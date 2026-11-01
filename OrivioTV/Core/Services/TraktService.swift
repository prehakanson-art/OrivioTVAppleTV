import Foundation

struct TraktTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

struct TraktComment: Identifiable, Hashable {
    let id: Int
    let user: String
    let text: String
    let spoiler: Bool
    let likes: Int
    let createdAt: Date?
}

struct DeviceCodeInfo {
    var deviceCode: String
    var userCode: String
    var verificationURL: String
    var interval: TimeInterval
    var expiresAt: Date
}

/// Trakt session per profile.
@MainActor
final class TraktStore: ObservableObject, ProfileScoped {
    @Published private(set) var tokens: TraktTokens?
    @Published private(set) var username: String?
    @Published var needsReconnect = false
    @Published var lastSync: Date?
    @Published var lastError: String?

    init() { reloadForActiveProfile() }

    var isSignedIn: Bool { tokens != nil }

    func reloadForActiveProfile() {
        let p = ProfileScope.current
        tokens = Persistence.loadScoped(TraktTokens.self, base: "trakt.tokens.v1", profile: p)
        username = Persistence.string(forKey: Persistence.key("trakt.user.v1", profile: p))
        needsReconnect = false
    }

    func set(_ t: TraktTokens?, user: String?) {
        tokens = t
        username = user
        needsReconnect = false
        let p = ProfileScope.current
        if let t { Persistence.saveScoped(t, base: "trakt.tokens.v1", profile: p) } else {
            Persistence.set(nil, forKey: Persistence.key("trakt.tokens.v1", profile: p))
        }
        Persistence.set(user, forKey: Persistence.key("trakt.user.v1", profile: p))
        SyncSignals.markDirty(.providerCredentials)
    }
}

enum TraktService {
    static let base = "https://api.trakt.tv"
    static var clientID: String { Secrets.traktClientID }
    static var isConfigured: Bool { !clientID.isEmpty }

    private static var refreshTask: Task<TraktTokens?, Never>?

    // MARK: Requests

    @MainActor
    private static func token() async -> String? {
        let store = AppStores.shared.trakt
        guard var t = store.tokens else { return nil }
        if t.expiresAt < Date().addingTimeInterval(300) {
            // Serialized refresh.
            if let running = refreshTask {
                guard let r = await running.value else { return nil }
                t = r
            } else {
                let refresh = t.refreshToken
                let task = Task<TraktTokens?, Never> { await refreshTokens(refresh) }
                refreshTask = task
                let r = await task.value
                refreshTask = nil
                if let r { store.set(r, user: store.username); t = r } else {
                    store.needsReconnect = true
                    return nil
                }
            }
        }
        return t.accessToken
    }

