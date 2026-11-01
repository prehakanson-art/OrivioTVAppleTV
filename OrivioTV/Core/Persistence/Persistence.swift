import Foundation
import Compression

/// Storage rules (tvOS):
/// - Only `Library/Caches` and `tmp` are writable; writes elsewhere fail silently.
/// - UserDefaults aborts at 1 MB (`…TRYING_TO_STORE_TOO_MUCH_DATA` is a SIGABRT),
///   so payloads are zlib-compressed behind a 4-byte `OAZ1` magic, and anything
///   still above the safe ceiling spills to a file under `Library/Caches/OrivioData`
///   (kept out of `OrivioCache` so "Clear cache" doesn't delete history).
/// - Per-profile keys carry `.pN`. Reads fall back to the legacy un-suffixed key
///   only when the scoped key is absent and only for profile 1, so removals must
///   write empty markers, never delete the key.
enum Persistence {
    static let defaults = UserDefaults.standard
    static let prefix = "orivio."
    /// The daemon enforces the limit per write *and* over the domain, so keep
    /// every defaults blob far below 1 MB and spill the rest to a file.
    private static let maxDefaultsBytes = 256_000

    // MARK: Keys

    static func key(_ base: String) -> String { prefix + base }

    static func key(_ base: String, profile: Int) -> String { prefix + base + ".p\(profile)" }

    // MARK: Compression (raw DEFLATE, OAZ1 magic)

    private static let magic = Data("OAZ1".utf8)

    static func compress(_ data: Data) -> Data {
        guard data.count > 512, let deflated = try? (data as NSData).compressed(using: .zlib) as Data else {
            return data
        }
        return magic + deflated
    }

    static func decompress(_ data: Data) -> Data {
        guard data.count > 4, data.prefix(4) == magic else { return data }
        let body = data.dropFirst(4)
        return (try? (Data(body) as NSData).decompressed(using: .zlib) as Data) ?? Data()
    }

    // MARK: Codable blobs

    static func rawData(forKey key: String) -> Data? {
        if let raw = try? Data(contentsOf: blobURL(for: key)) { return decompress(raw) }
        guard let raw = defaults.data(forKey: key) else { return nil }
        return decompress(raw)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = rawData(forKey: key) else { return nil }
        return try? JSONDecoder.orivio.decode(T.self, from: data)
    }

    /// Persists can now run on `writeQueue` while a `saveNow()` flush runs on
    /// main, so the encode goes through one lock: `JSONEncoder.orivio` is a
    /// single shared instance and two threads encoding on it at once is not a
    /// supported use.
    private static let encodeLock = NSLock()

    private static func encoded<T: Encodable>(_ value: T) -> Data? {
        encodeLock.lock(); defer { encodeLock.unlock() }
        return try? JSONEncoder.orivio.encode(value)
    }

