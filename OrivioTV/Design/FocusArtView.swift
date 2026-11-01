import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Collection folder focus artwork (`focusGifUrl`): an animated GIF / WebP —
/// or a still that is simply meant to replace the cover on focus. `RemoteImage`
/// decodes only a first frame, so this has its own decoder.
///
/// Measured on the real collection assets: 480×270–800×600 with 120–241 frames,
/// 67–276 MB EACH decoded at full size. So frames are decoded through a
/// thumbnail sized to the tile, resampled to a target rate, capped in count,
/// and the decoded cache is budgeted in bytes. Only the focused tile animates.
enum FocusArtDecoder {
    /// Longest side in pixels (tiles are 220–400 pt).
    private static var maxPixel: CGFloat {
        if PerformanceProfile.isLowPower { return 240 }
        if PerformanceProfile.isMidPower { return 320 }
        return 480
    }
    /// The rate the loop is rebuilt at (frames are stepped from the source rate,
    /// so playback speed stays honest and the cap shortens the loop instead).
    private static var targetFPS: Double {
        if PerformanceProfile.isLowPower { return 12 }
        if PerformanceProfile.isMidPower { return 15 }
        return 20
    }
    private static var maxFrames: Int {
        if PerformanceProfile.isLowPower { return 24 }
        if PerformanceProfile.isMidPower { return 36 }
        return 60
    }
    /// Decoded bytes held: the focused tile plus the one just left.
    private static var byteBudget: Int {
        if PerformanceProfile.isLowPower { return 8 << 20 }
        if PerformanceProfile.isMidPower { return 16 << 20 }
        return 40 << 20
    }

    private static var cache: [String: UIImage] = [:]
    private static var bytes: [String: Int] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    private static let purgeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in FocusArtDecoder.purge() }

    /// Real collection data has doubled URLs ("…Hover.pnghttps://…Hover.png");
    /// keep the first.
    static func normalize(_ url: String) -> String {
        guard url.count > 1 else { return url }
        for scheme in ["https://", "http://"] {
            if let second = url.range(of: scheme, range: url.index(after: url.startIndex)..<url.endIndex) {
                return String(url[..<second.lowerBound])
            }
        }
        return url
    }

    /// Stills and animations are cached apart, so changing the setting takes effect.
    static func key(_ url: String, still: Bool) -> String { still ? "still|" + url : url }

    static func cached(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[key] else { return nil }
        if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
        return hit
    }

    static func store(_ image: UIImage, cost: Int, for key: String) {
        _ = purgeObserver
        lock.lock(); defer { lock.unlock() }
        if cache[key] == nil { order.append(key) }
        cache[key] = image
        bytes[key] = cost
        var total = bytes.values.reduce(0, +)
        // Never evict the entry just stored, even when it alone is over budget.
        while total > byteBudget, order.count > 1, let oldest = order.first {
            order.removeFirst()
            total -= bytes.removeValue(forKey: oldest) ?? 0
            cache.removeValue(forKey: oldest)
        }
    }

    static func purge() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(); bytes.removeAll(); order.removeAll()
    }

    private static var thumbOptions: CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixel,
         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    }

    /// First frame only (the "Still" setting, or a static asset).
    static func decodeStill(_ data: Data) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return (UIImage(cgImage: cg), cg.width * cg.height * 4)
    }

    /// Every (sampled) frame as one animated `UIImage`. A single-frame asset —
    /// some "*_Hover.gif" files are really JPEGs/PNGs — comes back as a still:
    /// it's still focus art meant to replace the cover.
    static func decode(_ data: Data) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        if count <= 1 { return decodeStill(data) }

        var total = 0.0
        for i in 0..<count { total += frameDelay(source, index: i) }
        if total <= 0 { total = Double(count) * 0.1 }
        let sourceFPS = Double(count) / total
        let step = max(1, Int((sourceFPS / targetFPS).rounded()))
        var frames: [UIImage] = []
        var cost = 0
        for i in Swift.stride(from: 0, to: count, by: step) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, thumbOptions) else { continue }
            frames.append(UIImage(cgImage: cg))
            cost += cg.width * cg.height * 4
            if frames.count >= maxFrames { break }
        }
        guard let first = frames.first else { return nil }
        guard frames.count > 1 else { return (first, cost) }
        // The slice of the original timeline these frames cover → real speed.
        let played = min(Double(frames.count * step) / sourceFPS, total)
        return (UIImage.animatedImage(with: frames, duration: played) ?? first, cost)
    }

    /// Per-frame delay for GIF, animated WebP and APNG (the collections use
    /// all three). 0 / near-0 is common shorthand for 0.1 s.
    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (dict, unclamped, clamped) in dicts {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let delay = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0.1
            return delay < 0.011 ? 0.1 : delay
        }
        return 0.1
    }
}

