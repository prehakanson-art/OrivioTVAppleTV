import Foundation

/// §9.1 Local Backup: the active profile's add-ons, library, progress,
/// watched marks, ratings, collections and preferences as one JSON blob.
/// Credentials (API keys, debrid keys, account tokens) are never included.
/// Import merges: nothing already on this Apple TV is removed.
@MainActor
enum LocalBackup {
    struct Blob: Codable {
        var app = "orivio-tvos"
        var version = 1
        var createdAt = Date()
        var addons: [String]
        var library: [LibraryItem]
        var progress: [WatchProgress]
        var watched: [WatchedItem]
        var collections: [OrivioCollection]
        var preferences: OrivioSync.PreferencesSnapshot
    }

    static var filename: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "orivio-backup-\(f.string(from: Date())).json"
    }

    static func export() -> String {
        let s = AppStores.shared
        var tmdb = s.tmdb.value
        tmdb.apiKey = ""
        var mdblist = s.mdblist.value
        mdblist.apiKey = ""
        let prefs = OrivioSync.PreferencesSnapshot(appearance: s.appearance.value, home: s.home.value, player: s.player.value, tmdb: tmdb,
                                                   mdblist: mdblist, torrent: s.torrent.value, traktFlags: s.traktFlags.value,
                                                   simklFlags: s.simklFlags.value, ratings: s.ratings.ratings)
        let blob = Blob(addons: s.addons.addons.map(\.manifestURL), library: s.library.items,
                        progress: Array(s.progress.entries.values), watched: Array(s.watched.items.values),
                        collections: s.collections.library, preferences: prefs)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(blob)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    struct Summary { var addons = 0, library = 0, progress = 0, watched = 0, collections = 0 }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That isn't an Orivio backup." }
    }

    static func importBackup(_ text: String) async throws -> Summary {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8), let blob = try? dec.decode(Blob.self, from: data), blob.app == "orivio-tvos" else {
            throw ImportError.unreadable
        }
        let s = AppStores.shared
        var summary = Summary()

        summary.addons = await s.addons.importURLs(blob.addons.joined(separator: "\n"))

        let libIDs = Set(s.library.items.map(\.id))
        let newLib = blob.library.filter { !libIDs.contains($0.id) }
        summary.library = newLib.count
        s.library.applyRemote(s.library.items + newLib)

        summary.progress = blob.progress.filter { p in s.progress.entries[p.id].map { p.updatedAt > $0.updatedAt } ?? true }.count
        s.progress.applyRemote(blob.progress)

        let newWatched = blob.watched.filter { s.watched.items[$0.id] == nil }
        summary.watched = newWatched.count
        s.watched.applyRemote(Array(s.watched.items.values) + newWatched)

        let collIDs = Set(s.collections.library.map(\.id))
        let newColl = blob.collections.filter { !collIDs.contains($0.id) }
        summary.collections = newColl.count
        s.collections.applyRemote(s.collections.library + newColl)

        // Preferences: keep this device's keys.
        let p = blob.preferences
        s.appearance.applyRemote(p.appearance)
        s.home.applyRemote(p.home)
        s.player.applyRemote(p.player)
        var tmdb = p.tmdb
        tmdb.apiKey = s.tmdb.value.apiKey
        s.tmdb.applyRemote(tmdb)
        var mdblist = p.mdblist
        mdblist.apiKey = s.mdblist.value.apiKey
        s.mdblist.applyRemote(mdblist)
        s.torrent.applyRemote(p.torrent)
        s.traktFlags.applyRemote(p.traktFlags)
        s.simklFlags.applyRemote(p.simklFlags)
        if let r = p.ratings { s.ratings.applyRemote(s.ratings.ratings.merging(r) { local, _ in local }) }

        // Push the merged result to the account on the next sync.
        for kind: SyncKind in [.library, .watchProgress, .watched, .collections, .profileSettings, .homeCatalog] {
            SyncSignals.markDirty(kind)
        }
        return summary
    }
}
