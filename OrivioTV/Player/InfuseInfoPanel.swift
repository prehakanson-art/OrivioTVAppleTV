import AVFoundation
import AVKit
import KSPlayer
import SwiftUI

// MARK: - Info panel (swipe down)
//
// Infuse's tvOS info sheet: four tab pills centred at the top — Info, Video,
// Audio, Subtitles — over one wide dark card. Moving focus across the pills
// switches the card; Down steps into the card's rows; a row with a value
// opens a full-screen picker (`InfusePickerScreen`); Menu steps back out of
// a picker, then closes the sheet; Up on the pills closes it too.
//
// Everything the app has that Infuse doesn't — sources, episodes, engine,
// Picture in Picture — sits under OPTIONS on the Info tab, so the visible
// player stays Infuse's and nothing is lost.

struct InfuseInfoPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var store: PlayerSettingsStore
    @FocusState private var focus: Focus?
    @State private var picker: InfusePickerSpec?
    /// Where focus goes back to when the picker closes.
    @State private var pickerReturnFocus: Focus?
    /// The focus before the current one, to tell "Up from a row" apart from
    /// a sideways move along the pills.
    @State private var lastFocus: Focus?
    /// The rows only become focusable once the viewer presses Down from a
    /// pill, and until focus has landed anywhere only the Info pill is
    /// focusable — so the engine's first pass has exactly one place to go.
    @State private var rowsEnabled = false
    @State private var firstFocusLanded = false
    private var rowsHaveFocus: Bool {
        if case .row = focus { return true }
        return false
    }
    /// Bumped to pop the AirPlay route picker (the Speaker row).
    @State private var routePickerToken = 0
    @State private var speakerName = InfuseInfoPanel.currentSpeakerName()

    enum Focus: Hashable {
        case tab(Int)
        case row(String)
    }

    private static let tabs = ["Info", "Video", "Audio", "Subtitles"]

    /// Focus one main-actor turn later — the rows are being (re)enabled or
    /// the sheet is still mounting on the pass that asks for it.
    private func landFocus(_ target: Focus) {
        Task { @MainActor in focus = target }
    }

    var body: some View {
        ZStack {
            // (The dim behind the sheet is PlayerScreen's, so it fades in
            // place instead of sliding down with the sheet as a grey slab.)
            VStack(spacing: 22) {
                tabBar
                card
                Spacer(minLength: 0)
            }
            .padding(.top, 42)
            .padding(.horizontal, FusionMetrics.sideInset)
            .ignoresSafeArea()
            // The sheet stays put under a picker — dimmed, and out of the
            // focus engine's reach — so it is exactly where you left it when
            // the picker closes.
            .opacity(picker == nil ? 1 : 0.35)
            .disabled(picker != nil)

            if let picker {
                InfusePickerScreen(viewModel: viewModel, spec: picker) {
                    closePicker()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, .tab(0))
        .onAppear {
            // Open on the Info pill: it is the only focusable thing until
            // focus has landed once (the other pills and every row are
            // disabled), so the engine cannot choose anything else. The
            // binding is NOT pre-set — a pre-set binding made defaultFocus a
            // no-op and the engine then picked a row by geometry.
            lastFocus = nil
            rowsEnabled = false
            firstFocusLanded = false
            viewModel.infoFocusOnTabs = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if focus == nil { focus = .tab(0) }
            }
        }
        .onChange(of: focus) { _, new in
            defer { lastFocus = new }
            if new != nil { firstFocusLanded = true }
            guard case .tab(let index) = new else {
                if new != nil { viewModel.infoFocusOnTabs = false }
                return
            }
            viewModel.infoFocusOnTabs = true
            // Up out of the rows lands on whichever pill is nearest by
            // geometry, which is usually NOT the open tab. Coming from a row,
            // the destination is the current tab, full stop.
            if case .row = lastFocus, index != viewModel.infoTab {
                landFocus(.tab(viewModel.infoTab))
                return
            }
            viewModel.infoTab = index
        }
        // Back closed the picker from the view model (window-level Menu).
        .onChange(of: viewModel.infoPickerVisible) { _, visible in
            if !visible, picker != nil { closePicker() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification),
                   perform: focusMoveFailed)
        .animation(FusionMotion.controlsAppear, value: picker == nil)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 20) {
            ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, title in
                Button {
                    viewModel.infoTab = index
                } label: {
                    InfuseTabLabel(title: title, selected: viewModel.infoTab == index)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focus, equals: .tab(index))
                // While focus is down in the rows only the OPEN tab is
                // reachable, so Up comes straight back to it instead of
                // visiting whichever pill the engine finds nearest first.
                .disabled((rowsHaveFocus && index != viewModel.infoTab)
                          || (!firstFocusLanded && index != 0))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The engine reported a move it could not make. Only then — never on a
    /// guess about timing — hand focus across the gap it can't see: Up from
    /// a row to the open tab's pill, Down from a pill to that tab's first
    /// row. (The pill can sit far to one side of the rows, outside the
    /// engine's angular window; the Info tab's options are at the right
    /// edge.) A move the engine DID make, however long it takes to report,
    /// never triggers this — which is what stopped Up between rows from
    /// jumping to the pills.
    private func focusMoveFailed(_ note: Notification) {
        guard viewModel.overlay == .info, picker == nil,
              let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
        else { return }
        switch context.focusHeading {
        case .up:
            if case .row = focus { focus = .tab(viewModel.infoTab) }
        case .down:
            // The rows are disabled until now — enable them, then land on the
            // first one a turn later, once they are focusable.
            if case .tab = focus, let first = firstRow(ofTab: viewModel.infoTab) {
                rowsEnabled = true
                landFocus(.row(first))
            }
        default:
            break
        }
    }

    /// The row Down from the pills should land on, per tab.
    private func firstRow(ofTab tab: Int) -> String? {
        switch tab {
        case 1: return "video.zoom"
        case 2: return viewModel.audioOptions.first.map { "audio.track.\($0.id)" } ?? "audio.speaker"
        case 3: return viewModel.subtitleOptions.first.map { "sub.track.\($0.id)" } ?? "sub.font"
        default: return "info.source"
        }
    }

    // MARK: Card

    private var card: some View {
        Group {
            switch viewModel.infoTab {
            case 1: videoTab
            case 2: audioTab
            case 3: subtitlesTab
            default: infoTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!rowsEnabled)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color(hex: 0x1B1B1D).opacity(0.94))
        )
    }

    // MARK: Info tab

    private var infoTab: some View {
        let summary = viewModel.infuseFileSummary()
        let episode = viewModel.currentVideo
        let still = episode?.thumbnail.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(alignment: .top, spacing: 40) {
            HStack(alignment: .center, spacing: 28) {
                Group {
                    if let still {
                        RemoteImage(url: still, maxDimension: 320)
                            .frame(width: 320, height: 180)
                    } else {
                        RemoteImage(url: viewModel.displayMeta.poster, maxDimension: 250)
                            .frame(width: 168, height: 250)
                    }
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 10) {
                    // The title, then what identifies the TITLE rather than
                    // the file: score, certificate, genre. Score and
                    // certificate are fixed-size, so the genre is the only one
                    // that gives way when the column is narrow — "if there's
                    // room", in that order of importance.
                    HStack(alignment: .center, spacing: 16) {
                        Text(viewModel.infoCardTitle)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .layoutPriority(2)
                        if let imdb = viewModel.displayMeta.imdbRating, !imdb.isEmpty {
                            ImdbBadge(rating: imdb).fixedSize()
                        }
                        // From the view model, resolved when the player opened —
                        // fetching it here made the badge appear mid-slide.
                        if let contentRating = viewModel.contentRating, !contentRating.isEmpty {
                            ContentRatingBadge(rating: contentRating).fixedSize()
                        }
                        if let genres = infoGenres {
                            Text(genres)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if let synopsis = infoSynopsis {
                        Text(synopsis)
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // WRAPPING, not clipped. As one `HStack … lineLimit(1)`
                    // everything past the width of the column simply vanished —
                    // on a well-described file that was the codec, the HDR tag,
                    // the audio format and the bitrate, i.e. most of what the
                    // card exists to say. It now flows onto as many rows as it
                    // needs.
                    InfuseWrapRow(spacing: 20, lineSpacing: 8) {
                        if let runtime = summary.runtime {
                            Text(runtime)
                        }
                        if let year = viewModel.displayMeta.releaseInfo, !year.isEmpty {
                            Text(year)
                        }
                        ForEach(Array(summary.details.enumerated()), id: \.offset) { _, item in
                            Text(item)
                        }
                    }
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                }
            }
            .padding(.vertical, 16)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            optionsColumn(header: "Options") {
                optionRow("info.source", label: "Source", value: viewModel.currentEntry.addonName) {
                    viewModel.loadSourcesIfNeeded()
                    return InfusePickerSpec(title: "Sources", content: .sources)
                }
                if viewModel.currentVideo?.season != nil {
                    optionRow("info.episodes", label: "Episodes", value: viewModel.currentVideo?.seasonEpisodeCode) {
                        InfusePickerSpec(title: "Episodes", content: .episodes)
                    }
                }
                optionRow("info.engine", label: "Engine", value: viewModel.engineName) {
                    InfusePickerSpec(title: "Engine", content: .items(
                        PlayerEngine.allCases.filter { $0 != .external }.map { engine in
                            InfusePickerItem(id: engine.rawValue, title: engine.label,
                                             selected: viewModel.effectiveEngine == engine) {
                                viewModel.switchEngine(engine)
                            }
                        }
                    ))
                }
                if viewModel.pictureInPicture.isPossible {
                    actionRow("info.pip", label: "Picture in Picture") {
                        viewModel.pictureInPicture.start()
                    }
                } else if viewModel.canEnterPictureInPictureViaNativeEngine {
                    actionRow("info.pip", label: "Picture in Picture", value: "via Native engine") {
                        viewModel.enterPictureInPictureViaNativeEngine()
                    }
                }
            }
            .frame(width: 520)
            .padding(.top, 12)
            .padding(.trailing, 60)
            .padding(.bottom, 20)
        }
    }

    /// An episode's card is about the EPISODE, so its own overview wins;
    /// otherwise the title's.
    private var infoSynopsis: String? {
        if let overview = viewModel.currentVideo?.overview, !overview.isEmpty { return overview }
        guard let description = viewModel.displayMeta.description, !description.isEmpty else { return nil }
        return description
    }

    /// Three at most — past that it stops being a genre and starts being a
    /// list, and it is the first thing to lose the width fight anyway.
    private var infoGenres: String? {
        guard let genres = viewModel.displayMeta.genres?.prefix(3), !genres.isEmpty else { return nil }
        return genres.joined(separator: ", ")
    }

    // MARK: Video tab

    /// THE THREE COLUMNS MUST FIT 1748pt.
    ///
    /// The sheet is padded by `FusionMetrics.sideInset` (86) on each side of a
    /// 1920pt screen, so the card has 1748pt — and this is the only tab whose
    /// columns are fixed widths (Audio and Subtitles go through `twoColumns`,
    /// which is `maxWidth: .infinity` and simply compresses). Fixed children
    /// cannot compress, so when the total exceeded the card the HStack
    /// overran, the ZStack that hosts BOTH this sheet and the video grew wider
    /// than the screen, and `PlayerVideoView` — which fills that ZStack — took
    /// the video's container with it. A `.resizeAspect` layer in an
    /// oversized frame scales the picture up: opening the Video tab visibly
    /// ZOOMED the film behind it, and the Status column was being clipped off
    /// the right edge at the same time.
    ///
    /// Every column is `InfuseRowMetrics.columnWidth` (520), on this tab and on
    /// Audio: 520 × 3 + (40 × 2 spacing) + (40 × 2 padding) = 1720, i.e. 28pt
    /// of slack. Keep the sum under 1748 when touching any of these.
    private var videoTab: some View {
        HStack(alignment: .top, spacing: 40) {
            formatColumn
            videoOptions
            statusColumn
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 40)
    }

    /// Live session health, right of Options: download speed, cache lead,
    /// how much is on disk, connections — "why is this stuttering", answered
    /// from the couch. Read-only and non-focusable, like Format. Refreshes
    /// once a second via TimelineView, so only THIS column re-renders.
    private var statusColumn: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let h = MediaCacheServer.shared.health
            let bufferAhead = max(viewModel.clock.buffered - viewModel.clock.position, 0)
            VStack(alignment: .leading, spacing: 0) {
                InfuseColumnHeader(text: "Status")
                if h.hasSession {
                    InfuseOptionRow(label: "Download",
                                    value: h.downloadRate > 0 ? Self.rate(h.downloadRate) : "idle",
                                    interactive: false)
                    InfuseOptionRow(label: "Cache ahead",
                                    value: h.leadSeconds > 0
                                        ? "\(Int(h.leadSeconds))s (\(Self.bytes(h.leadBytes)))"
                                        : Self.bytes(h.leadBytes),
                                    interactive: false)
                    InfuseOptionRow(label: "On disk",
                                    value: h.totalBytes > 0
                                        ? "\(Self.bytes(h.onDiskBytes)) of \(Self.bytes(h.totalBytes)) (\(Int(Double(h.onDiskBytes) / Double(h.totalBytes) * 100))%)"
                                        : Self.bytes(h.onDiskBytes),
                                    interactive: false)
                    InfuseOptionRow(label: "Connections",
                                    value: "\(h.busyWorkers)/\(h.workerLimit)"
                                        + (h.originCap.map { " · capped at \($0)" } ?? ""),
                                    interactive: false)
                    if h.windowed {
                        InfuseOptionRow(label: "Cache window",
                                        value: h.pausedForSpace
                                            ? "paused for space"
                                            : "sliding · \(Self.bytes(h.evictedBytes)) evicted",
                                        interactive: false)
                    }
                } else if let failure = h.failure {
                    InfuseOptionRow(label: "Cache", value: failure, interactive: false)
                } else {
                    InfuseOptionRow(label: "Cache", value: "off (direct stream)", interactive: false)
                }
                InfuseOptionRow(label: "Engine buffer",
                                value: bufferAhead > 0 ? "\(Int(bufferAhead))s" : "—",
                                interactive: false)
            }
        }
        .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
        .allowsHitTesting(false)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond / 1_048_576
        return mbps >= 10 ? String(format: "%.0f MB/s", mbps)
            : mbps >= 1 ? String(format: "%.1f MB/s", mbps)
            : String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }

    private static func bytes(_ count: Int64) -> String {
        let mb = Double(count) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }

    /// What the stream IS, beside the controls that change how it's shown.
    /// Read-only and non-focusable: it answers "am I actually getting Dolby
    /// Vision / HDR10 / SDR, and which profile" without leaving the player.
    private var formatColumn: some View {
        let rows = viewModel.videoFormatRows()
        return VStack(alignment: .leading, spacing: 0) {
            InfuseColumnHeader(text: "Format")
            if rows.isEmpty {
                InfuseOptionRow(label: "Still identifying the stream…", value: nil, interactive: false)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    InfuseOptionRow(label: row.label, value: row.value, interactive: false)
                }
            }
        }
        .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var videoOptions: some View {
        optionsColumn(header: "Options") {
            optionRow("video.zoom", label: "Zoom Mode", value: zoomLabel(viewModel.aspectMode)) {
                InfusePickerSpec(title: "Zoom Mode", content: .items(
                    AspectMode.allCases.map { mode in
                        InfusePickerItem(id: mode.rawValue, title: zoomLabel(mode),
                                         selected: viewModel.aspectMode == mode) {
                            viewModel.setAspect(mode)
                        }
                    }
                ))
            }
            optionRow("video.aspect", label: "Aspect Ratio", value: viewModel.aspectRatioLabel) {
                InfusePickerSpec(title: "Aspect Ratio", content: .items(
                    PlayerViewModel.aspectRatioOptions.map { option in
                        InfusePickerItem(id: option.label, title: option.label,
                                         selected: option.value == viewModel.aspectRatioOverride) {
                            viewModel.aspectRatioOverride = option.value
                        }
                    }
                ))
            }
            optionRow("video.shift", label: "Vertical Shift", value: viewModel.verticalShift.label) {
                InfusePickerSpec(title: "Vertical Shift", content: .items(
                    PlayerViewModel.VerticalShift.allCases.map { shift in
                        InfusePickerItem(id: shift.rawValue, title: shift.label,
                                         selected: viewModel.verticalShift == shift) {
                            viewModel.verticalShift = shift
                        }
                    }
                ))
            }
            if !viewModel.chapters.isEmpty {
                let current = viewModel.currentChapter
                let currentIndex = viewModel.chapters.firstIndex { $0.start == current?.start } ?? 0
                optionRow("video.chapters", label: "Chapters",
                          value: current.map { PlayerViewModel.chapterLabel($0, index: currentIndex) } ?? "—") {
                    InfusePickerSpec(title: "Chapters", content: .items(
                        viewModel.chapters.enumerated().map { index, chapter in
                            InfusePickerItem(id: "chapter-\(index)",
                                             title: PlayerViewModel.chapterLabel(chapter, index: index),
                                             subtitle: TimeFormat.clock(chapter.start),
                                             selected: index == currentIndex) {
                                viewModel.seek(toChapter: chapter)
                            }
                        }
                    ))
                }
            }
            optionRow("video.speed", label: "Playback Speed", value: speedLabel(viewModel.playbackSpeed)) {
                InfusePickerSpec(title: "Playback Speed", content: .items(
                    Self.speeds.map { speed in
                        InfusePickerItem(id: "\(speed)", title: speedLabel(speed),
                                         selected: viewModel.playbackSpeed == speed) {
                            viewModel.setSpeed(speed)
                        }
                    }
                ))
            }
            if let dolby = viewModel.dolbyVisionStatus {
                InfuseOptionRow(label: "Dolby Vision", value: dolby, interactive: false)
            }
        }
        .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
    }

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private func zoomLabel(_ mode: AspectMode) -> String {
        switch mode {
        case .fit: return "Normal"
        case .zoom: return "Crop"
        case .stretch: return "Stretch"
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1 ? "Normal" : String(format: "%gx", speed)
    }

    // MARK: Audio tab

    /// Tracks, then the controls, then — far right — what the audio IS and
    /// what the app is doing with it. Three columns of
    /// `InfuseRowMetrics.columnWidth`, the same as the Video tab's, so the
    /// headers sit at one pitch and the right-hand column does not move when
    /// you switch tabs — see the width-budget note above `videoTab` for why
    /// the sum must stay under 1748: exceeding it once made the hosting stack
    /// wider than the screen and visibly zoomed the film behind the sheet.
    /// Tracks stay first so the default focus target (`audio.track.*`) is
    /// unchanged.
    private var audioTab: some View {
        HStack(alignment: .top, spacing: 40) {
            tracksColumn(prefix: "audio", options: viewModel.audioOptions,
                         selectedID: viewModel.selectedAudioID) { option in
                viewModel.selectAudio(option)
            }
            .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
            audioOptionsColumn
            audioFormatColumn
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 40)
    }

    /// Read-only and non-focusable, like the Video tab's `formatColumn`: it
    /// answers "is this really Atmos, or multichannel PCM?" without leaving
    /// the player. Re-read on every route change so plugging in a receiver
    /// mid-film updates the Output and Route rows.
    private var audioFormatColumn: some View {
        let rows = viewModel.audioFormatRows()
        return VStack(alignment: .leading, spacing: 0) {
            InfuseColumnHeader(text: "Format")
            if rows.isEmpty {
                InfuseOptionRow(label: "Still identifying the audio…", value: nil, interactive: false)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    InfuseOptionRow(label: row.label, value: row.value, interactive: false)
                }
            }
        }
        .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
        .allowsHitTesting(false)
        // `speakerName` is already refreshed on route change below; naming it
        // here makes this column re-evaluate on the same notification.
        .id(speakerName)
    }

    private var audioOptionsColumn: some View {
        optionsColumn(header: "Options") {
                // Lip-sync offset ("voices don't line up with the mouths") —
                // per-title, remembered like speed. FFmpeg, VLC and DV sample
                // engines; the native AVPlayer path has no knob to turn, so the
                // row stays out of the way there rather than lying. "Off" is the
                // engine's own timing — every value is added on top of it.
                if viewModel.audioSyncAdjustable {
                    optionRow("audio.sync", label: "Audio Sync",
                              value: PlayerViewModel.audioSyncLabel(viewModel.audioSyncOffset)) {
                        InfusePickerSpec(title: "Audio Sync", content: .items(
                            PlayerViewModel.audioSyncOptions.map { offset in
                                InfusePickerItem(
                                    id: "sync-\(Int(offset * 1000))",
                                    title: PlayerViewModel.audioSyncLabel(offset),
                                    selected: viewModel.audioSyncOffset == offset
                                ) {
                                    viewModel.setAudioSync(offset)
                                }
                            }
                        ))
                    }
                }
                actionRow("audio.speaker", label: "Speaker", value: speakerName) {
                    routePickerToken += 1
                }
            }
            .frame(width: InfuseRowMetrics.columnWidth, alignment: .leading)
            .background {
                // Invisible AVRoutePickerView; the row pokes it to present
                // the system AirPlay / output sheet.
                AirPlayRoutePickerHost(presentToken: routePickerToken)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .opacity(0.02)
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                speakerName = Self.currentSpeakerName()
            }
    }

    /// The current audio output route, as the TV names it.
    private static func currentSpeakerName() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else { return "Apple TV" }
        switch output.portType {
        case .HDMI: return "TV"
        case .airPlay: return output.portName
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return output.portName
        default: return output.portName.isEmpty ? "Apple TV" : output.portName
        }
    }

    // MARK: Subtitles tab

    private var subtitlesTab: some View {
        twoColumns {
            tracksColumn(prefix: "sub", options: viewModel.subtitleOptions,
                         selectedID: viewModel.selectedSubtitleID) { option in
                viewModel.selectSubtitle(option)
            }
        } trailing: {
            optionsColumn(header: "Options") {
                let s = store.settings
                // Fetches the addon tracks again and puts the current one
                // back — for captions that stopped showing or never loaded.
                actionRow("sub.reload", label: "Reload Subtitles") {
                    viewModel.reloadSubtitles()
                }
                optionRow("sub.font", label: "Font", value: fontLabel(s.subtitleFontName)) {
                    InfusePickerSpec(title: "Font", content: .items(
                        PlayerSettings.subtitleFontOptions.map { option in
                            InfusePickerItem(id: "font-\(option.0)", title: option.1,
                                             selected: s.subtitleFontName == option.0) {
                                store.settings.subtitleFontName = option.0
                            }
                        }
                    ))
                }
                optionRow("sub.size", label: "Size", value: "\(s.subtitleSize) pt") {
                    InfusePickerSpec(title: "Size", content: .items(
                        PlayerSettings.subtitleSizeValues.map { size in
                            InfusePickerItem(id: "size-\(size)", title: "\(size) pt",
                                             selected: s.subtitleSize == size) {
                                store.settings.subtitleSize = size
                                // KSPlayer's own cue styling reads this static.
                                SubtitleModel.textFontSize = CGFloat(size)
                            }
                        }
                    ))
                }
                optionRow("sub.color", label: "Color", value: colorLabel(s.subtitleTextColorHex)) {
                    InfusePickerSpec(title: "Color", content: .items(
                        PlayerSettings.subtitleColorOptions.map { option in
                            InfusePickerItem(id: "color-\(option.0)", title: option.1,
                                             selected: s.subtitleTextColorHex == option.0) {
                                store.settings.subtitleTextColorHex = option.0
                            }
                        }
                    ))
                }
                optionRow("sub.weight", label: "Weight", value: s.subtitleBold ? "Bold" : "Regular") {
                    InfusePickerSpec(title: "Weight", content: .items([
                        InfusePickerItem(id: "regular", title: "Regular", selected: !s.subtitleBold) {
                            store.settings.subtitleBold = false
                        },
                        InfusePickerItem(id: "bold", title: "Bold", selected: s.subtitleBold) {
                            store.settings.subtitleBold = true
                        }
                    ]))
                }
                optionRow("sub.outline", label: "Outline", value: s.subtitleOutlineEnabled ? "Bordered" : "Off") {
                    InfusePickerSpec(title: "Outline", content: .items([
                        InfusePickerItem(id: "bordered", title: "Bordered", selected: s.subtitleOutlineEnabled) {
                            store.settings.subtitleOutlineEnabled = true
                        },
                        InfusePickerItem(id: "off", title: "Off", selected: !s.subtitleOutlineEnabled) {
                            store.settings.subtitleOutlineEnabled = false
                        }
                    ]))
                }
                optionRow("sub.background", label: "Background", value: s.subtitleBackground ? "On" : "Off") {
                    InfusePickerSpec(title: "Background", content: .items([
                        InfusePickerItem(id: "on", title: "On", selected: s.subtitleBackground) {
                            store.settings.subtitleBackground = true
                        },
                        InfusePickerItem(id: "off", title: "Off", selected: !s.subtitleBackground) {
                            store.settings.subtitleBackground = false
                        }
                    ]))
                }
                optionRow("sub.opacity", label: "Opacity", value: "\(s.subtitleBackgroundOpacity)%") {
                    InfusePickerSpec(title: "Opacity", content: .items(
                        PlayerSettings.subtitleBackgroundOpacityValues.map { value in
                            InfusePickerItem(id: "opacity-\(value)", title: "\(value)%",
                                             selected: s.subtitleBackgroundOpacity == value) {
                                store.settings.subtitleBackgroundOpacity = value
                            }
                        }
                    ))
                }
                optionRow("sub.offset", label: "Vertical Alignment", value: offsetLabel(s.subtitleVerticalOffset)) {
                    InfusePickerSpec(title: "Vertical Alignment", content: .items(
                        PlayerSettings.subtitleOffsetValues.map { value in
                            InfusePickerItem(id: "offset-\(value)", title: offsetLabel(value),
                                             selected: s.subtitleVerticalOffset == value) {
                                store.settings.subtitleVerticalOffset = value
                            }
                        }
                    ))
                }
                optionRow("sub.delay", label: "Delay", value: PlayerViewModel.formatDelay(viewModel.subtitleDelay)) {
                    InfusePickerSpec(title: "Delay", content: .items(
                        PlayerSettings.subtitleDelayValues.map { value in
                            InfusePickerItem(id: "delay-\(value)", title: PlayerViewModel.formatDelay(value),
                                             selected: viewModel.subtitleDelay == value) {
                                viewModel.nudgeSubtitleDelay(by: value - viewModel.subtitleDelay)
                            }
                        }
                    ))
                }
            }
        }
    }

    private func fontLabel(_ name: String) -> String {
        PlayerSettings.subtitleFontOptions.first { $0.0 == name }?.1 ?? "Default"
    }

    private func colorLabel(_ hex: String) -> String {
        PlayerSettings.subtitleColorOptions.first { $0.0.caseInsensitiveCompare(hex) == .orderedSame }?.1 ?? "White"
    }

    private func offsetLabel(_ value: Int) -> String {
        value == 0 ? "Default" : (value > 0 ? "Up \(value)" : "Down \(-value)")
    }

    // MARK: Layout helpers

    /// TRACKS on the left, OPTIONS on the right — the Audio and Subtitles
    /// cards. Both columns start well in from the card's edge, as Infuse's do.
    private func twoColumns<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 40) {
            leading().frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 230)
        .padding(.vertical, 22)
    }

    private func optionsColumn<Rows: View>(header: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InfuseColumnHeader(text: header)
            rows()
        }
    }

    /// A list of tracks with a checkmark on the active one. Scrolls past
    /// eight rows, fading at the bottom edge like Infuse's.
    private func tracksColumn(prefix: String, options: [TrackOption], selectedID: String?,
                              onSelect: @escaping (TrackOption) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InfuseColumnHeader(text: "Tracks")
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if options.isEmpty {
                        InfuseOptionRow(label: "No tracks in this stream", value: nil, interactive: false)
                    }
                    ForEach(options) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            InfuseTrackRow(
                                title: option.id == "sub-off" ? "None" : option.displayName,
                                selected: option.id == selectedID
                            )
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focus, equals: .row("\(prefix).track.\(option.id)"))
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            // Sized to the rows (up to eight), so a one-track list doesn't
            // stretch the card to the scroller's maximum.
            .frame(height: InfuseRowMetrics.height * CGFloat(min(max(options.count, 1), 8)) + 20)
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    /// A row that opens a picker. `make` builds the picker when pressed so the
    /// spec always reflects the current values.
    private func optionRow(_ id: String, label: String, value: String?,
                           make: @escaping () -> InfusePickerSpec) -> some View {
        Button {
            pickerReturnFocus = .row(id)
            picker = make()
            viewModel.infoPickerVisible = true
        } label: {
            InfuseOptionRow(label: label, value: value, interactive: true)
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focus, equals: .row(id))
    }

    private func actionRow(_ id: String, label: String, value: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InfuseOptionRow(label: label, value: value, interactive: true)
        }
        .buttonStyle(PlainCardButtonStyle())
        .focused($focus, equals: .row(id))
    }

    private func closePicker() {
        picker = nil
        viewModel.infoPickerVisible = false
        landFocus(pickerReturnFocus ?? .tab(viewModel.infoTab))
    }
}

