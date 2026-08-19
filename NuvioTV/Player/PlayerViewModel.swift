import AVFoundation
import Combine
import GameController
import KSPlayer
import SwiftUI

extension UIApplication {
    /// Non-deprecated replacement for `.windows.first` (deprecated tvOS 15) —
    /// tvOS only ever has one connected window scene, so this is equivalent.
    /// Used for `avDisplayManager`, which hangs off UIWindow.
    var ks_keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first
    }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaItem
    let video: MetaVideo?
    let entry: StreamEntry
    let allEntries: [StreamEntry]
    let resumePosition: Double?
}

enum PlayerOverlay: Equatable {
    case none
    case controls
    case pauseInfo
    case episodes
    case sources
    case audio
    case subtitles
    case speed
    case upNext          // "Up Next" card counting down to the next episode
    case stillWatching   // "Still watching?" gate after N auto-advances
    case postPlay        // end-of-content overlay (replay / close)
    case exitConfirm     // "Exit Player?" confirmation before leaving playback
    case info            // Infuse-style pull-down file/media info panel
    case engine          // playback-engine picker (Auto/Native/FFmpeg/VLC)
    case error(String)
}

enum AspectMode: String, CaseIterable {
    case fit, zoom, stretch

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .zoom: return "Zoom"
        case .stretch: return "Stretch"
        }
    }

    /// Zoom/stretch are applied as a SwiftUI transform on the video host, NOT
    /// via the engine's contentMode — KSPlayer's Metal render path (the
    /// FFmpeg engine, i.e. every MKV) ignores UIView contentMode entirely, so
    /// the button silently no-opped there. A geometric scale computed from the
    /// video's natural size works identically on both engines.
    func scale(video: CGSize, container: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0,
              container.width > 0, container.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let videoAspect = video.width / video.height
        let containerAspect = container.width / container.height
        switch self {
        case .fit:
            return CGSize(width: 1, height: 1)
        case .zoom:
            // Uniformly scale the FITTED video until it fills the screen
            // (crops the mismatched axis — kills letterbox/pillarbox bars).
            let factor = max(containerAspect / videoAspect, videoAspect / containerAspect)
            return CGSize(width: factor, height: factor)
        case .stretch:
            // Non-uniformly fill: distorts instead of cropping.
            if videoAspect > containerAspect {
                return CGSize(width: 1, height: videoAspect / containerAspect)
            } else {
                return CGSize(width: containerAspect / videoAspect, height: 1)
            }
        }
    }
}

/// Engine-agnostic track descriptor covering embedded audio/subtitle tracks
/// (both the AVPlayer- and FFmpeg-backed engines) and addon subtitles.
struct TrackOption: Identifiable, Equatable {
    enum Payload {
        case off
        case track(any MediaPlayerTrack)
        case subtitle(any SubtitleInfo)
        case vlcAudio(Int32)      // VLC audio track index
        case vlcSubtitle(Int32)   // VLC subtitle track index (-1 = off)
    }

    let id: String
    let displayName: String
    let payload: Payload

    static func == (lhs: TrackOption, rhs: TrackOption) -> Bool { lhs.id == rhs.id }
}

/// KSOptions that adapts frame pacing to whether the display could actually
/// switch to the content's frame rate:
/// - tvOS Match Content ON  → `updateVideo` switches the panel (24Hz/HDR),
///   cadence is perfect, KSPlayer's default clock policy stays.
/// - Match Content OFF → the panel is stuck at 60Hz (3:2 pulldown). KSPlayer's
///   default policy drops every OTHER frame once video runs slightly late,
///   which reads as stutter on the A10X. Here we soften that: mildly-late
///   frames are SHOWN instead of dropped (late-by-40ms beats an 83ms hole in
///   motion), keeping 1 drop in 3 so the clock still catches up. Emergency
///   recovery (flush / seek / GOP drops for seriously-behind video) passes
///   through untouched.
final class NuvioPlayerOptions: KSOptions {
    /// True when the display can't match content (stays 60Hz). Refreshed on
    /// every `updateVideo` (KSPlayer's Metal path calls it on video setup; the
    /// native path via applyNativeDisplayCriteria). Written on main, read on
    /// the render clock thread — benign torn-read (a frame of stale policy).
    var pulldown60Hz = false

    /// OPT-IN display-mode switching. Some TVs mis-handshake the HDMI mode
    /// switch that leaving HDR content triggers — the screen wedges grey until
    /// the TV itself is power-cycled, which no amount of app-side sequencing
    /// can fully fix. So by default the app NEVER touches
    /// `preferredDisplayCriteria`: the Apple TV stays in its home-screen
    /// format and tone-maps HDR/DV content into it, exactly like the Android
    /// APK and Stremio (which never grey-screen). Settings → Playback →
    /// "Match content display mode" turns switching back on for setups that
    /// handle it — and when on, the switch is done in the gentlest form we
    /// can (see updateVideo) to lower the odds of a wedge.
    var matchDisplayCriteria = false

    /// Also switch the panel refresh rate to the content's (off = keep the
    /// current rate, only vary dynamic range). Off avoids the heavy rate
    /// switch whose exit revert power-cycles some TVs.
    var matchFrameRate = false

    /// True for a native-DV session (playing the DV-tagged local playlist):
    /// don't clamp DV→HDR10 in the display request — the clamp exists because
    /// the Metal path OUTPUTS HDR10, which isn't true here.
    var nativeDV = false

    /// The criteria last requested from the display, so repeat calls with
    /// identical criteria don't re-hit the HDMI handshake.
    private var lastAppliedDynamicRange: Int32?
    private var lastAppliedRefreshRate: Float?

    /// Capability-gated, harm-reduced display-mode request. Mitigations over
    /// KSPlayer's stock behavior, aimed at the grey-screen wedge:
    ///
    /// 1. REAL refresh rate, always. An earlier version requested
    ///    `refreshRate: 0` hoping it meant "keep the current rate" — it
    ///    doesn't: 0 isn't a mode any display advertises, and asking the HDMI
    ///    chain to negotiate one is exactly the malformed handshake that
    ///    wedged real hardware grey. Stock KSPlayer always passes the
    ///    content's true rate and is field-tested on tvOS; do the same, and
    ///    refuse to request anything when the rate is unknown. (tvOS itself
    ///    only *applies* the rate/range parts the user has enabled under
    ///    Settings → Video and Audio → Match Content.)
    /// 2. DE-DUP. KSPlayer calls this on both the fps and formatDescription
    ///    didSet, so the same criteria arrives 2–3× in a row; re-requesting
    ///    an identical mode is a pointless extra handshake, so we skip it.
    ///
    /// The DR itself is clamped to what the TV actually advertises
    /// (`DynamicRange.availableHDRModes`): DV maps to HDR10 (the Metal path
    /// outputs DV as HDR10), an unsupported HDR flavor falls back to the best
    /// supported one, and an SDR-only TV is left alone entirely. A NATIVE-DV
    /// session keeps genuine Dolby Vision — and, being its own explicit DV
    /// opt-in, may request the switch even when the general "match content
    /// display mode" toggle is off.
    override func updateVideo(refreshRate: Float, isDovi _: Bool, formatDescription: CMFormatDescription?) {
        // A mismatched panel (or Match Frame Rate off) stays at its home rate
        // (typically 60Hz): keep the pulldown softening on.
        pulldown60Hz = true
        guard matchDisplayCriteria || nativeDV,
              refreshRate > 0,
              let displayManager = UIApplication.shared.ks_keyWindow?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled,
              let formatDescription
        else { return }
        var target = formatDescription.dynamicRange
        // FFmpeg/Metal renders DV as HDR10 output (KSPlayer's own mapping) —
        // but a native-DV session really does emit Dolby Vision, so keep it.
        if target == .dolbyVision, !nativeDV { target = .hdr10 }
        let available = DynamicRange.availableHDRModes   // [.sdr] when none
        if target != .sdr, !available.contains(target) {
            if available.contains(.hdr10) { target = .hdr10 }
            else if available.contains(.hlg) { target = .hlg }
            else { target = .sdr }
        }
        // Refresh rate. By default we DON'T switch it — keep the panel at its
        // current rate so the only thing that changes is dynamic range. A rate
        // switch is a heavier HDMI renegotiation, and reverting it on exit is
        // what drops some TVs to standby / turns them off. `matchFrameRate`
        // (Settings → Playback) opts into the real rate switch (with the
        // 23.976 AFR bias: FFmpeg reports film as 23.97/23.98/24.0 but nearly
        // all "24fps" releases are 24000/1001, so bias near-24 to 23.976).
        var rate = Float(UIScreen.main.maximumFramesPerSecond)   // current, no switch
        if matchFrameRate {
            rate = refreshRate
            if (23.5...24.2).contains(rate) { rate = 23.976 }
        }
        // Now that we know whether a rate switch is happening, set the pulldown
        // softening correctly. When Match Frame Rate drives the panel TO the
        // content's native cadence there is no 3:2 pulldown to soften — leaving
        // it on (the old unconditional `true`) made videoClockSync fight a
        // cadence that isn't there, softening drops on an already-matched panel.
        // Match-dynamic-range-only leaves the panel at 60Hz, so it stays on.
        // Set it BEFORE the de-dup guard so it's right even when the criteria
        // are unchanged and we return early below.
        pulldown60Hz = !matchFrameRate
        guard lastAppliedDynamicRange != target.rawValue
            || lastAppliedRefreshRate != rate else { return }
        lastAppliedDynamicRange = target.rawValue
        lastAppliedRefreshRate = rate
        displayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: rate, videoDynamicRange: target.rawValue
        )
        // The exit sequencing needs to know a real switch was requested this
        // SESSION (not just whether the toggle is on — native-DV sessions
        // switch with the toggle off), so it can wait out the switch-back
        // before tearing the cover down.
        onDisplayCriteriaApplied?()
    }

    /// Fired when a display-mode switch is actually requested. Set by
    /// PlayerViewModel.load(); hops to main there.
    var onDisplayCriteriaApplied: (() -> Void)?

    /// Counts softened drops so every 3rd still drops (catch-up pressure).
    private var softenCount = 0

    override func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Double, frameCount: Int) -> (Double, ClockProcessType) {
        let (diff, action) = super.videoClockSync(main: main, nextVideoTime: nextVideoTime, fps: fps, frameCount: frameCount)
        // Only intervene at 60Hz pulldown, only for plain frame drops, and only
        // when lateness is mild — anything worse keeps default recovery.
        guard pulldown60Hz, action == .dropNextFrame, diff > -0.5 else { return (diff, action) }
        softenCount &+= 1
        return softenCount % 3 == 0 ? (diff, action) : (diff, .next)
    }
}

/// Time state published separately from the main view model so the several-
/// times-per-second position ticks only re-render the few small views that
/// display time (timeline, HUDs, readouts) — NOT the whole player ZStack with
/// the video view inside it. This split is the core smoothness fix.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    /// Live scrub position, updated many times per second by the trackpad.
    /// Lives HERE (not on the view model) so scrubbing only re-renders the
    /// small time views, not the whole player ZStack — the scrub-choppiness
    /// fix, same principle as the position ticks.
    @Published var scrubTarget: Double?
    /// Wheel indicator angle, likewise high-frequency.
    @Published var wheelAngle: Double = 0
}

