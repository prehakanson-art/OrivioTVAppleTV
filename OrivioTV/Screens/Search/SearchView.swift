import SwiftUI

/// §6.5 / §16.9 Search: the tvOS keyboard; idle = Trending + Browse; results =
/// Top Result, Movies, Shows, People. 350 ms debounce, min 2 characters.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var movies: [MetaItem] = []
    @Published private(set) var shows: [MetaItem] = []
    @Published private(set) var people: [TMDBPerson] = []
    @Published private(set) var topResult: MetaItem?
    @Published private(set) var searching = false
    @Published private(set) var searchedQuery = ""
    @Published private(set) var trending: [MetaItem] = []
    @Published private(set) var genres: [String] = []

    private var task: Task<Void, Never>?

    func queryChanged() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            movies = []; shows = []; people = []; topResult = nil; searchedQuery = ""; searching = false
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.run(q)
        }
    }

    private func run(_ q: String) async {
        searching = true
        movies = []; shows = []; people = []; topResult = nil
        searchedQuery = q
        let stores = AppStores.shared
        let banners = stores.home.value.posterBanners
        let catalogs = stores.addons.searchCatalogs
        if stores.tmdb.value.isUsable {
            Task { [weak self] in
                let p = await TMDBService.searchPeople(q)
                guard let self, self.searchedQuery == q else { return }
                self.people = Array(p.filter { $0.photo != nil }.prefix(20))
            }
        }
        await withTaskGroup(of: [MetaItem].self) { group in
            for (addon, cat) in catalogs {
                group.addTask {
                    (try? await AddonClient.catalog(addon, type: cat.type, id: cat.id, extras: ["search": q], timeout: 15)) ?? []
                }
            }
            // Publish as each add-on answers; exact matches first within each new batch only.
            for await batch in group {
                guard !Task.isCancelled, searchedQuery == q else { return }
                let fresh = batch.map { $0.withPoster(banners: banners) }
                merge(fresh, query: q)
            }
        }
        if searchedQuery == q { searching = false }
    }

    private func merge(_ batch: [MetaItem], query q: String) {
        let lower = q.lowercased()
        let sorted = batch.sorted { a, b in
            (a.name.lowercased() == lower ? 0 : 1) < (b.name.lowercased() == lower ? 0 : 1)
        }
        var m = movies, s = shows
        var seen = Set(m.map(\.id) + s.map(\.id))
        for item in sorted where seen.insert(item.id).inserted {
            if item.type == "movie" { m.append(item) } else if item.type == "series" || item.type == "anime" { s.append(item) }
        }
        movies = m
        shows = s
        if topResult == nil || topResult?.name.lowercased() != lower {
            let exact = (m + s).first { $0.name.lowercased() == lower }
            topResult = exact ?? topResult ?? (m + s).first
        }
    }

    /// Trending from Cinemeta's popular catalogs (not whichever add-on is first).
    func loadIdle() async {
        guard trending.isEmpty else { return }
        let stores = AppStores.shared
        let addons = stores.addons.enabled.sorted { a, _ in a.isCinemeta }
        guard let addon = addons.first(where: { $0.manifest.catalogs.contains { $0.id == "top" } }) ?? addons.first else { return }
        let cats = addon.manifest.catalogs.filter { !$0.requiresExtra && !$0.isSearchOnly }
        let picks = cats.filter { $0.id == "top" }.isEmpty ? Array(cats.prefix(2)) : cats.filter { $0.id == "top" }
        var all: [MetaItem] = []
        for c in picks {
            let items = (try? await AddonClient.catalog(addon, type: c.type, id: c.id)) ?? []
            all.append(contentsOf: items.prefix(15))
        }
        // Interleave movies and shows.
        let mv = all.filter { $0.type == "movie" }, sh = all.filter { $0.type != "movie" }
        var mixed: [MetaItem] = []
        for i in 0..<max(mv.count, sh.count) {
            if i < mv.count { mixed.append(mv[i]) }
            if i < sh.count { mixed.append(sh[i]) }
        }
        trending = mixed.map { $0.withPoster(banners: stores.home.value.posterBanners) }
        genres = picks.first(where: { $0.type == "movie" })?.genreOptions ?? picks.first?.genreOptions ?? []
    }
}

