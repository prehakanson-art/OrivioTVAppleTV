import SwiftUI

// Onyx theme — a from-scratch home screen that faithfully ports the
// bobsupra/NuvioTVOS tvOS client (github.com/bobsupra/NuvioTVOS). It shares
// NOTHING with Classic or the other themes; only the DATA layer (HomeViewModel,
// ProgressStore, collections) and the shared detail route are reused.
//
// The NuvioTVOS look, reproduced 1:1:
//  • a full-screen backdrop of the FOCUSED title, crossfading as focus moves,
//    with a left horizontal gradient + a bottom vertical gradient for legibility
//  • a passive hero (logo/title + meta line + description) that reflects focus —
//    there is NO hero button; you select the focused card itself
//  • flat poster cards (210×315, r16) whose ONLY focus signal is a crisp 4pt
//    WHITE outline + a soft black shadow — no scale, no colored ring, no glow
//  • on Modern layout the focused card expands into a 560pt landscape card that
//    OVERFLOWS its neighbours (leading edge pinned, no reflow), showing the
//    backdrop + logo, or for Continue Watching the episode summary
//  • Continue Watching cards carry a white progress bar + a "S1 E3 · 24m left"
//    badge; movies carry a green watched checkmark
//
// Layout constants are the source app's exact values (TVHomeLayout / TVLayout /
// PosterCard in NuvioTVOS).

/// Applies tvOS's native collapsible sidebar tab style (tvOS 18+), matching the
/// NuvioTVOS root's `.tabViewStyle(.sidebarAdaptable)`. No-op on older tvOS.
struct OnyxSidebarTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *) { content.tabViewStyle(.sidebarAdaptable) }
        else { content }
    }
}

enum OnyxLayout {
    static let rowLeading: CGFloat = 48
    static let posterW: CGFloat = 210
    static let posterH: CGFloat = 315
    static let landscapeW: CGFloat = 560
    static let cardRadius: CGFloat = 16
    static let rowSpacing: CGFloat = 28
    static let sectionSpacing: CGFloat = 28
    static let heroHeight: CGFloat = 500
    static let borderWidth: CGFloat = 4
    // Focus expansion / row reflow uses the shared `View.focusExpand` /
    // `FusionMotion.rowExpand` (bounce-free, and gated by Reduce Motion).
    static let watchedGreen = Color(red: 0.10, green: 0.68, blue: 0.34)
}

struct OnyxHomeView: View {
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
    /// into it, and only the backdrop + hero subviews observe it. Held as
    /// plain @State (not @StateObject) deliberately — the root must NOT
    /// subscribe, or every D-pad step would re-render the whole home and
    /// decode a fresh full-screen backdrop per step (the A8 stutter the
    /// Classic home's HeroFocus debounce exists to prevent). CW context rides
    /// in `hero.progress`, committed atomically with the item.
    @State private var hero = HeroFocus()

    private var catalogRows: [HomeRow] {
        viewModel.entries.compactMap { if case .catalog(let r) = $0 { return r } else { return nil } }
    }
    private var continueItems: [WatchProgress] {
        progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
            .map(progressWithCatalogArt)
    }
    /// What the hero shows before any card has been focused.
    private var heroFallback: MetaItem? {
        viewModel.initialHero ?? catalogRows.first?.items.first
    }

    private func progressWithCatalogArt(_ progress: WatchProgress) -> WatchProgress {
        guard (progress.poster == nil || progress.background == nil || progress.name.isEmpty),
              let meta = catalogRows.lazy.flatMap(\.items).first(where: { $0.id == progress.metaID }) else {
            return progress
        }
        return progress.withFallbackMetadata(meta)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Full-screen backdrop of the focused title (fixed; rows scroll over it).
            OnyxBackdrop(hero: hero, fallback: heroFallback,
                         placeholder: theme.palette.background)
                .ignoresSafeArea()

            // 2. Readability gradients: a left wash (58% width) + a bottom wash.
            OnyxGradients(color: theme.palette.background).ignoresSafeArea()

            // 3. Pinned hero + scrollable rows.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.isLoading && viewModel.entries.isEmpty && continueItems.isEmpty {
                        NuvioLoadingView(label: "Loading")
                            .frame(maxWidth: .infinity).frame(height: 400)
                    } else {
                        OnyxHero(hero: hero, fallback: heroFallback)
                            .frame(height: OnyxLayout.heroHeight, alignment: .bottomLeading)

                        LazyVStack(alignment: .leading, spacing: OnyxLayout.sectionSpacing) {
                            rows
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.bottom, 80)
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .task {
            await viewModel.loadIfNeeded(addonManager: addonManager,
                                         collections: collections,
                                         settings: homeCatalogSettings)
        }
    }

