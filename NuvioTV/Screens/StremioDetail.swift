import SwiftUI

// Stremio's MetaDetails, reconstructed from the IPA's
// tvOS/Board/MetaDetails: a full BackgroundImage (blurred, darkened backdrop),
// a MetaPreview on the left (title logo / title, metadata line, IMDb,
// description), an ActionStack (a primary purple Streams/Resume pill followed
// by circular icon actions), and a MetaCatalog below (episodes for series,
// "More like this"). Replaces the shared DetailView while Stremio is active.

struct StremioDetailView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var ratings: RatingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var viewModel: DetailViewModel

    let onPlay: (MetaItem, MetaVideo?) -> Void
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    let onPlayFromBeginning: (MetaItem, MetaVideo?) -> Void
    var onSelectItem: (MetaItem) -> Void = { _ in }

    @State private var activeTrailer: TMDBService.Trailer?

    init(
        item: MetaItem,
        onPlay: @escaping (MetaItem, MetaVideo?) -> Void,
        onPlayManually: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onPlayFromBeginning: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onSelectItem: @escaping (MetaItem) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: DetailViewModel(item: item))
        self.onPlay = onPlay
        self.onPlayManually = onPlayManually
        self.onPlayFromBeginning = onPlayFromBeginning
        self.onSelectItem = onSelectItem
    }

    private var autoLinkOn: Bool { profiles.activeAutoLink.enabled }
    private var meta: MetaItem { viewModel.meta }

    var body: some View {
        ZStack {
            StremioSurfaces.background.ignoresSafeArea()
            backdrop

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    preview
                    actionStack
                        .focusSection()
                        .padding(.top, 30)
                    if meta.isSeries {
                        episodesSection.padding(.top, 44)
                    }
                    moreLikeThis.padding(.top, 44)
                }
                .padding(.leading, 80)
                .padding(.trailing, 70)
                .padding(.bottom, 90)
            }
            .scrollClipDisabled()
        }
        .task {
            await viewModel.load(
                addonManager: addonManager, mdbSettings: mdblist.settings,
                tmdb: tmdbSettings.settings,
                parentalGuideEnabled: playerSettings.settings.parentalGuideEnabled
            )
        }
        .fullScreenCover(item: $activeTrailer) { trailer in
            TrailerPlayerView(trailer: trailer).environmentObject(theme)
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        GeometryReader { geo in
            ZStack {
                RemoteImage(url: meta.background ?? meta.poster)
                    .frame(width: geo.size.width, height: geo.size.height)
                // Stremio darkens the backdrop heavily so the navy stage and
                // text dominate — a left-to-right + bottom scrim.
                LinearGradient(
                    stops: [
                        .init(color: StremioSurfaces.background.opacity(0.97), location: 0),
                        .init(color: StremioSurfaces.background.opacity(0.86), location: 0.38),
                        .init(color: StremioSurfaces.background.opacity(0.55), location: 0.72),
                        .init(color: StremioSurfaces.background.opacity(0.4), location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: StremioSurfaces.background, location: 0),
                        .init(color: StremioSurfaces.background.opacity(0.2), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .bottom, endPoint: .top
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Meta preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 150)

            if let logo = meta.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                    .frame(width: 460, height: 170, alignment: .bottomLeading)
            } else {
                Text(meta.name)
                    .font(StremioFont.bold(56))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            metaLine.padding(.top, 22)

            if let description = meta.description, !description.isEmpty {
                Text(description)
                    .font(StremioFont.regular(24))
                    .lineSpacing(8)
                    .foregroundStyle(StremioSurfaces.textPrimary.opacity(0.92))
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 20)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 0) {
            ForEach(Array(metaValues.enumerated()), id: \.offset) { idx, value in
                if idx > 0 {
                    Circle().fill(StremioSurfaces.textTertiary).frame(width: 5, height: 5)
                        .padding(.horizontal, 14)
                }
                Text(value)
                    .font(StremioFont.medium(22))
                    .foregroundStyle(StremioSurfaces.textSecondary)
            }
            if let rating = meta.imdbRating {
                Circle().fill(StremioSurfaces.textTertiary).frame(width: 5, height: 5)
                    .padding(.horizontal, 14)
                HStack(spacing: 7) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(StremioSurfaces.yellow)
                    Text(rating)
                        .font(StremioFont.medium(22))
                        .foregroundStyle(StremioSurfaces.textSecondary)
                }
            }
        }
        .lineLimit(1)
    }

    private var metaValues: [String] {
        var values: [String] = []
        if let year = Self.firstYear(in: viewModel.releaseDate ?? meta.releaseInfo ?? "") {
            values.append(year)
        } else if let info = meta.releaseInfo {
            values.append(info)
        }
        if let contentRating = viewModel.contentRating {
            values.append(contentRating)
        }
        if meta.isSeries {
            let count = meta.regularSeasons.count
            if count > 0 { values.append(count == 1 ? "1 season" : "\(count) seasons") }
        } else if let runtime = meta.runtimeFormatted {
            values.append(runtime)
        }
        if let genre = meta.genres?.first { values.append(genre) }
        return values
    }

    private static func firstYear(in text: String) -> String? {
        let digits = Array(text)
        guard digits.count >= 4 else { return nil }
        for i in 0...(digits.count - 4) {
            let slice = String(digits[i..<i + 4])
            if slice.allSatisfy(\.isNumber), let y = Int(slice), (1900...2100).contains(y) { return slice }
        }
        return nil
    }

    // MARK: Action stack

    private var actionStack: some View {
        HStack(spacing: 20) {
            // Primary purple Streams / Resume / Play pill.
            StremioPrimaryAction(title: primaryTitle, icon: "play.fill") {
                if meta.isSeries, let target = seriesPlayTarget {
                    onPlay(meta, target)
                } else {
                    onPlay(meta, nil)
                }
            }
            .stremioHoldMenu(enabled: autoLinkOn) {
                if meta.isSeries, let target = seriesPlayTarget { onPlayManually(meta, target) }
                else { onPlayManually(meta, nil) }
            }

            // Circular icon actions.
            StremioCircleAction(
                icon: library.contains(meta) ? "checkmark" : "plus",
                active: library.contains(meta)
            ) {
                let saved = library.contains(meta)
                library.toggle(meta)
                ToastCenter.shared.show(saved ? "Removed from Library" : "Add to Library",
                                        icon: saved ? "bookmark.slash" : "checkmark")
            }

            // Mark as Watched (Stremio's ActionStack action, not a "like").
            StremioCircleAction(
                icon: isWatchedNow ? "checkmark.circle.fill" : "checkmark.circle",
                active: isWatchedNow
            ) { toggleWatched() }

            // Watch Trailer.
            if layout.detailPageTrailerButtonEnabled, let trailer = viewModel.trailers.first {
                StremioCircleAction(icon: "film", active: false) { activeTrailer = trailer }
            }

            // Share — tvOS has no share sheet, so this surfaces the title.
            StremioCircleAction(icon: "square.and.arrow.up", active: false) {
                ToastCenter.shared.show("Shared “\(meta.name)”", icon: "square.and.arrow.up")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isWatchedNow: Bool {
        if meta.isSeries {
            let all = meta.seasons.flatMap { meta.episodes(season: $0) }
            return !all.isEmpty && all.allSatisfy {
                watched.isWatched(contentID: meta.id, season: $0.season ?? 0, episode: $0.episode)
            }
        }
        return watched.isWatched(meta)
    }

    private func toggleWatched() {
        if meta.isSeries {
            let all = meta.seasons.flatMap { meta.episodes(season: $0) }
            let markWatched = !isWatchedNow
            for ep in all {
                let on = watched.isWatched(contentID: meta.id, season: ep.season ?? 0, episode: ep.episode)
                if markWatched && !on { watched.mark(meta: meta, video: ep) }
                else if !markWatched && on { watched.remove(contentID: meta.id, season: ep.season, episode: ep.episode) }
            }
            ToastCenter.shared.show(markWatched ? "Marked as Watched" : "Marked as Unwatched", icon: "checkmark.circle.fill")
        } else {
            let was = watched.isWatched(meta)
            watched.toggleMovie(meta)
            ToastCenter.shared.show(was ? "Marked as Unwatched" : "Marked as Watched", icon: "checkmark.circle.fill")
        }
    }

    private var primaryTitle: String {
        if meta.isSeries, let target = seriesPlayTarget {
            let inProgress = progressStore.progress(for: target.id).map { $0.fraction > 0.02 } ?? false
            return "\(inProgress ? "Resume" : "Play") S\(target.season ?? 1):E\(target.episode ?? 1)"
        }
        let key = ProgressStore.key(metaID: meta.id, video: nil)
        if let p = progressStore.progress(for: key), p.fraction > 0.02 { return "Resume" }
        return "Streams"
    }

    private var seriesPlayTarget: MetaVideo? {
        let all = meta.playbackSeasons.flatMap { meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return nil }
        if let inProgress = all.first(where: { ep in
            if let p = progressStore.progress(for: ep.id) { return p.fraction > 0.02 && p.fraction < 0.95 }
            return false
        }) { return inProgress }
        func isWatched(_ ep: MetaVideo) -> Bool {
            watched.isWatched(contentID: meta.id, season: ep.season ?? 0, episode: ep.episode)
        }
        if let firstUnwatched = all.first(where: { !isWatched($0) && (layout.showUnairedNextUp || $0.hasAired) }) {
            return firstUnwatched
        }
        return all.first
    }

    // MARK: Episodes (series)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !meta.seasons.isEmpty {
                HStack(spacing: 20) {
                    Text("Season").font(StremioFont.bold(28)).foregroundStyle(.white)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(meta.seasons, id: \.self) { season in
                                Button {
                                    viewModel.selectedSeason = season
                                    Task { await viewModel.loadSeason(season) }
                                } label: {
                                    StremioSeasonChip(season: season, selected: viewModel.selectedSeason == season)
                                }
                                .buttonStyle(PlainCardButtonStyle())
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            }
            if let season = viewModel.selectedSeason {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 26) {
                        ForEach(meta.episodesIncludingLinkedSpecials(season: season)) { episode in
                            let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
                            Button { onPlay(meta, episode) } label: {
                                StremioEpisodeCard(
                                    episode: episode,
                                    stillURL: episode.thumbnail ?? extra?.still ?? meta.background,
                                    progress: progressStore.progress(for: episode.id)?.fraction,
                                    watched: watched.isWatched(contentID: meta.id, season: season, episode: episode.episode),
                                    castLine: episodeCastLine(viewModel.episodeCasts[episode.id])
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .task { await viewModel.loadCast(for: episode) }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 70)
                }
                .scrollClipDisabled()
                .focusSection()
            }
        }
        .onChange(of: viewModel.selectedSeason) { _, s in
            if let s { Task { await viewModel.loadSeason(s) } }
        }
    }

    // MARK: More like this

    private func episodeCastLine(_ cast: [TMDBService.CastMember]?) -> String? {
        guard let names = cast?.prefix(3).map(\.name), !names.isEmpty else { return nil }
        return "Cast: \(names.joined(separator: ", "))"
    }

    @ViewBuilder
    private var moreLikeThis: some View {
        if !viewModel.moreLikeThis.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("More like this").font(StremioFont.bold(28)).foregroundStyle(.white)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 26) {
                        ForEach(viewModel.moreLikeThis) { item in
                            Button { onSelectItem(item) } label: { PosterCard(item: item) }
                                .mediaCardButtonStyle()
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, 70)
                }
                .scrollClipDisabled()
                .focusSection()
            }
        }
    }
}

// MARK: - Primary action (purple pill)

private struct StremioPrimaryAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StremioPrimaryLabel(title: title, icon: icon)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct StremioPrimaryLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 24, weight: .bold))
            Text(title).font(StremioFont.bold(26))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 34)
        .frame(height: 74)
        .background(Capsule(style: .continuous).fill(StremioSurfaces.accent))
        // Focus = brighter (white edge) + scale + neutral shadow, no glow.
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Color.white.opacity(isFocused ? 0.85 : 0), lineWidth: 2))
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.2), radius: isFocused ? 16 : 8, y: 5)
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(StremioFocus.entry, value: isFocused)
    }
}