struct SearchView: View {
    @StateObject private var model = SearchModel()
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var focusedArt: String?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 50) {
                    if model.searchedQuery.isEmpty { idle } else { results }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .searchable(text: $model.query, prompt: "Movies, Shows and People")
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .toolbar(.hidden, for: .navigationBar)
            .modifier(ClearNavigationBackground())
        }
        // Clear the collapsed nav capsule at the top-left.
        .padding(.top, 96)
        // One continuous page: the ambient (and the focused result's art) behind
        // everything, including the strip above the search field.
        .background {
            ZStack {
                Color.clear
                if appearance.value.artworkTint, let art = focusedArt {
                    ArtField(imageURL: art).opacity(0.4).transition(.opacity)
                }
            }
            .animation(Motion.artField, value: focusedArt)
            .railBleed()
            .ignoresSafeArea()
        }
        .task { await model.loadIdle() }
    }

    // MARK: Idle

    @ViewBuilder private var idle: some View {
        if !model.trending.isEmpty {
            row("Trending", items: model.trending)
        }
        if !model.genres.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToCards) {
                SectionHeader(title: "Browse").padding(.horizontal, Metrics.margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(model.genres, id: \.self) { g in
                            Button { router.push(.discover(type: "movie", genre: g)) } label: {
                                GradientTile(title: g, seed: g, width: 300, height: 170)
                            }
                            .buttonStyle(FlatCardStyle())
                        }
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if let top = model.topResult {
            VStack(alignment: .leading, spacing: Metrics.headerToCards) {
                SectionHeader(title: "Top Result").padding(.horizontal, Metrics.margin)
                let actions = PlayActions(router: router)
                Button { actions.openDetail(top) } label: { TopResultCard(meta: top) }
                    .buttonStyle(FlatCardStyle(lift: 1.04))
                    .onPlayPauseCommand { actions.playManually(top) }
                    .posterHoldMenu(top) { actions.openDetail(top) }
                    .padding(.horizontal, Metrics.margin)
                    .modifier(ArtOnFocus(url: top.background, art: $focusedArt))
            }
        }
        if !model.movies.isEmpty { row("Movies", items: model.movies) }
        if !model.shows.isEmpty { row("Shows", items: model.shows) }
        if !model.people.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.headerToCards) {
                SectionHeader(title: "People").padding(.horizontal, Metrics.margin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(model.people) { p in
                            Button { router.push(.person(p.id, p.name)) } label: {
                                CastCircle(name: p.name, role: p.role, photo: p.photo)
                            }
                            .buttonStyle(BareFocusStyle())
                        }
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
        if model.searching && model.movies.isEmpty && model.shows.isEmpty {
            OrivioLoadingView(label: "Searching…").frame(maxWidth: .infinity).frame(height: 300)
        } else if !model.searching && model.movies.isEmpty && model.shows.isEmpty && model.people.isEmpty {
            OrivioEmptyState(icon: "magnifyingglass", title: "No results", message: "Nothing matched “\(model.searchedQuery)”.")
                .frame(maxWidth: .infinity).frame(height: 360)
        }
    }

    private func row(_ title: String, items: [MetaItem]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCards) {
            SectionHeader(title: title).padding(.horizontal, Metrics.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        let actions = PlayActions(router: router)
                        Button { actions.openDetail(item, siblings: items) } label: { PosterCard(meta: item, width: 220) }
                            .buttonStyle(FlatCardStyle())
                            .onPlayPauseCommand { actions.playManually(item) }
                            .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
                            .modifier(ArtOnFocus(url: item.background ?? item.poster, art: $focusedArt))
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
    }
}

/// Reports a focused card's art for the background field.
private struct ArtOnFocus: ViewModifier {
    let url: String?
    @Binding var art: String?
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).onChange(of: focused) { _, f in if f { art = url } }
    }
}

/// The 540×300 landscape Top Result card.
private struct TopResultCard: View {
    let meta: MetaItem
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: meta.background ?? meta.poster, maxPixel: ImageSize.landscape)
                .frame(width: 540, height: 300)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 300, height: 90), fallbackStyle: .cardTitle)
                MetaLine(parts: [meta.typeLabel, meta.year ?? "", meta.genres.first ?? ""], rating: meta.imdbRating, style: .caption)
            }
            .padding(22)
        }
        .frame(width: 540, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous))
    }
}

/// The search screen's NavigationStack paints an opaque background; clear it so
/// the page shows the app's ambient like every other tab.
private struct ClearNavigationBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(ClearHostBackground())
    }
}

/// Walks up to the hosting navigation controller and clears its views' backgrounds.
private struct ClearHostBackground: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Probe() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Probe: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            clear()
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { self.clear() }
        }
        private func clear() {
            view.backgroundColor = .clear
            var vc: UIViewController? = parent
            while let c = vc {
                c.view.backgroundColor = .clear
                if let nav = c as? UINavigationController {
                    nav.view.backgroundColor = .clear
                    nav.viewControllers.forEach { $0.view.backgroundColor = .clear }
                    break
                }
                vc = c.parent
            }
        }
    }
}
