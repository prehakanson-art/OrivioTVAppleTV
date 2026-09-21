import AVKit
import ObjectiveC
import UIKit

/// The engine-agnostic Picture in Picture path, on top of AVKit's private
/// "generic view" content source.
///
/// tvOS AVKit will not take a sample-buffer layer for PiP (see the header of
/// PictureInPicture.swift), but its platform adapter DOES accept a third
/// source kind it uses for its own non-AVPlayer video: an
/// `AVPictureInPictureContentViewController` whose view is hosted in the
/// system PiP window, paired with a "player controller" object that the
/// adapter interrogates for playback state and sends transport commands to.
/// Neither is public API. Everything here is resolved at runtime and bails
/// to "no PiP" when a class or selector is missing, so a future tvOS that
/// drops the path degrades to the row disappearing rather than a crash.
///
/// What AVKit asks the player controller for was recovered from the device's
/// AVKit binary (`-[AVPictureInPicturePlatformAdapter(Common)
/// _updateStatusUsingProposedStatus:]`, `-[AVPictureInPictureController
/// pictureInPicturePlatformAdapter:handlePlaybackCommand:]`): possibility,
/// content dimensions, second-screen state, play/pause/mute toggles and the
/// interruption bookkeeping. Anything not implemented explicitly is answered
/// by `resolveInstanceMethod` with a zero and written to the PiP trail, so a
/// selector this build never saw shows up by name instead of as a crash.
enum GenericPictureInPicture {
    /// `static let`, not a computed var: the runtime's answer cannot change
    /// within a process, and this is read from the player's 10 Hz tick — an
    /// NSClassFromString + class_getInstanceMethod pair per tick, for the
    /// whole film, on the main actor.
    static let isAvailable: Bool =
        NSClassFromString("AVPictureInPictureContentViewController") != nil
            && class_getInstanceMethod(AVPictureInPictureController.ContentSource.self,
                                       initSelector) != nil

    private static let initSelector = NSSelectorFromString(
        "initWithSourceView:contentViewController:playerController:")

    /// Build the private content source. `sourceView` is what AVKit measures
    /// for visibility and the zoom-out animation; `contentViewController` is
    /// what the PiP window hosts (the video view is moved into it when PiP
    /// starts); `playerController` is the bridge.
    static func makeContentSource(sourceView: UIView,
                                  contentViewController: UIViewController,
                                  playerController: PiPPlaybackBridge)
        -> AVPictureInPictureController.ContentSource?
    {
        let cls: AnyClass = AVPictureInPictureController.ContentSource.self
        guard let method = class_getInstanceMethod(cls, initSelector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, UIView, UIViewController, AnyObject)
            -> Unmanaged<AnyObject>?
        let imp = unsafeBitCast(method_getImplementation(method), to: Init.self)
        guard let allocated = class_createInstance(cls, 0) else { return nil }
        // Ownership, carefully: `class_createInstance` is declared
        // OBJC_RETURNS_RETAINED, so Swift's `allocated` binding OWNS the
        // create's +1 and ARC releases it when this scope ends — the create
        // needs no manual balancing here. The only manual references are the
        // +1 handed to ObjC `init` (which consumes it, per convention) and
        // init's returned +1, consumed by `takeRetainedValue()`.
        //
        // An extra `autorelease()` "balancing the create" sat here briefly and
        // over-released every ContentSource by one: AVKit's copy died while
        // the PiP controller still used it, and the heap corruption surfaced
        // as SIGSEGVs in SwiftUI graph teardown when the player was dismissed
        // — the "app crashes or freezes on exiting the player".
        let object = allocated as AnyObject
        let handed = Unmanaged.passRetained(object)   // the +1 `init` consumes
        guard let result = imp(handed.takeUnretainedValue(), initSelector,
                               sourceView, contentViewController, playerController) else {
            return nil
        }
        return result.takeRetainedValue() as? AVPictureInPictureController.ContentSource
    }

    static func makeContentViewController() -> UIViewController? {
        guard let cls = NSClassFromString("AVPictureInPictureContentViewController") as? UIViewController.Type
        else { return nil }
        return cls.init()
    }
}

