import SwiftUI

/// The Detail page host: pages left/right between the titles of the row it was
/// opened from. Both pages are slid by hand — tvOS drops the removal transition
/// of a page that holds focus, so the old page used to vanish instantly.
struct DetailView: View {
    @Environment(\.pageWidth) private var pageWidth
    let meta: MetaItem
    var siblings: [MetaItem] = []
    @State private var current: MetaItem
    @State private var hasPaged = false
    /// The page sliding away (a non-interactive copy).
    @State private var outgoing: MetaItem?
    /// +1 = moving to the next title (new page comes in from the right).
    @State private var direction: CGFloat = 1
    /// 0 → 1 over a page change.
    @State private var progress: CGFloat = 1
    /// The card this page zooms out of (screen frame), while the zoom runs.
    @State private var zoomFrom: CGRect?
    @State private var zoom: CGFloat = 1
    @State private var didZoom = false
    /// The card's own image (already on screen) and the backdrop it becomes.
    @State private var zoomStart: UIImage?
    @State private var zoomEnd: UIImage?
    /// The current page's screen frame, and whether it's full screen (hero/sections).
    @State private var pageFrame: CGRect = .zero
    @State private var expanded = false
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @EnvironmentObject private var router: Router
    @Environment(\.currentTab) private var tab
    @Environment(\.railBleed) private var bleed

    init(meta: MetaItem, siblings: [MetaItem] = []) {
        self.meta = meta
        // Detail pages are single-title now: no left/right neighbours.
        self.siblings = []
        _current = State(initialValue: meta)
    }

    /// Outgoing (while sliding away) first, then the current page.
    /// Pages kept built beside the current one (off screen), so a flip only slides
    /// an existing page in. Changed only once a slide has finished — building the
    /// next neighbour and dropping the far one happen while nothing moves.
    @State private var resident: [String] = []

    private var pages: [MetaItem] {
        var ids = resident
        for m in [outgoing, current].compactMap({ $0 }) where !ids.contains(m.id) { ids.append(m.id) }
        return ids.compactMap { id in
            if id == current.id { return current }
            if id == outgoing?.id { return outgoing }
            return siblings.first { $0.id == id }
        }
    }

    private var index: Int? { siblings.firstIndex { $0.id == current.id } }
    private var previous: MetaItem? { neighbour(of: current, -1) }
    private var next: MetaItem? { neighbour(of: current, 1) }

    private func neighbour(of m: MetaItem, _ d: Int) -> MetaItem? {
        guard let i = siblings.firstIndex(where: { $0.id == m.id }), siblings.indices.contains(i + d) else { return nil }
        return siblings[i + d]
    }

    /// Where a resident page waits: one screen to the side of the current one.
    private func restingOffset(_ m: MetaItem) -> CGFloat {
        guard let i = siblings.firstIndex(where: { $0.id == m.id }), let c = index else { return pageWidth * 2 }
        return CGFloat(i - c) * pageWidth
    }

