import SwiftUI

@main
struct NuvioTVApp: App {
    @StateObject private var theme = ThemeManager()
    @StateObject private var addonManager = AddonManager()
    @StateObject private var progressStore = ProgressStore()
    @StateObject private var account = NuvioAccountManager()
    @StateObject private var library = LibraryStore()
    @StateObject private var watched = WatchedStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var collections = CollectionsStore()
    @StateObject private var homeCatalogSettings = HomeCatalogSettingsStore()
    @StateObject private var tmdbSettings = TMDBSettingsStore()
    @StateObject private var mdblistSettings = MDBListSettingsStore()
    @StateObject private var debrid = DebridStore()
    @StateObject private var trakt = TraktStore()
    @StateObject private var stremioAccount = StremioAccountStore()
    @StateObject private var playerSettings = PlayerSettingsStore()
    @StateObject private var streamBadges = StreamBadgeStore()
    @StateObject private var plugins = PluginStore()
    @StateObject private var torrent = TorrentSettingsStore()
    @StateObject private var ratings = RatingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .fontDesign(theme.rootFontDesign)   // app-wide font family (Fusion routes serif to headings only)
                .environmentObject(theme)
                .environmentObject(addonManager)
                .environmentObject(progressStore)
                .environmentObject(account)
                .environmentObject(library)
                .environmentObject(watched)
                .environmentObject(profiles)
                .environmentObject(collections)
                .environmentObject(homeCatalogSettings)
                .environmentObject(tmdbSettings)
                .environmentObject(mdblistSettings)
                .environmentObject(debrid)
                .environmentObject(trakt)
                .environmentObject(stremioAccount)
                .environmentObject(playerSettings)
                .environmentObject(streamBadges)
                .environmentObject(plugins)
                .environmentObject(torrent)
                .environmentObject(ratings)
                // Classic is hard-dark (the original look). The Apple TV theme
                // honors its Appearance setting — light, dark, or nil to
                // follow the TV's own system appearance.
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}

enum Route: Hashable {
    case detail(MetaItem)
    case streams(MetaItem, MetaVideo?)
    /// Source picker forced into manual mode (hold-Play / "Play Manually"):
    /// always shows the list, even when Auto Link Selector is on.
    case streamsManual(MetaItem, MetaVideo?)
    /// Source picker that plays from 0:00 (the Detail page's Start Over).
    case streamsFromStart(MetaItem, MetaVideo?)
    /// Continue Watching resume: re-scrape fresh sources and auto-play the one
    /// matching what was last watched. `fromStart` plays it from 0:00 (Start
    /// Over) instead of the saved position.
    case streamsResume(MetaItem, MetaVideo?, fromStart: Bool)
    case collection(NuvioCollection)
    case person(id: Int, name: String)
    case tmdbCompany(id: Int, name: String)
    case catalogSeeAll(addon: InstalledAddon, catalog: ManifestCatalog, title: String)
    case discover
    case cloudLibrary
}

