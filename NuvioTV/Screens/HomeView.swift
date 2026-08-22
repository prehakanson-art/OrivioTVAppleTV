import SwiftUI

struct HomeRow: Identifiable {
    let id: String
    let title: String
    let items: [MetaItem]
    /// Source catalog, so the row can navigate to a paginated "See All".
    var addon: InstalledAddon?
    var catalog: ManifestCatalog?
}

private extension Sequence where Element == WatchedItem {
    func deduplicatedByContentID() -> [WatchedItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.contentID).inserted }
    }
}

/// A home screen row: either a catalog of posters or a collection of folders.
enum HomeEntry: Identifiable {
    case catalog(HomeRow)
    case collection(NuvioCollection)

    var id: String {
        switch self {
        case .catalog(let row): return row.id
        case .collection(let collection): return "collection|\(collection.id)"
        }
    }
}

/// Persists the last-rendered Home catalog rows (their items) to disk, keyed by
/// catalog key, so the screen paints instantly on a cold start and then
/// refreshes in the background (stale-while-revalidate).
enum HomeCatalogCache {
    private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("nuvio-home-catalogs.json")
    }()

    static func load() -> [String: [MetaItem]] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [MetaItem]].self, from: data) else { return [:] }
        return decoded
    }

    static func save(_ rows: [String: [MetaItem]]) {
        // Encode + write OFF the main thread. This is called from the @MainActor
        // Home load right after a refresh; encoding ~15 rows × 30 MetaItems and
        // writing the file synchronously there is a visible hitch on the A8 the
        // moment Home finishes loading. It's fire-and-forget persistence, so a
        // utility-queue hop costs the UI nothing.
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var entries: [HomeEntry] = []
    @Published var isLoading = false
    /// Current phase label for the first-run stepped loading backdrop
    /// (nil when not doing a cold, cache-less load).
    @Published var loadingStep: String?
    @Published var loadError: String?
    /// The default billboard title (first catalog item with art), computed on
    /// load. The LIVE hero — which changes as focus moves — lives in a separate
    /// `HeroFocus` object so its frequent animated updates only re-render the
    /// billboard, NOT the poster rows. That full re-render was cancelling the
    /// first long-press on a card right after moving to it.
    var initialHero: MetaItem?

    private var loadedFingerprint: [String] = []

    func loadIfNeeded(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore
    ) async {
        // Fingerprint includes catalog counts (so rows refresh when the live
        // manifests replace the bundled seed) plus the layout customization
        // state and collection list, so edits re-render immediately. viewMode +
        // pinToTop are included so changing a collection's Home layout or its
        // pin re-renders without a relaunch.
        var fingerprint = addonManager.catalogAddons.map {
            "\($0.id)#\(($0.manifest.catalogs ?? []).count)"
        }
        fingerprint.append(settings.orderKeys.joined(separator: ","))
        fingerprint.append(settings.disabledKeys.sorted().joined(separator: ","))
        fingerprint.append(settings.customTitles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        fingerprint.append("hideUnreleased=\(settings.hideUnreleasedContent)")
        fingerprint.append(collections.collections.map {
            "\($0.id)#\($0.folders.count)#\($0.title)#\($0.viewMode)#\($0.pinToTop)"
        }.joined(separator: ","))
        guard entries.isEmpty || fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        await load(addonManager: addonManager, collections: collections, settings: settings)
    }

    func load(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore
    ) async {
        isLoading = entries.isEmpty
        loadError = nil

        // Assemble the available rows keyed the same way the sync payload is,
        // then let the layout settings decide order and visibility.
        var catalogByKey: [String: (addon: InstalledAddon, catalog: ManifestCatalog)] = [:]
        var catalogKeys: [String] = []
        // Second-and-later installs of the SAME addon id get their own key
        // namespace, so two configured instances don't collide (see
        // AddonManager.catalogKeyNamespaces).
        let namespaces = addonManager.catalogKeyNamespaces
        for addon in addonManager.catalogAddons {
            // NO per-addon cap here. There used to be a `.prefix(6)`, which
            // silently disagreed with every other enumeration in the app:
            // Settings → Layout, Discover, the collection source picker and the
            // sync payload all list a catalog addon's FULL set. So an addon
            // declaring more than six usable catalogs (the TMDB addon has ten,
            // AIOLists-style configs have far more) showed rows in Layout that
            // could be renamed, reordered and toggled on — and then never
            // appeared on Home, because the key wasn't in `catalogByKey` and
            // the loop below quietly skips keys it can't resolve.
            // The row ceiling that actually protects the focus engine is
            // `AddonSweepLimits.maxHomeRows`, applied to the merged order a few
            // lines down — i.e. against the user's OWN ranking, so the cut is
            // the rows they placed last rather than an arbitrary six per addon.
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addon: addon, catalog: catalog, namespaces: namespaces
                )
                guard catalogByKey[key] == nil else { continue }
                catalogKeys.append(key)
                catalogByKey[key] = (addon, catalog)
            }
        }
        var collectionByKey: [String: NuvioCollection] = [:]
        var collectionKeys: [String] = []
        for collection in collections.collections {
            let key = HomeCatalogSettingsStore.collectionKey(collection.id)
            collectionKeys.append(key)
            collectionByKey[key] = collection
        }

        let mergedKeys = settings
            .mergedOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
            .filter { settings.isEnabled(key: $0) }
        // Pin to top: a collection flagged pinToTop jumps to the front of the
        // Home order (keeping relative order among pins), so it renders above
        // the catalogs instead of wherever the merged order placed it.
        let pinnedKeys = Set(collections.collections.filter(\.pinToTop)
            .map { HomeCatalogSettingsStore.collectionKey($0.id) })
        let prioritized = pinnedKeys.isEmpty ? mergedKeys
            : mergedKeys.filter { pinnedKeys.contains($0) } + mergedKeys.filter { !pinnedKeys.contains($0) }

        // Cap the number of CATALOG rows Home will build. Row layouts render
        // their rows eagerly (see rowsContent), so an account carrying 40+
        // addons — each declaring up to 6 catalogs — would materialize hundreds
        // of rows and fetch every one of them on a single load. That is the
        // "app dies after signing in with lots of addons" case: it isn't the
        // login, it's the Home load that follows it. Collections are exempt:
        // they're markers with no fetch, and the user explicitly created them.
        // The order is the user's own (Settings → Layout), so the cut is always
        // "the rows you ranked lowest", and everything remains reachable from
        // Discover.
        var catalogRowBudget = AddonSweepLimits.maxHomeRows
        let orderedKeys = prioritized.filter { key in
            guard catalogByKey[key] != nil else { return true }   // collections: always keep
            guard catalogRowBudget > 0 else { return false }
            catalogRowBudget -= 1
            return true
        }

        // STALE: on a cold start, paint the last-saved catalog items instantly
        // (paired with the live addon/catalog so "See All" still works), then
        // refresh below.
        if entries.isEmpty {
            // Read + JSON-decode the on-disk cache OFF the main thread — on the
            // A8 this blocked the very first frame (the loading backdrop) until
            // the file was parsed. Awaiting a detached read lets the backdrop
            // paint immediately, then the stale rows swap in when it returns.
            let cached = await Task.detached(priority: .userInitiated) {
                HomeCatalogCache.load()
            }.value
            var stale: [HomeEntry] = []
            for key in orderedKeys {
                if let collection = collectionByKey[key] {
                    // Collections are pure markers (buttons/tiles, no content
                    // fetch) in every view mode, so all paint instantly.
                    stale.append(.collection(collection))
                } else if let request = catalogByKey[key], let items = cached[key], !items.isEmpty {
                    // Dedup: a cache written before the source-side dedup
                    // shipped could still hold duplicate ids. Unreleased items
                    // are dropped here too — the cache may predate the setting
                    // (or the title's release date may have passed since).
                    var staleItems = items.deduplicatedByID()
                    if settings.hideUnreleasedContent {
                        staleItems = staleItems.filter { !$0.isUnreleased }
                    }
                    guard !staleItems.isEmpty else { continue }
                    stale.append(.catalog(HomeRow(
                        id: Self.rowID(request),
                        title: Self.rowTitle(key: key, request: request, settings: settings),
                        items: staleItems, addon: request.addon, catalog: request.catalog
                    )))
                }
            }
            if !stale.isEmpty {
                entries = stale
                if initialHero == nil { initialHero = Self.firstHero(stale) }
            }
        }

        // The stepped backdrop only shows when there's genuinely nothing on
        // screen (true first run). Warm starts render from cache instantly.
        isLoading = entries.isEmpty
        if isLoading {
            // No artificial pause — go straight to fetching so the first-run
            // load is as fast as the network allows.
            loadingStep = "Loading catalogs…"
        }

        // REVALIDATE: fetch the catalogs, a bounded number at a time.
        // Collections are just markers here — Home shows them as buttons/tiles;
        // their catalog content is resolved on demand when the user opens a
        // folder/collection's discover page, so Home never eagerly fetches
        // collection content.
        var fetched: [(index: Int, key: String?, entry: HomeEntry)] = []
        // The catalog rows still to fetch, paired with their slot in
        // orderedKeys. Titles and row ids are resolved HERE, on the main actor,
        // so the fetch loop below needs no isolated state of its own.
        var pending: [(index: Int, key: String, title: String, rowID: String,
                       request: (addon: InstalledAddon, catalog: ManifestCatalog))] = []
        for (index, key) in orderedKeys.enumerated() {
            if let collection = collectionByKey[key] {
                fetched.append((index, nil, .collection(collection)))
            } else if let request = catalogByKey[key] {
                pending.append((
                    index, key,
                    Self.rowTitle(key: key, request: request, settings: settings),
                    Self.rowID(request),
                    request
                ))
            }
        }
        if !fetched.isEmpty { entries = fetched.sorted { $0.index < $1.index }.map(\.entry) }

        await withTaskGroup(of: (Int, String, HomeEntry?).self) { group in
            // Keep at most `catalogs` requests outstanding. Unbounded, a large
            // install fired one request per row simultaneously and held every
            // decoded response at once — the peak that killed the app.
            let window = max(1, min(AddonSweepLimits.catalogs, pending.count))
            var next = 0
            // Read once here, not inside the task: `settings` is main-actor state.
            let hideUnreleased = settings.hideUnreleasedContent
            func startNext() {
                guard next < pending.count else { return }
                let (index, key, title, rowID, request) = pending[next]
                next += 1
                group.addTask {
                    var items = (try? await StremioAPI.catalog(addon: request.addon, catalog: request.catalog)) ?? []
                    // "Hide unreleased content" (Settings → Layout). Filtered
                    // BEFORE the 30-item trim so a row full of upcoming titles
                    // still fills up with things you can actually watch.
                    if hideUnreleased { items = items.filter { !$0.isUnreleased } }
                    guard !items.isEmpty else { return (index, key, nil) }
                    let row = HomeRow(
                        id: rowID,
                        title: title,
                        items: Array(items.prefix(30)),
                        addon: request.addon,
                        catalog: request.catalog
                    )
                    return (index, key, .catalog(row))
                }
            }
            for _ in 0..<window { startNext() }

            // Reveal rows AS SOURCES RESPOND so a slow aggregator doesn't hold
            // up the whole screen — but coalesce the republishes. Re-sorting and
            // reassigning `entries` on every single completion made SwiftUI
            // rebuild the entire (eagerly-built) row stack once per row; with
            // many rows that is quadratic work on the main actor. Same throttle
            // the Sources sweep uses.
            var lastFlush = Date.distantPast
            for await (index, key, entry) in group {
                startNext()
                guard let entry else { continue }
                fetched.append((index: index, key: String?.some(key), entry: entry))
                if Date().timeIntervalSince(lastFlush) > 0.4 {
                    entries = fetched.sorted { $0.index < $1.index }.map(\.entry)
                    lastFlush = Date()
                }
            }
            entries = fetched.sorted { $0.index < $1.index }.map(\.entry)
        }

        if isLoading { loadingStep = "Loading artwork…" }

        let ordered = fetched.sorted { $0.index < $1.index }
        let freshEntries = ordered.map(\.entry)
        // Keep stale rows on screen if the refresh came back empty (offline).
        if !freshEntries.isEmpty { entries = freshEntries }

        // Persist fresh catalog items for the next cold start. Only real
        // add-on catalog rows (whose key maps back to a live catalog) are
        // cached; collection-derived rows re-resolve on next launch.
        var toCache: [String: [MetaItem]] = [:]
        for row in ordered {
            if let key = row.key, catalogByKey[key] != nil, case .catalog(let r) = row.entry {
                toCache[key] = r.items
            }
        }
        if !toCache.isEmpty { HomeCatalogCache.save(toCache) }

        if initialHero == nil { initialHero = Self.firstHero(entries) }
        if entries.isEmpty {
            loadError = "No catalogs available. Check your addons and network connection."
        }
        isLoading = false
        loadingStep = nil

        // Warm the poster cache for the below-the-fold rows so scrolling down
        // hits disk, not the network. First rows render on their own.
        let prefetchURLs = entries.dropFirst(2).flatMap { entry -> [String] in
            guard case .catalog(let row) = entry else { return [] }
            return row.items.prefix(12).compactMap(\.poster)
        }
        if !prefetchURLs.isEmpty, PerformanceSettingsStore.shared.settings.artworkPrefetch {
            ImageCache.shared.prefetch(urls: Array(prefetchURLs))
        }
    }

    // MARK: Row builders (shared between the cache-paint and live-fetch paths)

    static func rowID(_ request: (addon: InstalledAddon, catalog: ManifestCatalog)) -> String {
        "\(request.addon.id)|\(request.catalog.type)|\(request.catalog.id)"
    }

    static func rowTitle(
        key: String,
        request: (addon: InstalledAddon, catalog: ManifestCatalog),
        settings: HomeCatalogSettingsStore
    ) -> String {
        // APK row header format: "{Catalog Name} - {Type}" (e.g. "Trending Movies - Movie").
        let typeLabel: String
        switch request.catalog.type {
        case "series", "tv": typeLabel = "Series"
        case "movie": typeLabel = "Movie"
        default: typeLabel = request.catalog.type.capitalized
        }
        let baseName = request.catalog.name ?? request.catalog.id.capitalized
        if let custom = settings.customTitle(for: key) { return custom }
        var title = baseName
        if settings.catalogAddonNameEnabled { title += " · \(request.addon.manifest.name)" }
        if settings.catalogTypeSuffixEnabled { title += " - \(typeLabel)" }
        return title
    }

    static func firstHero(_ entries: [HomeEntry]) -> MetaItem? {
        let firstCatalog = entries.lazy.compactMap { entry -> HomeRow? in
            if case .catalog(let row) = entry { return row }
            return nil
        }.first
        return firstCatalog?.items.first { $0.background != nil } ?? firstCatalog?.items.first
    }

    /// The top titles for the Apple TV hero's spotlight rotation: the first
    /// catalog row's items that actually have backdrop art (a hero with no
    /// backdrop is a dead frame), capped at `max`.
    func spotlightItems(max: Int) -> [MetaItem] {
        let firstCatalog = entries.lazy.compactMap { entry -> HomeRow? in
            if case .catalog(let row) = entry { return row }
            return nil
        }.first
        let items = (firstCatalog?.items ?? []).filter { $0.background != nil }
        return Array(items.prefix(max))
    }

    /// Titles for the inline Fusion hero bar. Sourced from the SECOND catalog
    /// row (falling back to the first) so the bar doesn't echo the top
    /// spotlight, which rotates the first row.
    func heroBarItems(max: Int) -> [MetaItem] {
        let catalogs = entries.compactMap { entry -> HomeRow? in
            if case .catalog(let row) = entry { return row }
            return nil
        }
        let source = catalogs.count > 1 ? catalogs[1] : catalogs.first
        let items = (source?.items ?? []).filter { $0.background != nil }
        return Array(items.prefix(max))
    }
}

