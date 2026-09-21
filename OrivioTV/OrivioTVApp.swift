import AVKit
import SwiftUI

@main
struct OrivioTVApp: App {
    /// Reclaim orphaned player scratch space before anything else runs. A
    /// remux session that got jetsammed leaves its segment directory behind
    /// with no owner left to delete it, and nothing else in the app ever
    /// swept them — launch is the one moment we know none of them are live.
    init() {
        // FIRST of all, before ANY UserDefaults write below: shrink an
        // oversized add-on blob a pre-compression build left behind. On a box
        // already at the ~1 MB CFPreferences abort, the first unrelated write
        // (the migration stamp, a store save) aborts the process, so the app
        // crash-loops on launch and the viewer can never reach Settings to
        // remove the add-on. This is a reducing write, which CFPreferences
        // accepts, so it breaks the loop. See AddonManager.
        AddonManager.reclaimUncompressedStorage()
        #if !DEBUG
        // A pre-v8 release build persisted an unbounded PiP dev trail (measured
        // ~97 KB, the single largest key in the domain) that the PiP code only
        // clears once PiP actually runs. Clear it here so a viewer who never
        // opens PiP still reclaims the space before the domain can reach the
        // abort.
        UserDefaults.standard.removeObject(forKey: "dev.pipTrail")
        #endif
        // THEN: carry `nuvio.*` prefs and caches forward to `orivio.*` before
        // any store reads them, or an existing install boots as a factory
        // reset — no add-ons, library, profiles, progress or credentials.
        OrivioRenameMigration.runIfNeeded()
        PlayerTempSweep.sweepAtLaunch()
        // Diagnostics capture (Settings → Performance). Resolved BEFORE any
        // probe starts so a Release install can be probed without a Debug
        // rebuild: DEBUG defaults on, Release defaults off, and the stored
        // choice wins either way.
        ProbeGate.configureFromDefaults()
        // LAN read-out of the probe bus, so a session can be watched live
        // without `devicectl` backgrounding the app mid-playback.
        ColorProbeServer.shared.start()
        // …and a recording that SURVIVES the failure, for when the live probe
        // cannot answer: a suspended app, a wedged one, or a box that panics.
        // See FlightRecorder for what it records and why each field is there.
        FlightRecorder.start()
        // The browse half of the same probe. Armed HERE, not on a screen's
        // appear, so the tail covers launch itself — a cold start that hangs
        // before any view exists is exactly the session with no other witness.
        AppProbe.installLevels()
    }

    @StateObject private var theme = ThemeManager()
    @StateObject private var addonManager = AddonManager()
    @StateObject private var progressStore = ProgressStore()
    @StateObject private var account = OrivioAccountManager()
    @StateObject private var library = LibraryStore()
    @StateObject private var watched = WatchedStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var collections = CollectionsStore()
    @StateObject private var homeCatalogSettings = HomeCatalogSettingsStore()
    @StateObject private var tmdbSettings = TMDBSettingsStore()
    @StateObject private var mdblistSettings = MDBListSettingsStore()
    @StateObject private var debrid = DebridStore()
    @StateObject private var trakt = TraktStore()
    @StateObject private var simkl = SimklStore()
    @StateObject private var stremioAccount = StremioAccountStore()
    @StateObject private var playerSettings = PlayerSettingsStore()
    @StateObject private var streamBadges = StreamBadgeStore()
    @StateObject private var plugins = PluginStore()
    @StateObject private var torrent = TorrentSettingsStore()
    @StateObject private var ratings = RatingsStore()
    @StateObject private var mediaServers = MediaServerStore()

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
                .environmentObject(simkl)
                .environmentObject(stremioAccount)
                .environmentObject(playerSettings)
                .environmentObject(streamBadges)
                .environmentObject(plugins)
                .environmentObject(torrent)
                .environmentObject(ratings)
                .environmentObject(mediaServers)
                // Classic is hard-dark (the original look). The Apple TV theme
                // honors its Appearance setting — light, dark, or nil to
                // follow the TV's own system appearance.
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}

/// Human names for the probe's `[app]` block and its nav events. Kept beside
/// the enum so a new case is obvious here too — an unnamed route reads as
/// "route" in the tail and tells the reader nothing.
extension Route {
    var probeName: String {
        switch self {
        case .detail: return "Detail"
        case .collection: return "Collection"
        case .person: return "Cast"
        case .tmdbCompany: return "Studio"
        case .catalogSeeAll: return "See All"
        case .discover: return "Discover"
        case .cloudLibrary: return "Cloud Library"
        case .mediaServerShow: return "Media Server Show"
        case .streams: return "Sources"
        case .streamsInfuse: return "Sources (Infuse)"
        case .streamsManual: return "Sources (manual)"
        case .streamsFromStart: return "Sources (from start)"
        case .streamsResume: return "Sources (resume)"
        }
    }

