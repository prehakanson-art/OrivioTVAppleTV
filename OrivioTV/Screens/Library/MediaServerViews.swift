import SwiftUI

/// One Plex / Jellyfin library: title + sort capsule, the 6-column grid.
/// Movies play straight from the server; shows open `MediaServerShowView`.
struct MediaServerLibraryView: View {
    let serverID: String
    let libraryID: String
    let title: String

    @ObservedObject private var servers = MediaServerStore.shared
    @State private var items: [MediaServerItem] = []
    @State private var loading = true
    @State private var failed = false
    @State private var sort: Sort = .name
    @State private var picking = false
    @State private var shown = 120

    enum Sort: String, CaseIterable { case name = "Name", added = "Recently Added", year = "Year" }

    private var kind: MediaServerKind? { MediaServerKind(rawValue: serverID) }
    private var account: MediaServerAccount? { kind.flatMap { servers.account($0) } }

    private var sorted: [MediaServerItem] {
        switch sort {
        case .name: return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .added: return items.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        case .year: return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    var body: some View {
        let metas = Array(sorted.prefix(shown)).map(\.metaItem)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                BrowseHeader(title: title, subtitle: subtitle) {
                    FilterCapsule(label: sort.rawValue) { picking = true }
                }
                // Grow the grid in pages: a big library is thousands of posters.
                PosterGrid(items: metas) { if shown < items.count { shown += 120 } }
                if failed {
                    OrivioEmptyState(icon: "exclamationmark.triangle", title: "Couldn't reach \(account?.serverName ?? kind?.displayName ?? "the server")",
                                     message: "Check that the server is on and reachable from this Apple TV.", actionTitle: "Try Again") {
                        Task { await load() }
                    }
                    .frame(height: 400)
                } else {
                    GridFooter(loading: loading, isEmpty: items.isEmpty && !loading, emptyIcon: kind?.icon ?? "server.rack",
                               emptyMessage: "This library is empty.")
                }
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: sorted.first?.backdrop).railBleed().ignoresSafeArea())
        .task { if items.isEmpty { await load() } }
        .sheet(isPresented: $picking) {
            OptionPickerSheet(title: "Sort", options: Sort.allCases.map { ($0.rawValue, $0.rawValue) }, selected: sort.rawValue) { v in
                picking = false
                sort = Sort(rawValue: v) ?? .name
                shown = 120
            }
        }
    }

    private var subtitle: String? {
        guard !items.isEmpty else { return account?.serverName }
        return [account?.serverName, "\(items.count) title\(items.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        guard let account else { failed = true; loading = false; return }
        loading = true
        failed = false
        let result = await MediaServerAPI.items(account, library: libraryID)
        loading = false
        if let result { items = result } else { failed = true }
    }
}

/// A server show: backdrop + title + overview, a season tab strip, and the
/// season's episodes as cards. Select plays the episode; the rest ride along for Up Next.
struct MediaServerShowView: View {
    let serverID: String
    let itemID: String
    let title: String

    @ObservedObject private var servers = MediaServerStore.shared
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var home: HomeSettingsStore
    @State private var show: MediaServerItem?
    @State private var episodes: [MediaServerItem] = []
    @State private var season: Int?
    @State private var loading = true
    @FocusState private var focused: String?

