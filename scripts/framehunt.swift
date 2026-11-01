// Usage: swift scripts/framehunt.swift <video> [threshold]
//
// Scans a simulator recording at 15 fps and prints the time windows where the
// picture is actually moving (mean luminance change between samples), so a
// transition can then be dumped frame by frame with framedump.swift.
import AVFoundation
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: framehunt <video> [threshold]"); exit(1) }
let url = URL(fileURLWithPath: args[1])
let threshold = args.count > 2 ? Double(args[2]) ?? 0.6 : 0.6

let asset = AVURLAsset(url: url)
let duration = CMTimeGetSeconds(asset.duration)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: 320, height: 180)

func gray(_ t: Double) -> [UInt8]? {
    guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 320 * 180)
    guard let ctx = CGContext(data: &bytes, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 320, height: 180))
    return bytes
}

var previous: [UInt8]?
var t = 0.0
var moving = false
var runStart = 0.0
while t < duration {
    if let g = gray(t) {
        if let p = previous {
            var sum = 0
            for i in stride(from: 0, to: g.count, by: 1) { sum += abs(Int(g[i]) - Int(p[i])) }
            let mean = Double(sum) / Double(g.count)
            if mean > threshold, !moving {
                moving = true; runStart = t
            } else if mean <= threshold, moving {
                moving = false
                print(String(format: "motion %.2fs–%.2fs", runStart, t))
            }
        }
        previous = g
    }
    t += 1.0 / 15
}
if moving { print(String(format: "motion %.2fs–%.2fs", runStart, duration)) }
