import SwiftUI

// Stremio's Board — a fully custom home screen (NOT the shared HomeView).
// Reconstructed from the IPA's CatalogFlexVC + CatalogFlexInfoView: a
// focus-following PREVIEW PANEL pinned at the top (backdrop + logo/title +
// metadata + description for whatever poster is focused) over a vertical list
// of catalog rows — Continue Watching first, then each catalog, with a "See
// All" affordance and per-item poster shapes. Loading shows skeleton cards.

struct StremioBoardView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var progressStore: ProgressStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject var viewModel: HomeViewModel

    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    var onSeeAll: (HomeRow) -> Void = { _ in }
    var onContentReady: () -> Void = {}
    var onBackAtRoot: () -> Void = {}

    /// The focus-followed hero, ISOLATED from this view: cards report focus
    /// into it, and only the backdrop + info subviews observe it. Held as
    /// plain @State (not @StateObject) deliberately — the root must NOT
    /// subscribe, or every D-pad step would re-render the whole board and
    /// decode a fresh full-screen backdrop per step (the A8 stutter the
    /// Classic home's HeroFocus debounce exists to prevent). HeroFocus also
    /// caches enrichments, so re-focusing a title never re-fetches its meta.
    @State private var hero = HeroFocus()
    /// The focused row's key — scrolled to a consistent line just below the
    /// hero. Root state is fine here: it changes once per ROW, not per card.
    @State private var focusedRowKey: String?

    /// Height of the hero region; the rows are inset by this and scroll behind it.
    private static let heroHeight: CGFloat = 560

    private var catalogRows: [HomeRow] {
        viewModel.entries.compactMap { if case .catalog(let r) = $0 { return r } else { return nil } }
    }

    /// All catalog items, de-duped — used to enrich a focused Continue-Watching
    /// item (whose WatchProgress lacks description/genres/rating) with the full
    /// MetaItem when the same title also appears in a catalog row.
    private var pool: [MetaItem] {
        var seen = Set<String>()
        return catalogRows.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }
    /// Upgrade a card's light MetaItem with the catalog copy (art) before it
    /// reaches the hero — CW cards carry only name + art fragments.
    private func enrich(_ m: MetaItem) -> MetaItem { pool.first { $0.id == m.id } ?? m }

    private func progressWithCatalogArt(_ progress: WatchProgress, pool: [MetaItem]) -> WatchProgress {
        guard (progress.poster == nil || progress.background == nil || progress.name.isEmpty),
              let meta = pool.first(where: { $0.id == progress.metaID }) else {
            return progress
        }
        return progress.withFallbackMetadata(meta)
    }

    /// Full meta for a committed hero item (runtime / cast / synopsis) —
    /// catalog items carry only light metadata, but the hero shows the same
    /// info line + cast as the real Stremio board. Installed as `hero.enrich`,
    /// so HeroFocus debounces it behind the settle window and caches results
    /// (the old per-focus fetch re-downloaded the same meta every visit).
    private func fullMeta(_ e: MetaItem) async -> MetaItem? {
        guard let addon = await addonManager.metaAddon(for: e.type, id: e.id),
              let full = try? await StremioAPI.meta(addon: addon, type: e.type, id: e.id)
        else { return nil }
        return MetaItem(
            id: e.id, type: e.type, name: full.name.isEmpty ? e.name : full.name,
            poster: e.poster, background: e.background ?? full.background, logo: full.logo ?? e.logo,
            description: full.description ?? e.description,
            releaseInfo: full.releaseInfo ?? e.releaseInfo,
            imdbRating: full.imdbRating ?? e.imdbRating,
            runtime: full.runtime, genres: full.genres ?? e.genres,
            cast: full.cast, videos: full.videos ?? e.videos
        )
    }

    var body: some View {
        // Same structure as the other themes' heros (HomeView.pinnedLayout): a
        // FULL-BLEED backdrop of the focused item behind everything (reaching
        // every screen edge and dissolving into the stage), the info block pinned
        // top-left over it, and the rows in a vertically-CLIPPED scroll below —
        // so scrolled rows are hard-cut under the hero instead of needing an
        // opaque band.
        // The rows scroll in the region BELOW the hero (a `VStack` spacer reserves
        // the hero band). Because the scroll's own top edge is right under the
        // hero, scrolling the focused row to `anchor: .top` lands its heading just
        // below the hero — a consistent focus line, always fully in view. The
        // opaque hero is drawn over the top, so the previous row (clipped above the
        // scroll's edge) is hidden — no peek, no box.
        ZStack(alignment: .top) {
            StremioSurfaces.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: Self.heroHeight)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 36) {
                            if viewModel.isLoading && viewModel.entries.isEmpty {
                                ForEach(0..<3, id: \.self) { _ in StremioSkeletonRow() }
                            } else {
                                // Pool computed ONCE per body pass — the art
                                // fallback used to rebuild it per CW item.
                                let pool = self.pool
                                let continueItems = progressStore
                                    .continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
                                    .map { progressWithCatalogArt($0, pool: pool) }
                                if !continueItems.isEmpty {
                                    StremioContinueRow(
                                        items: continueItems, onResume: onResume, onSelect: onSelect,
                                        onFocus: { hero.focus(enrich($0)) }, onRowFocus: { focusedRowKey = "row_cw" },
                                        onBackAtRoot: onBackAtRoot
                                    )
                                    .id("row_cw")
                                }
                                ForEach(catalogRows) { row in
                                    StremioCatalogRow(
                                        row: row, onSelect: onSelect,
                                        onFocus: { hero.focus($0) }, onRowFocus: { focusedRowKey = "row_\(row.id)" },
                                        onBackAtRoot: onBackAtRoot
                                    )
                                    .id("row_\(row.id)")
                                }
                            }
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 90)
                    }
                    // Clipped (no scrollClipDisabled) so rows above the top edge are
                    // cut away. Snap the focused row's heading to that edge.
                    .onChange(of: focusedRowKey) { _, key in
                        guard let key else { return }
                        // Reduce Motion / A8: snap without the scroll animation.
                        if perf.reduceMotion {
                            proxy.scrollTo(key, anchor: .top)
                        } else {
                            withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(key, anchor: .top) }
                        }
                    }
                }
            }

            StremioHeroBackdrop(hero: hero)
                .frame(height: Self.heroHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            StremioHeroInfo(hero: hero)
                .frame(height: Self.heroHeight - 96, alignment: .topLeading)
                .padding(.top, 46)
                .padding(.leading, 60)
                .padding(.trailing, 60)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            hero.enrichAlways = true   // hero shows runtime/cast — light items never carry them
            hero.enrich = { [weak addonManager] item in
                guard addonManager != nil else { return nil }
                return await fullMeta(item)
            }
            await viewModel.loadIfNeeded(addonManager: addonManager, collections: collections, settings: homeCatalogSettings)
            if hero.item == nil, let first = catalogRows.first?.items.first { hero.focus(first) }
            onContentReady()
        }
        .onChange(of: viewModel.entries.count) { _, _ in
            if hero.item == nil, let first = catalogRows.first?.items.first { hero.focus(first) }
        }
        .onChange(of: addonManager.addons) { _, _ in
            Task { await viewModel.load(addonManager: addonManager, collections: collections, settings: homeCatalogSettings) }
        }
        .onExitCommand(perform: onBackAtRoot)
    }
}

