import SwiftUI

// MARK: - Home row (folder tiles)

/// A single collection rendered as its OWN Home row (Rows view mode): the row
/// is titled by the collection, and each FOLDER is a button/tile. Selecting a
/// folder opens that folder's discover page (its content, on its own).
struct CollectionRowSection: View {
    @EnvironmentObject private var theme: ThemeManager

    let collection: OrivioCollection
    let title: String
    /// Open ONE folder's discover page.
    let onOpenFolder: (OrivioCollectionFolder) -> Void
    /// Open the whole collection (the empty-state tile's action — with no
    /// folders there's no folder to open).
    var onOpenCollection: () -> Void = {}
    /// Reports WHICH folder just gained focus, so Home can drive the hero panel
    /// per-folder (each category shows its own logo/backdrop).
    var onFolderFocus: (OrivioCollectionFolder) -> Void = { _ in }
    /// Back on the first tile bubbles up (sidebar / tab bar).
    var onBackAtStart: () -> Void = {}

    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            RowHeader(title: title)
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                    ForEach(collection.folders) { folder in
                        Button { onOpenFolder(folder) } label: {
                            CollectionFolderCard(folder: folder, glowEnabled: collection.focusGlowEnabled ?? true,
                                                 showTitle: false, forceLandscape: true)
                                .onFocusChange { if $0 { onFolderFocus(folder) } }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focusedID, equals: folder.id)
                        .id(folder.id)
                    }
                    if collection.folders.isEmpty {
                        // Must stay a Button: a bare card is unfocusable on
                        // tvOS, leaving this row a focus dead-zone with no way
                        // to open the empty collection.
                        Button(action: onOpenCollection) {
                            CollectionFolderCard(folder: nil, fallbackTitle: collection.title,
                                                 glowEnabled: collection.focusGlowEnabled ?? true)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.vertical, OrivioSpacing.lg)
            }
            .scrollClipDisabled()
            // Focus section so Down/Up always STOP on this row instead of
            // skipping it when it's sparse (e.g. a collection with one folder
            // sitting below a wide poster row). Safe here — these tiles carry no
            // long-press hold menu, so the focus section can't swallow one.
            .focusSection()
            // Back: scroll to + focus the first tile if scrolled in; on the
            // first tile, bubble up (sidebar / tab bar).
            .onExitCommand {
                if let first = collection.folders.first?.id, focusedID != first {
                    withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .leading) }
                    DispatchQueue.main.async { focusedID = first }
                } else {
                    onBackAtStart()
                }
            }
            }   // ScrollViewReader
        }
    }
}

/// ALL collections as a single headerless Home row — one tile per collection.
/// (On Home there's deliberately no row title; the reorder screen labels the
/// whole group "Collections".)
struct CollectionsRowSection: View {
    let collections: [OrivioCollection]
    let onOpen: (OrivioCollection) -> Void
    /// Reports which collection is focused so Home can drive its hero
    /// backdrop/logo panel the same way a regular poster card does.
    var onFocus: (OrivioCollection) -> Void = { _ in }
    /// Back on the first tile bubbles up (sidebar / tab bar).
    var onBackAtStart: () -> Void = {}

    @FocusState private var focusedID: String?

    /// Collections flagged "pin to top" sort first, in their given order;
    /// everything else keeps the Home-layout order after them. Home already
    /// folds every collection into this one combined row, so a per-collection
    /// pin can't move it to its own row position — instead it wins its place
    /// within this shared tile strip.
    private var ordered: [OrivioCollection] {
        let pinned = collections.filter(\.pinToTop)
        guard !pinned.isEmpty else { return collections }
        let rest = collections.filter { !$0.pinToTop }
        return pinned + rest
    }

    /// Tallest tile in this row, plus room for the title line beneath it. Must
    /// match CollectionTileCard.cardSize.
    private var rowHeight: CGFloat {
        let tallest = ordered.reduce(CGFloat(214)) { acc, c in
            switch c.folders.first?.tileShape {
            case "POSTER": return max(acc, 330)
            case "LANDSCAPE": return max(acc, 214)
            default: return max(acc, 260)
            }
        }
        // + title line + the row's own vertical padding.
        return tallest + 44 + OrivioSpacing.lg * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                ForEach(ordered) { collection in
                    Button { onOpen(collection) } label: {
                        CollectionTileCard(collection: collection)
                            .onFocusChange { focused in
                                if focused { onFocus(collection) }
                            }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focusedID, equals: collection.id)
                    .id(collection.id)
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.vertical, OrivioSpacing.lg)
            // Reserve the TALLEST tile's height for the whole row. Collections
            // mix shapes (a POSTER tile is 330pt, a LANDSCAPE one 214pt), and
            // without a common height the row only sized to its own content —
            // so a tall tile plus its title/focus glow spilled over whatever
            // sat underneath.
            .frame(height: rowHeight, alignment: .top)
        }
        .scrollClipDisabled()
        // Focus section so a sparse collections row is never skipped on vertical
        // moves. Safe — collection tiles have no long-press hold menu.
        .focusSection()
        // Back: scroll to + focus the first tile if scrolled in; on the first
        // tile, bubble up (sidebar / tab bar).
        .onExitCommand {
            if let first = ordered.first?.id, focusedID != first {
                withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .leading) }
                DispatchQueue.main.async { focusedID = first }
            } else {
                onBackAtStart()
            }
        }
        }   // ScrollViewReader
    }
}

