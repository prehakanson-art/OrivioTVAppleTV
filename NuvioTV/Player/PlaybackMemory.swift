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

/// Links the viewer walked out on.
///
/// The Auto Link Selector always picks the same "best" source for a title, so a
/// link that is dead, wrong-language, or badly muxed sends you into the player,
/// straight back out, and then into the *same* link again — with no way to say
/// "not that one" short of turning the selector off. This remembers the ones a
/// session bailed out of and takes them out of the running for a while.
///
/// Five minutes of playback is the line. Past it the link demonstrably works,
/// so any earlier grudge against it is dropped — whatever went wrong before was
/// transient (a bad debrid cache, a stalled CDN) and holding it would only push
/// future plays onto worse sources.
enum RejectedLinks {
    private static let key = "nuvio.player.rejectedLinks.v1"
    /// A rejection is a hint, not a verdict — sources come and go, and a link
    /// that failed this morning may be the best one tonight.
    private static let ttl: TimeInterval = 8 * 60 * 60
    /// Titles remembered, newest first.
    private static let titleLimit = 60
    /// Rejections per title. Past this the selector has run out of road and the
    /// list is doing more harm than good.
    private static let perTitleLimit = 6

    private struct Entry: Codable { var links: [String: Date] }

    private static func loadAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveAll(_ all: [String: Entry]) {
        var all = all
        let cutoff = Date().addingTimeInterval(-ttl)
        for (title, entry) in all {
            let fresh = entry.links.filter { $0.value > cutoff }
            if fresh.isEmpty { all.removeValue(forKey: title) } else { all[title] = Entry(links: fresh) }
        }
        if all.count > titleLimit {
            let newest = all.sorted {
                ($0.value.links.values.max() ?? .distantPast)
                    > ($1.value.links.values.max() ?? .distantPast)
            }.prefix(titleLimit)
            all = Dictionary(uniqueKeysWithValues: Array(newest))
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Link keys to avoid for this title right now.
    static func rejected(for titleKey: String) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-ttl)
        guard let entry = loadAll()[titleKey] else { return [] }
        return Set(entry.links.filter { $0.value > cutoff }.keys)
    }

    static func reject(_ linkKey: String, for titleKey: String) {
        guard !linkKey.isEmpty else { return }
        var all = loadAll()
        var entry = all[titleKey] ?? Entry(links: [:])
        entry.links[linkKey] = Date()
        // Oldest rejections fall off first, so a title can't accumulate a list
        // long enough to starve the selector of anything to play.
        if entry.links.count > perTitleLimit {
            let keep = entry.links.sorted { $0.value > $1.value }.prefix(perTitleLimit)
            entry.links = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        all[titleKey] = entry
        saveAll(all)
        NSLog("[OrivioAutoLink] rejected a link for %@ (%d held)", titleKey, entry.links.count)
    }

    /// This link proved itself — drop any rejection standing against it.
    ///
    /// Only this one. Other links rejected for the same title stay rejected:
    /// they failed on their own merits, and one good source says nothing about
    /// the rest.
    static func keep(_ linkKey: String, for titleKey: String) {
        guard !linkKey.isEmpty else { return }
        var all = loadAll()
        guard var entry = all[titleKey],
              entry.links.removeValue(forKey: linkKey) != nil else { return }
        if entry.links.isEmpty { all.removeValue(forKey: titleKey) } else { all[titleKey] = entry }
        saveAll(all)
        NSLog("[OrivioAutoLink] link cleared for %@ (watched past the threshold)", titleKey)
    }
}
