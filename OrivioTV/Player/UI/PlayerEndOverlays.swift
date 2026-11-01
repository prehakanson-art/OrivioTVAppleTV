import SwiftUI

/// Layer 14: Up Next, Still watching?, Post-play and Error (§7.16, §16.14).
struct PlayerEndOverlays: View {
    @ObservedObject var vm: PlayerViewModel
    var focus: FocusState<PlayerFocus?>.Binding
    @Environment(\.theme) private var theme

    var body: some View {
        switch vm.overlay {
        case .upNext: upNext.transition(.opacity)
        case .stillWatching: stillWatching.transition(.opacity)
        case .postPlay: postPlay.transition(.opacity)
        case .error(let message): error(message).transition(.opacity)
        default: EmptyView()
        }
    }

    // MARK: Up Next (bottom-right, over the credits)

    private var upNext: some View {
        let next = vm.nextVideo
        return VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 22) {
                        RemoteImage(url: next?.thumbnail, maxPixel: ImageSize.landscape, fallbackURL: vm.meta.background)
                            .frame(width: 300, height: 169)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.stillRadius, style: .continuous))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Up Next").font(.system(size: 24, weight: .bold)).foregroundStyle(theme.accent)
                            Text(next?.seasonEpisodeCode ?? "").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                            Text(next.map { $0.title.isEmpty ? "Episode \($0.episode ?? 0)" : $0.title } ?? "")
                                .font(.system(size: 28, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                    if let r = vm.upNextRemaining {
                        Capsule().fill(.white.opacity(0.2)).frame(width: 360, height: 6)
                            .overlay(alignment: .leading) {
                                Capsule().fill(theme.accent).frame(width: 360, height: 6)
                                    .scaleEffect(x: max(0.001, r / max(vm.upNextTotal, 0.1)), y: 1, anchor: .leading)
                                    .animation(.linear(duration: 0.25), value: r)
                            }
                    }
                    HStack(spacing: 18) {
                        Button { vm.playNext(auto: false) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.fill")
                                Text(vm.upNextRemaining.map { "Play Next Episode · \(Int($0.rounded(.up)))s" } ?? "Play Next Episode")
                                    .monospacedDigit()
                            }
                        }
                        .buttonStyle(PrimaryCapsuleStyle(minWidth: 300))
                        .focused(focus, equals: .button("upnext.play"))
                        .contextMenu {
                            Button("Select Source") { vm.openNextSourcePicker() }
                            Button("Mark as Watched") { vm.markNextWatched() }
                        }
                        Button("Cancel") { vm.cancelUpNext() }
                            .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 30, height: 64))
                            .focused(focus, equals: .button("upnext.cancel"))
                    }
                    .focusSection()
                }
                .padding(32)
                .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 40, style: .continuous), dark: true) }
            }
        }
        .padding(.trailing, 86)
        .padding(.bottom, 80)
        .onAppear { setFocus("upnext.play") }
    }

    // MARK: Still watching?

    private var stillWatching: some View {
        centred {
            Image(systemName: "eye").font(.system(size: 54, weight: .semibold)).foregroundStyle(.white)
            Text("Still watching?").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
            if let n = vm.nextVideo {
                Text("Up next: \(n.episodeLine)").font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                capsule("Continue Watching", id: "still.continue", primary: true) { vm.continueAfterStillWatching() }
                capsule("Exit", id: "still.exit") { vm.exit() }
            }
            .padding(.top, 10)
        }
        .onAppear { setFocus("still.continue") }
    }

    // MARK: Post-play

    private var postPlay: some View {
        centred {
            LogoOrTitle(logo: vm.meta.logo, title: vm.meta.name, maxSize: CGSize(width: 520, height: 180), alignment: .center,
                        fallbackStyle: .pageTitle)
            Text("Finished").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 20) {
                capsule("Replay", id: "post.replay", icon: "arrow.counterclockwise") { vm.replay() }
                capsule("Close", id: "post.close", primary: true) { vm.exit() }
            }
            .padding(.top, 10)
        }
        .onAppear { setFocus("post.close") }
    }

    // MARK: Error

    private func error(_ message: String) -> some View {
        centred {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 54)).foregroundStyle(.yellow)
            Text("Playback Failed").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
            Text(message).font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center).lineLimit(4).frame(maxWidth: 820)
            HStack(spacing: 20) {
                capsule("Try Again", id: "err.retry", primary: true, icon: "arrow.clockwise") { vm.retry() }
                if vm.allEntries.count > 1 {
                    capsule("Other Sources", id: "err.sources") { vm.openPicker(.sources, from: vm.overlay) }
                }
                capsule("Close Player", id: "err.close") { vm.exit() }
            }
            .padding(.top, 10)
        }
        .onAppear { setFocus("err.retry") }
    }

    // MARK: Building blocks

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) { content() }
                .padding(.horizontal, 70)
                .padding(.vertical, 54)
                .frame(minWidth: 760)
                .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 40, style: .continuous), dark: true) }
                .focusSection()
        }
        .frame(width: 1920, height: 1080)
    }

    private func capsule(_ title: String, id: String, primary: Bool = false, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
        }
        .buttonStyle(PrimaryCapsuleStyle(minWidth: 240))
        .focused(focus, equals: .button(id))
    }

    private func setFocus(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus.wrappedValue = .button(id) }
    }
}

