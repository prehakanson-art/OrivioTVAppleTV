import SwiftUI
import UIKit

/// Drives Orivio account sign-in on tvOS via the backend's QR / device-pairing
/// flow: the TV asks the server to start a login session, shows a QR code the
/// user scans and approves on nuvio.tv from their phone, then exchanges the
/// approved code for Supabase tokens. The password never touches this device.
///
/// Endpoints and payloads mirror the Android `AuthManager` exactly.
@MainActor
final class OrivioAccountManager: ObservableObject {
    @Published private(set) var authState: OrivioAuthState = .loading
    @Published private(set) var qrLogin: QRLoginState?
    @Published var errorMessage: String?

    private var session: OrivioSession?
    private var pollTask: Task<Void, Never>?
    private var exchangeInFlight = false

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Edge functions (token exchange) can cold-start slowly.
        config.timeoutIntervalForRequest = 40
        return URLSession(configuration: config)
    }()

    // MARK: - Endpoints

    private enum Endpoint {
        static let startTvLogin = "/rest/v1/rpc/start_tv_login_session"
        static let pollTvLogin = "/rest/v1/rpc/poll_tv_login_session"
        static let exchangeTvLogin = "/functions/v1/tv-logins-exchange"
        static let refresh = "/auth/v1/token?grant_type=refresh_token"
    }

    init() {
        restoreSession()
    }

    // MARK: - Session restore

    private func restoreSession() {
        guard let stored = OrivioSession.load() else {
            authState = .signedOut
            return
        }
        session = stored
        applySignedIn(from: stored.accessToken)
        // Refresh in the background if the access token is stale.
        if let claims = JWT.decode(stored.accessToken),
           let exp = claims.exp, exp.timeIntervalSinceNow < 120 {
            Task { await refreshSession() }
        }
    }

    private func applySignedIn(from accessToken: String) {
        guard let claims = JWT.decode(accessToken),
              let userID = claims.sub,
              !userID.isEmpty else {
            session = nil
            OrivioSession.clear()
            authState = .signedOut
            errorMessage = "Your saved sign-in could not be restored. Please sign in again."
            return
        }
        authState = .signedIn(
            userID: userID,
            email: claims.email ?? "Signed in"
        )
    }

    // MARK: - QR login

    func startQRLogin() {
        cancelPolling()
        errorMessage = nil
        qrLogin = nil
        let nonce = Self.generateDeviceNonce()
        let deviceName = Self.deviceLabel

        Task {
            do {
                let rows: [TvLoginStartResult] = try await postArray(
                    endpoint: Endpoint.startTvLogin,
                    body: [
                        "p_device_nonce": nonce,
                        "p_redirect_base_url": OrivioConfig.tvLoginWebBaseURL,
                        "p_device_name": deviceName
                    ]
                )
                guard let start = rows.first, !start.code.isEmpty, !start.webURL.isEmpty else {
                    throw OrivioAuthError.message("The server returned an incomplete login session.")
                }
                qrLogin = QRLoginState(
                    code: start.code,
                    webURL: start.webURL,
                    nonce: nonce,
                    statusText: "Scan the code with your phone to sign in",
                    expiresAt: Self.parseDate(start.expiresAt),
                    pollIntervalSeconds: max(start.pollIntervalSeconds, 2)
                )
                startPolling()
            } catch {
                errorMessage = friendlyError(error)
                qrLogin = nil
            }
        }
    }

    func cancelQRLogin() {
        cancelPolling()
        qrLogin = nil
    }

    private func startPolling() {
        cancelPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.qrLogin?.pollIntervalSeconds else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 2)) * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.pollOnce()
            }
        }
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        guard let state = qrLogin else { return }
        do {
            let rows: [TvLoginPollResult] = try await postArray(
                endpoint: Endpoint.pollTvLogin,
                body: ["p_code": state.code, "p_device_nonce": state.nonce]
            )
            guard let result = rows.first else { return }
            let status = result.status.lowercased()
            if var updated = qrLogin {
                updated.statusText = statusText(for: status, raw: result.status)
                if let exp = result.expiresAt.flatMap(Self.parseDate) { updated.expiresAt = exp }
                if let interval = result.pollIntervalSeconds { updated.pollIntervalSeconds = max(interval, 2) }
                qrLogin = updated
            }
            switch status {
            case "approved":
                cancelPolling()
                // Run the exchange in a fresh task: we're currently executing
                // inside the polling task that cancelPolling() just cancelled,
                // and URLSession aborts requests made from a cancelled task
                // with URLError.cancelled (-999). A new task is unaffected.
                Task { [weak self] in await self?.exchange() }
            case "expired", "used", "cancelled":
                cancelPolling()
                errorMessage = "This login code \(status). Try again."
                qrLogin = nil
            default:
                break // pending — keep polling
            }
        } catch {
            cancelPolling()
            errorMessage = friendlyError(error)
        }
    }

    private func exchange() async {
        guard let state = qrLogin, !exchangeInFlight else { return }
        exchangeInFlight = true
        defer { exchangeInFlight = false }
        do {
            // Parse tokens leniently: the exchange edge function may return them
            // flat or nested (session/data), so don't rely on a strict shape.
            let data = try await post(
                endpoint: Endpoint.exchangeTvLogin,
                body: ["code": state.code, "device_nonce": state.nonce]
            )
            let (access, refresh) = try Self.parseTokens(from: data)
            storeTokens(access: access, refresh: refresh)
            qrLogin = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Sign out / refresh

    func signOut() {
        cancelPolling()
        session = nil
        OrivioSession.clear()
        qrLogin = nil
        authState = .signedOut
    }

    @discardableResult
    func refreshSession() async -> Bool {
        guard let refreshToken = session?.refreshToken else { return false }
        do {
            let data = try await post(endpoint: Endpoint.refresh, body: ["refresh_token": refreshToken])
            let (access, refresh) = try Self.parseTokens(from: data)
            storeTokens(access: access, refresh: refresh)
            return true
        } catch {
            // A hard failure here means the refresh token is no longer valid.
            if case OrivioAuthError.http(let code, _) = error, [400, 401, 403].contains(code) {
                signOut()
            }
            return false
        }
    }

    private func storeTokens(access: String, refresh: String) {
        let newSession = OrivioSession(accessToken: access, refreshToken: refresh)
        newSession.save()
        session = newSession
        applySignedIn(from: access)
    }

    /// Current bearer token for authenticated data-sync calls.
    var accessToken: String? { session?.accessToken }

    /// The signed-in user's Supabase id (used to scope sync queries).
    var currentUserID: String? {
        if case .signedIn(let userID, _) = authState { return userID }
        return nil
    }

    // MARK: - Networking

    private func postArray<T: Decodable>(endpoint: String, body: [String: String]) async throws -> [T] {
        let data = try await post(endpoint: endpoint, body: body)
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func postObject<T: Decodable>(endpoint: String, body: [String: String]) async throws -> T {
        let data = try await post(endpoint: endpoint, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// POSTs a JSON body, retrying against the origin fallback host when the
    /// primary edge returns a 5xx or a connection error (matches Android).
    private func post(endpoint: String, body: [String: String]) async throws -> Data {
        do {
            return try await postAttempt(base: OrivioConfig.supabaseURL, endpoint: endpoint, body: body)
        } catch {
            guard OrivioConfig.supabaseFallbackURL != OrivioConfig.supabaseURL,
                  !OrivioConfig.supabaseFallbackURL.isEmpty,
                  shouldRetryFallback(error) else {
                throw error
            }
            return try await postAttempt(base: OrivioConfig.supabaseFallbackURL, endpoint: endpoint, body: body)
        }
    }

    private func postAttempt(base: String, endpoint: String, body: [String: String]) async throws -> Data {
        guard let url = URL(string: base.trimmedTrailingSlash + endpoint) else {
            throw OrivioAuthError.message("Bad backend URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(OrivioConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrivioAuthError.message("No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OrivioAuthError.http(http.statusCode, bodyText)
        }
        return data
    }

    private func shouldRetryFallback(_ error: Error) -> Bool {
        if case OrivioAuthError.http(let code, let body) = error {
            let retryCodes: Set<Int> = [408, 500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 530]
            return retryCodes.contains(code) || body.localizedCaseInsensitiveContains("cloudflare")
        }
        return (error as? URLError) != nil
    }

    // MARK: - Helpers

    private func statusText(for status: String, raw: String) -> String {
        switch status {
        case "approved": return "Approved — signing in…"
        case "pending": return "Waiting for approval on your phone…"
        case "expired": return "This code expired. Try again."
        default: return "Status: \(raw)"
        }
    }

    private func friendlyError(_ error: Error) -> String {
        switch error {
        case OrivioAuthError.http(let code, let body):
            // Prefer the backend's own error message when it sends one.
            if let serverMsg = Self.serverError(in: body) { return serverMsg }
            if code == 404 { return "Login service unavailable. Please try again later." }
            if code == 400 { return "The login request was rejected. Try again." }
            return "The server returned an error (\(code))."
        case OrivioAuthError.message(let message):
            return message
        case let urlError as URLError where urlError.code == .notConnectedToInternet:
            return "No internet connection."
        case let urlError as URLError where urlError.code == .timedOut:
            return "The server took too long to respond. Please try again."
        case let urlError as URLError:
            return "Network error (\(urlError.code.rawValue)). Please try again."
        default:
            return "Sign-in failed: \(error.localizedDescription)"
        }
    }

    /// Extracts a human-readable error from a JSON body like `{"error": "..."}`.
    private static func serverError(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["error_description", "error", "message", "msg"] {
            if let value = obj[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Pulls the access/refresh tokens out of an exchange/refresh response,
    /// tolerating both flat and nested (`session`/`data`) token shapes and
    /// surfacing any server-provided error message.
    private static func parseTokens(from data: Data) throws -> (access: String, refresh: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw OrivioAuthError.message("The sign-in response was not valid JSON.")
        }

        func tokens(in any: Any?) -> (String, String)? {
            guard let dict = any as? [String: Any] else { return nil }
            let access = (dict["access_token"] ?? dict["accessToken"]) as? String
            let refresh = (dict["refresh_token"] ?? dict["refreshToken"]) as? String
            if let access, let refresh, !access.isEmpty, !refresh.isEmpty { return (access, refresh) }
            return nil
        }

        if let found = tokens(in: root) { return found }
        if let dict = root as? [String: Any] {
            for key in ["error_description", "error", "message", "msg"] {
                if let value = dict[key] as? String, !value.isEmpty {
                    throw OrivioAuthError.message(value)
                }
            }
            for key in ["session", "data", "currentSession", "user"] {
                if let found = tokens(in: dict[key]) { return found }
                if let nested = dict[key] as? [String: Any], let found = tokens(in: nested["session"]) {
                    return found
                }
            }
        }
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
        throw OrivioAuthError.message("Unexpected sign-in response: \(snippet)")
    }

    /// The name this client registers with the Orivio account. `UIDevice.name`
    /// on tvOS is unreliable (can be empty or a stale/default value that shows
    /// up as a junk label like "New Folder" in the account's device list), so
    /// we always identify clearly as an Apple TV — appending the user's set
    /// name only when it's a real, distinct one.
    static var deviceLabel: String {
        let raw = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              !raw.localizedCaseInsensitiveContains("apple tv"),
              !raw.localizedCaseInsensitiveContains("new folder")
        else { return "Apple TV" }
        return "\(raw) (Apple TV)"
    }

    private static func generateDeviceNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum OrivioAuthError: Error {
    case http(Int, String)
    case message(String)
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
