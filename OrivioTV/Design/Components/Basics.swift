import SwiftUI

/// "Continue Watching" etc. Optional add-on icon before the title and a See All capsule at the right.
struct SectionHeader: View {
    let title: String
    var iconURL: String? = nil
    var trailing: String? = nil
    var onSeeAll: (() -> Void)? = nil
    @Environment(\.ghostedRow) private var ghosted

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let iconURL {
                RemoteImage(url: iconURL, maxPixel: 96, contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            }
            Text(title).textStyle(.sectionHeader).lineLimit(1).opacity(ghosted ? 0 : 1)
            Spacer(minLength: 20)
            if let trailing { Text(trailing).textStyle(.meta) }
            if let onSeeAll {
                Button("See All", action: onSeeAll)
                    .buttonStyle(GlassCapsuleStyle(font: .system(size: 20, weight: .semibold), horizontalPadding: 18, height: 40))
            }
        }
    }
}

struct BadgePill: View {
    let text: String
    var systemImage: String? = nil
    var color: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(TypeStyle.badge.font)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background {
            if let color { Capsule().fill(color) } else { GlassSurface(shape: Capsule()) }
        }
    }
}

struct LivePill: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.live))
    }
}

/// Hairline-outlined badge ("TV-MA", "4K", "Dolby Vision").
struct OutlinedBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.textTertiary, lineWidth: 1.5))
    }
}

/// 8 pt dots; the current one is an elongated 28×8 capsule.
struct PaginationDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 1 : 0.45))
                    .frame(width: i == index ? 28 : 8, height: 8)
            }
        }
        .animation(Motion.focus, value: index)
        .allowsHitTesting(false)
    }
}

/// The meta line: parts joined with " · ", plus optional outlined badges.
struct MetaLine: View {
    var parts: [String]
    var rating: String? = nil
    var badges: [String] = []
    var style: TypeStyle = .meta

    var body: some View {
        HStack(spacing: 10) {
            let text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
            if !text.isEmpty { Text(text).textStyle(style).lineLimit(1) }
            if let rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.system(size: 18))
                    Text(rating)
                }
                .font(style.font)
                .foregroundStyle(Palette.positive)
            }
            ForEach(badges, id: \.self) { OutlinedBadge(text: $0) }
        }
    }
}

/// A progress bar (accent, or white under System White).
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(theme.progress).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// A 1 pt focusable anchor: with nothing focused, Menu falls through and
/// suspends the app. Every loading/QR screen needs one.
struct FocusAnchor: View {
    var body: some View {
        Button(action: {}) { Color.clear.frame(width: 1, height: 1) }
            .buttonStyle(AnchorStyle())
            .accessibilityHidden(true)
    }

    private struct AnchorStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

struct OrivioLoadingView: View {
    var label: String = "Loading…"
    var holdsFocus = true

    var body: some View {
        VStack(spacing: 24) {
            ProgressView().scaleEffect(1.4)
            Text(label).textStyle(.meta)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { if holdsFocus { FocusAnchor() } }
    }
}

struct OrivioEmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 64, weight: .light)).foregroundStyle(Palette.textSecondary)
            Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
            if let message {
                Text(message).textStyle(.body, color: Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 900)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryCapsuleStyle(minWidth: 220)).padding(.top, 8)
            } else {
                FocusAnchor()
            }
        }
        .padding(56)
        .glassCard(radius: Metrics.popoverRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `‹ ◉ Home` — the collapsed Apple TV sidebar hint. Not focusable.
struct NavCapsuleHint: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.textSecondary)
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.glassRaised))
            Text(title).font(.system(size: 26, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .frame(height: 52)
        .glassCapsule()
        .allowsHitTesting(false)
    }
}

/// Left-to-right + bottom scrims for text on artwork.
struct ArtworkScrims: View {
    var leftWidth: CGFloat = 0.55
    var bottomFraction: CGFloat = 0.35
    var bottomOpacity: Double = 0.6

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: leftWidth)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 1 - bottomFraction), .init(color: .black.opacity(bottomOpacity), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
