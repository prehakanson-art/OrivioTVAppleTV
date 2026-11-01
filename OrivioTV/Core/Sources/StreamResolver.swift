import Foundation

/// Turns a `StreamEntry` into something the player can open.
struct ResolvedStream {
    var url: URL
    var headers: [String: String]
}

@MainActor
enum StreamResolver {
    /// - Parameter onStatus: progress text for overlays ("Resolving via Real-Debrid").
    static func resolve(_ entry: StreamEntry, video: MetaVideo?, timeout: TimeInterval,
                        onStatus: ((String) -> Void)? = nil) async throws -> ResolvedStream {
        let s = entry.stream
        let headers = s.proxyRequestHeaders
        if let u = s.url, !u.isEmpty {
            let (clean, piped) = LiveStreamOptions.split(u)
            guard let url = URL(string: clean) else { throw HTTPError.badURL(u) }
            return ResolvedStream(url: url, headers: headers.merging(piped) { a, _ in a })
        }
        if let yt = s.ytId {
            onStatus?("Getting YouTube stream")
            guard let src = await TrailerService.resolve(yt, muted: false) else { throw HTTPError.other("YouTube stream unavailable") }
            return ResolvedStream(url: src.videoURL, headers: [:])
        }
        if s.isTorrent {
            let debrid = AppStores.shared.debrid.value
            if debrid.hasAny {
                let url = try await withTimeout(timeout) {
                    try await DebridService.resolve(s, season: video?.season, episode: video?.episode) { p in
                        Task { @MainActor in onStatus?("Resolving via \(p.label)") }
                    }
                }
                return ResolvedStream(url: url, headers: [:])
            }
            let torrent = AppStores.shared.torrent.value
            if torrent.enabled, let url = TorrServerService.streamURL(server: torrent.serverURL, stream: s) {
                onStatus?("Starting TorrServer")
                return ResolvedStream(url: url, headers: [:])
            }
            throw DebridError.noKey
        }
        throw HTTPError.other("This source can only be opened in another app.")
    }
}

/// `url|User-Agent=…&Referer=…` piped options (IPTV style) → request headers.
enum LiveStreamOptions {
    static func split(_ raw: String) -> (String, [String: String]) {
        guard let bar = raw.firstIndex(of: "|") else { return (raw, [:]) }
        let url = String(raw[..<bar])
        let opts = raw[raw.index(after: bar)...]
        var headers: [String: String] = [:]
        for pair in opts.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].removingPercentEncoding ?? kv[1]
            switch k.lowercased() {
            case "user-agent", "useragent": headers["User-Agent"] = v
            case "referer", "referrer": headers["Referer"] = v
            case "origin": headers["Origin"] = v
            case "cookie": headers["Cookie"] = v
            default: headers[k] = v
            }
        }
        return (url, headers)
    }
}

/// JavaScript scraper plugins (filled in by the plugin runtime).
@MainActor
final class PluginHost {
    static let shared = PluginHost()
    struct ScraperRef { let id: String; let name: String }
    var enabledScrapers: [ScraperRef] { [] }
    nonisolated func streams(scraperID: String, meta: MetaItem, video: MetaVideo?) async throws -> [Stream] { [] }
}
