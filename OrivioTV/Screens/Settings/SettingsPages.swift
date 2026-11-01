import SwiftUI

/// The root page of each category (§11).
struct SettingsCategoryPage: View {
    let category: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            switch category {
            case .account: AccountSettings()
            case .appearance: AppearanceSettingsPage()
            case .home: HomeLayoutSettings()
            case .content: ContentSettings()
            case .integrations: IntegrationsSettings()
            case .playback: PlaybackSettings()
            case .subtitles: SubtitlesAudioSettings()
            case .trackers: TrackerSettings()
            case .about: AboutSettings()
            }
        }
    }
}

// MARK: - Account

private struct AccountSettings: View {
    @EnvironmentObject private var nav: SettingsNav
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var hub = SyncHub.shared
    @ObservedObject private var account = OrivioAccount.shared
    @State private var confirm: ConfirmAction?
    @State private var showQR = false
    @State private var backup: BackupSheet?

    enum BackupSheet: String, Identifiable { case export, restore; var id: String { rawValue } }

    private var syncValue: String {
        if hub.isSyncing { return "Syncing…" }
        guard let d = hub.lastSync else { return "Never" }
        return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        SettingsGroup(header: "Orivio account",
                      footer: hub.lastError.map { "Last error: \($0)" }
                        ?? (hub.isSignedIn ? "Profiles, add-ons, library, progress, watched, collections and settings sync with your other devices."
                                           : "Sign in to sync with the Orivio app on your other devices.")) {
            if hub.isSignedIn {
                SettingsRow(label: "Signed in", value: hub.accountEmail ?? "Orivio account") {}
                SettingsRow(label: "Sync Now", value: syncValue) { Task { await hub.syncNow() } }
            } else if account.isConfigured {
                SettingsRow(label: "Sign In with QR Code", icon: "qrcode") {
                    account.startQRLogin()
                    showQR = true
                }
                SettingsRow(label: "Sign In with Email", chevron: true, icon: "envelope") {
                    nav.push("Sign In") { EmailSignInPage() }
                }
            } else {
                SettingsRow(label: "Orivio account", value: "Not configured in this build") {}
            }
        }
        SettingsGroup(header: "Profiles") {
            SettingsRow(label: "Manage Profiles", value: "\(profiles.profiles.count)", chevron: true) {
                nav.push("Manage Profiles") { ManageProfilesPage() }
            }
        }
        SettingsGroup(header: "Local Backup", footer: "This profile's add-ons, library, progress, watched marks, collections and settings as one file — without passwords or API keys. Restoring merges; nothing here is removed.") {
            SettingsRow(label: "Export Backup", icon: "square.and.arrow.up") { backup = .export }
            SettingsRow(label: "Restore Backup", icon: "square.and.arrow.down") { backup = .restore }
        }
        SettingsGroup(footer: "Removes Continue Watching and watched marks for this profile on this Apple TV.") {
            SettingsRow(label: "Clear Watch History", destructive: true) {
                confirm = ConfirmAction(title: "Clear Watch History?", message: "Continue Watching and every watched mark for \(profiles.active.name) will be removed.",
                                        button: "Clear") {
                    AppStores.shared.progress.clearAll()
                    AppStores.shared.watched.clearAll()
                    ToastCenter.shared.show("Watch history cleared")
                }
            }
        }
        if hub.isSignedIn {
            SettingsGroup {
                SettingsRow(label: "Sign Out", destructive: true) {
                    confirm = ConfirmAction(title: "Sign out of Orivio?", message: "This Apple TV stops syncing. Your data stays on the account.",
                                            button: "Sign Out") { hub.signOut() }
                }
            }
        }
        Color.clear.frame(height: 1)
            .confirmation($confirm)
            .fullScreenCover(isPresented: $showQR) { QRSignInSheet { account.cancelQRLogin(); showQR = false } }
            .fullScreenCover(item: $backup) { kind in
                switch kind {
                case .export:
                    PhoneInputSheet(title: "Export Backup", prompt: "Download the file and keep it somewhere safe. It has no passwords or API keys.",
                                    exportFilename: LocalBackup.filename, exportText: LocalBackup.export()) { backup = nil }
                case .restore:
                    PhoneInputSheet(title: "Restore Backup", prompt: "Paste the contents of an Orivio backup file.", multiline: true) { text in
                        Task {
                            do {
                                let r = try await LocalBackup.importBackup(text)
                                backup = nil
                                ToastCenter.shared.show("Restored \(r.library) library, \(r.watched) watched, \(r.addons) add-ons", systemImage: "checkmark.circle")
                            } catch {
                                ToastCenter.shared.show(error.localizedDescription, systemImage: "exclamationmark.triangle")
                            }
                        }
                    } onDone: { backup = nil }
                }
            }
            .onChange(of: hub.isSignedIn) { _, signedIn in if signedIn { showQR = false } }
    }
}

/// The Orivio QR sign-in: the code page on the phone, the app never sees the password.
private struct QRSignInSheet: View {
    @ObservedObject private var account = OrivioAccount.shared
    let onCancel: () -> Void

