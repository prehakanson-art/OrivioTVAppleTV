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
    /// Trakt-specific hooks (separate owner from the account-sync onRemove):
    /// fired on a genuine local mark / un-mark so the Trakt manager can add or
    /// remove the item from Trakt watch history.
    var onTraktMark: ((WatchedItem) -> Void)?
    var onTraktRemove: (([WatchedItem]) -> Void)?
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

    private var profileID = 1
    private var storageKey: String {
        profileID == 1 ? "orivio.watched.v1" : "orivio.watched.v1.p\(profileID)"
    }

    init() { load() }

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        suppressChange = true
        items = [:]
        load()
        suppressChange = false
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

    func mark(meta: MetaItem, video: MetaVideo?) {
        let item = WatchedItem(
            contentID: meta.id,
            contentType: meta.type,
            title: video?.title ?? meta.name,
            season: video?.season,
            episode: video?.episode,
            watchedAt: Date()
        )
        set(item)
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
        let isNew = items[item.key] == nil
        items[item.key] = item
        save()
        if !suppressChange {
            if isNew { onTraktMark?(item) }
            onLocalChange?()
        }
    }

    func remove(contentID: String, season: Int?, episode: Int?) {
        let key = WatchedItem.key(contentID: contentID, season: season, episode: episode)
        guard let removed = items.removeValue(forKey: key) else { return }
        tombstones[key] = Date()
        save()
        if !suppressChange {
            onRemove?([removed])
            onTraktRemove?([removed])
            onLocalChange?()
        }
    }

    @discardableResult
    func clearAll(notify: Bool = true) -> [WatchedItem] {
        let removedItems = Array(items.values)
        guard !removedItems.isEmpty else { return [] }
        let now = Date()
        for item in removedItems { tombstones[item.key] = now }
        items.removeAll()
        save()
        if notify && !suppressChange {
            onRemove?(removedItems)
            onTraktRemove?(removedItems)
            onLocalChange?()
        }
        return removedItems
    }

    // MARK: - Sync bridge

    func allForSync() -> [WatchedItem] { Array(items.values) }

    func importItems(_ imported: [WatchedItem]) {
        guard !imported.isEmpty else { return }
        var changed = false
        for item in imported {
            if let local = items[item.key], local.watchedAt >= item.watchedAt { continue }
            tombstones.removeValue(forKey: item.key)
            items[item.key] = item
            changed = true
        }
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
    func mergeRemote(_ remote: [WatchedItem], reconcile: Bool = true) {
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
        for item in remote where items[item.key] == nil {
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
        if changed { save() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: WatchedItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
