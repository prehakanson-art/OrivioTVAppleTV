import SwiftUI

/// The Apple TV theme's settings surface, styled like the tvOS Settings app:
/// a single centered column of rows — label left, value + chevron right —
/// grouped into glass section cards, with the white tvOS focus platter. Rows
/// push the SAME detail panes Classic's two-pane settings uses, so every
/// option stays available in both themes.
struct ATVSettingsView: View {
    @EnvironmentObject private var theme: ThemeManager
    /// Opens the "Who's watching?" profile gate (owned by the root view).
    var onOpenProfiles: () -> Void = {}

    /// Categories that get a plain pushed row, in tvOS-Settings-ish order.
    /// Appearance/Themes are handled by the dedicated section up top.
    private var generalCategories: [SettingsCategory] {
        let hidden: Set<SettingsCategory> = [.appearance, .account]
        return SettingsCategory.allCases.filter {
            !hidden.contains($0) && (theme.experienceMode.isAdvanced || !$0.isAdvanced)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                Text("Settings")
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(.top, NuvioSpacing.xl)

                ATVSettingsSection(title: "Appearance") {
                    NavigationLink(value: SettingsCategory.appearance) {
                        ATVRowLabel(title: "Appearance", value: theme.palette.displayName)
                    }
                    .buttonStyle(ATVRowButtonStyle())
                }

                ATVSettingsSection(title: "Users & Accounts") {
                    NavigationLink(value: SettingsCategory.account) {
                        ATVRowLabel(title: "Account")
                    }
                    .buttonStyle(ATVRowButtonStyle())

                    Button(action: onOpenProfiles) {
                        ATVRowLabel(title: "Switch Profile", showChevron: false)
                    }
                    .buttonStyle(ATVRowButtonStyle())
                }

                ATVSettingsSection(title: "General") {
                    ForEach(generalCategories) { category in
                        NavigationLink(value: category) {
                            ATVRowLabel(title: category.title)
                        }
                        .buttonStyle(ATVRowButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.bottom, NuvioSpacing.huge)
        }
        .background(ATVBackground())
        .navigationDestination(for: SettingsCategory.self) { pane(for: $0) }
    }


    /// Pushed detail pages reuse Classic's panes over the ATV backdrop.
    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        SettingsCategoryPane(category: category)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, NuvioSpacing.huge)
            .background(ATVBackground())
    }
}

/// A titled group of rows on one glass card (Liquid Glass on tvOS 26,
/// translucent material earlier) — the tvOS Settings section look.
private struct ATVSettingsSection<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 19, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.leading, NuvioSpacing.lg)
            VStack(spacing: 4) {
                content
            }
            .padding(NuvioSpacing.sm)
            .atvGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .focusSection()
    }
}

/// Row content: label left, value + chevron right. Colors flip to dark text
/// while the row is focused, because the focus platter is white.
private struct ATVRowLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var value: String? = nil
    var showChevron: Bool = true

    var body: some View {
        HStack(spacing: NuvioSpacing.md) {
            Text(title)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(isFocused ? Color(hex: 0x1C1C1E) : theme.palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: NuvioSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 27))
                    .foregroundStyle(isFocused ? Color(hex: 0x1C1C1E).opacity(0.6)
                                               : theme.palette.textSecondary)
                    .lineLimit(1)
            }
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isFocused ? Color(hex: 0x1C1C1E).opacity(0.45)
                                               : theme.palette.textTertiary)
            }
        }
        .padding(.horizontal, NuvioSpacing.xl)
        .frame(minHeight: 84)
        .frame(maxWidth: .infinity)
    }
}

/// tvOS-Settings focus treatment: the focused row rises on a white platter
/// with a soft shadow; idle rows are a whisper of fill so the section card
/// reads as one grouped list.
private struct ATVRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ATVRowChrome(configuration: configuration)
    }

    private struct ATVRowChrome: View {
        @EnvironmentObject private var theme: ThemeManager
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? Color.white
                              : (theme.atvIsLight ? Color.white.opacity(0.45)
                                                  : Color.white.opacity(0.05)))
                )
                .shadow(color: .black.opacity(isFocused ? 0.28 : 0),
                        radius: isFocused ? 18 : 0, y: 8)
                .focusLift(NuvioFocus.row, isFocused)
                .cardPressDip(configuration.isPressed)
        }
    }
}