    private var account: MediaServerAccount? { MediaServerKind(rawValue: serverID).flatMap { servers.account($0) } }
    private var seasons: [Int] { Array(Set(episodes.compactMap(\.season))).sorted { ($0 == 0 ? 999 : $0) < ($1 == 0 ? 999 : $1) } }
    private var current: Int? { season ?? seasons.first }
    private var seasonEpisodes: [MediaServerItem] { episodes.filter { $0.season == current } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 34) {
                header
                if !seasons.isEmpty { seasonStrip }
                if !seasonEpisodes.isEmpty { episodeRow }
                if loading {
                    OrivioLoadingView(label: "Loading episodes…", holdsFocus: episodes.isEmpty).frame(height: 260)
                } else if episodes.isEmpty {
                    OrivioEmptyState(icon: "tv", title: "No episodes", message: "The server didn't return any episodes for this show.").frame(height: 300)
                }
                Spacer().frame(height: 80)
            }
        }
        .scrollClipDisabled()
        .background {
            ZStack {
                ArtField(imageURL: show?.backdrop)
                RemoteImage(url: show?.backdrop, maxPixel: ImageSize.backdrop, placeholder: false)
                    .frame(maxWidth: .infinity).frame(height: 1080)
                    .overlay(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2)], startPoint: .leading, endPoint: .trailing))
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom))
                    .clipped()
            }
            .railBleed()
            .ignoresSafeArea()
        }
        .task { if show == nil { await load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(show?.title ?? title).textStyle(.heroLogoFallback).lineLimit(2)
            MetaLineText(parts: [show?.year.map(String.init), seasons.isEmpty ? nil : "\(seasons.filter { $0 > 0 }.count) Season\(seasons.filter { $0 > 0 }.count == 1 ? "" : "s")",
                                 account?.serverName ?? MediaServerKind(rawValue: serverID)?.displayName])
            if let o = show?.overview, !o.isEmpty {
                Text(o).textStyle(.body, color: Palette.textSecondary).lineLimit(3).frame(maxWidth: 1000, alignment: .leading)
            }
            if let next = nextUp {
                Button {
                    play(next)
                } label: {
                    Label(progressFor(next) != nil ? "Resume \(next.metaVideo.seasonEpisodeCode)" : "Play \(next.metaVideo.seasonEpisodeCode)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryCapsuleStyle(minWidth: 320))
                .focused($focused, equals: "play")
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 340)
    }

    private var seasonStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { s in
                    Button(s == 0 ? "Specials" : "Season \(s)") { season = s }
                        .buttonStyle(TextTabStyle(selected: s == current))
                        .focused($focused, equals: "season-\(s)")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, Metrics.margin - 22)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private var episodeRow: some View {
        FocusRow(rowKey: "server-episodes-\(itemID)-\(current ?? 0)", title: nil, items: seasonEpisodes, spacing: 40) { ep, _ in
            Button { play(ep) } label: {
                EpisodeCard(video: ep.metaVideo, showBackdrop: show?.backdrop, progress: progressFor(ep)?.fraction,
                            watched: isWatched(ep), spoiler: home.value.hideSpoilers && !isWatched(ep) && progressFor(ep) == nil)
            }
            .buttonStyle(FlatCardStyle())
            .contextMenu {
                Button("Play from Beginning") { play(ep, fromStart: true) }
                Button(isWatched(ep) ? "Mark as Unwatched" : "Mark as Watched") {
                    guard let meta = showMeta else { return }
                    if isWatched(ep) { watched.markUnwatched(meta: meta, video: ep.metaVideo) } else { watched.markWatched(meta: meta, video: ep.metaVideo) }
                }
            }
        }
    }

    // MARK: State

    private var showMeta: MetaItem? {
        guard var m = show?.metaItem else { return nil }
        m.videos = episodes.map(\.metaVideo)
        return m
    }

    private func progressFor(_ ep: MediaServerItem) -> WatchProgress? {
        guard let meta = showMeta, let p = progress.progress(meta: meta, video: ep.metaVideo), p.isResumable else { return nil }
        return p
    }

    private func isWatched(_ ep: MediaServerItem) -> Bool {
        guard let meta = showMeta else { return false }
        return watched.isWatched(meta: meta, video: ep.metaVideo)
    }

    /// The episode in progress, else the first unwatched one.
    private var nextUp: MediaServerItem? {
        episodes.first { progressFor($0) != nil } ?? episodes.first { ($0.season ?? 0) > 0 && !isWatched($0) } ?? episodes.first
    }

    private func play(_ ep: MediaServerItem, fromStart: Bool = false) {
        guard let account, let show else { return }
        MediaServerPlayback.play(episode: ep, show: show, episodes: episodes, account: account, fromStart: fromStart)
    }

    private func load() async {
        guard let account else { loading = false; return }
        async let s = MediaServerAPI.item(account, id: itemID)
        async let e = MediaServerAPI.episodes(account, showID: itemID)
        show = await s
        episodes = await e
        loading = false
        if let n = nextUp { season = n.season }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = "play" }
    }
}

/// "2019 · 3 Seasons · Plex" from optional parts.
private struct MetaLineText: View {
    let parts: [String?]
    var body: some View {
        Text(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).textStyle(.meta)
    }
}
