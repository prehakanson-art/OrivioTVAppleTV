import Foundation

/// Client for a TorrServer instance (github.com/YouROK/TorrServer) — the same
/// torrent-streaming server the Android app bundles locally, here reached over
/// HTTP on the user's network. TorrServer does the peering; the Apple TV just
/// plays the HLS/HTTP `/stream` URL.
enum TorrServerService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    enum P2PResult {
        case success(url: String, filename: String?)
        case notConfigured
        case failed(String)
    }

    /// Add a magnet to TorrServer, pick the right video file, and return a
    /// directly-playable `/stream` URL.
    ///
    /// `fileIdx` is the addon-supplied index of the wanted file inside the
    /// TORRENT's own file list (Stremio's `Stream.fileIdx`, 0-based, counting
    /// every file including samples and subtitles). It was ignored here — the
    /// same defect the debrid path had — so a season pack fell through to the
    /// filename heuristic and, when that missed, played the LARGEST file:
    /// reliably the wrong episode. Defaulted to nil so the existing call site
    /// keeps compiling until it passes the value through.
    static func resolve(
        magnet: String, settings: TorrentSettings, season: Int?, episode: Int?,
        fileIdx: Int? = nil
    ) async -> P2PResult {
        guard settings.isConfigured else { return .notConfigured }
        let base = settings.normalizedServerURL
        do {
            guard let hash = try await addTorrent(base: base, magnet: magnet), !hash.isEmpty else {
                return .failed("TorrServer didn't accept the torrent")
            }
            // Poll briefly for the file list to populate.
            var files: [TorrFile] = []
            for _ in 0..<10 {
                files = try await fileStats(base: base, hash: hash)
                if !files.isEmpty { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let file = selectFile(files, season: season, episode: episode, fileIdx: fileIdx) else {
                return .failed("No video file found in the torrent")
            }
            let url = streamURL(base: base, magnet: magnet, index: file.id)
            return .success(url: url, filename: (file.path as NSString).lastPathComponent)
        } catch {
            return .failed("Can't reach TorrServer at \(base)")
        }
    }

    /// Reachability + version check for the settings "Test" button.
    static func ping(_ settings: TorrentSettings) async -> Bool {
        let base = settings.normalizedServerURL
        guard let url = URL(string: "\(base)/echo") else { return false }
        guard let (_, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: API

    private static func addTorrent(base: String, magnet: String) async throws -> String? {
        let body: [String: Any] = ["action": "add", "link": magnet, "save_to_db": false]
        let data = try await post(base: base, body: body)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["hash"] as? String
    }

    private static func fileStats(base: String, hash: String) async throws -> [TorrFile] {
        let data = try await post(base: base, body: ["action": "get", "hash": hash])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["file_stats"] as? [[String: Any]] else { return [] }
        return list.enumerated().map { i, f in
            TorrFile(
                id: (f["id"] as? Int) ?? (i + 1),
                path: (f["path"] as? String) ?? "",
                length: (f["length"] as? Int64) ?? Int64((f["length"] as? Int) ?? 0)
            )
        }
    }

    private static func post(base: String, body: [String: Any]) async throws -> Data {
        // NOT force-unwrapped: `base` is a free-text server address the user
        // types into settings (`ping()` merely fails the Test button, it never
        // stops them saving a bad one), so a stray space or a pasted quote made
        // `URL(string:)` return nil and playing a P2P source TRAPPED. Throwing
        // instead lands in `resolve`'s catch, which shows "Can't reach
        // TorrServer at …" — the right message for an unusable address.
        guard let url = URL(string: "\(base)/torrents") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        return data
    }

    static func streamURL(base: String, magnet: String, index: Int) -> String {
        let encoded = magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryValueSafe) ?? magnet
        return "\(base)/stream?link=\(encoded)&index=\(index)&play"
    }

    // MARK: File selection

    private struct TorrFile { let id: Int; let path: String; let length: Int64 }
    private static let videoExtensions = ["mkv", "mp4", "avi", "mov", "m4v", "ts", "webm"]

    private static func isVideo(_ file: TorrFile) -> Bool {
        videoExtensions.contains((file.path as NSString).pathExtension.lowercased())
    }

    /// Pick the wanted file. Order of preference matches the debrid sibling
    /// (`DebridService.selectFile`):
    /// 1. The addon's `fileIdx`, mapped onto TorrServer's own ids. Unlike most
    ///    debrid providers, this list can be indexed safely: `file_stats` is
    ///    the torrent's COMPLETE file list (nothing filtered — this method does
    ///    the video filtering itself) and `TorrFile.id` is that list's position,
    ///    which is exactly what `fileIdx` counts. The pick must still be a
    ///    video file, so a stale/bogus index falls through instead of handing
    ///    the player an .nfo.
    /// 2. For series, a filename matching SxxExx / Sxx.Exx / SxE.
    /// 3. The largest video file.
    private static func selectFile(_ files: [TorrFile], season: Int?, episode: Int?,
                                   fileIdx: Int? = nil) -> TorrFile? {
        // TorrServer numbers files from 1 (and `fileStats` falls back to `i + 1`
        // for the same reason), while `fileIdx` counts from 0 — so the offset is
        // the list's own lowest id rather than a hardcoded 1. That also keeps
        // this correct if a build ever numbers from 0.
        if let fileIdx, fileIdx >= 0, let base = files.map(\.id).min(),
           let pick = files.first(where: { $0.id - base == fileIdx }), isVideo(pick) {
            return pick
        }
        let videos = files.filter(isVideo)
        guard !videos.isEmpty else { return files.max { $0.length < $1.length } }
        if let season, let episode {
            let patterns = [
                String(format: "s%02de%02d", season, episode),
                String(format: "%dx%02d", season, episode),
                String(format: "s%02d.e%02d", season, episode)
            ]
            if let match = videos.first(where: { file in
                let name = file.path.lowercased()
                return patterns.contains { name.contains($0) }
            }) { return match }
        }
        return videos.max { $0.length < $1.length }
    }
}

private extension CharacterSet {
    static let urlQueryValueSafe: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
