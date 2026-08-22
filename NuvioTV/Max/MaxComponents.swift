import SwiftUI

// Max theme — cards, rails and the featured hero, ported from MaxTV's
// ContentRail / PosterCard / FeaturedHero. Sizes, spacing, fonts and focus
// treatments are MaxTV's 1:1. Two deliberate changes: it draws Orivio's
// `RemoteImage` (String URLs) and `MaxTitle` data, and — per request — the rail
// posters are PORTRAIT that expand into a LANDSCAPE card when highlighted.

enum MaxLayout {
    static let railInset: CGFloat = MaxStyle.side   // 130 — the "stopping point"
    static let posterW: CGFloat = 210
    static let posterH: CGFloat = 315
    static let landscapeW: CGFloat = 560            // 16:9 of the poster height
    static let cardRadius: CGFloat = 6
    static let border: CGFloat = 4
    static let heroHeight: CGFloat = 760
    // Row reflow on focus uses the shared `View.focusExpand` / `FusionMotion.rowExpand`.
}

// MARK: - Poster rail (portrait → landscape on focus)

/// A titled horizontal row of posters. Each poster is portrait at rest and grows
/// into a landscape card when focused, the row reflowing to make room.
struct MaxPosterRail: View {
    let title: String
    let items: [MaxTitle]
    var onSelect: (MaxTitle) -> Void
    /// When set, the FIRST card adopts this focus binding so a parent (the hero's
    /// Down press) can drop focus onto the row.
    var firstCardFocus: FocusState<Bool>.Binding? = nil
    /// Called when Back is pressed while a card past the first is focused → the
    /// row jumps to its first card; at the first card the parent opens the menu.
    var onBackAtStart: () -> Void = {}

    @State private var focusedID: String?
    @State private var centerWork: DispatchWorkItem?
    @FocusState private var rowFirst: Bool

    /// The binding the first card uses — the parent's (hero-down) when supplied,
    /// otherwise the row's own, so both Down-into-row and Back-to-start focus it.
    private var firstFocus: FocusState<Bool>.Binding { firstCardFocus ?? $rowFirst }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MaxStyle.title(30))
                .foregroundStyle(.white)
                .padding(.leading, MaxLayout.railInset)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 20) {
                        ForEach(items) { item in
                            MaxPosterCard(
                                title: item,
                                externalFocus: item.id == items.first?.id ? firstFocus : nil,
                                onSelect: { onSelect(item) },
                                onFocusChanged: { gained in
                                    if gained { focusedID = item.id }
                                    else if focusedID == item.id { focusedID = nil }
                                }
                            )
                            .zIndex(focusedID == item.id ? 10 : 0)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, MaxLayout.railInset)
                    .padding(.vertical, 16)
                    .focusExpand(focusedID)
                }
                .scrollClipDisabled()
                // Keep the focused card centered as you scroll (so the expanding
                // landscape card never runs off the edge) — but DEBOUNCED: a fast
                // touch / rotational ("iPod") scroll fires focus changes in bursts,
                // and centering each one stacks competing scroll animations that
                // move the content mid-input, throwing off tvOS's focus geometry
                // so the row skips cards. Waiting for the scroll to settle centers
                // cleanly (tvOS keeps focus visible meanwhile). Clamps at the ends.
                .onChange(of: focusedID) { _, id in
                    centerWork?.cancel()
                    guard let id else { return }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    centerWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
                }
                // Back mid-row jumps to the first card; Back at the first card
                // opens the side menu (matches the other Orivio themes).
                .onExitCommand {
                    if let f = focusedID, f != items.first?.id { firstFocus.wrappedValue = true }
                    else { onBackAtStart() }
                }
            }
        }
    }
}

/// The morphing poster: portrait art at rest, a 560pt landscape card on focus.
/// White border is the focus signal (Max's flat highlight); the title name fades
/// in beneath, its space always reserved so the row never jumps vertically.
/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged cards instead of rebuilding
/// every card in the row. Same gate the classic home's HomePosterCell uses;
/// focus visuals and store changes invalidate through their own dependencies,
/// which bypass ==.
struct MaxPosterCard: View, Equatable {
    // NOTE: no LibraryStore here — the hold menu (MaxCardMenu) owns that
    // subscription. Declaring it on the card subscribed every card's body to
    // the store, so they all rebuilt on any library change, for nothing.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title }

