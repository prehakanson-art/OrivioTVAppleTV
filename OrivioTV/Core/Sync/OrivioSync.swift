import Foundation

/// Orivio account sync (§9.1), wire-compatible with Android.
///
/// Rules that keep stores from clobbering each other:
/// - Every store pushes on a ~1.3 s debounce after a local change (dirty flag,
///   persisted per profile) and every pull is a full snapshot — so a dirty
///   store is **always flushed before its pull**.
/// - An empty pull from an account that has never held this store's data
///   ("unseeded") is a fresh account, not "deleted everything elsewhere".
/// - Deletions travel as persisted tombstones; remote rows a tombstone blocks
///   are deleted on the account, and the tombstone retires once a pull no
///   longer returns the id.
@MainActor
final class OrivioSync {
    static let shared = OrivioSync()

    private let account = OrivioAccount.shared
    private let stores = AppStores.shared
    private var pushTasks: [SyncKind: Task<Void, Never>] = [:]
    private var pulledThisSession: Set<String> = []
    private var running = false

    /// Stable per-device id so the backend can avoid echoing our own writes.
    let clientID: String = {
        let key = "orivio.sync.client.v1"
        if let id = Persistence.string(forKey: key) { return id }
        let id = UUID().uuidString
        Persistence.set(id, forKey: key)
        return id
    }()

    var onError: ((String?) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(forName: .orivioSyncDirty, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?["kind"] as? String, let kind = SyncKind(rawValue: raw),
                  let profile = note.userInfo?["profile"] as? Int else { return }
            Task { @MainActor in self?.schedulePush(kind, profile: profile) }
        }
    }

    private var pid: Int { ProfileScope.current }

    // MARK: Seeded flags

    private func seededKey(_ k: SyncKind, _ p: Int) -> String { Persistence.key("sync.seeded.\(k.rawValue).v1", profile: p) }
    private func isSeeded(_ k: SyncKind, _ p: Int) -> Bool { Persistence.bool(forKey: seededKey(k, p)) }
    private func setSeeded(_ k: SyncKind, _ p: Int) { Persistence.set(true, forKey: seededKey(k, p)) }

    /// Signing into a *different* account wipes resident per-profile content first.
    func accountChanged(to userID: String) {
        let key = "orivio.account.lastUser.v1"
        let last = Persistence.string(forKey: key)
        defer { Persistence.set(userID, forKey: key) }
        guard let last, last != userID else { return }
        SyncSignals.applyingRemote {
            stores.progress.clearAll()
            stores.watched.applyRemote([])
            stores.library.applyRemote([])
            stores.collections.applyRemote([])
        }
        for p in stores.profiles.profiles.map(\.id) + [1] {
            for k in SyncKind.allCases {
                SyncSignals.clearDirty(k, profile: p)
                Persistence.set(nil, forKey: seededKey(k, p))
            }
        }
        pulledThisSession = []
    }

    func signedOut() {
        pushTasks.values.forEach { $0.cancel() }
        pushTasks = [:]
        pulledThisSession = []
    }

    // MARK: Debounced pushes

