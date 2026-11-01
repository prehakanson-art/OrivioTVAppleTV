import SwiftUI

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    static func hex(_ s: String) -> Color { Color(hex: s) ?? .gray }
}

/// §16.1 colour tokens, resolved for the current Ambience/Accent.
struct Theme: Equatable {
    var ambience: Ambience
    var accentChoice: AccentChoice
    var artworkTint: Bool

    init(_ s: AppearanceSettings = AppearanceSettings()) {
        ambience = s.ambience
        accentChoice = s.accent
        artworkTint = s.artworkTint
    }

    var ambientTop: Color { .hex(ambience.hexes.0) }
    var ambientBottom: Color { .hex(ambience.hexes.1) }
    var ambientGradient: LinearGradient {
        LinearGradient(colors: [ambientTop, ambientBottom], startPoint: .top, endPoint: .bottom)
    }

    var accent: Color { .hex(accentChoice.hex) }
    /// Ink for text/icons drawn on an accent fill.
    var accentInk: Color { accentChoice.needsDarkInk ? Palette.focusInk : .white }
    var isSystemWhite: Bool { accentChoice == .systemWhite }
    /// Progress bars: white under System White, else the accent.
    var progress: Color { isSystemWhite ? .white : accent }
    /// Focused primary button fill (Play): the accent when chosen, else white.
    var primaryFocusFill: Color { isSystemWhite ? Palette.focusFill : accent }
    var primaryFocusInk: Color { isSystemWhite ? Palette.focusInk : accentInk }
}

enum Palette {
    static let focusFill = Color.white
    static let focusInk = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.5)
    static let hairline = Color.white.opacity(0.14)
    static let glassSolid = Color.white.opacity(0.10)
    static let glassRaised = Color.white.opacity(0.18)
    /// The nav chrome's dark base (sidebar, rail, top bar), under or instead of the blur.
    static let navBase = Color(red: 0.07, green: 0.08, blue: 0.11)
    static let live = Color.hex("#FF3B30")
    static let positive = Color.hex("#30D158")
    static let destructive = Color.hex("#FF6961")
    static let imdb = Color.hex("#F5C518")
    static let panelDark = Color.hex("#1B1B1D")
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Type (§16.2) — SF Pro everywhere

enum TypeStyle {
    case heroLogoFallback, pageTitle, sectionHeader, seasonTab, body, meta, cardTitle, cardBody, eyebrow, button, badge, caption

    var font: Font {
        switch self {
        case .heroLogoFallback: return .system(size: 76, weight: .heavy)
        case .pageTitle: return .system(size: 48, weight: .bold)
        case .sectionHeader: return .system(size: 29, weight: .semibold)
        case .seasonTab: return .system(size: 34, weight: .semibold)
        case .body: return .system(size: 25, weight: .regular)
        case .meta: return .system(size: 24, weight: .medium)
        case .cardTitle: return .system(size: 23, weight: .semibold)
        case .cardBody: return .system(size: 21, weight: .regular)
        case .eyebrow: return .system(size: 17, weight: .semibold)
        case .button: return .system(size: 26, weight: .semibold)
        case .badge: return .system(size: 18, weight: .semibold)
        case .caption: return .system(size: 19, weight: .medium)
        }
    }
}

extension View {
    func textStyle(_ style: TypeStyle, color: Color? = nil) -> some View {
        let c: Color
        switch style {
        case .sectionHeader, .meta, .cardBody, .caption: c = color ?? Palette.textSecondary
        case .eyebrow: c = color ?? Palette.textTertiary
        default: c = color ?? Palette.textPrimary
        }
        return self.font(style.font)
            .foregroundStyle(c)
            .tracking(style == .eyebrow ? 0.6 : (style == .heroLogoFallback ? -1.5 : 0))
            .lineSpacing(style == .body ? 6 : 0)
    }
}

extension Text {
    func eyebrow() -> some View {
        self.textCase(.uppercase).textStyle(.eyebrow)
    }
}

// MARK: - Shape & spacing (§16.3)

