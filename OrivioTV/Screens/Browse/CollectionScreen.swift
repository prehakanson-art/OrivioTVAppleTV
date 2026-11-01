import SwiftUI

/// §16.10 Collection page: the hero band (folder backdrop + logo or title),
/// a tab strip of folders ("All" first when enabled), Type / Genre / Sort
/// capsules on the right of the strip, then a 6-column poster grid.
/// The route id is `collectionID` or `collectionID#folderID` (opens on that folder).
struct CollectionScreen: View {
    let collectionID: String

    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var home: HomeSettingsStore
    @State private var tab: String?
    @State private var folders: [String: FolderState] = [:]
    @State private var type: BrowseTypeFilter = .all
    @State private var genre: String?
    @State private var sort: BrowseSort = .standard
    @State private var picker: Picker?
    @State private var allLoading = false
    /// Bumped to ask the tab strip to put focus on the open tab.
    @State private var tabFocusRequest = 0

    enum Picker: Identifiable { case type, genre, sort; var id: Self { self } }
    static let allTab = "__all"

    struct FolderState {
        var items: [MetaItem] = []
        var page = 0
        var loading = false
        var exhausted = false
        var blocked: CollectionResolver.Outcome?
    }

    private var ids: (collection: String, folder: String?) {
        let parts = collectionID.split(separator: "#", maxSplits: 1).map(String.init)
        return (parts.first ?? collectionID, parts.count > 1 ? parts[1] : nil)
    }

    private var collection: OrivioCollection? {
        collections.visibleCollection(ids.collection, for: profiles.active)
    }

    private var hasAllTab: Bool { (collection?.showAllTab ?? false) && (collection?.folders.count ?? 0) > 1 }

    private var tabs: [(id: String, title: String)] {
        guard let c = collection else { return [] }
        return (hasAllTab ? [(Self.allTab, "All")] : []) + c.folders.map { ($0.id, $0.title) }
    }

    private var currentTab: String? { tab ?? tabs.first?.id }
    private var currentFolder: CollectionFolder? { collection?.folders.first { $0.id == currentTab } }

    /// Titles for the open tab, before filters.
    private var raw: [MetaItem] {
        guard let c = collection else { return [] }
        if currentTab == Self.allTab {
            var seen = Set<String>()
            let lists = c.folders.map { folders[$0.id]?.items ?? [] }
            var out: [MetaItem] = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for l in lists where i < l.count && seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
            return out
        }
        return currentTab.flatMap { folders[$0]?.items } ?? []
    }

    private var shown: [MetaItem] {
        sort.apply(raw.filter { type.keep($0) && (genre == nil || $0.genres.contains(genre!)) })
    }

    private var genres: [String] {
        var seen = Set<String>()
        return raw.flatMap(\.genres).filter { seen.insert($0).inserted }.sorted()
    }

    private var isLoading: Bool {
        currentTab == Self.allTab ? allLoading : (currentTab.flatMap { folders[$0]?.loading } ?? true)
    }

    var body: some View {
        Group {
            if let c = collection {
                content(c)
            } else {
                OrivioEmptyState(icon: "square.stack.3d.up.slash", title: "Collection not found",
                                 message: "It may have been removed, or hidden for this profile.")
            }
        }
        .sheet(item: $picker) { p in pickerSheet(p) }
    }

    private func content(_ c: OrivioCollection) -> some View {
        // Derived lists once per redraw: `raw` merges every folder for "All"
        // (200 of them in a big collection) and was recomputed for each use.
        let rawList = raw
        let shownList = sort.apply(rawList.filter { type.keep($0) && (genre == nil || $0.genres.contains(genre!)) })
        let art = backdrop(c, raw: rawList)
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 34) {
                hero(c, count: rawList.count)
                strip(hasGenres: rawList.contains { !$0.genres.isEmpty })
                if let blocked = currentTab.flatMap({ folders[$0]?.blocked }) {
                    guidance(blocked)
                } else {
                    PosterGrid(items: shownList) { Task { await loadMore() } }
                    if currentTab == Self.allTab && allLoading && !rawList.isEmpty {
                        HStack(spacing: 16) { ProgressView(); Text("Loading more categories…").textStyle(.meta) }
                            .padding(.horizontal, Metrics.margin)
                    } else {
                        GridFooter(loading: isLoading, isEmpty: shownList.isEmpty,
                                   emptyIcon: "square.stack.3d.up",
                                   emptyMessage: rawList.isEmpty ? "This folder's sources returned no titles." : "No titles match these filters.")
                    }
                }
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background(heroBackdrop(art))
        .task(id: c.id) {
            if tab == nil {
                tab = ids.folder.flatMap { f in c.folders.contains { $0.id == f } ? f : nil } ?? tabs.first?.id
            }
            await openTab()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { tabFocusRequest += 1 }
        }
        .onChange(of: tab) { _, _ in
            genre = nil
            Task { await openTab() }
        }
    }

