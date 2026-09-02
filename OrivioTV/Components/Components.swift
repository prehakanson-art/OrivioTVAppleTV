import SwiftUI
import UIKit
import CryptoKit
import ImageIO
import CoreImage

// MARK: - Image cache

/// Process-wide image cache with two layers:
///
/// * **Memory** (`NSCache`) — decoded pixels, instant re-show. `AsyncImage`
///   re-downloads and re-decodes every time its view is recreated (which the
///   home hero does on every focus move) — that was the backdrop flicker.
/// * **Disk** (`Caches/orivio-images`) — the original encoded bytes, so posters
///   and backdrops survive an app relaunch and don't have to be refetched.
///   LRU-trimmed to a byte budget on launch.
///
/// Memory lookups are synchronous; disk lookups are async (off the main
/// thread) and promote hits back into the memory layer.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// Dedicated download session for artwork. Posters/backdrops nearly all come
    /// from one host (image.tmdb.org), so the default 6-connections-per-host cap
    /// throttles a full poster grid to 6 at a time — raise it so the grid fills
    /// in far fewer round-trips. Own URLCache keeps HTTP-cached art off the
    /// shared session.
    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = PerformanceProfile.isLowPower ? 6 : (PerformanceProfile.isMidPower ? 8 : 12)
        config.timeoutIntervalForRequest = 25
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        return URLSession(configuration: config)
    }()

    private let memory = NSCache<NSString, UIImage>()
    private let ioQueue = DispatchQueue(label: "orivio.imagecache.io", qos: .utility)
    private let fm = FileManager.default
    private let diskURL: URL
    private let diskBudget = 512 * 1024 * 1024   // ~512 MB of encoded images

    private init() {
        // Sized to the hardware: the Apple TV HD has 2 GB total — a 256 MB
        // decoded-pixel cache there gets the app jetsammed.
        memory.countLimit = PerformanceProfile.imageCacheCount
        memory.totalCostLimit = PerformanceProfile.imageCacheBytes
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskURL = caches.appendingPathComponent("orivio-images", isDirectory: true)
        try? fm.createDirectory(at: diskURL, withIntermediateDirectories: true)
        ioQueue.async { [weak self] in self?.trimDisk() }
        // Under real memory pressure, decoded pixels are the cheapest thing to
        // give back (they re-decode from disk on demand) — dropping them here
        // is what keeps tvOS from jetsamming the whole app instead.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.memory.removeAllObjects() }
    }

    /// Decode `data` off the render path, downsampled (via ImageIO) to
    /// `budget` pixels on the longest side when the source is larger.
    ///
    /// Callers that know their rendered size pass a tight budget (a poster
    /// card never needs a 2000×3000 "original" — decoding it full-size costs
    /// ~24 MB where ~3 MB carries the identical rendered pixels). With no
    /// budget the device framebuffer cap applies (1920 on the 1080p HD, 3840
    /// on 4K devices) — beyond the framebuffer there is nothing more to show,
    /// so every path stays pixel-identical.
    static func decodeDownsampled(_ data: Data, budget: CGFloat? = nil) -> UIImage? {
        let maxDim = min(budget ?? .greatestFiniteMagnitude,
                         PerformanceProfile.maxImagePixelSize)
        guard let src = CGImageSourceCreateWithData(data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else {
            // Fallback: force the decode now so it doesn't happen lazily on
            // the render path while a row scrolls.
            let decoded = UIImage(data: data)
            return decoded?.preparingForDisplay() ?? decoded
        }
        // Source already within the display's budget — plain decode.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
           max(w, h) <= maxDim {
            let decoded = UIImage(data: data)
            return decoded?.preparingForDisplay() ?? decoded
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode now, off-main
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            let decoded = UIImage(data: data)
            return decoded?.preparingForDisplay() ?? decoded
        }
        return UIImage(cgImage: cg)
    }

    /// Synchronous memory-only lookup.
    func image(for key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    /// Off-main disk lookup. On a hit the image is promoted back into memory
    /// (under `memoryKey`, which carries the decode-budget bucket) and its
    /// file's mtime is touched so it survives LRU trimming. Disk always stores
    /// the original encoded bytes keyed by URL — one file serves every size.
    func diskImage(for key: String, budget: CGFloat? = nil, memoryKey: String? = nil) async -> UIImage? {
        let fileURL = fileURL(for: key)
        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self,
                      let data = try? Data(contentsOf: fileURL),
                      // Decode HERE (background, downsampled) — otherwise UIKit
                      // decodes lazily on first draw, i.e. on the render path
                      // while a row is scrolling.
                      let prepared = Self.decodeDownsampled(data, budget: budget) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.insertMemory(prepared, for: memoryKey ?? key)
                try? self.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
                continuation.resume(returning: prepared)
            }
        }
    }

    /// Store in memory now and persist the encoded bytes to disk in the
    /// background. Pass the original downloaded `data` to avoid re-encoding.
    /// `memoryKey` (when given) carries the decode-budget bucket; disk is
    /// always keyed by the plain URL.
    func insert(_ image: UIImage, for key: String, data: Data? = nil, memoryKey: String? = nil) {
        insertMemory(image, for: memoryKey ?? key)
        let payload = data ?? image.jpegData(compressionQuality: 0.9)
        guard let payload else { return }
        let fileURL = fileURL(for: key)
        ioQueue.async { try? payload.write(to: fileURL, options: .atomic) }
    }

    /// Release every decoded image held in RAM.
    ///
    /// Invisible: anything still on screen re-decodes from the disk layer,
    /// which is the whole reason that layer exists. Called when playback
    /// starts, because the player's peak is the app's peak — a read-ahead
    /// buffer (up to 400 MB on a 3 GB box), the decoder, and the Metal
    /// surfaces all arrive at once, and until now a browsing session's worth
    /// of decoded posters (up to 160 MB) was still being held underneath it.
    /// tvOS does not reliably deliver a memory warning before jetsam on a
    /// spike that fast, so waiting for one is not a strategy.
    func dropDecoded() { memory.removeAllObjects() }

    private func insertMemory(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale) * 4
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskURL.appendingPathComponent(name)
    }

    /// Warm the cache for images that will be needed soon (posters in rows
    /// below the fold). DISK-ONLY: persists the encoded bytes so the first real
    /// display is a disk hit (no network round-trip), and stops there.
    ///
    /// It deliberately does NOT decode or populate memory. The old version
    /// decoded each prefetched image at the full device cap (1920px on the HD —
    /// ~9 MB decoded for a poster drawn at ~330px) and inserted it under the
    /// PLAIN url key, but the display path (`RemoteImage`) only ever reads under
    /// a budget-bucketed key (`url#<budget>`). So every prefetch decode was both
    /// far too large AND stored under a key nothing reads — it just churned CPU
    /// and RAM (a real jetsam risk on the 2 GB box when a Home load prefetched
    /// 100+ posters) before being evicted, for zero display benefit. The display
    /// path decodes from this disk cache at its own tight per-card budget.
    /// The one live prefetch pass. Each Home reload used to spawn ANOTHER
    /// uncancellable detached task — N reloads stacked N endless download
    /// loops that kept running during playback.
    private var prefetchTask: Task<Void, Never>?

    func prefetch(urls: [String]) {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0).inserted }
        // Capped on EVERY tier — "all of them" was unbounded on 4K boxes.
        let limit = PerformanceProfile.isLowPower ? 36 : (PerformanceProfile.isMidPower ? 60 : 96)
        let candidates = Array(unique.prefix(limit))
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            for urlString in candidates {
                guard !Task.isCancelled else { return }
                guard let self, let url = URL(string: urlString) else { continue }
                let fileURL = self.fileURL(for: urlString)
                if self.fm.fileExists(atPath: fileURL.path) { continue }
                guard let (data, _) = try? await ImageCache.downloadSession.data(from: url) else { continue }
                self.ioQueue.async { try? data.write(to: fileURL, options: .atomic) }
            }
        }
    }

    // MARK: Pre-blurred renditions (hero "progressive blur")

    /// Shared CIContext for the pre-blur path. Creating one per blur would
    /// re-initialize a Metal pipeline each hero change.
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// A small pre-blurred rendition of the image at `key`, built ONCE off-main
    /// and memory-cached. Replaces live `.blur(radius:)` layers: Core Animation
    /// re-applies a live gaussian on EVERY composited frame, so a full-screen
    /// blurred backdrop was one of the heaviest recurring GPU costs on the
    /// A10X/A8 while Home scrolls. A 60pt blur destroys all detail anyway, so
    /// blurring a ~480px copy once and stretching it is visually identical —
    /// and the per-frame cost drops to an ordinary image composite.
    ///
    /// `screenBlurRadius` is the SwiftUI blur the rendition stands in for, at
    /// the 1920pt reference width — the CI sigma is scaled to the downsampled
    /// copy so the softness matches what `.blur(radius:)` showed.
    func blurredImage(for key: String, screenBlurRadius: CGFloat = 60) async -> UIImage? {
        let baseWidth: CGFloat = 480
        let blurKey = "\(key)#blur\(Int(screenBlurRadius))"
        if let hit = image(for: blurKey) { return hit }

        // Base bytes: disk first (the sharp hero rendering beneath this layer
        // has nearly always persisted them already), then network.
        let fileURL = fileURL(for: key)
        var data: Data? = await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: try? Data(contentsOf: fileURL)) }
        }
        if data == nil, let url = URL(string: key),
           let (fetched, _) = try? await Self.downloadSession.data(from: url) {
            data = fetched
            ioQueue.async { try? fetched.write(to: fileURL, options: .atomic) }
        }
        guard let data else { return nil }

        let blurred = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let base = Self.decodeDownsampled(data, budget: baseWidth),
                  let cg = base.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            // Match the live blur's softness at this scale (blur radius is
            // proportional to layer size).
            let sigma = screenBlurRadius * (input.extent.width / 1920)
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
            // Clamp first so the gaussian doesn't pull in transparent edges
            // (the dark-vignette artifact), then crop back to the frame.
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(sigma, forKey: kCIInputRadiusKey)
            guard let output = filter.outputImage?.cropped(to: input.extent),
                  let rendered = Self.ciContext.createCGImage(output, from: input.extent) else {
                return nil
            }
            return UIImage(cgImage: rendered)
        }.value
        if let blurred { insertMemory(blurred, for: blurKey) }
        return blurred
    }

    /// Evict oldest files (by mtime) until the directory is under budget.
    private func trimDisk() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: diskURL, includingPropertiesForKeys: keys
        ) else { return }
        var files = contents.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { return nil }
            return (url, size, date)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > diskBudget else { return }
        files.sort { $0.date < $1.date }   // oldest first
        for file in files {
            if total <= diskBudget { break }
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }
}

