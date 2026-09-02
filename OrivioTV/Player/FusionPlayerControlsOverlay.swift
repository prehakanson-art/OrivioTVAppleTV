import SwiftUI

// MARK: - Shared geometry
//
// Fusion is one bar. The bottom block — title, then the bar — sits at ONE
// fixed position in every state, including scrubbing and fine-tuning, so the
// title never jumps when you drop into a preview. Everything that appears
// while you're moving through the film (the scene window above the playhead,
// the wheel and position below it) is laid out against the TRACK and overlaid,
// so it can never push the block around.

enum FusionMetrics {
    /// Distance from the screen's bottom edge to the bottom of the block. Tall
    /// enough that the wheel and position read-out can hang under the playhead
    /// without running off the screen — which is why the bar sits higher here
    /// than in Classic.
    static let bottomInset: CGFloat = 150
    static let sideInset: CGFloat = OrivioSpacing.huge

    /// Deliberately hairline, like the system player's. The dot carries the
    /// playhead; the track only has to be findable.
    static let trackHeight: CGFloat = 3
    /// Focus is a nudge, not an event. The first pass doubled the track and hung
    /// a 26pt dot off it, which read as the whole bar inflating.
    static let trackHeightFocused: CGFloat = 4
    static let thumbSize: CGFloat = 14

    /// Scene window (the Netflix-style preview riding the playhead).
    static let sceneWidth: CGFloat = 300
    static let sceneHeight: CGFloat = 169
    static let sceneGap: CGFloat = 26
    static let sceneCaret: CGFloat = 16

    /// Under-dot read-out.
    static let readoutTop: CGFloat = 28
    static let wheelSize: CGFloat = 40
}

/// What the bar is currently showing. Drives the scene window and the
/// under-dot read-out; the block itself is identical in all of them.
enum FusionBarMode {
    /// Controls up, nothing in flight.
    case idle
    /// A left/right press is accumulating a skip that hasn't committed yet.
    case nudging
    /// Fast-forward / rewind preview sweeping.
    case scanning
    /// Scrub view — preview frame, nothing committed.
    case scrubbing
    /// Scrubbing WITH the trackpad wheel engaged.
    case fineTuning

    /// A plain skip doesn't earn a preview frame — it's a 10-second hop, and
    /// the window would flash in and out on every press.
    var showsScene: Bool { self == .scanning || self == .scrubbing || self == .fineTuning }
    var showsReadout: Bool { self != .idle }
}

// MARK: - Controls overlay

