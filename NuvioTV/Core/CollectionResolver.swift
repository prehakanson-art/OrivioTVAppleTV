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

        let isContinuation = tmdbStartPage > 1

        // Every source in the folder is fetched CONCURRENTLY. They used to run
        // one after another — each addon catalog, then each TMDB source, then
        // each Trakt list, every one a full network round-trip — so a folder
        // built from four sources took four round-trips end to end even though
        // none of them depends on the others. Folders were already parallel;
        // the wait was inside each one.
        //
        // Order is preserved by INDEX, not by arrival: the merge below still
        // goes addon → TMDB → Trakt, in each group's own source order, so the
        // de-duplication keeps giving the same winner it always did (first
        // source to claim an id owns it). Concurrency changes when things
        // arrive, never what the folder resolves to.
        func gather(_ count: Int,
                    _ body: @escaping @Sendable (Int) async -> [MetaItem]) async -> [[MetaItem]] {
            guard count > 0 else { return [] }
            var out = [[MetaItem]](repeating: [], count: count)
            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                for i in 0..<count { group.addTask { (i, await body(i)) } }
                for await (i, items) in group { out[i] = items }
            }
            return out
        }

        async let addonResults: [[MetaItem]] = isContinuation ? [] : gather(addonSources.count) { i in
            let source = addonSources[i]
            guard let addonID = source.addonId,
                  let type = source.type,
                  let catalogID = source.catalogId,
                  let addon = addons.first(where: { $0.manifest.id == addonID }),
                  let catalog = (addon.manifest.catalogs ?? [])
                    .first(where: { $0.type == type && $0.id == catalogID })
            else { return [] }
            return (try? await StremioAPI.catalog(addon: addon, catalog: catalog)) ?? []
        }
        async let tmdbResults: [[MetaItem]] = gather(resolvableTmdb.count) { i in
            await TMDBService.resolve(source: resolvableTmdb[i], language: tmdbLanguage,
                                      maxPages: maxTmdbPages, startPage: tmdbStartPage)
        }
        async let traktResults: [[MetaItem]] = isContinuation ? [] : gather(traktSources.count) { i in
            await resolveTrakt(source: traktSources[i], addonManager: addonManager)
        }

        var items: [MetaItem] = []
        var seen = Set<String>()
        for batch in await addonResults + tmdbResults + traktResults {
            for item in batch where seen.insert(item.id).inserted { items.append(item) }
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
        // Flatten first: every entry gets its placeholder, and the first 30 get
        // upgraded in place if their meta lookup lands.
        struct Entry { let id: String; let type: String; let placeholder: MetaItem }
        let entries: [Entry] = raw.compactMap { item in
            let metaType = item.isMovie ? "movie" : "series"
            guard let id = item.imdb ?? item.tmdb.map({ "tmdb:\($0)" }) else { return nil }
            return Entry(id: id, type: metaType, placeholder: MetaItem(
                id: id, type: metaType, name: item.title,
                releaseInfo: item.year.map(String.init)
            ))
        }
        guard !entries.isEmpty else { return [] }

        // Resolve the meta add-on ONCE per type rather than per item. It is a
        // main-actor lookup, so doing it inside the loop cost thirty hops onto
        // the main thread — while the main thread is drawing the grid.
        var addonByType: [String: InstalledAddon] = [:]
        for type in Set(entries.prefix(30).map(\.type)) {
            if let first = entries.first(where: { $0.type == type }),
               let addon = await addonManager.metaAddon(for: type, id: first.id) {
                addonByType[type] = addon
            }
        }

        // The enrichment is what made a Trakt list slow: thirty meta fetches,
        // strictly one after another, before a single poster appeared. They are
        // independent lookups — run them together, bounded so a list doesn't
        // open thirty sockets at once.
        let enrichCount = min(entries.count, 30)
        var upgraded = [MetaItem?](repeating: nil, count: enrichCount)
        await withTaskGroup(of: (Int, MetaItem?).self) { group in
            let window = min(8, enrichCount)
            var next = 0
            func start() {
                guard next < enrichCount else { return }
                let i = next
                next += 1
                let entry = entries[i]
                let addon = addonByType[entry.type]
                group.addTask {
                    guard let addon else { return (i, nil) }
                    return (i, try? await StremioAPI.meta(addon: addon, type: entry.type, id: entry.id))
                }
            }
            for _ in 0..<window { start() }
            for await (i, meta) in group {
                start()
                upgraded[i] = meta
            }
        }

        return entries.enumerated().map { index, entry in
            (index < enrichCount ? upgraded[index] : nil) ?? entry.placeholder
        }
    }
}
