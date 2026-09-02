import Foundation

/// Reclaims the player's scratch space in `tmp/` at launch.
///
/// The DV remuxer writes its fMP4 segments to `tmp/dv-remux-<uuid>/` and
/// deletes the directory when the session ends. That deletion is best-effort
/// by construction — it runs as the player is being dismissed, and a remux
/// session is exactly the workload most likely to get the app jetsammed on a
/// 3 GB box, so the process is often gone before the delete completes. Every
/// time that happens the directory is orphaned with no owner left to remove
/// it: found on a real Apple TV 4K (1st gen) as **3.2 GB across 15 leaked
/// directories**, three of them ~1 GB each.
///
/// Nothing else ever cleaned them up. tvOS does purge `tmp/` under storage
/// pressure, but only once the box is nearly full — long after the app has
/// been swapping, stuttering and getting killed. So the sweep has to be ours,
/// and it has to run at LAUNCH: that is the one moment we know for certain
/// that no remuxer owns any of these directories.
///
/// CFNetwork's response spool files (`tmp/CFNetworkDownload_*.tmp`) leak the
/// same way and for the same reason — the app dies with requests in flight —
/// so they are swept on the same pass (179 MB / 12,231 files on that device).
enum PlayerTempSweep {
    private static let remuxPrefix = "dv-remux-"
    private static let spoolPrefix = "CFNetworkDownload_"

    /// Delete every orphaned player scratch directory and network spool file.
    ///
    /// Call once, at launch, BEFORE any playback can start. Runs off the main
    /// thread: this is thousands of unlinks and real filesystem work, and it
    /// must never sit in front of the first frame of UI.
    static func sweepAtLaunch() {
        Task.detached(priority: .utility) { sweep() }
    }

    /// The sweep itself. Synchronous — call it directly only from a background
    /// context (or a test).
    static func sweep() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey]
        ) else { return }

        var reclaimed: Int64 = 0
        var directories = 0
        var spools = 0

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(remuxPrefix) {
                reclaimed += directorySize(of: entry, fm: fm)
                try? fm.removeItem(at: entry)
                directories += 1
            } else if name.hasPrefix(spoolPrefix) {
                reclaimed += Int64(
                    (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0
                )
                try? fm.removeItem(at: entry)
                spools += 1
            }
        }

        guard directories > 0 || spools > 0 else { return }
        NSLog("[OrivioSweep] reclaimed %.1f MB — %d orphaned remux dirs, %d network spool files",
              Double(reclaimed) / (1024 * 1024), directories, spools)
    }

    private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
        }
        return total
    }
}
