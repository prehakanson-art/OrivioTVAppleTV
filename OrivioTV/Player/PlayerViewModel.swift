import SwiftUI
import AVFoundation
import KSPlayer

enum PlayerOverlay: Equatable {
    case none, controls, pauseInfo, audio, subtitles, episodes, sources, speed, engine, info
    /// Live TV: the channel list (mini guide).
    case channels
    case upNext, stillWatching, postPlay
    case error(String)

    /// "Transport visible" = controls, pauseInfo, audio, subtitles.
    var transportVisible: Bool { [.controls, .pauseInfo, .audio, .subtitles].contains(self) }
    var isPicker: Bool { [.episodes, .sources, .speed, .engine, .channels].contains(self) }
}

/// Coarse focus area the screen reports, so remote handling knows the context.
enum PlayerFocusArea: Equatable {
    case video, bar, glyphs, popover, skipIntro, sheet, picker, overlay
}

enum InfoTab: String, CaseIterable, Identifiable {
    case info = "Info", video = "Video", audio = "Audio", subtitles = "Subtitles"
    var id: String { rawValue }
}

struct ScrubState: Equatable {
    var target: Double
    var pausedByScrub: Bool
    var wheel = false
    var wheelAngle: Double = 0
    var lastInput = Date()
}

/// The player's brain. One instance per full-screen cover; advances episodes inside it.
@MainActor
final class PlayerViewModel: ObservableObject {
    // MARK: Now playing
    @Published var meta: MetaItem
    @Published var video: MetaVideo?
    @Published private(set) var entry: StreamEntry
    @Published var allEntries: [StreamEntry]
    private(set) var request: PlaybackRequest
    var onNowPlayingChanged: ((MetaItem, MetaVideo?) -> Void)?
    var onExit: (() -> Void)?

    // MARK: Engine
    private(set) var engine: PlaybackEngine?
    @Published private(set) var engineKind: EngineKind = .native
    @Published private(set) var engineState: EngineState = .preparing
    @Published private(set) var firstFrameShown = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedTime: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var showRebuffer = false
    @Published var loadingStatus = "Loading…"
    @Published private(set) var preparingProgress: Double?
    @Published var isSwitchingSource = false
    @Published private(set) var exitCover = false
    @Published private(set) var resyncCover = false

    // MARK: UI state
    @Published var overlay: PlayerOverlay = .none
    @Published private(set) var controlsSession = 0
    @Published var focusArea: PlayerFocusArea = .video
    @Published var infoTab: InfoTab = .info
    @Published var showWallClock = false
    @Published var scrub: ScrubState?
    @Published private(set) var nudgeDelta: Double?
    @Published private(set) var quickSeekHUD: Double?
    @Published private(set) var toast: String?
    @Published private(set) var introRange: ClosedRange<Double>?
    @Published private(set) var creditsStart: Double?
    @Published private(set) var introDismissed = false
    @Published var zoom: VideoScaling = .normal
    @Published var aspect: AspectChoice = .auto
    @Published var shift: VerticalShift = .none
    @Published private(set) var speed: Float = 1
    @Published private(set) var audioSync: Double = 0
    @Published var upNextRemaining: Double?
    @Published var upNextTotal: Double = 10
    @Published var nextVideo: MetaVideo?
    @Published var isFinished = false
    @Published private(set) var videoInfo = VideoFormatInfo()
    @Published private(set) var audioInfo = AudioFormatInfo()
    @Published private(set) var audioTracks: [EngineTrack] = []
    @Published private(set) var selectedAudioID: String?
    @Published var episodeList: [MetaVideo] = []
    @Published private(set) var cacheStatus: [String] = []
    @Published private(set) var pipActive = false

    let subtitles = SubtitleController()
    /// §7.19 scrub previews (coarse pass after the first frame, fine pass while scrubbing).
    let previews = ScrubPreviews()
    private let previewGate = PreviewGate()
    private var previewsStarted = false
    let decisions = PlaybackDecisionLog()
    let settings: PlayerSettingsStore
    private let stores = AppStores.shared

    // MARK: Session bookkeeping
    private var tickTimer: Timer?
    var hideTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stallSince: Date?
    private var rebufferTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var seekPlayWatch: Task<Void, Never>?
    private var failedEngines: Set<EngineKind> = []
    /// §7.18 hybrid disk cache: the duration was handed over for this load.
    private var cacheDurationNoted = false
    private var lastCacheSpansAt = Date.distantPast
    /// Disk-cached stretches as 0…1 fractions of the RUNTIME (calibrated from bytes).
    @Published private(set) var cacheSpans: [ClosedRange<Double>] = []
    /// The DV/Atmos header probe in flight; a newer load supersedes it by token.
    private var preflightTask: Task<Void, Never>?
    private var preflightToken: UUID?
    private var triedLinks: Set<String> = []
    private var sessionStart: Date = Date()
    private var sessionFloor: Double = 0
    private var pendingResume: Double?
    private var lastProgressSave = Date.distantPast
    private var lastTransientSave = Date()
    var autoAdvanceCount = 0
    var shuffleOrder: [String] = []
    var lastMenuAt = Date.distantPast
    var lastPlayPause: (Date, String)?
    var playPauseStamps: [Date] = []
    private var pausedAt: Date?
    private var suspendedAt: Date?
    private var scrobbleStarted = false
    var upNextCancelled = false
    var advancing = false
    var swipeRun: (count: Int, last: Date)?
    var lastPanAt = Date.distantPast
    private var openedAt: Date?

    /// The screen moves focus here when set (then clears it).
    @Published var requestedFocus: PlayerFocusArea?
    /// Where a full-screen picker returns to on Menu.
    var returnOverlay: PlayerOverlay?
    /// A full-screen picker opened from inside the info sheet.
    @Published var infoPickerOpen = false
    var alternativesSearch: StreamSearch?
    /// The sources picker lists the *next* episode's links (Up Next → Select Source).
    @Published var pickingNextSource = false
    @Published var nextEntries: [StreamEntry] = []
    var nextSourceSearch: StreamSearch?
    /// The error came from an episode advance — Try Again retries the advance.
    var retryAdvance = false
    private(set) var started = false
    /// The player cover is on screen (a disappear only tears down if it stays gone).
    var screenVisible = false
    /// Live TV: the channel-change banner, and the pending Up/Down target.
    @Published var liveBanner: LiveBanner?
    var zapTargetIndex: Int?
    var zapTask: Task<Void, Never>?
    var bannerTask: Task<Void, Never>?
    private var pipStorage: PiPCoordinator?
    /// Built on first use (most sessions never open PiP).
    private var pip: PiPCoordinator {
        if let p = pipStorage { return p }
        let p = PiPCoordinator(vm: self)
        pipStorage = p
        return p
    }
    /// For per-frame questions that must not build a coordinator just to answer no.
    private var pipIfCreated: PiPCoordinator? { pipStorage }
    var currentRequest: PlaybackRequest { request }

