import SwiftUI

/// Settings categories shown in the left rail. Order, titles, icons and
/// subtitles match the Android app's `SettingsSectionSpec` list exactly.
/// (The APK's mode-gated Experience/Advanced/Debug sections aren't ported —
/// those are unbuilt features.) The APK folds add-ons, catalogs and
/// collections into one "Content & Discovery" section.
enum SettingsCategory: String, CaseIterable, Identifiable {
    // Matches the live APK rail (Essential mode): no Account/Profiles (those
    // live on the sidebar profile avatar). Only categories whose settings are
    // actually wired up are shown — no stub panes.
    case account, appearance, layout, contentDiscovery, integration, plugins, playback, performance, trakt, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .appearance: return "Appearance"
        case .layout: return "Layout"
        case .contentDiscovery: return "Content & Discovery"
        case .integration: return "Integrations"
        case .plugins: return "Plugins"
        case .playback: return "Playback"
        case .performance: return "Performance"
        case .trakt: return "Trakt & SIMKL"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Orivio account and profiles"
        case .appearance: return "Theme, accent color, and font"
        case .layout: return "Home structure and poster styles"
        case .contentDiscovery: return "Add-ons, catalogs, and collections"
        case .integration: return "Manage available integrations"
        case .plugins: return "Scraper repositories and plugins"
        case .playback: return "Auto-play and next-episode behavior"
        case .performance: return "Turn effects off for a faster UI on older Apple TVs"
        case .trakt: return "Scrobble and sync your watch history, or connect SIMKL"
        case .about: return "App information, updates, and legal links"
        }
    }

    // SF Symbols matched to the APK's Material icons.
    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .appearance: return "paintpalette.fill"
        case .layout: return "square.grid.2x2.fill"
        case .contentDiscovery: return "safari.fill"
        case .integration: return "link"
        case .plugins: return "puzzlepiece.extension.fill"
        case .playback: return "play.fill"
        case .performance: return "speedometer"
        case .trakt: return "checkmark.seal.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// Categories hidden from the rail in Essential experience mode.
    var isAdvanced: Bool { self == .plugins }

    /// Shorter label for the narrow rail (the detail header still uses `title`).
    var railTitle: String {
        switch self {
        case .contentDiscovery: return "Content"
        default: return title
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var account: OrivioAccountManager
    @EnvironmentObject private var trakt: TraktStore
    @FocusState private var railFocus: SettingsCategory?
    /// True while focus is inside the rail; used to tell the entry event apart
    /// from in-rail moves (entry snaps to `selected` instead of previewing).
    @State private var inRail = false

    // Dev: the settings demo opens on Layout (a content-rich, scrollable pane)
    // so the workspace card + grouped cards + fit can be screenshot-verified.
    @State private var selected: SettingsCategory = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-paneAccount") { return .account }
        if args.contains("-paneTrakt") { return .trakt }
        if args.contains("-paneLayout") { return .layout }
        if args.contains("-paneContent") { return .contentDiscovery }
        if args.contains("-paneIntegration") { return .integration }
        if args.contains("-panePlayback") { return .playback }
        if args.contains("-panePerformance") { return .performance }
        if args.contains("-paneAbout") { return .about }
        return .appearance
    }()

    // Matches the APK's default "Classic" settings: everything sits inside a
    // rounded "workspace" card (inset from the screen edges, faint border) with
    // a vertical rail of tall pill buttons on the LEFT and the detail pane on
    // the RIGHT. Focusing a rail pill live-previews its detail (as the APK
    // does); both regions are focus sections so Right enters the detail and
    // Left returns to the rail without locking up.
    /// Rail categories, minus advanced ones when Essential mode is on.
    private var visibleCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter { theme.experienceMode.isAdvanced || !$0.isAdvanced }
    }

    var body: some View {
        HStack(alignment: .top, spacing: OrivioSpacing.xl) {
            rail
            detail
                // Fill the pane instead of capping at 900 — the old cap left
                // the right ~40% empty and forced descriptions to truncate.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
        }
        // Essential mode may hide the category you're viewing — fall back.
        .onChange(of: theme.experienceMode) { _, _ in
            if !visibleCategories.contains(selected) { selected = .appearance }
        }
        .padding(OrivioSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The APK "workspace" card: rounded (28dp), BackgroundElevated fill,
        // hairline border, inset from the screen edges on near-black. Content is
        // CLIPPED to the card so scrolled detail rows never spill outside it.
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(OrivioPrimitives.neutral750, lineWidth: 1)
        )
        .padding(.horizontal, OrivioSpacing.xxl)
        .padding(.vertical, OrivioSpacing.xl)
        .background(ATVBackground())
    }

    // MARK: - Vertical rail (Classic — tall pills)

    private var rail: some View {
        // 220dp rail, pills vertically centered (matches the APK's
        // spacedBy(10, CenterVertically)). 10 categories fit at 56dp each.
        VStack(spacing: OrivioSpacing.sm) {
            ForEach(visibleCategories) { category in
                Button {
                    selected = category
                } label: {
                    SettingsRailButton(category: category, selected: selected == category)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($railFocus, equals: category)
                // Live-preview: focusing a pill shows its detail (APK behavior)
                // — EXCEPT on the entry event. tvOS enters the rail at the
                // geometrically nearest pill; snapping back to `selected` there
                // keeps the pane you were on. Later moves preview normally.
                .onFocusChange { focused in
                    guard focused else { return }
                    if inRail {
                        selected = category
                    } else {
                        inRail = true
                        if category != selected { railFocus = selected }
                    }
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .center)
        .focusSection()
        // Entering the rail lands on the pane you're viewing, not a stale row.
        .defaultFocus($railFocus, selected)
        .onChange(of: railFocus) { _, newValue in
            if newValue == nil { inRail = false }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        SettingsCategoryPane(category: selected)
    }
}

/// The detail pane for one settings category.
///
/// Every settings shell renders the SAME panes — Classic's two-pane rail, the
/// Apple TV list, Stremio, Max and Hulu. This is the single switch they all go
/// through, so adding or retiring a category is one edit, not five (each shell
/// keeps its own chrome around this).
struct SettingsCategoryPane: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .account:           AccountSettingsDetail()
        case .appearance:        AppearanceDetail()
        case .layout:            LayoutSettingsDetail()
        case .contentDiscovery:  ContentDiscoveryDetail()
        case .integration:       IntegrationsDetail()
        case .plugins:           PluginsSettingsDetail()
        case .playback:          PlaybackSettingsDetail()
        case .performance:       PerformanceSettingsDetail()
        case .trakt:             TraktDetail()
        case .about:             AboutDetail()
        }
    }
}

