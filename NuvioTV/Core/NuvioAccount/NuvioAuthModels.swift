import Foundation

// MARK: - Backend DTOs (field names mirror the Nuvio Supabase schema)

/// Row returned by `rpc/start_tv_login_session`.
struct TvLoginStartResult: Decodable {
    let code: String
    let webURL: String
    let expiresAt: String
    let pollIntervalSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case code
        case webURL = "web_url"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        webURL = try c.decode(String.self, forKey: .webURL)
        expiresAt = (try? c.decode(String.self, forKey: .expiresAt)) ?? ""
        pollIntervalSeconds = (try? c.decode(Int.self, forKey: .pollIntervalSeconds)) ?? 3
    }
}

/// Row returned by `rpc/poll_tv_login_session`.
struct TvLoginPollResult: Decodable {
    let status: String
    let expiresAt: String?
    let pollIntervalSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case status
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }
}

// MARK: - Auth state

enum NuvioAuthState: Equatable {
    case loading
    case signedOut
    case signedIn(userID: String, email: String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// Live state of an in-progress QR device login.
struct QRLoginState: Equatable {
    var code: String
    var webURL: String
    var nonce: String
    var statusText: String
    var expiresAt: Date?
    var pollIntervalSeconds: Int
}

// MARK: - Persisted session

/// The tokens we keep so the login survives app relaunches. Stored in
/// UserDefaults for parity with the rest of this app's local storage; the
/// access token is short-lived and the refresh token is rotated on use.
struct NuvioSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String

    private static let key = "nuvio.session.v1"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func load() -> NuvioSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NuvioSession.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - JWT helpers

/// Minimal decode of a Supabase access token so we can show who is signed in
/// (and detect expiry) without an extra `/user` round-trip.
enum JWT {
    struct Claims {
        let sub: String?
        let email: String?
        let exp: Date?
    }

    static func decode(_ token: String) -> Claims? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // base64url -> base64 with padding
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp = (obj["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Claims(sub: obj["sub"] as? String, email: obj["email"] as? String, exp: exp)
    }
}
