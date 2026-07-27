import SwiftUI
import UIKit
import ImageIO

/// Animated GIF support for collection folder tiles (`focusGifUrl`).
///
/// The rest of the app draws artwork through `RemoteImage`, which decodes with
/// `UIImage(data:)` — that only ever yields a GIF's FIRST FRAME, so a folder's
/// focus GIF looked like a still (or nothing, when the first frame is blank).
/// Decoding every frame needs ImageIO, hence this separate view.
///
/// Frames are decoded once and cached, because a collection like "Actors" has
/// 100 folders each with its own GIF and re-decoding on every focus move would
/// be brutal on an A10X.
enum GIFDecoder {
    /// MEASURED against the real collection GIFs: they are 480x270–800x600 with
    /// 120–241 frames, which decodes to 67–276 MB EACH at full size. Caching a
    /// handful of those would jetsam an Apple TV outright. Two hard limits keep
    /// it sane, and the cache is budgeted in BYTES rather than entries:
    ///
    ///  • decode through a thumbnail at `maxPixel`, since the tile is only
    ///    260–360pt wide — full 800x600 frames are thrown away by the GPU anyway
    ///  • sample down to `maxFrames`, because a 241-frame/4s GIF is 60fps and a
    ///    background loop reads identically at ~20fps
    private static let maxPixel: CGFloat = 720      // longest side, pixels
    private static let maxFrames = 24
    /// Total decoded bytes held. Only the focused tile animates, so a couple of
    /// GIFs is all that's ever needed at once.
    private static let byteBudget = 96 * 1024 * 1024

    private static var cache: [String: UIImage] = [:]
    private static var bytes: [String: Int] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    static func cached(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    static func store(_ image: UIImage, cost: Int, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] == nil { order.append(key) }
        cache[key] = image
        bytes[key] = cost
        var total = bytes.values.reduce(0, +)
        while total > byteBudget, let oldest = order.first {
            order.removeFirst()
            total -= bytes.removeValue(forKey: oldest) ?? 0
            cache.removeValue(forKey: oldest)
        }
    }

    /// Drop everything on a memory warning — same policy as the image and
    /// response caches. A dropped GIF just re-decodes next time it's focused.
    static func purge() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(); bytes.removeAll(); order.removeAll()
    }

    /// Decode animated image data (GIF *or* animated WebP — the collections use
    /// both, and ImageIO reads each) into one `UIImage` carrying its frames,
    /// plus the decoded byte cost. Returns nil for non-animated or undecodable
    /// data so the caller falls back to the static cover art.
    static func decode(_ data: Data) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }   // not animated — RemoteImage handles it

        // Full duration first, so sampling frames doesn't speed the loop up.
        var total: Double = 0
        for i in 0 ..< count { total += frameDelay(source, index: i) }
        if total <= 0 { total = Double(count) * 0.1 }

        let stride = max(1, Int((Double(count) / Double(maxFrames)).rounded(.up)))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        var frames: [UIImage] = []
        var cost = 0
        for i in Swift.stride(from: 0, to: count, by: stride) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, opts as CFDictionary)
            else { continue }
            frames.append(UIImage(cgImage: cg))
            cost += cg.width * cg.height * 4
        }
        guard frames.count > 1 else { return nil }
        return (UIImage.animatedImage(with: frames, duration: total) ?? frames[0], cost)
    }

    /// Per-frame delay, honouring the unclamped value when present (GIF spec
    /// stores hundredths of a second and 0 is common shorthand for 10).
    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }
}

/// Plays an animated GIF from a URL. Renders nothing until the GIF has decoded,
/// so the caller can keep the static cover visible underneath and cross-fade.
struct AnimatedGIFView: UIViewRepresentable {
    let url: String
    var contentMode: UIView.ContentMode = .scaleAspectFit
    /// Called once the GIF is ready (or fails), so the parent can decide whether
    /// to hide the still artwork behind it.
    var onLoaded: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        context.coordinator.memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in GIFDecoder.purge() }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        // Already showing this GIF — don't restart it on every focus re-render.
        if context.coordinator.loadedURL == url, view.image != nil { return }
        context.coordinator.loadedURL = url
        view.image = nil

        if let hit = GIFDecoder.cached(url) {
            view.image = hit
            view.startAnimating()
            onLoaded?(true)
            return
        }
        context.coordinator.task?.cancel()
        context.coordinator.task = Task { [weak view] in
            guard let remote = URL(string: url),
                  let (data, _) = try? await URLSession.shared.data(from: remote),
                  !Task.isCancelled
            else { await MainActor.run { onLoaded?(false) }; return }
            // Decode off the main actor — a 100-frame GIF is real work.
            let decoded = await Task.detached(priority: .userInitiated) {
                GIFDecoder.decode(data)
            }.value
            await MainActor.run {
                guard !Task.isCancelled, let decoded, let view else {
                    onLoaded?(false); return
                }
                GIFDecoder.store(decoded.image, cost: decoded.cost, for: url)
                view.image = decoded.image
                view.startAnimating()
                onLoaded?(true)
            }
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        view.stopAnimating()
        view.image = nil          // release the frames with the view
        if let token = coordinator.memoryWarning {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: String?
        var task: Task<Void, Never>?
        var memoryWarning: NSObjectProtocol?
    }
}