/// The encoded bytes on disk (3–4 MB each; URLSession won't HTTP-cache bodies
/// that large), so moving through a 100-folder row re-decodes but never
/// re-downloads. LRU by modification date, capped.
enum FocusArtStore {
    private static let dir: URL = {
        let d = Persistence.fileURL("focus-art")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let capBytes = 200 << 20

    private static func file(_ url: String) -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hash)
    }

    static func data(for url: URL) async -> Data? {
        let f = file(url.absoluteString)
        if let d = try? Data(contentsOf: f) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
            return d
        }
        guard let d = try? await HTTP.data(url, timeout: 30), !d.isEmpty else { return nil }
        // Writing and trimming the 200 MB cache is disk work; doing it inline
        // landed on the main actor as the focused tile started animating.
        Task.detached(priority: .utility) {
            try? d.write(to: f, options: .atomic)
            trim()
        }
        return d
    }

    private static func trim() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard var files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        func info(_ u: URL) -> (Date, Int) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        var total = files.reduce(0) { $0 + info($1).1 }
        guard total > capBytes else { return }
        files.sort { info($0).0 < info($1).0 }
        for f in files where total > capBytes * 3 / 4 {
            total -= info(f).1
            try? fm.removeItem(at: f)
        }
    }
}

/// Plays a folder's focus artwork. Stays MOUNTED and goes dormant when
/// inactive (inserting/removing a UIKit view on every focus step makes tvOS
/// re-resolve focus and strands the card's lift). Draws nothing until decoded,
/// so the cover underneath stays until the art is really there.
struct FocusArtView: UIViewRepresentable {
    let url: String
    var still = false
    var active = true
    /// Ready (true) or failed / dormant (false). Always delivered async.
    var onReady: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        // The image's intrinsic size must never size the tile.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            v.setContentHuggingPriority(.defaultLow, for: axis)
            v.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return v
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let co = context.coordinator
        guard active else {
            co.task?.cancel()
            co.loadedKey = nil
            if view.image != nil { view.stopAnimating(); view.image = nil }
            return
        }
        let url = FocusArtDecoder.normalize(self.url)
        let key = FocusArtDecoder.key(url, still: still)
        if co.loadedKey == key, view.image != nil { return }
        co.loadedKey = key
        view.image = nil
        // Cancel before any early return, so an older load can't land later.
        co.task?.cancel()
        let onReady = self.onReady
        if let hit = FocusArtDecoder.cached(key) {
            view.image = hit
            view.startAnimating()
            DispatchQueue.main.async { onReady(true) }
            return
        }
        let still = self.still
        co.task = Task { [weak view] in
            var decoded: (image: UIImage, cost: Int)?
            if let remote = URL(string: url), let data = await FocusArtStore.data(for: remote), !Task.isCancelled {
                decoded = await Task.detached(priority: .userInitiated) {
                    still ? FocusArtDecoder.decodeStill(data) : FocusArtDecoder.decode(data)
                }.value
            }
            await MainActor.run {
                if let decoded { FocusArtDecoder.store(decoded.image, cost: decoded.cost, for: key) }
                // Retargeted or cancelled while loading: cache it, don't paint it.
                guard !Task.isCancelled, co.loadedKey == key, let view else { return }
                guard let decoded else { onReady(false); return }
                view.image = decoded.image
                view.startAnimating()
                onReady(true)
            }
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        view.stopAnimating()
        view.image = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedKey: String?
        var task: Task<Void, Never>?
    }
}
