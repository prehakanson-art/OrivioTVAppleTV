import Combine
import Foundation
import UIKit

/// Two-way sync between the app and SIMKL: watch history (WatchedStore ↔ SIMKL
/// history), the Library (↔ SIMKL's plan-to-watch list) and star ratings.
///
/// Runs alongside `TraktSyncManager` rather than replacing it — both are
/// opt-in destinations and a viewer can use either, both, or neither. The two
/// managers subscribe to the same store hooks (which is why those hooks are
/// lists), and both merge ADDITIVELY, so neither can delete what the other put
/// there.
///
/// Deliberately narrower than the Trakt manager in two places:
///
/// * **Continue Watching is one-way, and approximate.** SIMKL has no
///   playback-position API — nothing equivalent to Trakt's `/sync/playback` —
///   so there is no partial position to pull in or push out. What its
///   "watching" bucket does give is the episode you are up to, and that seeds
///   Continue Watching at the START of the next episode (see
///   `syncContinueWatching`). Positions flow out through the history phase
///   instead: finishing an episode marks it watched, which is how SIMKL
///   advances a show.
/// * **No token refresh.** SIMKL access tokens do not expire, so there is no
///   refresh token to rotate and none of the single-use-refresh contention the
///   Trakt manager has to guard against.
@MainActor
final class SimklSyncManager: ObservableObject {
    private let simkl: SimklStore
    private let watched: WatchedStore
    private let library: LibraryStore
    private let ratings: RatingsStore
    private let addonManager: AddonManager
    /// Continue Watching. SIMKL cannot supply a playback POSITION, but its
    /// "watching" bucket says which episode you are up to — see
    /// `SimklStore.syncContinueWatching` and `syncContinueWatching(remote:)`.
    private let progress: ProgressStore

    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    /// Throttle full syncs so foreground + sign-in + a setting flip don't stack.
    private var lastFullSync = Date.distantPast

    /// `/sync/activities` "all" stamp from the start of the last CLEAN run
    /// (every library fetch succeeded, every push landed), pinned to the token
    /// and profile it was earned under. Per-profile accounts swap tokens, and
    /// even one shared token serves per-profile local stores — a stamp proven
    /// against profile A's stores says nothing about profile B's.
    private var lastCleanRunActivity: (token: String, profile: Int, stamp: String)?
    /// A push failed since the last clean run — an immediate hook push or a
    /// phase push. The next run must reconcile for real instead of trusting
    /// the activities gate (a FAILED push doesn't bump SIMKL's stamp, so the
    /// gate alone would never retry it).
    private var pushRetryNeeded = false