    var body: some View {
        SignInSheet(title: "Sign In to Orivio", url: account.qrLogin?.webURL, code: account.qrLogin?.code,
                    status: account.errorMessage ?? account.qrLogin?.status ?? "Getting a code…", onCancel: onCancel)
    }
}

private struct EmailSignInPage: View {
    @ObservedObject private var account = OrivioAccount.shared
    @EnvironmentObject private var nav: SettingsNav
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        SettingsGroup(footer: account.errorMessage ?? "Signing in with the QR code is safer — your password never touches the TV.") {
            TextEntryRow(label: "Email", text: $email, keyboard: .emailAddress)
            TextEntryRow(label: "Password", text: $password, masked: true)
            SettingsRow(label: working ? "Signing In…" : "Sign In", icon: "person.crop.circle.badge.checkmark") {
                guard !working else { return }
                working = true
                Task {
                    await account.signIn(email: email, password: password)
                    working = false
                    password = ""
                    if account.isSignedIn { nav.pop() }
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPage: View {
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        SettingsGroup(header: "Navigation") {
            PickerRow(label: "Navigation style", options: NavigationStyle.allCases, selection: $appearance.value.navigationStyle, title: \.label)
            if appearance.value.navigationStyle == .rail {
                ToggleRow(label: "Hide side rail when closed", detail: "Pages use the full width; press Left at the edge or Back to open it",
                          isOn: $appearance.value.railAutoHide)
            }
        }
        SettingsGroup(header: "Colour", footer: "Artwork-tinted backgrounds take their colour from the title's artwork; off keeps the Ambience colour everywhere.") {
            PickerRow(label: "Ambience", options: Ambience.allCases, selection: $appearance.value.ambience, title: \.label,
                      swatch: { Color.hex($0.hexes.0) },
                      onPreview: { a in appearance.preview = a.map { var s = appearance.value; s.ambience = $0; return s } })
            PickerRow(label: "Accent color", options: AccentChoice.allCases, selection: $appearance.value.accent, title: \.label,
                      swatch: { Color.hex($0.hex) },
                      onPreview: { a in appearance.preview = a.map { var s = appearance.value; s.accent = $0; return s } })
            ToggleRow(label: "Artwork-tinted backgrounds", isOn: $appearance.value.artworkTint)
        }
    }
}

// MARK: - Home & Layout

private struct HomeLayoutSettings: View {
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var nav: SettingsNav

    private var heroSources: [String?] { [nil] + HomeRowsPage.catalogRows(addons).map(\.key) }

    var body: some View {
        SettingsGroup(header: "Hero") {
            PickerRow(label: "Hero layout", options: HeroLayout.allCases, selection: $home.value.heroLayout, title: \.label)
            PickerRow(label: "Hero source", options: heroSources, selection: $home.value.heroSource) { key in
                key.flatMap { k in HomeRowsPage.catalogRows(addons).first { $0.key == k }?.title } ?? "Automatic"
            }
            ToggleRow(label: "Hero video", detail: "Plays the trailer muted behind the art", isOn: $home.value.heroVideo)
            ToggleRow(label: "Trailer sound", detail: "Trailers on Home and title pages play with sound", isOn: $home.value.trailerSound)
            ToggleRow(label: "Featured section", isOn: $home.value.featuredSection)
        }
        SettingsGroup(header: "Posters") {
            ToggleRow(label: "Landscape posters", isOn: $home.value.landscapePosters)
            ToggleRow(label: "Poster labels", isOn: $home.value.posterLabels)
            ToggleRow(label: "Poster banners", isOn: $home.value.posterBanners)
            ToggleRow(label: "Hide unreleased content", isOn: $home.value.hideUnreleased)
        }
        SettingsGroup(header: "Continue Watching", footer: "Hide spoilers blurs unwatched episode stills and barely-started next-up art.") {
            PickerRow(label: "Sort", options: ContinueWatchingSort.allCases, selection: $home.value.cwSort, title: \.label)
            ToggleRow(label: "Episode thumbnails", isOn: $home.value.episodeThumbnails)
            ToggleRow(label: "Next up from furthest episode", isOn: $home.value.nextUpFromFurthest)
            ToggleRow(label: "Show unaired next up", isOn: $home.value.showUnairedNextUp)
            ToggleRow(label: "Hide spoilers", isOn: $home.value.hideSpoilers)
            ToggleRow(label: "Upcoming episode countdown", isOn: $home.value.upcomingCountdown)
        }
        SettingsGroup(header: "Rows") {
            ToggleRow(label: "“To Watch After” rows",
                      detail: "Shows picks like “Comedies to Watch After …” based on the last titles you finished",
                      isOn: $home.value.afterWatchingRows)
            SettingsRow(label: "Home rows", detail: "Reorder, rename or hide catalog rows", chevron: true) {
                nav.push("Home Rows") { HomeRowsPage() }
            }
            SettingsRow(label: "Collections", detail: "Folders of titles from add-ons, TMDB and Trakt", chevron: true) {
                nav.push("Collections") { CollectionsSettingsPage() }
            }
            PickerRow(label: "Collection GIFs", options: FocusArtMode.allCases, selection: $home.value.focusArt, title: \.label)
            PickerRow(label: "Auto-refresh Home", options: [0, 15, 30, 60, 180], selection: $home.value.autoRefreshMinutes) {
                $0 == 0 ? "Off" : ($0 < 60 ? "Every \($0) min" : "Every \($0 / 60) hr")
            }
        }
        SettingsGroup(header: "Sources page") {
            ToggleRow(label: "Full stream names", detail: "Show each link's whole release name instead of one line",
                      isOn: $home.value.fullStreamNames)
        }
        LinkBadgesGroup()
    }
}

/// Badger link badges: a community pack of regex rules that tags each link
/// (4K, Dolby Vision, Atmos, Remux…) with a logo chip. Synced with your Orivio
/// account like the other Orivio apps.
private struct LinkBadgesGroup: View {
    @EnvironmentObject private var badges: StreamBadgeStore
    @State private var working = false

    var body: some View {
        SettingsGroup(header: "Link badges",
                      footer: badges.lastStatus ?? "Badge packs come from Badger (nintle.github.io/Badger) — paste the pack's JSON link, or set one up in any Orivio app and sync it here.") {
            SettingsRow(label: "Badge pack", value: badges.isConfigured ? "\(badges.filterCount) badges" : "None", action: {})
            TextEntryRow(label: badges.isConfigured ? "Replace from URL" : "Import from URL",
                         text: Binding(get: { badges.sourceURL }, set: { url in
                             guard !url.isEmpty, url != badges.sourceURL else { return }
                             working = true
                             Task { await badges.importPack(from: url); working = false }
                         }),
                         placeholder: "https://…/badges.json",
                         footer: "A Badger pack's JSON link. Pastebin and Gist page links work too.",
                         keyboard: .URL)
            SettingsRow(label: working ? "Syncing…" : "Sync from Orivio account", icon: "arrow.triangle.2.circlepath") {
                guard !working else { return }
                working = true
                Task {
                    badges.lastStatus = await OrivioSync.shared.pullBadges(manual: true)
                    working = false
                }
            }
            if badges.isConfigured {
                PickerRow(label: "Badge size", options: BadgeSize.allCases,
                          selection: Binding(get: { badges.size }, set: { badges.setSize($0) }), title: \.label)
                SettingsRow(label: "Remove badge pack", destructive: true) { badges.remove() }
            }
        }
    }
}

struct HomeRowsPage: View {
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var nav: SettingsNav

    struct CatalogRow: Hashable { let key: String; let title: String; let addon: String }

    static func catalogRows(_ addons: AddonManager) -> [CatalogRow] {
        var out: [CatalogRow] = []
        for a in addons.enabled {
            for c in a.manifest.catalogs where !c.requiresExtra && !c.isSearchOnly {
                let typeName = c.type == "movie" ? "Movies" : (c.type == "series" ? "Shows" : c.type.capitalized)
                let base = c.name.isEmpty ? c.id : c.name
                let title = base.localizedCaseInsensitiveContains(typeName) ? base : "\(base) \(typeName)"
                out.append(CatalogRow(key: "\(a.manifest.id)|\(c.type)|\(c.id)", title: title, addon: a.displayName))
            }
        }
        return out
    }

    var body: some View {
        let rows = Self.catalogRows(addons)
        let ordered = home.ordered(rows.map(\.key)).compactMap { k in rows.first { $0.key == k } }
        if ordered.isEmpty {
            Text("Install an add-on with catalogs to arrange Home rows.").textStyle(.body, color: Palette.textSecondary)
        } else {
            SettingsGroup(footer: "Select a row to rename, move or hide it.") {
                ForEach(ordered, id: \.key) { r in
                    let cfg = home.config(for: r.key)
                    SettingsRow(label: cfg?.customTitle ?? r.title, detail: r.addon, value: cfg?.hidden == true ? "Hidden" : nil, chevron: true) {
                        nav.push(cfg?.customTitle ?? r.title) { HomeRowEditPage(row: r, keys: ordered.map(\.key)) }
                    }
                }
            }
        }
    }
}

private struct HomeRowEditPage: View {
    let row: HomeRowsPage.CatalogRow
    let keys: [String]
    @EnvironmentObject private var home: HomeSettingsStore

    private var cfg: HomeRowConfig { home.config(for: row.key) ?? HomeRowConfig(key: row.key) }

    var body: some View {
        SettingsGroup {
            ToggleRow(label: "Show on Home", isOn: Binding(get: { !cfg.hidden }, set: { v in var c = cfg; c.hidden = !v; home.setConfig(c) }))
            TextEntryRow(label: "Name", text: Binding(get: { cfg.customTitle ?? "" }, set: { v in
                var c = cfg; c.customTitle = v.isEmpty ? nil : v; home.setConfig(c)
            }), placeholder: row.title, footer: "Leave empty to use “\(row.title)”.")
            ToggleRow(label: "Numbered (Top 10 style)", isOn: Binding(get: { cfg.numbered ?? false }, set: { v in
                var c = cfg; c.numbered = v; home.setConfig(c)
            }))
        }
        SettingsGroup(header: "Position") {
            SettingsRow(label: "Move Up", icon: "arrow.up") { home.move(row.key, by: -1, among: keys) }
            SettingsRow(label: "Move Down", icon: "arrow.down") { home.move(row.key, by: 1, among: keys) }
        }
    }
}

// MARK: - Content

private struct ContentSettings: View {
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var liveTV: LiveTVSettingsStore
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsGroup(header: "Add-ons") {
            SettingsRow(label: "Add-ons", value: "\(addons.addons.count) installed", chevron: true) {
                nav.push("Add-ons") { AddonsSettingsPage() }
            }
        }
        SettingsGroup(header: "Live TV", footer: "Live preview plays the focused channel muted in the Live TV header.") {
            ToggleRow(label: "Live TV tab", isOn: $liveTV.value.enabled)
            TextEntryRow(label: "Location", text: $liveTV.value.country, placeholder: "Country code, e.g. US")
            PickerRow(label: "Preferred language", options: [""] + Languages.common, selection: $liveTV.value.language) {
                $0.isEmpty ? "Any" : Languages.name($0)
            }
            TextEntryRow(label: "Custom playlist URL", text: $liveTV.value.customPlaylistURL, placeholder: "https://…/playlist.m3u", keyboard: .URL)
            ToggleRow(label: "Add-on channels", isOn: $liveTV.value.useAddonChannels)
            ToggleRow(label: "Live preview", isOn: $liveTV.value.livePreview)
        }
        SettingsGroup(header: "IPTV provider (Xtream)") {
            TextEntryRow(label: "Server", text: $liveTV.value.xtreamServer, placeholder: "http://provider:8080", keyboard: .URL)
            TextEntryRow(label: "Username", text: $liveTV.value.xtreamUsername)
            TextEntryRow(label: "Password", text: $liveTV.value.xtreamPassword, masked: true)
        }
        GuideSettingsGroup()
    }
}

// MARK: - Integrations

private struct IntegrationsSettings: View {
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var mdblist: MDBListSettingsStore
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var torrent: TorrentSettingsStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var torrentStatus: String?

    var body: some View {
        SettingsGroup(header: "TMDB", footer: "Your own TMDB key adds cast photos and characters, collections, studios and better recommendations.") {
            ToggleRow(label: "Use TMDB", isOn: $tmdb.value.enabled)
            TextEntryRow(label: "API key", text: $tmdb.value.apiKey, masked: true, placeholder: "TMDB API key (v3)",
                         footer: "Create a free key at themoviedb.org → Settings → API.")
            PickerRow(label: "Language", options: ["en-US", "en-GB", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "nl-NL", "ja-JP", "ko-KR"],
                      selection: $tmdb.value.language) { $0 }
            ToggleRow(label: "Enrich Continue Watching", detail: "Fills missing art and titles for synced rows", isOn: $tmdb.value.enrichContinueWatching)
        }
        SettingsGroup(header: "MDBList", footer: "Shows aggregated ratings (Rotten Tomatoes, Metacritic, Letterboxd…) on Detail pages.") {
            ToggleRow(label: "Use MDBList", isOn: $mdblist.value.enabled)
            TextEntryRow(label: "API key", text: $mdblist.value.apiKey, masked: true)
        }
        SettingsGroup(header: "Debrid") {
            SettingsRow(label: "Debrid services", value: debrid.value.hasAny ? debrid.value.configured.map(\.short).joined(separator: " · ") : "Not connected",
                        chevron: true) {
                nav.push("Debrid") { DebridSettingsPage() }
            }
        }
        MediaServerSettingsGroup()
        SettingsGroup(header: "P2P", footer: "Plays torrent sources through your TorrServer when no debrid service is connected.") {
            ToggleRow(label: "Use TorrServer", isOn: $torrent.value.enabled)
            TextEntryRow(label: "Server URL", text: $torrent.value.serverURL, keyboard: .URL)
            SettingsRow(label: "Test connection", value: torrentStatus) {
                torrentStatus = "Testing…"
                let url = torrent.value.serverURL
                Task { torrentStatus = await TorrServerService.test(server: url) ? "Connected" : "Not responding" }
            }
        }
    }
}

private struct DebridSettingsPage: View {
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var flow: DeviceFlow?
    @State private var names: [DebridProvider: String] = [:]

    var body: some View {
        SettingsGroup(footer: "Sources from your preferred service are tried first.") {
            ForEach(DebridProvider.allCases) { p in
                SettingsRow(label: p.label, value: debrid.value.key(p) != nil ? (names[p] ?? "Connected") : "Not connected", chevron: true) {
                    nav.push(p.label) { DebridProviderPage(provider: p, flow: $flow) }
                }
            }
        }
        if debrid.value.configured.count > 1 {
            SettingsGroup {
                PickerRow(label: "Preferred provider", options: debrid.value.configured, selection: $debrid.value.preferred, title: \.label)
            }
        }
        Color.clear.frame(height: 1)
            .task {
                for p in debrid.value.configured {
                    if let k = debrid.value.key(p), let n = await DebridService.validate(p, key: k) { names[p] = n }
                }
            }
            .fullScreenCover(item: $flow) { f in
                DeviceFlowSheet(flow: f) { f.cancel(); flow = nil }
            }
    }
}

private struct DebridProviderPage: View {
    let provider: DebridProvider
    @Binding var flow: DeviceFlow?
    @EnvironmentObject private var debrid: DebridStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var checking: String?

    var body: some View {
        let connected = debrid.value.key(provider) != nil
        SettingsGroup(footer: footer) {
            if provider == .realDebrid || provider == .allDebrid {
                SettingsRow(label: connected ? "Reconnect with Code" : "Connect with Code", icon: "qrcode") { startDeviceFlow() }
            }
            TextEntryRow(label: "API key", text: Binding(get: { debrid.value.keys[provider.rawValue] ?? "" }, set: { v in
                debrid.update { $0.keys[provider.rawValue] = v.isEmpty ? nil : v }
                if !v.isEmpty { verify(v) }
            }), masked: true)
            if let checking { SettingsRow(label: "Status", value: checking) {} }
        }
        if connected {
            SettingsGroup {
                SettingsRow(label: "Disconnect", destructive: true) {
                    debrid.update {
                        $0.keys[provider.rawValue] = nil
                        if provider == .realDebrid { $0.rdRefreshToken = nil; $0.rdClientID = nil; $0.rdClientSecret = nil }
                    }
                    nav.pop()
                }
            }
        }
    }

    private var footer: String {
        switch provider {
        case .realDebrid: return "Sign in with a code at real-debrid.com/device, or paste your API token from real-debrid.com/apitoken."
        case .premiumize: return "Paste your API key from premiumize.me/account."
        case .torbox: return "Paste your API key from torbox.app/settings."
        case .allDebrid: return "Sign in with a PIN at alldebrid.com/pin, or paste an API key."
        }
    }

    private func verify(_ key: String) {
        checking = "Checking…"
        Task { checking = await DebridService.validate(provider, key: key).map { "Connected as \($0)" } ?? "Key not accepted" }
    }

    private func startDeviceFlow() {
        let f = DeviceFlow(title: "Connect \(provider.label)")
        flow = f
        f.task = Task { @MainActor in
            do {
                if provider == .realDebrid {
                    let code = try await DebridService.rdStartDeviceCode()
                    f.url = code.verificationURL; f.code = code.userCode; f.status = "Waiting for you to approve…"
                    let (access, refresh, cid, secret) = try await DebridService.rdPoll(code)
                    debrid.update {
                        $0.keys[DebridProvider.realDebrid.rawValue] = access
                        $0.rdRefreshToken = refresh; $0.rdClientID = cid; $0.rdClientSecret = secret
                    }
                } else {
                    let pin = try await DebridService.adStartPin()
                    f.url = pin.userURL; f.code = pin.pin; f.status = "Waiting for you to approve…"
                    let key = try await DebridService.adPoll(pin)
                    debrid.update { $0.keys[DebridProvider.allDebrid.rawValue] = key }
                }
                flow = nil
                ToastCenter.shared.show("\(provider.label) connected")
                verify(debrid.value.key(provider) ?? "")
            } catch is CancellationError {
            } catch {
                f.status = error.localizedDescription
            }
        }
    }
}

/// State for a device-code / PIN sign-in shown in `SignInSheet`.
@MainActor
final class DeviceFlow: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published var url: String?
    @Published var code: String?
    @Published var status = "Getting a code…"
    var task: Task<Void, Never>?

    init(title: String) { self.title = title }
    func cancel() { task?.cancel() }
}

// MARK: - Playback

private struct PlaybackSettings: View {
    @EnvironmentObject private var player: PlayerSettingsStore
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsGroup(header: "Auto-play", footer: "A credits chapter in the file shows Up Next earlier than this.") {
            ToggleRow(label: "Auto-play next episode", isOn: $player.value.autoPlayNextEpisode)
            PickerRow(label: "Show Up Next", options: [10, 15, 20, 30, 45, 60, 90, 120, 180], selection: $player.value.upNextSecondsBeforeEnd) {
                "\($0) s before the end"
            }
            PickerRow(label: "Auto-play countdown", options: [0, 5, 10, 15, 20, 30, -1], selection: $player.value.autoPlayCountdown) {
                $0 < 0 ? "Unlimited" : ($0 == 0 ? "Immediately" : "\($0) s")
            }
            ToggleRow(label: "Still watching?", isOn: $player.value.stillWatchingEnabled)
            if player.value.stillWatchingEnabled {
                PickerRow(label: "Ask after", options: [2, 3, 4, 5, 6, 8], selection: $player.value.stillWatchingAfter) { "\($0) episodes" }
            }
            ToggleRow(label: "Keep next episode on the same source", isOn: $player.value.keepSameSourceForNext)
        }
        SettingsGroup(header: "Seeking") {
            PickerRow(label: "Skip amount", options: [5, 10, 15, 30], selection: $player.value.skipAmount) { "\($0) s" }
            PickerRow(label: "Scrubber jump", options: [30, 60, 120, 300], selection: $player.value.scrubberJump) { $0 >= 60 ? "\($0 / 60) min" : "\($0) s" }
            ToggleRow(label: "Skip Intro button", isOn: $player.value.skipIntroButton)
            ToggleRow(label: "Auto-skip intros", isOn: $player.value.autoSkipIntros)
            ToggleRow(label: "AniSkip for anime", isOn: $player.value.aniSkip)
            ToggleRow(label: "Scrub preview frames", isOn: $player.value.scrubPreviews)
        }
        SettingsGroup(header: "Sources") {
            ToggleRow(label: "Link filters", isOn: $player.value.linkFilters)
            PickerRow(label: "Links per resolution", options: [2, 4, 6, 8, 10, 20], selection: $player.value.linksPerResolution) { "\($0)" }
            PickerRow(label: "Source search patience", options: [15, 30, 45, 60, 90], selection: $player.value.sourceSearchPatience) { "\($0) s" }
            PickerRow(label: "Minimum resolution", options: [nil, "720p", "1080p", "2160p"], selection: $player.value.minimumResolution) { $0 ?? "Any" }
            ToggleRow(label: "Hide AV1", isOn: $player.value.hideAV1)
            ToggleRow(label: "HDR only", isOn: $player.value.hdrOnly)
            ToggleRow(label: "Dolby Vision only", isOn: $player.value.dolbyVisionOnly)
            ToggleRow(label: "Cached only", isOn: $player.value.cachedOnly)
        }
        SettingsGroup(header: "Auto-play source") {
            ToggleRow(label: "Auto-play best source", isOn: $player.value.autoPlayBestSource)
            ToggleRow(label: "Cached sources only", isOn: $player.value.autoPlayCachedOnly)
            ToggleRow(label: "Reuse last link", isOn: $player.value.reuseLastLink)
            if player.value.reuseLastLink {
                PickerRow(label: "Reuse window", options: [6, 12, 24, 48, 72, 168], selection: $player.value.reuseWindowHours) {
                    $0 >= 48 ? "\($0 / 24) days" : "\($0) hours"
                }
            }
        }
        SettingsGroup(header: "Player", footer: "Auto opens movies and episodes with AetherEngine first (every container, Dolby Vision / HDR10+ / HLG, lossless and Atmos audio); if it cannot play a stream, Native takes MP4/HLS and FFmpeg everything else. Live TV skips AetherEngine.") {
            PickerRow(label: "Playback engine", options: EnginePreference.allCases, selection: $player.value.engine, title: \.label)
            PickerRow(label: "Playback mode", options: PlaybackMode.allCases, selection: $player.value.playbackMode, title: \.label)
            ToggleRow(label: "Hybrid disk cache", isOn: $player.value.hybridCache)
            ToggleRow(label: "Dolby Atmos passthrough", isOn: $player.value.atmosPassthrough)
            PickerRow(label: "Video scaling", options: VideoScaling.allCases, selection: $player.value.videoScaling, title: \.label)
        }
        SettingsGroup(header: "External player", footer: "Used when the engine is External app, and from a source's hold menu.") {
            PickerRow(label: "External player", options: ExternalPlayerApp.allCases, selection: $player.value.externalPlayer, title: \.label)
            ToggleRow(label: "Forward subtitles", isOn: $player.value.externalForwardSubtitles)
            ToggleRow(label: "Send the rest of the season", isOn: $player.value.externalSendSeason)
        }
        SettingsGroup(header: "Content & trailers") {
            ToggleRow(label: "Parental guide", isOn: $player.value.parentalGuide)
            PickerRow(label: "Auto-play trailer on Detail", options: [-1, 0, 1, 2, 3, 5], selection: $player.value.detailTrailerDelay) {
                $0 < 0 ? "Off" : ($0 == 0 ? "Immediately" : "After \($0) s")
            }
        }
        SettingsGroup(header: "Developer", footer: "Public sample files for every playback path (Dolby Vision, HDR10, TrueHD Atmos, DTS-HD MA, PGS/ASS…) and a custom URL field.") {
            SettingsRow(label: "Test streams", chevron: true, icon: "testtube.2") {
                nav.push("Test streams") { TestStreamsPage() }
            }
        }
    }
}