// MARK: - Hero (full-bleed backdrop + pinned info) — matches HomeView's hero

/// The full-bleed backdrop of the focused item. Fills every screen edge
/// (`.ignoresSafeArea()`) and dissolves into the navy stage via a left scrim
/// (for the text column) and a bottom scrim (so the rows sit on solid navy) —
/// the same treatment as the other themes' heros (`HeroBackdropView`). The art
/// crossfades as focus moves.
private struct StremioHeroBackdrop: View {
    /// Observed HERE, not at the root — a hero change re-renders the backdrop
    /// and info subviews only, never the rows.
    @ObservedObject var hero: HeroFocus

    private var item: MetaItem? { hero.item }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // OPAQUE base under the art. The backdrop must never be see-through:
                // as the focused item changes, `RemoteImage` crossfades and its
                // opacity briefly dips — without this base the rows scrolling behind
                // would flash through for a frame. The base keeps the hero solid.
                StremioSurfaces.background
                    .frame(width: geo.size.width, height: geo.size.height)
                if let item, let art = item.background ?? item.poster {
                    RemoteImage(url: art)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                // Left scrim: darken the text column, fade to clear so the art
                // reads on the right. A smooth many-stop ramp (no flat block).
                LinearGradient(
                    stops: [
                        .init(color: StremioSurfaces.background, location: 0.0),
                        .init(color: StremioSurfaces.background.opacity(0.92), location: 0.14),
                        .init(color: StremioSurfaces.background.opacity(0.72), location: 0.30),
                        .init(color: StremioSurfaces.background.opacity(0.42), location: 0.46),
                        .init(color: StremioSurfaces.background.opacity(0.16), location: 0.62),
                        .init(color: .clear, location: 0.80)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                // Bottom scrim: dissolve the art into the stage so the rows below
                // sit on solid navy (a smooth ramp, fully navy by the bottom edge).
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.34),
                        .init(color: StremioSurfaces.background.opacity(0.5), location: 0.58),
                        .init(color: StremioSurfaces.background.opacity(0.9), location: 0.80),
                        .init(color: StremioSurfaces.background, location: 0.94)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// The pinned info block over the hero — matches the real Stremio board: the
/// TITLE as bold text, a space-separated meta line ("109 min   2026   8.0  IMDb"
/// with a yellow IMDb badge), the overview, and the CAST line at the bottom.
private struct StremioHeroInfo: View {
    @ObservedObject var hero: HeroFocus
    @ObservedObject private var perf = PerformanceSettingsStore.shared

    private var item: MetaItem? { hero.item }

    var body: some View {
        content
            // The crossfade that used to live on the root — moved here with
            // the state it animates, so the root never observes the hero.
            .animation(perf.heroCrossfadeEffective ? .easeInOut(duration: 0.3) : nil, value: item?.id)
    }

    @ViewBuilder private var content: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(StremioFont.bold(60))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

                metaLine(item)
                    .padding(.top, 18)

                if let d = item.description, !d.isEmpty {
                    Text(d)
                        .font(StremioFont.regular(29))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(.top, 22)
                }

                Spacer(minLength: 0)

                if let cast = item.cast, !cast.isEmpty {
                    Text(cast.prefix(3).joined(separator: ", "))
                        .font(StremioFont.medium(22))
                        .foregroundStyle(StremioSurfaces.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(item.id)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func metaLine(_ item: MetaItem) -> some View {
        HStack(spacing: 26) {
            if let rt = item.runtime, !rt.isEmpty {
                Text(rt.contains("min") || rt.contains("h") ? rt : "\(rt) min")
            }
            if let y = item.year { Text(y) }
            if let r = item.imdbRating {
                HStack(spacing: 10) {
                    Text(r)
                    Text("IMDb")
                        .font(StremioFont.bold(18))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(StremioSurfaces.yellow))
                }
            }
        }
        .font(StremioFont.medium(24))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}

// MARK: - Catalog row

private struct StremioCatalogRow: View {
    let row: HomeRow
    let onSelect: (MetaItem) -> Void
    var onFocus: (MetaItem) -> Void = { _ in }
    /// Fired when any card in this row gains focus (board scrolls it into line).
    var onRowFocus: () -> Void = {}
    /// Bubbled when Back is pressed on the first card (board opens the sidebar).
    var onBackAtRoot: () -> Void = {}

    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @FocusState private var focusedID: String?

    /// Stremio renders tv/channel catalogs as landscape cards; movie/series as
    /// portrait (its posterShape).
    private var landscape: Bool {
        guard let t = row.catalog?.type else { return false }
        return t == "tv" || t == "channel"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Row heading only — the real Stremio board has no "See All" pill.
            Text(row.title)
                .font(StremioFont.bold(34))
                .foregroundStyle(.white)
                .padding(.leading, 60)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: landscape ? 26 : 24) {
                        ForEach(row.items) { item in
                            Button { onSelect(item) } label: {
                                StremioPosterCard(item: item, width: landscape ? 340 : 190,
                                                  landscape: landscape, parallax: perf.cardParallaxEffective)
                                    .onFocusChange { if $0 { onFocus(item) } }
                            }
                            // Native tvOS card style (lift + 3D trackpad tilt) when
                            // parallax is on; a plain scale-only focus on the A8.
                            .stremioCardStyle(parallax: perf.cardParallaxEffective)
                            .posterHoldMenu(item) { onSelect(item) }
                            .focused($focusedID, equals: item.id)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 14)
                }
                .scrollClipDisabled()
                // Back jumps to the first card; Back from the first card bubbles
                // to the board (which opens the sidebar).
                .onExitCommand {
                    stremioBackToStart(proxy, first: row.items.first?.id, focused: focusedID,
                                       onBackAtRoot: onBackAtRoot) { focusedID = $0 }
                }
            }
        }
        .onChange(of: focusedID) { _, id in if id != nil { onRowFocus() } }
        // No `.focusSection()`: it grouped the See-All + posters so a vertical
        // move landed on See-All and lost the column. Without it, tvOS keeps the
        // horizontal position across rows (Down from the 3rd poster → the 3rd
        // poster of the next row) and See-All (far right) is only reached by
        // pressing Right/Up to it — matching the shared HomeView rows.
    }
}

/// Shared Back-to-first for the Stremio rows.
private func stremioBackToStart(_ proxy: ScrollViewProxy, first: String?, focused: String?,
                                onBackAtRoot: () -> Void, setFocus: @escaping (String) -> Void) {
    guard let first, focused != first else { onBackAtRoot(); return }
    withAnimation(StremioFocus.entry) { proxy.scrollTo(first, anchor: .leading) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { setFocus(first) }
}

/// The purple "in library" check badge shown on the top-left of a poster.
private struct StremioCheckBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(StremioSurfaces.accent))
            .padding(9)
    }
}

