import SwiftUI
import UIKit

struct PlayerScreen: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var watched: WatchedStore
    @StateObject private var viewModel: PlayerViewModel
    @FocusState private var catcherFocused: Bool
    /// Focus on the "Skip Intro" pill. Kept in sync both ways with
    /// `viewModel.skipIntroFocused` so the trackpad gesture layer and the
    /// focus engine can each move it and neither ends up lying about it.
    @FocusState private var skipIntroFocused: Bool
    /// Opaque cover held over the last frame while the display-mode handshake
    /// settles on exit. See exitPlayer().
    @State private var exitCoverVisible = false

    let dismiss: () -> Void

    init(
        request: PlaybackRequest,
        addonManager: AddonManager,
        progressStore: ProgressStore,
        playerSettings: PlayerSettings = .default,
        allowUnairedNextUp: Bool = true,
        dismiss: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: PlayerViewModel(
            request: request,
            addonManager: addonManager,
            progressStore: progressStore,
            settings: playerSettings,
            allowUnairedNextUp: allowUnairedNextUp
        ))
        self.dismiss = dismiss
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // NB: the exit cover is added at the END of this ZStack (see the
            // overlay below) so it sits above every control.

            // In the default FIT mode the video view is hosted RAW — no
            // GeometryReader, no scaleEffect. A Core Animation transform on the
            // Metal video layer forces per-frame recompositing (breaking the
            // direct scan-out path), which drops frames on the A10X on EVERY
            // video, not just when zooming — that was choppiness we imposed
            // that stock players (Stremio) don't. Zoom/stretch opt INTO the
            // transform only when actually selected.
            if viewModel.aspectMode == .fit {
                PlayerVideoView(viewModel: viewModel, refreshID: viewModel.videoRefreshID)
                    .ignoresSafeArea()
            } else {
                GeometryReader { geo in
                    let scale = viewModel.aspectMode.scale(
                        video: viewModel.videoNaturalSize, container: geo.size
                    )
                    PlayerVideoView(viewModel: viewModel, refreshID: viewModel.videoRefreshID)
                        .scaleEffect(x: scale.width, y: scale.height)
                        .animation(.easeInOut(duration: 0.25), value: viewModel.aspectMode)
                }
                .ignoresSafeArea()
            }

            SubtitleOverlayView(model: viewModel.subtitleModel, settings: viewModel.settings)
                .ignoresSafeArea()

            // Diagnostics HUD (Settings → Performance → Developer). Above the
            // subtitles, below the controls; hidden while any panel is open so
            // it never fights the UI for the corner.
            if PerformanceSettingsStore.shared.settings.showPlayerDiagnostics
                || ProcessInfo.processInfo.arguments.contains("-playerHUD"),
               viewModel.overlay == .none || viewModel.overlay == .controls {
                PlayerDiagnosticsHUD(viewModel: viewModel)
            }

            // Window-level TRACKPAD capture (indirect touches) — the single,
            // reliable source for taps/swipes/scrub. Active over bare video,
            // the pause overlay, and while scrubbing.
            RemoteTouchCatcher(
                isActive: {
                    viewModel.overlay == .none
                        || viewModel.overlay == .pauseInfo
                        || viewModel.isScrubbing
                },
                onBegan: { viewModel.remoteTouchBegan() },
                onMoved: { dx, dy in viewModel.remoteTouchMoved(dx: dx, dy: dy) },
                onEnded: { dx, dy in viewModel.remoteTouchEnded(dx: dx, dy: dy) }
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)

            // Window-level Back interceptor: Menu is ALWAYS routed through
            // handleExit while the player is up, even when a side panel left
            // focus in limbo (the "Back closes the whole player" bug).
            RemoteMenuCatcher { _ = viewModel.handleExit() }
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)

            // On-screen input diagnostics (Settings → Playback → toggle).
            if viewModel.settings.showInputDebug {
                VStack {
                    Text("input: \(viewModel.inputDebug)")
                        .font(.system(size: 22, weight: .bold).monospaced())
                        .foregroundStyle(.yellow)
                        .padding(10)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 40)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Invisible focus catcher: owns focus whenever no other focusable
            // UI is up (bare video, the pause overlay, and the info pull-down),
            // turning remote presses into player actions. Without it those
            // states would be focus dead-zones and remote commands (including
            // Menu) would stop arriving.
            if viewModel.overlay == .none || viewModel.overlay == .pauseInfo || viewModel.overlay == .info {
                remoteCatcher
            }

            // Black cover while resyncing after returning from background —
            // hides the undecoded garbage (black/green/red) frames the Metal
            // layer shows until the flush-seek lands a clean frame.
            if viewModel.isResyncing {
                Color.black.ignoresSafeArea().transition(.opacity)
            }

            if !viewModel.hasStartedPlayback && !viewModel.isShowingError {
                if viewModel.settings.loadingOverlayEnabled {
                    // Full-screen Orivio-style loading backdrop for the initial load.
                    PlayerLoadingOverlay(viewModel: viewModel)
                        .transition(.opacity)
                } else {
                    // Overlay off: plain black covers the undecoded first frames.
                    Color.black.ignoresSafeArea().transition(.opacity)
                }
            } else if viewModel.showBufferSpinner && viewModel.overlay != .controls {
                // Light spinner for mid-playback rebuffers (keep the video
                // visible). Debounced in the view model: skip/seek blips must
                // NOT flash it (the "white glitch" on every skip).
                bufferingIndicator
                    .transition(.opacity)
            }

            // Peek bar (light tap): position + when you started / when you'll
            // finish — no menu. Click drops into scrub to edit the time.
            if viewModel.peekVisible, viewModel.overlay == .none, !viewModel.isScrubbing {
                // Fusion shows its OWN bar here rather than the stock peek bar,
                // so a light tap — and the quick-seek below — look like the
                // controls you get a moment later instead of a different player.
                FusionInertOverlay(viewModel: viewModel).transition(.opacity)
            }


            scrubHUD

            if viewModel.overlay == .controls {
                FusionPlayerControlsOverlay(viewModel: viewModel).transition(.opacity)
                if viewModel.settings.osdClockEnabled {
                    OSDClock()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, OrivioSpacing.xl)
                        .padding(.trailing, OrivioSpacing.huge)
                        .transition(.opacity)
                }
            }

            if viewModel.overlay == .pauseInfo, viewModel.settings.pauseOverlayEnabled {
                PauseOverlayView(viewModel: viewModel)
                    .transition(.opacity)
            }

            // Side panel: just a clean slide in from the right (move-only
            // transition, see SidePanel). No separate dim layer — that was
            // snapping in as a block before the panel slid into it.
            sidePanels

            // The sheet is ALWAYS MOUNTED and simply parked above the top of
            // the screen, sliding down on a plain `.offset`. It is never
            // inserted or removed, so there is no transition at all.
            //
            // That is the point. A transition needs an animation transaction to
            // drive it, and this subtree sits inside the player ZStack's own
            // `.animation(value: viewModel.overlay)` as well as this one — two
            // transactions, two different durations, both firing on the same
            // state change. SwiftUI ran the transition twice, which is why two
            // copies of the sheet were on screen a few points apart and the
            // title looked ghosted. Neither shortening the travel nor measuring
            // it could fix that, because the duplication was never about the
            // distance. With the view permanently mounted there is nothing to
            // insert, nothing to remove, and only one animatable value.
            //
            // Cost: the panel's artwork loads once when playback starts rather
            // than on first pull-down. It is the same poster and cast row the
            // Detail page already cached, and it buys a slide that cannot
            // desync.
            if viewModel.hasStartedPlayback {
                VStack(spacing: 0) {
                    InfoPullDownPanel(viewModel: viewModel)
                        .offset(y: viewModel.overlay == .info ? 0 : -900)
                        .animation(.easeOut(duration: 0.3),
                                   value: viewModel.overlay == .info)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(viewModel.overlay == .info)
            }

            if viewModel.overlay == .upNext {
                UpNextOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }

            if viewModel.overlay == .stillWatching {
                StillWatchingOverlay(viewModel: viewModel, exit: exitPlayer)
                    .transition(.opacity)
            }

            if viewModel.overlay == .postPlay {
                PostPlayOverlay(viewModel: viewModel, exit: exitPlayer)
                    .transition(.opacity)
            }

            if viewModel.overlay == .exitConfirm {
                ExitConfirmOverlay(viewModel: viewModel, exit: exitPlayer)
                    .transition(.opacity)
            }

            if case .error(let message) = viewModel.overlay {
                PlayerErrorOverlay(message: message, viewModel: viewModel, dismiss: exitPlayer)
            }

            if let toast = viewModel.toast {
                VStack {
                    Text(toast)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, OrivioSpacing.xl)
                        .padding(.vertical, OrivioSpacing.sm)
                        .playerChrome(in: Capsule())
                        .padding(.top, OrivioSpacing.xxl)
                    Spacer()
                }
                .transition(.opacity)
            }

            if viewModel.isSwitchingSource {
                SwitchingSourceOverlay(label: "Loading next episode")
            }

            // Quick-seek HUD: shown while accumulating D-pad skips over the
            // bare video (controls hidden). Reflects the running total.
            if viewModel.pendingSeekDelta != 0, viewModel.overlay != .controls, !viewModel.isScrubbing {
                // Not drawn twice: the peek bar above already renders this
                // same block, and a skip over bare video is exactly when a
                // light tap may also have raised it.
                if !viewModel.peekVisible {
                    FusionInertOverlay(viewModel: viewModel).transition(.opacity)
                }
            }

            // "Skip Intro" pill while inside an intro-like chapter.
            skipIntroPill
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.overlay)
        .animation(.easeOut(duration: 0.2), value: viewModel.isResyncing)
        // Held over the last frame while the display-mode handshake settles.
        // Opaque and above everything, so the renegotiation happens over a
        // static black screen — never over a video surface being torn down.
        .overlay {
            if exitCoverVisible { Color.black.ignoresSafeArea() }
        }
        .animation(.easeOut(duration: 0.16), value: viewModel.isScrubbing)
        .animation(.easeOut(duration: 0.16), value: viewModel.peekVisible)
        .animation(.easeOut(duration: 0.2), value: viewModel.showBufferSpinner)
        .animation(.easeOut(duration: 0.16), value: viewModel.pendingSeekDelta != 0)
        .animation(.easeInOut(duration: 0.3), value: viewModel.hasStartedPlayback)
        .onPlayPauseCommand {
            if viewModel.isScrubbing {
                viewModel.commitScrub()
            } else if viewModel.skipIntroActive {
                // While the Skip Intro pill is up, ⏯ skips (focus never has to
                // leave the video).
                viewModel.skipIntro()
            } else {
                viewModel.togglePlayPause()
            }
        }
        .onExitCommand {
            if !viewModel.handleExit() {
                exitPlayer()
            }
        }
        .onChange(of: viewModel.overlay) { _, newValue in
            // Sources opened from a Continue Watching session has no
            // alternatives yet — fetch them the moment the panel appears.
            if newValue == .sources { viewModel.loadSourcesIfNeeded() }
            // When the controls auto-hide (→ bare video), focus was on a
            // control that's now gone. Reclaim it for the invisible catcher so
            // the very next click REOPENS the menu instead of landing on the
            // stale play button (which read as "trying to hide the menu").
            if newValue == .none || newValue == .pauseInfo || newValue == .info {
                // ...unless the Skip Intro pill is the thing that should hold
                // it, in which case stealing focus back would un-highlight it.
                guard !viewModel.skipIntroFocused else { return }
                DispatchQueue.main.async { catcherFocused = true }
            }
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.skipIntroActive)
        // View model → focus engine.
        .onChange(of: viewModel.skipIntroFocused) { _, focused in
            if focused {
                skipIntroFocused = true
            } else if viewModel.overlay == .none || viewModel.overlay == .pauseInfo
                        || viewModel.overlay == .info {
                // The pill let go — the invisible catcher has to take focus
                // back or the remote goes dead over bare video.
                DispatchQueue.main.async { catcherFocused = true }
            }
        }
        // Focus engine → view model (a swipe can land focus on the pill on its
        // own; the model must not go on believing the catcher still has it).
        .onChange(of: skipIntroFocused) { _, focused in
            if viewModel.skipIntroFocused != focused { viewModel.skipIntroFocused = focused }
        }
        .onDisappear {
            viewModel.teardown()
        }
        // Belt #3 against Back closing the player: even if a Menu press slips
        // past the window recognizer (races with the system's own handling
        // while a panel transition has focus in limbo), the system is not
        // allowed to interactively dismiss this cover. Exits happen ONLY via
        // exitPlayer() → dismiss().
        .interactiveDismissDisabled()
        .onAppear {
            // Let the player mark episodes watched (Episodes / Up Next
            // long-press) via the shared WatchedStore.
            viewModel.markWatched = { [weak viewModel] episode in
                guard let viewModel else { return }
                watched.mark(meta: viewModel.meta, video: episode)
            }
            // Hand the view model a debrid resolver so torrent sources can be
            // switched to (and failed over to) mid-playback. Tries every
            // configured provider, preferred first, like the Sources page.
            if debrid.resolverProvider != nil {
                // Ask the store per call rather than snapshotting the keys here:
                // a Real-Debrid token refreshed during a long session would
                // otherwise leave this closure holding the expired one for the
                // rest of playback.
                viewModel.torrentResolver = { [weak viewModel, debrid] stream in
                    let (result, _) = await DebridService.resolveAcross(
                        stream: stream,
                        providers: await debrid.resolversRefreshingIfNeeded(),
                        season: viewModel?.currentVideo?.season,
                        episode: viewModel?.currentVideo?.episode
                    )
                    guard case .success(let url, let filename) = result else { return nil }
                    return Stream(
                        name: stream.name,
                        title: filename ?? stream.title,
                        description: stream.description,
                        url: url,
                        infoHash: nil,
                        behaviorHints: stream.behaviorHints
                    )
                }
            }
        }
        .task { await runDemoTourIfRequested() }
    }

    /// Dev-only: `-playerDemoTour` walks the player through its overlay
    /// states (controls → pause info → Infuse scrub → commit) so each can be
    /// screenshotted headlessly in the simulator.
    private func runDemoTourIfRequested() async {
        // Dev-only: `-playerControlsDemo` keeps the transport controls pinned up
        // (re-showing them past the idle auto-hide) so the overlay skin can be
        // screenshot-verified in the sim, where the remote can't be driven.
        if ProcessInfo.processInfo.arguments.contains("-playerControlsDemo") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if viewModel.hasStartedPlayback { viewModel.showControls() }
            }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("-playerDemoTour") else { return }
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        viewModel.togglePlayPause()             // → pause overlay
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        viewModel.togglePlayPause()             // resume
        viewModel.hideControls()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        viewModel.beginScrub()                  // → Infuse scrub HUD
        viewModel.scrubJump(90)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        viewModel.scrubJump(60)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        viewModel.commitScrub()
    }

    /// Exit is immediate UNLESS a display-mode switch happened this session.
    ///
    /// When one did, prepareForExit detaches the video surface, then this holds
    /// the black cover while the mode is released a beat later, so the HDMI
    /// handshake completes over a static screen rather than over a video surface being destroyed —
    /// the overlap that leaves some TVs grey until they are power-cycled. The
    /// wait is zero for every ordinary (SDR / no-switch) exit, so nothing gets
    /// slower for the common case.
    private func exitPlayer() {
        guard !viewModel.isExiting else { return }
        NSLog("[OrivioPlayer] exitPlayer() called — overlay=%@", String(describing: viewModel.overlay))
        viewModel.prepareForExit()
        let settle = viewModel.exitDisplaySettleDelay
        guard settle > 0 else {
            viewModel.releaseDisplayForExit()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
            return
        }
        // isExiting is already true, so every input path is inert while this
        // runs — a Back press during the wait can't re-enter the exit flow.
        exitCoverVisible = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            viewModel.releaseDisplayForExit()
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    private var remoteCatcher: some View {
        Button {
            viewModel.noteInput("click")
            if viewModel.isScrubbing {
                viewModel.commitScrub()
            } else if viewModel.peekVisible {
                // Peek is up → a click drops into scrub so you can edit the time.
                viewModel.beginScrub()
            } else if viewModel.overlay == .info {
                viewModel.dismissInfoPanel()
            } else if viewModel.overlay == .pauseInfo {
                viewModel.togglePlayPause()
            } else {
                viewModel.showControls()
            }
        } label: {
            Color.clear
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($catcherFocused)
        .onAppear { catcherFocused = true }
        .onMoveCommand { direction in
            viewModel.noteInput("move \(direction)")
            if viewModel.overlay == .info {
                // Swipe up tucks the pull-down away; left/right switch between
                // the Details and File Info tabs. Nothing seeks under the panel.
                switch direction {
                case .up: viewModel.dismissInfoPanel()
                case .left: viewModel.infoTab = 0
                case .right: viewModel.infoTab = 1
                default: break
                }
                return
            }
            // A trackpad SWIPE emits a move command too, but a swipe is already
            // handled by the pan recognizer (which sets moveSuppressed). So
            // ONLY a real directional CLICK gets past here.
            if viewModel.moveSuppressed { return }
            // Fine-tune has the pad locked: swallow the move commands a
            // circling thumb generates at the edges rather than letting them
            // through to the jump/seek paths below.
            if viewModel.wheelEngaged { return }
            if viewModel.isScrubbing {
                switch direction {
                case .left: viewModel.scrubJump(-Double(viewModel.settings.scrubJumpSeconds))
                case .right: viewModel.scrubJump(Double(viewModel.settings.scrubJumpSeconds))
                default: viewModel.cancelScrub()
                }
                return
            }
            // Bare video / peek bar — directional CLICKS: left/right skip by the
            // configured amount, up/down open the controls. (The info panel is
            // swipe-down only, handled by the pan recognizer.)
            switch direction {
            case .left: viewModel.nudgeSeek(-Double(viewModel.settings.skipSeconds))
            case .right: viewModel.nudgeSeek(Double(viewModel.settings.skipSeconds))
            // Up/down normally opens the controls — but while the pill is up
            // it is the FIRST stop, and a second press carries on to the menu.
            case .up, .down:
                if !viewModel.focusSkipIntro() { viewModel.showControls() }
            @unknown default: break
            }
        }
    }

    /// "Skip Intro" pill.
    ///
    /// Over bare video it is a REAL focusable button — it highlights, Select
    /// skips, and the gesture layer hands it focus on the first nudge of the
    /// trackpad (see `focusSkipIntro`). Once the transport controls are up
    /// they own focus, so there it degrades to a static hint and ⏯ skips.
    @ViewBuilder
    private var skipIntroPill: some View {
        if viewModel.skipIntroActive, !viewModel.isScrubbing,
           viewModel.overlay == .none || viewModel.overlay == .controls {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if viewModel.overlay == .none {
                        Button { viewModel.skipIntro() } label: {
                            SkipIntroPillLabel()
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($skipIntroFocused)
                        .onMoveCommand { direction in
                            viewModel.noteInput("move \(direction) (skip)")
                            if viewModel.moveSuppressed { return }
                            switch direction {
                            // Keep going past the pill → the transport controls.
                            case .up, .down:
                                viewModel.skipIntroFocused = false
                                viewModel.showControls()
                            // Left/right still seek, same as over bare video —
                            // the pill isn't a mode you have to escape first.
                            case .left:
                                viewModel.nudgeSeek(-Double(viewModel.settings.skipSeconds))
                            case .right:
                                viewModel.nudgeSeek(Double(viewModel.settings.skipSeconds))
                            @unknown default: break
                            }
                        }
                    } else {
                        SkipIntroPillLabel()
                    }
                }
                .padding(.trailing, OrivioSpacing.huge)
                .padding(.bottom, viewModel.overlay == .controls ? 320 : OrivioSpacing.huge)
            }
            .transition(.opacity)
        }
    }

    private var bufferingIndicator: some View {
        VStack(spacing: OrivioSpacing.lg) {
            ProgressView()
                .tint(theme.palette.secondary)
                .scaleEffect(1.6)
            if let via = viewModel.viaLine {
                Text(via)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(OrivioSpacing.xl)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: OrivioRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private var scrubHUD: some View {
        if viewModel.isScrubbing {
            // Fusion draws the scrub view itself, using the SAME bottom block
            // as its controls — that is what keeps the title from dropping when
            // you enter a preview.
            FusionInertOverlay(viewModel: viewModel, forcedScrub: true).transition(.opacity)
        }
    }

    @ViewBuilder
    private var sidePanels: some View {
        switch viewModel.overlay {
        case .episodes:
            SidePanel(title: "Episodes", onExitCommand: sidePanelExit) {
                EpisodesPanelContent(viewModel: viewModel)
            }
        case .sources:
            SidePanel(title: "Sources", onExitCommand: sidePanelExit) {
                SourcesPanelContent(viewModel: viewModel)
            }
        case .audio:
            SidePanel(title: "Audio", onExitCommand: sidePanelExit) {
                TrackPanelContent(
                    options: viewModel.audioOptions,
                    selectedID: viewModel.selectedAudioID
                ) { viewModel.selectAudio($0); viewModel.overlay = .controls }
            }
        case .subtitles:
            SidePanel(title: "Subtitles", onExitCommand: sidePanelExit) {
                VStack(spacing: OrivioSpacing.sm) {
                    SubtitleDelayControl(viewModel: viewModel)
                    TrackPanelContent(
                        options: viewModel.subtitleOptions,
                        selectedID: viewModel.selectedSubtitleID
                    ) { viewModel.selectSubtitle($0); viewModel.overlay = .controls }
                }
            }
        case .speed:
            SidePanel(title: "Playback Speed", onExitCommand: sidePanelExit) {
                SpeedPanelContent(viewModel: viewModel)
            }
        case .engine:
            SidePanel(title: "Player Engine", onExitCommand: sidePanelExit) {
                EnginePanelContent(viewModel: viewModel)
            }
        default:
            EmptyView()
        }
    }

    /// Shared Back/Menu handler for every side panel: always returns to the
    /// main controls, never falls through to exiting the player.
    private func sidePanelExit() {
        _ = viewModel.handleExit()
    }
}

/// Full-screen initial-load screen matching the real Orivio app: the title's
/// backdrop under a dark vertical gradient, with the movie/show logo (or its
/// name) gently pulsing in the center and a status line beneath. Replaces the
/// bare spinner so loading a stream feels like the APK.
/// A live wall clock for the player OSD (Android's osdClock). Ticks each
/// minute while the controls overlay is visible.
struct OSDClock: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Text(Self.formatter.string(from: now))
            .font(.system(size: 30, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            .onReceive(timer) { now = $0 }
    }
}

struct PlayerLoadingOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    @State private var pulse = false
    @State private var revealed = false

    private var hasLogo: Bool {
        if let logo = viewModel.meta.logo { return !logo.isEmpty }
        return false
    }

    /// "Loading" while the stream opens, then "Caching" (with progress) while
    /// the initial forward buffer builds; playback starts when it completes.
    private var phaseLabel: String {
        switch viewModel.loadPhase {
        case .caching:
            return viewModel.cacheProgress > 0 ? "Caching \(viewModel.cacheProgress)%" : "Caching"
        default:
            return "Loading"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster)
                .ignoresSafeArea()

            // Match the APK scrim: light at the top, deepening to near-black at
            // the bottom so the logo/title and status read cleanly.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.30), location: 0),
                    .init(color: .black.opacity(0.60), location: 0.35),
                    .init(color: .black.opacity(0.80), location: 0.70),
                    .init(color: .black.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: OrivioSpacing.xxl) {
                logoOrTitle
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(pulse ? 1.07 : 1.0)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.7)
                    .opacity(revealed ? 1 : 0)

                if viewModel.settings.showPlayerLoadingStatus {
                    Text(phaseLabel)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .opacity(revealed ? 1 : 0)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: phaseLabel)
                }

                // A real cache-fill bar during the caching phase, so you can
                // watch the buffer building toward playback.
                if viewModel.settings.showPlayerLoadingStatus, viewModel.loadPhase == .caching {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: max(CGFloat(viewModel.cacheProgress) / 100 * 320, 6))
                    }
                    .frame(width: 320, height: 6)
                    .opacity(revealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: viewModel.cacheProgress)
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.15)) { revealed = true }
            // The logo pulse re-composites the (large) title image every frame
            // for the entire load — exactly while the A8 is busiest opening and
            // demuxing the stream, which visibly slows the open itself. Static
            // logo there; the spinner still shows life.
            if !PerformanceProfile.isLowPower {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    @ViewBuilder
    private var logoOrTitle: some View {
        if hasLogo {
            RemoteImage(url: viewModel.meta.logo, contentMode: .fit)
                .frame(width: 480, height: 270)
        } else {
            Text(viewModel.displayTitle)
                .font(.system(size: 68, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}

struct SwitchingSourceOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let label: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.lg) {
                ProgressView()
                    .tint(theme.palette.secondary)
                    .scaleEffect(1.6)
                Text(label)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// "Up Next" card — Netflix/Stremio-style: episode thumbnail, a countdown
/// PROGRESS BAR that drains toward auto-play, a "Play Next Episode" button and
/// a "Cancel" button. Long-pressing Play Next opens a context menu to pick a
/// specific source (or mark the next episode watched) — the same actions the
/// Episodes list offers, but for the queued next episode.
struct UpNextOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var playFocused: Bool

    /// Remaining fraction of the countdown for the timer bar (1 → 0).
    private var progress: Double {
        guard viewModel.upNextTotalSeconds > 0, let count = viewModel.upNextCountdown else { return 0 }
        return max(0, min(1, Double(count) / Double(viewModel.upNextTotalSeconds)))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: OrivioSpacing.xl) {
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster)
                    .frame(width: 300, height: 169)
                    .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                    Text("Up Next")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(theme.palette.secondary)
                    if let line = viewModel.upNextLine {
                        Text(line)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }

                    // Countdown timer bar (only while a countdown is active;
                    // an "unlimited" timeout shows no bar, just the buttons).
                    if viewModel.upNextCountdown != nil {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            GeometryReader { geo in
                                Capsule().fill(theme.palette.secondary)
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(width: 360, height: 6)
                        .animation(.linear(duration: 1), value: progress)
                        .padding(.top, 2)
                    }

                    HStack(spacing: OrivioSpacing.md) {
                        Button {
                            viewModel.playUpNextNow()
                        } label: {
                            HStack(spacing: OrivioSpacing.sm) {
                                Image(systemName: "play.fill")
                                if let count = viewModel.upNextCountdown {
                                    Text("Play Next Episode · \(count)s")
                                } else {
                                    Text("Play Next Episode")
                                }
                            }
                            .font(.system(size: 24, weight: .semibold))
                        }
                        .focused($playFocused)
                        // Same long-press actions as the Episodes list, for the
                        // queued next episode.
                        .contextMenu {
                            Button {
                                viewModel.playUpNextChoosingSource()
                            } label: {
                                Label("Select Source", systemImage: "list.bullet")
                            }
                            Button {
                                viewModel.markUpNextWatched()
                            } label: {
                                Label("Mark as Watched", systemImage: "checkmark.circle")
                            }
                        }
                        Button("Cancel") { viewModel.dismissUpNext() }
                            .font(.system(size: 24, weight: .semibold))
                    }
                    .padding(.top, OrivioSpacing.xs)
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
            .padding(OrivioSpacing.huge)
        }
        .onAppear { playFocused = true }
    }
}

/// "Still watching?" gate shown after several consecutive auto-advances.
struct StillWatchingOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    let exit: () -> Void
    @FocusState private var continueFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.xl) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(theme.palette.secondary)
                Text("Still watching?")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                if let line = viewModel.upNextLine {
                    Text("Up next: \(line)")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: OrivioSpacing.lg) {
                    Button("Continue Watching") { viewModel.confirmStillWatching() }
                        .font(.system(size: 25, weight: .semibold))
                        .focused($continueFocused)
                    Button("Exit", action: exit)
                        .font(.system(size: 25, weight: .semibold))
                }
                .padding(.top, OrivioSpacing.md)
            }
            .padding(OrivioSpacing.huge)
        }
        .onAppear { continueFocused = true }
    }
}

