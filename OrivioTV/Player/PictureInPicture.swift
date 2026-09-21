import AVKit
import KSPlayer
import ObjectiveC
import OSLog
import UIKit

/// Picture in Picture for the player.
///
/// On tvOS, AVKit will only drive PiP from an `AVPlayerLayer`. The
/// sample-buffer content source (`AVSampleBufferDisplayLayer` plus a playback
/// delegate) exists in the tvOS SDK, but the platform adapter behind
/// `AVPictureInPictureController` refuses it: its `isContentSourceSupported`
/// accepts player-layer, video-call and generic-view sources and masks out the
/// sample-buffer kind, so the controller's status never leaves "prohibited",
/// `isPictureInPicturePossible` never turns true, and `startPictureInPicture`
/// logs "failed; status = 0". Verified on tvOS 26.5 and 26.6 both by
/// disassembling AVKit and by probing a live session on an Apple TV 4K
/// (`-pipProbe`): the same session arms within seconds on the native engine
/// and never arms on FFmpeg. So of this app's engines:
///
/// * **KSAVPlayer** (native, mp4/HLS and the DV remux tier) — `AVPlayerLayer`.
///   The only one that can.
/// * **KSMEPlayer** (FFmpeg) — draws into an `AVSampleBufferDisplayLayer`.
///   Blocked by the platform, not by anything here.
/// * **DVSampleEngine** — its own `AVSampleBufferDisplayLayer`. Same.
/// * **VLC** — its own drawable, no CALayer AVKit could adopt anyway.
///
/// Availability is still decided per SESSION rather than assumed: the control
/// is hidden unless the engine that actually loaded produced a player layer
/// and AVKit reports PiP possible for it. On a title the native engine could
/// play but that is running elsewhere (mp4/HLS on FFmpeg or VLC), the options
/// menu offers the row anyway and one press switches engines and starts PiP
/// once armed — see `PlayerViewModel.enterPictureInPictureViaNativeEngine`.
/// On mkv and the other FFmpeg-only containers there is no row at all.
@MainActor
final class PictureInPictureController: NSObject, ObservableObject {
    /// Can PiP start right now? False until the attached layer has content,
    /// which is why this is observed rather than asked once.
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    /// PiP is taking the video. The host must get the full-screen player out
    /// of the way — the video has moved to the system's window, and what's
    /// left behind is a black screen with controls floating on it.
    var onWillStart: (() -> Void)?
    /// PiP ended without a restore request (the viewer closed the small
    /// window), so the session should be torn down.
    var onDidStop: (() -> Void)?
    /// The viewer asked to go back to full screen. Re-present, then call the
    /// completion — AVKit holds the PiP window up until it is called.
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?

    /// One "why is there no PiP" line per session, not one per clock tick.
    private var loggedUnavailable = false

