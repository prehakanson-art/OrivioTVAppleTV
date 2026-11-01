import UIKit
import AVFoundation
import KSPlayer
import TVVLCKit

/// VLCKit engine — the manual fallback, and full ASS/SSA styling (VLC renders subtitles itself).
@MainActor
final class VLCEngine: NSObject, PlaybackEngine {
    let kind: EngineKind = .vlc
    weak var delegate: PlaybackEngineDelegate?
    let view = UIView()
    private let player = VLCMediaPlayer()
    private var lastState: EngineState = .preparing
    private var firstFrameSent = false
    private var startAt: Double = 0
    private var didSeekToStart = false
    private var _audioDelay: Double = 0
    private var slaveSubtitleIDs: [String: Int32] = [:]

    override init() {
        super.init()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.drawable = view
        player.delegate = self
    }

    func start(url: URL, headers: [String: String], startAt: Double) {
        self.startAt = startAt
        let media = VLCMedia(url: url)
        if let ua = headers["User-Agent"] { media.addOption(":http-user-agent=\(ua)") } else { media.addOption(":http-user-agent=\(HTTP.userAgent)") }
        if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
        media.addOption(":network-caching=\(PerformanceProfile.isLowPower ? 3000 : 6000)")
        if startAt > 1 { media.addOption(":start-time=\(Int(startAt))") }
        player.media = media
        player.play()
    }

    var currentTime: Double { Double(player.time.intValue) / 1000 }
    var duration: Double { Double(player.media?.length.intValue ?? 0) / 1000 }
    var bufferedTime: Double { currentTime + 5 }
    var isPlaying: Bool { player.isPlaying }
    var isReady: Bool { lastState != .preparing }
    var naturalSize: CGSize { player.videoSize }
    var chapters: [Chapter] { [] }
    var downloadedBytes: Int64 { 0 }
    var supportsAudioDelay: Bool { true }
    var avPlayerLayer: AVPlayerLayer? { nil }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var audioDelay: Double {
        get { _audioDelay }
        set {
            _audioDelay = newValue
            // VLC: audio delay in µs (positive = audio later).
            player.currentAudioPlaybackDelay = Int(newValue * 1_000_000)
        }
    }

    var audioTracks: [EngineTrack] {
        let names = player.audioTrackNames as? [String] ?? []
        let ids = player.audioTrackIndexes as? [NSNumber] ?? []
        return zip(ids, names).enumerated().compactMap { i, pair in
            guard pair.0.intValue >= 0 else { return nil }
            let lower = pair.1.lowercased()
            return EngineTrack(id: "\(pair.0.intValue)", index: i, name: pair.1, language: nil,
                               codec: lower.contains("e-ac3") || lower.contains("eac3") ? "E-AC-3" : (lower.contains("truehd") ? "TrueHD" : nil),
                               channels: nil, isDefault: Int32(pair.0.intValue) == player.currentAudioTrackIndex, isForced: false, isImage: false,
                               isAtmos: lower.contains("atmos"))
        }
    }

    var selectedAudio: EngineTrack? { audioTracks.first { $0.id == "\(player.currentAudioTrackIndex)" } }

    var subtitleTracks: [EngineTrack] {
        let names = player.videoSubTitlesNames as? [String] ?? []
        let ids = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        return zip(ids, names).enumerated().compactMap { i, pair in
            guard pair.0.intValue >= 0, !slaveSubtitleIDs.values.contains(Int32(pair.0.intValue)) else { return nil }
            return EngineTrack(id: "\(pair.0.intValue)", index: i, name: pair.1, language: nil, codec: nil, channels: nil,
                               isDefault: false, isForced: pair.1.lowercased().contains("forced"), isImage: false)
        }
    }

    func select(audio: EngineTrack) {
        if let i = Int32(audio.id) { player.currentAudioTrackIndex = i }
    }

    func select(subtitle: EngineTrack?) {
        guard let subtitle, let i = Int32(subtitle.id) else { player.currentVideoSubTitleIndex = -1; return }
        player.currentVideoSubTitleIndex = i
    }

    /// VLC renders add-on subtitles itself (full ASS styling).
    func addSubtitle(url: URL, id: String, select: Bool) {
        _ = player.addPlaybackSlave(url, type: .subtitle, enforce: select)
    }

    func subtitleParts(at time: Double) -> [SubtitlePart] { [] }

    var videoInfo: VideoFormatInfo {
        var v = VideoFormatInfo()
        v.resolution = player.videoSize == .zero ? nil : player.videoSize
        v.dynamicRange = "Decoded by VLC"
        return v
    }

    var audioInfo: AudioFormatInfo {
        AudioFormatInfo(codec: selectedAudio?.name, channels: nil, atmos: "Decoded by VLC", output: "PCM → HDMI")
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to time: Double, completion: @escaping (Bool) -> Void) {
        player.time = VLCTime(int: Int32(max(0, time) * 1000))
        completion(true)
    }

    func setContentMode(_ mode: UIView.ContentMode) {
        player.scaleFactor = 0
        player.videoAspectRatio = nil
    }

    func stop() {
        player.delegate = nil
        player.stop()
        player.drawable = nil
    }

    private func setState(_ s: EngineState) {
        guard s != lastState else { return }
        lastState = s
        delegate?.engine(self, state: s)
    }
}

extension VLCEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            switch player.state {
            case .opening: setState(.preparing)
            case .buffering: if lastState == .preparing { setState(.ready) } else if lastState != .paused { setState(.buffering) }
            case .playing: setState(.playing); delegate?.engineTracksChanged(self)
            case .paused: setState(.paused)
            case .ended, .stopped: if lastState != .preparing { setState(.ended) }
            case .error: setState(.failed("VLC couldn't open the stream."))
            case .esAdded: delegate?.engineTracksChanged(self)
            @unknown default: break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            if !firstFrameSent, currentTime > 0 {
                firstFrameSent = true
                if lastState == .preparing || lastState == .buffering { setState(.playing) }
                delegate?.engineDidRenderFirstFrame(self)
            }
            if lastState == .buffering { setState(.playing) }
        }
    }
}
