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

    /// Total bytes of the NuvioCache directory (source lists, meta, images…).
    static func cacheSize() -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func cacheSizeLabel() -> String {
        ByteCountFormatter.string(fromByteCount: cacheSize(), countStyle: .file)
    }

    /// Clear all app caches: the on-disk NuvioCache tree + the shared URL cache.
    static func clearCaches() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        URLCache.shared.removeAllCachedResponses()
    }
}
