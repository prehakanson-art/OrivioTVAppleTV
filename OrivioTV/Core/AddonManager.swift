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

    /// The LEGACY device-wide list. Never deleted (except on account switch):
    /// it is what the PRIMARY profile inherits when add-ons are separate, and
    /// the live list in shared mode. Other profiles start from the defaults —
    /// Trakt-switch semantics; `ensureDefaults` means never truly empty.
    private static let storageKey = "orivio.addons.v1"
    static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"

    // MARK: Per-profile scope

    /// Add-ons are PER PROFILE, like the library/progress/layout stores — a
    /// configured add-on's manifest URL carries personal state (a debrid
    /// token, a Letterboxd account baked into an Xperience config), and one
    /// household's profiles legitimately install different ones. The account
    /// backend has always stored them per profile (Android writes scoped
    /// rows); this store and the tvOS sync used to flatten everything into
    /// one device-wide list, which is why two profiles showed identical
    /// add-ons and home layouts.
    ///
    /// Read at init from ProfileStore's key (same trick TraktStore uses) so
    /// the scope is right from launch even when signed out.
    private(set) var profileID: Int

    private static let activeProfileKey = "orivio.profiles.active"

    /// Feature name for the separate-vs-shared switch (see
    /// `ProfileScopedDefaults.isSeparate`). Shared mode = every profile uses
    /// one device-wide list, the pre-split behaviour.
    static let feature = "addons"

    /// Whether add-ons are kept separately per profile (the default) or as
    /// one shared list, Trakt-switch style.
    var perProfileEnabled: Bool { ProfileScopedDefaults.isSeparate(Self.feature) }

    /// Flip separate ↔ shared and reload the visible list for the new mode.
    /// Silent (no push armed): the LIST didn't change, only which copy is live.
    func setPerProfile(_ on: Bool) {
        guard on != perProfileEnabled else { return }
        ProfileScopedDefaults.setSeparate(Self.feature, on)
        suppressChange = true
        defer { suppressChange = false }
        addons = []
        load()
        ensureDefaults()
    }

    /// Point the store at a profile: swap the previous profile's add-on list
    /// out for this one's. The primary profile inherits the legacy device-wide
    /// list; any other profile with no list of its own starts from the
    /// defaults (its account rows pull in on the next sync).
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        suppressChange = true
        defer { suppressChange = false }
        addons = []
        load()
        ensureDefaults()
    }

    /// Forget a deleted profile's add-ons so a recycled profile id starts
    /// from the seed instead of inheriting them.
    func forgetProfile(_ id: Int) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey + ".p\(id)")
        UserDefaults.standard.removeObject(forKey: Self.forgottenDefaultsKey + ".p\(id)")
        if id == profileID {
            addons = []
            load()
            ensureDefaults()
        }
    }

    struct RemoteAddonState {
        let manifestURL: String
        let enabled: Bool
        /// Whether the source actually KNOWS the enabled state.
        ///
        /// Stremio's add-on descriptor has no `enabled` field at all, so a pull
        /// from there can only report "installed". Passing `true` for every row
        /// re-enabled anything the user had switched off here, on every tick
        /// (gap 5) — a local disable is an overlay the wire cannot express, so
        /// it must survive a pull that has nothing to say about it.
        let enabledIsAuthoritative: Bool

        init(manifestURL: String, enabled: Bool, enabledIsAuthoritative: Bool = true) {
            self.manifestURL = manifestURL
            self.enabled = enabled
            self.enabledIsAuthoritative = enabledIsAuthoritative
        }
    }

    /// A local edit arrived while a remote apply held the suppression.
    ///
    /// `applyRemote` keeps `suppressChange` set across its manifest fetches —
    /// seconds, on a slow or unreachable add-on — and it runs on the main
    /// actor, so a user removing an add-on in that window is delivered here
    /// and silently dropped. `onLocalChange` is the ONLY thing that sets the
    /// account sync's dirty flag, and the tail push is now gated on it, so the
    /// removal never reached the server and the next reconciling pull put the
    /// add-on straight back. Remember it and fire once the apply finishes.
    private var missedLocalChangeWhileSuppressed = false

    private func notifyLocalChange() {
        guard !suppressChange else {
            missedLocalChangeWhileSuppressed = true
            return
        }
        onLocalChange?()
    }

    /// Lift the suppression, delivering any change that arrived under it.
    private func endSuppression() {
        suppressChange = false
        guard missedLocalChangeWhileSuppressed else { return }
        missedLocalChangeWhileSuppressed = false
        onLocalChange?()
    }

    /// Add-ons just merged from the Stremio account need to reach the Orivio
    /// account too. `applyRemote` deliberately fires no change hook (the
    /// account's own pull must not echo), so a tracker merge asks explicitly —
    /// the full sync no longer re-uploads the list unconditionally.
    func requestSyncPush() {
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
        defer { endSuppression() }
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
            return (manifestURL: manifestURL, baseURL: baseURL, enabled: state.enabled,
                    authoritative: state.enabledIsAuthoritative)
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
        for state in normalizedStates where state.authoritative {
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
    /// Bounded and time-boxed. This used to be a plain serial loop at the 20s
    /// session timeout, and the source sweep AWAITED it — so two unreachable
    /// add-ons on a cold cache meant up to forty seconds staring at
    /// "Searching addons 0/0" before a single stream request went out. It is a
    /// self-heal, not a precondition for playing anything.
    private static let placeholderResolveTimeout: TimeInterval = 5

    @discardableResult
    func resolvePlaceholders() async -> Bool {
        let stuck = addons.filter { $0.enabled && $0.manifest.isPlaceholder }
        guard !stuck.isEmpty else { return false }
        let timeout = Self.placeholderResolveTimeout
        let resolved = await boundedConcurrentMap(stuck, limit: AddonSweepLimits.manifests) { addon in
            let manifest: AddonManifest? = await withTaskGroup(of: AddonManifest?.self) { group in
                group.addTask { try? await StremioAPI.manifest(url: addon.manifestURL) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            return (url: addon.manifestURL, manifest: manifest, enabled: addon.enabled)
        }
        var resolvedAny = false
        for entry in resolved {
            // Same rule as the refresh: an empty manifest is not a resolution.
            guard let manifest = entry.manifest, !manifest.isPlaceholder,
                  let index = addons.firstIndex(where: { $0.manifestURL == entry.url }) else { continue }
            addons[index] = InstalledAddon(
                manifestURL: entry.url, manifest: manifest, enabled: entry.enabled
            )
            resolvedAny = true
        }
        if resolvedAny { save() }
        return resolvedAny
    }

    private static let lastRefreshKey = "orivio.addons.lastRefresh.v1"

    init() {
        profileID = UserDefaults.standard.object(forKey: Self.activeProfileKey) as? Int ?? 1
        load()
        ensureDefaults()
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
        metaAddons(for: type, id: id).first
    }

    /// Every meta add-on worth ASKING for this id, best first.
    ///
    /// `metaAddon` returns only the best guess, and a single guess is not
    /// enough for a series: an add-on can advertise meta, claim the id, and
    /// still answer without a `videos` array — at which point the detail page
    /// has a title and no episodes, and nothing tries anyone else. (That is
    /// what "no season or episode options" looks like on a catalog-only
    /// add-on whose items carry ids no installed meta provider really serves.)
    /// Callers that need episodes walk this list until one answers usefully.
    ///
    /// Ordered: add-ons that declare the id prefix first, then the rest as a
    /// long shot — the same two-tier logic `metaAddon` had, spelled out.
    func metaAddons(for type: String, id: String) -> [InstalledAddon] {
        // Honour `enabled`, as every other capability lookup does: a disabled
        // meta addon stopped serving catalogs and streams but still answered
        // episode lists, Continue Watching enrichment and next-episode lookups.
        let enabled = addons.filter { $0.enabled && $0.manifest.providesMeta }
        let claiming = enabled.filter { $0.handles(id: id) }
        let rest = enabled.filter { addon in !claiming.contains { $0.id == addon.id } }
        return claiming + rest
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
    ///
    /// EVERY profile's list plus the legacy device-wide seed, not just the
    /// active scope: any surviving slot (or the seed a fresh profile would
    /// copy) still carries the previous user's tokenized manifest URLs, and
    /// the next profile switch would load them straight into the new account.
    func clearAll() {
        addons.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        for id in 1...ProfileStore.maxProfiles {
            UserDefaults.standard.removeObject(forKey: Self.storageKey + ".p\(id)")
        }
    }

    func remove(_ addon: InstalledAddon) {
        // Record it FIRST: a default removed on purpose must not come back on
        // the next launch, or the Remove button looks broken.
        noteDefaultRemoved(addon)
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
                _ = try await StremioAPI.manifest(url: addon.manifestURL, bypassCache: true)
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
            AppProbe.warn("addon sync", "\(error)")
            return .failed(Self.shortReason(error))
        }
        let after = Set(addons.map(\.manifestURL))
        let added = after.subtracting(before).count
        let removed = before.subtracting(after).count
        NSLog("[OrivioAddonSync] sync ok: +%d -%d", added, removed)
        AppProbe.sync("add-ons: +\(added) -\(removed)")
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
        let refreshed = await boundedConcurrentMap(current, limit: AddonSweepLimits.manifests) { addon -> (InstalledAddon, Bool) in
            guard let manifest = try? await StremioAPI.manifest(url: addon.manifestURL) else {
                return (addon, false)
            }
            // A 200 THAT ISN'T A MANIFEST decodes to an EMPTY one: the decoder
            // is deliberately tolerant, so a captive-portal page, a CDN error
            // body or a WAF challenge all come back as a manifest with no
            // catalogs and no resources — `isPlaceholder`. Written over a good
            // entry and saved, that is an add-on gone from Home and Sources
            // with nothing to bring it back before the next launch, which is
            // exactly what a wake-time network hiccup produces. Keep what we
            // have unless the answer is better than it.
            guard !manifest.isPlaceholder || addon.manifest.isPlaceholder else {
                return (addon, false)
            }
            // Preserve the user's enable/disable choice across a refresh.
            return (InstalledAddon(manifestURL: addon.manifestURL, manifest: manifest, enabled: addon.enabled), true)
        }
        // Bail if the installed set changed while we were fetching (e.g. the
        // user added/removed an addon), so we don't clobber their edit.
        guard addons.map(\.manifestURL) == current.map(\.manifestURL) else { return }
        addons = refreshed.map { $0.0 }
        save()
        // Only a sweep that actually reached an add-on counts as "done for the
        // hour". Stamping it after a sweep where every fetch failed burned the
        // whole window, so the relaunch right after — the one the viewer makes
        // BECAUSE something is missing — skipped the repair entirely.
        if refreshed.contains(where: { $0.1 }) {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRefreshKey)
        }
    }

    private func load() {
        // Separate mode: this profile's own list; only the PRIMARY profile
        // falls back to the legacy device-wide list (Trakt-switch semantics —
        // other profiles start fresh with the defaults). Shared mode: the
        // legacy list IS the list.
        guard let data = ProfileScopedDefaults.data(Self.storageKey, feature: Self.feature, profileID),
              let decoded = try? JSONDecoder().decode([InstalledAddon].self, from: Self.inflated(data))
        else { return }
        addons = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(addons) else { return }
        UserDefaults.standard.set(
            Self.deflated(data),
            forKey: ProfileScopedDefaults.writeKey(Self.storageKey, feature: Self.feature, profileID)
        )
    }

    /// The list is stored COMPRESSED, because a manifest is not a preference.
    ///
    /// Every installed addon is persisted here with its whole manifest, and a
    /// catalog pack's manifest is enormous: one real Xperience profile is 746
    /// catalogs, each with its genre list — 270 KB in this one key, per
    /// profile that installs it. NSUserDefaults on tvOS is not sized for that.
    /// A domain around 1 MB is where CFPreferences answered a write with
    /// `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`
    /// and abort() — the crash that moved the collections library out to a
    /// file — and three such profiles on a box whose other keys already hold
    /// ~450 KB clears that on their own. zlib takes the same list to ~10 KB
    /// (25x), which puts it back in proportion without moving addons out of
    /// the defaults they have always lived in (a file in Caches is purgeable,
    /// and a viewer with no account would lose the list outright).
    ///
    /// Written by `save()`, read by `load()`, and nothing else touches the key.
    /// An older build reading a compressed blob decodes nothing and falls back
    /// to the default addons, so a DOWNGRADE re-seeds the list from the
    /// account rather than keeping it.
    private static let compressionMagic = Data([0x4F, 0x41, 0x5A, 0x31])   // "OAZ1"

    /// Compressed, behind a magic prefix — or the plain JSON when compression
    /// fails, which `inflated` reads just as happily.
    private static func deflated(_ json: Data) -> Data {
        guard let squeezed = try? (json as NSData).compressed(using: .zlib) as Data else { return json }
        return compressionMagic + squeezed
    }

    /// The JSON back out. Anything without the magic is returned untouched:
    /// the plain blob every build before this one wrote, and the argument-domain
    /// overrides the UI tests launch with.
    private static func inflated(_ stored: Data) -> Data {
        guard stored.starts(with: compressionMagic),
              let json = try? (Data(stored.dropFirst(compressionMagic.count)) as NSData)
                .decompressed(using: .zlib) as Data
        else { return stored }
        return json
    }

    /// Emergency launch reclaim: compress any add-on list still stored
    /// UNCOMPRESSED.
    ///
    /// `save()` is the only writer, and it only runs once the app gets far
    /// enough to mutate the list. On a box whose UserDefaults domain is already
    /// at the ~1 MB CFPreferences abort — a big catalog pack installed by a
    /// build from before compression shipped (v7 had none) — the first
    /// unrelated write at launch aborts the process, so the app can never reach
    /// that `save()` and loops on every launch with no way to reach Settings.
    /// This runs before any other write and shrinks the domain with a REDUCING
    /// write (CFPreferences accepts those), which breaks the loop. Lossless:
    /// the same JSON, just compressed. Anything already carrying the magic is
    /// skipped, and a non-`Data` value (the UI tests' launch-argument override)
    /// is left alone.
    static func reclaimUncompressedStorage() {
        let defaults = UserDefaults.standard
        // BOTH namespaces. The oversized blob this exists for was written by a
        // PRE-RENAME build under `nuvio.addons.v1`; reclaiming only
        // `orivio.addons.v1` left it untouched, and the rename migration then
        // copied those oversized bytes into the new key — a large write that
        // aborts the very domain this is meant to shrink. The legacy key is
        // compressed HERE, first, so the migration carries the small copy.
        let prefixes = ["orivio.addons.v1", "nuvio.addons.v1"]
        for prefix in prefixes {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                guard let stored = defaults.data(forKey: key),
                      !stored.starts(with: compressionMagic) else { continue }
                let squeezed = deflated(stored)
                guard squeezed.count < stored.count else { continue }
                defaults.set(squeezed, forKey: key)
                NSLog("[OrivioAddons] reclaimed %@: %d → %d bytes", key, stored.count, squeezed.count)
            }
        }
    }

    /// Add-ons every install gets, with or without an account.
    ///
    /// Someone who chose "Use without an account" still has to be able to
    /// browse something, so these are guaranteed rather than merely seeded:
    /// `ensureDefaults()` puts back any that are missing. Removing one by hand
    /// is still respected — see `forgottenDefaultsKey`.
    static let defaultManifestURLs = [cinemetaURL, openSubtitlesURL]

    static let openSubtitlesURL = "https://opensubtitles-v3.strem.io/manifest.json"

    /// Defaults the viewer deliberately removed. Without this, `ensureDefaults`
    /// would reinstate them on the next launch and the Remove button would look
    /// broken.
    private static let forgottenDefaultsKey = "orivio.addons.forgottenDefaults.v1"

    /// Scoped like the list itself (mode-aware). The legacy device-wide set
    /// belongs to the PRIMARY profile (a default IT removed must not
    /// reappear); other profiles start with the defaults present.
    private var forgottenDefaults: Set<String> {
        get {
            if perProfileEnabled {
                if let scoped = UserDefaults.standard.stringArray(
                    forKey: ProfileScopedDefaults.key(Self.forgottenDefaultsKey, profileID)) {
                    return Set(scoped)
                }
                guard profileID == 1 else { return [] }
            }
            return Set(UserDefaults.standard.stringArray(forKey: Self.forgottenDefaultsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(
                Array(newValue),
                forKey: ProfileScopedDefaults.writeKey(Self.forgottenDefaultsKey, feature: Self.feature, profileID)
            )
        }
    }

    /// Put back any default the viewer hasn't explicitly removed.
    ///
    /// The bundled manifests are stand-ins so there is content before the first
    /// network round-trip; `refreshManifests()` replaces them with the live
    /// ones moments later.
    func ensureDefaults() {
        var changed = false
        let forgotten = forgottenDefaults
        for url in Self.defaultManifestURLs where !forgotten.contains(url) {
            guard !addons.contains(where: { $0.manifestURL == url }) else { continue }
            addons.append(Self.bundledDefault(for: url))
            changed = true
        }
        if changed { save() }
    }

    /// Remember that a default was removed on purpose.
    func noteDefaultRemoved(_ addon: InstalledAddon) {
        guard Self.defaultManifestURLs.contains(addon.manifestURL) else { return }
        forgottenDefaults.insert(addon.manifestURL)
    }

    private static func bundledDefault(for url: String) -> InstalledAddon {
        url == openSubtitlesURL ? bundledOpenSubtitles() : bundledCinemeta()
    }

    /// Placeholder for the subtitles default, replaced by the live manifest.
    static func bundledOpenSubtitles() -> InstalledAddon {
        let manifest = AddonManifest(
            id: "org.stremio.opensubtitlesv3",
            name: "OpenSubtitles v3",
            version: "1.0.0",
            description: "Subtitles from OpenSubtitles",
            logo: nil,
            types: ["movie", "series"],
            idPrefixes: ["tt"],
            catalogs: [],
            resources: [.simple("subtitles")]
        )
        return InstalledAddon(manifestURL: openSubtitlesURL, manifest: manifest)
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
