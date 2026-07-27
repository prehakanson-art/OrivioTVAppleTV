import SwiftUI

// Hulu theme — cards, hero, rails and genre buttons, ported from HuluTV. Sizes,
// spacing, fonts and the green-outline/lift focus language are HuluTV's 1:1; the
// accent (green in the original) is `theme.palette.secondary` so it follows the
// Color Theme, and the data is Orivio's `HuluTitle`.

/// A style of row on a page.
enum HuluRailStyle { case richTile, landscape, poster }

/// A titled horizontal row. `id` is STABLE (never a fresh UUID) so recomputing
/// rows on a parent re-render doesn't tear down + rebuild every rail.
struct HuluRail: Identifiable {
    let id: String
    let title: String
    let items: [HuluTitle]
    var style: HuluRailStyle = .landscape
}

// MARK: - Rich tall tile

struct HuluRichTile: View {
    let title: HuluTitle
    var width: CGFloat = 300
    var focus: FocusState<Bool>.Binding? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: title.posterURL ?? title.cardURL)
                    .frame(width: width, height: height)
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.92)],
                                            startPoint: .center, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.name)
                        .font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                    Text(title.metaLine)
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: width - 36, alignment: .leading)
                .padding(.bottom, 18)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .watchedBadge(title.meta)
            .huluFocusRing(focused, cornerRadius: 10, lineWidth: 5)
        }
        .buttonStyle(.huluFlat)
        .posterHoldMenu(ifAvailable: title.meta, onDetails: action)
        .focused($focused)
        .huluExternalFocus(focus)
        .focusLift(1.06, focused)
        .onChange(of: focused) { _, f in onFocusChanged?(f) }
        .padding(.vertical, 16)
    }
}

// MARK: - Landscape card

struct HuluLandscapeCard: View {
    let title: HuluTitle
    var width: CGFloat = 380
    var focus: FocusState<Bool>.Binding? = nil
    var onFocusChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    private var height: CGFloat { width * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                RemoteImage(url: title.cardURL, maxDimension: width)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .watchedBadge(title.meta)
                    .huluFocusRing(focused, cornerRadius: 8, lineWidth: 5)
            }
            .buttonStyle(.huluFlat)
            .posterHoldMenu(ifAvailable: title.meta, onDetails: action)
            .focused($focused)
            .huluExternalFocus(focus)
            .focusLift(1.05, focused)
            .onChange(of: focused) { _, f in onFocusChanged?(f) }