// MARK: - Rail button (Classic — icon + title + chevron, pill highlight)

private struct SettingsRailButton: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let category: SettingsCategory
    let selected: Bool

    private var active: Bool { isFocused || selected }

    // Selected pill = solid accent fill with dark text (a real "you are here"
    // marker); focused-but-not-selected = accent ring on a faint fill; idle =
    // fully transparent so the rail reads as a clean list, not a stack of boxes.
    private var textColor: Color {
        if selected { return theme.palette.onSecondary }
        return isFocused ? theme.palette.textPrimary : theme.palette.textSecondary
    }

    var body: some View {
        HStack(spacing: OrivioSpacing.sm) {
            Image(systemName: category.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 24)
            Text(category.railTitle)
                .font(.system(size: 21, weight: active ? .bold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: OrivioSpacing.xs)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    selected ? theme.palette.secondary
                    : (isFocused ? theme.palette.backgroundCard.opacity(0.6) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isFocused && !selected ? theme.palette.focusRing : .clear,
                    lineWidth: 3
                )
        )
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
        .animation(perf.motion(FusionMotion.focusMove), value: selected)
    }
}

// MARK: - Detail scaffolding

/// A rounded, accent-tinted tile holding an SF Symbol. Gives every settings row
/// a consistent, scannable icon "chip" (iOS-Settings style) — the core visual
/// motif of the redesigned panes.
struct SettingsIconTile: View {
    @EnvironmentObject private var theme: ThemeManager
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [theme.palette.secondary.opacity(0.32), theme.palette.secondary.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(theme.palette.secondary.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsDetailHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: OrivioSpacing.md) {
                // Accent spine — a bold vertical bar that anchors the title and
                // sets the new, more editorial header rhythm.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.palette.secondary)
                    .frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 21))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped settings section rendered as a rounded card (title + optional
/// subtitle + rows), matching the APK's `secondaryCardRadius` (18dp) groups.
struct SettingsGroupCard<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            // Section label sits ABOVE the card (grouped-list style) — the
            // accent-tinted, letter-spaced title reads as a real section break
            // instead of another boxed header stacked inside the card.
            if !title.isEmpty || (subtitle?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title.uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(theme.palette.secondary)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 19))
                            .foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            }
            // The rows live in one shared surface; each row is flat until
            // focused, so the card groups them like a single list.
            VStack(spacing: 4) {
                content
            }
            .padding(OrivioSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                    .fill(theme.palette.backgroundCard.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                    // Hairline reads mid-grey on dark; in ATV light mode that
                    // same grey is a heavy outline — use a soft dark line.
                    .strokeBorder(scheme == .light ? Color.black.opacity(0.10)
                                  : OrivioPrimitives.neutral750.opacity(0.55), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable settings row with strong focus, matching the Android SettingsActionRow.
struct SettingsActionRow: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var value: String?
    var leadingIcon: String?

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            if let leadingIcon {
                SettingsIconTile(symbol: leadingIcon)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: OrivioSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textSecondary : theme.palette.textTertiary)
        }
        .padding(.horizontal, OrivioSpacing.md)
        .padding(.vertical, OrivioSpacing.md)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        // Was a spring, so one row type bounced while the value row directly
        // beneath it eased. One focus response for the whole app.
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

/// Shared row backdrop for the redesigned settings: transparent when idle so
/// rows read as one grouped list, and an accent-tinted, ringed highlight when
/// focused. No per-row scale — the fill/ring alone carries focus.
struct SettingsRowBackground: View {
    @EnvironmentObject private var theme: ThemeManager
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
            .fill(isFocused ? theme.palette.focusBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
    }
}

struct DetailScaffold<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                SettingsDetailHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, OrivioSpacing.xs)
                content
            }
            .padding(.horizontal, OrivioSpacing.xl)
            .padding(.top, OrivioSpacing.lg)
            .padding(.bottom, OrivioSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Clips scrolled content to the pane so rows stay inside the workspace card.
    }
}

// MARK: - Appearance detail

