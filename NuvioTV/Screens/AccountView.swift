import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: NuvioAccountManager

    var body: some View {
        // Transparent background so the Settings workspace card shows through
        // (this pane is rendered inside that card).
        content
            .padding(.horizontal, NuvioSpacing.huge)
            .padding(.vertical, NuvioSpacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch account.authState {
        case .loading:
            NuvioLoadingView(label: "Loading account")
        case .signedIn(_, let email):
            signedIn(email: email)
        case .signedOut:
            if let qr = account.qrLogin {
                qrLoginView(qr)
            } else {
                signInPrompt
            }
        }
    }

    // MARK: - Signed out

    private var signInPrompt: some View {
        VStack(spacing: NuvioSpacing.xl) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 84))
                .foregroundStyle(theme.palette.secondary)
            Text("Sign in to Orivio")
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Sign in to sync your addons, watch progress and library with your Orivio account.")
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            AccountPrimaryButton(title: "Sign In", systemImage: "qrcode") {
                account.startQRLogin()
            }

            if let error = account.errorMessage {
                errorLabel(error)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func qrLoginView(_ qr: QRLoginState) -> some View {
        HStack(spacing: NuvioSpacing.huge) {
            QRCodeView(string: qr.webURL, side: 360)

            VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                Text("Scan to sign in")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                stepRow(1, "Scan the QR code with your phone camera")
                stepRow(2, "Sign in on the page that opens")
                stepRow(3, "This TV signs in automatically")

                Text(qr.webURL)
                    .font(.system(size: 19, weight: .medium).monospaced())
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520, alignment: .leading)

                HStack(spacing: NuvioSpacing.md) {
                    ProgressView().tint(theme.palette.secondary)
                    Text(qr.statusText)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .padding(.top, NuvioSpacing.sm)

                if let error = account.errorMessage {
                    errorLabel(error)
                }

                AccountPrimaryButton(title: "Cancel", systemImage: "xmark", filled: false) {
                    account.cancelQRLogin()
                }
                .padding(.top, NuvioSpacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .center, spacing: NuvioSpacing.md) {
            Text("\(number)")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.palette.onSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.palette.secondary))
            Text(text)
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.textPrimary)
        }
    }

    // MARK: - Signed in

    private func signedIn(email: String) -> some View {
        VStack(spacing: NuvioSpacing.xl) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(NuvioPrimitives.success)
            Text("Signed in")
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
            Text(email)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)

            // Manual full-account sync, sitting directly under the account it
            // belongs to. Everything syncs automatically every
            // `NuvioSyncManager.autoSyncInterval` seconds; this is for "do it
            // now" after changing something on another device.
            AccountPrimaryButton(
                title: syncing ? "Syncing…" : "Sync Now",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                guard !syncing, let sync else { return }
                syncing = true
                syncStatus = nil
                Task {
                    await sync.syncNow()
                    syncing = false
                    syncStatus = sync.lastSyncError.map { "Sync failed: \($0)" }
                        ?? "Everything synced just now"
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    syncStatus = nil
                }
            }
            .disabled(syncing)

            if let syncStatus {
                Text(syncStatus)
                    .font(.system(size: 20))
                    .foregroundStyle(syncStatus.hasPrefix("Sync failed")
                                     ? NuvioPrimitives.error : theme.palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }

            AccountPrimaryButton(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", filled: false) {
                confirmSignOut = true
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Signing out drops local account state — confirm so a stray click
        // can't log the account out (matches the Android app's dialog).
        .alert("Sign Out?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress, library and add-ons stay on this device, but they'll stop syncing until you sign in again.")
        }
    }

    @State private var confirmSignOut = false
    @State private var syncing = false
    @State private var syncStatus: String?
    private var sync: NuvioSyncManager? { NuvioSyncManager.shared }

    private func errorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(NuvioPrimitives.error)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 640)
    }
}

/// Focusable pill button matching the app's focus visuals.
private struct AccountPrimaryButton: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let systemImage: String
    var filled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountButtonLabel(title: title, systemImage: systemImage, filled: filled)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct AccountButtonLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    let title: String
    let systemImage: String
    let filled: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(filled ? theme.palette.onSecondary : theme.palette.textPrimary)
            .padding(.horizontal, NuvioSpacing.xxl)
            .padding(.vertical, NuvioSpacing.md)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }

    private var background: Color {
        if filled {
            return isFocused ? theme.palette.secondary : theme.palette.secondary.opacity(0.8)
        }
        return isFocused ? theme.palette.focusBackground : .white.opacity(0.12)
    }
}