// MARK: - Remote image

/// Cached async image with a shimmer placeholder and a crossfade-in. Keeps the
/// previously shown image on screen while a new URL loads, so changing the hero
/// backdrop is a smooth crossfade rather than a flash.
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    /// Longest rendered side in POINTS, when the caller knows it (poster and
    /// episode cards do). Decoding is capped at 1.5× this size in pixels —
    /// still supersampled relative to what's drawn, so the rendered output is
    /// identical, but a grid of cards stops decoding full "original" TMDB art
    /// it can never show. `nil` (heroes/backdrops) = device framebuffer cap.
    var maxDimension: CGFloat? = nil

    @State private var image: UIImage?
    @State private var shownKey: String?

    var body: some View {
        Color.clear.overlay(alignment: alignment) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .id(shownKey)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .clipped()
        .task(id: url) { await load(url) }
    }

    /// Pixel budget for the decode (longest side), from the rendered size.
    private var pixelBudget: CGFloat? {
        maxDimension.map { $0 * UIScreen.main.scale * 1.5 }
    }

    /// Memory-cache key: the URL plus the budget bucket, so a small card decode
    /// is never handed to a full-screen consumer of the same URL (and vice
    /// versa). Disk stays keyed by plain URL — encoded bytes fit every size.
    private func memoryKey(_ value: String) -> String {
        pixelBudget.map { "\(value)#\(Int($0))" } ?? value
    }

    /// Commit a loaded image, fading only when "Artwork fade-in" is on
    /// (Settings → Performance) — each fade re-renders the cell for its
    /// duration, which adds up during a fast row scroll on older boxes.
    private func show(_ newImage: UIImage?, key: String?, duration: Double) {
        if PerformanceSettingsStore.shared.artworkFadeInEffective {
            withAnimation(.easeOut(duration: duration)) { image = newImage; shownKey = key }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { image = newImage; shownKey = key }
        }
    }

    private func load(_ value: String?) async {
        guard let value, let parsed = URL(string: value) else {
            show(nil, key: nil, duration: 0.2)
            return
        }
        if value == shownKey { return }
        if let cached = ImageCache.shared.image(for: memoryKey(value)) {
            show(cached, key: value, duration: 0.28)
            return
        }
        // Disk hit: survives relaunch, so a previously seen poster shows without
        // a network round-trip.
        if let disk = await ImageCache.shared.diskImage(
            for: value, budget: pixelBudget, memoryKey: memoryKey(value)
        ) {
            if Task.isCancelled { return }
            show(disk, key: value, duration: 0.28)
            return
        }
        // Keep the current image visible while the replacement downloads.
        guard let (data, _) = try? await ImageCache.downloadSession.data(from: parsed),
              !Task.isCancelled else { return }
        // Decode off the render path (UIKit otherwise decodes lazily on first
        // draw — a scroll hitch per newly visible poster), downsampled to this
        // view's own pixel budget (a poster card must not decode a full-res
        // backdrop-sized original).
        let budget = pixelBudget
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            ImageCache.decodeDownsampled(data, budget: budget)
        }).value else { return }
        if Task.isCancelled { return }
        ImageCache.shared.insert(prepared, for: value, data: data, memoryKey: memoryKey(value))
        show(prepared, key: value, duration: 0.35)
    }

    private var placeholder: some View {
        PlaceholderShimmer()
    }
}

