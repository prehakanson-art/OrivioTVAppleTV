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

// MARK: - Hero layout

/// How the Home hero behaves. Replaces the old "Pin hero to the top" switch,
/// which could only express two of these three.
enum HeroLayout: String, CaseIterable, Identifiable, Codable {
    /// A banner at the top of the scroll that cycles the top titles on a
    /// timer. Browsing never changes it — and it never changes where you are.
    case rolling
    /// A fixed header that always shows whatever card holds focus. Never
    /// rotates; browsing IS what drives it.
    case pinnedFocus
    /// Rolls at the top of the page, then hands over: the moment a content
    /// card takes focus the rolling stops and the hero follows the browse for
    /// the rest of the visit.
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rolling:     return "Rolling Hero"
        case .pinnedFocus: return "Pinned Focus"
        case .hybrid:      return "Hybrid"
        }
    }

    var summary: String {
        switch self {
        case .rolling:
            return "A banner that cycles the top titles on its own. Browsing doesn't change it."
        case .pinnedFocus:
            return "A fixed header showing whichever card you're on. Never cycles."
        case .hybrid:
            return "Cycles at the top, then follows what you're browsing once you move down into the rows."
        }
    }

    /// Lenient on purpose. `Persisted` uses synthesized `Codable`, so a raw
    /// value this build doesn't know (a case added by a LATER build, arriving
    /// through account sync) would throw out of the whole settings blob and
    /// reset every unrelated setting with it — see `UnreadableBlobGuard` in
    /// `load()`. Falling back costs the viewer this ONE preference instead.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HeroLayout(rawValue: raw) ?? .hybrid
    }
}


// MARK: - Navigation position

/// Where the primary navigation sits. The rail is the same component either
/// way — same items, icons, labels, focus behaviour and glass — turned on its
/// side; see `GlassSidebar`.
enum NavigationPosition: String, CaseIterable, Identifiable, Codable {
    /// The shipped layout: a vertical rail hugging the left edge.
    case left
    /// A horizontal bar across the top.
    case top

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left / Vertical"
        case .top:  return "Top / Horizontal"
        }
    }

    var summary: String {
        switch self {
        case .left: return "A vertical rail down the left edge. The default."
        case .top:  return "A horizontal bar across the top of the screen."
        }
    }

    /// True when the rail runs across the top. Reads better than `== .top` at
    /// the layout call sites.
    var isHorizontal: Bool { self == .top }

    /// Lenient, for the same reason `HeroLayout` is: a raw value a LATER build
    /// introduced must not throw out of the whole settings blob and reset every
    /// unrelated preference with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NavigationPosition(rawValue: raw) ?? .left
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
/// tvOS-only sync blob (see OrivioSyncManager.AppPreferencesSnapshot).
struct HomePresentationSnapshot: Codable, Equatable {
    var homeLayout: HomeLayout = .modern
    var landscapePosters = false
    var fullscreenHero = true
    var posterSize: PosterSize = .medium
    var showPosterLabels = true
    var showPosterBanners = true
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
    // Which optional sections the details page shows. All default ON, so a
    // viewer who never opens these settings sees exactly the page they always
    // did. These are DISPLAY switches — independent of the per-section TMDB
    // enrichment switches, which decide whether the data is fetched at all.
    /// Details page: Creator and Cast.
    var detailShowCast = true
    /// Details page: the collection ("part of…") row.
    var detailShowCollection = true
    /// Details page: More Like This.
    var detailShowMoreLikeThis = true
    /// Details page: Production companies.
    var detailShowProduction = true
    /// Details page: Trakt comments.
    var detailShowComments = true
    var showFeaturedBar = true
    /// Legacy. Superseded by `heroLayout`; kept so an older client's blob
    /// round-trips, and so the migration below has something to read.
    var pinnedHero = false
    var heroLayout: HeroLayout = .hybrid
    var autoHideSidebar = false
    /// Where the navigation rail sits. `.left` is the shipped layout and stays
    /// the default, so an existing install sees no change.
    var navigationPosition: NavigationPosition = .left
    var fullStreamTitles = false
    var heroTrailersEnabled = true
    var heroTrailerSound = false
    /// Which catalog feeds the Home hero, as a `catalogKey`. Empty means
    /// AUTOMATIC — the first row in Home's order, which is what the hero has
    /// always used and stays the default, so nothing moves for anyone who
    /// never opens this setting.
    var heroCatalogKey = ""
}

