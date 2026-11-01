import Foundation

struct TMDBPerson: Hashable, Identifiable, Codable {
    var id: Int
    var name: String
    var role: String?
    var photo: String?
}

struct TMDBCompany: Hashable, Identifiable, Codable {
    var id: Int
    var name: String
    var logo: String?
    var isNetwork = false
}

struct TMDBVideo: Hashable, Codable {
    var key: String
    var name: String
    var type: String
    var site: String
    var official: Bool
}

/// Everything TMDB adds to a Detail page. Sections with no data are hidden.
struct TMDBEnrichment {
    var tmdbID: Int
    var imdbID: String?
    var title: String?
    var overview: String?
    var tagline: String?
    var backdrop: String?
    var poster: String?
    var logo: String?
    var genres: [String] = []
    var runtime: Int?
    var releaseDate: Date?
    var status: String?
    var certification: String?
    var countries: [String] = []
    var spokenLanguages: [String] = []
    var originalLanguage: String?
    var cast: [TMDBPerson] = []
    var creators: [TMDBPerson] = []
    var directors: [TMDBPerson] = []
    var videos: [TMDBVideo] = []
    var recommendations: [MetaItem] = []
    var collectionID: Int?
    var collectionName: String?
    var companies: [TMDBCompany] = []
    var networks: [TMDBCompany] = []
    var nextEpisodeAir: Date?
    var nextEpisodeLabel: String?
    var voteAverage: Double?

    var trailers: [TMDBVideo] {
        videos.filter { $0.site == "YouTube" && ["Trailer", "Teaser"].contains($0.type) }
            .sorted { ($0.type == "Trailer" ? 0 : 1, $0.official ? 0 : 1) < ($1.type == "Trailer" ? 0 : 1, $1.official ? 0 : 1) }
    }
}

struct TMDBEpisodeInfo: Hashable {
    var episode: Int
    var name: String
    var overview: String?
    var still: String?
    var airDate: Date?
    var rating: Double?
    var runtime: Int?
    var guestStars: [String]
}

enum TMDBService {
    private static let base = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p/"
    private static let cache = ResponseCache<Any>(capacity: 256, ttl: 6 * 3600)

    @MainActor static var settings: TMDBSettings { AppStores.shared.tmdb.value }

