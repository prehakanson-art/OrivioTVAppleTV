import SwiftUI
import KSPlayer

/// §7.10: scrim, "Swipe down for Info", title line + glyphs, the bar, times,
/// the scrub HUD and the Subtitles/Audio popovers.
struct PlayerTransport: View {
    @ObservedObject var vm: PlayerViewModel
    var focus: FocusState<PlayerFocus?>.Binding

    static let side: CGFloat = 86
    static let barY: CGFloat = 1080 - 95
    static let barWidth: CGFloat = 1920 - side * 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrim
            if vm.scrub == nil {
                swipeHint
                titleLine
            }
            if let s = vm.scrub {
                ScrubPreviewImage(previews: vm.previews, target: s.target, duration: vm.duration)
            }
            bar
            times
            if vm.overlay == .subtitles || vm.overlay == .audio {
                TrackPopover(vm: vm, focus: focus)
                    .transition(.opacity)
            }
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
    }

    // MARK: Scrim + hint

    private var scrim: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.28), location: 0.45),
                                   .init(color: .black.opacity(0.7), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 460)
        }
        .frame(width: 1920, height: 1080)
        .allowsHitTesting(false)
    }

    private var swipeHint: some View {
        VStack(spacing: 2) {
            Text("Swipe down for Info").font(.system(size: 22, weight: .medium))
            Image(systemName: "chevron.compact.down").font(.system(size: 30, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.95))
        .shadow(color: .black.opacity(0.5), radius: 8)
        .frame(width: 1920)
        .offset(y: 60)
        .allowsHitTesting(false)
    }

    // MARK: Title line + glyphs

    private var titleLine: some View {
        HStack(alignment: .bottom, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.meta.name)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let v = vm.video {
                    Text(v.title.isEmpty ? v.seasonEpisodeCode : "\(v.seasonEpisodeCode) · \(v.title)")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 10)
            Spacer(minLength: 0)
            glyphs
        }
        .frame(width: Self.barWidth, height: 160, alignment: .bottom)
        .offset(x: Self.side, y: Self.barY - 30 - 160)
    }

    private var glyphs: some View {
        HStack(spacing: 25) {
            GlyphButton(id: "subtitles", open: vm.overlay == .subtitles, focus: focus) {
                Image(systemName: "captions.bubble").font(.system(size: 28, weight: .semibold))
            } action: { toggle(.subtitles) }
            GlyphButton(id: "audio", open: vm.overlay == .audio, focus: focus) {
                SpectrumGlyph()
            } action: { toggle(.audio) }
            if vm.nextVideo != nil, !vm.isLive {
                GlyphButton(id: "next", open: false, focus: focus) {
                    Image(systemName: "forward.end.fill").font(.system(size: 26, weight: .semibold))
                } action: { vm.playNext(auto: false) }
            }
        }
        .focusSection()
    }

    private func toggle(_ o: PlayerOverlay) {
        vm.hideTask?.cancel()
        if vm.overlay == o {
            vm.overlay = vm.isPaused ? .pauseInfo : .controls
            vm.scheduleAutoHide()
        } else {
            if o == .audio { vm.refreshInfo() } else { vm.subtitles.rebuild() }
            vm.overlay = o
        }
    }

    // MARK: Bar

    private var bar: some View {
        let shown = vm.displayTime
        let d = max(vm.duration, 0.001)
        let w = Self.barWidth
        let played = vm.isLive ? 1 : min(1, max(0, shown / d))
        let cachedFrom = min(1, max(0, vm.currentTime / d))
        let cachedTo = min(1, max(0, vm.bufferedTime / d))
        return ZStack(alignment: .leading) {
            // The focusable bar (Select = scrub, captured by the window catchers).
            Button(action: {}) { Color.clear.frame(width: w, height: 70) }
                .buttonStyle(BareFocusStyle())
                .focused(focus, equals: .bar)
                .disabled(!vm.overlay.transportVisible)
            Capsule().fill(.white.opacity(0.22)).frame(width: w, height: 6)
            if !vm.isLive, !vm.cacheSpans.isEmpty {
                // Every stretch the hybrid disk cache holds (§7.18).
                ForEach(Array(vm.cacheSpans.enumerated()), id: \.offset) { _, span in
                    Capsule().fill(.white.opacity(0.45))
                        .frame(width: max(2, w * (span.upperBound - span.lowerBound)), height: 6)
                        .offset(x: w * span.lowerBound)
                }
            } else if !vm.isLive, cachedTo > cachedFrom {
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: w * (cachedTo - cachedFrom), height: 6)
                    .offset(x: w * cachedFrom)
                    .animation(PerformanceProfile.isLowPower ? nil : .easeInOut(duration: 0.7), value: cachedTo)
            }
            Capsule().fill(.white).frame(width: max(6, w * played), height: 6)
            if !vm.isLive {
                ForEach(Array(chapterStarts.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(.black.opacity(0.4)).frame(width: 2, height: 6).offset(x: w * t / d - 1)
                }
                playhead.offset(x: w * played - playheadWidth / 2)
            }
        }
        .frame(width: w, height: 70, alignment: .leading)
        .offset(x: Self.side, y: Self.barY - 35)
        .allowsHitTesting(false)
    }

    private var chapterStarts: [Double] {
        (vm.engine?.chapters ?? []).map(\.start).filter { $0 > 1 && $0 < vm.duration - 1 }
    }

    private var playheadWidth: CGFloat {
        if let s = vm.scrub { return s.wheel ? 46 : 4 }
        return 16
    }

    @ViewBuilder private var playhead: some View {
        if let s = vm.scrub {
            if s.wheel {
                JogWheel(angle: s.wheelAngle)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 4, height: 20)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        } else {
            Circle().fill(.black)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .frame(width: 16, height: 16)
        }
    }

    // MARK: Times

    private var times: some View {
        let shown = vm.displayTime
        let x = Self.barWidth * (vm.duration > 0 ? min(1, max(0, shown / vm.duration)) : 0)
        let readout = scrubReadout
        // End labels hide when the centred readout would overlap them.
        let hideLeft = readout != nil && x < 400
        let hideRight = readout != nil && x > Self.barWidth - 400
        return ZStack(alignment: .topLeading) {
            if vm.isLive {
                LivePill().offset(y: 0)
            } else {
                HStack {
                    Text(leftLabel(shown)).opacity(hideLeft ? 0 : 1)
                    Spacer()
                    Text(rightLabel(shown)).opacity(hideRight ? 0 : 1)
                }
                .frame(width: Self.barWidth)
                if let readout {
                    Text(readout)
                        .fixedSize()
                        .frame(width: 240)
                        .offset(x: min(max(0, x - 120), Self.barWidth - 240))
                }
            }
        }
        .font(.system(size: 28, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.88))
        .shadow(color: .black.opacity(0.4), radius: 6)
        .offset(x: Self.side, y: Self.barY + 3 + 13)
        .allowsHitTesting(false)
    }

    private var scrubReadout: String? {
        if let s = vm.scrub { return Self.clock(s.target) }
        if let d = vm.nudgeDelta { return (d >= 0 ? "+" : "−") + Self.shortDelta(abs(d)) }
        return nil
    }

    private func leftLabel(_ t: Double) -> String {
        if vm.showWallClock {
            let started = Date().addingTimeInterval(-vm.currentTime / Double(max(vm.speed, 0.1)))
            return "Started \(Self.wall.string(from: started))"
        }
        return Self.clock(t)
    }

    private func rightLabel(_ t: Double) -> String {
        let remaining = max(0, vm.duration - t)
        if vm.showWallClock {
            let ends = Date().addingTimeInterval(remaining / Double(max(vm.speed, 0.1)))
            return "Ends \(Self.wall.string(from: ends))"
        }
        return "−" + Self.clock(remaining)
    }

    static let wall: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t.isFinite ? t : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func shortDelta(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? (s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s") : "\(s)s"
    }
}

