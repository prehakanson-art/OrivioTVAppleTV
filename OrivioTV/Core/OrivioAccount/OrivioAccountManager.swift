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

    /// True when the CURRENT session came from someone actually signing in on
    /// this device, rather than from a token restored at launch.
    ///
    /// Both publish `.signedIn`, and the sync manager has to tell them apart:
    /// a restore must not drag a heavyweight full sync into app construction,
    /// but a real sign-in should bring the account's data down at once instead
    /// of leaving the viewer looking at an empty library until the next
    /// auto-sync tick.
    private(set) var didSignInInteractively = false

    // MARK: - Session restore

    private func restoreSession() {
        guard let stored = OrivioSession.load() else {
            authState = .signedOut
            return
        }
        session = stored
        didSignInInteractively = false
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

    /// Consecutive failed polls. A single blip must not end the login (see
    /// pollOnce); several in a row means something is actually wrong.
    private var pollFailures = 0
    private static let maxPollFailures = 5

    private func startPolling() {
        cancelPolling()
        pollFailures = 0
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
            pollFailures = 0
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
            // ONE transient error (Wi-Fi blip, a 5xx, an RPC cold start) used to
            // cancel polling while leaving the QR code on screen: the user
            // approved it on their phone and the TV — no longer asking — sat
            // there forever until it was backed out of. Keep polling; give up
            // only after several consecutive failures.
            pollFailures += 1
            guard pollFailures >= Self.maxPollFailures else {
                qrLogin?.statusText = "Trouble reaching the server — retrying…"
                return
            }
            cancelPolling()
            errorMessage = friendlyError(error)
            qrLogin = nil
        }
    }

    private func exchange() async {
        guard let state = qrLogin, !exchangeInFlight else { return }
        exchangeInFlight = true
        defer { exchangeInFlight = false }
        // Same generation guard as performRefresh: this is the other path that
        // writes tokens after an `await`, so a sign-out landing mid-exchange
        // must not be undone by the response arriving afterwards.
        let generation = authGeneration
        do {
            // Parse tokens leniently: the exchange edge function may return them
            // flat or nested (session/data), so don't rely on a strict shape.
            let data = try await post(
                endpoint: Endpoint.exchangeTvLogin,
                body: ["code": state.code, "device_nonce": state.nonce]
            )
            let (access, refresh) = try Self.parseTokens(from: data)
            guard generation == authGeneration else {
                NSLog("[OrivioAuth] discarding a QR exchange that completed after sign-out")
                return
            }
            // Someone just signed in on this device — see
            // `didSignInInteractively`. Set BEFORE `storeTokens`, which is what
            // publishes `.signedIn` and wakes the sync manager.
            didSignInInteractively = true
            storeTokens(access: access, refresh: refresh)
            qrLogin = nil
        } catch {
            guard generation == authGeneration else { return }
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Sign out / refresh

    func signOut() {
        cancelPolling()
        // Retire every token-writing operation that is already in flight.
        //
        // Sign-out used to clear the session and publish `.signedOut` while
        // leaving `refreshTask` running. A refresh already past its `await`
        // then called `storeTokens`, which saved a NEW session and flipped the
        // state back to signed-in — with the sync bookkeeping already reset,
        // so the account came back half-retired. Cancelling alone is not
        // enough (the task may be past every cancellation point), so the
        // generation is what actually makes the completion a no-op: any
        // token-writing continuation started before this bump is ignored.
        authGeneration &+= 1
        didSignInInteractively = false
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        OrivioSession.clear()
        qrLogin = nil
        authState = .signedOut
    }

    /// Bumped by every sign-out. An async operation that will end by writing
    /// tokens captures this first and refuses to write if it no longer matches
    /// — the user signed out while it was in flight, and resurrecting their
    /// session is never the right answer.
    private var authGeneration = 0

    /// The in-flight refresh, if any. Supabase ROTATES the refresh token on
    /// every use, and every sync call that meets a 401 calls this — so a token
    /// expiring mid-sync fired several refreshes with the same refresh token at
    /// once. The first won; the rest got a 400 for a token the server had
    /// already rotated away and, reading that as "your session is dead",
    /// signed the user out. Concurrent callers now share one refresh.
    /// (Same serialization TraktSyncManager.validToken() uses.)
    private var refreshTask: Task<Bool, Never>?

    @discardableResult
    func refreshSession() async -> Bool {
        if let existing = refreshTask { return await existing.value }
        guard session?.refreshToken != nil else { return false }
        let generation = authGeneration
        let task = Task { [weak self] () -> Bool in
            await self?.performRefresh(generation: generation) ?? false
        }
        refreshTask = task
        let result = await task.value
        // Only the generation that owns this task may clear the slot. A
        // sign-out has already cancelled and nilled it, and a sign-in after
        // that may have started its own refresh — clearing unconditionally
        // would drop THAT task's handle and let a second concurrent refresh
        // burn the rotated token, which is the failure this serialization
        // exists to prevent.
        if generation == authGeneration { refreshTask = nil }
        return result
    }

    private func performRefresh(generation: Int) async -> Bool {
        guard let refreshToken = session?.refreshToken else { return false }
        do {
            let data = try await post(endpoint: Endpoint.refresh, body: ["refresh_token": refreshToken])
            let (access, refresh) = try Self.parseTokens(from: data)
            // The user signed out while this was in flight. Storing the new
            // tokens here is what used to UNDO the sign-out: it wrote a fresh
            // session to disk and republished `.signedIn`.
            guard generation == authGeneration else {
                NSLog("[OrivioAuth] discarding a refresh that completed after sign-out")
                return false
            }
            storeTokens(access: access, refresh: refresh)
            return true
        } catch {
            // A hard failure here means the refresh token is no longer valid.
            // Nothing to sign out of if the user already did it themselves.
            guard generation == authGeneration else { return false }
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
