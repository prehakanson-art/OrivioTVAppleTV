import Foundation

/// The link last played for a title — used by "Reuse last link".
struct LastLink: Codable, Equatable {
    var stream: Stream
    var addonName: String
    var rejectionKey: String
    var savedAt: Date
}

struct WatchProgress: Codable, Identifiable, Equatable {
    /// Movie id, or the episode's video id `<show>:<s>:<e>`.
    var id: String
    var metaID: String
    var type: String
    var videoID: String?
    var season: Int?
    var episode: Int?
    var position: Double
    var duration: Double
    var updatedAt: Date
    var name: String
    var poster: String?
    var background: String?
    var logo: String?
    var episodeTitle: String?
    var episodeThumbnail: String?
    var signature: StreamSignature?
    var lastLink: LastLink?

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var isFinished: Bool { fraction >= 0.95 }
    var isResumable: Bool { fraction > 0.02 && !isFinished }
    var remaining: Double { max(0, duration - position) }
    var isEpisode: Bool { season != nil && episode != nil }

    var remainingLabel: String {
        let m = Int(remaining / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(max(1, m))m left"
    }

    var episodeCode: String? {
        guard let s = season, let e = episode else { return nil }
        return "S\(s):E\(e)"
    }

    var meta: MetaItem {
        MetaItem(id: metaID, type: type, name: name, poster: poster, background: background, logo: logo)
    }
}

/// Watch progress / Continue Watching, per profile.
@MainActor
final class ProgressStore: ObservableObject, ProfileScoped {
    @Published private(set) var entries: [String: WatchProgress] = [:]
    /// Shows/movies removed from Continue Watching (tombstoned so a stale sync can't bring them back).
    private(set) var removed = Tombstones()
    /// Next Up rows the viewer dismissed (by show id).
    private(set) var dismissedNextUp: [String: Date] = [:]

    private let baseKey = "progress.v1"
    private let removedKey = "progress.removedShows.v1"
    private let dismissedKey = "nextUp.dismissed.v1"
    private var saveWork: DispatchWorkItem?
    private var transientSaves = 0

    init() { load() }

    private func load() {
        let p = ProfileScope.current
        entries = Persistence.loadScoped([String: WatchProgress].self, base: baseKey, profile: p) ?? [:]
        removed = Persistence.loadScoped(Tombstones.self, base: removedKey, profile: p) ?? Tombstones()
        dismissedNextUp = Persistence.loadScoped([String: Date].self, base: dismissedKey, profile: p) ?? [:]
    }

    func reloadForActiveProfile() { load() }