    private static func headers(_ token: String?) -> [String: String] {
        var h = ["trakt-api-version": "2", "trakt-api-key": clientID, "Content-Type": "application/json"]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    @discardableResult
    static func request(_ path: String, method: String = "GET", body: Any? = nil, auth: Bool = true) async throws -> (Any, HTTPURLResponse) {
        guard isConfigured, let url = URL(string: base + path) else { throw HTTPError.other("Trakt not configured") }
        var tok: String?
        if auth {
            tok = await token()
            guard tok != nil else { throw HTTPError.status(401) }
        }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let req = HTTP.request(url, method: method, headers: headers(tok), body: data, fresh: true, timeout: 20)
        do {
            let (d, resp) = try await HTTP.data(req, session: HTTP.ephemeral)
            let obj = d.isEmpty ? [String: Any]() : ((try? JSONSerialization.jsonObject(with: d)) ?? [String: Any]())
            return (obj, resp)
        } catch HTTPError.status(401) {
            await MainActor.run { AppStores.shared.trakt.needsReconnect = true }
            throw HTTPError.status(401)
        }
    }

    // MARK: Auth (device code)

    static func startDeviceCode() async throws -> DeviceCodeInfo {
        let (obj, _) = try await request("/oauth/device/code", method: "POST", body: ["client_id": clientID], auth: false)
        guard let d = obj as? [String: Any], let code = d["device_code"] as? String, let user = d["user_code"] as? String else {
            throw HTTPError.notJSON
        }
        return DeviceCodeInfo(deviceCode: code, userCode: user, verificationURL: d["verification_url"] as? String ?? "https://trakt.tv/activate",
                              interval: TimeInterval(d["interval"] as? Int ?? 5),
                              expiresAt: Date().addingTimeInterval(TimeInterval(d["expires_in"] as? Int ?? 600)))
    }

    /// Polls until approved (returns tokens), denied/expired (throws) or cancelled.
    static func pollDeviceToken(_ info: DeviceCodeInfo) async throws -> TraktTokens {
        while Date() < info.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(info.interval * 1_000_000_000))
            guard let url = URL(string: base + "/oauth/device/token") else { throw HTTPError.badURL("") }
            let body = try JSONSerialization.data(withJSONObject: ["code": info.deviceCode, "client_id": clientID,
                                                                    "client_secret": Secrets.traktClientSecret])
            let req = HTTP.request(url, method: "POST", headers: headers(nil), body: body, fresh: true)
            let (data, resp) = try await HTTP.ephemeral.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = parseTokens(d) { return t }
            if status == 400 { continue }          // pending
            if status == 429 { try await Task.sleep(nanoseconds: 2_000_000_000); continue }
            if [404, 409, 410, 418].contains(status) { throw HTTPError.other("The code expired or was denied.") }
        }
        throw HTTPError.other("The code expired.")
    }

    private static func parseTokens(_ d: [String: Any]) -> TraktTokens? {
        guard let a = d["access_token"] as? String, let r = d["refresh_token"] as? String else { return nil }
        let created = (d["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let expires = TimeInterval(d["expires_in"] as? Int ?? 7_776_000)
        return TraktTokens(accessToken: a, refreshToken: r, expiresAt: created.addingTimeInterval(expires))
    }

    private static func refreshTokens(_ refresh: String) async -> TraktTokens? {
        guard let url = URL(string: base + "/oauth/token"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "refresh_token": refresh, "client_id": clientID, "client_secret": Secrets.traktClientSecret,
                  "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"])
        else { return nil }
        let req = HTTP.request(url, method: "POST", headers: headers(nil), body: body, fresh: true)
        guard let (data, _) = try? await HTTP.data(req, session: HTTP.ephemeral),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseTokens(d)
    }

    static func username() async -> String? {
        guard let (obj, _) = try? await request("/users/settings"),
              let user = (obj as? [String: Any])?["user"] as? [String: Any] else { return nil }
        return user["username"] as? String
    }

    // MARK: Item helpers

    static func ids(for meta: MetaItem) -> [String: Any] {
        var ids: [String: Any] = [:]
        if let imdb = meta.imdbID { ids["imdb"] = imdb }
        if let t = meta.tmdbID { ids["tmdb"] = t }
        return ids
    }

    static func scrobbleBody(meta: MetaItem, video: MetaVideo?, progress: Double) -> [String: Any] {
        var body: [String: Any] = ["progress": max(0, min(100, progress * 100))]
        if let video, let s = video.season, let e = video.episode {
            body["show"] = ["ids": ids(for: meta)]
            body["episode"] = ["season": s, "number": e]
        } else {
            body["movie"] = ["ids": ids(for: meta)]
        }
        return body
    }

    static func posterURL(imdb: String) -> String { "https://images.metahub.space/poster/medium/\(imdb)/img" }
    static func backdropURL(imdb: String) -> String { "https://images.metahub.space/background/medium/\(imdb)/img" }
    static func logoURL(imdb: String) -> String { "https://images.metahub.space/logo/medium/\(imdb)/img" }

    static func meta(fromTraktItem item: [String: Any], type: String) -> MetaItem? {
        guard let ids = item["ids"] as? [String: Any] else { return nil }
        let title = item["title"] as? String ?? ""
        let year = (item["year"] as? Int).map(String.init)
        if let imdb = ids["imdb"] as? String, !imdb.isEmpty {
            var m = MetaItem(id: imdb, type: type, name: title, poster: posterURL(imdb: imdb), background: backdropURL(imdb: imdb),
                             logo: logoURL(imdb: imdb), releaseInfo: year)
            m.tmdbID = ids["tmdb"] as? Int
            return m
        }
        if let tmdb = ids["tmdb"] as? Int {
            var m = MetaItem(id: "tmdb:\(tmdb)", type: type, name: title, releaseInfo: year)
            m.tmdbID = tmdb
            return m
        }
        return nil
    }

    /// Unwraps `{movie:{…}}` / `{show:{…}}` / bare items.
    static func metas(from list: [[String: Any]], defaultType: String) -> [MetaItem] {
        list.compactMap { row in
            if let m = row["movie"] as? [String: Any] { return meta(fromTraktItem: m, type: "movie") }
            if let s = row["show"] as? [String: Any] { return meta(fromTraktItem: s, type: "series") }
            return meta(fromTraktItem: row, type: defaultType)
        }
    }

    // MARK: Lists (public — client id only)

    static func listItems(listID: Int64, page: Int = 1) async -> [MetaItem] {
        guard let (obj, _) = try? await request("/lists/\(listID)/items?page=\(page)&limit=100", auth: false),
              let list = obj as? [[String: Any]] else { return [] }
        return metas(from: list, defaultType: "movie")
    }

    static func endpointItems(path: String, query: String?, type: String, page: Int = 1) async -> [MetaItem] {
        var p = path.hasPrefix("/") ? path : "/" + path
        p += "?page=\(page)&limit=50"
        if let query, !query.isEmpty { p += "&" + query }
        guard let (obj, _) = try? await request(p, auth: false), let list = obj as? [[String: Any]] else { return [] }
        return metas(from: list, defaultType: type)
    }

    static func searchLists(_ q: String) async -> [(Int64, String, Int)] {
        guard let (obj, _) = try? await request("/search/list?query=\(HTTP.encodeComponent(q))&limit=20", auth: false),
              let list = obj as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let l = r["list"] as? [String: Any], let ids = l["ids"] as? [String: Any],
                  let id = (ids["trakt"] as? Int).map(Int64.init) ?? (ids["trakt"] as? Int64) else { return nil }
            return (id, l["name"] as? String ?? "List", l["item_count"] as? Int ?? 0)
        }
    }

    // MARK: Comments

    static func comments(for meta: MetaItem) async -> [TraktComment] {
        guard let id = meta.imdbID else { return [] }
        let kind = meta.isSeries ? "shows" : "movies"
        guard let (obj, _) = try? await request("/\(kind)/\(id)/comments/likes?limit=20", auth: false),
              let list = obj as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let id = c["id"] as? Int, let text = c["comment"] as? String else { return nil }
            let user = (c["user"] as? [String: Any])?["username"] as? String ?? "Trakt user"
            return TraktComment(id: id, user: user, text: text, spoiler: c["spoiler"] as? Bool ?? false,
                                likes: c["likes"] as? Int ?? 0, createdAt: (c["created_at"] as? String).flatMap(DateParsing.parse))
        }
    }

    // MARK: Scrobble

    static func scrobble(_ action: String, meta: MetaItem, video: MetaVideo?, progress: Double) async {
        _ = try? await request("/scrobble/\(action)", method: "POST", body: scrobbleBody(meta: meta, video: video, progress: progress))
    }
}
