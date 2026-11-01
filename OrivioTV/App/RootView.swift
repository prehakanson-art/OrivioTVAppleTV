import SwiftUI
import UIKit

enum NavFocus: Hashable {
    case tab(AppTab)
    case profileHeader
    case profile(Int)
    case addProfile
}

struct RootView: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var liveTV: LiveTVSettingsStore
    @EnvironmentObject private var toasts: ToastCenter

    @StateObject private var router = Router()
    @StateObject private var focusRouter = ContentFocusRouter()
    @StateObject private var edges = FocusEdgeObserver()
    @ObservedObject private var presenter = PlayerPresenter.shared
    @StateObject private var sync = SyncHub.shared
    @ObservedObject private var trailers = TrailerPresenter.shared
    @ObservedObject private var reminders = GuideReminders.shared
    @ObservedObject private var info = InfoPresenter.shared

    enum Phase { case onboarding, gate, main }
    /// nil until `decidePhase` runs: the first frame used to draw the main shell
    /// (its grey side rail) and only then switch to "Who's watching?" — a grey
    /// bar flashing at the left on launch, long enough to see on an A10X box.
    @State private var phase: Phase?
    @State private var didDecidePhase = false

    var body: some View {
        let theme = Theme(appearance.preview ?? appearance.value)
        ZStack {
            theme.ambientGradient.ignoresSafeArea()
            switch phase {
            case .onboarding:
                WelcomeFlow { advanceFromOnboarding() }
            case .gate:
                ProfileGateView(cancellable: false) { id in
                    profiles.switchTo(id)
                    withAnimation(Motion.pageOpen) { phase = .main }
                }
                .transition(.opacity)
            case .main:
                MainShell()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            case nil:
                EmptyView()
            }
            ToastOverlay(center: toasts)
        }
        .environment(\.theme, theme)
        .environmentObject(router)
        .environmentObject(focusRouter)
        .environmentObject(edges)
        .environmentObject(presenter)
        .environmentObject(sync)
        .fullScreenCover(item: $presenter.request) { request in
            PlayerScreen(request: request)
                .withAppStores(AppStores.shared)
                .environment(\.theme, theme)
                .environmentObject(router)
        }
        .modifier(ClassicPlayerCover(presenter: presenter, theme: theme))
        .fullScreenCover(item: $trailers.request) { r in
            TrailerFullScreen(keys: r.keys) { trailers.request = nil }
                .ignoresSafeArea()
                .onExitCommand { trailers.request = nil }
        }
        .fullScreenCover(item: $reminders.due) { r in
            ReminderPrompt(reminder: r) { reminders.due = nil }
                .withAppStores(AppStores.shared)
                .environment(\.theme, theme)
                .presentationBackground(.clear)
        }
        .sheet(item: $info.meta) { m in
            InfoPopover(meta: m).environment(\.theme, theme)
        }
        .onAppear(perform: decidePhase)
        .onAppear { GuideReminders.shared.start() }
        .onOpenURL { url in DeepLinks.handle(url, router: router) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await AppStores.shared.addons.refreshPlaceholders() }
            sync.appBecameActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            AppStores.shared.flushAll()
        }
    }

    private func decidePhase() {
        guard !didDecidePhase else { return }
        didDecidePhase = true
        let args = PerformanceProfile.arguments
        #if DEBUG
        DebugLog.launchMark("firstFrame")
        if args.contains("-traceFocus") { DebugLog.traceFocus() }
        if args.contains("-hitchLog") { HitchMonitor.start() }
        #if arch(arm64)
        if args.contains("-hitchProfile") { HitchProfiler.shared.start() }
        #endif
        // `-skipWelcome`: a fresh install (e.g. a test device) starts on Home.
        if args.contains("-skipWelcome") { Persistence.set(true, forKey: Persistence.key("onboarding.completed.v1")) }
        #endif
        if args.contains("-welcomeDemo") || !Persistence.bool(forKey: Persistence.key("onboarding.completed.v1")) {
            phase = .onboarding
        } else if args.contains("-profileGateDemo") || profiles.needsGateAtLaunch {
            phase = .gate
        } else {
            phase = .main
        }
        sync.start()
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-playTest"), i + 1 < CommandLine.arguments.count,
           let url = URL(string: CommandLine.arguments[i + 1]) {
            // Debug: open the player straight on a URL (simulator testing).
            var meta = MetaItem(id: "tt0000000", type: "movie", name: "Player Test")
            var video: MetaVideo?
            if CommandLine.arguments.contains("-series") {
                let eps = (1...3).map { (n: Int) in MetaVideo(id: "tt0000000:1:\(n)", title: "Episode Name \(n)", season: 1, episode: n) }
                meta = MetaItem(id: "tt0000000", type: "series", name: "Series Test", videos: eps)
                video = eps[0]
            }
            let entry = StreamEntry(stream: Stream(name: "Test", title: url.lastPathComponent, url: url.absoluteString),
                                    addonName: "Debug", addonID: "debug", index: 0)
            // `-playTestAfter N`: open it N seconds in (over Home, like a real press).
            let after = CommandLine.arguments.firstIndex(of: "-playTestAfter").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                let resume = CommandLine.arguments.firstIndex(of: "-resume").flatMap { Double(CommandLine.arguments[$0 + 1]) }
                presenter.present(PlaybackRequest(meta: meta, video: video, entry: entry, allEntries: [entry], resumePosition: resume, url: url))
            }
        }
        #endif
    }

    private func advanceFromOnboarding() {
        Persistence.set(true, forKey: Persistence.key("onboarding.completed.v1"))
        withAnimation(Motion.pageOpen) { phase = profiles.needsGateAtLaunch ? .gate : .main }
    }
}

