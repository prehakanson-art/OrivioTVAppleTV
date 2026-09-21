import SwiftUI

/// Fusion's inline hero bar (§21): a wide, self-contained cinematic module that
/// sits between Home rows — "a panoramic window into its featured content"
/// rather than a flat banner. Panoramic artwork fills the whole card; a left
/// text column (eyebrow, title/logo, metadata, two-line synopsis, Play +
/// Details) reads over a protection gradient; pagination dots track the
/// auto-rotation. Fusion-only.
struct FusionHeroBar: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.colorScheme) private var scheme

    /// Rotation set (3–10 titles). Each should have backdrop art.
    let items: [MetaItem]
    /// Eyebrow label above the title (source / category).
    var eyebrow: String = "Featured"
    var height: CGFloat = 340
    let onPlay: (MetaItem) -> Void
    let onDetails: (MetaItem) -> Void

    @State private var index = 0
    @State private var playFocused = false
    @State private var lastInteraction = Date()
    /// When the bar last advanced — so each title dwells for a readable beat
    /// instead of flipping on every timer tick.
    @State private var lastRotation = Date.distantPast
    /// False while Home is covered (player cover, pushed screen, other tab) —
    /// the bar stays mounted there, and rotating unseen means decoding a fresh
    /// wide backdrop every 9s during playback on the 2–3 GB boxes.
    @State private var isVisible = true
    @State private var contentRating: String?

    /// Seconds each hero title stays up before auto-advancing.
    private let dwellSeconds: TimeInterval = 9
    // Idle tick for auto-rotation — the dwell gate below does the real pacing,
    // so 2s granularity on a 9s dwell is plenty. `.default`, NOT `.common`:
    // common-mode timers fire inside the run-loop tracking mode focus/scroll
    // animations run in, waking SwiftUI mid-scroll on the A8 for a check that
    // is never urgent.
    private let tick = Timer.publish(every: 2, on: .main, in: .default).autoconnect()

    /// Near-black graphite used by the left readability scrim (§4.3).
    private static let scrim = Color(hex: 0x06080A)

    private var focusedInside: Bool { playFocused }
    private var current: MetaItem? { items.indices.contains(index) ? items[index] : nil }
    private var radius: CGFloat { FusionRadius.heroBar(homeCatalogSettings.posterCornerRadius) }

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
        .frame(height: height)
        .padding(.horizontal, OrivioSpacing.huge)
        .padding(.vertical, OrivioSpacing.sm)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        // The item list changes whenever Home reloads (cached → live rows, a
        // layout change, a sync). An index past the new end rendered a blank
        // card with a dead "Go to Movie" button until the next rotation.
        .onChange(of: items.map(\.id)) { _, _ in
            if !items.indices.contains(index) { index = 0 }
        }
        .onReceive(tick) { _ in rotateIfIdle() }
        .contentRating(for: current, into: $contentRating)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Panoramic artwork — the subject reads on the right, text on the left.
            if let art = current?.background ?? current?.poster {
                RemoteImage(url: art, alignment: .trailing, maxPixels: PerformanceProfile.backdropPixelCap)
                    .frame(width: width, height: height)
                    .clipped()
                    // §21.2 dim: unfocused bar sits slightly dark, lifting on
                    // focus. Was `.brightness()` — a color-matrix filter, i.e.
                    // an offscreen pass over the near-full-width bar that gets
                    // recomposited on every Home scroll frame. A flat black
                    // overlay is a plain alpha composite with the same read
                    // (cf. PosterCard's unfocused dim); nothing draws focused.
                    .overlay(Color.black.opacity(focusedInside ? 0 : 0.10))
                    // REQUIRED, not cosmetic. RemoteImage fills its frame, so
                    // this view overflows the box it is visually clipped to and
                    // stayed hit-testable across the Continue Watching row above
                    // it. On tvOS focus is NOT hit-tested but context menus ARE,
                    // so focus, Select and Play/Pause all worked on those cards
                    // while hold-Select never opened their menu. Bisected on
                    // device: the menu returns the moment this artwork is
                    // absent, shrunk, or taken out of hit testing.
                    .allowsHitTesting(false)
            } else {
                theme.palette.backgroundCard
            }

            // §4.3 left readability gradient — near-opaque on the left, fully
            // clear by ~84%, so the subject on the right reads while the text
            // sits on darkness. Uses a near-black graphite so text is crisp.
            LinearGradient(
                stops: [
                    .init(color: Self.scrim.opacity(0.98), location: 0),
                    .init(color: Self.scrim.opacity(0.91), location: 0.22),
                    .init(color: Self.scrim.opacity(0.68), location: 0.42),
                    .init(color: Self.scrim.opacity(0.25), location: 0.66),
                    .init(color: .clear, location: 0.84)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            // §4.3 bottom content gradient.
            LinearGradient(
                stops: [
                    .init(color: theme.palette.background, location: 0),
                    .init(color: theme.palette.background.opacity(0.66), location: 0.34),
                    .init(color: .clear, location: 0.68)
                ],
                startPoint: .bottom, endPoint: .top
            )

            textColumn(width: width)

            paginationDots
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, OrivioSpacing.xl + OrivioSpacing.lg)
                .padding(.bottom, OrivioSpacing.md)

        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // Focus: an accent-colored edge (the user's chosen accent, like every
        // other card's ring) + accent glow. The edge does NOT ride the Card
        // Shadows perf switch (the glow below does), so the bar always reads
        // as clearly focused even on the low tier where shadows are off.
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focusedInside ? theme.palette.focusRing : .clear, lineWidth: focusedInside ? 5 : 0)
        )
        // Both shadows ride the Card Shadows switch: a resting radius-18 blur
        // under a near-full-width bar is an offscreen pass recomposited on every
        // Home scroll frame — one of the costlier static layers on the A8 tier,
        // where the switch defaults off.
        .shadow(color: perf.settings.cardShadows
                    ? .black.opacity(focusedInside ? 0.5 : 0.28) : .clear,
                radius: perf.settings.cardShadows ? (focusedInside ? 34 : 18) : 0,
                y: focusedInside ? 16 : 8)
        .focusLift(OrivioFocus.card, focusedInside)
        .offset(y: focusedInside ? -8 : 0)
        .animation(FusionMotion.focusEntry, value: focusedInside)
    }

    @ViewBuilder
    private func textColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            Spacer(minLength: 0)

            Text(eyebrow.uppercased())
                .font(FusionType.badge(theme.font))
                .tracking(2)
                .foregroundStyle(theme.palette.secondary)

            // Title logo when available, else a bold text title.
            if let logo = current?.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading, maxDimension: 360)
                    .frame(width: 360, height: 96)
                    .shadow(color: .black.opacity(scheme == .light ? 0.25 : 0.45), radius: 10, y: 4)
            } else if let name = current?.name {
                Text(name)
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
            }

            if let item = current { metaLine(item) }

            if let synopsis = current?.description, !synopsis.isEmpty {
                Text(synopsis)
                    .font(FusionType.metadata(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: width * 0.42, alignment: .leading)
            }

            buttons

            Spacer(minLength: 0)
        }
        .padding(.leading, OrivioSpacing.xl)
        .padding(.trailing, OrivioSpacing.lg)
        .frame(width: width * 0.5, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metaLine(_ item: MetaItem) -> some View {
        let segments = [contentRating, item.year, item.genres?.first, item.runtimeFormatted].compactMap { $0 }
        HStack(spacing: OrivioSpacing.sm) {
            if let rating = item.imdbRating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 14, weight: .bold))
                    Text(rating).font(.system(size: 19, weight: .bold))
                }
                .foregroundStyle(OrivioPrimitives.success)
                if !segments.isEmpty { MetaDot() }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                if i > 0 { MetaDot() }
                MetaDotText(seg)
            }
        }
    }

    /// -1 / 1 while an invisible stepping sentinel beside the button holds
    /// focus for a beat. NOT `.onMoveCommand` — that swallows EVERY direction
    /// on the focused view, so Down could never leave the bar for the rows.
    @FocusState private var stepFocus: Int?
    @FocusState private var playButtonFocus: Bool
    @Environment(\.railIsHidden) private var railIsHidden

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 0) {
            // Dropped while the rail is auto-hidden, exactly like the top
            // hero's sentinel: LEFT must find no candidate here so the failed
            // move bubbles up and summons the rail. With the sentinel always
            // present, Left from the Featured bar stepped the carousel forever
            // and the hidden rail was unreachable from this row.
            if !railIsHidden {
                Color.clear.frame(width: 1, height: 40)
                    .focusable()
                    .focused($stepFocus, equals: -1)
            }
            // One primary action, matching the reference — opens the title's
            // page. Labelled by TYPE: "Go to Show" on a series read wrong as
            // "Go to Movie". (The top hero keeps its own labelling.)
            Button { if let c = current { onPlay(c) } } label: {
                Label(current?.isSeries == true ? "Go to Show" : "Go to Movie",
                      systemImage: "play.fill")
            }
            .buttonStyle(FusionHeroBarButtonStyle(prominent: true))
            .focused($playButtonFocus)
            // NOT `.onFocusChange`: `\.isFocused` only resolves INSIDE the
            // Button, so on the wrapper it never fired — the bar showed no
            // focus ring, and kept auto-rotating under a focused button.
            .onChange(of: playButtonFocus) { _, focused in
                playFocused = focused
                if focused {
                    lastInteraction = Date()
                    ContentFocusRouter.shared.noteFocused(row: "hero")
                }
            }
            // Coming back out of the rail lands on this button when the bar
            // was where the viewer left (ContentFocusRouter).
            .onAppear {
                ContentFocusRouter.shared.register("hero") {
                    playButtonFocus = true
                    DispatchQueue.main.async { if !playButtonFocus { playButtonFocus = true } }
                    return true
                }
            }
            .onDisappear { ContentFocusRouter.shared.unregister("hero") }
            Color.clear.frame(width: 1, height: 40)
                .focusable()
                .focused($stepFocus, equals: 1)
        }
        .onChange(of: stepFocus) { _, step in
            guard let step else { return }
            advance(by: step)
            stepFocus = nil
            playButtonFocus = true
        }
        .padding(.top, OrivioSpacing.xs)
    }


    @ViewBuilder
    private var paginationDots: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? theme.palette.secondary : Color.white.opacity(0.35))
                        .frame(width: i == index ? 24 : 7, height: 7)
                        .animation(FusionMotion.focusEntry, value: index)
                }
            }
        }
    }

    private func rotateIfIdle() {
        let now = Date()
        // §55: Reduce Motion disables automatic rotation (manual chevrons stay).
        guard isVisible, !perf.reduceMotion, items.count > 1, !focusedInside,
              now.timeIntervalSince(lastInteraction) > 6,
              now.timeIntervalSince(lastRotation) >= dwellSeconds else { return }
        lastRotation = now
        advance(by: 1)
    }

    /// Manual / auto step through the hero titles (wraps).
    private func advance(by delta: Int) {
        // `% 0` traps, and the sentinel focus path that reaches here does not
        // itself check `items.count` (only rotateIfIdle and the dots do), so an
        // empty bar could crash on a stray focus change.
        guard !items.isEmpty else { return }
        lastInteraction = Date()
        let fade = perf.heroCrossfadeEffective
        withAnimation(fade ? FusionMotion.heroSlide : nil) {
            index = (index + delta + items.count) % items.count
        }
    }
}

