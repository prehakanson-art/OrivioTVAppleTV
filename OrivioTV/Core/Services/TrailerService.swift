import Foundation
import AVFoundation
import YouTubeKit

/// Resolves YouTube trailer keys to playable streams (tvOS has no WebKit).
struct TrailerSource {
    var videoURL: URL
    /// Separate audio for adaptive streams (nil when the video is progressive).
    var audioURL: URL?

    /// A player item: muxes adaptive video + audio into one composition.
    ///
    /// YouTube's adaptive files are fragmented MP4s: asking AVFoundation for
    /// their `.duration` walks every fragment (~10 s for a 1080p trailer — the
    /// trailer "took ages to start"). The URL's own `dur` is the real length
    /// (the asset even reports twice it), so it's used whenever present, and
    /// the two tracks load at once rather than one after the other.
    func makeItem() async -> AVPlayerItem {
        // Fastest start: the DASH files described as HLS (plays from the first
        // fragment). The composition below is the fallback.
        if TrailerService.isGoogleVideo(videoURL), let hls = await DashAsHLS.item(video: videoURL, audio: audioURL) {
            return Self.budgeted(hls)
        }
        guard let audioURL else { return Self.budgeted(AVPlayerItem(asset: Self.asset(videoURL))) }
        let comp = AVMutableComposition()
        let v = Self.asset(videoURL)
        let a = Self.asset(audioURL)
        do {
            async let videoTracks = v.loadTracks(withMediaType: .video)
            async let audioTracks = a.loadTracks(withMediaType: .audio)
            guard let vt = try await videoTracks.first else { return Self.budgeted(AVPlayerItem(asset: v)) }
            let duration: CMTime
            if let d = Self.declaredDuration(videoURL) { duration = d } else { duration = try await v.load(.duration) }
            let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vt, at: .zero)
            if let at = try await audioTracks.first {
                let ad: CMTime
                if let d = Self.declaredDuration(audioURL) { ad = d } else { ad = try await at.load(.timeRange).duration }
                let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, ad)), of: at, at: .zero)
            }
            return Self.budgeted(AVPlayerItem(asset: comp))
        } catch {
            return Self.budgeted(AVPlayerItem(asset: Self.asset(videoURL)))
        }
    }

    /// The length a googlevideo URL declares (`dur`, seconds).
    static func declaredDuration(_ url: URL) -> CMTime? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dur" })?.value,
              let seconds = Double(raw), seconds > 0 else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: 1000)
    }

    /// A trailer is a preview beside a browsing UI: on 2–3 GB boxes its read-ahead
    /// is bounded so it doesn't compete with poster decodes for memory.
    static func budgeted(_ item: AVPlayerItem) -> AVPlayerItem {
        if PerformanceProfile.isConstrained { item.preferredForwardBufferDuration = 10 }
        return item
    }

    /// googlevideo URLs only play for the User-Agent of the InnerTube client that
    /// minted them (the `c=` parameter); AVPlayer's own agent gets "Cannot Open".
    static func asset(_ url: URL) -> AVURLAsset {
        guard TrailerService.isGoogleVideo(url) else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent(for: url)]])
    }

    static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value
        switch client {
        case "ANDROID_VR":
            return "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case "ANDROID": return "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        case "ANDROID_MUSIC": return "com.google.android.apps.youtube.music/5.16.51 (Linux; U; Android 11) gzip"
        case "ANDROID_EMBEDDED_PLAYER": return "com.google.android.youtube/18.11.34 (Linux; U; Android 11) gzip"
        case "IOS": return "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case "IOS_MUSIC": return "com.google.ios.youtubemusic/5.21 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)"
        case "TVHTML5":
            return "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
        default: return "Mozilla/5.0"   // browser clients (WEB, MWEB, embedded…)
        }
    }
}

enum TrailerService {
    private static let cache = ResponseCache<TrailerSource>(capacity: 48, ttl: 2 * 3600)
    /// Extracted stream lists by video id (shared by muted/sound lookups and
    /// background prefetches; googlevideo URLs stay valid for hours).
    private static let streamCache = ResponseCache<[YouTubeKit.Stream]>(capacity: 48, ttl: 2 * 3600)
    private static let inFlight = LockedBox<[String: Task<[YouTubeKit.Stream]?, Never>]>([:])

    /// Extracts a YouTube id from a key or URL.
    static func youtubeID(_ s: String) -> String? {
        if s.count == 11, !s.contains("/") { return s }
        if let u = URLComponents(string: s) {
            if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            if u.host?.contains("youtu.be") == true { return String(u.path.dropFirst()) }
            if u.path.contains("/embed/") { return u.path.components(separatedBy: "/embed/").last }
        }
        return nil
    }

