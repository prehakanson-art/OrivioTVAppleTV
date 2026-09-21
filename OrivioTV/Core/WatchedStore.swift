import Foundation

/// A movie or episode the user has finished. Mirrors the Android `WatchedItem`
/// so it round-trips through `sync_push/pull_watched_items`.
struct WatchedItem: Codable, Identifiable, Hashable {
    let contentID: String
    let contentType: String
    let title: String
    let season: Int?
    let episode: Int?
    let watchedAt: Date

    /// Stable key: movie = contentID; episode = contentID|s|e.
    static func key(contentID: String, season: Int?, episode: Int?) -> String {
        if let season, let episode { return "\(contentID)|\(season)|\(episode)" }
        return contentID
    }

    var key: String { Self.key(contentID: contentID, season: season, episode: episode) }
    var id: String { key }
}

@MainActor
final class WatchedStore: ObservableObject {
    @Published private(set) var items: [String: WatchedItem] = [:]

    /// Fired after a local change so account sync can push. Suppressed while
    /// merging remote data.
    var onLocalChange: (() -> Void)?
    /// Fired with the items the user explicitly un-marked, so account sync can
    /// delete them server-side (`sync_delete_watched_items`) — otherwise the
    /// upsert-only push would resurrect them on the next pull. Mirrors
    /// ProgressStore.onRemove.
    var onRemove: (([WatchedItem]) -> Void)?
    /// Tracking-service hooks, fired on a genuine local mark / un-mark.
    ///
    /// A LIST rather than a single closure: Trakt and SIMKL are independent
    /// destinations and both want to hear about the same local change. While
    /// this was one `onTrakt…` property, whichever manager was constructed
    /// second would silently overwrite the first's subscription. Separate from
    /// the account-sync `onRemove`, which has its own owner.
    var onTrackerMark: [(WatchedItem) -> Void] = []
    var onTrackerRemove: [([WatchedItem]) -> Void] = []
    private var suppressChange = false

    /// Recently un-marked keys → removal time. A full-snapshot pull can still
    /// carry a just-removed row (its server delete lags the pull), so without
    /// this the reconcile below would re-add what the user just cleared.
    private var tombstones: [String: Date] = [:]
    private static let tombstoneGrace: TimeInterval = 180
    /// Grace protecting a freshly-marked row whose push may still be in flight
    /// when a pull's snapshot was captured — don't reconcile it away.
    private static let deletionGrace: TimeInterval = 120

