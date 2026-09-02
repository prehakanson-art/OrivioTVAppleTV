import SwiftUI

/// A Fusion accent — the four color roles the spec (§6) defines per accent.
/// `primary` is the base accent; `brightFocus` the max-focus outline/fill;
/// `darkTint` a muted variant; `glow` the translucent ambient focus glow.
struct FusionAccent {
    let primary: Color
    let brightFocus: Color
    let darkTint: Color
    let glow: Color
}

/// The seven Fusion accents (§6), keyed by the same ids as `OrivioThemes` so the
/// user's Color Theme choice maps straight through. Fusion uses these richer,
/// slightly more saturated values instead of the base app accents — but ONLY
/// when the Fusion theme is active (see `ATVPalettes.adapt`), so Classic keeps
/// its original accents untouched.
enum FusionAccents {
    static let white = FusionAccent(
        primary: Color(hex: 0xF2F3F5), brightFocus: Color(hex: 0xFFFFFF),
        darkTint: Color(hex: 0x737982), glow: Color(hex: 0xFFFFFF, alpha: 0.22))
    static let crimson = FusionAccent(
        primary: Color(hex: 0xF0445A), brightFocus: Color(hex: 0xFF6678),
        darkTint: Color(hex: 0x8F2637), glow: Color(hex: 0xF0445A, alpha: 0.30))
    static let ocean = FusionAccent(
        primary: Color(hex: 0x3C8DFF), brightFocus: Color(hex: 0x65A7FF),
        darkTint: Color(hex: 0x23589F), glow: Color(hex: 0x3C8DFF, alpha: 0.30))
    static let violet = FusionAccent(
        primary: Color(hex: 0x9468FF), brightFocus: Color(hex: 0xB08EFF),
        darkTint: Color(hex: 0x5B3E9F), glow: Color(hex: 0x9468FF, alpha: 0.30))
    static let emerald = FusionAccent(
        primary: Color(hex: 0x35CF8A), brightFocus: Color(hex: 0x5BE3A5),
        darkTint: Color(hex: 0x1C7B52), glow: Color(hex: 0x35CF8A, alpha: 0.30))
    static let mint = FusionAccent(
        primary: Color(hex: 0x1CE783), brightFocus: Color(hex: 0x57F0A5),
        darkTint: Color(hex: 0x0F7C48), glow: Color(hex: 0x1CE783, alpha: 0.30))
    static let amber = FusionAccent(
        primary: Color(hex: 0xF1AC3D), brightFocus: Color(hex: 0xFFC663),
        darkTint: Color(hex: 0x8E6425), glow: Color(hex: 0xF1AC3D, alpha: 0.28))
    static let rose = FusionAccent(
        primary: Color(hex: 0xF267A2), brightFocus: Color(hex: 0xFF8BBC),
        darkTint: Color(hex: 0x983E67), glow: Color(hex: 0xF267A2, alpha: 0.30))
    static let orivioPurple = FusionAccent(
        primary: Color(hex: 0x6D27E8), brightFocus: Color(hex: 0x925DFF),
        darkTint: Color(hex: 0x3C137F), glow: Color(hex: 0x6D27E8, alpha: 0.32))
    static let lavender = FusionAccent(
        primary: Color(hex: 0xB99AFF), brightFocus: Color(hex: 0xD4C1FF),
        darkTint: Color(hex: 0x6D5AA8), glow: Color(hex: 0xB99AFF, alpha: 0.28))

    static func accent(id: String) -> FusionAccent {
        switch id {
        case "crimson": return crimson
        case "ocean": return ocean
        case "violet": return violet
        case "purple": return orivioPurple
        case "lavender": return lavender
        case "emerald": return emerald
        case "mint": return mint
        case "amber": return amber
        case "rose": return rose
        default: return white
        }
    }

    /// Whether this accent needs dark text/icons on its fill (the near-white
    /// one, the light lavender and the neon mint).
    static func needsDarkOn(id: String) -> Bool { id == "white" || id == "lavender" || id == "mint" }
}

