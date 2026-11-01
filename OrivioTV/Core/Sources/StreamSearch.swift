import Foundation

/// Fans out to every enabled stream-capable add-on and plugin concurrently,
/// each bounded by **Source search patience**. Results stream in as add-ons answer.
@MainActor
final class StreamSearch: ObservableObject {
    enum Status: Equatable {
        case searching
        case done(Int)
        case failed(String)
    }

    struct AddonState: Identifiable, Equatable {
        let id: String
        let name: String
        var status: Status
    }

    @Published private(set) var entries: [StreamEntry] = []
    @Published private(set) var states: [AddonState] = []
    /// Add-ons skipped for structural reasons (don't serve this type / id).
    @Published private(set) var skipped: [String] = []
    @Published private(set) var isComplete = false

    let meta: MetaItem
    let video: MetaVideo?
    var onEntries: (([StreamEntry]) -> Void)?
    private var task: Task<Void, Never>?
    private var counter = 0

    init(meta: MetaItem, video: MetaVideo?) {
        self.meta = meta
        self.video = video
    }

    var pendingCount: Int { states.filter { $0.status == .searching }.count }
    var answeredCount: Int { states.count - pendingCount }

    func start() {
        task?.cancel()
        entries = []
        states = []
        skipped = []
        isComplete = false
        counter = 0
        let stores = AppStores.shared
        let patience = TimeInterval(stores.player.value.sourceSearchPatience)
        task = Task { [weak self] in
            guard let self else { return }
            var meta = self.meta
            if meta.id.hasPrefix("tmdb:") { meta = await TMDBService.canonicalize(meta) }
            let type = meta.isSeries ? "series" : (meta.type == "tv" || meta.type == "channel" ? meta.type : "movie")
            let id: String
            if let v = self.video {
                id = v.id.hasPrefix("tmdb:") && meta.imdbID != nil && v.season != nil
                    ? "\(meta.imdbID!):\(v.season!):\(v.episode ?? 1)" : v.id
            } else {
                id = meta.id
            }
            var targets: [InstalledAddon] = []
            for addon in stores.addons.streamAddons {
                if addon.manifest.handles("stream", type: type, id: id) { targets.append(addon) } else { self.skipped.append(addon.displayName) }
            }
            self.states = targets.map { AddonState(id: $0.manifestURL, name: $0.displayName, status: .searching) }
            let plugins = PluginHost.shared.enabledScrapers
            for p in plugins { self.states.append(AddonState(id: "plugin:\(p.id)", name: p.name, status: .searching)) }

            // Entries are built in the child tasks, off the main thread: parsing and
            // scoring thousands of links (a big torrent add-on) on main stalled
            // the Detail page on A8/A10X boxes.
            await withTaskGroup(of: (String, String, String, Result<[StreamEntry], Error>).self) { group in
                for addon in targets {
                    group.addTask {
                        do {
                            let streams = try await withTimeout(patience) {
                                try await AddonClient.streams(addon, type: type, id: id, timeout: patience)
                            }
                            return (addon.manifestURL, addon.displayName, addon.manifest.id,
                                    .success(Self.entries(streams, name: addon.displayName, addonID: addon.manifest.id)))
                        } catch {
                            return (addon.manifestURL, addon.displayName, addon.manifest.id, .failure(error))
                        }
                    }
                }
                let video = self.video
                for p in plugins {
                    group.addTask {
                        do {
                            let streams = try await withTimeout(patience) {
                                try await PluginHost.shared.streams(scraperID: p.id, meta: meta, video: video)
                            }
                            return ("plugin:\(p.id)", p.name, "plugin:\(p.id)",
                                    .success(Self.entries(streams, name: p.name, addonID: "plugin:\(p.id)")))
                        } catch {
                            return ("plugin:\(p.id)", p.name, "plugin:\(p.id)", .failure(error))
                        }
                    }
                }
                for await (key, name, addonID, result) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    self.apply(key: key, name: name, addonID: addonID, result: result)
                }
            }
            guard !Task.isCancelled else { return }
            self.isComplete = true
        }
    }

    /// Playable links → entries (runs in the fetching task, not on main).
    /// The index only has to be unique within one add-on's list (ids carry the add-on id).
    nonisolated static func entries(_ streams: [Stream], name: String, addonID: String) -> [StreamEntry] {
        streams.filter { $0.isPlayable || $0.externalUrl != nil }.enumerated().map { i, s in
            StreamEntry(stream: s, addonName: name, addonID: addonID, index: i + 1)
        }
    }

    private func apply(key: String, name: String, addonID: String, result: Result<[StreamEntry], Error>) {
        guard let i = states.firstIndex(where: { $0.id == key }) else { return }
        switch result {
        case .success(let new):
            states[i].status = .done(new.count)
            if !new.isEmpty {
                entries.append(contentsOf: new)
                onEntries?(new)
            }
        case .failure(let e):
            states[i].status = .failed(Self.reason(e))
        }
    }

    static func reason(_ e: Error) -> String {
        if let h = e as? HTTPError {
            switch h {
            case .status(let c): return "HTTP \(c)"
            case .timeout: return "timed out"
            case .badURL: return "bad URL"
            case .notJSON: return "unreadable response"
            default: return h.localizedDescription
            }
        }
        return e.localizedDescription
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

// MARK: - Rejected links

/// A link watched < 5 min is rejected for 8 h for that title, so auto-select skips it.
@MainActor
enum RejectedLinks {
    private static let key = Persistence.key("player.rejectedLinks.v1")
    private static var store: [String: [String: Date]] = Persistence.load([String: [String: Date]].self, key: key) ?? [:]

    static func reject(_ rejectionKey: String, title: String) {
        store[title, default: [:]][rejectionKey] = Date().addingTimeInterval(8 * 3600)
        prune()
        Persistence.save(store, key: key)
    }

    static func clear(_ rejectionKey: String, title: String) {
        store[title]?[rejectionKey] = nil
        Persistence.save(store, key: key)
    }

    static func isRejected(_ rejectionKey: String, title: String) -> Bool {
        guard let until = store[title]?[rejectionKey] else { return false }
        return until > Date()
    }

    private static func prune() {
        let now = Date()
        for (t, links) in store {
            let alive = links.filter { $0.value > now }
            store[t] = alive.isEmpty ? nil : alive
        }
    }
}

// MARK: - Grouping and filters

struct SourceTier: Identifiable {
    var id: String { label }
    let label: String
    let entries: [StreamEntry]
}

struct SourceGroup: Identifiable {
    var id: String { addonName }
    let addonName: String
    let tiers: [SourceTier]
    var count: Int { tiers.reduce(0) { $0 + $1.entries.count } }
}

enum SourceFilters {
    /// Applies the Settings filters. Untagged resolutions are kept by the minimum-resolution filter.
    static func apply(_ entries: [StreamEntry], settings s: PlayerSettings) -> [StreamEntry] {
        entries.filter { e in
            // Junk under 250 MB (samples, notice clips).
            if let size = e.sizeBytes, size > 0, size < 250 * 1_048_576 { return false }
            if let min = s.minimumResolution, let r = e.resolutionLabel,
               StreamScoring.resolutionValue(r) < StreamScoring.resolutionValue(min) { return false }
            if s.hideAV1 && e.traits.isAV1 { return false }
            if s.hdrOnly && !e.traits.isHDR { return false }
            if s.dolbyVisionOnly && !e.traits.isDolbyVision { return false }
            if s.cachedOnly && e.stream.isTorrent && !e.isInstant { return false }
            return true
        }
    }

    static func group(_ entries: [StreamEntry], settings s: PlayerSettings, addonOrder: [String]) -> [SourceGroup] {
        let filtered = s.linkFilters ? apply(entries, settings: s) : entries
        var byAddon: [String: [StreamEntry]] = [:]
        var order: [String] = []
        for e in filtered {
            if byAddon[e.addonName] == nil { order.append(e.addonName) }
            byAddon[e.addonName, default: []].append(e)
        }
        order.sort { a, b in
            let ia = addonOrder.firstIndex(of: a) ?? Int.max, ib = addonOrder.firstIndex(of: b) ?? Int.max
            return ia < ib
        }
        return order.map { name in
            let list = byAddon[name] ?? []
            if !s.linkFilters {
                let sorted = list.sorted { ($0.isInstant ? 0 : 1) < ($1.isInstant ? 0 : 1) }
                return SourceGroup(addonName: name, tiers: [SourceTier(label: "", entries: Array(sorted.prefix(40)))])
            }
            var tierOrder = StreamScoring.resolutionOrder + ["Other"]
            if PerformanceProfile.isLowPower { tierOrder = ["1080p", "720p", "2160p", "480p", "Other"] }
            let tiers = tierOrder.compactMap { label -> SourceTier? in
                let inTier = list.filter { ($0.resolutionLabel ?? "Other") == label }.sorted { $0.sourceScore > $1.sourceScore }
                guard !inTier.isEmpty else { return nil }
                return SourceTier(label: label == "2160p" ? "4K" : label, entries: Array(inTier.prefix(s.linksPerResolution)))
            }
            return SourceGroup(addonName: name, tiers: tiers)
        }
    }
}

// MARK: - Auto-selection (§8.2)

@MainActor
enum AutoSelect {
    struct Context {
        var titleKey: String
        var autoLink: AutoLinkPrefs
        var settings: PlayerSettings
        var resumeSignature: StreamSignature?
        var lastLink: LastLink?
    }

    static func eligible(_ e: StreamEntry, ctx: Context) -> Bool {
        !e.stream.isExternal && !RejectedLinks.isRejected(e.rejectionKey, title: ctx.titleKey)
            && !(e.stream.isTorrent && !AppStores.shared.debrid.value.hasAny && !AppStores.shared.torrent.value.enabled)
    }

    /// 1. Auto Link Selector early pick — as soon as a qualifying link arrives.
    static func autoLinkPick(_ entries: [StreamEntry], ctx: Context, final: Bool) -> StreamEntry? {
        let p = ctx.autoLink
        guard p.enabled else { return nil }
        let qualifying = entries.filter { e in
            guard eligible(e, ctx: ctx) else { return false }
            if let min = p.minimumQuality, StreamScoring.resolutionValue(e.resolutionLabel) < StreamScoring.resolutionValue(min) { return false }
            if let max = p.maximumSizeGB, let size = e.sizeBytes, Double(size) / 1_073_741_824 > max { return false }
            if p.cachedOnly && e.stream.isTorrent && !e.isInstant { return false }
            if p.avoidDolbyVision && e.traits.isDolbyVision { return false }
            return true
        }
        if let pref = p.preferredAddon {
            let fromPref = qualifying.filter { $0.sourceAddonName == pref || $0.addonID == pref }
            if let best = fromPref.max(by: { $0.sourceScore < $1.sourceScore }) { return best }
            // The secondary is used only when the preferred add-on has no match (wait until complete).
            guard final else { return nil }
            if let sec = p.secondaryAddon {
                let fromSec = qualifying.filter { $0.sourceAddonName == sec || $0.addonID == sec }
                if let best = fromSec.max(by: { $0.sourceScore < $1.sourceScore }) { return best }
            }
            return nil
        }
        guard final else { return nil }
        return qualifying.max { $0.sourceScore < $1.sourceScore }
    }

    /// 2. Reuse last link — the stored stream itself, if inside the window.
    static func reuseLastLink(ctx: Context) -> LastLink? {
        guard ctx.settings.reuseLastLink, let last = ctx.lastLink else { return nil }
        guard Date().timeIntervalSince(last.savedAt) < TimeInterval(ctx.settings.reuseWindowHours * 3600) else { return nil }
        guard !RejectedLinks.isRejected(last.rejectionKey, title: ctx.titleKey) else { return nil }
        return last
    }

    /// 3. Resume format match, then 4. Auto-play best source.
    static func finalPick(_ entries: [StreamEntry], ctx: Context) -> [StreamEntry] {
        let pool = entries.filter { eligible($0, ctx: ctx) }
        if let sig = ctx.resumeSignature {
            let matches = pool.filter { sig.matches($0) }.sorted { $0.sourceScore > $1.sourceScore }
            if !matches.isEmpty { return matches + ranked(pool.filter { !matches.contains($0) }, ctx: ctx) }
        }
        guard ctx.settings.autoPlayBestSource else { return [] }
        return ranked(pool, ctx: ctx)
    }

    static func ranked(_ pool: [StreamEntry], ctx: Context) -> [StreamEntry] {
        var list = pool
        if ctx.settings.autoPlayCachedOnly { list = list.filter { !$0.stream.isTorrent || $0.isInstant } }
        if !ctx.settings.autoPlayRegex.isEmpty, let re = try? NSRegularExpression(pattern: ctx.settings.autoPlayRegex, options: [.caseInsensitive]) {
            list = list.filter { e in
                let text = e.stream.allText
                return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
        if ctx.settings.linkFilters { list = SourceFilters.apply(list, settings: ctx.settings) }
        return list.sorted { $0.sourceScore > $1.sourceScore }
    }

    /// In-player failover: same link → same add-on → same resolution any add-on; uncached last; rejected skipped.
    static func rankedCandidates(after current: StreamEntry, in all: [StreamEntry], titleKey: String) -> [StreamEntry] {
        let pool = all.filter { $0.id != current.id && !$0.stream.isExternal && !RejectedLinks.isRejected($0.rejectionKey, title: titleKey) }
        let sameAddon = pool.filter { $0.sourceAddonName == current.sourceAddonName }.sorted { $0.sourceScore > $1.sourceScore }
        let sameRes = pool.filter { $0.sourceAddonName != current.sourceAddonName && $0.resolutionLabel == current.resolutionLabel }
            .sorted { $0.sourceScore > $1.sourceScore }
        let rest = pool.filter { !sameAddon.contains($0) && !sameRes.contains($0) }.sorted { $0.sourceScore > $1.sourceScore }
        let ordered = sameAddon + sameRes + rest
        return ordered.filter { !$0.stream.isTorrent || $0.isInstant } + ordered.filter { $0.stream.isTorrent && !$0.isInstant }
    }
}
