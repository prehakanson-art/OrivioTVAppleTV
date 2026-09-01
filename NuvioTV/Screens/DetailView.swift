import SwiftUI
import AVKit

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var meta: MetaItem
    @Published var selectedSeason: Int?
    @Published var isLoading = true
    @Published var cast: [TMDBService.CastMember] = []
    @Published var moreLikeThis: [MetaItem] = []
    @Published var collection: TMDBService.CollectionRef?
    @Published var collectionParts: [MetaItem] = []
    @Published var companies: [TMDBService.Company] = []
    @Published var trailers: [TMDBService.Trailer] = []
    @Published var comments: [TraktService.Comment] = []
    @Published var mdbRatings: MDBListRatings?
    @Published var crew: [TMDBService.CastMember] = []
    @Published var director: String?
    @Published var country: String?
    @Published var language: String?
    @Published var releaseDate: String?
    @Published var contentRating: String?
    @Published var parentalGuide: [ParentalGuideEntry] = []
    /// Per-season episode extras (rating / air date), keyed season → episode.
    @Published var episodeExtras: [Int: [Int: TMDBService.EpisodeExtra]] = [:]
    @Published var episodeCasts: [String: [TMDBService.CastMember]] = [:]
    private var loadingEpisodeCast = Set<String>()

    init(item: MetaItem) {
        meta = item
    }

    func load(addonManager: AddonManager, mdbSettings: MDBListSettings = .default, tmdb: TMDBSettings = .default, parentalGuideEnabled: Bool = false) async {
        useEpisodeExtras = tmdb.useEpisodes
        // Canonicalize the identity FIRST: TMDB-sourced items arrive as
        // `tmdb:<n>`, but progress / watched / library are keyed by id — the
        // same movie found via different addons would otherwise never match
        // its own Continue Watching entry (and Cinemeta can't serve tmdb: ids
        // at all). Resolve to the IMDb tt id once, cached inside TMDBService.
        if meta.id.hasPrefix("tmdb:"), let n = Int(meta.id.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !meta.isSeries) {
            meta = MetaItem(
                id: tt, type: meta.type, name: meta.name,
                poster: meta.poster, background: meta.background, logo: meta.logo,
                description: meta.description, releaseInfo: meta.releaseInfo,
                imdbRating: meta.imdbRating, runtime: meta.runtime,
                genres: meta.genres, cast: meta.cast, videos: meta.videos
            )
        }
        // Kick off TMDB enrichment + Trakt comments in parallel with the meta fetch.
        let enrichTask = Task { await TMDBService.detail(imdbID: meta.id, type: meta.type) }
        let commentsTask = Task { await TraktService.comments(imdbID: meta.id, type: meta.type) }
        let ratingsTask = Task { await loadMDBRatings(settings: mdbSettings) }

        if let addon = addonManager.metaAddon(for: meta.type, id: meta.id),
           let full = try? await StremioAPI.meta(addon: addon, type: meta.type, id: meta.id) {
            meta = full
        }
        if selectedSeason == nil {
            selectedSeason = meta.regularSeasons.first ?? meta.seasons.first
        }
        if let season = selectedSeason { await loadSeason(season) }
        // Episodes are ready now — stop blocking the episode section (gated on
        // `isLoading`) behind Trakt comments / MDBList ratings / parental guide
        // below. Those are unrelated to episodes and can each be slow
        // themselves; a meta addon that aggregates several sources per request
        // (e.g. AIOMetadata) was already the slow part of this load, and
        // chaining three more independent network calls after it responded
        // just made "episodes" wait even longer for no reason.
        isLoading = false

        if let detail = await enrichTask.value {
            // Granular TMDB toggles gate which enriched sections appear.
            if tmdb.useCredits {
                cast = detail.cast
                crew = detail.crew
                director = detail.director
            }
            if tmdb.useDetails {
                country = detail.country
                language = detail.language
            }
            contentRating = detail.contentRating
            if tmdb.useReleaseDates { releaseDate = detail.releaseDate }
            if tmdb.useMoreLikeThis { moreLikeThis = detail.moreLikeThis.deduplicatedByID() }
            if tmdb.useProductions { companies = detail.companies }
            if tmdb.useTrailers { trailers = detail.trailers }
            if tmdb.useCollections {
                collection = detail.collection
                if let collection {
                    collectionParts = await TMDBService.collectionItems(id: collection.id)
                        .filter { $0.id != meta.id }
                        .deduplicatedByID()
                }
            }
        }
        comments = await commentsTask.value
        mdbRatings = await ratingsTask.value
        // Content advisories (IMDb parents guide) once the id is canonical tt.
        if parentalGuideEnabled, meta.id.hasPrefix("tt") {
            parentalGuide = await ParentalGuideService.guide(imdbID: meta.id)
        }
    }

    /// Fetch MDBList source ratings, resolving a tmdb id to imdb first if needed.
    private func loadMDBRatings(settings: MDBListSettings) async -> MDBListRatings? {
        guard settings.isConfigured else { return nil }
        let imdbID: String?
        if meta.id.hasPrefix("tt") {
            imdbID = meta.id
        } else if let (tid, isMovie) = await TMDBService.resolveTMDBID(from: meta.id, type: meta.type) {
            imdbID = await TMDBService.imdbID(tmdbID: tid, isMovie: isMovie)
        } else {
            imdbID = nil
        }
        guard let imdbID else { return nil }
        return await MDBListService.ratings(imdbID: imdbID, type: meta.type, settings: settings)
    }

    /// Whether to fetch per-episode TMDB extras (ratings / air dates). Set from
    /// the TMDB "Episodes" toggle when the detail loads.
    var useEpisodeExtras = true

    /// Load per-episode ratings + air dates for a season (once, cached).
    func loadSeason(_ season: Int) async {
        guard useEpisodeExtras, episodeExtras[season] == nil, meta.isSeries else { return }
        let extras = await TMDBService.seasonEpisodes(imdbID: meta.id, type: meta.type, season: season)
        if !extras.isEmpty { episodeExtras[season] = extras }
    }

    func loadCast(for episode: MetaVideo) async {
        guard meta.isSeries, episodeCasts[episode.id] == nil, !loadingEpisodeCast.contains(episode.id) else { return }
        loadingEpisodeCast.insert(episode.id)
        defer { loadingEpisodeCast.remove(episode.id) }
        let cast = await TMDBService.episodeCast(imdbID: meta.id, type: meta.type, episode: episode)
        if !cast.isEmpty { episodeCasts[episode.id] = cast }
    }
}

