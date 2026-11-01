import Foundation

enum DebridError: LocalizedError {
    case notCached(DebridProvider)
    case noKey
    case noFile
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .notCached(let p): return "This torrent isn't cached on \(p.label). Try another source."
        case .noKey: return "Add a debrid API key, or turn on P2P (TorrServer) to play torrent sources."
        case .noFile: return "No playable video file in this torrent."
        case .provider(let s): return s
        }
    }
}

/// A file inside a debrid torrent/cloud item.
struct DebridFile: Hashable {
    var id: String
    var name: String
    var bytes: Int64
    var link: String?
}

/// Real-Debrid / Premiumize / TorBox / AllDebrid. **Preferred provider** first, then the others.
enum DebridService {
    static let videoExtensions = ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "wmv", "webm", "flv", "mpg", "mpeg"]
    private static let rdOpenClientID = "X245A4XAIBGVM"

    // MARK: Resolve

    /// Resolves a torrent stream to a direct link via the configured providers in order.
    @MainActor
    static func resolve(_ stream: Stream, season: Int?, episode: Int?, onProvider: ((DebridProvider) -> Void)? = nil) async throws -> URL {
        let settings = AppStores.shared.debrid.value
        guard let hash = stream.infoHash else { throw DebridError.noFile }
        let providers = settings.configured
        guard !providers.isEmpty else { throw DebridError.noKey }
        var lastError: Error = DebridError.noKey
        for p in providers {
            guard let key = settings.key(p) else { continue }
            onProvider?(p)
            do {
                return try await resolve(provider: p, key: key, hash: hash, magnet: stream.magnetURI ?? "magnet:?xt=urn:btih:\(hash)",
                                         fileIdx: stream.fileIdx, filename: stream.behaviorHints?.filename, season: season, episode: episode)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func resolve(provider: DebridProvider, key: String, hash: String, magnet: String, fileIdx: Int?, filename: String?,
                        season: Int?, episode: Int?) async throws -> URL {
        switch provider {
        case .realDebrid: return try await RealDebrid.resolve(key: key, magnet: magnet, fileIdx: fileIdx, filename: filename, season: season, episode: episode)
        case .premiumize: return try await Premiumize.resolve(key: key, magnet: magnet, filename: filename, season: season, episode: episode)
        case .torbox: return try await TorBox.resolve(key: key, magnet: magnet, hash: hash, filename: filename, season: season, episode: episode)
        case .allDebrid: return try await AllDebrid.resolve(key: key, magnet: magnet, filename: filename, season: season, episode: episode)
        }
    }

    /// `fileIdx` is honoured only for Real-Debrid and TorrServer; the others
    /// renumber, so match by `SxxExx` (or the filename), then the largest video.
    static func pickFile(_ files: [DebridFile], filename: String?, season: Int?, episode: Int?) -> DebridFile? {
        let videos = files.filter { f in videoExtensions.contains((f.name as NSString).pathExtension.lowercased()) && !f.name.lowercased().contains("sample") }
        let pool = videos.isEmpty ? files : videos
        if let filename, let exact = pool.first(where: { ($0.name as NSString).lastPathComponent == filename }) { return exact }
        if let s = season, let e = episode {
            let patterns = [String(format: "s%02de%02d", s, e), String(format: "%dx%02d", s, e), String(format: "s%de%d", s, e)]
            if let m = pool.first(where: { f in patterns.contains { f.name.lowercased().contains($0) } }) { return m }
        }
        return pool.max { $0.bytes < $1.bytes }
    }

    // MARK: Instant availability (⚡ Cached)

    /// Returns hashes known cached across configured providers that support a check.
    @MainActor
    static func cachedHashes(_ hashes: [String]) async -> Set<String> {
        let settings = AppStores.shared.debrid.value
        guard !hashes.isEmpty else { return [] }
        var out = Set<String>()
        if let k = settings.key(.premiumize) { out.formUnion(await Premiumize.cached(key: k, hashes: hashes)) }
        if let k = settings.key(.torbox) { out.formUnion(await TorBox.cached(key: k, hashes: hashes)) }
        return out
    }

    // MARK: Validation

    static func validate(_ p: DebridProvider, key: String) async -> String? {
        switch p {
        case .realDebrid:
            guard let d = try? await RealDebrid.get("/user", key: key) as? [String: Any] else { return nil }
            return d["username"] as? String ?? "Connected"
        case .premiumize:
            guard let d = try? await Premiumize.get("/account/info", key: key), (d["status"] as? String) == "success" else { return nil }
            return (d["customer_id"]).map { "Customer \($0)" } ?? "Connected"
        case .torbox:
            guard let d = try? await TorBox.get("/user/me", key: key), let data = d["data"] as? [String: Any] else { return nil }
            return data["email"] as? String ?? "Connected"
        case .allDebrid:
            guard let d = try? await AllDebrid.get("/user", key: key, params: [:]), let data = d["data"] as? [String: Any],
                  let user = data["user"] as? [String: Any] else { return nil }
            return user["username"] as? String ?? "Connected"
        }
    }

    // MARK: Real-Debrid device-code OAuth

    struct RDDeviceCode { var deviceCode: String; var userCode: String; var verificationURL: String; var interval: TimeInterval; var expiresAt: Date }

    static func rdStartDeviceCode() async throws -> RDDeviceCode {
        guard let url = URL(string: "https://api.real-debrid.com/oauth/v2/device/code?client_id=\(rdOpenClientID)&new_credentials=yes"),
              let d = try await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any],
              let dc = d["device_code"] as? String, let uc = d["user_code"] as? String else { throw HTTPError.notJSON }
        return RDDeviceCode(deviceCode: dc, userCode: uc, verificationURL: d["verification_url"] as? String ?? "https://real-debrid.com/device",
                            interval: TimeInterval(d["interval"] as? Int ?? 5), expiresAt: Date().addingTimeInterval(TimeInterval(d["expires_in"] as? Int ?? 600)))
    }

    /// Polls for credentials, then exchanges for a token. Returns (access, refresh, clientID, clientSecret).
    static func rdPoll(_ code: RDDeviceCode) async throws -> (String, String, String, String) {
        while Date() < code.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(code.interval * 1_000_000_000))
            guard let url = URL(string: "https://api.real-debrid.com/oauth/v2/device/credentials?client_id=\(rdOpenClientID)&code=\(code.deviceCode)"),
                  let d = try? await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any],
                  let cid = d["client_id"] as? String, let secret = d["client_secret"] as? String else { continue }
            let (access, refresh) = try await rdToken(clientID: cid, secret: secret, code: code.deviceCode)
            return (access, refresh, cid, secret)
        }
        throw HTTPError.other("The code expired.")
    }

    static func rdToken(clientID: String, secret: String, code: String) async throws -> (String, String) {
        guard let url = URL(string: "https://api.real-debrid.com/oauth/v2/token") else { throw HTTPError.badURL("") }
        let body = "client_id=\(clientID)&client_secret=\(secret)&code=\(code)&grant_type=http://oauth.net/grant_type/device/1.0"
        let req = HTTP.request(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8), fresh: true)
        guard let d = try await HTTP.jsonObject(req) as? [String: Any], let a = d["access_token"] as? String,
              let r = d["refresh_token"] as? String else { throw HTTPError.notJSON }
        return (a, r)
    }

    /// Refreshes an expired RD OAuth token (stored refresh token + client creds).
    @MainActor
    static func rdRefreshIfNeeded() async -> Bool {
        let store = AppStores.shared.debrid
        guard let refresh = store.value.rdRefreshToken, let cid = store.value.rdClientID, let secret = store.value.rdClientSecret,
              let (a, r) = try? await rdToken(clientID: cid, secret: secret, code: refresh) else { return false }
        store.update { $0.keys[DebridProvider.realDebrid.rawValue] = a; $0.rdRefreshToken = r }
        return true
    }

    // MARK: AllDebrid PIN

    struct ADPin { var pin: String; var check: String; var userURL: String; var expiresAt: Date }

    static func adStartPin() async throws -> ADPin {
        guard let url = URL(string: "https://api.alldebrid.com/v4.1/pin/get?agent=orivio"),
              let d = (try await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any])?["data"] as? [String: Any],
              let pin = d["pin"] as? String, let check = d["check"] as? String else { throw HTTPError.notJSON }
        return ADPin(pin: pin, check: check, userURL: d["user_url"] as? String ?? "https://alldebrid.com/pin/",
                     expiresAt: Date().addingTimeInterval(TimeInterval(d["expires_in"] as? Int ?? 600)))
    }

    static func adPoll(_ pin: ADPin) async throws -> String {
        while Date() < pin.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            guard let url = URL(string: "https://api.alldebrid.com/v4/pin/check?agent=orivio&check=\(pin.check)&pin=\(pin.pin)"),
                  let d = (try? await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any])?["data"] as? [String: Any] else { continue }
            if let key = d["apikey"] as? String, d["activated"] as? Bool == true { return key }
        }
        throw HTTPError.other("The PIN expired.")
    }
}

