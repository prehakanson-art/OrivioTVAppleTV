import Foundation
import UIKit

/// Build info + cache management for the About / Diagnostics screen. The
/// Android app's Advanced settings are mostly Compose-specific (fast focus
/// nav, smooth bring-into-view, compose highlighter) with no tvOS analog, and
/// Sentry / playback-issue reports are telemetry we don't ship in a sideloaded
/// build — so this covers the genuinely portable pieces.
enum DiagnosticsService {
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    static var systemVersion: String {
        "tvOS \(UIDevice.current.systemVersion)"
    }

    static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let raw = String(cString: model)
        return raw.isEmpty ? UIDevice.current.model : raw
    }

    /// Root of the app's on-disk caches (DiskCache lives under NuvioCache/).
    private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrivioCache", isDirectory: true)
    }

    /// Entries under the cache root that are NOT caches.
    ///
    /// The collections library is the user's own content (a signed-out user has
    /// no other copy), and the plugin JS bodies have no re-download path once
    /// removed — `PluginStore.streams()` just returns [] for every scraper until
    /// the repo is removed and re-added. "Clear cache" used to delete the whole
    /// tree, so it silently wiped custom collections and disabled every plugin.
    private static let protectedEntries: Set<String> = [
        "collections-library.json",   // CollectionsStore.libraryFileURL
        "scrapers"                    // PluginStore.jsCache — plugin JS bodies
    ]

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in e {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Bytes the "Clear cache" button would actually free — so the number the
    /// user reads matches what pressing it does.
    ///
    /// Includes the image cache, which lives in a SIBLING directory
    /// (`Caches/orivio-images`, budgeted at 512 MB) rather than under the cache
    /// root: it was neither counted nor cleared, so the About row could report
    /// a few MB while half a gigabyte of artwork sat on disk — and its own
    /// subtitle told the user images were included.
    static func cacheSize() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil
        )) ?? []
        let rootBytes = contents
            .filter { !protectedEntries.contains($0.lastPathComponent) }
            .reduce(0) { $0 + size(of: $1) }
        return rootBytes + size(of: ImageCache.diskDirectory)
    }

    static func cacheSizeLabel() -> String {
        ByteCountFormatter.string(fromByteCount: cacheSize(), countStyle: .file)
    }

    /// Clear the app's caches: everything under the cache root EXCEPT the
    /// protected entries above, the image cache in its sibling directory, and
    /// the shared URL cache.
    ///
    /// The per-cache directories under the root are deleted, not just emptied —
    /// each `DiskCache` created its directory once at init, so afterwards every
    /// `store()` failed silently and the app ran uncached until relaunch.
    /// `DiskCache.store` now recreates its directory on a failed write, and
    /// `ImageCache.clearDisk()` recreates its own, so both come back to life
    /// immediately. Recreating only `cacheRoot` here (as before) is enough for
    /// the root itself.
    static func clearCaches() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        for url in contents where !protectedEntries.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        ImageCache.shared.clearDisk()
        URLCache.shared.removeAllCachedResponses()
    }
}
