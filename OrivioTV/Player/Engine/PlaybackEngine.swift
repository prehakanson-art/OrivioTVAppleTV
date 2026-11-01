import UIKit
import AVFoundation
import KSPlayer

enum EngineKind: String, Codable, CaseIterable {
    case native, ffmpeg, vlc, dvDirect

    var label: String {
        switch self {
        case .native: return "Native"
        case .ffmpeg: return "FFmpeg"
        case .vlc: return "VLC"
        case .dvDirect: return "Dolby Vision direct"
        }
    }
}

enum EngineState: Equatable {
    case preparing
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

/// A track the engine exposes (audio or embedded subtitle).
struct EngineTrack: Identifiable, Hashable {
    let id: String
    let index: Int
    let name: String
    let language: String?
    let codec: String?
    let channels: Int?
    let isDefault: Bool
    let isForced: Bool
    let isImage: Bool
    var isAtmos: Bool = false

    var displayName: String {
        var parts: [String] = []
        if let l = language, let n = Languages.normalize(l) { parts.append(Languages.name(n)) }
        if !name.isEmpty, !parts.contains(name) { parts.append(name) }
        if let c = codec { parts.append(c) }
        if let ch = channels { parts.append(Self.channelLabel(ch)) }
        if isForced { parts.append("Forced") }
        return parts.isEmpty ? "Track \(index + 1)" : parts.joined(separator: " · ")
    }

    static func channelLabel(_ ch: Int) -> String {
        switch ch {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(ch) ch"
        }
    }
}

/// What the Video tab's Format column shows.
struct VideoFormatInfo: Equatable {
    var dynamicRange: String?
    var output: String?
    var codec: String?
    var resolution: CGSize?
    var bitDepth: Int?
    var primaries: String?
    var transfer: String?
    var frameRate: Double?
    var bitrate: Int?
    var isDolbyVision = false
    var dvProfile: Int?
    var isHDR = false
    var untagged = false
}

struct AudioFormatInfo: Equatable {
    var codec: String?
    var channels: Int?
    var atmos: String?
    var output: String?
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engine(_ e: PlaybackEngine, state: EngineState)
    func engineDidRenderFirstFrame(_ e: PlaybackEngine)
    func engineTracksChanged(_ e: PlaybackEngine)
}

/// The common surface every engine offers the view model.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    var delegate: PlaybackEngineDelegate? { get set }
    var view: UIView { get }
    var currentTime: Double { get }
    var duration: Double { get }
    /// Seconds buffered ahead of the playhead (absolute time).
    var bufferedTime: Double { get }
    var isPlaying: Bool { get }
    var isReady: Bool { get }
    var naturalSize: CGSize { get }
    var chapters: [Chapter] { get }
    var rate: Float { get set }
    var audioTracks: [EngineTrack] { get }
    var selectedAudio: EngineTrack? { get }
    var subtitleTracks: [EngineTrack] { get }
    var videoInfo: VideoFormatInfo { get }
    var audioInfo: AudioFormatInfo { get }
    var supportsAudioDelay: Bool { get }
    /// Seconds; positive = voices later.
    var audioDelay: Double { get set }
    var downloadedBytes: Int64 { get }
    /// Bridge for Picture in Picture on the native engine.
    var avPlayerLayer: AVPlayerLayer? { get }

    func start(url: URL, headers: [String: String], startAt: Double)
    func play()
    func pause()
    func seek(to time: Double, completion: @escaping (Bool) -> Void)
    func select(audio: EngineTrack)
    /// Embedded subtitle selection (nil = none). Text cues are fetched with `subtitleParts(at:)`.
    func select(subtitle: EngineTrack?)
    func subtitleParts(at time: Double) -> [SubtitlePart]
    func setContentMode(_ mode: UIView.ContentMode)
    func stop()
}

/// Every engine-selection branch logs a line here; shown in the info panel.
/// "A player that can explain itself is debuggable from the couch."
@MainActor
final class PlaybackDecisionLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let stage: String
        let choice: String
        let reason: String
    }
    @Published private(set) var entries: [Entry] = []

    func log(_ stage: String, _ choice: String, _ reason: String) {
        entries.append(Entry(stage: stage, choice: choice, reason: reason))
        if entries.count > 80 { entries.removeFirst(entries.count - 80) }
        #if DEBUG
        print("[decision] \(stage): \(choice) — \(reason)")
        DebugLog.write("[decision] \(stage): \(choice) — \(reason)")
        #endif
    }
}
