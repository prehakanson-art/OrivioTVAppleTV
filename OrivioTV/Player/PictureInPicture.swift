import AVKit
import UIKit

/// Picture in Picture for the player.
///
/// tvOS has had `AVPictureInPictureController` since 14, but only for content
/// AVKit is itself rendering. Of this app's four engines that is exactly one:
///
/// * **KSAVPlayer** — an `AVPlayer` behind an `AVPlayerLayer`. PiP works, and
///   this is `KSOptions.firstPlayerType` for real mp4/HLS.
/// * **KSMEPlayer** — the FFmpeg engine, drawing through Metal. There is no
///   layer to hand AVKit. Auto picks this for mkv and extensionless debrid
///   links, which is most of what this app actually plays, so PiP is
///   genuinely unavailable much of the time.
/// * **VLC** — renders into its own drawable. Same story.
/// * **DVSampleEngine** — feeds an `AVSampleBufferDisplayLayer`, which *can*
///   drive PiP via a sample-buffer content source. That is not a layer
///   handover though: it needs a full
///   `AVPictureInPictureSampleBufferPlaybackDelegate` supplying transport,
///   seeking and a live time range. Not wired up.
///
/// So availability is decided per SESSION rather than once, and the control is
/// hidden when the engine that actually loaded can't do it — better than
/// offering a button that silently fails.
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
    private weak var attachedLayer: AVPlayerLayer?

    /// Point at whatever the engine renders into.
    ///
    /// Idempotent on purpose: `PlayerVideoView.updateUIView` calls this on
    /// every SwiftUI update, so rebuilding the controller each time would
    /// churn AVKit state (and drop an active PiP session) many times a second.
    func attach(to view: UIView?) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = view?.layer as? AVPlayerLayer else {
            // Every non-AVPlayer engine lands here. Don't tear down an ACTIVE
            // session: during the handoff the render view is going away by
            // design, and resetting here would kill the PiP window we just
            // opened.
            if !isActive { reset() }
            return
        }
        guard layer !== attachedLayer else { return }
        reset()
        attachedLayer = layer
        let pip = AVPictureInPictureController(playerLayer: layer)
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