// MARK: - Glyphs

private struct GlyphButton<Label: View>: View {
    let id: String
    let open: Bool
    var focus: FocusState<PlayerFocus?>.Binding
    @ViewBuilder let label: () -> Label
    let action: () -> Void

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(GlyphStyle(open: open))
            .focused(focus, equals: .glyph(id))
    }
}

private struct GlyphStyle: ButtonStyle {
    let open: Bool
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, open: open) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let open: Bool
        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background { Circle().fill(.white.opacity(focused || open ? 0.26 : 0)) }
                .scaleEffect(focused ? 1.08 : 1)
                .shadow(color: .black.opacity(0.4), radius: 8)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// The 7-bar audio spectrum glyph.
private struct SpectrumGlyph: View {
    private let heights: [CGFloat] = [0.35, 0.7, 1, 0.55, 0.85, 0.45, 0.3]
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().frame(width: 3.5, height: 26 * heights[i])
            }
        }
        .frame(height: 26)
    }
}

private struct JogWheel: View {
    let angle: Double
    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(Palette.focusInk.opacity(0.85), lineWidth: 3).padding(5)
            Circle().fill(Palette.focusInk)
                .frame(width: 9, height: 9)
                .offset(x: 14 * cos(-angle - .pi / 2), y: 14 * sin(-angle - .pi / 2))
        }
        .frame(width: 46, height: 46)
        .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

