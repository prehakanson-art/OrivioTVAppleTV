import AVFoundation
import Foundation

// Shims the ported engines (DV sample feed, Atmos HLS, media cache) were written
// against in the old app, mapped onto this app's equivalents.

/// The old app's network-readable probe trail. Here it goes to the DEBUG log;
/// Release builds compile it to nothing, as the old `dvDiag` did.
enum PlayerProbe {
    static func event(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        DebugLog.write("[\(category)] \(message())")
        #endif
    }

    /// A last-value note (the old probe's key/value table).
    static func note(_ key: String, _ value: @autoclosure () -> String) {
        #if DEBUG
        DebugLog.write("[note] \(key)=\(value())")
        #endif
    }

    static func count(_ key: String) {
        #if DEBUG
        DebugLog.write("[count] \(key)")
        #endif
    }
}

extension Bool {
    /// "Y" / "n" in the compact probe lines.
    var probe: String { self ? "Y" : "n" }
}

extension PlayerViewModel {
    /// Colour/format decisions (the old app's colour trail).
    nonisolated static func colorTrail(_ line: String) {
        PlayerProbe.event("colour", line)
    }
}

/// Audio-track language matching for the direct engine, on this app's
/// `Languages` rules: a real tag is definitive (639-2 B/T aliases included);
/// a label counts on whole words only — never `contains("es")` ("Chinese").
enum AudioLanguageMatch {
    static func matches(code: String?, label: String?, preferred: String) -> Bool {
        let raw = preferred.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let wanted = Languages.normalize(raw) ?? (raw.count == 2 ? raw.lowercased() : nil) else { return false }
        if let code, !code.isEmpty, code.lowercased() != "und" {
            return Languages.matches(code, wanted)
        }
        guard let label, !label.isEmpty else { return false }
        return Languages.matches(label, wanted)
    }
}

/// The audio route, for the direct engine (which builds its own renderers, so
/// no KSPlayer init configures the session for it).
enum AudioOutputCapability {
    /// Category + multichannel BEFORE the route is read — an inactive or
    /// unconfigured session reports 2 channels for an Atmos receiver.
    static func configureForMoviePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        if #available(tvOS 15.0, *) { try? session.setSupportsMultichannelContent(true) }
    }

    /// The route can take more than stereo (only meaningful once ACTIVE).
    static var supportsMultichannel: Bool {
        AVAudioSession.sharedInstance().maximumOutputNumberOfChannels > 2
    }
}
