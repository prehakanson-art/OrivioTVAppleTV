import Compression
import Foundation

/// One guide entry (XMLTV `<programme>`).
struct EPGProgramme: Codable, Hashable, Identifiable {
    var start: Date
    var end: Date
    var title: String
    var desc: String?

    var id: Int { Int(start.timeIntervalSince1970) }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func isLive(at now: Date) -> Bool { start <= now && now < end }
    func progress(at now: Date) -> Double {
        duration > 0 ? min(1, max(0, now.timeIntervalSince(start) / duration)) : 0
    }
}

/// The TV guide: XMLTV from the IPTV provider (`xmltv.php`), the playlist's
/// own `url-tvg`, or a URL the viewer sets. Files can be tens of MB (often
/// gzipped), so they're streamed to disk, inflated in chunks and parsed with
/// a SAX parser — keeping only this viewer's channels, inside the catch-up
/// window and the next few days. Cached on disk; refreshed every 12 h.
@MainActor
final class EPGGuide: ObservableObject {
    static let shared = EPGGuide()

    @Published private(set) var programmes: [String: [EPGProgramme]] = [:]
    /// Cached day bounds. This used to scan every programme of every channel
    /// from every guide row (twice) on each redraw.
    private(set) var range: ClosedRange<Date>?
    @Published private(set) var updated: Date?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// Normalised display name → XMLTV channel id (for channels without a tvg-id).
    private var names: [String: String] = [:]
    /// LiveChannel.id → XMLTV channel id, resolved once per load.
    private var keyCache: [String: String?] = [:]
    private var sourceKey = ""
    private let cacheURL = Persistence.fileURL("epg-guide.json")
    private static let maxAge: TimeInterval = 12 * 3600

    private struct Snapshot: Codable {
        var updated: Date
        var sourceKey: String
        var programmes: [String: [EPGProgramme]]
        var names: [String: String]
    }

    private init() {
        if let s = Persistence.loadFile(Snapshot.self, url: cacheURL) {
            programmes = s.programmes
            names = s.names
            updated = s.updated
            sourceKey = s.sourceKey
            range = Self.dateRange(s.programmes)
        }
    }

    private static func dateRange(_ programmes: [String: [EPGProgramme]]) -> ClosedRange<Date>? {
        var lo: Date?, hi: Date?
        for list in programmes.values {
            if let f = list.first?.start { lo = min(lo ?? f, f) }
            if let l = list.last?.end { hi = max(hi ?? l, l) }
        }
        guard let lo, let hi, lo < hi else { return nil }
        return lo...hi
    }

    // MARK: Lookup

    /// The XMLTV channel a live channel maps to: its tvg-id, else its name.
    func key(for c: LiveChannel) -> String? {
        // The value is `String?`, so bind once and return the cached nil too:
        // channels with no guide used to re-normalise their name on every row redraw.
        if let cached = keyCache[c.id] { return cached }
        var k: String?
        if let t = c.tvgID?.lowercased(), !t.isEmpty, programmes[t] != nil { k = t }
        else if let byName = names[Self.normalize(c.name)], programmes[byName] != nil { k = byName }
        keyCache[c.id] = k
        return k
    }

    func hasGuide(for c: LiveChannel) -> Bool { key(for: c) != nil }

