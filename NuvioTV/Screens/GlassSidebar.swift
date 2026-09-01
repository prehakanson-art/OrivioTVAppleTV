import SwiftUI

/// The primary sidebar destinations. `liveTV` is declared LAST so its raw
/// value (4) is stable and doesn't renumber `settings` (3) — the app keys tab
/// state off these ints in many places. For display it sits ABOVE Settings via
/// `sidebarOrder`.
enum AppTab: Int, CaseIterable, Identifiable {
    case home, search, library, settings, liveTV
    var id: Int { rawValue }

    /// Order the rail renders in (Live TV above Settings, despite raw value).
    static let sidebarOrder: [AppTab] = [.home, .search, .library, .liveTV, .settings]

    var label: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .liveTV: return "Live TV"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "bookmark.fill"
        case .liveTV: return "tv.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The always-visible left navigation rail, drawn as Liquid Glass (tvOS 26;
/// translucent material before that). Collapsed it is a floating glass pill of
/// icons, vertically centered at the left edge. When focus enters it expands
/// rightward into a wider glass panel with the profile chip on top and
/// labeled rows; the parent dims the content behind it.
struct GlassSidebar: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var liveTV = LiveTVSettingsStore.shared
    @Binding var selected: Int
    var focusBinding: FocusState<Int?>.Binding
    var onProfileTap: () -> Void = {}
    /// Fires when a tab is tapped, BEFORE `selected` is mutated, so the root
    /// can tell whether this is actually a change of tab (vs. re-tapping the
    /// tab you're already on) and react accordingly.
    var onTabSelected: (Int) -> Void = { _ in }

    var expanded: Bool { focusBinding.wrappedValue != nil }

    /// Space (inside the safe area) the content reserves so it clears the
    /// floating collapsed pill, which hugs the screen edge at absolute
    /// 28..112pt — the safe inset (~90) covers most of it.
    static let collapsedWidth: CGFloat = 60
    static let expandedWidth: CGFloat = 240

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? 34 : 42, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded { Spacer(minLength: 0) }

            // Profile chip — expanded panel only, sitting DIRECTLY above the
            // nav items (one centered group, not pinned to the panel top).
            if expanded {
                Button(action: onProfileTap) {
                    GlassProfileHeader(profile: profiles.active)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused(focusBinding, equals: -1)
                .transition(.opacity)
                .padding(.horizontal, NuvioSpacing.sm)
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: expanded ? 10 : 24) {
                ForEach(AppTab.sidebarOrder.filter { $0 != .liveTV || liveTV.enabled }) { tab in
                    Button {
                        // Fire BEFORE mutating `selected` so the root can still
                        // see which tab we're coming FROM.
                        onTabSelected(tab.rawValue)
                        selected = tab.rawValue
                        // NOTE: do NOT clear focusBinding here — unfocusing
                        // with no destination makes the engine grab the nearest
                        // candidate. The root force-moves focus into content.
                    } label: {
                        GlassItemLabel(tab: tab, selected: selected == tab.rawValue, expanded: expanded)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused(focusBinding, equals: tab.rawValue)
                }
            }
            .padding(.horizontal, expanded ? NuvioSpacing.sm : 12)
            // Entering the sidebar lands on the tab you're on, not a stale row.
            .defaultFocus(focusBinding, selected)
            .padding(.vertical, expanded ? 0 : 20)

            if expanded { Spacer(minLength: 0) }
        }
        .frame(width: expanded ? Self.expandedWidth : 84, alignment: .leading)
        // Clip to the ANIMATING width so labels are revealed by the expanding
        // edge instead of rendering at their final position over the content.
        .clipped()
        // The pill hugs its icons vertically; the expanded panel stretches.
        .frame(maxHeight: expanded ? .infinity : nil)
        // Background-style glass: glassEffect WRAPPING focusable content hides
        // it from the focus engine (see liquidGlassIf).
        .background(Color.clear.liquidGlass(in: panelShape))
        .padding(.vertical, expanded ? NuvioSpacing.xl : 0)
        .padding(.leading, 28)
        .frame(maxHeight: .infinity, alignment: .center)
        // Hug the screen edge: the rail sits INSIDE the TV safe inset, not
        // pushed to the content's title-safe column.
        .ignoresSafeArea(edges: .horizontal)
        .animation(PerformanceSettingsStore.shared.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: expanded)
        // On ENTRY (collapsed → expanded), snap focus to the current tab —
        // tvOS otherwise lands on the geometrically nearest row.
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && focusBinding.wrappedValue != selected {
                focusBinding.wrappedValue = selected
            }
        }
    }
}

/// The tappable profile chip at the top of the expanded panel.
private struct GlassProfileHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let profile: UserProfile

    var body: some View {
        HStack(spacing: NuvioSpacing.sm) {
            ProfileAvatarView(profile: profile, size: 52)
            Text(profile.name)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NuvioSpacing.sm)
        .frame(height: 64)
        .background(
            Capsule(style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.18) : .clear)
        )
    }
}

/// A single rail entry: icon (+ label when expanded). Focused/selected shows a
/// soft translucent capsule fill — no border, no scale; the glass carries it.
private struct GlassItemLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let tab: AppTab
    let selected: Bool
    let expanded: Bool

    private var highlighted: Bool { isFocused || selected }

    var body: some View {
        HStack(spacing: NuvioSpacing.sm) {
            Image(systemName: tab.icon)
                .font(.system(size: expanded ? 30 : 36, weight: .semibold))
                .foregroundStyle(highlighted ? theme.palette.textPrimary : theme.palette.textSecondary)
                .frame(width: expanded ? 44 : 60, height: expanded ? nil : 60, alignment: .center)

            if expanded {
                Text(tab.label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(highlighted ? theme.palette.textPrimary : theme.palette.textSecondary)
                    .lineLimit(1)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, expanded ? NuvioSpacing.md : 0)
        .padding(.trailing, expanded ? NuvioSpacing.md : 0)
        .frame(height: expanded ? 76 : 60)
        .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(highlighted ? Color.white.opacity(isFocused ? 0.22 : 0.10) : .clear)
        )
    }
}
