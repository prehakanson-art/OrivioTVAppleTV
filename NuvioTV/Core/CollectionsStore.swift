import Foundation

/// Decodes `T` if possible, otherwise nil — so a single malformed element in
/// an array (a collection / folder / source written by another platform or a
/// newer app version) doesn't throw and drop the ENTIRE array. Used for the
/// synced collections blob so every valid custom catalog still comes through.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - Models
//
// These mirror the Android app's Gson-serialized collection shape exactly
// (CollectionsDataStore.SerializableCollection et al) so the JSON blob synced
// through `sync_push/pull_collections` round-trips between platforms without
// loss. TMDB/Trakt sources are carried through untouched even though tvOS
// can't render them yet (they need the #4 integrations).

struct CollectionSourceDTO: Codable, Hashable {
    var provider: String = "addon"
    // addon provider
    var addonId: String?
    var type: String?
    var catalogId: String?
    var genre: String?
    // tmdb provider (preserved, not yet rendered on tvOS)
    var tmdbSourceType: String?
    var title: String?
    var tmdbId: Int?
    // trakt provider (preserved, not yet rendered on tvOS)
    var traktListId: Int64?
    // shared tmdb/trakt fields
    var mediaType: String?
    var sortBy: String?
    var sortHow: String?
    var filters: TmdbFiltersDTO?

    var isAddonSource: Bool { provider.lowercased() == "addon" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "addon"
        addonId = try c.decodeIfPresent(String.self, forKey: .addonId)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        tmdbSourceType = try c.decodeIfPresent(String.self, forKey: .tmdbSourceType)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
        traktListId = try c.decodeIfPresent(Int64.self, forKey: .traktListId)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        sortBy = try c.decodeIfPresent(String.self, forKey: .sortBy)
        sortHow = try c.decodeIfPresent(String.self, forKey: .sortHow)
        filters = try c.decodeIfPresent(TmdbFiltersDTO.self, forKey: .filters)
    }

    init(addonId: String, type: String, catalogId: String, genre: String? = nil) {
        self.provider = "addon"
        self.addonId = addonId
        self.type = type
        self.catalogId = catalogId
        self.genre = genre
    }

    /// A TMDB source (LIST/COLLECTION/COMPANY/NETWORK/DISCOVER/PERSON/DIRECTOR).
    init(
        tmdbSourceType: String, title: String, tmdbId: Int?,
        mediaType: String = "movie", sortBy: String? = nil, filters: TmdbFiltersDTO? = nil
    ) {
        self.provider = "tmdb"
        self.tmdbSourceType = tmdbSourceType
        self.title = title
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.sortBy = sortBy
        self.filters = filters
    }

    /// A Trakt public/personal list source.
    init(traktListId: Int64, title: String, mediaType: String = "movie", sortBy: String = "rank", sortHow: String = "asc") {
        self.provider = "trakt"
        self.traktListId = traktListId
        self.title = title
        self.mediaType = mediaType
        self.sortBy = sortBy
        self.sortHow = sortHow
    }

    var isTMDBSource: Bool { provider.lowercased() == "tmdb" }
    var isTraktSource: Bool { provider.lowercased() == "trakt" }

    // Gson omits nulls; match that so the blob compares stable across pushes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(addonId, forKey: .addonId)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(catalogId, forKey: .catalogId)
        try c.encodeIfPresent(genre, forKey: .genre)
        try c.encodeIfPresent(tmdbSourceType, forKey: .tmdbSourceType)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(tmdbId, forKey: .tmdbId)
        try c.encodeIfPresent(traktListId, forKey: .traktListId)
        try c.encodeIfPresent(mediaType, forKey: .mediaType)
        try c.encodeIfPresent(sortBy, forKey: .sortBy)
        try c.encodeIfPresent(sortHow, forKey: .sortHow)
        try c.encodeIfPresent(filters, forKey: .filters)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, addonId, type, catalogId, genre, tmdbSourceType, title
        case tmdbId, traktListId, mediaType, sortBy, sortHow, filters
    }
}

