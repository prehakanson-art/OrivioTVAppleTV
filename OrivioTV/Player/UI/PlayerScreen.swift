import SwiftUI
import KSPlayer

enum PlayerFocus: Hashable {
    case catcher
    case bar
    case glyph(String)
    case popover(String)
    case skipIntro
    case pill(InfoTab)
    case row(String)
    case picker(String)
    case button(String)

    var area: PlayerFocusArea {
        switch self {
        case .catcher: return .video
        case .bar: return .bar
        case .glyph: return .glyphs
        case .popover: return .popover
        case .skipIntro: return .skipIntro
        case .pill, .row: return .sheet
        case .picker: return .picker
        case .button: return .overlay
        }
    }
}

/// The player: a full-screen cover over the root. Layers follow §7.8, bottom → top.
struct PlayerScreen: View {
    let request: PlaybackRequest
    @StateObject private var vm: PlayerViewModel
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @FocusState private var focus: PlayerFocus?
    @Environment(\.theme) private var theme

    init(request: PlaybackRequest) {
        self.request = request
        // Returning from Picture in Picture adopts the parked model.
        if let parked = PlayerPresenter.shared.parkedModel as? PlayerViewModel, parked.currentRequest.id == request.id {
            _vm = StateObject(wrappedValue: parked)
        } else {
            _vm = StateObject(wrappedValue: PlayerViewModel(request: request))
        }
    }

