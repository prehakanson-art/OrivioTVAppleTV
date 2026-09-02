import Foundation

/// One file already sitting in a debrid provider's cloud storage. `directURL`
/// is a ready-to-play link when the provider hands one out with the listing
/// (Premiumize / Real-Debrid / AllDebrid); TorBox needs a per-file resolve
/// step, so those carry the ids instead and `resolveURL` fetches on demand.
struct CloudFile: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int64?
    var directURL: String?
    var torboxTorrentID: Int?
    var torboxFileID: Int?

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "mov", "m4v", "wmv", "flv", "ts", "webm", "mpg", "mpeg"
    ]
    var isVideo: Bool {
        CloudFile.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    /// Best-effort movie/show split from the filename: SxxExx, 1x02, or an
    /// explicit "Season"/"Episode" marks it as a show.
    var isSeries: Bool {
        let patterns = [#"(?i)s\d{1,2}[ ._-]?e\d{1,2}"#,
                        #"(?i)\b\d{1,2}x\d{1,2}\b"#,
                        #"(?i)\b(season|episode)\b"#]
        return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }
    var sizeLabel: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Lists (and resolves) the files a user already has in their debrid cloud —
/// the tvOS equivalent of Android's CloudLibrary providers (Premiumize +
/// TorBox), plus Real-Debrid downloads and AllDebrid saved links.
enum CloudLibraryService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Providers that expose a browsable cloud library.
    static let supportedProviders: [DebridProvider] = [.premiumize, .realDebrid, .torbox, .allDebrid]

    static func list(provider: DebridProvider, apiKey: String) async -> [CloudFile] {
        guard !apiKey.isEmpty else { return [] }
        do {
            switch provider {
            case .premiumize: return try await listPremiumize(apiKey)
            case .realDebrid: return try await listRealDebrid(apiKey)
            case .torbox:     return try await listTorbox(apiKey)
            case .allDebrid:  return try await listAllDebrid(apiKey)
            }
        } catch {
            NSLog("[CloudLibrary] %@ list failed: %@", provider.rawValue, error.localizedDescription)
            return []
        }
    }

    /// A directly-playable URL for a cloud file (resolves TorBox on demand).
    static func resolveURL(_ file: CloudFile, provider: DebridProvider, apiKey: String) async -> String? {
        if let directURL = file.directURL { return directURL }
        guard provider == .torbox, let tid = file.torboxTorrentID, let fid = file.torboxFileID else { return nil }
        var comps = URLComponents(string: "https://api.torbox.app/v1/api/torrents/requestdl")!
        comps.queryItems = [
            .init(name: "token", value: apiKey),
            .init(name: "torrent_id", value: String(tid)),
            .init(name: "file_id", value: String(fid))
        ]
        guard let url = comps.url else { return nil }
        let data = try? await session.data(from: url).0
        guard let data, let resp = try? JSONDecoder().decode(TorboxDL.self, from: data) else { return nil }
        return resp.data
    }

    // MARK: Premiumize — /item/listall gives flat files with direct links.

    private static func listPremiumize(_ key: String) async throws -> [CloudFile] {
        var comps = URLComponents(string: "https://www.premiumize.me/api/item/listall")!
        comps.queryItems = [.init(name: "apikey", value: key)]
        let (data, _) = try await session.data(from: comps.url!)
        let resp = try JSONDecoder().decode(PremiumizeListAll.self, from: data)
        return (resp.files ?? []).map {
            CloudFile(id: $0.id ?? UUID().uuidString, name: $0.name ?? "File",
                      size: $0.size.map(Int64.init), directURL: $0.stream_link ?? $0.link)
        }
    }

    // MARK: Real-Debrid — /downloads are already unrestricted direct links.

    private static func listRealDebrid(_ key: String) async throws -> [CloudFile] {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/downloads?limit=200")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        let rows = try JSONDecoder().decode([RealDebridDownload].self, from: data)
        return rows.map {
            CloudFile(id: $0.id ?? UUID().uuidString, name: $0.filename ?? "File",
                      size: $0.filesize, directURL: $0.download)
        }
    }

    // MARK: TorBox — mylist gives torrents+files; link resolved on play.

    private static func listTorbox(_ key: String) async throws -> [CloudFile] {
        var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        let resp = try JSONDecoder().decode(TorboxList.self, from: data)
        var out: [CloudFile] = []
        for torrent in resp.data ?? [] {
            for file in torrent.files ?? [] {
                out.append(CloudFile(
                    id: "\(torrent.id ?? 0):\(file.id ?? 0)",
                    name: file.short_name ?? file.name ?? "File",
                    size: file.size, directURL: nil,
                    torboxTorrentID: torrent.id, torboxFileID: file.id
                ))
            }
        }
        return out
    }

    // MARK: AllDebrid — saved links (already unlocked direct URLs).

    private static func listAllDebrid(_ key: String) async throws -> [CloudFile] {
        var comps = URLComponents(string: "https://api.alldebrid.com/v4/user/links")!
        comps.queryItems = [.init(name: "agent", value: "nuvio"), .init(name: "apikey", value: key)]
        let (data, _) = try await session.data(from: comps.url!)
        let resp = try JSONDecoder().decode(AllDebridLinks.self, from: data)
        return (resp.data?.links ?? []).map {
            CloudFile(id: $0.link ?? UUID().uuidString, name: $0.filename ?? "File",
                      size: $0.size, directURL: $0.link)
        }
    }

    // MARK: - Response DTOs (all tolerant / optional)

    private struct PremiumizeListAll: Decodable {
        let files: [PMFile]?
        struct PMFile: Decodable { let id: String?; let name: String?; let size: Double?; let link: String?; let stream_link: String? }
    }
    private struct RealDebridDownload: Decodable { let id: String?; let filename: String?; let filesize: Int64?; let download: String? }
    private struct TorboxList: Decodable {
        let data: [TorboxTorrent]?
        struct TorboxTorrent: Decodable { let id: Int?; let name: String?; let files: [TorboxFile]? }
        struct TorboxFile: Decodable { let id: Int?; let name: String?; let short_name: String?; let size: Int64? }
    }
    private struct TorboxDL: Decodable { let data: String? }
    private struct AllDebridLinks: Decodable {
        let data: Payload?
        struct Payload: Decodable { let links: [ADLink]? }
        struct ADLink: Decodable { let link: String?; let filename: String?; let size: Int64? }
    }
}