/// A tile representing a whole collection (its first folder's cover/emoji plus
/// the collection title), used in the combined Home collections row.
/// Fusion (§27.1): a layered "stack" backing drawn behind a collection folder
/// tile — two offset, darker, slightly-rotated cards peeking out so the tile
/// reads as a folder holding things. On focus the layers separate a little more
/// (§27.2). Purely decorative (the tiles carry a single brand cover, not member
/// posters), so it uses tinted cards rather than real artwork.
struct FusionFolderStack: View {
    let size: CGSize
    let radius: CGFloat
    let tint: Color
    let focused: Bool

    var body: some View {
        ZStack {
            layer(scale: 0.95, offset: focused ? 30 : 22, angle: 3.5, dim: -0.16, opacity: 0.6)
            layer(scale: 0.975, offset: focused ? 17 : 12, angle: 1.8, dim: -0.08, opacity: 0.82)
        }
        .animation(FusionMotion.focusEntry, value: focused)
    }

    private func layer(scale: CGFloat, offset: CGFloat, angle: Double, dim: Double, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint)
            // Darken via a black overlay, not `.brightness()`: the filter put
            // an offscreen color-matrix pass on BOTH stack layers of every
            // collection tile, re-composited through the focus animation. The
            // overlay is a plain alpha blend for the same darkened read.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(-dim))
            )
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle))
            .offset(x: offset, y: offset)
            .opacity(opacity)
    }
}

/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged tiles instead of rebuilding
/// every one in the row. Focus visuals come through \.isFocused, which
/// bypasses the == gate.
struct CollectionTileCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.collection == rhs.collection }

    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    @AppStorage(CommunityCollections.coverStyleKey) private var coverStylesJSON = "{}"
    let collection: OrivioCollection

    private var firstFolder: OrivioCollectionFolder? { collection.folders.first }
    private var cover: String? { firstFolder?.coverImageUrl }
    private var emoji: String? { firstFolder?.coverEmoji }
    /// Keyed by the FOLDER's id (the stable per-category preset id), not the
    /// collection's — a group collection (e.g. "Streaming Services") holds
    /// several categories, each with its own independent Dark/Bright choice.
    private var isBright: Bool {
        guard let id = firstFolder?.id else { return false }
        return CommunityCollections.decodeCoverStyles(coverStylesJSON)[id] ?? false
    }

    /// SQUARE is the only shape that means "a logo mark on a branded card";
    /// POSTER and LANDSCAPE are full-bleed artwork that should fill the tile.
    private var isLogoMark: Bool {
        let shape = firstFolder?.tileShape ?? "SQUARE"
        return shape != "POSTER" && shape != "LANDSCAPE"
    }

    /// Tile size follows the (editable) shape of the collection's first folder.
    private var cardSize: CGSize {
        switch firstFolder?.tileShape {
        case "POSTER": return CGSize(width: 220, height: 330)
        case "LANDSCAPE": return CGSize(width: 380, height: 214)
        default: return CGSize(width: 260, height: 260)   // SQUARE
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: OrivioRadius.md)
                    .fill(isBright ? AnyShapeStyle(OrivioPrimitives.neutral100) : AnyShapeStyle(theme.palette.surface))
                if let cover, !cover.isEmpty {
                    // POSTER / LANDSCAPE covers are full-bleed CARD ART (a
                    // Netflix card, a director portrait), not logo marks — so
                    // fill the tile edge to edge. Drawing them .fit with padding
                    // left the grey `surface` fill showing as bars around every
                    // tile. Only SQUARE is a logo mark that wants a margin.
                    RemoteImage(url: cover, contentMode: isLogoMark ? .fit : .fill)
                        .padding(OrivioSpacing.sm)
                        .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md))
                } else if let emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 84))
                } else {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            // Fusion (§27): layered-stack backing behind the tile.
            .background {
                if theme.isAppleTVTheme {
                    FusionFolderStack(size: cardSize, radius: OrivioRadius.md,
                                      tint: theme.palette.backgroundCard, focused: isFocused)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .shadow(color: .black.opacity(perf.settings.cardShadows && isFocused ? 0.65 : 0),
                    radius: perf.settings.cardShadows && isFocused ? 22 : 0, y: 10)
            // Collection-authored "focus glow" — a colored halo behind the tile,
            // distinct from the neutral drop shadow above. Off by default per
            // folder if the collection disabled it in the editor.
            .shadow(color: glowEnabled && perf.settings.cardShadows && isFocused ? theme.palette.focusRing.opacity(0.85) : .clear,
                    radius: glowEnabled && perf.settings.cardShadows && isFocused ? 28 : 0)

            Text(collection.title)
                .font(theme.isAppleTVTheme ? FusionType.cardTitle(theme.font) : .system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1)
                .frame(width: cardSize.width, alignment: .leading)
        }
        .focusLift(OrivioFocus.card, isFocused)
    }

    private var glowEnabled: Bool { collection.focusGlowEnabled ?? true }
}

