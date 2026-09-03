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

    /// Two-way watch-history / watched-badge sync with SIMKL.
    @Published var syncWatchHistory: Bool {
        didSet { UserDefaults.standard.set(syncWatchHistory, forKey: Self.histKey) }
    }
    /// Two-way sync of the Library with SIMKL's plan-to-watch list.
    @Published var syncWatchlist: Bool {
        didSet { UserDefaults.standard.set(syncWatchlist, forKey: Self.watchlistKey) }
    }
    /// Two-way sync of personal star ratings with SIMKL.
    @Published var syncRatings: Bool {
        didSet { UserDefaults.standard.set(syncRatings, forKey: Self.ratingsKey) }
    }

    /// Last full-sync outcome, shown in Settings → Trakt & SIMKL.
    @Published private(set) var lastSyncStatus: String?
    func setSyncStatus(_ s: String?) { lastSyncStatus = s }

    /// Fired when a SIMKL sync setting changes, so the manager can react.
    var onSyncSettingChange: (() -> Void)?

    /// True when THIS session's login was completed here, just now, rather
    /// than restored from disk at launch. The manager syncs immediately in
    /// that case (someone is watching and waiting) and defers the launch case
    /// behind the first screen, exactly as the Trakt manager does.
    private(set) var didSignInInteractively = false

    private static let tokenKey = "orivio.simkl.token.v1"
    private static let userKey = "orivio.simkl.user.v1"
    private static let histKey = "orivio.simkl.synchistory.v1"
    private static let watchlistKey = "orivio.simkl.syncwatchlist.v1"
    private static let ratingsKey = "orivio.simkl.syncratings.v1"

    init() {
        syncWatchHistory = UserDefaults.standard.object(forKey: Self.histKey) as? Bool ?? true
        syncWatchlist = UserDefaults.standard.object(forKey: Self.watchlistKey) as? Bool ?? true
        syncRatings = UserDefaults.standard.object(forKey: Self.ratingsKey) as? Bool ?? true
        accessToken = UserDefaults.standard.string(forKey: Self.tokenKey)
        username = UserDefaults.standard.string(forKey: Self.userKey)
    }

    var isSignedIn: Bool { accessToken != nil }

    func store(access: String) {
        accessToken = access
        UserDefaults.standard.set(access, forKey: Self.tokenKey)
    }

    /// Called by the PIN flow when a login completes on this device.
    func markSignedInHere() { didSignInInteractively = true }

    func setUsername(_ name: String?) {
        username = name
        UserDefaults.standard.set(name, forKey: Self.userKey)
    }

    func signOut() {
        didSignInInteractively = false
        lastSyncStatus = nil
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
    private static func request(_ path: String, method: String = "GET",
                                bearer: String? = nil) -> URLRequest? {
        guard let url = URL(string: base + path) else {
            NSLog("[OrivioSimkl] unusable request path %@", path)
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
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

// MARK: - Sync

extension SimklService {
    /// One title (or one episode of one title) crossing the SIMKL boundary.
    ///
    /// Deliberately the same shape as `TraktService.SyncItem` so the two sync
    /// managers map to and from the local stores identically — the difference
    /// between the services is in the wire format, not in what an item is.
    struct SyncItem {
        var imdb: String?
        var tmdb: Int?
        /// "movie" or "series", in the app's vocabulary — NOT SIMKL's.
        var type: String
        var title: String = ""
        var season: Int?
        var episode: Int?
        var rating: Int?
        var watchedAt: Date?
    }

    /// SIMKL groups everything under `movies` / `shows`. The app says
    /// "movie" / "series"; anime is a SIMKL-side classification the app has no
    /// concept of, and SIMKL accepts anime under `shows` on write.
    private static func isShow(_ type: String) -> Bool {
        type == "series" || type == "tv" || type == "show" || type == "anime"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func idPayload(_ item: SyncItem) -> [String: Any]? {
        var ids: [String: Any] = [:]
        if let imdb = item.imdb, !imdb.isEmpty { ids["imdb"] = imdb }
        if let tmdb = item.tmdb { ids["tmdb"] = String(tmdb) }
        return ids.isEmpty ? nil : ids
    }

    /// Build SIMKL's `{"movies":[…],"shows":[…]}` envelope.
    ///
    /// Episodes of the same show are folded into ONE show entry with a
    /// `seasons` tree — SIMKL matches on the show's ids, so sending a separate
    /// show object per episode would make it resolve the same title over and
    /// over for a single binge.
    private static func envelope(_ items: [SyncItem], includeRating: Bool = false,
                                 listTarget: String? = nil) -> [String: Any] {
        var movies: [[String: Any]] = []
        // Preserve the caller's ordering; a dictionary alone would not.
        var showOrder: [String] = []
        var shows: [String: [String: Any]] = [:]
        // showKey → season number → episode number → episode payload
        var showSeasons: [String: [Int: [Int: [String: Any]]]] = [:]

        for item in items {
            guard let ids = idPayload(item) else { continue }
            var entry: [String: Any] = ["ids": ids]
            if !item.title.isEmpty { entry["title"] = item.title }
            if includeRating, let rating = item.rating { entry["rating"] = rating }
            if let listTarget { entry["to"] = listTarget }
            if let watchedAt = item.watchedAt { entry["watched_at"] = iso.string(from: watchedAt) }

            guard isShow(item.type) else { movies.append(entry); continue }

            // Key on the ids, not the title — two entries for one show must
            // merge even when only one of them carried a title.
            let key = (item.imdb ?? "") + "|" + (item.tmdb.map(String.init) ?? "")
            if shows[key] == nil {
                shows[key] = entry
                showOrder.append(key)
            } else if let title = entry["title"], shows[key]?["title"] == nil {
                shows[key]?["title"] = title
            }
            guard let season = item.season, let episode = item.episode else { continue }
            var payload: [String: Any] = ["number": episode]
            if let watchedAt = item.watchedAt { payload["watched_at"] = iso.string(from: watchedAt) }
            showSeasons[key, default: [:]][season, default: [:]][episode] = payload
        }

        var showList: [[String: Any]] = []
        for key in showOrder {
            guard var show = shows[key] else { continue }
            if let seasons = showSeasons[key] {
                show["seasons"] = seasons.keys.sorted().map { number -> [String: Any] in
                    let episodes = seasons[number] ?? [:]
                    return ["number": number,
                            "episodes": episodes.keys.sorted().compactMap { episodes[$0] }]
                }
                // A show entry carrying seasons must NOT also carry a
                // whole-show watched_at: that marks every episode ever aired.
                show.removeValue(forKey: "watched_at")
            }
            showList.append(show)
        }

        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies }
        if !showList.isEmpty { body["shows"] = showList }
        return body
    }

    /// POST an envelope. Returns whether SIMKL accepted it.
    private static func post(_ path: String, body: [String: Any], accessToken: String) async -> Bool {
        guard !body.isEmpty else { return true }
        guard var req = request(path, method: "POST", bearer: accessToken) else { return false }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            NSLog("[OrivioSimkl] POST %@ failed — network", path)
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            NSLog("[OrivioSimkl] POST %@ → HTTP %d %@", path, http.statusCode,
                  serviceMessage(data) ?? "")
            return false
        }
        return true
    }

    // MARK: Reads

    /// SIMKL's library for one media type, flattened into `SyncItem`s.
    ///
    /// Returns nil when the FETCH failed, which callers must not confuse with
    /// an empty library — an outage read as "SIMKL has nothing" would make the
    /// push phase re-upload the user's entire history.
    ///
    /// `status` filters SIMKL's list buckets: "completed" is watch history,
    /// "plantowatch" is the watchlist.
    static func allItems(type: String, status: String?, accessToken: String) async -> [SyncItem]? {
        var path = "/sync/all-items/\(type)"
        if let status { path += "/\(status)" }
        path += "?extended=full"
        guard let req = request(path, bearer: accessToken) else { return nil }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        // SIMKL answers an empty bucket with 200 and no body at all.
        guard (200..<300).contains(http.statusCode) else {
            NSLog("[OrivioSimkl] all-items %@ → HTTP %d", path, http.statusCode)
            return nil
        }
        guard !data.isEmpty else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A 200 with an unreadable body is an outage, not an empty library.
            return nil
        }
        var out: [SyncItem] = []
        for (bucket, appType) in [("movies", "movie"), ("shows", "series"), ("anime", "series")] {
            guard let rows = root[bucket] as? [[String: Any]] else { continue }
            for row in rows {
                // The title object sits under a key named for its kind.
                let node = (row["movie"] ?? row["show"] ?? row["anime"]) as? [String: Any]
                guard let node, let ids = node["ids"] as? [String: Any] else { continue }
                let imdb = ids["imdb"] as? String
                let tmdb = (ids["tmdb"] as? Int) ?? (ids["tmdb"] as? String).flatMap(Int.init)
                guard imdb != nil || tmdb != nil else { continue }
                let title = (node["title"] as? String) ?? ""
                let rating = (row["user_rating"] as? Int)
                    ?? (row["user_rating"] as? Double).map(Int.init)
                let watched = (row["last_watched_at"] as? String).flatMap(parseDate)

                guard appType == "series", let seasons = row["seasons"] as? [[String: Any]],
                      !seasons.isEmpty else {
                    out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                        rating: rating, watchedAt: watched))
                    continue
                }
                // A show with a seasons tree expands to one item per watched
                // episode; the show-level row is kept too so ratings and
                // watchlist entries on the show itself survive.
                out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                    rating: rating, watchedAt: watched))
                for season in seasons {
                    guard let number = season["number"] as? Int,
                          let episodes = season["episodes"] as? [[String: Any]] else { continue }
                    for episode in episodes {
                        guard let epNumber = episode["number"] as? Int else { continue }
                        let at = (episode["watched_at"] as? String).flatMap(parseDate) ?? watched
                        out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                            season: number, episode: epNumber, watchedAt: at))
                    }
                }
            }
        }
        return out
    }

    /// What a token is worth right now.
    enum TokenState { case ok, unauthorized, unknown }

    /// Probe the token. Only worth calling once a real request has already
    /// failed: a failed library fetch and a revoked login are indistinguishable
    /// from the caller's side, and telling someone "couldn't reach SIMKL" when
    /// the truth is "sign in again" sends them to check their network forever.
    static func checkToken(_ accessToken: String) async -> TokenState {
        guard let req = request("/users/settings", bearer: accessToken) else { return .unknown }
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return .unknown }
        if (200..<300).contains(http.statusCode) { return .ok }
        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
        return .unknown
    }

    /// SIMKL stamps vary ("2024-01-02T03:04:05Z" and a space-separated form),
    /// so try the strict parser first and fall back rather than dropping the
    /// item's date entirely.
    private static func parseDate(_ raw: String) -> Date? {
        if let d = iso.date(from: raw) { return d }
        let flexible = ISO8601DateFormatter()
        flexible.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = flexible.date(from: raw) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: raw)
    }

    // MARK: Writes

    static func addToHistory(_ items: [SyncItem], accessToken: String) async -> Bool {
        await post("/sync/history", body: envelope(items), accessToken: accessToken)
    }

    static func removeFromHistory(_ items: [SyncItem], accessToken: String) async -> Bool {
        await post("/sync/history/remove", body: envelope(items), accessToken: accessToken)
    }

    /// The watchlist is SIMKL's "plan to watch" list.
    static func addToWatchlist(_ items: [SyncItem], accessToken: String) async -> Bool {
        await post("/sync/add-to-list", body: envelope(items, listTarget: "plantowatch"),
                   accessToken: accessToken)
    }

    // NOTE: there is deliberately no `removeFromWatchlist`.
    //
    // SIMKL has no watchlist-only removal. Its model is ONE library where a
    // title carries a status, and the only documented way off a list is
    // `/sync/history/remove`, which drops the title from the library
    // altogether — watch history included. Trakt's `/sync/watchlist/remove`
    // touches only the watchlist, which is why the Trakt manager can push
    // removals and this one must not: taking a finished show out of the local
    // Library would silently erase every episode of it from the viewer's
    // SIMKL history. Additions sync; removals stay local. See the matching
    // note in SimklSyncManager.

    static func addRatings(_ items: [SyncItem], accessToken: String) async -> Bool {
        await post("/sync/ratings", body: envelope(items, includeRating: true),
                   accessToken: accessToken)
    }

    static func removeRatings(_ items: [SyncItem], accessToken: String) async -> Bool {
        await post("/sync/ratings/remove", body: envelope(items), accessToken: accessToken)
    }

    /// Dev only (`-simklEnvelopeReport`): render the request body the sync
    /// would send, so the wire format can be checked without a SIMKL account.
    /// The envelope is the one piece of this integration with no other way to
    /// verify it — a mis-shaped `seasons` tree silently marks the wrong
    /// episodes, and SIMKL answers a malformed body with the same 200 it gives
    /// a good one.
    static func debugEnvelope(_ items: [SyncItem], includeRating: Bool = false,
                              listTarget: String? = nil) -> String {
        let body = envelope(items, includeRating: includeRating, listTarget: listTarget)
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "<unencodable>" }
        return text
    }
}
