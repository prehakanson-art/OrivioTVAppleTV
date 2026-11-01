import Foundation

struct StreamProxyHeaders: Codable, Hashable {
    var request: [String: String]?
    var response: [String: String]?
}

struct StreamBehaviorHints: Codable, Hashable {
    var bingeGroup: String?
    var notWebReady: Bool?
    var videoSize: Int64?
    var filename: String?
    var proxyHeaders: StreamProxyHeaders?
    var videoHash: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        bingeGroup = c.string(AnyKey("bingeGroup"))
        notWebReady = c.bool(AnyKey("notWebReady"))
        if let n = c.double(AnyKey("videoSize")) { videoSize = Int64(n) }
        filename = c.string(AnyKey("filename"))
        proxyHeaders = try? c.decodeIfPresent(StreamProxyHeaders.self, forKey: AnyKey("proxyHeaders"))
        videoHash = c.string(AnyKey("videoHash"))
    }
}

struct Stream: Codable, Hashable {
    var name: String?
    var title: String?
    var description: String?
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var sources: [String]
    var behaviorHints: StreamBehaviorHints?
    var subtitles: [AddonSubtitle]

    init(name: String? = nil, title: String? = nil, description: String? = nil, url: String? = nil,
         infoHash: String? = nil, fileIdx: Int? = nil, externalUrl: String? = nil, sources: [String] = [],
         behaviorHints: StreamBehaviorHints? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.url = url
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.externalUrl = externalUrl
        self.sources = sources
        self.behaviorHints = behaviorHints
        self.subtitles = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string(AnyKey("name"))
        title = c.string(AnyKey("title"))
        description = c.string(AnyKey("description"))
        url = c.string(AnyKey("url"))
        ytId = c.string(AnyKey("ytId"))
        infoHash = c.string(AnyKey("infoHash"))?.lowercased()
        fileIdx = c.int(AnyKey("fileIdx"))
        externalUrl = c.string(AnyKey("externalUrl"))
        sources = c.stringList(AnyKey("sources"))
        behaviorHints = try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: AnyKey("behaviorHints"))
        subtitles = c.lossyArray(AddonSubtitle.self, AnyKey("subtitles"))
    }

    // MARK: Derived

    /// All human-readable text the add-on attached (name + title + description + filename).
    var allText: String {
        [name, title, description, behaviorHints?.filename].compactMap { $0 }.joined(separator: "\n")
    }

    /// Some add-ons hard-wrap long release names, breaking a word with a hyphen
    /// ("[10-⏎80p]", "PL.72-⏎0p"): rejoin those, so "1080p" reads as 1080p
    /// (they were shown, and graded, as "SD").
    static func unwrapped(_ s: String) -> String {
        guard s.contains("-\n") else { return s }
        return s.replacingOccurrences(of: #"(?<=[A-Za-z0-9])-\n(?=[A-Za-z0-9])"#, with: "", options: .regularExpression)
    }

    var isTorrent: Bool { infoHash != nil && (url ?? "").isEmpty }
    var isExternal: Bool { (url ?? "").isEmpty && infoHash == nil && externalUrl != nil }
    var isPlayable: Bool { !(url ?? "").isEmpty || infoHash != nil || ytId != nil }

    var proxyRequestHeaders: [String: String] { behaviorHints?.proxyHeaders?.request ?? [:] }

    var magnetURI: String? {
        guard let infoHash else { return nil }
        var s = "magnet:?xt=urn:btih:\(infoHash)"
        for tr in sources where tr.hasPrefix("tracker:") {
            s += "&tr=" + HTTP.encodeComponent(String(tr.dropFirst("tracker:".count)))
        }
        return s
    }
}

/// Text classification of a stream — computed once per stream.
struct StreamTraits: Hashable {
    var resolution: String?      // 2160p / 1080p / 720p / 480p (the grading tier)
    /// The resolution exactly as the release names it (1080i, 576p, 480i, 360p…).
    var resolutionTag: String?
    var isCached: Bool
    var isMarkedUncached: Bool
    var debridShort: String?     // RD / PM / TB / AD
    var isDolbyVision: Bool
    var isHDR10Plus: Bool
    var isHDR: Bool
    var hasAtmos: Bool
    var isAV1: Bool
    var isHEVC: Bool
    var isAVC: Bool
    var sizeBytes: Int64?
    var seeders: Int?
    var hasDDP: Bool
    var hasTrueHD: Bool
    var hasDTS: Bool
    var releaseScore: Int
    var isCam: Bool

