import Foundation

struct MetaLink: Codable, Hashable {
    var name: String
    var category: String
    var url: String?

    init(name: String, category: String, url: String? = nil) {
        self.name = name
        self.category = category
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string(AnyKey("name")) ?? ""
        category = c.string(AnyKey("category")) ?? ""
        url = c.string(AnyKey("url"))
    }
}

struct MetaTrailer: Codable, Hashable {
    var source: String
    var type: String?
    var title: String?

    init(source: String, type: String? = "Trailer", title: String? = nil) {
        self.source = source
        self.type = type
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        source = c.string(AnyKey("source")) ?? c.string(AnyKey("ytId")) ?? ""
        type = c.string(AnyKey("type"))
        title = c.string(AnyKey("title")) ?? c.string(AnyKey("name"))
    }
}

/// An episode.
struct MetaVideo: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var season: Int?
    var episode: Int?
    var thumbnail: String?
    var overview: String?
    var released: Date?
    var originalSeason: Int?
    var originalEpisode: Int?
    var rating: Double?
    var runtime: Int?

    init(id: String, title: String, season: Int?, episode: Int?, thumbnail: String? = nil, overview: String? = nil,
         released: Date? = nil, originalSeason: Int? = nil, originalEpisode: Int? = nil, rating: Double? = nil, runtime: Int? = nil) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.released = released
        self.originalSeason = originalSeason
        self.originalEpisode = originalEpisode
        self.rating = rating
        self.runtime = runtime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.string(AnyKey("id")) ?? UUID().uuidString
        title = c.string(AnyKey("title")) ?? c.string(AnyKey("name")) ?? ""
        season = c.int(AnyKey("season"))
        episode = c.int(AnyKey("episode")) ?? c.int(AnyKey("number"))
        thumbnail = c.string(AnyKey("thumbnail"))
        overview = c.string(AnyKey("overview")) ?? c.string(AnyKey("description"))
        if let s = c.string(AnyKey("released")) ?? c.string(AnyKey("firstAired")) {
            released = DateParsing.parse(s)
        } else if let d = try? c.decodeIfPresent(Date.self, forKey: AnyKey("released")) {
            released = d
        }
        originalSeason = c.int(AnyKey("originalSeason"))
        originalEpisode = c.int(AnyKey("originalEpisode"))
        rating = c.double(AnyKey("rating"))
        runtime = c.int(AnyKey("runtime"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encodeIfPresent(season, forKey: AnyKey("season"))
        try c.encodeIfPresent(episode, forKey: AnyKey("episode"))
        try c.encodeIfPresent(thumbnail, forKey: AnyKey("thumbnail"))
        try c.encodeIfPresent(overview, forKey: AnyKey("overview"))
        if let released { try c.encode(DateParsing.iso.string(from: released), forKey: AnyKey("released")) }
        try c.encodeIfPresent(originalSeason, forKey: AnyKey("originalSeason"))
        try c.encodeIfPresent(originalEpisode, forKey: AnyKey("originalEpisode"))
        try c.encodeIfPresent(rating, forKey: AnyKey("rating"))
        try c.encodeIfPresent(runtime, forKey: AnyKey("runtime"))
    }

    var hasAired: Bool {
        guard let released else { return true }
        return released <= Date()
    }

    var seasonEpisodeCode: String {
        guard let s = season, let e = episode else { return title }
        return "S\(s):E\(e)"
    }

    var isSpecial: Bool { (season ?? 1) == 0 }

    var airedText: String? {
        guard let released else { return nil }
        return DateParsing.mediumDisplay.string(from: released)
    }

    /// "Today", "Tomorrow", "in 3 days", or a date — for unaired episodes.
    var airCountdownText: String? {
        guard let released, released > Date() else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: released)).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Tomorrow"
        case 2...13: return "in \(days) days"
        default: return DateParsing.mediumDisplay.string(from: released)
        }
    }

    /// Compact pill text ("Today", "5d").
    var countdownPill: String? {
        guard let released, released > Date() else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: released)).day ?? 0
        return days <= 0 ? "Today" : "\(days)d"
    }

    var episodeLine: String {
        let t = title.isEmpty ? "Episode \(episode ?? 0)" : title
        return "\(seasonEpisodeCode) · \(t)"
    }
}

