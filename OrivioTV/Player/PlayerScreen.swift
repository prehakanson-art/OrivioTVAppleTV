import SwiftUI
import UIKit

struct PlayerScreen: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var watched: WatchedStore
    /// Observed (not the view model's load-time snapshot) so caption style
    /// edits made in the Subtitles panel restyle the captions on screen live.
    @EnvironmentObject private var playerSettingsStore: PlayerSettingsStore
    /// Only for the active profile's Auto Link Selector, which bounds which
    /// addons an auto-advance may use — see PlayerViewModel.autoLinkPrefs.
    @EnvironmentObject private var profiles: ProfileStore
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
    /// Kept so a Picture in Picture handoff can park this exact session and
    /// the root view can re-present the same request when it ends.
    private let request: PlaybackRequest

    /// The playing item changed WITHIN this session — auto-advance, or a pick
    /// from the in-player episode list. The host needs this because the player
    /// advances episodes inside the SAME full-screen cover without replacing
    /// the `PlaybackRequest`, so nothing the host observes changes: Trakt only
    /// ever scrobbled the FIRST episode of a binge, and the closing `stop` was
    /// addressed to that episode too.
    let onNowPlayingChanged: ((MetaItem, MetaVideo?) -> Void)?

    init(
        request: PlaybackRequest,
        addonManager: AddonManager,
        progressStore: ProgressStore,
        playerSettings: PlayerSettings = .default,
        allowUnairedNextUp: Bool = true,
        onNowPlayingChanged: ((MetaItem, MetaVideo?) -> Void)? = nil,
        dismiss: @escaping () -> Void
    ) {
        // Coming back from Picture in Picture re-presents the cover for a
        // session that never stopped playing, so adopt the parked model rather
        // than building a second one over a live engine.
        if let parked = PiPHandoff.shared.parkedViewModel(for: request) {
            _viewModel = StateObject(wrappedValue: parked)
            PiPHandoff.shared.releaseAfterRestore()
        } else {
            _viewModel = StateObject(wrappedValue: PlayerViewModel(
                request: request,
                addonManager: addonManager,
                progressStore: progressStore,
                settings: playerSettings,
                allowUnairedNextUp: allowUnairedNextUp
            ))
        }
        self.request = request
        self.dismiss = dismiss
        self.onNowPlayingChanged = onNowPlayingChanged
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
            // ONE host, always. Zoom / aspect / shift are a transform on it
            // that is the identity in the plain case. Switching between a
            // raw host and a transformed one remounted the engine's view,
            // and going Crop → Normal left the picture black on the device.
            let screen = UIScreen.main.bounds.size
            let scale = viewModel.aspectMode.transform(
                video: viewModel.videoNaturalSize, container: screen,
                forcedAspect: viewModel.aspectRatioOverride
            )
            let shift = viewModel.aspectMode.shiftOffset(
                video: viewModel.videoNaturalSize, container: screen,
                forcedAspect: viewModel.aspectRatioOverride,
                shift: viewModel.verticalShift
            )
            PlayerVideoView(viewModel: viewModel, refreshID: viewModel.videoRefreshID,
                            scale: scale, shiftY: shift)
                .ignoresSafeArea()

            // Live store settings, NOT viewModel.settings: that copy is a
            // load-time snapshot, and the Subtitles panel's size/font control
            // writes to the store — captions must restyle as you step them.
            SubtitleOverlayView(model: viewModel.subtitleModel, settings: playerSettingsStore.settings)
                .ignoresSafeArea()

            // Diagnostics HUD (Settings → Performance → Developer). Above the
            // subtitles, below the controls; hidden while any panel is open so
            // it never fights the UI for the corner.
            if PerformanceSettingsStore.shared.settings.showPlayerDiagnostics || PlayerDevFlags.playerHUD,
               viewModel.overlay == .none || viewModel.overlay == .controls {
                PlayerDiagnosticsHUD(viewModel: viewModel)
            }

            // Window-level TRACKPAD capture (indirect touches) — the single,
            // reliable source for taps/swipes/scrub. Active over bare video,
            // the pause overlay, and while scrubbing.
            RemoteTouchCatcher(
                isActive: {
                    viewModel.overlay == .none
                        || viewModel.overlay == .controls
                        || viewModel.overlay == .pauseInfo
                        || viewModel.overlay == .info
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
            //
            // AND IT MUST HONOUR THE RESULT. This discarded it, which was
            // harmless only while `handleExit` always returned true — with the
            // "Exit Player?" confirmation gone it returns FALSE to mean "the
            // view should leave now", so a Menu press arriving through this
            // path instead of `onExitCommand` would have been swallowed and
            // the player would simply refuse to close.
            RemoteMenuCatcher { if !viewModel.handleExit() { exitPlayer() } }
                .allowsHitTesting(false)
                .frame(width: 0, height: 0)

            // On-screen input diagnostics (Settings → Playback → toggle).
            if viewModel.settings.showInputDebug {
                VStack {
                    // Named like the diagnostics HUD, and for the same reason:
                    // a bare yellow line at the top of the video reads as
                    // garbage when the toggle is forgotten.
                    Text("DEV input (Settings → Performance): \(viewModel.inputDebug)")
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
            // UI is up — bare video, and the whole of the info sheet's
            // slide-out. Without it those states are focus dead-zones and
            // remote commands (including Menu) stop arriving.
            //
            // `sheetClosing` is in here because the closing sheet is still
            // mounted and `.disabled()`, so for the ~400ms of its animation
            // NOTHING in the window was focusable and every press but Menu
            // (which the window recognizer catches separately) was dropped.
            // Kept as one `if` so the catcher is the same view across the
            // hand-off and focus doesn't flicker when the sheet finally goes.
            if viewModel.overlay == .none || viewModel.sheetClosing {
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

            bottomScrim

            scrubHUD

            // The transport. Paused (.pauseInfo) is the same screen — Infuse
            // keeps the bar up while paused — and the audio / subtitle
            // popovers are this screen with a panel over one glyph.
            if controlsVisible {
                FusionPlayerControlsOverlay(viewModel: viewModel).transition(.opacity)
            }

            // Sources / episodes / engine / speed reached from elsewhere
            // (error overlay, episode long-press) use the same full-screen
            // picker the info sheet does.
            pickerOverlays

            if viewModel.overlay == .info {
                // The close is an explicit slide-up on a still-mounted sheet
                // (`sheetClosing`), then the removal: pulling a focused
                // sheet straight out of the hierarchy let the focus system
                // commit the change before the removal transition ran, so
                // the close never animated.
                Color.black.opacity(viewModel.sheetClosing ? 0 : 0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                InfuseInfoPanel(viewModel: viewModel)
                    .offset(y: viewModel.sheetClosing ? -1000 : 0)
                    .opacity(viewModel.sheetClosing ? 0 : 1)
                    .disabled(viewModel.sheetClosing)
                    .animation(PlayerViewModel.sheetMotion, value: viewModel.sheetClosing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ABOVE the transport, BELOW every modal. It is a near-opaque
            // cover, and sitting at the end of the stack it was painted over
            // the exit confirmation and the error screen — a viewer who
            // pressed Back during a failover got a dialog they could not see
            // and buttons they could not reach.
            if viewModel.isSwitchingSource, !loadingBackdropOwnsScreen {
                SwitchingSourceOverlay(label: viewModel.switchingSourceLabel)
                    .transition(.opacity)
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

            if case .error(let message) = viewModel.overlay {
                PlayerErrorOverlay(message: message, viewModel: viewModel, dismiss: exitPlayer)
            }

            if let toast = viewModel.toast {
                InfuseToast(text: toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 48)
                    .padding(.trailing, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }


            // Quick-seek HUD: shown while accumulating D-pad skips over the
            // bare video (controls hidden). Reflects the running total.
            // `!controlsVisible`, not `!= .controls`: pauseInfo (and the track
            // popovers) already draw the full transport, and a nudge there
            // stacked a second bottom block on top of it.
            if viewModel.pendingSeekDelta != 0, !controlsVisible, !viewModel.isScrubbing {
                FusionInertOverlay(viewModel: viewModel).transition(.opacity)
            }

            // "Skip Intro" pill while inside an intro-like chapter.
            skipIntroPill
        }
        // Appear and dismiss are NOT the same move. One symmetric `easeOut`
        // drove every overlay in this stack, while the token file has said all
        // along that chrome should arrive on a decelerating curve and leave on a
        // slower, softer one — `controlsDismiss` (0.26) had never reached the
        // screen. Dismissal is where a ten-foot UI most needs to be gentle: the
        // viewer is looking at the picture underneath, not at the thing leaving.
        // A8/A10X: overlays SNAP instead of fading. The fade composites the
        // full-screen transport + scrim through an offscreen transparency
        // layer over live video for its whole duration — and the FFmpeg
        // engine delivers every frame from the main run loop, so those
        // composite frames come straight out of the picture ("bringing up
        // the overlay drops the frames of the movie"). A snap at ten feet is
        // barely distinguishable from an 0.18s fade; the 4 GB boxes keep it.
        .animation(PerformanceProfile.isLowPower || PerformanceProfile.isMidPower
                   ? nil
                   : viewModel.sheetMoving ? PlayerViewModel.sheetMotion
                   : viewModel.overlay == .none ? FusionMotion.controlsDismiss
                   : FusionMotion.controlsAppear,
                   value: viewModel.overlay)
        .animation(FusionMotion.controlsAppear, value: viewModel.isResyncing)
        // Held over the last frame while the display-mode handshake settles.
        // Opaque and above everything, so the renegotiation happens over a
        // static black screen — never over a video surface being torn down.
        .overlay {
            if exitCoverVisible { Color.black.ignoresSafeArea() }
        }
        // These four were 0.16/0.16/0.2/0.16 — a 40ms spread nobody can see,
        // multiplying transactions over the same stack for no gain. One token.
        .animation(FusionMotion.controlsAppear, value: viewModel.isScrubbing)
        .animation(FusionMotion.controlsAppear, value: viewModel.showBufferSpinner)
        .animation(FusionMotion.controlsAppear, value: viewModel.pendingSeekDelta != 0)
        // The first frame appearing is a page-scale moment, not a control one.
        .animation(FusionMotion.pageEnter, value: viewModel.hasStartedPlayback)
        .onPlayPauseCommand {
            if viewModel.isScrubbing {
                viewModel.commitScrub()
            // ⏯ SKIPS THE INTRO ONLY OVER BARE, RUNNING VIDEO.
            //
            // It used to skip whenever the pill was on screen, which includes
            // while PAUSED (a pause raises the transport, and the pill stays up
            // under it). Pressing play/pause on a paused film and having it
            // jump the intro instead of resuming is the single least forgivable
            // thing this button can do — it is the most-used control in the
            // player and it has to mean one thing. Over bare running video
            // there is nothing else it could mean, so the shortcut stays there;
            // everywhere else the pill is still reachable by focus and Select.
            } else if skipIntroPillVisible && viewModel.overlay == .none && viewModel.isPlaying {
                // While the Skip Intro pill is up, ⏯ skips (focus never has to
                // leave the video).
                //
                // Keyed to the PILL, not to `skipIntroActive`. The flag stays
                // raised for the whole intro chapter no matter what is on
                // screen, so opening the info sheet or a picker during an
                // opening turned ⏯ into an invisible seek: the pill isn't
                // drawn over those, and the only thing the viewer could see
                // was the film jumping forward instead of pausing.
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
            if newValue == .none {
                // ...unless the Skip Intro pill is the thing that should hold
                // it, in which case stealing focus back would un-highlight it.
                guard !viewModel.skipIntroFocused else { return }
                DispatchQueue.main.async { catcherFocused = true }
            }
        }
        .animation(FusionMotion.controlsAppear, value: viewModel.skipIntroActive)
        // View model → focus engine.
        .onChange(of: viewModel.skipIntroFocused) { _, focused in
            if focused {
                skipIntroFocused = true
            } else if viewModel.overlay == .none {
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
            // During a PiP handoff the session is still playing — in the
            // system's small window — and PiPHandoff.finish() runs teardown
            // when it really ends. Tearing down here would stop the engine and
            // take the PiP window with it.
            guard !viewModel.isHandingOffToPictureInPicture else { return }
            viewModel.teardown()
        }
        // Belt #3 against Back closing the player: even if a Menu press slips
        // past the window recognizer (races with the system's own handling
        // while a panel transition has focus in limbo), the system is not
        // allowed to interactively dismiss this cover. Exits happen ONLY via
        // exitPlayer() → dismiss().
        .interactiveDismissDisabled()
        .onAppear {
            // Picture in Picture hands the video to the system's small window;
            // the full-screen cover has to get out of the way or the viewer is
            // left staring at a black screen behind it.
            viewModel.pictureInPicture.onWillStart = { [weak viewModel] in
                guard let viewModel else { return }
                viewModel.isHandingOffToPictureInPicture = true
                PiPHandoff.shared.begin(viewModel: viewModel, request: request)
                dismiss()
            }
            // Closed from the PiP window itself: nobody is coming back, so run
            // the teardown onDisappear skipped.
            viewModel.pictureInPicture.onDidStop = {
                PiPHandoff.shared.finish()
            }
            viewModel.pictureInPicture.onRestore = { completion in
                PiPHandoff.shared.restore(completion)
            }
            // Let the player mark episodes watched (Episodes / Up Next
            // long-press) via the shared WatchedStore.
            viewModel.markWatched = { [weak viewModel] episode in
                guard let viewModel else { return }
                watched.mark(meta: viewModel.meta, video: episode)
            }
            // Tell the host each time the playing item changes inside this
            // session, so the Trakt scrobble stops the finished episode and
            // starts the new one (see `onNowPlayingChanged` above). The view
            // model invokes it on the main actor once the new episode's
            // metadata is in place.
            if let onNowPlayingChanged {
                viewModel.onNowPlayingChanged = onNowPlayingChanged
                viewModel.autoLinkPrefs = profiles.activeAutoLink
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
                        episode: viewModel?.currentVideo?.episode,
                        // Mid-playback source switch / failover: honour the
                        // addon's file index too, so switching to a season-pack
                        // source doesn't jump to a different episode.
                        fileIdx: stream.fileIdx
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
        if PlayerDevFlags.controlsDemo {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if viewModel.hasStartedPlayback { viewModel.showControls() }
            }
            return
        }
        // Dev-only: `-playerInfoDemo` pulls the info sheet down once playback
        // is running (the gesture that opens it can't be sent to the sim).
        if PlayerDevFlags.infoDemo {
            while !viewModel.hasStartedPlayback, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            viewModel.hideControls()
            viewModel.showInfoPanel()
            return
        }
        guard PlayerDevFlags.demoTour else { return }
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
            viewModel.noteSelectPressed()   // so the lift isn't also a tap
            // Present only to hold focus while the info sheet slides away —
            // a press landing inside that animation belongs to the gesture
            // that closed it, not to the video underneath.
            if viewModel.sheetClosing { return }
            if viewModel.isScrubbing {
                viewModel.commitScrub()
            } else {
                // Infuse: a click on the bare picture is play / pause. The
                // transport comes up with it and hides again on its own.
                viewModel.togglePlayPause()
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
            if viewModel.sheetClosing { return }
            // A trackpad SWIPE emits a move command too, but a swipe is already
            // handled by the pan recognizer (which sets moveSuppressed). So
            // ONLY a real directional CLICK gets past here.
            if viewModel.moveSuppressed { return }
            // A directional press is the same physical pad-depress-and-lift a
            // Select click is: without this the LIFT also counted as a light
            // tap, so every skip press over bare video raised the transport
            // and every bar press silently flipped the clock readout.
            viewModel.noteSelectPressed()
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
            // Bare video — directional CLICKS: left/right skip by the
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

    /// The pill is actually on screen: over bare video (focusable) or under
    /// the transport (a static ⏯ hint). Everything else — the info sheet, a
    /// picker, Up Next, the exit prompt — covers it, and while it is covered
    /// ⏯ has to mean play/pause again.
    private var skipIntroPillVisible: Bool {
        viewModel.skipIntroActive && !viewModel.isScrubbing
            && (viewModel.overlay == .none || controlsVisible)
    }

    /// "Skip Intro" pill.
    ///
    /// Over bare video it is a REAL focusable button — it highlights, Select
    /// skips, and the gesture layer hands it focus on the first nudge of the
    /// trackpad (see `focusSkipIntro`). Once the transport controls are up
    /// they own focus, so there it degrades to a static hint and ⏯ skips.
    @ViewBuilder
    private var skipIntroPill: some View {
        if skipIntroPillVisible {
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
                            viewModel.noteSelectPressed()   // see the catcher's note
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
                .padding(.bottom, controlsVisible ? 260 : OrivioSpacing.huge)
            }
            .transition(.opacity)
        }
    }

    /// The full-screen initial-load backdrop is the thing on screen — and it
    /// already carries a spinner and a status line of its own.
    ///
    /// A failover BEFORE the first frame — the load watchdog giving up on a
    /// source that never opened, so `isSwitchingSource` goes true while
    /// `hasStartedPlayback` is still false — used to mount the switching cover
    /// on top of this backdrop. That cover is only 0.75 black, so it dimmed the
    /// backdrop instead of replacing it: two spinners and two status lines,
    /// stacked and overlapping, for as long as the failover had to await
    /// (a source list fetch, a torrent resolve, the once-per-chain re-scrape).
    /// The backdrop speaks `switchingSourceLabel` itself instead, and the cover
    /// stands down. It still mounts for every case where the backdrop is NOT
    /// up: mid-session switches and episode advances, the error screen, and the
    /// plain-black path when the overlay is turned off in Settings.
    private var loadingBackdropOwnsScreen: Bool {
        !viewModel.hasStartedPlayback && !viewModel.isShowingError
            && viewModel.settings.loadingOverlayEnabled
    }

    /// The transport is on screen: controls, paused, or a track popover.
    /// See `PlayerOverlay.showsTransport` — shared with `controlsSession`, so
    /// "the transport is on screen" and "the transport was just raised" can
    /// never disagree about which states count.
    private var controlsVisible: Bool { viewModel.overlay.showsTransport }

    private var bottomBlockVisible: Bool {
        if controlsVisible { return true }
        if viewModel.isScrubbing { return true }
        if viewModel.pendingSeekDelta != 0, viewModel.overlay != .controls { return true }
        return false
    }

    /// The one bottom scrim. It follows "is any bottom block on screen" rather
    /// than living inside each block, so entering or leaving a scrub swaps only
    /// the content underneath it and the darkening itself stays put.
    @ViewBuilder
    private var bottomScrim: some View {
        if bottomBlockVisible {
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.28), .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 460)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var bufferingIndicator: some View {
        ProgressView()
            .tint(.white)
            .scaleEffect(1.8)
            .shadow(color: .black.opacity(0.5), radius: 8)
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
    private var pickerOverlays: some View {
        switch viewModel.overlay {
        case .sources:
            InfusePickerScreen(viewModel: viewModel,
                               spec: InfusePickerSpec(title: "Sources", content: .sources)) {}
                .transition(.opacity)
        case .episodes:
            InfusePickerScreen(viewModel: viewModel,
                               spec: InfusePickerSpec(title: "Episodes", content: .episodes)) {}
                .transition(.opacity)
        case .speed:
            InfusePickerScreen(viewModel: viewModel, spec: InfusePickerSpec(
                title: "Playback Speed",
                content: .items([0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { (speed: Float) in
                    InfusePickerItem(id: "\(speed)",
                                     title: speed == 1 ? "Normal" : String(format: "%gx", speed),
                                     selected: viewModel.playbackSpeed == speed) {
                        viewModel.setSpeed(speed)
                    }
                })
            )) {
                viewModel.overlay = .controls
            }
            .transition(.opacity)
        case .engine:
            InfusePickerScreen(viewModel: viewModel, spec: InfusePickerSpec(
                title: "Engine",
                content: .items(PlayerEngine.allCases.filter { $0 != .external }.map { engine in
                    InfusePickerItem(id: engine.rawValue, title: engine.label,
                                     selected: viewModel.effectiveEngine == engine) {
                        viewModel.switchEngine(engine)
                    }
                })
            )) {}
            .transition(.opacity)
        default:
            EmptyView()
        }
    }
}

/// Infuse's confirmation pill: top-right, dark, rounded, a line of text.
private struct InfuseToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: 0x1B1B1D).opacity(0.94))
            )
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

private extension AspectMode {
    /// Host transform for the picture: the forced aspect ratio first
    /// (stretching the mismatched axis), then this mode's crop / stretch on
    /// the resulting shape.
    func transform(video: CGSize, container: CGSize, forcedAspect: Double?) -> CGSize {
        guard video.width > 0, video.height > 0,
              container.width > 0, container.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let real = video.width / video.height
        let shown = forcedAspect.map { CGFloat($0) } ?? real
        let fittedReal = Self.fitted(aspect: real, in: container)
        let fittedShown = Self.fitted(aspect: shown, in: container)
        let mode = scale(video: fittedShown, container: container)
        return CGSize(width: fittedShown.width / fittedReal.width * mode.width,
                      height: fittedShown.height / fittedReal.height * mode.height)
    }

    /// Vertical offset that parks a letterboxed picture against the top or
    /// bottom edge of the screen.
    func shiftOffset(video: CGSize, container: CGSize, forcedAspect: Double?,
                     shift: PlayerViewModel.VerticalShift) -> CGFloat {
        guard shift != .none, video.width > 0, video.height > 0 else { return 0 }
        let real = video.width / video.height
        let t = transform(video: video, container: container, forcedAspect: forcedAspect)
        let shownHeight = Self.fitted(aspect: real, in: container).height * t.height
        let slack = max(container.height - shownHeight, 0) / 2
        return shift == .up ? -slack : slack
    }

    private static func fitted(aspect: CGFloat, in container: CGSize) -> CGSize {
        container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
    }
}

/// Full-screen initial-load screen matching the real Orivio app: the title's
/// backdrop under a dark vertical gradient, with the movie/show logo (or its
/// name) gently pulsing in the center and a status line beneath. Replaces the
/// bare spinner so loading a stream feels like the APK.
struct PlayerLoadingOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    @State private var pulse = false
    @State private var revealed = false

    private var hasLogo: Bool {
        if let logo = viewModel.meta.logo { return !logo.isEmpty }
        return false
    }

    /// ONE loading language, in the viewer's words.
    ///
    /// "Caching" is an implementation concept — it names a buffer the viewer
    /// has no idea exists. What is actually happening during that phase is that
    /// the player is building enough of a head start to play without stuttering,
    /// which is "Preparing". "Resuming" is worth saying separately because the
    /// wait has a reason the viewer already understands: they are going back to
    /// where they were.
    private var phaseLabel: String {
        // A failover that lands before the first frame leaves THIS backdrop on
        // screen, so the switching cover stands down rather than stacking a
        // second spinner and a second status line over it (see
        // `PlayerScreen.loadingBackdropOwnsScreen`) — which makes this the only
        // place left to say what the wait is for.
        if viewModel.isSwitchingSource { return viewModel.switchingSourceLabel }
        switch viewModel.loadPhase {
        case .caching:
            return viewModel.cacheProgress > 0
                ? "Preparing video… \(viewModel.cacheProgress)%"
                : "Preparing video…"
        default:
            return viewModel.isResumingFromSavedPosition ? "Resuming…" : "Loading…"
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster,
                        maxPixels: PerformanceProfile.backdropPixelCap)
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
            // for the entire load — exactly while the chip is busiest opening
            // and demuxing the stream, which visibly slows the open itself.
            // That argument was written for the A8 but applies just as well to
            // the A10X opening a 4K remux, and that box is `isMidPower`, so the
            // mitigation was never reaching it. Also gated on Reduce Motion: a
            // two-second breathing scale, running for the whole load, is exactly
            // what that setting exists to suppress. The spinner still shows life.
            if !PerformanceProfile.isLowPower, !PerformanceProfile.isMidPower,
               !PerformanceSettingsStore.shared.reduceMotion {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }

    @ViewBuilder
    private var logoOrTitle: some View {
        if hasLogo {
            RemoteImage(url: viewModel.meta.logo, contentMode: .fit, maxDimension: 480)
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
                RemoteImage(url: viewModel.meta.background ?? viewModel.meta.poster, maxDimension: 300)
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
                        // `scaleEffect`, not `frame(width:)`. Animating a frame
                        // is a LAYOUT animation: it re-ran layout every frame
                        // for a full second, once per tick, for the whole
                        // countdown, while video decoded behind it. A transform
                        // composites for free — and the parent frame is a known
                        // 360pt, so the GeometryReader that measured it was
                        // buying a measurement pass for nothing.
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(theme.palette.secondary)
                                .scaleEffect(x: max(0, min(progress, 1)), anchor: .leading)
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

struct PlayerErrorOverlay: View {
    @EnvironmentObject private var theme: ThemeManager
    let message: String
    @ObservedObject var viewModel: PlayerViewModel
    let dismiss: () -> Void
    @FocusState private var retryFocused: Bool
    @FocusState private var sourcesFocused: Bool
    @FocusState private var closeFocused: Bool

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
                    // TRY AGAIN FIRST, and focused by default. Most terminal
                    // errors here are a CDN that timed out or a debrid link
                    // that expired — transient things where one more attempt
                    // genuinely works, and where the alternative was asking the
                    // viewer to leave the film and start over from the browser.
                    Button("Try Again") { viewModel.retryPlayback() }
                        .focused($retryFocused)
                    if viewModel.allEntries.count > 1 {
                        Button("Other Sources") {
                            viewModel.showSourcesFromError()
                        }
                        .focused($sourcesFocused)
                    }
                    Button("Close Player", action: dismiss)
                        .focused($closeFocused)
                }
                // Land focus explicitly. Left to the engine, the first pass on
                // a screen whose only focusables are these two buttons picked
                // by geometry, and on the one-button variant it sometimes
                // picked nothing at all — a full-screen error with a dead
                // remote, which is the last place that can be afforded.
                .onAppear { retryFocused = true }
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