    /// Live TV channel changes / Start Over switch between a live stream and a recording.
    func setStreamKind(isLive: Bool, forceDemuxer: Bool) {
        request.isLive = isLive
        request.forceDemuxer = forceDemuxer
    }

    init(request: PlaybackRequest) {
        self.request = request
        meta = request.meta
        video = request.video
        entry = request.entry
        allEntries = request.allEntries
        settings = AppStores.shared.player
        zoom = AppStores.shared.player.value.videoScaling
        pendingResume = request.resumePosition
        sessionFloor = request.resumePosition ?? 0
        if request.shuffle { shuffleOrder = Self.makeShuffle(meta: request.meta, current: request.video) }
        subtitles.delay = AppStores.shared.player.value.subtitleDelay
        let mem = PlaybackMemory.get(titleKey)
        speed = mem.speed
        audioSync = mem.audioSync
        DisplayModeManager.shared.onLog = { [weak self] line in self?.decisions.log("display", "", line) }
    }

    var titleKey: String { video?.id ?? meta.id }
    var isLive: Bool { request.isLive || meta.type == "tv" || meta.type == "channel" }
    /// Sources shorter than 180 s are add-on notice clips ("link expired" videos).
    var isNoticeClip: Bool { duration > 0 && duration < 180 && !isLive }
    /// A catch-up recording from the TV guide: seekable, but not a title to track.
    var isRecording: Bool { meta.type == "recording" }
    var displayTime: Double { scrub?.target ?? (nudgeDelta.map { currentTime + $0 } ?? currentTime) }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        DisplayModeManager.shared.beginPlayback()
        sessionStart = Date()
        loadingStatus = (pendingResume ?? 0) > 1 ? "Resuming…" : "Loading…"
        openWithPreflight(url: request.url, headers: request.headers, startAt: pendingResume ?? 0)
        startTick()
        Task { await subtitles.loadAddonSubtitles(meta: meta, video: video, filename: entry.stream.behaviorHints?.filename) }
        computeNextEpisode()
        loadEpisodeList()
        onNowPlayingChanged?(meta, video)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// Engine choice (§7.2). Auto: AVPlayer for MP4/HLS, FFmpeg for MKV & friends.
    func chooseEngine() -> EngineKind {
        let pref = settings.value.engine
        let ext = containerExtension
        if request.forceDemuxer {
            decisions.log("engine", "FFmpeg", "demuxer-only stream (forced)")
            return .ffmpeg
        }
        switch pref {
        case .native: decisions.log("engine", "Native", "preference"); return .native
        case .ffmpeg: decisions.log("engine", "FFmpeg", "preference"); return .ffmpeg
        case .vlc: decisions.log("engine", "VLC", "preference"); return .vlc
        // `.aether` is a classic-player (VOD) engine; live TV routes like Auto.
        case .auto, .aether, .external: break
        }
        if ["mp4", "m4v", "mov", "m3u8"].contains(ext) {
            decisions.log("engine", "Native", "container .\(ext)")
            return .native
        }
        decisions.log("engine", "FFmpeg", ext.isEmpty ? "unknown container" : "container .\(ext)")
        return .ffmpeg
    }

    var containerExtension: String {
        let candidates: [String?] = [entry.stream.behaviorHints?.filename, request.url.lastPathComponent, request.url.path]
        for c in candidates.compactMap({ $0 }) {
            let e = (c as NSString).pathExtension.lowercased()
            if ["mp4", "m4v", "mov", "m3u8", "mkv", "avi", "ts", "m2ts", "flv", "webm", "wmv", "mpg"].contains(e) { return e }
        }
        if request.url.absoluteString.contains(".m3u8") { return "m3u8" }
        return ""
    }

