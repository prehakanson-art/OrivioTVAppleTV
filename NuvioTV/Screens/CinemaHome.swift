import SwiftUI

struct CinemaHomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var progressStore: ProgressStore
    @ObservedObject var viewModel: HomeViewModel

    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onResumeFromStart: (WatchProgress) -> Void
    let onPlayManually: (MetaItem, MetaVideo?) -> Void
    let onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void
    let onOpenCollection: (NuvioCollection) -> Void

    /// The focus-followed hero, ISOLATED from this view: cards report focus
    /// into it, only the hero subview observes it. Held as plain @State (not
    /// @StateObject / @ObservedObject) deliberately — the root must NOT
    /// subscribe, or every D-pad step would re-render the whole home (hero +
    /// every row) and decode a fresh full-screen backdrop per step: the
    /// "stepping through a row stutters" cost on the A8/A10X. HeroFocus also
    /// debounces the commit with a tier-aware settle window, exactly like the
    /// Classic home (see HeroFocus.settleNanos).
    @State private var hero = HeroFocus()
    /// Focus target for Back — the hero's own button.
    @FocusState private var heroFocused: Bool

    /// Rows, Continue Watching and the collections strip all come from the
    /// shared assembly on HomeViewModel — every theme derives them the same way.
    private var continueItems: [WatchProgress] {
        viewModel.continueItems(progress: progressStore,
                                sortMode: homeCatalogSettings.continueWatchingSortMode)
    }
    /// What the hero shows before any card has been focused.
    private var heroFallback: MetaItem? {
        viewModel.initialHero ?? viewModel.catalogRows.first?.items.first
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.palette.background.ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    CinemaHero(hero: hero, fallback: heroFallback, onPlay: onSelect,
                               focusTarget: $heroFocused)
                        .frame(height: 620)
                        .focusSection()
                        .id(Self.topAnchor)

                    if viewModel.isLoading && viewModel.entries.isEmpty {
                        NuvioLoadingView(label: "Loading")
                            .frame(maxWidth: .infinity).frame(height: 300)
                    } else {
                        rows(backToTop: { backToTop(proxy) })
                    }
                }
                .padding(.bottom, 80)
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
            }
        }
        .task {
            await viewModel.loadIfNeeded(addonManager: addonManager, collections: collections, settings: homeCatalogSettings)
        }
    }

    private static let topAnchor = "cinema_top"

    /// Back at the start of a row: scroll to the hero and put focus on it, so
    /// the button is reachable and Up from there lands on the tab bar. The root
    /// swallows `onExitCommand`, and the rows' `onBackAtStart` was never wired,
    /// so Back did NOTHING anywhere on this screen — you could only climb out
    /// by holding Up through every row.
    private func backToTop(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
        heroFocused = true
    }

    @ViewBuilder private func rows(backToTop: @escaping () -> Void) -> some View {
        // Collections that share one "Collections" row (viewMode != ROWS) render
        // once, at the first such entry's slot.
        let sharedCollections = viewModel.sharedCollections
        let firstSharedID = viewModel.firstSharedCollectionID

        // LAZY: this was a plain VStack, so every row in the home — 45+ on a
        // real account — built eagerly on load, each instantiating its own
        // LazyHStack and kicking off artwork decodes for cards nobody had
        // scrolled to yet. That is most of why this theme crawls on the older
        // boxes. Trade-off, same one Onyx already takes: a row recycled off
        // screen loses its horizontal scroll position.
        LazyVStack(alignment: .leading, spacing: 40) {
            if !continueItems.isEmpty {
                CinemaContinueRow(
                    items: continueItems,
                    onResume: onResume,
                    onResumeFromStart: onResumeFromStart,
                    onDetails: { onSelect(metaFor($0)) },
                    onFocusItem: { hero.focus(metaFor($0)) },
                    onBackAtStart: backToTop
                )
            }
            ForEach(viewModel.entries) { entry in
                switch entry {
                case .catalog(let row):
                    CinemaCatalogRow(row: row, onSelect: onSelect, onSeeAll: onSeeAll,
                                     onFocusItem: { hero.focus($0) },
                                     onBackAtStart: backToTop)
                case .collection(let collection):
                    if collection.viewMode == "ROWS" {
                        // Each collection = its own row of folder buttons.
                        CollectionRowSection(
                            collection: collection,
                            title: collection.title,
                            onOpenFolder: { openFolder($0, in: collection) },
                            onOpenCollection: { onOpenCollection(collection) }
                        )
                    } else if collection.id == firstSharedID {
                        // One shared "Collections" row of collection covers.
                        CollectionsRowSection(collections: sharedCollections, onOpen: onOpenCollection)
                    }
                }
            }
        }
        .padding(.horizontal, 60)
    }

    private func openFolder(_ folder: NuvioCollectionFolder, in collection: NuvioCollection) {
        onOpenCollection(HomeViewModel.folderCollection(folder, in: collection))
    }

    private func metaFor(_ p: WatchProgress) -> MetaItem { viewModel.metaFor(p) }
}

