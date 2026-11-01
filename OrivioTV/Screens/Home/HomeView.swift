import SwiftUI

/// Rotates the rolling hero every 18 s while idle and visible (never under Reduce Motion).
@MainActor
final class HeroRotation: ObservableObject {
    @Published var index = 0
    @Published var direction: Edge = .trailing
    var count = 0
    var paused = false
    var videoHoldUntil: Date?
    private var lastChange = Date()
    private var timer: Timer?
    var buttonFocusSince: Date?
    static let interval: TimeInterval = 18

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard count > 1, !paused, !PerformanceProfile.reduceMotion else { return }
        if let since = buttonFocusSince, Date().timeIntervalSince(since) < 3 { return }
        if let hold = videoHoldUntil, Date() < hold { return }
        guard Date().timeIntervalSince(lastChange) >= Self.interval else { return }
        step(1)
    }

    func step(_ delta: Int) {
        guard count > 0 else { return }
        direction = delta > 0 ? .trailing : .leading
        withAnimation(Motion.unlessReduced(Motion.heroPage)) {
            index = (index + delta + count) % count
        }
        lastChange = Date()
        videoHoldUntil = nil
    }

    func resetClock() { lastChange = Date() }
}

enum HomeHeroFocus: Hashable { case stepPrev, primary, info, next, stepNext }

