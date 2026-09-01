import SwiftUI

/// Settings → Integrations: the external services Orivio talks to — TMDB,
/// MDBList, the debrid providers, and a self-hosted TorrServer for P2P.
/// Trakt and the Orivio/Stremio accounts have their own panes.
struct IntegrationsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var torrent: TorrentSettingsStore
    @State private var sheet: IntegrationSheet?

    enum IntegrationSheet: String, Identifiable { case tmdb, mdblist, debrid, p2p; var id: String { rawValue } }

    var body: some View {
        // APK layout: a single list of drill-in rows, each opening a sub-screen.
        DetailScaffold(title: SettingsCategory.integration.title, subtitle: SettingsCategory.integration.subtitle) {
            SettingsGroupCard(title: "") {
                // Nuvio account moved to Settings → Account.
                integrationRow(title: "TMDB", subtitle: "Metadata enrichment controls", icon: "film.stack") { sheet = .tmdb }
                integrationRow(title: "MDBList", subtitle: "External ratings providers", icon: "star.circle.fill") { sheet = .mdblist }
                integrationRow(title: "Debrid", subtitle: "Cached torrent sources as direct streams", icon: "bolt.horizontal.circle.fill") { sheet = .debrid }
                integrationRow(title: "P2P (TorrServer)", subtitle: "Stream uncached torrents through your own TorrServer", icon: "point.3.connected.trianglepath.dotted") { sheet = .p2p }
            }
        }
        .fullScreenCover(item: $sheet) { s in
            ZStack {
                ATVBackground()
                integrationSheet(s)
            }
            .environmentObject(theme)
            .environmentObject(tmdb)
            .environmentObject(mdblist)
            .environmentObject(debrid)
            .environmentObject(torrent)
            .onExitCommand { sheet = nil }
        }
    }

    private func integrationRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsValueCard(title: title, subtitle: subtitle, value: "", icon: icon)
        }
        .buttonStyle(PlainCardButtonStyle())
    }

    @ViewBuilder
    private func integrationSheet(_ s: IntegrationSheet) -> some View {
        switch s {
        case .tmdb:
            DetailScaffold(title: "TMDB", subtitle: "Metadata enrichment controls") {
                SettingsGroupCard(title: "") { tmdbSection }
            }
        case .mdblist:
            DetailScaffold(title: "MDBList", subtitle: "External ratings providers") {
                SettingsGroupCard(title: "") { mdblistSection }
            }
        case .debrid:
            DetailScaffold(title: "Debrid", subtitle: "Cached torrent sources as direct, high-speed streams") {
                SettingsGroupCard(title: "") { debridSection }
            }
        case .p2p:
            DetailScaffold(title: "P2P (TorrServer)", subtitle: "Stream torrents peer-to-peer via a TorrServer instance") {
                SettingsGroupCard(title: "") { P2PSection() }
            }
        }
    }

    // MARK: - MDBList

    private var mdblistSection: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            SettingsToggleCard(
                title: "Enable MDBList ratings",
                subtitle: "Aggregate scores across rating sources",
                isOn: Binding(get: { mdblist.settings.enabled }, set: { mdblist.settings.enabled = $0 })
            )

            if mdblist.settings.enabled {
                MDBListKeyRow()
                ForEach(MDBListProvider.allCases) { provider in
                    MDBListProviderToggle(provider: provider)
                }
            }

            Text("Get a key at mdblist.com/preferences.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.top, 2)
        }
    }

    // MARK: - Debrid

    private var debridSection: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            ForEach(DebridProvider.allCases) { provider in
                DebridProviderRow(provider: provider)
            }

            if debrid.configuredProviders.count > 1 {
                PreferredProviderRow()
                    .padding(.top, NuvioSpacing.sm)
            }
        }
    }

    // MARK: - TMDB

    private var tmdbSection: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            SettingsToggleCard(
                title: "Enable TMDB",
                subtitle: "Powers TMDB collection sources (lists, collections, companies, networks, discover)",
                isOn: Binding(get: { tmdb.settings.enabled }, set: { tmdb.settings.enabled = $0 })
            )

            if tmdb.settings.enabled {
                SettingsToggleCard(
                    title: "Enrich Continue Watching",
                    subtitle: "Fetch missing titles and artwork for Continue Watching rows synced from other devices. Off skips those lookups.",
                    isOn: Binding(get: { tmdb.settings.enrichContinueWatching }, set: { tmdb.settings.enrichContinueWatching = $0 })
                )

                NuvioDropdown(
                    title: "Language",
                    subtitle: "TMDB metadata language",
                    selection: tmdb.settings.language,
                    options: TMDBLanguages.options.map { NuvioDropdownOption($0, TMDBLanguages.displayName($0)) }
                ) { tmdb.settings.language = $0 }

                SettingsToggleCard(
                    title: "Cast & Crew",
                    subtitle: "Show TMDB cast, crew, and director on the details page.",
                    isOn: Binding(get: { tmdb.settings.useCredits }, set: { tmdb.settings.useCredits = $0 })
                )
                SettingsToggleCard(
                    title: "Trailers",
                    subtitle: "Show TMDB trailers and the auto-playing hero trailer on details.",
                    isOn: Binding(get: { tmdb.settings.useTrailers }, set: { tmdb.settings.useTrailers = $0 })
                )
                SettingsToggleCard(
                    title: "More Like This",
                    subtitle: "Show the TMDB recommendations row on the details page.",
                    isOn: Binding(get: { tmdb.settings.useMoreLikeThis }, set: { tmdb.settings.useMoreLikeThis = $0 })
                )
                SettingsToggleCard(
                    title: "Details",
                    subtitle: "Show TMDB country and spoken-language details.",
                    isOn: Binding(get: { tmdb.settings.useDetails }, set: { tmdb.settings.useDetails = $0 })
                )
                SettingsToggleCard(
                    title: "Release dates",
                    subtitle: "Show the TMDB release date on the details page.",
                    isOn: Binding(get: { tmdb.settings.useReleaseDates }, set: { tmdb.settings.useReleaseDates = $0 })
                )
                SettingsToggleCard(
                    title: "Production companies",
                    subtitle: "Show the TMDB production-companies row.",
                    isOn: Binding(get: { tmdb.settings.useProductions }, set: { tmdb.settings.useProductions = $0 })
                )
                SettingsToggleCard(
                    title: "Collections",
                    subtitle: "Show the “part of a collection” row and its other entries.",
                    isOn: Binding(get: { tmdb.settings.useCollections }, set: { tmdb.settings.useCollections = $0 })
                )
                SettingsToggleCard(
                    title: "Episodes",
                    subtitle: "Fetch per-episode TMDB ratings and air dates for series.",
                    isOn: Binding(get: { tmdb.settings.useEpisodes }, set: { tmdb.settings.useEpisodes = $0 })
                )
            }

            Text("Uses a shared, app-embedded TMDB API key — no sign-in required.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.top, 2)
        }
    }

}

