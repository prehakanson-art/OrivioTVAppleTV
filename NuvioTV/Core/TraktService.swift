import Foundation

/// Trakt account + settings, persisted locally.
///
/// The client id AND secret are recovered, live-validated public values
/// (extracted from the CloudStream-based APK's BuildConfig and verified against
/// Trakt's `/oauth/token` endpoint — a wrong secret returns `invalid_client`,
/// this pair returns `invalid_grant`). So device-code login completes end to
/// end without any user-supplied secret.
@MainActor
final class TraktStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var username: String?
    @Published var scrobbleEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobbleEnabled, forKey: Self.scrobbleKey) }
    }
    /// Two-way watch-history / watched-badge sync with Trakt.
    @Published var syncWatchHistory: Bool {
        didSet { UserDefaults.standard.set(syncWatchHistory, forKey: Self.histKey) }
    }
    /// Pull Trakt playback progress into Continue Watching.
    @Published var syncPlayback: Bool {
        didSet { UserDefaults.standard.set(syncPlayback, forKey: Self.playbackKey) }
    }
    /// Two-way sync of the Library with the Trakt watchlist.
    @Published var syncWatchlist: Bool {
        didSet { UserDefaults.standard.set(syncWatchlist, forKey: Self.watchlistKey) }
    }
    /// Two-way sync of personal star ratings with Trakt.
    @Published var syncRatings: Bool {
        didSet { UserDefaults.standard.set(syncRatings, forKey: Self.ratingsKey) }
    }
    /// Last full-sync outcome, shown in Settings → Trakt.
    @Published private(set) var lastSyncStatus: String?
    /// Fired when a Trakt sync-related setting changes, so the manager can react.
    var onTraktSettingChange: (() -> Void)?
    /// Fired when the user confirms clearing Trakt's continue-watching list.
    /// Wired to TraktSyncManager, which owns the token and the API calls.
    var onClearContinueWatching: (() -> Void)?
    func setSyncStatus(_ s: String?) { lastSyncStatus = s }
    /// User-supplied client secret (empty until recovered).
    @Published var clientSecret: String {
        didSet { UserDefaults.standard.set(clientSecret, forKey: Self.secretKey) }
    }

    /// Recovered + validated public client id (header `trakt-api-key`).
    /// `nonisolated`: an immutable constant safe to read from the nonisolated
    /// networking statics (silences the main-actor isolation warning).
    nonisolated static let clientID = Secrets.traktClientID
    /// Recovered + validated public client secret (device-code token exchange).
    nonisolated static let clientSecret = Secrets.traktClientSecret

    private static let tokenKey = "nuvio.trakt.tokens.v1"
    private static let userKey = "nuvio.trakt.user.v1"
    private static let perProfileKey = "nuvio.trakt.perProfileAccounts.v1"
    private static let explicitLoginKey = "nuvio.trakt.signedInHere.v1"
    /// Same key ProfileStore uses, read directly so the scope is right from
    /// launch even when signed out of the Orivio account (the sync manager,
    /// which scopes the other stores, only runs while signed in).
    private static let activeProfileKey = "nuvio.profiles.active"
    private static let scrobbleKey = "nuvio.trakt.scrobble.v1"
    private static let secretKey = "nuvio.trakt.secret.v1"
    private static let histKey = "nuvio.trakt.synchistory.v1"
    private static let playbackKey = "nuvio.trakt.syncplayback.v1"
    private static let watchlistKey = "nuvio.trakt.syncwatchlist.v1"
    private static let ratingsKey = "nuvio.trakt.syncratings.v1"

    private struct Tokens: Codable { let access: String; let refresh: String }

    init() {
        scrobbleEnabled = UserDefaults.standard.object(forKey: Self.scrobbleKey) as? Bool ?? true
        syncWatchHistory = UserDefaults.standard.object(forKey: Self.histKey) as? Bool ?? true
        syncPlayback = UserDefaults.standard.object(forKey: Self.playbackKey) as? Bool ?? true
        syncWatchlist = UserDefaults.standard.object(forKey: Self.watchlistKey) as? Bool ?? true
        syncRatings = UserDefaults.standard.object(forKey: Self.ratingsKey) as? Bool ?? true
        clientSecret = UserDefaults.standard.string(forKey: Self.secretKey) ?? ""
        perProfileAccounts = UserDefaults.standard.bool(forKey: Self.perProfileKey)
        profileID = UserDefaults.standard.object(forKey: Self.activeProfileKey) as? Int ?? 1
        let suffix = perProfileAccounts ? ".p\(profileID)" : ""
        username = UserDefaults.standard.string(forKey: Self.userKey + suffix)
        if let data = UserDefaults.standard.data(forKey: Self.tokenKey + suffix),
           let tokens = try? JSONDecoder().decode(Tokens.self, from: data) {
            accessToken = tokens.access
            refreshToken = tokens.refresh
        }
    }

    /// Give every PROFILE its own Trakt account instead of sharing one across
    /// the device. Off = the login is device-wide, as it has always been.
    ///
    /// Only the ACCOUNT (tokens + username) is scoped. The sync switches and
    /// the client secret stay device-wide: the secret is an app credential
    /// rather than a person's login, and scoping the switches would silently
    /// reset them per profile.
    ///
    /// The account backend already stores these per profile — the credentials
    /// push sends `p_profile_id` — so this aligns local storage with what sync
    /// was doing anyway.
    @Published var perProfileAccounts: Bool {
        didSet {
            guard perProfileAccounts != oldValue else { return }
            UserDefaults.standard.set(perProfileAccounts, forKey: Self.perProfileKey)
            if perProfileAccounts {
                // Turning it ON: whoever is using the app now keeps the login
                // that was already set up, and the other profiles start empty.
                // The device-wide copy is left untouched, so turning it back
                // off restores the shared account exactly as it was.
                if UserDefaults.standard.data(forKey: scopedTokenKey) == nil,
                   let shared = UserDefaults.standard.data(forKey: Self.tokenKey) {
                    UserDefaults.standard.set(shared, forKey: scopedTokenKey)
                    UserDefaults.standard.set(UserDefaults.standard.string(forKey: Self.userKey),
                                              forKey: scopedUserKey)
                }
                // Whoever is using the app now owns the login it ends up with,
                // however it got there — inherited from the shared account or
                // already sitting in this profile's slot. Without this the
                // profile holds tokens it never "claimed", and the account is
                // then refused permission to refresh them.
                if UserDefaults.standard.data(forKey: scopedTokenKey) != nil {
                    signedInHere = true
                }
            }
            reloadAccount()
        }
    }

    /// The profile whose Trakt account is currently loaded.
    private(set) var profileID: Int

    private var scopeSuffix: String { perProfileAccounts ? ".p\(profileID)" : "" }
    private var scopedTokenKey: String { Self.tokenKey + scopeSuffix }
    private var scopedUserKey: String { Self.userKey + scopeSuffix }
    private var scopedExplicitKey: String { Self.explicitLoginKey + scopeSuffix }

    /// Whether THIS profile connected Trakt itself.
    ///
    /// The account stores Trakt credentials per profile, but while the login
    /// was shared every profile switch pushed the same tokens into whichever
    /// profile was active — so every profile's row on the server now holds the
    /// same account. Without this, turning per-profile accounts on changed
    /// nothing visible: each profile signed straight back in from its polluted
    /// row. A profile with no explicit login here ignores what the account
    /// offers and shows the connect screen, which is the point of the setting.
    private var signedInHere: Bool {
        get { UserDefaults.standard.bool(forKey: scopedExplicitKey) }
        set { UserDefaults.standard.set(newValue, forKey: scopedExplicitKey) }
    }

    /// Called by the device-code flow when a login completes on this profile.
    func markSignedInHere() { signedInHere = true }

    /// Forget a deleted profile's Trakt account so a recycled profile id never
    /// inherits it.
    func forgetProfile(_ id: Int) {
        for key in [Self.tokenKey, Self.userKey, Self.explicitLoginKey] {
            UserDefaults.standard.removeObject(forKey: key + ".p\(id)")
        }
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

    /// Load tokens + username from whichever scope is active now.
    private func reloadAccount() {
        applyingRemote = true
        defer { applyingRemote = false }
        username = UserDefaults.standard.string(forKey: scopedUserKey)
        if let data = UserDefaults.standard.data(forKey: scopedTokenKey),
           let tokens = try? JSONDecoder().decode(Tokens.self, from: data) {
            accessToken = tokens.access
            refreshToken = tokens.refresh
        } else {
            accessToken = nil
            refreshToken = nil
        }
        lastSyncStatus = nil
    }

    var isSignedIn: Bool { accessToken != nil }
    var hasSecret: Bool { !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Fired on a local sign-in/out/username change so account sync can push the
    /// Trakt tokens to the shared `provider_credentials` table (the same place
    /// the Android app keeps them). Suppressed while applying a remote pull.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    func store(access: String, refresh: String) {
        accessToken = access
        refreshToken = refresh
        if let data = try? JSONEncoder().encode(Tokens(access: access, refresh: refresh)) {
            UserDefaults.standard.set(data, forKey: scopedTokenKey)
        }
        if !applyingRemote { onLocalChange?() }
    }

    func setUsername(_ name: String?) {
        username = name
        UserDefaults.standard.set(name, forKey: scopedUserKey)
        if !applyingRemote { onLocalChange?() }
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        username = nil
        UserDefaults.standard.removeObject(forKey: scopedTokenKey)
        UserDefaults.standard.removeObject(forKey: scopedUserKey)
        signedInHere = false
        if !applyingRemote { onLocalChange?() }
    }

    /// Apply Trakt tokens pulled from the account without echoing them back up.
    /// Only applies a real remote login (non-empty tokens) that differs from the
    /// local one. Deliberately does NOT sign out locally when the account has no
    /// Trakt row — absence usually means "never synced from this device", not
    /// "signed out everywhere".
    func applyRemote(access: String?, refresh: String?, username: String?) {
        // Per-profile mode: only a profile that connected Trakt itself accepts
        // an account-supplied login. See `signedInHere`.
        guard !perProfileAccounts || signedInHere else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if let access, let refresh, !access.isEmpty {
            guard access != accessToken || refresh != refreshToken else {
                if let username, username != self.username { setUsername(username) }
                return
            }
            store(access: access, refresh: refresh)
            if let username { setUsername(username) }
        }
    }
}