/// The live billboard title, updated as focus moves across cards. Kept separate
/// from HomeViewModel and owned by HomeView WITHOUT observation, so its frequent
/// animated changes re-render only the billboard subviews — not the poster rows.
@MainActor
final class HeroFocus: ObservableObject {
    @Published var item: MetaItem?
    /// Fetches full metadata for a bare item (Continue Watching rows only
    /// store name + art) — set by HomeView. Successful results are cached.
    var enrich: ((MetaItem) async -> MetaItem?)?
    private var task: Task<Void, Never>?

    // MARK: Spotlight rotation (Apple TV theme)
    /// The top titles the hero auto-cycles through when idle. Empty disables
    /// rotation (Classic keeps the pure focus-follow behavior).
    var spotlight: [MetaItem] = []
    /// Position within `spotlight` — published (read-only outside this class)
    /// so the Fusion spotlight can render pagination dots (§20.5).
    @Published private(set) var spotlightIndex = 0
    /// Last time the user drove the hero (focused a card / touched the hero),
    /// so rotation pauses while browsing and resumes once idle.
    private var lastInteraction = Date.distantPast
    /// When the spotlight last advanced, so each title stays up for a readable
    /// dwell instead of flipping on every timer tick.
    private var lastRotation = Date.distantPast
    /// Seconds each spotlight title stays on screen before the next.
    private let dwellSeconds: TimeInterval = 9
    /// True while the hero's own Play button holds focus — rotation stays
    /// frozen so the title can't change out from under a press.
    var heroButtonFocused = false

    /// Seed the rotation set and show its first title. Safe to call repeatedly;
    /// only re-seeds when the set actually changed.
    func setSpotlight(_ items: [MetaItem]) {
        guard items.map(\.id) != spotlight.map(\.id) else { return }
        spotlight = items
        spotlightIndex = 0
        if item == nil, let first = items.first { item = first }
    }

    /// Record a user interaction so the timer holds off for a beat.
    func markInteraction() { lastInteraction = Date() }

    /// Manual prev/next through the spotlight (Left/Right on the hero). Wraps,
    /// pauses auto-rotation, and shows the chosen title immediately.
    func stepSpotlight(by delta: Int) {
        guard spotlight.count > 1 else { return }
        lastInteraction = Date()
        lastRotation = Date()
        spotlightIndex = (spotlightIndex + delta + spotlight.count) % spotlight.count
        let next = spotlight[spotlightIndex]
        let fade = PerformanceSettingsStore.shared.heroCrossfadeEffective
        withAnimation(fade ? .easeInOut(duration: 0.4) : nil) { item = next }
    }