struct RootView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject private var liveTV = LiveTVSettingsStore.shared
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var plugins: PluginStore
    @EnvironmentObject private var torrent: TorrentSettingsStore
    @EnvironmentObject private var ratings: RatingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    // One navigation stack per tab (tvOS expects TabView at the top level with
    // an independent NavigationStack inside each tab; a shared stack under one
    // NavigationStack makes the tab bar hard to reach and focus feel stuck).
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var liveTVPath = NavigationPath()
    /// Stremio-only sections (Discover / Addons) that aren't app tabs.
    @State private var discoverPath = NavigationPath()
    @State private var addonsPath = NavigationPath()
    // Persisted here (not inside HomeView) so switching tabs and coming back
    // doesn't rebuild it and re-trigger the catalog load / loading spinner.
    @StateObject private var homeViewModel = HomeViewModel()
    // Persisted here (not inside SearchView) so leaving the Search tab and
    // coming back keeps the query and results instead of clearing them.
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var playback: PlaybackRequest?
    /// An Auto Link Selector auto-play is on screen; pop its source page once the
    /// player closes so Back returns to the title page, not the source list.
    /// Deferred (not popped at play time) so StreamsView isn't torn down while
    /// its resolve Task is still running.
    @State private var pendingAutoPlayPop = false
    @State private var sync: NuvioSyncManager?
    @State private var traktSync: TraktSyncManager?
    @State private var showProfileGate = false
    @State private var selectedTab = 0
    /// Polls the account every 30s while Home is up so Continue Watching stays
    /// live — removals and additions made on another device (or that failed to
    /// reconcile on foreground) appear without a relaunch. Fires continuously;
    /// the receiver gates it to Home + active + not-in-player. A no-change pull
    /// mutates nothing (mergeRemote only publishes on a real diff), so an idle
    /// Home doesn't re-render.
    private let continueWatchingPoll = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// When Home last popped back from a pushed screen — used to swallow the
    /// stray Menu that otherwise opens the sidebar right after backing out.
    @State private var lastHomePopAt: Date?
    @FocusState private var sidebarFocus: Int?
    /// Focus for the Netflix theme's custom top navigation (its ground-up
    /// chrome — see netflixLayout). nil while content holds focus; a tab id
    /// (or -1, the profile chip) while the bar does. Setting it is how Back
    /// at a page root moves focus up to the bar (§18).
    @FocusState private var netflixNavFocus: Int?
    /// The sidebar is briefly non-focusable at launch so initial focus lands in
    /// the CONTENT (the APK boots with the sidebar collapsed and a card focused).
    @State private var sidebarEnabled = false

    var body: some View {
        content
            .onOpenURL { handleDeepLink($0) }
            // If Live TV is turned off while you're on it (or via sync), drop
            // back to Home so you're not stranded on a now-hidden tab.
            .onChange(of: liveTV.enabled) { _, enabled in
                if !enabled && selectedTab == 4 { selectedTab = 0 }
            }
            // Refresh a QR-linked Real-Debrid token at launch (its device-flow
            // access token is short-lived).
            .task { await debrid.refreshRealDebridIfNeeded() }
            .onAppear {
                NSLog("[OrivioPlayer] RootView content onAppear")
                startPlayerDemoIfRequested()
                startDetailDemoIfRequested()
            }
            .task {
                if sync == nil {
                    // Finishing a title records it in watched history.
                    progressStore.onFinished = { [weak watched] meta, video in
                        watched?.mark(meta: meta, video: video)
                    }
                    sync = NuvioSyncManager(
                        account: account,
                        addonManager: addonManager,
                        progressStore: progressStore,
                        libraryStore: library,
                        watchedStore: watched,
                        profileStore: profiles,
                        collectionsStore: collections,
                        homeCatalogSettings: homeCatalogSettings,
                        streamBadges: streamBadges,
                        playerSettings: playerSettings,
                        tmdbSettings: tmdbSettings,
                        themeManager: theme,
                        debridStore: debrid,
                        pluginStore: plugins,
                        torrentSettings: torrent,
                        traktStore: trakt
                    )
                    sync?.enrichContinueWatchingEnabled = { [tmdbSettings] in
                        tmdbSettings.settings.enrichContinueWatching
                    }
                    // Trakt two-way sync (history / watched badges + Continue
                    // Watching). Separate opt-in destination from the account.
                    traktSync = TraktSyncManager(
                        trakt: trakt, watched: watched, progress: progressStore,
                        library: library, ratings: ratings, addonManager: addonManager
                    )
                    // Fix up any already-installed Community Collections
                    // categories (a corrected Marvel/DC query, a Top Rated
                    // quality filter, ...) at launch — not only if the user
                    // happens to reopen the Community Collections screen,
                    // which could otherwise leave a fix installed in code but
                    // never actually reaching a category the user already
                    // has (that was the actual bug: Marvel/DC's query was
                    // correct, but a stale, already-installed folder just
                    // never got told to use it). The data-correctness parts
                    // are synchronous/local — run them NOW, before the user
                    // could possibly navigate into a collection this launch.
                    // Only the network-bound logo re-measurement (cosmetic,
                    // not correctness) is backgrounded.
                    CommunityCollections.consolidateIndividualCollections(collections: collections)
                    CommunityCollections.resyncPresetSources(collections: collections)
                    Task { await CommunityCollections.remeasureInstalledLogos(collections: collections) }
                    // "Who's watching?" gate on cold launch when 2+ profiles.
                    // Skipped in the demo modes so the screen isn't covered.
                    let args = ProcessInfo.processInfo.arguments
                    let demoArgs = ["-detailDemo", "-detailDemoSeries", "-homeDemo", "-settingsDemo", "-liveTVDemo", "-searchDemo", "-libraryDemo", "-discoverDemo", "-traktQRDemo", "-accountDemo", "-settingsTabDemo"]
                    let demoMode = demoArgs.contains { args.contains($0) }
                    showProfileGate = profiles.profiles.count >= 2 && !demoMode
                    if args.contains("-settingsDemo") { selectedTab = 3 }
                    // Settings TAB (in-place, not the full-screen pane demo) —
                    // used to drive the ATV theme's settings in the sim.
                    if args.contains("-settingsTabDemo") { selectedTab = 3 }
                    if args.contains("-liveTVDemo") { selectedTab = 4 }
                    if args.contains("-searchDemo") { selectedTab = 1 }
                    if args.contains("-libraryDemo") { selectedTab = 2 }
                    // Stremio-only sections.
                    if args.contains("-stremioDiscoverDemo") { selectedTab = 10 }
                    if args.contains("-stremioAddonsDemo") { selectedTab = 11 }
                    if args.contains("-discoverDemo") {
                        selectedTab = 1
                        searchPath.append(Route.discover)
                    }
                    // Dev: jump straight to the profile gate.
                    if args.contains("-profileGateDemo") { showProfileGate = true }
                }
            }
            .fullScreenCover(isPresented: $showProfileGate) {
                // The gate now only SELECTS a profile; account + Manage Profiles
                // live in Settings → Account. The design is an independent look
                // axis (Settings → Themes → Profile Screen).
                Group {
                    let done: () -> Void = { showProfileGate = false; deferSidebarAfterProfileGate() }
                    switch theme.profileStyle {
                    case .orivio: ProfileGateView(onSelected: done)
                    case .marquee: ThemedProfileGate(variant: .marquee, onSelected: done)
                    case .streamline: ThemedProfileGate(variant: .streamline, onSelected: done)
                    }
                }
                .environmentObject(theme)
                .environmentObject(profiles)
                .environmentObject(account)
            }
            // Returning to the app pulls the latest Continue Watching so changes
            // made on another device show up without a relaunch (local edits
            // already push immediately on every change).
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    sync?.refreshContinueWatching()
                    traktSync?.syncNow()
                }
            }
            // Keep Continue Watching live while browsing Home (tab 0), app
            // active, no player open. refreshContinueWatching pulls a full
            // snapshot; mergeRemote reconciles both adds and removes.
            .onReceive(continueWatchingPoll) { _ in
                guard scenePhase == .active, selectedTab == 0, playback == nil else { return }
                sync?.refreshContinueWatching()
            }
    }

    /// The sidebar's cold-launch fallback timers (3s in SidebarNav, 800ms from
    /// Home's onContentReady) keep running while the profile gate covers the
    /// screen, so by the time the user finishes picking a profile — which
    /// usually takes longer than that — `sidebarEnabled` is often already
    /// true. Without this, the instant the gate dismisses the focus engine
    /// lands on the nearest focusable view for the newly-revealed screen,
    /// which is the sidebar rail, popping it open instead of landing on Home.
    /// Briefly disable it again and re-enable after a beat, same pattern as
    /// the cold-launch path, so focus goes to Home's content first.
    private func deferSidebarAfterProfileGate() {
        sidebarEnabled = false
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            sidebarEnabled = true
        }
    }

    /// Dev-only: `-playerDemo` opens the player with Apple's public HLS test
    /// stream (`-playerDemoMKV` uses an MKV sample to exercise the FFmpeg
    /// engine) so playback UI can be verified without a stream addon.
    private func startPlayerDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wantsMKV = args.contains("-playerDemoMKV")
        guard wantsMKV || args.contains("-playerDemo") else { return }
        let meta = MetaItem(
            id: "tt0111161", type: "movie", name: wantsMKV ? "Demo Stream (MKV)" : "Demo Stream (HLS)"
        )
        let stream = Stream(
            name: wantsMKV ? "MKV Sample\n1080p" : "Apple HLS\n1080p",
            title: wantsMKV ? "Big Buck Bunny MKV sample" : "BipBop advanced fMP4 example",
            description: nil,
            url: wantsMKV
                ? "https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_5MB.mkv"
                : "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
            infoHash: nil, behaviorHints: nil
        )
        playback = PlaybackRequest(
            meta: meta, video: nil,
            entry: StreamEntry(addonName: "Demo", stream: stream),
            allEntries: [], resumePosition: nil
        )
    }

    /// Dev-only: `-detailDemo` jumps straight to a Detail screen for a known
    /// title so TMDB/Trakt enrichment (cast, trailers, more-like-this, comments)
    /// can be verified without navigating there by remote.
    private func startDetailDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        // `-detailDemoSeries` opens a known series so the episode browser +
        // Episode Details drawer can be screenshot-verified.
        if args.contains("-detailDemoSeries") {
            let meta = MetaItem(id: "tt0903747", type: "series", name: "Breaking Bad")
            if homePath.isEmpty { homePath.append(Route.detail(meta)) }
            return
        }
        guard args.contains("-detailDemo") else { return }
        let meta = MetaItem(id: "tt0111161", type: "movie", name: "The Shawshank Redemption")
        if homePath.isEmpty { homePath.append(Route.detail(meta)) }
    }

    private var content: some View {
        // Dev-only: `-settingsDemo` renders Settings full-screen (no sidebar) so
        // the settings chrome can be screenshotted cleanly in the sim.
        if ProcessInfo.processInfo.arguments.contains("-settingsDemo") {
            return AnyView(
                SettingsView()
                    .background(theme.palette.background.ignoresSafeArea())
            )
        }
        if ProcessInfo.processInfo.arguments.contains("-accountDemo") {
            return AnyView(
                ZStack { theme.palette.background.ignoresSafeArea(); AccountView() }
            )
        }
        if ProcessInfo.processInfo.arguments.contains("-traktQRDemo") {
            return AnyView(
                ZStack {
                    theme.palette.background.ignoresSafeArea()
                    TraktConnectPage(
                        code: TraktDeviceCode(deviceCode: "d", userCode: "AB12CD34",
                                              verificationURL: "https://trakt.tv/activate",
                                              interval: 5, expiresIn: 600),
                        expiresAt: Date().addingTimeInterval(600)
                    )
                }
                .environmentObject(theme)
            )
        }
        return AnyView(mainContent)
    }

    /// Whether the current tab is at its root grid (no pushed screen). When a
    /// Detail/Streams/etc. is pushed, the sidebar hides so that screen is
    /// full-bleed, exactly like the APK.
    private var showSidebar: Bool {
        switch selectedTab {
        case 0: return homePath.isEmpty
        case 1: return searchPath.isEmpty
        case 2: return libraryPath.isEmpty
        case 4: return liveTVPath.isEmpty
        case 10: return discoverPath.isEmpty   // Stremio Discover
        case 11: return addonsPath.isEmpty     // Stremio Addons
        default: return true   // Settings keeps the rail
        }
    }

    private var mainContent: some View {
        Group {
            if theme.isNetflixTheme {
                netflixLayout
            } else if theme.isStremioTheme {
                stremioLayout
            } else if theme.isCinemaTheme {
                cinemaLayout
            } else if theme.isOnyxTheme {
                onyxLayout
            } else if theme.isMaxTheme {
                maxLayout
            } else if theme.isHuluTheme {
                huluLayout
            } else {
                classicLayout
            }
        }
        // Developer FPS read-out over the whole UI (Settings → Performance).
        .overlay {
            if perf.settings.showFPSOverlay { FPSOverlay() }
        }
        // App-wide toast (Fusion): Added to Library / Marked Watched / etc.
        .overlay { FusionToastHost() }
        .fullScreenCover(item: $playback, onDismiss: {
            // Pop the auto-played source page ONLY after the cover has fully
            // torn down. Mutating the NavigationStack path in the same runloop
            // tick that dismisses the cover desyncs the stack — the path empties
            // but the pushed source view lingers as a focused "ghost" (looks
            // glitched; Back on it escapes to tvOS and quits the app). The extra
            // TabView layer in the Fusion layout makes that race fire reliably.
            // Deferring to onDismiss + the next tick sequences the two mutations.
            guard pendingAutoPlayPop else { return }
            pendingAutoPlayPop = false
            DispatchQueue.main.async { popActivePathForAutoPlay() }
        }) { request in
            PlayerScreen(
                request: request,
                addonManager: addonManager,
                progressStore: progressStore,
                playerSettings: playerSettings.settings,
                allowUnairedNextUp: homeCatalogSettings.showUnairedNextUp
            ) {
                // Just dismiss the cover; the auto-play pop runs in onDismiss.
                playback = nil
            }
        }
        .onChange(of: playback?.id) { _, _ in scrobbleForPlaybackChange() }
        // Feed the resolved system scheme to the theme so `.system` appearance
        // under the Apple TV theme can pick the matching palette.
        .onAppear { theme.systemIsDark = colorScheme == .dark }
        .onChange(of: colorScheme) { _, scheme in theme.systemIsDark = scheme == .dark }
    }

    /// The Apple TV theme's root: a native top tab bar (Liquid Glass on
    /// tvOS 26, the standard bar before that) over a soft clear backdrop —
    /// the Omni/Fusion-style layout. Same tabs, paths and view models as the
    /// Classic sidebar, so switching themes never loses state.
    private var atvLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                homeRoot
                    // Back at a tab ROOT is a no-op here (swallowed) so it
                    // doesn't quit the app — the TV/Home button exits. Pushed
                    // screens still pop normally via the NavigationStack.
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(0)

            NavigationStack(path: $searchPath) {
                searchRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
            .tabItem { Label("Library", systemImage: "bookmark.fill") }
            .tag(2)

            NavigationStack {
                ATVSettingsView(onOpenProfiles: { showProfileGate = true })
                    .onExitCommand { }
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(3)

            // Conditional tab declared LAST so toggling Live TV doesn't re-diff
            // (and reset) the Settings tab that would otherwise follow it.
            if liveTV.enabled {
                NavigationStack(path: $liveTVPath) {
                    liveTVRoot
                        .onExitCommand { }
                        .navigationDestination(for: Route.self) { destination(for: $0, path: $liveTVPath) }
                }
                .tabItem { Label("Live TV", systemImage: "tv.fill") }
                .tag(4)
            }
        }
        .background(ATVBackground())
    }

    /// The Cinema theme's root. A native top tab bar (a system component, not
    /// Modern's `atvLayout`); the Home tab renders `CinemaHomeView` — a from-
    /// scratch home with its OWN hero + rows + cards, including its own Continue
    /// Watching row (so the hold menu works). Search/Library/Live TV/Settings
    /// reuse the SHARED roots (not part of Modern/Nova).
    private var cinemaLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                cinemaRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(0)

            NavigationStack(path: $searchPath) {
                searchRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
            .tabItem { Label("Library", systemImage: "bookmark.fill") }
            .tag(2)

            NavigationStack {
                SettingsView()
                    .onExitCommand { }
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(3)

            // Live TV is the ONLY conditional tab, so it must be declared LAST:
            // toggling it then adds/removes the final child, leaving every other
            // tab's structural position (and NavigationStack identity) intact.
            // Declared before Settings, toggling it re-created the Settings stack
            // and reset the pane mid-use.
            if liveTV.enabled {
                NavigationStack(path: $liveTVPath) {
                    liveTVRoot
                        .onExitCommand { }
                        .navigationDestination(for: Route.self) { destination(for: $0, path: $liveTVPath) }
                }
                .tabItem { Label("Live TV", systemImage: "tv.fill") }
                .tag(4)
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
    }

    private var cinemaRoot: some View {
        CinemaHomeView(
            viewModel: homeViewModel,
            onSelect: { homePath.append(Route.detail($0)) },
            onResume: { resume($0) },
            onResumeFromStart: { resume($0, fromBeginning: true) },
            onPlayManually: { meta, video in playManually(meta, video) },
            onSeeAll: { addon, catalog, title in
                homePath.append(Route.catalogSeeAll(addon: addon, catalog: catalog, title: title))
            },
            onOpenCollection: { homePath.append(Route.collection($0)) }
        )
    }

    /// The Onyx theme's root: a faithful port of bobsupra/NuvioTVOS — the native
    /// collapsible sidebar (`.sidebarAdaptable`) over the near-black stage, with
    /// its own `OnyxHomeView`. Reuses the same shared tab roots + path bindings
    /// as every other layout, so switching themes never loses state.
    private var onyxLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                onyxRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(0)

            NavigationStack(path: $searchPath) {
                searchRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
            .tabItem { Label("Library", systemImage: "bookmark") }
            .tag(2)

            NavigationStack {
                SettingsView()
                    .onExitCommand { }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)

            // Conditional tab declared LAST so toggling Live TV doesn't re-diff
            // (and reset) the Settings tab that would otherwise follow it.
            if liveTV.enabled {
                NavigationStack(path: $liveTVPath) {
                    liveTVRoot
                        .onExitCommand { }
                        .navigationDestination(for: Route.self) { destination(for: $0, path: $liveTVPath) }
                }
                .tabItem { Label("Live TV", systemImage: "tv") }
                .tag(4)
            }
        }
        .modifier(OnyxSidebarTabStyle())
        .background(theme.palette.background.ignoresSafeArea())
    }

    private var onyxRoot: some View {
        OnyxHomeView(
            viewModel: homeViewModel,
            onSelect: { homePath.append(Route.detail($0)) },
            onResume: { resume($0) },
            onResumeFromStart: { resume($0, fromBeginning: true) },
            onPlayManually: { meta, video in playManually(meta, video) },
            onSeeAll: { addon, catalog, title in
                homePath.append(Route.catalogSeeAll(addon: addon, catalog: catalog, title: title))
            },
            onOpenCollection: { homePath.append(Route.collection($0)) }
        )
    }

    /// The Netflix-inspired theme's root: GROUND-UP chrome (like Fusion vs
    /// Classic) — a custom §17 top navigation floating over the black stage,
    /// one NavigationStack per tab. The tab roots and path bindings are the
    /// same shared ones the other layouts use, so switching themes never
    /// loses state; only the chrome differs.
    private var netflixLayout: some View {
        ZStack(alignment: .top) {
            NetflixBackground()

            netflixContent
                // Pages other than Home start below the floating bar; Home
                // stays full-bleed so the billboard art runs under it (§21).
                .padding(.top, selectedTab == 0 ? 0 : 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()

            // Hidden while a screen is pushed, same rule as the sidebar —
            // pushed screens run full-bleed (§18 Back pops them instead).
            if showSidebar {
                NetflixTopNav(
                    selected: $selectedTab,
                    focusBinding: $netflixNavFocus,
                    onProfileTap: { showProfileGate = true },
                    onTabSelected: { newTab in
                        // No sidebar collapse dance here — the bar is always
                        // visible at roots; focus stays on it until the user
                        // presses Down into the fresh page.
                        selectedTab = newTab
                    }
                )
                .focusSection()
            }
        }
    }

    /// The selected tab's screen for the Netflix layout. Back at a tab ROOT
    /// moves focus up to the top navigation (§18); pushed screens hold focus
    /// themselves, so their Back pops the NavigationStack instead.
    @ViewBuilder
    private var netflixContent: some View {
        switch selectedTab {
        case 1:
            NavigationStack(path: $searchPath) {
                searchRoot
                    .onExitCommand { netflixNavFocus = 1 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
        case 2:
            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { netflixNavFocus = 2 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
        case 3:
            // Interim settings surface (§79 restyle is a later session);
            // pushes the same shared detail panes as the other themes.
            NavigationStack {
                ATVSettingsView(onOpenProfiles: { showProfileGate = true })
                    .onExitCommand { netflixNavFocus = 3 }
            }
        case 4:
            NavigationStack(path: $liveTVPath) {
                liveTVRoot
                    .onExitCommand { netflixNavFocus = 4 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $liveTVPath) }
            }
        default:
            NavigationStack(path: $homePath) {
                homeRoot
                    .onExitCommand {
                        // Same lingering-Menu guard as the Classic layout: a
                        // second Menu delivered right after popping back from
                        // a pushed screen must not yank focus to the bar.
                        if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                        netflixNavFocus = 0
                    }
                    .onChange(of: homePath.count) { oldCount, newCount in
                        if newCount < oldCount { lastHomePopAt = Date() }
                    }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
        }
    }

    /// The Stremio theme's root: its left icon TabBar (`StremioNav`) beside
    /// FULLY CUSTOM Stremio screens (`stremioContent` — its own Board,
    /// Settings, Search, Library, none of them the shared Classic screens).
    /// Reuses only the sidebar focus machinery (`sidebarFocus`,
    /// `sidebarEnabled`, `selectTab`) so navigation works unchanged.
    private var stremioLayout: some View {
        ZStack(alignment: .leading) {
            StremioSurfaces.background.ignoresSafeArea()

            stremioContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .opacity(sidebarFocus != nil && showSidebar ? 1 : 0)
                }
                .padding(.leading, showSidebar ? StremioNav.collapsedWidth : 0)
                .focusSection()

            if showSidebar {
                StremioNav(selected: $selectedTab, focusBinding: $sidebarFocus,
                           onProfileTap: { showProfileGate = true },
                           onTabSelected: { newTab in selectTab(newTab) })
                    .focusSection()
                    .disabled(!sidebarEnabled)
                    .onExitCommand { collapseSidebarFromExit() }
                    .onMoveCommand { direction in
                        if direction == .right { collapseSidebarFromExit() }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        sidebarEnabled = true
                    }
            }
        }
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.32, dampingFraction: 0.85) : nil, value: showSidebar)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.32, dampingFraction: 0.85) : nil, value: sidebarFocus != nil)
        .background(StremioSurfaces.background)
    }

    /// Stremio's custom per-tab screens, each in its own NavigationStack so
    /// pushes (StremioDetailView etc.) stay within the tab. Back at a tab root
    /// opens the tab bar (`sidebarFocus`).
    @ViewBuilder
    private var stremioContent: some View {
        switch selectedTab {
        case 1:
            NavigationStack(path: $searchPath) {
                StremioSearchView(
                    viewModel: searchViewModel,
                    onSelect: { searchPath.append(Route.detail($0)) },
                    onBackAtRoot: { sidebarFocus = 1 }
                )
                .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
        case 2:
            NavigationStack(path: $libraryPath) {
                StremioLibraryView(
                    onSelect: { libraryPath.append(Route.detail($0)) },
                    onResume: { resume($0) },
                    onBackAtRoot: { sidebarFocus = 2 }
                )
                .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
        case 3:
            NavigationStack {
                StremioSettingsView(
                    onOpenProfiles: { showProfileGate = true },
                    onBackAtRoot: { sidebarFocus = 3 }
                )
            }
        case 10:
            NavigationStack(path: $discoverPath) {
                StremioDiscoverView(
                    onSelect: { discoverPath.append(Route.detail($0)) },
                    onBackAtRoot: { sidebarFocus = 10 }
                )
                .navigationDestination(for: Route.self) { destination(for: $0, path: $discoverPath) }
            }
        case 11:
            NavigationStack(path: $addonsPath) {
                StremioAddonsView(onBackAtRoot: { sidebarFocus = 11 })
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $addonsPath) }
            }
        default:
            NavigationStack(path: $homePath) {
                StremioBoardView(
                    viewModel: homeViewModel,
                    onSelect: { homePath.append(Route.detail($0)) },
                    onResume: { resume($0) },
                    onSeeAll: { row in
                        if let addon = row.addon, let catalog = row.catalog {
                            homePath.append(Route.catalogSeeAll(addon: addon, catalog: catalog, title: row.title))
                        }
                    },
                    onContentReady: {
                        Task { try? await Task.sleep(nanoseconds: 800_000_000); sidebarEnabled = true }
                    },
                    onBackAtRoot: {
                        if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                        sidebarFocus = 0
                    }
                )
                .onChange(of: homePath.count) { oldCount, newCount in
                    guard newCount < oldCount else { return }
                    lastHomePopAt = Date()
                    // Rail parity with Classic: popping all the way back to the
                    // Board keeps the icon rail non-focusable for a beat so focus
                    // lands on a Board card instead of the rail springing open.
                    if newCount == 0 {
                        sidebarEnabled = false
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            sidebarEnabled = true
                        }
                    }
                }
                .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
        }
    }

    /// The Max theme's root: the ported MaxTV UI (`MaxRootView`) driven by Orivio
    /// data, inside the shared home NavigationStack so selecting a title pushes
    /// Orivio's real DetailView / streams / player. All browse navigation (the
    /// sidebar, sections, category drill-down) is self-contained in MaxRootView.
    private var maxLayout: some View {
        NavigationStack(path: $homePath) {
            MaxRootView(
                homeViewModel: homeViewModel,
                searchViewModel: searchViewModel,
                onSelect: { homePath.append(Route.detail($0)) },
                onOpenProfiles: { showProfileGate = true },
                onOpenChannel: { homePath.append(Route.streams($0, nil)) },
                onOpenCollection: { homePath.append(Route.collection($0)) }
            )
            .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
        }
        .background(MaxStyle.stage.ignoresSafeArea())
    }

    /// The "Streamline" (Hulu) theme's root: the ported HuluTV UI (`HuluRootView`)
    /// driven by Orivio data, inside the shared home NavigationStack. The hero
    /// PLAY pushes the stream picker; DETAILS/cards push DetailView.
    private var huluLayout: some View {
        NavigationStack(path: $homePath) {
            HuluRootView(
                homeViewModel: homeViewModel,
                searchViewModel: searchViewModel,
                onSelect: { homePath.append(Route.detail($0)) },
                onPlay: { homePath.append(Route.streams($0, nil)) },
                onResume: { resume($0) },
                onOpenProfiles: { showProfileGate = true },
                onOpenCollection: { homePath.append(Route.collection($0)) }
            )
            .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
        }
        .background(HuluStyle.stage.ignoresSafeArea())
    }

    private var classicLayout: some View {
        // OVERLAY layout, not an HStack: when the sidebar expanded inside an
        // HStack its width change re-laid-out the ENTIRE content column (every
        // Home row) on every frame of the spring — the "sidebar isn't smooth"
        // jank on the A10X. Now the content is fixed (padded past the
        // collapsed rail) and the expanding panel just draws OVER the dimmed
        // content; the only things animating are the panel's own width and
        // the dim's opacity.
        ZStack(alignment: .leading) {
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Dim the content while the sidebar is expanded/focused (APK
                    // behavior). The dim STARTS at the sidebar's own tone right
                    // at the expanded panel's seam (fixed coordinates now — the
                    // content no longer moves) and eases into the dim, so
                    // there's no hard bright/dark two-tone line at the edge.
                    // Always mounted with an animated opacity (not an insert
                    // transition) so it fades in IN LOCKSTEP with the sidebar's
                    // expansion instead of popping in ahead of it.
                    LinearGradient(
                        stops: [
                            // Everything left of ~0.11 sits UNDER the expanded
                            // panel (tvOS is a fixed 1920pt layout: the panel
                            // edge lands at (270-64)/(1920-64) ≈ 0.11 of the
                            // content width).
                            .init(color: theme.palette.backgroundElevated, location: 0),
                            .init(color: theme.palette.backgroundElevated, location: 0.111),
                            .init(color: .black.opacity(0.55), location: 0.20),
                            .init(color: .black.opacity(0.55), location: 1)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(sidebarFocus != nil && showSidebar ? 1 : 0)
                }
                // HOME runs full-bleed (hero to the edge, icons float over it
                // on the soft background column below). Every OTHER tab keeps
                // the original 64pt inset so its content sits beside the rail,
                // not under it — that also keeps left-navigation into the
                // sidebar clean (Library was letting focus slip into the panel
                // when its grid ran full-bleed under the rail). Pushed screens
                // (showSidebar == false) stay full-bleed as before.
                .padding(.leading, showSidebar && selectedTab != 0 ? SidebarNav.collapsedWidth : 0)
                .focusSection()

            // Home only: a soft left column in the BACKGROUND colour behind the
            // icons. Grounds them over the hero art without the contrasting
            // grey the old reserved strip had — it IS the background, fading
            // into the content. Solid over the icons (~0-90pt), fully clear by
            // ~135pt — BEFORE the content's leading edge (~145pt) so the hero
            // text / row labels / posters don't get darkened by the fade.
            if selectedTab == 0 && showSidebar {
                LinearGradient(
                    stops: [
                        .init(color: theme.palette.background, location: 0),
                        .init(color: theme.palette.background, location: 0.66),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                // Anchored at the very left edge, narrow enough that the fade
                // completes before the content — the earlier 230pt column ran
                // its tail across the first posters/labels.
                .frame(width: 135)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if showSidebar {
                SidebarNav(selected: $selectedTab, focusBinding: $sidebarFocus,
                           onProfileTap: { showProfileGate = true },
                           onTabSelected: { newTab in selectTab(newTab) })
                    // Nudge the collapsed icons left (clip-safe, moves with the
                    // rail's clip region). ~48pt ≈ 1.2in on a 55" panel — was
                    // -8, moved another ~40pt (≈1in) left. Snaps back to 0 when
                    // the panel expands so labels aren't pushed off the edge.
                    .offset(x: sidebarFocus == nil ? -48 : 0)
                    .focusSection()
                    .disabled(!sidebarEnabled)
                    // Back while IN the sidebar collapses it into content
                    // instead of falling through to the system (which quit the
                    // app). Exit the app with the Siri remote's TV/Home button.
                    // NOT the same helper as picking a tab: nothing is being
                    // freshly mounted here (you're just closing the panel on
                    // the tab you're already on), so this always uses the fast
                    // fixed-delay re-enable — never waits on onContentReady,
                    // which wouldn't fire again since Home isn't reloading.
                    .onExitCommand { collapseSidebarFromExit() }
                    // Swipe/press RIGHT exits into content. In the overlay
                    // layout the content's focus section is UNDER the panel
                    // (overlapping, not beside it), so the focus engine sees
                    // no candidate "to the right" and the move dies — catch
                    // it and run the same collapse Back uses.
                    .onMoveCommand { direction in
                        if direction == .right { collapseSidebarFromExit() }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    // The sidebar stays non-focusable until Home has content to
                    // hold initial focus (onContentReady) — otherwise the app
                    // boots with the sidebar expanded over an empty screen. The
                    // timer is only a fallback if Home never loads (or another
                    // tab is the demo entry point).
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        sidebarEnabled = true
                    }
            }
        }
        // Matches SidebarNav's own expand spring so the width change, the
        // content reflow, and the dim all move together as one motion.
        // (nil when "Sidebar animation" is off in Settings → Performance:
        // the sidebar and its dim snap instantly.)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: showSidebar)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: sidebarFocus != nil)
        .background(theme.palette.background)
    }

    /// Handles tapping a sidebar tab. Two things happen together:
    /// 1. Clear `sidebarFocus` — this collapses the panel (expanded and the dim
    ///    both key off it) and stops the still-set focus state from yanking
    ///    focus back to the sidebar when it re-enables. Clearing it ALONE just
    ///    re-lands focus on the nearest sidebar item (an icon / the profile
    ///    button), so also:
    /// 2. Make the whole sidebar momentarily unfocusable, so the focus engine
    ///    is forced onto the only remaining candidates — the tab's content.
    ///
    /// `newTab` arrives BEFORE `selectedTab` is mutated (SidebarNav fires this
    /// first), so `selectedTab` here still holds the tab we're coming FROM —
    /// that's what lets us tell a genuine tab change apart from re-tapping the
    /// tab already on screen (see the comment below on why that distinction
    /// matters).
    private func selectTab(_ newTab: Int) {
        let enteringHomeFresh = selectedTab != 0 && newTab == 0
        selectedTab = newTab
        sidebarFocus = nil
        sidebarEnabled = false

        // Switching TO Home FROM another tab rebuilds HomeView from scratch
        // (the switch in `selectedContent` tears it down when you're on
        // another tab), and its rows/hero backdrop can take a beat longer to
        // lay out and become focusable than a blind fixed-delay guess —
        // especially right after a full rebuild. If a timer re-enabled the
        // sidebar before Home's content is actually focusable, the sidebar is
        // the only focusable thing left and reclaims focus.
        //
        // Home already reports real readiness via `onContentReady` (fired
        // after its reload completes, with its own grace period) — so ONLY
        // for a genuine transition into Home, skip the timer and let that be
        // the sole re-enabler.
        //
        // Critically, this must NOT apply when Home was already on screen
        // (e.g. re-tapping the Home icon just to close the panel): HomeView
        // isn't reloading in that case, so `onContentReady` will never fire
        // again and `sidebarEnabled` would be stuck `false` forever — the
        // sidebar would become permanently unreachable. That's why this reads
        // `enteringHomeFresh`, captured before the mutation above, rather than
        // just checking `selectedTab == 0`.
        guard enteringHomeFresh else {
            scheduleSidebarReenable()
            return
        }
    }

    /// Closes the panel when Back is pressed WHILE IT'S the one focused —
    /// i.e. you opened it but didn't pick anything. No tab change happens
    /// here and nothing is being freshly mounted, so this always uses the
    /// fast fixed-delay re-enable regardless of which tab is active — it must
    /// NOT defer to Home's `onContentReady`, which won't fire again since
    /// nothing is reloading (this was the bug behind "I can no longer get
    /// into the side panel" after a few Back presses: relying on Home's
    /// reload signal here latched `sidebarEnabled` false with nothing left to
    /// ever flip it back true).
    private func collapseSidebarFromExit() {
        sidebarFocus = nil
        sidebarEnabled = false
        scheduleSidebarReenable()
    }

    private func scheduleSidebarReenable() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            sidebarEnabled = true
        }
    }

    /// The sidebar-opening Back handler is attached to each tab's ROOT screen
    /// (see `selectedContent`), NOT here — wrapping the whole NavigationStack
    /// made `onExitCommand` swallow Back at every depth, so a pushed screen
    /// (e.g. a detail opened from Discovery) could never pop.
    private var contentColumn: some View {
        selectedContent
    }

    // MARK: - Shared tab roots (used by BOTH the Classic sidebar layout and
    // the Apple TV top-bar layout, so the two themes stay in behavioral
    // lockstep — only the chrome around them differs).

    private var homeRoot: some View {
        HomeView(
            viewModel: homeViewModel,
            onSelect: { homePath.append(Route.detail($0)) },
            onResume: { resume($0) },
            onResumeFromStart: { resume($0, fromBeginning: true) },
            onPlayManually: { meta, video in playManually(meta, video) },
            onOpenCollection: { homePath.append(Route.collection($0)) },
            onSeeAll: { addon, catalog, title in
                homePath.append(Route.catalogSeeAll(addon: addon, catalog: catalog, title: title))
            },
            onContentReady: {
                // Give the freshly-loaded rows a beat to render and
                // take initial focus before the sidebar becomes
                // focusable, or the focus engine grabs the top-left
                // (sidebar) and boots the app with it expanded.
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    sidebarEnabled = true
                }
            },
            // Back at the start of a row: Classic opens the sidebar; Netflix
            // focuses its custom top bar (§18); Fusion is a no-op (tvOS
            // doesn't expose programmatic focus of a native tab bar).
            onHomeBack: {
                if theme.isNetflixTheme { netflixNavFocus = 0 }
                else if !theme.isAppleTVTheme { sidebarFocus = 0 }
            }
        )
    }

    private var searchRoot: some View {
        SearchView(
            viewModel: searchViewModel,
            onSelect: { searchPath.append(Route.detail($0)) },
            onOpenDiscover: { searchPath.append(Route.discover) }
        )
    }

    private var libraryRoot: some View {
        LibraryView(
            onSelect: { libraryPath.append(Route.detail($0)) },
            onOpenCloud: { libraryPath.append(Route.cloudLibrary) },
            // At the top of the grid, Back leaves: Classic opens the sidebar,
            // Netflix focuses its top bar, Fusion is a no-op (focus rises to
            // the native tab bar on the next Up).
            onBackAtRoot: {
                if theme.isNetflixTheme { netflixNavFocus = 2 }
                else if !theme.isAppleTVTheme { sidebarFocus = 2 }
            }
        )
    }

    private var liveTVRoot: some View {
        LiveTVView(
            onSelectChannel: { channel in liveTVPath.append(Route.streams(channel, nil)) },
            onPlayDirect: { channel in playLiveChannel(channel) }
        )
    }

    /// The screen for the selected sidebar tab, each in its own NavigationStack
    /// so per-tab back-stacks stay independent.
    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case 1:
            NavigationStack(path: $searchPath) {
                searchRoot
                    // Back at the tab ROOT opens the sidebar; when a screen is
                    // pushed, focus is in that screen (not here) so the
                    // NavigationStack pops instead.
                    .onExitCommand { sidebarFocus = 1 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
        case 2:
            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { sidebarFocus = 2 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
        case 3:
            SettingsView()
                .onExitCommand { sidebarFocus = 3 }
        case 4:
            NavigationStack(path: $liveTVPath) {
                liveTVRoot
                    .onExitCommand { sidebarFocus = 4 }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $liveTVPath) }
            }
        default:
            NavigationStack(path: $homePath) {
                homeRoot
                .onExitCommand {
                    // Ignore a Menu press that lands right after popping back
                    // from a pushed screen (detail / streams). tvOS sometimes
                    // delivers a lingering second Menu to Home after the pop,
                    // which would spuriously open the sidebar.
                    if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                    sidebarFocus = 0
                }
                .onChange(of: homePath.count) { oldCount, newCount in
                    guard newCount < oldCount else { return }
                    lastHomePopAt = Date()
                    // Popping all the way back to Home: keep the sidebar
                    // non-focusable for a beat so the focus engine lands on a
                    // Home card instead of grabbing the rail (which springs the
                    // sidebar open). Same trick as the cold-launch path.
                    if newCount == 0 {
                        sidebarEnabled = false
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            sidebarEnabled = true
                        }
                    }
                }
                .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
        }
    }

    /// Shared navigation destinations. `path` is the binding for whichever
    /// tab's stack is presenting, so nested pushes stay within that tab.
    @ViewBuilder
    private func destination(for route: Route, path: Binding<NavigationPath>) -> some View {
        switch route {
        case .detail(let item):
            // Stremio always uses its own MetaDetails. Otherwise the detail page
            // is an independent look axis (Settings → Themes → Detail Page).
            if theme.isStremioTheme {
                StremioDetailView(
                    item: item,
                    onPlay: { meta, video in path.wrappedValue.append(Route.streams(meta, video)) },
                    onPlayManually: { meta, video in path.wrappedValue.append(Route.streamsManual(meta, video)) },
                    onPlayFromBeginning: { meta, video in path.wrappedValue.append(Route.streamsFromStart(meta, video)) },
                    onSelectItem: { path.wrappedValue.append(Route.detail($0)) }
                )
            } else if theme.detailStyle != .orivio {
                ThemedDetailView(
                    variant: theme.detailStyle,
                    item: item,
                    onPlay: { meta, video in path.wrappedValue.append(Route.streams(meta, video)) },
                    onPlayFromBeginning: { meta, video in path.wrappedValue.append(Route.streamsFromStart(meta, video)) },
                    onSelectItem: { path.wrappedValue.append(Route.detail($0)) }
                )
            } else {
                DetailView(
                    item: item,
                    onPlay: { meta, video in path.wrappedValue.append(Route.streams(meta, video)) },
                    onPlayManually: { meta, video in path.wrappedValue.append(Route.streamsManual(meta, video)) },
                    onPlayFromBeginning: { meta, video in path.wrappedValue.append(Route.streamsFromStart(meta, video)) },
                    onSelectItem: { path.wrappedValue.append(Route.detail($0)) },
                    onSelectPerson: { id, name in path.wrappedValue.append(Route.person(id: id, name: name)) },
                    onSelectCompany: { id, name in path.wrappedValue.append(Route.tmdbCompany(id: id, name: name)) }
                )
            }
        case .collection(let collection):
            CollectionView(collection: collection) { path.wrappedValue.append(Route.detail($0)) }
        case .person(let id, let name):
            CastDetailView(personID: id, personName: name) { path.wrappedValue.append(Route.detail($0)) }
        case .tmdbCompany(let id, let name):
            TMDBBrowseView(companyID: id, title: name) { path.wrappedValue.append(Route.detail($0)) }
        case .catalogSeeAll(let addon, let catalog, let title):
            CatalogSeeAllView(addon: addon, catalog: catalog, title: title) { path.wrappedValue.append(Route.detail($0)) }
        case .discover:
            DiscoverView { path.wrappedValue.append(Route.detail($0)) }
        case .cloudLibrary:
            CloudLibraryView { meta, entry in
                startPlayback(PlaybackRequest(
                    meta: meta, video: nil, entry: entry,
                    allEntries: [entry], resumePosition: nil
                ))
            }
        case .streams(let meta, let video):
            StreamsView(
                meta: meta, video: video,
                // Auto Link Selector auto-played: flag a deferred pop; the real
                // pop happens when the player closes (see the player cover),
                // never while this view's resolve Task is still running.
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
                let key = ProgressStore.key(metaID: meta.id, video: video)
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: progressStore.progress(for: key)?.positionSeconds
                ))
            }
        case .streamsManual(let meta, let video):
            StreamsView(meta: meta, video: video, forceManual: true) { entry, all in
                let key = ProgressStore.key(metaID: meta.id, video: video)
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: progressStore.progress(for: key)?.positionSeconds
                ))
            }
        case .streamsFromStart(let meta, let video):
            // Same picker, but playback ignores any saved progress (Start Over).
            StreamsView(meta: meta, video: video) { entry, all in
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: nil
                ))
            }
        case .streamsResume(let meta, let video, let fromStart):
            // Continue Watching: re-scrape and auto-play the best format match,
            // with the full list as the player's failover. Start Over plays the
            // matched link from 0:00; a normal resume from the saved position.
            let key = ProgressStore.key(metaID: meta.id, video: video)
            let progress = progressStore.progress(for: key)
            StreamsView(
                meta: meta, video: video,
                resumeAutoPlay: true,
                resumeSignature: progress?.streamSignature,
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: fromStart ? nil : progress?.positionSeconds
                ))
            }
        }
    }

    /// Trakt scrobble on the playback lifecycle: `start` when a title begins,
    /// `stop` with the last known progress when it ends. Best-effort and
    /// gated on sign-in + the scrobble toggle; only tt… ids scrobble.
    @State private var scrobblingItem: (meta: MetaItem, video: MetaVideo?)?

    private func scrobbleForPlaybackChange() {
        guard trakt.isSignedIn, trakt.scrobbleEnabled, let token = trakt.accessToken else {
            scrobblingItem = nil
            return
        }
        if let request = playback {
            // Playback started.
            scrobblingItem = (request.meta, request.video)
            let fraction = request.resumePosition.flatMap { pos -> Double? in
                let key = ProgressStore.key(metaID: request.meta.id, video: request.video)
                guard let duration = progressStore.progress(for: key)?.durationSeconds, duration > 0 else { return nil }
                return pos / duration * 100
            } ?? 0
            Task {
                await TraktService.scrobble(
                    action: .start, imdbID: request.meta.id, type: request.meta.type,
                    season: request.video?.season, episode: request.video?.episode,
                    progress: fraction, accessToken: token
                )
            }
        } else if let item = scrobblingItem {
            // Playback ended — report final progress.
            scrobblingItem = nil
            let key = ProgressStore.key(metaID: item.meta.id, video: item.video)
            let fraction = (progressStore.progress(for: key)?.fraction ?? 0) * 100
            Task {
                await TraktService.scrobble(
                    action: .stop, imdbID: item.meta.id, type: item.meta.type,
                    season: item.video?.season, episode: item.video?.episode,
                    progress: fraction, accessToken: token
                )
            }
        }
    }

    /// Resume from Continue Watching. Items saved on this device carry the
    /// stream URL and replay directly; items pulled from the account have no
    /// URL (the backend doesn't store it), so we route to source selection.
    /// Single entry point for starting playback. External-app engine hands
    /// the stream straight to the chosen player (Infuse etc.) instead of
    /// opening Nuvio's own player; if the chosen app was uninstalled, any
    /// other installed one is used; none installed → play internally.
    /// Play a direct Live TV channel (M3U): wrap its URL in a one-off stream and
    /// go straight to the player — no source picker, no debrid.
    private func playLiveChannel(_ channel: LiveChannel) {
        guard let url = channel.directURL else { return }
        let stream = Stream(name: "Live", title: channel.name, description: nil,
                            url: url, infoHash: nil, behaviorHints: nil)
        let entry = StreamEntry(addonName: "Live TV", stream: stream)
        let meta = MetaItem(id: channel.id, type: "tv", name: channel.name,
                            poster: channel.logo, background: channel.logo, logo: channel.logo)
        startPlayback(PlaybackRequest(
            meta: meta, video: nil, entry: entry, allEntries: [entry], resumePosition: nil
        ))
    }

    /// Pop the source page off the active tab's stack after an Auto Link
    /// Selector auto-play, so backing out of the player returns to the title
    /// page. Safe here because the player has fully closed by now. The player
    /// covers the stack while it's up, so the top entry is still the source page.
    private func popActivePathForAutoPlay() {
        switch selectedTab {
        case 0: if !homePath.isEmpty { homePath.removeLast() }
        case 1: if !searchPath.isEmpty { searchPath.removeLast() }
        case 2: if !libraryPath.isEmpty { libraryPath.removeLast() }
        case 4: if !liveTVPath.isEmpty { liveTVPath.removeLast() }
        default: break
        }
    }

    private func startPlayback(_ request: PlaybackRequest) {
        if playerSettings.settings.playerEngine == .external,
           let urlString = request.entry.stream.url {
            let chosen = ExternalPlayers.player(id: playerSettings.settings.externalPlayerID)
            let target = (chosen?.isInstalled == true ? chosen : nil) ?? ExternalPlayers.installed.first
            if let target {
                if playerSettings.settings.externalPlayerForwardSubtitles {
                    // Fetch a preferred-language subtitle, then hand off (async).
                    Task {
                        let sub = await externalSubtitleURL(for: request)
                        target.open(streamURL: urlString, subtitleURL: sub)
                    }
                } else {
                    target.open(streamURL: urlString)
                }
                return
            }
        }
        playback = request
    }

    /// Best subtitle URL from the installed subtitle addons for this playback,
    /// preferring the user's subtitle language. nil when none is found.
    private func externalSubtitleURL(for request: PlaybackRequest) async -> String? {
        let providers = addonManager.subtitleAddons
        guard !providers.isEmpty else { return nil }
        let id = request.video?.id ?? request.meta.id
        let type = request.meta.type
        let preferred = playerSettings.settings.preferredSubtitleLanguage.lowercased()
        var firstAny: String?
        for addon in providers {
            let subs = (try? await StremioAPI.subtitles(addon: addon, type: type, id: id)) ?? []
            if firstAny == nil { firstAny = subs.first?.url }
            if !preferred.isEmpty,
               let match = subs.first(where: { ($0.lang ?? "").lowercased().hasPrefix(preferred) }) {
                return match.url
            }
        }
        return firstAny
    }

    /// Route an incoming `nuvio://` / `stremio://` deep link.
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLinkService.parse(url) else { return }
        switch link {
        case .meta(let type, let id):
            // Open the title on the Home tab. DetailView fetches full meta +
            // canonicalizes tmdb→tt from this id.
            let meta = MetaItem(id: id, type: type, name: "")
            selectedTab = 0
            homePath.append(Route.detail(meta))
        case .addonInstall(let manifestURL):
            Task { try? await addonManager.install(manifestURL: manifestURL) }
        }
    }

    private func resume(_ progress: WatchProgress, fromBeginning: Bool = false) {
        Task { await resumeResolved(progress, fromBeginning: fromBeginning) }
    }


    /// Route to the Sources page (manual), resolving a tmdb: identity first.
    /// Always the manual list — this is the "Play Manually" affordance, so it
    /// bypasses the Auto Link Selector even when a profile has it on.
    private func playManually(_ meta: MetaItem, _ video: MetaVideo?) {
        // Navigate immediately — don't block the transition on a tmdb→tt
        // lookup. StreamsView canonicalizes the id itself (effectiveStreamID),
        // so pushing the raw meta opens the Sources screen at once (with its
        // own loading state) instead of leaving the card on screen for ~2s.
        homePath.append(Route.streamsManual(meta, video))
    }

    /// Continue Watching resume. TMDB-sourced items are stored as `tmdb:<n>`
    /// (and episodes as `tmdb:<n>:<s>:<e>`), but Cinemeta and Torrentio only
    /// speak IMDb `tt` ids — so resuming one directly found no metadata and no
    /// streams (the "metadata not found" a show hit that had never been opened
    /// through its Detail page, which is where this same resolve normally
    /// happens). Canonicalize to the `tt` id first, then migrate the stored
    /// entry so the card doesn't fork into a duplicate under the new key.
    @MainActor
    private func resumeResolved(_ progress: WatchProgress, fromBeginning: Bool) async {
        var metaID = progress.metaID
        // TMDB-sourced ids can't be served by Cinemeta/Torrentio — resolve to
        // the IMDb tt id (DetailView does the same).
        if metaID.hasPrefix("tmdb:"), let n = Int(metaID.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: progress.type != "series") {
            metaID = tt
        }

        // Reconstruct the CANONICAL Stremio episode id (`showId:season:episode`)
        // from the parts rather than trusting `progress.id`. Synced entries key
        // episodes by the backend's `video_id`, which falls back to the bare
        // SHOW id when the backend didn't send one — so resuming a synced
        // episode used to fetch show-level streams (none for a series) and fail
        // with "no sources", while opening via Details (which builds the id
        // correctly) worked. Only for tt-based shows; leave exotic id schemes
        // (kitsu: etc.) and movies alone.
        var episodeID = progress.id
        if metaID.hasPrefix("tt"), let season = progress.season, let episode = progress.episode {
            episodeID = "\(metaID):\(season):\(episode)"
        } else if metaID != progress.metaID {
            // tmdb → tt movie (no episode): the id is just the show/movie id.
            episodeID = metaID
        }

        // Migrate the stored entry if the identity changed, so the corrected
        // key doesn't fork a duplicate Continue Watching card.
        if episodeID != progress.id || metaID != progress.metaID {
            progressStore.recanonicalize(oldID: progress.id, newID: episodeID, newMetaID: metaID)
        }

        let meta = MetaItem(
            id: metaID,
            type: progress.type,
            name: progress.name,
            poster: progress.poster,
            background: progress.background,
            logo: progress.logo
        )
        // Rebuild the episode identity so progress keeps saving under the
        // episode key instead of forking a second entry under the show.
        let video: MetaVideo? = progress.season != nil || progress.episode != nil
            ? MetaVideo(
                id: episodeID,
                title: progress.episodeTitle,
                season: progress.season,
                episode: progress.episode
            )
            : nil
        // Resume ALWAYS re-scrapes a fresh link now: a remembered URL from a
        // debrid/Comet-style addon expires, so replaying it "fails to load" and
        // (with no failover alternates) drops you back to 0:00. Instead route to
        // the source picker, which auto-plays the link best matching what was
        // last watched, with the full list as failover. Start Over takes the
        // same matched-link path but plays from 0:00.
        homePath.append(Route.streamsResume(meta, video, fromStart: fromBeginning))
    }
}
