import SwiftUI

/// A reusable, good-looking transport progress bar: a soft rounded track with a
/// buffered fill, an accent played fill, and (optionally) a glowing thumb.
/// Shared by the on-screen controls and the quick-seek HUD so they match.
struct ProgressTrack: View {
    @EnvironmentObject private var theme: ThemeManager
    var played: Double            // 0…1
    var buffered: Double          // 0…1
    var height: CGFloat = 10
    var showThumb: Bool = true
    var emphasized: Bool = false  // focused / actively seeking
    /// Chapter starts (0…1) drawn as small ticks on the track.
    var chapters: [Double] = []
    /// Draw a bright tick at the buffered edge (the "cache line").
    var showCacheMarker: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = CGFloat(min(max(played, 0), 1))
            let b = CGFloat(min(max(buffered, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(emphasized ? 0.22 : 0.16))
                // Cache bar (Netflix/Infuse gray): how far ahead the stream is
                // buffered. Clearly brighter than the base track so the cached
                // region reads at a glance in both focus states.
                if b > p {
                    Capsule().fill(.white.opacity(0.45))
                        .frame(width: w * b)
                }
                // Cache line: a bright tick marking exactly how far the cache
                // reaches, so you can see the buffer growing ahead of you.
                if showCacheMarker, b > 0.001, b < 0.999 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.9))
                        .frame(width: 4, height: height + 8)
                        .offset(x: w * b - 2, y: -4)
                }
                // Chapter ticks.
                ForEach(chapters, id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.7))
                        .frame(width: 3, height: height + 4)
                        .offset(x: w * CGFloat(fraction) - 1.5, y: -2)
                }
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.palette.secondary, theme.palette.secondary.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(w * p, height))
                    .shadow(color: theme.palette.secondary.opacity(emphasized ? 0.7 : 0), radius: 8)
                if showThumb {
                    Circle()
                        .fill(.white)
                        .frame(width: emphasized ? 26 : 20, height: emphasized ? 26 : 20)
                        .shadow(color: .black.opacity(0.6), radius: 5)
                        .overlay(Circle().stroke(theme.palette.secondary.opacity(emphasized ? 0.9 : 0), lineWidth: 3))
                        .offset(x: min(max(w * p - (emphasized ? 13 : 10), 0), w - (emphasized ? 26 : 20)))
                }
            }
        }
        .frame(height: emphasized ? height + 4 : height)
        .animation(.easeOut(duration: 0.18), value: emphasized)
    }
}

/// Quick-seek HUD shown while the user accumulates D-pad skips over the bare
/// video: a big signed offset (+50s), the target time, and a preview bar.
/// Observes the playback clock directly so it stays live without the parent
/// re-rendering on every tick.
struct SeekHUD: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var clock: PlaybackClock
    let delta: Double

    private var position: Double { clock.position }
    private var duration: Double { clock.duration }
    private var buffered: Double { clock.buffered }
    private var target: Double { min(max(position + delta, 0), max(duration, 0)) }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: OrivioSpacing.lg) {
                HStack(spacing: OrivioSpacing.md) {
                    Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(theme.palette.secondary)
                    Text(TimeFormat.signedDelta(delta))
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                        .foregroundStyle(.white)
                }

                ProgressTrack(
                    played: duration > 0 ? target / duration : 0,
                    buffered: duration > 0 ? buffered / duration : 0,
                    height: 10, showThumb: true, emphasized: true
                )
                .frame(height: 14)

                // Where you'd land: how far in ← → how much would remain.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TimeFormat.clock(target))
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("elapsed")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Text(TimeFormat.clock(duration))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("-\(TimeFormat.clock(max(duration - target, 0)))")
                            .font(.system(size: 26, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("remaining")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.bottom, OrivioSpacing.xxl)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
    }
}

