import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var stremio: StremioAccountStore
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var plugins: PluginStore

    private enum AccountFocus: Hashable {
        case orivioSignIn
        case stremioSignIn
        case cancelOrivioSignIn
        case mergeSync
        case pullUpdates
        case pushDevice
        case stremioSync
        case stremioDisconnect
        case syncPanel
        case clearLog
        case exportBackup
        case importBackup
        case providerCheck
        case signOut
        case navOrivio
        case navStremio
        case navSync
        case navBackups
    }

    private enum AccountSection: CaseIterable {
        case orivio
        case stremio
        case sync
        case backups

        var title: String {
            switch self {
            case .orivio: return "Orivio"
            case .stremio: return "Stremio"
            case .sync: return "Sync"
            case .backups: return "Backups"
            }
        }

        var subtitle: String {
            switch self {
            case .orivio: return "Account sign-in"
            case .stremio: return "Stremio Link"
            case .sync: return "Status and actions"
            case .backups: return "Local safety copy"
            }
        }

        var icon: String {
            switch self {
            case .orivio: return "person.crop.circle"
            case .stremio: return "link.circle"
            case .sync: return "arrow.triangle.2.circlepath"
            case .backups: return "archivebox"
            }
        }

        var focus: AccountFocus {
            switch self {
            case .orivio: return .navOrivio
            case .stremio: return .navStremio
            case .sync: return .navSync
            case .backups: return .navBackups
            }
        }
    }

    @FocusState private var focusedControl: AccountFocus?
    @State private var selectedSection: AccountSection = .orivio

    var body: some View {
        // Transparent background so the Settings workspace card shows through
        // (this pane is rendered inside that card).
        content
            .padding(.horizontal, NuvioSpacing.huge)
            .padding(.vertical, NuvioSpacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { stremioPollTask?.cancel() }
            .onChange(of: focusedControl, correctSkippedFocus)
            .fullScreenCover(isPresented: $showStremioConnect) {
                ZStack {
                    theme.palette.background.ignoresSafeArea()
                    if let code = stremioLinkCode {
                        StremioConnectPage(code: code, status: stremioConnectStatus).id(code.code)
                    }
                }
                .environmentObject(theme)
                .onExitCommand { cancelStremioConnect() }
            }
            .fullScreenCover(isPresented: $showBackupExport) {
                AccountBackupExportView(text: backupText, onDone: { showBackupExport = false })
                    .environmentObject(theme)
            }
            .fullScreenCover(isPresented: $showBackupImport) {
                AccountBackupImportView(
                    text: $backupImportText,
                    status: backupImportStatus,
                    importing: importingBackup,
                    onImport: importBackup,
                    onDone: { showBackupImport = false }
                )
                .environmentObject(theme)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch account.authState {
        case .loading:
            NuvioLoadingView(label: "Loading account")
        case .signedIn(_, let email):
            accountShell(orivioEmail: email)
        case .signedOut:
            if let qr = account.qrLogin {
                qrLoginView(qr)
            } else {
                accountShell(orivioEmail: nil)
            }
        }
    }

    // MARK: - Account shell

    private func accountShell(orivioEmail: String?) -> some View {
        HStack(spacing: NuvioSpacing.xl) {
            accountNavigationRail(orivioEmail: orivioEmail)
                .frame(width: 360)

            accountDetailPane(orivioEmail: orivioEmail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncLog = NuvioSyncDiagnostics.entries()
            focusedControl = selectedSection.focus
        }
        .alert("Sign Out?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress, library and add-ons stay on this device, but they'll stop syncing until you sign in again.")
        }
    }

    private func accountNavigationRail(orivioEmail: String?) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Accounts")
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(accountRailSubtitle(orivioEmail: orivioEmail))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
            }
            .padding(.bottom, NuvioSpacing.md)

            ForEach(AccountSection.allCases, id: \.self) { section in
                AccountNavRow(
                    title: section.title,
                    subtitle: section.subtitle,
                    systemImage: section.icon,
                    selected: selectedSection == section,
                    action: {
                        selectedSection = section
                        focusedControl = section.focus
                    }
                )
                .focused($focusedControl, equals: section.focus)
            }

            Spacer(minLength: NuvioSpacing.md)

            VStack(alignment: .leading, spacing: 8) {
                AccountRailStatus(title: "Orivio", value: orivioEmail ?? "Not connected", connected: orivioEmail != nil)
                AccountRailStatus(title: "Stremio", value: stremio.isSignedIn ? (stremio.email ?? "Connected") : "Not connected", connected: stremio.isSignedIn)
            }
        }
        .padding(NuvioSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(NuvioPrimitives.neutral750.opacity(0.65), lineWidth: 1)
        )
        .focusSection()
    }

    @ViewBuilder
    private func accountDetailPane(orivioEmail: String?) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(selectedSection.title, systemImage: selectedSection.icon)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(detailSubtitle(orivioEmail: orivioEmail))
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            switch selectedSection {
            case .orivio:
                orivioAccountDetail(orivioEmail: orivioEmail)
            case .stremio:
                stremioConnectionCard
            case .sync:
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                        syncActions
                        syncStatusPanel
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.bottom, NuvioSpacing.xxl)
                }
                .focusSection()
            case .backups:
                backupActions
            }
        }
        .padding(NuvioSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.background.opacity(0.24))
        )
        .focusSection()
    }

    private func accountRailSubtitle(orivioEmail: String?) -> String {
        switch (orivioEmail != nil, stremio.isSignedIn) {
        case (true, true): return "Orivio and Stremio connected"
        case (true, false): return "Orivio connected"
        case (false, true): return "Stremio connected"
        case (false, false): return "No accounts connected"
        }
    }

    private func detailSubtitle(orivioEmail: String?) -> String {
        switch selectedSection {
        case .orivio:
            return orivioEmail == nil
                ? "Sign in with QR to sync this Apple TV with your Orivio account."
                : "Signed in as \(orivioEmail ?? "Orivio account")."
        case .stremio:
            return "Connect Stremio Link and keep Stremio data merged into this app."
        case .sync:
            return "Run account sync actions and inspect the latest sync state without leaving this page."
        case .backups:
            return "Export or import a local backup for add-ons, plugins, library, progress, and watched state."
        }
    }

    private func orivioAccountDetail(orivioEmail: String?) -> some View {
        accountConnectionCard(
            title: "Orivio",
            subtitle: orivioEmail == nil
                ? "Sync add-ons, profiles, settings, library, watched, and Continue Watching with your Orivio account."
                : "Full account sync runs automatically while the app is open and not playing video.",
            status: orivioEmail == nil ? "Not connected" : "Connected",
            icon: orivioEmail == nil ? "person.crop.circle.badge.plus" : "checkmark.circle.fill"
        ) {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                if let orivioEmail {
                    Text(orivioEmail)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    AccountPrimaryButton(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", filled: false) {
                        confirmSignOut = true
                    }
                    .focused($focusedControl, equals: .signOut)
                } else {
                    AccountPrimaryButton(title: "Sign In", systemImage: "qrcode") {
                        account.startQRLogin()
                    }
                    .focused($focusedControl, equals: .orivioSignIn)

                    if let error = account.errorMessage {
                        errorLabel(error)
                    }
                }
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    private var syncActions: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            AccountPrimaryButton(
                title: syncing ? "Syncing..." : "Merge Sync",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                runSyncAction(label: "Merge sync") { sync in
                    await sync.syncNow()
                }
            }
            .focused($focusedControl, equals: .mergeSync)

            HStack(spacing: NuvioSpacing.md) {
                AccountPrimaryButton(title: "Pull Updates", systemImage: "arrow.down.circle", filled: false) {
                    runSyncAction(label: "Pull updates") { sync in
                        await sync.pullAccountUpdates()
                    }
                }
                .focused($focusedControl, equals: .pullUpdates)

                AccountPrimaryButton(title: "Push Device", systemImage: "arrow.up.circle", filled: false) {
                    runSyncAction(label: "Device push") { sync in
                        await sync.pushThisDevice()
                    }
                }
                .focused($focusedControl, equals: .pushDevice)
            }

            if let syncStatus {
                Text(syncStatus)
                    .font(.system(size: 20))
                    .foregroundStyle(syncStatus.hasPrefix("Sync failed")
                                     ? NuvioPrimitives.error : theme.palette.textTertiary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .padding(NuvioSpacing.xl)
        .frame(maxWidth: 980, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(NuvioPrimitives.neutral750.opacity(0.65), lineWidth: 1)
        )
        .focusSection()
    }

    private var backupActions: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
            HStack(spacing: NuvioSpacing.md) {
                AccountPrimaryButton(title: "Export Backup", systemImage: "square.and.arrow.up", filled: false) {
                    backupText = NuvioLocalBackupService.exportBackup(
                        addonManager: addonManager,
                        plugins: plugins,
                        library: library,
                        progress: progress,
                        watched: watched
                    ) ?? ""
                    showBackupExport = true
                }
                .focused($focusedControl, equals: .exportBackup)

                AccountPrimaryButton(title: "Import Backup", systemImage: "square.and.arrow.down", filled: false) {
                    backupImportText = ""
                    backupImportStatus = nil
                    showBackupImport = true
                }
                .focused($focusedControl, equals: .importBackup)
            }

            Text("Backups stay local and do not include provider credentials or account tokens.")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: 780, alignment: .leading)
        }
        .padding(NuvioSpacing.xl)
        .frame(maxWidth: 980, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(NuvioPrimitives.neutral750.opacity(0.65), lineWidth: 1)
        )
        .focusSection()
    }

    private var signInPrompt: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: NuvioSpacing.xl) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 76))
                    .foregroundStyle(theme.palette.secondary)
                Text("Accounts")
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Connect Orivio, Stremio, or both. When both are connected, this device merges matching data and syncs the combined add-ons, library, watched state, and Continue Watching into Orivio.")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 880)

                VStack(spacing: NuvioSpacing.lg) {
                    accountConnectionCard(
                        title: "Orivio",
                        subtitle: "Sync add-ons, profiles, settings, library, watched, and Continue Watching with your Orivio account.",
                        status: "Not connected",
                        icon: "person.crop.circle.badge.plus"
                    ) {
                        AccountPrimaryButton(title: "Sign In", systemImage: "qrcode") {
                            account.startQRLogin()
                        }
                        .focused($focusedControl, equals: .orivioSignIn)
                    }

                    stremioConnectionCard
                }
                .frame(maxWidth: 980)
                .focusSection()

                if let error = account.errorMessage {
                    errorLabel(error)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NuvioSpacing.xxl)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focusedControl = .orivioSignIn }
    }

    private func accountConnectionCard<Controls: View>(
        title: String,
        subtitle: String,
        status: String,
        icon: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            HStack(alignment: .top, spacing: NuvioSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
                    .frame(width: 46)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: NuvioSpacing.sm) {
                        Text(title)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(status)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.palette.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule(style: .continuous).fill(theme.palette.background.opacity(0.65)))
                    }
                    Text(subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NuvioSpacing.md)
            }

            controls()
                .padding(.leading, 62)
        }
        .padding(NuvioSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(NuvioPrimitives.neutral750.opacity(0.65), lineWidth: 1)
        )
    }

    private var stremioConnectionCard: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
            HStack(alignment: .top, spacing: NuvioSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(theme.palette.secondary.opacity(0.18))
                    Image(systemName: stremio.isSignedIn ? "link.circle.fill" : "link.badge.plus")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(theme.palette.secondary)
                }
                .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: NuvioSpacing.sm) {
                        Text("Stremio")
                            .font(.system(size: 31, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(stremio.isSignedIn ? "Connected" : "Optional")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(stremio.isSignedIn ? NuvioPrimitives.success : theme.palette.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill((stremio.isSignedIn ? NuvioPrimitives.success : theme.palette.textTertiary).opacity(0.16))
                            )
                    }

                    Text(stremio.isSignedIn ? (stremio.email ?? "Stremio account linked") : "Connect with Stremio Link to bring over add-ons, saved library, watched movies, and Continue Watching.")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: NuvioSpacing.md)
            }

            HStack(spacing: NuvioSpacing.sm) {
                AccountMetricPill(title: "Add-ons", value: "\(addonManager.addons.count)", systemImage: "puzzlepiece.extension")
                AccountMetricPill(title: "Library", value: "\(library.items.count)", systemImage: "bookmark")
                AccountMetricPill(title: "Continue", value: "\(progress.continueWatching.count)", systemImage: "play.rectangle")
                AccountMetricPill(title: "Watched", value: "\(watched.items.count)", systemImage: "checkmark.seal")
            }

            VStack(alignment: .leading, spacing: NuvioSpacing.sm) {
                HStack(spacing: NuvioSpacing.md) {
                    if stremio.isSignedIn {
                        AccountPrimaryButton(
                            title: stremio.isSyncing ? "Syncing..." : "Sync Stremio",
                            systemImage: "arrow.triangle.2.circlepath",
                            filled: false
                        ) {
                            syncStremioNow()
                        }
                        .focused($focusedControl, equals: .stremioSync)

                        AccountPrimaryButton(title: "Disconnect", systemImage: "xmark.circle", filled: false) {
                            stremio.signOut()
                            focusedControl = .stremioSignIn
                        }
                        .focused($focusedControl, equals: .stremioDisconnect)
                    } else {
                        AccountPrimaryButton(title: "Connect Stremio", systemImage: "qrcode", filled: false) {
                            startStremioLogin()
                        }
                        .focused($focusedControl, equals: .stremioSignIn)
                    }
                }

                if let status = stremioStatus ?? stremio.lastSyncStatus {
                    Text(status)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(status.hasPrefix("Couldn't") ? NuvioPrimitives.error : theme.palette.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(NuvioSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stremio.isSignedIn ? NuvioPrimitives.success.opacity(0.45) : NuvioPrimitives.neutral750.opacity(0.65), lineWidth: 1)
        )
        .focusSection()
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
                .focused($focusedControl, equals: .cancelOrivioSignIn)
                .padding(.top, NuvioSpacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .onAppear { focusedControl = .cancelOrivioSignIn }
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: NuvioSpacing.xl) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(NuvioPrimitives.success)
                Text("Signed in")
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(email)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)

                stremioConnectionCard
                    .frame(maxWidth: 980)

                // Manual full-account sync, sitting directly under the account it
                // belongs to. Everything syncs automatically every
                // `NuvioSyncManager.autoSyncInterval` seconds; this is for "do it
                // now" after changing something on another device.
                AccountPrimaryButton(
                    title: syncing ? "Syncing..." : "Merge Sync",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    runSyncAction(label: "Merge sync") { sync in
                        await sync.syncNow()
                    }
                }
                .focused($focusedControl, equals: .mergeSync)

                HStack(spacing: NuvioSpacing.md) {
                    AccountPrimaryButton(title: "Pull Updates", systemImage: "arrow.down.circle", filled: false) {
                        runSyncAction(label: "Pull updates") { sync in
                            await sync.pullAccountUpdates()
                        }
                    }
                    .focused($focusedControl, equals: .pullUpdates)

                    AccountPrimaryButton(title: "Push Device", systemImage: "arrow.up.circle", filled: false) {
                        runSyncAction(label: "Device push") { sync in
                            await sync.pushThisDevice()
                        }
                    }
                    .focused($focusedControl, equals: .pushDevice)
                }

                if let syncStatus {
                    Text(syncStatus)
                        .font(.system(size: 20))
                        .foregroundStyle(syncStatus.hasPrefix("Sync failed")
                                         ? NuvioPrimitives.error : theme.palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                }

                syncStatusPanel

                HStack(spacing: NuvioSpacing.md) {
                    AccountPrimaryButton(title: "Export Backup", systemImage: "square.and.arrow.up", filled: false) {
                        backupText = NuvioLocalBackupService.exportBackup(
                            addonManager: addonManager,
                            plugins: plugins,
                            library: library,
                            progress: progress,
                            watched: watched
                        ) ?? ""
                        showBackupExport = true
                    }
                    .focused($focusedControl, equals: .exportBackup)

                    AccountPrimaryButton(title: "Import Backup", systemImage: "square.and.arrow.down", filled: false) {
                        backupImportText = ""
                        backupImportStatus = nil
                        showBackupImport = true
                    }
                    .focused($focusedControl, equals: .importBackup)
                }

                AccountPrimaryButton(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right", filled: false) {
                    confirmSignOut = true
                }
                .focused($focusedControl, equals: .signOut)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NuvioSpacing.xxl)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncLog = NuvioSyncDiagnostics.entries()
            focusedControl = stremio.isSignedIn ? .stremioSync : .stremioSignIn
        }
        // Signing out drops local account state — confirm so a stray click
        // can't log the account out (matches the Android app's dialog).
        .alert("Sign Out?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { account.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your watch progress, library and add-ons stay on this device, but they'll stop syncing until you sign in again.")
        }
        .fullScreenCover(isPresented: $showBackupExport) {
            AccountBackupExportView(text: backupText, onDone: { showBackupExport = false })
                .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showBackupImport) {
            AccountBackupImportView(
                text: $backupImportText,
                status: backupImportStatus,
                importing: importingBackup,
                onImport: importBackup,
                onDone: { showBackupImport = false }
            )
            .environmentObject(theme)
        }
    }

    @State private var confirmSignOut = false
    @State private var syncing = false
    @State private var syncStatus: String?
    @State private var syncLog: [NuvioSyncLogEntry] = []
    @State private var providerStatus: String?
    @State private var checkingProviders = false
    @State private var showBackupExport = false
    @State private var showBackupImport = false
    @State private var backupText = ""
    @State private var backupImportText = ""
    @State private var backupImportStatus: String?
    @State private var importingBackup = false
    @State private var showStremioConnect = false
    @State private var stremioLinkCode: StremioLinkCode?
    @State private var stremioPollTask: Task<Void, Never>?
    @State private var stremioConnectStatus = "Starting sign-in..."
    @State private var stremioStatus: String?
    private var sync: NuvioSyncManager? { NuvioSyncManager.shared }

    private var syncStatusPanel: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            HStack {
                Label("Sync Status", systemImage: "checklist.checked")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                Text(sync?.isSyncing == true ? "Running" : "Idle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(sync?.isSyncing == true ? theme.palette.secondary : theme.palette.textTertiary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NuvioSpacing.md), count: 2), spacing: NuvioSpacing.md) {
                AccountSyncStatusRow(title: "Profile", value: activeProfileName, systemImage: "person.crop.circle")
                AccountSyncStatusRow(title: "Add-ons", value: "\(addonManager.addons.count) installed", systemImage: "puzzlepiece.extension")
                AccountSyncStatusRow(title: "Library", value: "\(library.items.count) saved", systemImage: "bookmark")
                AccountSyncStatusRow(title: "Continue Watching", value: "\(progress.continueWatching.count) active", systemImage: "play.rectangle")
                AccountSyncStatusRow(title: "Watched", value: "\(watched.items.count) marked", systemImage: "checkmark.seal")
                AccountSyncStatusRow(title: "Stremio", value: stremio.isSignedIn ? (stremio.email ?? "Connected") : "Not connected", systemImage: "link")
                AccountSyncStatusRow(title: "Trakt", value: trakt.isSignedIn ? (trakt.username ?? "Connected") : "Not connected", systemImage: "checkmark.seal.fill")
                AccountSyncStatusRow(title: "Debrid", value: debridProvidersLabel, systemImage: "key")
                AccountSyncStatusRow(title: "Plugins", value: "\(plugins.repositories.count) repos, \(plugins.enabledScrapers.count) enabled", systemImage: "shippingbox")
                AccountSyncStatusRow(title: "Pending Queue", value: pendingQueueLabel, systemImage: "tray.and.arrow.up")
                AccountSyncStatusRow(title: "Last Error", value: sync?.lastSyncError ?? "None", systemImage: "exclamationmark.triangle")
            }

            if !syncLog.isEmpty {
                VStack(alignment: .leading, spacing: NuvioSpacing.sm) {
                    HStack {
                        Text("Recent Events")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Spacer()
                        AccountMiniButton(title: "Clear", systemImage: "trash") {
                            NuvioSyncDiagnostics.clear()
                            syncLog = []
                            focusedControl = .syncPanel
                        }
                        .focused($focusedControl, equals: .clearLog)
                    }

                    ForEach(syncLog.prefix(6)) { entry in
                        AccountSyncLogRow(entry: entry)
                    }
                }
                .padding(.top, NuvioSpacing.sm)
            }

            Button {
                Task { await runProviderCheck() }
            } label: {
                SettingsActionRow(
                    title: checkingProviders ? "Checking Providers" : "Run Provider Check",
                    subtitle: providerStatus ?? "Check add-on manifests, plugin repositories, Trakt and debrid setup",
                    leadingIcon: "waveform.path.ecg"
                )
            }
            .buttonStyle(PlainCardButtonStyle())
            .focused($focusedControl, equals: .providerCheck)
        }
        .padding(NuvioSpacing.xl)
        .frame(maxWidth: 980)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.palette.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    focusedControl == .syncPanel ? theme.palette.focusRing : NuvioPrimitives.neutral750.opacity(0.65),
                    lineWidth: focusedControl == .syncPanel ? 3 : 1
                )
        )
        .focusable()
        .focused($focusedControl, equals: .syncPanel)
        .focusSection()
    }

    private var activeProfileName: String {
        profiles.profiles.first { $0.id == profiles.activeProfileID }?.name ?? "Profile \(profiles.activeProfileID)"
    }

    private var debridProvidersLabel: String {
        let providers = debrid.configuredProviders.map(\.displayName)
        return providers.isEmpty ? "None configured" : providers.joined(separator: ", ")
    }

    private var pendingQueueLabel: String {
        guard let counts = sync?.pendingSyncCounts else { return "Unavailable" }
        guard counts.total > 0 else { return "Empty" }
        return "\(counts.progressDeletes) progress, \(counts.libraryDeletes) library, \(counts.watchedDeletes) watched"
    }

    private func correctSkippedFocus(_ oldFocus: AccountFocus?, _ newFocus: AccountFocus?) {
        guard let newFocus else { return }
        if let section = railSection(for: newFocus), selectedSection != section {
            selectedSection = section
        }
    }

    private func railSection(for focus: AccountFocus?) -> AccountSection? {
        switch focus {
        case .navOrivio: return .orivio
        case .navStremio: return .stremio
        case .navSync: return .sync
        case .navBackups: return .backups
        default: return nil
        }
    }

    private func startStremioLogin() {
        stremioStatus = nil
        stremioConnectStatus = "Starting sign-in..."
        showStremioConnect = true
        Task { await loadStremioCode() }
    }

    private func loadStremioCode() async {
        do {
            let code = try await StremioAccountService.createLink()
            stremioLinkCode = code
            stremioConnectStatus = "Waiting for authorization..."
            beginStremioPolling(code)
        } catch {
            stremioStatus = "Couldn't start Stremio login."
            showStremioConnect = false
        }
    }

    private func beginStremioPolling(_ code: StremioLinkCode) {
        stremioPollTask?.cancel()
        stremioPollTask = Task {
            let deadline = Date().addingTimeInterval(300)
            while !Task.isCancelled && Date() < deadline {
                switch await StremioAccountService.readLink(code: code.code) {
                case .pending:
                    stremioConnectStatus = "Waiting for authorization..."
                case .authorized(let authKey):
                    stremioConnectStatus = "Authorized. Syncing your account..."
                    let user = await StremioAccountService.getUser(authKey: authKey)
                    stremio.signIn(authKey: authKey, user: user)
                    stremioLinkCode = nil
                    showStremioConnect = false
                    syncStremioNow()
                    focusedControl = .stremioSync
                    return
                case .failed(let message):
                    stremioStatus = message
                    stremioConnectStatus = message
                    stremioLinkCode = nil
                    showStremioConnect = false
                    focusedControl = .stremioSignIn
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if !Task.isCancelled && showStremioConnect { await loadStremioCode() }
        }
    }

    private func cancelStremioConnect() {
        stremioPollTask?.cancel()
        stremioLinkCode = nil
        showStremioConnect = false
        focusedControl = .stremioSignIn
    }

    private func syncStremioNow() {
        if let manager = StremioSyncManager.shared {
            manager.syncNow(reason: "Manual Stremio sync")
            focusedControl = .stremioSync
            return
        }

        guard let key = stremio.authKey else { return }
        stremio.setSyncing(true)
        stremio.setStatus("Syncing...")
        Task {
            let result = await StremioSync.pull(
                authKey: key,
                addonManager: addonManager,
                library: library,
                progress: progress,
                watched: watched
            )
            stremio.setStatus(result)
            stremio.setSyncing(false)
            focusedControl = .stremioSync
        }
    }

    private func runProviderCheck() async {
        guard !checkingProviders else { return }
        focusedControl = .providerCheck
        checkingProviders = true
        defer {
            checkingProviders = false
            focusedControl = .providerCheck
        }

        let addonResults = await addonManager.healthCheck()
        let addonFailures = addonResults.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let addonSlow = addonResults.filter { $0.status == .slow }.count

        let pluginFailures = await pluginManifestFailures()
        let traktStatus = trakt.isSignedIn ? "Trakt connected" : "Trakt off"
        let debridStatus = debrid.configuredProviders.isEmpty
            ? "no debrid"
            : "\(debrid.configuredProviders.count) debrid"

        providerStatus = "\(addonFailures) addon failed, \(addonSlow) slow · \(pluginFailures) plugin repo failed · \(traktStatus) · \(debridStatus)"
        NuvioSyncDiagnostics.record(.info, area: "Health", providerStatus ?? "Provider check finished.")
        syncLog = NuvioSyncDiagnostics.entries()
    }

    private func runSyncAction(label: String, action: @escaping (NuvioSyncManager) async -> Void) {
        guard !syncing, let sync else { return }
        syncing = true
        syncStatus = nil
        Task {
            await action(sync)
            syncing = false
            syncStatus = sync.lastSyncError.map { "\(label) failed: \($0)" }
                ?? "\(label) finished"
            syncLog = NuvioSyncDiagnostics.entries()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            syncStatus = nil
        }
    }

    private func pluginManifestFailures() async -> Int {
        var failures = 0
        for repo in plugins.repositories where repo.enabled {
            guard let url = URL(string: repo.url) else {
                failures += 1
                continue
            }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(code) { failures += 1 }
            } catch {
                failures += 1
            }
        }
        return failures
    }

    private func importBackup() {
        guard !importingBackup else { return }
        importingBackup = true
        backupImportStatus = "Importing..."
        Task {
            let result = await NuvioLocalBackupService.importBackup(
                backupImportText,
                addonManager: addonManager,
                plugins: plugins,
                library: library,
                progress: progress,
                watched: watched
            )
            backupImportStatus = result
            importingBackup = false
        }
    }

    private func errorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(NuvioPrimitives.error)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 640)
    }
}

