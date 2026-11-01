import SwiftUI

/// A titled horizontal row that owns its focus, reports it to the
/// `ContentFocusRouter`, and answers landing/reset requests (the nav's Right/Back
/// lands on this row's first card).
struct FocusRow<Item: Identifiable, Card: View>: View where Item.ID == String {
    let rowKey: String
    var title: String?
    var iconURL: String? = nil
    var trailing: String? = nil
    /// Adds a "See All" tile after the last card (Apple puts it in the row, not the header).
    var onSeeAll: (() -> Void)? = nil
    var seeAllSize = CGSize(width: 240, height: 360)
    let items: [Item]
    var spacing: CGFloat = 36
    var verticalPadding: CGFloat = 40
    var onFocus: ((Item, Int) -> Void)? = nil
    @ViewBuilder let card: (Item, Int) -> Card

    static var seeAllID: String { "__seeall" }
    @FocusState private var focused: String?
    /// Card frames, kept OUT of SwiftUI state: a GeometryReader + preference per
    /// card wrote a @State dictionary on every frame of any movement (a row
    /// sliding into place, a sideways scroll), redrawing every card of every
    /// row each frame — the main source of stutter on A8/A10X boxes.
    @State private var frames = CardFrames()
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @Environment(\.currentTab) private var tab

    /// Focus requests made while a row is still sliding into place can be
    /// dropped; retry briefly until focus actually lands.
    private func land(on target: String?, attempt: Int, token: UUID) {
        guard let target, attempt < 6 else { return }
        // A newer landing (another Down during a fast swipe) supersedes this one.
        guard focusRouter.landing?.token == token else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.12)) {
            guard focusRouter.landing?.token == token, focused != target else { return }
            focused = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if focused != target { land(on: target, attempt: attempt + 1, token: token) }
            }
        }
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("FocusRow")
        #endif
        VStack(alignment: .leading, spacing: Metrics.headerToCards - verticalPadding) {
            if let title {
                SectionHeader(title: title, iconURL: iconURL, trailing: trailing)
                    .padding(.horizontal, Metrics.margin)
                    // Rows that carry a "See All" capsule measured 11 pt taller
                    // than the ones without, so every kind of row below the first
                    // could shift as it arrived. One header height for all.
                    .frame(minHeight: 40, alignment: .center)
                    .zIndex(1)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            card(item, i)
                                .focused($focused, equals: item.id)
                                .id(item.id)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                                    frames.set(item.id, f, router: focusRouter)
                                }
                        }
                        if let onSeeAll {
                            Button(action: onSeeAll) { SeeAllTile(size: seeAllSize) }
                                .buttonStyle(FlatCardStyle(lift: 1.06))
                                .focused($focused, equals: Self.seeAllID)
                                .id(Self.seeAllID)
                        }
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.top, verticalPadding)
                    .padding(.bottom, verticalPadding * 0.6)
                }
                .scrollClipDisabled()
                .onChange(of: focusRouter.resetRow) { _, r in
                    guard r?.rowID == rowKey, r?.tab == nil || r?.tab == tab, let first = items.first?.id else { return }
                    focused = first
                    withAnimation(Motion.pageScroll) { proxy.scrollTo(first, anchor: .leading) }
                }
            }
        }
        .focusSection()
        .onChange(of: focused) { _, id in
            #if DEBUG
            if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[row] \(rowKey) focused=\(id ?? "nil")") }
            #endif
            frames.focused = id
            guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return }
            focusRouter.noteFocus(tab: tab, rowID: rowKey, index: i)
            focusRouter.focusedMidX = frames.all[id]?.midX
            focusRouter.focusedFrame = frames.all[id]
            focusRouter.focusedItem = id
            onFocus?(items[i], i)
        }
        .onChange(of: focusRouter.landing) { _, l in
            #if DEBUG
            if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[row] \(rowKey) got landing \(l?.rowID ?? "nil")") }
            #endif
            guard let l, l.rowID == rowKey, l.tab == nil || l.tab == tab else { return }
            var target = items.first?.id
            if let i = l.index, items.indices.contains(i) {
                target = items[i].id
            } else if let x = l.x {
                // The visible card closest to x (Apple's vertical move).
                let visible = frames.all.filter { $0.value.maxX > 0 && $0.value.minX < 1920 }
                target = visible.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key ?? target
            }
            land(on: target, attempt: 0, token: l.token)
        }
    }
}

// MARK: - Continue Watching

struct ContinueWatchingRow: View {
    let items: [ContinueWatchingItem]
    let focus: HomeFocusModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var home: HomeSettingsStore

