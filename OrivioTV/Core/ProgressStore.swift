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
    /// How many episodes have aired SINCE this viewer started the show that
    /// they haven't watched — the "+2" badge on the Continue Watching card.
    ///
    /// Deliberately a count of NEW episodes, not of unwatched ones: a back
    /// catalogue that was already out when you started is not something you
    /// are "behind" on, so only episodes whose air date falls after your first
    /// watch of the show count. Optional so rows written before this existed
    /// (and rows from other clients) decode as "unknown", not "zero".
    ///
    /// Derived, never synced as a field: the backend stores no column for it,
    /// and it is a pure function of watch history (which DOES sync to the
    /// account, Trakt, SIMKL and Stremio) plus episode air dates, so every
    /// device arrives at the same number on its own.
    var newEpisodeCount: Int? = nil

    /// Whether to show the new-episode badge at all.
    var hasNewEpisode: Bool { (newEpisodeCount ?? 0) > 0 }

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
            newEpisodeCount: newEpisodeCount
        )
    }
}

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var items: [String: WatchProgress] = [:] {
        didSet { continueWatchingMemo.removeAll(keepingCapacity: true) }
    }

    /// Memoized `continueWatching(sortMode:)` results, cleared on any items
    /// change. The derivation builds a per-show dictionary and sorts, and
    /// Home's body touches it more than once per pass — one sort per mutation
    /// instead of several per render.
    private var continueWatchingMemo: [ContinueWatchingSortMode: [WatchProgress]] = [:]

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
        let shelfTicket = shelf == nil ? 0 : TopShelfExporter.nextSequence()
        Task.detached(priority: .utility) {
            await ProgressPersister.shared.write(snapshot, key: key, sequence: sequence,
                                                 shelf: shelf, shelfSequence: shelfTicket)
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
    /// metaID), so Trakt sync can delete the matching playback rows there too
    /// and the coordinator can kick a full sync. A LIST for the same reason as
    /// the WatchedStore hooks: more than one thing needs to hear it. Not fired
    /// for internal migrations (recanonicalize) — the title is still being
    /// watched, its key just changed.
    var onTrackerProgressRemove: [(String) -> Void] = []
    /// Fired with the metaID when a title leaves Continue Watching, so the
    /// Stremio sync can clear it THERE too. Stremio's continue watching is
    /// derived from each library item's playback state, and the push only
    /// carries rows that still exist locally — so without this a removal was
    /// invisible to Stremio and the card simply came back on the next pull.
    var onStremioClearProgress: ((String) -> Void)?
    /// Whether a row's episode was marked watched AFTER the row was last
    /// written (installed by the app from `WatchedStore`). Such a row is a
    /// stale copy of an episode the viewer has since finished, and no merge
    /// may put it back.
    ///
    /// Finishing retires the row here, but copies elsewhere outlive it: the
    /// account row the periodic pushes wrote, a Trakt playback row, Stremio's
    /// resume state. Each handed the episode back once the three-minute
    /// tombstone lapsed, at the position it had reached before the credits,
    /// and Continue Watching went back to an episode already watched. The
    /// watched mark is the record that outlives them all.
    var episodeWatchedAfter: ((WatchProgress) -> Bool)?
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
    /// Read from the SAME key `ProfileStore` persists, so the scope is right
    /// from LAUNCH. The sync manager rescopes every store shortly after start,
    /// but defaulting to 1 here meant a device on any other profile decoded
    /// profile 1's blob on the main actor and then decoded the correct one a
    /// moment later — twice the launch cost, and a reload cascade on top.
    /// `RatingsStore` and `TraktStore` already do this.
    private static let activeProfileKey = "orivio.profiles.active"
    private var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1
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
        clearRemoval(metaID: metaID)
        guard dismissedNextUpShows.remove(metaID) != nil else { return }
        if dismissedNextUpShows.isEmpty {
            UserDefaults.standard.removeObject(forKey: dismissedNextUpKey)
        } else {
            UserDefaults.standard.set(Array(dismissedNextUpShows), forKey: dismissedNextUpKey)
        }
    }

    // MARK: - Removed from Continue Watching (persisted, per profile)

    /// Shows the user removed from Continue Watching → when they removed them.
    ///
    /// The per-key tombstones above protect a removal for three minutes and
    /// die with the process. That is not enough, because a removal has to
    /// outlast every source that can hand the title back:
    ///
    /// * the ACCOUNT, when the server delete is still retrying, when an
    ///   in-flight push captured the row before the removal and re-upserted it
    ///   right after the delete landed, or when the key the server holds is
    ///   not one this device ever knew (another client keys episodes
    ///   differently);
    /// * TRAKT, whose playback-row delete runs concurrently with the full sync
    ///   the same removal kicks off — the pull can read the row before the
    ///   delete has gone through;
    /// * SIMKL, which cannot be told at all: it re-seeds "the next episode" of
    ///   every show in its watching bucket on every five-minute sync, so a
    ///   removed show came back on the first sync after the tombstone expired.
    ///
    /// So every merge path consults this: an incoming row for a removed show
    /// is dropped unless it is NEWER than the removal, which means the title
    /// was watched again elsewhere and the removal is over. Watching the show
    /// here clears it too. Persisted per profile (the `.p<id>` suffix is what
    /// a profile deletion sweeps), never synced — it is this device's memory of
    /// what its user asked for, and the other devices hear about the removal
    /// through the server delete.
    private var removedShows: [String: Date] = [:]
    private var removedShowsKey: String {
        profileID == 1 ? "orivio.progress.removedShows.v1" : "orivio.progress.removedShows.v1.p\(profileID)"
    }
    /// A removal older than this has nothing left to block — any row that
    /// still carries an older timestamp is stale beyond caring — so the map
    /// cannot grow without bound.
    private static let removalLife: TimeInterval = 180 * 24 * 60 * 60

    private func loadRemovedShows() {
        let raw = UserDefaults.standard.dictionary(forKey: removedShowsKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.removalLife).timeIntervalSince1970
        removedShows = raw.filter { $0.value > cutoff }
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveRemovedShows() {
        if removedShows.isEmpty {
            UserDefaults.standard.removeObject(forKey: removedShowsKey)
        } else {
            UserDefaults.standard.set(removedShows.mapValues { $0.timeIntervalSince1970 },
                                      forKey: removedShowsKey)
        }
    }

    private func recordRemoval(metaID: String, at date: Date = Date()) {
        removedShows[metaID] = date
        saveRemovedShows()
    }

    private func clearRemoval(metaID: String) {
        guard removedShows.removeValue(forKey: metaID) != nil else { return }
        saveRemovedShows()
    }

    /// Whether an incoming row is one the user removed and has not watched
    /// since. A row newer than the removal WITH real progress is a re-watch
    /// elsewhere: it lifts the removal and is accepted.
    ///
    /// The progress requirement is load-bearing: SIMKL's Continue Watching
    /// seeds are synthesized "start the next episode" rows at position 0, and
    /// their timestamp can fall back to now() when SIMKL reports no date — so
    /// without it the very source this record exists to block could lift the
    /// removal on its first sync.
    private func isBlockedByRemoval(_ entry: WatchProgress) -> Bool {
        guard let removedAt = removedShows[entry.metaID] else { return false }
        if entry.updatedAt > removedAt, entry.positionSeconds > 0 {
            clearRemoval(metaID: entry.metaID)
            return false
        }
        return true
    }

    /// How long after a removal this device may still DELETE matching rows on
    /// the account. Deliberately far shorter than `removalLife`.
    ///
    /// Suppressing a row locally is this device's own business and can last as
    /// long as the record does. Deleting it from the ACCOUNT reaches every
    /// other device, and the only evidence here is a timestamp comparison —
    /// which is not a reliable ordering signal: a Stremio import carries the
    /// ORIGINAL watch time, so a title legitimately re-added on a phone months
    /// later can arrive stamped older than the removal. Left unbounded, this
    /// device would keep deleting it from everyone's account for half a year.
    /// A week is long enough to converge an account that was simply offline.
    private static let removalDeleteWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The keys of `remote` rows a removal would block, WITHOUT lifting any
    /// removal. The sync manager asks this of a server snapshot so it can
    /// queue those keys for deletion: hiding them here is not enough, the
    /// account has to converge too or every other device keeps the card.
    /// Bounded by `removalDeleteWindow` — see above.
    func remoteKeysBlockedByRemoval(_ remote: [WatchProgress]) -> [String] {
        let deleteCutoff = Date().addingTimeInterval(-Self.removalDeleteWindow)
        return remote.compactMap { entry in
            guard let removedAt = removedShows[entry.metaID],
                  entry.updatedAt <= removedAt,
                  removedAt >= deleteCutoff else { return nil }
            return entry.id
        }
    }

    private static let maxProgressSeconds: Double = 30 * 24 * 60 * 60

    private nonisolated static func sanitized(_ entry: WatchProgress) -> WatchProgress? {
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
        // The removal tombstones belong to the profile being left — carried
        // over, a title profile A just removed was skipped from profile B's
        // first pull for the whole grace window. Parked per profile rather
        // than dropped: they are the only guard the Trakt/Stremio merges have
        // against re-adding what that profile removed.
        tombstonesByProfile[profileID] = tombstones
        profileID = id
        suppressChange = true
        items = [:]
        // The in-playback overrides belong to the profile we are LEAVING. Left
        // in place, the next save/push folds them into the new profile's data.
        transientOverrides.removeAll()
        tombstones = tombstonesByProfile[id] ?? [:]
        externallyMerged.removeAll()
        awaitingServerAck.removeAll()
        load()   // also re-reads this profile's removal record
        suppressChange = false
    }
    private var tombstonesByProfile: [Int: [String: Date]] = [:]

    /// Re-export the Top Shelf snapshot without touching stored progress.
    /// Needed when something OTHER than progress changes what may be shown —
    /// today, a profile's PIN being switched on or off, which changes whether
    /// this profile's Continue Watching may appear on the home screen at all.
    /// Without this the shelf kept the pre-PIN rows until the next playback
    /// save or relaunch.
    func refreshTopShelf() {
        let shelf = TopShelfExporter.entries(from: continueWatching)
        let ticket = TopShelfExporter.nextSequence()
        Task.detached(priority: .utility) { await TopShelfExporter.writeOrdered(shelf, sequence: ticket) }
    }

    /// All entries, for a full push to the account backend.
    func allForSync() -> [WatchProgress] { Array(items.values) }

    /// The key the ACCOUNT stores a row under.
    ///
    /// Nuvio Sync names an episode `<metaID>_s<season>e<episode>` — the phone
    /// app, the Android TV app and the reference tvOS client all key it that
    /// way — while this store keys a row by the add-on's video id
    /// (`tt123:2:2`), which is what the player, the details page and the
    /// tracker merges look rows up by. Pushed, deleted and pulled under the
    /// local key, the two never met: a pull never returned the `:2:2` row, so
    /// the reconcile dropped what the player had just saved and kept the
    /// account's older `_s2e2` copy, and a delete sent as `:2:2` deleted
    /// nothing, so a finished episode came straight back. A movie (or any row
    /// without a season and episode) has the same key on both sides.
    nonisolated static func accountProgressKey(for row: WatchProgress) -> String {
        guard let season = row.season, let episode = row.episode else { return row.id }
        return "\(row.metaID)_s\(season)e\(episode)"
    }

    /// Every key, local and account form, that a row still in the store
    /// answers to — published rows and periodic in-playback ones alike.
    func accountKeysHeld() -> Set<String> {
        var held = Set<String>()
        for row in items.values {
            held.insert(row.id)
            held.insert(Self.accountProgressKey(for: row))
        }
        for row in transientOverrides.values {
            held.insert(row.id)
            held.insert(Self.accountProgressKey(for: row))
        }
        return held
    }

    /// What to delete on the ACCOUNT for rows that have just left this store:
    /// each row's own key and the account's name for it.
    ///
    /// Nothing is sent for an episode that a row still in the store stands
    /// for — a duplicate collapsed onto its survivor, a key migrated in place.
    /// The account holds one row per episode, so deleting the retired key's
    /// account name deleted the SURVIVOR's row: resuming a synced episode from
    /// Continue Watching did exactly that, and when the viewer left before the
    /// player saved again, the episode vanished and the card fell back to an
    /// earlier one. Call after the rows are gone from `items`.
    private func accountDeleteKeys(for removed: [WatchProgress]) -> [String] {
        let held = accountKeysHeld()
        var keys: [String] = []
        for row in removed {
            let accountKey = Self.accountProgressKey(for: row)
            guard !held.contains(accountKey) else { continue }
            for key in [row.id, accountKey] where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    /// The same row under another key. `WatchProgress.id` is a `let`, so a
    /// key change means rebuilding it, every field carried.
    private static func rekeyed(_ row: WatchProgress, to id: String) -> WatchProgress {
        WatchProgress(
            id: id, metaID: row.metaID, type: row.type, name: row.name,
            poster: row.poster, background: row.background, logo: row.logo,
            season: row.season, episode: row.episode, episodeTitle: row.episodeTitle,
            episodeThumbnail: row.episodeThumbnail,
            positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds,
            streamURL: row.streamURL, streamSignature: row.streamSignature,
            updatedAt: row.updatedAt,
            syncSource: row.syncSource,
            newEpisodeCount: row.newEpisodeCount
        )
    }

    /// Sources whose rows are real, syncable Continue Watching — as opposed to
    /// a device-local scratch row. A row whose source is NOT in this set is
    /// dropped by `removeLocalOnlyProgress`, never uploaded to the account,
    /// and not preserved by a first-pull snapshot merge.
    ///
    /// `"simkl"` was missing here for as long as the SIMKL manager has been
    /// seeding Continue Watching. Every card it produced was invisible to the
    /// account push AND deleted outright by the next Stremio tick (which calls
    /// `removeLocalOnlyProgress` on every successful sync) — so SIMKL cards
    /// appeared, vanished within thirty seconds, came back on SIMKL's next
    /// five-minute sync, and never reached any other device.
    private static let serviceSyncSources: Set<String> = ["local", "nuvio", "stremio", "trakt", "simkl"]

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
            // A row for a show the user removed is never uploaded again — the
            // periodic override of the title that was playing when they
            // removed it, or a row an external merge slipped in, would
            // otherwise re-create on the server what the delete just retired.
            if let removedAt = removedShows[item.metaID], item.updatedAt <= removedAt { return false }
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
            // A restore is the user's explicit word: it overrides a removal.
            clearRemoval(metaID: entry.metaID)
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
            newEpisodeCount: entry.newEpisodeCount ?? local.newEpisodeCount
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
        let staleRemovalTime = Date()
        for id in staleIDs {
            items.removeValue(forKey: id)
            // Same reason as remove()/removeShow()/collapseDuplicateEpisodes():
            // the reconciled-away key can be the one CURRENTLY PLAYING, whose
            // live position lives only in `transientOverrides` (playback
            // publishes to `items` at start and exit only, while the periodic
            // save runs every ten seconds — so the `items` row ages past the
            // deletion grace mid-film and qualifies here). Left behind, the
            // override is folded straight back onto disk by `save()` and
            // re-pushed by `serviceBackedForSync()`: the card the user is
            // watching vanished from Continue Watching mid-playback and came
            // back on the next launch. Tombstone it as every other removal
            // path does so nothing resurrects it inside the grace window.
            transientOverrides.removeValue(forKey: id)
            tombstones[id] = staleRemovalTime
            changed = true
        }

        for rawEntry in remote {
            guard let entry = Self.sanitized(rawEntry) else { continue }
            if isBlockedByRemoval(entry) { continue }
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
            // The row CURRENTLY PLAYING: its live position rides
            // `transientOverrides` (published to `items` only at start/exit,
            // by design — a publish re-renders Home behind the player). The
            // server row here is usually the ECHO of the position this device
            // pushed thirty seconds ago, and upserting it into `items` was
            // republishing the whole Home tree mid-film at sync cadence —
            // the periodic playback hiccup, reintroduced via the round trip.
            if let transient = transientOverrides[entry.id],
               transient.updatedAt >= entry.updatedAt { continue }
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

    /// Drop every row a given sync source contributed (a Stremio account
    /// switch retiring the previous account's Continue Watching). No
    /// tombstones and no callbacks: the rows are not being removed by the
    /// user, and the incoming account's copies must not be blocked.
    func removeRows(syncSource source: String) {
        suppressChange = true
        defer { suppressChange = false }
        let next = items.filter { _, item in item.syncSource != source }
        guard next.count != items.count else { return }
        for id in items.keys where next[id] == nil {
            transientOverrides.removeValue(forKey: id)
        }
        items = next
        save()
    }

    func removeLocalOnlyProgress() {
        let next = items.filter { _, item in
            guard let source = item.syncSource else { return false }
            return Self.serviceSyncSources.contains(source)
        }
        guard next.count != items.count else { return }
        // Retire the periodic in-playback rows of the keys being dropped, like
        // every other removal path — otherwise `save()` folds a purged row
        // straight back onto disk from `transientOverrides`. No tombstone here:
        // unlike the reconcile-deletes, this is a local filter that runs either
        // side of a Stremio merge, and tombstoning would block that merge from
        // (re)adding the same key for the whole grace window.
        for id in items.keys where next[id] == nil {
            transientOverrides.removeValue(forKey: id)
        }
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
        pruneTombstones()

        // A local row for the same EPISODE under another key is the same row,
        // not a second one. Rows pulled before the account keys were translated
        // sit here under the account's `_sXeY` form, and a tracker or another
        // client can key an episode its own way. Matched by key alone, the
        // pulled row landed beside them without their title, still or stream
        // signature, and the leftover was dropped as absent from the server.
        // Newest row per episode, ties broken on the key.
        var localByEpisode: [String: WatchProgress] = [:]
        for row in items.values where row.season != nil && row.episode != nil {
            let identity = Self.identity(of: row)
            if let held = localByEpisode[identity],
               (held.updatedAt, held.id) >= (row.updatedAt, row.id) { continue }
            localByEpisode[identity] = row
        }
        // Local rows folded into a pulled row under another key. They must not
        // also survive beside it through the keep rules below.
        var mergedLocalIDs = Set<String>()

        var next: [String: WatchProgress] = [:]
        for entry in sanitizedRemote {
            // A show the user removed stays removed until it is watched again
            // somewhere — see `removedShows`.
            if isBlockedByRemoval(entry) { continue }
            // Respect tombstones exactly as `mergeRemote` does. This path used
            // to ignore them entirely, so a row whose server delete was still
            // retrying came straight back on the next pull and the card the
            // user had just removed reappeared on screen. A remote row NEWER
            // than our removal means it was re-watched elsewhere afterwards —
            // honour that and drop the tombstone.
            if let tomb = tombstones[entry.id] {
                if entry.updatedAt > tomb {
                    tombstones.removeValue(forKey: entry.id)
                } else {
                    continue
                }
            }
            // The row CURRENTLY PLAYING: its live position rides
            // `transientOverrides`, and the pulled row is the echo of what this
            // device pushed moments ago. Adopting it republished Home behind the
            // player at every pull — the rule `mergeRemote` already follows.
            // Only for a row `items` already holds: one it lacks is adopted as
            // before, or a session that ended without publishing (an exit in
            // the middle of a source switch) stayed off the row until relaunch.
            if let local = items[entry.id], let transient = transientOverrides[entry.id],
               transient.updatedAt >= entry.updatedAt {
                next[entry.id] = local
                continue
            }
            let local = items[entry.id]
                ?? (entry.season != nil && entry.episode != nil
                    ? localByEpisode[Self.identity(of: entry)] : nil)
            var merged = entry
            if let local {
                if local.id != entry.id { mergedLocalIDs.insert(local.id) }
                // Newest side wins, same comparison `mergeRemote` uses. This path
                // was remote-always-wins: it adopted the server's position AND its
                // timestamp unconditionally, so with any clock skew (or a snapshot
                // captured before our push landed) an OLDER remote row overwrote a
                // newer local resume point and playback jumped backwards.
                if local.updatedAt >= entry.updatedAt {
                    merged = local.id == entry.id ? local : Self.rekeyed(local, to: entry.id)
                } else {
                    merged = coalesced(remote: entry, local: local)
                }
            }
            // The episode was finished after this row was last written: a stale
            // copy the account still holds (see `episodeWatchedAfter`).
            if episodeWatchedAfter?(merged) == true { continue }
            next[entry.id] = merged
        }
        for id in awaitingServerAck where !mergedLocalIDs.contains(id) {
            if let local = items[id], Self.sanitized(local) != nil {
                next[id] = local
            }
        }
        if preserveLocalAdditions {
            for (id, local) in items where next[id] == nil && !mergedLocalIDs.contains(id) {
                guard Self.sanitized(local) != nil,
                      let source = local.syncSource,
                      Self.serviceSyncSources.contains(source) else { continue }
                next[id] = local
            }
        }
        // The same deletion grace `mergeRemote` grants: a row updated in the
        // last two minutes may simply not have reached the server yet (its
        // push is in flight). Dropping it here — and tombstoning it — hid the
        // title just watched from Continue Watching until the tombstone
        // expired, three minutes later.
        let graceCutoff = Date().addingTimeInterval(-Self.deletionGrace)
        for (id, local) in items where next[id] == nil && !mergedLocalIDs.contains(id) {
            guard local.updatedAt >= graceCutoff, Self.sanitized(local) != nil else { continue }
            next[id] = local
        }

        guard next != items else { return }
        // Rows this snapshot drops need the same cleanup every other removal
        // path performs. Without it the dropped key's periodic in-playback row
        // stayed in `transientOverrides` and `save()` folded it right back onto
        // disk — the title the user was watching disappeared from Continue
        // Watching mid-playback and returned after a relaunch.
        let droppedTime = Date()
        for id in items.keys where next[id] == nil {
            transientOverrides.removeValue(forKey: id)
            tombstones[id] = droppedTime
        }
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
                newEpisodeCount: existing.newEpisodeCount
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
        let now = Date()
        var loserRows: [WatchProgress] = []
        for key in losers {
            if let row = items.removeValue(forKey: key) { loserRows.append(row) }
            // The losing key may be the one currently playing, whose periodic
            // row lives only in `transientOverrides`. Left behind, `save()`
            // folds it straight back onto disk and the push re-uploads it right
            // after `onRemove` asked the server to delete it — the duplicate
            // card returns on the next launch.
            transientOverrides.removeValue(forKey: key)
            tombstones[key] = now
        }
        save()
        if !suppressChange {
            // Delete the dropped keys from the account as well, or the next
            // pull hands the duplicate straight back — except where the account
            // row IS the survivor's, which is every same-episode pair: the
            // account holds one row per episode, and deleting it there took the
            // episode off the account until the next push restored it.
            let accountKeys = accountDeleteKeys(for: loserRows)
            if !accountKeys.isEmpty { onRemove?(accountKeys) }
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
            // Trakt's playback list and SIMKL's watching bucket both hand a
            // removed show straight back; the removal record is what makes
            // "Remove from Continue Watching" stick against them.
            if isBlockedByRemoval(entry) { continue }
            // A playback row or resume state written before the episode was
            // finished: Trakt keeps the row when the stop scrobble never
            // reached it, Stremio keeps its state until something replaces it.
            if episodeWatchedAfter?(entry) == true { continue }
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
        if let memo = continueWatchingMemo[sortMode] { return memo }
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
        let result: [WatchProgress]
        switch sortMode {
        case .recentlyWatched:
            result = byRecency
        case .streamingStyle:
            let inProgress = byRecency.filter { $0.fraction >= 0.02 }
            let fresh = byRecency.filter { $0.fraction < 0.02 }
            result = inProgress + fresh
        }
        continueWatchingMemo[sortMode] = result
        return result
    }

    func progress(for key: String) -> WatchProgress? {
        items[key]
    }

    static func key(metaID: String, video: MetaVideo?) -> String {
        guard let video else { return metaID }
        return video.id
    }

    /// Retire this episode from Continue Watching and record it as watched.
    ///
    /// Extracted from `update`'s 95% branch so the PLAYER can call it directly.
    /// Position is not the only thing that means "done with this episode": the
    /// Up Next card arms at the credits chapter, which on a show with long
    /// credits is well under 95%, so advancing from the card left the outgoing
    /// episode sitting in Continue Watching at whatever fraction the credits
    /// happened to start at — and the viewer came back to a card offering the
    /// episode they had just finished, at its last saved position.
    ///
    /// `save` is false for the in-`update` caller, which saves once at the end
    /// of its own body.
    func markFinished(meta: MetaItem, video: MetaVideo?, save shouldSave: Bool = true) {
        let key = Self.key(metaID: meta.id, video: video)
        // Finishing an episode is watching the show, so it lifts a previous
        // "remove from Continue Watching" just as an in-progress save does.
        // Without this, removing a show and later watching a new episode
        // straight through left the dismissal in place for good and Next Up
        // never offered that show again.
        clearNextUpDismissal(metaID: meta.id)
        // Every row that IS this episode, not only the one under the player's
        // key: a copy under another key (the account's `_sXeY`, a tracker's)
        // kept the finished episode on the row at its old position.
        //
        // And a row that exists only as a periodic save counts as removed. An
        // episode played straight through to the Up Next card is never
        // published to `items`, so this used to find nothing to remove — no
        // tombstone, no account delete — while the periodic pushes had already
        // put its credits-time position on the account, and the next pull
        // brought the finished episode back.
        var finished: [String: WatchProgress] = [:]
        if let row = items[key] ?? transientOverrides[key] { finished[key] = row }
        if let season = video?.season, let episode = video?.episode {
            for (rowKey, row) in items
            where row.metaID == meta.id && row.season == season && row.episode == episode {
                finished[rowKey] = row
            }
            for (rowKey, row) in transientOverrides
            where finished[rowKey] == nil
                && row.metaID == meta.id && row.season == season && row.episode == episode {
                finished[rowKey] = row
            }
        }
        let finishedAt = Date()
        for rowKey in finished.keys {
            items.removeValue(forKey: rowKey)
            // Retire the periodic row too. Without this, `save()` folds it back
            // into the snapshot and the finished title returns to Continue
            // Watching on the next launch — and `serviceBackedForSync()` pushes it
            // back to the account right after `onRemove` asked for a delete.
            transientOverrides.removeValue(forKey: rowKey)
            tombstones[rowKey] = finishedAt
        }
        if !suppressChange {
            if !finished.isEmpty { onRemove?(accountDeleteKeys(for: Array(finished.values))) }
            onFinished?(meta, video)
        }
        if shouldSave {
            self.save()
            if !suppressChange { onLocalUpdate?() }
        }
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
            markFinished(meta: meta, video: video, save: false)
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
        // And the show-level removal: this row is newer than any removal, and
        // `serviceBackedForSync` would otherwise refuse to upload it.
        clearRemoval(metaID: meta.id)
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
        guard let row = items.removeValue(forKey: id) else { return }
        transientOverrides.removeValue(forKey: id)
        tombstones[id] = Date()
        // Deliberately NO show-level removal record here: this path's callers
        // are internal cleanups (dropping the optimistic row after an external
        // player failed to start). The user-facing "Remove from Continue
        // Watching" goes through `removeShow`, which does record.
        save()
        if !suppressChange {
            onRemove?(accountDeleteKeys(for: [row]))
            onLocalUpdate?()
        }
    }

    /// - Returns: the keys to delete on the account for everything cleared (see
    ///   `accountDeleteKeys`).
    @discardableResult
    func clearAllProgress(notify: Bool = true, tombstone: Bool = true) -> [String] {
        let removedKeys = Array(items.keys)
        let removedRows = Array(items.values)
        // The Next Up dismissals are this profile's state too, and on an account
        // switch they would keep suppressing shows for a user who never removed
        // them. Cleared even when there are no rows to remove.
        if !tombstone {
            if !dismissedNextUpShows.isEmpty {
                dismissedNextUpShows = []
                UserDefaults.standard.removeObject(forKey: dismissedNextUpKey)
            }
            // The memory of what the PREVIOUS account deleted must go too, or it
            // suppresses the incoming account's rows sharing those keys for the
            // whole grace period.
            tombstones.removeAll()
            externallyMerged.removeAll()
            awaitingServerAck.removeAll()
            // Likewise the previous user's Continue Watching removals.
            removedShows.removeAll()
            saveRemovedShows()
        }
        guard !removedKeys.isEmpty else { return [] }
        let now = Date()
        // On an account switch tombstoning would suppress the INCOMING
        // account's rows locally for the whole 180s grace.
        if tombstone {
            for key in removedKeys { tombstones[key] = now }
        }
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
        let accountKeys = accountDeleteKeys(for: removedRows)
        if notify && !suppressChange {
            onRemove?(accountKeys)
            onLocalUpdate?()
        }
        return accountKeys
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
        // A row already under the canonical key that is NEWER is the better
        // copy — the migration must not roll it back to this older one.
        let canonicalIsNewer = items[newID].map { $0.updatedAt > existing.updatedAt } ?? false
        if !canonicalIsNewer {
            // Carry episodeThumbnail and newEpisodeCount too: rebuilding without them
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
                newEpisodeCount: existing.newEpisodeCount
            )
        }
        save()
        if !suppressChange {
            // Delete the stale tmdb: key server-side. Nothing is deleted when the
            // account names both keys' row the same (`_s2e2` → `tt…:2:2`): that
            // row IS the canonical entry, and deleting it on the way into the
            // player took the episode off the account — so leaving before the
            // player saved again dropped it and the card fell back to an
            // earlier episode.
            let accountKeys = accountDeleteKeys(for: [existing])
            if !accountKeys.isEmpty { onRemove?(accountKeys) }
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
        if !suppressChange {
            dismissNextUp(metaID: metaID)
            // Remembered past the tombstone grace and across launches, so no
            // source can hand the show back until it is watched again.
            recordRemoval(metaID: metaID)
        }
        let removedRows = items.values.filter { $0.metaID == metaID }
        let removedKeys = removedRows.map(\.id)
        guard !removedKeys.isEmpty else {
            if !suppressChange {
                onRemove?([metaID])
                if notifyTrakt { for hook in onTrackerProgressRemove { hook(metaID) } }
                onStremioClearProgress?(metaID)
                onLocalUpdate?()
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
            onRemove?(accountDeleteKeys(for: removedRows))
            if notifyTrakt { for hook in onTrackerProgressRemove { hook(metaID) } }
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
        // Ties broken by (updatedAt, id), matching `continueWatching` exactly.
        // With `existing.0 >= item.updatedAt` the winner among equal timestamps
        // was whichever row the (unordered) dictionary happened to yield first,
        // while the Continue Watching card picked the highest id — so for
        // batch-imported rows sharing a timestamp (a Trakt history import
        // stamps hundreds within the same moment) a poster's progress bar
        // showed a DIFFERENT episode's fraction than the card for that show.
        var latest: [String: (updatedAt: Date, id: String, fraction: Double)] = [:]
        for item in items.values where item.fraction < 0.95 {
            if let existing = latest[item.metaID],
               (existing.updatedAt, existing.id) >= (item.updatedAt, item.id) { continue }
            latest[item.metaID] = (item.updatedAt, item.id, item.fraction)
        }
        continueFractions = latest.mapValues { $0.fraction }
    }

    private func load() {
        dismissedNextUpShows = Set(UserDefaults.standard.stringArray(forKey: dismissedNextUpKey) ?? [])
        loadRemovedShows()
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            items = [:]
            finishLoadHousekeeping()
            return
        }
        // Decode + sanitize OFF the main actor, publish when it lands — same
        // rationale and race guards as WatchedStore.load(): the content
        // stores' init-time decodes ran serially on the main thread before
        // first frame, the dominant launch cost on the A8.
        let key = storageKey
        let expectedProfile = profileID
        Task.detached(priority: .userInitiated) {
            let decoded = try? JSONDecoder().decode([String: WatchProgress].self, from: data)
            let sanitized = decoded.map { raw in
                raw.compactMapValues { Self.sanitized($0) }
                    .filter { _, item in item.syncSource != nil }
            }
            await MainActor.run { [weak self] in
                guard let self, self.profileID == expectedProfile else { return }
                guard let decoded, let sanitized else {
                    // An UNREADABLE blob is not an empty one. Treating it as
                    // empty let the first save overwrite the whole history
                    // with one row (and the deletion reconcile then removed
                    // the rest from the account). Keep the bytes recoverable
                    // before anything writes over them.
                    UnreadableBlobGuard.preserve(data, key: key)
                    if self.items.isEmpty { self.items = [:] }
                    self.finishLoadHousekeeping()
                    return
                }
                var needsSave = sanitized.count != decoded.count
                if self.items.isEmpty {
                    self.items = sanitized
                } else {
                    // A write beat the decode (an early playback save, a fast
                    // merge): keep the newer in-memory rows, fold the
                    // persisted ones in underneath, re-persist the union.
                    self.items.merge(sanitized) { current, _ in current }
                    needsSave = true
                }
                // save() redoes the fraction rebuild + Top Shelf export.
                if needsSave { self.save() } else { self.finishLoadHousekeeping() }
            }
        }
    }

    /// The post-load bookkeeping the old synchronous `load()` ran in a defer:
    /// rebuild the fraction index and refresh the Top Shelf snapshot so the
    /// tvOS home shelf reflects Continue Watching immediately (save() only
    /// fires during playback).
    private func finishLoadHousekeeping() {
        rebuildContinueFractions()
        let shelf = TopShelfExporter.entries(from: continueWatching)
        let ticket = TopShelfExporter.nextSequence()
        Task.detached(priority: .utility) { await TopShelfExporter.writeOrdered(shelf, sequence: ticket) }
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
    /// Per STORAGE KEY, not global. One counter compared across different
    /// profiles' keys meant a burst of writes to several profiles — which is
    /// exactly what an account switch does — could drop a whole profile's write
    /// as "out of order" when it was simply for a different key, silently
    /// leaving that profile's history on disk.
    private var lastSequence: [String: UInt64] = [:]

    func write(_ snapshot: [String: WatchProgress], key: String,
               sequence: UInt64, shelf: [TopShelfExporter.Entry]?,
               shelfSequence: UInt64) async {
        guard sequence > (lastSequence[key] ?? 0) else { return }
        lastSequence[key] = sequence
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if let shelf { await TopShelfExporter.writeOrdered(shelf, sequence: shelfSequence) }
    }
}

/// A persisted blob that no longer decodes must not be mistaken for "nothing
/// saved": the next save would overwrite it and the history is gone. Copy the
/// raw bytes aside (once) under `<key>.unreadable` so they stay recoverable.
enum UnreadableBlobGuard {
    /// Copies go to a FILE under Application Support, not back into the
    /// defaults domain: doubling a large blob there would push the domain
    /// toward the CFPreferences size abort the collections store already met.
    /// One copy per key, kept until a human looks at it.
    static func preserve(_ data: Data, key: String) {
        // CACHES, not Application Support: tvOS does not provide an
        // Application Support directory, so this whole guard was writing into
        // a path that never existed and silently preserved NOTHING — on every
        // store that relies on it (progress, watched, library, ratings, home
        // layout). Caches is the same directory CollectionsStore moved its
        // library to for exactly this reason.
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        let dir = base.appendingPathComponent("orivio-unreadable", isDirectory: true)
        let file = dir.appendingPathComponent(key + ".json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: file, options: .atomic)
            NSLog("[OrivioStore] %@ did not decode (%d bytes) — kept a copy at %@",
                  key, data.count, file.path)
        } catch {
            NSLog("[OrivioStore] %@ did not decode and the copy failed: %@", key, String(describing: error))
        }
    }
}
