import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [MetaItem] = []
    @Published var isSearching = false
    /// Shown while the query is empty — the tab opens onto something browseable
    /// (Apple TV style) instead of a bare "start typing" void. Loaded once.
    @Published var trending: [MetaItem] = []

    private var searchTask: Task<Void, Never>?
    private var loadedTrending = false

    func search(addonManager: AddonManager) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let targets: [(InstalledAddon, ManifestCatalog)] = addonManager.catalogAddons
            .flatMap { addon in
                (addon.manifest.catalogs ?? [])
                    .filter { $0.supportsSearch }
                    .map { (addon, $0) }
            }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            var merged: [MetaItem] = []
            var seen = Set<String>()
            await withTaskGroup(of: [MetaItem].self) { group in
                for (addon, catalog) in targets {
                    group.addTask {
                        (try? await StremioAPI.catalog(addon: addon, catalog: catalog, search: trimmed)) ?? []
                    }
                }
                for await items in group {
                    for item in items where !seen.contains(item.id + item.type) {
                        seen.insert(item.id + item.type)
                        merged.append(item)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            results = merged
            isSearching = false
        }
    }

    /// First extra-free catalog's top titles, fetched once per session.
    func loadTrendingIfNeeded(addonManager: AddonManager) async {
        guard !loadedTrending else { return }
        loadedTrending = true
        for addon in addonManager.catalogAddons {
            guard let catalog = (addon.manifest.catalogs ?? []).first(where: { !$0.requiresExtra })
            else { continue }
            if let items = try? await StremioAPI.catalog(addon: addon, catalog: catalog),
               !items.isEmpty {
                trending = Array(items.deduplicatedByID().prefix(18))
                return
            }
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var addonManager: AddonManager
    // Owned by RootView so the query + results PERSIST across tab switches.
    // A local @StateObject would be rebuilt (and cleared) every time the Search
    // tab is re-entered.
    @ObservedObject var viewModel: SearchViewModel

    let onSelect: (MetaItem) -> Void
    var onOpenDiscover: () -> Void = {}

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: OrivioSpacing.lg, alignment: .top)] }

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                searchBar
                ScrollView(.vertical) {
                    if viewModel.isSearching && viewModel.results.isEmpty {
                        OrivioLoadingView(label: "Searching").frame(height: 480)
                    } else if !viewModel.results.isEmpty {
                        // Results split by type: Movies on top, Shows below.
                        VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                            if !movieResults.isEmpty {
                                resultSection(title: "Movies", items: movieResults)
                            }
                            if !showResults.isEmpty {
                                resultSection(title: "Shows", items: showResults)
                            }
                        }
                        .padding(.top, OrivioSpacing.sm)
                        .padding(.bottom, OrivioSpacing.huge)
                    } else if viewModel.query.count >= 2 {
                        OrivioEmptyState(
                            icon: "magnifyingglass",
                            title: "No results",
                            message: "Nothing matched “\(viewModel.query)”."
                        )
                        .frame(height: 480)
                    } else if !viewModel.trending.isEmpty {
                        // Idle: something to browse instead of an empty void.
                        resultSection(title: "Trending", items: viewModel.trending)
                            .padding(.top, OrivioSpacing.sm)
                            .padding(.bottom, OrivioSpacing.huge)
                    } else {
                        OrivioEmptyState(
                            icon: "magnifyingglass",
                            title: "Start Searching",
                            message: "Enter at least 2 characters"
                        )
                        .frame(height: 480)
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.top, OrivioSpacing.xl)
        }
        .task { await viewModel.loadTrendingIfNeeded(addonManager: addonManager) }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search(addonManager: addonManager)
        }
    }

    private var searchBar: some View {
        HStack(spacing: OrivioSpacing.md) {
            SearchField(text: $viewModel.query)
            Button(action: onOpenDiscover) { SearchBarIcon(systemName: "square.grid.2x2") }
                .buttonStyle(PlainCardButtonStyle())
        }
        .padding(.horizontal, OrivioSpacing.huge)
        .focusSection()
    }

    private var movieResults: [MetaItem] {
        viewModel.results.filter { !$0.isSeries }
    }

    private var showResults: [MetaItem] {
        viewModel.results.filter(\.isSeries)
    }

    /// One titled grid section ("Movies" / "Shows" / "Trending"), its own focus
    /// section so up/down moves cleanly between the groups.
    private func resultSection(title: String, items: [MetaItem]) -> some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            RowHeader(title: title)
                .padding(.leading, -OrivioSpacing.huge)   // RowHeader pads itself
            LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                ForEach(items) { item in
                    GridPosterCell(
                        item: item,
                        captionWidth: posterLayout.posterSize.posterWidth,
                        onSelect: onSelect
                    )
                }
            }
        }
        .padding(.horizontal, OrivioSpacing.huge)
        .focusSection()
    }
}


/// Round glass icon button in the Search top bar (opens Discover).
private struct SearchBarIcon: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.textPrimary)
            .frame(width: 74, height: 74)
            .background {
                if isFocused { Circle().fill(theme.palette.secondary) }
            }
            .liquidGlassIf(!isFocused, in: Circle())
            .overlay(Circle().strokeBorder(isFocused ? Color.white.opacity(0.95) : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.card, isFocused)
            .animation(PerformanceSettingsStore.shared.buttonMotion(FusionMotion.focusEntry),
                       value: isFocused)
    }
}

/// The pill search field on glass. A plain `TextField` in a frosted resting
/// capsule; on focus tvOS draws its own light editing surface, and we DON'T add
/// a competing ring — otherwise the system fill sits inset inside our ring with
/// a dark gap between them (the "weird bar" the user saw). Letting the system
/// focus be the sole highlight means the highlight and the field are one shape.
private struct SearchField: View {
    @EnvironmentObject private var theme: ThemeManager
    @FocusState private var focused: Bool
    @Binding var text: String

    var body: some View {
        HStack(spacing: OrivioSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary)
            TextField("Search movies & series", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 26))
                .foregroundStyle(theme.palette.textPrimary)
                .tint(theme.palette.secondary)
        }
        .padding(.horizontal, OrivioSpacing.xl)
        .frame(height: 74)
        .frame(maxWidth: .infinity)
        .background(Color.clear.liquidGlass(in: Capsule()))
        // No auto-focus: merely moving focus over the Search tab must not pop
        // the keyboard. Focus the field only when the user actually selects it.
    }
}