private extension View {
    /// Adds a hold-Select "Play Manually" menu to the Play button when Auto
    /// Link Selector is on; a no-op otherwise (Play already opens the list).
    @ViewBuilder
    func playManuallyMenu(enabled: Bool,
                          action: @escaping () -> Void,
                          infuse: (() -> Void)? = nil) -> some View {
        if enabled {
            contextMenu {
                Button(action: action) {
                    Label("Play Manually", systemImage: "list.and.film")
                }
                // Only offered when Infuse is actually installed — a menu entry
                // that opens nothing is worse than no entry.
                if let infuse, ExternalPlayers.isInfuseInstalled {
                    Button(action: infuse) {
                        Label("Play in Infuse", systemImage: "arrow.up.forward.app.fill")
                    }
                }
            }
        } else {
            self
        }
    }
}

struct DetailView: View {
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
    /// Open the manual source list, bypassing Auto Link Selector (hold-Play).
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Resolve the auto-picked link and hand it to Infuse (hold-Play).
    var onPlayInInfuse: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    let onPlayFromBeginning: (MetaItem, MetaVideo?) -> Void
    var onSelectItem: (MetaItem) -> Void = { _ in }
    var onSelectPerson: (Int, String) -> Void = { _, _ in }
    var onSelectCompany: (Int, String) -> Void = { _, _ in }
    @State private var activeTrailer: TMDBService.Trailer?
    @State private var showRatingPicker = false
    /// Trailer playing silently in the backdrop after the idle delay.
    @State private var backdropPlayer: AVPlayer?
    @State private var showBackdropTrailer = false
    /// Loop observer for the backdrop trailer, removed on teardown — otherwise
    /// every Detail visit leaves a dead block registered with the notification
    /// center forever.
    @State private var backdropLoopToken: NSObjectProtocol?

    init(
        item: MetaItem,
        onPlay: @escaping (MetaItem, MetaVideo?) -> Void,
        onPlayManually: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onPlayInInfuse: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onPlayFromBeginning: @escaping (MetaItem, MetaVideo?) -> Void = { _, _ in },
        onSelectItem: @escaping (MetaItem) -> Void = { _ in },
        onSelectPerson: @escaping (Int, String) -> Void = { _, _ in },
        onSelectCompany: @escaping (Int, String) -> Void = { _, _ in }
    ) {
        _viewModel = StateObject(wrappedValue: DetailViewModel(item: item))
        self.onPlay = onPlay
        self.onPlayManually = onPlayManually
        self.onPlayInInfuse = onPlayInInfuse
        self.onPlayFromBeginning = onPlayFromBeginning
        self.onSelectItem = onSelectItem
        self.onSelectPerson = onSelectPerson
        self.onSelectCompany = onSelectCompany
    }