/// Stands in for AVKit's `AVPlayerController` on the generic path: the PiP
/// adapter reads playback state from it and routes the PiP window's
/// transport controls through it. State is pushed in by `PlayerViewModel`
/// on every clock tick; commands go back out through the closures.
final class PiPPlaybackBridge: NSObject {
    var onSetPlaying: ((Bool) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSetMuted: ((Bool) -> Void)?

    // Written on main by the view model's clock tick, read by AVKit's platform
    // adapter on its own queue: locked, so `sizeState` (two words) can never
    // be read half-updated and `activitySessionIdentifier` never torn.
    @Atomic private var playingState = false
    @Atomic private var positionState: Double = 0
    @Atomic private var durationState: Double = 0
    @Atomic private var sizeState = CGSize(width: 1920, height: 1080)
    @Atomic private var mutedState = false
    // The adapter reads AND writes these back from its own queue while the main
    // thread may read them, so they are locked like the fields above — the
    // header comment already claimed that, but only the @Atomic ones were.
    @Atomic private var interrupted = false
    @Atomic private var wasPlayingBeforeInterruption = false
    @Atomic private var allowsPiP = true
    @Atomic private var supported = true
    @Atomic private var active = false
    @Atomic private var canToggle = true
    @Atomic private var activitySessionIdentifier: String?
    private weak var pictureInPictureController: AnyObject?

    /// Feed the latest engine state. Emits KVO only for what changed, since
    /// the adapter observes at least the playing flag with an initial value.
    func update(playing: Bool, position: Double, duration: Double, size: CGSize) {
        if playing != playingState {
            willChangeValue(forKey: "playing")
            willChangeValue(forKey: "isPlaying")
            playingState = playing
            didChangeValue(forKey: "playing")
            didChangeValue(forKey: "isPlaying")
        }
        positionState = position
        if duration != durationState {
            willChangeValue(forKey: "contentDuration")
            willChangeValue(forKey: "maxTime")
            durationState = duration
            didChangeValue(forKey: "contentDuration")
            didChangeValue(forKey: "maxTime")
        }
        if size != .zero, size != sizeState {
            willChangeValue(forKey: "contentDimensions")
            sizeState = size
            didChangeValue(forKey: "contentDimensions")
        }
    }

    // MARK: Possibility

    @objc func isPictureInPicturePossible() -> Bool { true }
    @objc func hasVideo() -> Bool { true }
    @objc func hasEnabledVideo() -> Bool { true }
    @objc func hasEnabledAudio() -> Bool { true }
    @objc func isReadyToPlay() -> Bool { true }
    @objc func status() -> Int { 1 }
    @objc func isStreaming() -> Bool { false }
    @objc func isPlayingOnSecondScreen() -> Bool { false }
    @objc func setPlayingOnSecondScreen(_ flag: Bool) {}
    @objc func isPlayingOnExternalScreen() -> Bool { false }
    @objc func hasLiveStreamingContent() -> Bool { false }
    @objc func hasSeekableLiveStreamingContent() -> Bool { false }
    @objc func atLiveEdge() -> Bool { false }
    @objc func contentDimensions() -> CGSize { sizeState }
    @objc func presentationSize() -> CGSize { sizeState }
    @objc func activePlayer() -> AnyObject? { nil }
    @objc func player() -> AnyObject? { nil }

    // MARK: Transport

    /// The command closures are formed inside `@MainActor` code and touch the
    /// view model; AVKit may call these entry points from any queue, so hop.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    @objc func isPlaying() -> Bool { playingState }
    @objc func setPlaying(_ playing: Bool) {
        PictureInPictureController.trail("bridge: setPlaying \(playing)")
        onMain { [self] in onSetPlaying?(playing) }
    }
    @objc func togglePlaybackEvenWhenInBackground(_ flag: Bool) {
        PictureInPictureController.trail("bridge: togglePlayback (background=\(flag))")
        let next = !playingState
        onMain { [self] in onSetPlaying?(next) }
    }
    @objc func play() { setPlaying(true) }
    @objc func pause() { setPlaying(false) }
    @objc func rate() -> Double { playingState ? 1 : 0 }
    @objc func setRate(_ rate: Double) { onMain { [self] in onSetPlaying?(rate != 0) } }
    @objc func defaultPlaybackRate() -> Double { 1 }
    @objc func effectiveRateNonZero() -> Bool { playingState }
    @objc func canTogglePlayback() -> Bool { true }
    @objc func canSeek() -> Bool { durationState > 0 }
    @objc func currentTime() -> Double { positionState }
    @objc func contentDuration() -> Double { durationState }
    @objc func minTime() -> Double { 0 }
    @objc func maxTime() -> Double { durationState }
    @objc func seekToTime(_ time: Double) {
        PictureInPictureController.trail("bridge: seekToTime \(time)")
        onMain { [self] in onSeek?(time) }
    }
    @objc func isMuted() -> Bool { mutedState }
    @objc func setMuted(_ muted: Bool) {
        PictureInPictureController.trail("bridge: setMuted \(muted)")
        mutedState = muted
        onMain { [self] in onSetMuted?(muted) }
    }

    // MARK: PiP bookkeeping the adapter writes back

    @objc func isPictureInPictureInterrupted() -> Bool { interrupted }
    @objc func setPictureInPictureInterrupted(_ flag: Bool) {
        PictureInPictureController.trail("bridge: interrupted \(flag)")
        interrupted = flag
    }
    @objc func wasPlayingWhenPictureInPictureInterruptionBegan() -> Bool { wasPlayingBeforeInterruption }
    @objc func setWasPlayingWhenPictureInPictureInterruptionBegan(_ flag: Bool) { wasPlayingBeforeInterruption = flag }
    @objc func allowsPictureInPicturePlayback() -> Bool { allowsPiP }
    @objc func setAllowsPictureInPicturePlayback(_ flag: Bool) { allowsPiP = flag }
    @objc func isPictureInPictureSupported() -> Bool { supported }
    @objc func setPictureInPictureSupported(_ flag: Bool) { supported = flag }
    @objc func isPictureInPictureActive() -> Bool { active }
    @objc func setPictureInPictureActive(_ flag: Bool) { active = flag }
    @objc func canTogglePictureInPicture() -> Bool { canToggle }
    @objc func setCanTogglePictureInPicture(_ flag: Bool) { canToggle = flag }
    @objc func pipActivitySessionIdentifier() -> String? { activitySessionIdentifier }
    @objc func setPipActivitySessionIdentifier(_ id: String?) {
        PictureInPictureController.trail("bridge: activity session \(id ?? "nil")")
        activitySessionIdentifier = id
    }
    @objc func setHandlesAudioSessionInterruptions(_ flag: Bool) {}
    @objc func setPictureInPictureController(_ controller: AnyObject?) { pictureInPictureController = controller }
    @objc func isReducingResourcesForPictureInPicture() -> Bool { false }
    @objc func beginReducingResourcesForPictureInPicturePlayerLayer(_ layer: AnyObject?) {}
    @objc func endReducingResourcesForPictureInPicturePlayerLayer(_ layer: AnyObject?) {}

    // MARK: Unknowns — logged here, answered with zero by the sink

    /// Never add methods to THIS class: KVO decides how to observe a key by
    /// asking `respondsToSelector:` for collection accessors (`getPlaying`,
    /// `insertObject:inPlayingAtIndex:`…), and a class that says yes to
    /// everything turns a BOOL into an ordered collection and crashes. So
    /// selectors that are not implemented stay unimplemented — `respondsTo`
    /// answers honestly — and a real send of one is forwarded to a sink that
    /// answers zero.
    override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
        let name = NSStringFromSelector(sel)
        if !name.hasPrefix("_"), !PiPUnknownSink.isKVOAccessorProbe(name) {
            PictureInPictureController.trail("bridge: asked for \(name)")
        }
        return super.resolveInstanceMethod(sel)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        PictureInPictureController.trail("bridge: forwarding \(NSStringFromSelector(aSelector))")
        return PiPUnknownSink.shared
    }

