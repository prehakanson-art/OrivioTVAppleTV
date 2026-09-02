import SwiftUI
import UIKit

/// One entry in a hold-Select menu.
struct HoldAction: Identifiable {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void
    var id: String { title }
}

/// Detects a HELD Select press with a UIKit recogniser.
///
/// SwiftUI's `.contextMenu` is unreliable here — it refuses to present at all
/// if any item carries a destructive role, and it fights the native card
/// platter — so the hold is detected directly instead. A
/// `UILongPressGestureRecognizer` restricted to `.select` sits in the card's
/// own view hierarchy, where tvOS delivers presses along the focused view's
/// responder chain, and recognises alongside the button's own press handling
/// so an ordinary Select still activates the card.
struct HoldPressDetector: UIViewRepresentable {
    let onHold: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHold: onHold) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let recogniser = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handle(_:))
        )
        recogniser.minimumPressDuration = 0.5
        recogniser.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        // Touch types must be empty or the recogniser also waits on the
        // trackpad surface, which never "presses" on a Siri Remote.
        recogniser.allowedTouchTypes = []
        recogniser.delegate = context.coordinator
        view.addGestureRecognizer(recogniser)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHold = onHold
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onHold: () -> Void
        init(onHold: @escaping () -> Void) { self.onHold = onHold }

        @objc func handle(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onHold()
        }

        /// The card's own Select handling must keep working.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A card whose Select opens the title and whose HELD Select opens a menu.
///
/// `.contextMenu` proved unusable on tvOS 26: it refuses to present when any
/// item carries a destructive role, it interacts badly with the native card
/// platter, and its failures are silent. The hold is detected directly here
/// instead, by TWO independent means so a quirk in either still leaves a
/// working menu:
///
/// 1. `simultaneousGesture(LongPressGesture)` — SwiftUI's own long press.
///    `simultaneousGesture` (not `onLongPressGesture`) matters: it explicitly
///    lets the button keep its own press handling, so ordinary Select still
///    activates the card.
/// 2. A `UILongPressGestureRecognizer` limited to `.select`, in a BACKGROUND
///    view. Background rather than overlay so it can never intercept anything
///    in front of it — if tvOS doesn't route presses to it, it is simply
///    inert.
///
/// Whichever fires first shows the menu; `showMenu` makes the second a no-op.
/// The card keeps the native platter, so focus lift and sheen are unaffected.
struct HoldableCard<Label: View>: View {
    let actions: [HoldAction]
    /// Ordinary Select.
    let primary: () -> Void
    @ViewBuilder var label: Label
    /// Names the card in the menu, so it's clear what is being acted on.
    var menuTitle: String = ""
    /// False keeps the flat card style — episode stills use it, so adding a
    /// hold menu doesn't silently restyle them.
    var usesPlatter: Bool = true

    @State private var showMenu = false
    /// The hold already acted; swallow the release that follows so the card
    /// doesn't also open (tvOS delivers the button action on release).
    @State private var handledByHold = false

    var body: some View {
        Button {
            if handledByHold {
                handledByHold = false
                return
            }
            primary()
        } label: {
            label
        }
        .modifier(HoldCardStyle(usesPlatter: usesPlatter))
        .background(HoldPressDetector(onHold: triggerHold))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in triggerHold() }
        )
        .fullScreenCover(isPresented: $showMenu) {
            HoldMenuSheet(title: menuTitle, actions: actions) { showMenu = false }
        }
    }

    private func triggerHold() {
        guard !actions.isEmpty, !showMenu else { return }
        handledByHold = true
        showMenu = true
    }
}

/// Applies whichever card style the caller asked for.
private struct HoldCardStyle: ViewModifier {
    let usesPlatter: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesPlatter {
            content.mediaCardButtonStyle()
        } else {
            content.buttonStyle(PlainCardButtonStyle())
        }
    }
}

/// The menu: a glass panel of rows in the app's list language, with the same
/// bright focus platter the settings index uses.
struct HoldMenuSheet: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let actions: [HoldAction]
    let dismiss: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(2)
                        .padding(.horizontal, OrivioSpacing.lg)
                }

                VStack(spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                                .overlay(Color.white.opacity(0.10))
                                .padding(.leading, OrivioSpacing.xxl)
                        }
                        Button {
                            dismiss()
                            // Let the sheet finish dismissing before the action
                            // navigates or mutates the row underneath.
                            DispatchQueue.main.async { item.action() }
                        } label: {
                            HoldMenuRow(item: item)
                        }
                        .buttonStyle(HoldMenuRowStyle())
                        .focused($focused, equals: item.id)
                    }
                }
                .background(Color.clear.liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .frame(maxWidth: 820)
            .padding(OrivioSpacing.xl)
        }
        .onExitCommand(perform: dismiss)
        .onAppear { focused = actions.first?.id }
    }
}

private struct HoldMenuRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let item: HoldAction

    private var tint: Color {
        if isFocused { return item.isDestructive ? OrivioPrimitives.error : .black }
        return item.isDestructive ? OrivioPrimitives.error : theme.palette.textPrimary
    }

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            Image(systemName: item.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 34)
            Text(item.title)
                .font(.system(size: 27, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, OrivioSpacing.lg)
        .frame(height: 78)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoldMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? Color.white : Color.clear)
                )
                .cardPressDip(configuration.isPressed)
        }
    }
}