/// A pre-blurred rendition of a remote image, for the hero's "progressive
/// blur" dissolve. Displays `ImageCache.blurredImage` — blurred ONCE off-main
/// at ~1/4 scale — as a plain stretched image, so the per-frame compositor
/// cost is an ordinary alpha blend instead of a live full-screen gaussian
/// (see `blurredImage` for why that mattered on the A10X/A8 tiers).
/// Mirrors RemoteImage's keep-last-image crossfade so hero changes dissolve.
struct BlurredRemoteImage: View {
    let url: String?
    var screenBlurRadius: CGFloat = 60

    @State private var image: UIImage?
    @State private var shownKey: String?

    var body: some View {
        Color.clear.overlay {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(shownKey)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: url) { await load(url) }
    }

    private func load(_ value: String?) async {
        guard let value else {
            shownKey = nil
            image = nil
            return
        }
        if value == shownKey { return }
        guard let blurred = await ImageCache.shared.blurredImage(
            for: value, screenBlurRadius: screenBlurRadius
        ), !Task.isCancelled else { return }
        // Ride the hero-crossfade setting like the sharp layer beneath, so the
        // two renditions always dissolve (or snap) together.
        if PerformanceSettingsStore.shared.heroCrossfadeEffective {
            withAnimation(.easeOut(duration: 0.3)) { image = blurred; shownKey = value }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { image = blurred; shownKey = value }
        }
    }
}

/// Dimmed placeholder shown while an image downloads. Deliberately STATIC:
/// the earlier breathing animation started a repeat-forever animation in
/// every freshly created cell — during a fast row scroll that's dozens of
/// simultaneous animations spinning up, which visibly stuttered scrolling on
/// the A10X.
private struct PlaceholderShimmer: View {
    var body: some View {
        OrivioPrimitives.neutral875
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: 30))
                    .foregroundStyle(OrivioPrimitives.neutral700)
            )
            .opacity(0.7)
    }
}

// MARK: - Marquee title

/// Focus-marquee for long titles (the Android app's default): while `active`
/// (card focused) an overflowing title scrolls horizontally in a seamless
/// loop; inactive (or fitting) it renders as a plain truncated Text. The
/// measuring/animating variant exists ONLY on the focused card, so grids pay
/// zero extra cost — critical after the row-perf work.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let active: Bool

    var body: some View {
        if active {
            ActiveMarquee(text: text, font: font, color: color)
        } else {
            Text(text).font(font).foregroundStyle(color).lineLimit(1)
        }
    }
}

private struct ActiveMarquee: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var marqueeTask: Task<Void, Never>?

    /// Gap between the looping copies, and scroll speed in pt/s.
    private let gap: CGFloat = 60
    private let speed: CGFloat = 55

    private var overflows: Bool { textWidth > boxWidth + 1 }

    var body: some View {
        HStack(spacing: gap) {
            measuredText
            if overflows {
                // Second copy so the loop wraps seamlessly instead of
                // snapping back to the start.
                Text(text).font(font).foregroundStyle(color).fixedSize()
            }
        }
        .offset(x: offset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { boxWidth = geo.size.width }
            }
        )
        .onChange(of: textWidth) { _, _ in startIfNeeded() }
        .onChange(of: boxWidth) { _, _ in startIfNeeded() }
        .onDisappear { marqueeTask?.cancel() }
    }

    private var measuredText: some View {
        Text(text).font(font).foregroundStyle(color)
            .fixedSize()   // natural width, so overflow is measurable
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { textWidth = geo.size.width }
                }
            )
    }

    private func startIfNeeded() {
        marqueeTask?.cancel()
        guard overflows, offset == 0 else { return }
        let distance = textWidth + gap
        // Brief hold so the title is readable before it starts moving.
        marqueeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, overflows, offset == 0 else { return }
            withAnimation(.linear(duration: distance / speed)
                .delay(0.4)
                .repeatForever(autoreverses: false)) {
                offset = -distance
            }
        }
    }
}

// MARK: - Poster card

