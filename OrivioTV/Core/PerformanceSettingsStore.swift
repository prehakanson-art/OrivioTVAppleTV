import Foundation
import SwiftUI
import UIKit

/// How much motion collection folder tiles may use on focus.
///
/// Collection packs ship focus artwork per folder — often 3–4 MB GIFs of
/// 120–240 frames. Decoding those is the single most expensive thing a tile can
/// do, so this is a real performance dial, not a cosmetic one. It defaults to
/// OFF on the 2 GB Apple TV HD and the 3 GB 4K gen 1, which is where the cost
/// actually hurts.
enum CollectionGifQuality: String, Codable, CaseIterable, Identifiable {
    /// Animated, highest frame rate and resolution this device allows.
    case full
    /// Static focus artwork only — the hover image swaps in, nothing animates.
    /// Costs one still image per tile instead of dozens of frames.
    case partial
    /// Nothing on focus; the cover art stays put. Cheapest.
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:    return "Full — animated"
        case .partial: return "Partial — still images"
        case .off:     return "Off"
        }
    }

    var summary: String {
        switch self {
        case .full:
            return "Play the collection's focus GIFs. The richest look, and by far the heaviest — a single GIF can be 240 frames."
        case .partial:
            return "Swap in the focus artwork as a still image. Keeps the art change on focus at a fraction of the cost."
        case .off:
            return "Leave the cover art alone on focus. Recommended on older Apple TVs."
        }
    }

    /// Default for this hardware. Deliberately OFF on both constrained tiers:
    /// the 3 GB 4K gen 1 froze with GIFs enabled.
    static var deviceDefault: CollectionGifQuality {
        (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? .off : .full
    }
}


/// User-tunable performance switches (Settings → Performance). On 4K gen-2+
/// hardware everything defaults ON — the app's full look. Older boxes start
/// with the costly effects OFF (see `tierDefaults()`); every switch remains
/// user-tunable either way, so the tier default is a starting point, not a cap.
///
/// Persisted per-device in UserDefaults and deliberately NOT synced to the
/// account: a setting tuned for the living-room 4K gen 1 shouldn't downgrade
/// a newer box on the same account.
@MainActor
final class PerformanceSettingsStore: ObservableObject {
    static let shared = PerformanceSettingsStore()

    struct Settings: Codable, Equatable {
        /// Full-screen artwork behind Home that changes as you browse.
        var heroBackdrop = true
        /// Dissolve animation when the hero artwork/info changes.
        var heroCrossfade = true
        /// Soft drop shadows under posters and cards.
        var cardShadows = true
        /// Cards spring slightly larger when focused.
        var focusZoom = true
        /// Apple TV theme only: the native tvOS card platter — the focused
        /// poster lifts and tilts/parallaxes with the trackpad. It's the
        /// heaviest per-frame focus effect (the system re-composites the whole
        /// focused card as the finger moves). OFF swaps in a lightweight
        /// scale-only focus so cards still respond, without the tilt.
        var cardParallax = true
        /// Background download of below-the-fold row artwork.
        var artworkPrefetch = true
        /// Fade posters in as they finish loading.
        var artworkFadeIn = true
        /// The sidebar's expand/collapse spring + the dim over the content.
        var sidebarAnimation = true
        /// Scale/spring on small controls (See All, tab pills, presses).
        var buttonAnimations = true
        /// Developer: live FPS counter overlaid on the app. Off by default,
        /// never set by the tier defaults — a diagnostic, not an effect.
        var showFPSOverlay = false
        /// On-screen tracing for the hold-Select menus (see HoldProbe).
        var showHoldProbe = false
        /// In-player diagnostics HUD: engine, fps, dropped frames, A/V drift,
        /// bitrate, buffer depth. Answers "why is this stuttering" on the
        /// couch, without a Mac attached.
        var showPlayerDiagnostics = false
        /// Motion allowed on collection folder tiles when focused. Defaults per
        /// hardware tier (off on the 2 GB HD and the 3 GB 4K gen 1).
        var collectionGifQuality: CollectionGifQuality = .deviceDefault

        init() {}

        private enum CodingKeys: String, CodingKey {
            case heroBackdrop, heroCrossfade, cardShadows, focusZoom, cardParallax, showHoldProbe
            case artworkPrefetch, artworkFadeIn
            case sidebarAnimation, buttonAnimations, showFPSOverlay, showPlayerDiagnostics
            case collectionGifQuality
        }

