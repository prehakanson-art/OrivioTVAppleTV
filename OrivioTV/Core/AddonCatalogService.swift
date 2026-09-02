import Foundation

/// One add-on from the Stremio community/official catalog. Mapped from the
/// `addon_catalog` resource that the official apps use to power their add-on
/// directory (see AddonCatalogService).
struct RemoteAddon: Identifiable, Hashable {
    let transportUrl: String
    let name: String
    let description: String?
    let logo: String?
    let types: [String]
    let resources: [String]
    var id: String { transportUrl }

    /// Bucket for the Discover UI. tv/anime win first so IPTV and anime
    /// surface in their own sections even though they also provide streams.
    var category: AddonCategory {
        let t = Set(types.map { $0.lowercased() })
        let r = Set(resources.map { $0.lowercased() })
        if t.contains("tv") { return .liveTV }
        if t.contains("anime") { return .anime }
        if r.contains("subtitles") && !r.contains("stream") { return .subtitles }
        if r.contains("stream") { return .streams }
        if r.contains("catalog") || r.contains("meta") { return .metadata }
        return .other
    }
}

/// Fetches the live Stremio add-on directory — the exact source the official
/// Stremio clients use: the Cinemeta `addon_catalog` resource, split into
/// `official` and `community` collections (~200 add-ons). This is what powers
/// "connect to the community add-ons" in Discover.
enum AddonCatalogService {
    static let officialURL = "https://v3-cinemeta.strem.io/addon_catalog/all/official.json"
    static let communityURL = "https://v3-cinemeta.strem.io/addon_catalog/all/community.json"

    private struct Response: Decodable { let addons: [Entry] }
    private struct Entry: Decodable {
        let transportUrl: String
        let manifest: Manifest
    }
    private struct Manifest: Decodable {
        let name: String?
        let description: String?
        let logo: String?
        let types: [String]?
        let resources: [ManifestResource]?
    }

    /// Official first, then community; de-duplicated by transport URL. Returns
    /// [] on failure so the caller can fall back to its built-in list.
    static func fetchAll() async -> [RemoteAddon] {
        async let official = fetch(officialURL)
        async let community = fetch(communityURL)
        let combined = await official + community
        var seen = Set<String>()
        return combined.filter { seen.insert($0.transportUrl).inserted }
    }

    private static func fetch(_ urlString: String) async -> [RemoteAddon] {
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.addons.compactMap { entry in
            guard !entry.transportUrl.isEmpty else { return nil }
            let name = entry.manifest.name
                ?? URL(string: entry.transportUrl)?.host
                ?? "Add-on"
            return RemoteAddon(
                transportUrl: entry.transportUrl,
                name: name,
                description: entry.manifest.description,
                logo: entry.manifest.logo,
                types: entry.manifest.types ?? [],
                resources: (entry.manifest.resources ?? []).map(\.name)
            )
        }
    }
}
