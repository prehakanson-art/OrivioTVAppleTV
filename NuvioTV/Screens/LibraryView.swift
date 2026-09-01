import SwiftUI

private enum LibraryTab: String, CaseIterable { case saved = "Saved", cloud = "Cloud" }

struct LibraryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progressStore: ProgressStore

    let onSelect: (MetaItem) -> Void
    /// Opens the full Cloud Library screen (debrid cloud files).
    var onOpenCloud: () -> Void = {}
    /// Back pressed while already at the top of the grid: leave the screen
    /// (Classic opens the sidebar; Fusion is a no-op so focus rises to the tab bar).
    var onBackAtRoot: () -> Void = {}

    @State private var tab: LibraryTab = .saved
    @State private var sort = "Added"              // Added / Name / Recently Watched
    @FocusState private var focusedID: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: NuvioSpacing.lg, alignment: .top)] }

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

    /// First focusable poster in the grid (Movies section leads, then Shows).
    private var firstItemID: String? { savedMovies.first?.id ?? savedShows.first?.id }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                    header
                    tabs
                    if tab == .saved { filters }
                    if tab == .cloud {
                        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                            NuvioEmptyState(icon: "externaldrive.connected.to.line.below",
                                            title: "Debrid cloud files",
                                            message: "Browse and play the files already in your Real-Debrid / Premiumize / TorBox / AllDebrid cloud.")
                                .frame(maxWidth: .infinity)
                            // Left-aligned under the tabs so focus drops straight
                            // down onto it (a centered button forces a sideways hop).
                            Button(action: onOpenCloud) {
                                SeeAllLabel(text: "Open Cloud Library")
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 460, alignment: .leading)
                        .padding(.horizontal, NuvioSpacing.huge)
                    } else if sorted.isEmpty {
                        NuvioEmptyState(icon: "bookmark",
                                        title: "Nothing saved yet",
                                        message: "Start saving your favorites to see them here")
                            .frame(height: 460)
                    } else {
                        // Movies and Shows split into their own sections, like Search.
                        VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                            if !savedMovies.isEmpty {
                                LibrarySection(title: "Movies") { savedGrid(savedMovies) }
                            }
                            if !savedShows.isEmpty {
                                LibrarySection(title: "Shows") { savedGrid(savedShows) }
                            }
                        }
                        .padding(.bottom, NuvioSpacing.huge)
                    }
                }
                .padding(.top, NuvioSpacing.xl)
            }
            .scrollClipDisabled()
            .onExitCommand { backToTop(proxy) }
            }
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
        HStack {
            Text("Library")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            Image("OrivioLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 40)
                .accessibilityLabel("Orivio")
        }
        .padding(.horizontal, NuvioSpacing.huge)
    }

    private var tabs: some View {
        HStack(spacing: NuvioSpacing.md) {
            ForEach(LibraryTab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    LibrarySegment(title: t.rawValue, selected: tab == t)
                }
                .buttonStyle(PlainCardButtonStyle())
            }
        }
        .padding(.horizontal, NuvioSpacing.huge)
    }

    private var filters: some View {
        HStack(spacing: NuvioSpacing.lg) {
            NuvioDropdown(
                title: "Sort",
                selection: sort,
                options: [
                    NuvioDropdownOption("Added"),
                    NuvioDropdownOption("Name"),
                    NuvioDropdownOption("Recently Watched")
                ],
                triggerWidth: 460
            ) { sort = $0 }
        }
        .padding(.horizontal, NuvioSpacing.huge)
    }

    private func savedGrid(_ items: [SavedLibraryItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioSpacing.xl) {
            ForEach(items) { item in
                Button { onSelect(item.metaItem) } label: {
                    PosterCard(item: item.metaItem)
                }
                .mediaCardButtonStyle()
                .posterHoldMenu(item.metaItem) { onSelect(item.metaItem) }
                .focused($focusedID, equals: item.id)
                .id(item.id)
            }
        }
    }
}

/// A Saved/Cloud style tab pill.
private struct LibrarySegment: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(selected ? theme.palette.onSecondary : theme.palette.textSecondary)
            .padding(.horizontal, NuvioSpacing.lg)
            .padding(.vertical, NuvioSpacing.sm)
            .background(
                Capsule().fill(selected ? theme.palette.secondary
                               : (isFocused ? theme.palette.focusBackground : Color.white.opacity(0.08)))
            )
            .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(NuvioFocus.card, isFocused)
            .animation(PerformanceSettingsStore.shared.buttonAnimationsEffective
                       ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: isFocused)
    }
}

