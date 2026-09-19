import SwiftUI

/// One option in a `OrivioDropdown`. `value` is the stable identity written back
/// on selection; `label` is what the user sees.
struct OrivioDropdownOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }
    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

/// A dropdown selector matching the APK's pickers: a focusable trigger card
/// showing the current value; pressing it opens a full-screen list of every
/// option (each focus-highlighted, the current one check-marked), and picking
/// one writes it back and closes. Fully Siri-remote driven — no hover/tap.
///
/// Two trigger looks:
/// - `triggerWidth != nil` → compact filter style (small label on top, big
///   value below, fixed width), used for Library Type/Sort.
/// - `triggerWidth == nil` → settings-row style: `[icon]` title (+ subtitle)
///   … value ▾, full width. Used for TMDB language, Playback rows, etc.
struct OrivioDropdown: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let selection: String
    let options: [OrivioDropdownOption]
    var triggerWidth: CGFloat? = nil
    let onSelect: (String) -> Void

    @State private var open = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? selection
    }

    var body: some View {
        Button { open = true } label: {
            DropdownTrigger(title: title, subtitle: subtitle, icon: icon, value: currentLabel, width: triggerWidth)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $open) {
            DropdownPicker(title: title, selection: selection, options: options,
                           onSelect: { onSelect($0); open = false },
                           onCancel: { open = false })
                .environmentObject(theme)
        }
    }
}

private struct DropdownTrigger: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var icon: String?
    let value: String
    var width: CGFloat?

    private var compact: Bool { width != nil }

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: OrivioSpacing.md) {
            if let icon, !compact {
                SettingsIconTile(symbol: icon)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                if compact {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(theme.palette.textTertiary)
                    Text(value)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                } else {
                    Text(title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: OrivioSpacing.sm)
            if !compact {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
                    .padding(.top, 2)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.top, compact ? 0 : 2)
        }
        .padding(.horizontal, compact ? OrivioSpacing.lg : OrivioSpacing.md)
        .padding(.vertical, compact ? 0 : OrivioSpacing.md)
        .frame(width: width, height: compact ? 84 : nil)
        .frame(minHeight: compact ? nil : 74)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(dropdownBackground)
        .overlay {
            if compact {
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 3)
            }
        }
        .shadow(color: compact && isFocused ? .black.opacity(0.35) : .clear,
                radius: compact && isFocused ? 18 : 0, y: 8)
        .focusLift(compact ? OrivioFocus.row : 1.0, isFocused)
    }

    // Compact (player panels / Discover / Library) keeps a solid pill fill so it
    // reads as a control on its own. In Settings the trigger is flat inside a
    // group card and only lights up on focus, matching the other rows.
    @ViewBuilder
    private var dropdownBackground: some View {
        if compact {
            // Liquid Glass in every state; focus is the bright ring + lift.
            Color.clear
                .liquidGlass(in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
        } else {
            SettingsRowBackground(isFocused: isFocused)
        }
    }
}

/// The full-screen option list. Initial focus lands on the current selection.
private struct DropdownPicker: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let selection: String
    let options: [OrivioDropdownOption]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: String?

    /// The band between the title and the first row that scrolled options
    /// dissolve into. Exactly the gap the title and the list used to be
    /// separated by, so nothing moves — the space is just painted now.
    private static let headerFade = OrivioSpacing.xl

    /// The title, with the stage painted solid behind it and fading out
    /// underneath.
    ///
    /// The list below is `scrollClipDisabled` — it has to be, or a focused
    /// row's ring and lift are cut off at the scroll view's edges — so its
    /// rows draw right out of the top of the list and across the title. They
    /// were doing it in front, and an option row is a 50%-opaque card, so the
    /// title stayed legible straight through the row riding over it. `zIndex`
    /// puts this in front instead, and the solid block gives the rows
    /// something to disappear behind rather than merely covering them.
    private var header: some View {
        Text(title)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(theme.palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Self.headerFade)
            .background(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Up past the top of the screen, not merely behind the
                    // title: the list overflows the WHOLE way up, so a block
                    // that stopped at the title's own line just left the rows
                    // above it on show. A background never affects the layout
                    // it is attached to, so the height only has to be "more
                    // than the title's distance from the top edge".
                    theme.palette.background
                        .frame(height: 1200)
                    LinearGradient(
                        colors: [theme.palette.background, theme.palette.background.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: Self.headerFade)
                }
            }
            // Siblings composite in order, so the list — declared after this —
            // would otherwise always win.
            .zIndex(1)
    }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            // `spacing: 0`: the gap that used to be here is now the header's
            // own bottom padding, which is what the fade is drawn over.
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: OrivioSpacing.sm) {
                        ForEach(options) { option in
                            Button { onSelect(option.value) } label: {
                                DropdownOptionRow(label: option.label, selected: option.value == selection)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focused, equals: option.value)
                        }
                    }
                    // Room for the focus ring + scale so rows aren't clipped
                    // at the scroll view's edges.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
                .frame(maxWidth: 800, maxHeight: 760)
            }
            .padding(OrivioSpacing.huge)
        }
        .onExitCommand { onCancel() }
        .onAppear { focused = selection }
    }
}

private struct DropdownOptionRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let label: String
    let selected: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.palette.secondary)
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : (selected ? theme.palette.secondary.opacity(0.5) : .clear),
                              lineWidth: isFocused ? 4 : 2)
        )
        .focusLift(OrivioFocus.row, isFocused)
    }
}