// MARK: - Circular action

private struct StremioCircleAction: View {
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StremioCircleLabel(icon: icon, active: active)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct StremioCircleLabel: View {
    @Environment(\.isFocused) private var isFocused
    let icon: String
    let active: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(isFocused || active ? .white : StremioSurfaces.textPrimary)
            .frame(width: 74, height: 74)
            .background(
                Circle().fill(isFocused ? StremioSurfaces.accent
                              : active ? StremioSurfaces.accentFill
                              : StremioSurfaces.card)
            )
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: isFocused ? 12 : 0, y: 4)
            .scaleEffect(isFocused ? 1.06 : 1)
            .animation(StremioFocus.entry, value: isFocused)
    }
}

// MARK: - Season chip

private struct StremioSeasonChip: View {
    @Environment(\.isFocused) private var isFocused
    let season: Int
    let selected: Bool

    var body: some View {
        Text(season == 0 ? "Specials" : "\(season)")
            .font(StremioFont.medium(23))
            .foregroundStyle(isFocused || selected ? .white : StremioSurfaces.textSecondary)
            .padding(.horizontal, 26)
            .frame(height: 56)
            .background(
                Capsule(style: .continuous)
                    .fill(isFocused ? StremioSurfaces.accent
                          : selected ? StremioSurfaces.accentFill : StremioSurfaces.card)
            )
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(StremioFocus.entry, value: isFocused)
    }
}

