import SwiftUI

// Cards are Button labels; they read `\.isFocused` themselves. Decorative
// images never hit-test (focus isn't hit-tested, context menus are).

// MARK: - Poster (240×360) with the focus caption strip

struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat = 240
    var landscape = false
    var showsLabel = true
    var watched = false
    var progress: Double? = nil
    var numeral: Int? = nil
    @Environment(\.isFocused) private var focused

    private var height: CGFloat { landscape ? width * 9 / 16 : width * 1.5 }
    /// The focused card grows a caption strip at its bottom, inside the same
    /// rounded shape. It extends past the layout frame so neighbours don't move.
    private var stripHeight: CGFloat {
        // A8/A10X: the caption strip grew the focused card by 46 pt, so every
        // focus move animated a layout (and row-height) change as well as the
        // scale. Keep the plain card there; the title line stays visible.
        if PerformanceProfile.isConstrained { return 0 }
        #if DEBUG
        if Self.noStrip { return 0 }
        #endif
        return focused && !landscape ? 46 : 0
    }
    #if DEBUG
    private static let noStrip = PerformanceProfile.arguments.contains("-noCardStrip")
    #endif
    private var imageURL: String? { landscape ? (meta.background ?? meta.poster) : meta.poster }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("PosterCard")
        #endif
        VStack(alignment: .leading, spacing: 12) {
            card
                .frame(width: width, height: height, alignment: .top)
                .zIndex(1)
            if showsLabel {
                Text(meta.name)
                    .font(TypeStyle.caption.font)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    // Same reserved height as the numbered rows below: a text
                    // label is 11 pt shorter than the space they keep, which
                    // made otherwise identical rows measure 11 pt apart and
                    // shifted the Home stack when one arrived.
                    .frame(width: width, height: 34, alignment: .topLeading)
                    .opacity(stripHeight > 0 ? 0 : 1)
            } else if !landscape {
                // No title line (numbered rows): keep the room the focused card's
                // caption strip grows into, or it covered the next row's header.
                Color.clear.frame(width: width, height: 34)
            }
        }
    }

    private var card: some View {
        ZStack(alignment: .top) {
            // Blurred continuation of the artwork — what the strip is made of.
            if stripHeight > 0 {
                if PerformanceProfile.isConstrained {
                    // A live blur re-renders the whole card on every focus frame.
                    // On A8/A10X the strip is a solid tint instead.
                    Color.black.opacity(0.55)
                        .frame(width: width, height: height + stripHeight)
                        .transition(.opacity)
                } else {
                    RemoteImage(url: imageURL, maxPixel: 200, placeholder: false)
                        .frame(width: width, height: height + stripHeight)
                        .scaleEffect(1.25, anchor: .bottom)
                        .blur(radius: 18)
                        .overlay(Color.black.opacity(0.18))
                        .transition(.opacity)
                }
            }
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: imageURL, maxPixel: landscape ? ImageSize.landscape : ImageSize.poster,
                            fallbackURL: landscape ? meta.poster : meta.background)
                    .frame(width: width, height: height)
                if landscape || meta.poster == nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    LogoOrTitle(logo: landscape ? meta.logo : nil, title: meta.name,
                                maxSize: CGSize(width: width * 0.7, height: height * 0.35), fallbackStyle: .cardTitle)
                        .padding(14)
                }
                if let numeral {
                    Text("\(numeral)")
                        .font(.system(size: 72, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(PerformanceProfile.isConstrained ? 0 : 0.6), radius: PerformanceProfile.isConstrained ? 0 : 8)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let progress, progress > 0.01 {
                    ProgressBar(fraction: progress, height: 5).padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
            .frame(width: width, height: height)
            // The poster melts into the caption strip — drawn as an overlay on
            // the focused card only. (A gradient .mask on every card forced an
            // offscreen pass for all of them on every frame of movement.)
            .overlay(alignment: .bottom) {
                if stripHeight > 0 {
                    LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                        .frame(height: height * 0.14)
                        .transition(.opacity)
                }
            }
            if stripHeight > 0 {
                Text(([meta.typeLabel] + meta.genres.prefix(1)).joined(separator: " · "))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .frame(width: width, height: stripHeight)
                    .offset(y: height)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height + stripHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if watched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.focusInk, .white)
                    .padding(10)
            }
        }
        .animation(Motion.focus, value: focused)
    }
}

