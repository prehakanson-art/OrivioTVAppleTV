import Foundation

@MainActor
final class AddonManager: ObservableObject {
    @Published private(set) var addons: [InstalledAddon] = []
    @Published var lastError: String?

    /// Called after a user-initiated change so account sync can push. Not
    /// fired while applying remote data (guarded by `suppressChange`).
    var onLocalChange: (() -> Void)?
    /// Called when the user taps "Refresh Add-ons" — the sync manager wires this
    /// to pull the account's addons so ones added on other devices appear.
    /// THROWS so the caller can tell the user WHY nothing arrived; `nil` means
    /// no sync manager is attached at all (signed out).
    var onSyncRequested: (() async throws -> Void)?
    private var suppressChange = false

    private static let storageKey = "orivio.addons.v1"
    static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"

    struct RemoteAddonState {
        let manifestURL: String
        let enabled: Bool
    }

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
        // Split any query/fragment off BEFORE deciding. A configured addon's
        // manifest routinely carries one (…/manifest.json?token=…), and
        // appending to the whole string produced
        // "…/manifest.json?token=…/manifest.json" — an addon that can never be
        // installed, and whose `baseURL` then equals its manifest URL so every
        // catalog/meta/stream request is malformed too.
        var suffix = ""
        if let mark = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            suffix = String(s[mark...])
            s = String(s[s.startIndex..<mark])
        }
        if !s.hasSuffix("manifest.json") {
            s = s.hasSuffix("/") ? s + "manifest.json" : s + "/manifest.json"
        }
        return s + suffix
    }

    /// Applies the account's addon list.
    ///
    /// `reconcile: false` is additive — install anything new, never remove.
    /// Used for the FIRST pull on a profile, where the account may legitimately
    /// know less than this device and the follow-up push uploads the union.
    ///
    /// `reconcile: true` makes the account authoritative: addons the account no
    /// longer lists are REMOVED locally, so a delete on another device
    /// propagates here. Only safe once this profile is "seeded" (has synced
    /// addon data before) and once any pending local change has been pushed —
    /// both enforced by the caller (OrivioSyncManager.pullAddons), because
    /// reconciling against a stale account would delete addons this device
    /// added while offline.
    ///
    /// Does not fire `onLocalChange` (no echo back). Returns the number added.
    @discardableResult
    func applyRemote(urls: [String], reconcile: Bool = false) async -> Int {
        await applyRemote(
            addons: urls.map { RemoteAddonState(manifestURL: $0, enabled: true) },
            reconcile: reconcile
        )
    }

    /// Applies the account's addon list, including each addon's enabled state.
    /// Does not fire `onLocalChange` (no echo back). Returns the number added.
    @discardableResult
    func applyRemote(addons remoteAddons: [RemoteAddonState], reconcile: Bool = false) async -> Int {
        suppressChange = true
        defer { suppressChange = false }
        let normalizedStates = remoteAddons.map { state in
            let manifestURL = Self.normalizeManifestURL(state.manifestURL)
            // Derived by the SAME rule as `InstalledAddon.baseURL`. This used to
            // strip only a trailing "/manifest.json" and keep the query, so for
            // a configured addon (…/manifest.json?token=…) the two disagreed and
            // the identity match below never fired: every sync re-fetched and
            // re-appended the addon (shuffling it to the end of the priority
            // order), a reconciling pull removed then re-added it, and an
            // enable/disable made on another device never reached it.
            let baseURL = InstalledAddon.baseURL(forManifestURL: manifestURL)
            return (manifestURL: manifestURL, baseURL: baseURL, enabled: state.enabled)
        }
        let existing = Set(addons.map { $0.baseURL })
        // Keep only genuinely-new addons, in their incoming order.
        let toInstall = normalizedStates.filter { !existing.contains($0.baseURL) }
        // Removals first, so the count logged below reflects the real delta.
        var removed = 0
        if reconcile {
            let remoteBases = Set(normalizedStates.map(\.baseURL))
            let before = addons.count
            addons.removeAll { !remoteBases.contains($0.baseURL) }
            removed = before - addons.count
            if removed > 0 { save() }
        }

        var updatedEnabled = 0
        for state in normalizedStates {
            guard let index = addons.firstIndex(where: { $0.baseURL == state.baseURL }),
                  addons[index].enabled != state.enabled else { continue }
            addons[index].enabled = state.enabled
            updatedEnabled += 1
        }
        if updatedEnabled > 0 { save() }

        NSLog("[OrivioAddonSync] pull: %d from account, %d already installed, %d to add, %d removed (reconcile=%@)",
              normalizedStates.count, normalizedStates.count - toInstall.count, toInstall.count, removed,
              reconcile ? "yes" : "no")
        guard !toInstall.isEmpty else { return 0 }

        // Fetch the new manifests a few at a time, then apply in the original
        // order so the installed list is deterministic. A manifest that fails
        // to fetch still installs as a placeholder (never dropped): dropping it
        // would let a later push delete this account addon from the server.
        // The window matters here: this runs during the first-login sync, when
        // an account with dozens of addons would otherwise fire every manifest
        // request at once while Home is also loading.
        let fetched = await boundedConcurrentMap(toInstall, limit: AddonSweepLimits.manifests) { state in
            let manifest = (try? await StremioAPI.manifest(url: state.manifestURL))
                ?? AddonManifest.placeholder(manifestURL: state.manifestURL)
            return (state, manifest)
        }

        var added = 0
        for (state, manifest) in fetched {
            let addon = InstalledAddon(manifestURL: state.manifestURL, manifest: manifest, enabled: state.enabled)
            if let existing = addons.firstIndex(where: { $0.manifestURL == state.manifestURL }) {
                addons[existing] = addon
            } else {
                addons.append(addon)
                added += 1
            }
        }
        save()
        return added
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

    private static let lastRefreshKey = "orivio.addons.lastRefresh.v1"

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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshManifests()
            }
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

    /// Remove every installed add-on. For an ACCOUNT SWITCH only.
    ///
    /// A configured add-on's manifest URL routinely embeds the user's own debrid
    /// token (Torrentio and friends), and the first pull for a new account is
    /// additive (its seeded flag was just cleared), so leaving these installed
    /// meant the end-of-sync replace push uploaded the PREVIOUS user's manifest
    /// URLs — token and all — into the new user's account.
    ///
    /// Deliberately silent: the caller is retiring the previous account's state
    /// and must not arm a push of the result.
    func clearAll() {
        guard !addons.isEmpty else { return }
        addons.removeAll()
        save()
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

    /// Install every manifest URL in an exported setup blob. Accepts one URL per
    /// line, comma-separated lists, and pasted text that contains manifest URLs.
    @discardableResult
    func importManifestURLs(from text: String) async -> (installed: Int, failed: Int) {
        let urls = Self.extractManifestURLs(from: text)
        guard !urls.isEmpty else { return (0, 0) }

        var installed = 0
        var failed = 0
        for url in urls {
            do {
                try await install(manifestURL: url)
                installed += 1
            } catch {
                failed += 1
            }
        }
        return (installed, failed)
    }

    var exportedManifestList: String {
        addons.map(\.manifestURL).joined(separator: "\n")
    }

    private static func extractManifestURLs(from text: String) -> [String] {
        let pattern = #"https?://[^\s,;]+(?:manifest\.json)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let normalized = normalizeManifestURL(String(text[r]))
            guard !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return normalized
        }
    }

    struct HealthResult: Identifiable, Equatable {
        enum Status: Equatable {
            case ok
            case slow
            case disabled
            case failed(String)

            var label: String {
                switch self {
                case .ok: return "OK"
                case .slow: return "Slow"
                case .disabled: return "Off"
                case .failed: return "Failed"
                }
            }
        }

        let id: String
        let name: String
        let manifestURL: String
        let elapsedMS: Int?
        let status: Status
        let capabilities: String
    }

    /// Measures manifest responsiveness for every installed addon. This is a
    /// lightweight provider health check for users with many addons enabled:
    /// slow or dead manifests usually explain long home/source loading.
    func healthCheck() async -> [HealthResult] {
        let snapshot = addons
        guard !snapshot.isEmpty else { return [] }

        return await boundedConcurrentMap(snapshot, limit: AddonSweepLimits.manifests) { addon in
            let capabilities = Self.capabilitySummary(for: addon.manifest)
            guard addon.enabled else {
                return HealthResult(
                    id: addon.id, name: addon.manifest.name, manifestURL: addon.manifestURL,
                    elapsedMS: nil, status: .disabled, capabilities: capabilities
                )
            }

            let started = Date()
            do {
                _ = try await StremioAPI.manifest(url: addon.manifestURL)
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                return HealthResult(
                    id: addon.id, name: addon.manifest.name, manifestURL: addon.manifestURL,
                    elapsedMS: elapsed, status: elapsed > 2500 ? .slow : .ok,
                    capabilities: capabilities
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                return HealthResult(
                    id: addon.id, name: addon.manifest.name, manifestURL: addon.manifestURL,
                    elapsedMS: elapsed, status: .failed(Self.shortReason(error)),
                    capabilities: capabilities
                )
            }
        }
    }

    nonisolated private static func capabilitySummary(for manifest: AddonManifest) -> String {
        var parts: [String] = []
        if manifest.providesCatalogs { parts.append("Catalogs") }
        if manifest.providesStreams { parts.append("Streams") }
        if manifest.providesMeta { parts.append("Meta") }
        if manifest.providesSubtitles { parts.append("Subtitles") }
        return parts.isEmpty ? "No active resources" : parts.joined(separator: " · ")
    }

    /// Re-fetch every installed addon's manifest (the APK's "Refresh Add-ons")
    /// AND sync with the account: pull addons added on other devices, then push
    /// the merged list back.
    /// Result of a user-initiated "Refresh Add-ons", so the UI can say what
    /// actually happened. Previously this returned nothing and every failure —
    /// signed out, HTTP error, decode error, empty account — was swallowed by a
    /// `try?`, while the button unconditionally reported "Add-ons refreshed
    /// just now". That is why account add-ons appeared not to sync with no
    /// indication of why.
    enum RefreshOutcome {
        case notSignedIn
        case changed(added: Int, removed: Int)
        case alreadyUpToDate
        case failed(String)

        var message: String {
            switch self {
            case .notSignedIn:
                return "Manifests refreshed — sign in to sync add-ons with your account"
            case .changed(let added, let removed):
                var parts: [String] = []
                if added > 0 { parts.append("added \(added)") }
                if removed > 0 { parts.append("removed \(removed)") }
                return "Synced with your account — " + parts.joined(separator: ", ")
            case .alreadyUpToDate:
                return "Add-ons synced — already up to date"
            case .failed(let why):
                return "Couldn't sync with your account: \(why)"
            }
        }
    }

    /// TWO-WAY add-on sync (the "Sync Add-ons" button).
    ///
    /// Re-fetches every manifest, then hands off to the sync manager, which
    /// pushes any pending local change UP first and then pulls the account down
    /// with reconciliation — so an add-on deleted on another device is deleted
    /// here too, and one added here survives rather than being reconciled away.
    @discardableResult
    func syncWithAccount() async -> RefreshOutcome {
        await refreshManifests()
        guard let onSyncRequested else {
            NSLog("[OrivioAddonSync] sync: no sync manager attached (signed out)")
            return .notSignedIn
        }
        let before = Set(addons.map(\.manifestURL))
        do {
            try await onSyncRequested()
        } catch {
            NSLog("[OrivioAddonSync] sync FAILED: %@", String(describing: error))
            return .failed(Self.shortReason(error))
        }
        let after = Set(addons.map(\.manifestURL))
        let added = after.subtracting(before).count
        let removed = before.subtracting(after).count
        NSLog("[OrivioAddonSync] sync ok: +%d -%d", added, removed)
        return (added + removed) > 0
            ? .changed(added: added, removed: removed) : .alreadyUpToDate
    }

    nonisolated private static func shortReason(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .notConnectedToInternet ? "no internet" : "network error"
        }
        if error is DecodingError { return "unexpected response from the server" }
        let text = "\(error)"
        return text.count > 90 ? String(text.prefix(90)) + "…" : text
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
    static func bundledCinemeta() -> InstalledAddon {
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
