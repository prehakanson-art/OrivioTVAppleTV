import Foundation
import CryptoKit

/// Per-profile "Auto Link Selector": when enabled, pressing Play resolves and
/// plays the best matching source directly (no source list), honoring these
/// preferences. Holding Play still opens the manual picker. Stored on the
/// profile and preserved across account syncs (the shared profile backend has
/// no columns for it, so it's device-local like `pinHash`).
struct AutoLinkPreferences: Codable, Hashable {
    var enabled = false
    /// Preferred addon name; matched first. "" = any addon.
    var preferredAddon = ""
    /// Fallback addon name if the preferred one has no match. "" = none.
    var secondaryAddon = ""
    /// Minimum resolution ("2160p"/"1080p"/"720p"/"480p"), "" = any.
    var minResolution = ""
    /// Largest acceptable file size in GB; 0 = no limit.
    var maxSizeGB = 0.0
    /// Only pick a debrid-cached / instantly-playable source.
    var cachedOnly = false
    /// Skip Dolby Vision sources when auto-picking. OFF by default — the DV
    /// pipeline handles profiles 5/8 (and 7 with conversion) now, so avoiding
    /// DV out of the box just downgraded auto-picks for no reason. The toggle
    /// stays for setups where DV still renders green/purple. Enabling the
    /// selector also resets this to off (see ProfilesView.autoLinkSection).
    var avoidDolbyVision = false

    init() {}

    static func sanitizedMaxSizeGB(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return min(value.rounded(), 60)
    }

    // Tolerant decode so prefs saved before a field existed still load (a
    // missing key falls back to the default instead of failing the whole
    // profile decode).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        preferredAddon = (try? c.decode(String.self, forKey: .preferredAddon)) ?? ""
        secondaryAddon = (try? c.decode(String.self, forKey: .secondaryAddon)) ?? ""
        minResolution = (try? c.decode(String.self, forKey: .minResolution)) ?? ""
        let decodedMaxSize = (try? c.decode(Double.self, forKey: .maxSizeGB)) ?? 0
        maxSizeGB = Self.sanitizedMaxSizeGB(decodedMaxSize)
        cachedOnly = (try? c.decode(Bool.self, forKey: .cachedOnly)) ?? false
        avoidDolbyVision = (try? c.decode(Bool.self, forKey: .avoidDolbyVision)) ?? false
    }
}

/// A viewer profile. `id` is the backend `profile_index`; profile 1 is the
/// primary profile and maps to the app's original (unsuffixed) local storage.
struct UserProfile: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    var avatarColorHex: String
    var usesPrimaryAddons: Bool
    var usesPrimaryPlugins: Bool
    var avatarID: String?
    var avatarURL: String?
    var pinEnabled: Bool
    /// SHA-256 of the PIN, cached on successful set/verify so a locked profile
    /// can still be unlocked offline. Device-local; never synced.
    var pinHash: String?
    /// Auto Link Selector settings. Optional so profiles stored before this
    /// shipped still decode; use `autoLinkPrefs` for a non-optional value.
    var autoLink: AutoLinkPreferences?

    init(
        id: Int, name: String, avatarColorHex: String,
        usesPrimaryAddons: Bool = false, usesPrimaryPlugins: Bool = false,
        avatarID: String? = nil, avatarURL: String? = nil, pinEnabled: Bool = false,
        pinHash: String? = nil, autoLink: AutoLinkPreferences? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarColorHex = avatarColorHex
        self.usesPrimaryAddons = usesPrimaryAddons
        self.usesPrimaryPlugins = usesPrimaryPlugins
        self.avatarID = avatarID
        self.avatarURL = avatarURL
        self.pinEnabled = pinEnabled
        self.pinHash = pinHash
        self.autoLink = autoLink
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, avatarColorHex, usesPrimaryAddons, usesPrimaryPlugins
        case avatarID, avatarURL, pinEnabled, pinHash, autoLink
    }

    /// Tolerant decode, for the same reason `AutoLinkPreferences` has one — but
    /// the stakes here are higher. Synthesized `Codable` over non-optional
    /// fields fails the WHOLE array if one key is missing, and `load()` then
    /// left `profiles` empty, `init` synthesised "Profile 1" and `saveList()`
    /// wrote it straight over the stored blob: one added field would have
    /// silently destroyed every profile on every device. A missing key now
    /// falls back to its default instead. `id` is the one field with no
    /// sensible default (it scopes all of a profile's storage), so its absence
    /// still throws — and `load()` keeps the blob untouched when it does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Profile \(id)"
        // Literal rather than `ProfileStore.avatarColors[0]`: this initializer
        // is nonisolated and that store is @MainActor.
        avatarColorHex = (try? c.decode(String.self, forKey: .avatarColorHex)) ?? "#1E88E5"
        usesPrimaryAddons = (try? c.decode(Bool.self, forKey: .usesPrimaryAddons)) ?? false
        usesPrimaryPlugins = (try? c.decode(Bool.self, forKey: .usesPrimaryPlugins)) ?? false
        avatarID = try? c.decodeIfPresent(String.self, forKey: .avatarID)
        avatarURL = try? c.decodeIfPresent(String.self, forKey: .avatarURL)
        pinEnabled = (try? c.decode(Bool.self, forKey: .pinEnabled)) ?? false
        pinHash = try? c.decodeIfPresent(String.self, forKey: .pinHash)
        autoLink = try? c.decodeIfPresent(AutoLinkPreferences.self, forKey: .autoLink)
    }

    /// First letter shown on the avatar circle.
    var initial: String { String(name.first ?? "?").uppercased() }

    /// Non-optional auto-link settings (defaults when never configured).
    var autoLinkPrefs: AutoLinkPreferences { autoLink ?? AutoLinkPreferences() }
}