    /// Entries overlapping [from, to), in order.
    func programmes(for c: LiveChannel, from: Date, to: Date) -> [EPGProgramme] {
        guard let k = key(for: c), let list = programmes[k] else { return [] }
        // First entry that ends after `from` (binary search; the list is sorted).
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].end <= from { lo = mid + 1 } else { hi = mid }
        }
        var out: [EPGProgramme] = []
        var i = lo
        while i < list.count, list[i].start < to { out.append(list[i]); i += 1 }
        return out
    }

    func nowNext(for c: LiveChannel, at now: Date = Date()) -> (now: EPGProgramme?, next: EPGProgramme?) {
        let list = programmes(for: c, from: now, to: now.addingTimeInterval(12 * 3600))
        let current = list.first { $0.isLive(at: now) }
        let next = list.first { $0.start >= (current?.end ?? now) }
        return (current, next)
    }

    // MARK: Loading

    /// Guide sources for the current Live TV setup, best first.
    static func sources(_ s: LiveTVSettings, playlistGuides: [URL]) -> [URL] {
        var out: [URL] = []
        if let u = URL(string: s.epgURL.trimmingCharacters(in: .whitespaces)), !s.epgURL.isEmpty { out.append(u) }
        if !s.xtreamServer.isEmpty, !s.xtreamUsername.isEmpty, let u = Xtream.xmltvURL(server: s.xtreamServer, user: s.xtreamUsername, pass: s.xtreamPassword) {
            out.append(u)
        }
        out += playlistGuides
        // Nothing else (the free public channel lists carry no guide): epg.pw's
        // per-country XMLTV, matched to channels by name.
        if out.isEmpty {
            let country = (s.country.isEmpty ? (Locale.current.region?.identifier ?? "") : s.country).uppercased()
            let code = country == "UK" ? "GB" : country
            if code.count == 2, let u = URL(string: "https://epg.pw/xmltv/epg_\(code).xml.gz") { out.append(u) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.absoluteString).inserted }
    }

    func loadIfNeeded(channels: [LiveChannel], sources: [URL]) async {
        let key = sources.map(\.absoluteString).joined(separator: "|")
        let fresh = updated.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false
        if key == sourceKey, fresh, !programmes.isEmpty { return }
        await refresh(channels: channels, sources: sources)
    }

    func refresh(channels: [LiveChannel], sources: [URL]) async {
        guard !loading else { return }
        guard !sources.isEmpty else {
            error = "No guide source. Your provider or playlist doesn't offer one — add a Guide URL in Settings → Content."
            return
        }
        loading = true
        error = nil
        defer { loading = false }

        let wantedIDs = Set(channels.compactMap { $0.tvgID?.lowercased() }.filter { !$0.isEmpty })
        let wantedNames = Set(channels.map { Self.normalize($0.name) })
        let maxArchive = channels.compactMap(\.archiveDays).max() ?? 0
        let now = Date()
        // Past listings only as far back as catch-up reaches (else the last few hours).
        let windowMin = maxArchive > 0 ? Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(maxArchive) * 86400))
                                        : now.addingTimeInterval(-6 * 3600)
        let windowMax = now.addingTimeInterval(4 * 86400)

        var merged: [String: [EPGProgramme]] = [:]
        var mergedNames: [String: String] = [:]
        var failures: [String] = []
        for src in sources {
            do {
                let file = try await Self.download(src)
                let result = try await Task.detached(priority: .utility) {
                    try XMLTVReader.parse(file: file, wantedIDs: wantedIDs, wantedNames: wantedNames,
                                          from: windowMin, to: windowMax)
                }.value
                try? FileManager.default.removeItem(at: file)
                for (k, v) in result.programmes where merged[k] == nil { merged[k] = v }
                mergedNames.merge(result.names) { a, _ in a }
            } catch {
                failures.append("\(src.host ?? "Guide"): \(error.localizedDescription)")
            }
        }
        guard !merged.isEmpty else {
            error = failures.first ?? "The guide had no listings for your channels."
            return
        }
        programmes = merged
        range = Self.dateRange(merged)
        names = mergedNames
        keyCache = [:]
        updated = Date()
        sourceKey = sources.map(\.absoluteString).joined(separator: "|")
        let snapshot = Snapshot(updated: updated!, sourceKey: sourceKey, programmes: merged, names: mergedNames)
        let url = cacheURL
        Task.detached(priority: .background) { Persistence.saveFile(snapshot, url: url, compressed: true) }
    }

    /// The channel list changed (new playlist): re-resolve names → ids.
    func channelsChanged() { keyCache = [:] }

    // MARK: Helpers

    /// "UK: Sky Sports Main Event HD" and "Sky Sports Main Event" match.
    nonisolated static func normalize(_ name: String) -> String {
        var s = name.lowercased()
        // A short country/provider prefix: "uk:", "us |", "[uk]".
        if let r = s.range(of: #"^\s*[\[\(]?[a-z]{2,4}[\]\)]?\s*[:|\-]\s+"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^\s*[\[\(][a-z]{2,4}[\]\)]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        let noise: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "raw", "backup", "50fps", "60fps"]
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" }).map(String.init).filter { !noise.contains($0) }
        var joined = words.joined()
        // Run-together names ("SkyPremiereHD") carry the quality as a suffix.
        for suffix in ["uhd", "fhd", "hd", "4k"] where joined.count > suffix.count + 2 && joined.hasSuffix(suffix) {
            joined.removeLast(suffix.count)
            break
        }
        return joined
    }

    /// Downloads to a temp file, inflating gzip (by magic, not by name) on the way.
    private static func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.setValue("Orivio/1.0 (AppleTV)", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw HTTPError.other("HTTP \(http.statusCode)")
        }
        let dir = FileManager.default.temporaryDirectory
        let raw = dir.appendingPathComponent("epg-\(UUID().uuidString).raw")
        try FileManager.default.moveItem(at: tmp, to: raw)
        guard Gunzip.isGzip(raw) else { return raw }
        let xml = dir.appendingPathComponent("epg-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await Task.detached(priority: .utility) { try Gunzip.inflate(raw, to: xml) }.value
        return xml
    }
}