enum Metrics {
    static let margin: CGFloat = 80
    static let headerToCards: CGFloat = 20
    static let rowGap: CGFloat = 56
    static let posterRadius: CGFloat = 22
    static let stillRadius: CGFloat = 18
    static let glassCardRadius: CGFloat = 28
    static let popoverRadius: CGFloat = 40
    static let sidebarRadius: CGFloat = 44
    static let pageCardRadius: CGFloat = 48
    static let screen = CGSize(width: 1920, height: 1080)
}

// MARK: - Motion (§16.3)

enum Motion {
    /// Constrained boxes get the same motion language with shorter tails:
    /// a 0.72 s page fade reads as "slow" even when every frame is smooth.
    static var focus: Animation { .spring(response: PerformanceProfile.isConstrained ? 0.2 : 0.32, dampingFraction: 0.82) }
    static var pageScroll: Animation { .spring(response: PerformanceProfile.isConstrained ? 0.42 : 0.7, dampingFraction: 0.92) }
    static var heroPage: Animation { .easeInOut(duration: 1.8) }
    static var heroText: Animation { .easeInOut(duration: 0.6).delay(0.3) }
    static var pageOpen: Animation { PerformanceProfile.isConstrained ? .easeOut(duration: 0.3) : .spring(response: 0.72, dampingFraction: 0.88) }
    /// Back: the page card shrinks into its card (critically damped — no undershoot past the card).
    static var pageClose: Animation { PerformanceProfile.isConstrained ? .easeOut(duration: 0.32) : .spring(response: 0.5, dampingFraction: 1) }
    /// Detail page: hero ⇄ sections, one continuous scroll.
    static var detailScroll: Animation { PerformanceProfile.isConstrained ? .easeInOut(duration: 0.36) : .spring(response: 0.62, dampingFraction: 0.9) }
    static var pageSlide: Animation { PerformanceProfile.isConstrained ? .easeOut(duration: 0.34) : .spring(response: 0.55, dampingFraction: 0.9) }
    static var sidebar: Animation { .spring(response: 0.35, dampingFraction: 0.85) }
    static var popover: Animation { .spring(response: 0.3, dampingFraction: 0.85) }
    static var artField: Animation { .easeInOut(duration: 0.8) }
    static var imageFade: Animation { .easeOut(duration: PerformanceProfile.isConstrained ? 0.12 : 0.25) }

    /// Chrome over live video: decelerating 0.18 s in, softer 0.26 s out —
    /// and snapped on A8/A10X (fading over live video drops frames there).
    static var chromeIn: Animation? { PerformanceProfile.animatesOverVideo ? .easeOut(duration: 0.18) : nil }
    static var chromeOut: Animation? { PerformanceProfile.animatesOverVideo ? .easeInOut(duration: 0.26) : nil }

    /// `nil` under Reduce Motion.
    static func unlessReduced(_ a: Animation) -> Animation? { PerformanceProfile.reduceMotion ? nil : a }
}

// MARK: - Page canvas (side rail clearance)

private struct PageWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1920 }
private struct RailBleedKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// The page canvas width: 1920, or 1800 beside the side rail.
    var pageWidth: CGFloat {
        get { self[PageWidthKey.self] }
        set { self[PageWidthKey.self] = newValue }
    }

    /// How far full-bleed art should reach left, under the side rail.
    var railBleed: CGFloat {
        get { self[RailBleedKey.self] }
        set { self[RailBleedKey.self] = newValue }
    }
}

private struct RailBleed: ViewModifier {
    @Environment(\.railBleed) private var bleed
    func body(content: Content) -> some View { content.padding(.leading, -bleed) }
}

private struct PageFrame: ViewModifier {
    let alignment: Alignment
    @Environment(\.pageWidth) private var width
    func body(content: Content) -> some View { content.frame(width: width, height: 1080, alignment: alignment) }
}

extension View {
    /// Extends a full-bleed background under the side rail (no-op otherwise).
    func railBleed() -> some View { modifier(RailBleed()) }

    /// The full page canvas (1920×1080, or 1800 wide beside the side rail).
    func pageFrame(alignment: Alignment = .topLeading) -> some View { modifier(PageFrame(alignment: alignment)) }
}

/// The tab clip: the page bounds, extended left so bled art shows under the rail.
struct LeadingBleedRect: Shape {
    var bleed: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - bleed, y: rect.minY, width: rect.width + bleed, height: rect.height))
    }
}
