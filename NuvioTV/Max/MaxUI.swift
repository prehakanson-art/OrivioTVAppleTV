import SwiftUI

// Max theme — shared UI foundation ported from MaxTV. The MaxTV UI is brought in
// VERBATIM (sizes, fonts, insets, focus treatments); only the DATA is Orivio's.
// `MaxTitle` is the thin card/hero model MaxTV's components expect, mapped off
// Orivio's `MetaItem`/`WatchProgress`. Genres are matched by NAME (Orivio stores
// genre names, not TMDB ids), which drives the hub chips + Categories.

// MARK: - Model

/// The corner badge a card can carry (ported from MaxTV `TitleBadge`).
enum MaxTitleBadge {
    case none, newEpisode, newlyAdded
    var text: String? {
        switch self {
        case .none: return nil
        case .newEpisode: return "New Episode"
        case .newlyAdded: return "Newly Added"
        }
    }
}

/// A thin card/hero model matching MaxTV's `Title`, populated from a `MetaItem`
/// (or a `WatchProgress`). Carries the original `meta` so selection routes back
/// into Orivio's real navigation.
struct MaxTitle: Identifiable, Hashable {
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
    var brand: String = "ORIVIO"
    var maturity: String = "TV-MA"
    var seasonsText: String = ""
    var runtimeText: String = ""
    var badge: MaxTitleBadge = .none
    var progress: Double? = nil
    var episodeLine: String? = nil
    var isPlaceholder: Bool = false
    var meta: MetaItem? = nil

    static let placeholder = MaxTitle(
        id: "placeholder", name: "", overview: "", posterURL: nil, backdropURL: nil,
        cardURL: nil, logoURL: nil, isSeries: true, year: "", genres: [], isPlaceholder: true
    )

    init(id: String, name: String, overview: String, posterURL: String?, backdropURL: String?,
         cardURL: String?, logoURL: String?, isSeries: Bool, year: String, genres: [String],
         brand: String = "ORIVIO", maturity: String = "TV-MA", seasonsText: String = "",
         runtimeText: String = "", badge: MaxTitleBadge = .none, progress: Double? = nil,
         episodeLine: String? = nil, isPlaceholder: Bool = false, meta: MetaItem? = nil) {
        self.id = id; self.name = name; self.overview = overview
        self.posterURL = posterURL; self.backdropURL = backdropURL
        self.cardURL = cardURL; self.logoURL = logoURL
        self.isSeries = isSeries; self.year = year; self.genres = genres; self.brand = brand
        self.maturity = maturity; self.seasonsText = seasonsText; self.runtimeText = runtimeText
        self.badge = badge; self.progress = progress; self.episodeLine = episodeLine
        self.isPlaceholder = isPlaceholder; self.meta = meta
    }

    init(_ m: MetaItem) {
        let series = m.isSeries
        let rating = Double(m.imdbRating ?? "") ?? 0
        let seasons = m.seasons.count
        self.init(
            id: m.id, name: m.name, overview: m.description ?? "",
            posterURL: m.poster, backdropURL: m.background,
            cardURL: m.background ?? m.poster, logoURL: m.logo,
            isSeries: series, year: m.year ?? "", genres: m.genres ?? [],
            brand: series ? "ORIVIO" : "ORIVIO ORIGINAL",
            maturity: rating >= 8 ? "TV-MA" : rating >= 6.5 ? "TV-14" : "TV-PG",
            seasonsText: series ? "\(max(1, seasons)) Season\(max(1, seasons) == 1 ? "" : "s")" : "",
            runtimeText: m.runtimeFormatted ?? "",
            badge: .none, meta: m
        )
    }

    init(_ p: WatchProgress) {
        let series = p.season != nil
        var epLine: String? = nil
        if let s = p.season, let e = p.episode { epLine = "S\(s) E\(e)" }
        self.init(
            id: p.metaID, name: p.name, overview: "",
            posterURL: p.poster, backdropURL: p.background,
            cardURL: p.episodeThumbnail ?? p.background ?? p.poster, logoURL: p.logo,
            isSeries: series, year: "", genres: [],
            brand: series ? "ORIVIO" : "ORIVIO ORIGINAL",
            progress: p.fraction, episodeLine: epLine, meta: nil
        )
    }
}

// MARK: - Focus helpers (ported from MaxTV FocusHelpers.swift)

/// A flat button style — none of tvOS's default focus platter. Focus appearance
/// is driven entirely by each view's own `@FocusState`, matching Max's flat
/// white highlights; the only chrome this adds is the shared Select-press dip,
/// so a press registers here the same as in every other theme (with the platter
/// off, these cards previously gave no press feedback at all).
struct MaxFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.cardPressDip(configuration.isPressed)
    }
}
extension ButtonStyle where Self == MaxFlatButtonStyle {
    static var maxFlat: MaxFlatButtonStyle { MaxFlatButtonStyle() }
}

extension View {
    /// "Raise & move" toggle for Max's plain (scale-based) poster cards. When the
    /// `cardParallax` setting is on, use tvOS's native card platter (lift + 3D
    /// trackpad tilt); when off, Max's flat style so the card's own white border /
    /// scale is the sole focus visual.
    @ViewBuilder
    func maxCardStyle(_ parallax: Bool) -> some View {
        if parallax { buttonStyle(.card) } else { buttonStyle(.maxFlat) }
    }
}

/// Applies an external `.focused(_:)` binding only when one is supplied.
private struct MaxExternalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

extension View {
    func maxExternalFocus(_ binding: FocusState<Bool>.Binding?) -> some View {
        modifier(MaxExternalFocus(binding: binding))
    }
    /// Pulls focus to `binding` shortly after appear so a browse page opens
    /// focused on its content (matching MaxTV's `pullFocusOnAppear`).
    func maxPullFocusOnAppear(_ binding: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { binding.wrappedValue = true } }
    }
}

// MARK: - Brand lockup (Orivio)

/// The Orivio brand lockup used top-right on browse pages — the app's own logo
/// asset plus the "ORIVIO" wordmark, replacing MaxTV's HBO max lockup.
struct MaxBrandLogo: View {
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 12 * scale) {
            Image("OrivioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40 * scale, height: 40 * scale)
            Text("ORIVIO")
                .font(.system(size: 28 * scale, weight: .heavy))
                .tracking(1.5 * scale)
                .foregroundStyle(.white)
        }
        .fixedSize()
    }
}
