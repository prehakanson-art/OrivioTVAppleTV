import Foundation

/// A parsed incoming deep link. Mirrors the Android DeepLinkParser: `orivio://`
/// links open a title; `stremio://…/manifest.json` installs an addon.
enum DeepLink: Equatable {
    /// Open a title's detail page. `id` is a Stremio id (`tt…` or `tmdb:<n>`).
    case meta(type: String, id: String)
    /// Install a Stremio/Orivio addon from its manifest URL.
    case addonInstall(url: String)
    /// An external player finished and handed playback back to us
    /// (x-callback-url `x-success`). Infuse returns the url it stopped on and
    /// the position in seconds; that's what updates Continue Watching.
    case externalPlaybackFinished(streamURL: String?, position: Double?)
    /// An external player refused the stream (x-callback-url `x-error`).
    case externalPlaybackFailed(message: String?)
}

enum DeepLinkService {
    static func parse(_ url: URL) -> DeepLink? {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        // Path segments without the leading slash.
        let segments = url.path.split(separator: "/").map(String.init)

        if scheme == "stremio" {
            // stremio://<addon-host>/manifest.json → install.
            return looksLikeAddonHost(host) ? .addonInstall(url: httpsManifest(from: url)) : nil
        }
        // Both accepted: "orivio" is current, "nuvio" stays valid for links
        // saved before the rename and for external-player callbacks issued by
        // an older build that is still mid-handoff.
        guard scheme == "orivio" || scheme == "nuvio" else {
            // A bare https manifest link also installs.
            if scheme == "https", url.absoluteString.lowercased().hasSuffix("manifest.json") {
                return .addonInstall(url: url.absoluteString)
            }
            return nil
        }

        let query = queryParams(url)
        switch host {
        // x-callback returns from an external player. Matched BEFORE the
        // catch-all below, which would otherwise try to read them as addon
        // hosts.
        case "external-return", "externalreturn", "external-success":
            return .externalPlaybackFinished(
                streamURL: firstParam(query, "lastplayedurl", "url"),
                position: firstParam(query, "position").flatMap(Double.init)
            )
        case "external-error", "externalerror":
            return .externalPlaybackFailed(message: firstParam(query, "errormessage", "message"))
        case "meta":
            if let type = firstParam(query, "type", "mediatype", "media_type"),
               let id = metaID(query) {
                return .meta(type: normalizeType(type), id: id)
            }
            return metaFromPath(segments)
        case "detail", "details", "open", "watch":
            return metaFromPath(segments)
        case "imdb", "tmdb":
            guard let raw = segments.first else { return nil }
            let type = normalizeType(firstParam(query, "type", "mediatype", "media_type") ?? "movie")
            let id = host == "tmdb" ? "tmdb:\(raw)" : raw
            return .meta(type: type, id: id)
        case "movie", "movies", "film", "series", "show", "tv":
            guard let raw = segments.first else { return nil }
            return .meta(type: normalizeType(host), id: normalizeID(raw))
        default:
            if looksLikeAddonHost(host) {
                return .addonInstall(url: httpsManifest(from: url))
            }
            return nil
        }
    }

    // MARK: Helpers

    private static func metaFromPath(_ segments: [String]) -> DeepLink? {
        guard segments.count >= 2 else { return nil }
        let type = normalizeType(segments[0])
        let id = normalizeID(segments[1])
        return type.isEmpty || id.isEmpty ? nil : .meta(type: type, id: id)
    }

    private static func metaID(_ query: [String: String]) -> String? {
        if let imdb = firstParam(query, "id", "imdb", "imdbid", "imdb_id"), !imdb.isEmpty {
            return normalizeID(imdb)
        }
        if let tmdb = firstParam(query, "tmdb", "tmdbid", "tmdb_id"), !tmdb.isEmpty {
            return "tmdb:\(tmdb)"
        }
        return nil
    }

    private static func normalizeType(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "series", "show", "tv", "shows": return "series"
        case "movie", "movies", "film": return "movie"
        default: return value.lowercased()
        }
    }

    /// A bare TMDB numeric id becomes `tmdb:<n>`; everything else passes through.
    private static func normalizeID(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("tt") || v.hasPrefix("tmdb:") || v.contains(":") { return v }
        if Int(v) != nil { return "tmdb:\(v)" }
        return v
    }

    private static func looksLikeAddonHost(_ host: String) -> Bool {
        host.contains(".")
    }

    private static func httpsManifest(from url: URL) -> String {
        var s = url.absoluteString
        if let range = s.range(of: "://") { s.replaceSubrange(s.startIndex..<range.lowerBound, with: "https") }
        return s
    }

    private static func queryParams(_ url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items where item.value != nil { out[item.name.lowercased()] = item.value }
        return out
    }

    private static func firstParam(_ query: [String: String], _ keys: String...) -> String? {
        for key in keys { if let v = query[key.lowercased()], !v.isEmpty { return v } }
        return nil
    }
}