    static func image(_ path: String?, size: String = "w780") -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return imageBase + size + path
    }

    // MARK: Request

    private static func get(_ path: String, _ params: [String: String] = [:], key: String, language: String) async throws -> [String: Any] {
        var items = params
        items["language"] = items["language"] ?? language
        var headers: [String: String] = [:]
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 40 { headers["Authorization"] = "Bearer \(trimmed)" } else { items["api_key"] = trimmed }
        guard let url = URL(string: "\(base)\(path)?\(HTTP.query(items))") else { throw HTTPError.badURL(path) }
        let cacheKey = url.absoluteString
        if let hit = cache.get(cacheKey) as? [String: Any] { return hit }
        let obj = try await HTTP.jsonObject(HTTP.request(url, headers: headers, timeout: 15), session: HTTP.session)
        guard let dict = obj as? [String: Any] else { throw HTTPError.notJSON }
        cache.set(cacheKey, dict)
        return dict
    }

    private static func call(_ path: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        let s = await settings
        guard s.isUsable else { throw HTTPError.other("TMDB not configured") }
        return try await get(path, params, key: s.apiKey, language: s.language)
    }

    static func validate(key: String) async -> Bool {
        (try? await get("/configuration", [:], key: key, language: "en-US")) != nil
    }

    // MARK: IDs

    /// (tmdbID, isTV) for an IMDb id.
    static func find(imdbID: String) async -> (Int, Bool)? {
        guard let d = try? await call("/find/\(imdbID)", ["external_source": "imdb_id"]) else { return nil }
        if let m = (d["movie_results"] as? [[String: Any]])?.first, let id = m["id"] as? Int { return (id, false) }
        if let t = (d["tv_results"] as? [[String: Any]])?.first, let id = t["id"] as? Int { return (id, true) }
        if let e = (d["tv_episode_results"] as? [[String: Any]])?.first, let id = e["show_id"] as? Int { return (id, true) }
        return nil
    }

    static func imdbID(tmdbID: Int, isTV: Bool) async -> String? {
        guard let d = try? await call("/\(isTV ? "tv" : "movie")/\(tmdbID)/external_ids") else { return nil }
        return d["imdb_id"] as? String
    }

    /// Resolves the TMDB id of a meta (`tmdb:123`, `tt…`, or the meta's tmdbID).
    static func resolve(_ meta: MetaItem) async -> (Int, Bool)? {
        let isTV = meta.isSeries
        if let t = meta.tmdbID { return (t, isTV) }
        if meta.id.hasPrefix("tmdb:"), let n = Int(meta.id.dropFirst(5).split(separator: ":").first ?? "") { return (n, isTV) }
        if let imdb = meta.imdbID { return await find(imdbID: imdb) }
        return nil
    }

    // MARK: Details

    static func enrichment(for meta: MetaItem) async -> TMDBEnrichment? {
        guard await settings.isUsable, let (id, isTV) = await resolve(meta) else { return nil }
        let kind = isTV ? "tv" : "movie"
        let append = isTV
            ? "credits,videos,recommendations,content_ratings,images,external_ids,aggregate_credits"
            : "credits,videos,recommendations,release_dates,images,external_ids"
        let lang = await settings.language
        let langCode = String(lang.prefix(2))
        guard let d = try? await call("/\(kind)/\(id)", ["append_to_response": append,
                                                         "include_image_language": "\(langCode),en,null",
                                                         "include_video_language": "\(langCode),en,null"]) else { return nil }
        var e = TMDBEnrichment(tmdbID: id)
        e.imdbID = (d["external_ids"] as? [String: Any])?["imdb_id"] as? String ?? d["imdb_id"] as? String
        e.title = d["title"] as? String ?? d["name"] as? String
        e.overview = d["overview"] as? String
        e.tagline = d["tagline"] as? String
        e.backdrop = image(d["backdrop_path"] as? String, size: "original")
        e.poster = image(d["poster_path"] as? String, size: "w500")
        e.genres = (d["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        e.runtime = d["runtime"] as? Int ?? (d["episode_run_time"] as? [Int])?.first
        e.releaseDate = (d["release_date"] as? String ?? d["first_air_date"] as? String).flatMap(DateParsing.parse)
        e.status = d["status"] as? String
        e.voteAverage = d["vote_average"] as? Double
        e.countries = (d["production_countries"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            ?? (d["origin_country"] as? [String]) ?? []
        e.spokenLanguages = (d["spoken_languages"] as? [[String: Any]])?.compactMap { ($0["english_name"] as? String) ?? ($0["name"] as? String) } ?? []
        e.originalLanguage = d["original_language"] as? String
        if let logos = (d["images"] as? [String: Any])?["logos"] as? [[String: Any]] {
            let pick = logos.first { ($0["iso_639_1"] as? String) == langCode } ?? logos.first { ($0["iso_639_1"] as? String) == "en" } ?? logos.first
            e.logo = image(pick?["file_path"] as? String, size: "w500")
        }
        let credits = (d["aggregate_credits"] as? [String: Any]) ?? (d["credits"] as? [String: Any])
        if let cast = credits?["cast"] as? [[String: Any]] {
            // The whole cast (capped well above any real bill).
            e.cast = cast.prefix(80).compactMap { c in
                guard let pid = c["id"] as? Int, let name = c["name"] as? String else { return nil }
                let role = c["character"] as? String ?? ((c["roles"] as? [[String: Any]])?.first?["character"] as? String)
                return TMDBPerson(id: pid, name: name, role: role, photo: image(c["profile_path"] as? String, size: "w185"))
            }
        }
        if let crew = (d["credits"] as? [String: Any])?["crew"] as? [[String: Any]] {
            var seenDirectors = Set<Int>()
            e.directors = crew.filter { ($0["job"] as? String) == "Director" && seenDirectors.insert($0["id"] as? Int ?? 0).inserted }.compactMap { c in
                guard let pid = c["id"] as? Int, let name = c["name"] as? String else { return nil }
                return TMDBPerson(id: pid, name: name, role: "Director", photo: image(c["profile_path"] as? String, size: "w185"))
            }
        }
        if let created = d["created_by"] as? [[String: Any]] {
            e.creators = created.compactMap { c in
                guard let pid = c["id"] as? Int, let name = c["name"] as? String else { return nil }
                return TMDBPerson(id: pid, name: name, role: "Creator", photo: image(c["profile_path"] as? String, size: "w185"))
            }
        }
        e.videos = ((d["videos"] as? [String: Any])?["results"] as? [[String: Any]])?.compactMap { v in
            guard let key = v["key"] as? String else { return nil }
            return TMDBVideo(key: key, name: v["name"] as? String ?? "Trailer", type: v["type"] as? String ?? "",
                             site: v["site"] as? String ?? "", official: v["official"] as? Bool ?? false)
        } ?? []
        e.recommendations = ((d["recommendations"] as? [String: Any])?["results"] as? [[String: Any]])?
            .prefix(20).compactMap { metaFromResult($0, defaultTV: isTV) } ?? []
        if let coll = d["belongs_to_collection"] as? [String: Any] {
            e.collectionID = coll["id"] as? Int
            e.collectionName = coll["name"] as? String
        }
        e.companies = (d["production_companies"] as? [[String: Any]])?.compactMap { c in
            guard let cid = c["id"] as? Int, let name = c["name"] as? String else { return nil }
            return TMDBCompany(id: cid, name: name, logo: image(c["logo_path"] as? String, size: "w300"))
        } ?? []
        e.networks = (d["networks"] as? [[String: Any]])?.compactMap { c in
            guard let cid = c["id"] as? Int, let name = c["name"] as? String else { return nil }
            return TMDBCompany(id: cid, name: name, logo: image(c["logo_path"] as? String, size: "w300"), isNetwork: true)
        } ?? []
        if isTV {
            let ratings = (d["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            e.certification = (ratings.first { ($0["iso_3166_1"] as? String) == "US" } ?? ratings.first)?["rating"] as? String
            if let next = d["next_episode_to_air"] as? [String: Any] {
                e.nextEpisodeAir = (next["air_date"] as? String).flatMap(DateParsing.parse)
                if let s = next["season_number"] as? Int, let ep = next["episode_number"] as? Int {
                    e.nextEpisodeLabel = ep == 1 ? "New Season" : "New Episode"
                    _ = s
                }
            }
        } else {
            let results = (d["release_dates"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let us = results.first { ($0["iso_3166_1"] as? String) == "US" }
            let dates = us?["release_dates"] as? [[String: Any]] ?? []
            e.certification = dates.compactMap { $0["certification"] as? String }.first { !$0.isEmpty }
        }
        return e
    }

    /// A TMDB list result → a lightweight `MetaItem` (id `tmdb:<id>` until resolved).
    static func metaFromResult(_ r: [String: Any], defaultTV: Bool) -> MetaItem? {
        guard let id = r["id"] as? Int else { return nil }
        let mediaType = r["media_type"] as? String
        if mediaType == "person" { return nil }
        let isTV = mediaType.map { $0 == "tv" } ?? defaultTV
        let name = (r["title"] as? String) ?? (r["name"] as? String) ?? ""
        let date = (r["release_date"] as? String) ?? (r["first_air_date"] as? String)
        var m = MetaItem(id: "tmdb:\(id)", type: isTV ? "series" : "movie", name: name,
                         poster: image(r["poster_path"] as? String, size: "w500"),
                         background: image(r["backdrop_path"] as? String, size: "w1280"),
                         description: r["overview"] as? String,
                         releaseInfo: date.map { String($0.prefix(4)) })
        m.tmdbID = id
        if let v = r["vote_average"] as? Double, v > 0 { m.imdbRating = String(format: "%.1f", v) }
        return m
    }

    // MARK: Seasons / episodes

    static func season(tvID: Int, season: Int) async -> [TMDBEpisodeInfo] {
        guard let d = try? await call("/tv/\(tvID)/season/\(season)") else { return [] }
        return (d["episodes"] as? [[String: Any]])?.compactMap { e in
            guard let n = e["episode_number"] as? Int else { return nil }
            return TMDBEpisodeInfo(episode: n, name: e["name"] as? String ?? "", overview: e["overview"] as? String,
                                   still: image(e["still_path"] as? String, size: "w780"),
                                   airDate: (e["air_date"] as? String).flatMap(DateParsing.parse),
                                   rating: (e["vote_average"] as? Double).flatMap { $0 > 0 ? $0 : nil },
                                   runtime: e["runtime"] as? Int,
                                   guestStars: (e["guest_stars"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
        } ?? []
    }

    /// Builds the full episode list for a show from TMDB (used when the add-on sends none).
    static func episodes(tvID: Int, imdbID: String?, seasons: Int) async -> [MetaVideo] {
        let list = await boundedConcurrentMap(Array(1...max(1, seasons)), limit: 4) { s in (s, await season(tvID: tvID, season: s)) }
        let showID = imdbID ?? "tmdb:\(tvID)"
        return list.flatMap { s, eps in
            eps.map { e in
                MetaVideo(id: "\(showID):\(s):\(e.episode)", title: e.name, season: s, episode: e.episode, thumbnail: e.still,
                          overview: e.overview, released: e.airDate, rating: e.rating, runtime: e.runtime)
            }
        }
    }

    static func episodeCast(tvID: Int, season: Int, episode: Int) async -> [String] {
        guard let d = try? await call("/tv/\(tvID)/season/\(season)/episode/\(episode)/credits") else { return [] }
        let cast = (d["cast"] as? [[String: Any]] ?? []) + (d["guest_stars"] as? [[String: Any]] ?? [])
        return cast.prefix(6).compactMap { $0["name"] as? String }
    }

    static func seasonCount(tvID: Int) async -> Int {
        guard let d = try? await call("/tv/\(tvID)") else { return 1 }
        return d["number_of_seasons"] as? Int ?? 1
    }

    // MARK: Lists

    static func collection(_ id: Int) async -> (name: String, backdrop: String?, parts: [MetaItem])? {
        guard let d = try? await call("/collection/\(id)") else { return nil }
        let parts = (d["parts"] as? [[String: Any]])?.compactMap { metaFromResult($0, defaultTV: false) } ?? []
        let sorted = parts.sorted { ($0.releaseInfo ?? "9999") < ($1.releaseInfo ?? "9999") }
        return (d["name"] as? String ?? "", image(d["backdrop_path"] as? String, size: "w1280"), sorted)
    }

    struct PersonDetails {
        var id: Int
        var name: String
        var photo: String?
        var knownFor: String?
        var biography: String?
        var movies: [MetaItem]
        var shows: [MetaItem]
    }

    static func person(_ id: Int) async -> PersonDetails? {
        guard let d = try? await call("/person/\(id)", ["append_to_response": "combined_credits"]) else { return nil }
        let credits = (d["combined_credits"] as? [String: Any])?["cast"] as? [[String: Any]] ?? []
        let crew = (d["combined_credits"] as? [String: Any])?["crew"] as? [[String: Any]] ?? []
        var seen = Set<Int>()
        let all = (credits + crew).sorted { ($0["popularity"] as? Double ?? 0) > ($1["popularity"] as? Double ?? 0) }
            .filter { r in
                guard let i = r["id"] as? Int else { return false }
                return seen.insert(i).inserted
            }
        let metas = all.compactMap { metaFromResult($0, defaultTV: false) }
        return PersonDetails(id: id, name: d["name"] as? String ?? "", photo: image(d["profile_path"] as? String, size: "h632"),
                             knownFor: d["known_for_department"] as? String, biography: d["biography"] as? String,
                             movies: metas.filter { !$0.isSeries }, shows: metas.filter(\.isSeries))
    }

    /// Discover feed (`/discover/movie|tv`) with arbitrary filters.
    static func discover(tv: Bool, params: [String: String], page: Int = 1) async -> [MetaItem] {
        var p = params
        p["page"] = String(page)
        if p["sort_by"] == nil { p["sort_by"] = "popularity.desc" }
        guard let d = try? await call("/discover/\(tv ? "tv" : "movie")", p) else { return [] }
        return (d["results"] as? [[String: Any]])?.compactMap { metaFromResult($0, defaultTV: tv) } ?? []
    }

    static func company(_ id: Int, isNetwork: Bool, page: Int = 1) async -> [MetaItem] {
        if isNetwork { return await discover(tv: true, params: ["with_networks": String(id)], page: page) }
        async let movies = discover(tv: false, params: ["with_companies": String(id)], page: page)
        async let shows = discover(tv: true, params: ["with_companies": String(id)], page: page)
        let (m, s) = await (movies, shows)
        return zip2(m, s)
    }

    static func trending(tv: Bool) async -> [MetaItem] {
        guard let d = try? await call("/trending/\(tv ? "tv" : "movie")/week") else { return [] }
        return (d["results"] as? [[String: Any]])?.compactMap { metaFromResult($0, defaultTV: tv) } ?? []
    }

    static func list(path: String, tv: Bool, page: Int = 1) async -> [MetaItem] {
        guard let d = try? await call(path, ["page": String(page)]) else { return [] }
        let key = d["results"] != nil ? "results" : "items"
        return (d[key] as? [[String: Any]])?.compactMap { metaFromResult($0, defaultTV: tv) } ?? []
    }

    static func searchPeople(_ query: String) async -> [TMDBPerson] {
        guard let d = try? await call("/search/person", ["query": query]) else { return [] }
        return (d["results"] as? [[String: Any]])?.prefix(12).compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            return TMDBPerson(id: id, name: name, role: r["known_for_department"] as? String,
                              photo: image(r["profile_path"] as? String, size: "w185"))
        } ?? []
    }

    static func searchCompanies(_ query: String) async -> [TMDBCompany] {
        guard let d = try? await call("/search/company", ["query": query]) else { return [] }
        return (d["results"] as? [[String: Any]])?.prefix(20).compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            return TMDBCompany(id: id, name: name, logo: image(r["logo_path"] as? String, size: "w300"))
        } ?? []
    }

    static func searchCollections(_ query: String) async -> [(Int, String)] {
        guard let d = try? await call("/search/collection", ["query": query]) else { return [] }
        return (d["results"] as? [[String: Any]])?.prefix(20).compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            return (id, name)
        } ?? []
    }

    static func genres(tv: Bool) async -> [(Int, String)] {
        guard let d = try? await call("/genre/\(tv ? "tv" : "movie")/list") else { return [] }
        return (d["genres"] as? [[String: Any]])?.compactMap { g in
            guard let id = g["id"] as? Int, let name = g["name"] as? String else { return nil }
            return (id, name)
        } ?? []
    }

    /// Converts a `tmdb:` meta into an IMDb-keyed one so add-ons can answer it.
    static func canonicalize(_ meta: MetaItem) async -> MetaItem {
        guard meta.id.hasPrefix("tmdb:"), let tid = meta.tmdbID ?? Int(meta.id.dropFirst(5)) else { return meta }
        guard let imdb = await imdbID(tmdbID: tid, isTV: meta.isSeries), !imdb.isEmpty else { return meta }
        var m = meta
        m.id = imdb
        m.tmdbID = tid
        return m
    }

    private static func zip2(_ a: [MetaItem], _ b: [MetaItem]) -> [MetaItem] {
        var out: [MetaItem] = []
        for i in 0..<max(a.count, b.count) {
            if i < a.count { out.append(a[i]) }
            if i < b.count { out.append(b[i]) }
        }
        return out
    }
}
