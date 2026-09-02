import SwiftUI
import QuartzCore

/// Developer diagnostic: a live frames-per-second read-out, driven by a
/// CADisplayLink so it reflects the ACTUAL compositor frame rate (not a
/// SwiftUI re-render count). Toggled by Settings → Performance → Show FPS
/// overlay; attached once at the app root so it measures the whole UI.
///
/// Colour-coded against the display's own max refresh (usually 60): green =
/// smooth, amber = some drops, red = janky — so the effect switches can be
/// tuned by eye on the real Apple TV.
struct FPSOverlay: View {
    @StateObject private var meter = FrameMeter()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text("\(meter.fps) FPS")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(color.opacity(0.8), lineWidth: 2))
        .padding(.top, 40)
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)   // never eats focus/clicks
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private var color: Color {
        let target = Double(max(meter.maxRefresh, 1))
        switch Double(meter.fps) / target {
        case 0.9...:   return .green
        case 0.6..<0.9: return .yellow
        default:       return .red
        }
    }
}

/// Counts real display frames over a rolling one-second window.
@MainActor
final class FrameMeter: ObservableObject {
    @Published var fps: Int = 0
    /// The display's maximum refresh rate (60 on current Apple TV hardware),
    /// so the colour thresholds scale if that ever changes.
    let maxRefresh: Int = UIScreen.main.maximumFramesPerSecond

    private var link: CADisplayLink?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        frames = 0
        windowStart = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if windowStart == 0 { windowStart = link.timestamp }
        frames += 1
        let elapsed = link.timestamp - windowStart
        if elapsed >= 1 {
            fps = Int((Double(frames) / elapsed).rounded())
            frames = 0
            windowStart = link.timestamp
        }
    }
}