private struct AccountNavRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    private var navBackground: Color {
        if isFocused { return theme.palette.focusBackground.opacity(0.55) }
        if selected { return theme.palette.secondary.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: NuvioSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(selected || isFocused ? theme.palette.secondary : theme.palette.textTertiary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, NuvioSpacing.lg)
        .padding(.trailing, NuvioSpacing.md)
        .frame(height: 68)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(navBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing.opacity(0.75) : .clear, lineWidth: 2)
        )
        .overlay(alignment: .leading) {
            if selected || isFocused {
                Capsule(style: .continuous)
                    .fill(theme.palette.secondary.opacity(isFocused ? 0.9 : 0.5))
                    .frame(width: 3, height: 30)
                    .padding(.leading, 6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
        .focusable(true, interactions: .activate)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .animation(.easeInOut(duration: 0.14), value: isFocused)
        .animation(.easeInOut(duration: 0.14), value: selected)
    }
}

private struct AccountRailStatus: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let value: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? NuvioPrimitives.success : theme.palette.textTertiary.opacity(0.65))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct AccountMiniButton: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isFocused ? theme.palette.focusBackground : theme.palette.background.opacity(0.52))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 2)
                )
                .scaleEffect(isFocused ? 1.05 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.82), value: isFocused)
        }
        .buttonStyle(.plain)
    }
}

