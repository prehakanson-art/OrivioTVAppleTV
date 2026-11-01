import SwiftUI
import UIKit
import ImageIO

/// Fetch → downsample (ImageIO thumbnail at the tier's max pixel size) →
/// memory cache (cost-limited by tier, purged on memory warning). The disk
/// layer is the shared `URLCache`.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        cache.totalCostLimit = PerformanceProfile.imageCacheBytes
        cache.countLimit = PerformanceProfile.imageCacheItems
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> String { "\(Int(maxPixel))|\(url.absoluteString)" }

    /// Stremio catalog add-ons often hand over `/original/` TMDB art. Fetching
    /// a 3–8 MB original and then downsampling it to 420 px wastes most of the
    /// load time; ask TMDB for the smallest size that still covers `maxPixel`.
    private func downloadURL(_ url: URL, maxPixel: CGFloat) -> URL {
        let marker = "/t/p/original/"
        guard url.host == "image.tmdb.org", url.path.contains(marker) else { return url }
        let size: String
        switch maxPixel {
        case ..<420: size = "w342"
        case ..<620: size = "w500"
        case ..<1000: size = "w780"
        case ..<1600: size = "w1280"
        default:
            guard PerformanceProfile.isConstrained else { return url }
            size = "w1280"
        }
        let rewritten = url.absoluteString.replacingOccurrences(of: marker, with: "/t/p/\(size)/")
        return URL(string: rewritten) ?? url
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(downloadURL(url, maxPixel: maxPixel), maxPixel) as NSString)
    }

    /// Whatever size of this image is already in memory (largest first).
    func anyCached(_ url: URL) -> UIImage? {
        for size in [ImageSize.backdrop, ImageSize.landscape, ImageSize.poster, 600, 400, 200] {
            if let img = cached(url, maxPixel: size) { return img }
        }
        return nil
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let target = downloadURL(url, maxPixel: maxPixel)
        let k = key(target, maxPixel)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        // Look up and register in one critical section, so two cards asking for
        // the same image at once share one download (they used to race).
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let t = Task<UIImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                guard let data = try? await HTTP.data(target, timeout: 20) else { return nil }
                guard let img = Self.downsample(data, maxPixel: maxPixel, trimBars: maxPixel >= 1900) else { return nil }
                let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
                self?.cache.setObject(img, forKey: k as NSString, cost: cost)
                return img
            }
            inFlight[k] = t
            return t
        }
        let result = await task.value
        lock.withLock { inFlight[k] = nil }
        return result
    }

    static func downsample(_ data: Data, maxPixel: CGFloat, trimBars: Bool = false) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: trimBars ? trimLetterbox(cg) : cg)
    }

    /// Wide art (backdrops, landscape cards) sometimes comes with cinema
    /// letterbox bars baked in — full screen they read as a black band across
    /// the top. Crops matching dark (or transparent) bars off the top AND bottom;
    /// both must be there, so a dark sky alone is never cut.
    static func trimLetterbox(_ cg: CGImage) -> CGImage {
        let w = cg.width, h = cg.height
        let bpp = cg.bitsPerPixel / 8
        guard h >= 120, w >= 200, cg.bitsPerComponent == 8, bpp >= 3,
              let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return cg }
        let bpr = cg.bytesPerRow
        // Where alpha sits (if anywhere) in each pixel.
        let info = cg.alphaInfo
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        var alphaAt: Int? = nil
        switch info {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaAt = little ? 3 : 0
        case .premultipliedLast, .last, .noneSkipLast: alphaAt = little ? 0 : 3
        default: alphaAt = bpp == 4 ? 3 : nil
        }
        func isBar(_ y: Int) -> Bool {
            let row = base + y * bpr
            var x = 0
            while x < w {
                let p = row + x * bpp
                for c in 0..<min(bpp, 4) where c != alphaAt {
                    if p[c] > 26 {
                        if let a = alphaAt, p[a] < 16 { break }   // transparent counts as bar
                        return false
                    }
                }
                x += 6
            }
            return true
        }
        let limit = h / 4
        var top = 0
        while top < limit, isBar(top) { top += 1 }
        var bottom = 0
        while bottom < limit, isBar(h - 1 - bottom) { bottom += 1 }
        let minBar = h / 30
        #if DEBUG
        if top >= minBar || bottom >= minBar {
            DebugLog.write("[letterbox] \(w)x\(h) top=\(top) bottom=\(bottom) alpha=\(info.rawValue) little=\(little) bpp=\(bpp)")
        }
        #endif
        guard top >= minBar, bottom >= minBar else { return cg }
        return cg.cropping(to: CGRect(x: 0, y: top, width: w, height: h - top - bottom)) ?? cg
    }

    func purge() { cache.removeAllObjects() }

    func prefetch(_ urls: [URL], maxPixel: CGFloat) {
        for u in urls.prefix(12) { Task.detached(priority: .utility) { _ = await self.image(u, maxPixel: maxPixel) } }
    }
}

