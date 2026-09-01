import SwiftUI

/// One option in a `NuvioDropdown`. `value` is the stable identity written back
/// on selection; `label` is what the user sees.
struct NuvioDropdownOption: Identifiable, Equatable {
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
struct NuvioDropdown: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let selection: String
    let options: [NuvioDropdownOption]
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
        HStack(alignment: compact ? .center : .top, spacing: NuvioSpacing.md) {
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
            Spacer(minLength: NuvioSpacing.sm)
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
        .padding(.horizontal, compact ? NuvioSpacing.lg : NuvioSpacing.md)
        .padding(.vertical, compact ? 0 : NuvioSpacing.md)
        .frame(width: width, height: compact ? 84 : nil)
        .frame(minHeight: compact ? nil : 74)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(dropdownBackground)
        .overlay {
            if compact {
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 3)
            }
        }
        .shadow(color: compact && isFocused ? .black.opacity(0.35) : .clear,
                radius: compact && isFocused ? 18 : 0, y: 8)
        .focusLift(compact ? NuvioFocus.row : 1.0, isFocused)
    }

    // Compact (player panels / Discover / Library) keeps a solid pill fill so it
    // reads as a control on its own. In Settings the trigger is flat inside a
    // group card and only lights up on focus, matching the other rows.
    @ViewBuilder
    private var dropdownBackground: some View {
        if compact {
            // Liquid Glass in every state; focus is the bright ring + lift.
            Color.clear
                .liquidGlass(in: RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
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
    let options: [NuvioDropdownOption]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(spacing: NuvioSpacing.xl) {
                Text(title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                ScrollView {
                    VStack(spacing: NuvioSpacing.sm) {
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
            .padding(NuvioSpacing.huge)
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
        .padding(.horizontal, NuvioSpacing.lg)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : (selected ? theme.palette.secondary.opacity(0.5) : .clear),
                              lineWidth: isFocused ? 4 : 2)
        )
        .focusLift(NuvioFocus.row, isFocused)
    }
}