    // MARK: Hero

    private func backdrop(_ c: OrivioCollection, raw: [MetaItem]) -> String? {
        let f = currentFolder
        return f?.heroBackdropUrl ?? c.backdropImageUrl ?? f?.cover ?? raw.first?.background
    }

    private func hero(_ c: OrivioCollection, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.title).eyebrow()
            if currentTab != Self.allTab, let f = currentFolder {
                LogoOrTitle(logo: f.titleLogoUrl, title: f.title, maxSize: CGSize(width: 640, height: 200), fallbackStyle: .heroLogoFallback)
            } else {
                Text(c.title).textStyle(.heroLogoFallback).lineLimit(1).minimumScaleFactor(0.6)
            }
            if count > 0 {
                Text("\(count)\(exhaustedAll ? "" : "+") title\(count == 1 ? "" : "s")").textStyle(.meta)
            }
        }
        .padding(.horizontal, Metrics.margin)
        .frame(maxWidth: .infinity, minHeight: 470, alignment: .bottomLeading)
    }

    /// Full-bleed backdrop: fades out down the page and darkens behind the title.
    private func heroBackdrop(_ art: String?) -> some View {
        ZStack(alignment: .top) {
            ArtField(imageURL: art)
            RemoteImage(url: art, maxPixel: ImageSize.backdrop, placeholder: false)
                .frame(width: 1920, height: 760)
                .overlay(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .center))
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .id(art)
                .transition(.opacity)
        }
        .animation(Motion.pageOpen, value: art)
        .railBleed()
        .ignoresSafeArea()
    }

    private var exhaustedAll: Bool {
        guard let c = collection else { return true }
        if currentTab == Self.allTab { return c.folders.allSatisfy { folders[$0.id]?.exhausted ?? false } }
        return currentTab.flatMap { folders[$0]?.exhausted } ?? true
    }

    // MARK: Tab strip + filters

    private func strip(hasGenres: Bool) -> some View {
        let tabs = self.tabs
        let current = currentTab
        return HStack(alignment: .center) {
            if tabs.count > 1 {
                CollectionTabStrip(tabs: tabs, current: current, focusRequest: tabFocusRequest) { tab = $0 }
            } else {
                Text(tabs.first?.title ?? "").textStyle(.sectionHeader).padding(.leading, Metrics.margin)
                Spacer()
            }
            HStack(spacing: 14) {
                FilterCapsule(label: type.label) { picker = .type }
                if hasGenres { FilterCapsule(label: genre ?? "All Genres") { picker = .genre } }
                FilterCapsule(label: sort.label) { picker = .sort }
            }
            .buttonStyle(GlassCapsuleStyle(font: .system(size: 22, weight: .semibold), height: 52))
            .fixedSize()
            .layoutPriority(1)
            .padding(.trailing, Metrics.margin)
            .focusSection()
        }
    }

    @ViewBuilder private func pickerSheet(_ p: Picker) -> some View {
        switch p {
        case .type:
            OptionPickerSheet(title: "Type", options: BrowseTypeFilter.allCases.map { ($0.rawValue, $0.label) }, selected: type.rawValue) { v in
                picker = nil
                type = BrowseTypeFilter(rawValue: v) ?? .all
            }
        case .genre:
            OptionPickerSheet(title: "Genre", options: [("", "All Genres")] + genres.map { ($0, $0) }, selected: genre ?? "") { v in
                picker = nil
                genre = v.isEmpty ? nil : v
            }
        case .sort:
            OptionPickerSheet(title: "Sort", options: BrowseSort.allCases.map { ($0.rawValue, $0.label) }, selected: sort.rawValue) { v in
                picker = nil
                sort = BrowseSort(rawValue: v) ?? .standard
            }
        }
    }

    // MARK: Gating guidance (inside the folder, §6.8)

    @ViewBuilder private func guidance(_ outcome: CollectionResolver.Outcome) -> some View {
        switch outcome {
        case .needsTMDB:
            OrivioEmptyState(icon: "key.fill", title: "Connect TMDB",
                             message: "This folder pulls titles from TMDB. Add your TMDB key in Settings → Integrations.")
                .frame(height: 400)
        case .needsTrakt:
            OrivioEmptyState(icon: "link", title: "Connect Trakt",
                             message: "This folder pulls titles from Trakt. Connect it in Settings → Trakt & SIMKL.")
                .frame(height: 400)
        case .items:
            EmptyView()
        }
    }

    // MARK: Loading

    private func openTab() async {
        guard let c = collection, let t = currentTab else { return }
        if t == Self.allTab {
            let pending = c.folders.filter { (folders[$0.id]?.items.isEmpty ?? true) && folders[$0.id]?.blocked == nil && !(folders[$0.id]?.exhausted ?? false) }
            guard !pending.isEmpty, !allLoading else { return }
            allLoading = true
            await withTaskGroup(of: Void.self) { group in
                for f in pending.prefix(PerformanceProfile.collectionParallelFolders) {
                    group.addTask { await load(f) }
                }
            }
            for f in pending.dropFirst(PerformanceProfile.collectionParallelFolders) { await load(f) }
            allLoading = false
        } else if let f = c.folders.first(where: { $0.id == t }), folders[t]?.items.isEmpty ?? true {
            await load(f)
        }
    }

    private func loadMore() async {
        guard let c = collection, let t = currentTab else { return }
        if t == Self.allTab {
            guard !allLoading else { return }
            allLoading = true
            for f in c.folders where !(folders[f.id]?.exhausted ?? false) && folders[f.id]?.blocked == nil {
                await load(f)
            }
            allLoading = false
        } else if let f = c.folders.first(where: { $0.id == t }) {
            await load(f)
        }
    }

    private func load(_ f: CollectionFolder) async {
        var s = folders[f.id] ?? FolderState()
        guard !s.loading, !s.exhausted, s.blocked == nil else { return }
        s.loading = true
        folders[f.id] = s
        let outcome = await CollectionResolver.resolve(f, page: s.page)
        s = folders[f.id] ?? s
        s.loading = false
        switch outcome {
        case .items(let more):
            let seen = Set(s.items.map(\.id))
            let fresh = more.filter { !seen.contains($0.id) }.map { $0.withPoster(banners: home.value.posterBanners) }
            if fresh.isEmpty { s.exhausted = true }
            s.items += fresh
            s.page += 1
        case .needsTMDB, .needsTrakt:
            s.blocked = outcome
            s.exhausted = true
        }
        folders[f.id] = s
    }
}

/// The folder tabs. Its own view owning the focus state: kept on the page,
/// every move along the tabs rebuilt the whole page (~170 ms each on an A10X).
private struct CollectionTabStrip: View {
    let tabs: [(id: String, title: String)]
    let current: String?
    /// Bumped by the page to focus the open tab.
    let focusRequest: Int
    let select: (String) -> Void
    @FocusState private var focused: String?
    private static let eagerLimit = 16

    private var buttons: some View {
        ForEach(tabs, id: \.id) { t in
            Button(t.title) { select(t.id) }
                .buttonStyle(TextTabStyle(selected: t.id == current))
                .focused($focused, equals: t.id)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy only for big collections (100–200 folders): a lazy stack made
            // every move along the tabs cost ~170 ms of focus search on an A10X
            // (~90 ms eager), but an eager one costs on every page redraw.
            Group {
                if tabs.count <= Self.eagerLimit {
                    HStack(spacing: 8) { buttons }
                } else {
                    LazyHStack(spacing: 8) { buttons }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, Metrics.margin - 22)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .focusSection()
        .onChange(of: focusRequest) { _, _ in focused = current }
        #if DEBUG
        .onAppear { DebugLog.write("[coll] \(tabs.count) tabs") }
        #endif
    }
}