// MARK: - Skeletons

private struct StremioSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 6).fill(StremioSurfaces.card)
                .frame(width: 220, height: 26).padding(.leading, 60)
            HStack(spacing: 24) {
                ForEach(0..<7, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: StremioFocus.cardRadius, style: .continuous)
                        .fill(StremioSurfaces.card)
                        .frame(width: 190, height: 285)
                }
            }
            .padding(.leading, 60)
        }
    }
}

// MARK: - Poster card (Stremio catalog item)

/// Stremio catalog poster card — shared by Board, Search, Discover and Library.
/// Ported from the StremioTV app's `ParallaxPoster`: a titleless poster that,
/// on focus, uses the native tvOS **card** button style (applied at the call
/// site) to lift and tilt in 3D with a moving specular highlight as the thumb
/// slides on the Siri Remote trackpad — the "reflective" effect. On top we add
/// Stremio's warm near-white focus FRAME (#F2F2F2, not purple), a glossy sheen
/// and the episode-count / progress badges. Posters are slightly squarer than a
/// standard 2:3 movie poster (width × 1.42), matching the real app.
/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged cards instead of rebuilding
/// every card in the row. Same gate the classic home's HomePosterCell uses;
/// focus visuals and store changes invalidate through their own dependencies,
/// which bypass ==.
struct StremioPosterCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.width == rhs.width
            && lhs.landscape == rhs.landscape && lhs.parallax == rhs.parallax
    }

    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let item: MetaItem
    var width: CGFloat = 210
    /// Landscape (16:9) card for tv/channel catalogs; portrait otherwise.
    var landscape: Bool = false
    /// The native card platter (lift/tilt) is active. When off (the A8 default,
    /// where the platter is the heaviest per-frame focus cost), the card supplies
    /// a lightweight scale-only focus instead — identical intent, far cheaper.
    var parallax: Bool = true

    @State private var sheen = false
    private var height: CGFloat { landscape ? width * 9 / 16 : width * 1.42 }

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: landscape ? (item.background ?? item.poster) : item.poster, maxDimension: height)
                .frame(width: width, height: height)
                .background(StremioSurfaces.card)
                // Gloss only on the FOCUSED card — a `plusLighter` blend on every
                // unfocused card in every row is pure waste (its 0.05 sheen was
                // imperceptible), so it's skipped entirely off-focus.
                .overlay { if isFocused { gloss } }
                .clipShape(RoundedRectangle(cornerRadius: StremioFocus.cardRadius, style: .continuous))
                // Purple library check (top-left), like the real Stremio posters.
                .overlay(alignment: .topLeading) {
                    if library.contains(item) { StremioCheckBadge() }
                }
            if let f = progressStore.continueFractions[item.id], f > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.55))
                        Capsule().fill(StremioSurfaces.accentBright)
                            .frame(width: geo.size.width * CGFloat(min(max(f, 0.03), 1)))
                    }
                }
                .frame(height: 5)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: width, height: height)
        // Focus indicator: the native `.card` platter's lift/tilt when parallax is
        // on; a plain scale when it's off. Drop shadow rides the Card Shadows
        // switch (off by default on A8/A10X).
        .scaleEffect(perf.focusScale(StremioFocus.posterScale, !parallax && isFocused))
        .shadow(color: .black.opacity(isFocused && perf.settings.cardShadows ? 0.5 : 0), radius: 18, y: 8)
        .onChange(of: isFocused) { _, f in sheen = f }
        .animation(perf.motion(StremioFocus.entry), value: isFocused)
    }

    /// A diagonal specular highlight on the focused card. It sweeps (repeatForever)
    /// on capable devices; on the A8 or with Reduce Motion it holds static — the
    /// blend still reads as a reflective sheen without recompositing every frame.
    private var gloss: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.26), .clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .rotationEffect(.degrees(sheen ? 8 : -8))
            .scaleEffect(1.6)
            .blendMode(.plusLighter)
            .animation(glossSweep, value: sheen)
            .allowsHitTesting(false)
    }

    private var glossSweep: Animation? {
        (perf.reduceMotion || PerformanceProfile.isLowPower)
            ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}