    /// Drops pages no longer beside the current one, then (a frame later, so the
    /// two costs don't stack) builds the missing neighbours.
    private func settleResidents() {
        guard outgoing == nil else { return }
        // Waiting pages each load a full-width backdrop. On constrained
        // hardware keep only the next one (memory and opening cost); high-tier
        // devices keep both neighbours for instant flips in either direction.
        let around = PerformanceProfile.isConstrained ? [current, next] : [previous, current, next]
        let ids = around.compactMap { $0?.id }
        guard ids != resident else { return }
        let kept = resident.filter { ids.contains($0) }
        if kept != resident { resident = kept }
        DispatchQueue.main.async {
            if outgoing == nil, ids.contains(current.id) { resident = ids }
        }
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("DetailView")
        #endif
        ZStack {
            // One background behind every page, crossfading between titles.
            ArtField(imageURL: current.background ?? current.poster).railBleed().ignoresSafeArea()
            if let from = zoomFrom {
                ZoomCard(start: zoomStart, end: zoomEnd, from: from, to: cardFrame, progress: zoom)
            }
            // The page being left keeps its identity and slides away itself (it
            // used to be replaced by a freshly built copy: a whole page built and
            // torn down again on every flip).
            ForEach(pages, id: \.id) { m in
                let isCurrent = m.id == current.id
                let isOutgoing = m.id == outgoing?.id
                DetailPage(meta: m, previous: neighbour(of: m, -1), next: neighbour(of: m, 1),
                           animateIn: !hasPaged && isCurrent,
                           zoomIn: isCurrent && !PerformanceProfile.isConstrained && (zoomFrom != nil || !didZoom),
                           active: isCurrent, onPage: isCurrent ? page : { _ in })
                    .equatable()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                        if isCurrent { pageFrame = f }
                    }
                    .offset(x: isCurrent ? direction * pageWidth * (1 - progress)
                                : (isOutgoing ? -direction * pageWidth * progress : restingOffset(m)))
                    // Waiting pages aren't drawn at all until they slide in.
                    .opacity(isCurrent || isOutgoing ? 1 : 0)
                    .disabled(!isCurrent)
                    .allowsHitTesting(isCurrent)
            }
        }
        .onPreferenceChange(DetailExpandedKey.self) { expanded = $0 }
        .onAppear {
            startZoom()
            resident = [current.id]
            // Neighbours once the open zoom and the first sections are done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settleResidents() }
        }
        .onExitCommand(perform: close)
    }

    /// The page card on screen (the art inside the card insets), or the whole
    /// screen once the page has gone full screen.
    private var cardFrame: CGRect {
        let p = pageFrame == .zero ? CGRect(x: 1920 - pageWidth, y: 0, width: pageWidth, height: 1080) : pageFrame
        if expanded { return CGRect(x: p.minX - bleed, y: p.minY, width: p.width + bleed, height: p.height) }
        let i = DetailPage.cardInsets
        return CGRect(x: p.minX + i.leading, y: p.minY + i.top,
                      width: p.width - i.leading - i.trailing, height: p.height - i.top - i.bottom)
    }

    /// Back: the page shrinks into the card it opened from — when that card is
    /// still where it was (this title, straight back to the tab's root).
    private func close() {
        let toRoot = (router.paths[tab]?.count ?? 0) <= 1
        // The page is being dismissed for real (not merely covered by Sources
        // or the player), so the next open is a fresh presentation and should
        // zoom in from its Home card again.
        DetailModelCache.shared.model(for: current).hasPresented = false
        if toRoot, current.id == meta.id, !PerformanceProfile.reduceMotion, !PerformanceProfile.isConstrained,
           let card = focusRouter.rootCardFrame(tab: tab, metaID: meta.id) {
            let end = zoomEnd ?? (current.background ?? current.poster).flatMap(URL.init(string:)).flatMap { ImagePipeline.shared.anyCached($0) }
            focusRouter.zoomBack = .init(tab: tab, start: zoomStart ?? cardImage(for: card), end: end, card: card, page: cardFrame)
        }
        router.pop()
        if router.isAtRoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusRouter.restore(tab: tab) }
        }
    }

    /// Opening: the selected card grows into the page card (≈ 0.6 s), then the
    /// page content fades in over it.
    private func startZoom() {
        guard !didZoom else { return }
        didZoom = true
        // The page is rebuilt whenever a route above it pops (Back from
        // Sources/the player). Only the FIRST presentation is an opening —
        // replaying the zoom there made the page fly out of the Home card
        // again, over the episode the viewer had just been watching.
        let model = DetailModelCache.shared.model(for: meta)
        let firstPresentation = !model.hasPresented
        model.hasPresented = true
        // On constrained hardware the full-screen zoom card adds another
        // 1920-wide image decode and composite on top of the page's own artwork.
        guard firstPresentation, !PerformanceProfile.isConstrained,
              let f = focusRouter.cardFrame(for: meta.id), f.width > 40, f.height > 40,
              !PerformanceProfile.reduceMotion else { return }
        zoomStart = cardImage(for: f)
        if let endURL = (current.background ?? current.poster).flatMap(URL.init(string:)) {
            if let hit = ImagePipeline.shared.anyCached(endURL), hit.size.width >= 1000 {
                zoomEnd = hit
            } else {
                Task { zoomEnd = await ImagePipeline.shared.image(endURL, maxPixel: ImageSize.backdrop) }
            }
        }
        zoomFrom = f
        zoom = 0
        DispatchQueue.main.async {
            withAnimation(Motion.pageOpen) { zoom = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { zoomFrom = nil }
        }
    }

    /// The image the card was showing: wide cards show the backdrop, posters the poster.
    private func cardImage(for card: CGRect) -> UIImage? {
        let wide = card.width > card.height
        let url = (wide ? (current.background ?? current.poster) : (current.poster ?? current.background)).flatMap(URL.init(string:))
        return url.flatMap { ImagePipeline.shared.anyCached($0) }
    }

    private func page(_ delta: Int) {
        guard let i = index, outgoing == nil else { return }
        let j = i + delta
        guard siblings.indices.contains(j) else { return }
        hasPaged = true
        // The focused card goes with the old page: keep focus off the rail meanwhile.
        focusRouter.holdNav?()
        direction = delta > 0 ? 1 : -1
        outgoing = current
        progress = 0
        current = siblings[j]
        DispatchQueue.main.async {
            withAnimation(Motion.pageSlide) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { outgoing = nil }
            // Neighbours of the new title once its sections are in (still on it).
            let landed = current.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if current.id == landed { settleResidents() }
            }
        }
    }
}

enum DetailFocus: Hashable {
    /// `card` = the page card itself (bordered, swipe between titles).
    case card, play, startOver, library, info, more, shuffle
}

struct DetailPage: View, Equatable {
    /// Inputs only (the page's own state and stores update it as usual): the
    /// host redraws several times per flip, and each re-ran both pages' bodies.
    /// `onPage` reads the host's state when called, so an older copy is fine.
    nonisolated static func == (a: DetailPage, b: DetailPage) -> Bool {
        a.metaID == b.metaID && a.previous?.id == b.previous?.id && a.next?.id == b.next?.id
            && a.animateIn == b.animateIn && a.zoomIn == b.zoomIn && a.active == b.active
    }

