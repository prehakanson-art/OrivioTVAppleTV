import SwiftUI

// Cinema theme — a from-scratch home screen. Owns its hero, rows, and cards;
// reuses NOTHING from the retired Modern/Nova themes. Only the shared DATA layer
// (HomeViewModel, ProgressStore) and the shared detail route are reused. Every
// card carries its OWN `.contextMenu`, so hold menus work everywhere — including
// Continue Watching, which is the whole point of the rebuild.

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

    /// The item the hero reflects — follows focus as you move across cards.
    @State private var focused: MetaItem?

    private var catalogRows: [HomeRow] {
        viewModel.entries.compactMap { if case .catalog(let r) = $0 { return r } else { return nil } }
    }
    private var continueItems: [WatchProgress] {
        progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
            .map(progressWithCatalogArt)
    }
    private var heroItem: MetaItem? { focused ?? viewModel.initialHero ?? catalogRows.first?.items.first }

    var body: some View {
        ZStack(alignment: .top) {
            theme.palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    CinemaHero(item: heroItem, onPlay: { if let h = heroItem { onSelect(h) } })
                        .frame(height: 620)
                        .focusSection()

                    if viewModel.isLoading && viewModel.entries.isEmpty {
                        NuvioLoadingView(label: "Loading")
                            .frame(maxWidth: .infinity).frame(height: 300)
                    } else {
                        rows
                    }
                }
                .padding(.bottom, 80)
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .task {
            await viewModel.loadIfNeeded(addonManager: addonManager, collections: collections, settings: homeCatalogSettings)
        }
    }

    @ViewBuilder private var rows: some View {
        // Collections that share one "Collections" row (viewMode != ROWS) render
        // once, at the first such entry's slot.
        let sharedCollections = viewModel.entries.compactMap { e -> NuvioCollection? in
            if case .collection(let c) = e, c.viewMode != "ROWS" { return c } else { return nil }
        }
        let firstSharedID = sharedCollections.first?.id

        VStack(alignment: .leading, spacing: 40) {
            if !continueItems.isEmpty {
                CinemaContinueRow(
                    items: continueItems,
                    onResume: onResume,
                    onResumeFromStart: onResumeFromStart,
                    onDetails: { onSelect(metaFor($0)) },
                    onFocusItem: { focused = metaFor($0) }
                )
            }
            ForEach(viewModel.entries) { entry in
                switch entry {
                case .catalog(let row):
                    CinemaCatalogRow(row: row, onSelect: onSelect, onSeeAll: onSeeAll,
                                     onFocusItem: { focused = $0 })
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
        let single = NuvioCollection(id: "folder:\(collection.id):\(folder.id)",
                                     title: folder.title, folders: [folder])
        onOpenCollection(single)
    }

    private func metaFor(_ p: WatchProgress) -> MetaItem {
        for row in catalogRows {
            if let m = row.items.first(where: { $0.id == p.metaID }) { return m }
        }
        return MetaItem(id: p.metaID, type: p.type, name: p.name,
                        poster: p.poster, background: p.background, logo: p.logo)
    }

    private func progressWithCatalogArt(_ progress: WatchProgress) -> WatchProgress {
        guard (progress.poster == nil || progress.background == nil || progress.name.isEmpty),
              let meta = catalogRows.lazy.flatMap(\.items).first(where: { $0.id == progress.metaID }) else {
            return progress
        }
        return progress.withFallbackMetadata(meta)
    }
}

// MARK: - Hero

private struct CinemaHero: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let item: MetaItem?
    let onPlay: () -> Void
    @State private var contentRating: String?

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
                CinemaPlayButton(title: item?.type == "series" ? "Go to Show" : "Go to Movie", action: onPlay)
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

    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue Watching")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 28) {
                        ForEach(items) { p in
                            CinemaContinueCard(
                                progress: p,
                                focusID: $focusedID,
                                onResume: { onResume(p) },
                                onResumeFromStart: { onResumeFromStart(p) },
                                onDetails: { onDetails(p) },
                                onFocus: { onFocusItem(p) }
                            )
                            .id(p.id)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .scrollClipDisabled()
                .onExitCommand { cinemaBackToStart(proxy, first: items.first?.id, focused: focusedID, onBackAtStart: onBackAtStart) { focusedID = $0 } }
            }
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

private struct CinemaContinueCard: View {
    @EnvironmentObject private var progressStore: ProgressStore
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
            .contextMenu {
                Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
                Button { onResumeFromStart() } label: { Label("Start from Beginning", systemImage: "gobackward") }
                Button(role: .destructive) {
                    progressStore.removeShow(metaID: progress.metaID, notifyTrakt: true)
                } label: { Label("Remove from Continue Watching", systemImage: "xmark") }
            }
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

    @FocusState private var focusedID: String?

    private var landscape: Bool {
        let t = row.catalog?.type
        return t == "tv" || t == "channel"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(row.title).font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                if let addon = row.addon, let catalog = row.catalog {
                    Button { onSeeAll(addon, catalog, row.title) } label: { CinemaSeeAll() }
                        .buttonStyle(CinemaCardStyle())
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: landscape ? 28 : 24) {
                        ForEach(row.items) { item in
                            CinemaPosterCard(item: item, landscape: landscape, focusID: $focusedID,
                                             onSelect: { onSelect(item) }, onFocus: { onFocusItem(item) })
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .scrollClipDisabled()
                // Back jumps to the first card (scroll + focus it — the LazyHStack
                // may have unloaded it); Back from the first card bubbles up.
                .onExitCommand { cinemaBackToStart(proxy, first: row.items.first?.id, focused: focusedID, onBackAtStart: onBackAtStart) { focusedID = $0 } }
            }
        }
    }
}

/// Shared Back-to-first for the Cinema rows: scroll the first card into view and
/// focus it unless already there, in which case bubble up.
private func cinemaBackToStart(_ proxy: ScrollViewProxy, first: String?, focused: String?,
                               onBackAtStart: () -> Void, setFocus: @escaping (String) -> Void) {
    guard let first, focused != first else { onBackAtStart(); return }
    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(first, anchor: .leading) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { setFocus(first) }
}

private struct CinemaPosterCard: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
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
            .contextMenu {
                Button { onSelect() } label: { Label("Go to Details", systemImage: "info.circle") }
                Button { library.toggle(item) } label: {
                    Label(library.contains(item) ? "Remove from Library" : "Add to Library",
                          systemImage: library.contains(item) ? "bookmark.slash" : "bookmark")
                }
                Button { watched.toggleMovie(item) } label: {
                    Label(watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle")
                }
            }
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