/// Pixel budgets for common uses. On constrained hardware these are still
/// 1.7–2× the on-screen size (tvOS draws the 1080p UI at 1×), but decode and
/// memory drop by roughly a third compared with the high-tier sizes.
enum ImageSize {
    static var poster: CGFloat { PerformanceProfile.isConstrained ? 420 : 520 }
    static var landscape: CGFloat { PerformanceProfile.isConstrained ? 760 : 900 }
    static var logo: CGFloat { PerformanceProfile.isConstrained ? 600 : 900 }
    static var backdrop: CGFloat { PerformanceProfile.backdropMaxPixels }
    static var avatar: CGFloat { PerformanceProfile.isConstrained ? 260 : 400 }
}

/// An image that fades in over a glass placeholder (0.25 s).
struct RemoteImage: View {
    let url: String?
    var maxPixel: CGFloat = ImageSize.poster
    var contentMode: ContentMode = .fill
    var placeholder: Bool = true
    var fallbackURL: String? = nil

    @State private var image: UIImage?
    @State private var loadedKey: String?
    /// Far-off rows hold their downloads until they come near (see `deferImageLoad`).
    @Environment(\.deferImageLoad) private var deferred
    @Environment(\.ghostedRow) private var ghosted

    private var resolved: URL? {
        guard let s = url ?? fallbackURL, !s.isEmpty else { return nil }
        return URL(string: s.hasPrefix("//") ? "https:" + s : s)
    }

    var body: some View {
        ZStack {
            if placeholder, image == nil, !ghosted {
                Rectangle().fill(Palette.glassSolid)
            }
            if let image, !ghosted {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(Motion.imageFade))
            }
        }
        .allowsHitTesting(false)
        .task(id: deferred ? "deferred" : resolved?.absoluteString) { await load() }
    }

    private func load() async {
        guard let u = resolved else { image = nil; return }
        // Deferred: show what's already in memory, fetch nothing yet.
        if deferred {
            if image == nil, let hit = ImagePipeline.shared.cached(u, maxPixel: maxPixel) { image = hit; loadedKey = u.absoluteString }
            return
        }
        let key = u.absoluteString
        if loadedKey == key, image != nil { return }
        if let hit = ImagePipeline.shared.cached(u, maxPixel: maxPixel) {
            image = hit
            loadedKey = key
            return
        }
        image = nil
        var img = await ImagePipeline.shared.image(u, maxPixel: maxPixel)
        if img == nil, let fb = fallbackURL, fb != url, let fu = URL(string: fb) {
            img = await ImagePipeline.shared.image(fu, maxPixel: maxPixel)
        }
        guard !Task.isCancelled else { return }
        withAnimation(Motion.imageFade) { image = img }
        loadedKey = key
    }
}

private struct DeferImageLoadKey: EnvironmentKey { static let defaultValue = false }
private struct GhostedRowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Rows far below the focused one on Home: every row is built up front, and
    /// without this every poster in every row downloaded and decoded at launch
    /// (hundreds of images competing on an A8).
    var deferImageLoad: Bool {
        get { self[DeferImageLoadKey.self] }
        set { self[DeferImageLoadKey.self] = newValue }
    }

    /// Home's row just above the focused one: kept (at 1 % opacity) only so Up
    /// is a native move. Its art isn't drawn — bright posters still showed
    /// faintly on a TV. (A colour filter instead made the TV composite a stale
    /// band of the backdrop.)
    var ghostedRow: Bool {
        get { self[GhostedRowKey.self] }
        set { self[GhostedRowKey.self] = newValue }
    }
}

/// A title logo (fits, bottom-leading) or a text fallback.
struct LogoOrTitle: View {
    let logo: String?
    let title: String
    var maxSize: CGSize = CGSize(width: 560, height: 200)
    var alignment: Alignment = .bottomLeading
    var fallbackStyle: TypeStyle = .heroLogoFallback

    @State private var failed = false
    @State private var image: UIImage?
    @Environment(\.ghostedRow) private var ghosted
    private static let shadows = !PerformanceProfile.isConstrained

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: alignment)
                    // A soft shadow is an offscreen pass every frame the logo moves;
                    // on A8/A10X the scrims behind it carry the contrast instead.
                    .shadow(color: .black.opacity(Self.shadows ? 0.35 : 0), radius: Self.shadows ? 12 : 0, y: Self.shadows ? 4 : 0)
            } else if logo == nil || failed {
                Text(title)
                    .textStyle(fallbackStyle)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(alignment == .center || alignment == .top ? .center : .leading)
                    .frame(maxWidth: maxSize.width, alignment: alignment)
                    .shadow(color: .black.opacity(Self.shadows ? 0.4 : 0), radius: Self.shadows ? 10 : 0)
            } else {
                Color.clear.frame(width: maxSize.width * 0.6, height: maxSize.height * 0.6)
            }
        }
        .opacity(ghosted ? 0 : 1)
        .allowsHitTesting(false)
        .task(id: logo) {
            failed = false
            image = nil
            guard let s = logo, let u = URL(string: s) else { failed = true; return }
            if let img = await ImagePipeline.shared.image(u, maxPixel: ImageSize.logo) { image = img } else { failed = true }
        }
    }
}
