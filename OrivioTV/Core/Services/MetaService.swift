import Foundation

/// Resolves full metadata for a title: add-on meta first (in the user's add-on
/// order), then TMDB when a key is set.
@MainActor
enum MetaService {
    static func fetch(_ meta: MetaItem) async -> MetaItem {
        var target = meta
        target.id = MetaItem.canonicalShowID(meta.id)
        if target.id.hasPrefix("tmdb:") { target = await TMDBService.canonicalize(target) }
        let addons = AppStores.shared.addons.enabled
        let candidates = addons.filter { $0.manifest.handles("meta", type: target.type, id: target.id) }
        var found: MetaItem?
        for addon in candidates {
            if let m = try? await AddonClient.meta(addon, type: target.type, id: target.id), !m.name.isEmpty {
                found = m
                break
            }
        }
        // Some catalogs label shows "movie" or vice versa — try the other type with Cinemeta.
        if found == nil, target.id.hasPrefix("tt") {
            let alt = target.isSeries ? "movie" : "series"
            for addon in addons where addon.manifest.handles("meta", type: alt, id: target.id) {
                if let m = try? await AddonClient.meta(addon, type: alt, id: target.id), !m.name.isEmpty { found = m; break }
            }
        }
        var result = found.map { $0.merged(with: target) } ?? target
        if result.poster == nil { result.poster = meta.poster }
        if result.isSeries, result.videos.isEmpty, AppStores.shared.tmdb.value.isUsable,
           let (tid, isTV) = await TMDBService.resolve(result), isTV {
            let seasons = await TMDBService.seasonCount(tvID: tid)
            result.videos = await TMDBService.episodes(tvID: tid, imdbID: result.imdbID, seasons: seasons)
            result.tmdbID = tid
        }
        return result
    }

    /// Lightweight cached fetch used for Next Up / CW enrichment.
    private static var showCache: [String: (MetaItem, Date)] = [:]

    static func cachedShow(_ id: String, type: String = "series") async -> MetaItem? {
        if let (m, at) = showCache[id], Date().timeIntervalSince(at) < 3600 { return m }
        let m = await fetch(MetaItem(id: id, type: type, name: ""))
        guard !m.name.isEmpty else { return nil }
        showCache[id] = (m, Date())
        if showCache.count > 120 { showCache.removeAll() }
        return m
    }
}

// MARK: - Continue Watching / Next Up

struct ContinueWatchingItem: Identifiable, Hashable {
    var id: String
    var meta: MetaItem
    var video: MetaVideo?
    var progress: WatchProgress?
    var isNextUp: Bool
    /// Episodes aired since the viewer started the show that they haven't watched (derived, never synced).
    var newEpisodes: Int
    var upcoming: String?

    var fraction: Double { progress?.fraction ?? 0 }

    var caption: String {
        if let v = video { return v.episodeLine }
        if let p = progress, let code = p.episodeCode { return "\(code) · \(p.episodeTitle ?? "")" }
        return meta.typeLabel
    }

    var image: String? { meta.background ?? meta.poster }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.fraction == b.fraction && a.newEpisodes == b.newEpisodes && a.video?.id == b.video?.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
enum ContinueWatchingBuilder {
    static func build(progress: ProgressStore, watched: WatchedStore, home: HomeSettings) async -> [ContinueWatchingItem] {
        var items: [ContinueWatchingItem] = []
        var seenShows = Set<String>()
        // 1. In-progress rows.
        for p in progress.inProgress {
            seenShows.insert(p.metaID)
            var meta = p.meta
            var video: MetaVideo?
            if let s = p.season, let e = p.episode {
                video = MetaVideo(id: p.videoID ?? p.id, title: p.episodeTitle ?? "", season: s, episode: e,
                                  thumbnail: p.episodeThumbnail)
            }
            if home.episodeThumbnails, let thumb = p.episodeThumbnail { meta.background = thumb }
            items.append(ContinueWatchingItem(id: "cw:\(p.metaID)", meta: meta, video: video, progress: p,
                                              isNextUp: false, newEpisodes: 0, upcoming: nil))
        }
        // 2. Next Up for shows whose last episode was finished.
        var candidates: [(String, Date, String)] = []
        var byShow: [String: Date] = [:]
        for w in watched.items.values where w.season != nil {
            if let cur = byShow[w.metaID], cur >= w.watchedAt { continue }
            byShow[w.metaID] = w.watchedAt
        }
        for p in progress.entries.values where p.isFinished && p.isEpisode {
            if let cur = byShow[p.metaID], cur >= p.updatedAt { continue }
            byShow[p.metaID] = p.updatedAt
        }
        for (show, date) in byShow where !seenShows.contains(show) && !watched.droppedShows.contains(show) {
            if let dismissed = progress.dismissedNextUp[show], dismissed >= date { continue }
            if let at = progress.removed.ids[show], at >= date { continue }
            candidates.append((show, date, "series"))
        }
        candidates.sort { $0.1 > $1.1 }
        let limited = Array(candidates.prefix(32))
        let metas = await withTaskGroup(of: (String, MetaItem?).self) { group -> [String: MetaItem] in
            for (show, _, type) in limited { group.addTask { (show, await MetaService.cachedShow(show, type: type)) } }
            var out: [String: MetaItem] = [:]
            for await (id, m) in group { if let m { out[id] = m } }
            return out
        }
        for (show, date, _) in limited {
            guard let meta = metas[show], let next = nextEpisode(meta: meta, watched: watched, progress: progress, home: home) else { continue }
            if !next.hasAired && !home.showUnairedNextUp { continue }
            var m = meta.preview
            if home.episodeThumbnails, let t = next.thumbnail { m.background = t }
            let newCount = newEpisodeCount(meta: meta, watched: watched)
            items.append(ContinueWatchingItem(id: "nu:\(show)", meta: m, video: next, progress: nil, isNextUp: true,
                                              newEpisodes: newCount, upcoming: next.hasAired ? nil : next.countdownPill))
            _ = date
        }
        // 3. Fill "+N" on in-progress shows we already have metas for.
        for i in items.indices where !items[i].isNextUp && items[i].meta.isSeries {
            if let m = metas[items[i].meta.id] { items[i].newEpisodes = newEpisodeCount(meta: m, watched: watched) }
        }
        // Sort.
        let dateOf: (ContinueWatchingItem) -> Date = { item in
            item.progress?.updatedAt ?? byShow[item.meta.id] ?? .distantPast
        }
        switch home.cwSort {
        case .recent:
            items.sort { dateOf($0) > dateOf($1) }
        case .streaming:
            items.sort { a, b in
                let am = a.progress != nil, bm = b.progress != nil
                if am != bm { return am }
                return dateOf(a) > dateOf(b)
            }
        }
        return items
    }