    init(simkl: SimklStore, watched: WatchedStore, library: LibraryStore,
         ratings: RatingsStore, addonManager: AddonManager, progress: ProgressStore) {
        self.simkl = simkl
        self.watched = watched
        self.library = library
        self.ratings = ratings
        self.addonManager = addonManager
        self.progress = progress

        // LOCAL → SIMKL: immediate push on each kind of local change.
        watched.onTrackerMark.append { [weak self] item in self?.pushMark(item) }
        watched.onTrackerRemove.append { [weak self] items in self?.pushRemove(items) }
        library.onTrackerAdd.append { [weak self] item in self?.pushWatchlistAdd(item) }
        // No onTrackerRemove subscription for the Library, on purpose: SIMKL
        // cannot remove a title from plan-to-watch without removing it from
        // the library entirely, which would take its watch history with it.
        // See the note above `addToWatchlist` in SimklService.
        ratings.onTrackerRate.append { [weak self] id, type, r in self?.pushRating(id, type, r) }
        ratings.onTrackerUnrate.append { [weak self] id, type in self?.pushUnrate(id, type) }
        simkl.onSyncSettingChange = { [weak self] in self?.syncNow(force: true) }

        simkl.$accessToken
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard signedIn else { return }
                // Someone who just finished the PIN login is sitting there
                // waiting for their library: sync immediately.
                if self?.simkl.didSignInInteractively == true {
                    // One main-actor turn later: `@Published` notifies from
                    // `willSet`, so syncNow's own signed-in guard would still
                    // see the PREVIOUS (signed-out) value and skip the very
                    // sync this sign-in is waiting for.
                    Task { @MainActor [weak self] in self?.syncNow(force: true) }
                    return
                }
                // A token restored at launch is deferred. `@Published` delivers
                // its CURRENT value on subscribe, so without this the whole
                // sync ran during app construction, against the Home catalog
                // sweep. None of it has to happen before the first screen is
                // usable. Staggered past Trakt's five seconds so two signed-in
                // services don't fire their pulls in the same instant.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.syncNow(force: true)
                }
            }
            .store(in: &cancellables)

        // Signed in is enough — no Orivio account required. See `startAutoSync`.
        simkl.$accessToken
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] signedIn in
                if signedIn { self?.startAutoSync() } else { self?.stopAutoSync() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard self?.simkl.isSignedIn == true else { return }
                self?.syncNow()   // throttled
            }
            .store(in: &cancellables)
    }

    // MARK: - Auto sync

    /// How often a signed-in SIMKL account reconciles on its own. Like Trakt,
    /// SIMKL had no periodic sync at all — only sign-in, local changes and
    /// setting flips — so a title watched elsewhere never turned up here until
    /// the next launch. Cheap in practice: `runSync` asks `/sync/activities`
    /// first and returns immediately when nothing has moved.
    private static let autoSyncInterval: TimeInterval = 5 * 60
    private var autoSyncTask: Task<Void, Never>?

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoSyncInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard simkl.isSignedIn else { continue }
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

    /// Run a full two-way sync (throttled). `force` bypasses the throttle
    /// (sign-in, manual "Sync now", a setting flip).
    func syncNow(force: Bool = false) {
        guard simkl.isSignedIn else { return }
        if !force, Date().timeIntervalSince(lastFullSync) < 60 { return }
        lastFullSync = Date()
        // Coalesce rather than cancel: a rapid second trigger (sign-in +
        // foreground) must not abort the first sync mid-way — but remember it
        // (a profile switch during a run must sync the new profile after).
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

    private var rerunRequested = false

    /// The stores this manager merges into are per profile (and with
    /// per-profile accounts on, so is the SIMKL login itself): a switch
    /// mid-run re-scopes them, and an unpinned run merged profile A's history
    /// into profile B's store (the Trakt manager pins the same way). Checked
    /// after every await, before any store write.
    private func profileStillActive(_ profile: Int) -> Bool { watched.profileID == profile }

    private func runSync() async {
        guard let token = simkl.accessToken else { return }
        let profile = watched.profileID

        // SIMKL's own guidance: ask /sync/activities what changed before
        // pulling all-items — the pull below is the viewer's ENTIRE library,
        // three requests over. Skippable only when it provably cannot matter:
        // the last run read everything and pushed cleanly, for THIS token and
        // THIS profile, and the stamp hasn't moved since that run began. Any
        // SUCCESSFUL push (immediate or in-phase) bumps the server stamp, so
        // "unchanged" also proves our own writes are already reflected; a
        // failed push sets `pushRetryNeeded` instead. An unreadable stamp
        // counts as moved.
        let stamp = await SimklService.lastActivity(accessToken: token)
        guard profileStillActive(profile) else { return }
        if !pushRetryNeeded, let stamp, let last = lastCleanRunActivity,
           last.token == token, last.profile == profile, last.stamp == stamp {
            NSLog("[OrivioSimkl] runSync skipped — no SIMKL activity since the last clean sync")
            simkl.setSyncStatus("SIMKL: up to date")
            return
        }
        // This run reconciles in full; failures below re-arm the flag.
        pushRetryNeeded = false

        NSLog("[OrivioSimkl] runSync start (history=%d watchlist=%d ratings=%d)",
              simkl.syncWatchHistory ? 1 : 0, simkl.syncWatchlist ? 1 : 0,
              simkl.syncRatings ? 1 : 0)

        // ONE fetch of the whole library — every status bucket — feeds all
        // three phases. Fetching per-status buckets ("completed" here,
        // "plantowatch" in the watchlist phase) caused two real bugs: watched
        // episodes of a show still in progress sit under the "watching" bucket
        // and never pulled into local ✓ badges, and the watchlist push
        // couldn't see completed/watching titles at all — so it "added" them
        // to plan-to-watch, which on SIMKL MOVES the title between lists and
        // wiped the very status the history phase had just earned it.
        async let moviesFetch = SimklService.allItems(type: "movies", status: nil, accessToken: token)
        async let showsFetch = SimklService.allItems(type: "shows", status: nil, accessToken: token)
        async let animeFetch = SimklService.allItems(type: "anime", status: nil, accessToken: token)
        let movies = await moviesFetch
        let shows = await showsFetch
        let anime = await animeFetch
        let remote = merge(movies, shows, anime)
        // The watchlist push MOVES titles between SIMKL lists, so unlike the
        // additive pushes it may only run for a media type whose library was
        // actually read — a failed fetch would make everything of that type
        // look absent and get dragged to plan-to-watch.
        let pushableTypes = SafePushTypes(movies: movies != nil,
                                          series: shows != nil && anime != nil)

        // A failed fetch is nil, NOT an empty library. Treating an outage as
        // "SIMKL has nothing" would make every push phase re-upload the
        // viewer's entire history on the next flaky network.
        guard let remote else {
            // Ask WHY before reporting. A revoked or expired login fails these
            // fetches exactly like an outage does, and "couldn't reach SIMKL"
            // would send someone to check their network over and over when the
            // fix is to sign in again.
            let reason = await SimklService.checkToken(token) == .unauthorized
                ? "SIMKL rejected this login — sign in again"
                : "Couldn't reach SIMKL — nothing was changed"
            NSLog("[OrivioSimkl] runSync aborted — %@", reason)
            simkl.setSyncStatus(reason)
            return
        }

        guard profileStillActive(profile) else {
            NSLog("[OrivioSimkl] runSync abandoned — profile switched during the fetch")
            return
        }
        var parts: [String] = []
        if simkl.syncWatchHistory {
            parts.append("\(await syncWatchHistory(remote: remote, token: token, profile: profile)) history")
        }
        if simkl.syncWatchlist {
            guard profileStillActive(profile) else { return }
            parts.append("\(await syncWatchlist(remote: remote, safeToPush: pushableTypes, token: token, profile: profile)) watchlist")
        }
        if simkl.syncRatings {
            guard profileStillActive(profile) else { return }
            parts.append("\(await syncRatings(remote: remote, token: token)) ratings")
        }
        if simkl.syncContinueWatching {
            guard profileStillActive(profile) else { return }
            parts.append("\(await syncContinueWatching(remote: remote, profile: profile)) continue watching")
        }
        NSLog("[OrivioSimkl] runSync done: %@", parts.joined(separator: ", "))
        simkl.setSyncStatus(parts.isEmpty
                            ? "SIMKL: nothing to sync"
                            : "SIMKL synced (\(parts.joined(separator: ", ")))")

        // Only a clean run earns the gate: all three libraries read, no push
        // failed (a concurrent hook push can flip the flag mid-run — that
        // conservatism is fine). The stamp is the one from BEFORE the run: our
        // own pushes bump the server stamp after it, so the next trigger runs
        // full once more and then settles — an extra sync, never a missed one.
        if let stamp, movies != nil, shows != nil, anime != nil, !pushRetryNeeded {
            lastCleanRunActivity = (token, profile, stamp)
        }
    }

    /// Combine the three bucket fetches. nil only if EVERY one failed; a
    /// partial result is still usable and better than aborting the whole sync.
    private func merge(_ buckets: [SimklService.SyncItem]?...) -> [SimklService.SyncItem]? {
        var out: [SimklService.SyncItem] = []
        var anySucceeded = false
        for list in buckets {
            guard let list else { continue }
            anySucceeded = true
            out.append(contentsOf: list)
        }
        return anySucceeded ? out : nil
    }

    // MARK: - Phases

    /// Which media types the MOVE-between-lists watchlist push may touch:
    /// only those whose SIMKL library was read in full this run. Series need
    /// both the shows AND anime fetches — SIMKL files anime separately, and a
    /// series absent from a successful shows fetch could still be sitting in
    /// an anime bucket that failed.
    private struct SafePushTypes {
        let movies: Bool
        let series: Bool
        func allows(_ type: String) -> Bool { type == "movie" ? movies : series }
    }

    /// Two-way watch history. Pull SIMKL → add anything missing locally; push
    /// local items SIMKL doesn't have. Returns the count pulled.
    private func syncWatchHistory(remote: [SimklService.SyncItem], token: String, profile: Int) async -> Int {
        guard profileStillActive(profile) else { return 0 }
        let clearedAt = WatchHistoryClearState.clearedAt
        // History is EPISODE rows (whatever bucket their show sits in — a
        // show mid-binge lives under "watching", and its watched episodes are
        // just as watched) plus movies from the completed bucket. A movie row
        // from any other bucket is a plan or a rating, not a viewing, and the
        // show-level row that `allItems` also emits carries the rating.
        let remoteItems = remote
            .filter { ($0.type == "movie" && $0.status == "completed")
                   || ($0.season != nil && $0.episode != nil) }
            .compactMap(watchedItem(from:))
            .filter { item in
                guard let clearedAt else { return true }
                return item.watchedAt > clearedAt
            }
        // Additive — never delete local history from a partial SIMKL response.
        // Anything new goes on to the Orivio account as well.
        if !remoteItems.isEmpty, watched.mergeRemote(remoteItems, reconcile: false) {
            watched.requestSyncPush()
        }

        // Built from EVERY remote row, not just the ones that survived the
        // history filter above. A row SIMKL holds but this filter drops (an
        // anime entry, a bucket we don't import) is still a row SIMKL has —
        // treating it as missing is what re-uploaded it on every sync.
        let remoteKeys = Set(remote.flatMap { s in
            localIDs(from: s).map { WatchedItem.key(contentID: $0, season: s.season, episode: s.episode) }
        })
        let pushable = watched.allForSync()
            .filter { !remoteKeys.contains($0.key) }
            .compactMap(syncItem(from:))
        if !pushable.isEmpty, !(await SimklService.addToHistory(pushable, accessToken: token)) {
            pushRetryNeeded = true
        }
        return remoteItems.count
    }

    /// Two-way watchlist ↔ Library. Returns the count pulled.
    ///
    /// The push side is the ONE non-additive write in this manager: SIMKL's
    /// add-to-list MOVES a title to plan-to-watch, so pushing a title SIMKL
    /// already has under completed/watching/hold would strip that status (and
    /// then re-strip it every sync, fighting the history phase). So the pull
    /// reads only the plantowatch rows, but the push excludes a title present
    /// under ANY status — only titles SIMKL has never heard of go up.
    private func syncWatchlist(remote: [SimklService.SyncItem], safeToPush: SafePushTypes,
                               token: String, profile: Int) async -> Int {
        // Show-level rows only: an episode entry is not a watchlist item.
        let known = remote.filter { $0.season == nil && $0.episode == nil }
        let titles = known.filter { $0.status == "plantowatch" }

        let missing: [(item: SimklService.SyncItem, id: String)] = titles.compactMap { s in
            guard let id = localID(from: s), !library.contains(id: id, type: s.type) else { return nil }
            return (s, id)
        }
        // Same budget as the Trakt manager: artwork for the first 25 so a
        // large watchlist can't turn one sync into hundreds of meta calls —
        // fetched a few at a time, not one after another.
        let metas = await TraktSyncManager.fetchMetas(missing.enumerated().map { index, entry in
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
        guard profileStillActive(profile) else { return 0 }   // the meta enrichment awaits
        if !added.isEmpty, library.mergeRemote(added, reconcile: false) {
            library.requestSyncPush()   // on to the Orivio account too
        }

        // Everything SIMKL has, under any status — not just plan-to-watch.
        let remoteKeys = Set(known.flatMap { s in
            localIDs(from: s).map { "\(s.type)|\($0)" }
        })
        let localOnly = library.allForSync()
            .filter { !remoteKeys.contains($0.key) && safeToPush.allows($0.type) }
            .compactMap { syncItem(fromLibrary: $0) }
        if !localOnly.isEmpty, !(await SimklService.addToWatchlist(localOnly, accessToken: token)) {
            pushRetryNeeded = true
        }
        return titles.count
    }

    /// Two-way ratings (additive pull + push local-only). SIMKL returns the
    /// rating on the library row, so this reuses the already-fetched payload —
    /// which now spans every status bucket, so a rating on a show still being
    /// watched (or on hold) pulls in too, and blocks the push from stamping a
    /// local rating over it.
    private func syncRatings(remote: [SimklService.SyncItem], token: String) async -> Int {
        let mapped: [(metaID: String, type: String, rating: Int)] = remote.compactMap { s in
            // Show-level rows only — SIMKL rates titles, not episodes.
            guard s.season == nil, let id = localID(from: s), let r = s.rating else { return nil }
            return (id, s.type, r)
        }
        if !mapped.isEmpty { ratings.mergeRemote(mapped) }

        // Every id form of every title SIMKL already has a RATING for.
        // Deliberately not every title it knows: a title in the library with
        // no rating SHOULD receive ours. The only change here from `mapped` is
        // that both id forms are covered, so a locally `tmdb:`-keyed rating
        // isn't re-pushed forever because SIMKL answered with the IMDb id.
        let remoteIDs = Set(remote.filter { $0.season == nil && $0.rating != nil }
                                  .flatMap(localIDs(from:)))
        let pushable = ratings.allForSync()
            .filter { !remoteIDs.contains($0.metaID) }
            .compactMap { syncItem(metaID: $0.metaID, type: $0.type, rating: $0.rating) }
        if !pushable.isEmpty, !(await SimklService.addRatings(pushable, accessToken: token)) {
            pushRetryNeeded = true
        }
        return mapped.count
    }

    // MARK: - Immediate push

    /// Every immediate push runs the same shape: bail unless signed in and the
    /// relevant switch is on, map to a SIMKL item, send it. A failed send arms
    /// `pushRetryNeeded` so the next full sync reconciles instead of trusting
    /// the activities gate — these are fire-and-forget, and the full sync's
    /// push phase is their only retry.
    private func push(_ enabled: Bool, _ items: [SimklService.SyncItem],
                      _ send: @escaping ([SimklService.SyncItem], String) async -> Bool) {
        guard simkl.isSignedIn, enabled, !items.isEmpty,
              let token = simkl.accessToken else { return }
        Task { [weak self] in
            if !(await send(items, token)) { self?.pushRetryNeeded = true }
        }
    }

    private func pushMark(_ item: WatchedItem) {
        push(simkl.syncWatchHistory, [syncItem(from: item)].compactMap { $0 },
             SimklService.addToHistory)
    }
    private func pushRemove(_ items: [WatchedItem]) {
        push(simkl.syncWatchHistory, items.compactMap(syncItem(from:)),
             SimklService.removeFromHistory)
    }
    private func pushWatchlistAdd(_ item: SavedLibraryItem) {
        push(simkl.syncWatchlist, [syncItem(fromLibrary: item)].compactMap { $0 },
             SimklService.addToWatchlist)
    }
    private func pushRating(_ metaID: String, _ type: String, _ rating: Int) {
        push(simkl.syncRatings, [syncItem(metaID: metaID, type: type, rating: rating)].compactMap { $0 },
             SimklService.addRatings)
    }
    private func pushUnrate(_ metaID: String, _ type: String) {
        push(simkl.syncRatings, [syncItem(metaID: metaID, type: type, rating: nil)].compactMap { $0 },
             SimklService.removeRatings)
    }

    // MARK: - ID mapping

    // MARK: Continue Watching

    /// Seed Continue Watching from SIMKL's "watching" bucket.
    ///
    /// One-way, and it has to be: SIMKL stores no playback position, so there
    /// is nothing to push back that it doesn't already learn from the history
    /// phase (finishing an episode marks it watched, which moves the show
    /// along on SIMKL's side by itself).
    ///
    /// What it CAN say is which episode you are up to. For every show sitting
    /// in "watching", the highest watched episode of the highest watched
    /// season names the next one, and that episode goes in at position 0 —
    /// "start this one", not "resume 14 minutes in", which is the honest
    /// reading of the data.
    ///
    /// `mergeExternal` only advances a row when the incoming one is further
    /// along and meaningfully newer, so a local row with a real position is
    /// never overwritten by a position-less SIMKL row for the same episode.
    private func syncContinueWatching(remote: [SimklService.SyncItem], profile: Int) async -> Int {
        let clearedAt = WatchHistoryClearState.clearedAt
        // Show-level rows carry the bucket; episode rows carry the progress.
        var watchingShows: [String: SimklService.SyncItem] = [:]
        for item in remote where item.type == "series" && item.status == "watching" {
            guard item.season == nil, let id = localID(from: item) else { continue }
            watchingShows[id] = item
        }
        guard !watchingShows.isEmpty else { return 0 }

        /// The furthest episode SIMKL has seen for each show.
        var furthest: [String: (season: Int, episode: Int, at: Date?)] = [:]
        for item in remote where item.type == "series" {
            guard let season = item.season, let episode = item.episode,
                  let id = localID(from: item), watchingShows[id] != nil else { continue }
            let current = furthest[id]
            if current == nil || (season, episode) > (current!.season, current!.episode) {
                furthest[id] = (season, episode, item.watchedAt)
            }
        }

        // Newest first, and capped. A long-standing SIMKL account can have
        // dozens of shows parked in "watching"; all of them at once would bury
        // what this device is actually mid-way through, and each one costs an
        // add-on meta round trip for its art. The cap is the enrichment budget,
        // so every row that does appear is a complete card.
        let ordered = watchingShows
            .sorted { (furthest[$0.key]?.at ?? .distantPast) > (furthest[$1.key]?.at ?? .distantPast) }
            .prefix(25)

        // Nothing watched yet is a "plan to start", not a resume — that
        // belongs in the Library, which the watchlist phase handles.
        let candidates: [(id: String, show: SimklService.SyncItem, seen: (season: Int, episode: Int, at: Date?), updatedAt: Date)] =
            ordered.compactMap { id, show in
                guard let seen = furthest[id] else { return nil }
                let updatedAt = seen.at ?? show.watchedAt ?? SyncTimestamp.unknown
                if let clearedAt, updatedAt <= clearedAt { return nil }
                return (id, show, seen, updatedAt)
            }
        // Same budget the Trakt pull uses (the list is already capped at 25):
        // a full meta fetch per show, a few at a time rather than in series.
        let metas = await TraktSyncManager.fetchMetas(candidates.map {
            (addonManager.metaAddon(for: "series", id: $0.id), "series", $0.id)
        })
        var rows: [WatchProgress] = []
        for (index, candidate) in candidates.enumerated() {
            let id = candidate.id
            let show = candidate.show
            let seen = candidate.seen
            let updatedAt = candidate.updatedAt
            var name = show.title
            var poster: String?
            var background: String?
            var runtimeMin: Int?
            var nextEpisode: (season: Int, episode: Int)?
            if let meta = metas[index] {
                if !meta.name.isEmpty { name = meta.name }
                poster = meta.poster
                background = meta.background
                runtimeMin = Self.parseRuntimeMinutes(meta.runtime)
                // Don't invent an episode past the end of the show. Choose the
                // first known episode after the last one SIMKL reported, so a
                // season finale correctly advances to next season's episode 1.
                if let videos = meta.videos, !videos.isEmpty {
                    nextEpisode = videos
                        .compactMap { video -> (season: Int, episode: Int)? in
                            guard let season = video.season, let episode = video.episode else { return nil }
                            return (season, episode)
                        }
                        .filter { ($0.season, $0.episode) > (seen.season, seen.episode) }
                        .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
                        .first
                }
            }
            guard let nextEpisode else { continue }
            // Already watched locally? Then it isn't next up here either.
            if watched.isWatched(contentID: id, season: nextEpisode.season, episode: nextEpisode.episode) { continue }
            let duration = Double((runtimeMin ?? 45) * 60)
            rows.append(WatchProgress(
                id: "\(id):\(nextEpisode.season):\(nextEpisode.episode)", metaID: id, type: "series",
                name: name, poster: poster, background: background, logo: nil,
                season: nextEpisode.season, episode: nextEpisode.episode, episodeTitle: nil,
                positionSeconds: 0, durationSeconds: duration, streamURL: nil,
                updatedAt: updatedAt, syncSource: "simkl"))
        }
        guard profileStillActive(profile), !rows.isEmpty else { return 0 }
        progress.mergeExternal(rows)
        return rows.count
    }

    /// Runtime string → minutes. Delegates to the Trakt manager's parser so
    /// the two Continue Watching pulls estimate durations identically.
    private static func parseRuntimeMinutes(_ raw: String?) -> Int? {
        TraktSyncManager.parseRuntimeMinutes(raw)
    }

    private func syncItem(from w: WatchedItem) -> SimklService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: w.contentID)
        guard imdb != nil || tmdb != nil else { return nil }
        return SimklService.SyncItem(imdb: imdb, tmdb: tmdb, type: w.contentType,
                                     title: w.title, season: w.season, episode: w.episode,
                                     watchedAt: w.watchedAt)
    }

    private func watchedItem(from s: SimklService.SyncItem) -> WatchedItem? {
        guard let cid = localID(from: s) else { return nil }
        return WatchedItem(contentID: cid, contentType: s.type, title: s.title,
                           season: s.season, episode: s.episode,
                           watchedAt: s.watchedAt ?? SyncTimestamp.unknown)
    }

    /// EVERY local id form this remote row could correspond to.
    ///
    /// `localID` picks one (IMDb first), but the local store may hold the
    /// title under the other. A row saved as `tmdb:438631` never matched a
    /// SIMKL row returned as `tt1160419`, so it counted as "SIMKL doesn't have
    /// this" on every sync and was re-uploaded forever — and the pull added a
    /// SECOND local row under the IMDb id, so one film showed twice.
    private func localIDs(from s: SimklService.SyncItem) -> [String] {
        var out: [String] = []
        if let imdb = s.imdb, imdb.hasPrefix("tt") { out.append(imdb) }
        if let tmdb = s.tmdb { out.append("tmdb:\(tmdb)") }
        return out
    }

    private func localID(from s: SimklService.SyncItem) -> String? {
        if let imdb = s.imdb, imdb.hasPrefix("tt") { return imdb }
        if let tmdb = s.tmdb { return "tmdb:\(tmdb)" }
        return nil
    }

    private func syncItem(fromLibrary item: SavedLibraryItem) -> SimklService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: item.id)
        guard imdb != nil || tmdb != nil else { return nil }
        return SimklService.SyncItem(imdb: imdb, tmdb: tmdb, type: item.type, title: item.name)
    }

    private func syncItem(metaID: String, type: String, rating: Int?) -> SimklService.SyncItem? {
        let (imdb, tmdb) = Self.ids(from: metaID)
        guard imdb != nil || tmdb != nil else { return nil }
        return SimklService.SyncItem(imdb: imdb, tmdb: tmdb, type: type, rating: rating)
    }

    private static func ids(from contentID: String) -> (imdb: String?, tmdb: Int?) {
        if contentID.hasPrefix("tt") { return (contentID, nil) }
        if contentID.hasPrefix("tmdb:"), let n = Int(contentID.dropFirst("tmdb:".count)) { return (nil, n) }
        return (nil, nil)
    }
}
