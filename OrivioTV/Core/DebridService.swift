import Foundation

// MARK: - Providers

/// A debrid provider. All four authenticate here either by pasting an API
/// key/token (from the provider's account page) or via a scan-a-QR device
/// login — the same device flows the Android app uses.
enum DebridProvider: String, CaseIterable, Identifiable, Codable {
    case realDebrid, premiumize, torbox, allDebrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .premiumize: return "Premiumize"
        case .torbox: return "TorBox"
        case .allDebrid: return "AllDebrid"
        }
    }

    var shortName: String {
        switch self {
        case .realDebrid: return "RD"
        case .premiumize: return "PM"
        case .torbox: return "TB"
        case .allDebrid: return "AD"
        }
    }

    /// Where the user finds their API key, shown in Settings.
    var keyHint: String {
        switch self {
        case .realDebrid: return "real-debrid.com/apitoken"
        case .premiumize: return "premiumize.me/account"
        case .torbox: return "torbox.app → Settings → API"
        case .allDebrid: return "alldebrid.com/apikeys"
        }
    }

    /// Whether this provider supports the scan-a-QR sign-in flow (like the APK).
    /// All four do: Real-Debrid uses an OAuth device flow, AllDebrid a PIN flow,
    /// Premiumize an OAuth device flow (client_id 450935904), and TorBox its
    /// `user/auth/device` flow (app "Orivio") — the same endpoints the Android app
    /// uses.
    var supportsQRAuth: Bool { true }
}

// MARK: - Device (QR) authentication

/// Real-Debrid OAuth refresh bundle, stored locally so the (short-lived) access
/// token can be refreshed without re-scanning.
struct RDRefresh: Codable, Equatable {
    let clientID: String
    let clientSecret: String
    let refreshToken: String
}

/// A pending device-login: what to show the user (code + QR) and the opaque
/// tokens used to poll for completion.
struct DebridDeviceCode {
    let userCode: String        // shown big on screen
    let verificationURL: String // where to enter it
    let qrURL: String           // encoded in the QR
    let pollPrimary: String     // RD: device_code · AD: check hash
    let pollSecondary: String   // AD: pin · RD: ""
    let interval: Int
    let expiresIn: Int
}

struct DebridAuthSuccess {
    let apiKey: String          // token/key to store + use as Bearer
    let refresh: RDRefresh?     // RD only
}

enum DebridAuthPoll {
    case pending
    case success(DebridAuthSuccess)
    case failed(String)
}

// MARK: - Store

/// Per-provider API keys + preferred provider, persisted locally.
@MainActor
final class DebridStore: ObservableObject {
    @Published private(set) var keys: [DebridProvider: String] = [:]
    @Published var preferred: DebridProvider? {
        didSet {
            guard preferred != oldValue else { return }
            saveMeta()
            if !applyingRemote { onLocalChange?() }
        }
    }

    /// Fired on a local key/preferred change so account sync can push. Guarded
    /// during a remote apply so a pull never echoes back as a push.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    /// Real-Debrid OAuth refresh bundle (device-login only). Stored locally,
    /// NOT synced — it's device credentials, so each device refreshes its own.
    @Published private(set) var rdRefresh: RDRefresh?