// MARK: - Hero

private struct CinemaHero: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    /// Observed HERE, not at the root — a hero change re-renders this subview
    /// only, never the rows behind it.
    @ObservedObject var hero: HeroFocus
    let fallback: MetaItem?
    let onPlay: (MetaItem) -> Void
    /// Bound to the root's Back target so Back from a row can land here.
    var focusTarget: FocusState<Bool>.Binding
    @State private var contentRating: String?

    private var item: MetaItem? { hero.item ?? fallback }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Full-bleed backdrop that crossfades as focus moves.
            GeometryReader { geo in
                RemoteImage(url: item?.background ?? item?.poster, contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            stops: [
                                .init(color: theme.palette.background, location: 0),
                                .init(color: theme.palette.background.opacity(0.2), location: 0.55),
                                .init(color: .clear, location: 1)
                            ], startPoint: .bottom, endPoint: .top)
                    )
                    .overlay(
                        LinearGradient(
                            stops: [
                                .init(color: theme.palette.background.opacity(0.85), location: 0),
                                .init(color: .clear, location: 0.6)
                            ], startPoint: .leading, endPoint: .trailing)
                    )
            }
            .id(item?.id)                       // crossfade on change
            .transition(.opacity)
            .animation(perf.heroCrossfadeEffective ? .easeInOut(duration: 0.35) : nil, value: item?.id)

            VStack(alignment: .leading, spacing: 16) {
                if let logo = item?.logo {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(maxWidth: 460, maxHeight: 150, alignment: .bottomLeading)
                } else {
                    Text(item?.name ?? "")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(2)
                }
                if let meta = metaLine {
                    Text(meta).font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                if let d = item?.description, !d.isEmpty {
                    Text(d).font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 900, alignment: .leading)
                }
                CinemaPlayButton(title: item?.type == "series" ? "Go to Show" : "Go to Movie",
                                 action: { if let item { onPlay(item) } })
                    .focused(focusTarget)
                    .padding(.top, 8)
            }
            .padding(.leading, 60)
            .padding(.bottom, 24)
        }
        .task(id: item?.id) { await loadContentRating() }
    }

    private func loadContentRating() async {
        guard let item, item.type != "collection" else {
            contentRating = nil
            return
        }
        let rating = await TMDBService.contentRating(imdbID: item.id, type: item.type)
        if self.item?.id == item.id { contentRating = rating }
    }

    private var metaLine: String? {
        guard let item else { return nil }
        var parts: [String] = []
        if let r = item.imdbRating { parts.append("★ \(r)") }
        if let contentRating { parts.append(contentRating) }
        if let y = item.releaseInfo { parts.append(y) }
        if let g = item.genres?.first { parts.append(g) }
        if let rt = item.runtime { parts.append(rt) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

private struct CinemaPlayButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { CinemaPlayLabel(title: title) }
            .buttonStyle(CinemaCardStyle())
    }
}

private struct CinemaPlayLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill").font(.system(size: 24, weight: .bold))
            Text(title).font(.system(size: 26, weight: .semibold))
        }
        .foregroundStyle(isFocused ? .white : Color(hex: 0x15171A))
        .padding(.horizontal, 36).padding(.vertical, 16)
        .background(
            Capsule().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.92))
        )
        .overlay(Capsule().strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: CinemaFocus.ringWidth))
        .scaleEffect(perf.focusScale(1.05, isFocused))
        .shadow(color: isFocused ? theme.palette.secondary.opacity(CinemaFocus.glowOpacity) : .black.opacity(0.18),
                radius: isFocused ? CinemaFocus.glowRadius : 6, y: 6)
        .animation(perf.motion(CinemaFocus.entry), value: isFocused)
    }
}

// MARK: - Continue Watching row