/// Settings → Appearance: every "how the app looks" control in one pane —
/// the app theme, the accent palette, AMOLED, font, the independent
/// detail/profile/player look axes, and how much of settings to expose.
/// (Was split across an Appearance and a Themes pane; they were the same
/// subject and the rail listed them twice.)
struct AppearanceDetail: View {
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        DetailScaffold(title: SettingsCategory.appearance.title, subtitle: SettingsCategory.appearance.subtitle) {
            SettingsGroupCard(title: "Accent Color", subtitle: "The highlight color used across the app") {
                ScrollView(.horizontal) {
                    HStack(spacing: OrivioSpacing.md) {
                        ForEach(OrivioThemes.all) { palette in
                            Button { theme.setPalette(palette) } label: {
                                ColorSwatchCard(palette: palette, selected: theme.palette.id == palette.id)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    // Breathing room for the focus ring; the scroll stays
                    // CLIPPED so swatches don't ride over the rest of the pane.
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }

                SettingsToggleCard(
                    title: "Black Background",
                    subtitle: "Pure black stage that keeps your accent glow",
                    isOn: Binding(get: { theme.amoled }, set: { theme.amoled = $0 })
                )
            }

            SettingsGroupCard(title: "Font", subtitle: "Typeface used across the app") {
                HStack(spacing: OrivioSpacing.md) {
                    ForEach(AppFont.allCases) { font in
                        Button { theme.font = font } label: {
                            SelectableChip(title: font.displayName, selected: theme.font == font)
                                .fontDesign(font.design)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
            }

            SettingsGroupCard(title: "Experience Mode", subtitle: theme.experienceMode.summary) {
                HStack(spacing: OrivioSpacing.md) {
                    ForEach(ExperienceMode.allCases) { mode in
                        Button { theme.experienceMode = mode } label: {
                            SelectableChip(title: mode.displayName, selected: theme.experienceMode == mode)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
                Text("Essential hides the Plugins section and the advanced Playback cards (auto-play source, player engine, on-screen display and audio).")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            SettingsGroupCard(title: "Settings Style", subtitle: theme.settingsUiStyle.summary) {
                HStack(spacing: OrivioSpacing.md) {
                    ForEach(SettingsUiStyle.allCases) { style in
                        Button { theme.settingsUiStyle = style } label: {
                            SelectableChip(title: style.displayName, selected: theme.settingsUiStyle == style)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
                Text("Reshapes settings cards and rows — Classic rounded, Zen pill, Horizon squared.")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

}

/// Reusable focus-aware selection chip (accent fill on focus, readable in
/// every state) — used by the theme font picker and other inline selectors.
struct SelectableChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary : (selected ? theme.palette.textPrimary : theme.palette.textSecondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, OrivioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .fill(isFocused ? theme.palette.secondary
                          : (selected ? theme.palette.secondary.opacity(0.28) : theme.palette.backgroundCard.opacity(0.85)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : (selected ? theme.palette.secondary : .clear),
                                  lineWidth: isFocused ? 4 : 2)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }
}

/// A colored accent swatch card (circle + name, check when selected) for the
/// horizontal Color Theme row.
private struct ColorSwatchCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let palette: ThemePalette
    let selected: Bool

    var body: some View {
        VStack(spacing: OrivioSpacing.sm) {
            ZStack {
                Circle().fill(palette.secondary).frame(width: 60, height: 60)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(palette.onSecondary)
                }
            }
            Text(palette.displayName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
        }
        .frame(width: 150, height: 130)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.background.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing
                              : (selected ? theme.palette.secondary : .clear), lineWidth: isFocused ? 4 : 2)
        )
    }
}

/// A pill switch matching the APK's toggle (dark when off, accent when on,
/// with a sliding white knob).
struct OrivioSwitch: View {
    @EnvironmentObject private var theme: ThemeManager
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                // `.primary` == white under Classic's forced-dark scheme;
                // flips to a visible dark track in ATV light mode.
                .fill(isOn ? theme.palette.secondary : Color.primary.opacity(0.18))
                .frame(width: 64, height: 36)
            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .padding(4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
    }
}

/// A toggle row rendered as a focusable card (title + subtitle + pill switch),
/// matching the APK's toggle rows.
struct SettingsToggleCard: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ToggleCardLabel(title: title, subtitle: subtitle, isOn: isOn)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct ToggleCardLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: OrivioSpacing.lg) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 18))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            OrivioSwitch(isOn: isOn)
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .frame(minHeight: 68)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
        )
    }
}

/// A navigation-style row with a trailing value + chevron. Focus = brighter
/// fill + thick accent ring so the selected row is always unmistakable.
struct SettingsValueCard: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String
    let value: String
    var icon: String = "puzzlepiece.extension.fill"

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            SettingsIconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle).font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: OrivioSpacing.lg)
            Text(value).font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.palette.secondary)
            Image(systemName: "chevron.right").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textSecondary : theme.palette.textTertiary)
        }
        .padding(.horizontal, OrivioSpacing.md)
        .padding(.vertical, OrivioSpacing.md)
        .frame(minHeight: 72)
        .background(SettingsRowBackground(isFocused: isFocused))
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

// MARK: - Add-ons detail

/// Settings → Account: Orivio account sign-in/status + Manage Profiles. Both
/// were moved here from the "Who's watching" gate so account and profile
/// management live in Settings.
struct AccountSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: OrivioAccountManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var stremio: StremioAccountStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var watchedStore: WatchedStore
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var plugins: PluginStore
    @State private var showAccount = false
    @State private var showProfiles = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.account.title, subtitle: SettingsCategory.account.subtitle) {
            SettingsGroupCard(title: "") {
                Button { showAccount = true } label: {
                    SettingsValueCard(
                        title: "Accounts",
                        subtitle: account.authState.isSignedIn
                            ? "Manage Orivio, Stremio, sync status and backups"
                            : "Sign in to Orivio, Stremio, or both",
                        value: accountStatus
                    )
                }
                .buttonStyle(PlainCardButtonStyle())

                Button { showProfiles = true } label: {
                    SettingsActionRow(
                        title: "Manage Profiles",
                        subtitle: "Add, rename, recolor, PIN-lock and remove profiles",
                        value: "\(profiles.profiles.count)",
                        leadingIcon: "person.2.fill"
                    )
                }
                .buttonStyle(PlainCardButtonStyle())

            }
        }
        .fullScreenCover(isPresented: $showAccount) {
            ZStack {
                ATVBackground()
                AccountView()
            }
            .environmentObject(theme)
            .environmentObject(account)
            .environmentObject(profiles)
            .environmentObject(addonManager)
            .environmentObject(library)
            .environmentObject(progressStore)
            .environmentObject(watchedStore)
            .environmentObject(stremio)
            .environmentObject(trakt)
            .environmentObject(debrid)
            .environmentObject(plugins)
            .onExitCommand { showAccount = false }
        }
        .fullScreenCover(isPresented: $showProfiles) {
            ProfileManageView { showProfiles = false }
                .environmentObject(theme)
                .environmentObject(profiles)
                .environmentObject(addonManager)
        }
    }

    private var accountStatus: String {
        switch account.authState {
        case .signedIn(_, let email): return email.isEmpty ? "Orivio connected" : email
        case .loading: return "..."
        case .signedOut:
            return stremio.isSignedIn ? (stremio.email ?? "Stremio connected") : ""
        }
    }
}

