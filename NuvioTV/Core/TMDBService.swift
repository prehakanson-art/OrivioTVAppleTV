import Foundation

/// TMDB settings, mirroring the Android `TmdbSettings`. Persisted locally;
/// governs metadata enrichment and whether TMDB collection sources resolve.
struct TMDBSettings: Codable, Equatable {
    var enabled: Bool = false
    var enrichContinueWatching: Bool = true
    var language: String = "en"
    // Granular enrichment toggles (mirror Android's per-section TMDB switches).
    var useCredits: Bool = true
    var useTrailers: Bool = true
    var useMoreLikeThis: Bool = true
    /// Country / spoken-language detail fields.
    var useDetails: Bool = true
    /// Release-date field.
    var useReleaseDates: Bool = true
    /// Production companies row.
    var useProductions: Bool = true
    /// Collection ("part of…") row and its parts.
    var useCollections: Bool = true
    /// Per-episode ratings + air dates.
    var useEpisodes: Bool = true

    static let `default` = TMDBSettings()
}

@MainActor
final class TMDBSettingsStore: ObservableObject {
    @Published var settings: TMDBSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            TMDBService.preferredLanguage = settings.language
            if !applyingRemote { onLocalChange?() }
        }
    }

    /// Fired on a local (user-driven) change so the sync manager can push it up.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let key = "nuvio.tmdb.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TMDBSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        // Localize every TMDB request from launch (get() reads this global).
        TMDBService.preferredLanguage = settings.language
    }

    /// Apply settings pulled from the account without echoing them back up.
    func applyRemote(_ new: TMDBSettings) {
        guard new != settings else { return }
        applyingRemote = true
        settings = new
        applyingRemote = false
    }

    var isEnabled: Bool { settings.enabled }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Thin TMDB v3 client. The API key is a client-embedded value recovered from
/// the official app (same key the Android build ships in BuildConfig); TMDB v3
/// keys are designed to live in the client. Used to resolve TMDB collection
/// sources into MetaItems and to map TMDB ids to IMDB ids so those items flow
/// through the existing Cinemeta detail/stream pipeline.
enum TMDBService {
    /// TMDB API key — supplied via Secrets (gitignored).
    static let apiKey = Secrets.tmdbAPIKey
    private static let base = "https://api.themoviedb.org/3"
    private static let imageBase = "https://image.tmdb.org/t/p"