    @ViewBuilder private var rows: some View {
        let sharedCollections = viewModel.entries.compactMap { e -> NuvioCollection? in
            if case .collection(let c) = e, c.viewMode != "ROWS" { return c } else { return nil }
        }
        let firstSharedID = sharedCollections.first?.id

        if !continueItems.isEmpty {
            OnyxContinueRow(
                items: continueItems,
                onResume: onResume,
                onResumeFromStart: onResumeFromStart,
                onDetails: { onSelect(metaFor($0)) },
                onFocusItem: { p in hero.focus(metaFor(p), progress: p) }
            )
        }
        ForEach(viewModel.entries) { entry in
            switch entry {
            case .catalog(let row):
                OnyxCatalogRow(row: row, onSelect: onSelect, onSeeAll: onSeeAll,
                               onFocusItem: { hero.focus($0) })
            case .collection(let collection):
                if collection.viewMode == "ROWS" {
                    CollectionRowSection(
                        collection: collection,
                        title: collection.title,
                        onOpenFolder: { openFolder($0, in: collection) },
                        onOpenCollection: { onOpenCollection(collection) }
                    )
                } else if collection.id == firstSharedID {
                    CollectionsRowSection(collections: sharedCollections, onOpen: onOpenCollection)
                }
            }
        }
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
}

// MARK: - Full-screen crossfading backdrop

private struct OnyxBackdrop: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    /// Observed HERE, not at the root — a hero change re-renders the backdrop
    /// and hero subviews only, never the rows scrolling over them.
    @ObservedObject var hero: HeroFocus
    let fallback: MetaItem?
    let placeholder: Color

    private var url: String? {
        let item = hero.item ?? fallback
        return item?.background ?? item?.poster
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                placeholder
                RemoteImage(url: url, contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .id(url)                       // remount → crossfade
                    .transition(.opacity)
            }
            .animation(perf.heroCrossfadeEffective ? .easeInOut(duration: 0.30) : nil, value: url)
        }
    }
}

/// Left horizontal wash (58% width) + bottom vertical wash — the NuvioTVOS home
/// gradients that let the hero text and rows read over any backdrop.
private struct OnyxGradients: View {
    let color: Color
    var body: some View {
        ZStack {
            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0.94), location: 0),
                        .init(color: color.opacity(0.84), location: 0.22),
                        .init(color: color.opacity(0.52), location: 0.46),
                        .init(color: color.opacity(0.14), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: color.opacity(0.20), location: 0.42),
                            .init(color: color.opacity(0.58), location: 0.78),
                            .init(color: color, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: proxy.size.height * 0.40)
                }
            }
        }
    }
}

// MARK: - Hero (passive, reflects focus — no button)

private struct OnyxHero: View {
    @ObservedObject var hero: HeroFocus
    let fallback: MetaItem?
    @State private var contentRating: String?