    /// Diagnostics ring buffer, persisted so it can be read back from the app
    /// container after the fact — a console session cannot be attached to a
    /// player the viewer drives themselves. Read with the `dev.pipTrail` key.
    nonisolated private static let trailKey = "dev.pipTrail"
    /// Appends go to an in-memory ring and are flushed to UserDefaults on a
    /// utility queue at most once a second. The first version rewrote the
    /// whole 800-line array synchronously on every call, on whichever thread
    /// called — the player's clock tick included — which showed up as a
    /// periodic hitch in full-screen playback whenever the probe was on.
    nonisolated static func trail(_ line: String) {
        // Mirrored into the live probe for the reason dvTrail is: the PiP
        // trail is written from lifecycle callbacks that fire exactly when
        // the app is going away, and reading it afterwards (pulling the
        // container) BACKGROUNDS the app, which fires more of them.
        PlayerProbe.event("pip", line)
        NSLog("[OrivioPiP] %@", line)
        #if DEBUG
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)"
        trailQueue.async {
            trailBuffer.append(stamped)
            if trailBuffer.count > 800 { trailBuffer.removeFirst(trailBuffer.count - 800) }
            guard !trailFlushScheduled else { return }
            trailFlushScheduled = true
            trailQueue.asyncAfter(deadline: .now() + 1) {
                trailFlushScheduled = false
                UserDefaults.standard.set(trailBuffer, forKey: trailKey)
            }
        }
        #else
        // DEBUG only, like `PlayerProbe.event` above: the trail is read by
        // pulling the app container off a development box, so on a release
        // install it is pure cost — and the cost is not small. 800 lines is
        // ~97 KB, measured the biggest single key in the whole domain on a
        // real Apple TV, against the ~1 MB where CFPreferences answers a write
        // with abort() (see AddonManager's note). Clear what an earlier build
        // left behind, once per process, on the queue the writes used to use.
        trailQueue.async {
            guard !clearedStaleTrail else { return }
            clearedStaleTrail = true
            UserDefaults.standard.removeObject(forKey: trailKey)
        }
        #endif
    }
    nonisolated private static let trailQueue = DispatchQueue(label: "orivio.pip.trail", qos: .utility)
    #if DEBUG
    nonisolated(unsafe) private static var trailBuffer: [String] =
        UserDefaults.standard.stringArray(forKey: "dev.pipTrail") ?? []
    nonisolated(unsafe) private static var trailFlushScheduled = false
    #else
    nonisolated(unsafe) private static var clearedStaleTrail = false
    #endif
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var attachedLayer: AVPlayerLayer?

    /// Generic-view path (FFmpeg, VLC, the DV engine): the view AVKit hosts,
    /// the private content view controller it lives in while PiP is up, and
    /// the bridge that answers for playback state. See PictureInPictureBridge.
    private weak var attachedGenericView: UIView?
    private var contentViewController: UIViewController?
    private(set) var bridge: PiPPlaybackBridge?
    /// Where the video view came from, so `stop`/restore can put it back
    /// before the player screen rebuilds its container.
    private weak var genericViewHome: UIView?
    /// The view actually parented in the content view controller right now.
    /// Deliberately NOT the same field as `attachedGenericView`, which stays
    /// the view the ContentSource was BUILT for: a re-host under a live window
    /// swaps this one, and the identity guard in `attach(genericView:)` must
    /// still see a mismatch once the session ends and rebuild the source. Left
    /// pointing at the retired view, AVKit would be measuring a `sourceView`
    /// that is in no window, and PiP could never start again this session.
    private weak var hostedGenericView: UIView?

    /// Point at whatever the engine renders into.
    ///
    /// Idempotent on purpose: `PlayerVideoView.updateUIView` and the clock
    /// ticks both call this, so rebuilding the controller each time would
    /// churn AVKit state (and drop an active PiP session) many times a second.
    func attach(_ layer: AVPlayerLayer?) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer else {
            if !loggedUnavailable {
                loggedUnavailable = true
                Self.trail("unavailable — supported=\(AVPictureInPictureController.isPictureInPictureSupported()) layer=\(layer == nil ? "nil" : "yes")")
            }
            // A non-native engine, or a device/simulator without PiP. Don't
            // tear down an ACTIVE session: during the handoff the render view
            // is going away by design, and resetting here would kill the
            // window just opened.
            if !isActive { reset() }
            return
        }
        guard layer !== attachedLayer else { return }
        // Same rule as the nil-source path above: a source that CHANGES while
        // PiP is up (an engine failover under a running window) must not
        // deallocate the live controller — that takes the window down with no
        // `didStop` callback, so `isActive` stays true, the parked view model
        // is never released and the player can never be re-presented. The
        // next tick after PiP ends attaches the new source.
        guard !isActive else { return }
        Self.trail("attach AVPlayerLayer \(Unmanaged.passUnretained(layer).toOpaque())")
        reset()
        attachedLayer = layer
        let pip: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        controller = pip
        possibleObservation = pip?.observe(\.isPictureInPicturePossible,
                                           options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.isPossible != possible else { return }
                Self.trail("isPictureInPicturePossible=\(possible)")
                self.isPossible = possible
                if possible { self.consumePendingStart() }
            }
        }
    }

    /// Point at a render view no `AVPlayerLayer` backs. Same idempotence
    /// contract as `attach(_:)`; the bridge is created once per view.
    /// The KSOptions host hooks are process-wide and identical for every
    /// session, but this attach runs from the 10 Hz tick — installing a
    /// fresh escaping closure per tick was a small, permanent main-actor
    /// allocation cost for the whole film. Install once.
    private static let hostHooksInstalled: Void = {
        KSOptions.hostPictureInPictureActive = { PiPHandoff.shared.isActive }
        if PlayerDevFlags.pipProbe {
            KSOptions.hostTrail = { PictureInPictureController.trail($0) }
        }
    }()

    func attach(genericView view: UIView?, bridge makeBridge: () -> PiPPlaybackBridge) {
        _ = Self.hostHooksInstalled
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              GenericPictureInPicture.isAvailable, let view else {
            if !loggedUnavailable {
                loggedUnavailable = true
                Self.trail("generic unavailable — supported=\(AVPictureInPictureController.isPictureInPictureSupported()) private=\(GenericPictureInPicture.isAvailable) view=\(view == nil ? "nil" : "yes")")
            }
            if !isActive { reset() }
            return
        }
        guard view !== attachedGenericView else { return }
        // The controller and its ContentSource must outlive a source change
        // under a live window (see attach(_:)) — but the view the window is
        // SHOWING still has to follow the engine, or it goes on drawing the
        // retired one.
        guard !isActive else { rehostGenericView(view); return }
        Self.trail("attach generic \(type(of: view)) \(Unmanaged.passUnretained(view).toOpaque())")
        reset()
        // Recorded BEFORE the fallible steps: a failed attach is otherwise
        // retried on every clock tick for the whole film — an allocation, a
        // bridge and a synchronous NSLog several times a second.
        attachedGenericView = view
        guard let contentVC = GenericPictureInPicture.makeContentViewController() else {
            Self.trail("generic: no content view controller class")
            return
        }
        let bridge = makeBridge()
        guard let source = GenericPictureInPicture.makeContentSource(
            sourceView: view, contentViewController: contentVC, playerController: bridge) else {
            Self.trail("generic: content source init returned nil")
            return
        }
        Self.trail("generic: content source \(type(of: source)) built, source=\(String(describing: source.value(forKey: "source")).prefix(80))")
        attachedGenericView = view
        contentViewController = contentVC
        self.bridge = bridge
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible,
                                          options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.isPossible != possible else { return }
                Self.trail("isPictureInPicturePossible=\(possible) (generic)")
                self.isPossible = possible
                if possible { self.consumePendingStart() }
            }
        }
    }

    /// The system window is about to take the picture: move the render view
    /// into the hosted content view controller. Its old superview is the
    /// player screen's container, which is being dismissed anyway.
    private func routeGenericViewIntoPiP() {
        guard let view = attachedGenericView, let contentVC = contentViewController else { return }
        genericViewHome = view.superview
        // `view` is an implicitly-unwrapped optional; binding instead of
        // force-unwrapping avoids a trap if the content VC's view never loads.
        guard let host = contentVC.view else { return }
        host.backgroundColor = .black
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        hostedGenericView = view
        Self.trail("generic: routed \(type(of: view)) into content VC, host bounds=\(Int(host.bounds.width))x\(Int(host.bounds.height)) inWindow=\(host.window != nil)")
    }

    /// Swap the view the live window is hosting for the one the engine renders
    /// into NOW, leaving the controller and its ContentSource alone.
    ///
    /// A load that builds a new render view under a running window retires the
    /// engine that was drawing into the one parented here: the same-URL reopen
    /// (audio-route change, seek-fault recovery) drops the `KSPlayerLayer` and
    /// builds a fresh one, and `startDVFirst` / `loadViaVLC` retire it for an
    /// engine with its own view. Nothing else re-parents — `PlayerVideoView`
    /// is unmounted for the whole handoff, and both `attach` overloads refuse
    /// to re-point while `isActive` — so the window sat on the retired
    /// stream's last frame (or black) while the new one's audio played, with
    /// no way out but restoring to full screen. Same framing as
    /// `routeGenericViewIntoPiP()`; the controller is untouched on purpose,
    /// because rebuilding it mid-session takes the window down with no
    /// `didStop` and strands `isActive` (see attach(_:)).
    private func rehostGenericView(_ view: UIView) {
        guard let hosted = hostedGenericView, hosted !== view,
              let host = contentViewController?.view,
              hosted.superview === host else { return }
        hosted.removeFromSuperview()
        hostedGenericView = view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        Self.trail("generic: re-hosted \(type(of: view)) into the live window")
    }

    /// PiP is over: hand the view back to whatever container is live (the
    /// re-presented player screen re-parents it itself on its next update).
    private func routeGenericViewHome() {
        // The HOSTED view, not the attached one — after a re-host they are
        // different, and it is the one in the window that has to come home.
        guard let view = hostedGenericView, view.superview === contentViewController?.view else { return }
        hostedGenericView = nil
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        Self.trail("generic: view returned from content VC")
    }

    func detach() { reset() }

    /// Start PiP the moment AVKit arms it, if that happens within a minute.
    /// Used by the options menu's switch-to-Native path: the switch tears the
    /// engine down and rebuilds it, so the request has to outlive `reset()` —
    /// which is why it is a deadline here rather than state on the layer.
    private var pendingStartDeadline: Date?
    func startWhenPossible() {
        pendingStartDeadline = Date().addingTimeInterval(60)
        if isPossible { consumePendingStart() }
    }

    /// Called on every clock tick as well as when `isPossible` flips, so a
    /// request made while the app was still activating (AVKit refuses to
    /// start unless the scene is foreground-active) is retried rather than
    /// lost.
    func consumePendingStart() {
        guard let deadline = pendingStartDeadline else { return }
        guard Date() < deadline else { pendingStartDeadline = nil; return }
        guard isPossible, !isActive,
              UIApplication.shared.applicationState == .active else { return }
        pendingStartDeadline = nil
        Self.trail("pending start → startPictureInPicture()")
        start()
    }

    /// Dev diagnostic (`-pipProbe`): what AVKit thinks of the attached layer,
    /// at most every few seconds. `isPictureInPicturePossible` alone does not
    /// say WHY, so the layer's own readiness goes in the same line, and AVKit's
    /// own log lines for this process are copied into the trail: they are the
    /// only place the framework states its reason.
    private var lastProbeAt = Date.distantPast
    private var forcedStart = false
    private var dumpedRuntime = false
    private var interestingRuntimeNames: [String] = []
    private var probeTimer: Timer?
    private let probeStartedAt = Date()
    func probe() {
        guard PlayerDevFlags.pipProbe, let controller else { return }
        if probeTimer == nil {
            // Keep probing even when the engine's clock stops ticking.
            probeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] timer in
                guard self != nil else { timer.invalidate(); return }
                Task { @MainActor in self?.probe() }
            }
        }
        guard Date().timeIntervalSince(lastProbeAt) > 3.5 else { return }
        lastProbeAt = Date()
        var detail = "possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive)"
        if let layer = attachedLayer {
            detail += " ready=\(layer.isReadyForDisplay) item=\(layer.player?.currentItem != nil)"
            var root: CALayer = layer
            while let up = root.superlayer { root = up }
            detail += " bounds=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
            detail += " hidden=\(layer.isHidden) rootIsWindow=\(root.delegate is UIWindow)"
        }
        if let metal = attachedGenericView as? MetalPlayView {
            detail += " metal ticks=\(metal.diagDisplayLinkTicks) enq=\(metal.diagFramesEnqueued) nil=\(metal.diagFramesReturnedNil) notReady=\(metal.diagLayerNotReady) dlPaused=\(metal.diagDisplayLinkPaused) status=\(metal.displayLayer.status.rawValue)"
        }
        if let view = attachedGenericView {
            detail += " generic bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            detail += " inWindow=\(view.window != nil) hidden=\(view.isHidden) super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil")"
            if let content = controller.contentSource {
                detail += " src=\(String(describing: content.value(forKey: "source")).prefix(60))"
            }
        }
        let session = AVAudioSession.sharedInstance()
        detail += " app=\(UIApplication.shared.applicationState.rawValue)"
        detail += " audio=\(session.category.rawValue)/\(session.mode.rawValue)"
        Self.trail(detail)
        // Private state, read by name only: whatever AVKit keeps that mentions
        // possibility or a reason. Names are dumped once, values every probe.
        if !dumpedRuntime {
            dumpedRuntime = true
            var cls: AnyClass? = AVPictureInPictureController.self
            var names: [String] = []
            while let c = cls, c != NSObject.self {
                var count: UInt32 = 0
                if let list = class_copyPropertyList(c, &count) {
                    for i in 0..<Int(count) { names.append(String(cString: property_getName(list[i]))) }
                    free(list)
                }
                if let list = class_copyIvarList(c, &count) {
                    for i in 0..<Int(count) {
                        if let n = ivar_getName(list[i]) { names.append(String(cString: n)) }
                    }
                    free(list)
                }
                cls = class_getSuperclass(c)
            }
            interestingRuntimeNames = names.filter {
                let l = $0.lowercased()
                return l.contains("possib") || l.contains("reason") || l.contains("eligib") || l.contains("prohibit")
            }.sorted()
            Self.trail("runtime names: \(interestingRuntimeNames.joined(separator: ","))")
        }
        for name in interestingRuntimeNames {
            let key = name.hasPrefix("_") ? String(name.dropFirst()) : name
            let value = controller.value(forKey: key).map { String(describing: $0) } ?? "nil"
            if value != "0", value != "nil", value != "false" {
                Self.trail("  \(name)=\(value.prefix(200))")
            }
        }
        // AVKit's own words, from this process's log store. Read on a utility
        // queue: the store query walks every persisted entry since `from` and
        // takes longer the longer the session runs — on the main thread that
        // was a visible hitch every four seconds.
        Self.collectLogs(since: probeStartedAt.addingTimeInterval(-30))
        // `-pipForce`: start it even though AVKit says impossible, purely to
        // capture the error it answers with.
        if PlayerDevFlags.pipForce, !forcedStart, !isActive {
            forcedStart = true
            Self.trail("forcing start as soon as possible")
            startWhenPossible()
        }
    }

    nonisolated private static let logQueue = DispatchQueue(label: "orivio.pip.logs", qos: .utility)
    nonisolated(unsafe) private static var seenLogLines = Set<String>()
    nonisolated(unsafe) private static var logCollecting = false
    nonisolated(unsafe) private static var logPosition: OSLogPosition?
    nonisolated private static func collectLogs(since from: Date) {
        logQueue.async {
            guard !logCollecting else { return }
            logCollecting = true
            defer { logCollecting = false }
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
            let position = logPosition ?? store.position(date: from)
            let predicate = NSPredicate(format: "subsystem CONTAINS[c] 'avkit' OR subsystem CONTAINS[c] 'pictureinpicture' OR composedMessage CONTAINS[c] 'pictureinpicture' OR composedMessage CONTAINS[c] 'PiP' OR composedMessage CONTAINS '[Orivio' OR composedMessage CONTAINS '[video]' OR composedMessage CONTAINS '[audio]' OR category CONTAINS[c] 'AVAudioSession' OR subsystem CONTAINS[c] 'coreaudio'")
            guard let entries = try? store.getEntries(at: position, matching: predicate) else { return }
            var n = 0
            var newest: Date?
            let clock = Date.FormatStyle(date: .omitted, time: .standard)
            for entry in entries {
                guard let log = entry as? OSLogEntryLog, log.date > from else { continue }
                if log.composedMessage.hasPrefix("[OrivioPiP]") { continue }
                let msg = log.composedMessage.replacingOccurrences(of: "\n", with: " ")
                let line = "  log@\(log.date.formatted(clock)) \(log.category) \(msg.prefix(400))"
                guard seenLogLines.insert(line).inserted else { continue }
                newest = log.date
                n += 1
                if n > 80 { break }
                trail(line)
            }
            // Resume a few seconds behind the newest entry next time rather
            // than from the session start: entries can land in the store late.
            if let newest { logPosition = store.position(date: newest.addingTimeInterval(-5)) }
            if seenLogLines.count > 4000 { seenLogLines.removeAll() }
        }
    }

    /// Tear the controller down. IDEMPOTENT AND CHEAP WHEN ALREADY CLEAR —
    /// both `attach` overloads call this from their unavailable path, and that
    /// path is taken on every clock tick whenever there is nothing to attach
    /// to: the whole load phase before the engine has a view, and the entire
    /// film in the Simulator (where `isPictureInPictureSupported()` is false).
    /// `isPossible` is `@Published`, and Combine publishes on every assignment
    /// whether or not the value changed, so the unguarded version was firing
    /// `objectWillChange` ten times a second to re-nil eight fields that were
    /// already nil.
    private func reset() {
        guard controller != nil || attachedLayer != nil || attachedGenericView != nil
            || contentViewController != nil || bridge != nil || probeTimer != nil
            || possibleObservation != nil || isPossible else { return }
        probeTimer?.invalidate()
        probeTimer = nil
        possibleObservation = nil
        controller = nil
        attachedLayer = nil
        attachedGenericView = nil
        contentViewController = nil
        bridge = nil
        isPossible = false
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !isActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, isActive else { return }
        controller.stopPictureInPicture()
    }
}