struct MetaItem: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var posterFallback: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var released: Date?
    var imdbRating: String?
    var runtime: String?
    var genres: [String]
    var cast: [String]
    var director: [String]
    var writer: [String]
    var country: String?
    var language: String?
    var certification: String?
    var awards: String?
    var website: String?
    var trailers: [MetaTrailer]
    var links: [MetaLink]
    var videos: [MetaVideo]
    var defaultVideoId: String?
    var posterShape: String?
    var tmdbID: Int?

    init(id: String, type: String, name: String, poster: String? = nil, posterFallback: String? = nil,
         background: String? = nil, logo: String? = nil, description: String? = nil, releaseInfo: String? = nil,
         released: Date? = nil, imdbRating: String? = nil, runtime: String? = nil, genres: [String] = [],
         cast: [String] = [], director: [String] = [], writer: [String] = [], country: String? = nil,
         language: String? = nil, certification: String? = nil, awards: String? = nil, website: String? = nil,
         trailers: [MetaTrailer] = [], links: [MetaLink] = [], videos: [MetaVideo] = [],
         defaultVideoId: String? = nil, posterShape: String? = nil, tmdbID: Int? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterFallback = posterFallback
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.released = released
        self.imdbRating = imdbRating
        self.runtime = runtime
        self.genres = genres
        self.cast = cast
        self.director = director
        self.writer = writer
        self.country = country
        self.language = language
        self.certification = certification
        self.awards = awards
        self.website = website
        self.trailers = trailers
        self.links = links
        self.videos = videos
        self.defaultVideoId = defaultVideoId
        self.posterShape = posterShape
        self.tmdbID = tmdbID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.string(AnyKey("id")) ?? c.string(AnyKey("imdb_id")) ?? ""
        type = c.string(AnyKey("type")) ?? "movie"
        name = (c.string(AnyKey("name")) ?? c.string(AnyKey("title")) ?? "").htmlEntitiesDecoded
        poster = c.string(AnyKey("poster"))
        posterFallback = c.string(AnyKey("posterFallback"))
        background = c.string(AnyKey("background"))
        logo = c.string(AnyKey("logo"))
        description = c.string(AnyKey("description"))?.htmlEntitiesDecoded
        releaseInfo = c.string(AnyKey("releaseInfo")) ?? c.string(AnyKey("year"))
        if let s = c.string(AnyKey("released")) { released = DateParsing.parse(s) }
        imdbRating = c.string(AnyKey("imdbRating"))
        runtime = c.string(AnyKey("runtime"))
        var g = c.stringList(AnyKey("genres"))
        if g.isEmpty { g = c.stringList(AnyKey("genre")) }
        let links = c.lossyArray(MetaLink.self, AnyKey("links"))
        if g.isEmpty { g = links.filter { $0.category.lowercased() == "genres" }.map(\.name) }
        genres = g
        var castList = c.stringList(AnyKey("cast"))
        if castList.isEmpty { castList = links.filter { $0.category.lowercased() == "cast" }.map(\.name) }
        cast = castList.map(\.htmlEntitiesDecoded)
        var dir = c.stringList(AnyKey("director"))
        if dir.isEmpty { dir = links.filter { $0.category.lowercased() == "directors" }.map(\.name) }
        director = dir.map(\.htmlEntitiesDecoded)
        var wr = c.stringList(AnyKey("writer"))
        if wr.isEmpty { wr = links.filter { $0.category.lowercased() == "writers" }.map(\.name) }
        writer = wr.map(\.htmlEntitiesDecoded)
        country = c.string(AnyKey("country"))
        language = c.string(AnyKey("language"))
        certification = c.string(AnyKey("certification")) ?? c.string(AnyKey("contentRating"))
        awards = c.string(AnyKey("awards"))
        website = c.string(AnyKey("website"))
        var t = c.lossyArray(MetaTrailer.self, AnyKey("trailers"))
        if t.isEmpty { t = c.lossyArray(MetaTrailer.self, AnyKey("trailerStreams")) }
        trailers = t.filter { !$0.source.isEmpty }
        self.links = links
        videos = c.lossyArray(MetaVideo.self, AnyKey("videos"))
        if let hints = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("behaviorHints")) {
            defaultVideoId = hints.string(AnyKey("defaultVideoId"))
        }
        posterShape = c.string(AnyKey("posterShape"))
        tmdbID = c.int(AnyKey("tmdbID")) ?? c.int(AnyKey("moviedb_id")) ?? c.int(AnyKey("tmdb_id"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(type, forKey: AnyKey("type"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(poster, forKey: AnyKey("poster"))
        try c.encodeIfPresent(posterFallback, forKey: AnyKey("posterFallback"))
        try c.encodeIfPresent(background, forKey: AnyKey("background"))
        try c.encodeIfPresent(logo, forKey: AnyKey("logo"))
        try c.encodeIfPresent(description, forKey: AnyKey("description"))
        try c.encodeIfPresent(releaseInfo, forKey: AnyKey("releaseInfo"))
        if let released { try c.encode(DateParsing.iso.string(from: released), forKey: AnyKey("released")) }
        try c.encodeIfPresent(imdbRating, forKey: AnyKey("imdbRating"))
        try c.encodeIfPresent(runtime, forKey: AnyKey("runtime"))
        if !genres.isEmpty { try c.encode(genres, forKey: AnyKey("genres")) }
        if !cast.isEmpty { try c.encode(cast, forKey: AnyKey("cast")) }
        if !director.isEmpty { try c.encode(director, forKey: AnyKey("director")) }
        if !writer.isEmpty { try c.encode(writer, forKey: AnyKey("writer")) }
        try c.encodeIfPresent(country, forKey: AnyKey("country"))
        try c.encodeIfPresent(language, forKey: AnyKey("language"))
        try c.encodeIfPresent(certification, forKey: AnyKey("certification"))
        try c.encodeIfPresent(awards, forKey: AnyKey("awards"))
        try c.encodeIfPresent(website, forKey: AnyKey("website"))
        if !trailers.isEmpty { try c.encode(trailers, forKey: AnyKey("trailers")) }
        if !links.isEmpty { try c.encode(links, forKey: AnyKey("links")) }
        if !videos.isEmpty { try c.encode(videos, forKey: AnyKey("videos")) }
        if let defaultVideoId {
            var hints = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("behaviorHints"))
            try hints.encode(defaultVideoId, forKey: AnyKey("defaultVideoId"))
        }
        try c.encodeIfPresent(posterShape, forKey: AnyKey("posterShape"))
        try c.encodeIfPresent(tmdbID, forKey: AnyKey("tmdbID"))
    }

    static func == (a: MetaItem, b: MetaItem) -> Bool {
        a.id == b.id && a.type == b.type && a.name == b.name && a.poster == b.poster && a.videos.count == b.videos.count
            && a.background == b.background && a.logo == b.logo && a.description == b.description
    }

    func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(type)
    }

    // MARK: Helpers

    var isSeries: Bool { type == "series" || type == "anime" || (!videos.isEmpty && videos.contains { $0.season != nil } && type != "movie") }
    var isMovie: Bool { !isSeries && type != "tv" && type != "channel" }

    var typeLabel: String {
        switch type {
        case "movie": return "Movie"
        case "series": return "TV Show"
        case "anime": return "Anime"
        case "tv", "channel": return "Live"
        default: return type.capitalized
        }
    }

    var year: String? {
        if let r = releaseInfo {
            let digits = r.prefix(4)
            if digits.count == 4, Int(digits) != nil { return String(digits) }
        }
        if let released { return String(Calendar.current.component(.year, from: released)) }
        return nil
    }

    var isUnreleased: Bool {
        if let released { return released > Date() }
        if let y = year, let yi = Int(y) { return yi > Calendar.current.component(.year, from: Date()) }
        return false
    }

    var runtimeMinutes: Int? {
        guard let runtime else { return nil }
        let lower = runtime.lowercased()
        var total = 0
        var found = false
        let scanner = Scanner(string: lower)
        while !scanner.isAtEnd {
            if let n = scanner.scanInt() {
                found = true
                let rest = lower[scanner.currentIndex...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("h") { total += n * 60 } else { total += n }
            } else {
                _ = scanner.scanCharacter()
            }
        }
        return found && total > 0 ? total : nil
    }

    var runtimeFormatted: String? {
        guard let m = runtimeMinutes else { return runtime }
        return Self.formatMinutes(m)
    }

    static func formatMinutes(_ m: Int) -> String {
        if m >= 60 {
            let h = m / 60, r = m % 60
            return r == 0 ? "\(h)h" : "\(h)h \(r)m"
        }
        return "\(m)m"
    }

    var imdbID: String? {
        if id.hasPrefix("tt") { return String(id.split(separator: ":").first ?? "") }
        return nil
    }

    var ratingValue: Double? { imdbRating.flatMap { Double($0) } }

    /// Seasons in order, specials last.
    var seasons: [Int] {
        let set = Set(videos.compactMap(\.season))
        return set.filter { $0 > 0 }.sorted() + (set.contains(0) ? [0] : [])
    }

    func episodes(season: Int) -> [MetaVideo] {
        videos.filter { $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    /// All episodes in watch order (specials excluded).
    var orderedEpisodes: [MetaVideo] {
        videos.filter { ($0.season ?? 0) > 0 }.sorted {
            if $0.season != $1.season { return ($0.season ?? 0) < ($1.season ?? 0) }
            return ($0.episode ?? 0) < ($1.episode ?? 0)
        }
    }

    func episode(after video: MetaVideo, allowUnaired: Bool) -> MetaVideo? {
        let list = orderedEpisodes
        guard let i = list.firstIndex(where: { $0.id == video.id }), i + 1 < list.count else { return nil }
        let next = list[i + 1]
        return allowUnaired || next.hasAired ? next : nil
    }

    func video(id vid: String) -> MetaVideo? { videos.first { $0.id == vid } }

    /// Picks the clean poster when the viewer turned Poster banners off.
    func withPoster(banners: Bool) -> MetaItem {
        guard !banners, let posterFallback, !posterFallback.isEmpty, posterFallback != poster else { return self }
        var copy = self
        copy.poster = posterFallback
        return copy
    }

    /// A lightweight copy for lists/persistence (no videos).
    var preview: MetaItem {
        var copy = self
        copy.videos = []
        copy.links = []
        return copy
    }

    /// Fills missing fields from `other` (add-on meta first, enrichment second).
    func merged(with other: MetaItem) -> MetaItem {
        var m = self
        if m.poster == nil { m.poster = other.poster }
        if m.background == nil { m.background = other.background }
        if m.logo == nil { m.logo = other.logo }
        if (m.description ?? "").isEmpty { m.description = other.description }
        if m.releaseInfo == nil { m.releaseInfo = other.releaseInfo }
        if m.released == nil { m.released = other.released }
        if m.imdbRating == nil { m.imdbRating = other.imdbRating }
        if m.runtime == nil { m.runtime = other.runtime }
        if m.genres.isEmpty { m.genres = other.genres }
        if m.cast.isEmpty { m.cast = other.cast }
        if m.director.isEmpty { m.director = other.director }
        if m.country == nil { m.country = other.country }
        if m.language == nil { m.language = other.language }
        if m.certification == nil { m.certification = other.certification }
        if m.trailers.isEmpty { m.trailers = other.trailers }
        if m.videos.isEmpty { m.videos = other.videos }
        if m.tmdbID == nil { m.tmdbID = other.tmdbID }
        return m
    }

    /// Splits an episode id `<showId>:<season>:<episode>`.
    static func parseEpisodeID(_ id: String) -> (show: String, season: Int, episode: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) else { return nil }
        return (parts.dropLast(2).joined(separator: ":"), s, e)
    }

    /// Add-on "Up Next" ids (`simkl_upnext_tt…`) map back to the show id.
    static func canonicalShowID(_ id: String) -> String {
        for prefix in ["simkl_upnext_", "trakt_upnext_", "upnext_", "next_"] where id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }
}

// MARK: - Responses

struct CatalogResponse: Decodable {
    var metas: [MetaItem]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        metas = c.lossyArray(MetaItem.self, AnyKey("metas")).filter { !$0.id.isEmpty }
    }
}

struct MetaResponse: Decodable {
    var meta: MetaItem?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        meta = try? c.decodeIfPresent(MetaItem.self, forKey: AnyKey("meta"))
    }
}

