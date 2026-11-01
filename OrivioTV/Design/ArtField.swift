import SwiftUI
import UIKit

/// Dominant colours of an artwork, rendered as a soft blurred field.
/// Extraction: downscale to 32×18, sample corner/centre averages, boost
/// saturation ×1.15 and clamp brightness to 35–55 % so white text always
/// reads. Cached by URL in memory and on disk. Rendering is a few large radial
/// gradients in a `Canvas` — cheap and identical on every tier (no live blur).
struct ArtPalette: Codable, Hashable {
    var colors: [RGB]

    struct RGB: Codable, Hashable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    }

    var lightest: Color {
        let c = colors.max { ($0.r + $0.g + $0.b) < ($1.r + $1.g + $1.b) } ?? RGB(r: 0.3, g: 0.4, b: 0.5)
        return c.color
    }
}

final class ArtPaletteCache: @unchecked Sendable {
    static let shared = ArtPaletteCache()
    private var memory: [String: ArtPalette] = [:]
    private let lock = NSLock()
    private let fileURL = Persistence.fileURL("artfield-palettes.json")
    private var dirty = false

    init() {
        if let stored = Persistence.loadFile([String: ArtPalette].self, url: fileURL) { memory = stored }
    }

    func cached(_ url: String) -> ArtPalette? {
        lock.lock(); defer { lock.unlock() }
        return memory[url]
    }

    func palette(for url: String) async -> ArtPalette? {
        if let hit = cached(url) { return hit }
        guard let u = URL(string: url), let img = await ImagePipeline.shared.image(u, maxPixel: 200),
              let p = Self.extract(img) else { return nil }
        let snapshot: [String: ArtPalette] = lock.withLock {
            memory[url] = p
            if memory.count > 600 { memory.removeAll() }
            return memory
        }
        // Encoding and writing the whole palette map was landing on the main
        // actor right as a Detail/Home transition ran.
        let url = fileURL
        Task.detached(priority: .utility) { Persistence.saveFile(snapshot, url: url) }
        return p
    }

    static func extract(_ image: UIImage) -> ArtPalette? {
        guard let cg = image.cgImage else { return nil }
        let w = 32, h = 18
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func avg(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> ArtPalette.RGB {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in y0..<y1 { for x in x0..<x1 {
                let i = (y * w + x) * 4
                r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
            } }
            return normalize(ArtPalette.RGB(r: r / n / 255, g: g / n / 255, b: b / n / 255))
        }
        let colors = [
            avg(0, 0, 16, 9), avg(16, 0, 32, 9), avg(0, 9, 16, 18), avg(16, 9, 32, 18), avg(8, 4, 24, 14),
        ]
        return ArtPalette(colors: colors)
    }

    /// Saturation ×1.15, brightness clamped to 35–55 %.
    static func normalize(_ c: ArtPalette.RGB) -> ArtPalette.RGB {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        sat = min(1, sat * 1.15)
        bri = min(0.55, max(0.35, bri))
        let out = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        out.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ArtPalette.RGB(r: Double(r), g: Double(g), b: Double(b))
    }
}

/// The blurred colour field. Always mounted; crossfades (0.8 s) on change.
struct ArtField: View {
    let imageURL: String?
    var intensity: Double = 1
    @Environment(\.theme) private var theme
    @State private var palette: ArtPalette?

    var body: some View {
        ZStack {
            theme.ambientGradient
            // A8/A10X: the artwork tints are decorative and each one costs a
            // 200 px image load plus extraction on every focused title. Keep the
            // static ambient gradient there; high-tier devices keep the field.
            if !PerformanceProfile.isConstrained, theme.artworkTint, let palette {
                ArtFieldCanvas(palette: palette)
                    .opacity(intensity)
                    .transition(.opacity)
                    .id(palette)
            }
        }
        .animation(Motion.artField, value: palette)
        .allowsHitTesting(false)
        .task(id: imageURL) {
            guard !PerformanceProfile.isConstrained, theme.artworkTint, let url = imageURL else { palette = nil; return }
            if let hit = ArtPaletteCache.shared.cached(url) { palette = hit; return }
            let p = await ArtPaletteCache.shared.palette(for: url)
            if !Task.isCancelled { palette = p }
        }
    }
}

private struct ArtFieldCanvas: View {
    let palette: ArtPalette

    var body: some View {
        Canvas { ctx, size in
            let base = palette.colors.last?.color ?? .gray
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base.opacity(0.9)))
            let anchors: [CGPoint] = [
                CGPoint(x: 0.15, y: 0.2), CGPoint(x: 0.85, y: 0.15), CGPoint(x: 0.2, y: 0.85), CGPoint(x: 0.8, y: 0.8),
            ]
            for (i, c) in palette.colors.prefix(4).enumerated() {
                let center = CGPoint(x: anchors[i].x * size.width, y: anchors[i].y * size.height)
                let radius = max(size.width, size.height) * 0.65
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [c.color.opacity(0.85), c.color.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
            }
            // Keep the field dark enough for white text.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.25)))
        }
        .drawingGroup()
    }
}
