import SwiftUI

// Hosting the Classic player (the old app's player) in the new app: building
// its request from the new `PlaybackRequest`, the full-screen cover, Picture
// in Picture restore, and Trakt scrobbling — which the old app did in its root
// view rather than inside the player.

extension ClassicPlaybackRequest {
    /// The old request for a new one. The link the new app already resolved
    /// (debrid, TorrServer, Plex/Jellyfin) is what plays: its URL and headers
    /// go onto the entry's stream.
    init(_ r: PlaybackRequest) {
        var stream = r.entry.stream
        stream.url = r.url.absoluteString
        if !r.headers.isEmpty {
            var hints = stream.behaviorHints ?? StreamBehaviorHints()
            var proxy = hints.proxyHeaders ?? StreamProxyHeaders()
            proxy.request = (proxy.request ?? [:]).merging(r.headers) { _, new in new }
            hints.proxyHeaders = proxy
            stream.behaviorHints = hints
        }
        let entry = StreamEntry(stream: stream, addonName: r.entry.addonName, addonID: r.entry.addonID, index: 0)
        let direct = r.directEpisodes
        self.init(meta: r.meta, video: r.video, entry: entry, allEntries: r.allEntries,
                  resumePosition: r.resumePosition, forceDemuxer: r.forceDemuxer,
                  directEpisodeResolver: direct.map { map in { video in map[video.id] } },
                  shuffle: r.shuffle)
    }
}

/// Trakt scrobbling for Classic sessions (start / stop per title, episode to
/// episode inside one session, nothing across a Picture in Picture handoff).
@MainActor
final class ClassicScrobbler {
    static let shared = ClassicScrobbler()
    private var current: (meta: MetaItem, video: MetaVideo?)?

    private var enabled: Bool {
        AppStores.shared.trakt.isSignedIn && AppStores.shared.traktFlags.value.scrobble
    }

    private func fraction(_ meta: MetaItem, _ video: MetaVideo?, fallback: Double?) -> Double {
        let key = ProgressStore.key(metaID: meta.id, video: video)
        guard let p = AppStores.shared.progress.progress(for: key), p.duration > 0 else { return 0 }
        return min(1, max(0, (fallback ?? p.position) / p.duration))
    }

    func start(_ meta: MetaItem, _ video: MetaVideo?, resume: Double?) {
        // A dev test stream has no title Trakt could know.
        guard enabled, !TestStreamCatalog.isTestMeta(meta.id) else { current = nil; return }
        if let c = current, c.meta.id == meta.id, c.video?.id == video?.id { return }
        if current != nil { stop() }
        current = (meta, video)
        let f = resume.map { fraction(meta, video, fallback: $0) } ?? 0
        Task { await TraktService.scrobble("start", meta: meta, video: video, progress: f) }
    }

    func stop() {
        guard let c = current else { return }
        current = nil
        guard enabled else { return }
        let f = fraction(c.meta, c.video, fallback: nil)
        Task { await TraktService.scrobble("stop", meta: c.meta, video: c.video, progress: f) }
    }
}

/// The Classic player's full-screen cover, attached to the app's root view.
struct ClassicPlayerCover: ViewModifier {
    @ObservedObject var presenter: PlayerPresenter
    let theme: Theme

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presenter.classicRequest) { request in
                ClassicPlayerScreen(
                    request: request,
                    addonManager: AppStores.shared.addons,
                    progressStore: AppStores.shared.progress,
                    playerSettings: ClassicPlayerSettingsStore.shared.settings,
                    allowUnairedNextUp: AppStores.shared.home.value.showUnairedNextUp,
                    onNowPlayingChanged: { meta, video in ClassicScrobbler.shared.start(meta, video, resume: nil) }
                ) {
                    presenter.classicRequest = nil
                }
                .withAppStores(AppStores.shared)
                .environmentObject(ClassicPlayerSettingsStore.shared)
                .environment(\.theme, theme)
            }
            .onChange(of: presenter.classicRequest?.id) { _, _ in
                if let r = presenter.classicRequest {
                    // Back from Picture in Picture: the session never stopped.
                    if presenter.classicRestoredID == r.id { presenter.classicRestoredID = nil; return }
                    ClassicScrobbler.shared.start(r.meta, r.video, resume: r.resumePosition)
                } else if !PiPHandoff.shared.isActive {
                    ClassicScrobbler.shared.stop()
                }
            }
            .onAppear {
                PiPHandoff.shared.present = { [presenter] request in
                    presenter.classicRestoredID = request.id
                    presenter.classicRequest = request
                }
            }
    }
}