// MARK: - Real-Debrid

enum RealDebrid {
    static let base = "https://api.real-debrid.com/rest/1.0"

    static func get(_ path: String, key: String) async throws -> Any {
        guard let url = URL(string: base + path) else { throw HTTPError.badURL(path) }
        return try await HTTP.jsonObject(HTTP.request(url, headers: ["Authorization": "Bearer \(key)"], fresh: true))
    }

    static func post(_ path: String, key: String, form: [String: String]) async throws -> Any {
        guard let url = URL(string: base + path) else { throw HTTPError.badURL(path) }
        let body = form.map { "\($0.key)=\(HTTP.encodeComponent($0.value))" }.joined(separator: "&")
        return try await HTTP.jsonObject(HTTP.request(url, method: "POST", headers: ["Authorization": "Bearer \(key)",
                                                                                    "Content-Type": "application/x-www-form-urlencoded"],
                                                      body: Data(body.utf8), fresh: true))
    }

    static func resolve(key: String, magnet: String, fileIdx: Int?, filename: String?, season: Int?, episode: Int?) async throws -> URL {
        guard let add = try await post("/torrents/addMagnet", key: key, form: ["magnet": magnet]) as? [String: Any],
              let id = add["id"] as? String else { throw DebridError.provider("Real-Debrid refused the magnet.") }
        guard let info = try await get("/torrents/info/\(id)", key: key) as? [String: Any] else { throw DebridError.provider("Real-Debrid didn't answer.") }
        let files = (info["files"] as? [[String: Any]] ?? []).map { f in
            DebridFile(id: String(f["id"] as? Int ?? 0), name: f["path"] as? String ?? "", bytes: (f["bytes"] as? Int64) ?? Int64(f["bytes"] as? Int ?? 0))
        }
        var chosen: DebridFile?
        if let fileIdx, fileIdx + 1 <= files.count, let byIdx = files.first(where: { $0.id == String(fileIdx + 1) }) {
            chosen = byIdx
        } else {
            chosen = DebridService.pickFile(files, filename: filename, season: season, episode: episode)
        }
        guard let file = chosen else { throw DebridError.noFile }
        if (info["status"] as? String) == "waiting_files_selection" || (info["links"] as? [String] ?? []).isEmpty {
            _ = try? await post("/torrents/selectFiles/\(id)", key: key, form: ["files": file.id])
        }
        // A cached torrent turns "downloaded" almost immediately.
        var links: [String] = []
        for _ in 0..<6 {
            try Task.checkCancellation()
            if let i = try await get("/torrents/info/\(id)", key: key) as? [String: Any] {
                let status = i["status"] as? String ?? ""
                if status == "downloaded" { links = i["links"] as? [String] ?? []; break }
                if ["downloading", "queued", "magnet_conversion"].contains(status), (i["progress"] as? Double ?? 0) < 100 {
                    if status == "downloading" { break }
                }
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        guard let link = links.first else {
            _ = try? await deleteTorrent(id, key: key)
            throw DebridError.notCached(.realDebrid)
        }
        guard let un = try await post("/unrestrict/link", key: key, form: ["link": link]) as? [String: Any],
              let dl = un["download"] as? String, let url = URL(string: dl) else { throw DebridError.provider("Real-Debrid couldn't unrestrict the link.") }
        return url
    }

    static func deleteTorrent(_ id: String, key: String) async throws {
        guard let url = URL(string: base + "/torrents/delete/\(id)") else { return }
        _ = try? await HTTP.data(HTTP.request(url, method: "DELETE", headers: ["Authorization": "Bearer \(key)"], fresh: true), session: HTTP.ephemeral)
    }

    /// Cloud: finished torrents.
    static func cloud(key: String) async -> [(id: String, name: String, bytes: Int64, links: [String])] {
        guard let list = try? await get("/torrents?limit=200", key: key) as? [[String: Any]] else { return [] }
        return list.filter { ($0["status"] as? String) == "downloaded" }.map {
            ($0["id"] as? String ?? "", $0["filename"] as? String ?? "", Int64($0["bytes"] as? Int ?? 0), $0["links"] as? [String] ?? [])
        }
    }

    static func unrestrict(_ link: String, key: String) async throws -> URL {
        guard let un = try await post("/unrestrict/link", key: key, form: ["link": link]) as? [String: Any],
              let dl = un["download"] as? String, let url = URL(string: dl) else { throw DebridError.provider("Couldn't get link.") }
        return url
    }
}

// MARK: - Premiumize

enum Premiumize {
    static let base = "https://www.premiumize.me/api"

    static func get(_ path: String, key: String, params: [String: String] = [:]) async throws -> [String: Any] {
        var p = params
        p["apikey"] = key
        guard let url = URL(string: base + path + "?" + HTTP.query(p)),
              let d = try await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any] else { throw HTTPError.notJSON }
        return d
    }

    static func resolve(key: String, magnet: String, filename: String?, season: Int?, episode: Int?) async throws -> URL {
        guard let url = URL(string: base + "/transfer/directdl?apikey=\(HTTP.encodeComponent(key))") else { throw HTTPError.badURL("") }
        let body = "src=\(HTTP.encodeComponent(magnet))"
        let req = HTTP.request(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8), fresh: true)
        guard let d = try await HTTP.jsonObject(req) as? [String: Any] else { throw HTTPError.notJSON }
        guard (d["status"] as? String) == "success", let content = d["content"] as? [[String: Any]], !content.isEmpty else {
            throw DebridError.notCached(.premiumize)
        }
        let files = content.map { c in
            DebridFile(id: c["path"] as? String ?? "", name: c["path"] as? String ?? "", bytes: Int64(c["size"] as? Int ?? 0),
                       link: (c["stream_link"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c["link"] as? String)
        }
        guard let f = DebridService.pickFile(files, filename: filename, season: season, episode: episode),
              let link = f.link, let u = URL(string: link) else { throw DebridError.noFile }
        return u
    }

    static func cached(key: String, hashes: [String]) async -> Set<String> {
        var comps = URLComponents(string: base + "/cache/check")!
        comps.queryItems = [URLQueryItem(name: "apikey", value: key)] + hashes.prefix(100).map { URLQueryItem(name: "items[]", value: $0) }
        guard let url = comps.url, let d = try? await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any],
              let resp = d["response"] as? [Bool] else { return [] }
        return Set(zip(hashes, resp).filter { $0.1 }.map { $0.0 })
    }

    static func cloud(key: String) async -> [(id: String, name: String, bytes: Int64, link: String)] {
        guard let d = try? await get("/item/listall", key: key), let files = d["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { f in
            guard let link = (f["stream_link"] as? String) ?? (f["link"] as? String) else { return nil }
            return (f["id"] as? String ?? "", f["name"] as? String ?? "", Int64(f["size"] as? Int ?? 0), link)
        }
    }
}

// MARK: - TorBox

enum TorBox {
    static let base = "https://api.torbox.app/v1/api"

