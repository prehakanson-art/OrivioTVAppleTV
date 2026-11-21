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
    /// Done watching. 95 % for everything, and for a movie anything inside
    /// its end credits too: a feature's credits run 5–10 minutes, so stopping
    /// as they roll used to leave the film in Continue Watching at ~92 %.
    /// The last 10 % (capped at ten minutes) counts as credits. A player that
    /// knows the exact credits chapter records the full duration instead.
    var isFinished: Bool {
        guard duration > 0 else { return false }
        if fraction >= 0.95 { return true }
        if !isEpisode, type == "movie", duration >= 40 * 60 {
            return remaining <= min(duration * 0.10, 600)
        }
        return false
    }
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
    /// Bumped whenever a title is removed or dismissed from Continue Watching.
    /// `removed` and `dismissedNextUp` aren't published, and a Next Up card has
    /// no progress row to delete, so `entries` often doesn't change on a
    /// removal — Home watches this so the card leaves the row immediately
    /// instead of on the next sync pull minutes later.
    @Published private(set) var removalRevision = 0

    /// Periodic in-playback saves that are persisted and synced but NOT yet
    /// published. Publishing `entries` on every ~10 s player tick re-rendered
    /// the whole Home screen sitting behind the player — and 1.5 s later its
    /// debounced Continue Watching rebuild re-rendered it again — two main-
    /// thread stalls of 60–300 ms every ten seconds, which the video's render
    /// loop (on the main run loop) showed as dropped frames. The next
    /// non-transient save (pause, exit, episode change) folds these in with a
    /// single publish.
    private var silent: [String: WatchProgress] = [:]

    /// `entries` with the unpublished periodic saves laid over it — the true
    /// current state. Use this for anything that persists, syncs or resumes.
    var allEntries: [String: WatchProgress] {
        guard !silent.isEmpty else { return entries }
        var out = entries
        for (k, v) in silent where (out[k]?.updatedAt ?? .distantPast) <= v.updatedAt { out[k] = v }
        return out
    }

    private static let removalLife: TimeInterval = 30 * 24 * 60 * 60
    private let baseKey = "progress.v1"
    private let removedKey = "progress.removedShows.v1"
    private let dismissedKey = "nextUp.dismissed.v1"
    private var saveWork: DispatchWorkItem?
    private var transientSaves = 0

    init() { load() }

    private func load() {
        let p = ProfileScope.current
        silent.removeAll()
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
        let entries = self.allEntries
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
        Persistence.saveScoped(allEntries, base: baseKey, profile: p)
        Persistence.saveScoped(removed, base: removedKey, profile: p)
        Persistence.saveScoped(dismissedNextUp, base: dismissedKey, profile: p)
    }

    // MARK: Reads

    func progress(for id: String) -> WatchProgress? { silent[id] ?? entries[id] }

    func progress(meta: MetaItem, video: MetaVideo?) -> WatchProgress? {
        progress(for: video?.id ?? meta.id)
    }

    /// All progress rows for one show, newest first.
    func showEntries(_ metaID: String) -> [WatchProgress] {
        allEntries.values.filter { $0.metaID == metaID }.sorted { $0.updatedAt > $1.updatedAt }
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
        if let existing = self.progress(for: p.id) {
            if p.signature == nil { p.signature = existing.signature }
            if p.lastLink == nil { p.lastLink = existing.lastLink }
        }
        if transient {
            silent[p.id] = p
        } else {
            // One publish carrying this row and every periodic save before it.
            var next = allEntries
            next[p.id] = p
            silent.removeAll()
            entries = next
        }
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
        silent[id] = nil
        entries[id] = nil
        removalRevision &+= 1
        scheduleSave(markDirty: true)
    }

    /// Remove a title (all its episodes) from Continue Watching.
    func removeFromContinueWatching(metaID: String) {
        for (k, v) in silent where v.metaID == metaID && !v.isFinished { silent[k] = nil }
        for (k, v) in entries where v.metaID == metaID && !v.isFinished { entries[k] = nil }
        removed.add(metaID)
        dismissedNextUp[metaID] = Date()
        removalRevision &+= 1
        scheduleSave(markDirty: true)
    }

    func dismissNextUp(_ metaID: String) {
        dismissedNextUp[metaID] = Date()
        removalRevision &+= 1
        scheduleSave(markDirty: false)
    }

    func setLastLink(_ link: LastLink, signature: StreamSignature, for id: String) {
        if var e = silent[id] {
            e.lastLink = link
            e.signature = signature
            silent[id] = e
            scheduleSave(markDirty: false)
            return
        }
        guard var e = entries[id] else { return }
        e.lastLink = link
        e.signature = signature
        entries[id] = e
        scheduleSave(markDirty: false)
    }

    /// Last-link info is also needed before any progress exists.
    private var pendingLinks: [String: (LastLink, StreamSignature)] = [:]
    func rememberLink(_ link: LastLink, signature: StreamSignature, for id: String) {
        if progress(for: id) != nil { setLastLink(link, signature: signature, for: id) } else { pendingLinks[id] = (link, signature) }
    }
    func takePendingLink(for id: String) -> (LastLink, StreamSignature)? {
        defer { pendingLinks[id] = nil }
        return pendingLinks[id]
    }

    func lastLink(for metaID: String) -> LastLink? {
        allEntries.values.filter { $0.metaID == metaID || $0.id == metaID }.compactMap(\.lastLink).max { $0.savedAt < $1.savedAt }
    }

    func clearAll() {
        silent.removeAll()
        entries.removeAll()
        removed = Tombstones()
        dismissedNextUp.removeAll()
        scheduleSave(markDirty: true)
    }

    // MARK: Sync

    func applyRemote(_ remote: [WatchProgress]) {
        var merged = entries
        for r in remote {
            if let at = removed.ids[r.metaID], r.updatedAt <= at { continue }
            // Same timestamp = the row we already hold (usually our own push
            // echoed back). Re-adopting it blanked its title — the account
            // stores no names — so every 90 s pull republished Continue
            // Watching, and the name backfill republished it again.
            if let local = merged[r.id], local.updatedAt >= r.updatedAt { continue }
            if let playing = silent[r.id], playing.updatedAt >= r.updatedAt { continue }
            var copy = r
            if let local = merged[r.id] {
                copy.signature = local.signature
                copy.lastLink = local.lastLink
                if copy.name.isEmpty { copy.name = local.name }
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
        for (k, v) in merged where !remoteKeys.contains(k) && silent[k] == nil && v.updatedAt < Date().addingTimeInterval(-120) {
            merged[k] = nil
        }
        // Removals expire on AGE, not on the account forgetting the title.
        // Retiring a tombstone as soon as the account stopped returning the
        // show let the next Trakt/SIMKL/Stremio merge hand back its old row,
        // and the removed card reappeared. A newer row (watched again) lifts a
        // removal on its own, so keeping it longer never hides a real re-watch.
        removed.prune(olderThan: Date().addingTimeInterval(-Self.removalLife))
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
            if let local = progress(for: r.id), local.updatedAt >= r.updatedAt { continue }
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
