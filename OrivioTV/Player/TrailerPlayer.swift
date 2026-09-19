import SwiftUI
import AVKit
import Network
import YouTubeKit

/// A counter that moves every time the box's network path changes shape — a
/// VPN tunnel coming up or going down is exactly that kind of change.
///
/// googlevideo mints a playback URL for the connection that asked for it, and
/// the moment the route out of the house changes (tunnel up, tunnel down, or
/// the VPN provider rotating which exit you leave from) the URLs we remembered
/// start answering 403. Nothing in the trailer pipeline noticed: the resolved
/// URLs were cached for half an hour, so enabling a VPN could leave every
/// trailer dead until that window ran out. Stamping each cached entry with the
/// generation it was extracted under makes a path change drop them, without
/// any cache having to know what a VPN is.
enum TrailerNetworkGeneration {
    private static let lock = NSLock()
    private static var value: UInt64 = 0
    /// The shape of the last path we saw. `nil` until the first callback,
    /// which only establishes the baseline — the app didn't change networks by
    /// launching.
    private static var lastShape: String?

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let shape = TrailerNetworkGeneration.shape(of: path)
            TrailerNetworkGeneration.lock.withLock {
                guard TrailerNetworkGeneration.lastShape != shape else { return }
                if TrailerNetworkGeneration.lastShape != nil {
                    TrailerNetworkGeneration.value &+= 1
                }
                TrailerNetworkGeneration.lastShape = shape
            }
        }
        monitor.start(queue: DispatchQueue(label: "orivio.trailer.path"))
        return monitor
    }()

    /// Reading this also starts the monitor the first time, so nothing has to
    /// remember to boot it.
    static var current: UInt64 {
        _ = monitor
        return lock.withLock { value }
    }

    /// What we consider "the same network". `usesInterfaceType(.other)` is how
    /// a tunnel shows up, and the interface list catches a VPN that reconnects
    /// onto a fresh `utun` (and so, almost always, a fresh exit address).
    private static func shape(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name)/\($0.type)" }
            .sorted()
            .joined(separator: ",")
        return "\(path.status)|tunnel:\(path.usesInterfaceType(.other))|\(interfaces)"
    }
}

/// Resolves a YouTube video key to something AVPlayer can play. tvOS has no
/// WebKit, so the iframe embed is out — YouTubeKit extracts native streams.
///
/// YouTube only *muxes* audio+video up to ~720p; 1080p and up exist solely as
/// separate adaptive tracks (DASH), so a 1080p trailer means merging a
/// video-only and an audio-only stream into one composition.
///
/// This used to always take the single muxed URL for a fast start, which
/// capped every trailer at 720p (often 360/480p, since the muxed ladder is
/// thin). Resolution wins now: the merge is used whenever it is genuinely
/// sharper than the best muxed stream, and the muxed fast path is kept for the
/// case where it is already as good. The old objection — that merging is slow
/// to start — was mostly the merge loading its two remote assets one after the
/// other; `mergedItem` now loads them concurrently.
enum TrailerResolver {
    /// How many of TMDB's ranked trailers to try before giving up on a title.
    ///
    /// One was not enough. A trailer is a YouTube video like any other and
    /// plenty of them are geo-restricted, so the top-ranked one can be
    /// unplayable from wherever the connection comes OUT — the ordinary case
    /// when the box is on a VPN whose exit sits in another country. TMDB
    /// usually lists several (the studio's, a distributor's, a regional cut)
    /// and the ones after the first are frequently not restricted at all.
    /// Bounded because every miss costs a full extraction.
    static let maxCandidates = 3