struct TmdbFiltersDTO: Codable, Hashable {
    // Defaults so callers can build a filter with just the field(s) they need
    // (e.g. `TmdbFiltersDTO(withGenres: "28")`).
    var withGenres: String? = nil
    var releaseDateGte: String? = nil
    var releaseDateLte: String? = nil
    var voteAverageGte: Double? = nil
    var voteAverageLte: Double? = nil
    var voteCountGte: Int? = nil
    var withOriginalLanguage: String? = nil
    var withOriginCountry: String? = nil
    var withKeywords: String? = nil
    var withCompanies: String? = nil
    var withNetworks: String? = nil
    var year: Int? = nil
    var watchRegion: String? = nil
    var withWatchProviders: String? = nil
    /// Rolling "released in the last N days" window, computed fresh at query
    /// time (not a fixed date, which would go stale) — pairs with sorting by
    /// popularity instead of release date. Verified live that plain
    /// `sort_by=primary_release_date.desc` surfaces unreleased 2029-2099
    /// placeholder entries with zero votes, not watchable "newest releases".
    /// tvOS-only; nil unless a preset explicitly opts in.
    var recentDays: Int? = nil
}

struct NuvioCollectionFolder: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var coverImageUrl: String?
    var focusGifUrl: String?
    var focusGifEnabled: Bool?
    var coverEmoji: String?
    var tileShape: String = "SQUARE"   // SQUARE | POSTER | LANDSCAPE
    var hideTitle: Bool = false
    var sources: [CollectionSourceDTO]?
    var catalogSources: [CollectionSourceDTO]?   // legacy field, addon-only shape
    var heroBackdropUrl: String?
    var heroVideoUrl: String?
    var titleLogoUrl: String?

    /// Effective sources: modern `sources` wins, legacy `catalogSources` as fallback.
    var effectiveSources: [CollectionSourceDTO] {
        if let sources, !sources.isEmpty { return sources }
        return catalogSources ?? []
    }

    var addonSources: [CollectionSourceDTO] {
        effectiveSources.filter { $0.isAddonSource }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        coverImageUrl = try c.decodeIfPresent(String.self, forKey: .coverImageUrl)
        focusGifUrl = try c.decodeIfPresent(String.self, forKey: .focusGifUrl)
        focusGifEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusGifEnabled)
        coverEmoji = try c.decodeIfPresent(String.self, forKey: .coverEmoji)
        tileShape = try c.decodeIfPresent(String.self, forKey: .tileShape) ?? "SQUARE"
        hideTitle = try c.decodeIfPresent(Bool.self, forKey: .hideTitle) ?? false
        // Lenient element decode: a bad source doesn't drop the folder.
        sources = try c.decodeIfPresent([Lenient<CollectionSourceDTO>].self, forKey: .sources)?.compactMap(\.value)
        catalogSources = try c.decodeIfPresent([Lenient<CollectionSourceDTO>].self, forKey: .catalogSources)?.compactMap(\.value)
        heroBackdropUrl = try c.decodeIfPresent(String.self, forKey: .heroBackdropUrl)
        heroVideoUrl = try c.decodeIfPresent(String.self, forKey: .heroVideoUrl)
        titleLogoUrl = try c.decodeIfPresent(String.self, forKey: .titleLogoUrl)
    }

    init(id: String, title: String, sources: [CollectionSourceDTO]) {
        self.id = id
        self.title = title
        self.sources = sources
        self.catalogSources = sources.filter { $0.isAddonSource }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(coverImageUrl, forKey: .coverImageUrl)
        try c.encodeIfPresent(focusGifUrl, forKey: .focusGifUrl)
        try c.encodeIfPresent(focusGifEnabled, forKey: .focusGifEnabled)
        try c.encodeIfPresent(coverEmoji, forKey: .coverEmoji)
        try c.encode(tileShape, forKey: .tileShape)
        try c.encode(hideTitle, forKey: .hideTitle)
        // Android always writes both `sources` and the legacy `catalogSources`.
        try c.encode(effectiveSources, forKey: .sources)
        try c.encode(addonSources.map { source in
            CollectionSourceDTO(
                addonId: source.addonId ?? "",
                type: source.type ?? "",
                catalogId: source.catalogId ?? "",
                genre: source.genre
            )
        }, forKey: .catalogSources)
        try c.encodeIfPresent(heroBackdropUrl, forKey: .heroBackdropUrl)
        try c.encodeIfPresent(heroVideoUrl, forKey: .heroVideoUrl)
        try c.encodeIfPresent(titleLogoUrl, forKey: .titleLogoUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, coverImageUrl, focusGifUrl, focusGifEnabled, coverEmoji
        case tileShape, hideTitle, sources, catalogSources
        case heroBackdropUrl, heroVideoUrl, titleLogoUrl
    }
}

