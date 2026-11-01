import AVFoundation
import Combine
import CoreGraphics
import Foundation
import UIKit
// INTERNAL on purpose: nothing below exposes an AetherEngine type, and with
// the module built with library evolution the app that imports it never loads
// AetherEngine's module, its FFmpeg headers or LibDovi's `Dovi` (see
// Package.swift for why that matters).
internal import AetherEngine

// MARK: - Public, Orivio-defined value types

/// What the engine is doing, reduced to what the player screen acts on.
/// Frozen so the app's exhaustive switch needs no `@unknown default` now that
/// the module is resilient.
@frozen
public enum AetherPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    /// The source played to completion on its own. Terminal.
    case ended
    /// Terminal failure. The text is for logs and the decision log, not a key.
    case failed(String)
}

/// One audio or subtitle track as the engine lists it. `id` is the container
/// stream index (or the engine's external-track id) — the value every
/// selection call takes.
public struct AetherTrack: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let language: String?
    public let codec: String
    public let channels: Int
    public let isDefault: Bool
    public let isForced: Bool
    public let isCommentary: Bool
    public let isHearingImpaired: Bool
    public let isAtmos: Bool
    public let isDTSX: Bool
    public let isExternal: Bool
    public let profile: String?

    /// A label for the picker: the engine's own name, with the facts it does
    /// not always spell out (Atmos, DTS:X, channel count) appended once.
    public var displayName: String {
        var label = name.isEmpty ? (language?.uppercased() ?? codec.uppercased()) : name
        let lower = label.lowercased()
        if isAtmos, !lower.contains("atmos") { label += " · Atmos" }
        if isDTSX, !lower.contains("dts:x"), !lower.contains("dts-x") { label += " · DTS:X" }
        return label
    }
}

/// One decoded subtitle cue on the SOURCE timeline. Text cues carry `text`;
/// bitmap cues (PGS / DVB / VobSub) carry `image` plus where it sits on the
/// authoring canvas, in canvas pixels.
public struct AetherSubtitleCue: Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let text: String?
    public let image: CGImage?
    public let origin: CGPoint
    public let canvasSize: CGSize
    public let isForced: Bool
}

/// A chapter mark from the container.
public struct AetherChapter: Sendable {
    public let title: String
    public let start: Double
    public let end: Double
}

/// The per-load knobs Orivio sets. Everything not listed keeps the engine's
/// own default, which is tuned for Apple TV already.
public struct AetherLoadConfiguration: Sendable {
    /// Addon-declared request headers (Referer / User-Agent / auth).
    public var httpHeaders: [String: String] = [:]
    /// Ordered audio-language preference, honoured on the FIRST frame (no
    /// reload after load to switch language).
    public var preferredAudioLanguages: [String] = []
    /// Mirror of the Apple TV's Match Content switch.
    public var matchContent = true
    /// Lossless FLAC bridge (up to 7.1 LPCM) for TrueHD / DTS-HD MA / DTS
    /// instead of the 128 kbps/ch E-AC-3 bridge. Needs an HDMI sink that
    /// takes multichannel LPCM.
    public var losslessAudioBridge = false
    /// Render TrueHD Atmos objects and DTS:X heights into this many-channel
    /// speaker bed (12 → 7.1.4, 16 → 9.1.6); 0 keeps the 7.1 channel decode.
    /// Takes effect on tvOS 26+ only (the APAC / MAT path), a no-op below.
    public var objectAudioBedChannels = 0
    /// Background bounded decode that confirms which tracks really carry
    /// Atmos (E-AC-3 JOC) and republishes the track list.
    public var confirmAtmos = true
    /// Compose Dolby Vision Profile 7 FEL dual-layer on the software route
    /// instead of the single-layer 8.1 conversion.
    public var preferDualLayerDolbyVision = false
    /// Forward buffer, in ~4 s segments (nil = engine default ≈ 40 s).
    public var forwardBufferSegments: Int?
    /// Serve each loopback segment while it is being written: faster starts
    /// on a slow link, no change on a fast one.
    public var progressiveSegmentDelivery = true
    /// Lip-sync offset in seconds, positive = audio later.
    public var audioDelaySeconds: Double = 0
    /// Remote HLS: hand it to AVPlayer directly (the engine's own bypass).
    public var isRemoteHLS = false
    public var isLive = false

    public init() {}
}

// MARK: - The engine adapter