    static func get(_ path: String, key: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path),
              let d = try await HTTP.jsonObject(HTTP.request(url, headers: ["Authorization": "Bearer \(key)"], fresh: true)) as? [String: Any]
        else { throw HTTPError.notJSON }
        return d
    }

    static func resolve(key: String, magnet: String, hash: String, filename: String?, season: Int?, episode: Int?) async throws -> URL {
        guard let url = URL(string: base + "/torrents/createtorrent") else { throw HTTPError.badURL("") }
        let boundary = "orivio-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"magnet\"\r\n\r\n\(magnet)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"seed\"\r\n\r\n3\r\n--\(boundary)--\r\n".utf8))
        let req = HTTP.request(url, method: "POST", headers: ["Authorization": "Bearer \(key)", "Content-Type": "multipart/form-data; boundary=\(boundary)"],
                               body: body, fresh: true)
        guard let d = try await HTTP.jsonObject(req) as? [String: Any], let data = d["data"] as? [String: Any],
              let tid = data["torrent_id"] as? Int else { throw DebridError.provider("TorBox refused the magnet.") }
        var files: [DebridFile] = []
        for _ in 0..<5 {
            let info = try await get("/torrents/mylist?id=\(tid)&bypass_cache=true", key: key)
            if let t = info["data"] as? [String: Any] {
                let finished = (t["download_finished"] as? Bool) ?? false
                files = (t["files"] as? [[String: Any]] ?? []).map { f in
                    DebridFile(id: String(f["id"] as? Int ?? 0), name: f["name"] as? String ?? f["short_name"] as? String ?? "",
                               bytes: Int64(f["size"] as? Int ?? 0))
                }
                if finished, !files.isEmpty { break }
                if !finished, (t["download_state"] as? String)?.contains("download") == true { throw DebridError.notCached(.torbox) }
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        guard let f = DebridService.pickFile(files, filename: filename, season: season, episode: episode) else { throw DebridError.notCached(.torbox) }
        let dl = try await get("/torrents/requestdl?token=\(HTTP.encodeComponent(key))&torrent_id=\(tid)&file_id=\(f.id)", key: key)
        guard let link = dl["data"] as? String, let u = URL(string: link) else { throw DebridError.provider("TorBox couldn't create a link.") }
        return u
    }

    static func cached(key: String, hashes: [String]) async -> Set<String> {
        let q = hashes.prefix(100).joined(separator: ",")
        guard let d = try? await get("/torrents/checkcached?hash=\(q)&format=list", key: key), let list = d["data"] as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0["hash"] as? String)?.lowercased() })
    }

    static func cloud(key: String) async -> [(id: Int, name: String, bytes: Int64, files: [DebridFile])] {
        guard let d = try? await get("/torrents/mylist?bypass_cache=true", key: key), let list = d["data"] as? [[String: Any]] else { return [] }
        return list.filter { ($0["download_finished"] as? Bool) == true }.map { t in
            let files = (t["files"] as? [[String: Any]] ?? []).map { f in
                DebridFile(id: String(f["id"] as? Int ?? 0), name: f["name"] as? String ?? "", bytes: Int64(f["size"] as? Int ?? 0))
            }
            return (t["id"] as? Int ?? 0, t["name"] as? String ?? "", Int64(t["size"] as? Int ?? 0), files)
        }
    }

    static func link(key: String, torrentID: Int, fileID: String) async throws -> URL {
        let dl = try await get("/torrents/requestdl?token=\(HTTP.encodeComponent(key))&torrent_id=\(torrentID)&file_id=\(fileID)", key: key)
        guard let link = dl["data"] as? String, let u = URL(string: link) else { throw DebridError.provider("Couldn't get link.") }
        return u
    }
}