extension PictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isActive = true
            self.routeGenericViewIntoPiP()
            self.onWillStart?()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        PictureInPictureController.trail("failed to start: \(error)")
        Task { @MainActor in
            // Never leave `isActive` set on a failure: the host would keep the
            // player dismissed for a PiP window that never appeared.
            self.isActive = false
            self.routeGenericViewHome()
            // AND UNPARK THE SESSION. AVKit sends `willStart` before it sends
            // this, so by now the host has already dismissed the full-screen
            // cover and parked the view model in `PiPHandoff` — and
            // `PlayerScreen.onDisappear` deliberately skipped teardown because
            // a handoff was in flight. Without this the engine, its buffers and
            // the whole view model stay alive with no window and no UI: the
            // film keeps decoding, audio keeps playing, and nothing can reach
            // it. Telling the host it stopped runs the teardown that was
            // skipped; it is a no-op when nothing was parked.
            self.onDidStop?()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.routeGenericViewHome()
            guard self.isActive else { return }
            self.isActive = false
            self.onDidStop?()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            guard let restore = self.onRestore else { completionHandler(false); return }
            // `isActive` is cleared HERE rather than in didStop, so didStop's
            // guard sees the restore already handled it and doesn't also fire
            // onDidStop — which would tear down the session we are restoring.
            self.isActive = false
            self.routeGenericViewHome()
            restore(completionHandler)
        }
    }
}

