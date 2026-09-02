import Foundation

/// A time-based skip interval for anime intros/outros (seconds).
struct AnimeSkipInterval: Hashable {
    enum Kind { case intro, outro }
    let kind: Kind
    let start: Double
    let end: Double
}

/// Anime intro/outro skip times, sourced exactly like the Android app:
/// resolve the IMDb id → MyAnimeList id per season via ARM (arm.haglund.dev),
/// then fetch op/ed intervals from AniSkip v2 (api.aniskip.com — no auth /
/// client-id required, unlike the AnimeSkip GraphQL API).
enum AnimeSkipService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private static var malCache: [String: [Int]] = [:]   // imdbId → per-season MAL ids
    private static var intervalCache: [String: [AnimeSkipInterval]] = [:]

    /// Skip intervals for an episode, or [] when the title isn't anime / has no
    /// data. `episodeLength` (seconds) sharpens AniSkip's matching when known.
    static func intervals(imdbID: String, season: Int, episode: Int, episodeLength: Int = 0) async -> [AnimeSkipInterval] {
        guard imdbID.hasPrefix("tt"), episode > 0 else { return [] }
        let key = "\(imdbID):\(season):\(episode)"
        if let hit = intervalCache[key] { return hit }

        let malIDs = await malIDs(imdbID: imdbID)
        guard !malIDs.isEmpty else { intervalCache[key] = []; return [] }
        // ARM returns one entry per season; fall back to the first mapping.
        let malID = (season - 1 < malIDs.count ? malIDs[season - 1] : malIDs.first) ?? malIDs.first
        guard let malID else { intervalCache[key] = []; return [] }

        let result = await fetchAniSkip(malID: malID, episode: episode, episodeLength: episodeLength)
        intervalCache[key] = result
        return result
    }

    // MARK: ARM — IMDb → per-season MAL ids

    private static func malIDs(imdbID: String) async -> [Int] {
        if let hit = malCache[imdbID] { return hit }
        var comps = URLComponents(string: "https://arm.haglund.dev/api/v2/imdb")!
        comps.queryItems = [
            .init(name: "id", value: imdbID),
            .init(name: "include", value: "myanimelist")
        ]
        guard let url = comps.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let entries = try? JSONDecoder().decode([ArmEntry].self, from: data) else {
            malCache[imdbID] = []
            return []
        }
        // Preserve per-season order; a nil season entry stays nil in the slot.
        let ids = entries.map { $0.myanimelist }.compactMap { $0 }
        malCache[imdbID] = ids
        return ids
    }

    // MARK: AniSkip v2

    private static func fetchAniSkip(malID: Int, episode: Int, episodeLength: Int) async -> [AnimeSkipInterval] {
        var comps = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)")!
        comps.queryItems = [
            .init(name: "types[]", value: "op"),
            .init(name: "types[]", value: "ed"),
            .init(name: "episodeLength", value: String(episodeLength))
        ]
        guard let url = comps.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(AniSkipResponse.self, from: data),
              decoded.found, let results = decoded.results else { return [] }
        return results.compactMap { r in
            let kind: AnimeSkipInterval.Kind = r.skipType.lowercased() == "ed" ? .outro : .intro
            guard r.interval.endTime > r.interval.startTime else { return nil }
            return AnimeSkipInterval(kind: kind, start: r.interval.startTime, end: r.interval.endTime)
        }
    }

    // MARK: DTOs
    private struct ArmEntry: Decodable { let myanimelist: Int? }
    private struct AniSkipResponse: Decodable { let found: Bool; let results: [AniSkipResult]? }
    private struct AniSkipResult: Decodable { let interval: AniSkipIntervalDTO; let skipType: String }
    private struct AniSkipIntervalDTO: Decodable { let startTime: Double; let endTime: Double }
}
