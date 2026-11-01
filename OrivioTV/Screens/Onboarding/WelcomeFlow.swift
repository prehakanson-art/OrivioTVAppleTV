import SwiftUI

/// §16.15 Onboarding: Welcome (slow poster mosaic) → Sign in (QR) → Add
/// add-ons (from phone) → then the profile picker if needed (RootView).
struct WelcomeFlow: View {
    let onDone: () -> Void
    @ObservedObject private var account = OrivioAccount.shared
    @ObservedObject private var hub = SyncHub.shared
    @EnvironmentObject private var addons: AddonManager
    @State private var step: Step = .welcome
    @State private var posters: [String] = []
    @State private var fromPhone = false
    @State private var installed = 0
    @FocusState private var focus: String?

    enum Step { case welcome, signIn, addons }

    var body: some View {
        ZStack {
            Color.clear
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.opacity)
            case .signIn: signIn.transition(.opacity)
            case .addons: addonsStep.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { PosterMosaic(posters: posters) }
        .animation(Motion.pageOpen, value: step)
        .task { await loadPosters() }
        .onChange(of: hub.isSignedIn) { _, signedIn in
            if signedIn, step == .signIn { withAnimation { step = .addons } }
        }
        .fullScreenCover(isPresented: $fromPhone) {
            PhoneInputSheet(title: "Add Add-ons", prompt: "Paste one or more add-on manifest URLs (one per line).", multiline: true) { text in
                Task { installed += await addons.importURLs(text) }
            } onDone: { fromPhone = false }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 30) {
            Spacer()
            Text("Orivio").font(.system(size: 110, weight: .heavy)).tracking(-2)
            Text("Everything you watch, in one place.").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 24) {
                if account.isConfigured {
                    Button("Sign In") {
                        account.startQRLogin()
                        step = .signIn
                    }
                    .buttonStyle(PrimaryCapsuleStyle(minWidth: 320))
                    .focused($focus, equals: "signin")
                }
                Button("Continue Without Account") { step = .addons }
                    .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 34, height: 64))
                    .focused($focus, equals: "skip")
            }
            .padding(.top, 30)
            if !account.isConfigured {
                Text("Accounts aren't configured in this build. You can still use Orivio without one.").textStyle(.cardBody)
            }
            Spacer().frame(height: 140)
        }
        .defaultFocus($focus, account.isConfigured ? "signin" : "skip")
    }

    private var signIn: some View {
        VStack(spacing: 40) {
            HStack(spacing: 90) {
                Group {
                    if let url = account.qrLogin?.webURL, let img = QRCode.image(url) {
                        Image(uiImage: img).interpolation(.none).resizable().frame(width: 360, height: 360)
                    } else {
                        ProgressView().frame(width: 360, height: 360)
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.white))
                VStack(alignment: .leading, spacing: 24) {
                    Text("Sign In to Orivio").font(.system(size: 52, weight: .bold))
                    Text("Scan the code with your phone, or go to").textStyle(.body, color: Palette.textSecondary)
                    Text(account.qrLogin.map { URL(string: $0.webURL)?.host ?? $0.webURL } ?? "…").font(.system(size: 32, weight: .semibold))
                    if let code = account.qrLogin?.code {
                        Text("and enter the code below").textStyle(.body, color: Palette.textSecondary)
                        Text(code).font(.system(size: 64, weight: .bold, design: .monospaced)).tracking(6)
                    }
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(account.errorMessage ?? account.qrLogin?.status ?? "Getting a code…").textStyle(.meta)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            HStack(spacing: 24) {
                Button("Skip for Now") { account.cancelQRLogin(); step = .addons }
                    .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 34, height: 64))
                if account.errorMessage != nil {
                    Button("Get a New Code") { account.startQRLogin() }
                        .buttonStyle(PrimaryCapsuleStyle(minWidth: 280))
                }
            }
        }
        .onExitCommand { account.cancelQRLogin(); step = .welcome }
    }

    private var addonsStep: some View {
        VStack(spacing: 26) {
            Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 60))
            Text("Add add-ons?").font(.system(size: 52, weight: .bold))
            Text("Add-ons bring catalogs and sources into Orivio. Cinemeta and OpenSubtitles are already installed — add more from your phone, or later in Settings → Content.")
                .textStyle(.body, color: Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            if installed > 0 {
                Text("Installed \(installed) add-on\(installed == 1 ? "" : "s") ✓").font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.positive)
            }
            HStack(spacing: 24) {
                Button { fromPhone = true } label: { Label("Add from Phone", systemImage: "iphone") }
                    .buttonStyle(PrimaryCapsuleStyle(minWidth: 320))
                    .focused($focus, equals: "phone")
                Button(installed > 0 ? "Continue" : "Skip") { onDone() }
                    .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 40, height: 64))
            }
            .padding(.top, 20)
        }
        .padding(60)
        .frame(width: 1200)
        .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 40, style: .continuous), dark: true) }
        .defaultFocus($focus, "phone")
    }

    private func loadPosters() async {
        guard posters.isEmpty, let cinemeta = addons.enabled.first(where: \.isCinemeta) ?? addons.enabled.first else { return }
        var urls: [String] = []
        for type in ["movie", "series"] {
            let items = (try? await AddonClient.catalog(cinemeta, type: type, id: "top")) ?? []
            urls += items.compactMap(\.poster).prefix(24)
        }
        posters = urls.shuffled()
    }
}

/// Apple's bundle-banner mosaic: posters drifting slowly on a diagonal.
private struct PosterMosaic: View {
    let posters: [String]
    @State private var drift = false

    var body: some View {
        let columns = 9
        let w: CGFloat = 230, h: CGFloat = 345, gap: CGFloat = 26
        ZStack {
            Color.black
            if !posters.isEmpty {
                VStack(spacing: gap) {
                    ForEach(0..<5, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { col in
                                let url = posters[(row * columns + col) % posters.count]
                                RemoteImage(url: url, maxPixel: PerformanceProfile.isConstrained ? 260 : ImageSize.poster)
                                    .frame(width: w, height: h)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                        .offset(x: row.isMultiple(of: 2) ? 0 : (w + gap) / 2)
                    }
                }
                .rotationEffect(.degrees(-12))
                .offset(x: drift ? -260 : 60, y: drift ? -200 : 40)
                .onAppear {
                    guard !PerformanceProfile.reduceMotion, !PerformanceProfile.isConstrained else { return }
                    withAnimation(.linear(duration: 60).repeatForever(autoreverses: true)) { drift = true }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