    /// Timer tick: advance to the next spotlight title, but only if the user
    /// hasn't touched anything for a few seconds (so it never yanks the hero
    /// out from under someone browsing).
    func rotateIfIdle() {
        let now = Date()
        guard spotlight.count > 1, !heroButtonFocused,
              now.timeIntervalSince(lastInteraction) > 6,
              now.timeIntervalSince(lastRotation) >= dwellSeconds else { return }
        lastRotation = now
        spotlightIndex = (spotlightIndex + 1) % spotlight.count
        let next = spotlight[spotlightIndex]
        let fade = PerformanceSettingsStore.shared.heroCrossfadeEffective
        withAnimation(fade ? .easeInOut(duration: 0.7) : nil) { item = next }
    }
    /// The id the debounce is ABOUT to commit. Guarding only against the
    /// COMMITTED item had a race: moving X→Y→X inside the debounce window
    /// passed the guard (item still X) without cancelling the pending Y, so Y
    /// landed while focus sat on X — the "wrong hero" flash.
    private var pendingID: String?
    private var enriched: [String: MetaItem] = [:]

    /// Debounced so fast scrolling through a row doesn't thrash the backdrop,
    /// animated for a smooth crossfade.
    ///
    /// The settle window is tier-aware. Committing the hero means decoding a
    /// full-screen backdrop (~1920px on the HD) and compositing it edge to
    /// edge — at 60ms nearly every D-pad step through a row commits, so on the
    /// A8 the CPU spends the whole browse decoding backdrops it immediately
    /// replaces (the core "stepping through a row stutters" cost on that box).
    /// 220ms means a steady step-step-step never commits; the hero lands the
    /// moment you rest, which is when anyone actually looks at it. The 3 GB
    /// 4K gen 1 decodes up-to-3840px backdrops (~33 MB each), so it gets a
    /// middle window: fast enough to feel live, long enough that a steady
    /// scrub skips most intermediate commits.
    private var settleNanos: UInt64 {
        if PerformanceProfile.isLowPower { return 220_000_000 }
        if PerformanceProfile.isMidPower { return 120_000_000 }
        return 60_000_000
    }

    func focus(_ newItem: MetaItem) {
        // Browsing cards counts as interaction — pause spotlight rotation.
        lastInteraction = Date()
        guard newItem.id != (pendingID ?? item?.id) else { return }
        task?.cancel()
        pendingID = newItem.id
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: settleNanos)   // let focus settle
            guard !Task.isCancelled else { return }
            let display = enriched[newItem.id] ?? newItem
            let fade = PerformanceSettingsStore.shared.heroCrossfadeEffective
            withAnimation(fade ? .easeInOut(duration: 0.4) : nil) { item = display }
            pendingID = nil
            // Bare item (no synopsis): fetch the full meta so the billboard
            // shows description/genres/rating, and swap it in if still current.
            guard display.description == nil, let enrich else { return }
            guard let full = await enrich(display), !Task.isCancelled,
                  self.item?.id == display.id else { return }
            enriched[display.id] = full
            withAnimation(fade ? .easeInOut(duration: 0.25) : nil) { self.item = full }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    // Owned by RootView so it PERSISTS across tab switches. If it were a local
    // @StateObject, switching away and back would rebuild HomeView with a fresh
    // (empty) model → a "Loading catalogs" spinner with no focusable element →
    // focus falls back to the sidebar, which reopened the panel.
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject private var perf = PerformanceSettingsStore.shared

    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    var onResumeFromStart: (WatchProgress) -> Void = { _ in }
    /// Opens the source list (StreamsView) so the user picks a stream manually.
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    let onOpenCollection: (NuvioCollection) -> Void
    var onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void = { _, _, _ in }
    /// Fires when the first load attempt finishes (success or error), so the
    /// root can re-enable the sidebar only once content exists to hold focus.
    var onContentReady: () -> Void = {}
    /// Called when Back is pressed at the START of a row (or on the hero/other
    /// non-row content): opens the sidebar (Classic) or focuses the tab bar
    /// (Fusion). Passed from RootView.
    var onHomeBack: () -> Void = {}

    private var layout: HomeLayout { homeCatalogSettings.homeLayout }

    /// The big title/logo/synopsis hero panel is a MODERN-only affordance.
    /// Classic keeps the focus-following backdrop but drops the panel (that's
    /// the whole point of Classic — a lighter, rows-first home), and Grid has
    /// no billboard at all.
    private var showsHeroPanel: Bool { layout == .modern }

    /// Whether the hero backdrop/billboard tracks the focused card. Classic
    /// does (Netflix-style). Fusion deliberately does NOT — its spotlight stays
    /// pinned on its rotating Top-10 title as you browse down, per the design.
    /// Grid never drives the hero either way.
    private var heroFollowsFocus: Bool { layout != .grid && !theme.isAppleTVTheme && !theme.isStremioTheme }

    /// How far the row scroll starts below the top. Modern reserves room for the
    /// hero panel; Classic shows just a sliver of backdrop; Grid starts flush.
    private var rowsTopInset: CGFloat {
        switch layout {
        case .grid: return 0
        // 130 left the rows viewport barely taller than a single poster row,
        // so the focus engine's minimal scroll landed rows with their header
        // ("See All") sliced off at the clip line, and the previous row's
        // caption letters peeking. 60 reclaims ~70pt so a full row + its
        // header always fit below the billboard.
        case .modern: return 60
        // Fusion's Classic layout uses the taller 300pt backdrop sliver
        // (§22.1), so rows need more clearance than Classic theme's original
        // thin strip — the sliver's title sits near its bottom edge, so give
        // a real gap below the full 300pt band.
        case .classic: return theme.isAppleTVTheme ? 340 : 60
        }
    }

    // Owned via @State (NOT @StateObject) so HomeView does NOT observe it —
    // hero changes must re-render only the billboard subviews, never the rows.
    @State private var hero = HeroFocus()
    @State private var nextUpContinueItems: [WatchProgress] = []

    /// Drives the Apple TV hero's spotlight rotation. Ticks every 2s; the hero
    /// only advances when it's been idle for a few seconds (see rotateIfIdle).
    private let spotlightTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// False while Home is covered (player fullScreenCover, pushed screen,
    /// other tab). Home stays mounted in those states, so without this gate the
    /// spotlight kept rotating unseen — decoding a full-screen backdrop every
    /// 9s DURING playback, real decode/memory contention on the 2–3 GB boxes.
    @State private var isVisible = true