// MARK: - XMLTV

/// SAX reader for XMLTV. Channels come first in the file, so display names are
/// known before programmes and name-only matches can be kept on the fly.
final class XMLTVReader: NSObject, XMLParserDelegate {
    struct Result { var programmes: [String: [EPGProgramme]]; var names: [String: String] }

    private var wantedIDs: Set<String>
    private let wantedNames: Set<String>
    private let from: TimeInterval
    private let to: TimeInterval
    private var out: [String: [EPGProgramme]] = [:]
    private var names: [String: String] = [:]

    private var channelID: String?
    private var progChannel: String?
    private var progStart: TimeInterval = 0
    private var progEnd: TimeInterval = 0
    private var title: String?
    private var desc: String?
    private var collecting: String?
    private var text = ""

    private init(wantedIDs: Set<String>, wantedNames: Set<String>, from: Date, to: Date) {
        self.wantedIDs = wantedIDs
        self.wantedNames = wantedNames
        self.from = from.timeIntervalSince1970
        self.to = to.timeIntervalSince1970
    }

    static func parse(file: URL, wantedIDs: Set<String>, wantedNames: Set<String>, from: Date, to: Date) throws -> Result {
        guard let stream = InputStream(url: file) else { throw HTTPError.other("Couldn't open the guide.") }
        let reader = XMLTVReader(wantedIDs: wantedIDs, wantedNames: wantedNames, from: from, to: to)
        let parser = XMLParser(stream: stream)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), reader.out.isEmpty {
            throw parser.parserError ?? HTTPError.other("The guide isn't valid XMLTV.")
        }
        // Sorted, without duplicate starts (several sources / repeated blocks).
        for (k, list) in reader.out {
            var seen = Set<Int>()
            reader.out[k] = list.sorted { $0.start < $1.start }.filter { seen.insert($0.id).inserted }
        }
        return Result(programmes: reader.out, names: reader.names)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name {
        case "channel":
            channelID = a["id"]?.lowercased()
        case "display-name":
            if channelID != nil { collecting = name; text = "" }
        case "programme":
            progChannel = nil
            guard let ch = a["channel"]?.lowercased(), wantedIDs.contains(ch),
                  let s = a["start"].flatMap(Self.time), let e = a["stop"].flatMap(Self.time),
                  e > from, s < to, e > s else { return }
            progChannel = ch
            progStart = s
            progEnd = e
            title = nil
            desc = nil
        case "title":
            if progChannel != nil, title == nil { collecting = name; text = "" }
        case "desc":
            if progChannel != nil, desc == nil { collecting = name; text = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting != nil, text.count < 600 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "display-name":
            guard collecting == name, let id = channelID else { break }
            let n = EPGGuide.normalize(text)
            if !n.isEmpty, names[n] == nil { names[n] = id }
            if wantedNames.contains(n) { wantedIDs.insert(id) }
            collecting = nil
        case "channel":
            channelID = nil
        case "title":
            if collecting == name { title = text.trimmingCharacters(in: .whitespacesAndNewlines); collecting = nil }
        case "desc":
            if collecting == name {
                let d = text.trimmingCharacters(in: .whitespacesAndNewlines)
                desc = d.isEmpty ? nil : String(d.prefix(400))
                collecting = nil
            }
        case "programme":
            if let ch = progChannel {
                let t = (title?.isEmpty == false ? title! : "Untitled")
                out[ch, default: []].append(EPGProgramme(start: Date(timeIntervalSince1970: progStart),
                                                         end: Date(timeIntervalSince1970: progEnd), title: t, desc: desc))
            }
            progChannel = nil
        default:
            break
        }
    }