/// §18 circular frosted-glass chevron for manual hero navigation.
private struct FusionChevronStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }
    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle().fill(Color.white.opacity(isFocused ? 0.24 : 0.12))
                )
                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0.9 : 0.15), lineWidth: isFocused ? 2 : 1))
                .opacity(isFocused ? 1 : 0.55)
                .focusLift(OrivioFocus.control, isFocused)
                .cardPressDip(configuration.isPressed)
        }
    }
}

/// Play / Details buttons inside the Fusion hero bar. Prominent = accent fill;
/// secondary = translucent glass. Lifts on focus.
private struct FusionHeroBarButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, prominent: prominent)
    }

    private struct Chrome: View {
        @EnvironmentObject private var theme: ThemeManager
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let prominent: Bool

        private var fill: Color {
            if prominent { return isFocused ? theme.palette.focusRing : theme.palette.secondary }
            return isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.16)
        }
        private var textColor: Color {
            if prominent { return theme.palette.onSecondary }
            return isFocused ? Color(hex: 0x15171A) : theme.palette.textPrimary
        }

        var body: some View {
            configuration.label
                .font(FusionType.button(theme.font))
                .foregroundStyle(textColor)
                .padding(.horizontal, OrivioSpacing.lg)
                .padding(.vertical, OrivioSpacing.sm)
                .background(Capsule().fill(fill))
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: isFocused ? 14 : 0, y: 6)
                .focusLift(OrivioFocus.card, isFocused)
                .cardPressDip(configuration.isPressed)
        }
    }
}
