import Foundation

enum WatchHistoryClearState {
    private static let clearedAtKey = "orivio.watchHistoryClearedAt.v1"

    static var clearedAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: clearedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    @discardableResult
    static func markClearedNow() -> Date {
        let date = Date()
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: clearedAtKey)
        // An explicit new clear overrides an earlier reset.
        UserDefaults.standard.removeObject(forKey: clearedResetKey)
        return date
    }

    private static let clearedResetKey = "orivio.watchHistoryClearedAt.reset.v1"

    /// Whether this device deliberately dropped its clear point. Sticky,
    /// because the point also lives in the account blob: without this, the very
    /// next pull re-adopted the horizon that was just reset and nothing changed.
    static var wasReset: Bool { UserDefaults.standard.bool(forKey: clearedResetKey) }

    /// Forget the clear point entirely, and stop the account re-supplying it.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: clearedAtKey)
        UserDefaults.standard.set(true, forKey: clearedResetKey)
    }

    /// Adopt a clear point learned from the account (synced prefs blob). The
    /// clear point used to be CONTAINER-LOCAL only — so any other install of
    /// the app (a dev build, a fresh sideload) had none, re-imported the
    /// user's entire Trakt history unfiltered, and pushed the flood up to the
    /// account, undoing the curation done on the device that cleared. Newest
    /// wins; nil never regresses an existing local clear.
    static func adopt(_ remote: Date?) {
        // A device that reset its horizon must not have it handed back by the
        // account on the next pull.
        guard !wasReset, let remote else { return }
        if let clearedAt, clearedAt >= remote { return }
        UserDefaults.standard.set(remote.timeIntervalSince1970, forKey: clearedAtKey)
    }
}

struct WatchProgress: Codable, Identifiable, Hashable {
    let id: String
    let metaID: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    /// Episode still image, so Continue Watching can show it instead of the
    /// show poster. Optional → old saves without it decode to nil.
    var episodeThumbnail: String? = nil
    var positionSeconds: Double
    var durationSeconds: Double
    var streamURL: String?
    /// Format fingerprint of the link that was playing, so a resume can pick a
    /// fresh link with the same look (DV/HDR/Atmos/resolution). Local-only (the
    /// backend has no field for it); optional so old saves + synced rows decode.
    var streamSignature: StreamSignature? = nil
    var updatedAt: Date
    var syncSource: String? = nil
    var hasNewEpisode: Bool? = nil

    var fraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    var remainingTimeText: String? {
        guard durationSeconds.isFinite,
              positionSeconds.isFinite,
              durationSeconds > positionSeconds,
              fraction > 0,
              fraction < 0.95 else { return nil }
        let minutes = max(1, Int(((durationSeconds - positionSeconds) / 60).rounded(.up)))
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    static func shouldReplaceTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == id { return true }
        if trimmed.hasPrefix("tt") && trimmed.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    func withFallbackMetadata(_ meta: MetaItem) -> WatchProgress {
        WatchProgress(
            id: id,
            metaID: metaID,
            type: type,
            name: Self.shouldReplaceTitle(name, id: metaID) ? meta.name : name,
            poster: poster ?? meta.poster,
            background: background ?? meta.background,
            logo: logo ?? meta.logo,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            episodeThumbnail: episodeThumbnail,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            streamURL: streamURL,
            streamSignature: streamSignature,
            updatedAt: updatedAt,
            syncSource: syncSource,
            hasNewEpisode: hasNewEpisode
        )
    }
}

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var items: [String: WatchProgress] = [:]

    /// Rows written by `updateTransient` (the periodic in-playback save) that
    /// are NOT yet reflected in `items` — by design, since publishing them
    /// would re-render Home behind the player.
    ///
    /// They have to be remembered, though, because `items` is what every other
    /// `save()` encodes. Without this, any unrelated write during playback — a
    /// sync pull landing, marking something watched, removing a row — reached
    /// disk carrying the position from when the movie STARTED and silently
    /// undid every periodic save since. A crash then lost the whole session,
    /// which is exactly what the periodic save exists to prevent.
    private var transientOverrides: [String: WatchProgress] = [:]

    /// Monotonic stamp for persistence writes. Encode + write happen off the
    /// main actor, so two saves in flight could otherwise land out of order
    /// and leave the OLDER snapshot on disk.
    private var saveSequence: UInt64 = 0

    /// Hand a snapshot to the serializing writer.
    private func persist(_ snapshot: [String: WatchProgress],
                         shelf: [TopShelfExporter.Entry]?) {
        saveSequence += 1
        let sequence = saveSequence
        let key = storageKey
        Task.detached(priority: .utility) {
            await ProgressPersister.shared.write(snapshot, key: key, sequence: sequence, shelf: shelf)
        }
    }

