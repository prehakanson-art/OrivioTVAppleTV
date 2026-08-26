import AVFoundation
import AVKit
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
        case dvDirectAudio(Int32) // DVSampleEngine audio stream index
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
/// One display-mode switch per app launch — first wins, held for the app's
/// lifetime, never renegotiated.
///
/// Every HDMI renegotiation is a fresh chance for a wedge-prone panel to
/// mis-handshake into the solid-grey state (recoverable only by an input
/// toggle on this user's chain). Titles used to flip the mode in, out, and
/// between rates several times a session. Pinning the first successful
/// criteria removes every subsequent switch: later playbacks reuse the
/// negotiated mode, exits hold it, and the UI simply renders inside it.
/// The OS still reverts when the app backgrounds or dies — that single
/// unavoidable event is the only remaining exposure.
enum SessionDisplayMode {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pinned = false
    nonisolated(unsafe) private static var observing = false

    /// The pin is per FOREGROUND STINT, not per process: when the app
    /// backgrounds, tvOS has already put the display back in its home format
    /// on its own terms, so clearing `preferredDisplayCriteria` there is
    /// invisible — no renegotiation happens on a backgrounded app. Clearing
    /// the flag lets the next foreground session negotiate its mode fresh
    /// instead of inheriting a stale pin that no longer matches the panel.
    private static func installBackgroundReleaseIfNeeded() {
        lock.lock()
        let install = !observing
        if install { observing = true }
        lock.unlock()
        guard install else { return }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            UIApplication.shared.ks_keyWindow?.avDisplayManager.preferredDisplayCriteria = nil
            lock.lock(); pinned = false; lock.unlock()
            NSLog("[OrivioDisplay] backgrounded — pin cleared (display already reverted by tvOS)")
        }
    }

    /// Apply `criteria` only if nothing was pinned this launch. Lock-based
    /// (not actor-isolated): callers arrive from KSPlayer's setup thread AND
    /// from the main actor, and a main.sync hop from main would deadlock.
    static func applyOnce(_ criteria: AVDisplayCriteria,
                          via manager: AVDisplayManager) -> Bool {
        lock.lock()
        let first = !pinned
        if first { pinned = true }
        lock.unlock()
        guard first else { return false }
        installBackgroundReleaseIfNeeded()
        if Thread.isMainThread {
            manager.preferredDisplayCriteria = criteria
        } else {
            DispatchQueue.main.async { manager.preferredDisplayCriteria = criteria }
        }
        NSLog("[OrivioDisplay] session display mode pinned (first and only switch this launch)")
        // GROUND TRUTH: preferredDisplayCriteria is a request; whether the
        // display actually changed is only readable from UIScreen once the
        // handshake settles. 24 here proves the 23.976 mode took; 60 proves
        // the request is being ignored — the decisive datum for the judder
        // investigation, gathered without the TV's menus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSLog("[OrivioDisplay] UIScreen reports %ld fps after the switch",
                  UIScreen.main.maximumFramesPerSecond)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NSLog("[OrivioDisplay] UIScreen reports %ld fps (settled)",
                  UIScreen.main.maximumFramesPerSecond)
        }
        return true
    }
}

