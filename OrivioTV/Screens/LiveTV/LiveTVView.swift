import SwiftUI
import AVFoundation

@MainActor
private final class LiveTVFocusModel: ObservableObject {
    @Published var channel: LiveChannel?
}

/// §16.11 Live TV: Library's two-pane grammar — a list on the left (Search,
/// Favorites, Recent, All Channels, Categories), a preview header for the
/// focused channel, then rows (All/Favorites) or a 5-column grid (a category).
/// Lets the shell know whether Live TV currently holds focus in its category
/// column or in the channel area, without guessing from a focus frame.
@MainActor
final class LiveTVMenuState: ObservableObject {
    static let shared = LiveTVMenuState()
    @Published var inList = false
}

struct LiveTVView: View {
    @ObservedObject private var model = LiveTVModel.shared
    @EnvironmentObject private var settings: LiveTVSettingsStore
    @EnvironmentObject private var favorites: LiveChannelFavorites
    @State private var section: Section = .all
    @State private var focus = LiveTVFocusModel()
    @State private var query = ""
    /// Typed text settles before the channel list and guide are searched: each
    /// keystroke used to rebuild the grid and scan every channel's listings.
    @State private var searchQuery = ""
    @State private var channelResults: [LiveChannel] = []
    @State private var channelResultCount = 0
    @State private var guideResults: [GuideSearchResult] = []
    @State private var sort: Sort = .standard
    @State private var showSort = false
    @State private var preview = LivePreviewController()
    @FocusState private var listFocus: Section?
    /// Cancels a pending "return to the list" from an earlier Back press.
    @State private var listLandingToken = UUID()
    /// False for the first beat after the page is re-enabled: the menu is the
    /// only focus target then, so the engine can't flash the first channel tile
    /// while the landing request is still in flight.
    @State private var contentFocusable = true
    /// A show picked from search results (the guide's card).
    @State private var showSelection: LiveGuideView.GuideSelection?
    @Environment(\.currentTab) private var tab
    @Environment(\.isEnabled) private var pageEnabled
    @EnvironmentObject private var focusRouter: ContentFocusRouter