    var probeDetail: String {
        switch self {
        case .detail(let item): return "\(item.name) [\(item.type) \(item.id)]"
        case .collection(let c): return c.title
        case .person(_, let name): return name
        case .tmdbCompany(_, let name): return name
        case .catalogSeeAll(_, _, let title): return title
        case .mediaServerShow(let show): return show.title
        case .streams(let meta, let video),
             .streamsInfuse(let meta, let video),
             .streamsManual(let meta, let video),
             .streamsFromStart(let meta, let video),
             .streamsResume(let meta, let video, _):
            return meta.name + (video.map { " S\($0.season ?? 0)E\($0.episode ?? 0)" } ?? "")
        default: return ""
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
    case collection(OrivioCollection)
    case person(id: Int, name: String)
    case tmdbCompany(id: Int, name: String)
    case catalogSeeAll(addon: InstalledAddon, catalog: ManifestCatalog, title: String)
    case discover
    case cloudLibrary
    /// A Plex / Jellyfin show's episode list.
    case mediaServerShow(MediaServerItem)
}

struct RootView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject private var liveTV = LiveTVSettingsStore.shared
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var account: OrivioAccountManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var simkl: SimklStore
    @EnvironmentObject private var stremioAccount: StremioAccountStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var mediaServers: MediaServerStore
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
    /// A deep-link add-on install waiting for the viewer to say yes.
    ///
    /// A `stremio://` / `https://…/manifest.json` / `orivio://<host>` link used
    /// to install SILENTLY (a bare `Task { try? await install(…) }` — no prompt,
    /// no toast, error swallowed). Anything on the network that can make tvOS
    /// open a URL — another app, a QR code, an AirPlay handoff — could add a
    /// stream provider that then feeds this app arbitrary stream URLs. Now the
    /// manifest is fetched first (read-only), the add-on is NAMED in a
    /// confirmation, and nothing is written until the viewer presses Install.
    @State private var pendingAddonInstall: PendingAddonInstall?
    /// Why a Live TV channel couldn't be opened — DRM the box can't decrypt, or
    /// a YouTube relay that no longer resolves. Shown instead of letting the
    /// player fail with a generic decode error and burn four source retries on
    /// something that can never work.
    @State private var liveChannelError: String?
    /// True while the manifest behind a deep link is being fetched for the
    /// prompt — keeps a second link from queueing a second dialog.
    @State private var addonInstallInFlight = false

    struct PendingAddonInstall: Identifiable {
        let id = UUID()
        let manifestURL: String
        let name: String
        /// Already installed: the prompt says "Update" instead of "Install".
        let isUpdate: Bool
    }

    @State private var sync: OrivioSyncManager?
    @State private var traktSync: TraktSyncManager?
    @State private var simklSync: SimklSyncManager?
    /// Held only by -addonServerProbe; nil in normal runs.
    @State private var devAddonServer: AddonImportServer?
    @State private var stremioSync: StremioSyncManager?
    @State private var showProfileGate = false
    /// First launch, nobody signed in — the welcome screen sits in front of
    /// everything, including the profile gate.
    @State private var showWelcome = false
    /// True when the gate was opened from the rail / Settings (Back closes
    /// it); false for the cold-launch gate, where Back stays a no-op.
    @State private var profileGateCancellable = false
    @State private var selectedTab = 0
    /// Polls the account every 30s while Home is up so Continue Watching stays
    /// live — removals and additions made on another device (or that failed to
    /// reconcile on foreground) appear without a relaunch. Fires continuously;
    /// the receiver gates it to Home + active + not-in-player. A no-change pull
    /// mutates nothing (mergeRemote only publishes on a real diff), so an idle
    /// Home doesn't re-render.
    /// `.default`, NOT `.common`: common-mode timers fire inside the run-loop
    /// tracking mode focus/scroll animations run in, waking SwiftUI mid-scroll
    /// for a poll that is never urgent. Tier-scaled: on the A8/A10X the full
    /// account sync already runs every 90s, and a second independent 30s pull
    /// over the same data doubled the recurring decode/merge load for nothing.
    private let continueWatchingPoll = Timer.publish(
        every: (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? 60 : 30,
        on: .main, in: .default
    ).autoconnect()
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
            .onChange(of: sidebarFocus) { old, new in traceSidebar(old, new) }
            .onChange(of: sidebarEnabled) { _, new in traceSidebarEnabled(new) }
            // If Live TV is turned off while you're on it (or via sync), drop
            // back to Home so you're not stranded on a now-hidden tab.
            .onChange(of: liveTV.enabled) { _, enabled in
                if !enabled && selectedTab == 4 { selectedTab = 0 }
                // Also drop the tab's stack. Left in place, re-enabling Live TV
                // later rebuilt the NavigationStack with the old path intact
                // and reopened whatever pushed screen (a channel's sources)
                // was up when it was switched off. Pop, don't reset, per the
                // app's own convention.
                if !enabled, !liveTVPath.isEmpty { liveTVPath.removeLast(liveTVPath.count) }
            }
            // Install the hold trace when the setting is switched ON, not only
            // in onAppear: turning "Hold menu probe" on mid-session used to
            // bring up the HUD with nothing to report until the next relaunch.
            // `install()` is idempotent, so a second call is free.
            .onChange(of: perf.settings.showHoldProbe) { _, on in
                // Off matters as much as on: the trace installs a focus-change
                // observer that walks ten superviews and logs on EVERY focus
                // move, plus a window-wide long-press recogniser. Left behind,
                // they cost that on the A8/A10X boxes for the rest of the
                // session after the user switched the probe back off.
                if on { HoldInteractionTrace.install() }
                else { HoldInteractionTrace.uninstall() }
            }
            // Refresh a QR-linked Real-Debrid token at launch (its device-flow
            // access token is short-lived).
            .task { await debrid.refreshRealDebridIfNeeded() }
            .onAppear {
                NSLog("[OrivioPlayer] RootView content onAppear")
                FocusTrace.installIfRequested()
                if perf.settings.showHoldProbe { HoldInteractionTrace.install() }
                startPlayerDemoIfRequested()
                startDetailDemoIfRequested()
                ScrubThumbnailer.runSelfTestIfRequested()
            }
            .task {
                if sync == nil {
                    // Finishing a title records it in watched history.
                    progressStore.onFinished = { [weak watched, finishedThisSession] meta, video in
                        watched?.mark(meta: meta, video: video, fromPlayback: true)
                        // Remember it for the stop scrobble: the row this fires
                        // for has just been DELETED from the progress store.
                        finishedThisSession.keys.insert(
                            ProgressStore.key(metaID: meta.id, video: video)
                        )
                    }
                    // A synced row for an episode finished AFTER that row was
                    // written is a stale copy; no merge may restore it (see
                    // `ProgressStore.episodeWatchedAfter`).
                    progressStore.episodeWatchedAfter = { [weak watched] row in
                        guard let watched, let season = row.season, let episode = row.episode,
                              let mark = watched.items[WatchedItem.key(contentID: row.metaID,
                                                                       season: season,
                                                                       episode: episode)]
                        else { return false }
                        return mark.watchedAt > row.updatedAt
                    }
                    let orivioSync = OrivioSyncManager(
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
                        traktStore: trakt,
                        simklStore: simkl,
                        ratingsStore: ratings
                    )
                    sync = orivioSync
                    orivioSync.enrichContinueWatchingEnabled = { [tmdbSettings] in
                        tmdbSettings.settings.enrichContinueWatching
                    }
                    // Trakt two-way sync (history / watched badges + Continue
                    // Watching). Separate opt-in destination from the account.
                    // Trakt scoping must survive being signed out of Orivio:
                    // the sync manager owns profile scoping for every other
                    // store, but it only runs while signed in.
                    // Ratings are per-profile for the same reason Trakt is: a
                    // profile with its own Trakt account must not push another
                    // profile's ratings into it. SIMKL rides the same
                    // per-profile switch as Trakt (one setting, both services).
                    // Everything personal rescopes on a switch, even when
                    // signed out of Orivio (the sync manager only runs while
                    // signed in): trackers, add-ons/plugins (honouring the
                    // profile's use-primary fallbacks), debrid logins, player
                    // settings, TMDB, theme, badges — upstream Nuvio's
                    // per-profile boundary, ported wholesale.
                    profiles.onSwitchLocal = { [weak trakt, weak simkl, weak ratings, weak addonManager,
                                                weak plugins, weak debrid, weak playerSettings,
                                                weak tmdbSettings, weak theme, weak streamBadges,
                                                weak profiles] id in
                        let flags = profiles?.profiles.first { $0.id == id }
                        trakt?.setProfile(id)
                        simkl?.setProfile(id)
                        ratings?.setProfile(id)
                        addonManager?.setProfile(flags?.usesPrimaryAddons == true ? 1 : id)
                        plugins?.setProfile(flags?.usesPrimaryPlugins == true ? 1 : id)
                        debrid?.setProfile(id)
                        playerSettings?.setProfile(id)
                        tmdbSettings?.setProfile(id)
                        theme?.setProfile(id)
                        streamBadges?.setProfile(id)
                        LiveChannelFavorites.shared.setProfile(id)
                        // Every store just re-pointed at another profile's
                        // data; reconcile the new picture everywhere rather
                        // than waiting for a tick.
                        SyncCoordinator.shared.requestFullSync("profile switched")
                    }
                    profiles.onProfileLockChanged = { [weak progressStore] in
                        progressStore?.refreshTopShelf()
                    }
                    // Write the shelf once at launch. Every other trigger is a
                    // CHANGE — a progress save, a PIN flip — so a device whose
                    // Continue Watching arrived from the account (a reinstall,
                    // a second box) had nothing on the tvOS home screen until
                    // it played something. Also logs where the snapshot went,
                    // which is the only way to tell "no rows" apart from "the
                    // signer stripped the app group" from a device log.
                    progressStore.refreshTopShelf()
                    NSLog("[TopShelf] app group %@ → %@", AppGroupResolver.identifier,
                          AppGroupResolver.sharedFile("topshelf.json")?.path ?? "UNAVAILABLE")
                    profiles.onProfileDeleted = { [weak trakt, weak simkl, weak addonManager,
                                                   weak plugins, weak debrid, weak playerSettings,
                                                   weak tmdbSettings, weak theme, weak streamBadges,
                                                   weak orivioSync] id in
                        trakt?.forgetProfile(id)
                        simkl?.forgetProfile(id)
                        addonManager?.forgetProfile(id)
                        plugins?.forgetProfile(id)
                        debrid?.forgetProfile(id)
                        playerSettings?.forgetProfile(id)
                        tmdbSettings?.forgetProfile(id)
                        theme?.forgetProfile(id)
                        streamBadges?.forgetProfile(id)
                        LiveChannelFavorites.shared.forgetProfile(id)
                        orivioSync?.syncProfilesNow()
                        SyncCoordinator.shared.requestFullSync("profile deleted")
                    }
                    traktSync = TraktSyncManager(
                        trakt: trakt, watched: watched, progress: progressStore,
                        library: library, ratings: ratings, addonManager: addonManager
                    )
                    // Constructed AFTER the Trakt manager, and safely so: the
                    // store hooks both subscribe to are lists, so this appends
                    // rather than replacing Trakt's subscriptions. It takes the
                    // progress store to SEED Continue Watching from SIMKL's
                    // "watching" list; SIMKL has no playback-position API, so
                    // nothing flows the other way (see syncContinueWatching).
                    simklSync = SimklSyncManager(
                        simkl: simkl, watched: watched, library: library,
                        ratings: ratings, addonManager: addonManager,
                        progress: progressStore
                    )
                    let stremioManager = StremioSyncManager(
                        stremio: stremioAccount,
                        addonManager: addonManager,
                        library: library,
                        progress: progressStore,
                        watched: watched
                    )
                    stremioManager.onMergedFromStremio = { [weak orivioSync, account] in
                        guard account.authState.isSignedIn else { return }
                        await orivioSync?.pushThisDevice()
                    }
                    stremioSync = stremioManager

                    // Anything sync-relevant that happens locally now kicks a
                    // full sync of every destination, debounced (see
                    // SyncCoordinator). Registered by name, so this is safe to
                    // reach twice.
                    // Coming back from Picture in Picture: re-present the
                    // cover for the session PiPHandoff kept alive.
                    PiPHandoff.shared.present = { [pipRestored] request in
                        // Flag it as a RESTORE before the cover flips back on,
                        // so the scrobble lifecycle doesn't read a session that
                        // never stopped playing as a fresh start (see
                        // PiPRestoredRequest).
                        pipRestored.id = request.id
                        playback = request
                    }
                    let coordinator = SyncCoordinator.shared
                    coordinator.observe(watched: watched, library: library,
                                        ratings: ratings, progress: progressStore)
                    coordinator.addDestination("Orivio") { [weak orivioSync] in
                        Task { @MainActor in
                            // A change made from inside the player (mark
                            // watched, remove from Continue Watching) still
                            // reaches the account at once — through the light
                            // pass, so it cannot contend with the stream.
                            if OrivioSyncManager.playbackActive {
                                await orivioSync?.syncLight(reason: "local change during playback")
                            } else {
                                await orivioSync?.syncNow()
                            }
                        }
                    }
                    // NOT forced: the per-item hooks (pushMark etc.) already
                    // delivered the change itself — this pass is pure
                    // reconciliation, and `force: true` bypassed the managers'
                    // own throttles, so a single "mark watched" pulled the
                    // FULL Trakt watched history (thousands of per-episode
                    // rows, transformed on the main actor) while the user was
                    // still navigating the page. With the throttle honored a
                    // burst reconciles once; the 5-min periodic tick remains
                    // the backstop.
                    coordinator.addDestination("Trakt") { [weak traktSyncRef = traktSync] in
                        traktSyncRef?.syncNow(force: false)
                    }
                    coordinator.addDestination("SIMKL") { [weak simklSyncRef = simklSync] in
                        simklSyncRef?.syncNow(force: false)
                    }
                    coordinator.addDestination("Stremio") { [weak stremioManager] in
                        stremioManager?.syncNow(reason: "Local change")
                    }
                    // Fix up any already-installed Community Collections after
                    // launch has yielded. Keep network-backed logo migration
                    // out of app-open startup; that runs when the collection
                    // screen is opened.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        CommunityCollections.runLaunchMigrations(collections: collections)
                    }
                    // "Who's watching?" gate on cold launch when 2+ profiles —
                    // OR whenever the profile about to become active is PIN
                    // locked. With only the count test, a device with a single
                    // PIN-locked profile booted straight into it and the lock
                    // the user had enabled protected nothing.
                    // Everything the browse probe needs that lives in a store
                    // rather than in this view. Weak, so a block registered
                    // here can never be what keeps a store alive, and
                    // re-registered harmlessly if the root ever reappears
                    // (`register` replaces by name).
                    installStoreProbe()
                    AppProbe.tab = Self.tabName(selectedTab)
                    AppProbe.life("root appeared — tab=\(Self.tabName(selectedTab))")
                    // Skipped in the demo modes so the screen isn't covered.
                    let args = ProcessInfo.processInfo.arguments
                    let demoArgs = ["-detailDemo", "-detailDemoSeries", "-homeDemo", "-settingsDemo", "-liveTVDemo", "-searchDemo", "-libraryDemo", "-discoverDemo", "-traktQRDemo", "-simklQRDemo", "-accountDemo", "-settingsTabDemo"]
                    let demoMode = demoArgs.contains { args.contains($0) }
                    // -welcomeDemo forces it regardless of the completed flag
                    // or an already-restored session, which is the only way to
                    // look at this screen twice on one install.
                    let forceWelcome = args.contains("-welcomeDemo")
                        || args.contains("-welcomeOfferDemo")
                    showWelcome = (forceWelcome || OnboardingState.shouldShow(
                        signedIn: account.authState.isSignedIn)) && !demoMode
                    showProfileGate = (profiles.profiles.count >= 2 || profiles.active.pinEnabled) && !demoMode
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
                    // Dev: run the add-on import server standalone and log
                    // its address, so the HTTP path can be exercised without
                    // driving the settings UI.
                    if args.contains("-addonServerProbe") {
                        let server = AddonImportServer()
                        server.onInstall = { [weak addonManager] url in
                            guard let addonManager else { return .failure(URLError(.cancelled)) }
                            do {
                                try await addonManager.install(manifestURL: url)
                                let m = addonManager.addons.first { $0.manifestURL == url }?.manifest
                                return .success(.init(manifestURL: url, name: m?.name ?? url,
                                                      logo: m?.logo, description: m?.description))
                            } catch { return .failure(error) }
                        }
                        server.start()
                        devAddonServer = server
                        Task { @MainActor in
                            for _ in 0..<20 {
                                if let a = server.address {
                                    NSLog("[OrivioAddonServer] listening at %@", a); return
                                }
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                            NSLog("[OrivioAddonServer] never became ready: %@",
                                  server.lastError ?? "unknown")
                        }
                    }
                    // Dev: can this device do Picture in Picture at all?
                    if args.contains("-pipProbe") {
                        // Each probe run starts a fresh trail.
                        UserDefaults.standard.removeObject(forKey: "dev.pipTrail")
                        NSLog("[OrivioPiP] isPictureInPictureSupported=%d",
                              AVPictureInPictureController.isPictureInPictureSupported() ? 1 : 0)
                    }
                    // Dev: what search will query, in order, and what one real
                    // query returns from each — the ordering is the whole point
                    // of searchTargets and is otherwise invisible.
                    if args.contains("-searchProbe") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            let targets = SearchViewModel.searchTargets(addonManager)
                            var lines: [String] = []
                            for (i, t) in targets.enumerated() {
                                let m = t.0.manifest
                                lines.append("\(i). \(m.name) [\(t.1.type)/\(t.1.id)]"
                                             + " meta=\(m.providesMeta) stream=\(m.providesStreams)")
                            }
                            // Write the ORDER first: the slow part below is a
                            // real query per catalog and must not be able to
                            // lose the answer we already have.
                            UserDefaults.standard.set(lines.joined(separator: "\n"),
                                                      forKey: "dev.searchProbe")
                            NSLog("[OrivioSearch] order written (%d targets)", targets.count)
                            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                                for (i, t) in targets.enumerated() {
                                    group.addTask {
                                        ((i, (try? await StremioAPI.catalog(
                                            addon: t.0, catalog: t.1, search: "breaking bad")) ?? []))
                                    }
                                }
                                var got: [Int: [MetaItem]] = [:]
                                for await (i, items) in group { got[i] = items }
                                for i in targets.indices {
                                    let items = got[i] ?? []
                                    lines.append("RESULT \(i) \(targets[i].0.manifest.name): \(items.count) — "
                                                 + items.prefix(3).map(\.name).joined(separator: " | "))
                                }
                            }
                            UserDefaults.standard.set(lines.joined(separator: "\n"),
                                                      forKey: "dev.searchProbe")
                            NSLog("[OrivioSearch] probe written")
                        }
                    }
                    // Dev: dump the SIMKL request bodies (see debugEnvelope).
                    if args.contains("-simklEnvelopeReport") {
                        let now = Date(timeIntervalSince1970: 1_700_000_000)
                        let history: [SimklService.SyncItem] = [
                            .init(imdb: "tt0111161", type: "movie", title: "The Shawshank Redemption", watchedAt: now),
                            .init(imdb: "tt0903747", type: "series", title: "Breaking Bad", season: 1, episode: 1, watchedAt: now),
                            .init(imdb: "tt0903747", type: "series", season: 1, episode: 2, watchedAt: now),
                            .init(imdb: "tt0903747", type: "series", season: 2, episode: 1, watchedAt: now),
                            .init(tmdb: 1396, type: "series", title: "Tmdb Only", season: 1, episode: 1, watchedAt: now),
                            .init(type: "movie", title: "No IDs — must be dropped"),
                        ]
                        let rated: [SimklService.SyncItem] = [
                            .init(imdb: "tt0111161", type: "movie", title: "Shawshank", rating: 9),
                        ]
                        let watchlist: [SimklService.SyncItem] = [
                            .init(imdb: "tt0468569", type: "movie", title: "The Dark Knight"),
                        ]
                        let report = "HISTORY\n" + SimklService.debugEnvelope(history)
                            + "\n\nRATINGS\n" + SimklService.debugEnvelope(rated, includeRating: true)
                            + "\n\nWATCHLIST\n" + SimklService.debugEnvelope(watchlist, listTarget: "plantowatch")
                        UserDefaults.standard.set(report, forKey: "dev.simklEnvelope")
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
                    // Dev: flip per-profile accounts and/or switch profile, the
                    // same calls Settings and the profile gate make. The switch
                    // covers Trakt AND SIMKL, exactly as the Settings toggle does.
                    if args.contains("-traktPerProfile") {
                        trakt.perProfileAccounts = true
                        simkl.perProfileAccounts = true
                    }
                    if args.contains("-traktShared") {
                        trakt.perProfileAccounts = false
                        simkl.perProfileAccounts = false
                    }
                    if let f = args.first(where: { $0.hasPrefix("-traktForget:") })?
                        .replacingOccurrences(of: "-traktForget:", with: ""), let id = Int(f) {
                        // Same path a profile deletion takes.
                        trakt.forgetProfile(id)
                        simkl.forgetProfile(id)
                    }
                    if let p = args.first(where: { $0.hasPrefix("-profile:") })?
                        .replacingOccurrences(of: "-profile:", with: ""), let id = Int(p) {
                        profiles.setActive(id)
                    }
                    // Dev: expand the rail shortly after launch (sim key
                    // delivery is flaky; this makes the expanded panel
                    // screenshot-able without remote input).
                    if args.contains("-railDemo") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            sidebarEnabled = true
                            sidebarFocus = 0
                        }
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
                        Task { @MainActor [weak orivioSync] in
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
                            await orivioSync?.pushThisDevice()
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
                        Task { @MainActor [weak orivioSync] in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            await orivioSync?.clearWatchHistoryEverywhere()
                            NSLog("[OrivioSync] -clearWatchHistory launch action finished")
                        }
                    }
                }
            }
            // Presented AFTER the profile gate's modifier so it layers on
            // top: on a fresh install both would otherwise want the screen,
            // and "who's watching" makes no sense before "who are you".
            .fullScreenCover(isPresented: $showWelcome) {
                WelcomeView(account: account, addonManager: addonManager) {
                    OnboardingState.completed = true
                    showWelcome = false
                }
                .environmentObject(theme)
            }
            .fullScreenCover(isPresented: $showProfileGate) {
                // The gate now only SELECTS a profile; account + Manage Profiles
                // live in Settings → Account. The design is an independent look
                // axis (Settings → Themes → Profile Screen).
                ProfileGateView(
                    onSelected: { showProfileGate = false; deferSidebarAfterProfileGate() },
                    onCancel: profileGateCancellable
                        ? { showProfileGate = false; deferSidebarAfterProfileGate() }
                        : nil
                )
                .environmentObject(theme)
                .environmentObject(profiles)
                .environmentObject(account)
            }
            // Returning to the app pulls the latest Continue Watching so changes
            // made on another device show up without a relaunch (local edits
            // already push immediately on every change).
            .onChange(of: scenePhase) { _, phase in
                AppProbe.scene = "\(phase)"
                AppProbe.life("scene → \(phase)")
                if phase == .active {
                    // First foreground after an external handoff is the return
                    // from that app. Players that don't call back (VLC, nPlayer,
                    // VidHub, SenPlayer) have no deep link, so this marker is
                    // the only signal; consuming it also keeps a plain later
                    // foreground from re-triggering the navigation.
                    if ExternalLaunchMarker.consume() {
                        returnToHomeFromExternalPlayback()
                    }
                    // Opening the app syncs the whole account, not just
                    // Continue Watching — add-ons, collections, the layout and
                    // the player/theme settings all change on other devices
                    // too, and waiting for the periodic tick (30s, 90s on the
                    // A8/A10X) meant the app opened showing yesterday's copy.
                    // Self-coalescing and self-throttled: a cold launch arms
                    // this from the auth change as well, a quick
                    // inactive→active flip is ignored, and a cycle already
                    // running is reused rather than duplicated.
                    sync?.syncOnAppOpen(reason: "app opened")
                    // Stands down on its own while that sync is armed, so the
                    // two can't pull progress and library at the same time.
                    sync?.refreshContinueWatching()
                    traktSync?.syncNow()
                    stremioSync?.syncNow(reason: "Foreground Stremio sync")
                    // An add-on left as a stub — its manifest fetch answered
                    // during a wake, before the network was really back — has
                    // no catalogs and serves no streams, and NOTHING else
                    // re-fetches manifests until the next launch. That is why a
                    // missing add-on came back only after closing the app.
                    // Same repair the Sources screen already runs, and it does
                    // nothing when there is no stub to fix.
                    if addonManager.addons.contains(where: { $0.enabled && $0.manifest.isPlaceholder }) {
                        Task { _ = await addonManager.resolvePlaceholders() }
                    }
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

    private func traceSidebar(_ old: Int?, _ new: Int?) {
        #if DEBUG
        guard FocusTrace.enabled else { return }
        NSLog("[FocusTrace] sidebarFocus %@ -> %@ (enabled=%d)",
              old.map(String.init) ?? "nil", new.map(String.init) ?? "nil", sidebarEnabled ? 1 : 0)
        #endif
    }

    private func traceSidebarEnabled(_ enabled: Bool) {
        #if DEBUG
        guard FocusTrace.enabled else { return }
        NSLog("[FocusTrace] sidebarEnabled=%d", enabled ? 1 : 0)
        #endif
    }

    private static var playerDemoStarted = false

    /// Dev-only: `-playerDemo` opens the player with Apple's public HLS test
    /// stream (`-playerDemoMKV` uses an MKV sample to exercise the FFmpeg
    /// engine) so playback UI can be verified without a stream addon.
    private func startPlayerDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wantsMKV = args.contains("-playerDemoMKV")
        guard wantsMKV || args.contains("-playerDemo") else { return }
        // Once per process: the root content re-appears whenever the player
        // cover dismisses — including the Picture in Picture handoff — and a
        // second demo session would tear the parked one down.
        guard !Self.playerDemoStarted else { return }
        Self.playerDemoStarted = true
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
        // Dev-only: open a detail page directly, so the page's opening focus
        // and the hold-Select menu on Play can be driven from a UI test
        // without navigating through Home. `-detailSeries` renders a show
        // instead of a movie — the two branches of the action row are the
        // working/broken pair for the hold menu.
        if ProcessInfo.processInfo.arguments.contains("-detailDemo") {
            let series = ProcessInfo.processInfo.arguments.contains("-detailSeries")
            return AnyView(
                ZStack {
                    theme.palette.background.ignoresSafeArea()
                    DetailView(
                        item: series
                            ? MetaItem(id: "tt0903747", type: "series", name: "Breaking Bad",
                                       description: "A chemistry teacher turns to making meth.")
                            : MetaItem(id: "tt0111161", type: "movie", name: "The Shawshank Redemption",
                                       description: "Two imprisoned men bond over a number of years."),
                        onPlay: { _, _ in },
                        onPlayManually: { _, _ in },
                        onPlayInInfuse: { _, _ in },
                        onPlayFromBeginning: { _, _ in }
                    )
                }
            )
        }
        if ProcessInfo.processInfo.arguments.contains("-accountDemo") {
            return AnyView(
                ZStack { theme.palette.background.ignoresSafeArea(); AccountView() }
            )
        }
        if ProcessInfo.processInfo.arguments.contains("-simklQRDemo") {
            return AnyView(
                ZStack {
                    theme.palette.background.ignoresSafeArea()
                    SimklConnectPage(
                        code: SimklDeviceCode(userCode: "AB12CD34",
                                              verificationURL: "https://simkl.com/pin",
                                              interval: 5, expiresIn: 600),
                        expiresAt: Date().addingTimeInterval(600)
                    )
                }
                .environmentObject(theme)
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
            if perf.settings.showHoldProbe { HoldProbeHUD() }
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
                allowUnairedNextUp: homeCatalogSettings.showUnairedNextUp,
                // Auto-advance / in-player episode pick: the cover and its
                // PlaybackRequest never change, so `onChange(of: playback?.id)`
                // below can't see it. Without this only episode one of a binge
                // was ever scrobbled.
                onNowPlayingChanged: { meta, video in
                    scrobbleNowPlayingChanged(meta, video)
                }
            ) {
                // Just dismiss the cover; the auto-play pop runs in onDismiss.
                playback = nil
            }
        }
        .onChange(of: playback?.id) { _, _ in scrobbleForPlaybackChange() }
        // Deep-link add-on install confirmation. A tvOS alert is fully
        // focusable and remote-navigable, and Cancel carries the `.cancel`
        // role so a Menu press is a REFUSAL — the safe default for a prompt
        // the viewer may not have asked for.
        .alert(
            pendingAddonInstall?.isUpdate == true ? "Update add-on?" : "Install add-on?",
            isPresented: Binding(
                get: { pendingAddonInstall != nil },
                set: { if !$0 { pendingAddonInstall = nil } }
            ),
            presenting: pendingAddonInstall
        ) { pending in
            Button(pending.isUpdate ? "Update" : "Install") { confirmAddonInstall(pending) }
            Button("Cancel", role: .cancel) { pendingAddonInstall = nil }
        } message: { pending in
            Text("\(pending.name)\n\(pending.manifestURL)\n\nThis add-on will be able to supply catalogs, metadata and stream links to Orivio.")
        }
        .alert("Can't play this channel",
               isPresented: Binding(get: { liveChannelError != nil },
                                    set: { if !$0 { liveChannelError = nil } })) {
            Button("OK", role: .cancel) { liveChannelError = nil }
        } message: {
            Text(liveChannelError ?? "")
        }
        // Feed the resolved system scheme to the theme so `.system` appearance
        // under the Apple TV theme can pick the matching palette.
        .onAppear { theme.systemIsDark = colorScheme == .dark }
        .onChange(of: colorScheme) { _, scheme in theme.systemIsDark = scheme == .dark }
    }

    /// Whether the current tab is at its root (no pushed screen). When a
    /// Detail/Streams/etc. is pushed the rail hides so that screen runs
    /// full-bleed.
    private var atTabRoot: Bool {
        switch selectedTab {
        case 0: return homePath.isEmpty
        case 1: return searchPath.isEmpty
        case 2: return libraryPath.isEmpty
        case 4: return liveTVPath.isEmpty
        default: return true   // Settings keeps the rail
        }
    }

    /// Layout → "Hide the sidebar until it's needed": the collapsed rail is
    /// off screen entirely and content runs full width, until a sideways press
    /// at the left edge of the content (or Menu) calls it back. Settings keeps
    /// its rail regardless — that pane is navigated THROUGH the rail, and
    /// hiding it there leaves no way back out of a settings detail.
    /// Where the rail lives. Read once here so every axis-dependent site below
    /// agrees, and so the whole feature is one value to follow.
    private var navPosition: NavigationPosition { homeCatalogSettings.navigationPosition }
    private var navIsTop: Bool { navPosition.isHorizontal }

    private var sidebarAutoHides: Bool {
        homeCatalogSettings.autoHideSidebar && selectedTab != 3
    }

    /// Set when the auto-hiding rail has been summoned; cleared when it
    /// collapses again.
    @State private var sidebarRevealed = false

    /// When the rail was last ASKED for — a summon, or focus actually landing
    /// in it. Read only by the rail's exit-move handler; see the note there.
    @State private var sidebarEngagedAt = Date.distantPast

    /// How long after engaging the rail an exit move is treated as an echo of
    /// the gesture that opened it rather than a fresh instruction to leave.
    ///
    /// Short enough that a deliberate press pair is never swallowed (two
    /// separate presses on the clickpad are far slower than this), long enough
    /// to cover the tail of ONE swipe on the old remote's touch surface.
    private static let sidebarExitEchoWindow: TimeInterval = 0.3

    private var showSidebar: Bool {
        guard atTabRoot else { return false }
        return !sidebarAutoHides || sidebarRevealed
    }

    /// Bring a hidden rail back and put focus on it. The reveal has to happen
    /// BEFORE the focus write — the rail isn't in the view tree until
    /// `showSidebar` turns true, and `@FocusState` on a view that doesn't
    /// exist yet is dropped on the floor.
    private func revealSidebar() {
        guard sidebarAutoHides, !sidebarRevealed else {
            AppProbe.focus("reveal rail refused — autoHides=\(sidebarAutoHides.probe)"
                           + " alreadyRevealed=\(sidebarRevealed.probe)")
            return
        }
        // The failed-move notification is app-wide: a left press with no
        // target inside the player, a pushed Detail page, or either fullscreen
        // gate reaches here too, and revealing there would flip state for a
        // rail that isn't even on screen — it then greets the viewer already
        // open when they come back to the root.
        guard atTabRoot, playback == nil, !showProfileGate, !showWelcome else {
            AppProbe.focus("reveal rail refused — atRoot=\(atTabRoot.probe)"
                           + " player=\((playback != nil).probe) gate=\(showProfileGate.probe)"
                           + " welcome=\(showWelcome.probe)")
            return
        }
        AppProbe.focus("reveal rail")
        sidebarRevealed = true
        sidebarEngagedAt = Date()
        setSidebarEnabled(true)
        DispatchQueue.main.async { sidebarFocus = selectedTab }
    }

    /// The app's single root: an always-visible Liquid Glass rail floating at
    /// the left edge over full-bleed content. OVERLAY layout (not an HStack)
    /// so the expanding panel just draws over the content — the content
    /// column never re-lays-out during the spring.
    private var tabLayout: some View {
        ZStack(alignment: navIsTop ? .top : .leading) {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Tab changes CUT. No fade, in either direction.
                //
                // There were two attempts at fading before this, and each one
                // exposed something it shouldn't:
                //
                // 1. `insertion: .opacity, removal: .identity`. `.identity`
                //    does not mean "leaves the tree at once" — it means no
                //    visual transform is applied, so the outgoing page stayed
                //    FULLY OPAQUE for the whole 0.22s while the new one faded
                //    in on top of it. Home's hero art showed straight through
                //    the half-faded page arriving over it.
                // 2. Removing the outgoing page over ~0 seconds fixed that,
                //    and then the fade-in had nothing in front of the app
                //    background — so `ATVBackground`'s accent bloom flashed
                //    through the half-transparent page instead.
                //
                // Both are the same root cause: a page that is partially
                // transparent shows whatever is behind it, and on this screen
                // there is always something behind it worth not seeing. A cut
                // has no transparent frame at all, which is also what the
                // system tvOS apps do when moving between tabs.
                //
                // `.id` still forces a fresh view per tab, so the outgoing
                // hierarchy is torn down rather than updated in place.
                .id(selectedTab)
                .transition(.identity)
                .animation(nil, value: selectedTab)
                // Home runs full-bleed (hero art sweeps under the floating
                // pill); other tabs clear the rail. The top bar reserves
                // height where the left rail reserves width — and Home is NOT
                // exempt there: the left rail floats beside the hero's art,
                // but a top bar sits across the hero's own title block, which
                // is text rather than bleed.
                .padding(.leading, !navIsTop && showSidebar && selectedTab != 0
                         ? GlassSidebar.collapsedWidth : 0)
                // Same rule on the other axis, Home included: the bar FLOATS
                // over Home the way the pill floats beside it, so the hero is
                // never pushed down. The other tabs get a SAFE-AREA inset
                // rather than a plain one — see `topBarClearance`: plain
                // padding cut the page off under the bar, so scrolled rows hit
                // a black band instead of sliding under the glass.
                .safeAreaPadding(.top, navIsTop && showSidebar && selectedTab != 0
                                 ? GlassSidebar.topBarClearance : 0)
                // The expanded panel draws OVER the page and the page does
                // not move. There was an `.offset` here (plus an animation
                // keyed to the rail opening) that slid the content sideways to
                // clear the panel's right edge. It kept every heading legible,
                // but it meant opening the rail shoved the whole screen
                // across, which is the part that reads as wrong in motion — a
                // side panel is supposed to overlay. The cost is that while it
                // is open the panel covers the leading edge of what is under
                // it. Nothing dims behind it either: the rail's glass samples
                // what is behind it, so a scrim under it only turns the glass
                // muddy.
                .focusSection()
                // Summon a hidden rail — but ONLY from the left edge. This was
                // `.onMoveCommand(.left)` on the section, on the belief that a
                // section's move handler fires only when the engine finds no
                // candidate. It does not: it fires on EVERY left press anywhere
                // in the content, so stepping between two cards mid-row popped
                // the rail open. `movementDidFailNotification` is the engine's
                // own "I looked left and found nothing" — exactly the press
                // from the first card of a row, and nothing else.
                .onReceive(NotificationCenter.default.publisher(
                    for: UIFocusSystem.movementDidFailNotification)) { note in
                    guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                            as? UIFocusUpdateContext else { return }
                    // The press that reaches for the rail is whichever one
                    // points AT it: Left for the edge rail, Up for the bar.
                    // Everything downstream is identical.
                    guard ctx.focusHeading.contains(navIsTop ? .up : .left) else { return }
                    // Search root with the rail ON SCREEN but inside one of its
                    // short `.disabled` windows (the moments after a tab switch
                    // or a rail exit, kept so the engine seeds focus into the
                    // content). A disabled rail can't take focus, so this Left
                    // failed and was swallowed: the search bar read as a trap
                    // while Back, which force-enables the rail, still worked.
                    // A deliberate Left now takes Back's path. Search only.
                    if selectedTab == 1, showSidebar, !sidebarEnabled, sidebarFocus == nil,
                       playback == nil, !showProfileGate, !showWelcome {
                        focusSidebar(selectedTab)
                    } else if navIsTop, showSidebar, sidebarFocus == nil, atTabRoot,
                              playback == nil, !showProfileGate, !showWelcome {
                        // TOP BAR, already on screen, and Up found nothing: put
                        // focus in it.
                        //
                        // The left rail never needs this — it sits BESIDE the
                        // content (which is inset by its width), so the engine
                        // finds it by geometry. The bar sits OVER content that
                        // spans the full height, and from a page whose own
                        // topmost row is close under it the engine answers "no
                        // candidate" instead of stepping up into it. The press
                        // then did nothing at all: Library's filter chips were
                        // a dead end upward, and with "Hide the sidebar" on
                        // there was no way to call the bar back either, because
                        // the branch below only reveals a bar that is OFF
                        // screen. Same remedy the Search case above uses, which
                        // is the same problem on the other axis.
                        focusSidebar(selectedTab)
                    } else {
                        revealSidebar()
                    }
                }
                // Lets the content tell whether a LEFT press should be its own
                // (step the hero spotlight) or the rail's (come back).
                // "A LEFT press has to escape to the rail." False with the bar
                // on top, where Left is never the rail's press — so the hero's
                // spotlight sentinels stay in place there, which is what they
                // are for.
                .environment(\.railIsHidden,
                             !navIsTop && sidebarAutoHides && !sidebarRevealed)
                // Layout, not input: Home's own leading inset exists to clear a
                // rail at the LEFT edge, and there isn't one in the top layout.
                .environment(\.navigationIsTop, navIsTop)

            if showSidebar {
                GlassSidebar(selected: $selectedTab, focusBinding: $sidebarFocus,
                             onProfileTap: { profileGateCancellable = true; showProfileGate = true },
                             onTabSelected: { newTab in selectTab(newTab) },
                             position: navPosition)
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
                        // Out of the rail and into the content: Right off the
                        // edge rail, Down off the top bar.
                        guard direction == (navIsTop ? .down : .right) else { return }
                        // …unless this is the tail of the swipe that just
                        // OPENED the rail.
                        //
                        // The old Siri Remote's touch surface reports a swipe
                        // as a stream of move commands, and the settling end of
                        // one carries a move back the other way; the clickpad
                        // on the current remote emits a single discrete press
                        // and never does this. So a swipe left landed focus in
                        // the rail and the same gesture's tail immediately
                        // exited it — the panel opened and bounced straight
                        // back, only ever on the old remote. The race below
                        // makes it worse: this block is async, so a tail that
                        // arrives before focus has settled sees `sidebarFocus`
                        // still nil and disables the rail exactly as focus is
                        // arriving, which pushes it back to the content too.
                        //
                        // A leaving move is only real once the opening one has
                        // had time to finish.
                        guard Date().timeIntervalSince(sidebarEngagedAt)
                                > Self.sidebarExitEchoWindow else { return }
                        // The engine acts on this press too: on tabs whose
                        // content clears only the COLLAPSED rail, cards past
                        // the panel's edge are real right candidates, so focus
                        // may already have moved by the next tick. Then the
                        // engine's pick stands — only the housekeeping runs —
                        // instead of a second, visible teleport on top of it.
                        DispatchQueue.main.async {
                            if sidebarFocus != nil {
                                collapseSidebarFromExit()
                            } else {
                                if sidebarAutoHides { sidebarRevealed = false }
                                setSidebarEnabled(false, reenableAfter: 0.4)
                            }
                        }
                    }
                    .transition(.move(edge: navIsTop ? .top : .leading).combined(with: .opacity))
                    // Stays non-focusable until Home has content to hold
                    // initial focus (onContentReady); timer is the fallback.
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        // Cold-launch fallback ONLY. When a tab switch is
                        // deliberately waiting on onContentReady, this timer
                        // used to flip the rail focusable over slow addons
                        // and the panel reclaimed initial focus.
                        if sidebarReenableTask == nil, !sidebarAwaitingContent {
                            sidebarEnabled = true
                        }
                    }
            }
        }
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: showSidebar)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: sidebarFocus != nil)
        // Focus ARRIVING in the rail counts as engaging it, however it got
        // there. `focusSidebar` and `revealSidebar` stamp their own way in, but
        // the common case — an always-visible rail that the focus engine simply
        // moves into from the first card of a row — goes through neither, and
        // that is exactly the case a swipe hits.
        .onChange(of: sidebarFocus) { old, new in
            if old == nil, new != nil { sidebarEngagedAt = Date() }
        }
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
                    .onExitCommand { focusSidebar(1) }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
        case 2:
            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { focusSidebar(2) }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
        case 3:
            NavigationStack {
                ATVSettingsView(onOpenProfiles: { profileGateCancellable = true; showProfileGate = true })
                    .onExitCommand { focusSidebar(3) }
                    .probeScreen("Settings")
            }
        case 4:
            NavigationStack(path: $liveTVPath) {
                liveTVRoot
                    .onExitCommand { focusSidebar(4) }
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
                        focusSidebar(0)
                    }
                    .onChange(of: homePath.count) { oldCount, newCount in
                        // Only a pop that lands ON Home matters here.
                        guard newCount < oldCount, newCount == 0 else { return }
                        lastHomePopAt = Date()
                        // Popping all the way back to Home: keep the rail
                        // non-focusable for a beat so focus lands on a card
                        // instead of the rail springing open.
                        setSidebarEnabled(false, reenableAfter: 0.9)
                    }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $homePath) }
            }
        }
    }

    /// Rail tabs by name, for the probe. Numbers in a log are a second thing
    /// to decode while reading a focus bug.
    static func tabName(_ tab: Int) -> String {
        switch tab {
        case 1: return "Search"
        case 2: return "Library"
        case 3: return "Settings"
        case 4: return "Live TV"
        default: return "Home"
        }
    }

    /// The `[stores]` probe block: what the app is holding right now, which is
    /// the other half of "why is this row empty" — the first half being the
    /// `data` events that tried to fill it.
    private func installStoreProbe() {
        PlayerProbe.register("stores") { [weak addonManager, weak collections,
                                          weak library, weak progressStore,
                                          weak profiles, weak account] in
            var out: [String] = []
            if let addonManager {
                let enabled = addonManager.addons.filter(\.enabled)
                let stubs = enabled.filter { $0.manifest.isPlaceholder }
                out.append("addons \(enabled.count)/\(addonManager.addons.count) enabled"
                           + (stubs.isEmpty ? "" : "  STUBS: " + stubs.map(\.manifest.name).joined(separator: ", ")))
            }
            if let collections {
                out.append("collections \(collections.library.count)")
            }
            if let library {
                out.append("library \(library.items.count)")
            }
            if let progressStore {
                out.append("continue watching \(progressStore.items.count)")
            }
            if let profiles {
                out.append("profile \(profiles.active.name) [\(profiles.active.id)]"
                           + "  of \(profiles.profiles.count)")
            }
            if let account {
                out.append("account \(account.authState.isSignedIn ? "signed in" : "signed out")")
            }
            return out
        }
    }

    /// Handles tapping a rail tab: collapse the panel and force focus into the
    /// fresh tab's content by making the rail momentarily unfocusable.
    private func selectTab(_ newTab: Int) {
        let enteringHomeFresh = selectedTab != 0 && newTab == 0
        AppProbe.nav("tab \(Self.tabName(selectedTab)) → \(Self.tabName(newTab))"
                     + (enteringHomeFresh ? "  (Home rebuilds; rail waits on content)" : ""))
        AppProbe.tab = Self.tabName(newTab)
        selectedTab = newTab
        if homeCatalogSettings.autoHideSidebar { sidebarRevealed = false }
        sidebarFocus = nil
        // Through the owner, so a pending re-enable (a rail exit moments ago)
        // is CANCELLED — it used to flip the rail focusable before the fresh
        // tab's content could hold focus, and the panel sprang open over it.
        setSidebarEnabled(false)
        // Entering Home fresh rebuilds HomeView; its onContentReady is the
        // sole re-enabler there (a blind timer could beat the rows to
        // focusability and the rail would reclaim focus).
        sidebarAwaitingContent = enteringHomeFresh
        guard enteringHomeFresh else {
            setSidebarEnabled(false, reenableAfter: 0.4)
            return
        }
    }

    /// Open the rail on `tab`. The rail is `.disabled` for short windows after
    /// every tab switch / collapse / pop (so the engine seeds focus into the
    /// content instead), and a focus request into a disabled view is silently
    /// dropped — a Menu press in one of those windows did nothing. A deliberate
    /// Back always wins: enable now, focus on the next tick.
    private func focusSidebar(_ tab: Int) {
        AppProbe.focus("focusSidebar(\(Self.tabName(tab)))"
                       + "  revealed=\(sidebarRevealed.probe) enabled=\(sidebarEnabled.probe)")
        // Menu at a tab root is the other way back to a hidden rail.
        if sidebarAutoHides { sidebarRevealed = true }
        sidebarEngagedAt = Date()
        setSidebarEnabled(true)
        DispatchQueue.main.async { sidebarFocus = tab }
    }

    /// Back pressed while the rail itself is focused: close the panel. Always
    /// the fast fixed-delay re-enable — nothing is being freshly mounted.
    private func collapseSidebarFromExit() {
        // An auto-hiding rail goes all the way away again, not just narrow.
        if sidebarAutoHides { sidebarRevealed = false }
        // Hand focus to the FIRST tile of the row the viewer left, when that
        // row is mounted to take it. Dropping the rail's focus with no
        // destination let the engine pick whatever card sat nearest the
        // rail's centre — the fourth along, with the first two under the
        // panel. The rail stays enabled for the turn the hand-off needs; a
        // request into a `.disabled` view is silently dropped.
        if ContentFocusRouter.shared.focusLastRowStart() {
            DispatchQueue.main.async {
                sidebarFocus = nil   // a no-op once the tile holds focus
                setSidebarEnabled(false, reenableAfter: 0.4)
            }
            return
        }
        sidebarFocus = nil
        setSidebarEnabled(false, reenableAfter: 0.4)
    }

    /// The ONE owner of every timed rail re-enable. Five independent timers
    /// used to race each other: exit the rail (400ms re-enable pending), then
    /// switch tabs — the tab switch disabled the rail to keep initial focus in
    /// the content, and the stale 400ms timer flipped it back early, so the
    /// panel sprang open over the fresh screen. Scheduling through one task
    /// cancels whatever was pending first.
    @State private var sidebarReenableTask: Task<Void, Never>?

    private func setSidebarEnabled(_ enabled: Bool, reenableAfter delay: Double? = nil) {
        // The rail's `.disabled` windows swallow directional presses, which is
        // the shape of half the focus bugs this app has had — so every open and
        // close of one is on the record, with how long it is meant to last.
        AppProbe.focus("rail " + (enabled ? "enabled" : "disabled")
                       + (delay.map { String(format: " for %.2fs", $0) } ?? ""))
        AppProbe.rail = enabled ? "enabled" : "disabled"
        if enabled { sidebarAwaitingContent = false }
        sidebarReenableTask?.cancel()
        sidebarReenableTask = nil
        sidebarEnabled = enabled
        guard !enabled, let delay else { return }
        scheduleSidebarReenable(after: delay)
    }

    /// Waiting on HomeView's onContentReady before the rail may take focus
    /// (the entering-Home-fresh tab switch). Distinct from a pending timer,
    /// so the cold-launch 3s fallback can tell the two disables apart.
    @State private var sidebarAwaitingContent = false

    /// Re-enable the rail after `delay` WITHOUT touching its current state —
    /// for callers that merely want "focusable again soon" (onContentReady),
    /// where disabling first would break a rail the viewer has open.
    private func scheduleSidebarReenable(after delay: Double) {
        sidebarAwaitingContent = false
        sidebarReenableTask?.cancel()
        sidebarReenableTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AppProbe.focus("rail re-enabled by timer")
            AppProbe.rail = "enabled"
            sidebarEnabled = true
            sidebarReenableTask = nil
        }
    }

    /// The rail's cold-launch fallback timer keeps running while the profile
    /// gate covers the screen, so once the gate dismisses the focus engine
    /// would land on the rail and pop it open. Briefly disable it again so
    /// focus goes to Home's content first.
    private func deferSidebarAfterProfileGate() {
        setSidebarEnabled(false, reenableAfter: 0.8)
    }

    // MARK: - Tab roots

    private var homeRoot: some View {
        HomeView(
            viewModel: homeViewModel,
            onSelect: { homePath.append(Route.detail($0)) },
            onResume: { resume($0) },
            onResumeFromStart: { resume($0, fromBeginning: true) },
            onPlayManually: { meta, video in playManually(meta, video) },
            onPlayManuallyProgress: { playManuallyFromProgress($0) },
            onOpenCollection: { homePath.append(Route.collection($0)) },
            // A pinned channel plays exactly as it would from the Live TV tab:
            // an M3U channel straight away, an add-on channel via the picker.
            onPlayChannel: { channel in
                if channel.directURL != nil { playLiveChannel(channel) }
                else if let meta = channel.meta { homePath.append(Route.streams(meta, nil)) }
            },
            onSeeAll: { addon, catalog, title in
                homePath.append(Route.catalogSeeAll(addon: addon, catalog: catalog, title: title))
            },
            onContentReady: {
                // Give the freshly-loaded rows a beat to render and take
                // initial focus before the rail becomes focusable. This must
                // ONLY schedule the re-enable — it fires on every catalog
                // refresh, and disabling first would kick focus off an OPEN
                // rail whenever a background sync reloaded Home.
                scheduleSidebarReenable(after: 0.8)
            },
            // Back at the start of a row opens the rail.
            onHomeBack: {
                if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < 1.0 { return }
                focusSidebar(0)
            }
        )
        .probeScreen("Home")
    }

    private var searchRoot: some View {
        SearchView(
            viewModel: searchViewModel,
            onSelect: { searchPath.append(Route.detail($0)) },
            onOpenDiscover: { searchPath.append(Route.discover) }
        )
        .probeScreen("Search")
    }

    private var libraryRoot: some View {
        LibraryView(
            onSelect: { libraryPath.append(Route.detail($0)) },
            onOpenCloud: { libraryPath.append(Route.cloudLibrary) },
            onPlayMediaServer: { startPlayback($0) },
            onOpenMediaServerShow: { libraryPath.append(Route.mediaServerShow($0)) },
            onBackAtRoot: { focusSidebar(2) }
        )
        .probeScreen("Library")
    }

    private var liveTVRoot: some View {
        LiveTVView(
            onSelectChannel: { channel in liveTVPath.append(Route.streams(channel, nil)) },
            onPlayDirect: { channel in playLiveChannel(channel) }
        )
        .probeScreen("Live TV")
    }

    /// Shared navigation destinations. `path` is the binding for whichever
    /// tab's stack is presenting, so nested pushes stay within that tab.
    /// Every pushed screen goes through here, so ONE marker covers all of
    /// them — and a route added later is instrumented the moment it is
    /// reachable, with no second place to remember.
    private func destination(for route: Route, path: Binding<NavigationPath>) -> some View {
        destinationBody(for: route, path: path)
            .probeScreen(route.probeName) { route.probeDetail }
    }

    @ViewBuilder
    private func destinationBody(for route: Route, path: Binding<NavigationPath>) -> some View {
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
        case .mediaServerShow(let show):
            MediaServerShowView(show: show) { startPlayback($0) }
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
                // Like the external branch of `startPlayback`: no in-app cover
                // opens here, so nothing would ever consume a deferred auto-play
                // pop and it would fire against the wrong screen later.
                discardPendingAutoPlayPopAroundHandoff()
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
            // Carries `onAutoDismiss` like every other automatic route: without
            // it an auto-picked Start Over had nothing to pop, so the source
            // list uncovered itself behind the player and Back landed on it.
            StreamsView(
                meta: meta, video: video,
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
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

    /// Progress keys that crossed the "finished" threshold during playback.
    ///
    /// `ProgressStore.update` DELETES the row at >=95%, so by the time the player
    /// dismisses and the stop scrobble runs there is nothing left to read a final
    /// fraction from. It reported 0% — and Trakt reads a stop under 80% as a
    /// PAUSE, so every title the viewer actually finished landed back on their
    /// account as a 0% in-progress row (which "Sync Continue Watching" then
    /// pulled straight back into the Continue Watching row).
    ///
    /// A reference box rather than a plain `Set` because the store's `onFinished`
    /// callback is installed once and has to write somewhere the view can read.
    final class FinishedKeys { var keys: Set<String> = [] }
    @State private var finishedThisSession = FinishedKeys()

    /// The `PlaybackRequest` id Picture in Picture has just put back on screen.
    ///
    /// A handoff dismisses this cover and a restore re-presents the SAME
    /// request, so `onChange(of: playback?.id)` sees the id go nil and come
    /// back — indistinguishable from the viewer starting the title afresh.
    /// That is how a restore came to report a `start` at the position the
    /// session ORIGINALLY resumed from (0% for a film played from the top)
    /// while the engine had been playing continuously for an hour.
    /// `PiPHandoff.isActive` cannot answer this side: the re-presented screen
    /// releases the park from `PlayerScreen.init`, before this handler runs.
    ///
    /// A reference box for the same reason as `FinishedKeys` above: it is
    /// written by the `present` closure PiPHandoff holds and read from the
    /// change handler, with no view update guaranteed to sit between the two.
    final class PiPRestoredRequest { var id: UUID? }
    @State private var pipRestored = PiPRestoredRequest()

    private func scrobbleForPlaybackChange() {
        guard trakt.isSignedIn, trakt.scrobbleEnabled, let token = trakt.accessToken else {
            scrobblingItem = nil
            return
        }
        if let request = playback {
            // Coming back from Picture in Picture: this cover is being
            // re-presented for a session that never stopped, so there is
            // nothing to start — and `resumePosition` is where that session
            // BEGAN, so starting from it threw the account's progress back to
            // the top of the film while the engine was an hour in. The item is
            // still in `scrobblingItem` (the handoff left it there) and, if the
            // session auto-advanced inside the PiP window, it is the episode
            // actually playing rather than the one this request names.
            if pipRestored.id == request.id {
                pipRestored.id = nil
                return
            }
            // Playback started.
            startScrobble(meta: request.meta, video: request.video,
                          resumePosition: request.resumePosition, token: token)
        } else if let item = scrobblingItem {
            // The handoff INTO Picture in Picture dismisses this cover while
            // the engine plays on in the system's small window (PlayerScreen's
            // onWillStart: begin() then dismiss()), so this nil is the UI
            // leaving, not playback ending. A stop here reported the title as
            // paused mid-film every time the viewer popped it out — Trakt reads
            // a stop under 80% as a pause. The session's real stop follows when
            // the restored cover is dismissed for good.
            if PiPHandoff.shared.isActive { return }
            // Playback ended — report final progress.
            scrobblingItem = nil
            stopScrobble(item, token: token)
        }
    }

    /// The playing item changed WITHIN one player session — auto-advance to the
    /// next episode, or a pick from the in-player episode list.
    ///
    /// The player advances inside the SAME `fullScreenCover` and never replaces
    /// the `PlaybackRequest`, so `onChange(of: playback?.id)` never fires: every
    /// episode after the first got no `start`, and the eventual `stop` was
    /// addressed to episode ONE — a whole binge landed on Trakt as one episode
    /// watched and the rest untouched. Treat it as end-of-previous +
    /// start-of-next, reusing the same bookkeeping as the cover-level lifecycle.
    private func scrobbleNowPlayingChanged(_ meta: MetaItem, _ video: MetaVideo?) {
        guard trakt.isSignedIn, trakt.scrobbleEnabled, let token = trakt.accessToken else {
            scrobblingItem = nil
            return
        }
        // Same item (a reload / source switch re-announcing the current
        // episode): re-sending start/stop would double-count it.
        if let current = scrobblingItem,
           current.meta.id == meta.id,
           current.video?.id == video?.id {
            return
        }
        if let previous = scrobblingItem {
            scrobblingItem = nil
            stopScrobble(previous, token: token)
        }
        // No resume position: an auto-advanced episode starts at zero, and a
        // pick from the episode list has already had its own resume applied by
        // the player itself.
        startScrobble(meta: meta, video: video, resumePosition: nil, token: token)
    }

    private func startScrobble(meta: MetaItem, video: MetaVideo?,
                               resumePosition: Double?, token: String) {
        scrobblingItem = (meta, video)
        let startKey = ProgressStore.key(metaID: meta.id, video: video)
        // A re-watch starts fresh: last session's "finished" must not make
        // this one report 100% if the viewer bails out after five minutes.
        finishedThisSession.keys.remove(startKey)
        let fraction = resumePosition.flatMap { pos -> Double? in
            guard let duration = progressStore.progress(for: startKey)?.durationSeconds, duration > 0 else { return nil }
            return pos / duration * 100
        } ?? 0
        Task {
            await TraktService.scrobble(
                action: .start, imdbID: meta.id, type: meta.type,
                season: video?.season, episode: video?.episode,
                progress: fraction, accessToken: token
            )
        }
    }

    private func stopScrobble(_ item: (meta: MetaItem, video: MetaVideo?), token: String) {
        let key = ProgressStore.key(metaID: item.meta.id, video: item.video)
        // A live row wins; otherwise a row that vanished because it FINISHED
        // reports complete, and one that never existed reports 0.
        let fraction: Double
        if let live = progressStore.progress(for: key)?.fraction {
            fraction = live * 100
        } else if finishedThisSession.keys.contains(key) {
            fraction = 100
        } else {
            fraction = 0
        }
        finishedThisSession.keys.remove(key)
        Task {
            await TraktService.scrobble(
                action: .stop, imdbID: item.meta.id, type: item.meta.type,
                season: item.video?.season, episode: item.video?.episode,
                progress: fraction, accessToken: token
            )
        }
    }

    /// Resume from Continue Watching. Items saved on this device carry the
    /// stream URL and replay directly; items pulled from the account have no
    /// URL (the backend doesn't store it), so we route to source selection.
    /// Single entry point for starting playback. External-app engine hands
    /// the stream straight to the chosen player (Infuse etc.) instead of
    /// opening Orivio's own player; if the chosen app was uninstalled, any
    /// other installed one is used; none installed → play internally.
    /// Play a direct Live TV channel (M3U): wrap its URL in a one-off stream and
    /// go straight to the player — no source picker, no debrid.
    private func playLiveChannel(_ channel: LiveChannel) {
        guard let rawURL = channel.directURL else { return }
        // A `|Header=Value` suffix can reach here on a channel that came from
        // somewhere other than the playlist parser (a favourite stored by an
        // older build, an add-on). Splitting again is idempotent.
        let split = LiveStreamClassifier.splitPipedOptions(rawURL)
        var options = channel.options
        options.merge(split.options)

        // Say WHY an encrypted channel can't play. Handing a DRM-protected
        // manifest to the player produces a generic decode failure and four
        // pointless source retries; tvOS gives third-party apps no Widevine or
        // PlayReady CDM at all, so this can only ever fail.
        if let reason = options.unsupportedDRMReason {
            liveChannelError = reason
            return
        }

        Task { @MainActor in
            var playURL = split.url
            // YouTube links are pages, not media. Community playlists are full
            // of 24/7 relays published as ordinary watch/live URLs, and handing
            // one straight to a player fetches HTML.
            if LiveStreamClassifier.isYouTube(playURL) {
                guard let resolved = await LiveStreamResolver.resolveYouTube(playURL) else {
                    liveChannelError = "Couldn't open this YouTube channel. YouTube may have "
                        + "ended the broadcast or changed how it serves this video."
                    return
                }
                playURL = resolved.url
                options.merge(resolved.options)
            }

            let hints = options.requestHeaders.map {
                StreamBehaviorHints(proxyHeaders: StreamProxyHeaders(request: $0))
            }
            let stream = Stream(name: "Live", title: channel.name, description: nil,
                                url: playURL, infoHash: nil, behaviorHints: hints)
            let entry = StreamEntry(addonName: "Live TV", stream: stream)
            let meta = MetaItem(id: channel.id, type: "tv", name: channel.name,
                                poster: channel.logo, background: channel.logo, logo: channel.logo)
            startPlayback(PlaybackRequest(
                meta: meta, video: nil, entry: entry, allEntries: [entry], resumePosition: nil,
                // RTMP/RTSP/UDP and DASH cannot be opened by AVPlayer at all,
                // so the engine preference must not be honoured for them —
                // with Native selected the channel would simply fail.
                forceDemuxer: LiveStreamClassifier.kind(for: playURL, options: options) == .demuxer
            ))
        }
    }

    /// Pop the source page off the active tab's stack after an Auto Link
    /// Selector auto-play, so backing out of the player returns to the title
    /// page. Safe here because the player has fully closed by now. The player
    /// covers the stack while it's up, so the top entry is still the source page.
    /// Run a deferred auto-play pop now, for the paths that never open the
    /// in-app player. Deferred by one runloop turn for the same reason the
    /// player's `onDismiss` defers it: mutating the NavigationStack path while
    /// the source view's own resolve Task is still unwinding desyncs the stack.
    private func consumePendingAutoPlayPop() {
        guard pendingAutoPlayPop else { return }
        pendingAutoPlayPop = false
        DispatchQueue.main.async { popActivePathForAutoPlay() }
    }

    /// The external-handoff variant. `StreamsView` runs its `onSelect` callback
    /// (which reaches here) BEFORE its `autoDismiss()` arms
    /// `pendingAutoPlayPop`, so a plain `consumePendingAutoPlayPop()` runs one
    /// step too early and the pop it exists to prevent is armed immediately
    /// afterwards — then fires against whatever screen is open the next time an
    /// in-app player closes. Clear it on the NEXT runloop turn (after the arm)
    /// and never pop: an external return lands on Home, not a source page.
    private func discardPendingAutoPlayPopAroundHandoff() {
        consumePendingAutoPlayPop()
        DispatchQueue.main.async { pendingAutoPlayPop = false }
    }

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
                // No in-app player cover opens on this path, so nothing will
                // ever consume a deferred auto-play pop. Left set, it fires
                // against the WRONG screen the next time any in-app playback
                // ends, throwing the viewer back one page too far.
                discardPendingAutoPlayPopAroundHandoff()
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
        // A session parked in the Picture in Picture window is still decoding
        // and still owns the audio route, and nothing in the app ever ended
        // one — `stop()` had no callers at all. Opening a different title over
        // it left two engines live: two soundtracks at once and two pipelines
        // on a 3 GB A10X, and with the hybrid cache on, `beginSession` for the
        // new origin tore down the parked session's connections and deleted
        // the cache file its reader was still reading.
        if PiPHandoff.shared.isActive {
            // Window first: `finish()` on its own runs the teardown but leaves
            // AVKit's window up over a view model that no longer exists.
            PiPHandoff.shared.viewModel?.pictureInPicture.stop()
            // Then the teardown `onDidStop` would have run — synchronously,
            // BEFORE the new cover. Teardown resets state the two sessions
            // share (the cache server's session, the audio session, the sync
            // pause), so letting it land after the new load has started strips
            // that out from under the new engine. AVKit's own `didStop` still
            // arrives later and finds nothing parked, which is a no-op.
            PiPHandoff.shared.finish()
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
               let match = subs.first(where: {
                   AudioLanguageMatch.matches(code: $0.lang, label: nil, preferred: preferred)
               }) {
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
            // The scheme is this install's OWN (see AppCallbackScheme) — the
            // generic `orivio` is claimed by every other sideload of this app
            // on the box, and the callback was landing in one of those.
            handoff.successURL = "\(AppCallbackScheme.value)://external-return"
            handoff.errorURL = "\(AppCallbackScheme.value)://external-error"
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
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
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

    /// Landing spot after an external player. The viewer chose a stream on a
    /// source (or title) page; when the other app hands the screen back, drop
    /// the whole pushed stack and show Home instead of leaving them on that
    /// picker. Only called from a confirmed external return — the callback
    /// deep link, or the one-shot launch marker on foreground — so ordinary
    /// playback navigation is untouched.
    private func returnToHomeFromExternalPlayback() {
        // A stream is on screen (or about to be): never yank the navigation
        // stack out from under a live player. The external handoff has no
        // cover of its own, so this only catches a pathological overlap.
        guard playback == nil else { return }
        // Any deferred auto-play pop pointed at the source page this is about
        // to remove; left set it would later fire against Home.
        pendingAutoPlayPop = false
        // DEFERRED, not synchronous. Mutating `selectedTab` and the
        // NavigationPaths in the same runloop tick the app becomes active (or
        // the callback deep link lands) desyncs the NavigationStack: the path
        // empties while the pushed screen lingers as a grey, focusable ghost.
        // The in-app player's own `onDismiss` defers for exactly this reason.
        DispatchQueue.main.async {
            // Pop the stack we are LEAVING (the tab that launched the handoff)
            // so its source page can't be landed on later, plus Home's own
            // stack so we truly arrive at the Home root. The OTHER tabs' places
            // are deliberately left alone — this change is only about where an
            // external return lands, not a global navigation reset.
            // `removeLast(count)`, NOT `path = NavigationPath()`: this app
            // deliberately never resets a path wholesale (every other pop is a
            // single `removeLast()`), and assigning an empty path is what
            // leaves the pushed screen behind as a grey ghost.
            switch selectedTab {
            case 1: if !searchPath.isEmpty { searchPath.removeLast(searchPath.count) }
            case 2: if !libraryPath.isEmpty { libraryPath.removeLast(libraryPath.count) }
            case 4: if !liveTVPath.isEmpty { liveTVPath.removeLast(liveTVPath.count) }
            default: break
            }
            if !homePath.isEmpty { homePath.removeLast(homePath.count) }
            selectedTab = 0
            // Home is the finished screen: make the rail focusable right away
            // so it is usable instead of waiting on a stale tab-switch timer.
            sidebarAwaitingContent = false
            setSidebarEnabled(false, reenableAfter: 0.8)
        }
    }

    /// Route an incoming `orivio://` / `stremio://` deep link.
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLinkService.parse(url) else { return }
        switch link {
        case .meta(let type, let id):
            // Open the title on the Home tab. DetailView fetches full meta +
            // canonicalizes tmdb→tt from this id.
            let meta = MetaItem(id: id, type: type, name: "")
            selectedTab = 0
            // Defer the push one runloop turn so it lands AFTER the tab switch
            // has rebuilt the Home NavigationStack. Mutating `selectedTab` and
            // the path in the same tick is the documented grey/ghost shape the
            // player cover's own deferral exists to avoid.
            DispatchQueue.main.async { homePath.append(Route.detail(meta)) }
        case .addonInstall(let manifestURL):
            requestAddonInstall(manifestURL)
        case .externalPlaybackFinished(let streamURL, let position):
            // The callback itself proves we are returning from the other app.
            // Clear the launch marker so the foreground handler can't fire the
            // same navigation a second time.
            _ = ExternalLaunchMarker.consume()
            returnToHomeFromExternalPlayback()
            finishExternalPlayback(streamURL: streamURL, position: position)
        case .externalPlaybackFailed(let message):
            // The stream never played over there, so drop the optimistic
            // Continue Watching row we wrote at handoff — it would otherwise
            // sit at 0% forever.
            if let first = ExternalPlaybackSession.pending?.items.first {
                progressStore.remove(id: ProgressStore.key(metaID: first.meta.id, video: first.video))
            }
            ExternalPlaybackSession.clear()
            _ = ExternalLaunchMarker.consume()
            returnToHomeFromExternalPlayback()
            NSLog("[OrivioPlayer] external player error: %@", message ?? "(none)")
        }
    }

    /// Step 1 of a deep-link add-on install: read the manifest so the prompt
    /// can NAME the add-on, then ask. Nothing is installed here — fetching a
    /// manifest is a plain read, and the viewer still has to say yes.
    private func requestAddonInstall(_ manifestURL: String) {
        guard !addonInstallInFlight, pendingAddonInstall == nil else { return }
        addonInstallInFlight = true
        Task { @MainActor in
            defer { addonInstallInFlight = false }
            let normalized = AddonManager.normalizeManifestURL(manifestURL)
            guard let manifest = try? await StremioAPI.manifest(url: normalized) else {
                // Previously this failure was swallowed entirely — the link
                // just did nothing and the viewer had no idea why.
                ToastCenter.shared.show("Couldn't read that add-on's manifest", icon: "exclamationmark.triangle")
                return
            }
            pendingAddonInstall = PendingAddonInstall(
                manifestURL: normalized,
                name: manifest.name.isEmpty ? normalized : manifest.name,
                isUpdate: addonManager.addons.contains { $0.manifestURL == normalized }
            )
        }
    }

    /// Step 2: the viewer pressed Install/Update. Success and failure are both
    /// reported — the old silent `try?` left either outcome invisible.
    private func confirmAddonInstall(_ pending: PendingAddonInstall) {
        pendingAddonInstall = nil
        Task { @MainActor in
            do {
                try await addonManager.install(manifestURL: pending.manifestURL)
                ToastCenter.shared.show(
                    pending.isUpdate ? "Updated \(pending.name)" : "Installed \(pending.name)",
                    icon: "checkmark.circle"
                )
            } catch {
                ToastCenter.shared.show("Couldn't install \(pending.name)", icon: "exclamationmark.triangle")
            }
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
        // A Plex / Jellyfin item plays again from its server; its id means
        // nothing to the add-ons the source picker would scrape.
        if MediaServerKind.kind(ofMetaID: progress.metaID) != nil {
            if let request = await MediaServerPlayback.resume(progress, store: mediaServers,
                                                              fromBeginning: fromBeginning) {
                startPlayback(request)
            } else {
                ToastCenter.shared.show("Couldn't reach the media server", icon: "exclamationmark.triangle")
            }
            return
        }
        let (meta, video) = await canonicalResumeIdentity(progress)
        // Resume ALWAYS re-scrapes a fresh link now: a remembered URL from a
        // debrid/Comet-style addon expires, so replaying it "fails to load" and
        // (with no failover alternates) drops you back to 0:00. Instead route to
        // the source picker, which auto-plays the link best matching what was
        // last watched, with the full list as failover. Start Over takes the
        // same matched-link path but plays from 0:00.
        homePath.append(Route.streamsResume(meta, video, fromStart: fromBeginning))
    }

    /// Continue Watching hold → "Play Manually". The manual source list, but
    /// through the SAME identity repair as a resume: this route used to push
    /// the raw stored row (Home built a MetaItem straight off it), so every id
    /// shape `resumeResolved` had learned to fix — `tmdb:` metaIDs, rows typed
    /// "tv", synced rows whose season/episode columns were dropped — reached
    /// the picker unrepaired and produced the same empty Sources page the
    /// automatic path was cured of.
    private func playManuallyFromProgress(_ progress: WatchProgress) {
        // A media-server row has no addon sources to pick between — play it
        // from its server exactly like a plain resume.
        if MediaServerKind.kind(ofMetaID: progress.metaID) != nil {
            resume(progress)
            return
        }
        Task { @MainActor in
            let (meta, video) = await canonicalResumeIdentity(progress)
            homePath.append(Route.streamsManual(meta, video))
        }
    }

    /// Whether a progress row is a series. Synced rows arrive typed "tv",
    /// "show" or "anime" as well as "series" — a bare `type != "series"` test
    /// sent every one of those down TMDB's MOVIE endpoint (disjoint id space →
    /// no tt id, or the wrong film's) and put the raw type into the addon
    /// stream path (`/stream/tv/…` → 404), which is why SOME shows resumed
    /// from Continue Watching found no sources while their Detail page — which
    /// tests `isSeries` properly — worked.
    private static func isSeriesProgressType(_ type: String) -> Bool {
        ["series", "tv", "show", "tvshow", "anime"].contains(type.lowercased())
    }

    /// The canonical (meta, video) identity for a stored Continue Watching
    /// row — shared by resume and the hold-menu's Play Manually. Repairs the
    /// id/type shapes sync sources leave behind, and migrates the stored row
    /// so the corrected key doesn't fork a duplicate card.
    @MainActor
    private func canonicalResumeIdentity(_ progress: WatchProgress) async -> (MetaItem, MetaVideo?) {
        let isSeries = Self.isSeriesProgressType(progress.type)

        // Recover a dropped season/episode from the progress KEY. Synced rows
        // can carry `season`/`episode` as nil while the key still spells them
        // ("tt123:2:5" — the backend sent video_id but not the columns). With
        // them nil the episode identity below collapsed to the bare show id,
        // and a show-level stream query returns nothing for a series.
        var season = progress.season
        var episode = progress.episode
        if isSeries, season == nil || episode == nil {
            let parts = progress.id.split(separator: ":")
            if parts.count >= 3,
               let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) {
                season = s
                episode = e
            }
        }

        var metaID = progress.metaID
        // TMDB-sourced ids can't be served by Cinemeta/Torrentio — resolve to
        // the IMDb tt id (DetailView does the same).
        if metaID.hasPrefix("tmdb:"), let n = Int(metaID.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !isSeries) {
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
        if metaID.hasPrefix("tt"), let season, let episode {
            episodeID = "\(metaID):\(season):\(episode)"
        } else if metaID != progress.metaID, !isSeries {
            // tmdb → tt movie (no episode): the id is just the movie id. A
            // series row must NOT take this collapse — with no recoverable
            // episode it would rewrite the stored key to the show id.
            episodeID = metaID
        }

        // Migrate the stored entry if the identity changed, so the corrected
        // key doesn't fork a duplicate Continue Watching card.
        if episodeID != progress.id || metaID != progress.metaID {
            progressStore.recanonicalize(oldID: progress.id, newID: episodeID, newMetaID: metaID)
        }

        let meta = MetaItem(
            id: metaID,
            // Normalised: the raw stored type goes verbatim into the addon
            // stream URL (`/stream/<type>/<id>.json`), and only "series" /
            // "movie" exist there.
            type: isSeries ? "series" : "movie",
            name: progress.name,
            poster: progress.poster,
            background: progress.background,
            logo: progress.logo
        )
        // Rebuild the episode identity so progress keeps saving under the
        // episode key instead of forking a second entry under the show.
        let video: MetaVideo? = season != nil || episode != nil
            ? MetaVideo(
                id: episodeID,
                title: progress.episodeTitle,
                season: season,
                episode: episode
            )
            : nil
        return (meta, video)
    }
}


// NOTE: intentionally NOT #if DEBUG — the call sites above are unconditional.
/// Dev: `-focusLog` logs every focus update and every FAILED move (the focus
/// engine found no candidate) app-wide. Sim key delivery is flaky and
/// screenshots only show styled focus, so this is the only reliable truth
/// about where focus actually is.
@MainActor
enum FocusTrace {
    private static var tokens: [NSObjectProtocol] = []
    static let enabled = ProcessInfo.processInfo.arguments.contains("-focusLog")

    static func installIfRequested() {
        guard tokens.isEmpty, enabled else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification,
                                         object: nil, queue: .main) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            NSLog("[FocusTrace] UPDATE %@ -> %@ (heading %ld)",
                  describe(ctx.previouslyFocusedItem), describe(ctx.nextFocusedItem),
                  ctx.focusHeading.rawValue)
        })
        tokens.append(center.addObserver(forName: UIFocusSystem.movementDidFailNotification,
                                         object: nil, queue: .main) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            NSLog("[FocusTrace] MOVE FAILED from %@ heading %ld",
                  describe(ctx.previouslyFocusedItem), ctx.focusHeading.rawValue)
        })
        NSLog("[FocusTrace] installed")
    }

    private static func describe(_ item: UIFocusItem?) -> String {
        guard let item else { return "NONE" }
        let cls = String(describing: type(of: item))
        // UIFocusItem.frame is in the item's own coordinate space; convert via
        // its container for a window-relative rectangle.
        var frame = item.frame
        if let view = item as? UIView, let win = view.window {
            frame = view.convert(view.bounds, to: win)
        } else if let container = item.parentFocusEnvironment as? UIView, let win = container.window {
            frame = container.convert(frame, to: win)
        }
        let parent = item.parentFocusEnvironment.map { String(describing: type(of: $0)) } ?? "-"
        return String(format: "%@ @(%.0f,%.0f %.0fx%.0f) in %@", cls, frame.minX, frame.minY, frame.width, frame.height, parent)
    }
}
// (end -focusLog tracer)