    /// DV/Atmos preflight hints (§7.2): nil = don't probe; otherwise whether the
    /// hint is about audio only (shorter probe budget, stricter acceptance).
    func dvPreflightHint() -> (audioOnly: Bool, reason: String)? {
        let pref = settings.value.engine
        guard pref == .auto || pref == .aether || pref == .ffmpeg, request.url.scheme?.hasPrefix("http") == true else { return nil }
        guard settings.value.playbackMode != .compatibility, !failedEngines.contains(.dvDirect), !isLive else { return nil }
        guard !["mp4", "m4v", "mov", "m3u8"].contains(containerExtension), !request.forceDemuxer else { return nil }
        let footprint = Self.memoryFootprintMB()
        guard footprint < 850 else { decisions.log("preflight", "skip", "memory \(footprint) MB"); return nil }
        guard !DolbyMemory.isDeclined(meta.id) else { return nil }
        let text = entry.stream.allText.lowercased()
        let video = text.range(of: #"\b(dv|dovi|dolby)\b"#, options: .regularExpression) != nil && DisplayModeManager.shared.supportsDolbyVision
        let audio = text.range(of: #"(atmos(?!phere)|joc|ddp|dd\+|e-?ac-?3|ec-?3|ac-?3|true-?hd)"#, options: .regularExpression) != nil
        let remembered = DolbyMemory.isCapable(meta.id)
        if video { return (false, "video DV tag") }
        if audio { return (true, "Dolby audio tag") }
        if remembered { return (true, "remembered Dolby title") }
        return nil
    }

    /// Opens the right engine, running the DV/Atmos preflight first when hinted.
    private func openWithPreflight(url: URL, headers: [String: String], startAt: Double) {
        guard let hint = dvPreflightHint() else {
            openEngine(chooseEngine(), url: url, headers: headers, startAt: startAt)
            return
        }
        decisions.log("preflight", "probe", hint.reason)
        preflightTask?.cancel()
        let token = UUID()
        preflightToken = token
        preflightTask = Task { [weak self] in
            let probeURL = self?.cachedPlaybackURL(url, headers: headers) ?? url
            let probe = await StreamProbe.inspect(url: probeURL.absoluteString, headers: headers, needsStyledASS: false,
                                                  needsHDR10Plus: true, needsDolbyVision: true,
                                                  timeoutSeconds: hint.audioOnly ? 3 : 5)
            guard let self, !Task.isCancelled, self.preflightToken == token, self.request.url == url else { return }
            if let config = await self.directEngineConfig(probe: probe, audioOnly: hint.audioOnly) {
                guard self.preflightToken == token else { return }
                self.openEngine(.dvDirect, url: url, headers: headers, startAt: startAt, dvConfig: config)
            } else {
                self.openEngine(self.chooseEngine(), url: url, headers: headers, startAt: startAt)
            }
        }
    }

    /// The direct-engine decision from the header probe (the old app's DV-first rules).
    private func directEngineConfig(probe: StreamProbeResult, audioOnly: Bool) async -> DVDirectConfig? {
        let profile = probe.dvProfile ?? 0
        let fidelity = settings.value.playbackMode == .maximumFidelity
        // P7 → 8.1 conversion everywhere but the A8: the base layer alone plays
        // genuinely dark (P7 carries brightness in the enhancement layer).
        let p7ok = fidelity || !PerformanceProfile.isLowPower
        var dvOK = profile == 0 || profile == 5 || profile == 8 || (profile == 7 && p7ok)
        // P7 without conversion: play the HDR10 base layer when there is a Dolby
        // bitstream to win; otherwise this would be a video change for nothing.
        var baseLayerForAudio = false
        if profile == 7, !p7ok, probe.hasBitstreamableDolby {
            dvOK = true
            baseLayerForAudio = true
        }
        // A DV feed never goes to a panel with no DV mode.
        if profile > 0, !DisplayModeManager.shared.supportsDolbyVision, !baseLayerForAudio {
            dvOK = false
            decisions.log("preflight", "declined", "DV profile \(profile) but the display has no DV mode")
        }
        // Entered for audio alone with nothing tvOS can bitstream: FFmpeg decodes identically.
        if audioOnly, !probe.hasBitstreamableDolby {
            dvOK = false
            decisions.log("preflight", "declined", "no E-AC-3/AC-3 track to bitstream")
        }
        // H.264 rides this engine only for a Dolby bitstream.
        let videoUsable = probe.hasHEVC || (probe.hasAVC && probe.hasBitstreamableDolby)
        if audioOnly, probe.durationSeconds > 0, !videoUsable { DolbyMemory.markDeclined(meta.id) }
        // ≥ 180 s: a notice clip must not take the direct engine (its failover is a tier
        // drop on the SAME source; the normal load's duration check moves to another link).
        guard videoUsable, dvOK, probe.hasEligibleAudio, probe.durationSeconds >= 180 else {
            decisions.log("preflight", "normal load", "profile=\(probe.dvProfile.map(String.init) ?? "none") HEVC=\(probe.hasHEVC) audio=\(probe.hasEligibleAudio) duration=\(Int(probe.durationSeconds))s")
            return nil
        }
        // Configure + activate the session BEFORE reading the route: an inactive
        // session reports 2 channels and would fold an Atmos rig to stereo.
        AudioOutputCapability.configureForMoviePlayback()
        await Task.detached(priority: .userInitiated) { try? AVAudioSession.sharedInstance().setActive(true) }.value
        let memory = PlaybackMemory.get(titleKey)
        var config = DVDirectConfig()
        config.preferredAudioLanguage = settings.value.preferredAudioLanguage.isEmpty ? (memory.audioLanguage ?? "") : settings.value.preferredAudioLanguage
        config.convertProfile7 = p7ok
        config.downmixToStereo = !AudioOutputCapability.supportsMultichannel
        config.forceHDR10 = baseLayerForAudio
        config.streamNameSaysAtmos = entry.stream.allText.range(of: #"atmos(?!phere)"#, options: [.regularExpression, .caseInsensitive]) != nil
        config.probe = probe
        config.atmosPassthrough = settings.value.atmosPassthrough
        decisions.log("engine", EngineKind.dvDirect.label,
                      profile > 0 ? "Dolby Vision profile \(profile)\(profile == 7 ? (baseLayerForAudio ? " (base layer)" : " → 8.1") : "")" : (probe.hasBitstreamableDolby ? "Dolby audio bitstream" : "HEVC"))
        return config
    }

    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    private func openEngine(_ kind: EngineKind, url: URL, headers: [String: String], startAt: Double, dvConfig: DVDirectConfig? = nil) {
        preflightTask?.cancel()
        preflightToken = nil
        engine?.stop()
        let e: PlaybackEngine
        switch kind {
        case .vlc: e = VLCEngine()
        case .dvDirect:
            if var dvConfig {
                dvConfig.atmosSourceURL = url
                e = DVDirectEngine(config: dvConfig)
            } else {
                e = KSEngine(kind: .ffmpeg)
            }
        case .native, .ffmpeg: e = KSEngine(kind: kind)
        }
        e.delegate = self
        engine = e
        engineKind = e.kind
        subtitles.engine = e
        subtitles.reset()
        firstFrameShown = false
        engineState = .preparing
        openedAt = nil
        cacheDurationNoted = false
        e.start(url: cachedPlaybackURL(url, headers: headers), headers: headers, startAt: startAt)
        e.audioDelay = audioSync
        armWatchdog()
        objectWillChange.send()
    }

    // MARK: - Tick

    private func startTick() {
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .default)
        tickTimer = t
    }

    private func tick() {
        guard let e = engine else { return }
        let t = e.currentTime
        if abs(t - currentTime) > 0.05 { currentTime = t }
        let d = e.duration
        if d > 0, abs(d - duration) > 0.5 { duration = d }
        bufferedTime = e.bufferedTime
        if t > sessionFloor, firstFrameShown { sessionFloor = max(sessionFloor, min(t, duration)) }
        subtitles.tick(time: t)
        if firstFrameShown { subtitles.autoPickIfNeeded(settings: settings.value) }
        checkIntroAndCredits(t)
        checkUpNextTrigger(t)
        checkStall()
        if let s = scrub, !s.wheel, Date().timeIntervalSince(s.lastInput) > 6 { cancelScrub() }
        // Previews stand aside while the demuxer read-ahead is short (8 s; the passes poll this).
        previewGate.set(isPaused || bufferedTime - t >= 8)
        if !cacheDurationNoted, duration > 0, !isLive {
            cacheDurationNoted = true
            MediaCacheServer.shared.noteDuration(duration)
        }
        if pipActive { pipIfCreated?.updateBridge(self) }
        if Date().timeIntervalSince(lastCacheSpansAt) >= 1 {
            lastCacheSpansAt = Date()
            refreshCacheSpans()
        }
        #if DEBUG
        if CommandLine.arguments.contains("-cacheTrace"), Int(Date().timeIntervalSince1970 * 4) % 20 == 0 {
            let lines = MediaCacheServer.shared.probeLines
            DebugLog.write("CACHETRACE \(lines.prefix(3).joined(separator: " | "))")
        }
        #endif
        if firstFrameShown, !previewsStarted, duration > 0 { startPreviews() }
        if firstFrameShown, !isPaused, Date().timeIntervalSince(lastTransientSave) > 20 {
            lastTransientSave = Date()
            saveProgress(transient: true)
        }
        if overlay == .info, Int(Date().timeIntervalSince1970 * 4) % 4 == 0 { refreshInfo() }
    }

    func refreshInfo() {
        guard let e = engine else { return }
        videoInfo = e.videoInfo
        audioInfo = e.audioInfo
        audioTracks = e.audioTracks
        selectedAudioID = e.selectedAudio?.id
        var status: [String] = []
        if e.downloadedBytes > 0 { status.append("Downloaded: \(StreamEntry.formatBytes(e.downloadedBytes))") }
        let ahead = max(0, e.bufferedTime - e.currentTime)
        status.append("Engine buffer: \(Int(ahead))s")
        status.append(settings.value.hybridCache ? "Cache: off (direct stream)" : "Cache: disabled in Settings")
        cacheStatus = status
    }

    // MARK: - Watchdogs

    /// Load 30 s (no ready) · first frame 25 s after the container opened → failover.
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !(self.engine?.isReady ?? false) {
                self.decisions.log("watchdog", "load", "no ready after 30 s")
                self.handleFailure("The stream took too long to open.")
            }
        }
    }

