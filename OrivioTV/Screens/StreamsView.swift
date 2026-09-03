import SwiftUI
import UIKit

@MainActor
final class StreamsViewModel: ObservableObject {
    /// Addon → resolution section → size subsection → rows (see SourceSelection).
    @Published var groups: [AddonSourceGroup] = []
    @Published var isLoading = true
    @Published var finishedAddons = 0
    @Published var totalAddons = 0
    /// Addons that returned at least one usable link, in the order they arrived
    /// — drives the filter chips. nil `selectedAddon` = show all (merged).
    @Published var addonNames: [String] = []
    @Published var selectedAddon: String? = nil

    let meta: MetaItem
    let video: MetaVideo?

    /// Every usable link across all addons, kept raw so the addon filter can
    /// re-curate a SINGLE addon's full set (not just what survived the
    /// cross-addon per-tier cap).
    private var pool: [StreamEntry] = []
    /// Every stream addon queried for this title (installed order), whether or
    /// not it returned links — so an addon that came back empty (or with only a
    /// cast action) is still shown, as the user asked ("addon name … None").
    private var queriedAddonNames: [String] = []
    /// Installed addons that were NOT queried, with the reason — a broken
    /// manifest or an id-prefix mismatch used to be completely invisible,
    /// which made "why isn't my addon showing?" undiagnosable from the UI.
    /// `id` is the add-on's manifest URL, not its name: two installed
    /// configurations of the same add-on (two Torrentio/Comet setups) produce
    /// two rows with the SAME name, and a duplicated ForEach id makes SwiftUI
    /// drop or mis-render them.
    @Published var skippedAddons: [(id: String, name: String, reason: String)] = []
    /// Addons whose stream request errored this load, with a short reason
    /// (HTTP code / timeout / …) — rendered as "Not working — <reason>" under
    /// the addon name, distinct from a healthy addon that returned no links.
    @Published var failedAddons: [String: String] = [:]

    /// Compact human reason for a failed addon request.
    nonisolated static func shortReason(for error: Error) -> String {
        switch error {
        case StremioAPIError.badResponse(let code):
            return code == 403 ? "the add-on refused the request (HTTP 403)" : "the add-on returned HTTP \(code)"
        case StremioAPIError.emptyBody:
            return "the add-on sent an empty response"
        case StremioAPIError.badURL:
            return "the add-on's URL is invalid"
        case let urlError as URLError where urlError.code == .timedOut:
            return "the add-on timed out"
        case let urlError as URLError:
            return urlError.localizedDescription
        case is DecodingError:
            return "the add-on sent an unreadable response"
        default:
            return "the add-on didn't respond"
        }
    }
    /// Links kept per resolution×size cell (2160p·10–20 GB …) when filters on.
    private var perTier = 6
    /// Curated filters on (resolution → size tiers, cached first) vs raw
    /// capped-per-addon.
    private var filtersEnabled = true

    init(meta: MetaItem, video: MetaVideo?) {
        self.meta = meta
        self.video = video
    }

    var streamID: String {
        video?.id ?? meta.id
    }

    /// The id actually sent to stream addons — resolved once, then reused so
    /// the cache key and every fetch agree. Two normalizations, both so a
    /// resumed / manually-played title lands on an id Cinemeta/Comet/Torrentio
    /// can resolve (the "Comet unable to get metadata" empty source page):
    ///  1. `tmdb:<n>` → IMDb `tt` (those addons can't serve tmdb ids).
    ///  2. For a series episode, force the canonical `showId:season:episode`
    ///     form instead of trusting a stored `video.id`, which after a
    ///     Continue-Watching round-trip can be the bare show id.
    private var resolvedID: String?
    /// When the user pressed Play. Every stage below logs its offset from this,
    /// so a slow open can be attributed to a stage instead of guessed at.
    var openedAt = Date()
    func stage(_ name: String) {
        NSLog("[OrivioPlay] +%.2fs %@", Date().timeIntervalSince(openedAt), name)
    }

