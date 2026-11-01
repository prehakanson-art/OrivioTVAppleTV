import SwiftUI

/// Sections below the Detail hero, on the art field. Sections with no data are hidden.
struct DetailSections: View {
    @ObservedObject var model: DetailModel
    let autoSelectOn: Bool
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @Environment(\.currentTab) private var tab
    private var meta: MetaItem { model.meta }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("DetailSections")
        #endif
        content
    }

    #if DEBUG
    /// `-detailSkip trailers,cast,…`: leave sections out (cost A/B on the device).
    private static let skip: Set<String> = {
        guard let i = CommandLine.arguments.firstIndex(of: "-detailSkip"), i + 1 < CommandLine.arguments.count else { return [] }
        return Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
    }()
    #else
    private static let skip: Set<String> = []
    #endif
    private func on(_ name: String) -> Bool { !Self.skip.contains(name) }

    private var content: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap - 30) {
            if meta.isSeries, !meta.seasons.isEmpty, on("episodes") { episodes }
            if on("trailers") { trailers }
            if !model.collectionParts.isEmpty, on("collection") {
                posterRow(key: "collection", title: model.enrichment?.collectionName ?? "Collection", items: model.collectionParts)
            }
            // The rest appear one row at a time, top first, each on its own timer
            // (building them all in one frame held the main thread ~0.7 s on an
            // A10X; a shared stage counter re-built every shown row at each step).
            if let recs = model.enrichment?.recommendations, !recs.isEmpty, on("related") {
                Staged(step: 1) { posterRow(key: "related", title: "Related", items: recs) }
            }
            if !model.cast.isEmpty, on("cast") { Staged(step: 2) { castRow } }
            if !model.previewSources.isEmpty, on("sources") { Staged(step: 3) { sourcesPreview } }
            if !productionCompanies.isEmpty, on("production") { Staged(step: 3) { production } }
            if !model.comments.isEmpty, on("comments") { Staged(step: 4) { commentsRow } }
            if on("about") { Staged(step: 4) { about } }
            if on("information") { Staged(step: 5) { information } }
        }
    }

    private var productionCompanies: [TMDBCompany] {
        (model.enrichment?.networks ?? []) + (model.enrichment?.companies ?? [])
    }

    // MARK: Episodes

    private var episodes: some View {
        let seasons = meta.seasons
        let season = seasons.contains(model.selectedSeason) ? model.selectedSeason : (seasons.first ?? 1)
        let eps = meta.episodes(season: season)
        let left = eps.filter { $0.hasAired && !watched.isWatched($0.id) }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons, id: \.self) { s in
                                Button(s == 0 ? "Specials" : "Season \(s)") {
                                    model.selectedSeason = s
                                    Task { await model.loadSeasonInfo(s) }
                                }
                                .buttonStyle(TextTabStyle(selected: s == season))
                                .modifier(TrackedFocus(id: "seasons-\(s)"))
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, Metrics.margin - 22)
                    }
                    .scrollClipDisabled()
                    // Leave room for the episode count and Mark Season Watched.
                    .frame(maxWidth: 1240, alignment: .leading)
                    .clipped()
                    .focusSection()
                } else {
                    Text(season == 0 ? "Specials" : "Season \(season)").textStyle(.sectionHeader).padding(.leading, Metrics.margin)
                }
                Spacer()
                if left > 0 { Text("\(left) episode\(left == 1 ? "" : "s") left").textStyle(.meta) }
                let allWatched = left == 0 && !eps.isEmpty
                Button(allWatched ? "Mark Season Unwatched" : "Mark Season Watched") {
                    watched.markSeasonWatched(meta: meta, season: season, watched: !allWatched)
                    toasts.show(allWatched ? "Season marked unwatched" : "Season marked watched", systemImage: "eye")
                }
                .buttonStyle(GlassCapsuleStyle(font: .system(size: 20, weight: .semibold), height: 44))
                .modifier(TrackedFocus(id: "seasons-mark"))
                .padding(.trailing, Metrics.margin)
            }
            FocusRow(rowKey: "episodes-\(season)", title: nil, items: eps, spacing: 40,
                     onFocus: { v, _ in model.loadEpisodeCast(v) }) { v, _ in
                let p = progress.progress(for: v.id)
                let isWatched = watched.isWatched(v.id)
                Button { playEpisode(v) } label: {
                    EpisodeCard(video: enriched(v), showBackdrop: meta.background, progress: p?.fraction, watched: isWatched,
                                spoiler: home.value.hideSpoilers && !isWatched && (p?.fraction ?? 0) < 0.05,
                                rating: model.rating(for: v), cast: model.episodeCast[v.id] ?? [])
                }
                .buttonStyle(BareFocusStyle())
                .onPlayPauseCommand {
                    model.rememberReturnFocus(video: v)
                    router.push(.streams(StreamsRequest(meta: meta, video: v, mode: .manual)))
                }
                .modifier(EpisodeHoldMenu(meta: meta, video: v, autoSelectOn: autoSelectOn, isWatched: isWatched))
            }
        }
    }

    /// Fill missing still/overview/air date/runtime from TMDB.
    private func enriched(_ v: MetaVideo) -> MetaVideo {
        guard let s = v.season, let e = v.episode, let info = model.episodeInfo[s]?[e] else { return v }
        var copy = v
        if copy.thumbnail == nil { copy.thumbnail = info.still }
        if (copy.overview ?? "").isEmpty { copy.overview = info.overview }
        if copy.released == nil { copy.released = info.airDate }
        if copy.runtime == nil { copy.runtime = info.runtime }
        if copy.title.isEmpty { copy.title = info.name }
        return copy
    }

    private func playEpisode(_ v: MetaVideo) {
        let p = progress.progress(for: v.id)
        let mode: StreamsMode = (p?.isResumable ?? false) ? .resume(fromStart: false) : .normal
        model.rememberReturnFocus(video: v)
        router.push(.streams(StreamsRequest(meta: meta, video: v, mode: mode)))
    }

    // MARK: Trailers

    @ViewBuilder private var trailers: some View {
        let list = trailerItems
        if !list.isEmpty {
            FocusRow(rowKey: "trailers", title: "Trailers", items: list, spacing: 40) { t, _ in
                Button { TrailerPresenter.shared.present(keys: [t.key]) } label: {
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(url: "https://img.youtube.com/vi/\(TrailerService.youtubeID(t.key) ?? t.key)/hqdefault.jpg", maxPixel: 600)
                            .frame(width: 400, height: 225)
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title).textStyle(.cardTitle).lineLimit(2)
                            Label("Play", systemImage: "play.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                        }
                        .padding(14)
                    }
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous))
                }
                .buttonStyle(FlatCardStyle(lift: 1.06))
            }
        }
    }

    struct TrailerItem: Identifiable { let id: String; let key: String; let title: String }

    private var trailerItems: [TrailerItem] {
        var out: [TrailerItem] = meta.trailers.map { TrailerItem(id: $0.source, key: $0.source, title: $0.title ?? $0.type ?? "Trailer") }
        for v in model.enrichment?.trailers ?? [] where !out.contains(where: { $0.key == v.key }) {
            out.append(TrailerItem(id: v.key, key: v.key, title: v.name))
        }
        return Array(out.prefix(10))
    }

    // MARK: Posters / cast

    private func posterRow(key: String, title: String, items: [MetaItem]) -> some View {
        FocusRow(rowKey: key, title: title, items: items) { item, _ in
            let actions = PlayActions(router: router)
            Button { actions.openDetail(item, siblings: items) } label: { PosterCard(meta: item, showsLabel: true) }
                .buttonStyle(FlatCardStyle())
                .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
        }
    }

    @ViewBuilder private var castRow: some View {
        let cast = model.cast
        if !cast.isEmpty {
            let people = cast.enumerated().map { CastItem(id: "\($0.offset)-\($0.element.name)", person: $0.element) }
            FocusRow(rowKey: "cast", title: "Cast & Crew", items: people, spacing: 40) { c, _ in
                Button {
                    if c.person.id > 0 { router.push(.person(c.person.id, c.person.name)) }
                } label: {
                    CastCircle(name: c.person.name, role: c.person.role, photo: c.person.photo, tint: .white.opacity(0.3))
                }
                .buttonStyle(BareFocusStyle())
            }
        }
    }

    struct CastItem: Identifiable { let id: String; let person: TMDBPerson }

    // MARK: Sources preview ("How to Watch")

    @ViewBuilder private var sourcesPreview: some View {
        if !model.previewSources.isEmpty {
            let target = ContinueWatchingBuilder.playTarget(meta: meta, watched: watched, progress: progress, home: home.value)?.0
            let cards: [SourcePreviewItem] = model.previewSources.map { .init(id: $0.id, entry: $0) } + [.init(id: "all", entry: nil)]
            FocusRow(rowKey: "sources", title: "Sources", items: cards, spacing: 30) { item, _ in
                Button {
                    router.push(.streams(StreamsRequest(meta: meta, video: target, mode: .manual)))
                } label: {
                    Group {
                        if let e = item.entry {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Text(e.traits.resolutionTag ?? "Link").font(.system(size: 22, weight: .bold))
                                    ForEach(e.badges, id: \.self) { OutlinedBadge(text: $0) }
                                    if e.isInstant { Text("⚡ Cached").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.positive) }
                                }
                                Text([e.sourceAddonName, e.fileSizeLabel].compactMap { $0 }.joined(separator: " · ")).textStyle(.cardBody).lineLimit(1)
                            }
                            .padding(.horizontal, 24)
                            .frame(width: 520, height: 120, alignment: .leading)
                        } else {
                            Label("See all sources", systemImage: "list.bullet").font(.system(size: 24, weight: .semibold))
                                .frame(width: 320, height: 120)
                        }
                    }
                }
                .buttonStyle(GlassCardStyle(radius: 24))
            }
        }
    }

    struct SourcePreviewItem: Identifiable { let id: String; let entry: StreamEntry? }

    // MARK: Production

    @ViewBuilder private var production: some View {
        let companies = productionCompanies
        if !companies.isEmpty {
            let items = companies.map { CompanyItem(id: "\($0.isNetwork ? "n" : "c")\($0.id)", company: $0) }
            FocusRow(rowKey: "production", title: "Production", items: items, spacing: 30) { c, _ in
                Button { router.push(.tmdbCompany(c.company.id, c.company.name, isNetwork: c.company.isNetwork)) } label: {
                    Group {
                        if let logo = c.company.logo {
                            RemoteImage(url: logo, maxPixel: 400, contentMode: .fit, placeholder: false)
                                .colorMultiply(.white)
                                .frame(width: 200, height: 70)
                        } else {
                            Text(c.company.name).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center).frame(width: 200, height: 70)
                        }
                    }
                    .padding(24)
                }
                .buttonStyle(GlassCardStyle(radius: 24))
            }
        }
    }

    struct CompanyItem: Identifiable { let id: String; let company: TMDBCompany }

    // MARK: Comments

    @ViewBuilder private var commentsRow: some View {
        if !model.comments.isEmpty {
            FocusRow(rowKey: "comments", title: "Comments", items: model.comments.map { CommentItem(id: String($0.id), c: $0) }, spacing: 30) { item, _ in
                Button {} label: { CommentCard(comment: item.c) }
                    .buttonStyle(GlassCardStyle(radius: 24))
            }
        }
    }

    struct CommentItem: Identifiable { let id: String; let c: TraktComment }

    // MARK: About / Information

    private var about: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCards) {
            Text("About").textStyle(.sectionHeader).padding(.horizontal, Metrics.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 30) {
                    Button { InfoPresenter.shared.present(meta) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(meta.name).font(.system(size: 28, weight: .bold))
                            Text(([meta.typeLabel] + meta.genres.prefix(3)).joined(separator: " · ")).textStyle(.meta)
                            Text(meta.description ?? "").textStyle(.cardBody).lineLimit(5)
                            Text("MORE").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.textSecondary)
                        }
                        .padding(28)
                        .frame(width: 720, height: 300, alignment: .topLeading)
                    }
                    .buttonStyle(GlassCardStyle())
                    .modifier(TrackedFocus(id: "about-0"))
                    if !model.ratings.isEmpty {
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Ratings").textStyle(.eyebrow)
                                ForEach(model.ratings.prefix(5)) { r in
                                    HStack {
                                        Image(systemName: r.symbol).frame(width: 30)
                                        Text(r.label).font(.system(size: 21))
                                        Spacer()
                                        Text(r.value).font(.system(size: 24, weight: .bold))
                                    }
                                }
                            }
                            .padding(28)
                            .frame(width: 420, height: 300, alignment: .topLeading)
                        }
                        .buttonStyle(GlassCardStyle())
                        .modifier(TrackedFocus(id: "about-1"))
                    }
                    if let cert = model.certification {
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(cert).font(.system(size: 64, weight: .heavy))
                                Text(ageSentence(cert)).textStyle(.cardBody).lineLimit(4)
                            }
                            .padding(28)
                            .frame(width: 340, height: 300, alignment: .topLeading)
                        }
                        .buttonStyle(GlassCardStyle())
                        .modifier(TrackedFocus(id: "about-2"))
                    }
                    if !model.advisories.isEmpty {
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Parental Guide").textStyle(.eyebrow)
                                ForEach(model.advisories) { a in
                                    HStack {
                                        Text(a.label).font(.system(size: 21))
                                        Spacer()
                                        Text(a.severity.label).font(.system(size: 21, weight: .semibold))
                                            .foregroundStyle(a.severity == .severe ? Palette.destructive : (a.severity == .moderate ? .orange : Palette.positive))
                                    }
                                }
                            }
                            .padding(28)
                            .frame(width: 440, height: 300, alignment: .topLeading)
                        }
                        .buttonStyle(GlassCardStyle())
                        .modifier(TrackedFocus(id: "about-3"))
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func ageSentence(_ cert: String) -> String {
        switch cert.uppercased() {
        case "G", "TV-Y", "TV-G": return "Suitable for all ages."
        case "PG", "TV-Y7", "TV-PG": return "Parental guidance suggested for younger viewers."
        case "PG-13", "TV-14": return "Parents strongly cautioned; some material may be inappropriate for under 13."
        case "R", "TV-MA", "NC-17": return "Restricted — intended for mature audiences."
        default: return "Content rating \(cert)."
        }
    }

    private var information: some View {
        let e = model.enrichment
        var info: [(String, String)] = []
        if let s = e?.companies.first?.name ?? e?.networks.first?.name { info.append(("Studio", s)) }
        if let d = meta.released ?? e?.releaseDate { info.append(("Released", DateParsing.mediumDisplay.string(from: d))) }
        else if let y = meta.year { info.append(("Released", y)) }
        if let r = model.runtimeMinutes { info.append(("Run Time", MetaItem.formatMinutes(r))) }
        if let c = model.certification { info.append(("Rated", c)) }
        if !model.advisories.isEmpty { info.append(("Content Advisories", model.advisories.map(\.label).joined(separator: ", "))) }
        if let c = model.country { info.append(("Region of Origin", c)) }
        var langs: [(String, String)] = []
        if let o = e?.originalLanguage { langs.append(("Original Audio", Locale.current.localizedString(forLanguageCode: o) ?? o)) }
        if let l = meta.language ?? e?.spokenLanguages.joined(separator: ", "), !l.isEmpty { langs.append(("Audio", l)) }
        return HStack(alignment: .top, spacing: 60) {
            Button {} label: { infoColumn("Information", info) }
                .buttonStyle(GlassCardStyle())
                .modifier(TrackedFocus(id: "information"))
            if !langs.isEmpty { infoColumn("Languages", langs) }
            infoColumn("Accessibility", [("CC", "Closed captions are available when the source or an add-on provides subtitles.")])
        }
        .padding(.horizontal, Metrics.margin)
        .focusSection()
    }

    private func infoColumn(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            ForEach(rows, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k).font(.system(size: 19)).foregroundStyle(Palette.textTertiary)
                    Text(v).font(.system(size: 21)).foregroundStyle(Palette.textPrimary).lineLimit(3)
                }
            }
        }
        .padding(28)
        .frame(width: 500, alignment: .topLeading)
    }
}