    @EnvironmentObject private var watched: WatchedStore
    let title: MaxTitle
    var externalFocus: FocusState<Bool>.Binding? = nil
    let onSelect: () -> Void
    let onFocusChanged: (Bool) -> Void
    @State private var held = false
    @State private var focused = false

    private var expanded: Bool { focused || held }

    var body: some View {
        // A PORTRAIT focusable button (keeps vertical focus in a stable column —
        // Up/Down go straight to the poster above/below) sits beside an EMPTY,
        // non-focusable spacer that widens when focused. The spacer is what
        // pushes the neighbouring cards aside; the landscape art then expands
        // into that reserved gap (drawn over the empty spacer, NOT under the
        // next card).
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) {
                // Focus is read INSIDE the label (`@Environment(\.isFocused)`),
                // which reflects the button's own focus; it reports back up so the
                // spacer can reserve the reflow gap.
                MaxPosterLabel(title: title, isWatched: title.meta.map(watched.isWatched) ?? false,
                               held: held, onFocusChanged: { gained in
                    focused = gained
                    if gained { held = false }
                    onFocusChanged(gained)
                })
            }
            .buttonStyle(.maxFlat)
            .maxExternalFocus(externalFocus)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in held = true })
            .contextMenu { MaxCardMenu(title: title, onSelect: onSelect) }
            .zIndex(1)

            // Reserved gap that pushes the following cards to the side.
            Color.clear
                .frame(width: expanded ? (MaxLayout.landscapeW - MaxLayout.posterW) : 0,
                       height: MaxLayout.posterH)
        }
        .focusExpand(expanded)
    }
}

private struct MaxPosterLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: MaxTitle
    let isWatched: Bool
    var held: Bool = false
    let onFocusChanged: (Bool) -> Void

    private var expanded: Bool { isFocused || held }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteImage(url: title.posterURL ?? title.cardURL, maxDimension: MaxLayout.posterH)
                .frame(width: MaxLayout.posterW, height: MaxLayout.posterH)
                .clipShape(RoundedRectangle(cornerRadius: MaxLayout.cardRadius))
                .overlay(alignment: .topLeading) { MaxCardBadge(badge: title.badge) }
                .overlay(alignment: .bottom) {
                    if let f = title.progress { MaxProgressBar(fraction: f) }
                }
                .overlay(alignment: .topTrailing) {
                    if isWatched && !title.isSeries { MaxWatchedBadge() }
                }
                // The landscape art expands to the right into the reserved gap.
                .overlay(alignment: .topLeading) {
                    if expanded {
                        MaxLandscapeArt(url: title.cardURL, logo: title.logoURL,
                                        name: title.name, progress: title.progress)
                            .frame(width: MaxLayout.landscapeW, height: MaxLayout.posterH,
                                   alignment: .topLeading)
                            .transition(.opacity)
                    }
                }
                // The button's focus frame stays PORTRAIT (the overlay overflows
                // without enlarging it), so vertical navigation doesn't drift.
                .frame(width: MaxLayout.posterW, height: MaxLayout.posterH, alignment: .topLeading)
                .animation(.easeOut(duration: 0.18), value: expanded)

            MaxCardTitle(name: title.name, focused: expanded, width: MaxLayout.posterW)
        }
        .padding(.vertical, 10)
        .onChange(of: isFocused) { _, v in onFocusChanged(v) }
    }
}

/// The 560pt landscape art shown when a poster is focused: backdrop + a bottom
/// scrim + logo (or title) + optional progress, with the white focus border.
private struct MaxLandscapeArt: View {
    let url: String?
    let logo: String?
    let name: String
    var progress: Double? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: url, maxDimension: MaxLayout.landscapeW)
                .frame(width: MaxLayout.landscapeW, height: MaxLayout.posterH)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            if let logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                    .frame(width: 250, height: 78, alignment: .bottomLeading)
                    .padding(22)
            } else {
                Text(name)
                    .font(MaxStyle.title(30)).foregroundStyle(.white)
                    .lineLimit(2).padding(22)
            }
        }
        .frame(width: MaxLayout.landscapeW, height: MaxLayout.posterH)
        .clipShape(RoundedRectangle(cornerRadius: MaxLayout.cardRadius))
        .overlay(alignment: .bottom) { if let progress { MaxProgressBar(fraction: progress) } }
        .overlay(RoundedRectangle(cornerRadius: MaxLayout.cardRadius).stroke(.white, lineWidth: MaxLayout.border))
    }
}

