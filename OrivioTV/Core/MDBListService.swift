import Foundation

// MARK: - Settings

/// MDBList settings, mirroring the Android `MDBListSettings`. Requires the
/// user's own MDBList API key (there's no shared key — MDBList is per-account).
struct MDBListSettings: Codable, Equatable {
    var enabled: Bool = false
    var apiKey: String = ""
    var showTrakt = true
    var showImdb = true
    var showTmdb = true
    var showLetterboxd = true
    var showTomatoes = true
    var showAudience = true
    var showMetacritic = true

    static let `default` = MDBListSettings()

    var isConfigured: Bool { enabled && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

@MainActor
final class MDBListSettingsStore: ObservableObject {
    @Published var settings: MDBListSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private static let key = "orivio.mdblist.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(MDBListSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - Ratings model

/// Aggregate ratings across sources (0–10 for imdb/tmdb/letterboxd/trakt-ish,
/// 0–100 percentages for tomatoes/audience/metacritic — MDBList returns them
/// pre-scaled per source).
struct MDBListRatings: Equatable {
    var trakt: Double?
    var imdb: Double?
    var tmdb: Double?
    var letterboxd: Double?
    var tomatoes: Double?
    var audience: Double?
    var metacritic: Double?

    var isEmpty: Bool {
        trakt == nil && imdb == nil && tmdb == nil && letterboxd == nil
            && tomatoes == nil && audience == nil && metacritic == nil
    }

    /// Ordered, display-ready entries (matches the Android hero ratings row).
    func entries(settings: MDBListSettings) -> [MDBListRatingEntry] {
        var out: [MDBListRatingEntry] = []
        func add(_ provider: MDBListProvider, _ value: Double?, _ show: Bool) {
            guard show, let value else { return }
            out.append(MDBListRatingEntry(provider: provider, text: provider.format(value)))
        }
        add(.trakt, trakt, settings.showTrakt)
        add(.imdb, imdb, settings.showImdb)
        add(.tmdb, tmdb, settings.showTmdb)
        add(.letterboxd, letterboxd, settings.showLetterboxd)
        add(.tomatoes, tomatoes, settings.showTomatoes)
        add(.audience, audience, settings.showAudience)
        add(.metacritic, metacritic, settings.showMetacritic)
        return out
    }
}

struct MDBListRatingEntry: Identifiable, Equatable {
    let provider: MDBListProvider
    let text: String
    var id: String { provider.rawValue }
}

enum MDBListProvider: String, CaseIterable, Identifiable {
    case trakt, imdb, tmdb, letterboxd, tomatoes, audience, metacritic
    var id: String { rawValue }

    /// Short badge label shown next to the score.
    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .letterboxd: return "LBXD"
        case .tomatoes: return "RT"
        case .audience: return "RT🍿"
        case .metacritic: return "MC"
        }
    }

    var fullName: String {
        switch self {
        case .trakt: return "Trakt"
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .letterboxd: return "Letterboxd"
        case .tomatoes: return "Rotten Tomatoes"
        case .audience: return "RT Audience"
        case .metacritic: return "Metacritic"
        }
    }

    /// Matches Android `formatMDBListRating`: 0–10 scores keep one decimal,
    /// percentage sources show a whole number (or one decimal if fractional).
    func format(_ rating: Double) -> String {
        switch self {
        case .imdb, .tmdb, .letterboxd:
            return String(format: "%.1f", rating)
        default:
            return rating.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rating))
                : String(format: "%.1f", rating)
        }
    }
}

// MARK: - Service

/// MDBList ratings client. `POST /rating/{mediaType}/{ratingType}?apikey=` with
/// a body of imdb ids; one call per rating source, fanned out in parallel.
enum MDBListService {
    private static let base = "https://api.mdblist.com"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // 30-minute rating cache, keyed by imdb id + api key.
    private struct CacheEntry { let ratings: MDBListRatings; let expiresAt: Date }
    // Guarded by `cacheLock`: `ratings(...)` runs concurrently across catalog
    // items, and a plain Dictionary is not safe under concurrent mutation.
    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]
    private static let ttl: TimeInterval = 30 * 60

    private static func cachedEntry(_ key: String) -> CacheEntry? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }
    private static func storeEntry(_ entry: CacheEntry, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key] = entry
    }

    /// Validate an API key via `GET /user`.
    static func validate(apiKey: String) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              var comps = URLComponents(string: base + "/user") else { return false }
        comps.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = comps.url else { return false }
        guard let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Fetch all enabled ratings for a title. Needs an imdb `tt…` id.
    static func ratings(imdbID: String, type: String, settings: MDBListSettings) async -> MDBListRatings? {
        guard settings.isConfigured, imdbID.hasPrefix("tt") else { return nil }
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespaces)
        let mediaType = (type == "series" || type == "tv") ? "show" : "movie"
        let cacheKey = "\(mediaType):\(imdbID):\(apiKey.hashValue)"
        if let hit = cachedEntry(cacheKey), hit.expiresAt > Date() {
            return hit.ratings.isEmpty ? nil : hit.ratings
        }

        let providers = enabledProviders(settings)
        var values: [MDBListProvider: Double] = [:]
        await withTaskGroup(of: (MDBListProvider, Double?).self) { group in
            for provider in providers {
                group.addTask {
                    (provider, await fetchProvider(imdbID: imdbID, mediaType: mediaType, provider: provider, apiKey: apiKey))
                }
            }
            for await (provider, value) in group {
                if let value { values[provider] = value }
            }
        }

        let ratings = MDBListRatings(
            trakt: values[.trakt], imdb: values[.imdb], tmdb: values[.tmdb],
            letterboxd: values[.letterboxd], tomatoes: values[.tomatoes],
            audience: values[.audience], metacritic: values[.metacritic]
        )
        storeEntry(CacheEntry(ratings: ratings, expiresAt: Date().addingTimeInterval(ttl)), for: cacheKey)
        return ratings.isEmpty ? nil : ratings
    }

    private static func enabledProviders(_ s: MDBListSettings) -> [MDBListProvider] {
        var out: [MDBListProvider] = []
        if s.showTrakt { out.append(.trakt) }
        if s.showImdb { out.append(.imdb) }
        if s.showTmdb { out.append(.tmdb) }
        if s.showLetterboxd { out.append(.letterboxd) }
        if s.showTomatoes { out.append(.tomatoes) }
        if s.showAudience { out.append(.audience) }
        if s.showMetacritic { out.append(.metacritic) }
        return out
    }

    private static func fetchProvider(imdbID: String, mediaType: String, provider: MDBListProvider, apiKey: String) async -> Double? {
        guard var comps = URLComponents(string: "\(base)/rating/\(mediaType)/\(provider.rawValue)") else { return nil }
        comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [imdbID], "provider": "imdb"])
        struct Response: Decodable {
            struct Item: Decodable { let rating: Double? }
            let ratings: [Item]?
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return body.ratings?.first?.rating
    }
}