    private static let keysKey = "orivio.debrid.keys.v1"
    private static let preferredKey = "orivio.debrid.preferred.v1"
    private static let rdRefreshKey = "orivio.debrid.rdrefresh.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.keysKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            keys = Dictionary(uniqueKeysWithValues: decoded.compactMap { raw in
                DebridProvider(rawValue: raw.key).map { ($0, raw.value) }
            })
        }
        if let raw = UserDefaults.standard.string(forKey: Self.preferredKey) {
            preferred = DebridProvider(rawValue: raw)
        }
        if let data = UserDefaults.standard.data(forKey: Self.rdRefreshKey) {
            rdRefresh = try? JSONDecoder().decode(RDRefresh.self, from: data)
        }
    }

    /// Save the result of a QR device login: the token as the provider's key,
    /// plus (for Real-Debrid) the refresh bundle for later token refreshes.
    func applyDeviceAuth(_ success: DebridAuthSuccess, for provider: DebridProvider) {
        setKey(success.apiKey, for: provider)
        if provider == .realDebrid {
            rdRefresh = success.refresh
            saveRDRefresh()
        }
    }

    /// Refresh the Real-Debrid access token (its device-flow token is short-
    /// lived). Call on launch so a QR-linked RD keeps working. No-op if RD isn't
    /// device-linked.
    func refreshRealDebridIfNeeded() async {
        guard configuredProviders.contains(.realDebrid), let refresh = rdRefresh else { return }
        guard let result = await DebridService.refreshRealDebrid(refresh) else { return }
        applyingRemote = true          // don't treat a token refresh as a user edit
        keys[.realDebrid] = result.token
        saveKeys()
        applyingRemote = false
        rdRefresh = result.refresh
        saveRDRefresh()
    }

    private func saveRDRefresh() {
        if let refresh = rdRefresh, let data = try? JSONEncoder().encode(refresh) {
            UserDefaults.standard.set(data, forKey: Self.rdRefreshKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.rdRefreshKey)
        }
    }

    var configuredProviders: [DebridProvider] {
        DebridProvider.allCases.filter { !(keys[$0] ?? "").isEmpty }
    }

    var hasAnyConfigured: Bool { !configuredProviders.isEmpty }

    func key(for provider: DebridProvider) -> String { keys[provider] ?? "" }

    func setKey(_ key: String, for provider: DebridProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keys.removeValue(forKey: provider)
            if provider == .realDebrid { rdRefresh = nil; saveRDRefresh() }
        } else { keys[provider] = trimmed }
        if preferred == nil, !trimmed.isEmpty { preferred = provider }
        if preferred != nil, keys[preferred!] == nil { preferred = configuredProviders.first }
        saveKeys()
        if !applyingRemote { onLocalChange?() }
    }

    // MARK: Sync

    /// Provider keys + preferred, as a syncable snapshot.
    struct DebridSnapshot: Codable, Equatable {
        var keys: [String: String] = [:]
        var preferred: String?
    }

    var snapshot: DebridSnapshot {
        DebridSnapshot(
            keys: Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) }),
            preferred: preferred?.rawValue
        )
    }

    /// Apply keys pulled from the account without echoing them back up. Merges:
    /// remote keys win, but a locally-entered key the remote lacks is kept.
    func applyRemote(_ s: DebridSnapshot) {
        applyingRemote = true
        defer { applyingRemote = false }
        var merged = keys
        for (raw, value) in s.keys {
            guard let provider = DebridProvider(rawValue: raw), !value.isEmpty else { continue }
            merged[provider] = value
        }
        if merged != keys { keys = merged; saveKeys() }
        if let raw = s.preferred, let provider = DebridProvider(rawValue: raw),
           configuredProviders.contains(provider), preferred != provider {
            preferred = provider
        }
    }

    /// The provider to try first for resolution.
    var resolverProvider: DebridProvider? {
        if let preferred, configuredProviders.contains(preferred) { return preferred }
        return configuredProviders.first
    }

    /// Every configured provider with its key, preferred first — the order
    /// `DebridService.resolveAcross` walks, so a torrent the preferred debrid
    /// doesn't have cached still resolves through the others.
    var orderedResolvers: [(provider: DebridProvider, apiKey: String)] {
        var order = configuredProviders
        if let preferred, let idx = order.firstIndex(of: preferred) {
            order.remove(at: idx)
            order.insert(preferred, at: 0)
        }
        return order.map { ($0, key(for: $0)) }
    }

    private func saveKeys() {
        let raw = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.keysKey)
        }
    }

    private func saveMeta() {
        UserDefaults.standard.set(preferred?.rawValue, forKey: Self.preferredKey)
    }
}

// MARK: - Resolution

