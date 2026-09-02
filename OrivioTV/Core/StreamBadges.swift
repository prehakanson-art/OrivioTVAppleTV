import Foundation
import SwiftUI

/// Badger integration (https://nintle.github.io/Badger/): community-made
/// badge packs for stream rows. A pack is a JSON config of regex filters —
/// each with a badge image URL and/or tag colors — matched against a link's
/// filename/name/title/description; matches render as chips on the source
/// row. Schema mirrors the official Android app's StreamBadgeRules parser
/// (filters[]: name/pattern/imageURL/isEnabled/tagColor/tagStyle/textColor/
/// borderColor; unknown keys ignored; groups only organize the editor).
struct StreamBadge: Equatable, Identifiable {
    let name: String
    let imageURL: String
    let tagColor: String
    let tagStyle: String
    let textColor: String
    let borderColor: String

    var id: String { "\(name)|\(imageURL)" }
    var isImage: Bool { !imageURL.isEmpty }
}

@MainActor
final class StreamBadgeStore: ObservableObject {
    @Published private(set) var sourceURL: String = ""
    @Published private(set) var filterCount: Int = 0
    /// Human-readable outcome of the last import attempt, for the Settings row.
    @Published private(set) var lastStatus: String?

    var isConfigured: Bool { filterCount > 0 }

    // MARK: Badge size (device-local)
    /// Chip size multiplier: 0 = small, 1 = medium (default), 2 = large.
    static let sizeOptions: [(String, String, CGFloat)] = [
        ("small", "Small", 0.8), ("medium", "Medium", 1.0), ("large", "Large", 1.35)
    ]
    private static let sizeKey = "orivio.badges.size.v1"
    static var sizeRaw: String {
        get { UserDefaults.standard.string(forKey: sizeKey) ?? "medium" }
        set { UserDefaults.standard.set(newValue, forKey: sizeKey) }
    }
    static var sizeScale: CGFloat {
        sizeOptions.first { $0.0 == sizeRaw }?.2 ?? 1.0
    }
    /// Published mirror so Settings rows re-render on change.
    @Published var sizeRawUI: String = StreamBadgeStore.sizeRaw
    func setSize(_ raw: String) { Self.sizeRaw = raw; sizeRawUI = raw }

