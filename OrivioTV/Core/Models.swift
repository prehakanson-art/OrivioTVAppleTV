import Foundation

// MARK: - Stremio addon manifest

struct AddonManifest: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let types: [String]?
    let idPrefixes: [String]?
    let catalogs: [ManifestCatalog]?
    let resources: [ManifestResource]?

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, types, idPrefixes, catalogs, resources
    }

    /// Tolerant decode: real-world manifests routinely bend the spec (missing
    /// name, numeric versions, odd catalog entries…). A strict decode turned
    /// ANY such quirk into a dead placeholder addon — instead, salvage every
    /// field we can and fall back sensibly, so any addon that serves valid
    /// streams works regardless of manifest cosmetics.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let rawName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        id = rawID ?? rawName ?? "addon"
        name = rawName ?? rawID ?? "Add-on"
        // NB: no non-nil fallback here — version's nil-ness participates in
        // isPlaceholder, and persisted placeholders must round-trip as such.
        var decodedVersion: String? = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
        if decodedVersion == nil,
           let numeric = (try? c.decodeIfPresent(Double.self, forKey: .version)) ?? nil {
            decodedVersion = String(numeric)
        }
        version = decodedVersion
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        logo = (try? c.decodeIfPresent(String.self, forKey: .logo)) ?? nil
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil
        idPrefixes = (try? c.decodeIfPresent([String].self, forKey: .idPrefixes)) ?? nil
        catalogs = (try? c.decodeIfPresent([ManifestCatalog].self, forKey: .catalogs)) ?? nil
        resources = (try? c.decodeIfPresent([ManifestResource].self, forKey: .resources)) ?? nil
    }

    init(id: String, name: String, version: String?, description: String?,
         logo: String?, types: [String]?, idPrefixes: [String]?,
         catalogs: [ManifestCatalog]?, resources: [ManifestResource]?) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.logo = logo
        self.types = types
        self.idPrefixes = idPrefixes
        self.catalogs = catalogs
        self.resources = resources
    }

    private func provides(_ resource: String) -> Bool {
        resources?.contains { $0.name == resource } ?? false
    }

    var providesStreams: Bool { provides("stream") }
    var providesMeta: Bool { provides("meta") }
    var providesCatalogs: Bool { !(catalogs ?? []).isEmpty }
    var providesSubtitles: Bool { provides("subtitles") }

    /// True while this addon exists only as a URL we couldn't fetch a manifest
    /// for yet. It contributes nothing (no catalogs/streams) but is retained so
    /// a sync push never silently drops — and thereby deletes — it.
    var isPlaceholder: Bool { resources == nil && catalogs == nil && version == nil }

    /// A minimal stand-in for an addon whose manifest failed to load. Names it
    /// after the host so the list stays recognisable; self-heals on the next
    /// successful manifest refresh.
    static func placeholder(manifestURL: String) -> AddonManifest {
        let host = URL(string: manifestURL)?.host ?? manifestURL
        return AddonManifest(id: manifestURL, name: host, version: nil,
                             description: nil, logo: nil, types: nil,
                             idPrefixes: nil, catalogs: nil, resources: nil)
    }
}

/// Manifest `resources` entries are either plain strings ("stream") or
/// objects ({"name": "stream", "types": [...], "idPrefixes": [...]}).
enum ManifestResource: Codable, Hashable {
    case simple(String)
    case detailed(name: String, types: [String]?, idPrefixes: [String]?)

    var name: String {
        switch self {
        case .simple(let name): return name
        case .detailed(let name, _, _): return name
        }
    }

    private struct Detailed: Codable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .simple(string)
        } else {
            let obj = try container.decode(Detailed.self)
            self = .detailed(name: obj.name, types: obj.types, idPrefixes: obj.idPrefixes)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .simple(let name):
            try container.encode(name)
        case .detailed(let name, let types, let idPrefixes):
            try container.encode(Detailed(name: name, types: types, idPrefixes: idPrefixes))
        }
    }
}

struct ManifestCatalog: Codable, Identifiable, Hashable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?
    let extraRequired: [String]?
    let extraSupported: [String]?

    /// Catalogs that require an extra argument (search, genre...) cannot be
    /// shown as plain home rows.
    var requiresExtra: Bool {
        if let extraRequired, !extraRequired.isEmpty { return true }
        return extra?.contains { $0.isRequired == true } ?? false
    }

    var supportsSearch: Bool {
        if extraSupported?.contains("search") == true { return true }
        return extra?.contains { $0.name == "search" } ?? false
    }

    /// Genres this catalog can filter by (from the `genre` extra's options).
    var genreOptions: [String] {
        extra?.first { $0.name == "genre" }?.options ?? []
    }

    var displayName: String {
        let base = name ?? id.capitalized
        let typeLabel: String
        switch type {
        case "movie": typeLabel = "Movies"
        case "series": typeLabel = "Series"
        case "tv": typeLabel = "TV"
        default: typeLabel = type.capitalized
        }
        if base.lowercased().contains(typeLabel.lowercased()) { return base }
        return "\(base) \(typeLabel)"
    }
}