    @Environment(\.pageWidth) private var pageWidth
    @Environment(\.railBleed) private var bleed
    let previous: MetaItem?
    let next: MetaItem?
    /// The zoom-in on first open; paging between titles only slides.
    let animateIn: Bool
    /// The host is zooming a card into place: the content fades in over it.
    var zoomIn = false
    /// False for the copy that slides away while paging (no focus, no trailer).
    var active: Bool = true
    let onPage: (Int) -> Void
    private let metaID: String

    @StateObject private var model: DetailModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @Environment(\.theme) private var theme
    @Environment(\.currentTab) private var tab
    @Environment(\.navHasFocus) private var navHasFocus

    @FocusState private var focus: DetailFocus?
    /// card: bordered page with neighbours peeking (Left/Right pages) ·
    /// hero: full screen, buttons focused · sections: scrolled down into the page.
    enum Mode: Equatable { case card, hero, sections }
    @State private var mode: Mode
    private var inSections: Bool { mode == .sections }
    private var isCard: Bool { mode == .card }
    @State private var showInfo = false
    @State private var showMore = false
    @State private var showRating = false
    @State private var fullTrailer = false
    @State private var trailerVisible = false
    @State private var swipeHint = false
    @State private var appeared: Bool
    /// Sections build after the zoom/slide settles, keeping the motion light.
    /// The sliding-away copy never builds them.
    @State private var sectionsReady: Bool
    /// Bumped whenever the page gains or loses `active` (delayed work checks it).
    @State private var activation = 0
    @StateObject private var video = BackgroundVideoController()

    /// The hero page card's frame on screen (full width, no side rail).
    static let cardRect = CGRect(x: 90, y: 40, width: 1740, height: 980)
    static let cardInsets = EdgeInsets(top: 40, leading: 90, bottom: 60, trailing: 90)

    init(meta: MetaItem, previous: MetaItem?, next: MetaItem?, animateIn: Bool = true, zoomIn: Bool = false,
         active: Bool = true, onPage: @escaping (Int) -> Void) {
        self.active = active
        self.metaID = meta.id
        self.zoomIn = zoomIn
        let cached = DetailModelCache.shared.model(for: meta)
        _model = StateObject(wrappedValue: cached)
        self.previous = previous
        self.next = next
        self.animateIn = animateIn
        self.onPage = onPage
        _appeared = State(initialValue: !animateIn)
        // Returning from Sources/the player: build straight into the sections
        // so the page never flashes its hero and then scrolls down.
        let returning = cached.pendingReturnFocus != nil
        _mode = State(initialValue: returning ? .sections : .hero)
        _sectionsReady = State(initialValue: returning)
    }

    private var meta: MetaItem { model.meta }
    private var stores: AppStores { AppStores.shared }

    /// Auto-select is "on" when pressing Play would skip the list.
    private var autoSelectOn: Bool {
        profiles.active.autoLink.enabled || playerSettings.value.autoPlayBestSource || playerSettings.value.reuseLastLink
    }

    private var playTarget: (video: MetaVideo?, progress: WatchProgress?) {
        if meta.isSeries {
            if let t = ContinueWatchingBuilder.playTarget(meta: meta, watched: watched, progress: progress, home: home.value) { return (t.0, t.1) }
            return (nil, nil)
        }
        return (nil, progress.progress(for: meta.id))
    }

