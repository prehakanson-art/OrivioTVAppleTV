import SwiftUI

/// The in-player diagnostics HUD (Settings → Performance → Developer).
///
/// One glance answers the questions that otherwise need a Mac attached: which
/// engine is playing, at what fps, how many frames it has dropped, how far
/// audio and video have drifted, what the stream's real bitrate is and how
/// deep the read-ahead buffer sits. Polls once a second — cheap enough to
/// leave on while chasing a stutter, and it never eats focus.
struct PlayerDiagnosticsHUD: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var snapshot = PlayerViewModel.DiagnosticsSnapshot()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Engine", snapshot.engine)
            if snapshot.fps > 0 {
                row("FPS", String(format: "%.1f", snapshot.fps),
                    bad: snapshot.fps < 22)
            }
            row("Dropped", "\(snapshot.droppedFrames)", bad: snapshot.droppedFrames > 30)
            if abs(snapshot.avSyncDiff) > 0.001 {
                row("A/V drift", String(format: "%+.0f ms", snapshot.avSyncDiff * 1000),
                    bad: abs(snapshot.avSyncDiff) > 0.12)
            }
            if snapshot.bitrateMbps > 0 {
                row("Bitrate", String(format: "%.1f Mbps", snapshot.bitrateMbps))
            }
            row("Buffer", String(format: "%.0f s ahead", snapshot.bufferSeconds),
                bad: snapshot.bufferSeconds < 2)
            if snapshot.downloadedMB > 0 {
                row("Read", String(format: "%.0f MB", snapshot.downloadedMB))
            }
        }
        .font(.system(size: 20, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
        .padding(.top, 40)
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear { snapshot = viewModel.diagnosticsSnapshot() }
        .onReceive(tick) { _ in snapshot = viewModel.diagnosticsSnapshot() }
    }

    @ViewBuilder private func row(_ label: String, _ value: String, bad: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Text(value).foregroundStyle(bad ? Color.red : .white)
        }
        .frame(width: 320)
    }
}
