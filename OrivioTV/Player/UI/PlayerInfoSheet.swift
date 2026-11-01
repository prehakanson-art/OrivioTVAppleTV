import SwiftUI
import AVKit
import AVFoundation

/// §7.13 swipe-down info sheet: Info · Video · Audio · Subtitles pills over one
/// wide glass card. Rows become focusable on Down from a pill; Up from any row
/// returns to the open tab's pill; a row with a value opens a full-screen picker.
struct PlayerInfoSheet: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var subs: SubtitleController
    @ObservedObject private var settings: PlayerSettingsStore
    var focus: FocusState<PlayerFocus?>.Binding

    @State private var rowsEnabled = false
    @State private var picker: InfoPicker?
    @State private var lastRow: String?

    init(vm: PlayerViewModel, focus: FocusState<PlayerFocus?>.Binding) {
        self.vm = vm
        self.subs = vm.subtitles
        self.settings = vm.settings
        self.focus = focus
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55).ignoresSafeArea()
            if let picker {
                InfusePicker(title: picker.title, rows: pickerRows(picker), focus: focus) { id in
                    apply(picker, id)
                    closePicker()
                }
                .transition(.opacity)
            } else {
                card.transition(.opacity)
            }
        }
        .frame(width: 1920, height: 1080)
        .onChange(of: focus.wrappedValue) { old, new in
            guard picker == nil else { return }
            switch new {
            case .pill(let t)?:
                if case .row? = old {
                    rowsEnabled = false
                    if t != vm.infoTab { focus.wrappedValue = .pill(vm.infoTab) }
                } else if t != vm.infoTab {
                    vm.infoTab = t
                }
            case .row(let id)?:
                lastRow = id
            default: break
            }
        }
        .onChange(of: vm.infoPickerOpen) { _, open in
            if !open, picker != nil { closePicker() }
        }
        .onAppear {
            DispatchQueue.main.async { focus.wrappedValue = .pill(vm.infoTab) }
        }
    }

    private func openPicker(_ p: InfoPicker, from row: String) {
        lastRow = row
        vm.infoPickerOpen = true
        withAnimation(Motion.chromeIn) { picker = p }
    }

    private func closePicker() {
        vm.infoPickerOpen = false
        withAnimation(Motion.chromeOut) { picker = nil }
        let back = lastRow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let back { focus.wrappedValue = .row(back) }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 34) {
            pills
            Group {
                switch vm.infoTab {
                case .info: infoTab
                case .video: videoTab
                case .audio: audioTab
                case .subtitles: subtitlesTab
                }
            }
            .disabled(!rowsEnabled)
            .focusSection()
        }
        .padding(.top, 30)
        .padding(.bottom, 44)
        .padding(.horizontal, 44)
        .frame(width: 1920 - 86 * 2, alignment: .top)
        .background {
            // A solid base under the glass: on a real TV the video read through the sheet.
            RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Palette.navBase.opacity(0.82))
            GlassSurface(shape: RoundedRectangle(cornerRadius: 36, style: .continuous), dark: true)
        }
        .padding(.top, 42)
    }

    private var pills: some View {
        HStack(spacing: 14) {
            ForEach(InfoTab.allCases) { t in
                Button { } label: { Text(t.rawValue) }
                    .buttonStyle(InfoPillStyle(selected: vm.infoTab == t))
                    .focused(focus, equals: .pill(t))
                    .onMoveCommand { dir in
                        guard dir == .down else { return }
                        rowsEnabled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            if let first = firstRow(of: vm.infoTab) { focus.wrappedValue = .row(first) }
                        }
                    }
            }
        }
        .focusSection()
    }

    private func firstRow(of tab: InfoTab) -> String? {
        switch tab {
        case .info: return "source"
        case .video: return "zoom"
        case .audio: return vm.audioTracks.first.map { "audio:\($0.id)" } ?? "sync"
        case .subtitles: return "sub:\(subs.choices.first?.id ?? "none")"
        }
    }

    // MARK: Info tab

    private var infoTab: some View {
        HStack(alignment: .top, spacing: 50) {
            HStack(alignment: .top, spacing: 30) {
                artwork
                VStack(alignment: .leading, spacing: 14) {
                    Text(vm.video.map { $0.title.isEmpty ? vm.meta.name : $0.title } ?? vm.meta.name)
                        .font(.system(size: 27, weight: .bold)).lineLimit(2)
                    if vm.video != nil {
                        Text("\(vm.meta.name) · \(vm.video!.seasonEpisodeCode)")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                    HStack(spacing: 10) {
                        if let r = vm.meta.imdbRating, !r.isEmpty {
                            Text("IMDb").font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.imdb))
                            Text(r).font(.system(size: 21, weight: .semibold))
                        }
                        if let c = vm.meta.certification, !c.isEmpty { OutlinedBadge(text: c) }
                        Text(vm.meta.genres.prefix(3).joined(separator: ", "))
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                    if let synopsis = vm.video?.overview ?? vm.meta.description, !synopsis.isEmpty {
                        Text(synopsis).font(.system(size: 23)).foregroundStyle(.white.opacity(0.85)).lineLimit(4)
                    }
                    WrapLayout(spacing: 10, lineSpacing: 10) {
                        ForEach(infoChips, id: \.self) { chip in
                            Text(chip).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            column("Options", width: 520) {
                InfoRow(id: "source", label: "Source", value: vm.entry.sourceAddonName, focus: focus) {
                    vm.openPicker(.sources, from: .info)
                }
                if vm.meta.isSeries {
                    InfoRow(id: "episodes", label: "Episodes", value: vm.video.map { "Season \($0.season ?? 1)" }, focus: focus) {
                        vm.openPicker(.episodes, from: .info)
                    }
                }
                InfoRow(id: "engine", label: "Engine", value: vm.engineKind.label, focus: focus) {
                    vm.openPicker(.engine, from: .info)
                }
                InfoRow(id: "speed", label: "Playback Speed", value: PlaybackSpeed.label(vm.speed), focus: focus) {
                    vm.openPicker(.speed, from: .info)
                }
                InfoRow(id: "pip", label: "Picture in Picture", value: vm.canPiP ? nil : "via Native engine", focus: focus) {
                    if vm.canPiP { vm.startPiP() } else { vm.switchEngine(.native) }
                }
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        if let still = vm.video?.thumbnail {
            RemoteImage(url: still, maxPixel: ImageSize.landscape, fallbackURL: vm.meta.background)
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous))
        } else {
            RemoteImage(url: vm.meta.poster, maxPixel: ImageSize.poster)
                .frame(width: 168, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var infoChips: [String] {
        var c: [String] = []
        let minutes = vm.duration > 0 ? Int(vm.duration / 60) : (vm.video?.runtime ?? vm.meta.runtimeMinutes)
        if let m = minutes, m > 0 { c.append(m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min") }
        if let y = vm.meta.year { c.append(y) }
        if let s = vm.entry.fileSizeLabel { c.append(s) }
        let v = vm.videoInfo
        if let codec = v.codec { c.append(codec) }
        if let res = v.resolution, res.height > 0 {
            let label = res.width >= 3000 ? "4K" : (res.height >= 1000 ? "1080p" : "\(Int(res.height))p")
            let range = v.isDolbyVision ? " DV" : (v.isHDR ? " HDR" : "")
            c.append("(\(label)\(range))")
        }
        if let a = vm.audioInfo.codec {
            c.append(a + (vm.audioInfo.channels.map { " " + EngineTrack.channelLabel($0) } ?? ""))
        }
        if let b = v.bitrate, b > 0 { c.append(String(format: "%.1f Mbps", Double(b) / 1_000_000)) }
        if let f = v.frameRate, f > 0 { c.append(String(format: "%.3g fps", f)) }
        return c
    }

    // MARK: Video tab

    private var videoTab: some View {
        HStack(alignment: .top, spacing: 40) {
            column("Format", width: 520) {
                let v = vm.videoInfo
                if v.codec == nil && v.resolution == nil {
                    Text("Still identifying the stream…").font(.system(size: 25)).foregroundStyle(.white.opacity(0.6))
                } else {
                    ReadRow(label: "Dynamic Range", value: v.dynamicRange ?? (v.untagged ? "SDR · no colour tags" : "SDR"))
                    if let o = v.output { ReadRow(label: "Output", value: o) }
                    ReadRow(label: "Codec", value: v.codec)
                    ReadRow(label: "Resolution", value: v.resolution.map { "\(Int($0.width))×\(Int($0.height))" })
                    ReadRow(label: "Bit Depth", value: v.bitDepth.map { "\($0)-bit" })
                    ReadRow(label: "Primaries", value: v.primaries)
                    ReadRow(label: "Transfer", value: v.transfer)
                    ReadRow(label: "Frame Rate", value: v.frameRate.map { String(format: "%.3f", $0) })
                    ReadRow(label: "Bitrate", value: v.bitrate.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) })
                }
            }
            column("Options", width: 520) {
                InfoRow(id: "zoom", label: "Zoom Mode", value: vm.zoom.label, focus: focus) { openPicker(.zoom, from: "zoom") }
                InfoRow(id: "aspect", label: "Aspect Ratio", value: vm.aspect.label, focus: focus) { openPicker(.aspect, from: "aspect") }
                InfoRow(id: "shift", label: "Vertical Shift", value: vm.shift.label, focus: focus) { openPicker(.shift, from: "shift") }
                InfoRow(id: "chapters", label: "Chapters", value: "\((vm.engine?.chapters ?? []).count)", focus: focus) {
                    openPicker(.chapters, from: "chapters")
                }
                InfoRow(id: "vspeed", label: "Playback Speed", value: PlaybackSpeed.label(vm.speed), focus: focus) {
                    vm.openPicker(.speed, from: .info)
                }
                ReadRow(label: "Dolby Vision", value: vm.videoInfo.isDolbyVision
                        ? (vm.videoInfo.dvProfile.map { "Profile \($0)" } ?? "Yes")
                        : (DisplayModeManager.shared.supportsDolbyVision ? "Not in this stream" : "Display doesn't support it"))
            }
            column("Status", width: 520) {
                ForEach(vm.cacheStatus, id: \.self) { line in
                    Text(line).font(.system(size: 25, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        .frame(height: 52, alignment: .leading)
                }
            }
        }
    }

    // MARK: Audio tab

    private var audioTab: some View {
        HStack(alignment: .top, spacing: 40) {
            column("Tracks", width: 520) {
                if vm.audioTracks.isEmpty {
                    Text("No tracks in this stream").font(.system(size: 25)).foregroundStyle(.white.opacity(0.6))
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(vm.audioTracks) { t in
                                InfoRow(id: "audio:\(t.id)", label: t.displayName, value: nil, checked: t.id == vm.selectedAudioID, focus: focus) {
                                    vm.selectAudio(t)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 520)
                }
            }
            column("Options", width: 520) {
                InfoRow(id: "sync", label: "Audio Sync", value: AudioSync.label(vm.audioSync), focus: focus) {
                    openPicker(.audioSync, from: "sync")
                }
                InfoRow(id: "speaker", label: "Speaker", value: AudioRoute.name, focus: focus) {
                    AudioRoute.presentPicker()
                }
            }
            column("Format", width: 520) {
                let a = vm.audioInfo
                ReadRow(label: "Codec", value: a.codec.map(AudioRoute.codecName))
                ReadRow(label: "Channels", value: a.channels.map(EngineTrack.channelLabel))
                ReadRow(label: "Atmos", value: a.atmos ?? "Not tagged")
                ReadRow(label: "Output", value: a.output ?? AudioRoute.outputDescription)
                ReadRow(label: "Route", value: AudioRoute.name)
                if let ch = a.channels, ch > 2, AudioRoute.maxChannels <= 2 {
                    ReadRow(label: "Downmix", value: "Folded to stereo in app")
                    ReadRow(label: "Route Limit", value: "Sink advertising stereo")
                    ReadRow(label: "Fix", value: "Power-cycle the receiver")
                }
            }
        }
    }

    // MARK: Subtitles tab

    private var subtitlesTab: some View {
        let s = settings.value
        return HStack(alignment: .top, spacing: 40) {
            column("Tracks", width: 760) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(subs.choices) { c in
                            InfoRow(id: "sub:\(c.id)", label: c.title, value: c.detail, checked: c.id == subs.selected.id, focus: focus) {
                                vm.selectSubtitle(c)
                            }
                        }
                        if !subs.addonsLoaded {
                            Text("Loading add-on subtitles…").font(.system(size: 23)).foregroundStyle(.white.opacity(0.5))
                                .frame(height: 52)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 600)
            }
            column("Options", width: 760) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        InfoRow(id: "reload", label: "Reload Subtitles", value: nil, focus: focus) {
                            Task { await subs.reload(meta: vm.meta, video: vm.video, settings: settings.value) }
                            vm.showToast("Reloading subtitles")
                        }
                        InfoRow(id: "font", label: "Font", value: s.subtitleFont, focus: focus) { openPicker(.font, from: "font") }
                        InfoRow(id: "size", label: "Size", value: "\(Int(s.subtitleSize)) pt", focus: focus) { openPicker(.size, from: "size") }
                        InfoRow(id: "color", label: "Color", value: s.subtitleColor, focus: focus) { openPicker(.color, from: "color") }
                        InfoRow(id: "weight", label: "Weight", value: s.subtitleBold ? "Bold" : "Regular", focus: focus) {
                            settings.value.subtitleBold.toggle()
                        }
                        InfoRow(id: "outline", label: "Outline", value: s.subtitleOutline ? "Bordered" : "Off", focus: focus) {
                            settings.value.subtitleOutline.toggle()
                        }
                        InfoRow(id: "background", label: "Background", value: s.subtitleBackground ? "On" : "Off", focus: focus) {
                            settings.value.subtitleBackground.toggle()
                        }
                        InfoRow(id: "opacity", label: "Opacity", value: "\(Int(s.subtitleBackgroundOpacity * 100))%", focus: focus) {
                            openPicker(.opacity, from: "opacity")
                        }
                        InfoRow(id: "vertical", label: "Vertical Alignment", value: Self.verticalLabel(s.subtitleVerticalOffset), focus: focus) {
                            openPicker(.vertical, from: "vertical")
                        }
                        InfoRow(id: "delay", label: "Delay", value: Self.delayLabel(subs.delay), focus: focus) {
                            openPicker(.delay, from: "delay")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 600)
            }
        }
    }

    static func verticalLabel(_ v: Double) -> String {
        v == 0 ? "Default" : (v > 0 ? "Up \(Int(v))" : "Down \(Int(-v))")
    }

    static func delayLabel(_ v: Double) -> String {
        v == 0 ? "Off" : String(format: "%+.1f s", v)
    }

    // MARK: Pickers

    enum InfoPicker: Equatable {
        case zoom, aspect, shift, chapters, audioSync, font, size, color, opacity, vertical, delay

        var title: String {
            switch self {
            case .zoom: return "Zoom Mode"
            case .aspect: return "Aspect Ratio"
            case .shift: return "Vertical Shift"
            case .chapters: return "Chapters"
            case .audioSync: return "Audio Sync"
            case .font: return "Subtitle Font"
            case .size: return "Subtitle Size"
            case .color: return "Subtitle Color"
            case .opacity: return "Background Opacity"
            case .vertical: return "Vertical Alignment"
            case .delay: return "Subtitle Delay"
            }
        }
    }

    private static let verticalSteps: [Double] = [-40, -20, 0, 20, 40, 60, 80, 100, 120, 140, 160]
    private static let delaySteps: [Double] = stride(from: -5.0, through: 5.0, by: 0.5).map { $0 }
    private static let opacitySteps: [Double] = [0, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 1]

    private func pickerRows(_ p: InfoPicker) -> [InfuseRow] {
        let s = settings.value
        switch p {
        case .zoom: return VideoScaling.allCases.map { InfuseRow(id: $0.rawValue, title: $0.label, checked: vm.zoom == $0) }
        case .aspect: return AspectChoice.allCases.map { InfuseRow(id: $0.rawValue, title: $0.label, checked: vm.aspect == $0) }
        case .shift: return VerticalShift.allCases.map { InfuseRow(id: $0.rawValue, title: $0.label, checked: vm.shift == $0) }
        case .chapters:
            let list = vm.engine?.chapters ?? []
            return list.enumerated().map { i, c in
                let name = c.title.trimmingCharacters(in: .whitespaces).isEmpty ? String(format: "Chapter %02d", i + 1) : c.title
                let current = vm.currentTime >= c.start && vm.currentTime < c.end
                return InfuseRow(id: "\(i)", title: name, subtitle: PlayerTransport.clock(c.start), checked: current)
            }
        case .audioSync: return AudioSync.steps.map { InfuseRow(id: "\($0)", title: AudioSync.label($0), checked: vm.audioSync == $0) }
        case .font: return SubtitleStyle.fonts.map { InfuseRow(id: $0, title: $0, checked: s.subtitleFont == $0) }
        case .size: return SubtitleStyle.sizes.map { InfuseRow(id: "\($0)", title: "\(Int($0)) pt", checked: s.subtitleSize == $0) }
        case .color: return SubtitleStyle.colors.map { InfuseRow(id: $0, title: $0, checked: s.subtitleColor == $0) }
        case .opacity: return Self.opacitySteps.map { InfuseRow(id: "\($0)", title: "\(Int($0 * 100))%", checked: abs(s.subtitleBackgroundOpacity - $0) < 0.01) }
        case .vertical: return Self.verticalSteps.map { InfuseRow(id: "\($0)", title: Self.verticalLabel($0), checked: s.subtitleVerticalOffset == $0) }
        case .delay: return Self.delaySteps.map { InfuseRow(id: "\($0)", title: Self.delayLabel($0), checked: abs(subs.delay - $0) < 0.01) }
        }
    }

    private func apply(_ p: InfoPicker, _ id: String) {
        switch p {
        case .zoom:
            if let z = VideoScaling(rawValue: id) { vm.zoom = z }
        case .aspect:
            if let a = AspectChoice(rawValue: id) { vm.aspect = a }
        case .shift:
            if let s = VerticalShift(rawValue: id) { vm.shift = s }
        case .chapters:
            if let i = Int(id), let c = vm.engine?.chapters[safe: i] { vm.seek(to: c.start) }
        case .audioSync:
            if let v = Double(id) { vm.setAudioSync(v) }
        case .font: settings.value.subtitleFont = id
        case .size: if let v = Double(id) { settings.value.subtitleSize = v }
        case .color: settings.value.subtitleColor = id
        case .opacity: if let v = Double(id) { settings.value.subtitleBackgroundOpacity = v }
        case .vertical: if let v = Double(id) { settings.value.subtitleVerticalOffset = v }
        case .delay:
            if let v = Double(id) {
                subs.delay = v
                settings.value.subtitleDelay = v
            }
        }
    }

    // MARK: Building blocks

    private func column<Content: View>(_ header: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header.uppercased())
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 18)
                .padding(.bottom, 8)
            content()
        }
        .frame(width: width, alignment: .topLeading)
    }
}

private struct InfoRow: View {
    let id: String
    let label: String
    let value: String?
    var checked = false
    var focus: FocusState<PlayerFocus?>.Binding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if checked { Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)) }
                Text(label).lineLimit(1)
                Spacer(minLength: 12)
                if let value { Text(value).lineLimit(1).opacity(0.6) }
            }
            .font(.system(size: 29, weight: .medium))
        }
        .buttonStyle(InfoRowStyle())
        .focused(focus, equals: .row(id))
    }
}