struct PosterCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused

    let item: MetaItem
    var progress: Double? = nil

    private var cardWidth: CGFloat { layout.posterSize.posterWidth }
    private var cardHeight: CGFloat { cardWidth * 3 / 2 }
    private var stremio: Bool { theme.isStremioTheme }
    /// Stremio uses generously rounded poster corners.
    private var cornerRadius: CGFloat {
        CGFloat(layout.posterCornerRadius)
    }

    /// Explicit progress wins; otherwise an O(1) Continue Watching lookup so
    /// a started movie/show carries its progress bar EVERYWHERE it appears
    /// (home rows, search, discover, library…), not just the CW row.
    private var effectiveProgress: Double? {
        if let progress { return progress }
        return progressStore.continueFractions[item.id]
    }

    /// The native CardButtonStyle platter supplies focus (raise + trackpad
    /// wiggle), so the card's own ring / scale / shadow / caption are
    /// suppressed — posters read as clean "icons".
    private var atv: Bool { true }

    /// Focus ring fallback. Classic always rings its focused card. Fusion
    /// normally lets the accent GLOW mark focus — but the glow rides the Card
    /// Shadows switch (off by default on the A8/A10X tiers), and with parallax
    /// and zoom also off that left NO focus indicator at all. When the glow is
    /// unavailable, fall back to the ring: a single stroked outline is one
    /// vector stroke — no offscreen pass, nothing recomposited per frame.
    private var showsFocusRing: Bool {
        isFocused && (!atv || !perf.settings.cardShadows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: item.poster, maxDimension: cardHeight)
                    .aspectRatio(2 / 3, contentMode: .fill)
                if let progress = effectiveProgress, progress > 0 {
                    ProgressStrip(fraction: progress)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(theme.palette.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Fusion (§13.4): dim unfocused cards a touch so the focused one
            // pops. This USED to be .saturation(0.94) + .brightness(-0.05) — two
            // color-matrix filters, each an offscreen render pass, on EVERY
            // unfocused card, every scroll frame (the single biggest scroll cost
            // in this theme, and brutal in the simulator, which composites
            // offscreen passes far slower than the device). A flat dark overlay
            // is a plain alpha composite — no offscreen pass — for the same
            // "focused pops" read. Nothing is drawn when focused.
            .overlay {
                // Fusion: unfocused cards rest slightly darker so the focused
                // one pops (flat overlay — no live filters).
                if atv && !isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.11))
                }
            }
            .overlay(alignment: .topTrailing) {
                if watched.isWatched(item) { WatchedBadge().padding(10) }
            }
            .overlay(
                // Stremio marks focus with a thicker purple border.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(showsFocusRing ? theme.palette.focusRing : .clear,
                                  lineWidth: 3)
            )
            // FOCUSED card only. A drop shadow is an offscreen render pass per
            // card; with the old always-on ambient shadow every visible poster
            // paid one, which is a large share of the scroll cost on the
            // A8/A10X boxes. One shadow (the focused pop) keeps the depth cue.
            .shadow(color: .black.opacity(perf.settings.cardShadows && isFocused && !atv ? 0.65 : 0),
                    radius: perf.settings.cardShadows && isFocused && !atv ? 22 : 0, y: 10)

            if layout.showPosterLabels && !atv {
                MarqueeText(
                    text: item.name,
                    font: .system(size: 22, weight: .medium),
                    color: isFocused ? theme.palette.textPrimary : theme.palette.textSecondary,
                    active: isFocused
                )
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        // `atv` opts out: the Apple TV theme uses the native tvOS card platter
        // (lift + trackpad tilt) instead of a scale. Every other theme gets the
        // shared card lift, so a poster grows identically in all of them.
        .focusLift(atv ? 1.0 : OrivioFocus.card, isFocused)
    }
}

struct ProgressStrip: View {
    @EnvironmentObject private var theme: ThemeManager
    let fraction: Double

    var body: some View {
        // No GeometryReader: a full-width fill Capsule scaled horizontally to
        // the fraction. Every Continue Watching card carries one of these, and
        // GeometryReader forces each into its own layout pass — measurable
        // scroll cost across a row of them. scaleEffect is a cheap transform.
        Capsule().fill(Color.white.opacity(0.35))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(theme.palette.secondary)
                    .scaleEffect(x: CGFloat(min(max(fraction, 0.02), 1)), y: 1, anchor: .leading)
            }
            .frame(height: 6)
    }
}

enum LandscapeSubtitleBehavior: Equatable {
    case compact
    case readableOnFocus
}