    /// Plain "yyyy-MM-dd" for TMDB's date-range discover params. Fixed UTC/
    /// POSIX locale so it never reflects the device's calendar/locale.
    private static let isoDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        return URLSession(configuration: config)
    }()

    // Cache TMDB→IMDB id lookups so repeated collection loads stay cheap.
    // Guarded by `cacheLock` — these caches are read/written from many
    // concurrent `Task`s (catalog rows map items in parallel), and a plain
    // Swift Dictionary is not thread-safe (concurrent mutation → EXC_BAD_ACCESS).
    private static let cacheLock = NSLock()
    private static var imdbCache: [String: String] = [:]

    private static func cachedIMDB(_ key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return imdbCache[key]
    }
    private static func storeIMDB(_ value: String, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        imdbCache[key] = value
    }
    private static func cachedFind(_ key: String) -> (Int, Bool)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return findCache[key]
    }
    private static func storeFind(_ value: (Int, Bool), for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        findCache[key] = value
    }

    enum TMDBError: LocalizedError {
        case badResponse(Int)
        case missing
        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "TMDB returned HTTP \(code)"
            case .missing: return "TMDB item not found"
            }
        }
    }

    /// Preferred content language (ISO-639-1), kept in sync with the TMDB
    /// language setting so EVERY request is localized — not just the calls
    /// that happened to thread a `language:` argument. Set once at launch and
    /// on change by TMDBSettingsStore.
    nonisolated(unsafe) static var preferredLanguage = "en"

    private static func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: base + path)!
        var items = [URLQueryItem(name: "api_key", value: apiKey)]
        // Localize any request that didn't specify a language explicitly.
        if query["language"] == nil, preferredLanguage != "en" {
            items.append(URLQueryItem(name: "language", value: preferredLanguage))
        }
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TMDBError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func imageURL(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "\(imageBase)/\(size)\(path)"
    }

    /// Upgrade a stored TMDB image URL (…/t/p/w500/…) to full-resolution
    /// `original`, so brand logos render crisp on a big TV. Non-TMDB URLs (and
    /// already-`original` ones) pass through untouched.
    static func originalSize(_ urlString: String?) -> String? {
        guard let urlString, urlString.contains("image.tmdb.org") else { return urlString }
        return urlString.replacingOccurrences(
            of: "/t/p/w[0-9]+/", with: "/t/p/original/", options: .regularExpression)
    }

    // MARK: - ID mapping

    /// Map a TMDB id to an IMDB tt id via /external_ids. Cached; nil on failure.
    static func imdbID(tmdbID: Int, isMovie: Bool) async -> String? {
        let cacheKey = "\(isMovie ? "m" : "t"):\(tmdbID)"
        if let hit = cachedIMDB(cacheKey) { return hit.isEmpty ? nil : hit }
        let path = isMovie ? "/movie/\(tmdbID)/external_ids" : "/tv/\(tmdbID)/external_ids"
        struct ExternalIDs: Decodable { let imdb_id: String? }
        let imdb = (try? await get(path) as ExternalIDs)?.imdb_id
        storeIMDB(imdb ?? "", for: cacheKey)
        return imdb?.isEmpty == false ? imdb : nil
    }

    // MARK: - Collection source discovery (editor: search / id lookup)

    struct CompanySearchResult: Identifiable, Hashable {
        let id: Int
        let name: String
        let logoURL: String?
    }

    /// TMDB has no company-name matching in `/search/company` beyond substring,
    /// but that's exactly what the editor needs to let a user find "Marvel" etc.
    static func searchCompanies(_ query: String) async -> [CompanySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        struct Response: Decodable {
            struct Item: Decodable { let id: Int; let name: String; let logo_path: String? }
            let results: [Item]
        }
        guard let body: Response = try? await get("/search/company", query: ["query": trimmed]) else { return [] }
        return body.results.prefix(20).map {
            CompanySearchResult(id: $0.id, name: $0.name, logoURL: imageURL($0.logo_path, size: "w300"))
        }
    }

    struct PersonSearchResult: Identifiable, Hashable {
        let id: Int
        let name: String
        let profileURL: String?
        let knownFor: String?
    }

    static func searchPeople(_ query: String) async -> [PersonSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int; let name: String; let profile_path: String?
                let known_for_department: String?
            }
            let results: [Item]
        }
        guard let body: Response = try? await get("/search/person", query: ["query": trimmed]) else { return [] }
        return body.results.prefix(20).map {
            PersonSearchResult(id: $0.id, name: $0.name,
                               profileURL: imageURL($0.profile_path, size: "w300"),
                               knownFor: $0.known_for_department)
        }
    }

    /// TMDB has no network SEARCH endpoint — only lookup by id (matches
    /// Android, which requires the id and fetches the name for confirmation).
    static func networkName(id: Int) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/network/\(id)") as Response)?.name
    }

    struct BrandInfo { let name: String; let logoURL: String? }

    /// Network name + logo (for Community Collections tiles — official HQ art,
    /// fetched live so it's never stale even if TMDB reshuffles a logo).
    /// Widest logo variant (ratio ≥ 1.5) from a company/network's alternative
    /// logos. Some brands' PRIMARY mark is squarish (Warner Bros' shield,
    /// ratio ~1.1), which lands a mismatched square tile in an otherwise
    /// landscape row — but TMDB usually also hosts the wide wordmark banner
    /// (WB's is 1280×331). Highest-resolution wide variant wins; nil when the
    /// brand has no wide logo at all.
    static func brandWideLogo(id: Int, isNetwork: Bool) async -> String? {
        struct ImagesResponse: Decodable { let logos: [Logo]? }
        struct Logo: Decodable { let file_path: String?; let aspect_ratio: Double?; let width: Int? }
        let path = isNetwork ? "/network/\(id)/images" : "/company/\(id)/images"
        guard let body: ImagesResponse = try? await get(path, query: [:]) else { return nil }
        return (body.logos ?? [])
            .filter { ($0.aspect_ratio ?? 0) >= 1.5 }
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first
            .flatMap { imageURL($0.file_path, size: "w500") }
    }

    static func networkBrand(id: Int) async -> BrandInfo? {
        struct Response: Decodable { let name: String?; let logo_path: String? }
        guard let body: Response = try? await get("/network/\(id)"), let name = body.name else { return nil }
        return BrandInfo(name: name, logoURL: imageURL(body.logo_path, size: "w500"))
    }

    /// Company name + logo, same purpose as `networkBrand` for studios.
    static func companyBrand(id: Int) async -> BrandInfo? {
        struct Response: Decodable { let name: String?; let logo_path: String? }
        guard let body: Response = try? await get("/company/\(id)"), let name = body.name else { return nil }
        return BrandInfo(name: name, logoURL: imageURL(body.logo_path, size: "w500"))
    }

    static func collectionName(id: Int, language: String) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/collection/\(id)", query: ["language": language]) as Response)?.name
    }

    static func listName(id: Int, language: String) async -> String? {
        struct Response: Decodable { let name: String? }
        return (try? await get("/list/\(id)", query: ["language": language]) as Response)?.name
    }

    /// Parse a bare numeric id, or the id embedded in a themoviedb.org URL
    /// (`/list/123-slug`, `/collection/456-slug`) — mirrors the Android app's
    /// tolerant input so pasting either a URL or a plain id works.
    static func parseTMDBID(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed) { return n }
        guard let range = trimmed.range(of: #"(?:list|collection)/(\d+)"#, options: .regularExpression) else {
            // Fall back to the first run of digits anywhere in the string.
            let digits = trimmed.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        let match = String(trimmed[range])
        let digits = match.drop { !$0.isNumber }
        return Int(digits)
    }

    // MARK: - Collection source resolution

    /// Resolve a TMDB collection source into MetaItems. Each item's id is its
    /// IMDB tt id (resolved best-effort so it plays through Cinemeta); items
    /// whose IMDB id can't be resolved fall back to a `tmdb:<id>` id and still
    /// display. `language` comes from TMDB settings (ISO-639-1).
    /// `maxPages` caps how many TMDB discover pages are fetched. The collection
    /// BROWSE page wants the full catalog (default = unlimited), but Home rows
    /// only need ~one page of posters, so they pass maxPages: 1 to avoid firing
    /// hundreds of requests per folder on every Home load.
    /// `startPage` lets a caller fetch a WINDOW of pages (startPage ..<
    /// startPage+maxPages) instead of always starting at 1, so a big catalog
    /// can be streamed into the grid in chunks rather than assembled in full
    /// before anything appears. Only DISCOVER/COMPANY/NETWORK are paged; the
    /// other source types return their whole (small) result on the first call.
    static func resolve(source: CollectionSourceDTO, language: String, maxPages: Int = Int.max,
                        startPage: Int = 1) async -> [MetaItem] {
        guard source.provider.lowercased() == "tmdb",
              let sourceType = source.tmdbSourceType?.uppercased() else { return [] }
        let mediaIsMovie = (source.mediaType ?? "movie").lowercased() != "tv"
        let raw: [TMDBRawItem]
        do {
            switch sourceType {
            case "LIST":
                // Unpaged sources have already been returned in full by the
                // first window; later windows must not repeat them.
                raw = startPage > 1 ? [] : (try await resolveList(id: source.tmdbId, language: language))
            case "COLLECTION":
                raw = startPage > 1 ? [] : (try await resolveCollection(id: source.tmdbId, language: language))
            case "COMPANY", "NETWORK", "DISCOVER":
                raw = try await resolveDiscover(source: source, sourceType: sourceType, isMovie: mediaIsMovie, language: language, maxPages: maxPages, startPage: startPage)
            case "PERSON", "DIRECTOR":
                raw = startPage > 1 ? [] : (try await resolvePerson(id: source.tmdbId, director: sourceType == "DIRECTOR", isMovie: mediaIsMovie, language: language))
            default:
                raw = []
            }
        } catch {
            return []
        }
        return await mapToMetaItems(raw)
    }

    /// A TMDB entity flattened to the fields we need before IMDB resolution.
    private struct TMDBRawItem {
        let tmdbID: Int
        let isMovie: Bool
        let name: String
        let poster: String?
        let background: String?
        let description: String?
        let releaseInfo: String?
        let rating: Double?
        var genres: [String]? = nil
    }

    /// TMDB's genre id→name lists are small and effectively fixed — hardcoded
    /// here instead of an extra `/genre/movie|tv/list` round-trip per resolve.
    private static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Science Fiction", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    ]
    private static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 10762: "Kids", 9648: "Mystery",
        10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
        10767: "Talk", 10768: "War & Politics", 37: "Western",
    ]

    private static func mapToMetaItems(_ raw: [TMDBRawItem]) async -> [MetaItem] {
        // Resolve IMDB ids concurrently (capped) so the whole folder loads fast.
        var resolved: [(Int, String?)] = []
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, item) in raw.prefix(40).enumerated() {
                group.addTask {
                    (index, await imdbID(tmdbID: item.tmdbID, isMovie: item.isMovie))
                }
            }
            for await pair in group { resolved.append(pair) }
        }
        let imdbByIndex = Dictionary(resolved, uniquingKeysWith: { a, _ in a })
        return raw.enumerated().map { index, item in
            let id = imdbByIndex[index].flatMap { $0 } ?? "tmdb:\(item.tmdbID)"
            return MetaItem(
                id: id,
                type: item.isMovie ? "movie" : "series",
                name: item.name,
                poster: item.poster,
                background: item.background,
                logo: nil,
                description: item.description,
                releaseInfo: item.releaseInfo,
                imdbRating: item.rating.map { String(format: "%.1f", $0) },
                genres: item.genres
            )
        }
    }

    // MARK: - Endpoint helpers

    private static func resolveList(id: Int?, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct ListResponse: Decodable { let items: [ListItem]? }
        struct ListItem: Decodable {
            let id: Int
            let title: String?; let name: String?
            let media_type: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        let body: ListResponse = try await get("/list/\(id)", query: ["language": language])
        return (body.items ?? []).compactMap { item in
            let isMovie = (item.media_type?.lowercased() ?? "movie") != "tv"
            guard let title = item.title ?? item.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: item.id, isMovie: isMovie, name: title,
                poster: imageURL(item.poster_path, size: "w500") ?? imageURL(item.backdrop_path, size: "w780"),
                background: imageURL(item.backdrop_path, size: "w1280"),
                description: item.overview,
                releaseInfo: (item.release_date ?? item.first_air_date).map { String($0.prefix(4)) },
                rating: item.vote_average
            )
        }
    }

    private static func resolveCollection(id: Int?, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct CollectionResponse: Decodable { let parts: [Part]? }
        struct Part: Decodable {
            let id: Int; let title: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let vote_average: Double?
        }
        let body: CollectionResponse = try await get("/collection/\(id)", query: ["language": language])
        return (body.parts ?? []).compactMap { part in
            guard let title = part.title, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: part.id, isMovie: true, name: title,
                poster: imageURL(part.poster_path, size: "w500") ?? imageURL(part.backdrop_path, size: "w780"),
                background: imageURL(part.backdrop_path, size: "w1280"),
                description: part.overview,
                releaseInfo: part.release_date.map { String($0.prefix(4)) },
                rating: part.vote_average
            )
        }
    }

    private static func resolveDiscover(source: CollectionSourceDTO, sourceType: String, isMovie: Bool, language: String, maxPages: Int = Int.max, startPage: Int = 1) async throws -> [TMDBRawItem] {
        let f = source.filters
        // NETWORK forces TV, because TMDB's with_networks filter is TV-only —
        // UNLESS a watch-provider override is present. Watch-provider data
        // works for movies too, so a network preset with one lets mediaType
        // drive movie vs TV instead of being stuck TV-only, which is why every
        // streaming-service category only ever showed shows, never movies.
        let hasWatchProviderOverride = f?.withWatchProviders?.isEmpty == false
        let useTV = (sourceType == "NETWORK" && !hasWatchProviderOverride) ? true : !isMovie
        var baseQuery: [String: String] = [
            "language": language,
            "sort_by": source.sortBy?.isEmpty == false ? source.sortBy! : "popularity.desc"
        ]
        if sourceType == "COMPANY" {
            // `filters.withCompanies` (pipe-separated, OR-match) overrides the
            // single tmdbId when set — some franchises are legally fragmented
            // across several TMDB company records (e.g. "DC Films" alone is
            // only ~17 titles; DC Films + DC Entertainment combined is the
            // real ~70-title DC catalog), so one company id badly undercounts
            // them. Plain single-studio collections (Pixar, A24, etc.) are
            // already complete under their one id and don't set this.
            if let multi = f?.withCompanies, !multi.isEmpty {
                baseQuery["with_companies"] = multi
            } else if let tid = source.tmdbId {
                baseQuery["with_companies"] = String(tid)
            }
        }
        if let v = f?.withGenres { baseQuery["with_genres"] = v }
        if let v = f?.withKeywords { baseQuery["with_keywords"] = v }
        if let v = f?.withOriginalLanguage { baseQuery["with_original_language"] = v }
        // Streaming-service filtering (Netflix, Hulu, Apple TV+, …): both keys
        // are required together by TMDB. Limit to subscription/flatrate offers.
        if let providers = f?.withWatchProviders, !providers.isEmpty {
            baseQuery["with_watch_providers"] = providers
            baseQuery["watch_region"] = (f?.watchRegion?.isEmpty == false) ? f!.watchRegion! : "US"
            baseQuery["with_watch_monetization_types"] = "flatrate"
        }
        if let v = f?.voteCountGte { baseQuery["vote_count.gte"] = String(v) }
        if let v = f?.voteAverageGte { baseQuery["vote_average.gte"] = String(v) }
        if let v = f?.year { baseQuery[useTV ? "first_air_date_year" : "year"] = String(v) }
        // "Newest Releases": a rolling window computed fresh THIS call (not a
        // fixed date, which would go stale), sorted by popularity instead of
        // release date. Verified live that plain sort_by=primary_release_date
        // surfaces unreleased 2029-2099 placeholder entries with zero votes —
        // not watchable "newest releases" at all.
        if let days = f?.recentDays, days > 0 {
            let today = Date()
            let past = Calendar.current.date(byAdding: .day, value: -days, to: today) ?? today
            let dateField = useTV ? "first_air_date" : "primary_release_date"
            baseQuery["\(dateField).lte"] = Self.isoDateOnly.string(from: today)
            baseQuery["\(dateField).gte"] = Self.isoDateOnly.string(from: past)
            baseQuery["sort_by"] = "popularity.desc"
        }
        if sourceType == "NETWORK", let tid = source.tmdbId, !hasWatchProviderOverride {
            baseQuery["with_networks"] = String(tid)
        }

        struct DiscoverResponse: Decodable { let results: [Result]?; let total_pages: Int? }
        struct Result: Decodable {
            let id: Int; let title: String?; let name: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?; let genre_ids: [Int]?
        }
        let path = useTV ? "/discover/tv" : "/discover/movie"
        let genreMap = useTV ? tvGenres : movieGenres
        // Retries a page on a 429 (brief backoff, a few attempts) since we now
        // routinely issue far more requests than before; any other failure
        // just skips that page rather than blocking the whole fetch.
        func fetchPage(_ page: Int) async -> DiscoverResponse? {
            var q = baseQuery
            q["page"] = String(page)
            for attempt in 0..<3 {
                do {
                    return try await get(path, query: q) as DiscoverResponse
                } catch TMDBError.badResponse(429) {
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                } catch {
                    return nil
                }
            }
            return nil
        }

        // TMDB paginates discover results at 20/page and hard-caps the
        // endpoint itself at page 500 (10,000 results) — beyond that TMDB's
        // own API refuses the request, so 500 is TMDB's ceiling, not one we're
        // imposing. Fetch every page up to whichever is smaller so a category
        // shows its FULL TMDB catalog (this was previously capped much lower,
        // which is why large studios/networks looked incomplete). Batched in
        // chunks so a network with hundreds of pages doesn't fire them all
        // simultaneously — kinder to TMDB's rate limit and to the device.
        let tmdbPageCeiling = 500
        let batchSize = 20
        // Window: pages [startPage, startPage + maxPages).
        guard let first = await fetchPage(startPage) else { return [] }
        var allResults = first.results ?? []
        let available = min(first.total_pages ?? 1, tmdbPageCeiling)
        let totalPages = maxPages == Int.max ? available
            : min(available, startPage + max(1, maxPages) - 1)
        var page = startPage + 1
        while page <= totalPages {
            let upper = min(page + batchSize - 1, totalPages)
            await withTaskGroup(of: (Int, [Result]).self) { group in
                for p in page...upper {
                    group.addTask { (p, (await fetchPage(p))?.results ?? []) }
                }
                var byPage: [Int: [Result]] = [:]
                for await (p, results) in group { byPage[p] = results }
                for p in page...upper { allResults.append(contentsOf: byPage[p] ?? []) }
            }
            page = upper + 1
        }

        return allResults.compactMap { r in
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            let genres = r.genre_ids?.compactMap { genreMap[$0] }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: !useTV, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "w1280"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average,
                genres: (genres?.isEmpty == false) ? genres : nil
            )
        }
    }

    private static func resolvePerson(id: Int?, director: Bool, isMovie: Bool, language: String) async throws -> [TMDBRawItem] {
        guard let id else { throw TMDBError.missing }
        struct CreditsResponse: Decodable { let cast: [Credit]?; let crew: [Credit]? }
        struct Credit: Decodable {
            let id: Int; let title: String?; let name: String?
            let media_type: String?; let job: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        let body: CreditsResponse = try await get("/person/\(id)/combined_credits", query: ["language": language])
        let credits = director
            ? (body.crew ?? []).filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
            : (body.cast ?? [])
        let wantTV = !isMovie
        return credits.compactMap { c in
            let credIsTV = (c.media_type?.lowercased() == "tv")
            guard credIsTV == wantTV else { return nil }
            guard let title = c.title ?? c.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: c.id, isMovie: !credIsTV, name: title,
                poster: imageURL(c.poster_path, size: "w500") ?? imageURL(c.backdrop_path, size: "w780"),
                background: imageURL(c.backdrop_path, size: "w1280"),
                description: c.overview,
                releaseInfo: (c.release_date ?? c.first_air_date).map { String($0.prefix(4)) },
                rating: c.vote_average
            )
        }
    }

    // MARK: - Detail enrichment (cast, more-like-this, collection)

    /// A cast member with a headshot, used on the Detail screen and clickable
    /// through to a Cast Detail filmography.
    struct CastMember: Identifiable, Hashable {
        let id: Int
        let name: String
        let character: String?
        let profileURL: String?
    }

    /// A movie collection ("belongs to") reference from TMDB.
    struct CollectionRef: Hashable {
        let id: Int
        let name: String
        let backdropURL: String?
    }

    /// A production company / network with a logo.
    struct Company: Identifiable, Hashable {
        let id: Int
        let name: String
        let logoURL: String
    }

    /// Per-episode extras (rating, air date, better still) keyed by episode
    /// number, resolved from a TMDB season.
    struct EpisodeExtra: Hashable {
        let rating: Double?
        let airDate: String?
        let still: String?
    }

    /// A YouTube trailer/teaser. `youtubeKey` feeds the stream extractor.
    struct Trailer: Identifiable, Hashable {
        let id: String        // TMDB video id
        let name: String
        let youtubeKey: String
        var thumbnailURL: String { "https://img.youtube.com/vi/\(youtubeKey)/hqdefault.jpg" }
    }

    /// Everything the Detail screen pulls from TMDB in one call.
    struct Detail {
        var cast: [CastMember] = []
        var crew: [CastMember] = []      // director + writers, shown first in "Creator and Cast"
        var moreLikeThis: [MetaItem] = []
        var collection: CollectionRef?
        var companies: [Company] = []
        var trailers: [Trailer] = []
        var director: String?
        var country: String?             // primary production country name
        var language: String?            // spoken/original language, uppercased ISO (e.g. "EN")
        var releaseDate: String?         // ISO date for the localized full-date meta line
    }

    // Cache imdb→(tmdbID,isMovie) resolutions from /find.
    private static var findCache: [String: (Int, Bool)] = [:]

    /// Resolve a MetaItem id to a TMDB id. Handles `tt…` (imdb, via /find),
    /// `tmdb:<n>`, and returns nil for id schemes TMDB can't map.
    static func resolveTMDBID(from id: String, type: String) async -> (id: Int, isMovie: Bool)? {
        let wantMovie = !(type == "series" || type == "tv")
        if id.hasPrefix("tmdb:") {
            guard let n = Int(id.dropFirst("tmdb:".count)) else { return nil }
            return (n, wantMovie)
        }
        guard id.hasPrefix("tt") else { return nil }
        if let hit = cachedFind(id) { return hit }
        struct FindResponse: Decodable {
            struct M: Decodable { let id: Int }
            let movie_results: [M]?
            let tv_results: [M]?
        }
        guard let body: FindResponse = try? await get("/find/\(id)", query: ["external_source": "imdb_id"]) else { return nil }
        let result: (Int, Bool)?
        if wantMovie, let m = body.movie_results?.first { result = (m.id, true) }
        else if let t = body.tv_results?.first { result = (t.id, false) }
        else if let m = body.movie_results?.first { result = (m.id, true) }
        else { result = nil }
        if let result { storeFind(result, for: id) }
        return result
    }

    /// Pull cast (with headshots), recommendations/similar, and collection for
    /// a title in a single append_to_response call. Best-effort: returns nil on
    /// any failure so callers keep their Cinemeta fallbacks.
    static func detail(imdbID: String, type: String, language: String = preferredLanguage) async -> Detail? {
        guard let (tmdbID, isMovie) = await resolveTMDBID(from: imdbID, type: type) else { return nil }
        struct DetailResponse: Decodable {
            struct Credits: Decodable { let cast: [CastDTO]?; let crew: [CrewDTO]? }
            struct CastDTO: Decodable {
                let id: Int; let name: String; let character: String?; let profile_path: String?
            }
            struct CrewDTO: Decodable {
                let id: Int; let name: String; let job: String?; let profile_path: String?
            }
            struct RecoResponse: Decodable { let results: [RecoItem]? }
            struct RecoItem: Decodable {
                let id: Int; let title: String?; let name: String?; let media_type: String?
                let poster_path: String?; let backdrop_path: String?
                let overview: String?; let release_date: String?; let first_air_date: String?
                let vote_average: Double?
            }
            struct BelongsTo: Decodable { let id: Int; let name: String; let backdrop_path: String? }
            struct CompanyDTO: Decodable { let id: Int; let name: String; let logo_path: String? }
            struct CountryDTO: Decodable { let iso_3166_1: String?; let name: String? }
            struct Videos: Decodable { let results: [VideoDTO]? }
            struct VideoDTO: Decodable {
                let id: String; let key: String; let name: String
                let site: String?; let type: String?; let official: Bool?
            }
            let credits: Credits?
            let recommendations: RecoResponse?
            let similar: RecoResponse?
            let belongs_to_collection: BelongsTo?
            let production_companies: [CompanyDTO]?
            let production_countries: [CountryDTO]?
            let original_language: String?
            let release_date: String?
            let first_air_date: String?
            let videos: Videos?
        }
        let path = isMovie ? "/movie/\(tmdbID)" : "/tv/\(tmdbID)"
        guard let body: DetailResponse = try? await get(
            path, query: ["language": language, "append_to_response": "credits,recommendations,similar,videos"]
        ) else { return nil }

        var detail = Detail()
        detail.cast = (body.credits?.cast ?? []).prefix(24).map {
            CastMember(id: $0.id, name: $0.name, character: $0.character,
                       profileURL: imageURL($0.profile_path, size: "w300"))
        }
        // Director + writers first (shown ahead of the cast in "Creator and Cast").
        let crew = body.credits?.crew ?? []
        let importantJobs = ["Director", "Writer", "Screenplay", "Creator"]
        detail.crew = crew
            .filter { importantJobs.contains($0.job ?? "") }
            .prefix(4)
            .map { CastMember(id: $0.id, name: $0.name, character: $0.job,
                              profileURL: imageURL($0.profile_path, size: "w300")) }
        detail.director = crew.first { $0.job == "Director" }?.name
            ?? crew.first { $0.job == "Creator" }?.name
        detail.country = body.production_countries?.first?.name
        detail.language = body.original_language?.uppercased()
        detail.releaseDate = body.release_date ?? body.first_air_date
        let recoResults = (body.recommendations?.results?.isEmpty == false)
            ? body.recommendations?.results
            : body.similar?.results
        let raw = (recoResults ?? []).compactMap { r -> TMDBRawItem? in
            let itemIsTV = (r.media_type?.lowercased() == "tv") || (!isMovie && r.media_type == nil)
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: !itemIsTV, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "w1280"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average
            )
        }
        detail.moreLikeThis = await mapToMetaItems(raw)
        if let bt = body.belongs_to_collection {
            detail.collection = CollectionRef(id: bt.id, name: bt.name,
                                              backdropURL: imageURL(bt.backdrop_path, size: "w780"))
        }
        detail.companies = (body.production_companies ?? []).compactMap { c in
            guard let logo = imageURL(c.logo_path, size: "w300") else { return nil }
            return Company(id: c.id, name: c.name, logoURL: logo)
        }
        // YouTube trailers/teasers, official first, "Trailer" before "Teaser".
        let videos = (body.videos?.results ?? []).filter {
            ($0.site?.caseInsensitiveCompare("YouTube") == .orderedSame)
                && ["Trailer", "Teaser"].contains($0.type ?? "")
        }
        detail.trailers = videos
            .sorted { a, b in
                if (a.official ?? false) != (b.official ?? false) { return (a.official ?? false) }
                return (a.type == "Trailer" ? 0 : 1) < (b.type == "Trailer" ? 0 : 1)
            }
            .map { Trailer(id: $0.id, name: $0.name, youtubeKey: $0.key) }
        return detail
    }

    /// Per-episode extras for a season, keyed by episode number. Used to show
    /// ratings + air dates on the Detail episode row. Best-effort.
    static func seasonEpisodes(imdbID: String, type: String, season: Int) async -> [Int: EpisodeExtra] {
        guard let (tmdbID, _) = await resolveTMDBID(from: imdbID, type: type) else { return [:] }
        struct SeasonResponse: Decodable {
            struct Episode: Decodable {
                let episode_number: Int?
                let vote_average: Double?
                let air_date: String?
                let still_path: String?
            }
            let episodes: [Episode]?
        }
        guard let body: SeasonResponse = try? await get("/tv/\(tmdbID)/season/\(season)") else { return [:] }
        var map: [Int: EpisodeExtra] = [:]
        for ep in body.episodes ?? [] {
            guard let n = ep.episode_number else { continue }
            map[n] = EpisodeExtra(
                rating: (ep.vote_average ?? 0) > 0 ? ep.vote_average : nil,
                airDate: ep.air_date,
                still: imageURL(ep.still_path, size: "w300")
            )
        }
        return map
    }

    /// The parts of a TMDB collection as MetaItems (for the "belongs to" row).
    static func collectionItems(id: Int, language: String = preferredLanguage) async -> [MetaItem] {
        guard let raw = try? await resolveCollection(id: id, language: language) else { return [] }
        return await mapToMetaItems(raw)
    }

    /// Browse a production company's catalog (movies + TV), most-popular first.
    /// Backs the TMDB entity-browse screen reached from a company logo.
    static func browseCompany(id: Int, language: String = preferredLanguage) async -> [MetaItem] {
        async let movies = discover(path: "/discover/movie", with: ["with_companies": String(id)], isMovie: true, language: language)
        async let tv = discover(path: "/discover/tv", with: ["with_companies": String(id)], isMovie: false, language: language)
        let raw = (await movies) + (await tv)
        let sorted = raw.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        return await mapToMetaItems(Array(sorted.prefix(40)))
    }

    /// Whether a genre NAME is known for movies / TV (so callers can decide which
    /// media type(s) to query for a Categories genre).
    static func hasMovieGenre(_ name: String) -> Bool { movieGenres.values.contains(name) }
    static func hasTVGenre(_ name: String) -> Bool { tvGenres.values.contains(name) }

    /// ONE page of a genre's catalog (movies or TV), popularity-desc. Paginated
    /// so a browse grid can keep appending pages until the genre is exhausted.
    static func titlesByGenre(name: String, isMovie: Bool, page: Int, language: String = preferredLanguage) async -> [MetaItem] {
        let map = isMovie ? movieGenres : tvGenres
        guard let id = map.first(where: { $0.value == name })?.key else { return [] }
        let path = isMovie ? "/discover/movie" : "/discover/tv"
        let raw = await discover(path: path,
                                 with: ["with_genres": String(id), "sort_by": "popularity.desc", "page": String(page)],
                                 isMovie: isMovie, language: language)
        return await mapToMetaItems(raw)
    }

    private static func discover(path: String, with extra: [String: String], isMovie: Bool, language: String) async -> [TMDBRawItem] {
        var query = ["language": language, "page": "1", "sort_by": "popularity.desc"]
        extra.forEach { query[$0.key] = $0.value }
        struct DiscoverResponse: Decodable { let results: [Result]? }
        struct Result: Decodable {
            let id: Int; let title: String?; let name: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        guard let body: DiscoverResponse = try? await get(path, query: query) else { return [] }
        return (body.results ?? []).compactMap { r in
            guard let title = r.title ?? r.name, !title.isEmpty else { return nil }
            return TMDBRawItem(
                tmdbID: r.id, isMovie: isMovie, name: title,
                poster: imageURL(r.poster_path, size: "w500") ?? imageURL(r.backdrop_path, size: "w780"),
                background: imageURL(r.backdrop_path, size: "w1280"),
                description: r.overview,
                releaseInfo: (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) },
                rating: r.vote_average
            )
        }
    }

    /// A person's full filmography (cast credits, movies + TV), most-acclaimed
    /// first. Used by the Cast Detail screen.
    static func personFilmography(personID: Int, language: String = preferredLanguage) async -> [MetaItem] {
        struct CreditsResponse: Decodable { let cast: [Credit]? }
        struct Credit: Decodable {
            let id: Int; let title: String?; let name: String?; let media_type: String?
            let poster_path: String?; let backdrop_path: String?
            let overview: String?; let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        guard let body: CreditsResponse = try? await get(
            "/person/\(personID)/combined_credits", query: ["language": language]
        ) else { return [] }
        var seen = Set<Int>()
        let raw: [TMDBRawItem] = (body.cast ?? [])
            .sorted { ($0.vote_average ?? 0) > ($1.vote_average ?? 0) }
            .compactMap { c in
                let isTV = c.media_type?.lowercased() == "tv"
                guard let title = c.title ?? c.name, !title.isEmpty, seen.insert(c.id).inserted else { return nil }
                return TMDBRawItem(
                    tmdbID: c.id, isMovie: !isTV, name: title,
                    poster: imageURL(c.poster_path, size: "w500") ?? imageURL(c.backdrop_path, size: "w780"),
                    background: imageURL(c.backdrop_path, size: "w1280"),
                    description: c.overview,
                    releaseInfo: (c.release_date ?? c.first_air_date).map { String($0.prefix(4)) },
                    rating: c.vote_average
                )
            }
        return await mapToMetaItems(Array(raw.prefix(40)))
    }
}
