import SwiftUI
import AVFoundation


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
    case collection(OrivioCollection)

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
        return caches.appendingPathComponent("orivio-home-catalogs.json")
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
    @Published var entries: [HomeEntry] = [] {
        didSet { rebuildItemIndex() }
    }
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
    /// Published, so the hero can paint the MOMENT the disk cache decodes it.
    /// As a plain var the view only read it after `loadIfNeeded` returned — i.e.
    /// after every add-on had answered or timed out — so on a warm launch the
    /// whole first screen, an 880pt hero, sat blank while the rows underneath it
    /// were already drawn from cache and the answer was sitting right here.
    @Published var initialHero: MetaItem?

    private var loadedFingerprint: [String] = []
    /// Bumped by every `load`. Loads overlap constantly on launch —
    /// `.task` fires one, then the account sync lands and collections,
    /// order keys and add-ons each trip their own `.onChange` — and each
    /// run holds its OWN `orderedKeys`, captured before its awaits. With
    /// no generation check the run that finishes last wins, which is
    /// routinely the OLDEST one: it republishes a row list assembled
    /// before the collections existed, so the collection rows vanish and
    /// stay gone (the fingerprint already says "loaded"). That is the
    /// intermittent "my categories didn't show up" — a race, which is
    /// why a relaunch usually 'fixes' it.
    private var loadGeneration = 0

    // MARK: - Shared home assembly
    //
    // Every themed home derives the same things from `entries`: the catalog
    // rows, the Continue Watching list with its artwork fallback, the shared
    // collections strip. Each theme used to carry its own copy — `catalogRows`
    // in five files, `metaFor` in six, `progressWithCatalogArt` in four — so a
    // fix (or a performance bug) in one never reached the others. They live
    // here once now; a theme supplies only the look.

    /// Catalog rows, in Home order.
    var catalogRows: [HomeRow] {
        entries.compactMap { if case .catalog(let row) = $0 { return row } else { return nil } }
    }

    /// Every catalog item by id, rebuilt only when `entries` changes. The
    /// per-theme copies re-derived this inside a loop over Continue Watching
    /// items — 45 rows x 30 items scanned per card, on every body pass.
    private(set) var itemIndex: [String: MetaItem] = [:]

    /// Every catalog item, de-duplicated, in HOME ORDER. Order matters — the
    /// Max and Hulu spotlights take the first few with backdrop art, so this
    /// cannot be served from `itemIndex.values`, which is unordered.
    private(set) var orderedItems: [MetaItem] = []

    private func rebuildItemIndex() {
        var index: [String: MetaItem] = [:]
        var ordered: [MetaItem] = []
        for case .catalog(let row) in entries {
            for item in row.items where index[item.id] == nil {
                index[item.id] = item
                ordered.append(item)
            }
        }
        itemIndex = index
        orderedItems = ordered
    }

    /// A Continue Watching row's full MetaItem, upgraded from the catalog copy
    /// when one is loaded (CW rows carry only name + art fragments).
    func metaFor(_ progress: WatchProgress) -> MetaItem {
        itemIndex[progress.metaID]
            ?? MetaItem(id: progress.metaID, type: progress.type, name: progress.name,
                        poster: progress.poster, background: progress.background,
                        logo: progress.logo)
    }

    /// Fill in artwork/title a Continue Watching row is missing from the
    /// catalog copy of the same title, when Home has one loaded.
    func withCatalogArt(_ progress: WatchProgress) -> WatchProgress {
        guard progress.poster == nil || progress.background == nil || progress.name.isEmpty,
              let meta = itemIndex[progress.metaID] else { return progress }
        return progress.withFallbackMetadata(meta)
    }

    /// Continue Watching for a themed home: sorted per the user's setting, with
    /// the catalog artwork fallback applied.
    func continueItems(
        progress store: ProgressStore, sortMode: ContinueWatchingSortMode
    ) -> [WatchProgress] {
        store.continueWatching(sortMode: sortMode).map(withCatalogArt)
    }

    /// Collections that share ONE combined "Collections" row (viewMode other
    /// than ROWS); a theme renders them at `firstSharedCollectionID`'s slot.
    var sharedCollections: [OrivioCollection] {
        entries.compactMap {
            if case .collection(let c) = $0, c.viewMode != "ROWS" { return c } else { return nil }
        }
    }

    var firstSharedCollectionID: String? { sharedCollections.first?.id }

    /// One folder presented as its own single-folder collection — what every
    /// theme opens when a folder tile is selected.
    nonisolated static func folderCollection(
        _ folder: OrivioCollectionFolder, in collection: OrivioCollection
    ) -> OrivioCollection {
        OrivioCollection(id: "folder:\(collection.id):\(folder.id)",
                        title: folder.title, folders: [folder])
    }

    func loadIfNeeded(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore,
        providers: CollectionProviders
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
        // Row titles are baked in at load time by rowTitle(), so the two
        // switches that change them belong in the fingerprint. Without these,
        // toggling "Show add-on name" or the type suffix left every row header
        // stale until some unrelated refresh happened to rebuild Home.
        fingerprint.append("addonName=\(settings.catalogAddonNameEnabled)")
        fingerprint.append("typeSuffix=\(settings.catalogTypeSuffixEnabled)")
        fingerprint.append(collections.collections.map {
            "\($0.id)#\($0.folders.count)#\($0.title)#\($0.viewMode)#\($0.pinToTop)"
        }.joined(separator: ","))
        // Collection rows no longer come and go with TMDB / Trakt, but keep
        // the connections in the fingerprint anyway — cheap, and any future
        // provider-dependent rendering rebuilds without a relaunch.
        fingerprint.append("providers=\(providers.tmdb)/\(providers.trakt)")
        guard entries.isEmpty || fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        await load(addonManager: addonManager, collections: collections,
                   settings: settings, providers: providers)
    }

    func load(
        addonManager: AddonManager,
        collections: CollectionsStore,
        settings: HomeCatalogSettingsStore,
        /// TMDB / Trakt. Collections ALWAYS show on Home, whatever is
        /// connected — a collection opened with nothing connected explains
        /// inside (per folder) that TMDB or Trakt needs setting up. Hiding
        /// them here just made the feature look broken with no pointer to why.
        providers: CollectionProviders
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        /// False once a newer load has started; a superseded run stops
        /// publishing instead of overwriting the newer one's rows.
        func isCurrent() -> Bool { loadGeneration == generation }

        isLoading = entries.isEmpty
        loadError = nil

        // Assemble the available rows keyed the same way the sync payload is,
        // then let the layout settings decide order and visibility.
        var catalogByKey: [String: (addon: InstalledAddon, catalog: ManifestCatalog)] = [:]
        var catalogKeys: [String] = []
        // Enumerate EVERY catalog the addon declares — the same rule
        // Settings → Layout uses. These two lists must agree: a per-addon
        // `.prefix(6)` here meant an addon declaring 10 catalogs showed all 10
        // in the Layout editor (with live toggles and reorder arrows) while
        // Home silently never fetched 7-10, and no amount of reordering could
        // rescue them because the cut was taken in MANIFEST order, before the
        // user's order was merged in. `maxHomeRows` below is the real ceiling,
        // and it cuts in the user's own order.
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id
                )
                guard catalogByKey[key] == nil else { continue }
                catalogKeys.append(key)
                catalogByKey[key] = (addon, catalog)
            }
        }
        var collectionByKey: [String: OrivioCollection] = [:]
        var collectionKeys: [String] = []
        for collection in collections.collections {
            let key = HomeCatalogSettingsStore.collectionKey(collection.id)
            collectionKeys.append(key)
            collectionByKey[key] = collection
        }
        NSLog("[OrivioHome] load: %d catalogs, %d collections (%d pinned), %d order keys",
              catalogKeys.count, collectionKeys.count,
              collections.collections.filter(\.pinToTop).count,
              settings.orderKeys.count)

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

        // Rows painted from the on-disk cache, by key. These are REAL content
        // already on screen, so every republish below composes against them:
        // a row that hasn't come back from the network yet keeps showing its
        // cached items rather than disappearing.
        var staleByKey: [String: HomeEntry] = [:]

        /// The published row list: fresh where we have it, cached where we
        /// don't, collections always.
        ///
        /// Everything that assigns `entries` during a refresh goes through
        /// this. The old code assigned raw partial results instead — first the
        /// collection markers alone (wiping every cached row the moment a
        /// refresh started), then each progressive batch (a screen of cached
        /// rows collapsing to the one or two that had answered so far). That
        /// is the "categories flash for a split second and vanish" on a cold
        /// start: the rows were never lost, they were being republished a few
        /// at a time over a full screen that had already painted.
        func compose(fresh: [String: HomeEntry]) -> [HomeEntry] {
            orderedKeys.compactMap { key in
                if let collection = collectionByKey[key] { return .collection(collection) }
                return fresh[key] ?? staleByKey[key]
            }
        }

        // A refresh over an already-populated Home (coming back to the tab, a
        // settings change, a manual refresh) has to be protected the same way
        // — seed the fallback from what is currently on screen, or the
        // progressive republish blanks those rows exactly like a cold start.
        if !entries.isEmpty {
            var keyByRowID: [String: String] = [:]
            for key in orderedKeys {
                if let request = catalogByKey[key] { keyByRowID[Self.rowID(request)] = key }
            }
            for entry in entries {
                if case .catalog(let row) = entry, let key = keyByRowID[row.id] {
                    staleByKey[key] = entry
                }
            }
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
                    let staleRow = HomeEntry.catalog(HomeRow(
                        id: Self.rowID(request),
                        title: Self.rowTitle(key: key, request: request, settings: settings),
                        items: staleItems, addon: request.addon, catalog: request.catalog
                    ))
                    // Remembered by key so the refresh below can fall back to
                    // it PER ROW instead of blanking the screen.
                    staleByKey[key] = staleRow
                    stale.append(staleRow)
                }
            }
            if !isCurrent() { return }
            if !stale.isEmpty {
                entries = stale
                if initialHero == nil { initialHero = Self.firstHero(stale) }
                // As early as the rows exist, before the network revalidation
                // even starts. Backdrops are the one image class nothing warms:
                // the poster prefetch below only takes `\.poster` from rows 3+,
                // so every spotlight title used to hit the network at the
                // moment it rotated in — a full-screen download while you are
                // looking at the frame it belongs in.
                warmSpotlightArt()
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
        /// Fresh rows by key, for `compose`.
        var freshByKey: [String: HomeEntry] = [:]
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
        // Collections resolve instantly; publish them WITH the cached rows
        // still in place (compose keeps them) rather than in place of them.
        if !fetched.isEmpty, isCurrent() { entries = compose(fresh: [:]) }

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
                    // A row that yields nothing is dropped silently — it just
                    // isn't on Home, while Settings → Layout still lists it.
                    // That is indistinguishable from "the addon is down" unless
                    // we say which happened, so log the reason.
                    var items: [MetaItem]
                    do {
                        items = try await StremioAPI.catalog(addon: request.addon, catalog: request.catalog)
                    } catch {
                        NSLog("[OrivioHome] row dropped — fetch failed: %@ (%@): %@",
                              title, key, error.localizedDescription)
                        return (index, key, nil)
                    }
                    let fetched = items.count
                    // "Hide unreleased content" (Settings → Layout). Filtered
                    // BEFORE the 30-item trim so a row full of upcoming titles
                    // still fills up with things you can actually watch.
                    if hideUnreleased { items = items.filter { !$0.isUnreleased } }
                    guard !items.isEmpty else {
                        NSLog("[OrivioHome] row dropped — %@: %@ (%@)",
                              fetched == 0 ? "addon returned no items"
                                           : "all \(fetched) items hidden by Hide unreleased content",
                              title, key)
                        return (index, key, nil)
                    }
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
                // Stop the whole sweep once superseded, rather than only muting
                // its results. The generation check below prevented a stale
                // publish, but the abandoned run carried on issuing and decoding
                // every remaining catalog page — so the duplicated work and the
                // memory peak both survived it.
                guard isCurrent() else { group.cancelAll(); break }
                startNext()
                guard let entry else { continue }
                fetched.append((index: index, key: String?.some(key), entry: entry))
                freshByKey[key] = entry
                if Date().timeIntervalSince(lastFlush) > 0.4, isCurrent() {
                    entries = compose(fresh: freshByKey)
                    lastFlush = Date()
                }
            }
            if isCurrent() { entries = compose(fresh: freshByKey) }
        }

        // Superseded mid-flight: a newer load owns the screen now. Bail before
        // republishing this run's (older) row list over it.
        guard isCurrent() else { return }

        if isLoading { loadingStep = "Loading artwork…" }

        let ordered = fetched.sorted { $0.index < $1.index }
        // Per-row fallback, so one dead catalog can't blank its row and an
        // offline refresh can't blank the screen.
        entries = compose(fresh: freshByKey)

        // Persist fresh catalog items for the next cold start. Only real
        // add-on catalog rows (whose key maps back to a live catalog) are
        // cached; collection-derived rows re-resolve on next launch.
        var toCache: [String: [MetaItem]] = [:]
        for row in ordered {
            if let key = row.key, catalogByKey[key] != nil, case .catalog(let r) = row.entry {
                toCache[key] = r.items
            }
        }
        // A row that didn't answer this run is still on screen from cache —
        // carry its items forward, or saving here would drop it and the next
        // cold start would have nothing to paint for it.
        for (key, entry) in staleByKey where toCache[key] == nil {
            if catalogByKey[key] != nil, case .catalog(let r) = entry { toCache[key] = r.items }
        }
        if !toCache.isEmpty { HomeCatalogCache.save(toCache) }

        if initialHero == nil { initialHero = Self.firstHero(entries) }
        // Again with the live rows: the fresh top titles may differ from the
        // cached ones, and an already-cached URL costs a `fileExists` here.
        warmSpotlightArt()
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

    /// Pull the spotlight's backdrops into the image cache. Gated on the same
    /// switch as the poster prefetch — this is art that is not on screen yet.
    private func warmSpotlightArt() {
        guard PerformanceSettingsStore.shared.settings.artworkPrefetch else { return }
        let art = spotlightItems(max: 6).compactMap { $0.background ?? $0.poster }
        guard !art.isEmpty else { return }
        ImageCache.shared.warm(urls: art)
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

/// Fades the top of the row list out, so content scrolling up under a PINNED
/// hero dissolves into the stage instead of sliding out from behind it.
///
/// A mask rather than a colour scrim: the stage is `ATVBackground` — a wash
/// plus an accent bloom that changes with y — so any opaque strip painted over
/// it would show as a seam. Fading the content itself to transparent reveals
/// the real background underneath and can't mismatch.
///
/// Applied ONLY in the pinned layout. `scrollClipDisabled` (which the rows need
/// so a focused card's lift isn't cut off) is exactly what let them draw up
/// over the billboard in the first place, and a full-screen mask is an
/// offscreen compositing pass — not something to impose on the default layout
/// for a problem it doesn't have. Flipping `active` remounts the scroll view,
/// which only happens when the setting itself is toggled.
private struct HeroFadeMask: ViewModifier {
    let active: Bool

    /// How much of the strip above the scroll view a row dissolves across on
    /// its way under the billboard. In POINTS, not a fraction: the mask is
    /// deliberately larger than the view it masks, so a proportional stop
    /// would drift as that overhang changed.
    private static let fadeHeight: CGFloat = 60
    /// How far the mask spills PAST the scroll view's frame on the other three
    /// sides. tvOS keeps a title-safe inset, and `scrollClipDisabled` is what
    /// lets a row draw into it — which is where a poster's caption lands when
    /// the focused card is near the bottom. A mask sized to the frame clipped
    /// exactly that strip, so the titles and release dates under the last
    /// visible row vanished. The overhang keeps the fade at the top and leaves
    /// every other edge alone.
    private static let overhang: CGFloat = 260

    func body(content: Content) -> some View {
        if active {
            content.mask(
                VStack(spacing: 0) {
                    // The fade sits ENTIRELY ABOVE the scroll view's top edge,
                    // in the strip that `scrollClipDisabled` lets a row draw
                    // into as it rides up under the billboard. Everything from
                    // the top edge down is fully opaque.
                    //
                    // It was the other way round at first — the gradient ran
                    // downward FROM the top edge — which faded the first row's
                    // header and See All while they were sitting in perfectly
                    // ordinary, un-overlapped space. The only content that
                    // should be dimmed is the content actually behind the hero.
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                    Color.black
                }
                .padding(.top, -Self.fadeHeight)
                .padding(.bottom, -Self.overhang)
                .padding(.horizontal, -Self.overhang)
            )
        } else {
            content
        }
    }
}

/// True while the glass rail is auto-hidden and not currently summoned
/// (Layout → "Hide the sidebar"). Injected by RootView, which owns that state.
///
/// The hero needs it because it flanks its Play button with two invisible
/// focusable sentinels that turn LEFT/RIGHT into spotlight steps — and the
/// hero's Play button is where focus lands at launch. With the rail hidden,
/// the left sentinel swallowed the very press that is supposed to call the
/// rail back, so the first thing a viewer tried did nothing.
private struct RailIsHiddenKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var railIsHidden: Bool {
        get { self[RailIsHiddenKey.self] }
        set { self[RailIsHiddenKey.self] = newValue }
    }
}