    init(_ s: Stream) {
        let text = Stream.unwrapped(s.allText)
        let lower = text.lowercased()
        resolution = Self.resolution(in: lower)
        resolutionTag = Self.resolutionTag(in: lower)
        let nameLower = (s.name ?? "").lowercased()
        isCached = lower.contains("⚡") || nameLower.contains("+]") || nameLower.contains("[rd+") || nameLower.contains("instant")
            || nameLower.range(of: #"\b(rd|pm|tb|ad|dl|ed|oc)\+"#, options: .regularExpression) != nil
            || lower.contains("[cached]")
        isMarkedUncached = lower.contains("⏳") || nameLower.contains("download]") || lower.contains("uncached")
            || nameLower.range(of: #"\[(rd|pm|tb|ad) download\]"#, options: .regularExpression) != nil
        debridShort = Self.debrid(in: nameLower)
        isDolbyVision = lower.range(of: #"\b(dv|dovi|dolby[ .]?vision)\b"#, options: .regularExpression) != nil
        isHDR10Plus = lower.contains("hdr10+") || lower.contains("hdr10plus")
        isHDR = isHDR10Plus || lower.range(of: #"\bhdr(10)?\b"#, options: .regularExpression) != nil || isDolbyVision
        hasAtmos = lower.range(of: #"atmos(?!phere)"#, options: .regularExpression) != nil
        isAV1 = lower.range(of: #"\bav1\b"#, options: .regularExpression) != nil
        isHEVC = lower.range(of: #"\b(hevc|x265|h\.?265)\b"#, options: .regularExpression) != nil
        isAVC = lower.range(of: #"\b(avc|x264|h\.?264)\b"#, options: .regularExpression) != nil
        hasDDP = lower.range(of: #"(ddp|dd\+|e-?ac-?3|eac3)"#, options: .regularExpression) != nil
        hasTrueHD = lower.contains("truehd")
        hasDTS = lower.range(of: #"\bdts"#, options: .regularExpression) != nil
        sizeBytes = s.behaviorHints?.videoSize ?? Self.size(in: text)
        seeders = Self.seeders(in: text)
        isCam = lower.range(of: #"\b(cam|camrip|hdcam|ts|telesync|hdts|telecine|tc)\b"#, options: .regularExpression) != nil
        if lower.contains("remux") { releaseScore = 140 }
        else if lower.range(of: #"(blu-?ray|bdrip|brrip)"#, options: .regularExpression) != nil { releaseScore = 120 }
        else if lower.range(of: #"web-?dl"#, options: .regularExpression) != nil { releaseScore = 110 }
        else if lower.range(of: #"web-?rip"#, options: .regularExpression) != nil { releaseScore = 90 }
        else if lower.contains("hdtv") { releaseScore = 60 }
        else if lower.contains("dvdrip") { releaseScore = 40 }
        else { releaseScore = 0 }
    }

    static func resolution(in lower: String) -> String? {
        if lower.range(of: #"(2160p|\b4k\b|\buhd\b)"#, options: .regularExpression) != nil { return "2160p" }
        if lower.contains("1080p") || lower.contains("1080i") || lower.range(of: #"\bfhd\b"#, options: .regularExpression) != nil { return "1080p" }
        if lower.contains("720p") { return "720p" }
        if lower.range(of: #"(480p|576p|\bsd\b)"#, options: .regularExpression) != nil { return "480p" }
        return nil
    }

    /// The release's own resolution tag, for display.
    static func resolutionTag(in lower: String) -> String? {
        if lower.range(of: #"(2160p|\b4k\b|\buhd\b)"#, options: .regularExpression) != nil { return "4K" }
        let tags = ["1440p", "1080p", "1080i", "720p", "576p", "576i", "540p", "480p", "480i", "360p", "240p"]
        for t in tags where lower.range(of: "(?<![0-9])\(t)\\b", options: .regularExpression) != nil { return t }
        if lower.range(of: #"\bfhd\b"#, options: .regularExpression) != nil { return "1080p" }
        if lower.range(of: #"\b(dvd ?rip|dvd5|dvd9|dvd)\b"#, options: .regularExpression) != nil { return "480p" }
        if lower.range(of: #"\bsd\b"#, options: .regularExpression) != nil { return "SD" }
        return nil
    }

    static func debrid(in nameLower: String) -> String? {
        let map: [(String, String)] = [("rd", "RD"), ("real-debrid", "RD"), ("realdebrid", "RD"), ("pm", "PM"),
                                       ("premiumize", "PM"), ("tb", "TB"), ("torbox", "TB"), ("ad", "AD"), ("alldebrid", "AD")]
        for (needle, short) in map {
            if nameLower.range(of: "(^|[\\[\\s(])\(needle)(\\+|\\]|\\s|$| download)", options: .regularExpression) != nil { return short }
        }
        return nil
    }

    static func size(in text: String) -> Int64? {
        guard let r = text.range(of: #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|GiB|MiB|TiB)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(text[r])
        let scanner = Scanner(string: match.replacingOccurrences(of: ",", with: "."))
        guard let n = scanner.scanDouble() else { return nil }
        let unit = match.uppercased()
        let mult: Double = unit.contains("T") ? 1_099_511_627_776 : unit.contains("G") ? 1_073_741_824 : 1_048_576
        return Int64(n * mult)
    }

    static func seeders(in text: String) -> Int? {
        guard let r = text.range(of: #"👤\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].filter(\.isNumber))
    }
}

/// A stream with its add-on and everything rows need, precomputed (computing
/// these in row bodies was the Sources page's main scroll cost).
struct StreamEntry: Identifiable, Hashable {
    let id: String
    let stream: Stream
    let addonName: String
    let addonID: String
    let traits: StreamTraits
    let displayName: String
    let displayDetail: String
    /// The complete release name (Settings → Full stream names).
    let fullName: String
    let sourceScore: Int

    var resolutionLabel: String? { traits.resolution }
    var sizeBytes: Int64? { traits.sizeBytes }
    var isInstant: Bool { traits.isCached }
    var fileSizeLabel: String? { sizeBytes.map(Self.formatBytes) }

    init(stream: Stream, addonName: String, addonID: String, index: Int) {
        self.stream = stream
        self.addonName = addonName
        self.addonID = addonID
        let traits = StreamTraits(stream)
        self.traits = traits
        let title = Stream.unwrapped(stream.title ?? stream.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = title.split(separator: "\n").first.map(String.init) ?? ""
        let name = (stream.name ?? "").replacingOccurrences(of: "\n", with: " ")
        displayName = firstLine.isEmpty ? (stream.behaviorHints?.filename ?? name) : firstLine
        let rest = title.split(separator: "\n").dropFirst().joined(separator: " · ")
        displayDetail = rest.isEmpty ? name : rest
        // The whole release name: the file name when the add-on gives one,
        // else every line of the title that isn't add-on decoration.
        let lines = title.split(separator: "\n").map(String.init)
        let release = lines.filter { l in !l.contains("💾") && !l.contains("👤") && !l.contains("⚙️") && !l.contains("🎬") }
        fullName = stream.behaviorHints?.filename ?? (release.isEmpty ? displayName : release.joined(separator: " "))
        sourceScore = StreamScoring.score(traits)
        id = "\(addonID)#\(index)#\(stream.url ?? stream.infoHash ?? stream.externalUrl ?? displayName)"
    }

    static func formatBytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    /// Add-on name with any resolver prefix stripped ("RD · Torrentio" → "Torrentio").
    /// Every "same add-on" comparison uses this.
    var sourceAddonName: String { Self.stripResolverPrefix(addonName) }

    static func stripResolverPrefix(_ name: String) -> String {
        for sep in [" · ", " | ", " - "] {
            if let r = name.range(of: sep) {
                let head = name[..<r.lowerBound].trimmingCharacters(in: .whitespaces).uppercased()
                if ["RD", "PM", "TB", "AD", "REAL-DEBRID", "PREMIUMIZE", "TORBOX", "ALLDEBRID", "TORRSERVER"].contains(head) {
                    return String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return name
    }

    /// Survives sessions — never the URL (debrid links are re-signed each resolve).
    var rejectionKey: String {
        if let hash = stream.infoHash { return "hash:\(hash)#\(stream.fileIdx ?? -1)" }
        if let file = stream.behaviorHints?.filename, !file.isEmpty { return "file:\(sourceAddonName)|\(file)" }
        return "name:\(sourceAddonName)|\(displayName)|\(displayDetail)"
    }

    var signature: StreamSignature {
        StreamSignature(resolution: traits.resolution, dolbyVision: traits.isDolbyVision, hdr: traits.isHDR,
                        atmos: traits.hasAtmos, addonName: sourceAddonName)
    }

    var badges: [String] {
        var b: [String] = []
        if traits.isDolbyVision { b.append("DV") } else if traits.isHDR10Plus { b.append("HDR10+") } else if traits.isHDR { b.append("HDR") }
        if traits.hasAtmos { b.append("Atmos") }
        if traits.isAV1 { b.append("AV1") }
        return b
    }

    static func == (a: StreamEntry, b: StreamEntry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Saved with progress so a resume can pick a fresh link with the same "look".
struct StreamSignature: Codable, Hashable {
    var resolution: String?
    var dolbyVision: Bool
    var hdr: Bool
    var atmos: Bool
    var addonName: String

    func matches(_ e: StreamEntry) -> Bool {
        e.traits.resolution == resolution && e.traits.isDolbyVision == dolbyVision && e.traits.isHDR == hdr
            && e.traits.hasAtmos == atmos && e.sourceAddonName == addonName
    }
}

enum StreamScoring {
    static func score(_ t: StreamTraits) -> Int {
        var s = 0
        if t.isCached { s += 1000 }
        s += t.releaseScore
        if t.isCam { s -= 400 }
        if PerformanceProfile.isLowPower {
            if t.isAV1 { s -= 300 } else if t.isHEVC { s -= 120 } else if t.isAVC { s += 40 }
        } else {
            if t.isAV1 { s -= 150 } else if t.isHEVC { s += 40 } else if t.isAVC { s += 15 }
        }
        if t.isDolbyVision { s += 35 }
        if t.isHDR10Plus { s += 30 } else if t.isHDR { s += 25 }
        if t.hasAtmos { s += 20 }
        if t.hasDDP { s += 15 } else if t.hasTrueHD { s += 10 } else if t.hasDTS { s += 8 }
        if !t.isCached, let seeds = t.seeders {
            if seeds == 0 { s -= 300 } else if seeds >= 20 { s += 20 } else if seeds >= 5 { s += 10 }
        }
        if let size = t.sizeBytes, let res = t.resolution {
            let gb = Double(size) / 1_073_741_824
            let range: ClosedRange<Double>
            switch res {
            case "2160p": range = 8...60
            case "1080p": range = 2...15
            case "720p": range = 0.7...6
            default: range = 0.2...3
            }
            if range.contains(gb) { s += 30 } else if gb > range.upperBound { s += 10 } else if gb < range.lowerBound / 2 { s -= 25 }
        }
        return s
    }

    static let resolutionOrder: [String] = ["2160p", "1080p", "720p", "480p"]

    static func resolutionRank(_ r: String?) -> Int {
        guard let r, let i = resolutionOrder.firstIndex(of: r) else { return resolutionOrder.count }
        return i
    }

    static func resolutionValue(_ r: String?) -> Int {
        switch r {
        case "2160p": return 2160
        case "1080p": return 1080
        case "720p": return 720
        case "480p": return 480
        default: return 0
        }
    }
}

struct StreamsResponse: Decodable {
    var streams: [Stream]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        streams = c.lossyArray(Stream.self, AnyKey("streams"))
    }
}
