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

    // Guarded by `cacheLock`: `intervals` is called from concurrent player and
    // detail Tasks, and a plain Swift Dictionary is not thread-safe (concurrent
    // mutation → EXC_BAD_ACCESS). Same pattern as TMDBService.
    private static let cacheLock = NSLock()
    private static var malCache: [String: [Int]] = [:]   // imdbId → per-season MAL ids
    private static var intervalCache: [String: [AnimeSkipInterval]] = [:]

    private static func cachedIntervals(_ key: String) -> [AnimeSkipInterval]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return intervalCache[key]
    }
    private static func storeIntervals(_ value: [AnimeSkipInterval], for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        intervalCache[key] = value
    }
    private static func cachedMALIDs(_ key: String) -> [Int]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return malCache[key]
    }
    private static func storeMALIDs(_ value: [Int], for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        malCache[key] = value
    }

    /// Skip intervals for an episode, or [] when the title isn't anime / has no
    /// data. `episodeLength` (seconds) sharpens AniSkip's matching when known.
    static func intervals(imdbID: String, season: Int, episode: Int, episodeLength: Int = 0) async -> [AnimeSkipInterval] {
        guard imdbID.hasPrefix("tt"), episode > 0 else { return [] }
        let key = "\(imdbID):\(season):\(episode)"
        if let hit = cachedIntervals(key) { return hit }

        let malIDs = await malIDs(imdbID: imdbID)
        guard !malIDs.isEmpty else { storeIntervals([], for: key); return [] }
        // ARM returns one entry per season; fall back to the first mapping.
        // Season 0 is normal for anime specials/OVAs in Cinemeta and Kitsu
        // metadata, so the LOW end needs guarding as much as the high one —
        // `malIDs[-1]` traps.
        let seasonIndex = season - 1
        let malID: Int? = malIDs.indices.contains(seasonIndex) ? malIDs[seasonIndex] : malIDs.first
        guard let malID else { storeIntervals([], for: key); return [] }

        let result = await fetchAniSkip(malID: malID, episode: episode, episodeLength: episodeLength)
        storeIntervals(result, for: key)
        return result
    }

    // MARK: ARM — IMDb → per-season MAL ids

    private static func malIDs(imdbID: String) async -> [Int] {
        if let hit = cachedMALIDs(imdbID) { return hit }
        var comps = URLComponents(string: "https://arm.haglund.dev/api/v2/imdb")!
        comps.queryItems = [
            .init(name: "id", value: imdbID),
            .init(name: "include", value: "myanimelist")
        ]
        guard let url = comps.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let entries = try? JSONDecoder().decode([ArmEntry].self, from: data) else {
            storeMALIDs([], for: imdbID)
            return []
        }
        // Preserve per-season order; a nil season entry stays nil in the slot.
        let ids = entries.map { $0.myanimelist }.compactMap { $0 }
        storeMALIDs(ids, for: imdbID)
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