// MARK: - Episode card

private struct StremioEpisodeCard: View {
    @Environment(\.isFocused) private var isFocused
    let episode: MetaVideo
    let stillURL: String?
    let progress: Double?
    let watched: Bool
    let castLine: String?

    private let width: CGFloat = 420
    private let height: CGFloat = 236

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: stillURL)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: StremioFocus.cardRadius, style: .continuous))
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 2)
                    .padding(.leading, 18)
                    .padding(.bottom, progress != nil ? 22 : 16)
                if let progress, progress > 0.01 {
                    Rectangle().fill(Color.white.opacity(0.3)).frame(height: 5)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(StremioSurfaces.accentBright)
                                .scaleEffect(x: CGFloat(min(max(progress, 0.02), 1)), y: 1, anchor: .leading)
                        }
                        .clipped()
                }
                if watched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(StremioSurfaces.accentBright)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: StremioFocus.cardRadius, style: .continuous)
                        .strokeBorder(StremioSurfaces.accentBright, lineWidth: StremioFocus.borderWidth)
                }
            }
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 20, y: 9)
            .scaleEffect(isFocused ? StremioFocus.landscapeScale : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(titleLine)
                    .font(StremioFont.medium(22))
                    .foregroundStyle(isFocused ? .white : StremioSurfaces.textSecondary)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)

                if let castLine, !castLine.isEmpty {
                    Text(castLine)
                        .font(StremioFont.regular(16))
                        .foregroundStyle(StremioSurfaces.textTertiary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                        .opacity(isFocused ? 1 : 0)
                }
            }
            .frame(width: width, height: castLine?.isEmpty == false ? 68 : 54, alignment: .topLeading)
            .clipped()
        }
        .animation(StremioFocus.entry, value: isFocused)
    }

    private var titleLine: String {
        let ep = episode.episode.map { "EP \($0) · " } ?? ""
        return ep + (episode.title ?? "Episode")
    }
}

// MARK: - Hold-to-choose-source menu

private struct StremioHoldMenu: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu { Button("Choose stream", action: action) }
        } else {
            content
        }
    }
}

private extension View {
    func stremioHoldMenu(enabled: Bool, action: @escaping () -> Void) -> some View {
        modifier(StremioHoldMenu(enabled: enabled, action: action))
    }
}