struct CommentCard: View {
    let comment: TraktComment
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(comment.user).font(.system(size: 21, weight: .semibold))
                Spacer()
                Label("\(comment.likes)", systemImage: "heart.fill").font(.system(size: 18)).foregroundStyle(Palette.textSecondary)
            }
            ZStack(alignment: .topLeading) {
                Text(comment.text).textStyle(.cardBody, color: focused ? Palette.focusInk : Palette.textSecondary).lineLimit(4)
                    .opacity(comment.spoiler && !focused && PerformanceProfile.isConstrained ? 0.12 : 1)
                    .blur(radius: comment.spoiler && !focused && !PerformanceProfile.isConstrained ? 8 : 0)
                if comment.spoiler && !focused {
                    Text("Spoiler — focus to reveal").font(.system(size: 20, weight: .semibold))
                }
            }
        }
        .foregroundStyle(focused ? Palette.focusInk : .white)
        .padding(24)
        .frame(width: 520, height: 200, alignment: .topLeading)
    }
}

/// Shows its content `step` beats after it appears. Each section owns its
/// timer, so a step builds just that section.
private struct Staged<Content: View>: View {
    let step: Int
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    private static var beat: UInt64 { PerformanceProfile.isConstrained ? 110_000_000 : 60_000_000 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if shown { content() }
        }
        .task {
            guard !shown else { return }
            try? await Task.sleep(nanoseconds: UInt64(step) * Self.beat)
            if !Task.isCancelled { shown = true }
        }
    }
}

