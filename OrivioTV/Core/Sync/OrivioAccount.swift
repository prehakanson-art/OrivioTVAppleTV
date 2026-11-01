import Foundation
import UIKit

enum OrivioAuthError: LocalizedError {
    case message(String)
    case http(Int, String)
    case signedOut

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .http(let code, let body):
            if let msg = Self.serverMessage(body) { return msg }
            return "The server answered \(code)."
        case .signedOut: return "Not signed in."
        }
    }

    static func serverMessage(_ body: String) -> String? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        for k in ["error_description", "msg", "message", "error", "hint"] {
            if let v = d[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// PostgREST's answer when the function itself isn't deployed.
    var isMissingRPC: Bool {
        guard case .http(let code, let body) = self else { return false }
        return [400, 404].contains(code) && body.localizedCaseInsensitiveContains("could not find the function")
    }
}

/// The Orivio account (self-hosted Supabase, wire-compatible with Android).
/// Sign-in: QR (the TV shows a code; the user signs in on the web page; the app
/// never sees the password) or email/password. Session in `orivio.session.v1`.
@MainActor
final class OrivioAccount: ObservableObject {
    static let shared = OrivioAccount()

    struct Session: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
    }

    struct QRLogin: Equatable {
        var code: String
        var webURL: String
        var nonce: String
        var status: String
        var pollInterval: Int
    }

    @Published private(set) var session: Session?
    @Published private(set) var userID: String?
    @Published private(set) var email: String?
    @Published private(set) var qrLogin: QRLogin?
    @Published var errorMessage: String?

    /// Bumps on every sign-in/out so a late response can't undo a sign-out.
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Bool, Never>?
    private static let sessionKey = "orivio.session.v1"
    private let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    var isSignedIn: Bool { session != nil && userID != nil }
    var isConfigured: Bool { !Secrets.supabaseURL.isEmpty && !Secrets.supabaseAnonKey.isEmpty }

    /// Called after every successful sign-in (the sync engine wipes a different account's data, then syncs).
    var onSignedIn: ((_ userID: String, _ interactive: Bool) -> Void)?
    var onSignedOut: (() -> Void)?

    private init() {
        if let data = Persistence.dataValue(forKey: Self.sessionKey), let s = try? JSONDecoder().decode(Session.self, from: data) {
            session = s
            applyClaims(s.accessToken)
        }
    }

    // MARK: QR login

    func startQRLogin() {
        cancelQRLogin()
        errorMessage = nil
        let nonce = Self.nonce()
        let gen = generation
        Task {
            do {
                let data = try await post("/rest/v1/rpc/start_tv_login_session", body: [
                    "p_device_nonce": nonce,
                    "p_redirect_base_url": Secrets.tvLoginWebBaseURL,
                    "p_device_name": Self.deviceLabel,
                ])
                guard gen == generation else { return }
                guard let row = Self.firstRow(data), let code = row["code"] as? String, let web = row["web_url"] as? String,
                      !code.isEmpty, !web.isEmpty else { throw OrivioAuthError.message("The server returned an incomplete login session.") }
                qrLogin = QRLogin(code: code, webURL: web, nonce: nonce, status: "Scan the code with your phone to sign in",
                                  pollInterval: max(row["poll_interval_seconds"] as? Int ?? 3, 2))
                startPolling()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelQRLogin() {
        pollTask?.cancel()
        pollTask = nil
        qrLogin = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let state = self.qrLogin else { return }
                try? await Task.sleep(nanoseconds: UInt64(state.pollInterval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let data = try await self.post("/rest/v1/rpc/poll_tv_login_session", body: ["p_code": state.code, "p_device_nonce": state.nonce])
                    failures = 0
                    guard let row = Self.firstRow(data), let status = (row["status"] as? String)?.lowercased() else { continue }
                    switch status {
                    case "approved":
                        self.qrLogin?.status = "Signing in…"
                        // A fresh task: this one is about to be cancelled, and URLSession aborts cancelled tasks' requests.
                        Task { await self.exchange(state) }
                        return
                    case "expired", "used", "cancelled":
                        self.errorMessage = "This login code \(status). Try again."
                        self.qrLogin = nil
                        return
                    default:
                        self.qrLogin?.status = "Waiting for you to approve on your phone…"
                    }
                } catch {
                    // One blip must not end the login; several in a row does.
                    failures += 1
                    self.qrLogin?.status = "Trouble reaching the server — retrying…"
                    if failures >= 5 {
                        self.errorMessage = error.localizedDescription
                        self.qrLogin = nil
                        return
                    }
                }
            }
        }
    }

    private func exchange(_ state: QRLogin) async {
        let gen = generation
        do {
            let data = try await post("/functions/v1/tv-logins-exchange", body: ["code": state.code, "device_nonce": state.nonce])
            let (access, refresh) = try Self.parseTokens(data)
            guard gen == generation else { return }
            store(Session(accessToken: access, refreshToken: refresh), interactive: true)
            qrLogin = nil
        } catch {
            guard gen == generation else { return }
            errorMessage = error.localizedDescription
            qrLogin = nil
        }
    }

    // MARK: Email / password

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { errorMessage = "Enter your email and password."; return }
        errorMessage = nil
        do {
            let data = try await post("/auth/v1/token?grant_type=password", body: ["email": email, "password": password])
            let (access, refresh) = try Self.parseTokens(data)
            store(Session(accessToken: access, refreshToken: refresh), interactive: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        cancelQRLogin()
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        userID = nil
        email = nil
        Persistence.set(nil, forKey: Self.sessionKey)
        onSignedOut?()
    }

    private func store(_ s: Session, interactive: Bool) {
        session = s
        if let data = try? JSONEncoder().encode(s) { Persistence.set(data, forKey: Self.sessionKey) }
        applyClaims(s.accessToken)
        if let userID { onSignedIn?(userID, interactive) }
    }

    private func applyClaims(_ jwt: String) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        userID = claims["sub"] as? String
        email = claims["email"] as? String
    }

    // MARK: Refresh (serialized — the refresh token rotates on use)

    func refresh() async -> Bool {
        if let t = refreshTask { return await t.value }
        guard let token = session?.refreshToken else { return false }
        let gen = generation
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            do {
                let data = try await self.post("/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": token], isRefresh: true)
                let (a, r) = try Self.parseTokens(data)
                guard gen == self.generation else { return false }
                self.store(Session(accessToken: a, refreshToken: r), interactive: false)
                return true
            } catch {
                guard gen == self.generation else { return false }
                if case OrivioAuthError.http(let code, _) = error, [400, 401, 403].contains(code) { self.signOut() }
                return false
            }
        }
        refreshTask = task
        let ok = await task.value
        if gen == generation { refreshTask = nil }
        return ok
    }

    // MARK: Requests

    /// An authenticated PostgREST call; refreshes once on 401.
    func authed(_ path: String, method: String = "POST", body: Any? = nil) async throws -> Data {
        guard session != nil else { throw OrivioAuthError.signedOut }
        do {
            return try await send(path, method: method, body: body, auth: session?.accessToken)
        } catch OrivioAuthError.http(let code, let text) where code == 401 || (code == 403 && text.contains("JWT")) {
            guard await refresh() else { throw OrivioAuthError.http(code, text) }
            return try await send(path, method: method, body: body, auth: session?.accessToken)
        }
    }

    func rpc(_ name: String, _ body: [String: Any]) async throws -> Data {
        try await authed("/rest/v1/rpc/\(name)", body: body)
    }

    private func post(_ path: String, body: [String: Any], isRefresh: Bool = false) async throws -> Data {
        try await send(path, method: "POST", body: body, auth: nil, isRefresh: isRefresh)
    }

    /// Primary host first; the origin fallback on network errors / 5xx (never
    /// replaying a refresh the origin may already have consumed).
    private func send(_ path: String, method: String, body: Any?, auth: String?, isRefresh: Bool = false) async throws -> Data {
        do {
            return try await attempt(base: Secrets.supabaseURL, path: path, method: method, body: body, auth: auth)
        } catch {
            let fallback = Secrets.supabaseFallbackURL
            guard !fallback.isEmpty, fallback != Secrets.supabaseURL else { throw error }
            let retry: Bool
            switch error {
            case let e as URLError:
                retry = !(isRefresh && [.timedOut, .networkConnectionLost].contains(e.code))
            case OrivioAuthError.http(let code, _):
                retry = code >= 500 && !(isRefresh && [504, 524].contains(code))
            default:
                retry = false
            }
            guard retry else { throw error }
            return try await attempt(base: fallback, path: path, method: method, body: body, auth: auth)
        }
    }

    private func attempt(base: String, path: String, method: String, body: Any?, auth: String?) async throws -> Data {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + path) else { throw OrivioAuthError.message("Bad backend URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(Secrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(auth ?? Secrets.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await urlSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw OrivioAuthError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    // MARK: Helpers

    private static func firstRow(_ data: Data) -> [String: Any]? {
        let obj = try? JSONSerialization.jsonObject(with: data)
        return (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
    }

    /// Tokens may come back flat or nested (session/data).
    static func parseTokens(_ data: Data) throws -> (String, String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw OrivioAuthError.message("The sign-in response was not valid JSON.") }
        func find(_ any: Any?) -> (String, String)? {
            guard let d = any as? [String: Any] else { return nil }
            if let a = (d["access_token"] ?? d["accessToken"]) as? String, let r = (d["refresh_token"] ?? d["refreshToken"]) as? String,
               !a.isEmpty, !r.isEmpty { return (a, r) }
            return nil
        }
        if let t = find(root) { return t }
        if let d = root as? [String: Any] {
            for k in ["session", "data", "currentSession"] {
                if let t = find(d[k]) ?? find((d[k] as? [String: Any])?["session"]) { return t }
            }
            for k in ["error_description", "error", "message", "msg"] {
                if let v = d[k] as? String, !v.isEmpty { throw OrivioAuthError.message(v) }
            }
        }
        throw OrivioAuthError.message("Unexpected sign-in response.")
    }

    /// `UIDevice.name` on tvOS can be empty or a stale default; always say Apple TV.
    static var deviceLabel: String {
        let raw = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.localizedCaseInsensitiveContains("apple tv") else { return "Apple TV" }
        return "\(raw) (Apple TV)"
    }

    private static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