/// Fusion surface + text tokens (§5, §7). The accent (secondary/focus) comes
/// from `FusionAccents`; here we set the neutral graphite / light / AMOLED
/// surfaces and the text ramp. Applied only for the Fusion theme.
enum ATVPalettes {
    /// Rebuild `base` with Fusion surfaces + accent. `light` picks the warm
    /// off-white appearance; `amoled` (dark only) uses true black.
    static func adapt(_ base: ThemePalette, light: Bool, amoled: Bool) -> ThemePalette {
        var p = base

        // ── Accent (§6) — override the base app accent with the Fusion accent ──
        let accent = FusionAccents.accent(id: base.id)
        p.secondary = accent.primary
        p.secondaryVariant = accent.darkTint
        p.focusRing = accent.brightFocus
        p.focusGlow = accent.glow
        p.onSecondary = FusionAccents.needsDarkOn(id: base.id)
            ? Color(hex: 0x15171A) : OrivioPrimitives.white

        // ── Surfaces + text ──
        if light {
            // §7.3 — warm, muted off-white (not pure white).
            p.background = Color(hex: 0xE8E9EC)
            p.backgroundElevated = Color(hex: 0xF4F5F7)
            p.backgroundCard = Color(hex: 0xF4F5F7)
            p.surface = Color(hex: 0xEDEEF1)
            p.surfaceVariant = Color(hex: 0xE0E1E5)
            p.panel = Color(hex: 0xF4F5F7)
            p.field = Color(hex: 0xEDEEF1)
            p.overlay = Color.black.opacity(0.35)
            p.textPrimary = Color(hex: 0x15171A)
            p.textSecondary = Color(hex: 0x4F5560)
            p.textTertiary = Color(hex: 0x7B818C)
            p.focusBackground = accent.primary.opacity(0.16)
        } else if amoled {
            // §7.2 — true black, brighter edges compensate elsewhere.
            p.background = Color(hex: 0x000000)
            p.backgroundElevated = Color(hex: 0x080808)
            p.backgroundCard = Color(hex: 0x101010)
            p.surface = Color(hex: 0x080808)
            p.surfaceVariant = Color(hex: 0x151515)
            p.panel = Color(hex: 0x080808)
            p.field = Color(hex: 0x101010)
            p.overlay = Color.black.opacity(0.85)
            p.textPrimary = Color(hex: 0xF6F7F9)
            p.textSecondary = Color(hex: 0xBEC3CC)
            p.textTertiary = Color(hex: 0x858D99)
            p.focusBackground = accent.primary.opacity(0.22)
        } else {
            // Medium graphite GREY (not near-black) — matches the reference
            // Home art where the neutral page reads as a warm-cool grey stage.
            p.background = Color(hex: 0x202329)         // page grey
            p.backgroundElevated = Color(hex: 0x282C33) // raised
            p.backgroundCard = Color(hex: 0x2E323A)     // cards / rows
            p.surface = Color(hex: 0x282C33)
            p.surfaceVariant = Color(hex: 0x363B44)     // elevated controls
            p.panel = Color(hex: 0x282C33)
            p.field = Color(hex: 0x2E323A)
            p.overlay = Color(hex: 0x0A0C0F).opacity(0.72)
            p.textPrimary = Color(hex: 0xF6F7F9)
            p.textSecondary = Color(hex: 0xC3C8D0)
            p.textTertiary = Color(hex: 0x8E949E)
            p.focusBackground = accent.primary.opacity(0.20)
        }
        return p
    }
}

extension View {
    /// Liquid Glass when the box runs tvOS 26+, a plain translucent material
    /// on anything older — "liquid glass if the TV accepts it".
    @ViewBuilder
    func atvGlass<S: Shape>(in shape: S) -> some View {
        if PerformanceProfile.isLowPower {
            // A live glass/blur pass is one of the costliest composites on the
            // A8 Apple TV HD. On that box, back the layer with a solid graphite
            // tone — identical shape and layout, no per-frame blur.
            self.background(FusionMaterials.dialog, in: shape)
        } else if #available(tvOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Player-overlay chrome (toasts, pills, control sheets shown OVER playing
    /// video). `.ultraThinMaterial` here re-blurs the moving frame underneath on
    /// every displayed frame — one of the worst per-frame costs on the A8, and
    /// it drops playback frames while any control is up. On the low-power box
    /// fall back to a solid dark fill (visually near-identical, since these
    /// chips already sit under dark text scrims). `solid` is opaque enough that
    /// the missing blur doesn't read as a change.
    @ViewBuilder
    func playerChrome<S: Shape>(in shape: S, solid: Color = Color(hex: 0x121418).opacity(0.86)) -> some View {
        if PerformanceProfile.isLowPower {
            self.background(solid, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The tone hero/backdrop scrims fade into so full-bleed art dissolves into
/// `ATVBackground` without a seam — approximately the wash's color at the
/// lower-middle of the screen (the flat `palette.background` used to leave a
/// visible hard line where the hero band met the lighter graphite stage).
enum ATVStage {
    static let blend = Color(hex: 0x1E2126)
}

/// Fusion's environmental background (§4.1, §5): a deep graphite wash with a
/// vignette and a faint accent bloom — "deep rather than flat." In light
/// appearance it's a soft off-white stage. Sits behind every Fusion screen.
struct ATVBackground: View {
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        ZStack {
            theme.palette.background
            // Gentle grey depth wash — a touch lighter at top, slightly deeper
            // at the bottom, but staying a medium GREY (not sinking to black).
            // Black Background mode drops the wash so the stage is pure black,
            // keeping only the accent bloom.
            if !theme.amoled {
                LinearGradient(
                    colors: [Color(hex: 0x252931), Color(hex: 0x1B1E24)],
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(0.92)
            }
            // Accent bloom, top-leading — keeps the stage from reading dead.
            RadialGradient(
                colors: [theme.palette.secondary.opacity(theme.amoled ? 0.12 : 0.14), .clear],
                center: .topLeading, startRadius: 0, endRadius: 1500
            )
        }
        .ignoresSafeArea()
    }
}