/// Content & Discovery — the APK folds add-ons, catalogs and collections into
/// one section, so this pane hosts add-on management plus a Collections entry.
/// Content & Discovery pane: a single "Addons" drill-in row (APK behavior).
struct ContentDiscoveryDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @ObservedObject private var liveTV = LiveTVSettingsStore.shared
    @State private var showAddons = false
    @State private var badgeURLInput = ""
    @State private var badgeImporting = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.contentDiscovery.title, subtitle: SettingsCategory.contentDiscovery.subtitle) {
            SettingsGroupCard(title: "") {
                Button { showAddons = true } label: {
                    SettingsValueCard(
                        title: "Addons",
                        subtitle: "Manage add-ons, catalog order, and collections",
                        value: "\(addonManager.addons.count)"
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
            }
            SettingsGroupCard(title: "Catalogs") {
                OrivioDropdown(
                    title: "Auto-refresh",
                    subtitle: "Re-fetch Home catalogs on a timer while the app is open, so new releases appear without relaunching",
                    icon: "arrow.triangle.2.circlepath",
                    selection: String(homeCatalogSettings.autoRefreshMinutes),
                    options: [
                        OrivioDropdownOption("0", "Off"),
                        OrivioDropdownOption("15", "Every 15 minutes"),
                        OrivioDropdownOption("30", "Every 30 minutes"),
                        OrivioDropdownOption("60", "Every hour")
                    ]
                ) { homeCatalogSettings.autoRefreshMinutes = Int($0) ?? 0 }
            }
            SettingsGroupCard(title: "Live TV", subtitle: "The Live TV tab, and which channels its built-in IPTV list shows") {
                SettingsToggleCard(
                    title: "Live TV tab",
                    subtitle: "Show the Live TV tab in the sidebar. Off: it's hidden until you turn this back on.",
                    isOn: $liveTV.enabled
                )

                if liveTV.enabled {
                    OrivioDropdown(
                        title: "Location",
                        subtitle: "Load channels for this country. All countries = the full global list.",
                        icon: "globe",
                        selection: liveTV.countryCode,
                        options: LiveTVSettingsStore.countries.map { OrivioDropdownOption($0.code, $0.name) }
                    ) { liveTV.countryCode = $0 }

                    OrivioDropdown(
                        title: "Preferred language",
                        subtitle: "Only show channels in this language, wherever they're from. Location is used only when no language is set.",
                        icon: "character.bubble",
                        selection: liveTV.languageCode,
                        options: LiveTVSettingsStore.languages.map { OrivioDropdownOption($0.code, $0.name) }
                    ) { liveTV.languageCode = $0 }
                }
            }
            SettingsGroupCard(title: "Badges", subtitle: "Badge packs from Badger (nintle.github.io/Badger) shown on source rows") {
                badgeControls
            }
        }
        .fullScreenCover(isPresented: $showAddons) {
            ZStack {
                ATVBackground()
                AddonsManagementView()
            }
            .environmentObject(theme)
            .environmentObject(addonManager)
            .environmentObject(collections)
            .environmentObject(homeCatalogSettings)
            .onExitCommand { showAddons = false }
        }
    }

    /// Badger badge-pack import: paste a config URL (from the Badger editor's
    /// export / a community template), fetch + validate, show the live state,
    /// and allow removal. The chips then appear on Sources-page rows.
    @ViewBuilder
    private var badgeControls: some View {
        if streamBadges.isConfigured {
            HStack(spacing: OrivioSpacing.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.palette.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streamBadges.filterCount) badge filters active")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(streamBadges.sourceURL)
                        .font(.system(size: 17))
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Sync from Account") {
                    Task { await streamBadges.syncFromAccount() }
                }
                .font(.system(size: 22, weight: .semibold))
                Button("Remove") { streamBadges.removeConfig() }
                    .font(.system(size: 22, weight: .semibold))
            }
            .padding(.vertical, 4)
            badgeExtraControls
            if let status = streamBadges.lastStatus {
                Text(status)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        } else {
            HStack(spacing: OrivioSpacing.md) {
                TextField("Badge config URL or Pastebin link", text: $badgeURLInput)
                    .font(.system(size: 22))
                Button {
                    guard !badgeImporting, !badgeURLInput.isEmpty else { return }
                    badgeImporting = true
                    Task {
                        await streamBadges.importConfig(from: badgeURLInput)
                        badgeImporting = false
                        if streamBadges.isConfigured { badgeURLInput = "" }
                    }
                } label: {
                    if badgeImporting {
                        ProgressView()
                    } else {
                        Text("Import")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
            }
            Button("Sync from Account") {
                Task { await streamBadges.syncFromAccount() }
            }
            .font(.system(size: 22, weight: .semibold))

            badgeExtraControls
            if let status = streamBadges.lastStatus {
                Text(status)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Text("Build or pick a badge pack at nintle.github.io/Badger, host the JSON (the editor gives you a link), and paste its URL here — or pull the pack already set up in another Orivio app with Sync from Account.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    /// Size + profile pickers, shown in BOTH the configured and empty states.
    @ViewBuilder
    private var badgeExtraControls: some View {
        OrivioDropdown(
            title: "Badge size",
            icon: "textformat.size",
            selection: streamBadges.sizeRawUI,
            options: StreamBadgeStore.sizeOptions.map { OrivioDropdownOption($0.0, $0.1) }
        ) { streamBadges.setSize($0) }

        // Only when the account carries badge configs from 2+ Orivio apps —
        // run Sync from Account once to discover them.
        if !streamBadges.remoteProfiles.isEmpty {
            OrivioDropdown(
                title: "Badge profile",
                icon: "person.2",
                selection: streamBadges.preferredRemoteProfileID.isEmpty
                    ? streamBadges.remoteProfiles[0].id
                    : streamBadges.preferredRemoteProfileID,
                options: streamBadges.remoteProfiles.map { OrivioDropdownOption($0.id, $0.label) }
            ) { id in
                streamBadges.preferredRemoteProfileID = id
                streamBadges.applyChosenRemoteProfile()
            }
        }
    }
}

/// Full add-ons management screen, opened from Content & Discovery. Structured
/// to mirror the APK's Add-ons screen: Install card → Catalog Order → Collections
/// → Refresh → Installed Add-ons list (with per-addon on/off, reorder, remove).
private struct AddonsManagementView: View {
    @State private var showPhoneAdd = false
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore

    @State private var newAddonURL = ""
    @State private var installing = false
    @State private var installMessage: String?
    @State private var showCollections = false
    @State private var showDiscover = false
    @State private var showCommunityCollections = false
    @State private var refreshing = false
    @State private var showExport = false
    @State private var showImport = false
    @State private var showHealth = false
    @State private var pendingRemoval: InstalledAddon?

    private static let refreshIdle = "Two-way sync with your account — uploads your changes, pulls others' and removes add-ons deleted elsewhere"
    @State private var refreshSubtitle = AddonsManagementView.refreshIdle

    var body: some View {
        DetailScaffold(title: "Add-ons", subtitle: "Manage add-ons, catalog order, and collections") {
            // Install Add-on
            SettingsGroupCard(title: "Install Add-on", subtitle: "Install add-ons by manifest URL") {
                HStack(spacing: OrivioSpacing.md) {
                    TextField("https://.../manifest.json", text: $newAddonURL)
                        .font(.system(size: 23))
                        .padding(.horizontal, OrivioSpacing.lg)
                        .padding(.vertical, OrivioSpacing.md)
                        .background(theme.palette.field, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
                        .frame(maxWidth: 640)
                    Button { install() } label: {
                        if installing {
                            ProgressView().tint(theme.palette.onSecondary)
                        } else {
                            Text("Install").font(.system(size: 23, weight: .semibold))
                        }
                    }
                    // Not disabled while installing: that disables the button
                    // you just pressed and drops focus to an arbitrary row.
                    // install() guards re-entry.
                    .disabled(newAddonURL.isEmpty)
                }

                if let installMessage {
                    Text(installMessage)
                        .font(.system(size: 20))
                        .foregroundStyle(installMessage.hasPrefix("Installed") ? OrivioPrimitives.success : OrivioPrimitives.error)
                }
            }

            // Discover: curated one-tap-install directory.
            Button { showDiscover = true } label: {
                SettingsActionRow(
                    title: "Discover Add-ons",
                    subtitle: "Browse and install popular add-ons — streams, catalogs, metadata and subtitles",
                    leadingIcon: "sparkle.magnifyingglass"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // Collections
            Button { showCollections = true } label: {
                SettingsActionRow(
                    title: "Collections",
                    subtitle: "Group catalogs into custom home rows",
                    value: collections.collections.isEmpty ? nil : "\(collections.collections.count)",
                    leadingIcon: "rectangle.stack.fill"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // Community Collections — curated, HQ, one-tap-install collections
            // (major streaming services / studios) that need zero setup.
            Button { showCommunityCollections = true } label: {
                SettingsActionRow(
                    title: "Community Collections",
                    subtitle: "One-tap streaming-service and studio collections — install and go",
                    leadingIcon: "square.stack.3d.up.fill"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // Sync Add-ons (two-way)
            Button { refresh() } label: {
                SettingsActionRow(
                    title: "Sync Add-ons",
                    subtitle: refreshSubtitle,
                    value: refreshing ? "…" : nil,
                    leadingIcon: "arrow.clockwise"
                )
            }
            .buttonStyle(PlainCardButtonStyle())
            .disabled(refreshing)

            Button { showHealth = true } label: {
                SettingsActionRow(
                    title: "Add-on Health",
                    subtitle: "Measure manifest response time and find slow or dead providers",
                    leadingIcon: "waveform.path.ecg"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // Export Setup: QR with every installed manifest URL — scan with a
            // phone to keep your addon list for a fresh install.
            Button { showPhoneAdd = true } label: {
                SettingsActionRow(
                    title: "Add Add-ons",
                    subtitle: "Show a QR code that opens a page on your phone — paste manifest URLs there and they install here",
                    leadingIcon: "qrcode"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            Button { showExport = true } label: {
                SettingsActionRow(
                    title: "Export Add-on Setup",
                    subtitle: "Show a QR code containing every installed manifest URL",
                    leadingIcon: "qrcode"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            Button { showImport = true } label: {
                SettingsActionRow(
                    title: "Import Add-on Setup",
                    subtitle: "Paste exported manifest URLs to restore a setup",
                    leadingIcon: "square.and.arrow.down"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // Installed Add-ons
            SettingsGroupCard(title: "Installed Add-ons") {
                if addonManager.addons.isEmpty {
                    Text("No add-ons installed yet.")
                        .font(.system(size: 21))
                        .foregroundStyle(theme.palette.textSecondary)
                } else {
                    ForEach(Array(addonManager.addons.enumerated()), id: \.element.id) { index, addon in
                        AddonRowView(
                            addon: addon,
                            canMoveUp: index > 0,
                            canMoveDown: index < addonManager.addons.count - 1,
                            onMoveUp: { addonManager.moveUp(addon) },
                            onMoveDown: { addonManager.moveDown(addon) },
                            onToggle: { addonManager.setEnabled(addon, !addon.enabled) },
                            onRemove: { pendingRemoval = addon }
                        )
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCollections) {
            CollectionsCoverView { showCollections = false }
                .environmentObject(theme)
                .environmentObject(collections)
                .environmentObject(addonManager)
        }
        .fullScreenCover(isPresented: $showCommunityCollections) {
            CommunityCollectionsView { showCommunityCollections = false }
                .environmentObject(theme)
                .environmentObject(collections)
        }
        .fullScreenCover(isPresented: $showDiscover) {
            AddonDiscoverView { showDiscover = false }
                .environmentObject(theme)
                .environmentObject(addonManager)
        }
        .alert("Remove Add-on?",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { addon in
            Button("Remove", role: .destructive) {
                addonManager.remove(addon)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { addon in
            Text("\"\(addon.manifest.name)\" will be removed from this device and your account. You can add it back later with its manifest URL.")
        }
        .fullScreenCover(isPresented: $showPhoneAdd) {
            AddonPhoneAddView(addonManager: addonManager) { showPhoneAdd = false }
                .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showExport) {
            AddonExportView(
                urls: addonManager.addons.map(\.manifestURL),
                onDone: { showExport = false }
            )
            .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showImport) {
            AddonImportView(onDone: { showImport = false })
                .environmentObject(theme)
                .environmentObject(addonManager)
        }
        .fullScreenCover(isPresented: $showHealth) {
            AddonHealthView(onDone: { showHealth = false })
                .environmentObject(theme)
                .environmentObject(addonManager)
        }
    }

    private func install() {
        guard !installing else { return }
        installing = true
        installMessage = nil
        let url = newAddonURL
        Task {
            do {
                try await addonManager.install(manifestURL: url)
                installMessage = "Installed successfully"
                newAddonURL = ""
            } catch {
                installMessage = "Install failed: \(error.localizedDescription)"
            }
            installing = false
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            // Report what ACTUALLY happened. This used to say "Add-ons
            // refreshed just now" unconditionally, including when the account
            // pull had failed or been skipped entirely.
            let outcome = await addonManager.syncWithAccount()
            refreshing = false
            refreshSubtitle = outcome.message
            // Leave a failure on screen longer than a success — it's the one
            // the user needs to read.
            let linger: UInt64 = { if case .failed = outcome { return 10 } else { return 4 } }()
            try? await Task.sleep(nanoseconds: linger * 1_000_000_000)
            refreshSubtitle = Self.refreshIdle
        }
    }
}

/// Full-screen Collections manager, opened from Content & Discovery. Menu/Back
/// closes it back to the settings pane.
private struct CollectionsCoverView: View {
    @EnvironmentObject private var theme: ThemeManager
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            CollectionsSettingsDetail()
                .padding(.horizontal, OrivioSpacing.xxl)
                .padding(.vertical, OrivioSpacing.xl)
        }
        .onExitCommand { onDone() }
    }
}

private struct AddonRowView: View {
    @EnvironmentObject private var theme: ThemeManager
    let addon: InstalledAddon
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onToggle: () -> Void = {}
    let onRemove: () -> Void

    private var isCinemeta: Bool { addon.manifestURL == AddonManager.cinemetaURL }

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            // On/off toggle (APK's per-addon switch).
            Button(action: onToggle) { AddonToggle(isOn: addon.enabled) }
                .buttonStyle(PlainCardButtonStyle())

            VStack(alignment: .leading, spacing: 3) {
                Text(addon.manifest.name)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                HStack(spacing: OrivioSpacing.sm) {
                    if let version = addon.manifest.version {
                        Text("v\(version)").font(.system(size: 18)).foregroundStyle(theme.palette.textTertiary)
                    }
                    if addon.manifest.providesCatalogs { capability("Catalogs") }
                    if addon.manifest.providesStreams { capability("Streams") }
                    if addon.manifest.providesMeta { capability("Meta") }
                }
            }
            // Dim the info when the addon is off.
            .opacity(addon.enabled ? 1 : 0.45)

            Spacer()

            // Reorder controls (dimmed + non-focusable at the ends).
            // Dimmed at the ends but never `.disabled`: moving an add-on to
            // the top disabled the chevron you were standing on and dropped
            // focus. The actions no-op at the bounds instead.
            RowActionCircle(icon: "chevron.up", action: { if canMoveUp { onMoveUp() } })
                .opacity(canMoveUp ? 1 : 0.3)
            RowActionCircle(icon: "chevron.down", action: { if canMoveDown { onMoveDown() } })
                .opacity(canMoveDown ? 1 : 0.3)

            // Cinemeta is the bundled meta provider and can't be removed.
            if !isCinemeta {
                Button(action: onRemove) { TrashCircle() }
                    .buttonStyle(PlainCardButtonStyle())
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.sm)
        .frame(minHeight: 84)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(theme.palette.backgroundCard.opacity(0.5))
        )
    }

    private func capability(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.palette.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(theme.palette.secondary.opacity(0.15), in: Capsule())
    }
}

/// The addon on/off switch, with a focus ring so it reads as selectable.
private struct AddonToggle: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let isOn: Bool

    var body: some View {
        OrivioSwitch(isOn: isOn)
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .focusLift(OrivioFocus.control, isFocused)
    }
}

/// A round reorder button (up/down chevron) for addon rows.
private struct RowActionCircle: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { RowActionCircleLabel(icon: icon) }
            .buttonStyle(PlainCardButtonStyle())
    }
}

private struct RowActionCircleLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.textPrimary)
            .frame(width: 60, height: 60)
            .background(Circle().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.12)))
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.control, isFocused)
    }
}

/// Readable, clearly-focusable delete control for addon rows: a red trash
/// circle that fills solid red with a ring on focus.
private struct TrashCircle: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isFocused ? .white : OrivioPrimitives.red300)
            .frame(width: 64, height: 64)
            .background(Circle().fill(isFocused ? OrivioPrimitives.red500 : OrivioPrimitives.red500.opacity(0.18)))
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.control, isFocused)
    }
}

// MARK: - About detail

struct AboutDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @State private var info: AboutInfo?
    // Starts empty and is filled by .task below. The default value used to be
    // `DiagnosticsService.cacheSizeLabel()`, which walks the whole cache
    // directory synchronously on the main thread — and a @State default is
    // evaluated every time the view struct is built, not once, so opening
    // About (and every redraw of it) stuttered.
    @State private var cacheLabel = "…"
    @State private var clearing = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.about.title, subtitle: SettingsCategory.about.subtitle) {
            SettingsGroupCard(title: "") {
                VStack(spacing: OrivioSpacing.sm) {
                    HStack(spacing: OrivioSpacing.sm) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.palette.secondary)
                        Text("ORIVIO")
                            .font(.system(size: 40, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                    }
                    Text("Version \(DiagnosticsService.appVersion)")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, OrivioSpacing.md)

                Button { info = .privacy } label: {
                    SettingsValueCard(title: "Privacy Policy", subtitle: "View our privacy policy", value: "", icon: "hand.raised.fill")
                }.buttonStyle(PlainCardButtonStyle())
                Button { info = .licenses } label: {
                    SettingsValueCard(title: "Licenses & Attributions", subtitle: "Open-source components used in this app", value: "", icon: "doc.text.fill")
                }.buttonStyle(PlainCardButtonStyle())
            }

            SettingsGroupCard(title: "Diagnostics", subtitle: "Device information and storage") {
                SettingsValueCard(title: "System", subtitle: DiagnosticsService.deviceModel, value: DiagnosticsService.systemVersion, icon: "appletv.fill")
                Button {
                    guard !clearing else { return }
                    clearing = true
                    // Off the main thread for the same reason as the initial
                    // measurement: clearing and re-measuring both enumerate the
                    // cache directory recursively.
                    Task {
                        await Task.detached(priority: .userInitiated) {
                            DiagnosticsService.clearCaches()
                        }.value
                        cacheLabel = await Self.measureCache()
                        clearing = false
                    }
                } label: {
                    SettingsValueCard(
                        title: "Clear cache",
                        subtitle: "Remove cached source lists, metadata and images",
                        value: clearing ? "…" : cacheLabel,
                        icon: "trash.fill"
                    )
                }.buttonStyle(PlainCardButtonStyle())
            }
        }
        .task {
            // Measure the cache once the view is on screen, off the main
            // thread — see cacheLabel above.
            cacheLabel = await Self.measureCache()
        }
        .fullScreenCover(item: $info) { item in
            AboutInfoView(info: item)
                .environmentObject(theme)
        }
    }

    private static func measureCache() async -> String {
        await Task.detached(priority: .utility) {
            DiagnosticsService.cacheSizeLabel()
        }.value
    }
}

/// The static info pages reachable from About.
private enum AboutInfo: String, Identifiable {
    case privacy, licenses
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .licenses: return "Licenses & Attributions"
        }
    }

    var body: String {
        switch self {
        case .privacy:
            return "Orivio does not collect, store, or share any personal data. All playback, library, and account information stays on your device or with the third-party services you explicitly connect (such as TMDB, Trakt, or your debrid provider). No analytics or tracking is performed by this app."
        case .licenses:
            return "This app uses open-source components including SwiftUI, KSPlayer, and metadata provided by TMDB. TMDB is used under their API terms; this product uses the TMDB API but is not endorsed or certified by TMDB. Full license texts for bundled components are available in the source repository."
        }
    }
}

private struct AboutInfoView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    let info: AboutInfo

    var body: some View {
        DetailScaffold(title: info.title, subtitle: "") {
            SettingsGroupCard(title: "") {
                Text(info.body)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OrivioSpacing.md)
            }
        }
        .onExitCommand { dismiss() }
    }
}

private struct AddonImportView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    let onDone: () -> Void

    @State private var input = ""
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        ZStack {
            ATVBackground()
            DetailScaffold(title: "Import Add-ons", subtitle: "Paste manifest URLs from an exported setup") {
                SettingsGroupCard(title: "Manifest URLs", subtitle: "One URL per line, or paste the full text from an export") {
                    TextField("https://.../manifest.json", text: $input, axis: .vertical)
                        .font(.system(size: 22))
                        .lineLimit(5...10)
                        .padding(OrivioSpacing.lg)
                        .background(theme.palette.field, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))

                    HStack(spacing: OrivioSpacing.md) {
                        Button {
                            importAddons()
                        } label: {
                            if importing {
                                ProgressView().tint(theme.palette.onSecondary)
                            } else {
                                Text("Import").font(.system(size: 23, weight: .semibold))
                            }
                        }
                        // Stays enabled while importing (disabling the focused
                        // button drops focus); importAddons() guards re-entry.
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Done", action: onDone)
                            .font(.system(size: 23, weight: .semibold))
                    }

                    if let message {
                        Text(message)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(message.hasPrefix("Imported") ? OrivioPrimitives.success : OrivioPrimitives.error)
                    }
                }
            }
        }
        .onExitCommand(perform: onDone)
    }

    private func importAddons() {
        guard !importing else { return }
        importing = true
        message = nil
        Task {
            let result = await addonManager.importManifestURLs(from: input)
            importing = false
            if result.installed == 0 && result.failed == 0 {
                message = "No manifest URLs found."
            } else {
                message = "Imported \(result.installed), failed \(result.failed)."
                if result.installed > 0 { input = "" }
            }
        }
    }
}