    override func value(forUndefinedKey key: String) -> Any? {
        PictureInPictureController.trail("bridge: unknown key \(key)")
        return nil
    }

    override func setValue(_ value: Any?, forUndefinedKey key: String) {
        PictureInPictureController.trail("bridge: unknown key set \(key)")
    }
}

/// Receives every message the bridge does not implement and answers zero,
/// so an AVKit selector this build never saw degrades to a no-op that is
/// named in the trail rather than an unrecognized-selector crash. Nothing
/// observes this object, so resolving selectors on demand is safe here.
final class PiPUnknownSink: NSObject {
    static let shared = PiPUnknownSink()

    static func isKVOAccessorProbe(_ name: String) -> Bool {
        ["get", "insertObject:", "insert", "removeObjectFrom", "remove", "replaceObjectIn",
         "replace", "add", "intersect", "countOf", "objectIn", "enumeratorOf", "memberOf"]
            .contains { name.hasPrefix($0) }
    }

    override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
        let name = NSStringFromSelector(sel)
        // Integer zero in x0: the sink cannot know the real signature, and an
        // integer return is the only choice that is DEFINED for the common
        // cases (BOOL `-is…`/`-can…` → NO, int → 0, pointer → nil). A float or
        // struct return remains undefined either way; anything that must
        // return one belongs on the bridge itself, named in the trail.
        let block: @convention(block) (AnyObject) -> Int = { _ in 0 }
        let imp = imp_implementationWithBlock(block)
        let arguments = name.filter { $0 == ":" }.count
        class_addMethod(self, sel, imp, "q@:" + String(repeating: "@", count: arguments))
        return true
    }
}
