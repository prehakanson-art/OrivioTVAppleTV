import Foundation

/// Resolves a collection folder's catalog sources (addon / TMDB / Trakt) into
/// `MetaItem`s. Shared by the collection BROWSE page (full depth) and HOME
/// rows (first TMDB page only, via `maxTmdbPages`, so rendering a Rows/Combined
/// collection doesn't fire hundreds of TMDB requests per folder on every load).
enum CollectionResolver {

    /// True when a folder carries sources tvOS can't resolve here — a non-addon,
    /// non-TMDB, non-Trakt source, or a TMDB source while TMDB is disabled.
    static func hasUnsupportedSources(_ folder: NuvioCollectionFolder, tmdbEnabled: Bool) -> Bool {
        let tmdbSources = folder.effectiveSources.filter { $0.provider.lowercased() == "tmdb" }
        let other = folder.effectiveSources.filter {
            !$0.isAddonSource && $0.provider.lowercased() != "tmdb" && !$0.isTraktSource
        }
        return !other.isEmpty || (!tmdbSources.isEmpty && !tmdbEnabled)
    }

    /// Resolve ONE folder's items, de-duplicated by id (addon order, then TMDB,
    /// then Trakt). Returns empty when the folder has nothing resolvable.
    static func resolveFolder(
        _ folder: NuvioCollectionFolder,
        addons: [InstalledAddon],
        addonManager: AddonManager,
        tmdbEnabled: Bool,
        tmdbLanguage: String,
        maxTmdbPages: Int = Int.max,
        /// First TMDB page of this window (see TMDBService.resolve). >1 means
        /// "continue a streaming load", so addon/Trakt sources — which aren't
        /// paged — are skipped to avoid re-returning what earlier windows
        /// already delivered.
        tmdbStartPage: Int = 1,
        hideUnreleased: Bool = false
    ) async -> [MetaItem] {
        let tmdbSources = folder.effectiveSources.filter { $0.provider.lowercased() == "tmdb" }
        let traktSources = folder.effectiveSources.filter { $0.isTraktSource }
        let addonSources = folder.addonSources
        let resolvableTmdb = tmdbEnabled ? tmdbSources : []
        guard !addonSources.isEmpty || !resolvableTmdb.isEmpty || !traktSources.isEmpty else { return [] }

        var items: [MetaItem] = []
        var seen = Set<String>()
        let isContinuation = tmdbStartPage > 1
        for source in addonSources where !isContinuation {
            guard let addonID = source.addonId,
                  let type = source.type,
                  let catalogID = source.catalogId,
                  let addon = addons.first(where: { $0.manifest.id == addonID }),
                  let catalog = (addon.manifest.catalogs ?? [])
                    .first(where: { $0.type == type && $0.id == catalogID })
            else { continue }
            let fetched = (try? await StremioAPI.catalog(addon: addon, catalog: catalog)) ?? []
            for item in fetched where seen.insert(item.id).inserted { items.append(item) }
        }
        for source in resolvableTmdb {
            let fetched = await TMDBService.resolve(source: source, language: tmdbLanguage,
                                                    maxPages: maxTmdbPages, startPage: tmdbStartPage)
            for item in fetched where seen.insert(item.id).inserted { items.append(item) }
        }
        for source in traktSources where !isContinuation {
            let fetched = await resolveTrakt(source: source, addonManager: addonManager)
            for item in fetched where seen.insert(item.id).inserted { items.append(item) }
        }
        return hideUnreleased ? items.filter { !$0.isUnreleased } : items
    }

    /// Trakt list items arrive with no artwork — enrich the first N via the
    /// installed meta add-on (Cinemeta) so the grid still has posters; the rest
    /// still display (title only) rather than being dropped.
    static func resolveTrakt(source: CollectionSourceDTO, addonManager: AddonManager) async -> [MetaItem] {
        guard let traktListId = source.traktListId else { return [] }
        let type = (source.mediaType ?? "movie").lowercased() == "tv" ? "show" : "movie"
        let sortBy = source.sortBy ?? "rank"
        let sortHow = source.sortHow ?? "asc"
        let raw = await TraktService.publicListItems(
            traktListId: traktListId, type: type, sortBy: sortBy, sortHow: sortHow
        )
        var enriched = 0
        var out: [MetaItem] = []
        for item in raw {
            let metaType = item.isMovie ? "movie" : "series"
            let id = item.imdb ?? item.tmdb.map { "tmdb:\($0)" }
            guard let id else { continue }
            if enriched < 30, let addon = await addonManager.metaAddon(for: metaType, id: id),
               let meta = try? await StremioAPI.meta(addon: addon, type: metaType, id: id) {
                enriched += 1
                out.append(meta)
            } else {
                out.append(MetaItem(
                    id: id, type: metaType, name: item.title,
                    releaseInfo: item.year.map(String.init)
                ))
            }
        }
        return out
    }
}