struct HomeView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var liveTV: LiveTVSettingsStore
    @EnvironmentObject private var topBar: TopBarVisibility
    @EnvironmentObject private var appearance: AppearanceStore

    let scope: HomeScope
    @Environment(\.currentTab) private var tab
    /// False while the side menu covers the page (or the tab is hidden).
    @Environment(\.isEnabled) private var pageEnabled
    @Environment(\.navHasFocus) private var navHasFocus
    @StateObject private var model: HomeModel

    init(scope: HomeScope = .all) {
        self.scope = scope
        _model = StateObject(wrappedValue: HomeModel(scope: scope))
    }
    @StateObject private var focus = HomeFocusModel()
    @StateObject private var rotation = HeroRotation()
    @FocusState private var heroFocus: HomeHeroFocus?
    /// A scheduled landing, replaced when another row move arrives.
    @State private var rowLandWork: DispatchWorkItem?
    @State private var infoFor: MetaItem?
    /// A landing on the top of the page arrived before the hero or any row had
    /// loaded (a freshly opened Movies / Shows tab): it is carried out once they exist.
    @State private var topLandingPending = false
    /// Whether the hero's title/synopsis/buttons are drawn. Kept beside
    /// `focus.inRows` only so the two directions can be timed differently — see
    /// `onChange(of: focus.inRows)`.
    @State private var heroContentVisible = true

    private var stores: AppStores { AppStores.shared }
    private var layout: HeroLayout { home.value.heroLayout }
    private var showsRollingHero: Bool { layout != .pinnedFocus && !model.heroItems.isEmpty }
    /// Where a focused row's header sits: the poster is fully visible with the
    /// next row peeking below; rows above it are hidden.
    static let focusedRowTop: CGFloat = 540
    /// Only heights: the stack offset moves every row each frame, and storing
    /// positions rewrote this state (and rebuilt Home) throughout the scroll.
    @State private var rowTops: [String: CGFloat] = [:]
    /// The height of each kind of row, measured from a built one (see
    /// `placeholder`). The rows far from focus are drawn at this height instead
    /// of a guess, which used to be ~180 pt out and snap — visibly — half a
    /// second after the row arrived.
    @State private var kindHeight: [HomeRowKind: CGFloat] = [:]
    /// Each row's own last measured height, so coming back to a row is exact.
    @State private var rowMeasure: [String: CGFloat] = [:]
    /// The row the live window is centred on. It trails focus by the length of
    /// the scroll, so the row coming into range (off screen below/above) is
    /// built after the move's animation rather than in its first frames — unless
    /// focus has already reached the window's edge (fast presses).
    @State private var liveAnchor = 0
    @State private var anchorFollow: Task<Void, Never>?
    private var heroItem: MetaItem? {
        guard !model.heroItems.isEmpty else { return nil }
        return model.heroItems[min(rotation.index, model.heroItems.count - 1)]
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("HomeView")
        #endif
        ZStack(alignment: .top) {
            HomeBackdrop(focus: focus, spotlight: focus.spotlight, rotation: rotation, heroItems: model.heroItems, layout: layout,
                         headerBottom: focusedRowScreenTop - 30, heroVideo: home.value.heroVideo, trailerSound: home.value.trailerSound)
                .railBleed()
                .ignoresSafeArea()

            if case .loading(let label) = model.state, model.rows.isEmpty, model.continueWatching.isEmpty {
                OrivioLoadingView(label: label)
            } else if model.state == .failed {
                OrivioEmptyState(icon: "rectangle.stack.badge.minus", title: "Nothing to show",
                                 message: "None of your add-ons returned a catalog. Check your connection or add-ons, then try again.",
                                 actionTitle: "Try Again") { model.retry(stores: stores) }
            } else {
                content
            }
        }
        // The page is exactly the screen; the row stack overflows below it.
        .pageFrame(alignment: .top)
        .ignoresSafeArea()
        // Arriving with a row already focused (Back from the player or a page)
        // must not flash the hero's title over the rows.
        .onAppear { heroContentVisible = !focus.inRows }
        .modifier(dataLifecycle)
        // Start on the hero, not on whichever row happens to be ready first.
        .defaultFocus($heroFocus, .primary)
        .onChange(of: heroFocus) { old, f in heroFocusChanged(old, f) }
        .onChange(of: pageEnabled) { _, on in
            if !on { topLandingPending = false }
            // Hidden tabs stay mounted; their 2 s hero timers have nothing to do.
            rotation.paused = !on || focus.inRows
            if on { rotation.resetClock(); rotation.start() } else { rotation.stop() }
        }
        .onChange(of: focus.inRows) { _, inRows in
            rotation.paused = inRows || !pageEnabled
            topBar.visible = !inRows || focus.focusedRowKey == firstRowKey
            // The hero used to switch off/on in a single frame, so on the way
            // down the title vanished mid-slide and on the way up it appeared at
            // full brightness over a row that had barely moved. Out is quick
            // (the rows are already sliding over it); in waits for the stack to
            // mostly arrive, so the two layouts are not both on screen.
            if inRows {
                withAnimation(.easeOut(duration: 0.16)) { heroContentVisible = false }
            } else {
                withAnimation(.easeOut(duration: 0.26).delay(0.18)) { heroContentVisible = true }
            }
        }
        .onChange(of: focus.focusedRowKey) { _, key in
            topBar.visible = !focus.inRows || key == firstRowKey
        }
        .onChange(of: focusedIndex) { _, fi in followAnchor(fi ?? 0) }
        // A card size / label change (or another profile's settings) invalidates
        // every stored row height: the rows have to be measured again.
        .onChange(of: home.value) { _, _ in
            kindHeight = [:]
            rowMeasure = [:]
        }
        .onChange(of: focusRouter.landing) { _, l in
            #if DEBUG
            if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] landing onChange row=\(l?.rowID ?? "nil") inRows=\(focus.inRows) pending=\(String(describing: focus.pendingRowKey)) focused=\(String(describing: focus.focusedRowKey))") }
            #endif
            // Out of the nav / Back to a tab: the hero (or the top of a pinned page).
            guard let l, l.tab == nil || l.tab == tab else { return }
            // A page is pushed over Home: the landing is for that page, not us.
            guard router.paths[tab]?.isEmpty ?? true else { return }
            guard l.rowID == ContentFocusRouter.topRow else {
                // Back to a row further down (after a Detail page): position and
                // enable it first, or focus can't land there and the engine's own
                // pick (the first row) wins.
                if rowKeys.contains(l.rowID) {
                    focus.pendingRowKey = l.rowID
                    if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                }
                return
            }
            if showsRollingHero {
                withAnimation(Motion.pageScroll) { focus.inRows = false }
                focusHero(attempt: 0)
            } else if let first = rowKeys.first {
                focusRouter.land(row: first, x: nil, tab: tab)
            } else {
                topLandingPending = true
            }
        }
        // Trackpad swipes between the hero and the rows (clicks arrive through
        // the hero's and rows' `.onMoveCommand`).
        .onVerticalSwipeMove(enabled: pageEnabled && !navHasFocus && (router.paths[tab]?.isEmpty ?? true)) { dir in
            swipeMoved(dir)
        }
        .onChange(of: showsRollingHero) { _, on in if on { carryOutTopLanding() } }
        .onChange(of: rowKeys.first) { _, first in if first != nil { carryOutTopLanding() } }
        .onChange(of: infoFor) { _, m in
            if let m { InfoPresenter.shared.present(m); infoFor = nil }
        }
    }

    private func heroFocusChanged(_ old: HomeHeroFocus?, _ f: HomeHeroFocus?) {
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] heroFocus \(String(describing: old)) → \(String(describing: f)) inRows=\(focus.inRows)") }
        #endif
        // The invisible steps page only on a sideways move from the buttons;
        // focus arriving there from elsewhere (launch, Up) just goes to Primary.
        if f == .stepPrev { if old == .primary { rotation.step(-1) }; heroFocus = .primary }
        else if f == .stepNext { if old == .next { rotation.step(1) }; heroFocus = old == .next ? .next : .primary }
        if f != nil {
            focusRouter.noteFocus(tab: tab, rowID: ContentFocusRouter.topRow, index: 0)
            // The hero isn't a card: a page opened from it has nothing to zoom back into.
            focusRouter.focusedFrame = nil
            focusRouter.focusedItem = nil
            if rotation.buttonFocusSince == nil { rotation.buttonFocusSince = Date() }
            withAnimation(Motion.pageScroll) { focus.inRows = false }
            topBar.visible = true
        } else {
            rotation.buttonFocusSince = nil
        }
    }

    /// A focus request made while the hero is still sliding back in is dropped;
    /// keep asking briefly.
    private func followAnchor(_ target: Int) {
        anchorFollow?.cancel()
        guard target != liveAnchor else { return }
        if abs(target - liveAnchor) >= Self.liveRowRadius {
            liveAnchor = target
            return
        }
        anchorFollow = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if !Task.isCancelled { liveAnchor = target }
        }
    }

    /// A swipe up or down that found nothing focusable: the same move a click does.
    private func swipeMoved(_ dir: MoveCommandDirection) {
        if focus.inRows {
            guard let key = focus.pendingRowKey ?? focus.focusedRowKey else { return }
            moveRow(dir == .down ? 1 : -1, from: key)
        } else if dir == .down, heroFocus != nil {
            enterRowsFromHero()
        }
    }

    private func carryOutTopLanding() {
        guard topLandingPending, pageEnabled, router.paths[tab]?.isEmpty ?? true else { return }
        topLandingPending = false
        if showsRollingHero {
            withAnimation(Motion.pageScroll) { focus.inRows = false }
            focusHero(attempt: 0)
        } else if let first = rowKeys.first {
            focusRouter.land(row: first, x: nil, tab: tab)
        }
    }

    private func focusHero(attempt: Int) {
        guard attempt < 8 else { return }
        #if DEBUG
        if attempt == 0, CommandLine.arguments.contains("-traceFocus") { DebugLog.write("[home] focusHero tab=\(tab) atRoot=\(router.isAtRoot)") }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.1)) {
            guard heroFocus != .primary else { return }
            heroFocus = .primary
            focusHero(attempt: attempt + 1)
        }
    }

    private var dataLifecycle: HomeDataLifecycle {
        HomeDataLifecycle(model: model, rotation: rotation)
    }
}

