import Foundation

/// Writes the Continue Watching list into the shared app-group container so
/// the Top Shelf extension can render it on the tvOS home screen. Called from
/// ProgressStore whenever progress persists — the snapshot is tiny (≤10
/// entries) and written off-main alongside the progress save itself.
///
/// Sideload caveat: if the signing tool strips the app-group entitlement,
/// `containerURL` is nil and this is a silent no-op — the app works, the
/// shelf just stays empty.
enum TopShelfExporter {
    /// Mirrored by TopShelfProvider.Entry in the extension target — keep the
    /// fields/keys in sync.
    struct Entry: Codable {
        let id: String
        let type: String
        let title: String
        let subtitle: String?
        let imageURL: String?
    }

    /// Build the export entries on the caller's (main) side — cheap — so the
    /// disk write can happen on a background task with plain value data.
    static func entries(from progresses: [WatchProgress]) -> [Entry] {
        progresses.prefix(10).map { p in
            var subtitle: String?
            if let s = p.season, let e = p.episode {
                subtitle = "S\(s):E\(e)"
                if let t = p.episodeTitle, !t.isEmpty { subtitle! += " · \(t)" }
            }
            return Entry(
                id: p.metaID,
                type: p.type,
                title: p.name,
                subtitle: subtitle,
                // Wide art to match the .hdtv shape: episode still, then
                // backdrop, then poster as a last resort.
                imageURL: p.episodeThumbnail ?? p.background ?? p.poster
            )
        }
    }

    /// Persist to the shared container. Safe to call from any thread.
    static func write(_ entries: [Entry]) {
        guard let dir = AppGroupResolver.containerURL else { return }
        let file = dir.appendingPathComponent("topshelf.json")
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