    private func effectiveStreamID() async -> String {
        if let resolvedID { return resolvedID }
        var showID = meta.id
        if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: meta.type != "series") {
            // A network round-trip BEFORE a single addon is queried. Catalogs
            // sourced from TMDB hand us `tmdb:` ids, so this is on the critical
            // path of most plays.
            showID = tt
            stage("tmdb→imdb id resolved")
        }
        let id: String
        if showID.hasPrefix("tt"), let season = video?.season, let episode = video?.episode {
            id = "\(showID):\(season):\(episode)"
        } else {
            id = video?.id ?? showID
        }
        resolvedID = id
        return id
    }

    var allEntries: [StreamEntry] {
        groups.flatMap(\.entries)
    }

    /// Whether the list has at least one PLAYABLE row.
    ///
    /// `groups` being non-empty is not the same thing: once the sweep finishes,
    /// `rebuildGroups` appends a name-only group for every addon that returned
    /// nothing, so a single stream addon that times out leaves one group of
    /// pure `Text`. The panel used to take that as "we have results", skip the
    /// empty state with its Try Again button, and render a page with NOTHING
    /// focusable — and a Menu press on a focus-less page falls through to tvOS
    /// and suspends the app (see the FocusAnchor note in HomeView).
    var hasPlayableEntries: Bool {
        groups.contains { !$0.entries.isEmpty }
    }

    /// Filter the visible list to a single addon (nil = All). Re-curates from
    /// the raw pool so the chosen addon shows its full per-tier selection.
    func selectAddon(_ name: String?) {
        guard selectedAddon != name else { return }
        selectedAddon = name
        rebuildGroups()
    }

    /// Disk-backed cache of a title's raw source list so re-opening a title
    /// (or resuming from Continue Watching) rebuilds the Sources list instantly
    /// instead of sweeping every addon again. TTL is short because addon direct
    /// links can go stale; the player's failover re-fetches if one has expired.
    static let sourceCache = DiskCache<[CachedStreamSource]>(name: "sources")
    static let sourceCacheTTL: TimeInterval = 15 * 60

    /// Remembers the last successfully-played source per title so "Reuse last
    /// link" can replay it without another addon sweep. Freshness is enforced
    /// per-read against the user's chosen cache window.
    static let lastLinkCache = DiskCache<CachedStreamSource>(name: "lastlink")

    /// The last played source for this title if still within `hours`, else nil.
    func freshLastLink(hours: Int) async -> StreamEntry? {
        let id = await effectiveStreamID()
        guard let cached = await Self.lastLinkCache.value(
            for: id, ttl: TimeInterval(max(1, hours)) * 3600
        ) else { return nil }
        return StreamEntry(addonName: cached.addonName, stream: cached.stream)
    }

    /// Record a resolved, directly-playable source as this title's last link.
    func recordLastLink(_ entry: StreamEntry) {
        guard entry.stream.isPlayable, let id = resolvedID else { return }
        let cached = CachedStreamSource(addonName: entry.addonName, stream: entry.stream)
        Task { await Self.lastLinkCache.store(cached, for: id) }
    }

    /// Merge streams produced by plugin scrapers into the pool (they arrive
    /// after the addon sweep, so re-curate). Deduped by URL.
    func addPluginStreams(_ entries: [StreamEntry]) {
        guard !entries.isEmpty else { return }
        let existing = Set(pool.compactMap { $0.stream.url })
        let fresh = entries.filter { entry in
            guard let url = entry.stream.url else { return false }
            return !existing.contains(url)
        }
        guard !fresh.isEmpty else { return }
        pool.append(contentsOf: fresh)
        rebuildGroups()
    }

    /// Best source for a profile's Auto Link Selector. Entries are already
    /// sorted best-first; we filter by the profile's cached-only / min-
    /// resolution / max-size prefs, then prefer the chosen addon (then the
    /// secondary), falling back to the best remaining link. Unknown
    /// resolution/size never disqualifies a link (missing metadata shouldn't
    /// hide a possibly-good source).
    /// Addons whose stream request has returned (either way).
    @Published private(set) var finishedAddonNames: Set<String> = []
    private var sweepStarted = Date()
    /// Set by the view while the Auto Link Selector is armed, so the sweep can
    /// hand back a pick without waiting for every addon.
    var autoLinkPrefs: AutoLinkPreferences?
    var onEarlyAutoLink: ((StreamEntry) -> Void)?
    private var earlyPickFired = false
    /// Longest we will hold out for a preferred addon that hasn't answered.
    private static let preferredAddonWait: TimeInterval = 6

    /// A pick that is safe to act on BEFORE the sweep has finished.
    ///
    /// The Auto Link Selector used to run only after `load` returned — that is,
    /// after the SLOWEST installed addon had answered or timed out. Your
    /// preferred addon replying in half a second bought nothing; every play was
    /// paced by the worst one in the list, which is why turning the selector on
    /// made starting a title feel slower rather than faster.
    ///
    /// The rule: if the preferred addon has produced a usable match, take it.
    /// If it has answered and produced nothing, fall through to the secondary
    /// on the same terms. Only wait while an addon we actually care about is
    /// still outstanding — and not past `preferredAddonWait`, so one dead addon
    /// can't hold up the whole thing.
    func earlyAutoLinkPick(_ prefs: AutoLinkPreferences) -> StreamEntry? {
        let pool = autoLinkPool(prefs)
        // Patience only means something when there is a specific addon whose
        // answer we are waiting FOR. With neither a preferred nor a secondary
        // addon set — the default — the window below made the selector sit on a
        // perfectly good cached link that arrived at 300ms for the full 6s and
        // then take it anyway.
        let hasAddonPreference = !prefs.preferredAddon.trimmingCharacters(in: .whitespaces).isEmpty
            || !prefs.secondaryAddon.trimmingCharacters(in: .whitespaces).isEmpty
        let patient = hasAddonPreference
            && Date().timeIntervalSince(sweepStarted) < Self.preferredAddonWait

        /// Whether an addon can still change the answer: it has to be one we
        /// queried at all, and not yet returned.
        func outstanding(_ name: String) -> Bool {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return false }
            guard queriedAddonNames.contains(where: { $0.lowercased().contains(q) }) else { return false }
            return !finishedAddonNames.contains { $0.lowercased().contains(q) }
        }
        func firstFrom(_ name: String) -> StreamEntry? {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return nil }
            return pool.first { $0.addonName.lowercased().contains(q) }
        }

        if let hit = firstFrom(prefs.preferredAddon) { return hit }
        if patient, outstanding(prefs.preferredAddon) { return nil }
        if let hit = firstFrom(prefs.secondaryAddon) { return hit }
        if patient, outstanding(prefs.secondaryAddon) { return nil }
        // No addon preference left to honour. Anything already in hand will do
        // once the sweep is done; until then keep collecting.
        guard finishedAddons >= totalAddons || !patient else { return nil }
        return pool.first
    }

    /// Evaluate the early pick and fire it at most once per sweep.
    ///
    /// Called both when an addon answers AND from a deadline timer, because the
    /// per-batch path can only run when an addon answers — which made
    /// `preferredAddonWait` really mean "6s OR the next addon to reply,
    /// whichever is LATER". One slow addon stretched a 6s window to the full
    /// 45s stream timeout.
    func evaluateEarlyAutoLink(_ prefs: AutoLinkPreferences) {
        guard !earlyPickFired, !allEntries.isEmpty else { return }
        rebuildGroups()
        guard let pick = earlyAutoLinkPick(prefs) else { return }
        earlyPickFired = true
        stage("auto-link picked \(pick.addonName) — \(pick.displayName)")
        onEarlyAutoLink?(pick)
    }

    /// The entries a profile's Auto Link prefs allow, best-first.
    private func autoLinkPool(_ prefs: AutoLinkPreferences) -> [StreamEntry] {
        let minTier = prefs.minResolution.isEmpty ? nil
            : ResolutionTier.from(resolutionLabel: prefs.minResolution)
        let maxSizeGB = AutoLinkPreferences.sanitizedMaxSizeGB(prefs.maxSizeGB)
        let maxBytes = maxSizeGB > 0 ? Int64(maxSizeGB * 1_073_741_824) : nil
        let pool = allEntries.filter { entry in
            if prefs.cachedOnly && !entry.stream.isCached { return false }
            if prefs.avoidDolbyVision && entry.stream.isDolbyVision { return false }
            if let minTier, let label = entry.resolutionLabel,
               ResolutionTier.from(resolutionLabel: label).rawValue > minTier.rawValue { return false }
            if let maxBytes, let bytes = entry.sizeBytes, bytes > 0, bytes > maxBytes { return false }
            return true
        }
        // Skip links a recent session walked straight back out of, so pressing
        // Play again moves on instead of re-serving the one that just failed.
        let rejected = RejectedLinks.rejected(for: ProgressStore.key(metaID: meta.id, video: video))
        guard !rejected.isEmpty else { return pool }
        let survivors = pool.filter { !rejected.contains($0.rejectionKey) }
        // If avoiding them leaves nothing, the grudge is worse than the link:
        // play the best match rather than dropping to the manual list.
        return survivors.isEmpty ? pool : survivors
    }

    func autoLinkPick(_ prefs: AutoLinkPreferences) -> StreamEntry? {
        let pool = autoLinkPool(prefs)
        guard !pool.isEmpty else { return nil }
        func firstFromAddon(_ name: String) -> StreamEntry? {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return nil }
            return pool.first { $0.addonName.lowercased().contains(q) }
        }
        return firstFromAddon(prefs.preferredAddon)
            ?? firstFromAddon(prefs.secondaryAddon)
            ?? pool.first
    }

    /// First source to auto-play (entries are already sorted best-first),
    /// honoring cached-only and an optional case-insensitive title regex.
    func autoPlayPick(cachedOnly: Bool, regex: String) -> StreamEntry? {
        let trimmed = regex.trimmingCharacters(in: .whitespaces)
        let re = trimmed.isEmpty ? nil
            : try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
        return allEntries.first { entry in
            if cachedOnly && !entry.stream.isCached { return false }
            if let re {
                let hay = "\(entry.addonName) \(entry.displayName) \(entry.displayDetail)"
                let range = NSRange(hay.startIndex..., in: hay)
                if re.firstMatch(in: hay, range: range) == nil { return false }
            }
            return true
        }
    }

    /// Best fresh link to auto-resume with, given the format last watched. Ranks
    /// by similarity — same resolution, Dolby Vision, HDR, Atmos — and prefers
    /// the same add-on and cached/instant links, so a resume re-connects with a
    /// comparable stream instead of a dead URL. Falls back to the best overall
    /// link when nothing is remembered or nothing matches.
    func bestResumeMatch(signature: StreamSignature?) -> StreamEntry? {
        // Never auto-resume into an external hand-off (a "cast to DMM" style
        // entry opens another app) — resume must play a real stream here.
        let candidates = allEntries.filter { !$0.stream.isExternal }
        guard !candidates.isEmpty else { return nil }
        guard let sig = signature else { return candidates.first }
        func matchScore(_ e: StreamEntry) -> Int {
            var s = 0
            if e.stream.isCached { s += 6 }   // instant beats waiting on a re-download
            if let want = sig.resolution, let have = e.resolutionLabel, want == have { s += 8 }
            if sig.dolbyVision { s += e.stream.isDolbyVision ? 6 : -6 }
            if sig.hdr, e.stream.isHDR { s += 3 }
            if sig.atmos { s += e.stream.hasAtmos ? 4 : -3 }
            if let a = sig.addonName, e.addonName.caseInsensitiveCompare(a) == .orderedSame { s += 4 }
            return s
        }
        // Entries are already sorted best-first; pick the highest signature
        // match, breaking ties toward that existing (better) base rank.
        return candidates.enumerated().max { lhs, rhs in
            let l = matchScore(lhs.element), r = matchScore(rhs.element)
            return l != r ? l < r : lhs.offset > rhs.offset
        }?.element
    }

    /// Reset and fetch again (the empty state's Try Again) — bypasses the cache
    /// so the user gets a genuinely fresh sweep.
    func reload(addonManager: AddonManager, debridEnabled: Bool, perTier: Int, filtersEnabled: Bool = true) async {
        groups = []
        pool = []
        addonNames = []
        selectedAddon = nil
        finishedAddons = 0
        // NOTE: the view resets its one-shot focus latch around this call —
        // `reload` regenerates every entry id, so the previously focused row no
        // longer exists, and the retry button that held focus disappears the
        // moment results arrive.
        await load(addonManager: addonManager, debridEnabled: debridEnabled, perTier: perTier, filtersEnabled: filtersEnabled, forceRefresh: true)
    }

    /// When a debrid provider is configured, torrent streams (infoHash, no
    /// direct URL) are kept so they can be resolved on selection; otherwise
    /// only directly-playable http(s) streams are shown.
    ///
    /// Each addon's links are grouped into size tiers (250 MB–4 GB … 30 GB+),
    /// debrid-cached links first within each tier, capped at `perTier` — so
    /// the list is short and useful instead of the 150+ near-identical rips
    /// Torrentio alone returns, which is what made scrolling (and selecting
    /// during load) choke.
    func load(addonManager: AddonManager, debridEnabled: Bool, perTier: Int, filtersEnabled: Bool = true, forceRefresh: Bool = false) async {
        let fetchID = await effectiveStreamID()
        stage("stream id ready (\(fetchID))")
        // Self-heal: an addon installed by account sync while its manifest
        // fetch failed is a silent placeholder (no stream resource → never
        // queried, no error anywhere). Retry those now, when the user actually
        // needs them, so e.g. a DMM Cast that installed broken starts working.
        if addonManager.addons.contains(where: { $0.enabled && $0.manifest.isPlaceholder }) {
            // Detached: this is a self-heal for add-ons whose manifest failed to
            // load earlier, and nothing about this play depends on it. Awaiting
            // it put up to N x 5s in front of the first stream request.
            Task { [addonManager] in await addonManager.resolvePlaceholders() }
        }
        let addons = addonManager.streamAddons.filter { $0.handles(id: fetchID) }
        var seenNames = Set<String>()
        queriedAddonNames = addons.compactMap {
            seenNames.insert($0.manifest.name).inserted ? $0.manifest.name : nil
        }
        // Surface every enabled addon that is NOT being queried, with why —
        // and mirror it to the console for debugging.
        var skipped: [(id: String, name: String, reason: String)] = []
        for addon in addonManager.addons where addon.enabled {
            let m = addon.manifest
            if m.isPlaceholder {
                skipped.append((addon.id, m.name, "Not working — couldn't load this add-on. Check its URL or refresh add-ons."))
            } else if m.providesStreams, !addon.handles(id: fetchID) {
                let prefixes = (m.idPrefixes ?? []).joined(separator: ", ")
                skipped.append((addon.id, m.name, "Doesn't claim this title (id \(fetchID) vs prefixes [\(prefixes)])"))
            }
        }
        skippedAddons = skipped
        NSLog("[OrivioSources] id=%@ querying=%@ skipped=%@",
              fetchID, queriedAddonNames.joined(separator: "|"),
              skipped.map { "\($0.name): \($0.reason)" }.joined(separator: "|"))
        totalAddons = addons.count
        self.perTier = perTier
        self.filtersEnabled = filtersEnabled
        isLoading = true

        // Instant path: a fresh cached source list rebuilds the whole page with
        // no addon sweep at all.
        if !forceRefresh,
           let cached = await Self.sourceCache.value(for: fetchID, ttl: Self.sourceCacheTTL),
           !cached.isEmpty {
            pool = cached.map { StreamEntry(addonName: $0.addonName, stream: $0.stream) }
            finishedAddons = totalAddons
            rebuildGroups()
            isLoading = false
            return
        }

        failedAddons = [:]
        finishedAddonNames = []
        sweepStarted = Date()
        // Reset per sweep, or a refresh after an early pick could never fire one.
        earlyPickFired = false
        // The deadline that `preferredAddonWait` was always supposed to be.
        var autoLinkDeadline: Task<Void, Never>?
        if let prefs = autoLinkPrefs {
            autoLinkDeadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.preferredAddonWait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.evaluateEarlyAutoLink(prefs)
            }
        }
        defer { autoLinkDeadline?.cancel() }
        await withTaskGroup(of: (name: String, entries: [StreamEntry],
                                 failure: (name: String, reason: String)?).self) { group in
            // Bounded window: with a large install this sweep queries dozens of
            // addons. Firing them all at once spikes memory right when the user
            // is waiting on the list, and the tail is set by the slowest addon
            // either way.
            let window = max(1, min(AddonSweepLimits.streams, addons.count))
            var next = 0
            func startNext() {
                guard next < addons.count else { return }
                let addon = addons[next]
                next += 1
                group.addTask { [meta] in
                    do {
                        let streams = try await StremioAPI.streams(addon: addon, type: meta.type, id: fetchID)
                        let entries = streams
                            .filter { $0.isPlayable || (debridEnabled && $0.isTorrent) || $0.isExternal }
                            .map { StreamEntry(addonName: addon.manifest.name, stream: $0) }
                        return (addon.manifest.name, entries, nil)
                    } catch {
                        // Request failed (timeout / HTTP error / unreachable) —
                        // record the SPECIFIC reason so the UI can say what's
                        // wrong instead of a generic "didn't respond".
                        NSLog("[OrivioSources] %@ stream request failed: %@",
                              addon.manifest.name, String(describing: error))
                        return (addon.manifest.name, [], (addon.manifest.name, Self.shortReason(for: error)))
                    }
                }
            }
            for _ in 0..<window { startNext() }
            // Re-curate on throttled batches: recomputing the tier selection per
            // addon made the whole list re-diff several times in the first
            // seconds — exactly while the user starts scrolling it.
            var lastFlush = Date.distantPast
            for await batch in group {
                startNext()
                finishedAddons += 1
                finishedAddonNames.insert(batch.name)
                stage("addon \(batch.name) answered (\(batch.entries.count) links, \(finishedAddons)/\(totalAddons))")
                pool.append(contentsOf: batch.entries)
                if let failure = batch.failure { failedAddons[failure.name] = failure.reason }
                let now = Date()
                if !pool.isEmpty, now.timeIntervalSince(lastFlush) > 0.4 {
                    rebuildGroups()
                    lastFlush = now
                }
                // Auto Link Selector: act the MOMENT the answer is knowable,
                // rather than at the end of the sweep. See earlyAutoLinkPick.
                if let prefs = autoLinkPrefs { evaluateEarlyAutoLink(prefs) }
            }
            rebuildGroups()
        }
        isLoading = false

        // Persist for instant re-open — but ONLY a sweep that actually finished.
        // This ran even when `onDisappear` cancelled the task, so backing out at
        // two seconds persisted a one-addon snapshot that the next open then
        // showed as the complete list for the full cache TTL.
        let snapshot = pool.map { CachedStreamSource(addonName: $0.addonName, stream: $0.stream) }
        if !snapshot.isEmpty, !Task.isCancelled, finishedAddons >= totalAddons {
            await Self.sourceCache.store(snapshot, for: fetchID)
        }
    }

    /// Recompute `addonNames` + `groups` from the raw pool, honoring the
    /// current addon filter. Called on every load flush and filter change.
    private func rebuildGroups() {
        // Filter chips list EVERY queried addon (installed order), not just ones
        // that returned links — so an empty/cast-only addon stays selectable.
        addonNames = queriedAddonNames
        // Drop a stale filter (e.g. after a reload dropped that addon).
        if let selected = selectedAddon, !queriedAddonNames.contains(selected) {
            selectedAddon = nil
        }
        let scoped0 = selectedAddon.map { name in pool.filter { $0.addonName == name } } ?? pool
        let scoped = SourceSelection.filter(scoped0, streamFilters)
        var built = filtersEnabled
            ? SourceSelection.byAddon(scoped, perTier: perTier)
            : SourceSelection.byAddonUnfiltered(scoped, cap: PlayerSettings.unfilteredPerAddonCap)

        // EVERY queried addon gets a slot from the first rebuild, not just the
        // ones that have answered. Appending these only at the end meant the
        // list changed shape twice underneath the reader: a slow addon that sits
        // early in the installed order inserted its whole group ABOVE the rows
        // being scanned, and then at completion a batch of "None" headings was
        // scattered through the list — both while someone was settling on a
        // candidate. With the skeleton in place results fill into slots that
        // already exist and nothing is ever inserted above the reading position.
        //
        // An addon that has not replied yet renders as pending rather than
        // "None"; `finishedAddonNames` is what tells the row which it is.
        let wanted = selectedAddon.map { [$0] } ?? queriedAddonNames
        let present = Set(built.map(\.addonName))
        for name in wanted where !present.contains(name) {
            built.append(AddonSourceGroup(addonName: name, sections: []))
        }
        // Stable installed-order layout regardless of which addon replied first.
        let order = Dictionary(
            uniqueKeysWithValues: queriedAddonNames.enumerated().map { ($1, $0) }
        )
        groups = built.sorted { (order[$0.addonName] ?? .max) < (order[$1.addonName] ?? .max) }
    }

    /// User stream filters (min resolution, exclude AV1, HDR/DV/cached only).
    var streamFilters = StreamFilterOptions()
}