// MARK: - Debrid rows

private struct DebridProviderRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore
    let provider: DebridProvider

    @State private var showEditor = false

    private var isConfigured: Bool { !debrid.key(for: provider).isEmpty }

    var body: some View {
        Button { showEditor = true } label: {
            HStack(spacing: NuvioSpacing.lg) {
                Text(provider.shortName)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(theme.palette.onSecondary)
                    .frame(width: 54, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isConfigured ? NuvioPrimitives.success : theme.palette.surfaceVariant)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(isConfigured ? "Connected · key set" : "Key from \(provider.keyHint)")
                        .font(.system(size: 19))
                        .foregroundStyle(isConfigured ? NuvioPrimitives.success : theme.palette.textSecondary)
                }
                Spacer()
                if debrid.preferred == provider && debrid.configuredProviders.count > 1 {
                    MetaBadge(text: "PREFERRED", tint: theme.palette.secondary.opacity(0.2), textColor: theme.palette.secondary)
                }
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isConfigured ? NuvioPrimitives.success : theme.palette.textTertiary)
            }
            .integrationRowBackground(theme)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $showEditor) {
            DebridKeyEditor(provider: provider) { showEditor = false }
                .environmentObject(theme)
                .environmentObject(debrid)
        }
    }
}

private struct PreferredProviderRow: View {
    @EnvironmentObject private var debrid: DebridStore

