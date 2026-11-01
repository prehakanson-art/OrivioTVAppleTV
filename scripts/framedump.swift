// Usage: swift scripts/framedump.swift <video> <outDir> <fromSeconds> <toSeconds> <fps>
//
// Pulls frames out of a simulator screen recording so a transition can be
// inspected frame by frame (no ffmpeg needed).
import AVFoundation
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 6,
      let from = Double(args[3]), let to = Double(args[4]), let fps = Double(args[5]) else {
    print("usage: framedump <video> <outDir> <from> <to> <fps>")
    exit(1)
}
let url = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: url)
let duration = CMTimeGetSeconds(asset.duration)
print("duration \(duration)s")
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

var t = max(0, from)
var i = 0
while t <= min(to, duration) {
    let time = CMTime(seconds: t, preferredTimescale: 600)
    if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            let name = String(format: "f%03d-%.2fs.png", i, t)
            try? data.write(to: outDir.appendingPathComponent(name))
        }
    }
    t += 1.0 / fps
    i += 1
}
print("wrote \(i) frames")