/// The "Fusion" player layout, chosen via Settings → Themes → Player Layout.
///
/// One thin bar carries the whole transport: left/right seek, held left/right
/// fast-forwards, Select plays and pauses, Down opens the scrub view. Every
/// secondary control — sources, episodes, tracks, speed, aspect, engine — is
/// behind the single options button above the bar's right end, so the resting
/// screen is a title and a line.
///
/// The info pull-down, Skip Intro pill, peek bar and Up Next card are owned by
/// `PlayerScreen`, not by any layout, so they are unaffected by this choice.
struct FusionPlayerControlsOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focusedControl: Control?

    enum Control: Hashable {
        case bar
        case options
        case row(Int)
    }

    var body: some View {
        ZStack {
            scrim

            if viewModel.optionsPopupVisible {
                FusionOptionsPopup(viewModel: viewModel, focus: $focusedControl)
                    .padding(.trailing, FusionMetrics.sideInset)
                    .padding(.bottom, FusionMetrics.bottomInset + 176)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
            }

            // The options button rides in the block's trailing slot, so it sits
            // on the TITLE's line however many lines the title runs to —
            // hand-tuned padding drifted the moment an episode line appeared.
            FusionBottomBlock(
                viewModel: viewModel,
                clock: viewModel.clock,
                forcedScrub: false,
                showsTitle: true,
                isBarFocused: focusedControl == .bar
            ) {
                optionsButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // The bar's focus + input target. Kept SEPARATE from the drawing
            // above, and deliberately free of any clock observation: rebuilding
            // a focusable on every playback tick makes the focus engine churn,
            // which restarts the auto-hide timer forever and swallows presses.
            barInputTarget
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // Declared, not just assigned. `onAppear` alone loses the race with the
        // focus engine's own first pass, which picks by geometry and content
        // and lands on the options button — the one focusable here with
        // something actually drawn in it. Focus then sat on "..." while the bar
        // looked focused, so pressing Select opened the options panel instead of
        // dropping into scrub.
        .defaultFocus($focusedControl, .bar)
        .onAppear { focusedControl = .bar }
        .onChange(of: focusedControl) { _, _ in viewModel.restartHideTimer() }
        .onChange(of: viewModel.optionsPopupVisible) { _, visible in
            // Closing the panel hands focus back to the button it belongs to,
            // never to nothing (which would leave the remote dead).
            if !visible { focusedControl = .options }
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.optionsPopupVisible)
    }

    // A single soft bottom scrim, like the system player — no top gradient, so
    // the frame stays clear everywhere the controls aren't.
    private var scrim: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.40), .black.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 640)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var optionsButton: some View {
        Button {
            viewModel.optionsPopupVisible = true
            viewModel.restartHideTimer()
        } label: {
            FusionOptionsGlyph()
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focusedControl, equals: .options)
        .accessibilityLabel("Options")
        .onMoveCommand { direction in
            viewModel.noteInput("move \(direction) (options)")
            if viewModel.moveSuppressed { return }
            switch direction {
            case .down: focusedControl = .bar
            case .up: viewModel.restartHideTimer()
            // Left/right still seek from here — the button isn't a mode you
            // have to escape first.
            case .left: viewModel.barDirectionalPress(forward: false)
            case .right: viewModel.barDirectionalPress(forward: true)
            @unknown default: break
            }
        }
    }

    /// An invisible, full-width focusable sitting exactly over the bar. It owns
    /// left/right seeking, Select, and the move up/down out of the bar.
    private var barInputTarget: some View {
        Button {
            viewModel.noteInput("click (bar)")
            if viewModel.scanPreview != nil {
                // A fast-forward preview is up — Select commits it and plays
                // from there (togglePlayPause routes to scanCommit).
                viewModel.togglePlayPause()
                viewModel.restartHideTimer()
            } else {
                // Otherwise a click on the bar means "let me pick a spot", the
                // same as clicking the peek bar and the same as Classic's
                // timeline. Play/pause stays on the remote's own ⏯ button.
                viewModel.beginScrub()
            }
        } label: {
            // Short enough to clear the options button now sitting on the
            // title's line: two overlapping focusables is how the focus engine
            // starts making its own decisions about which one you meant.
            // `.contentShape` so the focus engine treats the whole strip as
            // real content rather than an empty rectangle it can skip over.
            Color.clear
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focusedControl, equals: .bar)
        .padding(.horizontal, FusionMetrics.sideInset)
        .padding(.bottom, FusionMetrics.bottomInset - 18)
        .onMoveCommand { direction in
            viewModel.noteInput("move \(direction) (bar)")
            if viewModel.moveSuppressed { return }
            switch direction {
            case .left: viewModel.barDirectionalPress(forward: false)
            case .right: viewModel.barDirectionalPress(forward: true)
            case .up: focusedControl = .options
            // Down drops into the scrub view — the only route to the preview
            // frames and the fine-tune wheel from the controls.
            case .down: viewModel.beginScrub()
            @unknown default: break
            }
        }
    }
}

// MARK: - Scrub / fine-tune presentation
//
// `beginScrub()` clears the overlay and raises `isScrubbing`, so the controls
// above are gone by then. This draws the SAME bottom block in the SAME place,
// which is what stops the title dropping when you enter the scrub view — and
// it is deliberately inert: every scrub input (click to commit, Back to
// cancel, left/right to jump, pan to scrub, edge-circle to fine-tune) is
// already handled by PlayerScreen's invisible catcher and the trackpad
// recognizer, exactly as it is for Classic.

