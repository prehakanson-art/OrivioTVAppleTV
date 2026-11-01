import SwiftUI

/// The Sources page: fan-out results grouped by add-on and resolution tier.
/// Auto flows cover it with a branded loading screen ("Finding the best source…").
struct StreamsView: View {
    let request: StreamsRequest

    @StateObject private var search: StreamSearch
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var badgeStore: StreamBadgeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pageWidth) private var pageWidth
    @Environment(\.railBleed) private var bleed

    @State private var addonFilter: String?
    @State private var resolving: StreamEntry?
    @State private var resolvingStatus = ""
    @State private var resolveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var autoActive = false
    @State private var autoStatus = "Finding the best source…"
    @State private var autoTried = Set<String>()
    @State private var autoAttempts = 0
    @State private var didAutoStart = false
    @State private var launched = false

    init(request: StreamsRequest) {
        self.request = request
        _search = StateObject(wrappedValue: StreamSearch(meta: request.meta, video: request.video))
    }

    private var meta: MetaItem { request.meta }
    private var titleKey: String { request.video?.id ?? meta.id }
    private var settings: PlayerSettings { playerSettings.value }

    /// Whether this visit runs the automatic chain.
    private var autoMode: Bool {
        #if DEBUG
        // `-noAutoPlay`: device tests never start playback on the user's titles.
        if CommandLine.arguments.contains("-noAutoPlay") { return false }
        #endif
        switch request.mode {
        case .manual: return false
        case .infuse, .shuffle, .resume: return true
        case .normal, .fromStart:
            return profiles.active.autoLink.enabled || settings.autoPlayBestSource || settings.reuseLastLink
        }
    }

    private var context: AutoSelect.Context {
        let p = progress.progress(for: titleKey)
        var sig: StreamSignature?
        if case .resume = request.mode { sig = p?.signature }
        return AutoSelect.Context(titleKey: titleKey, autoLink: profiles.active.autoLink, settings: settings,
                                  resumeSignature: sig, lastLink: progress.lastLink(for: titleKey))
    }

    var body: some View {
        ZStack {
            backdrop
            if autoActive {
                autoLoading
            } else {
                list
            }
            if let entry = resolving, !autoActive {
                resolvingOverlay(entry)
            }
        }
        .pageFrame()
        .ignoresSafeArea()
        .onAppear(perform: start)
        .onDisappear {
            search.cancel()
            resolveTask?.cancel()
        }
        .onExitCommand {
            if resolving != nil || autoActive {
                cancelResolve()
                withAnimation { autoActive = false }
            } else {
                router.pop()
            }
        }
        .alert("Couldn't play", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onChange(of: presenter.isPresenting) { _, open in
            let closed = !open
            // Coming back from the player: leave auto flows, show the list.
            if closed, launched { autoActive = false }
        }
    }

    /// Pinned to the page canvas. A fill image left to size itself takes the
    /// art's own aspect: a wide backdrop made the page wider than the screen
    /// and the centred list slid right, its right half cut off.
    private var backdrop: some View {
        ZStack {
            ArtField(imageURL: meta.background ?? meta.poster)
            RemoteImage(url: meta.background, maxPixel: ImageSize.backdrop, placeholder: false)
                .opacity(0.5)
            LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: pageWidth + bleed, height: 1080)
        .clipped()
        .padding(.leading, -bleed)
        .frame(width: pageWidth, height: 1080, alignment: .trailing)
    }

    // MARK: Start / auto chain

    private func start() {
        guard !didAutoStart else { return }
        didAutoStart = true
        if autoMode {
            autoActive = true
            // 2. Reuse last link (no scrape needed).
            if let last = AutoSelect.reuseLastLink(ctx: context) {
                let entry = StreamEntry(stream: last.stream, addonName: last.addonName, addonID: last.addonName, index: 0)
                autoTried.insert(entry.rejectionKey)
                autoStatus = "Reusing your last link…"
                play(entry, auto: true, fallback: { runFinalPickIfReady(force: true) })
            }
            search.onEntries = { _ in tryAutoLinkEarly() }
        }
        search.start()
    }

    /// 1. Auto Link Selector early pick — as soon as a qualifying link arrives.
    private func tryAutoLinkEarly() {
        guard autoActive, resolving == nil, !launched else { return }
        if let pick = AutoSelect.autoLinkPick(search.entries.filter { !autoTried.contains($0.rejectionKey) }, ctx: context, final: false) {
            autoTried.insert(pick.rejectionKey)
            play(pick, auto: true, fallback: { runFinalPickIfReady(force: true) })
        }
    }

    /// 3/4 once the search completes (or a candidate failed).
    private func runFinalPickIfReady(force: Bool = false) {
        guard autoActive, !launched, resolving == nil, search.isComplete || force else { return }
        let pool = search.entries.filter { !autoTried.contains($0.rejectionKey) }
        var candidates: [StreamEntry] = []
        if let a = AutoSelect.autoLinkPick(pool, ctx: context, final: true) { candidates.append(a) }
        candidates += AutoSelect.finalPick(pool, ctx: context).filter { c in !candidates.contains(c) }
        if candidates.isEmpty, case .resume = request.mode {
            candidates = AutoSelect.ranked(pool.filter { AutoSelect.eligible($0, ctx: context) }, ctx: context)
        }
        if candidates.isEmpty, request.mode == .shuffle || request.mode == .infuse {
            candidates = AutoSelect.ranked(pool.filter { AutoSelect.eligible($0, ctx: context) }, ctx: context)
        }
        guard let next = candidates.first, autoAttempts < 4, autoTried.count < 25 else {
            if search.isComplete {
                // Nothing qualifies: show the list.
                withAnimation { autoActive = false }
            }
            return
        }
        autoTried.insert(next.rejectionKey)
        play(next, auto: true) { runFinalPickIfReady(force: true) }
    }

    // MARK: Play

    private func play(_ entry: StreamEntry, auto: Bool, fallback: (() -> Void)? = nil) {
        guard !launched else { return }
        if entry.stream.isExternal, let ext = entry.stream.externalUrl, let url = URL(string: ext) {
            UIApplication.shared.open(url)
            return
        }
        resolving = entry
        resolvingStatus = entry.stream.isTorrent ? "Resolving…" : "Opening…"
        if auto { autoAttempts += 1; autoStatus = "Finding the best source…" }
        let timeout: TimeInterval = auto ? 20 : 60
        resolveTask = Task {
            do {
                let resolved = try await StreamResolver.resolve(entry, video: request.video, timeout: timeout) { s in
                    resolvingStatus = s
                    if auto { autoStatus = s }
                }
                guard !Task.isCancelled else { return }
                resolving = nil
                launch(entry, resolved: resolved)
            } catch is CancellationError {
                resolving = nil
            } catch {
                resolving = nil
                guard !Task.isCancelled else { return }
                if auto {
                    // Try the next candidate instead of alerting.
                    if let fallback { fallback() } else { runFinalPickIfReady(force: true) }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelResolve() {
        resolveTask?.cancel()
        resolving = nil
    }

    private func launch(_ entry: StreamEntry, resolved: ResolvedStream) {
        let stores = AppStores.shared
        // Remember the link (Reuse last link) and its "look" (resume format match).
        let link = LastLink(stream: entry.stream, addonName: entry.addonName, rejectionKey: entry.rejectionKey, savedAt: Date())
        stores.progress.rememberLink(link, signature: entry.signature, for: titleKey)

        if request.mode == .infuse || settings.engine == .external {
            let app: ExternalPlayerApp = request.mode == .infuse ? .infuse : settings.externalPlayer
            Task {
                var sub: URL?
                if settings.externalForwardSubtitles { sub = await SubtitleFetcher.preferredSubtitleURL(meta: meta, video: request.video) }
                if ExternalPlayback.launch(app, meta: meta, video: request.video, url: resolved.url, subtitles: sub) {
                    launched = true
                    autoActive = false
                } else {
                    errorMessage = "\(app.label) isn't installed."
                }
            }
            return
        }

        var resume: Double?
        switch request.mode {
        case .fromStart, .resume(fromStart: true), .shuffle: resume = nil
        default:
            if let p = progress.progress(for: titleKey), p.isResumable { resume = p.position }
        }
        launched = true
        presenter.present(PlaybackRequest(meta: meta, video: request.video, entry: entry, allEntries: search.entries,
                                          resumePosition: resume, shuffle: request.mode == .shuffle,
                                          url: resolved.url, headers: resolved.headers))
        // Back from the player returns to the page before Sources when auto-launched.
        if autoActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { autoActive = false; router.pop() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { launched = false }
        }
    }

    // MARK: Views

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 420, height: 120), fallbackStyle: .pageTitle)
            if let v = request.video { Text(v.episodeLine).textStyle(.meta) }
            if !search.isComplete {
                Text("Searching addons \(search.answeredCount)/\(search.states.count)").textStyle(.caption)
            }
        }
    }

    private var groups: [SourceGroup] {
        let entries = addonFilter.map { f in search.entries.filter { $0.addonName == f } } ?? search.entries
        return SourceFilters.group(entries, settings: settings, addonOrder: addons.addons.map(\.displayName))
    }

    #if DEBUG
    static let debugFullNames = CommandLine.arguments.contains("-fullNames")
    #else
    static let debugFullNames = false
    #endif

    /// Only the first link's focus is tracked (a page-wide focus state redrew the
    /// whole list on every move): it's where focus goes when the list appears.
    @FocusState private var firstLinkFocused: Bool

    /// Focus has landed on the first link once (after that the viewer drives).
    @State private var landedOnFirst = false

    /// Put focus on the first link when the list first has one — the top of
    /// the list. The old check only stepped in when focus looked "adrift" (no
    /// frame or the 1 pt loading anchor), and after a push it often still read
    /// the previous page's frame: nothing on the list was focused and Down did
    /// nothing. A request made as rows appear can be refused, so it is asked
    /// again briefly.
    private func focusFirstLink() {
        guard !landedOnFirst else { return }
        for delay in [0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !landedOnFirst else { return }
                // A link row is ≥ 96 pt tall and 1200 wide: focus is really on one.
                if let f = FocusProbe.focusedFrame, f.width > 600, f.height > 60, firstLinkFocused {
                    landedOnFirst = true
                    return
                }
                // A refused request keeps its value: clear it, then ask.
                firstLinkFocused = false
                DispatchQueue.main.async { firstLinkFocused = true }
            }
        }
    }

    private var list: some View {
        let groups = self.groups
        let firstID = groups.first?.tiers.first?.entries.first?.id
        let addonNames = Array(Set(search.entries.map(\.addonName))).sorted()
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                header
                if addonNames.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button("All") { addonFilter = nil }.buttonStyle(GlassCapsuleStyle(selected: addonFilter == nil))
                            ForEach(addonNames, id: \.self) { n in
                                Button(n) { addonFilter = n }.buttonStyle(GlassCapsuleStyle(selected: addonFilter == n))
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
                if search.isComplete && search.entries.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { g in groupView(g, firstID: firstID) }
                    statusRows
                }
            }
            .frame(width: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .onChange(of: firstID) { _, id in if id != nil { focusFirstLink() } }
        .onChange(of: search.isComplete) { _, done in if done { focusFirstLink() } }
        .onAppear { if firstID != nil { focusFirstLink() } }
    }

    private func groupView(_ g: SourceGroup, firstID: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(g.addonName).eyebrow()
            ForEach(g.tiers) { tier in
                if !tier.label.isEmpty { Text(tier.label).textStyle(.meta).padding(.top, 4) }
                ForEach(tier.entries) { e in
                    Button { play(e, auto: false) } label: {
                        SourceRow(entry: e, fullName: home.value.fullStreamNames || Self.debugFullNames,
                                  badges: badgeStore.badges(for: e), badgeScale: badgeStore.size.scale)
                    }
                        .buttonStyle(SourceRowStyle())
                        .modifier(FirstLinkFocus(isFirst: e.id == firstID, focused: $firstLinkFocused))
                        .modifier(SourceHoldMenu(entry: e) { infuse(e) })
                }
            }
            if let state = search.states.first(where: { $0.name == g.addonName }), state.status == .searching {
                Text("Searching…").textStyle(.caption, color: Palette.textTertiary)
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        let pending = search.states.filter { st in st.status == .searching && !search.entries.contains(where: { $0.addonName == st.name }) }
        let failed = search.states.compactMap { s -> (String, String)? in if case .failed(let r) = s.status { return (s.name, r) }; return nil }
        if !pending.isEmpty || !failed.isEmpty || !search.skipped.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending) { s in Text("\(s.name) — Searching…").textStyle(.caption, color: Palette.textTertiary) }
                ForEach(failed, id: \.0) { n, r in Text("\(n) — Not working — \(r)").textStyle(.caption, color: Palette.textTertiary) }
                if !search.skipped.isEmpty {
                    Text("Skipped (don't serve this title): " + search.skipped.joined(separator: ", ")).textStyle(.caption, color: Palette.textTertiary)
                }
            }
            .padding(.top, 10)
        }
        if !search.isComplete { FocusAnchor() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("No sources found").font(.system(size: 34, weight: .bold))
            Text("None of your installed addons returned a playable link for this title.").textStyle(.body, color: Palette.textSecondary)
            ForEach(search.states) { s in
                if case .failed(let r) = s.status { Text("\(s.name) — \(r)").textStyle(.caption) }
                else if case .done(0) = s.status { Text("\(s.name) — no links").textStyle(.caption) }
            }
            Button("Try Again") { search.start() }.buttonStyle(PrimaryCapsuleStyle(minWidth: 220))
        }
        .padding(40)
        .glassCard(radius: Metrics.popoverRadius)
    }

    private var autoLoading: some View {
        ZStack {
            Group {
                if PerformanceProfile.isConstrained {
                    RemoteImage(url: meta.background ?? meta.poster, maxPixel: 800, placeholder: false)
                        .opacity(0.6)
                } else {
                    RemoteImage(url: meta.background ?? meta.poster, maxPixel: 800, placeholder: false)
                        .blur(radius: 40).opacity(0.6)
                }
            }
            // Same as the backdrop: never let the art size the page.
            .frame(width: pageWidth, height: 1080)
            .clipped()
            Color.black.opacity(0.45)
            VStack(spacing: 36) {
                LogoOrTitle(logo: meta.logo, title: meta.name, maxSize: CGSize(width: 520, height: 200), alignment: .center)
                if let v = request.video { Text(v.episodeLine).textStyle(.meta) }
                IndeterminateCapsule().frame(width: 320, height: 6)
                Text(autoStatus).textStyle(.meta)
                Text("Press Back to choose a source").textStyle(.caption, color: Palette.textTertiary)
            }
            FocusAnchor()
        }
        .onChange(of: search.isComplete) { _, done in if done { runFinalPickIfReady() } }
    }

    private func resolvingOverlay(_ e: StreamEntry) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 22) {
                ProgressView().scaleEffect(1.4)
                Text(resolvingStatus).font(.system(size: 30, weight: .semibold))
                Text(e.displayName).textStyle(.caption).lineLimit(1).frame(maxWidth: 900)
                Text("Press Back to cancel and pick another source").textStyle(.caption, color: Palette.textTertiary)
            }
            .padding(50)
            .glassCard(radius: Metrics.popoverRadius, dark: true)
            FocusAnchor()
        }
    }

    private func infuse(_ e: StreamEntry) {
        resolving = e
        resolveTask = Task {
            do {
                let r = try await StreamResolver.resolve(e, video: request.video, timeout: 60) { resolvingStatus = $0 }
                resolving = nil
                var sub: URL?
                if settings.externalForwardSubtitles { sub = await SubtitleFetcher.preferredSubtitleURL(meta: meta, video: request.video) }
                _ = ExternalPlayback.launch(.infuse, meta: meta, video: request.video, url: r.url, subtitles: sub)
            } catch {
                resolving = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A thin white capsule that sweeps (the auto-select loading bar).
struct IndeterminateCapsule: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: geo.size.width * phase)
            }
            .clipShape(Capsule())
        }
        .onAppear {
            guard !PerformanceProfile.reduceMotion else { phase = 0.3; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 0.65 }
        }
    }
}

