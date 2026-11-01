import Foundation

// MARK: - Manifest

struct CatalogExtra: Codable, Hashable {
    var name: String
    var isRequired: Bool
    var options: [String]

    init(name: String, isRequired: Bool = false, options: [String] = []) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string(AnyKey("name")) ?? ""
        isRequired = c.bool(AnyKey("isRequired")) ?? false
        options = c.stringList(AnyKey("options"))
    }
}

struct ManifestCatalog: Codable, Hashable, Identifiable {
    var type: String
    var id: String
    var name: String
    var extra: [CatalogExtra]
    var extraRequired: [String]
    var extraSupported: [String]

    var key: String { "\(type)/\(id)" }

    init(type: String, id: String, name: String, extra: [CatalogExtra] = [], extraRequired: [String] = [], extraSupported: [String] = []) {
        self.type = type
        self.id = id
        self.name = name
        self.extra = extra
        self.extraRequired = extraRequired
        self.extraSupported = extraSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = c.string(AnyKey("type")) ?? "movie"
        id = c.string(AnyKey("id")) ?? ""
        name = c.string(AnyKey("name")) ?? id
        extra = c.lossyArray(CatalogExtra.self, AnyKey("extra"))
        extraRequired = c.stringList(AnyKey("extraRequired"))
        extraSupported = c.stringList(AnyKey("extraSupported"))
    }

    /// A catalog that *requires* any extra can't be a Home row.
    var requiresExtra: Bool {
        extra.contains { $0.isRequired } || !extraRequired.isEmpty
    }

    var supportsSearch: Bool {
        extra.contains { $0.name == "search" } || extraSupported.contains("search")
    }

    var isSearchOnly: Bool {
        (extra.first { $0.name == "search" }?.isRequired ?? false) || extraRequired.contains("search")
    }

    var supportsSkip: Bool {
        extra.contains { $0.name == "skip" } || extraSupported.contains("skip")
    }

    var genreOptions: [String] {
        extra.first { $0.name == "genre" }?.options ?? []
    }

    var genreRequired: Bool {
        (extra.first { $0.name == "genre" }?.isRequired ?? false) || extraRequired.contains("genre")
    }
}

struct ManifestResource: Codable, Hashable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?

    init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.string(AnyKey("name")) ?? ""
        let t = c.stringList(AnyKey("types"))
        types = t.isEmpty ? nil : t
        let p = c.stringList(AnyKey("idPrefixes"))
        idPrefixes = p.isEmpty ? nil : p
    }
}

struct AddonBehaviorHints: Codable, Hashable {
    var configurable: Bool = false
    var configurationRequired: Bool = false
    var adult: Bool = false
}

struct AddonManifest: Codable, Hashable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var logo: String?
    var background: String?
    var types: [String]
    var idPrefixes: [String]
    var catalogs: [ManifestCatalog]
    var resources: [ManifestResource]
    var behaviorHints: AddonBehaviorHints?

    /// A 200 that wasn't a manifest (captive portal, WAF page) decodes to this.
    var isPlaceholder: Bool { id.isEmpty || (resources.isEmpty && catalogs.isEmpty && name.isEmpty) }

    static func placeholder(name: String = "") -> AddonManifest {
        AddonManifest(id: "", name: name, version: "", description: nil, logo: nil, background: nil,
                      types: [], idPrefixes: [], catalogs: [], resources: [], behaviorHints: nil)
    }

    init(id: String, name: String, version: String, description: String?, logo: String?, background: String?,
         types: [String], idPrefixes: [String], catalogs: [ManifestCatalog], resources: [ManifestResource],
         behaviorHints: AddonBehaviorHints?) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.logo = logo
        self.background = background
        self.types = types
        self.idPrefixes = idPrefixes
        self.catalogs = catalogs
        self.resources = resources
        self.behaviorHints = behaviorHints
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: AnyKey.self) else {
            self = .placeholder()
            return
        }
        id = c.string(AnyKey("id")) ?? ""
        name = c.string(AnyKey("name")) ?? ""
        version = c.string(AnyKey("version")) ?? ""
        description = c.string(AnyKey("description"))
        logo = c.string(AnyKey("logo"))
        background = c.string(AnyKey("background"))
        types = c.stringList(AnyKey("types"))
        idPrefixes = c.stringList(AnyKey("idPrefixes"))
        catalogs = c.lossyArray(ManifestCatalog.self, AnyKey("catalogs"))
        resources = c.lossyArray(ManifestResource.self, AnyKey("resources"))
        behaviorHints = try? c.decodeIfPresent(AddonBehaviorHints.self, forKey: AnyKey("behaviorHints"))
    }

    func provides(_ resource: String) -> Bool {
        resources.contains { $0.name == resource }
    }

    /// Whether this add-on claims `resource` for a given type and id.
    func handles(_ resource: String, type: String, id: String) -> Bool {
        guard let r = resources.first(where: { $0.name == resource }) else { return false }
        let typeList = r.types ?? types
        if !typeList.isEmpty, !typeList.contains(type) { return false }
        let prefixes = r.idPrefixes ?? idPrefixes
        if !prefixes.isEmpty, !prefixes.contains(where: { id.hasPrefix($0) }) { return false }
        return true
    }
}

extension AddonBehaviorHints {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        configurable = c.bool(AnyKey("configurable")) ?? false
        configurationRequired = c.bool(AnyKey("configurationRequired")) ?? false
        adult = c.bool(AnyKey("adult")) ?? false
    }
}

// MARK: - Installed add-on

struct InstalledAddon: Codable, Hashable, Identifiable {
    var manifestURL: String
    var manifest: AddonManifest
    var enabled: Bool = true

    var id: String { manifestURL }

    /// Manifest URL minus `/manifest.json` and any query.
    var baseURL: String { Self.baseURL(for: manifestURL) }

    var displayName: String { manifest.name.isEmpty ? (URL(string: manifestURL)?.host ?? manifestURL) : manifest.name }

    static func baseURL(for manifestURL: String) -> String {
        var s = manifestURL
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if s.hasSuffix("/manifest.json") { s = String(s.dropLast("/manifest.json".count)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizeManifestURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        if !s.contains("manifest.json") {
            while s.hasSuffix("/") { s.removeLast() }
            s += "/manifest.json"
        }
        return s
    }

    var isCinemeta: Bool { manifest.id == "com.linvo.cinemeta" || manifestURL.contains("cinemeta") }

    var isMetadataAddon: Bool { manifest.provides("meta") }
    var isStreamAddon: Bool { manifest.provides("stream") }
    var isSubtitleAddon: Bool { manifest.provides("subtitles") }
}

enum DefaultAddons {
    static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"
    static let openSubtitles = "https://opensubtitles-v3.strem.io/manifest.json"
    static let all = [cinemeta, openSubtitles]
}