struct FusionInertOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// True for the scrub view (always in a preview state). False for the peek
    /// bar and the quick-seek HUD, which let the block read its own mode —
    /// idle, or nudging while a skip is accumulating.
    var forcedScrub = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.40), .black.opacity(0.88)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 640)
            }
            .ignoresSafeArea()

            FusionBottomBlock(
                viewModel: viewModel,
                clock: viewModel.clock,
                forcedScrub: forcedScrub,
                showsTitle: forcedScrub,
                isBarFocused: true
            ) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The block itself

/// Title + bar, plus whatever hangs off the playhead. Observes the clock (it
/// is the only thing here that needs to repaint on a tick).
private struct FusionBottomBlock<Trailing: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    /// True for the scrub presentation, which is always in a preview state.
    let forcedScrub: Bool
    /// The title block belongs to the full controls (and the scrub view, where
    /// it must not move). A light tap or a 10-second skip over bare video is a
    /// glance at the time — it gets the bar and the numbers, nothing else.
    let showsTitle: Bool
    let isBarFocused: Bool
    /// Sits on the title's line, trailing edge — the options button, or nothing.
    @ViewBuilder var trailing: () -> Trailing

    private var mode: FusionBarMode {
        if forcedScrub { return viewModel.wheelEngaged ? .fineTuning : .scrubbing }
        if viewModel.scanPreview != nil { return .scanning }
        if viewModel.pendingSeekDelta != 0 { return .nudging }
        return .idle
    }

    /// The position the bar is POINTING at: a scan preview, a scrub target, or
    /// playback plus any pending nudge.
    private var target: Double {
        let raw = viewModel.scanPreview ?? clock.scrubTarget
            ?? (clock.position + viewModel.pendingSeekDelta)
        return min(max(raw, 0), duration)
    }
    private var duration: Double { max(clock.duration, 1) }
    private var fraction: CGFloat { CGFloat(min(max(target / duration, 0), 1)) }
    /// Where playback actually still is — drawn as a ghost tick while the
    /// pointer has moved away from it.
    private var liveFraction: CGFloat {
        CGFloat(min(max(clock.position / duration, 0), 1))
    }
    private var showsGhost: Bool {
        mode != .idle && abs(target - clock.position) > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            if showsTitle {
                HStack(alignment: .bottom, spacing: OrivioSpacing.lg) {
                    titleBlock.allowsHitTesting(false)
                    Spacer(minLength: OrivioSpacing.xl)
                    trailing()
                }
            }
            barRow.allowsHitTesting(false)
        }
        .padding(.horizontal, FusionMetrics.sideInset)
        .padding(.bottom, FusionMetrics.bottomInset)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.displayTitle)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let episodeLine = viewModel.episodeLine {
                Text(episodeLine)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            if let source = sourceLine {
                Text(source)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    private var sourceLine: String? {
        let parts = [viewModel.meta.year, viewModel.viaLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var barRow: some View {
        HStack(spacing: OrivioSpacing.md) {
            Text(TimeFormat.clock(mode == .idle
                                  ? clock.position + viewModel.pendingSeekDelta
                                  : clock.position))
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(isBarFocused ? 1 : 0.86))
                .frame(minWidth: 88, alignment: .leading)
                // Wall-clock times ride as OVERLAYS rather than a second line in
                // the stack: in the flow they would make the row taller and push
                // the title up, and the whole point of this block is that it
                // sits at one height in every state.
                .overlay(alignment: .topLeading) {
                    wallClock(WatchClock.started(position: clock.position))
                }

            track

            Text("-\(TimeFormat.clock(max(duration - target, 0)))")
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(isBarFocused ? 0.85 : 0.6))
                .frame(minWidth: 88, alignment: .trailing)
                .overlay(alignment: .topTrailing) {
                    wallClock(WatchClock.ends(position: clock.position, duration: duration))
                }
        }
    }

    /// "8:14 PM" under an end of the bar — when the film started, and when it
    /// will finish.
    private func wallClock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
            .fixedSize()
            .offset(y: 30)
    }

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = isBarFocused ? FusionMetrics.trackHeightFocused : FusionMetrics.trackHeight
            let x = w * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.34))
                    .frame(width: w * CGFloat(min(clock.buffered / duration, 1)))
                Capsule().fill(.white).frame(width: max(x, h))

                // The file's own chapters, so an MKV's structure is visible on
                // the bar instead of only findable by scrubbing blind.
                ForEach(Array(viewModel.chapterFractions.enumerated()), id: \.offset) { _, f in
                    Capsule().fill(.black.opacity(0.45))
                        .frame(width: 2, height: h)
                        .offset(x: w * CGFloat(f))
                }

                if showsGhost {
                    Rectangle().fill(.white.opacity(0.5))
                        .frame(width: 3, height: 22)
                        .offset(x: w * liveFraction - 1.5)
                }

                if isBarFocused {
                    Circle().fill(.white)
                        .frame(width: FusionMetrics.thumbSize, height: FusionMetrics.thumbSize)
                        .overlay(Circle().strokeBorder(theme.palette.secondary, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.55), radius: 6)
                        .offset(x: min(max(x - FusionMetrics.thumbSize / 2, 0),
                                       w - FusionMetrics.thumbSize))
                }
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            // Everything that rides the playhead. Overlaid, so it never
            // contributes to layout and the title above can't be pushed.
            .overlay(alignment: .topLeading) {
                // No frame rather than an empty one: the thumbnail pass is
                // skipped entirely on the A8, on HLS, and on huge remuxes
                // (see startThumbnailsIfNeeded), so a window that always drew
                // would be a permanent blank rectangle on those. The position
                // read-out below the dot still says where you are.
                if mode.showsScene, let preview = viewModel.thumbnail(at: target) {
                    FusionSceneWindow(image: preview,
                                      rate: mode == .scanning ? viewModel.scanRate : 0)
                        .offset(x: clampedX(x, width: FusionMetrics.sceneWidth, in: w)
                                   - FusionMetrics.sceneWidth / 2,
                                y: -(FusionMetrics.sceneHeight + FusionMetrics.sceneCaret
                                     + FusionMetrics.sceneGap))
                }
            }
            .overlay(alignment: .topLeading) {
                if mode.showsReadout {
                    FusionPlayheadReadout(
                        // A pending skip reads as "where you are, plus how far
                        // you've asked to go" — 22:23 +10 — so the number stays
                        // the position you pressed from. Every other mode is
                        // pointing AT a place, so it names that place.
                        time: mode == .nudging ? clock.position : target,
                        delta: readoutDelta,
                        angle: clock.wheelAngle,
                        mode: mode
                    )
                    .frame(width: 260)
                    .offset(x: clampedX(x, width: 260, in: w) - 130,
                            y: FusionMetrics.readoutTop)
                }
            }
        }
        .frame(height: 30)
    }

    /// The offset shown beside the position, when there is one.
    private var readoutDelta: Double? {
        switch mode {
        case .idle: return nil
        case .nudging: return viewModel.pendingSeekDelta
        case .scanning, .scrubbing, .fineTuning:
            let d = target - clock.position
            return abs(d) > 1 ? d : nil
        }
    }

    /// Keep a floating element inside the track rather than letting it hang off
    /// the screen when the playhead is at either end.
    private func clampedX(_ x: CGFloat, width: CGFloat, in trackWidth: CGFloat) -> CGFloat {
        min(max(x, width / 2), max(trackWidth - width / 2, width / 2))
    }
}

