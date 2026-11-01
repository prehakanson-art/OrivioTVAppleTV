import SwiftUI

@MainActor
final class DetailModel: ObservableObject {
    @Published var meta: MetaItem
    @Published private(set) var enrichment: TMDBEnrichment?
    @Published private(set) var ratings: [ExternalRating] = []
    @Published private(set) var advisories: [ParentalAdvisory] = []
    @Published private(set) var comments: [TraktComment] = []
    @Published private(set) var collectionParts: [MetaItem] = []
    @Published private(set) var episodeInfo: [Int: [Int: TMDBEpisodeInfo]] = [:]
    @Published private(set) var episodeCast: [String: [String]] = [:]
    @Published private(set) var loaded = false
    @Published var selectedSeason: Int = 1

    /// Where focus should land when this page is shown again after the
    /// viewer opened Sources or the player from it. A pushed route replaces
    /// the page, so `DetailPage`'s own `mode`/focus state is rebuilt from
    /// scratch; this is the bit that has to outlive it (the model is cached).
    struct ReturnFocus: Equatable {
        var rowID: String
        var index: Int
        var season: Int?
    }
    private(set) var pendingReturnFocus: ReturnFocus?
    /// True once the page has actually been presented. The opening zoom runs
    /// only on that first presentation — a rebuilt page (Back from Sources)
    /// must not zoom in from the Home card again.
    var hasPresented = false

    /// Remember the episode the viewer entered, so Back can return focus to
    /// that card instead of the top of the page.
    func rememberReturnFocus(video: MetaVideo?) {
        guard let video, meta.isSeries else { return }
        let season = video.season ?? selectedSeason
        let episodes = meta.episodes(season: season)
        guard let index = episodes.firstIndex(where: { $0.id == video.id }) else { return }
        pendingReturnFocus = ReturnFocus(rowID: "episodes-\(season)", index: index, season: season)
    }

    func clearReturnFocus() {
        pendingReturnFocus = nil
    }
    /// Best-sources preview (filled after a background scrape; never blocks the page).
    @Published private(set) var previewSources: [StreamEntry] = []
    @Published private(set) var sourceBadges: [String] = []

    private var previewSearch: StreamSearch?
    private var episodeCastLoading = Set<String>()

    init(meta: MetaItem) {
        self.meta = meta
    }

    var trailerKeys: [String] {
        let fromAddon = meta.trailers.map(\.source)
        let fromTMDB = enrichment?.trailers.map(\.key) ?? []
        var seen = Set<String>()
        return (fromAddon + fromTMDB).filter { seen.insert($0).inserted }
    }

    /// Cast from TVmaze / IMDb when TMDB isn't available.
    @Published private(set) var fallbackCast: [TMDBPerson] = []

    /// The whole cast (with photos and character names), then directors/creators.
    var cast: [TMDBPerson] {
        if let e = enrichment, !e.cast.isEmpty {
            let crew = (e.directors + e.creators).filter { c in !e.cast.contains { $0.id == c.id } }
            return e.cast + crew
        }
        if !fallbackCast.isEmpty { return fallbackCast }
        let directors = meta.director.map { TMDBPerson(id: 0, name: $0, role: "Director", photo: nil) }
        return meta.cast.map { TMDBPerson(id: 0, name: $0, role: nil, photo: nil) } + directors
    }

    var directors: [String] {
        if let d = enrichment?.directors, !d.isEmpty { return d.map(\.name) }
        return meta.director
    }

    var certification: String? { meta.certification ?? enrichment?.certification }

    var runtimeMinutes: Int? { meta.runtimeMinutes ?? enrichment?.runtime }

    var country: String? { meta.country ?? enrichment?.countries.first }

    var badgeText: String? {
        if let air = enrichment?.nextEpisodeAir, air > Date(), let label = enrichment?.nextEpisodeLabel {
            return "\(label) \(DateParsing.monthDay.string(from: air))"
        }
        return nil
    }

    private var loadTask: Task<Void, Never>?

    /// Shared by the page and the neighbour prefetch: runs once.
    func load() async {
        if let t = loadTask { await t.value; return }
        let t = Task { await performLoad() }
        loadTask = t
        await t.value
    }