struct NuvioCollection: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var backdropImageUrl: String?
    var pinToTop: Bool = false
    var focusGlowEnabled: Bool?
    /// Default presentation for a collection. ROWS (each folder its own
    /// horizontal row) is the default; TABBED_GRID is the folder-tab grid.
    var viewMode: String = "ROWS"
    var showAllTab: Bool = true
    var folders: [NuvioCollectionFolder] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        backdropImageUrl = try c.decodeIfPresent(String.self, forKey: .backdropImageUrl)
        pinToTop = try c.decodeIfPresent(Bool.self, forKey: .pinToTop) ?? false
        focusGlowEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusGlowEnabled)
        viewMode = try c.decodeIfPresent(String.self, forKey: .viewMode) ?? "ROWS"
        showAllTab = try c.decodeIfPresent(Bool.self, forKey: .showAllTab) ?? true
        // Lenient element decode: a bad folder doesn't drop the collection.
        folders = (try c.decodeIfPresent([Lenient<NuvioCollectionFolder>].self, forKey: .folders) ?? []).compactMap(\.value)
    }

    init(id: String, title: String, folders: [NuvioCollectionFolder] = []) {
        self.id = id
        self.title = title
        self.folders = folders
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(backdropImageUrl, forKey: .backdropImageUrl)
        try c.encode(pinToTop, forKey: .pinToTop)
        try c.encodeIfPresent(focusGlowEnabled, forKey: .focusGlowEnabled)
        try c.encode(viewMode, forKey: .viewMode)
        try c.encode(showAllTab, forKey: .showAllTab)
        try c.encode(folders, forKey: .folders)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, backdropImageUrl, pinToTop, focusGlowEnabled
        case viewMode, showAllTab, folders
    }
}

// MARK: - Store

/// Per-profile collections, persisted locally and synced as a whole-profile
/// JSON blob (matching Android's CollectionsDataStore + CollectionSyncService).
@MainActor
final class CollectionsStore: ObservableObject {
    /// Collections VISIBLE on the active profile — what Home, Discover and the
    /// rest of the app render. This is `library` minus the profile's hidden set.
    @Published private(set) var collections: [NuvioCollection] = []

    /// Every collection on the account, regardless of which profile hides it.
    /// Collections used to be stored per-profile, which is why a pack added on
    /// one profile ("Kaptain's Collection") was invisible to every other. The
    /// library is now account-wide and each profile only chooses what to SHOW.
    @Published private(set) var library: [NuvioCollection] = []

    /// Collection ids this profile has switched off. Per-profile, and an opt-OUT
    /// so a newly added collection appears everywhere by default.
    @Published private(set) var hiddenIDs: Set<String> = []

    /// FOLDER ids this profile has switched off — e.g. keep "Streaming
    /// Services" but drop HBO Max from it. Per-profile, opt-out like the above.
    @Published private(set) var hiddenFolderIDs: Set<String> = []

    /// COLLECTION ids switched off for the whole account (Settings →
    /// Collections). Same relationship to `hiddenIDs` as the folder pair below:
    /// account-wide is the baseline, a profile may hide more on top.
    @Published private(set) var globalHiddenIDs: Set<String> = []