/// Tolerant decoding (in an extension so the memberwise init survives): a blob
/// written before a field existed decodes with that field's default instead of
/// failing wholesale and resetting every presentation pref on app update.
extension HomePresentationSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HomePresentationSnapshot()
        homeLayout = (try? c.decode(HomeLayout.self, forKey: .homeLayout)) ?? d.homeLayout
        landscapePosters = (try? c.decode(Bool.self, forKey: .landscapePosters)) ?? d.landscapePosters
        fullscreenHero = (try? c.decode(Bool.self, forKey: .fullscreenHero)) ?? d.fullscreenHero
        posterSize = (try? c.decode(PosterSize.self, forKey: .posterSize)) ?? d.posterSize
        showPosterLabels = (try? c.decode(Bool.self, forKey: .showPosterLabels)) ?? d.showPosterLabels
        showPosterBanners = (try? c.decode(Bool.self, forKey: .showPosterBanners)) ?? d.showPosterBanners
        continueWatchingSortMode = (try? c.decode(ContinueWatchingSortMode.self, forKey: .continueWatchingSortMode)) ?? d.continueWatchingSortMode
        nextUpFromFurthestEpisode = (try? c.decode(Bool.self, forKey: .nextUpFromFurthestEpisode)) ?? d.nextUpFromFurthestEpisode
        showUnairedNextUp = (try? c.decode(Bool.self, forKey: .showUnairedNextUp)) ?? d.showUnairedNextUp
        useEpisodeThumbnailsInCw = (try? c.decode(Bool.self, forKey: .useEpisodeThumbnailsInCw)) ?? d.useEpisodeThumbnailsInCw
        blurUnwatchedEpisodes = (try? c.decode(Bool.self, forKey: .blurUnwatchedEpisodes)) ?? d.blurUnwatchedEpisodes
        blurContinueWatchingNextUp = (try? c.decode(Bool.self, forKey: .blurContinueWatchingNextUp)) ?? d.blurContinueWatchingNextUp
        posterCornerRadius = (try? c.decode(Int.self, forKey: .posterCornerRadius)) ?? d.posterCornerRadius
        catalogAddonNameEnabled = (try? c.decode(Bool.self, forKey: .catalogAddonNameEnabled)) ?? d.catalogAddonNameEnabled
        catalogTypeSuffixEnabled = (try? c.decode(Bool.self, forKey: .catalogTypeSuffixEnabled)) ?? d.catalogTypeSuffixEnabled
        showFullReleaseDate = (try? c.decode(Bool.self, forKey: .showFullReleaseDate)) ?? d.showFullReleaseDate
        detailPageTrailerButtonEnabled = (try? c.decode(Bool.self, forKey: .detailPageTrailerButtonEnabled)) ?? d.detailPageTrailerButtonEnabled
        detailShowCast = (try? c.decode(Bool.self, forKey: .detailShowCast)) ?? d.detailShowCast
        detailShowCollection = (try? c.decode(Bool.self, forKey: .detailShowCollection)) ?? d.detailShowCollection
        detailShowMoreLikeThis = (try? c.decode(Bool.self, forKey: .detailShowMoreLikeThis)) ?? d.detailShowMoreLikeThis
        detailShowProduction = (try? c.decode(Bool.self, forKey: .detailShowProduction)) ?? d.detailShowProduction
        detailShowComments = (try? c.decode(Bool.self, forKey: .detailShowComments)) ?? d.detailShowComments
        showFeaturedBar = (try? c.decode(Bool.self, forKey: .showFeaturedBar)) ?? d.showFeaturedBar
        pinnedHero = (try? c.decode(Bool.self, forKey: .pinnedHero)) ?? d.pinnedHero
        // MIGRATION: a blob written before Hero Layout existed carries only the
        // boolean. Decoded AFTER `pinnedHero` so the fallback can read it.
        //
        // `true` was an explicit choice — someone reached into Settings and
        // turned that switch on — so it is honoured as `.pinnedFocus`. `false`
        // was only ever the absence of a choice, so it takes today's default
        // rather than being frozen as `.rolling` forever.
        heroLayout = (try? c.decode(HeroLayout.self, forKey: .heroLayout))
            ?? (pinnedHero ? .pinnedFocus : .hybrid)
        autoHideSidebar = (try? c.decode(Bool.self, forKey: .autoHideSidebar)) ?? d.autoHideSidebar
        navigationPosition = (try? c.decode(NavigationPosition.self, forKey: .navigationPosition)) ?? d.navigationPosition
        fullStreamTitles = (try? c.decode(Bool.self, forKey: .fullStreamTitles)) ?? d.fullStreamTitles
        heroTrailersEnabled = (try? c.decode(Bool.self, forKey: .heroTrailersEnabled)) ?? d.heroTrailersEnabled
        heroTrailerSound = (try? c.decode(Bool.self, forKey: .heroTrailerSound)) ?? d.heroTrailerSound
        heroCatalogKey = (try? c.decode(String.self, forKey: .heroCatalogKey)) ?? d.heroCatalogKey
    }
}