private struct AccountMetricPill: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.palette.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(theme.palette.background.opacity(0.46))
        )
    }
}

private struct AccountSyncStatusRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: NuvioSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.palette.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NuvioSpacing.md)
        .padding(.vertical, NuvioSpacing.sm)
        .frame(height: 74)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.palette.background.opacity(0.42))
        )
    }
}

private struct AccountSyncLogRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entry: NuvioSyncLogEntry

    var body: some View {
        HStack(spacing: NuvioSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(entry.timeLabel)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(entry.area)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.palette.secondary)
                .frame(width: 90, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NuvioSpacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.background.opacity(0.32))
        )
    }

    private var icon: String {
        switch entry.level {
        case .info: return "circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return theme.palette.textTertiary
        case .success: return NuvioPrimitives.success
        case .warning: return theme.palette.secondary
        case .failure: return NuvioPrimitives.error
        }
    }
}

private struct AccountBackupExportView: View {
    @EnvironmentObject private var theme: ThemeManager
    let text: String
    let onDone: () -> Void

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                Text("Local Backup")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("\(text.count) characters · credentials are not included")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)

                ScrollView {
                    Text(text.isEmpty ? "Backup unavailable." : text)
                        .font(.system(size: 17, weight: .medium).monospaced())
                        .foregroundStyle(theme.palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NuvioSpacing.lg)
                }
                .frame(maxHeight: 560)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.palette.backgroundElevated)
                )

                HStack(spacing: NuvioSpacing.md) {
                    Button("Done", action: onDone)
                }
                .font(.system(size: 24, weight: .bold))
            }
            .padding(NuvioSpacing.huge)
        }
        .onExitCommand(perform: onDone)
    }
}

private struct AccountBackupImportView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Binding var text: String
    let status: String?
    let importing: Bool
    let onImport: () -> Void
    let onDone: () -> Void

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                Text("Import Backup")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                TextField("Paste backup JSON", text: $text, axis: .vertical)
                    .font(.system(size: 20, weight: .medium).monospaced())
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(NuvioSpacing.md)
                    .frame(height: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.palette.backgroundElevated)
                    )

                if let status {
                    Text(status)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(status.hasPrefix("Couldn't") ? NuvioPrimitives.error : theme.palette.textSecondary)
                }

                HStack(spacing: NuvioSpacing.md) {
                    Button(importing ? "Importing..." : "Import", action: onImport)
                        .disabled(importing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Done", action: onDone)
                }
                .font(.system(size: 24, weight: .bold))
            }
            .padding(NuvioSpacing.huge)
        }
        .onExitCommand(perform: onDone)
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
