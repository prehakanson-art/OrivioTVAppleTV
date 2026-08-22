import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Primitive color tokens ported from NuvioTV's Android design system.
enum NuvioPrimitives {
    static let black = Color(hex: 0x000000)
    static let white = Color(hex: 0xFFFFFF)
    static let neutral950 = Color(hex: 0x0D0D0D)
    static let neutral925 = Color(hex: 0x111111)
    static let neutral900 = Color(hex: 0x1A1A1A)
    static let neutral875 = Color(hex: 0x1E1E1E)
    static let neutral850 = Color(hex: 0x222222)
    static let neutral825 = Color(hex: 0x242424)
    static let neutral800 = Color(hex: 0x2D2D2D)
    static let neutral750 = Color(hex: 0x333333)
    static let neutral700 = Color(hex: 0x4D4D4D)
    static let neutral650 = Color(hex: 0x6F6F6F)
    static let neutral600 = Color(hex: 0x808080)
    static let neutral500 = Color(hex: 0x9E9E9E)
    static let neutral400 = Color(hex: 0xB3B3B3)
    static let neutral200 = Color(hex: 0xE0E0E0)
    static let neutral100 = Color(hex: 0xF5F5F5)
    static let red500 = Color(hex: 0xE53935)
    static let red600 = Color(hex: 0xC62828)
    static let red300 = Color(hex: 0xFF5252)
    static let blue500 = Color(hex: 0x1E88E5)
    static let blue700 = Color(hex: 0x1565C0)
    static let blue300 = Color(hex: 0x42A5F5)
    static let violet500 = Color(hex: 0x8E24AA)
    static let violet700 = Color(hex: 0x6A1B9A)
    static let violet300 = Color(hex: 0xAB47BC)
    static let green500 = Color(hex: 0x43A047)
    static let green700 = Color(hex: 0x2E7D32)
    static let green300 = Color(hex: 0x66BB6A)
    static let amber500 = Color(hex: 0xFB8C00)
    static let amber700 = Color(hex: 0xEF6C00)
    static let amber300 = Color(hex: 0xFFA726)
    static let rose500 = Color(hex: 0xD81B60)
    static let rose700 = Color(hex: 0xC2185B)
    static let rose300 = Color(hex: 0xEC407A)
    static let rating = Color(hex: 0xFFD700)
    static let torrent = Color(hex: 0x7E57C2)
    static let imdb = Color(hex: 0xF5C518)
    static let success = Color(hex: 0x4CAF50)
    static let warning = Color(hex: 0xFFB74D)
    static let error = Color(hex: 0xCF6679)
}

struct ThemePalette: Identifiable, Equatable {
    let id: String
    let displayName: String
    var secondary: Color
    var secondaryVariant: Color
    var onSecondary: Color = NuvioPrimitives.white
    var focusRing: Color
    var focusBackground: Color
    var background: Color = NuvioPrimitives.neutral950
    var backgroundElevated: Color = NuvioPrimitives.neutral900
    var backgroundCard: Color = NuvioPrimitives.neutral825
    var surface: Color = NuvioPrimitives.neutral875
    var surfaceVariant: Color = NuvioPrimitives.neutral800
    var panel: Color = NuvioPrimitives.neutral900
    var overlay: Color = Color.black.opacity(0.85)
    var field: Color = NuvioPrimitives.neutral850
    var playerOverlay: Color = Color.black.opacity(0.8)

    // Stored (not computed) so the Apple TV theme's light palette can swap
    // them for dark-on-light text; every palette in NuvioThemes keeps these
    // defaults.
    var textPrimary: Color = NuvioPrimitives.white
    var textSecondary: Color = NuvioPrimitives.neutral400
    var textTertiary: Color = NuvioPrimitives.neutral500
    /// Ambient accent glow color used by the Fusion theme's focus glow (§13.3).
    /// Clear by default so Classic components draw no glow.
    var focusGlow: Color = .clear
}

