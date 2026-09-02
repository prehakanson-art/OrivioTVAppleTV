import SwiftUI

// NOTE: `ATVPalettes.adapt` (the Fusion accent + graphite surface/text ramp)
// and the `FusionAccents` table it read lived here. Nothing ever called adapt —
// the palette shipped straight from `OrivioThemes` — so the whole ramp, and the
// `focusGlow` it was the only writer of, were dead. Deleted rather than wired
// up: switching them on now would change the app's colors and add a focus glow
// that has never actually been on screen.

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
            // BACKGROUND glass, never wrapping: a `glassEffect` wrapped around
            // focusable content can hide it from the focus engine.
            self.background(Color.clear.glassEffect(.regular, in: shape))
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
