import Foundation
import YouTubeKit

/// Turns a Live TV link that is a PAGE into a link that is MEDIA.
///
/// Community playlists routinely list a 24/7 relay as an ordinary YouTube
/// watch or live URL. Handing that to a media player fetches HTML and the
/// channel reads as broken, so it has to be extracted first — the same job
/// `TrailerResolver` does for trailers, with two differences that matter here:
///
/// * **Live streams are HLS.** A YouTube live broadcast exposes an `m3u8`
///   manifest rather than the progressive/adaptive pair a finished video has,
///   and that manifest is the only form that keeps playing as the broadcast
///   continues. A progressive URL, where one exists at all, is a frozen
///   snapshot of the stream so far.
/// * **The link expires.** googlevideo URLs are time-limited, so a resolved
///   channel is cached for well under their lifetime and re-resolved after.
enum LiveStreamResolver {
    struct Resolved {
        let url: String
        /// Extraction can require a matching `User-Agent` — see
        /// `TrailerResolver.asset(for:)` for why the client and the agent have
        /// to agree.
        let options: LiveStreamOptions
    }

    private static let lock = NSLock()
    private static var cache: [String: (resolved: Resolved, at: Date)] = [:]
    /// Conservative slice of googlevideo's link lifetime. A live manifest is
    /// re-requested continuously by the player, so this only governs how long
    /// a channel can be RE-OPENED without another extraction.
    private static let ttl: TimeInterval = 20 * 60

    static func resolveYouTube(_ raw: String) async -> Resolved? {
        guard let videoID = LiveStreamClassifier.youTubeID(from: raw) else { return nil }

        let cached = lock.withLock { cache[videoID] }
        if let cached, Date().timeIntervalSince(cached.at) < ttl { return cached.resolved }

        // `.local` parses YouTube's own page and `.remote` uses the extraction
        // service, which needs no page at all — so the remote extractor gets
        // its own attempt, exactly as TrailerResolver does. (Reaching it needs
        // the ORIVIO PATCH in the vendored YouTubeKit: its availability
        // pre-check parses the watch page before it walks the method list, and
        // used to abort everything when that page came back unreadable — a
        // consent wall or bot check, which is what an address YouTube
        // distrusts gets served.)
        // A LIVE broadcast exposes an HLS manifest and NO usable progressive
        // stream, so it is tried first — `streams` on a live video either
        // throws or returns a frozen snapshot of the broadcast so far.
        // `livestreams` is documented as always using local extraction, hence
        // the separate remote attempt for the non-live fallback below.
        let live = YouTube(videoID: videoID, methods: [.local])
        if let hls = (try? await live.livestreams)?.first(where: { $0.streamType == .hls })?.url {
            let resolved = Resolved(url: hls.absoluteString, options: userAgentOptions(for: hls))
            lock.withLock { cache[videoID] = (resolved, Date()) }
            NSLog("[OrivioLiveTV] %@ resolved to a live HLS manifest", videoID)
            return resolved
        }

        // Not a live broadcast: fall back to the best playable stream, which
        // is what a permanently-archived "channel" in a playlist actually is.
        var streams: [YouTubeKit.Stream] = []
        for methods in [[YouTube.ExtractionMethod.local], [YouTube.ExtractionMethod.remote]] {
            if let extracted = try? await YouTube(videoID: videoID, methods: methods).streams,
               !extracted.isEmpty {
                streams = extracted
                break
            }
        }
        let playable = streams.filter { $0.isNativelyPlayable }
        guard let best = playable.filterVideoAndAudio().highestResolutionStream()
                ?? playable.filterVideoOnly().highestResolutionStream() else {
            NSLog("[OrivioLiveTV] %@ could not be resolved to a playable stream", videoID)
            return nil
        }
        let resolved = Resolved(url: best.url.absoluteString, options: userAgentOptions(for: best.url))
        lock.withLock { cache[videoID] = (resolved, Date()) }
        NSLog("[OrivioLiveTV] %@ resolved to a %dp progressive stream",
              videoID, best.videoResolution ?? 0)
        return resolved
    }

    /// googlevideo serves a playback URL only to the InnerTube client that
    /// extracted it — the `c=` query parameter names that client, and a
    /// mismatched User-Agent gets "Cannot Open" (-11828). Mirrors the mapping
    /// in `TrailerResolver.asset(for:)`.
    private static func userAgentOptions(for url: URL) -> LiveStreamOptions {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value
        var options = LiveStreamOptions()
        switch client {
        case "TVHTML5", "TVHTML5_SIMPLY_EMBEDDED_PLAYER":
            options.setHeader("User-Agent",
                              "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")
        case "IOS":
            options.setHeader("User-Agent", "com.google.ios.youtube/19.29.1 (iPhone; U; CPU iOS 17_5 like Mac OS X)")
        case "ANDROID":
            options.setHeader("User-Agent", "com.google.android.youtube/19.29.37 (Linux; U; Android 14) gzip")
        default:
            options.setHeader("User-Agent",
                              "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                              + "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")
        }
        return options
    }
}