struct StreamsView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @EnvironmentObject private var plugins: PluginStore
    @EnvironmentObject private var torrent: TorrentSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var viewModel: StreamsViewModel

    /// Manual mode (hold-Play / "Play Manually"): skip every auto-action so the
    /// user always lands on the source list, even with Auto Link Selector on.
    let forceManual: Bool
    /// Resuming from Continue Watching: re-scrape fresh sources and auto-play the
    /// one that best matches `resumeSignature` (the format last watched), instead
    /// of replaying a possibly-expired remembered link. Bypasses reuse-last-link.
    let resumeAutoPlay: Bool
    let resumeSignature: StreamSignature?
    /// Called when the Auto Link Selector auto-plays, so the caller can pop this
    /// page off the stack — backing out of the player returns to the title, not
    /// the source list.
    var onAutoDismiss: () -> Void = {}

    /// Auto Link Selector is resolving: show a loading screen instead of the
    /// source list so Play goes straight to "loading" with no list flash.
    @State private var autoLinkResolving = false

    @State private var resolving = false
    @State private var resolveError: String?
    // Sources load asynchronously; when the first ones arrive, move focus onto
    // the top source so the trackpad can navigate immediately instead of the
    // user having to swipe to "find" focus.
    @FocusState private var focusedEntry: UUID?
    /// Guards the one-time auto-focus so filter changes don't steal focus.
    @State private var didInitialFocus = false
    /// Guards the one-shot auto-play / reuse-last-link so backing out of the
    /// player lands on the manual list instead of re-triggering.
    @State private var didAutoAct = false
    /// Set once this view is popped (Back). Every async completion that would
    /// present the player or dismiss the page checks it first — firing
    /// `onSelect`/`startPlayback` from a torn-down navigation entry presents the
    /// player over a ghost stack and crashes/quits the app (the same desync the
    /// player cover's onDismiss comment warns about). `Task.isCancelled` alone
    /// isn't enough: the debrid/P2P resolve runs in its OWN unstructured Task
    /// that Back never cancels, so it needs an explicit view-level flag.
    @State private var isGone = false
    /// The in-flight source sweeps, cancelled when the page pops.
    @State private var sweepTasks: [Task<Void, Never>] = []

    let onSelect: (StreamEntry, [StreamEntry]) -> Void

    init(meta: MetaItem, video: MetaVideo?, forceManual: Bool = false,
         resumeAutoPlay: Bool = false, resumeSignature: StreamSignature? = nil,
         onAutoDismiss: @escaping () -> Void = {},
         onSelect: @escaping (StreamEntry, [StreamEntry]) -> Void) {
        _viewModel = StateObject(wrappedValue: StreamsViewModel(meta: meta, video: video))
        self.forceManual = forceManual
        self.resumeAutoPlay = resumeAutoPlay
        self.resumeSignature = resumeSignature
        self.onAutoDismiss = onAutoDismiss
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            // Auto Link Selector armed: the source page is an implementation
            // detail the viewer never asked to see. Show the title's own
            // loading screen — the SAME one the player is about to put up — and
            // let the addon sweep finish behind it, so pressing Play reads as
            // one continuous "opening the movie" rather than a detour through a
            // list that flashes past.
            if autoLinkResolving {
                AutoLinkLoadingScreen(
                    meta: viewModel.meta,
                    status: resolving
                        ? "Resolving via \(debrid.resolverProvider?.displayName ?? (torrent.settings.isConfigured ? "TorrServer" : "debrid"))"
                        : "Finding the best source"
                )
                .transition(.opacity)
            } else {
            ATVBackground()
            backdrop

            // APK split layout: content info on the LEFT, sources panel on the RIGHT.
            HStack(alignment: .top, spacing: OrivioSpacing.xl) {
                titleBlock
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sourcesPanel
                    .frame(width: 900)
                    .frame(maxHeight: .infinity)
                    .background(
                        // Opaque: a translucent panel over the full-screen
                        // backdrop forced per-frame blending of the whole
                        // panel while scrolling — a real cost on the A10X.
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(theme.palette.backgroundElevated)
                    )
                    // Keep the scrolling rows INSIDE the rounded panel —
                    // without this they draw over its edges as you scroll.
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.vertical, OrivioSpacing.xxl)

            // Only over the LIST — while the auto-link loading screen is up it
            // carries the resolve status itself, rather than stacking a second
            // dimmed spinner on top of a screen that is already a spinner.
            if resolving {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    OrivioLoadingView(label: "Resolving via \(debrid.resolverProvider?.displayName ?? (torrent.settings.isConfigured ? "TorrServer" : "debrid"))")
                }
            }
            }
        }
        .animation(.easeOut(duration: 0.2), value: autoLinkResolving)
        .task {
            let s = playerSettings.settings
            viewModel.streamFilters = s.streamFilterOptions
            // Auto Link Selector on (and not forced manual): show the loading
            // screen instead of the source list from the very first frame.
            autoLinkResolving = (profiles.activeAutoLink.enabled || resumeAutoPlay) && !forceManual
            viewModel.openedAt = Date()
            viewModel.stage("sources page opened")

            // Arm the early pick BEFORE the sweep starts, so the selector can
            // act as soon as the preferred addon answers instead of waiting for
            // the slowest one. The `didAutoAct` guard below still runs for the
            // cases this can't decide early (resume match, reuse-last-link).
            let armedAutoLink = profiles.activeAutoLink
            // No reuse-last-link condition here. That check runs synchronously
            // just below and, if it hits, sets `didAutoAct` — which the early
            // callback already tests. Gating on the SETTING instead meant that
            // simply having "Reuse last link" switched on disabled the early
            // pick for every title, including the ones with nothing remembered.
            // Resumes are armed too. Continue Watching used to run its own
            // format-matching pick and never consult the selector, so the same
            // title started one way from the detail page and another way from
            // the Continue Watching row. With the selector on it should choose
            // sources the same way everywhere.
            if armedAutoLink.enabled, !forceManual {
                viewModel.autoLinkPrefs = armedAutoLink
                viewModel.onEarlyAutoLink = { pick in
                    guard !isGone, !didAutoAct else { return }
                    didAutoAct = true
                    handleSelection(pick, viewModel.allEntries)
                    onAutoDismiss()
                }
            }

            // Reuse last link: if we still have a fresh remembered source, play
            // it immediately, but keep loading so backing out shows the full
            // list (and the player's failover has alternates).
            // Both sweeps are UNSTRUCTURED tasks (they must outlive awaits in
            // this .task) — kept in state so popping the page CANCELS them:
            // without that, backing out of a source list left the full addon
            // sweep + the JS plugin scrapers running to completion, and quick
            // browsing stacked concurrent full scrapes with no ceiling.
            let loadTask = Task {
                await viewModel.load(
                    addonManager: addonManager,
                    debridEnabled: debrid.hasAnyConfigured || torrent.settings.isConfigured,
                    perTier: s.sourcesPerSizeTier,
                    filtersEnabled: s.sourceFiltersEnabled
                )
            }
            sweepTasks.append(loadTask)
            // Plugin scrapers run alongside the addon sweep (they want a TMDB id).
            if !plugins.enabledScrapers.isEmpty {
                let pluginTask = Task {
                    guard let (tmdbID, isMovie) = await TMDBService.resolveTMDBID(
                        from: viewModel.meta.id, type: viewModel.meta.type
                    ) else { return }
                    let entries = await plugins.streams(
                        tmdbID: String(tmdbID), mediaType: isMovie ? "movie" : "tv",
                        season: viewModel.video?.season, episode: viewModel.video?.episode
                    )
                    guard !Task.isCancelled, !isGone else { return }
                    viewModel.addPluginStreams(entries)
                }
                sweepTasks.append(pluginTask)
            }
            // Reuse-last-link replays the remembered URL — skip it entirely when
            // resuming, since the whole point of a resume is to re-connect fresh.
            if !didAutoAct, !forceManual, !resumeAutoPlay, s.reuseLastLinkEnabled,
               let last = await viewModel.freshLastLink(hours: s.reuseLastLinkCacheHours) {
                // Re-test AFTER the await. `freshLastLink` suspends on the disk
                // cache, and the early Auto-Link callback can fire during that
                // suspension — the `!didAutoAct` test in the condition above had
                // already passed, so both paths acted and two playback requests
                // were issued for the same title.
                guard !didAutoAct else { return }
                didAutoAct = true
                // Do NOT wait for the sweep. The remembered link is already in
                // hand — the only thing `loadTask` would add is the alternates
                // list, and the player fetches those on demand via
                // `loadSourcesIfNeeded()` when it holds a single entry. Awaiting
                // it here paced the one feature built to make replay INSTANT at
                // the speed of the slowest installed add-on: ceil(addons/8) x the
                // 45s stream timeout in the worst case, 3-20s typically.
                //
                // The sweep is deliberately left running: it still fills
                // `sourceCache`, so the in-player Sources panel and any failover
                // are warm by the time they are needed.
                guard !isGone else { return }
                onSelect(last, [last])
                // Signals a deferred pop (handled when the player closes); does
                // NOT tear down this view now, so the in-flight resolve is safe.
                if autoLinkResolving { onAutoDismiss() }
                return
            }
            await loadTask.value
            // Back-during-load guard (see above): bail before any auto-act.
            guard !Task.isCancelled, !isGone else { return }

            // Resume from Continue Watching: re-scrape done, now auto-play the
            // link that best matches the format last watched (fresh connection,
            // so expired debrid/Comet links don't fail). Takes precedence over
            // the profile Auto Link Selector / global auto-play below.
            // Continue Watching resume. With the Auto Link Selector OFF this is
            // unchanged: re-pick the link closest to the format last watched.
            // With it ON, the selector's preferences win and this is skipped —
            // the selector block below handles the resume as an ordinary play.
            if !didAutoAct, !forceManual, resumeAutoPlay, !armedAutoLink.enabled {
                if let pick = viewModel.bestResumeMatch(signature: resumeSignature) {
                    didAutoAct = true
                    handleSelection(pick, viewModel.allEntries)
                    onAutoDismiss()
                } else {
                    autoLinkResolving = false   // nothing found → reveal the list
                }
            }

            // Auto Link Selector (per profile): pick the best link matching the
            // profile's preferred addon / quality / size and play it directly.
            // Takes precedence over the global auto-play. Skipped in manual mode.
            let autoLink = armedAutoLink
            if !didAutoAct, !forceManual, autoLink.enabled {
                if let pick = viewModel.autoLinkPick(autoLink) {
                    didAutoAct = true
                    handleSelection(pick, viewModel.allEntries)
                    // Request a pop AFTER the player closes (not now) so backing
                    // out lands on the title page, not the source list — popping
                    // here would tear this view down mid-resolve and crash.
                    onAutoDismiss()
                } else {
                    // No source matched the prefs — reveal the list as a manual
                    // fallback instead of leaving the loading screen up.
                    autoLinkResolving = false
                }
            }

            // Auto-play best source: once the sweep is done, start the best
            // matching link without waiting for a manual pick.
            if !didAutoAct, !forceManual, s.autoPlaySourceEnabled,
               let best = viewModel.autoPlayPick(
                   cachedOnly: s.autoPlaySourceCachedOnly, regex: s.autoPlaySourceRegex
               ) {
                didAutoAct = true
                handleSelection(best, viewModel.allEntries)
            }

            // Safety net: if we opened in auto-loading mode but nothing acted,
            // drop the loading screen so the user isn't stuck on it.
            if autoLinkResolving && !didAutoAct { autoLinkResolving = false }
        }
        // Back popped this page: block every pending async completion from
        // presenting the player / touching navigation on a torn-down view,
        // and stop the sweeps themselves (their awaits return promptly).
        .onDisappear {
            isGone = true
            for task in sweepTasks { task.cancel() }
            sweepTasks = []
        }
        .alert("Couldn't resolve stream", isPresented: Binding(
            get: { resolveError != nil },
            set: { if !$0 { resolveError = nil; autoLinkResolving = false } }
        )) {
            Button("OK", role: .cancel) {
                resolveError = nil
                // If an auto-pick (resume / Auto Link) failed to resolve, drop
                // the loading screen so the manual list is reachable — without
                // this, dismissing the alert stranded the user on
                // "Finding the best source…" forever.
                autoLinkResolving = false
            }
        } message: {
            Text(resolveError ?? "")
        }
    }

    /// The right-hand source panel: loading / empty / grouped list.
    @ViewBuilder
    private var sourcesPanel: some View {
        if autoLinkResolving {
            OrivioLoadingView(label: "Finding the best source…", holdsFocus: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            if viewModel.isLoading {
                OrivioLoadingView(label: streamCountLabel, holdsFocus: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: OrivioSpacing.lg) {
                    OrivioEmptyState(
                        icon: "play.slash",
                        title: "No sources found",
                        message: "None of your installed addons returned a playable link for this title. Install a stream addon in Settings."
                    )
                    // Explain any addon that wasn't even queried, so an addon
                    // that silently failed to install isn't a mystery here.
                    ForEach(viewModel.skippedAddons, id: \.id) { skip in
                        Text("\(skip.name): \(skip.reason)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, OrivioSpacing.huge)
                    }
                    retryButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                if viewModel.addonNames.count > 1 {
                    addonFilterBar
                }
                streamList
            }
            .padding(OrivioSpacing.md)
        }
    }

    /// The retry affordance, shared by the empty state and by the diagnostic
    /// list (see `streamList`) — the page's guaranteed focusable control.
    private var retryButton: some View {
        Button {
            Task {
                // Re-arm the one-shot focus grab: every entry id is about to be
                // regenerated, so nothing that currently holds focus will still
                // exist, and the retry button that has it disappears as soon as
                // results land. Without this the page ends up with nothing
                // focused — the state this file's own comments identify as
                // letting a Menu press fall through and suspend the app.
                didInitialFocus = false
                focusedEntry = nil
                await viewModel.reload(
                    addonManager: addonManager,
                    debridEnabled: debrid.hasAnyConfigured || torrent.settings.isConfigured,
                    perTier: playerSettings.settings.sourcesPerSizeTier,
                    filtersEnabled: playerSettings.settings.sourceFiltersEnabled
                )
            }
        } label: {
            RetryLabel()
        }
        .buttonStyle(PlainCardButtonStyle())
    }

    /// Stremio-style addon filter: "All" plus one chip per addon that returned
    /// links. Picking one shows only that addon's sources (still tiered).
    private var addonFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OrivioSpacing.sm) {
                AddonFilterChip(
                    title: "All",
                    selected: viewModel.selectedAddon == nil
                ) { viewModel.selectAddon(nil) }

                ForEach(viewModel.addonNames, id: \.self) { name in
                    AddonFilterChip(
                        title: name,
                        selected: viewModel.selectedAddon == name
                    ) { viewModel.selectAddon(name) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// Torrent entries resolve through the preferred debrid provider before
    /// playback; direct streams pass straight through.
    private func handleSelection(_ entry: StreamEntry, _ all: [StreamEntry]) {
        // Back already popped this page — never present the player from a
        // torn-down navigation entry (crashes / quits the app).
        guard !isGone else { return }
        // Cast / open-externally stream (DMM Cast): hand the link to the system
        // rather than the in-app player. On tvOS this only succeeds for a URL
        // scheme the platform can open — plain https has no browser to open, so
        // report that instead of failing silently.
        if entry.stream.isExternal, let ext = entry.stream.externalUrl,
           let url = URL(string: ext) {
            UIApplication.shared.open(url, options: [:]) { ok in
                if !ok {
                    resolveError = "Apple TV can't open this cast link directly. Open Debrid Media Manager on your phone or computer to cast."
                }
            }
            return
        }
        guard entry.stream.isTorrent else {
            viewModel.stage("direct link — handing to player")
            viewModel.recordLastLink(entry)
            onSelect(entry, all)
            return
        }
        viewModel.stage("torrent — starting debrid resolve")
        guard let provider = debrid.resolverProvider else {
            // No debrid: fall back to P2P (TorrServer) if the user enabled it.
            if torrent.settings.isConfigured {
                resolveViaP2P(entry, all)
            } else {
                resolveError = "Add a debrid API key, or turn on P2P (TorrServer) in Settings → Integrations, to play torrent sources."
            }
            return
        }
        resolving = true
        Task {
            // Try every configured debrid, preferred first — a torrent the
            // preferred provider doesn't have cached still resolves via the
            // others (TorBox / RD / PM / AD).
            let (result, resolvedBy) = await DebridService.resolveAcross(
                stream: entry.stream,
                providers: await debrid.resolversRefreshingIfNeeded(),
                season: viewModel.video?.season,
                episode: viewModel.video?.episode,
                // The addon told us WHICH file of the pack this row is. Without
                // it every row of a season pack resolved to the same (largest)
                // episode — the rows the fileIdx-aware dedupe now surfaces were
                // all playing the same file.
                fileIdx: entry.stream.fileIdx
            )
            let provider = resolvedBy ?? provider
            resolving = false
            // Back popped the page during the resolve (this Task isn't cancelled
            // by the pop) — don't present the player over a ghost stack.
            guard !isGone else { return }
            switch result {
            case .success(let url, let filename):
                let resolved = Stream(
                    name: entry.stream.name,
                    title: filename ?? entry.stream.title,
                    description: entry.stream.description,
                    url: url,
                    infoHash: nil,
                    behaviorHints: entry.stream.behaviorHints
                )
                let resolvedEntry = StreamEntry(addonName: "\(provider.shortName) · \(entry.addonName)", stream: resolved)
                viewModel.recordLastLink(resolvedEntry)
                viewModel.stage("resolved — handing to player")
                onSelect(resolvedEntry, all)
            case .missingKey:
                resolveError = "\(provider.displayName) API key is missing."
            case .notCached:
                resolveError = debrid.orderedResolvers.count > 1
                    ? "This torrent isn't cached on any of your debrid services. Try another source."
                    : "This torrent isn't cached on \(provider.displayName). Try another source."
            case .failed(let message):
                resolveError = "\(provider.displayName): \(message)"
            }
        }
    }

    /// Play a torrent via the user's TorrServer instance (P2P) — no debrid.
    private func resolveViaP2P(_ entry: StreamEntry, _ all: [StreamEntry]) {
        guard let magnet = entry.stream.magnetURI
            ?? entry.stream.infoHash.map({ "magnet:?xt=urn:btih:\($0)" }) else {
            resolveError = "This source has no magnet link to hand to TorrServer."
            return
        }
        resolving = true
        Task {
            let result = await TorrServerService.resolve(
                magnet: magnet, settings: torrent.settings,
                season: viewModel.video?.season, episode: viewModel.video?.episode,
                // TorrServer's file id IS the torrent-relative index, so unlike
                // most debrid providers it can honour the addon's pick directly
                // instead of guessing by filename or size.
                fileIdx: entry.stream.fileIdx
            )
            resolving = false
            // Back popped the page during the P2P resolve — don't present the
            // player over a torn-down navigation entry.
            guard !isGone else { return }
            switch result {
            case .success(let url, let filename):
                let resolved = Stream(
                    name: entry.stream.name,
                    title: filename ?? entry.stream.title,
                    description: entry.stream.description,
                    url: url, infoHash: nil,
                    behaviorHints: entry.stream.behaviorHints
                )
                let resolvedEntry = StreamEntry(addonName: "P2P · \(entry.addonName)", stream: resolved)
                viewModel.recordLastLink(resolvedEntry)
                viewModel.stage("resolved — handing to player")
                onSelect(resolvedEntry, all)
            case .notConfigured:
                resolveError = "Turn on P2P and set a TorrServer URL in Settings → Integrations."
            case .failed(let message):
                resolveError = message
            }
        }
    }

    private var streamCountLabel: String {
        guard viewModel.totalAddons > 0 else { return "Searching addons" }
        return "Searching addons \(viewModel.finishedAddons)/\(viewModel.totalAddons)"
    }

    private var backdrop: some View {
        GeometryReader { geo in
            ZStack {
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(0.5)
                HeroGradient(background: theme.palette.background, fullBleed: true)
            }
        }
        .ignoresSafeArea()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.xs) {
            Text(viewModel.meta.name)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            if let video = viewModel.video {
                Text("\(video.seasonEpisodeCode)\(video.title.map { " • \($0)" } ?? "")")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            if viewModel.isLoading && !viewModel.groups.isEmpty {
                Text(streamCountLabel)
                    .font(.system(size: 21))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
    }

    private var streamList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                ForEach(viewModel.groups) { group in
                    VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                        // Level 1: addon.
                        Text(group.addonName.uppercased())
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.leading, 4)
                        ForEach(group.sections) { section in
                            VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                                // Level 2: resolution (hidden when untiered).
                                if !section.title.isEmpty {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 20, weight: .heavy))
                                        .foregroundStyle(theme.palette.secondary)
                                        .padding(.leading, 8)
                                        .padding(.top, 2)
                                }
                                ForEach(section.entries) { entry in
                                    sourceRow(entry)
                                }
                            }
                        }
                        // Every queried addon has a slot from the first frame,
                        // so an empty one has to say WHICH kind of empty it is:
                        // still working, failed, or answered with nothing.
                        if group.entries.isEmpty,
                           !viewModel.finishedAddonNames.contains(group.addonName) {
                            Text("Searching…")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.palette.textTertiary)
                                .padding(.leading, 8)
                        } else if group.entries.isEmpty,
                           let reason = viewModel.failedAddons[group.addonName] {
                            Text("Not working — \(reason)")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.palette.textSecondary)
                                .padding(.leading, 8)
                        }
                    }
                }
                // Installed addons that were NOT queried, with why — a broken
                // manifest or an id-prefix mismatch was previously invisible.
                ForEach(viewModel.skippedAddons, id: \.id) { skip in
                    VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                        Text(skip.name.uppercased())
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(theme.palette.textSecondary)
                            .padding(.leading, 4)
                        Text(skip.reason)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.palette.textSecondary)
                            .padding(.leading, 8)
                    }
                }
                // Every group is name-only (each queried addon replied with
                // nothing / timed out), so nothing above this is focusable.
                // With one stream addon installed the addon filter bar is
                // hidden too and the page had NO focusable view at all — a
                // Menu press then fell through to tvOS and suspended the app.
                // Keep the retry affordance on screen instead.
                if !viewModel.hasPlayableEntries {
                    retryButton
                        .frame(maxWidth: .infinity)
                        .padding(.top, OrivioSpacing.md)
                }
            }
            .padding(.vertical, OrivioSpacing.lg)
        }
        .onChange(of: viewModel.groups.count) { _, _ in
            // Only grab focus on the FIRST results arriving — otherwise changing
            // the addon filter (which rebuilds groups) would yank focus off the
            // chip you just picked and down into the list.
            //
            // `groups.first` can be an addon that returned NOTHING (a name-only
            // group), so ask for the first group that actually has rows —
            // otherwise the initial focus grab silently no-ops and the list
            // opens with focus nowhere.
            guard !didInitialFocus, focusedEntry == nil,
                  let first = viewModel.groups.first(where: { !$0.entries.isEmpty })?.entries.first
            else { return }
            focusedEntry = first.id
            didInitialFocus = true
        }
    }

    private func sourceRow(_ entry: StreamEntry) -> some View {
        Button {
            handleSelection(entry, viewModel.allEntries)
        } label: {
            StreamRowView(
                entry: entry,
                debridShortName: entry.stream.isTorrent ? debrid.resolverProvider?.shortName : nil,
                badges: streamBadges.badges(for: entry)
            )
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focusedEntry, equals: entry.id)
        // Hold Select → context actions.
        .contextMenu {
            if entry.stream.isPlayable, let streamURL = entry.stream.url,
               ExternalPlayers.isInfuseInstalled {
                Button {
                    ExternalPlayers.openInInfuse(urlString: streamURL)
                } label: {
                    Label("Play in Infuse", systemImage: "arrow.up.forward.app.fill")
                }
            }
        }
    }
}