/// AetherEngine behind a small, VLCEngine-shaped surface the player view model
/// drives: one instance per playback session, a UIView to render into, a
/// state/time/track callback set, and the transport calls.
///
/// Everything here runs on the main actor, as AetherEngine does.
@MainActor
public final class AetherPlaybackEngine {

    /// True when this build carries the engine at all (it always does; kept
    /// so call sites read as a capability check rather than an assumption).
    public static let isAvailable = true

    /// The engine version string, for the info panel / diagnostics.
    public static var versionDescription: String { "AetherEngine \(AetherEngine.version)" }

    /// Which of the trait-gated components this build compiled in.
    public static var builtInComponents: [String] {
        AetherEngine.OptionalComponent.allCases.filter(\.isBuiltIn).map(\.traitName)
    }

    /// Warm a source's opening bytes before anything asks to play it (Up Next).
    public static func prewarm(url: URL, httpHeaders: [String: String] = [:]) {
        Task.detached(priority: .utility) {
            _ = await AetherEngine.prewarm(url: url, httpHeaders: httpHeaders)
        }
    }

    // MARK: Callbacks (main actor)

    public var onState: ((AetherPlaybackState) -> Void)?
    public var onBuffering: ((Bool) -> Void)?
    /// (presentation time, duration, buffered-to position, source time).
    /// Subtitles are timed against the SOURCE time.
    public var onTime: ((Double, Double, Double, Double) -> Void)?
    /// The audio or subtitle track list (or the active selection) changed.
    public var onTracksChanged: (() -> Void)?
    /// The decoded cue list for the active embedded subtitle track.
    public var onSubtitleCues: (([AetherSubtitleCue]) -> Void)?
    /// The first frame is ready / the video format or size became known.
    public var onVideoInfoChanged: (() -> Void)?

    // MARK: State

    private let engine: AetherEngine
    private let playerView = AetherPlayerView(frame: .zero)
    private var subscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var loadToken = 0
    private var isStopped = false

    /// The view the engine presents into. Hosted by PlayerVideoView.
    public var videoView: UIView { playerView }

    public init() throws {
        engine = try AetherEngine()
        playerView.backgroundColor = .black
        engine.bind(view: playerView)
        observe()
    }

    // MARK: Loading

