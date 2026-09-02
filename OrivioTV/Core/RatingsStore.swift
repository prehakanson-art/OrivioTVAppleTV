import Foundation

/// Personal 1–10 star ratings per title (movie/show), keyed by metaID. Local,
/// synced two-way with Trakt (Orivio's account backend has no ratings table).
@MainActor
final class RatingsStore: ObservableObject {
    /// metaID → rating (1…10). Also carries the type so a push can pick the
    /// right Trakt bucket.
    @Published private(set) var ratings: [String: Int] = [:]
    private var types: [String: String] = [:]

    /// Fired on a genuine local rate/unrate so the Trakt manager can push.
    var onTraktRate: ((_ metaID: String, _ type: String, _ rating: Int) -> Void)?
    var onTraktUnrate: ((_ metaID: String, _ type: String) -> Void)?
    private var suppressChange = false

    private static let key = "orivio.ratings.v1"

    init() { load() }

    func rating(for metaID: String) -> Int? { ratings[metaID] }

    /// Set (1…10) or clear (nil/0) the rating for a title.
    func setRating(_ value: Int?, for metaID: String, type: String) {
        if let value, (1...10).contains(value) {
            ratings[metaID] = value
            types[metaID] = type
            save()
            if !suppressChange { onTraktRate?(metaID, type, value) }
        } else {
            ratings.removeValue(forKey: metaID)
            let t = types.removeValue(forKey: metaID) ?? type
            save()
            if !suppressChange { onTraktUnrate?(metaID, t) }
        }
    }

    func type(for metaID: String) -> String { types[metaID] ?? "movie" }

    /// Apply ratings pulled from Trakt without echoing back (additive: adds a
    /// rating only where none exists locally).
    func mergeRemote(_ remote: [(metaID: String, type: String, rating: Int)]) {
        suppressChange = true
        defer { suppressChange = false }
        var changed = false
        for r in remote where ratings[r.metaID] == nil {
            ratings[r.metaID] = r.rating
            types[r.metaID] = r.type
            changed = true
        }
        if changed { save() }
    }

    func allForSync() -> [(metaID: String, type: String, rating: Int)] {
        ratings.map { ($0.key, types[$0.key] ?? "movie", $0.value) }
    }

    // MARK: - Persistence

    private struct Persisted: Codable { var ratings: [String: Int]; var types: [String: String] }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        ratings = p.ratings
        types = p.types
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(ratings: ratings, types: types)) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