    var body: some View {
        ZStack {
            // 1. Black.
            Color.black
            // 2. Video view.
            VideoHost(engineView: vm.engine?.view, vm: vm)
            // 3. Subtitles.
            SubtitleLayer(parts: vm.subtitles.parts, settings: playerSettings.value,
                          bottomInset: 84 + (vm.overlay.transportVisible ? 240 : 0))
                .allowsHitTesting(false)
            // 5. Remote catchers + the invisible focusable catcher button.
            RemoteInputLayer(vm: vm).allowsHitTesting(false)
            catcher
            // 6. Black cover while re-syncing after background.
            if vm.resyncCover { Color.black }
            // 7. Initial loading backdrop / rebuffer spinner.
            if !vm.firstFrameShown { PlayerLoadingBackdrop(vm: vm) }
            else if vm.showRebuffer { ProgressView().scaleEffect(1.6).allowsHitTesting(false) }
            // 8–10. Scrim, scrub HUD, transport.
            if vm.overlay.transportVisible || vm.scrub != nil {
                PlayerTransport(vm: vm, focus: $focus)
                    .transition(.opacity)
            }
            // 11. Full-screen pickers.
            if vm.overlay.isPicker { PlayerPickers(vm: vm, focus: $focus).transition(.opacity) }
            // 12. Info sheet.
            if vm.overlay == .info { PlayerInfoSheet(vm: vm, focus: $focus).transition(.opacity) }
            // 13. Switching source cover.
            if vm.isSwitchingSource, vm.firstFrameShown { SwitchingCover(label: vm.loadingStatus) }
            // 14. Up Next / Still watching / Post-play / Error.
            PlayerEndOverlays(vm: vm, focus: $focus)
            // 15. Toast (top-right).
            if let t = vm.toast { PlayerToast(text: t) }
            // Live TV: channel-change banner (bottom-left).
            if let b = vm.liveBanner, vm.overlay == .none {
                LiveChannelBannerView(banner: b).transition(.opacity).allowsHitTesting(false)
            }
            // 16. Quick-seek HUD.
            if let d = vm.quickSeekHUD, vm.overlay == .none { QuickSeekHUD(delta: d) }
            // 17. Skip Intro pill.
            if vm.showsSkipIntro { skipIntroPill }
            // 18. Exit black cover.
            if vm.exitCover { Color.black }
        }
        .ignoresSafeArea()
        .animation(Motion.chromeIn, value: vm.overlay)
        .onAppear {
            vm.screenVisible = true
            vm.onExit = { PlayerPresenter.shared.request = nil }
            vm.onNowPlayingChanged = { meta, video in NowPlayingReporter.changed(meta: meta, video: video) }
            if vm.started {
                PlayerPresenter.shared.parkedModel = nil
                vm.stopPiP()
            }
            vm.start()
            focus = .catcher
        }
        .onDisappear {
            // SwiftUI can drop and re-add the cover right after presenting it
            // (opening from the TV guide did): a teardown here killed the engine
            // it had just opened and the restart was a no-op — stuck on
            // "Loading". So wait a beat, and only tear down if it stayed gone.
            // Entering PiP dismisses the cover but keeps the session alive.
            vm.screenVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [vm] in
                guard !vm.screenVisible, !vm.exitCover, !vm.pipActive else { return }
                vm.saveProgress(transient: false)
                vm.teardown()
            }
        }
        .onPlayPauseCommand { vm.handle(.playPause(source: "focused")) }
        // Swallow Menu here so the cover never dismisses itself; the ladder decides (deduped with the window catcher).
        .onExitCommand { vm.handle(.menu) }
        .onChange(of: focus) { _, f in
            vm.focusArea = f?.area ?? .video
            vm.noteInteraction()
            // Down off a track popover (onto its glyph) closes it.
            if vm.overlay == .audio || vm.overlay == .subtitles, let f, f.area != .popover {
                let glyph = vm.overlay == .audio ? "audio" : "subtitles"
                vm.overlay = vm.isPaused ? .pauseInfo : .controls
                vm.scheduleAutoHide()
                // The focus engine may skip past the glyph onto the bar; land on the popover's glyph.
                if f == .bar {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .glyph(glyph) }
                }
            }
            if f == nil {
                DispatchQueue.main.async { if focus == nil, let d = defaultFocus { focus = d } }
            }
        }
        .onChange(of: vm.controlsSession) { _, _ in focus = .bar }
        .onChange(of: vm.overlay) { old, new in
            switch new {
            case .none: focus = .catcher
            case .controls, .pauseInfo: if !(old.transportVisible) { focus = .bar }
            case .info: focus = .pill(vm.infoTab)
            default: break
            }
        }
        .onChange(of: vm.requestedFocus) { _, r in
            guard let r else { return }
            switch r {
            case .skipIntro: focus = .skipIntro
            case .bar: focus = .bar
            case .glyphs: focus = .glyph("subtitles")
            case .video: focus = .catcher
            default: break
            }
            vm.requestedFocus = nil
        }
        .onChange(of: playerSettings.value) { _, s in
            (vm.engine as? KSEngine)?.applyNativeTextStyle(s)
        }
    }

    /// Where focus goes when it's lost (nil = the overlay places it itself).
    private var defaultFocus: PlayerFocus? {
        switch vm.overlay {
        case .none: return .catcher
        case .controls, .pauseInfo: return .bar
        case .info: return vm.infoPickerOpen ? nil : .pill(vm.infoTab)
        default: return nil
        }
    }

    /// Owns focus over bare video — without it remote commands stop arriving.
    private var catcher: some View {
        Button(action: {}) { Color.clear.frame(width: 2, height: 2) }
            .buttonStyle(BareFocusStyle())
            .focused($focus, equals: .catcher)
            .opacity(0.01)
            .disabled(vm.overlay != .none)
    }

    private var skipIntroPill: some View {
        let underTransport = vm.overlay.transportVisible
        return VStack {
            Spacer()
            HStack {
                Spacer()
                if underTransport {
                    Label("Skip Intro", systemImage: "playpause.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).frame(height: 64)
                        .glassBackground(Capsule(), dark: true)
                } else {
                    Button { vm.skipIntro() } label: {
                        Label("Skip Intro", systemImage: "forward.end.fill").font(.system(size: 26, weight: .semibold))
                    }
                    .buttonStyle(SkipIntroStyle())
                    .focused($focus, equals: .skipIntro)
                }
            }
            .padding(.trailing, 86)
            .padding(.bottom, underTransport ? 260 : 110)
        }
    }
}