/// A selectable avatar image from the backend catalog.
struct AvatarCatalogItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let imageURL: String
    let category: String
    let sortOrder: Int
    let bgColor: String?
}

struct PinVerifyOutcome {
    let unlocked: Bool
    let retryAfterSeconds: Int
    /// Specific failure reason (e.g. sign-in required). Nil = generic
    /// "Incorrect PIN".
    var message: String? = nil
}

enum PinSetOutcome: Equatable {
    case success
    case currentPinRequired
    case failure(String)
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [UserProfile] = []
    @Published private(set) var activeProfileID: Int = 1
    @Published private(set) var avatarCatalog: [AvatarCatalogItem] = []
    /// True while a Orivio account is signed in (set by OrivioSyncManager). The
    /// profile UI uses it to explain why PIN/avatar features are unavailable
    /// instead of failing silently.
    @Published var accountAvailable = false

    /// Fired when the profile list changes locally (add/rename/delete/color).
    var onLocalChange: (() -> Void)?
    /// Fired when the active profile changes, so data stores can re-scope.
    var onSwitch: ((Int) -> Void)?

    /// Authed backend operations, wired by OrivioSyncManager (which holds the
    /// access token). Nil when the sync layer hasn't been created yet.
    var avatarCatalogLoader: (() async -> [AvatarCatalogItem])?
    var pinVerifier: ((Int, String) async -> PinVerifyOutcome)?
    var pinSetter: ((Int, String, String?) async -> PinSetOutcome)?
    var pinClearer: ((Int, String?) async -> Bool)?

    private var suppressChange = false

    static let maxProfiles = 5
    static let avatarColors = [
        "#1E88E5", "#E53935", "#8E24AA", "#43A047", "#FB8C00", "#D81B60", "#00ACC1"
    ]

    private static let listKey = "orivio.profiles.v1"
    private static let activeKey = "orivio.profiles.active"