// MARK: - Subtitles & Audio

private struct SubtitlesAudioSettings: View {
    @EnvironmentObject private var player: PlayerSettingsStore
    @State private var allLanguages = false

    private var languages: [String] { allLanguages ? Languages.all : Languages.common }

    var body: some View {
        SettingsGroup(header: "Audio") {
            PickerRow(label: "Preferred language", options: languages, selection: $player.value.preferredAudioLanguage, title: Languages.name)
        }
        SettingsGroup(header: "Subtitles") {
            ToggleRow(label: "On by default", isOn: $player.value.subtitlesOnByDefault)
            PickerRow(label: "Preferred language", options: languages, selection: $player.value.subtitleLanguage, title: Languages.name)
            PickerRow(label: "Secondary language", options: [nil] + languages.map { Optional($0) }, selection: $player.value.subtitleSecondaryLanguage) {
                $0.map(Languages.name) ?? "None"
            }
            ToggleRow(label: "Prefer forced subtitles", isOn: $player.value.preferForcedSubtitles)
            ToggleRow(label: "Prefer add-on subtitles", isOn: $player.value.preferAddonSubtitles)
            ToggleRow(label: "Full styled subtitles", detail: "ASS/SSA styling through the VLC engine", isOn: $player.value.fullStyledSubtitles)
            ToggleRow(label: "Show all languages", isOn: $allLanguages)
        }
        SettingsGroup(header: "Style", footer: "Changes apply to captions right away, including during playback.") {
            PickerRow(label: "Size", options: SubtitleStyle.sizes, selection: $player.value.subtitleSize) { "\(Int($0)) pt" }
            PickerRow(label: "Font", options: SubtitleStyle.fonts, selection: $player.value.subtitleFont) { $0 }
            PickerRow(label: "Color", options: SubtitleStyle.colors, selection: $player.value.subtitleColor) { $0 }
            ToggleRow(label: "Bold", isOn: $player.value.subtitleBold)
            ToggleRow(label: "Outline", isOn: $player.value.subtitleOutline)
            if player.value.subtitleOutline {
                PickerRow(label: "Outline color", options: SubtitleStyle.colors, selection: $player.value.subtitleOutlineColor) { $0 }
                PickerRow(label: "Outline thickness", options: SubtitleStyle.outlineWidths, selection: $player.value.subtitleOutlineWidth) { "\(Int($0))" }
            }
            ToggleRow(label: "Background plate", isOn: $player.value.subtitleBackground)
            if player.value.subtitleBackground {
                PickerRow(label: "Background opacity", options: [0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 1.0],
                          selection: $player.value.subtitleBackgroundOpacity) { "\(Int($0 * 100))%" }
            }
            PickerRow(label: "Vertical position", options: [-40, -20, 0, 20, 40, 60, 80, 100, 120, 140, 160],
                      selection: $player.value.subtitleVerticalOffset) { $0 == 0 ? "Default" : ($0 > 0 ? "Up \(Int($0))" : "Down \(Int(-$0))") }
            PickerRow(label: "Timing offset", options: stride(from: -5.0, through: 5.0, by: 0.5).map { $0 }, selection: $player.value.subtitleDelay) {
                $0 == 0 ? "Off" : String(format: "%+.1f s", $0)
            }
        }
    }
}

