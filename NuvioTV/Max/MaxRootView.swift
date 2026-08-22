import SwiftUI

// Max theme — the root container. Owns the section state + the sidebar and
// renders the ported MaxTV screens, all fed by ORIVIO data (HomeViewModel /
// ProgressStore / LibraryStore / SearchViewModel). Selecting a title bridges out
// to Orivio's real navigation via `onSelect` (the app pushes DetailView, whose
// Play resolves streams through Orivio's addons). Mounted by
// `NuvioTVApp.maxLayout` inside the shared home NavigationStack.
struct MaxRootView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var homeViewModel: HomeViewModel
    // Not @ObservedObject: only `MaxSearchView` observes it, so the whole root
    // doesn't re-render (recomputing the data pools) on every search keystroke.
    let searchViewModel: SearchViewModel

    /// Bridge into Orivio navigation.
    var onSelect: (MetaItem) -> Void
    var onOpenProfiles: () -> Void
    /// Play/open a live channel (pushes Orivio's stream picker).
    var onOpenChannel: (MetaItem) -> Void = { _ in }
    /// Open one of the user's saved collections.
    var onOpenCollection: (NuvioCollection) -> Void = { _ in }

    private enum Screen: Equatable {
        case section(MaxSection)
        case myStuff
        case settings
    }
    @State private var screen: Screen = .section(.home)
    @State private var selectedSection: MaxSection = .home
    /// Category drill-down inside the Categories tab (Max-local, self-contained).
    @State private var openedCategory: String?

    @FocusState private var sidebarFocus: MaxSidebarNav.Row?
    @State private var sidebarEnabled = false
    @Namespace private var contentScope
    @FocusState private var heroFocus: Bool

    // MARK: Orivio → Max data pools

    /// Rows and the de-duplicated item pool come from the shared assembly on
    /// HomeViewModel — every theme derives them the same way.
    private var catalogRows: [HomeRow] { homeViewModel.catalogRows }
    private var pool: [MetaItem] { homeViewModel.orderedItems }
    private var featured: [MaxTitle] {
        var out = pool.filter { $0.background != nil }.prefix(6).map(MaxTitle.init)
        if out.isEmpty, let h = homeViewModel.initialHero { out = [MaxTitle(h)] }
        return Array(out)
    }
    private var continueItems: [MaxTitle] {
        progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode).map(MaxTitle.init)
    }
    private var homeRows: [MaxRow] {
        catalogRows.map { MaxRow(id: $0.id, title: $0.title, items: $0.items.map(MaxTitle.init)) }
    }
    private func typePool(series: Bool) -> [MaxTitle] {
        pool.filter { $0.isSeries == series }.map(MaxTitle.init)
    }
    private var genreTiles: [(name: String, image: String?)] {
        var seen = Set<String>()
        var used = Set<String>()   // a title is a rep for at most one tile
        var out: [(String, String?)] = []
        for item in pool {
            for g in (item.genres ?? []) where seen.insert(g).inserted {
                if let rep = pool.first(where: { ($0.genres ?? []).contains(g) && $0.background != nil && !used.contains($0.id) }) {
                    used.insert(rep.id)
                    out.append((g, rep.background ?? rep.poster))
                } else {
                    out.append((g, pool.first { ($0.genres ?? []).contains(g) }?.poster))
                }
            }
        }
        return out.map { (name: $0.0, image: $0.1) }
    }
    private var myStuffItems: [MaxTitle] {
        library.sorted.map { MaxTitle($0.metaItem) }
    }
    private var suggestions: [MaxTitle] { Array(pool.prefix(20)).map(MaxTitle.init) }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .leading) {
            MaxStyle.stage.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(edges: .leading)
                .focusScope(contentScope)
                .onExitCommand { openSidebar() }

            if showsLogo {
                MaxBrandLogo(scale: 0.9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 60).padding(.top, 40)
                    .allowsHitTesting(false)
            }

            MaxSidebarNav(
                selection: $selectedSection,
                specialSelected: isSpecial,
                focusBinding: $sidebarFocus,
                onProfile: onOpenProfiles,
                onMyStuff: { open(.myStuff) },
                onSettings: { open(.settings) },
                onSelectSection: { open(.section($0)) }
            )
            .disabled(!sidebarEnabled)
            .onExitCommand { collapseSidebar() }
            // Exit the menu on EITHER horizontal press/swipe. The sidebar is a
            // single column, so Left has no in-menu meaning — honoring it (as
            // well as Right and Back) means the user can always get back out.
            .onMoveCommand { if $0 == .right || $0 == .left { collapseSidebar() } }
            // Whenever focus FIRST enters the sidebar (from content — e.g.
            // pressing Left, which otherwise lands on the geometrically-nearest
            // icon), snap it to the tab for the page you're on. Moves WITHIN the
            // sidebar (old value non-nil) are left alone so navigation works.
            .onChange(of: sidebarFocus) { old, new in
                guard old == nil, let new, new != .section(selectedSection) else { return }
                // Don't override an intentional tap on the profile chip.
                if new == .profile { return }
                sidebarFocus = .section(selectedSection)
            }
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                sidebarEnabled = true
            }
        }
        .background(MaxStyle.stage)
        .task {
            await homeViewModel.loadIfNeeded(addonManager: addonManager,
                                             collections: collections,
                                             settings: homeCatalogSettings)
            pullHero()
            Task { try? await Task.sleep(nanoseconds: 800_000_000); sidebarEnabled = true }
        }
        .onAppear {
            // Dev-only: jump straight to a section/screen for sim verification.
            switch ProcessInfo.processInfo.environment["MAX_SECTION"] {
            case "Settings": screen = .settings
            case "MyStuff": screen = .myStuff
            case let s?:
                if let sec = MaxSection(rawValue: s) { selectedSection = sec; screen = .section(sec) }
            default: break
            }
        }
        .onAppear(perform: pullHero)
        // Dev-only: pin the expanded sidebar for sim screenshots.
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("-maxSidebarDemo") else { return }
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000)
                sidebarEnabled = true; sidebarFocus = .section(selectedSection) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if case .section(.categories) = screen, let name = openedCategory {
            MaxCategoryListView(name: name, onSelect: pick)
                .onExitCommand { openedCategory = nil }
        } else {
            switch screen {
            case .section(.home):
                // No `defaultFocusNS`: forcing prefers-default-focus made focus
                // jump back to the hero every time it re-entered the content
                // (e.g. returning from the sidebar), scrolling the page to the
                // top and looking like a reload. Initial focus is handled by the
                // one-time `heroFocus` pull instead, so returning from the
                // sidebar restores the card you were on.
                MaxHomeView(featured: featured, continueItems: continueItems, rows: homeRows,
                            onSelect: pick, playFocus: $heroFocus,
                            onBackAtRoot: { openSidebar() })
            case .section(.series):
                MaxHubView(featured: featured, pool: typePool(series: true), top10Kind: "SERIES",
                           series: true, onSelect: pick, playFocus: $heroFocus, onBackAtRoot: { openSidebar() })
            case .section(.movies):
                MaxHubView(featured: featured, pool: typePool(series: false), top10Kind: "MOVIES",
                           series: false, onSelect: pick, playFocus: $heroFocus, onBackAtRoot: { openSidebar() })
            case .section(.liveTV):
                LiveTVView(onSelectChannel: onOpenChannel,
                           onPlayDirect: { _ in })
                    .padding(.leading, MaxSidebarNav.collapsedWidth)
            case .section(.categories):
                MaxCategoriesView(genres: genreTiles, collections: collections.collections,
                                  onOpenCategory: { openedCategory = $0 },
                                  onOpenCollection: { onOpenCollection($0) },
                                  onOpenFolder: { folder, coll in
                                      onOpenCollection(HomeViewModel.folderCollection(folder, in: coll))
                                  })
            case .section(.search):
                MaxSearchView(suggestions: suggestions, searchViewModel: searchViewModel,
                              addonManager: addonManager, onSelect: pick)
            case .myStuff:
                MaxMyStuffView(items: myStuffItems, onSelect: pick)
            case .settings:
                MaxSettingsView()
                    .padding(.leading, MaxSidebarNav.collapsedWidth)
            }
        }
    }

    private var isSpecial: Bool {
        switch screen { case .myStuff, .settings: return true; default: return false }
    }
    private var showsLogo: Bool {
        // Show the Orivio lockup only on the hero browse pages.
        switch screen {
        case .section(.home), .section(.series), .section(.movies):
            return openedCategory == nil
        default: return false
        }
    }

    // MARK: Actions

    private func pick(_ t: MaxTitle) {
        onSelect(t.meta ?? metaFor(t.id))
    }
    private func metaFor(_ id: String) -> MetaItem {
        if let m = pool.first(where: { $0.id == id }) { return m }
        if let p = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
            .first(where: { $0.metaID == id }) {
            return MetaItem(id: p.metaID, type: p.type, name: p.name,
                            poster: p.poster, background: p.background, logo: p.logo)
        }
        return MetaItem(id: id, type: "movie", name: "")
    }

    private func open(_ s: Screen) {
        // Re-selecting the tab you're already on must NOT rebuild the screen
        // (that was the spurious "reload"); just close the menu. A real switch
        // to a different tab rebuilds it fresh — which is the intended reload.
        if s == screen {
            collapseSidebar()
            return
        }
        if case .section(let sec) = s { selectedSection = sec }
        openedCategory = nil
        screen = s
        collapseSidebar()
        pullHero()
    }
    private func openSidebar() {
        sidebarEnabled = true
        sidebarFocus = .section(selectedSection)
    }
    private func collapseSidebar() {
        sidebarFocus = nil
        sidebarEnabled = false
        // Always drive focus back onto the hero when leaving the menu. The
        // auto-advancing hero may have swapped its artwork while the sidebar was
        // open, so tvOS can't reliably restore the element you came from — this
        // guarantees exiting (or re-pressing the current tab) lands on the hero.
        pullHero()
        Task { try? await Task.sleep(nanoseconds: 400_000_000); sidebarEnabled = true }
    }
    private func pullHero() {
        if ProcessInfo.processInfo.arguments.contains("-maxSidebarDemo") { return }
        if ProcessInfo.processInfo.environment["MAX_FOCUS_CARD"] != nil { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { heroFocus = true }
    }
}
