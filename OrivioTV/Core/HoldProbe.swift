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
            let probe = HoldProbe.shared
            probe.events.append(Event(at: Date(), text: text))
            if probe.events.count > 12 { probe.events.removeFirst(probe.events.count - 12) }
        }
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
        if enabled {
            self
                .background(HoldPressProbe(label: label))
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in HoldProbe.log("longpress ≥0.5s (SwiftUI) — \(label)") }
                )
        } else {
            self
        }
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