    enum Section: Hashable {
        case search, favorites, recent, all, guide, group(String)
        var title: String {
            switch self {
            case .search: return "Search"
            case .favorites: return "Favorites"
            case .recent: return "Recent"
            case .all: return "All Channels"
            case .guide: return "Guide"
            case .group(let g): return g
            }
        }
        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .favorites: return "star.fill"
            case .recent: return "clock"
            case .all: return "square.grid.2x2"
            case .guide: return "calendar.day.timeline.left"
            case .group(let g): return LiveTVView.icon(for: g)
            }
        }
    }

    enum Sort: String, CaseIterable { case standard = "Default", az = "A–Z", za = "Z–A" }

    private struct GuideSearchResult {
        let channel: LiveChannel
        let programme: EPGProgramme
    }

    static func icon(for group: String) -> String {
        let g = group.lowercased()
        let map: [(String, String)] = [("news", "newspaper"), ("sport", "sportscourt"), ("movie", "film"), ("cinema", "film"),
                                       ("kid", "figure.and.child.holdinghands"), ("child", "figure.and.child.holdinghands"),
                                       ("music", "music.note"), ("docu", "books.vertical"), ("relig", "building.columns"),
                                       ("local", "mappin.and.ellipse"), ("entertain", "sparkles"), ("comedy", "theatermasks")]
        return map.first { g.contains($0.0) }?.1 ?? "dot.radiowaves.left.and.right"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 50) {
            list.frame(width: 330)
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .disabled(!contentFocusable)
        }
        .padding(.leading, Metrics.margin)
        .padding(.top, 120)
        .pageFrame()
        // The page's first focus target is its menu, so closing the app sidebar
        // never flashes the first channel tile before the landing request runs.
        .defaultFocus($listFocus, section, priority: .userInitiated)
        .task { await model.loadIfNeeded() }
        #if DEBUG
        .onAppear {
            if CommandLine.arguments.contains("-liveGuide") { section = .guide; listFocus = .guide }
            if let i = CommandLine.arguments.firstIndex(of: "-liveSearch"), i + 1 < CommandLine.arguments.count {
                section = .search; listFocus = .search; query = CommandLine.arguments[i + 1]
            }
        }
        .task {
            // `-reminderTest`: a reminder for a made-up programme starting in 30 s.
            guard CommandLine.arguments.contains("-reminderTest") else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let c = model.channels.first else { return }
            let start = Date().addingTimeInterval(30)
            GuideReminders.shared.toggle(c, EPGProgramme(start: start, end: start.addingTimeInterval(1800), title: "Reminder Test Show", desc: nil))
        }
        .task {
            // `-catchupTest`: play yesterday's programme on the first archive channel, no card.
            guard CommandLine.arguments.contains("-catchupTest") else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let c = model.channels.first(where: { ($0.archiveDays ?? 0) > 0 }) else { return }
            let t = Date().addingTimeInterval(-86400)
            guard let p = EPGGuide.shared.programmes(for: c, from: t, to: t.addingTimeInterval(3600)).first else { return }
            _ = await LivePlayback.playCatchup(c, p)
        }
        #endif
        .onChange(of: listFocus) { _, f in
            if let f { section = f }
            LiveTVMenuState.shared.inList = f != nil
            // The menu has focus again: the channel area may take part in
            // navigation without stealing it.
            if f != nil { contentFocusable = true }
        }
        .onChange(of: pageEnabled) { _, on in
            guard on else { contentFocusable = false; return }
            // The app sidebar just closed (or the tab came forward). Keep the
            // channel area out of the focus search until the menu lands.
            contentFocusable = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { contentFocusable = true }
        }
        // The shell asks the page to return to its menu instead of opening the
        // app sidebar when Left/Back is pressed inside the channel area.
        .onReceive(NotificationCenter.default.publisher(for: .orivioReturnToTabMenu)) { _ in
            guard tab == .liveTV, pageEnabled else { return }
            landOnList(section)
        }
        // Leaving the sidebar (or landing on this tab) used to leave focus to
        // the first channel tile, so the next Back looked like a bounce before
        // the menu opened. The page's own menu is the landing target.
        .onChange(of: focusRouter.landing) { _, l in
            guard let l, l.tab == nil || l.tab == tab, pageEnabled else { return }
            landOnList(section, delay: 0)
        }
        .onAppear {
            LiveTVMenuState.shared.inList = listFocus != nil
            if listFocus == nil, pageEnabled { landOnList(section, delay: 0) }
        }
        .onDisappear {
            LiveTVMenuState.shared.inList = false
            preview.stop()
        }
        .fullScreenCover(item: $showSelection) { s in
            GuideProgrammeCard(selection: s, now: Date(),
                               watch: { showSelection = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { watch(s.channel) } },
                               catchup: { p in
                                   showSelection = nil
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                       Task { if let err = await LivePlayback.playCatchup(s.channel, p) { ToastCenter.shared.show(err, systemImage: "exclamationmark.triangle.fill") } }
                                   }
                               },
                               close: { showSelection = nil })
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showSort) {
            OptionPickerSheet(title: "Sort", options: Sort.allCases.map { ($0.rawValue, $0.rawValue) }, selected: sort.rawValue) { v in
                sort = Sort(rawValue: v) ?? .standard
                showSort = false
            }
        }
    }

    // MARK: List

    /// Put focus back in the category column. A request made inside the focus
    /// update that just failed is dropped, so ask once after it settles. Don't
    /// clear the binding first: that hands focus to the first channel tile for
    /// a frame, then the next request pulls it back — the visible bounce.
    private func landOnList(_ target: Section, delay: TimeInterval = 0.05) {
        let token = UUID()
        listLandingToken = token
        let apply = {
            guard listLandingToken == token, tab == .liveTV, pageEnabled else { return }
            if listFocus != target { listFocus = target }
            // Only retry if the engine cleared the request (a section swap can
            // do that); a refused request keeps the value, so retrying blindly
            // would restart the bounce.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard listLandingToken == token, tab == .liveTV, pageEnabled else { return }
                if listFocus == nil { listFocus = target }
            }
        }
        if delay == 0 { apply() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply) }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([Section.search, .favorites, .recent, .all, .guide], id: \.self) { listRow($0) }
                if !model.groups.isEmpty {
                    Text("Categories").textStyle(.eyebrow).padding(.leading, 22).padding(.top, 24)
                    ForEach(model.groups.prefix(60), id: \.self) { listRow(.group($0)) }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .focusSection()
    }

    private func listRow(_ s: Section) -> some View {
        Button { } label: {
            HStack(spacing: 16) {
                Image(systemName: s.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.14)))
                Text(s.title).font(.system(size: 25, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(FocusCapsuleRowStyle(selected: section == s, height: 60))
        .focused($listFocus, equals: s)
    }

    // MARK: Content

    private func sorted(_ list: [LiveChannel]) -> [LiveChannel] {
        switch sort {
        case .standard: return list
        case .az: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .za: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    private var favoriteChannels: [LiveChannel] { favorites.ids.compactMap { model.channel($0) } }
    private var recentChannels: [LiveChannel] { settings.value.recentChannelIDs.compactMap { model.channel($0) } }

    @ViewBuilder private var content: some View {
        if model.channels.isEmpty {
            VStack(spacing: 20) {
                if model.loading {
                    ProgressView().scaleEffect(1.4)
                    Text("Loading channels…").textStyle(.body, color: Palette.textSecondary)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 54)).opacity(0.7)
                    Text("No channels").font(.system(size: 32, weight: .bold))
                    Text(model.error ?? "Add a playlist or IPTV login in Settings → Content.").textStyle(.body, color: Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await model.reload() } }.buttonStyle(PrimaryCapsuleStyle(minWidth: 220))
                }
            }
            .padding(50)
            .frame(width: 900)
            .glassCard()
            .frame(maxWidth: .infinity)
            .padding(.top, 140)
            .padding(.trailing, Metrics.margin)
        } else if section == .guide {
            // The guide brings its own header and scrolling (rows share one time window).
            LiveGuideView(watch: { c, list in watch(c, list: list) })
                .onAppear { preview.stop() }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    LiveHeader(focus: focus, preview: preview, model: model, favorites: favorites, settings: settings,
                               watch: { c in watch(c) }, toggleHome: { c in toggleHome(c) })
                    switch section {
                    case .search: searchView
                    case .favorites: grid(favoriteChannels, empty: "Hold a channel to add it to your favorites.")
                    case .recent: grid(recentChannels, empty: "Channels you watch appear here.")
                    case .all, .guide: rows
                    case .group(let g): grid(sorted(model.channels(in: g)), empty: "No channels in \(g).")
                    }
                }
                .padding(.trailing, Metrics.margin)
                .padding(.bottom, 100)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    // MARK: Header (focused channel; muted live preview after 1.2 s)

    /// Owns the focused-channel/EPG updates so moving through tiles does not
    /// invalidate the whole Live TV tab (list, rows and grids).
    private struct LiveHeader: View {
        @ObservedObject var focus: LiveTVFocusModel
        @ObservedObject var preview: LivePreviewController
        @ObservedObject var model: LiveTVModel
        @ObservedObject var favorites: LiveChannelFavorites
        @ObservedObject var settings: LiveTVSettingsStore
        let watch: (LiveChannel) -> Void
        let toggleHome: (LiveChannel) -> Void

        private var favoriteChannels: [LiveChannel] { favorites.ids.compactMap { model.channel($0) } }
        private var channel: LiveChannel? { focus.channel ?? favoriteChannels.first ?? model.channels.first }

        var body: some View {
            let c = channel
            HStack(spacing: 40) {
                ZStack {
                    ArtFieldMini(url: c?.logo)
                    if let c {
                        RemoteImage(url: c.logo, maxPixel: PerformanceProfile.isConstrained ? 360 : 600, contentMode: .fit, placeholder: false)
                            .frame(maxWidth: 360, maxHeight: 200)
                    }
                    if preview.isPlaying, preview.channelID == c?.id {
                        BackgroundVideoView(player: preview.player, gravity: .resizeAspectFill).transition(.opacity)
                    }
                }
                .frame(width: 720, height: 405)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.glassCardRadius, style: .continuous))
                .animation(.easeInOut(duration: 0.4), value: preview.isPlaying)
                VStack(alignment: .leading, spacing: 14) {
                    Text(c?.name ?? "").font(.system(size: 40, weight: .bold)).lineLimit(2)
                    HStack(spacing: 12) {
                        Text(c?.group ?? "").textStyle(.meta)
                        LivePill()
                    }
                    if preview.epg == nil, let c, case let nn = EPGGuide.shared.nowNext(for: c), nn.now != nil || nn.next != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let now = nn.now { Text("Now: \(now.title)").textStyle(.body) }
                            if let next = nn.next {
                                Text("Next: \(next.title) · \(PlayerTransport.wall.string(from: next.start))").textStyle(.cardBody)
                            }
                        }
                    } else if let epg = preview.epg, preview.channelID == c?.id {
                        VStack(alignment: .leading, spacing: 4) {
                            if let now = epg.now { Text("Now: \(now)").textStyle(.body) }
                            if let next = epg.next {
                                Text("Next: \(next)" + (epg.nextStart.map { " · \(PlayerTransport.wall.string(from: $0))" } ?? ""))
                                    .textStyle(.cardBody)
                            }
                        }
                    }
                    Spacer().frame(height: 10)
                    if let c {
                        HStack(spacing: 16) {
                            Button { watch(c) } label: { Label("Watch", systemImage: "play.fill") }
                                .buttonStyle(PrimaryCapsuleStyle(minWidth: 200))
                            Button { favorites.toggle(c.id) } label: {
                                Label(favorites.contains(c.id) ? "Favorited" : "Favorite", systemImage: favorites.contains(c.id) ? "star.fill" : "star")
                                    .lineLimit(1).fixedSize()
                            }
                            .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                            Button { toggleHome(c) } label: {
                                Image(systemName: settings.value.homeChannelIDs.contains(c.id) ? "house.fill" : "house")
                            }
                            .buttonStyle(CircleButtonStyle())
                        }
                        .focusSection()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 420)
            .onChange(of: focus.channel) { _, c in
                preview.focusChanged(c, enabled: settings.value.livePreview)
            }
        }
    }

    // MARK: Views

    private var rows: some View {
        let favorites = favoriteChannels
        let recents = recentChannels
        return LazyVStack(alignment: .leading, spacing: 40) {
            if !favorites.isEmpty { channelRow("Favorites", favorites) }
            if !recents.isEmpty { channelRow("Recent", recents) }
            ForEach(model.groups.prefix(30), id: \.self) { g in
                channelRow(g, Array(sorted(model.channels(in: g)).prefix(20)), seeAll: g)
            }
        }
    }

    private func channelRow(_ title: String, _ list: [LiveChannel], seeAll: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCards) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                if let seeAll {
                    Button { section = .group(seeAll); listFocus = .group(seeAll) } label: { Label("See All", systemImage: "chevron.right").labelStyle(TrailingIcon()) }
                        .buttonStyle(GlassCapsuleStyle())
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) {
                    ForEach(list) { tile($0) }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
    }

    private func grid(_ list: [LiveChannel], empty: String) -> some View {
        Group {
            if list.isEmpty {
                Text(empty).textStyle(.body, color: Palette.textSecondary).padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("\(list.count) channel\(list.count == 1 ? "" : "s")").textStyle(.meta)
                        Spacer()
                        Button { showSort = true } label: { Label("Sort: \(sort.rawValue)", systemImage: "chevron.down").labelStyle(TrailingIcon()) }
                            .buttonStyle(GlassCapsuleStyle())
                    }
                    // Its own section: Down from the search field lands on Sort
                    // first, then Down enters the grid. With very few results the
                    // spatial engine otherwise skipped straight past it.
                    .focusSection()
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 36), count: 5), alignment: .leading, spacing: 50) {
                        ForEach(list) { tile($0, width: 240) }
                    }
                    .focusSection()
                }
            }
        }
    }

    private var searchView: some View {
        VStack(alignment: .leading, spacing: 24) {
            TextField("Search channels", text: $query)
                .font(.system(size: 30))
                .autocorrectionDisabled()
            if channelResultCount > 200 {
                Text("Showing the first 200 of \(channelResultCount) channels — keep typing to narrow the search.").textStyle(.cardBody)
            }
            if !channelResults.isEmpty || guideResults.isEmpty {
                grid(channelResults, empty: searchQuery.isEmpty ? "Type a channel or show name." : "No channels match “\(searchQuery)”.")
            }
            if !guideResults.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "On the Guide")
                    ForEach(guideResults, id: \.programme.id) { r in showRow(r.channel, r.programme) }
                }
                .focusSection()
            }
        }
        .task(id: query) {
            let raw = query.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else {
                searchQuery = ""
                channelResults = []
                channelResultCount = 0
                guideResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searchQuery = raw
            let q = raw.lowercased()
            let all = model.channels.filter { $0.name.lowercased().contains(q) || $0.group.lowercased().contains(q) }
            guard !Task.isCancelled else { return }
            channelResultCount = all.count
            channelResults = Array(all.prefix(200))
            guideResults = EPGGuide.shared.search(raw, in: model.channels, limit: 40)
                .map { GuideSearchResult(channel: $0.channel, programme: $0.programme) }
        }
    }

    private func showRow(_ c: LiveChannel, _ p: EPGProgramme) -> some View {
        let now = Date()
        let when: String = p.isLive(at: now) ? "On now"
            : (Calendar.current.isDateInToday(p.start) ? "Today" : (Calendar.current.isDateInTomorrow(p.start) ? "Tomorrow" : p.start.formatted(.dateTime.weekday(.abbreviated).day())))
        return Button { showSelection = LiveGuideView.GuideSelection(channel: c, programme: p) } label: {
            HStack(spacing: 22) {
                Text(when).font(.system(size: 20, weight: .bold)).frame(width: 130, alignment: .leading)
                    .foregroundStyle(p.isLive(at: now) ? Palette.live : Palette.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    Text("\(c.name) · \(PlayerTransport.wall.string(from: p.start)) – \(PlayerTransport.wall.string(from: p.end))")
                        .font(.system(size: 20)).opacity(0.65).lineLimit(1)
                }
                Spacer(minLength: 0)
                if GuideReminders.shared.has(c.id, p) { Image(systemName: "bell.fill") }
            }
            .padding(.horizontal, 24)
            .frame(height: 84)
        }
        .buttonStyle(FocusCapsuleRowStyle(height: 84))
    }

    private func tile(_ c: LiveChannel, width: CGFloat = 300) -> some View {
        Button { watch(c) } label: {
            ChannelTile(name: c.name, logo: c.logo, favorite: favorites.contains(c.id), width: width, height: width * 170 / 300)
        }
        .buttonStyle(FlatCardStyle())
        .modifier(ChannelFocus(channel: c, focus: focus))
        .contextMenu {
            Button { favorites.toggle(c.id) } label: {
                Label(favorites.contains(c.id) ? "Remove from Favorites" : "Favorite", systemImage: favorites.contains(c.id) ? "star.slash" : "star")
            }
            Button { toggleHome(c) } label: {
                Label(settings.value.homeChannelIDs.contains(c.id) ? "Remove from Home Page" : "Add to Home Page", systemImage: "house")
            }
        }
    }

    private func toggleHome(_ c: LiveChannel) {
        let added = settings.toggleHome(c.id)
        ToastCenter.shared.show(added ? "Added to Home" : "Removed from Home")
    }

    /// `list`: what channel up/down moves through in the player (default: the
    /// section on screen — Favorites, Recent, a category — else the channel's category).
    private func watch(_ c: LiveChannel, list: [LiveChannel]? = nil) {
        preview.stop()
        let channels: [LiveChannel]? = list ?? {
            switch section {
            case .favorites: return favoriteChannels
            case .recent: return recentChannels
            case .group(let g): return model.channels(in: g)
            default: return nil
            }
        }()
        Task {
            if let err = await LivePlayback.play(c, list: channels) { ToastCenter.shared.show(err, systemImage: "exclamationmark.triangle.fill") }
        }
    }
}

