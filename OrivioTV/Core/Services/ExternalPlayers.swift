import UIKit

/// Infuse, VLC, nPlayer, VidHub, SenPlayer via URL schemes (detected with `canOpenURL`).
enum ExternalPlayers {
    /// `canOpenURL` is a synchronous round trip to the system, and source rows
    /// ask it from their view bodies — once per row on every redraw, which
    /// stalled the main thread (and the video's render loop) behind the
    /// player. Installed apps don't change while you're in this app, so the
    /// answer is cached until it comes back to the foreground.
    private static var installedCache: [ExternalPlayerApp: Bool] = [:]
    private static var cacheObserver: NSObjectProtocol?

    static func isInstalled(_ app: ExternalPlayerApp) -> Bool {
        if let known = installedCache[app] { return known }
        if cacheObserver == nil {
            cacheObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { _ in installedCache.removeAll() }
        }
        guard let probe = URL(string: probeScheme(app) + "://") else { return false }
        let result = UIApplication.shared.canOpenURL(probe)
        installedCache[app] = result
        return result
    }

    static var infuseInstalled: Bool { isInstalled(.infuse) }

    static var installed: [ExternalPlayerApp] { ExternalPlayerApp.allCases.filter(isInstalled) }

    private static func probeScheme(_ app: ExternalPlayerApp) -> String {
        switch app {
        case .infuse: return "infuse"
        case .vlc: return "vlc-x-callback"
        case .nplayer: return "nplayer-http"
        case .vidhub: return "open-vidhub"
        case .senplayer: return "senplayer"
        }
    }

    /// The install-unique callback scheme (the bundle id) so `x-success` lands in *this* install.
    static var callbackScheme: String { Bundle.main.bundleIdentifier ?? "orivio" }

    static func handoffURL(_ app: ExternalPlayerApp, media: URL, subtitles: URL? = nil, playlist: [URL] = []) -> URL? {
        let enc = { (u: URL) in HTTP.encodeComponent(u.absoluteString) }
        let success = HTTP.encodeComponent("\(callbackScheme)://x-callback-url/playbackDidFinish")
        let failure = HTTP.encodeComponent("\(callbackScheme)://x-callback-url/playbackDidFail")
        var s: String
        switch app {
        case .infuse:
            s = "infuse://x-callback-url/play?url=\(enc(media))"
            for extra in playlist { s += "&url=\(enc(extra))" }
            if let subtitles { s += "&sub=\(enc(subtitles))" }
            s += "&x-success=\(success)&x-error=\(failure)"
        case .vlc:
            s = "vlc-x-callback://x-callback-url/stream?url=\(enc(media))"
            if let subtitles { s += "&sub=\(enc(subtitles))" }
            s += "&x-success=\(success)&x-error=\(failure)"
        case .nplayer:
            s = "nplayer-" + media.absoluteString
        case .vidhub:
            s = "open-vidhub://x-callback-url/open?url=\(enc(media))"
        case .senplayer:
            s = "senplayer://x-callback-url/play?url=\(enc(media))"
            if let subtitles { s += "&sub=\(enc(subtitles))" }
        }
        return URL(string: s)
    }
}

/// Remembers what was handed off so the `x-success` callback can write progress.
@MainActor
enum ExternalPlayback {
    struct Pending: Codable {
        var meta: MetaItem
        var video: MetaVideo?
        var streamURL: String
        var startedAt: Date
        var duration: Double?
    }

    private static let key = Persistence.key("externalPlayback.pending.v1")

    static func begin(_ p: Pending) {
        Persistence.save(p, key: key, compressed: false)
    }

    static func launch(_ app: ExternalPlayerApp, meta: MetaItem, video: MetaVideo?, url: URL, subtitles: URL? = nil, playlist: [URL] = []) -> Bool {
        guard let handoff = ExternalPlayers.handoffURL(app, media: url, subtitles: subtitles, playlist: playlist) else { return false }
        begin(Pending(meta: meta, video: video, streamURL: url.absoluteString, startedAt: Date()))
        UIApplication.shared.open(handoff)
        return true
    }

    static func finished(position: Double?) {
        guard let p = Persistence.load(Pending.self, key: key) else { return }
        Persistence.set(nil, forKey: key)
        guard let position, position > 5 else { return }
        let duration = p.duration ?? max(position, (p.meta.runtimeMinutes.map { Double($0 * 60) } ?? position * 1.05))
        let id = p.video?.id ?? p.meta.id
        let progress = WatchProgress(id: id, metaID: p.meta.id, type: p.meta.type, videoID: p.video?.id,
                                     season: p.video?.season, episode: p.video?.episode, position: position, duration: duration,
                                     updatedAt: Date(), name: p.meta.name, poster: p.meta.poster, background: p.meta.background,
                                     logo: p.meta.logo, episodeTitle: p.video?.title, episodeThumbnail: p.video?.thumbnail)
        AppStores.shared.progress.record(progress, transient: false)
        if progress.isFinished { AppStores.shared.watched.markWatched(meta: p.meta, video: p.video) }
    }

    static func finishedWithError(_ message: String) {
        Persistence.set(nil, forKey: key)
        ToastCenter.shared.show(message, systemImage: "exclamationmark.triangle.fill")
    }
}