/// Landscape card used for Continue Watching and episode thumbnails.
struct LandscapeCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused

    private var stremio: Bool { theme.isStremioTheme }
    private var cardRadius: CGFloat { OrivioRadius.md }

    let imageURL: String?
    let title: String
    let subtitle: String?
    var progress: Double? = nil
    var watched: Bool = false
    var rating: String? = nil
    var width: CGFloat = 380
    var subtitleBehavior: LandscapeSubtitleBehavior = .compact
    var detailLine: String? = nil
    var remainingText: String? = nil
    var hasNewEpisode: Bool = false
    /// Flip to false to revert episode cards to the compact caption if the taller
    /// focused description treatment does not feel right on-device.
    private static let expandedEpisodeDescriptionsEnabled = true
    /// Flip to false to hide per-episode cast captions without removing the fetch/cache path.
    private static let episodeCastLineEnabled = true
    /// Spoiler-blur the still until the card is focused (then it reveals).
    var blurImage: Bool = false
    /// When false, the title/subtitle caption is omitted — the Apple TV theme
    /// renders it BELOW the focus platter instead (see `ATVCardCaption`), so
    /// the platter doesn't bridge art and label into one slab.
    var showsCaption: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: imageURL, maxDimension: width)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    // Attach `.blur` ONLY on the rare spoiler card. Applied
                    // unconditionally (even at radius 0) it forces every card
                    // into an offscreen render pass that the focus scale
                    // animation re-composites each frame — that, not the row
                    // re-render, is why Continue Watching scrolled heavier
                    // than the poster rows. `blurImage` is fixed per card, so
                    // the branch never flips on focus.
                    .modifier(SpoilerBlur(active: blurImage, revealed: isFocused))
                if let progress, progress > 0 {
                    ProgressStrip(fraction: progress)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .background(theme.palette.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let rating { RatingBadge(rating: rating).padding(10) }
            }
            .overlay(alignment: .topTrailing) {
                if hasNewEpisode {
                    NewEpisodeBadge().padding(10)
                } else if watched {
                    WatchedBadge().padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let remainingText {
                    RemainingTimeBadge(text: remainingText)
                        .padding(.trailing, 12)
                        .padding(.bottom, progress == nil ? 12 : 24)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    // ATV theme: the accent glow normally carries focus, but it
                    // rides the Card Shadows switch — when that's off (A8/A10X
                    // tier defaults), fall back to the ring so the focused card
                    // is always marked. One vector stroke, no offscreen pass
                    // (see PosterCard.showsFocusRing). Stremio: thicker purple.
                    .strokeBorder(isFocused && !perf.settings.cardShadows
                                      ? theme.palette.focusRing : .clear,
                                  lineWidth: 3)
            )

            if showsCaption {
                caption
            }
        }
        // Native card platter carries the lift.
        .focusLift(1.0, isFocused)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(
                text: title,
                font: .system(size: 22, weight: .medium),
                color: isFocused ? theme.palette.textPrimary : theme.palette.textSecondary,
                active: isFocused
            )
            .frame(width: width, alignment: .leading)
            .clipped()

            if let subtitle, !subtitle.isEmpty {
                subtitleText(subtitle)
            }

            if let detailLine, !detailLine.isEmpty, Self.episodeCastLineEnabled {
                Text(detailLine)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                    .opacity(isFocused ? 1 : 0)
                    .offset(y: isFocused ? 0 : 4)
            }
        }
        .frame(width: width, height: captionHeight, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func subtitleText(_ subtitle: String) -> some View {
        if subtitleBehavior == .readableOnFocus && Self.expandedEpisodeDescriptionsEnabled {
            ZStack(alignment: .topLeading) {
                episodeSubtitle(subtitle, lines: 2, color: theme.palette.textTertiary)
                    .opacity(isFocused ? 0 : 1)
                    .offset(y: isFocused ? -4 : 0)
                episodeSubtitle(subtitle, lines: 5, color: theme.palette.textSecondary)
                    .opacity(isFocused ? 1 : 0)
                    .offset(y: isFocused ? 0 : 6)
            }
            .frame(width: width, height: 98, alignment: .topLeading)
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
        } else {
            episodeSubtitle(subtitle, lines: 2, color: theme.palette.textTertiary)
        }
    }

    private func episodeSubtitle(_ subtitle: String, lines: Int, color: Color) -> some View {
        Text(subtitle)
            .font(.system(size: 18))
            .foregroundStyle(color)
            .lineSpacing(2)
            .lineLimit(lines)
            .frame(width: width, alignment: .leading)
            .clipped()
    }

    private var captionHeight: CGFloat {
        let expanded = subtitleBehavior == .readableOnFocus && Self.expandedEpisodeDescriptionsEnabled
        return expanded ? (Self.episodeCastLineEnabled && detailLine?.isEmpty == false ? 156 : 132) : 72
    }

}

private struct RemainingTimeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.68), in: Capsule())
    }
}

private struct NewEpisodeBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 34, height: 34)
            .background(.white, in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

/// Spoiler blur that is entirely ABSENT when inactive — no radius-0 blur
/// layer, so an unblurred card has no offscreen render pass to re-composite
/// during its focus animation. `active` is fixed per card (never toggles on
/// focus), so this branch is identity-stable.
private struct SpoilerBlur: ViewModifier {
    let active: Bool
    let revealed: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content
                .blur(radius: revealed ? 0 : 28)
                .animation(nil, value: revealed)   // snap, don't ride the spring
        } else {
            content
        }
    }
}

/// Liquid Glass on tvOS 26, translucent material earlier — the one frosted
/// treatment every glass surface in the app goes through (rail, filter pills,
/// search bar, detail icon circles, season chips).
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// `liquidGlass` only while `active` — for controls whose focused state
    /// swaps the glass for a solid fill. Rendered as a BACKGROUND view, never
    /// wrapping the content: a `glassEffect` wrapped around focusable content
    /// hides it from the tvOS focus engine (the detail page's action row
    /// became a focus trap that swallowed every direction).
    func liquidGlassIf<S: Shape>(_ active: Bool, in shape: S) -> some View {
        background { if active { Color.clear.liquidGlass(in: shape) } }
    }
}

/// Caption shown BELOW an Apple TV–theme card, OUTSIDE the focus platter.
/// The native `CardButtonStyle` draws its raised platter behind the whole
/// button label, so any caption kept inside the button gets bridged to the
/// artwork by a connecting slab (the "weird square"). Rendering the label as a
/// sibling below the button — the way the real tvOS home screen and TV app do
/// it — keeps the poster a clean tile and the title a free-floating label.
struct ATVCardCaption: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    var subtitle: String? = nil
    var width: CGFloat
    /// True while this caption's card is focused: the native platter grows the
    /// artwork downward past the caption's resting gap, so the caption eases
    /// down in step to keep a constant distance from the poster's bottom edge.
    var lowered: Bool = false
    /// How far to drop while lowered — the platter's bottom-edge growth plus
    /// breathing room, so the gap reads clearly at couch distance.
    var dropDistance: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(FusionType.cardTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(FusionType.metadata(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, 4)
        .offset(y: lowered ? dropDistance : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: lowered)
    }
}

/// A grid poster cell in the app's one look: native platter focus, hold menu,
/// ⏯ straight to the source picker, and the caption easing down while focused
/// so the grown platter never crowds it. Used by the Home grid and Search.
struct GridPosterCell: View {
    let item: MetaItem
    let captionWidth: CGFloat
    let onSelect: (MetaItem) -> Void
    var onPlayManually: (MetaItem, MetaVideo?) -> Void = { _, _ in }
    /// Optional external focus tracking (Discover's back-to-top uses it).
    var gridFocus: FocusState<String?>.Binding? = nil
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            button