            VStack(alignment: .leading, spacing: 4) {
                Text(title.name).font(HuluStyle.title(24))
                    .foregroundStyle(focused ? .white : HuluStyle.textSecondary).lineLimit(1)
                Text(title.metaLine).font(HuluStyle.regular(19))
                    .foregroundStyle(HuluStyle.textTertiary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Ranked poster card

struct HuluPosterCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let title: HuluTitle
    var rank: Int? = nil
    var width: CGFloat = 220
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
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let rank {
                            Text("\(rank)")
                                .font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(theme.palette.secondary.opacity(0.9))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
                    .watchedBadge(title.meta)
                    .huluFocusRing(focused, cornerRadius: 8, lineWidth: 5)
            }
            .huluCardStyle(parallax)
            .posterHoldMenu(ifAvailable: title.meta, onDetails: action)
            .focused($focused)
            .huluExternalFocus(focus)
            // Native platter supplies the lift; only add the manual scale when off.
            .focusLift(1.07, !parallax && focused)
            .onChange(of: focused) { _, f in onFocusChanged?(f) }

            Text(title.name).font(HuluStyle.medium(20))
                .foregroundStyle(focused ? .white : HuluStyle.textTertiary)
                .lineLimit(1).frame(width: width, alignment: .leading)
                .opacity(focused ? 1 : 0)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Progress card (Continue Watching / My Stuff)

struct HuluProgressCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let title: HuluTitle
    var label: String
    var subtitle: String
    var progress: Double = 0.4
    var badge: String? = nil
    var width: CGFloat = 420
    let action: () -> Void

    @FocusState private var focused: Bool
    private var height: CGFloat { width * 9 / 16 }
    private var parallax: Bool { perf.cardParallaxEffective }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                RemoteImage(url: title.cardURL, maxDimension: width)
                    .frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: 5)).padding(10)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if progress > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.3))
                                    Rectangle().fill(theme.palette.secondary).frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .huluFocusRing(focused, cornerRadius: 8, lineWidth: 5)
            }
            .huluCardStyle(parallax)
            .focused($focused)
            .focusLift(1.05, !parallax && focused)

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(HuluStyle.semibold(16))
                    .foregroundStyle(HuluStyle.textTertiary).tracking(1)
                Text(subtitle).font(HuluStyle.title(22))
                    .foregroundStyle(focused ? .white : HuluStyle.textSecondary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Rails

struct HuluContentRail: View {
    let rail: HuluRail
    var onSelect: (HuluTitle) -> Void
    /// Back mid-row jumps to the first card; Back at the first card calls this
    /// (opens the side menu) — the universal row-navigation behavior.
    var onBackAtStart: () -> Void = {}

    @State private var focusedID: String?
    @State private var centerWork: DispatchWorkItem?
    @FocusState private var rowFirst: Bool

    private var firstID: String? { rail.items.first?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rail.title).font(HuluStyle.title(26)).foregroundStyle(.white)
                .tracking(0.5).padding(.leading, HuluStyle.side)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: rail.style == .richTile ? 22 : 26) {
                        ForEach(Array(rail.items.enumerated()), id: \.element.id) { idx, item in
                            let isFirst = item.id == firstID
                            let onFC: (Bool) -> Void = { g in
                                if g { focusedID = item.id } else if focusedID == item.id { focusedID = nil }
                            }
                            Group {
                                switch rail.style {
                                case .richTile:
                                    HuluRichTile(title: item, focus: isFirst ? $rowFirst : nil,
                                                 onFocusChanged: onFC) { onSelect(item) }
                                case .landscape:
                                    HuluLandscapeCard(title: item, focus: isFirst ? $rowFirst : nil,
                                                      onFocusChanged: onFC) { onSelect(item) }
                                case .poster:
                                    HuluPosterCard(title: item, rank: idx + 1,
                                                   focus: isFirst ? $rowFirst : nil,
                                                   onFocusChanged: onFC) { onSelect(item) }
                                }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, HuluStyle.side)
                }
                .scrollClipDisabled()
                // Keep the focused card centered — but DEBOUNCED. A fast touch /
                // rotational ("iPod") scroll fires focus changes in quick bursts;
                // centering each one stacks competing scroll animations that move
                // the content mid-input, which throws off tvOS's focus geometry
                // and makes the row skip cards. Waiting for the scroll to settle
                // (and letting tvOS keep focus visible meanwhile) centers cleanly.
                .onChange(of: focusedID) { _, id in
                    centerWork?.cancel()
                    guard let id else { return }
                    let work = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    centerWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
                }
                .onExitCommand {
                    if let f = focusedID, f != firstID { rowFirst = true }
                    else { onBackAtStart() }
                }
            }
        }
    }
}

// MARK: - Genre buttons

struct HuluGenreButtons: View {
    let genres: [String]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GENRES").font(HuluStyle.title(26)).foregroundStyle(.white).padding(.leading, HuluStyle.side)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 26) {
                    ForEach(genres, id: \.self) { g in
                        HuluGenreButton(name: g.uppercased()) { onSelect(g) }
                    }
                }
                .padding(.horizontal, HuluStyle.side).padding(.vertical, 8)
            }
            .scrollClipDisabled()
        }
    }
}

private struct HuluGenreButton: View {
    let name: String
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(name).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                .frame(width: 440, height: 96)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HuluStyle.surface))
                .huluFocusRing(focused, cornerRadius: 10, lineWidth: 4)
        }
        .buttonStyle(.huluFlat)
        .focused($focused)
        .focusLift(1.03, focused)
    }
}

// MARK: - Featured hero

struct HuluFeaturedHero: View {
    @EnvironmentObject private var theme: ThemeManager
    let items: [HuluTitle]
    var onPlay: (HuluTitle) -> Void
    var onDetails: (HuluTitle) -> Void
    var playFocus: FocusState<Bool>.Binding? = nil