final class NuvioPlayerOptions: KSOptions {
    /// Decoded-frame queue depth, budgeted in BYTES instead of frames.
    ///
    /// KSPlayer's default is a flat 16 frames regardless of frame size. A
    /// 4K 10-bit CVPixelBuffer is ~25 MB, so on a 4K HDR stream the FFmpeg
    /// engine quietly held ~400 MB of DECODED frames — on top of the packet
    /// cache — which on the 3 GB gen-1 4K is most of the gap between
    /// "playing" and the ~1.2-1.4 GB RSS in its jetsam kill reports. The
    /// queue only exists to absorb decode jitter; a few frames of cushion do
    /// that (mpv runs ~3), so size it to a per-tier byte budget and let
    /// SMALL frames keep the deep queue while big ones get a shallow one:
    /// 1080p SDR still gets 16, 4K HDR on the A10X gets ~4 (~100 MB).
    override func videoFrameMaxCount(fps: Float, naturalSize: CGSize, isLive: Bool) -> UInt8 {
        if isLive { return 4 }   // KSPlayer's own live default
        let budgetBytes: Double
        if PerformanceProfile.isLowPower { budgetBytes = Double(64 << 20) }
        else if PerformanceProfile.isMidPower { budgetBytes = Double(112 << 20) }
        else { budgetBytes = Double(400 << 20) }   // 4 GB boxes: effectively stock
        // ~3 bytes/pixel: 4:2:0 biplanar at 10-bit (16-bit storage). Assumes
        // the worst case rather than sniffing bit depth — an 8-bit stream
        // just gets a slightly deeper queue than strictly needed.
        let area = max(naturalSize.width * naturalSize.height, 1920 * 1080)
        let frames = budgetBytes / (Double(area) * 3)
        return UInt8(min(max(frames.rounded(.down), 4), 16))
    }

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
        // THE INFUSE POLICY. Dolby Vision sessions may request the DV mode by
        // default (`nativeDV`) — that's the point of playing DV. Everything
        // else (HDR10/SDR via this path) stays hands-off unless the user opts
        // in with "Match content display mode". The grey-screen wedge is
        // prevented not by refusing the switch IN but by never switching BACK
        // while the app is alive: the pin holds for the whole foreground
        // stint (releaseDisplayForExit is a no-op) and tvOS performs the one
        // unavoidable revert invisibly when the app backgrounds.
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
        // ALWAYS match the content's rate on the one pinned switch (with the
        // 23.976 AFR bias: FFmpeg reports film as 23.97/23.98/24.0 but nearly
        // all "24fps" releases are 24000/1001). The rate switch was never the
        // wedge — the REVERT was, and no in-app revert exists anymore. A 24fps
        // movie in a 60Hz envelope is 3:2 pulldown judder, the thing a real
        // player exists to avoid.
        var rate = refreshRate
        if (23.5...24.2).contains(rate) { rate = 23.976 }
        // The panel is being driven TO the content's cadence, so there is no
        // 3:2 pulldown to soften — leaving the softening on made
        // videoClockSync fight a cadence that isn't there. Set BEFORE the
        // de-dup guard so it's right even on the early return below.
        pulldown60Hz = false
        guard lastAppliedDynamicRange != target.rawValue
            || lastAppliedRefreshRate != rate else { return }
        lastAppliedDynamicRange = target.rawValue
        lastAppliedRefreshRate = rate
        guard let criteria = AVDisplayCriteria(refreshRate: rate, videoDynamicRange: target.rawValue)
        else { return }
        guard SessionDisplayMode.applyOnce(criteria, via: displayManager) else { return }
        // The exit sequencing needs to know a real switch was requested this
        // SESSION (not just whether the toggle is on — native-DV sessions
        // switch with the toggle off), so it can wait out the switch-back
        // before tearing the cover down.
        onDisplayCriteriaApplied?()
    }

    /// Fired when a display-mode switch is actually requested. Set by
    /// PlayerViewModel.load(); hops to main there.
    var onDisplayCriteriaApplied: (() -> Void)?

    /// SUPPRESSED ON PURPOSE. KSPlayer clears preferredDisplayCriteria from
    /// the player layer's deinit, via an async hop to main — a SECOND display
    /// renegotiation, landing at a moment nobody controls, typically while the
    /// view hierarchy is being torn down and right after the app has already
    /// requested its own switch back. Two handshakes overlapping a surface
    /// teardown is the recipe for the grey/miscoloured screen that only a TV
    /// power-cycle clears (KSPlayer's own comment notes rapid changes leave
    /// isDisplayModeSwitchInProgress stuck true, and they stopped checking it).
    ///
    /// The app owns this lifecycle instead: exactly one reset, at a moment of
    /// its choosing, behind a black cover, with time to settle before anything
    /// else changes. See PlayerViewModel.prepareForExit().
    override func playerLayerDeinit() {}

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
        // Position at arm time: the watchdog's whole premise is "nothing is
        // moving". An AVPlayerItem recycle (and some seeks) leave isBuffering
        // set while playback is visibly ADVANCING — the flag lies, the clock
        // doesn't. Firing on the flag alone shot down a healthy native-DV
        // session 20s after a successful recycle, position marching the whole
        // time.
        let armedPosition = position
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            // Re-check currentLoadStarted at FIRE time too: if a source switch
            // began after arming, the stream is opening (not stalled) and the
            // 30s load watchdog owns that phase — a slow debrid open must not
            // be killed at 20s by a stall check armed for the previous stream.
            guard !Task.isCancelled, let self,
                  self.isBuffering, self.currentLoadStarted,
                  !self.isExiting, !self.isFailingOver else { return }
            // The clock moved since arming → not a stall, whatever the flag
            // says. Re-arm and keep watching.
            if abs(self.position - armedPosition) > 2 {
                self.updateStallWatchdog()
                return
            }
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
    /// The direct Dolby Vision sample-feed engine (no AVPlayer, no HLS, no
    /// CoreMedia retention) — the Infuse architecture. Mutually exclusive
    /// with the other engines while active.
    private(set) var dvDirectEngine: DVSampleEngine?
    var usingDVDirect: Bool { dvDirectEngine != nil }
    /// The UIView the active engine renders into (KSPlayer's player view,
    /// VLC's drawable, or the DV sample layer), handed to PlayerVideoView.
    var activeVideoView: UIView? {
        isExiting ? nil : (dvDirectEngine?.videoView ?? vlcEngine?.videoView ?? playerLayer?.player.view)
    }
    let subtitleModel = SubtitleModel()

    var onDismiss: (() -> Void)?

    // MARK: - Engine-agnostic transport (branch KS ↔ VLC)

    private func enginePlay() {
        if let dvDirectEngine { dvDirectEngine.play() }
        else if let vlcEngine { vlcEngine.play() } else { playerLayer?.play() }
    }
    private func enginePause() {
        if let dvDirectEngine { dvDirectEngine.pause() }
        else if let vlcEngine { vlcEngine.pause() } else { playerLayer?.pause() }
    }
    private func engineSeek(to seconds: Double, autoPlay: Bool) {
        // Direct sample feed: its timeline IS the source timeline — no
        // window, no offset, no re-remux. Seeks are plain.
        if let dvDirectEngine {
            dvDirectEngine.seek(to: seconds)
            if autoPlay { dvDirectEngine.play() }
            return
        }
        // Native-DV session: the player's timeline is the local playlist,
        // which starts at dvTimeOffset and only extends as far as the remux
        // has written. In-window seeks translate; out-of-window seeks restart
        // the remux at the target (the source supports range requests).
        if usingNativeDV {
            let windowEnd = dvRemuxFinished ? .infinity : dvTimeOffset + dvWrittenSeconds
            let windowStart = dvTimeOffset + dvPrunedThrough
            if seconds < windowStart - 2 || seconds > windowEnd + 4 {
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

    /// What the native remux path is being used FOR. The machinery is shared
    /// — remux to fMP4, serve over loopback, hand AVPlayer the bitstream — but
    /// the reason differs, and every label the user sees has to say which.
    enum NativePassthrough {
        case dolbyVision
        /// HDR10+ dynamic metadata, which lives as a per-frame SEI inside the
        /// video bitstream. A stream copy preserves it; the FFmpeg/Metal path
        /// decodes it away. Same remux, different payload.
        case hdr10Plus

        var label: String { self == .dolbyVision ? "Dolby Vision" : "HDR10+" }
        var stage: String { self == .dolbyVision ? "Dolby Vision" : "HDR10+" }
    }

    /// Which payload the current/attempted native session is carrying.
    private(set) var nativeKind: NativePassthrough = .dolbyVision

    /// True while playback runs off the tagged local playlist (real DV or
    /// HDR10+ out through Apple's pipeline). See DVRemuxer for the machinery.
    @Published private(set) var usingNativeDV = false

    /// HDR10+ dynamic metadata found in the source by the header probe.
    @Published private(set) var hasHDR10Plus = false
    private var dvRemuxer: DVRemuxer?
    /// Absolute source time (seconds) that the local playlist's t=0 maps to.
    private var dvTimeOffset: Double = 0
    /// The loopback playlist the native session is playing — kept so the
    /// memory guard can RECYCLE the AVPlayerItem (reload the same playlist at
    /// the current position) instead of abandoning DV outright.
    private var dvPlaylistURL: URL?
    private var lastDVRecycleAt = Date.distantPast
    /// Previous guard-tick footprint, for the predictive step-down slope.
    private var lastGuardSample: Double = 0
    /// Seconds of content written past dvTimeOffset (the seekable window).
    private var dvWrittenSeconds: Double = 0
    /// Seconds pruned off the FRONT of that window — already-watched segments
    /// whose files were deleted to bound disk use. A seek behind this point
    /// re-remuxes instead of requesting a file that no longer exists.
    private var dvPrunedThrough: Double = 0
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
        NSLog("[OrivioPlayer] PlayerViewModel deinit")
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
        // Compatibility mode: never leave the plain decode path. The HDR10-
        // mapped Metal output is the most forgiving pipeline this player has.
        if activeMode == .compatibility {
            if playerLayer?.player.tracks(mediaType: .video)
                .first(where: \.isEnabled)?.dovi != nil, !dvAttempted {
                dvAttempted = true
                decisionLog.record("Dolby Vision", "HDR10-mapped decode",
                                   because: "Compatibility mode skips the native-DV remux")
            }
            return
        }
        // MEMORY PRECONDITION. The native pipeline needs ~400-500 MB of
        // headroom, and the in-process retention it accrues is PROCESS-scoped
        // (survives AVPlayerItem recycling — proven live). Without this gate,
        // a memory-guard step-down was immediately followed by a fresh DV
        // attempt on the same ballasted process: an infinite DV/HDR10
        // alternation that ratcheted the footprint up each cycle until
        // jetsam. Starting only from a lean process makes the guard's
        // step-down stick for the session while leaving DV fully available
        // to the next fresh launch — and self-heals if memory ever comes
        // back down.
        guard Self.memoryFootprintMB() < 850 else {
            if !dvAttempted {
                dvAttempted = true
                decisionLog.record("Dolby Vision", "HDR10-mapped decode",
                                   because: "not enough free memory for the native pipeline this session")
                // Tell the viewer HOW to get DV back — the ballast a spent DV
                // session leaves behind survives exiting the player (it's
                // process-scoped), so without this hint DV just silently
                // never returns until the next app launch and it reads as
                // broken rather than recoverable.
                showToast("Dolby Vision off — restart the app to re-enable")
            }
            return
        }
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
        // Profile 5/8 always; Profile 7 only with the libdovi 7→8.1 conversion
        // enabled. Fidelity mode turns the conversion on regardless of the
        // tier default — its contract is "never silently downgrade".
        let p7ok = activeMode == .fidelity || settings.dolbyVisionProfile7
        guard let profile = track?.dovi?.dv_profile else { return }
        guard profile == 5 || profile == 8 || (profile == 7 && p7ok) else {
            if profile == 7, !dvAttempted {
                dvAttempted = true
                decisionLog.record("Dolby Vision", "HDR10 base layer",
                                   because: "Profile 7 conversion is off (Settings → Playback)")
            }
            return
        }

        dvAttempted = true
        decisionLog.record(
            "Dolby Vision",
            profile == 7 ? "Native DV (Profile 7 → 8.1)" : "Native DV (Profile \(Int(profile)))",
            because: profile == 7
                ? (activeMode == .fidelity && !settings.dolbyVisionProfile7
                    ? "Fidelity mode converts Profile 7 even where the tier default is off"
                    : "dual-layer P7 converted so Apple's pipeline accepts it")
                : "display supports Dolby Vision; remuxing for Apple's pipeline"
        )
        NSLog("[OrivioDV] DV profile %d detected — starting background remux", Int(profile))
        // Persisted, so "was this title actually the heavy dual-layer P7
        // path?" is answerable after the fact instead of needing a live log.
        Self.dvTrail("DV profile \(Int(profile)) detected — P7 conversion \(p7ok ? "enabled" : "off")")
        startDVRemux(from: max(nativeRemuxStartTarget - 2, 0), isRestart: false)
    }

    /// Called from readyToPlay right after the DV attempt. If the probe already
    /// found HDR10+ and DV declined this title, this is where HDR10+ picks it
    /// up — the tracks are real by now, which is what the decision needs.
    private func maybeStartNativeHDR10PlusAfterTracks() {
        guard hasHDR10Plus, !usingNativeDV, dvRemuxer == nil else { return }
        maybeStartNativeHDR10Plus()
    }

    /// What playback actually falls back TO when the native path fails —
    /// different payloads degrade to different things, and the panel must not
    /// call an HDR10+ fallback "HDR10-mapped decode from Dolby Vision".
    private var nativeFallbackLabel: String {
        nativeKind == .dolbyVision ? "HDR10-mapped decode" : "HDR10 (static metadata only)"
    }

    // MARK: - DV-first (direct native start)

    /// URLs already given a DV-first attempt this session — pass or fail,
    /// they don't get a second preflight (failures fall back to the normal
    /// engine path, which still has the mid-play switch as an upgrade).
    private var dvFirstTried: Set<String> = []
    private var dvFirstTask: Task<Void, Never>?

    /// Cheap synchronous gates for the direct-DV start.
    private func shouldTryDVFirst(url: URL) -> Bool {
        guard settings.nativeDolbyVision,
              effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              !url.isFileURL,
              DynamicRange.availableHDRModes.contains(.dolbyVision),
              Self.memoryFootprintMB() < 850,
              !dvFailedURLs.contains(url.absoluteString),
              !dvFirstTried.contains(url.absoluteString)
        else { return false }
        // A native-friendly container plays DV through AVPlayer as-is — the
        // remux is for the MKV world.
        let ext = url.pathExtension.lowercased()
        guard ext != "mp4", ext != "m4v", ext != "mov", ext != "m3u8" else { return false }
        // Title hint: debrid stream names carry the DV marker. No hint means
        // no preflight cost — the title still gets DV via the mid-play switch.
        let haystack = "\(currentEntry.stream.name ?? "") \(currentEntry.stream.title ?? "") \(currentEntry.stream.description ?? "")".lowercased()
        return haystack.range(of: "\\b(dv|dovi|dolby)\\b", options: .regularExpression) != nil
    }

    /// Probe the header; if it's a remuxable DV file, start the remux and hand
    /// AVPlayer the playlist directly. Anything else falls back to the normal
    /// engine path.
    private func startDVFirst(entry: StreamEntry, url: URL) {
        dvFirstTried.insert(url.absoluteString)
        currentURL = url
        loadPhase = .loading
        NSLog("[OrivioDV] DV-first preflight: %@", url.host ?? "?")
        dvFirstTask?.cancel()
        dvFirstTask = Task { [weak self] in
            let probe = await StreamProbe.inspect(
                url: url.absoluteString,
                needsStyledASS: false, needsHDR10Plus: false,
                needsDolbyVision: true, timeoutSeconds: 5
            )
            guard let self, !Task.isCancelled, !self.isExiting else { return }
            let p7ok = self.activeMode == .fidelity || self.settings.dolbyVisionProfile7
            // profile 0 = plain HEVC (HDR10/HDR10+/SDR) — the engine plays it
            // natively with every bitstream SEI intact, so a DV-hinted title
            // that turns out non-DV still direct-starts instead of falling to
            // the decode path.
            let profile = probe.dvProfile ?? 0
            let dvOK = profile == 0 || profile == 5 || profile == 8 || (profile == 7 && p7ok)
            guard probe.hasHEVC, dvOK,
                  probe.hasEligibleAudio,
                  probe.durationSeconds > 60,
                  self.activeMode != .compatibility
            else {
                Self.dvTrail("DV-first fell back to normal load (profile=\(probe.dvProfile.map(String.init) ?? "none"), audioOK=\(probe.hasEligibleAudio))")
                self.load(entry: entry)
                return
            }
            Self.dvTrail("DV-first: profile \(profile == 0 ? "HEVC/\(probe.isPQ ? "HDR10" : "SDR")" : String(profile)), \(Int(probe.durationSeconds))s — direct native start")
            self.dvAttempted = true
            self.nativeKind = .dolbyVision
            let resume = max(max(self.pendingResume ?? 0, self.sessionResumeFloor), 0)

            // TIER 1: the sample-feed engine — no AVPlayer, no HLS, no
            // CoreMedia retention; the app owns (and bounds) every buffer.
            // Its failure falls to TIER 2, the remux+AVPlayer path.
            // Downmix in-engine when the route can't use multichannel —
            // see DVSampleEngine.downmixToStereo.
            let spatial = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.isSpatialAudioEnabled }
            let engine = DVSampleEngine(
                input: url.absoluteString, startAt: resume,
                preferredAudioLanguage: self.settings.preferredAudioLanguage,
                convertProfile7: p7ok,
                requestHeaders: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders,
                downmixToStereo: !spatial
            )
            self.dvDirectEngine = engine
            self.duration = probe.durationSeconds
            self.clock.duration = probe.durationSeconds
            engine.onTime = { [weak self, weak engine] seconds in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                self.position = seconds
                self.clock.position = seconds
                self.isPlaying = engine.isPlaying
                self.isBuffering = false
                if !self.hasStartedPlayback, seconds > resume + 0.2 {
                    self.hasStartedPlayback = true
                    self.loadPhase = nil
                    self.showControls()
                    // The resume is DELIVERED — stop clamping saves to it.
                    // Left set, max(position, pendingResume) meant Continue
                    // Watching could never record a position below the
                    // session's entry point: exit after a rewind (or earlier
                    // than you resumed) and the row snapped back.
                    self.pendingResume = nil
                }
                self.markLoadStarted()
                self.markPlaybackProgressed(currentTime: seconds)
                self.saveProgressThrottled()
                self.updateSkipIntro()
                // Addon subtitles: the model picks the cue for this instant;
                // the overlay renders it. KSPlayer normally drives this from
                // its own clock — the direct engine drives it from its ticks.
                _ = self.subtitleModel.subtitle(currentTime: seconds + self.subtitleDelay)
            }
            engine.onBuffering = { [weak self, weak engine] buffering in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                self.isBuffering = buffering
                self.isPlaying = !buffering && engine.isPlaying
            }
            engine.onEnded = { [weak self, weak engine] in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                self.handlePlayedToEnd()
            }
            engine.onError = { [weak self, weak engine] message in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                Self.dvTrail("direct engine error — \(message)")
                self.fallBackFromDirect(entry: entry, reason: message)
            }
            engine.start { [weak self] ok, reason in
                guard let self, self.dvDirectEngine === engine else { return }
                if ok {
                    Self.dvTrail("direct sample engine started")
                    // Report what the ENGINE found in the stream itself, not
                    // the preflight's guess — and name a converted P7 as the
                    // conversion it is, the same honesty the remux path kept.
                    let realProfile = engine.detectedDVProfile > 0 ? engine.detectedDVProfile : profile
                    let dvLabel: String
                    switch realProfile {
                    case 0: dvLabel = "Native \(probe.isPQ ? "HDR10\(probe.hasHDR10Plus ? "+" : "")" : "HEVC") (direct sample feed)"
                    case 7: dvLabel = "Native DV (direct sample feed, Profile 7 → 8.1)"
                    default: dvLabel = "Native DV (direct sample feed, Profile \(realProfile))"
                    }
                    self.decisionLog.record("Dolby Vision", dvLabel,
                                            because: "compressed samples fed straight to the display pipeline — no remux, no server")
                    self.decisionLog.record("Engine", "DV Sample Feed",
                                            because: "AVSampleBufferDisplayLayer owns rendering for this session")
                    // SEQUENCE THE SWITCH LIKE INFUSE. Requesting the display
                    // mode right after attaching a live video surface put the
                    // HDMI renegotiation on top of a surface coming alive —
                    // the overlap that wedged this panel grey ON ENTRY. So:
                    // switch FIRST, while the loading screen is static and the
                    // engine is held paused with its view unattached; attach
                    // and roll only once the panel has settled (UIScreen's
                    // fps changing is the ground truth that the mode took).
                    var switching = false
                    if profile > 0 {
                        switching = self.requestDVDisplayMode(fps: engine.videoFPS)
                    } else if probe.isPQ {
                        switching = self.requestHDR10DisplayMode(fps: engine.videoFPS)
                    }
                    if switching {
                        engine.pause()
                        let before = UIScreen.main.maximumFramesPerSecond
                        Task { @MainActor in
                            // Wait for the mode to report in AND hold steady:
                            // panels keep link-training for a while after they
                            // claim the new mode, and attaching video during
                            // that window is the overlap that wedges. Require
                            // three consecutive stable polls post-change, then
                            // a long quiet beat.
                            var stable = 0
                            var last = before
                            for _ in 0 ..< 24 {   // up to 6s
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                let now = UIScreen.main.maximumFramesPerSecond
                                if now != before, now == last { stable += 1 } else { stable = 0 }
                                last = now
                                if stable >= 3 { break }
                            }
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            guard self.dvDirectEngine === engine, !self.isExiting else { return }
                            Self.dvTrail("display settled at \(UIScreen.main.maximumFramesPerSecond)fps — attaching video")
                            // Attach the engine's layer view: PlayerVideoView
                            // only re-reads activeVideoView when this ID
                            // changes — without the bump the engine rendered
                            // into a view nobody ever put on screen.
                            self.videoRefreshID = UUID()
                            engine.play()
                        }
                    } else {
                        // No switch this session — attach immediately (the
                        // maiden-flight rule: without the bump the engine
                        // renders into a view nobody ever put on screen).
                        self.videoRefreshID = UUID()
                    }
                    if self.playbackSpeed != 1 {
                        engine.rate = self.playbackSpeed
                    }
                    // Pickers: audio from the engine's own track list;
                    // subtitles via the addon search — SubtitleOverlayView
                    // renders from SubtitleModel above any engine.
                    self.audioOptions = engine.audioTracks.map {
                        TrackOption(id: "dvda-\($0.index)", displayName: $0.label,
                                    payload: .dvDirectAudio($0.index))
                    }
                    self.selectedAudioID = "dvda-\(engine.currentAudioIndex)"
                    self.fetchAddonSubtitles()
                    self.rebuildSubtitleOptions()
                    // Chapters (Skip Intro, timeline ticks) + scrub previews —
                    // the same features every other engine session gets.
                    self.chapters = engine.chapters
                    self.startThumbnailsIfNeeded()
                    self.trailMem("direct start")
                } else {
                    Self.dvTrail("direct engine declined (\(reason)) — remux path")
                    self.fallBackFromDirect(entry: entry, reason: reason, toRemux: true,
                                            profile: profile, probeDuration: probe.durationSeconds,
                                            resume: resume)
                }
            }
            // Direct start has no engine underneath to keep playing — if the
            // remux can't produce a playable playlist in 45s, fall back to
            // the normal path rather than leaving a spinner forever.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let stillSelf = self as PlayerViewModel?, !stillSelf.isExiting else { return }
            if !stillSelf.hasStartedPlayback, stillSelf.usingNativeDV, stillSelf.playerLayer == nil {
                Self.dvTrail("DV-first: no playable playlist after 45s — falling back")
                stillSelf.dvRemuxer?.cancel()
                stillSelf.dvRemuxer?.stopServer()
                stillSelf.dvRemuxer?.cleanup()
                stillSelf.dvRemuxer = nil
                stillSelf.usingNativeDV = false
                stillSelf.dvRestarting = false
                stillSelf.load(entry: entry)
            }
        }
    }

    /// Direct-engine failure: tear it down and continue on the next tier —
    /// the remux+AVPlayer DV path when the file qualifies, else the plain
    /// FFmpeg load.
    private func fallBackFromDirect(
        entry: StreamEntry, reason: String, toRemux: Bool = false,
        profile: Int = 0, probeDuration: Double = 0, resume: Double = 0
    ) {
        dvDirectEngine?.stop()
        dvDirectEngine = nil
        videoRefreshID = UUID()   // detach the dead engine's layer view
        if toRemux, profile > 0 {
            decisionLog.record("Dolby Vision",
                               "Native DV (remux, Profile \(profile))",
                               because: "direct sample feed declined: \(reason)")
            usingNativeDV = true
            dvRestarting = true
            duration = probeDuration
            clock.duration = probeDuration
            dvFullDuration = probeDuration
            startDVRemux(from: max(resume - 2, 0), isRestart: true)
        } else {
            usingNativeDV = false
            dvRestarting = false
            load(entry: entry)
        }
    }

    /// Ask the display for its Dolby Vision mode on behalf of the direct
    /// engine (which has no KSOptions.updateVideo hook). Same de-dup-free,
    /// capability-gated request the options path makes for native sessions.
    /// Returns true when a display switch was actually initiated this call
    /// (the caller then holds video attach until the handshake settles).
    @discardableResult
    private func requestDVDisplayMode(fps: Float) -> Bool {
        // DV sessions request their mode by DEFAULT (the Infuse policy) —
        // range-only unless Match Frame Rate is on, pinned once per foreground
        // stint, and never reverted while the app is alive.
        guard let displayManager = UIApplication.shared.ks_keyWindow?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled else { return false }
        var rate = Float(UIScreen.main.maximumFramesPerSecond)
        if fps > 0 {   // always match the content rate — the revert that made this risky is gone
            rate = fps
            if (23.5...24.2).contains(rate) { rate = 23.976 }
        }
        // Clamp to what the TV actually advertises, same as updateVideo: a
        // non-DV HDR TV gets the HDR10 (or HLG) mode instead — the DV video
        // is tone-mapped into it by the system — and an SDR-only TV is left
        // entirely alone (no request, no handshake, content tone-maps to
        // SDR). Requesting a mode the display never advertised is exactly
        // the malformed-handshake bait this app no longer offers.
        var target = DynamicRange.dolbyVision
        let available = DynamicRange.availableHDRModes   // [.sdr] when none
        if !available.contains(target) {
            if available.contains(.hdr10) { target = .hdr10 }
            else if available.contains(.hlg) { target = .hlg }
            else { return false }
        }
        guard let criteria = AVDisplayCriteria(
            refreshRate: rate, videoDynamicRange: target.rawValue
        ) else { return false }
        if SessionDisplayMode.applyOnce(criteria, via: displayManager) {
            displayCriteriaApplied = true
            return true
        }
        return false
    }

    /// HDR10-range request for non-DV direct sessions, same pin discipline.
    @discardableResult
    private func requestHDR10DisplayMode(fps: Float) -> Bool {
        guard settings.matchContentDisplayMode,
              let displayManager = UIApplication.shared.ks_keyWindow?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled else { return false }
        var rate = Float(UIScreen.main.maximumFramesPerSecond)
        if fps > 0 {   // always match the content rate — the revert that made this risky is gone
            rate = fps
            if (23.5...24.2).contains(rate) { rate = 23.976 }
        }
        guard DynamicRange.availableHDRModes.contains(.hdr10),
              let criteria = AVDisplayCriteria(
                refreshRate: rate, videoDynamicRange: DynamicRange.hdr10.rawValue
              ) else { return false }
        if SessionDisplayMode.applyOnce(criteria, via: displayManager) {
            displayCriteriaApplied = true
            return true
        }
        return false
    }

    /// Where a native remux must START so it covers what the viewer is
    /// actually about to watch.
    ///
    /// NOT `position`. Native DV is decided in `readyToPlay`, which is the
    /// exact window where a Continue Watching resume has been ISSUED but not
    /// LANDED: the seek is async and `pendingResume` is cleared the moment it
    /// is consumed, so `position` is still ~0. Starting the remux there made
    /// it cover the top of the file, and `switchToNativeDV` then reloaded the
    /// player onto a playlist whose t=0 is the top of the file — with the
    /// resume already discarded. Result: turning on DV threw the viewer back
    /// to the beginning and Continue Watching appeared not to work.
    ///
    /// This is the same "highest resume intent" the failover path uses (see
    /// `sessionResumeFloor`), for the same reason.
    private var nativeRemuxStartTarget: Double {
        max(max(position, pendingResume ?? 0), sessionResumeFloor)
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
            convertProfile7: settings.dolbyVisionProfile7,
            allowHDR10Only: nativeKind == .hdr10Plus
        )
        dvRemuxer = remuxer
        remuxer.onIneligible = { [weak self] reason in
            guard let self, self.dvRemuxer === remuxer else { return }
            NSLog("[OrivioDV] ineligible: %@", reason)
            Self.dvTrail("ineligible — \(reason)")
            self.decisionLog.record(self.nativeKind.stage, self.nativeFallbackLabel,
                                    because: "remux ineligible: \(reason)")
            self.dvFailedURLs.insert(urlString)
            if self.usingNativeDV { self.abandonNativeDV(reason: "became ineligible mid-play: \(reason)") }
            // Cleanup AFTER the abandon forensics have read the directory.
            self.dvRemuxer?.cleanup()
            self.dvRemuxer = nil
        }
        remuxer.onError = { [weak self] message in
            guard let self, self.dvRemuxer === remuxer else { return }
            NSLog("[OrivioDV] remux error: %@", message)
            // Persisted so the failure is readable AFTER the fact (the console
            // attach keeps dying with the app lifecycle) — same pattern as the
            // other diagnostics. Newest failure wins; success clears it.
            Self.dvTrail("remux error — \(message)")
            // The panel said "Native DV" the moment the remux STARTED; a
            // failure must correct it or the info panel lies about the output.
            self.decisionLog.record(self.nativeKind.stage, self.nativeFallbackLabel,
                                    because: "native \(self.nativeKind.label) remux failed: \(message)")
            self.dvFailedURLs.insert(urlString)
            if self.usingNativeDV { self.abandonNativeDV(reason: "remux error mid-play: \(message)") }
            // Cleanup AFTER the abandon forensics have read the directory —
            // and always cleanup, or failed remuxers leak their segment dirs
            // in tmp (found five of them during the P7 investigation).
            self.dvRemuxer?.cleanup()
            self.dvRemuxer = nil
        }
        remuxer.onProgress = { [weak self] written in
            guard let self, self.dvRemuxer === remuxer else { return }
            self.dvWrittenSeconds = max(self.dvWrittenSeconds, written)
            // PRE-SWITCH DRAIN. Once the remux has clearly taken (10s+
            // written), this session is headed for the engine swap — and the
            // FFmpeg engine's read-ahead cache is the largest thing that gets
            // stranded when the old engine fails to deinit (a KSPlayer bug
            // patched but, per live measurement, not fully cured). KSPlayer
            // reads maxBufferDuration LIVE, so shrinking it here lets the
            // cache drain to a few seconds during the remaining cushion
            // build: ~100 MB less alive at the swap, ~100 MB less stranded
            // after it. If the remux dies instead of switching, a 6s cap on
            // an actively-refilling stream is a shallower cushion, not a
            // stall — the same cap the 2 GB tier always runs with.
            if !self.usingNativeDV, written > 10,
               let options = self.currentOptions, options.maxBufferDuration > 6 {
                options.maxBufferDuration = 6
                NSLog("[OrivioDV] pre-switch drain: engine cache capped at 6s")
            }
        }
        remuxer.onWindowStart = { [weak self] pruned in
            guard let self, self.dvRemuxer === remuxer else { return }
            self.dvPrunedThrough = max(self.dvPrunedThrough, pruned)
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
        // Initial switch waits for a 20s cushion ahead of the viewer (see
        // minReadySecondsAhead) — enough for AVPlayer's ~12s forward buffer
        // plus margin, and once the switch happens the FFmpeg engine stops
        // pulling the source, so the worker's available bandwidth roughly
        // doubles. A seek-restart of an already-proven session keeps the
        // fast 3-segment gate so seeks stay snappy.
        remuxer.minReadySecondsAhead = isRestart ? 0 : 20
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
        sessionResumeFloor = max(sessionResumeFloor, dvTimeOffset)
        // Resume the playlist AT THE CURRENT POSITION, not at its start.
        // The playlist's t=0 is where the REMUX started — which is where the
        // viewer was when the background remux kicked off, minutes ago by the
        // time the cushion gate lets the switch happen. The old
        // `pendingResume = nil` played the playlist from 0, silently throwing
        // the viewer back to the remux start on every switch: barely a
        // stutter under the old 6-second ready gate, a jump back of MINUTES
        // under the cushion gate — the "turning on DV restarts the stream"
        // and "takes forever to load" reports. readyToPlay translates this
        // absolute time into the playlist's local timeline (− dvTimeOffset),
        // and everything from dvTimeOffset forward is on disk by definition.
        pendingResume = position > dvTimeOffset + 5 ? position : nil
        // Flatten the switch-window memory spike: hold the remux worker's
        // network sprint while the old engine tears down and AVPlayer fills
        // its first buffer (both from disk, unaffected by the hold).
        dvRemuxer?.pauseReadsUntil = Date().addingTimeInterval(6)
        ImageCache.shared.dropDecoded()
        showToast("\(nativeKind.label) — native output")
        Self.dvTrail("switched to native \(nativeKind.label) OK")
        trailMem("at switch")
        NSLog("[OrivioDV] switching to native playlist (offset %.1fs)", dvTimeOffset)
        dvPlaylistURL = playlist
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
        dvPrunedThrough = 0
        dvRemuxFinished = false
        NSLog("[OrivioDV] out-of-window seek → re-remux from %.1fs", clamped)
        startDVRemux(from: max(clamped - 2, 0), isRestart: true)
    }

    /// Longest single trail entry, and the total budget for the whole array.
    ///
    /// The count cap alone was NOT a size cap, and one caller below writes an
    /// entire dv.m3u8 into a single entry — two lines per segment, so a long
    /// remux makes one entry hundreds of KB. Thirty of those is megabytes in
    /// NSUserDefaults, and CFPreferences does not fail an oversized write, it
    /// ABORTS the process:
    /// `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`.
    /// Because the array persists, the app then re-hit the same abort on the
    /// next DV playback — a hard crash on play, every time. Confirmed as the
    /// signature on every crash report pulled off a real Apple TV.
    private static let maxTrailEntryChars = 400
    private static let maxTrailBytes = 16 * 1024

    /// The process's real memory footprint (what jetsam judges), in MB.
    /// -1 when the kernel call fails.
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Memory tracer: one persisted trail line every 2 minutes while the
    /// player lives, plus one at each DV transition. Jetsam kills leave no
    /// crash report and no stack — the ONLY way to find out which phase of a
    /// session grew to 1.5 GB is a breadcrumb trail that survives the kill.
    /// The trail's own 30-entry / 16 KB caps make this a self-pruning ring:
    /// after a crash the newest entries cover the last hour, which is enough
    /// to see the slope and the phase.
    private var memTracerTask: Task<Void, Never>?
    func startMemTracer() {
        memTracerTask?.cancel()
        memTracerTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // 12s cadence during native DV — the growth BURSTS (941 MB →
                // jetsam inside one 40s gap, observed live), and a guard that
                // samples slower than the spike is a guard in name only. The
                // trail line only goes out every ~3rd tick to keep the
                // persisted breadcrumbs from churning the 30-entry ring.
                let native = await MainActor.run { [weak self] in self?.usingNativeDV ?? false }
                try? await Task.sleep(nanoseconds: native ? 12_000_000_000 : 40_000_000_000)
                guard let self, !self.isExiting else { return }
                tick += 1
                if !native || tick % 3 == 0 { self.trailMem("periodic") }
                // MEMORY GUARD. Native DV accumulates footprint on this
                // hardware (a dead-engine blob parked at the switch, plus a
                // slow ongoing build not yet root-caused), and when jetsam
                // fires the user loses the whole app, their place, and their
                // patience. Long before that point, step down to the HDR10
                // decode instead: same movie, same position, one toast — the
                // difference between a graceful quality fallback and a crash
                // to the home screen. Threshold chosen from live kill data:
                // every observed jetsam landed at 1.3–1.6 GB.
                if self.usingNativeDV {
                    // NO recycle: replacing the AVPlayerItem was tested live
                    // and returned ZERO memory (the retention is process-
                    // scoped CoreMedia state) — it only added a rebuffer
                    // hiccup. DV simply runs until the ceiling, then steps
                    // down once, cleanly.
                    //
                    // PREDICTIVE, not reactive. AVPlayer's initial window
                    // fill retains at 15-20 MB/s on a fast link — jetsam
                    // repeatedly killed the app BETWEEN 12-second ticks
                    // (909 MB → dead in under 24 s, observed live). A fixed
                    // threshold loses that race by construction; projecting
                    // one tick ahead from the current slope steps down while
                    // there is still road.
                    let mb = Self.memoryFootprintMB()
                    let rate = self.lastGuardSample > 0 ? mb - self.lastGuardSample : 0
                    self.lastGuardSample = mb
                    let projected = mb + max(rate, 0)
                    if mb > 1150 || (mb > 850 && projected > 1150) {
                        Self.dvTrail(String(
                            format: "memory guard: %.0fMB, +%.0f/tick, projected %.0f — stepping down",
                            mb, rate, projected
                        ))
                        self.abandonNativeDV(reason: String(format: "memory guard at %.0fMB", mb))
                    }
                } else if self.dvRemuxer != nil {
                    self.lastGuardSample = 0
                    // PRE-switch guard. The P7 remux phase accrues memory too
                    // (~10 MB/s observed) and used to run unprotected — a
                    // session could balloon to jetsam before the switch ever
                    // happened. Cancelling the remux is even gentler than the
                    // post-switch abandon: playback never changes engines, the
                    // viewer just stays on the HDR10 decode they're already
                    // watching.
                    let mb = Self.memoryFootprintMB()
                    if mb > 1250 {
                        Self.dvTrail(String(format: "pre-switch memory guard at %.0fMB — cancelling remux", mb))
                        self.decisionLog.record(self.nativeKind.stage, self.nativeFallbackLabel,
                                                because: String(format: "remux cancelled by memory guard at %.0f MB", mb))
                        self.dvRemuxer?.cancel()
                        self.dvRemuxer?.stopServer()
                        self.dvRemuxer?.cleanup()
                        self.dvRemuxer = nil
                    }
                }
            }
        }
    }

    /// One footprint breadcrumb with enough phase context to interpret it.
    ///
    /// Breaks the footprint down by KIND — `int` is anonymous (malloc/Swift)
    /// memory, `cmp` is what the compressor holds — because the flat number
    /// alone couldn't distinguish real allocations from page-cache effects
    /// (the F_NOCACHE experiment disproved the cache theory; the split makes
    /// the next theory testable instead of arguable). The srv counters say
    /// how much the loopback segment server has handled.
    func trailMem(_ why: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let phase: String
        if usingDVDirect { phase = "dvDirect" }
        else if usingNativeDV { phase = "nativeDV" }
        else if dvRemuxer != nil { phase = "ffmpeg+remuxing" }
        else if vlcEngine != nil { phase = "vlc" }
        else { phase = "ffmpeg" }
        guard result == KERN_SUCCESS else {
            Self.dvTrail("mem ? \(phase) (\(why))"); return
        }
        let mb = Double(info.phys_footprint) / 1_048_576
        let anon = Double(info.internal) / 1_048_576
        let comp = Double(info.compressed) / 1_048_576
        // THE EXPERIMENT: ask malloc to return freed-but-held pages to the
        // kernel, then resample. The persistent compressed ballast survived
        // the remux thread's exit, which rules out autorelease pools; the
        // remaining candidate is allocator retention — memory our code has
        // long since freed that malloc keeps (and the compressor dutifully
        // compresses instead of discarding). The before→after delta in every
        // breadcrumb measures exactly that — and if it IS the cause, this
        // call is also the fix.
        malloc_zone_pressure_relief(nil, 0)
        var info2 = task_vm_info_data_t()
        var count2 = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result2 = withUnsafeMutablePointer(to: &info2) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count2)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count2)
            }
        }
        let after = result2 == KERN_SUCCESS ? Double(info2.phys_footprint) / 1_048_576 : -1
        Self.dvTrail(String(
            format: "mem %.0f→%.0fMB int=%.0f cmp=%.0f %@ pos=%.0fs %@ (%@)",
            mb, after, anon, comp, phase, position, DVSegmentServer.statsLine(), why
        ))
    }

    /// Append one line to the persisted DV trail (newest LAST — the previous
    /// overwrite-style key lost the interesting first error under the later
    /// abandon message).
    static func dvTrail(_ line: String) {
        // Mirrored to the console so a live-attached session sees the trail
        // in real time, not only after the fact.
        NSLog("[OrivioTrail] %@", line)
        let entry = String("\(Date()): \(line)".prefix(maxTrailEntryChars))
        var trail = UserDefaults.standard.stringArray(forKey: "dev.dvTrail") ?? []
        trail.append(entry)
        if trail.count > 30 { trail.removeFirst(trail.count - 30) }
        // Belt as well as braces: bound the TOTAL, so no combination of long
        // entries can ever grow the value without limit again.
        while trail.count > 1,
              trail.reduce(0, { $0 + $1.utf8.count }) > maxTrailBytes {
            trail.removeFirst()
        }
        UserDefaults.standard.set(trail, forKey: "dev.dvTrail")
    }

    /// Any DV failure: return to the FFmpeg engine at the same position —
    /// i.e. exactly the pre-DV behavior (decoded HDR10).
    private func abandonNativeDV(reason: String = "unspecified") {
        guard usingNativeDV else { resetNativeDV(); return }
        NSLog("[OrivioDV] abandoning native %@ (%@) — falling back to FFmpeg engine",
              nativeKind.label, reason)
        Self.dvTrail("abandoned after switch — \(reason)")
        trailMem("at abandon")
        // MEMORY-GUARD abandons keep this LIGHT and halt the growth sources
        // FIRST: the forensic directory walk, playlist read, and preserve
        // copies all allocate at the exact moment memory is critical — the
        // step-down must never lose its own race to jetsam.
        if reason.hasPrefix("memory guard") {
            dvRemuxer?.cancel()
            dvRemuxer?.stopServer()
            decisionLog.record(nativeKind.stage, nativeFallbackLabel,
                               because: "native \(nativeKind.label) abandoned: \(reason)")
            showToast("\(nativeKind.label) paused to protect playback — using HDR10")
            pendingResume = position > 10 ? position : nil
            sessionResumeFloor = max(sessionResumeFloor, position)
            load(entry: currentEntry)
            return
        }
        // Forensics: what did the remux directory actually hold when AVPlayer
        // gave up on it? This is the difference between "playlist never
        // existed" and "playlist existed and AVPlayer rejected the media".
        if let dir = dvRemuxer?.directory {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let sizes = names.prefix(8).map { name -> String in
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                return "\(name)=\((attrs?[.size] as? Int) ?? -1)b"
            }
            Self.dvTrail("dir at abandon: \(names.count) files [\(sizes.joined(separator: ", "))]")
            if let playlist = try? String(contentsOf: dir.appendingPathComponent("dv.m3u8"), encoding: .utf8) {
                // The HEAD of the playlist plus its length — that is what the
                // forensics actually need (does it have EXT-X-MAP, does it
                // have segments). Dumping every EXTINF line is what grew this
                // key until CFPreferences killed the app.
                let lines = playlist.split(separator: "\n", omittingEmptySubsequences: true)
                let head = lines.prefix(6).joined(separator: " | ")
                Self.dvTrail("playlist: \(lines.count) lines — \(head)")
            }
            // PRESERVE the rejected output for offline analysis — teardown
            // cleans the tmp dir minutes later, which is how the first three
            // captured failures evaporated before they could be pulled off the
            // device. COPY the analysis-critical files individually rather
            // than moving the whole directory: the remuxer is still writing
            // into it at abandon time, and the earlier moveItem failed
            // silently behind a try?. Every failure is trailed this time.
            let fm = FileManager.default
            // Caches, not Documents: tvOS gives apps no writable Documents
            // directory — the previous attempt failed with a permission error
            // straight from the platform.
            let keep = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dv-failed-output", isDirectory: true)
            try? fm.removeItem(at: keep)
            do {
                try fm.createDirectory(at: keep, withIntermediateDirectories: true)
                var kept: [String] = []
                for name in ["init.mp4", "dv.m3u8", "seg00000.m4s", "seg00001.m4s"] {
                    do {
                        try fm.copyItem(at: dir.appendingPathComponent(name),
                                        to: keep.appendingPathComponent(name))
                        kept.append(name)
                    } catch {
                        Self.dvTrail("preserve \(name) failed: \(error.localizedDescription)")
                    }
                }
                Self.dvTrail("preserved \(kept.joined(separator: ", ")) in Caches/dv-failed-output")
            } catch {
                Self.dvTrail("preserve dir failed: \(error.localizedDescription)")
            }
        } else {
            Self.dvTrail("dir at abandon: remuxer already gone")
        }
        decisionLog.record(nativeKind.stage, nativeFallbackLabel,
                           because: "native \(nativeKind.label) abandoned: \(reason)")
        // Blacklist the URL only for REAL failures. A memory-guard step-down
        // or a live-edge catch is a controlled trade on a healthy title — but
        // blacklisting those meant every replay of that title in the same app
        // session silently skipped DV entirely: after one guard trip, "DV not
        // working at all" until the app was relaunched.
        let controlledStepDown = reason.hasPrefix("memory guard")
            || reason.hasPrefix("caught the live edge")
            || reason.contains("stalled")
        if !controlledStepDown, let urlString = currentEntry.stream.url {
            dvFailedURLs.insert(urlString)
        }
        // The guard step-down is a controlled trade, not a failure — saying
        // "failed" made a working protection read like a broken feature.
        showToast(reason.hasPrefix("memory guard")
            ? "\(nativeKind.label) paused to protect playback — using HDR10"
            : "Native \(nativeKind.label) failed — using HDR10")
        pendingResume = position > 10 ? position : nil
        // Raise the session floor to WHERE THE ABANDON HAPPENED, not where
        // the session started. load() zeroes `position` and readyToPlay
        // consumes `pendingResume` — so if the fallback open then hiccups
        // into a failover, its resume target fell through to the floor, which
        // still held the ORIGINAL Continue Watching position. That was the
        // "sometimes it goes back to the resume time" jump: the viewer lost
        // everything watched since opening the player.
        sessionResumeFloor = max(sessionResumeFloor, position)
        load(entry: currentEntry)   // overrideURL nil → resetNativeDV() runs
    }

    /// Tear down DV state (normal loads, teardown). Keeps dvFailedURLs.
    private func resetNativeDV() {
        dvRemuxer?.cancel()
        // Nothing will request another segment from a retired session — kill
        // its loopback server now, not at the directory purge minutes later.
        dvRemuxer?.stopServer()
        if let remuxer = dvRemuxer { dvRetiredRemuxers.append(remuxer) }
        dvRemuxer = nil
        dvPlaylistURL = nil
        usingNativeDV = false
        dvAttempted = false
        dvRestarting = false
        dvTimeOffset = 0
        dvWrittenSeconds = 0
        dvPrunedThrough = 0
        dvRemuxFinished = false
        dvFullDuration = 0
        // Back to the default payload. Left at .hdr10Plus, the next title's DV
        // session would mislabel itself and skip the dvvC handling.
        nativeKind = .dolbyVision
    }

    /// Delete every remux directory. Only safe once playback is done.
    ///
    /// SYNCHRONOUS, unlike the retired-directory purge: this is the player's
    /// last moment of life. The old version handed the work to a utility-
    /// priority detached Task and returned — and a detached low-priority task
    /// spawned while the player is being dismissed routinely never ran, which
    /// is how ~1 GB segment directories ended up orphaned in tmp. Blocking
    /// teardown on the unlinks is cheap next to leaking the disk.
    ///
    /// `live` is passed in because `resetNativeDV()` has already retired the
    /// active remuxer and nil'd `dvRemuxer` by the time teardown gets here —
    /// reading the property again (as this used to) is always nil, so the
    /// live session's own directory was never the one being deleted.
    private func purgeDVDirectories(live: DVRemuxer?) {
        let retired = dvRetiredRemuxers
        dvRetiredRemuxers = []
        for remuxer in retired { remuxer.cleanup() }
        live?.cleanup()
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
    /// Why the current playback path looks the way it does — shown in the
    /// pull-down info panel. Reset at every load.
    private(set) var decisionLog = PlaybackDecisionLog()
    /// The active policy, read once per load so a mid-playback settings edit
    /// can't leave the session half in one mode and half in another.
    private(set) var activeMode: PlaybackMode = .automatic
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
        // Hand the poster cache's RAM back before the player allocates its
        // own. See ImageCache.dropDecoded().
        ImageCache.shared.dropDecoded()
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
        startMemTracer()
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
        let spatialRoute = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.isSpatialAudioEnabled }
        let useRenderer: Bool
        // Playback mode overrides: Fidelity insists on the Atmos-capable
        // renderer whenever the route can use it; Compatibility pins the
        // battle-tested AVAudioEngine. Automatic follows the audio setting.
        switch settings.playbackMode {
        case .fidelity:
            useRenderer = spatialRoute || settings.audioOutputMode == .renderer
        case .compatibility:
            useRenderer = false
        case .automatic:
            switch settings.audioOutputMode {
            case .auto: useRenderer = spatialRoute
            case .renderer: useRenderer = true
            case .engine: useRenderer = false
            }
        }
        decisionLog.record(
            "Audio Route",
            useRenderer ? "Enhanced renderer (Atmos-capable)" : "Standard (AVAudioEngine)",
            because: settings.playbackMode == .compatibility
                ? "Compatibility mode pins the standard engine"
                : (useRenderer
                    ? (spatialRoute ? "output route reports spatial-audio support" : "forced in audio settings")
                    : (spatialRoute ? "forced in audio settings" : "output route has no spatial-audio support"))
        )
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
        // Replay this title's remembered choices before the first load, so a
        // file that needed VLC (or 1.5x, or French audio) last time starts
        // that way now. Only user-made choices are stored, so replaying them
        // is doing what the user already asked for.
        if let memory = PlaybackMemory.memory(for: request.meta.id) {
            if let speed = memory.speed { playbackSpeed = speed }
            if settings.playerEngine == .auto, let raw = memory.engine,
               let engine = PlayerEngine(rawValue: raw), engine != .auto {
                sessionEngine = engine
                decisionLog.record("Engine", engine.label,
                                   because: "you switched this title to it last time")
            }
        }
        load(entry: request.entry)
        runStreamProbe()
    }

    /// One header probe answering both questions that change how a title
    /// plays, run in parallel with the initial load so nothing waits on it:
    ///
    /// - **Styled ASS/SSA** → reload into VLC, which renders it with libass +
    ///   embedded MKV fonts (KSPlayer's own parser drops both).
    /// - **HDR10+** → start the native remux so the dynamic metadata reaches
    ///   the TV instead of being decoded away by the Metal path.
    ///
    /// Only the questions worth asking are asked: each gate is checked BEFORE
    /// the probe, and a probe with nothing to answer never opens a connection.
    /// Keyed by URL, not a one-shot flag: switching source mid-title (failover,
    /// a different addon's link) hands us a DIFFERENT FILE, whose subtitle and
    /// HDR properties are its own. The old one-shot version silently kept the
    /// first file's answers for the rest of the session.
    private var probedURLs: Set<String> = []
    private func runStreamProbe() {
        guard effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              let url = currentEntry.stream.url,
              !probedURLs.contains(url) else { return }
        let wantASS = settings.fullAssSubtitles
        // HDR10+ is only worth probing for when this box can actually output
        // it — otherwise the honest answer is already known (HDR10 base), and
        // a scan on an A10X would cost startup for nothing.
        let wantHDR10Plus = settings.hdr10PlusPassthrough
            && PerformanceProfile.supportsHDR10Plus
            && activeMode != .compatibility
        guard wantASS || wantHDR10Plus else { return }
        probedURLs.insert(url)
        Task { [weak self] in
            let result = await StreamProbe.inspect(
                url: url, needsStyledASS: wantASS, needsHDR10Plus: wantHDR10Plus
            )
            // Only apply to the source we probed — a failover may have moved on.
            guard let self, !self.isExiting,
                  self.currentEntry.stream.url == url else { return }
            self.hasHDR10Plus = result.hasHDR10Plus
            if result.hasHDR10Plus { self.maybeStartNativeHDR10Plus() }
            guard result.hasStyledASS, !self.usingNativeDV,
                  self.effectiveEngine != .vlc else { return }
            NSLog("[OrivioSubs] styled ASS detected — routing to VLC for full rendering")
            self.switchEngine(.vlc)
        }
    }

    /// HDR10+ found and this Apple TV can output it: take the same native
    /// remux the DV path uses, for the same reason — only AVPlayer hands the
    /// bitstream to the display pipeline with its per-frame metadata intact.
    ///
    /// Deliberately yields to Dolby Vision: a file carrying both is a DV file
    /// with an HDR10+ base, and DV is the better output. This only runs when
    /// no DV session is running or pending.
    private func maybeStartNativeHDR10Plus() {
        guard PerformanceProfile.supportsHDR10Plus, settings.hdr10PlusPassthrough,
              activeMode != .compatibility,
              !usingNativeDV, !dvAttempted, dvRemuxer == nil, !isExiting,
              effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              let player = playerLayer?.player, player is KSMEPlayer,
              let urlString = currentEntry.stream.url,
              !dvFailedURLs.contains(urlString),
              currentURL?.isFileURL != true
        else { return }
        // A DV track means the DV path owns this title (it may not have run
        // yet — readyToPlay fires it — so check the track, not just the flags).
        //
        // The probe can finish BEFORE the tracks exist, and an empty track list
        // would read as "no DV" and let HDR10+ claim a Dolby Vision file. So
        // bail while the list is empty; readyToPlay calls this again once the
        // tracks are real, and whichever call arrives second does the work.
        let videoTracks = player.tracks(mediaType: .video)
        guard !videoTracks.isEmpty else { return }
        let track = videoTracks.first(where: \.isEnabled) ?? videoTracks.first
        if track?.dovi != nil {
            decisionLog.record("HDR10+", "Dolby Vision instead",
                               because: "the file also carries DV, which is the better output")
            return
        }
        dvAttempted = true
        nativeKind = .hdr10Plus
        decisionLog.record("HDR10+", "Native HDR10+",
                           because: "remuxing so the per-frame metadata survives to the TV")
        NSLog("[OrivioHDR] HDR10+ detected — starting background remux")
        startDVRemux(from: max(nativeRemuxStartTarget - 2, 0), isRestart: false)
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
        if overrideURL == nil {
            resetNativeDV()
            decisionLog.reset()
            activeMode = settings.playbackMode
            if activeMode != .automatic {
                decisionLog.record("Mode", activeMode.label, because: "chosen in Settings → Playback")
            }
        }
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
            decisionLog.record("Engine", "VLC", because: "selected as the playback engine")
            loadViaVLC(url: url)
            return
        }
        // Coming FROM the VLC engine (engine switch, or failover off a VLC
        // error): shut it down or both engines would run at once.
        vlcEngine?.stop()
        vlcEngine = nil

        // DV-FIRST. When the source advertises Dolby Vision (debrid names
        // carry it) and every gate passes, skip the FFmpeg engine entirely:
        // probe the header, start the remux, and open AVPlayer directly on
        // the playlist. The mid-play switch was the memory peak — two full
        // pipelines at once plus a dead engine stranded per swap — and the
        // pre-switch FFmpeg pull halved the remux's bandwidth. Direct start
        // has ONE pipeline from the first frame: the baseline drops by
        // hundreds of MB and the DV budget grows accordingly. Every failure
        // (probe timeout, ineligible file, remux error) falls back to this
        // normal load.
        if overrideURL == nil, shouldTryDVFirst(url: url) {
            startDVFirst(entry: entry, url: url)
            return
        }

        let options = NuvioPlayerOptions()
        // Addon-declared request headers (behaviorHints.proxyHeaders). Scraper
        // addons (KhmerDub and friends) return a CDN link that 403s without the
        // exact Referer/User-Agent of the page it was scraped from — dropping
        // them made every one of those sources "fail to play". appendHeader
        // feeds BOTH engines: AVURLAssetHTTPHeaderFieldsKey for the native
        // path, FFmpeg's `headers` option for the FFmpeg one.
        if let headers = entry.stream.behaviorHints?.proxyHeaders?.requestHeaders {
            options.appendHeader(headers)
            // KSOptions ALSO carries a standalone `user_agent` FFmpeg option
            // (default "KSPlayer"). Left alone it would go out alongside the
            // one appendHeader just wrote — two User-Agent lines on the same
            // request, which some of these CDNs reject outright. Point it at
            // the addon's value so the two agree.
            if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                options.userAgent = agent
            }
        }
        // Sticky per-session record that a display-mode switch really was
        // requested (survives options replacement on failover/DV swap) — the
        // exit path waits out the switch-back only when one could be pending.
        options.onDisplayCriteriaApplied = { [weak self] in
            DispatchQueue.main.async {
                self?.displayCriteriaApplied = true
                // This playback owns the display now; a release still pending
                // from the last exit must not fire underneath it.
                DisplayModeRestorer.cancelPending()
            }
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
        // Only a real DV session may request the Dolby Vision display mode.
        // HDR10+ rides the ordinary HDR10 mode — the dynamic metadata is
        // in-band, so asking the TV for a DV mode would be both wrong and an
        // extra HDMI handshake.
        options.nativeDV = overrideURL != nil && nativeKind == .dolbyVision

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
        // A container learned from an earlier sniff of this exact URL beats
        // every guess below — extensionless debrid links stop defaulting to
        // FFmpeg once we know they are plain MP4.
        if ext.isEmpty, overrideURL == nil, let learned = ContainerSniffer.cached(url.absoluteString) {
            ext = learned
            decisionLog.record("Container", learned.uppercased(),
                               because: "learned from an earlier probe of this link")
        }
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
        if overrideURL != nil {
            decisionLog.record("Engine", "Native (AVPlayer)",
                               because: "Dolby Vision playlist must ride Apple's pipeline")
        } else {
            let why: String
            switch effectiveEngine {
            case .native: why = "forced to Native in the engine picker"
            case .ffmpeg: why = "forced to FFmpeg in the engine picker"
            default:
                why = ext.isEmpty
                    ? "no file extension — FFmpeg plays every container"
                    : (needsFFmpeg ? "\(ext.uppercased()) container needs the FFmpeg demuxer"
                                   : "\(ext.uppercased()) is native-friendly")
            }
            decisionLog.record("Engine", needsFFmpeg ? "FFmpeg" : "Native (AVPlayer)", because: why)
        }
        // Unknown container: probe the real one in the background. This never
        // delays the open — FFmpeg is already the safe default — it informs
        // the decision panel now and routes the NEXT open of this link right.
        if ext.isEmpty, overrideURL == nil {
            let sniffURL = url.absoluteString
            let sniffHeaders = entry.stream.behaviorHints?.proxyHeaders?.requestHeaders
            Task { [weak self] in
                guard let found = await ContainerSniffer.sniff(sniffURL, headers: sniffHeaders) else { return }
                await MainActor.run {
                    guard let self, self.currentURL?.absoluteString == sniffURL else { return }
                    self.decisionLog.record("Container", found.uppercased(),
                                            because: "probed from the stream's first bytes; next open routes directly")
                }
            }
        }
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
            // Tier-aware: 12s is the right ceiling on the RAM-constrained
            // boxes (2-3 GB — deeper buffering just accelerates CoreMedia's
            // cumulative retention toward the memory guard), while the 4 GB+
            // gen-3 can hold a real cushion for smoother native playback.
            options.preferredForwardBufferDuration =
                (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? 12 : 30
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
        setSkipIntroActive(false)
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
        setSkipIntroActive(false)
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
        engine.load(
            url: url, networkCachingMs: cachingMs,
            headers: currentEntry.stream.behaviorHints?.proxyHeaders?.requestHeaders
        )
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
            if playbackSpeed != 1 {
                if let dvDirectEngine { dvDirectEngine.rate = playbackSpeed }
                else { vlcEngine?.rate = playbackSpeed }
            }
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
        let rememberedAudio = PlaybackMemory.memory(for: meta.id)?.audioLanguage
        if rememberedAudio != nil || !settings.preferredAudioLanguage.isEmpty {
            let want = rememberedAudio ?? settings.preferredAudioLanguage
            // Ranking inside the language: never a commentary/descriptive
            // track, then Atmos-capable (DD+ carries Atmos through tvOS
            // natively), then channel count. The file's own default only wins
            // when no preferred-language track exists.
            let matches = player.tracks(mediaType: .audio)
                .filter { ($0.languageCode ?? "").hasPrefix(want) }
                .sorted { a, b in
                    let aSec = Self.isSecondaryAudio(a), bSec = Self.isSecondaryAudio(b)
                    if aSec != bSec { return !aSec }
                    let aAtmos = Self.audioFormat(a).atmosCapable
                    let bAtmos = Self.audioFormat(b).atmosCapable
                    if aAtmos != bAtmos { return aAtmos }
                    return Self.channelCount(a) > Self.channelCount(b)
                }
            if let best = matches.first, !best.isEnabled {
                player.select(track: best)
                selectedAudioID = "audio-\(best.trackID)"
                decisionLog.record("Audio Track", trackLabel(best),
                                   because: "preferred language, ranked by Atmos capability and channels")
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
        // The user turned subtitles OFF on this title before; honour that over
        // the global on-by-default.
        if PlaybackMemory.memory(for: meta.id)?.subtitleLanguage == "off" {
            subtitleAutoApplied = true
            return
        }
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
        if label.isEmpty { label = "Track \(track.trackID)" }
        // Codec + channels + the HONEST output note. A TrueHD Atmos track is
        // not "Atmos" on tvOS — the platform can't bitstream it, so it decodes
        // to PCM. Saying so in the picker is the difference between a player
        // that reports its source and one that reports its marketing.
        let audio = Self.audioFormat(track)
        var parts: [String] = []
        if let codec = audio.codec, !label.localizedCaseInsensitiveContains(codec) {
            parts.append(codec)
        }
        let channels = Self.channelCount(track)
        if channels > 2, !label.contains("\(channels)") {
            parts.append(Self.channelLabel(channels))
        }
        if audio.decodedToPCM { parts.append("→ PCM") }
        return parts.isEmpty ? label : "\(label) · \(parts.joined(separator: " "))"
    }

    /// What an audio track IS and what tvOS can DO with it.
    ///
    /// tvOS bitstreams Dolby Digital and DD+ (including DD+ Atmos); everything
    /// lossless — TrueHD, DTS-HD MA, DTS:X — must be decoded to multichannel
    /// PCM. That is an Apple platform rule (Infuse documents the identical
    /// limitation), so the UI must never promise "Atmos" off a TrueHD track.
    static func audioFormat(_ track: any MediaPlayerTrack) -> (
        codec: String?, decodedToPCM: Bool, atmosCapable: Bool
    ) {
        let sub = track.formatDescription.map {
            CMFormatDescriptionGetMediaSubType($0).description
                .trimmingCharacters(in: CharacterSet(charactersIn: "'")).lowercased()
        } ?? ""
        let name = track.name.lowercased()
        func has(_ needles: String...) -> Bool {
            needles.contains { sub.contains($0) || name.contains($0) }
        }
        if has("trhd", "truehd", "mlp") {
            return ("TrueHD" + (has("atmos") ? " Atmos" : ""), true, false)
        }
        if has("dtsh", "dts-hd", "dtsx", "dts:x") { return ("DTS-HD", true, false) }
        if has("dtsc", "dtse", "dts") { return ("DTS", true, false) }
        if has("ec-3", "ec3", "eac3", "e-ac-3") {
            return ("Dolby Digital+" + (has("atmos", "joc") ? " Atmos" : ""), false, true)
        }
        if has("ac-3", "ac3") { return ("Dolby Digital", false, false) }
        if has("flac") { return ("FLAC", true, false) }
        if has("opus") { return ("Opus", true, false) }
        if has("aac") { return ("AAC", false, false) }
        if has("lpcm", "pcm", "sowt", "twos") { return ("PCM", false, false) }
        return (nil, false, false)
    }

    /// Tracks nobody wants auto-selected: commentaries and descriptive audio.
    /// They stay in the picker; they just never win the automatic choice.
    static func isSecondaryAudio(_ track: any MediaPlayerTrack) -> Bool {
        let name = track.name.lowercased()
        return ["commentary", "comment", "description", "descriptive", "narration"]
            .contains { name.contains($0) }
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
        keepDVPlayheadFreshWhilePaused()
    }

    /// While a native-DV session is PAUSED, keep re-stamping the remuxer's
    /// playhead with the (unmoving) position.
    ///
    /// The remuxer cannot tell a paused player from a dead one — both stop
    /// reporting. Its stale-playhead policy assumes the viewer kept advancing
    /// (so a stall can never starve the playlist), and its disk-budget bail
    /// treats "over budget with a long-stale playhead" as a runaway. Both are
    /// right for a dead player and wrong for a paused one: a long pause would
    /// have the worker write forward at 1× until the budget killed the
    /// session. A fresh-but-static playhead gives the correct behaviour for
    /// free — the worker builds exactly its lead over the paused position,
    /// then holds, and pruning stays alive.
    private var dvPauseHeartbeat: Task<Void, Never>?
    private func keepDVPlayheadFreshWhilePaused() {
        // Pre-switch too: a pause during the cushion build stops the position
        // callbacks just the same, and a stale viewer feed there re-opens the
        // disk-budget kill this heartbeat exists to prevent.
        guard dvRemuxer != nil, dvPauseHeartbeat == nil else { return }
        dvPauseHeartbeat = Task { [weak self] in
            defer { self?.dvPauseHeartbeat = nil }
            while !Task.isCancelled {
                guard let self, let remuxer = self.dvRemuxer else { return }
                // Only while actually paused — once playing, the position
                // callback owns the feed again and this task retires.
                guard !self.isPlaying else { return }
                if self.usingNativeDV {
                    remuxer.playheadSeconds = max(self.position - self.dvTimeOffset, 0)
                    remuxer.playheadUpdatedAt = Date()
                } else {
                    remuxer.viewerAbsolutePTS = max(self.position, 0)
                    remuxer.viewerAbsoluteUpdatedAt = Date()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
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
    /// The Skip Intro pill took focus during THIS gesture. It then takes a
    /// much longer pull to scroll past it, so the same nudge that grabbed the
    /// pill can't immediately overshoot into the transport controls.
    private var skipFocusTakenThisGesture = false

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
        skipFocusTakenThisGesture = false
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
            // Skip Intro first. While the pill is up it is the one thing the
            // viewer is reaching for, so ANY perceptible movement highlights
            // it — no aiming, no swipe direction to learn.
            if max(adx, ady) > 12, focusSkipIntro() {
                debug("skip intro focus")
                skipFocusTakenThisGesture = true
            }
            // Scrolling PAST a pill this gesture just grabbed needs a real
            // pull, so the nudge that selected it doesn't sail on through.
            guard max(adx, ady) > (skipFocusTakenThisGesture ? 190 : 45) else { return }
            touchIntent = .consumed
            if skipIntroFocused, ady > adx {
                // Kept scrolling off the pill → hand over to the transport
                // controls, which is what sits "below" it on screen.
                debug("swipe past skip → controls")
                skipIntroFocused = false
                showControls()
            } else if ady > adx {
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
            // Remember the LANGUAGE, not the track id — ids differ per file,
            // the language carries to every episode of the show.
            if let lang = mediaTrack.languageCode, !lang.isEmpty {
                PlaybackMemory.update(meta.id) { $0.audioLanguage = lang }
            }
        case .vlcAudio(let id):
            vlcEngine?.selectAudio(id)
        case .dvDirectAudio(let index):
            dvDirectEngine?.selectAudio(index: index)
        default:
            break
        }
    }

    func selectSubtitle(_ track: TrackOption) {
        selectedSubtitleID = track.id
        if track.id == "sub-off" {
            // An explicit OFF is a choice too — remember it, or the on-by-
            // default logic re-enables subtitles on the next episode.
            PlaybackMemory.update(meta.id) { $0.subtitleLanguage = "off" }
        }
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
        PlaybackMemory.update(meta.id) { $0.speed = speed == 1 ? nil : speed }
        if let dvDirectEngine { dvDirectEngine.rate = speed }
        else if let vlcEngine { vlcEngine.rate = speed }
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
    /// True while the Skip Intro pill OWNS focus (bare video only), so it is
    /// highlighted and a plain Select press skips. The pill is the nearest
    /// thing to hand while it's up, so the smallest nudge of the trackpad
    /// takes it — only a deliberate continued scroll falls through to the
    /// transport controls. Mirrored into the view's @FocusState both ways.
    @Published var skipIntroFocused = false {
        didSet { if skipIntroFocused { peekVisible = false } }
    }

    /// Move focus onto the Skip Intro pill if one is up over bare video.
    /// Returns false when there's nothing to take, so callers fall straight
    /// through to their normal action (open the controls, seek, ...).
    @discardableResult
    func focusSkipIntro() -> Bool {
        guard skipIntroActive, overlay == .none, !isScrubbing, !skipIntroFocused else { return false }
        skipIntroFocused = true
        return true
    }

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
            if skipIntroActive { setSkipIntroActive(false) }
            return
        }
        let inside = position >= intro.start && position < intro.end - 2
        // Auto-skip: jump straight past the intro/recap the first time we land
        // in it (no button press needed).
        if inside, settings.autoSkipSegments, !autoSkippedChapters.contains(intro.start) {
            autoSkippedChapters.insert(intro.start)
            setSkipIntroActive(false)
            seek(to: intro.end)
            showToast("Skipped intro")
            return
        }
        // Otherwise show the pill (if enabled) while inside the chapter.
        let active = inside && settings.skipIntroEnabled
        if active != skipIntroActive { setSkipIntroActive(active) }
    }

    /// Single gate for the pill's visibility — focus can never outlive it, or
    /// the invisible catcher would stay unfocused and the remote would go dead
    /// the moment the intro window closed.
    private func setSkipIntroActive(_ active: Bool) {
        skipIntroActive = active
        if !active, skipIntroFocused { skipIntroFocused = false }
    }

    /// Jump past the intro chapter.
    func skipIntro() {
        guard let intro = introChapter else { return }
        seek(to: intro.end)
        setSkipIntroActive(false)
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
        PlaybackMemory.update(meta.id) { $0.engine = engine.rawValue }
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
                self.abandonNativeDV(reason: "DV playlist never started (load watchdog)")
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
        // Direct sample engine stalled/died → drop to the next tier on the
        // same source rather than burning a different link.
        if usingDVDirect {
            Self.dvTrail("direct engine failover — \(error.localizedDescription)")
            fallBackFromDirect(entry: currentEntry, reason: error.localizedDescription)
            return
        }
        // Native-DV playback died → the remux/playlist is the suspect, not
        // the source. Fall back to the FFmpeg engine on the same source.
        if usingNativeDV {
            abandonNativeDV(reason: "playback error on the DV playlist: \(error.localizedDescription)")
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
            self.runStreamProbe()
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
                self.runStreamProbe()
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
        runStreamProbe()
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
            // While a resume seek is in flight (DV switch, item recycle),
            // `position` reads 0 for a few seconds — saving that would stomp
            // Continue Watching with the top of the movie.
            position: max(position, pendingResume ?? 0),
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
            position: max(position, pendingResume ?? 0),
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
    private var displayReleasedForExit = false

    /// Called when the exit sequence starts. Persists progress, halts
    /// playback, and detaches the render surface before teardown. Display
    /// criteria are released separately by `releaseDisplayForExit()`, after the
    /// black cover and the detached surface have had a run-loop turn to settle.
    func prepareForExit() {
        guard !isExiting else { return }
        isExiting = true
        saveProgress()
        cacheTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        countdownTask?.cancel()
        dvPauseHeartbeat?.cancel()
        dvFirstTask?.cancel()
        dvRemuxer?.cancel()   // stop the DV remux's network reads immediately
        dvDirectEngine?.stop()
        enginePause()
        // Drop any overlay so the wait shows the bare (paused) video, not a
        // half-dead confirm dialog.
        overlay = .none
        videoRefreshID = UUID()
    }

    /// Release the display mode after the video surface has been detached.
    /// Keeping this out of `prepareForExit()` avoids starting the HDMI mode
    /// restore in the same synchronous turn that still contains the native
    /// AVPlayer/DV view.
    func releaseDisplayForExit() {
        guard !displayReleasedForExit else { return }
        displayReleasedForExit = true
        // Release the display mode — ONCE, here, while the player's own black
        // screen is still up and nothing else is changing. KSPlayer's deinit
        // reset is suppressed (NuvioPlayerOptions.playerLayerDeinit) so this
        // is the only handshake, and exitPlayer holds the cover until it has
        // had time to settle.
        //
        // Skipped entirely when the user has turned the restore off: some TVs
        // mis-handshake no matter how gently the switch is sequenced, and not
        // switching back at all is the only thing that always works. tvOS
        // returns the display to its home-screen format on its own terms.
        // Deliberately releases NOTHING, ever (the Infuse policy). A revert
        // is a full HDMI renegotiation landing seconds after the player
        // closes — exactly when this user's panel wedges grey. The display
        // holds the video's mode for the rest of the foreground stint (the
        // SDR UI is tone-mapped into it, same as running the tvOS Format at
        // 4K Dolby Vision), and tvOS performs the single unavoidable revert
        // invisibly when the app backgrounds — where SessionDisplayMode also
        // clears the pin so the next stint negotiates fresh.
    }

    /// Seconds the exit must hold its black cover before tearing the player
    /// down, so the display-mode handshake finishes over a static screen
    /// instead of a disappearing video surface. Zero when no switch was made
    /// this session (the common case — exits stay instant).
    var exitDisplaySettleDelay: Double {
        0   // no in-app switch-back exists anymore, so there is no handshake to wait out
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
        dvPauseHeartbeat?.cancel()
        dvFirstTask?.cancel()
        memTracerTask?.cancel()
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
        dvDirectEngine?.stop()
        // Leak probes: 5s after teardown everything below should be freed.
        // Whichever line still prints ALIVE names the retention layer.
        weak var probeVM: PlayerViewModel? = self
        weak var probeEngine: DVSampleEngine? = dvDirectEngine
        weak var probeVideoView: UIView? = dvDirectEngine?.videoView
        dvDirectEngine = nil
        NSLog("[OrivioLeak] teardown() ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSLog("[OrivioLeak] +5s: vm=%@ engine=%@ videoView=%@",
                  probeVM == nil ? "freed" : "ALIVE",
                  probeEngine == nil ? "freed" : "ALIVE",
                  probeVideoView == nil ? "freed" : "ALIVE")
        }
        // Grab the live remuxer BEFORE resetNativeDV() retires it, so the
        // final purge actually has something to delete.
        let liveRemuxer = dvRemuxer
        resetNativeDV()
        purgeDVDirectories(live: liveRemuxer)
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
            let headers = self?.currentEntry.stream.behaviorHints?.proxyHeaders?.requestHeaders
            var bytes = self?.currentEntry.stream.behaviorHints?.videoSize
            if bytes == nil { bytes = await Self.remoteContentLength(url, headers: headers) }
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
            let thumbnailer = ScrubThumbnailer(url: url, headers: headers)
            self?.thumbnailer = thumbnailer
            let thumbs = await thumbnailer.generate()
            guard !Task.isCancelled, self?.thumbnailer === thumbnailer else { return }
            self?.thumbnailer = nil
            guard !thumbs.isEmpty else { return }
            self?.scrubThumbnails = thumbs.sorted { $0.time < $1.time }
            NSLog("[OrivioPlayer] scrub previews ready: %d frames", thumbs.count)
        }
    }

    // MARK: - Diagnostics HUD

    struct DiagnosticsSnapshot {
        var engine = "—"
        var fps = 0.0
        var droppedFrames: UInt32 = 0
        var avSyncDiff = 0.0
        var bitrateMbps = 0.0
        var bufferSeconds = 0.0
        var downloadedMB = 0.0
    }

    /// One coherent read of the live playback internals, for the HUD.
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        var snap = DiagnosticsSnapshot()
        snap.engine = usingVLC ? "VLC" : engineName + (usingNativeDV ? " · native DV" : "")
        snap.bufferSeconds = max(buffered - position, 0)
        if let info = playerLayer?.player.dynamicInfo {
            snap.fps = info.displayFPS
            snap.droppedFrames = info.droppedVideoFrameCount
            snap.avSyncDiff = info.audioVideoSyncDiff
            snap.bitrateMbps = Double(info.videoBitrate) / 1_000_000
            snap.downloadedMB = Double(info.bytesRead) / 1_048_576
        }
        return snap
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
    private static func remoteContentLength(
        _ url: URL, headers: [String: String]? = nil
    ) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
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

    /// "4:2:0 10-bit"-style label from the decoded pixel format.
    private static func chromaLabel(_ track: MediaPlayerTrack) -> String? {
        guard let format = track.formatDescription else { return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        switch subtype {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return "4:2:0"
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return "4:2:2"
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return "4:4:4"
        default:
            return nil
        }
    }

    /// Trim Apple's verbose colour constants ("ITU_R_2020") to something a
    /// person reads at a glance.
    private static func shortColorTag(_ raw: String) -> String {
        raw.replacingOccurrences(of: "ITU_R_", with: "BT.")
            .replacingOccurrences(of: "SMPTE_ST_", with: "SMPTE ")
            .replacingOccurrences(of: "_", with: " ")
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

        // WHY the session looks like this — the decision log, verbatim. First
        // section because it answers the question people actually open this
        // panel with ("why is this not Dolby Vision / why FFmpeg").
        if !decisionLog.entries.isEmpty {
            sections.append(.init(
                title: "Playback Path",
                rows: decisionLog.entries.map {
                    .init(label: $0.stage, value: "\($0.choice) — \($0.reason)")
                }
            ))
        }
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
            // Chroma + colour signalling. Worth showing verbatim rather than
            // collapsed into "HDR": a file can be BT.2020/PQ and still not be
            // Dolby Vision, and a wrong range or matrix is exactly what makes
            // an image look washed out or crushed.
            if let chroma = Self.chromaLabel(track) {
                video.append(.init(label: "Chroma", value: chroma))
            }
            if let primaries = track.colorPrimaries {
                video.append(.init(label: "Primaries", value: Self.shortColorTag(primaries)))
            }
            if let transfer = track.transferFunction {
                video.append(.init(label: "Transfer", value: Self.shortColorTag(transfer)))
            }
            if let matrix = track.yCbCrMatrix {
                video.append(.init(label: "Matrix", value: Self.shortColorTag(matrix)))
            }
            // Dolby Vision reported by PROFILE, not just as a yes/no. The
            // profile decides what can happen: 5 and 8 go out natively, 7 is
            // dual-layer and only plays natively after the RPU conversion, and
            // an 8.x file carries an HDR10 base layer to fall back on.
            if let dovi = track.dovi {
                let profile = Int(dovi.dv_profile)
                let level = Int(dovi.dv_level)
                var detail = "Profile \(profile)"
                if profile == 8 { detail += ".\(Int(dovi.dv_bl_signal_compatibility_id))" }
                if level > 0 { detail += " · level \(level)" }
                video.append(.init(label: "Dolby Vision", value: detail))
                video.append(.init(
                    label: "DV Output",
                    value: usingNativeDV
                        ? "Native Dolby Vision"
                        : (profile == 7 && !settings.dolbyVisionProfile7
                            ? "HDR10 base layer (Profile 7 conversion off)"
                            : "HDR10 base layer")
                ))
            } else if let range = track.formatDescription?.dynamicRange, range != .sdr {
                // HDR10 / HLG — anything beyond SDR is worth surfacing.
                video.append(.init(label: "HDR", value: range.description))
            }
            // HDR10+ is separate from the HDR row above: it's HDR10 PLUS
            // per-frame metadata, and what reaches the TV depends on hardware
            // this specific box may not have. Say which, in words.
            if hasHDR10Plus {
                video.append(.init(label: "HDR10+", value: "Dynamic metadata present"))
                video.append(.init(
                    label: "HDR10+ Output",
                    value: usingNativeDV && nativeKind == .hdr10Plus
                        ? "Passed through to the TV"
                        : (PerformanceProfile.supportsHDR10Plus
                            ? (settings.hdr10PlusPassthrough
                                ? "HDR10 base layer (passthrough didn't engage)"
                                : "HDR10 base layer (passthrough off)")
                            : "HDR10 base layer (\(PerformanceProfile.hdr10PlusUnavailableReason ?? "unsupported"))")
                ))
            }
            if track.fieldOrder != .progressive {
                video.append(.init(label: "Scan", value: "Interlaced (\(track.fieldOrder))"))
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
            let fmt = Self.audioFormat(track)
            if fmt.decodedToPCM {
                audio.append(.init(
                    label: "Output",
                    value: "Decoded to \(Self.channelLabel(Self.channelCount(track))) PCM — tvOS can't bitstream \(fmt.codec ?? "this format")"
                ))
            } else if fmt.atmosCapable {
                audio.append(.init(label: "Output", value: "Dolby Digital+ — Atmos passes through when the route supports it"))
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
            maybeStartNativeHDR10PlusAfterTracks()
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
            // Native-DV: "played to the end" can mean AVPlayer caught the LIVE
            // EDGE of the still-growing EVENT playlist, not the end of the
            // movie — the remux writes ahead of the viewer, and when the gap
            // closes (network dip, paced worker briefly behind) AVPlayer runs
            // off the last written segment and ends the item. Showing the
            // post-play "Finished" screen mid-movie is how that surfaced.
            // Treat it as the stall it is: fall back to the FFmpeg engine at
            // the same position and keep the movie going.
            if usingNativeDV, !dvRemuxFinished,
               dvFullDuration <= 0 || position < dvFullDuration - 30 {
                abandonNativeDV(reason: "caught the live edge of the remux mid-movie")
                return
            }
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
        // Feed the remuxer the viewer's position BEFORE the offset is applied:
        // the engine-relative time is already measured from the remux origin,
        // which is what pacing and pruning compare against. This is the signal
        // that keeps the worker from running away from the player.
        if usingNativeDV, let remuxer = dvRemuxer, currentTime.isFinite {
            remuxer.playheadSeconds = currentTime
            remuxer.playheadUpdatedAt = Date()
        } else if let remuxer = dvRemuxer, currentTime.isFinite {
            // PRE-switch: the FFmpeg engine is playing the source, so its
            // currentTime is absolute source time. Feeding it lets the worker
            // prune behind the viewer, pace itself relative to them, and gate
            // the switch on the cushion that actually matters.
            remuxer.viewerAbsolutePTS = currentTime
            remuxer.viewerAbsoluteUpdatedAt = Date()
        }
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


/// Releases the display-mode pin AFTER the player is gone.
///
/// Used only when "Restore display mode on exit" is OFF. That setting means
/// "don't fight the TV during teardown" — but it also left
/// `preferredDisplayCriteria` pinned for the REST OF THE APP'S LIFE, because
/// `displayCriteriaApplied` lives on the player view model and dies with it
/// and nothing else ever cleared the pin. The Apple TV therefore stayed in the
/// video's HDR/DV mode and the whole SDR interface rendered washed out — the
/// "screen goes grey after exiting, even on non-DV content" report. (Non-DV
/// too, because Match Frame Rate alone applies criteria.) The setting's own
/// description said tvOS would move the display back on its own terms; it
/// cannot, while the pin is held.
///
/// So the pin IS released — just not during the teardown race. Waiting until
/// the player is dismissed and the home UI has been static for a beat is the
/// sequencing difference that matters on panels which mis-handshake a switch
/// made over a video surface being destroyed.
@MainActor
enum DisplayModeRestorer {
    private static var pending: Task<Void, Never>?

    /// A new playback just claimed the display — abandon any pending release,
    /// or it would yank the mode out from under the video that just started.
    static func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    static func scheduleRelease(after delay: Double = 3) {
        cancelPending()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            UIApplication.shared.ks_keyWindow?.avDisplayManager.preferredDisplayCriteria = nil
            NSLog("[OrivioDisplay] released the display-mode pin after exit")
            pending = nil
        }
    }
}
