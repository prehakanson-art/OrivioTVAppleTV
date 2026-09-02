import Foundation

/// A single content-advisory category with its dominant severity.
struct ParentalGuideEntry: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let severity: ParentalSeverity
}

enum ParentalSeverity: String {
    case mild, moderate, severe
    var display: String {
        switch self {
        case .mild: return "Mild"
        case .moderate: return "Moderate"
        case .severe: return "Severe"
        }
    }
    /// 0…2 for sorting worst-first.
    var rank: Int { self == .severe ? 2 : (self == .moderate ? 1 : 0) }
}

/// Fetches IMDb parents-guide content advisories (same source the Android app
/// uses: api.tiffara.com), collapsing each category's vote breakdown to one
/// dominant severity.
enum ParentalGuideService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// Human labels for the IMDb category keys, in display order.
    private static let categoryLabels: [(key: String, label: String)] = [
        ("SEXUAL_CONTENT", "Sex & Nudity"),
        ("VIOLENCE", "Violence & Gore"),
        ("PROFANITY", "Profanity"),
        ("ALCOHOL_DRUGS", "Alcohol & Drugs"),
        ("FRIGHTENING_INTENSE_SCENES", "Frightening"),
    ]

    /// In-memory cache; advisories don't change within a session.
    private static var cache: [String: [ParentalGuideEntry]] = [:]

    static func guide(imdbID: String) async -> [ParentalGuideEntry] {
        guard imdbID.hasPrefix("tt") else { return [] }
        if let hit = cache[imdbID] { return hit }
        guard let url = URL(string: "https://api.tiffara.com/titles/\(imdbID)/parentsGuide") else { return [] }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

        let byCategory = Dictionary(
            (decoded.parentsGuide ?? []).map { ($0.category.uppercased(), $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var out: [ParentalGuideEntry] = []
        for (key, label) in categoryLabels {
            guard let category = byCategory[key], let severity = dominantSeverity(category) else { continue }
            out.append(ParentalGuideEntry(label: label, severity: severity))
        }
        cache[imdbID] = out
        return out
    }

    /// Highest-voted severity excluding "none" — unless "none" outvotes them all.
    private static func dominantSeverity(_ category: Category) -> ParentalSeverity? {
        let breakdowns = category.severityBreakdowns ?? []
        let ranked = breakdowns
            .filter { $0.severityLevel.lowercased() != "none" }
            .sorted { $0.voteCount > $1.voteCount }
        guard let top = ranked.first else { return nil }
        if let none = breakdowns.first(where: { $0.severityLevel.lowercased() == "none" }),
           none.voteCount > top.voteCount {
            return nil
        }
        return ParentalSeverity(rawValue: top.severityLevel.lowercased())
    }

    // MARK: DTOs
    private struct Response: Decodable { let parentsGuide: [Category]? }
    private struct Category: Decodable {
        let category: String
        let severityBreakdowns: [Breakdown]?
    }
    private struct Breakdown: Decodable {
        let severityLevel: String
        let voteCount: Int
    }
}