    @State private var index = 0
    @State private var lastManual = Date.distantPast
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var current: HuluTitle? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let t = current {
                RemoteImage(url: t.backdropURL)
                    .frame(height: 780)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .clipped()
                    .overlay(HuluStyle.heroScrim)
                    .id(t.id)
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 20) {
                    if !t.isPlaceholder {
                        Text(t.tagline.isEmpty ? "NOW STREAMING" : t.tagline)
                            .font(HuluStyle.semibold(22)).tracking(1).foregroundStyle(.white)

                        HuluTitleArt(title: t, maxHeight: 150)

                        if t.isSeries && !t.episodeLine.isEmpty {
                            Text(t.episodeLine).font(HuluStyle.semibold(26))
                                .foregroundStyle(theme.palette.secondary)
                        }

                        if !t.overview.isEmpty {
                            Text(t.overview).font(HuluStyle.regular(24)).foregroundStyle(.white)
                                .lineLimit(3).frame(maxWidth: 720, alignment: .leading)
                        }
                    }

                    HStack(spacing: 22) {
                        HuluHeroButton(text: "PLAY", icon: "play.fill", filled: true,
                                       playFocus: playFocus) { onPlay(t) }
                        HuluHeroButton(text: "DETAILS", icon: "arrow.right", filled: false) { onDetails(t) }
                    }
                    .padding(.top, 6)

                    if !t.isPlaceholder && items.count > 1 {
                        HuluCarouselDots(count: items.count, index: $index) { lastManual = Date() }
                            .padding(.top, 8)
                    }
                }
                .padding(.leading, HuluStyle.side)
                .padding(.bottom, 56)
            } else {
                Color.clear.frame(height: 780).frame(maxWidth: .infinity)
            }
        }
        .onReceive(timer) { _ in
            guard items.count > 1, Date().timeIntervalSince(lastManual) > 10 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
        }
    }
}

struct HuluTitleArt: View {
    let title: HuluTitle
    var maxHeight: CGFloat = 150
    var body: some View {
        if let url = title.logoURL {
            RemoteImage(url: url, contentMode: .fit, alignment: .bottomLeading)
                .frame(maxWidth: 620, maxHeight: maxHeight, alignment: .leading)
        } else {
            Text(title.name).font(.system(size: 60, weight: .heavy))
                .foregroundStyle(.white).lineLimit(2)
                .frame(maxWidth: 700, alignment: .leading)
        }
    }
}

struct HuluHeroButton: View {
    @EnvironmentObject private var theme: ThemeManager
    let text: String
    let icon: String
    let filled: Bool
    var playFocus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                Text(text).font(.system(size: 26, weight: .bold))
            }
            .foregroundStyle(filled ? .black : .white)
            .padding(.horizontal, 40).padding(.vertical, 20)
            .background(filled ? AnyShapeStyle(Color.white)
                               : AnyShapeStyle(Color.white.opacity(focused ? 0.28 : 0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(theme.palette.secondary, lineWidth: focused ? 4 : 0))
        }
        .buttonStyle(.huluFlat)
        .focused($focused)
        .huluExternalFocus(playFocus)
        .focusLift(1.05, focused)
    }
}

struct HuluCarouselDots: View {
    @EnvironmentObject private var theme: ThemeManager
    let count: Int
    @Binding var index: Int
    var onScrub: () -> Void
    @FocusState private var focusedDot: Int?

    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<count, id: \.self) { i in
                Button { index = i; onScrub() } label: {
                    Capsule()
                        .fill(i == index ? theme.palette.secondary : Color.white.opacity(0.35))
                        .frame(width: i == index ? 28 : 12, height: 12)
                        .scaleEffect(focusedDot == i ? 1.4 : 1)
                        .padding(8)
                }
                .buttonStyle(.huluFlat)
                .focused($focusedDot, equals: i)
            }
        }
        .animation(.easeOut(duration: 0.18), value: index)
        .animation(.easeOut(duration: 0.18), value: focusedDot)
        .onChange(of: focusedDot) { _, f in if let f, f != index { index = f; onScrub() } }
    }
}