    init() {
        load()
        deletedProfileIDs = Set(UserDefaults.standard.array(forKey: Self.deletedKey) as? [Int] ?? [])
        // A tombstone for a profile that is somehow still in the local list
        // (a partially applied delete) is stale: the list is the user's view.
        deletedProfileIDs.subtract(profiles.map(\.id))
        if profiles.isEmpty {
            profiles = [UserProfile(id: 1, name: "Profile 1", avatarColorHex: Self.avatarColors[0])]
            // Persist the synthesised default ONLY when there was nothing
            // readable to lose. If a stored blob exists but failed to decode,
            // writing this over it destroys every profile the user had (see
            // `listBlobUnreadable`) — run on the default in memory instead.
            if !listBlobUnreadable { saveList() }
        }
        activeProfileID = UserDefaults.standard.object(forKey: Self.activeKey) as? Int ?? 1
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles.first?.id ?? 1
            // Persist the correction: every other store reads the raw key at
            // its own init, so an in-memory-only fix left the UI on one
            // profile while progress/library/ratings read and wrote another's.
            // NEVER when the profile LIST failed to decode: the synthesised
            // "Profile 1" would then make every real id fail this test and a
            // device on profile 3 would be reset to 1 for good.
            if !listBlobUnreadable {
                UserDefaults.standard.set(activeProfileID, forKey: Self.activeKey)
            }
        }
    }

    var active: UserProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
            ?? UserProfile(id: 1, name: "Profile 1", avatarColorHex: Self.avatarColors[0])
    }

    var canAddProfile: Bool { profiles.count < Self.maxProfiles }

    // MARK: - Mutations

    @discardableResult
    func addProfile(name: String) -> UserProfile? {
        guard canAddProfile else { return nil }
        let used = Set(profiles.map { $0.id })
        // Never hand out an id whose deletion the account has not confirmed
        // yet. The new profile would be filtered out of the next pull as
        // "deleted"; worse, an in-flight `sync_delete_profile_data` for that
        // id would wipe the NEW profile's server data, and an undrained one
        // would be dropped so the old profile's rows are never deleted at all
        // — the next pull then adopts them into the new profile, which is how
        // a fresh "Guest" opened onto the deleted "Kids" profile's Continue
        // Watching, library and history.
        //
        // Refusing the add is the safe answer: the deletion drains on the next
        // sync (seconds), and the caller already handles nil by telling the
        // user it couldn't add a profile.
        let free = (1...Self.maxProfiles).filter { !used.contains($0) && !deletedProfileIDs.contains($0) }
        guard let newID = free.first else {
            NSLog("[OrivioProfiles] add refused — every free slot has an unconfirmed deletion pending")
            return nil
        }
        let color = Self.avatarColors[(newID - 1) % Self.avatarColors.count]
        let profile = UserProfile(
            id: newID,
            name: name.isEmpty ? "Profile \(newID)" : name,
            avatarColorHex: color
        )
        profiles.append(profile)
        saveList()
        notifyChange()
        return profile
    }

    func rename(id: Int, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        profiles[idx].name = name
        saveList()
        notifyChange()
    }

    func setColor(id: Int, hex: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].avatarColorHex = hex
        saveList()
        notifyChange()
    }

    /// Deletes a profile. Profile 1 (primary) can't be removed; deleting the
    /// active profile switches back to profile 1.
    /// Fired when a profile is deleted, so per-profile state elsewhere (the
    /// Trakt account, for one) can be dropped rather than inherited by the next
    /// profile to reuse that id.
    var onProfileDeleted: ((Int) -> Void)?

    /// Profiles deleted on this device whose deletion the account has not
    /// confirmed yet. `replaceRemote` filters them out of any list the server
    /// hands back in the meantime.
    ///
    /// Deleting a profile used to bring it straight back. Two races, both real:
    ///
    /// * `delete` switched away from the deleted profile BEFORE arming the
    ///   push, and the switch itself starts a full sync — which pulls the
    ///   profile list first and calls `replaceRemote` with a server copy that
    ///   still contains the row. Ordering alone fixes that one (see below).
    /// * Even in the right order, the push is DEBOUNCED by more than a second.
    ///   Any pull that lands inside that window — the 30s tick, a foreground
    ///   resume, a sync a different local change kicked off — restores the row
    ///   from the server just as surely.
    ///
    /// So the delete is remembered as a tombstone until the server has
    /// actually let go of the id, and only then is it allowed to speak for
    /// that id again.
    ///
    /// PERSISTED. It used to be in-memory on the theory that a relaunch meant
    /// the push had either landed or the profile legitimately still existed —
    /// but the push RPC never deletes anything (it upserts the rows it is
    /// given), so the profile ALWAYS still existed server-side, and the first
    /// pull after a relaunch put it straight back. The deletion itself now
    /// goes through `sync_delete_profile_data` (the same RPC the Android app
    /// uses), which the sync manager drains from this set until a pull comes
    /// back without the id.
    private(set) var deletedProfileIDs: Set<Int> = [] {
        didSet {
            guard deletedProfileIDs != oldValue else { return }
            if deletedProfileIDs.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.deletedKey)
            } else {
                UserDefaults.standard.set(Array(deletedProfileIDs).sorted(), forKey: Self.deletedKey)
            }
        }
    }
    private static let deletedKey = "orivio.profiles.deleted.v1"

    /// A server list just arrived. Any tombstoned id that is NOT in it has
    /// been accepted by the account, so the tombstone can go.
    ///
    /// Deliberately keyed on the PULL, not on the delete RPC returning 200 —
    /// a pull that no longer mentions the id is proof; nothing else is.
    func confirmProfileDeletions(remoteIDs: Set<Int>) {
        // Keep only the tombstones the server STILL reports — those are the
        // deletions it hasn't accepted yet. The rest are done.
        deletedProfileIDs.formIntersection(remoteIDs)
    }

    /// Forget every pending deletion — a DIFFERENT account signed in, and its
    /// profiles must not be suppressed (or deleted) on the previous user's say.
    func forgetProfileDeletions() {
        deletedProfileIDs = []
    }

    func delete(id: Int) {
        guard id != 1, profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        deletedProfileIDs.insert(id)
        onProfileDeleted?(id)
        saveList()
        // Arm the push BEFORE switching away. `setActive` runs the account's
        // profile-switch handler, which starts a full sync — and a full sync
        // only flushes the profile list when it has been told the list is
        // dirty. Notifying afterwards meant the sync the delete itself
        // triggered ran with `profilesDirty` still false: it pulled the
        // server's list, `replaceRemote` put the profile back, and the push
        // that followed 1.2s later uploaded the restored list.
        notifyChange()
        // Switch away BEFORE purging, so no store still pointed at this profile
        // can write its keys back out after the sweep.
        if activeProfileID == id { setActive(1) }
        purgeProfileData(id: id)
    }

    /// Retire every per-profile key belonging to a deleted profile.
    ///
    /// Each per-profile store namespaces its storage with a `.p<id>` suffix
    /// (profile 1 keeps the original unsuffixed key, and cannot be deleted), so
    /// one sweep covers all of it: watch progress, library, watched history,
    /// collection visibility, home layout, ratings, that profile's Trakt login
    /// and the account-sync bookkeeping.
    ///
    /// Without this the data outlived the profile while `addProfile` hands out
    /// the LOWEST free id — so the next profile created inherited the deleted
    /// one's Continue Watching, library and watch history.
    private func purgeProfileData(id: Int) {
        guard id != 1 else { return }
        let suffix = ".p\(id)"
        let defaults = UserDefaults.standard
        var removed = 0
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasSuffix(suffix) {
                defaults.removeObject(forKey: key)
                removed += 1
            } else if key.hasPrefix("orivio.sync.dirty.") {
                // The per-profile dirty flags live under an UNSCOPED key as an
                // array of profile ids, so the `.p<id>` sweep above misses them.
                // Left behind, a later profile that reuses this id inherits a
                // spurious "unpushed changes" mark.
                var ids = defaults.array(forKey: key) as? [Int] ?? []
                if let idx = ids.firstIndex(of: id) {
                    ids.remove(at: idx)
                    if ids.isEmpty { defaults.removeObject(forKey: key) }
                    else { defaults.set(ids, forKey: key) }
                    removed += 1
                }
            }
        }
        NSLog("[OrivioProfiles] deleted profile %d — retired %d stored keys", id, removed)
    }

    /// A second switch hook, for state that must rescope even when signed out
    /// of the account (the sync manager's `onSwitch` only runs while signed in).
    var onSwitchLocal: ((Int) -> Void)?

    func setActive(_ id: Int) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard id != activeProfileID else { return }
        activeProfileID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
        onSwitchLocal?(id)
        onSwitch?(id)
    }

    /// Called after a profile's PIN is switched on or off, so the Top Shelf
    /// can drop (or resume showing) that profile's Continue Watching. Set by
    /// the app; nil in tests and previews.
    var onProfileLockChanged: (() -> Void)?

    func setPinEnabled(id: Int, _ enabled: Bool) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].pinEnabled = enabled
        saveList()
        // Only the ACTIVE profile's data is on the shelf, but firing
        // unconditionally is both cheaper and safer than deciding here — the
        // exporter re-reads which profile is active anyway.
        onProfileLockChanged?()
    }

    func setAvatar(id: Int, avatarID: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].avatarID = avatarID
        saveList()
        notifyChange()
    }

    /// The active profile's Auto Link Selector settings (defaults if unset).
    var activeAutoLink: AutoLinkPreferences { active.autoLinkPrefs }

    func setAutoLink(id: Int, _ prefs: AutoLinkPreferences) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        var sanitized = prefs
        sanitized.maxSizeGB = AutoLinkPreferences.sanitizedMaxSizeGB(sanitized.maxSizeGB)
        profiles[idx].autoLink = sanitized
        saveList()
        notifyChange()
    }

    /// Resolves a profile's avatar image URL from the catalog (or its stored URL).
    func avatarURL(for profile: UserProfile) -> String? {
        if let direct = profile.avatarURL, !direct.isEmpty { return direct }
        guard let avatarID = profile.avatarID else { return nil }
        return avatarCatalog.first { $0.id == avatarID }?.imageURL
    }

    // MARK: - Authed operations (delegated to the sync layer)

    func loadAvatarCatalog() async {
        guard avatarCatalog.isEmpty, let loader = avatarCatalogLoader else { return }
        let items = await loader()
        if !items.isEmpty { avatarCatalog = items.sorted { $0.sortOrder < $1.sortOrder } }
    }

    func verifyPin(id: Int, pin: String) async -> PinVerifyOutcome {
        // Local hash first: instant, and keeps locked profiles usable offline.
        if let hash = profiles.first(where: { $0.id == id })?.pinHash,
           Self.hashPin(pin) == hash {
            return PinVerifyOutcome(unlocked: true, retryAfterSeconds: 0)
        }
        // Server verify covers PINs set on another device (and rate limits).
        if accountAvailable, let verifier = pinVerifier {
            let outcome = await verifier(id, pin)
            if outcome.unlocked { cachePinHash(id: id, pin: pin) }
            return outcome
        }
        // Signed out with no matching local hash: if we've never seen this PIN
        // on this device, say why instead of a misleading "Incorrect PIN".
        let hasLocalHash = profiles.first(where: { $0.id == id })?.pinHash != nil
        return PinVerifyOutcome(
            unlocked: false, retryAfterSeconds: 0,
            message: hasLocalHash ? nil : "Sign in to Orivio to verify this PIN."
        )
    }

    func setPin(id: Int, pin: String, currentPin: String?) async -> PinSetOutcome {
        guard accountAvailable, let setter = pinSetter else {
            return .failure("Sign in to Orivio to set a PIN.")
        }
        let outcome = await setter(id, pin, currentPin)
        if outcome == .success {
            setPinEnabled(id: id, true)
            cachePinHash(id: id, pin: pin)
        }
        return outcome
    }

    func clearPin(id: Int, currentPin: String?) async -> Bool {
        guard let clearer = pinClearer else { return false }
        let ok = await clearer(id, currentPin)
        if ok {
            setPinEnabled(id: id, false)
            cachePinHash(id: id, pin: nil)
        }
        return ok
    }

    private func cachePinHash(id: Int, pin: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].pinHash = pin.map(Self.hashPin)
        saveList()
    }

    private static func hashPin(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sync bridge

    func allForSync() -> [UserProfile] { profiles }

    /// The server is the source of truth for the profile list; replace ours —
    /// EXCEPT for profiles this device has just deleted and not yet pushed
    /// (see `deletedProfileIDs`), which the server hasn't been told about.
    func replaceRemote(_ remote: [UserProfile]) {
        let remote = remote.filter { !deletedProfileIDs.contains($0.id) }
        guard !remote.isEmpty else { return }
        suppressChange = true
        defer { suppressChange = false }
        // Remote payloads never carry the device-local PIN hash or the Auto Link
        // Selector prefs (no backend columns) — carry them over so offline
        // unlock and each profile's auto-link config survive a sync.
        // uniquingKeysWith, not uniqueKeysWithValues: a duplicate profile id in
        // the list (a malformed local save, or a server that hands back two rows
        // with the same id) used to TRAP here and take the app down mid-sync.
        // First one wins — the list is already in stable id order.
        let localHashes = Dictionary(profiles.compactMap { p in
            p.pinHash.map { (p.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let localAutoLink = Dictionary(profiles.compactMap { p in
            p.autoLink.map { (p.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        // The pull RPC has no `pinEnabled` column, so every row arrives false
        // and the REAL value only lands in the separate `pull_profile_locks`
        // call, which is best-effort (`try?`). Carrying the local lock state
        // forward — exactly like the hash — stops a failed or slow locks call
        // from silently UNLOCKING a protected profile. `applyLockStates` still
        // overwrites it once the authoritative answer arrives.
        let localPinEnabled = Dictionary(profiles.map { ($0.id, $0.pinEnabled) },
                                         uniquingKeysWith: { first, _ in first })
        profiles = remote.sorted { $0.id < $1.id }.map { p in
            var merged = p
            merged.pinHash = merged.pinHash ?? localHashes[p.id]
            merged.autoLink = merged.autoLink ?? localAutoLink[p.id]
            merged.pinEnabled = localPinEnabled[p.id] ?? merged.pinEnabled
            return merged
        }
        saveList()
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            setActive(profiles.first?.id ?? 1)
        }
    }

    func applyLockStates(_ states: [Int: Bool]) {
        for (index, enabled) in states {
            if let i = profiles.firstIndex(where: { $0.id == index }) {
                profiles[i].pinEnabled = enabled
            }
        }
        saveList()
    }

    // MARK: - Persistence

    private func notifyChange() {
        if !suppressChange { onLocalChange?() }
    }

    /// Set when a stored profile blob EXISTS but could not be decoded. `load()`
    /// used to just return, leaving `profiles` empty, whereupon `init`
    /// synthesised "Profile 1" and `saveList()` wrote it straight over the
    /// undecodable bytes — turning a recoverable decode bug into PERMANENT loss
    /// of every profile (and, since a profile id scopes its progress/library
    /// storage, of everything reachable through them). The synthesised default
    /// is now kept in memory only, so a later build can still read the bytes.
    /// A deliberate mutation afterwards (the user adding/renaming a profile, or
    /// a server list arriving) is real new state and does overwrite.
    private(set) var listBlobUnreadable = false

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.listKey) else { return }
        guard let decoded = try? JSONDecoder().decode([UserProfile].self, from: data) else {
            listBlobUnreadable = true
            return
        }
        listBlobUnreadable = false
        profiles = decoded
    }

    private func saveList() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
        listBlobUnreadable = false
    }
}

// MARK: - Per-profile UserDefaults scoping

/// The one rule upstream Nuvio's whole profile system reduces to: every
/// PERSONAL store's persistence container is suffixed per profile, and the
/// bare (legacy) name is what the PRIMARY profile inherits. AddonManager
/// introduced the pattern on tvOS; this helper is that pattern extracted so
/// the other personal stores (plugins, debrid, player, TMDB, theme, badges)
/// scope identically.
///
/// The legacy fallback applies to PROFILE 1 ALONE — the exact semantics of
/// the Trakt pane's per-profile switch: splitting hands the existing
/// device-wide state (logins included) to the primary profile, and every
/// other profile starts FRESH, able to connect its own accounts and shape
/// its own setup. Seeding every profile from the legacy value looked kinder
/// but meant profile 2 opened TMDB/debrid settings onto profile 1's login,
/// which is precisely what the split promises not to do.
///
/// Reads fall back only when the scoped key is ABSENT. Stores where "empty"
/// is a legitimate user state must therefore WRITE an empty marker (empty
/// string/data/array) on removal rather than deleting the scoped key —
/// deletion would resurrect the legacy value for the primary profile.
enum ProfileScopedDefaults {
    /// Same key ProfileStore writes; read directly so stores are scoped
    /// correctly from launch, before any manager wires them up.
    static var activeProfileID: Int {
        UserDefaults.standard.object(forKey: "orivio.profiles.active") as? Int ?? 1
    }

    static func key(_ base: String, _ profile: Int) -> String { "\(base).p\(profile)" }

    // MARK: Separate vs shared

    /// Each split store can be flipped between SEPARATE per-profile state and
    /// ONE shared device-wide copy — the same choice the Trakt pane's
    /// "Separate Trakt per profile" switch offers, generalized. Defaults ON
    /// (separate): that's the behaviour the split shipped with. Shared mode
    /// reads and writes the bare legacy keys, so turning a switch off always
    /// falls straight back to the device-wide copy — and turning it back on
    /// finds each profile's own state (or the seed) exactly where it was.
    static func isSeparate(_ feature: String) -> Bool {
        (UserDefaults.standard.object(forKey: separateFlagKey(feature)) as? Bool) ?? true
    }

    static func setSeparate(_ feature: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: separateFlagKey(feature))
    }

    private static func separateFlagKey(_ feature: String) -> String {
        "orivio.perProfile.\(feature).v1"
    }

    /// The key WRITES go to under the feature's current mode.
    static func writeKey(_ base: String, feature: String, _ profile: Int) -> String {
        isSeparate(feature) ? key(base, profile) : base
    }

    /// Mode-aware reads: separate → scoped with the legacy seed fallback;
    /// shared → the legacy key alone.
    static func data(_ base: String, feature: String, _ profile: Int) -> Data? {
        isSeparate(feature) ? data(base, profile) : UserDefaults.standard.data(forKey: base)
    }

    static func string(_ base: String, feature: String, _ profile: Int) -> String? {
        isSeparate(feature) ? string(base, profile) : UserDefaults.standard.string(forKey: base)
    }

    static func bool(_ base: String, feature: String, _ profile: Int, default def: Bool = false) -> Bool {
        isSeparate(feature) ? bool(base, profile, default: def)
            : (UserDefaults.standard.object(forKey: base) as? Bool) ?? def
    }

    static func data(_ base: String, _ profile: Int) -> Data? {
        if let scoped = UserDefaults.standard.data(forKey: key(base, profile)) {
            // De-pollution, same as TraktStore's adopt cleanup: while every
            // profile briefly seeded from the legacy value, incidental
            // echo-writes (TMDB's enabled-flip on init, theme didSets on a
            // switch, the hourly manifest refresh) persisted BYTE-IDENTICAL
            // copies of the primary's state into other profiles' slots — so
            // profile 2 opened TMDB onto profile 1's login. A copy that still
            // exactly equals the legacy blob was never this profile's own;
            // drop it once and start fresh. State a profile actually touched
            // differs and is left alone.
            // ONE-SHOT per key+profile. As a standing rule this ran on every
            // read forever, so a profile that deliberately chose the same
            // settings as profile 1 (identical bytes out of a deterministic
            // encoder) had its choice silently wiped on the next read. The
            // pollution being cleaned was seeded HISTORICALLY — one sweep per
            // slot is the whole job.
            let sweepKey = "orivio.profiles.depolluted." + key(base, profile)
            if profile != 1, !UserDefaults.standard.bool(forKey: sweepKey) {
                UserDefaults.standard.set(true, forKey: sweepKey)
                if scoped == UserDefaults.standard.data(forKey: base) {
                    UserDefaults.standard.removeObject(forKey: key(base, profile))
                    return nil
                }
            }
            return scoped
        }
        return profile == 1 ? UserDefaults.standard.data(forKey: base) : nil
    }

    static func string(_ base: String, _ profile: Int) -> String? {
        if let scoped = UserDefaults.standard.string(forKey: key(base, profile)) { return scoped }
        return profile == 1 ? UserDefaults.standard.string(forKey: base) : nil
    }

    static func bool(_ base: String, _ profile: Int, default def: Bool = false) -> Bool {
        if let scoped = UserDefaults.standard.object(forKey: key(base, profile)) as? Bool { return scoped }
        if profile == 1, let legacy = UserDefaults.standard.object(forKey: base) as? Bool { return legacy }
        return def
    }

    /// Remove one profile's scoped copies (profile deletion).
    static func forget(_ bases: [String], profile: Int) {
        for base in bases { UserDefaults.standard.removeObject(forKey: key(base, profile)) }
    }

    /// Remove EVERY profile's scoped copies plus the legacy seed (account
    /// switch, for credential-bearing stores).
    static func forgetAll(_ bases: [String]) {
        for base in bases {
            UserDefaults.standard.removeObject(forKey: base)
            for id in 1...ProfileStore.maxProfiles {
                UserDefaults.standard.removeObject(forKey: key(base, id))
            }
        }
    }
}
