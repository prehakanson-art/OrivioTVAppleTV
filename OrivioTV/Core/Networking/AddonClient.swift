import Foundation
import UIKit

/// Small in-memory TTL cache for decoded responses, sized by device tier and
/// purged on memory warnings.
final class ResponseCache<Value> {
    private struct Entry { let value: Value; let expires: Date; var lastUse: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let capacity: Int
    private let ttl: TimeInterval
    private var observer: NSObjectProtocol?

    init(capacity: Int, ttl: TimeInterval) {
        self.capacity = capacity
        self.ttl = ttl
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                          object: nil, queue: nil) { [weak self] _ in self?.removeAll() }
    }

    func get(_ key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[key] else { return nil }
        if e.expires < Date() { entries[key] = nil; return nil }
        e.lastUse = Date()
        entries[key] = e
        return e.value
    }

    func set(_ key: String, _ value: Value, ttl customTTL: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(value: value, expires: Date().addingTimeInterval(customTTL ?? ttl), lastUse: Date())
        if entries.count > capacity {
            let victims = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(entries.count - capacity)
            for v in victims { entries[v.key] = nil }
        }
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = nil
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

/// The Stremio add-on protocol.
enum AddonClient {
    static let catalogCache = ResponseCache<[MetaItem]>(capacity: PerformanceProfile.responseCacheEntries, ttl: 30 * 60)
    static let metaCache = ResponseCache<MetaItem>(capacity: PerformanceProfile.responseCacheEntries * 2, ttl: 60 * 60)
    static let subtitleCache = ResponseCache<[AddonSubtitle]>(capacity: 32, ttl: 10 * 60)

    // MARK: Manifest

    static func fetchManifest(_ manifestURL: String, timeout: TimeInterval = 15) async throws -> AddonManifest {
        let normalized = InstalledAddon.normalizeManifestURL(manifestURL)
        guard let url = URL(string: normalized) else { throw HTTPError.badURL(manifestURL) }
        let data = try await HTTP.data(url, fresh: true, timeout: timeout)
        guard let manifest = try? JSONDecoder.orivio.decode(AddonManifest.self, from: data) else {
            return .placeholder()
        }
        return manifest
    }

    // MARK: Catalog

    static func catalogURL(_ addon: InstalledAddon, type: String, id: String, extras: [String: String]) -> URL? {
        var path = "\(addon.baseURL)/catalog/\(HTTP.encodeComponent(type))/\(HTTP.encodeComponent(id))"
        let extraString = extras.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(HTTP.encodeComponent($0.key))=\(HTTP.encodeComponent($0.value))" }
            .joined(separator: "&")
        if !extraString.isEmpty { path += "/\(extraString)" }
        path += ".json"
        if let q = URL(string: addon.manifestURL)?.query, !q.isEmpty { path += "?\(q)" }
        return URL(string: path)
    }

    static func catalog(_ addon: InstalledAddon, type: String, id: String, extras: [String: String] = [:],
                        timeout: TimeInterval = 20) async throws -> [MetaItem] {
        guard let url = catalogURL(addon, type: type, id: id, extras: extras) else { throw HTTPError.badURL(addon.baseURL) }
        let key = url.absoluteString
        if let hit = catalogCache.get(key) { return hit }
        let response = try await HTTP.json(CatalogResponse.self, url: url, timeout: timeout)
        let metas = response.metas.map { m -> MetaItem in
            var m = m
            if m.type.isEmpty { m.type = type }
            return m
        }
        catalogCache.set(key, metas)
        return metas
    }

    // MARK: Meta

    static func meta(_ addon: InstalledAddon, type: String, id: String) async throws -> MetaItem? {
        let path = "\(addon.baseURL)/meta/\(HTTP.encodeComponent(type))/\(HTTP.encodeComponent(id)).json"
        guard let url = URL(string: path) else { return nil }
        let key = url.absoluteString
        if let hit = metaCache.get(key) { return hit }
        let response = try await HTTP.json(MetaResponse.self, url: url, timeout: 20)
        guard var meta = response.meta, !meta.id.isEmpty || !meta.name.isEmpty else { return nil }
        if meta.id.isEmpty { meta.id = id }
        if meta.type.isEmpty { meta.type = type }
        metaCache.set(key, meta)
        return meta
    }

    // MARK: Streams (never cached)

    static func streams(_ addon: InstalledAddon, type: String, id: String, timeout: TimeInterval) async throws -> [Stream] {
        var path = "\(addon.baseURL)/stream/\(HTTP.encodeComponent(type))/\(HTTP.encodeComponent(id)).json"
        if let q = URL(string: addon.manifestURL)?.query, !q.isEmpty { path += "?\(q)" }
        guard let url = URL(string: path) else { throw HTTPError.badURL(addon.baseURL) }
        let request = HTTP.request(url, fresh: true, timeout: timeout)
        return try await HTTP.json(StreamsResponse.self, request, session: HTTP.ephemeral).streams
    }

    // MARK: Subtitles (10 min; an empty list is evicted — rate-limited add-ons answer 200 [])

    static func subtitles(_ addon: InstalledAddon, type: String, id: String, extras: [String: String] = [:]) async throws -> [AddonSubtitle] {
        var path = "\(addon.baseURL)/subtitles/\(HTTP.encodeComponent(type))/\(HTTP.encodeComponent(id))"
        let extraString = extras.sorted { $0.key < $1.key }
            .map { "\(HTTP.encodeComponent($0.key))=\(HTTP.encodeComponent($0.value))" }.joined(separator: "&")
        if !extraString.isEmpty { path += "/\(extraString)" }
        path += ".json"
        guard let url = URL(string: path) else { throw HTTPError.badURL(addon.baseURL) }
        let key = url.absoluteString
        if let hit = subtitleCache.get(key) { return hit }
        let request = HTTP.request(url, fresh: true, timeout: 15)
        let subs = try await HTTP.json(SubtitlesResponse.self, request, session: HTTP.ephemeral).subtitles.map { s -> AddonSubtitle in
            var s = s
            s.addonName = addon.displayName
            return s
        }
        if subs.isEmpty { subtitleCache.remove(key) } else { subtitleCache.set(key, subs) }
        return subs
    }
}
