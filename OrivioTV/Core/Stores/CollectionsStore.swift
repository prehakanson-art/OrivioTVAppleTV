import Foundation

/// TMDB discover filters (wire-compatible with Android).
struct TmdbFilters: Codable, Hashable {
    var withGenres: String?
    var releaseDateGte: String?
    var releaseDateLte: String?
    var voteAverageGte: Double?
    var voteAverageLte: Double?
    var voteCountGte: Int?
    var withOriginalLanguage: String?
    var withOriginCountry: String?
    var withKeywords: String?
    var withCompanies: String?
    var withNetworks: String?
    var year: Int?
    var watchRegion: String?
    var withWatchProviders: String?
    var recentDays: Int?

    var params: [String: String] {
        var p: [String: String] = [:]
        p["with_genres"] = withGenres
        p["with_original_language"] = withOriginalLanguage
        p["with_origin_country"] = withOriginCountry
        p["with_keywords"] = withKeywords
        p["with_companies"] = withCompanies
        p["with_networks"] = withNetworks
        p["watch_region"] = watchRegion
        p["with_watch_providers"] = withWatchProviders
        if let v = voteAverageGte { p["vote_average.gte"] = String(v) }
        if let v = voteAverageLte { p["vote_average.lte"] = String(v) }
        if let v = voteCountGte { p["vote_count.gte"] = String(v) }
        if let y = year { p["primary_release_year"] = String(y); p["first_air_date_year"] = String(y) }
        if let d = releaseDateGte { p["primary_release_date.gte"] = d; p["first_air_date.gte"] = d }
        if let d = releaseDateLte { p["primary_release_date.lte"] = d; p["first_air_date.lte"] = d }
        if let days = recentDays, let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            let s = DateParsing.day.string(from: since)
            p["primary_release_date.gte"] = s
            p["first_air_date.gte"] = s
        }
        return p
    }
}

/// One source feeding a folder: an add-on catalog, a TMDB source or a Trakt list/endpoint.
struct CollectionSource: Codable, Hashable {
    var provider: String = "addon"
    var addonId: String?
    var type: String?
    var catalogId: String?
    var genre: String?
    /// LIST / COLLECTION / COMPANY / NETWORK / DISCOVER / PERSON / DIRECTOR
    var tmdbSourceType: String?
    var title: String?
    var tmdbId: Int?
    var traktListId: Int64?
    var traktEndpoint: String?
    var traktQuery: String?
    var mediaType: String?
    var sortBy: String?
    var sortHow: String?
    var filters: TmdbFilters?

    var isAddon: Bool { provider.lowercased() == "addon" }
    var isTMDB: Bool { provider.lowercased() == "tmdb" }
    var isTrakt: Bool { provider.lowercased() == "trakt" }

    static func addon(_ addonId: String, type: String, catalogId: String, genre: String? = nil) -> CollectionSource {
        CollectionSource(provider: "addon", addonId: addonId, type: type, catalogId: catalogId, genre: genre)
    }

    static func tmdb(_ kind: String, title: String, id: Int?, mediaType: String = "movie", sortBy: String? = nil, filters: TmdbFilters? = nil) -> CollectionSource {
        CollectionSource(provider: "tmdb", tmdbSourceType: kind, title: title, tmdbId: id, mediaType: mediaType, sortBy: sortBy, filters: filters)
    }

    static func traktEndpoint(_ path: String, title: String, mediaType: String) -> CollectionSource {
        CollectionSource(provider: "trakt", title: title, traktEndpoint: path, mediaType: mediaType)
    }

    static func traktList(_ id: Int64, title: String, mediaType: String = "movie") -> CollectionSource {
        CollectionSource(provider: "trakt", title: title, traktListId: id, mediaType: mediaType, sortBy: "rank", sortHow: "asc")
    }

    var label: String {
        if let title, !title.isEmpty { return title }
        if isAddon { return [catalogId, genre].compactMap { $0 }.joined(separator: " · ") }
        return provider.capitalized
    }
}

