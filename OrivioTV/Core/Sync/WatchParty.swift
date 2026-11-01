import Foundation

// MARK: - Wire models (Android's `com.nuvio.tv.core.party`)

/// What is being watched. Field names are the server's; `key` is how a party
/// decides two devices are on the same title/episode.
struct PartySource: Codable, Equatable {
    var infoHash: String?
    var fileIdx: Int?
    var filename: String?
    var videoSize: Int64?
    var bingeGroup: String?
    var addonId: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case infoHash = "info_hash"
        case fileIdx = "file_idx"
        case filename
        case videoSize = "video_size"
        case bingeGroup = "binge_group"
        case addonId = "addon_id"
        case name
    }
}

struct PartyMedia: Codable, Equatable {
    var type: String
    var metaId: String
    var metaType: String
    var videoId: String?
    var season: Int?
    var episode: Int?
    var title: String
    var episodeTitle: String?
    var description: String?
    var poster: String?
    var background: String?
    var logo: String?
    var source: PartySource?

    var key: String {
        [metaType.lowercased(), metaId, season.map(String.init) ?? "", episode.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case type
        case metaId = "meta_id"
        case metaType = "meta_type"
        case videoId = "video_id"
        case season
        case episode
        case title
        case episodeTitle = "episode_title"
        case description
        case poster
        case background
        case logo
        case source
    }
}

struct PartyPlayback: Codable, Equatable {
    var seq: Int64
    var memberId: String?
    var paused: Bool
    var positionMs: Int64
    var rate: Float
    /// Server clock, milliseconds. `positionMs` is where the film was at `at`.
    var at: Int64
    var mediaKey: String?
    var waiting: Bool

    init(seq: Int64, memberId: String?, paused: Bool, positionMs: Int64,
         rate: Float, at: Int64, mediaKey: String?, waiting: Bool = false) {
        self.seq = seq
        self.memberId = memberId
        self.paused = paused
        self.positionMs = positionMs
        self.rate = rate
        self.at = at
        self.mediaKey = mediaKey
        self.waiting = waiting
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case memberId = "member_id"
        case paused
        case positionMs = "position_ms"
        case rate
        case at
        case mediaKey = "media_key"
        case waiting
    }
}

struct PartyMember: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var avatarUrl: String?
    var avatarColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case avatarColor = "avatar_color"
    }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

struct PartyInfo: Codable, Equatable {
    var id: String
    var code: String
    var hostMemberId: String?
    var hostOnly: Bool
    var media: PartyMedia
    var playback: PartyPlayback?
    var maxMembers: Int

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case hostMemberId = "host_member_id"
        case hostOnly = "host_only"
        case media
        case playback
        case maxMembers = "max_members"
    }
}

struct PartySnapshot: Codable {
    var party: PartyInfo?
    var members: [PartyMember]
    var memberId: String?
    var serverTimeMs: Int64?
    var error: String?
    var ok: Bool?

    init(party: PartyInfo? = nil, members: [PartyMember] = [], memberId: String? = nil,
         serverTimeMs: Int64? = nil, error: String? = nil, ok: Bool? = nil) {
        self.party = party
        self.members = members
        self.memberId = memberId
        self.serverTimeMs = serverTimeMs
        self.error = error
        self.ok = ok
    }

    enum CodingKeys: String, CodingKey {
        case party
        case members
        case memberId = "member_id"
        case serverTimeMs = "server_time_ms"
        case error
        case ok
    }
}

struct PartyPreview: Codable {
    var media: PartyMedia?
    var host: PartyMember?
    var members: Int
    var maxMembers: Int
    var error: String?

    enum CodingKeys: String, CodingKey {
        case media
        case host
        case members
        case maxMembers = "max_members"
        case error
    }
}

/// The party this device is in, flattened from the last snapshot.
struct ActiveParty: Equatable {
    var id: String
    var code: String
    var memberId: String
    var hostMemberId: String?
    var members: [PartyMember]
    var media: PartyMedia
    var maxMembers: Int
    var hostOnly: Bool

    var isHost: Bool { memberId == hostMemberId }
    var hostName: String? {
        guard let hostMemberId else { return nil }
        return members.first { $0.id == hostMemberId }?.displayName
    }
    var canControl: Bool { !hostOnly || isHost }

