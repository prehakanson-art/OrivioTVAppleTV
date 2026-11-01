import Foundation

/// One aggregated rating (MDBList).
struct ExternalRating: Hashable, Identifiable {
    var id: String { source }
    var source: String
    var label: String
    var value: String
    var symbol: String
}

/// MDBList aggregated ratings: IMDb, TMDB, RT critics/audience, Metacritic, Letterboxd, Trakt…
enum MDBListService {
    private static let cache = ResponseCache<[ExternalRating]>(capacity: 256, ttl: 30 * 60)

    static func validate(key: String) async -> Bool {
        guard let url = URL(string: "https://api.mdblist.com/user?apikey=\(HTTP.encodeComponent(key))") else { return false }
        return (try? await HTTP.data(url, fresh: true, timeout: 10)) != nil
    }

    static func ratings(imdbID: String, isSeries: Bool, apiKey: String) async -> [ExternalRating] {
        guard imdbID.hasPrefix("tt"), !apiKey.isEmpty else { return [] }
        let cacheKey = "\(imdbID)|\(isSeries)"
        if let hit = cache.get(cacheKey) { return hit }
        let type = isSeries ? "show" : "movie"
        let urls = [
            "https://api.mdblist.com/imdb/\(type)/\(imdbID)?apikey=\(HTTP.encodeComponent(apiKey))",
            "https://mdblist.com/api/?apikey=\(HTTP.encodeComponent(apiKey))&i=\(imdbID)",
        ]
        for s in urls {
            guard let url = URL(string: s),
                  let obj = try? await HTTP.jsonObject(HTTP.request(url, timeout: 15)),
                  let d = obj as? [String: Any], let list = d["ratings"] as? [[String: Any]] else { continue }
            let out = list.compactMap(parse)
            cache.set(cacheKey, out)
            return out
        }
        return []
    }

    private static func parse(_ r: [String: Any]) -> ExternalRating? {
        guard let source = r["source"] as? String else { return nil }
        let raw = (r["value"] as? Double) ?? (r["value"] as? Int).map(Double.init) ?? (r["score"] as? Double)
        guard let v = raw, v > 0 else { return nil }
        switch source.lowercased() {
        case "imdb": return ExternalRating(source: "imdb", label: "IMDb", value: String(format: "%.1f", v), symbol: "star.fill")
        case "tmdb": return ExternalRating(source: "tmdb", label: "TMDB", value: "\(Int(v))%", symbol: "chart.bar.fill")
        case "tomatoes": return ExternalRating(source: "tomatoes", label: "Rotten Tomatoes", value: "\(Int(v))%", symbol: "leaf.fill")
        case "popcorn", "tomatoesaudience": return ExternalRating(source: "audience", label: "Audience", value: "\(Int(v))%", symbol: "popcorn.fill")
        case "metacritic": return ExternalRating(source: "metacritic", label: "Metacritic", value: "\(Int(v))", symbol: "m.square.fill")
        case "letterboxd": return ExternalRating(source: "letterboxd", label: "Letterboxd", value: String(format: "%.1f", v), symbol: "circle.grid.3x3.fill")
        case "trakt": return ExternalRating(source: "trakt", label: "Trakt", value: "\(Int(v))%", symbol: "checkmark.seal.fill")
        case "myanimelist": return ExternalRating(source: "mal", label: "MyAnimeList", value: String(format: "%.1f", v), symbol: "sparkles")
        default: return nil
        }
    }
}

enum AdvisorySeverity: String {
    case mild, moderate, severe
    var label: String { rawValue.capitalized }
    var rank: Int { self == .severe ? 2 : (self == .moderate ? 1 : 0) }
}

struct ParentalAdvisory: Hashable, Identifiable {
    var id: String { label }
    let label: String
    let severity: AdvisorySeverity
}

/// IMDb parents-guide advisories (same source as the Android app), each
/// category collapsed to its dominant severity.
enum ParentalGuideService {
    private static let cache = ResponseCache<[ParentalAdvisory]>(capacity: 128, ttl: 24 * 3600)
    private static let categories: [(String, String)] = [
        ("SEXUAL_CONTENT", "Sex & Nudity"), ("VIOLENCE", "Violence & Gore"), ("PROFANITY", "Profanity"),
        ("ALCOHOL_DRUGS", "Alcohol & Drugs"), ("FRIGHTENING_INTENSE_SCENES", "Frightening"),
    ]

    static func guide(imdbID: String) async -> [ParentalAdvisory] {
        guard imdbID.hasPrefix("tt") else { return [] }
        if let hit = cache.get(imdbID) { return hit }
        guard let url = URL(string: "https://api.tiffara.com/titles/\(imdbID)/parentsGuide"),
              let obj = try? await HTTP.jsonObject(HTTP.request(url, timeout: 15)),
              let list = (obj as? [String: Any])?["parentsGuide"] as? [[String: Any]] else { return [] }
        var byCat: [String: [[String: Any]]] = [:]
        for c in list {
            guard let cat = (c["category"] as? String)?.uppercased() else { continue }
            byCat[cat] = c["severityBreakdowns"] as? [[String: Any]] ?? []
        }
        var out: [ParentalAdvisory] = []
        for (key, label) in categories {
            guard let b = byCat[key] else { continue }
            let votes = b.map { (($0["severityLevel"] as? String ?? "").lowercased(), $0["voteCount"] as? Int ?? 0) }
            let ranked = votes.filter { $0.0 != "none" }.sorted { $0.1 > $1.1 }
            guard let top = ranked.first, top.1 > 0 else { continue }
            if let none = votes.first(where: { $0.0 == "none" }), none.1 > top.1 { continue }
            if let sev = AdvisorySeverity(rawValue: top.0) { out.append(ParentalAdvisory(label: label, severity: sev)) }
        }
        cache.set(imdbID, out)
        return out
    }
}