    /// Ask YouTube for a video's streams, local extractor first and the remote
    /// extraction service after it.
    ///
    /// `.local` parses YouTube's own page, so it breaks whenever they reshape
    /// it, and it is the first thing to be handed a consent wall or a
    /// "confirm you're not a bot" interstitial when the address asking has a
    /// poor reputation — which a VPN exit, shared by however many other people
    /// sit behind it, permanently does. `.remote` never touches that page, so
    /// it is the way through.
    ///
    /// Two separate calls rather than `methods: [.local, .remote]`, for one
    /// reason the combined form does not cover: a local extraction that
    /// returns an EMPTY list without throwing satisfies the combined call,
    /// which then hands back nothing at all. Here that counts as a miss and
    /// the remote extractor still gets its turn.
    ///
    /// Note that neither form reaches the remote extractor unless YouTubeKit
    /// itself is patched — its availability pre-check parses the watch page
    /// before it walks the method list, and used to abort everything when that
    /// page was unreadable. See the ORIVIO PATCH in
    /// `Vendor/YouTubeKit/Sources/YouTubeKit/YouTube.swift`.
    private static func extractStreams(youtubeKey: String) async -> [YouTubeKit.Stream]? {
        do {
            let streams = try await YouTube(videoID: youtubeKey, methods: [.local]).streams
            if !streams.isEmpty { return streams }
            NSLog("[OrivioTrailer] local extraction returned nothing for %@ — trying remote", youtubeKey)
        } catch {
            NSLog("[OrivioTrailer] local extraction failed for %@: %@ — trying remote",
                  youtubeKey, String(describing: error))
        }
        // The hero moved on (or the page closed) and took the URLSession
        // requests with it — that is not YouTube refusing us, and the remote
        // extractor would only be cancelled the same way.
        guard !Task.isCancelled else { return nil }
        do {
            let streams = try await YouTube(videoID: youtubeKey, methods: [.remote]).streams
            return streams.isEmpty ? nil : streams
        } catch {
            NSLog("[OrivioTrailer] extraction failed for %@: %@", youtubeKey, String(describing: error))
            return nil
        }
    }

