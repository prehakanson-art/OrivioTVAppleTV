import AVFoundation
import KSPlayer
import UIKit

/// What the preflight decided for a direct-engine session (§7.2).
struct DVDirectConfig {
    var preferredAudioLanguage = ""
    var preferredAudioLabel: String?
    var convertProfile7 = false
    var downmixToStereo = false
    /// P7 base layer only (strip the DV NALs, play HDR10) — taken when P7
    /// conversion is off for this tier but the file has a Dolby bitstream to win.
    var forceHDR10 = false
    var streamNameSaysAtmos = false
    var probe = StreamProbeResult()
    /// Settings → Dolby Atmos passthrough (§7.4, `AtmosHLS`).
    var atmosPassthrough = true
    /// The ORIGIN for the Atmos remux. The engine itself may read through the
    /// hybrid-cache proxy; the remux must not, or its 90 s read-ahead would
    /// register as a second playback reader and steer the cache's eviction.
    var atmosSourceURL: URL?
}

/// `PlaybackEngine` over `DVSampleEngine` — the sample-feed engine (FFmpeg demux →
/// CMSampleBuffer → AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer).
///
/// Display handshake (§7.6, the old app's "switch first, attach later"): when a
/// mode change is requested the engine is held paused with its picture NOT in
/// the hierarchy until the panel settles, then attached and rolled — attaching
/// a live surface during HDMI renegotiation is what wedged panels grey.
@MainActor
final class DVDirectEngine: PlaybackEngine {
    let kind: EngineKind = .dvDirect
    weak var delegate: PlaybackEngineDelegate?
    /// Hosts the engine's layer view once the display has settled.
    let view: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        return v
    }()

    private let config: DVDirectConfig
    private var engine: DVSampleEngine?
    private var startAt: Double = 0
    private var reportedFirstFrame = false
    private var lastTick: Double = -1
    private var buffering = true
    private var handshake: Task<Void, Never>?
    /// The viewer's play/pause intent while the handshake holds the clock.
    private var wantsPlay = true
    private var settled = false
    private var cues: [SubtitlePart] = []
    private var stopped = false
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]

    // ---- Atmos passthrough (E-AC-3 JOC → loopback fMP4/HLS → AVPlayer → Dolby MAT) ----
    private var atmos: AtmosPassthrough?
    private var atmosTimer: Timer?
    /// Sessions that failed on this engine; after two the engine keeps the audio.
    private var atmosFailures = 0
    private static let atmosMaxFailures = 2
    /// The engine's own audio is muted because the AVPlayer has it.
    private var atmosEngineMuted = false
    private var atmosWaitingSince: Date?
    private var atmosLastVideoClock: Double = 0
    private var atmosClockSampledAt = Date.distantPast
    private var atmosClockAdvancing = false
    private var atmosLastResync = Date.distantPast
    /// How far ahead of the picture to resume the AVPlayer: its measured start-up lag.
    private var atmosLead: Double = 0
    /// The viewer's mute (PiP window), kept across Atmos hand-overs.
    private var userMuted = false
    #if DEBUG
    private var atmosTraceTick = 0
    #endif

    init(config: DVDirectConfig) {
        self.config = config
    }

    // MARK: State

    var currentTime: Double { engine?.position ?? startAt }
    var duration: Double { engine?.duration ?? config.probe.durationSeconds }
    var bufferedTime: Double { max(engine?.bufferedUpTo ?? 0, currentTime) }
    var isPlaying: Bool { engine?.isPlaying ?? false }
    var isReady: Bool { engine != nil && settled }
    var naturalSize: CGSize {
        guard let e = engine, e.videoWidth > 0 else { return .zero }
        return CGSize(width: e.videoWidth, height: e.videoHeight)
    }
    var chapters: [Chapter] { engine?.chapters ?? [] }

    var rate: Float {
        get { engine?.rate ?? 1 }
        set {
            engine?.rate = newValue
            // The engine owns the audio at any speed but 1x; at 1x Atmos may resume.
            if newValue != 1 { stopAtmos(restoreEngineAudio: true) } else { startAtmosIfEligible(resume: currentTime) }
        }
    }

    var audioTracks: [EngineTrack] {
        guard let e = engine else { return [] }
        let current = e.currentAudioIndex
        return e.audioTracks.enumerated().map { i, t in
            let report = e.audioReport(index: t.index)
            // `name` empty: the engine's label is "English · EAC3 · 6ch", which
            // `displayName` would repeat next to its own language/codec/channels.
            return EngineTrack(id: "\(t.index)", index: i, name: t.lang.isEmpty ? t.label : "", language: t.lang.isEmpty ? nil : t.lang,
                               codec: report.map { Self.codecLabel($0.codec) }, channels: report.map(\.channels).flatMap { $0 > 0 ? $0 : nil },
                               isDefault: t.index == current, isForced: false, isImage: false,
                               isAtmos: report?.sourceSaysAtmos ?? false)
        }
    }

    var selectedAudio: EngineTrack? {
        guard let e = engine else { return nil }
        return audioTracks.first { $0.id == "\(e.currentAudioIndex)" }
    }

    var subtitleTracks: [EngineTrack] {
        (engine?.subtitleTracks ?? []).enumerated().map { i, t in
            EngineTrack(id: "\(t.index)", index: i, name: t.label, language: nil, codec: t.isBitmap ? "PGS" : nil,
                        channels: nil, isDefault: false, isForced: t.label.hasSuffix("Forced"), isImage: t.isBitmap)
        }
    }

    var videoInfo: VideoFormatInfo {
        var info = VideoFormatInfo()
        guard let e = engine else { return info }
        info.codec = e.videoCodecName
        info.resolution = naturalSize == .zero ? nil : naturalSize
        info.frameRate = e.videoFPS > 0 ? Double(e.videoFPS) : nil
        info.bitrate = e.containerMbps > 0 ? Int(e.containerMbps * 1_000_000) : nil
        let profile = e.detectedDVProfile
        if profile > 0, !e.forceHDR10 {
            info.isDolbyVision = true
            info.dvProfile = profile
            info.dynamicRange = profile == 7 ? "Dolby Vision 7 → 8.1" : "Dolby Vision \(profile)"
            info.output = DisplayModeManager.shared.supportsDolbyVision ? "Native Dolby Vision (direct sample feed)" : "HDR10 base layer"
        } else if config.probe.isPQ || e.forceHDR10 {
            info.isHDR = true
            info.dynamicRange = e.forceHDR10 ? "HDR10 (P7 base layer)" : (config.probe.hasHDR10Plus ? "HDR10+" : "HDR10")
            info.output = "Direct sample feed"
        } else {
            info.dynamicRange = "SDR"
            info.output = "Direct sample feed"
        }
        return info
    }

    var audioInfo: AudioFormatInfo {
        guard let e = engine else { return AudioFormatInfo() }
        let path = e.audioPath
        var info = AudioFormatInfo()
        info.codec = KSEngine.longCodec(Self.codecLabel(path.codec))
        info.channels = path.channels > 0 ? path.channels : nil
        if let atmos, atmos.isAudible {
            info.atmos = "Passthrough (Dolby MAT)"
            info.output = "Dolby Atmos → HDMI (AVPlayer)"
            return info
        }
        if path.sourceSaysAtmos {
            // Never claim Atmos output for a decoded track (TrueHD is always PCM here).
            info.atmos = path.passthrough && (path.codec == "eac3" || path.codec == "ac3")
                ? "Tagged in file" : (path.codec == "truehd" ? "Tagged — decoded to PCM" : "Tagged — lost in decode")
        } else {
            info.atmos = "Not tagged"
        }
        // "Passthrough" here means "handed to tvOS compressed" — only E-AC-3/AC-3
        // leave as a Dolby bitstream; AAC is decoded by tvOS itself.
        let dolby = path.codec == "eac3" || path.codec == "ac3"
        if path.passthrough {
            info.output = dolby ? "Dolby bitstream → HDMI" : "\(Self.codecLabel(path.codec)) decoded by tvOS → HDMI"
        } else {
            info.output = path.downmixed ? "Stereo PCM → HDMI" : "\(path.channels > 2 ? "Multichannel" : "Stereo") PCM → HDMI"
        }
        return info
    }

    var supportsAudioDelay: Bool { true }
    var audioDelay: Double = 0 {
        didSet { engine?.setAudioDelay(audioDelay) }
    }
    var downloadedBytes: Int64 { 0 }
    var avPlayerLayer: AVPlayerLayer? { nil }

    /// The engine's own live state (queues, clock, renderer readiness) for diagnostics.
    var probeLines: [String] { engine?.probeLines ?? [] }

    static func codecLabel(_ ffmpegName: String) -> String {
        switch ffmpegName.lowercased() {
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "truehd", "mlp": return "TrueHD"
        case "dts": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        default: return ffmpegName.uppercased()
        }
    }

    // MARK: Lifecycle

    func start(url: URL, headers: [String: String], startAt: Double) {
        self.startAt = max(0, startAt)
        sourceURL = url
        sourceHeaders = headers
        let e = DVSampleEngine(input: url.absoluteString, startAt: self.startAt,
                               preferredAudioLanguage: config.preferredAudioLanguage,
                               convertProfile7: config.convertProfile7,
                               requestHeaders: headers.isEmpty ? nil : headers,
                               downmixToStereo: config.downmixToStereo,
                               forceHDR10: config.forceHDR10,
                               preferredAudioLabel: config.preferredAudioLabel,
                               streamNameSaysAtmos: config.streamNameSaysAtmos)
        engine = e
        e.setAudioDelay(audioDelay)
        // Callbacks capture the engine WEAKLY and check identity: a retired
        // engine's late callbacks must never reach this session (and a strong
        // capture is the engine → closure → engine cycle the old app leaked).
        e.onTime = { [weak self, weak e] seconds in
            guard let self, let e, self.engine === e else { return }
            self.tick(seconds)
        }
        e.onBuffering = { [weak self, weak e] isBuffering in
            guard let self, let e, self.engine === e else { return }
            self.buffering = isBuffering
            if isBuffering { self.delegate?.engine(self, state: .buffering) }
            // Leaving a hold is reported by the next ADVANCING tick, not here.
        }
        e.onEnded = { [weak self, weak e] in
            guard let self, let e, self.engine === e else { return }
            self.delegate?.engine(self, state: .ended)
        }
        e.onError = { [weak self, weak e] message in
            guard let self, let e, self.engine === e else { return }
            self.delegate?.engine(self, state: .failed("Dolby Vision engine: \(message)"))
        }
        e.onSubtitleEvent = { [weak self, weak e] start, end, text, image, origin, canvas in
            guard let self, let e, self.engine === e else { return }
            self.addCue(start: start, end: end, text: text, image: image, origin: origin, canvas: canvas)
        }
        delegate?.engine(self, state: .preparing)
        e.start { [weak self, weak e] ok, reason in
            guard let self, let e, self.engine === e else { return }
            guard ok else {
                self.delegate?.engine(self, state: .failed("Dolby Vision engine declined: \(reason)"))
                return
            }
            self.beginDisplayHandshake(e)
        }
    }

    /// Request the display mode first; attach the picture only once the panel settled.
    private func beginDisplayHandshake(_ e: DVSampleEngine) {
        let profile = e.detectedDVProfile
        let range: DisplayModeManager.Range = profile > 0 && !e.forceHDR10 ? .dolbyVision : (config.probe.isPQ || e.forceHDR10 ? .hdr10 : .sdr)
        let before = UIScreen.main.maximumFramesPerSecond
        let switching = DisplayModeManager.shared.request(frameRate: Double(e.videoFPS), range: range)
        PlayerProbe.event("dv", "display gate: profile=\(profile) range=\(range.label) fps=\(e.videoFPS) switching=\(switching)")
        guard switching else {
            attach(e)
            return
        }
        // Hold the clock (the engine's preroll keeps filling meanwhile).
        e.pause()
        handshake = Task { @MainActor [weak self, weak e] in
            // tvOS says when the switch is over (rate- and range-only switches alike).
            let switched = await DisplayModeManager.shared.waitForSwitch()
            if Task.isCancelled { return }
            // Older panels report the end before the picture is back: a little
            // more margin after a real refresh-rate change.
            if switched, UIScreen.main.maximumFramesPerSecond != before {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, let e, !Task.isCancelled, self.engine === e, !self.stopped else { return }
            PlayerProbe.event("dv", "display settled at \(UIScreen.main.maximumFramesPerSecond) fps — attaching video")
            self.attach(e)
        }
    }

    private func attach(_ e: DVSampleEngine) {
        settled = true
        let v = e.videoView
        v.frame = view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(v)
        if wantsPlay { e.play() } else { e.pause() }
        delegate?.engine(self, state: .ready)
        delegate?.engineTracksChanged(self)
        startAtmosIfEligible(resume: startAt)
    }

    /// Progress drives state: only an ADVANCING clock clears buffering and proves
    /// the first frame (a fixed-rate tick fires whether or not anything moves).
    private func tick(_ seconds: Double) {
        let advanced = lastTick >= 0 && seconds > lastTick + 0.01
        lastTick = seconds
        guard settled else { return }
        if !reportedFirstFrame, seconds > startAt + 0.2 {
            reportedFirstFrame = true
            delegate?.engineDidRenderFirstFrame(self)
        }
        if advanced, !buffering || reportedFirstFrame {
            buffering = false
            delegate?.engine(self, state: .playing)
        } else if !advanced, !buffering, reportedFirstFrame, !(engine?.isPlaying ?? false) {
            delegate?.engine(self, state: .paused)
        }
        pruneCues(before: seconds)
    }

    func play() {
        wantsPlay = true
        guard settled else { return }
        engine?.play()
    }

    func pause() {
        wantsPlay = false
        engine?.pause()
        atmos?.pause()   // at once, not on the next tick
        if settled, reportedFirstFrame { delegate?.engine(self, state: .paused) }
    }

    func seek(to time: Double, completion: @escaping (Bool) -> Void) {
        guard let e = engine else { completion(false); return }
        cues.removeAll()
        lastTick = -1
        e.seek(to: max(0, time))
        if wantsPlay, settled { e.play() }
        completion(true)
    }

    func select(audio: EngineTrack) {
        guard let i = Int32(audio.id) else { return }
        engine?.selectAudio(index: i)
        // A running passthrough restarts on the new track in its tick (or hands
        // the sound back when that track can't pass through); this covers the
        // other direction — from a track that couldn't, to one that can.
        if atmos == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let e = self.engine else { return }
                self.startAtmosIfEligible(resume: e.currentClockSeconds)
            }
        }
    }

    func select(subtitle: EngineTrack?) {
        cues.removeAll()
        engine?.selectSubtitle(subtitle.flatMap { Int32($0.id) })
    }

    func subtitleParts(at time: Double) -> [SubtitlePart] {
        cues.filter { $0.start <= time && time < $0.end }
    }

    func setContentMode(_ mode: UIView.ContentMode) {
        (engine?.videoView.layer as? AVSampleBufferDisplayLayer)?.videoGravity = mode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
    }

    func stop() {
        stopped = true
        // No un-mute: a renderer still holding queued audio would blip as it stops.
        stopAtmos(restoreEngineAudio: false)
        handshake?.cancel()
        handshake = nil
        engine?.stop()
        engine?.videoView.removeFromSuperview()
        engine = nil
        cues.removeAll()
    }

    /// The PiP window's mute. While Atmos owns the sound the engine stays muted
    /// (the AVPlayer is the voice), so only the AVPlayer side follows the toggle.
    func setUserMuted(_ muted: Bool) {
        userMuted = muted
        if atmosEngineMuted { atmos?.setMuted(muted) } else { engine?.setMuted(muted) }
    }

    // MARK: Atmos passthrough

    /// The route is HDMI (Atmos only exists as a bitstream to a receiver/TV).
    private static var routeIsHDMI: Bool {
        #if DEBUG
        // Simulator checks of the remux → loopback HLS → AVPlayer path.
        if ProcessInfo.processInfo.arguments.contains("-atmosAnyRoute") { return true }
        #endif
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .HDMI }
    }

    /// Start the AVPlayer audio path for a track the CONTAINER says is Atmos
    /// (an ordinary DD+ 5.1 doesn't pay for a second read of the source). The
    /// engine keeps its own audio until the AVPlayer is actually audible.
    private func startAtmosIfEligible(resume: Double) {
        guard config.atmosPassthrough, atmos == nil, !stopped, settled,
              atmosFailures < Self.atmosMaxFailures,
              let e = engine, e.rate == 1 || !e.isPlaying, let url = config.atmosSourceURL ?? sourceURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let path = e.audioPath
        guard path.passthrough, path.sourceSaysAtmos, ["eac3", "ac3"].contains(path.codec), Self.routeIsHDMI else { return }
        let passthrough = AtmosPassthrough()
        passthrough.onError = { [weak self, weak passthrough] message in
            guard let self, let passthrough, self.atmos === passthrough else { return }
            self.atmosFailed("passthrough failed: \(message)")
        }
        passthrough.onAudibleChange = { [weak self, weak passthrough] audible in
            guard let self, let passthrough, self.atmos === passthrough, audible, !self.atmosEngineMuted, let e = self.engine else { return }
            // The AVPlayer has the sound now: silence the sample renderer so the
            // two don't play over each other. Once per session.
            e.setMuted(true)
            self.atmosEngineMuted = true
            PlayerProbe.event("atmos", "passthrough AUDIBLE — AVPlayer owns the \(e.audioPath.codec) audio")
            self.delegate?.engineTracksChanged(self)
        }
        // Set BEFORE start: a synchronous failure reports through `onError`,
        // which only acts on the current session.
        atmos = passthrough
        atmosWaitingSince = nil
        atmosLastVideoClock = e.currentClockSeconds
        atmosClockSampledAt = Date()
        atmosClockAdvancing = false
        passthrough.start(inputURL: url.absoluteString, headers: sourceHeaders.isEmpty ? nil : sourceHeaders,
                          startAt: resume, trackIndex: e.currentAudioIndex)
        atmosTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.atmosTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        atmosTimer = timer
        PlayerProbe.event("atmos", String(format: "passthrough starting for %@ at %.1fs", path.codec, resume))
    }

    /// Audio follows the picture — one rule for every state, so pause, play,
    /// buffering and seeks need no forwarding of their own. The AUDIO is what
    /// moves, never the picture (the engine's clock is timed off its own muted
    /// renderer, so nudging it does not hold; the AVPlayer seeks exactly).
    private func atmosTick() {
        guard let passthrough = atmos, let e = engine else { return }
        guard e.rate == 1 || !e.isPlaying else {
            stopAtmos(restoreEngineAudio: true)
            return
        }
        // A track change re-demuxes the ENGINE only; the remux would play the old track.
        guard e.currentAudioIndex == passthrough.trackIndex else {
            restartAtmos(at: e.currentClockSeconds, reason: "audio track changed")
            return
        }
        // The audio instant that belongs with the frame on screen (positive
        // offset = voices later, as `setAudioDelay` means it on the engine).
        let video = e.currentClockSeconds
        let target = video - audioDelay
        passthrough.noteVideoPlayhead(target)
        #if DEBUG
        atmosTraceTick += 1
        if atmosTraceTick % 8 == 0 {
            PlayerProbe.event("atmos", String(format: "tick video=%.2f audio=%@ audible=%@ playing=%@ advancing=%@",
                                              video, passthrough.currentTime.map { String(format: "%.2f", $0) } ?? "-",
                                              passthrough.isAudible.probe, e.isPlaying.probe, atmosClockAdvancing.probe))
        }
        #endif
        // "Running" = the clock is MOVING; a starved engine keeps rate 1 with a still clock.
        let now = Date()
        if now.timeIntervalSince(atmosClockSampledAt) >= 0.2 {
            atmosClockAdvancing = video > atmosLastVideoClock + 0.05
            atmosLastVideoClock = video
            atmosClockSampledAt = now
        }
        guard e.isPlaying, atmosClockAdvancing else {
            passthrough.pause()
            atmosWaitingSince = nil
            return
        }
        if passthrough.isAudible {
            atmosWaitingSince = nil
            // Let a just-started AVPlayer settle, and rate-limit corrections
            // (each is a short gap in the sound).
            if let since = passthrough.audibleSince, now.timeIntervalSince(since) >= 1.5,
               now.timeIntervalSince(atmosLastResync) >= 5,
               let audio = passthrough.currentTime, abs(audio - target) > 0.25 {
                atmosLastResync = now
                // The AVPlayer lands behind wherever it's resumed by its own start-up
                // time (≈ 0.27 s on an A10X box), so re-seeking to the picture alone
                // never closed the gap — a resync, and an audible hiccup, every 5 s.
                // Learn that lag and resume that far ahead from now on.
                atmosLead = min(1.0, max(-0.5, atmosLead + (target - audio)))
                PlayerProbe.event("atmos", String(format: "resync: audio %.2f vs picture %.2f (lead now %.2fs)", audio, target, atmosLead))
                passthrough.pause()   // the next tick resumes it at the picture
            }
            return
        }
        switch passthrough.resume(at: target + atmosLead) {
        case .outOfRange:
            // Never audible and already out of range: a remux that can't keep up.
            if !passthrough.hasPlayed { atmosFailures += 1 }
            restartAtmos(at: video, reason: String(format: "%.1fs is outside the remuxed audio", target))
            return
        case .finished:
            atmosWaitingSince = nil
            return
        case .pending:
            break
        }
        // Picture running without the AVPlayer's sound: short once it has played
        // (the engine is muted — this is silence), long while a remux warms up.
        let since = atmosWaitingSince ?? now
        atmosWaitingSince = since
        let limit: TimeInterval = passthrough.hasPlayed ? 4 : 20
        if now.timeIntervalSince(since) > limit {
            atmosFailed(passthrough.hasPlayed ? "AVPlayer stalled for \(Int(limit))s" : "AVPlayer never started in \(Int(limit))s")
        }
    }

    /// A fresh remux at `seconds`. Not a failure: the old one doesn't hold that position or track.
    private func restartAtmos(at seconds: Double, reason: String) {
        PlayerProbe.event("atmos", String(format: "restarting at %.1fs — %@", seconds, reason))
        stopAtmos(restoreEngineAudio: true)
        startAtmosIfEligible(resume: seconds)
    }

    /// Give the sound back to the engine and count it.
    private func atmosFailed(_ reason: String) {
        atmosFailures += 1
        PlayerProbe.event("atmos", "\(reason) — restoring engine audio (failure \(atmosFailures)/\(Self.atmosMaxFailures))")
        stopAtmos(restoreEngineAudio: true)
    }

    private func stopAtmos(restoreEngineAudio: Bool) {
        atmosTimer?.invalidate()
        atmosTimer = nil
        atmos?.stop()
        atmos = nil
        atmosWaitingSince = nil
        if atmosEngineMuted {
            if restoreEngineAudio { engine?.setMuted(userMuted) }
            atmosEngineMuted = false
        }
    }

    // MARK: Embedded subtitles

    private func addCue(start: Double, end: Double, text: String?, image: UIImage?, origin: CGPoint, canvas: CGSize) {
        // A clear marker (PGS): end every cue still open at `start`.
        guard text != nil || image != nil else {
            for c in cues where c.end > start { c.end = start }
            return
        }
        // A new bitmap event replaces the one on screen (PGS has no overlap).
        if image != nil { for c in cues where c.image != nil && c.end > start { c.end = start } }
        let part = SubtitlePart(start, end, attributedString: text.map { NSAttributedString(string: $0) })
        part.image = image
        part.origin = origin
        part.canvasSize = canvas
        cues.append(part)
        if cues.count > 200 { cues.removeFirst(cues.count - 200) }
    }

    private func pruneCues(before time: Double) {
        cues.removeAll { $0.end < time - 30 }
    }
}
