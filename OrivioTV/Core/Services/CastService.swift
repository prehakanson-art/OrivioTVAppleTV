import Foundation

/// Cast with photos when TMDB isn't set up: TVmaze for shows (photos and
/// character names, no key needed); IMDb's public suggestion lookup for
/// photos of everyone else.
enum CastService {
    private static let cache = ResponseCache<[TMDBPerson]>(capacity: 64, ttl: 6 * 3600)

    @MainActor
    static func cast(for meta: MetaItem) async -> [TMDBPerson] {
        guard let imdb = meta.imdbID else { return [] }
        if let hit = cache.get(imdb) { return hit }
        var people: [TMDBPerson] = []
        if meta.isSeries { people = await tvmaze(imdbID: imdb) }
        if people.isEmpty {
            let names = meta.cast.map { ($0, nil as String?) } + meta.director.map { ($0, "Director" as String?) }
            people = await boundedConcurrentMap(Array(names.prefix(30)), limit: 6) { name, role in
                TMDBPerson(id: 0, name: name, role: role, photo: await imdbPhoto(name: name))
            }
        }
        if !people.isEmpty { cache.set(imdb, people) }
        return people
    }

    private static func tvmaze(imdbID: String) async -> [TMDBPerson] {
        guard let lookup = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdbID)"),
              let show = try? await HTTP.jsonObject(HTTP.request(lookup, timeout: 10)) as? [String: Any],
              let id = show["id"] as? Int,
              let castURL = URL(string: "https://api.tvmaze.com/shows/\(id)/cast"),
              let list = try? await HTTP.jsonObject(HTTP.request(castURL, timeout: 10)) as? [[String: Any]] else { return [] }
        var out: [TMDBPerson] = list.compactMap { row in
            guard let person = row["person"] as? [String: Any], let name = person["name"] as? String else { return nil }
            let character = (row["character"] as? [String: Any])?["name"] as? String
            let photo = ((person["image"] as? [String: Any])?["original"] as? String) ?? ((person["image"] as? [String: Any])?["medium"] as? String)
            return TMDBPerson(id: 0, name: name, role: character, photo: photo)
        }
        if let crewURL = URL(string: "https://api.tvmaze.com/shows/\(id)/crew"),
           let crew = try? await HTTP.jsonObject(HTTP.request(crewURL, timeout: 10)) as? [[String: Any]] {
            for row in crew where (row["type"] as? String) == "Creator" {
                guard let person = row["person"] as? [String: Any], let name = person["name"] as? String,
                      !out.contains(where: { $0.name == name }) else { continue }
                let photo = (person["image"] as? [String: Any])?["medium"] as? String
                out.append(TMDBPerson(id: 0, name: name, role: "Creator", photo: photo))
            }
        }
        return out
    }

    /// A headshot from IMDb's public suggestion endpoint (first person match).
    private static func imdbPhoto(name: String) async -> String? {
        let slug = name.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        guard let first = name.lowercased().first,
              let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/\(first)/\(slug).json"),
              let obj = try? await HTTP.jsonObject(HTTP.request(url, timeout: 8)) as? [String: Any],
              let results = obj["d"] as? [[String: Any]],
              let person = results.first(where: { ($0["id"] as? String)?.hasPrefix("nm") == true }),
              let image = (person["i"] as? [String: Any])?["imageUrl"] as? String else { return nil }
        // Ask for a small rendition.
        return image.replacingOccurrences(of: "._V1_.jpg", with: "._V1_UY400_.jpg")
    }
}