    private func armFirstFrameWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled, !self.firstFrameShown, !self.isPaused else { return }
            self.decisions.log("watchdog", "first frame", "none 25 s after open")
            self.handleFailure("No picture after the stream opened.")
        }
    }

    /// Stall 20 s (re-arms after pause/failover). A paused viewer is not a stall.
    private func checkStall() {
        guard firstFrameShown, !isPaused, engineState == .buffering else { stallSince = nil; return }
        if stallSince == nil { stallSince = Date() }
        if let s = stallSince, Date().timeIntervalSince(s) > 20 {
            stallSince = nil
            decisions.log("watchdog", "stall", "buffering 20 s")
            handleFailure("The stream stalled.")
        }
    }

    // MARK: - Failure / failover

    private func handleFailure(_ message: String) {
        guard !advancing else { return }
        saveProgress(transient: false)
        let resumeAt = max(currentTime, sessionFloor, pendingResume ?? 0)
        // 1. Engine fallback for the same link: native ↔ FFmpeg, then VLC.
        failedEngines.insert(engineKind)
        let order: [EngineKind]
        switch engineKind {
        case .native: order = [.ffmpeg, .vlc]
        case .ffmpeg: order = [.native, .vlc]
        case .dvDirect: order = [.ffmpeg, .vlc]
        case .vlc: order = []
        }
        if [.auto, .aether, .external].contains(settings.value.engine),
           let next = order.first(where: { !failedEngines.contains($0) && !(($0 == .native) && !["mp4", "m4v", "mov", "m3u8", ""].contains(containerExtension)) }) {
            decisions.log("fallback", next.label, "\(engineKind.label) failed: \(message)")
            loadingStatus = "Trying \(next.label)…"
            showToast("Switching to \(next.label)")
            openEngine(next, url: request.url, headers: request.headers, startAt: resumeAt)
            return
        }
        // 2. Link failover: same add-on, then same resolution, uncached last.
        failOverToNextLink(message, at: resumeAt)
    }

    /// Move the title to the next ranked link (same add-on, then same
    /// resolution, uncached last); the error card when none is left.
    func failOverToNextLink(_ message: String, at position: Double? = nil) {
        guard !advancing else { return }
        let resumeAt = position ?? max(currentTime, sessionFloor, pendingResume ?? 0)
        triedLinks.insert(entry.rejectionKey)
        let candidates = AutoSelect.rankedCandidates(after: entry, in: allEntries, titleKey: titleKey).filter { !triedLinks.contains($0.rejectionKey) }
        if let next = candidates.first, triedLinks.count < 6 {
            decisions.log("failover", next.sourceAddonName, "link failed: \(message)")
            switchSource(to: next, at: resumeAt, label: "Trying another source…")
            return
        }
        overlay = .error(message)
    }

    func switchSource(to e: StreamEntry, at position: Double? = nil, label: String = "Switching source…") {
        let resumeAt = position ?? max(currentTime, 0)
        isSwitchingSource = true
        loadingStatus = label
        Task {
            do {
                let resolved = try await StreamResolver.resolve(e, video: video, timeout: 30) { [weak self] s in self?.loadingStatus = s }
                applyVerdict()
                entry = e
                request.url = resolved.url
                request.headers = resolved.headers
                failedEngines = []
                pendingResume = resumeAt
                isSwitchingSource = false
                overlay = .none
                sessionStart = Date()
                openWithPreflight(url: resolved.url, headers: resolved.headers, startAt: resumeAt)
                stores.progress.rememberLink(LastLink(stream: e.stream, addonName: e.addonName, rejectionKey: e.rejectionKey, savedAt: Date()),
                                             signature: e.signature, for: titleKey)
            } catch {
                isSwitchingSource = false
                triedLinks.insert(e.rejectionKey)
                handleFailure(error.localizedDescription)
            }
        }
    }

    func setNowPlaying(video newVideo: MetaVideo?, entry e: StreamEntry, entries: [StreamEntry], url: URL, headers: [String: String]) {
        video = newVideo
        entry = e
        allEntries = entries
        request.url = url
        request.headers = headers
        request.video = newVideo
        request.entry = e
        previews.stop()
        previewsStarted = false
        introRange = nil
        creditsStart = nil
        introDismissed = false
        isFinished = false
        triedLinks = []
        failedEngines = []
        sessionStart = Date()
        sessionFloor = 0
        let mem = PlaybackMemory.get(titleKey)
        speed = mem.speed
        audioSync = mem.audioSync
        loadEpisodeList()
        Task { await subtitles.loadAddonSubtitles(meta: meta, video: newVideo, filename: e.stream.behaviorHints?.filename) }
    }

    /// Reopens the engine for the current request (episode advance keeps the display pin).
    func reopen(startAt: Double) {
        pendingResume = startAt > 1 ? startAt : nil
        sessionFloor = startAt
        loadingStatus = startAt > 1 ? "Resuming…" : "Loading…"
        openEngine(chooseEngine(), url: request.url, headers: request.headers, startAt: startAt)
    }

    func retry() {
        overlay = .none
        if retryAdvance {
            retryAdvance = false
            playNext(auto: false)
            return
        }
        failedEngines = []
        openEngine(chooseEngine(), url: request.url, headers: request.headers, startAt: max(currentTime, sessionFloor))
    }

    func switchEngine(_ kind: EngineKind) {
        decisions.log("engine", kind.label, "chosen in the player")
        let at = currentTime
        overlay = .none
        openEngine(kind, url: request.url, headers: request.headers, startAt: at)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let e = engine else { return }
        if isFinished { replay(); return }
        if isPaused { resume() } else {
            e.pause()
            isPaused = true
            pausedAt = Date()
            saveProgress(transient: false)
            scrobble("pause")
            // Pausing raises the transport and it stays.
            raiseTransport()
        }
    }

    func resume() {
        guard let e = engine else { return }
        let longIdle = pausedAt.map { Date().timeIntervalSince($0) > 300 } ?? false
        let suspended = suspendedAt != nil
        isPaused = false
        pausedAt = nil
        if (longIdle || suspended), e.isReady, !isLive {
            // Stale socket: reconnect-rewind (seek back 1 s with autoplay).
            suspendedAt = nil
            decisions.log("resume", "reconnect-rewind", suspended ? "after suspension" : "after long idle")
            seek(to: max(0, currentTime - 1), keepPaused: false)
        } else {
            e.play()
        }
        scrobble("start")
        // The paused-info card belongs to the pause: back to the plain transport,
        // which then auto-hides (auto-hide only ever clears `.controls`).
        if overlay == .pauseInfo { overlay = .controls }
        scheduleAutoHide()
    }

    /// Every seek keeps the transport state (a skip while paused stays paused).
    /// Never `play()` inside a seek: a seek-play watchdog starts the picture if it didn't move.
    func seek(to time: Double, keepPaused: Bool? = nil) {
        guard let e = engine else { return }
        let target = max(0, duration > 0 ? min(time, duration - 1) : time)
        nudgeTask?.cancel()
        nudgeDelta = nil
        if target < currentTime { sessionFloor = min(sessionFloor, target) }
        if let r = introRange, target < r.lowerBound { introDismissed = false }
        let stayPaused = keepPaused ?? isPaused
        e.seek(to: target) { [weak self] _ in
            guard let self else { return }
            if stayPaused { self.engine?.pause() }
            self.armSeekPlayWatch(expectPlaying: !stayPaused, from: target)
        }
        currentTime = target
    }

    private func armSeekPlayWatch(expectPlaying: Bool, from: Double) {
        seekPlayWatch?.cancel()
        guard expectPlaying else { return }
        seekPlayWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.isPaused, let e = self.engine else { return }
            if abs(e.currentTime - from) < 0.2, !e.isPlaying {
                self.decisions.log("seek", "watchdog", "picture didn't move — play()")
                e.play()
            }
        }
    }

    /// Skips accumulate: the first commits immediately when `immediate`, a run on a debounce.
    func nudge(_ seconds: Double, debounce: TimeInterval, immediate: Bool = false, hud: Bool) {
        if immediate, nudgeDelta == nil {
            seek(to: currentTime + seconds)
            if hud { flashQuickSeek(seconds) }
            return
        }
        nudgeDelta = (nudgeDelta ?? 0) + seconds
        if hud { quickSeekHUD = nudgeDelta }
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard let self, !Task.isCancelled, let d = self.nudgeDelta else { return }
            let target = self.currentTime + d
            self.nudgeDelta = nil
            self.seek(to: target)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.nudgeDelta == nil { self.quickSeekHUD = nil }
        }
    }

    private func flashQuickSeek(_ s: Double) {
        quickSeekHUD = s
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if nudgeDelta == nil { quickSeekHUD = nil }
        }
    }

    func setSpeed(_ s: Float) {
        speed = s
        engine?.rate = s
        PlaybackMemory.update(titleKey) { $0.speed = s }
    }

    func setAudioSync(_ v: Double) {
        audioSync = v
        engine?.audioDelay = v
        PlaybackMemory.update(titleKey) { $0.audioSync = v }
    }

    func selectAudio(_ t: EngineTrack) {
        engine?.select(audio: t)
        selectedAudioID = t.id
        PlaybackMemory.update(titleKey) { $0.audioLanguage = Languages.normalize(t.language) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshInfo() }
    }

    func selectSubtitle(_ c: SubtitleChoice) {
        subtitles.select(c, settings: settings.value)
        PlaybackMemory.update(titleKey) { $0.subtitleLanguage = Languages.normalize(c.language) }
    }

    /// Settings language always wins; a per-title remembered pick is only a fallback.
    private func applyAudioLanguagePolicy() {
        guard let e = engine else { return }
        let tracks = e.audioTracks
        guard tracks.count > 1 else { return }
        let pref = settings.value.preferredAudioLanguage
        let inPref = tracks.filter { Languages.matches($0.language, pref) }
        let remembered = PlaybackMemory.get(titleKey).audioLanguage
        let pool = !inPref.isEmpty ? inPref : (remembered.map { r in tracks.filter { Languages.matches($0.language, r) } } ?? [])
        guard !pool.isEmpty else { return }
        // E-AC-3 +60, AC-3 +5 (multichannel only), so a remux's E-AC-3 JOC beats its TrueHD.
        let best = pool.max { score($0) < score($1) }!
        if best.id != e.selectedAudio?.id {
            decisions.log("audio", best.displayName, !inPref.isEmpty ? "Settings language" : "remembered for this title")
            e.select(audio: best)
        }
    }

    private func score(_ t: EngineTrack) -> Int {
        var s = (t.channels ?? 2) * 2
        if t.codec == "E-AC-3" { s += 60 }
        if t.codec == "AC-3", (t.channels ?? 2) > 2 { s += 5 }
        if t.isDefault { s += 3 }
        return s
    }

    // MARK: - Chrome

    func raiseTransport() {
        let wasVisible = overlay.transportVisible
        if !wasVisible { controlsSession += 1 }
        overlay = isPaused ? .pauseInfo : .controls
        scheduleAutoHide()
    }

    func hideTransport() {
        hideTask?.cancel()
        if overlay.transportVisible { overlay = .none }
    }

    /// Auto-hides after 5 s while playing; never while paused.
    func scheduleAutoHide() {
        hideTask?.cancel()
        guard !isPaused else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, !self.isPaused, self.scrub == nil else { return }
            if self.overlay == .controls { self.overlay = .none }
        }
    }

    func noteInteraction() {
        if overlay.transportVisible { scheduleAutoHide() }
    }

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast == s { toast = nil }
        }
    }

    // MARK: - Scrub

    func beginScrub() {
        guard duration > 0, !isLive else { return }
        let paused = !isPaused
        if paused { engine?.pause() }
        scrub = ScrubState(target: currentTime, pausedByScrub: paused)
        hideTask?.cancel()
        if previewsStarted { previews.refine(around: currentTime) }
    }

    // MARK: - Hybrid disk cache (§7.18)

    /// Direct http(s) files play through the localhost caching proxy, which
    /// downloads the film to disk at line speed and serves seeks from it. Fails
    /// open: the proxy answers 307 to the origin whenever it can't help, and
    /// `beginSession` itself declines HLS and anything non-http.
    func cachedPlaybackURL(_ origin: URL, headers: [String: String]) -> URL {
        guard settings.value.hybridCache, !isLive, !request.forceDemuxer,
              ["http", "https"].contains(origin.scheme?.lowercased() ?? "") else { return origin }
        guard let proxied = MediaCacheServer.shared.beginSession(origin: origin, headers: headers.isEmpty ? nil : headers) else {
            decisions.log("cache", "declined", "HLS, non-http, or the listener is unavailable — direct playback")
            return origin
        }
        // An origin that answers an HTTP error to every range request is the
        // wrong KIND of link (a cast endpoint dressed as a file): move this film
        // to another source rather than leave it uncacheable and unseekable.
        let key = entry.rejectionKey
        MediaCacheServer.shared.onOriginRefusedRanges = { [weak self] note in
            guard let self, self.entry.rejectionKey == key else { return }
            self.decisions.log("cache", "source refuses ranges", note)
            self.failOverToNextLink("This source refuses byte ranges — no caching or seeking.")
        }
        return proxied
    }

    /// The disk-only preview lane, when the film around `t` is already cached.
    private func cacheLaneURL(covering t: Double) -> URL? {
        let cache = MediaCacheServer.shared
        guard cache.hasLiveSession, let lane = cache.thumbnailURL, duration > 0 else { return nil }
        let f = t / duration
        return cacheSpans.contains { $0.contains(f) } ? lane : nil
    }

    /// Cached byte spans → runtime fractions, calibrated piecewise through the
    /// engine's read head (the one byte offset whose playback time is known);
    /// bytes and time disagree by minutes on a variable-bitrate file.
    private func refreshCacheSpans() {
        let cache = MediaCacheServer.shared
        guard !isLive, duration > 0, cache.hasLiveSession else {
            if !cacheSpans.isEmpty { cacheSpans = [] }
            return
        }
        let (spans, reader) = cache.coveredFractionsAndReader
        let readerTime = min(max(bufferedTime / duration, 0), 1)
        func toTime(_ b: Double) -> Double {
            guard let rb = reader, rb > 0.001, rb < 0.999, readerTime > 0.001, readerTime < 0.999 else { return b }
            return b <= rb ? b * readerTime / rb : readerTime + (b - rb) * (1 - readerTime) / (1 - rb)
        }
        let mapped = spans.map { min(toTime($0.start), 1)...min(toTime($0.end), 1) }.filter { $0.upperBound > $0.lowerBound }
        if mapped != cacheSpans { cacheSpans = mapped }
    }

    private func startPreviews() {
        previewsStarted = true
        guard settings.value.scrubPreviews, ScrubPreviews.eligible(url: request.url, isLive: isLive) else { return }
        let gate = previewGate
        previews.playbackHealthy = { gate.value }
        previews.cacheLane = { [weak self] t in self?.cacheLaneURL(covering: t) }
        previews.start(url: request.url, headers: request.headers, duration: duration)
    }

    /// Re-centres the fine pass as the target travels (it ignores moves under 20 s).
    private func refinePreviews() {
        guard previewsStarted, let t = scrub?.target else { return }
        previews.refine(around: t)
    }

    func scrubPan(dx: CGFloat) {
        guard var s = scrub, duration > 0 else { return }
        // 4800 points across the whole film, min 0.25 s/point.
        let perPoint = max(duration / 4800, 0.25)
        s.target = max(0, min(duration, s.target + Double(dx) * perPoint))
        s.lastInput = Date()
        scrub = s
        lastPanAt = Date()
        refinePreviews()
    }

    func scrubWheel(angleDelta: Double) {
        guard var s = scrub else { return }
        // 24 s per revolution.
        s.target = max(0, min(duration, s.target + angleDelta / (2 * .pi) * 24))
        s.wheel = true
        s.wheelAngle += angleDelta
        s.lastInput = Date()
        scrub = s
        refinePreviews()
    }

    func endWheel() {
        scrub?.wheel = false
    }

    func scrubJump(_ dir: Int) {
        guard var s = scrub else { return }
        // A rim click at the end of a drag commits instead.
        if Date().timeIntervalSince(lastPanAt) < 0.35 { commitScrub(); return }
        s.target = max(0, min(duration, s.target + Double(dir * settings.value.scrubberJump)))
        s.lastInput = Date()
        scrub = s
        refinePreviews()
    }

    func commitScrub() {
        guard let s = scrub else { return }
        scrub = nil
        previews.endScrub()
        if s.pausedByScrub || isPaused { isPaused = false }
        seek(to: s.target, keepPaused: false)
        engine?.play()
        raiseTransport()
    }

    func cancelScrub() {
        guard let s = scrub else { return }
        scrub = nil
        previews.endScrub()
        if s.pausedByScrub {
            engine?.play()
            isPaused = false
            scheduleAutoHide()
        } else {
            raiseTransport()
        }
    }

    // MARK: - Skip intro / credits

    private func checkIntroAndCredits(_ t: Double) {
        guard firstFrameShown, let r = introRange else { return }
        if r.contains(t), !introDismissed, settings.value.autoSkipIntros {
            introDismissed = true
            seek(to: r.upperBound)
            showToast("Skipped intro")
        }
    }

    var showsSkipIntro: Bool {
        guard settings.value.skipIntroButton, let r = introRange, !introDismissed else { return false }
        return r.contains(currentTime)
    }

    func skipIntro() {
        guard let r = introRange else { return }
        introDismissed = true
        seek(to: r.upperBound)
        showToast("Skipped intro")
    }

    private func detectChapters() {
        guard let e = engine, duration > 0 else { return }
        let chapters = e.chapters
        let introWords = ["intro", "opening", "recap", "prologue", "cold open", "avant", "teaser"]
        if let c = chapters.first(where: { c in
            c.start < duration / 2 && (["op", "ncop", "opening", "intro"].contains(c.title.lowercased().trimmingCharacters(in: .whitespaces))
                || introWords.contains { c.title.lowercased().contains($0) })
        }) {
            introRange = c.start...max(c.start + 1, c.end)
            decisions.log("intro", "chapter", c.title)
        }
        let creditWords = ["credit", "outro", "closing", "ending", "end", "ed"]
        if let c = chapters.first(where: { c in
            c.start > duration * 0.6 && creditWords.contains { w in
                let t = c.title.lowercased()
                return t == w || t.contains(w == "end" || w == "ed" ? "\(w) " : w) || t.hasPrefix(w)
            }
        }) {
            creditsStart = c.start
        }
        if introRange == nil, settings.value.aniSkip, meta.genres.contains(where: { $0.lowercased().contains("anim") }) {
            Task {
                if let iv = await IntroService.intervals(meta: meta, video: video, duration: duration) {
                    if introRange == nil, let i = iv.intro { introRange = i }
                    if creditsStart == nil, let o = iv.outro { creditsStart = o.lowerBound }
                }
            }
        }
    }

    // MARK: - Progress, verdicts, scrobble

    func saveProgress(transient: Bool) {
        guard !isLive, !isRecording, firstFrameShown, duration > 0, !isNoticeClip else { return }
        let position = max(currentTime, pendingResume ?? 0, min(sessionFloor, duration))
        guard position > 5 else { return }
        var p = WatchProgress(id: titleKey, metaID: meta.id, type: meta.type, videoID: video?.id, season: video?.season,
                              episode: video?.episode, position: position, duration: duration, updatedAt: Date(),
                              name: meta.name, poster: meta.poster, background: meta.background, logo: meta.logo,
                              episodeTitle: video?.title, episodeThumbnail: video?.thumbnail)
        if let (link, sig) = stores.progress.takePendingLink(for: titleKey) { p.lastLink = link; p.signature = sig }
        p.signature = p.signature ?? entry.signature
        stores.progress.record(p, transient: transient)
        // ≥ 95 % = finished → mark watched, remove from CW.
        if p.isFinished, !stores.watched.isWatched(titleKey) {
            stores.watched.markWatched(meta: meta, video: video)
        }
        lastProgressSave = Date()
    }

    /// A link watched ≥ 5 min is kept; < 5 min is rejected for 8 h for that title.
    func applyVerdict() {
        guard firstFrameShown, !isLive else { return }
        let watchedFor = Date().timeIntervalSince(sessionStart)
        if watchedFor < 300 && currentTime < duration * 0.9 {
            RejectedLinks.reject(entry.rejectionKey, title: titleKey)
            decisions.log("verdict", "rejected 8 h", "watched \(Int(watchedFor)) s")
        }
    }

    private func scrobble(_ action: String) {
        guard stores.trakt.isSignedIn, stores.traktFlags.value.scrobble, !isLive, !isRecording, duration > 0 else { return }
        if action == "start" { scrobbleStarted = true }
        let fraction = currentTime / duration
        let m = meta, v = video
        Task { await TraktService.scrobble(action, meta: m, video: v, progress: fraction) }
    }

    // MARK: - Exit

    /// Opaque black cover → 250 ms → detach video → release criteria → 0.8 s settle → dismiss.
    func exit() {
        guard !exitCover else { return }
        saveProgress(transient: false)
        applyVerdict()
        scrobble("stop")
        exitCover = true
        tickTimer?.invalidate()
        watchdog?.cancel()
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            engine?.pause()
            engine?.view.removeFromSuperview()
            // tvOS switches the panel back to the menu mode now. Wait that out
            // under the black cover: dismissing — or opening the next title —
            // while HDMI renegotiates is what left TVs on a grey screen. (A
            // fixed 0.8 s was shorter than most TVs' switch.)
            if DisplayModeManager.shared.releaseForExit() {
                await DisplayModeManager.shared.waitForSwitch(limit: 6, startWithin: 0.8)
            } else {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            teardown()
            onExit?()
        }
    }

    // MARK: - Picture in Picture

    /// Native: the AVPlayerLayer route. Others: the generic-view route, when AVKit offers it.
    var canPiP: Bool {
        guard let e = engine, !isLive || e.avPlayerLayer != nil else { return false }
        return e.avPlayerLayer != nil ? PiPCoordinator.isSupported : PiPCoordinator.supportsGeneric
    }

    func startPiP() {
        guard let e = engine else { return }
        overlay = .none
        if let layer = e.avPlayerLayer {
            pip.start(layer: layer)
        } else if PiPCoordinator.supportsGeneric {
            pip.start(genericView: e.view)
        } else {
            showToast("Picture in Picture needs the Native engine")
        }
    }

    /// The PiP window is hosting this render view (the player's host must leave it be).
    func pipHolds(_ view: UIView) -> Bool { pipIfCreated?.holds(view) ?? false }

    /// The PiP window's play/pause button.
    func pipSetPlaying(_ playing: Bool) {
        if playing, isPaused { resume() } else if !playing, !isPaused { togglePlayPause() }
    }

    /// The PiP window's mute button (the sample-feed engine has the only mute knob).
    func pipSetMuted(_ muted: Bool) {
        (engine as? DVDirectEngine)?.setUserMuted(muted)
    }

    func stopPiP() { pip.stop() }

    func setPiPActive(_ on: Bool) { pipActive = on }

    func teardown() {
        MediaCacheServer.shared.endSession()
        cacheSpans = []
        preflightTask?.cancel()
        preflightToken = nil
        previews.stop()
        tickTimer?.invalidate()
        hideTask?.cancel()
        watchdog?.cancel()
        nudgeTask?.cancel()
        seekPlayWatch?.cancel()
        engine?.stop()
        engine = nil
        subtitles.engine = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillResign() {
        guard !pipActive else { return }
        suspendedAt = Date()
        if !isPaused {
            engine?.pause()
            isPaused = true
            pausedAt = Date()
            overlay = .pauseInfo
        }
        saveProgress(transient: false)
    }

    @objc private func appDidBecomeActive() {
        // The cache's stall clocks are wall-clock: restamp after a suspension.
        MediaCacheServer.shared.noteAppResumed()
        guard !pipActive, suspendedAt != nil else { return }
        // Black cover while re-syncing after background (hides garbage frames).
        resyncCover = true
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            resyncCover = false
        }
    }
}