    /// Where the first section's header sits while it peeks under the hero.
    private static let sectionsPeekTop: CGFloat = 1028
    /// The logo at the top of the sections — part of the page, it scrolls away.
    private static let logoHeader: CGFloat = 230

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("DetailPage")
        #endif
        ZStack(alignment: .top) {
            // Hero: art card + text + buttons. Moving down is one continuous
            // motion: the card widens to full screen and its art fades into the
            // colour field, the text scrolls up and away, the sections rise.
            hero
                .disabled(inSections)

            // Sections (with the logo at their top): peek under the hero, then
            // rise as one page. No pinned header — it all scrolls together.
            sectionsLayer
                .padding(.top, sectionsTopPadding)
                .disabled(!inSections)
        }
        .pageFrame(alignment: .top)
        .preference(key: DetailExpandedKey.self, value: active && !isCard)
        .animation(Motion.detailScroll, value: mode)
        // Trackpad swipes between the hero and the sections (clicks arrive
        // through the buttons' and sections' `.onMoveCommand`).
        .onVerticalSwipeMove(enabled: active && !navHasFocus, perform: swipeMoved)
        .ignoresSafeArea()
        .scaleEffect(appeared || zoomIn ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if animateIn {
                if zoomIn {
                    // Over the zooming card: fade in as it settles.
                    withAnimation(.easeOut(duration: 0.35).delay(0.55)) { appeared = true }
                } else {
                    withAnimation(Motion.pageOpen) { appeared = true }
                }
            }
            if active { activate() }
        }
        .task(id: active) {
            guard active else { return }
            await model.load()
            // Get the neighbours ready so paging to them is instant.
            let neighbours = PerformanceProfile.isConstrained ? [next] : [previous, next]
            DetailModelCache.shared.prefetch(neighbours.compactMap { $0 })
        }
        .task(id: trailerKey) { if active { await runBackgroundTrailer() } }
        .onChange(of: playerSettings.value.detailTrailerDelay) { _, delay in
            if delay < 0 { stopTrailer() }
        }
        // Waiting beside the current page: have its trailer ready for a flip.
        .task(id: "\(active)|\(model.trailerKeys.first ?? "")") {
            if !active, !PerformanceProfile.isConstrained,
               playerSettings.value.detailTrailerDelay >= 0, !model.trailerKeys.isEmpty {
                TrailerService.prefetch(model.trailerKeys)
            }
        }
        .onDisappear {
            video.stop()
            model.stopPreview()
            if active { focusRouter.blockNav?(false) }
        }
        .onChange(of: active) { _, now in
            activation += 1
            if now {
                // A page built beside the current one, now sliding in.
                activate()
            } else {
                // Paged away from: it slides out as is, silent and out of focus,
                // and lets its sections go once off screen (on their own beat, so
                // dropping the page later is light).
                stopTrailer()
                model.stopPreview()
                let gen = activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if activation == gen { sectionsReady = false }
                }
            }
        }
        .onChange(of: model.loaded) { _, loaded in
            if loaded, active, sectionsReady, (!PerformanceProfile.isConstrained || inSections) {
                model.startSourcePreview(video: playTarget.video)
            }
        }
        // The player cover is up while the page is rebuilt underneath it
        // (auto-launch pops Sources at 0.8 s). A focus request under a
        // fullScreenCover is dropped, so finish the return once it closes.
        .onChange(of: presenter.isPresenting) { _, presenting in
            if !presenting, active, model.pendingReturnFocus != nil { restoreReturnFocus() }
        }
        .sheet(isPresented: $showInfo) { InfoPopover(meta: meta, model: model) }
        .fullScreenCover(isPresented: $showRating) {
            RatingPicker(title: meta.name, current: stores.ratings.rating(for: meta.id)) { value in
                stores.ratings.set(value, for: meta.id)
                showRating = false
                toasts.show(value == nil ? "Rating Cleared" : "Rating Saved", systemImage: "star.fill")
            } onCancel: { showRating = false }
        }
        .fullScreenCover(isPresented: $fullTrailer) {
            TrailerFullScreen(keys: model.trailerKeys) { fullTrailer = false }
                .ignoresSafeArea()
                .onExitCommand { fullTrailer = false }
        }
        .fullScreenCover(isPresented: $showMore) {
            MoreMenu(items: moreItems) { showMore = false }
                .presentationBackground(.clear)
        }
    }

    /// Becoming the current page: focus, then (once rested on) the sections.
    private func activate() {
        // Back from Sources/the player: the page was rebuilt, and its focus
        // belongs on the episode the viewer entered — not on Play.
        if model.pendingReturnFocus != nil {
            restoreReturnFocus()
            return
        }
        focusPlay(attempt: 0)
        #if DEBUG
        let noSections = CommandLine.arguments.contains("-noDetailSections")
        #else
        let noSections = false
        #endif
        // Only once the page has been rested on: flicking through titles never
        // pays for sections (~0.5 s of building per title on an A10X).
        guard !sectionsReady, !noSections else { return }
        let gen = activation
        let settle = PerformanceProfile.isConstrained ? 1.2 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard activation == gen else { return }
            withAnimation(.easeOut(duration: 0.25)) { sectionsReady = true }
            // The source search scans every add-on. On constrained hardware
            // keep it off the opening path and start it when the user scrolls
            // into the sections instead.
            if model.loaded, !PerformanceProfile.isConstrained { model.startSourcePreview(video: playTarget.video) }
        }
    }

    /// Put the rebuilt page back where the viewer left it: the sections, the
    /// season of the episode they entered, and focus on that exact card.
    ///
    /// The page is destroyed when Sources is pushed over it, so without this
    /// Back rebuilt it in hero mode and focus jumped to the top of the page
    /// (the reported "Back loses my episode").
    private func restoreReturnFocus() {
        guard let target = model.pendingReturnFocus else { return }
        if let season = target.season, meta.seasons.contains(season), model.selectedSeason != season {
            model.selectedSeason = season
            Task { await model.loadSeasonInfo(season) }
        }
        sectionsReady = true
        if mode != .sections { mode = .sections }
        if model.loaded { model.startSourcePreview(video: playTarget.video) }
        // While the player cover is up the focus request is refused; the
        // `presenter.isPresenting` observer above runs this again on close.
        guard !presenter.isPresenting else { return }
        model.clearReturnFocus()
        let started = Date()
        let row = target.rowID
        let index = target.index
        focusRouter.land(row: row, index: index, tab: tab)
        // The sections (and their FocusRow) may be built a frame or two after
        // this call — a landing published before the row exists is never seen.
        // Ask again while the viewer hasn't moved focus themselves.
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard active, mode == .sections, focusRouter.lastFocusAt < started else { return }
                focusRouter.land(row: row, index: index, tab: tab)
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") {
            DebugLog.write("[detail] return focus \(row)[\(index)] season=\(target.season.map(String.init) ?? "-")")
        }
        #endif
    }

    private var sectionsTopPadding: CGFloat {
        inSections ? 0 : Self.sectionsPeekTop - Self.logoHeader
    }

    private var sectionsLayer: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 1).id("sectionsTop")
                LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 420, height: 130), alignment: .center,
                            fallbackStyle: .sectionHeader)
                    .frame(height: 150)
                    .padding(.top, 50)
                    .padding(.bottom, Self.logoHeader - 200)
                    .frame(maxWidth: .infinity)
                    .opacity(inSections ? 1 : 0)
                    .allowsHitTesting(false)
                if sectionsReady {
                    DetailSections(model: model, autoSelectOn: autoSelectOn)
                        .onMoveCommand { dir in
                            VerticalMoveRelay.shared.notePress(dir)
                            if dir == .up { upFromSections() }
                        }
                        .transition(.opacity)
                }
                Spacer().frame(height: 160)
            }
        }
        .scrollClipDisabled(!inSections)
        .frame(height: 1080 - sectionsTopPadding, alignment: .top)
        // Entering: the page starts at its top, logo showing above the first row.
        .onChange(of: inSections) { _, now in
            guard now else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(Motion.detailScroll) { proxy.scrollTo("sectionsTop", anchor: .top) }
            }
        }
        }
    }

    /// Up leaves the sections only when it's pressed on the top row and focus had
    /// nowhere to go. The press is reported just *after* a successful move, so
    /// "focus changed within 0.12 s around the press" means it was a real move.
    private func upFromSections() {
        let pressed = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard inSections, abs(focusRouter.lastFocusAt.timeIntervalSince(pressed)) > 0.12,
                  focusRouter.lastFocusAt < pressed else { return }
            let top = Set(["seasons", firstSectionRow].compactMap { $0 })
            if let row = focusRouter.lastRow[tab], top.contains(row) { exitSections() }
        }
    }

    /// A swipe that found nothing focusable — the moves a click makes by hand.
    /// Up only fails in the sections on their top row (the scroll view moves
    /// focus everywhere else), so that failure is the way back to the hero.
    private func swipeMoved(_ dir: MoveCommandDirection) {
        switch (dir, inSections) {
        case (.down, false):
            guard !isCard, focus != nil else { return }
            enterSections()
        case (.up, false):
            if focus != nil, trailerVisible { fullTrailer = true; stopTrailer() }
        case (.up, true):
            let top = Set(["seasons", firstSectionRow].compactMap { $0 })
            if let row = focusRouter.lastRow[tab], top.contains(row) { exitSections() }
        default:
            break
        }
    }

    /// The first row in the sections (where Down from the hero lands).
    private var firstSectionRow: String? {
        let seasons = meta.seasons
        if meta.isSeries, !seasons.isEmpty {
            let season = seasons.contains(model.selectedSeason) ? model.selectedSeason : seasons[0]
            return "episodes-\(season)"
        }
        if !model.trailerKeys.isEmpty { return "trailers" }
        if !model.collectionParts.isEmpty { return "collection" }
        if !(model.enrichment?.recommendations.isEmpty ?? true) { return "related" }
        if !model.cast.isEmpty { return "cast" }
        if !model.previewSources.isEmpty { return "sources" }
        return nil
    }

    private func enterSections() {
        guard !inSections, let row = firstSectionRow else { return }
        sectionsReady = true
        if model.loaded { model.startSourcePreview(video: playTarget.video) }
        stopTrailer()
        withAnimation(Motion.detailScroll) { mode = .sections }
        // Enable the sections first, then land on the first row — again a moment
        // later if that row was still waiting for its build stage.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusRouter.land(row: row, x: nil, tab: tab) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if inSections, focusRouter.lastRow[tab] != row { focusRouter.land(row: row, x: nil, tab: tab) }
        }
    }

    private func exitSections() {
        guard inSections else { return }
        withAnimation(Motion.detailScroll) { mode = .hero }
        focusPlay(attempt: 0)
    }

    /// The hero re-enables as it slides back; a focus request made before that is
    /// dropped, so keep asking briefly until focus is really on Play.
    private func focusPlay(attempt: Int) {
        guard attempt < 8, mode == .hero else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.1)) {
            guard focus != .play else { return }
            focus = .play
            focusPlay(attempt: attempt + 1)
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // Neighbouring titles peek at the edges while the page is a card.
            HStack {
                peek(previous).offset(x: isCard ? -50 : -240)
                Spacer()
                peek(next).offset(x: isCard ? 50 : 240)
            }
            .padding(.top, Self.cardInsets.top)
            .padding(.bottom, Self.cardInsets.bottom)
            .opacity(isCard && appeared ? 1 : 0)

            // The art: a bordered card, full screen once the buttons have focus.
            ZStack {
                Color.black
                // Sized by the card, never by the art's own aspect.
                RemoteImage(url: meta.background ?? meta.poster, maxPixel: ImageSize.backdrop, placeholder: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(trailerVisible ? 0 : 1)
                // The sliding-away copy never plays: no player (and no AVPlayer made).
                if active, video.hasPlayer { BackgroundVideoView(player: video.player).opacity(trailerVisible ? 1 : 0) }
                ArtworkScrims(bottomFraction: 0.55, bottomOpacity: 0.75)
            }
            .animation(.easeInOut(duration: 0.6), value: trailerVisible)
            .clipShape(RoundedRectangle(cornerRadius: isCard ? Metrics.pageCardRadius : 0, style: .continuous))
            .padding(isCard ? Self.cardInsets : EdgeInsets())
            // Full screen, it reaches under the side rail too.
            .frame(width: pageWidth + (isCard ? 0 : bleed), height: 1080)
            .padding(.leading, isCard ? 0 : -bleed)
            // Fades into the colour field behind as the page moves down.
            .opacity(inSections ? 0 : 1)

            if swipeHint, !inSections {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.compact.up").font(.system(size: 26, weight: .bold))
                    Text("Swipe Up for Playback Controls").font(.system(size: 19)).foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 70)
                .transition(.opacity)
            }

            // Low in the card (buttons ≈ 80 % down), as in the TV app.
            Group {
                heroText
                    .padding(.leading, isCard ? 130 : Metrics.margin)
                    .padding(.bottom, 1080 - 965)
                credits
                    .frame(maxWidth: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, isCard ? 130 : Metrics.margin)
                    .padding(.bottom, 1080 - 930)
            }
            // Scrolls up with the page, by as much as the sections rise.
            .offset(y: inSections ? -(Self.sectionsPeekTop - Self.logoHeader) : 0)
            // Gone before the rising sections reach it, back only once they've
            // dropped away: fading at the scroll's pace drew the synopsis and
            // buttons over the first rows mid-move.
            // (Scoped to the opacity: the offset keeps the page's scroll spring.)
            .animation(inSections ? .easeOut(duration: 0.16) : .easeIn(duration: 0.28).delay(0.22)) {
                $0.opacity(inSections ? 0 : 1)
            }
        }
        .frame(width: pageWidth, height: 1080)
    }

    @ViewBuilder private func peek(_ item: MetaItem?) -> some View {
        if let item, !PerformanceProfile.isConstrained {
            RemoteImage(url: item.background ?? item.poster, maxPixel: 600)
                .frame(width: 100, height: Self.cardRect.height)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                .opacity(0.6)
        }
    }

    private var heroText: some View {
        let target = playTarget
        return VStack(alignment: .leading, spacing: 14) {
            if let badge = badgeText(target) { BadgePill(text: badge) }
            LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 480, height: 160))
            HStack(spacing: 12) {
                Text(([meta.typeLabel] + meta.genres.prefix(3)).joined(separator: " · ")).textStyle(.meta)
                if let cert = model.certification { OutlinedBadge(text: cert) }
            }
            if let d = meta.description, !d.isEmpty {
                Text(d).textStyle(.body).lineLimit(4).frame(maxWidth: 760, alignment: .leading)
            }
            metaLine2
            actionRow(target)
            if let caption = caption(target) {
                Text(caption).textStyle(.caption, color: Palette.textTertiary)
            }
        }
    }

    private var metaLine2: some View {
        var parts: [String] = []
        if let y = meta.year { parts.append(y) }
        if let r = model.runtimeMinutes { parts.append(MetaItem.formatMinutes(r)) }
        let rt = model.ratings.first { $0.source == "tomatoes" }
        return HStack(spacing: 14) {
            MetaLine(parts: parts, rating: meta.imdbRating)
            if let rt { Label(rt.value, systemImage: "leaf.fill").font(TypeStyle.meta.font).foregroundStyle(Palette.textSecondary) }
            ForEach(model.sourceBadges, id: \.self) { OutlinedBadge(text: $0) }
        }
    }

    private func actionRow(_ target: (video: MetaVideo?, progress: WatchProgress?)) -> some View {
        let resumable = target.progress?.isResumable ?? false
        let inLibrary = library.contains(meta.id)
        return HStack(spacing: 18) {
            Button { play(target, fromStart: false) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 24, weight: .bold))
                    Text(playLabel(target, resumable: resumable)).lineLimit(1)
                }
            }
            .buttonStyle(PrimaryCapsuleStyle(minWidth: 260))
            .focused($focus, equals: .play)
            .modifier(PlayHoldMenu(enabled: autoSelectOn, meta: meta, video: target.video))
            if resumable {
                CircleButton(systemImage: "gobackward") { play(target, fromStart: true) }
                    .focused($focus, equals: .startOver)
            }
            CircleButton(systemImage: inLibrary ? "checkmark" : "plus") {
                let added = library.toggle(meta)
                toasts.show(added ? "Added to Library" : "Removed from Library", systemImage: added ? "plus.circle.fill" : "minus.circle.fill")
            }
            .focused($focus, equals: .library)
            CircleButton(systemImage: "info") { showInfo = true }
                .focused($focus, equals: .info)
            if meta.isSeries {
                CircleButton(systemImage: "dice") { shuffle() }
                    .focused($focus, equals: .shuffle)
            }
            CircleButton(systemImage: "ellipsis") { showMore = true }
                .focused($focus, equals: .more)
        }
        // Shown but not focusable while the page is a card (Down selects Play).
        .disabled(isCard)
        .padding(.top, 8)
        // Fires only when the engine's own move fails (nothing focusable there).
        .onMoveCommand { dir in
            VerticalMoveRelay.shared.notePress(dir)
            if dir == .up, trailerVisible { fullTrailer = true; stopTrailer() }
            if dir == .down { enterSections() }
        }
    }

    private var credits: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let starring = model.cast.prefix(3).map(\.name)
            if !starring.isEmpty {
                Text("Starring " + starring.joined(separator: ", ")).textStyle(.meta).multilineTextAlignment(.trailing)
            }
            if !model.directors.isEmpty {
                Text("Director " + model.directors.prefix(2).joined(separator: ", ")).textStyle(.meta)
            }
        }
        .lineLimit(2)
        .frame(maxWidth: 620, alignment: .trailing)
        .allowsHitTesting(false)
    }

    private func playLabel(_ t: (video: MetaVideo?, progress: WatchProgress?), resumable: Bool) -> String {
        if let v = t.video { return (resumable ? "Resume " : "Play ") + v.seasonEpisodeCode }
        return resumable ? "Resume" : "Play"
    }

    private func caption(_ t: (video: MetaVideo?, progress: WatchProgress?)) -> String? {
        if let p = t.progress, p.isResumable { return "Resumes at \(PlayerTime.format(p.position))" }
        if meta.isSeries, let v = t.video, watched.watchedEpisodes(of: meta.id).count > 0 { return "Next: \(v.seasonEpisodeCode)" }
        return nil
    }

    private func badgeText(_ t: (video: MetaVideo?, progress: WatchProgress?)) -> String? {
        if let p = t.progress, p.isResumable, let v = t.video { return "Resume \(v.seasonEpisodeCode)" }
        return model.badgeText
    }

    /// Dice: random aired episodes, one after another, until stopped (the
    /// player keeps a per-session shuffle order and always counts down Up Next).
    private func shuffle() {
        let aired = meta.orderedEpisodes.filter(\.hasAired)
        let unwatched = aired.filter { !watched.isWatched($0.id) }
        guard let pick = (unwatched.isEmpty ? aired : unwatched).randomElement() else {
            toasts.show("No episodes to shuffle yet", systemImage: "dice")
            return
        }
        stopTrailer()
        model.rememberReturnFocus(video: pick)
        toasts.show("Shuffling \(meta.name)", systemImage: "dice.fill")
        router.push(.streams(StreamsRequest(meta: meta, video: pick, mode: .shuffle)))
    }

    private func play(_ t: (video: MetaVideo?, progress: WatchProgress?), fromStart: Bool) {
        stopTrailer()
        model.rememberReturnFocus(video: t.video)
        let resumable = t.progress?.isResumable ?? false
        let mode: StreamsMode = fromStart ? (resumable ? .resume(fromStart: true) : .fromStart) : (resumable ? .resume(fromStart: false) : .normal)
        router.push(.streams(StreamsRequest(meta: meta, video: t.video, mode: mode)))
    }

    // MARK: More menu

    private var moreItems: [MoreMenu.Item] {
        var items: [MoreMenu.Item] = []
        let target = playTarget
        if !meta.isSeries {
            let w = watched.isWatched(meta.id)
            items.append(.init(title: w ? "Mark as Unwatched" : "Mark as Watched", systemImage: w ? "eye.slash" : "eye") {
                if w { watched.markUnwatched(meta: meta) } else { watched.markWatched(meta: meta) }
                toasts.show(w ? "Marked as Unwatched" : "Marked as Watched", systemImage: "eye")
            })
        } else {
            let all = watched.isWatched(meta: meta)
            items.append(.init(title: all ? "Mark Show Unwatched" : "Mark Show Watched", systemImage: "eye") {
                if all { watched.markUnwatched(meta: meta) } else { watched.markWatched(meta: meta) }
                toasts.show(all ? "Marked as Unwatched" : "Marked as Watched", systemImage: "eye")
            })
        }
        items.append(.init(title: "Rate…", systemImage: "star") { showRating = true })
        if !model.trailerKeys.isEmpty {
            items.append(.init(title: "Play Trailer", systemImage: "film") { stopTrailer(); fullTrailer = true })
        }
        if meta.isSeries {
            items.append(.init(title: "Shuffle Episodes", systemImage: "dice") { shuffle() })
        }
        items.append(.init(title: "Play Manually", systemImage: "list.bullet") {
            model.rememberReturnFocus(video: target.video)
            router.push(.streams(StreamsRequest(meta: meta, video: target.video, mode: .manual)))
        })
        if ExternalPlayers.infuseInstalled {
            items.append(.init(title: "Play in Infuse", systemImage: "arrow.up.forward.app") {
                router.push(.streams(StreamsRequest(meta: meta, video: target.video, mode: .infuse)))
            })
        }
        if let cid = model.enrichment?.collectionID, let name = model.enrichment?.collectionName {
            items.append(.init(title: "Go to Collection", systemImage: "square.stack") {
                router.push(.tmdbCollection(cid, name))
            })
        }
        return items
    }

    // MARK: Background trailer

    private var trailerKey: String { "\(meta.id)|\(model.trailerKeys.first ?? "")|\(inSections)|\(active)|\(playerSettings.value.detailTrailerDelay)" }

    private func runBackgroundTrailer() async {
        #if DEBUG
        if CommandLine.arguments.contains("-noDetailTrailer") { return }
        #endif
        let delay = playerSettings.value.detailTrailerDelay
        #if DEBUG
        DebugLog.write("[trailer] \(meta.id) delay=\(delay) keys=\(model.trailerKeys.count) sections=\(inSections) active=\(active) reduceMotion=\(PerformanceProfile.reduceMotion)")
        #endif
        guard !PerformanceProfile.isConstrained,
              delay >= 0, !inSections, !model.trailerKeys.isEmpty, !presenter.isPresenting,
              !PerformanceProfile.reduceMotion else { return }
        // Look the stream up and buffer it DURING the delay (it used to start only
        // after it: the delay, then 1–3 s of YouTube lookup, then buffering).
        let began = Date()
        let readyAt = began.addingTimeInterval(Double(max(0, delay)))
        // …but not for titles flicked past on the way to another. On constrained
        // devices let the page, its artwork and its sections settle first.
        let lead = PerformanceProfile.isConstrained ? 1.8 : 0.8
        try? await Task.sleep(nanoseconds: UInt64(min(Double(delay), lead) * 1_000_000_000))
        guard !Task.isCancelled, !inSections else { return }
        let sound = home.value.trailerSound
        let src = await TrailerService.resolveFirst(model.trailerKeys, muted: !sound)
        #if DEBUG
        DebugLog.write(String(format: "[trailer] resolved=%@ after %.1f s cancelled=%@", src == nil ? "no" : "yes", Date().timeIntervalSince(began), Task.isCancelled ? "yes" : "no"))
        #endif
        guard let src, !Task.isCancelled else { return }
        video.loops = false
        video.setMuted(!sound)
        await video.play(source: src, key: meta.id, autoStart: false)
        let wait = readyAt.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard !Task.isCancelled, !inSections else { video.stop(); return }
        video.start()
        // Fade the art only once frames are actually moving (else: a black screen).
        var waited = 0
        while !video.isPlaying, waited < 40, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        #if DEBUG
        DebugLog.write(String(format: "[trailer] playing=%@ after %.1f s", video.isPlaying ? "yes" : "no", Date().timeIntervalSince(began)))
        #endif
        guard !Task.isCancelled, video.isPlaying else { video.stop(); return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        trailerVisible = true
        #if DEBUG
        DebugLog.write(String(format: "[trailer] visible %.1f s after landing (delay setting %d s)", Date().timeIntervalSince(began), delay))
        #endif
        withAnimation { swipeHint = true }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        withAnimation { swipeHint = false }
        // At the end the art fades back. A cancelled task (leaving the page,
        // opening sections, changing the setting) must also stop the video.
        while !Task.isCancelled, !video.didEnd { try? await Task.sleep(nanoseconds: 500_000_000) }
        if Task.isCancelled { stopTrailer(); return }
        trailerVisible = false
    }

    private func stopTrailer() {
        video.stop()
        trailerVisible = false
        swipeHint = false
    }
}