/// Loading/refresh triggers for a Home page (split out to keep the body type-checkable).
struct HomeDataLifecycle: ViewModifier {
    @ObservedObject var model: HomeModel
    @ObservedObject var rotation: HeroRotation
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var collections: CollectionsStore
    private var stores: AppStores { AppStores.shared }

    func body(content: Content) -> some View {
        content
        .onAppear {
            model.loadIfNeeded(stores: stores)
            rotation.resetClock()
            rotation.start()
        }
        .onDisappear { rotation.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .orivioAddonsChanged)) { _ in model.loadIfNeeded(stores: stores) }
        .onReceive(NotificationCenter.default.publisher(for: .orivioProfileChanged)) { _ in model.retry(stores: stores) }
        .onChange(of: home.value) { _, _ in model.loadIfNeeded(stores: stores) }
        .onChange(of: collections.library) { _, _ in model.loadIfNeeded(stores: stores) }
        // Live from Settings → Layout: the "… to Watch After …" rows appear or
        // disappear without a relaunch (Home stays mounted behind Settings).
        .onChange(of: home.value.afterWatchingRows) { _, _ in
            Task { await model.refreshRecommendations(stores: stores) }
        }
        .onChange(of: progress.entries.count) { _, _ in model.refreshContinueWatching(stores: stores) }
        .onReceive(progress.$entries.debounce(for: .seconds(1.5), scheduler: RunLoop.main)) { _ in model.refreshContinueWatching(stores: stores) }
        .onReceive(watched.$items.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in model.refreshContinueWatching(stores: stores) }
        .onChange(of: model.heroItems.count) { _, n in
            rotation.resetClock()
            rotation.count = n
            if rotation.index >= n { rotation.index = 0 }
        }
    }
}

extension HomeView {
    private var firstRowKey: String? {
        if !model.continueWatching.isEmpty { return "cw" }
        return model.rows.first?.id
    }

    // MARK: Content

