import SwiftUI

/// Account → Stremio: QR ("Stremio Link") sign-in and a one-way pull of your
/// Stremio library into Orivio's Library / Continue Watching / Watched. Opened
/// full-screen from the Account settings pane. Mirrors the Trakt flow.
struct StremioAccountView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var stremio: StremioAccountStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore

    var onClose: () -> Void = {}

    @State private var linkCode: StremioLinkCode?
    @State private var showConnect = false
    @State private var pollTask: Task<Void, Never>?
    @State private var status: String?

    var body: some View {
        DetailScaffold(title: "Stremio",
                       subtitle: "Sync your Stremio library, Continue Watching and Watched") {
            if stremio.isSignedIn { signedIn } else { signedOut }
        }
        .onDisappear { pollTask?.cancel() }
        .onExitCommand(perform: onClose)
        .fullScreenCover(isPresented: $showConnect) {
            ZStack {
                theme.palette.background.ignoresSafeArea()
                if let code = linkCode {
                    StremioConnectPage(code: code).id(code.code)
                }
            }
            .environmentObject(theme)
            .onExitCommand { cancelConnect() }
        }
    }

    // MARK: Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
            HStack(spacing: NuvioSpacing.lg) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(NuvioPrimitives.success)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stremio.email ?? "Connected")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Stremio account linked")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .integrationRowBackground(theme)

            Button { Task { await syncNow() } } label: {
                SettingsActionRow(
                    title: "Sync now",
                    subtitle: stremio.isSyncing
                        ? "Syncing…"
                        : (stremio.lastSyncStatus ?? "Pull your library, Continue Watching and Watched from Stremio"),
                    leadingIcon: "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(PlainCardButtonStyle())
            .disabled(stremio.isSyncing)

            Button { stremio.signOut() } label: {
                SettingsActionRow(
                    title: "Disconnect Stremio",
                    subtitle: "Remove this Stremio account from Orivio",
                    leadingIcon: "xmark.circle"
                )
            }
            .buttonStyle(PlainCardButtonStyle())
            .padding(.top, NuvioSpacing.sm)
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
            Button(action: startLogin) {
                SettingsActionRow(
                    title: "Connect Stremio",
                    subtitle: "Scan a QR code with your phone to sign in",
                    leadingIcon: "qrcode"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            if let status {
                Text(status)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
    }

    // MARK: Actions

    private func startLogin() {
        showConnect = true
        Task { await loadCode() }
    }

    private func loadCode() async {
        status = nil
        do {
            let code = try await StremioAccountService.createLink()
            linkCode = code
            beginPolling(code)
        } catch {
            status = "Couldn't start Stremio login."
            showConnect = false
        }
    }

    private func cancelConnect() {
        pollTask?.cancel()
        linkCode = nil
        showConnect = false
    }

    private func beginPolling(_ code: StremioLinkCode) {
        pollTask?.cancel()
        pollTask = Task {
            let deadline = Date().addingTimeInterval(300)   // codes are short-lived
            while !Task.isCancelled && Date() < deadline {
                if case .authorized(let authKey) = await StremioAccountService.readLink(code: code.code) {
                    let user = await StremioAccountService.getUser(authKey: authKey)
                    stremio.signIn(authKey: authKey, user: user)
                    linkCode = nil
                    showConnect = false
                    await syncNow()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Expired without a link → fetch a fresh code while the page is open.
            if !Task.isCancelled && showConnect { await loadCode() }
        }
    }

    private func syncNow() async {
        guard let key = stremio.authKey else { return }
        stremio.setSyncing(true)
        stremio.setStatus("Syncing…")
        let result = await StremioSync.pull(authKey: key, library: library, progress: progress, watched: watched)
        stremio.setStatus(result)
        stremio.setSyncing(false)
    }
}

/// Full-screen QR page for Stremio Link. Menu/Back cancels (handled by presenter).
struct StremioConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    let code: StremioLinkCode

    var body: some View {
        VStack(spacing: NuvioSpacing.xl) {
            VStack(spacing: NuvioSpacing.sm) {
                Text("Connect Stremio")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Scan the code with your phone, or open \(code.link) and sign in to your Stremio account.")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            // The QR encodes the Stremio Link URL; opening it authorizes this code.
            QRCodeView(string: code.link, side: 360)

            Text(code.code)
                .font(.system(size: 64, weight: .heavy, design: .monospaced))
                .tracking(10)
                .foregroundStyle(theme.palette.secondary)

            HStack(spacing: NuvioSpacing.sm) {
                ProgressView().tint(theme.palette.secondary)
                Text("Waiting for authorization…")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            Text("Press Menu to cancel")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .padding(NuvioSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
