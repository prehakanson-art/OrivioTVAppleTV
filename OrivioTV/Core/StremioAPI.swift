import Foundation
import UIKit

enum StremioAPIError: LocalizedError {
    case badURL(String)
    case badResponse(Int)
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .badURL(let url): return "Invalid addon URL: \(url)"
        case .badResponse(let code): return "Addon returned HTTP \(code)"
        case .emptyBody: return "Addon returned an empty response"
        }
    }
}

/// Small thread-safe TTL cache of raw response bodies keyed by request URL.
/// Addons rarely send `Cache-Control`, so `URLCache` is mostly inert for them;
/// this fills the gap so repeat catalog/meta fetches inside a session (e.g.
/// navigating away and back) are instant instead of another round-trip.
final class StremioResponseCache: @unchecked Sendable {
    private struct Entry { let data: Data; let time: Date }
    private var store: [String: Entry] = [:]
    private let lock = NSLock()
    /// Raw response bodies add up (a catalog page is easily 100s of KB) —
    /// uncapped, a long browse session keeps every response ever fetched in
    /// RAM. Eviction is invisible: a dropped entry is just one round-trip
    /// again. Also emptied outright on a memory warning, same policy as the
    /// image cache (cheapest bytes to give back). Tier-scaled: 96 bodies can
    /// be tens of MB, which the 2–3 GB boxes can't idle on.
    private let entryLimit = PerformanceProfile.isLowPower ? 32
        : PerformanceProfile.isMidPower ? 64 : 96

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.store.removeAll()
        }
    }

    func data(for key: String, ttl: TimeInterval) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = store[key], Date().timeIntervalSince(entry.time) < ttl else { return nil }
        return entry.data
    }

    /// Forget one entry, so the next caller goes back to the network.
    ///
    /// For results that are VALID but not worth remembering — a subtitle addon
    /// answering 200 with an empty list, which is how those fail transiently.
    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    func store(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        store[key] = Entry(data: data, time: Date())
        guard store.count > entryLimit else { return }
        // Drop the oldest half so eviction is amortized, not per-insert.
        let sorted = store.sorted { $0.value.time < $1.value.time }
        for (key, _) in sorted.prefix(store.count - entryLimit / 2) {
            store.removeValue(forKey: key)
        }
    }
}

