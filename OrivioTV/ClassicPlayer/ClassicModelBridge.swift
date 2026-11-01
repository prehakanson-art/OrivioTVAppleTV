import Foundation

// The old app's model API, on the new app's models: the Classic player was
// written against the old Stream/StreamEntry/… types, which the new ones
// replaced with the same names but a different shape.

// MARK: - Stream

extension Stream {
    private var classicTraits: StreamTraits { StreamTraits(self) }

    var displayName: String { (name ?? "Stream").replacingOccurrences(of: "\n", with: " · ") }
    var displayDetail: String { (title ?? description ?? "").replacingOccurrences(of: "\n", with: " · ") }
    var resolutionLabel: String? { classicTraits.resolution }
    var sizeBytes: Int64? { classicTraits.sizeBytes }
    var fileSizeLabel: String? { sizeBytes.map(StreamEntry.formatBytes) }
    var isInstant: Bool { classicTraits.isCached }
    var isCached: Bool { classicTraits.isCached }
    var isMarkedUncached: Bool { classicTraits.isMarkedUncached }
    var isAV1: Bool { classicTraits.isAV1 }
    var isDolbyVision: Bool { classicTraits.isDolbyVision }
    var isHDR: Bool { classicTraits.isHDR }
    var hasAtmos: Bool { classicTraits.hasAtmos }

    func signature(addonName: String?) -> StreamSignature {
        let t = classicTraits
        return StreamSignature(resolution: t.resolution, dolbyVision: t.isDolbyVision, hdr: t.isHDR,
                               atmos: t.hasAtmos, addonName: addonName.map(StreamEntry.stripResolverPrefix) ?? "")
    }

    /// The old ranking score; the new app's scoring is the same ladder.
    func qualityScore(isInstant: Bool, sizeBytes: Int64?, resolutionLabel: String?) -> Int {
        StreamScoring.score(classicTraits)
    }
}

// MARK: - StreamEntry

extension StreamEntry {
    /// The old app's constructor (no add-on id or list position).
    init(addonName: String, stream: Stream) {
        self.init(stream: stream, addonName: addonName, addonID: addonName, index: 0)
    }
}

// MARK: - Profiles

/// The old Auto Link Selector settings, as far as the player reads them.
struct AutoLinkPreferences {
    var enabled = false
    var preferredAddon = ""
    var secondaryAddon = ""
}

extension ProfileStore {
    var activeAutoLink: AutoLinkPreferences {
        let a = active.autoLink
        return AutoLinkPreferences(enabled: a.enabled, preferredAddon: a.preferredAddon ?? "", secondaryAddon: a.secondaryAddon ?? "")
    }
}

// MARK: - TMDB

extension TMDBService {
    typealias CastMember = TMDBPerson

    struct ClassicDetail {
        let cast: [TMDBPerson]
        let certification: String?
    }

    /// The old `detail(imdbID:type:)`: the new enrichment carries the same data.
    static func detail(imdbID: String, type: String) async -> ClassicDetail? {
        guard let e = await enrichment(for: MetaItem(id: imdbID, type: type, name: "")) else { return nil }
        return ClassicDetail(cast: e.cast, certification: e.certification)
    }

    static func contentRating(imdbID: String, type: String) async -> String? {
        await detail(imdbID: imdbID, type: type)?.certification
    }

    static func imdbID(tmdbID: Int, isMovie: Bool) async -> String? {
        await imdbID(tmdbID: tmdbID, isTV: !isMovie)
    }
}

// MARK: - Progress & watched

extension ProgressStore {
    /// The old title key: the episode id, or the title id for a movie.
    static func key(metaID: String, video: MetaVideo?) -> String { video?.id ?? metaID }

    func update(meta: MetaItem, video: MetaVideo?, streamURL: String?, position: Double, duration: Double,
                signature: StreamSignature) {
        classicRecord(meta: meta, video: video, position: position, duration: duration, signature: signature, transient: false)
    }

    func updateTransient(meta: MetaItem, video: MetaVideo?, streamURL: String?, position: Double, duration: Double,
                         signature: StreamSignature) {
        classicRecord(meta: meta, video: video, position: position, duration: duration, signature: signature, transient: true)
    }

    /// Sync is scheduled by `record` itself in the new store.
    func requestSyncPush() {}

    /// The episode was watched to its end: record it finished and mark it watched.
    func markFinished(meta: MetaItem, video: MetaVideo?) {
        // Dev test streams (Settings → Playback → Test streams) are never watch history.
        guard !TestStreamCatalog.isTestMeta(meta.id) else { return }
        let key = Self.key(metaID: meta.id, video: video)
        let duration = max(progress(for: key)?.duration ?? 0, 1)
        classicRecord(meta: meta, video: video, position: duration, duration: duration, signature: nil, transient: false)
        AppStores.shared.watched.markWatched(meta: meta, video: video)
    }