    private var item: MetaItem? { hero.item ?? fallback }
    /// Only surface CW context when the committed title IS the focused CW card
    /// (not once focus has moved on to a catalog row).
    private var progress: WatchProgress? {
        guard let p = hero.progress, p.metaID == item?.id else { return nil }
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let logo = item?.logo {
                RemoteImage(url: logo, contentMode: .fit)
                    .frame(maxWidth: 440, maxHeight: 114, alignment: .bottomLeading)
            } else {
                Text(item?.name ?? "")
                    .font(.system(size: 54, weight: .bold))
                    .lineLimit(2)
                    .foregroundColor(.white)
            }

            if let meta = metaLine {
                Text(meta)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
            }

            if let progress {
                Text(OnyxFormat.remaining(progress).uppercased())
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.66))
            }

            if let d = item?.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.leading, OnyxLayout.rowLeading)
        .padding(.top, 140)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .task(id: item?.id) { await loadContentRating() }
    }

    private func loadContentRating() async {
        guard let item else {
            contentRating = nil
            return
        }
        let rating = await TMDBService.contentRating(imdbID: item.id, type: item.type)
        if self.item?.id == item.id { contentRating = rating }
    }

    private var metaLine: String? {
        guard let item else { return nil }
        var parts: [String] = []
        if let e = progress.map(OnyxFormat.episodeLine), let e { parts.append(e) }
        else { parts.append(item.type == "series" ? "Series" : "Movie") }
        if let contentRating { parts.append(contentRating) }
        if let g = item.genres?.first { parts.append(g) }
        if let rt = item.runtime, progress == nil { parts.append(rt) }
        if let y = item.releaseInfo { parts.append(y) }
        if let r = item.imdbRating { parts.append("IMDb \(r)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }
}

// MARK: - Shared card button style (suppress the tvOS focus platter)

/// The card's OWN white outline is the only focus visual — this kills the
/// default tvOS focus platter/glow. Press feedback is the shared `cardPressDip`
/// so Onyx dips exactly like every other theme, and not at all when "Button
/// animations" is off / Reduce Motion is on.
struct OnyxCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cardPressDip(configuration.isPressed)
    }
}

// MARK: - Catalog row

private struct OnyxCatalogRow: View {
    let row: HomeRow
    let onSelect: (MetaItem) -> Void
    let onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void
    let onFocusItem: (MetaItem) -> Void

    /// Which card is focused, so it can be drawn above its neighbours while its
    /// landscape art overflows them.
    @State private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .padding(.leading, OnyxLayout.rowLeading)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: OnyxLayout.rowSpacing) {
                    ForEach(row.items) { item in
                        OnyxPosterCard(
                            item: item,
                            onSelect: { onSelect(item) },
                            onFocusChanged: { gained in
                                if gained { focusedID = item.id; onFocusItem(item) }
                                else if focusedID == item.id { focusedID = nil }
                            }
                        )
                        .zIndex(focusedID == item.id ? 10 : 0)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, OnyxLayout.rowLeading)
                .padding(.vertical, 28)
                // One curve drives BOTH the focused card's growth and the
                // neighbours' shift, so the whole row reflows as a single motion.
                .focusExpand(focusedID)
            }
            .scrollClipDisabled()
        }
    }
}

/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged cards instead of rebuilding
/// every card in the row. Same gate the classic home's HomePosterCell uses;
/// focus visuals and store changes invalidate through their own dependencies,
/// which bypass ==.
private struct OnyxPosterCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    let item: MetaItem
    let onSelect: () -> Void
    let onFocusChanged: (Bool) -> Void
    /// See OnyxContinueCard.held — keeps the card landscape under the hold menu.
    @State private var held = false

    var body: some View {
        Button(action: onSelect) {
            OnyxPosterLabel(item: item, isWatched: watched.isWatched(item), held: held,
                            onFocusChanged: { gained in
                                if gained { held = false }
                                onFocusChanged(gained)
                            })
        }
        .buttonStyle(OnyxCardStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in held = true })
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
    }
}

private struct OnyxPosterLabel: View {
    @Environment(\.isFocused) private var isFocused
    let item: MetaItem
    let isWatched: Bool
    var held: Bool = false
    let onFocusChanged: (Bool) -> Void

    private var isMovie: Bool {
        !["series", "tv", "show", "tvshow"].contains(item.type.lowercased())
    }
    private var expanded: Bool { isFocused || held }

