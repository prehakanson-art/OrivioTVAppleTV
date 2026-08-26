import TVVLCKit
import UIKit

/// Lightweight VLC playback engine — the alternative to KSPlayer, the same
/// pairing Stremio's tvOS app ships (KSPlayer default + VLC toggle). VLC is a
/// feature-reduced engine: it buffers internally (no "seconds ahead" the way
/// AVPlayer/KSPlayer expose, so no cache-line / caching-% hold) and renders
/// its own subtitles. It's the "try this when a file is choppy on FFmpeg"
/// fallback. Owns a VLCMediaPlayer and forwards state/time to the view model
/// through closures so the rest of the player (scrub, progress, failover)
/// reads the same `position`/`duration`/`isPlaying` mirrors as the KS path.
/// Not `@MainActor` on the class: it conforms to the ObjC
/// `VLCMediaPlayerDelegate` (a nonisolated requirement). VLCKit invokes the
/// delegate on the main thread, so the delegate methods `assumeIsolated` to
/// call the `@MainActor` callbacks synchronously without a hop. All other
/// methods are only ever called from PlayerViewModel (already on main).
final class VLCEngine: NSObject {
    let player = VLCMediaPlayer()
    /// The UIView VLC renders into (handed to PlayerVideoView).
    let videoView = UIView()

    /// (isPlaying, isBuffering, ended, errored)
    var onState: (@MainActor (Bool, Bool, Bool, Bool) -> Void)?
    /// (currentSeconds, totalSeconds)
    var onTime: (@MainActor (TimeInterval, TimeInterval) -> Void)?

    override init() {
        super.init()
        videoView.backgroundColor = .black
        player.drawable = videoView
        player.delegate = self
    }

    /// `networkCachingMs` is how much VLC pre-buffers — larger is smoother on
    /// remote 4K, at the cost of RAM and a slower first frame. `headers` are
    /// the addon's `behaviorHints.proxyHeaders.request` — libVLC has no generic
    /// header option, but it does expose the two that scraper addons actually
    /// send (Referer / User-Agent), which is what those CDNs check.
    func load(url: URL, networkCachingMs: Int, headers: [String: String]? = nil) {
        let media = VLCMedia(url: url)
        if let headers {
            for (key, value) in headers {
                switch key.lowercased() {
                case "referer", "referrer": media.addOption(":http-referrer=\(value)")
                case "user-agent": media.addOption(":http-user-agent=\(value)")
                default: break
                }
            }
        }
        media.addOption(":network-caching=\(networkCachingMs)")
        media.addOption(":file-caching=\(networkCachingMs)")
        // Ride out transient CDN drops instead of erroring out.
        media.addOption(":http-reconnect")
        // Skip the preparse/metadata pass — faster first frame on huge files.
        media.addOption(":no-video-title-show")
        player.media = media
    }

    func play() { player.play() }
    func pause() { if player.isPlaying { player.pause() } }
    func stop() { player.stop() }

    func seek(to seconds: TimeInterval) {
        let target = max(seconds, 0)
        // The time setter is silently ignored on many network streams (VLC
        // played from 0 after every engine switch); the POSITION-fraction
        // setter is what VLCKit honors reliably for HTTP input. Use it when
        // the media length is known, keeping the time setter as the fallback
        // for local/parsed media and as a best-effort first shot.
        player.time = VLCTime(int: Int32(target * 1000))
        let lengthMs = player.media?.length.intValue ?? 0
        if lengthMs > 0 {
            player.position = Float(min(max(target * 1000 / Double(lengthMs), 0), 0.999))
        }
    }

    var currentTime: TimeInterval { Double(player.time.intValue) / 1000 }
    var duration: TimeInterval {
        Double(player.media?.length.intValue ?? 0) / 1000
    }
    var isPlaying: Bool { player.isPlaying }
    var naturalSize: CGSize { player.videoSize }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    // MARK: Tracks

    struct EngineTrack {
        let id: Int32
        let name: String
    }

    var audioTracks: [EngineTrack] {
        zip(player.audioTrackIndexes, player.audioTrackNames).compactMap { idx, name in
            guard let id = (idx as? NSNumber)?.int32Value else { return nil }
            return EngineTrack(id: id, name: (name as? String) ?? "Audio \(id)")
        }
    }

    var subtitleTracks: [EngineTrack] {
        zip(player.videoSubTitlesIndexes, player.videoSubTitlesNames).compactMap { idx, name in
            guard let id = (idx as? NSNumber)?.int32Value else { return nil }
            return EngineTrack(id: id, name: (name as? String) ?? "Subtitle \(id)")
        }
    }

    var currentAudioID: Int32 { player.currentAudioTrackIndex }
    var currentSubtitleID: Int32 { player.currentVideoSubTitleIndex }

    func selectAudio(_ id: Int32) { player.currentAudioTrackIndex = id }
    /// `-1` disables subtitles in VLC.
    func selectSubtitle(_ id: Int32) { player.currentVideoSubTitleIndex = id }

    func addExternalSubtitle(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCEngine: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = player.state
        let buffering = state == .buffering || state == .opening
        let ended = state == .ended
        let errored = state == .error
        let playing = player.isPlaying
        MainActor.assumeIsolated {
            onState?(playing, buffering, ended, errored)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let current = currentTime
        let total = duration
        MainActor.assumeIsolated {
            onTime?(current, total)
        }
    }
}