// MARK: - Scene window

/// The Netflix-style preview frame sitting on top of the location dot, with a
/// caret pointing down at it. Only drawn when there is a frame to show.
private struct FusionSceneWindow: View {
    let image: UIImage
    /// Scan speed; 0 hides the chip.
    let rate: Int

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: FusionMetrics.sceneWidth, height: FusionMetrics.sceneHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.34), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.85), radius: 14, y: 7)

                if rate != 0 {
                    HStack(spacing: 5) {
                        Image(systemName: rate > 0 ? "forward.fill" : "backward.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("\(abs(rate))×")
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(8)
                }
            }
            // The caret that points down at the dot.
            Rectangle()
                .fill(Color(hex: 0x10141A))
                .frame(width: FusionMetrics.sceneCaret, height: FusionMetrics.sceneCaret)
                .rotationEffect(.degrees(45))
                .offset(y: -FusionMetrics.sceneCaret / 2)
        }
        .frame(width: FusionMetrics.sceneWidth)
    }
}

// MARK: - Under-dot read-out

/// Small spin wheel (fine-tuning only), then the position, then a one-line
/// note — stacked under the playhead so the whole column tracks across the bar
/// with the dot.
private struct FusionPlayheadReadout: View {
    @EnvironmentObject private var theme: ThemeManager
    let time: Double
    let delta: Double?
    let angle: Double
    let mode: FusionBarMode