    /// "20261013140000 +0100" (offset optional → UTC). Hand-parsed: a guide has
    /// hundreds of thousands of these and DateFormatter is slow.
    static func time(_ s: String) -> TimeInterval? {
        let u = Array(s.utf8)
        guard u.count >= 14 else { return nil }
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<(i + n) { let c = Int(u[k]) - 48; guard c >= 0, c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2), let se = num(12, 2) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi; comps.second = se
        guard let base = utcCalendar.date(from: comps) else { return nil }
        var offset = 0
        // Find "+hhmm" / "-hhmm" after the digits.
        if let signIndex = u[14...].firstIndex(where: { $0 == 43 || $0 == 45 }), signIndex + 4 < u.count,
           let oh = num(signIndex + 1, 2), let om = num(signIndex + 3, 2) {
            offset = (oh * 3600 + om * 60) * (u[signIndex] == 45 ? -1 : 1)
        }
        return base.timeIntervalSince1970 - Double(offset)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

// MARK: - gzip

/// Streams a .gz file through the Compression framework (raw DEFLATE after the
/// gzip header) — the guide never has to fit in memory twice.
enum Gunzip {
    static func isGzip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 2)) ?? Data()
        return magic == Data([0x1F, 0x8B])
    }

    static func inflate(_ src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        // Header: ID1 ID2 CM FLG MTIME(4) XFL OS, then optional fields.
        guard let head = try input.read(upToCount: 10), head.count == 10, head[0] == 0x1F, head[1] == 0x8B, head[2] == 8 else {
            throw HTTPError.other("The guide's gzip header is invalid.")
        }
        let flags = head[3]
        if flags & 0x04 != 0, let x = try input.read(upToCount: 2), x.count == 2 {
            _ = try input.read(upToCount: Int(x[0]) | Int(x[1]) << 8)
        }
        func skipCString() throws { while let b = try input.read(upToCount: 1), let c = b.first, c != 0 {} }
        if flags & 0x08 != 0 { try skipCString() }
        if flags & 0x10 != 0 { try skipCString() }
        if flags & 0x02 != 0 { _ = try input.read(upToCount: 2) }

        let chunk = 1 << 20
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dstBuffer.deallocate() }
        var stream = compression_stream(dst_ptr: dstBuffer, dst_size: 0, src_ptr: UnsafePointer(dstBuffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw HTTPError.other("Couldn't start inflating the guide.")
        }
        defer { compression_stream_destroy(&stream) }

        var finished = false
        while !finished {
            let data = try input.read(upToCount: chunk) ?? Data()
            let last = data.count < chunk
            var emptyPasses = 0
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dstBuffer)
                stream.src_size = data.count
                repeat {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = chunk
                    let status = compression_stream_process(&stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunk - stream.dst_size
                    if produced > 0 { output.write(Data(bytes: dstBuffer, count: produced)) }
                    switch status {
                    case COMPRESSION_STATUS_OK: break
                    case COMPRESSION_STATUS_END: finished = true
                    default: throw HTTPError.other("The guide's gzip data is corrupt.")
                    }
                    // The decoder takes input faster than it hands output back, so
                    // "input used up" isn't "done": mid-file, stop once the input is
                    // consumed and the output came back short; at the end, drain
                    // until the stream reports its end.
                    if finished { break }
                    if !last, stream.src_size == 0, produced < chunk { break }
                    if last, produced == 0, stream.src_size == 0, status == COMPRESSION_STATUS_OK, emptyPasses > 2 { break }
                    emptyPasses = produced == 0 ? emptyPasses + 1 : 0
                } while true
            }
            if last { finished = true }
        }
    }
}