    var body: some View {
        layoutContent
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(spotlightTick) { _ in
            // §55: Reduce Motion disables automatic hero rotation.
            if isVisible && theme.isAppleTVTheme && !perf.reduceMotion {
                hero.rotateIfIdle()
            }
        }
        .task {
            // Continue Watching rows only persist name/art — this fetches the
            // full meta (synopsis/genres/rating) for the billboard on demand.
            hero.enrich = { [weak addonManager] bare in
                guard let addonManager,
                      let addon = addonManager.metaAddon(for: bare.type, id: bare.id),
                      let full = try? await StremioAPI.meta(addon: addon, type: bare.type, id: bare.id)
                else { return nil }
                // Keep the art the progress row already had when the meta
                // addon returns none (hero backdrop must never go blank).
                return MetaItem(
                    id: full.id, type: full.type, name: full.name,
                    poster: full.poster ?? bare.poster,
                    background: full.background ?? bare.background,
                    logo: full.logo ?? bare.logo,
                    description: full.description, releaseInfo: full.releaseInfo,
                    imdbRating: full.imdbRating, runtime: full.runtime,
                    genres: full.genres, cast: full.cast, videos: full.videos
                )
            }
            await reload()
        }
        // Periodic catalog auto-refresh (Settings → Content & Discovery).
        // Restarts whenever the cadence changes; 0 = off. Uses the FORCED
        // load (not loadIfNeeded — the fingerprint wouldn't have changed) so
        // new releases appear without relaunching.
        .task(id: homeCatalogSettings.autoRefreshMinutes) {
            let minutes = homeCatalogSettings.autoRefreshMinutes
            guard minutes > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.load(
                    addonManager: addonManager,
                    collections: collections,
                    settings: homeCatalogSettings
                )
            }
        }
        .onChange(of: addonManager.addons) { _, _ in Task { await reload() } }
        .onChange(of: collections.collections) { _, _ in Task { await reload() } }
        .onChange(of: homeCatalogSettings.orderKeys) { _, _ in Task { await reload() } }
        .onChange(of: homeCatalogSettings.disabledKeys) { _, _ in Task { await reload() } }
        .onChange(of: homeCatalogSettings.customTitles) { _, _ in Task { await reload() } }
        .task(id: nextUpRefreshKey) { await refreshNextUpContinueItems() }
    }

    @ViewBuilder
    private var layoutContent: some View {
        // Fusion Modern: the hero is the FIRST item of one big vertical scroll,
        // so it scrolls UP and off as you move down (like the TV app), instead
        // of staying pinned. Every other case keeps the pinned billboard.
        if theme.isAppleTVTheme && layout == .modern {
            fusionModernLayout
        } else {
            pinnedLayout
        }
    }

    private var pinnedLayout: some View {
        ZStack(alignment: .top) {
            theme.palette.background.ignoresSafeArea()
            if perf.settings.heroBackdrop {
                // Fusion's Classic layout gets the shallow §22.1 sliver instead
                // of the full-bleed backdrop. Grid never shows one.
                if theme.isAppleTVTheme && layout == .classic {
                    ATVClassicHeroSliver(hero: hero)
                } else if layout != .grid {
                    HeroBackdropView(hero: hero)
                }
            }
            // The billboard is PINNED at the top; only the rows scroll beneath.
            VStack(alignment: .leading, spacing: 0) {
                if showsHeroPanel {
                    HeroInfoView(hero: hero)
                        .padding(.top, 56)
                        .padding(.leading, NuvioSpacing.huge)
                        .zIndex(1)
                }
                rowsScroll
            }
        }
    }

    private var fusionModernLayout: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                    if perf.settings.heroBackdrop {
                        FusionHeroHeader(hero: hero, onPlay: { onSelect($0) })
                            // Group the hero as its own focus section so a vertical
                            // UP from ANY card in the row below reaches it.
                            .focusSection()
                    }
                    rowsContent
                        // Rows keep a title-safe inset; the hero (above) does not,
                        // so its art can bleed to the very edges.
                        .padding(.horizontal, NuvioSpacing.lg)
                }
                .padding(.bottom, NuvioSpacing.huge)
            }
            // The whole scroll ignores the safe area so the hero backdrop fills
            // edge to edge (like the Detail page); rows re-inset themselves above.
            .ignoresSafeArea(edges: [.top, .horizontal])
            .scrollClipDisabled()
        }
    }

    private func reload() async {
        // Let the root enable focus/sidebar input after the first frame instead
        // of waiting for every Home catalog request to finish. Slow or broken
        // add-ons should leave Home loading, not make the whole app feel frozen.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            onContentReady()
        }

        await viewModel.loadIfNeeded(
            addonManager: addonManager,
            collections: collections,
            settings: homeCatalogSettings
        )
        if hero.item == nil { hero.item = viewModel.initialHero }
        // Apple TV theme: seed the auto-rotating spotlight with the top titles
        // (first catalog row's items that have backdrop art), so the hero
        // oscillates through them when idle.
        if theme.isAppleTVTheme {
            hero.setSpotlight(viewModel.spotlightItems(max: 10))
        }
        onContentReady()
    }

    @ViewBuilder
    private var rowsContent: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            HomeLoadingBackdrop(step: viewModel.loadingStep)
                .frame(maxWidth: .infinity)
                .frame(height: 460)
        } else if let error = viewModel.loadError, viewModel.entries.isEmpty {
            VStack(spacing: NuvioSpacing.lg) {
                NuvioEmptyState(icon: "antenna.radiowaves.left.and.right.slash", title: "Nothing to show", message: error)
                Button {
                    Task { await reload() }
                } label: {
                    RetryLabel()
                }
                .buttonStyle(PlainCardButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 460)
        } else {
            rowsList
        }
    }

    private var rowsScroll: some View {
        ScrollView(.vertical) {
            // Grid stacks many tall poster grids; a LazyVStack keeps off-screen
            // catalogs from all rendering at once (the source of the grid lag).
            // Row layouts keep the eager VStack (its LazyHStack children stay
            // lazy) so vertical focus moves never wait on row creation.
            Group {
                if layout == .grid {
                    LazyVStack(alignment: .leading, spacing: NuvioSpacing.xl) { rowsContent }
                } else {
                    VStack(alignment: .leading, spacing: NuvioSpacing.xl) { rowsContent }
                }
            }
            .padding(.top, layout == .grid ? 40 : NuvioSpacing.md)
            .padding(.bottom, NuvioSpacing.huge)
        }
        // Vertically CLIPPED on purpose (no scrollClipDisabled): rows scrolled
        // up past the viewport are hard-cut below the billboard, so they can
        // never render over the background art. Scrolling is fully native —
        // the old scrollPosition pin (forcing the focused row to the top slot)
        // double-drove the scroll against the focus engine and made every row
        // change a whole-content jump; the focus engine alone is smooth.
        .padding(.top, rowsTopInset)
    }

    @ViewBuilder
    private var rowsList: some View {
        let continueItems = mergedContinueItems()
        if !continueItems.isEmpty {
            continueRow(continueItems)
        }

        // Fusion (§21): an inline hero bar between Continue Watching and the
        // catalog rows, sourced from a different row than the top spotlight.
        if theme.isAppleTVTheme && layout == .modern && perf.settings.heroBackdrop {
            let barItems = viewModel.heroBarItems(max: 6)
            if barItems.count >= 2 {
                FusionHeroBar(
                    items: barItems,
                    eyebrow: "Featured",
                    // "Go to Movie" opens the title's Detail page (not the source
                    // list) — matches the reference and the spotlight button.
                    onPlay: { onSelect($0) },
                    onDetails: { onSelect($0) }
                )
                .focusSection()
            }
        }

        // Collections render by viewMode:
        // • ROWS      → each collection is its OWN row of folder buttons; a
        //               folder button opens that folder's discover page.
        // • FOLDERS/COMBINED → all share ONE "Collections" row of collection
        //               buttons (rendered at the first such collection's slot);
        //               a button opens that whole collection's discover/browse.
        let sharedCollections = viewModel.entries.compactMap { entry -> NuvioCollection? in
            if case .collection(let c) = entry, c.viewMode != "ROWS" { return c } else { return nil }
        }
        let firstSharedID = sharedCollections.first?.id

        ForEach(viewModel.entries) { entry in
            switch entry {
            case .catalog:
                rowEntry(entry)
            case .collection(let collection):
                if collection.viewMode == "ROWS" {
                    let key = HomeCatalogSettingsStore.collectionKey(collection.id)
                    CollectionRowSection(
                        collection: collection,
                        title: homeCatalogSettings.customTitle(for: key) ?? collection.title,
                        onOpenFolder: { openFolder($0, in: collection) },
                        onOpenCollection: { onOpenCollection(collection) },
                        onFolderFocus: { folder in
                            if heroFollowsFocus { hero.focus(heroItem(for: folder, in: collection)) }
                        },
                        onBackAtStart: onHomeBack
                    )
                } else if collection.id == firstSharedID {
                    CollectionsRowSection(
                        collections: sharedCollections,
                        onOpen: onOpenCollection,
                        onFocus: { if heroFollowsFocus { hero.focus(heroItem(for: $0)) } },
                        onBackAtStart: onHomeBack
                    )
                }
            }
        }
    }

    /// Open one folder's discover page: a browse view scoped to just that
    /// folder (its content + Sort, no tabs), reusing the collection browser
    /// with a synthetic single-folder collection.
    private func openFolder(_ folder: NuvioCollectionFolder, in collection: NuvioCollection) {
        let single = NuvioCollection(
            id: "folder:\(collection.id):\(folder.id)",
            title: folder.title,
            folders: [folder]
        )
        onOpenCollection(single)
    }

    /// A collection has no "meta" of its own, so build a lightweight stand-in
    /// for the shared hero panel. `background` feeds `HeroBackdropView`, which
    /// renders full-bleed at RemoteImage's default `.fill` (crop-to-cover) —
    /// exactly right for a wide backdrop PHOTO, but a small brand logo blown up
    /// that way just shows a zoomed-in, unrecognizable crop of the mark. So
    /// `background` is ONLY set when the collection has a genuine backdrop
    /// photo; the logo goes ONLY into `logo`, which HeroInfoView already
    /// renders correctly-contained (`.fit`, bounded 460×150 frame — no zoom).
    /// `description` is set to "" (not nil) so HeroFocus doesn't try to enrich
    /// a synthetic id.
    private func heroItem(for collection: NuvioCollection) -> MetaItem {
        let firstFolder = collection.folders.first
        let realBackdrop = collection.backdropImageUrl?.isEmpty == false ? collection.backdropImageUrl : nil
        return MetaItem(
            id: "collection:\(collection.id)",
            type: "collection",
            name: collection.title,
            background: realBackdrop,
            logo: TMDBService.originalSize(firstFolder?.coverImageUrl),
            description: ""
        )
    }

    /// Hero stand-in for ONE focused folder (category): its own backdrop if it
    /// has one, and its brand logo (full-res) shown WHOLE by the hero — so the
    /// billboard changes per category and the logo never renders zoomed/cropped.
    private func heroItem(for folder: NuvioCollectionFolder, in collection: NuvioCollection) -> MetaItem {
        let backdrop = folder.heroBackdropUrl?.isEmpty == false ? folder.heroBackdropUrl
            : (collection.backdropImageUrl?.isEmpty == false ? collection.backdropImageUrl : nil)
        return MetaItem(
            id: "collection:\(collection.id):\(folder.id)",
            type: "collection",
            name: folder.title,
            background: backdrop,
            logo: TMDBService.originalSize(folder.coverImageUrl),
            description: ""
        )
    }

    /// Only catalog rows go through here; collection rows are handled directly
    /// in `rowsList` (they render by viewMode).
    @ViewBuilder
    private func rowEntry(_ entry: HomeEntry) -> some View {
        if case .catalog(let row) = entry {
            if layout == .grid {
                posterGrid(row)
            } else {
                horizontalRow(row)
            }
        }
    }

    private func continueRow(_ items: [WatchProgress]) -> some View {
        ContinueWatchingRow(
            items: items,
            hero: hero,
            drivesHero: heroFollowsFocus,
            imageFor: continueImage,
            subtitleFor: continueSubtitle,
            blurFor: { [blur = homeCatalogSettings.blurContinueWatchingNextUp] progress in
                blur && progress.fraction < 0.02
            },
            heroItemFor: heroItem(from:),
            onResume: onResume,
            onDetails: { onSelect(heroItem(from: $0)) },
            onPlayManuallyMenu: { onPlayManually(heroItem(from: $0), metaVideo(from: $0)) },
            onResumeFromStartMenu: { onResumeFromStart($0) },
            onBackAtStart: onHomeBack
        )
    }

    private var nextUpRefreshKey: String {
        let watchedKey = watched.items.keys.sorted().joined(separator: "|")
        let progressKey = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
            .map(\.id)
            .sorted()
            .joined(separator: "|")
        return "\(watchedKey)#\(progressKey)#\(homeCatalogSettings.showUnairedNextUp)"
    }

    private func mergedContinueItems() -> [WatchProgress] {
        let active = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
        let activeMetaIDs = Set(active.map(\.metaID))
        let additions = nextUpContinueItems.filter { !activeMetaIDs.contains($0.metaID) }
        return active + additions
    }

    private func refreshNextUpContinueItems() async {
        let activeMetaIDs = Set(progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode).map(\.metaID))
        let watchedSeries = watched.items.values
            .filter { ($0.contentType == "series" || $0.contentType == "tv") && $0.season != nil && $0.episode != nil }
            .sorted { $0.watchedAt > $1.watchedAt }
            .deduplicatedByContentID()
            .filter { !activeMetaIDs.contains($0.contentID) }
            .prefix(20)

        var rows: [WatchProgress] = []
        for item in watchedSeries {
            guard let addon = addonManager.metaAddon(for: item.contentType, id: item.contentID),
                  let meta = try? await StremioAPI.meta(addon: addon, type: item.contentType, id: item.contentID),
                  let next = nextUpEpisode(in: meta) else { continue }
            rows.append(nextUpProgress(meta: meta, episode: next, lastWatchedAt: item.watchedAt))
        }
        if !Task.isCancelled {
            nextUpContinueItems = rows
        }
    }

    private func nextUpEpisode(in meta: MetaItem) -> MetaVideo? {
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return nil }

        func isWatched(_ episode: MetaVideo) -> Bool {
            watched.isWatched(contentID: meta.id, season: episode.season ?? 0, episode: episode.episode)
        }

        if homeCatalogSettings.nextUpFromFurthestEpisode,
           let furthestIndex = all.lastIndex(where: isWatched),
           furthestIndex + 1 < all.endIndex {
            return all[(furthestIndex + 1)...].first
        }

        return all.first { !isWatched($0) }
    }

    private func nextUpProgress(meta: MetaItem, episode: MetaVideo, lastWatchedAt: Date) -> WatchProgress {
        WatchProgress(
            id: episode.id,
            metaID: meta.id,
            type: meta.type,
            name: meta.name,
            poster: meta.poster,
            background: meta.background,
            logo: meta.logo,
            season: episode.season,
            episode: episode.episode,
            episodeTitle: episode.title,
            episodeThumbnail: episode.thumbnail,
            positionSeconds: 0,
            durationSeconds: 1,
            streamURL: nil,
            updatedAt: lastWatchedAt,
            hasNewEpisode: episode.hasAired
        )
    }

    // MARK: Rows

    /// Row header with a focusable "See All" affordance when the catalog can
    /// be paginated.
    @ViewBuilder
    private func catalogHeader(_ row: HomeRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            RowHeader(title: row.title)
            if let addon = row.addon, let catalog = row.catalog {
                Spacer()
                Button {
                    onSeeAll(addon, catalog, row.title)
                } label: {
                    SeeAllLabel()
                }
                .buttonStyle(PlainCardButtonStyle())
                .padding(.trailing, NuvioSpacing.huge)
            }
        }
    }

    /// Modern view can show landscape cards instead of portrait posters (APK's
    /// "Landscape Posters" toggle).
    private var useLandscape: Bool {
        layout == .modern && homeCatalogSettings.landscapePosters
    }

    // Thin wrapper — the row lives in its own view (HomePosterRow) so it can
    // own local @FocusState for the Back-to-start-of-row behavior without
    // re-rendering all of Home on every focus move.
    private func horizontalRow(_ row: HomeRow) -> some View {
        HomePosterRow(
            row: row,
            useLandscape: useLandscape,
            heroFollowsFocus: heroFollowsFocus,
            hero: hero,
            onSelect: onSelect,
            onPlayManually: onPlayManually,
            onSeeAll: onSeeAll,
            onBackAtStart: onHomeBack
        )
    }

    private func posterGrid(_ row: HomeRow) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            catalogHeader(row)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: homeCatalogSettings.posterSize.posterWidth,
                                             maximum: homeCatalogSettings.posterSize.posterWidth),
                                   spacing: NuvioSpacing.lg, alignment: .top)],
                alignment: .leading,
                spacing: NuvioSpacing.xl
            ) {
                ForEach(row.items) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            onSelect(item)
                        } label: {
                            // Grid shows no billboard, so we deliberately do NOT
                            // drive the hero here — that per-focus enrich fetch was
                            // firing a network request on every D-pad move and is
                            // what made grid navigation lag.
                            PosterCard(item: item)
                        }
                        .mediaCardButtonStyle()
                        .posterHoldMenu(item) { onSelect(item) }
                        // ⏯ parity with the horizontal rows: skip Detail, go
                        // straight to the source picker.
                        .onPlayPauseCommand { onPlayManually(item, nil) }

                        if theme.isAppleTVTheme {
                            ATVCardCaption(
                                title: item.name,
                                subtitle: item.year,
                                width: homeCatalogSettings.posterSize.posterWidth
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, NuvioSpacing.huge)
            .padding(.vertical, NuvioSpacing.md)
            // No .focusSection() — a LazyVGrid already preserves the column on
            // vertical moves, and the section wrapper made cross-grid moves
            // re-home to a center poster ("focus goes to the middle").
        }
    }

    /// Rebuilds the episode identity from a progress entry (same shape the
    /// root's resume() builds) so manual playback keeps saving under the
    /// episode key instead of forking a new entry under the show.
    private func metaVideo(from progress: WatchProgress) -> MetaVideo? {
        guard progress.season != nil || progress.episode != nil else { return nil }
        return MetaVideo(
            id: progress.id,
            title: progress.episodeTitle,
            season: progress.season,
            episode: progress.episode,
            thumbnail: progress.episodeThumbnail
        )
    }

    private func continueSubtitle(_ progress: WatchProgress) -> String? {
        if let season = progress.season, let episode = progress.episode {
            var line = "S\(season):E\(episode)"
            if let title = progress.episodeTitle { line += " · \(title)" }
            return line
        }
        return nil
    }

    /// Continue Watching card art: the episode still when enabled and present,
    /// otherwise the show backdrop/poster.
    private func continueImage(_ progress: WatchProgress) -> String? {
        if homeCatalogSettings.useEpisodeThumbnailsInCw, let thumb = progress.episodeThumbnail, !thumb.isEmpty {
            return thumb
        }
        return progress.background ?? progress.poster ?? catalogMeta(for: progress.metaID)?.background ?? catalogMeta(for: progress.metaID)?.poster
    }

    /// A hero-bar item for a Continue Watching entry. Progress rows only carry
    /// name/art, so prefer the full MetaItem when the title is also in a
    /// loaded catalog row (description, genres, rating…).
    private func heroItem(from progress: WatchProgress) -> MetaItem {
        if let match = catalogMeta(for: progress.metaID) { return match }
        return MetaItem(
            id: progress.metaID, type: progress.type, name: progress.name,
            poster: progress.poster, background: progress.background, logo: progress.logo
        )
    }

    private func catalogMeta(for id: String) -> MetaItem? {
        for entry in viewModel.entries {
            if case .catalog(let row) = entry,
               let match = row.items.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }
}