// MARK: - AirPlay route picker

/// A hidden `AVRoutePickerView`. tvOS has no API to present the output
/// sheet directly; poking the picker's own button is the accepted way.
struct AirPlayRoutePickerHost: UIViewRepresentable {
    let presentToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var lastToken = 0 }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        guard context.coordinator.lastToken != presentToken else { return }
        context.coordinator.lastToken = presentToken
        guard presentToken > 0 else { return }
        DispatchQueue.main.async {
            guard let button = view.subviews.compactMap({ $0 as? UIButton }).first else { return }
            button.sendActions(for: .primaryActionTriggered)
            button.sendActions(for: .touchUpInside)
        }
    }
}

// MARK: - Pieces

enum InfuseRowMetrics {
    static let height: CGFloat = 52
    static let font: CGFloat = 29

    /// Every column on every tab, so the three headers sit at the same pitch
    /// and the third one lands in the SAME place whichever tab you are on.
    /// They used to be 580 / 530 / 450, which stepped unevenly across the card
    /// and made the right-hand header jump when you switched between Video and
    /// Audio. See the width-budget note above `videoTab` before changing it:
    /// 3 × 520 + (40 × 2 spacing) + (40 × 2 padding) = 1720 — the same total
    /// the old split came to, so the 28pt of slack under the card is unchanged.
    static let columnWidth: CGFloat = 520
}

