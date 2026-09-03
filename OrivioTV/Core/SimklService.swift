import Foundation

/// SIMKL account, persisted locally.
///
/// Deliberately simpler than `TraktStore`: SIMKL's PIN flow needs only the
/// public client id (no client secret), and the access token it returns does
/// not expire, so there is no refresh token to keep or rotate.
///
/// The login is DEVICE-WIDE, matching Trakt's default. Trakt grew a
/// `perProfileAccounts` switch and the machinery behind it because its login
/// predates profiles and had to be split retroactively; SIMKL starts fresh, so
/// if per-profile SIMKL accounts are wanted later they should be built on that
/// same switch rather than a second parallel one.
@MainActor
final class SimklStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var username: String?

    /// Public client id (header `simkl-api-key`). `nonisolated`: an immutable
    /// constant the nonisolated networking statics read directly.
    nonisolated static let clientID = Secrets.simklClientID

    /// False until a client id is supplied. Everything degrades gracefully in
    /// that state — the settings page says so instead of offering a login that
    /// could only fail at the first request.
    nonisolated static var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let tokenKey = "orivio.simkl.token.v1"
    private static let userKey = "orivio.simkl.user.v1"

    init() {
        accessToken = UserDefaults.standard.string(forKey: Self.tokenKey)
        username = UserDefaults.standard.string(forKey: Self.userKey)
    }

    var isSignedIn: Bool { accessToken != nil }

    func store(access: String) {
        accessToken = access
        UserDefaults.standard.set(access, forKey: Self.tokenKey)
    }

    func setUsername(_ name: String?) {
        username = name
        UserDefaults.standard.set(name, forKey: Self.userKey)
    }

    func signOut() {
        accessToken = nil
        username = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }
}

// MARK: - Service

struct SimklDeviceCode {
    let userCode: String
    let verificationURL: String
    let interval: Int
    let expiresIn: Int
}

enum SimklPollResult {
    case pending
    case authorized(access: String)
    case expired
    case failed(String)
}

/// Thin SIMKL API client covering the PIN (device-code) login.
enum SimklService {
    private static let base = "https://api.simkl.com"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        // The poll hits the same URL every few seconds and a cached 200 would
        // look like a login that never completes.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Mirrors `TraktService.request`: nil rather than a force-unwrap trap for
    /// a path that can't form a URL.
    private static func request(_ path: String, bearer: String? = nil) -> URLRequest? {
        guard let url = URL(string: base + path) else {
            NSLog("[OrivioSimkl] unusable request path %@", path)
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SimklStore.clientID, forHTTPHeaderField: "simkl-api-key")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }

    enum StartError: LocalizedError {
        case notConfigured
        case service(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "this build has no SIMKL client id. Add one to Secrets.swift as simklClientID."
            case .service(let message):
                return message
            }
        }
    }

    /// SIMKL's error envelope. A bad client id answers HTTP 412 with
    /// `{"error":"client_id_failed","code":412,"message":"Your client_id is
    /// wrong..."}` — decoding that as a success response throws a
    /// `DecodingError` whose description ("The data couldn't be read…") tells
    /// the viewer nothing, so every failure path reads this first and shows
    /// what SIMKL actually said.
    private struct ServiceError: Decodable {
        let error: String?
        let message: String?
        var text: String? {
            if let message, !message.isEmpty { return message }
            if let error, !error.isEmpty { return error }
            return nil
        }
    }

    private static func serviceMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ServiceError.self, from: data))?.text
    }

    /// Start PIN login. Needs only the client id.
    static func startDeviceCode() async throws -> SimklDeviceCode {
        guard SimklStore.isConfigured else { throw StartError.notConfigured }
        struct Response: Decodable {
            let user_code: String
            let verification_url: String?
            let expires_in: Int?
            let interval: Int?
        }
        guard let req = request("/oauth/pin?client_id=\(SimklStore.clientID)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw StartError.service(serviceMessage(data) ?? "SIMKL returned HTTP \(status).")
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            throw StartError.service(serviceMessage(data) ?? "SIMKL sent a login code we couldn't read.")
        }
        return SimklDeviceCode(
            userCode: r.user_code,
            verificationURL: r.verification_url ?? "simkl.com/pin",
            interval: r.interval ?? 5,
            expiresIn: r.expires_in ?? 900
        )
    }

    /// Poll for the token.
    ///
    /// SIMKL polls by USER code, not by a separate device code, and answers
    /// every state with HTTP 200 — the `result` field carries the outcome, so
    /// the status code alone says nothing.
    static func pollToken(userCode: String) async -> SimklPollResult {
        struct Response: Decodable {
            let result: String?
            let access_token: String?
            let message: String?
        }
        guard let req = request("/oauth/pin/\(userCode)?client_id=\(SimklStore.clientID)") else {
            return .failed("Bad request URL")
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return .failed("Network error")
        }
        // A 5xx (or any body we can't read) shouldn't end a login that is
        // otherwise fine; the caller's deadline still bounds the spinning.
        if http.statusCode >= 500 { return .pending }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            return .failed(serviceMessage(data) ?? "Bad response from SIMKL")
        }
        // A rejected client id answers 412 with the envelope above, not with a
        // pending result — surface SIMKL's own wording rather than guessing.
        if !(200..<300).contains(http.statusCode) {
            return .failed(serviceMessage(data) ?? "SIMKL returned HTTP \(http.statusCode)")
        }
        if let token = r.access_token, !token.isEmpty { return .authorized(access: token) }
        // "Authorization pending" is the normal answer until the viewer
        // finishes on their phone. Anything else that isn't OK is terminal.
        let message = r.message?.lowercased() ?? ""
        if message.contains("pending") || message.contains("slow") { return .pending }
        if message.contains("expired") { return .expired }
        if r.result == "OK" { return .pending }        // OK without a token yet
        return message.isEmpty ? .pending : .failed(r.message ?? "SIMKL login failed")
    }

    /// Fetch the signed-in user's display name. Best-effort: a nil name just
    /// shows "Connected".
    static func fetchUsername(accessToken: String) async -> String? {
        struct Settings: Decodable {
            struct User: Decodable { let name: String? }
            let user: User?
        }
        guard let req = request("/users/settings", bearer: accessToken) else { return nil }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return settings.user?.name
    }
}