    var body: some View {
        VStack(spacing: 6) {
            if mode == .fineTuning {
                FusionSpinWheel(angle: angle, accent: theme.palette.secondary)
                    .frame(width: FusionMetrics.wheelSize, height: FusionMetrics.wheelSize)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Same 22pt as the elapsed / remaining figures at either end of
                // the bar: this is one more time read-out, not a headline.
                Text(TimeFormat.clock(time))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                if let delta {
                    Text(TimeFormat.signedDelta(delta))
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(theme.palette.secondary)
                }
            }
            .shadow(color: .black.opacity(0.8), radius: 6)
            if let note {
                Text(note)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    private var note: String? {
        switch mode {
        case .scanning: return "Press Play to resume here"
        case .scrubbing: return "Click to seek"
        case .fineTuning: return "Fine-tuning · 24s per turn"
        case .idle, .nudging: return nil
        }
    }
}

/// The click wheel: a solid accent ring with detent marks, and a white knob
/// sitting where your finger is on the trackpad.
///
/// There is deliberately NO progress arc. The first version drew one from the
/// accumulated rotation while the knob followed the raw angle, and the two
/// disagreed about which way was forwards — the arc grew clockwise while the
/// knob ran anticlockwise. A ring that is simply all one colour has no
/// direction to get wrong, and the position that actually matters (where your
/// finger is) is the knob.
private struct FusionSpinWheel: View {
    /// The finger's angle as `atan2(y, x)` over the GameController pad, where
    /// +y is the TOP of the pad.
    let angle: Double
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let ring = size * 0.22
            let r = (size - ring) / 2

            ZStack {
                Circle()
                    .stroke(accent, lineWidth: ring)
                    .padding(ring / 2)

                // Twelve detents, so the ring reads as something that turns.
                ForEach(0..<12, id: \.self) { i in
                    Capsule()
                        .fill(.black.opacity(0.32))
                        .frame(width: 1.5, height: ring * 0.55)
                        .offset(y: -r)
                        .rotationEffect(.degrees(Double(i) * 30))
                }

                Circle()
                    .fill(.white)
                    .frame(width: size * 0.26, height: size * 0.26)
                    // The pad reports +y at its TOP; SwiftUI's y grows DOWNWARD.
                    // Without the negation the knob is mirrored vertically, so
                    // it circles the opposite way to your finger.
                    .offset(x: r * CGFloat(cos(angle)), y: -r * CGFloat(sin(angle)))
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        }
    }
}

// MARK: - Options button & popup

private struct FusionOptionsGlyph: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(isFocused ? .black : .white.opacity(0.92))
                .frame(width: 58, height: 58)
                .background {
                    if isFocused {
                        Circle().fill(.white)
                            .shadow(color: .black.opacity(0.5), radius: 16, y: 7)
                    } else {
                        Circle().fill(.white.opacity(0.14))
                    }
                }
                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.18), lineWidth: 1))
                .focusLift(OrivioFocus.control, isFocused)
            Text("Options")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .opacity(isFocused ? 1 : 0)
                .lineLimit(1)
                .frame(width: 120)
        }
    }
}

