import SwiftUI

// Focus visuals are drawn from `\.isFocused` *inside* the style's body —
// `.onFocusChange` on a Button wrapper never fires on tvOS.

/// Media cards: a focus lift without the native parallax platter (the system
/// card style swallows `.contextMenu`). Scale + soft shadow on a spring.
struct FlatCardStyle: ButtonStyle {
    var lift: CGFloat = 1.08
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, lift: lift, onPressChanged: onPressChanged)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let lift: CGFloat
        let onPressChanged: ((Bool) -> Void)?
        #if DEBUG
        static let shadow = !PerformanceProfile.arguments.contains("-noCardShadow")
            && !PerformanceProfile.isConstrained
        #else
        static let shadow = !PerformanceProfile.isConstrained
        #endif

        var body: some View {
            configuration.label
                .scaleEffect(focused ? (configuration.isPressed ? lift - 0.03 : lift) : 1)
                .shadow(color: .black.opacity(focused && Self.shadow ? 0.45 : 0), radius: focused && Self.shadow ? 20 : 0, y: focused && Self.shadow ? 18 : 0)
                .animation(Motion.focus, value: focused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .zIndex(focused ? 1 : 0)
                .onChange(of: configuration.isPressed) { _, p in onPressChanged?(p) }
        }
    }
}

/// Rows/list items (sidebar, Settings, Library list): a full-width **white
/// capsule** behind the focused row, text turns `focusInk`. Selected-but-
/// unfocused = `glassRaised` capsule.
struct FocusCapsuleRowStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat? = nil
    var horizontalPadding: CGFloat = 22
    var height: CGFloat? = 60

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, cornerRadius: cornerRadius,
             horizontalPadding: horizontalPadding, height: height)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let cornerRadius: CGFloat?
        let horizontalPadding: CGFloat
        let height: CGFloat?

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : Palette.textPrimary)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background {
                    shape.fill(focused ? Palette.focusFill : (selected ? Palette.glassRaised : .clear))
                }
                .scaleEffect(focused ? 1.02 : 1)
                .animation(Motion.focus, value: focused)
                .environment(\.rowFocused, focused)
        }

        private var shape: AnyShape {
            if let cornerRadius { return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
            return AnyShape(Capsule())
        }
    }
}

private struct RowFocusedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside a focused `FocusCapsuleRowStyle` row (for secondary text tint).
    var rowFocused: Bool {
        get { self[RowFocusedKey.self] }
        set { self[RowFocusedKey.self] = newValue }
    }
}

/// Primary capsule ("Play", "Go to Movie"): white glass at rest, white (or the
/// accent) fill when focused, 64 pt tall. `minWidth` keeps the ≥ 200 pt hold-menu floor.
struct PrimaryCapsuleStyle: ButtonStyle {
    var minWidth: CGFloat = 260
    var height: CGFloat = 64

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, minWidth: minWidth, height: height)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.theme) private var theme
        let configuration: Configuration
        let minWidth: CGFloat
        let height: CGFloat

        var body: some View {
            configuration.label
                .font(TypeStyle.button.font)
                .foregroundStyle(focused ? theme.primaryFocusInk : .white)
                .padding(.horizontal, 34)
                .frame(minWidth: minWidth, minHeight: height)
                .background {
                    if focused { Capsule().fill(theme.primaryFocusFill) } else { GlassSurface(shape: Capsule(), tint: .white.opacity(0.12)) }
                }
                .scaleEffect(focused ? (configuration.isPressed ? 1.02 : 1.06) : 1)
                .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.35 : 0),
                        radius: PerformanceProfile.isConstrained ? 0 : 16,
                        y: PerformanceProfile.isConstrained ? 0 : 8)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// 64 pt circle: glass at rest → white fill with a dark glyph when focused, scale 1.1.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 64
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, size: size, active: active)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let size: CGFloat
        let active: Bool

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .frame(width: size, height: size)
                .background {
                    if focused { Circle().fill(Palette.focusFill) } else { GlassSurface(shape: Circle(), raised: active) }
                }
                .scaleEffect(focused ? (configuration.isPressed ? 1.04 : 1.1) : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Small glass capsule (See All, Sort ▾, filter chips, season tabs).
struct GlassCapsuleStyle: ButtonStyle {
    var selected = false
    var font: Font = .system(size: 22, weight: .semibold)
    var horizontalPadding: CGFloat = 22
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, font: font, horizontalPadding: horizontalPadding, height: height)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let font: Font
        let horizontalPadding: CGFloat
        let height: CGFloat

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height)
                .background {
                    if focused { Capsule().fill(Palette.focusFill) } else { GlassSurface(shape: Capsule(), raised: selected) }
                }
                .scaleEffect(focused ? 1.05 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Text tab (season strip): selected = white, others white 60 %, focused = white capsule.
struct TextTabStyle: ButtonStyle {
    var selected: Bool
    var font: Font = TypeStyle.seasonTab.font

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, font: font)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let font: Font

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(focused ? Palette.focusInk : (selected ? .white : .white.opacity(0.6)))
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background { Capsule().fill(focused ? Palette.focusFill : .clear) }
                .scaleEffect(focused ? 1.04 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// A plain focusable glass card (focused = white 55 % fill).
struct GlassCardStyle: ButtonStyle {
    var radius: CGFloat = Metrics.glassCardRadius

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, radius: radius)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let radius: CGFloat

        var body: some View {
            configuration.label
                .background {
                    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    if focused { shape.fill(Color.white.opacity(0.55)) } else { GlassSurface(shape: shape) }
                }
                .scaleEffect(focused ? 1.03 : 1)
                .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.3 : 0),
                        radius: PerformanceProfile.isConstrained ? 0 : 18,
                        y: PerformanceProfile.isConstrained ? 0 : 10)
                .animation(Motion.focus, value: focused)
        }
    }
}

// MARK: - Convenience views

struct PrimaryCapsuleButton: View {
    let title: String
    var systemImage: String? = "play.fill"
    var minWidth: CGFloat = 260
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 24, weight: .bold)) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(PrimaryCapsuleStyle(minWidth: minWidth))
    }
}

struct CircleButton: View {
    let systemImage: String
    var size: CGFloat = 64
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(CircleButtonStyle(size: size, active: active))
    }
}