    /// Folder ids switched off for the WHOLE account (Settings → Collections).
    /// This is the catalog-wide default; a profile can still hide more on top,
    /// so the effective rule is `global ∪ profile`. Lets you curate one shared
    /// set and let individual profiles trim it further.
    @Published private(set) var globalHiddenFolderIDs: Set<String> = []

    /// Fired after a user-initiated change so account sync can push. Not
    /// fired while applying remote data (guarded by `suppressChange`).
    var onLocalChange: (() -> Void)?
    /// Fired when only this profile's visibility changed — the library itself is
    /// untouched, so the sync manager pushes the per-profile blob, not the
    /// shared one.
    var onVisibilityChange: (() -> Void)?
    private var suppressChange = false
    private var profileID = 1

    private static let baseKey = "nuvio.collections.v1"
    /// Account-wide library key (no profile suffix).
    private static let libraryKey = "nuvio.collections.library.v1"

    /// Legacy per-profile key, still read once during migration.
    private var legacyStorageKey: String {
        profileID == 1 ? Self.baseKey : "\(Self.baseKey).p\(profileID)"
    }
    private var hiddenKey: String { "nuvio.collections.hidden.p\(profileID)" }
    private var hiddenFoldersKey: String { "nuvio.collections.hiddenFolders.p\(profileID)" }
    private static let globalHiddenFoldersKey = "nuvio.collections.hiddenFolders.global.v1"
    private static let globalHiddenCollectionsKey = "nuvio.collections.hidden.global.v1"

    init() {
        load()
    }

