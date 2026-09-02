import UIKit

/// Everything we can hand an external player about ONE handoff. Which fields
/// actually go out is per-player: each entry in the catalog only serializes the
/// parameters its own scheme documents, so nothing gets a made-up query key.
struct ExternalPlayerHandoff {
    /// One video in the handoff. More than one only goes to players that
    /// document a playlist form (Infuse); everyone else gets `primary`.
    struct Item {
        let streamURL: String
        /// External subtitle to side-load (players with a `sub` parameter).
        var subtitleURL: String?
        /// A media-style name ("Show.Name.S01E02.mkv"). Infuse matches artwork
        /// and metadata off this, so the title shows properly instead of a raw
        /// URL.
        var filename: String?
        /// Resume point in seconds. Players that accept it start there instead
        /// of at 0, so "continue watching" carries INTO the other app.
        var resumeSeconds: Double?
    }

    /// Never empty; `items[0]` is what starts playing.
    private(set) var items: [Item]
    /// x-callback-url return points, in OUR scheme. Only sent to players that
    /// document them; the player appends its own result parameters.
    var successURL: String?
    var errorURL: String?

    init(items: [Item]) {
        precondition(!items.isEmpty, "a handoff needs at least one item")
        self.items = items
    }

    init(streamURL: String, subtitleURL: String? = nil) {
        self.init(items: [Item(streamURL: streamURL, subtitleURL: subtitleURL)])
    }

    var primary: Item { items[0] }
}

/// One external player app the Apple TV might have installed, addressable via
/// its public URL scheme (the standard "Open in <app>" pattern) — no private
/// APIs, no code from those apps.
struct ExternalPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    /// Scheme probed with canOpenURL (must be in LSApplicationQueriesSchemes).
    let probeScheme: String
    /// Builds the handoff URL from everything we know about this playback.
    let makeURL: (ExternalPlayerHandoff) -> URL?
    /// This player calls `x-success` back into us when playback ends, carrying
    /// the final position — so Continue Watching can be updated EXACTLY. Only
    /// Infuse (8.4.7+) documents this; for the rest, progress can only come
    /// back through Trakt (if that app scrobbles) or the optimistic entry we
    /// write at handoff time.
    var reportsPosition: Bool = false
    /// Accepts a `position` parameter, i.e. resume carries into the app.
    var acceptsResume: Bool = false
    /// Takes more than one video per handoff (Infuse plays repeated url groups
    /// as a temporary playlist), so next-episode keeps working over there.
    var supportsPlaylist: Bool = false

    var isInstalled: Bool {
        guard let url = URL(string: "\(probeScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    func open(_ handoff: ExternalPlayerHandoff) {
        guard let url = makeURL(handoff) else { return }
        UIApplication.shared.open(url)
    }

    func open(streamURL: String, subtitleURL: String? = nil) {
        open(ExternalPlayerHandoff(streamURL: streamURL, subtitleURL: subtitleURL))
    }

    static func == (lhs: ExternalPlayer, rhs: ExternalPlayer) -> Bool { lhs.id == rhs.id }
}