/// Continue Watching as its OWN view so the per-card focus bookkeeping stays
/// local. The remembered-card snap-back state used to live on HomeView itself,
/// so every left/right step inside this row wrote HomeView @State and
/// re-rendered the ENTIRE Home body — all rows — once per step. That's why
/// only this row lagged while the rest of Home was fine. Here, a focus step
/// re-renders just this row.
/// A catalog poster row with LOCAL focus state, so a focus move re-renders
/// only this row (not all of Home) and the row can implement Back navigation:
/// Back while scrolled into the row jumps to the first card; Back on the first
/// card bubbles up (`onBackAtStart`) to open the sidebar / focus the tab bar.
private struct HomePosterRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    let row: HomeRow
    let useLandscape: Bool
    let heroFollowsFocus: Bool
    let hero: HeroFocus
    let onSelect: (MetaItem) -> Void
    let onPlayManually: (MetaItem, MetaVideo?) -> Void
    let onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void
    let onBackAtStart: () -> Void

    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            header
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: NuvioSpacing.lg) {
                        ForEach(row.items) { item in
                            // Equatable cell: a focus step writes the row's
                            // @FocusState, which re-runs THIS row body — with
                            // plain cells every materialized card re-built its
                            // Button/card/caption tree per step. The == gate
                            // (item + layout inputs) lets SwiftUI skip every
                            // unchanged cell body, so a step re-renders nothing
                            // but the two cards whose focus visuals actually
                            // change (they invalidate via \.isFocused, which
                            // bypasses ==). Focus/scroll bookkeeping stays out
                            // here on the wrapper.
                            HomePosterCell(
                                item: item,
                                useLandscape: useLandscape,
                                captionWidth: useLandscape ? 340 : homeCatalogSettings.posterSize.posterWidth,
                                heroFollowsFocus: heroFollowsFocus,
                                hero: hero,
                                onSelect: onSelect,
                                onPlayManually: onPlayManually
                            )
                            .equatable()
                            .focused($focusedID, equals: item.id)
                            // Scroll target for the Back-to-start jump.
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.lg)
                }
                .scrollClipDisabled()
                // No .focusSection() here: it blocks the card's long-press hold
                // menu on tvOS (verified). Full poster rows never get skipped on
                // vertical moves anyway (there's always a card under any column),
                // so the "never skip" fix only needs the SPARSE rows (collections).
                // Back: jump to the first card if scrolled in; on the first
                // card, bubble up (sidebar / tab bar).
                .onExitCommand { backToStart(proxy) }
            }
        }
    }

    /// Back: if scrolled into the row, scroll back to the first card AND focus
    /// it. The scroll is essential — a `LazyHStack` unloads off-screen cards, so
    /// when you're deep in the row the first card doesn't exist yet and setting
    /// focus alone fails (the "doesn't work far into the row" bug). Scrolling it
    /// into view renders it, then focus can land on it.
    private func backToStart(_ proxy: ScrollViewProxy) {
        guard let first = row.items.first?.id, focusedID != first else {
            onBackAtStart()
            return
        }
        withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .leading) }
        // Defer the focus so the just-rendered first card exists to receive it.
        DispatchQueue.main.async { focusedID = first }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            RowHeader(title: row.title)
            if let addon = row.addon, let catalog = row.catalog {
                Spacer()
                Button {
                    onSeeAll(addon, catalog, row.title)
                } label: {
                    SeeAllLabel()
                }
                .buttonStyle(PlainCardButtonStyle())
                .padding(.trailing, NuvioSpacing.huge)
            }
        }
    }
}

