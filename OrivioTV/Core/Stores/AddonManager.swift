import Foundation

/// Installed add-ons per profile (order + enabled). Manifests are persisted
/// zlib-compressed — one big catalog add-on is ~270 KB of JSON per profile.
@MainActor
final class AddonManager: ObservableObject, ProfileScoped {
    @Published private(set) var addons: [InstalledAddon] = []
    @Published private(set) var installing = false
    @Published var lastError: String?

    private let baseKey = "addons.v1"
    private var lastRefresh: Date = .distantPast
    var usesPrimaryProfile: () -> Bool = { false }

    init() {
        load()
    }

    private var storageProfile: Int { usesPrimaryProfile() ? 1 : ProfileScope.current }

    private func load() {
        if let stored = Persistence.loadScoped([InstalledAddon].self, base: baseKey, profile: storageProfile) {
            addons = stored
        } else {
            addons = DefaultAddons.all.map { url in
                InstalledAddon(manifestURL: url, manifest: .placeholder(name: url.contains("cinemeta") ? "Cinemeta" : "OpenSubtitles v3"))
            }
            Task { await refreshPlaceholders() }
        }
    }

    func reloadForActiveProfile() {
        load()
        NotificationCenter.default.post(name: .orivioAddonsChanged, object: nil)
    }

    private func save(markDirty: Bool = true) {
        // Installed manifests (catalogs, extras, resources) are a sizeable
        // encode; keep the press that installs or removes an add-on responsive.
        Persistence.saveScopedInBackground(addons, base: baseKey, profile: storageProfile)
        if markDirty { SyncSignals.markDirty(.addons) }
        NotificationCenter.default.post(name: .orivioAddonsChanged, object: nil)
    }

    var enabled: [InstalledAddon] { addons.filter(\.enabled) }

    var streamAddons: [InstalledAddon] { enabled.filter { $0.manifest.provides("stream") } }
    var subtitleAddons: [InstalledAddon] { enabled.filter { $0.manifest.provides("subtitles") } }
    var metaAddons: [InstalledAddon] { enabled.filter { $0.manifest.provides("meta") } }

    /// Metadata add-ons first (Cinemeta at the front), for search and meta lookups.
    var searchCatalogs: [(InstalledAddon, ManifestCatalog)] {
        var out: [(InstalledAddon, ManifestCatalog)] = []
        let ordered = enabled.sorted { a, b in
            let ra = a.isCinemeta ? 0 : (a.isMetadataAddon ? 1 : 2)
            let rb = b.isCinemeta ? 0 : (b.isMetadataAddon ? 1 : 2)
            return ra < rb
        }
        for addon in ordered {
            for cat in addon.manifest.catalogs where cat.supportsSearch {
                let otherRequired = cat.extra.filter { $0.isRequired && $0.name != "search" }
                if otherRequired.isEmpty { out.append((addon, cat)) }
            }
        }
        return out
    }

    func addon(id: String) -> InstalledAddon? { addons.first { $0.manifest.id == id || $0.manifestURL == id } }

    // MARK: Install / remove / order

    @discardableResult
    func install(_ rawURL: String) async -> Result<InstalledAddon, Error> {
        let url = InstalledAddon.normalizeManifestURL(rawURL)
        installing = true
        defer { installing = false }
        do {
            let manifest = try await AddonClient.fetchManifest(url)
            guard !manifest.isPlaceholder else { throw HTTPError.other("That URL didn't return an add-on manifest.") }
            let addon = InstalledAddon(manifestURL: url, manifest: manifest, enabled: true)
            if let i = addons.firstIndex(where: { $0.manifestURL == url || ($0.manifest.id == manifest.id && !manifest.id.isEmpty) }) {
                addons[i] = addon
            } else {
                addons.append(addon)
            }
            save()
            lastError = nil
            return .success(addon)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.manifestURL == addon.manifestURL }
        save()
    }

    func setEnabled(_ addon: InstalledAddon, _ on: Bool) {
        guard let i = addons.firstIndex(where: { $0.manifestURL == addon.manifestURL }) else { return }
        addons[i].enabled = on
        save()
    }

    func move(_ addon: InstalledAddon, by delta: Int) {
        guard let i = addons.firstIndex(where: { $0.manifestURL == addon.manifestURL }) else { return }
        let j = max(0, min(addons.count - 1, i + delta))
        guard i != j else { return }
        let item = addons.remove(at: i)
        addons.insert(item, at: j)
        save()
    }

    // MARK: Placeholders

    /// Re-resolves placeholder manifests (captive portal / WAF answered at
    /// install time). **Never overwrites a good manifest with a placeholder.**
    func refreshPlaceholders(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        let targets = addons.filter { force || $0.manifest.isPlaceholder }
        guard !targets.isEmpty else { return }
        let results = await boundedConcurrentMap(targets, limit: 4) { addon -> (String, AddonManifest?) in
            let m = try? await AddonClient.fetchManifest(addon.manifestURL)
            return (addon.manifestURL, m)
        }
        var changed = false
        for (url, manifest) in results {
            guard let manifest, !manifest.isPlaceholder, let i = addons.firstIndex(where: { $0.manifestURL == url }) else { continue }
            if addons[i].manifest != manifest {
                addons[i].manifest = manifest
                changed = true
            }
        }
        if changed { save(markDirty: false) }
    }

    // MARK: Sync

    /// Applies a remote list of manifest URLs (order matters), keeping any
    /// manifests we already have and fetching the rest.
    func applyRemote(urls: [(url: String, enabled: Bool)]) async {
        var result: [InstalledAddon] = []
        for entry in urls {
            let normalized = InstalledAddon.normalizeManifestURL(entry.url)
            if let existing = addons.first(where: { $0.manifestURL == normalized }) {
                var a = existing
                a.enabled = entry.enabled
                result.append(a)
            } else {
                result.append(InstalledAddon(manifestURL: normalized, manifest: .placeholder(), enabled: entry.enabled))
            }
        }
        guard !result.isEmpty else { return }
        addons = result
        save(markDirty: false)
        await refreshPlaceholders(force: false)
    }

    /// Export: every manifest URL, one per line.
    var exportText: String { addons.map(\.manifestURL).joined(separator: "\n") }

    func importURLs(_ text: String) async -> Int {
        let urls = text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "," })
            .map(String.init).filter { $0.contains("manifest.json") || $0.hasPrefix("stremio://") }
        var n = 0
        for u in urls where !addons.contains(where: { $0.manifestURL == InstalledAddon.normalizeManifestURL(u) }) {
            if case .success = await install(u) { n += 1 }
        }
        return n
    }

    // MARK: Health

    struct Health: Identifiable {
        let id: String
        let name: String
        let millis: Int?
        let error: String?
        var label: String {
            if let error { return "Not responding — \(error)" }
            guard let millis else { return "—" }
            return millis > 3000 ? "\(millis) ms · slow" : "\(millis) ms"
        }
    }

    func measureHealth() async -> [Health] {
        await boundedConcurrentMap(addons, limit: 6) { addon in
            let start = Date()
            do {
                let m = try await AddonClient.fetchManifest(addon.manifestURL, timeout: 10)
                if m.isPlaceholder { return Health(id: addon.id, name: addon.displayName, millis: nil, error: "not a manifest") }
                return Health(id: addon.id, name: addon.displayName, millis: Int(Date().timeIntervalSince(start) * 1000), error: nil)
            } catch {
                return Health(id: addon.id, name: addon.displayName, millis: nil, error: error.localizedDescription)
            }
        }
    }
}
