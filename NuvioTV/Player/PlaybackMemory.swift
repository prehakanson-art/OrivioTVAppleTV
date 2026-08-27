import Foundation

// Two small persistent memories that make repeat playback feel deliberate:
//
//  ContainerSniffer   Learns what an extensionless URL actually contains, so
//                     the NEXT open routes to the right engine instead of
//                     re-guessing. First open still defaults to FFmpeg (it
//                     plays everything); the sniff runs alongside and records
//                     the truth for the session's decision log and the cache.
//
//  PlaybackMemory     Per-title choices the user made by hand — engine, audio
//                     language, subtitle language, speed — replayed the next
//                     time the same title plays, so a file that needed VLC
//                     last week doesn't re-fight the same battle.

/// Magic-byte container detection over a ranged HTTP read.
enum ContainerSniffer {
    private static let cacheKey = "nuvio.player.containerCache.v1"
    private static let cacheLimit = 300

    /// A previously learned container for this URL, if any.
    static func cached(_ url: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[url]
    }

    private static func store(_ ext: String, for url: String) {
        var cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        // Cheap bound: clear rather than LRU — relearning costs one ranged read.
        if cache.count >= cacheLimit { cache = [:] }
        cache[url] = ext
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }

    /// Fetch the first bytes and identify the container by signature.
    /// Returns the canonical extension ("mkv", "mp4", "ts", "avi", "flv",
    /// "webm") or nil when unreachable/unrecognised. Result is cached.
    static func sniff(_ urlString: String, headers: [String: String]? = nil) async -> String? {
        if let hit = cached(urlString) { return hit }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        for (key, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              data.count >= 12 else { return nil }
        guard let ext = identify(data) else { return nil }
        store(ext, for: urlString)
        return ext
    }

    /// The signature table. Offsets per the container specs; nothing fuzzy.
    static func identify(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(512))
        guard bytes.count >= 12 else { return nil }
        // EBML — Matroska or WebM; the DocType string in the header says which.
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            let head = String(decoding: data.prefix(256), as: UTF8.self)
            return head.contains("webm") ? "webm" : "mkv"
        }
        // ISO BMFF — "ftyp" at offset 4 (MP4/M4V/MOV family).
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "mp4" }
        // MPEG-TS — 0x47 sync byte repeating every 188 bytes.
        if bytes[0] == 0x47, bytes.count > 188, bytes[188] == 0x47 { return "ts" }
        // RIFF····AVI
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x41, bytes[9] == 0x56, bytes[10] == 0x49 { return "avi" }
        // FLV
        if bytes[0] == 0x46, bytes[1] == 0x4C, bytes[2] == 0x56 { return "flv" }
        return nil
    }
}

/// Remembered per-title playback choices. Only what the USER changed by hand
/// is stored — defaults and automatic picks never overwrite a memory.
struct TitleMemory: Codable {
    var engine: String?
    var audioLanguage: String?
    /// Exact track label ("English · AC3 · 6ch") — languages alone can't
    /// distinguish the AC3 pick from the TrueHD default on an all-English
    /// remux. Label match outranks language match on restore.
    var audioTrackLabel: String?
    /// Subtitle language, or "off" for an explicit off choice.
    var subtitleLanguage: String?
    var speed: Float?
    var updatedAt = Date()
}

enum PlaybackMemory {
    private static let key = "nuvio.player.titleMemory.v1"
    private static let limit = 200

    private static func loadAll() -> [String: TitleMemory] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: TitleMemory].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveAll(_ all: [String: TitleMemory]) {
        var all = all
        // Bound by recency, so a big library can't grow this without limit.
        if all.count > limit {
            let keep = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func memory(for metaID: String) -> TitleMemory? { loadAll()[metaID] }

    static func update(_ metaID: String, _ mutate: (inout TitleMemory) -> Void) {
        var all = loadAll()
        var entry = all[metaID] ?? TitleMemory()
        mutate(&entry)
        entry.updatedAt = Date()
        all[metaID] = entry
        saveAll(all)
    }
}
