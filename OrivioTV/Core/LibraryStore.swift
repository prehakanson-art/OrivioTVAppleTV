import Foundation

/// A movie/show the user saved to their library. Mirrors the Android
/// `SavedLibraryItem` so it round-trips through `sync_push/pull_library`.
struct SavedLibraryItem: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String
    let background: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: Double?
    let genres: [String]
    let addonBaseURL: String?
    let addedAt: Date

    /// Stable storage key (a title can exist as both movie and series).
    var key: String { "\(type)|\(id)" }

    init(
        id: String, type: String, name: String,
        poster: String? = nil, posterShape: String = "POSTER",
        background: String? = nil, description: String? = nil,
        releaseInfo: String? = nil, imdbRating: Double? = nil,
        genres: [String] = [], addonBaseURL: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
        self.addonBaseURL = addonBaseURL
        self.addedAt = addedAt
    }

    init(meta: MetaItem) {
        self.init(
            id: meta.id,
            type: meta.type,
            name: meta.name,
            poster: meta.poster,
            posterShape: "POSTER",
            background: meta.background,
            description: meta.description,
            releaseInfo: meta.releaseInfo,
            imdbRating: meta.imdbRating.flatMap { Double($0) },
            genres: meta.genres ?? [],
            addonBaseURL: nil,
            addedAt: Date()
        )
    }

    static func shouldReplaceTitle(_ title: String, id: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == id { return true }
        if trimmed.hasPrefix("tt") && trimmed.dropFirst(2).allSatisfy(\.isNumber) { return true }
        return false
    }

    func withFallbackMetadata(_ meta: MetaItem) -> SavedLibraryItem {
        SavedLibraryItem(
            id: id,
            type: type,
            name: Self.shouldReplaceTitle(name, id: id) ? meta.name : name,
            poster: poster ?? meta.poster,
            posterShape: posterShape,
            background: background ?? meta.background,
            description: description ?? meta.description,
            releaseInfo: releaseInfo ?? meta.releaseInfo,
            imdbRating: imdbRating ?? meta.imdbRating.flatMap { Double($0) },
            genres: genres.isEmpty ? (meta.genres ?? []) : genres,
            addonBaseURL: addonBaseURL,
            addedAt: addedAt
        )
    }

    /// Reconstruct a `MetaItem` good enough to open the detail page.
    var metaItem: MetaItem {
        MetaItem(
            id: id, type: type, name: name,
            poster: poster, background: background,
            description: description, releaseInfo: releaseInfo,
            imdbRating: imdbRating.map { String(format: "%.1f", $0) },
            genres: genres.isEmpty ? nil : genres
        )
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [String: SavedLibraryItem] = [:]

    /// Called after a local change so account sync can push. Suppressed while
    /// merging remote data.
    var onLocalChange: (() -> Void)?
    /// Fired with the items the user explicitly removed, so account sync can
    /// record the removal DURABLY (a persisted pending-delete queue) instead of
    /// relying on the debounced replace-push landing before the next pull.
    /// Mirrors ProgressStore.onRemove / WatchedStore.onRemove — without it a
    /// removal lost to a killed app, an offline moment or an expired token was
    /// never represented anywhere, and the next pull re-added the item for good.
    var onRemove: (([SavedLibraryItem]) -> Void)?
    /// Tracking-service watchlist hooks, fired on a genuine local add /
    /// remove. Lists, not single closures — see the note in WatchedStore:
    /// Trakt and SIMKL both subscribe, and one property could only hold one.
    var onTrackerAdd: [(SavedLibraryItem) -> Void] = []
    var onTrackerRemove: [(SavedLibraryItem) -> Void] = []
    private var suppressChange = false

    /// Recently-removed keys → removal time. The library push is full-replace
    /// (no per-item delete RPC), so between removing an item and that push
    /// landing, a pull's snapshot still contains it — without this the 30s
    /// Home poll (which also pulls library) would resurrect the row the user
    /// just removed, and the next push would re-add it to the account.
    private var tombstones: [String: Date] = [:]
    private static let tombstoneGrace: TimeInterval = 180
    /// Grace protecting a freshly-added row whose replace-push is still in
    /// flight from the deletion reconcile below.
    private static let deletionGrace: TimeInterval = 120

    private func pruneTombstones() {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneGrace)
        tombstones = tombstones.filter { $0.value >= cutoff }
    }

    /// Reassert tombstones from outside — the sync manager calls this before a
    /// pull for removals whose replace-push hasn't landed yet, so a full
    /// snapshot can't resurrect them while the deletion is still outstanding.
    /// Renewing the timestamp keeps them protected for as long as that takes
    /// (the in-memory grace alone expires after 3 minutes, and is lost outright
    /// when the app restarts — which is how removals used to come back).
    func tombstone(_ keys: [String]) {
        let now = Date()
        for key in keys { tombstones[key] = now }
    }

    /// Read from the SAME key `ProfileStore` persists, so the scope is right
    /// from LAUNCH. The sync manager rescopes every store shortly after start,
    /// but defaulting to 1 here meant a device on any other profile decoded
    /// profile 1's blob on the main actor and then decoded the correct one a
    /// moment later — twice the launch cost, and a reload cascade on top.
    /// `RatingsStore` and `TraktStore` already do this.
    private static let activeProfileKey = "orivio.profiles.active"
    private var profileID = UserDefaults.standard.object(forKey: activeProfileKey) as? Int ?? 1
    private var storageKey: String {
        profileID == 1 ? "orivio.library.v1" : "orivio.library.v1.p\(profileID)"
    }

    init() { load() }

    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        // Tombstones belong to the profile being left — but they are its ONLY
        // protection against the Trakt/SIMKL/Stremio merges (which have no
        // delete queue) re-adding what it removed, so park them per profile
        // rather than dropping them.
        tombstonesByProfile[profileID] = tombstones
        profileID = id
        loadGeneration &+= 1   // invalidate any in-flight load; see clearAll
        suppressChange = true
        items = [:]
        tombstones = tombstonesByProfile[id] ?? [:]
        load()
        suppressChange = false
    }
    private var tombstonesByProfile: [Int: [String: Date]] = [:]

    // MARK: - Removed items (persisted, per profile)

    /// Items the user removed from the Library → when.
    ///
    /// The in-memory tombstone above lasts three minutes and dies with the
    /// process, and it is lifted whenever an incoming row's `addedAt` is
    /// newer. Both tracker merges build their rows with `addedAt` defaulted to
    /// NOW (they have no real added-date to carry), so a Trakt watchlist or
    /// SIMKL plan-to-watch pull lifted the tombstone on the very next sync and
    /// re-added the title the user had just removed — which `requestSyncPush`
    /// then propagated to the account and the other trackers. One removal,
    /// undone everywhere.
    ///
    /// So the removal is remembered here instead, and a merge may only lift it
    /// when the caller is TRUSTED — the Orivio account, whose `addedAt`
    /// round-trips as the real value, so "newer than the removal" genuinely
    /// means re-added on another device. A tracker echo never lifts it.
    /// Persisted per profile, never synced.
    private var removedItems: [String: Date] = [:]
    private var removedItemsKey: String {
        profileID == 1 ? "orivio.library.removed.v1" : "orivio.library.removed.v1.p\(profileID)"
    }
    /// A removal older than this has nothing left to block.
    private static let removalLife: TimeInterval = 180 * 24 * 60 * 60

    private func loadRemovedItems() {
        let raw = UserDefaults.standard.dictionary(forKey: removedItemsKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.removalLife).timeIntervalSince1970
        removedItems = raw.filter { $0.value > cutoff }.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveRemovedItems() {
        if removedItems.isEmpty {
            UserDefaults.standard.removeObject(forKey: removedItemsKey)
        } else {
            UserDefaults.standard.set(removedItems.mapValues { $0.timeIntervalSince1970 },
                                      forKey: removedItemsKey)
        }
    }

    private func recordRemoval(_ key: String) {
        removedItems[key] = Date()
        saveRemovedItems()
    }

    private func clearRemoval(_ key: String) {
        guard removedItems.removeValue(forKey: key) != nil else { return }
        saveRemovedItems()
    }

    /// The saved row for an id/type pair, if any.
    func item(id: String, type: String) -> SavedLibraryItem? {
        items["\(type)|\(id)"]
    }

    /// Saved items, newest first — the order the Library grid renders in.
    var sorted: [SavedLibraryItem] {
        items.values.sorted { $0.addedAt > $1.addedAt }
    }

    func contains(id: String, type: String) -> Bool {
        items["\(type)|\(id)"] != nil
    }

    func contains(_ meta: MetaItem) -> Bool { contains(id: meta.id, type: meta.type) }

    func toggle(_ meta: MetaItem) {
        if contains(meta) {
            remove(id: meta.id, type: meta.type)
        } else {
            add(SavedLibraryItem(meta: meta))
        }
    }

    func add(_ item: SavedLibraryItem) {
        // Re-saving something you'd removed clears its tombstone so the fresh
        // row survives the next pull's reconcile — and its persisted removal
        // record, or nothing would ever be allowed to sync it back.
        tombstones.removeValue(forKey: item.key)
        clearRemoval(item.key)
        let isNew = items[item.key] == nil
        items[item.key] = item
        save()
        if !suppressChange {
            if isNew { for hook in onTrackerAdd { hook(item) } }
            onLocalChange?()
        }
    }

    func remove(id: String, type: String) {
        let key = "\(type)|\(id)"
        guard let removed = items.removeValue(forKey: key) else { return }
        tombstones[key] = Date()
        // Remembered past the grace window and across launches, so a tracker
        // echo can't put it back (see `removedItems`).
        if !suppressChange { recordRemoval(key) }
        save()
        if !suppressChange {
            onRemove?([removed])
            for hook in onTrackerRemove { hook(removed) }
            onLocalChange?()
        }
    }

    // MARK: - Sync bridge

    /// Wipe this profile's rows outright.
    ///
    /// For an ACCOUNT SWITCH, where the resident data belongs to the user who
    /// just signed out. `tombstone: false` there: tombstones exist to stop a
    /// pull resurrecting something the user deleted, but on a switch they would
    /// instead suppress the INCOMING account's rows for the whole grace period.
    @discardableResult
    func clearAll(notify: Bool = true, tombstone: Bool = true) -> [SavedLibraryItem] {
        // Invalidate any in-flight async load: see ProgressStore.clearAllProgress.
        loadGeneration &+= 1
        let removed = Array(items.values)
        guard !removed.isEmpty else { return [] }
        if tombstone {
            let now = Date()
            for item in removed { tombstones[item.key] = now }
        } else {
            // Retiring the previous account: see ProgressStore.clearAllProgress.
            tombstones.removeAll()
            // The previous user's removals must not suppress the incoming
            // account's rows sharing those keys.
            removedItems.removeAll()
            saveRemovedItems()
        }
        items.removeAll()
        save()
        // Deliberately NOT firing onTrackerRemove: this clears local state, it is
        // not the user removing titles from their watchlist.
        if notify && !suppressChange { onLocalChange?() }
        return removed
    }

    func allForSync() -> [SavedLibraryItem] { Array(items.values) }

    /// A local backup restore: every row is adopted, INCLUDING titles the user
    /// had removed since (their tombstones are cleared, as `add` does) — the
    /// backup is the user's explicit word. Silent: no per-item tracker hooks
    /// (a big restore fanned out one Trakt/SIMKL POST per title); the caller
    /// pings `onLocalChange` once so the account push runs.
    func importItems(_ imported: [SavedLibraryItem]) {
        guard !imported.isEmpty else { return }
        suppressChange = true
        defer { suppressChange = false }
        for item in imported {
            tombstones.removeValue(forKey: item.key)
            clearRemoval(item.key)   // a restore is the user's explicit word
            if let local = items[item.key] {
                items[item.key] = local.withFallbackMetadata(item.metaItem)
            } else {
                items[item.key] = item
            }
        }
        save()
    }

    /// Merge a FULL remote snapshot. Two-way, mirroring Progress/Watched: rows
    /// from the account are added AND (when `reconcile`) local rows the server
    /// no longer has are removed — otherwise a removal made on another device
    /// resurrects here on the next pull, and this device's replace-push re-adds
    /// it to the account (the remove/re-add ping-pong). Freshly-added rows
    /// (grace) and tombstoned rows (removal's push still in flight) are
    /// protected. `reconcile: false` = additive union — used for the FIRST pull
    /// of a profile, so items saved locally before ever signing in survive and
    /// get pushed up rather than treated as remote deletions.
    /// - Parameter trusted: whether this source's `addedAt` is a REAL added
    ///   date that round-trips (the Orivio account), as opposed to one the
    ///   caller fabricated with `Date()` (every tracker merge). Only a trusted
    ///   source may lift a removal record — otherwise a Trakt watchlist or
    ///   SIMKL plan-to-watch echo, which always stamps NOW, would re-add the
    ///   title the user just removed on its very next sync.
    /// Returns whether anything changed — see `requestSyncPush`.
    @discardableResult
    func mergeRemote(_ remote: [SavedLibraryItem], reconcile: Bool = true,
                     trusted: Bool = false) -> Bool {
        suppressChange = true
        defer { suppressChange = false }
        var changed = false
        pruneTombstones()
        // id → keys index, built once (see the duplicate sweep below).
        var keysByID: [String: Set<String>] = [:]
        for (key, existing) in items { keysByID[existing.id, default: []].insert(key) }

        // ── Reconcile deletions ──
        if reconcile {
            let remoteKeys = Set(remote.map(\.key))
            let cutoff = Date().addingTimeInterval(-Self.deletionGrace)
            let staleKeys = items.compactMap { key, local in
                (!remoteKeys.contains(key) && local.addedAt < cutoff) ? key : nil
            }
            for key in staleKeys {
                items.removeValue(forKey: key)
                changed = true
            }
        }

        for item in remote {
            // The persisted removal outranks the in-memory tombstone: it
            // survives the 3-minute grace and a relaunch, and an untrusted
            // source can never lift it (see `removedItems`).
            if let removedAt = removedItems[item.key] {
                if trusted, item.addedAt > removedAt {
                    clearRemoval(item.key)   // genuinely re-saved on another device
                } else {
                    continue
                }
            }
            if let tomb = tombstones[item.key] {
                if item.addedAt > tomb {
                    tombstones.removeValue(forKey: item.key)   // re-saved elsewhere
                } else {
                    continue
                }
            }
            if let local = items[item.key] {
                let merged = local.withFallbackMetadata(item.metaItem)
                guard merged != local else { continue }
                items.removeValue(forKey: item.key)
                items[merged.key] = merged
            } else {
                // Indexed, not a scan: the per-item sweep over every key was
                // O(remote × items) on the main actor — millions of dictionary
                // probes on a first pull of a big watchlist, right after
                // sign-in, exactly when the app already feels slowest.
                for key in keysByID[item.id] ?? [] where key != item.key {
                    items.removeValue(forKey: key)
                }
                items[item.key] = item
                keysByID[item.id, default: []].insert(item.key)
            }
            changed = true
        }
        if changed { save() }
        return changed
    }

    /// Rows just merged from a tracker (Trakt watchlist, SIMKL plan-to-watch,
    /// the Stremio library) need to reach the ACCOUNT too — see the note on
    /// `WatchedStore.requestSyncPush`.
    func requestSyncPush() {
        guard !suppressChange else { return }
        onLocalChange?()
    }

    // MARK: - Persistence

    /// Bumped by `setProfile`/`clearAll`; an async `load()` checks it so it
    /// cannot repopulate `items` from a blob captured before an intentional
    /// clear. See `ProgressStore.loadGeneration`.
    private var loadGeneration = 0

    private func load() {
        loadRemovedItems()   // per profile, like the items themselves
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        // Decode OFF the main actor, publish when it lands — same rationale
        // and guards as WatchedStore.load(): store inits run serially on the
        // main thread before first frame, and a watchlist-scale library
        // decode was part of the A8's launch stall.
        let key = storageKey
        let expectedProfile = profileID
        let generation = loadGeneration
        Task.detached(priority: .userInitiated) {
            // `inflated` passes an uncompressed blob through untouched, so the
            // plain JSON older builds wrote still decodes. See StoreBlob.
            let decoded = try? JSONDecoder().decode([String: SavedLibraryItem].self,
                                                    from: StoreBlob.inflated(data))
            await MainActor.run { [weak self] in
                guard let self, self.profileID == expectedProfile,
                      self.loadGeneration == generation else { return }
                guard let decoded else {
                    UnreadableBlobGuard.preserve(data, key: key)   // see ProgressStore
                    return
                }
                if self.items.isEmpty {
                    self.items = decoded
                } else {
                    // A write beat the decode: keep the newer in-memory rows,
                    // fold the persisted ones in underneath, re-persist.
                    self.items.merge(decoded) { current, _ in current }
                    self.save()
                }
            }
        }
    }

    /// Monotonic stamps so overlapping detached writes land in order — PER
    /// storage key, or a profile switch's first save on the new profile would
    /// invalidate (and drop) the departing profile's last queued write.
    private var saveSequences: [String: UInt64] = [:]

    private func save() {
        // Encode + write OFF the main actor. Every other content store grew a
        // detached persister for exactly this stall; the library kept a
        // synchronous whole-collection encode on main, paid on every sync
        // pull that changed anything.
        let key = storageKey
        let sequence = (saveSequences[key] ?? 0) &+ 1
        saveSequences[key] = sequence
        let snapshot = items
        Task.detached(priority: .utility) { [weak self] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // Compressed: a large imported library is a key that can push the
            // whole defaults domain past the ~1 MB CFPreferences abort.
            let stored = StoreBlob.deflated(data)
            await MainActor.run {
                guard let self, self.saveSequences[key] == sequence else { return }
                UserDefaults.standard.set(stored, forKey: key)
            }
        }
    }
}