    /// `muted` → best video-only stream is enough (background trailers).
    static func resolve(_ key: String, muted: Bool) async -> TrailerSource? {
        if let u = URL(string: key), u.scheme?.hasPrefix("http") == true, !key.contains("youtu") {
            return TrailerSource(videoURL: u)
        }
        guard let id = youtubeID(key) else { return nil }
        let cacheKey = "\(id)|\(muted)"
        if let hit = cache.get(cacheKey) { return hit }
        guard let streams = await streams(for: id) else { return nil }
        let maxHeight = PerformanceProfile.isLowPower ? 720 : 1080
        let playable = streams.filter { $0.isNativelyPlayable }
        let videoOnly = playable.filter { $0.includesVideoTrack && !$0.includesAudioTrack && ($0.videoResolution ?? 0) <= maxHeight }
            .sorted { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) }
        let progressive = playable.filter { $0.includesVideoAndAudioTrack }
            .sorted { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) }
        let audio = playable.filter { $0.includesAudioTrack && !$0.includesVideoTrack }
            .sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
        var source: TrailerSource?
        if muted, let v = videoOnly.first {
            source = TrailerSource(videoURL: v.url)
        } else if let v = videoOnly.first, let a = audio.first, (v.videoResolution ?? 0) > (progressive.first?.videoResolution ?? 0) {
            source = TrailerSource(videoURL: v.url, audioURL: a.url)
        } else if let p = progressive.first {
            source = TrailerSource(videoURL: p.url)
        } else if let v = videoOnly.first {
            source = TrailerSource(videoURL: v.url, audioURL: audio.first?.url)
        }
        if let source { cache.set(cacheKey, source) }
        return source
    }

    /// Resolves the trailers of titles the user is likely to open next (the
    /// Detail page's neighbours), so theirs can start at once.
    static func prefetch(_ keys: [String]) {
        let ids = keys.compactMap(youtubeID).prefix(2)
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for id in ids where await streams(for: id) != nil { return }
        }
    }

    /// One extraction per video at a time (a page and a prefetch may ask together);
    /// it runs detached, so leaving the page still leaves the result cached.
    static func streams(for id: String) async -> [YouTubeKit.Stream]? {
        if let hit = streamCache.get(id) { return hit }
        let task: Task<[YouTubeKit.Stream]?, Never> = inFlight.mutate { d in
            if let t = d[id] { return t }
            let t = Task.detached(priority: .userInitiated) { () -> [YouTubeKit.Stream]? in
                let s = await extractStreams(id)
                if let s { streamCache.set(id, s) }
                inFlight.mutate { $0[id] = nil }
                return s
            }
            d[id] = t
            return t
        }
        return await task.value
    }

    /// YouTube's own page and YouTubeKit's remote extraction service, raced.
    /// The page route breaks whenever YouTube reshapes its player (every trailer
    /// failed with `regexMatchError`), can hang, and from some addresses only
    /// gets 240p; the remote one is reliable but takes several seconds. A page
    /// result wins only if it has a real (≥ 480p) picture.
    private static func extractStreams(_ id: String) async -> [YouTubeKit.Stream]? {
        let tryLocal = Date() >= localRetryAfter.value
        // First acceptable answer wins at once (a task group would wait for the
        // loser, and the page route can hang for its whole timeout).
        return await withCheckedContinuation { (c: CheckedContinuation<[YouTubeKit.Stream]?, Never>) in
            let state = LockedBox((resumed: false, remaining: tryLocal ? 2 : 1, lowRes: [YouTubeKit.Stream]?.none))
            let report: @Sendable ([YouTubeKit.Stream]?, Bool) -> Void = { streams, remote in
                let out: [YouTubeKit.Stream]?? = state.mutate { st in
                    guard !st.resumed else { return nil }
                    st.remaining -= 1
                    if let streams {
                        let best = streams.filter { $0.isNativelyPlayable && $0.includesVideoTrack }.compactMap(\.videoResolution).max() ?? 0
                        if remote || best >= 480 {
                            st.resumed = true
                            #if DEBUG
                            DebugLog.write("[YT] \(id) \(remote ? "remote" : "local"): \(streams.count) streams, best \(best)p")
                            #endif
                            return .some(streams)
                        }
                        st.lowRes = streams
                    }
                    if st.remaining == 0 { st.resumed = true; return .some(st.lowRes) }
                    return nil
                }
                if let out { c.resume(returning: out) }
            }
            if tryLocal {
                Task.detached(priority: .userInitiated) {
                    do {
                        let s = try await withTimeout(6) { try await YouTube(videoID: id, methods: [.local]).streams }
                        report(s.isEmpty ? nil : s, false)
                    } catch {
                        #if DEBUG
                        DebugLog.write("[YT] \(id) local: \(error)")
                        #endif
                        localRetryAfter.value = Date().addingTimeInterval(30 * 60)
                        report(nil, false)
                    }
                }
            }
            Task.detached(priority: .userInitiated) {
                do {
                    let s = try await withTimeout(15) { try await YouTube(videoID: id, methods: [.remote]).streams }
                    report(s.isEmpty ? nil : s, true)
                } catch {
                    #if DEBUG
                    DebugLog.write("[YT] \(id) remote: \(error)")
                    #endif
                    report(nil, true)
                }
            }
        }
    }

    private static let localRetryAfter = LockedBox(Date.distantPast)

    static func isGoogleVideo(_ url: URL) -> Bool { url.host?.lowercased().hasSuffix("googlevideo.com") ?? false }

    static func isYouTube(_ url: URL) -> Bool {
        let h = url.host?.lowercased() ?? ""
        return h.hasSuffix("youtube.com") || h == "youtu.be"
    }

    /// A YouTube live stream's HLS manifest. Takes a video id, a watch / youtu.be
    /// URL, or a channel's `/live` page (resolved to the current broadcast's id).
    static func liveHLS(_ key: String) async -> URL? {
        var id = youtubeID(key)
        if id == nil || (key.contains("/live") && !key.contains("v=")) {
            id = await currentBroadcastID(key) ?? id
        }
        guard let id else { return nil }
        do {
            let live = try await withTimeout(15) { try await YouTube(videoID: id).livestreams }
            if let first = live.first { return first.url }
            #if DEBUG
            DebugLog.write("[YT] \(id): no HLS manifest")
            #endif
        } catch {
            #if DEBUG
            DebugLog.write("[YT] \(id): \(error)")
            #endif
        }
        // Not live (a premiere ended, or a VOD in a playlist): play it as a video.
        return await resolve(id, muted: false)?.videoURL
    }

    /// `youtube.com/@name/live`, `/channel/UC…/live`: the page's canonical watch id.
    private static func currentBroadcastID(_ page: String) async -> String? {
        guard let url = URL(string: page) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req), let html = String(data: data, encoding: .utf8) else { return nil }
        for pattern in [#"<link rel="canonical" href="https://www\.youtube\.com/watch\?v=([\w-]{11})""#, #""videoId":"([\w-]{11})""#] {
            if let r = html.range(of: pattern, options: .regularExpression) {
                let match = String(html[r])
                if let idr = match.range(of: #"[\w-]{11}(?="$)"#, options: .regularExpression) { return String(match[idr]) }
            }
        }
        return nil
    }

    /// Tries each key in order until one resolves.
    static func resolveFirst(_ keys: [String], muted: Bool) async -> TrailerSource? {
        for k in keys {
            if let s = await resolve(k, muted: muted) { return s }
        }
        return nil
    }
}

