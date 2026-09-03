import SwiftUI
import UIKit

/// Live on-screen tracing for the hold-Select menus.
///
/// Reasoning about this bug from the code has failed repeatedly, and the
/// simulator cannot deliver a held press at all, so this records what actually
/// happens on the device and shows it on screen. Enable it in
/// Settings → Performance → "Hold menu probe".
///
/// Four independent signals, so the failure can be located precisely:
///  • `focus`      — the card took focus (so the menu is attached to the right view)
///  • `press`      — a UIPress of type .select reached the card's view hierarchy
///  • `longpress`  — SwiftUI recognised a ≥0.5s hold on that card
///  • `MENU BUILT` — tvOS evaluated the menu's contents, which it only does when
///                   it is actually about to present the menu
///
/// If focus/press/longpress appear but MENU BUILT never does, tvOS is refusing
/// to present. If MENU BUILT appears and no menu is visible, it is presenting
/// off-screen or being dismissed. If nothing appears at all, the press is not
/// reaching the app.
@MainActor
final class HoldProbe: ObservableObject {
    static let shared = HoldProbe()

    struct Event: Identifiable {
        let id = UUID()
        let at: Date
        let text: String
    }

    @Published private(set) var events: [Event] = []
    private init() {}

    /// Safe to call from anywhere, including inside a ViewBuilder: the append
    /// is deferred so it never mutates state during a view update.
    nonisolated static func log(_ text: String) {
        Task { @MainActor in
            // Respect the setting. The console line used to be emitted
            // unconditionally, so every call site that forgot to guard kept
            // spamming the device log (and building its message string) with
            // the probe switched off.
            guard PerformanceSettingsStore.shared.settings.showHoldProbe else { return }
            // Also to the console, so the probe can be watched over a device
            // log stream and not only on the HUD.
            NSLog("[HoldProbe] %@", text)
            let probe = HoldProbe.shared
            probe.events.append(Event(at: Date(), text: text))
            if probe.events.count > 12 { probe.events.removeFirst(probe.events.count - 12) }
        }
    }

    /// Body-evaluation counter. Prints a per-second rate so a row that
    /// rebuilds under an in-flight hold is visible without any holding.
    private static let renderCounts = RenderCounter()
    @MainActor
    static func renderTick(_ label: String) {
        guard PerformanceSettingsStore.shared.settings.showHoldProbe else { return }
        renderCounts.tick(label)
    }

    func clear() { events.removeAll() }
}

/// Reports raw `.select` presses reaching a view's hierarchy, without
/// consuming them — purely an observer.
struct HoldPressProbe: UIViewRepresentable {
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(label: label) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let long = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handle(_:)))
        long.minimumPressDuration = 0.45
        long.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        long.allowedTouchTypes = []
        long.delegate = context.coordinator
        view.addGestureRecognizer(long)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.label = label }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var label: String
        init(label: String) { self.label = label }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: HoldProbe.log("press ≥0.45s (UIKit) — \(label)")
            default: break
            }
        }
        // Never interfere with the card's own handling.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}

/// Attaches every probe signal to a card.
extension View {
    @ViewBuilder
    func holdProbe(_ label: String, enabled: Bool) -> some View {
        // PASSIVE ON PURPOSE. The first version added a SwiftUI
        // LongPressGesture here; it fired on every hold, but on tvOS it
        // competes with the long-press .contextMenu uses internally, so the
        // probe could suppress the menu it was meant to observe. The UIKit
        // recognizer in HoldPressProbe never fired at all (a background
        // representable is not in the focused view's press chain), so nothing
        // is lost by dropping both. Focus logging and the MENU BUILT lines
        // inside each .contextMenu body remain.
        self
    }
}

/// Answers the only question that matters: does the focused card actually have
/// a UIContextMenuInteraction attached? `.contextMenu` compiles and its body
/// runs whether or not SwiftUI ends up installing the interaction, so the
/// source alone cannot tell a working card from a broken one. This reads the
/// live view hierarchy instead.
@MainActor
enum HoldInteractionTrace {
    private static var token: NSObjectProtocol?

    /// Is the probe still switched on? Read from the notification / gesture
    /// callbacks, which are nonisolated but always run on the main thread
    /// (`queue: .main`, and UIKit gesture actions).
    ///
    /// Belt and braces alongside `uninstall()`: even between the toggle going
    /// off and the uninstall landing, nothing should log.
    nonisolated static func isEnabled() -> Bool {
        MainActor.assumeIsolated { PerformanceSettingsStore.shared.settings.showHoldProbe }
    }

