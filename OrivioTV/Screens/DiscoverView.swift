import SwiftUI

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = false
    @Published var reachedEnd = false
    private var seen = Set<String>()
    private var current: (addon: InstalledAddon, catalog: ManifestCatalog)?
    private var genre: String?
    /// Bumped by every `reset`. The grid's "load the next page" trigger lives on
    /// the last cell and fires an unstructured Task that nothing cancels, so a
    /// page request routinely outlives the selection that started it.
    private var generation = 0
    /// Set by `reset`, cleared when the replacement's first page lands.
    private var replacingSelection = false

    func reset(addon: InstalledAddon, catalog: ManifestCatalog, genre: String?) async {
        generation += 1
        current = (addon, catalog)
        self.genre = genre
        // Deliberately NOT clearing `items` here. Doing so replaced the grid the
        // viewer was reading with a spinner for a whole network round trip and
        // destroyed the focused cell with it — focus then landed wherever the
        // engine could find it. The outgoing results stay until the first page
        // of the new selection actually arrives (see `loadMore`).
        seen = []
        reachedEnd = false
        replacingSelection = true
        // Deliberately NOT waiting on the in-flight page: `loadMore` is gated on
        // `isLoading`, so leaving it set meant the new selection never fetched
        // anything. The grid was then empty, and the only thing that retriggers
        // a load is the last cell appearing — of which there were none, so
        // "Nothing here" stuck until the selectors were changed again.
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard let current, !isLoading, !reachedEnd else { return }
        let token = generation
        isLoading = true
        let page = (try? await StremioAPI.catalog(
            addon: current.addon, catalog: current.catalog,
            genre: genre, skip: items.count
        )) ?? []
        // The selection changed while this page was loading. Its items belong to
        // a catalog nobody is looking at, and its emptiness (a cancelled request
        // returns []) must not mark the NEW selection as finished. Leave
        // `isLoading` alone too — it now belongs to the newer request.
        guard token == generation else { return }
        isLoading = false
        // First page of a NEW selection: this is the moment to replace what is
        // on screen, so the swap happens once, with content, instead of via an
        // empty grid.
        if items.isEmpty || replacingSelection {
            replacingSelection = false
            items = []
        }
        let fresh = page.filter { seen.insert($0.id + $0.type).inserted }
        if fresh.isEmpty { reachedEnd = true } else { items.append(contentsOf: fresh) }
    }
}

/// Browse-by-catalog screen with Type / Catalog / Genre selectors and a
/// paginated poster grid, matching the APK's Discover screen (opened from the
/// Search compass button).
struct DiscoverView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var addonManager: AddonManager
    @StateObject private var viewModel = DiscoverViewModel()

    let onSelect: (MetaItem) -> Void

    @State private var type = "Movie"          // Movie / Series
    @State private var catalogIndex = 0
    @State private var genre = ""              // "" = Default (no filter)
    @FocusState private var focusedID: String?
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: OrivioSpacing.lg, alignment: .top)] }

    private var stremioType: String { type == "Series" ? "series" : "movie" }

    /// Catalogs of the selected type, across installed add-ons (no search-only).
    private var catalogs: [(addon: InstalledAddon, catalog: ManifestCatalog)] {
        addonManager.catalogAddons.flatMap { addon in
            (addon.manifest.catalogs ?? [])
                .filter { $0.type == stremioType && !$0.requiresExtra }
                .map { (addon, $0) }
        }
    }

    private var selected: (addon: InstalledAddon, catalog: ManifestCatalog)? {
        let list = catalogs
        guard !list.isEmpty else { return nil }
        return list[min(catalogIndex, list.count - 1)]
    }

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                    Text("Discover")
                        .font(FusionType.pageTitle(theme.font))
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(.leading, OrivioSpacing.huge)

                    HStack(spacing: OrivioSpacing.lg) {
                        OrivioDropdown(
                            title: "Type",
                            selection: type,
                            options: [OrivioDropdownOption("Movie"), OrivioDropdownOption("Series")],
                            triggerWidth: 380
                        ) { type = $0; catalogIndex = 0; genre = "" }

                        OrivioDropdown(
                            title: "Catalog",
                            selection: String(catalogIndex),
                            options: catalogs.enumerated().map { index, entry in
                                OrivioDropdownOption(String(index), entry.catalog.name ?? entry.catalog.id.capitalized)
                            },
                            triggerWidth: 460
                        ) { catalogIndex = Int($0) ?? 0; genre = "" }

                        OrivioDropdown(
                            title: "Genre",
                            selection: genre,
                            options: [OrivioDropdownOption("", "Default")]
                                + (selected?.catalog.genreOptions ?? []).map { OrivioDropdownOption($0) },
                            triggerWidth: 380
                        ) { genre = $0 }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)

                    if viewModel.items.isEmpty && viewModel.isLoading {
                        OrivioLoadingView(label: "Loading").frame(height: 420)
                    } else if viewModel.items.isEmpty {
                        OrivioEmptyState(icon: "safari", title: "Nothing here",
                                        message: "No titles for this catalog. Install more add-ons in Settings.")
                            .frame(height: 420)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                            ForEach(viewModel.items) { item in
                                GridPosterCell(
                                    item: item,
                                    captionWidth: posterLayout.posterSize.posterWidth,
                                    onSelect: onSelect,
                                    gridFocus: $focusedID
                                )
                                .id(item.id)
                                .onAppear {
                                    if item.id == viewModel.items.last?.id {
                                        Task { await viewModel.loadMore() }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, OrivioSpacing.huge)
                        .padding(.bottom, OrivioSpacing.huge)
                    }
                }
                .padding(.top, OrivioSpacing.xl)
            }
            .scrollClipDisabled()
            .onExitCommand { backToTop(proxy) }
            }
        }
        .task(id: reloadKey) {
            if let sel = selected {
                await viewModel.reset(addon: sel.addon, catalog: sel.catalog,
                                      genre: genre.isEmpty ? nil : genre)
            }
        }
    }

    /// Back deep in the grid scrolls to (and focuses) the first poster; a second
    /// Back — already at the top — pops back to the previous screen.
    private func backToTop(_ proxy: ScrollViewProxy) {
        // `focusedID` is nil while the selector pills hold focus — Back from
        // there pops the screen; it used to yank focus down into the grid.
        guard let first = viewModel.items.first?.id, let focused = focusedID, focused != first else {
            dismiss(); return
        }
        withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .top) }
        DispatchQueue.main.async { focusedID = first }
    }

    private var reloadKey: String { "\(type)#\(catalogIndex)#\(selected?.catalog.id ?? "")#\(genre)" }
}