    var body: some View {
        // The card's LAYOUT width grows to the landscape width on focus, so the
        // row reflows and the following cards shift right to make room (instead
        // of the landscape art overflowing on top of them).
        ZStack {
            if expanded {
                OnyxLandscapeCard(url: item.background ?? item.poster, logo: item.logo,
                                  title: item.name, summary: nil)
                    .transition(.opacity)
            } else {
                RemoteImage(url: item.poster, contentMode: .fill, maxDimension: OnyxLayout.posterH)
                    .frame(width: OnyxLayout.posterW, height: OnyxLayout.posterH)
                    .clipShape(RoundedRectangle(cornerRadius: OnyxLayout.cardRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if isMovie && isWatched { OnyxWatchedBadge() }
                    }
                    .shadow(color: .black.opacity(0.12), radius: 4)
                    .transition(.opacity)
            }
        }
        .frame(width: expanded ? OnyxLayout.landscapeW : OnyxLayout.posterW,
               height: OnyxLayout.posterH, alignment: .leading)
        .focusExpand(expanded)
        .onFocusChange { onFocusChanged($0) }
    }
}

// MARK: - Continue Watching row

private struct OnyxContinueRow: View {
    let items: [WatchProgress]
    let onResume: (WatchProgress) -> Void
    let onResumeFromStart: (WatchProgress) -> Void
    let onDetails: (WatchProgress) -> Void
    let onFocusItem: (WatchProgress) -> Void

    @State private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .padding(.leading, OnyxLayout.rowLeading)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: OnyxLayout.rowSpacing) {
                    ForEach(items) { p in
                        OnyxContinueCard(
                            progress: p,
                            onResume: { onResume(p) },
                            onResumeFromStart: { onResumeFromStart(p) },
                            onDetails: { onDetails(p) },
                            onFocusChanged: { gained in
                                if gained { focusedID = p.id; onFocusItem(p) }
                                else if focusedID == p.id { focusedID = nil }
                            }
                        )
                        .zIndex(focusedID == p.id ? 10 : 0)
                        .id(p.id)
                    }
                }
                .padding(.horizontal, OnyxLayout.rowLeading)
                .padding(.vertical, 28)
                .focusExpand(focusedID)
            }
            .scrollClipDisabled()
        }
    }
}

/// Equatable for the same reason as OnyxPosterCard.
private struct OnyxContinueCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.progress == rhs.progress }

    @EnvironmentObject private var progressStore: ProgressStore
    let progress: WatchProgress
    let onResume: () -> Void
    let onResumeFromStart: () -> Void
    let onDetails: () -> Void
    let onFocusChanged: (Bool) -> Void
    /// Set the instant a hold begins — BEFORE the context menu steals focus —
    /// so the card stays landscape under the menu instead of snapping back to
    /// the portrait poster (and overlapping its neighbour). Cleared when focus
    /// returns to the card after the menu closes.
    @State private var held = false

    var body: some View {
        Button(action: onResume) {
            OnyxContinueLabel(progress: progress, held: held, onFocusChanged: { gained in
                if gained { held = false }
                onFocusChanged(gained)
            })
        }
        .buttonStyle(OnyxCardStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in held = true })
        .contextMenu {
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button { onResumeFromStart() } label: { Label("Start from Beginning", systemImage: "gobackward") }
            Button(role: .destructive) {
                progressStore.removeShow(metaID: progress.metaID, notifyTrakt: true)
            } label: { Label("Remove from Continue Watching", systemImage: "xmark") }
        }
    }
}

private struct OnyxContinueLabel: View {
    @Environment(\.isFocused) private var isFocused
    let progress: WatchProgress
    var held: Bool = false
    let onFocusChanged: (Bool) -> Void

    private var expanded: Bool { isFocused || held }