struct AddonSubtitle: Codable, Hashable, Identifiable {
    var id: String
    var url: String
    var lang: String
    var addonName: String?

    init(id: String, url: String, lang: String, addonName: String? = nil) {
        self.id = id
        self.url = url
        self.lang = lang
        self.addonName = addonName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        url = c.string(AnyKey("url")) ?? ""
        id = c.string(AnyKey("id")) ?? url
        lang = c.string(AnyKey("lang")) ?? "und"
        addonName = c.string(AnyKey("addonName"))
    }
}

struct SubtitlesResponse: Decodable {
    var subtitles: [AddonSubtitle]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        subtitles = c.lossyArray(AddonSubtitle.self, AnyKey("subtitles")).filter { !$0.url.isEmpty }
    }
}

extension String {
    /// Add-on metadata sometimes arrives HTML-escaped ("Josh O&apos;Connor").
    var htmlEntitiesDecoded: String {
        guard contains("&"), contains(";") else { return self }
        var out = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            guard let semi = tail.prefix(10).firstIndex(of: ";") else { out.append("&"); rest = rest[rest.index(after: amp)...]; continue }
            let entity = tail[tail.index(after: amp)..<semi]
            if let ch = Self.entity(entity) {
                out.append(ch)
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest[rest.index(after: amp)...]
            }
        }
        return out + rest
    }

    private static func entity(_ e: Substring) -> Character? {
        switch e {
        case "amp": return "&"
        case "apos": return "'"
        case "quot": return "\""
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00A0}"
        default:
            guard e.hasPrefix("#") else { return nil }
            let num = e.dropFirst()
            let value = num.hasPrefix("x") || num.hasPrefix("X") ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
            return value.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}