enum NuvioThemes {
    static let crimson = ThemePalette(
        id: "crimson", displayName: "Crimson",
        secondary: NuvioPrimitives.red500,
        secondaryVariant: NuvioPrimitives.red600,
        focusRing: NuvioPrimitives.red300,
        focusBackground: Color(hex: 0x3D1A1A),
        backgroundCard: Color(hex: 0x241A1A)
    )
    static let ocean = ThemePalette(
        id: "ocean", displayName: "Ocean",
        secondary: NuvioPrimitives.blue500,
        secondaryVariant: NuvioPrimitives.blue700,
        focusRing: NuvioPrimitives.blue300,
        focusBackground: Color(hex: 0x1A2D3D),
        background: Color(hex: 0x0D0D0F),
        backgroundElevated: Color(hex: 0x1A1A1E),
        backgroundCard: Color(hex: 0x1A1F24)
    )
    static let violet = ThemePalette(
        id: "violet", displayName: "Violet",
        secondary: NuvioPrimitives.violet500,
        secondaryVariant: NuvioPrimitives.violet700,
        focusRing: NuvioPrimitives.violet300,
        focusBackground: Color(hex: 0x2D1A3D),
        background: Color(hex: 0x0D0D0F),
        backgroundElevated: Color(hex: 0x1A1A1E),
        backgroundCard: Color(hex: 0x1F1A24)
    )
    static let emerald = ThemePalette(
        id: "emerald", displayName: "Emerald",
        secondary: NuvioPrimitives.green500,
        secondaryVariant: NuvioPrimitives.green700,
        focusRing: NuvioPrimitives.green300,
        focusBackground: Color(hex: 0x1A3D1E),
        backgroundCard: Color(hex: 0x1A241A)
    )
    static let amber = ThemePalette(
        id: "amber", displayName: "Amber",
        secondary: NuvioPrimitives.amber500,
        secondaryVariant: NuvioPrimitives.amber700,
        focusRing: NuvioPrimitives.amber300,
        focusBackground: Color(hex: 0x3D2D1A),
        background: Color(hex: 0x0F0D0D),
        backgroundElevated: Color(hex: 0x1E1A1A),
        backgroundCard: Color(hex: 0x24201A)
    )
    static let rose = ThemePalette(
        id: "rose", displayName: "Rose",
        secondary: NuvioPrimitives.rose500,
        secondaryVariant: NuvioPrimitives.rose700,
        focusRing: NuvioPrimitives.rose300,
        focusBackground: Color(hex: 0x3D1A2D),
        backgroundCard: Color(hex: 0x241A1F)
    )
    static let white = ThemePalette(
        id: "white", displayName: "White",
        secondary: NuvioPrimitives.neutral100,
        secondaryVariant: NuvioPrimitives.neutral200,
        onSecondary: NuvioPrimitives.neutral925,
        focusRing: NuvioPrimitives.white,
        focusBackground: Color(hex: 0x303030),
        backgroundCard: NuvioPrimitives.neutral850
    )

    /// Orivio Purple — a deep, electric purple accent (deeper than the softer
    /// "Violet"), available to every theme like any accent.
    static let orivioPurple = ThemePalette(
        id: "purple", displayName: "Orivio Purple",
        secondary: Color(hex: 0x6D27E8),
        secondaryVariant: Color(hex: 0x3C137F),
        focusRing: Color(hex: 0x925DFF),
        focusBackground: Color(hex: 0x2A1A3D),
        background: Color(hex: 0x0D0C10),
        backgroundElevated: Color(hex: 0x1A1920),
        backgroundCard: Color(hex: 0x201A28)
    )

    /// Lavender — a soft light-purple accent; needs dark text on its fill
    /// like White.
    static let lavender = ThemePalette(
        id: "lavender", displayName: "Lavender",
        secondary: Color(hex: 0xB99AFF),
        secondaryVariant: Color(hex: 0x6D5AA8),
        onSecondary: Color(hex: 0x15121E),
        focusRing: Color(hex: 0xD4C1FF),
        focusBackground: Color(hex: 0x2E2740),
        backgroundCard: Color(hex: 0x201C2A)
    )

    /// Mint — the bright Hulu-style neon green accent; needs dark text on its
    /// fill (like White/Lavender). Pairs especially well with the Streamline theme.
    static let mint = ThemePalette(
        id: "mint", displayName: "Mint",
        secondary: Color(hex: 0x1CE783),
        secondaryVariant: Color(hex: 0x0FB968),
        onSecondary: Color(hex: 0x04241A),
        focusRing: Color(hex: 0x1CE783),
        focusBackground: Color(hex: 0x0F2A20)
    )

    // Picker order matches the APK's Color Theme row: White first.
    static let all: [ThemePalette] = [white, crimson, ocean, violet, orivioPurple, lavender, emerald, mint, amber, rose]

    static func palette(id: String) -> ThemePalette {
        all.first { $0.id == id } ?? crimson
    }
}

/// A full app THEME — the overall look/feel preset, distinct from the accent
/// "Color Theme" in Appearance. Register new themes in `all`; the selected id
/// lives on `ThemeManager.appThemeID` and syncs with the account. Rendering
/// code that a theme restyles branches on `theme.appThemeID`.
struct AppTheme: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    /// SF Symbol shown next to the theme in the picker.
    var icon: String = "paintbrush.fill"
}