    private func schedulePush(_ kind: SyncKind, profile: Int) {
        guard account.isSignedIn else { return }
        pushTasks[kind]?.cancel()
        pushTasks[kind] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, !Task.isCancelled, profile == self.pid || !kind.isProfileScoped else { return }
            do {
                try await self.push(kind, profile: profile)
                self.onError?(nil)
            } catch {
                self.report(error)
            }
        }
    }

    private func push(_ kind: SyncKind, profile p: Int) async throws {
        switch kind {
        case .profiles: try await pushProfiles()
        case .addons: try await pushAddons(p)
        case .watchProgress: try await pushProgress(p)
        case .watched: try await pushWatched(p)
        case .library: try await pushLibrary(p)
        case .collections: try await pushCollections(p)
        case .homeCatalog: try await pushHomeCatalog(p)
        case .profileSettings: try await pushSettingsBlob(p)
        case .providerCredentials: try await pushCredentials(p)
        case .plugins: break
        }
    }

    // MARK: Full sync

    /// Per-store chains run concurrently; each flushes its dirty flag before its pull.
    /// `light` (during playback): dirty flushes + progress/library/watched pulls only.
    func syncNow(light: Bool = false) async {
        guard account.isSignedIn, !running else { return }
        running = true
        defer { running = false }
        let p = pid
        var errors: [Error] = []
        func run(_ body: @escaping () async throws -> Void) async { do { try await body() } catch { errors.append(error) } }
        await withTaskGroup(of: Void.self) { g in
            if !light {
                g.addTask { await run { try await self.chainProfiles() } }
                g.addTask { await run { try await self.chain(.addons, p, push: self.pushAddons, pull: self.pullAddons) } }
                g.addTask { await run { try await self.chain(.collections, p, push: self.pushCollections, pull: self.pullCollections) } }
                g.addTask { await run { try await self.chain(.homeCatalog, p, push: self.pushHomeCatalog, pull: self.pullHomeCatalog) } }
                g.addTask { await run { try await self.chain(.profileSettings, p, push: self.pushSettingsBlob, pull: self.pullSettingsBlob) } }
                g.addTask { await run { try await self.chain(.providerCredentials, p, push: self.pushCredentials, pull: self.pullCredentials) } }
            }
            g.addTask { await run { try await self.chain(.watchProgress, p, push: self.pushProgress, pull: self.pullProgress) } }
            g.addTask { await run { try await self.chain(.watched, p, push: self.pushWatched, pull: self.pullWatched) } }
            g.addTask { await run { try await self.chain(.library, p, push: self.pushLibrary, pull: self.pullLibrary) } }
        }
        if let e = errors.first { report(e) } else { onError?(nil) }
    }

    private func chain(_ kind: SyncKind, _ p: Int, push: (Int) async throws -> Void, pull: (Int) async throws -> Void) async throws {
        if SyncSignals.isDirty(kind, profile: p) { try await push(p) }
        guard p == pid else { return }
        try await pull(p)
        pulledThisSession.insert("\(kind.rawValue).\(p)")
    }

    private func report(_ error: Error) {
        if let e = error as? OrivioAuthError, case .signedOut = e { return }
        onError?(error.localizedDescription)
    }

    /// The profile a store's rows live under (a "use primary add-ons" profile reads/writes profile 1's).
    private func addonPID(_ p: Int) -> Int {
        guard p != 1, let prof = stores.profiles.profile(p), prof.usesPrimaryAddons else { return p }
        return 1
    }

    private static func ms(_ seconds: Double) -> Int? {
        let v = (seconds * 1000).rounded()
        return v.isFinite && abs(v) < 9e15 ? Int(v) : nil
    }

    private nonisolated static func epochMS(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }
    private nonisolated static func date(ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private nonisolated static func rows(_ data: Data) -> [[String: Any]] {
        let obj = try? JSONSerialization.jsonObject(with: data)
        return (obj as? [[String: Any]]) ?? ((obj as? [String: Any]).map { [$0] } ?? [])
    }

    // MARK: Profiles

    private func chainProfiles() async throws {
        if SyncSignals.isDirty(.profiles, profile: 1) { try await pushProfiles() }
        try await drainProfileDeletes()
        try await pullProfiles()
    }

    private func pushProfiles() async throws {
        let entries: [[String: Any]] = stores.profiles.profiles.map { p in
            [
                "profile_index": p.id, "name": p.name, "avatar_color_hex": p.avatarColorHex,
                "uses_primary_addons": p.usesPrimaryAddons, "uses_primary_plugins": p.usesPrimaryPlugins,
                "avatar_id": p.avatarID ?? NSNull(), "avatar_url": p.avatarURL ?? NSNull(),
            ]
        }
        guard !entries.isEmpty else { return }
        _ = try await account.rpc("sync_push_profiles", [
            "p_client_max_profiles": ProfileStore.maxProfiles, "p_profiles": entries, "p_origin_client_id": clientID,
        ])
        SyncSignals.clearDirty(.profiles, profile: 1)
    }

    private func drainProfileDeletes() async throws {
        for raw in stores.profiles.deleted.ids.keys {
            guard let id = Int(raw), id != 1 else { continue }
            do {
                _ = try await account.rpc("sync_delete_profile_data", ["p_profile_id": id])
            } catch let e as OrivioAuthError where e.isMissingRPC {
                return
            }
        }
    }

    private func pullProfiles() async throws {
        let data = try await account.rpc("sync_pull_profiles", [:])
        let rows = Self.rows(data)
        let remote: [Profile] = rows.compactMap { r in
            guard let idx = r["profile_index"] as? Int else { return nil }
            var p = Profile(id: idx, name: r["name"] as? String ?? "Profile", avatarColorHex: r["avatar_color_hex"] as? String ?? "#1E88E5")
            p.usesPrimaryAddons = r["uses_primary_addons"] as? Bool ?? false
            p.usesPrimaryPlugins = r["uses_primary_plugins"] as? Bool ?? false
            p.avatarID = r["avatar_id"] as? String
            p.avatarURL = r["avatar_url"] as? String
            return p
        }
        if !remote.isEmpty, !SyncSignals.isDirty(.profiles, profile: 1) {
            SyncSignals.applyingRemote { stores.profiles.applyRemote(remote) }
        }
        if let lockData = try? await account.rpc("sync_pull_profile_locks", [:]) {
            var locks: [Int: Bool] = [:]
            for r in Self.rows(lockData) { if let i = r["profile_index"] as? Int { locks[i] = r["pin_enabled"] as? Bool ?? false } }
            SyncSignals.applyingRemote { stores.profiles.applyRemoteLocks(locks) }
        }
    }

    /// Server-side PIN (so other devices see the lock).
    func pushPIN(_ pin: String?, profile: Int) {
        guard account.isSignedIn else { return }
        Task {
            if let pin {
                _ = try? await account.rpc("set_profile_pin", ["p_profile_id": profile, "p_pin": pin])
            } else {
                _ = try? await account.rpc("clear_profile_pin", ["p_profile_id": profile])
            }
        }
    }

    /// Checks a PIN against the account (a lock set on another device has no local hash).
    func verifyPIN(_ pin: String, profile: Int) async -> Bool? {
        guard account.isSignedIn, let data = try? await account.rpc("verify_profile_pin", ["p_profile_id": profile, "p_pin": pin]) else { return nil }
        return Self.rows(data).first?["unlocked"] as? Bool
    }

    // MARK: Add-ons

    private func pushAddons(_ p: Int) async throws {
        // Never before this account's own list has been read, unless a local edit is waiting.
        guard pulledThisSession.contains("addons.\(p)") || SyncSignals.isDirty(.addons, profile: p) else { return }
        let entries: [[String: Any]] = stores.addons.addons.enumerated().map { i, a in
            var o: [String: Any] = ["url": a.manifestURL, "sort_order": i, "enabled": a.enabled]
            if !a.manifest.name.isEmpty { o["name"] = a.manifest.name }
            return o
        }
        _ = try await account.rpc("sync_push_addons", ["p_addons": entries, "p_profile_id": addonPID(p), "p_origin_client_id": clientID])
        SyncSignals.clearDirty(.addons, profile: p)
        setSeeded(.addons, p)
    }

    private func pullAddons(_ p: Int) async throws {
        guard let uid = account.userID else { return }
        let data = try await account.authed("/rest/v1/addons?user_id=eq.\(uid)&profile_id=eq.\(addonPID(p))&select=url,sort_order,enabled,name", method: "GET")
        guard p == pid, !SyncSignals.isDirty(.addons, profile: p) else { return }
        let rows = Self.rows(data).sorted { ($0["sort_order"] as? Int ?? 0) < ($1["sort_order"] as? Int ?? 0) }
        let list = rows.compactMap { r -> (url: String, enabled: Bool)? in
            guard let u = r["url"] as? String else { return nil }
            return (u, r["enabled"] as? Bool ?? true)
        }
        guard !list.isEmpty else { return }
        await stores.addons.applyRemote(urls: list)
        setSeeded(.addons, p)
    }

    // MARK: Watch progress (positions in ms; Android keys episodes `<id>_s<S>e<E>`)

    static func accountKey(_ w: WatchProgress) -> String {
        guard let s = w.season, let e = w.episode else { return w.id }
        return "\(w.metaID)_s\(s)e\(e)"
    }

    private nonisolated static func localKey(contentID: String, videoID: String, progressKey: String, season: Int?, episode: Int?) -> String {
        guard let s = season, let e = episode else { return progressKey }
        if contentID.hasPrefix("tt") { return "\(contentID):\(s):\(e)" }
        if videoID != progressKey, videoID.hasPrefix(contentID + ":") { return videoID }
        return progressKey
    }

    private func pushProgress(_ p: Int) async throws {
        // One entry per account row — the newest per episode.
        var newest: [String: WatchProgress] = [:]
        for w in stores.progress.entries.values {
            let k = Self.accountKey(w)
            if let held = newest[k], held.updatedAt >= w.updatedAt { continue }
            newest[k] = w
        }
        let entries: [[String: Any]] = newest.compactMap { key, w in
            guard w.duration > 0, let pos = Self.ms(w.position), let dur = Self.ms(w.duration) else { return nil }
            var o: [String: Any] = ["content_id": w.metaID, "content_type": w.type, "video_id": w.id, "position": pos, "duration": dur,
                                    "last_watched": Self.epochMS(w.updatedAt), "progress_key": key]
            if let s = w.season { o["season"] = s }
            if let e = w.episode { o["episode"] = e }
            return o
        }
        guard !entries.isEmpty else { SyncSignals.clearDirty(.watchProgress, profile: p); return }
        _ = try await account.rpc("sync_push_watch_progress", ["p_entries": entries, "p_profile_id": p, "p_origin_client_id": clientID])
        SyncSignals.clearDirty(.watchProgress, profile: p)
        setSeeded(.watchProgress, p)
    }

    private func pullProgress(_ p: Int) async throws {
        let data = try await account.rpc("sync_pull_watch_progress", ["p_profile_id": p])
        guard p == pid else { return }
        // Parsed off the main thread (sync runs at launch and every 90 s).
        let (rowCount, newest) = await Task.detached(priority: .utility) { Self.parseProgress(data) }.value
        if rowCount == 0 && !isSeeded(.watchProgress, p) { return }
        // Rows for titles removed here (and not watched since) are deleted on the account.
        let tombs = stores.progress.removed.ids
        let blocked = newest.values.filter { w, _, _ in tombs[w.metaID].map { w.updatedAt <= $0 } ?? false }
        if !blocked.isEmpty {
            _ = try? await account.rpc("sync_delete_watch_progress", ["p_keys": blocked.map(\.1), "p_profile_id": p, "p_origin_client_id": clientID])
        }
        let remote = newest.values.map(\.0).filter { w in !(tombs[w.metaID].map { w.updatedAt <= $0 } ?? false) }
        guard !SyncSignals.isDirty(.watchProgress, profile: p) else { return }
        SyncSignals.applyingRemote { stores.progress.applyRemote(remote) }
        if rowCount > 0 { setSeeded(.watchProgress, p) }
        await enrichProgressNames()
    }

    private nonisolated static func parseProgress(_ data: Data) -> (Int, [String: (WatchProgress, String, Int)]) {
        let rows = Self.rows(data)
        var newest: [String: (WatchProgress, String, Int)] = [:]
        for r in rows {
            guard let cid = r["content_id"] as? String else { continue }
            let vid = r["video_id"] as? String ?? cid
            let pkey = r["progress_key"] as? String ?? vid
            let s = r["season"] as? Int, e = r["episode"] as? Int
            let last = r["last_watched"] as? Int ?? 0
            let local = Self.localKey(contentID: cid, videoID: vid, progressKey: pkey, season: s, episode: e)
            if let held = newest[local], held.2 >= last { continue }
            let w = WatchProgress(id: local, metaID: cid, type: r["content_type"] as? String ?? "movie", videoID: vid, season: s, episode: e,
                                  position: Double(r["position"] as? Int ?? 0) / 1000, duration: Double(r["duration"] as? Int ?? 0) / 1000,
                                  updatedAt: Self.date(ms: last), name: "")
            newest[local] = (w, pkey, last)
        }
        return (rows.count, newest)
    }

    /// The account stores ids and positions only; fill in titles and art.
    private func enrichProgressNames() async {
        let missing = Dictionary(grouping: stores.progress.entries.values.filter { $0.name.isEmpty || $0.poster == nil }, by: \.metaID)
        guard !missing.isEmpty else { return }
        for (metaID, rows) in missing.prefix(30) {
            guard let type = rows.first?.type else { continue }
            let full = await MetaService.fetch(MetaItem(id: metaID, type: type == "movie" ? "movie" : "series", name: ""))
            guard !full.name.isEmpty else { continue }
            SyncSignals.applyingRemote { for r in rows { stores.progress.enrich(id: r.id, with: full) } }
        }
    }

    // MARK: Watched

    /// "tt123:1:2" → (tt123, 1, 2); a movie id → (id, nil, nil).
    private static func watchedParts(_ id: String) -> (String, Int?, Int?) {
        let parts = id.split(separator: ":").map(String.init)
        if parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) {
            return (parts.dropLast(2).joined(separator: ":"), s, e)
        }
        return (id, nil, nil)
    }

    private func pushWatched(_ p: Int) async throws {
        try await drainWatchedDeletes(p)
        let items = Array(stores.watched.items.values)
        guard !items.isEmpty else { SyncSignals.clearDirty(.watched, profile: p); return }
        let entries: [[String: Any]] = items.map { w in
            ["content_id": w.metaID, "content_type": w.type, "title": w.name ?? "", "watched_at": Self.epochMS(w.watchedAt),
             "season": w.season ?? NSNull(), "episode": w.episode ?? NSNull()]
        }
        _ = try await account.rpc("sync_push_watched_items", ["p_items": entries, "p_profile_id": p, "p_origin_client_id": clientID])
        SyncSignals.clearDirty(.watched, profile: p)
        setSeeded(.watched, p)
    }

    private func drainWatchedDeletes(_ p: Int) async throws {
        let ids = stores.watched.removed.ids.keys
        guard !ids.isEmpty else { return }
        let keys: [[String: Any]] = ids.map { id in
            let (cid, s, e) = Self.watchedParts(id)
            return ["content_id": cid, "season": s ?? NSNull(), "episode": e ?? NSNull()]
        }
        _ = try? await account.rpc("sync_delete_watched_items", ["p_keys": keys, "p_profile_id": p, "p_origin_client_id": clientID])
    }

    private func pullWatched(_ p: Int) async throws {
        try await drainWatchedDeletes(p)
        var collected: [WatchedItem] = []
        var page = 1
        let size = 900
        while true {
            let data = try await account.rpc("sync_pull_watched_items", ["p_profile_id": p, "p_page": page, "p_page_size": size])
            let (rowCount, items) = await Task.detached(priority: .utility) { () -> (Int, [WatchedItem]) in
                let rows = Self.rows(data)
                let items: [WatchedItem] = rows.compactMap { r in
                    guard let cid = r["content_id"] as? String else { return nil }
                    let s = r["season"] as? Int, e = r["episode"] as? Int
                    let id = (s != nil && e != nil) ? "\(cid):\(s!):\(e!)" : cid
                    return WatchedItem(id: id, metaID: cid, type: r["content_type"] as? String ?? "movie", season: s, episode: e,
                                       watchedAt: Self.date(ms: r["watched_at"] as? Int ?? 0), name: r["title"] as? String)
                }
                return (rows.count, items)
            }.value
            collected += items
            if rowCount < size || page > 40 { break }
            page += 1
        }
        guard p == pid, !SyncSignals.isDirty(.watched, profile: p) else { return }
        if collected.isEmpty && !isSeeded(.watched, p) { return }
        SyncSignals.applyingRemote { stores.watched.applyRemote(collected) }
        if !collected.isEmpty { setSeeded(.watched, p) }
    }

    // MARK: Library (push = replace)

    private func pushLibrary(_ p: Int) async throws {
        let items = stores.library.items
        let tombs = stores.library.removed.ids.keys
        // A cold start (local empty, not yet pulled) must never wipe the account.
        guard !items.isEmpty || pulledThisSession.contains("library.\(p)") || !tombs.isEmpty else { return }
        let entries: [[String: Any]] = items.map { i in
            let m = i.meta
            var o: [String: Any] = ["content_id": m.id, "content_type": m.type, "name": m.name, "title": m.name, "poster_shape": "POSTER",
                                    "genres": m.genres, "added_at": Self.epochMS(i.addedAt)]
            if let v = m.poster { o["poster"] = v }
            if let v = m.background { o["background"] = v }
            if let v = m.description { o["description"] = v }
            if let v = m.releaseInfo { o["release_info"] = v }
            if let v = m.imdbRating.flatMap(Double.init) { o["imdb_rating"] = v }
            return o
        }
        _ = try await account.rpc("sync_push_library", ["p_items": entries, "p_profile_id": p, "p_origin_client_id": clientID])
        let held = Set(items.map(\.meta.id))
        let deletes: [[String: String]] = tombs.filter { !held.contains($0) }.flatMap { id in
            [["content_id": id, "content_type": "movie"], ["content_id": id, "content_type": "series"]]
        }
        if !deletes.isEmpty {
            _ = try? await account.rpc("sync_delete_library_items", ["p_keys": deletes, "p_profile_id": p, "p_origin_client_id": clientID])
        }
        SyncSignals.clearDirty(.library, profile: p)
        if !items.isEmpty { setSeeded(.library, p) }
    }

    private func pullLibrary(_ p: Int) async throws {
        var collected: [LibraryItem] = []
        var offset = 0
        let size = 500
        while true {
            let data = try await account.rpc("sync_pull_library", ["p_profile_id": p, "p_limit": size, "p_offset": offset])
            let (rowCount, items) = await Task.detached(priority: .utility) { () -> (Int, [LibraryItem]) in
                let rows = Self.rows(data)
                let items: [LibraryItem] = rows.compactMap { r in
                    guard let cid = r["content_id"] as? String else { return nil }
                    let rating: String? = (r["imdb_rating"] as? Double).map { String(format: "%.1f", $0) }
                    let meta = MetaItem(id: cid, type: r["content_type"] as? String ?? "movie", name: (r["name"] as? String) ?? (r["title"] as? String) ?? "",
                                        poster: r["poster"] as? String, background: r["background"] as? String,
                                        description: r["description"] as? String, releaseInfo: r["release_info"] as? String,
                                        imdbRating: rating, genres: r["genres"] as? [String] ?? [])
                    return LibraryItem(meta: meta, addedAt: Self.date(ms: r["added_at"] as? Int ?? 0))
                }
                return (rows.count, items)
            }.value
            collected += items
            if rowCount < size || offset > 20_000 { break }
            offset += size
        }
        guard p == pid, !SyncSignals.isDirty(.library, profile: p) else { return }
        if collected.isEmpty && !isSeeded(.library, p) { return }
        SyncSignals.applyingRemote { stores.library.applyRemote(collected) }
        if !collected.isEmpty { setSeeded(.library, p) }
    }

    // MARK: Collections (one library shared by every profile)

    private func pushCollections(_ p: Int) async throws {
        let value: Any = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(stores.collections.library))) ?? [Any]()
        _ = try await account.rpc("sync_push_collections", ["p_profile_id": p, "p_collections_json": value, "p_origin_client_id": clientID])
        SyncSignals.clearDirty(.collections, profile: p)
        setSeeded(.collections, p)
    }

    private func pullCollections(_ p: Int) async throws {
        guard let uid = account.userID else { return }
        // Every profile's rows, gathered into the shared library.
        let data = try await account.authed("/rest/v1/collections?user_id=eq.\(uid)&select=profile_id,collections_json", method: "GET")
        // ~700 KB of collections: decoded off the main thread.
        let merged: [OrivioCollection] = await Task.detached(priority: .utility) {
            var merged: [OrivioCollection] = []
            var seen = Set<String>()
            for r in Self.rows(data).sorted(by: { ($0["profile_id"] as? Int ?? 1) < ($1["profile_id"] as? Int ?? 1) }) {
                var raw = r["collections_json"]
                if let s = raw as? String { raw = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
                guard let arr = raw as? [Any], let d = try? JSONSerialization.data(withJSONObject: arr),
                      let list = try? JSONDecoder().decode([OrivioCollection].self, from: d) else { continue }
                for c in list where seen.insert(c.id).inserted { merged.append(c) }
            }
            return merged
        }.value
        guard !SyncSignals.isDirty(.collections, profile: p) else { return }
        if merged.isEmpty && !isSeeded(.collections, p) { return }
        SyncSignals.applyingRemote { stores.collections.applyRemote(merged) }
        if !merged.isEmpty { setSeeded(.collections, p) }
    }

    // MARK: Home catalog settings (Android keys `{addonId}_{type}_{catalogId}`, `collection_{id}`)

    private func androidKey(_ local: String) -> String {
        if local.hasPrefix("collection:") { return "collection_" + local.dropFirst("collection:".count) }
        return local.replacingOccurrences(of: "|", with: "_")
    }

    private var knownLocalKeys: [String] {
        var keys: [String] = []
        for a in stores.addons.addons {
            for c in a.manifest.catalogs where !c.requiresExtra { keys.append("\(a.manifest.id)|\(c.type)|\(c.id)") }
        }
        keys += stores.collections.library.map { "collection:\($0.id)" }
        return keys
    }

    private func pushHomeCatalog(_ p: Int) async throws {
        let h = stores.home.value
        let ordered = stores.home.ordered(knownLocalKeys)
        var local: [String: Any] = [
            "home_catalog_order_keys": ordered.map(androidKey),
            "disabled_home_catalog_keys": h.rows.filter(\.hidden).map { androidKey($0.key) },
            "custom_catalog_titles": Dictionary(h.rows.compactMap { r in r.customTitle.map { (androidKey(r.key), $0) } }, uniquingKeysWith: { a, _ in a }),
            "hide_unreleased_content": h.hideUnreleased,
        ]
        // Keep keys other clients wrote.
        if let data = try? await account.rpc("sync_pull_home_catalog_settings", ["p_profile_id": p, "p_platform": "home_catalog_shared"]),
           let remote = Self.blob(Self.rows(data).first?["settings_json"]) {
            local = remote.merging(local) { _, l in l }
        }
        _ = try await account.rpc("sync_push_home_catalog_settings", [
            "p_profile_id": p, "p_settings_json": local, "p_platform": "home_catalog_shared", "p_origin_client_id": clientID,
        ])
        SyncSignals.clearDirty(.homeCatalog, profile: p)
    }

    private func pullHomeCatalog(_ p: Int) async throws {
        let data = try await account.rpc("sync_pull_home_catalog_settings", ["p_profile_id": p, "p_platform": "home_catalog_shared"])
        guard p == pid, !SyncSignals.isDirty(.homeCatalog, profile: p),
              let blob = Self.blob(Self.rows(data).first?["settings_json"]) else { return }
        let byAndroid = Dictionary(knownLocalKeys.map { (androidKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let order = (blob["home_catalog_order_keys"] as? [String] ?? []).compactMap { byAndroid[$0] }
        guard !order.isEmpty else { return }
        let hidden = Set((blob["disabled_home_catalog_keys"] as? [String] ?? []).compactMap { byAndroid[$0] })
        let titles = (blob["custom_catalog_titles"] as? [String: String] ?? [:])
        var h = stores.home.value
        let existing = Dictionary(h.rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        h.rows = order.map { k in
            var r = existing[k] ?? HomeRowConfig(key: k)
            r.hidden = hidden.contains(k)
            let t = titles[androidKey(k)]
            r.customTitle = (t?.isEmpty ?? true) ? nil : t
            return r
        }
        if let hu = blob["hide_unreleased_content"] as? Bool { h.hideUnreleased = hu }
        stores.home.applyRemote(h)
    }

    private nonisolated static func blob(_ any: Any?) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let s = any as? String { return try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
        return nil
    }

    // MARK: Profile settings blob (platform "tv"; our preferences under their own feature key)

    private static let prefsFeature = "orivio_tvos_preferences_v2"

    struct PreferencesSnapshot: Codable {
        var version = 2
        var appearance: AppearanceSettings
        var home: HomeSettings
        var player: PlayerSettings
        var tmdb: TMDBSettings
        var mdblist: MDBListSettings
        var torrent: TorrentSettings
        var traktFlags: TrackerFlags
        var simklFlags: TrackerFlags
        var ratings: [String: Int]?
    }

    private func pushSettingsBlob(_ p: Int) async throws {
        var home = stores.home.value
        home.rows = []   // rows travel in the home-catalog settings
        let snap = PreferencesSnapshot(appearance: stores.appearance.value, home: home, player: stores.player.value, tmdb: stores.tmdb.value,
                                       mdblist: stores.mdblist.value, torrent: stores.torrent.value, traktFlags: stores.traktFlags.value,
                                       simklFlags: stores.simklFlags.value, ratings: stores.ratings.ratings)
        guard let json = String(data: try JSONEncoder().encode(snap), encoding: .utf8) else { return }
        var blob: [String: Any] = ["version": 1, "features": [String: Any]()]
        if let data = try? await account.rpc("sync_pull_profile_settings_blob", ["p_profile_id": p, "p_platform": "tv"]),
           let existing = Self.blob(Self.rows(data).first?["settings_json"]) {
            blob = existing
        }
        var features = blob["features"] as? [String: Any] ?? [:]
        features[Self.prefsFeature] = ["type": "string", "value": json]
        // Link badges: written only after a change here — otherwise the
        // account's pack (maybe set up on another device) is left as it is.
        let badgeRules = stores.badges.rulesForPush()
        if let badgeRules {
            var f = features[Self.badgeFeature] as? [String: Any] ?? [:]
            f["stream_badge_rules"] = ["type": "string", "value": badgeRules]
            features[Self.badgeFeature] = f
        }
        blob["features"] = features
        _ = try await account.rpc("sync_push_profile_settings_blob", [
            "p_profile_id": p, "p_settings_json": blob, "p_platform": "tv", "p_origin_client_id": clientID,
        ])
        if badgeRules != nil, p == pid { stores.badges.didPush() }
        SyncSignals.clearDirty(.profileSettings, profile: p)
    }

    private static let badgeFeature = "stream_badge_settings"
    /// Blobs other Orivio apps write: a badge pack set up on a phone (or the
    /// previous tvOS app) lives in that platform's blob, not ours.
    private static let otherBlobPlatforms = ["mobile", "fusion", "ios", "desktop", "web"]
    private var badgeFallbackTried: Set<Int> = []

    private static func badgeRules(in blob: [String: Any]?) -> String? {
        guard let f = (blob?["features"] as? [String: Any])?[badgeFeature] as? [String: Any] else { return nil }
        let entry = f["stream_badge_rules"]
        if let d = entry as? [String: Any], let v = d["value"] as? String { return v }
        return entry as? String
    }

    private static func hasBadgeFilters(_ rules: String) -> Bool {
        guard let d = rules.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let imports = root["imports"] as? [[String: Any]] else { return false }
        return imports.contains { !(($0["filters"] as? [[String: Any]]) ?? []).isEmpty }
    }

    /// The account's badge pack: ours first, then any other app's. `manual` (the
    /// Settings button) always looks; otherwise once per session, and only while
    /// this profile has no pack.
    @discardableResult
    func pullBadges(manual: Bool = false) async -> String {
        let p = pid
        guard account.isSignedIn else { return "Sign in to your Orivio account first" }
        if !manual, stores.badges.isConfigured || badgeFallbackTried.contains(p) { return "" }
        badgeFallbackTried.insert(p)
        for platform in ["tv"] + Self.otherBlobPlatforms {
            guard let data = try? await account.rpc("sync_pull_profile_settings_blob", ["p_profile_id": p, "p_platform": platform]),
                  p == pid,
                  let rules = Self.badgeRules(in: Self.blob(Self.rows(data).first?["settings_json"])),
                  Self.hasBadgeFilters(rules) else { continue }
            stores.badges.applyRemote(rulesJSON: rules)
            return stores.badges.isConfigured ? "Synced \(stores.badges.filterCount) badge filters from your account" : "That badge pack had no usable filters"
        }
        return "No badge pack on this account yet — import one below or in any Orivio app"
    }

    private func pullSettingsBlob(_ p: Int) async throws {
        let data = try await account.rpc("sync_pull_profile_settings_blob", ["p_profile_id": p, "p_platform": "tv"])
        let tvBlob = Self.blob(Self.rows(data).first?["settings_json"])
        if p == pid {
            if let rules = Self.badgeRules(in: tvBlob) { stores.badges.applyRemote(rulesJSON: rules) }
            else if !stores.badges.isConfigured { Task { await pullBadges() } }
        }
        guard p == pid, !SyncSignals.isDirty(.profileSettings, profile: p),
              let blob = tvBlob,
              let feature = (blob["features"] as? [String: Any])?[Self.prefsFeature] as? [String: Any],
              let json = feature["value"] as? String,
              let snap = try? JSONDecoder().decode(PreferencesSnapshot.self, from: Data(json.utf8)) else { return }
        stores.appearance.applyRemote(snap.appearance)
        var home = snap.home
        home.rows = stores.home.value.rows
        stores.home.applyRemote(home)
        stores.player.applyRemote(snap.player)
        stores.tmdb.applyRemote(snap.tmdb)
        stores.mdblist.applyRemote(snap.mdblist)
        stores.torrent.applyRemote(snap.torrent)
        stores.traktFlags.applyRemote(snap.traktFlags)
        stores.simklFlags.applyRemote(snap.simklFlags)
        if let r = snap.ratings { stores.ratings.applyRemote(r) }
    }

    // MARK: Provider credentials (debrid keys, Trakt — shared with Android)

    /// Android's provider-credential ids. The backend only accepts the exact
    /// `debrid:<id>` names; sending bare `realdebrid` made the whole sync fail
    /// with "Unsupported provider credential: realdebrid" (v13/v14). AllDebrid
    /// isn't a synced provider on Android, so it stays local.
    private static let debridNames: [(DebridProvider, String)] = [
        (.realDebrid, "debrid:realdebrid"),
        (.premiumize, "debrid:premiumize"),
        (.torbox, "debrid:torbox"),
    ]

    /// A row's provider name → our provider, accepting both the current
    /// `debrid:realdebrid` form and the bare names older builds wrote.
    private static func debridProvider(for name: String) -> DebridProvider? {
        let n = name.lowercased()
        if let hit = debridNames.first(where: { $0.1.lowercased() == n }) { return hit.0 }
        let bare = n.hasPrefix("debrid:") ? String(n.dropFirst("debrid:".count)) : n
        return DebridProvider.allCases.first { $0.rawValue.lowercased() == bare }
    }

    /// The provider the server named in an "Unsupported provider credential: x"
    /// error, if that's what came back.
    private static func unsupportedProvider(in body: String) -> String? {
        let message = OrivioAuthError.serverMessage(body) ?? body
        guard let r = message.range(of: "Unsupported provider credential", options: .caseInsensitive) else { return nil }
        return message[r.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
            .lowercased()
    }

    private func pushCredentials(_ p: Int) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var creds: [[String: Any]] = []
        for (prov, name) in Self.debridNames {
            guard let key = stores.debrid.value.key(prov) else { continue }
            creds.append(["provider": name, "credential_json": ["api_key": key], "updated_at": now])
        }
        if let t = stores.trakt.tokens {
            var j: [String: Any] = ["access_token": t.accessToken, "refresh_token": t.refreshToken]
            if let u = stores.trakt.username { j["username"] = u }
            creds.append(["provider": "trakt", "credential_json": j, "updated_at": now])
        }
        guard !creds.isEmpty else { SyncSignals.clearDirty(.providerCredentials, profile: p); return }

        // Servers differ in which optional providers they accept (the public
        // schema rejects `trakt`). Drop the one the server names and retry
        // rather than failing the entire sync — and never let one bad row stop
        // the debrid keys from syncing.
        var pending = creds
        for _ in 0..<4 {
            do {
                _ = try await account.rpc("sync_push_provider_credentials",
                                          ["p_credentials": pending, "p_profile_id": p, "p_origin_client_id": clientID])
                break
            } catch let OrivioAuthError.http(_, body) where Self.unsupportedProvider(in: body) != nil {
                guard let bad = Self.unsupportedProvider(in: body) else { break }
                let before = pending.count
                pending.removeAll { ($0["provider"] as? String)?.lowercased() == bad }
                if pending.isEmpty || pending.count == before { break }
            }
        }
        SyncSignals.clearDirty(.providerCredentials, profile: p)
    }

    private func pullCredentials(_ p: Int) async throws {
        let data = try await account.rpc("sync_pull_provider_credentials", ["p_profile_id": p])
        guard p == pid, !SyncSignals.isDirty(.providerCredentials, profile: p) else { return }
        var keys = stores.debrid.value.keys
        var changed = false
        for r in Self.rows(data) {
            guard let prov = (r["provider"] as? String)?.lowercased() else { continue }
            let j = Self.blob(r["credential_json"]) ?? [:]
            func str(_ k: String...) -> String? { for x in k { if let v = j[x] as? String, !v.isEmpty { return v } }; return nil }
            if prov == "trakt" {
                if stores.trakt.tokens == nil, let a = str("access_token", "accessToken"), let rf = str("refresh_token", "refreshToken") {
                    SyncSignals.applyingRemote {
                        stores.trakt.set(TraktTokens(accessToken: a, refreshToken: rf, expiresAt: Date().addingTimeInterval(3600)), user: str("username", "user"))
                    }
                }
            } else if let dp = Self.debridProvider(for: prov),
                      let key = str("api_key", "apiKey", "apikey", "token", "access_token", "value"), keys[dp.rawValue] != key {
                keys[dp.rawValue] = key
                changed = true
            }
        }
        if changed {
            var v = stores.debrid.value
            v.keys = keys
            stores.debrid.applyRemote(v)
        }
    }
}