// MARK: - Trakt & SIMKL

private struct TrackerSettings: View {
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var flags: TraktFlagsStore
    @EnvironmentObject private var simkl: SimklStore
    @EnvironmentObject private var simklFlags: SimklFlagsStore
    @State private var syncing = false
    @State private var flow: DeviceFlow?
    @State private var confirm: ConfirmAction?

    var body: some View {
        SettingsGroup(header: "Trakt", footer: trakt.needsReconnect ? "Trakt needs you to sign in again." : nil) {
            if trakt.isSignedIn {
                SettingsRow(label: "Trakt", value: trakt.needsReconnect ? "Reconnect Needed" : "Connected as \(trakt.username ?? "you")",
                            valueColor: trakt.needsReconnect ? Palette.destructive : nil) {
                    if trakt.needsReconnect { connect() }
                }
            } else {
                SettingsRow(label: "Connect Trakt", icon: "qrcode") { connect() }
            }
            ToggleRow(label: "Scrobble", detail: "Tell Trakt what you're watching as you play", isOn: $flags.value.scrobble)
            ToggleRow(label: "Sync watch history", isOn: $flags.value.syncHistory)
            ToggleRow(label: "Sync Continue Watching", isOn: $flags.value.syncContinueWatching)
            ToggleRow(label: "Sync watchlist", isOn: $flags.value.syncWatchlist)
            ToggleRow(label: "Sync ratings", isOn: $flags.value.syncRatings)
        }
        if trakt.isSignedIn {
            SettingsGroup(footer: trakt.lastError.map { "Last error: \($0)" }) {
                SettingsRow(label: "Sync Now", value: syncing ? "Syncing…" : trakt.lastSync.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }) {
                    syncing = true
                    Task { await TraktSync.sync(); syncing = false }
                }
                SettingsRow(label: "Clear Trakt Continue Watching") {
                    confirm = ConfirmAction(title: "Clear Trakt Continue Watching?", message: "Every in-progress item on Trakt is removed.", button: "Clear") {
                        Task { await TraktSync.clearPlayback(); ToastCenter.shared.show("Trakt Continue Watching cleared") }
                    }
                }
            }
            SettingsGroup {
                SettingsRow(label: "Disconnect Trakt", destructive: true) {
                    confirm = ConfirmAction(title: "Disconnect Trakt?", message: "Scrobbling and sync stop for this profile.", button: "Disconnect") {
                        trakt.set(nil, user: nil)
                    }
                }
            }
        }
        SettingsGroup(header: "SIMKL", footer: simkl.lastError.map { "Last error: \($0)" }) {
            if simkl.isSignedIn {
                SettingsRow(label: "SIMKL", value: "Connected as \(simkl.session?.username ?? "you")") {}
                SettingsRow(label: "Sync Now", value: simkl.lastSync.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }) {
                    Task { await SimklService.sync() }
                }
            } else if SimklService.isConfigured {
                SettingsRow(label: "Connect SIMKL", icon: "qrcode") { connectSimkl() }
            }
            ToggleRow(label: "Sync watch history", isOn: $simklFlags.value.syncHistory)
            ToggleRow(label: "Sync Continue Watching", isOn: $simklFlags.value.syncContinueWatching)
            ToggleRow(label: "Sync watchlist", isOn: $simklFlags.value.syncWatchlist)
            ToggleRow(label: "Sync ratings", isOn: $simklFlags.value.syncRatings)
        }
        if simkl.isSignedIn {
            SettingsGroup {
                SettingsRow(label: "Disconnect SIMKL", destructive: true) { simkl.set(nil) }
            }
        }
        Color.clear.frame(height: 1)
            .fullScreenCover(item: $flow) { f in
                DeviceFlowSheet(flow: f) { f.cancel(); flow = nil }
            }
            .confirmation($confirm)
    }

    private func connectSimkl() {
        let f = DeviceFlow(title: "Connect SIMKL")
        flow = f
        f.task = Task { @MainActor in
            do {
                let pin = try await SimklService.startPin()
                f.url = pin.url; f.code = pin.userCode; f.status = "Waiting for you to approve…"
                let token = try await SimklService.poll(pin)
                let name = await SimklService.username(token)
                simkl.set(SimklSession(accessToken: token, username: name))
                flow = nil
                ToastCenter.shared.show("SIMKL connected")
                Task { await SimklService.sync() }
            } catch is CancellationError {
            } catch {
                f.status = error.localizedDescription
            }
        }
    }

    private func connect() {
        let f = DeviceFlow(title: "Connect Trakt")
        flow = f
        f.task = Task { @MainActor in
            do {
                let info = try await TraktService.startDeviceCode()
                f.url = info.verificationURL; f.code = info.userCode; f.status = "Waiting for you to approve…"
                let tokens = try await TraktService.pollDeviceToken(info)
                trakt.set(tokens, user: nil)
                let name = await TraktService.username()
                trakt.set(tokens, user: name)
                flow = nil
                ToastCenter.shared.show("Trakt connected")
                Task { await TraktSync.sync() }
            } catch is CancellationError {
            } catch {
                f.status = error.localizedDescription
            }
        }
    }
}