// MARK: - Service

struct TraktDeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: Int
    let expiresIn: Int
}

enum TraktPollResult {
    case pending
    case authorized(access: String, refresh: String)
    case needsSecret
    case expired
    case failed(String)
}

/// Thin Trakt API client covering device auth + scrobbling.
enum TraktService {
    private static let base = "https://api.trakt.tv"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    private static func request(_ path: String, method: String = "GET", bearer: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktStore.clientID, forHTTPHeaderField: "trakt-api-key")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: Device auth

    /// Start device login. Needs only the client id, so this always works.
    static func startDeviceCode() async throws -> TraktDeviceCode {
        struct Response: Decodable {
            let device_code: String; let user_code: String
            let verification_url: String; let expires_in: Int; let interval: Int
        }
        var req = request("/oauth/device/code", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": TraktStore.clientID])
        let (data, _) = try await session.data(for: req)
        let r = try JSONDecoder().decode(Response.self, from: data)
        return TraktDeviceCode(
            deviceCode: r.device_code, userCode: r.user_code,
            verificationURL: r.verification_url, interval: r.interval, expiresIn: r.expires_in
        )
    }

    /// Poll for the token. Requires the client secret; without it, returns
    /// `.needsSecret` so the UI can explain the blocker.
    static func pollToken(deviceCode: String, clientSecret: String) async -> TraktPollResult {
        let secret = clientSecret.trimmingCharacters(in: .whitespaces)
        guard !secret.isEmpty else { return .needsSecret }
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String }
        var req = request("/oauth/device/token", method: "POST")
        let body = ["code": deviceCode, "client_id": TraktStore.clientID, "client_secret": secret]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            return .failed("Network error")
        }
        switch http.statusCode {
        case 200:
            guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                return .failed("Bad token response")
            }
            return .authorized(access: token.access_token, refresh: token.refresh_token)
        case 400: return .pending            // authorization pending
        case 404: return .failed("Invalid device code")
        case 409: return .pending            // already used, keep polling briefly
        case 410: return .expired            // code expired
        case 418: return .failed("Login denied")
        case 429: return .pending            // slow down
        default: return .failed("Trakt returned HTTP \(http.statusCode)")
        }
    }

    /// Fetch the signed-in user's username for display.
    static func fetchUsername(accessToken: String) async -> String? {
        struct Settings: Decodable { struct User: Decodable { let username: String? }; let user: User? }
        let req = request("/users/settings", bearer: accessToken)
        guard let (data, _) = try? await session.data(for: req),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        return settings.user?.username
    }

    // MARK: Comments

    /// A public Trakt comment for the Detail screen.
    struct Comment: Identifiable, Hashable {
        let id: Int
        let user: String
        let text: String
        let likes: Int
        let spoiler: Bool
    }

    /// Fetch public comments for an IMDB-identified title (most-liked first).
    /// No auth needed — the api-key header is enough. Best-effort.
    static func comments(imdbID: String, type: String, limit: Int = 20) async -> [Comment] {
        guard imdbID.hasPrefix("tt") else { return [] }
        let kind = (type == "series" || type == "tv") ? "shows" : "movies"
        struct CommentDTO: Decodable {
            struct User: Decodable { let username: String? }
            let id: Int; let comment: String; let spoiler: Bool?; let likes: Int?; let user: User?
        }
        let req = request("/\(kind)/\(imdbID)/comments/likes?limit=\(limit)")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let dtos = try? JSONDecoder().decode([CommentDTO].self, from: data) else { return [] }
        return dtos.map {
            Comment(id: $0.id, user: $0.user?.username ?? "Someone",
                    text: $0.comment, likes: $0.likes ?? 0, spoiler: $0.spoiler ?? false)
        }
    }

    // MARK: Scrobble

    enum ScrobbleAction: String { case start, stop, pause }

    /// Scrobble progress for an IMDB-identified item. `progress` is 0–100.
    /// Best-effort: failures are swallowed (scrobbling must never block play).
    @discardableResult
    static func scrobble(
        action: ScrobbleAction,
        imdbID: String,
        type: String,
        season: Int?,
        episode: Int?,
        progress: Double,
        accessToken: String
    ) async -> Bool {
        // Only tt… ids map cleanly to Trakt; skip anything else (e.g. tmdb:).
        guard imdbID.hasPrefix("tt") else { return false }
        var body: [String: Any] = ["progress": max(0, min(100, progress))]
        if type == "series" || type == "tv", let season, let episode {
            body["show"] = ["ids": ["imdb": imdbID]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["imdb": imdbID]]
        }
        var req = request("/scrobble/\(action.rawValue)", method: "POST", bearer: accessToken)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: Token refresh

    /// Exchange the refresh token for a fresh access+refresh pair. Trakt access
    /// tokens last ~3 months; this keeps the link alive without re-login.
    static func refreshToken(_ refresh: String) async -> (access: String, refresh: String)? {
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String }
        var req = request("/oauth/token", method: "POST")
        let body: [String: Any] = [
            "refresh_token": refresh,
            "client_id": TraktStore.clientID,
            "client_secret": TraktStore.clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let t = try? JSONDecoder().decode(TokenResponse.self, from: data) else { return nil }
        return (t.access_token, t.refresh_token)
    }

    // MARK: Sync (watch history + playback progress)

    /// One synced item, normalized across movies and episodes.
    struct SyncItem: Hashable {
        var imdb: String? = nil
        var tmdb: Int? = nil
        var type: String        // "movie" | "series"
        var title: String
        var season: Int? = nil
        var episode: Int? = nil
        var progress: Double? = nil    // playback only, 0–100
        var watchedAt: Date? = nil     // history / paused_at
        var rating: Int? = nil         // ratings sync, 1–10
        /// Trakt's row id for a /sync/playback item — required to DELETE that
        /// row when the user removes it from Continue Watching locally.
        var playbackID: Int? = nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private struct TraktIDs: Decodable { let imdb: String?; let tmdb: Int? }
    private struct TraktMedia: Decodable { let title: String?; let ids: TraktIDs? }

    /// Full watched history (movies + shows/episodes), for the two-way merge.
    static func watchedHistory(accessToken: String) async -> [SyncItem] {
        var out: [SyncItem] = []

        struct WatchedMovie: Decodable { let last_watched_at: String?; let movie: TraktMedia? }
        if let (data, code) = await get("/sync/watched/movies", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([WatchedMovie].self, from: data) {
            for r in rows where r.movie != nil {
                out.append(SyncItem(
                    imdb: r.movie?.ids?.imdb, tmdb: r.movie?.ids?.tmdb, type: "movie",
                    title: r.movie?.title ?? "", season: nil, episode: nil,
                    progress: nil, watchedAt: parseDate(r.last_watched_at)))
            }
        }

        struct WatchedShow: Decodable {
            struct S: Decodable { let number: Int?; let episodes: [E]? }
            struct E: Decodable { let number: Int?; let last_watched_at: String? }
            let show: TraktMedia?; let seasons: [S]?
        }
        if let (data, code) = await get("/sync/watched/shows", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([WatchedShow].self, from: data) {
            for r in rows {
                guard let show = r.show else { continue }
                for s in r.seasons ?? [] {
                    for e in s.episodes ?? [] {
                        guard let sn = s.number, let en = e.number else { continue }
                        out.append(SyncItem(
                            imdb: show.ids?.imdb, tmdb: show.ids?.tmdb, type: "series",
                            title: show.title ?? "", season: sn, episode: en,
                            progress: nil, watchedAt: parseDate(e.last_watched_at)))
                    }
                }
            }
        }
        return out
    }

    /// In-progress playback (Continue Watching) for movies + episodes.
    /// No `limit` — Trakt returns the whole playback list unpaginated, and a
    /// cap silently dropped older in-progress items ("doesn't sync everything").
    /// Returns nil on FAILURE (network/HTTP/decode) — callers must not treat an
    /// outage like an empty list, or the local→Trakt backfill would re-scrobble
    /// the entire local Continue Watching every sync during Trakt downtime.
    static func playbackProgress(accessToken: String) async -> [SyncItem]? {
        struct Row: Decodable {
            struct Ep: Decodable { let season: Int?; let number: Int? }
            let id: Int?
            let progress: Double?; let paused_at: String?; let type: String?
            let movie: TraktMedia?; let episode: Ep?; let show: TraktMedia?
        }
        guard let (data, code) = await get("/sync/playback", accessToken), code == 200,
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.compactMap { r in
            if r.type == "movie", let m = r.movie {
                return SyncItem(imdb: m.ids?.imdb, tmdb: m.ids?.tmdb, type: "movie",
                                title: m.title ?? "", season: nil, episode: nil,
                                progress: r.progress, watchedAt: parseDate(r.paused_at),
                                playbackID: r.id)
            } else if let show = r.show, let ep = r.episode {
                return SyncItem(imdb: show.ids?.imdb, tmdb: show.ids?.tmdb, type: "series",
                                title: show.title ?? "", season: ep.season, episode: ep.number,
                                progress: r.progress, watchedAt: parseDate(r.paused_at),
                                playbackID: r.id)
            }
            return nil
        }
    }

    /// Delete one row from Trakt's playback list (their Continue Watching).
    @discardableResult
    static func removePlayback(playbackID: Int, accessToken: String) async -> Bool {
        let req = request("/sync/playback/\(playbackID)", method: "DELETE", bearer: accessToken)
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Add items to Trakt watch history. Returns true on success.
    @discardableResult
    static func addToHistory(_ items: [SyncItem], accessToken: String) async -> Bool {
        await historyCall("/sync/history", items, accessToken, includeWatchedAt: true)
    }

    /// Remove items from Trakt watch history.
    @discardableResult
    static func removeFromHistory(_ items: [SyncItem], accessToken: String) async -> Bool {
        await historyCall("/sync/history/remove", items, accessToken, includeWatchedAt: false)
    }

    private static func historyCall(_ path: String, _ items: [SyncItem], _ token: String, includeWatchedAt: Bool) async -> Bool {
        var movies: [[String: Any]] = []
        // Group episodes under their show so one show carries many episodes.
        var showsByKey: [String: (ids: [String: Any], seasons: [Int: [[String: Any]]])] = [:]
        for it in items {
            guard let ids = traktIDs(it) else { continue }
            if it.type == "movie" {
                var m: [String: Any] = ["ids": ids]
                if includeWatchedAt, let d = it.watchedAt { m["watched_at"] = iso.string(from: d) }
                movies.append(m)
            } else if let s = it.season, let e = it.episode {
                let key = it.imdb ?? it.tmdb.map { "tmdb:\($0)" } ?? ""
                var entry = showsByKey[key] ?? (ids: ids, seasons: [:])
                var ep: [String: Any] = ["number": e]
                if includeWatchedAt, let d = it.watchedAt { ep["watched_at"] = iso.string(from: d) }
                entry.seasons[s, default: []].append(ep)
                showsByKey[key] = entry
            }
        }
        let shows: [[String: Any]] = showsByKey.values.map { entry in
            [
                "ids": entry.ids,
                "seasons": entry.seasons.map { (num, eps) in ["number": num, "episodes": eps] },
            ]
        }
        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies }
        if !shows.isEmpty { body["shows"] = shows }
        guard !body.isEmpty else { return false }
        var req = request(path, method: "POST", bearer: token)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            NSLog("[OrivioTrakt] POST %@ — network error", path); return false
        }
        NSLog("[OrivioTrakt] POST %@ (movies=%d shows=%d) → HTTP %d", path,
              (body["movies"] as? [Any])?.count ?? 0, (body["shows"] as? [Any])?.count ?? 0, http.statusCode)
        return (200..<300).contains(http.statusCode)
    }

    /// Build a Trakt `ids` object from a SyncItem (imdb preferred).
    private static func traktIDs(_ it: SyncItem) -> [String: Any]? {
        if let imdb = it.imdb, imdb.hasPrefix("tt") { return ["imdb": imdb] }
        if let tmdb = it.tmdb { return ["tmdb": tmdb] }
        return nil
    }

    private static func get(_ path: String, _ token: String) async -> (Data, Int)? {
        let req = request(path, bearer: token)
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            NSLog("[OrivioTrakt] GET %@ — network error", path)
            return nil
        }
        if http.statusCode != 200 { NSLog("[OrivioTrakt] GET %@ → HTTP %d", path, http.statusCode) }
        return (data, http.statusCode)
    }

    // MARK: Watchlist

    /// Trakt watchlist (movies + shows), title-level.
    static func watchlist(accessToken: String) async -> [SyncItem] {
        var out: [SyncItem] = []
        struct MovieRow: Decodable { let movie: TraktMedia? }
        struct ShowRow: Decodable { let show: TraktMedia? }
        if let (data, code) = await get("/sync/watchlist/movies", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([MovieRow].self, from: data) {
            for r in rows where r.movie != nil {
                out.append(SyncItem(imdb: r.movie?.ids?.imdb, tmdb: r.movie?.ids?.tmdb,
                                    type: "movie", title: r.movie?.title ?? ""))
            }
        }
        if let (data, code) = await get("/sync/watchlist/shows", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([ShowRow].self, from: data) {
            for r in rows where r.show != nil {
                out.append(SyncItem(imdb: r.show?.ids?.imdb, tmdb: r.show?.ids?.tmdb,
                                    type: "series", title: r.show?.title ?? ""))
            }
        }
        return out
    }

    @discardableResult
    static func addToWatchlist(_ items: [SyncItem], accessToken: String) async -> Bool {
        await postTitles("/sync/watchlist", items, accessToken, includeRating: false)
    }
    @discardableResult
    static func removeFromWatchlist(_ items: [SyncItem], accessToken: String) async -> Bool {
        await postTitles("/sync/watchlist/remove", items, accessToken, includeRating: false)
    }

    // MARK: Ratings

    /// Trakt personal ratings (movies + shows), 1–10.
    static func ratings(accessToken: String) async -> [SyncItem] {
        var out: [SyncItem] = []
        struct MovieRow: Decodable { let rating: Int?; let movie: TraktMedia? }
        struct ShowRow: Decodable { let rating: Int?; let show: TraktMedia? }
        if let (data, code) = await get("/sync/ratings/movies", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([MovieRow].self, from: data) {
            for r in rows where r.movie != nil {
                out.append(SyncItem(imdb: r.movie?.ids?.imdb, tmdb: r.movie?.ids?.tmdb,
                                    type: "movie", title: r.movie?.title ?? "", rating: r.rating))
            }
        }
        if let (data, code) = await get("/sync/ratings/shows", accessToken), code == 200,
           let rows = try? JSONDecoder().decode([ShowRow].self, from: data) {
            for r in rows where r.show != nil {
                out.append(SyncItem(imdb: r.show?.ids?.imdb, tmdb: r.show?.ids?.tmdb,
                                    type: "series", title: r.show?.title ?? "", rating: r.rating))
            }
        }
        return out
    }

    @discardableResult
    static func addRatings(_ items: [SyncItem], accessToken: String) async -> Bool {
        await postTitles("/sync/ratings", items, accessToken, includeRating: true)
    }
    @discardableResult
    static func removeRatings(_ items: [SyncItem], accessToken: String) async -> Bool {
        await postTitles("/sync/ratings/remove", items, accessToken, includeRating: false)
    }

    /// Title-level POST (watchlist / ratings): {movies:[…], shows:[…]}.
    private static func postTitles(_ path: String, _ items: [SyncItem], _ token: String, includeRating: Bool) async -> Bool {
        var movies: [[String: Any]] = []
        var shows: [[String: Any]] = []
        for it in items {
            guard let ids = traktIDs(it) else { continue }
            var obj: [String: Any] = ["ids": ids]
            if includeRating, let r = it.rating { obj["rating"] = r }
            if it.type == "movie" { movies.append(obj) } else { shows.append(obj) }
        }
        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies }
        if !shows.isEmpty { body["shows"] = shows }
        guard !body.isEmpty else { return false }
        var req = request(path, method: "POST", bearer: token)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            NSLog("[OrivioTrakt] POST %@ — network error", path); return false
        }
        NSLog("[OrivioTrakt] POST %@ (movies=%d shows=%d) → HTTP %d", path,
              (body["movies"] as? [Any])?.count ?? 0, (body["shows"] as? [Any])?.count ?? 0, http.statusCode)
        return (200..<300).contains(http.statusCode)
    }

    // MARK: Public lists (collection sources)

    struct PublicListInfo: Hashable {
        let traktListId: Int64
        let title: String
        let description: String?
    }

    /// Parse a bare list id, a slug, or a full trakt.tv list URL — mirrors the
    /// Android app's tolerant input (`parseTraktListPath`).
    static func parseListIDPath(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if Int64(trimmed) != nil { return trimmed }
        for pattern in [#"[?&]id=([^&#/]+)"#, #"trakt\.tv/lists/([^/?#]+)"#, #"trakt\.tv/users/[^/]+/lists/([^/?#]+)"#] {
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                let match = String(trimmed[range])
                if let idRange = match.range(of: #"[^/=]+$"#, options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        let slugCharset = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return trimmed.unicodeScalars.allSatisfy(slugCharset.contains) ? trimmed : nil
    }

    /// Metadata for a public (or the signed-in user's own) Trakt list — no auth
    /// required. `input` accepts an id, slug, or full trakt.tv URL.
    static func publicListInfo(input: String) async -> PublicListInfo? {
        guard let idPath = parseListIDPath(input) else { return nil }
        struct Response: Decodable {
            struct IDs: Decodable { let trakt: Int64? }
            let name: String?; let description: String?; let ids: IDs?
        }
        let req = request("/lists/\(idPath)?extended=full")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONDecoder().decode(Response.self, from: data),
              let traktID = body.ids?.trakt, let name = body.name else { return nil }
        return PublicListInfo(traktListId: traktID, title: name, description: body.description)
    }

    /// One raw item from a public list — enough to build a MetaItem once the
    /// caller resolves poster art (Trakt's own image extension needs VIP).
    struct PublicListItem: Hashable {
        let imdb: String?
        let tmdb: Int?
        let title: String
        let year: Int?
        let isMovie: Bool
    }

    /// Items in a public Trakt list. `type` is "movie" or "show".
    static func publicListItems(traktListId: Int64, type: String, sortBy: String, sortHow: String) async -> [PublicListItem] {
        struct Row: Decodable {
            struct IDs: Decodable { let imdb: String?; let tmdb: Int? }
            struct Media: Decodable { let title: String?; let year: Int?; let ids: IDs? }
            let type: String?; let movie: Media?; let show: Media?
        }
        let path = "/lists/\(traktListId)/items/\(type)"
        let req = request(path + "?extended=full&limit=200&sort_by=\(sortBy)&sort_how=\(sortHow)")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode != 200 { NSLog("[OrivioTrakt] GET %@ → HTTP %d", path, http.statusCode) }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            let isMovie = (row.type ?? type) == "movie"
            guard let media = isMovie ? row.movie : row.show, let title = media.title else { return nil }
            return PublicListItem(imdb: media.ids?.imdb, tmdb: media.ids?.tmdb, title: title,
                                  year: media.year, isMovie: isMovie)
        }
    }
}
