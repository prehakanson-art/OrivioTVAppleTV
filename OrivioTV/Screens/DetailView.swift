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
    /// Adds the hold-Select menu to the Play button ONLY when Auto Link
    /// Selector is on (Play Manually / Play in Infuse); with it off, Play
    /// already opens the source list, so there is no menu at all.
    @ViewBuilder
    func playManuallyMenu(enabled: Bool,
                          action: @escaping () -> Void,
                          infuse: (() -> Void)? = nil) -> some View {
        if enabled {
            contextMenu {
                Button(action: action) {
                    Label("Play Manually", systemImage: "list.and.film")
                }
                if let infuse {
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
    @ObservedObject private var perf = PerformanceSettingsStore.shared
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
    /// The action row's controls, for the enter-lands-on-Play redirect.
    private enum ActionControl: Hashable {
        case play, startOver, library, watched, rate, trailer
    }
    /// Entering the action row from ANY direction lands on the Play button:
    /// when focus arrives on any other control while the row didn't previously
    /// hold focus, it's immediately redirected to Play. (`.focusScope`, and
    /// `.defaultFocus` applied to the ROW, both BROKE directional entry into
    /// the row's focusSection on tvOS 26; this manual redirect doesn't. The
    /// `.defaultFocus` on the scroll view in `body` is a different thing —
    /// it only decides the page's OPENING focus, not directional moves.)
    @FocusState private var actionFocus: ActionControl?
    /// How Play was pressed while a series' episode list was still loading —
    /// replayed against the real episode the moment it resolves.
    private enum PendingPlay { case auto, manual, infuse }
    @State private var pendingSeriesPlay: PendingPlay?
    @State private var showRatingPicker = false
    /// Trailer playing silently in the backdrop after the idle delay.
    @State private var backdropPlayer: AVPlayer?
    @State private var showBackdropTrailer = false
    /// Loop observer for the backdrop trailer, removed on teardown — otherwise
    /// every Detail visit leaves a dead block registered with the notification
    /// center forever.
    @State private var backdropLoopToken: NSObjectProtocol?
    /// Netflix-style: once the muted backdrop trailer has been playing and the
    /// user stays idle a beat longer, the page chrome fades away and the
    /// trailer takes the full screen (with sound). Any press/move restores.
    @State private var trailerFullscreen = false
    @State private var teaserFocused = false
    /// Bumped on any tracked focus change; re-arms (or cancels) the idle timer.
    @State private var interactionCount = 0
    /// Set when the user backs OUT of full-screen: the idle timer stays
    /// disarmed until they actually move again, so exiting doesn't bounce
    /// straight back into full-screen after the next 2 idle seconds.
    @State private var fullscreenCooldown = false
    /// When full-screen was last exited; focus changes inside a short window
    /// after it are the programmatic restore, not the user moving.
    @State private var fullscreenExitedAt = Date.distantPast
    /// True only while the muted backdrop trailer is actually rendering
    /// frames. `showBackdropTrailer` flips as soon as the player is created,
    /// long before the first frame — full-screen used to fade the chrome out
    /// over the static backdrop, then eat the next press to come back.
    @State private var backdropTrailerPlaying = false
    @State private var backdropStatusObserver: NSKeyValueObservation?
    @FocusState private var fullscreenTrailerFocus: Bool

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
            ATVBackground()
            backdrop
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
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
                .padding(.bottom, OrivioSpacing.huge)
            }
            .scrollClipDisabled()
            // Play owns the page from the first frame. Without this the focus
            // engine picks the topmost focusable — the synopsis teaser — and
            // the action row's entry redirect then hops focus down to Play in
            // a later frame, which reads as the page snatching focus away from
            // whatever you were looking at.
            .defaultFocus($actionFocus, .play)
            .opacity(trailerFullscreen ? 0 : 1)
            // Hidden is NOT unfocusable: without this, focus could stay on the
            // invisible synopsis during full-screen — whose move-handler then
            // swallowed every press, locking full-screen mode in.
            .disabled(trailerFullscreen)

            // Full-screen trailer mode: an invisible focusable overlay holds
            // focus; ANY input — move, Select, Menu, ⏯ — restores the page.
            // NOT a Button: one with a fully transparent label never becomes
            // focusable, so nothing held focus and full-screen locked in.
            if trailerFullscreen {
                Color.black.opacity(0.001)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .focusable()
                    .focused($fullscreenTrailerFocus)
                    .onMoveCommand { _ in exitTrailerFullscreen() }
                    .onExitCommand { exitTrailerFullscreen() }
                    .onPlayPauseCommand { exitTrailerFullscreen() }
                    .onTapGesture { exitTrailerFullscreen() }
            }
        }
        // Arm the idle → full-screen countdown whenever the trailer is up and
        // the user is resting in the header; any tracked interaction re-arms.
        .task(id: "\(backdropTrailerPlaying)#\(interactionCount)#\(trailerFullscreen)") {
            guard backdropTrailerPlaying, !trailerFullscreen, !fullscreenCooldown,
                  activeTrailer == nil, !showRatingPicker,
                  actionFocus != nil || teaserFocused else { return }
            // A real rest, not a reading pause: the first press after the
            // chrome fades only brings it back, so this must never fire while
            // someone is still deciding.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, backdropTrailerPlaying, !trailerFullscreen,
                  !fullscreenCooldown, activeTrailer == nil, !showRatingPicker else { return }
            // Un-muting needs a live audio session — the muted backdrop
            // deliberately runs without one (a raw AVPlayer can stall on tvOS
            // otherwise), so without this the full-screen trailer was SILENT.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            backdropPlayer?.isMuted = false
            // A bare AVPlayerLayer doesn't suppress the tvOS screensaver the
            // way AVPlayerViewController does — without this the Aerial saver
            // rolled in over a full-screen trailer.
            UIApplication.shared.isIdleTimerDisabled = true
            withAnimation(.easeInOut(duration: 0.6)) { trailerFullscreen = true }
            // Deferred: set in the same transaction as the button's insertion
            // it can be ignored.
            try? await Task.sleep(for: .milliseconds(120))
            fullscreenTrailerFocus = true
        }
        .task {
            // Dev: -focusLog prints the focused item every 2s (sim key
            // delivery is flaky; this is the only reliable focus truth).
            if ProcessInfo.processInfo.arguments.contains("-focusLog") {
                while !Task.isCancelled {
                    let env = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
                    let item = env.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                    NSLog("[OrivioFocus] focused=%@ fs=%d captureFocus=%d teaser=%d action=%@",
                          item.map { String(describing: $0).prefix(200) }.map(String.init) ?? "NONE",
                          trailerFullscreen ? 1 : 0,
                          fullscreenTrailerFocus ? 1 : 0,
                          teaserFocused ? 1 : 0,
                          actionFocus.map { String(describing: $0) } ?? "nil")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        // Play pressed before the episode list arrived: run it now, against
        // the episode the loaded data actually points at.
        .onChange(of: seriesPlayTarget?.id) { _, _ in
            guard let pending = pendingSeriesPlay, let target = seriesPlayTarget else { return }
            pendingSeriesPlay = nil
            switch pending {
            case .auto: onPlay(viewModel.meta, target)
            case .manual: onPlayManually(viewModel.meta, target)
            case .infuse: onPlayInInfuse(viewModel.meta, target)
            }
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
                // Decorative backdrop — kept out of hit testing so it cannot
                // swallow the action row's context-menu hit test (the same bug
                // the home Featured bar caused for Continue Watching).
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster)
                    .allowsHitTesting(false)
                    .frame(width: geo.size.width, height: geo.size.height)
                if showBackdropTrailer, let player = backdropPlayer {
                    BackdropVideoView(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                HeroGradient(background: theme.stageBlend, fullBleed: true)
                    .opacity(trailerFullscreen ? 0 : 1)
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
        // Reduce Motion keeps the still backdrop. An auto-starting, looping
        // trailer is unrequested motion by definition, and it escalates itself
        // to full screen a few seconds later — a large positional transition
        // the viewer never asked for and the setting's copy never mentions.
        guard !perf.reduceMotion else { return }
        guard delay > 0, let trailer = viewModel.trailers.first else { return }
        // Resolve WHILE the idle delay runs, not after it — extraction (and
        // the remote fallback especially) can take several seconds, and
        // serializing it behind the delay made the trailer feel like forever.
        async let resolved = TrailerResolver.backdropItem(youtubeKey: trailer.youtubeKey)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        guard let item = await resolved else {
            NSLog("[OrivioTrailer] backdrop resolve failed for %@", trailer.youtubeKey)
            return
        }
        guard !Task.isCancelled else { return }
        let player = AVPlayer(playerItem: item)
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
        backdropStatusObserver?.invalidate()
        backdropStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in backdropTrailerPlaying = playing }
        }
        player.play()
        withAnimation(.easeInOut(duration: 0.6)) { showBackdropTrailer = true }
    }

    /// Restore the detail page from full-screen trailer mode and put focus
    /// back on Play.
    private func exitTrailerFullscreen() {
        fullscreenCooldown = true
        fullscreenExitedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = false
        backdropPlayer?.isMuted = true
        // Give interrupted audio (another app's music) its shouldResume back —
        // full-screen mode activated the session to un-mute.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        withAnimation(.easeInOut(duration: 0.35)) { trailerFullscreen = false }
        // AFTER the capture button leaves the tree and the focus engine's own
        // re-resolve has settled — set too early it gets overridden by the
        // geometrically nearest item (the synopsis). One request is not always
        // honored either (the engine can re-resolve onto the synopsis a beat
        // later), so keep asking for a few ticks until Play actually holds it.
        Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !trailerFullscreen else { return }
                if actionFocus == .play && !teaserFocused { return }
                if actionFocus == .play {
                    // Stale binding (focus moved on without SwiftUI noticing):
                    // clear it on one tick so the next set is a real request.
                    actionFocus = nil
                    try? await Task.sleep(for: .milliseconds(30))
                }
                actionFocus = .play
            }
        }
    }

    private func teardownBackdropTrailer() {
        if trailerFullscreen {
            UIApplication.shared.isIdleTimerDisabled = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        trailerFullscreen = false
        backdropStatusObserver?.invalidate()
        backdropStatusObserver = nil
        backdropTrailerPlaying = false
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
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            // Push the logo down so it sits lower on the backdrop (APK layout).
            Spacer().frame(height: 260)

            // Both title treatments occupy the SAME 180pt slot, bottom-aligned.
            // They did not before: a logo got a fixed 180pt box while the text
            // fallback was sized by its own content, so a one-line title sat
            // about a hundred points higher than a logo and dragged the meta
            // lines, description and buttons up with it. Moving between two
            // titles — one with artwork, one without — visibly re-laid out the
            // whole header. Bottom alignment is what keeps a short wide logo
            // and a two-line title sharing a baseline.
            Group {
                if let logo = viewModel.meta.logo {
                    RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                        // Grounds a white logo on both a light frost and dark art.
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                        .frame(width: 520)
                } else {
                    Text(viewModel.meta.name)
                        .font(FusionType.heroTitle(theme.font))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: 900, alignment: .leading)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                }
            }
            .frame(height: 180, alignment: .bottomLeading)

            // Meta line 1: Genres • Full release date • IMDb.
            MetaLine(segments: primaryMetaSegments, imdbRating: viewModel.meta.imdbRating)
            // Meta line 2: Runtime • Country • Language.
            if !secondaryMetaSegments.isEmpty {
                MetaLine(segments: secondaryMetaSegments)
            }

            if let description = viewModel.meta.description {
                // Clickable teaser → full-description overlay (the Android
                // app's scrollable hero-description feature).
                DescriptionTeaser(
                    text: description,
                    title: viewModel.meta.name,
                    onFocusChanged: { focused in
                        teaserFocused = focused
                        // NOT clearing fullscreenCooldown here: focus falls
                        // back onto the teaser as part of exiting full-screen.
                        interactionCount += 1
                    }
                )
            }

            actionRow

            if let director = viewModel.director {
                Text("Director: \(director)")
                    .font(FusionType.metadata(theme.font))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            // Fact chips grouped on one tight block under the actions.
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
        .padding(.leading, OrivioSpacing.huge)
    }

    /// Play/Resume (+ Start Over) + circular add / watched / rate / trailer.
    /// Its own focus section so Down/Up move cleanly to/from the rows below
    /// instead of the focus engine skipping a row.
    private var actionRow: some View {
            HStack(spacing: OrivioSpacing.md) {
                if viewModel.meta.isSeries {
                    // The Play button is present from the FIRST frame, even
                    // before the episode list has loaded and `seriesPlayTarget`
                    // can say which episode it starts. It used to be wrapped in
                    // `if let target = seriesPlayTarget`, so a series page
                    // opened with no Play button at all: focus settled on the
                    // synopsis or a circle icon, then Play appeared a moment
                    // later and the entry redirect yanked focus across the row
                    // — the visible jump. Pressing it early is not lost either:
                    // `pendingSeriesPlay` fires it as soon as the target lands.
                    let target = seriesPlayTarget
                    PlayActionButton(title: target.map(seriesPlayTitle) ?? "Play") {
                        if let target {
                            onPlay(viewModel.meta, target)
                        } else {
                            pendingSeriesPlay = .auto
                        }
                    }
                    .focused($actionFocus, equals: .play)
                    // Auto Link Selector on: hold Play to pick a source
                    // manually instead of auto-playing the best match.
                    .playManuallyMenu(
                        enabled: autoLinkOn,
                        action: {
                            if let target { onPlayManually(viewModel.meta, target) }
                            else { pendingSeriesPlay = .manual }
                        },
                        infuse: {
                            if let target { onPlayInInfuse(viewModel.meta, target) }
                            else { pendingSeriesPlay = .infuse }
                        }
                    )
                    // Start Over sits right next to Resume: replay the
                    // in-progress episode from 0:00.
                    if let target, episodeInProgress(target) {
                        CircleIconButton(systemName: "gobackward", active: false) {
                            onPlayFromBeginning(viewModel.meta, target)
                        }
                        .focused($actionFocus, equals: .startOver)
                    }
                } else {
                    PlayActionButton(title: playButtonTitle) {
                        onPlay(viewModel.meta, nil)
                    }
                    .focused($actionFocus, equals: .play)
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
                        .focused($actionFocus, equals: .startOver)
                    }
                }
                // The secondary icons are one focus section, so a vertical
                // move into the row resolves against the section as a unit
                // instead of picking whichever circle's centre happens to be
                // nearest. tvOS chooses a Down/Up target by horizontal CENTRE
                // distance, and from the synopsis (centre ~564) or an episode
                // card (centre ~344) a bare circle always beat Play at x=64 —
                // so focus visibly landed on an icon before the row's redirect
                // pulled it back. That flash is the "jump".
                HStack(spacing: OrivioSpacing.md) {
                CircleIconButton(
                    systemName: library.contains(viewModel.meta) ? "checkmark" : "plus",
                    active: library.contains(viewModel.meta)
                ) {
                    let wasSaved = library.contains(viewModel.meta)
                    library.toggle(viewModel.meta)
                    ToastCenter.shared.show(wasSaved ? "Removed from Library" : "Added to Library",
                                            icon: wasSaved ? "bookmark.slash" : "checkmark")
                }
                .focused($actionFocus, equals: .library)
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
                    .focused($actionFocus, equals: .watched)
                }
                // Rate (Trakt) — star fills when you've rated; opens a 1–10 picker.
                CircleIconButton(
                    systemName: ratings.rating(for: viewModel.meta.id) != nil ? "star.fill" : "star",
                    active: ratings.rating(for: viewModel.meta.id) != nil
                ) { showRatingPicker = true }
                .focused($actionFocus, equals: .rate)
                if layout.detailPageTrailerButtonEnabled, let trailer = viewModel.trailers.first {
                    CircleIconButton(systemName: "play.rectangle.fill", active: false) {
                        activeTrailer = trailer
                    }
                    .focused($actionFocus, equals: .trailer)
                }
                }
                .focusSection()
                Spacer(minLength: 0)
            }
            .padding(.top, OrivioSpacing.xs)
            // Full-width focus section: the buttons stay left-aligned, but the
            // section spans the row so pressing Up from a right-scrolled cast
            // card still lands here (a narrow left-only section is missed when
            // the card below is scrolled far right).
            .frame(maxWidth: .infinity, alignment: .leading)
            // NO .focusSection() here: a programmatic `actionFocus = .play`
            // from OUTSIDE a focus section is silently ignored on tvOS 26,
            // which broke the teaser's direct Down-to-Play jump. Reachability
            // from below is covered by the entry redirect instead.
            //
            // The circle buttons are ALWAYS focusable. They used to carry
            // `.focusable(actionFocus != nil)` so that entering the row could
            // only land on Play — but that makes the focusable SET depend on
            // focus itself: pressing Down on the synopsis set actionFocus,
            // which re-rendered the row and flipped the circles to focusable
            // mid-move, so the focus engine invalidated and bounced focus back
            // up to the synopsis. Never gate focusability on focus state.
            // The enter-lands-on-Play redirect: focus arriving on any control
            // while the row previously held NOTHING gets moved to Play. Moves
            // WITHIN the row (old != nil) are left alone.
            .onChange(of: actionFocus) { old, new in
                interactionCount += 1
                // Only a USER move re-arms full-screen. Leaving full-screen
                // restores focus to Play programmatically; treating that as
                // interaction cleared the cooldown, so the page went back to
                // full-screen two seconds later and swallowed every other
                // press — the details page felt dead.
                if Date().timeIntervalSince(fullscreenExitedAt) > 1.0 {
                    fullscreenCooldown = false
                }
                if old == nil, let new, new != .play {
                    // DEFERRED, not immediate: setting @FocusState while the
                    // engine's own move is still in flight made it revert —
                    // Down from the synopsis went circle -> Play -> back to the
                    // synopsis, so the press appeared to do nothing at all.
                    // The icon it lands on never PAINTS in the meantime; see
                    // CircleIconLabel.
                    Task { @MainActor in
                        guard actionFocus != nil, actionFocus != .play else { return }
                        actionFocus = .play
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            if viewModel.meta.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: OrivioSpacing.sm) {
                        ForEach(viewModel.meta.seasons, id: \.self) { season in
                            Button {
                                viewModel.selectedSeason = season
                            } label: {
                                SeasonChip(season: season, selected: viewModel.selectedSeason == season)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.sm)
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
                    .padding(.trailing, OrivioSpacing.huge)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
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
                            // Hold Select on an episode to flip its watched
                            // state without opening it.
                            .contextMenu {
                                Button {
                                    toggleWatched(episode, season: season)
                                } label: {
                                    Label(isWatched(episode, season: season)
                                          ? "Mark as Unwatched" : "Mark as Watched",
                                          systemImage: isWatched(episode, season: season)
                                          ? "eye.slash" : "checkmark.circle")
                                }
                            }
                            .task { await viewModel.loadCast(for: episode) }
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.lg)
                }
                .scrollClipDisabled()
                // The EPISODE ROW is the focus section, not the whole block.
                // With the section around the block, Down from Play entered it
                // and the engine picked the section's nearest item — "Mark
                // Season Watched", parked at the far right — so leaving Play
                // threw focus 1400pt across the screen. Sectioning only the row
                // leaves the header button to the ordinary directional rules,
                // which never pick it for a Down out of Play: it isn't below
                // Play, the episodes are.
                .focusSection()
            } else if viewModel.isLoading {
                OrivioLoadingView(label: "Loading episodes")
                    .frame(height: 260)
            }
        }
        .onChange(of: viewModel.selectedSeason) { _, newSeason in
            if let newSeason { Task { await viewModel.loadSeason(newSeason) } }
        }
    }

    private func isWatched(_ episode: MetaVideo, season: Int) -> Bool {
        watched.isWatched(contentID: viewModel.meta.id,
                          season: episode.season ?? season,
                          episode: episode.episode)
    }

    /// Flip one episode's watched state from the hold menu.
    private func toggleWatched(_ episode: MetaVideo, season: Int) {
        if isWatched(episode, season: season) {
            watched.remove(contentID: viewModel.meta.id,
                           season: episode.season ?? season,
                           episode: episode.episode)
        } else {
            watched.mark(meta: viewModel.meta, video: episode)
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
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                // The trailer lives only in the action row above; the cast
                // header is just a title (removed the duplicate trailer tab).
                RowHeader(title: "Creator and Cast")

                ScrollView(.horizontal) {
                    LazyHStack(spacing: OrivioSpacing.lg) {
                        ForEach(people) { member in
                            Button {
                                onSelectPerson(member.id, member.name)
                            } label: {
                                CastChip(member: member)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.md)
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
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                RowHeader(title: collection.name)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: OrivioSpacing.lg) {
                        ForEach(viewModel.collectionParts) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                PosterCard(item: item)
                            }
                            .mediaCardButtonStyle()
                            .posterHoldMenu(item) { onSelectItem(item) }
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.lg)
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
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                RowHeader(title: "More Like This")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: OrivioSpacing.lg) {
                        ForEach(viewModel.moreLikeThis) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                PosterCard(item: item)
                            }
                            .mediaCardButtonStyle()
                            .posterHoldMenu(item) { onSelectItem(item) }
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.lg)
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
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                RowHeader(title: "Production")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: OrivioSpacing.lg) {
                        ForEach(viewModel.companies) { company in
                            Button {
                                onSelectCompany(company.id, company.name)
                            } label: {
                                CompanyLogo(company: company)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.md)
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
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                RowHeader(title: "Comments")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: OrivioSpacing.lg) {
                        ForEach(viewModel.comments) { comment in
                            CommentCard(comment: comment)
                        }
                    }
                    .padding(.horizontal, OrivioSpacing.huge)
                    .padding(.vertical, OrivioSpacing.md)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

/// A button style with NO chrome at all — used by the full-screen trailer's
/// invisible input-capture button.
private struct InertButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Circular cast headshot with name + character, focusable and clickable
/// through to the actor's filmography.
struct CastChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused

    let member: TMDBService.CastMember

    var body: some View {
        VStack(spacing: OrivioSpacing.sm) {
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
        .focusLift(OrivioFocus.card, isFocused)
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
            .padding(.horizontal, OrivioSpacing.md)
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }
}

/// A single Trakt comment card. Spoilers stay hidden until focused.
struct CommentCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let comment: TraktService.Comment

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            HStack(spacing: OrivioSpacing.sm) {
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
        .padding(OrivioSpacing.lg)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .focusable()
        .focusLift(OrivioFocus.row, isFocused)
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
    @Environment(\.isFocused) private var rawFocused
    let systemName: String
    let active: Bool

    /// Real focus, mirrored into state so the debounce below can re-read it.
    @State private var focusedNow = false
    /// Focus as DRAWN — real focus that has survived `paintDelay`.
    @State private var painted = false

    /// A vertical move into the action row lands on one of these icons before
    /// the row's redirect puts focus on Play: tvOS resolves such a move by
    /// horizontal centre distance and an icon's centre always beats Play's at
    /// x=64. The move itself can't be vetoed — SwiftUI reports focus after the
    /// engine has committed it — so the icon simply doesn't draw the highlight
    /// until it has held focus for three frames. A correction takes about one,
    /// so the visit never reaches the screen; a real Left/Right move onto an
    /// icon is 50ms behind, well inside the focus animation that follows.
    /// (Driving this off the row's @FocusState instead does NOT work:
    /// @FocusState updates a beat AFTER the focus system, so the icon has
    /// already painted by the time the row knows anything moved.)
    private static let paintDelay = Duration.milliseconds(50)

    private var isFocused: Bool { painted }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isFocused || active ? theme.palette.onSecondary : theme.palette.textPrimary)
            .frame(width: 78, height: 78)
            .background {
                if isFocused || active {
                    Circle().fill(active && !isFocused
                                  ? theme.palette.secondary.opacity(0.85)
                                  : theme.palette.secondary)
                }
            }
            // Glass circle at rest, matching the rail.
            .liquidGlassIf(!isFocused && !active, in: Circle())
            .overlay(Circle().strokeBorder(isFocused ? Color.white.opacity(0.95) : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.control, isFocused)
            .onAppear {
                focusedNow = rawFocused
                painted = rawFocused
            }
            .onChange(of: rawFocused) { _, focused in
                focusedNow = focused
                guard focused else { painted = false; return }
                Task { @MainActor in
                    try? await Task.sleep(for: Self.paintDelay)
                    if focusedNow { painted = true }
                }
            }
    }
}

/// Primary Play/Resume pill — the SAME chrome as the home hero's button
/// (white pill at rest, accent fill + white ring + accent glow on focus), so
/// the app's main action reads identically everywhere.
struct PlayActionButton: View {
    @EnvironmentObject private var theme: ThemeManager

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill").font(.system(size: 24, weight: .bold))
                Text(title).font(FusionType.button(theme.font))
            }
        }
        .buttonStyle(DetailPillButtonStyle())
    }
}