struct CollectionFolder: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var coverImageUrl: String?
    var customCoverImageUrl: String?
    var coverEmoji: String?
    /// Focus artwork: an animated GIF / WebP (or a still) that replaces the
    /// cover while the tile is focused. nil `focusGifEnabled` = on when a URL is set.
    var focusGifUrl: String?
    var focusGifEnabled: Bool?
    /// Carried for Android (not drawn on tvOS) — kept so syncing never drops it.
    var heroVideoUrl: String?
    /// Xperience names most folder art only by slug ("streaming_services.netflix")
    /// in a cover set; the image lives on its CDN.
    var defaultCoverSlug: String?
    var coverSetId: String?
    /// SQUARE | POSTER | LANDSCAPE
    var tileShape: String = "SQUARE"
    var hideTitle: Bool = false
    var sources: [CollectionSource]?
    /// Legacy add-on-only field.
    var catalogSources: [CollectionSource]?
    var heroBackdropUrl: String?
    var titleLogoUrl: String?

    var effectiveSources: [CollectionSource] {
        if let sources, !sources.isEmpty { return sources }
        return catalogSources ?? []
    }

    var cover: String? {
        if let c = coverImageUrl, !c.isEmpty { return c }
        if let c = customCoverImageUrl, !c.isEmpty { return c }
        // Slug-only art (366 of 434 folders in a real Xperience export).
        guard let slug = defaultCoverSlug, Self.isCoverName(slug, allowDots: true) else { return nil }
        let set = coverSetId.flatMap { Self.isCoverName($0, allowDots: false) ? $0 : nil } ?? "default"
        return "https://cdn.xperience-app.com/covers/\(set)/\(slug).webp"
    }

    /// The focus artwork to show, if any.
    var focusArt: String? {
        guard focusGifEnabled != false, let u = focusGifUrl, !u.isEmpty else { return nil }
        return u
    }

    /// Cover names are lowercase letters, digits, underscores (and dots in a
    /// slug) — nothing else can end up spliced into the URL.
    private static let coverNameCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
    private static func isCoverName(_ name: String, allowDots: Bool) -> Bool {
        !name.isEmpty && name.allSatisfy { coverNameCharacters.contains($0) || (allowDots && $0 == ".") }
    }

    var needsTMDB: Bool { effectiveSources.contains(where: \.isTMDB) }
    var needsTrakt: Bool { effectiveSources.contains(where: \.isTrakt) }

    init(id: String = UUID().uuidString, title: String) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.string(AnyKey("id")) ?? UUID().uuidString
        title = c.string(AnyKey("title")) ?? ""
        coverImageUrl = c.string(AnyKey("coverImageUrl"))
        customCoverImageUrl = c.string(AnyKey("customCoverImageUrl"))
        coverEmoji = c.string(AnyKey("coverEmoji"))
        focusGifUrl = c.string(AnyKey("focusGifUrl"))
        focusGifEnabled = c.bool(AnyKey("focusGifEnabled"))
        heroVideoUrl = c.string(AnyKey("heroVideoUrl"))
        defaultCoverSlug = c.string(AnyKey("defaultCoverSlug"))
        coverSetId = c.string(AnyKey("coverSetId"))
        tileShape = c.string(AnyKey("tileShape")) ?? "SQUARE"
        hideTitle = c.bool(AnyKey("hideTitle")) ?? false
        let s = c.lossyArray(CollectionSource.self, AnyKey("sources"))
        sources = s.isEmpty ? nil : s
        let cs = c.lossyArray(CollectionSource.self, AnyKey("catalogSources"))
        catalogSources = cs.isEmpty ? nil : cs
        heroBackdropUrl = c.string(AnyKey("heroBackdropUrl"))
        titleLogoUrl = c.string(AnyKey("titleLogoUrl"))
    }
}