enum AppThemes {
    static let classic = AppTheme(
        id: "classic",
        displayName: "Classic",
        summary: "The original Orivio look."
    )

    /// "Modern" — the premium modular media-center look: deep graphite
    /// backgrounds, artwork-driven environments, cinematic hero, reflective
    /// focus, light/dark/AMOLED. Internal id stays "appletv" so existing
    /// synced theme selections keep resolving to it.
    static let appleTV = AppTheme(
        id: "appletv",
        displayName: "Modern",
        summary: "A cinematic, customizable media center — deep graphite, artwork-driven, light & dark.",
        icon: "square.stack.3d.up.fill"
    )

    /// "Theater" — a dark cinema look: pure-black stage, artwork emerging from
    /// darkness, red accent states, dense fast rows, white Play button. Shares
    /// the Modern top-nav chrome (see `ThemeManager.isAppleTVTheme`) and
    /// restyles on top of it. Internal id stays "netflix" for synced selections.
    static let netflix = AppTheme(
        id: "netflix",
        displayName: "Theater",
        summary: "A dark theater: black stage, cinematic billboard, dense rows, red accent states.",
        icon: "play.rectangle.fill"
    )

    /// "Aurora" — a dark navy-purple stage with a signature purple accent,
    /// rounded cards, and a collapsible left icon rail. Internal id stays
    /// "stremio" so existing synced theme selections keep resolving to it.
    static let stremio = AppTheme(
        id: "stremio",
        displayName: "Aurora",
        summary: "A navy-purple stage with a purple accent, rounded cards, and a left icon rail.",
        icon: "puzzlepiece.extension.fill"
    )

    /// "Cinema" — a from-scratch cinematic media center (deep graphite stage,
    /// big artwork hero, artwork-driven rows). Built entirely on its OWN screens
    /// and components — reuses NOTHING from the retired Modern/Nova themes — so
    /// every focus highlight and hold menu works. Routes to `cinemaLayout` +
    /// `CinemaHomeView` and gates its look on `isCinemaTheme`.
    static let cinema = AppTheme(
        id: "cinema",
        displayName: "Cinema",
        summary: "A cinematic media center — deep graphite stage, big hero, artwork-driven rows.",
        icon: "film.stack.fill"
    )

    /// "Onyx" — modelled on the bobsupra/NuvioTVOS tvOS client: a near-black
    /// stage where focus is a crisp WHITE edge (no coloured ring, no glow, no
    /// lift). Rides the shared Classic layout, restyled purely via
    /// `OnyxPalette.adapt` (like Aurora) — its identity is the palette + focus
    /// edge, so no custom layout is needed.
    static let onyx = AppTheme(
        id: "onyx",
        displayName: "Onyx",
        summary: "A near-black stage with a crisp white focus edge — clean, flat, minimal.",
        icon: "viewfinder"
    )

    /// "Max" — a faithful port of the HBO Max / Max tvOS look: a pure-black
    /// stage, white type, and WHITE focus (borders/fills/scale, no colour), a
    /// collapsible left icon sidebar that expands over a scrim, an HBO max
    /// lockup top-right, a left-scrimmed featured hero, and Top 10 rank
    /// numerals. GROUND-UP chrome (`NuvioTVApp.maxLayout` + `MaxSidebarNav` +
    /// `MaxHomeView`); the shared screens ride `MaxPalette`. Gates on
    /// `ThemeManager.isMaxTheme`.
    /// "Marquee" — a pure-black cinematic look (white focus, left icon sidebar,
    /// big featured hero). Internal id stays "max" so existing synced theme
    /// selections keep resolving to it.
    static let max = AppTheme(
        id: "max",
        displayName: "Marquee",
        summary: "A pure-black cinematic look — white focus, a left icon sidebar, and a big featured hero.",
        icon: "rectangle.stack.badge.play.fill"
    )

    /// "Streamline" — a port of the Hulu tvOS look: a dark navy/teal stage, an
    /// accent-coloured focus outline (follows the Color Theme), a left icon
    /// sidebar, and PLAY/DETAILS hero buttons. Its own chrome
    /// (`NuvioTVApp.huluLayout` + `HuluRootView`). Gates on
    /// `ThemeManager.isHuluTheme`. Internal id "hulu".
    static let hulu = AppTheme(
        id: "hulu",
        displayName: "Streamline",
        summary: "A dark navy stage with an accent focus outline, a left icon sidebar, and Play/Details buttons.",
        icon: "play.tv.fill"
    )