// MARK: - AllDebrid

enum AllDebrid {
    static let base = "https://api.alldebrid.com/v4"

    static func get(_ path: String, key: String, params: [String: String]) async throws -> [String: Any] {
        var p = params
        p["agent"] = "orivio"
        p["apikey"] = key
        guard let url = URL(string: base + path + "?" + HTTP.query(p)),
              let d = try await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any] else { throw HTTPError.notJSON }
        if (d["status"] as? String) == "error" {
            let msg = (d["error"] as? [String: Any])?["message"] as? String ?? "AllDebrid error"
            throw DebridError.provider(msg)
        }
        return d
    }

    static func resolve(key: String, magnet: String, filename: String?, season: Int?, episode: Int?) async throws -> URL {
        var comps = URLComponents(string: base + "/magnet/upload")!
        comps.queryItems = [URLQueryItem(name: "agent", value: "orivio"), URLQueryItem(name: "apikey", value: key),
                            URLQueryItem(name: "magnets[]", value: magnet)]
        guard let url = comps.url, let d = try await HTTP.jsonObject(HTTP.request(url, fresh: true)) as? [String: Any],
              let m = ((d["data"] as? [String: Any])?["magnets"] as? [[String: Any]])?.first, let id = m["id"] as? Int else {
            throw DebridError.provider("AllDebrid refused the magnet.")
        }
        let ready = m["ready"] as? Bool ?? false
        guard ready else {
            // This resolve uploaded it and it isn't cached: clean up.
            _ = try? await get("/magnet/delete", key: key, params: ["id": String(id)])
            throw DebridError.notCached(.allDebrid)
        }
        let files = try await files(key: key, magnetID: id)
        guard let f = DebridService.pickFile(files, filename: filename, season: season, episode: episode), let link = f.link else { throw DebridError.noFile }
        return try await unlock(link, key: key)
    }

    static func files(key: String, magnetID: Int) async throws -> [DebridFile] {
        let d = try await get("/magnet/files", key: key, params: ["id[]": String(magnetID)])
        let magnets = (d["data"] as? [String: Any])?["magnets"] as? [[String: Any]] ?? []
        var out: [DebridFile] = []
        func walk(_ nodes: [[String: Any]], prefix: String) {
            for n in nodes {
                let name = n["n"] as? String ?? ""
                if let children = n["e"] as? [[String: Any]] { walk(children, prefix: prefix + name + "/") } else if let l = n["l"] as? String {
                    out.append(DebridFile(id: l, name: prefix + name, bytes: Int64(n["s"] as? Int ?? 0), link: l))
                }
            }
        }
        for m in magnets { walk(m["files"] as? [[String: Any]] ?? [], prefix: "") }
        return out
    }

    static func unlock(_ link: String, key: String) async throws -> URL {
        let d = try await get("/link/unlock", key: key, params: ["link": link])
        guard let l = (d["data"] as? [String: Any])?["link"] as? String, let u = URL(string: l) else { throw DebridError.provider("AllDebrid couldn't unlock the link.") }
        return u
    }

    static func cloud(key: String) async -> [(id: Int, name: String, bytes: Int64)] {
        guard let d = try? await get("/magnet/status", key: key, params: ["status": "ready"]),
              let magnets = (d["data"] as? [String: Any])?["magnets"] as? [[String: Any]] else { return [] }
        return magnets.map { ($0["id"] as? Int ?? 0, $0["filename"] as? String ?? "", Int64($0["size"] as? Int ?? 0)) }
    }
}

// MARK: - TorrServer (P2P)

enum TorrServerService {
    static func streamURL(server: String, stream: Stream) -> URL? {
        guard let hash = stream.infoHash else { return nil }
        var base = server.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let index = (stream.fileIdx ?? 0) + 1
        let name = HTTP.encodeComponent(stream.behaviorHints?.filename ?? "video")
        let link = HTTP.encodeComponent(stream.magnetURI ?? hash)
        return URL(string: "\(base)/stream/\(name)?link=\(link)&index=\(index)&play")
    }

    static func test(server: String) async -> Bool {
        var base = server.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/echo") else { return false }
        return (try? await HTTP.data(url, fresh: true, timeout: 6)) != nil
    }
}
