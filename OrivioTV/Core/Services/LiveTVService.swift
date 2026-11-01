import Foundation

/// One live channel from any source (M3U, Xtream, iptv-org, add-on `tv` catalog).
struct LiveChannel: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var logo: String?
    var group: String
    /// Direct stream URL (nil for add-on channels — their streams resolve at play time).
    var url: String?
    var headers: [String: String] = [:]
    var tvgID: String?
    /// DRM-protected (license via KODIPROP) — refused with a reason.
    var drm = false
    /// Xtream stream id (for Now/Next).
    var xtreamID: Int?
    /// Days of catch-up the provider keeps for this channel (Xtream `tv_archive`,
    /// or an M3U `catchup-days`).
    var archiveDays: Int?
    /// M3U catch-up: `default` / `append` / `shift` / `flussonic` / `xc`, and the
    /// `catchup-source` template.
    var catchupMode: String?
    var catchupSource: String?

    /// The provider keeps recordings of this channel.
    var hasCatchup: Bool { (archiveDays ?? 0) > 0 && (xtreamID != nil || catchupMode != nil) }
    /// Add-on channel: manifest URL + meta id.
    var addonURL: String?
    var metaID: String?

    var isAddon: Bool { addonURL != nil }
}

/// §6.7 sources: the iptv-org public playlists (per Location / Preferred
/// language; language wins), a custom M3U URL, an Xtream login (player_api.php,
/// falling back to get.php), or add-on `tv` catalogs. Cached on disk.
@MainActor
final class LiveTVModel: ObservableObject {
    static let shared = LiveTVModel()

    @Published private(set) var channels: [LiveChannel] = []
    @Published private(set) var groups: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// Guides the playlists announce (`url-tvg` / `x-tvg-url` in the #EXTM3U header).
    @Published private(set) var playlistGuides: [URL] = []
    private var channelsByGroup: [String: [LiveChannel]] = [:]
    private var channelIndex: [String: LiveChannel] = [:]
    private var loadedFingerprint = ""
    private var cacheURL: URL { Persistence.fileURL("livetv-channels.json") }
    private var fingerprintURL: URL { Persistence.fileURL("livetv-channels-fingerprint.txt") }

    private init() {
        channels = Persistence.loadFile([LiveChannel].self, url: cacheURL) ?? []
        // The fingerprint used to live only in memory, so every launch reloaded
        // the whole playlist over the network even when the disk cache matched.
        if let persisted = try? String(contentsOf: fingerprintURL, encoding: .utf8) {
            loadedFingerprint = persisted
        } else if !channels.isEmpty {
            // First launch after the fix: the cache was written by the current
            // settings, so adopt it instead of making the viewer wait through
            // one more full playlist download.
            loadedFingerprint = fingerprint
            let fp = loadedFingerprint
            let url = fingerprintURL
            Task.detached(priority: .utility) { try? fp.write(to: url, atomically: true, encoding: .utf8) }
        }
        rebuildIndexes()
    }

    private var fingerprint: String {
        let s = AppStores.shared.liveTV.value
        let addons = AppStores.shared.addons.enabled.map(\.manifestURL).joined()
        return [s.country, s.language, s.customPlaylistURL, s.xtreamServer, s.xtreamUsername, s.xtreamPassword,
                String(s.useAddonChannels), addons].joined(separator: "|")
    }

    /// The guide sources for this setup.
    var guideSources: [URL] { EPGGuide.sources(AppStores.shared.liveTV.value, playlistGuides: playlistGuides) }

    /// Loads the guide (cached for 12 h) once channels are in.
    func loadGuideIfNeeded() async {
        await loadIfNeeded()
        guard !channels.isEmpty else { return }
        await EPGGuide.shared.loadIfNeeded(channels: channels, sources: guideSources)
    }