struct CatalogExtra: Codable, Hashable {
    let name: String?
    let isRequired: Bool?
    /// Allowed values for this extra (e.g. the genre list when `name == "genre"`).
    let options: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case isRequired
        case options
    }
}

struct InstalledAddon: Codable, Identifiable, Hashable {
    let manifestURL: String
    let manifest: AddonManifest
    /// Disabled addons stay installed but contribute no catalogs/streams — the
    /// APK's per-addon on/off toggle.
    var enabled: Bool = true

    var id: String { manifestURL }

    private enum CodingKeys: String, CodingKey { case manifestURL, manifest, enabled }

    init(manifestURL: String, manifest: AddonManifest, enabled: Bool = true) {
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestURL = try c.decode(String.self, forKey: .manifestURL)
        manifest = try c.decode(AddonManifest.self, forKey: .manifest)
        // Back-compat: addons saved before the toggle existed default to on.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var baseURL: String {
        var base = manifestURL
        // Drop any query/fragment first. A configured addon's manifest can carry
        // one, and without this the suffix test below failed, `baseURL` came
        // back EQUAL to the manifest URL, and every resource request was built
        // as "…/manifest.json?token=…/catalog/…".
        if let mark = base.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            base = String(base[base.startIndex..<mark])
        }
        if base.hasSuffix("/manifest.json") {
            base = String(base.dropLast("/manifest.json".count))
        }
        return base
    }

    /// Whether this addon claims to resolve the given content id. Prefixes can
    /// be declared at the manifest top level OR inside a detailed resource
    /// entry ({"name":"stream","idPrefixes":[…]}) — union both; an addon that
    /// declares neither is assumed to handle everything.
    func handles(id contentID: String) -> Bool {
        var prefixes = manifest.idPrefixes ?? []
        for resource in manifest.resources ?? [] {
            if case .detailed(_, _, let resourcePrefixes) = resource {
                prefixes.append(contentsOf: resourcePrefixes ?? [])
            }
        }
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { contentID.hasPrefix($0) }
    }
}

// MARK: - Meta