private struct CinemaContinueRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let items: [WatchProgress]
    let onResume: (WatchProgress) -> Void
    let onResumeFromStart: (WatchProgress) -> Void
    let onDetails: (WatchProgress) -> Void
    let onFocusItem: (WatchProgress) -> Void
    var onBackAtStart: () -> Void = {}

    var body: some View {
        ThemedCardRow(items: items, spacing: 28, onBackAtStart: onBackAtStart) {
            Text("Continue Watching")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
        } card: { p, focusID in
            CinemaContinueCard(
                progress: p,
                focusID: focusID,
                onResume: { onResume(p) },
                onResumeFromStart: { onResumeFromStart(p) },
                onDetails: { onDetails(p) },
                onFocus: { onFocusItem(p) }
            )
        }
    }
}

/// Suppresses tvOS's default focus platter so the card's OWN ring/scale/glow are
/// the only focus visual. A tiny press dip; focus itself is drawn by the label
/// (which reads `\.isFocused`). Press feedback is the shared `cardPressDip`.
struct CinemaCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cardPressDip(configuration.isPressed)
    }
}

extension View {
    /// When "raise & move" (`cardParallax`) is on, use tvOS's native card platter
    /// (lift + 3D trackpad tilt); when off, use Cinema's flat scale-only style so
    /// the label's own ring/glow/scale are the sole focus visual.
    @ViewBuilder
    func cinemaCardStyle(_ parallax: Bool) -> some View {
        if parallax { buttonStyle(.card) } else { buttonStyle(CinemaCardStyle()) }
    }
}

/// Equatable for the same reason as CinemaPosterCard.
private struct CinemaContinueCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.progress == rhs.progress }

    // See CinemaPosterCard: the store subscription belongs to the shared hold-
    // menu modifier, not to the card. ProgressStore publishes on every playback
    // save and every sync pull.
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @FocusState private var focused: Bool
    let progress: WatchProgress
    var focusID: FocusState<String?>.Binding
    let onResume: () -> Void
    let onResumeFromStart: () -> Void
    let onDetails: () -> Void
    let onFocus: () -> Void

    private let width: CGFloat = 360
    private var parallax: Bool { perf.cardParallaxEffective }
    /// Ring/glow/scale are the card's OWN focus visuals — only when the native
    /// card platter (parallax) isn't already providing the lift.
    private var ringActive: Bool { focused && !parallax }

    var body: some View {
        // Title lives BELOW the button, not inside its label: the native card
        // platter draws a raised slab behind its whole label, so a title kept
        // inside gets bridged to the artwork by a connecting bar (the "weird bar
        // below the name"). As a sibling, the art tile stays clean.
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onResume) {
                CinemaContinueArt(progress: progress, width: width, ringActive: ringActive)
            }
            .cinemaCardStyle(parallax)
            .focused($focused)
            .focused(focusID, equals: progress.id)
            .continueHoldMenu(progress, onDetails: onDetails,
                              onPlayManually: onDetails,
                              onResumeFromStart: onResumeFromStart)
            .onChange(of: focused) { _, f in if f { onFocus() } }

            Text(progress.name)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(focused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1).frame(width: width, alignment: .leading)
        }
        .focusLift(CinemaFocus.landscapeScale, ringActive, animation: CinemaFocus.entry)
    }
}

private struct CinemaContinueArt: View {
    @EnvironmentObject private var theme: ThemeManager
    let progress: WatchProgress
    let width: CGFloat
    let ringActive: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: progress.episodeThumbnail ?? progress.background ?? progress.poster,
                        contentMode: .fill, maxDimension: width)
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: CinemaFocus.cardRadius, style: .continuous))
            if progress.hasNewEpisode == true {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white, in: Circle())
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let remaining = progress.remainingTimeText {
                Text(remaining)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(.trailing, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if progress.fraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(height: 5)
                        Capsule().fill(theme.palette.secondary)
                            .frame(width: geo.size.width * CGFloat(min(max(progress.fraction, 0.02), 1)), height: 5)
                    }
                }
                .frame(height: 5).padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .overlay(
            RoundedRectangle(cornerRadius: CinemaFocus.cardRadius, style: .continuous)
                .strokeBorder(ringActive ? theme.palette.focusRing : .clear, lineWidth: CinemaFocus.ringWidth)
        )
        .shadow(color: ringActive ? theme.palette.secondary.opacity(CinemaFocus.glowOpacity) : .clear,
                radius: ringActive ? CinemaFocus.glowRadius : 0, y: 6)
    }
}

// MARK: - Catalog row