/// A value shared across tasks behind a lock.
final class LockedBox<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

/// YouTube's DASH on-demand files (video-only and audio-only fragmented MP4 —
/// everything above 360p) presented to AVPlayer as one HLS stream.
///
/// Each file opens with its init header (`ftyp` + `moov`) and a `sidx` index of
/// every fragment's size and duration — exactly what an HLS playlist with
/// `EXT-X-MAP` + `EXT-X-BYTERANGE` describes. The playlists come from the first
/// 64 KB of each file and are served from memory; AVPlayer fetches the media
/// from googlevideo itself, fragment by fragment, starting at once. (A plain
/// composition of the same files read far ahead first: 6–8 s to the first frame.)
enum DashAsHLS {
    fileprivate static let scheme = "orivio-dash"

    /// nil when a file doesn't parse as expected (the caller falls back).
    static func item(video: URL, audio: URL?) async -> AVPlayerItem? {
        async let videoHead = head(of: video)
        async let audioHead: Data? = audio == nil ? nil : head(of: audio!)
        guard let v = await videoHead.flatMap(parse) else { return nil }
        var playlists: [String: Data] = ["video.m3u8": Data(playlist(for: video, v).utf8)]
        var master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let audio {
            guard let a = await audioHead.flatMap(parse) else { return nil }
            playlists["audio.m3u8"] = Data(playlist(for: audio, a).utf8)
            master.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"")
            master.append("#EXT-X-STREAM-INF:BANDWIDTH=\(v.bandwidth + a.bandwidth),AUDIO=\"a\"")
        } else {
            master.append("#EXT-X-STREAM-INF:BANDWIDTH=\(v.bandwidth)")
        }
        master.append("video.m3u8")
        playlists["master.m3u8"] = Data((master.joined(separator: "\n") + "\n").utf8)
        let loader = PlaylistLoader(playlists: playlists)
        guard let url = URL(string: "\(scheme)://\(UUID().uuidString)/master.m3u8") else { return nil }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": TrailerSource.userAgent(for: video)],
        ])
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader doesn't keep its delegate alive; the asset does.
        objc_setAssociatedObject(asset, &PlaylistLoader.associationKey, loader, .OBJC_ASSOCIATION_RETAIN)
        return await MainActor.run { AVPlayerItem(asset: asset) }
    }

    private struct Layout {
        let initLength: Int
        let segments: [(offset: Int, size: Int, seconds: Double)]
        let bandwidth: Int
    }

    private static func head(of url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue(TrailerSource.userAgent(for: url), forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
        return data
    }

    /// Top-level boxes: the init header ends with `moov`; `sidx` lists the
    /// fragments after it.
    private static func parse(_ data: Data) -> Layout? {
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> Int {
            guard i >= 0, i + 4 <= bytes.count else { return -1 }
            return Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        func u64(_ i: Int) -> Int {
            let high = u32(i), low = u32(i + 4)
            return high < 0 || low < 0 ? -1 : high << 32 | low
        }
        var offset = 0
        var moovEnd = -1
        while offset + 8 <= bytes.count {
            var size = u32(offset)
            var header = 8
            if size == 1 { size = u64(offset + 8); header = 16 }
            guard size >= header else { return nil }
            let type = String(bytes: bytes[(offset + 4) ..< (offset + 8)], encoding: .ascii) ?? ""
            if type == "moov" { moovEnd = offset + size }
            if type == "sidx" {
                guard moovEnd > 0, offset + size <= bytes.count else { return nil }
                var p = offset + header
                let version = bytes[p]
                p += 8                                   // version/flags, reference_ID
                let timescale = u32(p); p += 4
                guard timescale > 0 else { return nil }
                let firstOffset: Int
                if version == 0 { firstOffset = u32(p + 4); p += 8 } else { firstOffset = u64(p + 8); p += 16 }
                guard firstOffset >= 0, p + 4 <= offset + size else { return nil }
                p += 2                                   // reserved
                let count = Int(bytes[p]) << 8 | Int(bytes[p + 1]); p += 2
                guard p + count * 12 <= offset + size else { return nil }
                var cursor = offset + size + firstOffset
                var segments: [(offset: Int, size: Int, seconds: Double)] = []
                var totalBytes = 0
                var totalSeconds = 0.0
                for _ in 0 ..< count {
                    let reference = u32(p)
                    let duration = u32(p + 4)
                    p += 12
                    // reference_type 1 (a nested index) isn't used by these files.
                    guard reference > 0, reference & 0x8000_0000 == 0, duration > 0 else { return nil }
                    let length = reference & 0x7FFF_FFFF
                    let seconds = Double(duration) / Double(timescale)
                    segments.append((cursor, length, seconds))
                    cursor += length
                    totalBytes += length
                    totalSeconds += seconds
                }
                guard !segments.isEmpty, totalSeconds > 0 else { return nil }
                return Layout(initLength: moovEnd, segments: segments,
                              bandwidth: max(Int(Double(totalBytes * 8) / totalSeconds * 1.5), 64_000))
            }
            offset += size
        }
        return nil
    }

    private static func playlist(for url: URL, _ layout: Layout) -> String {
        let target = Int((layout.segments.map(\.seconds).max() ?? 10).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(layout.initLength)@0\"",
        ]
        for segment in layout.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.seconds))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Serves the generated playlists; every media request is a normal https
    /// fetch AVPlayer makes itself.
    private final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
        nonisolated(unsafe) static var associationKey: UInt8 = 0
        let queue = DispatchQueue(label: "orivio.dash-hls")
        private let playlists: [String: Data]

        init(playlists: [String: Data]) { self.playlists = playlists }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let url = loadingRequest.request.url, url.scheme == DashAsHLS.scheme,
                  let body = playlists[url.lastPathComponent] else { return false }
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(body.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
            return true
        }
    }
}