struct MetaItem: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let genres: [String]?
    let cast: [String]?
    let videos: [MetaVideo]?

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description
        case releaseInfo, imdbRating, runtime, genres, cast, videos, year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        poster = try? c.decode(String.self, forKey: .poster)
        background = try? c.decode(String.self, forKey: .background)
        logo = try? c.decode(String.self, forKey: .logo)
        description = try? c.decode(String.self, forKey: .description)
        if let info = try? c.decode(String.self, forKey: .releaseInfo) {
            releaseInfo = info
        } else if let year = try? c.decode(Int.self, forKey: .year) {
            releaseInfo = String(year)
        } else if let year = try? c.decode(String.self, forKey: .year) {
            releaseInfo = year
        } else {
            releaseInfo = nil
        }
        if let rating = try? c.decode(String.self, forKey: .imdbRating) {
            imdbRating = rating
        } else if let rating = try? c.decode(Double.self, forKey: .imdbRating) {
            imdbRating = String(format: "%.1f", rating)
        } else {
            imdbRating = nil
        }
        runtime = try? c.decode(String.self, forKey: .runtime)
        genres = try? c.decode([String].self, forKey: .genres)
        cast = try? c.decode([String].self, forKey: .cast)
        videos = try? c.decode([MetaVideo].self, forKey: .videos)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(cast, forKey: .cast)
        try c.encodeIfPresent(videos, forKey: .videos)
    }

    init(
        id: String, type: String, name: String,
        poster: String? = nil, background: String? = nil, logo: String? = nil,
        description: String? = nil, releaseInfo: String? = nil, imdbRating: String? = nil,
        runtime: String? = nil, genres: [String]? = nil, cast: [String]? = nil,
        videos: [MetaVideo]? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.runtime = runtime
        self.genres = genres
        self.cast = cast
        self.videos = videos
    }

    var year: String? {
        guard let releaseInfo, !releaseInfo.isEmpty else { return nil }
        return String(releaseInfo.prefix(4))
    }

    /// Whether this title hasn't come out yet — drives "Hide unreleased
    /// content" (Settings → Layout).
    ///
    /// `releaseInfo` arrives in a few shapes depending on the addon: a bare year
    /// ("2027"), a full date ("2027-03-14"), or a series span ("2019-2023", or
    /// "2019–" for one still airing). Taking the START of the span is right for
    /// all of them — an ongoing series that premiered in 2019 is released, it
    /// just isn't finished. An item with NO date counts as released: addons
    /// leave the field off constantly, and hiding undated items would quietly
    /// empty half of most catalogs.
    var isUnreleased: Bool {
        guard let releaseInfo, !releaseInfo.isEmpty else { return false }
        // Full date: compare properly, so something due later THIS year is
        // still correctly hidden.
        if releaseInfo.count >= 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: String(releaseInfo.prefix(10))) {
                return date > Date()
            }
        }
        let start = releaseInfo.prefix { $0 != "-" && $0 != "–" && $0 != "—" }
        guard let year = Int(start), year > 1800 else { return false }
        return year > Calendar.current.component(.year, from: Date())
    }

    var isSeries: Bool { type == "series" || type == "tv" }

    /// Capitalized content type for meta lines ("Movie" / "Series"), matching the APK.
    var typeLabel: String {
        switch type {
        case "series", "tv": return "Series"
        case "movie": return "Movie"
        default: return type.capitalized
        }
    }

    /// Runtime in the APK's "1h 49m" format (Cinemeta sends "109 min").
    var runtimeFormatted: String? {
        guard let runtime else { return nil }
        let trimmed = runtime.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("h") { return trimmed }   // already "1h 49m"-ish
        let digits = trimmed.prefix { $0.isNumber }
        guard let total = Int(digits), total > 0 else { return trimmed }
        if total >= 60 {
            let h = total / 60, m = total % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(total)m"
    }

    /// Runtime in SECONDS from the addon's free-text field ("109 min",
    /// "1h 49m", "2 hr 15 min"). A duration of last resort: an external
    /// player's callback reports a position but no duration, and a position
    /// means nothing without something to measure it against.
    var runtimeSeconds: Double? {
        guard let runtime = runtime?.lowercased() else { return nil }
        var hours = 0.0, minutes = 0.0
        var digits = ""
        var value: Double?
        for character in runtime {
            if character.isNumber { digits.append(character); continue }
            if !digits.isEmpty { value = Double(digits); digits = "" }
            guard let number = value else { continue }
            if character == "h" { hours += number; value = nil }
            else if character == "m" { minutes += number; value = nil }
        }
        if !digits.isEmpty { value = Double(digits) }
        // A bare number with no unit ("109") is minutes — Cinemeta's usual form.
        if let leftover = value, hours == 0, minutes == 0 { minutes = leftover }
        let total = hours * 3600 + minutes * 60
        return total > 0 ? total : nil
    }

    var seasons: [Int] {
        let numbers = Set((videos ?? []).compactMap { $0.season }.filter { $0 >= 0 })
        return numbers.sorted()
    }

    var regularSeasons: [Int] {
        seasons.filter { $0 > 0 }
    }

    var playbackSeasons: [Int] {
        regularSeasons.isEmpty ? seasons : regularSeasons
    }

    func episodes(season: Int) -> [MetaVideo] {
        (videos ?? [])
            .filter { $0.season == season }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            .deduplicatedByID()
    }

    func episodesIncludingLinkedSpecials(season: Int) -> [MetaVideo] {
        episodes(season: season)
    }
}

extension Array where Element == MetaItem {
    /// Keep only the first occurrence of each `id`. Addons — especially
    /// aggregators like AIO Metadata — routinely return the same title more
    /// than once in a single catalog. `MetaItem` is `Identifiable` by `id`, so
    /// duplicates put repeated identifiers into a `ForEach`, which is undefined
    /// in SwiftUI and crashes the tvOS focus engine. Search, Discover and the
    /// paginated "See All" already guard this way; catalogs feeding Home did
    /// not, which is why an AIO catalog could crash the app right after login.
    func deduplicatedByID() -> [MetaItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension Array where Element == MetaVideo {
    /// Same rationale as `MetaItem.deduplicatedByID` — some meta addons emit
    /// duplicate `video.id`s in an episode list, which would crash the Detail
    /// page's episode `ForEach` on tvOS.
    func deduplicatedByID() -> [MetaVideo] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

struct MetaVideo: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let thumbnail: String?
    let overview: String?
    let released: String?
    let originalSeason: Int?
    let originalEpisode: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, thumbnail, overview, released
        case originalSeason, originalEpisode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name))
        season = try? c.decode(Int.self, forKey: .season)
        episode = (try? c.decode(Int.self, forKey: .episode))
            ?? (try? c.decode(Int.self, forKey: .number))
        thumbnail = try? c.decode(String.self, forKey: .thumbnail)
        overview = try? c.decode(String.self, forKey: .overview)
        released = try? c.decode(String.self, forKey: .released)
        originalSeason = try? c.decode(Int.self, forKey: .originalSeason)
        originalEpisode = try? c.decode(Int.self, forKey: .originalEpisode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(originalSeason, forKey: .originalSeason)
        try c.encodeIfPresent(originalEpisode, forKey: .originalEpisode)
    }

