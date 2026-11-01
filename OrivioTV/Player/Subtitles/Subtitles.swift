import UIKit
import SwiftUI
import KSPlayer

enum SubtitleStyle {
    static let sizes: [Double] = [20, 24, 28, 32, 36, 42, 48, 56]
    static let fonts = ["System", "Helvetica Neue", "Avenir Next", "Gill Sans", "Georgia", "Times New Roman", "Typewriter", "Menlo", "Verdana"]
    static let colors = ["White", "Off-White", "Yellow", "Cyan", "Green", "Grey", "Black"]
    static let outlineWidths: [Double] = [1, 2, 3, 4, 6]

    static func color(_ name: String) -> UIColor {
        switch name {
        case "Off-White": return UIColor(white: 0.9, alpha: 1)
        case "Yellow": return UIColor(red: 1, green: 0.92, blue: 0.2, alpha: 1)
        case "Cyan": return .cyan
        case "Green": return UIColor(red: 0.3, green: 1, blue: 0.4, alpha: 1)
        case "Grey": return UIColor(white: 0.7, alpha: 1)
        case "Black": return .black
        default: return .white
        }
    }

    static func argb(_ c: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [a, r, g, b]
    }

    static func font(_ name: String, size: CGFloat, bold: Bool) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .semibold
        switch name {
        case "System": return .systemFont(ofSize: size, weight: weight)
        case "Typewriter": return UIFont(name: bold ? "AmericanTypewriter-Bold" : "AmericanTypewriter", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        case "Menlo": return UIFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        default:
            let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
            if bold, let d = base.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: size) }
            return base
        }
    }

    /// Strips the cue's own font/colour/background/stroke/shadow (ASS styles
    /// otherwise override every setting) and applies the profile's style. Italic survives.
    static func styled(_ source: NSAttributedString, s: PlayerSettings) -> NSAttributedString {
        let plain = source.string.replacingOccurrences(of: "\\N", with: "\n")
        let out = NSMutableAttributedString(string: plain)
        let font = Self.font(s.subtitleFont, size: CGFloat(s.subtitleSize), bold: s.subtitleBold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(s.subtitleColor), .paragraphStyle: para]
        if s.subtitleOutline {
            attrs[.strokeColor] = color(s.subtitleOutlineColor)
            attrs[.strokeWidth] = -CGFloat(s.subtitleOutlineWidth) * 2.2
        }
        let full = NSRange(location: 0, length: out.length)
        out.addAttributes(attrs, range: full)
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: min(source.length, out.length))) { value, range, _ in
            if let f = value as? UIFont, f.fontDescriptor.symbolicTraits.contains(.traitItalic),
               let d = font.fontDescriptor.withSymbolicTraits([.traitItalic, s.subtitleBold ? .traitBold : []]) {
                out.addAttribute(.font, value: UIFont(descriptor: d, size: font.pointSize), range: range)
            }
        }
        return out
    }
}

/// A selectable subtitle track (None, embedded, add-on).
struct SubtitleChoice: Identifiable, Hashable {
    enum Source: Hashable { case none, embedded(EngineTrack), addon(AddonSubtitle) }
    let id: String
    let title: String
    let detail: String?
    let language: String?
    let source: Source
    var isForced: Bool = false

    static let none = SubtitleChoice(id: "none", title: "None", detail: nil, language: nil, source: .none)
}

/// One of the nine ASS screen positions. Overlapping cues are bucketed per slot
/// so signs no longer land on dialogue.
struct SubtitleSlot: Hashable {
    var v: Int  // 0 top, 1 middle, 2 bottom
    var h: Int  // 0 left, 1 centre, 2 right

    init(_ part: SubtitlePart) {
        let p = part.textPosition
        switch p?.verticalAlign {
        case .top?: v = 0
        case .center?: v = 1
        default: v = 2
        }
        switch p?.horizontalAlign {
        case .leading?: h = 0
        case .trailing?: h = 2
        default: h = 1
        }
    }
}

