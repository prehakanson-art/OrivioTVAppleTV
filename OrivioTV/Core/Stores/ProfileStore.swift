import Foundation
import CryptoKit
import SwiftUI

/// Per-profile Auto Link Selector (§8.1). Device-local, never synced.
struct AutoLinkPrefs: Codable, Equatable {
    var enabled = false
    var preferredAddon: String?
    var secondaryAddon: String?
    var minimumQuality: String?          // "2160p" / "1080p" / "720p" / nil = any
    var maximumSizeGB: Double?           // ≤ 60
    var cachedOnly = false
    var avoidDolbyVision = false
}

struct Profile: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var avatarColorHex: String
    var avatarID: String?
    var avatarURL: String?
    var pinEnabled = false
    /// Device-local, never synced (backend has no column).
    var pinHash: String?
    /// Device-local, never synced.
    var autoLink = AutoLinkPrefs()
    var usesPrimaryAddons = false
    var usesPrimaryPlugins = false
    /// Which collections/folders this profile sees (ids hidden).
    var hiddenCollections: [String] = []
    var hiddenFolders: [String] = []

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var color: Color { Color(hex: avatarColorHex) ?? .blue }

    static let palette = ["#E5484D", "#F76B15", "#FFC53D", "#46A758", "#12A594", "#0090FF", "#3E63DD", "#8E4EC6", "#D6409F", "#8D8D8D"]
}

final class ProfileStore: ObservableObject {
    /// The account accepts at most this many profiles (matches Android).
    static let maxProfiles = 5
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeID: Int = ProfileScope.current
    private(set) var deleted = Tombstones()

    private let profilesKey = Persistence.key("profiles.v1")
    private let deletedKey = Persistence.key("profiles.deleted.v1")
    private let activeKey = Persistence.key("profiles.active")

    /// Called after the active profile switches so every per-profile store reloads.
    var onActiveProfileChanged: (() -> Void)?

    init() {
        profiles = Persistence.load([Profile].self, key: profilesKey) ?? []
        deleted = Persistence.load(Tombstones.self, key: deletedKey) ?? Tombstones()
        if profiles.isEmpty {
            profiles = [Profile(id: 1, name: "Me", avatarColorHex: Profile.palette[5])]
            save(markDirty: false)
        }
        if !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles[0].id
            ProfileScope.current = activeID
        }
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }

    /// The gate shows at launch with ≥ 2 profiles or a PIN on the active one.
    var needsGateAtLaunch: Bool { profiles.count >= 2 || active.pinEnabled }

    func profile(_ id: Int) -> Profile? { profiles.first { $0.id == id } }

    private func save(markDirty: Bool = true) {
        Persistence.save(profiles, key: profilesKey, compressed: false)
        Persistence.save(deleted, key: deletedKey, compressed: false)
        if markDirty { SyncSignals.markDirty(.profiles) }
    }

    func switchTo(_ id: Int) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let changed = id != activeID
        activeID = id
        ProfileScope.current = id
        Persistence.set(id, forKey: activeKey)
        if changed {
            onActiveProfileChanged?()
            NotificationCenter.default.post(name: .orivioProfileChanged, object: nil)
        }
    }

    @discardableResult
    func add(name: String, colorHex: String? = nil) -> Profile {
        let id = (profiles.map(\.id).max() ?? 0) + 1
        let color = colorHex ?? Profile.palette[(id - 1) % Profile.palette.count]
        let p = Profile(id: id, name: name.isEmpty ? "Profile \(id)" : name, avatarColorHex: color)
        profiles.append(p)
        deleted.remove(String(id))
        save()
        return p
    }

    func update(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let old = profiles[i]
        profiles[i] = profile
        // PIN hash and Auto Link prefs are device-local: don't mark sync dirty for them alone.
        var a = old, b = profile
        a.pinHash = nil; b.pinHash = nil; a.autoLink = AutoLinkPrefs(); b.autoLink = AutoLinkPrefs()
        save(markDirty: a != b)
    }

    func delete(_ id: Int) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: i)
        deleted.add(String(id))
        save()
        if activeID == id { switchTo(profiles[0].id) }
    }

    // MARK: PIN

    static func hashPIN(_ pin: String, profileID: Int) -> String {
        let digest = SHA256.hash(data: Data("orivio-pin-\(profileID)-\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func setPIN(_ pin: String?, for id: Int) {
        guard var p = profile(id) else { return }
        // Server-side too, so other devices see the lock.
        Task { @MainActor in OrivioSync.shared.pushPIN(pin, profile: id) }
        if let pin {
            p.pinHash = Self.hashPIN(pin, profileID: id)
            p.pinEnabled = true
        } else {
            p.pinHash = nil
            p.pinEnabled = false
        }
        update(p)
    }

    func verifyPIN(_ pin: String, for id: Int) -> Bool {
        guard let p = profile(id) else { return false }
        guard p.pinEnabled else { return true }
        // A PIN set on another device has no local hash; accept and adopt the first entry.
        guard let hash = p.pinHash else {
            setPIN(pin, for: id)
            return true
        }
        return hash == Self.hashPIN(pin, profileID: id)
    }

    // MARK: Sync

    /// Applies a remote snapshot, keeping device-local fields and honouring tombstones.
    func applyRemote(_ remote: [Profile]) {
        let remoteIDs = Set(remote.map { String($0.id) })
        deleted.retire(absentFrom: remoteIDs)
        var merged: [Profile] = []
        for var r in remote where !deleted.contains(String(r.id)) {
            if let local = profile(r.id) {
                r.pinHash = local.pinHash
                r.autoLink = local.autoLink
                r.hiddenCollections = r.hiddenCollections.isEmpty ? local.hiddenCollections : r.hiddenCollections
                r.hiddenFolders = r.hiddenFolders.isEmpty ? local.hiddenFolders : r.hiddenFolders
            }
            merged.append(r)
        }
        guard !merged.isEmpty else { return }
        let sorted = merged.sorted { $0.id < $1.id }
        // Unchanged (most sync passes): no publish, no disk write — each one
        // redrew every watching screen and rewrote the file on the main thread.
        guard sorted != profiles else { return }
        profiles = sorted
        save(markDirty: false)
        if !profiles.contains(where: { $0.id == activeID }) { switchTo(profiles[0].id) }
    }

    func applyRemoteLocks(_ locks: [Int: Bool]) {
        var changed = false
        for (id, locked) in locks {
            guard let i = profiles.firstIndex(where: { $0.id == id }), profiles[i].pinEnabled != locked else { continue }
            profiles[i].pinEnabled = locked
            if !locked { profiles[i].pinHash = nil }
            changed = true
        }
        if changed { save(markDirty: false) }
    }
}
