import SwiftUI

// Hulu theme — the root container. Owns the section state + sidebar and renders
// the ported HuluTV screens on ORIVIO data. Selecting a card opens Orivio's
// DetailView; the hero PLAY opens the stream picker (link selector) and DETAILS
// opens the detail page. Mounted by `NuvioTVApp.huluLayout` in the home stack.
struct HuluRootView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var homeViewModel: HomeViewModel
    let searchViewModel: SearchViewModel

    var onSelect: (MetaItem) -> Void          // → detail
    var onPlay: (MetaItem) -> Void            // → stream picker
    var onResume: (WatchProgress) -> Void     // → Continue Watching resume
    var onOpenProfiles: () -> Void
    var onOpenCollection: (NuvioCollection) -> Void = { _ in }

    private struct Category: Equatable { let name: String; let series: Bool? }
    @State private var screen: HuluSection = .home
    @State private var openedCategory: Category?

    @FocusState private var sidebarFocus: HuluSidebarNav.Row?
    @State private var sidebarEnabled = false
    @Namespace private var contentScope
    @FocusState private var heroFocus: Bool

    // MARK: Orivio → Hulu data

    private var catalogRows: [HomeRow] {
        homeViewModel.entries.compactMap { if case .catalog(let r) = $0 { return r } else { return nil } }
    }
    private var pool: [MetaItem] {
        var seen = Set<String>()
        return catalogRows.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }
    private var featured: [HuluTitle] {
        var out = pool.filter { $0.background != nil }.prefix(6).map(HuluTitle.init)
        if out.isEmpty, let h = homeViewModel.initialHero { out = [HuluTitle(h)] }
        return Array(out)
    }
    private var continueList: [WatchProgress] {
        progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
            .map(progressWithCatalogArt)
    }
    private var homeRows: [HuluRail] {
        var out: [HuluRail] = []
        for (i, row) in catalogRows.enumerated() {
            out.append(HuluRail(id: row.id, title: row.title.uppercased(),
                                items: row.items.map(HuluTitle.init),
                                style: i == 0 ? .richTile : .landscape))
        }
        let top = Array(pool.prefix(15)).map(HuluTitle.init)
        if !top.isEmpty { out.append(HuluRail(id: "top15", title: "TOP 15 TODAY", items: top, style: .poster)) }
        return out
    }
    private func genres(series: Bool) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for t in pool where t.isSeries == series {
            for g in (t.genres ?? []) where seen.insert(g).inserted { out.append(g) }
        }
        return out.sorted()
    }
    private func hubRows(series: Bool) -> [HuluRail] {
        let p = pool.filter { $0.isSeries == series }
        var out: [HuluRail] = []
        let top = Array(p.prefix(15)).map(HuluTitle.init)
        if !top.isEmpty {
            out.append(HuluRail(id: "top", title: series ? "TOP TV TODAY" : "TOP MOVIES TODAY",
                                items: top, style: .poster))
        }
        for g in genres(series: series).prefix(8) {
            let items = p.filter { ($0.genres ?? []).contains(g) }
            guard items.count >= 4 else { continue }
            out.append(HuluRail(id: g, title: g.uppercased(), items: items.map(HuluTitle.init), style: .landscape))
        }
        return out
    }
    private var myStuffItems: [HuluTitle] { library.sorted.map { HuluTitle($0.metaItem) } }
    private var suggestions: [HuluTitle] { Array(pool.prefix(20)).map(HuluTitle.init) }

    private func progressWithCatalogArt(_ progress: WatchProgress) -> WatchProgress {
        guard (progress.poster == nil || progress.background == nil || progress.name.isEmpty),
              let meta = pool.first(where: { $0.id == progress.metaID }) else {
            return progress
        }
        return progress.withFallbackMetadata(meta)
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .leading) {
            HuluStyle.background

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(edges: .leading)
                .focusScope(contentScope)
                .onExitCommand { openSidebar() }

            HuluSidebarNav(
                selection: $screen,
                focusBinding: $sidebarFocus,
                onProfile: onOpenProfiles,
                onSelectSection: { open($0) }
            )
            .disabled(!sidebarEnabled)
            .onExitCommand { collapseSidebar() }
            // Exit the menu on EITHER horizontal press/swipe — the single-column
            // sidebar has no in-menu Left, so honoring it (plus Right and Back)
            // means the user can always get back out to the content.
            .onMoveCommand { if $0 == .right || $0 == .left { collapseSidebar() } }
            .onChange(of: sidebarFocus) { old, new in
                guard old == nil, let new, new != .section(screen), new != .profile else { return }
                sidebarFocus = .section(screen)
            }
        }
        .background(HuluStyle.stage.ignoresSafeArea())
        .task {
            await homeViewModel.loadIfNeeded(addonManager: addonManager,
                                             collections: collections, settings: homeCatalogSettings)
            pullHero()
            Task { try? await Task.sleep(nanoseconds: 800_000_000); sidebarEnabled = true }
        }
        .task { try? await Task.sleep(nanoseconds: 3_000_000_000); sidebarEnabled = true }
        .onAppear {
            if let s = ProcessInfo.processInfo.environment["HULU_SECTION"],
               let sec = HuluSection(rawValue: s) { screen = sec }
        }
        .onAppear(perform: pullHero)
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("-huluSidebarDemo") else { return }
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000)
                sidebarEnabled = true; sidebarFocus = .section(screen) }
        }
    }

    @ViewBuilder private var content: some View {
        if let cat = openedCategory {
            HuluCategoryListView(name: cat.name, series: cat.series, onSelect: pick)
                .onExitCommand { openedCategory = nil }
        } else {
            switch screen {
            case .home:
                HuluHomeView(featured: featured,
                             continueItems: continueList.map(HuluTitle.init),
                             rows: homeRows, onSelect: pick, onPlay: playT,
                             onResume: { t in if let p = continueList.first(where: { $0.metaID == t.id }) { onResume(p) } },
                             playFocus: $heroFocus, onBackAtRoot: { openSidebar() })
            case .tv:
                HuluHubView(featured: featured, genres: genres(series: true), rows: hubRows(series: true),
                            series: true, onSelect: pick, onPlay: playT,
                            onCategory: { openedCategory = Category(name: $0, series: true) },
                            playFocus: $heroFocus, onBackAtRoot: { openSidebar() })
            case .movies:
                HuluHubView(featured: featured, genres: genres(series: false), rows: hubRows(series: false),
                            series: false, onSelect: pick, onPlay: playT,
                            onCategory: { openedCategory = Category(name: $0, series: false) },
                            playFocus: $heroFocus, onBackAtRoot: { openSidebar() })
            case .news:
                HuluNewsView(onSelect: pick, onBackAtRoot: { openSidebar() })
            case .myStuff:
                HuluMyStuffView(items: myStuffItems, onSelect: pick)
            case .hubs:
                HuluHubsView(collections: collections.collections,
                             onOpenCollection: onOpenCollection,
                             onOpenFolder: { folder, coll in
                                 let single = NuvioCollection(id: "folder:\(coll.id):\(folder.id)",
                                                              title: folder.title, folders: [folder])
                                 onOpenCollection(single)
                             })
            case .search:
                HuluSearchView(suggestions: suggestions, searchViewModel: searchViewModel,
                               addonManager: addonManager, onSelect: pick)
            case .settings:
                HuluSettingsView()
            }
        }
    }

    // MARK: Actions

    private func pick(_ t: HuluTitle) { onSelect(t.meta ?? metaFor(t.id)) }
    private func playT(_ t: HuluTitle) { onPlay(t.meta ?? metaFor(t.id)) }
    private func metaFor(_ id: String) -> MetaItem {
        if let m = pool.first(where: { $0.id == id }) { return m }
        if let p = continueList.first(where: { $0.metaID == id }) {
            return MetaItem(id: p.metaID, type: p.type, name: p.name,
                            poster: p.poster, background: p.background, logo: p.logo)
        }
        return MetaItem(id: id, type: "movie", name: "")
    }

    private func open(_ s: HuluSection) {
        guard s != screen else { collapseSidebar(); return }
        openedCategory = nil
        screen = s
        collapseSidebar()
        pullHero()
    }
    private func openSidebar() {
        sidebarEnabled = true
        sidebarFocus = .section(screen)
    }
    private func collapseSidebar() {
        sidebarFocus = nil
        sidebarEnabled = false
        // Drive focus back onto the hero so leaving the menu (or re-pressing the
        // current tab) never strands focus — the auto-advancing hero may have
        // swapped its artwork while the sidebar was open, so tvOS can't reliably
        // restore the element you came from.
        pullHero()
        Task { try? await Task.sleep(nanoseconds: 400_000_000); sidebarEnabled = true }
    }
    private func pullHero() {
        if ProcessInfo.processInfo.arguments.contains("-huluSidebarDemo") { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { heroFocus = true }
    }
}