/// UIKit subtitle renderer: text cues per slot, PGS/VobSub bitmaps scaled from the decoder canvas.
final class SubtitleLayerView: UIView {
    private var labels: [SubtitleSlot: UILabel] = [:]
    private var plates: [SubtitleSlot: UIView] = [:]
    private var imageViews: [UIImageView] = []
    private var lastKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(parts: [SubtitlePart], settings s: PlayerSettings, bottomInset: CGFloat) {
        let key = parts.map { "\($0.start)-\($0.text?.string ?? "img")" }.joined(separator: "|") + "\(s.subtitleSize)\(s.subtitleColor)\(s.subtitleVerticalOffset)\(bottomInset)\(s.subtitleBackground)\(s.subtitleOutline)\(s.subtitleFont)\(s.subtitleBold)\(s.subtitleBackgroundOpacity)\(bounds.size)"
        guard key != lastKey else { return }
        lastKey = key
        labels.values.forEach { $0.removeFromSuperview() }
        plates.values.forEach { $0.removeFromSuperview() }
        imageViews.forEach { $0.removeFromSuperview() }
        labels = [:]; plates = [:]; imageViews = []

        // Bitmap subtitles: composite every rect of the event.
        for part in parts where part.image != nil {
            guard let img = part.image else { continue }
            let canvas = part.canvasSize == .zero ? CGSize(width: 1920, height: 1080) : part.canvasSize
            let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
            let offset = CGPoint(x: (bounds.width - canvas.width * scale) / 2, y: (bounds.height - canvas.height * scale) / 2)
            let iv = UIImageView(image: img)
            iv.frame = CGRect(x: offset.x + part.origin.x * scale,
                              y: offset.y + part.origin.y * scale - CGFloat(s.subtitleVerticalOffset),
                              width: img.size.width * scale, height: img.size.height * scale)
            addSubview(iv)
            imageViews.append(iv)
        }

        var bySlot: [SubtitleSlot: [SubtitlePart]] = [:]
        for part in parts where part.text != nil && part.image == nil { bySlot[SubtitleSlot(part), default: []].append(part) }
        for (slot, list) in bySlot {
            let joined = NSMutableAttributedString()
            for (i, p) in list.enumerated() {
                if i > 0 { joined.append(NSAttributedString(string: "\n")) }
                joined.append(SubtitleStyle.styled(p.text!, s: s))
            }
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = joined
            label.textAlignment = slot.h == 0 ? .left : (slot.h == 2 ? .right : .center)
            let maxWidth = bounds.width * 0.8
            let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let x: CGFloat
            switch slot.h {
            case 0: x = bounds.width * 0.08
            case 2: x = bounds.width * 0.92 - size.width
            default: x = (bounds.width - size.width) / 2
            }
            let y: CGFloat
            switch slot.v {
            case 0: y = 60 + CGFloat(max(0, -s.subtitleVerticalOffset))
            case 1: y = (bounds.height - size.height) / 2
            default: y = bounds.height - bottomInset - CGFloat(s.subtitleVerticalOffset) - size.height
            }
            label.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            if s.subtitleBackground {
                let plate = UIView(frame: label.frame.insetBy(dx: -14, dy: -6))
                plate.backgroundColor = UIColor.black.withAlphaComponent(CGFloat(s.subtitleBackgroundOpacity))
                plate.layer.cornerRadius = 8
                addSubview(plate)
                plates[slot] = plate
            }
            addSubview(label)
            labels[slot] = label
        }
    }

    func clear() {
        render(parts: [], settings: PlayerSettings(), bottomInset: 0)
    }
}

struct SubtitleLayer: UIViewRepresentable {
    let parts: [SubtitlePart]
    let settings: PlayerSettings
    var bottomInset: CGFloat = 84

    func makeUIView(context: Context) -> SubtitleLayerView { SubtitleLayerView() }

    func updateUIView(_ v: SubtitleLayerView, context: Context) {
        v.render(parts: parts, settings: settings, bottomInset: bottomInset)
    }
}

/// Owns subtitle tracks: embedded + add-on, the default pick, delay and the current cues.
@MainActor
final class SubtitleController: ObservableObject {
    @Published private(set) var choices: [SubtitleChoice] = [.none]
    @Published private(set) var selected: SubtitleChoice = .none
    @Published private(set) var parts: [SubtitlePart] = []
    @Published var delay: Double = 0
    @Published private(set) var addonSubtitles: [AddonSubtitle] = []
    @Published private(set) var addonsLoaded = false

    private var urlInfos: [String: URLSubtitleInfo] = [:]
    private var didAutoPick = false
    weak var engine: PlaybackEngine?

    func reset() {
        choices = [.none]
        selected = .none
        parts = []
        didAutoPick = false
        urlInfos = [:]
    }