    init(
        id: String, title: String?, season: Int?, episode: Int?,
        thumbnail: String? = nil, overview: String? = nil, released: String? = nil,
        originalSeason: Int? = nil, originalEpisode: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.released = released
        self.originalSeason = originalSeason
        self.originalEpisode = originalEpisode
    }

    var hasAired: Bool {
        guard let released else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: released) { return date <= Date() }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: released) { return date <= Date() }
        return true
    }

    var seasonEpisodeCode: String {
        guard let season, let episode else { return "" }
        return "S\(season):E\(episode)"
    }

    var airedDate: Date? {
        guard let released, !released.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: released) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: released) { return date }
        let ymd = DateFormatter()
        ymd.locale = Locale(identifier: "en_US_POSIX")
        ymd.timeZone = TimeZone(secondsFromGMT: 0)
        ymd.dateFormat = "yyyy-MM-dd"
        return ymd.date(from: String(released.prefix(10)))
    }

    /// Air date formatted for display ("Jun 25, 2021"), or nil if unknown.
    var airedText: String? {
        guard let released, !released.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: released)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: released) }
        if date == nil {
            // Bare "yyyy-MM-dd".
            let ymd = DateFormatter()
            ymd.dateFormat = "yyyy-MM-dd"
            date = ymd.date(from: String(released.prefix(10)))
        }
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

// MARK: - Streams

/// A compact fingerprint of a played stream's format, remembered with watch
/// progress so a resume can re-scrape a FRESH link (debrid/Comet links expire)
/// and pick one matching what was originally watched — same resolution, Dolby
/// Vision, HDR, Atmos, and ideally the same add-on.
struct StreamSignature: Codable, Hashable {
    var resolution: String?      // "2160p" / "1080p" / …
    var dolbyVision: Bool = false
    var hdr: Bool = false
    var atmos: Bool = false
    var addonName: String?
}