// MARK: - Main shell (tabs + navigation chrome)

struct MainShell: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var liveTV: LiveTVSettingsStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @EnvironmentObject private var edges: FocusEdgeObserver
    @EnvironmentObject private var presenter: PlayerPresenter

    @State private var mounted: Set<AppTab> = [.home]
    @State private var navOpen = false
    /// After a tab switch or the profile gate the nav is briefly unfocusable so
    /// focus seeds into content — Back force-enables it.
    @State private var navSuppressed = true
    @State private var navHoldGeneration = 0
    /// Short-lived rail holds and blocks (Detail paging). Only the rail observes
    /// it: as shell state, each flip re-rendered the shell and every tab root.
    @State private var gate = NavGate()
    /// Auto-hidden rail: shown while focus is being moved into it.
    @State private var railRevealing = false
    @State private var profileStripOpen = false
    #if DEBUG
    @State private var debugPhoneSheet = CommandLine.arguments.contains("-phoneTest")
    #endif
    @FocusState private var navFocus: NavFocus?
    /// Leaving the rail/top bar: the chrome dips out for a moment so the focus
    /// engine has to hand focus to the page (a FocusState change alone is
    /// ignored while the focused button stays on screen).
    @State private var navLeaving = false
    @StateObject private var topBarVisibility = TopBarVisibility()

    private var style: NavigationStyle { appearance.value.navigationStyle }
    private var railAutoHide: Bool { style == .rail && (appearance.value.railAutoHide || Self.debugRailHide) }
    #if DEBUG
    /// `-railAutoHide`: try the hidden rail without touching the saved setting.
    private static let debugRailHide = CommandLine.arguments.contains("-railAutoHide")
    #else
    private static let debugRailHide = false
    #endif
    private var tabs: [AppTab] { AppTab.visible(liveTV: liveTV.value.enabled) }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("MainShell")
        #endif
        ZStack(alignment: .topLeading) {
            // Tabs overlap in their own ZStack. (A modifier such as `.focusSection()`
            // applied straight to a ForEach wraps it in an implicit VStack — the
            // tabs were stacked vertically, half a screen off each.)
            ZStack(alignment: .topLeading) {
                ForEach(AppTab.allCases.filter { mounted.contains($0) }) { tab in
                    // The rail keeps a 120 pt clearance: pages get an 1800 pt canvas
                    // (`pageWidth`) and full-bleed art reaches back under the pill
                    // (`railBleed`). A 1920 frame plus padding was 2040 wide and got
                    // centred 60 pt off — every page overflowed on the right.
                    let rail: CGFloat = style == .rail && !railAutoHide ? 120 : 0
                    let top: CGFloat = style == .topBar && tab != .home ? 120 : 0
                    TabRoot(tab: tab, onBackAtRoot: { backAtRoot() })
                        .environment(\.navHasFocus, navFocus != nil)
                        .environment(\.pageWidth, 1920 - rail)
                        .environment(\.railBleed, rail)
                        .frame(width: 1920 - rail, height: 1080 - top, alignment: .topLeading)
                        .clipShape(LeadingBleedRect(bleed: rail))
                        .opacity(tab == router.tab ? 1 : 0)
                        // The sidebar disables the page only once focus is in the panel:
                        // disabling the focused view first left focus in limbo and
                        // the panel refused it for a second or more.
                        .disabled(tab != router.tab || (style == .sidebar && navOpen))
                        .padding(.leading, rail)
                        .padding(.top, top)
                }
            }
            .focusSection()

            if style == .sidebar {
                sidebarChrome
            } else if style == .rail {
                SideRail(tabs: tabs, expanded: navFocus != nil || railRevealing, profileStripOpen: $profileStripOpen,
                         // Never a fallback target: when the focused view goes away (a page
                         // pushed or popped, the player or the link list opening), tvOS
                         // handed focus to the rail and it started to open. It takes focus
                         // only when asked — Left at the page's edge, or Back.
                         navFocus: $navFocus, suppressed: navSuppressed || navLeaving || (navFocus == nil && !railRevealing),
                         gate: gate,
                         hidden: railAutoHide && navFocus == nil && !railRevealing,
                         select: selectTab, close: leaveNav)
                    .opacity(navLeaving ? 0 : 1)
            } else {
                TopBar(tabs: tabs, navFocus: $navFocus, profileStripOpen: $profileStripOpen, select: selectTab, close: leaveNav)
                    // Briefly unfocusable at launch / after a tab switch so focus seeds into the page.
                    .disabled(navLeaving || navSuppressed)
                    .opacity(navLeaving ? 0 : 1)
                    .focusSection()
            }
        }
        .ignoresSafeArea()
        .environmentObject(topBarVisibility)
        .onAppear {
            FocusProbe.start()
            // Arriving from "Who's watching?" the shell fades/zooms in for ~0.7 s:
            // keep the nav unfocusable past that and seed focus into the page, or
            // the gate's vanishing button handed focus to the rail (seen on device).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if navFocus != nil { leaveNav() } else { focusRouter.land(tab: router.tab) }
                navSuppressed = false
            }
            #if DEBUG
            // Debug: `-tab settings` opens a tab at launch (simulator testing).
            if let i = CommandLine.arguments.firstIndex(of: "-tab"), i + 1 < CommandLine.arguments.count,
               let t = AppTab(rawValue: CommandLine.arguments[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectTab(t) }
            }
            if let i = CommandLine.arguments.firstIndex(of: "-ytLive"), i + 1 < CommandLine.arguments.count {
                let key = CommandLine.arguments[i + 1]
                Task { DebugLog.write("YTLIVE \(key) -> \(await TrailerService.liveHLS(key)?.absoluteString ?? "nil")") }
            }
            // `-navStyle sidebar|rail|topBar` switches the navigation style at launch.
            if let i = CommandLine.arguments.firstIndex(of: "-navStyle"), i + 1 < CommandLine.arguments.count,
               let st = NavigationStyle(rawValue: CommandLine.arguments[i + 1]) {
                appearance.value.navigationStyle = st
            }
            // `-xtream http://host:port` points Live TV at a (test) Xtream provider.
            if let i = CommandLine.arguments.firstIndex(of: "-xtream"), i + 1 < CommandLine.arguments.count {
                liveTV.value.xtreamServer = CommandLine.arguments[i + 1]
                liveTV.value.xtreamUsername = "test"
                liveTV.value.xtreamPassword = "test"
                liveTV.value.customPlaylistURL = ""
            }
            // `-clearTestProvider`: undo `-xtream` (only when it still points at the test server).
            if CommandLine.arguments.contains("-clearTestProvider"), liveTV.value.xtreamUsername == "test",
               liveTV.value.xtreamServer.contains(":8791") {
                liveTV.value.xtreamServer = ""
                liveTV.value.xtreamUsername = ""
                liveTV.value.xtreamPassword = ""
                liveTV.value.recentChannelIDs = []
            }
            // `-installAddon <manifest url>` (simulator tests), `-autoplayTest` turns on Auto-play best source.
            if let i = CommandLine.arguments.firstIndex(of: "-installAddon"), i + 1 < CommandLine.arguments.count {
                let u = CommandLine.arguments[i + 1]
                Task { _ = await AppStores.shared.addons.install(u) }
            }
            if CommandLine.arguments.contains("-autoplayTest") { AppStores.shared.player.value.autoPlayBestSource = true }
            // `-gifDemo <gif url>`: a pinned ROWS collection of slug-covered folders with focus GIFs.
            if let i = CommandLine.arguments.firstIndex(of: "-gifDemo"), i + 1 < CommandLine.arguments.count {
                Self.debugGIFCollection(gif: CommandLine.arguments[i + 1])
            }
            // `-push person:31`, `company:2`, `network:213`, `tmdbcollection:10`, `collection:<id>`.
            if let i = CommandLine.arguments.firstIndex(of: "-push"), i + 1 < CommandLine.arguments.count {
                let parts = CommandLine.arguments[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                let route: Route? = switch parts[0] {
                case "person": .person(Int(arg) ?? 31, "Person")
                case "company": .tmdbCompany(Int(arg) ?? 2, "Company", isNetwork: false)
                case "network": .tmdbCompany(Int(arg) ?? 213, "Network", isNetwork: true)
                case "tmdbcollection": .tmdbCollection(Int(arg) ?? 10, "Collection")
                case "collection" where arg == "demo": .collection(Self.debugDemoCollection())
                case "collection": .collection(arg)
                case "discover": .discover(type: "movie", genre: nil)
                // `streams:tt…` — the link list in manual mode (it never auto-plays).
                case "streams": .streams(StreamsRequest(meta: MetaItem(id: arg.isEmpty ? "tt0111161" : arg, type: "movie", name: ""), video: nil, mode: .manual))
                // `detail:tt1,tt2,…` opens the first with the rest as siblings (paging).
                case "detail":
                    { () -> Route in
                        let ids = (arg.isEmpty ? "tt0111161" : arg).split(separator: ",").map { MetaItem(id: String($0), type: "movie", name: "") }
                        return .detail(ids[0], siblings: ids.count > 1 ? ids : [])
                    }()
                default: nil
                }
                if let route { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { router.push(route) } }
            }
            #endif
        }
        #if DEBUG
        .fullScreenCover(isPresented: $debugPhoneSheet) {
            if CommandLine.arguments.contains("-restore") {
                PhoneInputSheet(title: "Restore Backup", prompt: "Debug restore.", multiline: true) { text in
                    Task {
                        do {
                            let r = try await LocalBackup.importBackup(text)
                            DebugLog.write("RESTORE ok library=\(r.library) watched=\(r.watched) addons=\(r.addons) collections=\(r.collections) progress=\(r.progress)")
                        } catch { DebugLog.write("RESTORE failed \(error.localizedDescription)") }
                    }
                } onDone: { debugPhoneSheet = false }
            } else {
                PhoneInputSheet(title: "Export Backup", prompt: "Debug export.", exportFilename: LocalBackup.filename, exportText: LocalBackup.export()) {
                    debugPhoneSheet = false
                }
            }
        }
        #endif
        .onAppear {
            edges.onFailedMove = { handleEdge($0) }
            focusRouter.holdNav = { holdNav() }
            focusRouter.blockNav = { [gate] b in gate.setBlocked(b) }
        }
        .onChange(of: navFocus) { old, new in
            // Focus left the rail/top bar into content → land on the last row.
            if old != nil, new == nil, style != .sidebar, !navOpen {
                profileStripOpen = false
                focusRouter.land(tab: router.tab)
            }
        }
        .onChange(of: liveTV.value.enabled) { _, on in
            if !on, router.tab == .liveTV { selectTab(.home) }
        }
    }

    // MARK: Sidebar (style A)

    /// The panel stays mounted (slid away, invisible and disabled when closed),
    /// so opening it never races a view insertion for focus.
    @ViewBuilder private var sidebarChrome: some View {
        NavCapsuleHint(title: router.tab.title, systemImage: router.tab.systemImage)
            .padding(.leading, 40)
            .padding(.top, 36)
            .opacity(router.isAtRoot && !navOpen ? 1 : 0)
            .animation(Motion.sidebar, value: navOpen)
        Color.black.opacity(navOpen ? 0.3 : 0).ignoresSafeArea().allowsHitTesting(false)
            .animation(Motion.sidebar, value: navOpen)
        SidebarPanel(tabs: tabs, current: router.tab, navFocus: $navFocus, profileStripOpen: $profileStripOpen,
                     select: selectTab, close: closeNav)
            .padding(40)
            // Parked off-screen while closed — visible and enabled, like the rail.
            // A panel switched from hidden/disabled at open time wasn't yet a focus
            // target, and every request into it was refused (a frozen remote).
            .offset(x: navOpen ? 0 : -480)
            .animation(Motion.sidebar, value: navOpen)
            .disabled(!navOpen)
            .focusSection()
            .defaultFocus($navFocus, .tab(router.tab), priority: .userInitiated)
    }

    // MARK: Behaviour

    private func handleEdge(_ heading: UIFocusHeading) {
        guard !presenter.isPresenting else { return }
        switch style {
        case .sidebar:
            // Left opens the sidebar only at the *page* edge. Inside a page's
            // content it first returns to that page's own left column (Library's
            // sections, Settings' categories, Live TV's list) — otherwise the
            // first poster's failed Left opened the sidebar instead.
            if heading.contains(.left), !navOpen, router.isAtRoot {
                if returnToPageMenuIfNeeded() { return }
                if focusedAtPageEdge { openNav() }
            } else if heading.contains(.right), navOpen { closeNav() }
        case .rail:
            // Right with nothing beside the panel: back onto the page (as the TV app).
            if heading.contains(.right), navFocus != nil, !profileStripOpen { leaveNav() }
            // Left at the edge of the page opens it (not on Detail's card, where
            // Left pages to the previous title). A page's own column comes first.
            else if heading.contains(.left), navFocus == nil, !gate.blocked, router.isAtRoot {
                if returnToPageMenuIfNeeded() { return }
                revealRail(attempt: 0)
            }
        case .topBar:
            // No rail on this side, but a two-pane page still owns Left.
            if heading.contains(.left), navFocus == nil, router.isAtRoot, returnToPageMenuIfNeeded() { return }
            if heading.contains(.down), navFocus != nil, !profileStripOpen { leaveNav() }
        }
    }

    /// A failed Left/Back inside a page that keeps its own left column lands on
    /// that column instead of leaving the page. True when focus moved.
    private func returnToPageMenuIfNeeded() -> Bool {
        if router.tab == .liveTV {
            if LiveTVMenuState.shared.inList { return false }
            NotificationCenter.default.post(name: .orivioReturnToTabMenu, object: nil)
            return true
        }
        return PageMenuRouter.shared.landOnMenu(tab: router.tab)
    }

    /// The focused view sits against the left edge of the page (not a grid or
    /// list inset beside Live TV's / Settings' own left column).
    private var focusedAtPageEdge: Bool {
        guard let f = FocusProbe.focusedFrame else { return true }
        // The right edge filters full-width ScrollView containers (they report
        // x=0 even when the focused tile is in the middle of the page).
        return f.minX <= 180 && f.maxX <= 700
    }

    private func backAtRoot() {
        if focusRouter.resetCurrentRowIfNeeded(tab: router.tab) { return }
        navSuppressed = false
        // Already in the chrome: Back leaves it.
        if style == .sidebar ? navOpen : navFocus != nil {
            if style == .sidebar { closeNav() } else { leaveNav() }
            return
        }
        // Inside a two-pane page, Back steps out to that page's own column
        // before it can open the app's sidebar/rail.
        if returnToPageMenuIfNeeded() { return }
        switch style {
        case .sidebar:
            if focusedAtPageEdge { openNav() }
        case .rail:
            revealRail(attempt: 0)
        case .topBar:
            DispatchQueue.main.async { navFocus = .tab(router.tab) }
        }
    }

    /// Back out of the rail/top bar onto the page.
    private func leaveNav() {
        profileStripOpen = false
        navFocus = nil
        navLeaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusRouter.land(tab: router.tab) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { navLeaving = false }
    }

    /// Shows the hidden rail (already open) and moves focus in — asked again
    /// until it lands, since a request to a view enabled this instant is refused.
    private func revealRail(attempt: Int) {
        if attempt == 0 {
            navSuppressed = false
            railRevealing = true
        }
        guard attempt < 10, railRevealing else { railRevealing = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.12)) {
            if let f = FocusProbe.focusedFrame, f.maxX <= 440, navFocus != nil { railRevealing = false; return }
            navFocus = nil
            DispatchQueue.main.async { navFocus = .tab(router.tab) }
            revealRail(attempt: attempt + 1)
        }
    }

    private func openNav() {
        navSuppressed = false
        withAnimation(Motion.sidebar) { navOpen = true }
        focusNav(attempt: 0)
    }

    /// Always land on the tab that is actually open. The first request goes out
    /// without clearing the binding (clearing hands focus back to the page for
    /// a frame — the menu "bounce"). A request to a panel enabled this instant
    /// is refused, though, and the binding keeps the refused value, so it can't
    /// say whether focus arrived: ask UIKit (`FocusProbe`) and, only if focus
    /// is still on the page, clear the binding and ask again.
    private func focusNav(attempt: Int = 0) {
        guard navOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.15)) {
            guard navOpen else { return }
            // The panel (padding included) lies within 480 pt of the left edge.
            if let f = FocusProbe.focusedFrame, f.maxX <= 480, navFocus != nil { return }
            guard attempt < 8 else { return }
            if attempt == 0 {
                navFocus = .tab(router.tab)
            } else {
                navFocus = nil
                DispatchQueue.main.async { navFocus = .tab(router.tab) }
            }
            focusNav(attempt: attempt + 1)
        }
    }

    private func closeNav() {
        profileStripOpen = false
        withAnimation(Motion.sidebar) { navOpen = false }
        navFocus = nil
        // Enable content first (focus requests to a disabled view are dropped), then land.
        DispatchQueue.main.async { focusRouter.land(tab: router.tab) }
    }

    private func selectTab(_ tab: AppTab) {
        mounted.insert(tab)
        if router.tab == tab { router.popToRoot(tab) }
        router.tab = tab
        navSuppressed = true
        if style == .sidebar { closeNav() } else { navFocus = nil }
        unsuppressSoon()
    }

    private func unsuppressSoon() {
        navHoldGeneration += 1
        let g = navHoldGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if g == navHoldGeneration { navSuppressed = false } }
    }

    private func holdNav() {
        guard navFocus == nil else { return }
        gate.hold()
    }
}