/// The hero pill chrome, shared by the detail page's primary action.
struct DetailPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        @EnvironmentObject private var theme: ThemeManager
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? .white : .black)
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.9)))
                .overlay(
                    Capsule().strokeBorder(isFocused ? Color.white.opacity(0.95) : .clear, lineWidth: 4)
                )
                .shadow(color: isFocused ? theme.palette.secondary.opacity(0.7) : .black.opacity(0.14),
                        radius: isFocused ? 26 : 6, y: isFocused ? 12 : 6)
                .focusLift(OrivioFocus.card, isFocused)
                .cardPressDip(configuration.isPressed)
        }
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
            .foregroundStyle(isFocused ? .black
                             : (selected ? theme.palette.textPrimary : theme.palette.textSecondary))
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, OrivioSpacing.sm)
            .background {
                if isFocused {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.92))
                } else if selected {
                    Capsule(style: .continuous).fill(theme.palette.secondary.opacity(0.28))
                }
            }
            .liquidGlassIf(!isFocused && !selected, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(selected && !isFocused ? theme.palette.secondary.opacity(0.8) : .clear,
                                  lineWidth: 2.5)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }
}

/// A compact IMDb parental-guide advisory row: one chip per category, tinted
/// by severity (mild → amber, moderate → orange, severe → red).
private struct ParentalGuideRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entries: [ParentalGuideEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.xs) {
            Text("PARENTAL GUIDE")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(theme.palette.textTertiary)
            HStack(spacing: OrivioSpacing.sm) {
                ForEach(entries.sorted { $0.severity.rank > $1.severity.rank }) { entry in
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(entry.severity.display)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(tint(entry.severity))
                    }
                    .padding(.horizontal, OrivioSpacing.md)
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
        case .mild: return OrivioPrimitives.warning
        case .moderate: return OrivioPrimitives.amber500
        case .severe: return OrivioPrimitives.error
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
    var onFocusChanged: (Bool) -> Void = { _ in }
    @State private var showFull = false

    var body: some View {
        Button { showFull = true } label: {
            TeaserLabel(text: text, onFocusChanged: onFocusChanged)
        }
        .buttonStyle(PlainCardButtonStyle())
        // No .onMoveCommand redirect here. It set `actionFocus = .play` while
        // the engine's own Down was still in flight, and the engine won: focus
        // went to a circle icon anyway, then the action row's entry redirect
        // moved it to Play, then the whole update reverted to the teaser — so
        // pressing Down on the synopsis LOOKED like it did nothing. The row's
        // redirect (deferred by one turn) is the single owner of that move now.
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
    var onFocusChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Text(text)
            .font(.system(size: 25))
            .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
            .lineLimit(4)
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Soft glass highlight on focus — reads as selectable without
            // the old solid accent slab shouting over the art.
            .liquidGlassIf(isFocused, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.35) : .clear, lineWidth: 2)
            )
            .padding(.horizontal, -14)   // keep the resting text aligned as before
            .onChange(of: isFocused) { _, focused in onFocusChanged(focused) }
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
            ATVBackground()

            VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
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
            VStack(spacing: OrivioSpacing.xl) {
                Text("Rate")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(title)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)

                HStack(spacing: OrivioSpacing.md) {
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
                                .focusLift(OrivioFocus.control, focus == n)
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
                            .foregroundStyle(OrivioPrimitives.error)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .background(Capsule().fill(theme.palette.backgroundElevated))
                            .overlay(Capsule().strokeBorder(focus == 0 ? OrivioPrimitives.error : .clear, lineWidth: 4))
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: 0)
                }

                Text("Press Menu to cancel")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(OrivioSpacing.huge)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(theme.palette.background)
            )
        }
        .onExitCommand { onCancel() }
        .onAppear { focus = current ?? 8 }
    }
}
