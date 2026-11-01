import AVKit
import UIKit

/// §7.20 Picture in Picture. Native engine: standard `AVPlayerLayer` PiP. Every
/// other engine (FFmpeg, VLC, the DV sample feed): tvOS AVKit REJECTS
/// sample-buffer sources, so those go through the private generic-view route
/// (`GenericPictureInPicture`: an `AVPictureInPictureContentViewController`
/// hosting the real render view, with `PiPPlaybackBridge` standing in for the
/// player controller). Entering PiP dismisses the cover but parks the view
/// model; returning re-presents the same request and adopts it; closing PiP
/// tears it down. The simulator reports PiP unsupported — device only.
@MainActor
final class PiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private weak var vm: PlayerViewModel?
    private var restoring = false

    // Generic-view route.
    private var bridge: PiPPlaybackBridge?
    private var contentViewController: UIViewController?
    /// The render view the ContentSource was BUILT for (rebuild when it changes).
    private weak var genericView: UIView?
    /// The view currently parented in the content view controller.
    private weak var hostedView: UIView?

    init(vm: PlayerViewModel) {
        self.vm = vm
    }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    static var supportsGeneric: Bool { isSupported && GenericPictureInPicture.isAvailable }

    func start(layer: AVPlayerLayer) {
        guard Self.isSupported else { vm?.showToast("Picture in Picture isn't available here"); return }
        if controller?.playerLayer !== layer {
            resetGeneric()
            controller = AVPictureInPictureController(playerLayer: layer)
            controller?.delegate = self
        }
        attemptStart(tries: 0)
    }

    /// The generic route, for an engine that renders into `view` with no AVPlayerLayer.
    func start(genericView view: UIView) {
        guard Self.supportsGeneric else { vm?.showToast("Picture in Picture isn't available here"); return }
        if genericView !== view || controller == nil {
            resetGeneric()
            controller = nil
            guard let contentVC = GenericPictureInPicture.makeContentViewController() else {
                vm?.showToast("Picture in Picture isn't available here")
                return
            }
            let bridge = PiPPlaybackBridge()
            bridge.onSetPlaying = { [weak self] playing in self?.vm?.pipSetPlaying(playing) }
            bridge.onSeek = { [weak self] t in self?.vm?.seek(to: t, keepPaused: nil) }
            bridge.onSetMuted = { [weak self] muted in self?.vm?.pipSetMuted(muted) }
            guard let source = GenericPictureInPicture.makeContentSource(sourceView: view, contentViewController: contentVC,
                                                                         playerController: bridge) else {
                vm?.showToast("Picture in Picture isn't available here")
                return
            }
            genericView = view
            contentViewController = contentVC
            self.bridge = bridge
            controller = AVPictureInPictureController(contentSource: source)
            controller?.delegate = self
            if let vm { updateBridge(vm) }
        }
        attemptStart(tries: 0)
    }

    /// State the PiP window shows (play/pause, position, size). Called from the player's tick.
    func updateBridge(_ vm: PlayerViewModel) {
        guard let bridge else { return }
        bridge.update(playing: !vm.isPaused && (vm.engine?.isPlaying ?? false), position: vm.currentTime,
                      duration: vm.duration, size: vm.engine?.naturalSize ?? .zero)
    }

    /// Move the render view into the PiP window's content controller.
    private func routeViewIntoPiP() {
        guard let view = genericView, let host = contentViewController?.view else { return }
        host.backgroundColor = .black
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.transform = .identity   // the player's zoom; the host reapplies it on return
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        hostedView = view
    }

    /// The PiP window is hosting `view` right now.
    func holds(_ view: UIView) -> Bool { hostedView === view && view.superview != nil }

    /// Give the view back: the re-presented player screen's host re-parents it
    /// on its next update (`VideoHost` adds the engine view wherever it isn't).
    private func routeViewHome() {
        guard let view = hostedView, view.superview === contentViewController?.view else { return }
        hostedView = nil
        view.removeFromSuperview()
    }

    private func resetGeneric() {
        routeViewHome()
        bridge = nil
        contentViewController = nil
        genericView = nil
    }

    private func attemptStart(tries: Int) {
        guard let c = controller else { return }
        if c.isPictureInPicturePossible {
            c.startPictureInPicture()
        } else if tries < 10 {
            // Possible flips true shortly after the controller is made.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attemptStart(tries: tries + 1) }
        } else {
            vm?.showToast("Picture in Picture couldn't start")
        }
    }

    func stop() { controller?.stopPictureInPicture() }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        // The window is about to take the picture: on the generic route, hand it the view.
        Task { @MainActor in self.routeViewIntoPiP() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            guard let vm else { return }
            vm.setPiPActive(true)
            PlayerPresenter.shared.parkedModel = vm
            PlayerPresenter.shared.request = nil
        }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            restoring = true
            routeViewHome()
            if let vm { PlayerPresenter.shared.request = vm.currentRequest }
            // A runloop later, so the full-screen video is up before the window goes.
            DispatchQueue.main.async { done(true) }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            routeViewHome()
            guard let vm else { return }
            vm.setPiPActive(false)
            if !restoring {
                // Closed from the PiP window: end the session.
                vm.saveProgress(transient: false)
                vm.teardown()
                PlayerPresenter.shared.parkedModel = nil
            }
            restoring = false
        }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            // AVKit sends willStart before this: the view must come home, and a
            // session that was parked (didStart never fired, so normally not) is unparked.
            routeViewHome()
            vm?.setPiPActive(false)
            vm?.showToast("Picture in Picture failed: \(error.localizedDescription)")
        }
    }
}
