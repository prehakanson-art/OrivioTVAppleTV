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
    /// Longest side in PIXELS. The tile is 260–360pt, so even the top tier is
    /// already supersampled; the lower tiers trade sharpness for survival.
    /// Sized per device because a 4K gen-1 (A10X, 3 GB) was CRASHING on the
    /// first version of this.
    private static var maxPixel: CGFloat {
        if PerformanceProfile.isLowPower { return 240 }
        if PerformanceProfile.isMidPower { return 320 }
        return 480
    }
    /// Frames per second to REBUILD the loop at. The bug in the first version
    /// was sampling to a fixed 24 frames while keeping the original duration —
    /// a 241-frame/4s GIF became 22 frames over 4s, i.e. 5.5fps, which is what
    /// "insanely choppy" was. Now the duration is recomputed from the frames
    /// actually kept, so playback rate is honest.
    private static var targetFPS: Double {
        if PerformanceProfile.isLowPower { return 12 }
        if PerformanceProfile.isMidPower { return 15 }
        return 20
    }
    /// Hard ceiling on frames regardless of length, so a 30-second GIF can't
    /// blow the budget on its own.
    private static var maxFrames: Int {
        if PerformanceProfile.isLowPower { return 24 }
        if PerformanceProfile.isMidPower { return 36 }
        return 60
    }
    /// Total decoded bytes held. Only the focused tile animates, so this only
    /// needs to cover the current tile plus the one you just came from.
    private static var byteBudget: Int {
        if PerformanceProfile.isLowPower { return 8 * 1024 * 1024 }
        if PerformanceProfile.isMidPower { return 16 * 1024 * 1024 }
        return 40 * 1024 * 1024
    }

    private static var cache: [String: UIImage] = [:]
    private static var bytes: [String: Int] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    /// Repairs malformed focus-art URLs seen in real collection data.
    ///
    /// Some entries have the URL DOUBLED — "…Hover.pnghttps://…Hover.png".
    /// i.ibb.co happens to ignore the trailing garbage and serve the right
    /// bytes, so it works by luck; any stricter host would 404. Truncate at the
    /// second scheme so it doesn't depend on that.
    static func normalize(_ url: String) -> String {
        let scheme = "https://"
        if let second = url.range(of: scheme, range: url.index(url.startIndex, offsetBy: min(1, url.count))..<url.endIndex) {
            return String(url[url.startIndex..<second.lowerBound])
        }
        return url
    }

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

    /// Decode ONLY the first frame, for "partial" quality. Same thumbnail and
    /// budget rules; no animation, so a 240-frame GIF costs one still.
    static func decodeFirstFrame(_ data: Data) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        return (UIImage(cgImage: cg), cg.width * cg.height * 4)
    }

    /// Decode animated image data (GIF *or* animated WebP — the collections use
    /// both, and ImageIO reads each) into one `UIImage` carrying its frames,
    /// plus the decoded byte cost. Returns nil for non-animated or undecodable
    /// data so the caller falls back to the static cover art.
    static func decode(_ data: Data) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)

        // STILL focus art. A chunk of the real collection assets are static
        // despite being named "*_Hover.gif" / "*-Hover.png": the github.com
        // ones are JPEGs with a .gif name (rewriting them to
        // raw.githubusercontent.com returns byte-identical JPEGs, so it is the
        // asset that is static, not the URL that is wrong), and the i.ibb.co
        // ones are PNGs. They are still FOCUS artwork — a different image meant
        // to replace the cover while the tile is focused — so show them instead
        // of discarding them, which is why those tiles previously did nothing.
        if count == 1 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
            else { return nil }
            return (UIImage(cgImage: cg), cg.width * cg.height * 4)
        }

        // Source runtime, so the rebuilt loop lasts as long as the original.
        var total: Double = 0
        for i in 0 ..< count { total += frameDelay(source, index: i) }
        if total <= 0 { total = Double(count) * 0.1 }

        // Step from the SOURCE rate, not from a frame budget. Spreading a fixed
        // number of samples across the whole GIF is what made this choppy: a
        // 241-frame/4s (60fps) clip sampled to 36 frames still spanned all 4s,
        // i.e. 9fps. Stepping by sourceFPS/targetFPS keeps real-time pacing, and
        // the frame cap then simply SHORTENS the loop instead of slowing it —
        // a smooth 2.4s loop reads far better than a stuttering 4s one on what
        // is decorative background motion.
        let sourceFPS = Double(count) / total
        let step = max(1, Int((sourceFPS / targetFPS).rounded()))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        var frames: [UIImage] = []
        var cost = 0
        for i in Swift.stride(from: 0, to: count, by: step) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, opts as CFDictionary)
            else { continue }
            frames.append(UIImage(cgImage: cg))
            cost += cg.width * cg.height * 4
            if frames.count >= maxFrames { break }
        }
        guard frames.count > 1 else { return nil }
        // Duration = the slice of the ORIGINAL timeline these frames cover, so
        // the loop runs at real speed (frames.count / played == targetFPS).
        let played = min(Double(frames.count * step) / sourceFPS, total)
        return (UIImage.animatedImage(with: frames, duration: played) ?? frames[0], cost)
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
    /// "Partial" quality: decode ONE frame and show it as a still. Keeps the
    /// art change on focus for a fraction of the cost — a single ~0.5 MB image
    /// instead of dozens of frames.
    var stillOnly: Bool = false
    /// Called once the GIF is ready (or fails), so the parent can decide whether
    /// to hide the still artwork behind it.
    var onLoaded: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        // A UIImageView's intrinsicContentSize is the IMAGE's size, and SwiftUI
        // honours it — so the view grew to the GIF's dimensions, spilled past
        // the tile's rounded border and shoved grey tile-surface into the
        // neighbouring cells. Drop the intrinsic size's authority entirely so
        // the parent frame decides.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in GIFDecoder.purge() }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        // Normalize FIRST so the cache key, the coordinator's dedupe key and
        // the fetch all agree — keying the cache on the raw URL while fetching
        // the repaired one would miss on every focus.
        let url = GIFDecoder.normalize(self.url)
        // Already showing this one — don't restart it on every focus re-render.
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
        NSLog("[OrivioGIF] load start %@", url.suffix(40).description)
        context.coordinator.task = Task { [weak view] in
            guard let remote = URL(string: url) else {
                NSLog("[OrivioGIF] bad URL"); await MainActor.run { onLoaded?(false) }; return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: remote), !Task.isCancelled
            else {
                NSLog("[OrivioGIF] fetch FAILED %@", url.suffix(40).description)
                await MainActor.run { onLoaded?(false) }; return
            }
            NSLog("[OrivioGIF] fetched %d bytes", data.count)
            // Decode off the main actor — a 100-frame GIF is real work.
            let stillOnly = self.stillOnly
            let decoded = await Task.detached(priority: .userInitiated) {
                stillOnly ? GIFDecoder.decodeFirstFrame(data) : GIFDecoder.decode(data)
            }.value
            await MainActor.run {
                guard !Task.isCancelled, let decoded, let view else {
                    NSLog("[OrivioGIF] decode FAILED (cancelled=%@ decoded=%@ view=%@)",
                          Task.isCancelled ? "y" : "n", decoded == nil ? "nil" : "ok",
                          view == nil ? "nil" : "ok")
                    onLoaded?(false); return
                }
                NSLog("[OrivioGIF] playing: %d frames, %.2fs, %.1f MB",
                      decoded.image.images?.count ?? 0, decoded.image.duration,
                      Double(decoded.cost) / 1_048_576)
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
