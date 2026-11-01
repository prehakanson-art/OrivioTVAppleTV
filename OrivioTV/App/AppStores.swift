import SwiftUI

/// Every app-wide store, in a **non-publishing holder** so one store publishing
/// doesn't re-render the root (that caused hold-menu highlight flicker).
@MainActor
final class AppStores {
    static let shared = AppStores()

    let profiles = ProfileStore()
    let appearance = AppearanceStore()
    let addons = AddonManager()
    let progress = ProgressStore()
    let watched = WatchedStore()
    let library = LibraryStore()
    let ratings = RatingsStore()
    let home = HomeSettingsStore()
    let player = PlayerSettingsStore()
    let tmdb = TMDBSettingsStore()
    let mdblist = MDBListSettingsStore()
    let debrid = DebridStore()
    let torrent = TorrentSettingsStore()
    let liveTV = LiveTVSettingsStore()
    let liveFavorites = LiveChannelFavorites()
    let traktFlags = TraktFlagsStore()
    let simklFlags = SimklFlagsStore()
    let collections = CollectionsStore()
    let trakt = TraktStore()
    let simkl = SimklStore()
    let badges = StreamBadgeStore()
    let toasts = ToastCenter.shared

    private init() {
        addons.usesPrimaryProfile = { [unowned self] in
            let p = self.profiles.active
            return p.id != 1 && p.usesPrimaryAddons
        }
        profiles.onActiveProfileChanged = { [unowned self] in self.reloadProfileScoped() }
    }

    private var profileScoped: [ProfileScoped] {
        [appearance, addons, progress, watched, library, ratings, home, player, tmdb, mdblist, debrid,
         liveFavorites, traktFlags, simklFlags, trakt, simkl, badges]
    }

    func reloadProfileScoped() {
        for s in profileScoped { s.reloadForActiveProfile() }
    }

    func flushAll() {
        progress.saveNow()
        watched.saveNow()
        // Every debounced settings store: 0.4 s is enough to lose a toggle when
        // the app is backgrounded right after it is changed.
        let savers: [() -> Void] = [appearance.saveNow, home.saveNow, player.saveNow, tmdb.saveNow,
                                   mdblist.saveNow, debrid.saveNow, torrent.saveNow, liveTV.saveNow,
                                   traktFlags.saveNow, simklFlags.saveNow]
        for saver in savers { saver() }
    }
}

extension View {
    /// Injects every store as an environment object.
    func withAppStores(_ s: AppStores) -> some View {
        self
            .environmentObject(s.profiles)
            .environmentObject(s.appearance)
            .environmentObject(s.addons)
            .environmentObject(s.progress)
            .environmentObject(s.watched)
            .environmentObject(s.library)
            .environmentObject(s.ratings)
            .environmentObject(s.home)
            .environmentObject(s.player)
            .environmentObject(s.tmdb)
            .environmentObject(s.mdblist)
            .environmentObject(s.debrid)
            .environmentObject(s.torrent)
            .environmentObject(s.liveTV)
            .environmentObject(s.liveFavorites)
            .environmentObject(s.traktFlags)
            .environmentObject(s.simklFlags)
            .environmentObject(s.collections)
            .environmentObject(s.trakt)
            .environmentObject(s.simkl)
            .environmentObject(s.badges)
            .environmentObject(s.toasts)
    }
}