struct Stream: Codable, Hashable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    /// Tracker/DHT sources for building a magnet URI (Stremio torrent streams).
    let sources: [String]?
    let behaviorHints: StreamBehaviorHints?
    /// Stremio's `externalUrl`: a link the client opens/hands off rather than
    /// plays in-app. "Cast" addons (DMM Cast etc.) use it for their cast
    /// action, so a stream can carry this INSTEAD of a playable `url`.
    let externalUrl: String?

    private enum CodingKeys: String, CodingKey {
        case name, title, description, url, infoHash, fileIdx, sources, behaviorHints, externalUrl
    }

    /// Tolerant decode: addons in the wild bend the spec (numbers where
    /// strings belong, string fileIdx, malformed behaviorHints…). Any field
    /// that doesn't parse becomes nil instead of throwing, so one odd field
    /// can't invalidate the stream — and with the lossy array decode in
    /// StremioAPI, one odd stream can't blank the whole addon.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedName: String? = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        if decodedName == nil, let numeric = (try? c.decodeIfPresent(Int.self, forKey: .name)) ?? nil {
            decodedName = String(numeric)
        }
        name = decodedName
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        infoHash = (try? c.decodeIfPresent(String.self, forKey: .infoHash)) ?? nil
        var decodedFileIdx: Int? = (try? c.decodeIfPresent(Int.self, forKey: .fileIdx)) ?? nil
        if decodedFileIdx == nil, let string = (try? c.decodeIfPresent(String.self, forKey: .fileIdx)) ?? nil {
            decodedFileIdx = Int(string)
        }
        fileIdx = decodedFileIdx
        sources = (try? c.decodeIfPresent([String].self, forKey: .sources)) ?? nil
        behaviorHints = (try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)) ?? nil
        externalUrl = (try? c.decodeIfPresent(String.self, forKey: .externalUrl)) ?? nil
    }

    init(
        name: String?, title: String?, description: String?, url: String?,
        infoHash: String?, fileIdx: Int? = nil, sources: [String]? = nil,
        behaviorHints: StreamBehaviorHints?, externalUrl: String? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.url = url
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.sources = sources
        self.behaviorHints = behaviorHints
        self.externalUrl = externalUrl
    }

    var isPlayable: Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        return parsed.scheme == "http" || parsed.scheme == "https"
    }

    var isTorrent: Bool { infoHash != nil && url == nil }

    /// A cast / open-externally stream (e.g. DMM Cast): no in-app-playable url
    /// and no torrent, but a link to hand off to the system / an external app.
    var isExternal: Bool {
        !isPlayable && !isTorrent && !(externalUrl?.isEmpty ?? true)
    }

    /// Debrid-cached marker, e.g. "[RD+]", "[TB+]", "PM+" — the convention
    /// Torrentio/Comet/MediaFusion use for torrents the provider already has
    /// (instant play, no download wait).
    private static let cachedMarkerRegex = try? NSRegularExpression(
        pattern: #"\b(rd|ad|pm|tb|dl|oc|pk|ed)\+"#, options: [.caseInsensitive]
    )

    /// True when picking this source plays immediately: a direct http(s)
    /// link, or a torrent the debrid service reports as already cached
    /// (the "[RD+]"-style marker, a ⚡, or the word "cached"). An unmarked
    /// torrent counts as NOT instant — the debrid provider would have to
    /// download it first.
    var isInstant: Bool {
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")"
        let lower = haystack.lowercased()
        // Explicitly-uncached debrid links (Torrentio's "[RD download]", a ⏳,
        // "uncached") DO carry a playable URL — the debrid service just
        // downloads on demand — so they must be caught BEFORE the isPlayable
        // shortcut, or "cached only" lets them through.
        if isUncachedMarked(lower) { return false }
        if isPlayable { return true }
        if haystack.contains("⚡") { return true }
        if lower.contains("cached") { return true }
        guard let regex = Self.cachedMarkerRegex else { return false }
        return regex.firstMatch(
            in: haystack, options: [],
            range: NSRange(haystack.startIndex..., in: haystack)
        ) != nil
    }

    private static let uncachedRegex = try? NSRegularExpression(
        pattern: #"\b(?:rd|ad|pm|tb|dl|oc|pk|torbox|debrid)\b[\s\-\]]*download|download\]|uncached|not cached"#,
        options: [.caseInsensitive]
    )
    private func isUncachedMarked(_ lower: String) -> Bool {
        if lower.contains("uncached") { return true }
        let raw = "\(name ?? "") \(title ?? "") \(description ?? "")"
        if raw.contains("⏳") || raw.contains("⌛") || raw.contains("⏬") { return true }
        guard let regex = Self.uncachedRegex else { return false }
        return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    /// Mentions of a debrid provider — a stream that names one is a debrid
    /// result, whose bare playable URL does NOT imply "cached".
    private static let debridMentionRegex = try? NSRegularExpression(
        pattern: #"real[\s\-]?debrid|premium(ize)?|all[\s\-]?debrid|torbox|debrid|\[(rd|ad|pm|tb|dl|oc|pk|ed)\b"#,
        options: [.caseInsensitive]
    )
    private func mentionsDebrid(_ lower: String) -> Bool {
        guard let regex = Self.debridMentionRegex else { return false }
        return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    /// STRICT cached test for the "cached only" filter. Unlike `isInstant`, a
    /// bare playable URL does NOT count — debrid addons (Comet, MediaFusion,
    /// StremThru…) return a playable URL for UNCACHED results too (they
    /// download on access), which is why "cached only" was letting non-cached
    /// links through. Requires a positive cached signal, or a plain direct
    /// link with no debrid involvement at all.
    var isCached: Bool {
        let raw = "\(name ?? "") \(title ?? "") \(description ?? "")"
        let lower = raw.lowercased()
        if isUncachedMarked(lower) { return false }
        // Positive cached markers used across the common addons.
        if raw.contains("⚡") || raw.contains("✅") { return true }
        if lower.contains("cached") || lower.contains("instant") { return true }
        if let regex = Self.cachedMarkerRegex,   // "[RD+]" / "[PM+]" style tags
           regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil { return true }
        // An unmarked torrent is never instant; a debrid URL without a cached
        // marker is a download-on-access link (NOT cached). Only a genuine
        // direct link with no debrid context counts as instant.
        if isTorrent { return false }
        return isPlayable && !mentionsDebrid(lower)
    }

    private var searchHaystack: String { "\(name ?? "") \(title ?? "") \(description ?? "")".lowercased() }

    /// AV1-encoded (no hardware decode on the Apple TV A10X).
    var isAV1: Bool { searchHaystack.contains("av1") }
    /// Dolby Vision.
    var isDolbyVision: Bool {
        let h = searchHaystack
        return h.contains("dolby vision") || h.contains("dolby.vision") || h.contains("dovi")
            || h.range(of: #"\bdv\b"#, options: .regularExpression) != nil
    }
    /// Any HDR flavor (including Dolby Vision).
    var isHDR: Bool { isDolbyVision || searchHaystack.contains("hdr") || searchHaystack.contains("hlg") }
    /// Dolby Atmos object audio (best-effort from the release name).
    var hasAtmos: Bool { searchHaystack.contains("atmos") }

    /// Fingerprint used to re-find a comparable link on resume.
    func signature(addonName: String?) -> StreamSignature {
        StreamSignature(
            resolution: resolutionLabel,
            dolbyVision: isDolbyVision,
            hdr: isHDR,
            atmos: hasAtmos,
            addonName: addonName
        )
    }

    /// Torrentio-style seeder count ("👤 123").
    private static let seedersRegex = try? NSRegularExpression(pattern: #"👤\s*(\d+)"#)

    /// Ranks a link WITHIN its resolution tier by everything the release name
    /// reveals. Weights, in order of dominance:
    ///  cached ≫ dead torrent / cam-rip ≫ release quality > codec > HDR >
    ///  audio > size sweet spot > seeders.
    /// A10X-specific choices: AV1 is punished hard (no hardware decode —
    /// software AV1 is a slideshow at high res) and HEVC is boosted.
    func qualityScore(isInstant: Bool, sizeBytes: Int64?, resolutionLabel: String?) -> Int {
        let hay = "\(name ?? "") \(title ?? "") \(description ?? "")".lowercased()
        var score = 0

        // Instant playback dominates everything: an uncached torrent means
        // waiting for the debrid service to download it first.
        if isInstant { score += 1000 }

        // Release quality ladder.
        if hay.contains("remux") { score += 140 }
        else if hay.contains("blu-ray") || hay.contains("bluray") || hay.contains("bdrip") || hay.contains("brrip") { score += 120 }
        else if hay.contains("web-dl") || hay.contains("webdl") || hay.contains("web dl") { score += 110 }
        else if hay.contains("webrip") || hay.contains("web-rip") { score += 90 }
        else if hay.contains("hdtv") { score += 60 }
        else if hay.contains("dvdrip") { score += 40 }
        // Theater rips are near-unwatchable — keep them visible but last.
        if hay.contains("hdcam") || hay.contains("camrip") || hay.contains("cam-rip")
            || hay.contains("telesync") || hay.contains("hdts") || hay.contains("telecine") {
            score -= 400
        }

        // Codec (hardware-decode reality on the Apple TV's A10X).
        if hay.contains("av1") { score -= 150 }
        else if hay.contains("hevc") || hay.contains("x265") || hay.contains("h265") || hay.contains("h.265") { score += 40 }
        else if hay.contains("x264") || hay.contains("h264") || hay.contains("h.264") || hay.contains("avc") { score += 15 }

        // Dynamic range.
        if hay.contains("dolby vision") || hay.contains("dolby.vision") || hay.contains("dovi")
            || hay.range(of: #"\bdv\b"#, options: .regularExpression) != nil {
            score += 35
        } else if hay.contains("hdr10+") || hay.contains("hdr10plus") {
            score += 30
        } else if hay.contains("hdr") {
            score += 25
        }

        // Audio. E-AC3/DD+ gets the edge: best tvOS compatibility (and the
        // native-DV path needs it); Atmos stacks on top.
        if hay.contains("atmos") { score += 20 }
        if hay.contains("ddp") || hay.contains("dd+") || hay.contains("eac3") || hay.contains("e-ac-3") || hay.contains("dd5.1") { score += 15 }
        else if hay.contains("truehd") { score += 10 }
        else if hay.contains("dts") { score += 8 }

        // Seeders — only meaningful for uncached torrents: 0 seeds = dead.
        if !isInstant, let regex = Self.seedersRegex,
           let match = regex.firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay)),
           let range = Range(match.range(at: 1), in: hay),
           let seeders = Int(hay[range]) {
            if seeders == 0 { score -= 300 }
            else if seeders >= 20 { score += 20 }
            else if seeders >= 5 { score += 10 }
        }

        // Size sweet spot per resolution: rewards a healthy bitrate, doesn't
        // blindly chase the biggest file. Unknown size is neutral — many
        // excellent debrid links carry no size.
        if let bytes = sizeBytes, bytes > 0 {
            let gb = Double(bytes) / 1_073_741_824
            let sweet: ClosedRange<Double>
            switch resolutionLabel {
            case "2160p": sweet = 8 ... 60
            case "1080p": sweet = 2 ... 15
            case "720p":  sweet = 0.7 ... 6
            case "480p":  sweet = 0.2 ... 3
            default:      sweet = 0.7 ... 20
            }
            if sweet.contains(gb) { score += 30 }
            else if gb > sweet.upperBound { score += 10 }        // huge remux: fine
            else if gb < sweet.lowerBound * 0.5 { score -= 25 }  // starved bitrate
        }

        return score
    }

    /// A magnet URI built from the info hash and any tracker sources.
    var magnetURI: String? {
        guard let infoHash, !infoHash.isEmpty else { return nil }
        var magnet = "magnet:?xt=urn:btih:\(infoHash)"
        for source in sources ?? [] {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("dht:") else { continue }
            let tracker = trimmed.hasPrefix("tracker:") ? String(trimmed.dropFirst("tracker:".count)) : trimmed
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                magnet += "&tr=\(encoded)"
            }
        }
        return magnet
    }

    /// Addon-provided short label, e.g. "Torrentio\n4K".
    var displayName: String {
        (name ?? "Stream").replacingOccurrences(of: "\n", with: " · ")
    }

    /// Longer description lines with file / size details.
    var displayDetail: String {
        let raw = title ?? description ?? ""
        return raw.replacingOccurrences(of: "\n", with: " · ")
    }

    var qualityTag: String? {
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")".lowercased()
        for tag in ["2160p", "4k", "1080p", "720p", "480p"] where haystack.contains(tag) {
            return tag == "4k" ? "4K" : tag
        }
        return nil
    }

    /// Resolution normalized to the "2160p / 1080p / 720p" form.
    var resolutionLabel: String? {
        guard let tag = qualityTag else { return nil }
        return tag == "4K" ? "2160p" : tag
    }

    /// Compiled once — `String.range(of:.regularExpression)` recompiles the
    /// pattern on every call, which was a real per-row cost on long source
    /// lists.
    private static let sizeRegex = try? NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(GB|GiB|MB|MiB)"#, options: [.caseInsensitive]
    )

    /// File size, e.g. "55.3 GB". Prefers the addon's exact byte count
    /// (behaviorHints.videoSize — Torrentio and friends set it), otherwise
    /// parses the "💾 55.3 GB"-style text most stream addons embed.
    /// NOTE: string/regex work — read it via StreamEntry's precomputed copy in
    /// row bodies, never directly per render.
    var fileSizeLabel: String? {
        if let bytes = behaviorHints?.videoSize, bytes > 0 {
            let gb = Double(bytes) / 1_073_741_824
            if gb >= 1 {
                return String(format: gb >= 100 ? "%.0f GB" : "%.1f GB", gb)
            }
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.0f MB", mb)
        }
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")"
        guard let regex = Self.sizeRegex,
              let match = regex.firstMatch(
                in: haystack, options: [],
                range: NSRange(haystack.startIndex..., in: haystack)
              ),
              let range = Range(match.range, in: haystack) else { return nil }
        let matched = haystack[range]
        let unit = matched.lowercased().contains("m") ? "MB" : "GB"
        let number = matched.trimmingCharacters(in: CharacterSet(charactersIn: " GgBbIiMm"))
        return "\(number) \(unit)"
    }

    /// Numeric file size in bytes for sorting/ranking sources (the high-GB vs
    /// low-GB split). Prefers the exact `behaviorHints.videoSize`, else parses
    /// the embedded "💾 55.3 GB" text. nil when no size is discoverable — such
    /// sources sort as smallest so they fill data-saver slots, not top ones.
    var sizeBytes: Int64? {
        if let bytes = behaviorHints?.videoSize, bytes > 0 { return bytes }
        let haystack = "\(name ?? "") \(title ?? "") \(description ?? "")"
        guard let regex = Self.sizeRegex,
              let match = regex.firstMatch(
                in: haystack, options: [],
                range: NSRange(haystack.startIndex..., in: haystack)
              ),
              let numberRange = Range(match.range(at: 1), in: haystack),
              let unitRange = Range(match.range(at: 2), in: haystack),
              let value = Double(haystack[numberRange]) else { return nil }
        let multiplier: Double = haystack[unitRange].lowercased().hasPrefix("m")
            ? 1_048_576 : 1_073_741_824
        return Int64(value * multiplier)
    }
}