    static func save<T: Encodable>(_ value: T, key: String, compressed: Bool = true) {
        guard let data = encoded(value) else { return }
        let payload = compressed ? compress(data) : data
        let url = blobURL(for: key)
        if blocksDefaults {
            try? payload.write(to: url, options: .atomic)
            return
        }
        if payload.count > maxDefaultsBytes {
            if (try? payload.write(to: url, options: .atomic)) != nil {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(payload, forKey: key)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Off-main writes

    /// Debounced and user-action saves run here. Encoding, zlib compression and
    /// the write are real CPU — a progress or library blob is easily hundreds of
    /// KB — and on the main thread they land between two frames: a stutter while
    /// a film plays, a late button after "Add to Library". FIFO, so the last
    /// snapshot written for a key is the one left on disk. `saveNow()`/`flushAll`
    /// stay synchronous: that is the flush before the app is suspended.
    static let writeQueue = DispatchQueue(label: "orivio.persistence.write", qos: .utility)

    static func saveInBackground<T: Encodable>(_ value: T, key: String, compressed: Bool = true) {
        writeQueue.async { save(value, key: key, compressed: compressed) }
    }

    static func saveScopedInBackground<T: Encodable>(_ value: T, base: String, profile: Int) {
        writeQueue.async { saveScoped(value, base: base, profile: profile) }
    }

    static func saveFileInBackground<T: Encodable>(_ value: T, url: URL, compressed: Bool = false) {
        writeQueue.async { saveFile(value, url: url, compressed: compressed) }
    }

    static func hasValue(key: String) -> Bool {
        defaults.object(forKey: key) != nil || FileManager.default.fileExists(atPath: blobURL(for: key).path)
    }

    /// Per-profile load with the legacy fallback (profile 1 only, scoped key absent).
    static func loadScoped<T: Decodable>(_ type: T.Type, base: String, profile: Int) -> T? {
        let scoped = key(base, profile: profile)
        if hasValue(key: scoped) { return load(type, key: scoped) }
        if profile == 1 { return load(type, key: key(base)) }
        return nil
    }

    static func saveScoped<T: Encodable>(_ value: T, base: String, profile: Int) {
        save(value, key: key(base, profile: profile))
    }

    /// Rescues any defaults blob already over the ceiling into a file so a legacy
    /// oversized value can't wedge the app in a SIGABRT loop.
    ///
    /// Once a process has loaded an oversized domain, cfprefsd keeps rejecting
    /// *every* write from that process — even after the key is gone. So this
    /// launch persists all writes to files instead; the next launch merges the
    /// small primitive overflow back into defaults and is normal again.
    static private(set) var blocksDefaults = false
    private static let totalDefaultsLimit = 500_000

    static func reclaimOversizedBlobs() {
        var payloads: [(String, Data)] = []
        var total = 0
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix(prefix) {
            if let d = v as? Data {
                payloads.append((k, d))
                total += d.count
            } else if let s = v as? String {
                total += s.utf8.count
            }
        }
        var changed = false
        for (k, d) in payloads.sorted(by: { $0.1.count > $1.1.count }) {
            guard d.count > maxDefaultsBytes || total > totalDefaultsLimit else { break }
            if (try? d.write(to: blobURL(for: k), options: .atomic)) != nil {
                defaults.removeObject(forKey: k)
                total -= d.count
                changed = true
            }
        }
        if changed {
            blocksDefaults = true
            defaults.synchronize()
        } else {
            mergeOverflow()
        }
    }

    // MARK: Primitive overflow (recovery launches only)

    private static let overflowLock = NSLock()
    private static var overflowCache: [String: Any]?

    private static var overflowURL: URL { dataURL.appendingPathComponent("prefs-overflow.plist") }

    private static func overflowLookup(_ key: String) -> (found: Bool, value: Any?) {
        overflowLock.lock()
        defer { overflowLock.unlock() }
        if overflowCache == nil {
            let data = try? Data(contentsOf: overflowURL)
            overflowCache = data.flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            } ?? [:]
        }
        guard let raw = overflowCache?[key] else { return (false, nil) }
        return (true, raw is NSNull ? nil : raw)
    }

    private static func overflowSet(_ value: Any?, forKey key: String) {
        overflowLock.lock()
        defer { overflowLock.unlock() }
        if overflowCache == nil {
            let data = try? Data(contentsOf: overflowURL)
            overflowCache = data.flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            } ?? [:]
        }
        overflowCache?[key] = value ?? NSNull()
        if let data = try? PropertyListSerialization.data(fromPropertyList: overflowCache ?? [:],
                                                          format: .binary, options: 0) {
            try? data.write(to: overflowURL, options: .atomic)
        }
    }

    private static func mergeOverflow() {
        overflowLock.lock()
        var values: [String: Any] = [:]
        if let data = try? Data(contentsOf: overflowURL) {
            values = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
        }
        overflowCache = nil
        overflowLock.unlock()
        guard !values.isEmpty else { return }
        for (k, v) in values {
            if v is NSNull { defaults.removeObject(forKey: k) } else { defaults.set(v, forKey: k) }
        }
        try? FileManager.default.removeItem(at: overflowURL)
    }

    private static func overflowRemove(_ key: String) {
        overflowLock.lock()
        defer { overflowLock.unlock() }
        if overflowCache == nil {
            let data = try? Data(contentsOf: overflowURL)
            overflowCache = data.flatMap {
                try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
            } ?? [:]
        }
        guard overflowCache?[key] != nil else { return }
        overflowCache?.removeValue(forKey: key)
        if let cache = overflowCache, !cache.isEmpty,
           let data = try? PropertyListSerialization.data(fromPropertyList: cache, format: .binary, options: 0) {
            try? data.write(to: overflowURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: overflowURL)
        }
    }

    private static func primitive(forKey key: String) -> Any? {
        let (found, value) = overflowLookup(key)
        if found { return value }
        return defaults.object(forKey: key)
    }

    static func bool(forKey key: String) -> Bool {
        let value = primitive(forKey: key)
        if let b = value as? Bool { return b }
        return (value as? NSNumber)?.boolValue ?? false
    }

    static func integer(forKey key: String) -> Int {
        (primitive(forKey: key) as? NSNumber)?.intValue ?? 0
    }

    static func string(forKey key: String) -> String? {
        primitive(forKey: key) as? String
    }

    static func dataValue(forKey key: String) -> Data? {
        primitive(forKey: key) as? Data
    }

    static func set(_ value: Any?, forKey key: String) {
        if let data = value as? Data, data.count > maxDefaultsBytes,
           (try? data.write(to: blobURL(for: key), options: .atomic)) != nil {
            if !blocksDefaults { defaults.removeObject(forKey: key) }
            return
        }
        if blocksDefaults {
            overflowSet(value, forKey: key)
        } else {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            // A value left in the overflow file would shadow this write.
            overflowRemove(key)
        }
    }

    // MARK: Files

    static var cachesURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// `Library/Caches/OrivioCache` — app-owned files that survive "Clear cache"
    /// selectively (collections library and plugin scripts are kept).
    static var orivioCacheURL: URL {
        let url = cachesURL.appendingPathComponent("OrivioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileURL(_ name: String) -> URL { orivioCacheURL.appendingPathComponent(name) }

    /// `Library/Caches/OrivioData` — persistent app data (watch history, progress).
    /// Deliberately outside `OrivioCache` so clearing image/stream caches keeps it.
    static var dataURL: URL {
        let url = cachesURL.appendingPathComponent("OrivioData", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func blobURL(for key: String) -> URL {
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return dataURL.appendingPathComponent(name)
    }

    static func loadFile<T: Decodable>(_ type: T.Type, url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.orivio.decode(T.self, from: decompress(data))
    }

    static func saveFile<T: Encodable>(_ value: T, url: URL, compressed: Bool = false) {
        guard let data = encoded(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (compressed ? compress(data) : data).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let orivio: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) {
                // Accept both seconds and milliseconds since 1970.
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            let s = try c.decode(String.self)
            if let date = DateParsing.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }()
}

extension JSONEncoder {
    static let orivio: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
}

/// Cached, static date formatters — per-call formatter allocation was a
/// measured hot-path cost.
enum DateParsing {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let mediumDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        if let d = isoNoFraction.date(from: s) { return d }
        if s.count >= 10, let d = day.date(from: String(s.prefix(10))) { return d }
        return nil
    }
}
