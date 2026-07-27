import Foundation

// Stremio account: QR ("Stremio Link") login + a one-way pull of the user's
// Stremio library into Orivio's own stores (saved Library, Continue Watching,
// Watched). The protocol is Stremio's public one:
//   • Link:  https://link.stremio.com/api/create?type=Create  → { code, link, qrcode }
//            https://link.stremio.com/api/read?type=Read&code= → { result:{ authKey } } once linked
//   • Data:  https://api.strem.io/api/getUser        { authKey }
//            https://api.strem.io/api/datastoreGet   { authKey, collection:"libraryItem", all:true }
//            https://api.strem.io/api/logout         { authKey }

// MARK: - Models

/// A QR/link login code from link.stremio.com.
struct StremioLinkCode {
    let code: String   // short code, e.g. "6YRB" (also shown as text)
    let link: String   // https://link.stremio.com/<code> — what the QR encodes
}

enum StremioLinkResult {
    case pending
    case authorized(authKey: String)
}

struct StremioUser {
    let email: String?
    let avatar: String?
}

// MARK: - Persisted store

@MainActor
final class StremioAccountStore: ObservableObject {
    @Published private(set) var authKey: String?
    @Published private(set) var email: String?
    @Published private(set) var avatar: String?
    @Published var lastSyncStatus: String?
    @Published private(set) var isSyncing = false

    private static let authKeyKey = "orivio.stremio.authKey.v1"
    private static let emailKey   = "orivio.stremio.email.v1"
    private static let avatarKey  = "orivio.stremio.avatar.v1"

    var isSignedIn: Bool { !(authKey ?? "").isEmpty }

    init() {
        authKey = UserDefaults.standard.string(forKey: Self.authKeyKey)
        email   = UserDefaults.standard.string(forKey: Self.emailKey)
        avatar  = UserDefaults.standard.string(forKey: Self.avatarKey)
    }

    func signIn(authKey: String, user: StremioUser?) {
        self.authKey = authKey
        self.email = user?.email
        self.avatar = user?.avatar
        UserDefaults.standard.set(authKey, forKey: Self.authKeyKey)
        UserDefaults.standard.set(user?.email, forKey: Self.emailKey)
        UserDefaults.standard.set(user?.avatar, forKey: Self.avatarKey)
    }

    func setSyncing(_ v: Bool) { isSyncing = v }
    func setStatus(_ s: String?) { lastSyncStatus = s }

    func signOut() {
        let key = authKey
        authKey = nil; email = nil; avatar = nil; lastSyncStatus = nil
        UserDefaults.standard.removeObject(forKey: Self.authKeyKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.avatarKey)
        if let key { Task { await StremioAccountService.logout(authKey: key) } }
    }
}

// MARK: - Service

enum StremioAccountService {
    private static let linkBase = "https://link.stremio.com"
    private static let apiBase  = "https://api.strem.io"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    /// Start a QR/link login — returns the code + link to display.
    static func createLink() async throws -> StremioLinkCode {
        struct Resp: Decodable { let code: String; let link: String }
        let url = URL(string: "\(linkBase)/api/create?type=Create")!
        let (data, _) = try await session.data(from: url)
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return StremioLinkCode(code: r.code, link: r.link)
    }

    /// Poll for the authKey. While the code is unauthorized the API returns an
    /// error (code 101) — that's treated as `.pending`; a network blip is too.
    static func readLink(code: String) async -> StremioLinkResult {
        struct AuthKey: Decodable { let authKey: String? }
        struct Resp: Decodable { let result: AuthKey? }
        guard let url = URL(string: "\(linkBase)/api/read?type=Read&code=\(code)"),
              let (data, _) = try? await session.data(from: url),
              let r = try? JSONDecoder().decode(Resp.self, from: data),
              let key = r.result?.authKey, !key.isEmpty else {
            return .pending
        }
        return .authorized(authKey: key)
    }

    /// The signed-in user (email/avatar) for display.
    static func getUser(authKey: String) async -> StremioUser? {
        struct U: Decodable { let email: String?; let avatar: String? }
        struct Resp: Decodable { let result: U? }
        guard let (data, _) = try? await post("/api/getUser", ["authKey": authKey]),
              let r = try? JSONDecoder().decode(Resp.self, from: data), let u = r.result else { return nil }
        return StremioUser(email: u.email, avatar: u.avatar)
    }

    /// The full `libraryItem` datastore (library + progress + watched, all in one).
    static func fetchLibrary(authKey: String) async throws -> [StremioLibraryItem] {
        struct Resp: Decodable { let result: [StremioLibraryItem]? }
        let (data, _) = try await post("/api/datastoreGet",
            ["authKey": authKey, "collection": "libraryItem", "all": true])
        let decoder = JSONDecoder()
        return (try decoder.decode(Resp.self, from: data)).result ?? []
    }