@MainActor
final class PlayerViewModel: ObservableObject {
    // Playback state. Time values live on `clock` (see PlaybackClock); the
    // mirrors here are non-published so internal logic can read them without
    // invalidating every view on each tick.
    @Published private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            // Keep the screen awake ONLY while actually playing. When paused,
            // browsing, or after the player closes, the idle timer must be
            // re-enabled or the Apple TV never shows its screensaver or sleeps
            // (returning from a screensaver mid-pause is handled by the
            // background/foreground resync). Set on main; VM is @MainActor.
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
    }
    @Published private(set) var isBuffering = true {
        // Watchdog only on TRANSITIONS: engines re-fire same-value buffering
        // callbacks repeatedly during a stall, and re-arming on every identical
        // write would perpetually reset the 20s timer so it never fired.
        didSet {
            updateBufferSpinner()
            if oldValue != isBuffering { updateStallWatchdog() }
        }
    }
    /// A source that OPENED and then froze mid-stream (a debrid CDN cutting off
    /// an IP-locked link after the first request succeeds) keeps buffering
    /// forever with nothing to re-trigger failover — the load watchdog was
    /// already disarmed when the stream opened. This catches a sustained stall
    /// during active playback and fails over.
    private var stallWatchdogTask: Task<Void, Never>?
    private let stallTimeoutSeconds: UInt64 = 20

    private func updateStallWatchdog() {
        stallWatchdogTask?.cancel()
        // Only while a stream that already started keeps buffering, mid-playback.
        // (A brief seek/skip blip cancels-and-re-arms, so only a SUSTAINED
        // stall ever fires.)
        guard isBuffering, currentLoadStarted, hasStartedPlayback,
              !isExiting, !isFailingOver else { return }
        let timeout = stallTimeoutSeconds
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            // Re-check currentLoadStarted at FIRE time too: if a source switch
            // began after arming, the stream is opening (not stalled) and the
            // 30s load watchdog owns that phase — a slow debrid open must not
            // be killed at 20s by a stall check armed for the previous stream.
            guard !Task.isCancelled, let self,
                  self.isBuffering, self.currentLoadStarted,
                  !self.isExiting, !self.isFailingOver else { return }
            self.showToast("Playback stalled — trying another source")
            self.attemptFailover(
                afterError: NSError(
                    domain: "Nuvio", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Playback stalled for \(timeout)s."]
                ),
                preferResolution: self.currentEntry.resolutionLabel
            )
        }
    }
    /// Debounced buffering UI. Skips/seeks cause sub-half-second `.buffering`
    /// blips, and flashing the spinner card for those reads as a white glitch
    /// over the video. Only surface the spinner when buffering PERSISTS.
    @Published private(set) var showBufferSpinner = false
    private var bufferSpinnerTask: Task<Void, Never>?

    private func updateBufferSpinner() {
        bufferSpinnerTask?.cancel()
        if isBuffering {
            guard !showBufferSpinner else { return }
            bufferSpinnerTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.isBuffering else { return }
                self.showBufferSpinner = true
            }
        } else {
            showBufferSpinner = false
        }
    }
    /// False until the stream first becomes ready. Drives the full-screen
    /// Nuvio-style loading backdrop (shown only during the initial load); once
    /// playing, mid-stream rebuffers use a light spinner instead.
    @Published private(set) var hasStartedPlayback = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    let clock = PlaybackClock()
    /// Which engine KSPlayerLayer is currently using ("Native" / "FFmpeg").
    @Published private(set) var engineName = "Native"

    // UI state
    @Published var overlay: PlayerOverlay = .none
    /// Coarse "a scrub is in progress" flag (flips twice per gesture) so the
    /// player can show/hide the scrub bar. The fine-grained target lives on
    /// `clock.scrubTarget`.
    @Published private(set) var isScrubbing = false
    @Published var toast: String?
    @Published var pendingSeekDelta: Double = 0
    /// Bumped whenever the underlying player (and thus its video view) may
    /// have changed, e.g. after engine failover.
    @Published private(set) var videoRefreshID = UUID()

    // Tracks & modes
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var subtitleOptions: [TrackOption] = []
    @Published var selectedAudioID: String?
    @Published var selectedSubtitleID: String?
    @Published var aspectMode: AspectMode = .fit
    /// Live subtitle timing offset in seconds (+ later, − earlier). Mirrors
    /// `subtitleModel.subtitleDelay` for the UI; nudged during playback.
    @Published var subtitleDelay: Double = 0
    @Published var playbackSpeed: Float = 1.0
    /// Native-transport fast-forward / rewind. It is a PREVIEW scrub through the
    /// progress bar: `scanPreview` is the previewed position (nil = not scanning),
    /// and the underlying player is paused and NOT sought while it runs — so no
    /// new content loads until the user commits with Play (`scanCommit`).
    /// `scanRate` is the continuous-sweep speed/direction (0 = paused-preview,
    /// +2/+3 = sweeping forward Nx, −2/−3 = sweeping back Nx).
    @Published var scanPreview: Double?
    @Published private(set) var scanRate: Int = 0
    private var wasPlayingBeforeScan = false

    // Content
    let meta: MetaItem
    @Published private(set) var currentVideo: MetaVideo?
    @Published private(set) var currentEntry: StreamEntry
    @Published private(set) var allEntries: [StreamEntry]
    @Published private(set) var isSwitchingSource = false

    private(set) var playerLayer: KSPlayerLayer?
    /// The VLC engine, active only when the VLC playback engine is selected;
    /// mutually exclusive with `playerLayer`.
    private(set) var vlcEngine: VLCEngine?
    var usingVLC: Bool { vlcEngine != nil }
    /// The UIView the active engine renders into (KSPlayer's player view or
    /// VLC's drawable), handed to PlayerVideoView.
    var activeVideoView: UIView? { vlcEngine?.videoView ?? playerLayer?.player.view }
    let subtitleModel = SubtitleModel()

    var onDismiss: (() -> Void)?

    // MARK: - Engine-agnostic transport (branch KS ↔ VLC)

    private func enginePlay() {
        if let vlcEngine { vlcEngine.play() } else { playerLayer?.play() }
    }
    private func enginePause() {
        if let vlcEngine { vlcEngine.pause() } else { playerLayer?.pause() }
    }
    private func engineSeek(to seconds: Double, autoPlay: Bool) {
        // Native-DV session: the player's timeline is the local playlist,
        // which starts at dvTimeOffset and only extends as far as the remux
        // has written. In-window seeks translate; out-of-window seeks restart
        // the remux at the target (the source supports range requests).
        if usingNativeDV {
            let windowEnd = dvRemuxFinished ? .infinity : dvTimeOffset + dvWrittenSeconds
            if seconds < dvTimeOffset - 2 || seconds > windowEnd + 4 {
                restartNativeDV(at: seconds)
                return
            }
            playerLayer?.seek(time: max(seconds - dvTimeOffset, 0), autoPlay: autoPlay) { _ in }
            return
        }
        if let vlcEngine {
            vlcEngine.seek(to: seconds)
            if autoPlay { vlcEngine.play() }
        } else {
            playerLayer?.seek(time: seconds, autoPlay: autoPlay) { _ in }
        }
    }

    // MARK: - Native Dolby Vision

    /// True while playback runs off the DV-tagged local playlist (real DV out
    /// through Apple's pipeline). See DVRemuxer for the machinery.
    @Published private(set) var usingNativeDV = false
    private var dvRemuxer: DVRemuxer?
    /// Absolute source time (seconds) that the local playlist's t=0 maps to.
    private var dvTimeOffset: Double = 0
    /// Seconds of content written past dvTimeOffset (the seekable window).
    private var dvWrittenSeconds: Double = 0
    private var dvRemuxFinished = false
    /// Full duration from the FFmpeg session — the growing playlist's own
    /// duration would otherwise creep up the timeline as segments land.
    private var dvFullDuration: Double = 0
    /// One attempt per stream URL; a failed/abandoned URL never re-enters.
    private var dvFailedURLs: Set<String> = []

    /// Block-based NotificationCenter registrations, removed in deinit. The
    /// blocks capture self weakly so the VM deallocates fine either way — but
    /// without explicit removal every finished playback session leaves its
    /// dead observer blocks registered forever, each still invoked on every
    /// background/foreground/controller event.
    private var notificationTokens: [NSObjectProtocol] = []

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
    private var dvAttempted = false
    private var dvRestarting = false
    /// Old remuxers kept alive until teardown so their segment dirs survive
    /// while AVPlayer may still be reading from them mid-restart.
    private var dvRetiredRemuxers: [DVRemuxer] = []

    /// Called from readyToPlay on the FFmpeg engine. Starts a background
    /// remux when every gate passes; playback continues undisturbed until the
    /// playlist is ready, then switches in place.
    private func maybeStartNativeDV() {
        guard settings.nativeDolbyVision,
              !usingNativeDV, !dvAttempted, dvRemuxer == nil, !isExiting,
              // Auto or explicit FFmpeg: both decode DV as HDR10-mapped Metal
              // output, so the native remux is an upgrade for either. (VLC and
              // explicit-native sessions never reach a KSMEPlayer DV probe.)
              effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              let player = playerLayer?.player, player is KSMEPlayer,
              let urlString = currentEntry.stream.url,
              !dvFailedURLs.contains(urlString),
              currentURL?.isFileURL != true,
              DynamicRange.availableHDRModes.contains(.dolbyVision)
        else { return }
        let track = player.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? player.tracks(mediaType: .video).first
        // Profile 5/8 always; Profile 7 only with the libdovi
        // 7→8.1 conversion enabled (DVRemuxer rewrites its RPUs).
        let p7ok = settings.dolbyVisionProfile7
        guard let profile = track?.dovi?.dv_profile,
              profile == 5 || profile == 8 || (profile == 7 && p7ok) else { return }

        dvAttempted = true
        NSLog("[OrivioDV] DV profile %d detected — starting background remux", Int(profile))
        startDVRemux(from: max(position - 2, 0), isRestart: false)
    }

    private func startDVRemux(from startAt: Double, isRestart: Bool) {
        guard let urlString = currentEntry.stream.url else { return }
        if let old = dvRemuxer {
            old.cancel()
            dvRetiredRemuxers.append(old)
        }
        let remuxer = DVRemuxer(
            input: urlString, startAt: startAt,
            preferredAudioLanguage: settings.preferredAudioLanguage,
            convertProfile7: settings.dolbyVisionProfile7
        )
        dvRemuxer = remuxer
        remuxer.onIneligible = { [weak self] reason in
            guard let self, self.dvRemuxer === remuxer else { return }
            NSLog("[OrivioDV] ineligible: %@", reason)
            self.dvFailedURLs.insert(urlString)
            self.dvRemuxer = nil
            if self.usingNativeDV { self.abandonNativeDV() }
        }
        remuxer.onError = { [weak self] message in
            guard let self, self.dvRemuxer === remuxer else { return }
            NSLog("[OrivioDV] remux error: %@", message)
            self.dvFailedURLs.insert(urlString)
            self.dvRemuxer = nil
            if self.usingNativeDV { self.abandonNativeDV() }
        }
        remuxer.onProgress = { [weak self] written in
            guard let self, self.dvRemuxer === remuxer else { return }
            self.dvWrittenSeconds = max(self.dvWrittenSeconds, written)
        }
        remuxer.onFinished = { [weak self] in
            guard let self, self.dvRemuxer === remuxer else { return }
            self.dvRemuxFinished = true
        }
        remuxer.onReady = { [weak self] playlist, actualStart in
            guard let self, self.dvRemuxer === remuxer, !self.isExiting else { return }
            self.dvTimeOffset = actualStart
            self.dvRestarting = false
            if isRestart {
                self.load(entry: self.currentEntry, overrideURL: playlist)
            } else {
                self.switchToNativeDV(playlist: playlist)
            }
        }
        let pace = settings.dolbyVisionProfile7Pace
        remuxer.qos = pace.qos
        remuxer.paceSpeedFactor = pace.speedFactor
        remuxer.paceLeadSeconds = pace.leadSeconds
        remuxer.start()
    }

    /// The playlist is playable — swap engines in place, keeping position.
    private func switchToNativeDV(playlist: URL) {
        guard !usingNativeDV, !isExiting else { return }
        dvFullDuration = duration
        dvRemuxFinished = dvRemuxFinished || false
        usingNativeDV = true
        pendingResume = nil
        showToast("Dolby Vision — native output")
        NSLog("[OrivioDV] switching to native playlist (offset %.1fs)", dvTimeOffset)
        load(entry: currentEntry, overrideURL: playlist)
    }

    /// A seek landed outside the remuxed window — re-remux from the target.
    private func restartNativeDV(at target: Double) {
        guard usingNativeDV, !dvRestarting else { return }
        dvRestarting = true
        isBuffering = true
        let clamped = max(min(target, duration > 0 ? duration - 5 : target), 0)
        position = clamped
        clock.position = clamped
        dvWrittenSeconds = 0
        dvRemuxFinished = false
        NSLog("[OrivioDV] out-of-window seek → re-remux from %.1fs", clamped)
        startDVRemux(from: max(clamped - 2, 0), isRestart: true)
    }

    /// Any DV failure: return to the FFmpeg engine at the same position —
    /// i.e. exactly the pre-DV behavior (decoded HDR10).
    private func abandonNativeDV() {
        guard usingNativeDV else { resetNativeDV(); return }
        NSLog("[OrivioDV] abandoning native DV — falling back to FFmpeg engine")
        if let urlString = currentEntry.stream.url { dvFailedURLs.insert(urlString) }
        showToast("Native Dolby Vision failed — using HDR10")
        pendingResume = position > 10 ? position : nil
        load(entry: currentEntry)   // overrideURL nil → resetNativeDV() runs
    }

    /// Tear down DV state (normal loads, teardown). Keeps dvFailedURLs.
    private func resetNativeDV() {
        dvRemuxer?.cancel()
        if let remuxer = dvRemuxer { dvRetiredRemuxers.append(remuxer) }
        dvRemuxer = nil
        usingNativeDV = false
        dvAttempted = false
        dvRestarting = false
        dvTimeOffset = 0
        dvWrittenSeconds = 0
        dvRemuxFinished = false
        dvFullDuration = 0
    }

    /// Delete every remux directory. Only safe once playback is done.
    private func purgeDVDirectories() {
        purgeRetiredDVDirectories()
        dvRemuxer?.cleanup()
    }

    /// Delete the segment directories of RETIRED remuxers only — the live one
    /// is left alone. Safe to call once playback has settled on the current
    /// source (see markPlaybackProgressed): the retired dirs were kept around
    /// solely to cover the window where AVPlayer might still be reading the old
    /// playlist mid-restart.
    private func purgeRetiredDVDirectories() {
        guard !dvRetiredRemuxers.isEmpty else { return }
        let retired = dvRetiredRemuxers
        dvRetiredRemuxers = []
        // Off the main actor: removing a directory of fMP4 segments is real
        // filesystem work and this runs from the playback clock callback.
        Task.detached(priority: .utility) {
            for remuxer in retired { remuxer.cleanup() }
        }
    }

    // Post-play / auto-next
    let settings: PlayerSettings
    /// The episode queued in the Up Next / Still Watching overlays.
    @Published private(set) var upNextEpisode: MetaVideo?
    /// Remaining seconds on the Up Next countdown (nil = no active countdown).
    @Published private(set) var upNextCountdown: Int?
    /// The countdown's starting value, so the Up Next card can draw a progress
    /// bar (remaining / total). 0 when there's no active countdown.
    @Published private(set) var upNextTotalSeconds: Int = 0
    private var countdownTask: Task<Void, Never>?
    /// True once an Up Next / auto-advance has been triggered for the current
    /// episode, so the threshold fires at most once per episode.
    private var autoAdvanceArmed = false
    /// Consecutive episodes advanced without a user "keep watching" interaction,
    /// feeding the Still Watching gate.
    private var consecutiveAutoAdvances = 0

    private let addonManager: AddonManager
    private let progressStore: ProgressStore
    private var hideControlsTask: Task<Void, Never>?
    private var scrubTimeoutTask: Task<Void, Never>?
    private var seekDebounceTask: Task<Void, Never>?
    /// Highest resume target this session has aimed for. Survives the window
    /// where `position` hasn't caught up yet and `pendingResume` is already
    /// consumed, so a failover during a resume seek doesn't silently restart
    /// the next source from 0. Advanced by real playback in `seek(to:)`.
    private var sessionResumeFloor: Double = 0
    private var scanTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastProgressSave = Date.distantPast
    private var lastSubtitleSearchAt: Double = -1
    private var pendingResume: Double?
    /// Options of the stream currently loading, kept for open-timing logs.
    private var currentOptions: KSOptions?
    private var loadStartedAt: Date?
    private var currentURL: URL?

    // Scrub preview thumbnails, generated in the background over a separate
    // FFmpeg context once playback is underway (Infuse builds its previews the
    // same way). Sorted by time; the scrub HUD picks the nearest frame.
    @Published private(set) var scrubThumbnails: [ScrubThumbnail] = []
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailsStarted = false
    /// The running grabber, so cancelling actually aborts its FFmpeg session —
    /// `thumbnailTask?.cancel()` alone cannot interrupt a blocking network read.
    private var thumbnailer: ScrubThumbnailer?

    // Initial-load phases shown on the loading backdrop: "Loading" while the
    // stream opens, then "Caching" while a deep forward buffer is built with
    // playback held, so the movie starts smooth instead of stuttering on a
    // thin buffer.
    enum LoadPhase { case loading, caching }
    @Published private(set) var loadPhase: LoadPhase? = .loading
    @Published private(set) var cacheProgress: Int = 0
    private var cacheTask: Task<Void, Never>?
    /// Forward-buffer target before first playback begins (one minute, like
    /// Netflix/Infuse); after release the reader keeps caching ahead up to
    /// maxBufferDuration continuously, playing or paused.
    /// Forward-buffer target before first playback — set per-load by the
    /// size tier (0 = skip the hold entirely; small files start instantly).
    private var cacheTargetSeconds: Double = 15
    /// Hard cap on the caching wait so a slow source still starts eventually.
    private let cacheMaxWaitSeconds: Double = 20

    /// Rough bitrate proxy used to tune buffers per stream: a 1 GB episode
    /// and a 60 GB remux need very different memory/network envelopes.
    enum SizeTier {
        case small      // < 2 GB — low bitrate, start instantly, buffer deep
        case medium     // 2–10 GB
        case large      // > 10 GB — high bitrate, cap memory, big socket reads
        case unknown

        init(bytes: Int64?) {
            guard let bytes, bytes > 0 else { self = .unknown; return }
            switch bytes {
            case ..<(2 << 30): self = .small
            case ..<(10 << 30): self = .medium
            default: self = .large
            }
        }
    }

    private static var engineConfigured = false

    private static func configureEngineDefaults() {
        guard !engineConfigured else { return }
        engineConfigured = true
        // Native AVPlayer first (HLS/MP4/MOV hardware path); on failure
        // KSPlayerLayer transparently retries with the FFmpeg engine, which
        // covers MKV, AVI, FLV, TS and friends.
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.logLevel = .error
        // Fast startup: begin rendering as soon as the first frames decode
        // (isSecondOpen) instead of waiting for a comfortable buffer.
        //
        // preferredForwardBufferDuration is NOT the smoothness buffer — it's
        // the gate KSPlayer waits on before (re)starting playback: seeks wait
        // for half of it and mid-play stalls wait for ALL of it. On a
        // high-bitrate debrid remux a large value means every stall/seek
        // downloads tens of seconds of video before the picture moves again.
        // Keep the gate SMALL for instant recovery; smoothness comes from the
        // deep background buffer (maxBufferDuration), which keeps filling
        // ahead regardless of this value.
        //
        // CRITICAL: the gate MUST stay strictly below maxBufferDuration (below).
        // At 6 it EQUALLED the low-power maxBufferDuration (6), so a mid-play
        // stall could only resume once the buffer was 100% full — which it
        // rarely reaches exactly, so playback deadlocked ("plays a split second
        // then keeps loading"). 3 leaves headroom under every tier (6/12/45) and
        // under the per-title byte-budget floor (applyBufferSizeTarget).
        KSOptions.isSecondOpen = true
        KSOptions.preferredForwardBufferDuration = 3
        // The continuous ahead-cache: the reader keeps filling toward this cap
        // the whole time — playing or paused. A high-bitrate remux holds ~this
        // many seconds of compressed packets in RAM (tvOS has no working disk
        // cache), which is real memory pressure on RAM-limited boxes — the
        // 3 GB Apple TV 4K gen-1 was getting jetsam-killed mid-playback. Scale
        // the global default by device tier (the per-title tier logic further
        // down caps the per-instance value the same way).
        KSOptions.maxBufferDuration = PerformanceProfile.isLowPower ? 6
            : (PerformanceProfile.isMidPower ? 12 : 45)
        // Decode off the render thread: the synchronous path stalls the video
        // loop under heavy 4K content on the A10X (the "jumpy" playback).
        KSOptions.asynchronousDecompression = true
        KSOptions.hardwareDecode = true
        // Keyframe seeks are near-instant; frame-accurate seeks can take
        // seconds on long-GOP content.
        KSOptions.isAccurateSeek = false
        // KSPlayer stamps this font onto every text cue, overriding whatever
        // the SwiftUI overlay styles — its tvOS default is a billboard-sized
        // 58pt. Overridden per-session from PlayerSettings in init.
        SubtitleModel.textFontSize = 36
        SubtitleModel.textBold = false
    }

    /// Mirrors "Show unaired next up" (Settings → Layout). Passed in rather than
    /// read from a store because the player owns no layout-settings dependency.
    private let allowUnairedNextUp: Bool

    init(
        request: PlaybackRequest,
        addonManager: AddonManager,
        progressStore: ProgressStore,
        settings: PlayerSettings = .default,
        allowUnairedNextUp: Bool = true
    ) {
        self.allowUnairedNextUp = allowUnairedNextUp
        self.meta = request.meta
        self.currentVideo = request.video
        self.currentEntry = request.entry
        self.allEntries = request.allEntries
        self.addonManager = addonManager
        self.progressStore = progressStore
        self.settings = settings
        self.pendingResume = request.resumePosition

        // Pause the 30s account auto-sync for the duration of playback — a
        // multi-endpoint sync competing for bandwidth mid-stream is exactly the
        // wrong time on a high-bitrate remux.
        NuvioSyncManager.playbackActive = true
        Self.configureEngineDefaults()
        // Subtitle presentation follows the user's Playback settings.
        SubtitleModel.textFontSize = CGFloat(settings.subtitleSize)
        SubtitleModel.textBold = settings.subtitleBold
        // Default video scaling + subtitle timing offset from settings.
        aspectMode = AspectMode(rawValue: settings.aspectModeRaw) ?? .fit
        subtitleDelay = settings.subtitleDelaySeconds
        subtitleModel.subtitleDelay = settings.subtitleDelaySeconds
        // Audio output for the FFmpeg engine, per-session (KSMEPlayer snapshots
        // the type at creation). AudioRendererPlayer =
        // AVSampleBufferAudioRenderer: Dolby Atmos/spatial rendering and
        // cheaper lossless (TrueHD/DTS-HD) audio on the A10X. Capability-
        // gated by default: Auto turns it on only when the current output
        // route (TV/receiver/soundbar) reports spatial-audio support — Atmos
        // setups get the Atmos-capable path, everything else keeps the
        // battle-tested AVAudioEngine. Settings can force either side.
        let useRenderer: Bool
        switch settings.audioOutputMode {
        case .auto:
            useRenderer = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.isSpatialAudioEnabled }
        case .renderer:
            useRenderer = true
        case .engine:
            useRenderer = false
        }
        KSOptions.audioPlayerType = useRenderer
            ? AudioRendererPlayer.self : AudioEnginePlayer.self
        fetchEnrichedMeta()
        configureWheelTracking()
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureWheelTracking() }
        })
        registerLifecycleObservers()
        // NB: the idle timer is managed by `isPlaying` (kept awake only while
        // actually playing) — NOT disabled for the whole session, which used
        // to leave the Apple TV never sleeping / never showing its screensaver.
        load(entry: request.entry)
        maybeRouteToVLCForASS()
    }

    /// Full ASS rendering: if the toggle is on and this title carries a styled
    /// ASS/SSA subtitle track, reload into VLC (which renders it with libass +
    /// embedded fonts). Runs in parallel with the initial KSPlayer load — a
    /// non-ASS title never pays for it, an ASS title flips to VLC once the
    /// header probe returns. Only for the KSPlayer-family engine and a direct
    /// URL (not the DV playlist / an explicit VLC/native/external choice).
    private var assRouteAttempted = false
    private func maybeRouteToVLCForASS() {
        guard settings.fullAssSubtitles, !assRouteAttempted,
              effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              let url = currentEntry.stream.url else { return }
        assRouteAttempted = true
        Task { [weak self] in
            guard await SubtitleProbe.hasStyledASS(url: url) else { return }
            guard let self, !self.isExiting, !self.usingNativeDV,
                  self.effectiveEngine != .vlc else { return }
            NSLog("[OrivioSubs] styled ASS detected — routing to VLC for full rendering")
            self.switchEngine(.vlc)
        }
    }

    // MARK: - App background / foreground

    /// True once a Home-button background happened mid-session, so the
    /// foreground handler knows to resync (and ignores stray foreground
    /// notifications that weren't preceded by a real background).
    private var didBackground = false
    /// Set on willResignActive (app switcher / system overlay) so the
    /// didBecomeActive handler knows a real interruption happened and the
    /// pipeline needs a resync on return — the app-switcher path never fires
    /// background/foreground, so without this the torn-off video layer comes
    /// back frozen while audio keeps playing. Cleared once the resync runs.
    private var didResignActive = false
    /// True while the just-foregrounded pipeline is being flushed/resynced —
    /// PlayerScreen holds a black cover over the video for this so the
    /// undecoded garbage frames (the black/green/red flash) never show.
    @Published private(set) var isResyncing = false
    private var resyncClearTask: Task<Void, Never>?

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        // Pressing Home suspends the app. tvOS does NOT pause the player for
        // us — the decoder keeps queuing frames and the audio session drops,
        // so on return the video races to catch up (fast-forward) against
        // dead/stale audio. Pause cleanly here instead.
        notificationTokens.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterBackground() }
        })
        notificationTokens.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterForeground() }
        })
        // Double-pressing the TV button opens the app switcher: the app only
        // goes INACTIVE — didEnterBackground never fires — yet it's no longer
        // what's on screen, so playback kept running over the switcher/menu.
        notificationTokens.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleResignActive() }
        })
        // Returning from the app switcher (or any system overlay that only made
        // us INACTIVE, never background) fires didBecomeActive with NO
        // willEnterForeground — so the pipeline resync that path relies on never
        // runs, and the video layer, torn off while inactive, comes back frozen
        // with audio still going. Resync here for exactly that case.
        notificationTokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBecomeActive() }
        })
    }

    /// App switcher / system overlay took the screen without backgrounding
    /// us: pause cleanly. Deliberately NO auto-resume on return — same policy
    /// as backgrounding ("press play to continue"). A real Home press fires
    /// this first and then didEnterBackground, whose handler runs on top
    /// harmlessly (pausing an already-paused engine is a no-op; it just adds
    /// its own didBackground bookkeeping for the pipeline resync).
    private func handleResignActive() {
        guard hasStartedPlayback, !isExiting else { return }
        // Remember the interruption even if we were already paused: on return
        // the video layer may have been torn off (frozen frame) and still needs
        // a resync nudge. Actual pausing only matters while playing.
        didResignActive = true
        guard isPlaying else { return }
        enginePause()
        markPaused()
        // Land on the pause overlay so returning shows a clean "paused here"
        // state, not a frozen bare frame.
        if overlay == .none { overlay = .pauseInfo }
        saveProgress()
    }

    private func handleEnterBackground() {
        guard hasStartedPlayback, !isExiting else { return }
        didBackground = true
        enginePause()
        markPaused()
        // Land the viewer on the pause overlay so returning shows a clean
        // "paused here" state, not a frozen bare frame.
        if overlay == .none { overlay = .pauseInfo }
        saveProgress()
    }

    /// Returning from a full background: resync the stale decode pipeline.
    private func handleEnterForeground() {
        guard didBackground, hasStartedPlayback, !isExiting else { return }
        didBackground = false
        // This path owns the resync; keep didBecomeActive (which fires right
        // after) from running a second, redundant one.
        didResignActive = false
        resyncPipeline()
    }

    /// Returning from the app switcher / a system overlay that only made us
    /// INACTIVE (no background/foreground pair). Without this the resync never
    /// runs and the torn-off video layer comes back frozen while audio plays —
    /// the double-press-Home-then-return freeze. Guarded so it never doubles up
    /// with the full-background path (which clears didResignActive first).
    private func handleBecomeActive() {
        guard didResignActive, !didBackground, hasStartedPlayback, !isExiting else { return }
        didResignActive = false
        resyncPipeline()
    }

    /// Flush the (possibly stale or torn-off) decode pipeline and re-render the
    /// current frame in place, staying paused where the viewer left off —
    /// pressing Play then resumes cleanly instead of into a broken pipeline
    /// (the fast-forward / stale-audio / frozen-frame bugs). Never auto-resumes.
    private func resyncPipeline() {
        isResyncing = true
        let target = max(position - 1, 0)
        if let vlcEngine {
            vlcEngine.seek(to: target)
            vlcEngine.pause()
            scheduleResyncClear(after: 0.7)
        } else {
            playerLayer?.pause()
            // DV-aware: native Dolby Vision runs off an offset local playlist,
            // so a raw layer seek to the absolute `position` lands outside the
            // playlist window and WEDGES the picture (frozen video / blue screen
            // on exit). engineSeek maps the offset (and restarts the remux if the
            // target fell out of the written window).
            if usingNativeDV {
                engineSeek(to: target, autoPlay: false)
                // engineSeek has no completion hook; rely on the safety-net clear.
                scheduleResyncClear(after: 1.5)
            } else {
                playerLayer?.seek(time: target, autoPlay: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleResyncClear(after: 0.2) }
                }
                // Safety net in case the seek callback never fires.
                scheduleResyncClear(after: 1.5)
            }
        }
        position = target
        clock.position = target
        isPlaying = false
        markPaused()
    }

    /// Clear the black resync cover once — the earliest scheduled clear wins,
    /// so the seek callback (fast) supersedes the safety-net timeout (slow).
    private func scheduleResyncClear(after seconds: Double) {
        guard isResyncing else { return }
        resyncClearTask?.cancel()
        resyncClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isResyncing = false
        }
    }

    // MARK: - Loading

    /// `overrideURL` is the native-DV path: play this local playlist instead
    /// of the entry's stream URL (entry stays the logical source for progress,
    /// source panels, failover identity). A normal load (nil) always resets
    /// any DV session first.
    private func load(entry: StreamEntry, overrideURL: URL? = nil) {
        if overrideURL == nil { resetNativeDV() }
        guard let url = overrideURL ?? entry.stream.url.flatMap(URL.init(string:)) else {
            overlay = .error("This source has no playable link.")
            return
        }
        audioOptions = []
        subtitleOptions = []
        selectedSubtitleID = nil
        duration = 0
        buffered = 0
        position = 0
        clock.position = 0
        clock.duration = 0
        clock.buffered = 0
        isBuffering = true
        pausedAt = nil

        // VLC engine path: self-contained, skips all the KSPlayer/FFmpeg setup.
        // (Never for the DV playlist — that must ride the native pipeline.)
        if effectiveEngine == .vlc, overrideURL == nil {
            loadViaVLC(url: url)
            return
        }
        // Coming FROM the VLC engine (engine switch, or failover off a VLC
        // error): shut it down or both engines would run at once.
        vlcEngine?.stop()
        vlcEngine = nil

        let options = NuvioPlayerOptions()
        // Sticky per-session record that a display-mode switch really was
        // requested (survives options replacement on failover/DV swap) — the
        // exit path waits out the switch-back only when one could be pending.
        options.onDisplayCriteriaApplied = { [weak self] in
            DispatchQueue.main.async { self?.displayCriteriaApplied = true }
        }
        // Display-mode switching is opt-in (see matchDisplayCriteria doc); and
        // even when on it only varies dynamic range, never refresh rate — so
        // the panel stays at its home rate and the softened-drop pacing is
        // always the right policy for 24fps content.
        options.matchDisplayCriteria = settings.matchContentDisplayMode
        options.matchFrameRate = settings.matchFrameRate
        options.pulldown60Hz = true
        // Native-DV session: if the user also enabled display matching, let
        // updateVideo request the real Dolby Vision mode instead of clamping
        // DV→HDR10 (the clamp exists for the decoded-HDR10 Metal path).
        options.nativeDV = overrideURL != nil

        // Route containers AVPlayer can't handle (the typical debrid remux is
        // an MKV) STRAIGHT to the FFmpeg engine. Otherwise KSPlayer tries the
        // native engine first — and on a 50 GB remote MKV AVPlayer can grind
        // for MINUTES before giving up, only then failing over to FFmpeg,
        // which re-downloads and re-probes from scratch.
        //
        // Container detection: URL path first; if the link is extensionless
        // (TorBox `requestdl?…`, some unrestrict endpoints) fall back to the
        // resolved filename, which the debrid resolver puts in the stream
        // title. A still-unknown remote file defaults to FFmpeg — it plays
        // everything (including MP4/HLS), while a wrong native-first guess
        // costs a minutes-long AVPlayer stall.
        let ffmpegContainers: Set<String> = ["mkv", "avi", "flv", "wmv", "ts", "m2ts", "webm"]
        let nativeContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "aac"]
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty,
           let filename = currentEntry.stream.title,
           let dotExt = filename.split(separator: ".").last.map({ String($0).lowercased() }),
           ffmpegContainers.contains(dotExt) || nativeContainers.contains(dotExt) {
            ext = dotExt
        }
        // Engine selection: the user's Settings choice wins; Auto is now
        // FFmpeg-FIRST by default and only hands a file to AVPlayer when the
        // container is a KNOWN streaming-friendly one (mp4/mov/hls/…). This
        // kills the "AVPlayer opens first, can't handle it, grinds, THEN fails
        // over to FFmpeg and re-opens from scratch" double-open on anything
        // ambiguous — an unknown/odd extension used to go native-first and
        // stall. Real mp4/HLS still take the fast native path; everything else
        // (mkv, extensionless debrid links, unknown) opens once on FFmpeg,
        // exactly like a single-engine player (mpv). The OTHER engine remains
        // second for genuine failover.
        let needsFFmpeg: Bool
        if overrideURL != nil {
            // DV playlist: Apple's pipeline only — that's the whole point.
            needsFFmpeg = false
        } else {
            switch effectiveEngine {
            case .native: needsFFmpeg = false
            case .ffmpeg: needsFFmpeg = true
            // .vlc returns before reaching here; .external is intercepted at
            // playback start (NuvioTVApp) — if a session lands here anyway
            // (e.g. no external app installed), route by container like Auto.
            case .auto, .vlc, .external: needsFFmpeg = !nativeContainers.contains(ext)
            }
        }
        KSOptions.firstPlayerType = needsFFmpeg ? KSMEPlayer.self : KSAVPlayer.self
        // Second engine = KSPlayer's own transparent retry when the first one
        // errors. It is only worth having when the other engine could actually
        // play this container.
        //
        // For a KNOWN AVPlayer-hostile container (mkv/avi/ts/…) it is worse
        // than useless: KSPlayerLayer.finish() swallows the FFmpeg error,
        // silently re-opens the same URL on AVPlayer — which cannot demux MKV
        // at all — and only notifies us when THAT fails too. On a big remote
        // remux that doomed second open is the "grinds for a minute doing
        // nothing" gap before the app's own source failover starts, and it also
        // means the error we finally surface is a misleading AVFoundation
        // "media may be damaged" instead of the real FFmpeg one.
        //
        // Unknown/extensionless links keep AVPlayer as a fallback — those are
        // often plain MP4 behind a debrid redirect, where it's a real recovery.
        let secondEngineIsHopeless = needsFFmpeg && ffmpegContainers.contains(ext)
        let secondEngine: MediaPlayerProtocol.Type? = needsFFmpeg
            ? KSAVPlayer.self : KSMEPlayer.self
        KSOptions.secondPlayerType = secondEngineIsHopeless ? nil : secondEngine

        // Fast probe for EVERY direct file (only HLS playlists need the full
        // scan). This previously applied only to known extensions — an
        // extensionless debrid link paid FFmpeg's default probe (5 MB + up to
        // 5 SECONDS of stream content) over remote HTTP, which alone accounted
        // for most of the "big file takes forever to open".
        if ext != "m3u8" {
            options.probesize = 2 << 20              // 2 MB
            options.maxAnalyzeDuration = 1_000_000   // 1s (microseconds)
        }

        // Belt-and-braces: pin the per-instance decode flags (the instance
        // snapshots the statics at init; make the intent explicit).
        options.hardwareDecode = true
        options.asynchronousDecompression = true

        // ---- Size-adaptive buffering (file size as a bitrate proxy) ----
        // One setting cannot fit both a 1 GB episode and a 60 GB remux:
        // seconds-of-packets scale with bitrate, so a fixed "45s" is either
        // wasted latency (small) or a memory bomb (huge) on the 3 GB box.
        // NOTE on the caps: KSPlayer's reader fills to maxBufferDuration,
        // sleeps, and resumes only once the buffer drains to HALF — so the cap
        // also sets the size of the periodic refill burst (network + demux
        // spike ≈ cap/2 seconds of data). On high-bitrate files a big cap
        // meant a CPU/network burst every ~15-20s that visibly nicked
        // playback on the A10X; tighter caps trade a slightly shallower
        // cushion for smaller, gentler refills.
        //
        // START POLICY: we no longer HOLD playback to pre-fill a cache before
        // starting. Every tier now starts on the first keyframe (cacheTarget=0)
        // and relies on KSPlayer's own buffering to pause/resume if the cache
        // underruns mid-stream — the same "start now, rebuffer only if needed"
        // model mpv uses (cache-pause). The old 12-15s pre-start hold on
        // medium/large files was the single biggest self-imposed open delay.
        // maxBufferDuration / socketBuffer stay tier-adaptive (they size the
        // background cache, not the start delay). If a huge remux stutters in
        // the first seconds on the A10X, reintroduce a small hold for .large.
        let tier = SizeTier(bytes: entry.stream.behaviorHints?.videoSize)
        var socketBuffer: Int
        cacheTargetSeconds = 0               // start on first keyframe, no hold
        switch tier {
        case .small:
            options.maxBufferDuration = 90    // low bitrate — bursts are cheap
            socketBuffer = 2 << 20
        case .medium, .unknown:
            options.maxBufferDuration = 36    // refill burst ≈ 18s of data
            socketBuffer = 4 << 20
        case .large:
            options.maxBufferDuration = 24    // refill burst ≈ 12s of data
            socketBuffer = 8 << 20            // fewer, bigger reads
        }
        // User buffer profile (Settings → Playback). Conservative shrinks the
        // seconds-based cap here. The SIZE options can't be sized until the
        // bitrate is known, so they keep the tier default for a smooth start
        // and get their real (byte-target → seconds) value applied at
        // readyToPlay (applyBufferSizeTarget). A bigger socket buffer helps
        // the size profiles sustain the deeper fill.
        switch settings.bufferProfile {
        case .auto:
            break
        case .conservative:
            options.maxBufferDuration = max(options.maxBufferDuration / 2, 12)
            socketBuffer = max(socketBuffer / 2, 1 << 20)
        case .mb500, .gb1, .gb2, .max:
            socketBuffer = min(socketBuffer * 2, 16 << 20)
        }

        // Device-memory ceiling. tvOS keeps this read-ahead cache in RAM (no
        // working disk cache), so on RAM-limited boxes a big buffer — on top of
        // decode, the DV remuxer, and the rest of the app — jetsam-kills the
        // process mid-playback. Worst on the 4K gen-1 (A10X, 3 GB) with a
        // high-bitrate 4K/DV stream, which is uncapped on the default Auto
        // profile (the byte-target profiles are separately bounded by
        // maxBufferBytes). Cap the seconds-based cache hard here; a shallower
        // cushion beats an out-of-memory crash. Applied AFTER the profile
        // adjustments so it's the final word.
        if PerformanceProfile.isLowPower {          // ~2 GB (Apple TV HD)
            options.maxBufferDuration = min(options.maxBufferDuration, 6)
            socketBuffer = min(socketBuffer, 2 << 20)
        } else if PerformanceProfile.isMidPower {   // ~3 GB (4K gen 1/2)
            options.maxBufferDuration = min(options.maxBufferDuration, 12)
            socketBuffer = min(socketBuffer, 4 << 20)
        }

        // Native path: preferredForwardBufferDuration maps STRAIGHT into
        // AVPlayerItem (KSAVPlayer pins automaticallyWaitsToMinimizeStalling
        // to false, so this value is AVPlayer's entire read-ahead license).
        // 6s starved remote playback; give it a real cushion. The FFmpeg path
        // keeps the small 6s gate — there it controls stall-recovery waits,
        // not read-ahead (maxBufferDuration does that).
        if !needsFFmpeg {
            options.preferredForwardBufferDuration = 12
        } else {
            // FFmpeg path: this is the (re)start gate, not the smoothness
            // buffer (maxBufferDuration does that, and keeps filling
            // regardless). 3s instead of the static 6s halves how much a
            // seek/stall downloads before the picture moves again.
            options.preferredForwardBufferDuration = 3
        }

        // FFmpeg-engine tuning (ignored by the AVPlayer path): a large socket
        // read buffer sustains throughput on high-bandwidth debrid CDNs,
        // reconnect-on-drop rides out transient network dips, and HTTP
        // keep-alive (multiple_requests) reuses one TLS connection across the
        // several range requests an MKV open needs (header → cues at the file
        // tail → back) instead of paying a fresh handshake for each.
        options.formatContextOptions["buffer_size"] = socketBuffer
        options.formatContextOptions["reconnect"] = 1
        options.formatContextOptions["reconnect_streamed"] = 1
        options.formatContextOptions["reconnect_delay_max"] = 5
        options.formatContextOptions["multiple_requests"] = 1
        // Also reconnect on HTTP-level errors (5xx from a flaky CDN edge), not
        // just dropped sockets.
        options.formatContextOptions["reconnect_on_network_error"] = 1
        // Hard ceiling on any single blocking read/write (µs). Without it a
        // dead CDN connection hangs the demuxer forever — the "player froze
        // and never errored" case; with it FFmpeg errors out and our failover
        // kicks in. 20s matches the app's URLSession request timeout.
        options.formatContextOptions["rw_timeout"] = 20_000_000
        // Small HTTP requests (range probes, HLS playlists) shouldn't wait on
        // Nagle coalescing.
        options.formatContextOptions["tcp_nodelay"] = 1
        // HLS: reuse one connection across segment fetches.
        options.formatContextOptions["http_persistent"] = 1
        // SOFTWARE-decode relief (ignored whenever VideoToolbox hardware path
        // is active — which is the normal case): when a file falls back to CPU
        // decode (some 10-bit HEVC, AV1, exotic profiles), skipping the
        // in-loop deblocking filter cuts a big slice of per-frame CPU on the
        // A10X. Slight blockiness in dark gradients beats a slideshow.
        // (threads=auto is already KSPlayer's default.)
        options.decoderOptions["skip_loop_filter"] = "all"
        currentOptions = options
        loadStartedAt = Date()
        currentURL = url
        startLoadWatchdog()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        thumbnailsStarted = false
        scrubThumbnails = []
        cacheTask?.cancel()
        addonSubtitlesFetched = false
        subtitleAutoApplied = false
        chapters = []
        animeSkipIntervals = []
        animeSkipFetched = false
        skipIntroActive = false
        autoSkippedChapters = []
        if !hasStartedPlayback {
            loadPhase = .loading
            cacheProgress = 0
        }
        NSLog("[OrivioPlayer] load start ext=%@ engine=%@ url-host=%@",
              ext.isEmpty ? "(none)" : ext,
              needsFFmpeg ? "FFmpeg" : "Native",
              url.host ?? "?")
        subtitleModel.selectedSubtitleInfo = nil
        subtitleModel.url = url

        if let playerLayer {
            playerLayer.set(url: url, options: options)
            // MUST follow every set(url:) on a REUSED layer.
            //
            // KSPlayerLayer.pause() clears its internal `isAutoPlay`, and
            // `set(url:)` only opens the new stream `if isAutoPlay` — both of
            // its branches (`player.replace(url:)` and the swap to a different
            // engine class) gate `prepareToPlay()` on that flag, and neither
            // `stop()` nor `replace()` ever opens a stream by itself. So any
            // load that follows a pause — an episode switch or Up Next advance
            // (play(episode:) pauses first), picking a different source/engine
            // while paused, a failover armed while backgrounded — swapped the
            // URL in and then never opened it. The picture never returned, the
            // 30s watchdog fired, and every failover candidate died exactly the
            // same silent way until "every available source was tried".
            //
            // play() re-arms autoplay and, because set(url:) leaves the layer
            // in `.initialized` via its own stop(), performs the prepareToPlay
            // that actually opens the stream. It is a no-op on the already
            // -preparing path, so the normal (still-playing) case is unchanged.
            playerLayer.play()
        } else {
            playerLayer = KSPlayerLayer(url: url, options: options, delegate: self)
        }
        videoRefreshID = UUID()
    }

    private func refreshEngineName() {
        guard let player = playerLayer?.player else { return }
        engineName = player is KSMEPlayer ? "FFmpeg" : "Native"
    }

    /// Apply a byte-target read-ahead cache for the size buffer profiles. The
    /// buffer is measured in SECONDS (KSPlayer holds that many seconds of
    /// packets in RAM), so convert the byte target to seconds via the stream's
    /// real bitrate — and clamp to the device RAM budget so a huge remux can't
    /// jetsam the app. Only the FFmpeg engine has this seconds-based cache;
    /// the native AVPlayer path manages its own buffer. `currentOptions` is
    /// read live by KSPlayer, so updating it here takes effect immediately.
    private func applyBufferSizeTarget(player: some MediaPlayerProtocol) {
        guard let options = currentOptions, player is KSMEPlayer else { return }
        // The DEFAULT (Auto) profile has no byte target, and this method used to
        // return immediately for it — which meant `PerformanceProfile
        // .maxBufferBytes`, documented as the "hard ceiling … an oversized one
        // jetsams the app", was in practice never enforced on the profile
        // virtually everyone runs. The only limit was maxBufferDuration, a
        // count of SECONDS, which is bitrate-blind: the tier defaults
        // (90s small / 36s unknown / 24s large) are a few tens of MB on an
        // ordinary stream and hundreds of MB on a high-bitrate 4K or 1080p one.
        // A missing `videoSize` hint (very common — Continue Watching resumes
        // carry none) lands such a stream on the 36s "unknown" tier. Treat the
        // device ceiling as the target when the user hasn't picked one.
        let target = settings.bufferProfile.targetBytes ?? PerformanceProfile.maxBufferBytes

        // Bitrate (bits/s): prefer file size ÷ duration; fall back to the sum
        // of the track bitrates. Guard against unknowns so we never divide by
        // a garbage rate.
        var bitsPerSecond = 0.0
        if let bytes = currentEntry.stream.behaviorHints?.videoSize, bytes > 0, duration > 1 {
            bitsPerSecond = Double(bytes) * 8 / duration
        }
        if bitsPerSecond < 1_000_000 {   // implausibly low → use track rates
            let trackBits = (player.tracks(mediaType: .video) + player.tracks(mediaType: .audio))
                .reduce(0.0) { $0 + Double(max($1.bitRate, 0)) }
            if trackBits > 0 { bitsPerSecond = trackBits }
        }
        guard bitsPerSecond >= 1_000_000 else { return }   // still unknown → leave Auto

        let budgetBytes = Double(min(target, PerformanceProfile.maxBufferBytes))
        let seconds = budgetBytes * 8 / bitsPerSecond
        // `seconds` is how much video actually FITS in the RAM byte budget, so it
        // must be an upper bound — this whole method exists to stop high-bitrate
        // remuxes from over-allocating and getting jetsam-killed. The old
        // `max(seconds, options.maxBufferDuration)` floored the result UP to the
        // tier default (up to 45s), which for a 4K/high-bitrate stream blew right
        // past the byte budget it was supposed to enforce. Cap by the byte budget
        // instead; keep only a small floor so the buffer always stays comfortably
        // above the stall-resume gate (preferredForwardBufferDuration), never a
        // runaway (30 min is plenty even for a very low-bitrate stream).
        let floor = Double(KSOptions.preferredForwardBufferDuration) + 2
        var clamped = min(max(seconds, floor), 1800)
        // On Auto the byte budget is only a CEILING: it must be able to shrink
        // the tier's seconds cap for a high-bitrate stream, never to inflate it
        // (a low-bitrate file would otherwise be handed 30 minutes of buffer).
        // An explicitly chosen size profile stays authoritative in both
        // directions — that is what the user asked for.
        if settings.bufferProfile.targetBytes == nil {
            clamped = max(min(clamped, options.maxBufferDuration), floor)
        }
        options.maxBufferDuration = clamped
        NSLog("[OrivioBuffer] size target %d MB @ %.1f Mbps → %.0fs cache (cap %d MB)",
              target / (1 << 20), bitsPerSecond / 1_000_000, clamped,
              PerformanceProfile.maxBufferBytes / (1 << 20))
    }

    /// Match Frame Rate / Match Dynamic Range for the NATIVE engine. On the
    /// FFmpeg/Metal path KSPlayer's MetalPlayView drives
    /// `KSOptions.updateVideo` itself (per-video, with the decoded format),
    /// which asks tvOS to switch the display to the content's refresh rate +
    /// dynamic range — the thing that kills 3:2 pulldown judder and washed-out
    /// HDR. The AVPlayer path never calls it, so 24fps MP4/HLS stayed at 60Hz.
    /// Drive it here on ready. `updateVideo` is gated internally on the user's
    /// tvOS Match Content setting, and `playerLayerDeinit` resets the criteria
    /// on teardown — both already handled by KSPlayer.
    private func applyNativeDisplayCriteria() {
        guard let player = playerLayer?.player, !(player is KSMEPlayer) else { return }
        guard let track = player.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? player.tracks(mediaType: .video).first,
            track.nominalFrameRate > 0
        else { return }
        currentOptions?.updateVideo(
            refreshRate: track.nominalFrameRate,
            isDovi: track.dovi != nil,
            formatDescription: track.formatDescription
        )
    }

    // MARK: - VLC engine path

    private func loadViaVLC(url: URL) {
        // Tear down any KSPlayer instance so the two engines never coexist.
        playerLayer?.stop()
        playerLayer = nil

        currentURL = url
        loadStartedAt = Date()
        startLoadWatchdog()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        thumbnailsStarted = false
        scrubThumbnails = []
        cacheTask?.cancel()
        addonSubtitlesFetched = false
        subtitleAutoApplied = false
        chapters = []
        animeSkipIntervals = []
        animeSkipFetched = false
        skipIntroActive = false
        autoSkippedChapters = []
        engineName = "VLC"
        if !hasStartedPlayback {
            loadPhase = .loading   // VLC never enters the .caching hold
            cacheProgress = 0
        }

        // VLC never touches KSPlayer, and KSPlayer is what normally puts the
        // audio session into .playback/.moviePlayback (KSAVPlayer/KSMEPlayer
        // both call KSOptions.setAudioSession on init). A VLC-only session
        // therefore ran on tvOS's default .soloAmbient category — the wrong
        // ducking, interruption and route policy for long-form video.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback, policy: .longFormAudio
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        let engine = vlcEngine ?? VLCEngine()
        vlcEngine = engine
        engine.onState = { [weak self] playing, buffering, ended, errored in
            self?.vlcStateChanged(playing: playing, buffering: buffering, ended: ended, errored: errored)
        }
        engine.onTime = { [weak self] current, total in
            self?.vlcTimeChanged(current: current, total: total)
        }
        // Size-adaptive pre-buffer: enough to be smooth for the tier's likely
        // bitrate without hoarding RAM on the 3 GB Apple TV or making small
        // files slow to start.
        let cachingMs: Int
        switch SizeTier(bytes: currentEntry.stream.behaviorHints?.videoSize) {
        case .small: cachingMs = 6000
        case .medium, .unknown: cachingMs = 12000
        case .large: cachingMs = 20000
        }
        engine.load(url: url, networkCachingMs: cachingMs)
        engine.play()
        NSLog("[OrivioPlayer] load start engine=VLC url-host=%@", url.host ?? "?")
        videoRefreshID = UUID()
    }

    private func vlcStateChanged(playing: Bool, buffering: Bool, ended: Bool, errored: Bool) {
        // Exiting: swallow only — same reasoning as the KSPlayer callback
        // (acting on the engine from inside its own state callback re-enters;
        // VLCKit additionally can deadlock on a stop() from its delegate).
        // teardown() stops the engine at dismissal.
        if isExiting { return }
        if errored {
            isPlaying = false
            isBuffering = false
            attemptFailover(afterError: NSError(
                domain: "VLC", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "VLC could not play this source."]
            ))
            return
        }
        if ended {
            isPlaying = false
            handlePlayedToEnd()
            return
        }
        isPlaying = playing
        isBuffering = buffering && !playing
        if playing { markLoadStarted() }   // VLC is alive → disarm watchdog
        // Same stale-connection bookkeeping as the KSPlayer path.
        if playing || buffering {
            pausedAt = nil
        } else if hasStartedPlayback, pausedAt == nil {
            pausedAt = Date()
        }

        if playing, !hasStartedPlayback {
            hasStartedPlayback = true
            loadPhase = nil
            videoRefreshID = UUID()   // re-attach the VLC drawable view
            if let engine = vlcEngine, engine.naturalSize != .zero {
                videoNaturalSize = engine.naturalSize
            }
            loadVLCTracks()
            if let resume = pendingResume, resume > 5,
               duration == 0 || resume < duration - 30 {
                vlcEngine?.seek(to: resume)
            }
            pendingResume = nil
            if playbackSpeed != 1 { vlcEngine?.rate = playbackSpeed }
            fetchAddonSubtitles()
            startThumbnailsIfNeeded()
            if overlay == .none { showControls() }
        }
    }

    private func vlcTimeChanged(current: Double, total: Double) {
        if current > 0, !hasStartedPlayback { hasStartedPlayback = true; loadPhase = nil }
        if current.isFinite { markPlaybackProgressed(currentTime: current) }
        position = current
        if total > 0 { duration = total }
        buffered = 0   // VLC doesn't expose an ahead-buffer, so no cache line
        if abs(clock.position - position) >= 0.4 { clock.position = position }
        if clock.duration != duration { clock.duration = duration }
        if videoNaturalSize == .zero, let size = vlcEngine?.naturalSize, size != .zero {
            videoNaturalSize = size
        }
        updateSkipIntro()
        saveProgressThrottled()
        maybeArmAutoNext()
    }

    /// Build the audio/subtitle pickers from VLC's track lists.
    private func loadVLCTracks() {
        guard let engine = vlcEngine else { return }
        audioOptions = engine.audioTracks.map {
            TrackOption(id: "vlc-audio-\($0.id)", displayName: $0.name, payload: .vlcAudio($0.id))
        }
        selectedAudioID = "vlc-audio-\(engine.currentAudioID)"

        var subs: [TrackOption] = []
        if !engine.subtitleTracks.isEmpty {
            subs.append(TrackOption(id: "sub-off", displayName: "Off", payload: .vlcSubtitle(-1)))
            subs.append(contentsOf: engine.subtitleTracks
                .filter { $0.id >= 0 }
                .map { TrackOption(id: "vlc-sub-\($0.id)", displayName: $0.name, payload: .vlcSubtitle($0.id)) })
        }
        subtitleOptions = subs
        selectedSubtitleID = engine.currentSubtitleID < 0 ? "sub-off" : "vlc-sub-\(engine.currentSubtitleID)"
        applyDefaultSubtitleIfNeeded()
    }

    private func loadTracks() {
        guard let player = playerLayer?.player else { return }

        audioOptions = player.tracks(mediaType: .audio).map { track in
            TrackOption(
                id: "audio-\(track.trackID)",
                displayName: trackLabel(track),
                payload: .track(track)
            )
        }
        selectedAudioID = player.tracks(mediaType: .audio)
            .first { $0.isEnabled }
            .map { "audio-\($0.trackID)" }

        // Preferred audio language: when configured and the stream carries a
        // matching track, switch to it (highest channel count wins).
        if !settings.preferredAudioLanguage.isEmpty {
            let want = settings.preferredAudioLanguage
            let matches = player.tracks(mediaType: .audio)
                .filter { ($0.languageCode ?? "").hasPrefix(want) }
                .sorted { Self.channelCount($0) > Self.channelCount($1) }
            if let best = matches.first, !best.isEnabled {
                player.select(track: best)
                selectedAudioID = "audio-\(best.trackID)"
            }
        }

        if let dataSouce = player.subtitleDataSouce {
            subtitleModel.addSubtitle(dataSouce: dataSouce)
        }
        rebuildSubtitleOptions()
        fetchAddonSubtitles()
    }

    private func rebuildSubtitleOptions() {
        var options: [TrackOption] = []
        let infos = subtitleModel.subtitleInfos
        if !infos.isEmpty {
            options.append(TrackOption(id: "sub-off", displayName: "Off", payload: .off))
            options.append(contentsOf: infos.map { info in
                TrackOption(
                    id: "sub-\(info.subtitleID)",
                    displayName: info.name,
                    payload: .subtitle(info)
                )
            })
        }
        subtitleOptions = options
        if selectedSubtitleID == nil, !options.isEmpty {
            selectedSubtitleID = "sub-off"
        }
        applyDefaultSubtitleIfNeeded()
    }

    /// True once the "subtitles on by default" auto-selection has fired for
    /// this stream, so later subtitle waves (addon subs arriving after the
    /// embedded tracks) don't override a choice — or the user's own change.
    private var subtitleAutoApplied = false

    /// Turn subtitles on automatically per the user's settings: prefer a track
    /// in `preferredSubtitleLanguage`, else (only once no more are coming, via
    /// `allowFallback`) the first available. Subtitles arrive in waves —
    /// embedded first, addon subs later — so this is called after each wave;
    /// a preferred-language request waits for a match rather than settling for
    /// the first track immediately.
    private func applyDefaultSubtitleIfNeeded(allowFallback: Bool = false) {
        guard settings.subtitlesOnByDefault, !subtitleAutoApplied else { return }
        let real = subtitleOptions.filter { $0.id != "sub-off" }
        guard !real.isEmpty else { return }

        // Preferred language, then the secondary fallback, then (once no more
        // waves are coming) the first available. Within a language, honor the
        // "prefer forced" setting.
        func pickInLanguage(_ code: String) -> TrackOption? {
            let matches = real.filter { optionMatchesLanguage($0, code) }
            guard !matches.isEmpty else { return nil }
            if settings.subtitlePreferForced,
               let forced = matches.first(where: { $0.displayName.localizedCaseInsensitiveContains("forced") }) {
                return forced
            }
            return matches.first
        }

        let want = settings.preferredSubtitleLanguage
        let secondary = settings.subtitleSecondaryLanguage
        let chosen: TrackOption?
        if want.isEmpty {
            chosen = real.first
        } else if let m = pickInLanguage(want) {
            chosen = m
        } else if !secondary.isEmpty, let m = pickInLanguage(secondary) {
            chosen = m
        } else if allowFallback {
            chosen = real.first
        } else {
            chosen = nil   // wait for a later wave that might carry the language
        }
        guard let pick = chosen else { return }
        subtitleAutoApplied = true
        selectSubtitle(pick)
    }

    private func optionMatchesLanguage(_ option: TrackOption, _ code: String) -> Bool {
        let name = option.displayName.lowercased()
        if let localized = Locale.current.localizedString(forLanguageCode: code)?.lowercased(),
           name.contains(localized) {
            return true
        }
        return name.contains(code.lowercased())
    }

    /// Pull external subtitles from any installed subtitle addon (e.g.
    /// OpenSubtitles) and add them to the picker alongside embedded tracks.
    private var addonSubtitlesFetched = false
    private func fetchAddonSubtitles() {
        guard !addonSubtitlesFetched else { return }
        let providers = addonManager.subtitleAddons
        guard !providers.isEmpty else { return }
        addonSubtitlesFetched = true
        let id = currentVideo?.id ?? meta.id
        let type = meta.type
        Task { [weak self] in
            guard let self else { return }
            var added = false
            for addon in providers {
                let subs = (try? await StremioAPI.subtitles(addon: addon, type: type, id: id)) ?? []
                for sub in subs.prefix(25) {
                    guard let url = URL(string: sub.url) else { continue }
                    let language = sub.lang.flatMap {
                        Locale.current.localizedString(forLanguageCode: $0)
                    } ?? sub.lang ?? "Unknown"
                    if let engine = self.vlcEngine {
                        // VLC downloads + renders the sub itself; added without
                        // auto-selecting so the user picks from the panel.
                        engine.addExternalSubtitle(url)
                    } else {
                        let info = URLSubtitleInfo(
                            subtitleID: sub.id ?? sub.url,
                            name: "\(language) · \(addon.manifest.name)",
                            url: url
                        )
                        self.subtitleModel.addSubtitle(info: info)
                    }
                    added = true
                }
            }
            guard added else {
                // No addon subs arrived — this was the last wave, so let a
                // "subtitles on" preference fall back to the first available.
                self.applyDefaultSubtitleIfNeeded(allowFallback: true)
                return
            }
            if self.usingVLC {
                // Give VLC a moment to register the new slave tracks.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.loadVLCTracks()
            } else {
                self.rebuildSubtitleOptions()
            }
            // Addon subs were the final wave: now allow the first-available
            // fallback if the preferred language still never showed up.
            self.applyDefaultSubtitleIfNeeded(allowFallback: true)
        }
    }

    private func trackLabel(_ track: any MediaPlayerTrack) -> String {
        var label = track.name
        if let code = track.languageCode,
           let language = Locale.current.localizedString(forLanguageCode: code),
           !label.localizedCaseInsensitiveContains(language) {
            label += " (\(language))"
        }
        return label.isEmpty ? "Track \(track.trackID)" : label
    }

    // MARK: - Transport

    /// When the player entered pause. Drives the stale-connection recovery on
    /// resume — after a long pause the debrid CDN has almost certainly dropped
    /// the idle socket, so a plain play() drains the buffer and then freezes
    /// mid-scene (the "have to rewind 10 seconds to get it going" bug).
    private var pausedAt: Date?

    /// Stamp the pause clock, KEEPING THE OLDEST time. `pausedAt` answers "how
    /// long has this connection been idle?", so every later event that pauses an
    /// already-paused player (backgrounding, the app switcher, the post-
    /// background resync, entering a scan preview) must not restamp it — that
    /// resets the staleness clock to zero and the resume then takes the plain
    /// play() path on a socket the CDN dropped long ago, which is the freeze the
    /// reconnect-by-seek exists to prevent. Cleared only when playback really
    /// moves again (the `.buffering` / `.bufferFinished` states).
    private func markPaused() {
        if pausedAt == nil { pausedAt = Date() }
    }

    /// Resume via a tiny in-place rewind whenever the stream can seek. That
    /// flushes stale decoder/network state and avoids the pause-resume freeze
    /// where audio continues but the picture needs a manual rewind to move.
    private let resumeRewindSeconds: Double = 1

    /// Beyond this idle time a paused stream's connection is treated as likely
    /// dropped (debrid CDNs reap idle sockets), so the resume flushes it with
    /// the reconnect-rewind. Under it the network cache and decoder are still
    /// warm, so a plain play() resumes instantly IN PLACE — no rewind and no
    /// refilling the 6–20s VLC network cache, which was the "takes forever to
    /// load on resume". A quick pause keeps the second before the playhead
    /// buffered, so nothing has to reload.
    private let staleResumeThreshold: TimeInterval = 12

    func togglePlayPause() {
        // Ignore input while exiting, or during the sub-second post-background
        // resync (a play press then would race the in-flight flush-seek).
        guard !isExiting, !isResyncing else { return }
        // If a fast-forward/rewind preview is up, Play commits it (seek + resume).
        if scanPreview != nil { scanCommit(); return }
        if isPlaying {
            enginePause()
            if overlay == .none {
                overlay = .pauseInfo
            }
        } else {
            // Only reconnect-by-seek when the stream can actually seek — a live
            // / non-seekable source would stash the seek and never play, so the
            // press would do nothing.
            resumePlayback()
            if overlay == .pauseInfo {
                overlay = .none
            }
            restartHideTimer()
        }
    }

    /// Leave pause. Seekable streams resume through a tiny rewind instead of a
    /// plain play(). The seek flushes stale decoder/network state and autoplays
    /// on completion, matching the manual workaround of nudging back a second.
    ///
    /// Non-seekable/live sources still use plain play: asking them to seek could
    /// stash a target that never resolves, making the Play press look ignored.
    ///
    /// The seek AUTOPLAYS on completion — never also call enginePlay(). Same
    /// trap as the resume path in `.readyToPlay`: a synchronous play() lands
    /// inside the seek and stomps KSMEPlayer's `.seeking` back to `.playing`,
    /// restarting both outputs mid-flush. The seek then flushes audio only, so
    /// audio re-primes at the new position while the video output keeps stale
    /// frames — picture freezes, sound carries on. FFmpeg engine only (AVPlayer
    /// has no such state).
    private func resumePlayback() {
        // Only a long idle risks the dropped-socket / stale-decoder freeze the
        // reconnect-rewind exists to fix. A short pause left everything warm, so
        // play in place — instant, and it never re-fills the network cache
        // (the resume that "takes forever to load").
        let idleSeconds = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let connectionLikelyStale = idleSeconds >= staleResumeThreshold
        let canReconnectBySeek = usingVLC || (playerLayer?.player.seekable ?? false)
        if connectionLikelyStale, canReconnectBySeek {
            engineSeek(to: max(position - resumeRewindSeconds, 0), autoPlay: true)
        } else {
            enginePlay()
        }
    }

    func skip(_ seconds: Double) {
        seek(to: position + seconds)
        showToast(TimeFormat.signedDelta(seconds))
    }

    /// When the user last issued a seek (skip/scrub/scan commit). Used to treat a
    /// finish-error that lands right after a big seek as a RECOVERABLE seek fault
    /// rather than a dead source (see `player(layer:finish:)`).
    private var lastUserSeekAt: Date?
    private var seekRecoveryInFlight = false

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        position = target
        clock.position = target   // instant UI feedback, no waiting for a tick
        lastUserSeekAt = Date()
        // The user's own seek replaces the resume target outright (including
        // seeking BACKWARDS — otherwise the floor would drag them forward again
        // on the next failover).
        sessionResumeFloor = target
        engineSeek(to: target, autoPlay: true)
    }

    // MARK: - Infuse-style touchpad scrubbing

    private var scrubAnchor: Double = 0
    /// Non-published mirror so hot-path logic reads the target without a
    /// published access; the UI reads `clock.scrubTarget`.
    private var scrubValue: Double?
    /// Trackpad pans arrive at 60 Hz — publishing the bar that fast is wasted
    /// re-render on the A10X. Coalesce to ~30 Hz; the value is exact either way.
    private var lastScrubPublish = Date.distantPast
    private func publishScrub(_ value: Double) {
        scrubValue = value
        let now = Date()
        guard now.timeIntervalSince(lastScrubPublish) > 0.033 else { return }
        lastScrubPublish = now
        clock.scrubTarget = value
    }

    // MARK: - Trackpad input (window-level indirect touches: pan + tap)
    //
    // Clean, single-source interaction model (rewritten 2026-07-11):
    //  bare video → tap OR swipe-up = controls, swipe-down = info,
    //               horizontal drag = scrub.
    //  scrubbing  → horizontal drag = scrub, tap/click = commit, Menu = cancel,
    //               press L/R = ±jump, circle = wheel fine-tune.
    //  controls   → recognizer is OFF; pure focus + move commands.

    /// Last input event, surfaced on-screen when the debug toggle is on so
    /// gestures can be diagnosed on-device (the sim has no Siri-remote touch).
    @Published var inputDebug = "—"
    private func debug(_ s: String) { if settings.showInputDebug { inputDebug = s } }
    /// Public debug hook for the view's move-command / click paths.
    func noteInput(_ s: String) { debug(s) }

    /// A trackpad swipe ALSO emits an `.onMoveCommand`; suppress those briefly
    /// after handling a gesture so they don't double-fire.
    private var suppressMoveUntil = Date.distantPast
    var moveSuppressed: Bool { Date() < suppressMoveUntil }
    private func suppressMoveBriefly() { suppressMoveUntil = Date().addingTimeInterval(0.4) }

    /// Pan translation (points) → seconds for scrub. Proven scale from the app's
    /// original scrubbing.
    private var secondsPerPoint: Double {
        guard duration > 0 else { return 0.5 }
        return max(duration / 3200, 0.35)
    }

    private enum TouchIntent { case undecided, scrub, consumed }
    private var touchIntent: TouchIntent = .undecided

    // Called by RemoteTouchCatcher.

    func remoteTouchBegan() {
        debug("touch ↓")
        scrubLastDx = 0            // translation resets per gesture
        // A pan only BEGINS on real movement (never on a stationary click), so
        // this reliably means "a swipe is happening" — suppress the parallel
        // move command the remote emits for the same swipe, so a swipe never
        // seeks / opens the menu (only a real button CLICK does). It also marks
        // the in-flight GC touch as a swipe so it isn't also read as a tap.
        suppressMoveBriefly()
        noteSwipeStarted()
        if isScrubbing {
            touchIntent = .scrub
        } else {
            touchIntent = .undecided
        }
    }

    /// `dx`/`dy` = pan translation in points from the gesture start.
    func remoteTouchMoved(dx: CGFloat, dy: CGFloat) {
        suppressMoveBriefly()      // keep the swipe's move command suppressed
        switch touchIntent {
        case .scrub:
            scrubPanPoints(dx: dx)
        case .consumed:
            break
        case .undecided:
            let adx = abs(dx), ady = abs(dy)
            guard max(adx, ady) > 45 else { return }
            touchIntent = .consumed
            if ady > adx {
                if dy > 0 { debug("swipe↓ info"); showInfoPanel() }
                else { debug("swipe↑ controls"); showControls() }
            } else {
                // Horizontal swipe = nothing (no auto-scrub, no seek). Seeking
                // is a TAP on a side or a directional CLICK.
                debug("swipe →/←")
            }
        }
    }

    func remoteTouchEnded(dx: CGFloat, dy: CGFloat) {
        if touchIntent == .scrub { endScrubGesture() }
        touchIntent = .undecided
    }

    /// Pan scrub via INCREMENTAL deltas so it composes cleanly with the wheel
    /// (both just nudge `scrubValue`) and so consecutive drags never jump. Track
    /// the last translation even while the wheel owns the scrub, so handing back
    /// to pan doesn't lurch.
    private var scrubLastDx: CGFloat = 0
    private func scrubPanPoints(dx: CGFloat) {
        let inc = dx - scrubLastDx
        scrubLastDx = dx
        guard let target = scrubValue, !wheelEngaged else { return }
        let proposed = target + Double(inc) * secondsPerPoint
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    func beginScrub() {
        guard hasStartedPlayback else { return }
        guard overlay == .none || overlay == .controls || overlay == .pauseInfo else { return }
        overlay = .none
        hidePeek()
        scrubAnchor = position
        scrubValue = position
        clock.scrubTarget = position
        isScrubbing = true
        resetWheel()
        restartScrubTimeout()
    }

    /// Re-anchor between pan gestures so consecutive swipes accumulate, and
    /// flush the exact value to the bar (the 30 Hz throttle may have dropped
    /// the final delta, leaving the bar a frame behind where the finger left).
    func endScrubGesture() {
        if let target = scrubValue {
            scrubAnchor = target
            clock.scrubTarget = target
        }
    }

    func commitScrub() {
        guard let target = scrubValue else { return }
        seek(to: target)
        clock.scrubTarget = nil
        scrubValue = nil
        isScrubbing = false
        resetWheel()
        scrubTimeoutTask?.cancel()
        // Leave the bar up briefly so you see where you landed, Netflix-style.
        showControls()
    }

    func cancelScrub() {
        clock.scrubTarget = nil
        scrubValue = nil
        isScrubbing = false
        resetWheel()
        scrubTimeoutTask?.cancel()
    }

    /// Coarse jump while in scrub mode: a left/right press moves the target by
    /// the configured scrubber-jump amount (default a minute) — pan zooms,
    /// presses hop, the wheel fine-tunes.
    func scrubJump(_ seconds: Double) {
        guard isScrubbing, let target = scrubValue else { return }
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    // MARK: - Edge wheel fine-tune (Infuse-style: hold at the side & circle)

    /// True while the finger is held at the trackpad EDGE — fine-tune mode.
    /// Engaging at the edge (not on any arc) is what stops the wheel from
    /// hijacking a normal horizontal scrub, and it drives the on-screen
    /// fine-tune indicator.
    @Published private(set) var wheelEngaged = false
    private var wheelLastAngle: Double?
    /// One full revolution ≈ this many seconds — small, because it's FINE tuning.
    private let wheelSecondsPerRevolution: Double = 24

    /// GameController absolute finger position ((0,0) = not touching).
    private func wheelSample(x: Double, y: Double) {
        guard isScrubbing else { resetWheel(); return }
        let radius = (x * x + y * y).squareRoot()

        // Finger lifted → leave fine-tune; normal pan owns the scrub again.
        if radius < 0.1 {
            wheelEngaged = false
            wheelLastAngle = nil
            return
        }
        // ENGAGE only by reaching the EDGE. But once engaged, the WHOLE pad is
        // the wheel — you can circle anywhere and it keeps turning; it only ends
        // on lift. (Requested: "have the whole trackpad be for fine tuning".)
        if !wheelEngaged {
            guard radius > 0.72 else { return }   // not at edge yet → pan handles it
            wheelEngaged = true
            wheelLastAngle = nil
        }
        // Near dead-center atan2 is noisy and flips direction — pause the angle
        // there (don't jump) but STAY engaged; re-anchor when it recovers.
        guard radius > 0.22 else { wheelLastAngle = nil; return }

        let angle = atan2(y, x)
        defer { wheelLastAngle = angle; clock.wheelAngle = angle }
        guard let last = wheelLastAngle, let target = scrubValue else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        guard abs(delta) < 1.0 else { return }   // sample glitch, ignore
        // Clockwise = forward (screen coords: clockwise decreases atan2 angle).
        let seconds = -delta / (2 * .pi) * wheelSecondsPerRevolution
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    private func resetWheel() {
        wheelLastAngle = nil
        wheelEngaged = false
    }

    // MARK: - Circular wheel (GameController absolute position, scrub-only)

    // GameController drives the fine-tune wheel (while scrubbing) AND light-tap
    // detection (otherwise) — the pan recognizer can't see a touch-only tap, but
    // this absolute-position stream does fire (it's what the wheel uses).
    private var gcTouchDown = false
    private var gcTouchStartTime = Date()
    /// True if the pan recognizer began (i.e. a real SWIPE) during this touch —
    /// that's what makes it NOT a tap. Distance is unreliable for side taps
    /// (the finger lands off-center and the lift trajectory adds travel), so we
    /// use "did the pan fire?" instead.
    private var gcPanFiredThisTouch = false

    /// Called by the pan recognizer's .began (movement-gated). Marks the
    /// in-flight GC touch as a swipe so it isn't also treated as a tap.
    func noteSwipeStarted() { gcPanFiredThisTouch = true }

    private func dpadSample(x: Double, y: Double) {
        if isScrubbing { wheelSample(x: x, y: y); return }

        let touching = abs(x) > 0.001 || abs(y) > 0.001
        if touching {
            if !gcTouchDown {
                gcTouchDown = true
                gcTouchStartTime = Date()
                gcPanFiredThisTouch = false
                debug("gc↓")
            }
        } else if gcTouchDown {
            gcTouchDown = false
            let dur = Date().timeIntervalSince(gcTouchStartTime)
            debug("gc↑ \(Int(dur * 1000))ms\(gcPanFiredThisTouch ? " swipe" : "")")
            // A tap = brief contact with NO pan (no swipe) — works anywhere on
            // the pad, including the far edges.
            if dur < 0.6, !gcPanFiredThisTouch { remoteTapped() }
        }
    }

    /// Light tap (no click, no swipe) → SHOW the peek bar. A tap only ever
    /// shows: nothing hides the peek/menu/scrub except the auto-timer and Back.
    private func remoteTapped() {
        debug("tap:show")
        guard hasStartedPlayback, !isScrubbing, overlay == .none else { return }
        showPeek()
    }

    // MARK: - Peek bar (light tap → just the timeline, no menu)

    @Published private(set) var peekVisible = false
    private var peekTask: Task<Void, Never>?

    func showPeek() {
        guard hasStartedPlayback, overlay == .none, !isScrubbing else { return }
        peekVisible = true
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.peekVisible = false
        }
    }

    func hidePeek() {
        peekTask?.cancel()
        peekVisible = false
    }

    func configureWheelTracking() {
        for controller in GCController.controllers() {
            guard let pad = controller.microGamepad else { continue }
            pad.reportsAbsoluteDpadValues = true
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.dpadSample(x: Double(x), y: Double(y)) }
            }
        }
    }

    private func restartScrubTimeout() {
        scrubTimeoutTask?.cancel()
        scrubTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancelScrub()
        }
    }

    // MARK: - D-pad seeking (press-to-skip, accumulating, with hold-accel)

    private var lastNudgeAt: Date?
    private var nudgeStreak = 0

    /// One left/right press. `base` is the configured skip amount (signed).
    /// Rapid consecutive presses accumulate into one bigger seek and, because
    /// holding the D-pad repeats the command, holding accelerates (each quick
    /// repeat grows the step) — a smooth "zoom" forward/back. Commits after a
    /// short pause so the seek fires once, not on every tap.
    func nudgeSeek(_ base: Double) {
        guard hasStartedPlayback else { return }
        let now = Date()
        if let last = lastNudgeAt, now.timeIntervalSince(last) < 0.35 {
            nudgeStreak = min(nudgeStreak + 1, 12)
        } else {
            nudgeStreak = 0
        }
        lastNudgeAt = now

        // 1× on a lone press; ramps up while the button is held.
        let accel = 1.0 + Double(nudgeStreak) * 0.6
        pendingSeekDelta += base * accel

        // Clamp the running preview to the timeline.
        if duration > 0 {
            let target = min(max(position + pendingSeekDelta, 0), duration - 1)
            pendingSeekDelta = target - position
        }

        restartHideTimer()
        seekDebounceTask?.cancel()
        seekDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self else { return }
            let delta = pendingSeekDelta
            pendingSeekDelta = 0
            nudgeStreak = 0
            guard delta != 0 else { return }
            seek(to: position + delta)
        }
    }

    // MARK: - Controls visibility

    func showControls() {
        // No chrome over the loading screen — gestures wake the UI only once
        // the movie is actually playing.
        guard hasStartedPlayback else { return }
        overlay = .controls
        restartHideTimer()
    }

    func hideControls() {
        if overlay == .controls { overlay = .none }
    }

    func restartHideTimer() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            // 3s of true idle — every remote interaction (focus moves included)
            // restarts this, so the controls never vanish mid-navigation.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Keep the transport up while a fast-forward/rewind preview is
            // active (so the moving playhead stays visible); otherwise hide once
            // idle + playing.
            if overlay == .controls, isPlaying, scanPreview == nil {
                overlay = .none
            }
        }
    }

    /// Menu/Back button handling. Back NEVER leaves playback directly — it
    /// either steps back out of a sub-panel to the main player controls, or (at
    /// the top level) raises the "Exit Player?" confirmation. Always returns
    /// true: the actual exit only happens when the user confirms it from the
    /// `.exitConfirm` overlay. `handleExit` is therefore fully self-contained.
    /// One Menu press can be delivered by BOTH the window-level catcher and a
    /// SwiftUI onExitCommand — dedupe so it only steps back once.
    private var lastExitPressAt = Date.distantPast

    func handleExit() -> Bool {
        // Exit already in flight: swallow every Back press so it can't
        // re-open overlays / restart playback while the display-mode switch
        // and dismissal complete.
        guard !isExiting else { return true }
        let now = Date()
        guard now.timeIntervalSince(lastExitPressAt) > 0.3 else { return true }
        lastExitPressAt = now
        // A fast-forward/rewind preview is cancelled by Back first (resumes where
        // playback was, without seeking).
        if scanPreview != nil {
            scanCancel()
            return true
        }
        if isScrubbing {
            cancelScrub()
            return true
        }
        // Peek bar up → Back just hides the bar (don't prompt to exit).
        if peekVisible {
            hidePeek()
            return true
        }
        switch overlay {
        case .episodes, .sources, .audio, .subtitles, .speed, .engine:
            // A player sub-menu → step back to the main player controls.
            overlay = .controls
            restartHideTimer()
        case .pauseInfo:
            // Back out to paused video *with* controls so the user is never
            // left staring at a frozen frame with no visible UI.
            overlay = .controls
        case .upNext:
            // Back on Up Next hides the card and keeps playing the current ep.
            dismissUpNext()
        case .controls:
            // Back with the controls showing just hides them (Netflix/Hulu) —
            // the exit prompt only appears from the bare video. The player
            // auto-shows controls when a stream first loads, so confirming here
            // would pop "Exit Player?" the instant playback begins.
            overlay = .none
        case .exitConfirm:
            // Back while the confirmation is up dismisses it and keeps playing.
            cancelExitConfirm()
        case .info:
            // Back closes the pull-down and returns to the bare video.
            dismissInfoPanel()
        case .none, .error, .stillWatching, .postPlay:
            // Bare video / dead-end overlays → ask before leaving.
            requestExitConfirm()
        }
        return true
    }

    /// Raise the "Exit Player?" confirmation. Progress is persisted up front so
    /// it's safe even if the user then powers off instead of confirming.
    func requestExitConfirm() {
        saveProgress()
        hideControlsTask?.cancel()
        // A DEAD-END overlay (playback error, finished title, still-watching
        // gate) is the only thing standing between the viewer and a black
        // screen — remember it so "Keep Watching" puts it back. Dropping
        // straight to `.controls` left them looking at a transport bar over a
        // stream that had failed or ended, with no way to reach the error text
        // or the Replay / Other Sources buttons again.
        switch overlay {
        case .error, .postPlay, .stillWatching: overlayBeforeExitConfirm = overlay
        default: overlayBeforeExitConfirm = nil
        }
        overlay = .exitConfirm
    }

    /// The dead-end overlay the exit confirmation was raised over, restored if
    /// the viewer chooses to keep watching.
    private var overlayBeforeExitConfirm: PlayerOverlay?

    /// Dismiss the exit confirmation and return to the main player controls.
    func cancelExitConfirm() {
        if let previous = overlayBeforeExitConfirm {
            overlayBeforeExitConfirm = nil
            overlay = previous
            return
        }
        guard hasStartedPlayback else {
            overlay = .none
            return
        }
        overlay = .controls
        restartHideTimer()
    }

    // MARK: - Tracks / speed / aspect

    func selectAudio(_ track: TrackOption) {
        selectedAudioID = track.id
        switch track.payload {
        case .track(let mediaTrack):
            playerLayer?.player.select(track: mediaTrack)
        case .vlcAudio(let id):
            vlcEngine?.selectAudio(id)
        default:
            break
        }
    }

    func selectSubtitle(_ track: TrackOption) {
        selectedSubtitleID = track.id
        switch track.payload {
        case .subtitle(let info):
            // Addon subtitles are downloaded + parsed on selection, which can
            // take a few seconds — say so instead of appearing dead.
            if info as? URLSubtitleInfo != nil {
                showToast("Loading subtitles…")
            }
            subtitleModel.selectedSubtitleInfo = info
        case .vlcSubtitle(let id):
            // VLC renders its own subtitles; -1 disables them.
            vlcEngine?.selectSubtitle(id)
        default:
            subtitleModel.selectedSubtitleInfo = nil
        }
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if let vlcEngine { vlcEngine.rate = speed }
        else { playerLayer?.player.playbackRate = speed }
        showToast("Speed \(speed == 1 ? "Normal" : String(format: "%gx", speed))")
    }

    // MARK: - Fast-forward / rewind scan (native transport, preview-based)

    /// Enter preview mode if we aren't already: pause playback and anchor the
    /// preview at the current position. Nothing is sought here, so nothing loads.
    private func beginScanPreviewIfNeeded() {
        guard scanPreview == nil else { return }
        wasPlayingBeforeScan = isPlaying
        enginePause()
        // Stamp the pause clock ourselves: the engine's `.paused` callback does
        // it for a normal pause, but a scan preview must be timed too so a long
        // sweep resumes through the stale-socket reconnect (see resumePlayback).
        markPaused()
        scanPreview = position
    }

    /// A short PRESS of the FF/RW button. While a continuous sweep runs in that
    /// direction it bumps the speed (2x → 3x); otherwise it steps the preview
    /// playhead ±skip along the bar. Never seeks — the video only moves on Play.
    func scanTap(forward: Bool) {
        guard hasStartedPlayback else { return }
        beginScanPreviewIfNeeded()
        showControls()
        if scanRate != 0, (scanRate > 0) == forward {
            let mag = abs(scanRate) >= 3 ? 2 : abs(scanRate) + 1
            scanRate = forward ? mag : -mag
        } else {
            scanRate = 0
            scanTask?.cancel(); scanTask = nil
            stepScanPreview(forward ? Double(settings.skipSeconds) : -Double(settings.skipSeconds))
        }
    }

    /// A long PRESS (hold): toggle a continuous preview sweep THROUGH the bar in
    /// that direction (2x). Hold again stops the sweep (leaving the preview where
    /// it froze, ready to commit with Play).
    func scanHold(forward: Bool) {
        guard hasStartedPlayback else { return }
        if scanRate != 0 {
            scanRate = 0
            scanTask?.cancel(); scanTask = nil
            showControls()
            return
        }
        beginScanPreviewIfNeeded()
        showControls()
        scanRate = forward ? 2 : -2
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, scanRate != 0, scanPreview != nil else { return }
                stepScanPreview(Double(scanRate) * 6)   // ~6s × rate per tick
                if let p = scanPreview, p <= 0 || p >= max(duration - 1, 0) {
                    scanRate = 0; return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stepScanPreview(_ delta: Double) {
        guard let p = scanPreview else { return }
        scanPreview = max(0, min(p + delta, duration > 0 ? duration - 1 : p + delta))
    }

    /// Commit the preview — the ONLY point the video seeks and thus loads.
    func scanCommit() {
        guard let target = scanPreview else { return }
        scanRate = 0
        scanTask?.cancel(); scanTask = nil
        scanPreview = nil
        // The seek AUTOPLAYS on completion — do NOT also call enginePlay().
        // A synchronous play() lands INSIDE the seek and stomps KSMEPlayer's
        // `.seeking` back to `.playing`, restarting both outputs mid-flush; the
        // seek then flushes audio only, so audio re-primes at the new position
        // while the video output keeps stale frames — picture freezes, sound
        // carries on. (Same trap documented in `.readyToPlay` and the
        // stale-socket resume in togglePlayPause.) If the engine can't seek
        // yet, KSPlayerLayer stashes the target WITH autoplay armed, so
        // playback still starts.
        seek(to: target)        // loads the new position here
        showControls()
    }

    /// Abandon the preview and resume exactly where playback was.
    func scanCancel() {
        guard scanPreview != nil else { return }
        scanRate = 0
        scanTask?.cancel(); scanTask = nil
        scanPreview = nil
        // The preview PAUSED the engine, and a sweep can sit there for minutes
        // — long enough for the CDN to drop the idle socket. Resume through the
        // same stale-connection path as the pause overlay rather than a bare
        // play() that would drain the buffer and freeze.
        if wasPlayingBeforeScan { resumePlayback() }
        showControls()
    }

    func cycleAspect() {
        let all = AspectMode.allCases
        let next = all[(all.firstIndex(of: aspectMode)! + 1) % all.count]
        aspectMode = next
        // The visual change is a SwiftUI transform on the video host (see
        // AspectMode.scale) — the engine stays pinned to aspect-fit. On video
        // that already matches the screen's shape, zoom/stretch are identical
        // to fit — say so instead of looking broken.
        let tv = CGSize(width: 1920, height: 1080)
        let scale = next.scale(video: videoNaturalSize, container: tv)
        if next != .fit, videoNaturalSize != .zero,
           abs(scale.width - 1) < 0.01, abs(scale.height - 1) < 0.01 {
            showToast("\(next.label) — video already fills the screen")
        } else {
            showToast(next.label)
        }
    }

    /// Live subtitle-timing adjustment during playback (+ later, − earlier).
    /// Clamped to ±30 s and applied straight to the subtitle renderer.
    func nudgeSubtitleDelay(by delta: Double) {
        let value = min(30, max(-30, subtitleDelay + delta))
        // Kill −0.0 so the label reads a clean "0.0 s".
        subtitleDelay = value == 0 ? 0 : (value * 10).rounded() / 10
        subtitleModel.subtitleDelay = subtitleDelay
        showToast("Subtitle delay \(Self.formatDelay(subtitleDelay))")
    }

    func resetSubtitleDelay() {
        subtitleDelay = 0
        subtitleModel.subtitleDelay = 0
        showToast("Subtitle delay 0.0 s")
    }

    /// "+1.5 s" / "0.0 s" / "−2.0 s" for the delay HUD.
    static func formatDelay(_ seconds: Double) -> String {
        let sign = seconds > 0 ? "+" : (seconds < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.1f", abs(seconds))) s"
    }

    /// Decoded video dimensions, published for the aspect-mode transform.
    @Published private(set) var videoNaturalSize: CGSize = .zero

    // MARK: - Chapters / skip intro

    /// Container chapters (FFmpeg engine; MKVs usually carry them).
    @Published private(set) var chapters: [Chapter] = []
    /// AnimeSkip op/ed intervals for the current episode (time-based skip data
    /// for anime that ships no named chapters). Feeds intro/credits fallback.
    @Published private(set) var animeSkipIntervals: [AnimeSkipInterval] = []
    private var animeSkipFetched = false

    /// A resolved intro/credits segment — from a file chapter or AnimeSkip.
    /// (KSPlayer's Chapter init is internal, so we can't build one directly.)
    struct SkipSegment { let start: Double; let end: Double; let title: String }
    /// True while playback sits inside an intro-like chapter — the player
    /// shows a "Skip Intro" pill and Play/Pause skips it.
    @Published private(set) var skipIntroActive = false

    /// A chapter that reads like an intro/opening/recap. Covers common
    /// TV/anime conventions ("Opening", "OP", "NCOP", "Cold Open", "Avant",
    /// "Teaser", "Recap"). Needs the FILE to carry named chapters — most
    /// movie/web-dl remuxes don't, which is why the pill often won't appear.
    private var introChapter: SkipSegment? {
        if let chapter = chapters.first(where: { chapter in
            let t = chapter.title.lowercased().trimmingCharacters(in: .whitespaces)
            if t == "op" || t == "ncop" || t == "opening" || t == "intro" { return true }
            return t.contains("intro") || t.contains("opening")
                || t.contains("recap") || t.contains("prologue")
                || t.contains("cold open") || t.contains("avant") || t.contains("teaser")
        }) { return SkipSegment(start: chapter.start, end: chapter.end, title: chapter.title) }
        // Anime-skip fallback: time-based op interval when the file has no
        // named chapters (most anime web releases).
        if let op = animeSkipIntervals.first(where: { $0.kind == .intro }) {
            return SkipSegment(start: op.start, end: op.end, title: "Intro")
        }
        return nil
    }

    /// A chapter that reads like the end credits, and sits in the back half of
    /// the runtime (so a mid-film "credits sequence" or an oddly-named early
    /// chapter can't false-trigger). This is the "credits roll" moment the
    /// Up Next card keys off when present.
    private var creditsChapter: SkipSegment? {
        guard duration > 0 else { return nil }
        if let chapter = chapters.first(where: { chapter in
            guard chapter.start > duration * 0.6 else { return false }
            let title = chapter.title.lowercased()
            return title.contains("credit") || title.contains("outro")
                || title.contains("closing") || title.contains("ending")
                || title == "end" || title == "ed"
        }) { return SkipSegment(start: chapter.start, end: chapter.end, title: chapter.title) }
        // Anime-skip fallback: the ed interval, when it sits in the back half.
        if let ed = animeSkipIntervals.first(where: { $0.kind == .outro }), ed.start > duration * 0.5 {
            return SkipSegment(start: ed.start, end: ed.end, title: "Credits")
        }
        return nil
    }

    /// Chapter starts as 0…1 fractions for timeline tick marks.
    var chapterFractions: [Double] {
        guard duration > 0, chapters.count > 1 else { return [] }
        return chapters.map { $0.start / duration }.filter { $0 > 0.01 && $0 < 0.99 }
    }

    /// Intro/recap chapters already auto-skipped this session, so we jump each
    /// one at most once (the viewer can seek back into it without re-skipping).
    private var autoSkippedChapters: Set<Double> = []

    /// Fetch AnimeSkip op/ed intervals for the current episode once, after the
    /// duration is known (sharpens AniSkip matching). Series episodes only.
    private func loadAnimeSkipIfNeeded() {
        guard !animeSkipFetched, settings.animeSkipEnabled else { return }
        guard let video = currentVideo, let season = video.season, let episode = video.episode,
              meta.id.hasPrefix("tt"), duration > 0 else { return }
        animeSkipFetched = true
        let imdbID = meta.id
        let length = Int(duration)
        Task { [weak self] in
            let intervals = await AnimeSkipService.intervals(
                imdbID: imdbID, season: season, episode: episode, episodeLength: length
            )
            guard !intervals.isEmpty else { return }
            await MainActor.run { self?.animeSkipIntervals = intervals }
        }
    }

    private func updateSkipIntro() {
        loadAnimeSkipIfNeeded()
        guard let intro = introChapter else {
            if skipIntroActive { skipIntroActive = false }
            return
        }
        let inside = position >= intro.start && position < intro.end - 2
        // Auto-skip: jump straight past the intro/recap the first time we land
        // in it (no button press needed).
        if inside, settings.autoSkipSegments, !autoSkippedChapters.contains(intro.start) {
            autoSkippedChapters.insert(intro.start)
            skipIntroActive = false
            seek(to: intro.end)
            showToast("Skipped intro")
            return
        }
        // Otherwise show the pill (if enabled) while inside the chapter.
        let active = inside && settings.skipIntroEnabled
        if active != skipIntroActive { skipIntroActive = active }
    }

    /// Jump past the intro chapter.
    func skipIntro() {
        guard let intro = introChapter else { return }
        seek(to: intro.end)
        skipIntroActive = false
        showToast("Skipped intro")
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Source switching & episodes

    /// True while the Sources panel is fetching alternatives in the background.
    @Published private(set) var isLoadingSources = false

    /// Resolves a torrent stream to a direct URL through the configured debrid
    /// provider. Injected by PlayerScreen (which owns the DebridStore); nil
    /// when no provider is configured.
    var torrentResolver: ((Stream) async -> Stream?)?

    // MARK: - In-player engine switching

    /// Session override picked from the in-player Engine panel; falls back to
    /// the Settings choice.
    @Published private(set) var sessionEngine: PlayerEngine?
    var effectiveEngine: PlayerEngine { sessionEngine ?? settings.playerEngine }

    /// Reload the current stream through a different engine, keeping position.
    func switchEngine(_ engine: PlayerEngine) {
        guard engine != effectiveEngine else {
            overlay = .none
            return
        }
        sessionEngine = engine
        overlay = .none
        let resumeAt = position
        countdownTask?.cancel()
        upNextCountdown = nil
        pendingResume = resumeAt > 10 ? resumeAt : nil
        showToast("Engine: \(engine.label)")
        load(entry: currentEntry)
    }

    /// Fetch every stream for the current title from the installed stream
    /// addons. Torrent entries are kept only when a debrid resolver exists.
    private func fetchAvailableSources(forceRefresh: Bool = false) async -> [StreamEntry] {
        let id = currentVideo?.id ?? meta.id
        let type = meta.type
        let hasResolver = torrentResolver != nil
        var entries: [StreamEntry] = []
        // Instant path: the Sources page caches the raw source list per title,
        // so an in-player Sources open / failover re-uses it with no sweep.
        // `forceRefresh` skips the cache so a failover can re-resolve FRESH
        // debrid links — the cached ones may be IP-locked/expired (the exact
        // "wrong IP, Comet won't play it" case).
        if !forceRefresh,
           let cached = await StreamsViewModel.sourceCache.value(for: id, ttl: StreamsViewModel.sourceCacheTTL),
           !cached.isEmpty {
            entries = cached
                .map { StreamEntry(addonName: $0.addonName, stream: $0.stream) }
                .filter { $0.stream.isPlayable || (hasResolver && $0.stream.isTorrent) }
        } else {
            let addons = addonManager.streamAddons.filter { $0.handles(id: id) }
            await withTaskGroup(of: [StreamEntry].self) { group in
                for addon in addons {
                    group.addTask {
                        let streams = (try? await StremioAPI.streams(addon: addon, type: type, id: id)) ?? []
                        return streams
                            .filter { $0.isPlayable || (hasResolver && $0.isTorrent) }
                            .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                    }
                }
                for await batch in group { entries.append(contentsOf: batch) }
            }
            // Persist for instant re-open (mirrors the Sources page).
            let snapshot = entries.map { CachedStreamSource(addonName: $0.addonName, stream: $0.stream) }
            if !snapshot.isEmpty {
                await StreamsViewModel.sourceCache.store(snapshot, for: id)
            }
        }
        // User stream filters (min resolution, exclude AV1, HDR/DV/cached) run
        // first, then curation. Never let filters empty the list — if they
        // remove everything, fall back to the unfiltered set so playback still
        // has sources.
        let filtered = SourceSelection.filter(entries, settings.streamFilterOptions)
        let base = filtered.isEmpty ? entries : filtered
        // Curate into size tiers with cached links first (same rule as the
        // Sources page). Filters off → raw addon order (cached still first).
        guard settings.sourceFiltersEnabled else {
            return SourceSelection.selectUnfiltered(
                base, cap: PlayerSettings.unfilteredPerAddonCap
            )
        }
        return SourceSelection.select(base, perTier: settings.sourcesPerSizeTier)
    }

    /// Playback started from Continue Watching carries `allEntries: []` (only
    /// the remembered stream URL). Opening the Sources panel then showed an
    /// empty list — and with zero focusable rows, Menu fell through and closed
    /// the whole player. Fetch the alternatives on demand.
    func loadSourcesIfNeeded() {
        guard allEntries.count <= 1, !isLoadingSources else { return }
        isLoadingSources = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingSources = false }
            var entries = await self.fetchAvailableSources()
            // Keep the playing stream selectable/at the top when the fetch
            // didn't return it (e.g. an expired debrid link).
            if !entries.contains(where: { $0.stream.url == self.currentEntry.stream.url }) {
                entries.insert(self.currentEntry, at: 0)
            }
            self.allEntries = entries
        }
    }

    // MARK: - Load timeout watchdog

    /// True once the current load has actually opened/started playing, so the
    /// watchdog knows the source is alive.
    private var currentLoadStarted = false
    private var loadWatchdogTask: Task<Void, Never>?
    /// A source that hasn't started playing within this long is treated as
    /// dead and swapped for another of the same quality. Generous, because a
    /// slow debrid link legitimately takes 10–20s to open a big remux.
    private let loadTimeoutSeconds: UInt64 = 30

    /// (Re)arm the watchdog for a fresh load. Called from `load`/`loadViaVLC`.
    private func startLoadWatchdog() {
        currentLoadStarted = false
        playbackProgressConfirmed = false
        playbackProgressBaseline = nil
        loadWatchdogTask?.cancel()
        let targetURL = currentURL
        let timeout = loadTimeoutSeconds
        loadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled, let self,
                  !self.currentLoadStarted, !self.isExiting, !self.isFailingOver,
                  // Only if we're still on the same load that armed this.
                  self.currentURL == targetURL
            else { return }
            // A stuck DV playlist load falls back to the FFmpeg engine, not
            // to a different source — the source itself is fine.
            if self.usingNativeDV {
                self.abandonNativeDV()
                return
            }
            self.showToast("Source didn't load — trying another")
            self.attemptFailover(
                afterError: NSError(
                    domain: "Nuvio", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "The source didn't start within \(self.loadTimeoutSeconds) seconds."]
                ),
                preferResolution: self.currentEntry.resolutionLabel
            )
        }
    }

    /// Playback has demonstrably begun for the current load — disarm the
    /// watchdog. Idempotent.
    private func markLoadStarted() {
        guard !currentLoadStarted else { return }
        currentLoadStarted = true
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        // NOTE: the failover-chain reset deliberately does NOT happen here.
        // See markPlaybackProgressed().
        playbackProgressBaseline = nil
    }

    /// Wall-clock-independent proof that the current source is actually
    /// PLAYING, not merely open: the engine's clock has advanced ~2s past
    /// wherever this load started.
    private var playbackProgressBaseline: Double?
    private var playbackProgressConfirmed = false

    /// A source is genuinely alive — allow the next stall to re-scrape fresh
    /// links once more (so a link that goes bad mid-session can still recover
    /// via a re-resolve), and let a later stall re-capture the "prefer this
    /// addon/quality" target from whatever is now playing.
    ///
    /// This used to live in `markLoadStarted()`, i.e. it fired at
    /// `.readyToPlay` — when the CONTAINER opens, before a single frame is
    /// presented. Every source opens, so a failure that happens after the open
    /// (the resume-seek freeze above, an IP-locked debrid link that serves
    /// headers then cuts off) reset the chain on every candidate: the failover
    /// forgot which addon/quality it was aiming for, re-granted itself the
    /// expensive full re-scrape each hop, and chewed through the entire source
    /// list reporting "every available source was tried". Opening is not
    /// playing — only advancing the clock is.
    private func markPlaybackProgressed(currentTime: Double) {
        guard !playbackProgressConfirmed, currentLoadStarted else { return }
        guard let baseline = playbackProgressBaseline else {
            playbackProgressBaseline = currentTime
            return
        }
        // Tolerate the resume seek's jump: only forward progress from the
        // settled baseline counts, and a backwards jump re-baselines.
        if currentTime < baseline { playbackProgressBaseline = currentTime; return }
        guard currentTime - baseline >= 2 else { return }
        playbackProgressConfirmed = true
        didFailoverRefetch = false
        chainPreferredAddon = nil
        chainPreferredResolution = nil
        // Playback has demonstrably moved onto the CURRENT source, so any
        // retired DV remuxer's segment directory is no longer being read and
        // can go now rather than at teardown. Each retired remux is a stream
        // COPY of the source — tens of GB on a 4K DV remux — and every
        // out-of-window seek retires another one, so holding them all for the
        // whole session could fill the box's storage mid-movie.
        purgeRetiredDVDirectories()
    }

    // MARK: - Automatic source failover

    /// Sources already tried (and failed) this session, so the failover never
    /// loops back onto a dead link. URLs are tracked too because a fresh
    /// re-scrape hands back new StreamEntry UUIDs for the same (still-dead) link.
    private var failedSourceIDs: Set<UUID> = []
    private var failedSourceURLs: Set<String> = []
    /// Set once a fresh (cache-bypassing) re-scrape has been tried this failover
    /// chain, so exhausting the list re-resolves links exactly once — reset when
    /// a source successfully starts so the next stall can re-scrape again.
    private var didFailoverRefetch = false
    /// The addon/quality of the link that started this failover chain (the
    /// original one the user was on) — failover prefers the SAME addon first,
    /// then the closest quality. Captured at chain start, cleared on a
    /// successful load so a later stall re-captures.
    private var chainPreferredAddon: String?
    private var chainPreferredResolution: String?
    private var isFailingOver = false

    /// A stream died. Remember the survivors' position, pick the next viable
    /// source, and switch to it silently — the error overlay only appears when
    /// every candidate is exhausted. `preferResolution` floats sources of the
    /// same quality to the front (used by the load-timeout failover, so a slow
    /// 4K link is replaced by another 4K link, not a random 480p one).
    private func attemptFailover(afterError error: Error, preferResolution: String? = nil) {
        // Native-DV playback died → the remux/playlist is the suspect, not
        // the source. Fall back to the FFmpeg engine on the same source.
        if usingNativeDV {
            abandonNativeDV()
            return
        }
        guard !isFailingOver else { return }
        isFailingOver = true
        stallWatchdogTask?.cancel()
        // Capture what to aim for ONCE per chain (the link that just died is,
        // on the first failure, the original the user was on): prefer the same
        // addon, then the closest quality.
        if chainPreferredAddon == nil {
            chainPreferredAddon = currentEntry.addonName
            chainPreferredResolution = preferResolution ?? currentEntry.resolutionLabel
        }
        failedSourceIDs.insert(currentEntry.id)
        if let deadURL = currentEntry.stream.url { failedSourceURLs.insert(deadURL) }
        // `position` is ~0 while a resume seek is still in flight and
        // `pendingResume` is cleared the moment it lands, so neither alone
        // survives a failure in that window — hence the session floor.
        let resumeAt = max(max(position, pendingResume ?? 0), sessionResumeFloor)
        isSwitchingSource = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isFailingOver = false
                self.isSwitchingSource = false
            }
            // A bare Continue Watching session has no alternatives yet (and an
            // expired debrid link NEEDS a re-resolve) — fetch the list first.
            if self.allEntries.count <= 1 {
                self.allEntries = await self.fetchAvailableSources()
            }
            var candidates = self.viableFailoverCandidates()
            // Everything we know about is dead. Before giving up, re-scrape
            // FRESH (bypassing the cache) once — a wrong-IP/expired debrid link
            // often re-resolves to a working one — then re-evaluate.
            if candidates.isEmpty, !self.didFailoverRefetch {
                self.didFailoverRefetch = true
                self.showToast("Re-checking sources…")
                self.allEntries = await self.fetchAvailableSources(forceRefresh: true)
                candidates = self.viableFailoverCandidates()
            }
            guard var next = candidates.first else {
                self.overlay = .error(
                    "Playback failed: \(error.localizedDescription)\n\nEvery available source "
                    + "was tried — they may be offline or region-blocked."
                )
                return
            }
            // Torrent candidate → resolve to a direct link first.
            if next.stream.isTorrent {
                guard let resolver = self.torrentResolver,
                      let resolved = await resolver(next.stream) else {
                    self.failedSourceIDs.insert(next.id)
                    if let u = next.stream.url { self.failedSourceURLs.insert(u) }
                    self.attemptFailoverRetry(afterError: error)
                    return
                }
                // The debrid cache can hand back the SAME dead direct link the
                // failover just abandoned (the torrent entry itself stays in
                // allEntries under its magnet URL). Without this check the
                // chain loops forever: pick torrent → resolve to dead link →
                // stall → fail → pick the same torrent again.
                if let u = resolved.url, self.failedSourceURLs.contains(u) {
                    self.failedSourceIDs.insert(next.id)
                    if let tu = next.stream.url { self.failedSourceURLs.insert(tu) }
                    self.attemptFailoverRetry(afterError: error)
                    return
                }
                next = StreamEntry(addonName: next.addonName, stream: resolved)
            }
            // The scrape / debrid re-resolve above can take many seconds. If the
            // viewer exited during it, stop here — `load()` would otherwise open
            // a fresh stream behind the dismissed player (the same orphaned
            // playback `player(layer:finish:)` guards against up front).
            guard !self.isExiting else { return }
            self.showToast("Source failed — trying \(next.addonName)")
            self.currentEntry = next
            self.pendingResume = resumeAt > 10 ? resumeAt : nil
            self.load(entry: next)
        }
    }

    /// Sources not yet marked dead (by UUID or URL), ordered to match the
    /// original link as closely as possible: SAME ADDON + same quality first,
    /// then same addon (any quality), then same quality (other addons), then the
    /// rest — stable within each tier so cached-first order survives.
    private func viableFailoverCandidates() -> [StreamEntry] {
        let viable = allEntries.filter { entry in
            !failedSourceIDs.contains(entry.id)
                && !failedSourceURLs.contains(entry.stream.url ?? "")
        }
        func rank(_ e: StreamEntry) -> Int {
            let sameAddon = chainPreferredAddon != nil && e.addonName == chainPreferredAddon
            let sameRes = chainPreferredResolution != nil && e.resolutionLabel == chainPreferredResolution
            switch (sameAddon, sameRes) {
            case (true, true):   return 0
            case (true, false):  return 1
            case (false, true):  return 2
            case (false, false): return 3
            }
        }
        return viable.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Re-enter the failover after a candidate was consumed without a load.
    private func attemptFailoverRetry(afterError error: Error) {
        isFailingOver = false
        attemptFailover(afterError: error)
    }

    func switchSource(_ entry: StreamEntry) {
        guard entry.id != currentEntry.id else {
            overlay = .none
            return
        }
        // Torrent source mid-playback: resolve through debrid first (this
        // previously dead-ended with "no playable link").
        if entry.stream.isTorrent {
            guard let resolver = torrentResolver else {
                showToast("Add a debrid key in Settings to play torrent sources")
                return
            }
            overlay = .none
            isSwitchingSource = true
            let resumeAt = position
            Task { [weak self] in
                guard let self else { return }
                defer { self.isSwitchingSource = false }
                guard let resolved = await resolver(entry.stream) else {
                    self.showToast("Couldn't resolve this source — try another")
                    return
                }
                // Debrid resolution takes seconds; the viewer may have left in
                // the meantime. Loading now would strand a playing layer behind
                // the dismissed player.
                guard !self.isExiting else { return }
                let direct = StreamEntry(addonName: entry.addonName, stream: resolved)
                self.currentEntry = direct
                self.countdownTask?.cancel()
                self.upNextCountdown = nil
                self.pendingResume = resumeAt > 10 ? resumeAt : nil
                self.load(entry: direct)
            }
            return
        }
        let resumeAt = position
        currentEntry = entry
        overlay = .none
        // Same episode, new source — keep the auto-next arming state as-is
        // (position resumes), but drop any pending Up Next for the old stream.
        countdownTask?.cancel()
        upNextCountdown = nil
        pendingResume = resumeAt > 10 ? resumeAt : nil
        load(entry: entry)
    }

    var nextEpisode: MetaVideo? {
        // displayMeta: CW-resumed sessions only get their episode list from
        // the enriched fetch — without it auto-next never fired for them.
        guard let current = currentVideo, let videos = displayMeta.videos else { return nil }
        let ordered = videos
            .filter { ($0.season ?? 0) > 0 }
            .sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return nil }
        guard let next = ordered.dropFirst(index + 1).first else { return nil }
        // "Show unaired next up" (Settings → Layout). This used to hard-require
        // hasAired, so the player's Up Next disagreed with the detail page,
        // which honours the setting. Note the setting is ON by default: an
        // unaired episode CAN become the auto-advance target, and since it has
        // no sources yet that advance will fail over and report no working
        // source. Turn the setting off to keep the old skip-unaired behaviour.
        return (allowUnairedNextUp || next.hasAired) ? next : nil
    }

    // MARK: - Post-play / auto-next

    /// When the Up Next card should arm. Prefers the exact moment the end
    /// credits start (a "credits"/"ending"/"outro" chapter in the back half of
    /// the runtime) — so the card pops as the credits roll and you can skip
    /// them — and falls back to the configured percentage / minutes-before-end
    /// threshold for content without chapter markers.
    private func crossedNextEpisodeThreshold() -> Bool {
        guard duration > 0 else { return false }
        if let credits = creditsChapter { return position >= credits.start }
        // No credits chapter → arm `upNextLeadSeconds` before the end.
        return (duration - position) <= Double(settings.upNextLeadSeconds)
    }

    /// Called on each time tick. Arms the Up Next overlay once the threshold
    /// is crossed and a next episode exists. The card ALWAYS appears
    /// (Netflix-style); `autoPlayNextEpisode` only decides whether its
    /// countdown runs and auto-advances — previously the whole card was
    /// gated on that setting, which shipped off, so the Play Next Episode
    /// button never showed up at all.
    private func maybeArmAutoNext() {
        guard !autoAdvanceArmed,
              let next = nextEpisode, crossedNextEpisodeThreshold() else { return }
        autoAdvanceArmed = true
        armUpNext(episode: next, atEnd: false)
    }

    /// Show the Up Next card and, unless the timeout is "unlimited", start the
    /// countdown that auto-advances. Doesn't interrupt an interactive overlay
    /// the user has opened (episodes/sources/etc).
    private func armUpNext(episode: MetaVideo, atEnd: Bool) {
        upNextEpisode = episode
        // Don't yank focus from a menu the user is actively using; the end-of-
        // content path (atEnd) always shows it since playback has stopped.
        let interactive: [PlayerOverlay] = [.episodes, .sources, .audio, .subtitles, .speed]
        if !atEnd && interactive.contains(overlay) { return }
        overlay = .upNext

        // Countdown (and the auto-advance it drives) only with auto-play on;
        // otherwise the card just offers Play Next / Cancel and waits.
        let timeout = settings.autoPlayTimeoutSeconds
        guard settings.autoPlayNextEpisode, timeout != PlayerSettings.timeoutUnlimited else {
            upNextCountdown = nil   // wait for the user to confirm
            return
        }
        startUpNextCountdown(from: timeout)
    }

    private func startUpNextCountdown(from seconds: Int) {
        countdownTask?.cancel()
        upNextTotalSeconds = max(seconds, 1)
        upNextCountdown = seconds
        countdownTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                remaining -= 1
                self.upNextCountdown = remaining
            }
            guard !Task.isCancelled, let self else { return }
            self.advanceToNext(userInitiated: false)
        }
    }

    /// Advance to the queued Up Next episode. Honors the Still Watching gate:
    /// after `stillWatchingEpisodeThreshold` consecutive auto-advances it shows
    /// the gate instead of playing, until the user confirms.
    private func advanceToNext(userInitiated: Bool) {
        countdownTask?.cancel()
        upNextCountdown = nil
        guard let episode = upNextEpisode else { return }

        if !userInitiated, settings.stillWatchingEnabled,
           consecutiveAutoAdvances + 1 >= settings.stillWatchingEpisodeThreshold {
            playerLayer?.pause()
            overlay = .stillWatching
            return
        }
        consecutiveAutoAdvances = userInitiated ? 0 : consecutiveAutoAdvances + 1
        play(episode: episode, autoAdvance: !userInitiated)
    }

    /// User pressed "Play Next Episode" on the Up Next card.
    func playUpNextNow() {
        advanceToNext(userInitiated: true)
    }

    /// Long-press "Select Source" on the Up Next card — advance to the next
    /// episode but open its Sources panel to pick a link.
    func playUpNextChoosingSource() {
        countdownTask?.cancel()
        upNextCountdown = nil
        guard let episode = upNextEpisode else { return }
        consecutiveAutoAdvances = 0
        play(episode: episode, presentSources: true)
    }

    /// Long-press "Mark Next Watched" on the Up Next card.
    func markUpNextWatched() {
        guard let episode = upNextEpisode else { return }
        markEpisodeWatched(episode)
    }

    /// User dismissed the Up Next card — keep playing the current episode and
    /// don't re-arm for it. At the end of content this closes to controls.
    func dismissUpNext() {
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextEpisode = nil
        overlay = isPlaying ? .none : .controls
    }

    /// "I'm still here" — reset the counter and continue into the next episode.
    func confirmStillWatching() {
        consecutiveAutoAdvances = 0
        guard let episode = upNextEpisode else {
            overlay = .none
            return
        }
        play(episode: episode, autoAdvance: false)
    }

    /// Replay the finished title from the start (post-play overlay).
    func replay() {
        overlay = .none
        upNextEpisode = nil
        autoAdvanceArmed = false
        consecutiveAutoAdvances = 0
        // Seek only — it autoplays on completion. A second, synchronous play()
        // here ran inside the seek's flush and left the picture frozen with the
        // audio running (see scanCommit / `.readyToPlay` for the full story).
        seek(to: 0)
    }

    /// End-of-content handling: queue the next episode (the Up Next card
    /// always appears when one exists; auto-play only controls its
    /// countdown), or show the post-play overlay for movies / last episodes.
    private func handlePlayedToEnd() {
        saveProgress()
        if let next = nextEpisode {
            autoAdvanceArmed = true
            armUpNext(episode: next, atEnd: true)
        } else {
            overlay = .postPlay
        }
    }

    /// Play a specific episode. `presentSources` opens the Sources panel once
    /// the episode's links are loaded (the "Choose Source" long-press action),
    /// so the viewer can pick a link instead of taking the auto-selected one.
    func play(episode: MetaVideo, autoAdvance: Bool = false, presentSources: Bool = false) {
        // The player is closing (or gone): never start a new stream. Its
        // source fetch takes seconds, so a countdown that fires — or an
        // Episodes-panel tap — as the viewer exits used to land a load() on a
        // dismissed player: a fresh layer playing audio with no UI to stop it.
        guard !isExiting else { return }
        overlay = .none
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextEpisode = nil
        autoAdvanceArmed = false
        if !autoAdvance { consecutiveAutoAdvances = 0 }
        isSwitchingSource = true
        saveProgress()
        playerLayer?.pause()
        let hasResolver = torrentResolver != nil
        Task {
            defer { isSwitchingSource = false }
            // Normalize the episode id the SAME way the initial-play path
            // (StreamsView.effectiveStreamID) does: stream addons speak IMDb
            // `tt` ids and need the canonical `showId:season:episode` form. The
            // raw `episode.id` from enriched metadata can be a `tmdb:` id or —
            // after a Continue-Watching round-trip — a bare show id, neither of
            // which any addon can resolve, which is why switching episodes from
            // the in-player list produced no working source.
            var showID = meta.id
            if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
               let tt = await TMDBService.imdbID(tmdbID: n, isMovie: meta.type != "series") {
                showID = tt
            }
            let streamID: String
            if showID.hasPrefix("tt"), let season = episode.season, let ep = episode.episode {
                streamID = "\(showID):\(season):\(ep)"
            } else {
                streamID = episode.id
            }
            let addons = addonManager.streamAddons.filter { $0.handles(id: streamID) }
            var entries: [StreamEntry] = []
            await withTaskGroup(of: [StreamEntry].self) { group in
                for addon in addons {
                    group.addTask { [meta] in
                        let streams = (try? await StremioAPI.streams(addon: addon, type: meta.type, id: streamID)) ?? []
                        // Keep cached torrents too when a debrid resolver
                        // exists, so the Choose-Source list isn't just direct
                        // links.
                        return streams
                            .filter { $0.isPlayable || (hasResolver && $0.isTorrent) }
                            .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                    }
                }
                for await batch in group {
                    entries.append(contentsOf: batch)
                }
            }
            guard !entries.isEmpty else {
                overlay = .error("No playable sources found for \(episode.seasonEpisodeCode).")
                return
            }
            // Curate the panel list (size tiers, cached first) like the Sources
            // page; fall back to the raw list if curation drops everything.
            let curated = settings.sourceFiltersEnabled
                ? SourceSelection.select(entries, perTier: settings.sourcesPerSizeTier)
                : SourceSelection.selectUnfiltered(entries, cap: PlayerSettings.unfilteredPerAddonCap)
            let panelEntries = curated.isEmpty ? entries : curated

            // Auto-pick must be directly playable (load() can't resolve a
            // torrent). Source selection honors the binge-group settings:
            //  • Prefer same source group ON  → same binge group first;
            //    with Reuse the same stream ON, restrict to the same ADDON's
            //    group (closest to "the same source"), else same addon.
            //  • Prefer same source group OFF → just take the best-ranked
            //    playable link (curation already put it first).
            let playable = panelEntries.filter(\.stream.isPlayable)
            let curGroup = currentEntry.stream.behaviorHints?.bingeGroup
            let preferred: StreamEntry?
            if settings.preferBingeGroupForNextEpisode {
                let sameGroup = playable.first { entry in
                    guard let g = entry.stream.behaviorHints?.bingeGroup, g == curGroup else { return false }
                    return !settings.reuseBingeGroup || entry.addonName == currentEntry.addonName
                }
                let sameAddon = playable.first { $0.addonName == currentEntry.addonName }
                preferred = sameGroup ?? sameAddon ?? playable.first
            } else {
                preferred = playable.first
            }

            // Re-check after the awaits above: the viewer may have exited while
            // the episode's sources were being fetched.
            guard !isExiting else { return }
            currentVideo = episode
            allEntries = panelEntries
            pendingResume = progressStore.progress(for: episode.id)?.positionSeconds
            // New episode = new timeline; the previous episode's resume target
            // must not follow it into a failover.
            sessionResumeFloor = 0

            if let preferred, !presentSources {
                currentEntry = preferred
                load(entry: preferred)
            } else if let preferred {
                // Choose Source: start the auto-pick playing, then open the
                // panel so the viewer can switch.
                currentEntry = preferred
                load(entry: preferred)
                overlay = .sources
            } else {
                // Only torrents available (no direct link to auto-load) — go
                // straight to the picker so the user resolves one.
                if let first = panelEntries.first { currentEntry = first }
                overlay = .sources
            }
        }
    }

    /// Mark an episode watched (wired to WatchedStore by PlayerScreen).
    var markWatched: ((MetaVideo) -> Void)?
    func markEpisodeWatched(_ episode: MetaVideo) {
        markWatched?(episode)
        showToast("Marked \(episode.seasonEpisodeCode) as watched")
    }

    // MARK: - Progress persistence

    private func saveProgressThrottled() {
        // Periodic saves are TRANSIENT: persisted to disk for crash safety,
        // but never published — a publish re-renders the whole Home screen
        // behind the player, which was the periodic playback hiccup. The
        // exit/teardown paths call saveProgress(), which publishes once.
        guard Date().timeIntervalSince(lastProgressSave) > 30 else { return }
        lastProgressSave = Date()
        progressStore.updateTransient(
            meta: meta,
            video: currentVideo,
            streamURL: currentEntry.stream.url,
            position: position,
            duration: duration,
            signature: currentEntry.stream.signature(addonName: currentEntry.addonName)
        )
    }

    func saveProgress() {
        lastProgressSave = Date()
        progressStore.update(
            meta: meta,
            video: currentVideo,
            streamURL: currentEntry.stream.url,
            position: position,
            duration: duration,
            signature: currentEntry.stream.signature(addonName: currentEntry.addonName)
        )
    }

    /// True once the exit sequence has started — every input path (Menu, the
    /// overlay buttons) checks it so a Back press during the exit wait can't
    /// re-open overlays or re-enter the exit flow (the "loop while trying to
    /// close the player").
    private(set) var isExiting = false
    /// True once ANY display-mode switch was requested this session (match
    /// content toggle or native DV). The exit sequencing keys off this.
    private(set) var displayCriteriaApplied = false

    /// Called when the exit sequence starts. Persists progress, halts
    /// playback, and releases HDR display criteria before teardown. Confirmed
    /// exits dismiss immediately after this; engine teardown still runs in
    /// `teardown()` (onDisappear), so resetting criteria twice is a no-op.
    func prepareForExit() {
        guard !isExiting else { return }
        isExiting = true
        saveProgress()
        cacheTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        countdownTask?.cancel()
        dvRemuxer?.cancel()   // stop the DV remux's network reads immediately
        enginePause()
        // Drop any overlay so the wait shows the bare (paused) video, not a
        // half-dead confirm dialog.
        overlay = .none
        // Kick the display-mode switch off immediately, over the player's own
        // screen — the same thing KSPlayerLayer's deinit would do later.
        UIApplication.shared.ks_keyWindow?.avDisplayManager.preferredDisplayCriteria = nil
    }

    func teardown() {
        NuvioSyncManager.playbackActive = false   // resume periodic account sync
        // The player is gone: any in-flight failover / watchdog / seek callback
        // must NOT restart playback from here (they all gate on isExiting).
        // Also swallows engine state callbacks arriving mid-teardown.
        isExiting = true
        saveProgress()
        cacheTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        countdownTask?.cancel()
        scanTask?.cancel()
        resyncClearTask?.cancel()
        loadWatchdogTask?.cancel()
        stallWatchdogTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        // Release the Siri-remote trackpad stream. `configureWheelTracking()`
        // installs this handler on the SHARED GCController, which outlives the
        // player — left in place it keeps firing (and keeps owning the pad's
        // absolute-value reporting) for the rest of the app's life, once per
        // playback session.
        for controller in GCController.controllers() {
            controller.microGamepad?.dpad.valueChangedHandler = nil
        }
        playerLayer?.pause()
        playerLayer?.stop()
        // KSMEPlayer.shutdown() (called by stop()) does NOT stop its
        // AVSampleBufferAudioRenderer — the Atmos/spatial audio path (see
        // AudioRendererPlayer). Audio already enqueued in that renderer can keep
        // playing for a beat in the background after the layer is gone, which is
        // the "recently watched movie audio keeps playing sometimes" bug (only
        // hits the renderer path, hence 'sometimes'). stop() resets playbackVolume
        // to 1, so do this AFTER it: force the volume to 0 so any lingering
        // renderer output drains silently before the layer deallocates.
        playerLayer?.player.playbackVolume = 0
        playerLayer = nil
        vlcEngine?.stop()
        vlcEngine = nil
        resetNativeDV()
        purgeDVDirectories()
    }

    /// The next-episode line shown on the Up Next / Still Watching cards.
    var upNextLine: String? {
        guard let ep = upNextEpisode else { return nil }
        var line = ep.seasonEpisodeCode
        if let title = ep.title, !title.isEmpty { line += " · \(title)" }
        return line
    }

    // MARK: - Display helpers

    var displayTitle: String { meta.name }

    var episodeLine: String? {
        guard let video = currentVideo, video.season != nil else { return nil }
        var line = video.seasonEpisodeCode
        if let title = video.title { line += " • \(title)" }
        return line
    }

    var viaLine: String? {
        let engine = usingNativeDV ? "Dolby Vision (native)" : "\(engineName) engine"
        return "via \(currentEntry.addonName) · \(currentEntry.stream.displayName) · \(engine)"
    }

    var isShowingError: Bool {
        if case .error = overlay { return true }
        return false
    }

    // MARK: - Initial pre-cache

    /// Holds the very first playback behind the loading backdrop while KSPlayer
    /// fills its forward buffer (the reader keeps downloading while paused, up
    /// to maxBufferDuration). Publishes progress toward `cacheTargetSeconds`,
    /// then releases playback — so the movie opens straight into smooth,
    /// cached video instead of stuttering on a thin buffer.
    private func beginPrecache() {
        guard !hasStartedPlayback else { return }
        playerLayer?.pause()
        loadPhase = .caching
        cacheProgress = 0
        cacheTask?.cancel()
        cacheTask = Task { [weak self] in
            let startedAt = Date()
            var lastAhead: Double = 0
            var lastGrowthAt = Date()
            var growthRate: Double = 0   // smoothed seconds-of-video per second
            while !Task.isCancelled {
                guard let self, let player = self.playerLayer?.player else { return }
                // Anything that sneaks playback back on (async seek callbacks,
                // engine loadState flips) gets re-paused: the hold must hold.
                if player.playbackState == .playing { self.playerLayer?.pause() }
                let ahead = max(player.playableTime - player.currentPlaybackTime, 0)
                let delta = ahead - lastAhead
                growthRate = growthRate * 0.7 + (delta / 0.3) * 0.3
                if delta > 0.5 {
                    lastGrowthAt = Date()
                }
                lastAhead = max(lastAhead, ahead)
                let percent = min(Int(ahead / max(self.cacheTargetSeconds, 1) * 100), 100)
                if percent > self.cacheProgress { self.cacheProgress = percent }
                let reachedTarget = ahead >= self.cacheTargetSeconds
                let reachedEOF = self.duration > 0
                    && player.playableTime >= self.duration - 0.5
                // Download provably outruns playback — no point holding: the
                // buffer keeps deepening while the movie plays. This is what
                // makes fast connections start in a few seconds instead of
                // sitting through the full caching bar.
                let outpacing = ahead >= 6 && growthRate >= 1.2
                // The engine stopped filling with a workable cache built —
                // waiting longer gains nothing.
                let plateaued = ahead >= 6
                    && Date().timeIntervalSince(lastGrowthAt) > 3
                let timedOut = Date().timeIntervalSince(startedAt) > self.cacheMaxWaitSeconds
                if reachedTarget || reachedEOF || outpacing || plateaued || timedOut { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.cacheProgress = 100
            self.loadPhase = nil
            self.hasStartedPlayback = true
            // Straight into the movie — no controls flash, no chrome.
            self.playerLayer?.play()
        }
    }

    // MARK: - Scrub preview thumbnails

    /// Kick off background preview-frame generation, delayed so it never
    /// competes with the initial pre-cache for bandwidth. Skipped for HLS
    /// (packetized playlists don't suit the frame grabber).
    private func startThumbnailsIfNeeded() {
        // Apple TV HD (A8, 2 cores): the preview pass decodes 36 keyframes on a
        // second FFmpeg session while the main decode is already near the CPU
        // ceiling for 1080p — it visibly nicks playback there no matter how
        // "idle" the network is. Skip; the scrub HUD falls back to the time
        // chip, exactly as it already does for HLS and oversized files.
        guard !PerformanceProfile.isLowPower else { return }
        guard !thumbnailsStarted,
              let url = currentURL,
              url.pathExtension.lowercased() != "m3u8" else { return }
        thumbnailsStarted = true
        thumbnailTask = Task { [weak self] in
            // The preview pass opens a SECOND connection and decodes dozens of
            // keyframes — on a huge remux that competes with playback for both
            // bandwidth and the decode budget. The addon-declared size is often
            // missing (Continue Watching resumes carry none), which previously
            // let 16 GB+ files slip through this gate and stutter playback:
            // VERIFY the size with a HEAD request and skip when big or unknown.
            var bytes = self?.currentEntry.stream.behaviorHints?.videoSize
            if bytes == nil { bytes = await Self.remoteContentLength(url) }
            guard let bytes, bytes > 0, bytes <= 8 * 1_073_741_824 else { return }
            // Hold until the playback cache is essentially full (reader idle)
            // so the pass never competes with the initial buffering.
            let waitStart = Date()
            // Gate on a fraction of the cache the session ACTUALLY got, not a
            // fixed 18s. The tier defaults (24s/36s/90s) are only the starting
            // point — the device-memory ceiling then clamps them to 6s on the
            // 2 GB Apple TV HD and 12s on the 3 GB 4K gen-1, so a hardcoded 18
            // was unsatisfiable on exactly the boxes this gate protects. They
            // fell through to the 120s timeout every time and then ran the
            // preview pass against live playback — the opposite of the intent.
            let cap = await MainActor.run { self?.currentOptions?.maxBufferDuration ?? 24 }
            let gate = max(min(18, cap * 0.75), 4)
            while !Task.isCancelled {
                guard let self else { return }
                let ahead = self.buffered - self.position
                if self.hasStartedPlayback && ahead >= gate { break }
                // VLC exposes no ahead-buffer at all (`buffered` is pinned to
                // 0 on that path), so the cache gate above can NEVER pass —
                // every VLC session fell through to the 120s timeout and then
                // ran the decode pass against live playback, which is the exact
                // thing the gate exists to prevent. Give it a fixed settle.
                if self.usingVLC, self.hasStartedPlayback,
                   Date().timeIntervalSince(waitStart) > 20 { break }
                if Date().timeIntervalSince(waitStart) > 120 { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled else { return }
            let thumbnailer = ScrubThumbnailer(url: url)
            self?.thumbnailer = thumbnailer
            let thumbs = await thumbnailer.generate()
            guard !Task.isCancelled, self?.thumbnailer === thumbnailer else { return }
            self?.thumbnailer = nil
            guard !thumbs.isEmpty else { return }
            self?.scrubThumbnails = thumbs.sorted { $0.time < $1.time }
            NSLog("[OrivioPlayer] scrub previews ready: %d frames", thumbs.count)
        }
    }

    /// Nearest preview frame for a scrub target, if generation has finished.
    func thumbnail(at time: Double) -> UIImage? {
        guard !scrubThumbnails.isEmpty else { return nil }
        var best: UIImage?
        var bestDistance = Double.infinity
        for thumb in scrubThumbnails {
            let distance = abs(thumb.time - time)
            if distance < bestDistance {
                bestDistance = distance
                best = thumb.image
            }
        }
        return best
    }

    /// Actual remote file size via a HEAD request (nil when the server won't
    /// say). Used to gate the preview-thumbnail pass.
    private static func remoteContentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
           let bytes = Int64(length), bytes > 0 {
            return bytes
        }
        return nil
    }

    // MARK: - Pull-down info panel

    struct MediaInfoRow: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    struct MediaInfoSection: Identifiable {
        let id = UUID()
        let title: String
        let rows: [MediaInfoRow]
    }

    /// Which pull-down tab is showing: 0 = Details (title/plot/cast),
    /// 1 = File Info (technical). Swipe left/right switches.
    @Published var infoTab = 0

    /// Full metadata for the Details tab. Playback is often started from a
    /// stripped-down record (a Continue Watching card carries only name +
    /// artwork), so the panel would show just "Movie". Re-fetched from the
    /// meta addon (cached, same call the Detail screen makes).
    @Published private(set) var enrichedMeta: MetaItem?
    /// Best available metadata: the enriched fetch when it lands, else
    /// whatever the player was launched with.
    var displayMeta: MetaItem { enrichedMeta ?? meta }

    /// TMDB cast with headshots, so the pull-down's Details tab shows the same
    /// circular cast chips as the Detail page (not a plain text list).
    @Published private(set) var tmdbCast: [TMDBService.CastMember] = []

    private func fetchEnrichedMeta() {
        // TMDB cast (with headshots) for the pull-down — same source as the
        // Detail page's cast row, and cached inside TMDBService.
        Task { [weak self] in
            guard let self else { return }
            if let detail = await TMDBService.detail(imdbID: self.meta.id, type: self.meta.type) {
                self.tmdbCast = detail.cast
            }
        }
        // Already complete (launched from a fully-loaded Detail screen)?
        // A series additionally needs its episode list — the in-player
        // Episodes panel and auto-next read it from the enriched meta.
        let needsEpisodes = meta.isSeries && (meta.videos ?? []).isEmpty
        if meta.description != nil, meta.cast?.isEmpty == false,
           meta.genres?.isEmpty == false, !needsEpisodes {
            return
        }
        Task { [weak self] in
            guard let self,
                  let addon = self.addonManager.metaAddon(for: self.meta.type, id: self.meta.id),
                  let full = try? await StremioAPI.meta(addon: addon, type: self.meta.type, id: self.meta.id)
            else { return }
            self.enrichedMeta = full
        }
    }

    /// Swipe-down on the bare video (Infuse gesture) opens the info sheet.
    /// Inert until playback is running — a stray downward touch during the
    /// loading/caching hold must never queue the panel up behind the loading
    /// screen (it would greet the viewer the moment the movie appeared).
    func showInfoPanel() {
        guard hasStartedPlayback else { return }
        guard overlay == .none || overlay == .pauseInfo else { return }
        hideControlsTask?.cancel()
        infoTab = 0
        overlay = .info
    }

    func dismissInfoPanel() {
        guard overlay == .info else { return }
        overlay = .none
    }

    /// Snapshot of everything the pull-down shows: file, video, audio,
    /// subtitle and live performance details, assembled from the running
    /// player. Built on demand — the panel is transient.
    func mediaInfoSections() -> [MediaInfoSection] {
        var sections: [MediaInfoSection] = []
        let player = playerLayer?.player

        var file: [MediaInfoRow] = []
        file.append(.init(label: "Source", value: currentEntry.addonName))
        let filename = currentEntry.stream.title ?? currentEntry.stream.displayName
        file.append(.init(label: "Name", value: filename))
        if let url = currentURL, !url.pathExtension.isEmpty {
            file.append(.init(label: "Container", value: url.pathExtension.uppercased()))
        }
        file.append(.init(label: "Engine", value: engineName))
        if let read = player?.dynamicInfo?.bytesRead, read > 0 {
            file.append(.init(label: "Downloaded", value: ByteCountFormatter.string(fromByteCount: read, countStyle: .file)))
        }
        sections.append(.init(title: "File", rows: file))

        if let track = player?.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? player?.tracks(mediaType: .video).first {
            var video: [MediaInfoRow] = []
            video.append(.init(label: "Codec", value: Self.codecName(track)))
            let size = track.naturalSize
            if size.width > 0 {
                video.append(.init(label: "Resolution", value: "\(Int(size.width)) × \(Int(size.height))"))
            }
            if track.nominalFrameRate > 0 {
                video.append(.init(label: "Frame Rate", value: String(format: "%.3g fps", track.nominalFrameRate)))
            }
            let bitrate = player?.dynamicInfo?.videoBitrate ?? Int(track.bitRate)
            if bitrate > 0 {
                video.append(.init(label: "Bitrate", value: String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)))
            }
            if track.bitDepth > 0 {
                video.append(.init(label: "Bit Depth", value: "\(track.bitDepth)-bit"))
            }
            if usingNativeDV {
                video.append(.init(label: "HDR", value: "Dolby Vision (native output)"))
            } else if track.dovi != nil {
                video.append(.init(label: "HDR", value: "Dolby Vision → HDR10"))
            } else if let range = track.formatDescription?.dynamicRange, range != .sdr {
                // HDR10 / HLG — anything beyond SDR is worth surfacing.
                video.append(.init(label: "HDR", value: range.description))
            }
            sections.append(.init(title: "Video", rows: video))
        }

        if let track = player?.tracks(mediaType: .audio).first(where: \.isEnabled)
            ?? player?.tracks(mediaType: .audio).first {
            var audio: [MediaInfoRow] = []
            audio.append(.init(label: "Codec", value: Self.codecName(track)))
            let channels = Self.channelCount(track)
            if channels > 0 {
                audio.append(.init(label: "Channels", value: Self.channelLabel(channels)))
            }
            if let code = track.languageCode,
               let language = Locale.current.localizedString(forLanguageCode: code) {
                audio.append(.init(label: "Language", value: language))
            }
            let bitrate = player?.dynamicInfo?.audioBitrate ?? Int(track.bitRate)
            if bitrate > 0 {
                audio.append(.init(label: "Bitrate", value: String(format: "%.0f kbps", Double(bitrate) / 1_000)))
            }
            let count = player?.tracks(mediaType: .audio).count ?? 1
            if count > 1 {
                audio.append(.init(label: "Tracks", value: "\(count)"))
            }
            sections.append(.init(title: "Audio", rows: audio))
        }

        var subs: [MediaInfoRow] = []
        let active = subtitleOptions.first { $0.id == selectedSubtitleID }?.displayName ?? "Off"
        subs.append(.init(label: "Active", value: active))
        let available = max(subtitleOptions.count - 1, 0)   // minus the "Off" row
        subs.append(.init(label: "Available", value: available == 0 ? "None" : "\(available)"))
        sections.append(.init(title: "Subtitles", rows: subs))

        if let info = player?.dynamicInfo {
            var perf: [MediaInfoRow] = []
            if info.displayFPS > 0 {
                perf.append(.init(label: "Display", value: String(format: "%.1f fps", info.displayFPS)))
            }
            perf.append(.init(label: "Dropped Frames", value: "\(info.droppedVideoFrameCount)"))
            perf.append(.init(label: "AV Sync", value: String(format: "%+.0f ms", info.audioVideoSyncDiff * 1000)))
            sections.append(.init(title: "Performance", rows: perf))
        }

        return sections
    }

    private static func codecName(_ track: any MediaPlayerTrack) -> String {
        guard let description = track.formatDescription else { return track.name }
        return description.mediaSubType.description
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            .uppercased()
    }

    static func channelCount(_ track: any MediaPlayerTrack) -> Int {
        guard let asbd = track.formatDescription?.audioStreamBasicDescription else { return 0 }
        return Int(asbd.mChannelsPerFrame)
    }

    static func channelLabel(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1 Surround"
        case 8: return "7.1 Surround"
        default: return "\(count) channels"
        }
    }
}