/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged tiles instead of rebuilding
/// every tile in the row. This row is rendered by EVERY theme, and a real
/// library has collections with 100-200 folders in one strip. Focus visuals
/// come through \.isFocused, which bypasses the == gate.
struct CollectionFolderCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folder == rhs.folder && lhs.fallbackTitle == rhs.fallbackTitle
            && lhs.glowEnabled == rhs.glowEnabled && lhs.showTitle == rhs.showTitle
            && lhs.forceLandscape == rhs.forceLandscape
    }

    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    /// True once this tile's focus GIF has decoded and started playing, so the
    /// still cover can fade out. Stays false if the GIF fails, keeping the
    /// static artwork on screen.
    @State private var gifPlaying = false
    /// Dark/Bright choice per community category (Community Collections
    /// picker), keyed by THIS folder's own id — a group collection (e.g.
    /// "Streaming Services") holds several categories, each with its own
    /// independent choice, so this can't be a collection-level lookup.
    @AppStorage(CommunityCollections.coverStyleKey) private var coverStylesJSON = "{}"

    let folder: OrivioCollectionFolder?
    var fallbackTitle: String = ""
    var glowEnabled: Bool = true
    /// Home rows hide the caption: the tile IS a brand logo (it already reads
    /// "Netflix"/"Marvel Studios"…), so the redundant caption underneath just
    /// pokes up through the billboard scrim as the row scrolls away.
    var showTitle: Bool = true
    /// Home rows render every non-poster tile at the SAME landscape size, so a
    /// brand whose only logo is squarish (Paramount's mountain, DC's circle —
    /// TMDB hosts no wide variant for either) doesn't leave a ragged row of
    /// mixed tile sizes. The logo draws .fit, centered with side margins — the
    /// declared tileShape stays accurate for Android, which stretches to it.
    var forceLandscape: Bool = false

    private var isBright: Bool {
        guard let id = folder?.id else { return false }
        return CommunityCollections.decodeCoverStyles(coverStylesJSON)[id] ?? false
    }

    private var title: String { folder?.title ?? fallbackTitle }

    /// The folder's focus GIF, when it has one AND hasn't switched it off.
    /// `focusGifEnabled` is nil on older/imported folders — treat a present URL
    /// as opt-in there, matching how the Android app behaves.
    /// The quality actually used, after Reduce Motion.
    ///
    /// `.partial` is the right answer for that setting: the focus art still
    /// swaps in, so the state change stays visible, but nothing loops. Without
    /// it a focused folder played a 24-60 frame animation for a viewer who
    /// asked the system to stop moving things. `.off` stays off.
    private var effectiveGifQuality: CollectionGifQuality {
        guard perf.reduceMotion else { return perf.settings.collectionGifQuality }
        return perf.settings.collectionGifQuality == .off ? .off : .partial
    }

    private var focusGifURL: String? {
        guard effectiveGifQuality != .off,
              let url = folder?.focusGifUrl, !url.isEmpty,
              folder?.focusGifEnabled != false else { return nil }
        return url
    }

    /// Same rule as CollectionCard: only SQUARE is a logo mark wanting a margin.
    private var isLogoMark: Bool {
        if forceLandscape { return false }
        let shape = folder?.tileShape ?? "SQUARE"
        return shape != "POSTER" && shape != "LANDSCAPE"
    }

    private var isPoster: Bool { folder?.tileShape == "POSTER" }
    private var isLandscape: Bool { folder?.tileShape == "LANDSCAPE" }

    private var cardSize: CGSize {
        if isPoster { return CGSize(width: 220, height: 330) }
        if isLandscape || forceLandscape { return CGSize(width: 360, height: 200) }
        return CGSize(width: 260, height: 260)   // SQUARE default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: OrivioRadius.md)
                    .fill(isBright ? AnyShapeStyle(OrivioPrimitives.neutral100) : AnyShapeStyle(theme.palette.surface))
                if let cover = folder?.coverImageUrl, !cover.isEmpty {
                    // Full-bleed for POSTER/LANDSCAPE card art; .fit + margin
                    // only for SQUARE logo marks. See CollectionCard above —
                    // padding full-bleed art inside the tile is what produced
                    // the grey bars around every tile.
                    // Decode capped to the tile, NOT the original. This asked
                    // TMDB for `originalSize` and then handed it to RemoteImage
                    // uncapped, so a 260-330pt tile decoded full-resolution
                    // artwork — in a strip that can hold 100-200 of them (this
                    // library has Actors at 100 and Film Collections at 200),
                    // on the box least able to afford it.
                    RemoteImage(url: TMDBService.originalSize(cover) ?? cover,
                                contentMode: isLogoMark ? .fit : .fill,
                                maxDimension: max(cardSize.width, cardSize.height))
                        .padding(isLogoMark ? OrivioSpacing.xl : 0)
                        .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md))
                        // Fade the still out only once the GIF is actually
                        // playing, so a slow/failed GIF never leaves a blank tile.
                        .opacity(gifPlaying ? 0 : 1)
                } else if let emoji = folder?.coverEmoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 84))
                } else {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                // Focus GIF. The model has carried `focusGifUrl` /
                // `focusGifEnabled` since the Android port, but nothing ever
                // drew them — that's why "the gifs don't work". Only mounted
                // while focused, so a 100-folder collection isn't animating a
                // hundred GIFs at once, and it fades in over the still art.
                if let gif = focusGifURL, isFocused {
                    AnimatedGIFView(url: gif, contentMode: .scaleAspectFill,
                                    stillOnly: effectiveGifQuality == .partial) { ok in
                        withAnimation(.easeOut(duration: 0.22)) { gifPlaying = ok }
                    }
                    // Pin to the tile explicitly. Without a hard frame the
                    // UIImageView's intrinsic size won out and the GIF drew
                    // outside the card.
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md))
                    .opacity(gifPlaying ? 1 : 0)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            // Unfocusing tears the GIF down; reset so the still returns.
            .onChange(of: isFocused) { _, focused in if !focused { gifPlaying = false } }
            // Fusion (§27): layered-stack backing behind the tile.
            .background {
                if theme.isAppleTVTheme {
                    FusionFolderStack(size: cardSize, radius: OrivioRadius.md,
                                      tint: theme.palette.backgroundCard, focused: isFocused)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .shadow(color: .black.opacity(perf.settings.cardShadows && isFocused ? 0.65 : 0),
                    radius: perf.settings.cardShadows && isFocused ? 22 : 0, y: 10)
            .shadow(color: glowEnabled && perf.settings.cardShadows && isFocused ? theme.palette.focusRing.opacity(0.85) : .clear,
                    radius: glowEnabled && perf.settings.cardShadows && isFocused ? 28 : 0)

            if showTitle && folder?.hideTitle != true && !title.isEmpty {
                Text(title)
                    .font(theme.isAppleTVTheme ? FusionType.cardTitle(theme.font) : .system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: cardSize.width, alignment: .leading)
            }
        }
        .focusLift(OrivioFocus.card, isFocused)
    }
}