private struct ReadRow: View {
    let label: String
    let value: String?
    var body: some View {
        HStack(spacing: 14) {
            Text(label).foregroundStyle(.white)
            Spacer(minLength: 12)
            Text(value ?? "—").foregroundStyle(.white.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 26, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 52)
    }
}

private struct InfoRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(focused ? Color.white : .clear) }
                .scaleEffect(focused ? 1.02 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

private struct InfoPillStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, selected: selected) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        var body: some View {
            configuration.label
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 30)
                .frame(height: 60)
                .background { Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.24) : .clear)) }
                .scaleEffect(focused ? 1.05 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Wrapping row of chips.
struct WrapLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/// The current audio route (Speaker row) and the AirPlay route picker.
@MainActor
enum AudioRoute {
    static var name: String {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        guard let out else { return "TV" }
        return out.portType == .HDMI ? "TV" : out.portName
    }

    static var maxChannels: Int { AVAudioSession.sharedInstance().maximumOutputNumberOfChannels }

    static var outputDescription: String {
        let ch = maxChannels
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType == .HDMI ? "HDMI" : name
        return ch > 2 ? "Multichannel PCM → \(port)" : "Stereo PCM → \(port)"
    }

    static func codecName(_ c: String) -> String {
        switch c.uppercased() {
        case "E-AC-3", "EAC3": return "Dolby Digital Plus (E-AC-3)"
        case "AC-3", "AC3": return "Dolby Digital (AC-3)"
        case "TRUEHD": return "Dolby TrueHD"
        case "DTS": return "DTS"
        case "AAC": return "AAC"
        default: return c
        }
    }

    private static var routeView: AVRoutePickerView?

    /// Opens the system AirPlay picker from a plain row.
    static func presentPicker() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let v = routeView ?? AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        routeView = v
        if v.superview == nil { window.addSubview(v) }
        if let button = v.subviews.compactMap({ $0 as? UIButton }).first {
            button.sendActions(for: .primaryActionTriggered)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
