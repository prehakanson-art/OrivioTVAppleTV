import SwiftUI

// Hulu theme — shared UI foundation ported from HuluTV. The UI is brought in
// verbatim (sizes/fonts/insets/focus language); the DATA is Orivio's. `HuluTitle`
// is the thin model the ported components expect, mapped off `MetaItem` /
// `WatchProgress`. Genres are matched by NAME (Orivio stores names, not ids).

// MARK: - Model

struct HuluTitle: Identifiable, Hashable {
    let id: String
    let name: String
    let overview: String
    let posterURL: String?
    let backdropURL: String?
    let cardURL: String?
    let logoURL: String?
    let isSeries: Bool
    let year: String
    let genres: [String]
    var maturity: String = "TV-14"
    var progress: Double? = nil
    var episodeLine: String = ""
    var tagline: String = ""
    var remainingText: String? = nil
    var hasNewEpisode: Bool = false
    var isPlaceholder: Bool = false
    var meta: MetaItem? = nil

    var genreName: String { genres.first ?? (isSeries ? "Series" : "Film") }
    /// "TV-14 • Comedy • 2026" metadata line.
    var metaLine: String {
        [maturity, genreName, year].filter { !$0.isEmpty }.joined(separator: "  •  ")
    }

    static let placeholder = HuluTitle(
        id: "placeholder", name: "", overview: "", posterURL: nil, backdropURL: nil,
        cardURL: nil, logoURL: nil, isSeries: true, year: "", genres: [], isPlaceholder: true
    )

    init(id: String, name: String, overview: String, posterURL: String?, backdropURL: String?,
         cardURL: String?, logoURL: String?, isSeries: Bool, year: String, genres: [String],
         maturity: String = "TV-14", progress: Double? = nil, episodeLine: String = "",
         tagline: String = "", remainingText: String? = nil, hasNewEpisode: Bool = false,
         isPlaceholder: Bool = false, meta: MetaItem? = nil) {
        self.id = id; self.name = name; self.overview = overview
        self.posterURL = posterURL; self.backdropURL = backdropURL
        self.cardURL = cardURL; self.logoURL = logoURL
        self.isSeries = isSeries; self.year = year; self.genres = genres
        self.maturity = maturity; self.progress = progress; self.episodeLine = episodeLine
        self.tagline = tagline; self.remainingText = remainingText; self.hasNewEpisode = hasNewEpisode
        self.isPlaceholder = isPlaceholder; self.meta = meta
    }

    init(_ m: MetaItem) {
        let series = m.isSeries
        let rating = Double(m.imdbRating ?? "") ?? 0
        let mat = series ? (rating >= 8 ? "TV-MA" : rating >= 6.5 ? "TV-14" : "TV-PG")
                         : (rating >= 7.5 ? "R" : rating >= 6 ? "PG-13" : "PG")
        self.init(
            id: m.id, name: m.name, overview: m.description ?? "",
            posterURL: m.poster, backdropURL: m.background,
            cardURL: m.background ?? m.poster, logoURL: m.logo,
            isSeries: series, year: m.year ?? "", genres: m.genres ?? [],
            maturity: mat, episodeLine: series ? "New Episodes Streaming" : "",
            tagline: "", meta: m
        )
    }

    init(_ p: WatchProgress) {
        let series = p.season != nil
        var epLine = ""
        if let s = p.season, let e = p.episode {
            epLine = "S\(s) E\(e)" + (p.episodeTitle.map { " · \($0)" } ?? "")
        } else { epLine = p.name }
        self.init(
            id: p.metaID, name: p.name, overview: "",
            posterURL: p.poster, backdropURL: p.background,
            cardURL: p.episodeThumbnail ?? p.background ?? p.poster, logoURL: p.logo,
            isSeries: series, year: "", genres: [],
            progress: p.fraction, episodeLine: epLine,
            remainingText: p.remainingTimeText,
            hasNewEpisode: p.hasNewEpisode == true,
            meta: nil
        )
    }
}

// MARK: - Focus helpers (ported from HuluTV FocusHelpers.swift)

/// A flat button style — no tvOS focus plate. Focus is drawn by each view via
/// the accent focus ring / lift; the only chrome this adds is the shared
/// Select-press dip, so a press registers here the same as in every other theme
/// (with the platter off, these cards previously gave no press feedback).
struct HuluFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.cardPressDip(configuration.isPressed)
    }
}
extension ButtonStyle where Self == HuluFlatButtonStyle {
    static var huluFlat: HuluFlatButtonStyle { HuluFlatButtonStyle() }
}

extension View {
    /// "Raise & move" toggle for Hulu's plain (scale-based) poster cards. When the
    /// `cardParallax` setting is on, use tvOS's native card platter (lift + 3D
    /// trackpad tilt); when off, Hulu's flat style so the accent focus ring / scale
    /// is the sole focus visual.
    @ViewBuilder
    func huluCardStyle(_ parallax: Bool) -> some View {
        if parallax { buttonStyle(.card) } else { buttonStyle(.huluFlat) }
    }
}

private struct HuluExternalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

/// The accent focus ring used on rows, settings, tiles — reads the CURRENT Color
/// Theme accent so the focus colour follows the picker.
private struct HuluFocusRing: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let focused: Bool
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(theme.palette.secondary, lineWidth: focused ? lineWidth : 0))
    }
}

extension View {
    func huluExternalFocus(_ binding: FocusState<Bool>.Binding?) -> some View {
        modifier(HuluExternalFocus(binding: binding))
    }
    func huluPullFocusOnAppear(_ binding: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { binding.wrappedValue = true } }
    }
    func huluFocusRing(_ focused: Bool, cornerRadius: CGFloat = 10, lineWidth: CGFloat = 4) -> some View {
        modifier(HuluFocusRing(focused: focused, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

// MARK: - Wordmark (Orivio, in the accent colour — replaces the "hulu" wordmark)

struct HuluWordmark: View {
    @EnvironmentObject private var theme: ThemeManager
    var size: CGFloat = 40
    var body: some View {
        Text("orivio")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(theme.palette.secondary)
            .fixedSize()
    }
}