    // MARK: Remote badge profiles
    /// Badge configs found on the account, one per platform blob (a user with
    /// packs configured in several Orivio apps has several "profiles").
    struct RemoteBadgeProfile: Identifiable, Equatable {
        let id: String        // "<platform>#<importIndex>"
        let label: String
        let count: Int
        let platform: String
        let importIndex: Int
    }
    @Published private(set) var remoteProfiles: [RemoteBadgeProfile] = []
    /// Raw rules JSON per platform, kept so switching profiles applies locally.
    private var remoteRulesByPlatform: [String: String] = [:]
    private static let preferredPlatformKey = "orivio.badges.platform.v1"
    var preferredRemoteProfileID: String {
        get { UserDefaults.standard.string(forKey: Self.preferredPlatformKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredPlatformKey) }
    }
    /// Expand every platform blob's imports into selectable profiles.
    func setRemoteRules(_ rulesByPlatform: [String: String]) {
        remoteRulesByPlatform = rulesByPlatform
        var profiles: [RemoteBadgeProfile] = []
        for (platform, json) in rulesByPlatform.sorted(by: { $0.key < $1.key }) {
            guard let d = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let imports = root["imports"] as? [[String: Any]] else { continue }
            for (i, imp) in imports.enumerated() {
                let n = (imp["filters"] as? [[String: Any]])?.count ?? 0
                guard n > 0 else { continue }
                let src = (imp["sourceUrl"] as? String ?? "")
                let name = (imp["name"] as? String)
                    ?? src.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".json", with: "")
                    ?? "Pack \(i + 1)"
                profiles.append(RemoteBadgeProfile(
                    id: "\(platform)#\(i)", label: "\(name) (\(n))",
                    count: n, platform: platform, importIndex: i))
            }
        }
        remoteProfiles = profiles
    }
    /// Apply the chosen profile (or the active/first when none chosen).
    func applyChosenRemoteProfile() {
        let chosen = remoteProfiles.first { $0.id == preferredRemoteProfileID } ?? remoteProfiles.first
        guard let chosen, let rules = remoteRulesByPlatform[chosen.platform] else { return }
        applyRemoteRules(rules, importIndex: chosen.importIndex)
    }

    private struct Compiled {
        let regex: NSRegularExpression
        /// Cheap lowercase literal pre-screen (same trick as the Android app):
        /// skip the regex when the candidate doesn't even contain this.
        let hint: String?
        let badge: StreamBadge
    }

    private var compiled: [Compiled] = []
    /// Per-entry match cache — entries are immutable, rows re-render often.
    private var cache: [UUID: [StreamBadge]] = [:]

    private static let urlKey = "orivio.badges.url.v1"
    private static let payloadKey = "orivio.badges.payload.v1"

    /// Fired after a LOCAL config change (import/remove) so account sync can
    /// push. Suppressed while applying remote data.
    var onLocalChange: (() -> Void)?
    private var suppressChange = false

    /// Wired by OrivioSyncManager: pull the account's badge config on demand
    /// (the Settings card's "Sync from Account" button). Returns a status line.
    var remoteSync: (() async -> String)?

    /// Manual account sync, surfacing the result in `lastStatus`.
    func syncFromAccount() async {
        guard let remoteSync else {
            lastStatus = "Account sync isn't ready yet"
            return
        }
        lastStatus = await remoteSync()
    }

    init() {
        sourceURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        if let payload = UserDefaults.standard.data(forKey: Self.payloadKey) {
            compileFilters(from: payload)
        }
    }

    // MARK: - Import / remove

    /// Fetch a Badger JSON config and activate it. Returns nil on success,
    /// else an error description (also mirrored into `lastStatus`).
    @discardableResult
    func importConfig(from urlString: String) async -> String? {
        // Normalize paste-service links to their RAW endpoint so a plain
        // pastebin.com/<id> link (which serves an HTML page) fetches the JSON.
        let trimmed = Self.normalizePasteURL(urlString.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            lastStatus = "Enter a valid http(s) URL"
            return lastStatus
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request)
            let count = try Self.parseFilters(from: data).count
            guard count > 0 else {
                lastStatus = "No usable filters in that config"
                return lastStatus
            }
            UserDefaults.standard.set(trimmed, forKey: Self.urlKey)
            UserDefaults.standard.set(data, forKey: Self.payloadKey)
            sourceURL = trimmed
            compileFilters(from: data)
            lastStatus = "Imported \(filterCount) badge filters"
            if !suppressChange { onLocalChange?() }
            return nil
        } catch {
            lastStatus = "Import failed: \(error.localizedDescription)"
            return lastStatus
        }
    }

    /// Turn a human paste link into its raw-text URL so `badges.json` hosted on a
    /// paste service loads. Non-paste URLs (and already-raw links) pass through.
    ///   pastebin.com/<id>       → pastebin.com/raw/<id>
    ///   gist.github.com/…/<id>  → gist.githubusercontent.com/…/<id>/raw
    ///   dpaste.org/<id>         → dpaste.org/<id>/raw
    static func normalizePasteURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host?.lowercased() else { return s }
        let parts = u.path.split(separator: "/").map(String.init)
        switch host {
        case "pastebin.com", "www.pastebin.com":
            if parts.count == 1, parts[0] != "raw" { return "https://pastebin.com/raw/\(parts[0])" }
        case "dpaste.org", "dpaste.com":
            if parts.count == 1 { return "https://\(host)/\(parts[0])/raw" }
        case "gist.github.com":
            if !s.hasSuffix("/raw") { return s + "/raw" }
        default:
            break
        }
        return s
    }

    func removeConfig() {
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        UserDefaults.standard.removeObject(forKey: Self.payloadKey)
        sourceURL = ""
        compiled = []
        cache = [:]
        filterCount = 0
        lastStatus = nil
        if !suppressChange { onLocalChange?() }
    }

    // MARK: - Orivio account sync (mirrors Android's stream_badge_settings)

    /// Apply the account's badge rules — the Android/Fusion `StreamBadgeRules`
    /// JSON: `{"imports":[{"sourceUrl","filters":[…],"groups":[…],"isActive"}]}`.
    /// The active import's EMBEDDED filters are used directly (no re-fetch),
    /// so a pack imported on another device lights up here immediately.
    func applyRemoteRules(_ rulesJSON: String, importIndex: Int? = nil) {
        guard let data = rulesJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imports = root["imports"] as? [[String: Any]], !imports.isEmpty
        else {
            // Empty/removed remotely → clear locally too (only if we had one).
            if isConfigured {
                suppressChange = true
                removeConfig()
                suppressChange = false
            }
            return
        }
        let active: [String: Any]
        if let importIndex, imports.indices.contains(importIndex) { active = imports[importIndex] }
        else { active = imports.first { ($0["isActive"] as? Bool ?? $0["active"] as? Bool) == true } ?? imports[0] }
        let remoteURL = (active["sourceUrl"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let filters = active["filters"] as? [[String: Any]], !filters.isEmpty else { return }
        // Same source already active → nothing to do.
        if importIndex == nil, isConfigured, !remoteURL.isEmpty,
           remoteURL.caseInsensitiveCompare(sourceURL) == .orderedSame { return }

        guard let payload = try? JSONSerialization.data(withJSONObject: ["filters": filters]) else { return }
        suppressChange = true
        UserDefaults.standard.set(remoteURL, forKey: Self.urlKey)
        UserDefaults.standard.set(payload, forKey: Self.payloadKey)
        sourceURL = remoteURL
        compileFilters(from: payload)
        lastStatus = "Synced \(filterCount) badge filters from your Orivio account"
        suppressChange = false
    }

    /// Our config in the Android `StreamBadgeRules` shape, for pushing to the
    /// account. nil when nothing is configured (encoded as empty imports so
    /// other devices clear too).
    func syncRulesJSON() -> String? {
        guard isConfigured,
              let payload = UserDefaults.standard.data(forKey: Self.payloadKey),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let filters = root["filters"] as? [[String: Any]]
        else {
            return #"{"imports":[]}"#
        }
        let rules: [String: Any] = [
            "imports": [[
                "sourceUrl": sourceURL,
                "filters": filters,
                "groups": (root["groups"] as? [[String: Any]]) ?? [],
                "isActive": true,
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Matching

    /// Badges for one source row, matched once and cached (regex work).
    func badges(for entry: StreamEntry) -> [StreamBadge] {
        guard !compiled.isEmpty else { return [] }
        if let hit = cache[entry.id] { return hit }
        if cache.count > 4096 { cache = [:] }   // bound a long session

        // Same candidate set as the Android matcher, reduced to our model.
        let candidates = [
            entry.stream.behaviorHints?.filename,
            entry.stream.name,
            entry.stream.title,
            entry.stream.description,
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !candidates.isEmpty else { cache[entry.id] = []; return [] }
        let lowered = candidates.map { $0.lowercased() }

        var seen = Set<String>()
        var matched: [StreamBadge] = []
        outer: for filter in compiled {
            for (i, candidate) in candidates.enumerated() {
                if let hint = filter.hint, !lowered[i].contains(hint) { continue }
                let range = NSRange(candidate.startIndex..., in: candidate)
                if filter.regex.firstMatch(in: candidate, range: range) != nil {
                    if seen.insert(filter.badge.id).inserted { matched.append(filter.badge) }
                    continue outer
                }
            }
        }
        cache[entry.id] = matched
        return matched
    }

    // MARK: - Parsing (tolerant, mirrors the Android schema)

    private struct Payload: Decodable {
        struct Filter: Decodable {
            let name: String?
            let pattern: String?
            let imageURL: String?
            let isEnabled: Bool?
            let tagColor: String?
            let tagStyle: String?
            let textColor: String?
            let borderColor: String?
        }
        let filters: [Filter]?
    }

    private static func parseFilters(from data: Data) throws -> [(pattern: String, badge: StreamBadge)] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.filters ?? []).compactMap { filter in
            let name = (filter.name ?? "").trimmingCharacters(in: .whitespaces)
            let pattern = (filter.pattern ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !pattern.isEmpty, filter.isEnabled ?? true else { return nil }
            let badge = StreamBadge(
                name: name,
                imageURL: filter.imageURL ?? "",
                tagColor: filter.tagColor ?? "",
                tagStyle: filter.tagStyle ?? "",
                textColor: filter.textColor ?? "",
                borderColor: filter.borderColor ?? ""
            )
            return (pattern, badge)
        }
    }

    private func compileFilters(from data: Data) {
        let parsed = (try? Self.parseFilters(from: data)) ?? []
        compiled = parsed.compactMap { pattern, badge in
            // No implicit flags — Badger patterns carry their own (?i) etc.,
            // matching how the Android app compiles them.
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Compiled(regex: regex, hint: Self.literalHint(pattern), badge: badge)
        }
        filterCount = compiled.count
        cache = [:]
    }

    /// A short literal extracted from simple patterns for the pre-screen;
    /// nil when the pattern is too regex-y to reduce safely.
    private static func literalHint(_ pattern: String) -> String? {
        let meta = CharacterSet(charactersIn: #"\[](){}*+?|^$."#)
        if pattern.count >= 2, pattern.rangeOfCharacter(from: meta) == nil {
            return pattern.lowercased()
        }
        if pattern.contains("|") { return nil }
        let stripped = pattern
            .replacingOccurrences(of: #"\b"#, with: "")
            .replacingOccurrences(of: "(?i)", with: "")
            .replacingOccurrences(of: "(?:", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        if stripped.count >= 2, stripped.rangeOfCharacter(from: meta) == nil {
            return stripped.lowercased()
        }
        return nil
    }
}

// MARK: - Chip rendering

/// One row of badge chips, visually matching the Android app: 20pt-tall
/// chips. NEVER invisible: an image badge shows its text-tag form until the
/// image loads (and keeps it if the image fails — some packs use formats
/// UIKit can't decode, and most set all their colors fully transparent
/// because they only intend the image to show).
struct StreamBadgeChips: View {
    let badges: [StreamBadge]
    /// User badge size multiplier (Settings → badges). Read once per render.
    private var scale: CGFloat { StreamBadgeStore.sizeScale }

    var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(badges.prefix(6)) { badge in
                BadgeChip(badge: badge, scale: scale)
            }
        }
    }
}

/// One chip, drawn the way the Badger editor / Orivio app draw it: the badge's
/// logo (or, image-less, its name text) sits inside a ROUNDED RECTANGLE filled
/// with `tagColor` and stroked with `borderColor`. The color is the frame
/// around the logo — earlier we drew the bare logo with no frame, so packs that
/// carry their color only in the tag/border looked monochrome.
private struct BadgeChip: View {
    let badge: StreamBadge
    var scale: CGFloat = 1

    /// Badger bakes at 30px tall with a 6.2px face radius (radius ≈ 0.2·h);
    /// keep that ratio at a TV-legible base height.
    private var height: CGFloat { 26 * scale }
    private var radius: CGFloat { 5.5 * scale }
    private var fill: Color? { Color(badgeHex: badge.tagColor) }
    private var border: Color? { Color(badgeHex: badge.borderColor) }
    /// A chip carrying its own frame (fill and/or border) pads its content and
    /// draws the rounded rect. When both are transparent (image-only "snapshot"
    /// packs whose color is baked into the PNG) the logo is the whole badge.
    private var hasFrame: Bool { fill != nil || border != nil }
    private var padX: CGFloat { hasFrame ? 7 * scale : 0 }
    private var padY: CGFloat { hasFrame ? 3.5 * scale : 0 }
    /// Height of the logo/text inside the frame.
    private var contentHeight: CGFloat { height - 2 * padY }

    var body: some View {
        content
            .frame(height: contentHeight)
            .padding(.horizontal, padX)
            .padding(.vertical, padY)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill ?? .clear))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border ?? .clear, lineWidth: border != nil ? 1.5 * scale : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .fixedSize()
    }

    /// The logo image (its natural aspect, sized to the chip height), or the
    /// name text when image-less or the image can't be decoded.
    @ViewBuilder private var content: some View {
        if badge.isImage {
            AsyncImage(url: URL(string: badge.imageURL)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    textLabel   // visible placeholder / fallback
                }
            }
        } else {
            textLabel
        }
    }

    /// Text form — name in `textColor` (falling back to `tagColor`, then a
    /// readable default so it never vanishes).
    private var textLabel: some View {
        let text = Color(badgeHex: badge.textColor) ?? fill ?? .white.opacity(0.9)
        return Text(badge.name)
            .font(.system(size: 13 * scale, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(text)
    }
}

extension Color {
    /// Badger color strings: "#RRGGBB" / "#AARRGGBB" / bare hex. Fully
    /// transparent values (alpha 0) return nil so callers use their default —
    /// image-only packs ship "#00000000" everywhere.
    init?(badgeHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        guard !hex.isEmpty else { return nil }
        let lower = hex.lowercased()
        // rgb(r,g,b) / rgba(r,g,b,a) — Badger packs exported from web tools.
        if lower.hasPrefix("rgb") {
            let nums = lower.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count >= 3 else { return nil }
            let a = nums.count >= 4 ? nums[3] : 1
            guard a > 0.01 else { return nil }
            self.init(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, opacity: a)
            return
        }
        // Common CSS color names.
        let named: [String: UInt64] = [
            "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x008000,
            "blue": 0x0000FF, "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080,
            "pink": 0xFFC0CB, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "gold": 0xFFD700,
            "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080, "teal": 0x008080,
            "lime": 0x00FF00, "crimson": 0xDC143C, "violet": 0xEE82EE
        ]
        if let v = named[lower] {
            self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255)
            return
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        // 3-digit shorthand (#FA0 → #FFAA00).
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        case 8:
            let alpha = Double((value >> 24) & 0xFF) / 255
            guard alpha > 0.01 else { return nil }
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: alpha
            )
        default:
            return nil
        }
    }
}
