import Foundation

/// The stores the Orivio account syncs. Each has a **persisted dirty flag** per
/// profile that is flushed (pushed) before the matching pull — every pull is a
/// full snapshot, so pulling over an unpushed local change would clobber it.
enum SyncKind: String, CaseIterable {
    case profiles, addons, plugins, library, watchProgress, watched, collections, homeCatalog, profileSettings, providerCredentials

    var isProfileScoped: Bool { self != .profiles }
}

extension Notification.Name {
    static let orivioSyncDirty = Notification.Name("orivio.sync.dirty")
    static let orivioProfileChanged = Notification.Name("orivio.profile.changed")
    static let orivioAddonsChanged = Notification.Name("orivio.addons.changed")
}

enum SyncSignals {
    /// Set while a pull is applying remote state, so stores don't mark
    /// themselves dirty for changes that came *from* the server.
    static var isApplyingRemote = false

    private static func key(_ kind: SyncKind, profile: Int) -> String {
        kind.isProfileScoped ? Persistence.key("sync.dirty.\(kind.rawValue).v1", profile: profile) : Persistence.key("sync.dirty.\(kind.rawValue).v1")
    }

    static func markDirty(_ kind: SyncKind, profile: Int = ProfileScope.current) {
        guard !isApplyingRemote else { return }
        Persistence.set(true, forKey: key(kind, profile: profile))
        NotificationCenter.default.post(name: .orivioSyncDirty, object: nil, userInfo: ["kind": kind.rawValue, "profile": profile])
    }

    static func isDirty(_ kind: SyncKind, profile: Int = ProfileScope.current) -> Bool {
        Persistence.bool(forKey: key(kind, profile: profile))
    }

    static func clearDirty(_ kind: SyncKind, profile: Int = ProfileScope.current) {
        Persistence.set(false, forKey: key(kind, profile: profile))
    }

    /// Runs `body` with dirty-marking suppressed.
    static func applyingRemote(_ body: () -> Void) {
        let was = isApplyingRemote
        isApplyingRemote = true
        body()
        isApplyingRemote = was
    }
}

/// Persisted tombstones: deletions survive until a pull comes back without the id.
struct Tombstones: Codable {
    var ids: [String: Date] = [:]

    mutating func add(_ id: String) { ids[id] = Date() }
    mutating func remove(_ id: String) { ids[id] = nil }
    func contains(_ id: String) -> Bool { ids[id] != nil }

    /// Retire tombstones whose id no longer appears in a fresh pull.
    mutating func retire(absentFrom remote: Set<String>) {
        for id in ids.keys where !remote.contains(id) { ids[id] = nil }
    }
}