// MARK: - Plain portrait card (grids + Top 10) and landscape card

/// A plain 2:3 poster — white border + scale on focus, title fades in below.
/// Used in grids (Search / My Stuff / Categories) and behind the Top 10 numerals.
/// Equatable for the same reason as MaxPosterCard.
struct MaxPortraitCard: View, Equatable {
    // No store subscriptions: this card reads neither, and holding them made
    // every instance rebuild whenever either store published (every sync pull,
    // every playback save). MaxCardMenu owns them where they are used.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.width == rhs.width
    }

    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let title: MaxTitle
    var width: CGFloat = 210
    var focus: FocusState<Bool>.Binding? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    private var height: CGFloat { width * 3 / 2 }
    private var parallax: Bool { perf.cardParallaxEffective }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                RemoteImage(url: title.posterURL ?? title.cardURL, maxDimension: height)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: MaxLayout.cardRadius))
                    .overlay(alignment: .topLeading) { MaxCardBadge(badge: title.badge, fontSize: 15) }
                    .overlay(RoundedRectangle(cornerRadius: MaxLayout.cardRadius)
                        .stroke(.white, lineWidth: focused ? MaxLayout.border : 0))
            }
            .maxCardStyle(parallax)
            .focused($focused)
            .maxExternalFocus(focus)
            // Native platter supplies the lift; only add the manual scale when off.
            .focusLift(1.08, !parallax && focused)
            .contextMenu { MaxCardMenu(title: title, onSelect: action) }
            .onChange(of: focused) { _, f in onFocusChanged?(f) }

            MaxCardTitle(name: title.name, focused: focused, width: width)
        }
        .padding(.vertical, 10)
    }
}

/// A 2:3 poster that FILLS its grid column (no fixed width), so a LazyVGrid never
/// overflows and overlaps its neighbours regardless of column count / area width.
/// Used in every grid (Search / My Stuff / Categories / hub genre lists).
/// Equatable for the same reason as MaxPosterCard.
struct MaxGridCard: View, Equatable {
    // No store subscriptions: this card reads neither, and holding them made
    // every instance rebuild whenever either store published (every sync pull,
    // every playback save). MaxCardMenu owns them where they are used.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title }

    let title: MaxTitle
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                RemoteImage(url: title.posterURL ?? title.cardURL, maxDimension: MaxLayout.posterH)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: MaxLayout.cardRadius))
                    .overlay(alignment: .topLeading) { MaxCardBadge(badge: title.badge, fontSize: 15) }
                    .overlay(RoundedRectangle(cornerRadius: MaxLayout.cardRadius)
                        .stroke(.white, lineWidth: focused ? MaxLayout.border : 0))
            }
            .buttonStyle(.maxFlat)
            .focused($focused)
            .maxExternalFocus(focus)
            .focusLift(1.06, focused)
            .contextMenu { MaxCardMenu(title: title, onSelect: action) }

            Text(title.name)
                .font(MaxStyle.semibold(20))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(focused ? 1 : 0)
                .frame(height: 28)
        }
        .padding(.vertical, 10)
    }
}


// MARK: - Top 10 row (ported from MaxTV ContentRail.Top10Row)

struct MaxTop10Row: View {
    let kind: String
    let items: [MaxTitle]
    var onSelect: (MaxTitle) -> Void
    var onBackAtStart: () -> Void = {}