/// A pinned Live TV channel on the home screen: its logo on a plate, sized to
/// match the poster rows around it rather than the wider Live TV tiles.
private struct HomeLiveChannelCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let favorite: FavoriteChannel

    private let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack {
                theme.palette.backgroundCard
                if let logo = favorite.logo {
                    RemoteImage(url: logo, contentMode: .fit, maxDimension: width)
                        .padding(OrivioSpacing.md)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )

            Text(favorite.name)
                .font(.system(size: 20, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .frame(width: width, alignment: .leading)
        }
        .focusLift(OrivioFocus.card, isFocused)
    }
}

/// The live billboard title, updated as focus moves across cards. Kept separate
/// from HomeViewModel and owned by HomeView WITHOUT observation, so its frequent
/// animated changes re-render only the billboard subviews — not the poster rows.
@MainActor
final class HeroFocus: ObservableObject {
    @Published var item: MetaItem?
    /// Continue-Watching context for the committed item (episode line,
    /// remaining time), committed atomically with `item` by themes whose hero
    /// surfaces it (Onyx). nil whenever the committed item isn't a CW card.
    @Published private(set) var progress: WatchProgress?
    /// Fetches full metadata for a bare item (Continue Watching rows only
    /// store name + art) — set by HomeView. Successful results are cached.
    var enrich: ((MetaItem) async -> MetaItem?)?
    /// Classic only enriches items with NO synopsis (CW cards). Themes whose
    /// hero shows fields catalog items never carry (Stremio board: runtime,
    /// cast) enrich every committed item instead — still debounced and cached.
    var enrichAlways = false
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
    /// True while the billboard trailer preview is playing (HeroTrailerLayer).
    /// Rotation holds — the trailer earned the spotlight by the viewer
    /// resting on this title, and swapping it mid-play is the same yank the
    /// idle window exists to prevent.
    var trailerPlaying = false