    var body: some View {
        // Reflow on focus: the card grows to the landscape width in layout so
        // the following cards shift right to make room (no overlap).
        ZStack {
            if expanded {
                OnyxLandscapeCard(
                    url: progress.episodeThumbnail ?? progress.background ?? progress.poster,
                    logo: nil,
                    title: progress.name,
                    summary: OnyxContinueSummary(
                        episode: OnyxFormat.episodeLine(progress),
                        title: progress.name,
                        episodeTitle: progress.episodeTitle
                    ),
                    progressFraction: progress.fraction
                )
                .transition(.opacity)
            } else {
                RemoteImage(url: progress.poster ?? progress.background,
                            contentMode: .fill, maxDimension: OnyxLayout.posterH)
                    .frame(width: OnyxLayout.posterW, height: OnyxLayout.posterH)
                    .clipShape(RoundedRectangle(cornerRadius: OnyxLayout.cardRadius, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if progress.hasNewEpisode == true {
                            OnyxPlusBadge()
                        } else {
                            OnyxRemainingBadge(text: OnyxFormat.badge(progress))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if progress.fraction > 0 {
                            OnyxProgressBar(fraction: progress.fraction)
                        }
                    }
                    .shadow(color: .black.opacity(0.12), radius: 4)
                    .transition(.opacity)
            }
        }
        .frame(width: expanded ? OnyxLayout.landscapeW : OnyxLayout.posterW,
               height: OnyxLayout.posterH, alignment: .leading)
        .focusExpand(expanded)
        .onFocusChange { onFocusChanged($0) }
    }
}

// MARK: - Shared card pieces

/// The 560pt landscape art shown when a card is focused (Modern). Reused by both
/// catalog posters (logo overlay) and Continue Watching (episode summary).
private struct OnyxLandscapeCard: View {
    let url: String?
    let logo: String?
    let title: String
    let summary: OnyxContinueSummary?
    /// When set, a progress bar is drawn across the CARD's bottom (its width
    /// tracks the card, never the text block) and the summary is padded up above.
    var progressFraction: Double? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: url, contentMode: .fill, maxDimension: OnyxLayout.landscapeW)
                .frame(width: OnyxLayout.landscapeW, height: OnyxLayout.posterH)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)

            if let summary {
                summary.padding(EdgeInsets(top: 22, leading: 22,
                                           bottom: progressFraction != nil ? 54 : 30, trailing: 22))
            } else if let logo {
                RemoteImage(url: logo, contentMode: .fit)
                    .frame(width: 250, height: 76, alignment: .bottomLeading)
                    .padding(22)
            } else {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .padding(22)
            }
        }
        .frame(width: OnyxLayout.landscapeW, height: OnyxLayout.posterH)
        .clipShape(RoundedRectangle(cornerRadius: OnyxLayout.cardRadius, style: .continuous))
        // Progress bar spans the card bottom (width tied to the card, not the
        // left-aligned summary — the old placement overflowed off the art).
        .overlay(alignment: .bottom) {
            if let progressFraction, progressFraction > 0 {
                OnyxProgressBar(fraction: progressFraction)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: OnyxLayout.cardRadius, style: .continuous)
                .stroke(Color.white, lineWidth: OnyxLayout.borderWidth)
        )
        .shadow(color: .black.opacity(0.24), radius: 10)
    }
}

private struct OnyxContinueSummary: View {
    let episode: String?
    let title: String
    let episodeTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let episode {
                Text(episode)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            if let episodeTitle, !episodeTitle.isEmpty {
                Text(episodeTitle)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: OnyxLayout.landscapeW * 0.8, alignment: .leading)
    }
}

private struct OnyxProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.38)).frame(height: 8)
                Capsule().fill(Color.white)
                    .frame(width: max(8, geo.size.width * CGFloat(min(max(fraction, 0), 1))), height: 8)
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }
}

private struct OnyxRemainingBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.72)))
            .padding(12)
    }
}

private struct OnyxPlusBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 32, height: 32)
            .background(.white, in: Circle())
            .padding(8)
    }
}

private struct OnyxWatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(OnyxLayout.watchedGreen))
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(12)
    }
}

// MARK: - Formatting

enum OnyxFormat {
    static func episodeLine(_ p: WatchProgress) -> String? {
        guard let s = p.season, let e = p.episode else { return nil }
        var line = "S\(s) E\(e)"
        if let t = p.episodeTitle, !t.isEmpty { line += " · \(t)" }
        return line
    }

    static func remaining(_ p: WatchProgress) -> String {
        p.remainingTimeText.map { "\($0) left" } ?? ""
    }

    /// Compact CW badge: "S1 E3 • 24m left" (or just remaining for movies).
    static func badge(_ p: WatchProgress) -> String {
        let rem = remaining(p)
        if let s = p.season, let e = p.episode {
            return rem.isEmpty ? "S\(s) E\(e)" : "S\(s) E\(e) • \(rem)"
        }
        return rem
    }
}