    @State private var focusedID: String?
    @State private var centerWork: DispatchWorkItem?
    @FocusState private var firstCard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 16) {
                Text("TOP 10")
                    .font(.system(size: 64, weight: .black))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0x8A8A92)],
                                                    startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: -8) {
                    Text(kind).font(.system(size: 24, weight: .semibold)).tracking(6)
                    Text("TODAY").font(.system(size: 24, weight: .semibold)).tracking(6)
                }
                .foregroundStyle(.white)
            }
            .padding(.leading, MaxLayout.railInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: -30) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 190, weight: .black))
                                    .foregroundStyle(LinearGradient(
                                        colors: [Color(hex: 0x3A3A40), Color(hex: 0x101014)],
                                        startPoint: .top, endPoint: .bottom))
                                    .frame(width: idx == 9 ? 260 : 150, alignment: .leading)
                                MaxPortraitCard(title: item, width: 200,
                                                focus: item.id == items.first?.id ? $firstCard : nil,
                                                onFocusChanged: { if $0 { focusedID = item.id } }) { onSelect(item) }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, MaxLayout.railInset)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
                // Centered-on-focus, DEBOUNCED so a fast touch/rotational scroll
                // settles before we animate (otherwise stacked scroll animations
                // make the row skip cards). Clamped at the ends.
                .onChange(of: focusedID) { _, id in
                    centerWork?.cancel()
                    guard let id else { return }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    centerWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
                }
                // Back → first card (scroll it in + focus it); from the first
                // card, bubble up to the parent (open the sidebar).
                .onExitCommand {
                    if let f = focusedID, f != items.first?.id {
                        if let first = items.first?.id {
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(first, anchor: .leading) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { firstCard = true }
                    } else {
                        onBackAtStart()
                    }
                }
            }
        }
    }
}

// MARK: - Card pieces

/// A white corner badge ("New Episode" / "Newly Added").
struct MaxCardBadge: View {
    let badge: MaxTitleBadge
    var fontSize: CGFloat = 17
    var body: some View {
        if let text = badge.text {
            Text(text)
                .font(MaxStyle.semibold(fontSize))
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(10)
        }
    }
}

/// The title name that fades in beneath a card while focused. Space reserved.
struct MaxCardTitle: View {
    let name: String
    let focused: Bool
    let width: CGFloat
    var body: some View {
        Text(name)
            .font(MaxStyle.semibold(22))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .opacity(focused ? 1 : 0)
            .frame(height: 30)
    }
}

/// The blue progress bar across a Continue Watching card's bottom. Taller than a
/// hairline so the remaining time reads at a glance when the card is highlighted.
struct MaxProgressBar: View {
    let fraction: Double
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.55)).frame(height: height)
                Rectangle().fill(MaxStyle.progress)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(fraction, 0), 1))), height: height)
            }
        }
        .frame(height: height)
    }
}

private struct MaxWatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(MaxStyle.check))
            .padding(10)
    }
}

/// The shared hold-menu for Max cards (Details / Library / Watched).
struct MaxCardMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    let title: MaxTitle
    let onSelect: () -> Void

    var body: some View {
        if let m = title.meta {
            Button { onSelect() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button { library.toggle(m) } label: {
                Label(library.contains(m) ? "Remove from Library" : "Add to Library",
                      systemImage: library.contains(m) ? "bookmark.slash" : "bookmark")
            }
            Button { watched.toggleMovie(m) } label: {
                Label(watched.isWatched(m) ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: watched.isWatched(m) ? "eye.slash" : "checkmark.circle")
            }
        }
    }
}

// MARK: - Featured hero (ported from MaxTV FeaturedHero.swift)

struct MaxFeaturedHero: View {
    let items: [MaxTitle]
    /// Fired by the hero's single "Get Info" action.
    var onPlay: (MaxTitle) -> Void
    var defaultFocusNS: Namespace.ID? = nil
    var playFocus: FocusState<Bool>.Binding? = nil
    /// Pressing Down while the Play button is focused moves into the content.
    var onDown: () -> Void = {}

    @State private var index = 0
    @State private var lastManual = Date.distantPast
    @State private var contentRating: String?
    /// False while this hero is off screen, so its timer can't rotate (and
    /// repaint a full-screen backdrop) for a section nobody is looking at.
    @State private var isVisible = false
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    private let contentInset: CGFloat = MaxLayout.railInset

    private var current: MaxTitle? { items.indices.contains(index) ? items[index] : nil }