// MARK: - KSPlayerLayerDelegate

extension PlayerViewModel: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        // Already exiting: SWALLOW the callback — do not touch the layer.
        // Calling pause()/stop() here recursed fatally: pause() sets the
        // layer's state, whose willSet re-fires this delegate synchronously,
        // which called pause() again… until the stack blew (the crash on
        // every exit-during-load). Swallowing is also all the audio fix
        // needs: prepareForExit() already paused (clearing the layer's
        // internal isAutoPlay, so it won't self-start on ready), and the
        // only play() on ready lives in OUR .readyToPlay branch below —
        // which this return keeps from running. teardown() stops the layer
        // for real once the cover is dismissed.
        if isExiting { return }
        switch state {
        case .initialized, .preparing:
            isBuffering = true
        case .readyToPlay:
            // The stream opened successfully — the load is alive, so disarm
            // the timeout watchdog.
            markLoadStarted()
            // The underlying player (and its UIView) can only have changed on
            // ready (initial open or engine failover) — refresh the video host
            // HERE, not on every routine buffering transition.
            videoRefreshID = UUID()
            refreshEngineName()
            // Open-timing breakdown (visible in Console.app, filter "NuvioPlayer")
            // so slow debrid opens can be attributed: connect vs FFmpeg
            // avformat open vs stream-info probe vs first decoded frame.
            if let started = loadStartedAt, let opts = currentOptions {
                let total = Date().timeIntervalSince(started)
                // Each field is an absolute CACurrentMediaTime stamp; a phase
                // is only meaningful when both of its endpoints were recorded.
                func delta(_ from: Double, _ to: Double) -> Double {
                    (from > 0 && to > from) ? to - from : 0
                }
                NSLog("[OrivioPlayer] ready engine=%@ total=%.2fs connect=%.2fs open=%.2fs find=%.2fs firstFrame=%.2fs",
                      engineName, total,
                      delta(opts.tcpStartTime, opts.tcpConnectedTime),
                      delta(opts.dnsStartTime, opts.openTime),
                      delta(opts.openTime, opts.findTime),
                      delta(opts.findTime, opts.readyTime))
                loadStartedAt = nil
            }
            isBuffering = false
            duration = layer.player.duration
            // DV playlist grows as the remux writes — pin the timeline to the
            // real duration learned from the FFmpeg session, and keep that
            // session's chapters (the playlist has none).
            if usingNativeDV, dvFullDuration > 0 { duration = dvFullDuration }
            clock.duration = duration
            // Now the bitrate is knowable, size a byte-target read-ahead cache.
            applyBufferSizeTarget(player: layer.player)
            // Engine always letterboxes (aspect-fit); zoom/stretch happen as a
            // SwiftUI transform driven by the natural size published here.
            layer.player.contentMode = .scaleAspectFit
            videoNaturalSize = layer.player.naturalSize
            if !usingNativeDV { chapters = layer.player.chapters }
            applyNativeDisplayCriteria()
            maybeStartNativeDV()
            if playbackSpeed != 1 {
                layer.player.playbackRate = playbackSpeed
            }
            let willPrecache = !hasStartedPlayback
            loadTracks()
            startThumbnailsIfNeeded()

            let resume = pendingResume ?? 0
            let meaningfulResume = resume > 30 && (duration == 0 || resume < duration - 30)

            if willPrecache {
                // Auto-resume at the saved position (if any) and hold playback
                // to build the initial cache — no blocking prompt. A "Start
                // Over" button in the controls bar (only shown when this title
                // had saved progress) lets the viewer jump back to 0 anytime.
                if cacheTargetSeconds <= 0 {
                    // No hold — straight into the movie.
                    //
                    // The seek and the play() are MUTUALLY EXCLUSIVE, and that
                    // matters enormously. `KSPlayerLayer.seek(autoPlay: true)`
                    // already calls play() from its completion handler, so an
                    // extra play() here doesn't just duplicate it — it runs
                    // SYNCHRONOUSLY, inside the seek. KSMEPlayer.seek sets
                    // playbackState = .seeking (which pauses both outputs while
                    // the flush runs) and our play() stomped that straight back
                    // to .playing, restarting audio + video mid-seek. When the
                    // seek then landed it called audioOutput.flush() — audio
                    // only — so audio re-primed at the resume point while the
                    // video output kept stale pre-seek frames against a timebase
                    // that had jumped forward. That is the "resumes, then the
                    // picture freezes while the audio keeps playing" bug.
                    //
                    // It only showed up on BIG files because the race window is
                    // the duration of the seek: a small file's seek completes in
                    // milliseconds, while a large high-bitrate long-GOP file
                    // needs a range request and a keyframe hunt.
                    if meaningfulResume {
                        // Remember the target for the whole session BEFORE the
                        // seek: `position` is still ~0 until it lands, so a
                        // failover in that window used to restart the next
                        // source from the beginning.
                        sessionResumeFloor = max(sessionResumeFloor, resume)
                        playerLayer?.seek(time: resume, autoPlay: true) { [weak self] finished in
                            guard let self else { return }
                            // Cleared either way: leaving it set would make a
                            // later `.readyToPlay` (engine failover) yank the
                            // viewer back here after they'd scrubbed elsewhere.
                            self.pendingResume = nil
                            // Engine refused the seek (not seekable) — don't
                            // leave the session parked on a paused frame.
                            if !finished { self.playerLayer?.play() }
                        }
                    } else {
                        pendingResume = nil
                        playerLayer?.play()
                    }
                    loadPhase = nil
                    hasStartedPlayback = true
                } else {
                    if meaningfulResume {
                        playerLayer?.seek(time: resume, autoPlay: false) { _ in }
                    }
                    pendingResume = nil
                    beginPrecache()
                }
            } else {
                // Engine failover / source switch / episode switch mid-session.
                // With a meaningful resume position, seek there and autoplay.
                // Otherwise (a fresh, unwatched episode starts at 0) start
                // playing outright — play(episode:) paused the layer before the
                // switch, so without this an unwatched episode set up its stream
                // but never left pause, spinning on the loading state forever.
                if resume > 5, duration == 0 || resume < duration - 30 {
                    // `resume` is an ABSOLUTE source time, but a native-DV
                    // session's layer timeline is the local playlist, whose t=0
                    // is `dvTimeOffset` into the source. Seeking the raw value
                    // there would land dvTimeOffset seconds too deep (or past
                    // the written window entirely). Everything else in the app
                    // goes through engineSeek, which does this translation —
                    // this call predates that and didn't.
                    let target = usingNativeDV ? max(resume - dvTimeOffset, 0) : resume
                    layer.seek(time: target, autoPlay: true) { _ in }
                } else {
                    layer.play()
                }
                pendingResume = nil
                if overlay == .none { showControls() }
            }
        case .buffering:
            isPlaying = true
            isBuffering = true
            pausedAt = nil
        case .bufferFinished:
            isPlaying = true
            isBuffering = false
            pausedAt = nil
            // Some engines (notably the FFmpeg path) go straight to playing
            // without a `.readyToPlay`, so dismiss the loading backdrop here
            // too — unless the initial pre-cache is still holding playback.
            // Disarm the load watchdog for the same reason: it is armed by
            // `load()` and only ever disarmed in `.readyToPlay`, so a stream
            // that reached "buffer finished" without one would be declared
            // dead and failed over 30s into perfectly good playback.
            markLoadStarted()
            if loadPhase != .caching { hasStartedPlayback = true }
        case .paused:
            isPlaying = false
            isBuffering = false
            // First transition into pause stamps the clock for the
            // stale-connection recovery; later delegate re-fires keep it.
            markPaused()
        case .playedToTheEnd:
            isPlaying = false
            // Post-play: queue next episode or show the end overlay instead of
            // leaving the user on a frozen last frame.
            handlePlayedToEnd()
        case .error:
            isPlaying = false
            isBuffering = false
            cacheTask?.cancel()
            loadPhase = nil
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        // Native-DV: the playlist timeline starts at dvTimeOffset — map every
        // engine-relative time back to the absolute source timeline so
        // position/progress/subtitles/auto-next all keep working unchanged.
        let currentTime = usingNativeDV ? currentTime + dvTimeOffset : currentTime
        // Catch-all: the clock is advancing, so playback has definitely begun —
        // clear the loading backdrop even if no ready/buffer-finished state
        // fired. Skipped while the initial pre-cache is holding playback.
        if currentTime > 0, !hasStartedPlayback, loadPhase != .caching {
            hasStartedPlayback = true
            loadPhase = nil
        }
        // A clock that is advancing is proof the load is alive, whatever states
        // the engine did or didn't report — never let the 30s load watchdog
        // fail over a stream that is visibly playing.
        if currentTime > 0 { markLoadStarted() }
        if currentTime.isFinite { markPlaybackProgressed(currentTime: currentTime) }
        if currentTime.isFinite { position = currentTime }
        if totalTime.isFinite, totalTime > 0, !usingNativeDV { duration = totalTime }
        buffered = layer.player.playableTime + (usingNativeDV ? dvTimeOffset : 0)
        // Publish to the clock only on meaningful change (~2Hz) so the few
        // time-displaying views re-render gently instead of every frame.
        if abs(clock.position - position) >= 0.4 { clock.position = position }
        if clock.duration != duration { clock.duration = duration }
        if abs(clock.buffered - buffered) >= 1.0 { clock.buffered = buffered }
        // Cue lookup walks the subtitle list linearly from the START each
        // call — late in a long movie that's thousands of iterations. Skip it
        // entirely with subtitles off, and throttle to ~8 Hz with them on
        // (well inside subtitle-timing tolerance).
        if subtitleModel.selectedSubtitleInfo != nil,
           abs(currentTime - lastSubtitleSearchAt) >= 0.12 {
            lastSubtitleSearchAt = currentTime
            _ = subtitleModel.subtitle(currentTime: currentTime)
        }
        // naturalSize can still be zero at readyToPlay (the AVPlayer engine
        // fills it in a later load callback) — without this the aspect
        // transform would stay identity for the whole session.
        if videoNaturalSize == .zero {
            let size = layer.player.naturalSize
            if size != .zero { videoNaturalSize = size }
        }
        updateSkipIntro()
        saveProgressThrottled()
        maybeArmAutoNext()
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard let error else { return }
        // A failure that lands during/after exit must not fail over: that
        // would load() a fresh source into a NEW layer behind the dismissed
        // player — orphaned playback with no UI to stop it.
        guard !isExiting else { return }
        // A far USER seek can make an otherwise-working source emit a finish
        // error (the engine rejected the jumped-to byte range) — that's a
        // recoverable seek fault, NOT a dead source, so don't abandon the source
        // the user is happily watching. Snap back to a spot we've already
        // buffered and resume on the SAME source. Only if it errors AGAIN (the
        // recovery seek is in flight / the fault wasn't seek-related) do we fall
        // through to real failover.
        if let last = lastUserSeekAt, Date().timeIntervalSince(last) < 6,
           hasStartedPlayback, !seekRecoveryInFlight {
            seekRecoveryInFlight = true
            lastUserSeekAt = nil
            let safe = max(0, min(position, buffered > 2 ? buffered - 2 : position))
            showToast("Couldn't skip that far — resuming")
            position = safe
            clock.position = safe
            engineSeek(to: safe, autoPlay: true)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.seekRecoveryInFlight = false
            }
            return
        }
        // KSPlayerLayer already retried with the FFmpeg engine before this
        // fires, so a surviving error means both engines rejected the stream.
        // Don't dead-end on it — fail over to the next source automatically
        // (fetching the source list first if this session started from a bare
        // Continue Watching URL, which also covers expired debrid links).
        attemptFailover(afterError: error)
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}