// MARK: - Small layers

/// Layer 13: 75 % black + spinner + label.
struct SwitchingCover: View {
    let label: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
            VStack(spacing: 22) {
                ProgressView().scaleEffect(1.6)
                Text(label.isEmpty ? "Switching source…" : label)
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Layer 15: a glass capsule top-right (48 top / 56 right).
struct PlayerToast: View {
    let text: String
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text(text)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 60)
                    .background { GlassSurface(shape: Capsule(), dark: true) }
            }
            Spacer()
        }
        .padding(.top, 48)
        .padding(.trailing, 56)
        .frame(width: 1920, height: 1080)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Layer 16: the running delta of accumulating skips over bare video.
struct QuickSeekHUD: View {
    let delta: Double
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: delta < 0 ? "gobackward" : "goforward").font(.system(size: 34, weight: .semibold))
            Text((delta < 0 ? "−" : "+") + PlayerTransport.shortDelta(abs(delta)))
                .font(.system(size: 34, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 34)
        .frame(height: 84)
        .background { GlassSurface(shape: Capsule(), dark: true) }
        // Inset inside the screen frame: padding outside it made the view
        // 2160 wide, which widened (and shifted) whatever screen it sat in.
        .padding(.horizontal, 120)
        .frame(width: 1920, height: 1080, alignment: delta < 0 ? .leading : .trailing)
        .allowsHitTesting(false)
    }
}

/// Layer 7: the art field, the logo (or title), a spinner, the status and a
/// 320 pt fill bar while preparing.
struct PlayerLoadingBackdrop: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var pulse = false

    var body: some View {
        ZStack {
            ArtField(imageURL: vm.meta.background ?? vm.meta.poster)
            RemoteImage(url: vm.video?.thumbnail ?? vm.meta.background, maxPixel: ImageSize.backdrop, placeholder: false)
                .opacity(0.35)
                .frame(width: 1920, height: 1080)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 34) {
                LogoOrTitle(logo: vm.meta.logo, title: vm.meta.name, maxSize: CGSize(width: 480, height: 270),
                            alignment: .center, fallbackStyle: .heroLogoFallback)
                    .scaleEffect(pulse ? 1.03 : 1)
                if let v = vm.video {
                    Text(v.episodeLine).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                }
                ProgressView().scaleEffect(1.4)
                Text(statusText).font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
                if let p = vm.preparingProgress {
                    ProgressBar(fraction: p).frame(width: 320)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !PerformanceProfile.reduceMotion, PerformanceProfile.isFourGB else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var statusText: String {
        if let p = vm.preparingProgress { return "Preparing video… \(Int(p * 100))%" }
        return vm.loadingStatus.isEmpty ? "Loading…" : vm.loadingStatus
    }
}
