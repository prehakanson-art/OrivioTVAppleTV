import Foundation

// §9.7 Plex / Jellyfin. Plex: PIN via plex.tv/link → resources → the first
// address that answers `/identity`. Jellyfin: server URL + AuthenticateByName.
// Libraries show in the Library tab; files play directly (no transcode).
// Tokens never reach the log.

enum MediaServerKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case plex, jellyfin

    var id: String { rawValue }
    var displayName: String { self == .plex ? "Plex" : "Jellyfin" }
    var icon: String { self == .plex ? "play.rectangle.on.rectangle.fill" : "server.rack" }
    /// Meta ids for server items: `plex:<ratingKey>`, `jellyfin:<Id>`.
    var idPrefix: String { rawValue + ":" }

    static func kind(ofMetaID id: String) -> MediaServerKind? {
        allCases.first { id.hasPrefix($0.idPrefix) }
    }
}

struct MediaServerAccount: Codable, Equatable {
    var kind: MediaServerKind
    /// "http://192.168.1.10:32400" — no trailing slash.
    var serverURL: String
    /// The server's X-Plex-Token, or the Jellyfin access token.
    var token: String
    /// Jellyfin's item endpoints are per user.
    var userID: String?
    var serverName: String?
    var username: String?

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }
}

/// One library on a server (a Plex section / a Jellyfin view).
struct MediaServerLibrary: Identifiable, Hashable {
    let id: String
    let title: String
    let isShows: Bool
}

/// A movie, show or episode on a server, with what the player needs.
struct MediaServerItem: Identifiable, Hashable {
    let kind: MediaServerKind
    let serverItemID: String
    let title: String
    var year: Int?
    var poster: String?
    var backdrop: String?
    var overview: String?
    var isSeries = false
    var durationSeconds: Double?
    var season: Int?
    var episode: Int?
    var showTitle: String?
    var showID: String?
    /// Plex: the part key (`/library/parts/…`). Jellyfin builds the URL from the id.
    var streamPath: String?
    var fileName: String?
    var addedAt: Date?

    var id: String { kind.idPrefix + serverItemID }

    var metaItem: MetaItem {
        MetaItem(id: id, type: isSeries ? "series" : "movie", name: title, poster: poster, background: backdrop ?? poster,
                 description: overview, releaseInfo: year.map(String.init),
                 runtime: durationSeconds.map { "\(Int($0 / 60)) min" })
    }

    var metaVideo: MetaVideo {
        MetaVideo(id: id, title: title, season: season, episode: episode, thumbnail: backdrop ?? poster, overview: overview,
                  runtime: durationSeconds.map { Int($0 / 60) })
    }
}

// MARK: - Store

/// The connected servers, one of each kind, device-wide.
@MainActor
final class MediaServerStore: ObservableObject {
    static let shared = MediaServerStore()
    @Published private(set) var plex: MediaServerAccount?
    @Published private(set) var jellyfin: MediaServerAccount?

    private struct Blob: Codable { var plex: MediaServerAccount?; var jellyfin: MediaServerAccount? }
    private let key = Persistence.key("mediaservers.v1")

    init() {
        let blob = Persistence.load(Blob.self, key: key)
        plex = blob?.plex
        jellyfin = blob?.jellyfin
    }

    func account(_ kind: MediaServerKind) -> MediaServerAccount? {
        let a = kind == .plex ? plex : jellyfin
        return a?.isConfigured == true ? a : nil
    }

    func set(_ account: MediaServerAccount?, for kind: MediaServerKind) {
        if kind == .plex { plex = account } else { jellyfin = account }
        Persistence.save(Blob(plex: plex, jellyfin: jellyfin), key: key, compressed: false)
    }

    var connected: [MediaServerKind] { MediaServerKind.allCases.filter { account($0) != nil } }
}

// MARK: - Shared HTTP

