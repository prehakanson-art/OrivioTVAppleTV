import SwiftUI

/// §16.8 Library: an in-page list on the left (Recently Added, Movies, TV
/// Shows, Continue Watching, Sources, Genres) and a 6-column grid on the right.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var section: Section = .recent
    @State private var sort: Sort = .added
    @State private var showSort = false
    @FocusState private var listFocus: Section?
    @ObservedObject private var servers = MediaServerStore.shared
    @State private var serverLibraries: [(MediaServerKind, MediaServerLibrary)] = []
    @Environment(\.currentTab) private var tab

    enum Section: Hashable {
        case recent, movies, shows, continueWatching, cloud, genre(String)
        case server(MediaServerKind, MediaServerLibrary)

        /// Rows that open their own page instead of filling the grid.
        var pushes: Bool {
            switch self {
            case .cloud, .server: return true
            default: return false
            }
        }

        var title: String {
            switch self {
            case .recent: return "Recently Added"
            case .movies: return "Movies"
            case .shows: return "TV Shows"
            case .continueWatching: return "Continue Watching"
            case .cloud: return "Debrid Cloud"
            case .genre(let g): return g
            case .server(let k, let l): return "\(l.title) · \(k.displayName)"
            }
        }

        var icon: String {
            switch self {
            case .recent: return "clock"
            case .movies: return "film"
            case .shows: return "tv"
            case .continueWatching: return "play.circle"
            case .cloud: return "icloud"
            case .genre: return "theatermasks"
            case .server(let k, _): return k.icon
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case added = "Added", name = "Name", watched = "Recently Watched"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            list.frame(width: 330)
            grid.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.leading, Metrics.margin)
        .padding(.top, 120)
        .pageFrame()
        .sheet(isPresented: $showSort) {
            OptionPickerSheet(title: "Sort", options: Sort.allCases.map { ($0.rawValue, $0.rawValue) }, selected: sort.rawValue) { v in
                sort = Sort(rawValue: v) ?? .added
                showSort = false
            }
        }
        .onChange(of: listFocus) { _, f in if let f, !f.pushes { section = f } }
        .onChange(of: section) { _, _ in registerMenu() }
        .onAppear { registerMenu() }
        .onDisappear { PageMenuRouter.shared.unregister(tab) }
        .task(id: servers.connected) { await loadServerLibraries() }
    }

    /// Tell the shell this page owns a left column, so a failed Left in the
    /// grid lands on it instead of opening the app sidebar. Re-registered when
    /// the section changes so the landing always targets the current row.
    private func registerMenu() {
        let target = section
        PageMenuRouter.shared.register(tab,
                                       isMenuFocused: { listFocus != nil },
                                       focusMenu: {
            listFocus = target
            // A request to a view that was disabled for a beat can be refused;
            // retry only if the engine cleared it (a refused request keeps it).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if listFocus == nil { listFocus = target }
            }
        })
    }

    private func loadServerLibraries() async {
        var out: [(MediaServerKind, MediaServerLibrary)] = []
        for kind in servers.connected {
            guard let a = servers.account(kind) else { continue }
            out += (await MediaServerAPI.libraries(a) ?? []).map { (kind, $0) }
        }
        serverLibraries = out
    }

    // MARK: List

    private var genres: [String] {
        var counts: [String: Int] = [:]
        for item in library.items { for g in item.meta.genres { counts[g, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map(\.key).sorted()
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([Section.recent, .movies, .shows, .continueWatching], id: \.self) { listRow($0) }
                if debrid.value.hasAny || !serverLibraries.isEmpty {
                    Text("Sources").textStyle(.eyebrow).padding(.leading, 22).padding(.top, 24)
                    if debrid.value.hasAny { listRow(.cloud) }
                    ForEach(serverLibraries, id: \.1.id) { kind, lib in listRow(.server(kind, lib)) }
                }
                if !genres.isEmpty {
                    Text("Genres").textStyle(.eyebrow).padding(.leading, 22).padding(.top, 24)
                    ForEach(genres, id: \.self) { listRow(.genre($0)) }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .focusSection()
    }

    private func listRow(_ s: Section) -> some View {
        Button {
            switch s {
            case .cloud: router.push(.cloudLibrary)
            case .server(let k, let l): router.push(.mediaServerLibrary(serverID: k.rawValue, libraryID: l.id, title: l.title))
            default: break
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: s.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.14)))
                Text(s.title).font(.system(size: 26, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(FocusCapsuleRowStyle(selected: section == s, height: 62))
        .focused($listFocus, equals: s)
    }

    // MARK: Grid

    private var items: [MetaItem] {
        switch section {
        case .continueWatching:
            let byMeta = Dictionary(grouping: progress.entries.values.filter { !$0.isFinished }, by: \.metaID)
                .compactMapValues { $0.max { $0.updatedAt < $1.updatedAt } }
            return byMeta.values.sorted { $0.updatedAt > $1.updatedAt }.map { p in
                library.items.first { $0.meta.id == p.metaID }?.meta
                    ?? MetaItem(id: p.metaID, type: p.type, name: p.name, poster: p.poster, background: p.background, logo: p.logo)
            }
        default:
            var list = library.items
            switch section {
            case .movies: list = list.filter { $0.meta.type == "movie" }
            case .shows: list = list.filter { $0.meta.isSeries }
            case .genre(let g): list = list.filter { $0.meta.genres.contains(g) }
            default: break
            }
            switch sort {
            case .added: list.sort { $0.addedAt > $1.addedAt }
            case .name: list.sort { $0.meta.name.localizedCaseInsensitiveCompare($1.meta.name) == .orderedAscending }
            case .watched:
                let last = lastWatched
                list.sort { (last[$0.meta.id] ?? .distantPast) > (last[$1.meta.id] ?? .distantPast) }
            }
            return list.map(\.meta)
        }
    }

    private var lastWatched: [String: Date] {
        var d: [String: Date] = [:]
        for p in progress.entries.values { d[p.metaID] = max(d[p.metaID] ?? .distantPast, p.updatedAt) }
        return d
    }

    private var countLine: String {
        let m = library.items.filter { $0.meta.type == "movie" }.count
        let s = library.items.filter { $0.meta.isSeries }.count
        return "\(m) movie\(m == 1 ? "" : "s") · \(s) show\(s == 1 ? "" : "s")"
    }

    private var grid: some View {
        let list = items
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).textStyle(.pageTitle)
                        Text(countLine).textStyle(.meta)
                    }
                    Spacer()
                    if section != .continueWatching {
                        Button { showSort = true } label: { Label("Sort: \(sort.rawValue)", systemImage: "chevron.down").labelStyle(TrailingIcon()) }
                            .buttonStyle(GlassCapsuleStyle())
                    }
                }
                .padding(.trailing, Metrics.margin)
                if list.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(190), spacing: 40), count: 6), alignment: .leading, spacing: 56) {
                        ForEach(list) { meta in
                            let actions = PlayActions(router: router)
                            Button { actions.openDetail(meta, siblings: list) } label: {
                                PosterCard(meta: meta, width: 190, progress: section == .continueWatching ? progressFraction(meta) : nil)
                            }
                            .buttonStyle(FlatCardStyle())
                            .onPlayPauseCommand { actions.playManually(meta) }
                            .posterHoldMenu(meta) { actions.openDetail(meta, siblings: list) }
                        }
                    }
                    .padding(.bottom, 100)
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func progressFraction(_ meta: MetaItem) -> Double? {
        progress.entries.values.filter { $0.metaID == meta.id }.max { $0.updatedAt < $1.updatedAt }?.fraction
    }

    private var empty: some View {
        let message = section == .continueWatching
            ? "Titles you start watching appear here."
            : "Save titles with the + button on their page and they'll live here."
        return VStack(spacing: 16) {
            Image(systemName: section == .continueWatching ? "play.circle" : "plus.circle").font(.system(size: 54)).opacity(0.7)
            Text(section == .continueWatching ? "Nothing in progress" : "Your library is empty").font(.system(size: 32, weight: .bold))
            Text(message).textStyle(.body, color: Palette.textSecondary).multilineTextAlignment(.center)
        }
        .padding(50)
        .frame(width: 900)
        .glassCard()
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.trailing, Metrics.margin)
    }
}