private struct InfuseTabLabel: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 31, weight: .semibold))
            .foregroundStyle(isFocused ? .black : .white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                } else if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.24))
                }
            }
            .focusLift(OrivioFocus.card, isFocused)
    }
}

/// A horizontal run of items that wraps onto further rows instead of being
/// clipped. tvOS has no `FlowLayout`, and an `HStack` silently truncates —
/// which is how the Info card came to hide half of what it had been given.
struct InfuseWrapRow: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                widest = max(widest, x)
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(max(widest, x), maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct InfuseColumnHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 22, weight: .medium))
            .kerning(0.8)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.top, 10)
            .padding(.bottom, 14)
    }
}

/// Label left, value right. Focus brightens both — there is no platter, so
/// contrast is the whole signal: an unfocused control sits well back and the
/// focused one is pure white and semibold. `interactive: false` rows are the
/// read-outs (the Video tab's Format column and its Dolby Vision line) — they
/// are not controls, nothing ever focuses them, and they keep their own
/// brightness rather than being dimmed as if they were dimmable.
struct InfuseOptionRow: View {
    @Environment(\.isFocused) private var isFocused
    let label: String
    let value: String?
    let interactive: Bool

    var body: some View {
        HStack(spacing: 20) {
            Text(label)
                .font(.system(size: InfuseRowMetrics.font, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? .white : .white.opacity(interactive ? 0.55 : 0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.system(size: InfuseRowMetrics.font, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? .white : .white.opacity(interactive ? 0.42 : 0.45))
                    .lineLimit(1)
            }
        }
        .frame(height: InfuseRowMetrics.height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct InfuseTrackRow: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .medium))
                .opacity(selected ? 1 : 0)
                .frame(width: 26)
            Text(title)
                .font(.system(size: InfuseRowMetrics.font, weight: isFocused ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isFocused ? .white : .white.opacity(selected ? 0.62 : 0.5))
        .frame(height: InfuseRowMetrics.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, -38)   // checkmark hangs in the gutter, text aligns with the header
        .contentShape(Rectangle())
    }
}

// MARK: - Full-screen picker

struct InfusePickerItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    /// Badger badge chips for this link, drawn the way the pre-play Sources
    /// list draws them. Carried as DATA rather than flattened into `subtitle`:
    /// a badge's whole point is that it is recognisable at a glance from the
    /// sofa, and `" · HDR · Atmos"` buried at the end of a grey subtitle line
    /// is none of that.
    var badges: [StreamBadge] = []
    /// Debrid-cached torrent — instant play. The single most consequential
    /// fact about a link and the one this list did not show at all: an
    /// uncached source streams from a file the provider is still downloading,
    /// which cannot report a length, so the hybrid cache refuses the session
    /// and the title buffers its way through with no read-ahead at all.
    var instant: Bool = false
    var debridName: String? = nil
    let selected: Bool
    let action: () -> Void
}

enum InfusePickerContent {
    case items([InfusePickerItem])
    /// Live lists that change while open (sources still loading, episode
    /// metadata arriving) — built from the view model on every pass.
    case sources
    case episodes
}

struct InfusePickerSpec {
    let title: String
    let content: InfusePickerContent
}

/// Infuse's option picker: a dimmed screen, the setting's name in grey at
/// the top, and a centred stack of rounded rows — white with a checkmark on
/// the focused one. Choosing a row applies it and calls `onClose`.
struct InfusePickerScreen: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    /// Only for a torrent link's provider chip ("RD", "TB"), matching the
    /// pre-play list. Injected app-wide, so the player's cover inherits it.
    @EnvironmentObject private var debrid: DebridStore
    let spec: InfusePickerSpec
    let onClose: () -> Void
    @FocusState private var focus: String?