    /// Whether the active profile's Auto Link Selector is on (Play auto-picks;
    /// hold-Play offers "Play Manually").
    private var autoLinkOn: Bool { profiles.activeAutoLink.enabled }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            backdrop
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                    header
                    if viewModel.meta.isSeries {
                        episodesSection
                    }
                    castSection
                    collectionSection
                    moreLikeThisSection
                    companiesSection
                    commentsSection
                }
                .padding(.bottom, NuvioSpacing.huge)
            }
            .scrollClipDisabled()
        }
        .task { await viewModel.load(addonManager: addonManager, mdbSettings: mdblist.settings, tmdb: tmdbSettings.settings, parentalGuideEnabled: playerSettings.settings.parentalGuideEnabled) }
        // Auto-play the trailer in the backdrop after the configured idle
        // delay. Re-runs once trailers finish loading. Resolves silently — no
        // loading UI — and only swaps in when the video is actually ready.
        .task(id: autoTrailerKey) {
            await startBackdropTrailerIfEnabled()
        }
        .onDisappear { teardownBackdropTrailer() }
        // Opening the full-screen trailer or navigating to play: stop the
        // muted backdrop so two players don't fight over audio.
        .onChange(of: activeTrailer?.id) { _, newValue in
            if newValue != nil { backdropPlayer?.pause() }
        }
        .fullScreenCover(item: $activeTrailer) { trailer in
            TrailerPlayerView(trailer: trailer)
                .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showRatingPicker) {
            RatingPickerOverlay(
                title: viewModel.meta.name,
                current: ratings.rating(for: viewModel.meta.id)
            ) { newRating in
                ratings.setRating(newRating, for: viewModel.meta.id, type: viewModel.meta.type)
                showRatingPicker = false
                ToastCenter.shared.show("Rating Saved", icon: "star.fill")
            } onCancel: { showRatingPicker = false }
            .environmentObject(theme)
        }
    }

    private var backdrop: some View {
        GeometryReader { geo in
            ZStack {
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster)
                    .frame(width: geo.size.width, height: geo.size.height)
                if showBackdropTrailer, let player = backdropPlayer {
                    BackdropVideoView(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
                HeroGradient(background: theme.palette.background, fullBleed: true)
            }
        }
        .ignoresSafeArea()
    }

    /// Changes when the delay setting or the first trailer changes, so the
    /// timed `.task` restarts appropriately.
    private var autoTrailerKey: String {
        "\(playerSettings.settings.autoPlayTrailerSeconds)#\(viewModel.trailers.first?.youtubeKey ?? "")"
    }

    private func startBackdropTrailerIfEnabled() async {
        let delay = playerSettings.settings.autoPlayTrailerSeconds
        guard delay > 0, let trailer = viewModel.trailers.first else { return }
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        guard let url = await TrailerResolver.streamURL(youtubeKey: trailer.youtubeKey) else { return }
        guard !Task.isCancelled else { return }
        let player = AVPlayer(url: url)
        // Silent hero preview (Netflix-style). Muting also means we don't need
        // an active audio session, which on tvOS can otherwise stall a raw
        // AVPlayer's playback entirely.
        player.isMuted = true
        // Loop so the preview keeps running while browsing the page.
        player.actionAtItemEnd = .none
        // The task can re-run within one visit (autoTrailerKey change) —
        // release the previous loop observer before installing a new one.
        if let token = backdropLoopToken { NotificationCenter.default.removeObserver(token) }
        backdropLoopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        backdropPlayer = player
        player.play()
        withAnimation(.easeInOut(duration: 0.6)) { showBackdropTrailer = true }
    }

    private func teardownBackdropTrailer() {
        // Clear the item too, not just pause — otherwise the muted backdrop
        // player stays the system "Now Playing" item and the tvOS transport
        // overlay can pop up over Home when Play/Pause is pressed.
        backdropPlayer?.pause()
        backdropPlayer?.replaceCurrentItem(with: nil)
        backdropPlayer = nil
        if let token = backdropLoopToken {
            NotificationCenter.default.removeObserver(token)
            backdropLoopToken = nil
        }
        showBackdropTrailer = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
            // Push the logo down so it sits lower on the backdrop (APK layout).
            Spacer().frame(height: 260)

            if let logo = viewModel.meta.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                    .frame(width: 520, height: 180)
            } else {
                Text(viewModel.meta.name)
                    .font(.system(size: 62, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            actionRow

            if let director = viewModel.director {
                Text("Director: \(director)")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            if let description = viewModel.meta.description {
                // Clickable teaser → full-description overlay (the Android
                // app's scrollable hero-description feature).
                DescriptionTeaser(text: description, title: viewModel.meta.name)
            }

            // Meta line 1: Genres • Full release date • IMDb.
            MetaLine(segments: primaryMetaSegments, imdbRating: viewModel.meta.imdbRating)
            // Meta line 2: Runtime • Country • Language.
            if !secondaryMetaSegments.isEmpty {
                MetaLine(segments: secondaryMetaSegments)
            }

            if let contentRating = viewModel.contentRating {
                ContentRatingBadge(rating: contentRating)
            }

            if let mdbRatings = viewModel.mdbRatings {
                let entries = mdbRatings.entries(settings: mdblist.settings)
                if !entries.isEmpty {
                    MDBListRatingsRow(entries: entries)
                }
            }

            if !viewModel.parentalGuide.isEmpty {
                ParentalGuideRow(entries: viewModel.parentalGuide)
            }
        }
        .padding(.leading, NuvioSpacing.huge)
    }

    /// Play/Resume (+ Start Over) + circular add / watched / rate / trailer.
    /// Its own focus section so Down/Up move cleanly to/from the rows below
    /// instead of the focus engine skipping a row.
    private var actionRow: some View {
            HStack(spacing: NuvioSpacing.md) {
                if viewModel.meta.isSeries {
                    if let target = seriesPlayTarget {
                        PlayActionButton(title: seriesPlayTitle(target)) {
                            onPlay(viewModel.meta, target)
                        }
                        // Auto Link Selector on: hold Play to pick a source
                        // manually instead of auto-playing the best match.
                        .playManuallyMenu(
                            enabled: autoLinkOn,
                            action: { onPlayManually(viewModel.meta, target) },
                            infuse: { onPlayInInfuse(viewModel.meta, target) }
                        )
                        // Start Over sits right next to Resume: replay the
                        // in-progress episode from 0:00.
                        if episodeInProgress(target) {
                            CircleIconButton(systemName: "gobackward", active: false) {
                                onPlayFromBeginning(viewModel.meta, target)
                            }
                        }
                    }
                } else {
                    PlayActionButton(title: playButtonTitle) {
                        onPlay(viewModel.meta, nil)
                    }
                    .playManuallyMenu(
                        enabled: autoLinkOn,
                        action: { onPlayManually(viewModel.meta, nil) },
                        infuse: { onPlayInInfuse(viewModel.meta, nil) }
                    )
                    // Movie with saved progress → offer a fresh start.
                    if playButtonTitle == "Resume" {
                        CircleIconButton(systemName: "gobackward", active: false) {
                            onPlayFromBeginning(viewModel.meta, nil)
                        }
                    }
                }
                CircleIconButton(
                    systemName: library.contains(viewModel.meta) ? "checkmark" : "plus",
                    active: library.contains(viewModel.meta)
                ) {
                    let wasSaved = library.contains(viewModel.meta)
                    library.toggle(viewModel.meta)
                    ToastCenter.shared.show(wasSaved ? "Removed from Library" : "Added to Library",
                                            icon: wasSaved ? "bookmark.slash" : "checkmark")
                }
                if !viewModel.meta.isSeries {
                    // Eye = seen. Filled + accent when watched, outline when not.
                    CircleIconButton(
                        systemName: watched.isWatched(viewModel.meta) ? "eye.fill" : "eye",
                        active: watched.isWatched(viewModel.meta)
                    ) {
                        let wasWatched = watched.isWatched(viewModel.meta)
                        watched.toggleMovie(viewModel.meta)
                        ToastCenter.shared.show(wasWatched ? "Marked Unwatched" : "Marked Watched",
                                                icon: "eye.fill")
                    }
                }
                // Rate (Trakt) — star fills when you've rated; opens a 1–10 picker.
                CircleIconButton(
                    systemName: ratings.rating(for: viewModel.meta.id) != nil ? "star.fill" : "star",
                    active: ratings.rating(for: viewModel.meta.id) != nil
                ) { showRatingPicker = true }
                if layout.detailPageTrailerButtonEnabled, let trailer = viewModel.trailers.first {
                    CircleIconButton(systemName: "play.rectangle.fill", active: false) {
                        activeTrailer = trailer
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, NuvioSpacing.xs)
            // Full-width focus section: the buttons stay left-aligned, but the
            // section spans the row so pressing Up from a right-scrolled cast
            // card still lands here (a narrow left-only section is missed when
            // the card below is scrolled far right).
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
    }

    private var primaryMetaSegments: [String] {
        var segments: [String] = []
        if let genres = viewModel.meta.genres, !genres.isEmpty {
            segments.append(genres.prefix(3).joined(separator: " • "))
        }
        if let contentRating = viewModel.contentRating {
            segments.append(contentRating)
        }
        if let full = DateFormat.releaseDate(viewModel.releaseDate) ?? viewModel.meta.releaseInfo {
            if layout.showFullReleaseDate {
                segments.append(full)
            } else {
                segments.append(Self.firstYear(in: viewModel.releaseDate ?? full) ?? full)
            }
        }
        return segments
    }

    /// First 4-digit year found in a date/string (for the year-only display).
    private static func firstYear(in text: String) -> String? {
        let digits = Array(text)
        for i in 0...(max(0, digits.count - 4)) where i + 4 <= digits.count {
            let slice = String(digits[i..<i + 4])
            if slice.allSatisfy(\.isNumber), let year = Int(slice), (1900...2100).contains(year) {
                return slice
            }
        }
        return nil
    }

    private var secondaryMetaSegments: [String] {
        var segments: [String] = []
        if let runtime = viewModel.meta.runtimeFormatted { segments.append(runtime) }
        if let country = viewModel.country { segments.append(country) }
        if let language = viewModel.language { segments.append(language) }
        return segments
    }

    private var playButtonTitle: String {
        let key = ProgressStore.key(metaID: viewModel.meta.id, video: nil)
        if let progress = progressStore.progress(for: key), progress.fraction > 0.02 {
            return "Resume"
        }
        return "Play"
    }

    /// Whether this episode has saved progress worth restarting from 0.
    private func episodeInProgress(_ episode: MetaVideo) -> Bool {
        guard let progress = progressStore.progress(for: episode.id) else { return false }
        return progress.fraction > 0.02 && progress.fraction < 0.95
    }

    /// For a series, the episode the Play button should start: an in-progress
    /// episode, else the next-up episode, else the very first — like the APK.
    private var seriesPlayTarget: MetaVideo? {
        let all = viewModel.meta.playbackSeasons.flatMap { viewModel.meta.episodesIncludingLinkedSpecials(season: $0) }
        guard !all.isEmpty else { return nil }
        if let inProgress = all.first(where: { ep in
            if let p = progressStore.progress(for: ep.id) { return p.fraction > 0.02 && p.fraction < 0.95 }
            return false
        }) { return inProgress }

        func isWatched(_ ep: MetaVideo) -> Bool {
            watched.isWatched(contentID: viewModel.meta.id, season: ep.season ?? 0, episode: ep.episode)
        }
        // Candidate unwatched episodes, honoring the "skip unaired" preference.
        let unwatched = all.filter { !isWatched($0) && (layout.showUnairedNextUp || $0.hasAired) }

        if layout.nextUpFromFurthestEpisode {
            // Next-up = the episode right after the FURTHEST watched one.
            if let furthestIndex = all.lastIndex(where: isWatched) {
                if let next = all[(furthestIndex + 1)...].first(where: {
                    layout.showUnairedNextUp || $0.hasAired
                }) { return next }
            }
        }
        if let firstUnwatched = unwatched.first { return firstUnwatched }
        return all.first
    }

    /// Blur an episode still when spoiler-blur is on and the episode is neither
    /// watched nor in progress.
    private func shouldBlurEpisode(_ episode: MetaVideo, season: Int) -> Bool {
        guard layout.blurUnwatchedEpisodes else { return false }
        let isWatched = watched.isWatched(contentID: viewModel.meta.id, season: season, episode: episode.episode)
        let inProgress = (progressStore.progress(for: episode.id)?.fraction ?? 0) > 0.02
        return !isWatched && !inProgress
    }

    private func seriesPlayTitle(_ episode: MetaVideo) -> String {
        let inProgress = progressStore.progress(for: episode.id).map { $0.fraction > 0.02 } ?? false
        let sxe = "S\(episode.season ?? 1):E\(episode.episode ?? 1)"
        return "\(inProgress ? "Resume" : "Play") \(sxe)"
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            if viewModel.meta.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: NuvioSpacing.sm) {
                        ForEach(viewModel.meta.seasons, id: \.self) { season in
                            Button {
                                viewModel.selectedSeason = season
                            } label: {
                                SeasonChip(season: season, selected: viewModel.selectedSeason == season)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.sm)
                }
                .scrollClipDisabled()
            }

            if let season = viewModel.selectedSeason {
                HStack(alignment: .firstTextBaseline) {
                    RowHeader(title: season == 0 ? "Specials" : "Season \(season)")
                    Spacer()
                    // Mark/unmark the whole season in one press.
                    Button {
                        let episodes = viewModel.meta.episodesIncludingLinkedSpecials(season: season)
                        for episode in episodes where !watched.isWatched(
                            contentID: viewModel.meta.id, season: episode.season ?? season, episode: episode.episode
                        ) {
                            watched.mark(meta: viewModel.meta, video: episode)
                        }
                    } label: {
                        SeeAllLabel(text: "Mark Season Watched")
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .padding(.trailing, NuvioSpacing.huge)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: NuvioSpacing.lg) {
                        ForEach(viewModel.meta.episodesIncludingLinkedSpecials(season: season)) { episode in
                            let extra = episode.episode.flatMap { viewModel.episodeExtras[season]?[$0] }
                            Button {
                                onPlay(viewModel.meta, episode)
                            } label: {
                                LandscapeCard(
                                    imageURL: episode.thumbnail ?? extra?.still ?? viewModel.meta.background,
                                    title: episodeTitle(episode),
                                    subtitle: episodeSubtitle(episode, extra: extra),
                                    progress: progressStore.progress(for: episode.id)?.fraction,
                                    watched: watched.isWatched(
                                        contentID: viewModel.meta.id,
                                        season: season,
                                        episode: episode.episode
                                    ),
                                    rating: extra?.rating.map { String(format: "%.1f", $0) },
                                    width: 400,
                                    subtitleBehavior: .readableOnFocus,
                                    detailLine: episodeCastLine(viewModel.episodeCasts[episode.id]),
                                    blurImage: shouldBlurEpisode(episode, season: season)
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .task { await viewModel.loadCast(for: episode) }
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.lg)
                }
                .scrollClipDisabled()
            } else if viewModel.isLoading {
                NuvioLoadingView(label: "Loading episodes")
                    .frame(height: 260)
            }
        }
        .focusSection()
        .onChange(of: viewModel.selectedSeason) { _, newSeason in
            if let newSeason { Task { await viewModel.loadSeason(newSeason) } }
        }
    }

    /// Episode caption: the overview if present, otherwise the localized air date.
    private func episodeSubtitle(_ episode: MetaVideo, extra: TMDBService.EpisodeExtra?) -> String? {
        if let overview = episode.overview, !overview.isEmpty { return overview }
        return DateFormat.releaseDate(extra?.airDate ?? episode.released)
    }

    private func episodeTitle(_ episode: MetaVideo) -> String {
        var label = ""
        if let number = episode.episode { label = "\(number). " }
        return label + (episode.title ?? "Episode")
    }

    private func episodeCastLine(_ cast: [TMDBService.CastMember]?) -> String? {
        guard let names = cast?.prefix(3).map(\.name), !names.isEmpty else { return nil }
        return "Cast: \(names.joined(separator: ", "))"
    }

    // MARK: - Cast

    @ViewBuilder
    private var castSection: some View {
        let people = viewModel.crew + viewModel.cast
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                // The trailer lives only in the action row above; the cast
                // header is just a title (removed the duplicate trailer tab).
                RowHeader(title: "Creator and Cast")

                ScrollView(.horizontal) {
                    LazyHStack(spacing: NuvioSpacing.lg) {
                        ForEach(people) { member in
                            Button {
                                onSelectPerson(member.id, member.name)
                            } label: {
                                CastChip(member: member)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Collection ("belongs to")

    @ViewBuilder
    private var collectionSection: some View {
        if let collection = viewModel.collection, !viewModel.collectionParts.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                RowHeader(title: collection.name)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: NuvioSpacing.lg) {
                        ForEach(viewModel.collectionParts) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                PosterCard(item: item)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.lg)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - More Like This

    @ViewBuilder
    private var moreLikeThisSection: some View {
        if !viewModel.moreLikeThis.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                RowHeader(title: "More Like This")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: NuvioSpacing.lg) {
                        ForEach(viewModel.moreLikeThis) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                PosterCard(item: item)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.lg)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Production companies

    @ViewBuilder
    private var companiesSection: some View {
        if !viewModel.companies.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                RowHeader(title: "Production")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: NuvioSpacing.lg) {
                        ForEach(viewModel.companies) { company in
                            Button {
                                onSelectCompany(company.id, company.name)
                            } label: {
                                CompanyLogo(company: company)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }

    // MARK: - Comments (Trakt)

    @ViewBuilder
    private var commentsSection: some View {
        if !viewModel.comments.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                RowHeader(title: "Comments")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: NuvioSpacing.lg) {
                        ForEach(viewModel.comments) { comment in
                            CommentCard(comment: comment)
                        }
                    }
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.vertical, NuvioSpacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

/// Circular cast headshot with name + character, focusable and clickable
/// through to the actor's filmography.
struct CastChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused

    let member: TMDBService.CastMember

    var body: some View {
        VStack(spacing: NuvioSpacing.sm) {
            RemoteImage(url: member.profileURL, maxDimension: 150)
                .frame(width: 150, height: 150)
                .background(theme.palette.backgroundCard)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
                )
                // Resting shadow rides the Card Shadows switch: every chip in the
                // cast row paid a radius-8 offscreen blur per scroll frame even
                // unfocused — a whole row of them is real cost on the A8 tier,
                // where the switch defaults off. Focused-only otherwise-shaped
                // identically.
                .shadow(color: perf.settings.cardShadows
                            ? .black.opacity(isFocused ? 0.6 : 0.3) : .clear,
                        radius: perf.settings.cardShadows ? (isFocused ? 18 : 8) : 0, y: 6)

            Text(member.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1)
            if let character = member.character, !character.isEmpty {
                Text(character)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 170)
        .focusLift(NuvioFocus.card, isFocused)
    }
}

/// A production-company logo tile on a light plate (TMDB logos are usually
/// transparent white/dark art that needs a neutral background to read).
struct CompanyLogo: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let company: TMDBService.Company

    var body: some View {
        RemoteImage(url: company.logoURL, contentMode: .fit, maxDimension: 180)
            .frame(width: 180, height: 90)
            .padding(.horizontal, NuvioSpacing.md)
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
            )
            .focusLift(NuvioFocus.card, isFocused)
    }
}

/// A single Trakt comment card. Spoilers stay hidden until focused.
struct CommentCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let comment: TraktService.Comment

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.sm) {
            HStack(spacing: NuvioSpacing.sm) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(comment.user)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 14))
                    Text("\(comment.likes)").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(theme.palette.textTertiary)
            }
            if comment.spoiler && !isFocused {
                Text("Spoiler — focus to reveal")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.palette.secondary)
            } else {
                Text(comment.text)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(6)
            }
        }
        .padding(NuvioSpacing.lg)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .focusable()
        .focusLift(NuvioFocus.row, isFocused)
    }
}

/// Circular icon button used for the Detail action row (add / watched / trailer),
/// matching the APK's dark round buttons that fill with the accent on focus.
struct CircleIconButton: View {
    let systemName: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Focus must be read INSIDE the button's label — read outside the
            // Button, `\.isFocused` never turns true and the highlight never
            // shows (only ancestors' focus reaches the environment).
            CircleIconLabel(systemName: systemName, active: active)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct CircleIconLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let systemName: String
    let active: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused || active ? theme.palette.onSecondary : theme.palette.textPrimary)
            .frame(width: 78, height: 78)
            .background(
                Circle().fill(
                    isFocused ? theme.palette.secondary
                    : (active ? theme.palette.secondary.opacity(0.85) : Color.white.opacity(0.14))
                )
            )
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            // Fusion accent focus glow.
            .shadow(color: isFocused ? theme.effectiveFocusGlow : .clear,
                    radius: theme.isAppleTVTheme && isFocused ? 22 : 0)
            .focusLift(NuvioFocus.control, isFocused)
    }
}

struct PlayActionButton: View {
    @EnvironmentObject private var theme: ThemeManager

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.palette.onSecondary)
                .padding(.horizontal, NuvioSpacing.xxl)
                .padding(.vertical, NuvioSpacing.md)
                .background(FocusAwareCapsule())
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

/// Capsule background that brightens and rings while its button is focused.
private struct FocusAwareCapsule: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Capsule(style: .continuous)
            .fill(isFocused ? theme.palette.secondary : theme.palette.secondary.opacity(0.75))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .shadow(color: theme.palette.secondary.opacity(isFocused ? 0.55 : 0), radius: 22, y: 8)
            .focusLift(NuvioFocus.card, isFocused)
    }
}