    func loadAddonSubtitles(meta: MetaItem, video: MetaVideo?, filename: String?) async {
        addonsLoaded = false
        let subs = await SubtitleFetcher.fetchAll(meta: meta, video: video, filename: filename)
        addonSubtitles = subs
        addonsLoaded = true
        rebuild()
    }

    func rebuild() {
        var list: [SubtitleChoice] = [.none]
        if let e = engine {
            for t in e.subtitleTracks {
                list.append(SubtitleChoice(id: "e:\(t.id)", title: t.displayName, detail: t.isImage ? "Embedded · image" : "Embedded",
                                           language: t.language, source: .embedded(t), isForced: t.isForced))
            }
        }
        var seen = Set<String>()
        for s in addonSubtitles where seen.insert(s.url).inserted {
            let langName = Languages.normalize(s.lang).map(Languages.name) ?? s.lang
            list.append(SubtitleChoice(id: "a:\(s.url)", title: langName, detail: s.addonName, language: s.lang, source: .addon(s)))
        }
        choices = list
    }

    /// Default pick: "on by default" → preferred language, then secondary;
    /// forced tracks if enabled; with "Prefer add-on subtitles" the pick waits for add-ons.
    func autoPickIfNeeded(settings s: PlayerSettings) {
        guard !didAutoPick else { return }
        if s.preferAddonSubtitles && !addonsLoaded { return }
        rebuild()
        didAutoPick = true
        let embedded = choices.filter { if case .embedded = $0.source { return true }; return false }
        let addon = choices.filter { if case .addon = $0.source { return true }; return false }
        // Forced tracks in the audio language even when subtitles are off.
        if s.preferForcedSubtitles, let forced = embedded.first(where: { $0.isForced && Languages.matches($0.language, s.preferredAudioLanguage) }), !s.subtitlesOnByDefault {
            select(forced, settings: s)
            return
        }
        guard s.subtitlesOnByDefault else { return }
        for lang in [s.subtitleLanguage] + (s.subtitleSecondaryLanguage.map { [$0] } ?? []) {
            let e = embedded.filter { Languages.matches($0.language, lang) }
            let a = addon.filter { Languages.matches($0.language, lang) }
            let eBest = s.preferForcedSubtitles ? (e.first { !$0.isForced } ?? e.first) : (e.first { !$0.isForced } ?? e.first)
            let pick = s.preferAddonSubtitles ? (a.first ?? eBest) : (eBest ?? a.first)
            if let pick { select(pick, settings: s); return }
        }
    }

    func select(_ choice: SubtitleChoice, settings: PlayerSettings) {
        selected = choice
        parts = []
        switch choice.source {
        case .none:
            engine?.select(subtitle: nil)
            urlInfos.values.forEach { $0.isEnabled = false }
        case .embedded(let t):
            urlInfos.values.forEach { $0.isEnabled = false }
            engine?.select(subtitle: t)
        case .addon(let s):
            engine?.select(subtitle: nil)
            guard let url = URL(string: s.url) else { return }
            if let vlc = engine as? VLCEngine, settings.fullStyledSubtitles {
                vlc.addSubtitle(url: url, id: s.url, select: true)
                return
            }
            urlInfos.values.forEach { $0.isEnabled = false }
            let info = urlInfos[s.url] ?? URLSubtitleInfo(subtitleID: s.url, name: s.lang, url: url, userAgent: HTTP.userAgent)
            urlInfos[s.url] = info
            info.isEnabled = true
        }
    }

    /// Called on the player tick. Selecting None stops querying (and clears the cue).
    func tick(time: Double) {
        let t = time - delay
        var newParts: [SubtitlePart]
        switch selected.source {
        case .none:
            if !parts.isEmpty { parts = [] }
            return
        case .embedded:
            newParts = engine?.subtitleParts(at: t) ?? []
        case .addon(let s):
            newParts = urlInfos[s.url]?.search(for: t) ?? []
        }
        if newParts.map(\.start) != parts.map(\.start) || newParts.count != parts.count { parts = newParts }
    }

    /// Re-fetch add-on tracks and restore the selection (replacing failed downloads).
    func reload(meta: MetaItem, video: MetaVideo?, settings: PlayerSettings) async {
        let keep = selected
        urlInfos = [:]
        AddonClient.subtitleCache.removeAll()
        await loadAddonSubtitles(meta: meta, video: video, filename: nil)
        if let again = choices.first(where: { $0.id == keep.id }) { select(again, settings: settings) }
    }
}
