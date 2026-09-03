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
    /// Skip Dolby Vision sources when auto-picking. On by default: DV Profile 5
    /// has no compatible base layer, so a source that isn't handled by the
    /// (experimental) native-DV path plays back green/purple — better not to
    /// auto-play one. Turn off to let auto-play choose DV sources.
    var avoidDolbyVision = true

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
        avoidDolbyVision = (try? c.decode(Bool.self, forKey: .avoidDolbyVision)) ?? true
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
        let newID = (1...Self.maxProfiles).first { !used.contains($0) } ?? profiles.count + 1
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

    func delete(id: Int) {
        guard id != 1, profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        onProfileDeleted?(id)
        saveList()
        // Switch away BEFORE purging, so no store still pointed at this profile
        // can write its keys back out after the sweep.
        if activeProfileID == id { setActive(1) }
        purgeProfileData(id: id)
        notifyChange()
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
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
            removed += 1
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

    /// The server is the source of truth for the profile list; replace ours.
    func replaceRemote(_ remote: [UserProfile]) {
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
        profiles = remote.sorted { $0.id < $1.id }.map { p in
            var merged = p
            merged.pinHash = merged.pinHash ?? localHashes[p.id]
            merged.autoLink = merged.autoLink ?? localAutoLink[p.id]
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
