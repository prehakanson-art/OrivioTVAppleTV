import Foundation

final class AppearanceStore: SettingsStore<AppearanceSettings> {
    /// While a picker row is focused, the whole app previews that option.
    @Published var preview: AppearanceSettings?

    init() {
        super.init(baseKey: "theme.v2", scope: .profile)
        onUserChange = { SyncSignals.markDirty(.profileSettings) }
    }
}

final class HomeSettingsStore: SettingsStore<HomeSettings> {
    init() {
        super.init(baseKey: "homecatalog.v1", scope: .profile)
        // Home is split across two account stores: row order/hidden state live
        // in the home-catalog blob, while heroLayout and the rest of the page
        // travel in the tv preferences blob. Marking only `.homeCatalog` left
        // the preferences pull free to overwrite a fresh layout with the
        // account's old one (the "layout never saves" report).
        onUserChange = {
            SyncSignals.markDirty(.homeCatalog)
            SyncSignals.markDirty(.profileSettings)
        }
    }

    func config(for key: String) -> HomeRowConfig? { value.rows.first { $0.key == key } }

    func setConfig(_ cfg: HomeRowConfig) {
        update { s in
            if let i = s.rows.firstIndex(where: { $0.key == cfg.key }) { s.rows[i] = cfg } else { s.rows.append(cfg) }
        }
    }

    /// Orders `keys` by the saved order; unknown keys keep their natural order after known ones.
    func ordered(_ keys: [String]) -> [String] {
        let saved = value.rows.map(\.key)
        let known = saved.filter { keys.contains($0) }
        let unknown = keys.filter { !saved.contains($0) }
        return known + unknown
    }

    func move(_ key: String, by delta: Int, among keys: [String]) {
        var order = ordered(keys)
        guard let i = order.firstIndex(of: key) else { return }
        let j = max(0, min(order.count - 1, i + delta))
        guard i != j else { return }
        order.remove(at: i)
        order.insert(key, at: j)
        update { s in
            var rows: [HomeRowConfig] = []
            for k in order { rows.append(s.rows.first { $0.key == k } ?? HomeRowConfig(key: k)) }
            for r in s.rows where !order.contains(r.key) { rows.append(r) }
            s.rows = rows
        }
    }
}

final class PlayerSettingsStore: SettingsStore<PlayerSettings> {
    init() {
        super.init(baseKey: "player.settings.v1", scope: .profile)
        onUserChange = { SyncSignals.markDirty(.profileSettings) }
    }
}

final class TMDBSettingsStore: SettingsStore<TMDBSettings> {
    init() {
        super.init(baseKey: "tmdb.settings.v1", scope: .profile)
        onUserChange = { SyncSignals.markDirty(.profileSettings) }
    }
}

final class MDBListSettingsStore: SettingsStore<MDBListSettings> {
    init() {
        super.init(baseKey: "mdblist.settings.v1", scope: .profile)
        onUserChange = { SyncSignals.markDirty(.profileSettings) }
    }
}

final class DebridStore: SettingsStore<DebridSettings> {
    init() {
        super.init(baseKey: "debrid.keys.v1", scope: .profile)
        onUserChange = { SyncSignals.markDirty(.providerCredentials) }
    }
}

final class TorrentSettingsStore: SettingsStore<TorrentSettings> {
    init() { super.init(baseKey: "torrent.settings.v1", scope: .device) }
}

final class LiveTVSettingsStore: SettingsStore<LiveTVSettings> {
    init() { super.init(baseKey: "livetv.settings.v1", scope: .device) }

    func noteRecent(_ channelID: String) {
        update { s in
            s.recentChannelIDs.removeAll { $0 == channelID }
            s.recentChannelIDs.insert(channelID, at: 0)
            if s.recentChannelIDs.count > 20 { s.recentChannelIDs.removeLast(s.recentChannelIDs.count - 20) }
        }
    }

    func toggleHome(_ channelID: String) -> Bool {
        var added = false
        update { s in
            if s.homeChannelIDs.contains(channelID) { s.homeChannelIDs.removeAll { $0 == channelID } } else {
                s.homeChannelIDs.append(channelID)
                added = true
            }
        }
        return added
    }
}

final class TraktFlagsStore: SettingsStore<TrackerFlags> {
    init() { super.init(baseKey: "trakt.flags.v1", scope: .profile) }
}

final class SimklFlagsStore: SettingsStore<TrackerFlags> {
    init() { super.init(baseKey: "simkl.flags.v1", scope: .profile) }
}

/// Favourite live channels, per profile, with tombstones.
@MainActor
final class LiveChannelFavorites: ObservableObject, ProfileScoped {
    @Published private(set) var ids: [String] = []
    private let baseKey = "livetv.favorites.v1"

    init() { reloadForActiveProfile() }

    func reloadForActiveProfile() {
        ids = Persistence.loadScoped([String].self, base: baseKey, profile: ProfileScope.current) ?? []
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    @discardableResult
    func toggle(_ id: String) -> Bool {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        Persistence.saveScoped(ids, base: baseKey, profile: ProfileScope.current)
        return ids.contains(id)
    }
}
