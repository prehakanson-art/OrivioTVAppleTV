import SwiftUI
import AVFoundation
import AVKit

/// A muted looping video layer for hero/detail backgrounds. Decorative:
/// no interaction, no hit-testing, and it must be **always mounted** and
/// revealed by opacity (inserting it mid-browse re-resolves focus).
final class BackgroundVideoController: ObservableObject {
    // Polled by the hero/Detail trailer tasks, never drawn: publishing them
    // re-rendered the whole page each time playback flipped waiting ↔ playing.
    private(set) var isPlaying = false
    private(set) var didEnd = false
    /// Made on first use: a page that never shows video never pays for an AVPlayer.
    private var made: AVQueuePlayer?
    /// Read before `player`: building a view with `player` allocates one even if
    /// the trailer never plays (Home did this on every launch).
    var hasPlayer: Bool { made != nil }
    var player: AVQueuePlayer {
        if let made { return made }
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.automaticallyWaitsToMinimizeStalling = true
        made = p
        return p
    }
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var currentKey: String?
    var loops = true

    /// `autoStart: false` loads and buffers the trailer without playing it
    /// (`start()` then rolls it at once).
    func play(source: TrailerSource, key: String, autoStart: Bool = true) async {
        guard currentKey != key else { return }
        currentKey = key
        let item = await source.makeItem()
        await MainActor.run {
            guard currentKey == key else { return }
            stopObservers()
            player.removeAllItems()
            didEnd = false
            if loops {
                looper = AVPlayerLooper(player: player, templateItem: item)
            } else {
                player.insert(item, after: nil)
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.isPlaying = false
                    self?.didEnd = true
                }
            }
            statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                let playing = p.timeControlStatus == .playing
                // Late callbacks after stop() (or a newer play) must not mark it playing.
                DispatchQueue.main.async { if let self, self.currentKey == key { self.isPlaying = playing } }
            }
            if autoStart { player.play() }
        }
        fitLetterbox(key: key)
    }

    func start() { made?.play() }

    // MARK: Baked-in letterbox

    private var letterboxTask: Task<Void, Never>?

    /// Many YouTube trailers carry cinema bars inside the frame; filled to the
    /// screen they show as black bands. A few frames are sampled once it plays
    /// and the picture zooms just enough to lose them (smallest bars seen win,
    /// so a dark scene can't over-zoom; black frames are ignored).
    private func fitLetterbox(key: String) {
        letterboxTask?.cancel()
        setZoom(1, animated: false)
        letterboxTask = Task { @MainActor [weak self] in
            // Real bars are identical in every frame: zoom once two frames agree
            // (a studio-logo intro or one dark scene can't decide it alone).
            var seen: [(top: CGFloat, bottom: CGFloat)] = []
            for at in [1.0, 3.0, 6.0, 10.0] {
                while let self, self.currentKey == key, (self.made?.currentTime().seconds ?? 0) < at {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                }
                guard let self, self.currentKey == key, let item = self.made?.currentItem else { return }
                let measured = await Self.bars(item)
                #if DEBUG
                DebugLog.write("[letterbox] video at \(at)s: \(measured.map { "top \($0.top) bottom \($0.bottom)" } ?? "no frame / black")")
                #endif
                guard let bars = measured, bars.top > 0 else { continue }
                if seen.contains(where: { abs($0.top - bars.top) < 0.008 && abs($0.bottom - bars.bottom) < 0.008 }) {
                    self.fit(bars, animated: true)
                    return
                }
                seen.append(bars)
            }
        }
    }

    /// Scales the picture area (between the bars) to fill, re-centred when the
    /// bars are uneven.
    private func fit(_ bars: (top: CGFloat, bottom: CGFloat), animated: Bool) {
        let visible = 1 - bars.top - bars.bottom
        guard bars.top + bars.bottom > 0.04, visible > 0.6,
              let view = made.flatMap({ PlayerLayerRegistry.view(for: $0) }) else { return setZoom(1, animated: animated) }
        let z = 1 / visible
        let shift = z * (bars.bottom - bars.top) / 2 * view.bounds.height
        apply(CGAffineTransform(translationX: 0, y: shift).scaledBy(x: z, y: z), to: view, animated: animated)
    }

    private func setZoom(_ z: CGFloat, animated: Bool) {
        guard let view = made.flatMap({ PlayerLayerRegistry.view(for: $0) }) else { return }
        apply(CGAffineTransform(scaleX: z, y: z), to: view, animated: animated)
    }

    private func apply(_ t: CGAffineTransform, to view: UIView, animated: Bool) {
        guard view.transform != t else { return }
        if animated { UIView.animate(withDuration: 0.45) { view.transform = t } } else { view.transform = t }
    }

    /// The top and bottom bars as shares of the frame's height (0 when there
    /// are none), or nil when the frame can't tell (no frame yet, or black).
    @MainActor
    private static func bars(_ item: AVPlayerItem) async -> (top: CGFloat, bottom: CGFloat)? {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        var buffer: CVPixelBuffer?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t) { buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil); break }
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard h >= 90 else { return nil }
        func isBar(_ y: Int) -> Bool {
            let row = base + y * bpr
            var x = 0
            while x < w {
                let p = row + x * 4
                if p[0] > 30 || p[1] > 30 || p[2] > 30 { return false }
                x += 8
            }
            return true
        }
        let limit = h / 4
        var top = 0
        while top < limit, isBar(top) { top += 1 }
        var bottom = 0
        while bottom < limit, isBar(h - 1 - bottom) { bottom += 1 }
        guard top < limit, bottom < limit else { return nil }          // a black frame
        // Letterbox bars come in pairs; one dark edge alone is the picture.
        guard min(top, bottom) >= h / 40 else { return (0, 0) }
        return (CGFloat(top) / CGFloat(h), CGFloat(bottom) / CGFloat(h))
    }

    func stop() {
        currentKey = nil
        letterboxTask?.cancel()
        setZoom(1, animated: false)
        stopObservers()
        made?.pause()
        made?.removeAllItems()
        looper = nil
        isPlaying = false
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    private func stopObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
    }

    deinit { stop() }
}