/// One poster cell, Equatable so a row re-render (every focus step writes the
/// row's @FocusState) skips the bodies of unchanged cells. == covers the data
/// and layout inputs; the closures/hero are deliberately ignored — they're
/// stable for the life of the row, and focus visuals invalidate through
/// \.isFocused / EnvironmentObject, which bypass the == gate.
private struct HomePosterCell: View, Equatable {
    @EnvironmentObject private var theme: ThemeManager
    let item: MetaItem
    let useLandscape: Bool
    let captionWidth: CGFloat
    let heroFollowsFocus: Bool
    let hero: HeroFocus
    let onSelect: (MetaItem) -> Void
    let onPlayManually: (MetaItem, MetaVideo?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.useLandscape == rhs.useLandscape
            && lhs.captionWidth == rhs.captionWidth
            && lhs.heroFollowsFocus == rhs.heroFollowsFocus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onSelect(item)
            } label: {
                Group {
                    if useLandscape {
                        LandscapeCard(
                            imageURL: item.background ?? item.poster,
                            title: item.name,
                            subtitle: nil,
                            width: 340,
                            showsCaption: !theme.isAppleTVTheme
                        )
                    } else {
                        PosterCard(item: item)
                    }
                }
                .onFocusChange { focused in
                    if focused && heroFollowsFocus { hero.focus(item) }
                }
            }
            .mediaCardButtonStyle()
            .posterHoldMenu(item) { onSelect(item) }
            .onPlayPauseCommand { onPlayManually(item, nil) }

            if theme.isAppleTVTheme {
                ATVCardCaption(
                    title: item.name,
                    subtitle: item.year,
                    width: captionWidth
                )
            }
        }
    }
}

private struct ContinueWatchingRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let items: [WatchProgress]
    /// Plain let (not observed): the row only CALLS into the hero, it never
    /// renders from it.
    let hero: HeroFocus
    /// False in Grid layout, where no backdrop/billboard renders the hero.
    let drivesHero: Bool
    let imageFor: (WatchProgress) -> String?
    let subtitleFor: (WatchProgress) -> String?
    let blurFor: (WatchProgress) -> Bool
    let heroItemFor: (WatchProgress) -> MetaItem
    let onResume: (WatchProgress) -> Void
    // Hold-Select actions fed into the shared `continueHoldMenu` modifier.
    let onDetails: (WatchProgress) -> Void
    let onPlayManuallyMenu: (WatchProgress) -> Void
    let onResumeFromStartMenu: (WatchProgress) -> Void
    /// Back on the first card bubbles up (sidebar / tab bar).
    var onBackAtStart: () -> Void = {}

    // Tracks the focused card for the Back-to-start jump. Uses the same plain
    // @FocusState model as HomePosterRow (no .focusScope / .prefersDefaultFocus)
    // — that focus-scope machinery re-asserted focus within the row and cancelled
    // the hold-menu long-press on Modern. Entry into the row is handled by the
    // .focusSection() below, exactly like the poster rows.
    @FocusState private var focusedCWCard: String?

    var body: some View {
        // Focus model mirrors HomePosterRow (plain @FocusState, no .focusScope /
        // .focusSection).
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            RowHeader(title: "Continue Watching")
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: NuvioSpacing.lg) {
                    ForEach(items) { progress in
                      // Equatable cell, same reasoning as HomePosterCell: focus
                      // steps write the row's @FocusState and re-run this body;
                      // the == gate skips every unchanged card. Derived values
                      // (image/subtitle/blur) are computed HERE and passed as
                      // stored properties so they participate in == — a settings
                      // toggle that changes them still re-renders. NB: no
                      // row-level focus glow — LandscapeCard draws its own off
                      // \.isFocused; a row-level shadow keyed on focusedCWCard
                      // used to re-render the whole row per move and cancelled
                      // the hold-menu long-press.
                      ContinueWatchingCell(
                        progress: progress,
                        imageURL: imageFor(progress),
                        subtitle: subtitleFor(progress),
                        blur: blurFor(progress),
                        drivesHero: drivesHero,
                        hero: hero,
                        heroItemFor: heroItemFor,
                        onResume: onResume,
                        onDetails: { onDetails(progress) },
                        onPlayManuallyMenu: { onPlayManuallyMenu(progress) },
                        onResumeFromStartMenu: { onResumeFromStartMenu(progress) }
                      )
                      .equatable()
                      .focused($focusedCWCard, equals: progress.id)
                      .id(progress.id)
                    }
                }
                .padding(.horizontal, NuvioSpacing.huge)
                .padding(.vertical, NuvioSpacing.lg)
            }
            .scrollClipDisabled()
            // Back: scroll to + focus the first card if scrolled in; on the first
            // card, bubble up (tab bar).
            .onExitCommand {
                if let first = items.first?.id, focusedCWCard != first {
                    withAnimation(FusionMotion.focusMove) { proxy.scrollTo(first, anchor: .leading) }
                    DispatchQueue.main.async { focusedCWCard = first }
                } else {
                    onBackAtStart()
                }
            }
            // A card removed while focused hands focus to the next available card.
            .onChange(of: items.map(\.id)) { oldIDs, newIDs in
                guard let focused = focusedCWCard, !newIDs.contains(focused),
                      !newIDs.isEmpty else { return }
                let oldIndex = oldIDs.firstIndex(of: focused) ?? 0
                focusedCWCard = newIDs[min(oldIndex, newIDs.count - 1)]
            }
            }   // ScrollViewReader
        }
        // No .focusSection() — matches HomePosterRow. The focus section governs
        // focus transitions, and on Modern it blocked the hold-menu context menu
        // from presenting even though the long-press reached the card (confirmed
        // via a press probe). Poster rows never had it and their hold menu works.
    }
}

/// One Continue Watching cell, Equatable so row re-renders (focus steps) skip
/// unchanged card bodies — see HomePosterCell. Derived display values are
/// stored properties so they participate in ==. The hold-Select menu is applied
/// with the shared `continueHoldMenu` modifier (built inline from these
/// closures), NOT a threaded @ViewBuilder — the threaded path failed to present
/// the menu on the Apple TV card style.
private struct ContinueWatchingCell: View, Equatable {
    @EnvironmentObject private var theme: ThemeManager
    let progress: WatchProgress
    let imageURL: String?
    let subtitle: String?
    let blur: Bool
    let drivesHero: Bool
    let hero: HeroFocus
    let heroItemFor: (WatchProgress) -> MetaItem
    let onResume: (WatchProgress) -> Void
    let onDetails: () -> Void
    let onPlayManuallyMenu: () -> Void
    let onResumeFromStartMenu: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.progress == rhs.progress
            && lhs.imageURL == rhs.imageURL
            && lhs.subtitle == rhs.subtitle
            && lhs.blur == rhs.blur
            && lhs.drivesHero == rhs.drivesHero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onResume(progress)
            } label: {
                        LandscapeCard(
                            imageURL: imageURL,
                            title: progress.name,
                            subtitle: subtitle,
                            progress: progress.fraction,
                            remainingText: progress.remainingTimeText,
                            hasNewEpisode: progress.hasNewEpisode == true,
                            blurImage: blur,
                    // ATV: caption goes BELOW the platter (see below) so it
                    // isn't bridged to the still by the slab.
                    showsCaption: !theme.isAppleTVTheme
                )
                // Hero bar follows focus here too, like every other row.
                // Inside the label: `\.isFocused` only resolves within the
                // focusable Button, not around it.
                .onFocusChange { focused in
                    if focused, drivesHero { hero.focus(heroItemFor(progress)) }
                }
            }
            .mediaCardButtonStyle()
            .continueHoldMenu(progress, onDetails: onDetails,
                              onPlayManually: onPlayManuallyMenu,
                              onResumeFromStart: onResumeFromStartMenu)
            // ⏯ resumes instantly from a focused CW card too.
            .onPlayPauseCommand { onResume(progress) }

            if theme.isAppleTVTheme {
                ATVCardCaption(
                    title: progress.name,
                    subtitle: subtitle,
                    width: 380
                )
            }
        }
    }
}

/// First-run loading backdrop that announces each phase as it happens (add-ons
/// → catalogs → artwork), mirroring the Android app. Completed steps show a
/// check, the active step spins, and pending steps are dimmed. Only shown on a
/// cold, cache-less launch; warm starts render instantly from the disk cache.
private struct HomeLoadingBackdrop: View {
    @EnvironmentObject private var theme: ThemeManager
    let step: String?

    private let steps = ["Loading add-ons…", "Loading catalogs…", "Loading artwork…"]
    private var activeIndex: Int { steps.firstIndex(of: step ?? "") ?? 0 }