    /// Down out of the hero. The first row peeks below the focus engine's safe
    /// area on a TV, so the native move can fail even though it works in the
    /// simulator. Raise the stack first, then ask the row for its first card.
    private func enterRowsFromHero() {
        guard !focus.inRows, let first = rowKeys.first else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] enterRows first=\(first) heroFocus=\(String(describing: heroFocus))") }
        #endif
        let x = focusRouter.focusedMidX ?? 300
        focus.pendingRowKey = first
        withAnimation(Motion.pageScroll) { focus.inRows = true }
        let work = DispatchWorkItem { focusRouter.land(row: first, x: x, tab: tab) }
        rowLandWork?.cancel()
        rowLandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        watchPending(first, x: x)
    }

    /// A landing the engine never satisfied (a busy device dropped every retry)
    /// would leave `pendingRowKey` set: the layout then follows a row that holds
    /// no focus. Ask once more, then give the layout back to the real focus.
    private func watchPending(_ target: String, x: CGFloat) {
        for (delay, last) in [(0.9, false), (1.8, true)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard focus.pendingRowKey == target else { return }
                if last { focus.pendingRowKey = nil } else { focusRouter.land(row: target, x: x, tab: tab) }
            }
        }
    }

    /// Up/Down between rows, done by hand: the next row barely peeks (outside
    /// the safe area the focus engine searches) and rows above are hidden, so
    /// the engine can't make these moves itself. Lands on the card closest in x.
    private func moveRow(_ delta: Int, from key: String) {
        guard focus.inRows else { return }
        // A swipe can send several moves before the first one lands. Base each
        // on the row we're already moving to, not the one still holding focus.
        let base = focus.pendingRowKey ?? focus.focusedRowKey ?? key
        guard let i = rowKeys.firstIndex(of: base) else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] moveRow delta=\(delta) key=\(key) base=\(base) i=\(i) pending=\(String(describing: focus.pendingRowKey)) focused=\(String(describing: focus.focusedRowKey))") }
        #endif
        move(delta, from: i, x: focusRouter.focusedMidX ?? 300)
    }

    private func move(_ delta: Int, from i: Int, x: CGFloat) {
        let j = i + delta
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] move delta=\(delta) from=\(i) → \(j) rows=\(rowKeys)") }
        #endif
        if j < 0 {
            // Up out of the first row hands the page back to the hero.
            rowLandWork?.cancel()
            focus.pendingRowKey = nil
            withAnimation(Motion.pageScroll) { focus.inRows = false }
            DispatchQueue.main.async { heroFocus = .primary }
            return
        }
        guard j < rowKeys.count else { return }
        let target = rowKeys[j]
        // Bring the target row into its on-screen slot (and enable it) first: a
        // focus request for a view the engine can't see is never satisfied, and
        // SwiftUI would retry it on every update. Only the newest move lands.
        rowLandWork?.cancel()
        focus.pendingRowKey = target
        let work = DispatchWorkItem { focusRouter.land(row: target, x: x, tab: tab) }
        rowLandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        watchPending(target, x: x)
    }

    /// Row keys in on-screen order.
    private var rowKeys: [String] {
        var keys: [String] = []
        if !model.continueWatching.isEmpty { keys.append("cw") }
        keys += model.recommendationRows.map(\.id)
        if !model.featured.isEmpty { keys.append("featured") }
        if liveTV.value.enabled, !liveTV.value.homeChannelIDs.isEmpty { keys.append("live") }
        return keys + model.rows.map(\.id)
    }

    private var focusedIndex: Int? {
        guard focus.inRows, let k = focus.activeRowKey else { return nil }
        return rowKeys.firstIndex(of: k)
    }

    /// Every row lands on the same line. This used to be raised for a tall row
    /// (Featured, 564 pt), by `1030 - (height - 24)` = 50 pt: entering or leaving
    /// that row slid the whole stack an extra 50 pt, and since the top rows are
    /// exactly Continue Watching / Featured / the first catalogs, moving through
    /// them bobbed up and down before settling once the rows were all the same
    /// height. The line is fixed now, so a move is exactly one row's height.
    private func screenTop(for _: String) -> CGFloat {
        Self.focusedRowTop
    }

    private var stackOffset: CGFloat {
        guard focus.inRows, let k = focus.activeRowKey, let top = stackTop(of: k) else { return 0 }
        return screenTop(for: k) - top
    }

    /// A row's top inside the (un-offset) stack, from row *heights* only. Measured
    /// positions move with the offset and would feed back into it (an endless
    /// two-value oscillation); heights don't.
    private func stackTop(of key: String) -> CGFloat? {
        guard let i = rowKeys.firstIndex(of: key) else { return nil }
        var y = (showsRollingHero ? 940 : Self.focusedRowTop) + 10
        for k in rowKeys.prefix(i) {
            guard let h = rowTops[k] else { return nil }
            y += h
        }
        return y
    }

    private var focusedRowScreenTop: CGFloat {
        guard let k = focus.activeRowKey else { return Self.focusedRowTop }
        return screenTop(for: k)
    }

    /// No ScrollView: the stack is offset so the focused row lands at a fixed
    /// height. Rows above it fade out completely.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArea
            rowsStack
        }
        // Natural heights (horizontal scroll views would otherwise be squeezed to fit).
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(LiveRowHeightKey.self) { new in
            for (key, h) in new where h > 1 {
                if abs((rowMeasure[key] ?? 0) - h) > 0.5 { rowMeasure[key] = h }
                // Learnt once per kind, so two live rows can never fight over it.
                if kindHeight[kind(of: key)] == nil { kindHeight[kind(of: key)] = h }
            }
        }
        .onPreferenceChange(RowTopKey.self) { new in
            // Heights only (all the layout uses). Positions move with the stack's
            // offset; emitting them made this fire on every frame of a row-to-row
            // scroll and rebuilt all of Home ~12× per press on an A10X.
            let changed = new.count != rowTops.count || new.contains { k, h in
                guard let old = rowTops[k] else { return true }
                return abs(old - h) > 1
            }
            if changed { rowTops = new }
        }
        // THE MASK IS IN STACK SPACE, INSIDE THE OFFSET.
        //
        // The edge is the focused row's top *within the stack*, so it rides the
        // same offset animation the rows do and stays exactly on the boundary
        // between the row leaving upward and the one arriving. In screen space
        // the edge and the stack animated separately — 50 pt of edge against
        // 514 pt of stack — so half way through a move the line sat far above
        // the real boundary and the bottom of the outgoing row (its caption
        // strips, with no artwork behind them) hung in mid-air under it.
        .mask(alignment: .top) { RowsMask(edge: maskEdge) }
        .offset(y: stackOffset)
        .animation(Motion.pageScroll, value: stackOffset)
        .animation(Motion.pageScroll, value: focus.inRows)
        .pageFrame(alignment: .top)
    }

    /// Stack y above which the rows are hidden: the focused row's top in the
    /// rows, nothing on the hero.
    private var maskEdge: CGFloat {
        guard focus.inRows, let k = focus.activeRowKey, let top = stackTop(of: k) else { return -RowsMask.fade }
        return top
    }

    @ViewBuilder private var heroArea: some View {
        if showsRollingHero, let item = heroItem {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                // Only the text crossfades between titles. The buttons stay
                // mounted: rebuilding them under focus (a hero step, the roll)
                // dropped focus onto the side rail and stranded the remote.
                HeroTextBlock(item: item, rank: model.heroItems.count > 1 ? rotation.index + 1 : nil)
                    .padding(.leading, Metrics.margin)
                    .padding(.bottom, 180 + HeroButtons.height + 22)
                    .id(item.id)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.8).delay(0.9)),
                                            removal: .opacity.animation(.easeIn(duration: 0.5))))
                HeroButtons(isSeries: item.isSeries, heroFocus: $heroFocus,
                            onPrimary: { PlayActions(router: router).openDetail(item, siblings: model.heroItems) },
                            onInfo: { infoFor = item },
                            onNext: { rotation.step(1) })
                    .padding(.leading, Metrics.margin)
                    .padding(.bottom, 180)
                if model.heroItems.count > 1 {
                    PaginationDots(count: model.heroItems.count, index: rotation.index)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 120)
                }
            }
            .frame(height: 940)
            // In the first row the hero buttons stay focusable (barely visible) so
            // Up returns to them natively.
            // No ghosting (logo swapped for text the instant the rows took over,
            // a doubled title mid-move): in the rows the hero rests above the
            // stack's mask edge, so even its 1 % copy is never drawn on screen.
            //
            // FADED, NOT SWITCHED. This opacity used to snap: on the way down the
            // logo, synopsis and buttons disappeared in one frame while the rows
            // were still gliding up, and on the way up they reappeared at full
            // brightness over a row that had barely started moving — the two
            // layers visibly on screen together. It rides the same spring as the
            // stack now, so the hero dissolves as it slides.
            .opacity(heroContentVisible ? 1 : (focusedIndex == 0 ? 0.011 : 0))
            // …but not from the rail: Right out of it must return to the row.
            .disabled(focus.inRows && (focusedIndex != 0 || navHasFocus))
            // Going Up, the hero slides in over the row it is uncovering. Without
            // this the row (drawn later in the VStack) passes in front of it.
            .zIndex(focus.inRows ? 0 : 2)
            .onMoveCommand { dir in
                VerticalMoveRelay.shared.notePress(dir)
                if dir == .down { enterRowsFromHero() }
            }
        } else {
            Color.clear.frame(height: Self.focusedRowTop)
        }
    }

    /// DEBUG `-homeRowLimit N`: build only the first N catalog rows (cost-scaling test).
    private var debugRows: [HomeRow] {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-homeRowLimit"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) {
            return Array(model.rows.prefix(n))
        }
        #endif
        return model.rows
    }

    private var rowsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.continueWatching.isEmpty {
                ContinueWatchingRow(items: model.continueWatching, focus: focus).modifier(rowSlot("cw"))
            }
            ForEach(model.recommendationRows) { row in
                CatalogRow(row: row, numbered: false, focus: focus).modifier(rowSlot(row.id))
            }
            if !model.featured.isEmpty {
                FeaturedRow(items: model.featured, focus: focus).modifier(rowSlot("featured"))
            }
            if liveTV.value.enabled, !liveTV.value.homeChannelIDs.isEmpty {
                HomeLiveChannelsRow(focus: focus).modifier(rowSlot("live"))
            }
            ForEach(debugRows) { row in
                Group {
                    switch row.descriptor.kind {
                    case .catalog:
                        CatalogRow(row: row, numbered: model.isNumbered(row), focus: focus)
                    case .collection(let id):
                        if let c = collections.collection(id) {
                            CollectionFoldersRow(collection: c, rowKey: row.id, focus: focus)
                        }
                    case .collectionsShared:
                        CollectionsSharedRow(rowKey: row.id, focus: focus)
                    case .recommendation:
                        CatalogRow(row: row, numbered: false, focus: focus)
                    }
                }
                .modifier(rowSlot(row.id))
            }
        }
        .padding(.top, 10)
    }

    /// Rows further than this from the focused row are placeholders of the same
    /// height. Every row used to be built and kept live: each focus move and
    /// animation frame then paid for all of them — on an A10X, ~200 ms per press
    /// with a full Home vs none with four rows. The A8 keeps one either side.
    // A10X boxes keep only one row either side too: the fourth live row's
    // focus updates and artwork were enough to stutter a row-to-row move.
    static let liveRowRadius = PerformanceProfile.isConstrained ? 1 : 2

    /// A not-yet-measured row's height: the typical measured one.
    private var typicalRowHeight: CGFloat {
        let hs = rowTops.values.sorted()
        return hs.isEmpty ? 520 : hs[hs.count / 2]
    }

    /// The kind a row belongs to, so far rows can be sized from a measured one.
    private func kind(of key: String) -> HomeRowKind {
        switch key {
        case "cw": return .continueWatching
        case "featured": return .featured
        case "live": return .live
        default: break
        }
        if let row = model.rows.first(where: { $0.id == key }) {
            switch row.descriptor.kind {
            case .catalog: return .catalog
            case .collection: return .collection
            case .collectionsShared: return .folders
            case .recommendation: return .recommendation
            }
        }
        return .catalog
    }

    private func placeholder(_ key: String, index i: Int, anchor: Int) -> CGFloat? {
        let k = kind(of: key)
        // Until its kind has been measured, the first row of that kind is built
        // (its posters stay deferred), so the rest can be sized exactly.
        if kindHeight[k] == nil, rowKeys.firstIndex(where: { kind(of: $0) == k }) == i { return nil }
        guard abs(i - anchor) > Self.liveRowRadius else { return nil }
        return rowMeasure[key] ?? kindHeight[k] ?? typicalRowHeight
    }

    private func rowSlot(_ key: String) -> RowSlot {
        guard focus.inRows, let fi = focusedIndex, let i = rowKeys.firstIndex(of: key) else {
            // On the hero: only the first row takes focus; rows past the third wait for images.
            let i = rowKeys.firstIndex(of: key) ?? 0
            return RowSlot(key: key, state: key == rowKeys.first ? .active : .waiting,
                           deferImages: i > (PerformanceProfile.isConstrained ? 1 : 2),
                           placeholderHeight: placeholder(key, index: i, anchor: liveAnchor)) { dir in
                #if DEBUG
                if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] slot(hero) \(key) move \(dir)") }
                #endif
                if dir == .down { moveRow(1, from: key) }
            }
        }
        let state: RowSlot.State
        if i == fi {
            state = .active
        } else if i == fi - 1 {
            // Drawn so it slides away under (or back out from) the mask edge.
            state = .above
        } else if i < fi {
            state = .hidden
        } else {
            state = .waiting
        }
        return RowSlot(key: key, state: state,
                       deferImages: i > fi + (PerformanceProfile.isConstrained ? 1 : 2),
                       placeholderHeight: placeholder(key, index: i, anchor: liveAnchor)) { dir in
            #if DEBUG
            if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[home] slot \(key) state=\(state) i=\(i) fi=\(fi) move \(dir) pending=\(String(describing: focus.pendingRowKey))") }
            #endif
            // Both vertical moves are done by hand. Up used to reach an invisible
            // "ghost" row natively, but that row only exists once the last move
            // has settled: Up pressed while a move was pending, or just after
            // landing, found nothing above and was dropped (the remote felt stuck).
            // Without a ghost the engine's own Up always fails here, so this
            // handler runs once per press (and the top row's Up still reaches the
            // hero's buttons natively as well).
            switch dir {
            case .down: moveRow(1, from: key)
            case .up: moveRow(-1, from: key)
            default: break
            }
        }
    }
}