    /// The first of `candidates` that resolves to something playable, with the
    /// key it came from so a later playback failure can invalidate the right
    /// entry. Ranked best-first by TMDB; see `maxCandidates`.
    static func playerItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if let item = await playerItem(youtubeKey: key) {
                return (item, key)
            }
            NSLog("[OrivioTrailer] %@ did not resolve — trying the next trailer", key)
        }
        return nil
    }

    /// The highest-resolution natively-playable item: a merged 1080p (or
    /// better) composition when the adaptive ladder beats the muxed one,
    /// otherwise the single muxed progressive URL.
    static func playerItem(youtubeKey: String) async -> AVPlayerItem? {
        guard let streams = await extractStreams(youtubeKey: youtubeKey) else { return nil }
        // isNativelyPlayable keeps only codecs AVPlayer decodes (H.264/AAC),
        // dropping VP9/AV1 webm — so the "highest" video-only is 1080p H.264.
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        // Merge only when it actually buys resolution. When YouTube happens to
        // mux the same height (or better), the single URL is both sharper-
        // equal and faster to start, so there is nothing to gain.
        // Apple TV HD: never merge. The composition is a second connection +
        // two moov round trips + an AVMutableComposition on a 2-core, 2 GB,
        // 1080p box, to lift a TRAILER from 720p — the muxed single URL is
        // the right trade there.
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (muxed best was %dp)",
                  youtubeKey, adaptiveHeight, muxedHeight)
            return merged
        }
        if let muxed {
            NSLog("[OrivioTrailer] %@: muxed %dp", youtubeKey, muxedHeight)
            return budgeted(AVPlayerItem(asset: asset(for: muxed.url)))
        }
        // No muxed stream at all — merge whatever the adaptive ladder offers,
        // even if the comparison above didn't favour it.
        if let adaptive,
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: adaptive.url, audio: audio.url) {
            NSLog("[OrivioTrailer] %@: merged %dp (no muxed stream)", youtubeKey, adaptiveHeight)
            return merged
        }
        return nil
    }

    /// Bound AVPlayer's read-ahead on the constrained boxes. With no
    /// preference set it buffers at its own appetite — fine on 4 GB, but a
    /// trailer is a MUTED PREVIEW playing beside a browsing UI on the 2–3 GB
    /// boxes, and its buffer competes with poster decodes for the same RAM.
    @discardableResult
    private static func budgeted(_ item: AVPlayerItem) -> AVPlayerItem {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            item.preferredForwardBufferDuration = 10
        }
        return item
    }

    /// googlevideo playback URLs are tied to the InnerTube CLIENT that
    /// extracted them (the `c=` query param) — YouTube serves them only to a
    /// matching User-Agent, and AVPlayer's default UA gets "Cannot Open"
    /// (-11828). Rebuild each request with the extracting client's UA.
    private static func asset(for url: URL) -> AVURLAsset {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value
        let userAgent: String
        switch client {
        case "ANDROID_VR":
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        case "ANDROID":
            userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        case "ANDROID_MUSIC":
            userAgent = "com.google.android.apps.youtube.music/5.16.51 (Linux; U; Android 11) gzip"
        case "ANDROID_EMBEDDED_PLAYER":
            userAgent = "com.google.android.youtube/18.11.34 (Linux; U; Android 11) gzip"
        // The clients below were missing, and every one of them is an APP
        // client — the kind googlevideo actually checks the agent for. They
        // are not exotic: the local extractor falls through to them when the
        // first choice is refused, and the REMOTE extractor (the one that
        // takes over whenever YouTube won't talk to this address directly,
        // which is the normal state of affairs from a VPN exit) hands back
        // whichever client got through. Extraction then succeeded and
        // playback died with "Cannot Open" — a trailer that resolves and
        // never starts. Agents lifted from YouTubeKit's own client table so
        // they match the request that minted the URL.
        case "IOS":
            userAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        case "IOS_MUSIC":
            userAgent = "com.google.ios.youtubemusic/5.21 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)"
        case "TVHTML5":
            userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER":
            userAgent = "Mozilla/5.0"
        default:
            // WEB, VISIONOS, MWEB, WEB_EMBEDDED_PLAYER and friends are
            // browser clients — a browser agent is the matching one.
            userAgent = "Mozilla/5.0"
        }
        return AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]
        ])
    }

    /// Merge a remote video-only and audio-only track into one playable asset.
    ///
    /// `@MainActor` because `AVPlayerItem.init(asset:)` is main-actor isolated
    /// in the current SDK and this was calling it from a nonisolated async
    /// context — a warning today and a hard error under Swift 6. Nothing is
    /// blocked by the annotation: every expensive step in here is an `await`
    /// on AVFoundation's own loaders, which suspend rather than spin, and the
    /// one caller (`playerItem`) is already reached from a `.task` on main.
    @MainActor
    private static func mergedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        let videoAsset = asset(for: video)
        let audioAsset = asset(for: audio)
        let composition = AVMutableComposition()
        do {
            // CONCURRENTLY. Each of these is a network round trip for the
            // asset's moov atom, and running them one after another is most of
            // what made a merged trailer slower to open than a muxed one —
            // which is why the muxed stream (and its 720p ceiling) used to be
            // preferred outright.
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let videoDuration = videoAsset.load(.duration)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)

            guard let vTrack = try await videoTracks.first else { return nil }
            let range = try await CMTimeRange(start: .zero, duration: videoDuration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try vComp?.insertTimeRange(range, of: vTrack, at: .zero)
            if let aTrack = try await audioTracks.first {
                let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                // The audio track can be a hair shorter than the video; clamp
                // so `insertTimeRange` can't throw on the tail and lose the
                // whole composition (and with it the 1080p path).
                let audioDuration = try await aTrack.load(.timeRange).duration
                let audioRange = CMTimeRange(start: .zero,
                                             duration: min(range.duration, audioDuration))
                try aComp?.insertTimeRange(audioRange, of: aTrack, at: .zero)
            }
            return budgeted(AVPlayerItem(asset: composition))
        } catch {
            NSLog("[OrivioTrailer] merge failed: %@", String(describing: error))
            return nil
        }
    }

    /// The backdrop trailer behind Home's hero and the Detail page.
    ///
    /// Resolution is chosen the same way `playerItem` chooses it — the merged
    /// adaptive pair when it beats the muxed ladder, which in practice means
    /// 1080p instead of 720p or worse. This used to take the muxed URL
    /// unconditionally "because the preview sits behind heavy scrims", but the
    /// Detail page plays this same item large and un-muted, so the ceiling was
    /// visible there.
    ///
    /// The client-matched User-Agent is baked in — see `asset(for:)`.
    /// Extraction is the slow step (seconds, the remote fallback especially),
    /// and the playback URLs it yields stay valid for hours — so remember
    /// them, and a title the browse comes BACK to starts its preview almost
    /// immediately instead of re-paying the extraction every visit.
    /// Guarded by `backdropCacheLock`: `backdropItem` is nonisolated async,
    /// so Home's hero layer and a Detail page opening at the same moment
    /// mutate these two dictionaries concurrently off the main actor —
    /// unsynchronised Dictionary mutation, i.e. a corrupted hash table.
    private static let backdropCacheLock = NSLock()

    /// What extraction settled on for one key. Both URLs are remembered, not
    /// just one, because the 1080p choice is a PAIR of adaptive streams —
    /// and `muxedFallback` keeps a single self-contained URL around so a
    /// failed merge degrades to a lower-resolution trailer WITH audio rather
    /// than to a silent one.
    private struct BackdropChoice {
        let video: URL
        let audio: URL?
        let muxedFallback: URL?
        let height: Int
        let at: Date
        /// The network path these URLs were minted for — see
        /// `TrailerNetworkGeneration`.
        let generation: UInt64
    }
    private static var backdropURLCache: [String: BackdropChoice] = [:]
    /// Conservative slice of googlevideo's ~6h link lifetime.
    private static let backdropURLTTL: TimeInterval = 30 * 60

    /// Keys whose extraction just failed, and when.
    ///
    /// Successes were remembered and failures were not, which is exactly
    /// backwards for load: every time the viewer's focus passed back over a
    /// title we could not extract, we asked YouTube again. Browsing a row of
    /// them is then a burst of failing requests from one address — and a burst
    /// is what earns a bot-check page, whose unparseable HTML is itself the
    /// `regexMatchError` that made the extraction fail. The retry storm feeds
    /// the thing causing it. Short enough that a genuinely transient failure
    /// costs one browse, long enough to stop the storm.
    private static var backdropFailureCache: [String: (at: Date, generation: UInt64)] = [:]
    private static let backdropFailureTTL: TimeInterval = 10 * 60
    /// The generation both dictionaries were last swept for.
    private static var cachedGeneration: UInt64 = 0

    /// Drop everything remembered for a network we are no longer on. Called
    /// under `backdropCacheLock`.
    private static func purgeIfPathChangedLocked(_ generation: UInt64) {
        guard cachedGeneration != generation else { return }
        cachedGeneration = generation
        backdropURLCache.removeAll()
        // The failures go too, and that is the point: a burst of them recorded
        // while a tunnel was coming up would otherwise keep every one of those
        // titles trailer-less for ten more minutes after it settled.
        backdropFailureCache.removeAll()
        NSLog("[OrivioTrailer] network path changed — dropped the resolved-URL cache")
    }

    /// Remember that a key wouldn't extract — but only if the network we
    /// failed on is still the network we are on. A slow extraction can finish
    /// AFTER a tunnel came up, and a failure earned on the old path must not
    /// be allowed to sit out the next ten minutes on the new one.
    private static func rememberFailure(youtubeKey: String, generation: UInt64) {
        // A cancelled extraction is not a failed one. Every hero rest starts a
        // resolve and stepping along a row cancels each of them in turn, so
        // recording those as failures branded a whole row trailer-less for ten
        // minutes just for browsing past it — and the slower extraction gets
        // (a VPN's remote fallback being the slow case), the more of the row
        // it swallowed.
        guard !Task.isCancelled else { return }
        backdropCacheLock.withLock {
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == generation else { return }
            backdropFailureCache[youtubeKey] = (Date(), generation)
        }
    }

    /// Forget what we resolved for a key. The caller is a player that got a
    /// dead URL: a cached googlevideo link minted on a different path answers
    /// 403 rather than video, and without this the next visit to the title
    /// would cheerfully hand out the same dead link for the rest of the TTL.
    static func invalidate(youtubeKey: String) {
        backdropCacheLock.withLock {
            backdropURLCache.removeValue(forKey: youtubeKey)
            // Not a failure to EXTRACT — re-extracting is exactly what should
            // happen next — so the failure cache must not pick it up either.
            backdropFailureCache.removeValue(forKey: youtubeKey)
        }
    }

    /// The first of `candidates` that resolves, with the key it came from.
    /// See `maxCandidates` for why more than one is tried.
    static func backdropItem(candidates: [String]) async -> (item: AVPlayerItem, youtubeKey: String)? {
        for key in candidates.prefix(maxCandidates) {
            guard !Task.isCancelled else { return nil }
            if let item = await backdropItem(youtubeKey: key) {
                return (item, key)
            }
            NSLog("[OrivioTrailer] backdrop %@ did not resolve — trying the next trailer", key)
        }
        return nil
    }

    static func backdropItem(youtubeKey: String) async -> AVPlayerItem? {
        let generation = TrailerNetworkGeneration.current
        let (cachedHit, cachedFailure) = backdropCacheLock.withLock { () -> (BackdropChoice?, (at: Date, generation: UInt64)?) in
            purgeIfPathChangedLocked(generation)
            return (backdropURLCache[youtubeKey], backdropFailureCache[youtubeKey])
        }
        if let hit = cachedHit,
           Date().timeIntervalSince(hit.at) < backdropURLTTL {
            return await backdropPlayerItem(hit)
        }
        if let cachedFailure,
           Date().timeIntervalSince(cachedFailure.at) < backdropFailureTTL {
            return nil
        }
        guard let streams = await extractStreams(youtubeKey: youtubeKey) else {
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            return nil
        }
        let playable = streams.filter { $0.isNativelyPlayable }
        let muxed = playable.filterVideoAndAudio().highestResolutionStream()
        let adaptive = playable.filterVideoOnly().highestResolutionStream()
        let muxedHeight = muxed?.videoResolution ?? 0
        let adaptiveHeight = adaptive?.videoResolution ?? 0

        let choice: BackdropChoice
        // Apple TV HD: same rule as `playerItem` — the muxed single URL over
        // a two-connection composition merge (see the note there).
        if !PerformanceProfile.isLowPower, adaptiveHeight > muxedHeight, let adaptive {
            // 1080p: video-only plus its own audio track, merged at play time.
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: muxed?.url,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else if let muxed {
            choice = BackdropChoice(video: muxed.url, audio: nil, muxedFallback: muxed.url,
                                    height: muxedHeight, at: Date(), generation: generation)
        } else if let adaptive {
            choice = BackdropChoice(video: adaptive.url,
                                    audio: playable.filterAudioOnly().highestAudioBitrateStream()?.url,
                                    muxedFallback: nil,
                                    height: adaptiveHeight, at: Date(), generation: generation)
        } else {
            rememberFailure(youtubeKey: youtubeKey, generation: generation)
            return nil
        }
        backdropCacheLock.withLock {
            // The path could have moved under us during a multi-second
            // extraction; only keep what still belongs to the current one.
            purgeIfPathChangedLocked(TrailerNetworkGeneration.current)
            guard cachedGeneration == choice.generation else { return }
            backdropURLCache[youtubeKey] = choice
        }
        NSLog("[OrivioTrailer] backdrop %@: %dp (%@)", youtubeKey, choice.height,
              choice.audio == nil ? "muxed" : "merged")
        return await backdropPlayerItem(choice)
    }

    /// Build the item for a resolved backdrop choice.
    ///
    /// `@MainActor` for the same reason `mergedItem` is: `AVPlayerItem.init`
    /// is main-actor isolated. A merge that fails falls back to the muxed URL
    /// — a lower-resolution trailer that still has SOUND, which matters
    /// because the Detail page un-mutes this item.
    @MainActor
    private static func backdropPlayerItem(_ choice: BackdropChoice) async -> AVPlayerItem? {
        guard let audio = choice.audio else {
            return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
        }
        if let merged = await mergedItem(video: choice.video, audio: audio) {
            return merged
        }
        if let fallback = choice.muxedFallback {
            NSLog("[OrivioTrailer] backdrop merge failed — falling back to the muxed stream")
            return budgeted(AVPlayerItem(asset: asset(for: fallback)))
        }
        return budgeted(AVPlayerItem(asset: asset(for: choice.video)))
    }
}