// MARK: - Continue Watching (340×212)

struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem
    var spoilerBlur = false
    var showCountdown = false
    @Environment(\.isFocused) private var focused

    static let size = CGSize(width: 340, height: 212)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.image, maxPixel: ImageSize.landscape, fallbackURL: item.meta.poster)
                .frame(width: Self.size.width, height: Self.size.height)
                .blur(radius: spoilerBlur && !PerformanceProfile.isConstrained ? 18 : 0)
                .overlay(Color.black.opacity(spoilerBlur && PerformanceProfile.isConstrained ? 0.55 : 0))
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                LogoOrTitle(logo: item.meta.logo, title: item.meta.name, maxSize: CGSize(width: 200, height: 64),
                            fallbackStyle: .cardTitle)
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                    if item.fraction > 0 {
                        ProgressBar(fraction: item.fraction, height: 4).frame(width: 60)
                    }
                    Text(subtitle).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
            }
            .padding(14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if showCountdown, let up = item.upcoming { BadgePill(text: up, systemImage: "calendar") }
                if item.newEpisodes > 0 { BadgePill(text: "+\(item.newEpisodes)", color: Palette.live.opacity(0.9)) }
            }
            .padding(10)
        }
    }

    private var subtitle: String {
        if let v = item.video, let s = v.season, let e = v.episode {
            if let p = item.progress { return "S\(s), E\(e) · \(p.remainingLabel)" }
            return "S\(s), E\(e)" + (item.isNextUp ? " · Next" : "")
        }
        if let p = item.progress { return p.remainingLabel }
        return item.meta.typeLabel
    }
}

// MARK: - Featured tall card (540×560)

struct TallFeatureCard: View {
    let meta: MetaItem
    var badge: String? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: meta.background ?? meta.poster, maxPixel: ImageSize.landscape, fallbackURL: meta.poster)
                .frame(width: 540, height: 480)
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                if let badge { BadgePill(text: badge) }
                LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 380, height: 120), fallbackStyle: .sectionHeader)
                Text(([meta.typeLabel] + meta.genres.prefix(2)).joined(separator: " · "))
                    .textStyle(.meta)
                    .lineLimit(1)
            }
            .padding(24)
        }
        .frame(width: 540, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
    }
}

// MARK: - Gradient tile ("Genius Browse")

struct GradientTile: View {
    let title: String
    var seed: String
    var width: CGFloat = 220
    var height: CGFloat = 300
    var emoji: String? = nil

    static let palettes: [(String, String)] = [
        ("#FF5F6D", "#FFC371"), ("#2193B0", "#6DD5ED"), ("#CC2B5E", "#753A88"), ("#42275A", "#734B6D"),
        ("#DE6262", "#FFB88C"), ("#06BEB6", "#48B1BF"), ("#EB3349", "#F45C43"), ("#56AB2F", "#A8E063"),
        ("#614385", "#516395"), ("#E55D87", "#5FC3E4"), ("#1D976C", "#93F9B9"), ("#F7971E", "#FFD200"),
    ]