    /// Same record the new player writes (see PlayerViewModel.saveProgress).
    private func classicRecord(meta: MetaItem, video: MetaVideo?, position: Double, duration: Double,
                               signature: StreamSignature?, transient: Bool) {
        guard duration > 0, position > 5, !TestStreamCatalog.isTestMeta(meta.id) else { return }
        let key = Self.key(metaID: meta.id, video: video)
        var p = WatchProgress(id: key, metaID: meta.id, type: meta.type, videoID: video?.id, season: video?.season,
                              episode: video?.episode, position: position, duration: duration, updatedAt: Date(),
                              name: meta.name, poster: meta.poster, background: meta.background, logo: meta.logo,
                              episodeTitle: video?.title, episodeThumbnail: video?.thumbnail)
        if let (link, sig) = takePendingLink(for: key) { p.lastLink = link; p.signature = sig }
        p.signature = p.signature ?? signature ?? progress(for: key)?.signature
        if p.lastLink == nil { p.lastLink = progress(for: key)?.lastLink }
        record(p, transient: transient)
        if p.isFinished, !AppStores.shared.watched.isWatched(key) {
            AppStores.shared.watched.markWatched(meta: meta, video: video)
        }
    }
}

extension WatchedStore {
    func mark(meta: MetaItem, video: MetaVideo?) { markWatched(meta: meta, video: video) }
}

// MARK: - Stream headers

extension StreamProxyHeaders {
    var requestHeaders: [String: String]? {
        guard let request, !request.isEmpty else { return nil }
        return request
    }
}

// MARK: - Add-ons

/// The old add-on client, on the new `AddonClient`.
enum StremioAPI {
    typealias AddonSubtitle = OrivioTV.AddonSubtitle

    static func streams(addon: InstalledAddon, type: String, id: String) async throws -> [Stream] {
        let patience = await TimeInterval(AppStores.shared.player.value.sourceSearchPatience)
        return try await AddonClient.streams(addon, type: type, id: id, timeout: patience)
    }

    static func subtitles(addon: InstalledAddon, type: String, id: String) async throws -> [AddonSubtitle] {
        try await AddonClient.subtitles(addon, type: type, id: id)
    }

    static func meta(addon: InstalledAddon, type: String, id: String) async throws -> MetaItem {
        guard let m = try await AddonClient.meta(addon, type: type, id: id) else { throw URLError(.zeroByteResource) }
        return m
    }
}

extension InstalledAddon {
    /// The old id-prefix check: does this add-on claim the id at all (any type)?
    func handles(id: String) -> Bool {
        let m = manifest
        let prefixes = m.idPrefixes + m.resources.flatMap { $0.idPrefixes ?? [] }
        return prefixes.isEmpty || prefixes.contains { id.hasPrefix($0) }
    }
}

extension AddonManager {
    /// The best meta add-on for a title: one that claims the id, else any.
    func metaAddon(for type: String, id: String) -> InstalledAddon? {
        let all = metaAddons
        return all.first { $0.manifest.handles("meta", type: type, id: id) } ?? all.first { $0.handles(id: id) } ?? all.first
    }
}

/// Requests in flight at once when the player sweeps every stream add-on.
enum AddonSweepLimits {
    static let streams = 6
}

/// The old Sources page's per-title link cache, kept for in-player reopens.
struct CachedStreamSource {
    let addonName: String
    let stream: Stream
}

actor ClassicSourceCache {
    private var store: [String: (at: Date, sources: [CachedStreamSource])] = [:]

    func value(for id: String, ttl: TimeInterval) -> [CachedStreamSource]? {
        guard let hit = store[id], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.sources
    }

    func store(_ sources: [CachedStreamSource], for id: String) {
        store[id] = (Date(), sources)
    }
}

enum StreamsViewModel {
    static let sourceCache = ClassicSourceCache()
    static let sourceCacheTTL: TimeInterval = 15 * 60
}

// MARK: - Meta

extension MetaItem {
    /// The catalogue runtime ("142 min", "2h 22m") in seconds.
    var runtimeSeconds: Double? {
        guard let r = runtime?.lowercased() else { return nil }
        var minutes = 0.0
        if let h = r.range(of: #"(\d+)\s*h"#, options: .regularExpression) {
            minutes += (Double(r[h].filter(\.isNumber)) ?? 0) * 60
        }
        if let m = r.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            minutes += Double(r[m].filter(\.isNumber)) ?? 0
        }
        if minutes == 0, let n = Double(r.filter(\.isNumber)) { minutes = n }
        return minutes > 0 ? minutes * 60 : nil
    }
}
