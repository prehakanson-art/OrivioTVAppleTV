import Foundation

/// P2P (torrent) streaming settings. tvOS can't run a torrent engine on-device
/// (the sandbox forbids bundled binaries / subprocesses, and there's no tvOS
/// BitTorrent library), so P2P routes through a TorrServer instance the user
/// runs on their network — the same server software the Android app bundles,
/// just remote. Mirrors Android's `TorrentSettings` client-relevant fields.
struct TorrentSettings: Codable, Equatable {
    var p2pEnabled: Bool = false
    /// Base URL of a TorrServer instance, e.g. http://192.168.1.10:8090
    var serverURL: String = ""
    var hideTorrentStats: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case p2pEnabled, serverURL, hideTorrentStats
    }

    /// Lenient decode, matching `PlayerSettings` / `PerformanceSettingsStore
    /// .Settings`. With synthesized `Codable` over three non-optional fields,
    /// adding ONE field would have failed the whole decode on every existing
    /// install and `init` would have fallen back to `.default` — silently
    /// wiping the TorrServer address the user typed in by hand, with P2P
    /// switched back off and no hint as to why.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        p2pEnabled = (try? c.decode(Bool.self, forKey: .p2pEnabled)) ?? false
        serverURL = (try? c.decode(String.self, forKey: .serverURL)) ?? ""
        hideTorrentStats = (try? c.decode(Bool.self, forKey: .hideTorrentStats)) ?? true
    }

    var isConfigured: Bool {
        p2pEnabled && !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// Normalized base URL (scheme added, trailing slash stripped).
    var normalizedServerURL: String {
        var s = serverURL.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static let `default` = TorrentSettings()
}

@MainActor
final class TorrentSettingsStore: ObservableObject {
    @Published var settings: TorrentSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if !applyingRemote { onLocalChange?() }
        }
    }

    var onLocalChange: (() -> Void)?
    private var applyingRemote = false
    private static let key = "orivio.torrent.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TorrentSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    func applyRemote(_ new: TorrentSettings) {
        guard new != settings else { return }
        applyingRemote = true
        settings = new
        applyingRemote = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
