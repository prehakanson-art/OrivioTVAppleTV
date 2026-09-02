import Foundation

struct OrivioLocalBackup: Codable {
    struct AddonState: Codable {
        let manifestURL: String
        let enabled: Bool
    }

    let version: Int
    let createdAt: Date
    let addons: [AddonState]
    let pluginRepositoryURLs: [String]
    let library: [SavedLibraryItem]
    let progress: [WatchProgress]
    let watched: [WatchedItem]
}

enum OrivioLocalBackupService {
    /// Format version this build writes and is able to read. Bump only with a
    /// reader that understands the older shape.
    static let currentVersion = 1

    @MainActor
    static func exportBackup(
        addonManager: AddonManager,
        plugins: PluginStore,
        library: LibraryStore,
        progress: ProgressStore,
        watched: WatchedStore
    ) -> String? {
        let backup = OrivioLocalBackup(
            version: currentVersion,
            createdAt: Date(),
            addons: addonManager.addons.map {
                OrivioLocalBackup.AddonState(manifestURL: $0.manifestURL, enabled: $0.enabled)
            },
            pluginRepositoryURLs: plugins.repositories.map(\.url),
            library: library.allForSync(),
            // streamURL is stripped: a resume link is routinely a debrid
            // "unrestricted" URL or otherwise carries the user's token, and the
            // backup is a plain-text document the user copies off the box —
            // while the export screen promises it holds no provider
            // credentials. Resume positions survive; only the link is dropped
            // (playback re-resolves a fresh one anyway).
            progress: progress.allForSync().map { row in
                var stripped = row
                stripped.streamURL = nil
                return stripped
            },
            watched: watched.allForSync()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(backup) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @MainActor
    static func importBackup(
        _ text: String,
        addonManager: AddonManager,
        plugins: PluginStore,
        library: LibraryStore,
        progress: ProgressStore,
        watched: WatchedStore
    ) async -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8),
              let backup = try? decoder.decode(OrivioLocalBackup.self, from: data) else {
            return "Couldn't read backup JSON."
        }
        // `version` was decoded and then ignored: a file written by a future
        // build imported "successfully" while silently dropping whatever it
        // added. Refuse it instead of half-restoring the user's data.
        guard backup.version > 0, backup.version <= currentVersion else {
            return "This backup was made by a newer version of Orivio (format \(backup.version)) — update the app first."
        }

        var addonInstalled = 0
        var addonFailed = 0
        for addon in backup.addons {
            do {
                try await addonManager.install(manifestURL: addon.manifestURL)
                if let installed = addonManager.addons.first(where: { $0.manifestURL == AddonManager.normalizeManifestURL(addon.manifestURL) }) {
                    addonManager.setEnabled(installed, addon.enabled)
                }
                addonInstalled += 1
            } catch {
                addonFailed += 1
            }
        }

        var pluginInstalled = 0
        for url in backup.pluginRepositoryURLs {
            await plugins.addRepository(url)
            pluginInstalled += 1
        }

        for item in backup.library { library.add(item) }
        progress.importEntries(backup.progress)
        watched.importItems(backup.watched)

        var parts = [
            "Imported \(backup.library.count) library items",
            "\(backup.progress.count) progress rows",
            "\(backup.watched.count) watched rows",
            "\(addonInstalled) add-ons",
            "\(pluginInstalled) plugin repos"
        ]
        if addonFailed > 0 { parts.append("\(addonFailed) add-ons failed") }
        return parts.joined(separator: " · ")
    }
}