/// A bare `AVPlayerLayer` with no transport chrome — used to play a trailer
/// silently behind the Detail hero. `.resizeAspectFill` so it fills the header
/// like the still backdrop it replaces.
struct BackdropVideoView: UIViewRepresentable {
    /// Optional so a host can keep the layer MOUNTED across previews and just
    /// swap what plays in it. Adding and removing this view mid-browse is a
    /// view-tree structural change, and the focus engine re-resolves on those
    /// — on Home that landed while the viewer was stepping through a row and
    /// left the focus lift stranded on the card they had already left.
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        // Decoration only. Inserting an interactive UIView into the hierarchy
        // makes the focus engine re-resolve, and on the detail page that threw
        // focus off Play and onto the synopsis the moment the backdrop trailer
        // started — the page appeared to grab the highlight on its own a
        // second after it opened. Same rule as the hero artwork.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen trailer playback. Resolves the YouTube key, then plays through
/// the native tvOS `VideoPlayer` transport. Menu (back) dismisses.
struct TrailerPlayerView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let trailer: TMDBService.Trailer
    /// Every trailer TMDB ranked for this title, best first. The one that was
    /// pressed leads; the rest are there because a geo-restricted first choice
    /// shouldn't be the end of it — see `TrailerResolver.maxCandidates`.
    var alternates: [String] = []

