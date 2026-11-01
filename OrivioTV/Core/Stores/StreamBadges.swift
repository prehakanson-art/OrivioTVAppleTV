import Foundation
import SwiftUI

/// Badger link badges (https://nintle.github.io/Badger/): a community badge pack
/// is a JSON list of regex filters, each with a badge image and/or tag colours,
/// matched against a link's file name / name / title / description. Matches show
/// as chips on the link row. Same schema and account sync as the Android app and
/// the previous Orivio (`stream_badge_settings` → `stream_badge_rules`), so a pack
/// set up in any Orivio app shows up here.
struct StreamBadge: Hashable, Identifiable {
    let name: String
    let imageURL: String
    let tagColor: String
    let textColor: String
    let borderColor: String

    var id: String { "\(name)|\(imageURL)" }
    var isImage: Bool { !imageURL.isEmpty }
}

enum BadgeSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1
        case .large: return 1.35
        }
    }
}

@MainActor
final class StreamBadgeStore: ObservableObject, ProfileScoped {
    /// What's stored per profile: the pack's source and its raw filters JSON.
    private struct Saved: Codable {
        var sourceURL: String
        var payload: Data
        var size: BadgeSize?
        /// Changed here and not yet written to the account.
        var unpushed: Bool?
    }

    @Published private(set) var sourceURL = ""
    @Published private(set) var filterCount = 0
    @Published private(set) var size: BadgeSize = .medium
    /// Outcome of the last import / sync, for the Settings row.
    @Published var lastStatus: String?

    var isConfigured: Bool { filterCount > 0 }

    private struct Compiled {
        let regex: NSRegularExpression
        /// A cheap lowercase literal to pre-screen with before running the regex.
        let hint: String?
        let badge: StreamBadge
    }

    private var compiled: [Compiled] = []
    private var payload = Data()
    private var unpushed = false
    /// Per-link match cache (rows redraw often; links never change).
    private var cache: [String: [StreamBadge]] = [:]
    private static let key = "badges.v1"

    init() { reloadForActiveProfile() }

    func reloadForActiveProfile() {
        let saved = Persistence.loadScoped(Saved.self, base: Self.key, profile: ProfileScope.current)
        sourceURL = saved?.sourceURL ?? ""
        size = saved?.size ?? .medium
        unpushed = saved?.unpushed ?? false
        compile(saved?.payload ?? Data())
        lastStatus = nil
    }

    private func save() {
        Persistence.saveScoped(Saved(sourceURL: sourceURL, payload: payload, size: size, unpushed: unpushed),
                               base: Self.key, profile: ProfileScope.current)
    }

    func setSize(_ s: BadgeSize) {
        size = s
        save()
    }

    // MARK: Import / remove

    /// Fetches a Badger JSON pack and activates it. Returns an error, or nil.
    @discardableResult
    func importPack(from raw: String) async -> String? {
        let trimmed = Self.rawPasteURL(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            lastStatus = "Enter a valid http(s) link"
            return lastStatus
        }
        do {
            let data = try await HTTP.data(url, timeout: 20)
            let count = (try? Self.parse(data).count) ?? 0
            guard count > 0 else {
                lastStatus = "No usable badge filters in that file"
                return lastStatus
            }
            sourceURL = trimmed
            unpushed = true
            compile(data)
            save()
            lastStatus = "Imported \(filterCount) badge filters"
            SyncSignals.markDirty(.profileSettings)
            return nil
        } catch {
            lastStatus = "Import failed: \(error.localizedDescription)"
            return lastStatus
        }
    }

    func remove() {
        sourceURL = ""
        unpushed = true
        compile(Data())
        save()
        lastStatus = nil
        SyncSignals.markDirty(.profileSettings)
    }