/// Infuse-style scrub overlay. Uses the EXACT same transport bar as the
/// on-screen controls (title, ProgressTrack with cache line, time readouts),
/// so scrubbing feels like dragging the playhead of the normal bar rather than
/// a separate widget. A preview frame floats above the playhead. Observes the
/// `PlaybackClock` directly so the trackpad's many-times-per-second updates
/// re-render ONLY this bar — not the whole player — which is what keeps
/// scrubbing smooth.
struct InfuseScrubHUD: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var clock: PlaybackClock

    let title: String
    var episodeLine: String?
    /// Nearest preview frame for a given time (nil until previews finish).
    var previewProvider: (Double) -> UIImage? = { _ in nil }
    var wheelEngaged: Bool = false

    private var target: Double { clock.scrubTarget ?? clock.position }
    private var current: Double { clock.position }
    private var duration: Double { max(clock.duration, 1) }
    private var buffered: Double { clock.buffered }
    private var fraction: CGFloat { CGFloat(min(max(target / duration, 0), 1)) }

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episodeLine {
                        Text(episodeLine)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                // The unified transport bar with a preview frame floating over
                // the playhead. The preview overflows upward (no clip) so the
                // bar itself stays the same height as the controls timeline.
                GeometryReader { geo in
                    let w = geo.size.width
                    let x = min(max(w * fraction, 150), w - 150)
                    let preview = previewProvider(target)   // looked up ONCE
                    ZStack(alignment: .topLeading) {
                        ProgressTrack(
                            played: target / duration,
                            buffered: buffered / duration,
                            height: 10,
                            showThumb: true,
                            emphasized: true
                        )
                        .frame(height: 14)
                        .offset(y: 100)

                        // Live playback ghost tick (where the movie actually is).
                        Rectangle()
                            .fill(.white.opacity(0.5))
                            .frame(width: 3, height: 22)
                            .offset(x: w * CGFloat(min(max(current / duration, 0), 1)) - 1.5, y: 96)

                        // Preview frame + time bubble riding the playhead.
                        VStack(spacing: 8) {
                            if let preview {
                                Image(uiImage: preview)
                                    .resizable()
                                    .aspectRatio(16 / 9, contentMode: .fill)
                                    .frame(width: 260, height: 146)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(.white.opacity(0.3), lineWidth: 2))
                                    .shadow(color: .black.opacity(0.8), radius: 12, y: 5)
                            }
                            Text(TimeFormat.clock(target))
                                .font(.system(size: 26, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, OrivioSpacing.md)
                                .padding(.vertical, 6)
                                .playerChrome(in: Capsule())
                        }
                        .frame(width: 260, alignment: .center)
                        .offset(x: x - 130, y: preview != nil ? -110 : 40)
                    }
                }
                .frame(height: 128)

                HStack {
                    Text(TimeFormat.clock(target))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(TimeFormat.signedDelta(target - current))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.palette.secondary)
                    Spacer()
                    if wheelEngaged {
                        Label("Fine-tuning", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Label("Click to seek", systemImage: "hand.tap")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text(TimeFormat.clock(duration))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.bottom, OrivioSpacing.xxl)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 460)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
    }
}

/// Wall-clock time-of-day when the movie STARTED (now − elapsed) and when it
/// will END (now + remaining), formatted like "8:34 PM". Recomputed every tick
/// so it stays live. Shared by the peek bar and the controls timeline.
enum WatchClock {
    static func started(position: Double) -> String {
        Self.format(Date().addingTimeInterval(-position))
    }
    static func ends(position: Double, duration: Double) -> String {
        Self.format(Date().addingTimeInterval(max(duration - position, 0)))
    }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static func format(_ date: Date) -> String { df.string(from: date) }
}

/// Minimal bottom timeline shown on a LIGHT touchpad tap (contact, no click):
/// the progress track with the time you STARTED on the left and the time you'll
/// FINISH on the right (both live). Passive (no menu); a click while it's up
/// drops into the full scrub HUD to edit. Auto-hides after a few seconds.
struct PeekBar: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: OrivioSpacing.sm) {
                ProgressTrack(
                    played: clock.duration > 0 ? min(clock.position / clock.duration, 1) : 0,
                    buffered: clock.duration > 0 ? min(clock.buffered / clock.duration, 1) : 0,
                    height: 8,
                    showThumb: true,
                    emphasized: false
                )
                HStack {
                    endpointLabel("Started", WatchClock.started(position: clock.position), sub: TimeFormat.clock(clock.position))
                    Spacer()
                    Text(TimeFormat.clock(clock.position))
                        .font(.system(size: 24, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer()
                    endpointLabel("Ends", WatchClock.ends(position: clock.position, duration: clock.duration),
                                  sub: "-\(TimeFormat.clock(max(clock.duration - clock.position, 0)))", trailing: true)
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.bottom, OrivioSpacing.xxl)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            )
        }
        .allowsHitTesting(false)
    }

    private func endpointLabel(_ caption: String, _ time: String, sub: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(caption.uppercased())
                .font(.system(size: 13, weight: .bold)).kerning(1)
                .foregroundStyle(.white.opacity(0.45))
            Text(time)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            Text(sub)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