/// Records a row's top in the Home stack and sets how it takes part in focus.
struct RowSlot: ViewModifier {
    enum State {
        /// The focused row.
        case active
        /// Below the focused row: visible, not focusable (Down is done by hand).
        case waiting
        /// Just above: drawn but under the stack's mask, not focusable.
        case above
        /// Further above: not drawn, not focusable.
        case hidden
    }

    let key: String
    let state: State
    /// Far below the focused row: posters wait to load until it comes near.
    var deferImages = false
    /// Far from the focused row: draw an empty block of this height instead.
    var placeholderHeight: CGFloat? = nil
    var onMove: (MoveCommandDirection) -> Void = { _ in }

    private var opacity: Double {
        switch state {
        case .active, .waiting, .above: return 1
        case .hidden: return 0
        }
    }

    func body(content: Content) -> some View {
        Group {
            if let h = placeholderHeight {
                // Far from focus: nothing live — just the space the row takes.
                Color.clear.frame(height: h)
            } else {
                content
                    .onMoveCommand { dir in
                        VerticalMoveRelay.shared.notePress(dir)
                        onMove(dir)
                    }
                    .environment(\.deferImageLoad, deferImages)
                    // A built row reports its real height; the placeholder rows
                    // are sized from it, so a row arriving never reflows the stack.
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: LiveRowHeightKey.self, value: [key: geo.size.height])
                        }
                    }
            }
        }
            .background(GeometryReader { geo in
                Color.clear.preference(key: RowTopKey.self, value: [key: geo.size.height])
            })
            .opacity(opacity)
            .disabled(state != .active)
            // Keep the incoming row above the one it is replacing while both
            // slide: a later sibling otherwise draws in front and makes the
            // focused row look like it was already waiting behind it.
            .zIndex(state == .active ? 2 : 0)
            // Only rows already off screen above the mask change opacity: no fade.
            .animation(nil, value: opacity)
    }
}