    /// Registration order = picker order. `appleTV` (Modern) is retired — kept
    /// defined so lingering references compile, but removed from `all` so it is
    /// no longer selectable and stored selections migrate to Classic.
    static let all: [AppTheme] = [classic, cinema, netflix, stremio, onyx, max, hulu]
    static let defaultID = classic.id

    static func theme(id: String) -> AppTheme { all.first { $0.id == id } ?? classic }
}

/// Light/dark preference for the Apple TV theme (Classic is always dark).
/// `system` follows the Apple TV's own Appearance setting.
enum ATVAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// Value handed to `.preferredColorScheme` (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide font family (applied at the root via `.fontDesign`).
enum AppFont: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Monospaced"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// How much of the settings surface to expose (mirrors Android's
/// ExperienceMode). Essential hides the most technical options.
enum ExperienceMode: String, CaseIterable, Identifiable, Codable {
    case essential, advanced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .essential: return "Essential"
        case .advanced: return "Advanced"
        }
    }
    var summary: String {
        switch self {
        case .essential: return "A simpler settings screen with just the everyday options"
        case .advanced: return "Every option, including engine, OSD and tuning controls"
        }
    }
    var isAdvanced: Bool { self == .advanced }
}

/// Settings-screen presentation style (mirrors Android's SettingsUiStyle).
/// Drives the corner radius of settings rows/cards.
enum SettingsUiStyle: String, CaseIterable, Identifiable, Codable {
    case classic, zen, horizon
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .zen: return "Zen"
        case .horizon: return "Horizon"
        }
    }
    var summary: String {
        switch self {
        case .classic: return "Soft rounded cards"
        case .zen: return "Pill-shaped rows"
        case .horizon: return "Sharp, squared edges"
        }
    }
    /// Corner radius for settings rows in this style.
    var rowRadius: CGFloat {
        switch self {
        case .classic: return 12
        case .zen: return 28
        case .horizon: return 2
        }
    }
    /// Corner radius for the larger settings group cards.
    var cardRadius: CGFloat {
        switch self {
        case .classic: return 18
        case .zen: return 34
        case .horizon: return 2
        }
    }
}

/// A per-axis LOOK variant — the detail page, profile screen and player overlay
/// can each independently use any theme's design (Orivio default, Marquee, or
/// Streamline), regardless of the selected app theme.
enum ThemeVariant: String, CaseIterable, Identifiable, Codable {
    case orivio, marquee, streamline
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .orivio: return "Orivio"
        case .marquee: return "Marquee"
        case .streamline: return "Streamline"
        }
    }
    func summary(_ kind: String) -> String {
        switch self {
        case .orivio: return "The default Orivio \(kind)."
        case .marquee: return "The HBO-Max-style \(kind) — pure black, white focus."
        case .streamline: return "The Hulu-style \(kind) — navy stage, accent focus."
        }
    }
}

/// The player-overlay axis. Independent of `ThemeVariant` (which still drives the
/// detail/profile axes): the player offers just two layouts — the default Orivio
/// controls, and an "HBO"/native-style minimal transport modelled on Apple TV's
/// own player chrome.
enum PlayerLayout: String, CaseIterable, Identifiable {
    case classic, hbo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .hbo: return "HBO"
        }
    }
    var summary: String {
        switch self {
        case .classic: return "The default Orivio playback controls."
        case .hbo: return "Apple TV's native-style transport — a clean scrubber, minimal chrome."
        }
    }
    var icon: String {
        switch self {
        case .classic: return "circle.grid.2x2.fill"
        case .hbo: return "play.rectangle.fill"
        }
    }
    /// Map any stored/synced string onto the two current options — including the
    /// retired values ("orivio"/"marquee"/"streamline") written while the player
    /// axis still shared `ThemeVariant`. The old HBO-styled "Marquee" overlay
    /// maps to `.hbo`; everything else falls back to `.classic`.
    init(stored raw: String?) {
        switch raw {
        case "hbo", "marquee": self = .hbo
        default: self = .classic
        }
    }
}

