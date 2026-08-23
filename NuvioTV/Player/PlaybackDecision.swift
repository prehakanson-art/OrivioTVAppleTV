import Foundation

// The playback decision layer: WHAT the player chose and WHY, plus the user
// policy (mode) that steered it. Every meaningful branch in the pipeline —
// engine choice, Dolby Vision path, audio route, fallbacks — records one line
// here, and the info panel shows them verbatim. A player that can explain
// itself is debuggable from the couch; one that can't needs a Mac and a log.

/// The user's playback policy (Settings → Playback → Playback Mode).
///
///  automatic     Best compatible quality: native DV when the chain supports
///                it, the Profile 7 conversion per the device tier, audio via
///                whatever the route does best. The default.
///  fidelity      Touch the source as little as possible, and prefer the
///                highest-quality path even where the tier default is shy of
///                it (the A10X ships with P7 conversion off; Fidelity turns it
///                on and accepts the cost). Never silently downgrades.
///  compatibility Make it play: skip the native-DV remux entirely (HDR10-
///                mapped decode is the most forgiving path), no P7 conversion,
///                standard audio engine. For streams that misbehave on the
///                clever paths.
enum PlaybackMode: String, Codable, CaseIterable {
    case automatic, fidelity, compatibility

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .fidelity: return "Maximum Fidelity"
        case .compatibility: return "Compatibility"
        }
    }

    var summary: String {
        switch self {
        case .automatic:
            return "Picks the best path the stream, this Apple TV and your display support. Recommended."
        case .fidelity:
            return "Touches the source as little as possible: native Dolby Vision whenever the display allows, Profile 7 conversion always on, enhanced audio renderer when the route supports it. Heaviest on older boxes."
        case .compatibility:
            return "The most forgiving path: plain HDR10 decode instead of the Dolby Vision remux, no Profile 7 conversion, standard audio engine. Use when a stream misbehaves."
        }
    }
}

/// One recorded decision: what was being decided, what won, and why.
struct PlaybackDecisionEntry: Identifiable {
    let id = UUID()
    let stage: String     // "Engine", "Dolby Vision", "Audio Route"…
    let choice: String    // "FFmpeg", "Native DV (P7 → 8.1)"…
    let reason: String    // "MKV container", "display has no DV mode"…
}

/// The per-session decision log. Reset on every load; append-only after.
/// Deliberately dumb — no @Published, the info panel reads it on open.
struct PlaybackDecisionLog {
    private(set) var entries: [PlaybackDecisionEntry] = []

    /// Reset for a new load. Stages recorded once per SESSION (the audio
    /// route is fixed at engine setup) survive; per-stream stages don't.
    mutating func reset(keeping stages: Set<String> = ["Audio Route", "Mode"]) {
        entries.removeAll { !stages.contains($0.stage) }
    }

    /// Record a decision. A repeat for the same stage REPLACES the earlier
    /// line (the DV path upgrades mid-session: detect → remux → switched).
    mutating func record(_ stage: String, _ choice: String, because reason: String) {
        entries.removeAll { $0.stage == stage }
        entries.append(PlaybackDecisionEntry(stage: stage, choice: choice, reason: reason))
        NSLog("[OrivioDecision] %@ -> %@ (%@)", stage, choice, reason)
    }
}