// MARK: - Reminders

struct GuideReminder: Codable, Hashable, Identifiable {
    var channelID: String
    var channelName: String
    var title: String
    var start: Date
    var end: Date
    var id: String { "\(channelID)|\(Int(start.timeIntervalSince1970))" }
}

/// "Remind me": a programme about to start. tvOS apps can't post alerts, so
/// reminders fire inside the app — a prompt with Watch Now, or (over the
/// player) a notice — checked every 20 s while Orivio is open.
@MainActor
final class GuideReminders: ObservableObject {
    static let shared = GuideReminders()

    @Published private(set) var items: [GuideReminder] = []
    /// The reminder to offer now (the prompt).
    @Published var due: GuideReminder?
    private let key = Persistence.key("livetv.reminders.v1")
    private var timer: Timer?

    private init() {
        items = (Persistence.load([GuideReminder].self, key: key) ?? []).filter { $0.end > Date() }
    }

    func has(_ channelID: String, _ p: EPGProgramme) -> Bool {
        items.contains { $0.channelID == channelID && $0.start == p.start }
    }

    /// Returns whether the reminder is now set.
    @discardableResult
    func toggle(_ c: LiveChannel, _ p: EPGProgramme) -> Bool {
        if has(c.id, p) {
            items.removeAll { $0.channelID == c.id && $0.start == p.start }
            save()
            return false
        }
        items.append(GuideReminder(channelID: c.id, channelName: c.name, title: p.title, start: p.start, end: p.end))
        items.sort { $0.start < $1.start }
        save()
        start()
        return true
    }

    func start() {
        guard timer == nil, !items.isEmpty else { return }
        let t = Timer(timeInterval: 20, repeats: true) { _ in Task { @MainActor in GuideReminders.shared.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    func check(now: Date = Date()) {
        items.removeAll { $0.end <= now }
        // Fire from 60 s before the start until 10 min in (the app may have been closed at the time).
        guard due == nil, let r = items.first(where: { $0.start.timeIntervalSince(now) < 60 && now.timeIntervalSince($0.start) < 600 }) else {
            if items.isEmpty { timer?.invalidate(); timer = nil }
            save()
            return
        }
        items.removeAll { $0.id == r.id }
        save()
        if PlayerPresenter.shared.isPresenting {
            ToastCenter.shared.show("\(r.title) is starting on \(r.channelName)", systemImage: "bell.fill")
        } else {
            due = r
        }
    }

    private func save() { Persistence.save(items, key: key, compressed: false) }
}

// MARK: - Search

extension EPGGuide {
    /// Programmes matching `query` from an hour ago through the next two days, soonest first.
    func search(_ query: String, in channels: [LiveChannel], limit: Int = 60) -> [(channel: LiveChannel, programme: EPGProgramme)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let now = Date()
        let from = now.addingTimeInterval(-3600), to = now.addingTimeInterval(2 * 86400)
        var out: [(LiveChannel, EPGProgramme)] = []
        for c in channels where key(for: c) != nil {
            for p in programmes(for: c, from: from, to: to) where p.end > now && p.title.localizedCaseInsensitiveContains(q) {
                out.append((c, p))
            }
        }
        return Array(out.sorted { $0.1.start < $1.1.start }.prefix(limit)).map { (channel: $0.0, programme: $0.1) }
    }
}
