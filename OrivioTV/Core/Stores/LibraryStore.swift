import Foundation

struct LibraryItem: Codable, Identifiable, Equatable {
    var id: String { meta.id }
    var meta: MetaItem
    var addedAt: Date
}

/// Saved titles, per profile.
@MainActor
final class LibraryStore: ObservableObject, ProfileScoped {
    @Published private(set) var items: [LibraryItem] = [] {
        didSet { ids = Set(items.map(\.meta.id)) }
    }
    /// `contains` runs for every poster on every redraw (its hold menu): a set,
    /// not a scan of the whole library.
    private var ids: Set<String> = []
    private(set) var removed = Tombstones()
    private let baseKey = "library.v1"
    private let removedKey = "library.removed.v1"

    init() { load() }

    private func load() {
        let p = ProfileScope.current
        items = Persistence.loadScoped([LibraryItem].self, base: baseKey, profile: p) ?? []
        removed = Persistence.loadScoped(Tombstones.self, base: removedKey, profile: p) ?? Tombstones()
    }

    func reloadForActiveProfile() { load() }

    private func save(markDirty: Bool = true) {
        let p = ProfileScope.current
        // Off-main: this runs on the "Add to Library" press, and a library of a
        // few hundred titles is a JSON encode plus a zlib pass before the button
        // acknowledges anything on an A8.
        Persistence.saveScopedInBackground(items, base: baseKey, profile: p)
        Persistence.saveScopedInBackground(removed, base: removedKey, profile: p)
        if markDirty { SyncSignals.markDirty(.library) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func add(_ meta: MetaItem) {
        guard !contains(meta.id) else { return }
        items.insert(LibraryItem(meta: meta.preview, addedAt: Date()), at: 0)
        removed.remove(meta.id)
        save()
    }

    func remove(_ id: String) {
        guard contains(id) else { return }
        items.removeAll { $0.meta.id == id }
        removed.add(id)
        save()
    }

    /// Returns the new state (true = in library).
    @discardableResult
    func toggle(_ meta: MetaItem) -> Bool {
        if contains(meta.id) { remove(meta.id); return false }
        add(meta)
        return true
    }

    func applyRemote(_ remote: [LibraryItem]) {
        removed.retire(absentFrom: Set(remote.map(\.id)))
        var merged = remote.filter { !removed.contains($0.id) }
        let remoteIDs = Set(merged.map(\.id))
        for local in items where !remoteIDs.contains(local.id) && local.addedAt > Date().addingTimeInterval(-120) {
            merged.append(local)
        }
        let sorted = merged.sorted { $0.addedAt > $1.addedAt }
        // Unchanged (most sync passes): no publish, no disk write — each one
        // redrew every watching screen and rewrote the file on the main thread.
        guard sorted != items else { return }
        items = sorted
        save(markDirty: false)
    }

    func mergeFromTracker(_ metas: [(MetaItem, Date)]) {
        var changed = false
        for (m, date) in metas where !contains(m.id) && !removed.contains(m.id) {
            items.append(LibraryItem(meta: m.preview, addedAt: date))
            changed = true
        }
        if changed {
            items.sort { $0.addedAt > $1.addedAt }
            save()
        }
    }
}

/// 1–10 user ratings, per profile.
@MainActor
final class RatingsStore: ObservableObject, ProfileScoped {
    @Published private(set) var ratings: [String: Int] = [:]
    private let baseKey = "ratings.v1"

    init() { reloadForActiveProfile() }

    func reloadForActiveProfile() {
        ratings = Persistence.loadScoped([String: Int].self, base: baseKey, profile: ProfileScope.current) ?? [:]
    }

    func rating(for id: String) -> Int? { ratings[id] }

    func set(_ value: Int?, for id: String) {
        ratings[id] = value
        Persistence.saveScoped(ratings, base: baseKey, profile: ProfileScope.current)
        SyncSignals.markDirty(.profileSettings)
    }

    func applyRemote(_ remote: [String: Int]) {
        guard remote != ratings else { return }
        ratings = remote
        Persistence.saveScoped(ratings, base: baseKey, profile: ProfileScope.current)
    }
}