/// Keeps the player alive while the full-screen cover is dismissed for
/// Picture in Picture.
///
/// The cover's `@StateObject` is otherwise the ONLY owner of the view model.
/// Dismissing it so the viewer can browse would deallocate the model, stop the
/// engine, and take the PiP window down with it — so the handoff parks a
/// strong reference here for exactly as long as PiP is up.
///
/// This is also why `PlayerScreen.onDisappear` skips `teardown()` during a
/// handoff: everything teardown cancels (watchdogs, the idle timer, the
/// progress saver) still has a job to do while the video is playing in the
/// corner. It runs later, in `finish()`.
@MainActor
final class PiPHandoff {
    static let shared = PiPHandoff()
    private init() {}

    private(set) var viewModel: PlayerViewModel?
    private(set) var request: PlaybackRequest?

    /// Set by the root view: how to put the player back on screen.
    var present: ((PlaybackRequest) -> Void)?

    var isActive: Bool { viewModel != nil }

    /// Does the screen being built belong to a session parked here? The id
    /// check matters: starting a DIFFERENT title while one is in PiP must
    /// build a fresh model, not adopt the parked one.
    func parkedViewModel(for request: PlaybackRequest) -> PlayerViewModel? {
        self.request?.id == request.id ? viewModel : nil
    }

