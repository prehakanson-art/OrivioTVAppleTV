import SwiftUI

/// One chip row drives the whole screen: All / Movies / Shows filter the one
/// unified grid, Cloud swaps to the debrid cloud pane.
private enum LibraryFilter: String, CaseIterable {
    case all = "All", movies = "Movies", shows = "Shows", cloud = "Cloud"
}

struct LibraryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progressStore: ProgressStore

    let onSelect: (MetaItem) -> Void
    /// Opens the full Cloud Library screen (debrid cloud files).
    var onOpenCloud: () -> Void = {}
    /// Back pressed while already at the top of the grid: leave the screen.
    var onBackAtRoot: () -> Void = {}

    @State private var filter: LibraryFilter = .all
    @State private var sort = "Added"              // Added / Name / Recently Watched
    @FocusState private var focusedID: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: OrivioSpacing.lg, alignment: .top)] }

    private var sorted: [SavedLibraryItem] {
        var items = library.sorted
        switch sort {
        case "Name":
            items = items.sorted { $0.metaItem.name.lowercased() < $1.metaItem.name.lowercased() }
        case "Recently Watched":
            // Latest Continue Watching activity per title; unwatched titles
            // keep their added order at the bottom.
            let lastWatched = Dictionary(
                progressStore.allForSync().map { ($0.metaID, $0.updatedAt) },
                uniquingKeysWith: max
            )
            items = items.sorted {
                let a = lastWatched[$0.id] ?? .distantPast
                let b = lastWatched[$1.id] ?? .distantPast
                return a > b
            }
        default:
            break
        }
        return items
    }

    private var savedMovies: [SavedLibraryItem] { sorted.filter { !$0.metaItem.isSeries } }
    private var savedShows: [SavedLibraryItem] { sorted.filter { $0.metaItem.isSeries } }

    /// The one grid's contents under the active filter.
    private var visibleItems: [SavedLibraryItem] {
        switch filter {
        case .movies: return savedMovies
        case .shows: return savedShows
        default: return sorted
        }
    }

    private var firstItemID: String? { visibleItems.first?.id }

    /// "12 movies · 8 shows" beside the title.
    private var countLine: String? {
        guard !sorted.isEmpty else { return nil }
        var parts: [String] = []
        if !savedMovies.isEmpty { parts.append("\(savedMovies.count) movie\(savedMovies.count == 1 ? "" : "s")") }
        if !savedShows.isEmpty { parts.append("\(savedShows.count) show\(savedShows.count == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                    header
                    chipRow
                    if filter == .cloud {
                        cloudPane
                    } else if visibleItems.isEmpty {
                        OrivioEmptyState(icon: "bookmark",
                                        title: emptyTitle,
                                        message: "Save titles with the + button on their page and they'll live here.")
                            .frame(height: 460)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                            ForEach(visibleItems) { item in
                                GridPosterCell(
                                    item: item.metaItem,
                                    captionWidth: posterLayout.posterSize.posterWidth,
                                    onSelect: onSelect,
                                    gridFocus: $focusedID
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, OrivioSpacing.huge)
                        .padding(.bottom, OrivioSpacing.huge)
                        .focusSection()
                    }
                }
                .padding(.top, OrivioSpacing.xl)
            }
            .scrollClipDisabled()
            .onExitCommand { backToTop(proxy) }
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .movies: return "No saved movies"
        case .shows: return "No saved shows"
        default: return "Nothing saved yet"
        }
    }

    /// Back deep in the grid scrolls to (and focuses) the first poster; a second
    /// Back — already at the top — leaves the screen via `onBackAtRoot`.
    private func backToTop(_ proxy: ScrollViewProxy) {
        guard let first = firstItemID, focusedID != first else {
            onBackAtRoot(); return
        }
        withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .top) }
        DispatchQueue.main.async { focusedID = first }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Library")
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
            if let countLine {
                Text(countLine)
                    .font(FusionType.metadata(theme.font))
                    .foregroundStyle(theme.palette.textTertiary)
                    .padding(.leading, OrivioSpacing.sm)
            }
            Spacer()
            Image("OrivioLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 40)
                .accessibilityLabel("Orivio")
        }
        .padding(.horizontal, OrivioSpacing.huge)
    }

    /// One row drives everything: All / Movies / Shows / Cloud chips on the
    /// left, the Sort pill on the right.
    private var chipRow: some View {
        HStack(spacing: OrivioSpacing.md) {
            ForEach(LibraryFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    LibraryChip(title: f.rawValue, selected: filter == f)
                }
                .buttonStyle(PlainCardButtonStyle())
            }
            Spacer()
            if filter != .cloud {
                OrivioDropdown(
                    title: "Sort",
                    selection: sort,
                    options: [
                        OrivioDropdownOption("Added"),
                        OrivioDropdownOption("Name"),
                        OrivioDropdownOption("Recently Watched")
                    ],
                    triggerWidth: 380
                ) { sort = $0 }
            }
        }
        .padding(.horizontal, OrivioSpacing.huge)
        .focusSection()
    }

    private var cloudPane: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            OrivioEmptyState(icon: "externaldrive.connected.to.line.below",
                            title: "Debrid cloud files",
                            message: "Browse and play the files already in your Real-Debrid / Premiumize / TorBox / AllDebrid cloud.")
                .frame(maxWidth: .infinity)
            // Left-aligned under the chips so focus drops straight down onto it
            // (a centered button forces a sideways hop).
            Button(action: onOpenCloud) {
                SeeAllLabel(text: "Open Cloud Library")
            }
            .buttonStyle(PlainCardButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 460, alignment: .leading)
        .padding(.horizontal, OrivioSpacing.huge)
    }
}

/// A Liquid Glass filter chip: glass in every state, accent tint + accent ring
/// when selected, white ring + lift while focused.
private struct LibraryChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(selected ? theme.palette.textPrimary : theme.palette.textSecondary)
            .padding(.horizontal, OrivioSpacing.xl)
            .padding(.vertical, OrivioSpacing.sm)
            .background {
                if selected {
                    Capsule().fill(theme.palette.secondary.opacity(0.30))
                }
            }
            .liquidGlassIf(!selected, in: Capsule())
            .overlay(Capsule().strokeBorder(
                isFocused ? Color.white.opacity(0.9)
                          : (selected ? theme.palette.secondary.opacity(0.7) : .clear),
                lineWidth: 3))
            .shadow(color: isFocused ? .black.opacity(0.35) : .clear, radius: isFocused ? 16 : 0, y: 6)
            .focusLift(OrivioFocus.card, isFocused)
            .animation(PerformanceSettingsStore.shared.buttonAnimationsEffective
                       ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: isFocused)
    }
}