    var body: some View {
        NuvioDropdown(
            title: "Preferred provider",
            subtitle: "Used first when a stream is cached on more than one",
            selection: debrid.preferred?.id ?? "",
            options: debrid.configuredProviders.map { NuvioDropdownOption($0.id, $0.displayName) }
        ) { picked in
            debrid.preferred = DebridProvider.allCases.first { $0.id == picked }
        }
    }
}

private struct DebridKeyEditor: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore
    let provider: DebridProvider
    let onDone: () -> Void

    @State private var key = ""
    @State private var validating = false
    @State private var status: String?
    @State private var showQR = false

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: NuvioSpacing.xl) {
                Text("Connect \(provider.displayName)")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                // QR sign-in — scan on your phone, like the APK. All four
                // providers support it (RD/PM OAuth device, AD/TB device flows).
                if provider.supportsQRAuth {
                    Button { showQR = true } label: {
                        HStack(spacing: NuvioSpacing.sm) {
                            Image(systemName: "qrcode")
                            Text("Sign in with QR")
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.palette.onSecondary)
                        .padding(.horizontal, NuvioSpacing.xl)
                        .padding(.vertical, NuvioSpacing.md)
                        .background(Capsule().fill(theme.palette.secondary))
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    Text("or paste an API key from \(provider.keyHint)")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textTertiary)
                } else {
                    Text("Get your key at \(provider.keyHint)")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                SecureField("Paste API key", text: $key)
                    .font(.system(size: 24))
                    .frame(maxWidth: 760)

                if let status {
                    Text(status)
                        .font(.system(size: 20))
                        .foregroundStyle(status.hasPrefix("Valid") ? NuvioPrimitives.success : NuvioPrimitives.error)
                }

                HStack(spacing: NuvioSpacing.lg) {
                    Button(action: verifyAndSave) {
                        if validating { ProgressView().tint(theme.palette.onSecondary) }
                        else { Text("Verify & Save") }
                    }
                    .disabled(validating || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !debrid.key(for: provider).isEmpty {
                        Button("Remove", role: .destructive) {
                            debrid.setKey("", for: provider)
                            onDone()
                        }
                    }
                    Button("Cancel", role: .cancel, action: onDone)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(NuvioSpacing.huge)
        }
        .onAppear { key = debrid.key(for: provider) }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone() }
        .fullScreenCover(isPresented: $showQR) {
            DebridConnectPage(provider: provider) { linked in
                showQR = false
                if linked { onDone() }
            }
            .environmentObject(theme)
            .environmentObject(debrid)
        }
    }

    private func verifyAndSave() {
        validating = true
        status = nil
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        Task {
            let valid = await DebridService.validate(provider: provider, apiKey: trimmed)
            validating = false
            if valid {
                debrid.setKey(trimmed, for: provider)
                status = "Valid — saved."
                onDone()
            } else {
                status = "Invalid key or network error."
            }
        }
    }
}