    /// Seed the rotation set and show its first title. Safe to call repeatedly;
    /// only re-seeds when the set actually changed.
    func setSpotlight(_ items: [MetaItem]) {
        guard items.map(\.id) != spotlight.map(\.id) else { return }
        spotlight = items
        spotlightIndex = 0
        // A fresh spotlight starts its dwell NOW. Left at .distantPast, the
        // first auto-advance fired the moment the idle gate opened (~6s in),
        // cutting the first title short — on the pinned billboard, right
        // after its trailer had finally started.
        lastRotation = Date()
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
        withAnimation(fade ? FusionMotion.heroCrossfade : nil) { item = next }
    }

    /// Timer tick: advance to the next spotlight title, but only if the user
    /// hasn't touched anything for a few seconds (so it never yanks the hero
    /// out from under someone browsing).
    ///
    /// NOT reachable from the PINNED hero, which never auto-advances at all
    /// (HomeView's tick skips it). The pinned billboard's whole contract is
    /// "show the title under the highlight", and a timer that moves it on is
    /// that contract broken: the trailer for the card you are sitting on
    /// played for a moment and then the art, name and synopsis all jumped to
    /// a title you had not selected. Browsing IS the only thing that changes
    /// a pinned billboard.
    func rotateIfIdle() {
        let now = Date()
        // Reduce Motion disables automatic rotation, exactly as FusionHeroBar
        // already does. Without it the billboard kept swapping every few
        // seconds — and because `heroCrossfadeEffective` is false under that
        // setting, it swapped as a HARD CUT, which is strictly worse for the
        // person the setting exists to protect. Manual stepping still works.
        guard !PerformanceSettingsStore.shared.reduceMotion,
              spotlight.count > 1, !heroButtonFocused, !trailerPlaying,
              now.timeIntervalSince(lastInteraction) > 6,
              now.timeIntervalSince(lastRotation) >= dwellSeconds else { return }
        lastRotation = now
        spotlightIndex = (spotlightIndex + 1) % spotlight.count
        let next = spotlight[spotlightIndex]
        let fade = PerformanceSettingsStore.shared.heroCrossfadeEffective
        withAnimation(fade ? FusionMotion.heroAutoRotate : nil) { item = next }
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

    func focus(_ newItem: MetaItem, progress newProgress: WatchProgress? = nil) {
        // Browsing cards counts as interaction — pause spotlight rotation.
        lastInteraction = Date()
        guard newItem.id != (pendingID ?? item?.id) else {
            // Same title, different context (catalog card ↔ its CW card):
            // nothing to decode, just swap the progress line.
            if progress?.id != newProgress?.id { progress = newProgress }
            return
        }
        task?.cancel()
        pendingID = newItem.id
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: settleNanos)   // let focus settle
            guard !Task.isCancelled else { return }
            let display = enriched[newItem.id] ?? newItem
            let fade = PerformanceSettingsStore.shared.heroCrossfadeEffective
            withAnimation(fade ? FusionMotion.heroCrossfade : nil) {
                item = display
                progress = newProgress
            }
            pendingID = nil
            // Bare item (no synopsis): fetch the full meta so the billboard
            // shows description/genres/rating, and swap it in if still current.
            guard enrichAlways || display.description == nil, let enrich,
                  enriched[display.id] == nil else { return }
            guard let full = await enrich(display), !Task.isCancelled,
                  self.item?.id == display.id else { return }
            enriched[display.id] = full
            withAnimation(fade ? FusionMotion.heroCrossfade : nil) { self.item = full }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var trakt: TraktStore

    /// The services collections can resolve from right now (see
    /// `CollectionProviders`). Collection rows always render; this only tells
    /// the loader what a collection opened from them will be able to fill.
    private var collectionProviders: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: trakt.isSignedIn)
    }
    // Owned by RootView so it PERSISTS across tab switches. If it were a local
    // @StateObject, switching away and back would rebuild HomeView with a fresh
    // (empty) model → a "Loading catalogs" spinner with no focusable element →
    // focus falls back to the sidebar, which reopened the panel.
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject private var liveFavorites = LiveChannelFavorites.shared

    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    var onResumeFromStart: (WatchProgress) -> Void = { _ in }
    /// Opens the source list (StreamsView) so the user picks a stream manually.
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Same, from a Continue Watching card's hold menu — takes the STORED row
    /// so the root can run the identity repair a resume gets (tmdb: → tt,
    /// "tv"-typed rows, dropped season/episode) before opening the picker.
    var onPlayManuallyProgress: (WatchProgress) -> Void = { _ in }
    let onOpenCollection: (OrivioCollection) -> Void
    /// A channel pinned to Home from the Live TV tab's hold menu.
    var onPlayChannel: (LiveChannel) -> Void = { _ in }
    var onSeeAll: (InstalledAddon, ManifestCatalog, String) -> Void = { _, _, _ in }
    /// Fires when the first load attempt finishes (success or error), so the
    /// root can re-enable the sidebar only once content exists to hold focus.
    var onContentReady: () -> Void = {}
    /// Called when Back is pressed at the START of a row (or on the hero/other
    /// non-row content): opens the sidebar (Classic) or focuses the tab bar
    /// (Fusion). Passed from RootView.
    var onHomeBack: () -> Void = {}

    private var layout: HomeLayout { homeCatalogSettings.homeLayout }

    /// Whether the hero chases card focus.
    ///
    /// OFF (the default): the spotlight stays on its rotating Top-10 title as
    /// you browse down. ON (Layout → "Pin hero to the top"): the hero is
    /// fixed above the rows and shows whatever card is highlighted — the
    /// rotation is switched off with it, since the two would otherwise fight
    /// over the same billboard.
    private var heroFollowsFocus: Bool { homeCatalogSettings.pinnedHero }

    /// The pinned hero sits OUTSIDE the scroll view, so the rows scroll under
    /// a billboard that stays put.
    private var heroIsPinned: Bool { perf.settings.heroBackdrop && homeCatalogSettings.pinnedHero }

    // Owned via @State (NOT @StateObject) so HomeView does NOT observe it —
    // hero changes must re-render only the billboard subviews, never the rows.
    @State private var hero = HeroFocus()
    /// Seeds initial focus onto the hero Play button once content exists. The
    /// rail boots disabled, and without an explicit landing spot the focus
    /// engine can end up holding NOTHING — then Menu falls through to tvOS and
    /// suspends the app.
    @FocusState private var heroPlayFocused: Bool
    /// Initial focus is seeded ONCE per mount. `reload()` also runs on every
    /// add-on / collection / catalog-settings change (account sync fires those
    /// in the background), and re-seeding there yanked focus out of whatever
    /// row you were browsing back up to the hero.
    @State private var didSeedHeroFocus = false
    /// Coalesces the launch burst of store publishes into one reload.
    @State private var reloadDebounce: Task<Void, Never>?
    @State private var nextUpContinueItems: [WatchProgress] = []
    /// metaID → how many episodes have aired since the viewer started that
    /// show and are still unwatched. Drives the green "+N" badge. Covers shows
    /// with a real progress row too, not just the synthesised Next Up cards.
    @State private var newEpisodeCounts: [String: Int] = [:]

    /// Drives the Apple TV hero's spotlight rotation. Ticks every 2s; the hero
    /// only advances when it's been idle for a few seconds (see rotateIfIdle).
    /// `.default`, NOT `.common`: a common-mode timer fires inside the
    /// run-loop tracking mode that focus/scroll animations run in, waking
    /// SwiftUI mid-scroll every 2s on the A8 for a check whose real pacing is
    /// the idle-dwell gate (see the HeroTrailerLayer watchdog note).
    private let spotlightTick = Timer.publish(every: 2, on: .main, in: .default).autoconnect()

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
            // §55: Reduce Motion disables automatic hero rotation (both
            // modes). The pinned hero cycles only while the viewer is resting
            // ON it — browsing cards drives it by focus instead, and a timer
            // swapping the highlighted title out from under someone browsing
            // is a bug, not a feature (see rotateIfIdle's pinnedBillboard).
            guard isVisible && !perf.reduceMotion, !heroIsPinned else { return }
            hero.rotateIfIdle()
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
                // Same gate the account-sync loops use: never fire a full
                // multi-addon catalog sweep (plus its poster prefetch) while
                // the home is covered or a stream is playing — that competed
                // with the movie for bandwidth mid-film.
                guard isVisible, !OrivioSyncManager.playbackActive else { continue }
                await viewModel.load(
                    addonManager: addonManager,
                    collections: collections,
                    settings: homeCatalogSettings,
                    providers: collectionProviders
                )
            }
        }
        // Eight separate triggers, ONE debounced reload. Each of these used to
        // fire its own unthrottled `reload()`, and at launch they arrive in a
        // burst: the first load runs, then the collections library finishes
        // decoding, then profile scoping republishes four settings at once — so
        // a cold start ran the whole catalog sweep two to four times over.
        .onChange(of: addonManager.addons) { _, _ in scheduleReload() }
        .onChange(of: collections.collections) { _, _ in scheduleReload() }
        // Collection rows render regardless, but a provider change still
        // reloads Home so anything downstream of the connections is fresh.
        .onChange(of: collectionProviders) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.orderKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.disabledKeys) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.customTitles) { _, _ in scheduleReload() }
        // Same reason as the three above: these three change what the loader
        // produces, and nothing else asked Home to rebuild when they flipped —
        // the row titles (and the unreleased filter) stayed stale.
        .onChange(of: homeCatalogSettings.catalogAddonNameEnabled) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.catalogTypeSuffixEnabled) { _, _ in scheduleReload() }
        .onChange(of: homeCatalogSettings.hideUnreleasedContent) { _, _ in scheduleReload() }
        .task(id: nextUpRefreshKey) { await refreshNextUpContinueItems() }
        // Paint the hero from the cached rows without waiting for the network.
        .onChange(of: viewModel.initialHero) { _, item in seedHero(item) }
    }

    /// Put a title in the billboard and land initial focus on its Play button.
    /// Idempotent and one-shot for focus: called both from the cache (early, via
    /// `onChange`) and after the live load, whichever happens first.
    private func seedHero(_ item: MetaItem?) {
        guard let item, hero.item == nil else { return }
        hero.item = item
        hero.setSpotlight(viewModel.spotlightItems(max: 10))
        // The PINNED hero has no Play button to land on — it is a display, and
        // its title is whatever the focused card is. Seeding focus at it would
        // be a request into a view that isn't in the tree, leaving the page
        // with nothing focused at all; let the first row take it instead.
        guard !didSeedHeroFocus, perf.settings.heroBackdrop, !heroIsPinned else { return }
        didSeedHeroFocus = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            heroPlayFocused = true
        }
    }

    private var layoutContent: some View { fusionModernLayout }

    private var fusionModernLayout: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: 0) {
                // Pinned: the hero is a fixed header the rows scroll beneath,
                // and it renders whichever card holds focus. A VStack rather
                // than an overlay, so the ScrollView is laid out in the space
                // that's LEFT and its content can't start underneath the
                // billboard.
                if heroIsPinned {
                    // 500, against the scrolling hero's 880: pinned, every
                    // point the billboard takes is a point the rows never get
                    // back. `ATVHeroInfoView` bottom-anchors its content inside
                    // its own box, so a shorter header lifts the whole billboard
                    // rather than cropping it — and those points go to the row
                    // below, where they are the difference between a focused
                    // card's release date being on screen and being cut off by
                    // the bottom edge.
                    FusionHeroHeader(hero: hero, onPlay: { heroSelect($0) },
                                     playFocus: $heroPlayFocused, height: 500,
                                     artCropBias: 0.75, showsTopBadge: false,
                                     playsTrailer: true, showsActions: false)
                        // NO `.focusSection()` here, unlike the scrolling
                        // banner. A section exists to give the engine a region
                        // to aim at, and with `showsActions: false` there is
                        // nothing focusable inside this one — an empty region
                        // is only something for focus resolution to trip over.
                        .ignoresSafeArea(edges: [.top, .horizontal])
                        // ABOVE the rows. `scrollClipDisabled` below lets row
                        // content draw outside the scroll view's bounds (that's
                        // what keeps a focused card's lift and shadow from
                        // being cut off), and a later sibling in a VStack draws
                        // on top — so without this the rows painted over the
                        // billboard as they scrolled up under it.
                        .zIndex(1)
                }

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                        if perf.settings.heroBackdrop && !heroIsPinned {
                            FusionHeroHeader(hero: hero, onPlay: { heroSelect($0) }, playFocus: $heroPlayFocused)
                                // Group the hero as its own focus section so a vertical
                                // UP from ANY card in the row below reaches it.
                                .focusSection()
                        }
                        // LAZY: with a signed-in account this list is dozens of
                        // rows; an eager VStack materializes every row body and
                        // rebuilds ALL of them on any parent re-render (measured
                        // before at ~40 row bodies per D-pad step vs 1.3 lazy) —
                        // that's the "super slow signed in" case.
                        LazyVStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                            rowsContent
                        }
                        // Rows keep a title-safe inset that also clears the
                        // floating glass rail; the hero (above) does not, so
                        // its art can bleed to the very edges.
                        .padding(.leading, 100)
                        .padding(.trailing, OrivioSpacing.lg)
                    }
                    // Under a pinned hero the first row would otherwise sit
                    // flush against the billboard's bottom edge.
                    .padding(.top, heroIsPinned ? OrivioSpacing.lg : 0)
                    // The pinned layout leaves ~520pt of viewport, and a poster
                    // row plus its caption very nearly fills it. The extra
                    // run-out gives the scroll somewhere to go, so the last
                    // row's title and release date can clear the bottom edge
                    // instead of being scrolled to the very limit and cut.
                    .padding(.bottom, heroIsPinned ? 160 : OrivioSpacing.huge)
                }
                // The whole scroll ignores the safe area so the hero backdrop fills
                // edge to edge (like the Detail page); rows re-inset themselves above.
                // NOT at the top when the hero is pinned — there the billboard owns
                // the top of the screen and the rows must start below it.
                .ignoresSafeArea(edges: heroIsPinned ? [.horizontal] : [.top, .horizontal])
                .scrollClipDisabled()
                .modifier(HeroFadeMask(active: heroIsPinned))
            }
        }
    }

    /// Coalesce a burst of store publishes into one reload. `loadIfNeeded` is
    /// fingerprint-guarded, so a redundant call is cheap — but only after it has
    /// already re-derived the whole request list, and at launch these arrive
    /// several at a time.
    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reload()
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
            settings: homeCatalogSettings,
            providers: collectionProviders
        )
        // Usually already done from the cache above; this covers a cold launch
        // where there was nothing to seed from.
        seedHero(viewModel.initialHero)
        // Re-seed the auto-rotating spotlight now the live rows are in, so it
        // cycles the fresh top titles rather than the cached ones.
        hero.setSpotlight(viewModel.spotlightItems(max: 10))
        onContentReady()
    }

    @ViewBuilder
    private var rowsContent: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            HomeLoadingBackdrop(step: viewModel.loadingStep)
                .frame(maxWidth: .infinity)
                .frame(height: 460)
        } else if let error = viewModel.loadError, viewModel.entries.isEmpty {
            VStack(spacing: OrivioSpacing.lg) {
                OrivioEmptyState(icon: "antenna.radiowaves.left.and.right.slash", title: "Nothing to show", message: error)
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

    @ViewBuilder
    private var rowsList: some View {
        let continueItems = mergedContinueItems()
        if !continueItems.isEmpty {
            continueRow(continueItems)
        }

        // §21: an inline hero bar between Continue Watching and the catalog
        // rows, sourced from a different row than the top spotlight. Two
        // gates: the performance switch (device) and the Layout pane's
        // "Featured section" toggle (per profile).
        if perf.settings.heroBackdrop && homeCatalogSettings.showFeaturedBar {
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

        // Channels pinned from Live TV (hold a channel → Favorite → Add to
        // Home Page). Below Continue Watching and below the Featured window,
        // which is where they were asked for.
        liveChannelsRow

        // Collections render by viewMode:
        // • ROWS      → each collection is its OWN row of folder buttons; a
        //               folder button opens that folder's discover page.
        // • FOLDERS/COMBINED → all share ONE "Collections" row of collection
        //               buttons (rendered at the first such collection's slot);
        //               a button opens that whole collection's discover/browse.
        let sharedCollections = viewModel.sharedCollections
        let firstSharedID = viewModel.firstSharedCollectionID

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
                        // The pinned hero follows categories too: the folder's
                        // backdrop (or the collection's) with its brand logo
                        // rendered whole — see `heroItem(for:in:)`. A folder
                        // with no art of its own still shows its name on the
                        // stage, which beats the billboard silently holding a
                        // title from three rows up.
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

    /// Live TV channels the viewer pinned to Home. Drawn from the stored
    /// favourites, so this needs neither the Live TV tab to have been visited
    /// nor the IPTV playlist to be loaded.
    @ViewBuilder
    private var liveChannelsRow: some View {
        let pinned = liveFavorites.homeChannels
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                RowHeader(title: "Live Channels")
                    .padding(.leading, OrivioSpacing.sm)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                        ForEach(pinned) { favorite in
                            Button { onPlayChannel(LiveChannel(favorite)) } label: {
                                HomeLiveChannelCard(favorite: favorite)
                                    // No hand-off handler — the note keeps the
                                    // router honest so leaving the rail from
                                    // here falls back to the engine instead of
                                    // teleporting to the last ROUTED row.
                                    .onFocusChange { if $0 { ContentFocusRouter.shared.noteFocused(row: "live") } }
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .channelHoldMenu(favorite)
                        }
                    }
                    .padding(.vertical, OrivioSpacing.lg)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Open one folder's discover page: a browse view scoped to just that
    /// folder (its content + Sort, no tabs), reusing the collection browser
    /// with a synthetic single-folder collection.
    private func openFolder(_ folder: OrivioCollectionFolder, in collection: OrivioCollection) {
        let single = HomeViewModel.folderCollection(folder, in: collection)
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
    private func heroItem(for collection: OrivioCollection) -> MetaItem {
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
    private func heroItem(for folder: OrivioCollectionFolder, in collection: OrivioCollection) -> MetaItem {
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

    /// Select on the hero. A real title opens its detail page; a collection
    /// stand-in (the pinned hero following a category) opens that collection
    /// or folder instead — its synthetic `collection:` id names nothing any
    /// meta add-on could serve, so routing it to the detail page would land on
    /// an empty screen.
    private func heroSelect(_ item: MetaItem) {
        guard item.type == "collection", item.id.hasPrefix("collection:") else {
            onSelect(item)
            return
        }
        let parts = item.id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let all = viewModel.entries.compactMap { entry -> OrivioCollection? in
            if case .collection(let c) = entry { return c }
            return nil
        } + viewModel.sharedCollections
        guard let collection = all.first(where: { $0.id == parts[1] }) else { return }
        if parts.count == 3, let folder = collection.folders.first(where: { $0.id == parts[2] }) {
            openFolder(folder, in: collection)
        } else {
            onOpenCollection(collection)
        }
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
            onPlayManuallyMenu: { onPlayManuallyProgress($0) },
            onResumeFromStartMenu: { onResumeFromStart($0) },
            onBackAtStart: onHomeBack
        )
    }

    private var nextUpRefreshKey: String {
        // CHEAP. This is a `.task(id:)` key recomputed on every Home body
        // pass; it used to sort-and-join the full watch history (a ~100KB
        // string after a Trakt import) plus a full Continue Watching sort,
        // twice over per invalidation. An order-insensitive hash of the same
        // inputs changes exactly when they do, for a few microseconds.
        var watchedHash = 0, progressHash = 0, dismissedHash = 0
        for key in watched.items.keys { watchedHash ^= key.hashValue }
        for item in progressStore.continueWatching(sortMode: .recentlyWatched) {
            progressHash ^= item.id.hashValue &+ Int(item.positionSeconds)
        }
        for show in progressStore.dismissedNextUpShows { dismissedHash ^= show.hashValue }
        return "\(watchedHash)#\(progressHash)#\(homeCatalogSettings.showUnairedNextUp)#\(dismissedHash)"
    }

    private func mergedContinueItems() -> [WatchProgress] {
        let active = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
        let activeMetaIDs = Set(active.map(\.metaID))
        // Also filtered here, not only in the async refresh: `removeShow` on a
        // synthesised card has no progress rows to delete, so the card would sit
        // on screen until the refresh re-ran — and that does up to twenty
        // sequential metadata fetches first.
        let additions = nextUpContinueItems.filter {
            !activeMetaIDs.contains($0.metaID)
                && !progressStore.dismissedNextUpShows.contains($0.metaID)
        }
        // Synthesised Next Up rows already carry their count; stamp the ones
        // with a real progress row here. Doing it on the row (rather than
        // passing the map down) keeps `ContinueWatchingCell`'s Equatable
        // comparison honest — the card re-renders when the number changes.
        let stamped = active.map { row -> WatchProgress in
            guard let count = newEpisodeCounts[row.metaID] else { return row }
            var copy = row
            copy.newEpisodeCount = count
            return copy
        }
        return stamped + additions
    }

    /// One show this pass needs metadata for.
    ///
    /// Two kinds, fetched together in a single bounded pass: shows that are
    /// ALREADY in Continue Watching (metadata is needed only to count their
    /// new episodes) and shows the viewer has watched but has no progress row
    /// for (which additionally get a synthesised Next Up card).
    private struct NextUpTarget {
        let contentID: String
        let contentType: String
        let lastWatchedAt: Date
        let wantsCard: Bool
    }

    private func refreshNextUpContinueItems() async {
        let activeRows = progressStore.continueWatching(sortMode: homeCatalogSettings.continueWatchingSortMode)
        let activeMetaIDs = Set(activeRows.map(\.metaID))
        // Series already on the row. No card is synthesised for these — they
        // have a real progress row — but they still need their episode list so
        // the "+N new episodes" badge can be computed for them.
        let activeSeries = activeRows
            .filter { $0.season != nil && ($0.type == "series" || $0.type == "tv") }
            .prefix(20)
            .map { NextUpTarget(contentID: $0.metaID, contentType: $0.type,
                                lastWatchedAt: $0.updatedAt, wantsCard: false) }

        let watchedSeries = watched.items.values
            .filter { ($0.contentType == "series" || $0.contentType == "tv") && $0.season != nil && $0.episode != nil }
            .sorted { $0.watchedAt > $1.watchedAt }
            .deduplicatedByContentID()
            .filter { !activeMetaIDs.contains($0.contentID) }
            // Removed from Continue Watching means removed, including the
            // synthesised suggestion that would otherwise replace the card.
            .filter { !progressStore.dismissedNextUpShows.contains($0.contentID) }
            .prefix(20)
            .map { NextUpTarget(contentID: $0.contentID, contentType: $0.contentType,
                                lastWatchedAt: $0.watchedAt, wantsCard: true) }

        let targets = activeSeries + watchedSeries
        // When the viewer first STARTED each show, and how far they have got.
        // Built once, off the per-show loop, from data that already syncs
        // everywhere (see `startedWatchingByShow`).
        let startedAt = startedWatchingByShow()
        let reached = reachedEpisodesByShow()

        // Bounded-concurrent, not serial. These are full-series metadata
        // responses — among the largest payloads in the app — and fetching up to
        // twenty of them one after another meant ten to twenty seconds on a cold
        // cache before a single Next Up card appeared. `boundedConcurrentMap`
        // preserves order, and the result is re-sorted below anyway.
        let fetched = await boundedConcurrentMap(
            targets, limit: AddonSweepLimits.catalogs
        ) { target -> (meta: MetaItem, target: NextUpTarget)? in
            guard let addon = addonManager.metaAddon(for: target.contentType, id: target.contentID),
                  let meta = try? await StremioAPI.meta(
                      addon: addon, type: target.contentType, id: target.contentID
                  )
            else { return nil }
            return (meta, target)
        }
        // The episode walking below is pure computation over the fetched
        // metas — up to 40 FULL series' episode lists, each walked several
        // times with per-episode date parses. Snapshot what it needs from the
        // main-actor stores (cheap: a key set and two bools), then run it
        // detached; only the publish hops back. On an A8 this loop used to be
        // hundreds of milliseconds ON the main actor at every launch and
        // after every watched/progress mutation.
        let watchedKeys = Set(watched.items.keys)
        let showUnaired = homeCatalogSettings.showUnairedNextUp
        let fromFurthest = homeCatalogSettings.nextUpFromFurthestEpisode
        let entries = fetched.compactMap { $0 }
        let (rows, counts) = await Task.detached(priority: .userInitiated) {
            var rows: [WatchProgress] = []
            var counts: [String: Int] = [:]
            for entry in entries {
                // Keyed by the CANONICAL id the watch/progress stores use, not
                // the id the meta addon echoed back — a fallback meta addon can
                // answer with its own scheme (tvdb:, anidb:…), and rows/badges
                // keyed by that never matched the stores (badge missing) and
                // resumed into a sources page no stream addon claims.
                let contentID = entry.target.contentID
                let count = Self.newEpisodeCount(in: entry.meta,
                                                 startedAt: startedAt[contentID],
                                                 reached: reached[contentID] ?? [])
                if count > 0 { counts[contentID] = count }
                guard entry.target.wantsCard,
                      let next = Self.nextUpEpisode(in: entry.meta, contentID: contentID,
                                                    watchedKeys: watchedKeys,
                                                    showUnaired: showUnaired,
                                                    fromFurthest: fromFurthest) else { continue }
                rows.append(Self.nextUpProgress(meta: entry.meta, contentID: contentID, episode: next,
                                                lastWatchedAt: entry.target.lastWatchedAt,
                                                newEpisodeCount: count))
            }
            return (rows, counts)
        }.value
        if !Task.isCancelled {
            nextUpContinueItems = rows
            newEpisodeCounts = counts
        }
    }

    /// metaID → when this viewer first watched anything of that title.
    ///
    /// Derived rather than stored, from the two things that already sync
    /// everywhere: watch history (account, Trakt, SIMKL, Stremio) and stored
    /// playback positions. That is what makes the badge agree across devices
    /// without a new synced field — and it means an imported Trakt history,
    /// which carries each episode's ORIGINAL watch time, gives the true start
    /// date rather than the import date.
    private func startedWatchingByShow() -> [String: Date] {
        var out: [String: Date] = [:]
        for item in watched.items.values {
            if let existing = out[item.contentID], existing <= item.watchedAt { continue }
            out[item.contentID] = item.watchedAt
        }
        for row in progressStore.items.values {
            if let existing = out[row.metaID], existing <= row.updatedAt { continue }
            out[row.metaID] = row.updatedAt
        }
        return out
    }

    /// metaID → every episode the viewer has reached, watched or merely
    /// started. "Reached" deliberately includes a part-watched episode: the
    /// one you are in the middle of is not something you are behind on.
    ///
    /// A SET rather than a single furthest point, because the furthest point
    /// has to be resolved against AIR DATES, which only the metadata knows —
    /// see `newEpisodeCount`.
    private func reachedEpisodesByShow() -> [String: Set<SeasonEpisode>] {
        var out: [String: Set<SeasonEpisode>] = [:]
        func offer(_ id: String, _ season: Int?, _ episode: Int?) {
            guard let season, let episode else { return }
            out[id, default: []].insert(SeasonEpisode(season: season, episode: episode))
        }
        for item in watched.items.values { offer(item.contentID, item.season, item.episode) }
        for row in progressStore.items.values { offer(row.metaID, row.season, row.episode) }
        return out
    }

    /// How many episodes are waiting AHEAD of the viewer that aired after they
    /// started the show.
    ///
    /// Two conditions, and both are load-bearing:
    ///
    /// * **After the furthest episode they have reached.** Counting every
    ///   unwatched episode would include the one they are 60% of the way
    ///   through, so a show you are actively keeping up with would claim you
    ///   were behind on it.
    /// * **Aired after they started the show.** Working through a back
    ///   catalogue is not being behind, and without this a series that
    ///   finished years ago would sit at a permanent "+49" from the moment
    ///   someone started episode one.
    ///
    /// An episode with no known air date is skipped rather than assumed new.
    private nonisolated static func newEpisodeCount(in meta: MetaItem, startedAt: Date?,
                                                    reached: Set<SeasonEpisode>) -> Int {
        guard let startedAt, !reached.isEmpty else { return 0 }
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return 0 }
        let now = Date()

        // The furthest episode reached that has ACTUALLY AIRED. Unaired
        // episodes are excluded from this even when they carry a watched row:
        // an episode that has not been broadcast cannot have been watched, and
        // "Mark Season Watched" used to stamp every episode a season lists,
        // including next month's finale. Taking those at face value pinned the
        // furthest point at the end of the season, so the show could never
        // report a new episode again.
        var furthest: SeasonEpisode?
        for episode in all {
            guard let season = episode.season, let number = episode.episode else { continue }
            guard let aired = episode.airedDate, aired <= now else { continue }
            let point = SeasonEpisode(season: season, episode: number)
            guard reached.contains(point) else { continue }
            if furthest == nil || point > furthest! { furthest = point }
        }
        guard let furthest else { return 0 }

        return all.reduce(into: 0) { total, episode in
            guard let season = episode.season, let number = episode.episode else { return }
            guard SeasonEpisode(season: season, episode: number) > furthest else { return }
            guard let aired = episode.airedDate, aired > startedAt, aired <= now else { return }
            total += 1
        }
    }

    private nonisolated static func nextUpEpisode(in meta: MetaItem, contentID: String,
                                                  watchedKeys: Set<String>,
                                                  showUnaired: Bool,
                                                  fromFurthest: Bool) -> MetaVideo? {
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return nil }

        func isWatched(_ episode: MetaVideo) -> Bool {
            // The canonical store id, not `meta.id` — a fallback meta addon
            // can echo its own id scheme, and history is not keyed by that.
            // (`watchedKeys` is a snapshot of the watched store's keys, taken
            // on the main actor by the caller.)
            watchedKeys.contains(WatchedItem.key(contentID: contentID,
                                                 season: episode.season ?? 0,
                                                 episode: episode.episode))
        }
        // "Show unaired Next Up" was in this row's refresh key but never in the
        // selection, so Home offered an episode airing next week — with no
        // streams behind it — while Detail's Play button, which does honour the
        // setting, offered something watchable for the very same show.
        func isEligible(_ episode: MetaVideo) -> Bool {
            showUnaired || episode.hasAired
        }

        if fromFurthest,
           let furthestIndex = all.lastIndex(where: isWatched),
           furthestIndex + 1 < all.endIndex {
            return all[(furthestIndex + 1)...].first(where: isEligible)
        }

        return all.first { !isWatched($0) && isEligible($0) }
    }

    private nonisolated static func nextUpProgress(meta: MetaItem, contentID: String, episode: MetaVideo,
                                                   lastWatchedAt: Date, newEpisodeCount: Int) -> WatchProgress {
        // The canonical show id + a canonical episode key under it. Using the
        // addon-echoed `meta.id`/`episode.id` made the synthesised row an
        // identity no other store row (or stream addon) matched. Only tt ids
        // take the `show:season:episode` form — exotic schemes (kitsu: …)
        // shape their episode ids differently, so keep theirs.
        var episodeID = episode.id
        if contentID.hasPrefix("tt"), let s = episode.season, let e = episode.episode {
            episodeID = "\(contentID):\(s):\(e)"
        }
        return WatchProgress(
            id: episodeID,
            metaID: contentID,
            type: "series",
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
            newEpisodeCount: newEpisodeCount
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
                .padding(.trailing, OrivioSpacing.huge)
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
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            catalogHeader(row)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: homeCatalogSettings.posterSize.posterWidth,
                                             maximum: homeCatalogSettings.posterSize.posterWidth),
                                   spacing: OrivioSpacing.lg, alignment: .top)],
                alignment: .leading,
                spacing: OrivioSpacing.xl
            ) {
                ForEach(row.items) { item in
                    // Grid shows no billboard, so it deliberately does NOT
                    // drive the hero — that per-focus enrich fetch was firing
                    // a network request on every D-pad move and is what made
                    // grid navigation lag.
                    GridPosterCell(
                        item: item,
                        captionWidth: homeCatalogSettings.posterSize.posterWidth,
                        onSelect: onSelect,
                        onPlayManually: onPlayManually
                    )
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.vertical, OrivioSpacing.md)
            // No .focusSection() — a LazyVGrid already preserves the column on
            // vertical moves, and the section wrapper made cross-grid moves
            // re-home to a center poster ("focus goes to the middle").
        }
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
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            header
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
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
                                showLabel: homeCatalogSettings.showPosterLabels,
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
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.lg)
                }
                .scrollClipDisabled()
                // No .focusSection() here: it blocks the card's long-press hold
                // menu on tvOS (verified). Full poster rows never get skipped on
                // vertical moves anyway (there's always a card under any column),
                // so the "never skip" fix only needs the SPARSE rows (collections).
                // Back: jump to the first card if scrolled in; on the first
                // card, bubble up (sidebar / tab bar).
                .onExitCommand { backToStart(proxy) }
                // Coming back out of the rail lands on THIS row's first card
                // when this was the row the viewer left (ContentFocusRouter).
                // Re-registered whenever the first card CHANGES, not just on
                // appear: the handler captures the id, and Home rows are
                // replaced in place by refreshes and sync pulls — a stale
                // handler scrolled to a card that no longer exists and its
                // focus write was silently dropped.
                .onAppear { registerRowHandler(proxy) }
                .onChange(of: row.items.first?.id) { _, _ in registerRowHandler(proxy) }
                .onDisappear { ContentFocusRouter.shared.unregister(row.id) }
                .onChange(of: focusedID) { _, new in
                    if new != nil { ContentFocusRouter.shared.noteFocused(row: row.id) }
                }
            }
        }
    }

    private func registerRowHandler(_ proxy: ScrollViewProxy) {
        let firstID = row.items.first?.id
        ContentFocusRouter.shared.register(row.id) {
            guard let first = firstID else { return false }
            // Retry until the card actually holds focus: deep in the row the
            // first card is unloaded, and it takes the scroll a few ticks to
            // materialize it on the slower boxes.
            ContentFocusRouter.land(assign: {
                proxy.scrollTo(first, anchor: .leading)
                focusedID = first
            }, landed: { focusedID == first },
               focusToken: { focusedID })
            return true
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
                .padding(.trailing, OrivioSpacing.huge)
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
    /// Settings → Layout → Posters → "Poster labels".
    ///
    /// A PROPERTY, not an `@EnvironmentObject`: this cell is `Equatable` and is
    /// rendered through `.equatable()`, so SwiftUI skips the body whenever `==`
    /// says nothing changed. An environment read would be invisible to that
    /// comparison and the row would keep its captions until something else
    /// forced a rebuild. Included in `==` below for the same reason.
    let showLabel: Bool
    let heroFollowsFocus: Bool
    let hero: HeroFocus
    let onSelect: (MetaItem) -> Void
    let onPlayManually: (MetaItem, MetaVideo?) -> Void
    @State private var focused = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.useLandscape == rhs.useLandscape
            && lhs.captionWidth == rhs.captionWidth
            && lhs.showLabel == rhs.showLabel
            && lhs.heroFollowsFocus == rhs.heroFollowsFocus
    }

    var body: some View {
        let _ = HoldProbe.renderTick("poster \(item.name)")
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
                            showsCaption: false
                        )
                    } else {
                        PosterCard(item: item)
                    }
                }
                .onFocusChange { isFocused in
                    focused = isFocused
                    if isFocused, PerformanceSettingsStore.shared.settings.showHoldProbe {
                        HoldProbe.log("focus — poster \(item.name)")
                    }
                    if isFocused && heroFollowsFocus { hero.focus(item) }
                }
            }
            .mediaCardButtonStyle()
            .holdProbe("poster \(item.name)", enabled: PerformanceSettingsStore.shared.settings.showHoldProbe)
            .posterHoldMenu(item) { onSelect(item) }
            .onPlayPauseCommand { onPlayManually(item, nil) }

            if showLabel {
                ATVCardCaption(
                    title: item.name,
                    subtitle: item.year,
                    width: captionWidth,
                    lowered: focused,
                    dropDistance: useLandscape ? 13 : 18
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
    private static let routerID = "row.continueWatching"

    private func registerRowHandler(_ proxy: ScrollViewProxy) {
        let firstID = items.first?.id
        ContentFocusRouter.shared.register(Self.routerID) {
            guard let first = firstID else { return false }
            ContentFocusRouter.land(assign: {
                proxy.scrollTo(first, anchor: .leading)
                focusedCWCard = first
            }, landed: { focusedCWCard == first },
               focusToken: { focusedCWCard })
            return true
        }
    }

    var body: some View {
        // Focus model mirrors HomePosterRow (plain @FocusState, no .focusScope /
        // .focusSection).
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            RowHeader(title: "Continue Watching")
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // Wider gap than the poster rows (.xl, not .lg): these cards
                // are 380pt landscape stills, so the 1.05 focus lift adds
                // ~9.5pt per side — at .lg the lifted card sat nearly flush
                // against its unlifted neighbours.
                LazyHStack(alignment: .top, spacing: OrivioSpacing.xl) {
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
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.vertical, OrivioSpacing.lg)
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
            // Coming back out of the rail lands on the first card when this
            // was the row the viewer left (ContentFocusRouter). Re-registered
            // when the first card changes — Continue Watching reorders on
            // every sync pull, and a handler holding the old first id dropped
            // its focus write on the floor.
            .onAppear { registerRowHandler(proxy) }
            .onChange(of: items.first?.id) { _, _ in registerRowHandler(proxy) }
            .onDisappear { ContentFocusRouter.shared.unregister(Self.routerID) }
            .onChange(of: focusedCWCard) { _, new in
                if new != nil { ContentFocusRouter.shared.noteFocused(row: Self.routerID) }
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
    @State private var focused = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.progress == rhs.progress
            && lhs.imageURL == rhs.imageURL
            && lhs.subtitle == rhs.subtitle
            && lhs.blur == rhs.blur
            && lhs.drivesHero == rhs.drivesHero
    }

    var body: some View {
        let _ = HoldProbe.renderTick("CW \(progress.name)")
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
                    newEpisodeCount: progress.newEpisodeCount ?? 0,
                    blurImage: blur,
                    // Caption goes BELOW the platter (see below) so it isn't
                    // bridged to the still by the slab.
                    showsCaption: false
                )
                // Hero bar follows focus here too, like every other row.
                // Inside the label: `\.isFocused` only resolves within the
                // focusable Button, not around it.
                .onFocusChange { isFocused in
                    focused = isFocused
                    if isFocused, PerformanceSettingsStore.shared.settings.showHoldProbe {
                        HoldProbe.log("focus — CW \(progress.name)")
                    }
                    if isFocused, drivesHero { hero.focus(heroItemFor(progress)) }
                }
            }
            // Was FlatCardButtonStyle, under a comment claiming the native
            // platter "swallows contextMenu" on landscape cards. That claim was
            // wrong, but so was the theory that replaced it: the button style
            // had nothing to do with the hold menu (see the FusionHeroBar
            // artwork note — a hit-testable backdrop was covering this row).
            // Kept on the platter purely so this card lifts and catches the
            // sheen like every other one.
            .mediaCardButtonStyle()
            .holdProbe("CW \(progress.name)", enabled: PerformanceSettingsStore.shared.settings.showHoldProbe)
            .continueHoldMenu(progress, onDetails: onDetails,
                              onPlayManually: onPlayManuallyMenu,
                              onResumeFromStart: onResumeFromStartMenu)
            // ⏯ resumes instantly from a focused CW card too.
            .onPlayPauseCommand { onResume(progress) }

            ATVCardCaption(
                title: progress.name,
                subtitle: subtitle,
                width: 380,
                lowered: focused,
                dropDistance: 13
            )
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
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            // Holds focus while Home has nothing else to: with NOTHING focused a
            // Menu press falls through to tvOS and suspends the app.
            FocusAnchor()
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                HStack(spacing: OrivioSpacing.md) {
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
        .padding(OrivioSpacing.huge)
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
        HStack(spacing: OrivioSpacing.sm) {
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
        .focusLift(OrivioFocus.card, isFocused)
        .animation(PerformanceSettingsStore.shared.buttonMotion(FusionMotion.focusEntry),
                   value: isFocused)
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
        .padding(.horizontal, OrivioSpacing.md)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : Color.primary.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .focusLift(OrivioFocus.card, isFocused)
        .animation(PerformanceSettingsStore.shared.buttonMotion(FusionMotion.focusEntry),
                   value: isFocused)
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
            // …and the mirror: a cell that leaves the tree (a lazy row
            // unloading it, a reload remounting the row) never gets the
            // false, so its caption stayed "lowered" — a card that read as
            // focused while the card actually under focus only moved its
            // name and date. Reset on the way out; `onAppear` re-seeds a
            // card that comes back already focused.
            .onDisappear {
                action(false)
            }
    }
}

// MARK: - Billboard (isolated so hero updates don't re-render the rows)

/// Fusion (§22.1): the Classic home layout's shallow "backdrop sliver" —
/// artwork confined to the upper-right of a 300pt band, faded hard into the
/// background, with only a compact title label (no synopsis, no buttons).
/// Classic is meant to feel lighter/faster than Modern's full spotlight.
/// Netflix-style billboard preview: once the hero has RESTED on one title for
/// a few seconds, its trailer fades in behind the info block — muted, looping,
/// and strictly decorative — and the still art returns the moment the hero
/// moves on.
///
/// Reuses the Detail page's whole trailer stack (TMDB key lookup, YouTubeKit
/// extraction, `BackdropVideoView`) and its switches: the Detail page's
/// auto-play delay doubles as the rest time here (0 = off), the TMDB
/// "trailers" enrichment switch is where the keys come from, and Reduce
/// Motion keeps the still art. The player layer is decoration — no hit
/// testing, no user interaction — per the hard-won focus rule (a focusable
/// or hit-testable layer inserted mid-browse makes the engine re-resolve
/// and throws the highlight).
private struct HeroTrailerLayer: View {
    @ObservedObject var hero: HeroFocus
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore

    @State private var player: AVPlayer?
    @State private var visible = false
    @State private var loopToken: NSObjectProtocol?
    /// Fires when the player actually starts rendering — see `run()`.
    @State private var statusObserver: NSKeyValueObservation?
    /// Whether THIS layer activated the audio session (sound on) — teardown
    /// only deactivates what it activated, and never out from under the real
    /// player or a Picture in Picture session.
    @State private var activatedAudio = false

    var body: some View {
        // MOUNTED ALWAYS, revealed by opacity. `if visible { ... }` inserted
        // and removed a UIViewRepresentable in the middle of a browse, and the
        // focus engine re-resolves on a view-tree change like that: the lift
        // could be left stranded on the card the viewer had already stepped
        // off, while the caption (plain @State) tracked the new one. Opacity
        // is a pure render change and touches neither the tree nor focus.
        ZStack {
            BackdropVideoView(player: player)
                .allowsHitTesting(false)
                .opacity(visible ? 1 : 0)
        }
        .task(id: hero.item?.id) { await run() }
        .onDisappear { teardown() }
        // Layout toggles apply to a preview already on screen too, not just
        // the next one.
        .onChange(of: homeCatalogSettings.heroTrailersEnabled) { _, enabled in
            if !enabled { teardown() }
        }
        .onChange(of: homeCatalogSettings.heroTrailerSound) { _, sound in
            guard let player else { return }
            setSound(sound, on: player)
        }
        // Backgrounding pauses the muted player for good; resume on return.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in player?.play() }
        // A pinned Live TV channel starts the real player straight FROM Home,
        // with no push to fire `onDisappear` — don't keep a second decoder
        // looping behind the movie.
        // A `.task` gated on `player`, not a timer publisher: the old
        // `.onReceive(Timer.publish…)` built a fresh publisher on every body
        // evaluation (this layer re-renders on every settled hero change), so
        // the watchdog ticked for the life of Home even with no trailer
        // playing — and each rebuild could reset its 3s deadline. This one
        // exists only while a trailer player does.
        .task(id: player != nil) {
            guard player != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if OrivioSyncManager.playbackActive { teardown(); break }
            }
        }
    }

    /// How long the hero has to hold one title before the trailer pipeline
    /// commits. A DEBOUNCE, not a Netflix-style idle wait: the resolve runs
    /// ALONGSIDE it, so time-to-motion is `max(debounce, resolve)` and every
    /// tenth of a second here is a tenth added to a preview that already
    /// waits on the network. Kept only long enough that stepping across a row
    /// doesn't fire a TMDB lookup and a YouTube extraction per card.
    private static let restDebounce: TimeInterval = 0.5

    /// Give up on a resolve that has taken this long. Past it the viewer has
    /// been looking at a still for so long that a preview snapping in reads
    /// as a glitch rather than a flourish — and the extraction is very likely
    /// wedged behind a slow remote fallback.
    private static let resolveTimeout: TimeInterval = 12

    private func run() async {
        teardown()
        guard let item = hero.item, item.type != "collection" else { return }
        guard homeCatalogSettings.heroTrailersEnabled else { return }
        guard !perf.reduceMotion,
              tmdbSettings.settings.isUsable, tmdbSettings.settings.useTrailers else { return }
        // The WHOLE pipeline — TMDB key lookup AND the YouTube extraction —
        // overlaps the rest delay. It was only the key lookup at first, with
        // extraction serialized after the sleep, and extraction is the slow
        // half: the preview routinely started seconds after the delay ended,
        // which reads as "the trailer takes too long". Now the wait is
        // max(delay, resolve) instead of delay + resolve, and a repeat visit
        // (TrailerResolver's URL cache) resolves in milliseconds.
        let t0 = Date()
        async let prepared: AVPlayerItem? = {
            guard let key = await TMDBService.firstTrailerKey(id: item.id, type: item.type)
            else { return nil }
            NSLog("[OrivioHeroTrailer] key %@ resolved in %.2fs", key, Date().timeIntervalSince(t0))
            let r = await TrailerResolver.backdropItem(youtubeKey: key)
            NSLog("[OrivioHeroTrailer] item ready in %.2fs (nil=%@)", Date().timeIntervalSince(t0), r == nil ? "y" : "n")
            return r
        }()
        try? await Task.sleep(for: .seconds(Self.restDebounce))
        guard !Task.isCancelled, !PiPHandoff.shared.isActive,
              !OrivioSyncManager.playbackActive else { return }
        guard let avItem = await prepared, !Task.isCancelled else { return }
        guard Date().timeIntervalSince(t0) < Self.resolveTimeout else {
            NSLog("[OrivioHeroTrailer] gave up after %.2fs", Date().timeIntervalSince(t0))
            return
        }
        // Small buffer target + play-when-ready: first frames on screen as
        // soon as the stream can sustain them, rather than after AVPlayer's
        // default (much larger) buffer fills.
        avItem.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: avItem)
        // Muted by default: no audio session is needed then — activating one
        // would duck whatever music another app is playing, for a silent
        // preview. Layout → "Hero trailer sound" opts into the session.
        setSound(homeCatalogSettings.heroTrailerSound, on: p)
        p.actionAtItemEnd = .none
        loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.playImmediately(atRate: 1)
        }
        player = p
        // Reveal on the FIRST FRAME, not on the call to play(). Fading the
        // layer in at `play()` put an empty (black) video layer over the
        // artwork for however long the stream took to buffer — a black hole
        // where the backdrop had been, which is a good part of what "takes
        // too long to start" looked like. `.playing` is AVPlayer saying
        // frames are actually flowing.
        statusObserver = p.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            guard observed.timeControlStatus == .playing else { return }
            Task { @MainActor in
                guard player === observed else { return }   // a later title won the layer
                hero.trailerPlaying = true
                NSLog("[OrivioHeroTrailer] first frame at %.2fs", Date().timeIntervalSince(t0))
                withAnimation(.easeInOut(duration: 0.45)) { visible = true }
            }
        }
        p.playImmediately(atRate: 1)
    }

    /// Un-muting needs an ACTIVE audio session or a raw AVPlayer on tvOS can
    /// stall outright; muting hands the session back (so another app's music
    /// resumes) — but never touches a session the real player or a Picture in
    /// Picture window owns.
    private func setSound(_ sound: Bool, on player: AVPlayer) {
        if sound {
            if !PiPHandoff.shared.isActive, !OrivioSyncManager.playbackActive {
                try? AVAudioSession.sharedInstance().setActive(true)
                activatedAudio = true
            }
            player.isMuted = false
        } else {
            player.isMuted = true
            releaseAudioIfHeld()
        }
    }

    private func releaseAudioIfHeld() {
        guard activatedAudio else { return }
        activatedAudio = false
        // Never while real playback owns the session — deactivating it there
        // stops the movie's (or PiP window's) audio dead.
        guard !PiPHandoff.shared.isActive, !OrivioSyncManager.playbackActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardown() {
        hero.trailerPlaying = false
        visible = false
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        // Clear the item, not just pause — a paused muted player otherwise
        // stays the system "Now Playing" target and the transport overlay
        // pops up over Home on a Play/Pause press (same as the Detail page).
        player?.replaceCurrentItem(with: nil)
        player = nil
        releaseAudioIfHeld()
        if let loopToken {
            NotificationCenter.default.removeObserver(loopToken)
            self.loopToken = nil
        }
    }
}

