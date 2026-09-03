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
        let targets: [(InstalledAddon, ManifestCatalog)] = Self.searchTargets(addonManager)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            // Collect by target INDEX, not by completion. `for await` on a task
            // group yields in the order tasks finish, so the merged list was
            // ordered by whichever add-on answered fastest — a race. A slow
            // Cinemeta behind a fast torrent aggregator put junk on top, and
            // the same search could come back in a different order twice in a
            // row. Now the order is the one `searchTargets` decided.
            var byTarget = [Int: [MetaItem]](minimumCapacity: targets.count)
            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for (index, target) in targets.enumerated() {
                    // Resolved out here: the class is @MainActor, so the
                    // task's body can't reach its static members.
                    let cap = Self.limit(for: target.0)
                    group.addTask {
                        let items = (try? await StremioAPI.catalog(
                            addon: target.0, catalog: target.1, search: trimmed)) ?? []
                        // Cap each catalog's contribution. One add-on
                        // returning hundreds of per-release rows buried every
                        // other add-on's real titles.
                        return (index, Array(items.prefix(cap)))
                    }
                }
                for await (index, items) in group { byTarget[index] = items }
            }
            guard !Task.isCancelled else { return }

            var merged: [MetaItem] = []
            var seen = Set<String>()
            for index in targets.indices {
                for item in byTarget[index] ?? [] where !seen.contains(item.id + item.type) {
                    seen.insert(item.id + item.type)
                    merged.append(item)
                }
            }
            results = merged
            isSearching = false
        }
    }

    /// Most results one catalog may contribute to a search.
    private static let perCatalogLimit = 40
    /// A much tighter cap for stream-only source add-ons. Ranking them last
    /// stops them leading the results but not from filling the tail: four
    /// searchable catalogs at the normal cap is still 160 per-release rows
    /// behind the real titles. They keep a foothold rather than a flood.
    private static let sourceAddonLimit = 8

    private static func limit(for addon: InstalledAddon) -> Int {
        searchRank(addon) == 2 ? sourceAddonLimit : perCatalogLimit
    }

    /// Every searchable catalog, metadata add-ons first.
    ///
    /// Search is for finding TITLES. An add-on that provides `meta` describes
    /// titles; one that only provides `stream` is a source aggregator whose
    /// catalog lists individual releases. When such an add-on sat above
    /// Cinemeta in the list, search filled up with single torrents for random
    /// episodes and users had to reorder their add-ons by hand to get it back.
    /// Ordering by capability rather than by install position is that
    /// workaround, done automatically.
    ///
    /// Source add-ons are still searched, just last — excluding them outright
    /// would silently drop results from a legitimately configured add-on.
    static func searchTargets(_ addonManager: AddonManager) -> [(InstalledAddon, ManifestCatalog)] {
        addonManager.catalogAddons
            .enumerated()
            // `sorted` is not documented as stable, so the install index is an
            // explicit tiebreaker — without it, add-ons of equal rank could
            // reshuffle between searches.
            .sorted { a, b in
                let (ra, rb) = (Self.searchRank(a.element), Self.searchRank(b.element))
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .flatMap { entry in
                (entry.element.manifest.catalogs ?? [])
                    .filter { $0.supportsSearch }
                    .map { (entry.element, $0) }
            }
    }

    /// Lower sorts first: metadata providers, then anything else, then
    /// stream-only source add-ons.
    private static func searchRank(_ addon: InstalledAddon) -> Int {
        if addon.manifest.providesMeta { return 0 }
        if addon.manifest.providesStreams { return 2 }
        return 1
    }

    /// First extra-free catalog's top titles, fetched once per session.
    func loadTrendingIfNeeded(addonManager: AddonManager) async {
        guard !loadedTrending else { return }
        loadedTrending = true
        // Same ordering problem as search: "the first add-on with an
        // extra-free catalog" made a torrent aggregator's release listing the
        // Trending shelf whenever one happened to be installed above Cinemeta.
        let ranked = addonManager.catalogAddons
            .enumerated()
            .sorted { a, b in
                let (ra, rb) = (Self.searchRank(a.element), Self.searchRank(b.element))
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
        for addon in ranked {
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