/// One entry in the options panel.
private struct FusionOption: Identifiable {
    let id: Int
    let icon: String
    let label: String
    let value: String?
    /// True when this row is the last of its group (a divider follows).
    let endsGroup: Bool
    /// Aspect cycles in place and deliberately leaves the panel up; every
    /// other row opens a side panel and closes it.
    let staysOpen: Bool
    let action: () -> Void
}

/// Everything Classic spread across nine icons, in one small panel anchored to
/// the options button. Each row carries its current value, so the panel answers
/// "what is it set to" before you open anything.
private struct FusionOptionsPopup: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState.Binding var focus: FusionPlayerControlsOverlay.Control?
    @Namespace private var namespace

    private var options: [FusionOption] {
        var rows: [FusionOption] = []
        func add(_ icon: String, _ label: String, _ value: String?,
                 endsGroup: Bool = false, staysOpen: Bool = false,
                 _ action: @escaping () -> Void) {
            rows.append(FusionOption(id: rows.count, icon: icon, label: label,
                                     value: value, endsGroup: endsGroup,
                                     staysOpen: staysOpen, action: action))
        }

        if !viewModel.subtitleOptions.isEmpty {
            add("captions.bubble", "Subtitles",
                selectedName(in: viewModel.subtitleOptions, id: viewModel.selectedSubtitleID)) {
                viewModel.overlay = .subtitles
            }
        }
        if !viewModel.audioOptions.isEmpty {
            add("waveform", "Audio",
                selectedName(in: viewModel.audioOptions, id: viewModel.selectedAudioID),
                endsGroup: true) {
                viewModel.overlay = .audio
            }
        }

        add("arrow.left.arrow.right", "Sources", viewModel.currentEntry.addonName) {
            viewModel.overlay = .sources
        }
        if viewModel.currentVideo != nil {
            add("list.bullet", "Episodes", nil) { viewModel.overlay = .episodes }
        }
        if let next = viewModel.nextEpisode {
            add("forward.end.fill", "Next Episode", next.seasonEpisodeCode, endsGroup: true) {
                viewModel.play(episode: next)
            }
        }

        add("speedometer", "Speed", speedLabel) { viewModel.overlay = .speed }
        add("aspectratio", "Aspect", viewModel.aspectMode.label, staysOpen: true) {
            viewModel.cycleAspect()
        }
        add("cpu", "Engine", viewModel.engineName) { viewModel.overlay = .engine }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Options")
                .font(.system(size: 15, weight: .semibold))
                .kerning(1.3)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, OrivioSpacing.md)
                .padding(.top, OrivioSpacing.sm)
                .padding(.bottom, 4)

            ForEach(options) { option in
                Button {
                    option.action()
                    if !option.staysOpen { viewModel.optionsPopupVisible = false }
                    viewModel.restartHideTimer()
                } label: {
                    FusionOptionRow(icon: option.icon, label: option.label, value: option.value)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focus, equals: .row(option.id))
                .prefersDefaultFocus(option.id == 0, in: namespace)

                if option.endsGroup {
                    Rectangle().fill(.white.opacity(0.10))
                        .frame(height: 1)
                        .padding(.horizontal, OrivioSpacing.md)
                        .padding(.vertical, 5)
                }
            }
        }
        .padding(OrivioSpacing.sm)
        .frame(width: 430)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(0.62))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
        .focusScope(namespace)
        .onAppear { focus = .row(0) }
    }

    private func selectedName(in options: [TrackOption], id: String?) -> String? {
        guard let id, let match = options.first(where: { $0.id == id }) else { return nil }
        return match.displayName
    }

    private var speedLabel: String {
        let value = viewModel.playbackSpeed
        let text = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value) : String(format: "%.2g", value)
        return "\(text)×"
    }
}

private struct FusionOptionRow: View {
    @Environment(\.isFocused) private var isFocused
    let icon: String
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 28)
            Text(label)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: OrivioSpacing.md)
            if let value {
                Text(value)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isFocused ? .black : .white)
        .padding(.horizontal, OrivioSpacing.md)
        .padding(.vertical, 12)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
            }
        }
    }
}