    private func rebuildIndexes() {
        var seen = Set<String>()
        groups = channels.map(\.group).filter { seen.insert($0).inserted }
        channelsByGroup = Dictionary(grouping: channels, by: \.group)
        channelIndex = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func channels(in group: String) -> [LiveChannel] { channelsByGroup[group] ?? [] }

    func channel(_ id: String) -> LiveChannel? { channelIndex[id] }

    func loadIfNeeded() async {
        guard fingerprint != loadedFingerprint || channels.isEmpty else { return }
        await reload()
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        let s = AppStores.shared.liveTV.value
        let fp = fingerprint
        var out: [LiveChannel] = []
        var failures: [String] = []
        var guides: [URL] = []

        if !s.xtreamServer.isEmpty, !s.xtreamUsername.isEmpty {
            do { out += try await Xtream.channels(server: s.xtreamServer, user: s.xtreamUsername, pass: s.xtreamPassword) } catch {
                failures.append("IPTV provider: \(error.localizedDescription)")
            }
        }
        if !s.customPlaylistURL.isEmpty, let u = URL(string: s.customPlaylistURL) {
            do {
                let p = try await M3U.fetchPlaylist(u, source: "custom")
                out += p.channels
                guides += p.guides
            } catch { failures.append("Playlist: \(error.localizedDescription)") }
        }
        if out.isEmpty, let u = Self.iptvOrgURL(s) {
            do {
                let p = try await M3U.fetchPlaylist(u, source: "iptvorg")
                out += p.channels
                guides += p.guides
            } catch { failures.append("iptv-org: \(error.localizedDescription)") }
        }
        playlistGuides = guides
        if s.useAddonChannels { out += await addonChannels() }

        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }
        channels = out
        rebuildIndexes()
        EPGGuide.shared.channelsChanged()
        loadedFingerprint = fp
        if out.isEmpty { error = failures.first ?? "No channels found. Set a location, language or playlist in Settings → Content." }
        // Encoding and compressing thousands of channels used to land on the
        // main actor just as the tab and its rows were being built.
        let cacheURL = cacheURL
        let fingerprintURL = fingerprintURL
        Task.detached(priority: .utility) {
            Persistence.saveFile(out, url: cacheURL, compressed: true)
            try? fp.write(to: fingerprintURL, atomically: true, encoding: .utf8)
        }
    }

    /// Language wins over country.
    static func iptvOrgURL(_ s: LiveTVSettings) -> URL? {
        if !s.language.isEmpty {
            let code = Languages.threeLetter[s.language]?.last ?? s.language
            return URL(string: "https://iptv-org.github.io/iptv/languages/\(code).m3u")
        }
        let country = s.country.isEmpty ? (Locale.current.region?.identifier ?? "") : s.country
        guard !country.isEmpty else { return nil }
        return URL(string: "https://iptv-org.github.io/iptv/countries/\(country.lowercased()).m3u")
    }

    private func addonChannels() async -> [LiveChannel] {
        let addons = AppStores.shared.addons.enabled
        var out: [LiveChannel] = []
        for a in addons {
            for c in a.manifest.catalogs where (c.type == "tv" || c.type == "channel") && !c.requiresExtra {
                let items = (try? await AddonClient.catalog(a, type: c.type, id: c.id)) ?? []
                for m in items.prefix(300) {
                    out.append(LiveChannel(id: "addon:\(a.manifest.id):\(m.id)", name: m.name, logo: m.logo ?? m.poster,
                                           group: c.name.isEmpty ? a.displayName : c.name, addonURL: a.manifestURL, metaID: m.id))
                }
            }
        }
        return out
    }
}

// MARK: - M3U

enum M3U {
    static func fetch(_ url: URL, source: String) async throws -> [LiveChannel] {
        try await fetchPlaylist(url, source: source).channels
    }

