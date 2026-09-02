import SwiftUI

/// Wall-clock time-of-day when the movie STARTED (now − elapsed) and when it
/// will END (now + remaining), formatted like "8:34 PM". Recomputed every tick
/// so it stays live. Used by the Fusion controls timeline (the peek bar and
/// the old scrub HUDs that shared it are gone — this is all that remains of
/// this file).
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
