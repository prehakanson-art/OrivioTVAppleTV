import SwiftUI

/// The Plex / Jellyfin tab inside Library: the server's movies and shows as
/// a poster grid. A movie plays straight from the server; a show opens its
/// episode list.
struct MediaServerPane: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mediaServers: MediaServerStore
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var progressStore: ProgressStore

    let kind: MediaServerKind
    let onPlay: (PlaybackRequest) -> Void
    let onOpenShow: (MediaServerItem) -> Void

    private enum Section: String, CaseIterable { case movies = "Movies", shows = "Shows" }
    @State private var section: Section = .movies
    @State private var movies: [MediaServerItem] = []
    @State private var shows: [MediaServerItem] = []
    /// Which server the lists belong to, so a reconnect reloads.
    @State private var loadedFor: String?
    @State private var isLoading = false
    @State private var failed = false

    private var account: MediaServerAccount? { mediaServers.account(for: kind) }
    private var loadKey: String { (account?.serverURL ?? "") + "|" + (account?.token ?? "") }
    private var items: [MediaServerItem] { section == .movies ? movies : shows }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth,
                            maximum: posterLayout.posterSize.posterWidth),
                  spacing: OrivioSpacing.lg, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            HStack(spacing: OrivioSpacing.sm) {
                ForEach(Section.allCases, id: \.self) { s in
                    Button { section = s } label: {
                        SelectableChip(title: s.rawValue, selected: section == s)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .frame(width: 220)
                }
                Spacer()
                if let name = account?.serverName, !name.isEmpty {
                    Text(name)
                        .font(FusionType.metadata(theme.font))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .focusSection()

            if isLoading && movies.isEmpty && shows.isEmpty {
                OrivioLoadingView(label: "Loading \(kind.displayName) library")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else if failed && movies.isEmpty && shows.isEmpty {
                OrivioEmptyState(icon: "exclamationmark.triangle",
                                title: "Couldn't reach \(kind.displayName)",
                                message: "Check the server is on and reachable from this Apple TV, then reconnect it in Settings → Integrations.")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else if items.isEmpty {
                OrivioEmptyState(icon: section == .movies ? "film" : "tv",
                                title: "No \(section.rawValue.lowercased()) on \(kind.displayName)",
                                message: "Nothing in this library yet.")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                    ForEach(items) { item in
                        MediaServerPosterCell(item: item,
                                              captionWidth: posterLayout.posterSize.posterWidth,
                                              showLabel: posterLayout.showPosterLabels) {
                            select(item)
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, OrivioSpacing.huge)
                .padding(.bottom, OrivioSpacing.huge)
                .focusSection()
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        guard let account else {
            movies = []; shows = []; loadedFor = nil
            isLoading = false; failed = false
            return
        }
        // The player cover re-appears this view; keep a listing that is
        // already up rather than replacing it with a spinner.
        guard loadedFor != loadKey else { return }
        isLoading = true
        failed = false
        let key = loadKey
        async let movieFetch: [MediaServerItem]? = account.kind == .plex
            ? PlexService.libraryItems(account, series: false)
            : JellyfinService.libraryItems(account, series: false)
        async let showFetch: [MediaServerItem]? = account.kind == .plex
            ? PlexService.libraryItems(account, series: true)
            : JellyfinService.libraryItems(account, series: true)
        let (m, s) = await (movieFetch, showFetch)
        guard key == loadKey, !Task.isCancelled else { return }
        // nil = the server didn't answer (or the fetch was torn down);
        // [] = it answered and the library is empty. The first cut collapsed
        // both into "failed" AND latched it — a server that was asleep for one
        // visit read "Couldn't reach" forever, and an empty library did too.
        if m == nil, s == nil {
            failed = true          // not latched: the next visit retries
            isLoading = false
            return
        }
        movies = m ?? []
        shows = s ?? []
        failed = false
        loadedFor = key
        isLoading = false
    }

    private func select(_ item: MediaServerItem) {
        if item.isSeries {
            onOpenShow(item)
            return
        }
        guard let account,
              let request = MediaServerPlayback.request(
                movie: item, account: account,
                resumePosition: progressStore.progress(for: item.id)?.positionSeconds
              ) else { return }
        onPlay(request)
    }
}

/// A poster cell for a server item: the same platter, caption and lift as
/// the Home grids, without the add-on hold menu (these ids mean nothing to
/// the add-ons).
private struct MediaServerPosterCell: View {
    let item: MediaServerItem
    let captionWidth: CGFloat
    /// Settings → Layout → Posters → "Poster labels" — the pane says "across
    /// the app", and these are poster cards like any other.
    let showLabel: Bool
    let onSelect: () -> Void
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                PosterCard(item: item.metaItem)
                    .onFocusChange { focused = $0 }
            }
            .mediaCardButtonStyle()
            if showLabel {
                ATVCardCaption(title: item.title, subtitle: item.year.map(String.init),
                               width: captionWidth, lowered: focused)
            }
        }
    }
}

// MARK: - Show page

/// A server show's seasons and episodes. Playing an episode carries the whole
/// list into the player, so Up Next and the in-player episode list work.
struct MediaServerShowView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mediaServers: MediaServerStore
    @EnvironmentObject private var progressStore: ProgressStore

    let show: MediaServerItem
    let onPlay: (PlaybackRequest) -> Void

    @State private var episodes: [MediaServerItem] = []
    @State private var season: Int?
    @State private var isLoading = true
    @FocusState private var focusedEpisode: String?

    private var seasons: [Int] {
        Array(Set(episodes.compactMap(\.season))).sorted()
    }
    private var visible: [MediaServerItem] {
        guard let season else { return episodes }
        return episodes.filter { $0.season == season }
    }

    var body: some View {
        DetailScaffold(title: show.title,
                       subtitle: "\(show.kind.displayName) · \(episodes.count) episode\(episodes.count == 1 ? "" : "s")") {
            if isLoading {
                OrivioLoadingView(label: "Loading episodes", holdsFocus: true)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if episodes.isEmpty {
                OrivioEmptyState(icon: "tv", title: "No episodes",
                                message: "The server has no episodes for this show.", holdsFocus: true)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                    if let overview = show.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 22))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(3)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                    if seasons.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: OrivioSpacing.sm) {
                                ForEach(seasons, id: \.self) { s in
                                    Button { season = s } label: {
                                        SelectableChip(title: "Season \(s)", selected: season == s)
                                    }
                                    .buttonStyle(PlainCardButtonStyle())
                                    .frame(width: 220)
                                }
                            }
                        }
                        .scrollClipDisabled()
                        .focusSection()
                    }
                    LazyVStack(spacing: OrivioSpacing.sm) {
                        ForEach(visible) { episode in
                            Button { play(episode) } label: {
                                MediaServerEpisodeRow(
                                    episode: episode,
                                    progress: progressStore.progress(for: episode.id).map {
                                        $0.durationSeconds > 0 ? $0.positionSeconds / $0.durationSeconds : 0
                                    }
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focusedEpisode, equals: episode.id)
                        }
                    }
                    .focusSection()
                }
            }
        }
        .task {
            guard let account = mediaServers.account(for: show.kind) else { isLoading = false; return }
            let list = await MediaServerPlayback.episodes(account, showID: show.serverItemID)
            episodes = list
            if season == nil { season = seasons.first }
            isLoading = false
        }
    }

    private func play(_ episode: MediaServerItem) {
        guard let account = mediaServers.account(for: show.kind),
              let request = MediaServerPlayback.request(
                episode: episode, show: show, episodes: episodes, account: account,
                resumePosition: progressStore.progress(for: episode.id)?.positionSeconds
              ) else { return }
        onPlay(request)
    }
}

private struct MediaServerEpisodeRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let episode: MediaServerItem
    let progress: Double?

    private var code: String {
        var parts: [String] = []
        if let s = episode.season { parts.append("S\(s)") }
        if let e = episode.episode { parts.append("E\(e)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: OrivioSpacing.lg) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: episode.poster, contentMode: .fill, maxDimension: 240)
                    .frame(width: 240, height: 135)
                    .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.sm, style: .continuous))
                if let progress, progress > 0.02 {
                    Rectangle().fill(theme.palette.secondary)
                        .frame(width: 240 * min(max(progress, 0), 1), height: 5)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: OrivioSpacing.sm) {
                    if !code.isEmpty {
                        Text(code)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(theme.palette.secondary)
                    }
                    Text(episode.title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let duration = episode.durationSeconds, duration > 0 {
                        Text("\(Int(duration / 60)) min")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(isFocused ? 4 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(OrivioSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
    }
}