private struct ChannelFocus: ViewModifier {
    let channel: LiveChannel
    let focus: LiveTVFocusModel
    @FocusState private var isFocused: Bool
    func body(content: Content) -> some View {
        content.focused($isFocused).onChange(of: isFocused) { _, f in if f { focus.channel = channel } }
    }
}

/// One muted HLS preview at a time (native engine only), started after 1.2 s
/// of focus and stopped the moment focus moves or the tab disappears. Also
/// fetches Now/Next for Xtream channels.
@MainActor
final class LivePreviewController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var channelID: String?
    @Published private(set) var epg: Xtream.EPG?
    private var task: Task<Void, Never>?
    private var observation: NSKeyValueObservation?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        observation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            DispatchQueue.main.async { self?.isPlaying = p.timeControlStatus == .playing }
        }
    }

    func focusChanged(_ c: LiveChannel?, enabled: Bool) {
        task?.cancel()
        stopPlayback()
        epg = nil
        channelID = c?.id
        guard let c else { return }
        task = Task { [weak self] in
            // Let the focus settle before touching the network. Moving across a
            // category used to fire one Xtream EPG request per intermediate
            // channel even when the inline preview was off.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if enabled, let sid = c.xtreamID {
                let s = AppStores.shared.liveTV.value
                let e = await Xtream.epg(server: s.xtreamServer, user: s.xtreamUsername, pass: s.xtreamPassword, streamID: sid)
                if !Task.isCancelled { self?.epg = e }
            }
            guard enabled, !c.drm, let u = c.url, u.lowercased().contains(".m3u8"), let url = URL(string: u),
                  !PlayerPresenter.shared.isPresenting else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            let asset = AVURLAsset(url: url, options: c.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": c.headers])
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            self.player.play()
        }
    }

    private func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }

    func stop() {
        task?.cancel()
        stopPlayback()
    }
}

/// Home's "Live TV" row: the channels added with "Add to Home Page".
struct HomeLiveChannelsRow: View {
    let focus: HomeFocusModel
    @ObservedObject private var model = LiveTVModel.shared
    @EnvironmentObject private var settings: LiveTVSettingsStore

    private struct Item: Identifiable { let channel: LiveChannel; var id: String { channel.id } }

    var body: some View {
        let items = settings.value.homeChannelIDs.compactMap { model.channel($0) }.map(Item.init)
        FocusRow(rowKey: "live", title: "Live TV", items: items, spacing: 36,
                 onFocus: { _, _ in
                     focus.focusedRowKey = "live"
                     if !focus.inRows { withAnimation(Motion.pageScroll) { focus.inRows = true } }
                 }) { item, _ in
            Button {
                Task { if let err = await LivePlayback.play(item.channel) { ToastCenter.shared.show(err, systemImage: "exclamationmark.triangle.fill") } }
            } label: {
                ChannelTile(name: item.channel.name, logo: item.channel.logo)
            }
            .buttonStyle(FlatCardStyle())
        }
        .task { await model.loadIfNeeded() }
    }
}