    /// Posted when a session is parked here, so screens the player dismisses
    /// onto can stop anything that would compete with it (DetailView's
    /// backdrop trailer).
    static let didBeginNotification = Notification.Name("OrivioPiPHandoffDidBegin")

    func begin(viewModel: PlayerViewModel, request: PlaybackRequest) {
        self.viewModel = viewModel
        self.request = request
        NotificationCenter.default.post(name: Self.didBeginNotification, object: nil)
    }

    /// PiP ended for good. Tear the session down properly — this is the
    /// teardown that `onDisappear` skipped.
    func finish() {
        viewModel?.isHandingOffToPictureInPicture = false
        viewModel?.teardown()
        viewModel = nil
        request = nil
    }

    /// The viewer wants the player back. Re-present, then tell AVKit.
    func restore(_ completion: @escaping (Bool) -> Void) {
        guard let request, let present else { completion(false); return }
        viewModel?.isHandingOffToPictureInPicture = false
        present(request)
        // The cover animates in; AVKit keeps the PiP window up until the
        // completion fires, so handing it back a runloop later avoids the
        // window vanishing before the full-screen video is on screen.
        DispatchQueue.main.async { completion(true) }
    }

    /// The re-presented screen adopted the parked model — stop holding it.
    /// 
    func releaseAfterRestore() {
        viewModel = nil
        request = nil
    }
}