// MARK: - Engine delegate

extension PlayerViewModel: PlaybackEngineDelegate {
    func engine(_ e: PlaybackEngine, state: EngineState) {
        guard e === engine else { return }
        engineState = state
        switch state {
        case .ready:
            openedAt = Date()
            duration = e.duration
            armFirstFrameWatchdog()
            e.rate = speed
            applyAudioLanguagePolicy()
            subtitles.rebuild()
            detectChapters()
            if let k = e as? KSEngine { k.applyNativeTextStyle(settings.value) }
            refreshInfo()
        case .buffering:
            rebufferTask?.cancel()
            rebufferTask = Task { [weak self] in
                // Debounced — seek blips must not flash the spinner.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled, self.engineState == .buffering, self.firstFrameShown else { return }
                self.showRebuffer = true
            }
        case .playing:
            rebufferTask?.cancel()
            showRebuffer = false
            if !firstFrameShown { engineDidRenderFirstFrame(e) }
        case .paused:
            rebufferTask?.cancel()
            showRebuffer = false
        case .ended:
            // An "end" before any picture is a load failure, not a finished title.
            if !firstFrameShown || duration <= 0 {
                decisions.log("engine", e.kind.label, "ended before the first frame")
                handleFailure("The stream ended before it started.")
            } else {
                handleEnded()
            }
        case .failed(let msg):
            decisions.log("engine", e.kind.label, "failed: \(msg)")
            handleFailure(msg)
        case .preparing:
            break
        }
    }