private struct FusionHeroHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var hero: HeroFocus
    let onPlay: (MetaItem) -> Void
    var playFocus: FocusState<Bool>.Binding
    /// Tall like the Detail page's backdrop — the art dominates the first
    /// screen, with the first content row peeking at the very bottom.
    var height: CGFloat = 880
    /// Where the visible slice of the backdrop sits. 0 = the middle of the
    /// image (what a plain aspect-fill gives you); 1 = its very top.
    ///
    /// Only matters when the band is SHORT. A 16:9 backdrop in a 1920x880
    /// header shows 81% of the image and a centre crop is fine, but the same
    /// art in the pinned hero's 1920x500 band shows 46% — a horizontal slice
    /// through the middle of the frame, which on a standing figure is a torso
    /// with the head cut off. Biasing the slice upward gets the composed part
    /// of the shot back without shrinking the art (nothing can show MORE of a
    /// 16:9 image across a 3.84:1 window while still filling the width).
    var artCropBias: CGFloat = 0
    /// The "TOP 10" eyebrow belongs to the rotating spotlight. The pinned hero
    /// shows whatever is highlighted — often not a top-ten title at all — so it
    /// passes false.
    var showsTopBadge = true
    /// Only the PINNED hero plays a billboard trailer. The default rotating
    /// banner stays still art — a preview restarting on every 9s rotation would
    /// never get going, and the viewer never asked the banner to move.
    var playsTrailer = false
    /// The Play button and the spotlight dots. The pinned hero has neither: it
    /// mirrors the card the viewer is already sitting on, so a "Go to Movie"
    /// button is a second way to open the thing under their thumb, and the
    /// dots count a rotation the viewer is not driving.
    var showsActions = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Full-bleed backdrop (the scroll ignores the safe area, so this
            // fills the whole screen width like the Detail-page backdrop).
            // The art's ALPHA fades out toward the bottom so the shared
            // ATVBackground stage shows through — an opaque blend color can
            // never match the stage's bloom and always left a seam line.
            GeometryReader { geo in
                // The subtree KEEPS ITS SHAPE whether or not the committed
                // item has art. `if let art { …everything… }` used to wrap the
                // trailer layer too, so committing an art-less item (a
                // collection-folder hero stand-in) tore the BackdropVideoView
                // representable out of the tree and re-inserted it on the
                // next commit — a UIKit focus re-resolve landing 60–220ms
                // after a focus move, mid-raise: the stranded-platter bug
                // HeroTrailerLayer's own MOUNTED-ALWAYS note describes. Only
                // the plain RemoteImage is conditional now.
                let art = hero.item?.background ?? hero.item?.poster
                // Two frames, not an offset. `RemoteImage` fills the frame
                // it is GIVEN, so the only way to move the crop is to fill
                // a taller frame (which recentres the slice further down the
                // image) and then take the TOP of that. Offsetting the
                // finished view instead would drag its clip rect along with
                // it and just leave a gap.
                //
                // The taller frame's extra height is twice the shift, and
                // the shift is measured against how far a 16:9 source
                // actually overflows this band — so `artCropBias` reads as
                // a true fraction of the distance from centre to top, and at
                // 1.0 it can never exceed the image (H + 2s ≤ the rendered
                // height for any bias ≤ 1).
                let overflow = max(0, (geo.size.width * 9 / 16 - geo.size.height) / 2)
                let shift = artCropBias * overflow
                ZStack {
                    if let art {
                        // Decorative — see the FusionHeroBar note. A full-bleed
                        // RemoteImage overflows the frame it is clipped to and
                        // stays hit-testable, which swallows a neighbouring
                        // card's context-menu hit test.
                        RemoteImage(url: art, maxPixels: PerformanceProfile.backdropPixelCap)
                            .allowsHitTesting(false)
                            .frame(width: geo.size.width, height: geo.size.height + shift * 2)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .clipped()
                    }
                    // The billboard trailer draws OVER the still art and
                    // UNDER the wash/mask, so it inherits exactly the
                    // treatment the art has and the info block stays
                    // readable on top of it.
                    if playsTrailer {
                        HeroTrailerLayer(hero: hero)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                        // Left readability wash rides INSIDE the mask so it
                        // fades away with the art instead of tinting the stage.
                        .overlay(
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.72), location: 0),
                                    .init(color: .black.opacity(0.5), location: 0.22),
                                    .init(color: .black.opacity(0.25), location: 0.38),
                                    .init(color: .clear, location: 0.60)
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.55),
                                    .init(color: .white.opacity(0.35), location: 0.82),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
            }
            // Spotlight info — extra leading inset so text/logo stay title-safe
            // even though the art bleeds to the edge.
            ATVHeroInfoView(hero: hero, onPlay: onPlay, playFocus: playFocus,
                            showsActions: showsActions)
                .padding(.leading, 100)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // "TOP 10" eyebrow at the very top-left of the hero.
        .overlay(alignment: .topLeading) {
            if showsTopBadge, hero.spotlight.count > 1 {
                Text("TOP 10")
                    .font(FusionType.badge(theme.font))
                    .tracking(2)
                    .foregroundStyle(theme.palette.secondary)
                    .padding(.leading, OrivioSpacing.huge + 100)
                    .padding(.top, 64)
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
    var playFocus: FocusState<Bool>.Binding
    /// Play button + spotlight dots (see `FusionHeroHeader.showsActions`).
    var showsActions = true
    /// -1 / 1 while an invisible stepping sentinel beside the Play button
    /// holds focus for a beat (see the hero button HStack).
    @FocusState private var spotlightStep: Int?
    @State private var contentRating: String?
    @Environment(\.railIsHidden) private var railIsHidden

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            Spacer(minLength: 0)
            if let item = hero.item {
                content(item)
            }
        }
        .frame(height: 560, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .padding(.leading, OrivioSpacing.huge)
        .padding(.bottom, OrivioSpacing.md)
        .contentRating(for: hero.item, into: $contentRating)
    }

    @ViewBuilder
    private func content(_ item: MetaItem) -> some View {
        if item.type == "collection" {
            // The category's NAME — deliberately not its cover tile, which
            // reads as a stray poster floating on the billboard. Raised by the
            // height of the meta line / synopsis / button block a real title
            // renders below its logo, so "Netflix" sits where a movie's title
            // treatment sits rather than on the very bottom edge of the band.
            Text(item.name)
                .font(.system(size: 60, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
                .shadow(color: .black.opacity(scheme == .light ? 0 : 0.4), radius: 10, y: 4)
                .padding(.bottom, 180)
        } else {
            // (The "TOP 10" eyebrow now lives at the hero's top-left corner —
            // see FusionHeroHeader.)
            // Title treatment (logo) or big text fallback.
            if let logo = item.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading, maxDimension: 540)
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

            // Left/Right on the Play button browse the spotlight titles via
            // two invisible focusable sentinels flanking it — each bounces
            // focus straight back after stepping. NOT `.onMoveCommand`: that
            // swallows EVERY direction on the focused view, so Down could
            // never leave the hero and the catalog rows were unreachable.
            if showsActions {
            HStack(spacing: 0) {
                // Dropped while the rail is hidden, so LEFT finds no candidate
                // here, bubbles up to RootView's `onMoveCommand`, and brings
                // the sidebar back (see `railIsHidden`). Stepping the spotlight
                // backwards costs nothing there — RIGHT still cycles it.
                if !railIsHidden {
                    Color.clear.frame(width: 1, height: 44)
                        .focusable()
                        .focused($spotlightStep, equals: -1)
                }
                ATVHeroPlayButton(title: item.type == "series" ? "Go to Show" : "Go to Movie") {
                    onPlay(item)
                }
                .focused(playFocus)
                // NOT `.onFocusChange`: `\.isFocused` resolves inside the
                // focusable Button, not on a modifier wrapped around it, so
                // that never fired and the spotlight kept rotating under a
                // focused Play button (Select then opened the wrong title).
                .onChange(of: playFocus.wrappedValue) { _, focused in
                    hero.heroButtonFocused = focused
                    if focused { hero.markInteraction() }
                }
                Color.clear.frame(width: 1, height: 44)
                    .focusable()
                    .focused($spotlightStep, equals: 1)
            }
            .onChange(of: spotlightStep) { _, step in
                guard let step else { return }
                hero.stepSpotlight(by: step)
                spotlightStep = nil
                playFocus.wrappedValue = true
            }
            .padding(.top, OrivioSpacing.xs)

            // §20.5 pagination — tracks spotlight rotation position.
            if hero.spotlight.count > 1 {
                paginationDots
                    .padding(.top, OrivioSpacing.sm)
            }
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
        HStack(spacing: OrivioSpacing.sm) {
            if let rating = item.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 17, weight: .bold))
                    Text(rating).font(.system(size: 23, weight: .bold))
                }
                .foregroundStyle(OrivioPrimitives.success)
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
                .focusLift(OrivioFocus.card, isFocused)
                .cardPressDip(configuration.isPressed)
        }
    }
}