    func member(_ id: String?) -> PartyMember? {
        guard let id else { return nil }
        return members.first { $0.id == id }
    }
}

// MARK: - Player bridge

/// The little bit of the player the party needs. Kept as a protocol so the
/// service never has to know about the classic player's engine internals.
@MainActor
protocol WatchPartyPlayer: AnyObject {
    var watchPartyPosition: Double { get }
    var watchPartyPaused: Bool { get }
    var watchPartyRate: Float { get }
    var watchPartyMedia: PartyMedia { get }
    /// Apply a state the party coordinator published. `position` is seconds.
    func watchPartyApply(paused: Bool, position: Double, rate: Float)
}

// MARK: - Service

/// Polling watch party. The backend exposes the same RPCs Android's realtime
/// channel persists through (`watch_party_create`, `join`, `preview`,
/// `heartbeat`, `update`, `leave`, `end`, `clock`); polling them is enough for
/// playback sync without a websocket dependency.
///
/// Flow:
/// - host: `create` sends the title and the first playback state, then every
///   local pause/seek/speed change is published (debounced 1.2 s).
/// - guest: `join` gets the party and its latest playback; the poll applies it
///   through `WatchPartyPlayer`. Members who may control also publish.
@MainActor
final class WatchPartyService: ObservableObject {
    static let shared = WatchPartyService()

    private let account = OrivioAccount.shared
    private let stores = AppStores.shared

    @Published private(set) var party: ActiveParty?
    @Published private(set) var busy = false
    @Published private(set) var errorText: String?
    @Published private(set) var notice: String?
    /// False once the server says watch party is switched off.
    @Published private(set) var available = true
    @Published private(set) var connected = false
    /// Set when the host switched to a different title/episode.
    @Published private(set) var pendingMedia: PartyMedia?

    weak var player: (any WatchPartyPlayer)?

    private var pollTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var clockOffsetMs: Double = 0
    private var lastApplied: PartyPlayback?
    private var localSeq: Int64 = 0
    private var applyingRemote = false
    private var joinedAt = Date.distantPast

    private init() {}

    var isSignedIn: Bool { account.isSignedIn }
    var canControl: Bool { party?.canControl ?? false }

    // MARK: Availability

    func refreshAvailability() async {
        guard account.isSignedIn else {
            available = false
            return
        }
        do {
            let data = try await account.rpc("watch_party_enabled", [:])
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            available = text.lowercased() != "false"
        } catch {
            // A probe failure is not proof the feature is off: leave it on and
            // let create/join surface the real error.
        }
    }

    // MARK: Create / join / leave

    func create(media: PartyMedia, position: Double, paused: Bool, rate: Float) async {
        guard await ready() else { return }
        busy = true
        errorText = nil
        notice = nil
        defer { busy = false }
        let playback = PartyPlayback(seq: 1,
                                     memberId: nil,
                                     paused: paused,
                                     positionMs: Int64(max(0, position) * 1000),
                                     rate: max(0.25, min(rate, 4)),
                                     at: serverNowMs(),
                                     mediaKey: media.key,
                                     waiting: false)
        do {
            var body = identityBody()
            body["p_media"] = try jsonObject(media)
            body["p_playback"] = try jsonObject(playback)
            let data = try await call("watch_party_create", body, withProfile: true)
            let snapshot = try decode(PartySnapshot.self, from: data)
            try adopt(snapshot)
            localSeq = 1
            lastApplied = playback
            startSession()
        } catch {
            errorText = message(for: error)
        }
    }

    func join(code: String) async {
        let normalized = Self.normalize(code)
        guard normalized.count == 6 else {
            errorText = "A party code is six characters."
            return
        }
        guard await ready() else { return }
        busy = true
        errorText = nil
        notice = nil
        defer { busy = false }
        do {
            var body = identityBody()
            body["p_code"] = normalized
            let data = try await call("watch_party_join", body, withProfile: true)
            let snapshot = try decode(PartySnapshot.self, from: data)
            try adopt(snapshot)
            localSeq = snapshot.party?.playback?.seq ?? 0
            lastApplied = snapshot.party?.playback
            startSession()
            if let pb = snapshot.party?.playback, let p = party,
               pb.memberId != p.memberId, pb.mediaKey == nil || pb.mediaKey == p.media.key {
                follow(pb)
            }
        } catch {
            errorText = message(for: error)
        }
    }

