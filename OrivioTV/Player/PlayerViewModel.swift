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

/// Launch-argument dev switches, read ONCE.
///
/// `ProcessInfo.processInfo.arguments` rebuilds a fresh `[String]` out of argv
/// on every single access — and three of these were being evaluated inside
/// `refreshPictureInPictureSource()`, which runs on the player's clock tick.
/// KSPlayer's tick is a 0.1s timer, so that was thirty array allocations a
/// second, for the length of a film, on the main actor beside a running 4K
/// decoder — to answer a question whose answer cannot change after launch. A
/// fourth sat in `PlayerScreen.body`, re-evaluated on every render.
///
/// `static let` is lazy and thread-safe, so this costs one array build for the
/// life of the process and a Bool load thereafter.
enum PlayerDevFlags {
    private static let args = Set(ProcessInfo.processInfo.arguments)
    static let pipProbe = args.contains("-pipProbe")
    static let pipForce = args.contains("-pipForce")
    static let pipViaNative = args.contains("-pipViaNative")
    static let pipNoGeneric = args.contains("-pipNoGeneric")
    static let hybridCache = args.contains("-hybridCache")
    static let forceFFmpeg = args.contains("-forceFFmpeg")
    static let playerHUD = args.contains("-playerHUD")
    static let controlsDemo = args.contains("-playerControlsDemo")
    /// The `-playerDemo` / `-playerDemoMKV` sample sessions.
    static let playerDemo = args.contains("-playerDemo") || args.contains("-playerDemoMKV")
    static let infoDemo = args.contains("-playerInfoDemo")
    static let demoTour = args.contains("-playerDemoTour")
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaItem
    let video: MetaVideo?
    let entry: StreamEntry
    let allEntries: [StreamEntry]
    let resumePosition: Double?
    /// Open on the FFmpeg demuxer regardless of the engine preference.
    ///
    /// For sources AVFoundation cannot open AT ALL — RTMP/RTSP/UDP/RTP live
    /// channels, DASH manifests — where honouring a "Native" preference is not
    /// a quality choice but a guaranteed failure. Engine routing is otherwise
    /// decided from the container extension, which those URLs don't have.
    var forceDemuxer: Bool = false
    /// A library server's episodes (Plex / Jellyfin) don't come from add-ons:
    /// when set, `play(episode:)` asks this for the episode's own file
    /// instead of sweeping the stream add-ons for an id they don't know.
    var directEpisodeResolver: ((MetaVideo) async -> StreamEntry?)? = nil
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
    case info            // Infuse-style pull-down file/media info panel
    case engine          // playback-engine picker (Auto/Native/FFmpeg/VLC)
    case error(String)

    /// Short name for the live probe (`:8123/live`) — the associated value on
    /// `.error` makes the reflected description useless in a state line.
    var probeName: String {
        if case .error = self { return "error" }
        return String(describing: self)
    }

    /// States that draw the transport (`FusionPlayerControlsOverlay`): the bar
    /// itself, the paused bar, and the two track popovers — which are that same
    /// screen with a panel over one glyph.
    ///
    /// Defined once here because two places have to agree exactly on it:
    /// `PlayerScreen.controlsVisible`, which mounts the overlay, and
    /// `controlsSession`, which decides when its focus starts over. They drifting
    /// apart is precisely how focus would end up somewhere nobody chose.
    var showsTransport: Bool {
        switch self {
        case .controls, .pauseInfo, .audio, .subtitles: return true
        default: return false
        }
    }
}

/// What the CURRENT output route can actually take, and how to ask tvOS for
/// it. One place, because three engines each configured the session their own
/// way and none of them ever told the session it would be playing multichannel.
///
/// `setSupportsMultichannelContent(true)` is not optional on tvOS: it is the
/// app declaring that it has more than two channels to give. Left at its
/// `false` default the session is entitled to hand the route a stereo fold,
/// which is what every Dolby path in this app was doing.
enum AudioOutputCapability {
    /// Long-form video session, multichannel declared. Cheap and idempotent —
    /// safe to call on every load from every engine.
    ///
    /// No route-sharing policy on tvOS, deliberately: see
    /// `KSOptions.setAudioSession` for why `.longFormAudio` detached the
    /// session from the user's Default Audio Output.
    static func configureForMoviePlayback() {
        let session = AVAudioSession.sharedInstance()
        var categoryOK = true
        do { try session.setCategory(.playback, mode: .moviePlayback) } catch { categoryOK = false }
        var multichannelOK = false
        if #available(tvOS 15.0, *) {
            multichannelOK = (try? session.setSupportsMultichannelContent(true)) != nil
        }
        // The single most direct read on "why did audio come out stereo /
        // cause a dropout": what the session actually accepted and how wide
        // the route says it is. Logged at every playback start.
        AppProbe.life("audio session → playback/moviePlayback ok=\(categoryOK.probe)"
            + " multichannel=\(multichannelOK.probe)"
            + " maxCh=\(session.maximumOutputNumberOfChannels)"
            + " out=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
    }

    /// Channels the route reports it can take. Only meaningful once the
    /// session is ACTIVE — an inactive session answers 2 for an Atmos AVR,
    /// which is how a capable receiver got a stereo downmix.
    static var maxOutputChannels: Int {
        AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
    }

    /// The route can carry more than stereo.
    ///
    /// NOT `isSpatialAudioEnabled`, which is a different question: that flag
    /// reports Apple's own spatialization (head tracking, virtualisation) and
    /// is routinely FALSE on exactly the equipment this matters for — an HDMI
    /// receiver that decodes Dolby itself. Using it as the multichannel test
    /// folded 7.1 to stereo on hardware that was perfectly capable.
    static var supportsMultichannel: Bool { maxOutputChannels > 2 }

    /// Whether tvOS will spatialize in software for this route (HomePods,
    /// AirPods). Kept separate from `supportsMultichannel` on purpose.
    static var routeIsSpatial: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.isSpatialAudioEnabled }
    }

    /// The route as a viewer would name it: "HDMI · up to 8 channels".
    /// `portName` is the system's own label for the output.
    static var routeShortDescription: String {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        let name = ports.first?.portName ?? "No output"
        let max = maxOutputChannels
        return max > 2 ? "\(name) · up to \(max) channels" : "\(name) · stereo"
    }

    /// One line for the diagnostics block.
    static var routeDescription: String {
        let session = AVAudioSession.sharedInstance()
        let ports = session.currentRoute.outputs
        let names = ports.map { "\($0.portType.rawValue)" }.joined(separator: "+")
        let routeChannels = ports.compactMap { $0.channels?.count }.max() ?? 0
        return "\(names.isEmpty ? "none" : names) max=\(maxOutputChannels)ch"
            + " route=\(routeChannels)ch preferred=\(session.preferredOutputNumberOfChannels)ch"
            + " spatial=\(routeIsSpatial ? "Y" : "n")"
    }
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
    /// The DYNAMIC RANGE the pin was taken for (-1 until something is pinned).
    ///
    /// The pin used to record only the rate, which made it range-BLIND: the
    /// first title of a foreground stint negotiated a mode and every later one
    /// was refused, whatever it asked for. So a Dolby Vision title opened after
    /// any HDR10 or SDR title could not move the panel into DV and played out
    /// as plain HDR — and a DV-only (profile 5) file, whose IPT colour is
    /// meaningless outside DV mode, came out with broken colour. The reverse
    /// washout was already known and instrumented at the `display gate` probe
    /// in `updateVideo` ("a panel pinned by an earlier title in the same
    /// foreground stint keeps that title's dynamic range") but never acted on.
    ///
    /// Rate churn is what the pin exists to stop; a genuine change of dynamic
    /// range is not churn, it is the whole point of matching content.
    nonisolated(unsafe) private static var pinnedRange: Int32 = -1
    /// What the panel reported after the pinned switch settled (0 until known).
    nonisolated(unsafe) private static var settledRate: Float = 0
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
            lock.lock(); pinned = false; pinnedRate = 0; pinnedRange = -1; lock.unlock()
            NSLog("[OrivioDisplay] backgrounded — pin cleared (display already reverted by tvOS)")
        }
    }

    /// Apply `criteria` only if nothing was pinned this launch. Lock-based
    /// (not actor-isolated): callers arrive from KSPlayer's setup thread AND
    /// from the main actor, and a main.sync hop from main would deadlock.
    /// Video refresh rates worth asking a TV for. A stream whose fps has not
    /// been established yet reports nonsense — a rate of 10 was seen pinned
    /// for a whole app session, and because the pin is one-per-stint every
    /// later title was then locked out of the mode it actually wanted.
    static func isPlausibleRate(_ rate: Float) -> Bool { rate >= 20 && rate <= 121 }

    /// Snap a measured rate to the nearest rate a TV actually has a mode for.
    ///
    /// 23.976 and 24.000 are DIFFERENT display modes and every 4K panel
    /// advertises both. The old rule folded everything in 23.5…24.2 onto
    /// 23.976 on the reasoning that FFmpeg reports film imprecisely — true of
    /// KSPlayer's `nominalFrameRate`, but NOT of the direct engine, which
    /// reads `avg_frame_rate` as an exact rational: 24000/1001 comes back as
    /// 23.976025 and 24/1 comes back as 24.0, and it can tell them apart.
    /// Throwing that away put genuinely-24p content into a 23.976 panel,
    /// which repeats a frame every ~42 seconds — a slow, regular hitch that
    /// reads as "a bit jumpy" rather than as anything obviously broken.
    ///
    /// Anything not near a standard rate is passed through untouched.
    static func snapToBroadcastRate(_ rate: Float) -> Float {
        let standards: [Float] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        guard let nearest = standards.min(by: { abs($0 - rate) < abs($1 - rate) }),
              abs(nearest - rate) <= 0.15 else { return rate }
        return nearest
    }

    static func applyOnce(_ criteria: AVDisplayCriteria,
                          via manager: AVDisplayManager,
                          rate: Float = 0,
                          range: Int32) -> Bool {
        // TRUST BUT VERIFY the pin: tvOS can revert the panel to its home
        // rate when playback ends even while our criteria stay set. The pin
        // then blocked the next playback's request and 24fps content played
        // into a 60Hz panel — the "smooth after force-quit, stuttery after
        // re-entry" 3:2-pulldown signature. If the panel no longer runs at
        // the rate we negotiated, the pin is stale: clear it and re-request.
        // Compared against the rate the panel SETTLED at after the pin, not
        // the content rate that was requested: with tvOS matching dynamic
        // range but not frame rate (this app's own default), the panel stays
        // at 60 while 23.976 was asked for, and comparing 60 against 23.976
        // declared the pin stale on every load — every title re-requested the
        // HDMI switch, DV-first sessions re-paid their black-screen hold, and
        // the 3:2 softening was cleared as if the panel ran at 24.
        // UIScreen is main-thread-only and this function is also reached from
        // KSPlayer's setup thread, so read it only where it is safe to. Off
        // main we skip the staleness probe (it is a heuristic; the pin logic
        // below still runs) rather than touch UIKit from a background thread.
        let current: Float? = Thread.isMainThread
            ? Float(UIScreen.main.maximumFramesPerSecond)
            : nil
        lock.lock()
        if let current, pinned, settledRate > 0, abs(current - settledRate) > 1.5 {
            NSLog("[OrivioDisplay] pin stale (panel %.0f vs settled %.0f) — re-requesting", current, settledRate)
            pinned = false
        }
        // A DIFFERENT DYNAMIC RANGE IS NOT THE CHURN THIS PIN EXISTS TO STOP.
        // Refusing it is what left Dolby Vision playing as HDR: the pin taken
        // by whatever ran first in this stint held the panel in that title's
        // range for the rest of the stint. Rate-only differences are still
        // refused, which is the case the pin was built for (24fps content
        // re-requesting a switch the panel had already settled).
        //
        // This is still only ever a switch INTO a content mode. Nothing here
        // reverts the panel toward its home mode, which is the sequence the
        // grey-screen wedge came from and which `releaseDisplayForExit`
        // deliberately no-ops.
        if pinned, pinnedRange != range {
            NSLog("[OrivioDisplay] pin was for range %d, this title wants %d — re-requesting",
                  pinnedRange, range)
            pinned = false
        }
        let first = !pinned
        if first { pinned = true; pinnedRate = rate; pinnedRange = range; settledRate = 0 }
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
            let fps = UIScreen.main.maximumFramesPerSecond
            NSLog("[OrivioDisplay] UIScreen reports %ld fps after the switch", fps)
            lock.lock(); settledRate = Float(fps); lock.unlock()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let fps = UIScreen.main.maximumFramesPerSecond
            NSLog("[OrivioDisplay] UIScreen reports %ld fps (settled)", fps)
            lock.lock(); settledRate = Float(fps); lock.unlock()
            // Into the COLOUR trail, which is the one the dev probe serves.
            // Whether the panel actually moved is the decisive datum for any
            // judder question and it was only ever in the device console.
            PlayerViewModel.colorTrail(
                String(format: "display: panel settled at %ldfps (requested %.3f)", fps, rate))
        }
        return true
    }

    /// Put the panel back the way playback found it.
    ///
    /// This is BYTE-FOR-BYTE what `installBackgroundReleaseIfNeeded`'s observer
    /// already does every single time the app backgrounds — clear the criteria,
    /// drop the pin — so it is not a new operation, only a new moment to run it
    /// at. That is the whole safety argument for calling it on exit: the code
    /// path is already exercised on every Home press in production.
    ///
    /// The caller is responsible for the SEQUENCING, which is the part that
    /// historically mattered: `PlayerScreen.exitPlayer` holds an opaque cover,
    /// lets `prepareForExit` detach the video surface, and only then calls
    /// this — so the HDMI renegotiation happens over a static black screen
    /// instead of over a surface being destroyed underneath it.
    static func releaseForExit() {
        UIApplication.shared.ks_keyWindow?.avDisplayManager.preferredDisplayCriteria = nil
        lock.lock(); pinned = false; pinnedRate = 0; pinnedRange = -1; settledRate = 0; lock.unlock()
        NSLog("[OrivioDisplay] released on exit — panel returns to its home format")
    }

    /// The manual re-sync gesture's pin clear: drop the pin (so a re-request is
    /// allowed to drive a fresh handshake) WITHOUT touching the criteria, which
    /// the caller has already dropped. `releaseForExit` does both; the resync
    /// needs the two steps separated in time.
    static func resetPinForResync() {
        lock.lock(); pinned = false; pinnedRate = 0; pinnedRange = -1; settledRate = 0; lock.unlock()
    }

    /// Diagnostics: whether an earlier title in THIS foreground stint already
    /// pinned the panel — in which case nothing this title asks for can move
    /// it, and it is playing into whatever mode that earlier title negotiated.
    static var pinDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return pinned
            ? "PINNED by an earlier title this stint (rate=\(pinnedRate), range=\(pinnedRange),"
                + " settled=\(settledRate)) — this title can only change the panel by asking for a different range"
            : "not pinned"
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
    /// 1080p SDR still gets 16, 4K HDR on the A10X gets 6 (~150 MB).
    override func videoFrameMaxCount(fps: Float, naturalSize: CGSize, isLive: Bool) -> UInt8 {
        if isLive { return 4 }   // KSPlayer's own live default
        let budgetBytes: Double
        if PerformanceProfile.isLowPower { budgetBytes = Double(64 << 20) }
        // 160 MB: six 4K HDR frames rather than four. Four was ~170 ms of
        // cushion at 24 fps, and every decode that ran long — a large
        // keyframe, a VideoToolbox hiccup — drained it to a repeated frame.
        else if PerformanceProfile.isMidPower { budgetBytes = Double(160 << 20) }
        else { budgetBytes = Double(400 << 20) }   // 4 GB boxes: effectively stock
        // ~3 bytes/pixel: 4:2:0 biplanar at 10-bit (16-bit storage). Assumes
        // the worst case rather than sniffing bit depth — an 8-bit stream
        // just gets a slightly deeper queue than strictly needed.
        //
        // REVERTED 09-16: sizing this by the track's real bit depth gave 8-bit
        // 4K thirteen frames instead of six — correct for a pure FFmpeg
        // session, but it roughly DOUBLES the decoded-frame memory actually in
        // use, and a DV Sample Feed session opens through the FFmpeg engine for
        // its first couple of seconds before handing rendering over. That paid
        // the extra allocation at exactly the moment playback is most fragile,
        // for an engine that then throws it away. Worth revisiting once the DV
        // path is settled; not worth it now.
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
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        // Reached from MetalPlayView's frame path, which is not main, while the
        // `UIScreen` / `UIApplication` reads below are main-thread-only. Hop
        // instead of touching UIKit off-main; the call is rare (fps/format
        // change) so an async hop costs nothing.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
            }
            return
        }
        // A mismatched panel (or Match Frame Rate off) stays at its home rate
        // (typically 60Hz): keep the pulldown softening on. Only until this
        // session has actually DECIDED, though — KSPlayer calls this 2–3× per
        // load, and re-arming the softening on the later calls would undo a
        // switch that already landed.
        // Re-arm only when nothing has been pinned yet this stint; re-arming on
        // every call would undo the clear below on KSPlayer's 2nd/3rd
        // `updateVideo` for the same load.
        if lastAppliedRefreshRate == nil { pulldown60Hz = true }
        // Orivio probe, BEFORE the guard: the interesting case is the one where
        // this title never gets to ask. A panel pinned by an earlier title in
        // the same foreground stint keeps that title's dynamic range, and SDR
        // content sent into an HDR mode is exactly the washed-out picture.
        let displayGate = "display gate content=\(formatDescription?.dynamicRange.description ?? "unknown")"
            + " rate=\(refreshRate) matchToggle=\(matchDisplayCriteria) nativeDV=\(nativeDV)"
            + " panelNow=\(UIScreen.main.maximumFramesPerSecond)fps"
            + " pin=\(SessionDisplayMode.pinDescription)"
            + " panelSupports=[\(DynamicRange.availableHDRModes.map(\.description).joined(separator: ","))]"
            // The Apple TV's own Video and Audio → Match Content → Match
            // Dynamic Range setting, read live off AVDisplayManager. If this is
            // false the app's request is IGNORED and HDR/DV is tone-mapped into
            // the home format — the classic "this movie looks too dark".
            + " matchContentSetting="
            + (UIApplication.shared.ks_keyWindow?.avDisplayManager.isDisplayCriteriaMatchingEnabled.probe ?? "?")
        PlayerViewModel.colorTrail(displayGate)
        // Also into the LIVE probe tail, which the colour trail (UserDefaults,
        // served at `/`) never reached — the per-title darkness question needs
        // to be answerable from the one recording.
        PlayerProbe.event("display", displayGate)
        // THE INFUSE POLICY. Dolby Vision sessions may request the DV mode by
        // default (`nativeDV`) — that's the point of playing DV. Everything
        // else (HDR10/SDR via this path) stays hands-off unless the user opts
        // in with "Match content display mode". The grey-screen wedge is
        // prevented not by refusing the switch IN but by never switching BACK
        // while the app is alive: the pin holds for the whole foreground
        // stint (releaseDisplayForExit is a no-op) and tvOS performs the one
        // unavoidable revert invisibly when the app backgrounds.
        guard matchDisplayCriteria || nativeDV,
              SessionDisplayMode.isPlausibleRate(refreshRate),
              let displayManager = UIApplication.shared.ks_keyWindow?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled,
              let formatDescription
        else { return }
        var target = formatDescription.dynamicRange
        let contentRange = target
        // FFmpeg/Metal renders DV as HDR10 output (KSPlayer's own mapping) —
        // but a native-DV session really does emit Dolby Vision, so keep it.
        // `isDovi` is the second way a session can say that, and the only one
        // the AVPlayer path has: it plays the file's own dvh1/dvhe elementary
        // stream out untouched, so clamping it dropped every DV mp4/mov to
        // HDR10 — and, because the pin holds for the whole foreground stint,
        // dragged every later title down with it. This does NOT widen the
        // opt-in gate above: with "match content display mode" off we have
        // already returned. The Metal path can't be caught by the new term
        // either — its format description is built from the DECODED pixel
        // buffer, whose subtype is a pixel format and never dvh1/dvhe, so
        // `target` is .hdr10 there no matter what `isDovi` says.
        if target == .dolbyVision, !nativeDV, !isDovi { target = .hdr10 }
        let available = DynamicRange.availableHDRModes   // [.sdr] when none
        PlayerViewModel.colorTrail(
            "display request content=\(contentRange) -> target=\(target)"
                + " nativeDV=\(nativeDV) isDovi=\(isDovi) panelSupports=[\(available.map(\.description).joined(separator: ","))]"
                + " rate=\(refreshRate) matchToggle=\(matchDisplayCriteria)"
        )
        if target != .sdr, !available.contains(target) {
            if available.contains(.hdr10) { target = .hdr10 }
            else if available.contains(.hlg) { target = .hlg }
            else { target = .sdr }
        }
        // REFRESH RATE: always ask for the content's, and let tvOS decide.
        //
        // This is the model every streaming app on the platform uses. The app
        // hands `AVDisplayCriteria` a rate AND a dynamic range; tvOS then
        // applies whichever of them the viewer enabled under
        // Settings -> Video and Audio -> Match Content. Asking for both is not
        // overreach — it is the only way to express "here is what the content
        // is", and Match Frame Rate off simply means the rate half is ignored.
        //
        // TWO STALE CLAIMS USED TO SIT HERE, and both would send the next
        // reader the wrong way:
        //   * that the rate is not switched by default and
        //     `options.matchFrameRate` opts into it. That property is written
        //     in `configureOptions` and READ NOWHERE — the rate below is
        //     unconditional, so the flag has no effect at all.
        //   * that "no in-app revert exists anymore". One does again:
        //     `releaseDisplayForExit` puts the panel back when the player
        //     closes, which is what stops the whole UI being left running at
        //     the film's rate.
        //
        // A 24fps movie in a 60Hz envelope is 3:2 pulldown judder, which is
        // the thing a real player exists to avoid.
        // The SAME snap the two direct-engine display requests use. This path
        // still carried the original rule — fold anything in 23.5…24.2 onto
        // 23.976 — which `snapToBroadcastRate` was written to replace: it
        // cannot tell 24000/1001 from a true 24/1, so genuinely-24p content
        // playing through KSPlayer was put into a 23.976 panel and repeated a
        // frame every ~42 seconds. Two of the three request sites were moved
        // over; this one was missed, and it is the one every FFmpeg and native
        // session goes through.
        let contentRate = SessionDisplayMode.snapToBroadcastRate(refreshRate)
        // RATE: only ask for the content's rate when the viewer opted in. With
        // `matchFrameRate` OFF (the default) we pass the rate the panel is
        // ALREADY running, so the request changes only the dynamic range — the
        // 60↔24 renegotiation is the heavy HDMI mode switch that wedges some
        // panels into a solid grey screen, while a range-only change is
        // handled in-band. This is exactly what the setting's own doc always
        // said ("off = keep the current rate, only vary dynamic range"); it was
        // simply read nowhere and the content rate was always sent.
        let rate = matchFrameRate ? contentRate : Float(UIScreen.main.maximumFramesPerSecond)
        // The pin may ALREADY hold this content's cadence — a previous title at
        // the same rate in this foreground stint. The panel is therefore running
        // at the content rate and the 3:2 softening must be off, even though no
        // switch happens on this call and the dedupe guard below returns first.
        // Clearing it only after a successful `applyOnce` left the second and
        // every later 24fps title fighting a cadence that was not there.
        if let pinned = lastAppliedRefreshRate, abs(pinned - contentRate) <= 1.5 {
            pulldown60Hz = false
        }
        guard lastAppliedDynamicRange != target.rawValue
            || lastAppliedRefreshRate != rate else { return }
        lastAppliedDynamicRange = target.rawValue
        lastAppliedRefreshRate = rate
        guard let criteria = AVDisplayCriteria(refreshRate: rate, videoDynamicRange: target.rawValue)
        else { return }
        guard SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate,
                                           range: target.rawValue) else { return }
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

    /// Consecutive badly-late frames, for the hard re-anchor below.
    private var badlyLateCount = 0

    /// Wall-clock instant the current unbroken run of "video is late" began,
    /// 0 when video is not currently late. Drives `fineCatchUp` below.
    private var lateRunBegan: Double = 0

    /// Wall-clock instant this options object first saw a sync decision, so
    /// the correction can converge faster during the opening seconds (see
    /// `fineCatchUp`). Options are built per load, so this is per session.
    private var firstSyncAt: Double = 0

    /// Sync telemetry, for the `[engine]` probe block. Written on the render
    /// clock thread and read on main — plain counters on purpose: a torn read
    /// costs a wrong digit in a diagnostic, and a lock here would sit in the
    /// per-frame path. Same trade-off `pulldown60Hz` already makes.
    ///
    /// `queueStarved` is the one that matters: `frameCount` is the DECODED
    /// frame queue's depth at the moment of the decision, so a session that
    /// spends its life at depth 1 has no catch-up headroom at all and no
    /// frame-dropping policy — stock's or ours — can shorten a deficit.
    private(set) var syncDecisions = 0
    private(set) var queueStarved = 0
    private(set) var queueDepthSum = 0
    private(set) var catchUpWanted = 0
    private(set) var catchUpIssued = 0
    private(set) var worstLateMs = 0

    /// Snapshot for the probe. Main-actor callers only read.
    var syncProbeLine: String {
        let avg = syncDecisions > 0 ? Double(queueDepthSum) / Double(syncDecisions) : 0
        let starvedPct = syncDecisions > 0 ? 100 * Double(queueStarved) / Double(syncDecisions) : 0
        return String(format: "queue avg=%.2f starved=%.0f%% of %d | catchUp wanted=%d issued=%d | worstLate=%dms",
                      avg, starvedPct, syncDecisions, catchUpWanted, catchUpIssued, worstLateMs)
    }

    override func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Double, frameCount: Int) -> (Double, ClockProcessType) {
        let (diff, action) = super.videoClockSync(main: main, nextVideoTime: nextVideoTime, fps: fps, frameCount: frameCount)
        // HARD RE-ANCHOR when video is seconds behind. The stock policy shows
        // every other late frame and only re-anchors at diff < −8 every 100th
        // tick — a multi-second deficit (a stall clearing, a seek landing) was
        // worked off as a visible slow-motion chop "till it reaches where it
        // was". A clean jump is what a viewer expects there. Ten consecutive
        // badly-late frames first, NOT immediately: right after a resume the
        // main clock can read ahead by the whole pause until the first audio
        // render re-stamps it, and re-anchoring on that lie would skip real
        // content.
        if diff < -2 {
            badlyLateCount += 1
            if badlyLateCount >= 10 {
                badlyLateCount = 0
                return (diff, .seek)
            }
        } else if diff > -0.2 {
            badlyLateCount = 0
        }
        // FINE LIP-SYNC CORRECTION — the fix for "the audio is ahead of the
        // picture on every single title".
        //
        // KSPlayer's gate is ASYMMETRIC. A frame that is EARLY is held back
        // until it is within half a frame of the master clock, so video can
        // never lead by more than ~20ms. A frame that is LATE is simply shown,
        // with no correction whatsoever, until it is more than `4/fps` behind
        // — 167ms at 24fps (`KSOptions.videoClockSync`). The whole band from
        // −167ms to 0 is a dead zone with no restoring force in it.
        //
        // So whatever lateness a session happens to START with is frozen in
        // for its whole duration. And every session starts with some: the
        // first picture cannot appear until it has been demuxed, decoded and
        // handed to the layer, by which time the audio clock has already been
        // running. Video then plays out at exactly 1.0x from wherever it
        // entered, permanently behind — which is heard as the audio running
        // early, on every title, by a fixed amount. Measured on the device:
        // `avSync` sat at exactly −0.15s for minutes without moving, and at
        // −0.05s in a previous session of the same file. Nothing in the stock
        // policy was ever going to pull either of them back.
        //
        // Video cannot be advanced against a master audio clock except by
        // showing one frame fewer, so that is what this does — gently. One
        // single frame, only after the lateness has persisted long enough to
        // be a standing offset rather than jitter, and only inside the band
        // stock KSPlayer ignores (past `4/fps` its own catch-up takes over and
        // this stays out of the way). Each drop recovers exactly one frame
        // duration, so a 150ms offset is gone in four of them and the
        // correction then stops firing because `diff` is back inside the
        // threshold. It is a servo that converges on zero and costs nothing
        // once it is there — not a fixed compensation bolted onto the clock.
        //
        // The threshold is 1.5 frame durations so that a single drop can never
        // overshoot into video-early; convergence is quicker over the opening
        // seconds, where a missing frame is invisible and the offset is at its
        // largest and most noticeable.
        //
        // `frameCount` is the decoded queue's depth, and it is the hard limit
        // on this working at all: `.dropNextFrame` shows the head frame and
        // then discards the one BEHIND it, so with only the head decoded there
        // is nothing to discard and the call is a no-op. Ask for a drop only
        // when one can actually land; the deficit is unchanged either way, so
        // a starved tick simply tries again on the next run of lateness.
        syncDecisions &+= 1
        queueDepthSum &+= frameCount
        if frameCount <= 1 { queueStarved &+= 1 }
        if diff < 0 { worstLateMs = max(worstLateMs, Int(-diff * 1000)) }
        if fps > 0, action == .next, diff < -1.5 / fps, diff >= -4 / fps {
            let now = CACurrentMediaTime()
            if firstSyncAt == 0 { firstSyncAt = now }
            if lateRunBegan == 0 { lateRunBegan = now }
            let settle = now - firstSyncAt < 4 ? 0.15 : 0.4
            if now - lateRunBegan >= settle {
                // Require a fresh run of lateness before the next one, which
                // is what paces the drops and stops this ever becoming the
                // every-other-frame chop the softening below exists to avoid.
                lateRunBegan = 0
                catchUpWanted &+= 1
                if frameCount >= 2 {
                    catchUpIssued &+= 1
                    return (diff, .dropNextFrame)
                }
            }
        } else {
            lateRunBegan = 0
        }
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
    /// The cache band's end, 0…1 of the film.
    ///
    /// PUBLISHED rather than read straight off `MediaCacheServer`: the server
    /// is a plain singleton, so a computed property reading it gave SwiftUI
    /// nothing to observe. The bar only refreshed as a side effect of
    /// `position` ticking — which meant that while PAUSED nothing invalidated
    /// the view and the band sat still, looking for all the world like a
    /// stalled download while the cache was in fact filling normally.
    @Published var cacheEnd: Double = 0

    /// EVERY cached stretch of the film, as 0…1 spans, not just the one in
    /// front of the playhead.
    ///
    /// The bar used to draw a single band from the playhead to the end of its
    /// contiguous run, which was the whole truth while the cache only ever
    /// filled forwards. It is not any more: the archive builds the film up from
    /// the beginning and around every place the viewer has jumped to, so a
    /// session collects several disjoint stretches and the bar was showing one
    /// of them and silently hiding the rest.
    @Published var cachedSpans: [ClosedRange<Double>] = []

    /// Bumped whenever the scrub/fine preview frame sets change, so the
    /// scene window can pop a newly decoded frame in under a resting finger.
    /// Lives HERE for the same reason `scrubTarget` does: as `@Published`
    /// arrays on the view model, every partial thumbnail merge re-rendered
    /// the ENTIRE PlayerScreen ZStack (which does not observe this clock) at
    /// decode rate for minutes-long stretches of every A10X session.
    @Published var previewsRevision: UInt64 = 0
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
            //
            // Only from the session that owns the globals (see
            // sharedStateOwner): a retired session's engine reports `paused` as
            // its teardown stops it, and that late write re-enabled the
            // screensaver over the film that was actually playing.
            if ownsSharedState { UIApplication.shared.isIdleTimerDisabled = isPlaying }
        }
    }
    @Published private(set) var isBuffering = true {
        // BOTH side effects only on TRANSITIONS: engines re-fire same-value
        // buffering callbacks repeatedly during a stall. Re-arming the
        // watchdog on identical writes would perpetually reset its 20s timer;
        // re-running the spinner debounce cancelled + respawned its 500ms
        // task per identical write — churn, and a stall re-firing faster than
        // 500ms could keep the spinner from ever appearing. (The @Published
        // publish itself still fires per write; the setters guard upstream.)
        didSet {
            guard oldValue != isBuffering else { return }
            // Rebuffer accounting. A single stall is nothing; forty of them, or
            // ninety seconds of them across a film, is the complaint — and
            // neither is visible from a scrolling event tail. Only counted once
            // playback has actually begun, so the initial open isn't scored as
            // a stall.
            if hasStartedPlayback, !pauseIntent {
                if isBuffering {
                    rebufferStartedAt = Date()
                    PlayerProbe.count("stall.count")
                    PlayerProbe.event("engine", String(format: "STALL began at %.1f", position))
                } else if let began = rebufferStartedAt {
                    let held = Date().timeIntervalSince(began)
                    rebufferStartedAt = nil
                    rebufferSeconds += held
                    PlayerProbe.count("stall.ms", by: Int(held * 1000))
                    PlayerProbe.note("stallTotal", String(format: "%.1fs", rebufferSeconds))
                    PlayerProbe.event("engine", String(format: "STALL ended after %.1fs", held))
                }
            }
            updateBufferSpinner()
            updateStallWatchdog()
        }
    }
    /// A source that OPENED and then froze mid-stream (a debrid CDN cutting off
    /// an IP-locked link after the first request succeeds) keeps buffering
    /// forever with nothing to re-trigger failover — the load watchdog was
    /// already disarmed when the stream opened. This catches a sustained stall
    /// during active playback and fails over.
    private var stallWatchdogTask: Task<Void, Never>?
    private let stallTimeoutSeconds: UInt64 = 20
    /// Rebuffer accounting for the probe's `[health]` block.
    private var rebufferStartedAt: Date?
    private var rebufferSeconds: TimeInterval = 0
    /// Last VLC state tuple written to the probe, so its self-repeating
    /// callback doesn't flood the tail.
    private var lastVLCProbeState = ""

    private func updateStallWatchdog() {
        stallWatchdogTask?.cancel()
        // Only while a stream that already started keeps buffering, mid-playback.
        // (A brief seek/skip blip cancels-and-re-arms, so only a SUSTAINED
        // stall ever fires.)
        guard isBuffering, currentLoadStarted, hasStartedPlayback,
              !isExiting, !isFailingOver, !pauseIntent else { return }
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
                  !self.isExiting, !self.isFailingOver,
                  // A paused viewer is not a stall — failing over here loaded
                  // a fresh source that AUTOPLAYS into an empty room.
                  !self.pauseIntent else { return }
            // The clock moved since arming → not a stall, whatever the flag
            // says. Re-arm and keep watching.
            if abs(self.position - armedPosition) > 2 {
                self.updateStallWatchdog()
                return
            }
            PlayerProbe.event("watchdog", String(
                format: "STALL TIMEOUT — buffering %ds with the clock stuck at %.1f",
                Int(timeout), self.position))
            PlayerProbe.count("watchdog.stall")
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
        // NOT WHILE THE VIEWER HAS PAUSED. `isBuffering` is the engine's own
        // state; the spinner is a promise to the viewer that we are waiting on
        // the network. On a paused session those are not the same thing, and
        // this app already draws that distinction — `updateStallWatchdog`
        // stands down on `pauseIntent` with the note "a paused viewer is not a
        // stall".
        //
        // Measured on the device: waking from tvOS display sleep runs
        // `resyncPipeline`, whose flush-seek with `autoPlay: false` puts the
        // engine into `.buffering` — and a paused engine never pumps enough to
        // report its way back out. The probe caught 52 seconds of it (RESYNC at
        // t=1901.1, no engine state event at all until the viewer pressed play
        // at t=1953.5, which reported `bufferFinished` 17ms later). Nothing was
        // wrong with the stream; the spinner was, and the stall watchdog that
        // would normally rescue one was already standing down on the same flag.
        if isBuffering, !pauseIntent {
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
    @Published private(set) var hasStartedPlayback = false {
        didSet {
            if hasStartedPlayback, !oldValue {
                PlayerProbe.event("load", String(
                    format: "FIRST FRAME after %.1fs (%@)",
                    Date().timeIntervalSince(sessionOpenedAt), engineLabelForPiP))
                PlayerProbe.note("firstFrameSeconds",
                                 String(format: "%.1f", Date().timeIntervalSince(sessionOpenedAt)))
                PictureInPictureController.trail("load: first playback (\(engineLabelForPiP))")
                // The first frame arrived — the open→first-frame gap this
                // watchdog covers is closed.
                firstFrameWatchdogTask?.cancel()
                firstFrameWatchdogTask = nil
            }
        }
    }
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    let clock = PlaybackClock()
    /// Which engine KSPlayerLayer is currently using ("Native" / "FFmpeg").
    @Published private(set) var engineName = "Native"

    // UI state
    /// Bumped each time the transport is RAISED from a state that wasn't
    /// showing it. Not bumped for moves between transport states
    /// (controls ↔ pauseInfo, controls ↔ a track popover), which must leave
    /// focus exactly where the viewer put it.
    ///
    /// The transport resets focus to the bar in `onAppear`, which works only
    /// when SwiftUI has actually torn the overlay down and built a new one. It
    /// does not always: raising the transport again inside its own dismiss
    /// transition leaves the outgoing copy on screen still holding focus on
    /// whichever glyph it had, and a press then lands on Subtitles instead of
    /// the bar. This counter is the same reset driven by state rather than by
    /// view lifetime, so it fires either way.
    @Published private(set) var controlsSession = 0

    @Published var overlay: PlayerOverlay = .none {
        didSet {
            guard overlay != oldValue else { return }
            if overlay.showsTransport, !oldValue.showsTransport {
                controlsSession &+= 1
            }
            if case .error(let message) = overlay {
                PlayerProbe.event("fail", "ERROR OVERLAY: \(message)")
                PlayerProbe.count("error.overlay")
                PlayerProbe.note("lastErrorShown", message)
            }
            // Which panel is up decides what nearly every button means, so an
            // unexplained overlay change is the hidden cause behind a whole
            // class of "the remote stopped working" reports. Cheap, and the
            // one line that makes an input trace readable.
            PlayerProbe.event("ui", "overlay \(oldValue.probeName) → \(overlay.probeName)")
        }
    }
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

    // Content
    let meta: MetaItem
    @Published private(set) var currentVideo: MetaVideo? {
        didSet { refreshNextEpisodeAvailability() }
    }
    /// Whether `nextEpisode` would find one, cached.
    ///
    /// The transport's Next Episode glyph asks this on every body pass, and
    /// the controls overlay is rebuilt on every clock tick while it is on
    /// screen — `nextEpisode` itself filters and sorts the title's ENTIRE
    /// episode list, which is a per-frame sort of a few hundred episodes on a
    /// two-core box. The inputs are `currentVideo` and `enrichedMeta`, and
    /// both refresh this when they change, so nothing has to remember to.
    @Published private(set) var nextEpisodeAvailable = false

    private func refreshNextEpisodeAvailability() {
        let available = nextEpisode != nil
        if nextEpisodeAvailable != available { nextEpisodeAvailable = available }
    }
    @Published private(set) var currentEntry: StreamEntry
    @Published private(set) var allEntries: [StreamEntry]
    @Published private(set) var isSwitchingSource = false {
        didSet {
            // A switch that ends WITHOUT loading anything (torrent resolve
            // failed, failover bailed on a stale generation) must not eat an
            // end-of-stream that arrived while it was up: engines announce
            // the end exactly once, so a swallowed one froze the session on
            // the last frame with no post-play and no Up Next. A switch that
            // DID load cleared the note in resetPerLoadSessionState first.
            if !isSwitchingSource, oldValue, pendingEndAfterSwitch {
                pendingEndAfterSwitch = false
                handlePlayedToEnd()
            }
        }
    }
    /// See `isSwitchingSource.didSet`.
    private var pendingEndAfterSwitch = false
    /// What the switching cover should SAY. It was hard-coded to "Loading next
    /// episode" in the view, so a source failover — by far the commonest reason
    /// it appears — told the viewer an episode was changing when it was not.
    @Published private(set) var switchingSourceLabel = "Switching source…"

    /// The transport may act on the remote right now: a stream is up, it is
    /// not being replaced, and the player is not on its way out.
    ///
    /// `isSwitchingSource` is the gap BETWEEN two streams — an episode
    /// advance, a source switch, a failover. `SwitchingSourceOverlay` covers
    /// the screen for it, but it is scenery: it has no focusable content, so
    /// focus stayed on the invisible catcher underneath and every press went
    /// straight through to a session that was being torn down. A Select there
    /// resumed the outgoing layer (`togglePlayPause` reads it as paused and
    /// plays it), left/right seeked it, and a swipe raised the PREVIOUS
    /// episode's transport — title and all — behind the "Loading next
    /// episode" cover. Nothing reset `hasStartedPlayback` across the gap, so
    /// the guard every one of those paths already had let them all in.
    private var acceptsTransportInput: Bool {
        hasStartedPlayback && !isSwitchingSource && !isExiting
    }

    private(set) var playerLayer: KSPlayerLayer?
    /// The VLC engine, active only when the VLC playback engine is selected;
    /// mutually exclusive with `playerLayer`.
    private(set) var vlcEngine: VLCEngine?
    var usingVLC: Bool { vlcEngine != nil }
    /// The direct Dolby Vision sample-feed engine (no AVPlayer, no HLS, no
    /// CoreMedia retention) — the Infuse architecture. Mutually exclusive
    /// with the other engines while active.
    private(set) var dvDirectEngine: DVSampleEngine?

    /// Experimental Atmos passthrough (see `AtmosHLS.swift`). Set only for an
    /// E-AC-3/AC-3 track on an HDMI route with the setting on.
    private var atmosPassthrough: AtmosPassthrough?
    private var atmosSyncTask: Task<Void, Never>?
    /// When the last seek was issued. The Atmos sync task nudges the video
    /// clock onto the AVPlayer's audio clock; right after a seek the AVPlayer
    /// is still catching up, so letting the sync run would drag the picture
    /// straight back to where the audio still is. Suppress it briefly.
    private var lastSeekIssuedAt = Date.distantPast
    var usingDVDirect: Bool { dvDirectEngine != nil }
    /// The UIView the active engine renders into (KSPlayer's player view,
    /// VLC's drawable, or the DV sample layer), handed to PlayerVideoView.
    var activeVideoView: UIView? {
        isExiting ? nil : (dvDirectEngine?.videoView ?? vlcEngine?.videoView ?? playerLayer?.player.view)
    }
    /// Picture in Picture, when the loaded engine can feed it.
    let pictureInPicture = PictureInPictureController()

    /// The layer PiP can take over, or nil when the live engine has none.
    /// Only this type knows which engine loaded, so the resolution lives here
    /// rather than in the controller. tvOS AVKit accepts nothing but an
    /// `AVPlayerLayer` (see the PictureInPicture.swift header), which of the
    /// four engines only the native one has.
    var pictureInPictureLayer: AVPlayerLayer? {
        guard !isExiting, dvDirectEngine == nil, vlcEngine == nil,
              let player = playerLayer?.player as? KSAVPlayer else { return nil }
        return player.view?.layer as? AVPlayerLayer
    }

    /// Containers AVPlayer streams well, and the ones that always need FFmpeg.
    /// Shared by engine routing in `load` and by the PiP row's "can this title
    /// switch to Native" test, so the two can't drift apart.
    static let ffmpegContainers: Set<String> = ["mkv", "avi", "flv", "wmv", "ts", "m2ts", "webm"]
    static let nativeContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "aac"]

    /// The container of the current source as engine routing would see it:
    /// URL extension, then a container learned from an earlier sniff of the
    /// link, then the filename in the stream title. Empty when unknown.
    private var currentSourceContainer: String {
        guard let url = currentEntry.stream.url.flatMap(URL.init(string:)) else { return "" }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty, let learned = ContainerSniffer.cached(url.absoluteString) { ext = learned }
        if ext.isEmpty,
           let filename = currentEntry.stream.title,
           let dotExt = filename.split(separator: ".").last.map({ String($0).lowercased() }),
           Self.ffmpegContainers.contains(dotExt) || Self.nativeContainers.contains(dotExt) {
            ext = dotExt
        }
        return ext
    }

    /// Can this session reach PiP by moving to the native engine? True for a
    /// title on FFmpeg/VLC whose container AVPlayer streams (mp4/HLS — the
    /// Settings default or the engine picker put it on the other engine).
    /// False on mkv and friends, where switching would only fail to play, and
    /// on a native session, which arms PiP by itself or not at all.
    var canEnterPictureInPictureViaNativeEngine: Bool {
        // Test the LIVE engine, not the setting: on the default `.auto` an
        // mp4 already plays on the native engine (a player layer exists), and
        // the row then offered a full reload onto the same engine for nothing.
        guard !isExiting, !isSwitchingSource, dvDirectEngine == nil,
              effectiveEngine != .native, pictureInPictureLayer == nil,
              AVPictureInPictureController.isPictureInPictureSupported() else { return false }
        return Self.nativeContainers.contains(currentSourceContainer)
    }

    /// Mute/unmute whichever engine is rendering — the PiP window's control.
    private func setPictureInPictureMuted(_ muted: Bool) {
        if let engine = dvDirectEngine {
            engine.setMuted(muted)
        } else if let vlcEngine {
            vlcEngine.setMuted(muted)
        } else if let playerLayer {
            playerLayer.player.playbackVolume = muted ? 0 : 1
        }
    }

    /// Switch to Native and enter PiP as soon as AVKit arms it — one press
    /// from the options menu does both, instead of sending the viewer to the
    /// engine picker and back.
    func enterPictureInPictureViaNativeEngine() {
        pictureInPicture.startWhenPossible()
        switchEngine(.native)
    }

    /// Re-point PiP at whatever the engine is rendering into RIGHT NOW.
    ///
    /// `PlayerVideoView` attaches once per engine swap and deliberately does
    /// not observe this model, but KSPlayerLayer fails over between engines
    /// underneath it (FFmpeg → native produces a player layer that did not
    /// exist at attach time). Called from the clock ticks; `attach`
    /// early-returns unless the layer identity really changed, so the
    /// steady-state cost is a pointer compare.
    func refreshPictureInPictureSource() {
        // Dev: `-pipViaNative` presses the options-menu row for you once the
        // non-native engine is up, so the switch-then-start path can be
        // verified on a device with no remote in hand.
        if PlayerDevFlags.pipViaNative,
           !pipViaNativePressed, canEnterPictureInPictureViaNativeEngine {
            pipViaNativePressed = true
            PictureInPictureController.trail("dev: entering PiP via Native")
            enterPictureInPictureViaNativeEngine()
        }
        let layer = pictureInPictureLayer
        let genericView = layer == nil && !PlayerDevFlags.pipNoGeneric
            ? pictureInPictureGenericView : nil
        // The trail line is INTERPOLATED ONLY WHEN IT CHANGES. Building the
        // string first and comparing it afterwards meant one String allocation
        // per clock tick — ten a second for the whole film — to discover that
        // nothing had changed, which is the answer roughly every time.
        let kindTag: Int = layer != nil ? 1 : (genericView != nil ? 2 : 0)
        let engineTag = engineLabelForPiP
        if kindTag != lastPiPSourceTag || engineTag != lastPiPEngineTag {
            lastPiPSourceTag = kindTag
            lastPiPEngineTag = engineTag
            PictureInPictureController.trail(
                kindTag == 1 ? "source=playerLayer"
                    : kindTag == 2 ? "source=generic(\(engineTag))"
                    : "source=none(\(engineTag))"
            )
        }
        if let layer {
            pictureInPicture.attach(layer)
        } else {
            pictureInPicture.attach(genericView: genericView) { [weak self] in
                let bridge = PiPPlaybackBridge()
                bridge.onSetPlaying = { [weak self] playing in
                    guard let self, self.isPlaying != playing else { return }
                    self.togglePlayPause()
                }
                bridge.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
                // The window's mute control only flipped the bridge's own
                // flag — the sound kept playing under a "muted" glyph.
                bridge.onSetMuted = { [weak self] muted in self?.setPictureInPictureMuted(muted) }
                return bridge
            }
            pictureInPicture.bridge?.update(playing: isPlaying, position: position,
                                            duration: duration, size: videoNaturalSize)
        }
        pictureInPicture.consumePendingStart()
        pictureInPicture.probe()
    }

    /// The render view for engines without an `AVPlayerLayer` — FFmpeg's
    /// MetalPlayView, VLC's drawable, the DV engine's layer view — handed to
    /// the generic-view PiP path. Nil while exiting or before the engine has
    /// a view.
    var pictureInPictureGenericView: UIView? {
        guard !isExiting else { return nil }
        return activeVideoView
    }

    /// Split in two so the steady-state comparison is an Int and a String
    /// literal, never a freshly interpolated description (see above).
    private var lastPiPSourceTag = -1
    private var lastPiPEngineTag = ""
    private var pipViaNativePressed = false

    /// Which engine is live, for the PiP trail.
    private var engineLabelForPiP: String {
        if dvDirectEngine != nil { return "dvDirect" }
        if vlcEngine != nil { return "vlc" }
        if playerLayer?.player is KSMEPlayer { return "ffmpeg" }
        if playerLayer?.player != nil { return "native" }
        return "no engine"
    }

    /// True between PiP starting and the session ending or being restored.
    /// `PlayerScreen.onDisappear` reads it to skip `teardown()`: the video is
    /// still playing, just in the corner, so nothing teardown cancels should
    /// be cancelled yet.
    var isHandingOffToPictureInPicture = false

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

    /// The active profile's Auto Link Selector settings, handed in by
    /// `PlayerScreen` (they live on `ProfileStore`, which the view model has no
    /// route to on its own).
    ///
    /// The next-episode advance honours them the same way the pre-play source
    /// list does: with the selector ON, an advance may only use the preferred
    /// addon and then the secondary one — the addons you actually chose —
    /// instead of marching the entire pool. Left unbounded it walked every
    /// source on the list, including addons that never work, which on an
    /// episode the debrid has not cached yet meant sixteen failovers and
    /// sixteen toasts in fifteen seconds.
    var autoLinkPrefs = AutoLinkPreferences()

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
    private var pauseIntent = false {
        // Intent clearing is a watchdog moment: the 20s stall watchdog is a
        // one-shot whose fire path stands down while `pauseIntent` is set —
        // and with the same-value buffering dedupes there may never be
        // another false→true transition to re-arm it. A film frozen while
        // "paused" then had NO rescue once the user pressed play again.
        didSet {
            // Only on a real transition. `pauseIntent` is written from several
            // paths with the value it already has, and `updateBufferSpinner`
            // cancels and respawns its 500ms debounce on every call — the same
            // churn the `isBuffering` didSet guards against for the same reason.
            guard oldValue != pauseIntent else { return }
            if oldValue, !pauseIntent { updateStallWatchdog() }
            // The spinner is gated on intent too (see updateBufferSpinner), and
            // `isBuffering` may not transition again to drive it: pausing must
            // take a visible spinner down, and resuming must be able to put it
            // back up for a stream that really is stuck.
            updateBufferSpinner()
        }
    }

    private func enginePlay() {
        pauseIntent = false
        if pictureInPicture.isActive { PictureInPictureController.trail("engine play (PiP active)") }
        if let dvDirectEngine { dvDirectEngine.play() }
        else if let vlcEngine { vlcEngine.play() } else { playerLayer?.play() }
    }
    /// Stop whichever engine is live, WITHOUT setting `pauseIntent`.
    ///
    /// For a switch that is about to replace the stream (next episode). The
    /// episode switch used to call `playerLayer?.pause()` alone, which is a
    /// no-op on the Dolby Vision and VLC engines — so the OUTGOING episode
    /// kept decoding and playing audio underneath the "Loading next episode…"
    /// cover for the whole source lookup, and if it reached its end in that
    /// window the EOF handler armed a SECOND Up Next countdown that advanced
    /// again. `enginePause` is the wrong tool here: its `pauseIntent` is the
    /// documented trap that pins the transport as paused for the next load.
    private func engineStopForSwitch() {
        if let dvDirectEngine { dvDirectEngine.pause() }
        else if let vlcEngine { vlcEngine.pause() }
        else { playerLayer?.pause() }
    }

    private func enginePause(_ reason: String = "?") {
        PlayerProbe.event("transport", "PAUSE (\(reason))")
        // A pause outranks any autoplay rescue still polling: the watchdog
        // checks `pauseIntent` on each pass, but cancelling outright means it
        // cannot restart playback in the gap between this call and the engine
        // reporting `.paused`.
        seekPlayWatchdog?.cancel()
        seekPlayWatchdog = nil
        pauseIntent = true
        if pictureInPicture.isActive { PictureInPictureController.trail("engine pause (PiP active)") }
        if let dvDirectEngine { dvDirectEngine.pause() }
        else if let vlcEngine { vlcEngine.pause() } else { playerLayer?.pause() }
    }
    private func engineSeek(to seconds: Double, autoPlay: Bool) {
        let issuedAt = Date()
        let from = position
        lastSeekIssuedAt = issuedAt
        PlayerProbe.event("seek", String(format: "ISSUE %.1f → %.1f autoPlay=%@ engine=%@",
                                         from, seconds, autoPlay.probe, engineLabelForProbe))
        PlayerProbe.count("seek.issued")
        // Direct sample feed: its timeline IS the source timeline — no
        // window, no offset, no re-remux. Seeks are plain.
        if let dvDirectEngine {
            dvDirectEngine.seek(to: seconds)
            // The Atmos AVPlayer owns the audio for this session, so it has to
            // be seeked too. Skip this and the 1s sync task (which follows the
            // audio clock) pulls the picture straight back to the audio's old
            // position — the seek appears to do nothing.
            atmosPassthrough?.seek(to: seconds)
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
            // The completion flag was discarded here. `finished == false` is
            // the engine saying it REFUSED or superseded the seek, and it is
            // the whole explanation for a scrub that snaps back, a chapter jump
            // that does nothing, and a resume that lands somewhere else — none
            // of which leave any other trace.
            playerLayer?.seek(time: seconds, autoPlay: autoPlay) { [weak self] finished in
                guard let self else { return }
                PlayerProbe.event("seek", String(
                    format: "LANDED %@ target=%.1f actual=%.1f after %.2fs",
                    finished ? "ok" : "REFUSED", seconds, self.position,
                    Date().timeIntervalSince(issuedAt)))
                if !finished { PlayerProbe.count("seek.refused") }
            }
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
    /// The DV-first preflight's transfer-function answer for the direct
    /// session. The sample engine reads the bitstream but exposes no colour
    /// tags, and `runStreamProbe` refuses to run while it is up, so without
    /// carrying the preflight's own `isPQ` forward the only thing the Info
    /// card knows about a profile-0 direct file is that it is not DV. Valid
    /// only while `dvDirectEngine` is non-nil: the single engine construction
    /// site sets this a few lines before it, so a live engine can never be
    /// paired with a previous session's value.
    private var dvDirectIsPQ = false
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
    /// A `let` of a Sendable lock box, so the nonisolated `deinit` can touch
    /// it: a release off main could otherwise lose a decrement and the census
    /// would report a leak that isn't there.
    nonisolated static let liveInstanceCounter = Atomic<Int>(wrappedValue: 0)
    static var liveInstances: Int { liveInstanceCounter.wrappedValue }

    /// The session that owns the state living OUTSIDE this view model: the
    /// account-sync pause, the hybrid cache session, the idle timer, the
    /// shared GCController's dpad handler and the audio session. There is one
    /// of each per process, and the newest session takes them over.
    ///
    /// Weak on purpose — a model released without a teardown (SwiftUI dropping
    /// a screen it never showed) hands ownership back by deallocating, and a
    /// nil owner means "nobody is playing", so the next teardown is free to
    /// clean up.
    private static weak var sharedStateOwner: PlayerViewModel?

    /// Is this session still the one those globals belong to? False only while
    /// a LATER session holds them, which is not hypothetical: PiP's `didStop`
    /// runs `PiPHandoff.finish()` at AVKit's own moment, so a retired session
    /// can be tearing down while a different film is already playing.
    private var ownsSharedState: Bool {
        Self.sharedStateOwner == nil || Self.sharedStateOwner === self
    }

    deinit {
        Self.liveInstanceCounter.mutate { $0 -= 1 }
        let live = Self.liveInstanceCounter.wrappedValue
        NSLog("[OrivioPlayer] PlayerViewModel deinit (live=%d)", live)
        PlayerProbe.event("leak", "deinit — liveVMs=\(live)")
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

    /// The key every "already tried / already failed / already probed" set is
    /// stored under. NEVER the playback url: with the hybrid cache on, that is
    /// a localhost proxy url carrying a per-session UUID, so a re-entry minted
    /// a string no guard had ever seen and each of them silently stopped
    /// working. The origin link is stable for the title.
    private func retryKey(for url: URL) -> String {
        (url.host == "127.0.0.1" ? currentEntry.stream.url : nil) ?? url.absoluteString
    }
    private var dvFirstTask: Task<Void, Never>?
    /// Bumped by every `load()` and every `startDVFirst`. The DV-first probe
    /// takes seconds, and cancellation alone is not enough once the task is past
    /// its cancellation check — the generation tells a probe whose entry has been
    /// superseded to do nothing at all.
    private var dvFirstGeneration = 0

    /// Cheap synchronous gates for the direct sample-feed start.
    ///
    /// TWO reasons to take this engine, not one. It was written for Dolby
    /// Vision, but it is also the ONLY path in this app that hands a Dolby
    /// AUDIO bitstream to tvOS: it feeds compressed E-AC-3 straight to
    /// `AVSampleBufferAudioRenderer`, where the FFmpeg engine decodes every
    /// codec to LPCM (`AudioSwresample`) and AVPlayer can't open the MKV these
    /// releases ship in. So an Atmos-hinted title now qualifies on its own —
    /// and, crucially, WITHOUT the Dolby Vision display requirement, because
    /// Atmos is an audio feature and a TV with no DV mode has nothing to do
    /// with it.
    private func shouldTryDVFirst(url: URL) -> Bool {
        guard effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              !url.isFileURL,
              Self.memoryFootprintMB() < 850,
              !dvFailedURLs.contains(retryKey(for: url)),
              !dvFirstTried.contains(retryKey(for: url))
        else { return false }
        // A native-friendly container plays DV — and Dolby audio — through
        // AVPlayer as-is. This engine is for the MKV world.
        let ext = url.pathExtension.lowercased()
        guard ext != "mp4", ext != "m4v", ext != "mov", ext != "m3u8" else { return false }
        // Title hint, so an uninterested title pays no preflight at all.
        // Add-on stream names carry both markers; the audio one covers the
        // spellings that never say "Dolby" ("DDP5.1 Atmos", "TrueHD.Atmos",
        // "EAC3"). A TrueHD hint counts on purpose: those files carry the
        // E-AC-3 compatibility track this engine can actually bitstream.
        let haystack = "\(currentEntry.stream.name ?? "") \(currentEntry.stream.title ?? "") \(currentEntry.stream.description ?? "")".lowercased()
        // NO TRAILING \\b, and the spellings spelled out. Release names glue
        // the codec to the channel layout ("DDP5.1"), end on a symbol ("DD+")
        // and drop dashes at random ("E-AC3", "EC-3") — a trailing word
        // boundary missed every one of those, including DDP5.1, which is one
        // of the most common namings there is. The one lookahead keeps a film
        // called "Atmosphere" from buying a header probe it has no use for.
        //
        // Plain `ac-?3` is in here because tvOS bitstreams AC-3 too, and it is
        // third on the priority list. Checked against the names that could
        // collide — AAC, AAC5.1, FLAC, DTS-HD, x264, "MAC3S" — none of them
        // match: `\b` will not start inside a word, so only a real "AC3"
        // token does.
        let learned = DolbyMemory.bitstreamable(meta.id)
        var audioHint = haystack.range(
            of: "\\b(atmos(?!phere)|joc|ddp|dd\\+|e-?ac-?3|ec-?3|ac-?3|true-?hd)",
            options: .regularExpression
        ) != nil
            // A previous play of this title was SEEN carrying bitstreamable
            // Dolby in an HEVC container (see DolbyMemory). That is knowledge,
            // not a guess from a name, and it is what catches the titles whose
            // add-on stream name says nothing about the audio at all — which
            // no hint can reach on a first play.
            || learned
        // ...unless a probe has already looked and found nothing usable. The
        // hint is a guess from a file NAME; this is what the file turned out
        // to be. One probe per title, not one per play — see DolbyMemory.
        //
        // It clears the AUDIO reason ONLY, never the function. Returning early
        // here would have let an audio verdict — recorded from some earlier
        // H.264 release of this title — cancel the Dolby VISION path for a
        // later release that deserves it. Two different reasons, judged apart.
        if audioHint, !learned, DolbyMemory.declined(meta.id) {
            audioHint = false
        }
        // The original video reason keeps its display gate: asking a panel
        // with no DV mode to take a DV feed buys nothing.
        let videoHint = DynamicRange.availableHDRModes.contains(.dolbyVision)
            && haystack.range(of: "\\b(dv|dovi|dolby)\\b", options: .regularExpression) != nil
        guard audioHint || videoHint else { return false }
        // Audio-ONLY entries are a smaller prize than Dolby Vision, so they get
        // a smaller budget: a header that hasn't answered in three seconds is
        // not worth holding the picture for when all that's at stake is which
        // audio path plays. A DV title keeps the original five.
        dvFirstIsAudioOnly = !videoHint
        return true
    }

    /// The pending preflight was entered for AUDIO reasons alone (no Dolby
    /// Vision hint). Sizes the probe budget and lets the preflight decline
    /// early when the file turns out to have nothing this engine can
    /// bitstream — see `startDVFirst`.
    private var dvFirstIsAudioOnly = false

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
        PictureInPictureController.trail("load: DV-first preflight begins")
        dvFirstTried.insert(retryKey(for: url))
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
        Self.beginColorTrail(for: url.absoluteString,
                             "=== DV-first preflight: \(entry.stream.name ?? entry.addonName) ===")
        NSLog("[OrivioDV] DV-first preflight: %@", url.host ?? "?")
        dvFirstTask?.cancel()
        dvFirstGeneration += 1
        let generation = dvFirstGeneration
        dvFirstTask = Task { [weak self] in
            let audioOnly = self?.dvFirstIsAudioOnly ?? false
            // Timed: on a big remote link this header probe is one of the two
            // source opens on the load path (the engine's own open is the
            // other), so its share of "why does this take ten seconds" needs to
            // be on the record.
            let preflightDone = AppProbe.begin("load", "DV-first preflight \(url.host ?? "?")")
            let probe = await StreamProbe.inspect(
                url: url.absoluteString,
                needsStyledASS: false, needsHDR10Plus: false,
                needsDolbyVision: true, timeoutSeconds: audioOnly ? 3 : 5
            )
            preflightDone(probe.dvProfile.map { "DV profile \($0)" } ?? "no DV profile")
            guard let self, !Task.isCancelled, !self.isExiting,
                  // A newer load (source switch, episode change) superseded this
                  // probe while it was in flight. Acting now would either revert
                  // the viewer's switch through the fallback `load(entry:)`
                  // below — saving progress under the wrong link — or stack a DV
                  // engine on top of the stream already playing, doubling audio.
                  self.dvFirstGeneration == generation
            else { return }
            // Profile 7 conversion: ON by default (Settings → Playback →
            // "Brighten Profile 7 Dolby Vision") on everything but the oldest
            // 2 GB box.
            //
            // The on-the-fly P7 -> 8.1 conversion re-processes the whole file,
            // which is why it was once gated to 4 GB machines. The alternative
            // on a cheaper box was worse: it played the HDR10 BASE LAYER only,
            // and Profile 7 carries much of its brightness in the enhancement
            // layer, so the picture came out genuinely DARK (the "why is this
            // movie so dark" report, on a P7 title on the 3 GB 4K). Conversion
            // runs in the SAME sample engine and keeps the Dolby audio
            // bitstream, so the only thing traded is CPU — and on the 3 GB
            // A10X that cost can show as early stalls on a heavy P7 remux, so
            // the setting is the escape hatch. Maximum Fidelity still forces
            // it, Compatibility declines the engine outright (the guard
            // below), and the A8/2 GB HD always keeps the base-layer shortcut.
            let p7ok = self.activeMode == .fidelity
                || PerformanceProfile.recommendsDolbyVisionProfile7
                || (self.settings.convertProfile7ForBrightness && !PerformanceProfile.isLowPower)
            // profile 0 = plain HEVC (HDR10/HDR10+/SDR) — the engine plays it
            // natively with every bitstream SEI intact, so a DV-hinted title
            // that turns out non-DV still direct-starts instead of falling to
            // the decode path.
            let profile = probe.dvProfile ?? 0
            var dvOK = profile == 0 || profile == 5 || profile == 8 || (profile == 7 && p7ok)
            // PROFILE 7 WITHOUT THE CONVERSION: the 2 GB HD's last resort.
            //
            // `p7ok` is now true on every box except the A8/2 GB Apple TV HD,
            // so this branch is only reached there: conversion is too heavy for
            // that SoC, and stripping to the base layer at least keeps the
            // Dolby audio bitstream. Everywhere else the conversion is taken
            // and the picture stays bright.
            //
            // Original rationale for the branch:
            // P7 is the UHD-remux profile, and on the 2-3 GB boxes the P7 → 8.1
            // conversion is off by tier (`recommendsDolbyVisionProfile7`). That
            // declined the whole engine, so the file fell to FFmpeg — which
            // decodes every audio codec — and a P7 remux with a DD+ Atmos track
            // lost Atmos for a reason that is entirely about VIDEO.
            //
            // The engine can play a P7 file's base layer instead: `forceHDR10`
            // drops the DV NALs and publishes plain HEVC. P7's base layer IS
            // HDR10, so the picture is native HDR10 — which is what the FFmpeg
            // fallback was mapping to anyway, only now without the decode. And
            // the reason the tier gate exists does not apply: this path does
            // NOT run the whole-file conversion, it strips two NAL types.
            //
            // Scoped tightly: only when there is an audio prize to win. A P7
            // file with nothing bitstreamable keeps the existing behaviour
            // exactly, because then this would be a video change for nothing.
            var p7BaseLayerForAudio = false
            if profile == 7, !p7ok, probe.hasBitstreamableDolby {
                dvOK = true
                p7BaseLayerForAudio = true
            }
            // A display with NO Dolby Vision mode may still reach this engine
            // now — an Atmos-hinted title qualifies on audio alone. It must
            // only take the path when the file carries no DV at all (profile
            // 0), where the engine publishes a plain HEVC format description
            // and nothing DV-related happens. Handing a DV feed to a panel
            // that has no DV mode is the one thing the old display gate was
            // protecting against, and it still does its job here.
            if profile > 0, !DynamicRange.availableHDRModes.contains(.dolbyVision) {
                dvOK = false
                Self.dvTrail("direct engine declined: DV profile \(profile) but the display has no DV mode")
            }
            // Entered for audio alone and the file has no track tvOS can
            // bitstream: this engine would decode to LPCM exactly like the
            // FFmpeg one, so there is nothing to win and a switch to buy it.
            // Hand it straight back rather than changing the playback path for
            // no reason. (A TrueHD-only file lands here, which is the honest
            // answer to "can you pass TrueHD Atmos through?" — no.)
            if audioOnly, !probe.hasBitstreamableDolby {
                dvOK = false
                Self.dvTrail("direct engine declined: no E-AC-3/AC-3 track to bitstream")
            }
            // Remember a STRUCTURAL no, so the next play of this title doesn't
            // buy the same probe. Only when the header was actually read — a
            // probe that timed out returns all-false, and recording that would
            // blind the title on one bad network moment (see DolbyMemory).
            // "Usable" now has two shapes: HEVC (any eligible audio — the
            // original contract), or H.264 WITH a bitstreamable Dolby track.
            // H.264 gets no free ride on a video hint: it exists on this
            // engine solely for the audio bitstream, so a release name that
            // says "Dolby" but carries H.264 + AAC declines here whichever
            // hint let it in.
            let videoUsable = probe.hasHEVC
                || (probe.hasAVC && probe.hasBitstreamableDolby)
            if audioOnly, probe.durationSeconds > 0, !videoUsable {
                DolbyMemory.rememberDeclined(self.meta.id)
            }
            guard videoUsable, dvOK,
                  probe.hasEligibleAudio,
                  probe.durationSeconds > 60,
                  // A notice clip must not take the direct engine: failover
                  // there means "drop a tier on the SAME source", and the
                  // problem with this one is that it is not the film. Declining
                  // hands it to the normal load, whose duration check fails
                  // over to another LINK.
                  !self.isNoticeClip(probe.durationSeconds),
                  self.activeMode != .compatibility
            else {
                Self.dvTrail("DV-first fell back to normal load (profile=\(probe.dvProfile.map(String.init) ?? "none"), audioOK=\(probe.hasEligibleAudio))")
                self.load(entry: entry)
                // On the KSPlayer path now: run the probe the DV attempt deferred.
                self.runStreamProbe()
                return
            }
            Self.dvTrail("DV-first: profile \(profile == 0 ? "\(probe.hasHEVC ? "HEVC" : "H.264")/\(probe.isPQ ? "HDR10" : "SDR")" : String(profile)), \(Int(probe.durationSeconds))s — direct native start")
            self.dvAttempted = true
            self.nativeKind = .dolbyVision
            self.dvDirectIsPQ = probe.isPQ
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
            AudioOutputCapability.configureForMoviePlayback()
            // Off the main actor: activation is an IPC round trip to
            // mediaserverd (100ms-1s, worse on AirPlay routes) and it sat on
            // the main thread in the middle of the load path.
            await Task.detached(priority: .userInitiated) {
                try? AVAudioSession.sharedInstance().setActive(true)
            }.value
            // Downmix in-engine only when the route genuinely cannot take more
            // than stereo — see DVSampleEngine.downmixToStereo.
            //
            // This used to read `isSpatialAudioEnabled`, which answers a
            // DIFFERENT question: whether tvOS will spatialize in software.
            // An HDMI receiver that decodes Dolby itself reports false for it,
            // so every 5.1/7.1 AVR was treated as a stereo route and the engine
            // folded 8ch to 2ch before it ever left the app. `maximumOutput‑
            // NumberOfChannels` is the capability, and it is read AFTER
            // activation above because an inactive session answers 2.
            let multichannel = AudioOutputCapability.supportsMultichannel
            // FEL titles keep true DV (user's choice). The HDR10-base-layer
            // experiment ran and EXONERATED the converted metadata: the one
            // stuttering FEL title stuttered identically as pure HDR10, and
            // a heavier FEL twin plays smooth as converted DV. forceHDR10
            // stays available as a diagnostic lever.
            // See `p7BaseLayerForAudio`. Otherwise unchanged: FEL titles keep
            // true DV (the HDR10-base experiment exonerated the converted
            // metadata), and this stays available as a diagnostic lever.
            let felHDR10 = p7BaseLayerForAudio
            // One read for both fields — this used to look the title up twice
            // in the same expression.
            let titleMemory = PlaybackMemory.memory(for: self.meta.id)
            let engine = DVSampleEngine(
                input: url.absoluteString, startAt: resume,
                // THE SETTINGS LANGUAGE LEADS. It used to be the other way —
                // per-title memory first — which meant one hand-picked track on
                // one episode pinned that language to the whole series for good
                // (the memory is keyed by show and never expires), and
                // Settings -> Audio was then quietly outranked on every later
                // release. The per-title memory is still consulted, but as a
                // FALLBACK for files carrying nothing in the chosen language —
                // see `applyPreferredDVAudioSecondTurn`.
                preferredAudioLanguage: self.settings.preferredAudioLanguage.isEmpty
                    ? (titleMemory?.audioLanguage ?? "")
                    : self.settings.preferredAudioLanguage,
                convertProfile7: p7ok,
                requestHeaders: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders,
                downmixToStereo: !multichannel,
                forceHDR10: felHDR10,
                preferredAudioLabel: titleMemory?.audioTrackLabel,
                // A link NAMED Atmos is a real signal the container tags don't
                // carry; used only to decide whether to try the Atmos path.
                streamNameSaysAtmos: entry.stream.hasAtmos
            )
            self.dvDirectEngine = engine
            // The title's remembered lip-sync offset, before any audio is fed.
            engine.setAudioDelay(self.audioSyncOffset)
            self.duration = probe.durationSeconds
            self.clock.duration = probe.durationSeconds
            MediaCacheServer.shared.noteDuration(probe.durationSeconds)
            engine.onTime = { [weak self, weak engine] seconds in
                guard let self, let engine, self.dvDirectEngine === engine else { return }
                self.position = seconds
                self.clock.position = seconds
                // This engine's `playableTime`. Without it `buffered` stays 0
                // for the whole session and every buffer-health gate is dead.
                let ahead = max(engine.bufferedUpTo, seconds)
                self.buffered = ahead
                if abs(self.clock.buffered - ahead) >= 1.0 { self.clock.buffered = ahead }
                self.publishBufferHealth()
                self.isPlaying = engine.isPlaying
                self.refreshPictureInPictureSource()
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
                // Guarded: @Published publishes on every assignment, so an
                // unconditional write here re-rendered every VM observer at
                // tick rate for the whole session.
                if advanced, self.isBuffering { self.isBuffering = false }
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
                    // The engine ranked its audio against ONE language at
                    // open; give the Settings default its turn now that the
                    // file's track list is known. Here and not in the start
                    // completion: switching tracks re-demuxes from the
                    // playhead, and the playhead only reads true once the
                    // clock is running.
                    self.applyPreferredDVAudioSecondTurn(engine: engine)
                }
                // Only an ADVANCING clock proves the load is alive. Disarming
                // the 30s load watchdog on the bare tick told it a DV open that
                // never produced a frame was healthy — and since the stall
                // watchdog needs `hasStartedPlayback` (which only the block
                // above sets, on real progress), that left the newly armed
                // watchdog with nothing to catch: a spinner forever.
                if advanced { self.markLoadStarted() }
                self.markPlaybackProgressed(currentTime: seconds)
                // Only when the clock MOVED. This tick fires every 0.5s
                // whether or not playback advances, and an unconditional save
                // re-stamped the transient row's `updatedAt` all through a
                // pause — so a device sitting paused for an hour kept
                // "winning" against another device's real progress (the merge
                // guard reads timestamps) and re-pushed its stale position as
                // the account's newest every thirty seconds.
                if advanced { self.saveProgressThrottled() }
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
                if self.pictureInPicture.isActive {
                    PictureInPictureController.trail("DV engine buffering=\(buffering) (PiP active)")
                }
                // Same-value dedupe: engines re-fire identical buffering
                // callbacks during a stall, and each @Published assignment
                // re-renders every VM observer.
                if self.isBuffering != buffering { self.isBuffering = buffering }
                let playing = !buffering && engine.isPlaying
                if self.isPlaying != playing { self.isPlaying = playing }
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
                    // A successful open proves the source is alive, so hand
                    // over to the 20s STALL watchdog. The 30s load watchdog
                    // otherwise had to cover the probe, the open, the display
                    // handshake (up to 8.5s, during which the clock is
                    // deliberately pinned at zero) and the preroll — a budget a
                    // slow debrid link plus a fussy panel can genuinely exceed,
                    // failing over a session that was opening normally.
                    self.markLoadStarted()
                    // Report what the ENGINE found in the stream itself, not
                    // the preflight's guess — and name a converted P7 as the
                    // conversion it is, the same honesty the remux path kept.
                    let realProfile = engine.detectedDVProfile > 0 ? engine.detectedDVProfile : profile
                    let dvLabel: String
                    if engine.forceHDR10 {
                        dvLabel = p7BaseLayerForAudio
                            ? "Native HDR10 (P7 base layer — kept the Dolby audio bitstream)"
                            : "Native HDR10 (P7 FEL base layer, direct sample feed)"
                    } else {
                    switch realProfile {
                    case 0: dvLabel = "Native \(probe.isPQ ? "HDR10\(probe.hasHDR10Plus ? "+" : "")" : engine.videoCodecName) (direct sample feed)"
                    case 7: dvLabel = "Native DV (direct sample feed, Profile 7 → 8.1)"
                    default: dvLabel = "Native DV (direct sample feed, Profile \(realProfile))"
                    }
                    }
                    self.decisionLog.record("Dolby Vision", dvLabel,
                                            because: "compressed samples fed straight to the display pipeline — no remux, no server")
                    self.decisionLog.record("Engine", "DV Sample Feed",
                                            because: "AVSampleBufferDisplayLayer owns rendering for this session")
                    // The audio verdict for the one engine that can bitstream
                    // Dolby. `audioPath.summary` is deliberately blunt about
                    // the decode case, including that a TrueHD track's Atmos
                    // objects are gone — this is where a session that LOOKS
                    // like Atmos and isn't has to say so.
                    let audioPath = engine.audioPath
                    self.decisionLog.record(
                        "Dolby Audio",
                        audioPath.passthrough ? "Bitstream to tvOS" : "Decoded to PCM in-app",
                        because: audioPath.summary
                    )
                    // Remember the title as engine-capable from the engine's
                    // own success — the only claim that can't be wrong,
                    // because it just happened. This is how an H.264 title
                    // learns: `noteDolbyCapability` stays HEVC-only on
                    // purpose, since a track list can't see Annex-B extradata
                    // or interlacing, and a wrong positive there would buy a
                    // doomed probe + engine attempt on every future play.
                    let lower = audioPath.codec.lowercased()
                    if audioPath.passthrough, lower == "eac3" || lower == "ac3" {
                        DolbyMemory.remember(self.meta.id)
                    }
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
                    // Orivio probe: the direct engine has no KSOptions hook, so
                    // without this a native session says nothing about the
                    // display at all. An SDR title asks for NOTHING here — so
                    // if an earlier title pinned the panel into DV/HDR, this is
                    // where that goes unnoticed.
                    PlayerViewModel.colorTrail(
                        "display gate (direct) profile=\(profile) isPQ=\(probe.isPQ)"
                            + " forceHDR10=\(engine.forceHDR10) fps=\(engine.videoFPS)"
                            + " will request=\(profile > 0 && !engine.forceHDR10 ? "DolbyVision" : (probe.isPQ ? "HDR10" : "NOTHING"))"
                            + " panelNow=\(UIScreen.main.maximumFramesPerSecond)fps"
                            + " pin=\(SessionDisplayMode.pinDescription)"
                            + " panelSupports=[\(DynamicRange.availableHDRModes.map(\.description).joined(separator: ","))]"
                    )
                    // DEBUG A/B (`-dvDisplayHDR10` launch argument): ask for the HDR10
                    // mode instead of Dolby Vision. With decode-ahead on, the layer is
                    // handed finished PQ pixel buffers rather than dvh1 samples, so the
                    // question is whether the TV's DV mode — fed pixels with no per-scene
                    // DV metadata — is what makes the picture dark.
                    #if DEBUG
                    let debugForceHDR10Display = ProcessInfo.processInfo.arguments.contains("-dvDisplayHDR10")
                    #else
                    let debugForceHDR10Display = false
                    #endif
                    if debugForceHDR10Display {
                        PlayerProbe.event("dv", "DEBUG -dvDisplayHDR10: requesting HDR10 instead of Dolby Vision")
                    }
                    if profile > 0, !engine.forceHDR10, !debugForceHDR10Display {
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
                            // 12 polls (3s), not 24. This loop can only ever
                            // succeed when `maximumFramesPerSecond` CHANGES —
                            // and with tvOS Match Content set to Dynamic Range
                            // but not Frame Rate (a common setup, and this app's
                            // own default for matchFrameRate), it never does. So
                            // a range-only switch that completed in under a
                            // second burned the full six seconds here and then
                            // the quiet beat below: eight and a half seconds of
                            // black screen for nothing. A switch that has not
                            // registered within three seconds never will.
                            var stable = 0
                            var last = before
                            var rateChanged = false
                            for _ in 0 ..< 12 {   // up to 3s
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                let now = UIScreen.main.maximumFramesPerSecond
                                if now != before { rateChanged = true }
                                if now != before, now == last { stable += 1 } else { stable = 0 }
                                last = now
                                if stable >= 3 { break }
                            }
                            // The 2.5s beat is deliberate margin for HDMI link
                            // training, and it stays exactly as it was whenever
                            // a REFRESH RATE change actually happened — that is
                            // the renegotiation that produced the grey-screen
                            // wedge this margin exists for.
                            //
                            // When the rate never moved, no such renegotiation
                            // took place: either only the dynamic range changed
                            // (which the panel handles in-band) or the pin was
                            // already correct. Waiting the full margin there was
                            // buying safety against something that did not
                            // occur, and it is the common case, because this
                            // app's own `matchFrameRate` default is off.
                            let beat: UInt64 = rateChanged ? 2_500_000_000 : 600_000_000
                            try? await Task.sleep(nanoseconds: beat)
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
                    // Experimental: hand the E-AC-3 audio to AVPlayer so the
                    // receiver gets real Atmos (see AtmosHLS.swift). No-op
                    // unless the setting is on and the route is HDMI.
                    self.startAtmosPassthroughIfEligible(engine: engine, entry: entry, resume: resume)
                } else {
                    Self.dvTrail("direct engine declined (\(reason)) — FFmpeg reload")
                    // A shape verdict, not a transient: every H.264 gate
                    // reason names the codec ("Annex B", "interlaced",
                    // "anamorphic", the audio rule). The header probe cannot
                    // see any of those, so this is the only place the negative
                    // can be learned — without it the title would re-pay probe
                    // + engine open + fallback on every play. Network/open
                    // failures don't match and stay retryable.
                    if audioOnly, reason.contains("H.264") {
                        DolbyMemory.rememberDeclined(self.meta.id)
                    }
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
        // CAPTURE THE PLAYHEAD FIRST, as every other reload path does.
        //
        // This was the one that did not, and on a DV-direct session all three
        // carriers are gone by the time a mid-film failure lands: `load()`
        // zeroes `position`, the direct engine clears `pendingResume` the
        // moment it reports progress, and nothing on the DV path ever writes
        // `sessionResumeFloor`. So an hour into a Dolby Vision film, one engine
        // error restarted it at 00:00 — and the throttled saves then wrote that
        // zero over Continue Watching, losing the viewer's place for good.
        // Recording it in the floor too means a later failover inherits it.
        let resumeAt = resumeTargetForReload
        if resumeAt > 10 {
            sessionResumeFloor = max(sessionResumeFloor, resumeAt)
            pendingResume = resumeAt
        }
        dvDirectEngine?.stop()
        dvDirectEngine = nil
        videoRefreshID = UUID()   // detach the dead engine's layer view
        if profile > 0 {
            decisionLog.record("Dolby Vision", nativeFallbackLabel,
                               because: "direct sample feed declined: \(reason)")
        }
        load(entry: entry)
        // The stream is on the KSPlayer path now, so the styled-ASS / HDR10+
        // probe the DV-first attempt deferred can run.
        runStreamProbe()
    }

    /// A DV-first preflight is running for the current load (the direct
    /// engine is not assigned until its header probe completes).
    private var hasDVFirstAttemptInFlight: Bool {
        guard let task = dvFirstTask else { return false }
        return !task.isCancelled && playerLayer == nil && vlcEngine == nil
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
        // Range-only by default: keep the panel's current rate so the request
        // does not trigger the 60↔24 HDMI renegotiation that wedges grey
        // panels. Only switch the rate when the viewer opted into
        // "Match frame rate".
        if self.settings.matchFrameRate, SessionDisplayMode.isPlausibleRate(fps) {
            rate = SessionDisplayMode.snapToBroadcastRate(fps)
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
        if SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate,
                                        range: target.rawValue) {
            displayCriteriaApplied = true
            return true
        }
        return false
    }

    /// HDR10-range request for non-DV direct sessions, same pin discipline.
    @discardableResult
    private func requestHDR10DisplayMode(fps: Float) -> Bool {
        // NO APP-LEVEL TOGGLE ANY MORE. The Apple TV's own Video and Audio →
        // Match Content is the switch, and it is exactly what
        // `isDisplayCriteriaMatchingEnabled` reports — so the app simply
        // honours the system setting instead of gating it behind a second one
        // that could disagree with it.
        guard let displayManager = UIApplication.shared.ks_keyWindow?.avDisplayManager,
              displayManager.isDisplayCriteriaMatchingEnabled else { return false }
        var rate = Float(UIScreen.main.maximumFramesPerSecond)
        // Range-only by default: keep the panel's current rate so the request
        // does not trigger the 60↔24 HDMI renegotiation that wedges grey
        // panels. Only switch the rate when the viewer opted into
        // "Match frame rate".
        if self.settings.matchFrameRate, SessionDisplayMode.isPlausibleRate(fps) {
            rate = SessionDisplayMode.snapToBroadcastRate(fps)
        }
        guard DynamicRange.availableHDRModes.contains(.hdr10),
              let criteria = AVDisplayCriteria(
                refreshRate: rate, videoDynamicRange: DynamicRange.hdr10.rawValue
              ) else { return false }
        if SessionDisplayMode.applyOnce(criteria, via: displayManager, rate: rate,
                                        range: DynamicRange.hdr10.rawValue) {
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
    /// `nonisolated`: the trail is written from the demux and decode threads
    /// as well as from main (that is most of what makes it useful), and these
    /// are immutable constants. Left main-actor-isolated by the class, every
    /// off-main use was a warning today and a hard error under Swift 6.
    nonisolated private static let maxTrailEntryChars = 400
    nonisolated private static let maxTrailBytes = 16 * 1024

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
    nonisolated private static let trailQueue = DispatchQueue(label: "orivio.dvtrail", qos: .utility)

    /// The colour-pipeline trail. Its own key rather than a share of the DV
    /// trail: the colour probe emits a dozen lines per load and would push the
    /// DV diagnostics straight out of their 30-entry window.
    ///
    /// Cleared at the start of every load, so what is on the device is always
    /// the LAST session — pull `dev.colorTrail` from the app container after
    /// watching a title that looked wrong.
    nonisolated static func colorTrail(_ line: String) {
        NSLog("[OrivioColor] %@", line)
        let entry = String(line.prefix(maxTrailEntryChars))
        trailQueue.async {
            var trail = UserDefaults.standard.stringArray(forKey: "dev.colorTrail") ?? []
            trail.append(entry)
            if trail.count > 40 { trail.removeFirst(trail.count - 40) }
            UserDefaults.standard.set(trail, forKey: "dev.colorTrail")
        }
    }

    /// Last URL a colour trail was started for, so the DV-first preflight and
    /// the `load()` it falls back to share ONE trail instead of the second
    /// wiping the first's findings.
    private static var colorTrailURL: String?

    /// Start (or continue) the colour trail for `url`, and make sure KSPlayer's
    /// own probes have somewhere to go. Clears only when the title changes.
    static func beginColorTrail(for url: String, _ header: String) {
        KSColorProbe.sink = { PlayerViewModel.colorTrail($0) }
        // The hybrid-cache proxy swaps the stream URL for a localhost one —
        // same title, same session. Treating that swap as a new title cleared
        // the trail mid-load, wiping the load header and the cache decision
        // from the very trail that was investigating them.
        guard colorTrailURL != url, !url.hasPrefix("http://127.0.0.1") else {
            colorTrail(header)
            return
        }
        colorTrailURL = url
        KSColorProbe.reset()
        trailQueue.async {
            UserDefaults.standard.set([String](), forKey: "dev.colorTrail")
        }
        colorTrail(header)
    }

    static func dvTrail(_ line: String) {
        // …and to the live probe. The trail holds every DV / engine-tier
        // DECISION — which path was chosen, why a fallback fired, what the
        // display handshake did — and until now the only way to read it during
        // a session was a console-attached device, which is the setup the
        // probe exists to replace. The UserDefaults copy is capped at 30
        // entries, so it also loses the early decisions of any long session.
        PlayerProbe.event("dv", line)
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
    /// Drop this session's probe samplers. Called from `prepareForExit` so a
    /// dismissed player is never kept alive by the registry.
    private func unregisterProbes() {
        for name in ["player", "scrub", "previews", "tracks", "dv", "engine", "input"] {
            PlayerProbe.unregister(name)
        }
    }

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
        // The embedded-subtitle infos belong to the engine just stopped. Kept,
        // a DV→DV episode advance dedups the next engine's "dvsub-N" ids
        // against these and the picker keeps the previous episode's cues.
        dvEmbeddedSubs = []
        dvActiveEmbeddedSub = nil
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
    /// An episode switch has been asked for and has not yet produced a stream.
    ///
    /// The window is longer than it looks: `play(episode:)` clears
    /// `autoAdvanceArmed` immediately and then fetches sources over the
    /// network for SECONDS, during which `currentVideo` is still the OUTGOING
    /// episode and `position` / `duration` still hold its end-of-file values.
    /// So the very next 10 Hz clock tick re-armed the card for the same
    /// episode and advanced AGAIN, on top of the load already running — the
    /// Up Next banner reappearing and retrying while a perfectly good source
    /// was still opening. Cleared when a stream actually opens
    /// (`markLoadStarted`) or when the retry ladder below gives up.
    private var advanceInFlight = false
    /// Which episode the ladder is trying to start, and how many attempts it
    /// has spent. Deliberately bounded: two retries, then the error card.
    private var advanceTarget: MetaVideo?
    private var advanceAttempt = 0
    private var advanceRetryTask: Task<Void, Never>?
    /// Waits spent because the source fetch had not returned yet. Bounded so a
    /// hung fetch cannot hold the ladder open indefinitely.
    private var advanceDeferrals = 0
    private static let maxAdvanceDeferrals = 3
    /// Wait before the first retry, then before the second. Spaced rather than
    /// immediate because the thing being retried is a stream that is usually
    /// still opening — a debrid link can legitimately take ten seconds — and
    /// restarting it instantly only guarantees it never finishes.
    private static let advanceRetryDelays: [UInt64] = [7, 10]
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
    private var toastTask: Task<Void, Never>?
    private var lastProgressSave = Date.distantPast
    private var transientSaveCount = 0
    /// The episode `play(episode:)` is moving to, from the moment the outgoing
    /// episode's progress is settled (saved, or retired as finished) until that
    /// episode's own stream starts loading. Every progress save waits it out.
    ///
    /// In that window `currentVideo`, `position` and `duration` do not describe
    /// one episode. The source lookup runs with the OUTGOING episode still
    /// current, so a save — the exit's, or a periodic tick — wrote the episode
    /// just retired straight back into Continue Watching as its newest row, and
    /// the card went back to the episode the viewer had moved on from. After
    /// the lookup, a debrid resolve or an opened source list leaves the NEW
    /// episode current over the outgoing stream's clock, so a save recorded it
    /// at the old episode's position — or, past 95%, marked it watched.
    private var episodeSwitchTargetID: String?
    /// The exit retired this episode as finished (see `prepareForExit`). The
    /// teardown's save runs after it and would write the row straight back at
    /// its credits-time position.
    private var retiredEpisodeOnExit = false
    /// Seconds between periodic crash-safety progress writes.
    /// 10s: the worst-case loss on a crash. The Apple TV HD's two A8 cores
    /// are often SOFTWARE-decoding the stream this runs alongside, and each
    /// save JSON-encodes the whole history (thousands of rows on a long-lived
    /// install) — 20s there halves that CPU for a loss bound nobody notices.
    private static let progressSaveInterval: TimeInterval = PerformanceProfile.isLowPower ? 20 : 10
    private var lastSubtitleSearchAt: Double = -1
    private var pendingResume: Double?
    /// Where this session picked the film up, so the exit can tell a viewer who
    /// watched from one who bailed out.
    private var sessionStartPosition: Double = 0
    /// Set from `PlaybackRequest.forceDemuxer` — see that field. A live
    /// channel on rtmp/rtsp/udp or a DASH manifest has no native path.
    private var forceDemuxerForSession = false
    /// Options of the stream currently loading, kept for open-timing logs.
    private var currentOptions: KSOptions?
    /// Why the current playback path looks the way it does — shown in the
    /// pull-down info panel. Reset at every load.
    private(set) var decisionLog = PlaybackDecisionLog()
    /// The active policy, read once per load so a mid-playback settings edit
    /// can't leave the session half in one mode and half in another.
    private(set) var activeMode: PlaybackMode = .automatic
    private var loadStartedAt: Date?
    /// When this player session was constructed. `loadStartedAt` is per-LOAD
    /// (and is cleared once the open times are logged), so it cannot answer the
    /// question a viewer actually asks — "how long from pressing Play to seeing
    /// a picture?" — across a failover or an engine swap. This can.
    private let sessionOpenedAt = Date()
    private var currentURL: URL?

    // Scrub preview thumbnails, generated in the background over a separate
    // FFmpeg context once playback is underway (Infuse builds its previews the
    // same way). Sorted by time; the scrub HUD picks the nearest frame.
    // NOT @Published: no view reads the array itself — the scene window calls
    // `thumbnail(at:)` and refreshes off `clock.previewsRevision` (see
    // PlaybackClock), so a partial merge no longer re-renders the whole
    // PlayerScreen at decode rate.
    private(set) var scrubThumbnails: [ScrubThumbnail] = [] {
        didSet { clock.previewsRevision &+= 1 }
    }
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
    /// This load is going back to a saved position, so the loading screen can
    /// say "Resuming…" — a wait the viewer already has a reason for reads as
    /// shorter than the same wait labelled generically.
    var isResumingFromSavedPosition: Bool { (pendingResume ?? 0) > 10 }
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
        // PRESENT ON THE PANEL'S OWN VSYNC, not on a rate the panel does not
        // have. This is the frame-pacing fix, and it is the reason 24p content
        // juddered all the way through a film.
        //
        // The FFmpeg engine has no frame scheduler: `MetalPlayView` enqueues
        // every picture with `presentationTimeStamp: .zero` and
        // `kCMSampleAttachmentKey_DisplayImmediately`, so a frame appears when
        // the display-link callback runs and at no other time — the callback
        // cadence IS the on-screen cadence. With `preferredFrame` on, KSPlayer
        // asks that link for `CAFrameRateRange(min: fps, max: 2*fps,
        // preferred: fps)` — a preferred 24Hz. A 60Hz panel can only deliver
        // 60/N, so the request lands on 30Hz, and 23.976fps content is then
        // presented on a 30Hz grid: every frame held for one tick or two,
        // 33ms/67ms/33ms, instead of the even 2:3 pattern 24p on 60Hz is
        // supposed to have. That irregularity is the stutter, it is
        // content-independent, and no amount of buffering can hide it.
        //
        // Off, the link runs at the panel's native vsync, `videoClockSync` is
        // asked 60 times a second instead of 30, and each frame goes up on the
        // vsync it is actually due — the correct 2:3 cadence falls out of the
        // existing gate with no scheduling code at all.
        //
        // It also restores the CATCH-UP HEADROOM the 30Hz link removed. A gate
        // that can only present 30 frames a second cannot outrun a 24fps
        // decoder by much, and once the decoded queue is empty it cannot outrun
        // it at all — which is why a session that started life a little behind
        // stayed exactly that far behind for hours (measured: avSync pinned at
        // −0.15s). At 60Hz the gate can present consecutive frames until the
        // picture is level with the audio again.
        KSOptions.preferredFrame = false
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
        // The HD cap was 6s — tighter than its memory needs (a 1080p H.264
        // link at 8 Mb/s is ~12 MB for 12s) and short enough that the older
        // Wi-Fi on that box hit KSPlayer's stop-and-go on every jitter burst.
        // 4K links (which the HD cannot play well anyway) stay bounded by
        // `maxBufferBytes`.
        KSOptions.maxBufferDuration = PerformanceProfile.isLowPower ? 12
            : (PerformanceProfile.isMidPower ? 12 : 45)
        // Decode off the render thread: the synchronous path stalls the video
        // loop under heavy 4K content on the A10X (the "jumpy" playback).
        KSOptions.asynchronousDecompression = true
        KSOptions.hardwareDecode = true
        // ACCURATE seeks. Keyframe-only seeks looked "near-instant" but were
        // the visible-jump bug: the demuxer lands on the keyframe AT OR
        // BEFORE the target (backward flag), and with accurate seek off the
        // per-track trim never runs — every frame from that keyframe was
        // DECODED AND SHOWN, so a −10s skip (or the resume rewind) visibly
        // replayed up to a whole GOP (5–10s on web encodes) and then chopped
        // forward to catch the audio clock ("the +10/−10 does the jumping").
        // Accurate seek decodes the same frames but discards them until the
        // target: the picture holds, then cuts cleanly. With the hybrid cache
        // the decode-forward reads from local disk; even over the network the
        // GOP is at most a few seconds of hardware decode.
        KSOptions.isAccurateSeek = true
        // KSPlayer stamps this font onto every text cue, overriding whatever
        // the SwiftUI overlay styles — its tvOS default is a billboard-sized
        // 58pt. Overridden per-session from PlayerSettings in init.
        SubtitleModel.textFontSize = 36
        SubtitleModel.textBold = false
    }

    /// Mirrors "Show unaired next up" (Settings → Layout). Passed in rather than
    /// read from a store because the player owns no layout-settings dependency.
    private let allowUnairedNextUp: Bool
    /// See `PlaybackRequest.directEpisodeResolver`.
    private let directEpisodeResolver: ((MetaVideo) async -> StreamEntry?)?

    init(
        request: PlaybackRequest,
        addonManager: AddonManager,
        progressStore: ProgressStore,
        settings: PlayerSettings = .default,
        allowUnairedNextUp: Bool = true
    ) {
        Self.liveInstanceCounter.mutate { $0 += 1 }
        // Hand the poster cache's RAM back before the player allocates its
        // own. See ImageCache.dropDecoded().
        ImageCache.shared.dropDecoded()
        self.allowUnairedNextUp = allowUnairedNextUp
        self.directEpisodeResolver = request.directEpisodeResolver
        self.meta = request.meta
        self.currentVideo = request.video
        self.currentEntry = request.entry
        self.allEntries = request.allEntries
        self.addonManager = addonManager
        self.progressStore = progressStore
        self.settings = settings
        self.pendingResume = request.resumePosition
        self.sessionStartPosition = request.resumePosition ?? 0
        self.forceDemuxerForSession = request.forceDemuxer

        // Pause the 30s account auto-sync for the duration of playback — a
        // multi-endpoint sync competing for bandwidth mid-stream is exactly the
        // wrong time on a high-bitrate remux.
        OrivioSyncManager.playbackActive = true
        // Newest session takes over the process-wide state (see
        // sharedStateOwner) — an older one parked in Picture in Picture must
        // not reset these globals out from under this load.
        Self.sharedStateOwner = self
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
        selectAudioOutput()
        // `didSet` does not run for the assignments an initializer makes, so
        // the launch episode's neighbour has to be looked up by hand once.
        // (A session launched from Continue Watching usually has no episode
        // list yet; `fetchEnrichedMeta` below brings one and refreshes this.)
        refreshNextEpisodeAvailability()
        fetchEnrichedMeta()
        configureWheelTracking()
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureWheelTracking() }
        })
        registerLifecycleObservers()
        // Let the global display re-sync (triple-press gesture OR the remote
        // command from the Mac) put THIS session's HDR/DV mode back when it
        // fires while a player is open. Weak, so a retired session contributes
        // nothing; the next load overwrites it.
        DisplayResync.sessionTarget = { [weak self] in self?.recoveredDisplayCriteria() }
        // NB: the idle timer is managed by `isPlaying` (kept awake only while
        // actually playing) — NOT disabled for the whole session, which used
        // to leave the Apple TV never sleeping / never showing its screensaver.
        // Replay this title's remembered choices before the first load, so a
        // file that needed VLC (or 1.5x, or French audio) last time starts
        // that way now. Only user-made choices are stored, so replaying them
        // is doing what the user already asked for.
        if let memory = PlaybackMemory.memory(for: request.meta.id) {
            if let speed = memory.speed { playbackSpeed = speed }
            if let offset = memory.audioSyncOffset { audioSyncOffset = offset }
            if settings.playerEngine == .auto, let raw = memory.engine,
               let engine = PlayerEngine(rawValue: raw), engine != .auto {
                sessionEngine = engine
                decisionLog.record("Engine", engine.label,
                                   because: "you switched this title to it last time")
            }
        }
        registerProbes()
        // Warm the content-rating lookup NOW, not when the info panel mounts.
        // It is a TMDB round-trip behind a cache, and asking for it only as the
        // sheet appears means the badge lands mid-animation — the rating
        // popping in as the panel comes down. Prefetching costs one request the
        // panel would have made anyway, and by the time it is pulled down the
        // answer is already cached.
        let ratingMeta = request.meta
        if ratingMeta.type != "collection" {
            Task { [weak self] in
                let value = await TMDBService.contentRating(imdbID: ratingMeta.id,
                                                            type: ratingMeta.type)
                await MainActor.run { self?.contentRating = value }
            }
        }
        load(entry: request.entry)
        runStreamProbe()
    }

    // MARK: - Live probe (dev)

    /// Publish this session's LEVELS to the probe server (`:8123/live`).
    ///
    /// Levels, not events: position, transport state, what the scrubber is
    /// pointing at, how many preview frames exist, which tracks are selected.
    /// Sampled when a reader asks, so nothing here costs anything while
    /// nobody is watching.
    private func registerProbes() {
        // One player session = one health block. Counters that carried over
        // from the last title would make every number a lie about this one.
        PlayerProbe.resetHealth()
        PlayerProbe.event("session", "OPEN \(meta.name) — \(currentEntry.addonName)"
            + " / \(currentEntry.displayName.prefix(70))")
        PlayerProbe.note("title", meta.name)
        PlayerProbe.register("player") { [weak self] in
            guard let self else { return [] }
            return [
                String(format: "pos=%.1f/%.1f playing=%@ buffering=%@ pauseIntent=%@ started=%@",
                       self.position, self.duration, self.isPlaying.probe,
                       self.isBuffering.probe, self.pauseIntent.probe,
                       self.hasStartedPlayback.probe),
                "engine=\(self.engineLabelForProbe) overlay=\(self.overlay.probeName)"
                    + " loadPhase=\(self.loadPhase.map(String.init(describing:)) ?? "-")"
                    + " switching=\(self.isSwitchingSource.probe)",
                "source=\(self.currentEntry.addonName) — \(self.currentEntry.displayName.prefix(60))",
                // The EFFECTIVE values, not the defaults: a setting persisted
                // before the default changed still wins, and "the countdown
                // isn't 10 seconds" is indistinguishable from "the default
                // didn't reach this install" without printing what is actually
                // in force.
                "upNextTimeout=\(self.settings.autoPlayTimeoutSeconds)s"
                    + " autoPlayNext=\(self.settings.autoPlayNextEpisode.probe)"
                    + " autoLink=\(self.autoLinkPrefs.enabled.probe)"
                    + " addons=\(self.advanceAddonAllowList.isEmpty ? "any" : self.advanceAddonAllowList.joined(separator: "/"))",
            ]
        }
        PlayerProbe.register("scrub") { [weak self] in
            guard let self else { return [] }
            return [
                String(format: "scrubbing=%@ target=%@ wheel=%@ pendingNudge=%.1f",
                       self.isScrubbing.probe,
                       self.clock.scrubTarget.map { String(format: "%.1f", $0) } ?? "-",
                       self.wheelEngaged.probe, self.pendingSeekDelta),
                "focusOnBar=\(self.controlsFocusOnBar.probe)"
                    + " skipIntro=\(self.skipIntroActive.probe)",
                // Frame damage, so "the picture goes choppy when the bar comes
                // up" is a number rather than an impression. `r` = repeated
                // frames, `s` = skipped: either one is visible judder.
                "overlay=\(String(describing: self.overlay))"
                    + " \(self.dvDirectEngine?.lastVsyncCensus ?? "vsync n/a")",
            ]
        }
        PlayerProbe.register("previews") { [weak self] in
            guard let self else { return [] }
            let lead = MediaCacheServer.shared.readerLeadSeconds
            return [
                "coarse=\(self.scrubThumbnails.count) fine=\(self.fineThumbnails.count)"
                    + " started=\(self.thumbnailsStartedForProbe.probe)"
                    + " enabled=\(self.settings.scrubPreviewsEnabled.probe)",
                String(format: "cacheLead=%.0fs (gate %.0fs → %@) fineCentre=%@",
                       lead, Self.previewLeadGate,
                       lead >= Self.previewLeadGate ? "PASSING" : "BLOCKED",
                       self.fineCentreForProbe.map { String(format: "%.0f", $0) } ?? "-"),
                // The SECOND gate, and the one that was silently shut on every
                // DV session — `shouldProceed` refuses to decode a frame below
                // 8s of engine buffer, and `buffered` was never written outside
                // the KSPlayer path.
                String(format: "engineBuffer=%.1fs ahead (gate %.1fs → %@)",
                       self.bufferAhead.wrappedValue, self.previewBufferGate,
                       self.bufferAhead.wrappedValue >= self.previewBufferGate
                           ? "PASSING" : "BLOCKED"),
                "windowAt=\(self.clock.scrubTarget.map { String(format: "%.0f", $0) } ?? "-")"
                    + " hasFrame=\((self.thumbnail(at: self.clock.scrubTarget ?? self.position) != nil).probe)",
            ]
        }
        // The direct DV engine's own live state — see DVSampleEngine.probeLines.
        // Registered unconditionally and self-skipping: the engine is created
        // partway through a load, so a registration gated on its existence at
        // init would never fire for the sessions that need it most.
        PlayerProbe.register("dv") { [weak self] in
            guard let engine = self?.dvDirectEngine else { return [] }
            return engine.probeLines
        }
        // The KSPlayer/VLC side of the same question. `seekable` in particular
        // silently decides whether a resume, a scrub commit or a chapter jump
        // does anything at all.
        PlayerProbe.register("engine") { [weak self] in
            guard let self else { return [] }
            var lines: [String] = [
                "name=\(self.engineName) vlc=\(self.usingVLC.probe) dv=\(self.usingDVDirect.probe)"
                    + " switching=\(self.isSwitchingSource.probe) failingOver=\(self.isFailingOver.probe)"
                    + " exiting=\(self.isExiting.probe) resyncing=\(self.isResyncing.probe)",
            ]
            if let player = self.playerLayer?.player {
                lines.append(String(
                    format: "ks: playable=%.1f seekable=%@ natural=%.0fx%.0f rate=%.2f",
                    player.playableTime, player.seekable.probe,
                    player.naturalSize.width, player.naturalSize.height,
                    player.playbackRate))
                // The picture-quality numbers the diagnostics HUD shows, which
                // until now could only be read by standing in front of the TV
                // with the HUD switched on. `droppedFrames` climbing and
                // `avSync` drifting are the two measurements that separate "the
                // stream is bad" from "the decode can't keep up".
                if let info = player.dynamicInfo {
                    lines.append(String(
                        format: "ks: fps=%.1f dropped=%d avSync=%+.2fs bitrate=%.1fMbps read=%.0fMB",
                        info.displayFPS, info.droppedVideoFrameCount,
                        info.audioVideoSyncDiff,
                        Double(info.videoBitrate) / 1_000_000,
                        Double(info.bytesRead) / 1_048_576))
                }
                // The A/V sync servo's own view: decoded-queue depth (the hard
                // limit on any catch-up), how often it wanted to correct, and
                // how often it could. `avSync` above says the picture is late;
                // this says whether anything is able to do something about it.
                if let opts = self.currentOptions as? OrivioPlayerOptions {
                    lines.append("ks: " + opts.syncProbeLine)
                }
            }
            // EVERY input to the picture transform, not just the mode. A
            // report of the picture zooming has three possible causes here —
            // the zoom mode, a forced aspect ratio, a vertical shift — and
            // `aspectMode` alone (which is what this line used to print) says
            // `fit` in all three, which is exactly as useful as printing
            // nothing.
            lines.append("aspect=\(self.aspectMode)"
                + " forcedAspect=\(self.aspectRatioOverride.map { String(format: "%.3f", $0) } ?? "-")"
                + " shift=\(self.verticalShift)"
                + String(format: " natural=%.0fx%.0f", self.videoNaturalSize.width,
                         self.videoNaturalSize.height))
            lines.append("speed=\(self.playbackSpeed)"
                + String(format: " subDelay=%.1f", self.subtitleDelay))
            return lines
        }
        // Gesture state. "The remote stopped working" is nearly always one of
        // these latched the wrong way — a pan that never ended, a suppression
        // window that never expired, focus parked somewhere invisible.
        PlayerProbe.register("input") { [weak self] in
            guard let self else { return [] }
            return [
                "moveSuppressed=\(self.moveSuppressed.probe)"
                    + " wheelEngaged=\(self.wheelEngaged.probe)"
                    + " scrubbing=\(self.isScrubbing.probe)"
                    + " acceptsTransport=\(self.acceptsTransportInput.probe)",
                "skipIntroActive=\(self.skipIntroActive.probe)"
                    + " skipIntroFocused=\(self.skipIntroFocused.probe)"
                    + " focusOnBar=\(self.controlsFocusOnBar.probe)"
                    + " sheetClosing=\(self.sheetClosing.probe)",
                "lastInput: \(self.inputDebug.isEmpty ? "-" : self.inputDebug)",
            ]
        }
        PlayerProbe.register("tracks") { [weak self] in
            guard let self else { return [] }
            let audio = self.audioOptions.first { $0.id == self.selectedAudioID }?.displayName ?? "-"
            let subtitle = self.subtitleOptions.first { $0.id == self.selectedSubtitleID }?.displayName ?? "-"
            let remembered = PlaybackMemory.memory(for: self.meta.id)?.audioLanguage ?? "-"
            return [
                "audio=\(audio)  (\(self.audioOptions.count) tracks)",
                "subtitle=\(subtitle)  (\(self.subtitleOptions.count) options)",
                "wantAudio: remembered=\(remembered) setting=\(self.settings.preferredAudioLanguage.isEmpty ? "-" : self.settings.preferredAudioLanguage)",
            ]
        }
        // The Atmos answer, in one block: what the source is, what this app is
        // doing with it, and what the route can take. Built so the PCM case is
        // impossible to mistake for a working Dolby one.
        PlayerProbe.register("atmos") { [weak self] in
            guard let self else { return [] }
            return self.atmosDiagnostics
        }
        // The HDR/DV picture side: what the panel is in, what it can take, and
        // whether the Apple TV is configured to match content at all. This is
        // the block to read for "why is this movie dark" — see the gate event.
        PlayerProbe.register("display") { [weak self] in
            guard let self else { return [] }
            let manager = UIApplication.shared.ks_keyWindow?.avDisplayManager
            var lines = [
                "matchContent=\(manager?.isDisplayCriteriaMatchingEnabled.probe ?? "?")"
                    + " panelNow=\(UIScreen.main.maximumFramesPerSecond)fps"
                    + " supports=[\(DynamicRange.availableHDRModes.map(\.description).joined(separator: ","))]",
                "pin=\(SessionDisplayMode.pinDescription)",
            ]
            if let opts = self.currentOptions as? OrivioPlayerOptions {
                lines.append("nativeDV=\(opts.nativeDV.probe) matchFrameRate=\(opts.matchFrameRate.probe)"
                    + " contentVideoRange=\(self.currentVideoDynamicRangeProbe)")
            }
            return lines
        }
    }

    /// Best-effort current video dynamic range for the `[display]` block.
    var currentVideoDynamicRangeProbe: String {
        if let track = playerLayer?.player.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? playerLayer?.player.tracks(mediaType: .video).first,
           let range = track.dynamicRange {
            return range.description
        }
        return dvDirectIsPQ ? "HDR10 (DV-direct PQ)" : "-"
    }

    /// What the audio pipeline is actually doing, gathered ONCE.
    ///
    /// Both readers render from this: the `[atmos]` probe block and the info
    /// panel's Audio tab. They used to be two hand-maintained lists of the same
    /// facts, which is how a panel and a log start disagreeing — and then one of
    /// them is lying about the thing this whole feature exists to answer.
    struct AudioPipelineFacts {
        var engine = "-"
        /// The source codec as the engine names it ("eac3", "Dolby Digital+ Atmos").
        var codec = "-"
        /// 0 when unknown.
        var channels = 0
        var sampleRate = 0
        /// The CONTAINER says Atmos. Metadata only — never a claim about what
        /// the receiver is decoding. See `DVSampleEngine.streamSaysAtmos`.
        var sourceSaysAtmos = false
        /// This app is not decoding the audio.
        ///
        /// Kept separate from `dolbyBitstream` on purpose: AAC passes through
        /// untouched and is not Dolby, and conflating the two would be the
        /// "PCM labelled Atmos" mistake in reverse.
        var passthrough = false
        /// What leaves the app is Dolby a receiver can decode.
        var dolbyBitstream = false
        /// Multichannel folded to 2ch inside the app (decode path only).
        var downmixedInApp = false
        var decoder = "-"
        var routeIsMultichannel = false
        var routeMaxChannels = 2
        var routeDescription = "-"

        // MARK: Derived

        /// THE ROUTE'S CHANNEL COUNT DOES NOT GATE A BITSTREAM.
        ///
        /// E-AC-3 JOC Atmos tunnels through a TWO-channel MAT carrier, so a
        /// perfectly working Atmos chain can report
        /// `maximumOutputNumberOfChannels == 2`. `outputNumberOfChannels` is the
        /// LPCM limit, and an encoded bitstream is not LPCM. So a Dolby
        /// bitstream leaving the app IS the native path; what the receiver does
        /// with it is the receiver's business and no API on this side can see it.
        var nativeDolbyPath: Bool { dolbyBitstream }
        var pcmConversionInApp: Bool { !passthrough }

        /// The route limit DOES bite decoded multichannel PCM: a 5.1/7.1 track
        /// decoded here and handed to a 2-channel route is a real downmix, and
        /// the usual cause is an HDMI handshake that landed in stereo PCM after
        /// a reboot or a format change rather than anything in this app.
        var pcmChannelsLostToRoute: Bool {
            !passthrough && !routeIsMultichannel && channels > 2
        }

        var channelsText: String { channels > 0 ? "\(channels)" : "-" }
        var rateText: String { sampleRate > 0 ? "\(sampleRate)Hz" : "-" }

        var whyNotNative: String {
            passthrough ? "the track is not a Dolby codec tvOS can bitstream"
                        : "audio is decoded to PCM here"
        }

        /// Which physical output the route is. A Dolby bitstream can only
        /// reach a receiver over HDMI; AirPlay and Bluetooth (A2DP) cannot
        /// carry it, and tvOS decodes/re-encodes on those routes. The old
        /// wording said "→ HDMI" unconditionally, which is a lie on AirPods.
        var routeKind: String {
            let d = routeDescription.lowercased()
            if d.contains("bluetooth") { return "bluetooth" }
            if d.contains("airplay") { return "airplay" }
            if d.contains("hdmi") { return "hdmi" }
            return "other"
        }

        var verdict: String {
            guard nativeDolbyPath else { return "no — " + whyNotNative }
            if routeKind == "bluetooth" || routeKind == "airplay" {
                return "compressed Dolby leaves the app, but this route can't pass it through"
            }
            return "YES — compressed Dolby leaves the app"
        }

        var finalOutput: String {
            if nativeDolbyPath {
                switch routeKind {
                case "bluetooth":
                    return "Dolby bitstream left the app → tvOS decodes it → Bluetooth"
                        + " (A2DP is stereo; no Dolby/Atmos reaches a soundbar)"
                case "airplay":
                    return "Dolby bitstream left the app → tvOS unwraps to LPCM → AirPlay"
                        + " (no Dolby/Atmos passthrough)"
                default:
                    return "Dolby bitstream → tvOS → HDMI"
                        + " (Atmos rides a 2ch MAT carrier — the route's channel count says nothing about it)"
                }
            }
            if passthrough, routeIsMultichannel {
                return "compressed non-Dolby (\(codec)) → tvOS → HDMI"
            }
            return routeIsMultichannel ? "multichannel PCM → tvOS → HDMI"
                                       : "stereo PCM → tvOS → HDMI"
        }
    }

    /// Everything that decides whether a Dolby bitstream is reaching the
    /// receiver, from whichever engine is running.
    var audioPipelineFacts: AudioPipelineFacts {
        var facts = AudioPipelineFacts()
        facts.engine = engineLabelForProbe

        if let dv = dvDirectEngine {
            let path = dv.audioPath
            facts.codec = path.codec
            facts.channels = path.channels
            facts.sampleRate = path.sampleRate
            facts.passthrough = path.passthrough
            facts.sourceSaysAtmos = path.sourceSaysAtmos
            facts.downmixedInApp = path.downmixed
            facts.decoder = path.passthrough
                ? "none (tvOS decodes the bitstream)" : "FFmpeg → LPCM (in-app)"
            let lower = path.codec.lowercased()
            facts.dolbyBitstream = path.passthrough && (lower == "eac3" || lower == "ac3")
        } else if usingVLC {
            facts.decoder = "VLC (decodes to PCM)"
        } else if let player = playerLayer?.player {
            let native = !(player is KSMEPlayer)
            if let track = player.tracks(mediaType: .audio).first(where: { $0.isEnabled }) {
                let fmt = Self.audioFormat(track)
                facts.codec = fmt.codec ?? track.name
                facts.channels = Self.channelCount(track)
                facts.sourceSaysAtmos = (fmt.codec ?? "").localizedCaseInsensitiveContains("atmos")
                if let asbd = track.formatDescription?.audioStreamBasicDescription,
                   asbd.mSampleRate > 0 {
                    facts.sampleRate = Int(asbd.mSampleRate)
                }
                // On AVPlayer a Dolby codec is bitstreamed by tvOS itself; on
                // the FFmpeg engine the same track is decoded here.
                facts.passthrough = native && !fmt.decodedToPCM
                // "Dolby Digital" / "Dolby Digital+" are the only two
                // `audioFormat` labels tvOS bitstreams.
                facts.dolbyBitstream = facts.passthrough
                    && (fmt.codec ?? "").hasPrefix("Dolby Digital")
            }
            facts.decoder = native ? "AVPlayer / tvOS" : "FFmpeg → LPCM (in-app)"
        }

        facts.routeIsMultichannel = AudioOutputCapability.supportsMultichannel
        facts.routeMaxChannels = AudioOutputCapability.maxOutputChannels
        facts.routeDescription = AudioOutputCapability.routeDescription
        return facts
    }

    /// The `[atmos]` probe block. Wording unchanged — notes and memory refer to
    /// these exact lines.
    var atmosDiagnostics: [String] {
        let f = audioPipelineFacts
        return [
            "source codec=\(f.codec) channels=\(f.channelsText) rate=\(f.rateText)",
            "source says Atmos=\(f.sourceSaysAtmos ? "yes" : "no / not tagged")"
                + "  (the container tag OR the release name says Atmos — not a claim about output)",
            "engine=\(f.engine)  decoder=\(f.decoder)",
            "PCM conversion in-app=\(f.pcmConversionInApp ? "yes" : "no")"
                + "  downmixed here=\(f.downmixedInApp ? "yes → 2ch" : "no")",
            "transcoding/remuxing=no (this app never re-encodes audio)",
            "route: \(f.routeDescription)",
            "route LPCM limit=\(f.routeIsMultichannel ? "\(f.routeMaxChannels)ch" : "2ch (stereo)")"
                + (f.pcmChannelsLostToRoute
                   ? "  ⚠︎ this \(f.channelsText)ch PCM track WILL be downmixed by the route."
                     + " Not this app: the HDMI sink is advertising stereo."
                     + " Power-cycle the receiver, or flip Apple TV's audio format setting once, to renegotiate."
                   : ""),
            "NATIVE DOLBY PATH=" + f.verdict,
            "final output=" + f.finalOutput,
        ]
    }

    /// Read-only mirrors so the probe closures can see private per-load state
    /// without opening it up to anything else.
    private var thumbnailsStartedForProbe: Bool { thumbnailsStarted }
    private var fineCentreForProbe: Double? { fineCenter }
    private var engineLabelForProbe: String {
        if usingDVDirect { return "dv-direct" }
        if usingVLC { return "vlc" }
        return "ksplayer"
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
        // Never during a direct DV session: the engine has the container open
        // already, so this would be a THIRD concurrent connection to the same
        // file competing for bandwidth during preroll — and its styled-ASS
        // reroute would yank a DV session over to VLC and silently lose Dolby
        // Vision.
        guard !usingDVDirect else { return }
        // The direct engine is assigned only AFTER the DV-first preflight's
        // async header probe, so the guard above is always false when a load
        // calls this synchronously. A DV-first attempt in flight is the same
        // case: `fallBackFromDirect` runs the probe if the attempt declines.
        guard playerLayer != nil || !hasDVFirstAttemptInFlight else { return }
        guard effectiveEngine == .auto || effectiveEngine == .ffmpeg,
              let url = currentEntry.stream.url,
              !probedURLs.contains(url) else { return }
        let wantASS = settings.fullAssSubtitles
        // HDR10+ is only worth probing for when this box can actually output
        // it — otherwise the honest answer is already known (HDR10 base), and
        // a scan on an A10X would cost startup for nothing.
        // No user toggle any more: whether this box can output HDR10+ IS the
        // answer (3rd-gen Apple TV 4K on tvOS 18.4+). Compatibility mode still
        // opts out, since its contract is the most forgiving path.
        let wantHDR10Plus = PerformanceProfile.supportsHDR10Plus
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
            // A DV-direct session must never be rerouted to VLC for styled
            // ASS — that silently trades Dolby Vision for subtitle styling.
            guard !self.usingDVDirect, !self.hasDVFirstAttemptInFlight else { return }
            // (The `!usingNativeDV` term that used to guard this reroute went
            // with the flag. Its intent — never yank a native-DV session over
            // to VLC for the sake of subtitle styling — is carried by the
            // `usingDVDirect` / `hasDVFirstAttemptInFlight` guard immediately
            // above, together with the identical guard at the top of this
            // method. A review note here used to claim the hole was still open;
            // it isn't, and leaving that standing invites someone to "fix" a
            // guard that is already doing its job.)
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
    /// The process was SUSPENDED since the last resume, not merely paused.
    /// `resumePlayback` needs that distinction — see the proxy note there.
    private var didSuspendSincePlay = false
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

    /// The route the FFmpeg session's audio output was chosen for, so a route
    /// change can tell whether the running output is still the right one.
    private var audioOutputChosenForAirPlay = false
    /// Whether the running FFmpeg engine was opened on the sample-buffer
    /// renderer (`true`) or the realtime AVAudioEngine (`false`). KSMEPlayer
    /// snapshots the type at creation, so a route change that flips this needs
    /// a reopen.
    private var audioOutputChosenIsRenderer = false

    /// Pick the FFmpeg engine's audio output for the CURRENT route. Called
    /// before every engine open (KSMEPlayer snapshots the type at creation),
    /// not once per session as before: an output chosen for HDMI outlived a
    /// switch to AirPlay and vice versa.
    private func selectAudioOutput() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let spatialRoute = outputs.contains { $0.isSpatialAudioEnabled }
        let airPlay = outputs.contains { $0.portType == .airPlay }
        audioOutputChosenForAirPlay = airPlay
        let useRenderer = Self.wantsSampleBufferRenderer(
            outputs: outputs, settings: settings
        )
        audioOutputChosenIsRenderer = useRenderer
        // NOT "Atmos-capable". Both outputs sit at the end of the FFmpeg
        // pipeline, where `AudioSwresample` has already decoded every codec to
        // LPCM — E-AC-3 JOC included. Whichever wins here is playing
        // multichannel PCM, and calling one of them Atmos-capable is the
        // mislabel that makes a PCM session look like a working Dolby one.
        decisionLog.record(
            "Audio Route",
            useRenderer ? "Sample-buffer renderer (multichannel PCM)" : "AVAudioEngine (multichannel PCM)",
            because: airPlay
                ? "AirPlay output route — buffered renderer required"
                : settings.playbackMode == .compatibility
                    ? "Compatibility mode pins the standard engine"
                    : (useRenderer
                        ? (spatialRoute ? "output route reports spatial-audio support" : "forced in audio settings")
                        : (spatialRoute ? "forced in audio settings" : "output route has no spatial-audio support"))
        )
        KSOptions.audioPlayerType = useRenderer
            ? AudioRendererPlayer.self : AudioEnginePlayer.self
    }

    /// Does THIS route want the sample-buffer renderer? A pure function of the
    /// route and the settings, so a mid-session route change can ask the same
    /// question the open asked (see `handleAudioRouteChange`).
    private static func wantsSampleBufferRenderer(
        outputs: [AVAudioSessionPortDescription], settings: PlayerSettings
    ) -> Bool {
        let spatialRoute = outputs.contains { $0.isSpatialAudioEnabled }
        // AirPlay 2 is a buffered transport with seconds of latency. The
        // realtime AVAudioEngine path fights that — dropouts, drift and
        // stop-and-go over Wi-Fi — while AVSampleBufferAudioRenderer is the
        // same buffered path AVPlayer itself uses for AirPlay. This beats
        // every mode and setting below.
        if outputs.contains(where: { $0.portType == .airPlay }) { return true }
        // Bluetooth headphones are the same shape of problem: a high-latency
        // buffered link the realtime engine handles badly, and one the system
        // STOPS the engine on when the route changes. AirPods often report
        // spatial audio (which already routes them to the renderer below) but
        // not always, so treat any Bluetooth output as renderer-worthy too.
        let bluetooth = outputs.contains {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
        // Playback mode overrides: Fidelity insists on the Atmos-capable
        // renderer whenever the route can use it; Compatibility pins the
        // battle-tested AVAudioEngine. Automatic follows the audio setting.
        switch settings.playbackMode {
        case .fidelity:
            return spatialRoute || bluetooth || settings.audioOutputMode == .renderer
        case .compatibility:
            return false
        case .automatic:
            switch settings.audioOutputMode {
            case .auto: return spatialRoute || bluetooth
            case .renderer: return true
            case .engine: return false
            }
        }
    }

    /// The output route moved mid-session. The FFmpeg engine snapshots its
    /// audio output when it is built, so a route that wants a different one
    /// must be reopened — reopening was done for AirPlay only, and switching
    /// the sound to Bluetooth headphones (AirPods) was the case it missed.
    ///
    /// AirPods report spatial audio, so the app's own rule wants the buffered
    /// `AudioRendererPlayer` for them, but the running session was opened for
    /// HDMI on the realtime `AVAudioEngine` — which the system STOPS on a
    /// route change. The audio clock freezes with it and the picture, slaved
    /// to that clock, sits frozen until the engine happens to be rebuilt: the
    /// "switched to AirPods and it froze, then came back a while later"
    /// report. Reopening onto the renderer also means later route changes are
    /// handled by AVFoundation's own buffered path.
    private func handleAudioRouteChange() {
        guard !isExiting, !isSwitchingSource, hasStartedPlayback,
              playerLayer?.player is KSMEPlayer else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let airPlay = outputs.contains { $0.portType == .airPlay }
        let wanted = Self.wantsSampleBufferRenderer(outputs: outputs, settings: settings)
        // Nothing to do when the running output is still the right one for
        // this route (the common case: a volume HUD or a `.categoryChange`).
        guard wanted != audioOutputChosenIsRenderer
                || airPlay != audioOutputChosenForAirPlay else { return }
        NSLog("[OrivioAudio] route changed — reopening for the right audio output"
            + " (renderer=%@ airPlay=%@)", wanted.probe, airPlay.probe)
        PictureInPictureController.trail(
            "audio route change: renderer=\(wanted) airPlay=\(airPlay) — reloading")
        let resumeAt = resumeTargetForReload
        pendingResume = resumeAt > 10 ? resumeAt : nil
        // A reload autoplays, so the pause card must not stay up over a
        // running picture (the next ⏯ would then pause instead of resume).
        // The sibling reload paths (switchSource / switchEngine) do the same.
        if overlay == .pauseInfo { overlay = .none }
        showToast(airPlay ? "Audio moved to AirPlay — reconnecting"
                          : "Audio output changed — reconnecting")
        load(entry: currentEntry)
    }

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        // AirPlay on/off mid-film: see handleAudioRouteChange.
        notificationTokens.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAudioRouteChange() }
        })
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
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                PictureInPictureController.trail("lifecycle: audio interruption type=\(raw) pip=\(self?.pictureInPicture.isActive ?? false)")
                guard AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                // Only an interruption of RUNNING playback takes the resign
                // path — the same guard the vendored engine handler carries,
                // because activating our own audio session can synthesize a
                // `.began` (it lands during the open, before anything plays).
                // Unguarded, that spurious one latched `didResignActive` from
                // inside `handleResignActive`, and the NEXT didBecomeActive —
                // whatever caused it — then paused a healthy playing film as
                // an "unattended start": the first title of a session opening
                // paused for no visible reason. An interruption that comes
                // with a system overlay (Siri, FaceTime) still latches the
                // resync via willResignActive, which fires alongside it.
                guard self?.isPlaying == true else { return }
                self?.handleResignActive()
            }
        })
        // Memory pressure during playback — precisely when it peaks on the
        // 2–3 GB boxes. The scrub/fine preview frames are the one big fully
        // regenerable block this model holds (tens of MB of BGRA at the
        // mid-tier caps): drop them and cancel the in-flight passes; a later
        // scrub simply re-runs against the cache. ImageCache and the addon
        // response cache already purge themselves; these frames had no owner
        // on the warning list at all.
        notificationTokens.append(nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.scrubThumbnails.isEmpty || !self.fineThumbnails.isEmpty else { return }
                NSLog("[OrivioPlayer] memory warning: dropping %d coarse + %d fine preview frames",
                      self.scrubThumbnails.count, self.fineThumbnails.count)
                self.thumbnailTask?.cancel()
                self.thumbnailer?.cancel()
                self.fineTask?.cancel()
                self.fineThumbnailer?.cancel()
                self.fineDebounce?.cancel()
                self.scrubThumbnails = []
                self.fineThumbnails = []
                self.fineCenter = nil
                // Allow a later scrub to restart the coarse pass from scratch.
                self.thumbnailsStarted = false
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
        guard !isExiting else { return }
        PictureInPictureController.trail("lifecycle: resignActive pip=\(pictureInPicture.isActive)")
        // The picture is in the system's PiP window: the app going inactive
        // or to the background is the whole point, not an interruption.
        if pictureInPicture.isActive { return }
        // Remember the interruption even if we were already paused: on return
        // the video layer may have been torn off (frozen frame) and still needs
        // a resync nudge. Actual pausing only matters while playing.
        //
        // RECORDED ABOVE THE `hasStartedPlayback` GATE, which used to sit at the
        // top of this method. A viewer who leaves DURING the open was never
        // recorded at all — and `.readyToPlay` autoplays whatever the app state
        // is, so the stream opened and ran unwatched behind the app switcher,
        // then came back with neither this path nor the foreground one holding
        // a flag to act on. `resyncPipeline()` therefore never ran over the
        // layer tvOS tore off while we were inactive, which is exactly the
        // frozen-picture-over-live-audio failure it exists to prevent.
        didResignActive = true
        PlayerProbe.event("life", "RESIGN ACTIVE (playing=\(isPlaying.probe)"
            + " started=\(hasStartedPlayback.probe))")
        guard hasStartedPlayback, isPlaying else { return }
        // Drop any gesture in flight FIRST. A scrub left running across a
        // background return with the transport underneath it in `.pauseInfo`
        // is two overlays claiming the screen, and its stale target commits on
        // the next Select.
        cancelPendingTransportIntents()
        enginePause("app resigned active")
        markPaused()
        // Land on the pause overlay so returning shows a clean "paused here"
        // state, not a frozen bare frame.
        if overlay == .none { overlay = .pauseInfo }
        saveProgress()
    }

    private func handleEnterBackground() {
        PlayerProbe.event("life", "BACKGROUND (playing=\(isPlaying.probe) pip=\(pictureInPicture.isActive.probe))")
        PlayerProbe.count("life.background")
        guard !isExiting else { return }
        PictureInPictureController.trail("lifecycle: enterBackground pip=\(pictureInPicture.isActive)")
        if pictureInPicture.isActive { return }
        // Recorded above the `hasStartedPlayback` gate — see handleResignActive.
        // Nothing else covers that window either: KSPlayerLayer's own
        // `enterBackground` bails on `guard state.isPlaying`, and
        // `KSOptions.canBackgroundPlay` is false and never overridden here, so
        // the engine's fallback pause does nothing before the first frame.
        didBackground = true
        // Tells the next resume that this was a suspension, not a pause.
        didSuspendSincePlay = true
        guard hasStartedPlayback else { return }
        cancelPendingTransportIntents()   // see handleResignActive
        enginePause("app went to the background")
        markPaused()
        // Land the viewer on the pause overlay so returning shows a clean
        // "paused here" state, not a frozen bare frame.
        if overlay == .none { overlay = .pauseInfo }
        saveProgress()
    }

    /// Returning from a full background: resync the stale decode pipeline.
    private func handleEnterForeground() {
        PlayerProbe.event("life", "FOREGROUND (didBackground=\(didBackground.probe)"
            + " started=\(hasStartedPlayback.probe))")
        PictureInPictureController.trail("lifecycle: enterForeground pip=\(pictureInPicture.isActive) didBackground=\(didBackground)")
        guard didBackground, !isExiting else { return }
        didBackground = false
        // This path owns the resync; keep didBecomeActive (which fires right
        // after) from running a second, redundant one.
        didResignActive = false
        // BOTH FLAGS CLEAR ABOVE THE `hasStartedPlayback` GATE. A round trip
        // that began and ended inside the open has nothing decoded to flush,
        // but a `didBackground` left standing would latch `handleBecomeActive`
        // off through its `!didBackground` term for the rest of the session,
        // and every later app-switcher return would come back frozen.
        guard hasStartedPlayback else { return }
        // The cache counted the frozen minutes as a stalled download; tell it
        // the clock restarts here, before the resync asks it for bytes. Only on
        // THIS path: a resign-only round trip never stopped the process, so its
        // stall clocks are honest and must keep running.
        MediaCacheServer.shared.noteAppResumed()
        claimUnattendedStart()
        resyncPipeline()
    }

    /// Returning from the app switcher / a system overlay that only made us
    /// INACTIVE (no background/foreground pair). Without this the resync never
    /// runs and the torn-off video layer comes back frozen while audio plays —
    /// the double-press-Home-then-return freeze. Guarded so it never doubles up
    /// with the full-background path (which clears didResignActive first).
    private func handleBecomeActive() {
        PlayerProbe.event("life", "ACTIVE (didResign=\(didResignActive.probe)"
            + " didBackground=\(didBackground.probe))")
        PictureInPictureController.trail("lifecycle: becomeActive pip=\(pictureInPicture.isActive) didResign=\(didResignActive)")
        guard didResignActive, !didBackground, !isExiting else { return }
        didResignActive = false
        // Cleared above the gate for the reason handleEnterForeground gives.
        guard hasStartedPlayback else { return }
        claimUnattendedStart()
        resyncPipeline()
    }

    /// The stream OPENED while the app was away, so nothing ever asked it to
    /// stop: both lifecycle handlers had no session to pause when they ran, and
    /// the VLC and direct-DV start paths autoplay without consulting the app
    /// state. Claim that pause BEFORE the resync flushes the pipeline — a
    /// player stopped with `pauseIntent` still false is one nobody asked to
    /// stop, which the `.paused` delegate reads as a dropped autoplay and
    /// restarts 1.5s later (`armSeekPlayWatchdog`), and which makes the first
    /// ⏯ press pause instead of resume. A session the handlers DID pause
    /// arrives here with the intent already set, so this is a no-op on every
    /// ordinary return.
    private func claimUnattendedStart() {
        guard isPlaying, !pauseIntent else { return }
        PlayerProbe.event("life", "claiming an unattended start — pausing a stream nobody asked to play")
        PlayerProbe.count("life.unattended-start")
        cancelPendingTransportIntents()
        enginePause("stream started while the app was away")
        if overlay == .none { overlay = .pauseInfo }
    }

    /// Flush the (possibly stale or torn-off) decode pipeline and re-render the
    /// current frame in place, staying paused where the viewer left off —
    /// pressing Play then resumes cleanly instead of into a broken pipeline
    /// (the fast-forward / stale-audio / frozen-frame bugs). Never auto-resumes.
    private func resyncPipeline() {
        PlayerProbe.event("life", String(format: "RESYNC pipeline from %.1f", position))
        PlayerProbe.count("life.resync")
        PictureInPictureController.trail("lifecycle: resyncPipeline pip=\(pictureInPicture.isActive)")
        isResyncing = true
        let target = max(position - 1, 0)
        if let dvDirectEngine {
            // The direct engine owns its own VideoToolbox session and its two
            // renderers, and a seek is what flushes them. Without this branch
            // the whole resync was a NO-OP for a native-DV session: it has no
            // `playerLayer`, so neither the pause nor the seek below reached
            // anything, yet the code went on to rewrite `position`, force
            // `isPlaying = false` and drop the black cover as though a resync
            // had happened. What actually came back was the layer tvOS tore
            // off while the app was inactive, still holding pre-background
            // frames.
            dvDirectEngine.pause()
            dvDirectEngine.seek(to: target)
            scheduleResyncClear(after: 0.7)
        } else if let vlcEngine {
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
        // A new stream answers whatever dead-end the viewer stepped out of to
        // reach it, so Back can no longer take them back to a stale error.
        overlayBeforeSubMenu = nil
        // Same for the empty-sources dead end: once a stream is genuinely being
        // opened, Try Again belongs to THAT stream again, not to an episode
        // lookup that has since been superseded (a failover can start a load
        // while the error is still on screen).
        episodeAwaitingSources = nil
        if overrideURL == nil {
            resetNativeDV()
            decisionLog.reset()
            selectAudioOutput()
            activeMode = settings.playbackMode
            if activeMode != .automatic {
                decisionLog.record("Mode", activeMode.label, because: "chosen in Settings → Playback")
            }
        }
        guard let originURL = overrideURL ?? entry.stream.url.flatMap(URL.init(string:)) else {
            overlay = .error("This source has no playable link.")
            return
        }
        PlayerProbe.event("load", "START \(entry.addonName)"
            + " / \(entry.displayName.prefix(60))"
            + " host=\(originURL.host ?? "?") ext=\(originURL.pathExtension)"
            + " engine=\(effectiveEngine.rawValue) mode=\(activeMode.rawValue)"
            + " override=\(overrideURL != nil ? "DV" : "-")"
            + " resume=\(pendingResume.map { String(format: "%.0f", $0) } ?? "-")")
        PlayerProbe.count("load.starts")
        PlayerProbe.note("url", "\(originURL.host ?? "?")\(originURL.path.suffix(48))")
        // Hybrid disk cache (Settings → Playback): swap the direct-file URL
        // for the localhost caching proxy, which downloads the whole file to
        // storage at full speed and serves seeks from disk. Never re-proxied
        // on an internal override re-entry (engine swaps keep whatever URL
        // they were handed), and `beginSession` itself declines HLS and
        // anything else that can't be cached this way.
        var url = originURL
        let wantsHybridCache = settings.hybridDiskCacheEnabled || PlayerDevFlags.hybridCache
        // The trail is opened FIRST. It clears itself when the title changes,
        // so anything written before this call — the cache decision, notably —
        // was wiped by the clear it triggers and never reached the read-out.
        startCacheBandTicker()
        Self.beginColorTrail(for: originURL.absoluteString,
                             "=== load: \(entry.stream.name ?? entry.addonName)"
                                 + " ext=\(originURL.pathExtension) engine=\(effectiveEngine.rawValue)"
                                 + " mode=\(activeMode.rawValue) override=\(overrideURL != nil) ===")
        if overrideURL == nil, !wantsHybridCache {
            Self.colorTrail("cache: not attempted — Hybrid disk cache is off in Settings → Playback")
        }
        if overrideURL == nil, wantsHybridCache,
           let proxied = MediaCacheServer.shared.beginSession(
               origin: originURL,
               headers: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders) {
            // Remember an origin that refuses ranges, so the picker stops
            // choosing this addon. Captured per load; the closure is replaced
            // on the next one.
            let addon = currentEntry.addonName
            MediaCacheServer.shared.onOriginRefusedRanges = { [weak self] note in
                Stream.RangeRefusingAddons.note(addon)
                Self.colorTrail("cache: \(addon) \(note) — excluded from auto-selection")
                // A PROBE EVENT, not just a trail line. The throttle back-off
                // taught this the hard way: a recorder watching the probe read
                // "0 throttle events" while throttling ran continuously
                // underneath it, because that path only wrote to the trail.
                PlayerProbe.event("cache", "\(addon) \(note)"
                    + " — excluded from auto-selection, moving to another source")
                self?.decisionLog.record("Cache", "Source refuses ranges",
                                         because: "\(addon) \(note); caching and seeking are impossible")
                // AND LEAVE IT. Remembering the addon only helps the NEXT
                // title; it does nothing for the viewer sitting in front of
                // this one, who has a film that cannot cache, cannot seek and
                // cannot show a scrub preview, with nothing on screen to say
                // why. Three sessions ended up here tonight on the same cast
                // endpoint. Every retry has been spent by this point — the
                // cache does not call this until all of them have failed on an
                // HTTP status — so there is nothing left to wait for.
                guard let self, !self.isExiting,
                      self.currentEntry.addonName == addon else { return }
                self.attemptFailover(afterError: NSError(
                    domain: "OrivioCache", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "this source refuses byte ranges — no caching or seeking"]))
            }
            decisionLog.record("Cache", "Hybrid disk",
                               because: "caching the whole file to storage so seeks serve from disk")
            PictureInPictureController.trail("hybrid cache proxying \(originURL.host ?? "?")")
            url = proxied
        } else if overrideURL == nil, wantsHybridCache {
            Self.colorTrail("cache: declined (non-http origin, HLS playlist, or listener failed) — direct playback")
        }
        PictureInPictureController.trail("load: begin \(url.host ?? "?") ext=\(url.pathExtension) engine=\(effectiveEngine.rawValue) override=\(overrideURL != nil) addon=\(entry.addonName)")
        audioOptions = []
        subtitleOptions = []
        selectedSubtitleID = nil
        duration = 0
        buffered = 0
        position = 0
        clock.position = 0
        clock.duration = 0
        clock.buffered = 0
        // The clock now belongs to this stream. When it is the episode a switch
        // was waiting for, saves describe that episode again.
        if let target = episodeSwitchTargetID, currentVideo?.id == target {
            episodeSwitchTargetID = nil
        }
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
        // A finished stream's terminal flag must not survive into the next
        // load either: a source/engine switch (or failover) issued from the
        // post-play state reopened at the tail, played to the end again and
        // then `handlePlayedToEnd` returned on the stale flag — frozen last
        // frame, no Replay/Up Next.
        playedToEndHandled = false
        // A NEW LINK RESTARTS THE EVIDENCE. `recordLinkVerdict` keeps or
        // rejects a source on "did five minutes of this session play", measured
        // from `sessionStartPosition` — which was only ever reset on an episode
        // change. After a failover the replacement link inherited every minute
        // the DEAD one had played, so a source that managed thirty seconds was
        // credited with the previous one's ten minutes and KEPT, and the
        // deterministic selector served it again next time. Engine switches
        // deliberately do not reset it: same link, same evidence.
        if verdictEntryID != entry.id {
            verdictEntryID = entry.id
            sessionStartPosition = pendingResume ?? position
        }
        // Per-load session state that EVERY engine path needs reset — the
        // previous stream's subtitle selection, scrub thumbnails, skip-intro
        // data and chapters. This used to be duplicated in the KSPlayer and
        // VLC paths only, so the DV-first path inherited all of it from the
        // previous episode (its cues, its previews, its OP timestamps).
        resetPerLoadSessionState()

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
            // A mid-session DV-first load must retire the live KSPlayer layer
            // first, exactly as `loadViaVLC` does — otherwise the old stream
            // keeps decoding and playing audio under the DV session, its tick
            // keeps overwriting `position`, and its buffering/finish callbacks
            // arm the stall watchdog against the healthy DV engine.
            if let layer = playerLayer {
                layer.pause()
                layer.stop()
                playerLayer = nil
                videoRefreshID = UUID()
            }
            subtitleModel.selectedSubtitleInfo = nil
            subtitleModel.url = url
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
        // The engine path keeps its own `isDisplayCriteriaMatchingEnabled`
        // check, which IS the Apple TV's Match Content setting; this app-level
        // term is retired, so leave it permissive and let tvOS decide.
        options.matchDisplayCriteria = true
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
        let ffmpegContainers = Self.ffmpegContainers
        let nativeContainers = Self.nativeContainers
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
        // A per-title memory of "Native" is only worth keeping on a container
        // AVPlayer can open. On an MKV (or an unknown link) it is a doomed
        // open that grinds for seconds and then falls over to FFmpeg — the
        // "takes forever to start" every play of that title afterwards. Drop
        // it and go Auto (FFmpeg-first) instead.
        if sessionEngine == .native, !enginePickedThisSession, overrideURL == nil,
           !nativeContainers.contains(ext) {
            sessionEngine = nil
            PlaybackMemory.update(meta.id) { $0.engine = nil }
            decisionLog.record("Engine", "Auto",
                               because: "the remembered Native engine can't open this container; forgetting it")
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
        } else if forceDemuxerForSession {
            // A scheme AVPlayer cannot open (rtmp/rtsp/udp) or a DASH
            // manifest. Not a preference — the native path has no chance.
            needsFFmpeg = true
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
        // What this engine can do with Dolby audio, said plainly and in the
        // one place where the engine is already known. FFmpeg decodes every
        // codec (`AudioSwresample`), so a session on it is multichannel PCM
        // however the receiver is labelled; AVPlayer hands Dolby to tvOS
        // untouched. The sample-feed engine records its own line at open.
        decisionLog.record(
            "Dolby Audio",
            needsFFmpeg ? "Decoded to PCM in-app" : "Bitstreamed by tvOS when the track is Dolby",
            because: needsFFmpeg
                ? "the FFmpeg engine decodes every audio codec; a Dolby bitstream needs the sample-feed engine (MKV) or AVPlayer (MP4/HLS)"
                : "AVPlayer passes Dolby Digital / DD+ straight to the HDMI route"
        )
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
            // TESTED 2026-09-07 and EXONERATED as a cause of missing colour
            // tags: widened to 16 MB / 5s on a 2160p 10-bit HEVC remux and
            // ffmpeg still reported colour_primaries/trc/space as UNSPECIFIED.
            // The small probe is not why the colour description is absent, so
            // the fast-startup budget stays.
            options.probesize = 2 << 20              // 2 MB
            options.maxAnalyzeDuration = 1_000_000   // 1s (microseconds)
            PlayerViewModel.colorTrail(
                "probe budget probesize=\(options.probesize ?? 0) maxAnalyze=\(options.maxAnalyzeDuration ?? 0)us"
            )
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
        switch effectiveBufferProfile(for: url) {
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
            options.maxBufferDuration = min(options.maxBufferDuration, 12)   // see the KSOptions cap
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
        // Carry the title's lip-sync offset onto the fresh options object.
        applyAudioSync()
        loadStartedAt = Date()
        currentURL = url
        startLoadWatchdog()
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

        // `KSPlayerLayer.set(url:)` is a NO-OP for an unchanged URL on the
        // same engine class (it only calls `play()`), so a reload of the
        // current source — the audio-route reopen, the seek-fault recovery,
        // an Auto↔FFmpeg engine switch on the same file — never reopened
        // anything: `.readyToPlay` never fired, the track lists and subtitle
        // model this function just cleared were never rebuilt, and
        // `pendingResume` floored every later progress save. Retire the layer
        // so the branch below builds a fresh one.
        if let layer = playerLayer, layer.url == url {
            layer.pause()
            layer.stop()
            playerLayer = nil
            videoRefreshID = UUID()
        }
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
    /// Buffer ahead applies ONLY to streams the hybrid disk cache cannot serve.
    ///
    /// When the cache IS in front of a stream it downloads the whole file to
    /// storage at full speed and serves seeks from disk, so a second, larger
    /// RAM read-ahead buys nothing and competes with decode for memory on the
    /// 3 GB boxes. The control is retired from Settings for the same reason;
    /// what remains of the profile is for the streams the cache declines —
    /// HLS and anything else it can't range-request.
    ///
    /// `url` is the PLAYBACK url, so a hybrid-cached session is the one being
    /// served from the loopback proxy.
    private func effectiveBufferProfile(for url: URL?) -> BufferProfile {
        url?.host == "127.0.0.1" ? .auto : settings.bufferProfile
    }

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
        let target = effectiveBufferProfile(for: currentURL).targetBytes
            ?? PerformanceProfile.maxBufferBytes

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
        if effectiveBufferProfile(for: currentURL).targetBytes == nil {
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
        // `dovi` is the FFmpeg-side DOVI configuration record: KSPlayer only
        // ever fills it on `FFmpegAssetTrack`, so on an AVMediaPlayerTrack it
        // is declared-and-never-assigned and this read was permanently false —
        // which is why the DV→HDR10 clamp in `updateVideo` fired on every
        // Dolby Vision mp4/mov AVPlayer opened. `dynamicRange` still consults
        // `dovi` first, then falls through to the real AVAssetTrack sample
        // entry, where a dvh1/dvhe box is exactly the DV this session emits.
        currentOptions?.updateVideo(
            refreshRate: track.nominalFrameRate,
            isDovi: track.dynamicRange == .dolbyVision,
            formatDescription: track.formatDescription
        )
    }

    /// Push the Playback pane's caption style onto the NATIVE engine's item.
    ///
    /// The FFmpeg path hands its cues to `SubtitleOverlayView`, which draws
    /// them with the app's own size/colour/outline. AVPlayer renders legible
    /// tracks ITSELF, and with no style rules attached it obeys the tvOS
    /// system caption appearance (Settings → Accessibility → Subtitles) —
    /// which is where "the subtitles are giant and nothing in the app changes
    /// them" comes from on an mp4/HLS stream. `AVTextStyleRule` is the only
    /// hook AVFoundation offers, so mirror the same settings into it.
    ///
    /// Relative size, not points: `kMSKTextFontSize` is a PERCENTAGE of the
    /// video's default caption size, so map the point setting against the
    /// 36pt default the overlay uses.
    private func applyNativeCaptionStyle() {
        guard let native = playerLayer?.player as? KSAVPlayer,
              let item = native.player.currentItem else { return }
        let s = settings
        /// ARGB as the 0...1 component array CMTextMarkup wants.
        func argb(_ hex: String, alpha: Double = 1, fallback: (Double, Double, Double)) -> [Double] {
            var value = UInt64(0)
            let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
            guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
                return [alpha, fallback.0, fallback.1, fallback.2]
            }
            return [alpha,
                    Double((value >> 16) & 0xFF) / 255,
                    Double((value >> 8) & 0xFF) / 255,
                    Double(value & 0xFF) / 255]
        }
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String:
                argb(s.subtitleTextColorHex, fallback: (1, 1, 1)),
            // A PERCENTAGE of the video's default caption size, not points —
            // scaled against the 36pt default the FFmpeg overlay draws at, so
            // one Size setting reads the same on both engines.
            kCMTextMarkupAttribute_RelativeFontSize as String:
                Double(s.subtitleSize) / 36.0 * 100.0,
            kCMTextMarkupAttribute_BoldStyle as String: s.subtitleBold,
            // Transparent unless the plate is on. Set EITHER way: leaving the
            // key out lets the system caption style put its own box back.
            kCMTextMarkupAttribute_BackgroundColorARGB as String:
                [s.subtitleBackground ? Double(s.subtitleBackgroundOpacity) / 100.0 : 0.0, 0.0, 0.0, 0.0],
            // CMTextMarkup has no edge COLOUR attribute, so the outline is
            // on/off here and tvOS picks the colour; the FFmpeg overlay is
            // where `subtitleOutlineColorHex` is honoured exactly.
            kCMTextMarkupAttribute_CharacterEdgeStyle as String:
                (s.subtitleOutlineEnabled ? kCMTextMarkupCharacterEdgeStyle_Uniform
                                          : kCMTextMarkupCharacterEdgeStyle_None) as String
        ]
        if !s.subtitleFontName.isEmpty {
            attributes[kCMTextMarkupAttribute_FontFamilyName as String] = s.subtitleFontName
        }
        item.textStyleRules = [AVTextStyleRule(textMarkupAttributes: attributes)].compactMap { $0 }
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

    /// The engine-agnostic per-load reset shared by the KSPlayer, VLC and
    /// DV-first paths. Anything that describes the PREVIOUS stream and would
    /// otherwise leak into the next one lives here.
    /// Bumped by every load. Async work started for one stream captures it and
    /// re-checks it after each await, so a slow round-trip that lands after the
    /// viewer has moved on cannot write into the stream that replaced it.
    ///
    /// `isExiting` was the only guard several of these had, which answers a
    /// different question: it catches "the player is gone" but not "this is now
    /// a DIFFERENT film". `dvFirstGeneration` already does exactly this for the
    /// Dolby Vision preflight; this generalises it to the rest of the per-load
    /// async work.
    private var loadGeneration = 0

    /// True when `generation` is still the stream currently loaded.
    private func isCurrentLoad(_ generation: Int) -> Bool {
        loadGeneration == generation && !isExiting
    }

    /// Drop every transport intent that belonged to the OUTGOING stream.
    ///
    /// A skip gathers into `pendingSeekDelta` and commits on a debounce, and a
    /// scrub holds a target until it is committed. Neither survives the stream
    /// it was aimed at: left armed across a load they fire against the NEW one,
    /// where `position` is 0 — a source switch that lands ten seconds in, or a
    /// scrub HUD still up over a different stream whose Select commits to the
    /// old timestamp.
    private func cancelPendingTransportIntents() {
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekDelta = 0
        nudgeStreak = 0
        scrubTimeoutTask?.cancel()
        scrubTimeoutTask = nil
        if isScrubbing || scrubValue != nil {
            isScrubbing = false
            scrubValue = nil
            clock.scrubTarget = nil
            resumeAfterScrub = false
            resetWheel()
        }
    }

    /// The link `sessionStartPosition` is currently measuring.
    private var verdictEntryID: UUID?

    private func resetPerLoadSessionState() {
        loadGeneration &+= 1
        cancelPendingTransportIntents()
        thumbnailTask?.cancel()
        thumbnailer?.cancel()   // aborts its FFmpeg session, even mid-read
        thumbnailer = nil
        thumbnailsStarted = false
        scrubThumbnails = []
        // The fine-tune set too: `thumbnail(at:)` prefers it and a stale
        // `fineCenter` blocks regeneration, so a reload mid-fine-tune kept the
        // previous source's frames.
        fineDebounce?.cancel()
        fineDebounce = nil
        fineThumbnailer?.cancel()
        fineThumbnailer = nil
        fineThumbnails = []
        fineCenter = nil
        cacheTask?.cancel()
        addonSubtitlesFetched = false
        subtitleAutoApplied = false
        pendingEndAfterSwitch = false   // a new stream: the old end is moot
        // A reload's re-select target belongs to the load that asked for it —
        // carried across an episode change it would re-apply the previous
        // episode's track id to the new stream's wave.
        pendingSubtitleReselect = nil
        vlcAudioAutoApplied = false
        vlcKnownAudioTrackCount = 0
        vlcLastAudioWaveCheck = .distantPast
        chapters = []
        animeSkipIntervals = []
        animeSkipFetched = false
        // Belongs to the seek that armed it, on the stream being replaced.
        seekPlayWatchdog?.cancel()
        seekPlayWatchdog = nil
        // The notice-clip verdict is about the link being loaded, not the
        // session — the counts per addon deliberately survive, since that is
        // what tells a bad link apart from a bad debrid session.
        currentSourceIsNoticeClip = false
        setSkipIntroActive(false)
        autoSkippedChapters = []
        dismissedIntroStart = nil
    }

    private func loadViaVLC(url: URL) {
        // Tear down any KSPlayer instance so the two engines never coexist.
        playerLayer?.stop()
        playerLayer = nil

        currentURL = url
        loadStartedAt = Date()
        startLoadWatchdog()
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
        AudioOutputCapability.configureForMoviePlayback()
        // Fire-and-forget off main: activation is an IPC round trip (see the
        // DV path's note); VLC tolerates it racing its own open.
        Task.detached(priority: .userInitiated) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }

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
        // Deduped: VLC re-reports the same tuple at its own cadence, and an
        // unfiltered line per report would bury every other event in the tail.
        let vlcState = "\(playing.probe)\(buffering.probe)\(ended.probe)\(errored.probe)"
        if vlcState != lastVLCProbeState {
            lastVLCProbeState = vlcState
            PlayerProbe.event("state", String(
                format: "vlc → playing=%@ buffering=%@ ended=%@ errored=%@ at %.1f",
                playing.probe, buffering.probe, ended.probe, errored.probe, position))
        }
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
        // Same-value dedupe — VLC re-reports state at its own cadence, and
        // each @Published assignment re-renders every VM observer.
        if isPlaying != playing { isPlaying = playing }
        let nowBuffering = buffering && !playing
        if isBuffering != nowBuffering { isBuffering = nowBuffering }
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
            applyAudioSync()          // per-session VLC knob
            videoRefreshID = UUID()   // re-attach the VLC drawable view
            if let engine = vlcEngine, engine.naturalSize != .zero {
                videoNaturalSize = engine.naturalSize
            }
            loadVLCTracks()
            if let resume = pendingResume, resume > 5,
               duration == 0 || resume < duration - 30 {
                // RAISE THE FLOOR BEFORE THE SEEK. VLC keeps reporting the top
                // of the file until the seek actually lands — the re-assert
                // below polls for four seconds precisely because that window is
                // that long — and nothing else on the VLC path ever writes
                // `sessionResumeFloor`. A failover or an engine/source switch
                // inside it took `max(position, pendingResume, floor)` off three
                // values that were all ~0 and reopened the replacement stream at
                // 00:00. The KSPlayer first-playback branch raises it here for
                // exactly this reason.
                sessionResumeFloor = max(sessionResumeFloor, resume)
                vlcEngine?.seek(to: resume)
                // VLCKit can override a seek issued at the first `playing`
                // flip with its own position once the media finishes opening
                // — the "VLC restarts the movie" bug. Re-assert until the
                // position actually lands near the target.
                let generation = loadGeneration
                let armedAt = Date()
                Task { [weak self] in
                    for _ in 0 ..< 4 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let self, self.isCurrentLoad(generation),
                              self.vlcEngine != nil else { return }
                        // THE VIEWER OUTRANKS THE RESUME. Its only exit was
                        // "position is near the target", so rewinding more than
                        // ten seconds inside this four-second window looked
                        // identical to VLC having ignored the seek — and it
                        // dragged them back to the resume point, undoing their
                        // own rewind with no explanation. A scrub in progress
                        // is the same situation a moment earlier.
                        // AND THE TARGET IS RELEASED HERE, NOT BEFORE THE
                        // SEEK. Every exit below means the resume is settled —
                        // landed, or overtaken by the viewer. Cleared up front
                        // it was gone while `position` still read ~0, so the
                        // `max(position, pendingResume)` both save paths use
                        // wrote a fraction of a second over a saved 1:20:00: one
                        // Menu, ⏯ or TV press in the first seconds of a VLC
                        // resume sent Continue Watching back to the film's start.
                        if self.isScrubbing { self.pendingResume = nil; return }
                        if let userSeek = self.lastUserSeekAt, userSeek > armedAt {
                            self.pendingResume = nil
                            return
                        }
                        if self.position >= resume - 10 { self.pendingResume = nil; return }
                        self.vlcEngine?.seek(to: resume)
                    }
                    // Out of attempts — release it anyway. Left set it floors
                    // every later save for the rest of the session, so Continue
                    // Watching could never record a position BELOW the entry
                    // point; that is the trap the DV tick documents. The
                    // generation re-check keeps it off a load that replaced this
                    // one in the meantime, which owns its own target.
                    guard let self, self.isCurrentLoad(generation) else { return }
                    self.pendingResume = nil
                }
            } else {
                pendingResume = nil
            }
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
        // Wave watch for the preferred-audio pick: nothing in VLCKit announces
        // "a new elementary stream appeared", so while the pick is unsettled
        // (see vlcAudioAutoApplied) poll the track count on this tick — at most
        // every 2s — and re-read the lists when it grows. Ends the moment the
        // preference is applied, the viewer picks by hand, or no preference is
        // set; costs one count read per check until then.
        if !vlcAudioAutoApplied, vlcSessionPrepared,
           Date().timeIntervalSince(vlcLastAudioWaveCheck) > 2 {
            vlcLastAudioWaveCheck = Date()
            if let engine = vlcEngine, engine.audioTracks.count != vlcKnownAudioTrackCount {
                loadVLCTracks()
            }
        }
        refreshPictureInPictureSource()
        if current.isFinite { markPlaybackProgressed(currentTime: current) }
        position = current
        if total > 0 {
            duration = total
            noteDurationForNoticeCheck(total)   // see the KSPlayer path
        }
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

    /// Audio tracks seen at the last `loadVLCTracks`, so the wave watch in
    /// `vlcTimeChanged` can tell when VLC has announced more.
    private var vlcKnownAudioTrackCount = 0
    /// Throttles that watch to one count read every couple of seconds.
    private var vlcLastAudioWaveCheck = Date.distantPast

    /// Build the audio/subtitle pickers from VLC's track lists.
    private func loadVLCTracks() {
        guard let engine = vlcEngine else { return }
        let engineAudio = engine.audioTracks
        vlcKnownAudioTrackCount = engineAudio.count
        audioOptions = engineAudio.map {
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
        applyPreferredVLCAudioIfNeeded()
        applyDefaultSubtitleIfNeeded()
    }

    /// True once the preferred-audio question is SETTLED for this VLC session
    /// — the preferred track was found (and selected), or the viewer picked a
    /// track by hand (see `selectAudio`). Later track waves must not undo
    /// either. Crucially it is NOT set just because the picker ran: VLC
    /// announces elementary streams in waves, and the first `playing` flip
    /// routinely lists only the track already decoding. Latching on that
    /// incomplete first wave is why the Settings default was still ignored on
    /// VLC streams — the preferred-language track arrived seconds later,
    /// nothing looked at it, and the session stayed on the file default.
    private var vlcAudioAutoApplied = false

    /// The KSPlayer and DV-direct paths both honour the preferred audio
    /// language — KSPlayer picks it in `loadTracks`, the DV engine scores it at
    /// open — but VLC never did: it played whatever the file defaulted to,
    /// which is what made the Settings default look ignored on those streams.
    /// VLC gives us names, not language codes, so the match is by name.
    private func applyPreferredVLCAudioIfNeeded() {
        guard !vlcAudioAutoApplied, !audioOptions.isEmpty else { return }
        let remembered = PlaybackMemory.memory(for: meta.id)?.audioLanguage
        // Remembered, then the Settings default — see `loadTracks` for why
        // both get a turn rather than the first one winning outright.
        // Settings first, per-title memory second — see `loadTracks`.
        let wants = [settings.preferredAudioLanguage, remembered]
            .compactMap { $0 }.filter { !$0.isEmpty }
        // No preference configured: settled by definition (and the wave watch
        // in `vlcTimeChanged` can stand down).
        guard !wants.isEmpty else { vlcAudioAutoApplied = true; return }
        var chosen: (match: TrackOption, why: String)?
        for (index, want) in wants.enumerated() {
            // A commentary track in the right language is still the wrong track.
            let inLanguage = audioOptions.filter { audioTrackMatchesLanguage($0, want) }
            guard let match = inLanguage.first(where: { !AudioLanguageMatch.isSecondary(label: $0.displayName) })
                    ?? inLanguage.first else { continue }
            let usedSetting = index == 0 && !settings.preferredAudioLanguage.isEmpty
            chosen = (match, usedSetting ? "preferred audio language"
                                         : "remembered for this title")
            break
        }
        // Nothing in any of them YET — leave the latch open so the next wave
        // gets to look again. The tracks VLC hasn't announced can't be matched.
        guard let (match, why) = chosen else { return }
        vlcAudioAutoApplied = true
        guard match.id != selectedAudioID else { return }
        selectAudio(match)
        decisionLog.record("Audio Track", match.displayName, because: why)
    }

    /// Name-based language match for engines that expose no language code.
    /// See `AudioLanguageMatch`: whole-word, alias-aware ("eng", "English",
    /// "Deutsch" all satisfy a German preference), because a bare
    /// `contains(code)` once picked the French track for an English default.
    private func audioTrackMatchesLanguage(_ option: TrackOption, _ code: String) -> Bool {
        AudioLanguageMatch.matches(code: nil, label: option.displayName, preferred: code)
    }

    /// SECOND TURN AT THE AUDIO PREFERENCE, for the direct engine.
    ///
    /// `DVSampleEngine` scores its audio once, at open, against a SINGLE
    /// language string — and the per-title memory takes that slot (see the
    /// `preferredAudioLanguage:` argument on the DV-first load). That is the
    /// one-shot `remembered ?? setting` `loadTracks` and the VLC path were
    /// both fixed for and this branch never was: a title (or, since the key
    /// is the show, an entire series) whose audio had ever been picked by
    /// hand was pinned to that language, and a release carrying no track in
    /// it opened on the file's own default with Settings → Audio never
    /// consulted at all.
    ///
    /// Runs ONLY when the remembered language is absent from this file —
    /// precisely the case the engine cannot see. Whenever it is present the
    /// engine's own ranking (exact remembered label, channels, commentary
    /// demoted) is the better answer and stands untouched.
    private func applyPreferredDVAudioSecondTurn(engine: DVSampleEngine) {
        // INVERTED WITH THE PRIORITY SWAP. The engine is now handed the
        // SETTINGS language at open, so this turn is the mirror of what it
        // was: it rescues a file that carries nothing in the chosen language
        // by falling back to what the title remembers.
        let primary = settings.preferredAudioLanguage
        // No Settings language configured: the engine was handed the title's
        // own memory instead and has already scored it. Nothing to add.
        guard !primary.isEmpty else { return }
        let memory = PlaybackMemory.memory(for: meta.id)
        // Nothing remembered for this title either — the engine's own ranking
        // is the whole answer.
        guard let remembered = memory?.audioLanguage, !remembered.isEmpty else { return }
        let tracks = engine.audioTracks
        guard tracks.count > 1 else { return }
        // The chosen language IS in this file — the engine already picked it,
        // and that is exactly the outcome the priority swap exists to produce.
        guard !tracks.contains(where: {
            AudioLanguageMatch.matches(code: $0.lang, label: $0.label, preferred: primary)
        }) else { return }
        // An exact remembered LABEL is here and outscores every language match
        // inside the engine, so the viewer's own track is already playing.
        if let label = memory?.audioTrackLabel,
           tracks.contains(where: { $0.label == label }) { return }
        let inLanguage = tracks.filter {
            AudioLanguageMatch.matches(code: $0.lang, label: $0.label, preferred: remembered)
        }
        // Rank inside the language the way the engine does — never a
        // commentary/descriptive track, then channel count, ties to the first
        // stream — reading the count back off the label the engine builds
        // ("English · EAC3 · 6ch"). A label that carries no count simply
        // ranks 0 and stream order decides.
        var best: DVSampleEngine.AudioTrack?
        var bestChannels = -1
        for track in inLanguage where !AudioLanguageMatch.isSecondary(label: track.label) {
            let channels = Self.dvTrackChannelCount(track.label)
            if channels > bestChannels {
                bestChannels = channels
                best = track
            }
        }
        // Everything in the language is commentary: still the language asked
        // for, which beats a default track in a language nobody asked for.
        guard let pick = best ?? inLanguage.first,
              pick.index != engine.currentAudioIndex else { return }
        // Straight to the engine, NOT through `selectAudio(_:)`: that records
        // the track in PlaybackMemory, and an automatic pick must never
        // overwrite a choice the viewer made by hand.
        engine.selectAudio(index: pick.index)
        selectedAudioID = "dvda-\(pick.index)"
        decisionLog.record("Audio Track", pick.label,
                           because: "remembered for this title — this file carries nothing in your preferred audio language")
    }

    /// Channel count read back off a `DVSampleEngine` track label's trailing
    /// "6ch" component; 0 when the label carries none.
    private static func dvTrackChannelCount(_ label: String) -> Int {
        guard let last = label.split(separator: "·").last?
                .trimmingCharacters(in: .whitespaces), last.hasSuffix("ch")
        else { return 0 }
        return Int(last.dropLast(2)) ?? 0
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
        // Remembered first, then the Settings default — IN THAT ORDER, both of
        // them. It used to be `remembered ?? setting`, one shot: a title (or,
        // since the key is the show, an entire series) that had ever had its
        // audio changed by hand was pinned to that language, and when the file
        // in front of us carried no track in it the preference was never even
        // consulted. The stream then opened on whatever the file defaulted to
        // and the Settings default looked ignored.
        for (want, why) in [(settings.preferredAudioLanguage, "preferred audio language"),
                            (rememberedAudio, "remembered for this title")] {
            guard let want, !want.isEmpty else { continue }
            // Ranking inside the language: never a commentary/descriptive
            // track, then Atmos-capable (DD+ carries Atmos through tvOS
            // natively), then channel count. The file's own default only wins
            // when no preferred-language track exists.
            let best = player.tracks(mediaType: .audio)
                .filter {
                    // Label fallback included: plenty of re-encodes tag no
                    // language at all and only say "English" in the track
                    // title, and those used to miss the preference entirely.
                    AudioLanguageMatch.matches(code: $0.languageCode,
                                               label: trackLabel($0), preferred: want)
                }
                .sorted { a, b in
                    let aSec = Self.isSecondaryAudio(a), bSec = Self.isSecondaryAudio(b)
                    if aSec != bSec { return !aSec }
                    let aAtmos = Self.audioFormat(a).atmosCapable
                    let bAtmos = Self.audioFormat(b).atmosCapable
                    if aAtmos != bAtmos { return aAtmos }
                    return Self.channelCount(a) > Self.channelCount(b)
                }
                .first
            guard let best else { continue }   // nothing here — try the next preference
            if !best.isEnabled {
                player.select(track: best)
                selectedAudioID = "audio-\(best.trackID)"
                PlayerProbe.event("tracks", "audio -> \(trackLabel(best)) (\(why))")
                decisionLog.record("Audio Track", trackLabel(best),
                                   because: "\(why), ranked by Atmos capability and channels")
            }
            break   // this preference had an answer, wanted or already playing
        }

        // Nothing in the preferred language (or none configured): the file's
        // own default still shouldn't be a commentary or described-video track.
        // Remuxes routinely mark one of those default, and the DV engine has
        // always demoted them — this path never did, which is the other way a
        // session opened on audio nobody asked for.
        let audio = player.tracks(mediaType: .audio)
        if let current = audio.first(where: { $0.isEnabled }),
           Self.isSecondaryAudio(current) || AudioLanguageMatch.isSecondary(label: trackLabel(current)),
           let primary = audio
            .filter({ !Self.isSecondaryAudio($0) && !AudioLanguageMatch.isSecondary(label: trackLabel($0)) })
            .max(by: { Self.channelCount($0) < Self.channelCount($1) }) {
            player.select(track: primary)
            selectedAudioID = "audio-\(primary.trackID)"
            decisionLog.record("Audio Track", trackLabel(primary),
                               because: "the file's default track is commentary or described video")
        }

        noteDolbyCapability(player: player)

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
        let remembered = PlaybackMemory.memory(for: meta.id)?.subtitleLanguage
        // The user turned subtitles OFF on this title before; honour that over
        // the global on-by-default.
        if remembered == "off" {
            subtitleAutoApplied = true
            return
        }
        // A language the viewer CHOSE for this title outranks the global
        // switch, in both directions. Infuse-style stickiness: turning
        // subtitles on for one show (anime, usually) keeps them on for the
        // next episode and the next time you come back to it, without turning
        // them on for everything else. `PlaybackMemory` is keyed by the SHOW's
        // meta id, so every episode reads the same entry.
        //
        // Without this, `subtitlesOnByDefault` gated the whole function: the
        // choice was recorded faithfully by `selectSubtitle` and then never
        // read back, so the next episode started with captions off again.
        // "on" = captions were switched on here but the track named no
        // language — turn them on again and let any track satisfy it.
        let stickyOn = remembered?.isEmpty == false
        let stickyLanguage = (stickyOn && remembered != "on") ? remembered : nil
        guard settings.subtitlesOnByDefault || stickyOn,
              !subtitleAutoApplied else { return }
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

        // The title's own remembered language leads; the global preference is
        // what a title with no memory falls back on.
        let want = stickyLanguage ?? settings.preferredSubtitleLanguage
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

    /// Does this subtitle option carry `code`?
    ///
    /// This used to end in `name.contains(code.lowercased())` — the bare
    /// two-letter code, matched ANYWHERE inside the label. "Chinese" and
    /// "Japanese" both contain "es", so a Spanish preference auto-selected the
    /// first Chinese track in the list; "fr" is inside plenty of addon names.
    /// `selectSubtitle` documents this exact trap and deliberately hand-rolls a
    /// stricter match rather than call in here — but the AUTOMATIC pick, which
    /// is the one that runs without anybody asking, kept the loose one.
    ///
    /// `AudioLanguageMatch` has been the whole-word, alias-aware answer all
    /// along ("eng"/"English"/"en" all satisfy an English preference, and
    /// nothing matches on a fragment); it is about language tags, not about
    /// audio, so the subtitle side gets it too.
    private func optionMatchesLanguage(_ option: TrackOption, _ code: String) -> Bool {
        AudioLanguageMatch.matches(code: nil, label: option.displayName, preferred: code)
    }

    /// Pull external subtitles from any installed subtitle addon (e.g.
    /// OpenSubtitles) and add them to the picker alongside embedded tracks.
    private var addonSubtitlesFetched = false
    private func fetchAddonSubtitles() {
        guard !addonSubtitlesFetched else { return }
        let providers = addonManager.subtitleAddons
        guard !providers.isEmpty else {
            // NO subtitle addon installed: the embedded wave was the ONLY
            // wave, and it is over. Bailing before saying so left the
            // "subtitles on by default" fallback waiting forever for addon
            // tracks that were never coming — a preferred language the file
            // doesn't carry meant captions never auto-enabled at all.
            if let wanted = pendingSubtitleReselect {
                pendingSubtitleReselect = nil
                if let option = subtitleOptions.first(where: { $0.id == wanted }) {
                    selectSubtitle(option, userInitiated: false)
                    return
                }
            }
            applyDefaultSubtitleIfNeeded(allowFallback: true)
            return
        }
        addonSubtitlesFetched = true
        let id = currentVideo?.id ?? meta.id
        let type = meta.type
        let generation = loadGeneration
        Task { [weak self] in
            guard let self else { return }
            // Providers are queried CONCURRENTLY. Serially, every addon's round
            // trip was added to the wait before ANY subtitle reached the
            // picker, and a slow or dead one held up the rest behind it —
            // several seconds of an empty Subtitles tab with two or three
            // configured. Results are put back into the user's addon order
            // afterwards so the list still reads the way their settings say.
            let batches: [(offset: Int, name: String, subs: [StremioAPI.AddonSubtitle])] =
                await withTaskGroup(
                    of: (offset: Int, name: String, subs: [StremioAPI.AddonSubtitle]).self
                ) { group in
                    for (offset, addon) in providers.enumerated() {
                        group.addTask {
                            let subs = (try? await StremioAPI.subtitles(
                                addon: addon, type: type, id: id
                            )) ?? []
                            return (offset, addon.manifest.name, subs)
                        }
                    }
                    var out: [(offset: Int, name: String, subs: [StremioAPI.AddonSubtitle])] = []
                    for await batch in group { out.append(batch) }
                    return out.sorted { $0.offset < $1.offset }
                }
            // These belong to the episode that ASKED for them. Several
            // providers in parallel can take seconds, which is long enough to
            // finish an episode and start the next — and these would then be
            // appended to, and auto-selected on, a stream they do not match.
            guard self.isCurrentLoad(generation) else { return }
            var added = false
            for batch in batches {
                // No per-addon cap: an addon that returns 30 tracks with
                // Vietnamese past the 25th used to lose it silently. Every
                // track the addon actually supplied becomes selectable.
                for sub in batch.subs {
                    guard let url = URL(string: sub.url) else { continue }
                    // Canonicalise the tag for the label, but keep the addon's
                    // own tag as the fallback: an unrecognized code shows the
                    // raw tag instead of vanishing or reading "Unknown".
                    let language = AudioLanguageMatch.displayName(for: sub.lang) ?? "Unknown"
                    if let engine = self.vlcEngine {
                        // VLC downloads + renders the sub itself; added without
                        // auto-selecting so the user picks from the panel.
                        engine.addExternalSubtitle(url)
                    } else {
                        let info = URLSubtitleInfo(
                            subtitleID: sub.id ?? sub.url,
                            name: "\(language) · \(batch.name)",
                            url: url
                        )
                        self.subtitleModel.addSubtitle(info: info)
                    }
                    added = true
                }
            }
            guard added else {
                self.pendingSubtitleReselect = nil
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
            // A reload puts the viewer's own track back before anything else
            // gets a say.
            if let wanted = self.pendingSubtitleReselect {
                self.pendingSubtitleReselect = nil
                if let option = self.subtitleOptions.first(where: { $0.id == wanted }) {
                    self.selectSubtitle(option, userInitiated: false)
                    return
                }
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
        // The subtype has to be read through the Swift `mediaSubType` property.
        // `CMFormatDescriptionGetMediaSubType` hands back a bare FourCharCode,
        // and a FourCharCode's `description` is the DECIMAL number: an E-AC-3
        // track stringified to "1700998451", which matches none of the needles
        // below. Detection then rested entirely on `track.name`, and an FFmpeg
        // stream tagged `language=eng` with no title tag is named just "eng" —
        // so rows lost their codec, the "→ PCM" note this function exists to
        // print never appeared, and `atmosCapable` was false for every track,
        // which quietly degraded the Atmos-first tie-break in the preferred-
        // language ranking to a plain highest-channel-count sort: it took the
        // 8ch TrueHD tvOS must decode over the DD+ track it can pass through.
        let sub = track.formatDescription.map {
            $0.mediaSubType.description
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

    /// Learn, from the tracks this session already has in hand, whether this
    /// title ships Dolby that tvOS could BITSTREAM — so the next play routes
    /// straight to the passthrough engine.
    ///
    /// The point is the titles whose add-on stream name says nothing about the
    /// audio: there is no hint to match, so `shouldTryDVFirst` declines and the
    /// file plays as PCM forever. One play now teaches it. Free: the track list
    /// is already built, nothing is probed, and nothing about THIS session
    /// changes — no reload, no switch, no interruption.
    ///
    /// Requires an HEVC video track, DELIBERATELY still — even though the
    /// engine takes H.264 now. A track list cannot see the things the H.264
    /// shape gate declines on (Annex-B extradata, interlacing, anamorphic
    /// SAR), so an H.264 positive recorded here could be wrong, and a wrong
    /// positive buys a doomed probe + engine attempt on every future play.
    /// H.264 titles learn from the engine's own success instead (see the
    /// `DolbyMemory.remember` in `startDVFirst`); HEVC stays safe to learn
    /// here because the engine takes any HEVC shape.
    private func noteDolbyCapability(player: some MediaPlayerProtocol) {
        guard !meta.id.isEmpty, !DolbyMemory.bitstreamable(meta.id) else { return }
        // Too short for the engine to take anyway (`isNoticeClip` rules out
        // anything under three minutes), so remembering it would buy a probe
        // per play that can only ever decline. A duration we don't know yet is
        // not a reason to skip — most sessions know it by now.
        guard duration <= 0 || duration > 180 else { return }
        let hasBitstreamDolby = player.tracks(mediaType: .audio).contains { track in
            let format = Self.audioFormat(track)
            // `atmosCapable` is exactly "DD+ / E-AC-3" — the codec tvOS
            // bitstreams. Plain AC-3 counts too (it is also bitstreamed); it
            // reports `atmosCapable: false` because it carries no Atmos, which
            // is a different question.
            let dolby = (format.codec ?? "").hasPrefix("Dolby Digital")
            return dolby && Self.channelCount(track) > 2
        }
        guard hasBitstreamDolby else { return }
        // Read the subtype as its four-character string, exactly as
        // `audioFormat` does — a FourCharCode's own `description` is the
        // DECIMAL number, which matches nothing (see the note there).
        let hasHEVC = player.tracks(mediaType: .video).contains { track in
            guard let sub = track.formatDescription?.mediaSubType.description
                .trimmingCharacters(in: CharacterSet(charactersIn: "'")).lowercased()
            else { return false }
            // hvc1/hev1 plain HEVC; dvh1/dvhe Dolby Vision HEVC.
            return ["hvc1", "hev1", "dvh1", "dvhe"].contains(sub)
        }
        guard hasHEVC else { return }
        DolbyMemory.remember(meta.id)
        PlayerProbe.event("audio", "learned: this title carries bitstreamable Dolby in HEVC — next play takes the passthrough engine")
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
        showToast("Re-syncing display…")
        // One implementation, shared with the remote command and usable with no
        // player open (see DisplayResync). The session's mode comes from
        // `DisplayResync.sessionTarget`, which this model installs.
        DisplayResync.force(reason: "gesture")
    }

    // MARK: - Experimental Atmos passthrough

    /// Start the AVPlayer audio path when the track is E-AC-3/AC-3, the setting
    /// is on, and the route is HDMI. The sample engine's own audio is muted so
    /// only the AVPlayer is heard; the video clock is nudged onto the audio
    /// clock. Any failure leaves the normal engine untouched.
    private func startAtmosPassthroughIfEligible(
        engine: DVSampleEngine, entry: StreamEntry, resume: Double
    ) {
        // Only for a track the container actually declares Atmos, so an
        // ordinary DD+ 5.1 title doesn't pay for a second read of the source.
        guard settings.atmosPassthrough, atmosPassthrough == nil,
              let urlString = entry.stream.url,
              engine.audioPath.passthrough,
              engine.audioPath.sourceSaysAtmos,
              ["eac3", "ac3"].contains(engine.audioPath.codec.lowercased()),
              AudioOutputCapability.routeDescription.lowercased().contains("hdmi")
        else { return }
        let passthrough = AtmosPassthrough()
        passthrough.onError = { [weak self] message in
            PlayerProbe.event("atmos", "passthrough failed: \(message) — restoring engine audio")
            self?.dvDirectEngine?.setMuted(false)
            self?.stopAtmosPassthrough()
        }
        passthrough.onReady = { [weak self, weak engine] in
            guard let self, let engine, self.dvDirectEngine === engine, !self.isExiting else { return }
            // The AVPlayer owns the audio now; silence the sample renderer so
            // the two don't play over each other.
            engine.setMuted(true)
            passthrough.play()
            self.startAtmosSync(engine: engine, passthrough: passthrough)
            PlayerProbe.event("atmos", "passthrough READY — AVPlayer owns the \(engine.audioPath.codec) audio")
        }
        passthrough.start(
            inputURL: urlString,
            headers: entry.stream.behaviorHints?.proxyHeaders?.requestHeaders,
            startAt: resume,
            trackIndex: engine.currentAudioIndex
        )
        atmosPassthrough = passthrough
        PlayerProbe.event("atmos", "passthrough starting for \(engine.audioPath.codec)")
    }

    /// Keep the picture on the audio clock. A 0.2s threshold means only a real
    /// drift is corrected, so the synchronizer isn't re-timed every second.
    private func startAtmosSync(engine: DVSampleEngine, passthrough: AtmosPassthrough) {
        atmosSyncTask?.cancel()
        atmosSyncTask = Task { @MainActor [weak self, weak engine] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let engine, !self.isExiting,
                      self.dvDirectEngine === engine, self.atmosPassthrough === passthrough
                else { return }
                // A seek was just issued and the AVPlayer audio is still
                // catching up: nudging now would undo the seek. Give it a beat
                // to land (both were seeked in `engineSeek`).
                if Date().timeIntervalSince(self.lastSeekIssuedAt) < 2 { continue }
                let want = passthrough.currentTime
                let have = engine.currentClockSeconds
                if abs(want - have) > 0.2 {
                    engine.alignClock(to: want)
                    PlayerProbe.event("atmos", String(format: "sync nudge %+.2fs (video %.2f → audio %.2f)",
                                                      want - have, have, want))
                }
            }
        }
    }

    private func stopAtmosPassthrough() {
        atmosSyncTask?.cancel()
        atmosSyncTask = nil
        atmosPassthrough?.stop()
        atmosPassthrough = nil
    }

    /// Best-effort display criteria for the manual re-sync when the session
    /// never pinned one. Mirrors the direct engine's HDR10 request: the content
    /// rate when it is real, clamped to a mode the panel advertises.
    private func recoveredDisplayCriteria() -> AVDisplayCriteria? {
        var range: DynamicRange?
        if let track = playerLayer?.player.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? playerLayer?.player.tracks(mediaType: .video).first,
           let dr = track.dynamicRange {
            range = dr
        } else if dvDirectIsPQ {
            range = .hdr10
        }
        guard var r = range, r != .sdr else { return nil }
        let available = DynamicRange.availableHDRModes
        if !available.contains(r) {
            if available.contains(.hdr10) { r = .hdr10 }
            else if available.contains(.hlg) { r = .hlg }
            else { return nil }
        }
        let fps: Float = dvDirectEngine?.videoFPS
            ?? (playerLayer?.player.tracks(mediaType: .video).first?.nominalFrameRate ?? 0)
        // Same range-only policy as the normal request: keep the panel's rate
        // unless the viewer opted into frame-rate matching.
        let rate = (settings.matchFrameRate && SessionDisplayMode.isPlausibleRate(fps))
            ? SessionDisplayMode.snapToBroadcastRate(fps)
            : Float(UIScreen.main.maximumFramesPerSecond)
        return AVDisplayCriteria(refreshRate: rate, videoDynamicRange: r.rawValue)
    }

    func togglePlayPause() {
        // The triple-press display re-sync is checked FIRST, before every other
        // guard: the HDMI wedge leaves the WHOLE screen grey and this is the
        // only way out of it, so it has to be reachable even while the player
        // is exiting or mid post-background resync.
        playPausePressTimes.append(Date())
        playPausePressTimes.removeAll { Date().timeIntervalSince($0) > 2.0 }
        if playPausePressTimes.count >= 2 {
            PlayerProbe.event("transport", "⏯ press \(playPausePressTimes.count) within 2.0s"
                + " (3 triggers the blind display re-sync)")
        }
        if playPausePressTimes.count >= 3 {
            playPausePressTimes.removeAll()
            resyncDisplay()
            return
        }
        // Ignore input while exiting, or during the sub-second post-background
        // resync (a play press then would race the in-flight flush-seek).
        guard !isExiting, !isResyncing else {
            PlayerProbe.event("transport", "⏯ IGNORED (exiting=\(isExiting.probe) resyncing=\(isResyncing.probe))")
            PlayerProbe.count("transport.press-ignored")
            return
        }
        // Nothing to toggle before the first frame — and during the DV
        // display-mode hold a ⏯ press here started the engine mid-handshake
        // (audio over black, video attaching while the panel link-trains).
        // Every other transport entry point already carries this gate.
        if pictureInPicture.isActive { PictureInPictureController.trail("togglePlayPause (PiP active) playing=\(isPlaying)") }
        guard acceptsTransportInput else {
            // The gate that eats a ⏯ before the first frame or during the DV
            // display handshake. Silent by design, which is exactly why it has
            // to be visible here — otherwise it looks like a dead button.
            PlayerProbe.event("transport", "⏯ REFUSED by acceptsTransportInput"
                + " (started=\(hasStartedPlayback.probe) overlay=\(overlay.probeName))")
            PlayerProbe.count("transport.press-refused")
            return
        }
        // If a fast-forward/rewind preview is up, Play commits it (seek + resume).
        // DECIDE ON INTENT, NOT ON WHETHER THE ENGINE MANAGED TO START.
        //
        // After a seek that asked for playback the engine can sit stopped for a
        // beat — on some sources it drops the autoplay every single time (see
        // `armSeekPlayWatchdog`). `isPlaying` is false through that window, so a
        // ⏯ press meant to PAUSE was read as RESUME: the button appeared to do
        // nothing, and the film started instead. Both halves of "the pause
        // button isn't working" and "it keeps unpausing when I don't".
        //
        // Once playback has started at all, "we are not intending to be paused"
        // is the honest reading of what the viewer is looking at.
        // …but only while the stream is LIVE. A finished film and a failed one
        // both sit stopped with no pause intent, and there ⏯ has always meant
        // "start again" / "retry" — reading them as a pause would turn the
        // press into a no-op on exactly the screens where it matters most.
        let stoppedForGood = playedToEndHandled || { if case .error = overlay { return true }; return false }()
        // A finished title: ⏯ is Replay, the same action the post-play card
        // offers. Falling through to `resumePlayback` here asked the engine to
        // resume from a position that IS the end — it played the last moment
        // and finished again, which reads as the button doing nothing.
        if playedToEndHandled, overlay == .postPlay || overlay == .upNext {
            replay()
            return
        }
        PlayerProbe.event("transport", "⏯ playing=\(isPlaying.probe) pauseIntent=\(pauseIntent.probe)"
            + " started=\(hasStartedPlayback.probe) stoppedForGood=\(stoppedForGood.probe)"
            + " → \(isPlaying || (!pauseIntent && hasStartedPlayback && !stoppedForGood) ? "PAUSE" : "RESUME")")
        if isPlaying || (!pauseIntent && hasStartedPlayback && !stoppedForGood) {
            enginePause("viewer pressed play/pause")
            // Pausing is the moment a viewer is most likely to leave — by the
            // remote, by the TV button, or by pulling the plug. Publish the
            // position here rather than relying on the exit path being reached,
            // so "I paused two minutes in and came back later" always resumes.
            saveProgress()
            // Infuse: pausing leaves the transport up (title, bar, times) and
            // it stays up until playback resumes — restartHideTimer never
            // hides while paused.
            if overlay == .none {
                overlay = .controls
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
        // The stale-connection premise is VOID under the hybrid cache: the
        // proxy never drops a merely-paused reader (its 25s stall timeout is
        // for readers actively waiting on a dead download), and even a dropped
        // localhost socket reconnects instantly at the demuxer's own offset,
        // served from disk. Firing the reconnect-rewind here anyway is what
        // made every real pause (>12s) resume SEVERAL SECONDS BACK — the 1s
        // rewind snaps to the previous keyframe with inaccurate seek, and web
        // encodes carry 5-10s GOPs — then chop forward to catch up.
        // …and that premise is void again after a SUSPENSION. It holds while
        // the app is RUNNING: the proxy is still serving and a localhost socket
        // reconnects instantly. It does not hold once tvOS has frozen the
        // process for minutes — the download workers are gone, the cache's
        // stall clocks are wall-clock, and the first read after the wake can
        // fail the session outright. Playing in place there is the press that
        // does nothing, so take the reconnect-rewind this branch exists for.
        let proxied = currentURL?.host == "127.0.0.1"
            && MediaCacheServer.shared.hasLiveSession
            && !didSuspendSincePlay
        let connectionLikelyStale = idleSeconds >= staleResumeThreshold && !proxied
        // The DV-direct engine has no KSPlayerLayer, so it was taking the plain
        // play path this reconnect exists to avoid.
        let canReconnectBySeek = usingVLC || usingDVDirect || (playerLayer?.player.seekable ?? false)
        PlayerProbe.event("transport", String(
            format: "RESUME idle=%.0fs proxied=%@ stale=%@ canSeek=%@ → %@",
            idleSeconds, proxied.probe, connectionLikelyStale.probe, canReconnectBySeek.probe,
            (connectionLikelyStale && canReconnectBySeek) ? "reconnect-rewind" : "play in place"))
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
            // ARM THE WATCHDOG HERE TOO. This path calls `engineSeek` directly
            // rather than going through `seek(to:)`, so it was the one
            // play-requesting seek with no rescue behind it — and it is the
            // likeliest to need one, because it only runs after a long idle,
            // exactly when the socket is stale and the demuxer seek is most
            // likely to be refused. A dropped autoplay there is the viewer
            // pressing Play and nothing happening.
            armSeekPlayWatchdog()
        } else {
            enginePlay()
        }
        didSuspendSincePlay = false
    }

    func skip(_ seconds: Double) {
        PlayerProbe.event("seek", String(format: "skip %+.0fs from %.1f", seconds, position))
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
        // ANY seek supersedes a nudge still sitting on its debounce.
        //
        // `nudgeSeek` gathers a run of skip presses and commits them 650ms
        // later, as `position + pendingSeekDelta`. Nothing cancelled that when
        // another transport action took over, so clicking into the bar within
        // that window — scrub, land somewhere, commit — was followed a beat
        // later by the stale delta firing against the NEW position: a jump
        // out of nowhere, right after a seek the viewer had just made. That is
        // the phantom skip after scrubbing.
        if pendingSeekDelta != 0 {
            PlayerProbe.event("nudge", String(format: "dropped a stale pending nudge of %+.1f",
                                              pendingSeekDelta))
        }
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekDelta = 0
        nudgeStreak = 0
        let target = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        PlayerProbe.event("seek", String(format: "SEEK %.1f -> %.1f autoPlay=%@ (was playing=%@)",
                                         position, target,
                                         autoPlay.map { $0 ? "Y" : "n" } ?? "keep", isPlaying.probe))
        position = target
        clock.position = target   // instant UI feedback, no waiting for a tick
        lastUserSeekAt = Date()
        // The user's own seek replaces the resume target outright (including
        // seeking BACKWARDS — otherwise the floor would drag them forward again
        // on the next failover).
        sessionResumeFloor = target
        // …and retires `pendingResume` with it. The in-flight resume seek's
        // completion is NOT guaranteed (a superseding seek overwrites
        // KSPlayer's stored completion handler), so a stale target could
        // otherwise pin every save above a deliberate rewind for the whole
        // session and yank a failover back up to it. `position = target` was
        // just set, so the saves lose nothing.
        pendingResume = nil
        // A rewind carries the VERDICT's baseline down with it. `recordLinkVerdict`
        // measures `position - sessionStartPosition`, so a session that ended below
        // where it began — resume at 1h20m, drop back to 40m, watch twenty minutes,
        // leave — computed a negative span, clamped it to 0, and REJECTED the link
        // that had just played fine; the next press of Play then skipped it for the
        // eight-hour TTL and the selector served a worse source. Same miscount the
        // episode-change and replay re-bases already fix, one seek earlier.
        // Downwards only: seeking FORWARD must not discard the evidence behind it.
        sessionStartPosition = min(sessionStartPosition, target)
        playedToEndHandled = false
        // Default from INTENT, not from raw `isPlaying`. After a seek whose
        // autoplay the engine dropped, `isPlaying` is false while the viewer
        // is looking at a picture that is supposed to be running; a skip taken
        // then would decide "we were paused" and leave it stopped for good.
        // Same reasoning as `togglePlayPause` — see its comment.
        let play = autoPlay ?? (isPlaying || (!pauseIntent && hasStartedPlayback))
        // engineSeek starts playback itself, bypassing enginePlay, so the
        // intent has to be cleared here or the buffer events that follow the
        // seek would be read as "still paused".
        if play { pauseIntent = false }
        engineSeek(to: target, autoPlay: play)
        if play { armSeekPlayWatchdog() }
    }

    private var seekPlayWatchdog: Task<Void, Never>?

    /// Make sure a seek that was supposed to resume actually did.
    ///
    /// `KSPlayerLayer.seek` only plays `if finished` — a demuxer seek FFmpeg
    /// refuses (a range the proxy couldn't serve yet) reports `false` and the
    /// autoplay is dropped on the floor, leaving the picture parked at the new
    /// position with nothing on screen to say why. And a seek superseded while
    /// another is in flight never calls its completion at all, because
    /// `MEPlayerItem.seek` overwrites the stored handler. Either way the viewer
    /// is left pressing play again after a scrub — which is the report.
    ///
    /// So don't ask the engine whether it worked; look at whether the picture
    /// is moving, and start it if it isn't.
    private func armSeekPlayWatchdog() {
        seekPlayWatchdog?.cancel()
        seekPlayWatchdog = Task { [weak self] in
            // A GRACE PERIOD, THEN POLL.
            //
            // The engine reports `.seeking` without reliably surfacing a
            // buffering state, so "settled and stopped" can read true while the
            // seek is still running — and `enginePlay()` landing inside a seek
            // is the trap `scanCommit` and `resumePlayback` both document: it
            // stomps KSMEPlayer's `.seeking` back to `.playing`, the seek then
            // flushes audio only, and the picture freezes while the sound
            // carries on. On the device this was firing 0.4s after a commit,
            // which is well inside a seek.
            //
            // Nothing is lost by waiting: a dropped autoplay is a steady state,
            // not a race, so it is exactly as rescuable a second later.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for _ in 0..<20 {
                guard !Task.isCancelled, let self, !self.isExiting else { return }
                // Anything that legitimately owns the transport in the
                // meantime — the viewer pausing, a scan preview, a new scrub,
                // a source switch — settles it, and this stands down.
                guard !self.pauseIntent, !self.isScrubbing,
                      !self.isSwitchingSource else { return }
                if self.isPlaying { return }   // it took, as it usually does
                // Still opening, or the seek is still in flight: look again.
                if self.hasStartedPlayback, !self.isBuffering {
                    // Settled, stopped, and nobody asked for it: the engine
                    // dropped the autoplay. `KSPlayerLayer.seek` only plays `if
                    // finished`, so a demuxer seek FFmpeg refuses (a range the
                    // proxy could not serve yet) loses it — and a seek
                    // superseded while another is in flight never calls its
                    // completion at all, because `MEPlayerItem.seek` overwrites
                    // the stored handler. Either way the viewer is left
                    // pressing play again after a scrub, which is the report.
                    PlayerProbe.event("seek", "WATCHDOG: autoplay never took — starting playback")
                    NSLog("[OrivioPlayer] seek autoplay never took — starting playback")
                    Self.dvTrail("seek autoplay dropped by the engine — starting playback")
                    self.enginePlay()
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            // LAST RESORT, and the one the wake case needs. The poll above can
            // only act once the engine reports it has stopped buffering — and
            // after a wake it never does: `resyncPipeline`'s autoPlay:false
            // flush-seek leaves the engine in `.buffering`, and a PAUSED engine
            // never pumps enough to report its way back out (measured on the
            // device; the buffer spinner carries the same note). So the loop
            // ran out and returned in silence, leaving the viewer pressing play
            // at a spinner that never clears. Nine seconds in, any real seek is
            // long over — the reason this rescue waits at all — so ask once.
            guard !Task.isCancelled, let self, !self.isExiting,
                  !self.pauseIntent, !self.isScrubbing, !self.isSwitchingSource,
                  !self.isPlaying else { return }
            PlayerProbe.event("seek", "WATCHDOG: still stopped after the poll window — starting playback")
            NSLog("[OrivioPlayer] seek autoplay never took (engine still buffering) — starting playback")
            Self.dvTrail("seek autoplay never took while buffering — starting playback")
            self.enginePlay()
        }
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
        noteSceneWindow(at: value)
    }

    /// Whether the scene window had a frame at the last publish, so the probe
    /// can report the moment it appears or disappears rather than a level
    /// sampled every couple of seconds. This is the exact thing the view asks
    /// for (`thumbnail(at:)` non-nil is what draws the window), reported at the
    /// rate it actually changes.
    private var sceneWindowHadFrame: Bool?
    private func noteSceneWindow(at target: Double) {
        #if DEBUG
        let has = thumbnail(at: target) != nil
        guard has != sceneWindowHadFrame else { return }
        sceneWindowHadFrame = has
        PlayerProbe.event("preview", String(
            format: "scene window %@ at %.0fs (coarse=%d fine=%d)",
            has ? "SHOWN" : "GONE — no frame near this position",
            target, scrubThumbnails.count, fineThumbnails.count))
        #endif
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
    private func debug(_ s: String) {
        // Mirrored into the live probe unconditionally. This one line is the
        // whole remote-input trace: every gesture decision in the player
        // already narrates itself here for the on-screen debug label, and
        // routing it to the probe as well means a live session can see which
        // branch a press took without the yellow overlay being switched on.
        PlayerProbe.event("remote", s)
        if settings.showInputDebug { inputDebug = s }
    }
    /// Public debug hook for the view's move-command / click paths.
    func noteInput(_ s: String) { debug(s) }

    /// A trackpad swipe ALSO emits an `.onMoveCommand`; suppress those briefly
    /// after handling a gesture so they don't double-fire.
    private var suppressMoveUntil = Date.distantPast
    var moveSuppressed: Bool { Date() < suppressMoveUntil }
    private func suppressMoveBriefly() { suppressMoveUntil = Date().addingTimeInterval(0.4) }

    /// Pan translation (points) → seconds for scrub.
    ///
    /// The film is `scrubPointsAcrossFilm` points of travel wide. Raising that
    /// number makes the same finger movement cover less time — a slower, finer
    /// scrub — which is what you want on a long title, where the original 3200
    /// put a two-and-a-half-hour film under one swipe and made landing on a
    /// scene a matter of luck.
    private static let scrubPointsAcrossFilm: Double = 4800
    /// Floor, so a short title doesn't end up needing several swipes to cross.
    private static let scrubMinSecondsPerPoint: Double = 0.25
    private var secondsPerPoint: Double {
        guard duration > 0 else { return 0.5 }
        return max(duration / Self.scrubPointsAcrossFilm, Self.scrubMinSecondsPerPoint)
    }

    private enum TouchIntent { case undecided, scrub, consumed }
    private var touchIntent: TouchIntent = .undecided
    /// The Skip Intro pill took focus during THIS gesture. It then takes a
    /// much longer pull to scroll past it, so the same nudge that grabbed the
    /// pill can't immediately overshoot into the transport controls.
    private var skipFocusTakenThisGesture = false

    // Called by RemoteTouchCatcher.

    /// Focus was on the sheet's pills when this touch started. A swipe that
    /// carries focus from the rows up onto the pills must not ALSO count as
    /// the close gesture, so the close reads the state at touch-down.
    private var infoTabsAtTouchStart = false

    func remoteTouchBegan() {
        debug("touch ↓")
        infoTabsAtTouchStart = infoFocusOnTabs
        scrubLastDx = 0            // translation resets per gesture
        panInFlight = true
        lastPanDx = 0
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
        lastPanDx = dx
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
            // With the transport up, a swipe down from anything above the
            // bar (a glyph, a popover row) is focus moving down to the bar —
            // the focus engine is handling it. Only from the bar itself,
            // and only a real pull, does it open the sheet.
            let transportUp = overlay == .controls || overlay == .pauseInfo
            if transportUp, ady > adx, dy > 0 {
                if !controlsFocusOnBar { touchIntent = .consumed; debug("swipe↓ (focus move)"); return }
                guard ady > 110 else { return }
            }
            touchIntent = .consumed
            if skipIntroFocused, ady > adx {
                // Kept scrolling off the pill → hand over to the transport
                // controls, which is what sits "below" it on screen.
                debug("swipe past skip → controls")
                skipIntroFocused = false
                showControls()
            } else if overlay == .info {
                // Only from the pills, and only a real pull — the focus engine
                // is reading the same swipe, and a nudge up from the rows is
                // the move to the pills, not a dismissal.
                if ady > adx, dy < -160, infoTabsAtTouchStart, infoFocusOnTabs {
                    debug("swipe↑ close info")
                    dismissInfoPanel()
                }
            } else if ady > adx {
                if dy > 0 { debug("swipe↓ info"); showInfoPanel() }
                else { debug("swipe↑ controls"); showControls() }
            } else if adx < ady * 1.4 {
                // Ambiguous diagonal: not clearly horizontal, not clearly
                // vertical. A pull-down that drifted right used to cross the
                // 45pt threshold with adx barely ahead and fire a ±10s SKIP —
                // "opening the pull-down menu made the film jump". A skip is
                // a destructive action; it must be unmistakably horizontal.
                // Stay undecided and let the next samples pick a winner.
                touchIntent = .undecided
            } else if overlay == .none
                        || ((overlay == .controls || overlay == .pauseInfo) && controlsFocusOnBar) {
                // A horizontal swipe is a skip — the configured amount (10s
                // by default), back or forward with the direction. Scrubbing
                // is entered by PRESSING the bar; that touch is `.scrub` from
                // the start and never reaches here.
                //
                // ONLY FROM THE BAR when the transport is up. With focus on a
                // track glyph the same swipe was still seeking, so one gesture
                // meant "move along the glyphs" or "jump ten seconds" depending
                // on where focus happened to be — invisible state deciding what
                // a physical action does. On a glyph the swipe now belongs to
                // the focus engine, which is what the viewer can actually see.
                // AND IT MUST BE A REAL PULL, not the roll of a finger
                // settling into a click. 45pt is the gate for DECIDING a
                // direction; it is nowhere near enough to COMMIT on. Every
                // other navigational gesture in this method already asks for a
                // deliberate pull — 110pt to open the info sheet, 160pt to
                // close it — while the one gesture that MOVES THE PLAYHEAD
                // fired at 45. That is why tapping to bring up the controls
                // occasionally jumped the film: a tap on this remote is a pad
                // PRESS with a finger on the surface, and the finger rolls a
                // few dozen points sideways as it presses. Held to the same
                // floor as the sheet-close pull.
                //
                // Undecided, NOT consumed — the same thing the ambiguous
                // diagonal above does. A gesture that really is a swipe keeps
                // being re-read on every later sample and skips the moment it
                // grows past the floor, so a deliberate swipe still lands;
                // only the short one is dropped.
                guard adx > 160 else { touchIntent = .undecided; return }
                let step = Double(settings.skipSeconds)
                debug(dx > 0 ? "swipe→ skip" : "swipe← skip")
                nudgeSeek(dx > 0 ? step : -step, gesture: true)
            }
        }
    }

    func remoteTouchEnded(dx: CGFloat, dy: CGFloat) {
        panInFlight = false
        scrubDragInContact = false   // the contact is over; presses now hop
        if touchIntent == .scrub { endScrubGesture() }
        touchIntent = .undecided
    }

    /// Pan scrub via INCREMENTAL deltas so it composes cleanly with the wheel
    /// (both just nudge `scrubValue`) and so consecutive drags never jump. Track
    /// the last translation even while the wheel owns the scrub, so handing back
    /// to pan doesn't lurch.
    private var scrubLastDx: CGFloat = 0
    /// A pan is between .began and .ended right now, and its latest translation.
    /// Kept for EVERY intent, not just `.scrub`, so a scrub started mid-gesture
    /// can pick the finger up where it already is.
    private var panInFlight = false
    private var lastPanDx: CGFloat = 0
    private func scrubPanPoints(dx: CGFloat) {
        let inc = dx - scrubLastDx
        scrubLastDx = dx
        guard let target = scrubValue, !wheelEngaged else { return }
        let proposed = target + Double(inc) * secondsPerPoint
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        scrubDragInContact = true
        publishScrub(clamped)
        // Moved out of the dense window — fetch the next one once you stop.
        requestFineThumbnails(around: clamped)
        restartScrubTimeout()
    }

    /// Playback was running when a bar click opened this scrub — the commit
    /// (and a cancel) put it back.
    private var resumeAfterScrub = false

    /// This CONTACT (finger-down to lift) has dragged the scrub target — by
    /// pan or by wheel. A directional press during such a contact is the
    /// commit click at the end of that drag (see `scrubJump`); a press on a
    /// fresh contact that has not dragged is a deliberate hop. Cleared on
    /// lift, so lift-then-press always hops.
    private var scrubDragInContact = false

    /// Enter scrub mode. `pausing` is the bar-click entry (Infuse: click
    /// pauses, the picture scrubs, the next click seeks and resumes); a swipe
    /// scrubs over whatever the transport is doing.
    func beginScrub(pausing: Bool = false) {
        guard acceptsTransportInput else { return }
        guard overlay == .none || overlay == .controls || overlay == .pauseInfo else { return }
        var start = position
        if pausing, isPlaying {
            enginePause("bar click opening a scrub")
            markPaused()
            saveProgress()
            resumeAfterScrub = true
        } else {
            resumeAfterScrub = false
        }
        // ADOPT A GESTURE ALREADY IN FLIGHT. `touchIntent` is decided when the
        // touch BEGINS, so a finger already on the pad when the bar is clicked
        // stayed `.undecided`/`.consumed` and its movement never reached
        // `scrubPanPoints`: you clicked, kept dragging, and nothing followed
        // your finger until you lifted and touched again. Seeding `scrubLastDx`
        // with the translation so far keeps it incremental — without it the
        // first sample would jump by everything the pan had already travelled.
        if panInFlight {
            touchIntent = .scrub
            scrubLastDx = lastPanDx
        }
        // BUILD THE DENSE SET NOW, not on a debounce.
        //
        // The only unconditional start was on WHEEL ENGAGE — a deliberate hold.
        // Every other route went through `requestFineThumbnails`, whose 300ms
        // debounce is cancelled by each pan sample and then checks `isScrubbing`
        // when it fires: an ordinary swipe-and-release cancels it all the way to
        // the lift and finds the scrub already over. The probe said so for a
        // whole session — `fine=0 fineCentre=-`, the pass had never run once, so
        // the preview window had nothing but the handful of sparse coarse frames
        // to draw and almost always found none near the finger.
        startFineThumbnailsIfNeeded(around: start)
        overlay = .none
        position = start
        scrubAnchor = start
        scrubValue = start
        clock.scrubTarget = start
        // A skip still on its debounce would fire mid-scrub and move the
        // picture out from under the target the viewer is aiming at.
        seekDebounceTask?.cancel()
        seekDebounceTask = nil
        pendingSeekDelta = 0
        nudgeStreak = 0
        isScrubbing = true
        scrubDragInContact = false   // only a real drag arms the commit click
        sceneWindowHadFrame = nil
        PlayerProbe.event("scrub", String(format: "BEGIN at %.1f (%@, resume=%@)",
                                          start, pausing ? "bar click" : "swipe",
                                          resumeAfterScrub.probe))
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
        PlayerProbe.event("scrub", String(format: "COMMIT -> %.1f (plays)", target))
        resumeAfterScrub = false
        // COMMITTING A SCRUB ALWAYS PLAYS.
        //
        // It used to resume only when the scrub had done the pausing itself, so
        // scrubbing from an already-paused player landed on the frame and
        // waited for a separate play press — the "I have to press play after
        // scrubbing" half of the report that survived every other fix.
        //
        // It is also not what the bar's own grammar says: click pauses, the
        // picture scrubs, the next click seeks AND RESUMES. Having deliberately
        // paused HERE is not a request to be left paused somewhere else — and
        // `cancelScrub` is still the way to change your mind, restoring exactly
        // the state the scrub found.
        pauseIntent = false
        pausedAt = nil
        seek(to: target, autoPlay: true)
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
        PlayerProbe.event("scrub", "CANCEL")
        // "Never mind" puts playback back the way the click found it.
        if resumeAfterScrub {
            resumeAfterScrub = false
            resumePlayback()
        } else if !isPlaying {
            // Cancelling a scrub the viewer started while ALREADY paused has
            // nothing to resume — and dropping the HUD then left a frozen frame
            // with no transport on it and no indication anything is paused.
            // The bar is the only thing that says so.
            overlay = .controls
        }
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
        // A CLICK ON THE RIM AT THE END OF A DRAG IS THE COMMIT CLICK.
        //
        // The Siri Remote reports a press near the EDGE of the pad as a
        // directional press, not Select. A thumb that has just dragged the
        // scrubber and clicks where it stopped — out toward the edge, which is
        // where a drag ends — arrived here as Left/Right, and the target
        // hopped a full jump at the very moment the viewer expected it to
        // seek: "I scrub, click, and it lands somewhere else".
        //
        // But ONLY a click that belongs to a drag. The first cut of this
        // committed on any press with a finger on the pad (`wheelTouching`),
        // which broke press-hopping outright: rest the thumb, press an edge
        // to hop a minute, and the scrub committed instead — "at first any
        // sort of scrubbing doesn't work". The signal that separates the two
        // is the CONTACT: a press during the same finger-down that dragged
        // the target is the viewer clicking where they stopped; lift first,
        // and every press is a deliberate hop. (Presses within 0.4s of a pan
        // sample never reach here — `moveSuppressed` eats them.)
        if scrubDragInContact {
            PlayerProbe.event("scrub", "rim press at the end of a drag -> commit")
            noteSelectPressed()
            commitScrub()
            return
        }
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        PlayerProbe.event("scrub", String(format: "jump %+.0f -> %.1f", seconds, clamped))
        publishScrub(clamped)
        requestFineThumbnails(around: clamped)   // a minute clears the window
        restartScrubTimeout()
    }

    // MARK: - Wheel fine-tune (rest a finger on the pad, then circle)

    /// True once the wheel has taken the pad — fine-tune mode. Drives the
    /// on-screen indicator and locks out every other scrub input.
    @Published private(set) var wheelEngaged = false
    private var wheelLastAngle: Double?
    /// Where the current stationary contact landed, so the knob can appear
    /// under the finger rather than at some default angle.
    private var wheelHoldOrigin: (x: Double, y: Double)?
    /// How long a finger has to sit on the outer ring before the wheel takes
    /// over. A beat, not a wait — long enough that swiping THROUGH the rim
    /// during a side-to-side scrub doesn't trigger it.
    private let wheelHoldSeconds: TimeInterval = 0.15
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
    // (`wheelAwaitingLift` and `wheelHoldSlop` used to live here, for a rule
    // the REVISED note in `wheelSample` explains was deliberately dropped —
    // no touch is disqualified any more, and the contact already on the pad
    // when the bar was clicked arms the hold like any other. Both were still
    // being written and never read; their doc comments described guards that
    // no longer existed, which is worse than no comment at all.)
    /// One full revolution ≈ this many seconds — small, because it's FINE tuning.
    private let wheelSecondsPerRevolution: Double = 24

    /// GameController absolute finger position ((0,0) = not touching).
    private func wheelSample(x: Double, y: Double) {
        guard isScrubbing else { resetWheel(); return }
        let radius = (x * x + y * y).squareRoot()

        // Finger LIFTED → leave fine-tune; normal pan owns the scrub again.
        //
        // Acted on immediately, on a SINGLE sample. It has to be one: the pad
        // only reports on VALUE CHANGE, so lifting produces exactly one (0,0)
        // event and then silence. An earlier version wanted two consecutive
        // near-zero readings; the second never came, so the wheel stayed
        // engaged after you took your thumb off and scrubbing was dead until
        // you touched and lifted again. (The counter that implemented that rule
        // survived as `if samples >= 1` after incrementing from 0 — always
        // true, and only ever read here. It is gone.)
        //
        // The 0.02 threshold is deliberately near zero: at the old 0.1 a finger
        // passing near the middle of the pad on its way round crossed it, so
        // one sloppy circle dropped out of fine-tune and the rest of that same
        // gesture landed on the pan recognizer as a coarse scrub.
        if radius < 0.02 {
            wheelTouching = false
            scrubDragInContact = false   // lift: the next press is a hop
            wheelHoldTask?.cancel()
            wheelHoldTask = nil
            wheelEngaged = false
            wheelLastAngle = nil
            wheelHoldOrigin = nil
            // A lift IS activity. While the finger rests the timeout is re-armed
            // on every pass (resting generates no samples, so it must be), but
            // nothing re-armed it on the way OUT — so a long rest followed by a
            // lift could leave only the remainder of a six-second window, and
            // the scrub expired a moment after the viewer took their thumb off,
            // mid-adjustment.
            restartScrubTimeout()
            // The dense frames STAY. Lifting off the wheel is a pause in
            // the middle of one adjustment, not the end of it — you drop
            // back to coarse scrubbing and are expected to rest again a
            // moment later. Throwing them away here meant re-running a
            // decode pass every single time.
            return
        }
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
        //
        // REVISED: the pad only reports CHANGES, so "resting on the ring" is
        // the absence of further samples. Every sample on the ring (re)arms
        // the beat, a sample off the ring cancels it, and a finger that is
        // still moving simply keeps pushing the beat back — no touch is ever
        // disqualified, and the finger that was already down when the bar was
        // pressed counts like any other (no lift needed first).
        if !wheelEngaged {
            if radius > wheelRingRadius {
                wheelHoldOrigin = (x, y)
                armWheelHold()
            } else {
                wheelHoldTask?.cancel()
                wheelHoldTask = nil
                wheelHoldOrigin = nil
            }
            return   // the timer engages, not this sample
        }
        // Engaged: the knob follows the finger wherever it is on the pad.
        let angle = atan2(y, x)
        clock.wheelAngle = angle
        // Near dead-center atan2 is noisy and flips direction — pause the angle
        // there (don't jump) but STAY engaged; re-anchor when it recovers.
        guard radius > 0.22 else { wheelLastAngle = nil; return }
        defer { wheelLastAngle = angle }
        guard let last = wheelLastAngle, let target = scrubValue else { return }
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        guard abs(delta) < 1.0 else { return }   // sample glitch, ignore
        // Clockwise = forward (screen coords: clockwise decreases atan2 angle).
        let seconds = -delta / (2 * .pi) * wheelSecondsPerRevolution
        let proposed = target + seconds
        let clamped = max(0, min(proposed, duration > 0 ? duration - 1 : proposed))
        scrubDragInContact = true
        publishScrub(clamped)
        // Follow the finger out of the covered window, exactly as the pan does.
        // The dense pass was started ONCE, when the wheel engaged, and never
        // re-centred while it turned — so fine-tuning past the edge of that
        // first window ran out of close-up frames and the preview stopped
        // updating, which is the mode it matters most in.
        requestFineThumbnails(around: clamped)
        restartScrubTimeout()
    }

    /// Arm the rest-to-engage timer for the touch that just landed.
    private func armWheelHold() {
        wheelHoldTask?.cancel()
        wheelHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.wheelHoldSeconds ?? 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isScrubbing, self.wheelTouching, !self.wheelEngaged else { return }
            // Only a FRESH rest takes the wheel. A drag that pauses on the rim
            // — stopping to read the preview frame, thumb still down at the
            // pad's edge where drags naturally end — used to engage it after
            // 0.15s: pan scrубbing then went dead (the wheel owns the pad) and
            // horizontal motion turned into slow angle deltas, which read as
            // "scrubbing stopped working". Lift and rest again to fine-tune.
            guard !self.scrubDragInContact else { return }
            self.wheelEngaged = true
            PlayerProbe.event("scrub", "WHEEL engaged")
            self.wheelLastAngle = nil
            // The knob appears under the finger, not at some default angle.
            if let origin = self.wheelHoldOrigin { self.clock.wheelAngle = atan2(origin.y, origin.x) }
            self.startFineThumbnailsIfNeeded(around: self.scrubValue ?? self.position)
        }
    }

    private func resetWheel() {
        wheelHoldTask?.cancel()
        wheelHoldTask = nil
        wheelLastAngle = nil
        wheelEngaged = false
        wheelTouching = false
        wheelHoldOrigin = nil
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
    /// A Select CLICK happened during this contact.
    ///
    /// A click on the Siri Remote is a touch landing, the pad depressing, and
    /// the finger lifting — so the lift looked exactly like the light tap this
    /// detector exists for, and every click did its own job AND the tap's. Over
    /// bare video that meant one press both toggled playback and silently
    /// swapped the time readout between elapsed/remaining and clock times.
    /// A physical action must produce one logical action.
    private var gcClickFiredThisTouch = false

    /// Called by the pan recognizer's .began (movement-gated). Marks the
    /// in-flight GC touch as a swipe so it isn't also treated as a tap.
    func noteSwipeStarted() { gcPanFiredThisTouch = true }

    /// Called by every Select handler that can fire while the pad is touched,
    /// so the lift that follows is not also read as a tap.
    func noteSelectPressed() { gcClickFiredThisTouch = true }

    private func dpadSample(x: Double, y: Double) {
        if isScrubbing { wheelSample(x: x, y: y); return }

        let touching = abs(x) > 0.001 || abs(y) > 0.001
        if touching {
            if !gcTouchDown {
                gcTouchDown = true
                gcTouchStartTime = Date()
                gcPanFiredThisTouch = false
                gcClickFiredThisTouch = false
                debug("gc↓")
            }
        } else if gcTouchDown {
            gcTouchDown = false
            let dur = Date().timeIntervalSince(gcTouchStartTime)
            debug("gc↑ \(Int(dur * 1000))ms\(gcPanFiredThisTouch ? " swipe" : "")\(gcClickFiredThisTouch ? " click" : "")")
            // A tap = brief contact with NO pan and NO click. Either of those
            // means the contact already produced an action of its own.
            if dur < 0.6, !gcPanFiredThisTouch, !gcClickFiredThisTouch { remoteTapped() }
        }
    }

    /// Light tap: no click, no swipe — a thumb resting on the pad.
    ///
    /// Over bare video it raises the TRANSPORT, which is what Infuse does with
    /// a touch. (An earlier design showed a thin "peek" bar here instead —
    /// playhead and times, no title, no glyphs. The Infuse rewrite replaced it
    /// and the machinery behind it sat unreachable until it was removed; see
    /// `FusionInertOverlay`, which is now only the scrub and quick-seek view.)
    ///
    /// A tap only ever SHOWS: nothing hides the menu or the scrub except the
    /// auto-hide timer and Back.
    private func remoteTapped() {
        guard acceptsTransportInput, !isScrubbing else { return }
        switch overlay {
        case .none:
            debug("tap:show")
            showControls()
        case .controls, .pauseInfo:
            // Infuse: a touch with the transport up swaps the elapsed /
            // remaining figures for the wall-clock start and end times (and
            // back). The next time the controls come up they read elapsed /
            // remaining again.
            debug("tap:clock")
            showsClockTimes.toggle()
            restartHideTimer()
        default:
            break
        }
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
    ///
    /// `gesture` = this came from a TRACKPAD SWIPE, which is a different
    /// input entirely and was being made to behave like a button it isn't.
    /// A button can repeat while held, so the long debounce is what gathers a
    /// hold into one accelerating seek; a swipe cannot repeat — by the time
    /// the app sees it, it is over. Waiting 650ms for a second one that the
    /// hardware will never send is dead air the viewer reads as a freeze, so
    /// the first swipe of a run commits AT ONCE and only a follow-up waits,
    /// and then only long enough to gather a flurry into a single seek rather
    /// than one re-buffer per swipe.
    func nudgeSeek(_ base: Double, gesture: Bool = false) {
        guard acceptsTransportInput else { return }
        let now = Date()
        // MUST BE LONGER THAN THE SWIPE REPEAT RATE. Measured off the remote:
        // a run of swipes arrives every 250-292ms, so a 0.35s window sat right
        // on top of the repeat interval and a run kept being re-classified as a
        // fresh gesture.
        let continuing = lastNudgeAt.map { now.timeIntervalSince($0) < 0.6 } ?? false
        nudgeStreak = continuing ? min(nudgeStreak + 1, 12) : 0
        lastNudgeAt = now

        // EVERY press is worth the configured skip, and no more. It used to
        // ramp while the button was held — four quick presses of a 10s skip
        // moved 76 seconds rather than 40 — which is the same "why did it run
        // off" surprise as the sweep this replaced. The debounce still gathers
        // a run into ONE seek; it just adds up honestly now.
        pendingSeekDelta += base
        PlayerProbe.event("nudge", String(format: "nudge %+.0f -> pending %+.1f (%@)",
                                          base, pendingSeekDelta,
                                          gesture ? "swipe" : "press"))

        // Clamp the running preview to the timeline.
        if duration > 0 {
            let target = min(max(position + pendingSeekDelta, 0), duration - 1)
            pendingSeekDelta = target - position
        }

        restartHideTimer()
        seekDebounceTask?.cancel()
        // Commit at once only for a swipe that is genuinely ON ITS OWN. Once a
        // run is under way every swipe goes through the debounce, so the run
        // costs ONE seek instead of one per swipe — and `lastNudgeAt` alone
        // cannot tell the difference, because a seek's own re-buffer stretches
        // the gap before the next swipe is delivered and made the middle of a
        // run look like the start of a new one.
        if gesture, !continuing,
           Date().timeIntervalSince(lastNudgeCommitAt) > 1.0 {
            commitPendingNudge()
            return
        }
        // 450ms, comfortably past the 250-292ms swipe repeat, so a flurry
        // gathers instead of firing a seek per swipe.
        //
        // This was 250ms, i.e. SHORTER than the interval between swipes, so the
        // window expired before the next one could arrive and the accumulator
        // never accumulated. Caught on the device: six separate seeks in 2.4
        // seconds, the last of them landing while `playing=n` because the one
        // before had not finished re-buffering. Every seek on a 4K remux is a
        // decoder flush and a re-demux from the previous keyframe — that run of
        // six is exactly "swiping forward or back makes it jittery and it keeps
        // having to load". The extra 200ms buys the viewer one seek instead of
        // six, and the bar shows `pendingSeekDelta` throughout, so the target is
        // moving on screen the whole time it is being gathered.
        let window: UInt64 = gesture ? 450_000_000 : 650_000_000
        seekDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: window)
            guard !Task.isCancelled, let self else { return }
            self.commitPendingNudge()
        }
    }

    /// When the last nudge actually turned into a seek, so a run in progress
    /// can be told from a fresh gesture even when the seek's own re-buffer has
    /// stretched the gap between swipes.
    private var lastNudgeCommitAt = Date.distantPast

    /// Fire the accumulated nudge and clear the preview.
    private func commitPendingNudge() {
        let delta = pendingSeekDelta
        pendingSeekDelta = 0
        nudgeStreak = 0
        guard delta != 0 else { return }
        lastNudgeCommitAt = Date()
        PlayerProbe.event("nudge", String(format: "COMMIT %+.1f", delta))
        seek(to: position + delta)
    }

    // MARK: - Controls visibility

    func showControls() {
        // No chrome over the loading screen — gestures wake the UI only once
        // the movie is actually playing.
        guard acceptsTransportInput else {
            PlayerProbe.event("ui", "showControls REFUSED (no transport input yet)")
            return
        }
        // Only raise the transport over bare video or the paused frame — a
        // track popover (.audio / .subtitles) is the transport already, and
        // must not be knocked back to the bar by a stray call.
        if overlay == .none {
            showsClockTimes = false
            overlay = .controls
        } else if overlay == .pauseInfo {
            overlay = .controls
        }
        restartHideTimer()
    }

    func hideControls() {
        if overlay == .controls { overlay = .none }
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
            // ...and never while PAUSED. Infuse keeps the bar up for as long as
            // the picture is stopped, which is what both `togglePlayPause` and
            // the `.pauseInfo` transitions have always claimed happens here —
            // but the timer never checked, so five idle seconds after a pause
            // took the transport away and left a frozen frame with no UI on it
            // at all. (A pause is not idleness; it is a state the viewer is
            // sitting in, and the bar is the only thing saying so.) Re-armed
            // rather than dropped, so playback that resumes without going
            // through a transport press — a seek autoplaying, a buffer
            // refilling — still gets its auto-hide back.
            guard overlay == .controls else { return }
            guard isPlaying else {
                restartHideTimer()
                return
            }
            PlayerProbe.event("ui", "controls auto-hid after 5s idle")
            overlay = .none
        }
    }

    /// Menu/Back button handling. Steps back out of a sub-panel to the main
    /// player controls; from the top level it leaves playback.
    ///
    /// Returns TRUE when it handled the press itself and FALSE when the caller
    /// should dismiss the player — the view owns the teardown (display-mode
    /// handshake, exit cover, `dismiss()`), so leaving cannot be done from in
    /// here. There is no "Exit Player?" confirmation any more: no other player
    /// on the platform asks, and Back is cheap to undo.
    /// One Menu press can be delivered by BOTH the window-level catcher and a
    /// SwiftUI onExitCommand — dedupe so it only steps back once.
    private var lastExitPressAt = Date.distantPast

    func handleExit() -> Bool {
        // Exit already in flight: swallow every Back press so it can't
        // re-open overlays / restart playback while the display-mode switch
        // and dismissal complete.
        guard !isExiting else {
            PlayerProbe.event("remote", "BACK swallowed — already exiting")
            return true
        }
        let now = Date()
        guard now.timeIntervalSince(lastExitPressAt) > 0.3 else {
            // Both the window recognizer and onExitCommand can deliver the
            // same press. A DOUBLE press the viewer meant, arriving inside
            // 300ms, is eaten by the same guard — worth counting, because
            // "Back sometimes needs two presses" lives here.
            PlayerProbe.event("remote", "BACK deduped (<300ms since the last)")
            PlayerProbe.count("input.back-deduped")
            return true
        }
        lastExitPressAt = now
        PlayerProbe.event("remote", "BACK on \(overlay.probeName) scrubbing=\(isScrubbing.probe)")
        if isScrubbing {
            cancelScrub()
            return true
        }
        switch overlay {
        case .episodes, .sources, .audio, .subtitles, .speed, .engine:
            // A sub-menu opened from a DEAD-END overlay goes back to it, not
            // to the transport: "Other Sources" on the error screen, then
            // Back, used to land the viewer on a transport bar over a stream
            // that had already failed — and the bar hides itself, so a moment
            // later they were looking at a black screen with no error text, no
            // Other Sources button and no way to reach either again.
            if let previous = overlayBeforeSubMenu {
                overlayBeforeSubMenu = nil
                overlay = previous
                return true
            }
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
            // Back with the controls showing just hides them (Netflix/Hulu),
            // so leaving takes two presses from here rather than one. Worth
            // keeping now that the confirmation is gone: the player auto-shows
            // the controls when a stream first loads, and exiting on the first
            // Back would drop straight back out of a title that had only just
            // started.
            overlay = .none
        case .info:
            // Back steps out of an open picker first, then closes the
            // pull-down and returns to the bare video.
            if sheetClosing { return true }
            if infoPickerVisible {
                infoPickerVisible = false
            } else {
                dismissInfoPanel()
            }
        case .none, .error, .stillWatching, .postPlay:
            PlayerProbe.event("session", String(format: "EXIT at %.1f of %.1f", position, duration))
            // Bare video / dead-end overlays → LEAVE. No confirmation: no other
            // player on the platform asks, Back is cheap to undo (the title is
            // one press away and resumes where it stopped), and a prompt on the
            // way out is a modal in front of someone who has already decided.
            // Progress is saved here rather than left to `prepareForExit` so it
            // is durable before any of the teardown can go wrong.
            saveProgress()
            hideControlsTask?.cancel()
            return false
        }
        return true
    }

    /// The dead-end overlay a player sub-menu was opened FROM, restored when
    /// Back steps back out of that menu. Cleared by `load(entry:)`: once a new
    /// stream is being opened the old error is answered, and Back must not
    /// resurrect it over playback that is now working.
    private var overlayBeforeSubMenu: PlayerOverlay?

    /// "Other Sources" on the playback-error screen. Same list as everywhere
    /// else, but Back returns to the error rather than to the transport.
    func showSourcesFromError() {
        // Same dead end as `retryPlayback`: after "No playable sources found
        // for SxxEyy", `allEntries` is still the list belonging to the episode
        // that finished, so this opened a picker full of links for the wrong
        // episode and choosing one restarted the previous one. Re-run the
        // named episode's lookup instead and let it raise the picker if
        // anything comes back this time.
        if let episode = episodeAwaitingSources {
            play(episode: episode, presentSources: true)
            return
        }
        overlayBeforeSubMenu = overlay
        overlay = .sources
    }

    // MARK: - Tracks / speed / aspect

    func selectAudio(_ track: TrackOption) {
        PlayerProbe.event("track", "AUDIO → \(track.displayName) [\(track.id)]")
        PlayerProbe.count("track.audio-switch")
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
            // Any selection through here settles the session — the auto pick
            // latches before calling in, and a manual pick must stop later
            // track waves (and the wave watch) from second-guessing the viewer.
            vlcAudioAutoApplied = true
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
        // A hand-picked track settles the session, the way `selectAudio`
        // latches `vlcAudioAutoApplied`. Subtitles arrive in WAVES: when the
        // embedded wave carries nothing in `preferredSubtitleLanguage`,
        // `applyDefaultSubtitleIfNeeded` returns with the latch still open, so
        // the addon wave landing seconds later would match its own English
        // track and pull the captions off the language the viewer had just
        // chosen. The automatic path closes the latch itself before calling in
        // here, so only a real choice reaches this.
        PlayerProbe.event("track", "SUBTITLE → \(track.displayName) [\(track.id)]"
            + " (\(userInitiated ? "viewer" : "automatic"))")
        PlayerProbe.count(userInitiated ? "track.sub-switch" : "track.sub-auto")
        if userInitiated { subtitleAutoApplied = true }
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
            let lang = PlayerSettings.allSubtitleLanguageOptions.first {
                guard !$0.0.isEmpty,
                      let localized = Locale.current.localizedString(forLanguageCode: $0.0)?.lowercased()
                else { return false }
                return name.contains(localized)
            }?.0
            // "on" when the track's label names no language we recognise —
            // still a deliberate "captions on for this show", and clearing the
            // field instead lost that: the next episode had nothing to read
            // back and started with subtitles off. `applyDefaultSubtitleIfNeeded`
            // treats it as "any track will do".
            if userInitiated { PlaybackMemory.update(meta.id) { $0.subtitleLanguage = lang ?? "on" } }
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
            // Nothing of ours belongs on screen over VLC's own captions.
            subtitleModel.selectedSubtitleInfo = nil
            dropDisplayedSubtitleCue()
        default:
            subtitleModel.selectedSubtitleInfo = nil
            dvActiveEmbeddedSub = nil
            dvDirectEngine?.selectSubtitle(nil)
            dropDisplayedSubtitleCue()
        }
    }

    /// Take the cue that is on screen down NOW.
    ///
    /// `SubtitleModel.parts` is only ever recomputed by
    /// `subtitle(currentTime:)`, and the KSPlayer clock tick skips that call
    /// while no track is selected (see `player(layer:currentTime:totalTime:)`)
    /// — so choosing None cleared the selection and then never ran the one
    /// call that empties the cue list: the last caption sat frozen on the
    /// picture for the rest of the film.
    private func dropDisplayedSubtitleCue() {
        guard !subtitleModel.parts.isEmpty else { return }
        _ = subtitleModel.subtitle(currentTime: position)
    }

    /// The track to put back once a reload's addon wave lands.
    private var pendingSubtitleReselect: String?

    /// "Reload Subtitles" (info panel -> Subtitles -> Options). Drops every
    /// addon track and the cue on screen, fetches the addon wave again as
    /// fresh objects — so a track whose download or parse failed is tried
    /// again from scratch — and puts the viewer's selection back once it
    /// lands. An embedded track is simply re-selected.
    func reloadSubtitles() {
        let wanted = selectedSubtitleID
        showToast("Reloading subtitles…")
        if usingVLC {
            // VLC owns its slave tracks and can't shed them; re-select the
            // current one AND fetch the addon wave again — a slave whose
            // download failed never made it into VLC's list at all, and the
            // re-fetch is what actually adds it (duplicates are cheap: VLC
            // keys slaves by URL).
            if let wanted, wanted != "sub-off",
               let option = subtitleOptions.first(where: { $0.id == wanted }),
               case .vlcSubtitle(let id) = option.payload {
                vlcEngine?.selectSubtitle(-1)
                vlcEngine?.selectSubtitle(id)
            }
            addonSubtitlesFetched = false
            fetchAddonSubtitles()
            return
        }
        subtitleModel.selectedSubtitleInfo = nil
        dvActiveEmbeddedSub = nil
        dvDirectEngine?.selectSubtitle(nil)
        dropDisplayedSubtitleCue()
        subtitleModel.removeSubtitles { $0 is URLSubtitleInfo }
        // The viewer's choice stands through the reload: nothing here is an
        // invitation for the on-by-default pick to choose something else.
        subtitleAutoApplied = true
        selectedSubtitleID = "sub-off"
        // Deliberately NOT rebuilding the options here: a file whose only
        // tracks were addon subtitles would rebuild to an EMPTY list (the Off
        // row rides along only when tracks exist), the glyph would vanish
        // mid-look, and a re-fetch that failed left the tab bare for good.
        // The stale rows still work — selecting one re-downloads through
        // `isEnabled` — and the addon wave rebuilds the list when it lands.
        addonSubtitlesFetched = false
        if let wanted, wanted != "sub-off",
           let option = subtitleOptions.first(where: { $0.id == wanted }) {
            // Embedded: still in the list — straight back on.
            pendingSubtitleReselect = nil
            selectSubtitle(option, userInitiated: false)
        } else {
            pendingSubtitleReselect = wanted
        }
        fetchAddonSubtitles()
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        PlaybackMemory.update(meta.id) { $0.speed = speed == 1 ? nil : speed }
        if let dvDirectEngine { dvDirectEngine.rate = speed }
        else if let vlcEngine { vlcEngine.rate = speed }
        else { playerLayer?.player.playbackRate = speed }
        showToast("Speed \(speed == 1 ? "Normal" : String(format: "%gx", speed))")
    }

    // MARK: Audio sync (lip-sync offset)

    /// User A/V offset in seconds. POSITIVE = voices play LATER relative to
    /// the picture (for "voices come before the mouths move" — the common
    /// case on TV/soundbar chains that delay video processing). Remembered
    /// per title, like speed. Wired on the FFmpeg engine (via the clock's
    /// `videoDelay` — the audio renderer is the master clock, so the offset
    /// shifts when VIDEO is presented), on VLC (its native audio-delay knob)
    /// and on the DV sample engine (its audio timestamps); the native AVPlayer
    /// engine is not adjustable. Zero is every engine's natural timing.
    @Published private(set) var audioSyncOffset: Double = 0

    static let audioSyncOptions: [Double] =
        [-2, -1, -0.5, -0.25, -0.1, -0.05, 0, 0.05, 0.1, 0.25, 0.5, 1, 2]

    static func audioSyncLabel(_ offset: Double) -> String {
        guard offset != 0 else { return "Off" }
        let ms = Int((offset * 1000).rounded())
        return ms > 0 ? "Voices +\(ms) ms later" : "Voices \(ms) ms earlier"
    }

    /// Audio Sync is only offered where the knob it writes is actually read.
    ///
    /// VLC has a real audio-side delay. The FFmpeg engine applies `videoDelay`
    /// inside `videoClockSync`. The NATIVE AVPlayer engine has neither — it
    /// never calls `videoClockSync`, so `videoDelay` is inert there — and the
    /// old test only asked whether an options object existed, which is true on
    /// the native path too. So the row was offered on native sessions and
    /// every value in it did nothing, in both directions. The direct-DV engine
    /// was already excluded for the same reason.
    ///
    /// The direct-DV engine now has a real knob too (`setAudioDelay`, which
    /// re-stamps the audio it hands to its renderer), so the row is back there.
    var audioSyncAdjustable: Bool {
        vlcEngine != nil || dvDirectEngine != nil
            || (!usingDVDirect && playerLayer?.player is KSMEPlayer)
    }

    func setAudioSync(_ offset: Double) {
        audioSyncOffset = offset
        applyAudioSync()
        // The engine on screen right now (see `applyAudioSync` for why the DV
        // engine is applied here and at creation, never from there).
        dvDirectEngine?.setAudioDelay(offset)
        PlaybackMemory.update(meta.id) { $0.audioSyncOffset = offset == 0 ? nil : offset }
        showToast("Audio sync \(Self.audioSyncLabel(offset))")
    }

    /// Re-applied wherever an engine (re)opens — the options object and the
    /// VLC player are per-session.
    func applyAudioSync() {
        // KSPlayer clock: `desire = master − videoDelay`, so POSITIVE
        // videoDelay presents video LATER (≡ voices earlier). Our positive
        // means voices later → negate.
        currentOptions?.videoDelay = -audioSyncOffset
        // VLC's knob is audio-side directly: positive = audio delayed (µs).
        vlcEngine?.player.currentAudioPlaybackDelay = Int(audioSyncOffset * 1_000_000)
        // NOT the DV sample engine: `load()` calls this before a new DV engine
        // exists, while `dvDirectEngine` can still be the previous title's —
        // and a changed offset re-anchors (seeks) the engine it is given. The
        // DV engine takes its offset at creation and in `setAudioSync` instead.
    }

    /// A left/right press on the Fusion bar. A lone press nudge-seeks; holding
    /// the direction down escalates into the continuous fast-forward sweep.
    ///
    /// ONE PRESS, ONE SKIP — the amount configured in Settings, nothing else.
    ///
    /// A run of quick presses used to be read as "held" and escalated into a
    /// continuous fast-forward sweep, on the reasoning that a single bar has no
    /// dedicated FF/RW button and tvOS reports no "held" state for a
    /// directional press, so the repeats were the only available signal. In
    /// practice that turned ordinary impatient skipping into a sweep nobody
    /// asked for. Pressing right four times should move four skips, and that
    /// is now all it does.
    func barDirectionalPress(forward: Bool) {
        guard acceptsTransportInput else { return }
        nudgeSeek(forward ? Double(settings.skipSeconds) : -Double(settings.skipSeconds))
    }

    // The fast-forward / rewind SCAN transport was removed here.
    //
    // It was a preview-based sweep — a ghost playhead that moved without
    // seeking, committed with Play — entered by four quick directional presses
    // on the bar. That trigger was removed because it hijacked ordinary
    // impatient skipping, and tvOS offers no other reliable way in: there is no
    // "held" state for a directional press, only a stream of repeats, and the
    // one remaining candidate gesture (resting a finger on the pad's edge) is
    // already claimed by the fine-tune wheel's ring engagement.
    //
    // Rather than keep an unreachable transport whose `scanPreview == nil`
    // guards still sat in the hide timer, the exit handler, the seek watchdog
    // and play/pause — always true, and reading as though a mode existed that
    // did not — the whole thing is gone. The scrub bar covers the same ground
    // better: it has thumbnails, so you can see where you are going instead of
    // watching a blind 8x sweep go past it.

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

    /// Set the zoom mode outright (the Infuse Video → Zoom Mode picker).
    func setAspect(_ mode: AspectMode) {
        guard mode != aspectMode else { return }
        aspectMode = mode
    }

    /// Infuse Video → Aspect Ratio. `nil` = Auto (the file's own shape); a
    /// value forces the picture to that width:height, stretching the
    /// mismatched axis. Applied as part of the same host transform as zoom.
    @Published var aspectRatioOverride: Double?
    static let aspectRatioOptions: [(value: Double?, label: String)] = [
        (nil, "Auto"),
        (4.0 / 3.0, "SDTV (4:3)"),
        (16.0 / 10.0, "HDTV (16:10)"),
        (16.0 / 9.0, "HDTV (16:9)"),
        (1.85, "Widescreen A (1.85:1)"),
        (2.00, "Widescreen B (2.00:1)"),
        (2.35, "Anamorphic A (2.35:1)"),
        (2.39, "Anamorphic B (2.39:1)"),
        (2.40, "Anamorphic C (2.40:1)"),
        (3.60, "Ultra-Widescreen (36:10)")
    ]
    var aspectRatioLabel: String {
        Self.aspectRatioOptions.first { $0.value == aspectRatioOverride }?.label ?? "Auto"
    }

    /// Infuse Video → Vertical Shift: slide a letterboxed picture to the top
    /// or bottom edge of the screen (subtitles then sit in the black bar).
    enum VerticalShift: String, CaseIterable {
        case none, up, down
        var label: String {
            switch self {
            case .none: return "None"
            case .up: return "Up"
            case .down: return "Down"
            }
        }
    }
    @Published var verticalShift: VerticalShift = .none

    /// A full-screen picker is open over the info panel; Back closes it
    /// before the panel itself.
    @Published var infoPickerVisible = false
    /// Focus is on the sheet's tab pills (not down in the rows). A swipe up
    /// closes the sheet only from there — from the rows it's the move up to
    /// the pills.
    @Published var infoFocusOnTabs = true
    /// With the transport up, focus is on the bar (not a glyph or a popover
    /// row). A swipe down opens the info sheet only from the bar — anywhere
    /// higher, a swipe down is the move DOWN through the controls.
    @Published var controlsFocusOnBar = true

    /// The transport is showing wall-clock start / end times instead of
    /// elapsed / remaining — a light tap on the pad flips it (Infuse). Reset
    /// whenever the controls come up from hidden.
    @Published var showsClockTimes = false

    /// The chapter playback is currently inside, for the Chapters row.
    var currentChapter: Chapter? {
        chapters.last { $0.start <= position + 0.5 }
    }

    /// "Chapter 03" for untitled chapters, the file's own title otherwise.
    static func chapterLabel(_ chapter: Chapter, index: Int) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? String(format: "Chapter %02d", index + 1) : title
    }

    func seek(toChapter chapter: Chapter) {
        seek(to: chapter.start)
        let index = chapters.firstIndex { $0.start == chapter.start } ?? 0
        showToast(Self.chapterLabel(chapter, index: index))
    }

    /// Dolby Vision status for the Video options card: "On" when the direct
    /// engine is outputting DV, "Off" when the file carries DV but the
    /// session isn't (base layer), nil when the file has none.
    var dolbyVisionStatus: String? {
        if let engine = dvDirectEngine {
            return engine.detectedDVProfile > 0 && !engine.forceHDR10 ? "On" : "Off"
        }
        let hasDV = playerLayer?.player.tracks(mediaType: .video).contains { $0.dovi != nil } ?? false
        return hasDV ? "Off" : nil
    }

    /// The Video tab's left column: what this stream actually IS.
    ///
    /// Dynamic range is named PRECISELY — "Dolby Vision 8.1" rather than a
    /// bare "DV" — because the profile decides which pipeline runs and what
    /// the TV is actually being sent. Every value here has to FIT the column
    /// (`InfuseRowMetrics.columnWidth` less the "Dynamic Range" label, i.e.
    /// about 300pt, and the row is `lineLimit(1)`): a read-out that ends in an
    /// ellipsis answers nothing. HDR is read from the TRANSFER
    /// FUNCTION rather than `formatDescription.dynamicRange`, which calls
    /// anything 10-bit "HDR10" and is wrong on 10-bit SDR encodes.
    func videoFormatRows() -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        let player = playerLayer?.player
        let track = player?.tracks(mediaType: .video).first(where: \.isEnabled)
            ?? player?.tracks(mediaType: .video).first

        if let engine = dvDirectEngine {
            let profile = engine.detectedDVProfile
            if profile > 0, !engine.forceHDR10 {
                rows.append(("Dynamic Range", profile == 7
                    ? "Dolby Vision 7 → 8.1"
                    : "Dolby Vision \(profile)"))
                rows.append(("Output", "Native Dolby Vision"))
            } else if engine.forceHDR10 {
                rows.append(("Dynamic Range", "Dolby Vision 7 (FEL)"))
                rows.append(("Output", "HDR10 base layer"))
            } else {
                rows.append(("Dynamic Range", "HDR10 / SDR"))
            }
        } else if let track {
            let trc = track.transferFunction
            let isPQ = trc == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            let isHLG = trc == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            if let dovi = track.dovi {
                let profile = Int(dovi.dv_profile)
                var name = "Dolby Vision \(profile)"
                if profile == 8 { name += ".\(Int(dovi.dv_bl_signal_compatibility_id))" }
                rows.append(("Dynamic Range", name))
                // Always the base layer here: this arm is the DECODE path, and
                // P7 conversion (now always on) happens on the direct engine,
                // which builds its rows above and never reaches this branch.
                rows.append(("Output", "HDR10 base layer"))
            } else if hasHDR10Plus {
                rows.append(("Dynamic Range", "HDR10+ · dynamic"))
            } else if isPQ {
                rows.append(("Dynamic Range", "HDR10"))
            } else if isHLG {
                rows.append(("Dynamic Range", "HLG"))
            } else {
                rows.append(("Dynamic Range", trc == nil ? "SDR · no colour tags" : "SDR"))
            }
        }

        if let track {
            rows.append(("Codec", Self.prettyVideoCodec(Self.codecName(track))))
            let size = track.naturalSize
            if size.width > 0 {
                rows.append(("Resolution", "\(Int(size.width)) × \(Int(size.height))"))
            }
            if track.bitDepth > 0 { rows.append(("Bit Depth", "\(track.bitDepth)-bit")) }
            if let primaries = track.colorPrimaries {
                rows.append(("Primaries", Self.shortColorTag(primaries)))
            }
            if let transfer = track.transferFunction {
                rows.append(("Transfer", Self.shortColorTag(transfer)))
            }
            if track.nominalFrameRate > 0 {
                rows.append(("Frame Rate", String(format: "%.3g fps", track.nominalFrameRate)))
            }
            let bitrate = player?.dynamicInfo?.videoBitrate ?? Int(track.bitRate)
            if bitrate > 0 {
                rows.append(("Bitrate", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)))
            }
        } else if let engine = dvDirectEngine {
            rows.append(("Codec", engine.videoCodecName))
            if engine.videoWidth > 0 {
                rows.append(("Resolution", "\(engine.videoWidth) × \(engine.videoHeight)"))
            }
            if engine.videoFPS > 0 {
                rows.append(("Frame Rate", String(format: "%.3g fps", engine.videoFPS)))
            }
            if engine.containerMbps > 0 {
                rows.append(("Bitrate", String(format: "%.1f Mbps", engine.containerMbps)))
            }
        }
        return rows
    }

    /// The Audio tab's read-only "Format" column — what the audio IS and what
    /// this app is doing with it, rendered from the same `audioPipelineFacts`
    /// the `[atmos]` probe block uses, so the two cannot disagree.
    ///
    /// The one row that matters is "Output". It names a Dolby bitstream ONLY
    /// when compressed Dolby leaves the app; anything decoded here says PCM, in
    /// as many words. Atmos is reported as what the FILE says about itself,
    /// never as a claim about what the receiver is decoding.
    func audioFormatRows() -> [(label: String, value: String)] {
        let f = audioPipelineFacts
        var rows: [(label: String, value: String)] = []
        guard f.codec != "-" || f.decoder != "-" else { return rows }

        rows.append(("Codec", Self.audioCodecDisplayName(f.codec)))
        if f.channels > 0 {
            rows.append(("Channels", Self.channelLabel(f.channels)))
        }

        // "Tagged in the file" is the honest ceiling: the container metadata
        // says Atmos, and that is all any code on this side can know. A TrueHD
        // track tagged Atmos is called out for what happens to it — tvOS
        // cannot bitstream TrueHD, so the objects are lost in the PCM decode.
        //
        // Every value here fits `InfuseOptionRow` on ONE line at
        // `InfuseRowMetrics.columnWidth` less its label: the row is
        // `lineLimit(1)` and a truncated verdict reads as a bug. The long-form
        // wording lives in the `[atmos]` probe block.
        let lower = f.codec.lowercased()
        let truehd = lower.contains("truehd") || lower.contains("mlp")
        let atmos: String
        if f.sourceSaysAtmos {
            atmos = truehd ? "Tagged — lost in decode"
                           : (f.dolbyBitstream ? "Tagged in file" : "Tagged — decoded to PCM")
        } else {
            atmos = "Not tagged"
        }
        rows.append(("Atmos", atmos))

        // THE VERDICT, and the only row that needs reading to answer "am I
        // actually getting Dolby?".
        //
        // It replaces four rows that each said a piece of the same thing —
        // Pipeline (bitstream vs decoded), Decoder (who decoded it), Native
        // Dolby (yes/no) and Sample Rate (48 kHz on essentially everything
        // this plays). Anything not a Dolby bitstream leaves as LPCM, whoever
        // decoded it, so there are exactly three outcomes worth naming.
        let output: String
        if f.nativeDolbyPath {
            output = "Dolby bitstream → HDMI"
        } else if f.routeIsMultichannel {
            output = "Multichannel PCM → HDMI"
        } else {
            output = "Stereo PCM → HDMI"
        }
        rows.append(("Output", output))
        rows.append(("Route", AudioOutputCapability.routeShortDescription))

        // Conditionals: these appear only when something is actually wrong, so
        // they cost nothing in the common case and are the whole point in the
        // uncommon one.
        if f.downmixedInApp {
            rows.append(("Downmix", "Folded to stereo in app"))
        }
        // The route limit bites decoded multichannel PCM only. The cause is
        // almost always the HDMI sink advertising stereo after a reboot or a
        // format change — not this app — so say what actually fixes it. Two
        // rows because one held both and truncated where the remedy started.
        if f.pcmChannelsLostToRoute {
            rows.append(("Route Limit", "Sink advertising stereo"))
            rows.append(("Fix", "Power-cycle the receiver"))
        }
        return rows
    }

    /// The engine's raw codec name, or an already-pretty label, made readable.
    static func audioCodecDisplayName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "eac3": return "Dolby Digital Plus (E-AC-3)"
        case "ac3": return "Dolby Digital (AC-3)"
        case "truehd", "mlp": return "Dolby TrueHD"
        case "dts": return "DTS"
        case "flac": return "FLAC"
        case "aac": return "AAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "vorbis": return "Vorbis"
        case "-": return "Unknown"
        default: return codec   // the KSPlayer path already hands over "Dolby Digital+ Atmos"
        }
    }

    /// The Infuse Info card's one-line file summary: runtime, then size,
    /// codec, "(4K DV)", audio, bitrate and frame rate — whatever's known.
    func infuseFileSummary() -> (runtime: String?, details: [String]) {
        var runtime: String?
        if duration > 0 {
            let total = Int(duration.rounded())
            let h = total / 3600, m = (total % 3600) / 60
            runtime = h > 0 ? "\(h) hr \(m) min" : "\(m) min"
        }
        var details: [String] = []
        if let size = currentEntry.fileSizeLabel { details.append(size) }

        let player = playerLayer?.player
        var width = 0
        var fps: Double = 0
        var mbps: Double = 0
        var codec: String?
        var hdr: String?
        if let engine = dvDirectEngine {
            codec = engine.videoCodecName
            width = engine.videoWidth
            fps = Double(engine.videoFPS)
            mbps = engine.containerMbps
            // Non-DV is not automatically HDR. `startDVFirst` accepts profile 0
            // (plain HEVC) on purpose and its entry hint is a loose "dolby"
            // match over the release name, so ordinary SDR files ride this
            // engine routinely — the flat "HDR" here labelled them as HDR while
            // the Video tab on the same sheet read them off the bitstream and
            // said otherwise. No PQ from the preflight, no tag, exactly as the
            // KSPlayer arm below leaves SDR untagged.
            if engine.detectedDVProfile > 0, !engine.forceHDR10 {
                hdr = "DV"
            } else if dvDirectIsPQ {
                hdr = "HDR"
            }
        } else if let track = player?.tracks(mediaType: .video).first(where: \.isEnabled)
                    ?? player?.tracks(mediaType: .video).first {
            codec = Self.prettyVideoCodec(Self.codecName(track))
            width = Int(track.naturalSize.width)
            fps = Double(track.nominalFrameRate)
            let bitrate = player?.dynamicInfo?.videoBitrate ?? Int(track.bitRate)
            mbps = Double(bitrate) / 1_000_000
            if track.dovi != nil {
                hdr = "DV"
            } else if hasHDR10Plus {
                hdr = "HDR10+"
            } else if let range = track.formatDescription?.dynamicRange, range != .sdr {
                hdr = range == .hlg ? "HLG" : "HDR"
            }
        }
        if width == 0 { width = Int(videoNaturalSize.width) }
        if let codec { details.append(codec) }
        let resolution: String? = width >= 3000 ? "4K" : width >= 1800 ? "1080p"
            : width >= 1200 ? "720p" : width > 0 ? "SD" : nil
        let tag = [resolution, hdr].compactMap { $0 }
        if !tag.isEmpty { details.append("(" + tag.joined(separator: " ") + ")") }

        if let track = player?.tracks(mediaType: .audio).first(where: \.isEnabled)
            ?? player?.tracks(mediaType: .audio).first {
            var audio = Self.audioFormat(track).codec ?? Self.codecName(track)
            let channels = Self.channelCount(track)
            if channels > 0 { audio += " " + Self.channelShort(channels) }
            details.append(audio)
        } else if let name = audioOptions.first(where: { $0.id == selectedAudioID })?.displayName {
            details.append(name)
        }
        if mbps > 0 { details.append(String(format: "%.1f Mbps", mbps)) }
        if fps > 0 {
            let rounded = (fps * 1000).rounded() / 1000
            details.append(rounded == rounded.rounded()
                ? String(format: "%.0f fps", rounded) : String(format: "%.3f fps", rounded))
        }
        return (runtime, details)
    }

    private static func prettyVideoCodec(_ raw: String) -> String {
        let u = raw.uppercased()
        if u.contains("HVC") || u.contains("HEV") { return "HEVC" }
        if u.contains("AVC") || u.contains("264") { return "H.264" }
        if u.contains("AV01") || u == "AV1" { return "AV1" }
        if u.contains("VP09") || u.contains("VP9") { return "VP9" }
        if u.contains("MP4V") || u.contains("MPEG4") { return "MPEG-4" }
        return raw
    }

    /// "5.1" / "7.1" / "Stereo" — the short form used in the file summary.
    static func channelShort(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count)ch"
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
    @Published var skipIntroFocused = false

    /// Move focus onto the Skip Intro pill if one is up over bare video.
    /// Returns false when there's nothing to take, so callers fall straight
    /// through to their normal action (open the controls, seek, ...).
    @discardableResult
    func focusSkipIntro() -> Bool {
        guard skipIntroActive, overlay == .none, !isScrubbing, !skipIntroFocused else { return false }
        skipIntroFocused = true
        return true
    }

    // MARK: Skip-segment cache
    //
    // `computeIntroChapter` and `computeCreditsChapter` walk every chapter,
    // lowercasing and trimming each title and testing it against a handful of
    // substrings — and BOTH used to be computed properties evaluated on every
    // one of the player's clock ticks: `updateSkipIntro()` reads the intro and
    // `maybeArmAutoNext()` (via `crossedNextEpisodeThreshold`) reads the
    // credits. KSPlayer's tick is a 0.1s timer, so on a remux with thirty
    // named chapters that was ~600 String allocations a second, on the main
    // actor, for the length of the film — to re-derive an answer that changes
    // at most twice a session.
    //
    // The inputs are the chapter list, the AniSkip intervals and the runtime.
    // Chapters and intervals are each assigned exactly once per load (and
    // cleared to empty by `resetPerLoadSessionState`, so every load passes
    // through a different key), and the duration settles moments after open.
    private struct SkipSegmentsKey: Equatable {
        let chapters: Int
        let animeSkip: Int
        let duration: Int
    }
    private var skipSegmentsKey: SkipSegmentsKey?
    private var cachedIntroChapter: SkipSegment?
    private var cachedCreditsChapter: SkipSegment?

    private func refreshSkipSegmentsIfNeeded() {
        // `Int(duration)` on a non-finite Double is a TRAP, not a conversion,
        // and a live/unknown-length source can report one — so the key carries
        // a sentinel rather than crashing the player to cache a chapter list.
        let key = SkipSegmentsKey(chapters: chapters.count,
                                  animeSkip: animeSkipIntervals.count,
                                  duration: duration.isFinite ? Int(duration) : -1)
        guard key != skipSegmentsKey else { return }
        skipSegmentsKey = key
        cachedIntroChapter = computeIntroChapter()
        cachedCreditsChapter = computeCreditsChapter()
    }

    private var introChapter: SkipSegment? {
        refreshSkipSegmentsIfNeeded()
        return cachedIntroChapter
    }

    private var creditsChapter: SkipSegment? {
        refreshSkipSegmentsIfNeeded()
        return cachedCreditsChapter
    }

    /// A chapter that reads like an intro/opening/recap. Covers common
    /// TV/anime conventions ("Opening", "OP", "NCOP", "Cold Open", "Avant",
    /// "Teaser", "Recap"). Needs the FILE to carry named chapters — most
    /// movie/web-dl remuxes don't, which is why the pill often won't appear.
    ///
    /// Reached through the cache above — never call this directly from a tick.
    private func computeIntroChapter() -> SkipSegment? {
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
    ///
    /// Reached through the cache above — never call this directly from a tick.
    private func computeCreditsChapter() -> SkipSegment? {
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
    /// Memoized on (chapter count, duration): the track reads this inside its
    /// GeometryReader, which re-renders at ~30 Hz during a scrub — a fresh
    /// map+filter per render is small but pure waste on the main actor.
    private var chapterFractionsMemo: (count: Int, duration: Double, fractions: [Double])?
    var chapterFractions: [Double] {
        guard duration > 0, chapters.count > 1 else { return [] }
        if let memo = chapterFractionsMemo,
           memo.count == chapters.count, memo.duration == duration {
            return memo.fractions
        }
        let fractions = chapters.map { $0.start / duration }.filter { $0 > 0.01 && $0 < 0.99 }
        chapterFractionsMemo = (chapters.count, duration, fractions)
        return fractions
    }

    /// How far (0…1) the hybrid disk cache extends contiguously ahead of the
    /// playhead — the growing cache segment on the timeline. 0 when the cache
    /// isn't in play, in which case the bar falls back to the engine's own
    /// buffered figure.
    var hybridCacheFraction: Double {
        guard clock.duration > 0 else { return 0 }
        return MediaCacheServer.shared.coverageFraction(
            fromTimeFraction: clock.position / clock.duration
        )
    }

    /// Keeps `clock.cacheEnd` current while a cache session is live, at a
    /// rate that has nothing to do with playback — the download runs whether
    /// or not the picture is moving, and the bar has to say so.
    private var cacheBandTask: Task<Void, Never>?

    private func startCacheBandTicker() {
        cacheBandTask?.cancel()
        // A different file maps bytes to time differently; never carry one
        // session's calibration into the next.
        cacheBandCalibration = nil
        cacheBandSkewCandidate = nil
        cacheBandLastPosition = -1
        cacheBandLastTick = nil
        cacheBandTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Nothing draws the band while every overlay is hidden and no
                // scrub is in flight (FusionBottomBlock is unmounted then) —
                // don't snapshot/merge/compare spans for an invisible bar.
                // 3s idle cadence keeps the numbers warm enough that the bar
                // is current within a beat of the overlay coming up.
                let visible = self.overlay != PlayerOverlay.none || self.isScrubbing
                if visible {
                    let value = self.cacheBandEnd
                    if abs(self.clock.cacheEnd - value) > 0.0005 { self.clock.cacheEnd = value }
                    var spans: [ClosedRange<Double>] = []
                    if MediaCacheServer.shared.hasLiveSession {
                        let snapshot = MediaCacheServer.shared.coveredFractionsAndReader
                        self.updateCacheBandCalibration(readerByteFraction: snapshot.reader)
                        spans = Self.displaySpans(snapshot.spans, duration: self.clock.duration,
                                                  calibration: self.cacheBandCalibration)
                    }
                    if spans != self.clock.cachedSpans { self.clock.cachedSpans = spans }
                }
                try? await Task.sleep(nanoseconds: visible ? 700_000_000 : 3_000_000_000)
            }
        }
    }

    /// Where the cache's BYTES meet the transport's TIME, as (byte fraction,
    /// time fraction) of one point in the file. nil until measured.
    ///
    /// THE BAR USED TO DRAW BYTE POSITIONS ON A TIME AXIS. The cache knows
    /// what it holds in bytes; the playhead is a timestamp; and the band was
    /// painted at `byte / fileSize` on a track where the playhead sits at
    /// `position / duration`. Those only agree for a constant-bitrate file.
    /// Measured on a 4K DV remux whose opening is lighter than its average:
    /// the resume point at 2015s (65.6% of the film) was byte 3991MB (68.1% of
    /// the file) — so the band started 77 seconds to the right of the playhead
    /// — and at 2190s the offset had grown to 109 seconds. That is the "cache
    /// starts about two minutes after where I am" report. The download itself
    /// was right the whole time; only the drawing was.
    ///
    /// The reader's byte offset is the one byte position whose time is known:
    /// it is the engine's read head, `buffered`. Mapping through that point
    /// (and the file's two ends) makes the band exact where the viewer is
    /// looking and no worse than before anywhere else.
    private var cacheBandCalibration: (byte: Double, time: Double)?
    private var cacheBandSkewCandidate: Double?
    private var cacheBandLastPosition: Double = -1
    private var cacheBandLastTick: Date?

    /// Refresh `cacheBandCalibration` from the live reader, refusing anything
    /// that could describe a different place than the playhead. Cosmetic by
    /// construction: on any doubt it keeps the last good calibration, or none —
    /// which is exactly the old drawing.
    private func updateCacheBandCalibration(readerByteFraction: Double?) {
        let now = Date()
        let elapsed = cacheBandLastTick.map { now.timeIntervalSince($0) } ?? 0
        let lastPosition = cacheBandLastPosition
        cacheBandLastTick = now
        cacheBandLastPosition = position
        // A seek moves the playhead immediately but the reader only when the
        // engine next reads, so for a moment the two describe different
        // places. Drop the candidate; keep the last good calibration.
        if lastPosition >= 0, abs(position - lastPosition) > max(3, elapsed * 2 + 1) {
            cacheBandSkewCandidate = nil
            return
        }
        guard duration > 0, let byte = readerByteFraction else {
            cacheBandSkewCandidate = nil
            return
        }
        // The reader's byte is what the engine has READ, so the matching time
        // is its read head, not the picture.
        let time = min(max(buffered, position), duration) / duration
        // Byte/time skew on a real file is a few percent; a stale reader from
        // before a long seek is off by the length of the seek.
        guard byte > 0.001, byte < 0.999, time > 0.001, time < 0.999,
              abs(byte - time) <= 0.15 else {
            cacheBandSkewCandidate = nil
            return
        }
        let skew = byte - time
        // Accept the first plausible reading of a session outright (it is
        // better than no calibration), and after that only a reading the
        // previous tick agrees with — VBR skew drifts by tiny amounts between
        // ticks 0.7s apart, a stale reader does not.
        if cacheBandCalibration == nil
            || cacheBandSkewCandidate.map({ abs(skew - $0) < 0.01 }) == true {
            cacheBandCalibration = (byte, time)
        }
        cacheBandSkewCandidate = skew
    }

    /// Map a 0…1 BYTE fraction onto the 0…1 TIME axis, piecewise-linearly
    /// through the file's start, the calibration point and the file's end.
    /// Monotonic and range-preserving; without a usable calibration it is the
    /// identity, i.e. the old linear drawing.
    nonisolated static func timeFraction(
        ofByteFraction f: Double, calibration c: (byte: Double, time: Double)?
    ) -> Double {
        guard let c, c.byte > 0, c.byte < 1, c.time > 0, c.time < 1 else { return f }
        if f <= c.byte { return f * (c.time / c.byte) }
        return c.time + (f - c.byte) * ((1 - c.time) / (1 - c.byte))
    }

    /// The cache's covered runs as the BAR should draw them. Raw
    /// `coveredFractions` early in a session is a scatter — the archive tier
    /// filling from byte zero, the window around the playhead, a chunk per
    /// past seek — and painting each one exactly made the bar read as broken
    /// into bits. Runs separated by less than ~1% of the film merge into one
    /// (the gap is a few points of track, and the download will close it in
    /// seconds anyway), and slivers too narrow to read as anything are
    /// dropped rather than drawn as specks.
    nonisolated static func displaySpans(
        _ raw: [(start: Double, end: Double)], duration: Double = 0,
        calibration: (byte: Double, time: Double)? = nil
    ) -> [ClosedRange<Double>] {
        // Merge gap in FRACTION of the film, derived from SECONDS. The flat
        // 1% looked reasonable on the bar but on a 2-hour film it painted a
        // 72-SECOND undownloaded hole as solid cached band — so the film
        // "froze at a bit that was cached" when the engine read into film
        // that was never on disk. ~5s of gap is small enough that whatever
        // seam remains reads honestly, and the download closes it in a beat.
        let gap = duration > 1 ? min(0.01, 5.0 / duration) : 0.01
        let sorted = raw
            .map { (timeFraction(ofByteFraction: max($0.start, 0), calibration: calibration),
                    timeFraction(ofByteFraction: min($0.end, 1), calibration: calibration)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for span in sorted {
            if var last = merged.last, span.0 - last.1 < gap {
                last.1 = max(last.1, span.1)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.1 - $0.0 >= 0.003 }.map { $0.0...$0.1 }
    }

    /// The growing cache band on the transport, 0…1 of the film. While the
    /// hybrid disk cache is running the band IS that cache — how far the file
    /// on disk reaches contiguously from the playhead — so it grows across
    /// the whole film as the download runs. Without it, the engine's own
    /// in-memory read-ahead (a few seconds) is all there is to show.
    var cacheBandEnd: Double {
        guard clock.duration > 0 else { return 0 }
        if MediaCacheServer.shared.hasLiveSession { return hybridCacheFraction }
        return clock.buffered / clock.duration
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
        let generation = loadGeneration
        Task { [weak self] in
            let intervals = await AnimeSkipService.intervals(
                imdbID: imdbID, season: season, episode: episode, episodeLength: length
            )
            guard !intervals.isEmpty else { return }
            // Intro/outro timestamps are per EPISODE. Landing late, these would
            // put a Skip Intro pill over the next episode at the previous one's
            // timestamps — and `autoSkipSegments` would act on them.
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentLoad(generation) else { return }
                self.animeSkipIntervals = intervals
            }
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
            // NEVER while a resume is still owed. Ticks run while the resume
            // seek is in flight and `position` reads ~0 — inside a 0-based
            // intro chapter — so the auto-skip fired, and `seek(to:)` then
            // retired `pendingResume` and dragged the floor down to the
            // intro's end: a film resumed at 40:00 restarted just past the
            // intro and the next periodic save overwrote Continue Watching.
            guard pendingResume == nil else { return }
            autoSkippedChapters.insert(intro.start)
            setSkipIntroActive(false)
            PlayerProbe.event("skip", String(format: "skip intro %.1f → %.1f (AUTOMATIC)",
                                             position, intro.end + Self.skipOvershoot))
            PlayerProbe.count("skip.auto")
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
        PlayerProbe.event("skip", String(format: "skip intro %.1f → %.1f (manual)",
                                         position, intro.end + Self.skipOvershoot))
        PlayerProbe.count("skip.manual")
        seek(to: intro.end + Self.skipOvershoot)
        setSkipIntroActive(false)
        showToast("Skipped intro")
    }

    private func showToast(_ text: String) {
        // The one thing the viewer can actually READ. A live session is a
        // conversation about what happened on screen, and without this the
        // probe records the cause while the person watching records the
        // message — with no way to line the two up.
        PlayerProbe.event("toast", text)
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
    /// True once the viewer (or the PiP row) picked an engine in THIS session,
    /// as opposed to one restored from PlaybackMemory — only the dev
    /// `-forceFFmpeg` flag cares, so it can beat the remembered engine without
    /// undoing a live switch.
    private var enginePickedThisSession = false
    var effectiveEngine: PlayerEngine {
        // Dev: `-forceFFmpeg` routes even mp4/HLS through the FFmpeg engine so
        // its render path can be exercised on a long public stream.
        if PlayerDevFlags.forceFFmpeg, !enginePickedThisSession {
            return .ffmpeg
        }
        return sessionEngine ?? settings.playerEngine
    }

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
        enginePickedThisSession = true
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
            // Windowed. This fires DURING playback (failover / Sources from the
            // player), and one task per add-on meant 40+ simultaneous requests
            // — each holding its response buffer — beside a live 4K decode and
            // the cache server's own connections. That is the jetsam
            // `BoundedConcurrency` exists to prevent.
            let batches = await boundedConcurrentMap(addons, limit: AddonSweepLimits.streams) { addon in
                let streams = (try? await StremioAPI.streams(addon: addon, type: type, id: id)) ?? []
                return streams
                    .filter { $0.isPlayable || (hasResolver && $0.isTorrent) }
                    .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
            }
            for batch in batches { entries.append(contentsOf: batch) }
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
        // A fresh load owns the open→first-frame gap too.
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
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
                PlayerProbe.event("watchdog", "LOAD TIMEOUT (DV) — falling back to FFmpeg after \(timeout)s")
                PlayerProbe.count("watchdog.dv-timeout")
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
            PlayerProbe.event("watchdog", "LOAD TIMEOUT — \(timeout)s with no playback")
            PlayerProbe.count("watchdog.load-timeout")
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
        // The episode being advanced to has a stream open — the switch is over,
        // so stop guarding and stop retrying.
        if advanceInFlight || advanceRetryTask != nil {
            PlayerProbe.event("next", "advance settled — the stream opened"
                + " (attempt \(max(advanceAttempt, 1)))")
            endAdvanceLadder()
        }
        if let started = loadStartedAt {
            let open = Date().timeIntervalSince(started)
            PlayerProbe.event("load", String(format: "OPENED in %.1fs", open))
            PlayerProbe.note("openSeconds", String(format: "%.1f", open))
        } else {
            PlayerProbe.event("load", "OPENED")
        }
        loadWatchdogTask?.cancel()
        loadWatchdogTask = nil
        // Hand off to the first-frame watchdog: this disarm fires at
        // `.readyToPlay` (the CONTAINER opened) or the first clock tick, but
        // the stall watchdog only covers sessions where `hasStartedPlayback`
        // is already true. A source that opens and then never presents a
        // frame (headers served then cut off; a read wedged in reconnect
        // cycles during the initial buffer) sat on the loading screen FOREVER
        // with no watchdog at all — "stuck loading, exit and retry works".
        armFirstFrameWatchdog()
        // NOTE: the failover-chain reset deliberately does NOT happen here.
        // See markPlaybackProgressed().
        playbackProgressBaseline = nil
    }

    private var firstFrameWatchdogTask: Task<Void, Never>?

    /// Covers the gap between "the container opened" and "a frame was
    /// presented". Fires a normal failover when playback never begins.
    private func armFirstFrameWatchdog() {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        guard !hasStartedPlayback else { return }
        let targetURL = currentURL
        firstFrameWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self,
                  !self.hasStartedPlayback,
                  !self.isExiting, !self.isFailingOver, !self.pauseIntent,
                  // Still the load that armed this — a switch re-arms its own.
                  self.currentURL == targetURL else { return }
            // The pre-cache phase HOLDS playback on purpose while it builds a
            // deep buffer, and it has its own bounded exits — give it another
            // window instead of shooting a healthy deep-buffer build.
            if self.loadPhase == .caching {
                self.armFirstFrameWatchdog()
                return
            }
            PlayerProbe.event("watchdog", "FIRST-FRAME TIMEOUT — open for 25s, never played")
            PlayerProbe.count("watchdog.first-frame")
            Self.dvTrail("first-frame watchdog: opened but never played — failing over")
            self.showToast("Source opened but never played — trying another")
            self.attemptFailover(
                afterError: NSError(
                    domain: "Orivio", code: -4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The source opened but never started playing."]
                ),
                preferResolution: self.currentEntry.resolutionLabel
            )
        }
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

    // MARK: - Notice clips

    /// Links that turned out to be a notice, keyed by URL so a duration
    /// reported over and over (VLC re-reports it on every tick) acts once.
    private var noticeClipURLs: Set<String> = []
    /// How many notice clips each addon has served this session. ONE is a bad
    /// link — that torrent isn't cached yet, nothing to hold against the rest
    /// of the addon's catalogue. TWO is the addon's whole debrid session (the
    /// wrong-IP case, an account out of traffic), and `viableFailoverCandidates`
    /// stops preferring it from then on.
    private var noticeClipsByAddon: [String: Int] = [:]

    /// How many links from each addon have DIED mid-playback this session.
    ///
    /// Same reasoning as the notice-clip tally above, and it earned its place
    /// the same way — on a real session. `debridmediamanager.com` began
    /// answering HTTP 500 to range requests at scattered byte offsets; the
    /// cache failed five times, the player failed over three times, and all
    /// three hops landed on ANOTHER link from the same provider, because
    /// `rankedCandidates` puts "same addon" first and a host being down is
    /// invisible to a ranking built out of resolution and addon name.
    ///
    /// ONE failure is a bad link — a torrent that isn't really cached, one
    /// expired URL — and says nothing about the addon's other links. TWO is the
    /// provider: its debrid session, its account, or its origin. Demoted from
    /// then on, never excluded, exactly as notice clips are: if nothing else
    /// plays, a link from a struggling provider still beats the error overlay.
    private var deadLinksByAddon: [String: Int] = [:]

    /// Links already counted above, so one death is charged ONCE.
    ///
    /// `attemptFailoverRetry` deliberately clears `isFailingOver` and re-enters
    /// when a candidate is consumed without ever loading, so the same dead link
    /// can pass the counting site several times in one chain. Keyed by entry id
    /// rather than guarded by a flag because that is the actual question being
    /// asked — how many DISTINCT links this addon has lost.
    private var deadLinkIDs: Set<UUID> = []
    /// True while the CURRENT source is a known notice clip, so its twenty
    /// seconds never reach Continue Watching — saved as a duration, that reads
    /// as a title watched to the end.
    private(set) var currentSourceIsNoticeClip = false

    /// The runtime the catalogue says this title has, when it says anything.
    private var expectedRuntimeSeconds: Double? { meta.runtimeSeconds }

    /// Is this a NOTICE rather than the title?
    ///
    /// Debrid services and the addons in front of them answer some requests
    /// with a short video that says what went wrong instead of an error:
    /// Real-Debrid's "this link must be requested from the same IP address it
    /// was generated with", the "this torrent is being downloaded to your
    /// debrid account, try again later" family, traffic-exhausted notices. They
    /// resolve, they open, they play — nothing in the pipeline fails — they are
    /// just twenty seconds of text where a feature film should be.
    ///
    /// Which is exactly what makes them detectable without reading a frame:
    /// they run a small fraction of the title's own length. The test is
    /// deliberately blunt, because the cost of being wrong is one silent
    /// failover to another link and the cost of missing one is the viewer
    /// staring at a message they can't do anything about.
    private func isNoticeClip(_ seconds: Double) -> Bool {
        // An unknown length is not a verdict — live and some HLS sources
        // legitimately report nothing.
        guard seconds > 0 else { return false }
        // Under three minutes is never the title. Every notice in the wild is a
        // matter of seconds, and nothing this app plays is a three-minute file
        // (trailers have their own player and never come through here).
        if seconds < 180 { return true }
        // Above that it takes a WILD mismatch, and only against a runtime the
        // catalogue actually knows. A tenth, not a fifth: the runtime on a
        // series is the show's typical episode, so a fifth of a 45-minute drama
        // is nine minutes — enough to throw out a genuinely short special. The
        // ten-minute cap then keeps a bogus runtime (a box set listed as one
        // 6000-minute title) from declaring most of a film a notice.
        guard let expected = expectedRuntimeSeconds, expected > 0 else { return false }
        return seconds < min(expected * 0.1, 600)
    }

    /// Called wherever a source's duration first becomes known. The VERDICT is
    /// re-established on every load; what FOLLOWS from it — counting it against
    /// the addon, keeping it out of the selector's next pass, handing the chain
    /// to the normal failover — acts once per link.
    private func noteDurationForNoticeCheck(_ seconds: Double) {
        // The dev demos play a deliberately short sample under a REAL movie id
        // (so metadata paths light up). The notice detector read the 10s file
        // as a debrid notice, failed over, swept the installed addons for
        // tt0111161 and replaced the demo with an actual 4 GB stream — on the
        // test box, mid-test. Keyed to the launch arg AND the demo's own
        // entry, so a real addon that happens to be NAMED "Demo" keeps its
        // notice protection.
        guard !(PlayerDevFlags.playerDemo && currentEntry.addonName == "Demo") else { return }
        guard !isExiting, isNoticeClip(seconds) else { return }
        // Above the dedup guard, because the suppression is per LOAD while the
        // guard's set is per SESSION: `resetPerLoadSessionState` clears the flag
        // on every load, so a link opened a SECOND time has to re-arm it before
        // the guard can return. Behind the guard it never did — "Try Again" on
        // the exhausted error screen reloads the very link that served the
        // notice (`attemptFailover` leaves `currentEntry` on it), and the second
        // time round its two minutes were saved as real progress. Anything over
        // a minute long then ends at 100%: a finished watch, so the title left
        // Continue Watching and Up Next counted down to the next episode.
        currentSourceIsNoticeClip = true
        let key = currentEntry.stream.url ?? currentEntry.rejectionKey
        guard noticeClipURLs.insert(key).inserted else { return }
        noticeClipsByAddon[currentEntry.addonName, default: 0] += 1
        let expected = expectedRuntimeSeconds ?? 0
        NSLog("[OrivioPlayer] notice clip from %@: %.0fs against an expected %.0fs — failing over",
              currentEntry.addonName, seconds, expected)
        Self.dvTrail("notice clip (\(Int(seconds))s) from \(currentEntry.addonName) — failing over")
        // The selector is deterministic: without this it hands back the same
        // link on the next press, and the next, for as long as the notice
        // stands.
        RejectedLinks.reject(currentEntry.rejectionKey,
                             for: ProgressStore.key(metaID: meta.id, video: currentVideo))
        attemptFailover(afterError: NSError(
            domain: "Orivio.Player", code: -20,
            userInfo: [NSLocalizedDescriptionKey:
                "This source played a \(Int(seconds))-second notice instead of the title "
                + "(a debrid \"same IP\" or \"still downloading\" message)."]
        ))
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
    private var isFailingOver = false {
        // Same re-arm rule as `pauseIntent`: the stall watchdog's fire path
        // stands down mid-failover, and with buffering writes deduped there
        // may be no later transition to arm a fresh one — a failover that
        // lands on another stalling link needs the watchdog back.
        didSet {
            if oldValue, !isFailingOver { updateStallWatchdog() }
        }
    }

    /// A stream died. Remember the survivors' position, pick the next viable
    /// source, and switch to it silently — the error overlay only appears when
    /// every candidate is exhausted. `preferResolution` floats sources of the
    /// same quality to the front (used by the load-timeout failover, so a slow
    /// 4K link is replaced by another 4K link, not a random 480p one).
    private func attemptFailover(afterError error: Error, preferResolution: String? = nil,
                                 continuing generation: Int? = nil) {
        PlayerProbe.event("fail", "FAILOVER requested at \(String(format: "%.1f", position))"
            + " — \(error.localizedDescription)"
            + " (already failing over=\(isFailingOver.probe), dv=\(usingDVDirect.probe))")
        PlayerProbe.count("failover.requested")
        PlayerProbe.note("lastError", error.localizedDescription)
        // Direct sample engine stalled/died → drop to the next tier on the
        // same source rather than burning a different link.
        if usingDVDirect {
            Self.dvTrail("direct engine failover — \(error.localizedDescription)")
            isFailingOver = false
            isSwitchingSource = false
            fallBackFromDirect(entry: currentEntry, reason: error.localizedDescription)
            return
        }
        // (The native-remux branch that followed went with its tier. It was a
        // bare `return` — a failover request swallowed whole, no engine change,
        // no error, no next source — which is precisely what a stray
        // `usingNativeDV = true` turned every stall into.)
        guard !isFailingOver else {
            PlayerProbe.event("fail", "DROPPED — a failover is already in flight")
            PlayerProbe.count("failover.dropped")
            return
        }
        isFailingOver = true
        // Charge the failure to the addon whose link just died. Here, not at
        // the top: the direct-engine branch above returns having only changed
        // TIER on the same source, which is not the link failing at all.
        // Keyed by entry id because `isFailingOver` is NOT enough on its own —
        // `attemptFailoverRetry` clears it and re-enters for the same dead
        // link, which would charge one death two or three times over.
        if deadLinkIDs.insert(currentEntry.id).inserted {
            // KEYED ON `sourceAddonName`, NOT `addonName`.
            //
            // A debrid or P2P resolve builds a NEW entry labelled
            // "RD · Torrentio" (StreamsView), while every candidate still
            // waiting in `allEntries` is plain "Torrentio". Counting under the
            // prefixed name and looking up under the bare one would never
            // match, and the demotion below would be dead code for exactly the
            // links that need it most — resolved debrid links are the ones that
            // die. `sourceAddonName` strips the resolver prefix, so both sides
            // agree.
            let addon = currentEntry.sourceAddonName
            deadLinksByAddon[addon, default: 0] += 1
            PlayerProbe.event("fail", "\(addon) has now lost"
                + " \(deadLinksByAddon[addon] ?? 0) link(s) this session")
        }
        // The chain below re-scrapes and resolves over the network — seconds in
        // which the viewer can pick a source from the panel, change episode, or
        // exit. Anything it decides is about the stream that FAILED, so it must
        // not be applied to whatever replaced it.
        // A chain CONTINUED from a torrent hand-off keeps the generation it
        // started with. Re-capturing it here let the continuation pass its own
        // staleness check for free — and then blacklist whatever `currentEntry`
        // had become in the meantime, permanently, for a source the viewer had
        // just picked themselves.
        let failoverGeneration = generation ?? loadGeneration
        guard isCurrentLoad(failoverGeneration) else {
            isFailingOver = false
            // The cover flag rides with it. A hand-off sets `handedOff` so the
            // defer skips both, and if the re-entry then lands here the cover
            // is stranded on screen with the transport disabled underneath.
            isSwitchingSource = false
            return
        }
        stallWatchdogTask?.cancel()
        // A stall near the end of an episode can land with Up Next already
        // counting down. Both then load: the countdown starts the NEXT episode
        // while the failover opens a replacement for THIS one. The generation
        // guard now stops the loser writing its state, but the wasted scrape
        // and the flicker are avoidable — the viewer is not finished with this
        // episode, they are watching it fail.
        countdownTask?.cancel()
        upNextCountdown = nil
        // Capture what to aim for ONCE per chain (the link that just died is,
        // on the first failure, the original the user was on): prefer the same
        // addon, then the closest quality.
        if chainPreferredAddon == nil {
            chainPreferredAddon = currentEntry.sourceAddonName
            chainPreferredResolution = preferResolution ?? currentEntry.resolutionLabel
        }
        failedSourceIDs.insert(currentEntry.id)
        if let deadURL = currentEntry.stream.url { failedSourceURLs.insert(deadURL) }
        // `position` is ~0 while a resume seek is still in flight and
        // `pendingResume` is cleared the moment it lands, so neither alone
        // survives a failure in that window — hence the session floor.
        let resumeAt = max(max(position, pendingResume ?? 0), sessionResumeFloor)
        switchingSourceLabel = "Trying another source…"
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
            guard self.isCurrentLoad(failoverGeneration) else { return }
            guard var next = candidates.first else {
                // The RAW error goes to the decision log, not to the screen.
                // `localizedDescription` here is whatever URLSession, FFmpeg or
                // the demuxer produced — "The request timed out", an OSStatus,
                // sometimes a bare error code. None of that tells a viewer
                // anything they can act on, and it is exactly the kind of
                // implementation detail that must never reach them.
                self.decisionLog.record("Error", "every source exhausted",
                                        because: error.localizedDescription)
                self.overlay = .error(
                    "This title wouldn't play.\n\nEvery source was tried — they may be "
                    + "offline, expired, or unavailable in your region."
                )
                return
            }
            // RETIRE THE CANDIDATE THE MOMENT IT IS CHOSEN, before any
            // resolve. A torrent that resolves successfully is replaced below by
            // a NEW StreamEntry with a fresh UUID and a freshly-signed URL, so
            // nothing ever marked the original magnet row dead: it stayed
            // viable, ranked identically, and was re-picked on the next hop —
            // for ever, because a debrid link is signed anew on every resolve
            // and so never matches `failedSourceURLs` either. `retryPlayback`
            // still clears both sets, so a deliberate retry gets it back.
            self.failedSourceIDs.insert(next.id)
            if let u = next.stream.url { self.failedSourceURLs.insert(u) }
            // Torrent candidate → resolve to a direct link first.
            if next.stream.isTorrent {
                guard let resolver = self.torrentResolver,
                      let resolved = await resolver(next.stream) else {
                    self.failedSourceIDs.insert(next.id)
                    if let u = next.stream.url { self.failedSourceURLs.insert(u) }
                    handedOff = true
                    self.attemptFailoverRetry(afterError: error, continuing: failoverGeneration)
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
                    self.attemptFailoverRetry(afterError: error, continuing: failoverGeneration)
                    return
                }
                next = StreamEntry(addonName: next.addonName, stream: resolved)
            }
            // The scrape / debrid re-resolve above can take many seconds. If the
            // viewer exited during it, stop here — `load()` would otherwise open
            // a fresh stream behind the dismissed player (the same orphaned
            // playback `player(layer:finish:)` guards against up front).
            // Still the stream that failed? A source the viewer picked
            // themselves, or a newer failover, outranks this one.
            guard self.isCurrentLoad(failoverGeneration) else { return }
            // Say WHICH failure this was. A link that opened, played, and was
            // simply the wrong file reads as the app switching for no reason
            // otherwise. (`currentSourceIsNoticeClip` still describes the
            // OUTGOING source here — `load` below is what clears it.)
            self.showToast(self.currentSourceIsNoticeClip
                ? "That link returned a message, not the title — trying \(next.addonName)"
                : "Source failed — trying \(next.addonName)")
            PlayerProbe.event("fail", String(
                format: "SWITCHING to %@ / %@ at %.1f (notice-clip=%@)",
                next.addonName, String(next.displayName.prefix(40)), resumeAt,
                self.currentSourceIsNoticeClip.probe))
            PlayerProbe.count("failover.switched")
            self.currentEntry = next
            self.pendingResume = resumeAt > 10 ? resumeAt : nil
            self.load(entry: next)
            self.runStreamProbe()
        }
    }

    /// "Try Again" from the error screen: forget what failed in THIS chain and
    /// start over on the source the viewer chose.
    ///
    /// The dead-link sets are per-chain evidence, not permanent truth — a CDN
    /// that timed out a minute ago is often fine now, and after a failover has
    /// walked the whole list the only way back to the preferred source is to
    /// clear them. Position is preserved: retrying is not restarting.
    func retryPlayback() {
        guard !isExiting else { return }
        PlayerProbe.event("fail", "RETRY requested by the viewer — clearing the dead-link sets")
        PlayerProbe.count("failover.retry")
        failedSourceIDs.removeAll()
        failedSourceURLs.removeAll()
        didFailoverRefetch = false
        chainPreferredAddon = nil
        chainPreferredResolution = nil
        isFailingOver = false
        overlayBeforeSubMenu = nil
        overlay = .none
        // "No playable sources found for SxxEyy" is a different dead end: the
        // thing that failed is not `currentEntry`, because that episode never
        // got as far as having one. Reloading `currentEntry` here restarted the
        // episode that had just FINISHED at its end position — it played the
        // last seconds, hit the end again, re-armed Up Next and came back to
        // the identical error, rewriting the old episode's progress on every
        // pass while the message named an episode nothing had touched. Retry
        // the episode the viewer is actually being told about.
        if let episode = episodeAwaitingSources {
            play(episode: episode)
            return
        }
        pendingResume = resumeTargetForReload > 10 ? resumeTargetForReload : nil
        decisionLog.record("Error", "retry requested", because: "viewer chose Try Again")
        load(entry: currentEntry)
        runStreamProbe()
    }

    /// Sources not yet marked dead (by UUID or URL), ordered to match the
    /// original link as closely as possible: SAME ADDON + same quality first,
    /// then same addon (any quality), then same quality (other addons), then the
    /// rest — stable within each tier so cached-first order survives.
    /// Addons an auto-advance may fall back onto, in order, when the Auto Link
    /// Selector is on: the preferred one, then the secondary one. Empty when
    /// the selector is off or names nothing, which means "no restriction".
    private var advanceAddonAllowList: [String] {
        guard autoLinkPrefs.enabled else { return [] }
        return [autoLinkPrefs.preferredAddon, autoLinkPrefs.secondaryAddon]
            .filter { !$0.isEmpty }
    }

    private func viableFailoverCandidates() -> [StreamEntry] {
        let viable = allEntries.filter { entry in
            // PLAYABLE ONLY. `allEntries` is the source page's raw pool, which
            // deliberately admits cast / hand-off rows so they stay selectable
            // there — but they carry no URL, so failing over onto one lands in
            // `load()`'s no-URL branch and raises "This source has no playable
            // link" with working sources still untried. That branch returns
            // before the watchdogs are armed and before the entry is retired,
            // so nothing recovers and Try Again re-raises it on the same row.
            guard entry.stream.isPlayable || entry.stream.isTorrent else { return false }
            return !failedSourceIDs.contains(entry.id)
                && !failedSourceURLs.contains(entry.stream.url ?? "")
        }
        // An ADVANCE is bounded to the addons the selector names. Only while
        // one is in flight: a failover during ordinary playback is the viewer
        // watching something that broke, and narrowing their options there
        // would strand them on a dead link with working sources untried.
        let allowed = advanceAddonAllowList
        if advanceInFlight, !allowed.isEmpty {
            let restricted = viable.filter { allowed.contains($0.addonName) }
            guard restricted.isEmpty else { return rankedCandidates(restricted) }
            PlayerProbe.event("next", "no candidates left on \(allowed.joined(separator: " / "))"
                + " — the advance stops here rather than walking the whole pool")
            return []
        }
        return rankedCandidates(viable)
    }

    /// Order candidates to match the original link as closely as possible.
    private func rankedCandidates(_ viable: [StreamEntry]) -> [StreamEntry] {
        func rank(_ e: StreamEntry) -> Int {
            // An addon that has served two notice clips this session is not a
            // preference any more — "request this from the same IP" is a
            // condition of its whole debrid session, not of one link, so its
            // next link is a notice too. Demoted, not excluded: if nothing else
            // plays, it is still better than the error overlay.
            if noticeClipsByAddon[e.addonName, default: 0] >= 2 { return 4 }
            // And an addon whose links keep dying under us. Two is the
            // provider rather than the link — see `deadLinksByAddon`.
            if deadLinksByAddon[e.sourceAddonName, default: 0] >= 2 { return 4 }
            let sameAddon = chainPreferredAddon != nil && e.sourceAddonName == chainPreferredAddon
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
    private func attemptFailoverRetry(afterError error: Error, continuing generation: Int) {
        isFailingOver = false
        attemptFailover(afterError: error, continuing: generation)
    }

    func switchSource(_ entry: StreamEntry) {
        PlayerProbe.event("fail", "VIEWER PICKED \(entry.addonName)"
            + " / \(entry.displayName.prefix(40))"
            + " (torrent=\(entry.stream.isTorrent.probe) same=\((entry.id == currentEntry.id).probe))")
        PlayerProbe.count("source.user-switch")
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
            // The viewer picked this one themselves — say so, rather than
            // implying the player gave up on something.
            switchingSourceLabel = "Switching source…"
            isSwitchingSource = true
            let resumeAt = resumeTargetForReload
            let generation = loadGeneration
            Task { [weak self] in
                guard let self else { return }
                defer { self.isSwitchingSource = false }
                guard let resolved = await resolver(entry.stream) else {
                    self.showToast("Couldn't resolve this source — try another")
                    return
                }
                // Debrid resolution takes seconds; the viewer may have left, or
                // a failover or another pick may have loaded something else in
                // the meantime. Loading now would strand a playing layer behind
                // the dismissed player, or replace a stream the viewer chose
                // after this one.
                guard self.isCurrentLoad(generation) else { return }
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
        // By id first; by season/episode when the ids disagree. A session
        // that started from Continue Watching (or from an addon that numbers
        // episodes its own way) carried a video id in one form while the
        // enriched list used another, so the current episode was never found
        // in its own list and there was "no next episode" for the whole show.
        var index = ordered.firstIndex(where: { $0.id == current.id })
        if index == nil, let season = current.season, let episode = current.episode {
            index = ordered.firstIndex(where: { $0.season == season && $0.episode == episode })
        }
        guard let index else { return nil }
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
        // Threshold first: `nextEpisode` filters and sorts the whole episode
        // list, and this runs on every 10 Hz clock tick for the entire film.
        // An advance already asked for is not a reason to ask again. Until the
        // new episode's stream opens, every value this function reads still
        // describes the OUTGOING one.
        guard !advanceInFlight, !isSwitchingSource else { return }
        guard !autoAdvanceArmed, crossedNextEpisodeThreshold() else { return }
        // A menu the viewer is using outranks the card — but WAIT for it, do
        // not arm behind it. `armUpNext` declined to show over these and this
        // had already latched `autoAdvanceArmed`, so an episode whose credits
        // began while the subtitle picker was open never got its card at all.
        let interactive: [PlayerOverlay] = [.episodes, .sources, .audio, .subtitles, .speed]
        guard !interactive.contains(overlay), let next = nextEpisode else { return }
        autoAdvanceArmed = true
        armUpNext(episode: next, atEnd: false)
    }

    /// Show the Up Next card and, unless the timeout is "unlimited", start the
    /// countdown that auto-advances. Doesn't interrupt an interactive overlay
    /// the user has opened (episodes/sources/etc).
    private func armUpNext(episode: MetaVideo, atEnd: Bool) {
        PlayerProbe.event("next", "ARM Up Next \(episode.seasonEpisodeCode)"
            + " atEnd=\(atEnd.probe) overlay=\(overlay.probeName)"
            + String(format: " at %.1f of %.1f", position, duration))
        upNextEpisode = episode
        // Don't yank focus from a menu the user is actively using; the end-of-
        // content path (atEnd) always shows it since playback has stopped.
        let interactive: [PlayerOverlay] = [.episodes, .sources, .audio, .subtitles, .speed]
        if !atEnd && interactive.contains(overlay) { return }
        // NEVER over a dead end the viewer still needs to read. Replacing a
        // playback error or a Still Watching gate with Up Next — and then
        // auto-advancing three seconds later — takes Try Again and Other
        // Sources away from someone who was looking straight at them. `atEnd`
        // deliberately does not exempt this: at the end of a title those two
        // still outrank the card.
        switch overlay {
        case .error, .stillWatching: return
        default: break
        }
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
    ///
    /// `finishingCurrent` retires the outgoing episode's Continue Watching row
    /// instead of saving a position in it. True for every path that reaches
    /// here at the end of an episode — the card, the countdown — and false
    /// only for the transport's Next Episode button pressed early, where the
    /// viewer has not finished anything yet.
    private func advanceToNext(userInitiated: Bool, finishingCurrent: Bool = true) {
        PlayerProbe.event("next", "ADVANCE (\(userInitiated ? "viewer" : "countdown"))")
        PlayerProbe.count("next.advance")
        countdownTask?.cancel()
        upNextCountdown = nil
        guard let episode = upNextEpisode else { return }

        if !userInitiated, settings.stillWatchingEnabled,
           consecutiveAutoAdvances + 1 >= settings.stillWatchingEpisodeThreshold {
            // Engine-agnostic: pausing only `playerLayer` left VLC and DV
            // sessions playing underneath the gate, and skipping the pause
            // INTENT let the next buffering callback flip `isPlaying` back on.
            enginePause("Still Watching gate")
            overlay = .stillWatching
            return
        }
        consecutiveAutoAdvances = userInitiated ? 0 : consecutiveAutoAdvances + 1
        // THE ONLY TWO THINGS THAT MAY START AN ADVANCE: this function, reached
        // from the Play Next button or from the countdown running out. Nothing
        // else re-attempts on its own any more (see `advanceInFlight`).
        advanceTarget = episode
        advanceAttempt = 1
        advanceDeferrals = 0
        // ALWAYS auto-advance onto the best link — do NOT open the source list
        // up front.
        //
        // With auto-selection off this used to hand the viewer the list AND
        // start the auto-pick behind it, so a link was already playing under a
        // panel that was supposed to be a choice: the screen appeared, the
        // episode was already running beneath it, and a binge needed a dismiss
        // it was never meant to. The next episode now just plays; if it cannot
        // start, the retry ladder ends on the error card, whose "Other Sources"
        // opens the list on demand — and the Up Next card's long-press "Select
        // Source" is still the explicit way in.
        PlayerProbe.event("next", "advance → auto"
            + (advanceAddonAllowList.isEmpty
                ? "" : " on \(advanceAddonAllowList.joined(separator: " / "))"))
        play(episode: episode, autoAdvance: !userInitiated, presentSources: false,
             finishingCurrent: finishingCurrent)
        advanceTarget = episode      // `play` clears the ladder's bookkeeping
        advanceAttempt = 1
        scheduleAdvanceRetry()
    }

    /// Wait, then try the next episode once more — twice, then give up.
    ///
    /// The old behaviour had no ladder at all: the re-arm loop fired another
    /// advance on the next clock tick, so a next episode that was merely SLOW
    /// to open got restarted from scratch every time, which is the one thing
    /// guaranteed to stop it ever opening. Spacing the attempts gives the
    /// stream the time it actually needs, and bounding them means a genuinely
    /// dead episode still reaches the error card instead of looping.
    ///
    /// `advanceAttempt` counts PLAYS issued (1 after the first), so
    /// `advanceAttempt - 1` is how many retries have been spent and indexes
    /// the delay for the next one. Once they are spent the ladder waits one
    /// last interval — so the final retry gets the same chance as the others
    /// before the error card replaces it — and then gives up.
    private func scheduleAdvanceRetry() {
        advanceRetryTask?.cancel()
        let retriesSpent = advanceAttempt - 1
        let isFinalGrace = retriesSpent >= Self.advanceRetryDelays.count
        let delay = isFinalGrace
            ? (Self.advanceRetryDelays.last ?? 10)
            : Self.advanceRetryDelays[retriesSpent]
        let target = advanceTarget
        advanceRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isExiting,
                  self.advanceTarget?.id == target?.id else { return }
            // The stream opened while we were waiting — `markLoadStarted` tore
            // the ladder down already, so there is nothing left to do.
            guard self.advanceInFlight else { return }
            guard !isFinalGrace else { self.failAdvance(); return }
            // The source fetch is STILL RUNNING. Starting a second one would
            // stack two sweeps against the same episode, which is exactly the
            // stacking this change exists to remove — so wait again WITHOUT
            // spending a retry. Bounded, so a fetch that never returns cannot
            // hold the ladder open forever.
            if self.isSwitchingSource {
                self.advanceDeferrals += 1
                guard self.advanceDeferrals <= Self.maxAdvanceDeferrals else {
                    self.failAdvance()
                    return
                }
                PlayerProbe.event("next", "advance retry deferred"
                    + " (\(self.advanceDeferrals)/\(Self.maxAdvanceDeferrals))"
                    + " — the source fetch is still running")
                self.scheduleAdvanceRetry()
                return
            }
            guard let episode = target else { return }
            PlayerProbe.event("next", "advance RETRY \(self.advanceAttempt)"
                + " for \(episode.seasonEpisodeCode) after \(delay)s")
            PlayerProbe.count("next.advance-retry")
            // `play` re-claims the window and resets this bookkeeping, so the
            // ladder's own state is restored immediately after it.
            let attempt = self.advanceAttempt + 1
            let deferrals = self.advanceDeferrals
            self.play(episode: episode, autoAdvance: true)
            self.advanceTarget = episode
            self.advanceAttempt = attempt
            self.advanceDeferrals = deferrals
            self.scheduleAdvanceRetry()
        }
    }

    /// Both retries are spent and nothing opened — land on the error card, the
    /// same dead end a failed first play reaches, with Try Again and Other
    /// Sources on it.
    private func failAdvance() {
        guard let episode = advanceTarget else { endAdvanceLadder(); return }
        PlayerProbe.event("next", "advance GAVE UP on \(episode.seasonEpisodeCode)"
            + " after \(Self.advanceRetryDelays.count) retries")
        PlayerProbe.count("next.advance-failed")
        endAdvanceLadder()
        // So Try Again / Other Sources act on the episode being named rather
        // than on the stream that finished — the same reason `play(episode:)`
        // records it on an empty source lookup.
        episodeAwaitingSources = episode
        overlay = .error("Couldn't start \(episode.seasonEpisodeCode).")
    }

    private func endAdvanceLadder() {
        advanceRetryTask?.cancel()
        advanceRetryTask = nil
        advanceInFlight = false
        advanceTarget = nil
        advanceAttempt = 0
        advanceDeferrals = 0
    }

    /// User pressed "Play Next Episode" on the Up Next card.
    func playUpNextNow() {
        advanceToNext(userInitiated: true)
    }

    /// Viewer pressed the transport's Next Episode button.
    ///
    /// Separate from `playUpNextNow()` because that one answers a card which
    /// only exists at the end of an episode, so it can assume the episode is
    /// over. This button is on screen for the whole episode and cannot.
    ///
    /// Past the point where the Up Next card would have armed on its own, this
    /// is the same thing that card's Play Next does, so the outgoing episode is
    /// retired exactly as it would have been. Pressed EARLY it is a viewer
    /// skipping ahead, and `markFinished` there would delete a Continue
    /// Watching row they are ten minutes into — and tell the account to delete
    /// it too. Their position is saved instead, so the episode is still where
    /// they left it.
    ///
    /// Everything downstream is the card's own path, so the binge-group and
    /// auto-link rules, the source-list fallback and the retry ladder all
    /// behave identically.
    func playNextEpisodeFromControls() {
        // An advance already under way is not a reason to start another: the
        // controls go away the moment one begins, but a second press landing
        // in the same frame would otherwise get through.
        guard !advanceInFlight, !isSwitchingSource, !isExiting else { return }
        guard let episode = nextEpisode else { return }
        let finishing = crossedNextEpisodeThreshold()
        PlayerProbe.event("next", "TRANSPORT BUTTON → \(episode.seasonEpisodeCode)"
            + " finishingCurrent=\(finishing.probe)")
        upNextEpisode = episode
        advanceToNext(userInitiated: true, finishingCurrent: finishing)
    }

    /// Long-press "Select Source" on the Up Next card — advance to the next
    /// episode but open its Sources panel to pick a link.
    func playUpNextChoosingSource() {
        countdownTask?.cancel()
        upNextCountdown = nil
        guard let episode = upNextEpisode else { return }
        consecutiveAutoAdvances = 0
        play(episode: episode, presentSources: true, finishingCurrent: true)
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
        play(episode: episode, autoAdvance: false, finishingCurrent: true)
    }

    /// Replay the finished title from the start (post-play overlay).
    func replay() {
        PlayerProbe.event("next", "REPLAY from the start")
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
        PlayerProbe.event("next", String(
            format: "PLAYED TO END at %.1f of %.1f (handled=%@ switching=%@)",
            position, duration, playedToEndHandled.probe, isSwitchingSource.probe))
        // Idempotent by contract. Engines are not consistent about how many
        // times they announce the end — the direct DV engine reported it from a
        // media-request callback — and re-running this re-publishes progress
        // and re-assigns the overlay, which churns the whole UI.
        guard !playedToEndHandled else { return }
        // An end that arrives while a switch is in flight belongs to the
        // stream being REPLACED, not to what the viewer is about to watch.
        // Acting on it re-arms Up Next against the outgoing episode and
        // auto-advances a second time onto the one already loading. Noted,
        // though: if the switch aborts without loading anything, this end is
        // the only one the engine will ever announce (see isSwitchingSource).
        guard !isSwitchingSource else { pendingEndAfterSwitch = true; return }
        playedToEndHandled = true
        saveProgress()
        if let next = nextEpisode {
            autoAdvanceArmed = true
            armUpNext(episode: next, atEnd: true)
        } else {
            // Same precedence `armUpNext` applies: a decision the viewer is in
            // the middle of making outranks the end-of-title card, and `atEnd`
            // does not exempt it. The error screen is the loud case — an
            // exhausted failover leaves whatever last OPENED still running
            // underneath it (a 20-second debrid notice clip, usually), and when
            // that clip hit its own end the card replaced "This title wouldn't
            // play", taking Try Again and Other Sources with it.
            switch overlay {
            case .error, .stillWatching:
                break
            default:
                overlay = .postPlay
            }
        }
    }

    /// The episode whose source lookup came back EMPTY, kept so the error
    /// screen's actions can be aimed at it. At the moment that bail-out fires
    /// none of the new episode's state is committed — `currentVideo`,
    /// `currentEntry`, `allEntries` and `sessionResumeFloor` all still belong
    /// to the episode that just finished — so anything reading the session
    /// there is reading the wrong title.
    private var episodeAwaitingSources: MetaVideo?

    /// Play a specific episode. `presentSources` opens the Sources panel once
    /// the episode's links are loaded (the "Choose Source" long-press action),
    /// so the viewer can pick a link instead of taking the auto-selected one.
    /// - Parameter finishingCurrent: the episode being left behind is DONE —
    ///   retire its Continue Watching row instead of saving a position in it.
    ///   True whenever the viewer arrives here from the Up Next card (the
    ///   countdown, Play Next, or the Still Watching gate), which is a
    ///   statement that this episode is over however far through it the
    ///   credits happened to start. False for the Episodes panel, where
    ///   jumping to another episode says nothing about the one you are on.
    func play(episode: MetaVideo, autoAdvance: Bool = false, presentSources: Bool = false,
              finishingCurrent: Bool = false) {
        // The player is closing (or gone): never start a new stream. Its
        // source fetch takes seconds, so a countdown that fires — or an
        // Episodes-panel tap — as the viewer exits used to land a load() on a
        // dismissed player: a fresh layer playing audio with no UI to stop it.
        guard !isExiting else {
            PlayerProbe.event("next", "play(episode:) REFUSED — the player is exiting")
            return
        }
        PlayerProbe.event("next", "PLAY EPISODE \(episode.seasonEpisodeCode)"
            + " autoAdvance=\(autoAdvance.probe) presentSources=\(presentSources.probe)")
        PlayerProbe.count("next.episode-load")
        // A fresh episode attempt answers the previous empty-sources dead end,
        // whether or not this one finds links.
        episodeAwaitingSources = nil
        overlay = .none
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextEpisode = nil
        autoAdvanceArmed = false
        advanceInFlight = true
        if !autoAdvance { consecutiveAutoAdvances = 0 }
        switchingSourceLabel = "Loading next episode…"
        isSwitchingSource = true
        playedToEndHandled = false
        if finishingCurrent, let leaving = currentVideo {
            // Retire rather than save. A plain `saveProgress()` here writes the
            // outgoing episode at its credits-chapter fraction, which is often
            // under the store's 95% finish threshold — so it stayed in Continue
            // Watching and the viewer came back to the episode they had just
            // watched instead of the one they moved on to.
            PlayerProbe.event("progress", "FINISHED \(leaving.seasonEpisodeCode)"
                + String(format: " at %.1f of %.1f — retiring its Continue Watching row",
                         position, duration))
            PlayerProbe.count("progress.episode-finished")
            progressStore.markFinished(meta: meta, video: leaving)
        } else {
            saveProgress()
        }
        // The outgoing episode is settled. Nothing saves again until this
        // episode's stream loads — see `episodeSwitchTargetID`.
        episodeSwitchTargetID = episode.id
        engineStopForSwitch()
        let hasResolver = torrentResolver != nil
        Task {
            defer { isSwitchingSource = false }
            var entries: [StreamEntry] = []
            if let directEpisodeResolver {
                // A library server's episode: its own file, no add-on sweep.
                if let entry = await directEpisodeResolver(episode) { entries = [entry] }
            } else {
                // Normalize the episode id the SAME way the initial-play path
                // (StreamsView.effectiveStreamID) does: stream addons speak IMDb
                // `tt` ids and need the canonical `showId:season:episode` form. The
                // raw `episode.id` from enriched metadata can be a `tmdb:` id or —
                // after a Continue-Watching round-trip — a bare show id, neither of
                // which any addon can resolve, which is why switching episodes from
                // the in-player list produced no working source.
                var showID = meta.id
                if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
                   let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
                    showID = tt
                }
                let streamID: String
                if showID.hasPrefix("tt"), let season = episode.season, let ep = episode.episode {
                    streamID = "\(showID):\(season):\(ep)"
                } else {
                    streamID = episode.id
                }
                let addons = addonManager.streamAddons.filter { $0.handles(id: streamID) }
                // Windowed, for the same reason as the failover sweep above: this
                // runs while the outgoing episode is still on screen.
                let mediaType = meta.type
                let batches = await boundedConcurrentMap(addons, limit: AddonSweepLimits.streams) { addon in
                    let streams = (try? await StremioAPI.streams(addon: addon, type: mediaType, id: streamID)) ?? []
                    // Keep cached torrents too when a debrid resolver exists, so
                    // the Choose-Source list isn't just direct links.
                    return streams
                        .filter { $0.isPlayable || (hasResolver && $0.isTorrent) }
                        .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                }
                for batch in batches {
                    entries.append(contentsOf: batch)
                }
            }
            guard !entries.isEmpty else {
                // Nothing below this point has run yet, so the session is
                // still the PREVIOUS episode's. Record the episode the message
                // names, or the error screen's buttons act on the stream that
                // just ended instead of on the one that has no sources.
                episodeAwaitingSources = episode
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
            // the episode's sources were being fetched — or a SECOND
            // `play(episode:)` may have superseded this one. Without the
            // identity check, the slower of two overlapping picks wins and
            // hijacks the session back to the episode the viewer already left
            // (`episodeSwitchTargetID` is only cleared once a stream actually
            // loads, which cannot have happened yet).
            guard !isExiting, episodeSwitchTargetID == episode.id else { return }
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
            } else if !presentSources, let resolver = torrentResolver,
                      let torrent = panelEntries.first(where: \.stream.isTorrent) {
                // ONLY TORRENTS, BUT A DEBRID RESOLVER IS CONFIGURED — so there
                // IS a usable source here and the advance should not be handing
                // the viewer a picker. Resolving one is what every other path
                // in this file already does with a torrent candidate: the
                // viewer's own source switch (`switchSource`) and the failover
                // ladder both call `torrentResolver` and load the direct link
                // it returns. Only the auto-advance refused, so an episode
                // whose sources happened to come back as torrents interrupted a
                // binge with the source list — "Auto Pick occasionally shows
                // the source-selection screen between episodes".
                //
                // The curated-first torrent, which is exactly the row the
                // picker below would have pre-selected, so the automatic choice
                // and the manual default agree.
                //
                // Purely a FALLBACK: reached only where the picker was opening
                // anyway. A directly-playable link still wins whenever one
                // exists, and with Auto Pick off (`presentSources`) the viewer
                // still gets the list they asked for.
                currentEntry = torrent
                let resolved = await resolver(torrent.stream)
                // Debrid resolution takes seconds. Re-checked for the same
                // reason `switchSource` re-checks its load generation: the
                // viewer may have exited, or a later advance may have moved on
                // to a different episode, and loading now would strand a stream
                // behind them.
                guard !isExiting, currentVideo?.id == episode.id else { return }
                if let resolved {
                    let direct = StreamEntry(addonName: torrent.addonName, stream: resolved)
                    currentEntry = direct
                    load(entry: direct)
                } else {
                    // Couldn't resolve — the picker is the right answer after
                    // all, which is where this case landed before.
                    overlay = .sources
                }
            } else {
                // Only torrents available and nothing can resolve them (no
                // debrid key) — go straight to the picker.
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
        // Same two gates as `saveProgress`: mid-switch the clock and the
        // episode disagree, and after an exit that retired the episode a tick
        // would write it back as a periodic row.
        guard episodeSwitchTargetID == nil, !retiredEpisodeOnExit else { return }
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
        // Never record a notice clip: saved with its own twenty-second length,
        // it lands in Continue Watching as a title watched to the end.
        guard !currentSourceIsNoticeClip else { return }
        lastProgressSave = Date()
        // The FIRST save and then every 3rd (~30s) also nudge the account
        // push, so another device sees the film in progress within seconds of
        // it starting and follows the position as you watch — instead of the
        // two-minute lag this used to have. The push encodes off-main and is
        // one small POST. No publish: see requestSyncPush.
        transientSaveCount &+= 1
        if transientSaveCount == 1 || transientSaveCount % 3 == 0 { progressStore.requestSyncPush() }
        progressStore.updateTransient(
            meta: meta,
            video: currentVideo,
            streamURL: currentEntry.stream.url,
            // While a resume seek is in flight (DV switch, item recycle),
            // `position` reads 0 for a few seconds — saving that would stomp
            // Continue Watching with the top of the movie. The session floor
            // covers the switch windows where `pendingResume` has already been
            // consumed: it is the last position a seek or switch aimed at, and
            // a user seek REPLACES it (down included), so it never drags a
            // save forward of the viewer's own intent.
            position: max(max(position, pendingResume ?? 0), sessionResumeFloor),
            duration: duration,
            signature: currentEntry.stream.signature(addonName: currentEntry.addonName)
        )
    }

    func saveProgress() {
        guard !currentSourceIsNoticeClip else {
            PlayerProbe.event("progress", "SAVE SUPPRESSED — this source is a notice clip")
            return
        }
        if let target = episodeSwitchTargetID {
            PlayerProbe.event("progress", "SAVE SUPPRESSED — switching to episode \(target), its stream has not loaded")
            return
        }
        guard !retiredEpisodeOnExit else {
            PlayerProbe.event("progress", "SAVE SUPPRESSED — the exit retired this episode as finished")
            return
        }
        let saved = max(max(position, pendingResume ?? 0), sessionResumeFloor)
        PlayerProbe.event("progress", String(
            format: "SAVE %.1f of %.1f (position=%.1f pendingResume=%@ floor=%.1f)",
            saved, duration, position,
            pendingResume.map { String(format: "%.1f", $0) } ?? "-", sessionResumeFloor))
        PlayerProbe.count("progress.saves")
        lastProgressSave = Date()
        Self.dvTrail(String(format: "progress saved: pos=%.0fs of %.0fs", position, duration))
        progressStore.update(
            meta: meta,
            video: currentVideo,
            streamURL: currentEntry.stream.url,
            position: max(max(position, pendingResume ?? 0), sessionResumeFloor),
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
        endAdvanceLadder()
        PlayerProbe.event("player", "exit")
        unregisterProbes()
        // LEAVING AFTER THE CREDITS IS FINISHING.
        //
        // The store retires an episode at 95%, but the point at which a viewer
        // is done with one is where the credits start — which is exactly where
        // the Up Next card arms, and on a show with long credits that can be
        // several percent short of the threshold. Walking out there used to
        // save a position instead of retiring the row, so Continue Watching
        // went on offering the episode just watched. Only when a next episode
        // actually exists: on the last one of a series there is nothing to
        // move on to, and the position is worth keeping. Never mid-switch: the
        // Up Next state read here would belong to the stream being replaced,
        // and the episode it names as current has not played at all.
        if autoAdvanceArmed, nextEpisode != nil, let leaving = currentVideo,
           !currentSourceIsNoticeClip, episodeSwitchTargetID == nil {
            PlayerProbe.event("progress", "FINISHED \(leaving.seasonEpisodeCode) on exit"
                + String(format: " at %.1f of %.1f — past the Up Next point", position, duration))
            PlayerProbe.count("progress.episode-finished")
            retiredEpisodeOnExit = true
            progressStore.markFinished(meta: meta, video: leaving)
        } else {
            saveProgress()
        }
        recordLinkVerdict()
        cacheTask?.cancel()
        cacheBandTask?.cancel()
        cacheBandTask = nil
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
        enginePause("player exiting")
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
        // NOTHING WAS SWITCHED, NOTHING TO RESTORE. An ordinary SDR exit never
        // touched the panel, so it must not pay a handshake or a cover — this
        // is what keeps the common exit instant.
        guard displayCriteriaApplied else { return }
        SessionDisplayMode.releaseForExit()
    }

    // THIS USED TO RELEASE NOTHING, EVER, AND THAT WAS THE BUG.
    //
    // The reasoning it carried was real: a revert is a full HDMI
    // renegotiation, and when one lands while the video surface is being torn
    // down some panels wedge grey until they are power-cycled. The response
    // was to stop reverting altogether and let the display hold the video's
    // mode for the rest of the foreground stint, on the theory that the SDR UI
    // would simply be tone-mapped into it.
    //
    // What that actually leaves behind is the whole app running at the FILM's
    // refresh rate. At 24Hz the menus, scrolling, focus movement and
    // animations are all quantised to 41ms — "the UI is sluggish after
    // watching something", fixed only by turning Match Frame Rate off, which
    // is not a fix. A player may change the display for playback; it may not
    // keep it.
    //
    // The overlap that caused the grey wedge is addressed where it actually
    // lives — in the SEQUENCING, which `exitDisplaySettleDelay` below restores:
    // opaque cover up, video surface detached by `prepareForExit`, THEN the
    // release, THEN a beat for the handshake, and only then the dismiss. That
    // ordering was built for exactly this and had been left switched off.
    //
    // If a grey wedge ever comes back on a particular panel, the escape is one
    // line: return 0 from `exitDisplaySettleDelay` and drop the
    // `SessionDisplayMode.releaseForExit()` call above.

    /// Seconds the exit must hold its black cover before tearing the player
    /// down, so the display-mode handshake finishes over a static screen
    /// instead of a disappearing video surface. Zero when no switch was made
    /// this session (the common case — exits stay instant).
    var exitDisplaySettleDelay: Double {
        // Only a session that actually moved the panel has a handshake to wait
        // out. `exitPlayer` adds its own 250ms before calling the release, so
        // the cover is up for roughly a second in total on a switched exit and
        // is not shown at all on any other.
        displayCriteriaApplied ? 0.8 : 0
    }

    func teardown() {
        // This teardown can arrive LATE — `PiPHandoff.finish()` runs it from
        // AVKit's `didStop`, at an arbitrary moment, possibly long after the
        // viewer started a different film. So every line below that touches
        // process-wide state is gated on still owning it: a retired session
        // resetting these deleted the LIVE session's cache file under its
        // reader, killed its scrub wheel and let the screensaver come up
        // mid-film. Per-session work (tasks, engines, progress) always runs.
        // Read the answer BEFORE handing ownership back, or the hand-back
        // would make every check below pass for free.
        let ownedSharedState = ownsSharedState
        if Self.sharedStateOwner === self { Self.sharedStateOwner = nil }
        if ownedSharedState {
            OrivioSyncManager.playbackActive = false   // resume periodic account sync
        }
        // The player is gone: any in-flight failover / watchdog / seek callback
        // must NOT restart playback from here (they all gate on isExiting).
        // Also swallows engine state callbacks arriving mid-teardown.
        isExiting = true
        // Stop the hybrid cache's download and reclaim its disk space — the
        // film being cached belongs to THIS playback.
        if ownedSharedState { MediaCacheServer.shared.endSession() }
        saveProgress()
        cacheTask?.cancel()
        cacheBandTask?.cancel()
        cacheBandTask = nil
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
        resyncClearTask?.cancel()
        loadWatchdogTask?.cancel()
        firstFrameWatchdogTask?.cancel()
        stallWatchdogTask?.cancel()
        // The auto-hide timer re-arms itself while playback is paused, so it
        // is a loop now rather than a one-shot and belongs on this list.
        hideControlsTask?.cancel()
        scrubTimeoutTask?.cancel()
        if ownedSharedState {
            UIApplication.shared.isIdleTimerDisabled = false
            // Release the Siri-remote trackpad stream. `configureWheelTracking()`
            // installs this handler on the SHARED GCController, which outlives the
            // player — left in place it keeps firing (and keeps owning the pad's
            // absolute-value reporting) for the rest of the app's life, once per
            // playback session.
            //
            // Only when this session still owns it: the handler is installed
            // once, from init and from GCControllerDidConnect, so nil'ing it
            // from a retired teardown left the PLAYING session's fine-tune
            // wheel (and its swipe-vs-tap disambiguation) dead for good.
            for controller in GCController.controllers() {
                controller.microGamepad?.dpad.valueChangedHandler = nil
            }
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
        stopAtmosPassthrough()
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
        // And only from the session that owns the route: a newer session is
        // playing through it, and handing its audio session back — or waking
        // whatever this one interrupted on top of it — is not this teardown's
        // call.
        if ownedSharedState {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // Stop offering this (now-dead) session's mode to the global
            // re-sync — but only when we still own the shared state, so a late
            // PiP teardown can't strip a live session's provider.
            DisplayResync.sessionTarget = nil
        }
        // Leak probes: 5s after teardown everything below should be freed.
        // Whichever line still prints ALIVE names the retention layer.
        #if DEBUG
        weak let probeVM: PlayerViewModel? = self
        weak let probeEngine: DVSampleEngine? = dvDirectEngine
        weak let probeVideoView: UIView? = dvDirectEngine?.videoView
        dvDirectEngine = nil
        NSLog("[OrivioLeak] teardown() ran")
        // Also onto the probe bus: NSLog only reaches a console-attached
        // device, and the leak is exactly what a live tail needs to show.
        PlayerProbe.event("leak", "teardown ran — title=\(meta.name) liveVMs=\(PlayerViewModel.liveInstances)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // presentedVC tells us whether the DISMISSED player cover is still
            // mounted in the window: a dead 4K layer tree the render server
            // keeps compositing would explain both the re-entry stutter and
            // the corrupted-strip glitch.
            let pvc = UIApplication.shared.ks_keyWindow?.rootViewController?.presentedViewController
            let line = "[OrivioLeak] +5s: vm=\(probeVM == nil ? "freed" : "ALIVE")"
                + " engine=\(probeEngine == nil ? "freed" : "ALIVE")"
                + " videoView=\(probeVideoView == nil ? "freed" : "ALIVE")"
                + " presentedVC=\(pvc.map { String(describing: type(of: $0)) } ?? "nil")"
                + " liveVMs=\(PlayerViewModel.liveInstances)"
            NSLog("%@", line)
            PlayerProbe.event("leak", line)
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

    /// "Show - S01E06 - Episode Title" for an episode, the title otherwise —
    /// the Info card's headline.
    var infoCardTitle: String {
        guard let video = currentVideo, video.season != nil else { return meta.name }
        var parts = [meta.name, video.seasonEpisodeCode.replacingOccurrences(of: ":", with: "")]
        if let title = video.title, !title.isEmpty { parts.append(title) }
        return parts.joined(separator: " - ")
    }

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
            var aheadAtLastGrowth: Double = 0
            var growthRate: Double = 0   // smoothed seconds-of-video per second
            while !Task.isCancelled {
                guard let self, let player = self.playerLayer?.player else { return }
                // Anything that sneaks playback back on (async seek callbacks,
                // engine loadState flips) gets re-paused: the hold must hold.
                if player.playbackState == .playing { self.playerLayer?.pause() }
                let ahead = max(player.playableTime - player.currentPlaybackTime, 0)
                let delta = ahead - lastAhead
                growthRate = growthRate * 0.7 + (delta / 0.3) * 0.3
                // CUMULATIVE growth, not per-tick: a source trickling 0.1s of
                // buffer per 0.3s tick never produced a single-tick delta over
                // 0.5, so `lastGrowthAt` sat frozen and the stall exits cut a
                // healthy slow start. Half a second of growth since the last
                // mark counts, however many ticks it took.
                if ahead - aheadAtLastGrowth > 0.5 {
                    lastGrowthAt = Date()
                    aheadAtLastGrowth = ahead
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
                // …and a source that stalls BELOW that floor is not worth the
                // full 20s cap either: if nothing has arrived for 5 straight
                // seconds, more waiting buys no more buffer — start with what
                // there is. (The floor kept slow-starting sources from being
                // released too early; a dead-stopped one held the viewer at
                // "Preparing video…" for the whole cap.)
                let stalled = Date().timeIntervalSince(lastGrowthAt) > 5
                    && Date().timeIntervalSince(startedAt) > 6
                let timedOut = Date().timeIntervalSince(startedAt) > self.cacheMaxWaitSeconds
                if reachedTarget || reachedEOF || outpacing || plateaued || stalled || timedOut { break }
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
            Self.colorTrail("previews: skipped — Scrub preview frames is off (Settings → Performance)")
            return
        }
        guard !PerformanceProfile.isLowPower else {
            NSLog("[OrivioPlayer] scrub previews skipped: low-power device")
            Self.colorTrail("previews: skipped — low-power device")
            return
        }
        guard !thumbnailsStarted, let url = currentURL else { return }
        guard url.pathExtension.lowercased() != "m3u8" else {
            NSLog("[OrivioPlayer] scrub previews skipped: HLS source")
            return
        }
        thumbnailsStarted = true
        thumbnailTask = Task { [weak self] in
            // Hybrid cache live: previews read the proxy's CACHE-ONLY lane —
            // every byte comes off the local disk, so there is no bandwidth
            // contention, no size cap, and no way for a preview seek to drag
            // the sequential download around. The pass follows the cache as
            // it fills, span by span.
            if url.host == "127.0.0.1", let thumbURL = MediaCacheServer.shared.thumbnailURL {
                await self?.runCacheDrivenThumbnails(thumbURL: thumbURL)
                return
            }
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
                let healthy = self.bufferAhead.wrappedValue >= self.previewBufferGate * 1.5
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
            let need = await MainActor.run { self?.previewBufferGate ?? 8 }
            var proceed: (@Sendable () -> Bool)?
            if gated, let health {
                proceed = { health.wrappedValue >= need }
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

    /// Cache-driven preview generation: instead of one whole-film pass over
    /// the network, follow the hybrid cache as it fills and thumbnail each
    /// newly covered span from the LOCAL disk via the proxy's cache-only lane.
    /// Works for any file size — the 8 GB network gate doesn't apply when the
    /// reads never leave the box — and with the sliding window the previews
    /// OUTLIVE the cache: a span's frames stay in memory after its bytes have
    /// been evicted, so the scrubber keeps its scenes for everything the
    /// window has ever passed over.
    private func runCacheDrivenThumbnails(thumbURL: URL) async {
        // Duration first — targets are spaced in seconds of runtime.
        while duration <= 0, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !Task.isCancelled, duration > 0 else { return }
        let runtime = duration
        // Infuse-grade density: the reads are local, so the budgets that
        // matter are memory and decode time, not bandwidth. One frame per 10s
        // (vs 30s over the network), memory-capped at 300 frames (~44 MB of
        // 256px BGRA) — a 45-minute episode gets full 10s coverage, a 3-hour
        // film degrades to ~36s and leans on the fine pass for the close-up.
        // Tiered. The A10X is `isMidPower`, so it was taking the full 300 —
        // ~44 MB of 256px BGRA held for the whole session, beside a 4K decode.
        // Target spacing is `scrubSecondsPerFrame` (15s), but the cap is the
        // pre-existing decode/memory budget — doubling it (240 on the A10X)
        // put twice the software-decode load beside playback and was felt as
        // general jank. The 15s density under the finger comes from the wide
        // dense pass during a drag; the whole-film coarse set doesn't need it.
        let cap = PerformanceProfile.isMidPower ? 120 : 300
        let spacing = max(runtime / Double(cap), ScrubThumbnailer.scrubSecondsPerFrame)
        let targetFrames = max(Int(runtime / spacing), 1)
        NSLog("[OrivioPlayer] scrub previews: cache-driven, %d frames over %.0fs as the cache fills", targetFrames, runtime)
        Self.colorTrail("previews: cache-driven — \(targetFrames) frames over \(Int(runtime))s, following the cache")
        // Seconds spans already thumbnailed. Eviction later removing their
        // BYTES doesn't matter — the frames are already in memory.
        var done: [(Double, Double)] = []
        var emptyPassCounts: [Double: Int] = [:]
        let health = bufferAhead
        let need = previewBufferGate
        let gate: @Sendable () -> Bool = { health.wrappedValue >= need }
        while !Task.isCancelled {
            let covered = MediaCacheServer.shared.coveredFractions
                .map { (max($0.start * runtime, 0), min($0.end * runtime, runtime)) }
            // Freshly covered spans big enough to be worth a pass. Requiring a
            // couple of frame-slots per pass batches the work; the tail of the
            // film (smaller than the threshold but final) still qualifies.
            let fresh = Self.subtractSpans(covered, minus: done)
                .filter { $0.1 - $0.0 >= spacing * 2 || $0.1 >= runtime - spacing }
            // STAND ASIDE WHEN THE CACHE IS LOSING. The preview pass opens a
            // second reader on the same file and software-decodes 4K
            // keyframes — its reads are served on the cache's own serial
            // queue, so on a high-bitrate remux whose download is barely
            // keeping ahead of playback it steals exactly the disk and CPU
            // that playback needs. `bufferAhead` can't see this: it measures
            // the ENGINE's buffer, which looks fine right up until the cache
            // runs out from under it. The cache's own lead is the honest
            // signal, so wait for real headroom before each pass.
            //
            // Measured in SECONDS of playback, not bytes. The flat 128 MB this
            // replaces was picked for the remux case and was nearly
            // unreachable at ordinary bitrates: on a 2 Mbps web-dl it is eight
            // minutes of lead, more than the pool even builds — the demand
            // side stops fetching at a 96 MB lookahead — so on most files the
            // gate never opened and the preview window simply never appeared.
            // A minute of road ahead is the same headroom the cache uses for
            // its own opening burst, and it means the same thing on every file.
            // The cache session is gone (failed open to the origin): the
            // cache-only lane this pass reads from has nothing to give and
            // never will. Stop, rather than polling a dead session every five
            // seconds for the rest of the film.
            guard MediaCacheServer.shared.hasLiveSession else {
                PlayerProbe.event("preview", "coarse pass STOPPED — the cache session is gone")
                return
            }
            // THROTTLED WHILE THE PICTURE IS MOVING, not suspended.
            //
            // This pass software-decodes 4K keyframes across the whole film in
            // the background. On the 3 GB first-gen 4K that is the same CPU the
            // DV pipeline is using to keep 4K Dolby Vision on screen, and the
            // cost is visible: frame repeats per vsync window went from 0 to 12
            // once this pass finally started producing frames, and the worst of
            // it lands just after a seek — a seek moves the cache window, this
            // sees freshly covered film and starts decoding exactly as playback
            // is trying to refill. Waiting for a pause costs only how soon the
            // set is ready; running through playback costs the film itself.
            // Standing it down entirely was the first attempt and it went too
            // far: `coarse=0` for whole sessions, so when the dense set had no
            // frame near the finger there was nothing at all to fall back on
            // and the window blinked out. The pass now RUNS while playing and
            // simply breathes longer between frames (see `breathSeconds`), so
            // coverage keeps building at a fraction of the contention.
            let leadSeconds = MediaCacheServer.shared.readerLeadSeconds
            if leadSeconds < Self.previewLeadGate {
                PlayerProbe.event("preview", String(format: "coarse pass WAITING — cache lead %.0fs of %.0fs",
                                                    leadSeconds, Self.previewLeadGate))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            if let span = fresh.first {
                let count = max(2, min(Int((span.1 - span.0) / spacing), 120))
                // Slow and steady on a box that is also decoding 4K DV.
                let breath: TimeInterval = (PerformanceProfile.isMidPower
                    || PerformanceProfile.isLowPower) && isPlaying && !isScrubbing
                    ? 0.6 : 0.08
                let pass = ScrubThumbnailer(
                    url: thumbURL, count: count,
                    // Local disk decode — quick, but still a software decode
                    // sharing cores with playback, so keep the health gate.
                    budgetSeconds: min(Double(count) * 1.2, 240),
                    range: span.0...span.1, breathSeconds: breath, shouldProceed: gate
                )
                thumbnailer = pass
                let thumbs = await pass.generate()
                guard !Task.isCancelled, thumbnailer === pass else { return }
                thumbnailer = nil
                if !thumbs.isEmpty {
                    PlayerProbe.event("preview", String(format: "coarse pass +%d frames over %.0f-%.0fs",
                                                        thumbs.count, span.0, span.1))
                    done.append(span)
                    // Dense slots snap BACKWARD to keyframes, so neighbours
                    // can resolve to the same frame — merge de-duplicated so
                    // memory buys coverage, not copies.
                    var buckets = Set<Int>()
                    // The de-dup buckets are spacing/2, so this merge could
                    // settle at roughly TWICE `cap` — the ceiling the comment
                    // above promises was never actually applied. Enforce it.
                    let merged = (scrubThumbnails + thumbs)
                        .sorted { $0.time < $1.time }
                        .filter { buckets.insert(Int(($0.time / max(spacing * 0.5, 1)).rounded())).inserted }
                    // Over budget: keep an even SAMPLE across the whole film.
                    // `prefix(cap)` threw away the newest (highest-time)
                    // frames — the back half of a long film lost its previews
                    // permanently, because the spans that produced them were
                    // already marked done and never revisited.
                    if merged.count > cap {
                        let step = Double(merged.count) / Double(cap)
                        scrubThumbnails = (0..<cap).map { merged[min(Int(Double($0) * step), merged.count - 1)] }
                    } else {
                        scrubThumbnails = merged
                    }
                    continue   // look for more freshly covered film right away
                }
                // Nothing at all usually means the demuxer couldn't seek yet
                // (MKV cues live at the file's tail, which may not be cached
                // in the early minutes). Leave the span un-done and retry on a
                // later lap — but not forever, in case this file just can't.
                let key = span.0.rounded()
                emptyPassCounts[key, default: 0] += 1
                if emptyPassCounts[key] ?? 0 >= 3 { done.append(span) }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                continue
            }
            // Everything ever covered has been thumbnailed — either the whole
            // film is done, or the window needs time to slide. Poll gently.
            let doneTotal = done.reduce(0.0) { $0 + ($1.1 - $1.0) }
            if doneTotal >= runtime * 0.98 {
                NSLog("[OrivioPlayer] scrub previews complete: %d frames (cache-driven)", scrubThumbnails.count)
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    /// How much road the cache must have ahead of the reader before the
    /// preview pass will take any disk time.
    ///
    /// Fifteen seconds, and measured on the device rather than reasoned about.
    /// The probe showed the lead cycling 0 → ~55s and being reset to zero by
    /// every seek: on a session where somebody is actually scrubbing — which
    /// is the only session where previews matter — a 60s gate opened once in
    /// two minutes and the coarse set stayed empty the whole time. Fifteen
    /// still means real headroom, and the per-frame `bufferAhead >= 8` gate
    /// inside the pass is what actually protects playback frame by frame.
    private static let previewLeadGate: Double = 15

    /// `spans` minus `minus`, all as (start, end) seconds. Pure bookkeeping
    /// for the cache-driven pass.
    private static func subtractSpans(
        _ spans: [(Double, Double)], minus: [(Double, Double)]
    ) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for span in spans {
            var pieces = [span]
            for cut in minus {
                var next: [(Double, Double)] = []
                for piece in pieces {
                    // No overlap → keep whole; else keep what pokes out.
                    if cut.1 <= piece.0 || cut.0 >= piece.1 {
                        next.append(piece)
                    } else {
                        if cut.0 > piece.0 { next.append((piece.0, cut.0)) }
                        if cut.1 < piece.1 { next.append((cut.1, piece.1)) }
                    }
                }
                pieces = next
            }
            result.append(contentsOf: pieces.filter { $0.1 - $0.0 > 1 })
        }
        return result.sorted { $0.0 < $1.0 }
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
    /// NOT @Published — same treatment as `scrubThumbnails` (see its note).
    private(set) var fineThumbnails: [ScrubThumbnail] = [] {
        didSet { clock.previewsRevision &+= 1 }
    }
    private var fineThumbnailer: ScrubThumbnailer?
    private var fineTask: Task<Void, Never>?
    /// Centre of the window `fineThumbnails` covers, so a small wheel movement
    /// doesn't restart the pass.
    private var fineCenter: Double?

    /// Debounce for the dense pass, so a moving finger doesn't restart it.
    private var fineDebounce: Task<Void, Never>?

    /// Ask for a dense pass around `target`, once the target STOPS MOVING.
    ///
    /// The pass itself cancels and replaces any pass before it, and the scrub
    /// paths that call this run at 60 Hz — a pan across the bar covers a
    /// 120-second window in about forty milliseconds. The live probe caught
    /// what that does: twenty passes started in 1.2 seconds, every one of them
    /// cancelled by the next, not one surviving long enough to decode a frame.
    /// The dense set was permanently empty for exactly the gesture it exists
    /// to serve.
    ///
    /// A dense close-up is for honing in, not for flying past. So: settle
    /// first, then fetch.
    /// Engine buffer the preview passes insist on before decoding a frame.
    ///
    /// These were flat numbers — 12, 8, 8 and 6 seconds — and every one of them
    /// is a KSPlayer number: there `playableTime` is the demuxer's whole
    /// read-ahead and runs to tens of seconds. The DV engine bounds its
    /// compressed queue at 120 access units, about five seconds at 24fps, so it
    /// CANNOT report eight however healthy it is, and all four gates were shut
    /// for the whole of every DV session. Scaled to what the engine in use can
    /// actually hold, they mean the same thing on both.
    var previewBufferGate: Double { usingDVDirect ? 3.5 : 8 }

    private func requestFineThumbnails(around target: Double) {
        fineDebounce?.cancel()
        fineDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.isScrubbing else { return }
            self.startFineThumbnailsIfNeeded(around: target)
        }
    }

    /// Start (or re-centre) the fine pass. Called when the wheel engages and as
    /// the target drifts out of the window already covered.
    private func startFineThumbnailsIfNeeded(around target: Double) {
        guard settings.scrubPreviewsEnabled, !PerformanceProfile.isLowPower,
              thumbnailsStarted, duration > 0 else { return }
        guard var url = currentURL, url.pathExtension.lowercased() != "m3u8" else { return }
        // Hybrid cache live: local reads make the dense pass cheap, so cover
        // a much wider stretch around the finger — scrubbing through cached
        // film should feel continuous, not sampled.
        let cached = url.host == "127.0.0.1" && MediaCacheServer.shared.hasLiveSession
        // 480 SECONDS OF DENSE FRAMES WAS TOO MUCH TO ASK OF THIS BOX. At one
        // frame every two seconds that is 240 software-decoded 4K keyframes,
        // uncapped — the coarse pass has capped itself at 120 all along — and
        // they are decoded WHILE a 4K DV stream is playing. The 3 GB first-gen
        // 4K (`isMidPower`, which the `isLowPower` guard above does not cover)
        // has nothing like that to spare.
        // FINE-TUNING WANTS DENSITY, NOT REACH. The wheel is for small
        // adjustments — a few seconds either side — and it was being served the
        // same window as a coarse drag: ±90s at one frame per two seconds is 90
        // slots, capped to 60, so the frames that survived sat about three
        // seconds apart. Nudging by a second showed the same picture three
        // nudges running. A narrow window at one frame per second puts a
        // distinct frame under every step of the wheel, for FEWER decodes than
        // the wide pass was asking for.
        let fineTuning = wheelEngaged
        let spacing = fineTuning
            ? ScrubThumbnailer.fineSecondsPerFrame
            : (cached ? ScrubThumbnailer.dragSecondsPerFrame
                      : ScrubThumbnailer.scrubSecondsPerFrame)
        let wide = PerformanceProfile.isMidPower ? 180.0 : 480.0
        let half = fineTuning
            ? Self.fineTuningHalfWindow
            : (cached ? wide : ScrubThumbnailer.fineWindowSeconds) / 2
        // Still inside the covered window (with a margin) — nothing to do.
        //
        // Unless the MODE changed. Engaging the wheel over a window a wide pass
        // already covered is exactly when the dense set is wanted, and judging
        // only by distance meant the wide pass's three-second spacing was kept
        // and the fine-tuning pass never ran at all.
        if let centre = fineCenter, fineCenterWasFineTuning == fineTuning,
           abs(centre - target) < half * 0.5 { return }
        // The cache-only lane: a fine pass can't reposition the download (an
        // uncovered slot fails fast and is simply skipped).
        if cached, let thumbURL = MediaCacheServer.shared.thumbnailURL {
            url = thumbURL
        }

        PlayerProbe.event("preview", String(format: "fine pass -> centre %.0f (+/-%.0fs, %@)",
                                            target, half, cached ? "from cache" : "over network"))
        fineCenter = target
        fineCenterWasFineTuning = fineTuning
        fineTask?.cancel()
        fineThumbnailer?.cancel()
        var lower = max(target - half, 0)
        var upper = min(target + half, max(duration - 1, 0))
        // CLAMP TO FILM THAT IS ACTUALLY ON DISK.
        //
        // The dense pass reads through the cache-only lane, which answers an
        // HTTP error for any byte range the cache does not already hold and
        // never triggers a download — that is the whole point of that lane, so
        // a preview can never steal the connection feeding the picture. But the
        // window was centred on the SCRUB TARGET and never intersected with
        // what is cached, so scrubbing anywhere the window had not reached
        // asked the disk for film the disk does not have and got nothing back.
        // `fine=0` for entire sessions, with the pass running perfectly.
        if cached, duration > 0 {
            let spans = MediaCacheServer.shared.coveredFractions
                .map { (max($0.start * duration, 0), min($0.end * duration, duration)) }
                .filter { $0.1 > $0.0 }
            guard let span = spans.first(where: { $0.0 <= target && target <= $0.1 }) else {
                // Nothing cached under the finger: the coarse set is the honest
                // answer here, and it already covers the whole film.
                fineCenter = nil
                return
            }
            lower = max(lower, span.0)
            upper = min(upper, span.1)
        }
        guard upper > lower else { fineCenter = nil; return }
        // Capped like the coarse pass. Without a ceiling the window's width was
        // the only thing bounding the decode, which is how a widened cached
        // window turned into an unbounded one.
        let cap = PerformanceProfile.isMidPower ? 60 : 120
        let count = min(max(4, Int((upper - lower) / spacing)), cap)
        let headers = currentEntry.stream.behaviorHints?.proxyHeaders?.requestHeaders

        fineTask = Task { [weak self] in
            let health = await MainActor.run { self?.bufferAhead }
            let need = await MainActor.run { (self?.previewBufferGate ?? 8) * 0.75 }
            var proceed: (@Sendable () -> Bool)?
            if let health { proceed = { health.wrappedValue >= need } }
            // SWEEP FOR THE FRAMES BETWEEN THE KEYFRAMES, off the local cache
            // only. A slot pass seeks, and a seek lands on a keyframe — five
            // or ten seconds apart on a remux — so fine-tuning showed the same
            // still through most of a turn of a wheel that moves 24 seconds per
            // revolution. The sweep decodes straight through the window
            // instead and keeps one frame a second. It reads every byte of
            // what it sweeps, which is why it is never asked for over the
            // network, and it stands itself down on hardware that can't hold
            // the pace (`sweepFloorFPS`), leaving the slot pass to fill the
            // window at the old density.
            let fine = ScrubThumbnailer(url: url, count: count,
                                        budgetSeconds: cached ? 60 : 30,
                                        headers: headers, range: lower...upper,
                                        denseSpacing: fineTuning && cached
                                            ? ScrubThumbnailer.fineSweepSeconds : nil,
                                        denseCenter: target,
                                        shouldProceed: proceed)
            await MainActor.run { self?.fineThumbnailer = fine }
            let thumbs = await fine.generate { partial in
                Task { @MainActor [weak self] in
                    guard let self, self.fineThumbnailer === fine else { return }
                    self.mergeFine(partial)
                }
            }
            await MainActor.run {
                guard let self, self.fineThumbnailer === fine else { return }
                self.fineThumbnailer = nil
                PlayerProbe.event("preview", "fine pass done — \(thumbs.count) frames"
                    + " (\(self.fineThumbnails.count) held)")
                self.mergeFine(thumbs)
            }
        }
    }

    /// Fold a pass's frames into the dense set instead of replacing it.
    ///
    /// Every pass used to ASSIGN, so re-centring threw away everything the
    /// previous window had — including the part that overlapped the new one.
    /// Scrubbing re-centres constantly, so the set was never more than the last
    /// pass's handful of frames, and the probe showed exactly that: "window
    /// SHOWN (fine=1)" then "window GONE — no frame near this position"
    /// moments later, with the pass working perfectly both times. Frames are
    /// cheap to keep and expensive to decode; the only reason to drop one is
    /// leaving the scrub entirely, which `clearFineThumbnails` still does.
    ///
    /// Bounded, and it discards the frames FURTHEST from the current interest
    /// first, so a long scrub keeps what is under the finger.
    private func mergeFine(_ incoming: [ScrubThumbnail]) {
        guard !incoming.isEmpty else { return }
        var byBucket: [Int: ScrubThumbnail] = [:]
        for thumb in fineThumbnails + incoming {
            // Keyframe stamps repeat, so key on the frame's own time.
            byBucket[Int(thumb.time.rounded())] = thumb
        }
        var merged = byBucket.values.sorted { $0.time < $1.time }
        if merged.count > Self.fineThumbnailLimit {
            let centre = fineCenter ?? clock.scrubTarget ?? position
            merged = merged
                .sorted { abs($0.time - centre) < abs($1.time - centre) }
                .prefix(Self.fineThumbnailLimit)
                .sorted { $0.time < $1.time }
        }
        fineThumbnails = merged
    }

    /// Ceiling on the dense set. A 4K frame scaled to preview size is small,
    /// but this is a 3 GB box and they are held for the whole scrub.
    private static var fineThumbnailLimit: Int {
        PerformanceProfile.isMidPower ? 80 : 240
    }

    /// Half-width of the fine-tuning window: the wheel is for small
    /// adjustments, so a narrow window puts a distinct frame under every
    /// couple of steps for a handful of decodes.
    ///
    /// Twenty seconds, not thirty, since the sweep arrived: the sweep DECODES
    /// the window rather than sampling it, so its width is what it costs, and
    /// ±20s is still most of a turn of the wheel (24s per revolution) either
    /// way. Everything past it is the coarse set's job.
    private static let fineTuningHalfWindow: Double = 20

    /// How far a frame from the dense set may be from the asked-for time and
    /// still be the right picture: the spacing the set was BUILT at (2s when
    /// fine-tuning, 15s when scrubbing) — or, when keyframes are further apart
    /// than that (a 4K remux's GOP is 5-10s, and every slot snaps BACKWARD to
    /// a keyframe), the spacing the set actually achieved. A flat 2s here
    /// rejected every frame of a 15s-spaced scrub set and fell through to the
    /// coarse set, which is the same density or worse.
    private var fineTolerance: Double {
        let built = fineCenterWasFineTuning ? ScrubThumbnailer.fineSecondsPerFrame
                                            : ScrubThumbnailer.scrubSecondsPerFrame
        guard fineThumbnails.count > 1,
              let first = fineThumbnails.first, let last = fineThumbnails.last else { return built }
        let achieved = (last.time - first.time) / Double(fineThumbnails.count - 1)
        return max(built, achieved * 0.75)
    }

    /// Whether the set currently centred was built at fine-tuning density.
    private var fineCenterWasFineTuning = false

    /// Drop the dense set when fine-tuning ends — it is ~45 frames held only
    /// for the window you were working in.
    private func clearFineThumbnails() {
        fineDebounce?.cancel(); fineDebounce = nil
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
        return max(ScrubThumbnailer.scrubSecondsPerFrame * 3, spacing * 1.5)
    }

    /// Nearest entry in a TIME-SORTED thumbnail array, by binary search.
    ///
    /// Both arrays are built in time order, and this is called from a view body
    /// at the scrub publish rate (~30Hz) over up to 240 coarse frames plus the
    /// fine window — thousands of comparisons per second on the main actor while
    /// the decoder is running. The order was always there to exploit.
    private static func nearest(
        in thumbs: [ScrubThumbnail], to time: Double
    ) -> (thumb: ScrubThumbnail, distance: Double)? {
        guard !thumbs.isEmpty else { return nil }
        var low = 0, high = thumbs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if thumbs[mid].time < time { low = mid + 1 } else { high = mid }
        }
        var best = thumbs[low]
        var bestDistance = abs(best.time - time)
        if low > 0 {
            let previous = thumbs[low - 1]
            let distance = abs(previous.time - time)
            if distance < bestDistance { best = previous; bestDistance = distance }
        }
        return (best, bestDistance)
    }

    func thumbnail(at time: Double) -> UIImage? {
        // Prefer a fine frame when one is genuinely near — within a single
        // fine step. Past that the coarse set is the better answer than a
        // stale close-up from the edge of the window.
        if let hit = Self.nearest(in: fineThumbnails, to: time),
           hit.distance <= fineTolerance {
            return hit.thumb.image
        }
        guard let coarse = Self.nearest(in: scrubThumbnails, to: time) else { return nil }
        let best: UIImage? = coarse.thumb.image
        let bestDistance = coarse.distance
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
    @Published private(set) var enrichedMeta: MetaItem? {
        didSet { refreshNextEpisodeAvailability() }
    }
    /// Best available metadata: the enriched fetch when it lands, else
    /// whatever the player was launched with.
    var displayMeta: MetaItem { enrichedMeta ?? meta }

    /// US certificate (PG-13, TV-MA) for the pull-down's header.
    ///
    /// Held HERE, resolved when the player opens, rather than fetched by the
    /// info panel when it mounts. It is a TMDB round-trip, and asking for it as
    /// the sheet appears meant the badge landed a beat into the slide — the
    /// rating visibly popping in as the panel came down. Even a cache hit is
    /// async, so warming the cache alone was not enough: the value has to
    /// already be on the model before the panel is built.
    @Published private(set) var contentRating: String?

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
        guard acceptsTransportInput else { return }
        switch overlay {
        case .none, .pauseInfo, .controls, .audio, .subtitles: break
        default: return
        }
        if isScrubbing { cancelScrub() }
        hideControlsTask?.cancel()
        infoTab = 0
        sheetMoving = true
        withAnimation(Self.sheetMotion) { overlay = .info }
        settleSheetMotion()
    }

    /// The info sheet's slide, in and out.
    static let sheetMotion: Animation = .easeOut(duration: 0.4)
    /// True across the sheet's open or close, so the player's overlay
    /// animation picks the slide for that change (the `.animation(value:)`
    /// modifier on the player stack decides the curve, not `withAnimation`).
    @Published private(set) var sheetMoving = false
    private var sheetMotionTask: Task<Void, Never>?

    private func settleSheetMotion() {
        sheetMotionTask?.cancel()
        sheetMotionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.sheetMoving = false
        }
    }

    /// The sheet is sliding up; it is removed once the slide has played.
    @Published private(set) var sheetClosing = false

    func dismissInfoPanel() {
        guard overlay == .info, !sheetClosing else { return }
        infoPickerVisible = false
        withAnimation(Self.sheetMotion) { sheetClosing = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.sheetClosing else { return }
            var t = Transaction()
            t.disablesAnimations = true
            // Only if the sheet is still what owns the screen. Four hundred
            // milliseconds is long enough for playback to fail, for a title to
            // end, or for the viewer to raise the exit prompt — and this used
            // to overwrite whichever of those had appeared, dropping the viewer
            // back to bare video with the thing they needed to answer gone.
            guard self.overlay == .info else {
                self.sheetClosing = false
                return
            }
            withTransaction(t) {
                // Paused behind the sheet? Land on the transport, not on bare
                // video: `togglePlayPause` could not raise the bar because the
                // sheet owned the overlay, so closing it would otherwise reveal
                // a frozen frame with nothing on screen saying why.
                self.overlay = self.isPlaying ? .none : .controls
                self.sheetClosing = false
            }
        }
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
                                   ? "HEVC · Dolby Vision P\(profile)" : engine.videoCodecName))
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
                video.append(.init(label: "DV Output", value: "HDR10 base layer"))
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
                        ? "HDR10 base layer (passthrough didn't engage)"
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
        PlayerProbe.event("state", String(format: "ks → %@ at %.1f (playing=%@ started=%@)",
                                          String(describing: state), position,
                                          isPlaying.probe, hasStartedPlayback.probe))
        switch state {
        case .initialized, .preparing:
            isBuffering = true
        case .readyToPlay:
            PictureInPictureController.trail("load: readyToPlay (\(engineLabelForPiP))")
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
            // A live or unknown-length source can report `.infinity` (or NaN)
            // here. Every consumer below already treats 0 as "unknown", while a
            // non-finite value poisons the arithmetic it feeds — `duration - 1`
            // into the seek clamp, `position / duration` into the bar — so
            // normalise it once, at the only place it enters the model.
            let reportedDuration = layer.player.duration
            duration = reportedDuration.isFinite && reportedDuration > 0 ? reportedDuration : 0
            clock.duration = duration
            // A twenty-second "request this from the same IP" clip opens and
            // plays like any other file; its LENGTH is the only tell, and this
            // is where it first becomes known.
            noteDurationForNoticeCheck(duration)
            // Lets the cache size its opening burst in seconds of playback
            // rather than a flat byte count.
            MediaCacheServer.shared.noteDuration(duration)
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
            applyNativeCaptionStyle()
            maybeStartNativeDV()
            // HDR10+ remux starter retired (direct engine passes SEIs through)
            if playbackSpeed != 1 {
                layer.player.playbackRate = playbackSpeed
            }
            let willPrecache = !hasStartedPlayback
            loadTracks()
            startThumbnailsIfNeeded()

            // No explicit resume mid-session means KSPlayerLayer rebuilt the
            // player on its own (first→second engine retry after a mid-film
            // error) — `load()` never ran, so `position` is still the real
            // playhead. Left at 0 the new engine restarted the film from the
            // original `startPlayTime` and then persisted THAT as progress.
            if hasStartedPlayback, pendingResume == nil, position > 30 {
                pendingResume = position
                sessionResumeFloor = max(sessionResumeFloor, position)
            }
            // The floor rides along: a user seek issued in the brief
            // pre-ready gap of a mid-session reload clears `pendingResume`
            // (see seek(to:)) and its own engine seek may be dropped by the
            // still-opening layer — the floor is where that seek aimed.
            let resume = max(pendingResume ?? 0, sessionResumeFloor)
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
                    // THE VIEWER LEFT WHILE THIS WAS OPENING. Asked of the
                    // system, not of `didBackground`/`didResignActive`: those
                    // are latches that can outlive their transition (the audio
                    // interruption observer sets one with no become-active to
                    // clear it), and a stale one read here would open the NEXT
                    // film paused. Nothing else stops this session either —
                    // both lifecycle handlers had no stream to pause when they
                    // ran, KSPlayerLayer's own `enterBackground` bails on
                    // `guard state.isPlaying`, and `UIBackgroundModes: audio`
                    // keeps the process alive once sound is rendering — so
                    // autoplaying here ran the film to nobody behind the app
                    // switcher or the Home screen and handed it back playing.
                    // Open where a background press would have left it: at the
                    // resume point, stopped.
                    // CORROBORATED, not a bare snapshot. `applicationState`
                    // can read non-active on a perfectly attended open (the
                    // scene still settling after launch, a transient system
                    // overlay) and one poisoned read here opened the film
                    // parked on the pause card with nothing to rescue it —
                    // "the first link I open doesn't play until I press
                    // play". A viewer who really left produced a lifecycle
                    // event during the load, and those LATCH (`didBackground`
                    // / `didResignActive` are recorded above their gates and
                    // cleared again when the viewer returns) — so unattended
                    // means the state reads away AND a leave was recorded.
                    let openedUnattended = UIApplication.shared.applicationState != .active
                        && (didBackground || didResignActive)
                    if meaningfulResume {
                        // Remember the target for the whole session BEFORE the
                        // seek: `position` is still ~0 until it lands, so a
                        // failover in that window used to restart the next
                        // source from the beginning.
                        sessionResumeFloor = max(sessionResumeFloor, resume)
                        playerLayer?.seek(time: resume, autoPlay: !openedUnattended) { [weak self] finished in
                            guard let self else { return }
                            // Cleared either way: leaving it set would make a
                            // later `.readyToPlay` (engine failover) yank the
                            // viewer back here after they'd scrubbed elsewhere.
                            self.pendingResume = nil
                            // Engine refused the seek (not seekable) — don't
                            // leave the session parked on a paused frame. Not
                            // when the open was unattended: there the parked
                            // frame is the point.
                            if !finished, !openedUnattended { self.playerLayer?.play() }
                        }
                    } else {
                        pendingResume = nil
                        if !openedUnattended { playerLayer?.play() }
                    }
                    loadPhase = nil
                    hasStartedPlayback = true
                    // AFTER the seek, never before: `KSMEPlayer.seek` sets
                    // playbackState to `.seeking` and nothing restores it, so a
                    // pause issued first would strand it there. Pausing on top
                    // lands it in `.paused`, clears KSPlayerLayer's own
                    // `isAutoPlay` — which the vendor's `readyToPlay` checks the
                    // instant this delegate returns and would otherwise
                    // self-start on — and makes the stop intentional, so the
                    // `.paused` branch below does not rescue it as a dropped
                    // autoplay.
                    if openedUnattended {
                        enginePause("stream opened while the app was away")
                        markPaused()
                        if overlay == .none { overlay = .pauseInfo }
                    }
                } else {
                    if meaningfulResume {
                        // Floor first, clear on COMPLETION — cleared at issue
                        // time, a failover during the precache hold computed
                        // resumeAt = 0 and restarted the film, and an early
                        // exit-save stomped Continue Watching with ~0.
                        sessionResumeFloor = max(sessionResumeFloor, resume)
                        playerLayer?.seek(time: resume, autoPlay: false) { [weak self] _ in
                            self?.pendingResume = nil
                        }
                    } else {
                        pendingResume = nil
                    }
                    beginPrecache()
                }
            } else {
                // Engine failover / source switch / episode switch mid-session.
                // With a meaningful resume position, seek there and autoplay.
                // Otherwise (a fresh, unwatched episode starts at 0) start
                // playing outright — play(episode:) paused the layer before the
                // switch, so without this an unwatched episode set up its stream
                // but never left pause, spinning on the loading state forever.
                // `meaningfulResume` is the determination made above: it is
                // already false when `startPlayTime` opened the container AT the
                // resume point. This branch used to ignore that and seek anyway
                // on the raw `resume`, so every source switch and every failover
                // with a saved position opened at the right byte offset and then
                // immediately flushed and re-sought to the same place — paying a
                // range request plus KSPlayer's own seek gate for nothing.
                if meaningfulResume, duration == 0 || resume < duration - 30 {
                    // (The playlist-offset translation that used to wrap this
                    // target went with the remux tier: a KSPlayer session's
                    // timeline IS the source timeline.)
                    // `pendingResume` stays set until the seek LANDS. Cleared
                    // at issue time (as this used to), `position` reads 0 for
                    // the seconds the seek is in flight and a periodic save in
                    // that window stomped Continue Watching back to the top of
                    // the film — the first-play path has always guarded this;
                    // the switch/failover path had not.
                    layer.seek(time: resume, autoPlay: true) { [weak self] _ in
                        self?.pendingResume = nil
                    }
                } else {
                    layer.play()
                    pendingResume = nil
                }
                if overlay == .none { showControls() }
            }
        case .buffering:
            PlayerProbe.event("engine", "buffering (pauseIntent=\(pauseIntent.probe))")
            if pictureInPicture.isActive { PictureInPictureController.trail("engine state: buffering (PiP active)") }
            // NOT unconditionally true: the reader buffers while paused too.
            isPlaying = !pauseIntent
            isBuffering = true
            // `pausedAt` drives the stale-socket reconnect on resume, so a
            // buffer event must not erase how long we have actually been sat
            // paused — only a real resume does.
            if !pauseIntent { pausedAt = nil }
        case .bufferFinished:
            PlayerProbe.event("engine", "bufferFinished (pauseIntent=\(pauseIntent.probe))")
            if pictureInPicture.isActive { PictureInPictureController.trail("engine state: bufferFinished (PiP active)") }
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
            // Only worth a line when nothing ASKED for it. A pause that
            // follows a `transport PAUSE (...)` is the system working; one
            // that doesn't is the engine stopping on its own, which is the
            // thing worth spotting in a scroll of events.
            PlayerProbe.event("engine", pauseIntent
                ? "paused (as asked)"
                : "PAUSED WITH NOBODY ASKING — the engine stopped on its own")
            // AND RECOVER FROM IT. An engine that stops with no pause intent
            // has dropped playback on its own — a refused seek, a decoder
            // hiccup, a reader that came back empty. Until now only a seek
            // armed the rescue, so a stall that happened OUTSIDE a seek had
            // nothing watching it at all: the picture just stopped, and the
            // viewer had to press play to find out it was not going to
            // recover. Seen on the device as exactly this line with no
            // WATCHDOG line after it.
            //
            // The watchdog is already the right instrument — it waits for the
            // engine to be settled and stopped before touching it, and stands
            // down for a real pause, a scrub, a source switch or a finished
            // title. Point it at this case too.
            if !pauseIntent, hasStartedPlayback, !playedToEndHandled,
               !isScrubbing, !isSwitchingSource, !isExiting {
                armSeekPlayWatchdog()
            }
            // Deduped: later delegate re-fires of .paused are expected, and
            // each @Published assignment re-renders every VM observer.
            if isPlaying { isPlaying = false }
            if isBuffering { isBuffering = false }
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
            PlayerProbe.event("engine", "ERROR")
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
        // The engine may have swapped its display layer under us since the
        // last tick — see refreshPictureInPictureSource.
        refreshPictureInPictureSource()
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
        if subtitleModel.selectedSubtitleInfo != nil || !subtitleModel.parts.isEmpty,
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
            // RELOAD, don't seek. By the time `finish(error:)` reaches us the
            // FFmpeg item is permanently `.failed` (its state machine has no
            // seek branch for that state) and the layer's tick timer is
            // stopped — a seek on it is a silent no-op with no further
            // callback, so the session froze on the last frame with nothing
            // to fail over. Reopening the same source at the safe position is
            // what the audio-route reload already does.
            pendingResume = safe > 10 ? safe : nil
            // The floor still holds the REJECTED forward target — left there,
            // every save (and the next failover) dragged the viewer back to
            // the position the toast just said couldn't be reached.
            sessionResumeFloor = safe
            if overlay == .pauseInfo { overlay = .none }   // the reload autoplays
            load(entry: currentEntry)
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

