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

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
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
        let url = URL(string: "\(linkBase)/api/create?type=Create")!
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
        var req = URLRequest(url: URL(string: apiBase + path)!)
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
    /// Playback state exactly as Stremio last reported it, keyed by item id.
    ///
    /// putLibrary REPLACES each item wholesale, so any library row pushed
    /// without a `state` wipes that title's resume point in Stremio. We push
    /// every library row on every sync, so titles we happened to have no local
    /// progress for were being cleared there — which is why Stremio's continue
    /// watching kept emptying out. Anything we don't have our own state for is
    /// written back from here, untouched.
    private(set) static var lastPulledStates: [String: [String: Any]] = [:]

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
        let clearedAt = WatchHistoryClearState.clearedAt
        // Import accounting, so "nothing came across" can be answered with
        // numbers instead of a guess.
        var withState = 0, withPosition = 0, skippedFinished = 0,
            skippedNoPosition = 0, skippedCleared = 0

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
            withState += 1
            pulledStates[li.id] = st.wireForm
            let (pos, dur) = playbackSeconds(offset: st.timeOffset, duration: st.duration)
            let (season, episode) = parseVideoID(st.video_id)
            let lastWatched = StremioDate.parse(st.lastWatched) ?? Date()
            if pos > 0 { withPosition += 1 }
            if let clearedAt, lastWatched <= clearedAt { skippedCleared += 1; continue }
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

        let addonStates = addonDescriptors
            .filter { !$0.transportUrl.isEmpty }
            .map { AddonManager.RemoteAddonState(manifestURL: $0.transportUrl, enabled: true) }

        if !addonStates.isEmpty {
            _ = await addonManager.applyRemote(addons: addonStates, reconcile: false)
        }
        if !saved.isEmpty {
            saved = await enrichLibraryItems(saved, addonManager: addonManager)
            library.mergeRemote(saved, reconcile: false)
        }
        OrivioSyncDiagnostics.record(
            .info, area: "Stremio",
            "Library \(items.count) rows · \(withState) with state · \(withPosition) with a position · "
            + "kept \(continueWatching.count) · skipped \(skippedFinished) finished, "
            + "\(skippedNoPosition) with no position, \(skippedCleared) before the clear point."
        )
        if !continueWatching.isEmpty {
            let before = continueWatching.count
            continueWatching = await enrichContinueWatching(continueWatching, addonManager: addonManager)
            if continueWatching.count != before {
                OrivioSyncDiagnostics.record(
                    .info, area: "Stremio",
                    "Metadata pass dropped \(before - continueWatching.count) row(s) that turned out to be finished."
                )
            }
            progress.mergeExternal(continueWatching)
        }
        if !watchedItems.isEmpty { watched.mergeRemote(watchedItems, reconcile: false) }

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
    }

    @MainActor
    static func pushCombined(authKey: String,
                             addonManager: AddonManager,
                             library: LibraryStore,
                             progress: ProgressStore,
                             watched: WatchedStore,
                             clearedProgressIDs: Set<String> = []) async -> PushOutcome {
        var warnings: [String] = []
        var libraryPushed = true

        do {
            try await StremioAccountService.setAddonCollection(authKey: authKey, addons: addonManager.addons)
        } catch {
            warnings.append("add-ons")
            OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Add-on push to Stremio failed: \(error.localizedDescription)")
        }

        let serviceProgress = progress.serviceBackedForSync()
        let savedLibrary = await enrichLibraryItems(library.allForSync(), addonManager: addonManager)
        if savedLibrary != library.allForSync() { library.mergeRemote(savedLibrary, reconcile: false) }
        let items = makeLibraryPutPayload(
            library: savedLibrary,
            progress: serviceProgress,
            watched: watched.allForSync(),
            clearedProgressIDs: clearedProgressIDs
        )
        do {
            try await StremioAccountService.putLibrary(authKey: authKey, items: items)
        } catch {
            libraryPushed = false
            warnings.append("library")
            OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Library push to Stremio failed: \(error.localizedDescription)")
        }

        let summary = "Pushed combined \(addonManager.addons.count) add-ons · \(library.allForSync().count) library · \(serviceProgress.count) in-progress · \(watched.allForSync().count) watched"
        guard !warnings.isEmpty else {
            return PushOutcome(summary: summary, libraryPushed: libraryPushed)
        }
        return PushOutcome(
            summary: "\(summary) · Stremio push failed for \(warnings.joined(separator: ", "))",
            libraryPushed: libraryPushed
        )
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
        let candidates = rawTitleItems + Array(artworkItems.prefix(30))
        guard !candidates.isEmpty else { return items }

        var metaByKey: [String: MetaItem] = [:]
        for item in candidates {
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
        clearedProgressIDs: Set<String> = []
    ) -> [[String: Any]] {
        var rows: [String: [String: Any]] = [:]

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

        for wp in progress {
            guard wp.durationSeconds.isFinite,
                  wp.positionSeconds.isFinite,
                  wp.durationSeconds > 0 else { continue }
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
            var row = rows[id] ?? [
                "_id": id,
                "_ctime": isoString(Date()),
                "id": id,
                "type": "movie",
                "removed": false,
                "temp": true
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

        return Array(rows.values)
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
        var state: [String: Any] = [
            "time_offset": progress.positionSeconds * 1000,
            "duration": progress.durationSeconds * 1000,
            "last_watched": isoString(progress.updatedAt),
            "time_watched": progress.positionSeconds,
            "overall_time_watched": progress.positionSeconds,
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
                hasNewEpisode: entry.hasNewEpisode
            )
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

    /// Stremio datastore values have been seen as both seconds and milliseconds
    /// depending on client/version. Normalize by duration: anything larger than
    /// a day is certainly milliseconds for a movie/episode runtime.
    private static func playbackSeconds(offset: Double?, duration: Double?) -> (Double, Double) {
        let rawOffset = offset ?? 0
        let rawDuration = duration ?? 0
        // Duration is the reliable signal, but it is very often ABSENT (see the
        // import note in `pull`). Keying the scale off duration alone then let a
        // millisecond offset through as seconds: a 50-minute resume point became
        // 3,000,000 "seconds", `enrichContinueWatching` computed a fraction far
        // past 1.0 and dropped the row as finished — silently discarding most
        // duration-less resume points on import. With no duration, fall back to
        // the offset's own magnitude: no movie or episode runs for a day.
        let scale: Double
        if rawDuration > 0 {
            scale = rawDuration > 86_400 ? 1000.0 : 1.0
        } else {
            scale = rawOffset > 86_400 ? 1000.0 : 1.0
        }
        return (rawOffset / scale, rawDuration / scale)
    }
}