/// Episode hold: Play Manually (auto-select on) · Mark as Watched / Unwatched.
struct EpisodeHoldMenu: ViewModifier {
    let meta: MetaItem
    let video: MetaVideo
    let autoSelectOn: Bool
    let isWatched: Bool
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var toasts: ToastCenter

    func body(content: Content) -> some View {
        StableContextMenu(content: content, key: "\(video.id)|\(isWatched)|\(autoSelectOn)") {
            if autoSelectOn {
                Button {
                    DetailModelCache.shared.model(for: meta).rememberReturnFocus(video: video)
                    router.push(.streams(StreamsRequest(meta: meta, video: video, mode: .manual)))
                } label: {
                    Label("Play Manually", systemImage: "list.bullet")
                }
            }
            Button {
                if isWatched { watched.markUnwatched(meta: meta, video: video) } else { watched.markWatched(meta: meta, video: video) }
                toasts.show(isWatched ? "Marked as Unwatched" : "Marked as Watched", systemImage: "eye")
            } label: {
                Label(isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: isWatched ? "eye.slash" : "eye")
            }
        }
    }
}

/// Focusables in the sections that aren't in a FocusRow (season tabs, Mark Season,
/// About cards), reported to the router so "Up from the top row" can be told
/// apart. Each tracks its own focus: one shared @FocusState on the sections made
/// every move between them rebuild every section (episodes included).
private struct TrackedFocus: ViewModifier {
    let id: String
    @FocusState private var focused: Bool
    @EnvironmentObject private var focusRouter: ContentFocusRouter
    @Environment(\.currentTab) private var tab

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, f in
                if f { focusRouter.noteFocus(tab: tab, rowID: id.hasPrefix("seasons") ? "seasons" : id, index: 0) }
            }
    }
}
