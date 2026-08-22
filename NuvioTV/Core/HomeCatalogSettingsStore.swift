import Foundation

// MARK: - Home layout

/// Home screen presentation style, mirroring Android's `HomeLayout`.
/// - modern: large hero backdrop that follows focus + horizontal rows.
/// - classic: full-bleed focus-gradient backdrop + horizontal rows, no hero panel.
/// - grid: each catalog wrapped as a vertical poster grid.
enum HomeLayout: String, CaseIterable, Identifiable, Codable {
    // Order matches the APK's Home Layout picker: Modern, Grid, Classic.
    case modern, grid, classic
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modern: return "Modern View"
        case .classic: return "Classic View"
        case .grid: return "Grid View"
        }
    }

    var summary: String {
        switch self {
        case .modern: return "Cinematic hero that follows focus, with rows below"
        case .classic: return "Traditional rows with a subtle focus backdrop"
        case .grid: return "Dense poster grids for fast browsing"
        }
    }
}

/// Poster card size — drives the portrait card width everywhere it renders.
enum PosterSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    /// Portrait poster width (points). Height is width × 3/2.
    var posterWidth: CGFloat {
        switch self {
        case .small: return 180
        case .medium: return 220
        case .large: return 264
        }
    }
}

/// How the Continue Watching row is ordered (mirrors Android's
/// ContinueWatchingSortMode).
enum ContinueWatchingSortMode: String, CaseIterable, Identifiable, Codable {
    case recentlyWatched, streamingStyle
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .recentlyWatched: return "Recently watched"
        case .streamingStyle: return "Streaming style"
        }
    }
    var summary: String {
        switch self {
        case .recentlyWatched: return "Most recently played first"
        case .streamingStyle: return "Titles you're mid-episode on first, then the rest"
        }
    }
}

/// The device-local Home/Continue-Watching presentation prefs that ride in the
/// tvOS-only sync blob (see NuvioSyncManager.AppPreferencesSnapshot).
struct HomePresentationSnapshot: Codable, Equatable {
    var homeLayout: HomeLayout = .modern
    var landscapePosters = false
    var fullscreenHero = true
    var posterSize: PosterSize = .medium
    var showPosterLabels = true
    var continueWatchingSortMode: ContinueWatchingSortMode = .recentlyWatched
    var nextUpFromFurthestEpisode = true
    var showUnairedNextUp = true
    var useEpisodeThumbnailsInCw = true
    var blurUnwatchedEpisodes = false
    var blurContinueWatchingNextUp = false
    var posterCornerRadius = 12
    var catalogAddonNameEnabled = false
    var catalogTypeSuffixEnabled = true
    var showFullReleaseDate = true
    var detailPageTrailerButtonEnabled = true
}

// MARK: - Sync payload (matches Android's home-catalog settings_json exactly)

/// The cross-platform home-catalog layout, wire-identical to the Nuvio Android
/// app: a flat ordered list of keys plus a disabled set and a custom-title map.
/// Keys are `{addonId}_{type}_{catalogId}` for addon catalogs and
/// `collection_{id}` for collections — so where a catalog sits, where a
/// collection sits, whether it's shown, and its custom title all round-trip
/// between the phone and the Apple TV. (The earlier `items:[{…}]` shape was
/// tvOS-only and silently didn't interoperate with the phone.)
struct SyncHomeCatalogPayload: Codable, Hashable {
    var orderKeys: [String] = []
    var disabledKeys: [String] = []
    var customTitles: [String: String] = [:]
    var hideUnreleasedContent: Bool = false

    private enum CodingKeys: String, CodingKey {
        case orderKeys = "home_catalog_order_keys"
        case disabledKeys = "disabled_home_catalog_keys"
        case customTitles = "custom_catalog_titles"
        case hideUnreleasedContent = "hide_unreleased_content"
    }

    init(orderKeys: [String] = [], disabledKeys: [String] = [],
         customTitles: [String: String] = [:], hideUnreleasedContent: Bool = false) {
        self.orderKeys = orderKeys
        self.disabledKeys = disabledKeys
        self.customTitles = customTitles
        self.hideUnreleasedContent = hideUnreleasedContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderKeys = try c.decodeIfPresent([String].self, forKey: .orderKeys) ?? []
        disabledKeys = try c.decodeIfPresent([String].self, forKey: .disabledKeys) ?? []
        customTitles = try c.decodeIfPresent([String: String].self, forKey: .customTitles) ?? [:]
        hideUnreleasedContent = try c.decodeIfPresent(Bool.self, forKey: .hideUnreleasedContent) ?? false
    }