            ATVCardCaption(
                title: item.name,
                subtitle: item.year,
                width: captionWidth,
                lowered: focused
            )
        }
    }

    @ViewBuilder
    private var button: some View {
        let base = Button {
            onSelect(item)
        } label: {
            PosterCard(item: item)
                .onFocusChange { focused = $0 }
        }
        .mediaCardButtonStyle()
        .posterHoldMenu(item) { onSelect(item) }
        .onPlayPauseCommand { onPlayManually(item, nil) }

        if let gridFocus {
            base.focused(gridFocus, equals: item.id)
        } else {
            base
        }
    }
}

/// Card-button chrome per app theme. The Apple TV theme uses the native tvOS
/// `CardButtonStyle` — the raised platter with the trackpad tilt/wiggle
/// parallax, exactly like home-screen icons — while Classic keeps the
/// borderless style so cards draw their own focus ring. Reads the theme from
/// the environment so call sites don't need a ThemeManager in scope.
private struct MediaCardButtonStyleModifier: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    var onPressChanged: ((Bool) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if perf.cardParallaxEffective {
            // Native platter: raised card + trackpad tilt/parallax.
            content.buttonStyle(CardButtonStyle())
        } else {
            // "Card wiggle & lift" off (Settings → Performance): a lightweight
            // scale-only focus that never re-composites the card as the finger
            // moves — the cheap path for the A8. Cards still respond to focus;
            // their own glow/border (drawn off \.isFocused) still shows.
            content.buttonStyle(FlatCardButtonStyle(onPressChanged: onPressChanged))
        }
    }
}

/// Apple TV theme, parallax OFF: focus is a plain scale (like Classic's
/// PlainCardButtonStyle) with no native platter — so there's no per-frame tilt
/// recomposition of the focused poster. The card's own focus glow/border still
/// render (they read `\.isFocused`, which this style leaves intact).
struct FlatCardButtonStyle: ButtonStyle {
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, onPressChanged: onPressChanged)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: ButtonStyle.Configuration
        let onPressChanged: ((Bool) -> Void)?

        var body: some View {
            configuration.label
                .focusLift(OrivioFocus.card, isFocused)
                .cardPressDip(configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    onPressChanged?(pressed)
                }
        }
    }
}

extension View {
    /// Apply to Buttons whose label is a media card (poster / landscape).
    func mediaCardButtonStyle(onPressChanged: ((Bool) -> Void)? = nil) -> some View {
        modifier(MediaCardButtonStyleModifier(onPressChanged: onPressChanged))
    }
}

/// Borderless button wrapper so cards manage their own focus visuals.
struct PlainCardButtonStyle: ButtonStyle {
    /// Reports Select press begin/end so screens can pause state changes that
    /// would re-render mid-hold and break context-menu long presses.
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .cardPressDip(configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChanged?(pressed)
            }
    }
}

/// The shared Select-press feedback for a card button style. Every theme that
/// suppresses the native tvOS platter (Classic, Onyx, Cinematic, Marquee,
/// Streamline, and Apple TV with parallax off) draws its own press, so they all
/// go through this: the same dip, the same curve, and **nothing at all** when
/// "Button animations" is off or Reduce Motion is on. Before this, Marquee and
/// Streamline cards had no press response whatsoever and Onyx/Cinematic dipped
/// regardless of the setting.
private struct CardPressDip: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(perf.buttonAnimationsEffective && isPressed ? FusionFocus.pressScale : 1)
            .animation(perf.buttonMotion(FusionFocus.pressAnimation), value: isPressed)
    }
}

/// The one focus-motion vocabulary the whole app speaks.
///
/// Every focusable element picks a ROLE here instead of writing its own
/// `.scaleEffect(isFocused ? 1.0x : 1)`. A poster therefore lifts by the same
/// amount in Classic, Apple TV, Cinematic, Theater, Aurora, Onyx, Marquee,
/// Streamline and Stremio — and in any theme added later — and settles on the
/// same curve, because they all go through `View.focusLift(_:_:)`.
///
/// Roles differ from ONE ANOTHER on purpose: a 300pt poster and a 72pt
/// settings row should not grow by the same fraction. What they never differ
/// by is which theme happens to be on screen.
///
/// Adding a theme? Don't add scales — reuse these roles and the theme
/// automatically inherits the app's focus behaviour, the "Focus zoom"
/// performance switch and Reduce Motion.
enum OrivioFocus {
    /// Full-width list rows: settings rows, side-panel rows, dropdown options.
    static let row: CGFloat = 1.02
    /// The default for anything card-shaped: posters, tiles, episode cards,
    /// chips, pills and ordinary buttons.
    static let card: CGFloat = 1.05
    /// Small circular icon controls — trash, reorder, player transport, keypad
    /// keys. Small targets need a larger fraction to read as focused at all.
    static let control: CGFloat = 1.08
    /// Deliberately-large focus targets: profile avatars and their tiles.
    static let avatar: CGFloat = 1.12
    /// Carousel position dots — tiny, so they take the largest scale.
    static let dot: CGFloat = 1.4

    /// The single curve every focus move settles on, app-wide.
    static let animation: Animation = FusionFocus.liftAnimation
}

/// The shared focus lift for a themed card/tile: the theme's own scale, but
/// gated by "Cards spring slightly larger when focused" + Reduce Motion, and
/// animated on one curve so a focus move settles at the same rate in every
/// theme. The `.animation` also carries the card's focus ring / colour change,
/// so under Reduce Motion those snap instead of easing.
private struct FocusLift: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let scale: CGFloat
    let focused: Bool
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .scaleEffect(perf.focusScale(scale, focused))
            .animation(perf.motion(animation), value: focused)
    }
}

/// Applies an external `.focused(_:)` binding only when one is supplied, so a
/// reusable card can accept an optional focus binding from its parent.
/// (Was duplicated verbatim as MaxExternalFocus and HuluExternalFocus.)
private struct OptionalExternalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

extension View {
    /// Attach `binding` with `.focused(_:)` when it exists, otherwise no-op.
    func externalFocus(_ binding: FocusState<Bool>.Binding?) -> some View {
        modifier(OptionalExternalFocus(binding: binding))
    }

    /// Pulls focus to `binding` shortly after appear so a browse page opens
    /// focused on its content instead of on the chrome.
    func pullFocusOnAppear(_ binding: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { binding.wrappedValue = true } }
    }
}