    static func logout(authKey: String) async {
        _ = try? await post("/api/logout", ["authKey": authKey])
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: URL(string: apiBase + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: req)
    }
}

// MARK: - Stremio library item (datastore shape)

struct StremioLibraryItem: Decodable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let removed: Bool?
    let temp: Bool?
    let ctime: String?
    let state: State?

    struct State: Decodable {
        let lastWatched: String?
        let timeOffset: Double?      // milliseconds
        let duration: Double?        // milliseconds
        let video_id: String?        // "<id>:<season>:<episode>" for series
        let timesWatched: Int?
        let flaggedWatched: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id", type, name, poster, removed, temp
        case ctime = "_ctime", state
    }

    var ctimeDate: Date? { StremioDate.parse(ctime) }
}

/// Lenient ISO-8601 parser (Stremio timestamps carry fractional seconds).
enum StremioDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}

// MARK: - Sync (Stremio → Orivio stores)

enum StremioSync {
    /// Pull the Stremio library and merge it into Orivio's Library / Continue
    /// Watching / Watched stores. One-way (Stremio → Orivio); non-destructive
    /// (`reconcile: false`) so it never deletes local items. Returns a summary.
    @MainActor
    static func pull(authKey: String,
                     library: LibraryStore,
                     progress: ProgressStore,
                     watched: WatchedStore) async -> String {
        let items: [StremioLibraryItem]
        do { items = try await StremioAccountService.fetchLibrary(authKey: authKey) }
        catch { return "Couldn't reach Stremio" }

        var saved: [SavedLibraryItem] = []
        var continueWatching: [WatchProgress] = []
        var watchedItems: [WatchedItem] = []

        for li in items {
            let removed = li.removed ?? false
            let temp = li.temp ?? false

            // Saved Library = explicitly added (not removed, not a temp progress-only row).
            if !removed && !temp {
                saved.append(SavedLibraryItem(
                    id: li.id, type: li.type, name: li.name,
                    poster: li.poster, addedAt: li.ctimeDate ?? Date()
                ))
            }

            guard let st = li.state else { continue }
            let pos = (st.timeOffset ?? 0) / 1000    // ms → s
            let dur = (st.duration ?? 0) / 1000
            let (season, episode) = parseVideoID(st.video_id)
            let lastWatched = StremioDate.parse(st.lastWatched) ?? Date()
            let finished = (st.flaggedWatched ?? 0) > 0

            // Continue Watching = has real progress and isn't finished.
            if dur > 60, pos > 0, pos / dur < 0.95, !finished {
                // Key must match ProgressStore.key: movie = id, episode = video_id.
                let key = (li.type == "series" ? (st.video_id ?? li.id) : li.id)
                continueWatching.append(WatchProgress(
                    id: key, metaID: li.id, type: li.type, name: li.name,
                    poster: li.poster, background: nil, logo: nil,
                    season: season, episode: episode, episodeTitle: nil, episodeThumbnail: nil,
                    positionSeconds: pos, durationSeconds: dur,
                    streamURL: nil, updatedAt: lastWatched
                ))
            }

            // Watched — movies flagged as watched (series per-episode watched is a
            // compressed bitfield that needs the full episode list to decode; not
            // pulled here).
            if li.type == "movie", finished || (st.timesWatched ?? 0) > 0 {
                watchedItems.append(WatchedItem(
                    contentID: li.id, contentType: li.type, title: li.name,
                    season: nil, episode: nil, watchedAt: lastWatched
                ))
            }
        }

        if !saved.isEmpty { library.mergeRemote(saved, reconcile: false) }
        if !continueWatching.isEmpty { progress.mergeExternal(continueWatching) }
        if !watchedItems.isEmpty { watched.mergeRemote(watchedItems, reconcile: false) }

        if saved.isEmpty && continueWatching.isEmpty && watchedItems.isEmpty {
            return "Nothing to sync"
        }
        return "Synced \(saved.count) library · \(continueWatching.count) in-progress · \(watchedItems.count) watched"
    }

    /// "<id>:<season>:<episode>" → (season, episode). nil for movies.
    private static func parseVideoID(_ v: String?) -> (Int?, Int?) {
        guard let v else { return (nil, nil) }
        let parts = v.split(separator: ":")
        guard parts.count >= 3, let e = Int(parts[parts.count - 1]), let s = Int(parts[parts.count - 2]) else {
            return (nil, nil)
        }
        return (s, e)
    }
}