// MARK: - Track popover

/// 440 pt glass panel above the glyph line; rows 66 pt (7 visible, scrolls);
/// focused row = a white pill slightly wider than the panel. Down off it closes it.
struct TrackPopover: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var subs: SubtitleController
    var focus: FocusState<PlayerFocus?>.Binding

    init(vm: PlayerViewModel, focus: FocusState<PlayerFocus?>.Binding) {
        self.vm = vm
        self.subs = vm.subtitles
        self.focus = focus
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let active: Bool
        let pick: () -> Void
    }

    private var isAudio: Bool { vm.overlay == .audio }

    private var rows: [Row] {
        if isAudio {
            if vm.audioTracks.isEmpty {
                return [Row(id: "none", title: "No tracks in this stream", detail: nil, active: false, pick: {})]
            }
            return vm.audioTracks.map { t in
                Row(id: t.id, title: t.displayName, detail: t.isAtmos ? "Atmos" : nil, active: t.id == vm.selectedAudioID) {
                    vm.selectAudio(t)
                }
            }
        }
        return subs.choices.map { c in
            Row(id: c.id, title: c.title, detail: c.detail, active: c.id == subs.selected.id) { vm.selectSubtitle(c) }
        }
    }

    /// The glyph's centre x (Subtitles is first of 2–3 glyphs at the right end).
    private var anchorX: CGFloat {
        let count: CGFloat = vm.nextVideo != nil && !vm.isLive ? 3 : 2
        let index: CGFloat = isAudio ? 1 : 0
        let right = PlayerTransport.side + PlayerTransport.barWidth
        let firstCentre = right - (count * 62 + (count - 1) * 25) + 31
        return firstCentre + index * 87
    }

    var body: some View {
        let list = rows
        let visible = min(CGFloat(list.count), 7)
        let height = 56 + visible * 66 + 20
        let glyphTop = PlayerTransport.barY - 30 - 62
        VStack(alignment: .leading, spacing: 0) {
            Text(isAudio ? "AUDIO" : "SUBTITLES")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 28)
                .frame(height: 56, alignment: .center)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(list) { r in
                        Button {
                            r.pick()
                            vm.overlay = vm.isPaused ? .pauseInfo : .controls
                            focus.wrappedValue = .glyph(isAudio ? "audio" : "subtitles")
                            vm.scheduleAutoHide()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                                    .opacity(r.active ? 1 : 0)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.system(size: 26, weight: .medium)).lineLimit(1)
                                    if let d = r.detail {
                                        Text(d).font(.system(size: 18, weight: .medium)).opacity(0.6).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(PopoverRowStyle())
                        .focused(focus, equals: .popover(r.id))

                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: visible * 66)
            .padding(.bottom, 20)
        }
        .frame(width: 440, height: height, alignment: .top)
        .background {
            GlassSurface(shape: RoundedRectangle(cornerRadius: 40, style: .continuous), dark: true)
        }
        .offset(x: anchorX + 20 - 440, y: glyphTop - 20 - height)
        .focusSection()
        .onAppear {
            let target = list.first(where: \.active)?.id ?? list.first?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let target { focus.wrappedValue = .popover(target) }
            }
        }
    }
}

private struct PopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 22)
                .frame(height: 66)
                .background { Capsule().fill(focused ? Color.white : .clear).padding(.horizontal, focused ? -8 : 0) }
                .animation(Motion.focus, value: focused)
        }
    }
}

/// The frame under the scrub target, centred over the playhead (Infuse-style),
/// clamped to the bar's ends.
private struct ScrubPreviewImage: View {
    @ObservedObject var previews: ScrubPreviews
    let target: Double
    let duration: Double

    static let size = CGSize(width: 400, height: 225)

    var body: some View {
        if let image = previews.frame(at: target) {
            let fraction = duration > 0 ? min(1, max(0, target / duration)) : 0
            let x = PlayerTransport.side + PlayerTransport.barWidth * fraction - Self.size.width / 2
            let minX = PlayerTransport.side
            let maxX = PlayerTransport.side + PlayerTransport.barWidth - Self.size.width
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .offset(x: min(max(x, minX), maxX), y: PlayerTransport.barY - 40 - Self.size.height)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