extension View {
    /// Apply inside a card `ButtonStyle.makeBody` to get the shared press dip.
    func cardPressDip(_ isPressed: Bool) -> some View {
        modifier(CardPressDip(isPressed: isPressed))
    }

    /// Replaces a hand-rolled `.scaleEffect(focused ? x : 1)` +
    /// `.animation(…, value: focused)` pair so the themes ported from other
    /// apps (Marquee, Streamline, Onyx, Cinematic, Aurora) obey the same
    /// performance switches Classic and Apple TV always have.
    func focusLift(_ scale: CGFloat, _ focused: Bool,
                   animation: Animation = FusionFocus.liftAnimation) -> some View {
        modifier(FocusLift(scale: scale, focused: focused, animation: animation))
    }

    /// The row-reflow animation for themes whose focused card expands into a
    /// landscape tile (Onyx, Marquee). One bounce-free curve drives both the
    /// card's growth and the neighbours' shift so the row moves as a single
    /// motion, and Reduce Motion makes the swap instant.
    func focusExpand<V: Equatable>(_ value: V,
                                   animation: Animation = FusionMotion.rowExpand) -> some View {
        modifier(FocusExpand(value: value, animation: animation))
    }
}

/// See `View.focusExpand(_:animation:)`.
private struct FocusExpand<V: Equatable>: ViewModifier {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let value: V
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(perf.motion(animation), value: value)
    }
}

// MARK: - Badges & meta

/// A `•` separator dot for meta lines (APK style).
struct MetaDot: View {
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        Text("•")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(theme.palette.textTertiary)
    }
}

/// A meta-line text segment styled like the APK's "Type • Genre • Year" line.
struct MetaDotText: View {
    @EnvironmentObject private var theme: ThemeManager
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(theme.palette.textSecondary)
    }
}

/// A dot-separated meta line ("A • B • C"), optionally ending with an IMDb badge.
/// Matches the APK's detail/home meta rows.
struct MetaLine: View {
    let segments: [String]
    var imdbRating: String? = nil

    var body: some View {
        HStack(spacing: OrivioSpacing.sm) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                if index > 0 { MetaDot() }
                MetaDotText(seg)
            }
            if let imdbRating {
                if !segments.isEmpty { MetaDot() }
                ImdbBadge(rating: imdbRating)
            }
        }
    }
}

struct ContentRatingBadge: View {
    let rating: String

    var body: some View {
        Text(rating)
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            )
    }
}

struct MetaBadge: View {
    let text: String
    // `.primary` == white under Classic's forced-dark scheme (identical to
    // the old hardcoded white) and flips dark in ATV light mode.
    var tint: Color = .primary.opacity(0.14)
    var textColor: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Small "watched" checkmark chip shown on poster/landscape cards.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(.white)
            .padding(9)
            .background(Circle().fill(OrivioPrimitives.success))
            // The white ring provides the contrast; no shadow — each shadow is
            // an offscreen pass, and one rides on EVERY watched card in a row.
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
    }
}

/// Small star-rating chip (e.g. "★ 8.4") shown on episode cards.
struct RatingBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OrivioPrimitives.imdb)
            Text(rating)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.65), in: Capsule())
    }
}

/// A row of MDBList source ratings (IMDb, TMDB, RT, Metacritic, …), each a
/// small labeled chip. Mirrors the Android hero `MDBListRatingsRow`.
struct MDBListRatingsRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let entries: [MDBListRatingEntry]

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Text(entry.provider.label)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.palette.secondary.opacity(0.22),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(entry.text)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
    }
}

struct ImdbBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 7) {
            Text("IMDb")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OrivioPrimitives.imdb, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(rating)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Section header

struct RowHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String

    var body: some View {
        Text(title)
            .font(FusionType.moduleHeading(theme.font))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.leading, OrivioSpacing.huge)
    }
}

/// A titled group (header + content) that separates a labelled grid/list, the
/// same Movies/Shows split the Search screen uses. Owns its horizontal padding
/// so the content lines up under the header, and is its own focus section so
/// up/down moves cleanly between groups.
struct LibrarySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            RowHeader(title: title)
            content
                .padding(.horizontal, OrivioSpacing.huge)
        }
        .focusSection()
    }
}

// MARK: - Hero gradients (ported from Orivio's ModernHeroGradientLayer)

struct HeroGradient: View {
    let background: Color
    var fullBleed: Bool = false
    /// Light appearance (Apple TV theme only — Classic is always dark): the
    /// dark-tuned scrim opacities read as fog when the background is white,
    /// so light mode uses tighter ramps that leave the art vivid.
    @Environment(\.colorScheme) private var scheme
    private var isLight: Bool { scheme == .light }