struct SeasonChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    let season: Int
    let selected: Bool

    var body: some View {
        Text(season == 0 ? "Specials" : "Season \(season)")
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(selected || isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
            .padding(.horizontal, NuvioSpacing.lg)
            .padding(.vertical, NuvioSpacing.sm)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? theme.palette.focusBackground : Color.white.opacity(isFocused ? 0.18 : 0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 2.5)
            )
            .focusLift(NuvioFocus.card, isFocused)
    }
}

/// A compact IMDb parental-guide advisory row: one chip per category, tinted
/// by severity (mild → amber, moderate → orange, severe → red).
private struct ParentalGuideRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entries: [ParentalGuideEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.xs) {
            Text("PARENTAL GUIDE")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(theme.palette.textTertiary)
            HStack(spacing: NuvioSpacing.sm) {
                ForEach(entries.sorted { $0.severity.rank > $1.severity.rank }) { entry in
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(entry.severity.display)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(tint(entry.severity))
                    }
                    .padding(.horizontal, NuvioSpacing.md)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(tint(entry.severity).opacity(0.16))
                    )
                }
            }
        }
        .padding(.top, 2)
    }

    private func tint(_ s: ParentalSeverity) -> Color {
        switch s {
        case .mild: return NuvioPrimitives.warning
        case .moderate: return NuvioPrimitives.amber500
        case .severe: return NuvioPrimitives.error
        }
    }
}