extension PlayerLayout: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlayerLayout(stored: raw)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The synced slice of the theme (accent palette + AMOLED + font + experience).
struct ThemeSnapshot: Codable, Equatable {
    var paletteID: String
    var amoled: Bool
    var font: AppFont
    /// Default advanced so existing users keep the full settings surface.
    var experienceMode: ExperienceMode = .advanced
    var settingsUiStyle: SettingsUiStyle = .classic
    /// Selected app theme id. Optional so blobs written before this field
    /// (and any Android blob without it) still decode cleanly.
    var appThemeID: String? = nil
    /// Apple TV theme light/dark preference. Optional for the same
    /// backward-compatibility reason as `appThemeID`.
    var atvAppearance: ATVAppearance? = nil
    /// Independent look axes — optional so old blobs still decode.
    var detailStyle: ThemeVariant? = nil
    var profileStyle: ThemeVariant? = nil
    var playerStyle: PlayerLayout? = nil
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published private var basePalette: ThemePalette {
        didSet {
            UserDefaults.standard.set(basePalette.id, forKey: Self.key)
            rebuildPalette()
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// AMOLED mode: force pure-black surfaces (APK "Use pure black for app backgrounds").
    @Published var amoled: Bool {
        didSet {
            UserDefaults.standard.set(amoled, forKey: Self.amoledKey)
            rebuildPalette()
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// App-wide font family (applied at the root with `.fontDesign`).
    @Published var font: AppFont {
        didSet {
            UserDefaults.standard.set(font.rawValue, forKey: Self.fontKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Settings-surface complexity (Essential hides advanced options).
    @Published var experienceMode: ExperienceMode {
        didSet {
            UserDefaults.standard.set(experienceMode.rawValue, forKey: Self.experienceKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Settings-screen presentation style (row/card shape).
    @Published var settingsUiStyle: SettingsUiStyle {
        didSet {
            UserDefaults.standard.set(settingsUiStyle.rawValue, forKey: Self.settingsStyleKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Independent LOOK axes — a user can mix the detail page, profile screen and
    /// player overlay of any theme regardless of the selected app theme.
    @Published var detailStyle: ThemeVariant {
        didSet {
            UserDefaults.standard.set(detailStyle.rawValue, forKey: Self.detailStyleKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    @Published var profileStyle: ThemeVariant {
        didSet {
            UserDefaults.standard.set(profileStyle.rawValue, forKey: Self.profileStyleKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    @Published var playerStyle: PlayerLayout {
        didSet {
            UserDefaults.standard.set(playerStyle.rawValue, forKey: Self.playerStyleKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Selected app theme (overall look preset). Currently only "classic";
    /// more can be registered in `AppThemes.all`.
    @Published var appThemeID: String {
        didSet {
            UserDefaults.standard.set(appThemeID, forKey: Self.appThemeKey)
            rebuildPalette()
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// Light/dark preference for the Apple TV theme. Ignored by Classic,
    /// which is hard-dark.
    @Published var atvAppearance: ATVAppearance {
        didSet {
            UserDefaults.standard.set(atvAppearance.rawValue, forKey: Self.atvAppearanceKey)
            if !applyingRemote { onLocalChange?() }
        }
    }
    /// The system's resolved scheme, fed in by the root view so `.system`
    /// appearance can pick the right palette. Defaults dark (tvOS default).
    @Published var systemIsDark = true

    /// The adapted palette, cached. `palette` used to recompute on every access;
    /// under the Apple TV theme that means running `ATVPalettes.adapt` — which
    /// rebuilds a ~20-field `ThemePalette` (every surface/text `Color(hex:)`
    /// reallocated) plus an accent lookup. Since `theme.palette` is read 600+
    /// times across the UI (many per view body, re-evaluated on every scroll and
    /// focus-move frame), recomputing per-access was a large per-frame cost the
    /// Classic theme never paid — there `palette` is just the stored base. The
    /// adapted result only depends on the accent, AMOLED and the active theme, so
    /// it's rebuilt only when one of those changes (see `rebuildPalette`).
    private var cachedPalette: ThemePalette = NuvioThemes.palette(id: "violet")

    /// Corner radius for settings rows under the current style.
    var settingsRowRadius: CGFloat { settingsUiStyle.rowRadius }
    /// Corner radius for the larger settings group cards under the current style.
    var settingsCardRadius: CGFloat { settingsUiStyle.cardRadius }

    /// Fired on a local (user-driven) theme change so the sync manager pushes it.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let key = "nuvio.theme"
    private static let amoledKey = "nuvio.theme.amoled"
    private static let fontKey = "nuvio.theme.font"
    private static let experienceKey = "nuvio.theme.experience"
    private static let settingsStyleKey = "nuvio.theme.settingsstyle"
    private static let appThemeKey = "nuvio.theme.appTheme"
    private static let explicitAppThemeKey = "nuvio.theme.appTheme.chosenHere.v1"
    private static let atvAppearanceKey = "nuvio.theme.atvAppearance"
    private static let detailStyleKey = "nuvio.theme.detailStyle"
    private static let profileStyleKey = "nuvio.theme.profileStyle"
    private static let playerStyleKey = "nuvio.theme.playerStyle"

    /// Dev-only launch-arg theme force (`-atvTheme` / `-classicTheme`) so the
    /// sim can be driven into either look without navigating Settings. Also
    /// wins over an account-synced snapshot for the session, since the synced
    /// blob would otherwise stomp the forced theme seconds after launch.
    private static var launchThemeOverride: String? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-cinemaTheme") { return AppThemes.cinema.id }
        if args.contains("-maxTheme") { return AppThemes.max.id }
        if args.contains("-huluTheme") { return AppThemes.hulu.id }
        if args.contains("-onyxTheme") { return AppThemes.onyx.id }
        if args.contains("-netflixTheme") { return AppThemes.netflix.id }
        if args.contains("-stremioTheme") { return AppThemes.stremio.id }
        if args.contains("-classicTheme") { return AppThemes.classic.id }
        return nil
    }

    /// Dev-only: force the look axes (detail/profile/player) for sim testing.
    private static var launchLooksOverride: ThemeVariant? {
        let a = ProcessInfo.processInfo.arguments
        if a.contains("-marqueeLooks") { return .marquee }
        if a.contains("-streamlineLooks") { return .streamline }
        return nil
    }

    /// Dev-only: force the player layout for sim testing.
    private static var launchPlayerOverride: PlayerLayout? {
        let a = ProcessInfo.processInfo.arguments
        if a.contains("-hboPlayer") { return .hbo }
        if a.contains("-classicPlayer") { return .classic }
        // The legacy looks flags still drive the player axis so existing test
        // launches keep working (Marquee was the HBO-styled overlay → .hbo).
        if a.contains("-marqueeLooks") { return .hbo }
        if a.contains("-streamlineLooks") { return .classic }
        return nil
    }

    /// Dev-only appearance force (`-atvLight` / `-atvDark`) — the tvOS sim
    /// runtime can't switch system appearance, so light mode is otherwise
    /// undrivable from the command line.
    private static var launchAppearanceOverride: ATVAppearance? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-atvLight") { return .light }
        if args.contains("-atvDark") { return .dark }
        return nil
    }

    init() {
        // Default to violet to match the Nuvio brand mark (cyan→purple play
        // logo); the old "crimson" default matched the retired red icon.
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? "violet"
        basePalette = NuvioThemes.palette(id: saved)
        amoled = UserDefaults.standard.bool(forKey: Self.amoledKey)
        font = AppFont(rawValue: UserDefaults.standard.string(forKey: Self.fontKey) ?? "") ?? .system
        experienceMode = ExperienceMode(rawValue: UserDefaults.standard.string(forKey: Self.experienceKey) ?? "") ?? .advanced
        settingsUiStyle = SettingsUiStyle(rawValue: UserDefaults.standard.string(forKey: Self.settingsStyleKey) ?? "") ?? .classic
        // A persisted id for a removed theme (e.g. the retired "premiere")
        // falls back to the default so the picker never rests on a phantom.
        let savedThemeID = UserDefaults.standard.string(forKey: Self.appThemeKey)
        appThemeID = Self.launchThemeOverride
            ?? savedThemeID.flatMap { id in AppThemes.all.contains { $0.id == id } ? id : nil }
            ?? AppThemes.defaultID
        atvAppearance = Self.launchAppearanceOverride
            ?? ATVAppearance(rawValue: UserDefaults.standard.string(forKey: Self.atvAppearanceKey) ?? "")
            ?? .system
        let looksOverride = Self.launchLooksOverride
        detailStyle = looksOverride ?? ThemeVariant(rawValue: UserDefaults.standard.string(forKey: Self.detailStyleKey) ?? "") ?? .orivio
        profileStyle = looksOverride ?? ThemeVariant(rawValue: UserDefaults.standard.string(forKey: Self.profileStyleKey) ?? "") ?? .orivio
        playerStyle = Self.launchPlayerOverride ?? PlayerLayout(stored: UserDefaults.standard.string(forKey: Self.playerStyleKey))
        // Seed the cache from the real inputs (the declaration default above is
        // just a placeholder; didSet doesn't fire for the initial assignments).
        rebuildPalette()
    }

    /// Current theme as a syncable snapshot.
    var snapshot: ThemeSnapshot {
        ThemeSnapshot(
            paletteID: basePalette.id, amoled: amoled, font: font,
            experienceMode: experienceMode, settingsUiStyle: settingsUiStyle,
            appThemeID: appThemeID, atvAppearance: atvAppearance,
            detailStyle: detailStyle, profileStyle: profileStyle, playerStyle: playerStyle
        )
    }

    /// Apply a snapshot pulled from the account without echoing it back up.
    func applyRemote(_ s: ThemeSnapshot) {
        guard s != snapshot else { return }
        applyingRemote = true
        basePalette = NuvioThemes.palette(id: s.paletteID)
        amoled = s.amoled
        font = s.font
        experienceMode = s.experienceMode
        settingsUiStyle = s.settingsUiStyle
        // Keep the CURRENT theme when the remote snapshot doesn't carry one
        // (a blob from an older build, or one whose id this build doesn't
        // know) — same rule as the look axes below. Falling back to the
        // DEFAULT here meant a stale blob reverted a just-picked theme to
        // Classic on the next pull.
        // A theme chosen on this device wins over the blob's (see
        // hasExplicitAppTheme). Without that, every profile switch — which runs
        // a full sync — reapplied that profile's stored theme over the user's
        // pick, and the push right after made the revert permanent.
        if let forced = Self.launchThemeOverride {
            appThemeID = forced
        } else if !hasExplicitAppTheme,
                  let remote = s.appThemeID,
                  AppThemes.all.contains(where: { $0.id == remote }) {
            appThemeID = remote
        }
        atvAppearance = Self.launchAppearanceOverride ?? s.atvAppearance ?? atvAppearance
        // Keep the CURRENT (locally-chosen) look axes when the remote snapshot
        // doesn't specify them — otherwise an older blob (nil fields) would stomp
        // a selection the user just made in Settings back to Orivio.
        let looks = Self.launchLooksOverride
        detailStyle = looks ?? s.detailStyle ?? detailStyle
        profileStyle = looks ?? s.profileStyle ?? profileStyle
        playerStyle = Self.launchPlayerOverride ?? s.playerStyle ?? playerStyle
        applyingRemote = false
    }

    /// The currently selected app theme.
    var appTheme: AppTheme { AppThemes.theme(id: appThemeID) }
    /// The user picking a theme in Settings — as opposed to one arriving from
    /// the account. Records that THIS DEVICE has an explicit choice, which then
    /// outranks anything a pulled blob carries (see `applyRemote`).
    func setAppTheme(_ t: AppTheme) {
        hasExplicitAppTheme = true
        appThemeID = t.id
    }

    /// Whether someone has chosen a theme on this device.
    ///
    /// This matters because the theme is a DEVICE-level look but it rides the
    /// per-PROFILE preferences blob. Switching profiles runs a full sync, whose
    /// pull carries that profile's stored theme — so picking Cinema on one
    /// profile and later switching to another silently reverted the look, and
    /// the following push wrote the reverted value back. Once the user has
    /// picked here, a pulled theme no longer overrides it; a device that has
    /// never chosen still adopts the account's, so a fresh install looks right.
    private(set) var hasExplicitAppTheme: Bool {
        get { UserDefaults.standard.bool(forKey: Self.explicitAppThemeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.explicitAppThemeKey) }
    }

    /// Root-level font design applied app-wide. Fusion routes Serif to headings
    /// ONLY (§8), so the global design stays sans when Serif is picked and the
    /// serif face is applied per-heading via `FusionType`. Rounded/Monospaced
    /// still apply everywhere. Classic keeps the global design for every choice.
    var rootFontDesign: Font.Design {
        if isAppleTVTheme && font == .serif { return .default }
        return font.design
    }

    /// The retired Modern theme's style flag. `appleTV` is no longer in `all`,
    /// so this is effectively always false — the shared components' `isAppleTVTheme`
    /// branches are now dead. Kept so those branches still compile.
    var isAppleTVTheme: Bool { appThemeID == AppThemes.appleTV.id }

    /// True for the Cinema theme — routes to `cinemaLayout` and gates the Cinema
    /// look/behaviour. Cinema owns all its screens/components (nothing shared
    /// with the retired Modern/Nova).
    var isCinemaTheme: Bool { appThemeID == AppThemes.cinema.id }

    /// True for the Onyx theme — near-black stage + white focus edge. Rides the
    /// shared Classic layout, restyled purely via `OnyxPalette` (like Aurora),
    /// so this exists mainly for any future component that wants Onyx's exact
    /// flat/no-glow focus treatment.
    var isOnyxTheme: Bool { appThemeID == AppThemes.onyx.id }

    /// True for the Max theme — a GROUND-UP port of the HBO Max look with its
    /// own chrome (`NuvioTVApp.maxLayout` + `MaxSidebarNav` + `MaxHomeView`) and
    /// its own player overlay skin. The shared screens ride `MaxPalette`.
    var isMaxTheme: Bool { appThemeID == AppThemes.max.id }

    /// True for the "Streamline" theme — a Hulu-look port with its own chrome
    /// (`NuvioTVApp.huluLayout` + `HuluRootView`); accent-driven focus. Shared
    /// screens ride `HuluPalette` (navy stage, keeps the user's accent).
    var isHuluTheme: Bool { appThemeID == AppThemes.hulu.id }

    /// True when the Netflix-inspired theme is active. A GROUND-UP theme (like
    /// Fusion vs Classic): its own chrome (`NuvioTVApp.netflixLayout` + custom
    /// `NetflixTopNav`), own background, own tokens — it deliberately does NOT
    /// ride `isAppleTVTheme`, so every Netflix look/behavior gates on this.
    var isNetflixTheme: Bool { appThemeID == AppThemes.netflix.id }

    /// True when the Stremio theme is active. Reuses the Classic sidebar
    /// layout, restyled via palette + `SidebarNav`/card focus branches.
    var isStremioTheme: Bool { appThemeID == AppThemes.stremio.id }

    /// Fusion is DARK-ONLY (the light appearance was removed) — its deep
    /// graphite palette is the whole identity, so this is always false. Kept as
    /// a single choke point in case a light option ever returns.
    var atvIsLight: Bool { false }

    /// Both themes render dark. (Fusion dropped its light/automatic option; the
    /// `atvAppearance` field is retained only so old synced blobs still decode.)
    var preferredColorScheme: ColorScheme? { .dark }

    /// The palette used across the app, with the AMOLED override applied.
    /// Under the Apple TV theme the base accent survives but surfaces swap to
    /// tvOS-style clear greys (light or dark).
    var palette: ThemePalette { cachedPalette }

    /// Recompute and store the adapted palette. Called from the `didSet` of every
    /// input that feeds it (accent, AMOLED, active theme). Cheap to call — it runs
    /// only on an actual settings change, not per view read.
    private func rebuildPalette() {
        cachedPalette = Self.buildPalette(appThemeID: appThemeID, base: basePalette, amoled: amoled)
    }

    /// Pure builder for the adapted palette (was the body of the old computed
    /// `palette`). Static so `init` can seed the cache before `self` is fully set.
    private static func buildPalette(appThemeID: String, base: ThemePalette, amoled: Bool) -> ThemePalette {
        if appThemeID == AppThemes.netflix.id {
            // Netflix-inspired: black theater stage + §6 accent tunings.
            return NetflixPalettes.adapt(base, amoled: amoled)
        }
        if appThemeID == AppThemes.stremio.id {
            // Stremio: navy-purple stage + purple accent.
            return StremioPalettes.adapt(base, amoled: amoled)
        }
        if appThemeID == AppThemes.cinema.id {
            // Cinema: a deep graphite dark stage (its own palette adapter).
            return CinemaPalette.adapt(base, amoled: amoled)
        }
        if appThemeID == AppThemes.onyx.id {
            // Onyx: near-black stage + white focus edge (bobsupra/NuvioTVOS look).
            return OnyxPalette.adapt(base, amoled: amoled)
        }
        if appThemeID == AppThemes.max.id {
            // Max: pure-black stage + white focus (HBO Max look).
            return MaxPalette.adapt(base, amoled: amoled)
        }
        if appThemeID == AppThemes.hulu.id {
            // Streamline: navy stage, keeps the user's accent (Hulu look).
            return HuluPalette.adapt(base, amoled: amoled)
        }
        guard amoled else { return base }
        var p = base
        p.background = NuvioPrimitives.black
        p.backgroundElevated = Color(hex: 0x0A0A0A)
        return p
    }

    /// Change the accent theme (keeps AMOLED state).
    func setPalette(_ palette: ThemePalette) { basePalette = palette }

    /// The Fusion focus glow, but only when card shadows/glows are enabled.
    /// A colored `.shadow(radius: 24–36)` on a focused card is an offscreen
    /// blur pass recomputed on every focus change and all through the zoom
    /// spring — the single most expensive per-focus effect on the A8 Apple TV
    /// HD. Folding it into the "Card Shadows" performance switch means it turns
    /// off wherever resting shadows do: automatically on the low/mid-power
    /// tiers (see `PerformanceSettingsStore.tierDefaults`) and any time the user
    /// disables shadows, while the cheap white focus BORDER still marks focus.
    /// Non-Fusion (Classic) never had a glow, so it stays `.clear` there.
    var effectiveFocusGlow: Color {
        guard isAppleTVTheme,
              PerformanceSettingsStore.shared.settings.cardShadows else { return .clear }
        return palette.focusGlow
    }
}

/// Spacing scale ported from Nuvio's SpacingTokens.
enum NuvioSpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 44
    static let huge: CGFloat = 64
}

enum NuvioRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}
