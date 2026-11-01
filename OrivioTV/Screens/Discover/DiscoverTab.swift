import SwiftUI

/// The Discover tab: genre tiles (Genius-Browse style), trending, and genre rows
/// from the installed add-ons. Each genre opens the Discover grid.
@MainActor
final class DiscoverTabModel: ObservableObject {
    struct Section: Identifiable {
        let id: String
        let title: String
        var items: [MetaItem]
    }

    @Published private(set) var movieGenres: [String] = []
    @Published private(set) var showGenres: [String] = []
    @Published private(set) var sections: [Section] = []
    @Published private(set) var loaded = false
    private var fingerprint = ""

    func load(stores: AppStores) async {
        let fp = stores.addons.enabled.map(\.manifestURL).joined() + "\(stores.tmdb.value.isUsable)"
        guard fp != fingerprint else { return }
        fingerprint = fp
        let addons = stores.addons.enabled
        // The first catalog of each type that offers genres drives the genre tiles and rows.
        func genreCatalog(_ type: String) -> (InstalledAddon, ManifestCatalog)? {
            for a in addons {
                if let c = a.manifest.catalogs.first(where: { $0.type == type && !$0.genreOptions.isEmpty && !$0.isSearchOnly }) { return (a, c) }
            }
            return nil
        }
        let movieCat = genreCatalog("movie")
        let showCat = genreCatalog("series")
        movieGenres = movieCat?.1.genreOptions ?? []
        showGenres = showCat?.1.genreOptions ?? []

        var specs: [(String, String, () async -> [MetaItem])] = []
        if stores.tmdb.value.isUsable {
            specs.append(("trending-movies", "Trending Movies This Week", { await TMDBService.trending(tv: false) }))
            specs.append(("trending-shows", "Trending Shows This Week", { await TMDBService.trending(tv: true) }))
        }
        for (cat, type) in [(movieCat, "Movies"), (showCat, "Shows")] {
            guard let (addon, c) = cat else { continue }
            for g in c.genreOptions.prefix(5) {
                specs.append(("\(c.type)-\(g)", "\(g) \(type)", {
                    (try? await AddonClient.catalog(addon, type: c.type, id: c.id, extras: ["genre": g])) ?? []
                }))
            }
        }
        sections = specs.map { Section(id: $0.0, title: $0.1, items: []) }
        // Publish each row the moment its catalog answers. Waiting for every
        // catalog before showing anything kept Discover on "Loading…" for as
        // long as the slowest add-on, then started every poster at once.
        let banners = stores.home.value.posterBanners
        var next = 0
        await withTaskGroup(of: (Int, [MetaItem]).self) { group in
            let limit = min(PerformanceProfile.homeFetchConcurrency, specs.count)
            func addNext() {
                guard next < specs.count else { return }
                let i = next
                next += 1
                let spec = specs[i]
                group.addTask { (i, await spec.2()) }
            }
            for _ in 0..<limit { addNext() }
            while let (i, items) = await group.next() {
                addNext()
                guard i < sections.count else { continue }
                let mapped = Array(items.prefix(30)).map { $0.withPoster(banners: banners) }
                guard !mapped.isEmpty else { continue }
                var section = sections[i]
                section.items = mapped
                sections[i] = section
                ImagePipeline.shared.prefetch(mapped.prefix(6).compactMap { $0.poster.flatMap(URL.init(string:)) },
                                              maxPixel: ImageSize.poster)
            }
        }
        sections.removeAll { $0.items.isEmpty }
        loaded = true
    }
}

struct DiscoverTab: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var addons: AddonManager
    @StateObject private var model = DiscoverTabModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Discover").textStyle(.pageTitle)
                    .padding(.horizontal, Metrics.margin)
                    .padding(.top, 130)
                    .padding(.bottom, 10)
                if !model.movieGenres.isEmpty {
                    genreRow(key: "genres-movie", title: "Browse Movies", genres: model.movieGenres, type: "movie")
                }
                if !model.showGenres.isEmpty {
                    genreRow(key: "genres-series", title: "Browse Shows", genres: model.showGenres, type: "series")
                }
                ForEach(model.sections) { section in
                    FocusRow(rowKey: "discover-\(section.id)", title: section.title, items: section.items) { item, _ in
                        let actions = PlayActions(router: router)
                        Button { actions.openDetail(item, siblings: section.items) } label: { PosterCard(meta: item) }
                            .buttonStyle(FlatCardStyle())
                            .onPlayPauseCommand { actions.playManually(item) }
                            .posterHoldMenu(item) { actions.openDetail(item, siblings: section.items) }
                    }
                }
                if !model.loaded {
                    OrivioLoadingView(label: "Loading…").frame(height: 300)
                }
                Spacer().frame(height: 120)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: nil).railBleed().ignoresSafeArea())
        .task(id: addons.enabled.map(\.manifestURL).joined()) { await model.load(stores: AppStores.shared) }
    }

    private struct GenreItem: Identifiable { let id: String; let name: String }

    private func genreRow(key: String, title: String, genres: [String], type: String) -> some View {
        FocusRow(rowKey: key, title: title, items: genres.map { GenreItem(id: "\(type)-\($0)", name: $0) }) { g, _ in
            Button { router.push(.discover(type: type, genre: g.name)) } label: {
                GradientTile(title: g.name, seed: g.name, width: 220, height: 300)
            }
            .buttonStyle(FlatCardStyle(lift: 1.06))
        }
    }
}