struct StreamRowView: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    let entry: StreamEntry
    var debridShortName: String?
    /// Badger badge chips matched for this link (see StreamBadgeStore).
    var badges: [StreamBadge] = []

    var body: some View {
        HStack(spacing: OrivioSpacing.lg) {
            Image(systemName: entry.stream.isTorrent ? "bolt.horizontal.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(isFocused ? theme.palette.secondary : theme.palette.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if !entry.displayDetail.isEmpty {
                    Text(entry.displayDetail)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
                if !badges.isEmpty {
                    StreamBadgeChips(badges: badges)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Debrid-cached torrent → instant play; worth calling out since
            // cached links sort first.
            if entry.stream.isTorrent, entry.isInstant {
                MetaBadge(
                    text: "⚡︎ Cached",
                    tint: OrivioPrimitives.success.opacity(0.22),
                    textColor: OrivioPrimitives.success
                )
            }

            if let debridShortName {
                MetaBadge(
                    text: debridShortName,
                    tint: OrivioPrimitives.success.opacity(0.22),
                    textColor: OrivioPrimitives.success
                )
            }

            // Resolution over file size, stacked in the same badge form:
            //   [2160p]
            //   [55.3 GB]
            if entry.resolutionLabel != nil || entry.fileSizeLabel != nil {
                VStack(alignment: .trailing, spacing: 5) {
                    if let resolution = entry.resolutionLabel {
                        MetaBadge(
                            text: resolution,
                            tint: theme.palette.secondary.opacity(0.22),
                            textColor: theme.palette.secondary
                        )
                    }
                    if let size = entry.fileSizeLabel {
                        MetaBadge(
                            text: size,
                            tint: Color.white.opacity(0.12),
                            textColor: .white.opacity(0.85)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Opaque card fill: translucent rows over the panel over the
            // backdrop meant three blended layers per pixel during scroll.
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 2.5)
        )
        // No focus scale: scaling a row forces offscreen re-composition of
        // the whole card every focus move mid-scroll (stutter on the A10X);
        // the fill + ring change is plenty of focus affordance.
        // `isAppleTVTheme` is a retired always-false stub, so the token branch
        // never executed and every source row settled on the literal instead.
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

/// A pill in the addon filter bar. Fills with the accent when it's the active
/// filter; focus adds the ring, matching every other Orivio control.
private struct AddonFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddonFilterChipLabel(title: title, selected: selected)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct AddonFilterChipLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, OrivioSpacing.sm)
            .background(Capsule().fill(background))
            .overlay(
                Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }

    private var foreground: Color {
        if isFocused { return theme.palette.onSecondary }
        if selected { return theme.palette.secondary }
        return theme.palette.textSecondary
    }

    private var background: Color {
        if isFocused { return theme.palette.secondary }
        if selected { return theme.palette.secondary.opacity(0.22) }
        return theme.palette.backgroundCard.opacity(0.85)
    }
}


/// The title's loading screen, shown while the Auto Link Selector picks a
/// source. Deliberately a near-copy of `PlayerLoadingOverlay`: the player puts
/// that up the instant this view hands off, so matching it means the source
/// sweep and the stream opening read as one screen that never changed.
private struct AutoLinkLoadingScreen: View {
    let meta: MetaItem
    let status: String
    @State private var revealed = false

    private var hasLogo: Bool {
        if let logo = meta.logo { return !logo.isEmpty }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Nothing else here is focusable, and this screen owns the whole
            // view for the length of an Auto Link Selector sweep (up to the 45s
            // stream deadline). With NOTHING focused a Menu press falls through
            // to tvOS and suspends the app — the same reason OrivioLoadingView
            // takes `holdsFocus`.
            FocusAnchor()
            RemoteImage(url: meta.background ?? meta.poster)
                .ignoresSafeArea()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.30), location: 0),
                    .init(color: .black.opacity(0.60), location: 0.35),
                    .init(color: .black.opacity(0.80), location: 0.70),
                    .init(color: .black.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: OrivioSpacing.xxl) {
                Group {
                    if hasLogo {
                        RemoteImage(url: meta.logo, contentMode: .fit)
                            .frame(width: 480, height: 270)
                    } else {
                        Text(meta.name)
                            .font(.system(size: 68, weight: .heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .opacity(revealed ? 1 : 0)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.7)
                    .opacity(revealed ? 1 : 0)

                Text(status)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(revealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: status)
            }
            .padding(.horizontal, OrivioSpacing.huge)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.1)) { revealed = true } }
    }
}