/// Conditional card focus style: the native platter (lift/tilt) when parallax is
/// on, else a plain style so the card's own scale marks focus. Shared by every
/// Stremio screen that shows poster cards.
extension View {
    @ViewBuilder
    func stremioCardStyle(parallax: Bool) -> some View {
        if parallax { buttonStyle(.card) } else { buttonStyle(PlainCardButtonStyle()) }
    }
}

// MARK: - Continue Watching

private struct StremioContinueRow: View {
    let items: [WatchProgress]
    let onResume: (WatchProgress) -> Void
    let onSelect: (MetaItem) -> Void
    var onFocus: (MetaItem) -> Void = { _ in }
    var onRowFocus: () -> Void = {}
    var onBackAtRoot: () -> Void = {}

    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continue Watching")
                .font(StremioFont.bold(34))
                .foregroundStyle(.white)
                .padding(.leading, 60)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(items) { progress in
                            Button { onResume(progress) } label: {
                                StremioContinueCard(progress: progress, parallax: perf.cardParallaxEffective)
                                    .onFocusChange { if $0 { onFocus(metaFor(progress)) } }
                            }
                            .stremioCardStyle(parallax: perf.cardParallaxEffective)
                            .posterHoldMenu(metaFor(progress)) { onSelect(metaFor(progress)) }
                            .focused($focusedID, equals: progress.id)
                            .id(progress.id)
                        }
                    }
                    .padding(.horizontal, 60)
                    .padding(.vertical, 14)
                }
                .scrollClipDisabled()
                .onExitCommand {
                    stremioBackToStart(proxy, first: items.first?.id, focused: focusedID,
                                       onBackAtRoot: onBackAtRoot) { focusedID = $0 }
                }
            }
        }
        .onChange(of: focusedID) { _, id in if id != nil { onRowFocus() } }
        // No `.focusSection()` — keep the column aligned with the rows below.
    }

    private func metaFor(_ p: WatchProgress) -> MetaItem {
        MetaItem(id: p.metaID, type: p.type, name: p.name, poster: p.poster, background: p.background, logo: p.logo)
    }
}