struct StreamBehaviorHints: Codable, Hashable {
    let bingeGroup: String?
    let notWebReady: Bool?
    /// Exact video size in bytes (Stremio SDK field, set by Torrentio etc.).
    let videoSize: Int64?
    let filename: String?
    /// Headers the addon wants sent WITH the media request (Stremio's
    /// `behaviorHints.proxyHeaders`). Scraper addons hand back a CDN link that
    /// only answers with the right `Referer`/`User-Agent` — without them the
    /// host returns 403 and the source looks broken. Only `request` is
    /// actionable for us; `response` is a browser-player concern.
    let proxyHeaders: StreamProxyHeaders?

    private enum CodingKeys: String, CodingKey {
        case bingeGroup, notWebReady, videoSize, filename, proxyHeaders
    }

    /// Tolerant decode, same policy as `Stream`: one malformed hint (a string
    /// `videoSize`, a proxyHeaders map with non-string values) must not blank
    /// the whole hints object and take the good fields down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bingeGroup = (try? c.decodeIfPresent(String.self, forKey: .bingeGroup)) ?? nil
        notWebReady = (try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)) ?? nil
        var decodedSize: Int64? = (try? c.decodeIfPresent(Int64.self, forKey: .videoSize)) ?? nil
        if decodedSize == nil, let string = (try? c.decodeIfPresent(String.self, forKey: .videoSize)) ?? nil {
            decodedSize = Int64(string)
        }
        videoSize = decodedSize
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? nil
        proxyHeaders = (try? c.decodeIfPresent(StreamProxyHeaders.self, forKey: .proxyHeaders)) ?? nil
    }
}