/// Full-screen QR device-login for a debrid provider (Real-Debrid & Premiumize
/// OAuth device flows, AllDebrid PIN flow, TorBox device flow) — the APK's
/// scan-to-connect. Menu/Back cancels.
private struct DebridConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore
    let provider: DebridProvider
    /// `true` when the account was linked.
    let onDone: (Bool) -> Void

    @State private var code: DebridDeviceCode?
    @State private var errorText: String?
    @State private var expiresAt = Date()
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: NuvioSpacing.xl) {
                Text("Connect \(provider.displayName)")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)

                if let code {
                    Text("Scan the code with your phone, or go to \(code.verificationURL) and enter the code below.")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)

                    QRCodeView(string: code.qrURL, side: 360)

                    Text(code.userCode)
                        .font(.system(size: 60, weight: .heavy, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(theme.palette.secondary)

                    HStack(spacing: NuvioSpacing.sm) {
                        ProgressView().tint(theme.palette.secondary)
                        Text("Waiting for authorization…")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.palette.textTertiary)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let seconds = expiresAt.timeIntervalSince(ctx.date)
                        let remaining = seconds.isFinite ? Int(min(max(seconds, 0), 86_400)) : 0
                        Text(remaining > 0
                             ? "Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
                             : "Refreshing code…")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                } else if let errorText {
                    Text(errorText)
                        .font(.system(size: 24))
                        .foregroundStyle(NuvioPrimitives.error)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                    Button("Try Again") { Task { await begin() } }
                        .font(.system(size: 24, weight: .semibold))
                } else {
                    ProgressView().tint(theme.palette.secondary)
                    Text("Starting sign-in…")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                Text("Press Menu to cancel")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(NuvioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await begin() }
        .onDisappear { pollTask?.cancel() }
        .onExitCommand { pollTask?.cancel(); onDone(false) }
    }

    private func begin(renewal: Bool = false) async {
        // Only cancel when NOT renewing: the renewal call runs INSIDE pollTask
        // itself, so cancelling here cancelled the very task doing the renewal
        // — the fresh startDeviceAuth then ran in a cancelled context, its
        // URLSession threw, and the user got an error instead of a new code.
        if !renewal { pollTask?.cancel() }
        errorText = nil
        code = nil
        guard let c = await DebridService.startDeviceAuth(provider) else {
            errorText = "Couldn't start QR sign-in. Check your connection, or paste an API key instead."
            return
        }
        code = c
        expiresAt = Date().addingTimeInterval(TimeInterval(c.expiresIn))
        startPolling(c)
    }

    /// Codes renewed since the screen opened — cap so an abandoned QR screen
    /// doesn't hit the provider's device-auth endpoint forever.
    @State private var renewals = 0

    private func startPolling(_ c: DebridDeviceCode) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(c.interval, 3)) * 1_000_000_000)
                if Task.isCancelled { return }
                if Date() >= expiresAt {   // expired → fresh code (bounded)
                    renewals += 1
                    guard renewals <= 3 else {
                        errorText = "The QR code expired. Press Back and reopen to try again."
                        code = nil
                        return
                    }
                    await begin(renewal: true)
                    return
                }
                switch await DebridService.pollDeviceAuth(provider, c) {
                case .pending:
                    continue
                case .success(let s):
                    debrid.applyDeviceAuth(s, for: provider)
                    onDone(true)
                    return
                case .failed(let msg):
                    errorText = msg
                    code = nil
                    return
                }
            }
        }
    }
}

// MARK: - MDBList rows

private struct MDBListKeyRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @State private var showEditor = false

    private var isConfigured: Bool {
        !mdblist.settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button { showEditor = true } label: {
            HStack(spacing: NuvioSpacing.lg) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(isConfigured ? "Connected · key set" : "Tap to paste your MDBList key")
                        .font(.system(size: 19))
                        .foregroundStyle(isConfigured ? NuvioPrimitives.success : theme.palette.textSecondary)
                }
                Spacer()
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isConfigured ? NuvioPrimitives.success : theme.palette.textTertiary)
            }
            .integrationRowBackground(theme)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $showEditor) {
            MDBListKeyEditor { showEditor = false }
                .environmentObject(theme)
                .environmentObject(mdblist)
        }
    }
}

private struct MDBListProviderToggle: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let provider: MDBListProvider

    private var binding: Binding<Bool> {
        Binding(
            get: {
                switch provider {
                case .trakt: return mdblist.settings.showTrakt
                case .imdb: return mdblist.settings.showImdb
                case .tmdb: return mdblist.settings.showTmdb
                case .letterboxd: return mdblist.settings.showLetterboxd
                case .tomatoes: return mdblist.settings.showTomatoes
                case .audience: return mdblist.settings.showAudience
                case .metacritic: return mdblist.settings.showMetacritic
                }
            },
            set: { newValue in
                switch provider {
                case .trakt: mdblist.settings.showTrakt = newValue
                case .imdb: mdblist.settings.showImdb = newValue
                case .tmdb: mdblist.settings.showTmdb = newValue
                case .letterboxd: mdblist.settings.showLetterboxd = newValue
                case .tomatoes: mdblist.settings.showTomatoes = newValue
                case .audience: mdblist.settings.showAudience = newValue
                case .metacritic: mdblist.settings.showMetacritic = newValue
                }
            }
        )
    }

    var body: some View {
        SettingsToggleCard(title: provider.fullName, subtitle: "", isOn: binding)
    }
}

