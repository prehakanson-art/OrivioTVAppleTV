import AVKit
import KSPlayer
import UIKit

/// Picture in Picture for the player.
///
/// AVKit will only drive PiP from a layer it can take over: an `AVPlayerLayer`,
/// or an `AVSampleBufferDisplayLayer` paired with a playback delegate. Three of
/// this app's four engines qualify:
///
/// * **KSAVPlayer** — an `AVPlayer` behind an `AVPlayerLayer`. The mp4/HLS path.
/// * **KSMEPlayer** (FFmpeg) — draws into an `AVSampleBufferDisplayLayer`
///   whenever `KSOptions.isUseDisplayLayer()` holds, which is `display ==
///   .plane` — the default this app never changes. KSPlayer already conforms
///   KSMEPlayer to `AVPictureInPictureSampleBufferPlaybackDelegate`, so the
///   transport comes for free. This is the engine Auto picks for mkv and
///   extensionless debrid links, i.e. most of what actually gets played.
/// * **DVSampleEngine** — feeds its own `AVSampleBufferDisplayLayer`; the
///   delegate is implemented alongside the engine.
/// * **VLC** — renders into its own drawable with no CALayer AVKit can adopt.
///   This one genuinely cannot, and is the only exclusion.
///
/// Availability is still decided per SESSION rather than assumed: the control
/// is hidden unless the engine that actually loaded produced a usable source
/// and AVKit reports PiP possible for it.
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

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var attachedLayer: CALayer?

    /// Where the picture comes from. Built by `PlayerViewModel` from whichever
    /// engine is live, because only it knows which one that is.
    enum Source {
        case playerLayer(AVPlayerLayer)
        case sampleBuffer(AVSampleBufferDisplayLayer, AVPictureInPictureSampleBufferPlaybackDelegate)

        /// Identity used to decide whether the attached source actually
        /// changed. Comparing the LAYER (not the enum, which can't be
        /// Equatable with a delegate in it) is what makes `attach` idempotent.
        var layer: CALayer {
            switch self {
            case .playerLayer(let l): return l
            case .sampleBuffer(let l, _): return l
            }
        }
    }

    /// Point at whatever the engine renders into.
    ///
    /// Idempotent on purpose: `PlayerVideoView.updateUIView` calls this on
    /// every SwiftUI update, so rebuilding the controller each time would churn
    /// AVKit state (and drop an active PiP session) many times a second.
    func attach(_ source: Source?) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let source else {
            // VLC, or a device/simulator without PiP. Don't tear down an ACTIVE
            // session: during the handoff the render view is going away by
            // design, and resetting here would kill the window just opened.
            if !isActive { reset() }
            return
        }
        guard source.layer !== attachedLayer else { return }
        reset()
        attachedLayer = source.layer
        let pip: AVPictureInPictureController?
        switch source {
        case .playerLayer(let layer):
            pip = AVPictureInPictureController(playerLayer: layer)
        case .sampleBuffer(let layer, let delegate):
            pip = AVPictureInPictureController(contentSource: .init(
                sampleBufferDisplayLayer: layer, playbackDelegate: delegate))
        }
        pip?.delegate = self
        controller = pip
        possibleObservation = pip?.observe(\.isPictureInPicturePossible,
                                           options: [.initial, .new]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    func detach() { reset() }

    private func reset() {
        possibleObservation = nil
        controller = nil
        attachedLayer = nil
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
            self.onWillStart?()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[OrivioPiP] failed to start: %@", error.localizedDescription)
        Task { @MainActor in
            // Never leave `isActive` set on a failure: the host would keep the
            // player dismissed for a PiP window that never appeared.
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
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

    func begin(viewModel: PlayerViewModel, request: PlaybackRequest) {
        self.viewModel = viewModel
        self.request = request
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
    func releaseAfterRestore() {
        viewModel = nil
        request = nil
    }
}