    var body: some View {
        ZStack {
            LinearGradient(
                stops: isLight
                    ? [
                        .init(color: background, location: 0),
                        .init(color: background.opacity(0.86), location: 0.20),
                        .init(color: background.opacity(0.50), location: 0.42),
                        .init(color: background.opacity(0.12), location: 0.62),
                        .init(color: .clear, location: 0.78)
                    ]
                    : [
                        .init(color: background, location: 0),
                        .init(color: background.opacity(0.86), location: 0.22),
                        .init(color: background.opacity(0.56), location: 0.46),
                        .init(color: background.opacity(0.16), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                startPoint: .leading,
                endPoint: UnitPoint(x: fullBleed ? 0.65 : 0.45, y: 0.5)
            )
            LinearGradient(
                stops: isLight
                    ? [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.38),
                        .init(color: background.opacity(0.40), location: 0.62),
                        .init(color: background.opacity(0.80), location: 0.85),
                        .init(color: background, location: 1)
                    ]
                    : [
                        .init(color: .clear, location: 0),
                        .init(color: background.opacity(0.25), location: 0.4),
                        .init(color: background.opacity(0.65), location: 0.75),
                        .init(color: background, location: 1)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Loading / error states

/// An invisible 1pt focusable. Put one in any state that would otherwise have
/// NO focusable view (loading screens, QR sign-in pages): with nothing focused
/// the tvOS focus engine has no responder, so `.onExitCommand` never fires and
/// a Menu press falls through to the system — suspending the app at a root, or
/// bypassing a page's own Back handling.
struct FocusAnchor: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .accessibilityHidden(true)
    }
}

struct OrivioLoadingView: View {
    @EnvironmentObject private var theme: ThemeManager
    var label: String = "Loading"
    /// Hold focus while this is the only thing on screen (see FocusAnchor).
    var holdsFocus: Bool = false

    var body: some View {
        VStack(spacing: OrivioSpacing.lg) {
            if holdsFocus { FocusAnchor() }
            ProgressView()
                .tint(theme.palette.secondary)
                .scaleEffect(1.4)
            Text(label)
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OrivioEmptyState: View {
    @EnvironmentObject private var theme: ThemeManager
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: OrivioSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(theme.palette.textTertiary)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting helpers

enum DateFormat {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let plainDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let output: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none; return f
    }()

    /// Localized long date ("5 July 2026") from an ISO date or a plain
    /// `yyyy-MM-dd`. Returns nil if unparseable/empty.
    static func releaseDate(_ isoDate: String?) -> String? {
        guard let isoDate, !isoDate.isEmpty else { return nil }
        let date = isoWithFraction.date(from: isoDate)
            ?? iso.date(from: isoDate)
            ?? plainDate.date(from: String(isoDate.prefix(10)))
        return date.map { output.string(from: $0) }
    }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func signedDelta(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : "+"
        return sign + clock(abs(seconds))
    }
}

// MARK: - Toasts (§54)

/// Lightweight app-wide toast center for browsing-side confirmations
/// (Added to Library, Marked Watched, Rating Saved…). Separate from the
/// player's own `toast`. Auto-dismisses after `FusionMotion.toastVisibleSeconds`.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    @Published var icon: String?
    private var task: Task<Void, Never>?

    func show(_ message: String, icon: String? = nil) {
        withAnimation(FusionMotion.toastEnter) {
            self.message = message
            self.icon = icon
        }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(FusionMotion.toastVisibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(FusionMotion.toastExit) { self?.message = nil }
        }
    }
}

/// Lower-center toast (§54): dark glass pill, white text, optional accent icon.
/// Never takes focus. Hosted at the app root; only renders in the Fusion theme.
struct FusionToastHost: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = center.message {
                HStack(spacing: OrivioSpacing.sm) {
                    if let icon = center.icon {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.palette.secondary)
                    }
                    Text(message)
                        .font(FusionType.button(theme.font))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, OrivioSpacing.xl)
                .padding(.vertical, OrivioSpacing.md)
                .atvGlass(in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                .padding(.bottom, OrivioSpacing.huge)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared themed card row

/// The horizontal card strip every themed home builds, with the focus, Back and
/// scroll bookkeeping owned ONCE.
///
/// Each theme used to write its own: the same ScrollViewReader + LazyHStack +
/// per-row `@FocusState` + `.id(item.id)` + Back-to-start, re-typed six times.
/// That is exactly how the homes drifted apart — Cinema's Back handler was
/// never wired to anything, Onyx's rows had no Back-to-start at all, and the
/// Equatable-cell fix had to be applied to every theme separately. A row built
/// here inherits all of it, so the next theme starts correct.
///
/// The theme still owns everything VISUAL: it supplies the header and the card
/// itself, plus spacing and alignment. `card` receives the row's focus binding
/// so a card can bind `.focused(binding, equals: id)` for the Back-to-start
/// jump; a card driving its own `@FocusState` can ignore it.
struct ThemedCardRow<Element: Identifiable, Header: View, Card: View>: View
where Element.ID == String {
    let items: [Element]
    var spacing: CGFloat = 24
    var horizontalPadding: CGFloat = 0
    var verticalPadding: CGFloat = 14
    var alignment: VerticalAlignment = .top
    var headerSpacing: CGFloat = 16
    /// Bubbled when Back is pressed while the FIRST card is already focused —
    /// the theme decides what "out of this row" means (top of page, sidebar…).
    var onBackAtStart: () -> Void = {}
    /// Fired when the focused card within this row changes. The Stremio board
    /// uses it to snap the focused row to a fixed line under its hero; themes
    /// that don't care leave it nil.
    var onFocusedIDChange: ((String?) -> Void)? = nil
    /// Apply the shared focus-expansion curve to the whole strip, so a card
    /// that grows on focus reflows its neighbours as one motion (Onyx).
    var expandsOnFocus: Bool = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder var card: (Element, FocusState<String?>.Binding) -> Card

    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: headerSpacing) {
            header()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: alignment, spacing: spacing) {
                        ForEach(items) { element in
                            card(element, $focusedID)
                                .id(element.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .focusExpand(expandsOnFocus ? focusedID : nil)
                }
                .scrollClipDisabled()
                // Back walks to the first card, then out of the row. The card
                // may have been unloaded by the LazyHStack, so scroll it back
                // into view before focusing it.
                .onExitCommand {
                    guard let first = items.first?.id, focusedID != first else {
                        onBackAtStart()
                        return
                    }
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(first, anchor: .leading) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusedID = first }
                }
            }
        }
        .onChange(of: focusedID) { _, id in onFocusedIDChange?(id) }
    }
}

// MARK: - Shared content-rating lookup

extension View {
    /// Keep `rating` in sync with the TMDB certification ("TV-MA", "PG-13") for
    /// the item a hero is showing.
    ///
    /// Every hero in the app needed this and each carried its own copy of the
    /// same `loadContentRating()` — seven of them, differing only in how they
    /// reached the item. The staleness guard each one hand-rolled ("is this
    /// still the item I fetched for?") is what `.task(id:)` already does: it
    /// cancels the in-flight fetch when the id changes, so a slow lookup can't
    /// land on the next title.
    ///
    /// Collections have no certification and are skipped.
    func contentRating(for item: MetaItem?, into rating: Binding<String?>) -> some View {
        task(id: item?.id) {
            guard let item, item.type != "collection" else {
                rating.wrappedValue = nil
                return
            }
            let value = await TMDBService.contentRating(imdbID: item.id, type: item.type)
            guard !Task.isCancelled else { return }
            rating.wrappedValue = value
        }
    }
}