/// Detection + handoff for external player apps installed on the Apple TV.
enum ExternalPlayers {
    /// Every player we know how to hand a stream to on tvOS. Detection is a
    /// canOpenURL probe, so only apps actually installed show up in Settings.
    static let catalog: [ExternalPlayer] = [
        // Infuse implements the full x-callback contract (Firecore's public
        // API, 8.4.7+): we send a resume position, a media-style filename and
        // an optional subtitle, and it calls x-success back with the URL it
        // finished on plus the final position — the one player that can close
        // the Continue Watching loop by itself.
        ExternalPlayer(
            id: "infuse", name: "Infuse", probeScheme: "infuse",
            makeURL: { h in
                // Repeated url/position/filename/sub groups = one temporary
                // playlist, played in order. Parameters belong to the url they
                // follow, so they are emitted per item, in order.
                var s = "infuse://x-callback-url/play"
                var separator = "?"
                for item in h.items {
                    s += "\(separator)url=\(encode(item.streamURL))"
                    separator = "&"
                    if let position = item.resumeSeconds, position >= 1 {
                        s += "&position=\(Int(position))"
                    }
                    if let filename = item.filename { s += "&filename=\(encode(filename))" }
                    if let sub = item.subtitleURL { s += "&sub=\(encode(sub))" }
                }
                if let success = h.successURL { s += "&x-success=\(encode(success))" }
                if let error = h.errorURL { s += "&x-error=\(encode(error))" }
                return URL(string: s)
            },
            reportsPosition: true,
            acceptsResume: true,
            supportsPlaylist: true
        ),
        ExternalPlayer(
            id: "vlc", name: "VLC", probeScheme: "vlc-x-callback",
            makeURL: { h in
                var s = "vlc-x-callback://x-callback-url/stream?url=\(encode(h.primary.streamURL))"
                if let sub = h.primary.subtitleURL { s += "&sub=\(encode(sub))" }
                if let filename = h.primary.filename { s += "&filename=\(encode(filename))" }
                return URL(string: s)
            }
        ),
        ExternalPlayer(
            id: "nplayer", name: "nPlayer", probeScheme: "nplayer-http",
            makeURL: { h in
                // nPlayer's documented form: prefix the URL's scheme with
                // "nplayer-" (http → nplayer-http). No other parameters.
                URL(string: "nplayer-\(h.primary.streamURL)")
            }
        ),
        ExternalPlayer(
            id: "vidhub", name: "VidHub", probeScheme: "open-vidhub",
            makeURL: { h in
                var s = "open-vidhub://x-callback-url/open?url=\(encode(h.primary.streamURL))"
                if let sub = h.primary.subtitleURL { s += "&sub=\(encode(sub))" }
                return URL(string: s)
            }
        ),
        ExternalPlayer(
            id: "senplayer", name: "SenPlayer", probeScheme: "senplayer",
            makeURL: { h in
                // Only `url` — SenPlayer's play action takes no subtitle,
                // position or callback parameter (its other documented action
                // is `/download`).
                URL(string: "senplayer://x-callback-url/play?url=\(encode(h.primary.streamURL))")
            }
        ),
    ]

    /// The players actually installed on this Apple TV, catalog order.
    static var installed: [ExternalPlayer] {
        catalog.filter(\.isInstalled)
    }

    static func player(id: String) -> ExternalPlayer? {
        catalog.first { $0.id == id }
    }

    // Legacy convenience (Sources-page "Play in Infuse" context action).
    static var isInfuseInstalled: Bool {
        player(id: "infuse")?.isInstalled ?? false
    }

    static func openInInfuse(urlString: String) {
        player(id: "infuse")?.open(streamURL: urlString)
    }

    private static func encode(_ urlString: String) -> String {
        urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryValue) ?? urlString
    }
}

/// The playback we last handed to an external player, remembered across app
/// launches.
///
/// tvOS suspends (and routinely KILLS) us the moment the other app takes the
/// screen, so this cannot live in memory: Infuse's `x-success` callback can
/// arrive minutes later into a cold-launched process. One slot — the newest
/// handoff is the only one that can still be playing.
enum ExternalPlaybackSession {
    /// One video we handed over, with everything needed to record progress for
    /// it without the app being alive in between.
    struct Item: Codable {
        let meta: MetaItem
        let video: MetaVideo?
        let streamURL: String
        /// Runtime, when we know it. The callback returns a POSITION only, and
        /// progress is meaningless without something to measure it against.
        let durationSeconds: Double?
    }

    struct Pending: Codable {
        /// In playback order — `items[0]` started, the rest are the playlist
        /// queued behind it.
        let items: [Item]
        let playerID: String
        let playerName: String
        let startedAt: Date
    }

    private static let storageKey = "orivio.externalPlayback.pending.v1"

    static var pending: Pending? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    static func begin(_ pending: Pending) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Where in the handed-over playlist the player stopped.
    ///
    /// Infuse echoes back the url it finished on. With a playlist that's the
    /// episode the viewer actually stopped in — and because it plays in order,
    /// everything BEFORE it was watched to the end. An unrecognized url means
    /// the callback isn't about this handoff, so nothing is touched.
    static func resolveReturn(_ pending: Pending, returnedURL: String?) -> (stopped: Item, completed: [Item])? {
        guard let returnedURL, !returnedURL.isEmpty else {
            return pending.items.first.map { ($0, []) }
        }
        guard let index = pending.items.firstIndex(where: { $0.streamURL == returnedURL }) else { return nil }
        return (pending.items[index], Array(pending.items.prefix(index)))
    }
}

private extension CharacterSet {
    /// URL-query-VALUE safe (RFC 3986 unreserved only) so an inner URL is fully
    /// percent-encoded and survives as one parameter.
    static let urlQueryValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