// MARK: - Row

struct SourceRow: View {
    let entry: StreamEntry
    let fullName: Bool
    /// Link badges matched for this row (Settings → Link Badges).
    var badges: [StreamBadge] = []
    var badgeScale: CGFloat = 1
    @Environment(\.rowFocused) private var focused

    var body: some View {
        HStack(spacing: 20) {
            // The release's own tag (1080p, 720p, 480i…); blank when it names none.
            Text(entry.traits.resolutionTag ?? "")
                .font(.system(size: (entry.traits.resolutionTag?.count ?? 0) > 4 ? 19 : 22, weight: .bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(width: 84, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.black.opacity(0.08) : Palette.glassRaised))
            VStack(alignment: .leading, spacing: 4) {
                // Full names: the whole release, every line of it (fixedSize, or
                // the lazy list truncates it at its proposed height anyway).
                Text(fullName ? entry.fullName : entry.displayName).font(TypeStyle.cardTitle.font)
                    .lineLimit(fullName ? nil : 1)
                    .fixedSize(horizontal: false, vertical: fullName)
                Text(entry.displayDetail).font(TypeStyle.cardBody.font)
                    .foregroundStyle(focused ? Palette.focusInk.opacity(0.7) : Palette.textSecondary)
                    .lineLimit(fullName ? nil : 2)
                    .fixedSize(horizontal: false, vertical: fullName)
                if !badges.isEmpty {
                    // Chips can't shrink: a link with many of them made the row
                    // wider than the list, and its right side ran off screen.
                    StreamBadgeChips(badges: badges, scale: badgeScale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 8) {
                if entry.isInstant {
                    Text("⚡ Cached").font(.system(size: 18, weight: .semibold)).foregroundStyle(focused ? .green : Palette.positive)
                }
                if let d = entry.traits.debridShort { chip(d) }
                // A badge pack labels the link itself; the built-in tags would repeat it.
                if badges.isEmpty { ForEach(entry.badges.prefix(3), id: \.self) { chip($0) } }
                if entry.stream.isTorrent && !entry.isInstant { Image(systemName: "bolt.horizontal.circle").font(.system(size: 22)) }
                if let size = entry.fileSizeLabel { Text(size).font(.system(size: 19, weight: .medium)) }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 18)
    }

    private func chip(_ s: String) -> some View {
        Text(s).font(.system(size: 16, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Palette.focusInk.opacity(0.5) : Palette.textTertiary, lineWidth: 1.5))
    }
}

struct SourceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                    if focused { shape.fill(Palette.focusFill) } else { GlassSurface(shape: shape) }
                }
                .scaleEffect(focused ? 1.02 : 1)
                .animation(Motion.focus, value: focused)
                .environment(\.rowFocused, focused)
        }
    }
}

/// Source row hold: Play in Infuse (if installed).
struct SourceHoldMenu: ViewModifier {
    let entry: StreamEntry
    let onInfuse: () -> Void

    func body(content: Content) -> some View {
        if ExternalPlayers.infuseInstalled {
            StableContextMenu(content: content, key: entry.id) {
                Button(action: onInfuse) { Label("Play in Infuse", systemImage: "arrow.up.forward.app") }
            }
        } else {
            content
        }
    }
}

/// Binds focus only on the list's first link.
private struct FirstLinkFocus: ViewModifier {
    let isFirst: Bool
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isFirst { content.focused(focused) } else { content }
    }
}
