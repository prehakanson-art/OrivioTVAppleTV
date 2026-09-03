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

    private struct Entry: Decodable {
        let transportUrl: String
        /// Optional so a row whose `manifest` is absent or shaped unexpectedly
        /// still surfaces (named after its host) instead of dropping — the
        /// transport URL is the only field Discover actually needs to install.
        let manifest: Manifest?

        private enum CodingKeys: String, CodingKey { case transportUrl, manifest }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            transportUrl = try c.decode(String.self, forKey: .transportUrl)
            manifest = try? c.decode(Manifest.self, forKey: .manifest)
        }
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

    /// Decodes `{"addons":[…]}` LOSSILY, one element at a time.
    ///
    /// This used to be a plain `JSONDecoder().decode(Response.self, …)`, so a
    /// single community-catalog row missing `transportUrl` (or with a manifest
    /// shaped unexpectedly) threw and the whole ~200-entry directory came back
    /// EMPTY — Discover fell back to its six built-ins with nothing to explain
    /// why. Every other decode path here is deliberately lossy; this one now
    /// matches: a bad entry drops only itself.
    private static func decodeEntries(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["addons"] as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(Entry.self, from: elementData)
        }
    }

    private static func fetch(_ urlString: String) async -> [RemoteAddon] {
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return decodeEntries(data).compactMap { entry in
            guard !entry.transportUrl.isEmpty else { return nil }
            let name = entry.manifest?.name
                ?? URL(string: entry.transportUrl)?.host
                ?? "Add-on"
            return RemoteAddon(
                transportUrl: entry.transportUrl,
                name: name,
                description: entry.manifest?.description,
                logo: entry.manifest?.logo,
                types: entry.manifest?.types ?? [],
                resources: (entry.manifest?.resources ?? []).map(\.name)
            )
        }
    }
}