    private var items: [InfusePickerItem] {
        switch spec.content {
        case .items(let items):
            return items
        case .sources:
            return viewModel.allEntries.map { entry in
                var detail = entry.addonName
                if !entry.displayDetail.isEmpty { detail += " · \(entry.displayDetail)" }
                let tags = [entry.resolutionLabel, entry.fileSizeLabel].compactMap { $0 }
                if !tags.isEmpty { detail += " · " + tags.joined(separator: " · ") }
                return InfusePickerItem(
                    id: entry.id.uuidString, title: entry.displayName,
                    subtitle: detail,
                    badges: streamBadges.badges(for: entry),
                    instant: entry.stream.isTorrent && entry.isInstant,
                    debridName: entry.stream.isTorrent ? debrid.resolverProvider?.shortName : nil,
                    selected: entry.id == viewModel.currentEntry.id
                ) {
                    viewModel.switchSource(entry)
                }
            }
        case .episodes:
            guard let season = viewModel.currentVideo?.season else { return [] }
            return viewModel.displayMeta.episodes(season: season).map { episode in
                InfusePickerItem(
                    id: episode.id,
                    title: "\(episode.episode.map { "\($0). " } ?? "")\(episode.title ?? "Episode")",
                    subtitle: episode.overview.flatMap { $0.isEmpty ? nil : $0 },
                    selected: episode.id == viewModel.currentVideo?.id
                ) {
                    viewModel.play(episode: episode)
                }
            }
        }
    }