private enum ServerHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func data(_ req: URLRequest) async -> (Data, Int)? {
        guard let (data, response) = try? await session.data(for: req), let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    static func json(_ req: URLRequest) async -> Any? {
        guard let (data, status) = await data(req), (200..<300).contains(status) else {
            #if DEBUG
            DebugLog.write("[MediaServer] \(req.httpMethod ?? "GET") \(req.url?.path ?? "") failed")
            #endif
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func persistentID(_ key: String) -> String {
        if let v = Persistence.string(forKey: key), !v.isEmpty { return v }
        let fresh = UUID().uuidString
        Persistence.set(fresh, forKey: key)
        return fresh
    }
}

// MARK: - Plex

enum PlexService {
    static let linkURL = "https://plex.tv/link"
    static var clientIdentifier: String { ServerHTTP.persistentID("orivio.plex.clientIdentifier") }

    private static func request(_ url: URL, method: String = "GET", token: String? = nil, timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        let headers = [
            "Accept": "application/json", "X-Plex-Product": "Orivio TV", "X-Plex-Version": "1.0",
            "X-Plex-Client-Identifier": clientIdentifier, "X-Plex-Platform": "tvOS",
            "X-Plex-Device": "Apple TV", "X-Plex-Device-Name": "Apple TV",
        ]
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let token { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return req
    }

    struct Pin { let id: Int; let code: String }

    static func requestPin() async -> Pin? {
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=false"),
              let d = await ServerHTTP.json(request(url, method: "POST")) as? [String: Any],
              let id = d["id"] as? Int, let code = d["code"] as? String else { return nil }
        return Pin(id: id, code: code)
    }

    /// The account token once the code has been entered; nil while pending.
    static func pollPin(_ pin: Pin) async -> String? {
        guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)"),
              let d = await ServerHTTP.json(request(url)) as? [String: Any],
              let token = d["authToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    struct ServerCandidate: Identifiable {
        struct Connection { let uri: String; let local: Bool; let relay: Bool }
        let id: String
        let name: String
        /// Differs from the account token on a server shared with you.
        let accessToken: String?
        let connections: [Connection]
    }

    static func servers(token: String) async -> [ServerCandidate] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=0"),
              let list = await ServerHTTP.json(request(url, token: token)) as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard ((r["provides"] as? String) ?? "").split(separator: ",").contains("server") else { return nil }
            let conns = (r["connections"] as? [[String: Any]] ?? []).compactMap { c -> ServerCandidate.Connection? in
                guard let uri = c["uri"] as? String, !uri.isEmpty else { return nil }
                return .init(uri: uri, local: c["local"] as? Bool ?? false, relay: c["relay"] as? Bool ?? false)
            }
            return ServerCandidate(id: r["clientIdentifier"] as? String ?? UUID().uuidString, name: r["name"] as? String ?? "Plex Media Server",
                                   accessToken: r["accessToken"] as? String, connections: conns)
        }
    }

    /// LAN first, then direct remote, then the relay.
    static func reachableURL(_ server: ServerCandidate, token: String) async -> String? {
        let ordered = server.connections.filter(\.local) + server.connections.filter { !$0.local && !$0.relay } + server.connections.filter(\.relay)
        for c in ordered {
            guard let url = URL(string: c.uri + "/identity") else { continue }
            if let (_, status) = await ServerHTTP.data(request(url, token: token, timeout: 5)), (200..<300).contains(status) { return c.uri }
        }
        return nil
    }

    private static func get(_ a: MediaServerAccount, _ path: String) async -> [String: Any]? {
        guard let url = URL(string: a.serverURL + path) else { return nil }
        return (await ServerHTTP.json(request(url, token: a.token)) as? [String: Any])?["MediaContainer"] as? [String: Any]
    }

    static func imageURL(_ a: MediaServerAccount, _ path: String?, width: Int = 500) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return a.serverURL + "/photo/:/transcode?width=\(width)&height=\(width * 3 / 2)&minSize=1&url=\(encoded)&X-Plex-Token=\(a.token)"
    }