    private func pruneTombstones() {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneGrace)
        tombstones = tombstones.filter { $0.value >= cutoff }
    }

    /// Reassert tombstones from the sync manager before a pull, for removals
    /// whose server delete hasn't been confirmed yet.
    func tombstone(_ keys: [String]) {
        let now = Date()
        for key in keys { tombstones[key] = now }
    }

    /// Read from the SAME key `ProfileStore` persists, so the scope is right
    /// from LAUNCH. The sync manager rescopes every store shortly after start,
    /// but defaulting to 1 here meant a device on any other profile decoded
    /// profile 1's blob on the main actor and then decoded the correct one a
    /// moment later — twice the launch cost, and a reload cascade on top.
    /// `RatingsStore` and `TraktStore` already do this.
    private static let activeProfileKey = "orivio.profiles.active"
    private(set) var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1
    private var storageKey: String {
        profileID == 1 ? "orivio.watched.v1" : "orivio.watched.v1.p\(profileID)"
    }

    init() { load() }

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        // Parked per profile, not dropped: see LibraryStore.setProfile.
        tombstonesByProfile[profileID] = tombstones
        profileID = id
        loadGeneration &+= 1   // invalidate any in-flight load; see clearAll
        suppressChange = true
        items = [:]
        tombstones = tombstonesByProfile[id] ?? [:]
        load()   // also re-reads this profile's removal record
        suppressChange = false
    }
    private var tombstonesByProfile: [Int: [String: Date]] = [:]

    // MARK: - Removed marks (persisted, per profile)

    /// Items the user explicitly un-marked → when.
    ///
    /// The in-memory tombstone lasts three minutes and dies with the process,
    /// but the trackers re-assert a watched mark indefinitely: Stremio's push
    /// copies the previous `flagged_watched` state back onto the row and its
    /// pull re-imports it, and Trakt/SIMKL re-add it from history. So the
    /// un-mark came back on the first sync after the grace expired, and
    /// `requestSyncPush` then propagated it to the account.
    ///
    /// A remote row only lifts the record when it is genuinely NEWER than the
    /// removal — which for these services means the title really was watched
    /// again elsewhere, since they carry the original watch time.
    private var removedMarks: [String: Date] = [:]
    private var removedMarksKey: String {
        profileID == 1 ? "orivio.watched.removed.v1" : "orivio.watched.removed.v1.p\(profileID)"
    }
    private static let removalLife: TimeInterval = 180 * 24 * 60 * 60

    private func loadRemovedMarks() {
        let raw = UserDefaults.standard.dictionary(forKey: removedMarksKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.removalLife).timeIntervalSince1970
        removedMarks = raw.filter { $0.value > cutoff }.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveRemovedMarks() {
        if removedMarks.isEmpty {
            UserDefaults.standard.removeObject(forKey: removedMarksKey)
        } else {
            UserDefaults.standard.set(removedMarks.mapValues { $0.timeIntervalSince1970 },
                                      forKey: removedMarksKey)
        }
    }

    // MARK: - Queries

    func isWatched(contentID: String, season: Int? = nil, episode: Int? = nil) -> Bool {
        items[WatchedItem.key(contentID: contentID, season: season, episode: episode)] != nil
    }

    /// Movie-level watched check.
    func isWatched(_ meta: MetaItem) -> Bool {
        !meta.isSeries && isWatched(contentID: meta.id)
    }

    // MARK: - Mutations

    /// - Parameter fromPlayback: the player crossed the finished threshold, as
    ///   opposed to the user tapping "Mark as watched". Recorded so the Trakt
    ///   push can tell the two apart — a finished playback is ALSO reported
    ///   by the stop scrobble, and sending a history add on top of it logged
    ///   every title the viewer finished as two plays on Trakt.
    func mark(meta: MetaItem, video: MetaVideo?, fromPlayback: Bool = false) {
        let item = WatchedItem(
            contentID: meta.id,
            contentType: meta.type,
            title: video?.title ?? meta.name,
            season: video?.season,
            episode: video?.episode,
            watchedAt: Date()
        )
        if fromPlayback { finishedByPlayback[item.key] = Date() }
        set(item)
    }

    /// Keys the PLAYER marked watched recently → when. Consulted by the Trakt
    /// push (see `mark(fromPlayback:)`); bounded by age, so it never grows.
    private var finishedByPlayback: [String: Date] = [:]

    func wasFinishedByPlayback(_ key: String, within seconds: TimeInterval = 120) -> Bool {
        let cutoff = Date().addingTimeInterval(-seconds)
        finishedByPlayback = finishedByPlayback.filter { $0.value >= cutoff }
        return finishedByPlayback[key] != nil
    }

    func toggleMovie(_ meta: MetaItem) {
        if isWatched(contentID: meta.id) {
            remove(contentID: meta.id, season: nil, episode: nil)
        } else {
            set(WatchedItem(
                contentID: meta.id, contentType: meta.type, title: meta.name,
                season: nil, episode: nil, watchedAt: Date()
            ))
        }
    }

    private func set(_ item: WatchedItem) {
        // Re-marking something you'd un-marked clears its tombstone so the fresh
        // row syncs normally instead of being held back by the reconcile guard.
        tombstones.removeValue(forKey: item.key)
        if removedMarks.removeValue(forKey: item.key) != nil { saveRemovedMarks() }
        let isNew = items[item.key] == nil
        items[item.key] = item
        save()
        if !suppressChange {
            if isNew { for hook in onTrackerMark { hook(item) } }
            onLocalChange?()
        }
    }

    func remove(contentID: String, season: Int?, episode: Int?) {
        let key = WatchedItem.key(contentID: contentID, season: season, episode: episode)
        guard let removed = items.removeValue(forKey: key) else { return }
        tombstones[key] = Date()
        // Outlives the grace window and the process, so a tracker re-import
        // can't quietly put the ✓ back (see `removedMarks`).
        if !suppressChange {
            removedMarks[key] = Date()
            saveRemovedMarks()
        }
        save()
        if !suppressChange {
            onRemove?([removed])
            for hook in onTrackerRemove { hook([removed]) }
            onLocalChange?()
        }
    }

    @discardableResult
    func clearAll(notify: Bool = true, tombstone: Bool = true) -> [WatchedItem] {
        // Invalidate any in-flight async load: see ProgressStore.clearAllProgress.
        loadGeneration &+= 1
        let removedItems = Array(items.values)
        guard !removedItems.isEmpty else { return [] }
        // See ProgressStore.clearAllProgress: on an account switch tombstoning
        // would suppress the INCOMING account's rows for the grace period.
        let now = Date()
        if tombstone {
            for item in removedItems { tombstones[item.key] = now }
        } else {
            // Retiring the previous account: its removals must not suppress the
            // incoming account's rows sharing those keys.
            tombstones.removeAll()
            removedMarks.removeAll()
            saveRemovedMarks()
        }
        items.removeAll()
        save()
        if notify && !suppressChange {
            onRemove?(removedItems)
            for hook in onTrackerRemove { hook(removedItems) }
            onLocalChange?()
        }
        return removedItems
    }

    // MARK: - Sync bridge

    func allForSync() -> [WatchedItem] { Array(items.values) }

    func importItems(_ imported: [WatchedItem]) {
        guard !imported.isEmpty else { return }
        var changed = false
        var marksChanged = false
        for item in imported {
            if let local = items[item.key], local.watchedAt >= item.watchedAt { continue }
            tombstones.removeValue(forKey: item.key)
            // Re-marking clears the un-mark record, exactly as `set` does — a
            // restored backup otherwise kept a `removedMarks` entry that would
            // block this key on a later account pull.
            if removedMarks.removeValue(forKey: item.key) != nil { marksChanged = true }
            items[item.key] = item
            changed = true
        }
        if marksChanged { saveRemovedMarks() }
        if changed {
            save()
            if !suppressChange { onLocalChange?() }
        }
    }

    /// Merge a FULL remote snapshot. Two-way, mirroring ProgressStore: newer
    /// remote rows are added AND (when `reconcile`) local rows the server no
    /// longer has are removed (a removal made on another device propagates),
    /// except freshly-marked rows still inside the grace window and tombstoned
    /// rows whose delete is pending. `reconcile: false` = additive union, used
    /// for a profile's FIRST pull so pre-sign-in local history survives and is
    /// pushed up instead of being treated as remotely deleted.
    /// Returns whether anything changed, so a caller merging from a TRACKER
    /// (Trakt/SIMKL/Stremio) can ask for an account push — the account's own
    /// pulls never need one, and this method fires no change hook of its own.
    @discardableResult
    func mergeRemote(_ remote: [WatchedItem], reconcile: Bool = true) -> Bool {
        suppressChange = true
        defer { suppressChange = false }
        var changed = false
        pruneTombstones()

        // ── Reconcile deletions ── drop local rows absent from the snapshot,
        // unless just marked (their push may still be in flight).
        if reconcile {
            let remoteKeys = Set(remote.map(\.key))
            let cutoff = Date().addingTimeInterval(-Self.deletionGrace)
            let staleKeys = items.compactMap { key, local in
                (!remoteKeys.contains(key) && local.watchedAt < cutoff) ? key : nil
            }
            for key in staleKeys {
                items.removeValue(forKey: key)
                changed = true
            }
        }

        // ── Add rows from the account ── skipping ones the user just un-marked
        // whose delete hasn't landed yet (the snapshot can still contain them).
        //
        // Existing keys are deliberately NOT updated from the remote copy. The
        // tracker merges (Trakt/SIMKL/Stremio) call this too and build their
        // rows with `watchedAt: s.watchedAt ?? Date()`, so a missing timestamp
        // becomes "now". Adopting that would raise the mark above a live
        // Continue Watching row's `updatedAt`, and `ProgressStore.episodeWatchedAfter`
        // would then retire the episode the viewer is part-way through. Add-only
        // is the safe direction here.
        var marksChanged = false
        for item in remote where items[item.key] == nil {
            if let removedAt = removedMarks[item.key] {
                if item.watchedAt > removedAt {
                    removedMarks.removeValue(forKey: item.key)   // watched again elsewhere
                    marksChanged = true
                } else {
                    continue
                }
            }
            if let tomb = tombstones[item.key] {
                if item.watchedAt > tomb {
                    tombstones.removeValue(forKey: item.key)   // re-watched elsewhere
                } else {
                    continue
                }
            }
            items[item.key] = item
            changed = true
        }
        if marksChanged { saveRemovedMarks() }
        if changed { save() }
        return changed
    }

    /// Rows just merged from a tracker need to reach the ACCOUNT too. The
    /// full sync used to upload the whole store unconditionally at the end of
    /// every run, which covered this by accident; now that it pushes only
    /// what is marked dirty, a tracker merge has to say so.
    func requestSyncPush() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    // MARK: - Persistence

    /// Bumped by `setProfile`/`clearAll`; an async `load()` checks it so it
    /// cannot repopulate `items` from a blob captured before an intentional
    /// clear. See `ProgressStore.loadGeneration`.
    private var loadGeneration = 0

    private func load() {
        loadRemovedMarks()
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        // Decode OFF the main actor and publish when it lands — the same
        // treatment CollectionsStore got for the same reason: this runs from
        // the store's init during app startup (and on profile switch), and
        // the history is thousands of rows after a Trakt import. Serial
        // main-thread JSONDecoder work across the content stores was the
        // dominant pre-first-frame cost on the A8.
        let key = storageKey
        let expectedProfile = profileID
        let generation = loadGeneration
        Task.detached(priority: .userInitiated) {
            // `inflated` returns the stored bytes untouched when they carry no
            // compression magic, so a blob an older build wrote still decodes.
            let decoded = try? JSONDecoder().decode([String: WatchedItem].self,
                                                    from: StoreBlob.inflated(data))
            await MainActor.run { [weak self] in
                guard let self, self.profileID == expectedProfile,
                      self.loadGeneration == generation else { return }
                guard let decoded else {
                    UnreadableBlobGuard.preserve(data, key: key)   // see ProgressStore
                    return
                }
                if self.items.isEmpty {
                    self.items = decoded
                } else {
                    // Something wrote before the decode landed (an early mark,
                    // a fast sync merge): keep the newer in-memory rows, add
                    // the persisted ones under them, and re-persist the union
                    // so neither side is lost.
                    self.items.merge(decoded) { current, _ in current }
                    self.save()
                }
            }
        }
    }

    /// Monotonic stamp so two in-flight writes can't land out of order.
    private var saveSequence: UInt64 = 0

    /// Encode + write OFF the main actor, exactly as `ProgressStore` does.
    ///
    /// This used to serialize the ENTIRE watch history and write UserDefaults
    /// synchronously on the main actor, once per `set(_:)` — so "Mark Season
    /// Watched" on a 24-episode season did 24 full encodes of a history that
    /// is thousands of rows after a Trakt import, back to back, freezing the
    /// focus engine for the duration.
    private func save() {
        saveSequence += 1
        let sequence = saveSequence
        let key = storageKey
        let snapshot = items
        Task.detached(priority: .utility) {
            await WatchedPersister.shared.write(snapshot, key: key, sequence: sequence)
        }
    }
}


/// Serializes watched-history writes off the main actor. Per storage KEY, so a
/// burst of writes across profiles (an account switch) can't drop one profile's
/// write as "out of order" when it was simply for a different key.
private actor WatchedPersister {
    static let shared = WatchedPersister()
    private var lastSequence: [String: UInt64] = [:]

    func write(_ snapshot: [String: WatchedItem], key: String, sequence: UInt64) async {
        guard sequence > (lastSequence[key] ?? 0) else { return }
        lastSequence[key] = sequence
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Compressed: a large imported history is the key that can push the
        // whole defaults domain past the ~1 MB CFPreferences abort. See StoreBlob.
        UserDefaults.standard.set(StoreBlob.deflated(data), forKey: key)
    }
}
