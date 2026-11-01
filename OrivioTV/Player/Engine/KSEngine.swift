import UIKit
import AVFoundation
import KSPlayer

/// KSOptions hooks: display criteria go through `DisplayModeManager` (pinned
/// once per playback, released only by the exit sequence), and a converging
/// A/V servo replaces the stock clock policy.
final class OrivioKSOptions: KSOptions {
    weak var engine: KSEngine?
    private var lateWindowStart: Date?

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        let range: DisplayModeManager.Range
        if isDovi { range = .dolbyVision } else {
            switch formatDescription?.dynamicRange {
            case .hdr10?: range = .hdr10
            case .hlg?: range = .hlg
            case .dolbyVision?: range = .dolbyVision
            default: range = .sdr
            }
        }
        if DisplayModeManager.shared.request(frameRate: Double(refreshRate), range: range) {
            engine?.holdForDisplaySwitch()
        }
    }

    override func playerLayerDeinit() {
        // Never release display criteria in teardown — the exit sequence owns it.
    }

    /// Drop one frame when video has been late by > 1.5 frame durations for a
    /// sustained window (only with ≥ 2 decoded frames queued).
    override func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Double, frameCount: Int) -> (Double, ClockProcessType) {
        let desire = main.time.seconds + CACurrentMediaTime() - main.lastMediaTime - videoDelay
        let diff = nextVideoTime - desire
        let frame = 1 / max(fps, 1)
        if diff >= frame / 2 {
            lateWindowStart = nil
            return (diff, .remain)
        }
        if diff < -1.5 * frame {
            if diff < -2 { lateWindowStart = nil; return (diff, frameCount > 1 ? .flush : .dropGOPPacket) }
            let now = Date()
            if lateWindowStart == nil { lateWindowStart = now }
            if frameCount >= 2, let start = lateWindowStart, now.timeIntervalSince(start) > 0.25 {
                lateWindowStart = now
                return (diff, .dropNextFrame)
            }
            return (diff, .next)
        }
        lateWindowStart = nil
        return (diff, .next)
    }
}

/// Native (KSAVPlayer / AVPlayer) and FFmpeg (KSMEPlayer) engines.
@MainActor
final class KSEngine: NSObject, PlaybackEngine {
    let kind: EngineKind
    weak var delegate: PlaybackEngineDelegate?
    let view = UIView()
    private var layer: KSPlayerLayer?
    private var options: OrivioKSOptions?
    private var firstFrameSent = false
    private var startAt: Double = 0
    /// AVPlayer ignores `startPlayTime`; the native engine seeks once when ready.
    private var didInitialSeek = false
    private var lastState: EngineState = .preparing
    private var selectedSubtitleInfo: (any SubtitleInfo)?
    private var _audioDelay: Double = 0

    init(kind: EngineKind) {
        precondition(kind == .native || kind == .ffmpeg)
        self.kind = kind
        super.init()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
    }

    private var player: MediaPlayerProtocol? { layer?.player }

    func start(url: URL, headers: [String: String], startAt: Double) {
        self.startAt = startAt
        didInitialSeek = false
        KSOptions.firstPlayerType = kind == .native ? KSAVPlayer.self : KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        // Otherwise 23.976 content was paced on a 30 Hz grid and audio ran ~250 ms early.
        KSOptions.preferredFrame = false
        KSOptions.isAutoPlay = true
        let o = OrivioKSOptions()
        o.engine = self
        if !headers.isEmpty { o.appendHeader(headers) }
        o.userAgent = headers["User-Agent"] ?? HTTP.userAgent
        if let ref = headers["Referer"] { o.referer = ref }
        o.startPlayTime = startAt
        o.isSecondOpen = true
        o.isAccurateSeek = false
        o.hardwareDecode = true
        o.autoSelectEmbedSubtitle = false
        o.registerRemoteControll = false
        o.preferredForwardBufferDuration = PerformanceProfile.isLowPower ? 2 : 3
        o.maxBufferDuration = PerformanceProfile.isLowPower ? 30 : (PerformanceProfile.isMidPower ? 60 : 120)
        // Engines bound a stalled read; the cache's own timeouts stay below this.
        o.formatContextOptions["rw_timeout"] = 20_000_000
        o.formatContextOptions["reconnect"] = 1
        o.formatContextOptions["reconnect_streamed"] = 1
        o.formatContextOptions["reconnect_delay_max"] = 4
        options = o
        let l = KSPlayerLayer(url: url, isAutoPlay: true, options: o, delegate: self)
        layer = l
        attachView()
    }