// MARK: - Sync payload (matches Android's home-catalog settings_json exactly)

/// The cross-platform home-catalog layout, wire-identical to the Orivio Android
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
    /// Sync-payload only: no code reads this and no settings row sets it (the
    /// Home hero is always fullscreen). Kept so account blobs written by other
    /// Orivio clients round-trip unchanged.
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
    /// Keep the tags some add-ons print into their poster artwork ("In
    /// Cinema", "#2 Today"). Off swaps in the plain poster the add-on sends
    /// alongside (`MetaItem.withPlainPoster()`) as catalogs and details are
    /// fetched. Written to `PosterBannerPreference` on EVERY assignment, ahead
    /// of the no-change guard: the fetch path can't read this main-actor store,
    /// and a profile switch or a sync pull has to reach it too.
    @Published var showPosterBanners: Bool = true {
        didSet {
            PosterBannerPreference.showBanners = showPosterBanners
            guard showPosterBanners != oldValue else { return }
            save(); notifyPresentationChange()
        }
    }
    /// The inline "Featured" hero bar between Continue Watching and the
    /// catalog rows. Off removes it from Home entirely.
    @Published var showFeaturedBar: Bool = true {
        didSet { guard showFeaturedBar != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Pin the hero to the top of Home and let it FOLLOW the focused card,
    /// instead of a banner that scrolls away and rotates on a timer. The
    /// spotlight rotation is switched off while this is on — the two are
    /// alternative answers to the same question ("what is the hero showing?")
    /// and running both means the art changes under the viewer's hands.
    @Published var pinnedHero: Bool = false {
        didSet { guard pinnedHero != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Hero Layout. The single control for how the hero
    /// behaves; `pinnedHero` above is the retired two-state version of it.
    @Published var heroLayout: HeroLayout = .hybrid {
        didSet { guard heroLayout != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Keep the glass rail off screen until it's wanted. It reappears on a
    /// sideways press from the leftmost content (and on Menu), so the rows run
    /// the full width of the screen the rest of the time.
    @Published var autoHideSidebar: Bool = false {
        didSet { guard autoHideSidebar != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Navigation Position.
    @Published var navigationPosition: NavigationPosition = .left {
        didSet { guard navigationPosition != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Sources page: let every link's release name wrap in full instead of
    /// truncating — the whole point of a remux hunt is reading the whole name.
    @Published var fullStreamTitles: Bool = false {
        didSet { guard fullStreamTitles != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Netflix-style billboard preview on the home hero (HeroTrailerLayer).
    @Published var heroTrailersEnabled: Bool = true {
        didSet { guard heroTrailersEnabled != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Play that preview with sound instead of muted.
    @Published var heroTrailerSound: Bool = false {
        didSet { guard heroTrailerSound != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Hero source: the `catalogKey` whose row feeds the
    /// hero. Empty = the first row in Home's order, which is what it always
    /// was. A key naming a row that is hidden (or ranked past Home's row cap)
    /// resolves back to that same first row rather than leaving a blank hero
    /// — see `HomeViewModel.heroCatalogRow`.
    @Published var heroCatalogKey: String = "" {
        didSet { guard heroCatalogKey != oldValue else { return }; save(); notifyPresentationChange() }
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
    @Published var autoRefreshMinutes: Int = UserDefaults.standard.integer(forKey: "orivio.home.autorefresh.v1") {
        didSet {
            guard autoRefreshMinutes != oldValue else { return }
            UserDefaults.standard.set(autoRefreshMinutes, forKey: "orivio.home.autorefresh.v1")
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
    /// Settings → Layout → Details Page: show Creator and Cast.
    @Published var detailShowCast: Bool = true {
        didSet { guard detailShowCast != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Details Page: show the collection ("part of…") row.
    @Published var detailShowCollection: Bool = true {
        didSet { guard detailShowCollection != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Details Page: show More Like This.
    @Published var detailShowMoreLikeThis: Bool = true {
        didSet { guard detailShowMoreLikeThis != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Details Page: show Production companies.
    @Published var detailShowProduction: Bool = true {
        didSet { guard detailShowProduction != oldValue else { return }; save(); notifyPresentationChange() }
    }
    /// Settings → Layout → Details Page: show Trakt comments.
    @Published var detailShowComments: Bool = true {
        didSet { guard detailShowComments != oldValue else { return }; save(); notifyPresentationChange() }
    }

    /// Selectable poster corner radii (points).
    static let posterCornerRadiusValues: [Int] = [0, 6, 12, 16, 22]

    var onLocalChange: (() -> Void)?
    /// Fired when a device-local presentation pref changes, so the tvOS sync
    /// blob (player/TMDB/theme/home) can push it.
    var onPresentationChange: (() -> Void)?
    private var suppressChange = false
    /// Read from the SAME key `ProfileStore` persists, so the scope is right
    /// from LAUNCH. The sync manager rescopes every store shortly after start,
    /// but defaulting to 1 here meant a device on any other profile decoded
    /// profile 1's blob on the main actor and then decoded the correct one a
    /// moment later — twice the launch cost, and a reload cascade on top.
    /// `RatingsStore` and `TraktStore` already do this.
    private static let activeProfileKey = "orivio.profiles.active"
    private var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1

    private static let baseKey = "orivio.homecatalog.v1"

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

    /// Splice saved keys the caller doesn't know about back into a reordered
    /// list. The Layout editor works in `mergedOrder` terms — only what this
    /// device can resolve — so writing its result back verbatim would delete
    /// every key belonging to the phone's add-ons, a disabled add-on, or a
    /// collection this profile hides. Each unknown key re-attaches behind the
    /// same visible key it used to follow (head-anchored ones stay at the
    /// front), so its position survives a reorder it wasn't part of.
    private func reanchoring(_ keys: [String]) -> [String] {
        let known = Set(keys)
        var head: [String] = []
        var trailing: [String: [String]] = [:]
        var anchor: String?
        for key in orderKeys {
            if known.contains(key) {
                anchor = key
            } else if let anchor {
                trailing[anchor, default: []].append(key)
            } else {
                head.append(key)
            }
        }
        var result = head
        for key in keys {
            result.append(key)
            if let extras = trailing[key] { result.append(contentsOf: extras) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    func setOrder(_ keys: [String]) {
        let full = reanchoring(keys)
        guard full != orderKeys else { return }
        orderKeys = full
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
        // The collections' own relative order has to come from the order being
        // EDITED, not from `collectionKeys` — that argument is the store's
        // array order (whatever sequence the collections happened to load in),
        // and re-emitting it here overwrote an arrangement made elsewhere.
        // Moving any row on this screen therefore re-sorted every collection,
        // and the push that followed sent that re-sort back to the account, so
        // an order set up on the phone was lost by touching the TV's list at
        // all. A block move should move the block and nothing else.
        let collectionKeySet = Set(collectionKeys)
        var orderedCollectionKeys = order.filter { collectionKeySet.contains($0) }
        // `mergedOrder` already contains every available collection key, so
        // this is normally empty — it is here so a key that somehow isn't in
        // `order` is appended rather than dropped from the layout entirely.
        let placed = Set(orderedCollectionKeys)
        orderedCollectionKeys += collectionKeys.filter { !placed.contains($0) }
        var result: [String] = []
        for u in units {
            if u == Self.collectionsUnit { result.append(contentsOf: orderedCollectionKeys) }
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

    /// Order to PUSH: every saved key keeps its slot — including keys this
    /// device can't currently resolve — then newly-available catalogs, then
    /// new collections.
    ///
    /// This deliberately does NOT use `mergedOrder`, which filters to what is
    /// available right now. That filter is correct for rendering and wrong for
    /// the wire: the blob is shared across every device, platform and profile,
    /// so "not available HERE" is routinely "installed on the phone",
    /// "belonging to a temporarily disabled add-on", or "hidden on this
    /// profile" — and pushing the filtered list deleted those positions for
    /// everyone. Disabling one add-on, or pushing before add-ons finished
    /// loading, was enough to flatten the account's whole Home order.
    private func exportOrder(catalogKeys: [String], collectionKeys: [String]) -> [String] {
        var seen = Set<String>()
        let saved = orderKeys.filter { seen.insert($0).inserted }
        return saved
            + catalogKeys.filter { seen.insert($0).inserted }
            + collectionKeys.filter { seen.insert($0).inserted }
    }

    /// Build the push payload from currently-available addons + collections.
    /// New catalogs (then collections) append to the saved order, exactly like
    /// Android's buildHomeCatalogSyncPayload; disabled keys and custom titles
    /// ship as-is (they already include anything pulled from the phone, so
    /// cross-device state isn't dropped).
    ///
    /// `collections` must be the account-wide LIBRARY, not a profile's visible
    /// subset — see the note on exportOrder.
    func exportPayload(addons: [InstalledAddon], collections: [OrivioCollection]) -> SyncHomeCatalogPayload {
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

        let order = exportOrder(catalogKeys: catalogKeys, collectionKeys: collectionKeys)
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
        orderKeys = payload.orderKeys
        disabledKeys = Set(payload.disabledKeys)
        customTitles = payload.customTitles.filter { !$0.value.isEmpty }
        hideUnreleasedContent = payload.hideUnreleasedContent
        // Lift the suppression BEFORE the write: `save()` now early-returns
        // while suppressed (so a bulk assign writes once, not once per
        // property), and this is the one write that has to land. Matches
        // `applyRemotePresentation` below.
        suppressChange = false
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
        var showPosterBanners: Bool?
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
        var detailShowCast: Bool?
        var detailShowCollection: Bool?
        var detailShowMoreLikeThis: Bool?
        var detailShowProduction: Bool?
        var detailShowComments: Bool?
        var showFeaturedBar: Bool?
        var pinnedHero: Bool?
        var heroLayout: HeroLayout?
        var autoHideSidebar: Bool?
        var navigationPosition: NavigationPosition?
        var fullStreamTitles: Bool?
        var heroTrailersEnabled: Bool?
        var heroTrailerSound: Bool?
        var heroCatalogKey: String?
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
            showPosterBanners: showPosterBanners,
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
            detailPageTrailerButtonEnabled: detailPageTrailerButtonEnabled,
            detailShowCast: detailShowCast,
            detailShowCollection: detailShowCollection,
            detailShowMoreLikeThis: detailShowMoreLikeThis,
            detailShowProduction: detailShowProduction,
            detailShowComments: detailShowComments,
            showFeaturedBar: showFeaturedBar,
            pinnedHero: pinnedHero,
            heroLayout: heroLayout,
            autoHideSidebar: autoHideSidebar,
            navigationPosition: navigationPosition,
            fullStreamTitles: fullStreamTitles,
            heroTrailersEnabled: heroTrailersEnabled,
            heroTrailerSound: heroTrailerSound,
            heroCatalogKey: heroCatalogKey
        )
    }

    /// Every presentation pref back to its shipped default. Called by `load()`
    /// for a profile that has no saved blob, so nothing carries over from the
    /// profile we just switched away from.
    private func applyPresentationDefaults() {
        let d = HomePresentationSnapshot()
        homeLayout = d.homeLayout
        landscapePosters = d.landscapePosters
        fullscreenHero = d.fullscreenHero
        posterSize = d.posterSize
        showPosterLabels = d.showPosterLabels
        showPosterBanners = d.showPosterBanners
        continueWatchingSortMode = d.continueWatchingSortMode
        nextUpFromFurthestEpisode = d.nextUpFromFurthestEpisode
        showUnairedNextUp = d.showUnairedNextUp
        useEpisodeThumbnailsInCw = d.useEpisodeThumbnailsInCw
        blurUnwatchedEpisodes = d.blurUnwatchedEpisodes
        blurContinueWatchingNextUp = d.blurContinueWatchingNextUp
        posterCornerRadius = d.posterCornerRadius
        catalogAddonNameEnabled = d.catalogAddonNameEnabled
        catalogTypeSuffixEnabled = d.catalogTypeSuffixEnabled
        showFullReleaseDate = d.showFullReleaseDate
        detailPageTrailerButtonEnabled = d.detailPageTrailerButtonEnabled
        detailShowCast = d.detailShowCast
        detailShowCollection = d.detailShowCollection
        detailShowMoreLikeThis = d.detailShowMoreLikeThis
        detailShowProduction = d.detailShowProduction
        detailShowComments = d.detailShowComments
        showFeaturedBar = d.showFeaturedBar
        pinnedHero = d.pinnedHero
        heroLayout = d.heroLayout
        autoHideSidebar = d.autoHideSidebar
        navigationPosition = d.navigationPosition
        fullStreamTitles = d.fullStreamTitles
        heroTrailersEnabled = d.heroTrailersEnabled
        heroTrailerSound = d.heroTrailerSound
        heroCatalogKey = d.heroCatalogKey
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
        showPosterBanners = s.showPosterBanners
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
        detailShowCast = s.detailShowCast
        detailShowCollection = s.detailShowCollection
        detailShowMoreLikeThis = s.detailShowMoreLikeThis
        detailShowProduction = s.detailShowProduction
        detailShowComments = s.detailShowComments
        showFeaturedBar = s.showFeaturedBar
        pinnedHero = s.pinnedHero
        heroLayout = s.heroLayout
        autoHideSidebar = s.autoHideSidebar
        navigationPosition = s.navigationPosition
        fullStreamTitles = s.fullStreamTitles
        heroTrailersEnabled = s.heroTrailersEnabled
        heroTrailerSound = s.heroTrailerSound
        heroCatalogKey = s.heroCatalogKey
        suppressChange = false
        save()
    }

    private func load() {
        let raw = UserDefaults.standard.data(forKey: storageKey)
        let decodedBlob = raw.flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        // A blob that exists but no longer decodes (a newer build's enum case,
        // say) is preserved before the defaults below get written over it on
        // this profile's first save.
        if let raw, decodedBlob == nil {
            UnreadableBlobGuard.preserve(raw, key: storageKey)
        }
        guard let decoded = decodedBlob else {
            // A profile with no saved blob must reset EVERY field, not just
            // order/disabled/titles/hideUnreleased/homeLayout: the presentation
            // prefs used to keep the previous profile's values and then got
            // written into the new profile's key on its first save — switching
            // to a fresh profile silently inherited (and stole) the old
            // profile's poster size, blur, CW sort, etc.
            orderKeys = []
            disabledKeys = []
            customTitles = [:]
            suppressChange = true
            hideUnreleasedContent = false
            applyPresentationDefaults()
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
        showPosterBanners = decoded.showPosterBanners ?? true
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
        detailShowCast = decoded.detailShowCast ?? true
        detailShowCollection = decoded.detailShowCollection ?? true
        detailShowMoreLikeThis = decoded.detailShowMoreLikeThis ?? true
        detailShowProduction = decoded.detailShowProduction ?? true
        detailShowComments = decoded.detailShowComments ?? true
        showFeaturedBar = decoded.showFeaturedBar ?? true
        pinnedHero = decoded.pinnedHero ?? false
        // Same migration as the snapshot: a blob from an older build of this
        // app has only the boolean.
        heroLayout = decoded.heroLayout ?? (pinnedHero ? .pinnedFocus : .hybrid)
        autoHideSidebar = decoded.autoHideSidebar ?? false
        navigationPosition = decoded.navigationPosition ?? .left
        fullStreamTitles = decoded.fullStreamTitles ?? false
        heroTrailersEnabled = decoded.heroTrailersEnabled ?? true
        heroTrailerSound = decoded.heroTrailerSound ?? false
        heroCatalogKey = decoded.heroCatalogKey ?? ""
        suppressChange = false
    }

    private func save() {
        // Bulk assigns (`load`, `applyRemotePresentation`) set `suppressChange`
        // and then write all ~22 published properties in a row, each with a
        // `didSet { save() }`. Without this the store re-encoded and re-wrote
        // the entire settings blob 22 times per apply — at launch, on every
        // profile switch, and on every sync that carried a preference change.
        // Both bulk paths call `save()` once themselves at the end.
        guard !suppressChange else { return }
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
            showPosterBanners: showPosterBanners,
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
            detailPageTrailerButtonEnabled: detailPageTrailerButtonEnabled,
            detailShowCast: detailShowCast,
            detailShowCollection: detailShowCollection,
            detailShowMoreLikeThis: detailShowMoreLikeThis,
            detailShowProduction: detailShowProduction,
            detailShowComments: detailShowComments,
            showFeaturedBar: showFeaturedBar,
            pinnedHero: pinnedHero,
            heroLayout: heroLayout,
            autoHideSidebar: autoHideSidebar,
            navigationPosition: navigationPosition,
            fullStreamTitles: fullStreamTitles,
            heroTrailersEnabled: heroTrailersEnabled,
            heroTrailerSound: heroTrailerSound,
            heroCatalogKey: heroCatalogKey
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
