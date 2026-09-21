import Foundation

// Stremio account: QR ("Stremio Link") login + a one-way pull of the user's
// Stremio library into Orivio's own stores (saved Library, Continue Watching,
// Watched). The protocol is Stremio's public one:
//   • Link:  https://link.stremio.com/api/create?type=Create  → { code, link, qrcode }
//            https://link.stremio.com/api/read?type=Read&code= → { result:{ authKey } } once linked
//   • Data:  https://api.strem.io/api/getUser        { authKey }
//            https://api.strem.io/api/datastoreGet   { authKey, collection:"libraryItem", all:true }
//            https://api.strem.io/api/addonCollectionGet / addonCollectionSet
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
    case failed(String)
}

enum StremioAccountError: LocalizedError {
    case server(String)
    /// A request URL that wouldn't build. Every Stremio endpoint interpolates
    /// something — a login code, an API path — and a value carrying a character
    /// URL can't parse used to hit a force-unwrap and take the whole app down
    /// with it. A failed request is the correct outcome; a crash never is.
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .badURL(let path): return "Couldn't build a Stremio request URL for \(path)."
        }
    }
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
        let path = "\(linkBase)/api/create?type=Create"
        guard let url = URL(string: path) else { throw StremioAccountError.badURL(path) }
        let (data, _) = try await session.data(from: url)
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return StremioLinkCode(code: r.code, link: r.link)
    }

    /// Poll for the authKey. While the code is unauthorized the API returns an
    /// error (code 101) — that's treated as `.pending`; a network blip is too.
    static func readLink(code: String) async -> StremioLinkResult {
        struct AuthKey: Decodable { let authKey: String? }
        struct LinkError: Decodable { let code: Int?; let message: String? }
        struct Resp: Decodable { let result: AuthKey?; let error: LinkError? }
        guard let url = URL(string: "\(linkBase)/api/read?type=Read&code=\(code)") else {
            return .failed("Bad Stremio link code.")
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("Stremio returned a server error.")
            }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            if let key = r.result?.authKey, !key.isEmpty {
                return .authorized(authKey: key)
            }
            if let error = r.error {
                // Stremio returns code 101 while the link is not authorized yet.
                if error.code == 101 { return .pending }
                return .failed(error.message ?? "Stremio rejected this login code.")
            }
            return .pending
        } catch {
            return .failed("Couldn't reach Stremio Link.")
        }
    }

    /// Sign in with a Stremio email and password, the alternative to the QR
    /// link flow. Returns the same `authKey` every other call here takes, so
    /// the two paths are interchangeable from the caller's side.
    ///
    /// `type: "Login"` rides along in the body because the official clients
    /// send it; the server ignores it on the newer endpoints but older
    /// deployments dispatch on it.
    static func login(email: String, password: String) async throws -> (authKey: String, user: StremioUser?) {
        struct U: Decodable { let email: String?; let avatar: String? }
        struct Result: Decodable { let authKey: String?; let user: U? }
        struct Resp: Decodable { let result: Result? }

        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw StremioAccountError.server("Enter your Stremio email and password.")
        }
        let (data, response) = try await post("/api/login",
                                              ["type": "Login", "email": email, "password": password])
        // The API reports bad credentials in the BODY with a 200, so check the
        // error envelope before the status code or a wrong password surfaces
        // as "couldn't reach Stremio".
        try throwIfAPIError(data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StremioAccountError.server("Stremio returned a server error.")
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let key = decoded.result?.authKey, !key.isEmpty else {
            throw StremioAccountError.server("Stremio didn't return a session for that account.")
        }
        let u = decoded.result?.user
        return (key, StremioUser(email: u?.email ?? email, avatar: u?.avatar))
    }

    /// The signed-in user (email/avatar) for display.
    static func getUser(authKey: String) async -> StremioUser? {
        struct U: Decodable { let email: String?; let avatar: String? }
        struct Resp: Decodable { let result: U? }
        guard let (data, _) = try? await post("/api/getUser", ["authKey": authKey]),
              let r = try? JSONDecoder().decode(Resp.self, from: data), let u = r.result else { return nil }
        return StremioUser(email: u.email, avatar: u.avatar)
    }

    /// Cheap change detection. `datastoreMeta` returns only ids and
    /// modification times for the collection, so a signature of it says
    /// whether the full `datastoreGet` (the whole library, potentially
    /// megabytes) is worth fetching at all. The result is a list of
    /// `[id, mtime]` pairs; objects with `_id`/`_mtime` are accepted too.
    static func fetchLibrarySignature(authKey: String) async throws -> String {
        let (data, _) = try await post("/api/datastoreMeta",
            ["authKey": authKey, "collection": "libraryItem"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StremioAccountError.server("Unexpected datastoreMeta response")
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            throw StremioAccountError.server(message)
        }
        guard let result = root["result"] as? [Any] else {
            throw StremioAccountError.server("datastoreMeta returned no result")
        }
        var pairs: [String] = []
        pairs.reserveCapacity(result.count)
        for entry in result {
            if let pair = entry as? [Any], pair.count >= 2 {
                pairs.append("\(pair[0])|\(pair[1])")
            } else if let dict = entry as? [String: Any] {
                let id = dict["_id"] ?? dict["id"] ?? ""
                let mtime = dict["_mtime"] ?? dict["mtime"] ?? ""
                pairs.append("\(id)|\(mtime)")
            }
        }
        // The `[[id, mtime]]` shape is assumed from stremio-core. A non-empty
        // result whose entries match neither form yields a CONSTANT signature,
        // and "unchanged" every tick would silence pulls for the session —
        // fail safe by throwing, which the caller treats as "do a full pull".
        guard result.isEmpty || !pairs.isEmpty else {
            throw StremioAccountError.server("datastoreMeta shape not recognised")
        }
        pairs.sort()
        return "\(pairs.count):" + StremioSync.fnv64(pairs.joined(separator: "\n"))
    }

    /// The full `libraryItem` datastore (library + progress + watched, all in one).
    static func fetchLibrary(authKey: String) async throws -> [StremioLibraryItem] {
        struct Resp: Decodable { let result: [StremioLibraryItem]? }
        let (data, _) = try await post("/api/datastoreGet",
            ["authKey": authKey, "collection": "libraryItem", "all": true])
        let decoder = JSONDecoder()
        return (try decoder.decode(Resp.self, from: data)).result ?? []
    }

    static func fetchAddonCollection(authKey: String) async throws -> [StremioAddonDescriptor] {
        struct AddonCollection: Decodable { let addons: [StremioAddonDescriptor?]? }
        struct APIError: Decodable { let message: String? }
        struct Resp: Decodable { let result: AddonCollection?; let error: APIError? }

        let (data, _) = try await post("/api/addonCollectionGet", ["authKey": authKey])
        let response = try JSONDecoder().decode(Resp.self, from: data)
        if let message = response.error?.message, !message.isEmpty {
            throw StremioAccountError.server(message)
        }
        return (response.result?.addons ?? [])
            .compactMap { $0 }
            .filter { !$0.transportUrl.isEmpty }
    }

    static func setAddonCollection(authKey: String, addons: [InstalledAddon]) async throws {
        let payload = try addons.compactMap { addon -> [String: Any]? in
            guard !addon.manifest.isPlaceholder else { return nil }
            let transportUrl = StremioAddonDescriptor(transportUrl: addon.manifestURL).transportUrl
            guard !transportUrl.isEmpty else { return nil }
            return [
                "transportUrl": transportUrl,
                "transportName": "http",
                "manifest": try manifestDictionary(addon.manifest),
                "flags": [:]
            ]
        }

        let (data, _) = try await post("/api/addonCollectionSet", [
            "authKey": authKey,
            "addons": payload
        ])
        try throwIfAPIError(data)
    }

    static func putLibrary(authKey: String, items: [[String: Any]]) async throws {
        let (data, _) = try await post("/api/datastorePut", [
            "authKey": authKey,
            "collection": "libraryItem",
            "changes": items
        ])
        try throwIfAPIError(data)
    }

    static func logout(authKey: String) async {
        _ = try? await post("/api/logout", ["authKey": authKey])
    }

    private static func manifestDictionary(_ manifest: AddonManifest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(manifest)
        let object = try JSONSerialization.jsonObject(with: data)
        var dictionary = object as? [String: Any] ?? [:]

        dictionary["id"] = manifest.id
        dictionary["name"] = manifest.name
        dictionary["version"] = manifest.version?.isEmpty == false ? manifest.version : "0.0.0"
        dictionary["description"] = manifest.description ?? ""
        dictionary["resources"] = dictionary["resources"] ?? []
        dictionary["types"] = dictionary["types"] ?? []
        dictionary["catalogs"] = dictionary["catalogs"] ?? []
        return dictionary
    }

    private static func throwIfAPIError(_ data: Data) throws {
        struct APIError: Decodable { let message: String? }
        struct Resp: Decodable { let error: APIError? }
        guard let response = try? JSONDecoder().decode(Resp.self, from: data),
              let message = response.error?.message,
              !message.isEmpty else { return }
        throw StremioAccountError.server(message)
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> (Data, URLResponse) {
        // `apiBase` is a literal but `path` is interpolated by every caller, so
        // this was a force-unwrap on a value the callers control: an illegal
        // character trapped the process instead of failing the one request.
        guard let url = URL(string: apiBase + path) else {
            throw StremioAccountError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: req)
    }
}

// MARK: - Stremio add-on descriptors

struct StremioAddonDescriptor: Codable {
    let transportUrl: String

    var dictionary: [String: String] { ["transportUrl": transportUrl] }

    init(transportUrl: String) {
        self.transportUrl = Self.normalizeManifestURL(transportUrl)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try? container.decodeIfPresent(String.self, forKey: .transportUrl)
        let alternate = try? container.decodeIfPresent(String.self, forKey: .transportURL)
        let url = try? container.decodeIfPresent(String.self, forKey: .url)
        let manifestURL = try? container.decodeIfPresent(String.self, forKey: .manifestURL)
        let endpoint = (try? container.decodeIfPresent([String].self, forKey: .endpoints))??.first
        transportUrl = Self.normalizeManifestURL(primary ?? alternate ?? url ?? manifestURL ?? endpoint ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transportUrl, forKey: .transportUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case transportUrl, transportURL, url, manifestURL, endpoints
    }

    private static func normalizeManifestURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("stremio://") {
            value = value.replacingOccurrences(of: "stremio://", with: "https://")
        }
        // Split any query/fragment off BEFORE deciding. A configured addon's
        // manifest routinely carries one (…/manifest.json?token=…), and
        // appending to the whole string produced
        // "…/manifest.json?token=…/manifest.json" — an addon that can never be
        // installed, and whose `baseURL` then equals its manifest URL so every
        // catalog/meta/stream request is malformed too.
        var suffix = ""
        if let mark = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            suffix = String(value[mark...])
            value = String(value[value.startIndex..<mark])
        }
        if !value.hasSuffix("manifest.json") {
            value = value.hasSuffix("/") ? value + "manifest.json" : value + "/manifest.json"
        }
        return value + suffix
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
    let mtime: String?
    let state: State?

    struct State: Decodable {
        let lastWatched: String?
        let timeOffset: Double?      // milliseconds
        let duration: Double?        // milliseconds, absent on some Stremio clients
        let timeWatched: Double?
        let overallTimeWatched: Double?
        let video_id: String?        // "<id>:<season>:<episode>" for series
        let timesWatched: Int?
        let flaggedWatched: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastWatched = (try? c.decodeIfPresent(String.self, forKey: .lastWatched))
                ?? (try? c.decodeIfPresent(String.self, forKey: .last_watched))
            timeOffset = (try? c.decodeIfPresent(Double.self, forKey: .timeOffset))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .time_offset))
            duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
            timeWatched = (try? c.decodeIfPresent(Double.self, forKey: .timeWatched))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .time_watched))
            overallTimeWatched = (try? c.decodeIfPresent(Double.self, forKey: .overallTimeWatched))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .overall_time_watched))
            video_id = try? c.decodeIfPresent(String.self, forKey: .video_id)
            timesWatched = (try? c.decodeIfPresent(Int.self, forKey: .timesWatched))
                ?? (try? c.decodeIfPresent(Int.self, forKey: .times_watched))
            flaggedWatched = (try? c.decodeIfPresent(Int.self, forKey: .flaggedWatched))
                ?? (try? c.decodeIfPresent(Int.self, forKey: .flagged_watched))
        }

        enum CodingKeys: String, CodingKey {
            case lastWatched, timeOffset, duration, timeWatched, overallTimeWatched, video_id, timesWatched, flaggedWatched
            case last_watched, time_offset, time_watched, overall_time_watched, times_watched, flagged_watched
        }

        /// Rebuild the wire form, so a state we pulled can be written back
        /// untouched. Required because putLibrary REPLACES the whole item:
        /// pushing a library row without its state silently wipes that title's
        /// resume point in Stremio.
        var wireForm: [String: Any] {
            var out: [String: Any] = [:]
            if let lastWatched { out["last_watched"] = lastWatched }
            if let timeOffset { out["time_offset"] = timeOffset }
            if let duration { out["duration"] = duration }
            if let timeWatched { out["time_watched"] = timeWatched }
            if let overallTimeWatched { out["overall_time_watched"] = overallTimeWatched }
            if let video_id { out["video_id"] = video_id }
            if let timesWatched { out["times_watched"] = timesWatched }
            if let flaggedWatched { out["flagged_watched"] = flaggedWatched }
            return out
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id", type, name, poster, removed, temp
        case ctime = "_ctime", mtime = "_mtime", state
    }

    var ctimeDate: Date? { StremioDate.parse(ctime) }
    var mtimeDate: Date? { StremioDate.parse(mtime) }
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
    /// Playback state exactly as Stremio last reported it, keyed by item id.
    ///
    /// putLibrary REPLACES each item wholesale, so any library row pushed
    /// without a `state` wipes that title's resume point in Stremio. We push
    /// every library row on every sync, so titles we happened to have no local
    /// progress for were being cleared there — which is why Stremio's continue
    /// watching kept emptying out. Anything we don't have our own state for is
    /// written back from here, untouched.
    private(set) static var lastPulledStates: [String: [String: Any]] = [:]

    /// What the last pull knew about each item beyond its playback state, so
    /// a row rebuilt here (a Continue Watching clear for a title not in the
    /// local library) keeps the item's real type/name/temp instead of
    /// replacing a saved series with a nameless `temp` movie stub.
    struct PulledItemMeta {
        let type: String
        let name: String
        let temp: Bool
        let removed: Bool
    }
    private(set) static var lastPulledItemMeta: [String: PulledItemMeta] = [:]

    /// Pull the Stremio library and merge it into Orivio's Library / Continue
    /// Watching / Watched stores. One-way (Stremio → Orivio); non-destructive
    /// (`reconcile: false`) so it never deletes local items. Returns a summary.
    @MainActor
    static func pull(authKey: String,
                     addonManager: AddonManager,
                     library: LibraryStore,
                     progress: ProgressStore,
                     watched: WatchedStore) async -> String {
        async let libraryFetch = StremioAccountService.fetchLibrary(authKey: authKey)
        async let addonFetch = StremioAccountService.fetchAddonCollection(authKey: authKey)

        let items: [StremioLibraryItem]
        let addonDescriptors: [StremioAddonDescriptor]
        do {
            items = try await libraryFetch
            addonDescriptors = (try? await addonFetch) ?? []
        } catch {
            return "Couldn't reach Stremio"
        }

        var saved: [SavedLibraryItem] = []
        var continueWatching: [WatchProgress] = []
        var watchedItems: [WatchedItem] = []
        var pulledStates: [String: [String: Any]] = [:]
        var pulledMeta: [String: PulledItemMeta] = [:]
        // Titles Stremio marks `removed` that this device still holds as
        // saved. Skipping them from `saved` was never enough: the additive
        // merge kept the local copy, and the next push wrote it back with
        // `removed: false` — a title removed in Stremio came back on every
        // launch. Only a removal NEWER than the local add counts; an older one
        // means the user re-saved it here afterwards.
        var removedRemotely: [SavedLibraryItem] = []
        let clearedAt = WatchHistoryClearState.clearedAt
        // Import accounting, so "nothing came across" can be answered with
        // numbers instead of a guess.
        var withState = 0, withPosition = 0, skippedFinished = 0,
            skippedNoPosition = 0, skippedCleared = 0

        for li in items {
            let removed = li.removed ?? false
            let temp = li.temp ?? false
            pulledMeta[li.id] = PulledItemMeta(type: li.type, name: li.name, temp: temp, removed: removed)

            // Saved Library = explicitly added (not removed, not a temp progress-only row).
            if !removed && !temp {
                saved.append(SavedLibraryItem(
                    id: li.id, type: li.type, name: li.name,
                    poster: li.poster, addedAt: li.ctimeDate ?? Date()
                ))
            } else if removed, let local = library.item(id: li.id, type: li.type),
                      let removedAt = li.mtimeDate, removedAt > local.addedAt {
                removedRemotely.append(local)
            }

            guard let st = li.state else { continue }
            withState += 1
            pulledStates[li.id] = st.wireForm
            let (pos, dur) = playbackSeconds(
                offset: st.timeOffset,
                duration: st.duration,
                timeWatched: st.timeWatched,
                overallTimeWatched: st.overallTimeWatched
            )
            let (season, episode) = parseVideoID(st.video_id)
            let parsedLastWatched = StremioDate.parse(st.lastWatched)
            // Epoch 0 is the ordering sentinel for "no timestamp" — correct for
            // sorting, but it must NOT be fed to the clear-horizon test below:
            // it would read as "watched before the clear" and suppress every
            // timestamp-less Stremio row for as long as the horizon exists.
            // Only a REAL timestamp can be proven to predate the clear.
            let lastWatched = parsedLastWatched ?? SyncTimestamp.unknown
            if pos > 0 { withPosition += 1 }
            if let clearedAt, let parsedLastWatched, parsedLastWatched <= clearedAt {
                skippedCleared += 1
                continue
            }
            let finished = (st.flaggedWatched ?? 0) > 0
            let inferredDuration = dur > 0 ? dur : 0
            // Stremio very often stores a real resume point with NO duration —
            // it only records what the player told it. Requiring a duration
            // here silently dropped most of the continue-watching list on
            // import. A row with a position but no runtime is kept with
            // duration 0 and filled in from the title's metadata below
            // (enrichContinueWatching); the 95%-finished test moves there too,
            // since it cannot be applied before a duration is known.
            //
            // Still excluded: entries with no position at all. Stremio keeps a
            // series pointer with no offset, and importing those as ~0s
            // progress made hundreds of dormant library rows look active.
            let unfinishedProgress = pos > 0
                && (inferredDuration <= 0 || (inferredDuration > 60 && pos / inferredDuration < 0.95))

            if finished, pos > 0 { skippedFinished += 1 }
            if !finished, pos <= 0 { skippedNoPosition += 1 }
            if !finished && unfinishedProgress {
                // Key must match ProgressStore.key: movie = id, episode = video_id.
                let key = (li.type == "series" ? (st.video_id ?? li.id) : li.id)
                continueWatching.append(WatchProgress(
                    id: key, metaID: li.id, type: li.type, name: li.name,
                    poster: li.poster, background: nil, logo: nil,
                    season: season, episode: episode, episodeTitle: nil, episodeThumbnail: nil,
                    positionSeconds: pos, durationSeconds: inferredDuration,
                    streamURL: nil, updatedAt: lastWatched,
                    syncSource: "stremio"
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

        lastPulledStates = pulledStates
        lastPulledItemMeta = pulledMeta
        for local in removedRemotely {
            // A real removal: the account hub and the trackers hear about it
            // exactly as if the user had removed it here.
            library.remove(id: local.id, type: local.type)
        }

        let addonStates = addonDescriptors
            .filter { !$0.transportUrl.isEmpty }
            .map { AddonManager.RemoteAddonState(manifestURL: $0.transportUrl, enabled: true) }

        if !addonStates.isEmpty {
            // Anything new here has to reach the Orivio account too: the full
            // sync no longer re-uploads every store unconditionally.
            if await addonManager.applyRemote(addons: addonStates, reconcile: false) > 0 {
                addonManager.requestSyncPush()
            }
        }
        let playing = await MainActor.run { OrivioSyncManager.playbackActive }
        if !saved.isEmpty {
            // Metadata lookups are a run of add-on requests: skipped while a
            // stream plays, filled in by the next idle pass.
            if !playing { saved = await enrichLibraryItems(saved, addonManager: addonManager) }
            if library.mergeRemote(saved, reconcile: false) { library.requestSyncPush() }
        }
        OrivioSyncDiagnostics.record(
            .info, area: "Stremio",
            "Library \(items.count) rows · \(withState) with state · \(withPosition) with a position · "
            + "kept \(continueWatching.count) · skipped \(skippedFinished) finished, "
            + "\(skippedNoPosition) with no position, \(skippedCleared) before the clear point."
        )
        if !continueWatching.isEmpty {
            let before = continueWatching.count
            if !playing {
                continueWatching = await enrichContinueWatching(continueWatching, addonManager: addonManager)
            }
            if continueWatching.count != before {
                OrivioSyncDiagnostics.record(
                    .info, area: "Stremio",
                    "Metadata pass dropped \(before - continueWatching.count) row(s) that turned out to be finished."
                )
            }
            progress.mergeExternal(continueWatching)
        }
        if !watchedItems.isEmpty, watched.mergeRemote(watchedItems, reconcile: false) {
            watched.requestSyncPush()
        }

        if addonStates.isEmpty && saved.isEmpty && continueWatching.isEmpty && watchedItems.isEmpty {
            return "Nothing to sync"
        }
        return "Pulled \(addonStates.count) add-ons · \(saved.count) library · \(continueWatching.count) in-progress · \(watchedItems.count) watched"
    }

    /// Outcome of a combined push. The summary is the human status line; the
    /// flag is what callers must branch on. The summary is NOT a success
    /// signal — it always reads "Pushed …", so a caller testing it for a
    /// failure prefix could never see one.
    struct PushOutcome {
        let summary: String
        /// False when the library PUT failed. The cleared-progress ids ride in
        /// that payload, so on failure they must stay queued for the next run.
        let libraryPushed: Bool
        /// Rows actually sent (zero when nothing had changed).
        let changedRows: Int
    }

    @MainActor
    static func pushCombined(authKey: String,
                             addonManager: AddonManager,
                             library: LibraryStore,
                             progress: ProgressStore,
                             watched: WatchedStore,
                             clearedProgressIDs: Set<String> = [],
                             removedLibraryItems: [StremioSyncManager.PendingLibraryRemoval] = []) async -> PushOutcome {
        var warnings: [String] = []
        var libraryPushed = true
        let playing = await MainActor.run { OrivioSyncManager.playbackActive }

        // Add-ons: `addonCollectionSet` replaces the account's whole list, so
        // send it only when the list actually changed since the last push.
        // What actually goes on the wire: local ORDER (the user's priority,
        // which `setAddonCollection` sends as-is) and only resolved manifests
        // (placeholders are dropped from the payload). A sorted set of URLs
        // missed a reorder and a placeholder that resolved after its push.
        let addonSignature = addonManager.addons
            .filter { !$0.manifest.isPlaceholder }
            .map(\.manifestURL)
            .joined(separator: "\n")
        var addonsSent = false
        if addonSignature != lastPushedAddonSignature {
            do {
                try await StremioAccountService.setAddonCollection(authKey: authKey, addons: addonManager.addons)
                lastPushedAddonSignature = addonSignature
                addonsSent = true
            } catch {
                warnings.append("add-ons")
                OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Add-on push to Stremio failed: \(error.localizedDescription)")
            }
        }

        let serviceProgress = progress.serviceBackedForSync()
        let rawLibrary = library.allForSync()
        let savedLibrary = playing ? rawLibrary : await enrichLibraryItems(rawLibrary, addonManager: addonManager)
        if savedLibrary != rawLibrary { library.mergeRemote(savedLibrary, reconcile: false) }
        let watchedRows = watched.allForSync()
        let cleared = clearedProgressIDs
        let removed = removedLibraryItems
        let lastHashes = lastPushedRowHashes
        // Only rows whose content changed since the last successful put. The
        // whole library used to go up every thirty seconds whether or not a
        // byte of it had moved; now a film in progress is a one-row put.
        //
        // Built + hashed OFF the main actor: the wire is one row, but the
        // BUILD is O(total rows) — a payload dictionary and one sorted-keys
        // JSONSerialization per library/progress/watched row, every 30s tick,
        // including mid-playback. At Trakt-import scale (thousands of watched
        // rows) that was a steady main-thread hiccup beside video decode on
        // the A8. Inputs are value-type snapshots taken above.
        let (changed, changedHashes, totalRows) = await Task.detached(
            priority: .utility
        ) { () -> ([[String: Any]], [String: String], Int) in
            let items = makeLibraryPutPayload(
                library: savedLibrary,
                progress: serviceProgress,
                watched: watchedRows,
                clearedProgressIDs: cleared,
                removedLibraryItems: removed
            )
            var changed: [[String: Any]] = []
            var changedHashes: [String: String] = [:]
            for row in items {
                guard let id = row["_id"] as? String else { continue }
                let hash = rowHash(row)
                if lastHashes[id] != hash {
                    changed.append(row)
                    changedHashes[id] = hash
                }
            }
            return (changed, changedHashes, items.count)
        }.value
        if !changed.isEmpty {
            do {
                try await StremioAccountService.putLibrary(authKey: authKey, items: changed)
                lastPushedRowHashes.merge(changedHashes) { $1 }
            } catch {
                libraryPushed = false
                warnings.append("library")
                OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Library push to Stremio failed: \(error.localizedDescription)")
            }
        }

        let summary: String
        if changed.isEmpty && !addonsSent {
            summary = "Stremio up to date"
        } else {
            summary = "Pushed \(changed.count) changed of \(totalRows) rows"
                + (addonsSent ? " · \(addonManager.addons.count) add-ons" : "")
                + " (\(savedLibrary.count) library · \(serviceProgress.count) in-progress · \(watchedRows.count) watched)"
        }
        guard !warnings.isEmpty else {
            return PushOutcome(summary: summary, libraryPushed: libraryPushed, changedRows: changed.count)
        }
        return PushOutcome(
            summary: "\(summary) · Stremio push failed for \(warnings.joined(separator: ", "))",
            libraryPushed: libraryPushed,
            changedRows: changed.count
        )
    }

    /// What this device last sent, so an unchanged row is not re-sent every
    /// tick. In memory only: a relaunch pushes everything once, as before.
    private(set) static var lastPushedRowHashes: [String: String] = [:]
    private(set) static var lastPushedAddonSignature: String?

    /// A different Stremio account signed in: nothing sent before applies.
    static func resetPushCache() {
        lastPushedRowHashes = [:]
        lastPushedAddonSignature = nil
        lastPulledStates = [:]
        lastPulledItemMeta = [:]
        enrichmentAttempted = []
    }

    private static func rowHash(_ row: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return UUID().uuidString }
        return fnv64(text)
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func fnv64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func metadataTypes(for type: String, id: String) -> [String] {
        let normalized = type.lowercased()
        let preferred = ["series", "tv", "show", "tvshow"].contains(normalized) ? "series" : "movie"
        guard id.hasPrefix("tt") else { return [preferred] }
        return preferred == "series" ? ["series", "movie"] : ["movie", "series"]
    }

    private static func isRawSyncTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == id { return true }
        if trimmed.hasPrefix("tt") && trimmed.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    private static func isUsefulMetadata(_ meta: MetaItem, for id: String) -> Bool {
        (!meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && meta.name != id)
        || meta.poster != nil
        || meta.background != nil
    }

    @MainActor
    private static func resolveSyncMetadata(id: String, type: String, addonManager: AddonManager) async -> MetaItem? {
        let cinemeta = AddonManager.bundledCinemeta()
        for lookupType in metadataTypes(for: type, id: id) {
            if let meta = try? await StremioAPI.meta(addon: cinemeta, type: lookupType, id: id),
               isUsefulMetadata(meta, for: id) {
                return meta
            }
        }
        return nil
    }

    /// Keys already attempted this session. Cinemeta simply HAS no art for
    /// some items, and without the memo the same ≤30 candidates were
    /// re-fetched — serially — on every 30s Stremio tick, forever: thirty
    /// round trips per sync keeping the radio and main actor busy against
    /// playback. OrivioSyncManager fixed the identical bug in its own copy
    /// with `artworkBackfillAttempted`; this is that memo for the Stremio
    /// copy. Reset on account change (resetPushCache).
    private static var enrichmentAttempted: Set<String> = []

    @MainActor
    private static func enrichLibraryItems(
        _ items: [SavedLibraryItem],
        addonManager: AddonManager
    ) async -> [SavedLibraryItem] {
        let rawTitleItems = items.filter { isRawSyncTitle($0.name, id: $0.id) }
        let rawTitleKeys = Set(rawTitleItems.map(\.key))
        let artworkItems = items.filter { item in
            !rawTitleKeys.contains(item.key) && (item.poster == nil || item.background == nil)
        }
        let candidates = (rawTitleItems + Array(artworkItems.prefix(30)))
            .filter { !enrichmentAttempted.contains($0.key) }
        guard !candidates.isEmpty else { return items }

        var metaByKey: [String: MetaItem] = [:]
        for item in candidates {
            enrichmentAttempted.insert(item.key)
            guard metaByKey[item.key] == nil else { continue }
            if let meta = await resolveSyncMetadata(id: item.id, type: item.type, addonManager: addonManager) {
                metaByKey[item.key] = meta
            }
        }
        guard !metaByKey.isEmpty else { return items }
        return items.map { item in
            guard let meta = metaByKey[item.key] else { return item }
            return item.withFallbackMetadata(meta)
        }
    }

    private static func makeLibraryPutPayload(
        library: [SavedLibraryItem],
        progress: [WatchProgress],
        watched: [WatchedItem],
        clearedProgressIDs: Set<String> = [],
        removedLibraryItems: [StremioSyncManager.PendingLibraryRemoval] = []
    ) -> [[String: Any]] {
        var rows: [String: [String: Any]] = [:]

        // Titles removed from the library HERE. `datastorePut` cannot express
        // absence, so a removal has to be written as the item with
        // `removed: true` — otherwise the account never hears about it and
        // its own copy comes straight back on the next pull.
        let stillSaved = Set(library.map(\.id))
        for removal in removedLibraryItems where !stillSaved.contains(removal.id) {
            let now = isoString(Date())
            var row: [String: Any] = [
                "_id": removal.id,
                "_ctime": now,
                "_mtime": now,
                "id": removal.id,
                "type": removal.type,
                "name": removal.name,
                "title": removal.name,
                "removed": true,
                "temp": false
            ]
            // Keep Stremio's own playback state: un-saving a title is not
            // clearing its resume point (`datastorePut` replaces the item).
            if let state = lastPulledStates[removal.id] { row["state"] = state }
            rows[removal.id] = row
        }

        for item in library {
            let now = isoString(item.addedAt)
            var row: [String: Any] = [
                "_id": item.id,
                "_ctime": now,
                "_mtime": now,
                "id": item.id,
                "type": item.type,
                "name": item.name,
                "title": item.name,
                "removed": false,
                "temp": false
            ]
            if let poster = item.poster { row["poster"] = poster }
            // Carry Stremio's own playback state back untouched. The progress
            // and watched passes below overwrite it for titles we actually
            // track; everything else keeps the resume point it already had
            // instead of being reset to nothing.
            if let existing = lastPulledStates[item.id] { row["state"] = existing }
            rows[item.id] = row
        }

        // Stremio's datastore keeps ONE playback state per LIBRARY ITEM — the
        // show, not the episode — so a series with two in-progress episodes has
        // to nominate one. This loop used to assign `row["state"]` for every
        // entry as it walked `serviceBackedForSync()`, whose order is
        // `Dictionary.Values`: unspecified, and seed-randomised per launch. The
        // last writer won, so the episode Stremio resumed flipped between syncs
        // and regularly REGRESSED to an older one. Nominate deterministically:
        // the most recently updated episode per show, ties broken on the
        // progress key so the choice never depends on hash order.
        var newestByMeta: [String: WatchProgress] = [:]
        for wp in progress {
            guard wp.durationSeconds.isFinite,
                  wp.positionSeconds.isFinite,
                  wp.durationSeconds > 0 else { continue }
            if let incumbent = newestByMeta[wp.metaID] {
                let wins = wp.updatedAt > incumbent.updatedAt
                    || (wp.updatedAt == incumbent.updatedAt && wp.id > incumbent.id)
                guard wins else { continue }
            }
            newestByMeta[wp.metaID] = wp
        }

        for wp in newestByMeta.values.sorted(by: { $0.metaID < $1.metaID }) {
            let id = wp.metaID
            var row = rows[id] ?? [
                "_id": id,
                "_ctime": isoString(wp.updatedAt),
                "id": id,
                "type": wp.type,
                "name": wp.name,
                "title": wp.name,
                "removed": false,
                "temp": true
            ]
            if let poster = wp.poster { row["poster"] = poster }
            row["_mtime"] = isoString(wp.updatedAt)
            row["state"] = stremioState(progress: wp, watched: nil)
            rows[id] = row
        }

        // Titles removed from Continue Watching here: zero their playback
        // state so Stremio drops them from ITS continue watching. Library
        // membership is untouched — this clears the resume point, it does not
        // unsave the title. Applied before the watched pass, which may then
        // legitimately overwrite the state with a "watched" marker.
        for id in clearedProgressIDs {
            // A show with a live resume point keeps it: the progress pass above
            // just nominated its current episode, and zeroing the state here
            // would wipe that. This is the "finished one episode, already on the
            // next" case, or a clear queued earlier landing after a re-watch
            // started. An explicit Remove-from-Continue-Watching has no row left,
            // so it still clears.
            guard newestByMeta[id] == nil else { continue }
            let known = lastPulledItemMeta[id]
            var row = rows[id] ?? [
                "_id": id,
                "_ctime": isoString(Date()),
                "id": id,
                "type": known?.type ?? "movie",
                "name": known?.name ?? "",
                "removed": known?.removed ?? false,
                "temp": known?.temp ?? true
            ]
            row["_mtime"] = isoString(Date())
            row["state"] = [
                "time_offset": 0,
                "time_watched": 0,
                "overall_time_watched": 0,
                "flagged_watched": 0,
                "last_watched": isoString(Date())
            ]
            rows[id] = row
        }

        for item in watched {
            guard item.contentType == "movie" || item.season == nil else { continue }
            let id = item.contentID
            var row = rows[id] ?? [
                "_id": id,
                "_ctime": isoString(item.watchedAt),
                "id": id,
                "type": item.contentType,
                "name": item.title,
                "title": item.title,
                "removed": false,
                "temp": true
            ]
            row["_mtime"] = isoString(item.watchedAt)
            row["state"] = stremioState(progress: nil, watched: item)
            rows[id] = row
        }

        // Ordered by id for the same reason the nomination above is: a payload
        // that shuffles on every launch is impossible to diff against the last
        // one when a resume point comes back wrong.
        return rows.keys.sorted().compactMap { rows[$0] }
    }

    private static func stremioState(progress: WatchProgress?, watched: WatchedItem?) -> [String: Any] {
        if let watched {
            return [
                "flagged_watched": 1,
                "times_watched": 1,
                "last_watched": isoString(watched.watchedAt)
            ]
        }
        guard let progress else { return [:] }
        // Stremio's datastore keeps EVERY duration in milliseconds. time_offset
        // and duration were sent in ms but time_watched / overall_time_watched
        // in seconds, so Stremio's own "time watched" stats for rows pushed by
        // this app read 1000x low.
        var state: [String: Any] = [
            "time_offset": progress.positionSeconds * 1000,
            "duration": progress.durationSeconds * 1000,
            "last_watched": isoString(progress.updatedAt),
            "time_watched": progress.positionSeconds * 1000,
            "overall_time_watched": progress.positionSeconds * 1000,
            "flagged_watched": 0
        ]
        if progress.type == "series" { state["video_id"] = progress.id }
        return state
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Runtime to assume when neither Stremio nor the metadata addon knows one.
    /// Same shape the Trakt import uses, so a row without a duration still gets
    /// a sensible resume percentage instead of being thrown away.
    nonisolated private static func fallbackRuntime(for type: String) -> Double {
        (type == "series" ? 45 : 100) * 60
    }

    @MainActor
    private static func enrichContinueWatching(
        _ entries: [WatchProgress],
        addonManager: AddonManager
    ) async -> [WatchProgress] {
        var metaByID: [String: MetaItem] = [:]
        // Series always (episode title/thumbnail), plus anything missing a
        // duration — including movies — since that is what makes the row
        // importable at all. Bounded so a large library can't turn one sync
        // into hundreds of meta fetches.
        var fetched = 0
        for entry in entries where entry.type == "series" || entry.durationSeconds <= 60 {
            guard metaByID[entry.metaID] == nil, fetched < 40 else { continue }
            fetched += 1
            if let meta = await resolveSyncMetadata(id: entry.metaID, type: entry.type, addonManager: addonManager) {
                metaByID[entry.metaID] = meta
            }
        }

        return entries.compactMap { entry -> WatchProgress? in
            // Fill in a missing duration, then apply the finished test that the
            // import could not.
            var entry = entry
            if entry.durationSeconds <= 60 {
                let runtime = metaByID[entry.metaID]?.runtimeSeconds
                    ?? fallbackRuntime(for: entry.type)
                entry.durationSeconds = runtime
                guard entry.positionSeconds / runtime < 0.95 else { return nil }
            }
            return enrichSeriesFields(entry, metaByID: metaByID)
        }
    }

    private static func enrichSeriesFields(
        _ entry: WatchProgress, metaByID: [String: MetaItem]
    ) -> WatchProgress {
            guard entry.type == "series", let meta = metaByID[entry.metaID] else { return entry }
            let video = meta.videos?.first { $0.id == entry.id }
                ?? meta.videos?.first { $0.season == entry.season && $0.episode == entry.episode }
            return WatchProgress(
                id: entry.id,
                metaID: entry.metaID,
                type: entry.type,
                name: meta.name,
                poster: meta.poster ?? entry.poster,
                background: meta.background ?? entry.background,
                logo: meta.logo ?? entry.logo,
                season: entry.season,
                episode: entry.episode,
                episodeTitle: video?.title ?? entry.episodeTitle,
                episodeThumbnail: video?.thumbnail ?? entry.episodeThumbnail,
                positionSeconds: entry.positionSeconds,
                durationSeconds: entry.durationSeconds,
                streamURL: entry.streamURL,
                streamSignature: entry.streamSignature,
                updatedAt: entry.updatedAt,
                syncSource: entry.syncSource,
                newEpisodeCount: entry.newEpisodeCount
            )
    }

    /// "<id>:<season>:<episode>" → (season, episode). nil for movies.
    ///
    /// The last two components are only a season/episode pair if the season
    /// looks like one. Kitsu-style ids ("kitsu:7442:1") have the identical
    /// shape but the middle component is the SHOW id, so Continue Watching
    /// happily rendered "S7442 · E1". Nothing has hundreds of seasons, so an
    /// implausible value means this isn't a season:episode id at all.
    private static let maxPlausibleSeason = 100

    private static func parseVideoID(_ v: String?) -> (Int?, Int?) {
        guard let v else { return (nil, nil) }
        let parts = v.split(separator: ":")
        guard parts.count >= 3, let e = Int(parts[parts.count - 1]), let s = Int(parts[parts.count - 2]) else {
            return (nil, nil)
        }
        guard s >= 0, s <= maxPlausibleSeason, e >= 0 else { return (nil, nil) }
        return (s, e)
    }

    /// Above this, a value cannot be a number of SECONDS of playback: nothing
    /// with a resume point runs for a day.
    private static let millisecondEvidenceThreshold: Double = 86_400

    /// Stremio datastore values have been seen as both seconds and milliseconds
    /// depending on client/version. Normalize by duration: anything larger than
    /// a day is certainly milliseconds for a movie/episode runtime.
    ///
    /// `timeWatched` / `overallTimeWatched` come from the SAME record and are
    /// written in the same unit as `timeOffset`, so they get a vote when the
    /// offset alone can't settle it.
    private static func playbackSeconds(offset: Double?,
                                        duration: Double?,
                                        timeWatched: Double?,
                                        overallTimeWatched: Double?) -> (Double, Double) {
        let rawOffset = offset ?? 0
        let rawDuration = duration ?? 0
        // Duration is the reliable signal, but it is very often ABSENT (see the
        // import note in `pull`). Keying the scale off duration alone then let a
        // millisecond offset through as seconds: a 50-minute resume point became
        // 3,000,000 "seconds", `enrichContinueWatching` computed a fraction far
        // past 1.0 and dropped the row as finished — silently discarding most
        // duration-less resume points on import.
        let scale: Double
        if rawDuration > 0 {
            scale = rawDuration > millisecondEvidenceThreshold ? 1000.0 : 1.0
        } else {
            // The offset's own magnitude is not enough either. An offset that IS
            // in milliseconds but below the threshold — the first ~86 seconds of
            // playback — passed straight through as seconds and became up to 24
            // hours, so `enrichContinueWatching` dropped it as finished: every
            // title the user had only just started disappeared on import.
            // Cross-check the companion fields Stremio sends in the same record.
            // Any ONE of them above the threshold proves the record is in
            // milliseconds, however small the offset happens to be. With nothing
            // else present this falls back to the offset test on its own.
            let evidence = max(rawOffset, max(timeWatched ?? 0, overallTimeWatched ?? 0))
            scale = evidence > millisecondEvidenceThreshold ? 1000.0 : 1.0
        }
        return (rawOffset / scale, rawDuration / scale)
    }
}