/// Continue-Watching card — a PORTRAIT poster with the purple library check and a
/// thin progress bar, exactly like the real Stremio board (no title / play icon).
/// Equatable for the same reason as StremioPosterCard.
private struct StremioContinueCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.progress == rhs.progress && lhs.parallax == rhs.parallax
    }

    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let progress: WatchProgress
    var parallax: Bool = true

    @State private var sheen = false
    private let width: CGFloat = 190
    private var height: CGFloat { width * 1.42 }

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: progress.poster ?? progress.background, maxDimension: height)
                .frame(width: width, height: height)
                .background(StremioSurfaces.card)
                .overlay { if isFocused { gloss } }
                .clipShape(RoundedRectangle(cornerRadius: StremioFocus.cardRadius, style: .continuous))
                .overlay(alignment: .topLeading) { StremioCheckBadge() }
                .overlay(alignment: .topTrailing) {
                    if progress.hasNewEpisode == true {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(.white, in: Circle())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let remaining = progress.remainingTimeText {
                        Text(remaining)
                            .font(StremioFont.bold(14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(.trailing, 8)
                            .padding(.bottom, 20)
                    }
                }
            if progress.fraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.55))
                        Capsule().fill(StremioSurfaces.accentBright)
                            .frame(width: geo.size.width * CGFloat(min(max(progress.fraction, 0.03), 1)))
                    }
                }
                .frame(height: 5)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(perf.focusScale(StremioFocus.posterScale, !parallax && isFocused))
        .shadow(color: .black.opacity(isFocused && perf.settings.cardShadows ? 0.5 : 0), radius: 18, y: 8)
        .onChange(of: isFocused) { _, f in sheen = f }
        .animation(perf.motion(StremioFocus.entry), value: isFocused)
    }

    /// The same sweeping specular sheen the posters use, on the focused card only.
    private var gloss: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.26), .clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .rotationEffect(.degrees(sheen ? 8 : -8))
            .scaleEffect(1.6)
            .blendMode(.plusLighter)
            .animation((perf.reduceMotion || PerformanceProfile.isLowPower)
                       ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                       value: sheen)
            .allowsHitTesting(false)
    }
}