struct StreamProxyHeaders: Codable, Hashable {
    /// Header name → value, applied to the outgoing media request.
    let request: [String: String]?

    private enum CodingKeys: String, CodingKey { case request }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = (try? c.decodeIfPresent([String: String].self, forKey: .request)) ?? nil
    }

    /// Non-empty header map, or nil — the form every caller actually wants.
    var requestHeaders: [String: String]? {
        guard let request, !request.isEmpty else { return nil }
        return request
    }
}

/// A stream tagged with the addon it came from, used across the stream
/// selection UI and in-player source switching.
struct StreamEntry: Identifiable, Hashable {
    let id = UUID()
    let addonName: String
    let stream: Stream

    /// Identity that survives between sessions, for remembering a link the
    /// viewer walked out on. NOT the URL: a debrid link is freshly signed on
    /// every resolve, so keying on it would never match twice. An infoHash is
    /// the same torrent forever; a filename is the same file; the display
    /// strings are the last resort.
    var rejectionKey: String {
        if let hash = stream.infoHash?.lowercased(), !hash.isEmpty {
            return "hash:\(hash)#\(stream.fileIdx ?? -1)"
        }
        if let file = stream.behaviorHints?.filename, !file.isEmpty {
            return "file:\(addonName)|\(file)"
        }
        return "name:\(addonName)|\(displayName)|\(displayDetail)"
    }
    /// Display strings PRECOMPUTED here, once per entry: computing them in
    /// row bodies (regex + string builds, × every visible row × every focus
    /// move) was the main Sources-page scroll cost.
    let displayName: String
    let displayDetail: String
    let resolutionLabel: String?
    let fileSizeLabel: String?
    /// Numeric size for ranking; nil = unknown.
    let sizeBytes: Int64?
    /// Plays immediately (direct link / debrid-cached torrent) — precomputed,
    /// it's regex work.
    let isInstant: Bool
    /// Quality score for ranking within a resolution tier (see
    /// Stream.qualityScore). Includes the dominant cached/instant bonus.
    let sourceScore: Int