    /// Called after a local progress change so account sync can push. Not
    /// fired while merging remote data (guarded by `suppressChange`).
    var onLocalUpdate: (() -> Void)?
    /// Called when a title/episode crosses the "finished" threshold, so it can
    /// be recorded in watched history.
    var onFinished: ((MetaItem, MetaVideo?) -> Void)?
    /// Called with the progress keys of entries the user explicitly deleted, so
    /// account sync can delete them server-side too — otherwise they'd
    /// resurrect on the next pull.
    var onRemove: (([String]) -> Void)?
    /// Fired when the USER removes a title from Continue Watching (with its
    /// metaID), so Trakt sync can delete the matching playback rows there too.
    /// Not fired for internal migrations (recanonicalize) — the title is still
    /// being watched, its key just changed.
    var onTraktRemove: ((String) -> Void)?
    /// Fired with the metaID when a title leaves Continue Watching, so the
    /// Stremio sync can clear it THERE too. Stremio's continue watching is
    /// derived from each library item's playback state, and the push only
    /// carries rows that still exist locally — so without this a removal was
    /// invisible to Stremio and the card simply came back on the next pull.
    var onStremioClearProgress: ((String) -> Void)?
    private var suppressChange = false

    /// Recently-removed progress keys → removal time. A pull's server snapshot
    /// can still contain a just-removed item (its server delete is slower than
    /// the 30s Home poll), so without this the next poll would resurrect the
    /// card the user just removed. mergeRemote refuses to re-add a tombstoned
    /// id until the grace passes (by which point the delete has landed and the
    /// server no longer returns it). A local re-watch clears the tombstone.
    private var tombstones: [String: Date] = [:]
    private static let tombstoneGrace: TimeInterval = 180

    /// Keys that arrived from an EXTERNAL source (Trakt playback) this session
    /// — PERMANENT for the session. Trakt sync consults this to avoid pushing
    /// Trakt's own rows back at it, which would resurrect items the user
    /// deleted on trakt.tv.
    private var externallyMerged: Set<String> = []

    /// Externally-merged keys whose account push hasn't been CONFIRMED by a
    /// server snapshot yet — TEMPORARY. The account reconcile must not delete
    /// these as "absent from the server": they carry their real (old) watch
    /// timestamps, so the 2-minute deletion grace — which protects fresh local
    /// rows while their push is in flight — offers them no protection. Once a
    /// snapshot contains the key (the push landed) it's pruned, so a removal
    /// made on another device can still propagate here afterwards.
    private var awaitingServerAck: Set<String> = []