    var body: some View {
        FocusRow(rowKey: "cw", title: "Continue Watching", items: items, spacing: 40,
                 onFocus: { item, _ in
                     focus.focusedItem = item.meta
                     focus.focusedRowKey = "cw"
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { item, _ in
            let actions = PlayActions(router: router)
            let spoiler = home.value.hideSpoilers && item.isNextUp && item.fraction < 0.05
            Button { actions.resume(item) } label: {
                ContinueWatchingCard(item: item, spoilerBlur: spoiler, showCountdown: home.value.upcomingCountdown)
            }
            .buttonStyle(FlatCardStyle(lift: 1.06))
            .onPlayPauseCommand { actions.resume(item) }
            .modifier(ContinueWatchingHoldMenu(item: item,
                                               onPlayManually: { actions.playManually(item.meta, video: item.video) },
                                               onDetails: { actions.openDetail(item.meta) },
                                               onStartOver: { actions.resume(item, fromStart: true) }))
        }
    }
}

// MARK: - Featured strip

struct FeaturedRow: View {
    let items: [MetaItem]
    let focus: HomeFocusModel
    @EnvironmentObject private var router: Router

    var body: some View {
        FocusRow(rowKey: "featured", title: "Featured", items: items, spacing: 40,
                 onFocus: { item, _ in
                     focus.focusedItem = item
                     focus.focusedRowKey = "featured"
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { item, _ in
            let actions = PlayActions(router: router)
            Button { actions.openDetail(item, siblings: items) } label: {
                TallFeatureCard(meta: item, badge: item.isUnreleased ? "Coming Soon" : nil)
            }
            .buttonStyle(FlatCardStyle(lift: 1.05))
            .onPlayPauseCommand { actions.playManually(item) }
            .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
        }
    }
}

// MARK: - Catalog row

struct CatalogRow: View {
    let row: HomeRow
    let numbered: Bool
    let focus: HomeFocusModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("CatalogRow")
        #endif
        let landscape = home.value.landscapePosters
        let labels = home.value.posterLabels
        FocusRow(rowKey: row.id, title: row.descriptor.title, iconURL: row.descriptor.addonLogo,
                 onSeeAll: seeAll, seeAllSize: landscape ? CGSize(width: 400, height: 225) : CGSize(width: 240, height: 360),
                 items: row.items,
                 onFocus: { item, _ in
                     focus.focusedItem = item
                     focus.focusedRowKey = row.id
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { item, i in
            let actions = PlayActions(router: router)
            Button { actions.openDetail(item, siblings: row.items) } label: {
                PosterCard(meta: item, width: landscape ? 400 : 240, landscape: landscape, showsLabel: labels && !numbered,
                           watched: !item.isSeries && watched.isWatched(item.id),
                           progress: progress.progress(for: item.id)?.fraction,
                           numeral: numbered ? i + 1 : nil)
            }
            .buttonStyle(FlatCardStyle())
            .onPlayPauseCommand { actions.playManually(item) }
            .posterHoldMenu(item) { actions.openDetail(item, siblings: row.items) }
        }
    }

    private var seeAll: (() -> Void)? {
        guard case .catalog(let url, let type, let catID) = row.descriptor.kind,
              let addon = AppStores.shared.addons.addons.first(where: { $0.manifestURL == url }),
              let cat = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == catID }) else { return nil }
        return { router.push(.catalogSeeAll(addonURL: url, catalog: cat, title: row.descriptor.title)) }
    }
}

// MARK: - Collections

struct FolderTile: View {
    let folder: CollectionFolder
    @Environment(\.isFocused) private var focused
    @EnvironmentObject private var home: HomeSettingsStore
    /// The focus artwork has decoded and is showing over the cover.
    @State private var artReady = false

    var size: CGSize {
        switch folder.tileShape.uppercased() {
        case "POSTER": return CGSize(width: 220, height: 330)
        case "LANDSCAPE": return CGSize(width: 400, height: 225)
        default: return CGSize(width: 260, height: 260)
        }
    }

    /// SQUARE covers are logo marks (streaming services, studios): fitted with
    /// a margin. Poster/landscape art fills the tile.
    private var isLogoMark: Bool { folder.tileShape.uppercased() != "POSTER" && folder.tileShape.uppercased() != "LANDSCAPE" }

    /// Reduce Motion keeps the art change on focus but stops it moving.
    private var artMode: FocusArtMode {
        let m = home.value.focusArt
        return PerformanceProfile.reduceMotion && m == .animated ? .still : m
    }

    var body: some View {
        Group {
            if let cover = folder.cover {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Palette.glassSolid)
                    RemoteImage(url: cover, maxPixel: ImageSize.landscape, contentMode: isLogoMark ? .fit : .fill, placeholder: false)
                        .padding(isLogoMark ? 36 : 0)
                        .frame(width: size.width, height: size.height)
                        .opacity(showArt ? 0 : 1)
                    focusArt(size)
                    if !folder.hideTitle {
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        Text(folder.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white).padding(16)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
            } else {
                let tile = gradientSize
                ZStack {
                    GradientTile(title: folder.hideTitle ? "" : folder.title, seed: folder.id,
                                 width: tile.width, height: tile.height, emoji: folder.coverEmoji)
                        .opacity(showArt ? 0 : 1)
                    focusArt(tile)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
            }
        }
        .onChange(of: focused) { _, f in if !f { artReady = false } }
    }

    private var showArt: Bool { focused && artReady }

    /// Covers-less square folders draw as a portrait gradient tile.
    private var gradientSize: CGSize { size.width == 260 ? CGSize(width: 220, height: 300) : size }

    /// Always mounted when the folder has art; dormant (nothing fetched or
    /// decoded) until focused, so a 100-folder row animates one tile.
    @ViewBuilder private func focusArt(_ size: CGSize) -> some View {
        if let art = folder.focusArt, artMode != .off {
            FocusArtView(url: art, still: artMode == .still, active: focused) { ok in
                withAnimation(.easeOut(duration: 0.22)) { artReady = ok && focused }
            }
            .frame(width: size.width, height: size.height)
            .opacity(showArt ? 1 : 0)
            .allowsHitTesting(false)
        }
    }
}

struct CollectionFoldersRow: View {
    let collection: OrivioCollection
    let rowKey: String
    let focus: HomeFocusModel
    @EnvironmentObject private var router: Router

    var body: some View {
        FocusRow(rowKey: rowKey, title: collection.title, items: collection.folders,
                 onFocus: { folder, _ in
                     let backdrop = folder.heroBackdropUrl ?? collection.backdropImageUrl ?? folder.cover
                     focus.focusedItem = MetaItem(id: "folder:\(folder.id)", type: "collection", name: folder.title,
                                                  background: backdrop, logo: folder.titleLogoUrl)
                     focus.focusedRowKey = rowKey
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { folder, _ in
            Button { router.push(.collection("\(collection.id)#\(folder.id)")) } label: { FolderTile(folder: folder) }
                .buttonStyle(FlatCardStyle())
        }
    }
}

struct CollectionsSharedRow: View {
    let rowKey: String
    let focus: HomeFocusModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        let list = collections.visible(for: profiles.active).filter { !$0.isRows && !$0.folders.isEmpty }
        FocusRow(rowKey: rowKey, title: "Collections", items: list,
                 onFocus: { c, _ in
                     focus.focusedItem = MetaItem(id: "collection:\(c.id)", type: "collection", name: c.title,
                                                  background: c.backdropImageUrl ?? c.folders.first?.cover)
                     focus.focusedRowKey = rowKey
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { c, _ in
            Button { router.push(.collection(c.id)) } label: {
                if let cover = c.backdropImageUrl ?? c.folders.first?.cover {
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(url: cover, maxPixel: ImageSize.landscape).frame(width: 400, height: 225)
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                        Text(c.title).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).padding(18)
                    }
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous))
                } else {
                    GradientTile(title: c.title, seed: c.id, width: 400, height: 225)
                }
            }
            .buttonStyle(FlatCardStyle(lift: 1.06))
        }
    }
}

/// A row's card frames — a reference box, so updating it never redraws.
/// The focused card's frame is forwarded to the router as it moves (the zoom
/// into Detail and Up/Down x-matching read it).
final class CardFrames {
    private(set) var all: [String: CGRect] = [:]
    var focused: String?

    @MainActor
    func set(_ id: String, _ frame: CGRect, router: ContentFocusRouter) {
        all[id] = frame
        if id == focused {
            router.focusedMidX = frame.midX
            router.focusedFrame = frame
            router.focusedItem = id
        }
    }
}


/// The row-end "See All" tile.
struct SeeAllTile: View {
    let size: CGSize
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.right")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 72, height: 72)
                .background(Circle().fill(focused ? Palette.focusInk.opacity(0.1) : Color.white.opacity(0.14)))
            Text("See All").font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(focused ? Palette.focusInk : .white)
        .frame(width: min(size.width, 220), height: size.height)
        .background {
            let shape = RoundedRectangle(cornerRadius: Metrics.posterRadius, style: .continuous)
            if focused { shape.fill(Color.white.opacity(0.9)) } else { GlassSurface(shape: shape) }
        }
    }
}