private struct AddonHealthView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    let onDone: () -> Void

    @State private var scanning = false
    @State private var results: [AddonManager.HealthResult] = []

    var body: some View {
        ZStack {
            ATVBackground()
            DetailScaffold(title: "Add-on Health", subtitle: "Manifest response times for installed providers") {
                SettingsGroupCard(title: "Scan", subtitle: summary) {
                    Button { scan() } label: {
                        SettingsActionRow(
                            title: scanning ? "Scanning..." : "Run Health Check",
                            subtitle: "Checks installed manifest URLs without changing your setup",
                            value: scanning ? "..." : nil,
                            leadingIcon: "waveform.path.ecg"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .disabled(scanning)
                }

                if !results.isEmpty {
                    SettingsGroupCard(title: "Results") {
                        ForEach(results) { result in
                            AddonHealthRow(
                                result: result,
                                onDisable: { disable(result) }
                            )
                        }
                    }
                }
            }
        }
        .task {
            if results.isEmpty { scan() }
        }
        .onExitCommand(perform: onDone)
    }

    private var summary: String {
        guard !results.isEmpty else {
            return scanning ? "Checking installed add-ons..." : "No scan has run yet"
        }
        let failed = results.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let slow = results.filter { $0.status == .slow }.count
        if failed > 0 || slow > 0 {
            return "\(failed) failed, \(slow) slow, \(results.count) checked"
        }
        return "All \(results.count) installed add-ons responded normally"
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            results = await addonManager.healthCheck().sorted { lhs, rhs in
                rank(lhs.status) < rank(rhs.status)
            }
            scanning = false
        }
    }

    private func rank(_ status: AddonManager.HealthResult.Status) -> Int {
        switch status {
        case .failed: return 0
        case .slow: return 1
        case .ok: return 2
        case .disabled: return 3
        }
    }

    private func disable(_ result: AddonManager.HealthResult) {
        guard let addon = addonManager.addons.first(where: { $0.id == result.id }) else { return }
        addonManager.setEnabled(addon, false)
        scan()
    }
}