    private func performLoad() async {
        guard !loaded else { return }
        let stores = AppStores.shared
        let full = await MetaService.fetch(meta)
        if !full.name.isEmpty { withAnimation(.easeOut(duration: 0.3)) { meta = full } }
        loaded = true
        if let first = meta.seasons.first {
            // Default to the season of the play target.
            if let target = ContinueWatchingBuilder.playTarget(meta: meta, watched: stores.watched, progress: stores.progress, home: stores.home.value),
               let s = target.0.season, s > 0 { selectedSeason = s } else { selectedSeason = first }
        }
        async let enrich = TMDBService.enrichment(for: meta)
        async let comments = Secrets.traktClientID.isEmpty ? [] : TraktService.comments(for: meta)
        let e = await enrich
        if let e {
            enrichment = e
            var m = meta
            if m.logo == nil { m.logo = e.logo }
            if m.background == nil { m.background = e.backdrop }
            if (m.description ?? "").isEmpty { m.description = e.overview }
            if m.genres.isEmpty { m.genres = e.genres }
            if m.tmdbID == nil { m.tmdbID = e.tmdbID }
            if m != meta { meta = m }
            if let cid = e.collectionID, let c = await TMDBService.collection(cid) {
                collectionParts = c.parts.filter { $0.tmdbID != e.tmdbID }
            }
            if meta.isSeries { await loadSeasonInfo(selectedSeason) }
        }
        self.comments = await comments
        if enrichment?.cast.isEmpty ?? true {
            fallbackCast = await CastService.cast(for: meta)
        }
        if let imdb = meta.imdbID {
            if stores.mdblist.value.isUsable {
                ratings = await MDBListService.ratings(imdbID: imdb, isSeries: meta.isSeries, apiKey: stores.mdblist.value.apiKey)
            }
            if stores.player.value.parentalGuide { advisories = await ParentalGuideService.guide(imdbID: imdb) }
        }
    }

    func loadSeasonInfo(_ season: Int) async {
        guard episodeInfo[season] == nil, let tid = enrichment?.tmdbID ?? meta.tmdbID, meta.isSeries else { return }
        let eps = await TMDBService.season(tvID: tid, season: season)
        episodeInfo[season] = Dictionary(eps.map { ($0.episode, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func loadEpisodeCast(_ v: MetaVideo) {
        guard let tid = enrichment?.tmdbID ?? meta.tmdbID, let s = v.season, let e = v.episode,
              episodeCast[v.id] == nil, !episodeCastLoading.contains(v.id) else { return }
        episodeCastLoading.insert(v.id)
        Task {
            let cast = await TMDBService.episodeCast(tvID: tid, season: s, episode: e)
            episodeCast[v.id] = cast
        }
    }

    func rating(for v: MetaVideo) -> Double? {
        if let r = v.rating { return r }
        guard let s = v.season, let e = v.episode else { return nil }
        return episodeInfo[s]?[e]?.rating
    }

    /// Starts the background scrape that feeds the "Sources" preview section.
    func startSourcePreview(video: MetaVideo?) {
        guard previewSearch == nil else { return }
        let search = StreamSearch(meta: meta, video: video)
        previewSearch = search
        search.onEntries = { [weak self, weak search] _ in
            guard let self, let search else { return }
            let settings = AppStores.shared.player.value
            let ranked = SourceFilters.apply(search.entries, settings: settings).sorted { $0.sourceScore > $1.sourceScore }
            self.previewSources = Array(ranked.prefix(3))
            var badges: [String] = []
            if search.entries.contains(where: { $0.resolutionLabel == "2160p" }) { badges.append("4K") }
            if search.entries.contains(where: { $0.traits.isDolbyVision }) { badges.append("Dolby Vision") }
            else if search.entries.contains(where: { $0.traits.isHDR }) { badges.append("HDR10") }
            if search.entries.contains(where: { $0.traits.hasAtmos }) { badges.append("Dolby Atmos") }
            self.sourceBadges = badges
        }
        search.start()
    }

    func stopPreview() {
        previewSearch?.cancel()
        // A search cut short may run again when the page is current again.
        previewSearch = nil
    }
}

/// Recently shown Detail models (so paging back is instant) and prefetched
/// neighbours (so paging forward is too).
@MainActor
final class DetailModelCache {
    static let shared = DetailModelCache()
    private var models: [String: DetailModel] = [:]
    private var order: [String] = []
    private let capacity = 8

    func model(for meta: MetaItem) -> DetailModel {
        if let m = models[meta.id] {
            touch(meta.id)
            return m
        }
        let m = DetailModel(meta: meta)
        insert(m, id: meta.id)
        return m
    }

    /// Loads neighbours' metadata and warms their backdrop and logo.
    func prefetch(_ metas: [MetaItem]) {
        for meta in metas {
            let m = model(for: meta)
            Task { await m.load() }
            let urls = [meta.background ?? meta.poster].compactMap { $0 }.compactMap(URL.init(string:))
            ImagePipeline.shared.prefetch(urls, maxPixel: ImageSize.backdrop)
            if let logo = meta.logo, let u = URL(string: logo) { ImagePipeline.shared.prefetch([u], maxPixel: ImageSize.logo) }
        }
    }

    /// A card rested on (Home): load its details, then look up its trailer, so
    /// opening it finds both ready (the trailer lookup alone can take ~8 s).
    func warm(_ meta: MetaItem) {
        guard meta.type == "movie" || meta.type == "series" else { return }
        let m = model(for: meta)
        Task {
            await m.load()
            if AppStores.shared.player.value.detailTrailerDelay >= 0, !m.trailerKeys.isEmpty {
                TrailerService.prefetch(m.trailerKeys)
            }
        }
    }

    private func insert(_ m: DetailModel, id: String) {
        models[id] = m
        touch(id)
        while order.count > capacity, let old = order.first {
            order.removeFirst()
            models[old] = nil
        }
    }

    private func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
