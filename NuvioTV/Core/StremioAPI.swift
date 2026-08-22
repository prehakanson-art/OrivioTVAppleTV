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
    /// image cache (cheapest bytes to give back).
    private let entryLimit = 96

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
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
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
    private static func get<T: Decodable>(_ urlString: String, ttl: TimeInterval = 0) async throws -> T {
        if ttl > 0, let cached = cache.data(for: urlString, ttl: ttl) {
            return try JSONDecoder().decode(T.self, from: cached)
        }
        // Coalesce concurrent identical fetches into ONE network round-trip —
        // overlapping requests for the same URL (Home rows, prefetch, back-nav)
        // share a single call instead of each hitting the network.
        let data = try await coalescer.data(for: urlString) {
            guard let url = URL(string: urlString) else { throw StremioAPIError.badURL(urlString) }
            var request = URLRequest(url: url)
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

    static func manifest(url: String) async throws -> AddonManifest {
        try await get(url, ttl: 300)
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
        var url = "\(addon.baseURL)/catalog/\(type)/\(id)"
        // Stremio catalog "extra" args are one path segment; multiple props
        // are joined with `&` (e.g. `/genre=Action&skip=100.json`).
        var extras: [String] = []
        if let search, !search.isEmpty {
            extras.append("search=\(encodePathComponent(search))")
        } else {
            if let genre, !genre.isEmpty { extras.append("genre=\(encodePathComponent(genre))") }
            if let skip, skip > 0 { extras.append("skip=\(skip)") }
        }
        if !extras.isEmpty { url += "/" + extras.joined(separator: "&") }
        url += ".json"
        // Don't cache search results (query-specific, one-shot); catalogs are
        // cached briefly so revisiting Home is instant.
        let ttl: TimeInterval = (search?.isEmpty == false) ? 0 : 120
        let response: CatalogResponse = try await get(url, ttl: ttl)
        // De-dup by id: duplicate identifiers in a catalog crash the tvOS focus
        // engine when rendered in a ForEach (aggregator addons emit them).
        return (response.metas ?? []).filter { !$0.name.isEmpty }.deduplicatedByID()
    }

    static func meta(addon: InstalledAddon, type: String, id: String) async throws -> MetaItem {
        let url = "\(addon.baseURL)/meta/\(encodePathComponent(type))/\(encodePathComponent(id)).json"
        if let cached = await metaDiskCache.value(for: url, ttl: metaDiskTTL) { return cached }
        let response: MetaResponse = try await get(url, ttl: 600)
        guard let meta = response.meta else { throw StremioAPIError.emptyBody }
        await metaDiskCache.store(meta, for: url)
        return meta
    }

    static func streams(addon: InstalledAddon, type: String, id: String) async throws -> [Stream] {
        let url = "\(addon.baseURL)/stream/\(encodePathComponent(type))/\(encodePathComponent(id)).json"
        let response: StreamsResponse = try await get(url)
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
        let url = "\(addon.baseURL)/subtitles/\(encodePathComponent(type))/\(encodePathComponent(id)).json"
        let response: SubtitlesResponse = try await get(url, ttl: 600)
        return response.subtitles ?? []
    }
}