    var body: some View {
        // NB: this view is mounted as a ~460pt hero strip inside Home's scroll
        // content, NOT full-screen — so the branded art rides as a clipped
        // .background (which doesn't affect layout) rather than a ZStack child,
        // where scaledToFill would blow past the strip and bleed over the rows.
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                HStack(spacing: NuvioSpacing.md) {
                    icon(for: index)
                        .frame(width: 34, height: 34)
                    Text(label.replacingOccurrences(of: "…", with: ""))
                        .font(.system(size: 27, weight: index == activeIndex ? .semibold : .regular))
                        .foregroundStyle(index <= activeIndex
                            ? theme.palette.textPrimary
                            : theme.palette.textSecondary.opacity(0.5))
                }
            }
        }
        .padding(NuvioSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            // Branded Orivio backdrop (logo mark on the gradient), cropped to
            // the strip.
            Image("OrivioBackdropLogo")
                .resizable()
                .scaledToFill()
        }
        .clipped()
    }

    @ViewBuilder
    private func icon(for index: Int) -> some View {
        if index < activeIndex {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(theme.palette.secondary)
        } else if index == activeIndex {
            ProgressView()
                .progressViewStyle(.circular)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 26))
                .foregroundStyle(theme.palette.textSecondary.opacity(0.35))
        }
    }
}

/// Focus-styled "Try Again" pill shared by network-failure empty states.
struct RetryLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: NuvioSpacing.sm) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 20, weight: .semibold))
            Text("Try Again")
                .font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.textPrimary)
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .background(Capsule().fill(isFocused ? theme.palette.secondary : Color.primary.opacity(0.1)))
        .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
        .scaleEffect(PerformanceSettingsStore.shared.buttonAnimationsEffective && isFocused ? 1.05 : 1)
        .animation(PerformanceSettingsStore.shared.buttonAnimationsEffective
                   ? .easeInOut(duration: 0.15) : nil, value: isFocused)
    }
}

/// "See All ›" pill shown in a catalog row header (text is reusable for other
/// header-side actions, e.g. "Mark Season Watched").
struct SeeAllLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    var text: String = "See All"

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 22, weight: .semibold))
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .bold))
        }
        .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
        .padding(.horizontal, NuvioSpacing.md)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : Color.primary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .scaleEffect(PerformanceSettingsStore.shared.buttonAnimationsEffective && isFocused ? 1.06 : 1)
        .animation(PerformanceSettingsStore.shared.buttonAnimationsEffective
                   ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: isFocused)
    }
}

extension View {
    /// Small helper because `.onFocusChange` reads better at call sites than
    /// the focusable/onChange dance.
    func onFocusChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(FocusChangeModifier(action: action))
    }
}

private struct FocusChangeModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused) { _, newValue in
                action(newValue)
            }
            // onChange misses the INITIAL value: a lazy cell created by a fast
            // scroll (or at launch) can be born already-focused with no change
            // event.
            .onAppear {
                if isFocused { action(true) }
            }
    }
}

// MARK: - Billboard (isolated so hero updates don't re-render the rows)

/// Fusion (§22.1): the Classic home layout's shallow "backdrop sliver" —
/// artwork confined to the upper-right of a 300pt band, faded hard into the
/// background, with only a compact title label (no synopsis, no buttons).
/// Classic is meant to feel lighter/faster than Modern's full spotlight.
private struct ATVClassicHeroSliver: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var hero: HeroFocus
    private let sliverHeight: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let art = hero.item?.background ?? hero.item?.poster {
                    RemoteImage(url: art, alignment: .topTrailing)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                // Strong left + bottom fade — only the upper-right corner
                // reads as art; everything else dissolves into the page.
                LinearGradient(
                    stops: [
                        .init(color: theme.palette.background, location: 0),
                        .init(color: theme.palette.background.opacity(0.62), location: 0.32),
                        .init(color: .clear, location: 0.62)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, theme.palette.background],
                    startPoint: UnitPoint(x: 0.5, y: 0.3), endPoint: UnitPoint(x: 0.5, y: 1)
                )
                if let name = hero.item?.name {
                    // Compact label only — no synopsis/buttons (§22.1).
                    Text(name)
                        .font(FusionType.moduleHeading(theme.font))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .padding(.leading, NuvioSpacing.huge)
                        .padding(.bottom, NuvioSpacing.lg)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: sliverHeight)
        .ignoresSafeArea(edges: .horizontal)
    }
}