        /// Lenient decode: a key missing from an older save keeps its default
        /// instead of failing the whole decode (which would reset every
        /// switch each time a new one ships).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heroBackdrop = (try? c.decode(Bool.self, forKey: .heroBackdrop)) ?? true
            heroCrossfade = (try? c.decode(Bool.self, forKey: .heroCrossfade)) ?? true
            cardShadows = (try? c.decode(Bool.self, forKey: .cardShadows)) ?? true
            focusZoom = (try? c.decode(Bool.self, forKey: .focusZoom)) ?? true
            cardParallax = (try? c.decode(Bool.self, forKey: .cardParallax)) ?? true
            artworkPrefetch = (try? c.decode(Bool.self, forKey: .artworkPrefetch)) ?? true
            artworkFadeIn = (try? c.decode(Bool.self, forKey: .artworkFadeIn)) ?? true
            sidebarAnimation = (try? c.decode(Bool.self, forKey: .sidebarAnimation)) ?? true
            buttonAnimations = (try? c.decode(Bool.self, forKey: .buttonAnimations)) ?? true
            showFPSOverlay = (try? c.decode(Bool.self, forKey: .showFPSOverlay)) ?? false
            showHoldProbe = (try? c.decode(Bool.self, forKey: .showHoldProbe)) ?? false
            showPlayerDiagnostics = (try? c.decode(Bool.self, forKey: .showPlayerDiagnostics)) ?? false
            collectionGifQuality = (try? c.decode(CollectionGifQuality.self, forKey: .collectionGifQuality))
                ?? .deviceDefault
        }
    }

    @Published var settings: Settings { didSet { save() } }

    /// Live mirror of the system Accessibility → Reduce Motion switch. When ON
    /// it forces the *motion* effects off regardless of the user's toggles (a
    /// Reduce Motion user still keeps non-motion polish like backdrop art and
    /// shadows). Read via the `…Effective` accessors below.
    @Published private(set) var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    // MARK: Effective (motion) values — user switch AND not overridden by
    // Reduce Motion. Call sites that gate an animation read these instead of
    // `settings.x` so the system setting is honored in one place.
    var heroCrossfadeEffective: Bool { settings.heroCrossfade && !reduceMotion }
    var focusZoomEffective: Bool { settings.focusZoom && !reduceMotion }
    var sidebarAnimationEffective: Bool { settings.sidebarAnimation && !reduceMotion }
    var buttonAnimationsEffective: Bool { settings.buttonAnimations && !reduceMotion }
    var artworkFadeInEffective: Bool { settings.artworkFadeIn && !reduceMotion }
    /// The native tvOS card platter's trackpad tilt/parallax. It is a *motion*
    /// effect like the rest, so Reduce Motion suppresses it too — themes that
    /// branch on this fall back to their own flat focus visual.
    var cardParallaxEffective: Bool { settings.cardParallax && !reduceMotion }

    // MARK: Motion helpers — so every theme gates focus motion the same way
    // instead of each porting its own hardcoded scale/animation.

    /// Focus zoom for a card/tile: the theme's scale when "Cards spring
    /// slightly larger when focused" is on and Reduce Motion is off, else 1
    /// (no lift at all). Every theme's focus scale should go through this.
    func focusScale(_ scale: CGFloat, _ focused: Bool) -> CGFloat {
        focusZoomEffective && focused ? scale : 1
    }

    /// A focus/state animation that snaps instead of animating under Reduce
    /// Motion. Returns `nil` (SwiftUI's "no animation") when motion is off.
    func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A press/control animation, additionally gated by the "Button
    /// animations" switch (Settings → Performance).
    func buttonMotion(_ animation: Animation) -> Animation? {
        buttonAnimationsEffective ? animation : nil
    }

    // MARK: Master "Performance mode"
    /// True when every optional visual effect is off — the lightest look.
    /// `artworkPrefetch` is excluded: it HELPS perceived scrolling (art is
    /// ready before you reach it), so max-performance leaves it on.
    var isMaxPerformance: Bool {
        let s = settings
        return !s.heroBackdrop && !s.heroCrossfade && !s.cardShadows
            && !s.focusZoom && !s.cardParallax && !s.artworkFadeIn
            && !s.sidebarAnimation && !s.buttonAnimations
    }

    /// One switch for all the eye-candy: ON strips every effect for max speed,
    /// OFF restores the full look. (Individual switches still work afterward.)
    func setMaxPerformance(_ on: Bool) {
        let v = !on
        var s = settings
        s.heroBackdrop = v; s.heroCrossfade = v; s.cardShadows = v
        s.focusZoom = v; s.cardParallax = v; s.artworkFadeIn = v
        s.sidebarAnimation = v; s.buttonAnimations = v
        settings = s
    }

    /// Restore the hardware-tuned baseline for this box (the first-run defaults).
    func resetToRecommended() {
        let show = settings.showFPSOverlay   // a diagnostic, not part of the reset
        let diag = settings.showPlayerDiagnostics
        var s = Self.tierDefaults()
        s.showFPSOverlay = show
        s.showPlayerDiagnostics = diag
        settings = s
    }

    private static let key = "orivio.performance.v1"

    /// First-run defaults tuned to the hardware tier. Users who never open
    /// Settings → Performance shouldn't pay full-eye-candy jank on an A8/A10X:
    /// the costly effects start OFF there and can be re-enabled per switch.
    /// Anything the user has ever saved wins over these (see init).
    static func tierDefaults() -> Settings {
        var s = Settings()
        if PerformanceProfile.isLowPower {
            // Apple TV HD (A8 / 2 GB): keep the core artwork, but drop recurring
            // animation/composite cost. Focus is still clear via rings/borders.
            s.cardShadows = false
            s.heroCrossfade = false
            s.focusZoom = false
            s.artworkFadeIn = false
            s.sidebarAnimation = false
            s.buttonAnimations = false
            // The native card platter re-composites the focused poster on every
            // trackpad micro-movement — the heaviest per-frame focus cost on the
            // A8. Default to the lightweight scale-only focus instead.
            s.cardParallax = false
        } else if PerformanceProfile.isMidPower {
            // 4K gen 1 (A10X / 3 GB): shadows, per-cell fades and the hero
            // crossfade (now also the info-panel rebuild) are what visibly
            // cost during row scrolls; the rest it handles fine.
            s.cardShadows = false
            s.artworkFadeIn = false
            s.heroCrossfade = false
        }
        return s
    }

    private init() {
        if ProcessInfo.processInfo.arguments.contains("-lowPower") {
            // Dev tier force (see PerformanceProfile.isLowPower): show the A8's
            // real first-run defaults, not whatever this sim previously saved —
            // otherwise the forced tier runs with high-tier eye candy on and
            // measures nothing.
            settings = Self.tierDefaults()
        } else if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Self.tierDefaults()
        }
        // Track the system Reduce Motion switch live so toggling it in
        // Accessibility takes effect without relaunching.
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
