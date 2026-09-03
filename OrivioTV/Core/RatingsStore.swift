import Foundation

/// Personal 1–10 star ratings per title (movie/show), keyed by metaID. Local,
/// synced two-way with Trakt (Orivio's account backend has no ratings table).
@MainActor
final class RatingsStore: ObservableObject {
    /// metaID → rating (1…10). Also carries the type so a push can pick the
    /// right Trakt bucket.
    @Published private(set) var ratings: [String: Int] = [:]
    private var types: [String: String] = [:]

    /// Fired on a genuine local rate/unrate so every tracking service can
    /// push. Lists, not single closures — see the note in WatchedStore.
    var onTrackerRate: [(_ metaID: String, _ type: String, _ rating: Int) -> Void] = []
    var onTrackerUnrate: [(_ metaID: String, _ type: String) -> Void] = []
    private var suppressChange = false

    /// Active profile scope. Profile 1 keeps the original (unsuffixed) key so
    /// existing ratings survive this change; other profiles get a namespace.
    ///
    /// Ratings used to be device-wide while Trakt sign-in can be PER-PROFILE, so
    /// a sync pulled profile A's Trakt ratings into the shared store and then
    /// pushed them into profile B's different Trakt account.
    private static let baseKey = "orivio.ratings.v1"
    /// Same key ProfileStore uses, read directly so the scope is right from
    /// LAUNCH. `setProfile` is only called from `ProfileStore.onSwitchLocal`,
    /// which fires on `setActive` — and `setActive` never runs at launch (the
    /// active id is restored straight from defaults, and it early-returns when
    /// the id is unchanged). Without this a device whose active profile is 3
    /// booted holding profile 1's ratings and pushed them to profile 3's Trakt
    /// account: exactly the leak the scoping was added to stop. TraktStore
    /// solves it the same way.
    private static let activeProfileKey = "orivio.profiles.active"
    private var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1
    private var storageKey: String {
        profileID == 1 ? Self.baseKey : "\(Self.baseKey).p\(profileID)"
    }

    init() { load() }

    /// Switch to another profile's ratings. The current profile is already
    /// persisted, so just re-point storage and reload.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        suppressChange = true
        ratings = [:]
        types = [:]
        load()
        suppressChange = false
    }

    func rating(for metaID: String) -> Int? { ratings[metaID] }

    /// Set (1…10) or clear (nil/0) the rating for a title.
    func setRating(_ value: Int?, for metaID: String, type: String) {
        if let value, (1...10).contains(value) {
            ratings[metaID] = value
            types[metaID] = type
            save()
            if !suppressChange { for hook in onTrackerRate { hook(metaID, type, value) } }
        } else {
            ratings.removeValue(forKey: metaID)
            let t = types.removeValue(forKey: metaID) ?? type
            save()
            if !suppressChange { for hook in onTrackerUnrate { hook(metaID, t) } }
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        ratings = p.ratings
        types = p.types
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Persisted(ratings: ratings, types: types)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
