import Combine
import Foundation

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
/// * **No Continue Watching.** SIMKL has no playback-position API — nothing
///   equivalent to Trakt's `/sync/playback` — so there is no partial position
///   to pull in or push out. Marking something watched still flows through the
///   history phase.
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

    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    /// Throttle full syncs so foreground + sign-in + a setting flip don't stack.
    private var lastFullSync = Date.distantPast

    init(simkl: SimklStore, watched: WatchedStore, library: LibraryStore,
         ratings: RatingsStore, addonManager: AddonManager) {
        self.simkl = simkl
        self.watched = watched
        self.library = library
        self.ratings = ratings
        self.addonManager = addonManager

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
                    self?.syncNow(force: true)
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
    }

    // MARK: - Full sync

    /// Run a full two-way sync (throttled). `force` bypasses the throttle
    /// (sign-in, manual "Sync now", a setting flip).
    func syncNow(force: Bool = false) {
        guard simkl.isSignedIn else { return }
        if !force, Date().timeIntervalSince(lastFullSync) < 60 { return }
        lastFullSync = Date()
        // Coalesce rather than cancel: a rapid second trigger (sign-in +
        // foreground) must not abort the first sync mid-way.
        if let t = syncTask, !t.isCancelled { return }
        syncTask = Task { [weak self] in
            await self?.runSync()
            self?.syncTask = nil
        }
    }

    private func runSync() async {
        guard let token = simkl.accessToken else { return }
        NSLog("[OrivioSimkl] runSync start (history=%d watchlist=%d ratings=%d)",
              simkl.syncWatchHistory ? 1 : 0, simkl.syncWatchlist ? 1 : 0,
              simkl.syncRatings ? 1 : 0)

        // One fetch feeds all three phases. SIMKL returns the whole library per
        // bucket, so asking once per phase would pull the same payload three
        // times over — and `completed` already carries the ratings.
        async let completedItems = SimklService.allItems(type: "movies", status: "completed", accessToken: token)
        async let completedShows = SimklService.allItems(type: "shows", status: "completed", accessToken: token)
        async let completedAnime = SimklService.allItems(type: "anime", status: "completed", accessToken: token)
        let completed = merge(await completedItems, await completedShows, await completedAnime)

        // A failed fetch is nil, NOT an empty library. Treating an outage as
        // "SIMKL has nothing" would make every push phase re-upload the
        // viewer's entire history on the next flaky network.
        guard let completed else {
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

        var parts: [String] = []
        if simkl.syncWatchHistory {
            parts.append("\(await syncWatchHistory(remote: completed, token: token)) history")
        }
        if simkl.syncWatchlist {
            if let n = await syncWatchlist(token: token) { parts.append("\(n) watchlist") }
        }
        if simkl.syncRatings {
            parts.append("\(await syncRatings(remote: completed, token: token)) ratings")
        }
        NSLog("[OrivioSimkl] runSync done: %@", parts.joined(separator: ", "))
        simkl.setSyncStatus(parts.isEmpty
                            ? "SIMKL: nothing to sync"
                            : "SIMKL synced (\(parts.joined(separator: ", ")))")
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

    /// Two-way watch history. Pull SIMKL → add anything missing locally; push
    /// local items SIMKL doesn't have. Returns the count pulled.
    private func syncWatchHistory(remote: [SimklService.SyncItem], token: String) async -> Int {
        let clearedAt = WatchHistoryClearState.clearedAt
        // Only EPISODE rows and movies are history; the show-level row that
        // `allItems` also emits carries the rating, not a viewing.
        let remoteItems = remote
            .filter { $0.type == "movie" || ($0.season != nil && $0.episode != nil) }
            .compactMap(watchedItem(from:))
            .filter { item in
                guard let clearedAt else { return true }
                return item.watchedAt > clearedAt
            }
        // Additive — never delete local history from a partial SIMKL response.
        if !remoteItems.isEmpty { watched.mergeRemote(remoteItems, reconcile: false) }

        let remoteKeys = Set(remoteItems.map(\.key))
        let pushable = watched.allForSync()
            .filter { !remoteKeys.contains($0.key) }
            .compactMap(syncItem(from:))
        if !pushable.isEmpty {
            _ = await SimklService.addToHistory(pushable, accessToken: token)
        }
        return remoteItems.count
    }

    /// Two-way watchlist ↔ Library. Returns the count pulled, or nil if SIMKL's
    /// plan-to-watch list couldn't be read (in which case nothing is pushed —
    /// an unreadable list would look like "SIMKL has none of this").
    private func syncWatchlist(token: String) async -> Int? {
        async let movies = SimklService.allItems(type: "movies", status: "plantowatch", accessToken: token)
        async let shows = SimklService.allItems(type: "shows", status: "plantowatch", accessToken: token)
        async let anime = SimklService.allItems(type: "anime", status: "plantowatch", accessToken: token)
        guard let remote = merge(await movies, await shows, await anime) else { return nil }
        // Show-level rows only: an episode entry is not a watchlist item.
        let titles = remote.filter { $0.season == nil }

        var added: [SavedLibraryItem] = []
        var enriched = 0
        for s in titles {
            guard let id = localID(from: s), !library.contains(id: id, type: s.type) else { continue }
            var name = s.title
            var poster: String?
            var background: String?
            // Same budget as the Trakt manager: artwork for the first 25 so a
            // large watchlist can't turn one sync into hundreds of meta calls.
            if enriched < 25, let addon = addonManager.metaAddon(for: s.type, id: id),
               let meta = try? await StremioAPI.meta(addon: addon, type: s.type, id: id) {
                enriched += 1
                if !meta.name.isEmpty { name = meta.name }
                poster = meta.poster
                background = meta.background
            }
            added.append(SavedLibraryItem(id: id, type: s.type, name: name,
                                          poster: poster, background: background))
        }
        if !added.isEmpty { library.mergeRemote(added, reconcile: false) }

        let remoteKeys = Set(titles.compactMap { s -> String? in
            localID(from: s).map { "\(s.type)|\($0)" }
        })
        let localOnly = library.allForSync()
            .filter { !remoteKeys.contains($0.key) }
            .compactMap { syncItem(fromLibrary: $0) }
        if !localOnly.isEmpty { _ = await SimklService.addToWatchlist(localOnly, accessToken: token) }
        return titles.count
    }

    /// Two-way ratings (additive pull + push local-only). SIMKL returns the
    /// rating on the library row, so this reuses the already-fetched payload.
    private func syncRatings(remote: [SimklService.SyncItem], token: String) async -> Int {
        let mapped: [(metaID: String, type: String, rating: Int)] = remote.compactMap { s in
            // Show-level rows only — SIMKL rates titles, not episodes.
            guard s.season == nil, let id = localID(from: s), let r = s.rating else { return nil }
            return (id, s.type, r)
        }
        if !mapped.isEmpty { ratings.mergeRemote(mapped) }

        let remoteIDs = Set(mapped.map(\.metaID))
        let pushable = ratings.allForSync()
            .filter { !remoteIDs.contains($0.metaID) }
            .compactMap { syncItem(metaID: $0.metaID, type: $0.type, rating: $0.rating) }
        if !pushable.isEmpty { _ = await SimklService.addRatings(pushable, accessToken: token) }
        return mapped.count
    }

    // MARK: - Immediate push

    /// Every immediate push runs the same shape: bail unless signed in and the
    /// relevant switch is on, map to a SIMKL item, send it.
    private func push(_ enabled: Bool, _ items: [SimklService.SyncItem],
                      _ send: @escaping ([SimklService.SyncItem], String) async -> Bool) {
        guard simkl.isSignedIn, enabled, !items.isEmpty,
              let token = simkl.accessToken else { return }
        Task { _ = await send(items, token) }
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
                           watchedAt: s.watchedAt ?? Date())
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
