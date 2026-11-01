import SwiftUI
import UIKit

// The pieces of the old Orivio app (NuvioTV-AppleTV) that its player draws
// with, brought over unchanged so the Classic player looks and behaves as it
// did there. Only what the player files reference lives here.

// MARK: - Motion and theme tokens (old Theme/FusionTokens.swift, OrivioTheme.swift)

enum FusionMotion {
    static func enter(_ d: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }
    static func exit(_ d: Double) -> Animation { .timingCurve(0.4, 0, 0.6, 1, duration: d) }

    static let pageEnter = enter(0.32)
    static let pageExit = exit(0.22)
    static let controlsAppear = enter(0.18)
    static let controlsDismiss = exit(0.26)
    static let upNext = enter(0.30)
}

enum FusionFocus {
    static let pressScale: CGFloat = 0.97
    static let pressAnimation: Animation = .easeOut(duration: 0.12)
    static let liftAnimation: Animation = .easeOut(duration: 0.16)
}

enum OrivioPrimitives {
    static let success = Color(.sRGB, red: 0x4C / 255, green: 0xAF / 255, blue: 0x50 / 255)
    static let warning = Color(.sRGB, red: 0xFF / 255, green: 0xB7 / 255, blue: 0x4D / 255)
    static let imdb = Color(.sRGB, red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255)
}

enum OrivioSpacing {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 44
    static let huge: CGFloat = 64
}

enum OrivioRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}

/// The old app's palette, as the player reads it (`theme.palette.secondary`).
struct ClassicPalette {
    let secondary: Color
}

extension Theme {
    /// The old player's accent comes from the new app's accent setting.
    var palette: ClassicPalette { ClassicPalette(secondary: accent) }
}

// MARK: - Focus lift (old Components.swift)

enum OrivioFocus {
    static let row: CGFloat = 1.02
    static let card: CGFloat = 1.05
    static let control: CGFloat = 1.08
}

private struct ClassicFocusLift: ViewModifier {
    let scale: CGFloat
    let focused: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .scaleEffect(focused && !PerformanceProfile.reduceMotion ? scale : 1)
            .animation(PerformanceProfile.reduceMotion ? nil : animation, value: focused)
    }
}

private struct ClassicCardPressDip: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !PerformanceProfile.reduceMotion ? FusionFocus.pressScale : 1)
            .animation(PerformanceProfile.reduceMotion ? nil : FusionFocus.pressAnimation, value: isPressed)
    }
}

extension View {
    func focusLift(_ scale: CGFloat, _ focused: Bool, animation: Animation = FusionFocus.liftAnimation) -> some View {
        modifier(ClassicFocusLift(scale: scale, focused: focused, animation: animation))
    }

    func cardPressDip(_ isPressed: Bool) -> some View {
        modifier(ClassicCardPressDip(isPressed: isPressed))
    }
}

struct PlainCardButtonStyle: ButtonStyle {
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cardPressDip(configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChanged?(pressed)
            }
    }
}

// MARK: - Badges (old Components.swift)

struct ContentRatingBadge: View {
    let rating: String

    var body: some View {
        Text(rating)
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            )
    }
}

struct MetaBadge: View {
    let text: String
    var tint: Color = .primary.opacity(0.14)
    var textColor: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ImdbBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 7) {
            Text("IMDb")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OrivioPrimitives.imdb, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(rating)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Time formatting (old Components.swift)

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func signedDelta(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : "+"
        return sign + clock(abs(seconds))
    }
}

// MARK: - Hardware tiers the old player asks about (old Core/PerformanceProfile.swift)

extension PerformanceProfile {
    /// HDR10+ needs an Apple TV 4K (3rd gen) on tvOS 18.4+. `-hdr10Plus` forces it (Simulator).
    static var supportsHDR10Plus: Bool {
        if arguments.contains("-hdr10Plus") { return true }
        guard isGen3 else { return false }
        if #available(tvOS 18.4, *) { return true }
        return false
    }

    static var hdr10PlusUnavailableReason: String? {
        guard !supportsHDR10Plus else { return nil }
        if !isGen3 { return "needs an Apple TV 4K (3rd gen) or newer — this is \(deviceName)" }
        if #available(tvOS 18.4, *) {} else { return "needs tvOS 18.4 or newer" }
        return "not supported by this Apple TV"
    }

    /// Full-bleed backdrop decode cap on the 3 GB boxes.
    static var backdropPixelCap: CGFloat? { isMidPower ? 2560 : nil }

    /// Ceiling on the in-memory video read-ahead (2 GB HD, 3 GB 4K gen 1/2, 4 GB+ gen 3).
    static var maxBufferBytes: Int {
        if isLowPower { return 220 << 20 }
        if isMidPower { return 400 << 20 }
        return 1000 << 20
    }

    /// Dolby Vision Profile 7 conversion defaults on only on the 4 GB+ boxes.
    static var recommendsDolbyVisionProfile7: Bool { !isLowPower && !isMidPower }
}

/// The old app's performance switches, as far as the player reads them.
@MainActor
final class PerformanceSettingsStore {
    static let shared = PerformanceSettingsStore()
    struct Settings { var showPlayerDiagnostics = false }
    var settings = Settings()
    var reduceMotion: Bool { PerformanceProfile.reduceMotion }
}

/// The old sync manager's "a title is playing" flag. The new sync layer
/// doesn't pause for playback, so nothing reads it.
enum OrivioSyncManager {
    @MainActor static var playbackActive = false
}

/// The old decoded-image cache: its only player call frees memory before playback.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    func dropDecoded() { ImagePipeline.shared.purge() }
}

// MARK: - Old initialisers

extension Color {
    /// The old app's `Color(hex: 0xRRGGBB)`.
    init(hex: Int, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension RemoteImage {
    /// The old app's `RemoteImage(url:maxDimension:)`.
    init(url: String?, maxDimension: CGFloat) {
        self.init(url: url, maxPixel: maxDimension)
    }
}

extension DebridStore {
    /// The provider torrents resolve through first (none when no key is set).
    var resolverProvider: DebridProvider? {
        let s = value
        guard s.hasAny else { return nil }
        return s.configured.contains(s.preferred) ? s.preferred : s.configured.first
    }
}

// MARK: - Player chrome (old Theme/ATVTheme.swift)

extension View {
    /// Blur behind a chip over moving video — a solid tone on the A8/A10X boxes.
    @ViewBuilder
    func playerChrome<S: Shape>(in shape: S, solid: Color = Color(hex: 0x121418).opacity(0.86)) -> some View {
        if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
            self.background(solid, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension RemoteImage {
    /// The old `RemoteImage(url:maxPixels:)` (nil = the device's backdrop cap).
    init(url: String?, maxPixels: CGFloat?) {
        self.init(url: url, maxPixel: maxPixels ?? ImageSize.backdrop, placeholder: false)
    }

    /// The old `RemoteImage(url:contentMode:maxDimension:)`.
    init(url: String?, contentMode: ContentMode, maxDimension: CGFloat) {
        self.init(url: url, maxPixel: maxDimension, contentMode: contentMode, placeholder: false)
    }
}