// MARK: - Collection browser (tabbed grid)

/// Full collection browser: folder tabs across the top (with an "All" tab when
/// enabled) and a poster grid below — the APK's TABBED_GRID view mode.
/// One-time notice, shown the first time collections are opened, explaining
/// that focus animations are off on this hardware and where to change it.
/// Collection packs carry hundreds of multi-megabyte focus GIFs and they were
/// heavy enough to lock up a 4K gen 1, so the default is conservative — but the
/// user should be told rather than left wondering why nothing animates.
struct CollectionGifNotice: View {
    @EnvironmentObject private var theme: ThemeManager
    let quality: CollectionGifQuality
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.lg) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 64))
                    .foregroundStyle(theme.palette.focusRing)
                Text("Collection focus artwork")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(message)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                Text("Settings → Performance → Collection focus artwork")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary)
                Button("Got it", action: onDismiss)
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.top, OrivioSpacing.md)
            }
            .padding(OrivioSpacing.huge)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: OrivioRadius.lg, style: .continuous))
            .padding(OrivioSpacing.huge)
        }
        .onExitCommand(perform: onDismiss)
    }

    private var message: String {
        switch quality {
        case .off:
            return "These collections include animated artwork that plays when you focus a tile. It's off on \(PerformanceProfile.tierLabel) because it's demanding enough to affect playback and browsing. You can turn it on any time."
        case .partial:
            return "Focus artwork is set to still images on \(PerformanceProfile.tierLabel) — the art still changes when you focus a tile, without the cost of animation. You can switch to full animation any time."
        case .full:
            return "These collections include animated artwork that plays when you focus a tile. If browsing feels sluggish, you can switch it to still images or turn it off."
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @ObservedObject private var perfSettings = PerformanceSettingsStore.shared
    @EnvironmentObject private var layoutSettings: HomeCatalogSettingsStore
    @AppStorage("orivio.collections.gifNoticeSeen.v1") private var gifNoticeSeen = false
    @State private var showGifNotice = false

    let collection: OrivioCollection
    let onSelect: (MetaItem) -> Void

    @State private var selectedFolderID: String?   // nil = All
    @State private var itemsByFolder: [String: [MetaItem]] = [:]
    /// Folders whose first pass has landed. The grid only shows an empty state
    /// for a folder that has actually been fetched — an unfetched one is still
    /// on its way, and saying "nothing here" about it would be a lie.
    @State private var loadedFolders: Set<String> = []
    @State private var isLoading = true
    @State private var hasUnsupportedSources = false

    private enum SortMode: String { case popular, topRated, az, newest }
    private enum TypeFilter: String { case all, movies, shows }
    @State private var sortMode: SortMode = .popular
    @State private var typeFilter: TypeFilter = .all
    @State private var genreFilter: String?   // nil = All genres

    /// The current folder/"All" selection, before type/genre/sort — everything
    /// downstream (type filter, genre filter, sort) narrows or reorders this.
    private var folderItems: [MetaItem] {
        if let selectedFolderID {
            return itemsByFolder[selectedFolderID] ?? []
        }
        // "All" preserves folder order and de-dupes across folders.
        var seen = Set<String>()
        return collection.folders.flatMap { itemsByFolder[$0.id] ?? [] }.filter { seen.insert($0.id).inserted }
    }

    /// False while the folder on screen is still queued. Folders now arrive one
    /// chunk at a time, so tabbing to one that hasn't landed must show a
    /// spinner — the empty state would wrongly claim the folder has no titles.
    /// "All" is treated as resolved as soon as anything has landed.
    private var selectedFolderResolved: Bool {
        guard let selectedFolderID else { return !loadedFolders.isEmpty }
        return loadedFolders.contains(selectedFolderID)
    }

    private var typeFilteredItems: [MetaItem] {
        switch typeFilter {
        case .all: return folderItems
        case .movies: return folderItems.filter { !$0.isSeries }
        case .shows: return folderItems.filter { $0.isSeries }
        }
    }

    /// True only when the current folder/"All" selection genuinely mixes both
    /// movies and shows — a Movies/Shows filter is pointless clutter otherwise.
    private var hasMixedTypes: Bool {
        var sawMovie = false, sawShow = false
        for item in folderItems {
            if item.isSeries { sawShow = true } else { sawMovie = true }
            if sawMovie && sawShow { return true }
        }
        return false
    }

    /// Genres actually present in the current type-filtered set (TMDB discover
    /// sources carry genres; addon/Trakt-sourced items generally don't, so this
    /// is empty — and the picker hides itself — for those).
    private var availableGenres: [String] {
        var seen = Set<String>()
        for item in typeFilteredItems {
            for g in item.genres ?? [] where seen.insert(g).inserted {}
        }
        return seen.sorted()
    }

    private var visibleItems: [MetaItem] {
        var items = typeFilteredItems
        if let genreFilter {
            items = items.filter { $0.genres?.contains(genreFilter) == true }
        }
        switch sortMode {
        case .popular:
            break   // sources already fetch popularity-first; keep that order
        case .topRated:
            items = items.sorted { (Double($0.imdbRating ?? "") ?? -1) > (Double($1.imdbRating ?? "") ?? -1) }
        case .az:
            items = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest:
            items = items.sorted { ($0.year ?? "0") > ($1.year ?? "0") }
        }
        return items
    }

    /// Bound to the poster-size setting — an `.adaptive(minimum: 220)` column
    /// let a 264pt Large card overflow its own track.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: layoutSettings.posterSize.posterWidth,
                            maximum: layoutSettings.posterSize.posterWidth),
                  spacing: OrivioSpacing.lg)]
    }

    /// The collection's background picture — explicit backdrop, else the first
    /// folder's cover (so it matches the tile).
    private var backdropURL: String? {
        if let b = collection.backdropImageUrl, !b.isEmpty { return b }
        if let c = collection.folders.first?.coverImageUrl, !c.isEmpty { return c }
        return nil
    }
    /// True when `backdropURL` is a genuine wide backdrop PHOTO (meant to fill
    /// the screen edge-to-edge) rather than the logo fallback (a small brand
    /// mark — every community category has one — meant to be seen WHOLE, not
    /// stretched/cropped to cover the frame, which just showed a zoomed-in
    /// sliver of the mark).
    private var backdropIsRealPhoto: Bool { collection.backdropImageUrl?.isEmpty == false }

    private var hasTabs: Bool { collection.folders.count > 1 || !collection.showAllTab }
    /// Height reserved for the pinned header (title + optional tabs + the
    /// sort/filter bar) — the grid starts below it and posters slide up UNDER
    /// the scrim/header.
    private var headerInset: CGFloat { (hasTabs ? 230 : 150) + 76 }

    var body: some View {
        collectionBody
            // First time a collection is opened, explain the focus-artwork
            // setting — otherwise "why doesn't anything animate?" on a
            // constrained box looks like a bug rather than a deliberate default.
            .overlay {
                if showGifNotice {
                    CollectionGifNotice(quality: perfSettings.settings.collectionGifQuality) {
                        gifNoticeSeen = true
                        showGifNotice = false
                    }
                }
            }
            .task {
                guard !gifNoticeSeen, collection.folders.contains(where: {
                    !($0.focusGifUrl ?? "").isEmpty
                }) else { return }
                showGifNotice = true
            }
    }

    private var collectionBody: some View {
        ZStack(alignment: .top) {
            ATVBackground()
            // A real backdrop photo fills edge-to-edge like before; the logo
            // fallback (every community category has one, no real backdrop)
            // is shown WHOLE via .fit instead of cropped/zoomed via .fill, at
            // a bit more opacity so the mark actually reads.
            if let backdrop = backdropURL {
                RemoteImage(url: backdrop, contentMode: backdropIsRealPhoto ? .fill : .fit)
                    .ignoresSafeArea()
                    .opacity(backdropIsRealPhoto ? 0.3 : 0.55)
                    .overlay(theme.palette.background.opacity(0.35).ignoresSafeArea())
            }

            // Scrolling posters (full-bleed; content padded to clear the header).
            grid

            // The "grain bar": a background-toned scrim over the top that hides
            // posters as they scroll up under the header, matching the pinned
            // treatment elsewhere. Title/tabs draw ON TOP of it.
            LinearGradient(
                stops: [
                    .init(color: theme.palette.background, location: 0),
                    .init(color: theme.palette.background, location: 0.62),
                    .init(color: theme.palette.background.opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: headerInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            // Pinned header — drawn last so it's in FRONT of the posters.
            VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                Text(collection.title)
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(.horizontal, OrivioSpacing.huge)
                // Tabs/sort only appear once content has loaded — no half-built
                // filter bar over a spinner.
                if !isLoading {
                    folderTabs
                    filterBar
                }
            }
            .padding(.top, OrivioSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task { await loadAll() }
        .onAppear {
            if !collection.showAllTab {
                selectedFolderID = collection.folders.first?.id
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if isLoading || !selectedFolderResolved {
            OrivioLoadingView(label: "Loading collection")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty {
            OrivioEmptyState(
                icon: "rectangle.stack",
                title: "Nothing here yet",
                message: hasUnsupportedSources
                    ? "This folder uses TMDB sources — enable TMDB in Settings → Integrations to show them here."
                    : "This folder has no items. Add catalog sources to it in Settings → Collections."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: OrivioSpacing.xl) {
                    ForEach(visibleItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            PosterCard(item: item)
                        }
                        .mediaCardButtonStyle()
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.bottom, OrivioSpacing.xxl)
            }
            // Reserve the pinned header's height as a top safe-area inset (not a
            // content padding): posters still scroll UP under the scrim, but the
            // focus engine now keeps the FOCUSED poster below the header — before,
            // navigating up through rows scrolled the focused card behind the
            // title/tabs where you couldn't see it.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: headerInset)
            }
        }
    }

    /// Sort + Movies/Shows + Genre — same compact filter-dropdown look as
    /// Library's Sort control. Type only appears when the current selection
    /// genuinely mixes movies and shows; Genre only appears when the resolved
    /// items actually carry genre data (TMDB discover sources do; addon/Trakt
    /// sources generally don't).
    @ViewBuilder
    private var filterBar: some View {
        let genres = availableGenres
        HStack(spacing: OrivioSpacing.md) {
            OrivioDropdown(
                title: "Sort",
                selection: sortMode.rawValue,
                options: [
                    OrivioDropdownOption(SortMode.popular.rawValue, "Popular"),
                    OrivioDropdownOption(SortMode.topRated.rawValue, "Top Rated"),
                    OrivioDropdownOption(SortMode.az.rawValue, "A-Z"),
                    OrivioDropdownOption(SortMode.newest.rawValue, "Newest"),
                ],
                triggerWidth: 280
            ) { sortMode = SortMode(rawValue: $0) ?? .popular }

            if hasMixedTypes {
                OrivioDropdown(
                    title: "Type",
                    selection: typeFilter.rawValue,
                    options: [
                        OrivioDropdownOption(TypeFilter.all.rawValue, "All"),
                        OrivioDropdownOption(TypeFilter.movies.rawValue, "Movies"),
                        OrivioDropdownOption(TypeFilter.shows.rawValue, "Shows"),
                    ],
                    triggerWidth: 240
                ) { newValue in
                    typeFilter = TypeFilter(rawValue: newValue) ?? .all
                    // A genre that only existed on the now-excluded type
                    // shouldn't linger as an invisible active filter.
                    if let genreFilter, !availableGenres.contains(genreFilter) { self.genreFilter = nil }
                }
            }

            if !genres.isEmpty {
                OrivioDropdown(
                    title: "Genre",
                    selection: genreFilter ?? "All",
                    options: [OrivioDropdownOption("All")] + genres.map { OrivioDropdownOption($0) },
                    triggerWidth: 260
                ) { genreFilter = $0 == "All" ? nil : $0 }
            }
        }
        .padding(.horizontal, OrivioSpacing.huge)
    }

    @ViewBuilder
    private var folderTabs: some View {
        if hasTabs {
            ScrollView(.horizontal) {
                HStack(spacing: OrivioSpacing.md) {
                    if collection.showAllTab {
                        folderTab(id: nil, label: "All")
                    }
                    ForEach(collection.folders) { folder in
                        folderTab(id: folder.id, label: folder.title)
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.vertical, OrivioSpacing.sm)
            }
            .scrollClipDisabled()
        }
    }

    private func folderTab(id: String?, label: String) -> some View {
        Button {
            selectedFolderID = id
        } label: {
            FolderTabPill(label: label, selected: selectedFolderID == id)
        }
        .buttonStyle(PlainCardButtonStyle())
    }

    private func loadAll() async {
        isLoading = true
        var unsupported = false
        let tmdbEnabled = tmdbSettings.isEnabled
        let tmdbLanguage = tmdbSettings.settings.language
        let addons = addonManager.addons
        let manager = addonManager
        let hideUnreleased = layoutSettings.hideUnreleasedContent
        for folder in collection.folders where CollectionResolver.hasUnsupportedSources(folder, tmdbEnabled: tmdbEnabled) {
            unsupported = true
        }

        func resolveAll(folders: [OrivioCollectionFolder], maxTmdbPages: Int,
                        tmdbStartPage: Int = 1) async -> [String: [MetaItem]] {
            var results: [String: [MetaItem]] = [:]
            await withTaskGroup(of: (String, [MetaItem]).self) { group in
                for folder in folders {
                    group.addTask {
                        let items = await CollectionResolver.resolveFolder(
                            folder, addons: addons, addonManager: manager,
                            tmdbEnabled: tmdbEnabled, tmdbLanguage: tmdbLanguage,
                            maxTmdbPages: maxTmdbPages, tmdbStartPage: tmdbStartPage,
                            hideUnreleased: hideUnreleased
                        )
                        return (folder.id, items)
                    }
                }
                for await (folderID, items) in group {
                    results[folderID] = items
                }
            }
            return results
        }

        // How many folders may be in flight at once during the background fill.
        // Unbounded meant a 200-folder collection opened 200 folders × 4 pages =
        // 800 simultaneous TMDB requests, which throttles and finishes SLOWER
        // than a bounded queue as well as spiking memory on the small boxes.
        let maxParallelFolders = 6
        let firstPassPages = 3          // 3 TMDB pages ≈ 60 titles

        /// Fetch `folders` a chunk at a time, publishing each chunk as it lands
        /// so the grid keeps filling, and re-ordering before every chunk so the
        /// folder the user is CURRENTLY looking at is fetched next rather than
        /// whenever its turn happens to come up.
        func fill(_ folders: [OrivioCollectionFolder], pages: Int) async {
            var pending = folders
            while !pending.isEmpty {
                if Task.isCancelled { return }
                if let i = pending.firstIndex(where: { $0.id == selectedFolderID }), i != 0 {
                    pending.insert(pending.remove(at: i), at: 0)
                }
                let chunk = Array(pending.prefix(maxParallelFolders))
                pending.removeFirst(chunk.count)
                let batch = await resolveAll(folders: chunk, maxTmdbPages: pages)
                if Task.isCancelled { return }
                for folder in chunk {
                    itemsByFolder[folder.id] = batch[folder.id] ?? []
                    loadedFolders.insert(folder.id)
                }
            }
        }

        // Phase 1 — first paint. The screen shows ONE folder at a time, so it
        // only needs that one folder to render; resolving the whole collection
        // up front is why a big one sat on a spinner for 20-30 seconds. Fetch
        // the folder actually on screen, paint, then fill the rest behind it.
        let firstFolder = collection.folders.first { $0.id == selectedFolderID }
            ?? collection.folders.first
        if let firstFolder {
            await fill([firstFolder], pages: firstPassPages)
        }
        hasUnsupportedSources = unsupported
        isLoading = false

        // The remaining folders stream in behind the visible grid. They're only
        // needed when the user changes tab (or for the "All" tab), and the tab
        // they pick jumps the queue.
        await fill(collection.folders.filter { $0.id != firstFolder?.id },
                   pages: firstPassPages)
        if Task.isCancelled { return }

        // Phase 2 — the FULL catalog streams in behind the visible grid, but
        // ONLY for folders phase 1 could actually have truncated: a folder
        // needs TMDB sources AND a phase-1 haul near the page cap (4 pages ×
        // 20/page, minus dedup slack). Addon/Trakt-only and small-catalog
        // folders are already complete — re-fetching them just doubled every
        // network call on every visit. Leaving the screen cancels this task.
        var possiblyTruncated = collection.folders.filter { folder in
            let hasTmdb = folder.effectiveSources.contains { $0.provider.lowercased() == "tmdb" }
            return hasTmdb && (itemsByFolder[folder.id]?.count ?? 0) >= firstPassPages * 20 - 5
        }
        guard !possiblyTruncated.isEmpty else { return }

        // Phase 2 — STREAM the rest in. This used to fetch everything at once
        // (maxTmdbPages: Int.max, up to 500 pages per folder) and only repaint
        // when the whole thing landed, so a big catalog sat there looking stuck
        // for a long time. Now it walks the catalog in windows and appends each
        // one as it arrives, so titles keep filling in continuously.
        let pagesPerWindow = 3                       // ~60 titles (TMDB pages are 20)
        var startPage = firstPassPages + 1
        while !possiblyTruncated.isEmpty, startPage <= 500 {
            if Task.isCancelled { return }
            // Chunked for the same reason as the first pass: a wide collection
            // would otherwise deepen every folder at once.
            var window: [String: [MetaItem]] = [:]
            for chunk in stride(from: 0, to: possiblyTruncated.count, by: maxParallelFolders) {
                if Task.isCancelled { return }
                let slice = Array(possiblyTruncated[chunk ..< min(chunk + maxParallelFolders,
                                                                 possiblyTruncated.count)])
                let part = await resolveAll(folders: slice,
                                            maxTmdbPages: pagesPerWindow,
                                            tmdbStartPage: startPage)
                window.merge(part) { a, _ in a }
            }
            if Task.isCancelled { return }
            var stillGoing: [OrivioCollectionFolder] = []
            for folder in possiblyTruncated {
                let fresh = window[folder.id] ?? []
                guard !fresh.isEmpty else { continue }   // exhausted → drop it
                var existing = itemsByFolder[folder.id] ?? []
                var seen = Set(existing.map(\.id))
                for item in fresh where seen.insert(item.id).inserted { existing.append(item) }
                itemsByFolder[folder.id] = existing      // published → grid grows
                stillGoing.append(folder)
            }
            possiblyTruncated = stillGoing
            startPage += pagesPerWindow
        }
    }
}

// MARK: - Collection settings

/// Inline three-option layout picker (Folders / Rows / Combined), used only by
/// the collection editor in Settings (SettingsLayoutView). Layout is a
/// per-collection setting that shapes the HOME rendering; the browse screen
/// itself has no layout control. `onChange` fires on each selection.
struct CollectionLayoutPicker: View {
    @EnvironmentObject private var theme: ThemeManager
    @Binding var viewMode: String
    var onChange: (String) -> Void = { _ in }

    private static let options: [(id: String, label: String)] = [
        ("TABBED_GRID", "Folders"),
        ("ROWS", "Rows"),
        ("COMBINED", "Combined"),
    ]

    private var subtitle: String {
        switch viewMode {
        case "ROWS": return "Each folder becomes its own row, stacked top to bottom."
        case "COMBINED": return "Every folder's titles spread out together in one row."
        default: return "Browse one folder at a time, with tabs across the top."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            Text("Layout")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            HStack(spacing: OrivioSpacing.md) {
                ForEach(Self.options, id: \.id) { opt in
                    Button {
                        viewMode = opt.id
                        onChange(opt.id)
                    } label: {
                        FolderTabPill(label: opt.label, selected: viewMode == opt.id)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
            }
            Text(subtitle)
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

/// Folder tab pill with the app's standard selected/focused treatment
/// (secondary fill when selected, focus ring + slight scale when focused).
struct FolderTabPill: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let label: String
    let selected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(selected ? theme.palette.onSecondary : theme.palette.textSecondary)
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, OrivioSpacing.sm)
            .background(
                Capsule().fill(selected ? theme.palette.secondary
                               : (isFocused ? theme.palette.focusBackground : Color.white.opacity(0.08)))
            )
            .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.card, isFocused)
    }
}