    /// Takes the rows the body already projected — `items` is expensive
    /// enough that it is built once per pass and handed down (see `body`).
    private func emptyLabel(for rows: [InfusePickerItem]) -> String? {
        switch spec.content {
        case .sources:
            if viewModel.isLoadingSources { return "Searching sources…" }
            return viewModel.allEntries.isEmpty ? "No sources found" : nil
        case .episodes:
            return rows.isEmpty ? "The episode list hasn't loaded yet" : nil
        case .items(let items):
            return items.isEmpty ? "Nothing to choose" : nil
        }
    }

    var body: some View {
        // `items` projects the WHOLE list — a uuidString, several string
        // appends and a badge lookup per source, and for episodes a
        // filter+sort over every video on the show. It was rebuilt on every
        // pass by ForEach, defaultFocus (twice), the onChange key and the
        // empty label, and — because `rowWidth` reached back through it —
        // once more for every row the LazyVStack realized, so a 150-source
        // list was rebuilt a dozen times on the main thread for a single Down
        // press, while the video decoded underneath. Project once and pass it
        // down. The onAppear and onChange ACTIONS deliberately still read
        // `items` live: they run after this pass, and landing focus on a
        // snapshot that no longer matches the rows on screen is how the
        // remote goes dead.
        let rows = items
        let rowWidth: CGFloat = rows.contains { $0.subtitle != nil } ? 1100 : 600
        ZStack {
            Group {
                if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
                    Color(hex: 0x141416).opacity(0.9)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.55))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Text(spec.title)
                    .font(.system(size: 53, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 100)
                    .padding(.bottom, 64)

                ScrollView(.vertical) {
                    LazyVStack(spacing: 12) {
                        if let emptyLabel = emptyLabel(for: rows) {
                            // Focusable so Menu still has somewhere to land.
                            Button {} label: {
                                InfusePickerRow(title: emptyLabel, subtitle: nil, selected: false,
                                                width: rowWidth)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focus, equals: "empty")
                        }
                        ForEach(rows) { item in
                            Button {
                                item.action()
                                onClose()
                            } label: {
                                InfusePickerRow(title: item.title, subtitle: item.subtitle,
                                                badges: item.badges, instant: item.instant,
                                                debridName: item.debridName,
                                                selected: item.selected, width: rowWidth)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focus, equals: item.id)
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
        .defaultFocus($focus, rows.first { $0.selected }?.id ?? rows.first?.id ?? "empty")
        .onAppear {
            focus = items.first { $0.selected }?.id ?? items.first?.id ?? "empty"
        }
        // Sources and Episodes arrive AFTER the screen opens — a Continue
        // Watching session has to fetch its alternatives first, and the
        // episode list comes in with the enriched metadata. Focus was parked
        // on the "Searching sources…" placeholder, which is removed the
        // instant the real rows land, taking focus out of the hierarchy with
        // it: a full screen of rows and a dead remote. Re-land it on the row
        // the picker would have opened on.
        .onChange(of: rows.map(\.id)) { _, ids in
            if let current = focus, ids.contains(current) { return }
            focus = items.first { $0.selected }?.id ?? ids.first ?? "empty"
        }
    }
}

private struct InfusePickerRow: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String?
    var badges: [StreamBadge] = []
    var instant: Bool = false
    var debridName: String? = nil
    let selected: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 29, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .white.opacity(0.55))
                        .lineLimit(2)
                }
                if !badges.isEmpty {
                    StreamBadgeChips(badges: badges)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            // Cached-vs-not, the fact that decides whether this link plays now
            // or buffers its way through. Same chip, same wording and the same
            // trailing position as the pre-play Sources list, so the two lists
            // read as one thing rather than two.
            if instant {
                MetaBadge(
                    text: "⚡︎ Cached",
                    tint: OrivioPrimitives.success.opacity(isFocused ? 0.30 : 0.22),
                    textColor: OrivioPrimitives.success
                )
            }
            if let debridName {
                MetaBadge(
                    text: debridName,
                    tint: OrivioPrimitives.success.opacity(isFocused ? 0.30 : 0.22),
                    textColor: OrivioPrimitives.success
                )
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isFocused ? .black.opacity(0.5) : .white.opacity(0.6))
            }
        }
        .foregroundStyle(isFocused ? .black : .white)
        .padding(.horizontal, 24)
        .padding(.vertical, subtitle == nil && badges.isEmpty ? 0 : 10)
        .frame(width: width)
        .frame(minHeight: 67)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.93) : Color.white.opacity(0.12))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 14, y: 6)
        )
        .focusLift(OrivioFocus.row, isFocused)
    }
}