private struct MDBListKeyEditor: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    let onDone: () -> Void

    @State private var key = ""
    @State private var validating = false
    @State private var status: String?

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: NuvioSpacing.xl) {
                Text("MDBList API Key")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Get your key at mdblist.com/preferences")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)

                SecureField("Paste API key", text: $key)
                    .font(.system(size: 24))
                    .frame(maxWidth: 760)

                if let status {
                    Text(status)
                        .font(.system(size: 20))
                        .foregroundStyle(status.hasPrefix("Valid") ? NuvioPrimitives.success : NuvioPrimitives.error)
                }

                HStack(spacing: NuvioSpacing.lg) {
                    Button(action: verifyAndSave) {
                        if validating { ProgressView().tint(theme.palette.onSecondary) }
                        else { Text("Verify & Save") }
                    }
                    .disabled(validating || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !mdblist.settings.apiKey.isEmpty {
                        Button("Remove", role: .destructive) {
                            mdblist.settings.apiKey = ""
                            onDone()
                        }
                    }
                    Button("Cancel", role: .cancel, action: onDone)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(NuvioSpacing.huge)
        }
        .onAppear { key = mdblist.settings.apiKey }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone() }
    }

    private func verifyAndSave() {
        validating = true
        status = nil
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        Task {
            let valid = await MDBListService.validate(apiKey: trimmed)
            validating = false
            if valid {
                mdblist.settings.apiKey = trimmed
                status = "Valid — saved."
                onDone()
            } else {
                status = "Invalid key or network error."
            }
        }
    }
}

/// A small curated ISO-639-1 language list for the TMDB language picker.
enum TMDBLanguages {
    static let options = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "hi", "ru", "ar"]

    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

/// Shared card background for integration rows. Reads `isFocused` so that when
/// the row is the label of a focusable Button (which `PlainCardButtonStyle`
/// otherwise strips of all focus chrome) it still shows the fill + accent ring.
/// On non-focusable rows `isFocused` stays false, giving a plain static card.
private struct IntegrationRowBackground: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, NuvioSpacing.lg)
            .frame(minHeight: 68)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
            )
    }
}

extension View {
    /// Shared, focus-aware card background for integration rows.
    func integrationRowBackground(_ theme: ThemeManager) -> some View {
        modifier(IntegrationRowBackground())
    }
}

/// P2P via a TorrServer instance. tvOS can't run a torrent engine on-device
/// (no subprocess / no BitTorrent library), so peering is offloaded to a
/// TorrServer the user runs on their network.
private struct P2PSection: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var torrent: TorrentSettingsStore
    @State private var testing = false
    @State private var testResult: String?

    private var s: Binding<TorrentSettings> {
        Binding(get: { torrent.settings }, set: { torrent.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            SettingsToggleCard(
                title: "Enable P2P",
                subtitle: "Play torrent sources peer-to-peer through TorrServer when no debrid provider is set",
                isOn: s.p2pEnabled
            )

            if torrent.settings.p2pEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TorrServer URL")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    TextField("http://192.168.1.10:8090", text: s.serverURL)
                        .font(.system(size: 22))
                    Text("Run TorrServer (github.com/YouROK/TorrServer) on a computer, NAS, or Raspberry Pi on your network, then enter its address here.")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .padding(.vertical, 4)

                HStack(spacing: NuvioSpacing.md) {
                    Button {
                        guard !testing, !torrent.settings.serverURL.isEmpty else { return }
                        testing = true; testResult = nil
                        Task {
                            let ok = await TorrServerService.ping(torrent.settings)
                            testResult = ok ? "Connected ✓" : "Couldn't reach TorrServer"
                            testing = false
                        }
                    } label: {
                        if testing { ProgressView() } else { SeeAllLabel(text: "Test connection") }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 19))
                            .foregroundStyle(testResult.contains("✓") ? NuvioPrimitives.success : NuvioPrimitives.error)
                    }
                }

                SettingsToggleCard(
                    title: "Hide torrent stats",
                    subtitle: "Don't show peer / seed counts while streaming",
                    isOn: s.hideTorrentStats
                )
            }

            Text("Apple TV can't run a torrent engine itself, so P2P streams through your TorrServer. Debrid (if configured) is still used first; P2P is the fallback for uncached torrents.")
                .font(.system(size: 17))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.top, 2)
        }
    }
}