private struct CinemaCatalogRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let row: HomeRow
    let onSelect: (MetaItem) -> Void
    let onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void
    let onFocusItem: (MetaItem) -> Void
    /// Bubbled when Back is pressed while already on the first card (Cinema
    /// otherwise swallows Back at the tab level, so this defaults to a no-op).
    var onBackAtStart: () -> Void = {}

    private var landscape: Bool {
        let t = row.catalog?.type
        return t == "tv" || t == "channel"
    }

    var body: some View {
        ThemedCardRow(items: row.items, spacing: landscape ? 28 : 24,
                      onBackAtStart: onBackAtStart) {
            HStack {
                Text(row.title).font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                if let addon = row.addon, let catalog = row.catalog {
                    Button { onSeeAll(addon, catalog, row.title) } label: { CinemaSeeAll() }
                        .buttonStyle(CinemaCardStyle())
                }
            }
        } card: { item, focusID in
            CinemaPosterCard(item: item, landscape: landscape, focusID: focusID,
                             onSelect: { onSelect(item) }, onFocus: { onFocusItem(item) })
        }
    }
}

/// Equatable so a focus step — which writes the ROW's @FocusState and re-runs
/// the row body — skips the bodies of unchanged cards. Without this every card
/// in the row rebuilt its button/artwork/menu tree on every single D-pad step
/// (measured: ~13 card bodies per press, against the ~2 that actually change).
/// `==` covers the data and layout inputs only; the closures are stable for the
/// life of the row, and this card's own focus visuals invalidate through its
/// internal @FocusState, which bypasses the == gate. Same pattern the classic
/// home's HomePosterCell already uses.
private struct CinemaPosterCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.landscape == rhs.landscape
    }

    // NO @EnvironmentObject for LibraryStore / WatchedStore here. The hold menu
    // needs them, but declaring them on the CARD subscribes the card's whole
    // body — artwork, overlays, shadow — to both stores, so every visible card
    // rebuilt whenever either published. They publish on every sync pull, so
    // browsing during a sync rebuilt the entire visible grid. The shared
    // `posterHoldMenu` modifier owns those subscriptions instead, which is why
    // it exists; only the menu re-renders.
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @FocusState private var focused: Bool
    let item: MetaItem
    let landscape: Bool
    var focusID: FocusState<String?>.Binding
    let onSelect: () -> Void
    let onFocus: () -> Void

    private var width: CGFloat { landscape ? 360 : 200 }
    private var parallax: Bool { perf.cardParallaxEffective }
    private var ringActive: Bool { focused && !parallax }

    var body: some View {
        // Landscape title sits BELOW the button (a sibling), not inside its
        // label: the native card platter would otherwise bridge it to the
        // artwork with a connecting slab (the "weird bar below the name").
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                CinemaPosterArt(item: item, landscape: landscape, ringActive: ringActive)
            }
            .cinemaCardStyle(parallax)
            .focused($focused)
            .focused(focusID, equals: item.id)
            .posterHoldMenu(item, onDetails: onSelect)
            .onChange(of: focused) { _, f in if f { onFocus() } }

            if landscape {
                Text(item.name).font(.system(size: 22, weight: .medium))
                    .foregroundStyle(focused ? theme.palette.textPrimary : theme.palette.textSecondary)
                    .lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .focusLift(landscape ? CinemaFocus.landscapeScale : CinemaFocus.posterScale,
                   ringActive, animation: CinemaFocus.entry)
    }
}

private struct CinemaPosterArt: View {
    @EnvironmentObject private var theme: ThemeManager
    let item: MetaItem
    let landscape: Bool
    let ringActive: Bool

    private var width: CGFloat { landscape ? 360 : 200 }
    private var height: CGFloat { landscape ? width * 9 / 16 : width * 3 / 2 }

    var body: some View {
        RemoteImage(url: landscape ? (item.background ?? item.poster) : item.poster,
                    contentMode: .fill, maxDimension: height)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: CinemaFocus.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CinemaFocus.cardRadius, style: .continuous)
                    .strokeBorder(ringActive ? theme.palette.focusRing : .clear, lineWidth: CinemaFocus.ringWidth)
            )
            .shadow(color: ringActive ? theme.palette.secondary.opacity(CinemaFocus.glowOpacity) : .clear,
                    radius: ringActive ? CinemaFocus.glowRadius : 0, y: 6)
    }
}

private struct CinemaSeeAll: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    var body: some View {
        HStack(spacing: 8) {
            Text("See All").font(.system(size: 22, weight: .medium))
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(isFocused ? .white : theme.palette.textSecondary)
        .padding(.horizontal, 20).frame(height: 48)
        .background(Capsule().fill(isFocused ? theme.palette.secondary : theme.palette.backgroundCard))
        .animation(perf.buttonMotion(CinemaFocus.entry), value: isFocused)
    }
}
