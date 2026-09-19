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
        // Every stage of Play → picture, on the same clock as the browsing
        // before it and the player after it. This is the seam the two probes
        // used to meet at with a gap in the middle.
        AppProbe.data(String(format: "play +%.2fs  %@",
                             Date().timeIntervalSince(openedAt), name))
    }

    private func effectiveStreamID() async -> String {
        if let resolvedID { return resolvedID }
        var showID = meta.id
        if showID.hasPrefix("tmdb:"), let n = Int(showID.dropFirst("tmdb:".count)),
           // `!isSeries`, not `type != "series"`: a meta typed "tv" went down
           // TMDB's movie endpoint (disjoint id space) and never resolved.
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
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
    /// after the addon sweep, so re-curate). Deduped by URL, or by info hash
    /// for torrent results — a magnet result has no URL, and keying on the
    /// URL alone silently dropped every one of them.
    func addPluginStreams(_ entries: [StreamEntry]) {
        guard !entries.isEmpty else { return }
        func identity(_ stream: Stream) -> String? {
            if let url = stream.url { return url }
            if let hash = stream.infoHash { return "hash:" + hash.lowercased() }
            return nil
        }
        let existing = Set(pool.compactMap { identity($0.stream) })
        let fresh = entries.filter { entry in
            // Same admission rule as the addon sweep: playable, a torrent
            // (which the debrid / TorrServer path can resolve), or external.
            guard entry.stream.isPlayable || entry.stream.isTorrent || entry.stream.isExternal,
                  let key = identity(entry.stream) else { return false }
            return !existing.contains(key)
        }
        guard !fresh.isEmpty else { return }
        pool.append(contentsOf: fresh)
        rebuildGroups()
        // Plugin scrapers are part of the early Auto-Link race too. Addon
        // batches trigger an evaluation as they answer; scraper batches never
        // did — so on a plugins-only setup (qink and friends: direct links,
        // no debrid, no stream addons) the selector could only ever act via
        // the end-of-sweep path, which used to race this very task.
        if let prefs = autoLinkPrefs { evaluateEarlyAutoLink(prefs) }
    }

    /// Addons whose stream request has returned (either way).
    @Published private(set) var finishedAddonNames: Set<String> = []
    private var sweepStarted = Date()
    /// Set by the view while the Auto Link Selector is armed, so the sweep can
    /// hand back a pick without waiting for every addon.
    var autoLinkPrefs: AutoLinkPreferences?
    /// Enabled plugin scrapers still being swept — so a PREFERRED addon that
    /// is actually a scraper (qink and friends) counts as outstanding during
    /// the patience window instead of the early pick firing an addon link
    /// past it. Set by the view when the plugin task starts, cleared when it
    /// finishes either way.
    var pendingPluginNames: [String] = []
    var onEarlyAutoLink: ((StreamEntry) -> Void)?
    private var earlyPickFired = false
    /// Longest we will hold out for a preferred addon that hasn't answered.
    private static let preferredAddonWait: TimeInterval = 6
    /// Longest we will keep collecting before picking with no addon preference
    /// left to honour.
    ///
    /// Without one, the early pick fired on the FIRST addon to answer, so with
    /// several installed the selector's choice was decided by network race
    /// order: whoever replied first got to pick, and a cached remux arriving
    /// 200ms later never entered the running. This is the settling time that
    /// buys — short enough to stay imperceptible next to the addon sweep it
    /// overlaps, and cut short the moment the field can no longer improve
    /// (every addon answered, or a link that plays now at the best resolution
    /// this box accepts is already in hand).
    private static let fieldSettleWait: TimeInterval = 2

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
    /// can't hold up the whole thing. With no addon left to wait for, take the
    /// best of the whole field once it has settled (`fieldSettleWait`).
    func earlyAutoLinkPick(_ prefs: AutoLinkPreferences) -> StreamEntry? {
        let pool = autoLinkPool(prefs)
        let elapsed = Date().timeIntervalSince(sweepStarted)

        /// Whether an addon can still change the answer: it has to be one we
        /// queried at all (a Stremio addon OR a plugin scraper), and not yet
        /// returned.
        func outstanding(_ name: String) -> Bool {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return false }
            if pendingPluginNames.contains(where: { $0.lowercased().contains(q) }) { return true }
            guard queriedAddonNames.contains(where: { $0.lowercased().contains(q) }) else { return false }
            return !finishedAddonNames.contains { $0.lowercased().contains(q) }
        }
        func firstFrom(_ name: String) -> StreamEntry? {
            let q = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return nil }
            return pool.first { $0.addonName.lowercased().contains(q) }
        }

        // Patience only means something while a specific addon we are waiting
        // FOR can still answer. It used to be spent on the clock alone, so once
        // the preferred and secondary addons had both replied with nothing the
        // pick still sat out the rest of the 6s for addons no preference names.
        let patient = elapsed < Self.preferredAddonWait

        if let hit = firstFrom(prefs.preferredAddon) { return hit }
        if patient, outstanding(prefs.preferredAddon) { return nil }
        if let hit = firstFrom(prefs.secondaryAddon) { return hit }
        if patient, outstanding(prefs.secondaryAddon) { return nil }

        // No addon preference left to honour: this is now a straight "best
        // available" choice, and the answer keeps improving while addons are
        // still arriving. Four ways to stop collecting, cheapest first — the
        // settle window is the CAP, not the normal wait, so the usual play is
        // still decided in the first few hundred milliseconds.
        guard let best = pool.first else { return nil }
        if finishedAddons >= totalAddons { return best }        // nothing more can arrive
        if elapsed >= Self.fieldSettleWait { return best }      // waited long enough
        if playsNow(best) {
            // Unbeatable: plays now, at the best resolution this box will take.
            if let top = topAllowedTier(prefs),
               ResolutionTier.from(resolutionLabel: best.resolutionLabel) == top { return best }
            // Most of the field is in and what we hold plays now — the
            // stragglers are not worth holding the screen for.
            if finishedAddons * 2 >= totalAddons { return best }
        }
        return nil
    }

    /// Evaluate the early pick and fire it at most once per sweep.
    ///
    /// Called both when an addon answers AND from a deadline timer, because the
    /// per-batch path can only run when an addon answers — which made
    /// `preferredAddonWait` really mean "6s OR the next addon to reply,
    /// whichever is LATER". One slow addon stretched a 6s window to the full
    /// 45s stream timeout.
    func evaluateEarlyAutoLink(_ prefs: AutoLinkPreferences) {
        // Gate on the RAW pool, not on `allEntries`: the latter reads through
        // `groups`, which the sweep only re-flushes every 400ms, so a batch
        // landing inside that window was turned away for having "no entries"
        // while holding the first links of the whole sweep — and turned away
        // before the rebuild that would have fixed it.
        guard !earlyPickFired, !pool.isEmpty else { return }
        rebuildGroups()
        guard let pick = earlyAutoLinkPick(prefs) else { return }
        earlyPickFired = true
        stage("auto-link picked \(pick.addonName) — \(pick.displayName)")
        onEarlyAutoLink?(pick)
    }

    /// Cached title verdicts, keyed by entry id. `evaluateEarlyAutoLink` runs
    /// once per addon batch and re-walks the whole pool each time, so the regex
    /// work behind a verdict is done once per link per sweep, not once per pass.
    private var titleVerdicts: [UUID: StreamTitleVerdict] = [:]

    /// `Stream.isCached` is regex work over three strings, and the auto-pick
    /// ranks the whole pool again on every addon batch. Memoized per entry for
    /// the same reason as `titleVerdicts`.
    private var cachedFlags: [UUID: Bool] = [:]

    /// Does this link play RIGHT NOW? Strict `isCached`, not `isInstant`: a
    /// debrid addon hands back a playable URL for uncached results too (it
    /// downloads on access), and an auto-pick that lands on one is exactly the
    /// wait the selector exists to avoid.
    private func playsNow(_ entry: StreamEntry) -> Bool {
        if let cached = cachedFlags[entry.id] { return cached }
        let cached = entry.stream.isCached
        cachedFlags[entry.id] = cached
        return cached
    }

    /// Rank the whole field for an automatic pick.
    ///
    /// The visible page is grouped by ADDON in INSTALLED order and ranked only
    /// within a group, so its first entry is the best link of whichever addon
    /// happens to sit first — not the best link available. Every automatic path
    /// took that first entry and the comments called it "already sorted
    /// best-first", which it is only inside one addon block: with two addons
    /// installed the selector would take a 720p from the first over a cached
    /// 2160p remux from the second, purely on install order.
    ///
    /// The order, most significant first:
    ///  1. Plays now. An auto-pick that has to wait on a debrid download is the
    ///     failure this feature exists to prevent, and it is the same principle
    ///     `qualityScore` already encodes with its dominant instant bonus.
    ///     Neutral when nothing is cached (a TorrServer-only setup, where every
    ///     link is a torrent), so those setups rank on quality as before — and
    ///     it does NOT lift a 480p link over a higher-resolution one, which is
    ///     the one trade where waiting is clearly the better answer (an
    ///     unlabelled link still counts, since plenty of good debrid links
    ///     carry no resolution at all).
    ///  2. Resolution, in the BOX's own order (`ResolutionTier.displayOrder` —
    ///     on an Apple TV HD a 2160p link is the worst pick, not the best).
    ///  3. `sourceScore`: release ladder, codec, HDR, audio, seeders, size.
    ///     Cached still wins inside a tier, SD included — its +1000 is there.
    ///  4. The page's own order, so equals stay in a stable, familiar sequence.
    private func autoRanked(_ entries: [StreamEntry]) -> [StreamEntry] {
        guard entries.count > 1 else { return entries }
        let tierRank = Dictionary(
            uniqueKeysWithValues: ResolutionTier.displayOrder.enumerated().map { ($1, $0) }
        )
        // Keys computed ONCE per entry rather than on every comparison — a
        // comparator that calls `playsNow` does O(n log n) dictionary lookups
        // for what is O(n) work.
        let keyed = entries.enumerated().map { offset, entry -> (entry: StreamEntry, now: Bool, tier: Int, score: Int, offset: Int) in
            let tier = ResolutionTier.from(resolutionLabel: entry.resolutionLabel)
            return (entry: entry,
                    now: playsNow(entry) && tier != .sd480,
                    tier: tierRank[tier] ?? .max,
                    score: entry.sourceScore,
                    offset: offset)
        }
        return keyed.sorted { l, r in
            if l.now != r.now { return l.now }
            if l.tier != r.tier { return l.tier < r.tier }
            if l.score != r.score { return l.score > r.score }
            return l.offset < r.offset
        }.map(\.entry)
    }

    /// The best resolution an auto-pick can hope for here: the first tier in
    /// the box's own display order that still clears the profile's minimum.
    /// Nothing beats it, so a link that reaches it (and plays now) is worth
    /// taking immediately instead of waiting out the settle window below.
    private func topAllowedTier(_ prefs: AutoLinkPreferences) -> ResolutionTier? {
        let minTier = prefs.minResolution.isEmpty ? nil
            : ResolutionTier.from(resolutionLabel: prefs.minResolution)
        return ResolutionTier.displayOrder.first { tier in
            guard tier != .other else { return false }   // unknown is never "the best"
            guard let minTier else { return true }
            return tier.rawValue <= minTier.rawValue     // lower rawValue = higher resolution
        }
    }

    /// Is this link really the title (and episode) that was asked for?
    /// See `StreamTitleMatcher` — only positive evidence of a MISMATCH rejects.
    func titleVerdict(_ entry: StreamEntry) -> StreamTitleVerdict {
        if let cached = titleVerdicts[entry.id] { return cached }
        let verdict = StreamTitleMatcher.verdict(
            text: StreamTitleMatcher.haystack(
                displayName: entry.displayName,
                displayDetail: entry.displayDetail,
                filename: entry.stream.behaviorHints?.filename
            ),
            title: meta.name,
            year: StreamTitleMatcher.year(fromReleaseInfo: meta.releaseInfo),
            season: video?.season,
            episode: video?.episode,
            ignoring: entry.addonName
        )
        titleVerdicts[entry.id] = verdict
        return verdict
    }

    /// Drop links that name a DIFFERENT title/episode, then float the ones that
    /// positively name the right one above the ones that say nothing either way.
    /// Order within each band is preserved, so every existing rank (resolution,
    /// size, cached, addon preference) still decides between equals.
    ///
    /// Never returns empty when given a non-empty list: if every link looks
    /// wrong, the matcher is more likely to be misreading an unusual naming
    /// convention than the entire source list is to be junk, and refusing to
    /// play anything is the worse failure.
    private func titleFiltered(_ entries: [StreamEntry]) -> [StreamEntry] {
        var confirmed: [StreamEntry] = []
        var unknown: [StreamEntry] = []
        for entry in entries {
            switch titleVerdict(entry) {
            case .confirmed: confirmed.append(entry)
            case .unknown: unknown.append(entry)
            case .rejected: break
            }
        }
        let kept = confirmed + unknown
        return kept.isEmpty ? entries : kept
    }

    /// The entries a profile's Auto Link prefs allow, best-first.
    private func autoLinkPool(_ prefs: AutoLinkPreferences) -> [StreamEntry] {
        let minTier = prefs.minResolution.isEmpty ? nil
            : ResolutionTier.from(resolutionLabel: prefs.minResolution)
        let maxSizeGB = AutoLinkPreferences.sanitizedMaxSizeGB(prefs.maxSizeGB)
        let maxBytes = maxSizeGB > 0 ? Int64(maxSizeGB * 1_073_741_824) : nil
        let pool = allEntries.filter { entry in
            // Never auto-pick an external hand-off (a DMM "cast" entry): the
            // Apple TV can't open it, so the pick died on an alert — with
            // playable links sitting right there. `bestResumeMatch` has
            // always excluded these; the selector and the global auto-play
            // (below) must too. Manual taps still offer them.
            if entry.stream.isExternal { return false }
            // An addon that answered a byte-range request with an HTTP error
            // cannot be cached OR seeked — the proxy fails open so the film
            // plays, and the cache, the scrub previews and seeking are all dead
            // for the rest of the session with nothing on screen to say so.
            if Stream.RangeRefusingAddons.contains(entry.addonName) { return false }
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
        guard !rejected.isEmpty else { return autoRanked(titleFiltered(pool)) }
        let survivors = pool.filter { !rejected.contains($0.rejectionKey) }
        // If avoiding them leaves nothing, the grudge is worse than the link:
        // play the best match rather than dropping to the manual list.
        return autoRanked(titleFiltered(survivors.isEmpty ? pool : survivors))
    }

    /// Best source for a profile's Auto Link Selector, once the sweep is done:
    /// the pool filtered by the profile's cached-only / min-resolution /
    /// max-size prefs and ranked across every addon (`autoRanked`), preferring
    /// the chosen addon, then the secondary, then the best remaining link.
    /// Unknown resolution/size never disqualifies a link (missing metadata
    /// shouldn't hide a possibly-good source).
    ///
    /// `excluding`: rejection keys of links an auto-pick already tried and
    /// failed to resolve this visit, so the retry moves ON instead of
    /// re-serving the same dead link.
    func autoLinkPick(_ prefs: AutoLinkPreferences, excluding: Set<String> = []) -> StreamEntry? {
        let pool = autoLinkPool(prefs).filter { !excluding.contains($0.rejectionKey) }
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

    /// Best source to auto-play, honoring cached-only and an optional
    /// case-insensitive title regex. Ranked over the whole field like the
    /// selector (see `autoRanked`) — "Auto-play best source" used to mean
    /// "auto-play the first installed addon's best source".
    func autoPlayPick(cachedOnly: Bool, regex: String, excluding: Set<String> = []) -> StreamEntry? {
        let trimmed = regex.trimmingCharacters(in: .whitespaces)
        let re = trimmed.isEmpty ? nil
            : try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
        // Same name check the Auto Link Selector uses: an auto-play that
        // starts the wrong episode is worse than one that starts nothing.
        return autoRanked(titleFiltered(allEntries)).first { entry in
            if entry.stream.isExternal { return false }   // see autoLinkPool
            if Stream.RangeRefusingAddons.contains(entry.addonName) { return false }
            if excluding.contains(entry.rejectionKey) { return false }
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
        //
        // NOR INTO AN ADDON THAT HAS ALREADY PROVED IT REFUSES BYTE RANGES.
        // The auto-pick pool has excluded those for a while; this path did not,
        // and this is the path a Continue Watching resume takes — which is how
        // the same cast endpoint was landed on three times in one evening after
        // being blacklisted the first time. It plays and nothing else works:
        // no caching, no seeking, no scrub preview.
        //
        // Ranked, so the "base rank" the tiebreak below falls back to is the
        // best link of the FIELD rather than of the first installed addon.
        let candidates = autoRanked(titleFiltered(allEntries.filter {
            !$0.stream.isExternal && !Stream.RangeRefusingAddons.contains($0.addonName)
        }))
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
        // Candidates are ranked best-first; pick the highest signature match,
        // breaking ties toward that existing (better) base rank.
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
        // Entry ids are regenerated by the sweep below, so these caches would
        // otherwise grow a dead entry per link on every retry.
        titleVerdicts = [:]
        cachedFlags = [:]
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
    func load(addonManager: AddonManager, debridEnabled: Bool, perTier: Int, filtersEnabled: Bool = true, forceRefresh: Bool = false, streamTimeout: TimeInterval = 45) async {
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
        AppProbe.data("sources for \(fetchID): asking \(queriedAddonNames.count)"
                      + " [\(queriedAddonNames.joined(separator: ", "))]"
                      + (skipped.isEmpty ? ""
                         : "  skipped \(skipped.count): "
                           + skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")))
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
            failedAddons = [:]   // stale "Not working" diagnostics from a previous sweep
            // Every queried addon is done on this path — the ones with no
            // links otherwise showed "Searching…" forever, since that label
            // keys off this set.
            finishedAddonNames = Set(queriedAddonNames)
            rebuildGroups()
            isLoading = false
            return
        }

        failedAddons = [:]
        finishedAddonNames = []
        sweepStarted = Date()
        // The sweep below APPENDS to `pool` and INCREMENTS `finishedAddons`,
        // so both have to start from zero — `reload()` cleared them and this
        // path did not. Re-entering Sources (play a link, press Back) ran a
        // second sweep on top of the first: every source from an addon that
        // had already answered was listed TWICE, `finishedAddons` counted past
        // `totalAddons` so the header read "9/6", and the auto-link settle
        // window was skipped because its `finished >= total` guard was already
        // true on the first batch.
        pool = []
        finishedAddons = 0
        // Entry ids are regenerated below, so these caches would otherwise
        // keep a dead entry per link from the previous sweep.
        titleVerdicts = [:]
        cachedFlags = [:]
        // Reset per sweep, or a refresh after an early pick could never fire one.
        earlyPickFired = false
        // The deadlines that `fieldSettleWait` and `preferredAddonWait` were
        // always supposed to be. BOTH need a timer: the per-batch path only
        // runs when an addon answers, so a window that expires between two
        // replies would otherwise mean "when the window is up OR the next
        // addon replies, whichever is LATER" — one slow addon stretching a 2s
        // settle to the full 45s stream timeout.
        var autoLinkDeadline: Task<Void, Never>?
        if let prefs = autoLinkPrefs {
            autoLinkDeadline = Task { [weak self] in
                var waited: TimeInterval = 0
                for deadline in [Self.fieldSettleWait, Self.preferredAddonWait] {
                    let remaining = deadline - waited
                    guard remaining > 0 else { continue }
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    waited = deadline
                    self?.evaluateEarlyAutoLink(prefs)
                }
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
                        let streams = try await StremioAPI.streams(addon: addon, type: meta.type, id: fetchID, timeout: streamTimeout)
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
                        AppProbe.warn("sources", "\(addon.manifest.name) — \(error)")
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

    /// Whether an automatic flow has taken the page over and the source list
    /// should stay hidden behind the loading screen.
    ///
    /// DERIVED, not a plain @State that `.task` switches on. `.task` runs after
    /// the first frame is on screen, so a stored flag that starts `false` meant
    /// every auto-linked Play rendered the source page once — the list flashing
    /// past for a frame before the loading screen replaced it. Reading the
    /// armed state during `body` instead means the loading screen IS the first
    /// frame and the list is never built at all.
    ///
    /// The latch is the override the auto flows write when they are done with
    /// the page (nothing matched, resolve failed): `nil` means "still whatever
    /// the settings say".
    private var autoLinkResolving: Bool { autoLinkResolvingLatch ?? autoLinkArmed }

    /// Set once an automatic flow has finished with the loading screen; until
    /// then `autoLinkResolving` follows `autoLinkArmed`.
    @State private var autoLinkResolvingLatch: Bool?

    /// An automatic pick fired and this page has asked to be popped. The pop is
    /// deliberately deferred to a runloop turn AFTER the player closes (see
    /// `onAutoDismiss`), and for that one turn this view is on screen again —
    /// which used to reveal the source list on the way OUT of an auto-played
    /// title, the same page the selector exists to skip. Stay covered until the
    /// pop lands.
    @State private var didAutoDismiss = false

    /// Request the deferred pop, and cover the page until it happens.
    private func autoDismiss() {
        didAutoDismiss = true
        onAutoDismiss()
    }

    /// Do the settings arm an automatic pick for this visit? Same condition
    /// `.task` used to compute, hoisted so the FIRST frame can ask it too.
    ///
    /// A RESUME only qualifies when some automatic selection is actually
    /// switched on.
    ///
    /// Deliberately NOT gated on `didAutoAct`. That term belongs to the
    /// come-back-from-the-player case, which the latch handles below — folding
    /// it in here would flip `autoLinkResolving` to false the instant a pick
    /// fires, which is precisely when the rest of the flow reads it to mean
    /// "the loading screen is up": the deferred pop after a reused last link
    /// and the dead-link failover in `autoAdvance` both hang off it.
    ///
    /// "Auto-play best source" counts on EVERY visit, not just a resume. It
    /// used to be `resumeAutoPlay &&`, but the block that acts on it (further
    /// down in `.task`) carries no such condition — so with the selector off
    /// and auto-play on, pressing Play built the full source list, showed it
    /// for the length of the addon sweep, and then started playing anyway.
    /// The two must agree or the page shows for exactly as long as the
    /// decision takes.
    private var autoLinkArmed: Bool {
        guard !forceManual else { return false }
        if profiles.activeAutoLink.enabled { return true }
        return playerSettings.settings.autoPlaySourceEnabled
    }

    @State private var resolving = false
    /// The in-flight debrid/P2P resolve, so Back can CANCEL it. Without this
    /// a hung provider left the viewer parked on the resolve spinner with no
    /// way to try another source — the only exit was popping the whole page
    /// and re-running the entire addon sweep.
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolveError: String?
    /// Links an auto-pick already tried and failed to RESOLVE this visit —
    /// the retry pool excludes them so a failed pick moves on to the next
    /// candidate instead of alerting and dropping to the manual list.
    @State private var autoTriedKeys: Set<String> = []
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
    @State private var pluginsSwept = false
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
            // Popped-but-still-on-screen (see `didAutoDismiss`): a bare cover,
            // NOT the loading screen — its spinner and "Finding the best
            // source" have already faded in by now, so reusing it here would
            // flash a search that finished minutes ago onto the way out.
            // …but NOT while a resolve is still running. An auto-picked
            // torrent asks debrid for a link before the player can open, which
            // is seconds of work, and the bare cover says nothing about it —
            // the loading screen below carries "Resolving via Real-Debrid".
            if didAutoDismiss, !resolving {
                AutoPickHandoffScreen(meta: viewModel.meta)
            // Auto Link Selector armed: the source page is an implementation
            // detail the viewer never asked to see. Show the title's own
            // loading screen — the SAME one the player is about to put up — and
            // let the addon sweep finish behind it, so pressing Play reads as
            // one continuous "opening the movie" rather than a detour through a
            // list that flashes past.
            } else if autoLinkResolving {
                AutoLinkLoadingScreen(
                    meta: viewModel.meta,
                    status: resolving
                        ? "Resolving via \(debrid.resolverProvider?.displayName ?? (torrent.settings.isConfigured ? "TorrServer" : "debrid"))"
                        : "Finding the best source"
                )
                .transition(.opacity)
                // Back during a slow sweep/resolve = "let me pick myself":
                // cancel whatever is in flight, disarm further auto-picks
                // this visit, and reveal the manual list. This screen owns
                // the whole view for up to the 45s stream deadline, and
                // Back used to pop clear off the page — there was no way to
                // reach the list a stuck auto-select was sitting on top of.
                .onExitCommand {
                    cancelResolve()
                    didAutoAct = true
                    autoLinkResolvingLatch = false
                }
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
                    VStack(spacing: OrivioSpacing.md) {
                        // holdsFocus so Menu lands on the `.onExitCommand`
                        // below (cancel) instead of on whatever list row is
                        // buried under this dim — a press there could fire a
                        // SECOND source while one is already resolving.
                        OrivioLoadingView(
                            label: "Resolving via \(debrid.resolverProvider?.displayName ?? (torrent.settings.isConfigured ? "TorrServer" : "debrid"))",
                            holdsFocus: true
                        )
                        .frame(maxHeight: 220)
                        Text("Press Back to cancel and pick another source")
                            .font(.system(size: 21))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
                // Back CANCELS the resolve and returns to the list. It used
                // to bubble up and pop the whole page — a hung provider cost
                // the entire sweep.
                .onExitCommand { cancelResolve() }
            }
            }
        }
        .animation(.easeOut(duration: 0.2), value: autoLinkResolving)
        .task {
            // Waiting on the deferred pop: this task re-runs when the player
            // cover comes down, and a page one runloop turn from being removed
            // has no business standing the whole addon sweep back up. The sleep
            // is a safety net only — if the pop never lands (nothing to pop on
            // this stack), uncover the list rather than strand the viewer on a
            // black screen.
            if didAutoDismiss {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !isGone else { return }
                autoLinkResolvingLatch = false   // uncover, or nothing ever would
                didAutoDismiss = false
                return
            }
            let s = playerSettings.settings
            viewModel.streamFilters = s.streamFilterOptions
            // A RESUME only qualifies when some automatic selection is actually
            // switched on. It used to qualify unconditionally, so a Continue
            // Watching row opened onto "Finding the best source…" and then
            // played something the viewer never picked, with both auto-select
            // settings off.
            let autoSelects = profiles.activeAutoLink.enabled || s.autoPlaySourceEnabled
            // Fresh visit: hand the loading screen back to `autoLinkArmed`.
            // AFTER a pick has fired, force the list instead: this task re-runs
            // when the player cover comes down (`onDisappear`/`onAppear` on the
            // view beneath it), and re-raising the loading screen then left the
            // page stuck on "Finding the best source…" — nothing picks again
            // (`didAutoAct` is @State) and the safety net below cannot clear it.
            autoLinkResolvingLatch = didAutoAct ? false : nil
            viewModel.openedAt = Date()
            viewModel.stage("sources page opened")
            autoTriedKeys = []   // fresh visit, fresh failover budget

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
                    autoDismiss()
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
                    filtersEnabled: s.sourceFiltersEnabled,
                    streamTimeout: TimeInterval(s.sourceSearchTimeoutSeconds)
                )
            }
            sweepTasks.append(loadTask)
            // Plugin scrapers run alongside the addon sweep (they want a TMDB id).
            // Once per page: the re-run after the player cover comes down must
            // not stand the whole JS scraper fleet up again. Held in a local
            // too — the auto-select decision below must be able to WAIT for it.
            var pluginTask: Task<Void, Never>?
            if !plugins.enabledScrapers.isEmpty, !pluginsSwept {
                viewModel.pendingPluginNames = plugins.enabledScrapers.map(\.name)
                let task = Task {
                    // However this sweep ends, the scrapers are no longer
                    // outstanding for the early pick's patience window.
                    defer { viewModel.pendingPluginNames = [] }
                    guard let (tmdbID, isMovie) = await TMDBService.resolveTMDBID(
                        from: viewModel.meta.id, type: viewModel.meta.type
                    ) else { return }
                    let entries = await plugins.streams(
                        tmdbID: String(tmdbID), mediaType: isMovie ? "movie" : "tv",
                        season: viewModel.video?.season, episode: viewModel.video?.episode
                    )
                    guard !Task.isCancelled, !isGone else { return }
                    viewModel.addPluginStreams(entries)
                    pluginsSwept = true
                }
                pluginTask = task
                sweepTasks.append(task)
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
                if autoLinkResolving { autoDismiss() }
                return
            }
            await loadTask.value
            // Back-during-load guard (see above): bail before any auto-act.
            guard !Task.isCancelled, !isGone else { return }

            // Plugin scrapers are sources like any other, but their sweep is a
            // SEPARATE task the auto-select decision used to race: on a
            // plugins-only setup (qink and friends — direct links, no debrid,
            // no stream addons) the addon sweep finished first with nothing,
            // the pick came up empty, and the loading screen dropped to the
            // manual list while the scraper was still working. Only reached
            // when nothing has acted yet — an addon match good enough for the
            // early pick has already fired and skips this wait entirely.
            if !didAutoAct, autoSelects { await pluginTask?.value }
            guard !Task.isCancelled, !isGone else { return }

            // Resume from Continue Watching: re-scrape done, now auto-play the
            // link that best matches the format last watched (fresh connection,
            // so expired debrid/Comet links don't fail).
            //
            // GATED ON THE AUTO-SELECT SETTINGS, which it never used to be.
            // This block ran whenever the Auto Link Selector was OFF, so
            // turning the selector off did not stop links being chosen for you
            // on a resume — it only changed which algorithm chose them, which
            // is the opposite of what the switch says. The global "Auto-play
            // best source" was ignored here as well.
            //
            // The three ways a link can now be picked without asking, and only
            // these: the Auto Link Selector (its own block below, which also
            // covers resumes), the global auto-play (further below), and this
            // format match — which is the better answer of the three for a
            // resume, so it stays first when either switch is on. With both
            // off nothing is picked and the source list appears, for a resume
            // exactly as for any other play.
            if !didAutoAct, !forceManual, resumeAutoPlay, autoSelects, !armedAutoLink.enabled {
                if let pick = viewModel.bestResumeMatch(signature: resumeSignature) {
                    didAutoAct = true
                    handleSelection(pick, viewModel.allEntries)
                    autoDismiss()
                } else {
                    autoLinkResolvingLatch = false   // nothing found → reveal the list
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
                    autoDismiss()
                } else {
                    // No source matched the prefs — reveal the list as a manual
                    // fallback instead of leaving the loading screen up.
                    autoLinkResolvingLatch = false
                }
            }

            // Auto-play best source: once the sweep is done, start the best
            // matching link without waiting for a manual pick.
            //
            // Dismisses like every other automatic pick. It used not to, which
            // is what made the source page reappear on the way OUT of an
            // auto-played title: the list was revealed behind the player and
            // was the first thing Back landed on.
            if !didAutoAct, !forceManual, s.autoPlaySourceEnabled,
               let best = viewModel.autoPlayPick(
                   cachedOnly: s.autoPlaySourceCachedOnly, regex: s.autoPlaySourceRegex
               ) {
                didAutoAct = true
                handleSelection(best, viewModel.allEntries)
                autoDismiss()
            }

            // Safety net: if we opened in auto-loading mode but nothing acted,
            // drop the loading screen so the user isn't stuck on it.
            if autoLinkResolving && !didAutoAct { autoLinkResolvingLatch = false }
        }
        // The player cover triggers `onDisappear` on this view too, so the
        // latch below must be RESET on every appearance — without it every
        // selection after backing out of the player was a silent no-op for
        // the rest of the session (CloudLibraryView carries the same fix).
        .onAppear { isGone = false }
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
            set: { if !$0 { resolveError = nil; autoLinkResolvingLatch = false } }
        )) {
            Button("OK", role: .cancel) {
                resolveError = nil
                // If an auto-pick (resume / Auto Link) failed to resolve, drop
                // the loading screen so the manual list is reachable — without
                // this, dismissing the alert stranded the user on
                // "Finding the best source…" forever.
                autoLinkResolvingLatch = false
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

    /// How many dead links one automatic flow will resolve through before
    /// giving up and showing the manual list.
    ///
    /// The point is to EXHAUST the qualifying links rather than sample them:
    /// `autoLinkPick` walks the preferred addon's links first, then the
    /// secondary addon's, then anything else, and the pool it draws from has
    /// already dropped everything below the minimum resolution (and over the
    /// size cap, and uncached when cached-only is set). So "keep going until
    /// nothing qualifies" is simply "keep going until the pool runs dry", and
    /// this ceiling exists only so a title whose links are ALL dead can't
    /// grind for minutes — each attempt is a debrid resolve over the network.
    private static let autoFailoverLimit = 25

    /// After an AUTO-picked link fails to resolve, move on to the next
    /// candidate instead of surfacing the alert — "couldn't resolve" over the
    /// 'Finding the best source' screen, with playable alternates in hand,
    /// was the selector giving up one link too early (and dismissing the
    /// alert then dumped the viewer onto the manual list). Returns true when
    /// another candidate was dispatched; false → let the caller alert as a
    /// last resort.
    ///
    /// The old ceiling here was FOUR, which on a well-seeded title meant the
    /// preferred addon was abandoned while it still had a dozen good links
    /// left — the exact "it dropped to the backup addon too early" report.
    private func autoAdvance(after entry: StreamEntry, _ all: [StreamEntry]) -> Bool {
        // Only while an automatic flow is in charge; a manually tapped link
        // keeps its error alert.
        guard autoLinkResolving else { return false }
        autoTriedKeys.insert(entry.rejectionKey)
        guard autoTriedKeys.count < Self.autoFailoverLimit else {
            viewModel.stage("gave up after \(autoTriedKeys.count) dead links")
            return false
        }
        let prefs = profiles.activeAutoLink
        let next = prefs.enabled
            ? viewModel.autoLinkPick(prefs, excluding: autoTriedKeys)
            : viewModel.autoPlayPick(
                cachedOnly: playerSettings.settings.autoPlaySourceCachedOnly,
                regex: playerSettings.settings.autoPlaySourceRegex,
                excluding: autoTriedKeys
            )
        guard let next else { return false }
        // Name the addon AND the attempt: walking 15 links of one addon looks
        // identical to a hang from the sofa otherwise.
        let sameAddon = next.addonName == entry.addonName
        viewModel.stage(sameAddon
            ? "link \(autoTriedKeys.count) from \(next.addonName) failed — trying the next one"
            : "\(entry.addonName) is out of links — switching to \(next.addonName)")
        handleSelection(next, all)
        return true
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
        resolveTask?.cancel()
        resolveTask = Task {
            // Try every configured debrid, preferred first — a torrent the
            // preferred provider doesn't have cached still resolves via the
            // others (TorBox / RD / PM / AD).
            //
            // Under a DEADLINE. The chain is unbounded by construction: each
            // provider is up to ~9 sequential requests (30s timeout each)
            // plus poll sleeps, × every configured provider — a bad candidate
            // could grind for minutes before the auto flow's `autoAdvance`
            // even got to try the NEXT link ("auto link selector can take a
            // long time"). A timeout is reported as .failed, so the auto
            // flow advances to another candidate and a manual pick shows the
            // normal alert. Tighter when auto-select is driving: its promise
            // is "plays now", and 20s of grinding is already a broken one.
            let stream = entry.stream
            let season = viewModel.video?.season
            let episode = viewModel.video?.episode
            let providers = await debrid.resolversRefreshingIfNeeded()
            let budget: TimeInterval = autoLinkResolving ? 20 : 60
            let outcome = await Self.withDeadline(seconds: budget) {
                await DebridService.resolveAcross(
                    stream: stream,
                    providers: providers,
                    season: season,
                    episode: episode,
                    // The addon told us WHICH file of the pack this row is.
                    // Without it every row of a season pack resolved to the
                    // same (largest) episode — the rows the fileIdx-aware
                    // dedupe now surfaces were all playing the same file.
                    fileIdx: stream.fileIdx
                )
            }
            let (result, resolvedBy) = outcome
                ?? (.failed("Timed out after \(Int(budget))s"), nil)
            // The viewer cancelled from the resolve spinner — a late success
            // must not shove the player over the list they went back to.
            guard !Task.isCancelled else { return }
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
                if autoAdvance(after: entry, all) { return }
                resolveError = "\(provider.displayName) API key is missing."
            case .notCached:
                if autoAdvance(after: entry, all) { return }
                resolveError = debrid.orderedResolvers.count > 1
                    ? "This torrent isn't cached on any of your debrid services. Try another source."
                    : "This torrent isn't cached on \(provider.displayName). Try another source."
            case .failed(let message):
                if autoAdvance(after: entry, all) { return }
                resolveError = "\(provider.displayName): \(message)"
            }
        }
    }

    /// Run `work` with a hard wall-clock deadline; nil on timeout. The losing
    /// task is cancelled (URLSession calls unwind cooperatively; provider
    /// cleanup like RD's torrent delete runs in its own unstructured task).
    private static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Abort an in-flight debrid/P2P resolve (Back from the resolve spinner
    /// or the auto-link screen). The task's own completions check
    /// `Task.isCancelled`, so a late answer can't present the player.
    private func cancelResolve() {
        guard resolving || resolveTask != nil else { return }
        resolveTask?.cancel()
        resolveTask = nil
        resolving = false
        viewModel.stage("resolve cancelled by viewer")
    }

    /// Play a torrent via the user's TorrServer instance (P2P) — no debrid.
    private func resolveViaP2P(_ entry: StreamEntry, _ all: [StreamEntry]) {
        guard let magnet = entry.stream.magnetURI
            ?? entry.stream.infoHash.map({ "magnet:?xt=urn:btih:\($0)" }) else {
            resolveError = "This source has no magnet link to hand to TorrServer."
            return
        }
        resolving = true
        resolveTask?.cancel()
        resolveTask = Task {
            // Same deadline as the debrid path (see handleSelection): a dead
            // TorrServer must fail over / alert, not hold the spinner.
            let season = viewModel.video?.season
            let episode = viewModel.video?.episode
            let stream = entry.stream
            let settings = torrent.settings
            let budget: TimeInterval = autoLinkResolving ? 20 : 60
            let outcome = await Self.withDeadline(seconds: budget) {
                await TorrServerService.resolve(
                    magnet: magnet, settings: settings,
                    season: season, episode: episode,
                    // TorrServer's file id IS the torrent-relative index, so
                    // unlike most debrid providers it can honour the addon's
                    // pick directly instead of guessing by filename or size.
                    fileIdx: stream.fileIdx
                )
            }
            let result = outcome ?? .failed("TorrServer timed out after \(Int(budget))s")
            // Cancelled from the resolve spinner — see the debrid path.
            guard !Task.isCancelled else { return }
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
                if autoAdvance(after: entry, all) { return }
                resolveError = "Turn on P2P and set a TorrServer URL in Settings → Integrations."
            case .failed(let message):
                if autoAdvance(after: entry, all) { return }
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
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster,
                            maxPixels: PerformanceProfile.backdropPixelCap)
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
                .font(FusionType.pageTitle(theme.font))
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
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @Environment(\.isFocused) private var isFocused

    let entry: StreamEntry
    var debridShortName: String?
    /// Badger badge chips matched for this link (see StreamBadgeStore).
    var badges: [StreamBadge] = []

    var body: some View {
        // Layout → "Full stream names": rows grow to fit the whole release
        // string instead of truncating it. `fixedSize` matters as much as the
        // lifted line limits — inside the list's lazy stack a Text is happy to
        // truncate at its proposed height unless told the full height is
        // required.
        let fullNames = homeCatalogSettings.fullStreamTitles
        HStack(spacing: OrivioSpacing.lg) {
            Image(systemName: entry.stream.isTorrent ? "bolt.horizontal.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(isFocused ? theme.palette.secondary : theme.palette.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(fullNames ? nil : 1)
                    .fixedSize(horizontal: false, vertical: fullNames)
                if !entry.displayDetail.isEmpty {
                    Text(entry.displayDetail)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(fullNames ? nil : 2)
                        .fixedSize(horizontal: false, vertical: fullNames)
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


/// The cover held over the source page between an automatic pick handing off to
/// the player and this page actually being popped (`didAutoDismiss`). Just the
/// title's backdrop: no spinner, no status, nothing that reads as a search
/// starting up again on the way out of a title.
private struct AutoPickHandoffScreen: View {
    let meta: MetaItem

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Nothing else here is focusable, and with NOTHING focused a Menu
            // press falls through to tvOS and suspends the app — the same
            // reason AutoLinkLoadingScreen anchors focus.
            FocusAnchor()
            RemoteImage(url: meta.background ?? meta.poster,
                        maxPixels: PerformanceProfile.backdropPixelCap)
                .ignoresSafeArea()
            Color.black.opacity(0.6).ignoresSafeArea()
        }
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
            RemoteImage(url: meta.background ?? meta.poster,
                        maxPixels: PerformanceProfile.backdropPixelCap)
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
                        RemoteImage(url: meta.logo, contentMode: .fit, maxDimension: 480)
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