/// The Home stack's mask, in screen space: clear above `edge`, opaque below,
/// with a short soft edge. The row above the focused one rests entirely in
/// the clear part (its posters end ~24 pt above the edge).
struct RowsMask: View {
    let edge: CGFloat
    static let fade: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, edge - Self.fade))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fade)
            Color.black
        }
    }
}

struct RowTopKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Heights of rows that are actually built (not placeholders). The far rows are
/// sized from these, so they can't be the wrong height.
struct LiveRowHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Rows that share a height: every catalog row lays its cards out identically,
/// so measuring one of each kind sizes the rest exactly.
enum HomeRowKind: Hashable {
    case continueWatching, featured, live, catalog, recommendation, collection, folders
}

// MARK: - Hero text block

struct HeroTextBlock: View {
    let item: MetaItem
    var rank: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogoOrTitle(logo: item.logo, title: item.name, maxSize: CGSize(width: 560, height: 200))
            Spacer().frame(height: 12)
            if let rank {
                BadgePill(text: "Top 10 #\(rank)").padding(.bottom, 12)
            }
            MetaLine(parts: [item.typeLabel] + item.genres.prefix(1) + [item.year ?? "", item.certification ?? ""],
                     rating: item.imdbRating)
            if let d = item.description, !d.isEmpty {
                Text(d).textStyle(.body).lineLimit(2).frame(maxWidth: 760, alignment: .leading).padding(.top, 10)
            }
        }
    }
}