    init(addonName: String, stream: Stream) {
        self.addonName = addonName
        self.stream = stream
        displayName = stream.displayName
        displayDetail = stream.displayDetail
        resolutionLabel = stream.resolutionLabel
        fileSizeLabel = stream.fileSizeLabel
        sizeBytes = stream.sizeBytes
        isInstant = stream.isInstant
        sourceScore = stream.qualityScore(
            isInstant: isInstant, sizeBytes: sizeBytes, resolutionLabel: resolutionLabel
        )
    }

    static func == (lhs: StreamEntry, rhs: StreamEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - API response envelopes

struct CatalogResponse: Codable {
    let metas: [MetaItem]?
}

struct MetaResponse: Codable {
    let meta: MetaItem?
}

struct StreamsResponse: Codable {
    let streams: [Stream]?

    private enum CodingKeys: String, CodingKey { case streams }

    /// Lossy array decode: one malformed entry from a loose addon drops just
    /// that entry, not the addon's entire response (which previously made the
    /// whole addon vanish from Sources).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard var array = try? c.nestedUnkeyedContainer(forKey: .streams) else {
            streams = nil
            return
        }
        var collected: [Stream] = []
        while !array.isAtEnd {
            if let stream = try? array.decode(Stream.self) {
                collected.append(stream)
            } else {
                // Skip the malformed element (decode into a throwaway).
                _ = try? array.decode(AnyIgnorable.self)
            }
        }
        streams = collected
    }

    init(streams: [Stream]?) { self.streams = streams }
}

/// Decodes and discards any JSON value — used to skip malformed array
/// elements during lossy decodes.
struct AnyIgnorable: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([AnyIgnorable].self)) != nil { return }
        _ = try? c.decode([String: AnyIgnorable].self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

