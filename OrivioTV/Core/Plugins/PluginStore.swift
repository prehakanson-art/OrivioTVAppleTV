import Foundation

/// Manages Orivio plugin repositories + JS scrapers: install/remove repos,
/// toggle scrapers, cache their JS, and run the enabled ones to produce
/// streams alongside Stremio addons. JSON-API scrapers work today; scrapers
/// that need crypto-js / cheerio require those bundled resources (see
/// PluginRuntime.bootstrapExtras).
@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var repositories: [PluginRepository] = []
    @Published private(set) var scrapers: [ScraperInfo] = []
    @Published var isBusy = false
    @Published var lastError: String?

    /// Fired on a user-driven change so account sync can push (repo list only —
    /// JS bodies are re-downloaded, not synced).
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private let runtime = PluginRuntime()
    private static let jsCache = DiskCache<String>(name: "scrapers")
    private static let reposKey = "orivio.plugins.repos.v1"
    private static let scrapersKey = "orivio.plugins.scrapers.v1"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    init() { load() }

    var enabledScrapers: [ScraperInfo] {
        let enabledRepoIDs = Set(repositories.filter(\.enabled).map(\.id))
        return scrapers.filter { $0.enabled && enabledRepoIDs.contains($0.repoID) }
    }

    // MARK: Repository management

    /// Add a repo from its manifest URL: fetch the manifest, download each
    /// scraper's JS, and register them.
    func addRepository(_ rawURL: String) async {
        let manifestURL = Self.canonicalManifestURL(rawURL)
        guard let url = URL(string: manifestURL) else { lastError = "Invalid URL"; return }
        isBusy = true; lastError = nil
        defer { isBusy = false }
        do {
            let (data, _) = try await session.data(from: url)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            let repoID = manifestURL
            let repo = PluginRepository(
                id: repoID, name: manifest.name, url: manifestURL,
                description: manifest.description, enabled: true, scraperCount: manifest.scrapers.count
            )

            var newScrapers: [ScraperInfo] = []
            for entry in manifest.scrapers {
                let jsURL = Self.resolve(filename: entry.filename, against: manifestURL)
                guard let jsURLObj = URL(string: jsURL),
                      let (jsData, _) = try? await session.data(from: jsURLObj),
                      let js = String(data: jsData, encoding: .utf8) else { continue }
                let info = ScraperInfo(
                    id: "\(repoID)::\(entry.id)", repoID: repoID, scraperID: entry.id,
                    name: entry.name, version: entry.version,
                    supportedTypes: entry.supportedTypes, enabled: entry.enabled,
                    logo: entry.logo, sourceURL: jsURL
                )
                await Self.jsCache.store(js, for: info.id)
                newScrapers.append(info)
            }
            guard !newScrapers.isEmpty else { lastError = "No scrapers in this repository"; return }

            repositories.removeAll { $0.id == repoID }
            scrapers.removeAll { $0.repoID == repoID }
            repositories.append(repo)
            scrapers.append(contentsOf: newScrapers)
            save(); notifyLocalChange()
        } catch {
            lastError = "Couldn't add repository: \(error.localizedDescription)"
        }
    }

    func removeRepository(_ id: String) {
        repositories.removeAll { $0.id == id }
        scrapers.removeAll { $0.repoID == id }
        save(); notifyLocalChange()
    }

    func setRepositoryEnabled(_ enabled: Bool, id: String) {
        guard let i = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[i].enabled = enabled
        save(); notifyLocalChange()
    }

    func setScraperEnabled(_ enabled: Bool, id: String) {
        guard let i = scrapers.firstIndex(where: { $0.id == id }) else { return }
        scrapers[i].enabled = enabled
        save(); notifyLocalChange()
    }

    // MARK: Streaming

    /// Run every enabled scraper for a title and collect their streams. `tmdbID`
    /// is the numeric TMDB id the scrapers expect; `mediaType` is movie / tv.
    func streams(tmdbID: String, mediaType: String, season: Int?, episode: Int?) async -> [StreamEntry] {
        let scrapers = enabledScrapers.filter { $0.supports(type: mediaType) }
        guard !scrapers.isEmpty else { return [] }
        // Bounded: each concurrent run stands up its OWN JSContext (JSCore isn't
        // thread-safe, so PluginRuntime can't share one), and a JSContext is
        // several MB apiece. Running every enabled scraper at once is what makes
        // a long plugin list expensive rather than just slow.
        let batches = await boundedConcurrentMap(scrapers, limit: AddonSweepLimits.plugins) { [runtime] scraper in
            guard let js = await Self.jsCache.value(for: scraper.id, ttl: .greatestFiniteMagnitude) else { return [StreamEntry]() }
            let results = await runtime.run(
                scraperJS: js, tmdbID: tmdbID, mediaType: mediaType, season: season, episode: episode
            )
            return results.map { Self.entry(from: $0, scraperName: scraper.name) }
        }
        return batches.flatMap { $0 }
    }

    nonisolated private static func entry(from result: ScraperResult, scraperName: String) -> StreamEntry {
        let title = result.title ?? result.name ?? result.quality ?? "Stream"
        var detailParts: [String] = []
        if let q = result.quality { detailParts.append(q) }
        if let size = result.size { detailParts.append(size) }
        if let lang = result.language { detailParts.append(lang) }
        let stream = Stream(
            name: result.provider ?? scraperName,
            title: title,
            description: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            url: result.url,
            infoHash: result.infoHash,
            behaviorHints: nil
        )
        return StreamEntry(addonName: result.provider ?? scraperName, stream: stream)
    }

    // MARK: Sync (repo list only)

    struct PluginSyncSnapshot: Codable, Equatable {
        var repositoryURLs: [String] = []
    }
    var snapshot: PluginSyncSnapshot { PluginSyncSnapshot(repositoryURLs: repositories.map(\.url)) }

    /// Apply the account's repo list.
    ///
    /// `reconcile: false` is additive (first pull / fresh account).
    /// `reconcile: true` also REMOVES repos the account no longer lists, so a
    /// plugin repo deleted on another device is deleted here — matching how
    /// add-ons, library and watched now behave. Gated by the caller's `seeded`
    /// check so a fresh account can't wipe this device.
    func applyRemote(_ s: PluginSyncSnapshot, reconcile: Bool = false) async {
        applyingRemote = true
        defer { applyingRemote = false }
        let existing = Set(repositories.map(\.url))
        for url in s.repositoryURLs where !existing.contains(url) {
            await addRepository(url)
        }
        guard reconcile else { return }
        let remote = Set(s.repositoryURLs)
        let goneIDs = repositories.filter { !remote.contains($0.url) }.map(\.id)
        guard !goneIDs.isEmpty else { return }
        repositories.removeAll { goneIDs.contains($0.id) }
        scrapers.removeAll { goneIDs.contains($0.repoID) }
        NSLog("[OrivioSync] plugins: removed %d repo(s) deleted on another device", goneIDs.count)
        save()
    }

    // MARK: Helpers / persistence

    private static func canonicalManifestURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "://") {
            let scheme = s[s.startIndex..<r.lowerBound].lowercased()
            if scheme != "http" && scheme != "https" { s = "https://" + s[r.upperBound...] }
        } else {
            s = "https://" + s
        }
        return s.hasSuffix(".json") ? s : (s.hasSuffix("/") ? s + "manifest.json" : s + "/manifest.json")
    }

    private static func resolve(filename: String, against manifestURL: String) -> String {
        if filename.hasPrefix("http://") || filename.hasPrefix("https://") { return filename }
        let base = manifestURL.replacingOccurrences(of: "/manifest.json", with: "")
        return "\(base)/\(filename.hasPrefix("/") ? String(filename.dropFirst()) : filename)"
    }

    private func notifyLocalChange() { if !applyingRemote { onLocalChange?() } }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.reposKey),
           let decoded = try? JSONDecoder().decode([PluginRepository].self, from: data) {
            repositories = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.scrapersKey),
           let decoded = try? JSONDecoder().decode([ScraperInfo].self, from: data) {
            scrapers = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: Self.reposKey)
        }
        if let data = try? JSONEncoder().encode(scrapers) {
            UserDefaults.standard.set(data, forKey: Self.scrapersKey)
        }
    }
}