    private func pruneTombstones() {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneGrace)
        tombstones = tombstones.filter { $0.value >= cutoff }
    }

    /// Reassert tombstones from outside — the sync manager calls this before a
    /// pull for removals whose server delete hasn't been confirmed yet, so a
    /// full-snapshot pull can't resurrect them while the delete is still
    /// pending/retrying. Renewing the timestamp keeps them protected across the
    /// 30s poll for as long as the delete is outstanding.
    func tombstone(_ ids: [String]) {
        let now = Date()
        for id in ids { tombstones[id] = now }
    }

    /// Active profile scope. Profile 1 uses the original (unsuffixed) key so
    /// existing data is preserved; other profiles get a suffixed namespace.
    private var profileID = 1
    private var storageKey: String {
        profileID == 1 ? "orivio.progress.v1" : "orivio.progress.v1.p\(profileID)"
    }

    /// Shows the user dismissed from the Next Up row.
    ///
    /// Home synthesises Next Up cards from WATCHED history, not from stored
    /// progress, so "Remove from Continue Watching" on one had no rows to delete
    /// and `removeShow` returned having done nothing — the card stayed put with
    /// no way to get rid of it. The same gap let a show the user DID remove come
    /// straight back as a Next Up suggestion a moment later.
    ///
    /// Cleared as soon as the show gets real progress again, so it can never
    /// become a permanent blocklist.
    @Published private(set) var dismissedNextUpShows: Set<String> = []
    private var dismissedNextUpKey: String {
        profileID == 1 ? "orivio.nextUp.dismissed.v1" : "orivio.nextUp.dismissed.v1.p\(profileID)"
    }

    /// Stop offering this show in the Next Up row.
    func dismissNextUp(metaID: String) {
        guard !dismissedNextUpShows.contains(metaID) else { return }
        dismissedNextUpShows.insert(metaID)
        UserDefaults.standard.set(Array(dismissedNextUpShows), forKey: dismissedNextUpKey)
    }

    /// Playing the show again undoes the dismissal.
    private func clearNextUpDismissal(metaID: String) {
        guard dismissedNextUpShows.remove(metaID) != nil else { return }
        if dismissedNextUpShows.isEmpty {
            UserDefaults.standard.removeObject(forKey: dismissedNextUpKey)
        } else {
            UserDefaults.standard.set(Array(dismissedNextUpShows), forKey: dismissedNextUpKey)
        }
    }

    private static let maxProgressSeconds: Double = 30 * 24 * 60 * 60

    private static func sanitized(_ entry: WatchProgress) -> WatchProgress? {
        guard entry.positionSeconds.isFinite,
              entry.durationSeconds.isFinite,
              entry.updatedAt.timeIntervalSince1970.isFinite,
              entry.durationSeconds > 60,
              entry.durationSeconds <= maxProgressSeconds,
              entry.positionSeconds >= 0 else { return nil }
        var sanitized = entry
        sanitized.positionSeconds = min(entry.positionSeconds, entry.durationSeconds)
        return sanitized
    }

    init() {
        load()
    }

    /// Switch to another profile's data: the current profile is already
    /// persisted, so just re-point storage and reload.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        suppressChange = true
        items = [:]
        // The in-playback overrides belong to the profile we are LEAVING. Left
        // in place, the next save/push folds them into the new profile's data.
        transientOverrides.removeAll()
        load()
        suppressChange = false
    }

    /// All entries, for a full push to the account backend.
    func allForSync() -> [WatchProgress] { Array(items.values) }

    private static let serviceSyncSources: Set<String> = ["local", "nuvio", "stremio", "trakt"]

    func serviceBackedForSync() -> [WatchProgress] {
        // Fold in the periodic in-playback saves, exactly as `save()` does.
        // Without this the account was pushed the position from when the film
        // STARTED: the row in `items` is only refreshed by the publishing
        // `update()`, which during playback never runs. A title watched for
        // forty minutes and still playing looked, to every other device, like
        // it had never been touched.
        var merged = items
        for (key, transient) in transientOverrides {
            // Never push back a key the user just removed/finished.
            if tombstones[key] != nil { continue }
            guard let live = merged[key] else { merged[key] = transient; continue }
            if transient.updatedAt > live.updatedAt { merged[key] = transient }
        }
        return merged.values.filter { item in
            guard let source = item.syncSource else { return false }
            return Self.serviceSyncSources.contains(source)
        }
    }

    /// Ask account sync to push what the periodic saves have written, WITHOUT
    /// publishing. `update()` would refresh `items` and re-render every view
    /// observing this store — including the Home screen sitting behind the
    /// player, which is the periodic playback hiccup this store works hard to
    /// avoid. The data is already on disk and in `transientOverrides`; this
    /// just tells the sync manager to send it.
    func requestSyncPush() {
        guard !suppressChange else { return }
        onLocalUpdate?()
    }

    func importEntries(_ entries: [WatchProgress]) {
        guard !entries.isEmpty else { return }
        var changed = false
        for entry in entries {
            guard let entry = Self.sanitized(entry) else { continue }
            if let local = items[entry.id], local.updatedAt >= entry.updatedAt { continue }
            tombstones.removeValue(forKey: entry.id)
            items[entry.id] = entry
            changed = true
        }
        if changed {
            save()
            if !suppressChange { onLocalUpdate?() }
        }
    }

    /// Merges entries pulled from the account, keeping whichever side was
    /// updated more recently. Never triggers a push back.
    /// Grace window protecting a just-created local row from deletion
    /// reconciliation. A row's own push fires immediately on change but takes a
    /// round-trip to land; if a pull's server snapshot was captured before that
    /// push arrived, the row is legitimately absent from `remote` yet must NOT
    /// be treated as deleted. Anything older than this is safe to reconcile.
    private static let deletionGrace: TimeInterval = 120

    private func coalesced(remote entry: WatchProgress, local: WatchProgress) -> WatchProgress {
        WatchProgress(
            id: entry.id,
            metaID: entry.metaID,
            type: entry.type,
            name: WatchProgress.shouldReplaceTitle(entry.name, id: entry.metaID) ? local.name : entry.name,
            poster: entry.poster ?? local.poster,
            background: entry.background ?? local.background,
            logo: entry.logo ?? local.logo,
            season: entry.season,
            episode: entry.episode,
            episodeTitle: entry.episodeTitle
                ?? (local.season == entry.season && local.episode == entry.episode ? local.episodeTitle : nil),
            episodeThumbnail: entry.episodeThumbnail
                ?? (local.season == entry.season && local.episode == entry.episode ? local.episodeThumbnail : nil),
            positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds,
            streamURL: entry.streamURL
                ?? (local.season == entry.season && local.episode == entry.episode ? local.streamURL : nil),
            streamSignature: local.season == entry.season && local.episode == entry.episode
                ? local.streamSignature : nil,
            updatedAt: entry.updatedAt,
            syncSource: entry.syncSource,
            hasNewEpisode: entry.hasNewEpisode ?? local.hasNewEpisode
        )
    }

    /// Merge a FULL remote snapshot for the profile. Two-way: newer remote rows
    /// are upserted, AND local rows the server no longer has are removed — so a
    /// removal made on another device (or a prior session) propagates the same
    /// way an addition does. Without the delete half, `mergeRemote` was
    /// additive-only: adds synced, removes never did.
    func mergeRemote(_ remote: [WatchProgress]) {
        suppressChange = true
        defer { suppressChange = false }
        var changed = false
        pruneTombstones()

        // ── Reconcile deletions ── remove local rows absent from the server
        // snapshot, except ones updated within the grace window (their own push
        // may still be in flight). This runs from a successful pull only, so an
        // empty snapshot genuinely means "the account has no Continue Watching."
        let remoteIDs = Set(remote.map(\.id))
        let cutoff = Date().addingTimeInterval(-Self.deletionGrace)
        // Collect first, then remove — mutating `items` mid-iteration is unsafe.
        // A snapshot that CONTAINS an externally-merged key proves its push
        // landed — release the exemption so future reconciles govern it.
        awaitingServerAck.subtract(remoteIDs)
        let staleIDs = items.compactMap { id, local in
            (!remoteIDs.contains(id) && local.updatedAt < cutoff
             && !awaitingServerAck.contains(id)) ? id : nil
        }
        for id in staleIDs {
            items.removeValue(forKey: id)
            changed = true
        }

        for rawEntry in remote {
            guard let entry = Self.sanitized(rawEntry) else { continue }
            // A just-removed item may still be in the server snapshot (its
            // delete is slower than the poll). Don't resurrect it — unless the
            // remote row is NEWER than our removal, which means it was
            // re-watched elsewhere after we removed it (honor that, drop tomb).
            if let tomb = tombstones[entry.id] {
                if entry.updatedAt > tomb {
                    tombstones.removeValue(forKey: entry.id)
                } else {
                    continue
                }
            }
            if let local = items[entry.id], local.updatedAt >= entry.updatedAt { continue }
            // Remote wins on position/timestamps, but synced rows arrive bare
            // (the backend stores no title/artwork/stream URL) and enrichment
            // is best-effort — so keep whatever presentation fields the local
            // entry already has instead of blanking the card. The remembered
            // stream URL carries over only for the same episode, so instant
            // resume keeps working after a pull.
            let merged = items[entry.id].map { coalesced(remote: entry, local: $0) } ?? entry
            items[entry.id] = merged
            changed = true
        }
        if changed { save() }
    }

    func removeLocalOnlyProgress() {
        let next = items.filter { _, item in
            guard let source = item.syncSource else { return false }
            return Self.serviceSyncSources.contains(source)
        }
        guard next.count != items.count else { return }
        items = next
        awaitingServerAck.formIntersection(Set(items.keys))
        externallyMerged.formIntersection(Set(items.keys))
        save()
    }

    /// Replace local Continue Watching with the Orivio account snapshot, keeping
    /// only external rows that were just merged from Stremio/Trakt and have not
    /// been acknowledged by Orivio yet. This removes stale device-local Orivio
    /// progress that otherwise bloats Continue Watching forever.
    func replaceWithOrivioSnapshot(_ remote: [WatchProgress], preserveLocalAdditions: Bool = false) {
        suppressChange = true
        defer { suppressChange = false }

        let sanitizedRemote = remote.compactMap(Self.sanitized)
        let remoteIDs = Set(sanitizedRemote.map(\.id))
        awaitingServerAck.subtract(remoteIDs)

        var next: [String: WatchProgress] = [:]
        for entry in sanitizedRemote {
            if let local = items[entry.id] {
                next[entry.id] = coalesced(remote: entry, local: local)
            } else {
                next[entry.id] = entry
            }
        }
        for id in awaitingServerAck {
            if let local = items[id], Self.sanitized(local) != nil {
                next[id] = local
            }
        }
        if preserveLocalAdditions {
            for (id, local) in items where next[id] == nil {
                guard Self.sanitized(local) != nil,
                      let source = local.syncSource,
                      Self.serviceSyncSources.contains(source) else { continue }
                next[id] = local
            }
        }

        guard next != items else { return }
        items = next
        save()
    }

    /// Backfill resolved title/artwork onto existing rows (matched by id),
    /// WITHOUT touching playback position, timestamps, or triggering a push —
    /// used by sync to replace a raw "tt…" id with the real title once a meta
    /// addon has been consulted. A real title is never regressed to an id, and
    /// existing artwork is kept. No-op for ids not currently present.
    func applyEnrichedMetadata(_ enriched: [WatchProgress]) {
        suppressChange = true
        defer { suppressChange = false }
        var changed = false
        for row in enriched {
            guard let existing = items[row.id] else { continue }
            let keepTitle = !WatchProgress.shouldReplaceTitle(existing.name, id: existing.metaID)
                || WatchProgress.shouldReplaceTitle(row.name, id: row.metaID)
            let merged = WatchProgress(
                id: existing.id,
                metaID: existing.metaID,
                type: existing.type,
                name: keepTitle ? existing.name : row.name,
                poster: existing.poster ?? row.poster,
                background: existing.background ?? row.background,
                logo: existing.logo ?? row.logo,
                season: existing.season,
                episode: existing.episode,
                episodeTitle: existing.episodeTitle ?? row.episodeTitle,
                episodeThumbnail: existing.episodeThumbnail ?? row.episodeThumbnail,
                positionSeconds: existing.positionSeconds,
                durationSeconds: existing.durationSeconds,
                streamURL: existing.streamURL,
                streamSignature: existing.streamSignature,
                updatedAt: existing.updatedAt,
                syncSource: existing.syncSource,
                hasNewEpisode: existing.hasNewEpisode
            )
            if merged != existing {
                items[row.id] = merged
                changed = true
            }
        }
        if changed { save() }
    }

    /// Additively merge externally-sourced progress (Trakt playback) — adds a
    /// row only when the key is absent, or updates position when the external
    /// one is clearly further AND the local row is older. Never deletes, so it
    /// can't fight the Orivio full-snapshot reconcile.
    /// The key an incoming row should land on: its own if we already hold that
    /// key, otherwise any existing row for the SAME title and episode.
    ///
    /// Sources disagree on how to key an episode — Trakt builds
    /// `tt1234:1:1` while the player uses the addon's own video id, which can
    /// be `tt1234_s1e1`. Keyed literally, the same episode lands twice and the
    /// two copies never merge: two rows, two positions, and whichever sorts
    /// first wins the card. Matching on identity instead is what makes the
    /// account a real hub rather than three parallel lists.
    private func mergeKey(for entry: WatchProgress, index: [String: String]) -> String {
        if items[entry.id] != nil { return entry.id }
        return index[Self.identity(of: entry)] ?? entry.id
    }

    /// metaID + season + episode — the same episode however it was keyed.
    private static func identity(of item: WatchProgress) -> String {
        "\(item.metaID)|\(item.season.map(String.init) ?? "-")|\(item.episode.map(String.init) ?? "-")"
    }

    private func identityIndex() -> [String: String] {
        var index: [String: String] = [:]
        for (key, item) in items where index[Self.identity(of: item)] == nil {
            index[Self.identity(of: item)] = key
        }
        return index
    }

    /// Collapse rows that are the same episode under different keys, keeping
    /// one and deleting the rest from the account too.
    ///
    /// Merging by identity (see mergeKey) stops new duplicates, but installs
    /// that already synced a Trakt-keyed copy alongside the player's own hold
    /// both. The survivor is the most recently updated row; on a tie the one
    /// the player itself writes (anything not sourced from Trakt) wins, since
    /// that is the key future playback will keep updating.
    @discardableResult
    func collapseDuplicateEpisodes() -> [String] {
        var best: [String: String] = [:]      // identity -> winning key
        var losers: [String] = []
        for (key, item) in items.sorted(by: { $0.key < $1.key }) {
            let id = Self.identity(of: item)
            guard let current = best[id], let held = items[current] else {
                best[id] = key
                continue
            }
            let heldWins: Bool
            if held.updatedAt != item.updatedAt {
                heldWins = held.updatedAt > item.updatedAt
            } else {
                heldWins = held.syncSource != "trakt" || item.syncSource == "trakt"
            }
            if heldWins { losers.append(key) } else { best[id] = key; losers.append(current) }
        }
        guard !losers.isEmpty else { return [] }
        for key in losers { items.removeValue(forKey: key) }
        save()
        if !suppressChange {
            // Delete the dropped keys from the account as well, or the next
            // pull hands the duplicate straight back.
            onRemove?(losers)
            onLocalUpdate?()
        }
        return losers
    }

    func mergeExternal(_ remote: [WatchProgress]) {
        suppressChange = true
        var changed = false
        let index = identityIndex()
        for rawEntry in remote {
            guard let entry = Self.sanitized(rawEntry) else { continue }
            let key = mergeKey(for: entry, index: index)
            if let local = items[key] {
                // Only advance position if external is further and MEANINGFULLY
                // newer (60s slack). External positions are rebuilt from a
                // percentage × a guessed runtime, so they're approximate — the
                // slack keeps a row this device just scrobble-pushed (whose
                // paused_at lands seconds after our own updatedAt) from
                // clobbering the precise local resume point with the
                // round-tripped estimate. A genuine watch on another device is
                // comfortably past 60s.
                if entry.positionSeconds > local.positionSeconds + 5,
                   entry.updatedAt > local.updatedAt.addingTimeInterval(60) {
                    var merged = local
                    merged.positionSeconds = entry.positionSeconds
                    if entry.durationSeconds > 0 { merged.durationSeconds = entry.durationSeconds }
                    merged.updatedAt = entry.updatedAt
                    items[key] = merged
                    externallyMerged.insert(key)
                    awaitingServerAck.insert(key)
                    changed = true
                }
            } else if tombstones[entry.id] == nil {
                items[entry.id] = entry
                externallyMerged.insert(entry.id)
                awaitingServerAck.insert(entry.id)
                changed = true
            }
        }
        if changed { save() }
        suppressChange = false
        // Push the merged rows to the ACCOUNT server too. Without this, the
        // account's full-snapshot reconcile (mergeRemote, run by the 30s
        // Continue Watching poll) saw Trakt-pulled rows as "absent from the
        // server" and deleted them within seconds — Trakt items flashed into
        // Continue Watching and then silently vanished, which is why Trakt
        // sync never seemed to show everything.
        if changed { onLocalUpdate?() }
    }

    /// Items that should appear in the Continue Watching row.
    ///
    /// A title shows up as soon as *any* progress is recorded (no minimum
    /// watched fraction) so an episode you barely started still appears. Series
    /// are collapsed to a single card per show (`metaID`) — the most recently
    /// watched episode — so starting a new episode replaces the old card
    /// instead of stacking a second entry for the same series.
    var continueWatching: [WatchProgress] {
        continueWatching(sortMode: .recentlyWatched)
    }

    /// Continue Watching, ordered per the chosen sort mode.
    /// - recentlyWatched: most recently played first.
    /// - streamingStyle: titles you're mid-episode on (2–95%) first, each by
    ///   recency, then barely-started ones — so you resume what you're actually
    ///   in the middle of.
    func continueWatching(sortMode: ContinueWatchingSortMode) -> [WatchProgress] {
        var latestPerShow: [String: WatchProgress] = [:]
        for item in items.values where item.fraction < 0.95 {
            if let existing = latestPerShow[item.metaID] {
                // Ties broken by id, NOT by whichever the dictionary happened to
                // yield first: `items` is a Dictionary, so its iteration order
                // is arbitrary and differs run to run. With equal timestamps
                // that made the surviving row for a show — its poster, its
                // episode — change on its own.
                guard (item.updatedAt, item.id) > (existing.updatedAt, existing.id) else { continue }
            }
            latestPerShow[item.metaID] = item
        }
        // Sort on (timestamp, id) so equal timestamps have ONE defined order.
        // sorted(by:) is not a stable sort, and its input here is unordered
        // dictionary values, so tied rows came out in a different order every
        // time this ran — and it runs on every body pass. That is the Continue
        // Watching row visibly reshuffling while you sit on the home screen.
        //
        // Ties are not rare: anything imported in a batch shares a timestamp —
        // a Trakt history import stamps hundreds of rows within the same
        // moment, and a restore writes them all at once.
        let byRecency = latestPerShow.values.sorted {
            ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id)
        }
        switch sortMode {
        case .recentlyWatched:
            return byRecency
        case .streamingStyle:
            let inProgress = byRecency.filter { $0.fraction >= 0.02 }
            let fresh = byRecency.filter { $0.fraction < 0.02 }
            return inProgress + fresh
        }
    }

    func progress(for key: String) -> WatchProgress? {
        items[key]
    }

    static func key(metaID: String, video: MetaVideo?) -> String {
        guard let video else { return metaID }
        return video.id
    }

    func update(
        meta: MetaItem,
        video: MetaVideo?,
        streamURL: String?,
        position: Double,
        duration: Double,
        signature: StreamSignature? = nil
    ) {
        guard duration.isFinite,
              position.isFinite,
              duration > 60,
              duration <= Self.maxProgressSeconds,
              position > 0 else { return }
        let key = Self.key(metaID: meta.id, video: video)
        if position / duration >= 0.95 {
            let removed = items.removeValue(forKey: key) != nil
            // Retire the periodic row too. Without this, `save()` below folds it
            // back into the snapshot and the finished title returns to Continue
            // Watching on the next launch — and `serviceBackedForSync()` pushes
            // it back to the account right after `onRemove` asked for a delete.
            transientOverrides.removeValue(forKey: key)
            if removed { tombstones[key] = Date() }
            if !suppressChange {
                if removed { onRemove?([key]) }
                onFinished?(meta, video)
            }
        } else {
            // Re-watching something you'd removed clears its tombstone so the
            // fresh entry syncs normally.
            tombstones.removeValue(forKey: key)
            items[key] = WatchProgress(
                id: key,
                metaID: meta.id,
                type: meta.type,
                name: meta.name,
                poster: meta.poster,
                background: meta.background,
                logo: meta.logo,
                season: video?.season,
                episode: video?.episode,
                episodeTitle: video?.title,
                episodeThumbnail: video?.thumbnail,
                positionSeconds: position,
                durationSeconds: duration,
                streamURL: streamURL,
                streamSignature: signature ?? items[key]?.streamSignature,
                updatedAt: Date(),
                syncSource: "nuvio"
            )
            // `items` now carries the newest position for this key, so the
            // periodic override is stale — retire it instead of accumulating.
            transientOverrides.removeValue(forKey: key)
            // Watching it again is an undo of "remove from Continue Watching".
            clearNextUpDismissal(metaID: meta.id)
        }
        save()
        if !suppressChange { onLocalUpdate?() }
    }

    /// Periodic in-playback save: persists to disk (crash safety) WITHOUT
    /// touching the published `items` — publishing re-rendered the whole Home
    /// screen sitting behind the player on every save, a periodic playback
    /// hiccup. The player's teardown/exit paths call the normal `update`,
    /// which publishes once and brings the UI up to date.
    func updateTransient(
        meta: MetaItem,
        video: MetaVideo?,
        streamURL: String?,
        position: Double,
        duration: Double,
        signature: StreamSignature? = nil
    ) {
        guard duration.isFinite,
              position.isFinite,
              duration > 60,
              duration <= Self.maxProgressSeconds,
              position > 0,
              position / duration < 0.95 else { return }
        let key = Self.key(metaID: meta.id, video: video)
        // Watching it again clears the removal tombstone, exactly as the
        // publishing `update()` does. Without this, a title removed and then
        // immediately re-played stayed tombstoned for the full grace period,
        // and the guards in `save()` / `serviceBackedForSync()` would skip its
        // periodic rows — losing the very in-playback progress they persist.
        tombstones.removeValue(forKey: key)
        var snapshot = items
        snapshot[key] = WatchProgress(
            id: key,
            metaID: meta.id,
            type: meta.type,
            name: meta.name,
            poster: meta.poster,
            background: meta.background,
            logo: meta.logo,
            season: video?.season,
            episode: video?.episode,
            episodeTitle: video?.title,
            episodeThumbnail: video?.thumbnail,
            positionSeconds: position,
            durationSeconds: duration,
            streamURL: streamURL,
            streamSignature: signature ?? items[key]?.streamSignature,
            updatedAt: Date(),
            syncSource: "nuvio"
        )
        transientOverrides[key] = snapshot[key]
        persist(snapshot, shelf: nil)
    }

    func remove(id: String) {
        guard items.removeValue(forKey: id) != nil else { return }
        transientOverrides.removeValue(forKey: id)
        tombstones[id] = Date()
        save()
        if !suppressChange {
            onRemove?([id])
            onLocalUpdate?()
        }
    }

    @discardableResult
    func clearAllProgress(notify: Bool = true) -> [String] {
        let removedKeys = Array(items.keys)
        guard !removedKeys.isEmpty else { return [] }
        let now = Date()
        for key in removedKeys { tombstones[key] = now }
        items.removeAll()
        externallyMerged.removeAll()
        awaitingServerAck.removeAll()
        // Periodic in-playback rows are part of "all progress" too — leaving
        // them behind let the very next save re-materialise the history the
        // user just cleared.
        transientOverrides.removeAll()
        rebuildContinueFractions()
        // Go through the serializing writer instead of clearing the key
        // directly: a save queued moments ago would otherwise land AFTER this
        // and restore the cleared history.
        persist([:], shelf: [])
        if notify && !suppressChange {
            onRemove?(removedKeys)
            onLocalUpdate?()
        }
        return removedKeys
    }

    /// Rewrite a progress entry's identifiers to their canonical IMDb (`tt`)
    /// form, preserving position/timestamps. Used when resuming a TMDB-sourced
    /// item whose stored `tmdb:` key can't be served by Cinemeta/Torrentio —
    /// without this the migrated playback would save under the new key and
    /// leave the old `tmdb:` entry behind as a duplicate Continue Watching card.
    func recanonicalize(oldID: String, newID: String, newMetaID: String) {
        guard oldID != newID, let existing = items[oldID] else { return }
        items.removeValue(forKey: oldID)
        transientOverrides.removeValue(forKey: oldID)
        tombstones[oldID] = Date()   // stale key is deleted server-side too
        tombstones.removeValue(forKey: newID)   // the canonical key is being (re)created
        // Carry episodeThumbnail and hasNewEpisode too: rebuilding without them
        // made a tmdb:→tt: migrated card drop back to the show poster (and lose
        // its "new episode" pip) the moment the key was canonicalized.
        items[newID] = WatchProgress(
            id: newID, metaID: newMetaID, type: existing.type, name: existing.name,
            poster: existing.poster, background: existing.background, logo: existing.logo,
            season: existing.season, episode: existing.episode, episodeTitle: existing.episodeTitle,
            episodeThumbnail: existing.episodeThumbnail,
            positionSeconds: existing.positionSeconds, durationSeconds: existing.durationSeconds,
            streamURL: existing.streamURL, streamSignature: existing.streamSignature,
            updatedAt: existing.updatedAt,
            syncSource: existing.syncSource,
            hasNewEpisode: existing.hasNewEpisode
        )
        save()
        if !suppressChange {
            onRemove?([oldID])   // delete the stale tmdb: key server-side
            onLocalUpdate?()     // push the canonical entry
        }
    }

    /// Removes every stored entry for a show (all episodes), the way "Remove
    /// from Continue Watching" works on Netflix/Hulu. Deleting just the visible
    /// episode would leave the show's other episodes behind, so the card would
    /// immediately reappear with a different episode.
    /// `notifyTrakt` must be passed ONLY from an explicit user action ("Remove
    /// from Continue Watching") — it deletes the title's playback rows on the
    /// user's Trakt account, which no internal cleanup/migration should do.
    func removeShow(metaID: String, notifyTrakt: Bool = false) {
        // Suppress the Next Up suggestion too, even when there is nothing
        // stored to delete. A Next Up card is synthesised from watched history
        // and has no progress row, so this method used to bail immediately and
        // the card the user asked to remove simply stayed on screen.
        // Only for a real user action — an internal merge/cleanup removing rows
        // is not the user saying "stop suggesting this".
        if !suppressChange { dismissNextUp(metaID: metaID) }
        let removedKeys = items.values.filter { $0.metaID == metaID }.map(\.id)
        guard !removedKeys.isEmpty else {
            if !suppressChange {
                if notifyTrakt { onTraktRemove?(metaID) }
                onStremioClearProgress?(metaID)
            }
            return
        }
        let now = Date()
        for key in removedKeys {
            items.removeValue(forKey: key)
            transientOverrides.removeValue(forKey: key)
            tombstones[key] = now
        }
        save()
        if !suppressChange {
            onRemove?(removedKeys)
            if notifyTrakt { onTraktRemove?(metaID) }
            onStremioClearProgress?(metaID)
            onLocalUpdate?()
        }
    }

    // MARK: - Cheap poster lookups

    /// metaID → latest unfinished fraction. Maintained on every mutation so
    /// poster cards can look their progress up in O(1) — computing
    /// `continueWatching` (scan + sort) per card per render was measurable
    /// jank on the A10X.
    private(set) var continueFractions: [String: Double] = [:]

    private func rebuildContinueFractions() {
        var latest: [String: (Date, Double)] = [:]
        for item in items.values where item.fraction < 0.95 {
            if let existing = latest[item.metaID], existing.0 >= item.updatedAt { continue }
            latest[item.metaID] = (item.updatedAt, item.fraction)
        }
        continueFractions = latest.mapValues { $0.1 }
    }

    private func load() {
        dismissedNextUpShows = Set(UserDefaults.standard.stringArray(forKey: dismissedNextUpKey) ?? [])
        defer {
            rebuildContinueFractions()
            // Refresh the Top Shelf snapshot on launch/profile switch so the
            // tvOS home shelf reflects existing Continue Watching immediately
            // (save() only fires during playback).
            let shelf = TopShelfExporter.entries(from: continueWatching)
            Task.detached(priority: .utility) { TopShelfExporter.write(shelf) }
        }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: WatchProgress].self, from: data) else {
            items = [:]
            return
        }
        let sanitized = decoded.compactMapValues { Self.sanitized($0) }
        items = sanitized.filter { _, item in item.syncSource != nil }
        if items.count != decoded.count { save() }
    }

    private func save() {
        rebuildContinueFractions()
        // Encode + persist OFF the main thread: serializing the whole history
        // and writing UserDefaults on main was part of the periodic playback
        // hiccup (this runs every 30s while a video plays).
        // Fold in any periodic in-playback saves `items` doesn't know about,
        // but never over a row `items` has more recent news about (the exit
        // path publishes a real update, and a remote merge can supersede too).
        var snapshot = items
        for (key, transient) in transientOverrides {
            // Never re-persist a key the user just removed/finished.
            if tombstones[key] != nil { continue }
            guard let live = snapshot[key] else { snapshot[key] = transient; continue }
            if transient.updatedAt > live.updatedAt { snapshot[key] = transient }
        }
        // Top Shelf mirrors the Continue Watching row — snapshot the entries
        // here (cheap) and write them in the same background hop.
        let shelf = TopShelfExporter.entries(from: continueWatching)
        persist(snapshot, shelf: shelf)
    }
}


/// Serializes progress writes off the main actor. Encoding and writing happen
/// outside the main actor (serializing the whole history on main was itself a
/// playback hiccup), so two saves can be in flight at once — an actor plus a
/// monotonic sequence keeps the OLDER snapshot from landing last and undoing
/// the newer one.
private actor ProgressPersister {
    static let shared = ProgressPersister()
    private var lastSequence: UInt64 = 0

    func write(_ snapshot: [String: WatchProgress], key: String,
               sequence: UInt64, shelf: [TopShelfExporter.Entry]?) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if let shelf { TopShelfExporter.write(shelf) }
    }
}