    private func scheduleSave(markDirty: Bool) {
        saveWork?.cancel()
        // Snapshot the profile too: switching profiles inside the debounce must
        // not write one profile's history into another.
        let profile = ProfileScope.current
        let entries = self.entries
        let removed = self.removed
        let dismissed = dismissedNextUp
        let local_baseKey = baseKey
        let local_removedKey = removedKey
        let local_dismissedKey = dismissedKey
        let work = DispatchWorkItem {
            // Encoding the whole history and compressing it is main-thread work
            // that used to land mid-film, every save the player schedules.
            Persistence.saveScopedInBackground(entries, base: local_baseKey, profile: profile)
            Persistence.saveScopedInBackground(removed, base: local_removedKey, profile: profile)
            Persistence.saveScopedInBackground(dismissed, base: local_dismissedKey, profile: profile)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        if markDirty { SyncSignals.markDirty(.watchProgress) }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let p = ProfileScope.current
        Persistence.saveScoped(entries, base: baseKey, profile: p)
        Persistence.saveScoped(removed, base: removedKey, profile: p)
        Persistence.saveScoped(dismissedNextUp, base: dismissedKey, profile: p)
    }

    // MARK: Reads

    func progress(for id: String) -> WatchProgress? { entries[id] }

    func progress(meta: MetaItem, video: MetaVideo?) -> WatchProgress? {
        entries[video?.id ?? meta.id]
    }

    /// All progress rows for one show, newest first.
    func showEntries(_ metaID: String) -> [WatchProgress] {
        entries.values.filter { $0.metaID == metaID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Most recent row per title that is still in progress (< 95 %).
    var inProgress: [WatchProgress] {
        var latest: [String: WatchProgress] = [:]
        for e in entries.values {
            if removed.contains(e.metaID), let at = removed.ids[e.metaID], e.updatedAt <= at { continue }
            if let cur = latest[e.metaID], cur.updatedAt >= e.updatedAt { continue }
            latest[e.metaID] = e
        }
        return latest.values.filter { !$0.isFinished && $0.position > 5 }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Writes

    /// Saves a position. `transient` saves (the ~20 s player tick) push to sync
    /// only every 3rd time.
    func record(_ progress: WatchProgress, transient: Bool) {
        var p = progress
        if let existing = entries[p.id] {
            if p.signature == nil { p.signature = existing.signature }
            if p.lastLink == nil { p.lastLink = existing.lastLink }
        }
        entries[p.id] = p
        if let at = removed.ids[p.metaID], p.updatedAt > at { removed.remove(p.metaID) }
        dismissedNextUp[p.metaID] = nil
        if transient {
            transientSaves += 1
            scheduleSave(markDirty: transientSaves % 3 == 0)
        } else {
            scheduleSave(markDirty: true)
        }
    }

    func clear(_ id: String) {
        entries[id] = nil
        scheduleSave(markDirty: true)
    }

    /// Remove a title (all its episodes) from Continue Watching.
    func removeFromContinueWatching(metaID: String) {
        for (k, v) in entries where v.metaID == metaID && !v.isFinished { entries[k] = nil }
        removed.add(metaID)
        dismissedNextUp[metaID] = Date()
        scheduleSave(markDirty: true)
    }

    func dismissNextUp(_ metaID: String) {
        dismissedNextUp[metaID] = Date()
        scheduleSave(markDirty: false)
    }

    func setLastLink(_ link: LastLink, signature: StreamSignature, for id: String) {
        guard var e = entries[id] else { return }
        e.lastLink = link
        e.signature = signature
        entries[id] = e
        scheduleSave(markDirty: false)
    }

    /// Last-link info is also needed before any progress exists.
    private var pendingLinks: [String: (LastLink, StreamSignature)] = [:]
    func rememberLink(_ link: LastLink, signature: StreamSignature, for id: String) {
        if entries[id] != nil { setLastLink(link, signature: signature, for: id) } else { pendingLinks[id] = (link, signature) }
    }
    func takePendingLink(for id: String) -> (LastLink, StreamSignature)? {
        defer { pendingLinks[id] = nil }
        return pendingLinks[id]
    }

    func lastLink(for metaID: String) -> LastLink? {
        entries.values.filter { $0.metaID == metaID || $0.id == metaID }.compactMap(\.lastLink).max { $0.savedAt < $1.savedAt }
    }

    func clearAll() {
        entries.removeAll()
        removed = Tombstones()
        dismissedNextUp.removeAll()
        scheduleSave(markDirty: true)
    }

    // MARK: Sync

    func applyRemote(_ remote: [WatchProgress]) {
        let remoteIDs = Set(remote.map(\.metaID))
        var merged = entries
        for r in remote {
            if let at = removed.ids[r.metaID], r.updatedAt <= at { continue }
            if let local = merged[r.id], local.updatedAt > r.updatedAt { continue }
            var copy = r
            if let local = merged[r.id] {
                copy.signature = local.signature
                copy.lastLink = local.lastLink
                if copy.poster == nil { copy.poster = local.poster }
                if copy.background == nil { copy.background = local.background }
                if copy.logo == nil { copy.logo = local.logo }
                if copy.episodeTitle == nil { copy.episodeTitle = local.episodeTitle }
                if copy.episodeThumbnail == nil { copy.episodeThumbnail = local.episodeThumbnail }
            }
            merged[r.id] = copy
        }
        // A full snapshot: rows we pushed before that are gone remotely were deleted elsewhere.
        let remoteKeys = Set(remote.map(\.id))
        for (k, v) in merged where !remoteKeys.contains(k) && v.updatedAt < Date().addingTimeInterval(-120) {
            merged[k] = nil
        }
        removed.retire(absentFrom: remoteIDs.union(Set(removed.ids.keys.filter { id in merged.values.contains { $0.metaID == id } })))
        // Unchanged (most sync passes): no publish, no disk write — each one
        // redrew every watching screen and rewrote the file on the main thread.
        guard merged != entries else { return }
        entries = merged
        saveNow()
    }

    /// Merge from a tracker (Trakt/SIMKL/Stremio). Requests a push.
    func mergeFromTracker(_ rows: [WatchProgress]) {
        var changed = false
        for r in rows {
            if let at = removed.ids[r.metaID], r.updatedAt <= at { continue }
            if let local = entries[r.id], local.updatedAt >= r.updatedAt { continue }
            var copy = r
            if let local = entries[r.id] {
                copy.signature = local.signature
                copy.lastLink = local.lastLink
            }
            entries[r.id] = copy
            changed = true
        }
        if changed { scheduleSave(markDirty: true) }
    }

    /// Fill missing art/titles (Enrich Continue Watching).
    func enrich(id: String, with meta: MetaItem) {
        guard var e = entries[id] else { return }
        var changed = false
        if e.poster == nil, let p = meta.poster { e.poster = p; changed = true }
        if e.background == nil, let b = meta.background { e.background = b; changed = true }
        if e.logo == nil, let l = meta.logo { e.logo = l; changed = true }
        if e.name.isEmpty || e.name == e.metaID { e.name = meta.name; changed = true }
        if let s = e.season, let ep = e.episode, e.episodeTitle == nil,
           let v = meta.videos.first(where: { $0.season == s && $0.episode == ep }) {
            e.episodeTitle = v.title
            e.episodeThumbnail = v.thumbnail
            changed = true
        }
        if changed {
            entries[id] = e
            scheduleSave(markDirty: false)
        }
    }
}