    var body: some View {
        let p = Self.palettes[abs(seed.hashValue) % Self.palettes.count]
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.hex(p.0), .hex(p.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let emoji {
                Text(emoji).font(.system(size: 72)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .shadow(color: .black.opacity(0.25), radius: 4)
                .padding(18)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
    }
}

// MARK: - Cast circle (180 pt)

struct CastCircle: View {
    let name: String
    var role: String?
    var photo: String?
    var size: CGFloat = 180
    var tint: Color = .teal
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.55))
                if let photo {
                    RemoteImage(url: photo, maxPixel: 400, placeholder: false).clipShape(Circle())
                } else {
                    Text(initials).font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: focused ? 4 : 0))
            .scaleEffect(focused ? 1.1 : 1)
            .animation(Motion.focus, value: focused)
            VStack(spacing: 4) {
                Text(name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let role, !role.isEmpty {
                    Text(role).font(.system(size: 19)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            .frame(width: size + 20)
        }
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}

/// Focus style for borderless labels that draw their own focus (cast circles etc.).
struct BareFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - Episode card (400×225 still + frosted text platter on focus)

struct EpisodeCard: View {
    let video: MetaVideo
    let showBackdrop: String?
    var progress: Double?
    var watched: Bool
    var spoiler: Bool
    var rating: Double?
    var cast: [String] = []
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: video.thumbnail, maxPixel: ImageSize.landscape, fallbackURL: showBackdrop)
                    .frame(width: 400, height: 225)
                    .blur(radius: spoiler && !PerformanceProfile.isConstrained ? 20 : 0)
                    .overlay(Color.black.opacity(spoiler && PerformanceProfile.isConstrained ? 0.55 : 0))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 6) {
                    if let countdown = video.airCountdownText {
                        BadgePill(text: countdown, systemImage: "calendar")
                    } else if let rt = video.runtime {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                        Text("\(rt)m").font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
                if let progress, progress > 0.01 {
                    ProgressBar(fraction: progress, height: 5).padding(.horizontal, 10).padding(.bottom, 6)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: 400, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if watched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28))
                        .symbolRenderingMode(.palette).foregroundStyle(Palette.focusInk, .white).padding(10)
                }
            }
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.4 : 0),
                    radius: PerformanceProfile.isConstrained ? 0 : 18,
                    y: PerformanceProfile.isConstrained ? 0 : 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("Episode \(video.episode ?? 0)").eyebrow()
                Text(video.title.isEmpty ? "Episode \(video.episode ?? 0)" : video.title)
                    .textStyle(.cardTitle).lineLimit(1)
                Text(spoiler ? "Spoiler hidden" : (video.overview ?? ""))
                    .textStyle(.cardBody)
                    .lineLimit(focused ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if focused, !cast.isEmpty {
                    Text("Cast: " + cast.joined(separator: ", ")).textStyle(.caption).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let aired = video.airedText { Text(aired).textStyle(.caption) }
                    if let rating { MetaLine(parts: [], rating: String(format: "%.1f", rating), style: .caption) }
                }
            }
            .padding(focused ? 14 : 0)
            .frame(width: 400, alignment: .leading)
            .background {
                if focused { GlassSurface(shape: RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous), raised: true) }
            }
        }
        .animation(Motion.focus, value: focused)
    }
}

// MARK: - Live channel tile

struct ChannelTile: View {
    let name: String
    let logo: String?
    var favorite = false
    var width: CGFloat = 300
    var height: CGFloat = 170
    var showsName = true
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ArtFieldMini(url: logo)
                if let logo {
                    RemoteImage(url: logo, maxPixel: PerformanceProfile.isConstrained ? 240 : 400, contentMode: .fit, placeholder: false)
                        .frame(maxWidth: width * 0.6, maxHeight: height * 0.6)
                } else {
                    Text(name).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                        .multilineTextAlignment(.center).padding()
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) { LivePill().padding(10) }
            .overlay(alignment: .topTrailing) {
                if favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(12) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
            if showsName {
                Text(name).textStyle(.cardTitle, color: focused ? .white : Palette.textSecondary).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
    }
}

/// A small art-field behind a logo (cheap; no live blur).
struct ArtFieldMini: View {
    let url: String?
    @State private var palette: ArtPalette?

    var body: some View {
        ZStack {
            Palette.glassSolid
            if !PerformanceProfile.isConstrained, let palette {
                LinearGradient(colors: palette.colors.prefix(3).map { $0.color }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.85)
            }
        }
        .allowsHitTesting(false)
        .task(id: url) {
            guard !PerformanceProfile.isConstrained, let url else { return }
            palette = await ArtPaletteCache.shared.palette(for: url)
        }
    }
}