    private static func item(_ a: MediaServerAccount, _ m: [String: Any]) -> MediaServerItem? {
        guard let key = m["ratingKey"] as? String, let title = m["title"] as? String else { return nil }
        let part = ((m["Media"] as? [[String: Any]])?.first?["Part"] as? [[String: Any]])?.first
        let isEpisode = m["type"] as? String == "episode"
        return MediaServerItem(
            kind: .plex, serverItemID: key, title: title, year: m["year"] as? Int,
            poster: imageURL(a, (isEpisode ? m["grandparentThumb"] : m["thumb"]) as? String),
            backdrop: imageURL(a, (isEpisode ? m["thumb"] : m["art"]) as? String, width: 1280),
            overview: m["summary"] as? String, isSeries: m["type"] as? String == "show",
            durationSeconds: (m["duration"] as? Double).map { $0 / 1000 },
            season: isEpisode ? m["parentIndex"] as? Int : nil, episode: isEpisode ? m["index"] as? Int : nil,
            showTitle: m["grandparentTitle"] as? String, showID: m["grandparentRatingKey"] as? String,
            streamPath: part?["key"] as? String,
            fileName: (part?["file"] as? String).map { ($0 as NSString).lastPathComponent },
            addedAt: (m["addedAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    static func libraries(_ a: MediaServerAccount) async -> [MediaServerLibrary]? {
        guard let c = await get(a, "/library/sections") else { return nil }
        return (c["Directory"] as? [[String: Any]] ?? []).compactMap { d in
            guard let key = d["key"] as? String, let type = d["type"] as? String, type == "movie" || type == "show" else { return nil }
            return MediaServerLibrary(id: key, title: d["title"] as? String ?? key, isShows: type == "show")
        }
    }

    static func items(_ a: MediaServerAccount, library: String) async -> [MediaServerItem]? {
        guard let c = await get(a, "/library/sections/\(library)/all") else { return nil }
        return (c["Metadata"] as? [[String: Any]] ?? []).compactMap { item(a, $0) }
    }

    static func episodes(_ a: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        guard let c = await get(a, "/library/metadata/\(showID)/allLeaves") else { return [] }
        return (c["Metadata"] as? [[String: Any]] ?? []).compactMap { item(a, $0) }
    }

    static func item(_ a: MediaServerAccount, id: String) async -> MediaServerItem? {
        guard let c = await get(a, "/library/metadata/\(id)") else { return nil }
        return (c["Metadata"] as? [[String: Any]] ?? []).compactMap { item(a, $0) }.first
    }

    static func streamURL(_ a: MediaServerAccount, _ item: MediaServerItem) -> String? {
        guard let path = item.streamPath else { return nil }
        return a.serverURL + path + (path.contains("?") ? "&" : "?") + "X-Plex-Token=" + a.token
    }
}

// MARK: - Jellyfin

enum JellyfinService {
    static var deviceID: String { ServerHTTP.persistentID("orivio.jellyfin.deviceId") }

    private static func request(_ url: URL, method: String = "GET", token: String? = nil, body: Data? = nil, timeout: TimeInterval? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        var auth = "MediaBrowser Client=\"Orivio TV\", Device=\"Apple TV\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
        if let token, !token.isEmpty {
            auth += ", Token=\"\(token)\""
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// "192.168.1.10:8096" → "http://192.168.1.10:8096".
    static func normalizedServerURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard URL(string: text)?.host != nil else { return nil }
        return text
    }

    static func serverName(_ serverURL: String) async -> String? {
        guard let url = URL(string: serverURL + "/System/Info/Public"),
              let d = await ServerHTTP.json(request(url, timeout: 8)) as? [String: Any] else { return nil }
        return d["ServerName"] as? String ?? "Jellyfin"
    }

    /// Signs in; the message explains a failure.
    static func authenticate(serverURL: String, username: String, password: String) async -> (MediaServerAccount?, String) {
        guard let url = URL(string: serverURL + "/Users/AuthenticateByName") else { return (nil, "That server address doesn't look right.") }
        let body = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        guard let (data, status) = await ServerHTTP.data(request(url, method: "POST", body: body)) else {
            return (nil, "Couldn't reach the server. Check the address and that it's on.")
        }
        guard (200..<300).contains(status) else {
            return (nil, status == 401 ? "Wrong username or password." : "The server answered HTTP \(status).")
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = d["AccessToken"] as? String,
              let user = d["User"] as? [String: Any], let userID = user["Id"] as? String else {
            return (nil, "The server's reply couldn't be read.")
        }
        let name = await serverName(serverURL)
        return (MediaServerAccount(kind: .jellyfin, serverURL: serverURL, token: token, userID: userID, serverName: name,
                                   username: user["Name"] as? String ?? username), "Connected.")
    }

    private static func get(_ a: MediaServerAccount, _ path: String) async -> [String: Any]? {
        guard let url = URL(string: a.serverURL + path) else { return nil }
        return await ServerHTTP.json(request(url, token: a.token)) as? [String: Any]
    }

    static func imageURL(_ a: MediaServerAccount, itemID: String, kind: String, tag: String?, height: Int = 720) -> String {
        var url = a.serverURL + "/Items/\(itemID)/Images/\(kind)?maxHeight=\(height)&api_key=\(a.token)"
        if let tag { url += "&tag=\(tag)" }
        return url
    }

    private static func item(_ a: MediaServerAccount, _ i: [String: Any]) -> MediaServerItem? {
        guard let id = i["Id"] as? String, let name = i["Name"] as? String else { return nil }
        let type = i["Type"] as? String
        let isEpisode = type == "Episode"
        let primary = (i["ImageTags"] as? [String: String])?["Primary"]
        let seriesID = i["SeriesId"] as? String
        let poster: String? = isEpisode
            ? seriesID.map { imageURL(a, itemID: $0, kind: "Primary", tag: i["SeriesPrimaryImageTag"] as? String) }
            : primary.map { imageURL(a, itemID: id, kind: "Primary", tag: $0) }
        let backdropTag = (i["BackdropImageTags"] as? [String])?.first
        let backdrop: String? = isEpisode
            ? primary.map { imageURL(a, itemID: id, kind: "Primary", tag: $0) }
            : backdropTag.map { imageURL(a, itemID: id, kind: "Backdrop", tag: $0, height: 1080) }
        let added = (i["DateCreated"] as? String).flatMap { DateParsing.isoNoFraction.date(from: String($0.prefix(19)) + "Z") }
        return MediaServerItem(
            kind: .jellyfin, serverItemID: id, title: name, year: i["ProductionYear"] as? Int,
            poster: poster, backdrop: backdrop, overview: i["Overview"] as? String, isSeries: type == "Series",
            durationSeconds: (i["RunTimeTicks"] as? Double).map { $0 / 10_000_000 },
            season: isEpisode ? i["ParentIndexNumber"] as? Int : nil, episode: isEpisode ? i["IndexNumber"] as? Int : nil,
            showTitle: i["SeriesName"] as? String, showID: seriesID, streamPath: nil,
            fileName: (i["Path"] as? String).map { ($0 as NSString).lastPathComponent }, addedAt: added)
    }

    static func libraries(_ a: MediaServerAccount) async -> [MediaServerLibrary]? {
        guard let uid = a.userID, let d = await get(a, "/Users/\(uid)/Views") else { return nil }
        return (d["Items"] as? [[String: Any]] ?? []).compactMap { v in
            guard let id = v["Id"] as? String, let type = v["CollectionType"] as? String, type == "movies" || type == "tvshows" else { return nil }
            return MediaServerLibrary(id: id, title: v["Name"] as? String ?? "Library", isShows: type == "tvshows")
        }
    }

    /// Paged: a flat Limit silently truncated big libraries.
    static func items(_ a: MediaServerAccount, library: String) async -> [MediaServerItem]? {
        guard let uid = a.userID else { return [] }
        var out: [MediaServerItem] = []
        var start = 0
        let page = 1000
        while start < 20_000 {
            let path = "/Users/\(uid)/Items?ParentId=\(library)&IncludeItemTypes=Movie,Series&Recursive=true"
                + "&Fields=Overview,ProductionYear,RunTimeTicks,Path,DateCreated&SortBy=SortName&SortOrder=Ascending&Limit=\(page)&StartIndex=\(start)"
            guard let d = await get(a, path) else { return start == 0 ? nil : out }
            let batch = d["Items"] as? [[String: Any]] ?? []
            out += batch.compactMap { item(a, $0) }
            if batch.count < page { break }
            start += page
        }
        return out
    }

    static func episodes(_ a: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        guard let uid = a.userID, let d = await get(a, "/Shows/\(showID)/Episodes?UserId=\(uid)&Fields=Overview,RunTimeTicks,Path") else { return [] }
        return (d["Items"] as? [[String: Any]] ?? []).compactMap { item(a, $0) }
    }

    static func item(_ a: MediaServerAccount, id: String) async -> MediaServerItem? {
        guard let uid = a.userID, let d = await get(a, "/Users/\(uid)/Items/\(id)") else { return nil }
        return item(a, d)
    }

    /// The original file (`static=true`), no transcode.
    static func streamURL(_ a: MediaServerAccount, _ item: MediaServerItem) -> String {
        a.serverURL + "/Videos/\(item.serverItemID)/stream?static=true&api_key=\(a.token)"
    }
}

// MARK: - Uniform access + playback

enum MediaServerAPI {
    static func libraries(_ a: MediaServerAccount) async -> [MediaServerLibrary]? {
        a.kind == .plex ? await PlexService.libraries(a) : await JellyfinService.libraries(a)
    }

    static func items(_ a: MediaServerAccount, library: String) async -> [MediaServerItem]? {
        a.kind == .plex ? await PlexService.items(a, library: library) : await JellyfinService.items(a, library: library)
    }

    static func episodes(_ a: MediaServerAccount, showID: String) async -> [MediaServerItem] {
        let list = a.kind == .plex ? await PlexService.episodes(a, showID: showID) : await JellyfinService.episodes(a, showID: showID)
        return list.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    static func item(_ a: MediaServerAccount, id: String) async -> MediaServerItem? {
        a.kind == .plex ? await PlexService.item(a, id: id) : await JellyfinService.item(a, id: id)
    }

    static func streamEntry(_ a: MediaServerAccount, _ item: MediaServerItem) -> StreamEntry? {
        let url: String?
        let headers: [String: String]
        switch a.kind {
        case .plex:
            url = PlexService.streamURL(a, item)
            headers = ["X-Plex-Token": a.token]
        case .jellyfin:
            url = JellyfinService.streamURL(a, item)
            headers = ["X-Emby-Token": a.token]
        }
        guard let url else { return nil }
        var hints = StreamBehaviorHints()
        hints.filename = item.fileName
        hints.proxyHeaders = StreamProxyHeaders(request: headers)
        hints.bingeGroup = "mediaserver-\(a.kind.rawValue)"
        let stream = Stream(name: a.kind.displayName, title: item.fileName ?? item.title, url: url, behaviorHints: hints)
        return StreamEntry(stream: stream, addonName: a.serverName ?? a.kind.displayName, addonID: "mediaserver.\(a.kind.rawValue)", index: 0)
    }
}

@MainActor
enum MediaServerPlayback {
    /// Plays a movie straight from the server.
    static func play(movie: MediaServerItem, account a: MediaServerAccount, fromStart: Bool = false) {
        guard let entry = MediaServerAPI.streamEntry(a, movie), let url = URL(string: entry.stream.url ?? "") else { return }
        let meta = movie.metaItem
        let resume = fromStart ? nil : AppStores.shared.progress.progress(meta: meta, video: nil).flatMap { $0.isResumable ? $0.position : nil }
        PlayerPresenter.shared.present(PlaybackRequest(meta: meta, video: nil, entry: entry, allEntries: [entry], resumePosition: resume,
                                                       url: url, headers: entry.stream.proxyRequestHeaders))
    }

    /// Plays an episode; the show's other episodes ride along so Up Next uses the server's files.
    static func play(episode: MediaServerItem, show: MediaServerItem, episodes: [MediaServerItem], account a: MediaServerAccount, fromStart: Bool = false) {
        guard let entry = MediaServerAPI.streamEntry(a, episode), let url = URL(string: entry.stream.url ?? "") else { return }
        var meta = show.metaItem
        meta.videos = episodes.map(\.metaVideo)
        let video = episode.metaVideo
        let resume = fromStart ? nil : AppStores.shared.progress.progress(meta: meta, video: video).flatMap { $0.isResumable ? $0.position : nil }
        var request = PlaybackRequest(meta: meta, video: video, entry: entry, allEntries: [entry], resumePosition: resume,
                                      url: url, headers: entry.stream.proxyRequestHeaders)
        request.directEpisodes = Dictionary(episodes.compactMap { e in MediaServerAPI.streamEntry(a, e).map { (e.id, $0) } },
                                            uniquingKeysWith: { x, _ in x })
        PlayerPresenter.shared.present(request)
    }

    /// Continue Watching → back to the server. Returns false when the server can't serve it.
    @discardableResult
    static func resume(meta: MetaItem, video: MetaVideo?, fromStart: Bool) async -> Bool {
        guard let kind = MediaServerKind.kind(ofMetaID: meta.id), let a = MediaServerStore.shared.account(kind) else { return false }
        let serverID = String(meta.id.dropFirst(kind.idPrefix.count))
        if let video {
            async let showFetch = MediaServerAPI.item(a, id: serverID)
            async let listFetch = MediaServerAPI.episodes(a, showID: serverID)
            guard let show = await showFetch else { return false }
            let list = await listFetch
            guard let ep = list.first(where: { $0.id == video.id }) ?? list.first(where: { $0.season == video.season && $0.episode == video.episode }) else { return false }
            play(episode: ep, show: show, episodes: list, account: a, fromStart: fromStart)
            return true
        }
        guard let movie = await MediaServerAPI.item(a, id: serverID) else { return false }
        play(movie: movie, account: a, fromStart: fromStart)
        return true
    }
}
