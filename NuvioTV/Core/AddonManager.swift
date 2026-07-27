import Foundation

@MainActor
final class AddonManager: ObservableObject {
    @Published private(set) var addons: [InstalledAddon] = []
    @Published var lastError: String?

    /// Called after a user-initiated change so account sync can push. Not
    /// fired while applying remote data (guarded by `suppressChange`).
    var onLocalChange: (() -> Void)?
    /// Called when the user taps "Refresh Add-ons" — the sync manager wires this
    /// to pull the account's addons (so ones added on other devices appear) and
    /// push the merged set back. `nil` (signed out) is a no-op.
    var onSyncRequested: (() async -> Void)?
    private var suppressChange = false

    private static let storageKey = "nuvio.addons.v1"
    static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"

    private func notifyLocalChange() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    /// Normalizes any user/remote addon reference to its canonical
    /// `…/manifest.json` URL (handles bare base URLs and `stremio://` links).
    static func normalizeManifestURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") {
            s = s.replacingOccurrences(of: "stremio://", with: "https://")
        }
        if !s.hasSuffix("manifest.json") {
            s = s.hasSuffix("/") ? s + "manifest.json" : s + "/manifest.json"
        }
        return s
    }

    /// Installs any remote addon URLs not already present, preserving remote
    /// order for the new ones. Manifests are fetched in parallel. Does not fire
    /// `onLocalChange` (no echo back).
    func applyRemote(urls: [String]) async {
        suppressChange = true
        defer { suppressChange = false }
        let existing = Set(addons.map { $0.baseURL })
        // Keep only genuinely-new addons, in their incoming order.
        let toInstall: [String] = urls.map(Self.normalizeManifestURL).filter { normalized in
            let base = normalized.hasSuffix("/manifest.json")
                ? String(normalized.dropLast("/manifest.json".count)) : normalized
            return !existing.contains(base)
        }
        guard !toInstall.isEmpty else { return }

        // Fetch the new manifests a few at a time, then apply in the original
        // order so the installed list is deterministic. A manifest that fails
        // to fetch still installs as a placeholder (never dropped): dropping it
        // would let a later push delete this account addon from the server.
        // The window matters here: this runs during the first-login sync, when
        // an account with dozens of addons would otherwise fire every manifest
        // request at once while Home is also loading.
        let fetched = await boundedConcurrentMap(toInstall, limit: AddonSweepLimits.manifests) { manifestURL in
            let manifest = (try? await StremioAPI.manifest(url: manifestURL))
                ?? AddonManifest.placeholder(manifestURL: manifestURL)
            return (manifestURL, manifest)
        }

        for (manifestURL, manifest) in fetched {
            let addon = InstalledAddon(manifestURL: manifestURL, manifest: manifest)
            if let existing = addons.firstIndex(where: { $0.manifestURL == manifestURL }) {
                addons[existing] = addon
            } else {
                addons.append(addon)
            }
        }
        save()
    }

    /// Re-fetch manifests for enabled PLACEHOLDER addons — ones installed (by
    /// account sync) while their manifest fetch failed, which otherwise sit
    /// silently contributing no streams/catalogs forever. Called when the
    /// Sources page opens so a transient install-time failure self-heals the
    /// next time the user actually needs the addon. Returns true if any
    /// placeholder resolved into a real manifest.
    func resolvePlaceholders() async -> Bool {
        let stuck = addons.filter { $0.enabled && $0.manifest.isPlaceholder }
        guard !stuck.isEmpty else { return false }
        var resolvedAny = false
        for addon in stuck {
            guard let manifest = try? await StremioAPI.manifest(url: addon.manifestURL) else { continue }
            if let index = addons.firstIndex(where: { $0.manifestURL == addon.manifestURL }) {
                addons[index] = InstalledAddon(
                    manifestURL: addon.manifestURL, manifest: manifest, enabled: addon.enabled
                )
                resolvedAny = true
            }
        }
        if resolvedAny { save() }
        return resolvedAny
    }

    private static let lastRefreshKey = "nuvio.addons.lastRefresh.v1"

    init() {
        load()
        if addons.isEmpty {
            addons = [Self.bundledCinemeta()]
            save()
        }
        // Manifests barely ever change — skip the launch refresh when the last
        // one is under an hour old (faster cold start, less addon traffic).
        // The manual "Refresh Add-ons" button always forces it.
        let last = UserDefaults.standard.double(forKey: Self.lastRefreshKey)
        if Date().timeIntervalSince1970 - last > 3600 {
            Task { await refreshManifests() }
        }
    }

    var streamAddons: [InstalledAddon] {
        addons.filter { $0.enabled && $0.manifest.providesStreams }
    }

    var catalogAddons: [InstalledAddon] {
        addons.filter { $0.enabled && $0.manifest.providesCatalogs }
    }

    var subtitleAddons: [InstalledAddon] {
        addons.filter { $0.enabled && $0.manifest.providesSubtitles }
    }

    func metaAddon(for type: String, id: String) -> InstalledAddon? {
        addons.first { $0.manifest.providesMeta && $0.handles(id: id) }
            ?? addons.first { $0.manifest.providesMeta }
    }

    func install(manifestURL rawURL: String) async throws {
        let urlString = Self.normalizeManifestURL(rawURL)
        let manifest = try await StremioAPI.manifest(url: urlString)
        let addon = InstalledAddon(manifestURL: urlString, manifest: manifest)
        if let existing = addons.firstIndex(where: { $0.manifestURL == urlString }) {
            addons[existing] = addon
        } else {
            addons.append(addon)
        }
        save()
        notifyLocalChange()
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.id == addon.id }
        save()
        notifyLocalChange()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        addons.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
        notifyLocalChange()
    }

    /// Reorder a single addon one slot up/down (the APK's row arrows).
    func moveUp(_ addon: InstalledAddon) {
        guard let i = addons.firstIndex(where: { $0.id == addon.id }), i > 0 else { return }
        addons.swapAt(i, i - 1)
        save()
        notifyLocalChange()
    }

    func moveDown(_ addon: InstalledAddon) {
        guard let i = addons.firstIndex(where: { $0.id == addon.id }), i < addons.count - 1 else { return }
        addons.swapAt(i, i + 1)
        save()
        notifyLocalChange()
    }

    /// Enable/disable an addon in place (stays installed, contributes nothing
    /// while off).
    func setEnabled(_ addon: InstalledAddon, _ enabled: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[i].enabled = enabled
        save()
        notifyLocalChange()
    }

    /// Re-fetch every installed addon's manifest (the APK's "Refresh Add-ons")
    /// AND sync with the account: pull addons added on other devices, then push
    /// the merged list back.
    func refresh() async {
        await refreshManifests()
        await onSyncRequested?()
    }

    private func refreshManifests() async {
        // Snapshot the current list, re-fetch the manifests a few at a time,
        // then reassemble in the original order.
        let current = addons
        guard !current.isEmpty else { return }
        let refreshed = await boundedConcurrentMap(current, limit: AddonSweepLimits.manifests) { addon in
            if let manifest = try? await StremioAPI.manifest(url: addon.manifestURL) {
                // Preserve the user's enable/disable choice across a refresh.
                return InstalledAddon(manifestURL: addon.manifestURL, manifest: manifest, enabled: addon.enabled)
            }
            return addon
        }
        // Bail if the installed set changed while we were fetching (e.g. the
        // user added/removed an addon), so we don't clobber their edit.
        guard addons.map(\.manifestURL) == current.map(\.manifestURL) else { return }
        addons = refreshed
        save()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRefreshKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([InstalledAddon].self, from: data) else { return }
        addons = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(addons) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Seed manifest so the home screen has content before the first network
    /// round-trip; replaced by the live manifest on launch.
    private static func bundledCinemeta() -> InstalledAddon {
        let manifest = AddonManifest(
            id: "com.linvo.cinemeta",
            name: "Cinemeta",
            version: "3.0.0",
            description: "The official addon for movie and series catalogs",
            logo: nil,
            types: ["movie", "series"],
            idPrefixes: ["tt"],
            catalogs: [
                ManifestCatalog(type: "movie", id: "top", name: "Popular", extra: [CatalogExtra(name: "search", isRequired: false, options: nil)], extraRequired: nil, extraSupported: ["search"]),
                ManifestCatalog(type: "series", id: "top", name: "Popular", extra: [CatalogExtra(name: "search", isRequired: false, options: nil)], extraRequired: nil, extraSupported: ["search"]),
                ManifestCatalog(type: "movie", id: "imdbRating", name: "Featured", extra: nil, extraRequired: nil, extraSupported: nil),
                ManifestCatalog(type: "series", id: "imdbRating", name: "Featured", extra: nil, extraRequired: nil, extraSupported: nil)
            ],
            resources: [.simple("catalog"), .simple("meta")]
        )
        return InstalledAddon(manifestURL: cinemetaURL, manifest: manifest)
    }
}