struct SkipIntroStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 28).frame(height: 64)
                .background { if focused { Capsule().fill(.white) } else { GlassSurface(shape: Capsule(), dark: true) } }
                .scaleEffect(focused ? 1.06 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Hosts the engine's video view. Zoom/aspect/shift are a transform that is
/// identity in Fit (a CA transform on the Metal layer breaks direct scan-out).
struct VideoHost: UIViewRepresentable {
    let engineView: UIView?
    @ObservedObject var vm: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ host: UIView, context: Context) {
        // Never reclaim a view the Picture in Picture window is showing: between
        // "will start" and this cover's dismissal an update here would pull it
        // out of the PiP window and leave that window black.
        if let ev = engineView, vm.pipHolds(ev) { return }
        if let ev = engineView, ev.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            ev.frame = host.bounds
            ev.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(ev)
        } else if engineView == nil {
            host.subviews.forEach { $0.removeFromSuperview() }
        }
        guard let ev = engineView else { return }
        switch vm.zoom {
        case .normal: vm.engine?.setContentMode(.scaleAspectFit)
        case .crop: vm.engine?.setContentMode(.scaleAspectFill)
        case .stretch: vm.engine?.setContentMode(.scaleToFill)
        }
        ev.transform = transform(natural: vm.engine?.naturalSize ?? .zero, bounds: host.bounds.size)
    }

    private func transform(natural: CGSize, bounds: CGSize) -> CGAffineTransform {
        guard natural.width > 0, natural.height > 0, bounds.width > 0 else { return .identity }
        var t = CGAffineTransform.identity
        let na = natural.width / natural.height
        let screen = bounds.width / bounds.height
        var shownAspect = na
        if let ar = vm.aspect.ratio, vm.zoom == .normal {
            // Re-shape the fitted picture to the chosen ratio, then re-fit it.
            let sx = ar / na
            let fitted = na >= screen ? CGSize(width: bounds.width, height: bounds.width / na) : CGSize(width: bounds.height * na, height: bounds.height)
            var scaleX = sx, scaleY: CGFloat = 1
            let newW = fitted.width * sx
            if newW > bounds.width { let k = bounds.width / newW; scaleX *= k; scaleY *= k }
            t = t.scaledBy(x: scaleX, y: scaleY)
            shownAspect = ar
        }
        if vm.shift != .none, shownAspect > screen {
            // Park a letterboxed picture against the top or bottom.
            let pictureH = bounds.width / shownAspect
            let bar = (bounds.height - pictureH) / 2
            t = t.translatedBy(x: 0, y: vm.shift == .up ? -bar : bar)
        }
        return t
    }
}

/// Reports every now-playing change (episode advances inside the cover).
@MainActor
enum NowPlayingReporter {
    static func changed(meta: MetaItem, video: MetaVideo?) {
        TopShelfNotifier.contentChanged()
    }
}

/// Channel up/down: the channel, what's on now (with progress) and next.
struct LiveChannelBannerView: View {
    let banner: LiveBanner

    var body: some View {
        let now = Date()
        HStack(spacing: 28) {
            ZStack {
                if let logo = banner.channel.logo {
                    RemoteImage(url: logo, maxPixel: 300, contentMode: .fit, placeholder: false).frame(maxWidth: 150, maxHeight: 84)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 40))
                }
            }
            .frame(width: 190, height: 110)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(banner.channel.name).font(.system(size: 30, weight: .bold)).lineLimit(1)
                    LivePill()
                }
                if let p = banner.now {
                    Text("\(p.title)").font(.system(size: 24, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 12) {
                        Text("\(PlayerTransport.wall.string(from: p.start)) – \(PlayerTransport.wall.string(from: p.end))")
                            .font(.system(size: 20)).foregroundStyle(Palette.textSecondary)
                        ProgressView(value: p.progress(at: now)).tint(Palette.positive).frame(width: 220)
                    }
                } else {
                    Text(banner.channel.group).font(.system(size: 22)).foregroundStyle(Palette.textSecondary)
                }
                if let n = banner.next {
                    Text("Next: \(n.title) · \(PlayerTransport.wall.string(from: n.start))")
                        .font(.system(size: 20)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 1100)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.navBase.opacity(0.8)))
        .glassCard(radius: 28, dark: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 90)
        .padding(.bottom, 80)
    }
}