    /// The next episode after the last finished one (or after the furthest, when enabled).
    static func nextEpisode(meta: MetaItem, watched: WatchedStore, progress: ProgressStore, home: HomeSettings) -> MetaVideo? {
        let eps = meta.orderedEpisodes
        guard !eps.isEmpty else { return nil }
        var anchor: (Int, Int)?
        if home.nextUpFromFurthest {
            anchor = watched.furthestEpisode(of: meta.id)
        } else if let recent = watched.mostRecentEpisode(of: meta.id), let s = recent.season, let e = recent.episode {
            anchor = (s, e)
        }
        let finished = progress.showEntries(meta.id).filter(\.isFinished).max { $0.updatedAt < $1.updatedAt }
        if let f = finished, let s = f.season, let e = f.episode {
            if anchor == nil || (!home.nextUpFromFurthest && (watched.mostRecentEpisode(of: meta.id)?.watchedAt ?? .distantPast) < f.updatedAt) {
                anchor = (s, e)
            }
        }
        guard let (s, e) = anchor, let idx = eps.firstIndex(where: { $0.season == s && $0.episode == e }) else { return nil }
        for v in eps[(idx + 1)...] where !watched.isWatched(v.id) { return v }
        return nil
    }

    /// Count of episodes aired since the viewer started the show that they haven't watched.
    static func newEpisodeCount(meta: MetaItem, watched: WatchedStore) -> Int {
        let marks = watched.watchedEpisodes(of: meta.id)
        guard let started = marks.map(\.watchedAt).min() else { return 0 }
        return meta.orderedEpisodes.filter { v in
            guard let r = v.released else { return false }
            return r > started && r <= Date() && !watched.isWatched(v.id)
        }.count
    }

    /// Detail's series Play target: the most recently updated in-progress
    /// episode (unless a later one was since marked watched) → next after
    /// furthest watched (if enabled) → first unwatched aired → first episode.
    static func playTarget(meta: MetaItem, watched: WatchedStore, progress: ProgressStore, home: HomeSettings) -> (MetaVideo, WatchProgress?)? {
        let eps = meta.orderedEpisodes
        guard !eps.isEmpty else { return nil }
        if let p = progress.showEntries(meta.id).first(where: { $0.isResumable }),
           let v = eps.first(where: { $0.id == p.id || ($0.season == p.season && $0.episode == p.episode) }) {
            let laterWatched = watched.watchedEpisodes(of: meta.id).contains { w in
                guard let s = w.season, let e = w.episode, let ps = p.season, let pe = p.episode else { return false }
                return (s, e) > (ps, pe) && w.watchedAt > p.updatedAt
            }
            if !laterWatched { return (v, p) }
        }
        if let next = nextEpisode(meta: meta, watched: watched, progress: progress, home: home), next.hasAired {
            return (next, progress.progress(for: next.id))
        }
        if let first = eps.first(where: { $0.hasAired && !watched.isWatched($0.id) }) {
            return (first, progress.progress(for: first.id))
        }
        return (eps[0], progress.progress(for: eps[0].id))
    }
}