struct OrivioCollection: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var backdropImageUrl: String?
    var pinToTop: Bool = false
    var focusGlowEnabled: Bool?
    /// ROWS | TABBED_GRID | COMBINED | CUSTOM
    var viewMode: String = "ROWS"
    var showAllTab: Bool = true
    var folders: [CollectionFolder] = []

    init(id: String = UUID().uuidString, title: String) {
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.string(AnyKey("id")) ?? UUID().uuidString
        title = c.string(AnyKey("title")) ?? ""
        backdropImageUrl = c.string(AnyKey("backdropImageUrl"))
        pinToTop = c.bool(AnyKey("pinToTop")) ?? false
        focusGlowEnabled = c.bool(AnyKey("focusGlowEnabled"))
        viewMode = c.string(AnyKey("viewMode")) ?? "ROWS"
        showAllTab = c.bool(AnyKey("showAllTab")) ?? true
        folders = c.lossyArray(CollectionFolder.self, AnyKey("folders"))
    }

    var isRows: Bool { viewMode.uppercased() == "ROWS" }
}

/// User-built collections. The library is **file-backed**
/// (`Library/Caches/OrivioCache/collections-library.json`, ~700 KB) — not
/// UserDefaults. Visibility is per profile (Edit Profile → Collections).
@MainActor
final class CollectionsStore: ObservableObject {
    @Published private(set) var library: [OrivioCollection] = [] {
        didSet { visibleCache = nil }
    }
    private(set) var removed = Tombstones()
    /// `visible(for:)` copies and filters the whole library (~700 KB of
    /// collections); views call it many times per redraw, so it's memoised
    /// until the library or the profile's hidden sets change.
    private var visibleCache: (key: Int, list: [OrivioCollection])?
    private let fileURL = Persistence.fileURL("collections-library.json")
    private let removedKey = Persistence.key("collections.removed.v2")

    init() {
        library = Persistence.loadFile([OrivioCollection].self, url: fileURL) ?? []
        removed = Persistence.load(Tombstones.self, key: removedKey) ?? Tombstones()
    }

    private func save(markDirty: Bool = true) {
        // A collection tree (folders, covers, sources) is one of the larger
        // blobs the app writes; keep it off the main thread.
        Persistence.saveFileInBackground(library, url: fileURL)
        Persistence.saveInBackground(removed, key: removedKey, compressed: false)
        if markDirty { SyncSignals.markDirty(.collections) }
    }

    /// Collections the active profile sees, pinned first.
    func visible(for profile: Profile) -> [OrivioCollection] {
        var h = Hasher()
        h.combine(profile.id)
        h.combine(profile.hiddenCollections)
        h.combine(profile.hiddenFolders)
        let key = h.finalize()
        if let c = visibleCache, c.key == key { return c.list }
        let list = computeVisible(for: profile)
        visibleCache = (key, list)
        return list
    }

    /// One visible collection (cheap: served from the memo).
    func visibleCollection(_ id: String, for profile: Profile) -> OrivioCollection? {
        visible(for: profile).first { $0.id == id }
    }

    private func computeVisible(for profile: Profile) -> [OrivioCollection] {
        let hidden = Set(profile.hiddenCollections)
        let hiddenFolders = Set(profile.hiddenFolders)
        let list = library.filter { !hidden.contains($0.id) }.map { c -> OrivioCollection in
            var c = c
            c.folders = c.folders.filter { !hiddenFolders.contains($0.id) }
            return c
        }
        return list.filter(\.pinToTop) + list.filter { !$0.pinToTop }
    }

    func collection(_ id: String) -> OrivioCollection? { library.first { $0.id == id } }

    @discardableResult
    func create(title: String) -> OrivioCollection {
        let c = OrivioCollection(title: title.isEmpty ? "New Collection" : title)
        library.append(c)
        save()
        return c
    }

    func update(_ c: OrivioCollection) {
        guard let i = library.firstIndex(where: { $0.id == c.id }) else { return }
        library[i] = c
        save()
    }