// MARK: - Full description overlay

/// The truncated synopsis on the hero, clickable: opens a full-screen
/// overlay with the complete text (the Android app's scrollable
/// hero-description). Brightens on focus so it reads as selectable.
private struct DescriptionTeaser: View {
    @EnvironmentObject private var theme: ThemeManager
    let text: String
    let title: String
    @State private var showFull = false

    var body: some View {
        Button { showFull = true } label: {
            TeaserLabel(text: text)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $showFull) {
            DescriptionOverlay(title: title, text: text) { showFull = false }
                .environmentObject(theme)
        }
    }
}

private struct TeaserLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 25))
            .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
            .lineLimit(4)
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .fill(isFocused ? theme.palette.focusBackground : .clear)
            )
            .padding(.horizontal, -14)   // keep the resting text aligned as before
    }
}

/// Full synopsis, arrow-scrollable. A full-screen invisible button holds
/// focus (the player's remote-catcher pattern): up/down scroll by a step,
/// Select or Back closes.
private struct DescriptionOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let text: String
    let onClose: () -> Void

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var maxOffset: CGFloat { max(contentHeight - viewportHeight, 0) }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                Text(title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                GeometryReader { viewport in
                    Text(text)
                        .font(.system(size: 28))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { geo in
                                Color.clear.onAppear { contentHeight = geo.size.height }
                            }
                        )
                        .offset(y: -offset)
                        .onAppear { viewportHeight = viewport.size.height }
                }
                .clipped()

                Text(maxOffset > 0 ? "Swipe up/down to scroll · press Back to close"
                                   : "Press Back to close")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(.horizontal, 220)
            .padding(.vertical, 90)

            // Invisible focus holder: Select closes, moves scroll.
            Button(action: onClose) { Color.clear }
                .buttonStyle(PlainCardButtonStyle())
        }
        .onMoveCommand { direction in
            let step: CGFloat = 340
            withAnimation(.easeOut(duration: 0.25)) {
                switch direction {
                case .down: offset = min(offset + step, maxOffset)
                case .up: offset = max(offset - step, 0)
                default: break
                }
            }
        }
        .onExitCommand { onClose() }
        .onPlayPauseCommand { onClose() }
    }
}

