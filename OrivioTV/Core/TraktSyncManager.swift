import Combine
import Foundation
import UIKit

/// Two-way sync between the app and Trakt: watch history / watched badges
/// (WatchedStore ↔ Trakt history) and Continue Watching (Trakt playback
/// progress → ProgressStore). Local scrobbling already pushes playback the
/// other way. Sits alongside OrivioSyncManager (the account backend) — Trakt is
/// a separate, opt-in destination.
@MainActor
final class TraktSyncManager: ObservableObject {
    private let trakt: TraktStore
    private let watched: WatchedStore
    private let progress: ProgressStore
    private let library: LibraryStore
    private let ratings: RatingsStore
    private let addonManager: AddonManager

    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    /// Throttle full syncs so foreground + timer + sign-in don't stack up.
    private var lastFullSync = Date.distantPast

    init(trakt: TraktStore, watched: WatchedStore, progress: ProgressStore,
         library: LibraryStore, ratings: RatingsStore, addonManager: AddonManager) {
        self.trakt = trakt
        self.watched = watched
        self.progress = progress
        self.library = library
        self.ratings = ratings
        self.addonManager = addonManager

        // LOCAL → TRAKT: immediate push on each kind of local change.
        watched.onTrackerMark.append { [weak self] item in self?.pushMark(item) }
        watched.onTrackerRemove.append { [weak self] items in self?.pushRemove(items) }
        library.onTrackerAdd.append { [weak self] item in self?.pushWatchlistAdd(item) }
        library.onTrackerRemove.append { [weak self] item in self?.pushWatchlistRemove(item) }
        ratings.onTrackerRate.append { [weak self] id, type, r in self?.pushRating(id, type, r) }
        ratings.onTrackerUnrate.append { [weak self] id, type in self?.pushUnrate(id, type) }
        progress.onTrackerProgressRemove.append { [weak self] metaID in self?.pushPlaybackRemove(metaID) }
        // Toggling a Trakt sync setting on kicks a full sync.
        trakt.onTraktSettingChange = { [weak self] in self?.syncNow(force: true) }
        trakt.onClearContinueWatching = { [weak self] in
            Task { @MainActor in await self?.clearTraktContinueWatching() }
        }

        // Sync the moment we become signed in (device-code login completes, or
        // tokens arrive from account sync) — and once now if already signed in.
        // Without this, a fresh sign-in didn't sync until the next relaunch.
        trakt.$accessToken
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                // Someone who just completed the device-code login is sitting
                // there waiting for their history: sync immediately.
                if self?.trakt.didSignInInteractively == true {
                    // One main-actor turn later: `@Published` notifies from
                    // `willSet`, so syncNow's own signed-in guard would still
                    // see the PREVIOUS (signed-out) value and skip the very
                    // sync this sign-in is waiting for.
                    Task { @MainActor [weak self] in self?.syncNow(force: true) }
                    return
                }
                // A token restored at launch is deferred, like the Stremio and
                // account syncs. `@Published` delivers its CURRENT value on
                // subscribe, so this otherwise fired during app construction and
                // ran four network phases in series against the Home catalog
                // sweep — and its watched-store merge re-triggered the Next Up
                // refetch on top. None of that has to happen before the first
                // screen is usable.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.syncNow(force: true)
                }
            }
            .store(in: &cancellables)

        // Being signed in is all it takes for the sync to run on its own —
        // the Orivio account is not a prerequisite for it. See `startAutoSync`.
        trakt.$accessToken
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if signedIn { self?.startAutoSync() } else { self?.stopAutoSync() }
            }
            .store(in: &cancellables)

        // Coming back to the app is the other moment a viewer expects their
        // history to be current — another device may have watched things while
        // this one was asleep.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard self?.trakt.isSignedIn == true else { return }
                self?.syncNow()   // throttled; a foreground burst can't stack
            }
            .store(in: &cancellables)
    }

    // MARK: - Auto sync

    /// How often a signed-in Trakt account reconciles on its own.
    ///
    /// There was NO periodic Trakt sync at all: history and Continue Watching
    /// only reconciled at sign-in, on a local change, or when a setting was
    /// flipped — so anything watched on another device (the phone, the web,
    /// another box) never appeared until the app was relaunched. Five minutes
    /// is well inside Trakt's rate limits for the handful of list endpoints a
    /// run touches, and `syncNow`'s own 60s throttle still collapses this
    /// against sign-in and foreground triggers.
    private static let autoSyncInterval: TimeInterval = 5 * 60
    private var autoSyncTask: Task<Void, Never>?

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoSyncInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard trakt.isSignedIn else { continue }
                // Never mid-stream: the account sync drops to a light pass
                // during playback for the same reason — a multi-endpoint
                // reconcile competing with the movie for bandwidth.
                guard !OrivioSyncManager.playbackActive else { continue }
                syncNow()
            }
        }
    }

    private func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    // MARK: - Full sync

    /// Run a full two-way sync (debounced). `force` bypasses the throttle
    /// (sign-in, manual "Sync now", a setting flip).
    func syncNow(force: Bool = false) {
        guard trakt.isSignedIn else {
            NSLog("[OrivioTrakt] syncNow skipped — not signed in")
            return
        }
        if !force, Date().timeIntervalSince(lastFullSync) < 60 { return }
        lastFullSync = Date()
        // Don't cancel an in-flight sync — a rapid second trigger (sign-in +
        // foreground) used to abort the first mid-way. Coalesce instead — but
        // REMEMBER the request: a profile switch during a run must sync the
        // newly selected profile once the run ends, not be dropped (there is
        // no periodic Trakt timer to pick it up later).
        if let t = syncTask, !t.isCancelled { rerunRequested = true; return }
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncTask = nil
            if self?.rerunRequested == true {
                self?.rerunRequested = false
                self?.syncNow(force: true)
            }
        }
    }

    /// A sync was requested while one was running; run again when it ends.
    private var rerunRequested = false

    /// The run belongs to the profile that started it. With per-profile Trakt
    /// accounts, a switch mid-run re-scopes every store AND the token — an
    /// unpinned run merged profile A's history into profile B's stores and
    /// pushed B's local-only rows to A's Trakt account. Every phase re-checks
    /// this after each await before it touches a store or issues a write.
    private func profileStillActive(_ profile: Int) -> Bool { trakt.profileID == profile }

    private func runSync() async {
        NSLog("[OrivioTrakt] runSync start (history=%d playback=%d watchlist=%d ratings=%d)",
              trakt.syncWatchHistory ? 1 : 0, trakt.syncPlayback ? 1 : 0,
              trakt.syncWatchlist ? 1 : 0, trakt.syncRatings ? 1 : 0)
        let profile = trakt.profileID
        guard let token = await validToken() else {
            NSLog("[OrivioTrakt] runSync aborted — no valid token")
            trakt.setSyncStatus("Trakt session expired — sign in again")
            return
        }
        guard profileStillActive(profile) else {
            NSLog("[OrivioTrakt] runSync abandoned — profile switched during token check")
            return
        }
        var parts: [String] = []
        if trakt.syncWatchHistory {
            let n = await syncWatchHistory(token: token, profile: profile)
            parts.append("\(n) history")
        }
        if trakt.syncPlayback {
            let n = await pullPlayback(token: token, profile: profile)
            if n > 0 { parts.append("\(n) in-progress") }
        }
        guard profileStillActive(profile) else {
            NSLog("[OrivioTrakt] runSync abandoned — profile switched mid-run")
            return
        }
        // Watchlist and ratings touch different stores from each other and from
        // the two phases above (LibraryStore and RatingsStore respectively), so
        // they run together. History and playback stay sequential: both write
        // progress/watched state and the order between them is load-bearing.
        async let watchlistCount: Int? = trakt.syncWatchlist ? await syncWatchlist(token: token, profile: profile) : nil
        async let ratingsCount: Int? = trakt.syncRatings ? await syncRatings(token: token, profile: profile) : nil
        if let n = await watchlistCount { parts.append("\(n) watchlist") }
        if let n = await ratingsCount { parts.append("\(n) ratings") }
        NSLog("[OrivioTrakt] runSync done: %@", parts.joined(separator: ", "))
        trakt.setSyncStatus(parts.isEmpty ? "Trakt: nothing to sync" : "Trakt synced (\(parts.joined(separator: ", ")))")
    }

    /// Two-way watch history. Pull Trakt → add missing locally; push local
    /// items Trakt doesn't have. Returns the count pulled.
    private func syncWatchHistory(token: String, profile: Int) async -> Int {
        let remote = await TraktService.watchedHistory(accessToken: token)
        guard profileStillActive(profile) else { return 0 }
        let clearedAt = WatchHistoryClearState.clearedAt
        // The transform is O(remote × local) value work — struct building,
        // key-string interpolation, set construction over a flattened
        // per-episode history that runs to thousands after a Trakt import.
        // The JSON decode was already off main; this landed the transform
        // back on the main actor every 5-min tick and every foreground.
        // Local rows are snapshotted BEFORE the merge below: a row the merge
        // adds is one Trakt already has, so it is excluded by `remoteKeys`
        // either way.
        let localRows = watched.allForSync()
        let (remoteItems, pushable) = await Task.detached(
            priority: .utility
        ) { [self] () -> ([WatchedItem], [TraktService.SyncItem]) in
            let remoteItems = remote.compactMap(watchedItem(from:)).filter { item in
                guard let clearedAt else { return true }
                return item.watchedAt > clearedAt
            }
            // Push anything local that Trakt is missing. Keyed off EVERY
            // remote row in both id forms — a row dropped by the
            // clear-horizon filter above is still a row Trakt has, and
            // re-sending it achieves nothing.
            let remoteKeys = Set(remote.flatMap { s in
                localIDs(from: s).map { WatchedItem.key(contentID: $0, season: s.season, episode: s.episode) }
            })
            let pushable = localRows.filter { !remoteKeys.contains($0.key) }
                .compactMap(syncItem(from:))
            return (remoteItems, pushable)
        }.value
        guard profileStillActive(profile) else { return 0 }
        // Add Trakt items missing locally (additive — never delete local
        // history from a partial Trakt response). Anything new goes on to the
        // Orivio account as well.
        if !remoteItems.isEmpty, watched.mergeRemote(remoteItems, reconcile: false) {
            watched.requestSyncPush()
        }
        if !pushable.isEmpty {
            _ = await TraktService.addToHistory(pushable, accessToken: token)
        }
        return remoteItems.count
    }

    /// Pull Trakt playback progress into Continue Watching (additive), enriched
    /// with meta for artwork + runtime — then push LOCAL Continue Watching rows
    /// Trakt is missing (scrobble-pause sets their playback position there).
    /// Returns count pulled.
    private func pullPlayback(token: String, profile: Int) async -> Int {
        // Keep anything genuinely in progress — dropping ≤1% hid barely-started
        // titles that Trakt showed. ≥95% still counts as finished, matching the
        // player's own auto-clear threshold. nil = the fetch FAILED — bail out
        // entirely rather than mistaking an outage for an empty list.
        guard let remote = await TraktService.playbackProgress(accessToken: token) else { return 0 }
        guard profileStillActive(profile) else { return 0 }
        let clearedAt = WatchHistoryClearState.clearedAt
        let items = remote.filter { item in
            let progress = item.progress ?? 0
            guard progress > 0, progress < 95 else { return false }
            guard let clearedAt else { return true }
            return (item.watchedAt ?? .distantPast) > clearedAt
        }
        // Artwork/runtime for the first 25, fetched a few at a time rather
        // than one after another: twenty-five sequential meta round trips was
        // most of the time a Trakt sync took.
        let mapped: [(item: TraktService.SyncItem, metaID: String, addon: InstalledAddon?)] =
            items.enumerated().compactMap { index, s in
                guard let metaID = localID(from: s) else { return nil }
                let addon = index < 25 ? addonManager.metaAddon(for: s.type, id: metaID) : nil
                return (s, metaID, addon)
            }
        let metas = await Self.fetchMetas(mapped.map { ($0.addon, $0.item.type, $0.metaID) })
        var rows: [WatchProgress] = []
        for (index, entry) in mapped.enumerated() {
            let s = entry.item
            let metaID = entry.metaID
            let key: String
            if s.type == "series", let sea = s.season, let ep = s.episode {
                key = "\(metaID):\(sea):\(ep)"
            } else { key = metaID }

            var name = s.title
            var poster: String?
            var background: String?
            var runtimeMin: Int?
            if let meta = metas[index] {
                if !meta.name.isEmpty { name = meta.name }
                poster = meta.poster
                background = meta.background
                runtimeMin = Self.parseRuntimeMinutes(meta.runtime)
            }
            let dur = Double((runtimeMin ?? (s.type == "series" ? 45 : 100)) * 60)
            let pos = dur * (s.progress ?? 0) / 100
            rows.append(WatchProgress(
                id: key, metaID: metaID, type: s.type, name: name,
                poster: poster, background: background, logo: nil,
                season: s.season, episode: s.episode, episodeTitle: nil,
                positionSeconds: pos, durationSeconds: dur, streamURL: nil,
                updatedAt: s.watchedAt ?? SyncTimestamp.unknown, syncSource: "trakt"))
        }
        // The meta enrichment above awaits.
        guard profileStillActive(profile) else { return 0 }
        progress.mergeExternal(rows)

        // LOCAL → TRAKT: Continue Watching rows Trakt doesn't have (scrobble
        // was off, failed, or predates sign-in). A scrobble "pause" at the
        // local position creates the playback row on Trakt's side. Only tt…
        // ids scrobble cleanly; cap the burst so a big backlog can't hammer
        // the API in one sync. remoteKeys carries BOTH the imdb- and tmdb-keyed
        // forms of every Trakt row, so a local row keyed under one identity
        // can't be mistaken for missing because Trakt reported the other.
        // Rows that ORIGINATED from Trakt are excluded: pushing those back
        // would resurrect items the user deleted on trakt.tv itself. That test
        // is the row's SOURCE, not "was it ever merged from outside" — the
        // externally-merged flag is also set for Stremio imports, so using it
        // here meant nothing watched in Stremio ever reached Trakt, while
        // everything flowed the other way. A Trakt-origin row that is watched
        // again locally becomes a "orivio" row and pushes normally.
        var remoteKeys = Set<String>()
        for s in remote {
            var idForms: [String] = []
            if let imdb = s.imdb { idForms.append(imdb) }
            if let tmdb = s.tmdb { idForms.append("tmdb:\(tmdb)") }
            for id in idForms {
                if s.type == "series", let sea = s.season, let ep = s.episode {
                    remoteKeys.insert("\(id):\(sea):\(ep)")
                } else {
                    remoteKeys.insert(id)
                }
            }
        }
        let localOnly = progress.serviceBackedForSync()
            .filter { $0.metaID.hasPrefix("tt") && !remoteKeys.contains($0.id) }
            .filter { $0.syncSource != "trakt" }
            .filter { $0.durationSeconds > 0 }
            .filter { let f = $0.positionSeconds / $0.durationSeconds; return f > 0.01 && f < 0.95 }
            // Rows Trakt has already refused repeatedly are parked, not retried
            // (see rejectedScrobbles).
            .filter { [self] row in expireRejectedScrobblesIfStale(); return !isScrobbleRejected(row.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(30)
        for row in localOnly {
            let ok = await TraktService.scrobble(
                action: .pause, imdbID: row.metaID, type: row.type,
                season: row.season, episode: row.episode,
                progress: row.positionSeconds / row.durationSeconds * 100,
                accessToken: token
            )
            noteScrobbleResult(ok, for: row.id)
        }
        return rows.count
    }

    // MARK: - Rejected scrobbles

    /// Continue Watching keys Trakt keeps refusing, with their failure count.
    ///
    /// Trakt answers a scrobble for an item it can't match (an id it doesn't
    /// carry, a mis-numbered episode) with the same non-2xx forever — and
    /// nothing recorded that, so every full sync re-sent up to 30 of the exact
    /// same doomed POSTs, for the life of the install. After
    /// `maxScrobbleAttempts` failures the key is parked; a success clears it, so
    /// a row that starts matching (Trakt added the episode) resumes normally.
    /// Persisted, because "forever" spans launches.
    private var rejectedScrobbles: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: rejectedScrobblesKey) as? [String: Int]) ?? [:]
    private static let rejectedScrobblesKey = "orivio.trakt.rejectedScrobbles.v1"
    private static let maxScrobbleAttempts = 3
    /// Ceiling so the parked set can't grow without bound; blown away wholesale
    /// (it simply re-learns) rather than tracked with per-key timestamps.
    private static let maxRejectedScrobbles = 500
    /// Parking EXPIRES. `TraktService.scrobble` returns false for a network
    /// failure as well as a refusal, so a few minutes offline could park every
    /// row — and a parked row is filtered out before the loop that would clear
    /// it, making the "a success clears it" promise unreachable. Expiring the
    /// whole set periodically means the worst case is a delay, not permanent
    /// silent loss of Trakt push.
    private static let rejectedScrobblesLife: TimeInterval = 7 * 24 * 60 * 60
    private static let rejectedScrobblesStampKey = "orivio.trakt.rejectedScrobbles.stamp.v1"

    /// Drop the parked set once it is older than its life, so parked rows get
    /// another chance without the user doing anything.
    private func expireRejectedScrobblesIfStale() {
        let defaults = UserDefaults.standard
        let stamp = defaults.object(forKey: Self.rejectedScrobblesStampKey) as? Double
        guard let stamp else {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.rejectedScrobblesStampKey)
            return
        }
        guard Date().timeIntervalSince1970 - stamp > Self.rejectedScrobblesLife else { return }
        guard !rejectedScrobbles.isEmpty else {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.rejectedScrobblesStampKey)
            return
        }
        NSLog("[OrivioTrakt] retrying %d parked scrobble(s) — parking expired", rejectedScrobbles.count)
        rejectedScrobbles = [:]
        defaults.removeObject(forKey: Self.rejectedScrobblesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.rejectedScrobblesStampKey)
    }

    private func isScrobbleRejected(_ key: String) -> Bool {
        (rejectedScrobbles[key] ?? 0) >= Self.maxScrobbleAttempts
    }

    private func noteScrobbleResult(_ ok: Bool, for key: String) {
        if ok {
            guard rejectedScrobbles.removeValue(forKey: key) != nil else { return }
        } else {
            if rejectedScrobbles.count >= Self.maxRejectedScrobbles { rejectedScrobbles = [:] }
            rejectedScrobbles[key, default: 0] += 1
            if rejectedScrobbles[key] == Self.maxScrobbleAttempts {
                NSLog("[OrivioTrakt] parking %@ — Trakt rejected it %d times", key, Self.maxScrobbleAttempts)
            }
        }
        UserDefaults.standard.set(rejectedScrobbles, forKey: Self.rejectedScrobblesKey)
    }

    /// The user removed a title from Continue Watching — delete its playback
    /// rows (movie, or every episode of the show) on Trakt too.
    /// Delete EVERY row from Trakt's playback list — their "continue
    /// watching". Deliberately NOT the watched history: this clears only the
    /// partially-watched rows, which is what re-imports into Continue Watching
    /// here. Also advances the local clear horizon so the rows can't be pulled
    /// Returns the number
    /// removed, or nil if the list couldn't be fetched (an outage must not be
    /// reported as "nothing to clear"). The watch-history clear horizon is left
    /// alone — see the note at the end of this method.
    @discardableResult
    func clearTraktContinueWatching() async -> Int? {
        guard let token = await validToken() else { return nil }
        guard let rows = await TraktService.playbackProgress(accessToken: token) else { return nil }
        var removed = 0
        for row in rows {
            guard let playbackID = row.playbackID else { continue }
            if await TraktService.removePlayback(playbackID: playbackID, accessToken: token) { removed += 1 }
        }
        // Deliberately does NOT advance the watch-history clear horizon.
        // Emptying Trakt's in-progress list is what stops those rows coming
        // back; moving the horizon would ALSO hide every older row from every
        // other source (Stremio imports carry their original watch time), which
        // is a far bigger hammer than the user asked for.
        NSLog("[OrivioTrakt] cleared %d of %d playback rows", removed, rows.count)
        trakt.setSyncStatus("Cleared \(removed) Trakt continue-watching rows")
        return removed
    }

    private func pushPlaybackRemove(_ metaID: String) {
        guard trakt.isSignedIn, trakt.syncPlayback else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            guard let rows = await TraktService.playbackProgress(accessToken: token) else { return }
            for s in rows where self.localID(from: s) == metaID {
                guard let pid = s.playbackID else { continue }
                _ = await TraktService.removePlayback(playbackID: pid, accessToken: token)
            }
        }
    }

    /// Two-way watchlist ↔ Library. Pull Trakt → add missing to Library
    /// (enriched); push local-only Library items to the watchlist.
    private func syncWatchlist(token: String, profile: Int) async -> Int {
        let remote = await TraktService.watchlist(accessToken: token)
        guard profileStillActive(profile) else { return 0 }
        let missing: [(item: TraktService.SyncItem, id: String)] = remote.compactMap { s in
            guard let id = localID(from: s), !library.contains(id: id, type: s.type) else { return nil }
            return (s, id)
        }
        let metas = await Self.fetchMetas(missing.enumerated().map { index, entry in
            (index < 25 ? addonManager.metaAddon(for: entry.item.type, id: entry.id) : nil,
             entry.item.type, entry.id)
        })
        var added: [SavedLibraryItem] = []
        for (index, entry) in missing.enumerated() {
            let s = entry.item
            var name = s.title
            var poster: String?
            var background: String?
            if let meta = metas[index] {
                if !meta.name.isEmpty { name = meta.name }
                poster = meta.poster
                background = meta.background
            }
            added.append(SavedLibraryItem(id: entry.id, type: s.type, name: name,
                                          poster: poster, background: background))
        }
        guard profileStillActive(profile) else { return 0 }
        if !added.isEmpty, library.mergeRemote(added, reconcile: false) {
            library.requestSyncPush()   // on to the Orivio account too
        }

        // Push local-only.
        let remoteKeys = Set(remote.flatMap { s in
            localIDs(from: s).map { "\(s.type)|\($0)" }
        })
        let localOnly = library.allForSync()
            .filter { !remoteKeys.contains($0.key) }
            .compactMap { syncItem(fromLibrary: $0) }
        if !localOnly.isEmpty { _ = await TraktService.addToWatchlist(localOnly, accessToken: token) }
        return remote.count
    }

    /// Two-way ratings ↔ Trakt (additive pull + push local-only).
    private func syncRatings(token: String, profile: Int) async -> Int {
        let remote = await TraktService.ratings(accessToken: token)
        guard profileStillActive(profile) else { return 0 }
        let mapped: [(metaID: String, type: String, rating: Int)] = remote.compactMap { s in
            guard let id = localID(from: s), let r = s.rating else { return nil }
            return (id, s.type, r)
        }
        if !mapped.isEmpty { ratings.mergeRemote(mapped) }

        // Both id forms of every title Trakt already holds a rating for. Not
        // every title it knows — an unrated one should still receive ours.
        let remoteIDs = Set(remote.filter { $0.rating != nil }.flatMap(localIDs(from:)))
        let pushable = ratings.allForSync()
            .filter { !remoteIDs.contains($0.metaID) }
            .compactMap { r -> TraktService.SyncItem? in syncItem(metaID: r.metaID, type: r.type, rating: r.rating) }
        if !pushable.isEmpty { _ = await TraktService.addRatings(pushable, accessToken: token) }
        return remote.count
    }

    // MARK: - Immediate push (watchlist / ratings)

    private func pushWatchlistAdd(_ item: SavedLibraryItem) {
        guard trakt.isSignedIn, trakt.syncWatchlist,
              let s = syncItem(fromLibrary: item) else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.addToWatchlist([s], accessToken: token)
        }
    }
    private func pushWatchlistRemove(_ item: SavedLibraryItem) {
        guard trakt.isSignedIn, trakt.syncWatchlist,
              let s = syncItem(fromLibrary: item) else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.removeFromWatchlist([s], accessToken: token)
        }
    }
    private func pushRating(_ metaID: String, _ type: String, _ rating: Int) {
        guard trakt.isSignedIn, trakt.syncRatings,
              let s = syncItem(metaID: metaID, type: type, rating: rating) else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.addRatings([s], accessToken: token)
        }
    }
    private func pushUnrate(_ metaID: String, _ type: String) {
        guard trakt.isSignedIn, trakt.syncRatings,
              let s = syncItem(metaID: metaID, type: type, rating: nil) else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.removeRatings([s], accessToken: token)
        }
    }

    // MARK: - Immediate mark/un-mark push

    private func pushMark(_ item: WatchedItem) {
        guard trakt.isSignedIn, trakt.syncWatchHistory,
              let s = syncItem(from: item) else { return }
        // The player finishing a title is reported by the stop scrobble
        // (Trakt logs a stop past 80% as a play). A history add on top of it
        // recorded a second play for every title watched to the end. Skip it
        // here; if the scrobble is lost, the next full sync's "local rows
        // Trakt is missing" pass still uploads the mark.
        if trakt.scrobbleEnabled, item.contentID.hasPrefix("tt"),
           watched.wasFinishedByPlayback(item.key) { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.addToHistory([s], accessToken: token)
        }
    }

    private func pushRemove(_ items: [WatchedItem]) {
        guard trakt.isSignedIn, trakt.syncWatchHistory else { return }
        let syncItems = items.compactMap(syncItem(from:))
        guard !syncItems.isEmpty else { return }
        let profile = trakt.profileID   // the profile whose store fired this
        Task { [weak self] in
            guard let self, let token = await self.validToken(),
                  self.profileStillActive(profile) else { return }
            _ = await TraktService.removeFromHistory(syncItems, accessToken: token)
        }
    }

    // MARK: - Token health

    /// A usable access token. If a health check fails we TRY to refresh, but if
    /// refresh isn't possible we still return the existing token and let the
    /// real calls run — a flaky settings check must not disable the whole sync.
    /// The token most recently proven good, and when. Every push path calls
    /// `validToken`, so without this a single sync fired a `/users/settings`
    /// check per operation.
    private var verifiedToken: String?
    private var verifiedAt = Date.distantPast
    private static let tokenHealthTTL: TimeInterval = 600

    /// The in-flight refresh, if any. Trakt refresh tokens are SINGLE USE: the
    /// independent Tasks here (mark, rate, watchlist, playback remove, full
    /// sync) each called `validToken`, so a shared outage had them all refresh
    /// at once — the losers received nothing and kept a token the server had
    /// already rotated away, which reads to the user as "Trakt session expired,
    /// sign in again" for good.
    private var refreshTask: Task<String?, Never>?

    private func validToken() async -> String? {
        guard let token = trakt.accessToken else { return nil }
        // Recently proven good: skip the round trip entirely.
        if token == verifiedToken, Date().timeIntervalSince(verifiedAt) < Self.tokenHealthTTL {
            return token
        }
        if await TraktService.fetchUsername(accessToken: token) != nil {
            verifiedToken = token
            verifiedAt = Date()
            return token
        }
        NSLog("[OrivioTrakt] token health check failed — attempting refresh")
        // Join an in-flight refresh instead of starting a competing one.
        if let existing = refreshTask {
            return await existing.value ?? trakt.accessToken
        }
        let task = Task { [trakt] () -> String? in
            guard let refresh = trakt.refreshToken,
                  let fresh = await TraktService.refreshToken(refresh) else { return nil }
            trakt.store(access: fresh.access, refresh: fresh.refresh)
            return fresh.access
        }
        refreshTask = task
        let refreshed = await task.value
        refreshTask = nil
        if let refreshed {
            NSLog("[OrivioTrakt] token refreshed")
            verifiedToken = refreshed
            verifiedAt = Date()
            return refreshed
        }
        // The check can fail for reasons that are nothing to do with auth — a
        // timeout, DNS, a Trakt 5xx. Keep using the token we have rather than
        // disabling the whole sync over a flaky network.
        NSLog("[OrivioTrakt] refresh unavailable — proceeding with existing token")
        return trakt.accessToken
    }

    // MARK: - ID mapping

    // The four mappers below are pure value transforms (args + static `ids`
    // only) — nonisolated so the history transform can run off the main
    // actor (see syncWatchHistory).
    private nonisolated func syncItem(from w: WatchedItem) -> TraktService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: w.contentID)
        guard imdb != nil || tmdb != nil else { return nil }
        return TraktService.SyncItem(
            imdb: imdb, tmdb: tmdb, type: w.contentType, title: w.title,
            season: w.season, episode: w.episode, progress: nil, watchedAt: w.watchedAt)
    }

    private nonisolated func watchedItem(from s: TraktService.SyncItem) -> WatchedItem? {
        guard let cid = localID(from: s) else { return nil }
        return WatchedItem(
            contentID: cid, contentType: s.type, title: s.title,
            season: s.season, episode: s.episode, watchedAt: s.watchedAt ?? SyncTimestamp.unknown)
    }

    /// EVERY local id form this remote row could correspond to.
    ///
    /// `pullPlayback` already builds both forms for its own key set, with a
    /// comment explaining why; the history, watchlist and ratings phases each
    /// keyed off `localID` alone, so a title held locally under `tmdb:` never
    /// matched the same title returned by Trakt under `tt…` and was re-pushed
    /// on every sync.
    private nonisolated func localIDs(from s: TraktService.SyncItem) -> [String] {
        var out: [String] = []
        if let imdb = s.imdb, imdb.hasPrefix("tt") { out.append(imdb) }
        if let tmdb = s.tmdb { out.append("tmdb:\(tmdb)") }
        return out
    }

    private nonisolated func localID(from s: TraktService.SyncItem) -> String? {
        if let imdb = s.imdb, imdb.hasPrefix("tt") { return imdb }
        if let tmdb = s.tmdb { return "tmdb:\(tmdb)" }
        return nil
    }

    private func syncItem(fromLibrary item: SavedLibraryItem) -> TraktService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: item.id)
        guard imdb != nil || tmdb != nil else { return nil }
        return TraktService.SyncItem(imdb: imdb, tmdb: tmdb, type: item.type, title: item.name)
    }

    private func syncItem(metaID: String, type: String, rating: Int?) -> TraktService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: metaID)
        guard imdb != nil || tmdb != nil else { return nil }
        return TraktService.SyncItem(imdb: imdb, tmdb: tmdb, type: type, title: "", rating: rating)
    }

    private nonisolated static func ids(from contentID: String) -> (imdb: String?, tmdb: Int?) {
        if contentID.hasPrefix("tt") { return (contentID, nil) }
        if contentID.hasPrefix("tmdb:"), let n = Int(contentID.dropFirst("tmdb:".count)) { return (nil, n) }
        return (nil, nil)
    }

    /// Meta lookups for a batch of titles, a few at a time, results in input
    /// order (nil where there was no add-on to ask or the lookup failed).
    /// Shared with the SIMKL manager. Bounded so a large list cannot fan out
    /// into dozens of simultaneous add-on requests on an Apple TV HD.
    static func fetchMetas(_ requests: [(addon: InstalledAddon?, type: String, id: String)]) async -> [MetaItem?] {
        let limit = PerformanceProfile.isLowPower ? 2 : 4
        return await boundedConcurrentMap(requests, limit: limit) { request in
            guard let addon = request.addon else { return nil }
            return try? await StremioAPI.meta(addon: addon, type: request.type, id: request.id)
        }
    }

    /// "120 min" / "1h 30min" / "45min" → minutes.
    static func parseRuntimeMinutes(_ raw: String?) -> Int? {
        guard let raw = raw?.lowercased() else { return nil }
        var minutes = 0
        if let h = raw.range(of: #"(\d+)\s*h"#, options: .regularExpression),
           let n = Int(raw[h].filter(\.isNumber)) { minutes += n * 60 }
        if let m = raw.range(of: #"(\d+)\s*m"#, options: .regularExpression),
           let n = Int(raw[m].filter(\.isNumber)) { minutes += n }
        if minutes == 0, let only = Int(raw.filter(\.isNumber)), only > 0, only < 1000 { minutes = only }
        return minutes > 0 ? minutes : nil
    }
}
