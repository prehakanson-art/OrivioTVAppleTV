
import Combine
import Foundation

/// Two-way sync of the account's data with the Orivio Supabase backend.
///
/// v1 covers the two local stores that already exist on tvOS: installed addons
/// and watch progress. On sign-in it pulls remote → local, then pushes local →
/// remote so both sides converge; afterwards it pushes on local changes.
///
/// All calls carry the login Bearer token (sync RPCs are `SECURITY DEFINER`
/// and enforce `auth.uid()` server-side). RPC names / payloads mirror the
/// Android `AddonSyncService` and `WatchProgressSyncService`.
@MainActor
final class OrivioSyncManager: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?

    /// The live instance, so views that aren't handed one (AccountView is used
    /// from two places, neither of which owns it) can trigger a manual sync.
    /// Weak: RootView's `@State` owns the lifetime.
    private(set) static weak var shared: OrivioSyncManager?

    private let account: OrivioAccountManager
    private let addonManager: AddonManager
    private let progressStore: ProgressStore
    private let libraryStore: LibraryStore
    private let watchedStore: WatchedStore
    private let profileStore: ProfileStore
    private let collectionsStore: CollectionsStore
    private let homeCatalogSettings: HomeCatalogSettingsStore
    private let streamBadges: StreamBadgeStore?
    /// App-preference stores synced together as one own-feature blob
    /// (`nuvio_tvos_preferences`): player, TMDB, and theme settings.
    private let playerSettings: PlayerSettingsStore?
    private let tmdbSettings: TMDBSettingsStore?
    private let themeManager: ThemeManager?
    private let debridStore: DebridStore?
    private let pluginStore: PluginStore?
    private let torrentSettings: TorrentSettingsStore?
    private let traktStore: TraktStore?
    /// Reads the "Enrich Continue Watching" TMDB setting (the store lives
    /// outside this manager). nil → enrich (default).
    var enrichContinueWatchingEnabled: (() -> Bool)?

    private var cancellables = Set<AnyCancellable>()
    private var pushAddonsTask: Task<Void, Never>?
    private var pushLibraryTask: Task<Void, Never>?
    private var pushWatchedTask: Task<Void, Never>?
    private var pushProfilesTask: Task<Void, Never>?
    private var pushCollectionsTask: Task<Void, Never>?
    private var pushHomeCatalogTask: Task<Void, Never>?
    private var pushBadgeSettingsTask: Task<Void, Never>?
    private var pushAppPreferencesTask: Task<Void, Never>?
    private var pushProviderCredentialsTask: Task<Void, Never>?
    private var pushPluginsTask: Task<Void, Never>?
    private var avatarCatalogCache: [AvatarCatalogItem] = []
    private var wasSignedIn = false
    /// The in-flight full sync (sign-in or profile switch); new full syncs chain
    /// behind it so two cycles never interleave across profiles.
    private var fullSyncTask: Task<Void, Never>?
    /// Profiles whose library pull succeeded this session, gating empty
    /// (cleared) library pushes so a cold start — or a profile whose pull
    /// failed — can't wipe that profile's account library. See pushLibrary.
    private var pulledLibraryProfiles: Set<Int> = []

    struct PendingSyncCounts {
        let progressDeletes: Int
        let libraryDeletes: Int
        let watchedDeletes: Int

        var total: Int { progressDeletes + libraryDeletes + watchedDeletes }
    }

    var pendingSyncCounts: PendingSyncCounts {
        PendingSyncCounts(
            progressDeletes: loadPendingDeletes().count,
            libraryDeletes: loadPendingLibraryDeletes().count,
            watchedDeletes: loadPendingWatchedDeletes().count
        )
    }

    // MARK: - Seeded flags
    // "Has this profile ever had <kind> data on the account?" — persisted, set
    // after any non-empty pull or push. An EMPTY pull only reconciles (deletes
    // local rows) when seeded: genuinely "everything was removed elsewhere".
    // Unseeded + empty = first sign-in with a fresh account → keep local data
    // and let the following push upload it.
    private func seededKey(_ kind: String) -> String { "orivio.sync.seeded.\(kind).p\(pid)" }
    private func isSeeded(_ kind: String) -> Bool { UserDefaults.standard.bool(forKey: seededKey(kind)) }
    private func setSeeded(_ kind: String) { UserDefaults.standard.set(true, forKey: seededKey(kind)) }
    private func clearedWatchHistoryKey() -> String { "orivio.sync.clearedWatchHistory.v1.p\(pid)" }
    /// Bumped whenever the repair below learns to fix something new, so it
    /// runs once more on installs where the previous version already ran.
    /// v3: also drops the clear HORIZON and pushes that up, since the account
    /// blob was handing the horizon straight back on the next pull.
    private func repairedWatchHistoryClearKey() -> String { "orivio.sync.repairedWatchHistoryClear.v3.p\(pid)" }

    /// The active profile scopes all personal-data sync. Addons stay global
    /// (profile 1) so the same sources are available on every profile.
    private var pid: Int { profileStore.activeProfileID }

    /// Thrown when the active profile changes part-way through a sync run.
    ///
    /// Everything after `applyActiveProfileScope()` is scoped to ONE profile:
    /// the stores have been pointed at it and every RPC reads `pid` fresh. A
    /// switch mid-run therefore merged one profile's server data into another
    /// profile's store, and the pushes at the end uploaded THAT under the new
    /// profile's id with replace semantics — overwriting it for good. Syncs run
    /// every 30s and take a comparable time, so the overlap is routine.
    private struct ProfileChangedMidSync: Error {
        let from: Int
        let to: Int
    }

    private func ensureProfile(_ expected: Int) throws {
        guard pid == expected else {
            throw ProfileChangedMidSync(from: expected, to: pid)
        }
    }

    /// The account this device last synced. See `handleAccountIdentityChange`.
    private static let lastAccountUserKey = "orivio.account.lastUser.v1"

    /// Drop every piece of per-account sync bookkeeping: seeded flags, the
    /// pending delete queues, the cleared-watch-history horizon and repair
    /// stamps, and the persisted app-preferences dirty bit. Touches NO user
    /// content — only the state that records what this device has already
    /// agreed with one particular account.
    private func resetSyncBookkeeping() {
        let defaults = UserDefaults.standard
        // The device id and the diagnostics log are not account state.
        let preserved: Set<String> = ["orivio.sync.client.v1", "orivio.sync.log.v1"]
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("orivio.sync.") && !preserved.contains(key) {
            defaults.removeObject(forKey: key)
        }
        addonsDirty = false
        progressDirty = false
        libraryDirty = false
        profilesDirty = false
        pluginsDirty = false
        appPreferencesDirty = false
    }

    /// Drop credentials belonging to the PREVIOUS account. Both stores are
    /// account-synced and both `applyRemote` implementations only ever ADD, so
    /// without this the next `pushProviderCredentials` uploads the previous
    /// user's Trakt tokens and debrid API keys into the new user's account.
    /// Safe against wiping the new account's server rows: that push skips an
    /// empty credential set entirely.
    private func resetAccountScopedCredentials() {
        traktStore?.signOut()
        if let debridStore {
            for provider in DebridProvider.allCases {
                debridStore.setKey("", for: provider)
            }
        }
    }

    /// Retire the previous account's state when a DIFFERENT user signs in.
    /// Signing out cleared only the Supabase tokens, so the next account
    /// inherited the last one's seeded flags, queued deletes and credentials.
    private func handleAccountIdentityChange() {
        guard let current = account.currentUserID else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.lastAccountUserKey)
        defaults.set(current, forKey: Self.lastAccountUserKey)
        // First account on this device: nothing to retire, and clearing the
        // owner's locally-entered debrid keys here would be a regression.
        guard let previous, previous != current else { return }
        NSLog("[OrivioSync] a different account signed in — retiring the previous account's sync state")
        OrivioSyncDiagnostics.record(
            .info, area: "Orivio",
            "A different account signed in; cleared the previous account's sync state and provider credentials."
        )
        resetSyncBookkeeping()
        resetAccountScopedCredentials()
    }

    /// Stable per-device id so the backend can avoid echoing our own writes.
    private let clientID: String = {
        let key = "orivio.sync.client.v1"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    private enum RPC {
        static func url(_ name: String) -> String { "/rest/v1/rpc/\(name)" }
        static let pushAddons = "sync_push_addons"
        static let pushWatchProgress = "sync_push_watch_progress"
        static let pullWatchProgress = "sync_pull_watch_progress"
        static let deleteWatchProgress = "sync_delete_watch_progress"
        static let pushLibrary = "sync_push_library"
        static let deleteLibraryItems = "sync_delete_library_items"
        static let pullLibrary = "sync_pull_library"
        static let pushWatchedItems = "sync_push_watched_items"
        static let pullWatchedItems = "sync_pull_watched_items"
        static let deleteWatchedItems = "sync_delete_watched_items"
        static let pushProfiles = "sync_push_profiles"
        static let pullProfiles = "sync_pull_profiles"
        static let pullProfileLocks = "sync_pull_profile_locks"
        static let setProfilePin = "set_profile_pin"
        static let verifyProfilePin = "verify_profile_pin"
        static let clearProfilePin = "clear_profile_pin"
        static let pushCollections = "sync_push_collections"
        static let pullCollections = "sync_pull_collections"
        static let pushHomeCatalogSettings = "sync_push_home_catalog_settings"
        static let pullHomeCatalogSettings = "sync_pull_home_catalog_settings"
        static let pushProfileSettingsBlob = "sync_push_profile_settings_blob"
        static let pullProfileSettingsBlob = "sync_pull_profile_settings_blob"
        // Dedicated tables the Android app uses — synced alongside (dual-write)
        // the tvOS-preferences blob so plugins / debrid keys / Trakt logins flow
        // between the Apple TV and the phone, not just tvOS↔tvOS.
        static let pushPlugins = "sync_push_plugins"
        static let pushProviderCredentials = "sync_push_provider_credentials"
        static let pullProviderCredentials = "sync_pull_provider_credentials"
    }

    /// Platform tag the Android TV app uses for the profile-settings blob —
    /// badge configs (Badger/Fusion) live inside that blob, so we read/write
    /// the same rows.
    private static let settingsBlobPlatform = "tv"

    /// Platform tags for home catalog settings rows (mirrors Android).
    private enum HomeCatalogPlatform {
        static let shared = "home_catalog_shared"
        static let legacy = ["tv", "mobile"]
    }

    init(
        account: OrivioAccountManager,
        addonManager: AddonManager,
        progressStore: ProgressStore,
        libraryStore: LibraryStore,
        watchedStore: WatchedStore,
        profileStore: ProfileStore,
        collectionsStore: CollectionsStore,
        homeCatalogSettings: HomeCatalogSettingsStore,
        streamBadges: StreamBadgeStore? = nil,
        playerSettings: PlayerSettingsStore? = nil,
        tmdbSettings: TMDBSettingsStore? = nil,
        themeManager: ThemeManager? = nil,
        debridStore: DebridStore? = nil,
        pluginStore: PluginStore? = nil,
        torrentSettings: TorrentSettingsStore? = nil,
        traktStore: TraktStore? = nil
    ) {
        self.account = account
        self.addonManager = addonManager
        self.progressStore = progressStore
        self.libraryStore = libraryStore
        self.watchedStore = watchedStore
        self.profileStore = profileStore
        self.collectionsStore = collectionsStore
        self.homeCatalogSettings = homeCatalogSettings
        self.streamBadges = streamBadges
        self.playerSettings = playerSettings
        self.tmdbSettings = tmdbSettings
        self.themeManager = themeManager
        self.debridStore = debridStore
        self.pluginStore = pluginStore
        self.torrentSettings = torrentSettings
        self.traktStore = traktStore

        // Sync whenever we transition into a signed-in state.
        account.$authState
            .sink { [weak self] state in self?.handleAuthChange(state) }
            .store(in: &cancellables)

        // Push local changes upward (debounced for addons/library/watched/profiles, immediate for progress).
        addonManager.onLocalChange = { [weak self] in self?.scheduleAddonPush() }
        // "Sync Add-ons" → TWO-WAY. Pending local edits go up first, then the
        // account comes down with reconciliation so a removal made on another
        // device lands here. Ordering matters: pull-then-push would let a stale
        // account delete a local add-on that had never been pushed.
        addonManager.onSyncRequested = { [weak self] in
            guard let self else { return }
            // Two-way now: push pending local edits, then pull + reconcile.
            // (Was pull-only with `try?`, so a signed-out session and every
            // network/decode failure looked identical to success.)
            try await syncAddonsBothWays()
        }
        progressStore.onLocalUpdate = { [weak self] in self?.pushWatchProgress() }
        progressStore.onRemove = { [weak self] keys in self?.deleteWatchProgress(keys: keys) }
        libraryStore.onLocalChange = { [weak self] in self?.scheduleLibraryPush() }
        libraryStore.onRemove = { [weak self] items in self?.queueLibraryDeletes(items) }
        watchedStore.onLocalChange = { [weak self] in self?.scheduleWatchedPush() }
        watchedStore.onRemove = { [weak self] items in self?.deleteWatchedItems(items) }
        profileStore.onLocalChange = { [weak self] in self?.scheduleProfilePush() }
        profileStore.onSwitch = { [weak self] id in self?.handleProfileSwitch(id) }
        collectionsStore.onLocalChange = { [weak self] in
            // Collections sync through the tvOS-preferences blob (the dedicated
            // sync_*_collections RPCs aren't on the shared backend). The
            // legacy dedicated push is kept as a best-effort no-op in case the
            // backend ever gains it.
            self?.scheduleAppPreferencesPush()
            self?.scheduleCollectionsPush()
            // Collections appear as home rows, so their add/remove also
            // changes the catalog-settings payload.
            self?.scheduleHomeCatalogPush()
        }
        // Per-profile show/hide: the shared library is untouched, so only the
        // profile-scoped preferences blob needs pushing (NOT the collections
        // blob — that would write this profile's visible subset over the shared
        // library and delete other profiles' collections).
        collectionsStore.onVisibilityChange = { [weak self] in
            self?.scheduleAppPreferencesPush()
            self?.scheduleHomeCatalogPush()
        }
        homeCatalogSettings.onLocalChange = { [weak self] in self?.scheduleHomeCatalogPush() }
        streamBadges?.onLocalChange = { [weak self] in self?.scheduleBadgeSettingsPush() }
        streamBadges?.remoteSync = { [weak self] in
            await self?.pullBadgeSettings() ?? "Account sync isn't ready yet"
        }
        // App preferences (player / TMDB / theme) share one own-feature blob.
        playerSettings?.onLocalChange = { [weak self] in self?.scheduleAppPreferencesPush() }
        tmdbSettings?.onLocalChange = { [weak self] in self?.scheduleAppPreferencesPush() }
        themeManager?.onLocalChange = { [weak self] in self?.scheduleAppPreferencesPush() }
        // Debrid keys and plugins dual-write: the blob (tvOS↔tvOS) AND the
        // dedicated Android tables (tvOS↔phone).
        debridStore?.onLocalChange = { [weak self] in
            self?.scheduleAppPreferencesPush()
            self?.scheduleProviderCredentialsPush()
        }
        pluginStore?.onLocalChange = { [weak self] in
            self?.scheduleAppPreferencesPush()
            self?.schedulePluginsPush()
        }
        torrentSettings?.onLocalChange = { [weak self] in self?.scheduleAppPreferencesPush() }
        // Trakt tokens live only in the dedicated provider_credentials table.
        traktStore?.onLocalChange = { [weak self] in self?.scheduleProviderCredentialsPush() }
        homeCatalogSettings.onPresentationChange = { [weak self] in self?.scheduleAppPreferencesPush() }

        // Authed operations the profile UI needs (require the access token).
        profileStore.avatarCatalogLoader = { [weak self] in
            (try? await self?.loadAvatarCatalog()) ?? []
        }
        profileStore.pinVerifier = { [weak self] id, pin in
            (try? await self?.verifyProfilePin(id: id, pin: pin))
                ?? PinVerifyOutcome(unlocked: false, retryAfterSeconds: 0)
        }
        profileStore.pinSetter = { [weak self] id, pin, current in
            await self?.setProfilePin(id: id, pin: pin, currentPin: current) ?? .failure("Not signed in.")
        }
        profileStore.pinClearer = { [weak self] id, current in
            (try? await self?.clearProfilePin(id: id, currentPin: current)) ?? false
        }

        // Scope local stores to the persisted active profile at startup (no-op
        // for profile 1); works offline before any sync happens.
        applyActiveProfileScope()
        Self.shared = self
    }

    private func handleAuthChange(_ state: OrivioAuthState) {
        NSLog("[OrivioSync] authChange -> %@ (wasSignedIn=%@)",
              String(describing: state), wasSignedIn ? "true" : "false")
        switch state {
        case .signedIn:
            guard account.currentUserID != nil else {
                profileStore.accountAvailable = false
                stopAutoSync()
                wasSignedIn = false
                OrivioSyncDiagnostics.record(.failure, area: "Orivio", "Sync skipped because the saved account session has no user id.")
                return
            }
            profileStore.accountAvailable = true
            // Before anything can push, make sure no state belonging to a
            // previous account is still resident on this device.
            handleAccountIdentityChange()
            startAutoSync()
            guard !wasSignedIn else { return }
            wasSignedIn = true
            // Do not run the heavyweight full sync during app construction. The
            // 30-second auto-sync loop and manual controls still sync the account,
            // but launch must stay responsive even with a large saved library.
            OrivioSyncDiagnostics.record(.info, area: "Orivio", "Account sync will run after launch or when requested.")
        case .signedOut:
            // Only a REAL sign-out, not the launch-time "no stored session" or a
            // failed session restore — both of those also publish `.signedOut`,
            // and wiping the bookkeeping there would drop pending deletes the
            // same user still needs when they sign back in.
            let leftAnAccount = wasSignedIn
            wasSignedIn = false
            profileStore.accountAvailable = false
            stopAutoSync()
            // Nothing queued for the account we just left may be allowed to run
            // against whichever account signs in next: the pending delete queues
            // would delete THAT user's rows, and the seeded flags would put its
            // first pull straight into reconcile mode.
            if leftAnAccount { resetSyncBookkeeping() }
        case .loading:
            break
        }
    }

    // MARK: - Full sync

    // MARK: - Periodic auto-sync

    /// Seconds between automatic full syncs while signed in and foregrounded.
    static let autoSyncInterval: TimeInterval = 30
    private var autoSyncTask: Task<Void, Never>?
    /// Set by the player so a heavy multi-endpoint sync doesn't contend with
    /// streaming for bandwidth mid-playback (this app already fights rebuffering
    /// on high-bitrate remuxes). The tick is skipped, not dropped — the next one
    /// after playback ends runs normally.
    @MainActor static var playbackActive = false

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoSyncInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard account.accessToken != nil else { continue }
                // Never stack syncs: a slow one must not have a second start
                // behind it.
                guard !isSyncing else { continue }
                if Self.playbackActive {
                    NSLog("[OrivioSync] auto-sync tick skipped — playback active")
                    continue
                }
                await syncNow()
            }
        }
    }

    private func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    func syncNow() async {
        guard account.accessToken != nil else {
            NSLog("[OrivioSync] syncNow skipped — no access token")
            return
        }
        guard account.currentUserID != nil else {
            NSLog("[OrivioSync] syncNow skipped — no user id")
            lastSyncError = "Account session is missing a user id. Sign in again."
            OrivioSyncDiagnostics.record(.failure, area: "Orivio", lastSyncError ?? "Sync skipped.")
            return
        }
        guard !isSyncing else {
            NSLog("[OrivioSync] syncNow skipped — sync already running")
            OrivioSyncDiagnostics.record(.warning, area: "Orivio", "Sync skipped because another sync is already running.")
            return
        }
        NSLog("[OrivioSync] syncNow starting")
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Full sync started for profile \(pid).")
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }
        do {
            // Flush any pending local profile edit FIRST — a just-created
            // profile whose debounced push hasn't landed would otherwise be
            // wiped by the pull's replaceRemote below.
            if profilesDirty { try await pushProfiles() }
            // Flush a pending app-preferences push (collections, player/TMDB/
            // theme edits) BEFORE the pulls below, or a re-sync would clobber
            // the not-yet-pushed local edit with the stale server copy.
            if appPreferencesDirty { await pushAppPreferences() }
            // Learn the profile list first, then scope the personal-data stores
            // to the active profile before pulling its data.
            try await pullProfiles()
            applyActiveProfileScope()
            // Everything below is scoped to THIS profile. Pin it and re-check at
            // each step: a switch part-way through would otherwise merge this
            // profile's server data into the newly-selected profile's store and
            // then push the result back up under the new profile's id.
            let runProfile = pid
            repairAccidentalWatchHistoryClearState()
            // Pull first so remote wins on first login, then push the merged
            // set — but flush a pending add-on edit first. `addonsDirty` exists
            // for exactly this ("dirty ⇒ push first"), yet only the manual
            // "Sync Add-ons" button consulted it: a periodic full sync landing
            // inside the 1.2s debounce would reconcile an add-on you had just
            // removed back onto the device, and then push it up again.
            if addonsDirty { try await pushAddons() }
            try await pullAddons()
            try ensureProfile(runProfile)
            // Flush local progress edits before pulling. The account pull is a
            // full snapshot, so pulling first can interpret a just-watched row
            // as remotely deleted before its upload lands.
            if progressDirty { try await pushWatchProgressAll() }
            // Flush removals queued in a previous session before pulling, and
            // tombstone them, so a not-yet-deleted row can't come back here.
            await reconcileProgressDeletesBeforePull()
            try await pullWatchProgress()
            try ensureProfile(runProfile)
            await reconcileLibraryDeletesBeforePull()
            try await pullLibrary()
            try ensureProfile(runProfile)
            await reconcileWatchedDeletesBeforePull()
            try await pullWatchedItems()
            // Collections ride the tvOS-preferences blob (pullAppPreferences).
            // The dedicated RPC is best-effort — if the backend lacks it a
            // throw here must NOT abort the rest of the sync.
            try ensureProfile(runProfile)
            try? await pullCollections()
            try await pullHomeCatalogSettings()
            await pullBadgeSettings()   // best-effort; badge chips are cosmetic
            await pullAppPreferences()  // player/TMDB/theme prefs + collections
            await pullProviderCredentials()  // debrid keys + Trakt (Android table)
            // Trakt and the player key the same episode differently; collapse
            // any pair that already exists so the hub holds ONE row per episode.
            let collapsed = progressStore.collapseDuplicateEpisodes()
            if !collapsed.isEmpty {
                OrivioSyncDiagnostics.record(
                    .info, area: "Orivio",
                    "Collapsed \(collapsed.count) duplicate Continue Watching row(s) keyed differently by another source."
                )
            }
            // Local repo edits go up before the reconciling pull, or a removal
            // still inside its debounce is restored and then re-uploaded.
            if pluginsDirty { try? await pushPlugins() }
            await pullPlugins()              // plugin repos (Android table)
            // Last and most important gate: every push below REPLACES the
            // account's copy for `pid`, so one that runs after a switch
            // overwrites the newly-selected profile with this one's data.
            try ensureProfile(runProfile)
            try await pushProfiles()
            try await pushAddons()
            try await pushWatchProgressAll()
            try await pushLibrary()
            try await pushWatchedItems()
            try? await pushCollections()   // best-effort; see pull note above
            try await pushHomeCatalogSettings()
            await pushAppPreferences()
            await pushProviderCredentials()  // dual-write to the Android table
            try? await pushPlugins()
        } catch let change as ProfileChangedMidSync {
            // Not a failure: the user moved to another profile, and that switch
            // schedules its own sync. Abandoning here is the point.
            NSLog("[OrivioSync] syncNow abandoned — profile switched %d -> %d mid-run",
                  change.from, change.to)
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio",
                "Sync for profile \(change.from) abandoned because the active profile changed to \(change.to); the new profile syncs on its own."
            )
            return
        } catch {
            // A full-sync failure used to vanish into `lastSyncError` with no
            // console trace, so "my stuff isn't syncing" was undiagnosable from
            // a device log. The step that threw is the one that aborted every
            // later pull/push in this run.
            NSLog("[OrivioSync] syncNow FAILED: %@", String(describing: error))
            lastSyncError = describe(error)
            OrivioSyncDiagnostics.record(.failure, area: "Orivio", lastSyncError ?? "Sync failed.")
            return
        }
        NSLog("[OrivioSync] syncNow finished ok")
        OrivioSyncDiagnostics.record(.success, area: "Orivio", "Full sync finished for profile \(pid).")
    }

    func pullAccountUpdates() async {
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Pull updates requested; running full two-way sync for profile \(pid).")
        await syncNow()
    }

    func pushThisDevice() async {
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Device push requested; running full two-way sync for profile \(pid).")
        await syncNow()
    }

    private func applyActiveProfileScope() {
        progressStore.setProfile(pid)
        libraryStore.setProfile(pid)
        watchedStore.setProfile(pid)
        collectionsStore.setProfile(pid)
        homeCatalogSettings.setProfile(pid)
        // Only rescopes when per-profile Trakt accounts are on; otherwise the
        // login stays device-wide.
        traktStore?.setProfile(pid)
    }

    // MARK: - Addons

    /// Set on any local add/remove/reorder, cleared only once a push actually
    /// lands. Guards reconciliation: pulling the account down and deleting
    /// whatever it doesn't list would destroy an add-on added on THIS device
    /// while the push was failing (offline, token expired). Dirty ⇒ push first.
    private var addonsDirty = false

    private func scheduleAddonPush() {
        addonsDirty = true
        pushAddonsTask?.cancel()
        pushAddonsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushAddons()
        }
    }

    /// Full two-way add-on sync: local changes up, then the account down with
    /// reconciliation so deletions from other devices land here.
    private func syncAddonsBothWays() async throws {
        guard account.accessToken != nil else {
            throw OrivioAuthError.message("not signed in")
        }
        if addonsDirty {
            // Local edits go first or the pull below would reconcile them away.
            try await pushAddons()
        }
        try await pullAddons()
    }

    private func pushAddons() async throws {
        guard account.accessToken != nil else { return }
        let entries: [[String: Any]] = addonManager.addons.enumerated().map { index, addon in
            var obj: [String: Any] = [
                "url": addon.manifestURL,
                "sort_order": index,
                "enabled": addon.enabled
            ]
            if !addon.manifest.name.isEmpty { obj["name"] = addon.manifest.name }
            return obj
        }
        let body: [String: Any] = [
            "p_addons": entries,
            "p_profile_id": 1,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushAddons), body: body)
        // Only now is the account known to hold this device's list, so a later
        // pull may safely reconcile against it.
        addonsDirty = false
        // A push proves this profile has add-on data on the account, which lets
        // a subsequent empty pull be read as a genuine "cleared elsewhere".
        setSeeded("addons")
    }

    private func pullAddons() async throws {
        guard let userID = account.currentUserID else {
            // Signed in far enough to hold a token but the JWT never yielded a
            // user id — silently returning here made "Refresh Add-ons" a no-op
            // with no explanation.
            throw OrivioAuthError.message("account not fully signed in")
        }
        // PostgREST select, filtered to our rows for the default profile.
        let path = "/rest/v1/addons?user_id=eq.\(userID)&profile_id=eq.1&select=url,sort_order,enabled,name"
        let data = try await authedGet(path)
        let rows = try JSONDecoder().decode([SupabaseAddon].self, from: data)
        let orderedAddons = rows.sorted { $0.sortOrder < $1.sortOrder }.map {
            AddonManager.RemoteAddonState(manifestURL: $0.url, enabled: $0.enabled)
        }
        NSLog("[OrivioAddonSync] pullAddons: %d rows for user %@", rows.count, userID)

        // Same seeded policy library/watched use. Reconciling (deleting local
        // add-ons the account doesn't list) is only correct once we know the
        // account genuinely represents this profile's add-ons — otherwise a
        // first sign-in against a fresh account would wipe the device.
        let seeded = isSeeded("addons")
        if orderedAddons.isEmpty {
            // Empty account list: only a real "removed everything elsewhere"
            // when seeded. Unseeded + empty = fresh account; keep local and let
            // the push upload it.
            guard seeded else { return }
            await addonManager.applyRemote(urls: [], reconcile: true)
            return
        }
        await addonManager.applyRemote(addons: orderedAddons, reconcile: seeded)
        setSeeded("addons")
    }

    // MARK: - Watch progress

    private var progressDirty = false

    private func pushWatchProgress() {
        progressDirty = true
        Task { [weak self] in try? await self?.pushWatchProgressAll() }
    }

    /// Pull the latest Continue Watching (and library) from the account — call
    /// on foreground so changes made on other devices show up without a
    /// relaunch. Local pushes already fire immediately on every change.
    func refreshContinueWatching() {
        guard account.accessToken != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            // Reassert not-yet-confirmed removals so the pull can't resurrect
            // them, push the deletes to the server, THEN pull the snapshot.
            await self.reconcileProgressDeletesBeforePull()
            guard self.loadPendingDeletes().isEmpty else { return }
            try? await self.pullWatchProgress()
            await self.reconcileLibraryDeletesBeforePull()
            try? await self.pullLibrary()
        }
    }

    // Removals must reach the account durably — a fire-and-forget delete that
    // hit a network blip would silently strand the row on the server, so it
    // reappears on the next full pull ("removed it, it came back"). Instead we
    // queue removals to a PERSISTED per-profile set and drain it (with the
    // key surviving app restarts) until the server confirms the delete.
    private func pendingDeletesKey() -> String { "orivio.sync.pendingWatchProgressDeletes.p\(pid)" }

    private func loadPendingDeletes() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingDeletesKey()) ?? [])
    }

    private func savePendingDeletes(_ set: Set<String>) {
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: pendingDeletesKey()) }
        else { UserDefaults.standard.set(Array(set), forKey: pendingDeletesKey()) }
    }

    /// Queue a Continue Watching removal for durable server deletion. Persists
    /// immediately (survives offline / relaunch) and kicks a drain.
    private func deleteWatchProgress(keys: [String]) {
        let trimmed = keys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        var pending = loadPendingDeletes()
        pending.formUnion(trimmed)
        savePendingDeletes(pending)
        Task { [weak self] in await self?.drainPendingDeletes() }
    }

    /// Reassert tombstones for Continue Watching removals the server hasn't
    /// confirmed, THEN flush them — so a full-snapshot pull can't resurrect a
    /// card whose delete is still retrying. The in-memory tombstone expires
    /// after 3 minutes while the persisted queue does not, so a delete that
    /// keeps failing would otherwise let the row reappear once the grace ran
    /// out. Must run before every progress pull.
    private func reconcileProgressDeletesBeforePull() async {
        let pending = loadPendingDeletes()
        if !pending.isEmpty { progressStore.tombstone(Array(pending)) }
        await drainPendingDeletes()
    }

    /// Send every queued removal to the account, clearing only what the server
    /// confirmed. Anything left (a failure, or added mid-flight) retries on the
    /// next drain — foreground, the 30s Home poll, or full sync.
    private func drainPendingDeletes() async {
        let pending = loadPendingDeletes()
        guard !pending.isEmpty, account.accessToken != nil else { return }
        let body: [String: Any] = [
            "p_keys": Array(pending),
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        do {
            _ = try await authedPost(RPC.url(RPC.deleteWatchProgress), body: body)
            var latest = loadPendingDeletes()
            latest.subtract(pending)   // keep any queued while this call was in flight
            savePendingDeletes(latest)
        } catch {
            // Leave the queue intact — a later drain retries it.
        }
    }

    private func repairAccidentalWatchHistoryClearState() {
        let hadClearState = UserDefaults.standard.bool(forKey: clearedWatchHistoryKey())
            || WatchHistoryClearState.clearedAt != nil
        guard hadClearState,
              !UserDefaults.standard.bool(forKey: repairedWatchHistoryClearKey()) else { return }

        UserDefaults.standard.removeObject(forKey: clearedWatchHistoryKey())
        savePendingDeletes([])
        savePendingWatchedDeletes([])
        UserDefaults.standard.set(true, forKey: repairedWatchHistoryClearKey())
        // Drop the clear HORIZON too. Clearing Trakt's continue-watching list
        // used to advance it, which then filtered every older row out of the
        // Trakt import and (with the rule removed above) had been deleting
        // account rows as well. The list it was protecting is empty now, so the
        // horizon has nothing left to do and is only blocking real syncing.
        WatchHistoryClearState.reset()
        // Ship the cleared state so the account stops handing this horizon back
        // to every device that pulls.
        scheduleAppPreferencesPush()
        OrivioSyncDiagnostics.record(
            .warning,
            area: "Orivio",
            "Cleared stale watch-history delete queues so account Continue Watching can pull again."
        )
    }

    /// USER-INITIATED clear of the whole watch history — Continue Watching and
    /// watched items, locally AND on the account. Marks the (synced) clear
    /// point first, so Trakt re-imports and account pulls on every install are
    /// filtered from this moment; then deletes the account rows. The prefs
    /// push carries the new clear point to the account right away.
    func clearWatchHistoryEverywhere() async {
        let clearedAt = WatchHistoryClearState.markClearedNow()
        OrivioSyncDiagnostics.record(
            .warning, area: "Orivio",
            "User cleared watch history (horizon \(clearedAt)) for profile \(pid)."
        )
        let progressKeys = progressStore.clearAllProgress(notify: false)
        let watchedItems = watchedStore.clearAll(notify: false)
        guard account.accessToken != nil else { return }
        if !progressKeys.isEmpty {
            deleteWatchProgress(keys: progressKeys)
            await drainPendingDeletes()
        }
        if !watchedItems.isEmpty {
            deleteWatchedItems(watchedItems)
            await drainPendingWatchedDeletes()
        }
        await pushAppPreferences()   // ship the clear point account-wide now
        OrivioSyncDiagnostics.record(.success, area: "Orivio", "Watch history cleared for profile \(pid).")
    }

    private func pushWatchProgressAll() async throws {
        guard account.accessToken != nil else { return }
        // Serialize OFF the main actor: this runs on every periodic progress
        // save during playback, and building dictionaries + JSON for the whole
        // history on main was a measurable playback hiccup.
        let snapshot = progressStore.serviceBackedForSync()
        let profileID = pid
        let client = clientID
        let payload = await Task.detached(priority: .utility) {
            Self.encodeWatchProgressBody(snapshot, pid: profileID, clientID: client)
        }.value
        guard let payload else { return }
        _ = try await send(endpoint: RPC.url(RPC.pushWatchProgress), method: "POST", body: payload)
        progressDirty = false
        if !snapshot.isEmpty { setSeeded("progress") }
    }

    private nonisolated static func boundedInt(_ value: Double) -> Int? {
        let jsonSafeIntegerLimit = 9_000_000_000_000_000.0
        guard value.isFinite,
              abs(value) <= jsonSafeIntegerLimit else { return nil }
        return Int(value)
    }

    private nonisolated static func milliseconds(_ seconds: Double) -> Int? {
        boundedInt((seconds * 1000).rounded())
    }

    private nonisolated static func epochMilliseconds(_ date: Date) -> Int? {
        boundedInt((date.timeIntervalSince1970 * 1000).rounded())
    }

    private nonisolated static func encodeWatchProgressBody(
        _ items: [WatchProgress], pid: Int, clientID: String
    ) -> Data? {
        let entries: [[String: Any]] = items.compactMap { wp in
            guard wp.durationSeconds > 0,
                  let position = milliseconds(wp.positionSeconds),
                  let duration = milliseconds(wp.durationSeconds),
                  let lastWatched = epochMilliseconds(wp.updatedAt) else { return nil }
            var obj: [String: Any] = [
                "content_id": wp.metaID,
                "content_type": wp.type,
                "video_id": wp.id,
                "position": position,
                "duration": duration,
                "last_watched": lastWatched,
                "progress_key": wp.id
            ]
            if let season = wp.season { obj["season"] = season }
            if let episode = wp.episode { obj["episode"] = episode }
            return obj
        }
        guard !entries.isEmpty else { return nil }
        let body: [String: Any] = [
            "p_entries": entries,
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    private var loggedWatchProgressColumns = false

    private func pullWatchProgress() async throws {
        guard account.accessToken != nil else { return }
        let data = try await authedPost(RPC.url(RPC.pullWatchProgress), body: ["p_profile_id": pid])
        // Diagnostic, ONCE per session: the columns the account actually stores
        // per row. The table holds ids and positions only — no title or artwork
        // — so every client has to resolve "tt…" into a title itself. A client
        // showing the raw id is one that isn't enriching, not a bad push.
        if !loggedWatchProgressColumns,
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let first = raw.first {
            loggedWatchProgressColumns = true
            NSLog("[OrivioSync] watch_progress columns: %@", first.keys.sorted().joined(separator: ","))
        }
        let rows = try JSONDecoder().decode([SupabaseWatchProgress].self, from: data)
        let seeded = isSeeded("progress")
        if rows.isEmpty && !seeded {
            // Fresh account: keep local app/Stremio/Trakt rows and let the
            // following push upload them instead of treating empty as deletion.
            return
        }
        // NB: after the first successful non-empty sync, an empty result is a
        // full snapshot and must reconcile deletions, e.g. when the last item
        // was removed elsewhere.

        var pulled: [WatchProgress] = rows.map { row in
            WatchProgress(
                id: row.progressKey,
                metaID: row.contentID,
                type: row.contentType,
                name: "",
                poster: nil,
                background: nil,
                logo: nil,
                season: row.season,
                episode: row.episode,
                episodeTitle: nil,
                positionSeconds: Double(row.position) / 1000.0,
                durationSeconds: Double(row.duration) / 1000.0,
                streamURL: nil,
                updatedAt: Date(timeIntervalSince1970: Double(row.lastWatched) / 1000.0),
                syncSource: "nuvio"
            )
        }
        // NOTE: no clear-horizon filter here, deliberately. An earlier version
        // dropped every account row older than the watch-history clear AND
        // queued its deletion, to converge the account after a Trakt flood.
        // That was a permanent rule applied to every pull, so it also deleted
        // legitimate rows that arrive with an older timestamp — anything
        // imported from Stremio carries its ORIGINAL watch time — which is
        // exactly why Stremio Continue Watching stopped syncing. The clear
        // itself already deletes the account rows (clearWatchHistoryEverywhere),
        // so nothing here needs to re-litigate it. The horizon still filters
        // TRAKT re-imports, which is what it was built for.
        pulled = await enrichMetadata(pulled)
        let before = progressStore.continueWatching(sortMode: .recentlyWatched).count
        progressStore.replaceWithOrivioSnapshot(pulled, preserveLocalAdditions: !seeded)
        if !pulled.isEmpty { setSeeded("progress") }
        // Catch-all: any Continue Watching card still labelled with its raw
        // "tt…" id — from THIS pull or any other source — resolves now, so a
        // synced row is never shown as its IMDb id.
        await enrichRawContinueWatchingTitles()
        let after = progressStore.continueWatching(sortMode: .recentlyWatched).count
        NSLog("[OrivioCWSync] pullWatchProgress: %d rows from account, continue-watching %d -> %d",
              rows.count, before, after)
    }

    /// Resolve real titles/art for any Continue Watching row still showing a
    /// raw "tt…" id and write them back to the store (presentation only — no
    /// push, no position change). Bounded by `enrichMetadata`'s own cap.
    private func enrichRawContinueWatchingTitles() async {
        let raw = progressStore.continueWatching(sortMode: .recentlyWatched)
            .filter { isRawSyncTitle($0.name, id: $0.metaID) }
        guard !raw.isEmpty else { return }
        let enriched = await enrichMetadata(raw)
            .filter { !isRawSyncTitle($0.name, id: $0.metaID) }
        guard !enriched.isEmpty else { return }
        progressStore.applyEnrichedMetadata(enriched)
    }

    /// The backend stores no titles/artwork with progress, so pulled Continue
    /// Watching rows arrive bare. Fill them in from a meta addon (Cinemeta) so
    /// the cards render, best-effort and capped.
    private func enrichMetadata(_ entries: [WatchProgress]) async -> [WatchProgress] {
        // The "Enrich Continue Watching" setting gates ONLY the optional artwork
        // backfill for rows that already have a real title (leaner: fewer
        // meta-addon calls). A raw "tt…" id is never an acceptable card title,
        // so rows still showing their IMDb id ALWAYS resolve — otherwise a row
        // synced from another device (which arrives with no title) renders as
        // "tt1234567". Locally-watched rows already carry name + art.
        let enrichArtwork = enrichContinueWatchingEnabled?() ?? true
        // Match ProgressStore.continueWatching: any started, unfinished item is
        // visible (no lower bound), so all of them need title/artwork.
        let visible = entries.filter { $0.fraction < 0.95 }
        // Skip metaIDs already displayed locally (they carry a name/art) — the
        // 30s Home poll must not re-hit meta addons for cards already on
        // screen; only genuinely new rows (added on another device) enrich.
        // Their name/art then flows through mergeRemote's local-field coalesce.
        let localNamed = Set(progressStore.items.values
            .filter { !isRawSyncTitle($0.name, id: $0.metaID) }
            .map(\.metaID))
        // Raw-title rows resolve unconditionally so no card shows a bare "tt…".
        let rawTitleTokens = visible
            .filter { isRawSyncTitle($0.name, id: $0.metaID) }
            .map { "\($0.metaID)|\($0.type)" }
        // Artwork-only backfill for already-titled rows is what the setting gates.
        let missingLocalTokens = enrichArtwork
            ? visible
                .filter { !localNamed.contains($0.metaID) }
                .map { "\($0.metaID)|\($0.type)" }
            : []
        let ids = Array(NSOrderedSet(array: rawTitleTokens + missingLocalTokens).compactMap { $0 as? String }).prefix(30)
        var metaByID: [String: MetaItem] = [:]
        for token in ids {
            let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if let meta = await resolveSyncMetadata(id: parts[0], type: parts[1]) {
                metaByID[parts[0]] = meta
            }
        }
        guard !metaByID.isEmpty else { return entries }
        return entries.map { wp in
            guard let meta = metaByID[wp.metaID] else { return wp }
            let video = meta.videos?.first { $0.id == wp.id }
                ?? meta.videos?.first { $0.season == wp.season && $0.episode == wp.episode }
            return WatchProgress(
                id: wp.id,
                metaID: wp.metaID,
                type: wp.type,
                name: meta.name,
                poster: meta.poster,
                background: meta.background,
                logo: meta.logo,
                season: wp.season,
                episode: wp.episode,
                episodeTitle: video?.title ?? wp.episodeTitle,
                episodeThumbnail: video?.thumbnail ?? wp.episodeThumbnail,
                positionSeconds: wp.positionSeconds,
                durationSeconds: wp.durationSeconds,
                streamURL: wp.streamURL,
                streamSignature: wp.streamSignature,
                updatedAt: wp.updatedAt,
                syncSource: wp.syncSource,
                hasNewEpisode: wp.hasNewEpisode
            )
        }
    }

    // MARK: - Library

    private func scheduleLibraryPush() {
        libraryDirty = true
        pushLibraryTask?.cancel()
        pushLibraryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushLibrary()
        }
    }

    /// Set on any local library edit, cleared only once a push actually lands.
    /// Dirty ⇒ push BEFORE pulling: the library push is full-replace and the
    /// pull reconciles, so a pull that ran first would restore whatever the
    /// debounced push hadn't uploaded yet — and the following push would then
    /// re-upload the row the user had just removed (the remove/re-add
    /// ping-pong). Addons and profiles already work this way.
    private var libraryDirty = false

    // The library push is upsert-with-replace and has no per-item delete RPC,
    // so a removal only reaches the account as an ABSENCE from the next push.
    // That made removals the most fragile thing in the whole sync: if the app
    // was killed inside the 1.2s debounce, or the push failed once (offline,
    // token refresh), nothing anywhere remembered the deletion — the in-memory
    // tombstone died with the process and the next pull re-added the item
    // permanently. Queue removals to a PERSISTED per-profile set, exactly like
    // Continue Watching and watched items, and keep them until a push confirms.
    private func pendingLibraryDeletesKey() -> String {
        "orivio.sync.pendingLibraryDeletes.p\(pid)"
    }

    private func loadPendingLibraryDeletes() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingLibraryDeletesKey()) ?? [])
    }

    private func savePendingLibraryDeletes(_ set: Set<String>) {
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: pendingLibraryDeletesKey()) }
        else { UserDefaults.standard.set(Array(set), forKey: pendingLibraryDeletesKey()) }
    }

    private func queueLibraryDeletes(_ items: [SavedLibraryItem]) {
        var keys = Set(items.map(\.key))
        for item in items where item.id.hasPrefix("tt") {
            let alternateType = item.type == "series" ? "movie" : "series"
            keys.insert("\(alternateType)|\(item.id)")
        }
        guard !keys.isEmpty else { return }
        var pending = loadPendingLibraryDeletes()
        pending.formUnion(keys)
        savePendingLibraryDeletes(pending)
    }

    private func libraryDeletePayload(from keys: Set<String>) -> [[String: String]] {
        keys.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return ["content_id": parts[1], "content_type": parts[0]]
        }
    }

    private func ignoresMissingRPC(_ error: Error) -> Bool {
        guard case OrivioAuthError.http(let status, let body) = error else { return false }
        return [400, 404].contains(status)
            && (body.localizedCaseInsensitiveContains("could not find the function")
                || body.localizedCaseInsensitiveContains("pgrst202")
                || body.localizedCaseInsensitiveContains("schema cache"))
    }

    private func staleAlternateLibraryDeleteKeys(for items: [SavedLibraryItem]) -> Set<String> {
        var keys: Set<String> = []
        for item in items where item.id.hasPrefix("tt") {
            let alternateType = item.type == "series" ? "movie" : "series"
            keys.insert("\(alternateType)|\(item.id)")
        }
        return keys
    }

    private func deleteLibraryItems(keys: Set<String>) async throws {
        let payload = libraryDeletePayload(from: keys)
        guard !payload.isEmpty else { return }
        do {
            _ = try await authedPost(
                RPC.url(RPC.deleteLibraryItems),
                body: [
                    "p_keys": payload,
                    "p_profile_id": pid,
                    "p_origin_client_id": clientID
                ]
            )
        } catch {
            guard ignoresMissingRPC(error) else { throw error }
        }
    }

    /// Reassert tombstones for removals the account hasn't confirmed, then flush
    /// the pending push — so a pull can neither resurrect them locally nor feed
    /// them back into the next upload.
    private func reconcileLibraryDeletesBeforePull() async {
        let pending = loadPendingLibraryDeletes()
        if !pending.isEmpty { libraryStore.tombstone(Array(pending)) }
        if libraryDirty || !pending.isEmpty {
            try? await pushLibrary()
        }
    }

    private func metadataTypes(for type: String, id: String) -> [String] {
        let normalized = type.lowercased()
        let preferred = ["series", "tv", "show", "tvshow"].contains(normalized) ? "series" : "movie"
        guard id.hasPrefix("tt") else { return [preferred] }
        return preferred == "series" ? ["series", "movie"] : ["movie", "series"]
    }

    private func isRawSyncTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == id { return true }
        if trimmed.hasPrefix("tt") && trimmed.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    private func isUsefulMetadata(_ meta: MetaItem, for id: String) -> Bool {
        (!meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meta.name != id)
        || meta.poster != nil
        || meta.background != nil
    }

    private func resolveSyncMetadata(id: String, type: String) async -> MetaItem? {
        let cinemeta = AddonManager.bundledCinemeta()
        for lookupType in metadataTypes(for: type, id: id) {
            if let meta = try? await StremioAPI.meta(addon: cinemeta, type: lookupType, id: id),
               isUsefulMetadata(meta, for: id) {
                return meta
            }
        }
        return nil
    }

    private func enrichLibraryMetadata(_ items: [SavedLibraryItem]) async -> [SavedLibraryItem] {
        let rawTitleItems = items.filter { isRawSyncTitle($0.name, id: $0.id) }
        let rawTitleKeys = Set(rawTitleItems.map(\.key))
        let artworkItems = items.filter { item in
            !rawTitleKeys.contains(item.key) && (item.poster == nil || item.background == nil)
        }
        let candidates = rawTitleItems + Array(artworkItems.prefix(30))
        guard !candidates.isEmpty else { return items }

        var metaByKey: [String: MetaItem] = [:]
        for item in candidates {
            guard metaByKey[item.key] == nil else { continue }
            if let meta = await resolveSyncMetadata(id: item.id, type: item.type) {
                metaByKey[item.key] = meta
            }
        }
        guard !metaByKey.isEmpty else { return items }
        return items.map { item in
            guard let meta = metaByKey[item.key] else { return item }
            return item.withFallbackMetadata(meta)
        }
    }

    private func pushLibrary() async throws {
        guard account.accessToken != nil else { return }
        let rawItems = libraryStore.allForSync()
        let items = await enrichLibraryMetadata(rawItems)
        if items != rawItems { libraryStore.mergeRemote(items, reconcile: false) }
        let pendingDeletes = loadPendingLibraryDeletes()
        // `sync_push_library` is replace-semantics (like the addon push), so an
        // empty push is how "removed my last saved item" reaches the account.
        // But only send empty AFTER a successful pull this session — otherwise a
        // cold start (local empty, not yet reconciled) could wipe the account.
        //
        // …OR when this device has a QUEUED REMOVAL. `pulledLibraryProfiles` is
        // in-memory, so removing your last saved item before the session's first
        // pull skipped the push entirely and left nothing to retry — the item
        // came straight back. A pending delete is positive proof the user
        // removed it here, which is exactly the evidence the cold-start guard
        // was missing.
        guard !items.isEmpty || pulledLibraryProfiles.contains(pid) || !pendingDeletes.isEmpty
        else { return }
        let entries: [[String: Any]] = items.compactMap { item in
            guard let addedAt = Self.epochMilliseconds(item.addedAt) else { return nil }
            var obj: [String: Any] = [
                "content_id": item.id,
                "content_type": item.type,
                "name": item.name,
                "title": item.name,
                "poster_shape": item.posterShape,
                "genres": item.genres,
                "added_at": addedAt
            ]
            if let poster = item.poster { obj["poster"] = poster }
            if let background = item.background { obj["background"] = background }
            if let description = item.description { obj["description"] = description }
            if let releaseInfo = item.releaseInfo { obj["release_info"] = releaseInfo }
            if let rating = item.imdbRating { obj["imdb_rating"] = rating }
            if let base = item.addonBaseURL { obj["addon_base_url"] = base }
            return obj
        }
        let body: [String: Any] = [
            "p_items": entries,
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushLibrary), body: body)
        let accountDeleteKeys = pendingDeletes.union(staleAlternateLibraryDeleteKeys(for: items))
        try await deleteLibraryItems(keys: accountDeleteKeys)
        // The push landed, so the account now holds exactly `items` — every
        // queued removal it doesn't contain is done. (Replace semantics mean an
        // absence IS the delete.) Subtract only the snapshot we captured above,
        // so a removal made while this call was in flight still retries.
        if !pendingDeletes.isEmpty {
            var latest = loadPendingLibraryDeletes()
            latest.subtract(pendingDeletes)
            savePendingLibraryDeletes(latest)
        }
        // Only now is the account known to hold this device's list, so a later
        // pull may safely reconcile against it.
        libraryDirty = false
        if !items.isEmpty { setSeeded("library") }
    }

    private func pullLibrary() async throws {
        guard account.accessToken != nil else { return }
        var offset = 0
        let pageSize = 500
        var collected: [SavedLibraryItem] = []
        while true {
            let data = try await authedPost(
                RPC.url(RPC.pullLibrary),
                body: ["p_profile_id": pid, "p_limit": pageSize, "p_offset": offset]
            )
            let page = try JSONDecoder().decode([SupabaseLibraryItem].self, from: data)
            let pageItems = page.map { row in
                SavedLibraryItem(
                    id: row.contentID,
                    type: row.contentType,
                    name: row.name,
                    poster: row.poster,
                    posterShape: row.posterShape,
                    background: row.background,
                    description: row.description,
                    releaseInfo: row.releaseInfo,
                    imdbRating: row.imdbRating,
                    genres: row.genres,
                    addonBaseURL: row.addonBaseURL,
                    addedAt: Date(timeIntervalSince1970: Double(row.addedAt) / 1000.0)
                )
            }
            collected.append(contentsOf: await enrichLibraryMetadata(pageItems))
            if page.count < pageSize { break }
            offset += pageSize
        }
        // A successful pull (even an empty one) marks local as reconciled, so a
        // subsequent empty push is a genuine "cleared my library", not a race.
        pulledLibraryProfiles.insert(pid)
        if collected.isEmpty {
            // Empty snapshot: reconcile (delete local stale rows) only if this
            // profile has synced library data before — "the last item was
            // removed elsewhere". Unseeded = fresh account: keep local, the
            // following push uploads it.
            guard isSeeded("library") else { return }
            libraryStore.mergeRemote([])
            return
        }
        // First-ever pull for this profile merges additively (union → pushed
        // up); once seeded, pulls reconcile so removals propagate.
        let seeded = isSeeded("library")
        libraryStore.mergeRemote(collected, reconcile: seeded)
        setSeeded("library")
    }

    // MARK: - Watched items

    private func scheduleWatchedPush() {
        pushWatchedTask?.cancel()
        pushWatchedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushWatchedItems()
        }
    }

    // Watched removals reach the account durably, exactly like Continue
    // Watching: the push is upsert-only (it can't express a deletion), so an
    // un-marked item would resurrect on the next pull. Queue removals to a
    // PERSISTED per-profile set and drain them through
    // `sync_delete_watched_items` (the same RPC the Android app uses) until the
    // server confirms. Each token encodes content_id / season / episode.
    private func pendingWatchedDeletesKey() -> String { "orivio.sync.pendingWatchedDeletes.p\(pid)" }
    private static let watchedDeleteSeparator = "\u{1F}"

    private func loadPendingWatchedDeletes() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingWatchedDeletesKey()) ?? [])
    }

    private func savePendingWatchedDeletes(_ set: Set<String>) {
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: pendingWatchedDeletesKey()) }
        else { UserDefaults.standard.set(Array(set), forKey: pendingWatchedDeletesKey()) }
    }

    private func watchedDeleteToken(_ item: WatchedItem) -> String {
        [item.contentID, item.season.map(String.init) ?? "", item.episode.map(String.init) ?? ""]
            .joined(separator: Self.watchedDeleteSeparator)
    }

    /// The WatchedStore key for a queued token, so a pull can be tombstoned.
    private func watchedKey(forToken token: String) -> String? {
        let parts = token.components(separatedBy: Self.watchedDeleteSeparator)
        guard parts.count == 3 else { return nil }
        return WatchedItem.key(contentID: parts[0], season: Int(parts[1]), episode: Int(parts[2]))
    }

    private func deleteWatchedItems(_ items: [WatchedItem]) {
        let tokens = items.map { watchedDeleteToken($0) }
        guard !tokens.isEmpty else { return }
        var pending = loadPendingWatchedDeletes()
        pending.formUnion(tokens)
        savePendingWatchedDeletes(pending)
        Task { [weak self] in await self?.drainPendingWatchedDeletes() }
    }

    /// Send every queued watched removal, clearing only what the server
    /// confirmed. Payload mirrors the Android app: `p_keys` is an array of
    /// `{content_id, season, episode}` (season/episode null for movies).
    private func drainPendingWatchedDeletes() async {
        let pending = loadPendingWatchedDeletes()
        guard !pending.isEmpty, account.accessToken != nil else { return }
        let keys: [[String: Any]] = pending.compactMap { token in
            let parts = token.components(separatedBy: Self.watchedDeleteSeparator)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return [
                "content_id": parts[0],
                "season": Int(parts[1]).map { $0 as Any } ?? NSNull(),
                "episode": Int(parts[2]).map { $0 as Any } ?? NSNull()
            ]
        }
        guard !keys.isEmpty else { return }
        let body: [String: Any] = [
            "p_keys": keys,
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        do {
            _ = try await authedPost(RPC.url(RPC.deleteWatchedItems), body: body)
            var latest = loadPendingWatchedDeletes()
            latest.subtract(pending)   // keep anything queued while this was in flight
            savePendingWatchedDeletes(latest)
        } catch {
            // Leave the queue intact — a later drain retries it.
        }
    }

    /// Flush queued watched removals and reassert their tombstones before a
    /// pull, so a not-yet-confirmed delete can't be resurrected by the snapshot.
    private func reconcileWatchedDeletesBeforePull() async {
        let pending = loadPendingWatchedDeletes()
        if !pending.isEmpty {
            watchedStore.tombstone(pending.compactMap { watchedKey(forToken: $0) })
        }
        await drainPendingWatchedDeletes()
    }

    private func pushWatchedItems() async throws {
        guard account.accessToken != nil else { return }
        let items = watchedStore.allForSync()
        guard !items.isEmpty else { return }
        let entries: [[String: Any]] = items.compactMap { item in
            guard let watchedAt = Self.epochMilliseconds(item.watchedAt) else { return nil }
            var obj: [String: Any] = [
                "content_id": item.contentID,
                "content_type": item.contentType,
                "title": item.title,
                "watched_at": watchedAt,
                "season": item.season as Any,
                "episode": item.episode as Any
            ]
            if item.season == nil { obj["season"] = NSNull() }
            if item.episode == nil { obj["episode"] = NSNull() }
            return obj
        }
        let body: [String: Any] = [
            "p_items": entries,
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushWatchedItems), body: body)
        setSeeded("watched")   // items is non-empty (guarded above)
    }

    private func pullWatchedItems() async throws {
        guard account.accessToken != nil else { return }
        var page = 1
        let pageSize = 900
        var collected: [WatchedItem] = []
        while true {
            let data = try await authedPost(
                RPC.url(RPC.pullWatchedItems),
                body: ["p_profile_id": pid, "p_page": page, "p_page_size": pageSize]
            )
            let rows = try JSONDecoder().decode([SupabaseWatchedItem].self, from: data)
            collected.append(contentsOf: rows.map { row in
                WatchedItem(
                    contentID: row.contentID,
                    contentType: row.contentType,
                    title: row.title,
                    season: row.season,
                    episode: row.episode,
                    watchedAt: Date(timeIntervalSince1970: Double(row.watchedAt) / 1000.0)
                )
            })
            if rows.count < pageSize { break }
            page += 1
        }
        if collected.isEmpty {
            // Same policy as library: an empty snapshot only reconciles when
            // this profile has synced watched data before (last item was
            // un-marked elsewhere); a fresh account keeps local history.
            guard isSeeded("watched") else { return }
            watchedStore.mergeRemote([])
            return
        }
        let seeded = isSeeded("watched")
        watchedStore.mergeRemote(collected, reconcile: seeded)
        setSeeded("watched")
    }

    // MARK: - Profiles

    /// A local profile edit is awaiting its debounced push. syncNow flushes it
    /// BEFORE pullProfiles — otherwise a just-created profile (push still
    /// pending) would be wiped by the pull's replaceRemote.
    private var profilesDirty = false

    private func scheduleProfilePush() {
        profilesDirty = true
        pushProfilesTask?.cancel()
        pushProfilesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushProfiles()
        }
    }

    private func pushProfiles() async throws {
        guard account.accessToken != nil else { return }
        let profiles = profileStore.allForSync()
        guard !profiles.isEmpty else { return }
        let entries: [[String: Any]] = profiles.map { p in
            var obj: [String: Any] = [
                "profile_index": p.id,
                "name": p.name,
                "avatar_color_hex": p.avatarColorHex,
                "uses_primary_addons": p.usesPrimaryAddons,
                "uses_primary_plugins": p.usesPrimaryPlugins
            ]
            obj["avatar_id"] = p.avatarID ?? NSNull()
            obj["avatar_url"] = p.avatarURL ?? NSNull()
            return obj
        }
        let body: [String: Any] = [
            "p_client_max_profiles": ProfileStore.maxProfiles,
            "p_profiles": entries,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushProfiles), body: body)
        profilesDirty = false   // only clear once the account actually has them
    }

    private func pullProfiles() async throws {
        guard account.accessToken != nil else { return }
        let data = try await authedPost(RPC.url(RPC.pullProfiles), body: [:])
        let rows = try JSONDecoder().decode([SupabaseProfile].self, from: data)
        if !rows.isEmpty {
            profileStore.replaceRemote(rows.map { row in
                UserProfile(
                    id: row.profileIndex,
                    name: row.name,
                    avatarColorHex: row.avatarColorHex,
                    usesPrimaryAddons: row.usesPrimaryAddons,
                    usesPrimaryPlugins: row.usesPrimaryPlugins,
                    avatarID: row.avatarID,
                    avatarURL: row.avatarURL
                )
            })
        }
        // PIN lock states are a separate table; failures here are non-fatal.
        if let lockData = try? await authedPost(RPC.url(RPC.pullProfileLocks), body: [:]),
           let locks = try? JSONDecoder().decode([SupabaseProfileLockState].self, from: lockData) {
            profileStore.applyLockStates(
                Dictionary(locks.map { ($0.profileIndex, $0.pinEnabled) }, uniquingKeysWith: { $1 })
            )
        }
    }

    /// Re-scope the personal-data stores to the newly-selected profile and run a
    /// FULL two-way sync for it. This must be the same pull+push cycle sign-in
    /// gets — the old pull-only version meant a non-primary profile's local data
    /// (progress, library, watched, collections, layout) never uploaded except
    /// item-by-item on later changes, so "profile 2 doesn't sync" while the
    /// profile active at sign-in (usually 1) worked fully. Local scoping happens
    /// even when signed out.
    private func handleProfileSwitch(_ id: Int) {
        progressStore.setProfile(id)
        libraryStore.setProfile(id)
        watchedStore.setProfile(id)
        collectionsStore.setProfile(id)
        homeCatalogSettings.setProfile(id)
        traktStore?.setProfile(id)
        guard account.accessToken != nil else { return }
        // Serialize behind any in-flight full sync (e.g. picking a profile at
        // the gate while the sign-in sync is still running) so two cycles can't
        // interleave their pulls/pushes across different profiles.
        let previous = fullSyncTask
        fullSyncTask = Task { [weak self] in
            await previous?.value
            // An auto-sync tick is NOT tracked by `fullSyncTask`, so waiting on
            // `previous` alone can still land inside a running sync — whose
            // `guard !isSyncing` would silently drop this one and leave the
            // newly-selected profile unsynced until the next 30s tick. Wait for
            // the in-flight run to clear; it abandons itself as soon as it
            // notices the switch, so this is a short wait in practice.
            for _ in 0..<100 {
                guard let self, self.isSyncing else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await self?.syncNow()
        }
    }

    // MARK: - Collections

    private func scheduleCollectionsPush() {
        pushCollectionsTask?.cancel()
        pushCollectionsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushCollections()
        }
    }

    private func pushCollections() async throws {
        guard account.accessToken != nil else { return }
        // The RPC replaces the whole blob; ship the JSON array as-is.
        let json = collectionsStore.exportJSON()
        let collectionsValue = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? []
        let body: [String: Any] = [
            "p_profile_id": pid,
            "p_collections_json": collectionsValue,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushCollections), body: body)
        NSLog("[OrivioCollections] pushed %d collections to the shared table (p%d)",
              (collectionsValue as? [Any])?.count ?? 0, pid)
    }

    /// Whether the one-time "adopt every profile's collections into the shared
    /// library" scan has run. That scan pulls EVERY profile's row (1.4 MB and
    /// ~1000 folders on a real account) and is only needed to migrate packs
    /// that predate the shared library — repeating it on every 30s sync froze
    /// the Apple TV 4K gen 1.
    private var adoptedAllProfileCollections = false

    private func pullCollections() async throws {
        guard let userID = account.currentUserID else { return }
        // Steady state: just this profile's row, like every other pull.
        guard !adoptedAllProfileCollections else {
            try await pullCollectionsForActiveProfile()
            return
        }
        adoptedAllProfileCollections = true
        // Collections are now an ACCOUNT-WIDE library. The backing table is
        // still keyed per profile (and Android writes it that way), so read
        // EVERY profile's row and merge them — that's what makes a pack added
        // on one profile ("Kaptain's Collection" lives on profile 6) show up on
        // all of them. Per-profile choice is visibility only, synced separately.
        let path = "/rest/v1/collections?user_id=eq.\(userID)&select=profile_id,collections_json"
        let data = try await authedGet(path)
        // Decode OFF the main actor. This is ~1.4 MB of deeply nested JSON and
        // the lenient per-element decode is slow; doing it inline on the
        // @MainActor store blocked the UI hard enough that a 3 GB Apple TV
        // appeared frozen at launch and the sign-in screen never responded.
        let adopted: [OrivioCollection] = await Task.detached(priority: .utility) {
            guard let rows = try? JSONDecoder().decode([SupabaseCollectionsRow].self, from: data)
            else { return [] }
            var out: [OrivioCollection] = []
            for row in rows.sorted(by: { $0.profileID < $1.profileID }) {
                guard let json = row.collectionsJSON.data(using: .utf8),
                      let lenient = try? JSONDecoder().decode([Lenient<OrivioCollection>].self, from: json)
                else { continue }
                out.append(contentsOf: lenient.compactMap(\.value))
            }
            return out
        }.value
        NSLog("[OrivioCollections] one-time adoption: %d collections from all profiles", adopted.count)
        guard !adopted.isEmpty else { return }
        let changed = collectionsStore.mergeIntoLibrary(adopted)
        NSLog("[OrivioCollections] shared library now %d collections (changed=%@)",
              collectionsStore.library.count, changed ? "yes" : "no")
    }

    /// Steady-state pull: only the active profile's row, decoded off-main.
    private func pullCollectionsForActiveProfile() async throws {
        guard account.accessToken != nil else { return }
        let data = try await authedPost(RPC.url(RPC.pullCollections), body: ["p_profile_id": pid])
        let decoded: [OrivioCollection]? = await Task.detached(priority: .utility) {
            guard let rows = try? JSONDecoder().decode([SupabaseCollectionsBlob].self, from: data),
                  let blob = rows.first,
                  let json = blob.collectionsJSON.data(using: .utf8),
                  let lenient = try? JSONDecoder().decode([Lenient<OrivioCollection>].self, from: json)
            else { return nil }
            return lenient.compactMap(\.value)
        }.value
        guard let decoded, !decoded.isEmpty else { return }
        collectionsStore.mergeIntoLibrary(decoded)
    }

    // MARK: - Home catalog settings

    private func scheduleHomeCatalogPush() {
        pushHomeCatalogTask?.cancel()
        pushHomeCatalogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushHomeCatalogSettings()
        }
    }

    private func pushHomeCatalogSettings() async throws {
        guard account.accessToken != nil else { return }
        // The account-wide LIBRARY, not `collections` (this profile's visible
        // subset). The home-catalog blob is shared by every profile and device,
        // so exporting the visible subset let a profile that hides a collection
        // delete that collection's row position for all the others.
        let payload = homeCatalogSettings.exportPayload(
            addons: addonManager.catalogAddons,
            collections: collectionsStore.library
        )
        guard let encoded = try? JSONEncoder().encode(payload),
              let localJSON = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }

        // Android merges the remote row's keys under the local payload so
        // settings other platforms store in this blob survive our push.
        var merged = localJSON
        if let remote = try? await fetchHomeCatalogBlob(platform: HomeCatalogPlatform.shared),
           let remoteJSON = try? JSONSerialization.jsonObject(with: Data(remote.settingsJSON.utf8)) as? [String: Any] {
            merged = remoteJSON.merging(localJSON) { _, local in local }
        }

        let body: [String: Any] = [
            "p_profile_id": pid,
            "p_settings_json": merged,
            "p_platform": HomeCatalogPlatform.shared,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushHomeCatalogSettings), body: body)
    }

    private func pullHomeCatalogSettings() async throws {
        guard account.accessToken != nil else { return }
        // Prefer the shared row; fall back to newest non-empty legacy row
        // (Android clients that predate the shared platform tag).
        var best: SyncHomeCatalogPayload?
        if let blob = try? await fetchHomeCatalogBlob(platform: HomeCatalogPlatform.shared),
           let payload = decodeHomeCatalogPayload(blob), !payload.isEmpty {
            best = payload
        } else {
            var newest: (payload: SyncHomeCatalogPayload, updatedAt: String)?
            for platform in HomeCatalogPlatform.legacy {
                guard let blob = try? await fetchHomeCatalogBlob(platform: platform),
                      let payload = decodeHomeCatalogPayload(blob), !payload.isEmpty else { continue }
                let stamp = blob.updatedAt ?? ""
                if newest == nil || stamp > newest!.updatedAt {
                    newest = (payload, stamp)
                }
            }
            best = newest?.payload
        }
        guard let payload = best else { return }   // nothing remote: keep local
        homeCatalogSettings.applyRemote(payload)
    }

    private func fetchHomeCatalogBlob(platform: String) async throws -> SupabaseHomeCatalogSettingsBlob? {
        let data = try await authedPost(
            RPC.url(RPC.pullHomeCatalogSettings),
            body: ["p_profile_id": pid, "p_platform": platform]
        )
        return try JSONDecoder().decode([SupabaseHomeCatalogSettingsBlob].self, from: data).first
    }

    private func decodeHomeCatalogPayload(_ blob: SupabaseHomeCatalogSettingsBlob) -> SyncHomeCatalogPayload? {
        try? JSONDecoder().decode(SyncHomeCatalogPayload.self, from: Data(blob.settingsJSON.utf8))
    }

    // MARK: - Avatars & PIN

    private func loadAvatarCatalog() async throws -> [AvatarCatalogItem] {
        if !avatarCatalogCache.isEmpty { return avatarCatalogCache }
        guard account.accessToken != nil else { return [] }
        let data = try await authedPost(RPC.url("get_avatar_catalog"), body: [:])
        let rows = try JSONDecoder().decode([SupabaseAvatarCatalogItem].self, from: data)
        let base = OrivioConfig.avatarPublicBaseURL.hasSuffix("/")
            ? String(OrivioConfig.avatarPublicBaseURL.dropLast()) : OrivioConfig.avatarPublicBaseURL
        let catalog = rows.map { row in
            AvatarCatalogItem(
                id: row.id,
                displayName: row.displayName,
                imageURL: base + "/" + row.storagePath,
                category: row.category,
                sortOrder: row.sortOrder,
                bgColor: row.bgColor
            )
        }
        avatarCatalogCache = catalog
        return catalog
    }

    private func verifyProfilePin(id: Int, pin: String) async throws -> PinVerifyOutcome {
        let data = try await authedPost(RPC.url(RPC.verifyProfilePin), body: ["p_profile_id": id, "p_pin": pin])
        let rows = try JSONDecoder().decode([PinVerifyRow].self, from: data)
        if let row = rows.first {
            return PinVerifyOutcome(unlocked: row.unlocked, retryAfterSeconds: row.retryAfterSeconds)
        }
        return PinVerifyOutcome(unlocked: false, retryAfterSeconds: 0)
    }

    private func setProfilePin(id: Int, pin: String, currentPin: String?) async -> PinSetOutcome {
        var body: [String: Any] = ["p_profile_id": id, "p_pin": pin]
        if let currentPin, !currentPin.isEmpty { body["p_current_pin"] = currentPin }
        do {
            _ = try await authedPost(RPC.url(RPC.setProfilePin), body: body)
            return .success
        } catch OrivioAuthError.http(_, let responseBody) {
            if responseBody.localizedCaseInsensitiveContains("current pin is required") {
                return .currentPinRequired
            }
            return .failure("Couldn't set PIN.")
        } catch {
            return .failure("Couldn't set PIN.")
        }
    }

    private func clearProfilePin(id: Int, currentPin: String?) async throws -> Bool {
        var body: [String: Any] = ["p_profile_id": id]
        if let currentPin, !currentPin.isEmpty { body["p_current_pin"] = currentPin }
        _ = try await authedPost(RPC.url(RPC.clearProfilePin), body: body)
        return true
    }

    // MARK: - Networking

    // MARK: - Badge settings (profile settings blob, Android-compatible)

    /// Platform tags other Orivio apps may have pushed their settings blob
    /// under. Badges configured in the MOBILE app (Fusion) live in that
    /// platform's blob, not the TV one — check them all, TV first.
    private static let settingsBlobPlatforms = ["tv", "mobile", "fusion", "ios", "desktop", "web"]

    /// Pull the profile settings blob(s) and apply the
    /// `stream_badge_settings` feature — the Badger/Fusion badge pack
    /// configured on any device. Returns a human-readable status for the
    /// Settings card's manual sync button.
    @discardableResult
    private func pullBadgeSettings() async -> String {
        guard let streamBadges else { return "Badge store unavailable" }
        guard account.accessToken != nil else { return "Sign in to your Orivio account first" }
        // Collect EVERY platform blob that carries a badge config, so the user
        // can pick between badge profiles instead of silently taking the first.
        var found: [(platform: String, rules: String, count: Int)] = []
        var sawAnyBlob = false
        for platform in Self.settingsBlobPlatforms {
            guard let data = try? await authedPost(
                RPC.url(RPC.pullProfileSettingsBlob),
                body: ["p_profile_id": pid, "p_platform": platform]
            ) else { continue }
            guard let blob = Self.settingsBlob(from: data) else { continue }
            sawAnyBlob = true
            guard let features = blob["features"] as? [String: Any],
                  let badgeFeature = features["stream_badge_settings"] as? [String: Any],
                  let rulesJSON = Self.preferenceString(badgeFeature["stream_badge_rules"])
            else { continue }
            // Count filters in the active import for the picker label.
            var count = 0
            if let d = rulesJSON.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let imports = root["imports"] as? [[String: Any]] {
                let active = imports.first { ($0["isActive"] as? Bool) == true } ?? imports.first
                count = (active?["filters"] as? [[String: Any]])?.count ?? 0
            }
            if count > 0 { found.append((platform, rulesJSON, count)) }
        }
        streamBadges.setRemoteRules(Dictionary(found.map { ($0.platform, $0.rules) }, uniquingKeysWith: { a, _ in a }))
        guard !found.isEmpty else {
            NSLog("[OrivioBadges] no badge rules in any settings blob (sawAnyBlob=%d)", sawAnyBlob ? 1 : 0)
            return sawAnyBlob
                ? "Your account has settings, but no badge config — import one in any Orivio app first"
                : "No synced settings found on this account"
        }
        NSLog("[OrivioBadges] %d badge profiles found across %d blobs", streamBadges.remoteProfiles.count, found.count)
        streamBadges.applyChosenRemoteProfile()
        return streamBadges.isConfigured
            ? "Synced \(streamBadges.filterCount) badge filters (\(streamBadges.remoteProfiles.count) profiles on account)"
            : "Badge config had no usable filters"
    }


    /// Rows may arrive as an array or a bare object; settings_json may be an
    /// object or a double-encoded JSON string. Accept all of it.
    private static func settingsBlob(from data: Data) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let row: [String: Any]?
        if let rows = parsed as? [[String: Any]] {
            row = rows.first
        } else {
            row = parsed as? [String: Any]
        }
        guard let row else { return nil }
        if let blob = row["settings_json"] as? [String: Any] { return blob }
        if let text = row["settings_json"] as? String,
           let data = text.data(using: .utf8),
           let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return blob
        }
        // Row IS the blob (RPC returned the jsonb directly).
        if row["features"] != nil { return row }
        return nil
    }

    /// A blob preference is usually {type,value}; tolerate a bare string too.
    private static func preferenceString(_ entry: Any?) -> String? {
        if let dict = entry as? [String: Any], let value = dict["value"] as? String { return value }
        return entry as? String
    }

    private func scheduleBadgeSettingsPush() {
        pushBadgeSettingsTask?.cancel()
        pushBadgeSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushBadgeSettings()
        }
    }

    /// Push our badge config into the account. READ-MERGE-WRITE: fetch the
    /// current blob, replace only the stream_badge_settings feature, push the
    /// whole thing back — never clobbers the other features Android put there.
    private func pushBadgeSettings() async {
        guard let streamBadges, account.accessToken != nil,
              let rulesJSON = streamBadges.syncRulesJSON() else { return }

        var blob: [String: Any] = ["version": 1, "features": [String: Any]()]
        if let data = try? await authedPost(
            RPC.url(RPC.pullProfileSettingsBlob),
            body: ["p_profile_id": pid, "p_platform": Self.settingsBlobPlatform]
        ),
           let existing = Self.settingsBlob(from: data) {
            blob = existing
        }
        var features = blob["features"] as? [String: Any] ?? [:]
        var badgeFeature = features["stream_badge_settings"] as? [String: Any] ?? [:]
        badgeFeature["stream_badge_rules"] = ["type": "string", "value": rulesJSON]
        features["stream_badge_settings"] = badgeFeature
        blob["features"] = features
        if blob["version"] == nil { blob["version"] = 1 }

        let body: [String: Any] = [
            "p_profile_id": pid,
            "p_settings_json": blob,
            "p_platform": Self.settingsBlobPlatform,
            "p_origin_client_id": clientID,
        ]
        _ = try? await authedPost(RPC.url(RPC.pushProfileSettingsBlob), body: body)
    }

    // MARK: - App preferences (player / TMDB / theme)

    /// Own-feature key inside the profile settings blob. tvOS-specific — Android
    /// ignores it — so pushing it can never clobber the app's shared features.
    private static let appPrefsFeatureKey = "nuvio_tvos_preferences"

    /// The synced slice of local app preferences.
    private struct AppPreferencesSnapshot: Codable {
        var version = 1
        var player: PlayerSettings
        var tmdb: TMDBSettings
        var theme: ThemeSnapshot
        /// Home/Continue-Watching presentation prefs. Optional so blobs written
        /// before this field decode cleanly.
        var home: HomePresentationSnapshot?
        /// Debrid provider keys + preferred. Optional for backward-compat.
        var debrid: DebridStore.DebridSnapshot?
        /// Installed plugin repository URLs. Optional for backward-compat.
        var plugins: PluginStore.PluginSyncSnapshot?
        /// P2P / TorrServer settings. Optional for backward-compat.
        var torrent: TorrentSettings?
        /// Custom collections (grouped catalog home rows). Synced HERE (not via
        /// the dedicated sync_*_collections RPCs, which the shared backend
        /// doesn't provide) so they round-trip through the same reliable
        /// tvOS-preferences feature the rest of the port-only data uses.
        /// Optional for backward-compat.
        var collections: [OrivioCollection]?
        /// Collection ids THIS profile has switched off. The collections above
        /// are the account-wide library; this is the per-profile opt-out, so a
        /// newly added pack shows everywhere until a profile turns it off.
        var hiddenCollectionIDs: [String]?
        /// Folder ids this profile switched off (e.g. keep Streaming Services
        /// but drop HBO Max).
        var hiddenFolderIDs: [String]?
        /// Folder ids switched off account-wide — the catalog default that all
        /// profiles inherit and can trim further.
        var globalHiddenFolderIDs: [String]?
        /// Whole collections switched off account-wide.
        var globalHiddenCollectionIDs: [String]?
        /// When the user last cleared watch history, synced so EVERY install
        /// filters Trakt re-imports and account pulls by the same horizon.
        /// Container-local only, this let any other install of the app flood
        /// the account with the full Trakt history the user had cleared.
        var watchHistoryClearedAt: Date?
    }

    /// Set when a local app-pref-backed change (collections included) is waiting
    /// to be pushed; a re-sync must flush it BEFORE pulling, or the pull's
    /// applyRemote would clobber the not-yet-pushed local edit. The generation
    /// counter guards a race: a push that was already in flight when a NEWER
    /// edit arrived must not clear the flag that newer edit just set.
    ///
    /// PERSISTED across launches. The edit itself lands in UserDefaults
    /// instantly, but the push rides a 1.5s debounce plus a network round
    /// trip — and on the 2 GB Apple TV HD, tvOS jetsams the backgrounded app
    /// long before a slow push completes. With the flag in memory only, the
    /// next launch saw nothing dirty, pulled first, and applyRemote overwrote
    /// the local edit with the stale server blob: pick a theme, watch it
    /// revert to Classic a few minutes later. Now a killed-before-push edit
    /// re-flushes on the next sync BEFORE the pull, so local wins.
    private var appPreferencesDirty = UserDefaults.standard.bool(forKey: appPrefsDirtyKey) {
        didSet { UserDefaults.standard.set(appPreferencesDirty, forKey: Self.appPrefsDirtyKey) }
    }
    private static let appPrefsDirtyKey = "orivio.sync.appPrefsDirty.v1"
    private var appPrefsGeneration = 0

    private func scheduleAppPreferencesPush() {
        appPreferencesDirty = true
        appPrefsGeneration += 1
        pushAppPreferencesTask?.cancel()
        pushAppPreferencesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushAppPreferences()
        }
    }

    /// Pull the tvOS preferences feature (if present) and apply it to the three
    /// stores. Best-effort: any decode failure leaves local settings untouched.
    private func pullAppPreferences() async {
        guard account.accessToken != nil,
              let playerSettings, let tmdbSettings, let themeManager else { return }
        // A sync already PAST its "flush dirty first" step when the user picks a
        // theme would fetch the pre-change blob and apply it here — reverting
        // the pick, and then the debounced push would ship the REVERTED value,
        // making it permanent. Syncs run every 60-90s and take ~30s, so that
        // window is wide open. Snapshot the edit generation and bail if a local
        // edit landed while this pull was in flight; the pending push ships it,
        // and the next sync pulls cleanly.
        let generationAtStart = appPrefsGeneration
        guard let data = try? await authedPost(
            RPC.url(RPC.pullProfileSettingsBlob),
            body: ["p_profile_id": pid, "p_platform": Self.settingsBlobPlatform]
        ),
            let blob = Self.settingsBlob(from: data),
            let features = blob["features"] as? [String: Any],
            let feature = features[Self.appPrefsFeatureKey] as? [String: Any],
            let json = Self.preferenceString(feature["value"]),
            let snapshot = try? JSONDecoder().decode(
                AppPreferencesSnapshot.self, from: Data(json.utf8)
            )
        else { return }
        guard !appPreferencesDirty, appPrefsGeneration == generationAtStart else {
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio",
                "Skipped applying account preferences: a local change landed while pulling."
            )
            return
        }
        playerSettings.applyRemote(snapshot.player)
        tmdbSettings.applyRemote(snapshot.tmdb)
        themeManager.applyRemote(snapshot.theme)
        WatchHistoryClearState.adopt(snapshot.watchHistoryClearedAt)
        if let home = snapshot.home { homeCatalogSettings.applyRemotePresentation(home) }
        if let debrid = snapshot.debrid { debridStore?.applyRemote(debrid) }
        if let plugins = snapshot.plugins, let pluginStore {
            Task { await pluginStore.applyRemote(plugins) }
        }
        if let torrent = snapshot.torrent { torrentSettings?.applyRemote(torrent) }
        if let collections = snapshot.collections {
            // Merge rather than replace: another profile's blob may carry packs
            // this one has never seen, and the library is account-wide.
            collectionsStore.mergeIntoLibrary(collections)
        }
        collectionsStore.applyRemoteHidden(snapshot.hiddenCollectionIDs.map(Set.init))
        // Only apply when the remote blob actually CARRIES these keys. A blob
        // written before they existed decodes them as nil, and treating nil as
        // "empty" let the pull wipe a local choice before the push in the same
        // sync could upload it — which is exactly what made a folder hidden on
        // this device come back as visible.
        if let globalCollections = snapshot.globalHiddenCollectionIDs {
            collectionsStore.applyRemoteGlobalHidden(Set(globalCollections))
        }
        if snapshot.hiddenFolderIDs != nil || snapshot.globalHiddenFolderIDs != nil {
            collectionsStore.applyRemoteHiddenFolders(
                profile: Set(snapshot.hiddenFolderIDs ?? []),
                global: Set(snapshot.globalHiddenFolderIDs ?? []))
        }
    }

    /// READ-MERGE-WRITE: fetch the blob, replace only our own feature key, push
    /// it all back so the badge feature and Android's features survive intact.
    private func pushAppPreferences() async {
        guard account.accessToken != nil,
              let playerSettings, let tmdbSettings, let themeManager else { return }
        let generationAtStart = appPrefsGeneration
        let snapshot = AppPreferencesSnapshot(
            player: playerSettings.settings,
            tmdb: tmdbSettings.settings,
            theme: themeManager.snapshot,
            home: homeCatalogSettings.presentationSnapshot,
            debrid: debridStore?.snapshot,
            plugins: pluginStore?.snapshot,
            torrent: torrentSettings?.settings,
            // The shared library (every profile's collections), plus THIS
            // profile's opt-outs. Pushing the visible subset here would delete
            // other profiles' collections from the account.
            collections: collectionsStore.library,
            hiddenCollectionIDs: collectionsStore.hiddenIDsForSync,
            hiddenFolderIDs: collectionsStore.hiddenFolderIDsForSync,
            globalHiddenFolderIDs: collectionsStore.globalHiddenFolderIDsForSync,
            globalHiddenCollectionIDs: collectionsStore.globalHiddenCollectionIDsForSync,
            watchHistoryClearedAt: WatchHistoryClearState.clearedAt
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }

        var blob: [String: Any] = ["version": 1, "features": [String: Any]()]
        if let existingData = try? await authedPost(
            RPC.url(RPC.pullProfileSettingsBlob),
            body: ["p_profile_id": pid, "p_platform": Self.settingsBlobPlatform]
        ),
           let existing = Self.settingsBlob(from: existingData) {
            blob = existing
        }
        var features = blob["features"] as? [String: Any] ?? [:]
        features[Self.appPrefsFeatureKey] = ["type": "string", "value": json]
        blob["features"] = features
        if blob["version"] == nil { blob["version"] = 1 }

        let body: [String: Any] = [
            "p_profile_id": pid,
            "p_settings_json": blob,
            "p_platform": Self.settingsBlobPlatform,
            "p_origin_client_id": clientID,
        ]
        if (try? await authedPost(RPC.url(RPC.pushProfileSettingsBlob), body: body)) != nil,
           appPrefsGeneration == generationAtStart {
            // Clear only if no NEWER edit arrived while this push was in
            // flight — that edit's own flag/push must survive.
            appPreferencesDirty = false
        }
    }

    // MARK: - Provider credentials (debrid keys + Trakt) — Android table

    /// Maps our DebridProvider to the Android provider-credential name. AllDebrid
    /// isn't a synced provider on Android, so it stays blob-only.
    private static let debridProviderNames: [(DebridProvider, String)] = [
        (.realDebrid, "realdebrid"), (.premiumize, "premiumize"), (.torbox, "torbox")
    ]

    private func scheduleProviderCredentialsPush() {
        pushProviderCredentialsTask?.cancel()
        pushProviderCredentialsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushProviderCredentials()
        }
    }

    /// Push debrid API keys and the Trakt login into the shared
    /// `provider_credentials` table. Each row is
    /// `{provider, credential_json, updated_at}`; `p_credentials` carries them.
    private func pushProviderCredentials() async {
        guard account.accessToken != nil else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        var credentials: [[String: Any]] = []

        if let debridStore {
            for (provider, name) in Self.debridProviderNames {
                let key = debridStore.key(for: provider)
                guard !key.isEmpty else { continue }
                credentials.append([
                    "provider": name,
                    // snake_case matches this backend's convention; the reader is
                    // tolerant of camelCase in case a client wrote it differently.
                    "credential_json": ["api_key": key],
                    "updated_at": now
                ])
            }
        }

        if let traktStore, let access = traktStore.accessToken, let refresh = traktStore.refreshToken {
            var json: [String: Any] = ["access_token": access, "refresh_token": refresh]
            if let username = traktStore.username { json["username"] = username }
            credentials.append(["provider": "trakt", "credential_json": json, "updated_at": now])
        }

        guard !credentials.isEmpty else { return }
        let body: [String: Any] = [
            "p_credentials": credentials,
            "p_profile_id": pid,
            "p_origin_client_id": clientID
        ]
        _ = try? await authedPost(RPC.url(RPC.pushProviderCredentials), body: body)
    }

    /// Pull provider credentials and apply them. Tolerant: `credential_json` may
    /// arrive as an object or a JSON string, and inner keys may be snake- or
    /// camel-case — so debrid keys and Trakt logins added on the phone show up
    /// here regardless of exactly how that client serialized them.
    private func pullProviderCredentials() async {
        guard account.accessToken != nil else { return }
        guard let data = try? await authedPost(
            RPC.url(RPC.pullProviderCredentials), body: ["p_profile_id": pid]
        ) else { return }
        // Rows may arrive as an array or (some PostgREST configs) a bare object.
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = parsed as? [[String: Any]] { rows = array }
        else if let single = parsed as? [String: Any] { rows = [single] }
        else { return }

        // Collect debrid keys and apply them in ONE guarded applyRemote — calling
        // setKey directly fired onLocalChange (it isn't the applyingRemote path),
        // which echoed a credentials push after every pull.
        var debridKeys: [String: String] = [:]
        for row in rows {
            guard let provider = (row["provider"] as? String)?.lowercased() else { continue }
            let json = Self.credentialJSON(from: row["credential_json"])
            #if DEBUG
            NSLog("[OrivioSync] provider_credentials '%@' keys: %@", provider,
                  json.keys.sorted().joined(separator: ","))
            #endif
            if provider == "trakt" {
                let access = Self.anyString(json["access_token"] ?? json["accessToken"])
                let refresh = Self.anyString(json["refresh_token"] ?? json["refreshToken"])
                let username = Self.anyString(json["username"] ?? json["user"])
                traktStore?.applyRemote(access: access, refresh: refresh, username: username)
            } else if let match = Self.debridProviderNames.first(where: { $0.1 == provider }) {
                let key = Self.anyString(
                    json["api_key"] ?? json["apiKey"] ?? json["apikey"]
                        ?? json["token"] ?? json["access_token"] ?? json["value"]
                )
                if let key, !key.isEmpty { debridKeys[match.0.rawValue] = key }
            }
        }
        if !debridKeys.isEmpty {
            debridStore?.applyRemote(DebridStore.DebridSnapshot(keys: debridKeys, preferred: nil))
        }
    }

    /// `credential_json` tolerated as a nested object OR a JSON-encoded string.
    private static func credentialJSON(from value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        if let text = value as? String, let data = text.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }

    private static func anyString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Plugins — Android table

    /// Set on any local plugin-repo edit, cleared once a push lands. Same role
    /// as `addonsDirty`: dirty ⇒ push before pulling, so a reconcile can't
    /// restore a repo the user just removed.
    private var pluginsDirty = false

    private func schedulePluginsPush() {
        pluginsDirty = true
        pushPluginsTask?.cancel()
        pushPluginsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushPlugins()
        }
    }

    /// The profile whose plugin rows this device reads/writes. Mirrors Android:
    /// a profile flagged "uses primary plugins" shares profile 1's rows, so a
    /// push from that profile must not fork its own plugin set.
    private var pluginPID: Int {
        let active = profileStore.allForSync().first { $0.id == pid }
        return (active?.usesPrimaryPlugins ?? true) ? 1 : pid
    }

    /// Push plugin repos to the dedicated `plugins` table (`sync_push_plugins`),
    /// mirroring the Android row shape: url/name/enabled/sort_order/repo_type.
    /// tvOS scrapers are Orivio JS repos → repo_type "ORIVIO_JS".
    private func pushPlugins() async throws {
        guard account.accessToken != nil, let pluginStore else { return }
        let repos = pluginStore.repositories
        // An empty push is how "I removed my last repo" reaches the account —
        // but only when this device actually made that edit (`pluginsDirty`).
        // Blanket-skipping empty meant removing the last repo never synced and
        // the next pull put it straight back; blanket-allowing it would let a
        // fresh device wipe the account before its first pull.
        guard !repos.isEmpty || pluginsDirty else { return }
        let entries: [[String: Any]] = repos.enumerated().map { index, repo in
            [
                "url": repo.url,
                "name": repo.name,
                "enabled": repo.enabled,
                "sort_order": index,
                "repo_type": "ORIVIO_JS"
            ]
        }
        let body: [String: Any] = [
            "p_plugins": entries,
            "p_profile_id": pluginPID,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushPlugins), body: body)
        pluginsDirty = false
        if !repos.isEmpty { setSeeded("plugins") }
    }

    /// Pull plugin repos via a PostgREST table select (there's no dedicated pull
    /// RPC — the Android app reads the table directly too). tvOS only needs the
    /// URLs; PluginStore re-fetches each manifest and installs missing ones.
    private func pullPlugins() async {
        guard let userID = account.currentUserID, let pluginStore else { return }
        let path = "/rest/v1/plugins?user_id=eq.\(userID)&profile_id=eq.\(pluginPID)&select=url,repo_type,sort_order,enabled"
        guard let data = try? await authedGet(path),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let urls = rows
            .filter { ($0["repo_type"] as? String)?.uppercased() != "EXTERNAL_DEX" }  // JS only
            .filter { ($0["enabled"] as? Bool) ?? true }   // don't install repos disabled elsewhere
            .compactMap { $0["url"] as? String }
        let seeded = isSeeded("plugins")
        if urls.isEmpty {
            // Only a genuine "removed everywhere" once seeded; otherwise this is
            // a fresh account and local repos should survive to be pushed up.
            guard seeded else { return }
            await pluginStore.applyRemote(PluginStore.PluginSyncSnapshot(repositoryURLs: []),
                                          reconcile: true)
            return
        }
        await pluginStore.applyRemote(PluginStore.PluginSyncSnapshot(repositoryURLs: urls),
                                      reconcile: seeded)
        setSeeded("plugins")
    }

    private func authedPost(_ endpoint: String, body: [String: Any]) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await send(endpoint: endpoint, method: "POST", body: payload)
    }

    private func authedGet(_ endpoint: String) async throws -> Data {
        try await send(endpoint: endpoint, method: "GET", body: nil)
    }

    private func send(endpoint: String, method: String, body: Data?, isRetry: Bool = false) async throws -> Data {
        guard let token = account.accessToken else { throw OrivioAuthError.message("Not signed in.") }
        let base = OrivioConfig.supabaseURL.hasSuffix("/")
            ? String(OrivioConfig.supabaseURL.dropLast()) : OrivioConfig.supabaseURL
        guard let url = URL(string: base + endpoint) else { throw OrivioAuthError.message("Bad sync URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(OrivioConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrivioAuthError.message("No response from sync server.")
        }
        if http.statusCode == 401 && !isRetry {
            // Access token likely expired — refresh once and retry.
            if await account.refreshSession() {
                return try await send(endpoint: endpoint, method: method, body: body, isRetry: true)
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OrivioAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case OrivioAuthError.http(let code, _): return "Sync failed (HTTP \(code))."
        case OrivioAuthError.message(let m): return m
        default: return "Sync failed."
        }
    }
}