    /// pastebin.com/<id> → pastebin.com/raw/<id>, gist pages → their raw text,
    /// so a pack shared as a paste link loads.
    static func rawPasteURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host?.lowercased() else { return s }
        let parts = u.path.split(separator: "/").map(String.init)
        switch host {
        case "pastebin.com", "www.pastebin.com":
            if parts.count == 1, parts[0] != "raw" { return "https://pastebin.com/raw/\(parts[0])" }
        case "dpaste.org", "dpaste.com":
            if parts.count == 1 { return "https://\(host)/\(parts[0])/raw" }
        case "gist.github.com":
            if !s.hasSuffix("/raw") { return s + "/raw" }
        default: break
        }
        return s
    }

    // MARK: Account sync (the Android `StreamBadgeRules` shape)

    /// The account's rules: `{"imports":[{"sourceUrl","filters":[…],"isActive"}]}`.
    /// The active import's embedded filters are used directly (no re-fetch).
    /// Ignored while a local change is still waiting to be pushed.
    func applyRemote(rulesJSON: String) {
        guard !unpushed else { return }
        guard let data = rulesJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imports = root["imports"] as? [[String: Any]], !imports.isEmpty else {
            if isConfigured {
                sourceURL = ""
                compile(Data())
                save()
            }
            return
        }
        let active = imports.first { ($0["isActive"] as? Bool ?? $0["active"] as? Bool) == true } ?? imports[0]
        guard let filters = active["filters"] as? [[String: Any]], !filters.isEmpty,
              let payload = try? JSONSerialization.data(withJSONObject: ["filters": filters]) else { return }
        guard payload != self.payload else { return }
        sourceURL = (active["sourceUrl"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        compile(payload)
        save()
        lastStatus = "Synced \(filterCount) badge filters from your Orivio account"
    }

    /// Our pack for the account, or nil when there's nothing new to write (the
    /// account's copy then stays as it is — it may come from another device).
    func rulesForPush() -> String? {
        guard unpushed else { return nil }
        let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let filters = root?["filters"] as? [[String: Any]] ?? []
        let rules: [String: Any] = filters.isEmpty ? ["imports": []] : [
            "imports": [["sourceUrl": sourceURL, "filters": filters, "groups": root?["groups"] ?? [], "isActive": true]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func didPush() {
        unpushed = false
        save()
    }

    // MARK: Matching

    func badges(for entry: StreamEntry) -> [StreamBadge] {
        guard !compiled.isEmpty else { return [] }
        if let hit = cache[entry.id] { return hit }
        if cache.count > 4096 { cache = [:] }
        let s = entry.stream
        let candidates = [s.behaviorHints?.filename, s.name, s.title, s.description].compactMap { $0?.isEmpty == false ? $0 : nil }
        let lowered = candidates.map { $0.lowercased() }
        var seen = Set<String>()
        var matched: [StreamBadge] = []
        outer: for f in compiled {
            for (i, c) in candidates.enumerated() {
                if let hint = f.hint, !lowered[i].contains(hint) { continue }
                if f.regex.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) != nil {
                    if seen.insert(f.badge.id).inserted { matched.append(f.badge) }
                    continue outer
                }
            }
        }
        cache[entry.id] = matched
        return matched
    }

    // MARK: Parsing (tolerant; unknown keys ignored)

    private struct Payload: Decodable {
        struct Filter: Decodable {
            let name: String?
            let pattern: String?
            let imageURL: String?
            let isEnabled: Bool?
            let tagColor: String?
            let textColor: String?
            let borderColor: String?
        }
        let filters: [Filter]?
    }

    private static func parse(_ data: Data) throws -> [(pattern: String, badge: StreamBadge)] {
        try JSONDecoder().decode(Payload.self, from: data).filters.map { list in
            list.compactMap { f in
                let name = (f.name ?? "").trimmingCharacters(in: .whitespaces)
                let pattern = (f.pattern ?? "").trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !pattern.isEmpty, f.isEnabled ?? true else { return nil }
                return (pattern, StreamBadge(name: name, imageURL: f.imageURL ?? "", tagColor: f.tagColor ?? "",
                                             textColor: f.textColor ?? "", borderColor: f.borderColor ?? ""))
            }
        } ?? []
    }

    private func compile(_ data: Data) {
        payload = data
        let parsed = data.isEmpty ? [] : ((try? Self.parse(data)) ?? [])
        // No implicit flags: Badger patterns carry their own (?i), as on Android.
        compiled = parsed.compactMap { pattern, badge in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Compiled(regex: regex, hint: Self.literalHint(pattern), badge: badge)
        }
        filterCount = compiled.count
        cache = [:]
    }

    /// A literal every match must contain, for simple patterns; nil otherwise.
    private static func literalHint(_ pattern: String) -> String? {
        let meta = CharacterSet(charactersIn: #"\[](){}*+?|^$."#)
        if pattern.count >= 2, pattern.rangeOfCharacter(from: meta) == nil { return pattern.lowercased() }
        if pattern.contains("|") { return nil }
        let stripped = pattern.replacingOccurrences(of: #"\b"#, with: "").replacingOccurrences(of: "(?i)", with: "")
            .replacingOccurrences(of: "(?:", with: "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        if stripped.count >= 2, stripped.rangeOfCharacter(from: meta) == nil { return stripped.lowercased() }
        return nil
    }
}

// MARK: - Chips

/// A row of badge chips (at most six).
struct StreamBadgeChips: View {
    let badges: [StreamBadge]
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(badges.prefix(6)) { BadgeChip(badge: $0, scale: scale) }
        }
    }
}

/// One chip, drawn as the Badger editor draws it: the badge's logo (or its name)
/// inside a rounded rectangle filled with `tagColor` and stroked with
/// `borderColor`. Never invisible: an image badge shows its text form until the
/// image loads, and keeps it if the image can't be decoded.
private struct BadgeChip: View {
    let badge: StreamBadge
    let scale: CGFloat
    @State private var image: UIImage?
    /// On the focused (white) row, a chip with no fill of its own — white text
    /// and border over nothing — would vanish: it switches to the row's ink.
    @Environment(\.rowFocused) private var rowFocused
    private var inked: Bool { rowFocused && Color(badgeHex: badge.tagColor) == nil }

    private var height: CGFloat { 26 * scale }
    private var radius: CGFloat { 5.5 * scale }
    private var fill: Color? { Color(badgeHex: badge.tagColor) }
    private var border: Color? { inked && Color(badgeHex: badge.borderColor) != nil ? Palette.focusInk : Color(badgeHex: badge.borderColor) }
    /// Image-only packs ship transparent colours: the logo is then the whole badge.
    private var hasFrame: Bool { fill != nil || border != nil }
    private var padX: CGFloat { hasFrame ? 7 * scale : 0 }
    private var padY: CGFloat { hasFrame ? 3.5 * scale : 0 }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .colorMultiply(inked ? Palette.focusInk : .white)
            } else {
                Text(badge.name)
                    .font(.system(size: 15 * scale, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(inked ? Palette.focusInk : (Color(badgeHex: badge.textColor) ?? fill ?? .white.opacity(0.9)))
                    .padding(.horizontal, hasFrame ? 0 : 6 * scale)
            }
        }
        .frame(height: height - 2 * padY)
        .padding(.horizontal, padX)
        .padding(.vertical, padY)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill ?? .clear))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(border ?? .clear, lineWidth: border != nil ? 1.5 * scale : 0))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .fixedSize()
        .task(id: badge.imageURL) {
            guard badge.isImage, let u = URL(string: badge.imageURL) else { return }
            if let hit = ImagePipeline.shared.cached(u, maxPixel: 160) { image = hit; return }
            image = await ImagePipeline.shared.image(u, maxPixel: 160)
        }
    }
}

extension Color {
    /// Badger colours: "#RRGGBB", "#AARRGGBB", "#RGB", rgb()/rgba(), or a CSS name.
    /// Fully transparent values return nil, so callers use their default.
    init?(badgeHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        guard !hex.isEmpty else { return nil }
        let lower = hex.lowercased()
        if lower.hasPrefix("rgb") {
            let nums = lower.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count >= 3 else { return nil }
            let a = nums.count >= 4 ? nums[3] : 1
            guard a > 0.01 else { return nil }
            self.init(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, opacity: a)
            return
        }
        let named: [String: UInt64] = [
            "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
            "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "pink": 0xFFC0CB, "cyan": 0x00FFFF,
            "magenta": 0xFF00FF, "gold": 0xFFD700, "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080,
            "teal": 0x008080, "lime": 0x00FF00, "crimson": 0xDC143C, "violet": 0xEE82EE,
        ]
        if let v = named[lower] {
            self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
            return
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        case 8:
            let alpha = Double((value >> 24) & 0xFF) / 255
            guard alpha > 0.01 else { return nil }
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255, opacity: alpha)
        default:
            return nil
        }
    }
}