    func engineDidRenderFirstFrame(_ e: PlaybackEngine) {
        guard e === engine, !firstFrameShown else { return }
        firstFrameShown = true
        watchdog?.cancel()
        loadingStatus = ""
        pendingResume = nil
        if isPaused { e.pause() }
        if isNoticeClip { decisions.log("notice", "clip", "\(Int(duration)) s — no progress saved") }
        scrobble("start")
        refreshInfo()
        if case .ffmpeg = e.kind, videoInfo.isDolbyVision || audioInfo.codec?.contains("Dolby") == true { DolbyMemory.markCapable(meta.id) }
        // The direct engine's own success is the claim that cannot be wrong.
        if case .dvDirect = e.kind, audioInfo.output == "Dolby bitstream → HDMI" { DolbyMemory.markCapable(meta.id) }
        #if DEBUG
        // `-pipTest`: 10 s in, start Picture in Picture (device check; logs the outcome).
        if CommandLine.arguments.contains("-pipTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                DebugLog.write("PIPTEST canPiP=\(self.canPiP) engine=\(self.engine.map { "\($0.kind)" } ?? "-")")
                self.startPiP()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { DebugLog.write("PIPTEST active=\(self.pipActive)") }
            }
        }
        // `-seekTest <sec>`: 12 s in, seek there (engine seek checks without a remote).
        if let i = CommandLine.arguments.firstIndex(of: "-seekTest"), i + 1 < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                DebugLog.write("SEEKTEST from=\(self.currentTime) to=\(arg) overlay=\(self.overlay)")
                switch arg {
                case "replay": self.replay()
                case "pause":
                    // Pause, then resume 3 s later: the clock must hold, then roll again.
                    self.togglePlayPause()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self else { return }
                        DebugLog.write("SEEKTEST paused 3s time=\(self.currentTime) playing=\(self.engine?.isPlaying ?? false)")
                        self.togglePlayPause()
                    }
                case "audio":
                    // Switch to the other audio track.
                    let tracks = self.engine?.audioTracks ?? []
                    DebugLog.write("SEEKTEST tracks=\(tracks.map { "\($0.id):\($0.displayName)" }) selected=\(self.engine?.selectedAudio?.id ?? "-")")
                    if let other = tracks.first(where: { $0.id != self.engine?.selectedAudio?.id }) { self.engine?.select(audio: other) }
                default:
                    if let t = Double(arg) { self.seek(to: t, keepPaused: false) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self else { return }
                    DebugLog.write("SEEKTEST after 6s time=\(self.currentTime) state=\(self.engineState) paused=\(self.isPaused) overlay=\(self.overlay)")
                    DebugLog.write("SEEKTEST audio now \(self.engine?.selectedAudio?.displayName ?? "-") · \(self.engine?.audioInfo.output ?? "-")")
                    for line in (self.engine as? DVDirectEngine)?.probeLines ?? [] { DebugLog.write("SEEKTEST probe \(line)") }
                    for line in MediaCacheServer.shared.probeLines { DebugLog.write("SEEKTEST cache \(line)") }
                    DebugLog.write("SEEKTEST cacheSpans=\(self.cacheSpans.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) })")
                }
            }
        }
        // `-scrubTest <sec>`: 12 s in, open a scrub at that time (preview checks without a remote).
        if let i = CommandLine.arguments.firstIndex(of: "-scrubTest"), i + 1 < CommandLine.arguments.count, let t = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self else { return }
                self.raiseTransport()
                self.beginScrub()
                self.scrub?.target = t
                self.scrub?.lastInput = Date().addingTimeInterval(60)
                self.previews.refine(around: t)
                DebugLog.write("SCRUBTEST frames=\(self.previews.frames.count)")
            }
        }
        #endif
    }

    func engineTracksChanged(_ e: PlaybackEngine) {
        guard e === engine else { return }
        subtitles.rebuild()
        audioTracks = e.audioTracks
        selectedAudioID = e.selectedAudio?.id
    }
}

