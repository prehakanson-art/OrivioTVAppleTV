import Foundation

/// SIMKL account, persisted locally.
///
/// Deliberately simpler than `TraktStore`: SIMKL's PIN flow needs only the
/// public client id (no client secret), and the access token it returns does
/// not expire, so there is no refresh token to keep or rotate.
///
/// Per-profile accounts ride Trakt's `perProfileAccounts` switch — the SAME
/// UserDefaults key, so "Separate Trakt & SIMKL per profile" is one setting,
/// not two that can disagree. The machinery here is a subset of TraktStore's:
/// SIMKL logins never sync through the Orivio account, so there is no
/// `applyRemote`, no explicit-login flag guarding it, and no pollution of
/// other profiles' slots to clean up when the setting turns on.
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
    /// Seed Continue Watching from SIMKL's "watching" list.
    ///
    /// SIMKL has no playback-position API — there is nothing equivalent to
    /// Trakt's `/sync/playback`, so an exact resume point can't come from
    /// here. What it does have is a "watching" bucket with the episodes you
    /// have finished, which is enough to say WHICH episode is next; the row
    /// lands at the start of that episode. Off would mean a viewer whose only
    /// tracker is SIMKL sees an empty Continue Watching after a reinstall,
    /// which is the complaint this exists to answer.
    @Published var syncContinueWatching: Bool {
        didSet { UserDefaults.standard.set(syncContinueWatching, forKey: Self.continueKey) }
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
    private static let continueKey = "orivio.simkl.synccontinue.v1"
    /// Trakt's key, on purpose — one switch splits BOTH services per profile.
    private static let perProfileKey = "orivio.trakt.perProfileAccounts.v1"
    /// Same key ProfileStore uses, read directly so the scope is right from
    /// launch (mirrors TraktStore).
    private static let activeProfileKey = "orivio.profiles.active"

    init() {
        syncWatchHistory = UserDefaults.standard.object(forKey: Self.histKey) as? Bool ?? true
        syncWatchlist = UserDefaults.standard.object(forKey: Self.watchlistKey) as? Bool ?? true
        syncRatings = UserDefaults.standard.object(forKey: Self.ratingsKey) as? Bool ?? true
        syncContinueWatching = UserDefaults.standard.object(forKey: Self.continueKey) as? Bool ?? true
        perProfileAccounts = UserDefaults.standard.bool(forKey: Self.perProfileKey)
        profileID = UserDefaults.standard.object(forKey: Self.activeProfileKey) as? Int ?? 1
        let suffix = perProfileAccounts ? ".p\(profileID)" : ""
        accessToken = UserDefaults.standard.string(forKey: Self.tokenKey + suffix)
        username = UserDefaults.standard.string(forKey: Self.userKey + suffix)
    }

    /// Give every PROFILE its own SIMKL account. Shares Trakt's UserDefaults
    /// key; the Settings toggle (and the dev launch args) set both stores, so
    /// the two stay in step. As with Trakt, only the ACCOUNT is scoped — the
    /// sync switches stay device-wide.
    @Published var perProfileAccounts: Bool {
        didSet {
            guard perProfileAccounts != oldValue else { return }
            UserDefaults.standard.set(perProfileAccounts, forKey: Self.perProfileKey)
            if perProfileAccounts { adoptSharedLoginIntoPrimaryProfile() }
            reloadAccount()
        }
    }

    /// The profile whose SIMKL account is currently loaded.
    private(set) var profileID: Int

    private var scopeSuffix: String { perProfileAccounts ? ".p\(profileID)" : "" }
    private var scopedTokenKey: String { Self.tokenKey + scopeSuffix }
    private var scopedUserKey: String { Self.userKey + scopeSuffix }

    /// Splitting accounts hands the existing device-wide login to PROFILE 1
    /// (see TraktStore's version for why not the active profile), and only
    /// when profile 1 has nothing of its own. The device-wide copy is never
    /// touched, so turning the setting off always falls back to it. Unlike
    /// Trakt there is no cleanup pass: nothing ever wrote SIMKL tokens into
    /// other profiles' slots while the login was shared.
    private func adoptSharedLoginIntoPrimaryProfile() {
        guard let shared = UserDefaults.standard.string(forKey: Self.tokenKey),
              UserDefaults.standard.string(forKey: Self.tokenKey + ".p1") == nil else { return }
        UserDefaults.standard.set(shared, forKey: Self.tokenKey + ".p1")
        UserDefaults.standard.set(UserDefaults.standard.string(forKey: Self.userKey),
                                  forKey: Self.userKey + ".p1")
    }

    /// Forget a deleted profile's SIMKL account so a recycled profile id never
    /// inherits it.
    func forgetProfile(_ id: Int) {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey + ".p\(id)")
        UserDefaults.standard.removeObject(forKey: Self.userKey + ".p\(id)")
        if id == profileID { reloadAccount() }
    }

    /// Forget EVERY profile's SIMKL login plus the shared (unsuffixed) one.
    /// For an Orivio account switch: SIMKL tokens are never pushed to the
    /// account (unlike Trakt's), but the next user must not go on scrobbling
    /// into the previous user's SIMKL history from any profile slot.
    func forgetAllProfiles() {
        didSignInInteractively = false
        for key in [Self.tokenKey, Self.userKey] {
            UserDefaults.standard.removeObject(forKey: key)
            for id in 1...ProfileStore.maxProfiles {
                UserDefaults.standard.removeObject(forKey: key + ".p\(id)")
            }
        }
        reloadAccount()
    }

    /// Point the store at a profile. No-op unless per-profile accounts are on,
    /// in which case the previous profile's login is swapped out for this
    /// one's — which may be none at all, and that is the intended outcome.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        guard perProfileAccounts else { return }
        reloadAccount()
    }

    /// Load token + username from whichever scope is active now.
    private func reloadAccount() {
        accessToken = UserDefaults.standard.string(forKey: scopedTokenKey)
        username = UserDefaults.standard.string(forKey: scopedUserKey)
        lastSyncStatus = nil
    }

    var isSignedIn: Bool { accessToken != nil }

    func store(access: String) {
        accessToken = access
        UserDefaults.standard.set(access, forKey: scopedTokenKey)
    }

    /// Called by the PIN flow when a login completes on this device.
    func markSignedInHere() { didSignInInteractively = true }

    func setUsername(_ name: String?) {
        username = name
        UserDefaults.standard.set(name, forKey: scopedUserKey)
    }

    func signOut() {
        didSignInInteractively = false
        lastSyncStatus = nil
        accessToken = nil
        username = nil
        UserDefaults.standard.removeObject(forKey: scopedTokenKey)
        UserDefaults.standard.removeObject(forKey: scopedUserKey)
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
        /// SIMKL's list bucket for the row this item came from ("completed",
        /// "plantowatch", "watching", "hold", …). Read-side only; the sync
        /// manager needs it to tell a watched title from a planned one when
        /// the whole library is fetched in one request.
        var status: String?
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
    /// `status` filters SIMKL's list buckets ("completed", "plantowatch", …);
    /// nil fetches EVERY bucket in one request, with each item carrying its
    /// row's `status` — which is what the sync manager uses: it must see the
    /// whole library, not just one bucket, to know what is safe to push.
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
        // Decode straight into lightweight structs rather than
        // JSONSerialization's `[String: Any]`. That object graph is several
        // times the size of the response, and for a viewer whose SIMKL library
        // runs to tens of thousands of rows it was the single largest
        // allocation in the whole sync — large enough to be jetsammed on a
        // 3 GB box before a single item had been imported, which is exactly
        // the "huge library crashes on sync" report. Trakt's pulls, which
        // handle the same volume, already decode with JSONDecoder.
        //
        // Every field is read through `try?` so a type SIMKL changes (or a row
        // another client wrote oddly) yields nil for that field rather than
        // failing the WHOLE response — the tolerance the old `as?` casts gave.
        // A 200 with an unreadable body is an outage, not an empty library.
        guard let root = try? JSONDecoder().decode(AllItemsPayload.self, from: data) else {
            return nil
        }
        var out: [SyncItem] = []
        for (bucket, rows, appType) in [("movies", root.movies, "movie"),
                                        ("shows", root.shows, "series"),
                                        ("anime", root.anime, "series")] {
            guard let rows else { continue }
            for row in rows {
                // The title object sits under a key named for its kind.
                let node = row.movie ?? row.show ?? row.anime
                guard let node, let ids = node.ids else { continue }
                // SIMKL files anime FILMS in the same bucket as anime series,
                // and mapping the whole bucket to "series" typed a film as a
                // show with no season — which the history filter rejects on
                // both arms, so the film could never be recognised as
                // already-synced and was re-uploaded on every single sync.
                // `anime_type` is the row's own kind ("tv", "movie", "ova"…).
                let animeKind = node.animeType?.lowercased()
                let appType = (bucket == "anime" && animeKind == "movie") ? "movie" : appType
                let imdb = ids.imdb
                let tmdb = ids.tmdb
                guard imdb != nil || tmdb != nil else { continue }
                let title = node.title ?? ""
                let rating = row.userRating.map { Int($0) }
                let watched = row.lastWatchedAt.flatMap(parseDate)
                let listStatus = row.status

                guard appType == "series", let seasons = row.seasons, !seasons.isEmpty else {
                    out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                        rating: rating, watchedAt: watched, status: listStatus))
                    continue
                }
                // A show with a seasons tree expands to one item per watched
                // episode; the show-level row is kept too so ratings and
                // watchlist entries on the show itself survive.
                out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                    rating: rating, watchedAt: watched, status: listStatus))
                for season in seasons {
                    guard let number = season.number, let episodes = season.episodes else { continue }
                    for episode in episodes {
                        guard let epNumber = episode.number else { continue }
                        let at = episode.watchedAt.flatMap(parseDate) ?? watched
                        out.append(SyncItem(imdb: imdb, tmdb: tmdb, type: appType, title: title,
                                            season: number, episode: epNumber, watchedAt: at,
                                            status: listStatus))
                    }
                }
            }
        }
        return out
    }

    /// The `/sync/all-items` response, decoded straight into structs (see
    /// `allItems`). Optional fields and custom initialisers are deliberate:
    /// SIMKL's ids arrive as strings on some rows and numbers on others, and
    /// its seasons tree carries only the watched episodes, often without a
    /// `watched_at` of their own.
    private struct AllItemsPayload: Decodable {
        var movies: [Row]?
        var shows: [Row]?
        var anime: [Row]?

        enum CodingKeys: String, CodingKey { case movies, shows, anime }

        // Each bucket independently, so a malformed one (a shape SIMKL changed)
        // yields nil for THAT bucket and leaves the other two usable — the
        // tolerance the old `root[bucket] as? [[String: Any]] else continue`
        // gave. A synthesized init would fail the whole response instead.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            movies = try? c.decode([Row].self, forKey: .movies)
            shows = try? c.decode([Row].self, forKey: .shows)
            anime = try? c.decode([Row].self, forKey: .anime)
        }

        struct Row: Decodable {
            var status: String?
            var lastWatchedAt: String?
            var userRating: Double?
            var movie: Node?
            var show: Node?
            var anime: Node?
            var seasons: [Season]?

            enum CodingKeys: String, CodingKey {
                case status, movie, show, anime, seasons
                case lastWatchedAt = "last_watched_at"
                case userRating = "user_rating"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                status = try? c.decode(String.self, forKey: .status)
                lastWatchedAt = try? c.decode(String.self, forKey: .lastWatchedAt)
                // `decode(Double.self)` accepts an integer JSON number too.
                userRating = try? c.decode(Double.self, forKey: .userRating)
                movie = try? c.decode(Node.self, forKey: .movie)
                show = try? c.decode(Node.self, forKey: .show)
                anime = try? c.decode(Node.self, forKey: .anime)
                seasons = try? c.decode([Season].self, forKey: .seasons)
            }
        }

        struct Node: Decodable {
            var title: String?
            var ids: IDs?
            var animeType: String?

            enum CodingKeys: String, CodingKey {
                case title, ids
                case animeType = "anime_type"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = try? c.decode(String.self, forKey: .title)
                ids = try? c.decode(IDs.self, forKey: .ids)
                animeType = try? c.decode(String.self, forKey: .animeType)
            }
        }

        /// `ids.tmdb` is a STRING on the live API ("67195") and a number on
        /// some rows, so read both; an unparseable value is nil, never a throw.
        struct IDs: Decodable {
            var imdb: String?
            var tmdb: Int?

            enum CodingKeys: String, CodingKey { case imdb, tmdb }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                imdb = try? c.decode(String.self, forKey: .imdb)
                if let n = try? c.decode(Int.self, forKey: .tmdb) {
                    tmdb = n
                } else if let s = try? c.decode(String.self, forKey: .tmdb) {
                    tmdb = Int(s)
                } else {
                    tmdb = nil
                }
            }
        }

        struct Season: Decodable {
            var number: Int?
            var episodes: [Episode]?

            enum CodingKeys: String, CodingKey { case number, episodes }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                number = try? c.decode(Int.self, forKey: .number)
                episodes = try? c.decode([Episode].self, forKey: .episodes)
            }
        }

        struct Episode: Decodable {
            var number: Int?
            var watchedAt: String?

            enum CodingKeys: String, CodingKey {
                case number
                case watchedAt = "watched_at"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                number = try? c.decode(Int.self, forKey: .number)
                watchedAt = try? c.decode(String.self, forKey: .watchedAt)
            }
        }
    }

    /// GET /sync/activities — the tiny "what changed and when" endpoint SIMKL
    /// asks clients to hit before pulling `all-items`, which is the viewer's
    /// ENTIRE library. Returns the top-level "all" stamp as an OPAQUE token:
    /// compared for equality only, never parsed as a date — doing clock math
    /// against someone else's server invites timezone bugs for no benefit.
    /// nil on any failure, which callers must treat as "unknown → do sync".
    static func lastActivity(accessToken: String) async -> String? {
        struct Response: Decodable { let all: String? }
        guard let req = request("/sync/activities", bearer: accessToken) else { return nil }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return r.all
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