    @State private var player: AVPlayer?
    @State private var failed = false

    private var candidates: [String] {
        [trailer.youtubeKey] + alternates.filter { $0 != trailer.youtubeKey }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // Fully release on dismiss: pausing alone leaves the player
                    // registered as the system "Now Playing" item, so pressing
                    // Play/Pause later summons the tvOS transport overlay over
                    // whatever screen you're on. Clearing the item drops it.
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                    }
            } else if failed {
                OrivioEmptyState(
                    icon: "play.slash.fill",
                    title: "Trailer unavailable",
                    message: "This trailer couldn't be loaded. Press Menu to go back."
                )
            } else {
                OrivioLoadingView(label: "Loading trailer")
            }
        }
        .onExitCommand { dismiss() }
        // Release on the CONTAINER, not the VideoPlayer branch: dismissing
        // while "Loading trailer" is still up means the VideoPlayer (and its
        // onDisappear) never existed — the resolved player then played on,
        // headless, and became the system Now Playing item.
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        .task {
            var exhausted: Set<String> = []
            // Two passes, not one. Resolving a key is not the same as being
            // able to PLAY it: a googlevideo URL that the connection can't
            // fetch — refused outright, or minted for a network path the box
            // has since left — leaves the item failed, and the old code sat on
            // that behind "Loading trailer" for as long as anyone waited. Now
            // a dead item moves on to the next trailer the title has.
            for _ in 0..<2 {
                let remaining = candidates.filter { !exhausted.contains($0) }
                guard !remaining.isEmpty,
                      let resolved = await TrailerResolver.playerItem(candidates: remaining) else { break }
                // Everything the resolver walked past is spent, not just the
                // key it settled on — re-extracting a candidate it already
                // gave up on would only buy the same failure twice.
                if let reached = remaining.firstIndex(of: resolved.youtubeKey) {
                    exhausted.formUnion(remaining[...reached])
                } else {
                    exhausted.insert(resolved.youtubeKey)
                }
                // Dismissed during the (multi-second) extraction: never start.
                guard !Task.isCancelled else { return }
                let player = AVPlayer(playerItem: resolved.item)
                // Start on the first available buffer instead of waiting to build a
                // stall-proof one — a trailer should pop up, not spin.
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
                player.play()
                guard await Self.itemFailed(resolved.item) else { return }
                NSLog("[OrivioTrailer] %@ failed to load: %@", resolved.youtubeKey,
                      String(describing: resolved.item.error))
                // Drop it from the shared backdrop cache too, so the page
                // underneath stops handing the same dead link to its hero.
                TrailerResolver.invalidate(youtubeKey: resolved.youtubeKey)
                player.pause()
                player.replaceCurrentItem(with: nil)
                self.player = nil
            }
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Suspends until the item is either playable or broken, and answers only
    /// for the broken case. A cancelled wait (the viewer left) is not a
    /// failure, so it reports `false` and the caller simply returns.
    ///
    /// The deadline matters as much as the status does: a connection that
    /// swallows the request rather than refusing it leaves the item `.unknown`
    /// indefinitely, and that is what left "Loading trailer" on screen for as
    /// long as anyone was willing to watch it. Generous enough that a slow
    /// link still wins on the first pass.
    private static func itemFailed(_ item: AVPlayerItem, timeout: TimeInterval = 25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            switch item.status {
            case .failed: return true
            case .readyToPlay: return false
            default:
                guard Date() < deadline else {
                    NSLog("[OrivioTrailer] gave up waiting for the item to load")
                    return true
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return false
    }
}