/// One tab's navigation stack.
struct TabRoot: View {
    let tab: AppTab
    let onBackAtRoot: () -> Void
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @State private var closeProgress: CGFloat = 1

    /// The tab's page stack, rendered directly (the system NavigationStack shifted
    /// pages half a screen down when several tabs were mounted). The root stays
    /// mounted underneath so it keeps its state; only the top page is built.
    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("TabRoot")
        #endif
        let path = router.paths[tab] ?? []
        ZStack(alignment: .topLeading) {
            root
                .frame(width: 1920, height: 1080, alignment: .topLeading)
                .opacity(path.isEmpty ? 1 : 0)
                .disabled(!path.isEmpty)
                .onExitCommand(perform: onBackAtRoot)
            if let top = path.last {
                RouteDestination(route: top)
                    .frame(width: 1920, height: 1080, alignment: .topLeading)
                    .id(path.count)
                    .onExitCommand {
                        router.pop()
                        if router.isAtRoot {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusRouter.restore(tab: tab) }
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: path.count)
        .overlay {
            // Back from Detail: the page card shrinking into its card, over the
            // root as it fades back in.
            if let z = focusRouter.zoomBack, z.tab == tab {
                ZoomCard(start: z.start, end: z.end, from: z.card, to: z.page, progress: closeProgress)
                    .id(z.id)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .onChange(of: path.count) { old, new in
            if old == 0, new > 0 { focusRouter.noteLeftRoot(tab: tab) }
        }
        .onChange(of: focusRouter.zoomBack) { _, z in
            guard let z, z.tab == tab else { return }
            #if DEBUG
            DebugLog.write("[zoomBack] page \(z.page) → card \(z.card) start=\(z.start != nil) end=\(z.end != nil)")
            #endif
            closeProgress = 1
            DispatchQueue.main.async {
                withAnimation(Motion.pageClose) { closeProgress = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard focusRouter.zoomBack?.id == z.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { focusRouter.zoomBack = nil }
                }
            }
        }
        .environment(\.currentTab, tab)

    }

    @ViewBuilder private var root: some View {
        switch tab {
        case .home: HomeView(scope: .all)
        case .movies: HomeView(scope: .movies)
        case .shows: HomeView(scope: .shows)
        case .discover: DiscoverTab()
        case .search: SearchView()
        case .library: LibraryView()
        case .liveTV: LiveTVView()
        case .settings: SettingsView()
        }
    }
}

private struct CurrentTabKey: EnvironmentKey { static let defaultValue: AppTab = .home }
private struct NavHasFocusKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// The rail / top bar holds focus (pages keep hidden helpers out of its reach).
    var navHasFocus: Bool {
        get { self[NavHasFocusKey.self] }
        set { self[NavHasFocusKey.self] = newValue }
    }
}
extension EnvironmentValues {
    var currentTab: AppTab {
        get { self[CurrentTabKey.self] }
        set { self[CurrentTabKey.self] = newValue }
    }
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        Group {
            switch route {
            case .detail(let meta, let siblings): DetailView(meta: meta, siblings: siblings)
            case .streams(let req): StreamsView(request: req)
            case .collection(let id): CollectionScreen(collectionID: id)
            case .person(let id, let name): PersonView(personID: id, name: name)
            case .tmdbCompany(let id, let name, let isNetwork): CompanyView(companyID: id, name: name, isNetwork: isNetwork)
            case .tmdbCollection(let id, let name): TMDBCollectionView(collectionID: id, name: name)
            case .catalogSeeAll(let url, let catalog, let title): CatalogSeeAllView(addonURL: url, catalog: catalog, title: title)
            case .discover(let type, let genre): DiscoverView(initialType: type, initialGenre: genre)
            case .cloudLibrary: CloudLibraryView()
            case .mediaServerLibrary(let sid, let lid, let title): MediaServerLibraryView(serverID: sid, libraryID: lid, title: title)
            case .mediaServerShow(let sid, let iid, let title): MediaServerShowView(serverID: sid, itemID: iid, title: title)
            }
        }
        // The nav controller hosts pushed pages at the full screen width; keep
        // them on the page canvas (1800 pt beside the side rail).
        .pageFrame()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar(.hidden, for: .navigationBar)
    }
}

#if DEBUG
extension MainShell {
    /// A throwaway collection of Cinemeta catalogs for simulator checks (`-push collection:demo`).
    static func debugDemoCollection() -> String {
        let store = AppStores.shared.collections
        if let existing = store.library.first(where: { $0.title == "Debug Demo" }) { return existing.id }
        var c = store.create(title: "Debug Demo")
        c.viewMode = "TABBED_GRID"
        var movies = CollectionFolder(title: "Popular Movies")
        movies.sources = [.addon("com.linvo.cinemeta", type: "movie", catalogId: "top")]
        var shows = CollectionFolder(title: "Popular Shows")
        shows.sources = [.addon("com.linvo.cinemeta", type: "series", catalogId: "top")]
        var action = CollectionFolder(title: "Action")
        action.sources = [.addon("com.linvo.cinemeta", type: "movie", catalogId: "top", genre: "Action")]
        c.folders = [movies, shows, action]
        store.update(c)
        return c.id
    }

    static func debugGIFCollection(gif: String) {
        let store = AppStores.shared.collections
        var c = store.library.first(where: { $0.title == "GIF Demo" }) ?? store.create(title: "GIF Demo")
        c.viewMode = "ROWS"
        c.pinToTop = true
        func folder(_ title: String, slug: String?, gif: String?, shape: String = "SQUARE") -> CollectionFolder {
            var f = CollectionFolder(id: "gifdemo-\(title)", title: title)
            f.defaultCoverSlug = slug
            f.focusGifUrl = gif
            f.tileShape = shape
            f.sources = [.addon("com.linvo.cinemeta", type: "movie", catalogId: "top")]
            return f
        }
        c.folders = [
            folder("Netflix", slug: "streaming_services.netflix", gif: gif),
            folder("Disney+", slug: "streaming_services.disney_plus", gif: nil),
            // Doubled URL, as seen in real data.
            folder("Doubled", slug: "streaming_services.netflix", gif: gif + gif),
            folder("Wide", slug: nil, gif: gif, shape: "LANDSCAPE"),
        ]
        store.update(c)
    }
}
#endif