    static func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard isEnabled() else { return }
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                  let view = ctx.nextFocusedItem as? UIView else { return }
            var chain: [String] = []
            var found = "none"
            var node: UIView? = view
            var depth = 0
            while let v = node, depth < 10 {
                let menus = v.interactions.filter { $0 is UIContextMenuInteraction }
                chain.append("\(type(of: v))\(menus.isEmpty ? "" : "[MENU]")")
                if !menus.isEmpty, found == "none" { found = "depth \(depth) \(type(of: v))" }
                node = v.superview
                depth += 1
            }
            NSLog("[HoldTrace] contextMenuInteraction: %@ | chain: %@",
                  found, chain.joined(separator: " < "))
        }
        installWindowPressWatch()
    }

    /// Remove BOTH probes. `install()` had no counterpart, so switching "Hold
    /// menu probe" back off left a focus observer that walks ten superviews and
    /// NSLogs on EVERY focus move — plus a window-wide long-press recogniser —
    /// running for the rest of the session, on a device where focus moves are
    /// the hot path. Idempotent, like `install()`.
    static func uninstall() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            Self.token = nil
        }
        if let watch = pressWatch {
            watch.view?.removeGestureRecognizer(watch)
            pressWatch = nil
        }
        NSLog("[HoldTrace] uninstalled")
    }

    /// Observes Select presses at the WINDOW, so the card's own gesture is
    /// untouched: it never cancels touches, never delays them, and recognises
    /// simultaneously with everything. The earlier per-card probe was the
    /// opposite of this and could suppress the menu it measured.
    private static var pressWatch: UILongPressGestureRecognizer?
    private static let watchDelegate = SimultaneousDelegate()

    private static func installWindowPressWatch() {
        guard pressWatch == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
                ?? scenes.flatMap(\.windows).first else { return }
        let g = UILongPressGestureRecognizer(target: watchDelegate,
                                             action: #selector(SimultaneousDelegate.handle(_:)))
        g.minimumPressDuration = 0.05
        g.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        g.allowedTouchTypes = []
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = watchDelegate
        window.addGestureRecognizer(g)
        pressWatch = g
        NSLog("[HoldTrace] window press watch installed")
    }

    /// Walks the live hierarchy for views carrying a UIContextMenuInteraction
    /// and reports the focused view's frame. Distinguishes "SwiftUI never
    /// installed the interaction" from "installed but refusing to present" —
    /// the one thing the source cannot tell us.
    static func dumpMenuInteractions() {
        guard isEnabled() else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
                ?? scenes.flatMap(\.windows).first else { return }
        var frames: [String] = []
        func walk(_ v: UIView) {
            if v.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
                let f = v.convert(v.bounds, to: window)
                frames.append(String(format: "%@(%.0f,%.0f %.0fx%.0f)",
                                     "\(type(of: v))", f.origin.x, f.origin.y, f.width, f.height))
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        let focusedFrame: String
        if let f = UIFocusSystem.focusSystem(for: window)?.focusedItem {
            let r = f.frame
            focusedFrame = String(format: "(%.0f,%.0f %.0fx%.0f)",
                                  r.origin.x, r.origin.y, r.width, r.height)
        } else { focusedFrame = "nil" }
        NSLog("[MenuScan] views with contextMenuInteraction: %d | focused item frame: %@ | %@",
              frames.count, focusedFrame, frames.prefix(6).joined(separator: " "))
    }

    final class SimultaneousDelegate: NSObject, UIGestureRecognizerDelegate {
        @objc func handle(_ g: UILongPressGestureRecognizer) {
            // The recogniser is removed by `uninstall()`, but stay quiet even
            // if a press is already in flight when the setting goes off.
            guard HoldInteractionTrace.isEnabled() else { return }
            switch g.state {
            case .began:
                NSLog("[Press] HOLD BEGAN")
                HoldInteractionTrace.dumpMenuInteractions()
            case .ended:     NSLog("[Press] hold ended")
            case .cancelled: NSLog("[Press] hold CANCELLED (something took the gesture)")
            case .failed:    NSLog("[Press] hold failed")
            default: break
            }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf o: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool { false }
    }
}

/// The on-screen read-out.
struct HoldProbeHUD: View {
    @ObservedObject private var probe = HoldProbe.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HOLD PROBE")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.yellow)
            if probe.events.isEmpty {
                Text("hold Select on a card…")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(probe.events) { event in
                Text("\(Self.stamp(event.at))  \(event.text)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(event.text.contains("MENU BUILT") ? .green : .white)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 640, alignment: .leading)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(24)
        .allowsHitTesting(false)
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SS"
        return f.string(from: d)
    }
}


/// Thread-safe tally of view-body evaluations, flushed once a second.
final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var lastFlush = Date()

    func tick(_ label: String) {
        lock.lock()
        counts[label, default: 0] += 1
        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= 1.0 else { lock.unlock(); return }
        let snapshot = counts
        counts.removeAll()
        lastFlush = now
        lock.unlock()
        let cw = snapshot.filter { $0.key.hasPrefix("CW ") }.values.reduce(0, +)
        if cw > 0 { NSLog("[Rebuild] CW cells rebuilt: %d", cw) }
        let poster = snapshot.filter { $0.key.hasPrefix("poster ") }.values.reduce(0, +)
        NSLog("[RenderRate] CW bodies/s: %d | poster bodies/s: %d", cw, poster)
    }
}