enum DebridResult {
    case success(url: String, filename: String?)
    case missingKey
    case notCached
    case failed(String)
}

/// Resolves torrent streams to direct HTTP links via a debrid provider.
/// Mirrors the Android DirectDebridResolver flows for each service.
enum DebridService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static let videoExtensions = ["mkv", "mp4", "avi", "mov", "m4v", "wmv", "flv", "ts", "webm"]

    /// Resolve across EVERY configured provider, preferred first: the first
    /// success wins; a provider that doesn't have the torrent cached (or
    /// errors) falls through to the next. Returns the provider that actually
    /// resolved so callers can label the source correctly. This is what makes
    /// a multi-debrid setup (e.g. TorBox + RD) actually use all of them
    /// instead of only the preferred one.
    static func resolveAcross(
        stream: Stream,
        providers: [(provider: DebridProvider, apiKey: String)],
        season: Int?,
        episode: Int?
    ) async -> (result: DebridResult, provider: DebridProvider?) {
        var lastResult: DebridResult = .missingKey
        for (provider, apiKey) in providers {
            let result = await resolve(
                stream: stream, provider: provider, apiKey: apiKey,
                season: season, episode: episode
            )
            if case .success = result { return (result, provider) }
            lastResult = result
        }
        return (lastResult, nil)
    }

    /// Resolve a torrent stream to a direct URL using the given provider+key.
    static func resolve(
        stream: Stream,
        provider: DebridProvider,
        apiKey: String,
        season: Int?,
        episode: Int?
    ) async -> DebridResult {
        guard !apiKey.isEmpty else { return .missingKey }
        guard let magnet = stream.magnetURI, let infoHash = stream.infoHash else {
            return .failed("Not a torrent stream")
        }
        do {
            switch provider {
            case .realDebrid:
                return try await resolveRealDebrid(magnet: magnet, apiKey: apiKey, season: season, episode: episode)
            case .premiumize:
                return try await resolvePremiumize(magnet: magnet, apiKey: apiKey, season: season, episode: episode)
            case .torbox:
                return try await resolveTorbox(magnet: magnet, apiKey: apiKey, season: season, episode: episode)
            case .allDebrid:
                return try await resolveAllDebrid(magnet: magnet, infoHash: infoHash, apiKey: apiKey, season: season, episode: episode)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Device (QR) auth

    /// Real-Debrid's public open-source device client id (same one the APK and
    /// other RD-integrating clients use for device login).
    static let rdClientID = "X245A4XAIBGVM"

    /// Begin a device login; nil if the provider doesn't support it or the
    /// request failed.
    static func startDeviceAuth(_ provider: DebridProvider) async -> DebridDeviceCode? {
        switch provider {
        case .realDebrid: return await startRD()
        case .allDebrid:  return await startAD()
        case .premiumize: return await startPM()
        case .torbox:     return await startTB()
        }
    }

    /// Poll for completion. `.pending` means keep waiting.
    static func pollDeviceAuth(_ provider: DebridProvider, _ code: DebridDeviceCode) async -> DebridAuthPoll {
        switch provider {
        case .realDebrid: return await pollRD(code)
        case .allDebrid:  return await pollAD(code)
        case .premiumize: return await pollPM(code)
        case .torbox:     return await pollTB(code)
        }
    }

    /// Refresh a Real-Debrid access token from its stored refresh bundle.
    /// Returns the new access token (and updated refresh) or nil on failure.
    static func refreshRealDebrid(_ r: RDRefresh) async -> (token: String, refresh: RDRefresh)? {
        guard let t = try? await rdToken(clientID: r.clientID, clientSecret: r.clientSecret, code: r.refreshToken) else { return nil }
        return (t.access_token, RDRefresh(clientID: r.clientID, clientSecret: r.clientSecret, refreshToken: t.refresh_token))
    }

    // Real-Debrid device flow ---------------------------------------------

    private static func startRD() async -> DebridDeviceCode? {
        struct Resp: Decodable {
            let device_code: String; let user_code: String
            let verification_url: String; let expires_in: Int; let interval: Int
            let direct_verification_url: String?
        }
        var comps = URLComponents(string: "https://api.real-debrid.com/oauth/v2/device/code")!
        comps.queryItems = [.init(name: "client_id", value: rdClientID), .init(name: "new_credentials", value: "yes")]
        guard let (data, resp) = try? await session.data(from: comps.url!),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return nil }
        return DebridDeviceCode(
            userCode: r.user_code,
            verificationURL: r.verification_url,
            qrURL: r.direct_verification_url ?? r.verification_url,
            pollPrimary: r.device_code, pollSecondary: "",
            interval: max(r.interval, 3), expiresIn: r.expires_in
        )
    }

    private static func pollRD(_ code: DebridDeviceCode) async -> DebridAuthPoll {
        struct Creds: Decodable { let client_id: String; let client_secret: String }
        var comps = URLComponents(string: "https://api.real-debrid.com/oauth/v2/device/credentials")!
        comps.queryItems = [.init(name: "client_id", value: rdClientID), .init(name: "code", value: code.pollPrimary)]
        guard let (data, resp) = try? await session.data(from: comps.url!),
              let http = resp as? HTTPURLResponse else { return .pending }
        // 200 with credentials = authorized; anything else = still waiting.
        guard (200..<300).contains(http.statusCode),
              let creds = try? JSONDecoder().decode(Creds.self, from: data) else { return .pending }
        guard let token = try? await rdToken(clientID: creds.client_id, clientSecret: creds.client_secret, code: code.pollPrimary) else {
            return .failed("Couldn't complete Real-Debrid sign-in.")
        }
        return .success(DebridAuthSuccess(
            apiKey: token.access_token,
            refresh: RDRefresh(clientID: creds.client_id, clientSecret: creds.client_secret, refreshToken: token.refresh_token)
        ))
    }

    private struct RDToken: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }

    private static func rdToken(clientID: String, clientSecret: String, code: String) async throws -> RDToken {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/oauth/v2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["client_id": clientID, "client_secret": clientSecret, "code": code,
                      "grant_type": "http://oauth.net/grant_type/device/1.0"]
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(RDToken.self, from: data)
    }

    // AllDebrid PIN flow ---------------------------------------------------

    private static func startAD() async -> DebridDeviceCode? {
        struct Resp: Decodable { let data: D?; struct D: Decodable { let pin: String; let check: String; let user_url: String; let expires_in: Int? } }
        var comps = URLComponents(string: "https://api.alldebrid.com/v4/pin/get")!
        comps.queryItems = [.init(name: "agent", value: "nuvio")]
        guard let (data, _) = try? await session.data(from: comps.url!),
              let d = (try? JSONDecoder().decode(Resp.self, from: data))?.data else { return nil }
        return DebridDeviceCode(
            userCode: d.pin, verificationURL: "alldebrid.com/pin",
            qrURL: d.user_url.hasPrefix("http") ? d.user_url : "https://\(d.user_url)",
            pollPrimary: d.check, pollSecondary: d.pin,
            interval: 4, expiresIn: d.expires_in ?? 600
        )
    }

    private static func pollAD(_ code: DebridDeviceCode) async -> DebridAuthPoll {
        struct Resp: Decodable { let data: D?; struct D: Decodable { let activated: Bool?; let apikey: String?; let expired: Bool? } }
        var comps = URLComponents(string: "https://api.alldebrid.com/v4/pin/check")!
        comps.queryItems = [.init(name: "agent", value: "nuvio"),
                            .init(name: "check", value: code.pollPrimary),
                            .init(name: "pin", value: code.pollSecondary)]
        guard let (data, _) = try? await session.data(from: comps.url!),
              let d = (try? JSONDecoder().decode(Resp.self, from: data))?.data else { return .pending }
        if d.expired == true { return .failed("Code expired — try again.") }
        if d.activated == true, let key = d.apikey, !key.isEmpty {
            return .success(DebridAuthSuccess(apiKey: key, refresh: nil))
        }
        return .pending
    }

    // Premiumize OAuth device flow ----------------------------------------
    // Same as the Android app: POST /token with the app's registered client id.

    /// Premiumize's registered device-flow client id (from the Orivio app).
    static let pmClientID = "450935904"

    private static func startPM() async -> DebridDeviceCode? {
        struct Resp: Decodable {
            let device_code: String?; let user_code: String?
            let verification_uri: String?; let verification_uri_complete: String?
            let expires_in: Int?; let interval: Int?
            let error: String?
        }
        guard let r: Resp = try? await decode(pmTokenRequest(fields: [
            "response_type": "device_code", "client_id": pmClientID
        ])), let deviceCode = r.device_code, let userCode = r.user_code else { return nil }
        let verify = r.verification_uri ?? "premiumize.me/device"
        return DebridDeviceCode(
            userCode: userCode,
            verificationURL: verify,
            qrURL: r.verification_uri_complete ?? verify,
            pollPrimary: deviceCode, pollSecondary: "",
            interval: max(r.interval ?? 5, 3), expiresIn: r.expires_in ?? 600
        )
    }

    private static func pollPM(_ code: DebridDeviceCode) async -> DebridAuthPoll {
        struct Resp: Decodable {
            let access_token: String?; let error: String?
        }
        guard let r: Resp = try? await decode(pmTokenRequest(fields: [
            "grant_type": "device_code", "code": code.pollPrimary, "client_id": pmClientID
        ])) else { return .pending }
        if let token = r.access_token, !token.isEmpty {
            return .success(DebridAuthSuccess(apiKey: token, refresh: nil))
        }
        // Standard OAuth device-flow statuses: keep waiting on these two.
        switch r.error {
        case "authorization_pending", "slow_down", nil: return .pending
        case "access_denied": return .failed("Sign-in was denied.")
        case "expired_token": return .failed("Code expired — try again.")
        default: return .failed("Couldn't complete Premiumize sign-in.")
        }
    }

    private static func pmTokenRequest(fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.premiumize.me/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        return request
    }

    // TorBox device flow --------------------------------------------------
    // GET .../device/start?app=Orivio → poll POST .../device/token {device_code}.

    private static func startTB() async -> DebridDeviceCode? {
        struct Resp: Decodable { let data: D?
            struct D: Decodable {
                let device_code: String?; let code: String?
                let verification_url: String?; let friendly_verification_url: String?
                let interval: Int?; let expires_at: String?
            }
        }
        var comps = URLComponents(string: "https://api.torbox.app/v1/api/user/auth/device/start")!
        comps.queryItems = [.init(name: "app", value: "Nuvio")]
        var request = URLRequest(url: comps.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let d = (try? await decode(request) as Resp)?.data,
              let deviceCode = d.device_code, let code = d.code,
              let verify = d.verification_url ?? d.friendly_verification_url else { return nil }
        return DebridDeviceCode(
            userCode: code,
            verificationURL: d.friendly_verification_url ?? verify,
            qrURL: verify,
            pollPrimary: deviceCode, pollSecondary: "",
            interval: max(d.interval ?? 5, 3), expiresIn: tbExpiry(d.expires_at)
        )
    }

    private static func pollTB(_ code: DebridDeviceCode) async -> DebridAuthPoll {
        struct Resp: Decodable { let data: D?
            struct D: Decodable { let access_token: String? }
        }
        var request = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/user/auth/device/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_code": code.pollPrimary])
        guard let r: Resp = try? await decode(request) else { return .pending }
        if let token = r.data?.access_token, !token.isEmpty {
            return .success(DebridAuthSuccess(apiKey: token, refresh: nil))
        }
        return .pending
    }

    /// Seconds until a TorBox `expires_at` ISO timestamp, or a sane default.
    private static func tbExpiry(_ iso: String?) -> Int {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return 600 }
        return max(Int(date.timeIntervalSinceNow), 60)
    }

    /// Validate a key by hitting the provider's account endpoint.
    static func validate(provider: DebridProvider, apiKey: String) async -> Bool {
        guard !apiKey.isEmpty else { return false }
        let request: URLRequest
        switch provider {
        case .realDebrid:
            request = bearerRequest("https://api.real-debrid.com/rest/1.0/user", key: apiKey)
        case .premiumize:
            request = bearerRequest("https://www.premiumize.me/api/account/info", key: apiKey)
        case .torbox:
            request = bearerRequest("https://api.torbox.app/v1/api/user/me", key: apiKey)
        case .allDebrid:
            var comps = URLComponents(string: "https://api.alldebrid.com/v4/user")!
            comps.queryItems = [.init(name: "agent", value: "nuvio"), .init(name: "apikey", value: apiKey)]
            request = URLRequest(url: comps.url!)
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: File selection

    /// Pick the best video file: for series match SxxExx, else the largest.
    private static func selectFile<F>(
        _ files: [F], season: Int?, episode: Int?,
        path: (F) -> String, size: (F) -> Int64
    ) -> F? {
        let videos = files.filter { f in
            let ext = (path(f) as NSString).pathExtension.lowercased()
            return videoExtensions.contains(ext)
        }
        let pool = videos.isEmpty ? files : videos
        if let season, let episode {
            let patterns = [
                String(format: "s%02de%02d", season, episode),
                String(format: "%dx%02d", season, episode)
            ]
            if let match = pool.first(where: { f in
                let name = path(f).lowercased()
                return patterns.contains { name.contains($0) }
            }) { return match }
        }
        return pool.max { size($0) < size($1) }
    }

    // MARK: Real-Debrid

    private static func resolveRealDebrid(magnet: String, apiKey: String, season: Int?, episode: Int?) async throws -> DebridResult {
        struct AddResult: Decodable { let id: String }
        struct TorrentInfo: Decodable {
            let status: String
            let links: [String]?
            let files: [TorrentFile]?
        }
        struct TorrentFile: Decodable { let id: Int; let path: String; let bytes: Int64 }
        struct Unrestrict: Decodable { let download: String; let filename: String? }

        let add: AddResult = try await form("https://api.real-debrid.com/rest/1.0/torrents/addMagnet", key: apiKey, fields: ["magnet": magnet])
        let torrentID = add.id
        var resolved = false
        defer {
            if !resolved {
                Task { _ = try? await self.delete("https://api.real-debrid.com/rest/1.0/torrents/delete/\(torrentID)", key: apiKey) }
            }
        }
        // RD parses the magnet asynchronously: immediately after addMagnet the
        // torrent sits in "magnet_conversion" with an empty file list, so a
        // single instant read declared genuinely-cached torrents .notCached.
        // Poll briefly until the files appear.
        var info1: TorrentInfo = try await bearerGET("https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)", key: apiKey)
        var waits = 0
        while (info1.files ?? []).isEmpty,
              ["magnet_conversion", "queued", "waiting_files_selection"].contains(info1.status.lowercased()),
              waits < 5 {
            waits += 1
            try? await Task.sleep(nanoseconds: 700_000_000)
            info1 = try await bearerGET("https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)", key: apiKey)
        }
        guard let file = selectFile(info1.files ?? [], season: season, episode: episode, path: \.path, size: \.bytes) else {
            return .notCached
        }
        try? await formIgnore("https://api.real-debrid.com/rest/1.0/torrents/selectFiles/\(torrentID)", key: apiKey, fields: ["files": String(file.id)])
        // A cached torrent flips to "downloaded" almost immediately — give it a
        // couple of beats before concluding it isn't cached.
        var info2: TorrentInfo = try await bearerGET("https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)", key: apiKey)
        waits = 0
        while info2.status.lowercased() != "downloaded", waits < 2 {
            waits += 1
            try? await Task.sleep(nanoseconds: 700_000_000)
            info2 = try await bearerGET("https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)", key: apiKey)
        }
        guard info2.status.lowercased() == "downloaded", let link = info2.links?.first else {
            return .notCached
        }
        let unrestrict: Unrestrict = try await form("https://api.real-debrid.com/rest/1.0/unrestrict/link", key: apiKey, fields: ["link": link])
        guard !unrestrict.download.isEmpty else { return .notCached }
        resolved = true
        return .success(url: unrestrict.download, filename: unrestrict.filename)
    }

    // MARK: Premiumize

    private static func resolvePremiumize(magnet: String, apiKey: String, season: Int?, episode: Int?) async throws -> DebridResult {
        struct DirectDL: Decodable {
            let status: String?
            let content: [Content]?
        }
        struct Content: Decodable { let path: String?; let link: String?; let size: Int64? }
        let result: DirectDL = try await form("https://www.premiumize.me/api/transfer/directdl", key: apiKey, fields: ["src": magnet])
        if result.status?.lowercased() == "error" { return .notCached }
        let contents = result.content ?? []
        guard let file = selectFile(contents, season: season, episode: episode,
                                    path: { $0.path ?? "" }, size: { $0.size ?? 0 }),
              let link = file.link, !link.isEmpty else {
            return .notCached
        }
        return .success(url: link, filename: (file.path as NSString?)?.lastPathComponent)
    }

    // MARK: TorBox

    private static func resolveTorbox(magnet: String, apiKey: String, season: Int?, episode: Int?) async throws -> DebridResult {
        struct Envelope<T: Decodable>: Decodable { let success: Bool?; let data: T? }
        struct CreateData: Decodable { let torrent_id: Int?; let id: Int? }
        struct TorrentData: Decodable { let files: [TorrentFile]? }
        struct TorrentFile: Decodable { let id: Int; let name: String; let size: Int64? }
        struct LinkData: Decodable { let data: String? }

        // INSTANT availability probe first (TorBox's dedicated endpoint):
        // side-effect-free and fast, so an uncached torrent answers .notCached
        // immediately instead of round-tripping createtorrent. Probe failure
        // (endpoint change/outage) falls through to the create path.
        if let infoHash = magnet.range(of: "btih:").map({ String(magnet[$0.upperBound...].prefix(40)) }) {
            struct Cached: Decodable { let name: String? }
            var probe = URLComponents(string: "https://api.torbox.app/v1/api/torrents/checkcached")!
            probe.queryItems = [
                .init(name: "hash", value: infoHash.lowercased()),
                .init(name: "format", value: "object"),
                .init(name: "list_files", value: "false")
            ]
            if let check: Envelope<[String: Cached]> = try? await decode(bearerRequest(probe.url!.absoluteString, key: apiKey)),
               check.success == true, (check.data ?? [:]).isEmpty {
                return .notCached
            }
        }

        // createtorrent is multipart; add_only_if_cached=true → error when not cached.
        let create: Envelope<CreateData> = try await multipart(
            "https://api.torbox.app/v1/api/torrents/createtorrent", key: apiKey,
            parts: ["magnet": magnet, "add_only_if_cached": "true", "allow_zip": "false"]
        )
        guard let torrentID = create.data?.torrent_id ?? create.data?.id else { return .notCached }
        // A cached torrent can take a beat before mylist reports its files —
        // retry briefly instead of declaring a genuinely cached torrent missing.
        var files: [TorrentFile] = []
        for attempt in 0..<4 {
            var comps = URLComponents(string: "https://api.torbox.app/v1/api/torrents/mylist")!
            comps.queryItems = [.init(name: "id", value: String(torrentID)), .init(name: "bypass_cache", value: "true")]
            let list: Envelope<TorrentData> = try await decode(bearerRequest(comps.url!.absoluteString, key: apiKey))
            files = list.data?.files ?? []
            if !files.isEmpty { break }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        guard let file = selectFile(files, season: season, episode: episode, path: \.name, size: { $0.size ?? 0 }) else {
            return .notCached
        }
        var linkComps = URLComponents(string: "https://api.torbox.app/v1/api/torrents/requestdl")!
        linkComps.queryItems = [
            .init(name: "token", value: apiKey),
            .init(name: "torrent_id", value: String(torrentID)),
            .init(name: "file_id", value: String(file.id))
        ]
        let link: LinkData = try await decode(bearerRequest(linkComps.url!.absoluteString, key: apiKey))
        guard let url = link.data, !url.isEmpty else { return .notCached }
        return .success(url: url, filename: file.name)
    }

    // MARK: AllDebrid (public v4 API)

    private static func resolveAllDebrid(magnet: String, infoHash: String, apiKey: String, season: Int?, episode: Int?) async throws -> DebridResult {
        // Upload magnet → get id, then poll status for ready links, then unlock.
        struct UploadResponse: Decodable { let data: UploadData? }
        struct UploadData: Decodable { let magnets: [UploadMagnet]? }
        struct UploadMagnet: Decodable { let id: Int?; let ready: Bool? }
        struct StatusResponse: Decodable { let data: StatusData? }
        struct StatusData: Decodable { let magnets: StatusMagnet? }
        struct StatusMagnet: Decodable { let status: String?; let links: [StatusLink]? }
        struct StatusLink: Decodable { let link: String?; let filename: String?; let size: Int64? }
        struct UnlockResponse: Decodable { let data: UnlockData? }
        struct UnlockData: Decodable { let link: String? }

        let upload: UploadResponse = try await adGET("magnet/upload", apiKey: apiKey, query: ["magnets[]": magnet])
        guard let id = upload.data?.magnets?.first?.id else { return .notCached }
        let status: StatusResponse = try await adGET("magnet/status", apiKey: apiKey, query: ["id": String(id)])
        guard status.data?.magnets?.status?.lowercased() == "ready",
              let links = status.data?.magnets?.links, !links.isEmpty else {
            return .notCached
        }
        let chosen = selectFile(links, season: season, episode: episode,
                                path: { $0.filename ?? "" }, size: { $0.size ?? 0 })
        guard let protectedLink = chosen?.link else { return .notCached }
        let unlock: UnlockResponse = try await adGET("link/unlock", apiKey: apiKey, query: ["link": protectedLink])
        guard let url = unlock.data?.link, !url.isEmpty else { return .notCached }
        return .success(url: url, filename: chosen?.filename)
    }

    // MARK: - HTTP helpers

    private static func bearerRequest(_ url: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func bearerGET<T: Decodable>(_ url: String, key: String) async throws -> T {
        try await decode(bearerRequest(url, key: key))
    }

    private static func form<T: Decodable>(_ url: String, key: String, fields: [String: String]) async throws -> T {
        var request = bearerRequest(url, key: key)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return try await decode(request)
    }

    /// POST a form body and ignore the response (used for RD selectFiles).
    private static func formIgnore(_ url: String, key: String, fields: [String: String]) async throws {
        var request = bearerRequest(url, key: key)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        _ = try await session.data(for: request)
    }

    @discardableResult
    private static func delete(_ url: String, key: String) async throws -> Data {
        var request = bearerRequest(url, key: key)
        request.httpMethod = "DELETE"
        let (data, _) = try await session.data(for: request)
        return data
    }

    private static func multipart<T: Decodable>(_ url: String, key: String, parts: [String: String]) async throws -> T {
        var request = bearerRequest(url, key: key)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (name, value) in parts {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return try await decode(request)
    }

    private static func adGET<T: Decodable>(_ path: String, apiKey: String, query: [String: String]) async throws -> T {
        var comps = URLComponents(string: "https://api.alldebrid.com/v4/\(path)")!
        var items = [URLQueryItem(name: "agent", value: "nuvio"), URLQueryItem(name: "apikey", value: apiKey)]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await decode(request)
    }
}
