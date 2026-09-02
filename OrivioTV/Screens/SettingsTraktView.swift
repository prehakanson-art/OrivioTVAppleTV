import SwiftUI

/// Settings → Trakt: device-code sign-in, scrobble toggle, and account status.
struct TraktDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var profiles: ProfileStore

    @State private var deviceCode: TraktDeviceCode?
    @State private var polling = false
    @State private var statusMessage: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var showConnect = false
    @State private var confirmClearPlayback = false
    @State private var codeExpiresAt: Date?

    var body: some View {
        DetailScaffold(title: SettingsCategory.trakt.title, subtitle: SettingsCategory.trakt.subtitle) {
            // Shown above BOTH states: a profile that hasn't connected Trakt
            // sees the signed-out view, and this is how someone turns the
            // per-profile behaviour on (or back off) from there. Only worth
            // showing once there is more than one profile.
            if profiles.profiles.count > 1 {
                SettingsToggleCard(
                    title: "Separate Trakt per profile",
                    subtitle: "Each profile connects its own Trakt account here. Profiles that haven't connected one simply have no Trakt — nothing is shared between them. Off: one Trakt account for the whole device.",
                    isOn: Binding(
                        get: { trakt.perProfileAccounts },
                        set: { trakt.perProfileAccounts = $0 }
                    )
                )
                .padding(.bottom, OrivioSpacing.sm)
            }
            if trakt.isSignedIn {
                signedInView
            } else {
                signedOutView
            }
        }
        .onDisappear { pollTask?.cancel() }
        // The device-code QR gets its OWN full-screen page (APK-style) instead
        // of squeezing into the settings pane.
        .fullScreenCover(isPresented: $showConnect) {
            ZStack {
                ATVBackground()
                if let code = deviceCode {
                    TraktConnectPage(code: code, expiresAt: codeExpiresAt ?? Date())
                        // Rebuild when the code changes (auto-refresh) so the QR
                        // + code + countdown all reset to the new code.
                        .id(code.userCode)
                }
            }
            .environmentObject(theme)
            .onExitCommand { cancelConnect() }
        }
    }

    // MARK: Signed in

    private var signedInView: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            HStack(spacing: OrivioSpacing.lg) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(OrivioPrimitives.success)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trakt.username ?? "Connected")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Trakt account linked")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .integrationRowBackground(theme)

            SettingsToggleCard(
                title: "Scrobble playback",
                subtitle: "Automatically mark what you watch on Trakt",
                isOn: $trakt.scrobbleEnabled
            )
            SettingsToggleCard(
                title: "Sync watch history",
                subtitle: "Two-way sync of watched movies & episodes (the ✓ badges) between this app and Trakt",
                isOn: Binding(
                    get: { trakt.syncWatchHistory },
                    set: { trakt.syncWatchHistory = $0; trakt.onTraktSettingChange?() }
                )
            )
            SettingsToggleCard(
                title: "Sync Continue Watching",
                subtitle: "Pull your in-progress movies & episodes from Trakt into the Continue Watching row",
                isOn: Binding(
                    get: { trakt.syncPlayback },
                    set: { trakt.syncPlayback = $0; trakt.onTraktSettingChange?() }
                )
            )
            SettingsToggleCard(
                title: "Sync watchlist",
                subtitle: "Two-way sync between your Library and your Trakt watchlist",
                isOn: Binding(
                    get: { trakt.syncWatchlist },
                    set: { trakt.syncWatchlist = $0; trakt.onTraktSettingChange?() }
                )
            )
            SettingsToggleCard(
                title: "Sync ratings",
                subtitle: "Two-way sync of your 1–10 star ratings with Trakt (rate from any title's page)",
                isOn: Binding(
                    get: { trakt.syncRatings },
                    set: { trakt.syncRatings = $0; trakt.onTraktSettingChange?() }
                )
            )

            Button {
                trakt.onTraktSettingChange?()
                trakt.setSyncStatus("Syncing with Trakt…")
            } label: {
                SettingsActionRow(
                    title: "Sync now",
                    subtitle: trakt.lastSyncStatus ?? "Force a two-way sync with Trakt",
                    leadingIcon: "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            Button { confirmClearPlayback = true } label: {
                SettingsActionRow(
                    title: "Clear Trakt Continue Watching",
                    subtitle: "Empties Trakt's in-progress list — the source of re-imported Continue Watching rows. Your watched history is NOT touched.",
                    leadingIcon: "trash"
                )
            }
            .buttonStyle(PlainCardButtonStyle())
            .alert("Clear Trakt Continue Watching?", isPresented: $confirmClearPlayback) {
                Button("Clear", role: .destructive) {
                    trakt.setSyncStatus("Clearing Trakt continue watching…")
                    trakt.onClearContinueWatching?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every partially-watched row from Trakt's continue-watching list, on Trakt itself. Your Trakt watched history stays exactly as it is. This cannot be undone.")
            }

            Button { trakt.signOut() } label: {
                DestructivePillLabel(title: "Sign Out")
            }
            .buttonStyle(PlainCardButtonStyle())
            .padding(.top, OrivioSpacing.sm)
        }
    }

    // MARK: Signed out

    private var signedOutView: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
            Button(action: startLogin) {
                SettingsActionRow(
                    title: "Login",
                    subtitle: "Sign in with a code on trakt.tv/activate",
                    leadingIcon: "link"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            if let statusMessage {
                Text(statusMessage)
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

    /// Request a fresh device code and (re)start polling. Called on Login and
    /// automatically whenever the current code expires, so a new code always
    /// replaces the old one without leaving the page.
    private func loadCode() async {
        statusMessage = nil
        do {
            let code = try await TraktService.startDeviceCode()
            deviceCode = code
            codeExpiresAt = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            beginPolling(code)
        } catch {
            statusMessage = "Couldn't start Trakt login: \(error.localizedDescription)"
            showConnect = false
        }
    }

    /// Cancel from the QR page (Menu/back): stop polling and close.
    private func cancelConnect() {
        pollTask?.cancel()
        polling = false
        deviceCode = nil
        codeExpiresAt = nil
        showConnect = false
    }

    private func beginPolling(_ code: TraktDeviceCode) {
        polling = true
        pollTask?.cancel()
        pollTask = Task {
            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            while !Task.isCancelled && Date() < deadline {
                let result = await TraktService.pollToken(deviceCode: code.deviceCode, clientSecret: TraktStore.clientSecret)
                switch result {
                case .authorized(let access, let refresh):
                    trakt.markSignedInHere()
                    trakt.store(access: access, refresh: refresh)
                    let name = await TraktService.fetchUsername(accessToken: access)
                    trakt.setUsername(name)
                    polling = false
                    deviceCode = nil
                    codeExpiresAt = nil
                    showConnect = false
                    return
                case .needsSecret:
                    // No client secret configured yet — keep the QR page up and
                    // keep waiting instead of closing it. Wait the poll interval
                    // so we don't spin.
                    try? await Task.sleep(nanoseconds: UInt64(max(code.interval, 5)) * 1_000_000_000)
                case .expired:
                    // Code expired mid-poll: fetch a fresh one and keep going.
                    if !Task.isCancelled && showConnect { await loadCode() }
                    return
                case .failed(let message):
                    polling = false
                    deviceCode = nil
                    codeExpiresAt = nil
                    showConnect = false
                    statusMessage = message
                    return
                case .pending:
                    try? await Task.sleep(nanoseconds: UInt64(max(code.interval, 1)) * 1_000_000_000)
                }
            }
            // Deadline reached without a terminal result → auto-refresh the code
            // (a new one pops up) as long as the page is still open.
            if !Task.isCancelled && showConnect {
                await loadCode()
            }
        }
    }
}

/// A destructive text-pill matching the app's own design system (font,
/// focus ring, capsule fill) instead of tvOS's native bordered button chrome
/// — a bare `Button(role: .destructive)` renders with the system font/style,
/// which looks out of place next to the app's custom controls.
private struct DestructivePillLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isFocused ? .white : OrivioPrimitives.red300)
            .padding(.horizontal, OrivioSpacing.xl)
            .padding(.vertical, OrivioSpacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(isFocused ? OrivioPrimitives.red500 : OrivioPrimitives.red500.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }
}

/// Full-screen Trakt device-code page: big centered QR + code + status, the
/// APK's dedicated login page. Menu/Back cancels (handled by the presenter).
struct TraktConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    let code: TraktDeviceCode
    /// When the current code stops being valid — drives the countdown.
    let expiresAt: Date

    var body: some View {
        VStack(spacing: OrivioSpacing.xl) {
            VStack(spacing: OrivioSpacing.sm) {
                Text("Connect Trakt")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Scan the code with your phone, or go to \(code.verificationURL) and enter the code below.")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            // Scanning opens the Trakt authorize page with the code pre-filled.
            QRCodeView(string: "https://trakt.tv/activate/authorize?user_code=\(code.userCode)", side: 360)

            Text(code.userCode)
                .font(.system(size: 68, weight: .heavy, design: .monospaced))
                .tracking(10)
                .foregroundStyle(theme.palette.secondary)

            HStack(spacing: OrivioSpacing.sm) {
                ProgressView().tint(theme.palette.secondary)
                Text("Waiting for authorization…")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            // Live countdown; a new code is fetched automatically when it hits 0.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = expiresAt.timeIntervalSince(context.date)
                let remaining = seconds.isFinite ? Int(min(max(seconds, 0), 86_400)) : 0
                Text(remaining > 0
                     ? "Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
                     : "Refreshing code…")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            Text("Press Menu to cancel")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .padding(OrivioSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