private struct AddonHealthRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let result: AddonManager.HealthResult
    let onDisable: () -> Void

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(Circle().fill(color.opacity(0.16)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: OrivioSpacing.sm) {
                    Text(result.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(result.status.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.16)))
                }
                Text(detail)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                Text(result.manifestURL)
                    .font(.system(size: 16).monospaced())
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if canDisable {
                Button("Disable", action: onDisable)
                    .font(.system(size: 21, weight: .semibold))
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.sm)
        .background(theme.palette.backgroundCard.opacity(0.5), in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
    }

    private var detail: String {
        let timing = result.elapsedMS.map { "\($0) ms" } ?? "not checked"
        switch result.status {
        case .failed(let reason):
            return "\(result.capabilities) · \(timing) · \(reason)"
        default:
            return "\(result.capabilities) · \(timing)"
        }
    }

    private var canDisable: Bool {
        switch result.status {
        case .failed, .slow: return true
        case .ok, .disabled: return false
        }
    }

    private var icon: String {
        switch result.status {
        case .ok: return "checkmark.circle.fill"
        case .slow: return "speedometer"
        case .disabled: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch result.status {
        case .ok: return OrivioPrimitives.success
        case .slow: return theme.palette.secondary
        case .disabled: return theme.palette.textTertiary
        case .failed: return OrivioPrimitives.error
        }
    }
}


/// Full-screen QR export of the installed addon manifest URLs — scan with a
/// phone to carry the setup to a fresh install (one URL per line).
private struct AddonExportView: View {
    @EnvironmentObject private var theme: ThemeManager
    let urls: [String]
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.xl) {
                Text("Add-on Setup")
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Scan with your phone — one manifest URL per line. Paste them into any Orivio install to restore your add-ons.")
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                QRCodeView(string: urls.joined(separator: "\n"))
                    .frame(width: 460, height: 460)
                Text("\(urls.count) add-on\(urls.count == 1 ? "" : "s")")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary)
                Button("Done", action: onDone)
            }
            .padding(OrivioSpacing.huge)
        }
        .onExitCommand(perform: onDone)
    }
}