    /// Re-scope to a profile. The LIBRARY is account-wide and unaffected; only
    /// the hidden set is per-profile, so switching profiles just re-filters.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        hiddenFolderIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenFoldersKey) ?? [])
        recomputeVisible()
    }

    /// Add to the shared library. Visible on every profile that hasn't hidden
    /// it — including the ones that didn't add it.
    func add(_ collection: NuvioCollection) {
        library.append(collection)
        save()
        recomputeVisible()
        notifyLocalChange()
    }

    func update(_ collection: NuvioCollection) {
        guard let index = library.firstIndex(where: { $0.id == collection.id }) else { return }
        library[index] = collection
        save()
        recomputeVisible()
        notifyLocalChange()
    }

    /// Remove from the account entirely (all profiles). To hide it on just this
    /// profile use `setVisible(false:id:)`.
    func remove(id: String) {
        library.removeAll { $0.id == id }
        hiddenIDs.remove(id)
        save()
        recomputeVisible()
        notifyLocalChange()
    }

    func generateID() -> String { UUID().uuidString }

    // MARK: Sync plumbing

    /// The JSON array blob pushed to `sync_push_collections`. Exports the whole
    /// LIBRARY, not the visible subset — otherwise hiding a collection on one
    /// profile would delete it from the account for everyone.
    func exportJSON() -> String {
        guard !library.isEmpty,
              let data = try? JSONEncoder().encode(library),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// This profile's hidden ids, for the per-profile side of the sync.
    var hiddenIDsForSync: [String] { Array(hiddenIDs).sorted() }
    var hiddenFolderIDsForSync: [String] { Array(hiddenFolderIDs).sorted() }
    /// Account-wide folder opt-outs — pushed with the shared library, not the
    /// per-profile blob.
    var globalHiddenFolderIDsForSync: [String] { Array(globalHiddenFolderIDs).sorted() }
    var globalHiddenCollectionIDsForSync: [String] { Array(globalHiddenIDs).sorted() }

    /// Apply the account-wide COLLECTION opt-outs (nil remote = no opinion,
    /// handled by the caller).
    func applyRemoteGlobalHidden(_ ids: Set<String>) {
        guard ids != globalHiddenIDs else { return }
        NSLog("[OrivioCollections] applyRemoteGlobalHidden %d->%d", globalHiddenIDs.count, ids.count)
        suppressChange = true
        defer { suppressChange = false }
        globalHiddenIDs = ids
        saveHidden()
        recomputeVisible()
    }

    func applyRemoteHiddenFolders(profile: Set<String>, global: Set<String>) {
        guard profile != hiddenFolderIDs || global != globalHiddenFolderIDs else { return }
        NSLog("[OrivioCollections] applyRemoteHiddenFolders profile %d->%d global %d->%d",
              hiddenFolderIDs.count, profile.count, globalHiddenFolderIDs.count, global.count)
        suppressChange = true
        defer { suppressChange = false }
        hiddenFolderIDs = profile
        globalHiddenFolderIDs = global
        saveHidden()
        recomputeVisible()
    }

    /// Apply a remote blob. Mirrors Android: remote-empty-while-local-has-data
    /// preserves local; identical JSON is a no-op. Returns true when applied.
    @discardableResult
    func applyRemote(json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        // Lenient element decode so one malformed collection (from another
        // platform / newer version) can't drop every other custom catalog.
        guard let lenient = try? JSONDecoder().decode([Lenient<NuvioCollection>].self, from: data) else { return false }
        return applyRemote(collections: lenient.compactMap(\.value))
    }

    /// Apply already-decoded remote collections (from the tvOS preferences
    /// blob). Same empty-preserve / no-op-on-identical rules as the JSON path.
    @discardableResult
    func applyRemote(collections remote: [NuvioCollection]) -> Bool {
        // Applies to the shared LIBRARY. Same guards as before: an empty remote
        // while we hold data is a race, not a clear-all; identical is a no-op.
        if remote.isEmpty && !library.isEmpty { return false }
        guard remote != library else { return false }
        suppressChange = true
        defer { suppressChange = false }
        library = remote
        save()
        recomputeVisible()
        return true
    }

    /// Merge a remote library into the shared one, de-duplicated by title with
    /// the richer copy winning — the same rule the local migration uses. Used
    /// when pulling the per-profile collection rows that predate the shared
    /// library, so a pack that only ever lived on one profile is adopted
    /// account-wide instead of being dropped.
    @discardableResult
    func mergeIntoLibrary(_ remote: [NuvioCollection]) -> Bool {
        guard !remote.isEmpty else { return false }
        var byTitle: [String: NuvioCollection] = [:]
        var order: [String] = []
        for c in library + remote {
            let key = c.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let existing = byTitle[key] {
                if Self.richness(c) > Self.richness(existing) { byTitle[key] = c }
            } else {
                byTitle[key] = c
                order.append(key)
            }
        }
        let merged = order.compactMap { byTitle[$0] }
        guard merged != library else { return false }
        suppressChange = true
        defer { suppressChange = false }
        library = merged
        save()
        recomputeVisible()
        return true
    }

    // MARK: Persistence

    private func notifyLocalChange() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    // MARK: Visibility (per profile)

    /// Visible on the ACTIVE profile — account-wide switch AND this profile's.
    func isVisible(_ id: String) -> Bool {
        !hiddenIDs.contains(id) && !globalHiddenIDs.contains(id)
    }

    /// Whether the collection is on ACCOUNT-WIDE (the catalog-settings switch).
    func isGloballyVisible(_ id: String) -> Bool { !globalHiddenIDs.contains(id) }

    /// Show/hide a whole collection for EVERY profile.
    func setGloballyVisible(_ visible: Bool, id: String) {
        let changed = visible ? globalHiddenIDs.remove(id) != nil
                              : globalHiddenIDs.insert(id).inserted
        guard changed else { return }
        saveLibrary()
        saveHidden()
        recomputeVisible()
        guard !suppressChange else { return }
        onLocalChange?()      // account-wide → push the shared blob
    }

    /// Show/hide one collection on the ACTIVE profile. The collection stays in
    /// the account-wide library either way.
    func setVisible(_ visible: Bool, id: String) {
        let changed = visible ? hiddenIDs.remove(id) != nil : hiddenIDs.insert(id).inserted
        guard changed else { return }
        saveHidden()
        recomputeVisible()
        guard !suppressChange else { return }
        onVisibilityChange?()
    }

    /// Apply a pulled hidden-set for the active profile without echoing back.
    /// Apply this profile's hidden set from the account. `nil` means the blob
    /// doesn't CARRY the key (written before it existed) — which must not be
    /// read as "nothing is hidden", or the pull un-hides collections the user
    /// switched off and the next push writes that back. Same rule the
    /// account-wide setters below already follow.
    func applyRemoteHidden(_ ids: Set<String>?) {
        guard let ids, ids != hiddenIDs else { return }
        NSLog("[OrivioCollections] applyRemoteHidden %d->%d (p%d)", hiddenIDs.count, ids.count, profileID)
        suppressChange = true
        defer { suppressChange = false }
        hiddenIDs = ids
        saveHidden()
        recomputeVisible()
    }

    // MARK: Folder visibility

    /// Effective hidden-folder set: the account-wide default plus this
    /// profile's own extra opt-outs.
    private var effectiveHiddenFolders: Set<String> {
        globalHiddenFolderIDs.union(hiddenFolderIDs)
    }

    func isFolderVisible(_ id: String) -> Bool { !effectiveHiddenFolders.contains(id) }
    /// Whether the folder is hidden ACCOUNT-WIDE (the catalog-settings switch).
    func isFolderGloballyVisible(_ id: String) -> Bool { !globalHiddenFolderIDs.contains(id) }

    /// Show/hide a folder on the ACTIVE profile only.
    func setFolderVisible(_ visible: Bool, id: String) {
        let changed = visible ? hiddenFolderIDs.remove(id) != nil
                              : hiddenFolderIDs.insert(id).inserted
        guard changed else { return }
        saveHidden()
        recomputeVisible()
        guard !suppressChange else { return }
        onVisibilityChange?()
    }

    /// Show/hide a folder for the WHOLE account (catalog settings default).
    func setFolderGloballyVisible(_ visible: Bool, id: String) {
        let changed = visible ? globalHiddenFolderIDs.remove(id) != nil
                              : globalHiddenFolderIDs.insert(id).inserted
        guard changed else { return }
        saveLibrary()          // global set rides with the shared library
        saveHidden()
        recomputeVisible()
        guard !suppressChange else { return }
        onLocalChange?()       // account-wide → push the shared blob
    }

    /// The folders of `collection` that this profile should actually see.
    func visibleFolders(in collection: NuvioCollection) -> [NuvioCollectionFolder] {
        let hidden = effectiveHiddenFolders
        return collection.folders.filter { !hidden.contains($0.id) }
    }

    private func recomputeVisible() {
        let hiddenFolders = effectiveHiddenFolders
        let next: [NuvioCollection] = library.compactMap { collection in
            guard !hiddenIDs.contains(collection.id),
                  !globalHiddenIDs.contains(collection.id) else { return nil }
            guard !hiddenFolders.isEmpty else { return collection }
            var trimmed = collection
            trimmed.folders = collection.folders.filter { !hiddenFolders.contains($0.id) }
            // A collection whose folders are all switched off has nothing to
            // show — drop the empty row rather than render a dead tile.
            return trimmed.folders.isEmpty ? nil : trimmed
        }
        // Publish ONLY on a real change. One account sync calls this five or
        // six times over (library merge, prefs blob, profile-hidden,
        // account-hidden, hidden folders), and an unconditional assignment
        // republished `collections` every time even when the visible set was
        // identical. Home rebuilds its rows on that publish, so a login turned
        // into a burst of full Home reloads — the collections row blinking in
        // and out until the last one settled.
        guard next != collections else { return }
        NSLog("[OrivioCollections] visible=%d/%d hiddenIDs=%d global=%d hiddenFolders=%d (p%d)",
              next.count, library.count, hiddenIDs.count,
              globalHiddenIDs.count, hiddenFolders.count, profileID)
        collections = next
    }

    // MARK: Persistence

    private func load() {
        // The hidden set is a tiny string array — safe to read inline.
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        hiddenFolderIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenFoldersKey) ?? [])
        globalHiddenFolderIDs = Set(UserDefaults.standard.stringArray(forKey: Self.globalHiddenFoldersKey) ?? [])
        globalHiddenIDs = Set(UserDefaults.standard.stringArray(forKey: Self.globalHiddenCollectionsKey) ?? [])

        // The LIBRARY is not: ~700 KB of nested JSON (493 folders on a real
        // account). Decoding it synchronously here — this runs from the store's
        // init during app startup — is what froze the Apple TV 4K gen 1 before
        // it could draw anything or accept a sign-in. Decode off-thread and
        // publish when it lands; the UI simply has no collections for the first
        // moment, which is how every other store behaves anyway.
        Task.detached(priority: .userInitiated) { [libraryKey = Self.libraryKey] in
            let decoded: [NuvioCollection]
            if let data = UserDefaults.standard.data(forKey: libraryKey),
               let d = try? JSONDecoder().decode([NuvioCollection].self, from: data) {
                decoded = d
            } else {
                decoded = Self.migrateLegacyProfileCollections()
            }
            await MainActor.run { [weak self] in
                guard let self, self.library.isEmpty else { return }
                self.library = decoded
                self.recomputeVisible()
                // Persist only if this came from the legacy migration.
                if UserDefaults.standard.data(forKey: libraryKey) == nil, !decoded.isEmpty {
                    self.saveLibrary()
                }
            }
        }
    }

    /// One-time union of the legacy per-profile collection stores into a single
    /// account-wide library, de-duplicated by TITLE. Where two profiles hold a
    /// same-named collection the RICHER one wins (more folders, then more
    /// artwork: gifs / hero backdrops / hero video / logos) — profile 6's
    /// "Streaming Services" carries GIFs and hero art that profile 1's does not.
    nonisolated private static func migrateLegacyProfileCollections() -> [NuvioCollection] {
        var byTitle: [String: NuvioCollection] = [:]
        var order: [String] = []
        for pid in 1...12 {
            let key = pid == 1 ? baseKey : "\(baseKey).p\(pid)"
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([NuvioCollection].self, from: data)
            else { continue }
            for c in decoded {
                let title = c.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let existing = byTitle[title] {
                    if richness(c) > richness(existing) { byTitle[title] = c }
                } else {
                    byTitle[title] = c
                    order.append(title)
                }
            }
        }
        let merged = order.compactMap { byTitle[$0] }
        if !merged.isEmpty {
            NSLog("[OrivioCollections] migrated %d per-profile collections into a shared library", merged.count)
        }
        return merged
    }

    /// How much presentation data a collection carries — the tie-break when the
    /// same collection exists on two profiles.
    nonisolated private static func richness(_ c: NuvioCollection) -> Int {
        var score = c.folders.count * 10
        if c.backdropImageUrl?.isEmpty == false { score += 5 }
        for f in c.folders {
            if f.focusGifUrl?.isEmpty == false { score += 2 }
            if f.heroBackdropUrl?.isEmpty == false { score += 2 }
            if f.heroVideoUrl?.isEmpty == false { score += 2 }
            if f.titleLogoUrl?.isEmpty == false { score += 1 }
            if f.coverImageUrl?.isEmpty == false { score += 1 }
            if f.coverEmoji?.isEmpty == false { score += 1 }
        }
        return score
    }

    private func saveLibrary() {
        if library.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.libraryKey)
            return
        }
        // Encode + write OFF the main thread. The merged library is ~700 KB of
        // nested JSON (493 folders); encoding it synchronously on the
        // @MainActor store stalled the UI on an A10X every time anything
        // touched collections. Persistence is fire-and-forget — the in-memory
        // `library` is the source of truth for this session.
        let snapshot = library
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.libraryKey)
        }
    }

    private func saveHidden() {
        func write(_ ids: Set<String>, _ key: String) {
            if ids.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(Array(ids), forKey: key) }
        }
        write(hiddenIDs, hiddenKey)
        write(hiddenFolderIDs, hiddenFoldersKey)
        write(globalHiddenFolderIDs, Self.globalHiddenFoldersKey)
        write(globalHiddenIDs, Self.globalHiddenCollectionsKey)
    }

    private func save() {
        saveLibrary()
        saveHidden()
    }
}
