import SwiftUI

struct HomeRowDescriptor: Hashable, Codable {
    enum Kind: Hashable, Codable {
        case catalog(addonURL: String, type: String, catalogID: String)
        /// A ROWS-mode collection: its own row of folder tiles.
        case collection(String)
        /// Every non-ROWS collection shares one "Collections" row.
        case collectionsShared
        /// "Comedies to Watch After Ted Lasso": picks based on a finished title.
        case recommendation(basedOn: String)
    }
    var key: String
    var title: String
    var kind: Kind
    var addonName: String?
    var addonLogo: String?
    var numbered: Bool
    var supportsSkip: Bool
}

struct HomeRow: Identifiable, Equatable, Codable {
    var id: String { descriptor.key }
    var descriptor: HomeRowDescriptor
    var items: [MetaItem]
}

/// The focused title — what the backdrop and pinned header show. Its own
/// object, observed only by them: as part of `HomeFocusModel` (which the whole
/// page observes) every Left/Right rebuilt every row on Home.
@MainActor
final class HomeSpotlight: ObservableObject {
    @Published var item: MetaItem?
}

/// Home's layout focus: on the hero or in the rows, and which row. The page
/// observes this, so it publishes only on a real change — rows re-assign the
/// same row key on every focus move, and @Published fires even for equal
/// values (each one a full Home rebuild on an A8/A10X).
@MainActor
final class HomeFocusModel: ObservableObject {
    let spotlight = HomeSpotlight()

    /// Forwarded to the spotlight (deliberately not published here).
    var focusedItem: MetaItem? {
        get { spotlight.item }
        set { if newValue?.id != spotlight.item?.id { spotlight.item = newValue } }
    }

    private var _inRows = false
    var inRows: Bool {
        get { _inRows }
        set { guard newValue != _inRows else { return }; objectWillChange.send(); _inRows = newValue }
    }

    private var _focusedRowKey: String?
    /// The row that holds focus (set by the rows themselves).
    var focusedRowKey: String? {
        get { _focusedRowKey }
        set {
            guard newValue != _focusedRowKey else { return }
            objectWillChange.send()
            _focusedRowKey = newValue
            if newValue == _pendingRowKey { _pendingRowKey = nil }
        }
    }

    private var _pendingRowKey: String?
    /// A row we're moving to: positioned and enabled before focus lands there.
    var pendingRowKey: String? {
        get { _pendingRowKey }
        set { guard newValue != _pendingRowKey else { return }; objectWillChange.send(); _pendingRowKey = newValue }
    }

    /// The row the layout follows.
    var activeRowKey: String? { pendingRowKey ?? focusedRowKey }
}

/// Home shows everything; the Movies and TV Shows tabs are the same page
/// limited to one type.
enum HomeScope: String {
    case all, movies, shows

    func includes(type: String) -> Bool {
        switch self {
        case .all: return true
        case .movies: return type == "movie"
        case .shows: return type == "series" || type == "anime"
        }
    }
}

@MainActor
final class HomeModel: ObservableObject {
    enum LoadState: Equatable { case idle, loading(String), loaded, failed }

    let scope: HomeScope

    init(scope: HomeScope = .all) {
        self.scope = scope
    }

    @Published private(set) var rows: [HomeRow] = []
    @Published private(set) var continueWatching: [ContinueWatchingItem] = []
    @Published private(set) var heroItems: [MetaItem] = []
    @Published private(set) var featured: [MetaItem] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var heroSourceKey: String?

    private var fingerprint = ""
    private var loadTask: Task<Void, Never>?
    private var cwTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private var cacheURL: URL {
        Persistence.cachesURL.appendingPathComponent("orivio-home-catalogs\(scope == .all ? "" : "-" + scope.rawValue).p\(ProfileScope.current).json")
    }

    // MARK: Descriptors

