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
    nonisolated(unsafe) private static var pinnedRate: Float = 0
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
            lock.lock(); pinned = false; pinnedRate = 0; lock.unlock()
            NSLog("[OrivioDisplay] backgrounded — pin cleared (display already reverted by tvOS)")
        }
    }

    /// Apply `criteria` only if nothing was pinned this launch. Lock-based
    /// (not actor-isolated): callers arrive from KSPlayer's setup thread AND
    /// from the main actor, and a main.sync hop from main would deadlock.
    static func applyOnce(_ criteria: AVDisplayCriteria,
                          via manager: AVDisplayManager,
                          rate: Float = 0) -> Bool {
        // TRUST BUT VERIFY the pin: tvOS can revert the panel to its home
        // rate when playback ends even while our criteria stay set. The pin
        // then blocked the next playback's request and 24fps content played
        // into a 60Hz panel — the "smooth after force-quit, stuttery after
        // re-entry" 3:2-pulldown signature. If the panel no longer runs at
        // the rate we negotiated, the pin is stale: clear it and re-request.
        let current = Float(UIScreen.main.maximumFramesPerSecond)
        lock.lock()
        if pinned, pinnedRate > 0, abs(current - pinnedRate) > 1.5 {
            NSLog("[OrivioDisplay] pin stale (panel %.0f vs pinned %.3f) — re-requesting", current, pinnedRate)
            pinned = false
        }
        let first = !pinned
        if first { pinned = true; pinnedRate = rate }
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

final class OrivioPlayerOptions: KSOptions {
    override init() {
        super.init()
        // The app renders its own transport; KSPlayer's MPRemoteCommandCenter
        // handlers are only removed when the layer DEALLOCATES, which the
        // leak probes show can lag teardown — leaving a Play/Pause press on
        // the home screen able to restart the movie you just exited, with no
        // UI. Never register them.
        registerRemoteControll = false
    }

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
        // (typically 60Hz): keep the pulldown softening on. Only until this
        // session has actually DECIDED, though — KSPlayer calls this 2–3× per
        // load, and re-arming the softening on the later calls would undo a
        // switch that already landed.
        // Re-arm only when nothing has been pinned yet this stint; re-arming on
        // every call would undo the clear below on KSPlayer's 2nd/3rd
        // `updateVideo` for the same load.
        if lastAppliedRefreshRate == nil { pulldown60Hz = true }
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
        // The pin may ALREADY hold this content's cadence — a previous title at
        // the same rate in this foreground stint. The panel is therefore running
        // at the content rate and the 3:2 softening must be off, even though no
        // switch happens on this call and the dedupe guard below returns first.
        // Clearing it only after a successful `applyOnce` left the second and
        // every later 24fps title fighting a cadence that was not there.
        if let pinned = lastAppliedRefreshRate, abs(pinned - rate) <= 1.5 {
            pulldown60Hz = false
        }
        guard lastAppliedDynamicRange != target.rawValue
            || lastAppliedRefreshRate != rate else { return }
        lastAppliedDynamicRange = target.rawValue
        lastAppliedRefreshRate = rate
        guard let criteria = AVDisplayCriteria(refreshRate: rate, videoDynamicRange: target.rawValue)
        else { return }
        guard SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate) else { return }
        // The panel is being driven TO the content's cadence, so there is no
        // 3:2 pulldown to soften — leaving the softening on made
        // videoClockSync fight a cadence that isn't there. Cleared ONLY when a
        // switch actually happens: assigned before applyOnce it also fired when
        // the session pin already held a DIFFERENT rate (60Hz pinned by an
        // earlier title, this one 24fps), disabling the softening in exactly
        // the case the flag exists for.
        pulldown60Hz = false
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
                    domain: "Orivio", code: -3,
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
    /// Orivio-style loading backdrop (shown only during the initial load); once
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
    /// Fusion layout: the small options panel anchored to the "..." button.
    /// Lives here rather than in the view so Back can close it — the Menu
    /// press is caught at the window level, which can't see view state.
    @Published var optionsPopupVisible = false
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
    /// Embedded tracks bridged from the direct engine (this session).
    private var dvEmbeddedSubs: [DVEmbeddedSubtitleInfo] = []
    private var dvActiveEmbeddedSub: DVEmbeddedSubtitleInfo?

    var onDismiss: (() -> Void)?

    /// Fired when the playing item changes WITHIN a session (auto-advance, or
    /// the in-player episode list), so the host can re-scrobble.
    ///
    /// Scrobbling is driven off a change of the PlaybackRequest identity, and a
    /// binge never replaces that request: the player advances episodes inside
    /// the same full-screen cover. So only the first episode was ever scrobbled
    /// — episodes two onward got no start and no stop, and the eventual stop was
    /// addressed to episode one. This is the notification the host needs to keep
    /// up. It fires ONLY for in-session changes: the host already scrobbles the
    /// first item when the cover opens, and firing on the initial load would
    /// double-count it.
    var onNowPlayingChanged: ((MetaItem, MetaVideo?) -> Void)?

    // MARK: - Engine-agnostic transport (branch KS ↔ VLC)

    /// Whether playback is stopped ON PURPOSE — the user pressed pause, the app
    /// was backgrounded, or a fast-forward preview froze it.
    ///
    /// Engine STATE is not the same as intent, and the buffering callbacks
    /// below conflated them: they reported `isPlaying = true` on every
    /// `.buffering` / `.bufferFinished`, which the reader emits while filling
    /// its cache — including while paused. So sitting on a paused frame, a
    /// routine cache event flipped the player back to "playing" with no input
    /// at all. Those callbacks now ask this instead of assuming.
    private var pauseIntent = false

    private func enginePlay() {
        pauseIntent = false
        if let dvDirectEngine { dvDirectEngine.play() }
        else if let vlcEngine { vlcEngine.play() } else { playerLayer?.play() }
    }
    private func enginePause() {
        pauseIntent = true
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
        // (The native-remux window translation that used to sit here went with
        // the retired tier. It could swallow a seek outright — `return` with
        // nothing done — and nothing sets its flag any more.)
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

    // `usingNativeDV` and the playlist-window state that went with it
    // (dvTimeOffset / dvWrittenSeconds / dvPrunedThrough / dvRemuxFinished /
    // dvFullDuration / dvPlaylistURL / dvRestarting) are GONE with the remux
    // tier. Nothing had set the flag since the tier was retired, but it still
    // gated `attemptFailover`, the load watchdog, the played-to-end handler and
    // `engineSeek` — every one of them a rescue path that a stray `true` (the
    // declined-DV branch below used to set one) turned off, leaving a frozen
    // player with a spinner and no way out. Residue that disables recovery is
    // not harmless residue.

    /// HDR10+ dynamic metadata found in the source by the header probe.
    @Published private(set) var hasHDR10Plus = false
    /// One attempt per stream URL; a failed/abandoned URL never re-enters.
    private var dvFailedURLs: Set<String> = []

    /// Block-based NotificationCenter registrations, removed in deinit. The
    /// blocks capture self weakly so the VM deallocates fine either way — but
    /// without explicit removal every finished playback session leaves its
    /// dead observer blocks registered forever, each still invoked on every
    /// background/foreground/controller event.
    private var notificationTokens: [NSObjectProtocol] = []

    /// Live instance census: the question isn't whether ONE view model
    /// lingers a few seconds after dismissal (SwiftUI releases lazily), it's
    /// whether they ACCUMULATE across sessions. This counter answers it.
    nonisolated(unsafe) static var liveInstances = 0

    deinit {
        Self.liveInstances -= 1
        NSLog("[OrivioPlayer] PlayerViewModel deinit (live=%d)", Self.liveInstances)
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
    private var dvAttempted = false

    // maybeStartNativeDV removed with the legacy remux tier. DV files get
    // the direct sample engine via DV-first; everything else plays the
    // HDR10-mapped FFmpeg path.
    private func maybeStartNativeDV() {}

    // HDR10+ remux starter removed: the direct engine passes HDR10+ SEIs
    // through natively.

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
    /// Bumped by every `load()` and every `startDVFirst`. The DV-first probe
    /// takes seconds, and cancellation alone is not enough once the task is past
    /// its cancellation check — the generation tells a probe whose entry has been
    /// superseded to do nothing at all.
    private var dvFirstGeneration = 0

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

    /// True once the direct-sample session's first-tick setup has run for THIS
    /// load. Cleared by every `startDVFirst`, exactly like `vlcSessionPrepared`
    /// — see its note for why `hasStartedPlayback` can't stand in for it.
    private var dvSessionPrepared = false

    /// Last position the direct engine reported, so a tick can be told apart
    /// from PROGRESS. The engine's tick timer runs at a flat 0.5s whether the
    /// stream is advancing or frozen — see the `onTime` handler.
    private var dvLastTickTime: Double = -1

    /// Probe the header; if the file rides the direct sample engine, start it
    /// and skip the FFmpeg pipeline entirely. Anything else falls back to the
    /// normal engine path.
    private func startDVFirst(entry: StreamEntry, url: URL) {
        dvFirstTried.insert(url.absoluteString)
        currentURL = url
        dvSessionPrepared = false
        loadPhase = .loading
        // ARM THE LOAD WATCHDOG FOR THIS PATH TOO. `load()` only reaches
        // `startLoadWatchdog()` AFTER the DV-first early return, so a direct
        // start that opened but never produced a frame left the loading
        // backdrop up forever with nothing watching it. Arming here also resets
        // the per-load state the watchdogs depend on — `currentLoadStarted`,
        // `playbackProgressConfirmed`, `playbackProgressBaseline` — which a
        // mid-session DV switch otherwise inherited from the previous stream:
        // the 20s STALL watchdog, armed for that stream, could then shoot down
        // a legitimately slow DV open. It must come after `currentURL` is set,
        // since the watchdog only fires while the load it armed for is current;
        // the engine's first `onTime` disarms it via `markLoadStarted()`.
        startLoadWatchdog()
        NSLog("[OrivioDV] DV-first preflight: %@", url.host ?? "?")
        dvFirstTask?.cancel()
        dvFirstGeneration += 1
        let generation = dvFirstGeneration
        dvFirstTask = Task { [weak self] in
            let probe = await StreamProbe.inspect(
                url: url.absoluteString,
                needsStyledASS: false, needsHDR10Plus: false,
                needsDolbyVision: true, timeoutSeconds: 5
            )
            guard let self, !Task.isCancelled, !self.isExiting,
                  // A newer load (source switch, episode change) superseded this
                  // probe while it was in flight. Acting now would either revert
                  // the viewer's switch through the fallback `load(entry:)`
                  // below — saving progress under the wrong link — or stack a DV
                  // engine on top of the stream already playing, doubling audio.
                  self.dvFirstGeneration == generation
            else { return }
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
            // Baseline for the progress test in `onTime`: the engine reports
            // the start position from its very first tick, before a single
            // frame has been decoded, so that first tick must not count as
            // movement.
            self.dvLastTickTime = resume

            // TIER 1: the sample-feed engine — no AVPlayer, no HLS, no
            // CoreMedia retention; the app owns (and bounds) every buffer.
            // Its failure falls to TIER 2, the remux+AVPlayer path.
            // The sample engine builds its own renderers, so no KSPlayer init
            // runs to configure the audio session (the VLC path had this same
            // gap). Configure BEFORE reading the route below — an inactive
            // session reports no spatial outputs, which silently forced a
            // stereo downmix on Atmos rigs for cold-launched DV titles.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            // Downmix in-engine when the route can't use multichannel —
            // see DVSampleEngine.downmixToStereo.
            let spatial = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.isSpatialAudioEnabled }
            // FEL titles keep true DV (user's choice). The HDR10-base-layer
            // experiment ran and EXONERATED the converted metadata: the one
            // stuttering FEL title stuttered identically as pure HDR10, and
            // a heavier FEL twin plays smooth as converted DV. forceHDR10
            // stays available as a diagnostic lever.
            let felHDR10 = false
            let engine = DVSampleEngine(
                input: url.absoluteString, startAt: resume,
                // Per-title memory outranks the global preference: the track you
                // picked for this movie/show is what you meant for it.
                preferredAudioLanguage: PlaybackMemory.memory(for: self.meta.id)?.audioLanguage
                    ?? self.settings.preferredAudioLanguage,
                convertProfile7: p7ok,
                requestHeaders: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders,
                downmixToStereo: !spatial,
                forceHDR10: felHDR10,
                preferredAudioLabel: PlaybackMemory.memory(for: self.meta.id)?.audioTrackLabel
            )
            self.dvDirectEngine = engine
            self.duration = probe.durationSeconds
            self.clock.duration = probe.durationSeconds
            engine.onTime = { [weak self, weak engine] seconds in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                self.position = seconds
                self.clock.position = seconds
                self.isPlaying = engine.isPlaying
                // BUFFERING IS ABOUT PROGRESS, NOT ABOUT TICKS.
                //
                // This tick comes off a fixed 0.5s timer in the engine that
                // fires whether or not the stream is advancing, and clearing
                // the flag unconditionally made a stalled DV stream
                // undetectable: `onBuffering(true)` set it, the next tick
                // cleared it 500ms later, and that genuine true→false
                // transition re-armed the 20-second stall watchdog forever and
                // cancelled the spinner's debounce. A frozen picture, no
                // spinner, and no failover — for as long as the stream stayed
                // dead. Only an advancing clock clears it now; the normal case
                // clears on the very next tick exactly as before.
                let advanced = seconds > self.dvLastTickTime + 0.01
                self.dvLastTickTime = seconds
                if advanced { self.isBuffering = false }
                // Keyed off a PER-LOAD flag, not `hasStartedPlayback` (which
                // nothing resets): a DV session that BEGINS mid-movie — a
                // source switch or a failover onto a DV link — arrives with
                // `hasStartedPlayback` already true, so this block never ran
                // and `pendingResume` stayed set for the rest of the session.
                // Same class of bug (and same fix) as `vlcSessionPrepared`.
                if !self.dvSessionPrepared, seconds > resume + 0.2 {
                    self.dvSessionPrepared = true
                    self.loadPhase = nil
                    if !self.hasStartedPlayback {
                        self.hasStartedPlayback = true
                        self.showControls()
                    }
                    // The resume is DELIVERED — stop clamping saves to it.
                    // Left set, max(position, pendingResume) meant Continue
                    // Watching could never record a position below the
                    // session's entry point: exit after a rewind (or earlier
                    // than you resumed) and the row snapped back.
                    self.pendingResume = nil
                }
                // Only an ADVANCING clock proves the load is alive. Disarming
                // the 30s load watchdog on the bare tick told it a DV open that
                // never produced a frame was healthy — and since the stall
                // watchdog needs `hasStartedPlayback` (which only the block
                // above sets, on real progress), that left the newly armed
                // watchdog with nothing to catch: a spinner forever.
                if advanced { self.markLoadStarted() }
                self.markPlaybackProgressed(currentTime: seconds)
                self.saveProgressThrottled()
                self.updateSkipIntro()
                // The Up Next card has to arm from the TICK, like the KSPlayer
                // and VLC paths do — armed only from `onEnded`, a DV session's
                // card appeared after the file was over instead of over the
                // credits.
                self.maybeArmAutoNext()
                // Addon subtitles: the model picks the cue for this instant;
                // the overlay renders it. KSPlayer normally drives this from
                // its own clock — the direct engine drives it from its ticks.
                // Pass the RAW time: SubtitleModel.subtitle(currentTime:)
                // subtracts `subtitleDelay` itself, so adding it here cancelled
                // it out and the delay control did nothing on DV sessions.
                _ = self.subtitleModel.subtitle(currentTime: seconds)
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
                    if engine.forceHDR10 {
                        dvLabel = "Native HDR10 (P7 FEL base layer, direct sample feed)"
                    } else {
                    switch realProfile {
                    case 0: dvLabel = "Native \(probe.isPQ ? "HDR10\(probe.hasHDR10Plus ? "+" : "")" : "HEVC") (direct sample feed)"
                    case 7: dvLabel = "Native DV (direct sample feed, Profile 7 → 8.1)"
                    default: dvLabel = "Native DV (direct sample feed, Profile \(realProfile))"
                    }
                    }
                    self.decisionLog.record("Dolby Vision", dvLabel,
                                            because: "compressed samples fed straight to the display pipeline — no remux, no server")
                    self.decisionLog.record("Engine", "DV Sample Feed",
                                            because: "AVSampleBufferDisplayLayer owns rendering for this session")
                    // FEL/MEL verdict arrives ~10s in, measured from the
                    // stream itself — surface it in the decision panel.
                    DVSampleEngine.onELVerdict = { [weak self] verdict in
                        guard let self, self.dvDirectEngine != nil else { return }
                        self.decisionLog.record("DV Layer", verdict,
                                                because: "measured from the enhancement-layer NAL sizes in the stream")
                    }
                    // SEQUENCE THE SWITCH LIKE INFUSE. Requesting the display
                    // mode right after attaching a live video surface put the
                    // HDMI renegotiation on top of a surface coming alive —
                    // the overlap that wedged this panel grey ON ENTRY. So:
                    // switch FIRST, while the loading screen is static and the
                    // engine is held paused with its view unattached; attach
                    // and roll only once the panel has settled (UIScreen's
                    // fps changing is the ground truth that the mode took).
                    var switching = false
                    if profile > 0, !engine.forceHDR10 {
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
                    // Embedded subtitle tracks: bridge each into the shared
                    // SubtitleModel; the picker/overlay treat them like any
                    // other subtitle source. Cues stream in live.
                    self.dvEmbeddedSubs = engine.subtitleTracks.map {
                        DVEmbeddedSubtitleInfo(streamIndex: $0.index, label: "\($0.label) · Embedded")
                    }
                    self.dvEmbeddedSubs.forEach { self.subtitleModel.addSubtitle(info: $0) }
                    engine.onSubtitleEvent = { [weak self] start, end, text, image in
                        guard let self, let active = self.dvActiveEmbeddedSub else { return }
                        active.add(start: start, end: end, text: text, image: image,
                                   playhead: self.position)
                    }
                    self.fetchAddonSubtitles()
                    self.rebuildSubtitleOptions()
                    // Chapters (Skip Intro, timeline ticks) + scrub previews —
                    // the same features every other engine session gets.
                    self.chapters = engine.chapters
                    self.startThumbnailsIfNeeded()
                    self.trailMem("direct start")
                } else {
                    Self.dvTrail("direct engine declined (\(reason)) — FFmpeg reload")
                    self.fallBackFromDirect(entry: entry, reason: reason, profile: profile)
                }
            }
            // The 45s "no playable playlist" fallback that used to live here is
            // gone with the remux tier it watched: it was guarded on
            // `usingNativeDV` (never set any more) AND `!hasStartedPlayback`
            // (already true for every mid-session start), so it could not fire.
            // `startLoadWatchdog()` above is the real cover — it is armed for
            // this load, disarmed by the engine's first tick, and its expiry
            // routes through `attemptFailover`, which drops a stuck direct
            // engine onto the FFmpeg path.
        }
    }

    /// Direct-engine failure or decline: tear the engine down and reload the
    /// same source on the ordinary FFmpeg path.
    ///
    /// There is no second tier any more. This used to fork on `toRemux`, which
    /// set `usingNativeDV`/`dvRestarting` and then handed off to a remux tier
    /// that had already been retired — so a DECLINED mid-session DV attempt
    /// (source switch, episode advance onto a DV-named link) simply stopped
    /// here: no engine, no player, no error. Worse, `usingNativeDV` then
    /// short-circuited `attemptFailover`, the load watchdog and the
    /// played-to-end handler, and the only rescue left was a 45s timer guarded
    /// on `!hasStartedPlayback` — already true mid-session. The result was a
    /// permanently spinning player. A decline now falls through to the reload
    /// that has always worked, whatever the profile.
    private func fallBackFromDirect(entry: StreamEntry, reason: String, profile: Int = 0) {
        dvDirectEngine?.stop()
        dvDirectEngine = nil
        videoRefreshID = UUID()   // detach the dead engine's layer view
        if profile > 0 {
            decisionLog.record("Dolby Vision", nativeFallbackLabel,
                               because: "direct sample feed declined: \(reason)")
        }
        load(entry: entry)
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
        if SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate) {
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
        if SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate) {
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

    // startDVRemux removed with the legacy remux tier: the direct sample
    // engine is the only native pipeline; its failures fall to FFmpeg.

    // switchToNativeDV removed with the legacy remux tier.

    // restartNativeDV removed with the legacy remux tier.

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
            while !Task.isCancelled {
                // A flat 40s cadence now. The 12s cadence and the predictive
                // memory guard that rode on it existed for the remux tier's
                // burst retention (941 MB → jetsam inside one 40s gap); both
                // were gated on `usingNativeDV`, so neither has run since that
                // tier was retired, and the guard's only remaining action was
                // to log a step-down it could no longer perform. The direct
                // engine bounds its own buffers by construction — the trail
                // line below is what is actually still worth having.
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                guard let self, !self.isExiting else { return }
                self.trailMem("periodic")
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
        else if vlcEngine != nil { phase = "vlc" }
        else { phase = "ffmpeg" }
        guard result == KERN_SUCCESS else {
            Self.dvTrail("mem ? \(phase) (\(why))"); return
        }
        // Carry the presentation census with the memory line: the trail is the
        // only record that outlives the session, and "is it jittery" is
        // answered by repeats/skips, not by footprint.
        let census = dvDirectEngine.map { " \($0.lastVsyncCensus)" } ?? ""
        let mb = Double(info.phys_footprint) / 1_048_576
        let anon = Double(info.internal) / 1_048_576
        let comp = Double(info.compressed) / 1_048_576
        // THE EXPERIMENT IS OVER, AND IT ANSWERED ITSELF.
        //
        // This used to call `malloc_zone_pressure_relief(nil, 0)` here and
        // resample, to test whether the compressed ballast was allocator
        // retention. Every breadcrumb it ever wrote came back X→X: across the
        // whole persisted trail, on every engine, the delta was ZERO. malloc
        // was holding nothing, so the call reclaimed nothing.
        //
        // What it DID do was run on the main actor, every 40 seconds, for the
        // entire film. `nil` zone means all zones and 0 means "release as much
        // as possible", so it walks every free list in a ~450 MB heap full of
        // video buffers and madvises pages back to the kernel — unbounded work
        // in the middle of playback. That is the periodic one-to-two second
        // freeze with no buffering indicator: not the network, not the decoder,
        // just the diagnostic stopping the world to measure a number that never
        // changed. Measure once, cheaply, and get out.
        Self.dvTrail(String(
            format: "mem %.0fMB int=%.0f cmp=%.0f %@ pos=%.0fs (%@)%@",
            mb, anon, comp, phase, position, why, census
        ))
    }

    /// Append one line to the persisted DV trail (newest LAST — the previous
    /// overwrite-style key lost the interesting first error under the later
    /// abandon message).
    /// Serializes the persisted-trail read/append/write off the main actor —
    /// the periodic mem-trace called this every ~36s DURING playback, and a
    /// synchronized UserDefaults write on the main thread is the same hiccup
    /// class ProgressStore already moved off-main.
    private static let trailQueue = DispatchQueue(label: "orivio.dvtrail", qos: .utility)

    static func dvTrail(_ line: String) {
        // Mirrored to the console so a live-attached session sees the trail
        // in real time, not only after the fact.
        NSLog("[OrivioTrail] %@", line)
        let entry = String("\(Date()): \(line)".prefix(maxTrailEntryChars))
        trailQueue.async {
            var trail = UserDefaults.standard.stringArray(forKey: "dev.dvTrail") ?? []
            trail.append(entry)
            if trail.count > 30 { trail.removeFirst(trail.count - 30) }
            // Belt as well as braces: bound the TOTAL, so no combination of
            // long entries can ever grow the value without limit again.
            while trail.count > 1,
                  trail.reduce(0, { $0 + $1.utf8.count }) > maxTrailBytes {
                trail.removeFirst()
            }
            UserDefaults.standard.set(trail, forKey: "dev.dvTrail")
        }
    }

    // abandonNativeDV removed with the legacy remux tier.

    /// Tear down DV state (normal loads, teardown). Keeps dvFailedURLs.
    private func resetNativeDV() {
        // The DIRECT engine too: without this, an in-player engine switch (or
        // any reload) built the new player while the old sample engine kept
        // demuxing and playing audio — and activeVideoView still returned its
        // layer: frozen picture over doubled audio ("switching players mid-
        // movie freezes and everything is all weird").
        if let engine = dvDirectEngine {
            engine.stop()
            dvDirectEngine = nil
            videoRefreshID = UUID()   // make PlayerVideoView re-read activeVideoView
        }
        dvAttempted = false
        dvLastTickTime = -1
        // Back to the default payload. Left at .hdr10Plus, the next title's DV
        // session would mislabel itself and skip the dvvC handling.
        nativeKind = .dolbyVision
    }

    // Legacy remux tier retired: its segment directories no longer exist,
    // so there is nothing to purge. PlayerTempSweep still clears any
    // leftovers from older builds at launch.

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
    private var transientSaveCount = 0
    /// Seconds between periodic crash-safety progress writes.
    private static let progressSaveInterval: TimeInterval = 10
    private var lastSubtitleSearchAt: Double = -1
    private var pendingResume: Double?
    /// Where this session picked the film up, so the exit can tell a viewer who
    /// watched from one who bailed out.
    private var sessionStartPosition: Double = 0
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
    /// Seconds of buffer ahead of the playhead, mirrored for the thumbnailer's
    /// worker thread (which cannot touch main-actor state). Updated on the
    /// position tick.
    private let bufferAhead = Atomic<Double>(wrappedValue: 0)
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
        Self.liveInstances += 1
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
        self.sessionStartPosition = request.resumePosition ?? 0

        // Pause the 30s account auto-sync for the duration of playback — a
        // multi-endpoint sync competing for bandwidth mid-stream is exactly the
        // wrong time on a high-bitrate remux.
        OrivioSyncManager.playbackActive = true
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
            // (The `!usingNativeDV` term that used to guard this reroute is
            // gone with the flag. NOTE for review: its INTENT was "never yank a
            // native-DV session over to VLC", and the direct engine has had no
            // equivalent guard since the tier was retired — a styled-ASS
            // subtitle currently reroutes a DV-direct session to VLC and loses
            // Dolby Vision. Left as-is rather than guessed at.)
            guard result.hasStyledASS,
                  self.effectiveEngine != .vlc else { return }
            NSLog("[OrivioSubs] styled ASS detected — routing to VLC for full rendering")
            self.switchEngine(.vlc)
        }
    }

    // HDR10+ remux path retired: the direct engine passes HDR10+ SEIs through.

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
        // Siri, FaceTime, another app seizing the audio session: only the
        // KSPlayer engine observes interruptions itself — the VLC and DV
        // engines would keep advancing video with dead audio. Route .began
        // through the same clean-pause path as the app switcher; deliberately
        // no auto-resume on .ended ("press play to continue" policy).
        notificationTokens.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self?.handleResignActive()
            }
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
            // (The offset-playlist branch that used to sit here went with the
            // remux tier. NOTE for review: a DV-DIRECT session takes this path
            // with `playerLayer == nil`, so the resync is a no-op for it —
            // unchanged from before, and not something to guess at here.)
            playerLayer?.seek(time: target, autoPlay: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleResyncClear(after: 0.2) }
            }
            // Safety net in case the seek callback never fires.
            scheduleResyncClear(after: 1.5)
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
        // Any DV-first probe still in flight belongs to the PREVIOUS entry.
        // Left alone, its completion either reverts this load or installs a
        // second engine underneath it. `startDVFirst` re-arms below when this
        // load is itself a DV-first one.
        dvFirstTask?.cancel()
        dvFirstGeneration += 1
        // A load always starts a stream that is meant to PLAY, so a stale pause
        // intent must not survive into it. Nothing else in the load path cleared
        // it, which made two situations stick: the Still Watching gate pauses via
        // `enginePause()` and its "Continue" resumes by LOADING the next episode,
        // and pausing before an in-player source or engine switch does the same.
        // In both, the buffering callbacks then read the stale intent and pinned
        // `isPlaying` false over a running picture — the screensaver coming up
        // mid-film, controls that never auto-hide, and a Play press that resumed
        // again instead of pausing.
        pauseIntent = false

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

        let options = OrivioPlayerOptions()
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
            // playback start (OrivioTVApp) — if a session lands here anyway
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
        // RESUME: open the stream AT the saved position instead of opening at
        // zero and seeking afterwards.
        //
        // This is why Continue Watching took so much longer to start than a
        // fresh play. Opening at 0 demuxes, decodes and fills the buffer at the
        // top of the film; the `.readyToPlay` seek then flushes all of it and
        // refills from a completely different byte offset — the whole opening
        // cost paid twice, plus a second range request. On a large remux over
        // debrid that is most of the wait.
        //
        // MEPlayerItem honours `startPlayTime` during open, so FFmpeg seeks
        // while the container is being read and only one fill ever happens.
        // The `.readyToPlay` seek stays as the fallback for engines that ignore
        // it; it checks how far off the position already is before acting.
        if let resume = pendingResume, resume > 5,
           duration <= 0 || resume < duration - 30 {
            options.startPlayTime = resume
        }
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
        dismissedIntroStart = nil
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

    /// Cleared by every `loadViaVLC`, so a mid-session switch INTO VLC runs the
    /// same first-play setup a cold start does.
    ///
    /// This block used to key off `hasStartedPlayback`, which nothing ever resets
    /// — so switching engine mid-film (or the automatic styled-ASS reroute, which
    /// fires after playback has started) skipped the resume seek, the track
    /// lists, the addon subtitles and the speed: the movie restarted at 0 with
    /// empty audio/subtitle pickers, and `pendingResume` stayed set so every
    /// later save floored progress at the switch point.
    private var vlcSessionPrepared = false

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
        dismissedIntroStart = nil
        engineName = "VLC"
        vlcSessionPrepared = false
        if !hasStartedPlayback {
            loadPhase = .loading   // VLC never enters the .caching hold
            cacheProgress = 0
        }

        // VLC never touches KSPlayer, and KSPlayer is what normally puts the
        // audio session into .playback/.moviePlayback (KSAVPlayer/KSMEPlayer
        // both call KSOptions.setAudioSession on init). A VLC-only session
        // therefore ran on tvOS's default .soloAmbient category — the wrong
        // ducking, interruption and route policy for long-form video.
        // Default route-sharing policy: tvOS then follows the user's Default
        // Audio Output (HomePods). See KSOptions.setAudioSession.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback
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

        if playing, !vlcSessionPrepared {
            vlcSessionPrepared = true
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
                // VLCKit can override a seek issued at the first `playing`
                // flip with its own position once the media finishes opening
                // — the "VLC restarts the movie" bug. Re-assert until the
                // position actually lands near the target.
                Task { [weak self] in
                    for _ in 0 ..< 4 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let self, !self.isExiting, self.vlcEngine != nil else { return }
                        if self.position >= resume - 10 { return }
                        self.vlcEngine?.seek(to: resume)
                    }
                }
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
        selectSubtitle(pick, userInitiated: false)
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
    private func keepDVPlayheadFreshWhilePaused() {}   // legacy remux tier retired

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

    // Blind display re-sync: three Play/Pause presses within 1.5s. Exists
    // because the HDMI-handshake wedge leaves the WHOLE screen grey — no
    // menu is visible, so the recovery has to work by feel. It performs the
    // electronic equivalent of the TV input toggle that recovers the panel:
    // drop the display criteria, let the TV fall back to its home mode, then
    // re-request the pinned mode fresh.
    private var playPausePressTimes: [Date] = []

    func resyncDisplay() {
        overlay = .none
        guard let manager = UIApplication.shared.ks_keyWindow?.avDisplayManager else { return }
        let held = manager.preferredDisplayCriteria
        manager.preferredDisplayCriteria = nil
        showToast("Re-syncing display…")
        NSLog("[OrivioDisplay] manual display re-sync — dropping and re-requesting the mode")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // If the viewer bailed out during the blind re-sync, do NOT fire a
            // fresh HDMI handshake over the browsing UI — that is the exact
            // wedge this recovery gesture exists to escape.
            guard let self, !self.isExiting else { return }
            manager.preferredDisplayCriteria = held
        }
    }

    func togglePlayPause() {
        // Ignore input while exiting, or during the sub-second post-background
        // resync (a play press then would race the in-flight flush-seek).
        guard !isExiting, !isResyncing else { return }
        playPausePressTimes.append(Date())
        playPausePressTimes.removeAll { Date().timeIntervalSince($0) > 1.5 }
        if playPausePressTimes.count >= 3 {
            playPausePressTimes.removeAll()
            resyncDisplay()
            return
        }
        // If a fast-forward/rewind preview is up, Play commits it (seek + resume).
        if scanPreview != nil { scanCommit(); return }
        if isPlaying {
            enginePause()
            // Pausing is the moment a viewer is most likely to leave — by the
            // remote, by the TV button, or by pulling the plug. Publish the
            // position here rather than relying on the exit path being reached,
            // so "I paused two minutes in and came back later" always resumes.
            saveProgress()
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
            // engineSeek autoplays but BYPASSES enginePlay, so the intent has to
            // be cleared here — exactly as `seek(to:)` does for the same reason.
            // Without it the buffer events that follow read `pauseIntent` as
            // "still paused" and pin `isPlaying` false while the picture is
            // actually running: the idle timer stays armed (screensaver over a
            // playing film), the controls never auto-hide, and the next
            // Play/Pause press resumes AGAIN instead of pausing — the transport
            // stays stuck until some other path clears the flag.
            pauseIntent = false
            // A real resume is also the one thing allowed to reset the pause
            // clock (see the `.buffering` handler); those callbacks only do it
            // when the intent is already clear, so do it here for the case
            // where no buffer event follows a warm seek.
            pausedAt = nil
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

    /// Seek, keeping the transport state you were in.
    ///
    /// `autoPlay` defaults to nil, meaning "whatever we were doing" — a seek
    /// from a PAUSED player leaves it paused. It used to pass `true`
    /// unconditionally, which is why pausing and then pressing skip started
    /// playback again about two thirds of a second later (the nudge commits on
    /// a debounce), with nothing on screen to explain it. Callers that must
    /// start playback — committing a fast-forward preview, restarting a
    /// finished title — pass `true` explicitly.
    func seek(to seconds: Double, autoPlay: Bool? = nil) {
        let target = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        position = target
        clock.position = target   // instant UI feedback, no waiting for a tick
        lastUserSeekAt = Date()
        // The user's own seek replaces the resume target outright (including
        // seeking BACKWARDS — otherwise the floor would drag them forward again
        // on the next failover).
        sessionResumeFloor = target
        playedToEndHandled = false
        let play = autoPlay ?? isPlaying
        // engineSeek starts playback itself, bypassing enginePlay, so the
        // intent has to be cleared here or the buffer events that follow the
        // seek would be read as "still paused".
        if play { pauseIntent = false }
        engineSeek(to: target, autoPlay: play)
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
        // Turned far enough to leave the dense window — fetch the next one.
        startFineThumbnailsIfNeeded(around: clamped)
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
        // AFTER resetWheel, which clears it.
        wheelAwaitingLift = true
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
        clearFineThumbnails()
        scrubTimeoutTask?.cancel()
        // Leave the bar up briefly so you see where you landed, Netflix-style.
        showControls()
    }

    func cancelScrub() {
        clock.scrubTarget = nil
        scrubValue = nil
        isScrubbing = false
        resetWheel()
        clearFineThumbnails()
        scrubTimeoutTask?.cancel()
    }

    /// Coarse jump while in scrub mode: a left/right press moves the target by
    /// the configured scrubber-jump amount (default a minute) — pan drags,
    /// presses hop, a rested finger becomes the fine-tune wheel.
    func scrubJump(_ seconds: Double) {
        // The wheel owns the whole pad while it is turning. A circling thumb
        // brushes the pad's edges, which the remote also reports as directional
        // presses — and a jump of a minute in the middle of a two-second
        // adjustment is the opposite of fine-tuning.
        guard !wheelEngaged else { return }
        guard isScrubbing, let target = scrubValue else { return }
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        publishScrub(clamped)
        restartScrubTimeout()
    }

    // MARK: - Wheel fine-tune (rest a finger on the pad, then circle)

    /// True once the wheel has taken the pad — fine-tune mode. Drives the
    /// on-screen indicator and locks out every other scrub input.
    @Published private(set) var wheelEngaged = false
    private var wheelLastAngle: Double?
    /// Consecutive near-zero samples, so one glitchy reading can't end a turn.
    private var wheelLiftSamples = 0
    /// When the current stationary contact began, and where it landed.
    private var wheelHoldStart: Date?
    private var wheelHoldOrigin: (x: Double, y: Double)?
    /// The finger moved before the hold completed, so this touch is a scrub
    /// drag and must never turn into a wheel part-way through.
    private var wheelHoldDisqualified = false
    /// How long a finger has to sit on the outer ring before the wheel takes
    /// over. A beat, not a wait — long enough that swiping THROUGH the rim
    /// during a side-to-side scrub doesn't trigger it.
    private let wheelHoldSeconds: TimeInterval = 0.25
    /// How far out counts as the outer ring (the pad reports -1…1 from centre).
    private let wheelRingRadius: Double = 0.72
    /// Fires the engage. The hold CANNOT be measured from the sample stream:
    /// `microGamepad.dpad.valueChangedHandler` only fires when the value
    /// CHANGES, so a finger held perfectly still produces no further samples at
    /// all — which is exactly the gesture we are waiting for. Checking elapsed
    /// time inside `wheelSample` therefore never ran again after the first
    /// touch, and the wheel could never engage. A timer, armed on contact, is
    /// the only thing that can see a still finger.
    private var wheelHoldTask: Task<Void, Never>?
    /// Whether a finger is currently down, maintained by the sample stream
    /// (contact and lift both change the value, so both do arrive).
    private var wheelTouching = false
    /// Set when scrubbing begins: the touch that is ALREADY on the pad cannot
    /// arm the hold. Clicking Select to enter scrub leaves your finger resting
    /// on the trackpad — a click is a press — so that same contact satisfied
    /// the rest-to-engage timer half a second later and threw you straight into
    /// fine-tune before you had scrubbed anything. Only a touch that begins
    /// AFTER a lift counts.
    private var wheelAwaitingLift = false
    /// Movement (in pad units, the pad being -1…1) that marks a touch as a drag
    /// rather than a rest.
    private let wheelHoldSlop: Double = 0.16
    /// One full revolution ≈ this many seconds — small, because it's FINE tuning.
    private let wheelSecondsPerRevolution: Double = 24

    /// GameController absolute finger position ((0,0) = not touching).
    private func wheelSample(x: Double, y: Double) {
        guard isScrubbing else { resetWheel(); return }
        let radius = (x * x + y * y).squareRoot()

        // Finger LIFTED → leave fine-tune; normal pan owns the scrub again.
        //
        // The bar for "lifted" is deliberately near zero and needs two samples
        // in a row. It used to be 0.1, which a finger passing anywhere near the
        // middle of the pad crosses on its way round — so a single sloppy
        // circle dropped out of fine-tune and the rest of that same gesture
        // landed on the pan recognizer as a scrub. Once engaged, the wheel
        // holds until you actually take your thumb off.
        // LIFT — acted on immediately, and on a SINGLE sample.
        //
        // It has to be one: the pad only reports on VALUE CHANGE, so lifting
        // produces exactly one (0,0) event and then silence. Waiting for a
        // second consecutive near-zero reading meant the second never came and
        // the wheel stayed engaged after you took your finger off — scrubbing
        // was dead until you touched and lifted again. The 0.02 threshold is
        // low enough that only a real lift reaches it.
        if radius < 0.02 {
            wheelLiftSamples += 1
            if wheelLiftSamples >= 1 {
                wheelTouching = false
                // A real lift: whatever was on the pad when scrubbing started
                // is gone, so the next touch is a fresh gesture and may arm.
                wheelAwaitingLift = false
                wheelHoldTask?.cancel()
                wheelHoldTask = nil
                wheelEngaged = false
                wheelLastAngle = nil
                wheelHoldStart = nil
                wheelHoldOrigin = nil
                wheelHoldDisqualified = false
                // The dense frames STAY. Lifting off the wheel is a pause in
                // the middle of one adjustment, not the end of it — you drop
                // back to coarse scrubbing and are expected to rest again a
                // moment later. Throwing them away here meant re-running a
                // decode pass every single time.
            }
            return
        }
        wheelLiftSamples = 0
        if !wheelTouching { restartScrubTimeout() }   // a new touch is activity
        wheelTouching = true
        // ENGAGE by putting a finger on the OUTER RING and leaving it there for
        // a beat. Side-to-side anywhere else stays a plain scrub.
        //
        // The rim is the gate and the quarter-second is what separates resting
        // there from swiping across it: a scrub that runs out to the edge and
        // keeps going is moving, so it is disqualified for the rest of that
        // touch — a gesture must not change meaning half way through. Once
        // engaged the WHOLE pad is the wheel, so you can circle inward, until
        // you lift.
        if !wheelEngaged {
            if let origin = wheelHoldOrigin {
                let travel = ((x - origin.x) * (x - origin.x)
                              + (y - origin.y) * (y - origin.y)).squareRoot()
                if travel > wheelHoldSlop, !wheelHoldDisqualified {
                    wheelHoldDisqualified = true
                    wheelHoldTask?.cancel()
                    wheelHoldTask = nil
                }
            } else if !wheelAwaitingLift, radius > wheelRingRadius {
                wheelHoldOrigin = (x, y)
                wheelHoldStart = Date()
                armWheelHold()
            }
            return   // the timer engages, not this sample
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

    /// Arm the rest-to-engage timer for the touch that just landed.
    private func armWheelHold() {
        wheelHoldTask?.cancel()
        wheelHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.wheelHoldSeconds ?? 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isScrubbing, self.wheelTouching,
                  !self.wheelHoldDisqualified, !self.wheelEngaged else { return }
            self.wheelEngaged = true
            self.wheelLastAngle = nil
            self.startFineThumbnailsIfNeeded(around: self.scrubValue ?? self.position)
        }
    }

    private func resetWheel() {
        wheelHoldTask?.cancel()
        wheelHoldTask = nil
        wheelLastAngle = nil
        wheelEngaged = false
        wheelLiftSamples = 0
        wheelTouching = false
        wheelHoldStart = nil
        wheelHoldOrigin = nil
        wheelHoldDisqualified = false
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
            guard !Task.isCancelled, let self else { return }
            // Never time out mid-adjustment. The intended flow is a series of
            // deliberate pauses — scrub, lift, rest to take the wheel, circle,
            // lift, scrub again — and a finger resting on the pad is the one
            // gesture that generates no samples at all. Dropping the whole
            // scrub out from under that is exactly wrong.
            guard !self.wheelEngaged, !self.wheelTouching else {
                self.restartScrubTimeout()
                return
            }
            self.cancelScrub()
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
        if overlay == .controls {
            // Never leave the options panel flagged open under bare video: the
            // next showControls would draw it with focus on the bar and no
            // way back into it.
            optionsPopupVisible = false
            overlay = .none
        }
    }

    func restartHideTimer() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            // Idle time before the controls go away. Every remote interaction
            // (focus moves included) restarts this, so they never vanish
            // mid-navigation.
            //
            // Was 3s, which is fine when the transport is a row of buttons you
            // are stepping through — each move resets the clock. Fusion's whole
            // transport is ONE bar: you look at it, decide, and press, with no
            // intervening input to restart the timer. Three seconds of that is
            // easy to exceed, and then the press lands on hidden controls and
            // merely brings them back rather than starting a scrub — which
            // reads as "half the time Select does nothing".
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Keep the transport up while a fast-forward/rewind preview is
            // active (so the moving playhead stays visible); otherwise hide once
            // idle + playing.
            // ...and never while the options panel is open — hiding then
            // unmounts the panel with focus inside it and leaves it flagged
            // visible, so it came back orphaned (drawn, unreachable).
            if overlay == .controls, isPlaying, scanPreview == nil, !optionsPopupVisible {
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
        // Fusion's options panel closes back to the controls, never out of the
        // player — same rule the side panels follow below.
        if optionsPopupVisible {
            optionsPopupVisible = false
            restartHideTimer()
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
            // Remember BOTH: the exact label (distinguishes AC3-6ch from the
            // TrueHD default on an all-English remux) and the language (which
            // carries across episodes/releases where labels differ).
            if let track = dvDirectEngine?.audioTracks.first(where: { $0.index == index }) {
                PlaybackMemory.update(meta.id) {
                    $0.audioTrackLabel = track.label
                    if !track.lang.isEmpty { $0.audioLanguage = track.lang }
                }
            }
        default:
            break
        }
    }

    /// - Parameter userInitiated: false for the automatic default-subtitle
    ///   pick. `PlaybackMemory` is meant to hold the viewer's OWN choices, and
    ///   writing an automatic pick there contradicts that — the automatic path
    ///   would record a language the viewer never selected.
    func selectSubtitle(_ track: TrackOption, userInitiated: Bool = true) {
        selectedSubtitleID = track.id
        if track.id == "sub-off" {
            // An explicit OFF is a choice too — remember it, or the on-by-
            // default logic re-enables subtitles on the next episode.
            if userInitiated { PlaybackMemory.update(meta.id) { $0.subtitleLanguage = "off" } }
        } else {
            // …and picking a REAL track has to retire that sentinel. Nothing
            // cleared it before, so a single "Off" press permanently disabled
            // subtitles-on-by-default for the title/show: applyDefaultSubtitle-
            // IfNeeded reads "off" and returns early forever. Remember the
            // language when the track NAMES it (deliberately the strict
            // spelled-out match, not optionMatchesLanguage's bare two-letter
            // contains — "Chinese" contains "es"); otherwise just clear it.
            let name = track.displayName.lowercased()
            let lang = PlayerSettings.subtitleLanguageOptions.first {
                guard !$0.0.isEmpty,
                      let localized = Locale.current.localizedString(forLanguageCode: $0.0)?.lowercased()
                else { return false }
                return name.contains(localized)
            }?.0
            if userInitiated { PlaybackMemory.update(meta.id) { $0.subtitleLanguage = lang } }
        }
        switch track.payload {
        case .subtitle(let info):
            // Addon subtitles are downloaded + parsed on selection, which can
            // take a few seconds — say so instead of appearing dead.
            if info as? URLSubtitleInfo != nil {
                showToast("Loading subtitles…")
            }
            subtitleModel.selectedSubtitleInfo = info
            // Embedded track: tell the engine which stream to demux+decode.
            if let embedded = info as? DVEmbeddedSubtitleInfo {
                dvActiveEmbeddedSub = embedded
                dvDirectEngine?.selectSubtitle(embedded.streamIndex)
            } else {
                dvActiveEmbeddedSub = nil
                dvDirectEngine?.selectSubtitle(nil)
            }
        case .vlcSubtitle(let id):
            // VLC renders its own subtitles; -1 disables them.
            vlcEngine?.selectSubtitle(id)
        default:
            subtitleModel.selectedSubtitleInfo = nil
            dvActiveEmbeddedSub = nil
            dvDirectEngine?.selectSubtitle(nil)
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

    /// A left/right press on the Fusion bar. A lone press nudge-seeks; holding
    /// the direction down escalates into the continuous fast-forward sweep.
    ///
    /// The old Apple-TV layout had dedicated FF/RW buttons that could tell a
    /// tap from a long-press. A single bar has no such button, and tvOS gives
    /// no "held" state for a directional press — only a stream of repeats — so
    /// the repeats themselves are the signal.
    func barDirectionalPress(forward: Bool) {
        guard hasStartedPlayback else { return }
        // Already sweeping (or holding a preview): the press belongs to the
        // scan transport — bump the speed, or step the frozen preview.
        if scanPreview != nil {
            scanTap(forward: forward)
            barRepeatCount = 0
            return
        }
        let now = Date()
        if let last = lastBarPressAt, barRepeatForward == forward,
           now.timeIntervalSince(last) < 0.4 {
            barRepeatCount += 1
        } else {
            barRepeatCount = 1
        }
        lastBarPressAt = now
        barRepeatForward = forward
        // Four presses in quick succession reads as "held".
        if barRepeatCount >= 4 {
            barRepeatCount = 0
            scanHold(forward: forward)
            return
        }
        nudgeSeek(forward ? Double(settings.skipSeconds) : -Double(settings.skipSeconds))
    }

    private var lastBarPressAt: Date?
    private var barRepeatForward = true
    private var barRepeatCount = 0

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
        seek(to: target, autoPlay: true)   // loads the new position here
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
        // An intro has to be near the FRONT. Without this, a chapter named
        // "Recap"/"Teaser"/"Cold Open" anywhere in the file raised the pill —
        // and with auto-skip on, landing in one at 1:20:00 threw the viewer
        // forward. Mirrors the back-half guard `creditsChapter` already had.
        // Only applied once the duration is known.
        func isNearFront(_ start: Double) -> Bool { duration <= 0 || start < duration * 0.5 }

        // EARLIEST match, not the first in file order — chapter lists aren't
        // guaranteed sorted, and an episode with both a recap and an opening
        // should offer the one you're about to sit through.
        if let chapter = chapters
            .filter({ chapter in
                guard isNearFront(chapter.start), chapter.end > chapter.start else { return false }
                let t = chapter.title.lowercased().trimmingCharacters(in: .whitespaces)
                if t == "op" || t == "ncop" || t == "opening" || t == "intro" { return true }
                return t.contains("intro") || t.contains("opening")
                    || t.contains("recap") || t.contains("prologue")
                    || t.contains("cold open") || t.contains("avant") || t.contains("teaser")
            })
            .min(by: { $0.start < $1.start }) {
            return SkipSegment(start: chapter.start, end: chapter.end, title: chapter.title)
        }
        // Anime-skip fallback: time-based op interval when the file has no
        // named chapters (most anime web releases).
        if let op = animeSkipIntervals
            .filter({ $0.kind == .intro && $0.end > $0.start && isNearFront($0.start) })
            .min(by: { $0.start < $1.start }) {
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

    /// The intro the viewer has already skipped by hand, keyed by its start.
    /// A seek doesn't land on an exact timestamp — engines snap to the nearest
    /// keyframe, which is usually the one BEFORE the target — so jumping to
    /// `intro.end` routinely put playback a couple of seconds back inside the
    /// segment. The next tick then saw "inside the intro" and raised the pill
    /// again (or, with auto-skip on, fired a second seek): press Skip Intro,
    /// watch it blink straight back. Remembering the segment keeps it down.
    private var dismissedIntroStart: Double?

    /// How far past the end of an intro to land. Same keyframe-snapping
    /// reason: aiming exactly at the boundary can resolve to just inside it.
    private static let skipOvershoot: Double = 0.5

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
        // A deliberate rewind to BEFORE the intro re-arms it — you asked to
        // watch it. (Landing a shade short of the end from the skip itself
        // doesn't, which is the whole point of the dismissal.)
        if let dismissed = dismissedIntroStart,
           dismissed != intro.start || position < intro.start - 1 {
            dismissedIntroStart = nil
        }
        // The pill used to vanish 2s early, which on a short recap chapter
        // left barely a window to press it. Hold it to within 1s of the end,
        // and never offer a "skip" that would seek backwards.
        let inside = position >= intro.start && position < intro.end - 1
        guard dismissedIntroStart == nil else {
            if skipIntroActive { setSkipIntroActive(false) }
            return
        }
        // Auto-skip: jump straight past the intro/recap the first time we land
        // in it (no button press needed).
        if inside, settings.autoSkipSegments, !autoSkippedChapters.contains(intro.start) {
            autoSkippedChapters.insert(intro.start)
            setSkipIntroActive(false)
            seek(to: intro.end + Self.skipOvershoot)
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
        guard let intro = introChapter, intro.end > position else {
            // Nothing left to skip — don't seek backwards, just take the pill
            // down so the press still feels like it did something.
            setSkipIntroActive(false)
            return
        }
        // Remember it: the seek below can land back inside the segment (see
        // `dismissedIntroStart`), and the pill must not blink back up. Also
        // stops auto-skip from firing a second jump on top of this one.
        dismissedIntroStart = intro.start
        autoSkippedChapters.insert(intro.start)
        seek(to: intro.end + Self.skipOvershoot)
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

    /// Where a reload has to come back to.
    ///
    /// NOT raw `position`: `load()` zeroes it and it only ticks again once the
    /// new engine plays, so a switch made while a load is still in flight reads
    /// 0, wipes `pendingResume`, and restarts the title from the beginning.
    /// `switchEngine` guarded against this; `switchSource` did not, so changing
    /// source while the first one was still opening lost the resume point and
    /// the throttled saves then wrote the new small positions over it.
    private var resumeTargetForReload: Double {
        max(max(position, pendingResume ?? 0), sessionResumeFloor)
    }

    /// Reload the current stream through a different engine, keeping position.
    func switchEngine(_ engine: PlayerEngine) {
        guard engine != effectiveEngine else {
            overlay = .none
            return
        }
        sessionEngine = engine
        PlaybackMemory.update(meta.id) { $0.engine = engine.rawValue }
        overlay = .none
        let resumeAt = resumeTargetForReload
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

    /// (Re)arm the watchdog for a fresh load. Called from `load`, `loadViaVLC`
    /// and `startDVFirst` — EVERY path that starts a stream, since a path that
    /// forgets to arm it is a path where a dead source spins forever.
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
            // A stuck DV load falls back to the FFmpeg engine, not to a
            // different source — the source itself is fine. This used to test
            // `usingNativeDV` and RETURN, which since the remux tier was retired
            // meant the watchdog either did nothing (flag never set) or, worse,
            // silently gave up on the one session that had no engine underneath
            // it. The direct engine is the tier that exists now, and dropping it
            // onto the FFmpeg reload is what "fall back" means for it.
            if self.usingDVDirect {
                Self.dvTrail("DV-first: nothing playing after \(timeout)s — FFmpeg reload")
                self.showToast("Dolby Vision didn't start — using the standard engine")
                self.fallBackFromDirect(
                    entry: self.currentEntry,
                    reason: "no playback within \(timeout)s"
                )
                return
            }
            // A FORCED engine that never starts is the likelier corpse than
            // the source: a remembered "Native (AVPlayer)" pick dead-ended
            // every MKV link for a title (AVPlayer can't open them), and
            // failing over just marched through sources on the same broken
            // engine. Retry the SAME source on Auto first, and clear the
            // per-title engine memory so the trap doesn't re-arm next time.
            if self.effectiveEngine != .auto, self.sessionEngine != nil || PlaybackMemory.memory(for: self.meta.id)?.engine != nil {
                self.showToast("\(self.effectiveEngine.label) engine didn't start — retrying on Auto")
                Self.dvTrail("forced engine \(self.effectiveEngine.label) never started — clearing memory, retrying on Auto")
                self.sessionEngine = nil
                PlaybackMemory.update(self.meta.id) { $0.engine = nil }
                self.load(entry: self.currentEntry)
                return
            }
            self.showToast("Source didn't load — trying another")
            self.attemptFailover(
                afterError: NSError(
                    domain: "Orivio", code: -2,
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
        // legacy remux tier retired — no segment directories exist
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
        // (The native-remux branch that followed went with its tier. It was a
        // bare `return` — a failover request swallowed whole, no engine change,
        // no error, no next source — which is precisely what a stray
        // `usingNativeDV = true` turned every stall into.)
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
            // A retry hands the rest of the chain to a FRESH attemptFailover
            // (with its own Task), so this one must not clear the flags on its
            // way out: the load watchdog gates on `!isFailingOver` and would
            // start a second concurrent failover chain, and the "switching
            // source" cover flickered off in the middle of the switch.
            var handedOff = false
            defer {
                if !handedOff {
                    self.isFailingOver = false
                    self.isSwitchingSource = false
                }
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
                    handedOff = true
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
                    handedOff = true
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
    /// Callers must set their `handedOff` flag first: the chain continues in
    /// the Task this spawns, so the caller's `defer` must leave `isFailingOver`
    /// / `isSwitchingSource` alone (the re-entry below re-arms `isFailingOver`
    /// synchronously, so there is no window for the watchdog to slip through).
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
            let resumeAt = resumeTargetForReload
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
        let resumeAt = resumeTargetForReload
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
            // Engine-agnostic: pausing only `playerLayer` left VLC and DV
            // sessions playing underneath the gate, and skipping the pause
            // INTENT let the next buffering callback flip `isPlaying` back on.
            enginePause()
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
        // Replaying restarts the evidence for this link at zero; otherwise the
        // verdict is measured against the position the session resumed from and
        // comes out negative (clamped to 0 = "rejected").
        sessionStartPosition = 0
        // Seek only — it autoplays on completion. A second, synchronous play()
        // here ran inside the seek's flush and left the picture frozen with the
        // audio running (see scanCommit / `.readyToPlay` for the full story).
        seek(to: 0, autoPlay: true)
    }

    /// True once the end of this stream has been acted on; cleared whenever a
    /// new stream (or a seek back into this one) makes an ending possible again.
    private var playedToEndHandled = false

    /// End-of-content handling: queue the next episode (the Up Next card
    /// always appears when one exists; auto-play only controls its
    /// countdown), or show the post-play overlay for movies / last episodes.
    private func handlePlayedToEnd() {
        // Idempotent by contract. Engines are not consistent about how many
        // times they announce the end — the direct DV engine reported it from a
        // media-request callback — and re-running this re-publishes progress
        // and re-assigns the overlay, which churns the whole UI.
        guard !playedToEndHandled else { return }
        playedToEndHandled = true
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
        playedToEndHandled = false
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
            // `recordLinkVerdict` measures how much of THIS session was watched
            // from here. Left at the previous episode's resume point, finishing
            // an episode resumed at 40:00 and then watching 25 minutes of the
            // next one computed 1500 - 2400 -> clamped to 0, so the link that
            // had just played fine was REJECTED for the title and skipped next
            // time.
            sessionStartPosition = pendingResume ?? 0

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
            // The now-playing item has CHANGED inside this session — tell the
            // host so it can stop scrobbling the previous episode and start
            // this one. Last, deliberately: the host reads `currentVideo`,
            // `currentEntry` and the resume state off this view model, so it
            // must not be called before every one of them is the new episode's.
            // Every caller of `play(episode:)` is mid-session (auto-advance,
            // Up Next, the episode panel), so this can never double-count the
            // start the host already scrobbled when the cover opened.
            onNowPlayingChanged?(meta, currentVideo)
        }
    }

    /// Mark an episode watched (wired to WatchedStore by PlayerScreen).
    var markWatched: ((MetaVideo) -> Void)?
    func markEpisodeWatched(_ episode: MetaVideo) {
        markWatched?(episode)
        showToast("Marked \(episode.seasonEpisodeCode) as watched")
    }

    // MARK: - Progress persistence

    /// Keep the thumbnailer's view of buffer health current. Called from the
    /// same tick that saves progress, so it costs nothing extra.
    private func publishBufferHealth() {
        bufferAhead.wrappedValue = max(buffered - position, 0)
    }

    private func saveProgressThrottled() {
        publishBufferHealth()
        // Periodic saves are TRANSIENT: persisted to disk for crash safety,
        // but never published — a publish re-renders the whole Home screen
        // behind the player, which was the periodic playback hiccup. The
        // exit/teardown paths call saveProgress(), which publishes once.
        //
        // The interval is the worst-case loss when the app dies without a
        // teardown (crash, force-quit, tvOS reclaiming memory). 30s meant
        // losing up to half a minute of a film; the write is a background
        // encode that never touches the main actor, so a tighter cadence
        // costs nothing on screen.
        guard Date().timeIntervalSince(lastProgressSave) > Self.progressSaveInterval else { return }
        lastProgressSave = Date()
        // Every 12th save (~2 minutes) also nudges the account push, so another
        // device sees a film in progress rather than nothing until you stop
        // watching. No publish: see requestSyncPush.
        transientSaveCount &+= 1
        if transientSaveCount % 12 == 0 { progressStore.requestSyncPush() }
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
        Self.dvTrail(String(format: "progress saved: pos=%.0fs of %.0fs", position, duration))
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

    /// Was this link worth keeping? Decided at the moment of leaving, on one
    /// threshold: five minutes of actual playback this session.
    ///
    /// Under it, the viewer almost always hit a bad source — dead link, wrong
    /// audio, a mux the engine chokes on — and the Auto Link Selector, being
    /// deterministic, would hand them the exact same one on the next press.
    /// Remembering the bail-out lets the next attempt move on. Over it, the
    /// link plays, so any rejection standing against it is dropped.
    ///
    /// Measured from where this session STARTED, not from zero: resuming at
    /// 1h20m and stopping two minutes later is two minutes of evidence, not
    /// eighty-two.
    private func recordLinkVerdict() {
        guard duration > 60 else { return }
        let titleKey = ProgressStore.key(metaID: meta.id, video: currentVideo)
        let watched = max(position - sessionStartPosition, 0)
        if hasStartedPlayback, watched >= 5 * 60 {
            RejectedLinks.keep(currentEntry.rejectionKey, for: titleKey)
        } else {
            RejectedLinks.reject(currentEntry.rejectionKey, for: titleKey)
        }
    }

    /// Called when the exit sequence starts. Persists progress, halts
    /// playback, and detaches the render surface before teardown. Display
    /// criteria are released separately by `releaseDisplayForExit()`, after the
    /// black cover and the detached surface have had a run-loop turn to settle.
    func prepareForExit() {
        guard !isExiting else { return }
        isExiting = true
        saveProgress()
        recordLinkVerdict()
        cacheTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        // The FINE pair too: exiting mid-scrub otherwise left an orphan
        // 30s-budget FFmpeg decode running after the player was gone.
        clearFineThumbnails()
        countdownTask?.cancel()
        dvPauseHeartbeat?.cancel()
        dvFirstTask?.cancel()
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
        // reset is suppressed (OrivioPlayerOptions.playerLayerDeinit) so this
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
        OrivioSyncManager.playbackActive = false   // resume periodic account sync
        // The player is gone: any in-flight failover / watchdog / seek callback
        // must NOT restart playback from here (they all gate on isExiting).
        // Also swallows engine state callbacks arriving mid-teardown.
        isExiting = true
        saveProgress()
        cacheTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        // The FINE pair too: exiting mid-scrub otherwise left an orphan
        // 30s-budget FFmpeg decode running after the player was gone.
        clearFineThumbnails()
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
        // Hand the audio session back so whatever the player interrupted (music
        // from another app, a HomePod group) gets its shouldResume — the app
        // never called setActive(false) anywhere, so interrupted audio stayed
        // dead until manually restarted.
        //
        // AFTER every engine is stopped, not before: deactivating a session
        // with live I/O fails with AVAudioSessionErrorCodeIsBusy, and the
        // `try?` swallowed it — so the hand-back this call exists for never
        // actually happened while KSPlayer/VLC/DV were still running.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // Leak probes: 5s after teardown everything below should be freed.
        // Whichever line still prints ALIVE names the retention layer.
        #if DEBUG
        weak var probeVM: PlayerViewModel? = self
        weak var probeEngine: DVSampleEngine? = dvDirectEngine
        weak var probeVideoView: UIView? = dvDirectEngine?.videoView
        dvDirectEngine = nil
        NSLog("[OrivioLeak] teardown() ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // presentedVC tells us whether the DISMISSED player cover is still
            // mounted in the window: a dead 4K layer tree the render server
            // keeps compositing would explain both the re-entry stutter and
            // the corrupted-strip glitch.
            let pvc = UIApplication.shared.ks_keyWindow?.rootViewController?.presentedViewController
            NSLog("[OrivioLeak] +5s: vm=%@ engine=%@ videoView=%@ presentedVC=%@ liveVMs=\(PlayerViewModel.liveInstances)",
                  probeVM == nil ? "freed" : "ALIVE",
                  probeEngine == nil ? "freed" : "ALIVE",
                  probeVideoView == nil ? "freed" : "ALIVE",
                  pvc.map { String(describing: type(of: $0)) } ?? "nil")
        }
        #endif
        resetNativeDV()
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
        // The direct sample feed is the native tier now — `engineName` is left
        // at whatever the last KSPlayer/VLC session set, so it can't name a DV
        // session on its own.
        let engine = usingDVDirect ? "Dolby Vision (direct)" : "\(engineName) engine"
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
        NSLog("[OrivioPlay] player: pre-cache hold begins (target %.0fs)", cacheTargetSeconds)
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
        // Each of these silently produced NO previews at all, which is
        // indistinguishable from a broken thumbnailer from the sofa. Say which
        // gate fired so "the preview window doesn't generate frames" is
        // answerable from a device log.
        guard settings.scrubPreviewsEnabled else {
            NSLog("[OrivioPlayer] scrub previews skipped: turned off in Settings")
            return
        }
        guard !PerformanceProfile.isLowPower else {
            NSLog("[OrivioPlayer] scrub previews skipped: low-power device")
            return
        }
        guard !thumbnailsStarted, let url = currentURL else { return }
        guard url.pathExtension.lowercased() != "m3u8" else {
            NSLog("[OrivioPlayer] scrub previews skipped: HLS source")
            return
        }
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
            guard let bytes, bytes > 0, bytes <= 8 * 1_073_741_824 else {
                NSLog("[OrivioPlayer] scrub previews skipped: source size %@",
                      bytes.map { "\($0 / 1_048_576) MB (over the 8 GB cap)" } ?? "unknown")
                return
            }
            // A short settle only. This used to hold until the playback cache
            // was essentially full — which on a slow source meant the pass
            // started MINUTES in (or hit the 120s timeout), so the preview
            // window was empty for exactly the stretch of film you had not
            // watched yet. Previews are wanted from the start and across the
            // whole file, including parts never played, so the pass now begins
            // as soon as playback is stable and streams its frames out as it
            // goes. It is still a second connection competing with playback —
            // if that shows up as early stutter, this settle is the dial.
            let waitStart = Date()
            while !Task.isCancelled {
                guard let self else { return }
                // Wait for a HEALTHY buffer, not just a few seconds on the
                // clock. Opening the pass is not free even before it decodes a
                // frame — a second connection, avformat_open_input and a
                // stream-info probe — and doing that while the movie is still
                // establishing its own buffer is a burst right at the start,
                // which is the one-off stall a few seconds into playback. The
                // per-frame gate can't help: this happens before the first
                // frame. The 45s ceiling keeps a source that never reports a
                // buffer (VLC) from waiting forever.
                let healthy = self.bufferAhead.wrappedValue >= 12
                if self.hasStartedPlayback, healthy,
                   Date().timeIntervalSince(waitStart) > 5 { break }
                if Date().timeIntervalSince(waitStart) > 45 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            // One frame per 30 seconds of runtime rather than a flat 36 across
            // the whole film: 36 frames on a two-hour movie is a preview every
            // THREE AND A HALF MINUTES, so the window showed a frame from a
            // different scene than the one under the playhead. The budget
            // scales with the count or a long film would hit the wall-clock
            // limit part-way through and leave the back half with no previews.
            let runtime = await MainActor.run { self?.duration ?? 0 }
            let frames = ScrubThumbnailer.frameCount(forDuration: runtime)
            // Roughly 2.5s a frame: each one is a seek plus a decode over the
            // network, and the old `max(60, frames)` (one second each) cut a
            // long film's pass off less than half way through.
            let budget = min(TimeInterval(frames) * 2.5, 900)
            NSLog("[OrivioPlayer] scrub previews: %d frames over %.0fs runtime (budget %.0fs)",
                  frames, runtime, budget)
            // VLC never reports an ahead-buffer (it is pinned to 0), so gating
            // on it there would stall the pass forever — let it run ungated,
            // which is what it did before any of this.
            let gated = await MainActor.run { !(self?.usingVLC ?? false) }
            let health = self?.bufferAhead
            var proceed: (@Sendable () -> Bool)?
            if gated, let health {
                proceed = { health.wrappedValue >= 8 }
            }
            let thumbnailer = ScrubThumbnailer(
                url: url, count: frames, budgetSeconds: budget,
                headers: headers, shouldProceed: proceed
            )
            self?.thumbnailer = thumbnailer
            // Publish frames AS THEY LAND rather than only at the end. A pass
            // over a long film can run for minutes behind the cache gate, and
            // an all-or-nothing hand-off meant the scene window showed nothing
            // at all for that whole time — indistinguishable from broken.
            let thumbs = await thumbnailer.generate { partial in
                Task { @MainActor [weak self] in
                    guard let self, self.thumbnailer === thumbnailer else { return }
                    self.scrubThumbnails = partial
                }
            }
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
        snap.engine = usingVLC ? "VLC" : engineName + (usingDVDirect ? " · direct DV" : "")
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
    /// Dense frames around the playhead, one every two seconds, generated when
    /// the fine-tune wheel engages. Separate from `scrubThumbnails` so the
    /// coarse whole-film set is never thrown away by a fine pass.
    @Published private(set) var fineThumbnails: [ScrubThumbnail] = []
    private var fineThumbnailer: ScrubThumbnailer?
    private var fineTask: Task<Void, Never>?
    /// Centre of the window `fineThumbnails` covers, so a small wheel movement
    /// doesn't restart the pass.
    private var fineCenter: Double?

    /// Start (or re-centre) the fine pass. Called when the wheel engages and as
    /// the target drifts out of the window already covered.
    private func startFineThumbnailsIfNeeded(around target: Double) {
        guard settings.scrubPreviewsEnabled, !PerformanceProfile.isLowPower,
              thumbnailsStarted, duration > 0 else { return }
        let half = ScrubThumbnailer.fineWindowSeconds / 2
        // Still inside the covered window (with a margin) — nothing to do.
        if let centre = fineCenter, abs(centre - target) < half * 0.5 { return }
        guard let url = currentURL, url.pathExtension.lowercased() != "m3u8" else { return }

        fineCenter = target
        fineTask?.cancel()
        fineThumbnailer?.cancel()
        let lower = max(target - half, 0)
        let upper = min(target + half, max(duration - 1, 0))
        guard upper > lower else { return }
        let count = max(4, Int((upper - lower) / ScrubThumbnailer.fineSecondsPerFrame))
        let headers = currentEntry.stream.behaviorHints?.proxyHeaders?.requestHeaders

        fineTask = Task { [weak self] in
            let health = await MainActor.run { self?.bufferAhead }
            var proceed: (@Sendable () -> Bool)?
            if let health { proceed = { health.wrappedValue >= 6 } }
            let fine = ScrubThumbnailer(url: url, count: count, budgetSeconds: 30,
                                        headers: headers, range: lower...upper,
                                        shouldProceed: proceed)
            await MainActor.run { self?.fineThumbnailer = fine }
            let thumbs = await fine.generate { partial in
                Task { @MainActor [weak self] in
                    guard let self, self.fineThumbnailer === fine else { return }
                    self.fineThumbnails = partial
                }
            }
            await MainActor.run {
                guard let self, self.fineThumbnailer === fine else { return }
                self.fineThumbnailer = nil
                if !thumbs.isEmpty { self.fineThumbnails = thumbs.sorted { $0.time < $1.time } }
            }
        }
    }

    /// Drop the dense set when fine-tuning ends — it is ~45 frames held only
    /// for the window you were working in.
    private func clearFineThumbnails() {
        fineTask?.cancel(); fineTask = nil
        fineThumbnailer?.cancel(); fineThumbnailer = nil
        fineCenter = nil
        if !fineThumbnails.isEmpty { fineThumbnails = [] }
    }

    /// How far a coarse frame may be from the asked-for time and still be
    /// worth showing: one and a half times the spacing the pass has reached so
    /// far, never tighter than three of its target steps.
    private var coarseTolerance: Double {
        guard scrubThumbnails.count > 1, duration > 0 else { return .infinity }
        let spacing = duration / Double(scrubThumbnails.count)
        return max(ScrubThumbnailer.secondsPerFrame * 3, spacing * 1.5)
    }

    func thumbnail(at time: Double) -> UIImage? {
        // Prefer a fine frame when one is genuinely near — within a single
        // fine step. Past that the coarse set is the better answer than a
        // stale close-up from the edge of the window.
        if !fineThumbnails.isEmpty {
            var best: ScrubThumbnail?
            var bestDistance = Double.infinity
            for thumb in fineThumbnails {
                let distance = abs(thumb.time - time)
                if distance < bestDistance { bestDistance = distance; best = thumb }
            }
            if let best, bestDistance <= ScrubThumbnailer.fineSecondsPerFrame {
                return best.image
            }
        }
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
        // Reject a frame that is nowhere near this scene — but judge "near" by
        // the coverage that actually EXISTS, not by the spacing the pass is
        // aiming for. A flat 90s cut-off meant that early on, when the pass had
        // only laid down a coarse spread, almost every position was further
        // than that from a frame and the window simply refused to appear. The
        // tolerance now starts wide and tightens on its own as frames fill in,
        // so there is always something to show and it gets more accurate.
        guard bestDistance <= coarseTolerance else { return nil }
        return best
    }

    /// Actual remote file size via a HEAD request (nil when the server won't
    /// say). Used to gate the preview-thumbnail pass.
    private static func remoteContentLength(
        _ url: URL, headers: [String: String]? = nil
    ) async -> Int64? {
        func probe(_ method: String, range: Bool) async -> Int64? {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 8
            for (key, value) in headers ?? [:] {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if range { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            // A ranged reply carries the real total after the slash:
            // "Content-Range: bytes 0-0/8123456789". Content-Length on that
            // reply is 1, so it must be read from Content-Range, not from it.
            if range, let content = http.value(forHTTPHeaderField: "Content-Range"),
               let total = content.split(separator: "/").last, let bytes = Int64(total),
               bytes > 0 {
                return bytes
            }
            if !range, let length = http.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(length), bytes > 0 {
                return bytes
            }
            return nil
        }

        if let bytes = await probe("HEAD", range: false) { return bytes }
        // Plenty of stream hosts — debrid endpoints especially — answer HEAD
        // with 405, or with no Content-Length at all. A one-byte ranged GET is
        // what actually works, and it costs a single byte. Without this the
        // size read as "unknown", which the caller treats as "skip", so scrub
        // previews were never generated for those sources at all.
        return await probe("GET", range: true)
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

        // Direct-engine sessions have no KSPlayer track objects — build the
        // Video section from what the engine itself measured.
        if let engine = dvDirectEngine {
            var video: [MediaInfoRow] = []
            let profile = engine.detectedDVProfile
            video.append(.init(label: "Codec",
                               value: profile > 0 && !engine.forceHDR10
                                   ? "HEVC · Dolby Vision P\(profile)" : "HEVC"))
            if engine.videoWidth > 0 {
                video.append(.init(label: "Resolution", value: "\(engine.videoWidth) × \(engine.videoHeight)"))
            }
            if engine.videoFPS > 0 {
                video.append(.init(label: "Frame Rate", value: String(format: "%.3f fps", engine.videoFPS)))
            }
            video.append(.init(label: "Display", value: "\(UIScreen.main.maximumFramesPerSecond) Hz"))
            if engine.containerMbps > 0 {
                video.append(.init(label: "Bitrate", value: String(format: "%.1f Mbps (container)", engine.containerMbps)))
            }
            sections.append(.init(title: "Video", rows: video))
        }

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
                // This whole section is built from KSPlayer's own track list,
                // so it only ever describes a DECODE session — a direct-engine
                // session builds its Video rows from the engine above and never
                // reaches here. The "Native Dolby Vision" arm was therefore
                // unreachable even before its flag was retired.
                video.append(.init(
                    label: "DV Output",
                    value: profile == 7 && !settings.dolbyVisionProfile7
                        ? "HDR10 base layer (Profile 7 conversion off)"
                        : "HDR10 base layer"
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
                    // Same reasoning as DV Output: passthrough belongs to the
                    // direct engine, which never renders this section.
                    value: PerformanceProfile.supportsHDR10Plus
                        ? (settings.hdr10PlusPassthrough
                            ? "HDR10 base layer (passthrough didn't engage)"
                            : "HDR10 base layer (passthrough off)")
                        : "HDR10 base layer (\(PerformanceProfile.hdr10PlusUnavailableReason ?? "unsupported"))"
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
            // Open-timing breakdown (visible in Console.app, filter "OrivioPlayer")
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
            clock.duration = duration
            // Now the bitrate is knowable, size a byte-target read-ahead cache.
            applyBufferSizeTarget(player: layer.player)
            // Engine always letterboxes (aspect-fit); zoom/stretch happen as a
            // SwiftUI transform driven by the natural size published here.
            layer.player.contentMode = .scaleAspectFit
            videoNaturalSize = layer.player.naturalSize
            // (The growing-playlist duration pin and this chapter guard were
            // both remux-tier special cases; a KSPlayer session is always
            // playing the real file now.)
            chapters = layer.player.chapters
            applyNativeDisplayCriteria()
            maybeStartNativeDV()
            // HDR10+ remux starter retired (direct engine passes SEIs through)
            if playbackSpeed != 1 {
                layer.player.playbackRate = playbackSpeed
            }
            let willPrecache = !hasStartedPlayback
            loadTracks()
            startThumbnailsIfNeeded()

            let resume = pendingResume ?? 0
            var meaningfulResume = resume > 30 && (duration == 0 || resume < duration - 30)
            // `startPlayTime` already opened the container at the resume point,
            // so the engine is sitting there — seeking again would flush a
            // buffer that is already in the right place and pay the cost this
            // change exists to avoid. Only seek if the open didn't land near
            // the target (an engine that ignores the option, or a container
            // FFmpeg couldn't seek during open).
            if meaningfulResume, currentOptions?.startPlayTime ?? 0 > 0 {
                let landed = layer.player.currentPlaybackTime
                if abs(landed - resume) < 10 {
                    NSLog("[OrivioPlayer] resume: opened at %.0fs, no seek needed", landed)
                    meaningfulResume = false
                    pendingResume = nil
                    sessionResumeFloor = max(sessionResumeFloor, resume)
                    position = landed
                    clock.position = landed
                }
            }

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
                    // (The playlist-offset translation that used to wrap this
                    // target went with the remux tier: a KSPlayer session's
                    // timeline IS the source timeline.)
                    layer.seek(time: resume, autoPlay: true) { _ in }
                } else {
                    layer.play()
                }
                pendingResume = nil
                if overlay == .none { showControls() }
            }
        case .buffering:
            // NOT unconditionally true: the reader buffers while paused too.
            isPlaying = !pauseIntent
            isBuffering = true
            // `pausedAt` drives the stale-socket reconnect on resume, so a
            // buffer event must not erase how long we have actually been sat
            // paused — only a real resume does.
            if !pauseIntent { pausedAt = nil }
        case .bufferFinished:
            isPlaying = !pauseIntent
            isBuffering = false
            if !pauseIntent { pausedAt = nil }
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
            // (The live-edge guard that used to sit here belonged to the
            // growing remux playlist — AVPlayer ending the item at the last
            // written segment rather than at the end of the film. There is no
            // playlist any more, and the guard's `return` swallowed the end of
            // a real movie for any session that had the flag set.)
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
        // (The playlist-offset mapping that used to open this method went with
        // the remux tier: a KSPlayer session's clock is already absolute
        // source time.)
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
        if totalTime.isFinite, totalTime > 0 { duration = totalTime }
        buffered = layer.player.playableTime
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


/// One embedded subtitle track from the direct sample engine, bridged into
/// KSPlayer's SubtitleModel so the existing picker, delay handling and
/// SubtitleOverlayView (text AND image cues) all work unchanged. Parts
/// stream in live from the demuxer as the engine reaches them.
final class DVEmbeddedSubtitleInfo: SubtitleInfo {
    let subtitleID: String
    let name: String
    var delay: TimeInterval = 0
    var isEnabled: Bool = false
    let streamIndex: Int32
    var parts: [SubtitlePart] = []

    init(streamIndex: Int32, label: String) {
        self.streamIndex = streamIndex
        subtitleID = "dvsub-\(streamIndex)"
        name = label
    }

    func search(for time: TimeInterval) -> [SubtitlePart] {
        var result = [SubtitlePart]()
        for part in parts {
            if part == time { result.append(part) }
            else if part.start > time { break }
        }
        return result
    }

    /// Append one live cue: truncate any still-open part it supersedes,
    /// dedup re-decoded cues after a backward seek, keep sorted, and prune
    /// far-behind parts so PGS images don't accumulate for a whole movie.
    func add(start: Double, end: Double, text: String?, image: UIImage?, playhead: Double) {
        if text == nil, image == nil {   // clear marker
            for part in parts.reversed() where part.end > start && part.start <= start {
                part.end = start
            }
            return
        }
        let part = SubtitlePart(start, end, attributedString: text.map { NSAttributedString(string: $0) })
        part.image = image
        if let idx = parts.lastIndex(where: { abs($0.start - start) < 0.01 && ($0.image != nil) == (image != nil) }) {
            parts[idx] = part
        } else {
            // A new image cue supersedes an open-ended one still running.
            if image != nil {
                for prev in parts.reversed() where prev.image != nil && prev.end > start && prev.start < start {
                    prev.end = start
                }
            }
            parts.append(part)
            parts.sort(by: <)
        }
        let cutoff = playhead - 120
        if let first = parts.first, first.start < cutoff - 60 {
            parts.removeAll { $0.end < cutoff }
        }
    }
}

