import UIKit
import SwiftUI
import GameController

/// Window-level remote catchers (§7.8 layer 5). Menu and ⏯ always go through
/// here so they can't be lost; Select/arrows are captured only on bare video,
/// the bar and in scrub mode (elsewhere real buttons need them). The touch
/// surface is read two ways: pan translation (swipes, scrub) and the
/// GameController's absolute dpad position (edge clicks, the jog wheel ring).
final class RemoteInputView: UIView, UIGestureRecognizerDelegate {
    var onPress: ((RemotePress) -> Void)?
    var onSwipe: ((CGFloat, CGFloat) -> Void)?
    var onPanDelta: ((CGFloat) -> Void)?
    var onLightTap: (() -> Void)?
    var onWheel: ((Double) -> Void)?
    var onWheelEnd: (() -> Void)?
    var isScrubbing: () -> Bool = { false }

    var capturesSelect = true { didSet { selectTap.isEnabled = capturesSelect } }
    var capturesArrows = true { didSet { arrowRecognizers.forEach { $0.isEnabled = capturesArrows } } }

    private let selectTap = UITapGestureRecognizer()
    private let playPauseTap = UITapGestureRecognizer()
    private let menuTap = UITapGestureRecognizer()
    private var arrowRecognizers: [UITapGestureRecognizer] = []
    private let lightTap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private weak var attachedWindow: UIWindow?

    private var lastPan = CGPoint.zero
    private var lastPressAt = Date.distantPast
    private var touchStartedAt: Date?
    private var dpad = CGPoint.zero
    private var dpadAt = Date.distantPast
    private var ringSince: Date?
    private var wheelAngle: Double?
    private var gcObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        selectTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        selectTap.addTarget(self, action: #selector(selectPressed))
        playPauseTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        playPauseTap.addTarget(self, action: #selector(playPausePressed))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.addTarget(self, action: #selector(menuPressed))
        for (type, sel) in [(UIPress.PressType.leftArrow, #selector(leftPressed)), (.rightArrow, #selector(rightPressed)),
                            (.upArrow, #selector(upPressed)), (.downArrow, #selector(downPressed))] {
            let r = UITapGestureRecognizer(target: self, action: sel)
            r.allowedPressTypes = [NSNumber(value: type.rawValue)]
            arrowRecognizers.append(r)
        }
        lightTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        lightTap.allowedPressTypes = []
        lightTap.addTarget(self, action: #selector(lightTapped))
        lightTap.cancelsTouchesInView = false
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.addTarget(self, action: #selector(panned(_:)))
        for r in [lightTap, pan] as [UIGestureRecognizer] { r.delegate = self }
        selectTap.delegate = self
        arrowRecognizers.forEach { $0.delegate = self }

        gcObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.configureControllers()
        }
        configureControllers()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let gcObserver { NotificationCenter.default.removeObserver(gcObserver) }
    }

    private var all: [UIGestureRecognizer] { [selectTap, playPauseTap, menuTap, lightTap, pan] + arrowRecognizers }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let w = window else { return }
        all.forEach { w.addGestureRecognizer($0) }
        attachedWindow = w
    }

    func detach() {
        guard let w = attachedWindow else { return }
        all.forEach { w.removeGestureRecognizer($0) }
        attachedWindow = nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: GameController (absolute touch position)

    private func configureControllers() {
        for c in GCController.controllers() {
            guard let pad = c.microGamepad else { continue }
            pad.reportsAbsoluteDpadValues = true
            pad.allowsRotation = false
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.dpadChanged(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
    }

    private func dpadChanged(_ p: CGPoint) {
        let touching = p != .zero
        dpad = p
        dpadAt = Date()
        if touching, touchStartedAt == nil { touchStartedAt = Date() }
        if !touching { touchStartedAt = nil }
        guard isScrubbing() else { ringSince = nil; wheelAngle = nil; return }
        // Rest on the outer ring (> 0.72 radius) for 0.15 s → fine-tune wheel.
        let r = hypot(p.x, p.y)
        if touching, r > 0.72 {
            if ringSince == nil { ringSince = Date() }
            if let since = ringSince, Date().timeIntervalSince(since) > 0.15 {
                let angle = atan2(Double(p.y), Double(p.x))
                if let last = wheelAngle {
                    var d = angle - last
                    if d > .pi { d -= 2 * .pi }
                    if d < -.pi { d += 2 * .pi }
                    // Clockwise (negative atan2 delta) moves forward.
                    onWheel?(-d)
                }
                wheelAngle = angle
            }
        } else {
            if wheelAngle != nil { onWheelEnd?() }
            ringSince = nil
            wheelAngle = nil
        }
    }

    // MARK: Presses

    @objc private func selectPressed() {
        lastPressAt = Date()
        // A click on the clickpad's edge (1st-gen remote) reports as Select; read where the finger was.
        if Date().timeIntervalSince(dpadAt) < 0.4 {
            if dpad.x < -0.6 { onPress?(.edge(.leading)); return }
            if dpad.x > 0.6 { onPress?(.edge(.trailing)); return }
            if dpad.y > 0.6 { onPress?(.edge(.top)); return }
            if dpad.y < -0.6 { onPress?(.edge(.bottom)); return }
        }
        onPress?(.select)
    }

    @objc private func playPausePressed() { lastPressAt = Date(); onPress?(.playPause(source: "window")) }
    @objc private func menuPressed() { lastPressAt = Date(); onPress?(.menu) }
    @objc private func leftPressed() { lastPressAt = Date(); onPress?(.edge(.leading)) }
    @objc private func rightPressed() { lastPressAt = Date(); onPress?(.edge(.trailing)) }
    @objc private func upPressed() { lastPressAt = Date(); onPress?(.edge(.top)) }
    @objc private func downPressed() { lastPressAt = Date(); onPress?(.edge(.bottom)) }

    /// Touch < 0.6 s, no click, no swipe.
    @objc private func lightTapped() {
        guard Date().timeIntervalSince(lastPressAt) > 0.35 else { return }
        if let start = touchStartedAt, Date().timeIntervalSince(start) > 0.6 { return }
        onLightTap?()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            lastPan = .zero
        case .changed:
            if isScrubbing(), wheelAngle == nil {
                onPanDelta?(t.x - lastPan.x)
            }
            lastPan = t
        case .ended:
            if !isScrubbing() { onSwipe?(t.x, t.y) }
            lastPan = .zero
        default:
            lastPan = .zero
        }
    }
}

struct RemoteInputLayer: UIViewRepresentable {
    @ObservedObject var vm: PlayerViewModel

    func makeUIView(context: Context) -> RemoteInputView {
        let v = RemoteInputView()
        v.onPress = { [weak vm] p in vm?.handle(p) }
        v.onSwipe = { [weak vm] dx, dy in vm?.handleSwipe(dx: dx, dy: dy) }
        v.onPanDelta = { [weak vm] dx in vm?.scrubPan(dx: dx) }
        v.onLightTap = { [weak vm] in vm?.handleLightTap() }
        v.onWheel = { [weak vm] a in vm?.scrubWheel(angleDelta: a) }
        v.onWheelEnd = { [weak vm] in vm?.endWheel() }
        v.isScrubbing = { [weak vm] in vm?.scrub != nil }
        return v
    }

    func updateUIView(_ v: RemoteInputView, context: Context) {
        v.capturesSelect = vm.capturesSelect
        v.capturesArrows = vm.capturesArrows
    }

    static func dismantleUIView(_ v: RemoteInputView, coordinator: ()) {
        v.detach()
    }
}