    /// Left/Right on the focused Play button steps through the featured titles.
    private func step(_ delta: Int) {
        guard items.count > 1 else { return }
        lastManual = Date()
        withAnimation(.easeInOut(duration: 0.4)) {
            index = (index + delta + items.count) % items.count
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let t = current {
                RemoteImage(url: t.backdropURL)
                    .frame(height: MaxLayout.heroHeight)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .clipped()
                    .overlay(MaxStyle.heroScrim)
                    .id(t.id)
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 22) {
                    if !t.isPlaceholder {
                        Text(t.brand)
                            .font(MaxStyle.semibold(20)).tracking(2)
                            .foregroundStyle(MaxStyle.textSecondary)

                        MaxTitleArt(title: t, maxHeight: 150)

                        Text(t.isSeries ? "New Season Streaming" : "New on Orivio")
                            .font(MaxStyle.semibold(24)).foregroundStyle(.white)

                        HStack(spacing: 16) {
                            Text(contentRating ?? t.maturity)
                            if t.isSeries { if !t.seasonsText.isEmpty { Text(t.seasonsText) } }
                            else { Text(t.year) }
                        }
                        .font(MaxStyle.medium(22)).foregroundStyle(MaxStyle.textSecondary)

                        if !t.overview.isEmpty {
                            Text(t.overview)
                                .font(MaxStyle.regular(24)).foregroundStyle(.white)
                                .lineLimit(2).frame(maxWidth: 720, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        MaxHeroPlayButton(icon: "info.circle", text: "Get Info",
                                          defaultFocusNS: defaultFocusNS, playFocus: playFocus,
                                          onLeft: { step(-1) }, onRight: { step(1) }, onDown: onDown) { onPlay(t) }
                    }
                    .padding(.top, 4)

                    if !t.isPlaceholder && items.count > 1 {
                        MaxDotsIndicator(count: items.count, index: index)
                            .padding(.top, 10)
                    }
                }
                .padding(.leading, contentInset)
                .padding(.bottom, 60)
            } else {
                Color.black.frame(height: MaxLayout.heroHeight).frame(maxWidth: .infinity)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(timer) { _ in
            // Gated like the Fusion hero: an auto-rotation crossfades a
            // FULL-SCREEN backdrop, so it must not run while this hero is off
            // screen (another tab/section is showing), and Reduce Motion turns
            // automatic rotation off entirely (§55). The fade itself follows the
            // hero-crossfade setting, which is off by default on the A8 and the
            // 3 GB 4K — there it swaps without recompositing a fade.
            guard isVisible, !perf.reduceMotion, items.count > 1,
                  Date().timeIntervalSince(lastManual) > 10 else { return }
            let fade = perf.heroCrossfadeEffective
            withAnimation(fade ? .easeInOut(duration: 0.6) : nil) {
                index = (index + 1) % items.count
            }
        }
        .contentRating(for: current?.meta, into: $contentRating)
    }
}

/// Non-focusable carousel indicator — the current title is a wider white pill,
/// the rest small dots. Not pressable; the hero is stepped via Play's Left/Right.
private struct MaxDotsIndicator: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: i == index ? 28 : 12, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.18), value: index)
        .allowsHitTesting(false)
    }
}

/// Title logo art when available, else a heavy text fallback.
struct MaxTitleArt: View {
    let title: MaxTitle
    var maxHeight: CGFloat = 150

    var body: some View {
        if let url = title.logoURL {
            RemoteImage(url: url, contentMode: .fit, alignment: .bottomLeading)
                .frame(maxWidth: 620, maxHeight: maxHeight, alignment: .leading)
        } else {
            Text(title.name.uppercased())
                .font(.system(size: 66, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 700, alignment: .leading)
        }
    }
}

struct MaxHeroPlayButton: View {
    var icon: String = "play.fill"
    let text: String
    var defaultFocusNS: Namespace.ID? = nil
    var playFocus: FocusState<Bool>.Binding? = nil
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onDown: () -> Void = {}
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 26))
                Text(text).font(MaxStyle.semibold(28))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 44).padding(.vertical, 20)
            .background(focused ? Color.white : Color.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.maxFlat)
        .focused($focused)
        .modifier(MaxOptionalFocus(binding: playFocus))
        .focusLift(1.05, focused)
        .modifier(MaxDefaultFocus(ns: defaultFocusNS))
        // While Play holds focus, Left/Right steps the featured carousel and
        // Down drops into the content (the dots aren't focusable). Up is a no-op
        // since the hero sits at the top of the page.
        .onMoveCommand { dir in
            switch dir {
            case .left: onLeft()
            case .right: onRight()
            case .down: onDown()
            default: break
            }
        }
    }
}

private struct MaxOptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}
private struct MaxDefaultFocus: ViewModifier {
    let ns: Namespace.ID?
    func body(content: Content) -> some View {
        if let ns { content.prefersDefaultFocus(in: ns) } else { content }
    }
}