    func delete(_ id: String) {
        library.removeAll { $0.id == id }
        removed.add(id)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(library.count - 1, i + delta))
        guard i != j else { return }
        let c = library.remove(at: i)
        library.insert(c, at: j)
        save()
    }

    func applyRemote(_ remote: [OrivioCollection]) {
        removed.retire(absentFrom: Set(remote.map(\.id)))
        let next = remote.filter { !removed.contains($0.id) }
        // Unchanged (most sync passes): no publish, no disk write — each one
        // redrew every watching screen and rewrote the file on the main thread.
        guard next != library else { return }
        library = next
        save(markDirty: false)
    }
}

/// Resolves a folder's sources into titles.
@MainActor
enum CollectionResolver {
    enum Outcome {
        case items([MetaItem])
        case needsTMDB
        case needsTrakt
    }

    static func resolve(_ folder: CollectionFolder, page: Int = 0) async -> Outcome {
        let sources = folder.effectiveSources
        let tmdbOK = AppStores.shared.tmdb.value.isUsable
        let traktOK = !Secrets.traktClientID.isEmpty
        if !sources.isEmpty, sources.allSatisfy({ $0.isTMDB }), !tmdbOK { return .needsTMDB }
        if !sources.isEmpty, sources.allSatisfy({ $0.isTrakt }), !traktOK { return .needsTrakt }
        let lists = await boundedConcurrentMap(sources, limit: PerformanceProfile.collectionParallelFolders) { src in
            await items(for: src, page: page, tmdbOK: tmdbOK, traktOK: traktOK)
        }
        var seen = Set<String>()
        var out: [MetaItem] = []
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for l in lists where i < l.count {
                if seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
        }
        return .items(out)
    }

    static func items(for src: CollectionSource, page: Int, tmdbOK: Bool, traktOK: Bool) async -> [MetaItem] {
        if src.isAddon {
            guard let addonId = src.addonId,
                  let addon = AppStores.shared.addons.enabled.first(where: { $0.manifest.id == addonId || $0.manifestURL == addonId }),
                  let type = src.type, let cat = src.catalogId else { return [] }
            var extras: [String: String] = [:]
            if let g = src.genre { extras["genre"] = g }
            if page > 0 { extras["skip"] = String(page * 100) }
            return (try? await AddonClient.catalog(addon, type: type, id: cat, extras: extras)) ?? []
        }
        if src.isTMDB, tmdbOK {
            let tv = (src.mediaType ?? "movie") == "tv" || src.mediaType == "series"
            let p = page + 1
            switch (src.tmdbSourceType ?? "DISCOVER").uppercased() {
            case "COLLECTION":
                guard let id = src.tmdbId else { return [] }
                return page == 0 ? (await TMDBService.collection(id)?.parts ?? []) : []
            case "COMPANY":
                guard let id = src.tmdbId else { return [] }
                return await TMDBService.discover(tv: tv, params: ["with_companies": String(id), "sort_by": src.sortBy ?? "popularity.desc"], page: p)
            case "NETWORK":
                guard let id = src.tmdbId else { return [] }
                return await TMDBService.discover(tv: true, params: ["with_networks": String(id), "sort_by": src.sortBy ?? "popularity.desc"], page: p)
            case "PERSON", "DIRECTOR":
                guard let id = src.tmdbId, page == 0, let person = await TMDBService.person(id) else { return [] }
                return tv ? person.shows : person.movies + person.shows
            case "LIST":
                guard let id = src.tmdbId else { return [] }
                return await TMDBService.list(path: "/list/\(id)", tv: tv, page: p)
            default:
                var params = src.filters?.params ?? [:]
                if let s = src.sortBy { params["sort_by"] = s }
                return await TMDBService.discover(tv: tv, params: params, page: p)
            }
        }
        if src.isTrakt, traktOK {
            let type = (src.mediaType ?? "movie") == "movie" ? "movie" : "series"
            if let listID = src.traktListId { return await TraktService.listItems(listID: listID, page: page + 1) }
            if let ep = src.traktEndpoint { return await TraktService.endpointItems(path: ep, query: src.traktQuery, type: type, page: page + 1) }
        }
        return []
    }
}