/// Hold on Play (only when auto-select is on): Play Manually · Play in Infuse.
/// The capsule's ≥ 260 pt width keeps tvOS from silently refusing the menu.
struct PlayHoldMenu: ViewModifier {
    let enabled: Bool
    let meta: MetaItem
    let video: MetaVideo?
    @EnvironmentObject private var router: Router

    func body(content: Content) -> some View {
        if enabled {
            StableContextMenu(content: content, key: "\(meta.id)|\(video?.id ?? "")") {
                Button {
                    DetailModelCache.shared.model(for: meta).rememberReturnFocus(video: video)
                    router.push(.streams(StreamsRequest(meta: meta, video: video, mode: .manual)))
                } label: {
                    Label("Play Manually", systemImage: "list.bullet")
                }
                if ExternalPlayers.infuseInstalled {
                    Button { router.push(.streams(StreamsRequest(meta: meta, video: video, mode: .infuse))) } label: {
                        Label("Play in Infuse", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        } else {
            content
        }
    }
}

enum PlayerTime {
    static func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// The live Detail page has left the bordered card (hero or sections).
struct DetailExpandedKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The selected card growing into the page card (poster crossfading to the
/// backdrop), or — run backwards — the page shrinking into its card. `from` and
/// `to` are screen (global) frames, so it lands right wherever it's drawn.
struct ZoomCard: View {
    let start: UIImage?
    let end: UIImage?
    let from: CGRect
    let to: CGRect
    let progress: CGFloat

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            card.position(x: frame.midX - origin.x, y: frame.midY - origin.y)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var frame: CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    private var card: some View {
        let f = frame
        let radius = Metrics.posterRadius + (Metrics.pageCardRadius - Metrics.posterRadius) * progress
        return ZStack {
            Color.black
            if let end {
                Image(uiImage: end).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: f.width, height: f.height)
                    .opacity(start == nil ? 1 : Double(progress))
            }
            if let start {
                Image(uiImage: start).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: f.width, height: f.height)
                    .opacity(end == nil ? 1 : Double(1 - progress))
            }
        }
        .frame(width: f.width, height: f.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: PerformanceProfile.isConstrained ? 8 : 30,
                y: PerformanceProfile.isConstrained ? 4 : 16)
    }
}