/// End-of-content overlay for movies / final episodes: Replay or Close.
struct PostPlayOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    let exit: () -> Void
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.xl) {
                Text(viewModel.displayTitle)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Finished")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: OrivioSpacing.lg) {
                    Button {
                        viewModel.replay()
                    } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 25, weight: .semibold))
                    }
                    Button("Close", action: exit)
                        .font(.system(size: 25, weight: .semibold))
                        .focused($closeFocused)
                }
                .padding(.top, OrivioSpacing.md)
            }
            .padding(OrivioSpacing.huge)
        }
        .onAppear { closeFocused = true }
    }
}

/// Infuse-style pull-down: swipe down over the video for a top sheet with two
/// tabs — **Details** (poster, plot, cast: the movie/episode itself) and
/// **File Info** (live technical data). Swipe left/right to switch tabs;
/// swipe up, click, or Back tucks it away — playback never stops underneath.
struct InfoPullDownPanel: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    /// File Info is assembled from the live player — track lists, the decision
    /// log, performance counters. Built straight into `body` it was rebuilt on
    /// every pass, including each frame of the tab cross-fade. Snapshot it when
    /// the tab opens instead; the panel is transient and the numbers are a
    /// point-in-time read anyway.
    @State private var infoSections: [PlayerViewModel.MediaInfoSection] = []

    /// Bottom-rounded sheet shape: the top edge bleeds off-screen.
    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            tabBar

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            Group {
                if viewModel.infoTab == 0 {
                    detailsTab
                } else {
                    fileInfoTab
                }
            }
            .animation(.easeOut(duration: 0.18), value: viewModel.infoTab)
        }
        .task(id: viewModel.infoTab) {
            guard viewModel.infoTab == 1 else { return }
            infoSections = viewModel.mediaInfoSections()
        }
        .padding(.horizontal, OrivioSpacing.huge)
        .padding(.top, OrivioSpacing.xl)
        .padding(.bottom, OrivioSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // System-player look: dark sheet, hairline edge, soft drop shadow
            // onto the video. The whole sheet — background and content — is one
            // unit that moves together.
            //
            // NO material here, on any device. `.ultraThinMaterial` is a LIVE
            // blur of the moving video behind a full-width sheet: the
            // compositor re-samples and re-blurs it every single frame of the
            // slide, which is what made the pull-down stutter on its way in.
            // The A8 already opted out, and its comment said why — under a 55%
            // black wash the blur is barely visible. That is just as true on
            // the 4K boxes, so the blur was paying a per-frame cost for an
            // effect nobody can see.
            sheetShape
                .fill(Color(hex: 0x0C0E12).opacity(0.92))
                .overlay(sheetShape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
                // Flatten before the shadow, so it is cast once for the whole
                // sheet instead of per layer underneath it.
                .compositingGroup()
                .shadow(color: .black.opacity(0.5),
                        radius: PerformanceProfile.isLowPower ? 0 : 16, y: 10)
        )
        // Bleed past the top/side safe area as part of the sheet itself, so
        // the slide-in offsets the entire sheet uniformly.
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    private var tabBar: some View {
        HStack(spacing: OrivioSpacing.sm) {
            tabPill("Details", index: 0)
            tabPill("File Info", index: 1)
            Spacer()
            HStack(spacing: OrivioSpacing.md) {
                shortcutHint(icon: "arrow.left.arrow.right", text: "Switch")
                shortcutHint(icon: "chevron.up", text: "Close")
            }
        }
    }

    private func shortcutHint(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.4))
    }

    private func tabPill(_ label: String, index: Int) -> some View {
        let selected = viewModel.infoTab == index
        return Text(label)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(selected ? .black : .white.opacity(0.65))
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.white : Color.white.opacity(0.1))
            )
            .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// Tab 1 — the title itself. Uses `displayMeta` (the enriched fetch) and
    /// mirrors the home hero banner's meta line — Type • Genre • Runtime •
    /// Year • IMDb — plus the plot, full genre list, and cast.
    private var detailsTab: some View {
        let meta = viewModel.displayMeta
        // When an EPISODE is playing, this tab describes that episode (its still,
        // overview and air date) rather than the show at large.
        let episode = viewModel.currentVideo
        let episodeStill = episode?.thumbnail.flatMap { $0.isEmpty ? nil : $0 }
        let bodyText = (episode?.overview.flatMap { $0.isEmpty ? nil : $0 }) ?? meta.description

        return HStack(alignment: .top, spacing: OrivioSpacing.xl) {
            Group {
                if let episodeStill {
                    // Episode still is landscape.
                    RemoteImage(url: episodeStill)
                        .frame(width: 300, height: 169)
                } else {
                    RemoteImage(url: meta.poster)
                        .frame(width: 190, height: 285)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                Text(meta.name)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let episodeLine = viewModel.episodeLine {
                    Text(episodeLine)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.palette.secondary)
                        .lineLimit(1)
                }

                // For an episode: air date. For a movie: the show/film meta line.
                if let episode {
                    if let aired = episode.airedText {
                        MetaDotText("Aired \(aired)")
                    }
                } else {
                    HStack(spacing: OrivioSpacing.sm) {
                        MetaDotText(meta.typeLabel)
                        if let genre = meta.genres?.first {
                            MetaDot(); MetaDotText(genre)
                        }
                        if let runtime = meta.runtimeFormatted {
                            MetaDot(); MetaDotText(runtime)
                        }
                        if let year = meta.year {
                            MetaDot(); MetaDotText(year)
                        }
                        if let rating = meta.imdbRating {
                            MetaDot(); ImdbBadge(rating: rating)
                        }
                    }

                    if let genres = meta.genres, genres.count > 1 {
                        Text(genres.prefix(5).joined(separator: " · "))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                if let bodyText {
                    Text(bodyText)
                        .font(.system(size: 21))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(4)
                        .padding(.top, 2)
                }

                // Same circular-headshot cast chips as the Detail page; the
                // plain name list is only the fallback while TMDB has nothing.
                if !viewModel.tmdbCast.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: OrivioSpacing.md) {
                            ForEach(viewModel.tmdbCast.prefix(10)) { member in
                                InfoCastChip(member: member)
                            }
                        }
                    }
                    .padding(.top, OrivioSpacing.xs)
                } else if let cast = meta.cast, !cast.isEmpty {
                    (Text("Cast: ").foregroundStyle(.white.opacity(0.5))
                        + Text(cast.prefix(8).joined(separator: ", ")).foregroundStyle(.white.opacity(0.8)))
                        .font(.system(size: 19, weight: .medium))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Tab 2 — live technical sections in a row of compact cards.
    private var fileInfoTab: some View {
        HStack(alignment: .top, spacing: OrivioSpacing.md) {
            ForEach(infoSections) { section in
                VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                    Text(section.title.uppercased())
                        .font(.system(size: 15, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(section.rows) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                            Text(row.value)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                // Playback Path rows carry full sentences — a
                                // remux failure REASON most of all. Truncating
                                // the one line that explains a fallback defeats
                                // the panel's purpose; wrap instead.
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OrivioSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Compact, non-interactive version of the Detail page's cast chip for the
/// pull-down: circular TMDB headshot + name + role.
private struct InfoCastChip: View {
    @EnvironmentObject private var theme: ThemeManager
    let member: TMDBService.CastMember

    var body: some View {
        VStack(spacing: 6) {
            RemoteImage(url: member.profileURL)
                .frame(width: 96, height: 96)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            Text(member.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let character = member.character, !character.isEmpty {
                Text(character)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: 120)
    }
}

/// "Exit Player?" confirmation. Reached only via Back from a top-level player
/// surface — Back never leaves playback without passing through here. Focus
/// defaults to "Keep Watching" so a stray press doesn't drop out of the video.
struct ExitConfirmOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    let exit: () -> Void
    @FocusState private var keepFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.xl) {
                Text("Exit Player?")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: OrivioSpacing.lg) {
                    Button("Keep Watching") { viewModel.cancelExitConfirm() }
                        .font(.system(size: 25, weight: .semibold))
                        .focused($keepFocused)
                    Button("Exit", action: exit)
                        .font(.system(size: 25, weight: .semibold))
                }
                .padding(.top, OrivioSpacing.md)
            }
            .padding(OrivioSpacing.huge)
        }
        .onAppear { keepFocused = true }
    }
}

struct PlayerErrorOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let message: String
    @ObservedObject var viewModel: PlayerViewModel
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: OrivioSpacing.xl) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(OrivioPrimitives.warning)
                Text(message)
                    .font(.system(size: 25))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                HStack(spacing: OrivioSpacing.lg) {
                    if viewModel.allEntries.count > 1 {
                        Button("Other Sources") {
                            viewModel.overlay = .sources
                        }
                    }
                    Button("Close Player", action: dismiss)
                }
            }
        }
    }
}

/// The "Skip Intro" capsule. Reads its own focus out of the environment so the
/// same label works both as the focusable button over bare video and as the
/// static hint under the transport controls — focused it goes solid white with
/// a Select glyph, unfocused it's the dim chrome pill with the ⏯ hint.
private struct SkipIntroPillLabel: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isFocused ? "forward.end.fill" : "playpause.fill")
                .font(.system(size: 18, weight: .bold))
            Text("Skip Intro")
                .font(.system(size: 23, weight: .semibold))
        }
        .foregroundStyle(isFocused ? .black : .white)
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.sm)
        .background {
            if isFocused {
                Capsule().fill(.white)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            }
        }
        .playerChrome(in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                .white.opacity(isFocused ? 0 : 0.25),
                lineWidth: 1
            )
        )
        .focusLift(OrivioFocus.card, isFocused)
    }
}