    var isEmpty: Bool { orderKeys.isEmpty && disabledKeys.isEmpty && customTitles.isEmpty }
}

// MARK: - Store

/// Home layout customization: which catalog rows show, their order, and custom
/// titles — plus collection rows interleaved. Keys match Android's
/// HomeCatalogSyncSupport: `{addonId}_{type}_{catalogId}` for addon catalogs
/// (addonId = manifest id, NOT the manifest URL) and `collection_{id}` for
/// collections, so settings sync cross-platform via
/// `sync_push/pull_home_catalog_settings`.
@MainActor
final class HomeCatalogSettingsStore: ObservableObject {
    @Published private(set) var orderKeys: [String] = []
    @Published private(set) var disabledKeys: Set<String> = []
    @Published private(set) var customTitles: [String: String] = [:]
    @Published var hideUnreleasedContent: Bool = false {
        didSet {
            guard hideUnreleasedContent != oldValue else { return }
            save()
            notifyLocalChange()
        }
    }
    /// Presentation style. Device-local (not part of the cross-platform sync
    /// payload — Android keeps layout local too).
    @Published var homeLayout: HomeLayout = .modern {
        didSet { guard homeLayout != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Modern-view cards: portrait (false) or landscape (true), like the APK's
    /// "Landscape Posters" toggle.
    @Published var landscapePosters: Bool = false {
        didSet { guard landscapePosters != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Whether the home hero backdrop fills the screen (APK "Fullscreen Hero Backdrop").
    @Published var fullscreenHero: Bool = true {
        didSet { guard fullscreenHero != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Poster card size across all grids/rows.
    @Published var posterSize: PosterSize = .medium {
        didSet { guard posterSize != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Show the title label beneath poster cards.
    @Published var showPosterLabels: Bool = true {
        didSet { guard showPosterLabels != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Continue Watching row ordering.
    @Published var continueWatchingSortMode: ContinueWatchingSortMode = .recentlyWatched {
        didSet { guard continueWatchingSortMode != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Resume a series from the episode after the FURTHEST watched one rather
    /// than the most recently played.
    @Published var nextUpFromFurthestEpisode: Bool = true {
        didSet { guard nextUpFromFurthestEpisode != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Allow an unaired episode to be the next-up target (off skips it).
    @Published var showUnairedNextUp: Bool = true {
        didSet { guard showUnairedNextUp != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Use the episode still (not the show poster) on Continue Watching cards.
    @Published var useEpisodeThumbnailsInCw: Bool = true {
        didSet { guard useEpisodeThumbnailsInCw != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Spoiler-blur episode thumbnails you haven't watched (focus reveals them).
    @Published var blurUnwatchedEpisodes: Bool = false {
        didSet { guard blurUnwatchedEpisodes != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Minutes between automatic Home catalog re-fetches while the app is
    /// open (0 = off). Per-device (plain UserDefaults, not in the synced
    /// snapshot): a refresh cadence tuned for one box shouldn't sync.
    @Published var autoRefreshMinutes: Int = UserDefaults.standard.integer(forKey: "nuvio.home.autorefresh.v1") {
        didSet {
            guard autoRefreshMinutes != oldValue else { return }
            UserDefaults.standard.set(autoRefreshMinutes, forKey: "nuvio.home.autorefresh.v1")
        }
    }
    /// Spoiler-blur Continue Watching art for barely-started next-up episodes.
    @Published var blurContinueWatchingNextUp: Bool = false {
        didSet { guard blurContinueWatchingNextUp != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Poster card corner radius (points).
    @Published var posterCornerRadius: Int = 12 {
        didSet { guard posterCornerRadius != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Append the addon's name to catalog row titles.
    @Published var catalogAddonNameEnabled: Bool = false {
        didSet { guard catalogAddonNameEnabled != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Append the "- Movie/Series" type suffix to catalog row titles.
    @Published var catalogTypeSuffixEnabled: Bool = true {
        didSet { guard catalogTypeSuffixEnabled != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Show the full release date (vs. just the year) on details.
    @Published var showFullReleaseDate: Bool = true {
        didSet { guard showFullReleaseDate != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Show the Trailer button on the details page.
    @Published var detailPageTrailerButtonEnabled: Bool = true {
        didSet { guard detailPageTrailerButtonEnabled != oldValue else { return }; save(); notifyPresentationChange() }
    }

    /// Selectable poster corner radii (points).
    static let posterCornerRadiusValues: [Int] = [0, 6, 12, 16, 22]

    var onLocalChange: (() -> Void)?
    /// Fired when a device-local presentation pref changes, so the tvOS sync
    /// blob (player/TMDB/theme/home) can push it.
    var onPresentationChange: (() -> Void)?
    private var suppressChange = false
    private var profileID = 1

    private static let baseKey = "nuvio.homecatalog.v1"

    nonisolated static func catalogKey(addonID: String, type: String, catalogID: String) -> String {
        "\(addonID)_\(type)_\(catalogID)"
    }

    nonisolated static func collectionKey(_ collectionID: String) -> String {
        "collection_\(collectionID)"
    }

    private var storageKey: String {
        profileID == 1 ? Self.baseKey : "\(Self.baseKey).p\(profileID)"
    }

    /// Dev-only: force the home layout via launch arg for sim verification
    /// (driving Settings needs a real remote). Applied after both local load
    /// AND remote sync — sync would otherwise stomp a local-only override
    /// seconds after launch, same issue the theme override had.
    private static var launchLayoutOverride: HomeLayout? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-layoutClassic") { return .classic }
        if args.contains("-layoutGrid") { return .grid }
        if args.contains("-layoutModern") { return .modern }
        return nil
    }

    init() {
        load()
        if let override = Self.launchLayoutOverride { homeLayout = override }
    }

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        load()
    }

    // MARK: Queries

    func isEnabled(key: String) -> Bool { !disabledKeys.contains(key) }

    func customTitle(for key: String) -> String? {
        customTitles[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Merge saved order with the currently-available keys, exactly like
    /// Android's buildHomeCatalogSyncPayload: saved keys that still exist keep
    /// their positions; new catalog keys append, then new collection keys.
    func mergedOrder(catalogKeys: [String], collectionKeys: [String]) -> [String] {
        let available = Set(catalogKeys + collectionKeys)
        var seen = Set<String>()
        let savedValid = orderKeys.filter { available.contains($0) && seen.insert($0).inserted }
        let savedSet = Set(savedValid)
        return savedValid
            + catalogKeys.filter { !savedSet.contains($0) }
            + collectionKeys.filter { !savedSet.contains($0) }
    }

    // MARK: Mutations (UI)

    func setOrder(_ keys: [String]) {
        guard keys != orderKeys else { return }
        orderKeys = keys
        save()
        notifyLocalChange()
    }

    func move(key: String, up: Bool, within allKeys: [String]) {
        var keys = mergedOrder(catalogKeys: allKeys.filter { !$0.hasPrefix("collection_") },
                               collectionKeys: allKeys.filter { $0.hasPrefix("collection_") })
        guard let index = keys.firstIndex(of: key) else { return }
        let target = up ? index - 1 : index + 1
        guard keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        setOrder(keys)
    }

    /// Synthetic unit token for the single "Collections" reorder row — all
    /// collections move together as one contiguous block on Home.
    static let collectionsUnit = "COLLECTIONS"

    /// Reorder Home treating every collection as ONE unit (they render as a
    /// single row). `unitKey` is a catalog key or `collectionsUnit`.
    func moveHomeUnit(up: Bool, unitKey: String, catalogKeys: [String], collectionKeys: [String]) {
        let order = mergedOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
        var units: [String] = []
        var insertedCollections = false
        for k in order {
            if collectionKeys.contains(k) {
                if !insertedCollections { units.append(Self.collectionsUnit); insertedCollections = true }
            } else {
                units.append(k)
            }
        }
        guard let idx = units.firstIndex(of: unitKey) else { return }
        let target = up ? idx - 1 : idx + 1
        guard units.indices.contains(target) else { return }
        units.swapAt(idx, target)
        var result: [String] = []
        for u in units {
            if u == Self.collectionsUnit { result.append(contentsOf: collectionKeys) }
            else { result.append(u) }
        }
        setOrder(result)
    }

    /// Show/hide ALL collections at once (the single Collections row).
    func setCollectionsEnabled(_ enabled: Bool, collectionKeys: [String]) {
        for k in collectionKeys {
            if enabled { disabledKeys.remove(k) } else { disabledKeys.insert(k) }
        }
        save()
        notifyLocalChange()
    }

    func setEnabled(_ enabled: Bool, key: String) {
        if enabled { disabledKeys.remove(key) } else { disabledKeys.insert(key) }
        save()
        notifyLocalChange()
    }

    func setCustomTitle(_ title: String?, key: String) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitles.removeValue(forKey: key)
        } else {
            customTitles[key] = trimmed
        }
        save()
        notifyLocalChange()
    }

    // MARK: Sync plumbing

    /// Build the push payload from currently-available addons + collections.
    /// The order array merges the saved order with any newly-available catalogs
    /// (then collections), exactly like Android's buildHomeCatalogSyncPayload;
    /// disabled keys and custom titles ship as-is (they already include anything
    /// pulled from the phone, so cross-device state isn't dropped).
    func exportPayload(addons: [InstalledAddon], collections: [NuvioCollection]) -> SyncHomeCatalogPayload {
        var catalogKeys: [String] = []
        var collectionKeys: [String] = []
        var seen = Set<String>()

        for addon in addons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = Self.catalogKey(addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                guard seen.insert(key).inserted else { continue }
                catalogKeys.append(key)
            }
        }
        for collection in collections {
            let key = Self.collectionKey(collection.id)
            guard seen.insert(key).inserted else { continue }
            collectionKeys.append(key)
        }

        let order = mergedOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
        return SyncHomeCatalogPayload(
            orderKeys: order,
            disabledKeys: Array(disabledKeys),
            customTitles: customTitles,
            hideUnreleasedContent: hideUnreleasedContent
        )
    }

    /// Apply a remote payload (pull). Suppresses the local-change push echo.
    func applyRemote(_ payload: SyncHomeCatalogPayload) {
        suppressChange = true
        defer { suppressChange = false }
        orderKeys = payload.orderKeys
        disabledKeys = Set(payload.disabledKeys)
        customTitles = payload.customTitles.filter { !$0.value.isEmpty }
        hideUnreleasedContent = payload.hideUnreleasedContent
        save()
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var orderKeys: [String]
        var disabledKeys: [String]
        var customTitles: [String: String]
        var hideUnreleasedContent: Bool
        var homeLayout: HomeLayout?
        var landscapePosters: Bool?
        var fullscreenHero: Bool?
        var posterSize: PosterSize?
        var showPosterLabels: Bool?
        var continueWatchingSortMode: ContinueWatchingSortMode?
        var nextUpFromFurthestEpisode: Bool?
        var showUnairedNextUp: Bool?
        var useEpisodeThumbnailsInCw: Bool?
        var blurUnwatchedEpisodes: Bool?
        var blurContinueWatchingNextUp: Bool?
        var posterCornerRadius: Int?
        var catalogAddonNameEnabled: Bool?
        var catalogTypeSuffixEnabled: Bool?
        var showFullReleaseDate: Bool?
        var detailPageTrailerButtonEnabled: Bool?
    }

    private func notifyLocalChange() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    private func notifyPresentationChange() {
        guard !suppressChange else { return }
        onPresentationChange?()
    }

    /// The presentation prefs as a syncable snapshot.
    var presentationSnapshot: HomePresentationSnapshot {
        HomePresentationSnapshot(
            homeLayout: homeLayout,
            landscapePosters: landscapePosters,
            fullscreenHero: fullscreenHero,
            posterSize: posterSize,
            showPosterLabels: showPosterLabels,
            continueWatchingSortMode: continueWatchingSortMode,
            nextUpFromFurthestEpisode: nextUpFromFurthestEpisode,
            showUnairedNextUp: showUnairedNextUp,
            useEpisodeThumbnailsInCw: useEpisodeThumbnailsInCw,
            blurUnwatchedEpisodes: blurUnwatchedEpisodes,
            blurContinueWatchingNextUp: blurContinueWatchingNextUp,
            posterCornerRadius: posterCornerRadius,
            catalogAddonNameEnabled: catalogAddonNameEnabled,
            catalogTypeSuffixEnabled: catalogTypeSuffixEnabled,
            showFullReleaseDate: showFullReleaseDate,
            detailPageTrailerButtonEnabled: detailPageTrailerButtonEnabled
        )
    }

    /// Apply presentation prefs pulled from the account without echoing back up.
    func applyRemotePresentation(_ s: HomePresentationSnapshot) {
        guard s != presentationSnapshot else { return }
        suppressChange = true
        homeLayout = Self.launchLayoutOverride ?? s.homeLayout
        landscapePosters = s.landscapePosters
        fullscreenHero = s.fullscreenHero
        posterSize = s.posterSize
        showPosterLabels = s.showPosterLabels
        continueWatchingSortMode = s.continueWatchingSortMode
        nextUpFromFurthestEpisode = s.nextUpFromFurthestEpisode
        showUnairedNextUp = s.showUnairedNextUp
        useEpisodeThumbnailsInCw = s.useEpisodeThumbnailsInCw
        blurUnwatchedEpisodes = s.blurUnwatchedEpisodes
        blurContinueWatchingNextUp = s.blurContinueWatchingNextUp
        posterCornerRadius = s.posterCornerRadius
        catalogAddonNameEnabled = s.catalogAddonNameEnabled
        catalogTypeSuffixEnabled = s.catalogTypeSuffixEnabled
        showFullReleaseDate = s.showFullReleaseDate
        detailPageTrailerButtonEnabled = s.detailPageTrailerButtonEnabled
        suppressChange = false
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            orderKeys = []
            disabledKeys = []
            customTitles = [:]
            suppressChange = true
            hideUnreleasedContent = false
            homeLayout = .modern
            suppressChange = false
            return
        }
        orderKeys = decoded.orderKeys
        disabledKeys = Set(decoded.disabledKeys)
        customTitles = decoded.customTitles
        suppressChange = true
        hideUnreleasedContent = decoded.hideUnreleasedContent
        homeLayout = decoded.homeLayout ?? .modern
        landscapePosters = decoded.landscapePosters ?? false
        fullscreenHero = decoded.fullscreenHero ?? true
        posterSize = decoded.posterSize ?? .medium
        showPosterLabels = decoded.showPosterLabels ?? true
        continueWatchingSortMode = decoded.continueWatchingSortMode ?? .recentlyWatched
        nextUpFromFurthestEpisode = decoded.nextUpFromFurthestEpisode ?? true
        showUnairedNextUp = decoded.showUnairedNextUp ?? true
        useEpisodeThumbnailsInCw = decoded.useEpisodeThumbnailsInCw ?? true
        blurUnwatchedEpisodes = decoded.blurUnwatchedEpisodes ?? false
        blurContinueWatchingNextUp = decoded.blurContinueWatchingNextUp ?? false
        posterCornerRadius = decoded.posterCornerRadius ?? 12
        catalogAddonNameEnabled = decoded.catalogAddonNameEnabled ?? false
        catalogTypeSuffixEnabled = decoded.catalogTypeSuffixEnabled ?? true
        showFullReleaseDate = decoded.showFullReleaseDate ?? true
        detailPageTrailerButtonEnabled = decoded.detailPageTrailerButtonEnabled ?? true
        suppressChange = false
    }

    private func save() {
        let persisted = Persisted(
            orderKeys: orderKeys,
            disabledKeys: Array(disabledKeys),
            customTitles: customTitles,
            hideUnreleasedContent: hideUnreleasedContent,
            homeLayout: homeLayout,
            landscapePosters: landscapePosters,
            fullscreenHero: fullscreenHero,
            posterSize: posterSize,
            showPosterLabels: showPosterLabels,
            continueWatchingSortMode: continueWatchingSortMode,
            nextUpFromFurthestEpisode: nextUpFromFurthestEpisode,
            showUnairedNextUp: showUnairedNextUp,
            useEpisodeThumbnailsInCw: useEpisodeThumbnailsInCw,
            blurUnwatchedEpisodes: blurUnwatchedEpisodes,
            blurContinueWatchingNextUp: blurContinueWatchingNextUp,
            posterCornerRadius: posterCornerRadius,
            catalogAddonNameEnabled: catalogAddonNameEnabled,
            catalogTypeSuffixEnabled: catalogTypeSuffixEnabled,
            showFullReleaseDate: showFullReleaseDate,
            detailPageTrailerButtonEnabled: detailPageTrailerButtonEnabled
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