    private func attachView() {
        view.subviews.forEach { $0.removeFromSuperview() }
        guard let v = player?.view else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    var currentTime: Double { player?.currentPlaybackTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }
    var bufferedTime: Double { player?.playableTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var isReady: Bool { player?.isReadyToPlay ?? false }
    var naturalSize: CGSize { player?.naturalSize ?? .zero }
    var chapters: [Chapter] { player?.chapters ?? [] }
    var downloadedBytes: Int64 { player?.dynamicInfo?.bytesRead ?? 0 }
    var supportsAudioDelay: Bool { kind == .ffmpeg }

    var avPlayerLayer: AVPlayerLayer? { (player as? KSAVPlayer)?.playerLayer }

    var rate: Float {
        get { player?.playbackRate ?? 1 }
        set { player?.playbackRate = newValue }
    }

    var audioDelay: Double {
        get { _audioDelay }
        set {
            _audioDelay = newValue
            // FFmpeg: videoDelay = −offset.
            layer?.options.videoDelay = -newValue
        }
    }

    // MARK: Tracks

    private func makeTrack(_ t: MediaPlayerTrack, index: Int) -> EngineTrack {
        let desc = t.description.lowercased()
        let codec = Self.codecName(t)
        let channels = t.audioStreamBasicDescription.map { Int($0.mChannelsPerFrame) }
        return EngineTrack(id: "\(t.trackID)", index: index, name: t.name, language: t.languageCode, codec: codec,
                           channels: channels, isDefault: t.isEnabled, isForced: desc.contains("forced"),
                           isImage: t.isImageSubtitle,
                           isAtmos: desc.contains("atmos") || desc.contains("joc"))
    }

    static func codecName(_ t: MediaPlayerTrack) -> String? {
        let fourcc = t.mediaSubType.rawValue
        switch fourcc {
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatLinearPCM: return "PCM"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AV1: return "AV1"
        default:
            let d = t.description.lowercased()
            if d.contains("truehd") { return "TrueHD" }
            if d.contains("dts") { return "DTS" }
            if d.contains("eac3") { return "E-AC-3" }
            if d.contains("ac3") { return "AC-3" }
            return nil
        }
    }

    var audioTracks: [EngineTrack] {
        (player?.tracks(mediaType: .audio) ?? []).enumerated().map { makeTrack($1, index: $0) }
    }

    var selectedAudio: EngineTrack? {
        let list = player?.tracks(mediaType: .audio) ?? []
        guard let i = list.firstIndex(where: { $0.isEnabled }) else { return nil }
        return makeTrack(list[i], index: i)
    }

    var subtitleTracks: [EngineTrack] {
        (player?.tracks(mediaType: .subtitle) ?? []).enumerated().map { makeTrack($1, index: $0) }
    }

    func select(audio: EngineTrack) {
        guard let t = player?.tracks(mediaType: .audio).first(where: { "\($0.trackID)" == audio.id }) else { return }
        player?.select(track: t)
    }

    func select(subtitle: EngineTrack?) {
        selectedSubtitleInfo?.isEnabled = false
        selectedSubtitleInfo = nil
        guard let subtitle else {
            if kind == .native, let p = player as? KSAVPlayer, let g = legibleGroup(p) { p.player.currentItem?.select(nil, in: g) }
            return
        }
        guard let t = player?.tracks(mediaType: .subtitle).first(where: { "\($0.trackID)" == subtitle.id }) else { return }
        if kind == .ffmpeg, let info = t as? (any SubtitleInfo) {
            info.isEnabled = true
            selectedSubtitleInfo = info
        }
        player?.select(track: t)
    }

    private func legibleGroup(_ p: KSAVPlayer) -> AVMediaSelectionGroup? {
        p.player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
    }

    func subtitleParts(at time: Double) -> [SubtitlePart] {
        selectedSubtitleInfo?.search(for: time) ?? []
    }

    /// Native AVPlayer subtitle styling (no edge colour there — outline is on/off).
    func applyNativeTextStyle(_ s: PlayerSettings) {
        guard kind == .native, let item = (player as? KSAVPlayer)?.player.currentItem else { return }
        var attrs: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: s.subtitleSize / 36 * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: SubtitleStyle.argb(SubtitleStyle.color(s.subtitleColor)),
        ]
        if s.subtitleBackground {
            attrs[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [s.subtitleBackgroundOpacity, 0, 0, 0]
        } else {
            attrs[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [0, 0, 0, 0]
        }
        if s.subtitleBold { attrs[kCMTextMarkupAttribute_BoldStyle as String] = true }
        attrs[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = s.subtitleOutline ? kCMTextMarkupCharacterEdgeStyle_Uniform : kCMTextMarkupCharacterEdgeStyle_None
        if let rule = AVTextStyleRule(textMarkupAttributes: attrs) { item.textStyleRules = [rule] }
    }

    // MARK: Video info

    var videoInfo: VideoFormatInfo {
        var info = VideoFormatInfo()
        guard let t = player?.tracks(mediaType: .video).first(where: { $0.isEnabled }) ?? player?.tracks(mediaType: .video).first else { return info }
        info.codec = Self.codecName(t)
        info.resolution = t.naturalSize == .zero ? naturalSize : t.naturalSize
        info.bitDepth = t.bitDepth > 0 ? Int(t.bitDepth) : nil
        info.frameRate = t.nominalFrameRate > 0 ? Double(t.nominalFrameRate) : nil
        info.bitrate = t.bitRate > 0 ? Int(t.bitRate) : nil
        info.primaries = t.colorPrimaries.map(Self.prettyColor)
        info.transfer = t.transferFunction.map(Self.prettyColor)
        if let dovi = t.dovi {
            info.isDolbyVision = true
            info.dvProfile = Int(dovi.dv_profile)
            info.dynamicRange = "Dolby Vision \(dovi.dv_profile)"
            info.output = DisplayModeManager.shared.supportsDolbyVision ? "Native Dolby Vision" : "HDR10 base layer"
        } else {
            switch t.dynamicRange {
            case .hdr10?: info.dynamicRange = "HDR10"; info.isHDR = true
            case .hlg?: info.dynamicRange = "HLG"; info.isHDR = true
            case .dolbyVision?: info.dynamicRange = "Dolby Vision"; info.isDolbyVision = true
            default:
                info.untagged = t.colorPrimaries == nil && t.transferFunction == nil
                info.dynamicRange = info.untagged ? "SDR · no colour tags" : "SDR"
            }
        }
        return info
    }

    var audioInfo: AudioFormatInfo {
        guard let a = selectedAudio else { return AudioFormatInfo() }
        var info = AudioFormatInfo()
        info.codec = a.codec.map(Self.longCodec)
        info.channels = a.channels
        let passthrough = kind == .native && (a.codec == "E-AC-3" || a.codec == "AC-3")
        if a.isAtmos {
            info.atmos = passthrough ? "Tagged in file" : (a.codec == "TrueHD" ? "Tagged — decoded to PCM" : "Tagged — lost in decode")
        } else {
            info.atmos = "Not tagged"
        }
        let routeChannels = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        if passthrough { info.output = "Dolby bitstream → HDMI" } else if (a.channels ?? 2) > 2, routeChannels > 2 {
            info.output = "Multichannel PCM → HDMI"
        } else {
            info.output = "Stereo PCM → HDMI"
        }
        return info
    }

    static func longCodec(_ c: String) -> String {
        switch c {
        case "E-AC-3": return "Dolby Digital Plus (E-AC-3)"
        case "AC-3": return "Dolby Digital (AC-3)"
        case "TrueHD": return "Dolby TrueHD"
        default: return c
        }
    }

    static func prettyColor(_ s: String) -> String {
        let map = ["ITU_R_709_2": "BT.709", "ITU_R_2020": "BT.2020", "SMPTE_ST_2084_PQ": "PQ (ST 2084)",
                   "ITU_R_2100_HLG": "HLG", "P3_D65": "Display P3", "SMPTE_C": "SMPTE-C", "EBU_3213": "EBU 3213"]
        for (k, v) in map where s.contains(k) { return v }
        return s
    }

    // MARK: Transport

    func play() {
        if displayHold != nil { resumeAfterHold = true; return }
        layer?.play()
    }
    func pause() {
        if displayHold != nil { resumeAfterHold = false; return }
        layer?.pause()
    }

    // MARK: Display switch

    /// The FFmpeg path asks for display matching from KSPlayer's render loop; the
    /// native (AVPlayer) path never did, so .mp4/HLS titles played in whatever
    /// mode the menus were in. Ask from the video track — tvOS's Match Content
    /// toggles still decide what actually changes.
    private func requestNativeDisplayMode() {
        let tracks = player?.tracks(mediaType: .video) ?? []
        guard let t = tracks.first(where: { $0.isEnabled }) ?? tracks.first else { return }
        let range: DisplayModeManager.Range
        if t.dovi != nil {
            range = .dolbyVision
        } else {
            switch t.dynamicRange {
            case .hdr10?: range = .hdr10
            case .hlg?: range = .hlg
            case .dolbyVision?: range = .dolbyVision
            default: range = .sdr
            }
        }
        let fps = t.nominalFrameRate > 0 ? Double(t.nominalFrameRate) : Double(UIScreen.main.maximumFramesPerSecond)
        if DisplayModeManager.shared.request(frameRate: fps, range: range) { holdForDisplaySwitch() }
    }

    private var displayHold: Task<Void, Never>?
    private var resumeAfterHold = true

    /// Same handshake as the Dolby Vision engine: while the TV changes mode the
    /// picture is out of the hierarchy and the clock is held, then both return.
    func holdForDisplaySwitch() {
        guard displayHold == nil else { return }
        resumeAfterHold = true
        view.isHidden = true
        layer?.pause()
        displayHold = Task { @MainActor [weak self] in
            await DisplayModeManager.shared.waitForSwitch()
            guard let self, !Task.isCancelled else { return }
            self.view.isHidden = false
            self.displayHold = nil
            if self.resumeAfterHold { self.layer?.play() }
        }
    }

    func seek(to time: Double, completion: @escaping (Bool) -> Void) {
        // Never `play()` inside a seek — the view model's seek-play watchdog does that.
        guard let layer else { completion(false); return }
        let wasPlaying = layer.state.isPlaying
        layer.seek(time: max(0, time), autoPlay: wasPlaying) { ok in completion(ok) }
    }

    func setContentMode(_ mode: UIView.ContentMode) {
        player?.contentMode = mode
    }

    func stop() {
        displayHold?.cancel()
        displayHold = nil
        layer?.delegate = nil
        layer?.stop()
        layer = nil
        options = nil
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    private func setState(_ s: EngineState) {
        guard s != lastState else { return }
        lastState = s
        delegate?.engine(self, state: s)
    }
}

extension KSEngine: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .initialized, .preparing: setState(.preparing)
        case .readyToPlay:
            attachView()
            if kind == .native { requestNativeDisplayMode() }
            if kind == .native, startAt > 1, !didInitialSeek {
                didInitialSeek = true
                layer.seek(time: startAt, autoPlay: true) { _ in }
            }
            setState(.ready)
            delegate?.engineTracksChanged(self)
        case .buffering: setState(.buffering)
        case .bufferFinished: setState(layer.player.isPlaying ? .playing : .paused)
        case .paused: setState(.paused)
        case .playedToTheEnd: setState(.ended)
        case .error: setState(.failed("The stream couldn't be played."))
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        if !firstFrameSent, layer.player.isReadyToPlay, currentTime > 0.04, layer.player.isPlaying || abs(currentTime - startAt) > 0.04 {
            firstFrameSent = true
            delegate?.engineDidRenderFirstFrame(self)
        }
        if lastState == .buffering, layer.player.isPlaying, layer.player.loadState == .playable { setState(.playing) }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error { setState(.failed(error.localizedDescription)) } else { setState(.ended) }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}