/// The hero's button row — one stable set for every title the hero shows.
struct HeroButtons: View {
    static let height: CGFloat = 64
    let isSeries: Bool
    var heroFocus: FocusState<HomeHeroFocus?>.Binding
    let onPrimary: () -> Void
    let onInfo: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                // Invisible step: Left from the primary button pages back.
                Button(action: {}) { Color.clear.frame(width: 1, height: 64) }
                    .buttonStyle(BareFocusStyle())
                    .focused(heroFocus, equals: .stepPrev)
                Button(action: onPrimary) {
                    Text(isSeries ? "Go to Show" : "Go to Movie")
                }
                .buttonStyle(PrimaryCapsuleStyle(minWidth: 280))
                .focused(heroFocus, equals: .primary)
                CircleButton(systemImage: "info", action: onInfo)
                    .focused(heroFocus, equals: .info)
                Button(action: onNext) {
                    Image(systemName: "chevron.right").font(.system(size: 30, weight: .semibold))
                }
                .buttonStyle(ChevronStyle())
                .focused(heroFocus, equals: .next)
                Button(action: {}) { Color.clear.frame(width: 1, height: 64) }
                    .buttonStyle(BareFocusStyle())
                    .focused(heroFocus, equals: .stepNext)
            }
            .padding(.leading, -19)
        }
    }

    private struct ChevronStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }
        private struct Chrome: View {
            @Environment(\.isFocused) private var focused
            let configuration: Configuration
            var body: some View {
                configuration.label
                    .foregroundStyle(focused ? Palette.focusInk : .white.opacity(0.85))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(focused ? Palette.focusFill : .clear))
                    .scaleEffect(focused ? 1.1 : 1)
                    .animation(Motion.focus, value: focused)
            }
        }
    }
}

// MARK: - Backdrop (full-bleed art + pinned header)

struct HomeBackdrop: View {
    @Environment(\.railBleed) private var bleed
    @ObservedObject var focus: HomeFocusModel
    /// The focused title (its own object: only this backdrop redraws per move).
    @ObservedObject var spotlight: HomeSpotlight
    @ObservedObject var rotation: HeroRotation
    let heroItems: [MetaItem]
    let layout: HeroLayout
    /// Bottom edge of the pinned header (just above the focused row).
    let headerBottom: CGFloat
    let heroVideo: Bool
    let trailerSound: Bool

    @StateObject private var video = BackgroundVideoController()
    @State private var videoVisible = false
    /// The player or a full-screen trailer covers Home (it stays enabled underneath).
    @EnvironmentObject private var presenter: PlayerPresenter
    @ObservedObject private var trailers = TrailerPresenter.shared
    private var covered: Bool { presenter.isPresenting || trailers.request != nil }
    /// False while a pushed page or the side menu covers Home: no trailer then.
    @Environment(\.isEnabled) private var pageEnabled
    /// The focused card, settled — fast scrolling doesn't flash every poster's art.
    @State private var settledFocus: MetaItem?
    /// The art on screen is the rolling hero's (not a focused card's): only a
    /// roll from one hero title to the next gets the slow 1.8 s crossfade.
    @State private var artIsHero = true
    @Environment(\.theme) private var theme

    private var heroItem: MetaItem? {
        heroItems.isEmpty ? nil : heroItems[min(rotation.index, heroItems.count - 1)]
    }

    /// The rolling hero at the top; in the rows, the focused card (Hybrid /
    /// Pinned Focus) or the hero (Rolling). Always full screen, top to bottom.
    private var artItem: MetaItem? {
        if layout == .pinnedFocus { return settledFocus ?? heroItem }
        if focus.inRows, layout == .hybrid { return settledFocus ?? heroItem }
        return heroItem
    }