    /// Open `url` at `startPosition`. Returns immediately; the outcome arrives
    /// through `onState`. A load superseded by a newer one (or by `stop`) is
    /// NOT a failure and reports nothing.
    public func load(url: URL, startPosition: Double?, configuration: AetherLoadConfiguration) {
        isStopped = false
        loadTask?.cancel()
        loadToken &+= 1
        let token = loadToken
        let options = Self.loadOptions(for: configuration)
        let start = (startPosition ?? 0) > 0 ? startPosition : nil
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.engine.load(url: url, startPosition: start, options: options)
            } catch is CancellationError {
                // Superseded by a newer load or a stop — not this session's failure.
            } catch {
                guard token == self.loadToken, !self.isStopped else { return }
                self.onState?(.failed(String(describing: error)))
            }
        }
    }

    private static func loadOptions(for configuration: AetherLoadConfiguration) -> LoadOptions {
        // Assigned field by field on top of the engine's own defaults, so a
        // field the engine adds later keeps its tuned default here.
        var options = LoadOptions()
        options.httpHeaders = configuration.httpHeaders
        options.preferDualLayerDolbyVision = configuration.preferDualLayerDolbyVision
        options.matchContentEnabled = configuration.matchContent
        options.audioBridgeMode = configuration.losslessAudioBridge ? .lossless : .surroundCompat
        options.objectAudioRendering = objectAudio(bedChannels: configuration.objectAudioBedChannels)
        options.isLive = configuration.isLive
        options.nativeRemoteHLS = configuration.isRemoteHLS
        options.confirmAtmos = configuration.confirmAtmos
        options.preferredAudioLanguages = configuration.preferredAudioLanguages
        options.forwardBufferSegments = configuration.forwardBufferSegments
        options.progressiveSegmentDelivery = configuration.progressiveSegmentDelivery
        options.autoplay = true
        options.audioDelaySeconds = configuration.audioDelaySeconds
        // An FFmpeg-only codec (AV1 on older boxes, VC-1, MPEG-2, Hi10P…)
        // moves to the software route instead of failing the load.
        options.escalatesToSoftwarePath = true
        // The engine owns the HDMI handshake: it must write the display
        // criteria synchronously before the item is assigned (tvOS 26.5
        // validates HDR variants against the panel's CURRENT mode).
        options.displayCriteriaOwner = .engine
        return options
    }

    private static func objectAudio(bedChannels: Int) -> ObjectAudioRendering {
        switch bedChannels {
        case 16...: return .render(.l916)
        case 12...: return .render(.l714)
        case 10...: return .render(.l712)
        case 8...: return .render(.l512)
        default: return .off
        }
    }

    // MARK: Transport

    public func play() { engine.play() }
    public func pause() { engine.pause() }

    public func seek(to seconds: Double) {
        let target = max(0, seconds)
        Task { @MainActor [weak self] in await self?.engine.seek(to: target) }
    }

    /// Stop the session. `final` means this instance is done for good: the
    /// view is unbound, the observers dropped and the engine leaves its
    /// shared-output registry. The audio session stays active either way
    /// (`deactivatesAudioSessionOnStop` is left off: the host owns it). A
    /// non-final stop keeps the instance ready for another `load`.
    ///
    /// The display criteria are NEVER reset here: the player screen releases
    /// the panel itself (`releaseDisplayForExit`), behind its opaque exit
    /// cover and after the video surface is detached — the sequencing that
    /// keeps wedge-prone panels out of the grey state. A reset from inside the
    /// teardown would be a second, unsequenced handshake.
    public func stop(final: Bool = true) {
        isStopped = true
        loadTask?.cancel()
        loadTask = nil
        loadToken &+= 1
        engine.stop(resetDisplayCriteria: false, finalTeardown: final)
        if final {
            subscriptions.removeAll()
            engine.unbind(view: playerView)
        }
    }

    /// Keep the current AVPlayerItem on screen across the next `load` (episode
    /// → episode), so the swap does not flash black between the two items.
    public func prepareForItemReplacement() { engine.prepareForItemReplacement() }

    public var rate: Float = 1 {
        didSet { engine.setRate(rate) }
    }

    public func setMuted(_ muted: Bool) { engine.volume = muted ? 0 : 1 }

    /// Positive = audio later, the same convention as Orivio's audio sync.
    public func setAudioDelay(_ seconds: Double) { engine.setAudioDelay(seconds) }

    // MARK: Tracks

    public var audioTracks: [AetherTrack] { engine.audioTracks.map(Self.track) }
    public var subtitleTracks: [AetherTrack] {
        // Tracks AVPlayer draws itself (remote HLS renditions) still list
        // here; selection drives AVPlayer's media selection for those.
        engine.subtitleTracks.map(Self.track)
    }
    public var activeAudioID: Int? { engine.activeAudioTrackIndex }
    public var activeSubtitleID: Int? { engine.activeSubtitleTrackIndex }

    public func selectAudio(id: Int) {
        guard id != engine.activeAudioTrackIndex else { return }
        engine.selectAudioTrack(index: id)
    }

    public func selectSubtitle(id: Int) {
        guard id != engine.activeSubtitleTrackIndex else { return }
        engine.selectSubtitleTrack(index: id)
    }

    public func clearSubtitle() { engine.clearSubtitle() }

    /// True when the active subtitle is drawn by AVPlayer (remote HLS
    /// rendition), so the host overlay must stay empty for it.
    public var subtitlesDrawnByPlayer: Bool { engine.videoRoute == .remoteBypass }

    private static func track(_ info: TrackInfo) -> AetherTrack {
        AetherTrack(
            id: info.id, name: info.name, language: info.language, codec: info.codec,
            channels: info.channels, isDefault: info.isDefault, isForced: info.isForced,
            isCommentary: info.isCommentary, isHearingImpaired: info.isHearingImpaired,
            isAtmos: info.isAtmos, isDTSX: info.isDTSX, isExternal: info.isExternal,
            profile: info.profile
        )
    }

    // MARK: Facts

    public var currentTime: Double { engine.clock.currentTime }
    public var sourceTime: Double { engine.clock.sourceTime }
    public var duration: Double { engine.duration }
    public var bufferedPosition: Double { engine.clock.bufferedPosition }
    public var isPlaying: Bool { engine.state == .playing }
    public var hasFirstFrame: Bool { engine.hasFirstFrameReadyForDisplay }

    public var naturalSize: CGSize {
        if let size = engine.softwareDisplaySize, size.width > 0, size.height > 0 { return size }
        let w = engine.sourceVideoWidth, h = engine.sourceVideoHeight
        return w > 0 && h > 0 ? CGSize(width: Int(w), height: Int(h)) : .zero
    }

    /// The layer AVKit's Picture in Picture can take over: present on the
    /// native (AVPlayer) routes, nil on the software route.
    public var nativePlayerLayer: AVPlayerLayer? { engine.nativePlayerLayer }

    public var chapters: [AetherChapter] {
        engine.mediaChapters.map {
            AetherChapter(title: $0.name, start: $0.startSeconds,
                          end: $0.startSeconds + $0.durationSeconds)
        }
    }

    /// What the PANEL presents (already clamped to its capability).
    public var videoFormatLabel: String { Self.label(engine.videoFormat) }
    /// What the SOURCE carries.
    public var sourceFormatLabel: String {
        let base = Self.label(engine.sourceVideoFormat)
        if let profile = engine.sourceDVProfile { return "\(base) (Profile \(profile))" }
        return base
    }
    public var isHDROutput: Bool { engine.videoFormat != .sdr }
    public var routeLabel: String {
        switch engine.videoRoute {
        case .none: return "none"
        case .remoteBypass: return "AVPlayer (direct HLS)"
        case .loopback: return "AVPlayer (loopback HLS)"
        case .software: return "Software (Metal)"
        case .audio: return "Audio only"
        }
    }
    /// The picture goes through AVPlayer (direct or loopback HLS), as opposed
    /// to the engine's software (Metal) route.
    public var usesNativeVideoRoute: Bool {
        engine.videoRoute == .remoteBypass || engine.videoRoute == .loopback
    }
    public var videoDecoderLabel: String? { engine.activeVideoDecoder }
    public var audioDecoderLabel: String? { engine.activeAudioDecoder }

    private static func label(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    // MARK: Observation

    private func observe() {
        engine.$state
            .removeDuplicates()
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.forward(state) }
            }
            .store(in: &subscriptions)

        engine.$isBuffering
            .removeDuplicates()
            .sink { [weak self] buffering in
                MainActor.assumeIsolated { self?.onBuffering?(buffering) }
            }
            .store(in: &subscriptions)

        engine.clock.$currentTime
            .sink { [weak self] current in
                MainActor.assumeIsolated {
                    guard let self, !self.isStopped else { return }
                    self.onTime?(current, self.engine.duration,
                                 self.engine.clock.bufferedPosition, self.engine.clock.sourceTime)
                }
            }
            .store(in: &subscriptions)

        Publishers.Merge4(
            engine.$audioTracks.map { _ in () },
            engine.$subtitleTracks.map { _ in () },
            engine.$activeAudioTrackIndex.map { _ in () },
            engine.$activeSubtitleTrackIndex.map { _ in () }
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.onTracksChanged?() }
        }
        .store(in: &subscriptions)

        engine.$subtitleCues
            .sink { [weak self] cues in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onSubtitleCues?(cues.map { self.cue($0) })
                }
            }
            .store(in: &subscriptions)

        Publishers.Merge3(
            engine.$hasFirstFrameReadyForDisplay.map { _ in () },
            engine.$videoFormat.map { _ in () },
            engine.$softwareDisplaySize.map { _ in () }
        )
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.onVideoInfoChanged?() }
        }
        .store(in: &subscriptions)
    }

    private func forward(_ state: PlaybackState) {
        guard !isStopped else { return }
        switch state {
        case .idle: onState?(.idle)
        case .loading: onState?(.loading)
        case .playing: onState?(.playing)
        case .paused: onState?(.paused)
        case .seeking: onState?(.seeking)
        case .ended: onState?(.ended)
        case .error(let message): onState?(.failed(message))
        }
    }

    private func cue(_ cue: SubtitleCue) -> AetherSubtitleCue {
        switch cue.body {
        case .image(let image):
            // Position is normalised [0, 1] against the canvas; Orivio's
            // overlay places bitmap cues in canvas PIXELS. With no canvas from
            // the decoder, the source frame is the canvas.
            var canvas = image.canvasSize
            if canvas.width <= 0 || canvas.height <= 0 {
                canvas = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
            }
            let origin = CGPoint(x: image.position.minX * canvas.width,
                                 y: image.position.minY * canvas.height)
            return AetherSubtitleCue(id: cue.id, start: cue.startTime, end: cue.endTime,
                                     text: nil, image: image.cgImage, origin: origin,
                                     canvasSize: canvas, isForced: image.isForced)
        case .text, .richText:
            return AetherSubtitleCue(id: cue.id, start: cue.startTime, end: cue.endTime,
                                     text: cue.text, image: nil, origin: .zero,
                                     canvasSize: .zero, isForced: false)
        }
    }
}