/// A 1–10 Trakt-style rating picker: a row of ten number buttons plus Clear.
/// tvOS-focusable, dismisses on selection.
private struct RatingPickerOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let current: Int?
    let onRate: (Int?) -> Void
    let onCancel: () -> Void
    @FocusState private var focus: Int?

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
                .onTapGesture { onCancel() }
            VStack(spacing: NuvioSpacing.xl) {
                Text("Rate")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(title)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)

                HStack(spacing: NuvioSpacing.md) {
                    ForEach(1...10, id: \.self) { n in
                        Button { onRate(n) } label: {
                            Text("\(n)")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(current == n ? theme.palette.onSecondary : theme.palette.textPrimary)
                                .frame(width: 74, height: 90)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(current == n ? theme.palette.secondary : theme.palette.backgroundElevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(focus == n ? theme.palette.secondary : .clear, lineWidth: 4)
                                )
                                .focusLift(NuvioFocus.control, focus == n)
                        }
                        .buttonStyle(.plain)
                        .focused($focus, equals: n)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: focus)

                if current != nil {
                    Button { onRate(nil) } label: {
                        Text("Clear rating")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(NuvioPrimitives.error)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .background(Capsule().fill(theme.palette.backgroundElevated))
                            .overlay(Capsule().strokeBorder(focus == 0 ? NuvioPrimitives.error : .clear, lineWidth: 4))
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: 0)
                }

                Text("Press Menu to cancel")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(NuvioSpacing.huge)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(theme.palette.background)
            )
        }
        .onExitCommand { onCancel() }
        .onAppear { focus = current ?? 8 }
    }
}