    /// The art shows the hero's title rather than a focused card's.
    private var showsHeroArt: Bool {
        layout == .rolling || (!focus.inRows && layout == .hybrid)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("HomeBackdrop")
        #endif
        ZStack(alignment: .topLeading) {
            theme.ambientGradient
            ZStack {
                if let item = artItem {
                    RemoteImage(url: item.background ?? item.poster, maxPixel: ImageSize.backdrop, placeholder: false)
                        .frame(width: 1920, height: 1080)
                        .id(item.id)
                        .transition(.opacity)
                }
                if video.hasPlayer {
                    BackgroundVideoView(player: video.player)
                        .opacity(videoVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: videoVisible)
                }
            }
            .frame(width: 1920, height: 1080)
            .clipped()
            // Back up to the hero from a row used the roll's 1.8 s too: the row's
            // art lingered under the hero's title for two seconds.
            .animation(Motion.unlessReduced(.easeInOut(duration: artIsHero && showsHeroArt ? 1.8 : 0.7)), value: artItem?.id)
            .onChange(of: artItem?.id) { _, _ in artIsHero = showsHeroArt }

            // Scrims: left-to-right always; once in the rows, a deeper bottom
            // fade so the row reads over the art.
            ArtworkScrims(bottomFraction: focus.inRows ? 0.62 : 0.35, bottomOpacity: focus.inRows ? 0.85 : 0.6)
                .animation(Motion.pageScroll, value: focus.inRows)

            if focus.inRows, layout != .rolling, let item = artItem {
                PinnedHeader(item: item, compact: headerBottom < 360)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .frame(height: headerBottom, alignment: .bottomLeading)
                    .padding(.leading, Metrics.margin + bleed)
                    // Rises and falls with the rows (a taller row sits higher).
                    .animation(Motion.pageScroll, value: headerBottom)
            }
        }
        .frame(width: 1920, height: 1080)
        .allowsHitTesting(false)
        .task(id: spotlight.item?.id) {
            // Settle before swapping the art (0.25 s).
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            #if DEBUG
            if PerformanceProfile.arguments.contains("-noBackdropSwap") { return }
            #endif
            settledFocus = spotlight.item
        }
        .task(id: videoTaskKey) { await runVideo() }
        .task(id: spotlight.item?.id) {
            // Rested on a card: get its Detail page (and trailer) ready.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let item = spotlight.item else { return }
            DetailModelCache.shared.warm(item)
        }
        .onDisappear { video.stop(); videoVisible = false }
    }

    /// Only the title the viewer is actually on gets a trailer: a focused,
    /// settled movie/show card. The rolling hero just rolls — never a trailer
    /// for whatever it happens to be showing.
    private var trailerItem: MetaItem? {
        guard focus.inRows, layout != .rolling, let item = settledFocus,
              item.id == spotlight.item?.id, item.type == "movie" || item.type == "series" else { return nil }
        return item
    }

    private var videoTaskKey: String {
        "\(trailerItem?.id ?? "")|\(heroVideo)|\(pageEnabled)|\(trailerSound)|\(covered)"
    }

    private func runVideo() async {
        video.stop()
        videoVisible = false
        // Decoding a trailer behind a browsing UI is too much for the A8/A10X:
        // focus moves stutter while it runs. Only the 4 GB boxes autoplay it.
        guard heroVideo, pageEnabled, !covered, !PerformanceProfile.reduceMotion,
              !PerformanceProfile.isConstrained, let item = trailerItem else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        var keys = item.trailers.map(\.source)
        if keys.isEmpty, let e = await TMDBService.enrichment(for: item) { keys = e.trailers.map(\.key) }
        guard !keys.isEmpty, !Task.isCancelled, let src = await TrailerService.resolveFirst(keys, muted: !trailerSound) else { return }
        guard !Task.isCancelled else { return }
        video.setMuted(!trailerSound)
        // With sound it plays once (a looping trailer with audio is a lot); muted it loops.
        video.loops = !trailerSound
        await video.play(source: src, key: item.id)
        var waited = 0
        while !video.isPlaying, waited < 40, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        guard !Task.isCancelled, video.isPlaying else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        videoVisible = true
        // Played once: the art fades back at the end.
        while !Task.isCancelled, !video.didEnd { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard !Task.isCancelled else { return }
        videoVisible = false
    }
}

/// The pinned header: the focused card's logo, meta and 2-line synopsis (no buttons).
struct PinnedHeader: View {
    let item: MetaItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoOrTitle(logo: item.logo, title: item.name, maxSize: CGSize(width: compact ? 360 : 480, height: compact ? 100 : 150))
            MetaLine(parts: [item.typeLabel] + item.genres.prefix(2) + [item.year ?? ""], rating: item.imdbRating)
            if !compact, let d = item.description {
                Text(d).textStyle(.body).lineLimit(2).frame(maxWidth: 760, alignment: .leading)
            }
        }
        .id(item.id)
        .transition(.opacity.animation(.easeInOut(duration: 0.35)))
    }
}
