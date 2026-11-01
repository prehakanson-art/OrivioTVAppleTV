import SwiftUI

/// Library → Debrid Cloud: files already in the user's Real-Debrid /
/// Premiumize / TorBox / AllDebrid cloud. Folders open their files; a file
/// shows "Getting link…" and plays.
struct CloudLibraryView: View {
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var presenter: PlayerPresenter
    @State private var entries: [CloudEntry] = []
    @State private var loading = true
    @State private var filter: Filter = .all
    @State private var folder: CloudEntry?
    @State private var folderFiles: [CloudEntry] = []
    @State private var status: String?

    enum Filter: String, CaseIterable { case all = "All", movies = "Movies", shows = "Shows" }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(folder?.name ?? "Debrid Cloud").textStyle(.pageTitle).lineLimit(1)
                    Text(subtitle).textStyle(.meta)
                }
                Spacer()
                if folder == nil {
                    HStack(spacing: 14) {
                        ForEach(Filter.allCases, id: \.self) { f in
                            Button(f.rawValue) { filter = f }.buttonStyle(GlassCapsuleStyle(selected: filter == f))
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 120)
            if loading {
                OrivioLoadingView(label: "Reading your cloud…").frame(maxWidth: .infinity).frame(height: 400)
            } else if shown.isEmpty {
                OrivioEmptyState(icon: "icloud", title: "Nothing here",
                                 message: folder == nil ? "Files you add to your debrid service appear here." : "This folder has no playable files.")
                    .frame(maxWidth: .infinity).frame(height: 400)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { e in
                            Button { open(e) } label: { row(e) }
                                .buttonStyle(FocusCapsuleRowStyle(cornerRadius: 20, horizontalPadding: 26, height: 84))
                        }
                    }
                    .padding(.horizontal, Metrics.margin)
                    .padding(.bottom, 100)
                }
                .scrollClipDisabled()
            }
        }
        .pageFrame()
        .overlay {
            if let status {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5)
                        Text(status).font(.system(size: 30, weight: .semibold))
                    }
                    FocusAnchor()
                }
            }
        }
        .onExitCommand(perform: folder != nil ? { folder = nil } : nil)
        .task { await load() }
    }

    private var subtitle: String {
        let list = shown
        let total = list.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(list.count) item\(list.count == 1 ? "" : "s")" + (total > 0 ? " · \(StreamEntry.formatBytes(total))" : "")
    }

    private var shown: [CloudEntry] {
        if folder != nil { return folderFiles }
        switch filter {
        case .all: return entries
        case .movies: return entries.filter { !$0.looksLikeShow }
        case .shows: return entries.filter(\.looksLikeShow)
        }
    }

    private func row(_ e: CloudEntry) -> some View {
        HStack(spacing: 18) {
            Image(systemName: e.isFolder ? "folder.fill" : "film")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.name).font(.system(size: 25, weight: .semibold)).lineLimit(1)
                Text([e.provider.label, e.bytes > 0 ? StreamEntry.formatBytes(e.bytes) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 19)).opacity(0.6)
            }
            Spacer()
            if e.isFolder { Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.5) }
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        var all: [CloudEntry] = []
        await withTaskGroup(of: [CloudEntry].self) { group in
            for p in debrid.value.configured {
                guard let key = debrid.value.key(p) else { continue }
                group.addTask { await CloudEntry.list(provider: p, key: key) }
            }
            for await list in group { all += list }
        }
        entries = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func open(_ e: CloudEntry) {
        guard let key = debrid.value.key(e.provider) else { return }
        if e.isFolder {
            status = "Opening…"
            Task {
                let files = await e.files(key: key).filter(\.isVideo)
                status = nil
                if files.count == 1 { play(files[0], key: key) } else {
                    folderFiles = files
                    folder = e
                }
            }
        } else {
            play(e, key: key)
        }
    }

    private func play(_ e: CloudEntry, key: String) {
        status = "Getting link…"
        Task {
            do {
                let url = try await e.resolve(key: key)
                status = nil
                let meta = MetaItem(id: "cloud:\(e.provider.short):\(e.id)", type: e.looksLikeShow ? "series" : "movie", name: e.displayTitle)
                var hints = StreamBehaviorHints()
                hints.filename = e.name
                let entry = StreamEntry(stream: Stream(name: e.provider.label, title: e.name, url: url.absoluteString, behaviorHints: hints),
                                        addonName: e.provider.label, addonID: "cloud", index: 0)
                presenter.present(PlaybackRequest(meta: meta, video: nil, entry: entry, allEntries: [entry], url: url))
            } catch {
                status = nil
                ToastCenter.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// One cloud item: a folder (torrent/magnet with several files) or a playable file.
struct CloudEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case rdTorrent(links: [String])
        case rdLink(String)
        case pmFile(link: String)
        case tbTorrent(id: Int, files: [DebridFile])
        case tbFile(torrentID: Int, fileID: String)
        case adMagnet(id: Int)
        case adFile(link: String)
    }

    let id: String
    let provider: DebridProvider
    let name: String
    let bytes: Int64
    let kind: Kind

    var isFolder: Bool {
        switch kind {
        case .rdTorrent(let links): return links.count != 1
        case .tbTorrent(_, let files): return files.count != 1
        case .adMagnet: return true
        default: return false
        }
    }

    var isVideo: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty || ["mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "webm", "wmv", "mpg"].contains(ext)
    }

    var looksLikeShow: Bool {
        name.range(of: #"(?i)\bS\d{1,2}[ ._-]?E\d{1,3}\b|\bS\d{1,2}\b|season"#, options: .regularExpression) != nil
    }

    /// "Movie.Name.2021.2160p.WEB-DL.mkv" → "Movie Name 2021".
    var displayTitle: String {
        var s = (name as NSString).deletingPathExtension.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        if let r = s.range(of: #"(?i)\b(19|20)\d{2}\b"#, options: .regularExpression) { s = String(s[..<r.upperBound]) }
        else if let r = s.range(of: #"(?i)\b(2160p|1080p|720p|480p|WEB|BluRay|HDTV)\b"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func list(provider p: DebridProvider, key: String) async -> [CloudEntry] {
        switch p {
        case .realDebrid:
            return await RealDebrid.cloud(key: key).map {
                CloudEntry(id: $0.id, provider: p, name: $0.name, bytes: $0.bytes, kind: .rdTorrent(links: $0.links))
            }
        case .premiumize:
            return await Premiumize.cloud(key: key).map {
                CloudEntry(id: $0.id, provider: p, name: $0.name, bytes: $0.bytes, kind: .pmFile(link: $0.link))
            }
        case .torbox:
            return await TorBox.cloud(key: key).map {
                CloudEntry(id: String($0.id), provider: p, name: $0.name, bytes: $0.bytes, kind: .tbTorrent(id: $0.id, files: $0.files))
            }
        case .allDebrid:
            return await AllDebrid.cloud(key: key).map {
                CloudEntry(id: String($0.id), provider: p, name: $0.name, bytes: $0.bytes, kind: .adMagnet(id: $0.id))
            }
        }
    }

    func files(key: String) async -> [CloudEntry] {
        switch kind {
        case .rdTorrent(let links):
            // Pair the torrent's selected files with its links (same order).
            let info = try? await RealDebrid.get("/torrents/info/\(id)", key: key) as? [String: Any]
            let selected = (info?["files"] as? [[String: Any]] ?? []).filter { ($0["selected"] as? Int) == 1 }
            return links.enumerated().map { i, l in
                let f = selected.indices.contains(i) ? selected[i] : nil
                let path = f?["path"] as? String ?? "Part \(i + 1)"
                return CloudEntry(id: "\(id)#\(i)", provider: provider, name: (path as NSString).lastPathComponent,
                                  bytes: Int64(f?["bytes"] as? Int ?? 0), kind: .rdLink(l))
            }
        case .tbTorrent(let tid, let files):
            return files.map { CloudEntry(id: "\(tid)#\($0.id)", provider: provider, name: ($0.name as NSString).lastPathComponent,
                                          bytes: $0.bytes, kind: .tbFile(torrentID: tid, fileID: $0.id)) }
        case .adMagnet(let mid):
            let files = (try? await AllDebrid.files(key: key, magnetID: mid)) ?? []
            return files.map { CloudEntry(id: $0.id, provider: provider, name: ($0.name as NSString).lastPathComponent,
                                          bytes: $0.bytes, kind: .adFile(link: $0.link ?? $0.id)) }
        default:
            return [self]
        }
    }

    func resolve(key: String) async throws -> URL {
        switch kind {
        case .rdTorrent(let links):
            guard let l = links.first else { throw DebridError.provider("No files in this torrent.") }
            return try await RealDebrid.unrestrict(l, key: key)
        case .rdLink(let l): return try await RealDebrid.unrestrict(l, key: key)
        case .pmFile(let link):
            guard let u = URL(string: link) else { throw DebridError.provider("Bad link.") }
            return u
        case .tbTorrent(let tid, let files):
            guard let f = files.first else { throw DebridError.provider("No files in this torrent.") }
            return try await TorBox.link(key: key, torrentID: tid, fileID: f.id)
        case .tbFile(let tid, let fid): return try await TorBox.link(key: key, torrentID: tid, fileID: fid)
        case .adMagnet: throw DebridError.provider("Open the folder to pick a file.")
        case .adFile(let link): return try await AllDebrid.unlock(link, key: key)
        }
    }
}