/// Full-bleed backdrop for the focused title. Observes `HeroFocus` on its own,
/// so the animated hero swap re-renders ONLY this view — not the poster rows
/// (that re-render was cancelling the first long-press on a card).
private struct HeroBackdropView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var hero: HeroFocus
    /// Light appearance (Apple TV theme only — Classic is always dark). The
    /// dark scrim ramps read as cinematic shadow, but the same opacities in
    /// WHITE read as fog over the whole image — light mode uses tighter ramps
    /// that keep the art vivid and only clear a zone for the text.
    @Environment(\.colorScheme) private var scheme
    private var isLight: Bool { scheme == .light }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let item = hero.item {
                    if item.type == "collection", (item.background ?? item.poster) == nil, let logo = item.logo {
                        // A category with no real backdrop: show its brand logo
                        // WHOLE (fit), large, high on the art side — never a
                        // cropped, zoomed-in .fill. Changes per focused folder.
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(width: geo.size.width * 0.4, height: geo.size.height * 0.34)
                            .padding(.top, geo.size.height * 0.1)
                            .padding(.trailing, geo.size.width * 0.08)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                    } else {
                        // No .id() — RemoteImage crossfades internally as the URL
                        // changes, dissolving between titles instead of reloading.
                        RemoteImage(url: item.background ?? item.poster)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                // Apple TV theme: progressive-blur dissolve (the tvOS TV-app
                // treatment) — the art frosts into the background toward the
                // text column and the rows, instead of dying under a flat
                // color band. A blurred copy of the same backdrop (cache hit,
                // hero-only cost) is revealed by gradient masks at the left
                // and bottom; the color scrims above then need far less
                // opacity, so the art stays vivid where it matters.
                if theme.isAppleTVTheme, !PerformanceProfile.isLowPower, let item = hero.item,
                   let art = item.background ?? item.poster,
                   !(item.type == "collection" && item.background == nil && item.poster == nil) {
                    // The progressive-blur dissolve needs a SECOND full-screen
                    // layer + gradient masks — a composite the 2 GB Apple TV HD
                    // can't spare even with the blur pre-rendered. There the
                    // flat color scrims below carry the fade instead.
                    //
                    // PRE-blurred (BlurredRemoteImage): the old live
                    // `.blur(radius: 60)` here made Core Animation re-run a
                    // full-screen gaussian on every composited frame — the
                    // heaviest recurring GPU cost on the A10X while Home
                    // scrolls. The pre-blurred rendition is pixel-equivalent
                    // under these masks at a plain-composite price.
                    BlurredRemoteImage(url: art, screenBlurRadius: 60)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(
                            ZStack {
                                LinearGradient(
                                    stops: [
                                        .init(color: .white, location: 0),
                                        .init(color: .white.opacity(0.9), location: 0.30),
                                        .init(color: .clear, location: 0.60)
                                    ],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 0.34),
                                        .init(color: .white.opacity(0.85), location: 0.58),
                                        .init(color: .white, location: 0.72)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                        )
                        .allowsHitTesting(false)
                }
                // Netflix scrim: art reads on the top-right; the left third is
                // darkened for the title/synopsis; the lower half dissolves into
                // the background so the rows sit on near-solid black.
                // Smooth continuous ramp (many stops, fade starts immediately)
                // so there's no flat near-solid block that reads as a second
                // "tone" next to the sidebar — it just dissolves into the art.
                LinearGradient(
                    stops: isLight
                        ? [
                            // Over the blur this tint reads as white frosted
                            // glass (blur + tint = material), so it stays
                            // strong through the text column and only drops
                            // once the art goes sharp.
                            .init(color: theme.palette.background, location: 0),
                            .init(color: theme.palette.background.opacity(0.90), location: 0.22),
                            .init(color: theme.palette.background.opacity(0.78), location: 0.40),
                            .init(color: theme.palette.background.opacity(0.45), location: 0.52),
                            .init(color: .clear, location: 0.64)
                        ]
                        : [
                            .init(color: theme.palette.background, location: 0),
                            .init(color: theme.palette.background.opacity(0.92), location: 0.14),
                            .init(color: theme.palette.background.opacity(0.72), location: 0.30),
                            .init(color: theme.palette.background.opacity(0.45), location: 0.46),
                            .init(color: theme.palette.background.opacity(0.20), location: 0.62),
                            .init(color: .clear, location: 0.80)
                        ],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    stops: isLight
                        ? [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.40),
                            .init(color: theme.palette.background.opacity(0.60), location: 0.56),
                            .init(color: theme.palette.background, location: 0.70)
                        ]
                        : [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.32),
                            .init(color: theme.palette.background.opacity(0.55), location: 0.52),
                            .init(color: theme.palette.background, location: 0.66)
                        ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Title / meta / synopsis block for the focused title. Same isolation as the
/// backdrop.
private struct HeroInfoView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject var hero: HeroFocus
    /// Light appearance (ATV theme): title-treatment logos are usually white
    /// art and float unanchored on a light backdrop without a shadow.
    @Environment(\.colorScheme) private var scheme
    @State private var contentRating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            if let item = hero.item {
                // Crossfade ON (Settings → Performance → Hero crossfade): the
                // whole info block dissolves between titles — `.id` replaces
                // the subtree per focus move (logo view + fetch task + text
                // layout), paired with HeroFocus.focus's withAnimation. That
                // teardown is the cost that made Modern scrub heavier than
                // Classic/Grid, so OFF takes the cheap path: in-place updates,
                // texts swap directly, the logo crossfades internally as its
                // URL changes.
                if perf.heroCrossfadeEffective {
                    content(item)
                        .id(item.id)
                        .transition(.opacity)
                } else {
                    content(item)
                }
            }
        }
        .frame(height: 330, alignment: .bottomLeading)
        .task(id: hero.item?.id) { await loadContentRating() }
    }

    private func loadContentRating() async {
        guard let item = hero.item, item.type != "collection" else {
            contentRating = nil
            return
        }
        let rating = await TMDBService.contentRating(imdbID: item.id, type: item.type)
        if hero.item?.id == item.id { contentRating = rating }
    }

    @ViewBuilder
    private func content(_ item: MetaItem) -> some View {
        // A category (collection folder): its logo is shown large in the
        // backdrop, so the info block is just the category name — no small
        // duplicate logo and no empty movie-meta row.
        if item.type == "collection" {
            Text(item.name)
                .font(.system(size: 52, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
        } else {
            realTitleContent(item)
        }
    }

    @ViewBuilder
    private func realTitleContent(_ item: MetaItem) -> some View {
        if let logo = item.logo {
            RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                .frame(width: 460, height: 150)
                .shadow(color: .black.opacity(scheme == .light ? 0.35 : 0),
                        radius: 14, y: 5)
        } else {
            Text(item.name)
                .font(.system(size: 58, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
        }

        // APK meta order: Type • Rating • Genre • Runtime • Year • IMDb badge + rating.
        HStack(spacing: NuvioSpacing.sm) {
            MetaDotText(item.typeLabel)
            if let contentRating {
                MetaDot(); MetaDotText(contentRating)
            }
            if let genre = item.genres?.first {
                MetaDot(); MetaDotText(genre)
            }
            if let runtime = item.runtimeFormatted {
                MetaDot(); MetaDotText(runtime)
            }
            if let year = item.year {
                MetaDot(); MetaDotText(year)
            }
            if let rating = item.imdbRating {
                MetaDot(); ImdbBadge(rating: rating)
            }
        }

        if let description = item.description {
            Text(description)
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

/// Fusion Modern's scroll-away hero header: a tall backdrop (art + scrim) with
/// the spotlight info block anchored at its bottom. It's the FIRST item of the
/// Home scroll, so it moves up and off the screen as the user browses down —
/// the hero is part of the page, not pinned to the viewport.
private struct FusionHeroHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var hero: HeroFocus
    let onPlay: (MetaItem) -> Void
    /// Tall like the Detail page's backdrop — the art dominates the first
    /// screen, with the first content row peeking at the very bottom.
    var height: CGFloat = 880

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Full-bleed backdrop (the scroll ignores the safe area, so this
            // fills the whole screen width like the Detail-page backdrop).
            GeometryReader { geo in
                if let art = hero.item?.background ?? hero.item?.poster {
                    RemoteImage(url: art)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            // Left readability wash.
            LinearGradient(
                stops: [
                    .init(color: theme.palette.background, location: 0),
                    .init(color: theme.palette.background.opacity(0.82), location: 0.16),
                    .init(color: theme.palette.background.opacity(0.45), location: 0.34),
                    .init(color: .clear, location: 0.60)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            // Strong bottom gradient blending into the grey page.
            LinearGradient(
                stops: [
                    .init(color: theme.palette.background, location: 0),
                    .init(color: theme.palette.background.opacity(0.9), location: 0.14),
                    .init(color: theme.palette.background.opacity(0.5), location: 0.32),
                    .init(color: .clear, location: 0.6)
                ],
                startPoint: .bottom, endPoint: .top
            )
            // Spotlight info — extra leading inset so text/logo stay title-safe
            // even though the art bleeds to the edge.
            ATVHeroInfoView(hero: hero, onPlay: onPlay)
                .padding(.leading, NuvioSpacing.xl)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // "TOP 10" eyebrow at the very top-left of the hero.
        .overlay(alignment: .topLeading) {
            if hero.spotlight.count > 1 {
                Text("TOP 10")
                    .font(FusionType.badge(theme.font))
                    .tracking(2)
                    .foregroundStyle(theme.palette.secondary)
                    .padding(.leading, NuvioSpacing.huge + NuvioSpacing.xl)
                    .padding(.top, 130)   // clear the top tab bar
            }
        }
    }
}

/// The Apple TV theme's prominent spotlight hero: a tall, bottom-anchored
/// billboard (logo, rating/meta line, synopsis, and a focusable Play button)
/// over the full-bleed backdrop. Auto-rotates through the top titles when idle
/// (see `HeroFocus.rotateIfIdle`) and follows card focus while browsing.
private struct ATVHeroInfoView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var hero: HeroFocus
    let onPlay: (MetaItem) -> Void
    @State private var contentRating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            Spacer(minLength: 0)
            if let item = hero.item {
                content(item)
            }
        }
        .frame(height: 560, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .padding(.leading, NuvioSpacing.huge)
        .padding(.bottom, NuvioSpacing.md)
        .task(id: hero.item?.id) { await loadContentRating() }
    }

    private func loadContentRating() async {
        guard let item = hero.item, item.type != "collection" else {
            contentRating = nil
            return
        }
        let rating = await TMDBService.contentRating(imdbID: item.id, type: item.type)
        if hero.item?.id == item.id { contentRating = rating }
    }

    @ViewBuilder
    private func content(_ item: MetaItem) -> some View {
        if item.type == "collection" {
            Text(item.name)
                .font(.system(size: 60, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
        } else {
            // (The "TOP 10" eyebrow now lives at the hero's top-left corner —
            // see FusionHeroHeader.)
            // Title treatment (logo) or big text fallback.
            if let logo = item.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                    .frame(width: 540, height: 180)
                    // Grounds a white logo on both a light frost and dark art.
                    .shadow(color: .black.opacity(scheme == .light ? 0.32 : 0.5),
                            radius: 16, y: 6)
            } else {
                Text(item.name)
                    .font(FusionType.heroTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(scheme == .light ? 0 : 0.4), radius: 10, y: 4)
            }

            metaLine(item)

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 820, alignment: .leading)
            }

            ATVHeroPlayButton(title: item.type == "series" ? "Go to Show" : "Go to Movie") {
                onPlay(item)
            }
            .onFocusChange { focused in
                hero.heroButtonFocused = focused
                if focused { hero.markInteraction() }
            }
            // Left/Right on the (horizontally-alone) Play button browse the
            // spotlight titles; Up/Down fall through to the focus engine so
            // Down still reaches the content rows.
            .onMoveCommand { direction in
                switch direction {
                case .left: hero.stepSpotlight(by: -1)
                case .right: hero.stepSpotlight(by: 1)
                default: break
                }
            }
            .padding(.top, NuvioSpacing.xs)

            // §20.5 pagination — tracks spotlight rotation position.
            if hero.spotlight.count > 1 {
                paginationDots
                    .padding(.top, NuvioSpacing.sm)
            }
        }
    }

    @ViewBuilder
    private var paginationDots: some View {
        HStack(spacing: 8) {
            ForEach(hero.spotlight.indices, id: \.self) { i in
                Capsule()
                    .fill(i == hero.spotlightIndex ? theme.palette.secondary : Color.white.opacity(0.35))
                    .frame(width: i == hero.spotlightIndex ? 24 : 7, height: 7)
            }
        }
        .animation(FusionMotion.focusEntry, value: hero.spotlightIndex)
    }

    /// Rating (green, TV-app style) then a dot-separated Year • Genre • Runtime.
    @ViewBuilder
    private func metaLine(_ item: MetaItem) -> some View {
        let segments = [contentRating, item.year, item.genres?.first, item.runtimeFormatted].compactMap { $0 }
        HStack(spacing: NuvioSpacing.sm) {
            if let rating = item.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 17, weight: .bold))
                    Text(rating).font(.system(size: 23, weight: .bold))
                }
                .foregroundStyle(NuvioPrimitives.success)
                if !segments.isEmpty { MetaDot() }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                if index > 0 { MetaDot() }
                MetaDotText(seg)
            }
        }
    }
}

/// White capsule Play button for the Apple TV hero (reference "Go to Movie"
/// affordance). Lifts on focus with the native-feeling scale + shadow.
private struct ATVHeroPlayButton: View {
    let title: String
    let action: () -> Void

    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill").font(.system(size: 24, weight: .bold))
                Text(title).font(FusionType.button(theme.font))
            }
        }
        .buttonStyle(ATVHeroPlayButtonStyle())
    }
}

private struct ATVHeroPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        @EnvironmentObject private var theme: ThemeManager
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                // Focused: accent fill + white text; at rest: neutral white pill.
                .foregroundStyle(isFocused ? .white : .black)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.9)))
                // Bright ring on focus so it reads as selected even over busy art.
                .overlay(
                    Capsule().strokeBorder(isFocused ? Color.white.opacity(0.95) : .clear, lineWidth: 4)
                )
                // Accent glow beneath the focused pill.
                .shadow(color: isFocused ? theme.palette.secondary.opacity(0.7) : .black.opacity(0.14),
                        radius: isFocused ? 26 : 6, y: isFocused ? 12 : 6)
                .scaleEffect(isFocused ? 1.12 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(FusionMotion.focusEntry, value: isFocused)
                .animation(configuration.isPressed ? FusionMotion.pressDown : FusionMotion.pressRelease,
                           value: configuration.isPressed)
        }
    }
}