struct BackgroundVideoView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.isUserInteractionEnabled = false
        v.playerLayer.player = player
        PlayerLayerRegistry.register(v, for: player)
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player {
            v.playerLayer.player = player
            PlayerLayerRegistry.register(v, for: player)
        }
        v.playerLayer.videoGravity = gravity
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The layer view showing each background player (the letterbox zoom applies
/// there). Main thread only.
enum PlayerLayerRegistry {
    private final class Weak { weak var view: UIView? ; init(_ v: UIView) { view = v } }
    private static var views: [ObjectIdentifier: Weak] = [:]
    static func register(_ v: UIView, for player: AVPlayer) {
        views = views.filter { $0.value.view != nil }
        views[ObjectIdentifier(player)] = Weak(v)
    }
    static func view(for player: AVPlayer) -> UIView? { views[ObjectIdentifier(player)]?.view }
}

/// Full-screen trailer with sound, system transport. Alternates tried in order.
/// `AVPlayerViewController` embedded in a SwiftUI cover has no dismissal of its
/// own: once the trailer is playing, Menu was swallowed by the transport
/// controls and the only way out was scrubbing to the end. Take the Menu press
/// before the player's controls see it, leaving every other command (play,
/// pause, scrub, swipes) untouched.
final class TrailerPlayerViewController: AVPlayerViewController {
    var onMenu: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesEnded(presses, with: event)
    }
}

struct TrailerFullScreen: UIViewControllerRepresentable {
    let keys: [String]
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> TrailerPlayerViewController {
        let vc = TrailerPlayerViewController()
        vc.onMenu = onDone
        vc.delegate = context.coordinator
        // A trailer never switches the TV's mode: AVPlayerViewController does
        // by default under Match Content (two HDMI switches per trailer, and a
        // grey panel when one lands mid-transition).
        vc.appliesPreferredDisplayCriteriaAutomatically = false
        Task {
            if let src = await TrailerService.resolveFirst(keys, muted: false) {
                let item = await src.makeItem()
                await MainActor.run {
                    let player = AVPlayer(playerItem: item)
                    vc.player = player
                    context.coordinator.observeEnd(item)
                    player.play()
                }
            } else {
                await MainActor.run {
                    ToastCenter.shared.show("Trailer unavailable", systemImage: "exclamationmark.triangle.fill")
                    onDone()
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: TrailerPlayerViewController, context: Context) {
        vc.onMenu = onDone
    }

    static func dismantleUIViewController(_ vc: TrailerPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        vc.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onDone: () -> Void
        private var obs: NSObjectProtocol?
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        deinit { if let obs { NotificationCenter.default.removeObserver(obs) } }

        func observeEnd(_ item: AVPlayerItem) {
            if let obs { NotificationCenter.default.removeObserver(obs) }
            obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.onDone()
            }
        }

        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool { true }
        func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) { onDone() }
    }
}
