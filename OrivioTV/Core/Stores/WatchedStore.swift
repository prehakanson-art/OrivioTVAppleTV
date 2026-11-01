import Foundation

struct WatchedItem: Codable, Identifiable, Equatable {
    /// Movie id or episode id `<show>:<s>:<e>`.
    var id: String
    var metaID: String
    var type: String
    var season: Int?
    var episode: Int?
    var watchedAt: Date
    var name: String?
}

/// Watched marks (movies + episodes), per profile.
@MainActor
final class WatchedStore: ObservableObject, ProfileScoped {
    @Published private(set) var items: [String: WatchedItem] = [:]
    private(set) var removed = Tombstones()
    /// Shows considered "dropped" (Trakt) — excluded from Next Up.
    @Published var droppedShows: Set<String> = []

    private let baseKey = "watched.v1"
    private let removedKey = "watched.removed.v1"
    private var saveWork: DispatchWorkItem?

    init() { load() }

    private func load() {
        let p = ProfileScope.current
        items = Persistence.loadScoped([String: WatchedItem].self, base: baseKey, profile: p) ?? [:]
        removed = Persistence.loadScoped(Tombstones.self, base: removedKey, profile: p) ?? Tombstones()
    }

    func reloadForActiveProfile() { load() }

    private func scheduleSave(markDirty: Bool = true) {
        saveWork?.cancel()
        // Snapshot the profile too: switching profiles inside the debounce must
        // not write one profile's history into another.
        let profile = ProfileScope.current
        let items = self.items
        let removed = self.removed
        let local_baseKey = baseKey
        let local_removedKey = removedKey
        let work = DispatchWorkItem {
            Persistence.saveScopedInBackground(items, base: local_baseKey, profile: profile)
            Persistence.saveScopedInBackground(removed, base: local_removedKey, profile: profile)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        if markDirty { SyncSignals.markDirty(.watched) }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let p = ProfileScope.current
        Persistence.saveScoped(items, base: baseKey, profile: p)
        Persistence.saveScoped(removed, base: removedKey, profile: p)
    }

    func isWatched(_ id: String) -> Bool { items[id] != nil }

    func isWatched(meta: MetaItem, video: MetaVideo? = nil) -> Bool {
        if let video { return items[video.id] != nil }
        if meta.isSeries {
            let aired = meta.orderedEpisodes.filter(\.hasAired)
            return !aired.isEmpty && aired.allSatisfy { items[$0.id] != nil }
        }
        return items[meta.id] != nil
    }

    func watchedEpisodes(of showID: String) -> [WatchedItem] {
        items.values.filter { $0.metaID == showID && $0.season != nil }
    }

    /// The furthest (season, episode) watched in a show.
    func furthestEpisode(of showID: String) -> (season: Int, episode: Int)? {
        watchedEpisodes(of: showID).compactMap { w -> (Int, Int)? in
            guard let s = w.season, let e = w.episode, s > 0 else { return nil }
            return (s, e)
        }.max { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    func mostRecentEpisode(of showID: String) -> WatchedItem? {
        watchedEpisodes(of: showID).max { $0.watchedAt < $1.watchedAt }
    }

    func markWatched(meta: MetaItem, video: MetaVideo? = nil, at date: Date = Date()) {
        if let video {
            items[video.id] = WatchedItem(id: video.id, metaID: meta.id, type: meta.type, season: video.season,
                                          episode: video.episode, watchedAt: date, name: meta.name)
            removed.remove(video.id)
        } else if meta.isSeries {
            for v in meta.orderedEpisodes where v.hasAired {
                items[v.id] = WatchedItem(id: v.id, metaID: meta.id, type: meta.type, season: v.season, episode: v.episode,
                                          watchedAt: date, name: meta.name)
                removed.remove(v.id)
            }
        } else {
            items[meta.id] = WatchedItem(id: meta.id, metaID: meta.id, type: meta.type, watchedAt: date, name: meta.name)
            removed.remove(meta.id)
        }
        scheduleSave()
    }

    func markSeasonWatched(meta: MetaItem, season: Int, watched: Bool) {
        for v in meta.episodes(season: season) where v.hasAired {
            if watched {
                items[v.id] = WatchedItem(id: v.id, metaID: meta.id, type: meta.type, season: v.season, episode: v.episode,
                                          watchedAt: Date(), name: meta.name)
                removed.remove(v.id)
            } else if items[v.id] != nil {
                items[v.id] = nil
                removed.add(v.id)
            }
        }
        scheduleSave()
    }

    func markUnwatched(meta: MetaItem, video: MetaVideo? = nil) {
        let ids: [String]
        if let video { ids = [video.id] } else if meta.isSeries { ids = items.values.filter { $0.metaID == meta.id }.map(\.id) } else { ids = [meta.id] }
        for id in ids where items[id] != nil {
            items[id] = nil
            removed.add(id)
        }
        scheduleSave()
    }

    func clearAll() {
        for id in items.keys { removed.add(id) }
        items.removeAll()
        scheduleSave()
    }

    // MARK: Sync

    func applyRemote(_ remote: [WatchedItem]) {
        let remoteIDs = Set(remote.map(\.id))
        removed.retire(absentFrom: remoteIDs)
        var merged: [String: WatchedItem] = [:]
        for r in remote where !removed.contains(r.id) { merged[r.id] = r }
        // Keep local marks newer than two minutes that the server hasn't seen yet.
        for (k, v) in items where merged[k] == nil && v.watchedAt > Date().addingTimeInterval(-120) { merged[k] = v }
        // Unchanged (most sync passes): no publish, no disk write — each one
        // redrew every watching screen and rewrote the file on the main thread.
        guard merged != items else { return }
        items = merged
        saveNow()
    }

    func mergeFromTracker(_ rows: [WatchedItem]) {
        var changed = false
        for r in rows where items[r.id] == nil && !removed.contains(r.id) {
            items[r.id] = r
            changed = true
        }
        if changed { scheduleSave() }
    }
}