    /// Channels plus the guide URLs the header announces.
    static func fetchPlaylist(_ url: URL, source: String) async throws -> (channels: [LiveChannel], guides: [URL]) {
        let data = try await HTTP.data(url, fresh: true, timeout: 30)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw HTTPError.notJSON }
        let list = parse(text, source: source)
        if list.isEmpty { throw HTTPError.other("The playlist had no channels.") }
        return (list, guideURLs(text))
    }

    /// `#EXTM3U url-tvg="a.xml.gz,b.xml" x-tvg-url="…"` (comma-separated lists allowed).
    static func guideURLs(_ text: String) -> [URL] {
        guard let header = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("#EXTM3U") }) else { return [] }
        let attrs = attributes(String(header))
        return ["url-tvg", "x-tvg-url", "tvg-url"].compactMap { attrs[$0] }
            .flatMap { $0.split(separator: ",") }
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.scheme?.hasPrefix("http") == true }
    }

    static func parse(_ text: String, source: String) -> [LiveChannel] {
        var out: [LiveChannel] = []
        var info: (name: String, attrs: [String: String])?
        // Playlist-wide catch-up defaults on the #EXTM3U line.
        let header = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("#EXTM3U") }).map { attributes(String($0)) } ?? [:]
        var opts: [String: String] = [:]
        var drm = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                let attrs = attributes(line)
                let name = line.range(of: ",", options: .backwards).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                info = (name, attrs)
                opts = [:]
                drm = false
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let kv = line.dropFirst("#EXTVLCOPT:".count).split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "http-user-agent": opts["User-Agent"] = kv[1]
                case "http-referrer", "http-referer": opts["Referer"] = kv[1]
                case "http-origin": opts["Origin"] = kv[1]
                default: break
                }
            } else if line.hasPrefix("#KODIPROP:") {
                if line.localizedCaseInsensitiveContains("license_type") || line.localizedCaseInsensitiveContains("license_key") { drm = true }
            } else if !line.isEmpty, !line.hasPrefix("#"), let i = info {
                // Piped options: url|User-Agent=…&Referer=…
                var url = line
                var headers = opts
                if let bar = line.firstIndex(of: "|") {
                    url = String(line[..<bar])
                    for pair in line[line.index(after: bar)...].split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { headers[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                    }
                }
                let name = i.name.isEmpty ? (i.attrs["tvg-name"] ?? "Channel") : i.name
                let group = (i.attrs["group-title"]?.split(separator: ";").first.map(String.init)).flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
                let tvg = i.attrs["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }
                var c = LiveChannel(id: "\(source):\(tvg ?? name)|\(url.hashValue)", name: name, logo: i.attrs["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 },
                                    group: group, url: url, headers: headers, tvgID: tvg, drm: drm)
                // Catch-up: catchup="default|append|shift|flussonic|xc", catchup-source, catchup-days
                // (older playlists: timeshift="7" / tvg-rec="7").
                let attr = { (k: String) in (i.attrs[k] ?? header[k]).flatMap { $0.isEmpty ? nil : $0 } }
                let days = (attr("catchup-days") ?? attr("timeshift") ?? attr("tvg-rec")).flatMap(Int.init)
                var mode = (attr("catchup") ?? attr("catchup-type"))?.lowercased()
                if mode == nil, days != nil { mode = "shift" }
                if let mode, ["default", "append", "shift", "timeshift", "flussonic", "flussonic-hls", "flussonic-ts", "fs", "xc"].contains(mode),
                   mode != "default" || attr("catchup-source") != nil {
                    c.catchupMode = mode
                    c.catchupSource = attr("catchup-source")
                    c.archiveDays = min(days ?? 3, 14)
                }
                out.append(c)
                info = nil
            }
        }
        // Stable ids: hashValue is per-launch; use name+url instead.
        return out.map { c in
            var c = c
            c.id = "\(source):\(c.tvgID ?? c.name)|\(c.url ?? "")"
            return c
        }
    }

    private static func attributes(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"([a-zA-Z0-9\-]+)="([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = line as NSString
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        return out
    }
}

// MARK: - Xtream Codes

enum Xtream {
    struct EPG { var now: String?; var next: String?; var nextStart: Date? }

    private static func base(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("http") { s = "http://" + s }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func api(_ server: String, _ user: String, _ pass: String, _ action: String, _ extra: String = "") -> URL? {
        URL(string: "\(base(server))/player_api.php?username=\(HTTP.encodeComponent(user))&password=\(HTTP.encodeComponent(pass))&action=\(action)\(extra)")
    }

    /// The provider's full XMLTV guide.
    static func xmltvURL(server: String, user: String, pass: String) -> URL? {
        URL(string: "\(base(server))/xmltv.php?username=\(HTTP.encodeComponent(user))&password=\(HTTP.encodeComponent(pass))")
    }

    /// The server's time zone (`server_info.timezone`): catch-up start times
    /// are written in it. Fetched once per server.
    private static var zones: [String: TimeZone] = [:]
    static func serverTimeZone(server: String, user: String, pass: String) async -> TimeZone {
        if let z = zones[server] { return z }
        let u = URL(string: "\(base(server))/player_api.php?username=\(HTTP.encodeComponent(user))&password=\(HTTP.encodeComponent(pass))")
        var zone = TimeZone.current
        if let u, let obj = try? JSONSerialization.jsonObject(with: await HTTP.data(u, fresh: true, timeout: 10)) as? [String: Any],
           let info = obj["server_info"] as? [String: Any], let id = info["timezone"] as? String, let z = TimeZone(identifier: id) {
            zone = z
        }
        zones[server] = zone
        return zone
    }

    /// A recording of `programme` on an archive channel:
    /// `/timeshift/user/pass/<minutes>/<yyyy-MM-dd:HH-mm>/<stream>.ts` (server time).
    static func catchupURL(server: String, user: String, pass: String, streamID: Int, start: Date, minutes: Int, zone: TimeZone) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        return URL(string: "\(base(server))/timeshift/\(HTTP.encodeComponent(user))/\(HTTP.encodeComponent(pass))/\(max(1, minutes))/\(f.string(from: start))/\(streamID).ts")
    }

    static func channels(server: String, user: String, pass: String) async throws -> [LiveChannel] {
        do {
            guard let cu = api(server, user, pass, "get_live_categories"), let su = api(server, user, pass, "get_live_streams") else { throw HTTPError.badURL(server) }
            let cats = (try? JSONSerialization.jsonObject(with: await HTTP.data(cu, fresh: true, timeout: 30))) as? [[String: Any]] ?? []
            var names: [String: String] = [:]
            for c in cats { if let id = c["category_id"].map({ "\($0)" }) { names[id] = c["category_name"] as? String } }
            guard let streams = try JSONSerialization.jsonObject(with: await HTTP.data(su, fresh: true, timeout: 45)) as? [[String: Any]] else {
                throw HTTPError.notJSON
            }
            return streams.compactMap { s in
                guard let sid = (s["stream_id"] as? Int) ?? Int("\(s["stream_id"] ?? "")") else { return nil }
                let cat = s["category_id"].map { "\($0)" } ?? ""
                // tv_archive / tv_archive_duration arrive as numbers or strings.
                func int(_ k: String) -> Int? { (s[k] as? Int) ?? Int("\(s[k] ?? "")") }
                let archive = (int("tv_archive") ?? 0) > 0 ? int("tv_archive_duration").flatMap { $0 > 0 ? min($0, 14) : nil } : nil
                return LiveChannel(id: "xtream:\(sid)", name: s["name"] as? String ?? "Channel",
                                   logo: (s["stream_icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }, group: names[cat] ?? "Other",
                                   url: "\(base(server))/live/\(user)/\(pass)/\(sid).m3u8", tvgID: s["epg_channel_id"] as? String,
                                   xtreamID: sid, archiveDays: archive)
            }
        } catch {
            // Fall back to the M3U export.
            guard let u = URL(string: "\(base(server))/get.php?username=\(HTTP.encodeComponent(user))&password=\(HTTP.encodeComponent(pass))&type=m3u_plus&output=m3u8") else { throw error }
            return try await M3U.fetch(u, source: "xtream")
        }
    }

    static func epg(server: String, user: String, pass: String, streamID: Int) async -> EPG? {
        guard let u = api(server, user, pass, "get_short_epg", "&stream_id=\(streamID)&limit=2"),
              let obj = try? JSONSerialization.jsonObject(with: await HTTP.data(u, fresh: true, timeout: 10)) as? [String: Any],
              let list = obj["epg_listings"] as? [[String: Any]], !list.isEmpty else { return nil }
        func title(_ e: [String: Any]) -> String? {
            guard let t = e["title"] as? String else { return nil }
            return Data(base64Encoded: t).flatMap { String(data: $0, encoding: .utf8) } ?? t
        }
        let nextStart = list.count > 1 ? (list[1]["start_timestamp"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } : nil
        return EPG(now: title(list[0]), next: list.count > 1 ? title(list[1]) : nil, nextStart: nextStart)
    }
}

// MARK: - Playback

@MainActor
enum LivePlayback {
    /// A channel's playable stream.
    struct Source {
        let url: URL
        let headers: [String: String]
        let stream: Stream
        /// Demuxer-only (raw TS, RTMP/UDP…) → FFmpeg.
        let demuxer: Bool
    }

    /// Resolves and presents a channel; `list` is what channel up/down moves
    /// through (default: the channel's own category). Returns an error message
    /// when it can't play.
    static func play(_ c: LiveChannel, list: [LiveChannel]? = nil) async -> String? {
        switch await resolve(c) {
        case .failure(let e): return e.message
        case .success(let src):
            AppStores.shared.liveTV.noteRecent(c.id)
            let channels = list ?? LiveTVModel.shared.channels(in: c.group)
            PlayerPresenter.shared.present(request(for: c, source: src, list: channels))
            return nil
        }
    }

    struct Failure: Error { let message: String }

    static func meta(for c: LiveChannel) -> MetaItem {
        MetaItem(id: c.id, type: "tv", name: c.name, poster: c.logo, logo: c.logo, genres: [c.group])
    }

    static func entry(for c: LiveChannel, source: Source) -> StreamEntry {
        StreamEntry(stream: source.stream, addonName: c.group, addonID: "livetv", index: 0)
    }

    static func request(for c: LiveChannel, source: Source, list: [LiveChannel]) -> PlaybackRequest {
        let e = entry(for: c, source: source)
        var r = PlaybackRequest(meta: meta(for: c), video: nil, entry: e, allEntries: [e], forceDemuxer: source.demuxer,
                                url: source.url, headers: source.headers, isLive: true)
        r.liveChannels = list.isEmpty ? nil : list
        return r
    }

    static func resolve(_ c: LiveChannel) async -> Result<Source, Failure> {
        if c.drm { return .failure(Failure(message: "\(c.name) is DRM-protected and can't be played.")) }
        var url: URL?
        var headers = c.headers
        var stream = Stream(name: c.group, title: c.name, url: c.url)
        if c.isAddon, let addonURL = c.addonURL, let metaID = c.metaID, let addon = AppStores.shared.addons.addon(id: addonURL) {
            let streams = (try? await AddonClient.streams(addon, type: "tv", id: metaID, timeout: 15)) ?? []
            guard let s = streams.first(where: { $0.url != nil || $0.ytId != nil }) else { return .failure(Failure(message: "\(c.name) has no stream right now.")) }
            stream = s
            url = s.url.flatMap(URL.init(string:))
            if let h = s.behaviorHints?.proxyHeaders?.request { headers.merge(h) { a, _ in a } }
        } else if let u = c.url {
            url = URL(string: u)
        }
        // YouTube live (an M3U entry pointing at youtube.com, or an add-on ytId stream).
        if let yt = stream.ytId ?? url.flatMap({ TrailerService.isYouTube($0) ? $0.absoluteString : nil }) {
            guard let hls = await TrailerService.liveHLS(yt) else { return .failure(Failure(message: "\(c.name) isn't live on YouTube right now.")) }
            url = hls
            headers = [:]
        }
        guard let url else { return .failure(Failure(message: "\(c.name) has no playable address.")) }
        let scheme = url.scheme?.lowercased() ?? ""
        let path = url.path.lowercased()
        // Demuxer-only streams (raw TS, RTMP/UDP…) go straight to FFmpeg.
        let demuxer = !["http", "https"].contains(scheme) || path.hasSuffix(".ts") || path.hasSuffix(".mpd")
        return .success(Source(url: url, headers: headers, stream: stream, demuxer: demuxer))
    }

    /// Whether `p` can be played back from the archive (finished, or on now = Start Over).
    static func canPlayFromArchive(_ c: LiveChannel, _ p: EPGProgramme, now: Date = Date()) -> Bool {
        guard c.hasCatchup, p.start < now, let days = c.archiveDays else { return false }
        return p.start >= Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(days) * 86400))
    }

    /// The recording's address: Xtream `timeshift`, or the playlist's catch-up scheme.
    static func catchupURL(_ c: LiveChannel, _ p: EPGProgramme) async -> URL? {
        let s = AppStores.shared.liveTV.value
        if let sid = c.xtreamID, !s.xtreamServer.isEmpty {
            let zone = await Xtream.serverTimeZone(server: s.xtreamServer, user: s.xtreamUsername, pass: s.xtreamPassword)
            return Xtream.catchupURL(server: s.xtreamServer, user: s.xtreamUsername, pass: s.xtreamPassword, streamID: sid,
                                     start: p.start, minutes: Int((p.duration / 60).rounded(.up)), zone: zone)
        }
        guard let mode = c.catchupMode, let live = c.url else { return nil }
        return Catchup.url(mode: mode, source: c.catchupSource, live: live, start: p.start, end: p.end, now: Date())
    }

    /// Catch-up: a past programme — or one on now, from its start — on a channel
    /// whose provider keeps an archive.
    static func playCatchup(_ c: LiveChannel, _ p: EPGProgramme) async -> String? {
        guard c.hasCatchup else { return "\(c.name) has no catch-up." }
        guard let url = await catchupURL(c, p) else { return "Couldn't build the catch-up address." }
        // "recording": seekable like a file, but never saved to Continue Watching or scrobbled.
        let meta = MetaItem(id: "\(c.id)@\(p.id)", type: "recording", name: p.title, poster: c.logo, logo: c.logo, description: p.desc, genres: [c.name])
        let stream = Stream(name: c.name, title: p.title, url: url.absoluteString)
        let entry = StreamEntry(stream: stream, addonName: c.name, addonID: "livetv", index: 0)
        // A recording: a seekable .ts (FFmpeg by container, through the disk cache).
        PlayerPresenter.shared.present(PlaybackRequest(meta: meta, video: nil, entry: entry, allEntries: [entry], forceDemuxer: false,
                                                       url: url, headers: c.headers, isLive: false))
        return nil
    }
}

// MARK: - M3U catch-up

/// Builds a recording URL from a playlist's catch-up scheme. The placeholder
/// set is the common one (Kodi IPTV Simple / TiviMate): {utc} {start}
/// {utcend} {end} {lutc} {now} {timestamp} {duration[:divisor]} {offset[:divisor]}
/// {Y} {m} {d} {H} {M} {S}, and {utc:<format>} with Y m d H M S letters.
enum Catchup {
    static func url(mode: String, source: String?, live: String, start: Date, end: Date, now: Date) -> URL? {
        let template: String
        switch mode {
        case "default":
            guard let source else { return nil }
            template = source
        case "append":
            guard let source else { return nil }
            template = live + source
        case "shift", "timeshift":
            template = live + (live.contains("?") ? "&" : "?") + "utc={utc}&lutc={lutc}"
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            // http://host/ch/index.m3u8 (or /mpegts) → /ch/archive-{start}-{duration}.m3u8 (or timeshift_abs-{start}.ts)
            guard let u = URL(string: live), var parts = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
            parts.query = nil
            parts.fragment = nil
            guard let bare = parts.url else { return nil }
            let base = bare.deletingLastPathComponent().absoluteString
            let ts = mode == "flussonic-ts" || u.lastPathComponent == "mpegts" || u.pathExtension == "ts"
            let query = u.query.map { "?\($0)" } ?? ""
            template = base + (ts ? "timeshift_abs-{utc}.ts" : "archive-{utc}-{duration}.m3u8") + query
        case "xc":
            // http://host/live/u/p/id.ext → http://host/timeshift/u/p/{minutes}/{Y-m-d:H-M}/id.ts
            guard let u = URL(string: live), u.pathComponents.count >= 5 else { return nil }
            let parts = u.pathComponents
            let id = (parts[parts.count - 1] as NSString).deletingPathExtension
            let user = parts[parts.count - 3], pass = parts[parts.count - 2]
            let host = live.components(separatedBy: "/live/").first ?? ""
            template = "\(host)/timeshift/\(user)/\(pass)/{duration:60}/{Y}-{m}-{d}:{H}-{M}/\(id).ts"
        default:
            return nil
        }
        return URL(string: fill(template, start: start, end: end, now: now))
    }

    static func fill(_ template: String, start: Date, end: Date, now: Date) -> String {
        let t = template.replacingOccurrences(of: "${", with: "{")
        guard let re = try? NSRegularExpression(pattern: #"\{([a-zA-Z]+)(?::([^}]*))?\}"#) else { return t }
        let ns = t as NSString
        var out = ""
        var last = 0
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func pad(_ v: Int, _ n: Int = 2) -> String { String(format: "%0\(n)d", v) }
        func stamp(_ d: Date, _ format: String?) -> String {
            guard let format, !format.isEmpty else { return String(Int(d.timeIntervalSince1970)) }
            let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            var s = ""
            for ch in format {
                switch ch {
                case "Y": s += pad(c.year ?? 0, 4)
                case "m": s += pad(c.month ?? 0)
                case "d": s += pad(c.day ?? 0)
                case "H": s += pad(c.hour ?? 0)
                case "M": s += pad(c.minute ?? 0)
                case "S": s += pad(c.second ?? 0)
                default: s.append(ch)
                }
            }
            return s
        }
        let duration = Int(end.timeIntervalSince(start))
        let offset = Int(now.timeIntervalSince(start))
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let arg = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
            let divisor = arg.flatMap(Int.init).map { max(1, $0) } ?? 1
            let value: String?
            switch name {
            case "utc", "start": value = stamp(start, arg)
            case "utcend", "end": value = stamp(end, arg)
            case "lutc", "now", "timestamp": value = stamp(now, arg)
            case "duration": value = String(duration / divisor)
            case "offset": value = String(offset / divisor)
            case "y": value = ns.substring(with: m.range(at: 1)) == "Y" ? pad(c.year ?? 0, 4) : nil
            case "m": value = ns.substring(with: m.range(at: 1)) == "m" ? pad(c.month ?? 0) : pad(c.minute ?? 0)
            case "d": value = pad(c.day ?? 0)
            case "h": value = pad(c.hour ?? 0)
            case "s": value = pad(c.second ?? 0)
            default: value = nil
            }
            out += value ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
