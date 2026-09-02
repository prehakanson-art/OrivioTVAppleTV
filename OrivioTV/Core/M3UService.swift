import Foundation

/// One channel parsed from an M3U/M3U8 playlist.
struct M3UChannel: Identifiable, Hashable {
    let id: String        // the stream URL (stable + unique enough)
    let name: String
    let url: String
    let logo: String?
    let group: String
    /// ISO country code from the tvg-id (e.g. "BBCAmerica.us@East" → "us"), if any.
    let country: String?
    var id_: String { id }
}

/// Parses an M3U playlist (e.g. the embedded iptv-org global list) into channels
/// with their group, logo and direct stream URL. Fetch + parse happen off the
/// main actor; the result is cached in memory for the session.
enum M3UService {
    /// The playlist embedded into Live TV so channels exist without installing
    /// any add-on.
    static let iptvOrgURL = "https://iptv-org.github.io/iptv/index.m3u"

    private static var cache: [String: [M3UChannel]] = [:]
    private static let lock = NSLock()

    static func channels(from urlString: String) async -> [M3UChannel] {
        lock.lock(); let hit = cache[urlString]; lock.unlock()
        if let hit { return hit }

        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let parsed = await Task.detached(priority: .userInitiated) { parse(text) }.value
        lock.lock(); cache[urlString] = parsed; lock.unlock()
        return parsed
    }

    static func parse(_ text: String) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var seen = Set<String>()
        var pendingName: String?
        var pendingLogo: String?
        var pendingGroup: String?
        var pendingCountry: String?

        text.enumerateLines { line, _ in
            if line.hasPrefix("#EXTINF") {
                pendingName = name(from: line)
                pendingLogo = attribute("tvg-logo", in: line)
                pendingGroup = attribute("group-title", in: line)
                pendingCountry = country(fromTvgID: attribute("tvg-id", in: line))
            } else if line.hasPrefix("#") {
                // #EXTVLCOPT / #EXTGRP etc. — ignore, keep pending.
                if line.hasPrefix("#EXTGRP:") {
                    pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                let url = line.trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty, let nm = pendingName, !nm.isEmpty else { return }
                if seen.insert(url).inserted {
                    channels.append(M3UChannel(
                        id: url, name: nm, url: url,
                        logo: pendingLogo?.isEmpty == false ? pendingLogo : nil,
                        group: (pendingGroup?.isEmpty == false ? pendingGroup! : "Other"),
                        country: pendingCountry
                    ))
                }
                pendingName = nil; pendingLogo = nil; pendingGroup = nil; pendingCountry = nil
            }
        }
        return channels
    }

    /// Value of an `attr="value"` pair on an #EXTINF line.
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// The 2-letter country code embedded in a tvg-id like "BBCAmerica.us@East"
    /// or "AlMajd.sa" — the segment after the last "." (before any "@").
    private static func country(fromTvgID tvgID: String?) -> String? {
        guard let raw = tvgID, !raw.isEmpty else { return nil }
        let beforeAt = raw.split(separator: "@", maxSplits: 1).first.map(String.init) ?? raw
        guard let cc = beforeAt.split(separator: ".").last.map(String.init),
              cc.count == 2, cc.allSatisfy({ $0.isLetter }) else { return nil }
        return cc.lowercased()
    }

    /// The channel name — the text after the first comma that isn't inside quotes.
    private static func name(from line: String) -> String {
        var inQuote = false
        for (i, c) in line.enumerated() {
            if c == "\"" { inQuote.toggle() }
            else if c == "," && !inQuote {
                let start = line.index(line.startIndex, offsetBy: i + 1)
                return String(line[start...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
