import SwiftUI

// Fusion design tokens (§8–12). Typography, corner radius, motion, and
// materials for the Fusion theme. These are only consumed by Fusion-gated
// components, so Classic is unaffected.

// MARK: - Typography (§8, §9)

/// Fusion type roles at the 1920×1080 reference. Heading roles honor the Serif
/// font choice (serif face for big titles); body / metadata / technical roles
/// stay sans even when Serif is selected, exactly as the spec requires. The
/// Rounded and Monospaced choices apply everywhere.
enum FusionType {
    static func heroTitle(_ f: AppFont) -> Font { .system(size: 62, weight: .bold, design: heading(f)) }
    static func pageTitle(_ f: AppFont) -> Font { .system(size: 46, weight: .bold, design: heading(f)) }
    static func moduleHeading(_ f: AppFont) -> Font { .system(size: 30, weight: .semibold, design: heading(f)) }
    static func cardTitle(_ f: AppFont) -> Font { .system(size: 22, weight: .semibold, design: body(f)) }
    static func bodyText(_ f: AppFont) -> Font { .system(size: 23, weight: .regular, design: body(f)) }
    static func metadata(_ f: AppFont) -> Font { .system(size: 20, weight: .medium, design: body(f)) }
    static func button(_ f: AppFont) -> Font { .system(size: 23, weight: .semibold, design: body(f)) }
    static func badge(_ f: AppFont) -> Font { .system(size: 15, weight: .bold, design: body(f)) }
    /// Technical stream data — always monospaced regardless of font choice
    /// (§8: "Technical source data may look especially appropriate in this mode").
    static func technical(_ f: AppFont) -> Font { .system(size: 18, weight: .medium, design: .monospaced) }

    /// Heading design: serif titles when Serif is picked, else the font's design.
    private static func heading(_ f: AppFont) -> Font.Design { f.design }
    /// Body design: sans when Serif is picked (headings only get serif), else
    /// the font's own design.
    private static func body(_ f: AppFont) -> Font.Design {
        f == .serif ? .default : f.design
    }
}

// MARK: - Corner radius (§10)

/// Fusion artwork radius. Poster radius comes straight from the user's
/// corner-radius setting (0/6/11/16/22 steps); hero bars use that + 4. Does not
/// apply to avatars, badges, progress bars, or the native scrubber.
enum FusionRadius {
    static func poster(_ setting: Int) -> CGFloat { CGFloat(setting) }
    static func heroBar(_ setting: Int) -> CGFloat { CGFloat(setting) + 4 }
}

// MARK: - Motion (§12)

/// Fusion motion language. Two easing curves — an "enter" curve
/// (cubic-bezier 0.22,1,0.36,1) and an "exit" curve (0.4,0,0.6,1) — plus the
/// named durations from the spec, so every Fusion animation feels the same.
enum FusionMotion {
    static func enter(_ d: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }
    static func exit(_ d: Double) -> Animation { .timingCurve(0.4, 0, 0.6, 1, duration: d) }

    static let focusEntry = enter(0.22)
    static let focusExit = exit(0.17)
    static let focusMove = enter(0.21)
    static let focusMoveFast = enter(0.16)     // during rapid directional input
    static let pressDown = enter(0.085)
    static let pressRelease = exit(0.13)
    static let pageEnter = enter(0.32)
    static let pageExit = exit(0.22)
    static let heroCrossfade = enter(0.40)
    static let heroSlide = enter(0.48)
    static let dialogEnter = enter(0.24)
    static let dialogExit = exit(0.18)
    static let toastEnter = enter(0.22)
    static let toastExit = exit(0.20)
    static let controlsAppear = enter(0.18)
    static let controlsDismiss = exit(0.26)
    static let upNext = enter(0.30)

    /// Row reflow when a focused card grows into its landscape form (Onyx and
    /// Marquee): the card's width animates 210→560pt while every neighbour
    /// shifts, which is the largest layout move in the app. It settles with NO
    /// bounce — the previous 0.82-damped spring overshot, so the whole row
    /// visibly wobbled back into place — and runs slightly longer than a focus
    /// move so the growth reads as deliberate rather than snapped.
    /// Ambient auto-rotation of the hero. Deliberately slower than
    /// `heroCrossfade`: nobody asked for this change, so it should drift rather
    /// than cut.
    static let heroAutoRotate = enter(0.7)

    static let toastVisibleSeconds: Double = 2.6
}

// MARK: - Focus geometry (§13)

/// Fusion focus treatment constants for artwork cards, so every card lifts by
/// the same amount. Portrait and landscape differ slightly per the spec.
enum FusionFocus {
    static let portraitScale: CGFloat = 1.065
    static let portraitLift: CGFloat = -8
    static let landscapeScale: CGFloat = 1.075
    static let landscapeLift: CGFloat = -7
    static let brightness: Double = 1.055
    static let saturation: Double = 1.035
    /// Reduced scale used while the user is scrubbing focus rapidly (§15.5).
    static let rapidScale: CGFloat = 1.025
    static let borderWidth: CGFloat = 2
    static let borderColor = Color.white.opacity(0.88)
    static func shadow(_ focused: Bool) -> Color { .black.opacity(focused ? 0.58 : 0) }
    /// The Select-press dip, shared by every theme's card button style so a
    /// press reads the same in Classic, Apple TV, Onyx, Cinematic, Marquee and
    /// Streamline. Applied via `View.cardPressDip(_:)`, which gates it on
    /// "Button animations" + Reduce Motion.
    static let pressScale: CGFloat = 0.97
    static let pressAnimation: Animation = .easeOut(duration: 0.12)
    /// The curve a focus move settles on for themes that draw their own lift
    /// (via `View.focusLift`). One value so Marquee, Streamline, Onyx,
    /// Cinematic and Aurora don't each drift to their own duration.
    static let liftAnimation: Animation = .easeOut(duration: 0.16)
}

// MARK: - Materials (§11)

/// Translucent material tones for Fusion floating layers. Paired with
/// `.atvGlass` (Liquid Glass on tvOS 26, material fallback below).
enum FusionMaterials {
    static let sidebar = Color(hex: 0x080A0D, alpha: 0.88)
    static let dialog = Color(hex: 0x14171D, alpha: 0.94)
}