/// AniSkip / IntroDB intervals (opt-in, anime).
enum IntroService {
    struct Intervals { var intro: ClosedRange<Double>?; var outro: ClosedRange<Double>? }

    static func intervals(meta: MetaItem, video: MetaVideo?, duration: Double) async -> Intervals? {
        guard let imdb = meta.imdbID, let ep = video?.episode else { return nil }
        // IMDb → MAL id via arm.haglund.dev, then AniSkip.
        guard let u = URL(string: "https://arm.haglund.dev/api/v2/imdb?id=\(imdb)&include=myanimelist"),
              let obj = try? await HTTP.jsonObject(HTTP.request(u, timeout: 10)),
              let list = obj as? [[String: Any]], let mal = list.compactMap({ $0["myanimelist"] as? Int }).first,
              let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(ep)?types[]=op&types[]=ed&episodeLength=\(Int(duration))"),
              let res = try? await HTTP.jsonObject(HTTP.request(url, timeout: 10)) as? [String: Any],
              let results = res["results"] as? [[String: Any]] else { return nil }
        var out = Intervals()
        for r in results {
            guard let iv = r["interval"] as? [String: Any], let s = iv["startTime"] as? Double, let e = iv["endTime"] as? Double, e > s else { continue }
            if (r["skipType"] as? String) == "op" { out.intro = s...e } else if (r["skipType"] as? String) == "ed" { out.outro = s...e }
        }
        return out
    }
}

/// The buffer-health flag the preview passes poll from their own threads.
final class PreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var healthy = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return healthy }
    func set(_ v: Bool) { lock.lock(); healthy = v; lock.unlock() }
}