enum StremioAPI {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        // Memory side tier-scaled — 32 MB of response bodies pinned in RAM is
        // a real bite out of the 2 GB box; disk stays generous.
        config.urlCache = URLCache(
            memoryCapacity: PerformanceProfile.isLowPower ? (8 << 20)
                : PerformanceProfile.isMidPower ? (16 << 20) : (32 << 20),
            diskCapacity: 256 << 20)
        // A single addon (Cinemeta, Torrentio…) usually serves every catalog /
        // stream request from one host; the default cap of 6 makes a Home load
        // fetch its rows 6-at-a-time. Let them all fire in parallel.
        config.httpMaximumConnectionsPerHost = 12
        // Browser-style User-Agent on every addon request. The CFNetwork
        // default UA trips bot protection on Cloudflare/Vercel-fronted addon
        // hosts (e.g. debridmediamanager.com → 403/handshake drop), which made
        // those addons "not respond" here while working from Android (okhttp
        // sends a normal UA).
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (AppleTV; CPU tvOS like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    private static let cache = StremioResponseCache()
    private static let coalescer = RequestCoalescer()
    /// Persistent (cross-launch) cache of enriched meta — episode lists, cast,
    /// etc. — so re-opening a Detail screen or resuming from Continue Watching
    /// paints instantly instead of waiting on the addon meta fetch. TTL kept
    /// modest so a currently-airing show still picks up new episodes soon.
    private static let metaDiskCache = DiskCache<MetaItem>(name: "meta")
    private static let metaDiskTTL: TimeInterval = 30 * 60

    /// `ttl` = how long a cached body stays fresh (0 disables caching for this
    /// request — used for streams, whose links can be short-lived).
    ///
    /// `ttl == 0` MUST ALSO OPT OUT OF THE URL LOADING SYSTEM'S OWN CACHE, or
    /// the "don't cache this" above is only half true. The session runs
    /// `.useProtocolCachePolicy` over a 256 MB DISK `URLCache`, so a stream
    /// response the app deliberately refused to cache was still stored and
    /// replayed by URLSession underneath — for whatever freshness the addon's
    /// headers allow, and (being on disk) across app launches. An addon that
    /// answered badly once then kept answering badly from disk without the
    /// request ever reaching the server, and the short-lived links in a stale
    /// body were already dead, so the sources that did come back failed to
    /// play. That is a self-hosted aggregator "failing" while it is demonstrably
    /// up, staying broken across a relaunch, and coming right only once the
    /// entry expired. Requests with a real `ttl` are unaffected: the app's own
    /// cache is the one that serves them.
    /// `bypassCache` skips the cache READ (and the coalescer, so a health
    /// check times its own request rather than joining one in flight) but
    /// still stores the response for later callers.
    private static func get<T: Decodable>(
        _ urlString: String, ttl: TimeInterval = 0, timeout: TimeInterval = 0,
        bypassCache: Bool = false
    ) async throws -> T {
        if !bypassCache, ttl > 0, let cached = cache.data(for: urlString, ttl: ttl) {
            return try JSONDecoder().decode(T.self, from: cached)
        }
        if bypassCache {
            guard let url = URL(string: urlString) else { throw StremioAPIError.badURL(urlString) }
            var request = URLRequest(url: url)
            if timeout > 0 { request.timeoutInterval = timeout }
            // A health check that can be answered from the URL cache is not a
            // health check. Same reasoning as the ttl == 0 case below.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StremioAPIError.badResponse(http.statusCode)
            }
            if ttl > 0 { cache.store(data, for: urlString) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        // Coalesce concurrent identical fetches into ONE network round-trip —
        // overlapping requests for the same URL (Home rows, prefetch, back-nav)
        // share a single call instead of each hitting the network.
        let data = try await coalescer.data(for: urlString) {
            guard let url = URL(string: urlString) else { throw StremioAPIError.badURL(urlString) }
            var request = URLRequest(url: url)
            if timeout > 0 { request.timeoutInterval = timeout }
            if ttl == 0 { request.cachePolicy = .reloadIgnoringLocalCacheData }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StremioAPIError.badResponse(http.statusCode)
            }
            if ttl > 0 { cache.store(data, for: urlString) }
            return data
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Catalog "extra" VALUES. The addon splits the extras segment with a
    /// query-string parser, so `&`, `=` and `+` are structural there —
    /// `urlPathAllowed` keeps all three, which turned "Law & Order" into
    /// `search=Law ` plus a bogus ` Order` prop, and every "… & …" genre
    /// ("Action & Adventure", "Sci-Fi & Fantasy") into an empty row.
    /// Unreserved characters only, as the query-value encoders elsewhere do.
    private static let extraValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func encodeExtraValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: extraValueAllowed) ?? value
    }

    /// `bypassCache` skips the 5-minute response cache — the health check
    /// must time the NETWORK, not a cached manifest (which reported "OK, 0 ms"
    /// for a host that had just gone down, and could never report "slow").
    static func manifest(url: String, bypassCache: Bool = false) async throws -> AddonManifest {
        try await get(url, ttl: 300, bypassCache: bypassCache)
    }

    static func catalog(
        addon: InstalledAddon,
        catalog: ManifestCatalog,
        search: String? = nil,
        genre: String? = nil,
        skip: Int? = nil
    ) async throws -> [MetaItem] {
        let type = encodePathComponent(catalog.type)
        let id = encodePathComponent(catalog.id)
        var path = "/catalog/\(type)/\(id)"
        // Stremio catalog "extra" args are one path segment; multiple props
        // are joined with `&` (e.g. `/genre=Action&skip=100.json`).
        var extras: [String] = []
        if let search, !search.isEmpty {
            extras.append("search=\(encodeExtraValue(search))")
        } else {
            if let genre, !genre.isEmpty { extras.append("genre=\(encodeExtraValue(genre))") }
            if let skip, skip > 0 { extras.append("skip=\(skip)") }
        }
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        path += ".json"
        // Built through the addon rather than by concatenating `baseURL`: a
        // configured addon keeps its token in the manifest URL's query, and
        // that query has to be re-appended AFTER `.json` or the request goes
        // out unauthenticated and silently returns nothing.
        let url = addon.resourceURL(path)
        // Don't cache search results (query-specific, one-shot); catalogs are
        // cached briefly so revisiting Home is instant.
        let ttl: TimeInterval = (search?.isEmpty == false) ? 0 : 120
        let response: CatalogResponse = try await get(url, ttl: ttl)
        // De-dup by id: duplicate identifiers in a catalog crash the tvOS focus
        // engine when rendered in a ForEach (aggregator addons emit them).
        return (response.metas ?? []).filter { !$0.name.isEmpty }.deduplicatedByID()
    }

    static func meta(addon: InstalledAddon, type: String, id: String) async throws -> MetaItem {
        // Via `resourceURL` so a configured addon's manifest query (its
        // token) rides along after `.json` instead of being dropped.
        let url = addon.resourceURL("/meta/\(encodePathComponent(type))/\(encodePathComponent(id)).json")
        if let cached = await metaDiskCache.value(for: url, ttl: metaDiskTTL) { return cached }
        let response: MetaResponse = try await get(url, ttl: 600)
        guard let meta = response.meta else { throw StremioAPIError.emptyBody }
        await metaDiskCache.store(meta, for: url)
        return meta
    }

    static func streams(addon: InstalledAddon, type: String, id: String,
                        timeout: TimeInterval = 45) async throws -> [Stream] {
        // Via `resourceURL` so a configured addon's manifest query (its
        // token) rides along after `.json` instead of being dropped.
        let url = addon.resourceURL("/stream/\(encodePathComponent(type))/\(encodePathComponent(id)).json")
        // Stream searches get a LONGER deadline than the session's 20s
        // default. Live torrent scrapers (Comet with cachedOnly=false,
        // Torrentio under load) legitimately compute for 15-20s before
        // sending their first byte — measured 16.2s for a healthy Comet
        // answer that then delivered 2,000+ streams. Under the 20s idle
        // timeout those addons "didn't work" on exactly the titles with the
        // most sources, while fast addons masked the problem. The sources
        // sweep is parallel and reveals results per addon as they land, so a
        // slow scraper arriving late costs nothing but its own lateness.
        // User-adjustable (Settings → Playback → Source search patience) for
        // aggregators that fan out to Usenet indexers and outlast even 45s.
        let response: StreamsResponse = try await get(url, timeout: max(timeout, 20))
        return response.streams ?? []
    }

    struct AddonSubtitle: Codable {
        let id: String?
        let url: String
        let lang: String?
    }

    private struct SubtitlesResponse: Codable {
        let subtitles: [AddonSubtitle]?
    }

    /// Stremio subtitle addons (e.g. OpenSubtitles): `/subtitles/{type}/{id}.json`.
    static func subtitles(addon: InstalledAddon, type: String, id: String) async throws -> [AddonSubtitle] {
        // Via `resourceURL` so a configured addon's manifest query (its
        // token) rides along after `.json` instead of being dropped.
        let url = addon.resourceURL("/subtitles/\(encodePathComponent(type))/\(encodePathComponent(id)).json")
        let response: SubtitlesResponse = try await get(url, ttl: 600)
        let subtitles = response.subtitles ?? []
        // AN EMPTY LIST IS NOT AN ANSWER WORTH REMEMBERING FOR TEN MINUTES.
        //
        // A subtitle addon that is rate-limited or briefly unwell does not
        // return an HTTP error — OpenSubtitles v3 in particular answers 200
        // with `{"subtitles":[]}`. The failure paths above all throw before
        // reaching the cache, so those are safe; this one looks like a
        // perfectly good response and gets stored, and every later open of the
        // same title is then served "no subtitles" from memory without the
        // request ever leaving the box. That is the reported "subtitles
        // occasionally fail even though they exist, and only a restart fixes
        // it" — a restart being the one thing that clears this in-memory cache.
        //
        // Dropping the entry costs one round trip per open of a title that
        // genuinely has none, and buys a retry for every title that briefly
        // looked that way. A non-empty result is cached exactly as before.
        if subtitles.isEmpty { cache.remove(url) }
        return subtitles
    }
}
