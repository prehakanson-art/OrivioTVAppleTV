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
    static func resolve(
        magnet: String, settings: TorrentSettings, season: Int?, episode: Int?
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
            guard let file = selectFile(files, season: season, episode: episode) else {
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
        var request = URLRequest(url: URL(string: "\(base)/torrents")!)
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

    private static func selectFile(_ files: [TorrFile], season: Int?, episode: Int?) -> TorrFile? {
        let videos = files.filter { videoExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
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
