import SwiftUI

@main
struct NuvioTVApp: App {
    /// Reclaim orphaned player scratch space before anything else runs. A
    /// remux session that got jetsammed leaves its segment directory behind
    /// with no owner left to delete it, and nothing else in the app ever
    /// swept them — launch is the one moment we know none of them are live.
    init() { PlayerTempSweep.sweepAtLaunch() }

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
    /// Auto Link Selector resolves the best source as usual, then hands the
    /// finished URL to Infuse instead of the in-app player (hold-Play).
    case streamsInfuse(MetaItem, MetaVideo?)
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
    @EnvironmentObject private var stremioAccount: StremioAccountStore
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
    @State private var stremioSync: StremioSyncManager?
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
    /// The rail is briefly non-focusable at launch so initial focus lands in
    /// the CONTENT (the app boots with the rail collapsed and a card focused).
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
                ScrubThumbnailer.runSelfTestIfRequested()
            }
            .task {
                if sync == nil {
                    // Finishing a title records it in watched history.
                    progressStore.onFinished = { [weak watched] meta, video in
                        watched?.mark(meta: meta, video: video)
                    }
                    let nuvioSync = NuvioSyncManager(
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
                    sync = nuvioSync
                    nuvioSync.enrichContinueWatchingEnabled = { [tmdbSettings] in
                        tmdbSettings.settings.enrichContinueWatching
                    }
                    // Trakt two-way sync (history / watched badges + Continue
                    // Watching). Separate opt-in destination from the account.
                    // Trakt scoping must survive being signed out of Orivio:
                    // the sync manager owns profile scoping for every other
                    // store, but it only runs while signed in.
                    profiles.onSwitchLocal = { [weak trakt] id in trakt?.setProfile(id) }
                    profiles.onProfileDeleted = { [weak trakt] id in trakt?.forgetProfile(id) }
                    traktSync = TraktSyncManager(
                        trakt: trakt, watched: watched, progress: progressStore,
                        library: library, ratings: ratings, addonManager: addonManager
                    )
                    let stremioManager = StremioSyncManager(
                        stremio: stremioAccount,
                        addonManager: addonManager,
                        library: library,
                        progress: progressStore,
                        watched: watched
                    )
                    stremioManager.onMergedFromStremio = { [weak nuvioSync, account] in
                        guard account.authState.isSignedIn else { return }
                        await nuvioSync?.pushThisDevice()
                    }
                    stremioSync = stremioManager
                    // Fix up any already-installed Community Collections after
                    // launch has yielded. Keep network-backed logo migration
                    // out of app-open startup; that runs when the collection
                    // screen is opened.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        CommunityCollections.runLaunchMigrations(collections: collections)
                    }
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
                    if args.contains("-discoverDemo") {
                        selectedTab = 1
                        searchPath.append(Route.discover)
                    }
                    // Dev: report what Trakt resolves to for the ACTIVE profile,
                    // after sync has had a chance to interfere. Reading the raw
                    // defaults keys can't answer this — the answer depends on
                    // which scope the store chose.
                    if args.contains("-traktReport") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            let report = "profile=\(profiles.activeProfileID)"
                                + " perProfile=\(trakt.perProfileAccounts)"
                                + " signedIn=\(trakt.isSignedIn)"
                                + " user=\(trakt.username ?? "-")"
                            UserDefaults.standard.set(report, forKey: "dev.traktReport")
                        }
                    }
                    // Dev: remove a title from Continue Watching through the
                    // same call the hold menu makes, so the fan-out to Orivio,
                    // Trakt and Stremio can be exercised without the tvOS UI.
                    if let meta = args.first(where: { $0.hasPrefix("-removeCW:") })?
                        .replacingOccurrences(of: "-removeCW:", with: ""), !meta.isEmpty {
                        progressStore.removeShow(metaID: meta, notifyTrakt: true)
                    }
                    // Dev: flip per-profile Trakt and/or switch profile, the
                    // same calls Settings and the profile gate make.
                    if args.contains("-traktPerProfile") { trakt.perProfileAccounts = true }
                    if args.contains("-traktShared") { trakt.perProfileAccounts = false }
                    if let f = args.first(where: { $0.hasPrefix("-traktForget:") })?
                        .replacingOccurrences(of: "-traktForget:", with: ""), let id = Int(f) {
                        trakt.forgetProfile(id)   // same path a profile deletion takes
                    }
                    if let p = args.first(where: { $0.hasPrefix("-profile:") })?
                        .replacingOccurrences(of: "-profile:", with: ""), let id = Int(p) {
                        profiles.setActive(id)
                    }
                    // Dev: jump straight to the profile gate.
                    if args.contains("-profileGateDemo") { showProfileGate = true }
                    // Dev/recovery: run the account-wide watch-history clear on
                    // launch (same code path as the Settings button) — lets a
                    // flooded device be repaired over devicectl without driving
                    // the tvOS UI. Waits for sign-in state to settle first.
                    // Dev/recovery: import Continue Watching rows from
                    // Documents/orivio-progress-restore.json (an array of
                    // WatchProgress, e.g. lifted from a device backup) and push
                    // them to the account. Each row is re-stamped to NOW, both
                    // so it wins over anything stale and so it sits after the
                    // watch-history clear horizon instead of being filtered out
                    // by it on the next pull.
                    if args.contains("-restoreProgress") {
                        Task { @MainActor [weak nuvioSync] in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            let url = FileManager.default
                                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("orivio-progress-restore.json")
                            guard let data = try? Data(contentsOf: url),
                                  let rows = try? JSONDecoder().decode([WatchProgress].self, from: data)
                            else {
                                NSLog("[OrivioSync] -restoreProgress: no readable payload at %@", url.path)
                                return
                            }
                            let stamped = rows.map { row -> WatchProgress in
                                var copy = row
                                copy.updatedAt = Date()
                                return copy
                            }
                            progressStore.importEntries(stamped)
                            await nuvioSync?.pushThisDevice()
                            NSLog("[OrivioSync] -restoreProgress: imported %d rows", stamped.count)
                        }
                    }
                    // Dev/recovery: clear Trakt's continue-watching list on
                    // launch (same path as the Settings → Trakt button).
                    if args.contains("-clearTraktPlayback") {
                        Task { @MainActor [weak traktSyncRef = traktSync] in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            let removed = await traktSyncRef?.clearTraktContinueWatching()
                            NSLog("[OrivioTrakt] -clearTraktPlayback removed=%@",
                                  removed.map(String.init) ?? "nil (fetch failed)")
                        }
                    }
                    if args.contains("-clearWatchHistory") {
                        Task { @MainActor [weak nuvioSync] in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            await nuvioSync?.clearWatchHistoryEverywhere()
                            NSLog("[OrivioSync] -clearWatchHistory launch action finished")
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showProfileGate) {
                // The gate now only SELECTS a profile; account + Manage Profiles
                // live in Settings → Account. The design is an independent look
                // axis (Settings → Themes → Profile Screen).
                ProfileGateView(onSelected: { showProfileGate = false; deferSidebarAfterProfileGate() })
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
                    stremioSync?.syncNow(reason: "Foreground Stremio sync")
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

    private var mainContent: some View {
        tabLayout
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

    /// Whether the current tab is at its root (no pushed screen). When a
    /// Detail/Streams/etc. is pushed the rail hides so that screen runs
    /// full-bleed.
    private var showSidebar: Bool {
        switch selectedTab {
        case 0: return homePath.isEmpty
        case 1: return searchPath.isEmpty
        case 2: return libraryPath.isEmpty
        case 4: return liveTVPath.isEmpty
        default: return true   // Settings keeps the rail
        }
    }

    /// The app's single root: an always-visible Liquid Glass rail floating at
    /// the left edge over full-bleed content. OVERLAY layout (not an HStack)
    /// so the expanding panel just draws over the dimmed content — the content
    /// column never re-lays-out during the spring.
    private var tabLayout: some View {
        ZStack(alignment: .leading) {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Dim the content while the rail is expanded/focused, so
                    // the glass panel reads above it.
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .opacity(sidebarFocus != nil && showSidebar ? 1 : 0)
                }
                // Home runs full-bleed (hero art sweeps under the floating
                // pill); other tabs clear the rail.
                .padding(.leading, showSidebar && selectedTab != 0 ? GlassSidebar.collapsedWidth : 0)
                .focusSection()

            if showSidebar {
                GlassSidebar(selected: $selectedTab, focusBinding: $sidebarFocus,
                             onProfileTap: { showProfileGate = true },
                             onTabSelected: { newTab in selectTab(newTab) })
                    .focusSection()
                    .disabled(!sidebarEnabled)
                    // Back while IN the rail collapses it into content instead
                    // of falling through to the system (which quit the app).
                    .onExitCommand { collapseSidebarFromExit() }
                    // Swipe/press RIGHT exits into content: the content's focus
                    // section is UNDER the panel (overlapping, not beside it),
                    // so the engine sees no candidate to the right — catch it
                    // and run the same collapse Back uses.
                    .onMoveCommand { direction in
                        if direction == .right { collapseSidebarFromExit() }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    // Stays non-focusable until Home has content to hold
                    // initial focus (onContentReady); timer is the fallback.
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        sidebarEnabled = true
                    }
            }
        }
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: showSidebar)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: sidebarFocus != nil)
        .background(ATVBackground())
    }

    /// The screen for the selected rail tab, each in its own NavigationStack
    /// so per-tab back-stacks stay independent. Back at a tab ROOT moves focus
    /// to the rail (expanding it); pushed screens hold focus themselves, so
    /// their Back pops the NavigationStack instead.
    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case 1:
            NavigationStack(path: $searchPath) {
                searchRoot
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
            NavigationStack {
                ATVSettingsView(onOpenProfiles: { showProfileGate = true })
                    .onExitCommand { sidebarFocus = 3 }
            }
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
                        // Ignore a Menu that lands right after popping back from
                        // a pushed screen — tvOS sometimes delivers a lingering
                        // second Menu, which would spuriously open the rail.
                        if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                        sidebarFocus = 0
                    }
                    .onChange(of: homePath.count) { oldCount, newCount in
                        guard newCount < oldCount else { return }
                        lastHomePopAt = Date()
                        // Popping all the way back to Home: keep the rail
                        // non-focusable for a beat so focus lands on a card
                        // instead of the rail springing open.
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

    /// Handles tapping a rail tab: collapse the panel and force focus into the
    /// fresh tab's content by making the rail momentarily unfocusable.
    private func selectTab(_ newTab: Int) {
        let enteringHomeFresh = selectedTab != 0 && newTab == 0
        selectedTab = newTab
        sidebarFocus = nil
        sidebarEnabled = false
        // Entering Home fresh rebuilds HomeView; its onContentReady is the
        // sole re-enabler there (a blind timer could beat the rows to
        // focusability and the rail would reclaim focus).
        guard enteringHomeFresh else {
            scheduleSidebarReenable()
            return
        }
    }

    /// Back pressed while the rail itself is focused: close the panel. Always
    /// the fast fixed-delay re-enable — nothing is being freshly mounted.
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

    /// The rail's cold-launch fallback timer keeps running while the profile
    /// gate covers the screen, so once the gate dismisses the focus engine
    /// would land on the rail and pop it open. Briefly disable it again so
    /// focus goes to Home's content first.
    private func deferSidebarAfterProfileGate() {
        sidebarEnabled = false
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            sidebarEnabled = true
        }
    }

    // MARK: - Tab roots

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
                // Give the freshly-loaded rows a beat to render and take
                // initial focus before the rail becomes focusable.
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    sidebarEnabled = true
                }
            },
            // Back at the start of a row opens the rail.
            onHomeBack: {
                if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                sidebarFocus = 0
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
            onBackAtRoot: { sidebarFocus = 2 }
        )
    }

    private var liveTVRoot: some View {
        LiveTVView(
            onSelectChannel: { channel in liveTVPath.append(Route.streams(channel, nil)) },
            onPlayDirect: { channel in playLiveChannel(channel) }
        )
    }

    /// Shared navigation destinations. `path` is the binding for whichever
    /// tab's stack is presenting, so nested pushes stay within that tab.
    @ViewBuilder
    private func destination(for route: Route, path: Binding<NavigationPath>) -> some View {
        switch route {
        case .detail(let item):
            DetailView(
                    item: item,
                    onPlay: { meta, video in path.wrappedValue.append(Route.streams(meta, video)) },
                    onPlayManually: { meta, video in path.wrappedValue.append(Route.streamsManual(meta, video)) },
                    onPlayInInfuse: { meta, video in path.wrappedValue.append(Route.streamsInfuse(meta, video)) },
                    onPlayFromBeginning: { meta, video in path.wrappedValue.append(Route.streamsFromStart(meta, video)) },
                    onSelectItem: { path.wrappedValue.append(Route.detail($0)) },
                    onSelectPerson: { id, name in path.wrappedValue.append(Route.person(id: id, name: name)) },
                    onSelectCompany: { id, name in path.wrappedValue.append(Route.tmdbCompany(id: id, name: name)) }
            )
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
        case .streamsInfuse(let meta, let video):
            // Same auto-pick path as .streams — the source still has to be
            // resolved (a debrid torrent has no playable URL until it is) —
            // but the finished link is handed off rather than played here.
            StreamsView(
                meta: meta, video: video,
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, _ in
                guard let url = entry.stream.url else { return }
                ExternalPlayers.openInInfuse(urlString: url)
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
                        handOff(request, to: target, streamURL: urlString, subtitleURL: sub)
                    }
                } else {
                    handOff(request, to: target, streamURL: urlString)
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

    /// Hand a playback to an external app with everything its scheme accepts,
    /// and remember it so the return trip can land back in Continue Watching.
    private func handOff(
        _ request: PlaybackRequest, to player: ExternalPlayer,
        streamURL: String, subtitleURL: String? = nil
    ) {
        let duration = externalDuration(meta: request.meta, video: request.video)
        let resume = request.resumePosition
            ?? progressStore.progress(for: ProgressStore.key(metaID: request.meta.id, video: request.video))?.positionSeconds

        var item = ExternalPlayerHandoff.Item(streamURL: streamURL)
        item.subtitleURL = subtitleURL
        item.filename = externalFilename(meta: request.meta, video: request.video, streamURL: streamURL)
        if player.acceptsResume, let resume, resume >= 1 { item.resumeSeconds = resume }

        let session = ExternalPlaybackSession.Item(
            meta: request.meta, video: request.video,
            streamURL: streamURL, durationSeconds: duration
        )

        // Optimistic Continue Watching entry, for the players that can't report
        // anything back: without it, watching in another app leaves no trace at
        // all here. A player that DOES report (Infuse) overwrites this with the
        // real position on return — or removes the row outright if it finished.
        if let duration, duration > 60 {
            progressStore.update(
                meta: request.meta, video: request.video, streamURL: streamURL,
                position: max(resume ?? 0, 1), duration: duration,
                signature: request.entry.stream.signature(addonName: request.entry.addonName)
            )
        }

        guard player.supportsPlaylist,
              playerSettings.settings.externalPlayerSendPlaylist,
              request.video != nil
        else {
            send([item], sessions: [session], to: player)
            return
        }
        // Resolve the rest of the season in the background and hand the whole
        // run over as one playlist. Bounded by a deadline: a slow addon sweep
        // must not hold up the episode the viewer actually pressed play on.
        Task {
            let upcoming = await upcomingExternalEpisodes(after: request)
            send([item] + upcoming.map(\.item),
                 sessions: [session] + upcoming.map(\.session), to: player)
        }
    }

    private func send(
        _ items: [ExternalPlayerHandoff.Item],
        sessions: [ExternalPlaybackSession.Item],
        to player: ExternalPlayer
    ) {
        var handoff = ExternalPlayerHandoff(items: items)
        if player.reportsPosition {
            // Bare scheme + host: the player APPENDS its own result query.
            handoff.successURL = "nuvio://external-return"
            handoff.errorURL = "nuvio://external-error"
        }
        ExternalPlaybackSession.begin(ExternalPlaybackSession.Pending(
            items: sessions, playerID: player.id, playerName: player.name,
            startedAt: Date()
        ))
        player.open(handoff)
    }

    /// The next few aired, unwatched episodes after the one being handed off,
    /// each with a playable link picked the way the in-player "next episode"
    /// picks one (same addon / binge group as the current source first).
    ///
    /// Capped hard: every episode costs a full stream sweep across the addons,
    /// and the whole lot rides in ONE url that the other app has to parse.
    private func upcomingExternalEpisodes(
        after request: PlaybackRequest
    ) async -> [(item: ExternalPlayerHandoff.Item, session: ExternalPlaybackSession.Item)] {
        guard let current = request.video,
              let season = current.season, let number = current.episode else { return [] }
        let episodes = (request.meta.videos ?? [])
            .filter { video in
                guard let s = video.season, let e = video.episode else { return false }
                return video.hasAired && (s > season || (s == season && e > number))
            }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
            .prefix(Self.externalPlaylistLimit)
        guard !episodes.isEmpty else { return [] }

        let deadline = Date().addingTimeInterval(Self.externalPlaylistDeadline)
        var out: [(item: ExternalPlayerHandoff.Item, session: ExternalPlaybackSession.Item)] = []
        for episode in episodes {
            guard Date() < deadline else { break }
            // Stop at the first gap: a playlist that silently skips an episode
            // is worse than a shorter one.
            guard let stream = await externalNextEpisodeStream(
                meta: request.meta, episode: episode, like: request.entry
            ), let url = stream.stream.url else { break }
            var item = ExternalPlayerHandoff.Item(streamURL: url)
            item.filename = externalFilename(meta: request.meta, video: episode, streamURL: url)
            out.append((
                item,
                ExternalPlaybackSession.Item(
                    meta: request.meta, video: episode, streamURL: url,
                    durationSeconds: externalDuration(meta: request.meta, video: episode)
                )
            ))
        }
        return out
    }

    private static let externalPlaylistLimit = 5
    private static let externalPlaylistDeadline: TimeInterval = 8

    /// One playable link for `episode`, chosen like PlayerViewModel's
    /// next-episode auto-pick: prefer the same binge group, then the same
    /// addon, then simply the best-ranked playable link. Torrents are skipped
    /// outright — no external player can take a magnet.
    private func externalNextEpisodeStream(
        meta: MetaItem, episode: MetaVideo, like current: StreamEntry
    ) async -> StreamEntry? {
        var showID = meta.id
        if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: meta.type != "series") {
            showID = tt
        }
        let streamID: String
        if showID.hasPrefix("tt"), let season = episode.season, let number = episode.episode {
            streamID = "\(showID):\(season):\(number)"
        } else {
            streamID = episode.id
        }
        let addons = addonManager.streamAddons.filter { $0.handles(id: streamID) }
        guard !addons.isEmpty else { return nil }
        var entries: [StreamEntry] = []
        await withTaskGroup(of: [StreamEntry].self) { group in
            for addon in addons {
                group.addTask {
                    let streams = (try? await StremioAPI.streams(addon: addon, type: meta.type, id: streamID)) ?? []
                    return streams.filter(\.isPlayable)
                        .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                }
            }
            for await batch in group { entries.append(contentsOf: batch) }
        }
        guard !entries.isEmpty else { return nil }
        let curated = SourceSelection.select(entries, perTier: playerSettings.settings.sourcesPerSizeTier)
        let playable = (curated.isEmpty ? entries : curated).filter(\.stream.isPlayable)
        let group = current.stream.behaviorHints?.bingeGroup
        return playable.first { $0.stream.behaviorHints?.bingeGroup == group && group != nil }
            ?? playable.first { $0.addonName == current.addonName }
            ?? playable.first
    }

    /// Duration for an external handoff: what we already recorded for this
    /// title, else the addon's runtime. Without one, a returned position can't
    /// be turned into progress at all (and never into "watched").
    private func externalDuration(meta: MetaItem, video: MetaVideo?) -> Double? {
        progressStore.progress(for: ProgressStore.key(metaID: meta.id, video: video))?.durationSeconds
            ?? meta.runtimeSeconds
    }

    /// A media-style filename for the handoff ("Show.Name.S01E02.mkv"). Infuse
    /// matches metadata off this, so a title arrives with real artwork instead
    /// of a raw CDN URL.
    private func externalFilename(meta: MetaItem, video: MetaVideo?, streamURL: String) -> String? {
        let name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var base = name.replacingOccurrences(of: " ", with: ".")
        if let video, let season = video.season, let episode = video.episode {
            base += String(format: ".S%02dE%02d", season, episode)
        } else if let year = meta.releaseInfo?.prefix(4), Int(year) != nil {
            base += ".\(year)"
        }
        // Keep the real container so the other app doesn't guess wrong.
        let ext = URL(string: streamURL)?.pathExtension ?? ""
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// An external player reported back (x-success). Write the position it
    /// returned into Continue Watching through the SAME path in-app playback
    /// uses, so watched-state, Trakt scrobbling and sync all behave identically.
    private func finishExternalPlayback(streamURL: String?, position: Double?) {
        guard let pending = ExternalPlaybackSession.pending,
              let (stopped, completed) = ExternalPlaybackSession.resolveReturn(pending, returnedURL: streamURL)
        else { return }
        ExternalPlaybackSession.clear()
        // Everything ahead of the stopping point played through to the end.
        for item in completed {
            guard let duration = item.durationSeconds ?? storedDuration(item), duration > 60 else { continue }
            progressStore.update(
                meta: item.meta, video: item.video, streamURL: item.streamURL,
                position: duration, duration: duration
            )
        }
        guard let position, position > 0,
              let duration = stopped.durationSeconds ?? storedDuration(stopped), duration > 60
        else { return }
        progressStore.update(
            meta: stopped.meta, video: stopped.video, streamURL: stopped.streamURL,
            position: position, duration: duration
        )
    }

    private func storedDuration(_ item: ExternalPlaybackSession.Item) -> Double? {
        progressStore.progress(for: ProgressStore.key(metaID: item.meta.id, video: item.video))?.durationSeconds
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
        case .externalPlaybackFinished(let streamURL, let position):
            finishExternalPlayback(streamURL: streamURL, position: position)
        case .externalPlaybackFailed(let message):
            // The stream never played over there, so drop the optimistic
            // Continue Watching row we wrote at handoff — it would otherwise
            // sit at 0% forever.
            if let first = ExternalPlaybackSession.pending?.items.first {
                progressStore.remove(id: ProgressStore.key(metaID: first.meta.id, video: first.video))
            }
            ExternalPlaybackSession.clear()
            NSLog("[OrivioPlayer] external player error: %@", message ?? "(none)")
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
