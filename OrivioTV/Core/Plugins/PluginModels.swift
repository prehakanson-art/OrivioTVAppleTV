import Foundation

/// A Orivio plugin repository (a manifest.json listing JS scrapers). Mirrors the
/// Android `PluginRepository` / `PluginManifest` shape so the same repos work.
struct PluginRepository: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String              // manifest URL
    var description: String?
    var enabled: Bool = true
    var scraperCount: Int = 0
}

/// One scraper as declared in a repo manifest.
struct ScraperManifestInfo: Codable, Hashable {
    let id: String
    let name: String
    var description: String?
    let version: String
    let filename: String                       // JS file, resolved against the manifest URL
    var supportedTypes: [String] = ["movie", "tv"]
    var enabled: Bool = true
    var logo: String?

    init(id: String, name: String, description: String? = nil, version: String,
         filename: String, supportedTypes: [String] = ["movie", "tv"],
         enabled: Bool = true, logo: String? = nil) {
        self.id = id; self.name = name; self.description = description
        self.version = version; self.filename = filename
        self.supportedTypes = supportedTypes; self.enabled = enabled; self.logo = logo
    }

    /// Swift's SYNTHESIZED decoder ignores property defaults and demands every
    /// non-optional key. These repo manifests are written for the Android/Gson
    /// side, where the same fields are optional — so a manifest omitting
    /// `enabled`, `supportedTypes` or `version` failed to decode and the user
    /// saw "Couldn't add repository: The data couldn't be read", with no clue
    /// which field was missing. Decode the optional-by-intent ones leniently.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        filename = try c.decode(String.self, forKey: .filename)
        supportedTypes = try c.decodeIfPresent([String].self, forKey: .supportedTypes) ?? ["movie", "tv"]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
    }
}

struct PluginManifest: Codable {
    let name: String
    let version: String
    var description: String?
    var author: String?
    let scrapers: [ScraperManifestInfo]

    /// Same leniency as above: only `name` and `scrapers` are truly required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        scrapers = try c.decodeIfPresent([ScraperManifestInfo].self, forKey: .scrapers) ?? []
    }
}

/// An installed scraper: manifest info + which repo it came from + local enable
/// state + the cached JS source.
struct ScraperInfo: Codable, Identifiable, Hashable {
    var id: String                 // "<repoId>:<scraperId>"
    var repoID: String
    var scraperID: String
    var name: String
    var version: String
    var supportedTypes: [String]
    var enabled: Bool
    var logo: String?
    /// URL the scraper JS was fetched from (cached separately on disk).
    var sourceURL: String

    func supports(type: String) -> Bool {
        let t = type == "series" ? "tv" : type
        return supportedTypes.contains(t) || supportedTypes.contains(type)
    }
}

/// A raw stream object returned by a scraper's getStreams().
struct ScraperResult: Decodable {
    let url: String
    var title: String?
    var name: String?
    var quality: String?
    var size: String?
    var language: String?
    var provider: String?
    var type: String?
    var seeders: Int?
    var infoHash: String?
    var headers: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case url, title, name, quality, size, language, provider, type, seeders, infoHash, headers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `url` is a string OR an object { url, headers }.
        if let s = try? c.decode(String.self, forKey: .url) {
            url = s
        } else if let obj = try? c.decode(URLObject.self, forKey: .url) {
            url = obj.url
        } else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "missing url")
        }
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        quality = try? c.decodeIfPresent(String.self, forKey: .quality)
        size = Self.looseString(c, .size)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        seeders = try? c.decodeIfPresent(Int.self, forKey: .seeders)
        infoHash = try? c.decodeIfPresent(String.self, forKey: .infoHash)
        headers = try? c.decodeIfPresent([String: String].self, forKey: .headers)
    }

    private struct URLObject: Decodable { let url: String }
    private static func looseString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return String(n) }
        return nil
    }
}