    func descriptors(stores: AppStores) -> [HomeRowDescriptor] {
        let home = stores.home
        var catalogRows: [HomeRowDescriptor] = []
        for addon in stores.addons.enabled {
            for cat in addon.manifest.catalogs where !cat.requiresExtra && !cat.isSearchOnly && scope.includes(type: cat.type) {
                let key = "\(addon.manifest.id)|\(cat.type)|\(cat.id)"
                let cfg = home.config(for: key)
                if cfg?.hidden == true { continue }
                let typeName = cat.type == "movie" ? "Movies" : (cat.type == "series" ? "Shows" : cat.type.capitalized)
                let base = cat.name.isEmpty ? cat.id : cat.name
                let title = cfg?.customTitle ?? (base.localizedCaseInsensitiveContains(typeName) ? base : "\(base) \(typeName)")
                let numberedDefault = false
                catalogRows.append(HomeRowDescriptor(
                    key: key, title: title, kind: .catalog(addonURL: addon.manifestURL, type: cat.type, catalogID: cat.id),
                    addonName: addon.displayName, addonLogo: addon.manifest.logo,
                    numbered: cfg?.numbered ?? numberedDefault, supportsSkip: cat.supportsSkip))
            }
        }
        let ordered = home.ordered(catalogRows.map(\.key))
        catalogRows = ordered.compactMap { k in catalogRows.first { $0.key == k } }
        catalogRows = Array(catalogRows.prefix(home.value.maxHomeRows))

        // Collections are always kept; "Pin to top" ones first.
        // Collections live on Home only.
        let collections = scope == .all ? stores.collections.visible(for: stores.profiles.active) : []
        var pinned: [HomeRowDescriptor] = []
        var unpinned: [HomeRowDescriptor] = []
        var hasShared = false
        for c in collections where !c.folders.isEmpty {
            if c.isRows {
                let d = HomeRowDescriptor(key: "collection:\(c.id)", title: c.title, kind: .collection(c.id), numbered: false, supportsSkip: false)
                if c.pinToTop { pinned.append(d) } else { unpinned.append(d) }
            } else {
                hasShared = true
            }
        }
        var result = pinned
        if hasShared {
            result.append(HomeRowDescriptor(key: "collections:shared", title: "Collections", kind: .collectionsShared, numbered: false, supportsSkip: false))
        }
        // Collection rows keep their saved position among catalog rows.
        let allKeys = home.ordered((catalogRows + unpinned).map(\.key))
        let byKey = Dictionary((catalogRows + unpinned).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        result += allKeys.compactMap { byKey[$0] }
        return result
    }

    private func makeFingerprint(stores: AppStores) -> String {
        let h = stores.home.value
        var parts: [String] = []
        parts.append(stores.addons.enabled.map { "\($0.manifestURL)#\($0.manifest.catalogs.count)" }.joined(separator: ","))
        parts.append(h.rows.map { "\($0.key)\($0.hidden)\($0.customTitle ?? "")\($0.numbered.map(String.init) ?? "")" }.joined())
        parts.append("\(h.hideUnreleased)\(h.posterBanners)\(h.heroSource ?? "")\(h.maxHomeRows)")
        parts.append(stores.collections.visible(for: stores.profiles.active).map { "\($0.id)\($0.folders.count)\($0.viewMode)\($0.pinToTop)" }.joined())
        parts.append("\(stores.tmdb.value.isUsable)\(stores.trakt.isSignedIn)\(ProfileScope.current)")
        return parts.joined(separator: "|")
    }

    // MARK: Loading

    func loadIfNeeded(stores: AppStores, force: Bool = false) {
        let fp = makeFingerprint(stores: stores)
        if !force, fp == fingerprint, state == .loaded || isLoading { return }
        fingerprint = fp
        load(stores: stores, force: force)
    }

    private var isLoading: Bool { if case .loading = state { return true }; return false }

    private func load(stores: AppStores, force: Bool) {
        loadTask?.cancel()
        let descriptors = descriptors(stores: stores)
        // Paint from the disk cache first (stale-while-revalidate). The decode runs
        // off the main thread: ~30 rows of metadata held launch up on an A8.
        let url = cacheURL
        let fromCache = rows.isEmpty && FileManager.default.fileExists(atPath: url.path)
        if rows.isEmpty, !fromCache { state = .loading("Loading catalogs…") }
        let home = stores.home.value
        loadTask = Task { [weak self] in
            if fromCache {
                let cached = await Task.detached(priority: .userInitiated) { Persistence.loadFile([HomeRow].self, url: url) }.value
                guard let self, !Task.isCancelled else { return }
                if self.rows.isEmpty, let cached {
                    let keys = Set(descriptors.map(\.key))
                    self.rows = cached.filter { keys.contains($0.id) }
                    self.recomputeHero(stores: stores)
                }
                if self.rows.isEmpty { self.state = .loading("Loading catalogs…") }
            }
            guard let self else { return }
            var fresh: [String: [MetaItem]] = [:]
            var lastFlush = Date()
            let catalogDescriptors = descriptors.filter { if case .catalog = $0.kind { return true }; return false }
            let addonsByURL = Dictionary(stores.addons.addons.map { ($0.manifestURL, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (String, [MetaItem]?).self) { group in
                var iterator = catalogDescriptors.makeIterator()
                let limit = PerformanceProfile.homeFetchConcurrency
                func addNext() {
                    guard let d = iterator.next(), case .catalog(let url, let type, let catID) = d.kind,
                          let addon = addonsByURL[url] else { return }
                    group.addTask {
                        let items = try? await AddonClient.catalog(addon, type: type, id: catID)
                        return (d.key, items)
                    }
                }
                for _ in 0..<limit { addNext() }
                while let (key, items) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let items { fresh[key] = items }
                    addNext()
                    if Date().timeIntervalSince(lastFlush) > 0.4 {
                        lastFlush = Date()
                        self.apply(descriptors: descriptors, fresh: fresh, home: home, stores: stores, final: false)
                        if self.rows.contains(where: { !$0.items.isEmpty }) { self.state = .loading("Loading artwork…") }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.apply(descriptors: descriptors, fresh: fresh, home: home, stores: stores, final: true)
            self.state = (self.rows.isEmpty && self.continueWatching.isEmpty) ? .failed : .loaded
            let toSave = self.rows.filter { if case .catalog = $0.descriptor.kind { return true }; return false }
            Task.detached(priority: .utility) { Persistence.saveFile(toSave, url: url) }
        }
        refreshContinueWatching(stores: stores)
        scheduleAutoRefresh(stores: stores)
    }

    private func apply(descriptors: [HomeRowDescriptor], fresh: [String: [MetaItem]], home: HomeSettings, stores: AppStores, final: Bool) {
        var out: [HomeRow] = []
        for d in descriptors {
            switch d.kind {
            case .catalog:
                let raw = fresh[d.key] ?? rows.first { $0.id == d.key }?.items ?? []
                var seen = Set<String>()
                var items = raw.filter { seen.insert($0.id).inserted }
                if home.hideUnreleased { items = items.filter { !$0.isUnreleased } }
                items = items.map { $0.withPoster(banners: home.posterBanners) }
                items = Array(items.prefix(30))
                if final && items.isEmpty { continue }
                out.append(HomeRow(descriptor: d, items: items))
            case .collection, .collectionsShared, .recommendation:
                out.append(HomeRow(descriptor: d, items: []))
            }
        }
        if out != rows { rows = out }
        recomputeHero(stores: stores)
    }

    private func recomputeHero(stores: AppStores) {
        let home = stores.home.value
        let catalogRows = rows.filter { if case .catalog = $0.descriptor.kind { return !$0.items.isEmpty }; return false }
        // Hero source: chosen catalog if on screen, else the first row.
        let source = catalogRows.first { $0.id == home.heroSource } ?? catalogRows.first
        heroSourceKey = source?.id
        let newHero = Array((source?.items ?? []).filter { $0.background != nil || $0.poster != nil }.prefix(10))
        if newHero.map(\.id) != heroItems.map(\.id) {
            heroItems = newHero
            ImagePipeline.shared.prefetch(newHero.prefix(3).compactMap { ($0.background ?? $0.poster).flatMap(URL.init(string:)) },
                                          maxPixel: ImageSize.backdrop)
        }
        let featuredSource = catalogRows.first { $0.id != source?.id }
        let f = home.featuredSection ? Array((featuredSource?.items ?? []).prefix(6)) : []
        let newFeatured = f.count >= 2 ? f : []
        if newFeatured.map(\.id) != featured.map(\.id) { featured = newFeatured }
    }

    func refreshContinueWatching(stores: AppStores) {
        cwTask?.cancel()
        cwTask = Task { [weak self] in
            guard let scope = self?.scope else { return }
            let all = await ContinueWatchingBuilder.build(progress: stores.progress, watched: stores.watched, home: stores.home.value)
            let items = all.filter { scope == .all || (scope == .shows) == ($0.meta.isSeries || $0.video != nil) }
            guard !Task.isCancelled, let self else { return }
            if items != self.continueWatching { self.continueWatching = items }
            if self.state == .failed, !items.isEmpty { self.state = .loaded }
            // Enrich rows synced from other devices with missing art.
            if stores.tmdb.value.enrichContinueWatching {
                for item in items where item.meta.poster == nil && item.meta.background == nil {
                    if let full = await MetaService.cachedShow(item.meta.id, type: item.meta.type), let p = item.progress {
                        stores.progress.enrich(id: p.id, with: full)
                    }
                }
            }
            if scope == .all { TopShelfExporter.export(items: items, stores: stores) }
            await self.refreshRecommendations(stores: stores)
        }
    }

    // MARK: Picks after a finished title

    @Published private(set) var recommendationRows: [HomeRow] = []
    private var recommendationCache: [String: (title: String, items: [MetaItem])] = [:]

    /// Up to two rows built from the most recently finished titles.
    func refreshRecommendations(stores: AppStores) async {
        // Settings → Layout can switch these off ("… to Watch After …"); the
        // lookup below is a TMDB round-trip per finished title, so it is not
        // worth starting when the rows would not be shown.
        guard stores.home.value.afterWatchingRows else {
            if !recommendationRows.isEmpty { recommendationRows = [] }
            return
        }
        var finished: [String: (type: String, date: Date)] = [:]
        func note(_ id: String, _ type: String, _ date: Date) {
            if let cur = finished[id], cur.date >= date { return }
            finished[id] = (type, date)
        }
        for w in stores.watched.items.values { note(w.metaID, w.type, w.watchedAt) }
        for p in stores.progress.entries.values where p.isFinished { note(p.metaID, p.type, p.updatedAt) }
        let recent = finished.sorted { $0.value.date > $1.value.date }
            .filter { scope.includes(type: $0.value.type) }
            .prefix(2)
        let seen = Set(finished.keys).union(continueWatching.map(\.meta.id))
        var rows: [HomeRow] = []
        for (id, info) in recent {
            if recommendationCache[id] == nil {
                guard let meta = await MetaService.cachedShow(id, type: info.type) else { continue }
                let items = await Self.picks(after: meta, stores: stores)
                recommendationCache[id] = (Self.rowTitle(after: meta), items)
            }
            guard let (title, items) = recommendationCache[id] else { continue }
            let fresh = items.filter { !seen.contains($0.id) && $0.id != id }.prefix(20)
            guard fresh.count >= 4 else { continue }
            let d = HomeRowDescriptor(key: "because:\(id)", title: title, kind: .recommendation(basedOn: id),
                                      numbered: false, supportsSkip: false)
            rows.append(HomeRow(descriptor: d, items: Array(fresh).map { $0.withPoster(banners: stores.home.value.posterBanners) }))
        }
        if rows.map(\.id) != recommendationRows.map(\.id) || rows.map(\.items.count) != recommendationRows.map(\.items.count) {
            recommendationRows = rows
        }
    }

    /// TMDB recommendations when a key is set, else the add-on's top titles in the same genre.
    private static func picks(after meta: MetaItem, stores: AppStores) async -> [MetaItem] {
        if stores.tmdb.value.isUsable, let e = await TMDBService.enrichment(for: meta), !e.recommendations.isEmpty {
            return e.recommendations
        }
        let type = meta.isSeries ? "series" : "movie"
        for genre in meta.genres.prefix(2) {
            for addon in stores.addons.enabled {
                guard let cat = addon.manifest.catalogs.first(where: { $0.type == type && $0.genreOptions.contains(genre) && !$0.isSearchOnly })
                else { continue }
                if let items = try? await AddonClient.catalog(addon, type: type, id: cat.id, extras: ["genre": genre]), !items.isEmpty {
                    return items
                }
            }
        }
        return []
    }

    static func rowTitle(after meta: MetaItem) -> String {
        guard let genre = meta.genres.first else { return "Because You Watched \(meta.name)" }
        let plural: [String: String] = [
            "Comedy": "Comedies", "Drama": "Dramas", "Thriller": "Thrillers", "Documentary": "Documentaries",
            "Romance": "Romances", "Mystery": "Mysteries", "Western": "Westerns", "Musical": "Musicals",
            "Biography": "Biopics", "Horror": "Horror Picks", "Animation": "Animated Picks", "Crime": "Crime Stories",
        ]
        let kind = plural[genre] ?? "\(genre) \(meta.isSeries ? "Shows" : "Movies")"
        return "\(kind) to Watch After \(meta.name)"
    }

    private func scheduleAutoRefresh(stores: AppStores) {
        refreshTimer?.invalidate()
        let minutes = stores.home.value.autoRefreshMinutes
        guard minutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                AddonClient.catalogCache.removeAll()
                self?.load(stores: stores, force: true)
            }
        }
        RunLoop.main.add(t, forMode: .default)
        refreshTimer = t
    }

    func retry(stores: AppStores) {
        AddonClient.catalogCache.removeAll()
        fingerprint = ""
        loadIfNeeded(stores: stores, force: true)
    }

    /// The hero source row is numbered by default when it's a "Top"/"Popular" catalog.
    func isNumbered(_ row: HomeRow) -> Bool {
        if row.descriptor.numbered { return true }
        guard row.id == heroSourceKey else { return false }
        let t = row.descriptor.title.lowercased()
        return (t.contains("top") || t.contains("popular")) && AppStores.shared.home.config(for: row.id)?.numbered != false
    }
}

/// Writes the Continue Watching snapshot for the Top Shelf (PIN-locked profiles excluded).
@MainActor
enum TopShelfExporter {
    private static var lastIDs: [String] = []

    static func export(items: [ContinueWatchingItem], stores: AppStores) {
        if stores.profiles.active.pinEnabled {
            TopShelfSnapshot(items: [], updatedAt: Date()).save()
            return
        }
        let scheme = Bundle.main.bundleIdentifier ?? "orivio"
        let entries = items.prefix(20).map { item -> TopShelfSnapshot.Item in
            let type = item.meta.type
            let id = item.meta.id
            return TopShelfSnapshot.Item(
                id: item.id, title: item.meta.name,
                subtitle: item.video.map { $0.seasonEpisodeCode },
                imageURL: item.video?.thumbnail ?? item.meta.background ?? item.meta.poster,
                progress: item.fraction,
                playURL: "\(scheme)://resume/\(type)/\(HTTP.encodeComponent(id))",
                displayURL: "\(scheme)://meta/\(type)/\(HTTP.encodeComponent(id))")
        }
        let ids = entries.map { "\($0.id)\($0.progress)" }
        guard ids != lastIDs else { return }
        lastIDs = ids
        TopShelfSnapshot(items: Array(entries), updatedAt: Date()).save()
        TopShelfNotifier.contentChanged()
    }
}

import TVServices

enum TopShelfNotifier {
    static func contentChanged() {
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
