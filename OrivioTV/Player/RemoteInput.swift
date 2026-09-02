import SwiftUI
import UIKit

/// Window-level Siri-remote TRACKPAD capture. Two recognizers on the window,
/// both restricted to `.indirect` touches (REQUIRED on tvOS or the focus engine
/// eats every touch):
/// - a `UIPanGestureRecognizer` for drags/swipes — its `translation(in:)` is in
///   well-defined points (this is what the app's original working scrubbing
///   used; raw indirect-touch `location` has an undefined scale), reported as
///   began/changed(tx,ty)/ended.
/// (Light taps are NOT captured — tvOS doesn't reliably surface a touch-only tap
/// to a recognizer, and a click already opens the controls.)
/// Gated by `isActive` so it never affects browsing UI.
struct RemoteTouchCatcher: UIViewRepresentable {
    let isActive: () -> Bool
    let onBegan: () -> Void
    let onMoved: (CGFloat, CGFloat) -> Void   // translation tx, ty (points)
    let onEnded: (CGFloat, CGFloat) -> Void    // final translation tx, ty

    func makeUIView(context: Context) -> TouchHostView {
        let view = TouchHostView()
        view.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
        return view
    }
    func updateUIView(_ uiView: TouchHostView, context: Context) {
        uiView.configure(isActive: isActive, onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }
    static func dismantleUIView(_ uiView: TouchHostView, coordinator: ()) {
        uiView.removeRecognizers()
    }
}

final class TouchHostView: UIView, UIGestureRecognizerDelegate {
    private var pan: UIPanGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    private var isActive: () -> Bool = { false }
    private var onBegan: () -> Void = {}
    private var onMoved: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

    func configure(isActive: @escaping () -> Bool, onBegan: @escaping () -> Void,
                   onMoved: @escaping (CGFloat, CGFloat) -> Void,
                   onEnded: @escaping (CGFloat, CGFloat) -> Void) {
        self.isActive = isActive
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizers()
        guard let window else { return }
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        p.cancelsTouchesInView = false
        p.delegate = self
        window.addGestureRecognizer(p)
        pan = p
        attachedWindow = window
    }

    func removeRecognizers() {
        if let attachedWindow, let pan {
            attachedWindow.removeGestureRecognizer(pan)
        }
        pan = nil; attachedWindow = nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard isActive() else { return }
        let t = g.translation(in: g.view)
        switch g.state {
        case .began: onBegan()
        case .changed: onMoved(t.x, t.y)
        case .ended, .cancelled, .failed: onEnded(t.x, t.y)
        default: break
        }
    }

    // Coexist with the focus engine's own recognizers (clicks/move commands).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { isActive() }
}

/// Captures Menu/Back presses at the WINDOW level so Back can never fall
/// through to the system (which dismisses the whole player). SwiftUI's
/// `onExitCommand` only fires when focus happens to sit inside the modifier's
/// hierarchy — a side panel mid-transition, or one with no focusable rows,
/// leaves focus nowhere and the press bypassed every handler. A window
/// recognizer sees the press regardless of focus.
struct RemoteMenuCatcher: UIViewRepresentable {
    let onMenu: () -> Void

    func makeUIView(context: Context) -> MenuHostView {
        let view = MenuHostView()
        view.onMenu = onMenu
        return view
    }

    func updateUIView(_ uiView: MenuHostView, context: Context) {
        uiView.onMenu = onMenu
    }

    static func dismantleUIView(_ uiView: MenuHostView, coordinator: ()) {
        uiView.removeRecognizer()
    }
}

final class MenuHostView: UIView, UIGestureRecognizerDelegate {
    var onMenu: () -> Void = {}

    private var recognizer: UITapGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizer()
        guard let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMenu))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
        attachedWindow = window
    }

    /// Every other recognizer (including UIKit's own menu handling) must wait
    /// for ours to fail — and ours never fails on a Menu press, so the
    /// system's "pop the presentation" behavior can never win the race.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func removeRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleMenu() {
        onMenu()
    }
}