    func preview(code: String) async -> PartyPreview? {
        let normalized = Self.normalize(code)
        guard normalized.count == 6 else { return nil }
        do {
            let data = try await call("watch_party_preview", ["p_code": normalized])
            return try decode(PartyPreview.self, from: data)
        } catch {
            return PartyPreview(media: nil, host: nil, members: 0, maxMembers: 0,
                                error: message(for: error))
        }
    }

    func leave() {
        guard let p = party else { return }
        let device = deviceID
        stopSession()
        party = nil
        pendingMedia = nil
        notice = "You left the party."
        Task { _ = try? await account.rpc("watch_party_leave",
                                          ["p_party_id": p.id, "p_device_id": device]) }
    }

    func end() {
        guard let p = party, p.isHost else { return }
        let device = deviceID
        stopSession()
        party = nil
        pendingMedia = nil
        notice = "The party ended."
        Task { _ = try? await account.rpc("watch_party_end",
                                          ["p_party_id": p.id, "p_device_id": device]) }
    }

    // MARK: Local playback → server

    /// Called by the player on a pause, seek or speed change. Coalesced: a run
    /// of skip presses becomes one update.
    func publishLocal(paused: Bool, position: Double, rate: Float) {
        guard let p = party, p.canControl, !applyingRemote else { return }
        // Do not publish the join itself: the snapshot we just received is the
        // host's state, not a new command from us.
        guard Date().timeIntervalSince(joinedAt) > 0.75 else { return }
        localSeq = max(localSeq + 1, (lastApplied?.seq ?? 0) + 1)
        let pb = PartyPlayback(seq: localSeq,
                               memberId: p.memberId,
                               paused: paused,
                               positionMs: Int64(max(0, position) * 1000),
                               rate: max(0.25, min(rate, 4)),
                               at: serverNowMs(),
                               mediaKey: p.media.key,
                               waiting: false)
        lastApplied = pb
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, self.party?.id == p.id else { return }
            do {
                let body: [String: Any] = [
                    "p_party_id": p.id,
                    "p_device_id": self.deviceID,
                    "p_playback": try self.jsonObject(pb),
                ]
                let data = try await self.call("watch_party_update", body)
                let snapshot = try self.decode(PartySnapshot.self, from: data)
                self.adoptSnapshot(snapshot, applyPlayback: false)
            } catch {
                self.connected = false
            }
        }
    }

    /// The host moved to a different title/episode. The panel offers the
    /// viewer a way to load it; nothing switches under them silently.
    func acknowledgePendingMedia() {
        pendingMedia = nil
    }

    /// The host changed episode/title inside the player. Push the new media
    /// alongside a fresh playback state so guests know what to load.
    func publishMedia(_ media: PartyMedia, position: Double, paused: Bool, rate: Float) {
        guard let p = party, p.isHost else { return }
        localSeq = max(localSeq + 1, (lastApplied?.seq ?? 0) + 1)
        let pb = PartyPlayback(seq: localSeq,
                               memberId: p.memberId,
                               paused: paused,
                               positionMs: Int64(max(0, position) * 1000),
                               rate: max(0.25, min(rate, 4)),
                               at: serverNowMs(),
                               mediaKey: media.key,
                               waiting: false)
        lastApplied = pb
        party?.media = media
        Task { [weak self] in
            guard let self, self.party?.id == p.id else { return }
            do {
                let body: [String: Any] = [
                    "p_party_id": p.id,
                    "p_device_id": self.deviceID,
                    "p_media": try self.jsonObject(media),
                    "p_playback": try self.jsonObject(pb),
                ]
                let data = try await self.call("watch_party_update", body)
                let snapshot = try self.decode(PartySnapshot.self, from: data)
                self.adoptSnapshot(snapshot, applyPlayback: false)
            } catch {
                self.connected = false
            }
        }
    }

    /// Surface a local validation message in the panel.
    func report(_ text: String) {
        errorText = text
    }

    // MARK: Polling

    private func startSession() {
        joinedAt = Date()
        connected = true
        pendingMedia = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // The first poll waits a beat so it doesn't race the create/join
            // response that just installed the state.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        syncClock()
    }

    private func stopSession() {
        pollTask?.cancel()
        pollTask = nil
        publishTask?.cancel()
        publishTask = nil
        clockTask?.cancel()
        clockTask = nil
        connected = false
        lastApplied = nil
        localSeq = 0
    }

    private func poll() async {
        guard let p = party else { return }
        do {
            let data = try await account.rpc("watch_party_heartbeat",
                                             ["p_party_id": p.id, "p_device_id": deviceID])
            let snapshot = try decode(PartySnapshot.self, from: data)
            if let error = snapshot.error {
                handlePartyError(error)
                return
            }
            connected = true
            adoptSnapshot(snapshot)
        } catch {
            connected = false
        }
    }

    private func adoptSnapshot(_ snapshot: PartySnapshot, applyPlayback: Bool = true) {
        guard let info = snapshot.party, let memberId = snapshot.memberId else { return }
        let previous = party
        var next = ActiveParty(id: info.id,
                               code: info.code,
                               memberId: memberId,
                               hostMemberId: info.hostMemberId,
                               members: snapshot.members,
                               media: info.media,
                               maxMembers: info.maxMembers,
                               hostOnly: info.hostOnly)
        if next.members.isEmpty { next.members = previous?.members ?? [] }
        if let old = previous, old.media.key != next.media.key {
            // The host switched titles. Tell the panel; do not yank playback.
            if next.media.key != player?.watchPartyMedia.key {
                pendingMedia = next.media
                notice = "The host is watching \(next.media.title)."
            } else {
                pendingMedia = nil
            }
        }
        party = next
        if let server = snapshot.serverTimeMs { sampleClock(server) }
        guard applyPlayback, let pb = info.playback else { return }
        if let current = lastApplied, !Self.isNewer(pb, than: current) { return }
        if pb.memberId == next.memberId { return }
        guard pb.mediaKey == nil || pb.mediaKey == next.media.key else { return }
        lastApplied = pb
        follow(pb)
    }

    private func follow(_ pb: PartyPlayback) {
        guard let player, !applyingRemote else { return }
        let expected = Self.expectedPositionMs(pb, now: serverNowMs())
        let localMs = Int64(player.watchPartyPosition * 1000)
        let drift = abs(localMs - expected)
        let wantPause = pb.paused
        let rateChanged = abs(player.watchPartyRate - pb.rate) > 0.01

        if wantPause {
            if !player.watchPartyPaused || drift > 750 {
                applyingRemote = true
                player.watchPartyApply(paused: true, position: Double(expected) / 1000, rate: pb.rate)
                applyingRemote = false
            }
            return
        }
        if player.watchPartyPaused || drift > 1_500 {
            applyingRemote = true
            player.watchPartyApply(paused: false, position: Double(expected) / 1000, rate: pb.rate)
            applyingRemote = false
        } else if rateChanged {
            applyingRemote = true
            player.watchPartyApply(paused: false, position: player.watchPartyPosition, rate: pb.rate)
            applyingRemote = false
        }
    }

    private func handlePartyError(_ error: String) {
        switch error {
        case "party_ended", "ended":
            finish("The party ended.")
        case "removed", "not_member":
            finish("You are no longer in the party.")
        case "party_not_found":
            finish("That party no longer exists.")
        case "rate_limited":
            errorText = "Too many requests — try again in a moment."
        case "unavailable":
            available = false
            finish("Watch Party is unavailable right now.")
        default:
            break
        }
    }

    private func finish(_ message: String) {
        stopSession()
        party = nil
        pendingMedia = nil
        notice = message
        ToastCenter.shared.show(message, systemImage: "person.2.slash")
    }

    // MARK: Clock

    private func syncClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            for _ in 0..<3 {
                guard let self, !Task.isCancelled else { return }
                let sent = Date()
                do {
                    let data = try await self.account.rpc("watch_party_clock", [:])
                    let text = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let server = Double(text) {
                        let rtt = Date().timeIntervalSince(sent) * 1000
                        let offset = server + rtt / 2 - Date().timeIntervalSince1970 * 1000
                        if abs(offset) < 60_000 { self.clockOffsetMs = offset }
                    }
                } catch {
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func sampleClock(_ serverMs: Int64) {
        // A heartbeat carries the server's clock too; treat it as a coarse
        // sample only when we have never synced.
        if abs(clockOffsetMs) < 1 {
            clockOffsetMs = Double(serverMs) - Date().timeIntervalSince1970 * 1000
        }
    }

    private func serverNowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000 + clockOffsetMs)
    }

    private static func expectedPositionMs(_ pb: PartyPlayback, now: Int64) -> Int64 {
        guard !pb.paused else { return max(0, pb.positionMs) }
        let elapsed = max(0, now - pb.at)
        return max(0, pb.positionMs + Int64(Double(elapsed) * Double(pb.rate)))
    }

    private static func isNewer(_ candidate: PartyPlayback, than current: PartyPlayback) -> Bool {
        if candidate.seq != current.seq { return candidate.seq > current.seq }
        return (candidate.memberId ?? "") > (current.memberId ?? "")
    }

    // MARK: Identity / RPC helpers

    private var deviceID: String { OrivioSync.shared.clientID }

    private var profile: Profile { stores.profiles.active }

    private func identityBody() -> [String: Any] {
        var body: [String: Any] = [
            "p_device_id": deviceID,
            "p_display_name": profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Orivio" : String(profile.name.prefix(40)),
            "p_avatar_color": profile.avatarColorHex,
        ]
        if let url = profile.avatarURL, url.hasPrefix("https://"), url.count <= 512 {
            body["p_avatar_url"] = url
        }
        return body
    }

    private func ready() async -> Bool {
        guard account.isSignedIn else {
            errorText = "Sign in to Orivio to use Watch Party."
            return false
        }
        if !available { await refreshAvailability() }
        guard available else {
            errorText = "Watch Party is unavailable on this account."
            return false
        }
        return true
    }

    private func call(_ name: String, _ body: [String: Any], withProfile: Bool = false) async throws -> Data {
        guard withProfile else { return try await account.rpc(name, body) }
        var profiled = body
        profiled["p_profile_index"] = profile.id
        do {
            return try await account.rpc(name, profiled)
        } catch let error as OrivioAuthError where error.isMissingRPC {
            // Older deployments don't take the profile index. Retry exactly
            // like Android: the function exists, the extra argument does not.
            return try await account.rpc(name, body)
        }
    }

    private func adopt(_ snapshot: PartySnapshot) throws {
        if let error = snapshot.error { throw PartyServiceError.party(error) }
        guard let info = snapshot.party, let memberId = snapshot.memberId else {
            throw PartyServiceError.party("network")
        }
        party = ActiveParty(id: info.id,
                            code: info.code,
                            memberId: memberId,
                            hostMemberId: info.hostMemberId,
                            members: snapshot.members,
                            media: info.media,
                            maxMembers: info.maxMembers,
                            hostOnly: info.hostOnly)
        if let server = snapshot.serverTimeMs { sampleClock(server) }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func message(for error: Error) -> String {
        if let e = error as? PartyServiceError { return e.text }
        if let e = error as? OrivioAuthError { return e.errorDescription ?? "Watch Party failed." }
        return error.localizedDescription
    }

    static func normalize(_ code: String) -> String {
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(code.uppercased().filter { alphabet.contains($0) }.prefix(6))
    }

    static func format(_ code: String) -> String {
        let n = normalize(code)
        return n.count == 6 ? "\(n.prefix(3)) \(n.suffix(3))" : n
    }
}

private enum PartyServiceError: Error {
    case party(String)

    var text: String {
        guard case .party(let code) = self else { return "Watch Party failed." }
        switch code {
        case "party_not_found": return "That party doesn't exist."
        case "party_full": return "That party is full."
        case "party_ended", "ended": return "That party has ended."
        case "removed", "not_member": return "You are no longer in that party."
        case "rate_limited": return "Too many attempts — try again in a moment."
        case "unavailable": return "Watch Party is unavailable right now."
        case "invalid_code": return "That code isn't valid."
        default: return "Couldn't reach the party — check your connection."
        }
    }
}