/// Observes a `DeviceFlow` so the sheet updates as the code arrives.
struct DeviceFlowSheet: View {
    @ObservedObject var flow: DeviceFlow
    let onCancel: () -> Void
    var body: some View {
        SignInSheet(title: flow.title, url: flow.url, code: flow.code, status: flow.status, onCancel: onCancel)
    }
}

// MARK: - About

private struct AboutSettings: View {
    @State private var confirm: ConfirmAction?

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 80, weight: .semibold))
                .frame(width: 160, height: 160)
                .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(LinearGradient(
                    colors: [Color.hex("#7B5CFF"), Color.hex("#3E63DD")], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text("Orivio TV").font(.system(size: 40, weight: .bold))
            Text("Version \(version)").textStyle(.meta)
        }
        .frame(maxWidth: .infinity)
        SettingsGroup(header: "System") {
            SettingsRow(label: "tvOS", value: UIDevice.current.systemVersion) {}
            SettingsRow(label: "Device", value: PerformanceProfile.deviceName) {}
        }
        SettingsGroup(footer: "Clears downloaded artwork, catalog and response caches. Your library, collections and settings stay.") {
            SettingsRow(label: "Clear Cache", destructive: true) {
                confirm = ConfirmAction(title: "Clear Cache?", message: "Artwork and catalogs will download again.", button: "Clear") {
                    CacheCleaner.clear()
                    ToastCenter.shared.show("Cache cleared")
                }
            }
        }
        .confirmation($confirm)
    }
}

enum CacheCleaner {
    /// Keeps the collections library (and anything else in OrivioCache that isn't a cache).
    static func clear() {
        URLCache.shared.removeAllCachedResponses()
        ImagePipeline.shared.purge()
        let fm = FileManager.default
        let caches = Persistence.cachesURL
        let keep: Set<String> = ["OrivioCache"]
        for name in (try? fm.contentsOfDirectory(atPath: caches.path)) ?? [] where !keep.contains(name) {
            if name.hasPrefix("orivio-home-catalogs") || name == "URLCache" || name == "player-scratch" || name.hasSuffix(".json") {
                try? fm.removeItem(at: caches.appendingPathComponent(name))
            }
        }
        let orivio = Persistence.orivioCacheURL
        for name in (try? fm.contentsOfDirectory(atPath: orivio.path)) ?? [] where !name.hasPrefix("collections") {
            try? fm.removeItem(at: orivio.appendingPathComponent(name))
        }
    }
}
