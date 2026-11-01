import SwiftUI

/// Settings → Integrations → Plex / Jellyfin.
struct MediaServerSettingsGroup: View {
    @ObservedObject private var servers = MediaServerStore.shared
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsGroup(header: "Media Servers", footer: "Your Plex or Jellyfin libraries appear under Library → Sources and play the original files directly.") {
            ForEach(MediaServerKind.allCases) { kind in
                let a = servers.account(kind)
                SettingsRow(label: kind.displayName, value: a.map { $0.serverName ?? "Connected" } ?? "Not connected", chevron: true) {
                    nav.push(kind.displayName) { MediaServerPage(kind: kind) }
                }
            }
        }
    }
}

private struct MediaServerPage: View {
    let kind: MediaServerKind
    @ObservedObject private var servers = MediaServerStore.shared
    @EnvironmentObject private var nav: SettingsNav
    @State private var flow: DeviceFlow?
    @State private var confirm: ConfirmAction?
    @State private var testStatus: String?

    var body: some View {
        if let a = servers.account(kind) {
            SettingsGroup {
                SettingsRow(label: "Server", value: a.serverName ?? kind.displayName) {}
                SettingsRow(label: "Address", value: Self.host(a.serverURL)) {}
                if let u = a.username { SettingsRow(label: "User", value: u) {} }
                SettingsRow(label: "Test Connection", value: testStatus) {
                    testStatus = "Testing…"
                    Task { testStatus = (await MediaServerAPI.libraries(a)).map { "\($0.count) librar\($0.count == 1 ? "y" : "ies")" } ?? "Not responding" }
                }
            }
            SettingsGroup {
                if kind == .plex {
                    SettingsRow(label: "Choose Another Server", chevron: true) { startPlex() }
                }
                SettingsRow(label: "Disconnect", destructive: true) {
                    confirm = ConfirmAction(title: "Disconnect \(kind.displayName)?", message: "Its libraries leave the Library tab.", button: "Disconnect") {
                        servers.set(nil, for: kind)
                    }
                }
            }
        } else if kind == .plex {
            SettingsGroup(footer: "Shows a code to enter at plex.tv/link, then finds your servers.") {
                SettingsRow(label: "Sign In with Plex", icon: "qrcode") { startPlex() }
            }
        } else {
            JellyfinConnectForm()
        }
        Color.clear.frame(height: 1)
            .confirmation($confirm)
            .fullScreenCover(item: $flow) { f in
                DeviceFlowSheet(flow: f) { f.cancel(); flow = nil }
            }
    }

    static func host(_ url: String) -> String {
        guard let u = URL(string: url), let h = u.host else { return url }
        return u.port.map { "\(h):\($0)" } ?? h
    }

    // MARK: Plex PIN → servers

    private func startPlex() {
        let f = DeviceFlow(title: "Sign In with Plex")
        flow = f
        f.task = Task { @MainActor in
            guard let pin = await PlexService.requestPin() else { f.status = "Couldn't reach plex.tv."; return }
            f.url = PlexService.linkURL
            f.code = pin.code
            f.status = "Waiting for you to enter the code…"
            let deadline = Date().addingTimeInterval(15 * 60)
            var token: String?
            while token == nil, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                token = await PlexService.pollPin(pin)
            }
            guard let token, !Task.isCancelled else { if !Task.isCancelled { f.status = "The code expired. Try again." }; return }
            f.status = "Finding your servers…"
            let list = await PlexService.servers(token: token)
            guard !list.isEmpty else { f.status = "No Plex Media Server on this account."; return }
            if list.count == 1 {
                f.status = "Connecting to \(list[0].name)…"
                if await connect(list[0], accountToken: token) { flow = nil } else { f.status = "Couldn't reach \(list[0].name) from this Apple TV." }
                return
            }
            flow = nil
            nav.push("Choose a Server") {
                PlexServerPickerPage(servers: list) { server in await connect(server, accountToken: token) }
            }
        }
    }

    private func connect(_ server: PlexService.ServerCandidate, accountToken: String) async -> Bool {
        let token = server.accessToken ?? accountToken
        guard let url = await PlexService.reachableURL(server, token: token) else { return false }
        servers.set(MediaServerAccount(kind: .plex, serverURL: url, token: token, serverName: server.name), for: .plex)
        return true
    }
}

private struct PlexServerPickerPage: View {
    let servers: [PlexService.ServerCandidate]
    let connect: (PlexService.ServerCandidate) async -> Bool
    @EnvironmentObject private var nav: SettingsNav
    @State private var status: [String: String] = [:]

    var body: some View {
        SettingsGroup(footer: "Orivio tries the local address first, then remote, then Plex's relay.") {
            ForEach(servers) { s in
                SettingsRow(label: s.name, detail: "\(s.connections.count) address\(s.connections.count == 1 ? "" : "es")", value: status[s.id]) {
                    status[s.id] = "Connecting…"
                    Task {
                        if await connect(s) { nav.pop() } else { status[s.id] = "Unreachable" }
                    }
                }
            }
        }
    }
}

/// The form outlives its page: each field's text-entry page replaces it in the pane.
@MainActor
private final class JellyfinDraft: ObservableObject {
    static let shared = JellyfinDraft()
    @Published var address = ""
    @Published var username = ""
    @Published var password = ""
    @Published var status: String?
    @Published var working = false
}

private struct JellyfinConnectForm: View {
    @ObservedObject private var servers = MediaServerStore.shared
    @ObservedObject private var draft = JellyfinDraft.shared

    var body: some View {
        SettingsGroup(footer: "The address of your Jellyfin server, e.g. 192.168.1.20:8096 or https://jellyfin.example.com.") {
            TextEntryRow(label: "Server address", text: $draft.address, placeholder: "192.168.1.20:8096", keyboard: .URL)
            TextEntryRow(label: "Username", text: $draft.username)
            TextEntryRow(label: "Password", text: $draft.password, masked: true)
        }
        SettingsGroup(footer: draft.status) {
            SettingsRow(label: draft.working ? "Connecting…" : "Connect", icon: "link") { connect() }
        }
    }

    private func connect() {
        guard !draft.working else { return }
        guard let url = JellyfinService.normalizedServerURL(draft.address) else { draft.status = "Enter the server address first."; return }
        guard !draft.username.isEmpty else { draft.status = "Enter your username."; return }
        draft.working = true
        draft.status = nil
        Task {
            let (account, message) = await JellyfinService.authenticate(serverURL: url, username: draft.username, password: draft.password)
            draft.working = false
            if let account {
                servers.set(account, for: .jellyfin)
                draft.password = ""
            } else {
                draft.status = message
            }
        }
    }
}
