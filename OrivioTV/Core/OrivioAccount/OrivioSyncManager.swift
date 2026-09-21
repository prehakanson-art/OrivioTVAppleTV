
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
    private let simklStore: SimklStore?
    private let ratingsStore: RatingsStore?
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
    /// The in-flight full sync (sign-in, launch or profile switch); new full
    /// syncs chain behind it so two cycles never interleave across profiles.
    private var fullSyncTask: Task<Void, Never>?

    /// The sync armed by the app being opened — a launch with a session
    /// already restored, or a return to the foreground. See `syncOnAppOpen`.
    private var openSyncTask: Task<Void, Never>?

    /// True from the moment an app-open sync is armed until it has started (or
    /// decided not to). Set SYNCHRONOUSLY, because the whole point is that the
    /// other launch-time pulls can see it before it begins: `isSyncing` only
    /// goes up once the task body reaches `syncNow`, and the foreground
    /// `refreshContinueWatching` fires in that gap — two full-snapshot pulls of
    /// progress and library, overlapping in `mergeRemote`.
    private(set) var openSyncPending = false

    /// When the last full sync finished (success or failure), and when the
    /// last app-open sync did. An app-open sync inside `openSyncFloor` of it is
    /// skipped: the picture is already current, and a quick inactive→active
    /// flip (a system overlay, the top shelf) shouldn't cost a full cycle.
    private var lastFullSyncEnded = Date.distantPast
    private static let openSyncFloor: TimeInterval = 15

    /// How long the app-open sync waits before starting.
    ///
    /// Not zero, and this is the reason a restored session used to have no
    /// launch sync at all: a full cycle is a few dozen round trips whose
    /// responses are decoded and merged ON THE MAIN ACTOR, and running that
    /// on top of app construction is what made launch unresponsive on a large
    /// library. The wait lets the first screen render and its catalogs get
    /// their requests out; after it the sync is just another background
    /// consumer. It is a settle delay, not a poll — nothing the user does
    /// shortens or triggers it, and it is orders of magnitude shorter than the
    /// 30/90s tick this replaces.
    ///
    /// The A8/A10X tier gets the same 3s the launch collection migration uses:
    /// those boxes are still decoding the first screen's posters at that point,
    /// and the pulls merge their snapshots on the main actor.
    private static var openSyncDelay: TimeInterval {
        (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? 3.0 : 1.5
    }
    /// Profiles whose library pull succeeded this session, gating empty
    /// (cleared) library pushes so a cold start — or a profile whose pull
    /// failed — can't wipe that profile's account library. See pushLibrary.
    private var pulledLibraryProfiles: Set<Int> = []
    /// Profiles whose add-on and plugin lists have been pulled from the CURRENT
    /// account at least once this session.
    ///
    /// An add-on's manifest URL routinely embeds the user's own debrid token
    /// (Torrentio and friends configure that way), so pushing the resident list
    /// into a freshly signed-in account hands that account the previous user's
    /// credentials. The identity change clears these, and the pushes below
    /// refuse to run until the new account has been read.
    private var pulledAddonProfiles: Set<Int> = []
    private var pulledPluginProfiles: Set<Int> = []

    /// A full sync was requested while one was running. It used to be
    /// DROPPED ("sync already running"), so a change made during a run —
    /// which takes tens of seconds on a big account — waited for the next
    /// 30-second tick, and a second change during THAT run waited again.
    /// Now the request is remembered and the sync runs once more when the
    /// current one ends.
    private var rerunRequested = false

    /// Profiles that have completed one full pull+push cycle this session on
    /// the current account. The FIRST cycle uploads every store whether or
    /// not it is marked dirty — that is what merges a device's pre-sign-in
    /// data into the account. After it, a store goes up only when something
    /// local changed (its dirty flag), which turns the periodic sync from a
    /// re-upload of the entire library, history and collections every 30s
    /// into a handful of small round trips.
    private var completedFullSyncProfiles: Set<Int> = []

    /// Set during a run when a pull grew the shared collections library
    /// (another profile's or device's packs merged in). Those pushes are
    /// gated on their dirty flags now, and a merge fires no change hook, so
    /// the run has to remember to upload the grown library itself.
    private var libraryGrewDuringSync = false

    /// When each profile's badge blobs were last read. Six settings-blob
    /// round trips per sync for a cosmetic chip set is too many; steady state
    /// re-reads every ten minutes, and the manual "sync badges" button is
    /// unthrottled.
    private var lastBadgePull: [Int: Date] = [:]
    private static let badgePullInterval: TimeInterval = 10 * 60

    /// The account has no `sync_delete_profile_data` (learned from a PGRST202
    /// answer this session), so profile deletions fall back to the legacy
    /// `p_deleted_profile_ids` hint on the profile push.
    private var profileDeleteRPCMissing = false
    private var legacyProfileDeleteHintMissing = false

    struct PendingSyncCounts {
        let progressDeletes: Int
        let libraryDeletes: Int
        let watchedDeletes: Int

        var total: Int { progressDeletes + libraryDeletes + watchedDeletes }
    }

    var pendingSyncCounts: PendingSyncCounts {
        PendingSyncCounts(
            progressDeletes: loadPendingDeletes(profile: pid).count,
            libraryDeletes: loadPendingLibraryDeletes(profile: pid).count,
            watchedDeletes: loadPendingWatchedDeletes(profile: pid).count
        )
    }

    // MARK: - Seeded flags
    // "Has this profile ever had <kind> data on the account?" — persisted, set
    // after any non-empty pull or push. An EMPTY pull only reconciles (deletes
    // local rows) when seeded: genuinely "everything was removed elsewhere".
    // Unseeded + empty = first sign-in with a fresh account → keep local data
    // and let the following push upload it.
    //
    // Every one of these keys takes the profile EXPLICITLY rather than reading
    // `pid`. A sync step spends seconds inside a request, and reading the
    // active profile again when the response lands is what filed one profile's
    // result under another profile's key.
    private func seededKey(_ kind: String, profile: Int) -> String { "orivio.sync.seeded.\(kind).p\(profile)" }
    private func isSeeded(_ kind: String, profile: Int) -> Bool {
        UserDefaults.standard.bool(forKey: seededKey(kind, profile: profile))
    }
    private func setSeeded(_ kind: String, profile: Int) {
        UserDefaults.standard.set(true, forKey: seededKey(kind, profile: profile))
    }
    private func clearedWatchHistoryKey(profile: Int) -> String {
        "orivio.sync.clearedWatchHistory.v1.p\(profile)"
    }
    /// Bumped whenever the repair below learns to fix something new, so it
    /// runs once more on installs where the previous version already ran.
    /// v3: also drops the clear HORIZON and pushes that up, since the account
    /// blob was handing the horizon straight back on the next pull.
    private func repairedWatchHistoryClearKey(profile: Int) -> String {
        "orivio.sync.repairedWatchHistoryClear.v3.p\(profile)"
    }

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
    /// - Parameter droppingPendingDeletes: only for a genuine ACCOUNT CHANGE.
    ///   A plain sign-out must keep the queues: the same user signing back in
    ///   still needs those removals to reach the server, and dropping them means
    ///   every row they deleted offline comes back on the next pull.
    private func resetSyncBookkeeping(droppingPendingDeletes: Bool) {
        let defaults = UserDefaults.standard
        // The device id and the diagnostics log are not account state.
        //
        // Neither is the watch-history repair stamp: it records a ONE-SHOT local
        // data repair, not an agreement with a server. Wiping it let the repair
        // run a second time on the next sign-in, which resets the user's clear
        // horizon and pushes that loss to every other device — so the history
        // they deliberately cleared floods back on the next import.
        var preserved: Set<String> = ["orivio.sync.client.v1", "orivio.sync.log.v1"]
        var preservedPrefixes = ["orivio.sync.repairedWatchHistoryClear."]
        if !droppingPendingDeletes {
            // A plain sign-out (same user expected back). The SEEDED flags stay
            // too: sweeping them made the same user's next first pull additive,
            // so everything they had deleted on another device while signed out
            // here came back, and the replace-push then re-uploaded it. A
            // different user is handled by `handleAccountIdentityChange`, which
            // passes `droppingPendingDeletes: true` and sweeps everything.
            // The collections adoption flag likewise records a one-shot scan
            // that must not repeat for the same account (re-adopting packs the
            // user has since deleted).
            preservedPrefixes.append("orivio.sync.seeded.")
            // The persisted dirty flags too: rows added while signed out are
            // pushed before the (now reconciling) first pull only if the flag
            // that says "unpushed" survives the sign-out.
            preservedPrefixes.append("orivio.sync.dirty.")
            preserved.insert(Self.adoptedCollectionsKey)
            preserved.formUnion(
                defaults.dictionaryRepresentation().keys.filter {
                    $0.hasPrefix("orivio.sync.pendingWatchProgressDeletes.")
                        || $0.hasPrefix("orivio.sync.pendingLibraryDeletes.")
                        || $0.hasPrefix("orivio.sync.pendingWatchedDeletes.")
                        // The attempt counters ride with the queues they count.
                        // (The prefix here used to name a key that never
                        // existed, so the counters were swept while the queues
                        // survived and a rejected key got a fresh five tries.)
                        || $0.hasPrefix("orivio.sync.pendingWatchProgressDeleteAttempts.")
                }
            )
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("orivio.sync.")
            && !preserved.contains(key)
            && !preservedPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        addonsDirty = false
        profilesDirty = false
        // `collections`, `homeCatalog`, `badges`, `providerCredentials`,
        // `plugins` and `appPreferences` are now persisted per profile under
        // `orivio.sync.dirty.*` (see `dirtyKey`): the sweep above already drops
        // them for a different account and preserves them for a plain sign-out,
        // so a pending edit still uploads. Nothing to clear here.
        // Whoever signs in next gets a full first cycle again.
        completedFullSyncProfiles.removeAll()
        lastBadgePull.removeAll()
        // progress / library / watched dirty flags are persisted per profile
        // (`orivio.sync.dirty.*`): the sweep above dropped them for a
        // different account and kept them for a plain sign-out.
    }

    // MARK: - Persisted per-profile dirty flags

    /// Progress, library and watched changes are pushed per PROFILE, so the
    /// flag that says "this profile has unpushed local changes" is keyed per
    /// profile — an in-memory global was cleared by whichever profile's push
    /// landed next (a switch inside the 1.2 s debounce made profile B's push
    /// clear profile A's flag, and A's mark was reconciled away). Persisted,
    /// so a kill or a sign-out between the change and its push cannot turn the
    /// next reconciling pull into a deletion.
    private func dirtyKey(_ kind: String) -> String { "orivio.sync.dirty.\(kind).v1" }
    private func isDirty(_ kind: String, profile: Int) -> Bool {
        (UserDefaults.standard.array(forKey: dirtyKey(kind)) as? [Int] ?? []).contains(profile)
    }
    private func setDirty(_ kind: String, profile: Int, _ dirty: Bool) {
        var set = Set(UserDefaults.standard.array(forKey: dirtyKey(kind)) as? [Int] ?? [])
        if dirty { set.insert(profile) } else { set.remove(profile) }
        if set.isEmpty {
            UserDefaults.standard.removeObject(forKey: dirtyKey(kind))
        } else {
            UserDefaults.standard.set(Array(set).sorted(), forKey: dirtyKey(kind))
        }
    }

    /// Set while the previous account's state is being retired, so the store
    /// callbacks that retirement fires cannot arm a push.
    ///
    /// Clearing a debrid key or signing out of Trakt calls `onLocalChange`, which
    /// is wired to `scheduleAppPreferencesPush` / `scheduleProviderCredentialsPush`
    /// — so retiring account A's credentials armed a push that then uploaded A's
    /// collections library, theme and settings into account B's profile blob,
    /// before B had been pulled even once.
    ///
    /// Now honoured by EVERY scheduler, not just those two: retiring the
    /// content stores deletes the previous account's collections, and
    /// `CollectionsStore.remove` fires `onLocalChange` — which is wired to the
    /// collections and home-catalog pushes as well, both of which would have
    /// written an emptied blob straight into the new account.
    private var isRetiringAccountState = false

    /// Drop credentials belonging to the PREVIOUS account. Both stores are
    /// account-synced and both `applyRemote` implementations only ever ADD, so
    /// without this the next `pushProviderCredentials` uploads the previous
    /// user's Trakt tokens and debrid API keys into the new user's account.
    /// Safe against wiping the new account's server rows: that push skips an
    /// empty credential set entirely.
    private func resetAccountScopedCredentials() {
        isRetiringAccountState = true
        defer { isRetiringAccountState = false }
        // EVERY profile's Trakt login, not just the active scope: with
        // per-profile Trakt on, `signOut()` cleared one `.pN` slot and the
        // others were reloaded by the next profile switch and pushed into the
        // new account's provider credentials.
        traktStore?.signOut()
        traktStore?.forgetAllProfiles()
        // SIMKL logins never reach the account's credential table, but they
        // mark the same user boundary: without this the next user keeps
        // scrobbling into the previous user's SIMKL history.
        simklStore?.signOut()
        simklStore?.forgetAllProfiles()
        // Ratings are pushed to whichever Trakt/SIMKL account is connected —
        // the previous user's stars must not follow the next user there.
        ratingsStore?.clearAllProfiles()
        // Every profile's debrid logins, not just the active scope — same
        // reasoning as Trakt's forgetAllProfiles above.
        debridStore?.forgetAllProfiles()
    }

    /// Drop the PREVIOUS account's per-profile content: Continue Watching,
    /// saved library, watched history, collections and the home-catalog layout,
    /// for EVERY profile — not just the active one.
    ///
    /// Retiring the bookkeeping alone was not enough. With the seeded flags
    /// just cleared, the new account's first pull is deliberately ADDITIVE (it
    /// must be, or a fresh account would wipe the device), so account A's rows
    /// survived the pull — and the pushes at the end of that same sync then
    /// uploaded A's library, watch progress, watched history and add-ons into
    /// B's rows. Two users' content, permanently merged on the server.
    ///
    /// Resetting is safe in the one direction that matters: A's data is already
    /// on A's account and comes back the moment A signs in again. This is what
    /// every streaming app does on an account switch.
    ///
    /// Only ever called from `handleAccountIdentityChange`, behind its
    /// "a DIFFERENT user id was recorded before" guard — never on a first
    /// sign-in and never when the same user signs back in.
    private func resetAccountScopedContentStores() {
        isRetiringAccountState = true
        defer { isRetiringAccountState = false }

        let activeProfile = pid

        func scope(to profile: Int) {
            progressStore.setProfile(profile)
            libraryStore.setProfile(profile)
            watchedStore.setProfile(profile)
            collectionsStore.setProfile(profile)
            homeCatalogSettings.setProfile(profile)
        }

        func clearScopedProfile() {
            // `notify: false` / the remote-merge paths: none of these may fire
            // the store's local-change callbacks, or the retirement itself would
            // arm a push of what it is retiring.
            // `tombstone: false` throughout: a tombstone stops a PULL bringing
            // back something the user deleted, but here it would suppress the
            // INCOMING account's rows for the whole grace period instead.
            progressStore.clearAllProgress(notify: false, tombstone: false)
            // A real clear, not `mergeRemote([], reconcile: true)`: that path
            // honours a 120s deletion grace, so anything saved in the last two
            // minutes survived and could still be pushed to the new account.
            libraryStore.clearAll(notify: false, tombstone: false)
            watchedStore.clearAll(notify: false, tombstone: false)
            // Per-profile collection/folder visibility — the library itself is
            // account-wide and is emptied once, below.
            collectionsStore.applyRemoteHidden([])
            collectionsStore.applyRemoteHiddenFolders(profile: [], global: [])
            homeCatalogSettings.applyRemote(SyncHomeCatalogPayload())
        }

        // Every profile SLOT, not just the profiles that exist right now: the
        // previous account may have used slots this one doesn't, and their data
        // sits in the same per-profile namespaces waiting to be pushed up.
        //
        // The ACTIVE profile goes LAST, and there is deliberately no
        // "restore the scope" pass afterwards. `ProgressStore.clearAllProgress`
        // persists through a detached writer while `setProfile` re-reads
        // UserDefaults synchronously, so re-scoping BACK to a profile we had
        // just cleared could load the pre-clear snapshot straight back into
        // memory — and the next save would write that resurrected history to
        // the new account.
        for profile in (1...ProfileStore.maxProfiles) where profile != activeProfile {
            scope(to: profile)
            clearScopedProfile()
        }
        scope(to: activeProfile)
        clearScopedProfile()

        // Account-wide collection state (the shared library and its global
        // opt-outs) belongs to the account being left, so it goes once — and
        // while scoped to the active profile, which is where it must end up.
        // One write, and no removal tombstones: `remove(id:)` per collection
        // recorded a tombstone for each, which would then suppress the incoming
        // account's collections sharing those ids.
        collectionsStore.clearAll()
        // Add-ons and plugin repos too. The `pulledAddonProfiles` gate below only
        // stops a push that runs BEFORE the first pull, and in `syncNow` the pull
        // always comes first — so without this the additive first pull unioned
        // the previous user's add-ons with the new account's, and the replace
        // push at the end of the same run uploaded that union (including manifest
        // URLs carrying the previous user's debrid token) into the new account.
        addonManager.clearAll()
        pluginStore?.clearAll()

        // In-memory proof that a profile's library has been pulled THIS
        // session. It belongs to the account we just left; left set, the new
        // account's first sync would be allowed to push our now-empty library
        // and wipe that profile's rows on the server before its pull landed.
        pulledLibraryProfiles.removeAll()
        pulledAddonProfiles.removeAll()
        pulledPluginProfiles.removeAll()

        NSLog("[OrivioSync] reset per-profile content stores for the previous account")
        OrivioSyncDiagnostics.record(
            .warning, area: "Orivio",
            "Cleared this device's Continue Watching, library, watched history, collections and home layout "
            + "for all \(ProfileStore.maxProfiles) profiles because a different account signed in; "
            + "the previous account's data is safe on that account."
        )
    }

    /// Retire the previous account's state when a DIFFERENT user signs in.
    /// Signing out cleared only the Supabase tokens, so the next account
    /// inherited the last one's seeded flags, queued deletes and credentials.
    /// - Parameter userID: the id of the account signing in, passed in by the
    ///   caller rather than read from `account` — see `handleAuthChange` for
    ///   why the manager's own view of it is one step behind here.
    private func handleAccountIdentityChange(userID current: String) {
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
        // Credentials FIRST, then the bookkeeping: the reset fires store
        // callbacks, and clearing the dirty flags afterwards is what guarantees
        // none of them survives as a pending upload into the new account.
        resetAccountScopedCredentials()
        // The per-profile CONTENT, before the bookkeeping reset below: this
        // step can set dirty flags and drop removal tombstones of its own, and
        // clearing the bookkeeping afterwards is what guarantees none of them
        // survives as a pending upload into the new account.
        resetAccountScopedContentStores()
        // These queues belong to the account being left; running them against
        // the new one would delete THAT user's rows. (This also drops the
        // deletes the content reset just queued, which is the point.)
        resetSyncBookkeeping(droppingPendingDeletes: true)
        // Likewise the collection removals: suppressing ids the previous user
        // deleted would hide the NEW user's collections of the same id — and
        // the reset above tombstoned every one of the previous account's.
        collectionsStore.forgetRemovalTombstones()
        // And the profile deletions still waiting to reach the previous
        // account: run against this one they would delete ITS profiles.
        profileStore.forgetProfileDeletions()
        profileDeleteRPCMissing = false
        legacyProfileDeleteHintMissing = false
        // Anything already armed before this point is also account A's — every
        // one of these pushes is scoped to the signed-in account, so letting a
        // debounced one land now uploads A's data into B.
        pushAddonsTask?.cancel()
        pushLibraryTask?.cancel()
        pushWatchedTask?.cancel()
        pushProfilesTask?.cancel()
        pushCollectionsTask?.cancel()
        pushHomeCatalogTask?.cancel()
        pushBadgeSettingsTask?.cancel()
        pushAppPreferencesTask?.cancel()
        pushProviderCredentialsTask?.cancel()
        pushPluginsTask?.cancel()
        lastPushedAppPrefs = nil
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
        /// Drops a profile row AND everything stored under it — the RPC the
        /// Android app deletes a profile with. `sync_push_profiles` only ever
        /// upserts the rows it is given, so this is the one way a deletion
        /// reaches the account.
        static let deleteProfileData = "sync_delete_profile_data"
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
        traktStore: TraktStore? = nil,
        simklStore: SimklStore? = nil,
        ratingsStore: RatingsStore? = nil
    ) {
        self.account = account
        self.ratingsStore = ratingsStore
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
        self.simklStore = simklStore

        // Sync whenever we transition into a signed-in state.
        account.$authState
            .sink { [weak self] state in self?.handleAuthChange(state) }
            .store(in: &cancellables)

        // Push local changes upward (debounced for addons/library/watched/profiles, immediate for progress).
        addonManager.onLocalChange = { [weak self] in
            self?.scheduleAddonPush()
            // An add-on's catalogs are rows in the shared home layout, and the
            // layout push is gated on its own dirty flag now (the full sync
            // used to re-upload it every run, which is how new rows got there).
            self?.scheduleHomeCatalogPush()
        }
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
        watchedStore.onRemove = { [weak self] items in
            guard let self else { return }
            self.deleteWatchedItems(items, profile: self.pid)
        }
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
            guard let self else { return "Account sync isn't ready yet" }
            return await self.pullBadgeSettings(profile: self.pid)
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
        // Live TV favourites / home-pinned channels ride the same blob.
        LiveChannelFavorites.shared.onLocalChange = { [weak self] in self?.scheduleAppPreferencesPush() }
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
        // The id comes from the STATE BEING PUBLISHED, never from
        // `account.currentUserID`. `@Published` fires its subscribers from
        // `willSet` — the property still holds the OLD value while this runs —
        // so on a fresh sign-in that read came back nil and this method took
        // the "no user id" exit below: no immediate sync, no auto-sync loop,
        // and `handleAccountIdentityChange` bailed out too. Sessions restored
        // at launch hid it, because the subscription's first delivery carries
        // the value already in place.
        case .signedIn(let userID, _):
            guard !userID.isEmpty else {
                profileStore.accountAvailable = false
                stopAutoSync()
                wasSignedIn = false
                OrivioSyncDiagnostics.record(.failure, area: "Orivio", "Sync skipped because the saved account session has no user id.")
                return
            }
            profileStore.accountAvailable = true
            // Before anything can push, make sure no state belonging to a
            // previous account is still resident on this device.
            handleAccountIdentityChange(userID: userID)
            // Every access-token refresh republishes `.signedIn` (hourly, on
            // the first 401). Restarting the loop here cancelled whichever
            // sync was awaiting inside that very refresh — the auto tick's own
            // run, most of the time — so that sync aborted half-way with
            // "Sync failed." Start the loop only when it is not running.
            if autoSyncTask == nil { startAutoSync() }
            guard !wasSignedIn else { return }
            wasSignedIn = true
            // A session RESTORED at launch syncs too, just not from inside app
            // construction. It used to wait for the periodic loop — up to 30s,
            // 90s on the A8/A10X — so opening the app showed the previous
            // session's Continue Watching, library and settings until a timer
            // the user couldn't see happened to fire. `syncOnAppOpen` starts it
            // after a short settle instead (see `openSyncDelay`), which keeps
            // the launch itself responsive.
            //
            // Someone actually SIGNING IN is the opposite case. They are sitting
            // in front of the TV having just authenticated, and everything they
            // own — library, watch progress, add-ons, collections — is on the
            // account rather than the device. Waiting even a second to see any
            // of it reads as a broken sign-in, so pull it now.
            guard account.didSignInInteractively else {
                syncOnAppOpen(reason: "launch, restored session")
                return
            }
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio", "Signed in — syncing this account now."
            )
            fullSyncTask?.cancel()
            fullSyncTask = Task { [weak self] in await self?.syncNow() }
        case .signedOut:
            // Only a REAL sign-out, not the launch-time "no stored session" or a
            // failed session restore — both of those also publish `.signedOut`,
            // and wiping the bookkeeping there would drop pending deletes the
            // same user still needs when they sign back in.
            let leftAnAccount = wasSignedIn
            wasSignedIn = false
            profileStore.accountAvailable = false
            stopAutoSync()
            // An app-open sync still sitting in its settle delay belongs to the
            // account being left. Its own token guard would catch it, but only
            // after it had waited; disarm it here so the flag can't stay set.
            openSyncTask?.cancel()
            openSyncTask = nil
            openSyncPending = false
            // Nothing queued for the account we just left may be allowed to run
            // against whichever account signs in next: the pending delete queues
            // would delete THAT user's rows, and the seeded flags would put its
            // first pull straight into reconcile mode.
            if leftAnAccount { resetSyncBookkeeping(droppingPendingDeletes: false) }
        case .loading:
            break
        }
    }

    // MARK: - Full sync

    // MARK: - App-open sync

    /// Bring the account down (and this device's changes up) because the app
    /// was just opened: a cold launch with a session already restored, or a
    /// return to the foreground after being away.
    ///
    /// Safe to call from every open-shaped lifecycle event, and meant to be —
    /// the launch auth-change and the `scenePhase` change both fire on a cold
    /// launch, and on tvOS `scenePhase` can flip more than once. Four things
    /// keep that from turning into several syncs:
    ///
    /// * An armed-but-not-yet-started open sync swallows further requests
    ///   (`openSyncPending`).
    /// * A full sync already running is REUSED, not queued behind — unlike
    ///   `syncNow`'s `rerunRequested`, which exists to carry a local change the
    ///   running cycle may have missed. Opening the app carries no such change,
    ///   so a second cycle would be pure duplicate work.
    /// * A full sync that ended in the last `openSyncFloor` seconds means the
    ///   picture is already current.
    /// * The task chains behind `fullSyncTask`, so it can never interleave with
    ///   a sign-in or profile-switch cycle.
    ///
    /// Nothing here blocks the UI: the stores already hold the last synced
    /// snapshot from disk and the screens are rendering it before this runs;
    /// the pulls publish into those same stores, so fresh data appears where
    /// the user already is.
    func syncOnAppOpen(reason: String) {
        guard !openSyncPending else {
            NSLog("[OrivioSync] app-open sync already armed — ignoring '%@'", reason)
            AppProbe.sync("app-open sync already armed — ignoring '\(reason)'")
            return
        }
        // Token only. `currentUserID` reads `authState`, and this is called
        // from that property's `willSet` subscriber — where it can still hold
        // the previous value (see `handleAuthChange`). `syncNow` re-checks it
        // for real, with the diagnostic, once the session has settled.
        guard account.accessToken != nil else { return }
        guard !isRetiringAccountState else { return }
        guard !isSyncing else {
            NSLog("[OrivioSync] app-open sync reusing the running sync (%@)", reason)
            AppProbe.sync("app-open sync reusing the running cycle (\(reason))")
            return
        }
        guard Date().timeIntervalSince(lastFullSyncEnded) >= Self.openSyncFloor else {
            NSLog("[OrivioSync] app-open sync skipped — one finished %.0fs ago (%@)",
                  Date().timeIntervalSince(lastFullSyncEnded), reason)
            return
        }
        openSyncPending = true
        NSLog("[OrivioSync] app-open sync armed — %@", reason)
        AppProbe.sync(String(format: "app-open sync armed — %@ (fires in %.1fs)",
                             reason, Self.openSyncDelay))
        let previous = fullSyncTask
        // The profile this sync was armed for. Picking someone else at the
        // launch gate runs `handleProfileSwitch`, which queues a full sync for
        // the profile chosen — so this one would be a second, identical cycle.
        let armedProfile = pid
        let task = Task { [weak self] in
            await previous?.value
            // Cancellation lands here as a thrown sleep; the code below still
            // has to run so `openSyncPending` can't stay armed forever.
            try? await Task.sleep(nanoseconds: UInt64(Self.openSyncDelay * 1_000_000_000))
            guard let self else { return }
            self.openSyncPending = false
            guard !Task.isCancelled else { return }
            guard self.pid == armedProfile else {
                NSLog("[OrivioSync] app-open sync stood down — profile changed %d -> %d; its switch syncs it",
                      armedProfile, self.pid)
                return
            }
            // Re-check both gates: waiting on `previous` and the settle delay
            // between them are plenty of time for a sign-in, a profile switch
            // or a tick to have started (or just finished) a cycle of its own.
            guard !self.isSyncing,
                  Date().timeIntervalSince(self.lastFullSyncEnded) >= Self.openSyncFloor
            else {
                NSLog("[OrivioSync] app-open sync stood down — another cycle covered it")
                AppProbe.sync("app-open sync stood down — another cycle covered it")
                return
            }
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio", "Syncing this account because the app was opened."
            )
            // Same split the periodic tick and the local-change coordinator
            // make. A stream can be playing when this fires — tvOS drops the
            // app to `.inactive` for a system overlay without stopping
            // playback, and coming back is an app-open — and the full cycle's
            // metadata enrichment and twenty-odd preference round trips are
            // exactly what must not contend with a decode. The light pass
            // still brings down Continue Watching, the library and watched
            // history, which is what changed on the other device.
            if Self.playbackActive {
                await self.syncLight(reason: "app opened during playback")
                // `syncNow`'s defer stamps this for the full path; the light
                // pass has to stamp it itself or a run of foreground flips
                // during one film would each get their own pass.
                self.lastFullSyncEnded = Date()
            } else {
                await self.syncNow()
            }
        }
        openSyncTask = task
        fullSyncTask = task
    }

    // MARK: - Periodic auto-sync

    /// Seconds between automatic full syncs while signed in and foregrounded.
    /// Tier-scaled: the full sync has no server-side change detection, so
    /// every idle tick pulls and decodes complete progress/library/watched
    /// snapshots — recurring work the A8/A10X pays in focus hitches while the
    /// user browses. 90s there still keeps devices current (the per-change
    /// SyncCoordinator push path is what carries urgency, not this timer).
    static let autoSyncInterval: TimeInterval =
        (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? 90 : 30
    private var autoSyncTask: Task<Void, Never>?
    /// Set by the player. While a stream plays the tick runs `syncLight`
    /// instead of the full multi-endpoint sync: a few small JSON requests that
    /// keep Continue Watching, the library and watched history current on
    /// every device mid-film, without the metadata enrichment and the twenty
    /// preference/addon/plugin round trips that used to make the whole tick
    /// something worth skipping. Nothing is skipped any more.
    @MainActor static var playbackActive = false

    /// Ticks seen while playback was active (see the loop below).
    private var playbackTicks = 0

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
                    // The light pass still merges three stores ON THE MAIN
                    // ACTOR — thousands of watched rows on a long-lived
                    // install — while the A8/A10X is decoding a film beside
                    // it. Those tiers' tick is already stretched to 90s by
                    // `autoSyncInterval`, which is the in-playback cadence
                    // the old every-third-tick skip produced.
                    playbackTicks += 1
                    await syncLight(reason: "auto, playback active")
                    continue
                }
                playbackTicks = 0
                await syncNow()
            }
        }
    }

    /// The in-playback sync. Flushes anything dirty, then pulls the three
    /// stores another device changes while you watch — Continue Watching, the
    /// library, watched history — and nothing else: no profile, add-on,
    /// preference or plugin round trips, and no metadata enrichment (see
    /// `enrichMetadata`), so it is a handful of small JSON requests that
    /// cannot contend with a stream. Same profile pinning as `syncNow`.
    func syncLight(reason: String) async {
        guard account.accessToken != nil, account.currentUserID != nil else { return }
        guard !isSyncing, !isRetiringAccountState else { return }
        isSyncing = true
        // A full sync requested while THIS light pass was running was neither
        // run nor re-run: `rerunRequested` was consumed only by syncNow's
        // defer, so the request sat until the next 30s tick. Same rule here.
        defer {
            isSyncing = false
            if rerunRequested {
                rerunRequested = false
                Task { [weak self] in await self?.syncNow() }
            }
        }
        let profile = pid
        do {
            if profilesDirty { try await pushProfiles() }
            await drainProfileDeletes()
            if isDirty("addons", profile: profile) { try await pushAddons(profile: profile) }
            // The three content stores are independent of one another: their
            // push → flush-deletes → pull chains run side by side.
            try await runConcurrently([
                { [self] in
                    if isDirty("progress", profile: profile) { try await pushWatchProgressAll(profile: profile) }
                    await reconcileProgressDeletesBeforePull(profile: profile)
                    // Still-pending deletes postpone the progress pull so it
                    // cannot resurrect them (same rule as refreshContinueWatching).
                    if loadPendingDeletes(profile: profile).isEmpty {
                        try await pullWatchProgress(profile: profile)
                    }
                },
                { [self] in
                    if isDirty("library", profile: profile) { try await pushLibrary(profile: profile) }
                    await reconcileLibraryDeletesBeforePull(profile: profile)
                    try await pullLibrary(profile: profile)
                },
                { [self] in
                    if isDirty("watched", profile: profile) { try await pushWatchedItems(profile: profile) }
                    await reconcileWatchedDeletesBeforePull(profile: profile)
                    try await pullWatchedItems(profile: profile)
                }
            ])
            NSLog("[OrivioSync] light sync ok — %@", reason)
        } catch let change as ProfileChangedMidSync {
            NSLog("[OrivioSync] light sync abandoned — profile switched %d -> %d mid-run",
                  change.from, change.to)
        } catch {
            NSLog("[OrivioSync] light sync FAILED (%@): %@", reason, String(describing: error))
            lastSyncError = describe(error)
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
            // Not dropped: the running sync runs once more when it ends, so
            // whatever prompted this request still goes up promptly.
            NSLog("[OrivioSync] syncNow deferred — sync already running; will run again after it")
            rerunRequested = true
            return
        }
        NSLog("[OrivioSync] syncNow starting")
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Full sync started for profile \(pid).")
        isSyncing = true
        lastSyncError = nil
        libraryGrewDuringSync = false
        let started = Date()
        defer {
            isSyncing = false
            lastFullSyncEnded = Date()
            if rerunRequested {
                rerunRequested = false
                Task { [weak self] in await self?.syncNow() }
            }
        }
        do {
            // Flush any pending local profile edit FIRST — a just-created
            // profile whose debounced push hasn't landed would otherwise be
            // wiped by the pull's replaceRemote below.
            if profilesDirty { try await pushProfiles() }
            // Then any deletion: it has its own RPC, and the pull below is
            // the only thing that retires its tombstone.
            await drainProfileDeletes()
            // Flush a pending app-preferences push (collections, player/TMDB/
            // theme edits) BEFORE the pulls below, or a re-sync would clobber
            // the not-yet-pushed local edit with the stale server copy.
            // Pinned to the profile that is active RIGHT NOW: `runProfile`
            // isn't known until pullProfiles has run (it can re-point the
            // active profile), and this blob is per-profile either way.
            if appPreferencesDirty { await pushAppPreferences(profile: pid) }
            // Learn the profile list first, then scope the personal-data stores
            // to the active profile before pulling its data.
            try await pullProfiles()
            applyActiveProfileScope()
            // Everything below is scoped to THIS profile. Pin it and re-check at
            // each step: a switch part-way through would otherwise merge this
            // profile's server data into the newly-selected profile's store and
            // then push the result back up under the new profile's id.
            //
            // The pin is threaded INTO every step as a parameter as well.
            // Checking between steps left the damaging window wide open INSIDE
            // them: `pullLibrary` issued its request with the old profile id and
            // wrote the response under whatever profile was current when it
            // landed, and `pushLibrary` spent seconds in metadata enrichment and
            // then built its body from a freshly-read id — sending one profile's
            // items to a replace-semantics RPC under another profile's id.
            let runProfile = pid
            let firstFullSync = !completedFullSyncProfiles.contains(runProfile)
            repairAccidentalWatchHistoryClearState(profile: runProfile)

            // The per-store chains below are independent of one another —
            // each one flushes its own dirty edits, then its own queued
            // removals, then pulls its own snapshot — so they run SIDE BY
            // SIDE. Run one after another, a full sync was forty-odd
            // sequential round trips (plus a run of metadata lookups inside
            // two of them), which is the "takes forever to sync" a big
            // account saw every 30 seconds. Every chain still pins and
            // re-checks `runProfile`; a switch abandons the whole run.
            try await runConcurrently([
                { [self] in try await syncAddonsChain(profile: runProfile) },
                { [self] in try await syncProgressChain(profile: runProfile) },
                { [self] in try await syncLibraryChain(profile: runProfile) },
                { [self] in try await syncWatchedChain(profile: runProfile) },
                { [self] in try await syncPreferencesChain(profile: runProfile) }
            ])
            try ensureProfile(runProfile)
            // Trakt and the player key the same episode differently; collapse
            // any pair that already exists so the hub holds ONE row per episode.
            let collapsed = progressStore.collapseDuplicateEpisodes()
            if !collapsed.isEmpty {
                OrivioSyncDiagnostics.record(
                    .info, area: "Orivio",
                    "Collapsed \(collapsed.count) duplicate Continue Watching row(s) keyed differently by another source."
                )
            }
            // Last and most important gate: every push below REPLACES the
            // account's copy for `pid`, so one that runs after a switch
            // overwrites the newly-selected profile with this one's data.
            try ensureProfile(runProfile)
            // The first cycle for a profile uploads EVERYTHING (that is how a
            // device's local data merges into the account); afterwards only
            // what changed locally, by each store's dirty flag. Every merge
            // from a tracker marks its store dirty (`requestSyncPush`), so
            // nothing that used to ride the unconditional tail push is lost.
            if firstFullSync || profilesDirty { try await pushProfiles() }
            if firstFullSync || isDirty("addons", profile: runProfile) {
                try await pushAddons(profile: runProfile)
            }
            if firstFullSync || isDirty("progress", profile: runProfile) {
                try await pushWatchProgressAll(profile: runProfile)
            }
            if firstFullSync || isDirty("library", profile: runProfile)
                || !loadPendingLibraryDeletes(profile: runProfile).isEmpty {
                try await pushLibrary(profile: runProfile)
            }
            if firstFullSync || isDirty("watched", profile: runProfile) {
                try await pushWatchedItems(profile: runProfile)
            }
            // Persist the "the shared library grew" signal into the real
            // dirty flags before the tail runs. `libraryGrewDuringSync` is
            // in-memory and reset at the top of every run, and
            // `mergeIntoLibrary` is idempotent — so if a chain threw after the
            // merge, the flag was lost and the next run's merge reported no
            // change. Those collections would never have been uploaded.
            if libraryGrewDuringSync {
                collectionsDirty = true
                homeCatalogDirty = true
                appPreferencesDirty = true
            }
            if firstFullSync || collectionsDirty || libraryGrewDuringSync {
                try? await pushCollections(profile: runProfile)   // best-effort; see the pull note
            }
            if firstFullSync || homeCatalogDirty || libraryGrewDuringSync {
                try await pushHomeCatalogSettings(profile: runProfile)
            }
            if firstFullSync || appPreferencesDirty || libraryGrewDuringSync {
                await pushAppPreferences(profile: runProfile)
            }
            if firstFullSync || providerCredentialsDirty {
                await pushProviderCredentials(profile: runProfile)  // dual-write to the Android table
            }
            if firstFullSync || pluginsDirty { try? await pushPlugins(profile: runProfile) }
            completedFullSyncProfiles.insert(runProfile)
            NSLog("[OrivioSync] syncNow finished ok in %.1fs (%@)",
                  Date().timeIntervalSince(started), firstFullSync ? "first full cycle" : "incremental")
        } catch let change as ProfileChangedMidSync {
            // Not a failure: the user moved to another profile, and that switch
            // schedules its own sync. Abandoning here is the point.
            NSLog("[OrivioSync] syncNow abandoned — profile switched %d -> %d mid-run",
                  change.from, change.to)
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio",
                "Sync for profile \(change.from) abandoned because the active profile changed to \(change.to); the new profile syncs on its own."
            )
            // The switch handler is already waiting to run a full sync for
            // the new profile; a rerun on top of it would be a third one.
            rerunRequested = false
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
        OrivioSyncDiagnostics.record(.success, area: "Orivio", "Full sync finished for profile \(pid).")
    }

    // MARK: Per-store chains (run concurrently by syncNow)

    /// Pull first so remote wins on first login, then push the merged set —
    /// but flush a pending add-on edit first. `addonsDirty` exists for exactly
    /// this ("dirty ⇒ push first"): a periodic full sync landing inside the
    /// 1.2s debounce would otherwise reconcile an add-on you had just removed
    /// back onto the device, and then push it up again.
    private func syncAddonsChain(profile: Int) async throws {
        try ensureProfile(profile)
        if isDirty("addons", profile: profile) { try await pushAddons(profile: profile) }
        try await pullAddons(profile: profile)
    }

    /// Flush local progress edits before pulling (the account pull is a full
    /// snapshot, so pulling first can read a just-watched row as remotely
    /// deleted before its upload lands), then flush removals queued in a
    /// previous session and tombstone them, so a not-yet-deleted row can't
    /// come back here.
    private func syncProgressChain(profile: Int) async throws {
        try ensureProfile(profile)
        if isDirty("progress", profile: profile) { try await pushWatchProgressAll(profile: profile) }
        await reconcileProgressDeletesBeforePull(profile: profile)
        try await pullWatchProgress(profile: profile)
    }

    private func syncLibraryChain(profile: Int) async throws {
        try ensureProfile(profile)
        // Flush local edits BEFORE the pull, and let a failure abort the
        // chain. `pullLibrary` reconciles — it deletes every local row the
        // server snapshot lacks — so running it after a push that failed
        // (expired token, timeout on a large body) deletes the titles the
        // user just saved, and they were never on the account either.
        // `reconcileLibraryDeletesBeforePull` swallows its push with `try?`,
        // which is why this cannot be left to it.
        if isDirty("library", profile: profile) { try await pushLibrary(profile: profile) }
        await reconcileLibraryDeletesBeforePull(profile: profile)
        try await pullLibrary(profile: profile)
    }

    /// Marks whose debounced push never landed go up BEFORE the pull, or the
    /// reconcile reads them as deleted elsewhere.
    private func syncWatchedChain(profile: Int) async throws {
        try ensureProfile(profile)
        if isDirty("watched", profile: profile) { try await pushWatchedItems(profile: profile) }
        await reconcileWatchedDeletesBeforePull(profile: profile)
        try await pullWatchedItems(profile: profile)
    }

    /// Collections, the home layout, badges, the app-preferences blob,
    /// provider credentials and plugin repos. These stay in ONE chain: the
    /// preferences blob carries the collections library and the layout reads
    /// it, so their order matters — but nothing in here touches the content
    /// stores, so the whole chain runs beside them.
    ///
    /// Each pull is a full-snapshot replace, so a local edit still sitting in
    /// its 1.2-1.5s debounce goes up FIRST or the server's stale copy wins
    /// and the edit is lost (see `collectionsDirty`). The dedicated
    /// collections RPC is best-effort — if the backend lacks it a throw must
    /// NOT abort the rest.
    private func syncPreferencesChain(profile: Int) async throws {
        try ensureProfile(profile)
        if collectionsDirty {
            do {
                try await pushCollections(profile: profile)
            } catch {
                // Swallowed by `try?` before, which hid the worst part: the
                // dirty flag only clears on SUCCESS, and `pullCollections`
                // refuses to apply anything while it is set. A push that keeps
                // failing therefore leaves this device permanently blind to
                // collection changes made anywhere else — folders reordered on
                // the phone simply never arrive — with nothing anywhere saying
                // so. Still best-effort (the rest of the chain must run), but
                // no longer silent.
                OrivioSyncDiagnostics.record(
                    .failure, area: "Orivio",
                    "Couldn't upload this device's collections: \(error.localizedDescription). "
                        + "Until it succeeds, collection changes made on other devices are NOT applied here."
                )
            }
        }
        try? await pullCollections(profile: profile)
        if homeCatalogDirty { try? await pushHomeCatalogSettings(profile: profile) }
        try await pullHomeCatalogSettings(profile: profile)
        if badgeSettingsDirty { await pushBadgeSettings(profile: profile) }
        await pullBadgeSettingsIfDue(profile: profile)   // best-effort; badge chips are cosmetic
        if appPreferencesDirty { await pushAppPreferences(profile: profile) }
        await pullAppPreferences(profile: profile)  // player/TMDB/theme prefs + collections
        if providerCredentialsDirty { await pushProviderCredentials(profile: profile) }
        await pullProviderCredentials(profile: profile)  // debrid keys + Trakt (Android table)
        // Local repo edits go up before the reconciling pull, or a removal
        // still inside its debounce is restored and then re-uploaded.
        if pluginsDirty { try? await pushPlugins(profile: profile) }
        await pullPlugins(profile: profile)   // plugin repos (Android table)
    }

    /// Run independent chains at once and wait for ALL of them. One chain
    /// failing does not cancel the others — each leaves its own store
    /// consistent and its dirty flags set when it fails, so the next run
    /// retries just that part. A profile switch is reported ahead of any
    /// other error, because it means the run is being abandoned on purpose.
    private func runConcurrently(_ chains: [@MainActor @Sendable () async throws -> Void]) async throws {
        let errors: [Error] = await withTaskGroup(of: Error?.self) { group in
            for chain in chains {
                group.addTask { @MainActor in
                    do { try await chain(); return nil } catch { return error }
                }
            }
            var collected: [Error] = []
            for await error in group {
                if let error { collected.append(error) }
            }
            return collected
        }
        if let change = errors.first(where: { $0 is ProfileChangedMidSync }) { throw change }
        if let first = errors.first { throw first }
    }

    func pullAccountUpdates() async {
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Pull updates requested; running full two-way sync for profile \(pid).")
        await syncNow()
    }

    func pushThisDevice() async {
        // Mid-film this is the Stremio tick's "we merged something" nudge,
        // thirty seconds apart at most — the light pass carries it.
        if Self.playbackActive {
            await syncLight(reason: "device push during playback")
            return
        }
        OrivioSyncDiagnostics.record(.info, area: "Orivio", "Device push requested; running full two-way sync for profile \(pid).")
        await syncNow()
    }

    private func applyActiveProfileScope() {
        progressStore.setProfile(pid)
        libraryStore.setProfile(pid)
        watchedStore.setProfile(pid)
        collectionsStore.setProfile(pid)
        homeCatalogSettings.setProfile(pid)
        rescopePerProfileStores(pid)
        // Only rescopes when per-profile Trakt accounts are on; otherwise the
        // login stays device-wide.
        traktStore?.setProfile(pid)
    }

    /// The stores split per profile in the upstream-parity pass: add-ons and
    /// plugins (honouring the profile's use-primary fallbacks), debrid logins,
    /// player settings, TMDB settings, theme, badges.
    private func rescopePerProfileStores(_ id: Int) {
        addonManager.setProfile(addonPID(for: id))
        pluginStore?.setProfile(pluginPID(for: id))
        debridStore?.setProfile(id)
        playerSettings?.setProfile(id)
        tmdbSettings?.setProfile(id)
        themeManager?.setProfile(id)
        streamBadges?.setProfile(id)
        // Was missing: favorites relied solely on the app-level profile
        // closure, so any rescope driven from HERE applied one profile's
        // account blob into another profile's favourites store.
        LiveChannelFavorites.shared.setProfile(id)
    }

    // MARK: - Addons

    /// Set on any local add/remove/reorder, cleared only once a push actually
    /// lands. Guards reconciliation: pulling the account down and deleting
    /// whatever it doesn't list would destroy an add-on added on THIS device
    /// while the push was failing (offline, token expired). Dirty ⇒ push first.
    ///
    /// Per profile (like `progressDirty`) now that add-on lists are: an edit
    /// on profile A followed by a quick switch to B must not make B's next
    /// sync look like it has pending edits — nor clear A's flag before A's
    /// list ever went up.
    private var addonsDirty: Bool {
        get { isDirty("addons", profile: pid) }
        set { setDirty("addons", profile: pid, newValue) }
    }

    private func scheduleAddonPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        addonsDirty = true
        pushAddonsTask?.cancel()
        pushAddonsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushAddons(profile: self.pid)
        }
    }

    /// Full two-way add-on sync: local changes up, then the account down with
    /// reconciliation so deletions from other devices land here.
    private func syncAddonsBothWays() async throws {
        guard account.accessToken != nil else {
            throw OrivioAuthError.message("not signed in")
        }
        // Pinned like a full sync: the seeded flag that decides whether the pull
        // may reconcile is per-profile, and a switch between these two calls
        // used to read it from the wrong profile.
        let profile = pid
        if isDirty("addons", profile: profile) {
            // Local edits go first or the pull below would reconcile them away.
            try await pushAddons(profile: profile)
        }
        try await pullAddons(profile: profile)
    }

    private func pushAddons(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        // Never before this account's own list has been read — see
        // `pulledAddonProfiles`. A local edit still pushes normally, because the
        // pull that precedes every push in `syncNow` marks the profile read.
        guard pulledAddonProfiles.contains(profile) || isDirty("addons", profile: profile) else {
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio",
                "Skipped the add-on push: this account's own list has not been read yet."
            )
            return
        }
        let entries: [[String: Any]] = addonManager.addons.enumerated().map { index, addon in
            var obj: [String: Any] = [
                "url": addon.manifestURL,
                "sort_order": index,
                "enabled": addon.enabled
            ]
            if !addon.manifest.name.isEmpty { obj["name"] = addon.manifest.name }
            return obj
        }
        // The REAL profile id. This was hardcoded to 1 (as was the pull's
        // filter), which flattened every profile into one account row set —
        // and since Android has always pushed per-profile rows, tvOS was
        // also blind to the per-profile add-ons the account already held.
        // Routed through `addonPID` so a "use primary add-ons" profile writes
        // profile 1's rows (its own stay dormant), matching Android.
        let body: [String: Any] = [
            "p_addons": entries,
            "p_profile_id": addonPID(for: profile),
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushAddons), body: body)
        // Only now is the account known to hold this device's list, so a later
        // pull may safely reconcile against it.
        setDirty("addons", profile: profile, false)
        // A push proves this profile has add-on data on the account, which lets
        // a subsequent empty pull be read as a genuine "cleared elsewhere".
        setSeeded("addons", profile: profile)
    }

    private func pullAddons(profile: Int) async throws {
        guard let userID = account.currentUserID else {
            // Signed in far enough to hold a token but the JWT never yielded a
            // user id — silently returning here made "Refresh Add-ons" a no-op
            // with no explanation.
            throw OrivioAuthError.message("account not fully signed in")
        }
        // PostgREST select, filtered to our rows for THIS profile — via
        // `addonPID`, so a "use primary add-ons" profile reads profile 1's rows.
        let path = "/rest/v1/addons?user_id=eq.\(userID)&profile_id=eq.\(addonPID(for: profile))&select=url,sort_order,enabled,name"
        let data = try await authedGet(path)
        let rows = try JSONDecoder().decode([SupabaseAddon].self, from: data)
        // The response is for `profile`; refuse to apply it under another one.
        try ensureProfile(profile)
        let localEditPending = isDirty("addons", profile: profile)
        let orderedAddons = rows.sorted { $0.sortOrder < $1.sortOrder }.map {
            AddonManager.RemoteAddonState(
                manifestURL: $0.url,
                enabled: $0.enabled,
                enabledIsAuthoritative: !localEditPending
            )
        }
        // This account's own list has now been read, so a push may run.
        pulledAddonProfiles.insert(profile)
        NSLog("[OrivioAddonSync] pullAddons: %d rows for user %@", rows.count, userID)

        // A local edit is waiting on its push, so this snapshot predates it —
        // applying it at all is wrong, not just the enabled/reconcile parts.
        // The additive install path used to run anyway, and the snapshot still
        // lists the add-on the user JUST removed: the pull re-installed it,
        // and the debounced push then uploaded the resurrected list, undoing
        // the removal for good. The dirty push goes first on the next cycle
        // (`syncAddonsChain`), and the pull after it applies a snapshot that
        // reflects the edit — new add-ons from other devices land then.
        if localEditPending {
            NSLog("[OrivioAddonSync] pullAddons: skipped applying — a local add-on edit is awaiting its push")
            return
        }

        // Same seeded policy library/watched use. Reconciling (deleting local
        // add-ons the account doesn't list) is only correct once we know the
        // account genuinely represents this profile's add-ons — otherwise a
        // first sign-in against a fresh account would wipe the device.
        let seeded = isSeeded("addons", profile: profile)
        let mayReconcile = seeded && !localEditPending
        if orderedAddons.isEmpty {
            // Empty account list: only a real "removed everything elsewhere"
            // when seeded and no local edit is waiting. Unseeded + empty = fresh
            // account; dirty + empty = stale pull racing a local edit.
            guard mayReconcile else { return }
            await addonManager.applyRemote(urls: [], reconcile: true)
            return
        }
        await addonManager.applyRemote(addons: orderedAddons, reconcile: mayReconcile)
        if !localEditPending { setSeeded("addons", profile: profile) }
    }

    // MARK: - Watch progress

    /// The ACTIVE profile's flag (see the persisted per-profile flags).
    private var progressDirty: Bool {
        get { isDirty("progress", profile: pid) }
        set { setDirty("progress", profile: pid, newValue) }
    }

    private func pushWatchProgress() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        progressDirty = true
        let profile = pid   // the profile that CHANGED, not whoever is active when this fires
        Task { [weak self] in
            guard let self else { return }
            try? await self.pushWatchProgressAll(profile: profile)
        }
    }

    /// True while a `refreshContinueWatching` task is running. Checked and set
    /// SYNCHRONOUSLY on the main actor — see the method.
    private var refreshContinueWatchingInFlight = false

    /// Pull the latest Continue Watching (and library) from the account — call
    /// on foreground so changes made on other devices show up without a
    /// relaunch. Local pushes already fire immediately on every change.
    func refreshContinueWatching() {
        guard account.accessToken != nil else { return }
        // Check-and-set BEFORE the Task. The overlap guard used to live inside
        // it, so two calls in the same runloop turn — the `scenePhase` change
        // and the 30s Home poll, or two poll ticks — both spawned a task, both
        // saw `isSyncing == false`, and both ran the push/drain/pull sequence
        // over the same stores. A second run is redundant, not newer.
        guard !refreshContinueWatchingInFlight else { return }
        refreshContinueWatchingInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshContinueWatchingInFlight = false }
            // The 30s Home poll and the 30s auto-sync tick run on separate
            // timers, and this method pulls the library as well — so on Home
            // the account was being pulled roughly twice per window, with the
            // two runs overlapping in `libraryStore.mergeRemote`. Every other
            // entry point has this guard; this one didn't.
            //
            // `openSyncPending` counts as well. This method is called from the
            // same `scenePhase` change that arms the app-open sync, and that
            // sync's settle delay means `isSyncing` is still false when this
            // runs — so both would pull progress and library at once, which is
            // exactly the overlap the guard exists to stop. Standing down loses
            // nothing: the full sync about to run is a superset of this.
            guard !self.isSyncing, !self.openSyncPending, !self.isRetiringAccountState
            else { return }
            // Pinned exactly like syncNow: this is a miniature sync, and the
            // profile can change between any two of these awaits.
            let profile = self.pid
            // A local change whose push is still in flight must go up first —
            // `replaceWithOrivioSnapshot` would otherwise read a snapshot that
            // predates it and drop (and tombstone) the title just watched.
            if self.progressDirty { try? await self.pushWatchProgressAll(profile: profile) }
            // Reassert not-yet-confirmed removals so the pull can't resurrect
            // them, push the deletes to the server, THEN pull the snapshot.
            await self.reconcileProgressDeletesBeforePull(profile: profile)
            // Still-pending deletes postpone the pull so it can't resurrect
            // them. This is no longer permanent: a key the server keeps
            // rejecting is quarantined by drainPendingDeletes (see
            // maxDeleteAttempts) instead of blocking every future refresh.
            guard self.loadPendingDeletes(profile: profile).isEmpty else { return }
            try? await self.pullWatchProgress(profile: profile)
            await self.reconcileLibraryDeletesBeforePull(profile: profile)
            try? await self.pullLibrary(profile: profile)
        }
    }

    // Removals must reach the account durably — a fire-and-forget delete that
    // hit a network blip would silently strand the row on the server, so it
    // reappears on the next full pull ("removed it, it came back"). Instead we
    // queue removals to a PERSISTED per-profile set and drain it (with the
    // key surviving app restarts) until the server confirms the delete.
    private func pendingDeletesKey(profile: Int) -> String {
        "orivio.sync.pendingWatchProgressDeletes.p\(profile)"
    }

    private func loadPendingDeletes(profile: Int) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingDeletesKey(profile: profile)) ?? [])
    }

    private func savePendingDeletes(_ set: Set<String>, profile: Int) {
        let key = pendingDeletesKey(profile: profile)
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(Array(set), forKey: key) }
    }

    /// How many SERVER REJECTIONS a queued delete survives before it is
    /// quarantined. A key the server refuses can never drain, and both
    /// `refreshContinueWatching` and the pre-pull reconcile stall while the
    /// queue is non-empty — so one permanently-rejected key stopped Continue
    /// Watching from ever refreshing again for that profile. Transport failures
    /// (offline, timeout, 5xx) don't count, so a week off the network still
    /// retries everything forever.
    private static let maxDeleteAttempts = 5

    private func pendingDeleteAttemptsKey(profile: Int) -> String {
        "orivio.sync.pendingWatchProgressDeleteAttempts.p\(profile)"
    }

    private func loadPendingDeleteAttempts(profile: Int) -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: pendingDeleteAttemptsKey(profile: profile)) as? [String: Int]) ?? [:]
    }

    private func savePendingDeleteAttempts(_ counts: [String: Int], profile: Int) {
        let key = pendingDeleteAttemptsKey(profile: profile)
        if counts.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(counts, forKey: key) }
    }

    /// A refusal the server will keep repeating. 401/403 (auth), 408/429 (come
    /// back later) and every 5xx are transient and must not burn an attempt.
    private static func isPermanentRejection(_ error: Error) -> Bool {
        guard case OrivioAuthError.http(let code, let body) = error else { return false }
        // A deployment that simply lacks the delete RPC answers 400/404 with a
        // PGRST202 "could not find the function" body. That says nothing about
        // the key, so burning attempts on it would silently drop every removal
        // the user ever makes. `ignoresMissingRPC` recognises the same shape.
        if Self.looksLikeMissingRPC(body) { return false }
        return (400..<500).contains(code)
            && code != 401 && code != 403 && code != 404 && code != 408 && code != 429
    }

    /// Queue a Continue Watching removal for durable server deletion. Persists
    /// immediately (survives offline / relaunch) and kicks a drain.
    /// - Parameter profile: the profile the removal belongs to. The store
    ///   callback passes nothing (the removal happened on the profile that is
    ///   active NOW); a caller that has already suspended passes its pin.
    private func deleteWatchProgress(keys: [String], profile explicitProfile: Int? = nil) {
        let trimmed = keys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        // Queue and drain under that id rather than whichever one the drain's
        // response happens to land under.
        let profile = explicitProfile ?? pid
        var pending = loadPendingDeletes(profile: profile)
        pending.formUnion(trimmed)
        savePendingDeletes(pending, profile: profile)
        Task { [weak self] in await self?.drainPendingDeletes(profile: profile) }
    }

    /// Reassert tombstones for Continue Watching removals the server hasn't
    /// confirmed, THEN flush them — so a full-snapshot pull can't resurrect a
    /// card whose delete is still retrying. The in-memory tombstone expires
    /// after 3 minutes while the persisted queue does not, so a delete that
    /// keeps failing would otherwise let the row reappear once the grace ran
    /// out. Must run before every progress pull.
    private func reconcileProgressDeletesBeforePull(profile: Int) async {
        guard pid == profile else { return }
        dropPendingDeletesHeldLocally(profile: profile)
        let pending = loadPendingDeletes(profile: profile)
        if !pending.isEmpty { progressStore.tombstone(Array(pending)) }
        await drainPendingDeletes(profile: profile)
    }

    /// A queued delete for an episode this device HAS again — finished, then
    /// played again before the delete went out (it waits for the network) — is
    /// void. Now that deletes name the account's row, sending it removed the
    /// fresh row from the account, and the tombstone reasserted before the pull
    /// dropped the local one too. Active profile only: the store holds no other.
    private func dropPendingDeletesHeldLocally(profile: Int) {
        guard pid == profile else { return }
        let pending = loadPendingDeletes(profile: profile)
        guard !pending.isEmpty else { return }
        let held = pending.intersection(progressStore.accountKeysHeld())
        guard !held.isEmpty else { return }
        savePendingDeletes(pending.subtracting(held), profile: profile)
        var attempts = loadPendingDeleteAttempts(profile: profile)
        for key in held { attempts[key] = nil }
        savePendingDeleteAttempts(attempts, profile: profile)
    }

    /// Send every queued removal to the account, clearing only what the server
    /// confirmed. Anything left (a failure, or added mid-flight) retries on the
    /// next drain — foreground, the 30s Home poll, or full sync.
    /// - Parameter profile: the profile these deletes belong to, threaded in so
    ///   the queue read, the RPC's `p_profile_id` and the queue write that
    ///   records the result are provably the same profile. Reading `pid` fresh
    ///   after the response meant a switch mid-request cleared the NEW
    ///   profile's queue on the strength of the old profile's delete.
    private func drainPendingDeletes(profile: Int) async {
        dropPendingDeletesHeldLocally(profile: profile)
        let pending = loadPendingDeletes(profile: profile)
        guard !pending.isEmpty, account.accessToken != nil else { return }
        let body: [String: Any] = [
            "p_keys": Array(pending),
            "p_profile_id": profile,
            "p_origin_client_id": clientID
        ]
        do {
            _ = try await authedPost(RPC.url(RPC.deleteWatchProgress), body: body)
            var latest = loadPendingDeletes(profile: profile)
            latest.subtract(pending)   // keep any queued while this call was in flight
            savePendingDeletes(latest, profile: profile)
            var attempts = loadPendingDeleteAttempts(profile: profile)
            for key in pending { attempts[key] = nil }
            savePendingDeleteAttempts(attempts, profile: profile)
        } catch {
            // Leave the queue intact — a later drain retries it. UNLESS the
            // server is rejecting the batch outright: those keys can never
            // drain, and a stuck queue blocks every Continue Watching refresh
            // for this profile forever. Count rejections and quarantine a key
            // once it has been refused maxDeleteAttempts times, so the refresh
            // can run again. (The row may reappear from the server snapshot —
            // visibly wrong beats silently frozen, and the user can remove it
            // again.)
            guard Self.isPermanentRejection(error) else { return }
            var attempts = loadPendingDeleteAttempts(profile: profile)
            var quarantined: Set<String> = []
            for key in pending {
                let count = (attempts[key] ?? 0) + 1
                if count >= Self.maxDeleteAttempts {
                    quarantined.insert(key)
                    attempts[key] = nil
                } else {
                    attempts[key] = count
                }
            }
            savePendingDeleteAttempts(attempts, profile: profile)
            guard !quarantined.isEmpty else { return }
            savePendingDeletes(loadPendingDeletes(profile: profile).subtracting(quarantined),
                               profile: profile)
            OrivioSyncDiagnostics.record(
                .warning, area: "Orivio",
                "Gave up on \(quarantined.count) Continue Watching removal(s) the server keeps rejecting; they no longer block refreshes."
            )
        }
    }

    private func repairAccidentalWatchHistoryClearState(profile: Int) {
        // ONLY the legacy per-profile flag is evidence of the accidental
        // clear this repairs. `WatchHistoryClearState.clearedAt` is also what
        // the user's own "Clear Watch History" sets — and a profile without
        // the repair stamp (any profile created after the repair shipped)
        // then had its deliberate clear undone by the next tick: horizon
        // dropped, both delete queues emptied, the history re-imported.
        let hadClearState = UserDefaults.standard.bool(forKey: clearedWatchHistoryKey(profile: profile))
        guard hadClearState,
              !UserDefaults.standard.bool(forKey: repairedWatchHistoryClearKey(profile: profile)) else { return }

        UserDefaults.standard.removeObject(forKey: clearedWatchHistoryKey(profile: profile))
        savePendingDeletes([], profile: profile)
        savePendingWatchedDeletes([], profile: profile)
        UserDefaults.standard.set(true, forKey: repairedWatchHistoryClearKey(profile: profile))
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
        // Pinned: the clear reads one profile's stores and then spends several
        // round trips deleting its rows and pushing the horizon.
        let profile = pid
        let clearedAt = WatchHistoryClearState.markClearedNow()
        // A user-initiated clear is never an "accidental" one: stamp the
        // profile so the legacy repair can't touch what this just set up.
        UserDefaults.standard.set(true, forKey: repairedWatchHistoryClearKey(profile: profile))
        OrivioSyncDiagnostics.record(
            .warning, area: "Orivio",
            "User cleared watch history (horizon \(clearedAt)) for profile \(profile)."
        )
        let progressKeys = progressStore.clearAllProgress(notify: false)
        let watchedItems = watchedStore.clearAll(notify: false)
        guard account.accessToken != nil else { return }
        if !progressKeys.isEmpty {
            deleteWatchProgress(keys: progressKeys)
            await drainPendingDeletes(profile: profile)
        }
        if !watchedItems.isEmpty {
            deleteWatchedItems(watchedItems, profile: profile)
            await drainPendingWatchedDeletes(profile: profile)
        }
        await pushAppPreferences(profile: profile)   // ship the clear point account-wide now
        OrivioSyncDiagnostics.record(.success, area: "Orivio", "Watch history cleared for profile \(profile).")
    }

    private func pushWatchProgressAll(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        // The store is scoped to the active profile, so reading it under any
        // other profile would upload the wrong history.
        try ensureProfile(profile)
        // Serialize OFF the main actor: this runs on every periodic progress
        // save during playback, and building dictionaries + JSON for the whole
        // history on main was a measurable playback hiccup.
        let snapshot = progressStore.serviceBackedForSync()
        let client = clientID
        let payload = await Task.detached(priority: .utility) {
            Self.encodeWatchProgressBody(snapshot, pid: profile, clientID: client)
        }.value
        guard let payload else {
            // Nothing to send (empty history, or every row filtered out): the
            // flag is still satisfied. Left set, it could never clear and every
            // sync re-attempted the no-op push. Same rule as pushWatchedItems.
            setDirty("progress", profile: profile, false)
            return
        }
        // The encode above suspends. The rows in `payload` are stamped with
        // `profile`; if the user has since switched, sending them would write
        // this profile's history under the other profile's id.
        try ensureProfile(profile)
        _ = try await send(endpoint: RPC.url(RPC.pushWatchProgress), method: "POST", body: payload)
        setDirty("progress", profile: profile, false)
        if !snapshot.isEmpty { setSeeded("progress", profile: profile) }
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
        // ONE entry per account row, keyed the way the account keys it (see
        // `ProgressStore.accountProgressKey`). Two rows here can be the same
        // episode under different keys until a pull folds them together, and
        // sent side by side the server applied whichever it met last — the
        // older position as often as not. The newest row per episode goes up.
        var newestByAccountKey: [String: WatchProgress] = [:]
        for wp in items {
            let key = ProgressStore.accountProgressKey(for: wp)
            if let held = newestByAccountKey[key],
               (held.updatedAt, held.id) >= (wp.updatedAt, wp.id) { continue }
            newestByAccountKey[key] = wp
        }
        let entries: [[String: Any]] = newestByAccountKey.compactMap { accountKey, wp in
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
                "progress_key": accountKey
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

    /// The key an account row is stored under on this device.
    ///
    /// The account names an episode `<content_id>_s<S>e<E>`; everything local
    /// — the player's saves, the details page, the Trakt and SIMKL merges —
    /// names it by its add-on video id. Kept under the account's key, a pulled
    /// episode was invisible to all of them: the player saved beside it under
    /// `tt…:2:2`, the next pull dropped that save as absent from the server,
    /// and a resume from the details page started from zero.
    ///
    /// An IMDb show's episodes are `tt…:season:episode` in every add-on (the
    /// same form `canonicalResumeIdentity` rebuilds). Another scheme's are
    /// whatever video id the writer sent, when it is an episode of this title;
    /// failing that, the account's key as before. Movies are unchanged.
    private nonisolated static func localProgressKey(for row: SupabaseWatchProgress) -> String {
        guard let season = row.season, let episode = row.episode else { return row.progressKey }
        if row.contentID.hasPrefix("tt") { return "\(row.contentID):\(season):\(episode)" }
        if row.videoID != row.progressKey, row.videoID.hasPrefix(row.contentID + ":") {
            return row.videoID
        }
        return row.progressKey
    }

    /// Account rows as store rows, under their local keys (`localProgressKey`),
    /// with each local key's account key beside it for the deletes a pull
    /// queues. The account stores ids and positions only, so the rows are bare.
    private nonisolated static func progressRows(
        fromAccount rows: [SupabaseWatchProgress]
    ) -> (rows: [WatchProgress], accountKeyByLocalID: [String: String]) {
        var accountKeyByLocalID: [String: String] = [:]
        var newestByLocalID: [String: SupabaseWatchProgress] = [:]
        for row in rows {
            let localID = localProgressKey(for: row)
            // Two account rows can land on one local key (a row another client
            // wrote under its own key). Keep the newest, never whichever came last.
            if let held = newestByLocalID[localID], held.lastWatched >= row.lastWatched { continue }
            newestByLocalID[localID] = row
            accountKeyByLocalID[localID] = row.progressKey
        }
        let progress = newestByLocalID.map { localID, row in
            WatchProgress(
                id: localID,
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
        return (progress, accountKeyByLocalID)
    }

    private var loggedWatchProgressColumns = false

    private func pullWatchProgress(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        let data = try await authedPost(RPC.url(RPC.pullWatchProgress), body: ["p_profile_id": profile])
        // The rows below belong to `profile`. Writing them into whichever store
        // scope is active when the response lands is exactly how one profile's
        // Continue Watching ended up merged into another's.
        try ensureProfile(profile)
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
        // Decoded OFF the main actor, like the collections pull: thousands of
        // rows every 30s (90s during playback) on @MainActor was the periodic
        // focus/scroll stutter for signed-in accounts.
        let rows = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode([SupabaseWatchProgress].self, from: data)
        }.value
        try ensureProfile(profile)
        let seeded = isSeeded("progress", profile: profile)
        if rows.isEmpty && !seeded {
            // Fresh account: keep local app/Stremio/Trakt rows and let the
            // following push upload them instead of treating empty as deletion.
            // (Nothing to converge either: no rows means no removed show can
            // still be sitting on the account.)
            return
        }
        // NB: after the first successful non-empty sync, an empty result is a
        // full snapshot and must reconcile deletions, e.g. when the last item
        // was removed elsewhere.

        let converted = Self.progressRows(fromAccount: rows)
        var pulled = converted.rows
        let accountKeyByLocalID = converted.accountKeyByLocalID
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
        // Rows for a show the user REMOVED here (and has not watched since)
        // are still on the account — the delete lost a race with a push, was
        // rejected, or the row is keyed the way another client keys it. The
        // store would refuse them, but hiding them locally is not enough:
        // queue their keys for deletion so the account converges and every
        // other device drops the card too. Dropped from this snapshot so
        // they cost no metadata lookups.
        let blocked = Set(progressStore.remoteKeysBlockedByRemoval(pulled))
        if !blocked.isEmpty {
            pulled.removeAll { blocked.contains($0.id) }
            NSLog("[OrivioCWSync] pullWatchProgress: %d row(s) belong to removed shows — queued for deletion",
                  blocked.count)
            // By the account's key: the local one names nothing there.
            deleteWatchProgress(keys: blocked.map { accountKeyByLocalID[$0] ?? $0 }, profile: profile)
        }
        // Metadata enrichment is a run of network calls; the store write after
        // it must still be going to the profile these rows came from.
        pulled = await enrichMetadata(pulled)
        try ensureProfile(profile)
        let before = progressStore.continueWatching(sortMode: .recentlyWatched).count
        progressStore.replaceWithOrivioSnapshot(pulled, preserveLocalAdditions: !seeded)
        if !pulled.isEmpty { setSeeded("progress", profile: profile) }
        // Catch-all: any Continue Watching card still labelled with its raw
        // "tt…" id — from THIS pull or any other source — resolves now, so a
        // synced row is never shown as its IMDb id.
        await enrichRawContinueWatchingTitles(profile: profile)
        let after = progressStore.continueWatching(sortMode: .recentlyWatched).count
        NSLog("[OrivioCWSync] pullWatchProgress: %d rows from account, continue-watching %d -> %d",
              rows.count, before, after)
    }

    /// Resolve real titles/art for any Continue Watching row still showing a
    /// raw "tt…" id and write them back to the store (presentation only — no
    /// push, no position change). Bounded by `enrichMetadata`'s own cap.
    private func enrichRawContinueWatchingTitles(profile: Int) async {
        guard pid == profile else { return }
        let raw = progressStore.continueWatching(sortMode: .recentlyWatched)
            .filter { Self.isRawSyncTitle($0.name, id: $0.metaID) }
        guard !raw.isEmpty else { return }
        let enriched = await enrichMetadata(raw)
            .filter { !Self.isRawSyncTitle($0.name, id: $0.metaID) }
        // Rows read from one profile's store, written back after a run of meta
        // fetches — the write has to land in the store they came from.
        guard !enriched.isEmpty, pid == profile else { return }
        progressStore.applyEnrichedMetadata(enriched)
    }

    /// The backend stores no titles/artwork with progress, so pulled Continue
    /// Watching rows arrive bare. Fill them in from a meta addon (Cinemeta) so
    /// the cards render, best-effort and capped.
    private func enrichMetadata(_ entries: [WatchProgress]) async -> [WatchProgress] {
        // A run of meta-addon requests. While a stream plays the sync stays
        // JSON-only; the next idle pass fills in titles and artwork.
        if Self.playbackActive { return entries }
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
            .filter { !Self.isRawSyncTitle($0.name, id: $0.metaID) }
            .map(\.metaID))
        // Raw-title rows resolve unconditionally so no card shows a bare "tt…".
        let rawTitleTokens = visible
            .filter { Self.isRawSyncTitle($0.name, id: $0.metaID) }
            .map { "\($0.metaID)|\($0.type)" }
        // Artwork-only backfill for already-titled rows is what the setting gates.
        let missingLocalTokens = enrichArtwork
            ? visible
                .filter { !localNamed.contains($0.metaID) }
                .map { "\($0.metaID)|\($0.type)" }
            : []
        let ids = Array(NSOrderedSet(array: rawTitleTokens + missingLocalTokens).compactMap { $0 as? String }).prefix(30)
        let requests: [(id: String, type: String)] = ids.compactMap { token in
            let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
        // A few lookups at a time instead of thirty in series — this ran
        // inside every progress pull, so it set the pace of the whole sync.
        let metas = await resolveSyncMetadata(requests)
        var metaByID: [String: MetaItem] = [:]
        for (request, meta) in zip(requests, metas) {
            if let meta { metaByID[request.id] = meta }
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
                newEpisodeCount: wp.newEpisodeCount
            )
        }
    }

    // MARK: - Library

    private func scheduleLibraryPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        libraryDirty = true
        let profile = pid   // the profile that changed
        pushLibraryTask?.cancel()
        pushLibraryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushLibrary(profile: profile)
        }
    }

    /// Set on any local library edit, cleared only once a push actually lands.
    /// Dirty ⇒ push BEFORE pulling: the library push is full-replace and the
    /// pull reconciles, so a pull that ran first would restore whatever the
    /// debounced push hadn't uploaded yet — and the following push would then
    /// re-upload the row the user had just removed (the remove/re-add
    /// ping-pong). Addons and profiles already work this way.
    private var libraryDirty: Bool {
        get { isDirty("library", profile: pid) }
        set { setDirty("library", profile: pid, newValue) }
    }

    // The library push is upsert-with-replace and has no per-item delete RPC,
    // so a removal only reaches the account as an ABSENCE from the next push.
    // That made removals the most fragile thing in the whole sync: if the app
    // was killed inside the 1.2s debounce, or the push failed once (offline,
    // token refresh), nothing anywhere remembered the deletion — the in-memory
    // tombstone died with the process and the next pull re-added the item
    // permanently. Queue removals to a PERSISTED per-profile set, exactly like
    // Continue Watching and watched items, and keep them until a push confirms.
    private func pendingLibraryDeletesKey(profile: Int) -> String {
        "orivio.sync.pendingLibraryDeletes.p\(profile)"
    }

    private func loadPendingLibraryDeletes(profile: Int) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingLibraryDeletesKey(profile: profile)) ?? [])
    }

    private func savePendingLibraryDeletes(_ set: Set<String>, profile: Int) {
        let key = pendingLibraryDeletesKey(profile: profile)
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(Array(set), forKey: key) }
    }

    private func queueLibraryDeletes(_ items: [SavedLibraryItem]) {
        var keys = Set(items.map(\.key))
        for item in items where item.id.hasPrefix("tt") {
            let alternateType = item.type == "series" ? "movie" : "series"
            keys.insert("\(alternateType)|\(item.id)")
        }
        guard !keys.isEmpty else { return }
        // Queued against the profile the removal was made on. This runs
        // synchronously from the store callback, so `pid` is still that profile.
        let profile = pid
        var pending = loadPendingLibraryDeletes(profile: profile)
        pending.formUnion(keys)
        savePendingLibraryDeletes(pending, profile: profile)
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
        return [400, 404].contains(status) && Self.looksLikeMissingRPC(body)
    }

    /// The body shape PostgREST returns when the function itself is absent from
    /// the deployment, as opposed to a refusal about the arguments.
    private static func looksLikeMissingRPC(_ body: String) -> Bool {
        body.localizedCaseInsensitiveContains("could not find the function")
            || body.localizedCaseInsensitiveContains("pgrst202")
            || body.localizedCaseInsensitiveContains("schema cache")
    }

    private func staleAlternateLibraryDeleteKeys(for items: [SavedLibraryItem]) -> Set<String> {
        var keys: Set<String> = []
        for item in items where item.id.hasPrefix("tt") {
            let alternateType = item.type == "series" ? "movie" : "series"
            keys.insert("\(alternateType)|\(item.id)")
        }
        return keys
    }

    private func deleteLibraryItems(keys: Set<String>, profile: Int) async throws {
        let payload = libraryDeletePayload(from: keys)
        guard !payload.isEmpty else { return }
        do {
            _ = try await authedPost(
                RPC.url(RPC.deleteLibraryItems),
                body: [
                    "p_keys": payload,
                    "p_profile_id": profile,
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
    /// - Parameter profile: pinned and passed through to `pushLibrary`. This
    ///   was the one path that reached the replace-semantics library push with
    ///   no profile gate in front of it at all.
    private func reconcileLibraryDeletesBeforePull(profile: Int) async {
        guard pid == profile else { return }
        let pending = loadPendingLibraryDeletes(profile: profile)
        if !pending.isEmpty { libraryStore.tombstone(Array(pending)) }
        if libraryDirty || !pending.isEmpty {
            try? await pushLibrary(profile: profile)
        }
    }

    private nonisolated static func metadataTypes(for type: String, id: String) -> [String] {
        let normalized = type.lowercased()
        let preferred = ["series", "tv", "show", "tvshow"].contains(normalized) ? "series" : "movie"
        guard id.hasPrefix("tt") else { return [preferred] }
        return preferred == "series" ? ["series", "movie"] : ["movie", "series"]
    }

    private nonisolated static func isRawSyncTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == id { return true }
        if trimmed.hasPrefix("tt") && trimmed.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    private nonisolated static func isUsefulMetadata(_ meta: MetaItem, for id: String) -> Bool {
        (!meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meta.name != id)
        || meta.poster != nil
        || meta.background != nil
    }

    private nonisolated static func resolveSyncMetadata(cinemeta: InstalledAddon, id: String, type: String) async -> MetaItem? {
        for lookupType in metadataTypes(for: type, id: id) {
            if let meta = try? await StremioAPI.meta(addon: cinemeta, type: lookupType, id: id),
               isUsefulMetadata(meta, for: id) {
                return meta
            }
        }
        return nil
    }

    /// Cinemeta lookups for a batch, a few at a time, results in input order.
    /// Bounded so a big backlog can't fan out into dozens of simultaneous
    /// requests on an Apple TV HD — but no longer one after another, which
    /// was most of what a sync spent its time on.
    private func resolveSyncMetadata(_ requests: [(id: String, type: String)]) async -> [MetaItem?] {
        guard !requests.isEmpty else { return [] }
        let cinemeta = AddonManager.bundledCinemeta()
        let limit = PerformanceProfile.isLowPower ? 2 : 4
        return await boundedConcurrentMap(requests, limit: limit) { request in
            await Self.resolveSyncMetadata(cinemeta: cinemeta, id: request.id, type: request.type)
        }
    }

    /// Library keys whose ARTWORK backfill has already been attempted this
    /// session. An item Cinemeta has no art for was looked up again on every
    /// push and pull — thirty round trips per sync, forever. Titles still
    /// showing a raw id are exempt (a real title matters more than a
    /// repeat lookup).
    private var artworkBackfillAttempted: Set<String> = []

    private func enrichLibraryMetadata(_ items: [SavedLibraryItem]) async -> [SavedLibraryItem] {
        if Self.playbackActive { return items }   // see enrichMetadata
        let rawTitleItems = items.filter { Self.isRawSyncTitle($0.name, id: $0.id) }
        let rawTitleKeys = Set(rawTitleItems.map(\.key))
        let artworkItems = items.filter { item in
            !rawTitleKeys.contains(item.key)
                && (item.poster == nil || item.background == nil)
                && !artworkBackfillAttempted.contains(item.key)
        }
        var seen = Set<String>()
        let candidates = (rawTitleItems + Array(artworkItems.prefix(30))).filter { seen.insert($0.key).inserted }
        guard !candidates.isEmpty else { return items }
        artworkBackfillAttempted.formUnion(artworkItems.prefix(30).map(\.key))

        let metas = await resolveSyncMetadata(candidates.map { (id: $0.id, type: $0.type) })
        var metaByKey: [String: MetaItem] = [:]
        for (item, meta) in zip(candidates, metas) {
            if let meta { metaByKey[item.key] = meta }
        }
        guard !metaByKey.isEmpty else { return items }
        return items.map { item in
            guard let meta = metaByKey[item.key] else { return item }
            return item.withFallbackMetadata(meta)
        }
    }

    /// - Parameter profile: the profile whose library this is, pinned by the
    ///   caller. `sync_push_library` REPLACES the account's rows for the
    ///   profile it is given, and this method reads the store, then spends
    ///   seconds in `enrichLibraryMetadata`, then built its body from a
    ///   freshly-read `pid` — so a profile switch during the enrichment sent
    ///   the OLD profile's items under the NEW profile's id and destroyed the
    ///   newly-selected profile's account library.
    private func pushLibrary(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        let rawItems = libraryStore.allForSync()
        let items = await enrichLibraryMetadata(rawItems)
        // Everything from here on writes `items` — read from `profile`'s store
        // — back to `profile`, on the server and locally.
        try ensureProfile(profile)
        if items != rawItems { libraryStore.mergeRemote(items, reconcile: false) }
        let pendingDeletes = loadPendingLibraryDeletes(profile: profile)
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
        guard !items.isEmpty || pulledLibraryProfiles.contains(profile) || !pendingDeletes.isEmpty
        else { return }
        // Built AND serialized off the main actor: a Trakt-watchlist-sized
        // library is thousands of dictionary rows, and this ran on @MainActor
        // every push tick.
        let clientID = self.clientID
        let payload = try await Task.detached(priority: .utility) {
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
                "p_profile_id": profile,
                "p_origin_client_id": clientID
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }.value
        // Last gate before a replace: the id in the body and the id the store
        // was read from are the same `profile`, and it is still the live one.
        try ensureProfile(profile)
        _ = try await authedPost(RPC.url(RPC.pushLibrary), payload: payload)
        // Never delete a key that is in the list we just uploaded: a removal
        // queued while offline, followed by a re-add before the queue drains,
        // would otherwise upsert the item and then immediately delete it
        // server-side — and the next reconciling pull would drop it here too.
        // ProgressStore guards this exact case (`dropPendingDeletesHeldLocally`);
        // the library push had no equivalent. The alternate-type cleanup below is
        // still applied.
        let heldKeys = Set(items.map(\.key))
        let accountDeleteKeys = pendingDeletes
            .subtracting(heldKeys)
            .union(staleAlternateLibraryDeleteKeys(for: items))
        try await deleteLibraryItems(keys: accountDeleteKeys, profile: profile)
        // The push landed, so the account now holds exactly `items` — every
        // queued removal it doesn't contain is done. (Replace semantics mean an
        // absence IS the delete.) Subtract only the snapshot we captured above,
        // so a removal made while this call was in flight still retries.
        if !pendingDeletes.isEmpty {
            var latest = loadPendingLibraryDeletes(profile: profile)
            latest.subtract(pendingDeletes)
            savePendingLibraryDeletes(latest, profile: profile)
        }
        // Only now is the account known to hold this device's list, so a later
        // pull may safely reconcile against it.
        setDirty("library", profile: profile, false)
        if !items.isEmpty { setSeeded("library", profile: profile) }
    }

    /// - Parameter profile: pinned by the caller and used for EVERY page. The
    ///   paging loop used to re-read `pid` per request, so a switch part-way
    ///   through pagination stitched two profiles' rows into one snapshot and
    ///   wrote the result into whichever store was active at the end.
    private func pullLibrary(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        var offset = 0
        let pageSize = 500
        var collected: [SavedLibraryItem] = []
        while true {
            let data = try await authedPost(
                RPC.url(RPC.pullLibrary),
                body: ["p_profile_id": profile, "p_limit": pageSize, "p_offset": offset]
            )
            try ensureProfile(profile)
            // Off-main decode: 500-row pages of nested JSON on @MainActor
            // stalled the UI on every library pull.
            // Map inside the same detached hop as the decode — the struct
            // construction over a 500-row page is main-actor work the sync
            // tick doesn't need.
            let (pageItems, rowCount) = try await Task.detached(priority: .utility) {
                let page = try JSONDecoder().decode([SupabaseLibraryItem].self, from: data)
                let mapped = page.map { row in
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
                return (mapped, page.count)
            }.value
            try ensureProfile(profile)
            collected.append(contentsOf: await enrichLibraryMetadata(pageItems))
            if rowCount < pageSize { break }
            offset += pageSize
        }
        // The enrichment inside the loop suspends too, so re-check before any
        // of it reaches a store or a per-profile flag.
        try ensureProfile(profile)
        // A successful pull (even an empty one) marks local as reconciled, so a
        // subsequent empty push is a genuine "cleared my library", not a race.
        pulledLibraryProfiles.insert(profile)
        if collected.isEmpty {
            // Empty snapshot: reconcile (delete local stale rows) only if this
            // profile has synced library data before — "the last item was
            // removed elsewhere". Unseeded = fresh account: keep local, the
            // following push uploads it.
            guard isSeeded("library", profile: profile) else { return }
            libraryStore.mergeRemote([])
            return
        }
        // First-ever pull for this profile merges additively (union → pushed
        // up); once seeded, pulls reconcile so removals propagate.
        let seeded = isSeeded("library", profile: profile)
        // `trusted: true` — this IS the Orivio account, the one source whose
        // `addedAt` round-trips as a real date. Without it the `removedItems`
        // record could never be lifted by a genuine re-add on another device:
        // this device would skip the title on every pull, and the next
        // replace-push would delete it from the account.
        libraryStore.mergeRemote(collected, reconcile: seeded, trusted: true)
        setSeeded("library", profile: profile)
    }

    // MARK: - Watched items

    /// Set on every local mark, cleared only by a push that landed. The
    /// debounced push swallows its error, so a mark whose one push hit a
    /// Wi-Fi blip was forgotten — and the next pull (which runs BEFORE the
    /// push in both sync paths) reconciled it away as remotely deleted once
    /// it aged past the grace window. Same shape as `libraryDirty`.
    private var watchedDirty: Bool {
        get { isDirty("watched", profile: pid) }
        set { setDirty("watched", profile: pid, newValue) }
    }

    private func scheduleWatchedPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        watchedDirty = true
        let profile = pid   // the profile that changed
        pushWatchedTask?.cancel()
        pushWatchedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushWatchedItems(profile: profile)
        }
    }

    // Watched removals reach the account durably, exactly like Continue
    // Watching: the push is upsert-only (it can't express a deletion), so an
    // un-marked item would resurrect on the next pull. Queue removals to a
    // PERSISTED per-profile set and drain them through
    // `sync_delete_watched_items` (the same RPC the Android app uses) until the
    // server confirms. Each token encodes content_id / season / episode.
    private func pendingWatchedDeletesKey(profile: Int) -> String {
        "orivio.sync.pendingWatchedDeletes.p\(profile)"
    }
    private static let watchedDeleteSeparator = "\u{1F}"

    private func loadPendingWatchedDeletes(profile: Int) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingWatchedDeletesKey(profile: profile)) ?? [])
    }

    private func savePendingWatchedDeletes(_ set: Set<String>, profile: Int) {
        let key = pendingWatchedDeletesKey(profile: profile)
        if set.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(Array(set), forKey: key) }
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

    /// - Parameter profile: the profile the un-mark happened on. Pass it
    ///   explicitly from any caller that has already suspended — reading `pid`
    ///   here would queue one profile's tokens against whichever profile is
    ///   active when the caller resumes, and drain them against that account.
    private func deleteWatchedItems(_ items: [WatchedItem], profile: Int) {
        let tokens = items.map { watchedDeleteToken($0) }
        guard !tokens.isEmpty else { return }
        var pending = loadPendingWatchedDeletes(profile: profile)
        pending.formUnion(tokens)
        savePendingWatchedDeletes(pending, profile: profile)
        Task { [weak self] in await self?.drainPendingWatchedDeletes(profile: profile) }
    }

    /// Send every queued watched removal, clearing only what the server
    /// confirmed. Payload mirrors the Android app: `p_keys` is an array of
    /// `{content_id, season, episode}` (season/episode null for movies).
    /// - Parameter profile: same rule as `drainPendingDeletes` — the queue this
    ///   was read from and the queue the confirmation clears must be one and
    ///   the same, whatever the user did while the request was in flight.
    private func drainPendingWatchedDeletes(profile: Int) async {
        let pending = loadPendingWatchedDeletes(profile: profile)
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
            "p_profile_id": profile,
            "p_origin_client_id": clientID
        ]
        do {
            _ = try await authedPost(RPC.url(RPC.deleteWatchedItems), body: body)
            var latest = loadPendingWatchedDeletes(profile: profile)
            latest.subtract(pending)   // keep anything queued while this was in flight
            savePendingWatchedDeletes(latest, profile: profile)
        } catch {
            // Leave the queue intact — a later drain retries it.
        }
    }

    /// Flush queued watched removals and reassert their tombstones before a
    /// pull, so a not-yet-confirmed delete can't be resurrected by the snapshot.
    private func reconcileWatchedDeletesBeforePull(profile: Int) async {
        guard pid == profile else { return }
        let pending = loadPendingWatchedDeletes(profile: profile)
        if !pending.isEmpty {
            watchedStore.tombstone(pending.compactMap { watchedKey(forToken: $0) })
        }
        await drainPendingWatchedDeletes(profile: profile)
    }

    private func pushWatchedItems(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        // The store read and the id in the body have to agree.
        try ensureProfile(profile)
        let items = watchedStore.allForSync()
        // Nothing to push means nothing left unpushed (removals travel by the
        // delete queue): clear the flag or it could never clear again.
        guard !items.isEmpty else { setDirty("watched", profile: profile, false); return }
        // Built AND serialized off the main actor — watched history reaches
        // Trakt-import scale (thousands of rows) and this ran on @MainActor.
        let clientID = self.clientID
        let payload = try await Task.detached(priority: .utility) {
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
                "p_profile_id": profile,
                "p_origin_client_id": clientID
            ]
            return try JSONSerialization.data(withJSONObject: body)
        }.value
        try ensureProfile(profile)
        _ = try await authedPost(RPC.url(RPC.pushWatchedItems), payload: payload)
        setSeeded("watched", profile: profile)   // items is non-empty (guarded above)
        setDirty("watched", profile: profile, false)
    }

    /// - Parameter profile: used for every page and for the store write, so a
    ///   switch mid-pagination can't stitch two profiles' history together.
    private func pullWatchedItems(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        var page = 1
        let pageSize = 900
        var collected: [WatchedItem] = []
        while true {
            let data = try await authedPost(
                RPC.url(RPC.pullWatchedItems),
                body: ["p_profile_id": profile, "p_page": page, "p_page_size": pageSize]
            )
            try ensureProfile(profile)
            // Off-main decode: watched history reaches Trakt-import scale
            // (900-row pages, thousands of rows) and was parsed on @MainActor
            // every sync tick.
            // Map inside the same detached hop as the decode: thousands of
            // struct constructions per 900-row page were landing back on the
            // main actor every sync tick.
            let (mapped, rowCount) = try await Task.detached(priority: .utility) {
                let rows = try JSONDecoder().decode([SupabaseWatchedItem].self, from: data)
                let mapped = rows.map { row in
                    WatchedItem(
                        contentID: row.contentID,
                        contentType: row.contentType,
                        title: row.title,
                        season: row.season,
                        episode: row.episode,
                        watchedAt: Date(timeIntervalSince1970: Double(row.watchedAt) / 1000.0)
                    )
                }
                return (mapped, rows.count)
            }.value
            try ensureProfile(profile)
            collected.append(contentsOf: mapped)
            if rowCount < pageSize { break }
            page += 1
        }
        if collected.isEmpty {
            // Same policy as library: an empty snapshot only reconciles when
            // this profile has synced watched data before (last item was
            // un-marked elsewhere); a fresh account keeps local history.
            guard isSeeded("watched", profile: profile) else { return }
            watchedStore.mergeRemote([])
            return
        }
        let seeded = isSeeded("watched", profile: profile)
        watchedStore.mergeRemote(collected, reconcile: seeded)
        setSeeded("watched", profile: profile)
    }

    // MARK: - Profiles

    /// A local profile edit is awaiting its debounced push. syncNow flushes it
    /// BEFORE pullProfiles — otherwise a just-created profile (push still
    /// pending) would be wiped by the pull's replaceRemote.
    private var profilesDirty = false

    private func scheduleProfilePush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        profilesDirty = true
        pushProfilesTask?.cancel()
        pushProfilesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            try? await self?.pushProfiles()
        }
    }

    func syncProfilesNow() {
        guard !isRetiringAccountState else { return }
        profilesDirty = true
        pushProfilesTask?.cancel()
        fullSyncTask?.cancel()
        fullSyncTask = Task { [weak self] in
            await self?.syncNow()
        }
    }

    /// - Parameter legacyDeletedIDs: only from `drainProfileDeletes`, on a
    ///   deployment without the dedicated delete RPC.
    private func pushProfiles(legacyDeletedIDs: [Int] = []) async throws {
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
        var body: [String: Any] = [
            "p_client_max_profiles": ProfileStore.maxProfiles,
            "p_profiles": entries,
            "p_origin_client_id": clientID
        ]
        // Deletions do NOT ride this push any more. The RPC upserts the rows
        // it is given and ignores what is missing, and a deployment without
        // the `p_deleted_profile_ids` hint refused the whole call — so every
        // profile push with a pending deletion was a 404 and a retry, and the
        // deletion itself never happened. See `drainProfileDeletes`.
        if !legacyDeletedIDs.isEmpty {
            body["p_deleted_profile_ids"] = legacyDeletedIDs
        }
        _ = try await authedPost(RPC.url(RPC.pushProfiles), body: body)
        profilesDirty = false   // only clear once the account actually has them
    }

    /// Send every profile deletion this device still owes the account, via
    /// `sync_delete_profile_data` — the same call the Android app makes. The
    /// tombstone in `ProfileStore` outlives this: only a pull that no longer
    /// lists the id retires it (`confirmProfileDeletions`), so a deletion the
    /// server has not accepted keeps being retried and keeps the profile out
    /// of the local list meanwhile.
    ///
    /// Deleting a profile used to be a local-only act. Its push carried a
    /// `p_deleted_profile_ids` hint the backend does not know, the push
    /// therefore failed and was retried without it, and nothing ever told the
    /// account to drop the row — so the next pull after a relaunch (when the
    /// in-memory tombstone was gone) put the profile straight back.
    private func drainProfileDeletes() async {
        let pending = profileStore.deletedProfileIDs
        guard !pending.isEmpty, account.accessToken != nil else { return }
        if profileDeleteRPCMissing {
            // No dedicated RPC on this deployment: the legacy hint on the
            // profile push is the only remaining way to say it.
            guard !legacyProfileDeleteHintMissing else { return }
            do {
                try await pushProfiles(legacyDeletedIDs: pending.sorted())
            } catch {
                if ignoresMissingRPC(error) { legacyProfileDeleteHintMissing = true }
                NSLog("[OrivioSync] legacy profile-deletion hint failed: %@", String(describing: error))
            }
            return
        }
        for id in pending.sorted() {
            do {
                _ = try await authedPost(RPC.url(RPC.deleteProfileData), body: ["p_profile_id": id])
                NSLog("[OrivioSync] deleted profile %d on the account", id)
                OrivioSyncDiagnostics.record(.info, area: "Orivio", "Deleted profile \(id) on the account.")
            } catch {
                if ignoresMissingRPC(error) {
                    profileDeleteRPCMissing = true
                    OrivioSyncDiagnostics.record(
                        .warning, area: "Orivio",
                        "This account has no profile-delete RPC; falling back to the profile push."
                    )
                    await drainProfileDeletes()
                    return
                }
                // Transport or auth trouble: the tombstone stays, the next
                // sync retries.
                NSLog("[OrivioSync] profile %d delete failed (retried next sync): %@", id, String(describing: error))
                OrivioSyncDiagnostics.record(
                    .warning, area: "Orivio",
                    "Couldn't delete profile \(id) on the account yet (\(describe(error))); it will be retried."
                )
            }
        }
    }

    private func pullProfiles() async throws {
        guard account.accessToken != nil else { return }
        let data = try await authedPost(RPC.url(RPC.pullProfiles), body: [:])
        let rows = try JSONDecoder().decode([SupabaseProfile].self, from: data)
        // Retire the tombstone for any locally-deleted profile the account no
        // longer reports — that pull is the only proof the delete landed.
        profileStore.confirmProfileDeletions(remoteIDs: Set(rows.map(\.profileIndex)))
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
        rescopePerProfileStores(id)
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

    /// A local edit is waiting on its debounced push.
    ///
    /// Same rule as `profilesDirty` / `addonsDirty` / `libraryDirty`, and it
    /// was missing here: these four stores each push on a 1.2-1.5s debounce
    /// and each PULL is a full-snapshot replace, so any sync that landed
    /// inside that window read the server's stale copy over the edit the user
    /// had just made — a deleted collection reappearing, a layout change
    /// reverting, a debrid key coming back — and then pushed the reverted
    /// state up as the new truth. `syncNow` now flushes each of these before
    /// the matching pull.
    /// All four are keyed per profile, like `addonsDirty`. As in-memory globals a
    /// profile switch inside the debounce let the NEW profile's push clear the
    /// flag the OLD profile's edit had set, so that edit never uploaded and the
    /// next reconciling pull overwrote it.
    private var collectionsDirty: Bool {
        get { isDirty("collections", profile: pid) }
        set { setDirty("collections", profile: pid, newValue) }
    }
    private var homeCatalogDirty: Bool {
        get { isDirty("homeCatalog", profile: pid) }
        set { setDirty("homeCatalog", profile: pid, newValue) }
    }
    private var badgeSettingsDirty: Bool {
        get { isDirty("badges", profile: pid) }
        set { setDirty("badges", profile: pid, newValue) }
    }
    private var providerCredentialsDirty: Bool {
        get { isDirty("providerCredentials", profile: pid) }
        set { setDirty("providerCredentials", profile: pid, newValue) }
    }

    private func scheduleCollectionsPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        collectionsDirty = true
        pushCollectionsTask?.cancel()
        pushCollectionsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushCollections(profile: self.pid)
        }
    }

    private func pushCollections(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        // The RPC replaces the whole blob; ship the JSON array as-is.
        // Encode + re-parse OFF the main actor: this is the same ~700 KB /
        // hundreds-of-folders blob whose synchronous main-thread DECODE froze
        // the 4K gen 1 (see CollectionsStore.load()) — the encode side was
        // still paying two full main-actor passes per push.
        let snapshot = collectionsStore.librarySnapshotForSync
        let collectionsValue: Any = await Task.detached(priority: .utility) {
            guard !snapshot.isEmpty,
                  let data = try? JSONEncoder().encode(snapshot),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return [Any]() }
            return obj
        }.value
        // The encode suspended; the blob belongs to `profile`.
        try ensureProfile(profile)
        let body: [String: Any] = [
            "p_profile_id": profile,
            "p_collections_json": collectionsValue,
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushCollections), body: body)
        // Explicit profile, not `pid`: the profile can switch during the await,
        // and clearing the NEW profile's flag would drop its pending edit.
        setDirty("collections", profile: profile, false)
        NSLog("[OrivioCollections] pushed %d collections to the shared table (p%d)",
              (collectionsValue as? [Any])?.count ?? 0, profile)
    }

    /// Whether the one-time "adopt every profile's collections into the shared
    /// library" scan has run. That scan pulls EVERY profile's row (1.4 MB and
    /// ~1000 folders on a real account) and is only needed to migrate packs
    /// that predate the shared library — repeating it on every 30s sync froze
    /// the Apple TV 4K gen 1.
    /// Persisted, not in-memory: as a plain property the "one-time" scan ran
    /// again on every launch, re-adopting collections the user had since
    /// deleted and re-reading every profile's row on the first sync each time.
    /// Lives under `orivio.sync.` so a different account signing in re-adopts.
    private static let adoptedCollectionsKey = "orivio.sync.adoptedAllProfileCollections.v1"
    private var adoptedAllProfileCollections: Bool {
        get { UserDefaults.standard.bool(forKey: Self.adoptedCollectionsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.adoptedCollectionsKey) }
    }

    private func pullCollections(profile: Int) async throws {
        guard let userID = account.currentUserID else { return }
        try ensureProfile(profile)
        // Steady state: just this profile's row, like every other pull.
        guard !adoptedAllProfileCollections else {
            try await pullCollections(forProfile: profile)
            return
        }
        // NOT set here: as a persisted flag, marking the scan done before the
        // request could fail meant one flaky connection disabled the migration
        // permanently, with no way to retrigger it short of signing out.
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
        // Gate BEFORE the flag: if the profile changed under us the run is
        // abandoned, and the migration must stay pending so the next sync
        // retries it rather than being marked done having applied nothing.
        try ensureProfile(profile)
        // A local edit is sitting un-flushed (its push failed, or it landed
        // while this request was in flight): merging now would replace the
        // edited copy with the account's stale one — the pull-clobber class.
        // Leave the adoption pending; the next sync retries after the flush.
        guard !collectionsDirty else { return }
        // The scan completed: record it now, on the success path only.
        adoptedAllProfileCollections = true
        guard !adopted.isEmpty else { return }
        let changed = collectionsStore.mergeIntoLibrary(adopted)
        if changed { libraryGrewDuringSync = true }
        NSLog("[OrivioCollections] shared library now %d collections (changed=%@)",
              collectionsStore.library.count, changed ? "yes" : "no")
    }

    /// Steady-state pull: only the pinned profile's row, decoded off-main.
    private func pullCollections(forProfile profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        let data = try await authedPost(RPC.url(RPC.pullCollections), body: ["p_profile_id": profile])
        let decoded: [OrivioCollection]? = await Task.detached(priority: .utility) {
            guard let rows = try? JSONDecoder().decode([SupabaseCollectionsBlob].self, from: data),
                  let blob = rows.first,
                  let json = blob.collectionsJSON.data(using: .utf8),
                  let lenient = try? JSONDecoder().decode([Lenient<OrivioCollection>].self, from: json)
            else { return nil }
            return lenient.compactMap(\.value)
        }.value
        guard let decoded, !decoded.isEmpty else { return }
        try ensureProfile(profile)
        // Same dirty guard as pullPlugins/pullAppPreferences: an edit whose
        // debounced push has not landed (or failed — the RPC is best-effort
        // and absent on the shared backend) must not be replaced by the
        // account's older copy, which the ID-keyed merge would let win.
        guard !collectionsDirty else {
            OrivioSyncDiagnostics.record(
                .warning, area: "Orivio",
                "Skipped applying \(decoded.count) collection(s) from the account — this device has a "
                    + "collection edit that hasn't uploaded yet, and applying now would overwrite it."
            )
            return
        }
        if collectionsStore.mergeIntoLibrary(decoded) { libraryGrewDuringSync = true }
    }

    // MARK: - Home catalog settings

    private func scheduleHomeCatalogPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        homeCatalogDirty = true
        pushHomeCatalogTask?.cancel()
        pushHomeCatalogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushHomeCatalogSettings(profile: self.pid)
        }
    }

    private func pushHomeCatalogSettings(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
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
        if let remote = try? await fetchHomeCatalogBlob(platform: HomeCatalogPlatform.shared, profile: profile),
           let remoteJSON = try? JSONSerialization.jsonObject(with: Data(remote.settingsJSON.utf8)) as? [String: Any] {
            merged = remoteJSON.merging(localJSON) { _, local in local }
        }

        let body: [String: Any] = [
            "p_profile_id": profile,
            "p_settings_json": merged,
            "p_platform": HomeCatalogPlatform.shared,
            "p_origin_client_id": clientID
        ]
        // The payload was read from `profile`'s store and read-merged against
        // `profile`'s row; the write has to go back to the same one.
        try ensureProfile(profile)
        _ = try await authedPost(RPC.url(RPC.pushHomeCatalogSettings), body: body)
        setDirty("homeCatalog", profile: profile, false)   // explicit profile; see pushCollections
    }

    private func pullHomeCatalogSettings(profile: Int) async throws {
        guard account.accessToken != nil else { return }
        try ensureProfile(profile)
        // Prefer the shared row; fall back to newest non-empty legacy row
        // (Android clients that predate the shared platform tag).
        var best: SyncHomeCatalogPayload?
        if let blob = try? await fetchHomeCatalogBlob(platform: HomeCatalogPlatform.shared, profile: profile),
           let payload = decodeHomeCatalogPayload(blob), !payload.isEmpty {
            best = payload
        } else {
            var newest: (payload: SyncHomeCatalogPayload, updatedAt: String)?
            for platform in HomeCatalogPlatform.legacy {
                guard let blob = try? await fetchHomeCatalogBlob(platform: platform, profile: profile),
                      let payload = decodeHomeCatalogPayload(blob), !payload.isEmpty else { continue }
                let stamp = blob.updatedAt ?? ""
                if newest == nil || stamp > newest!.updatedAt {
                    newest = (payload, stamp)
                }
            }
            best = newest?.payload
        }
        guard let payload = best else { return }   // nothing remote: keep local
        // Several requests happened above; this is `profile`'s layout and only
        // `profile`'s store may receive it.
        try ensureProfile(profile)
        homeCatalogSettings.applyRemote(payload)
        recordHomeCatalogReach(payload)
    }

    /// Say — in the log the viewer can actually read (Settings → Account) —
    /// how much of the pulled layout this device can act on.
    ///
    /// Two different things quietly swallow a phone's Home order, and neither
    /// used to leave any trace, so "my layout didn't come across" had no way
    /// of being told apart:
    ///
    /// * a key naming a catalog no add-on installed HERE declares — it is
    ///   dropped by `mergedOrder`, because there is no row to order;
    /// * Home's hard row cap (`maxHomeRows`) — rows past it keep their place
    ///   in the order and are simply never built, which on an account with
    ///   more catalogs than the cap is most of them.
    ///
    /// An account carrying well over a hundred catalogs hits the second every
    /// time, and that is expected rather than broken. Saying so — with the
    /// numbers — is the difference between a settled question and a bug report
    /// nobody can act on.
    private func recordHomeCatalogReach(_ payload: SyncHomeCatalogPayload) {
        let catalogKeys = payload.orderKeys.filter { !$0.hasPrefix("collection_") }
        guard !catalogKeys.isEmpty else { return }
        var available = Set<String>()
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                available.insert(HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id))
            }
        }
        let disabled = Set(payload.disabledKeys)
        let matched = catalogKeys.filter { available.contains($0) }
        let renderable = matched.filter { !disabled.contains($0) }
        let cap = AddonSweepLimits.maxHomeRows

        var message = "Home layout pulled: \(catalogKeys.count) catalog row(s) in the account's order; "
            + "\(matched.count) come from add-ons installed on this device"
        if matched.count < catalogKeys.count {
            message += ", \(catalogKeys.count - matched.count) name a catalog no add-on here declares"
        }
        message += "."
        // Collections are ordered by their own `collection_<id>` keys in the
        // same list. Counted separately because they are the part most likely
        // to be missing: a client that orders collections by the order of its
        // own collections array, rather than by writing keys here, leaves this
        // at zero — and then nothing about where they sit can cross over.
        let collectionOrderKeys = payload.orderKeys.filter { $0.hasPrefix("collection_") }
        let knownCollections = Set(collectionsStore.library.map {
            HomeCatalogSettingsStore.collectionKey($0.id)
        })
        if knownCollections.isEmpty {
            message += " No collections on this device."
        } else if collectionOrderKeys.isEmpty {
            message += " The layout carries NO collection positions"
                + " (\(knownCollections.count) collection(s) exist here), so they fall to the end of Home"
                + " in whatever order they loaded."
        } else {
            let placed = collectionOrderKeys.filter { knownCollections.contains($0) }.count
            message += " \(collectionOrderKeys.count) collection position(s) in the layout,"
                + " \(placed) matching a collection on this device."
        }
        if renderable.count > cap {
            message += " Home builds the first \(cap) of them — the rest keep their place in the order"
                + " but are not rendered, and stay reachable from Discover."
        }
        // A wholesale miss is the shape of a key-format mismatch rather than a
        // device simply having fewer add-ons, so it is worth flagging louder.
        let level: OrivioSyncLogEntry.Level = matched.isEmpty ? .warning : .info
        OrivioSyncDiagnostics.record(level, area: "Orivio", message)
    }

    private func fetchHomeCatalogBlob(platform: String, profile: Int) async throws -> SupabaseHomeCatalogSettingsBlob? {
        let data = try await authedPost(
            RPC.url(RPC.pullHomeCatalogSettings),
            body: ["p_profile_id": profile, "p_platform": platform]
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
    private func pullBadgeSettings(profile: Int) async -> String {
        guard let streamBadges else { return "Badge store unavailable" }
        guard account.accessToken != nil else { return "Sign in to your Orivio account first" }
        guard pid == profile else { return "Profile changed" }
        // Collect EVERY platform blob that carries a badge config, so the user
        // can pick between badge profiles instead of silently taking the first.
        // The six platform reads go out together — in series they were a
        // noticeable slice of every full sync.
        let blobs: [(platform: String, data: Data)] = await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, platform) in Self.settingsBlobPlatforms.enumerated() {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return (index, nil) }
                    let data = try? await self.authedPost(
                        RPC.url(RPC.pullProfileSettingsBlob),
                        body: ["p_profile_id": profile, "p_platform": platform]
                    )
                    return (index, data)
                }
            }
            var results = [Data?](repeating: nil, count: Self.settingsBlobPlatforms.count)
            for await (index, data) in group { results[index] = data }
            return zip(Self.settingsBlobPlatforms, results).compactMap { platform, data in
                data.map { (platform, $0) }
            }
        }
        // Bail if the profile moved while the reads were out rather than
        // mixing another profile's badge packs into this set.
        guard pid == profile else { return "Profile changed" }
        var found: [(platform: String, rules: String, count: Int)] = []
        var sawAnyBlob = false
        for (platform, data) in blobs {
            guard let blob = await Self.settingsBlobDetached(from: data) else { continue }
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
        // The detached parses above suspend — re-check the profile before
        // applying, same reason as the guard above the loop.
        guard pid == profile else { return "Profile changed" }
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
    ///
    /// Off-main wrapper: the blob physically contains the ~700 KB collections
    /// library as a string value, and the callers run on the 30s sync tick —
    /// parsing it on the main actor was tens of ms of recurring stall on the
    /// A8. (The INNER preferences decode was already off main; this outer
    /// parse was the missed half.)
    private static func settingsBlobDetached(from data: Data) async -> [String: Any]? {
        await Task.detached(priority: .utility) { settingsBlob(from: data) }.value
    }

    private nonisolated static func settingsBlob(from data: Data) -> [String: Any]? {
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

    /// The periodic sync's badge read, throttled per profile (see
    /// `lastBadgePull`). The Settings card's manual button calls
    /// `pullBadgeSettings` directly and is never throttled.
    private func pullBadgeSettingsIfDue(profile: Int) async {
        if let last = lastBadgePull[profile], Date().timeIntervalSince(last) < Self.badgePullInterval {
            return
        }
        lastBadgePull[profile] = Date()
        await pullBadgeSettings(profile: profile)
    }

    private func scheduleBadgeSettingsPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        badgeSettingsDirty = true
        pushBadgeSettingsTask?.cancel()
        pushBadgeSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushBadgeSettings(profile: self.pid)
        }
    }

    /// Push our badge config into the account. READ-MERGE-WRITE: fetch the
    /// current blob, replace only the stream_badge_settings feature, push the
    /// whole thing back — never clobbers the other features Android put there.
    private func pushBadgeSettings(profile: Int) async {
        guard let streamBadges, account.accessToken != nil,
              pid == profile,
              let rulesJSON = streamBadges.syncRulesJSON() else { return }

        var blob: [String: Any] = ["version": 1, "features": [String: Any]()]
        if let data = try? await authedPost(
            RPC.url(RPC.pullProfileSettingsBlob),
            body: ["p_profile_id": profile, "p_platform": Self.settingsBlobPlatform]
        ),
           let existing = await Self.settingsBlobDetached(from: data) {
            blob = existing
        }
        // Read-merge-WRITE: the blob we just read belongs to `profile`, so the
        // write must not be redirected to whichever profile is active now.
        guard pid == profile else { return }
        var features = blob["features"] as? [String: Any] ?? [:]
        var badgeFeature = features["stream_badge_settings"] as? [String: Any] ?? [:]
        badgeFeature["stream_badge_rules"] = ["type": "string", "value": rulesJSON]
        features["stream_badge_settings"] = badgeFeature
        blob["features"] = features
        if blob["version"] == nil { blob["version"] = 1 }

        let body: [String: Any] = [
            "p_profile_id": profile,
            "p_settings_json": blob,
            "p_platform": Self.settingsBlobPlatform,
            "p_origin_client_id": clientID,
        ]
        // Same rule as the credentials push: a failed upload must stay dirty
        // or the gated tail push never retries it.
        if (try? await authedPost(RPC.url(RPC.pushProfileSettingsBlob), body: body)) != nil {
            setDirty("badges", profile: profile, false)
        }
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
        /// Live TV channels this profile favourited, and which of them are
        /// pinned to Home. Optional for backward-compat.
        var liveChannels: [FavoriteChannel]?
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
    private var appPreferencesDirty: Bool {
        get { isDirty("appPreferences", profile: pid) }
        set { setDirty("appPreferences", profile: pid, newValue) }
    }
    private var appPrefsGeneration = 0

    private func scheduleAppPreferencesPush() {
        guard !isRetiringAccountState else { return }
        appPreferencesDirty = true
        appPrefsGeneration += 1
        pushAppPreferencesTask?.cancel()
        pushAppPreferencesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushAppPreferences(profile: self.pid)
        }
    }

    /// JSON → snapshot on a background thread; nil on any decode failure.
    nonisolated private static func decodeAppPreferences(_ json: String) async -> AppPreferencesSnapshot? {
        await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode(AppPreferencesSnapshot.self, from: Data(json.utf8))
        }.value
    }

    /// Snapshot → JSON on a background thread, for the same reason as the
    /// decode above: this blob carries the whole collections library.
    nonisolated private static func encodeAppPreferences(_ snapshot: AppPreferencesSnapshot) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// The payload this session last successfully pushed, with the profile it
    /// belonged to — lets an identical repeat push skip its two round trips.
    private var lastPushedAppPrefs: (profile: Int, json: String)?

    /// Pull the tvOS preferences feature (if present) and apply it to the three
    /// stores. Best-effort: any decode failure leaves local settings untouched.
    private func pullAppPreferences(profile: Int) async {
        guard account.accessToken != nil, pid == profile,
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
            body: ["p_profile_id": profile, "p_platform": Self.settingsBlobPlatform]
        ) else { return }
        // This blob is `profile`'s. Applying it to another profile's stores
        // would import that profile's collections, hidden sets and theme.
        guard pid == profile else { return }
        let parsed = await Self.settingsBlobDetached(from: data)
        // The detached parse suspends — a profile switch during it must not
        // touch this profile's bookkeeping at all.
        guard pid == profile else { return }
        guard let blob = parsed,
              let features = blob["features"] as? [String: Any],
              let feature = features[Self.appPrefsFeatureKey] as? [String: Any],
              let json = Self.preferenceString(feature["value"])
        else {
            // The account carries no tvOS-preferences blob for this profile (a
            // fresh account, or it was cleared elsewhere). Forget what we last
            // pushed so this sync's push re-uploads it in full instead of being
            // skipped as "already up there".
            lastPushedAppPrefs = nil
            return
        }
        // Decode OFF the main actor. This blob embeds the entire collections
        // library — the same ~700 KB of nested JSON whose synchronous main-thread
        // decode froze the Apple TV at launch (see CollectionsStore.load()) —
        // and a sync runs every 60-90s, so it was stalling the UI on a timer.
        guard let snapshot = await Self.decodeAppPreferences(json) else { return }
        guard pid == profile else { return }
        guard !appPreferencesDirty, appPrefsGeneration == generationAtStart else {
            OrivioSyncDiagnostics.record(
                .info, area: "Orivio",
                "Skipped applying account preferences: a local change landed while pulling."
            )
            return
        }
        // The account now holds something different from whatever this
        // session last pushed, so the "identical payload, skip the push" memo
        // below is stale. Left set, changing a preference back to its previous
        // value cleared the dirty flag WITHOUT pushing, and the next pull
        // reverted it.
        lastPushedAppPrefs = nil
        playerSettings.applyRemote(snapshot.player)
        tmdbSettings.applyRemote(snapshot.tmdb)
        themeManager.applyRemote(snapshot.theme)
        WatchHistoryClearState.adopt(snapshot.watchHistoryClearedAt)
        if let home = snapshot.home { homeCatalogSettings.applyRemotePresentation(home) }
        if let debrid = snapshot.debrid { debridStore?.applyRemote(debrid) }
        // Awaited, not fired into an unstructured Task: this used to return
        // while repos were still installing, and `pushPlugins` — which is
        // replace-semantics — could read a half-applied list and delete the
        // rest from the account. The dirty guard matches `pullPlugins`: a
        // snapshot fetched before a local repo edit must not re-install what
        // the user just removed.
        if let plugins = snapshot.plugins, let pluginStore, !pluginsDirty {
            await pluginStore.applyRemote(plugins)
            guard pid == profile else { return }
        }
        if let torrent = snapshot.torrent { torrentSettings?.applyRemote(torrent) }
        if let collections = snapshot.collections, !collectionsDirty {
            // Merge rather than replace: another profile's blob may carry packs
            // this one has never seen, and the library is account-wide. Dirty-
            // guarded like the pulls above: a blob fetched before a local edit
            // must not clobber it.
            if collectionsStore.mergeIntoLibrary(collections) { libraryGrewDuringSync = true }
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
        if let liveChannels = snapshot.liveChannels {
            LiveChannelFavorites.shared.applyRemote(liveChannels)
        }
    }

    /// READ-MERGE-WRITE: fetch the blob, replace only our own feature key, push
    /// it all back so the badge feature and Android's features survive intact.
    private func pushAppPreferences(profile: Int) async {
        guard account.accessToken != nil, pid == profile,
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
            watchHistoryClearedAt: WatchHistoryClearState.clearedAt,
            liveChannels: LiveChannelFavorites.shared.snapshot
        )
        guard let json = await Self.encodeAppPreferences(snapshot) else { return }
        // syncNow flushes a dirty push BEFORE the pulls and pushes again at the
        // END of the same run, so an unchanged blob — the whole collections
        // library included — was read-merge-written to the account TWICE per
        // sync. If the payload is byte-identical to the one this run already
        // shipped, the account already holds exactly this; skip both round
        // trips. (Keyed by profile: the blob is per-profile.)
        // The encode above suspends, so re-check: the snapshot was read from
        // `profile`'s stores and everything below writes it to `profile`'s row.
        guard pid == profile else { return }
        if let last = lastPushedAppPrefs, last.profile == profile, last.json == json {
            if appPrefsGeneration == generationAtStart { setDirty("appPreferences", profile: profile, false) }
            return
        }

        var blob: [String: Any] = ["version": 1, "features": [String: Any]()]
        if let existingData = try? await authedPost(
            RPC.url(RPC.pullProfileSettingsBlob),
            body: ["p_profile_id": profile, "p_platform": Self.settingsBlobPlatform]
        ),
           let existing = await Self.settingsBlobDetached(from: existingData) {
            blob = existing
        }
        guard pid == profile else { return }
        var features = blob["features"] as? [String: Any] ?? [:]
        features[Self.appPrefsFeatureKey] = ["type": "string", "value": json]
        blob["features"] = features
        if blob["version"] == nil { blob["version"] = 1 }

        let body: [String: Any] = [
            "p_profile_id": profile,
            "p_settings_json": blob,
            "p_platform": Self.settingsBlobPlatform,
            "p_origin_client_id": clientID,
        ]
        if (try? await authedPost(RPC.url(RPC.pushProfileSettingsBlob), body: body)) != nil {
            // Remember what the account now holds, so a second push in the same
            // sync with identical content is a no-op (see the check above).
            lastPushedAppPrefs = (profile, json)
            if appPrefsGeneration == generationAtStart {
                // Clear only if no NEWER edit arrived while this push was in
                // flight — that edit's own flag/push must survive. Explicit
                // profile: a switch during the await must not clear the new one.
                setDirty("appPreferences", profile: profile, false)
            }
        }
    }

    // MARK: - Provider credentials (debrid keys + Trakt) — Android table

    /// Maps our DebridProvider to the Android provider-credential name. AllDebrid
    /// isn't a synced provider on Android, so it stays blob-only.
    private static let debridProviderNames: [(DebridProvider, String)] = [
        (.realDebrid, "realdebrid"), (.premiumize, "premiumize"), (.torbox, "torbox")
    ]

    private func scheduleProviderCredentialsPush() {
        guard !isRetiringAccountState else { return }
        providerCredentialsDirty = true
        pushProviderCredentialsTask?.cancel()
        pushProviderCredentialsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pushProviderCredentials(profile: self.pid)
        }
    }

    /// Push debrid API keys and the Trakt login into the shared
    /// `provider_credentials` table. Each row is
    /// `{provider, credential_json, updated_at}`; `p_credentials` carries them.
    private func pushProviderCredentials(profile: Int) async {
        guard account.accessToken != nil, pid == profile else { return }
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
            "p_profile_id": profile,
            "p_origin_client_id": clientID
        ]
        // Only once the account actually has them. Clearing unconditionally
        // meant a single failed POST (Wi-Fi blip, 502) dropped the debrid key
        // or Trakt login for good: with the tail push now gated on this flag,
        // nothing ever retried it.
        if (try? await authedPost(RPC.url(RPC.pushProviderCredentials), body: body)) != nil {
            setDirty("providerCredentials", profile: profile, false)
        }
    }

    /// Pull provider credentials and apply them. Tolerant: `credential_json` may
    /// arrive as an object or a JSON string, and inner keys may be snake- or
    /// camel-case — so debrid keys and Trakt logins added on the phone show up
    /// here regardless of exactly how that client serialized them.
    private func pullProviderCredentials(profile: Int) async {
        guard account.accessToken != nil, pid == profile else { return }
        guard let data = try? await authedPost(
            RPC.url(RPC.pullProviderCredentials), body: ["p_profile_id": profile]
        ) else { return }
        // Trakt logins can be per-profile (TraktStore.setProfile), so these
        // rows must not be applied to a store that has since re-scoped.
        guard pid == profile else { return }
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
    /// restore a repo the user just removed. Per profile like `addonsDirty`.
    private var pluginsDirty: Bool {
        get { isDirty("plugins", profile: pid) }
        set { setDirty("plugins", profile: pid, newValue) }
    }

    private func schedulePluginsPush() {
        // Never while the previous account's state is being retired: the
        // store callbacks that retirement fires would arm a push of account A's
        // data into account B. See `isRetiringAccountState`.
        guard !isRetiringAccountState else { return }
        pluginsDirty = true
        pushPluginsTask?.cancel()
        pushPluginsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            try? await self.pushPlugins(profile: self.pid)
        }
    }

    /// The profile whose plugin rows this device reads/writes. Mirrors Android:
    /// a profile flagged "uses primary plugins" shares profile 1's rows, so a
    /// push from that profile must not fork its own plugin set.
    private func pluginPID(for profile: Int) -> Int {
        // Shared mode (the "Separate plugins per profile" switch is off) is
        // "every profile uses primary": one list, canonical at profile 1's
        // rows, so every device sharing the account converges on it.
        guard ProfileScopedDefaults.isSeparate(PluginStore.feature) else { return 1 }
        let active = profileStore.allForSync().first { $0.id == profile }
        return (active?.usesPrimaryPlugins ?? true) ? 1 : profile
    }

    /// Same fallback for add-ons: a profile marked "use primary add-ons" —
    /// or a device with the separate-add-ons switch off entirely — reads and
    /// writes profile 1's list, locally and on the wire (the upstream
    /// semantics of `uses_primary_addons` on the profile row).
    private func addonPID(for profile: Int) -> Int {
        guard ProfileScopedDefaults.isSeparate(AddonManager.feature) else { return 1 }
        let active = profileStore.allForSync().first { $0.id == profile }
        return (active?.usesPrimaryAddons ?? true) ? 1 : profile
    }

    /// Push plugin repos to the dedicated `plugins` table (`sync_push_plugins`),
    /// mirroring the Android row shape: url/name/enabled/sort_order/repo_type.
    /// tvOS scrapers are Orivio JS repos → repo_type "ORIVIO_JS".
    private func pushPlugins(profile: Int) async throws {
        guard account.accessToken != nil, let pluginStore else { return }
        try ensureProfile(profile)
        let repos = pluginStore.repositories
        // An empty push is how "I removed my last repo" reaches the account —
        // but only when this device actually made that edit (`pluginsDirty`).
        // Blanket-skipping empty meant removing the last repo never synced and
        // the next pull put it straight back; blanket-allowing it would let a
        // fresh device wipe the account before its first pull.
        guard !repos.isEmpty || pluginsDirty else { return }
        // Same reasoning as the add-on push: not before this account's list has
        // been read, or a switch uploads the previous user's repos.
        guard pulledPluginProfiles.contains(profile) || pluginsDirty else { return }
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
            "p_profile_id": pluginPID(for: profile),
            "p_origin_client_id": clientID
        ]
        _ = try await authedPost(RPC.url(RPC.pushPlugins), body: body)
        setDirty("plugins", profile: profile, false)
        if !repos.isEmpty { setSeeded("plugins", profile: profile) }
    }

    /// Pull plugin repos via a PostgREST table select (there's no dedicated pull
    /// RPC — the Android app reads the table directly too). tvOS only needs the
    /// URLs; PluginStore re-fetches each manifest and installs missing ones.
    private func pullPlugins(profile: Int) async {
        guard let userID = account.currentUserID, let pluginStore, pid == profile else { return }
        let path = "/rest/v1/plugins?user_id=eq.\(userID)&profile_id=eq.\(pluginPID(for: profile))&select=url,repo_type,sort_order,enabled"
        guard let data = try? await authedGet(path),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        guard pid == profile else { return }
        pulledPluginProfiles.insert(profile)
        // Same rule as pullAddons: a snapshot fetched while a local repo edit
        // awaits its push predates that edit, and applying it re-installs the
        // repo the user just removed — which the debounced push then uploads
        // back to the account. Skip; the dirty push goes first next cycle.
        guard !pluginsDirty else {
            NSLog("[OrivioSync] pullPlugins: skipped applying — a local repo edit is awaiting its push")
            return
        }
        let urls = rows
            .filter { ($0["repo_type"] as? String)?.uppercased() != "EXTERNAL_DEX" }  // JS only
            .filter { ($0["enabled"] as? Bool) ?? true }   // don't install repos disabled elsewhere
            .compactMap { $0["url"] as? String }
        let seeded = isSeeded("plugins", profile: profile)
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
        setSeeded("plugins", profile: profile)
    }

    private func authedPost(_ endpoint: String, body: [String: Any]) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await send(endpoint: endpoint, method: "POST", body: payload)
    }

    /// For bodies whose JSON was built off the main actor (the Trakt-scale
    /// library/watched pushes) — the serialization is the expensive half.
    private func authedPost(_ endpoint: String, payload: Data) async throws -> Data {
        try await send(endpoint: endpoint, method: "POST", body: payload)
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
