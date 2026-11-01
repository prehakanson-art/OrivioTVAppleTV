import SwiftUI

/// Background-only glass. **Never wrap focusable content in glass** — it makes
/// the content invisible to the focus engine (total focus trap). Use this as
/// `.background { }` behind content instead.
///
/// tvOS 26: Liquid Glass. Older: `.ultraThinMaterial`. A8/A10X: a solid
/// `white @ 10 %` (no live blur).
struct GlassSurface<S: Shape>: View {
    var shape: S
    var raised = false
    var tint: Color? = nil
    var dark = false

    var body: some View {
        Group {
            if raised {
                shape.fill(Palette.glassRaised)
            } else if !PerformanceProfile.allowsLiveBlur {
                shape.fill(dark ? Color.black.opacity(0.55) : Palette.glassSolid)
            } else if #available(tvOS 26.0, *) {
                Color.clear.glassEffect(dark ? .regular.tint(.black.opacity(0.45)) : .regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(dark ? Color.black.opacity(0.45) : Color.clear))
            }
        }
        .overlay(tint.map { shape.fill($0) })
        .allowsHitTesting(false)
    }
}

extension View {
    func glassBackground<S: Shape>(_ shape: S, raised: Bool = false, dark: Bool = false) -> some View {
        background { GlassSurface(shape: shape, raised: raised, dark: dark) }
    }

    func glassCapsule(raised: Bool = false) -> some View {
        glassBackground(Capsule(), raised: raised)
    }

    func glassCard(radius: CGFloat = Metrics.glassCardRadius, dark: Bool = false) -> some View {
        glassBackground(RoundedRectangle(cornerRadius: radius, style: .continuous), dark: dark)
    }
}
