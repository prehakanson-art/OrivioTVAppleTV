import AVFoundation
import CoreMedia
import Foundation
import KSPlayer
import Libavcodec
import Libavformat
import Libavutil
import UIKit

/// Direct Dolby Vision sample feed — the Infuse/SenPlayer architecture.
///
/// The remux→loopback-HLS→AVPlayer pipeline produces true DV output, but it
/// rents Apple's HLS machinery, and CoreMedia retains every byte it fetches
/// over that path — process-scoped, unreleasable, measured live at the fetch
/// rate until jetsam. This engine bypasses all of it: demux the source with
/// FFmpeg, convert the RPU when the file is Profile 7, wrap each compressed
/// HEVC access unit in a CMSampleBuffer tagged with a Dolby Vision format
/// description, and enqueue it straight into AVSampleBufferDisplayLayer.
/// tvOS decodes via VideoToolbox and drives the display into genuine DV mode
/// — and the only buffer in the app is OUR bounded queue, which clears
/// behind the playhead by construction. No server, no playlist, no AVPlayer,
/// no retention.
///
/// v1 scope: video + one audio track (E-AC3/AC3/AAC), play/pause/seek/rate,
/// position callbacks. Track menus and embedded subtitles are not wired —
/// any failure to start reports out so the caller can fall back to the
/// remux path (which stays intact behind this).
final class DVSampleEngine {
    // MARK: Public surface

    /// Hosts the AVSampleBufferDisplayLayer; hand this to PlayerVideoView.
    let videoView = DVSampleLayerView()

    /// Fired on main ~2×/s with the current position (absolute source secs).
    var onTime: ((Double) -> Void)?
    /// The demuxer reached EOF and both renderers drained.
    var onEnded: (() -> Void)?
    /// Terminal failure after a successful start (decode/enqueue/network).
    var onError: ((String) -> Void)?
    /// Underrun state: true while the network can't keep the queue fed and
    /// playback is held; false when refilled and rolling again.
    var onBuffering: ((Bool) -> Void)?

    private(set) var duration: Double = 0
    private(set) var videoFPS: Float = 0
    private(set) var videoWidth: Int = 0
    private(set) var videoHeight: Int = 0
    private(set) var containerMbps: Double = 0
    /// Container chapters (MKVs usually carry them) — feeds Skip Intro and
    /// the timeline tick marks, same as the FFmpeg engine's list.
    private(set) var chapters: [Chapter] = []
    /// The SOURCE's DV profile as read from its own dvcC/dvvC (0 = none) —
    /// the decision panel must report what the file is, not what the probe
    /// guessed or what the conversion outputs.
    private(set) var detectedDVProfile = 0

    /// Eligible audio tracks discovered at open, for the picker.
    struct AudioTrack { let index: Int32; let label: String; let lang: String }
    private(set) var audioTracks: [AudioTrack] = []

    struct SubtitleTrack { let index: Int32; let label: String; let isBitmap: Bool }
    private(set) var subtitleTracks: [SubtitleTrack] = []
    /// Which embedded subtitle stream to demux+decode (-1 = none). Set from
    /// the main thread via selectSubtitle; read on the demux thread.
    @Atomic private var activeSubtitleIndex: Int32 = -1
    func selectSubtitle(_ index: Int32?) { activeSubtitleIndex = index ?? -1 }
    /// One decoded subtitle event, delivered on MAIN:
    /// (start, end, text, image). text==nil && image==nil is a CLEAR marker
    /// (PGS emits explicit clears): end every part still open at `start`.
    var onSubtitleEvent: ((Double, Double, String?, UIImage?) -> Void)?
    private var subDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var subDecoderIndex: Int32 = -1
    /// Rolling raw-packet buffer for EVERY subtitle stream (demux thread
    /// only). The demuxer runs ~10s ahead of the playhead, so a track
    /// selected mid-play would otherwise stay silent until the read head's
    /// next cue. Replaying this backlog on selection makes subs immediate.
    private struct StoredSubPacket {
        let stream: Int32
        let pts: Int64
        let duration: Int64
        let ptsSeconds: Double
        let bytes: [UInt8]
    }
    private var subPacketBuffer: [StoredSubPacket] = []
    private var subStreamSet: Set<Int32> = []
    private var lastServedSubIndex: Int32 = -1

    /// Decode one stored packet by rebuilding a real AVPacket around it.
    private func replayStoredSubPacket(_ stored: StoredSubPacket, tb: AVRational) {
        guard let pkt = av_packet_alloc() else { return }
        defer { var pp: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&pp) }
        guard av_new_packet(pkt, Int32(stored.bytes.count)) >= 0 else { return }
        stored.bytes.withUnsafeBufferPointer { src in
            pkt.pointee.data.update(from: src.baseAddress!, count: src.count)
        }
        pkt.pointee.pts = stored.pts
        pkt.pointee.duration = stored.duration
        pkt.pointee.stream_index = stored.stream
        decodeSubtitlePacket(pkt, streamIndex: stored.stream, tb: tb, ptsSeconds: stored.ptsSeconds)
    }
    var currentAudioIndex: Int32 { desiredAudioIndex }

    /// Switch audio live: the demux loop starts forwarding the new stream at
    /// its next packet; the renderer is flushed so the old track doesn't
    /// finish its buffered tail first.
    func selectAudio(index: Int32) {
        guard audioFormats[index] != nil || decodeAudioIndices.contains(index) else { return }
        desiredAudioIndex = index
        queueLock.lock(); audioQueue.removeAll(); queueLock.broadcast(); queueLock.unlock()
        audioRenderer.flush()
    }

    var position: Double {
        CMTimeGetSeconds(synchronizer.currentTime())
    }

    var isPlaying: Bool { synchronizer.rate > 0 }

    // MARK: Internals

    private let inputURLString: String
    private let startAt: Double
    private let preferredAudioLanguage: String
    private let convertProfile7: Bool
    /// Addon-declared request headers (Referer/User-Agent) — sources that
    /// need them 403 a bare open.
    private let requestHeaders: [String: String]?

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var displayLayer: AVSampleBufferDisplayLayer { videoView.displayLayer }
    private let audioRenderer = AVSampleBufferAudioRenderer()

    private var videoFormat: CMFormatDescription?
    /// Passthrough format descriptions per audio stream index (E-AC3/AC3/AAC
    /// — codecs AVSampleBufferAudioRenderer decodes itself).
    private var audioFormats: [Int32: CMFormatDescription] = [:]
    /// Streams that need the FFmpeg decode→LPCM path (TrueHD, DTS, FLAC,
    /// Opus, PCM variants — anything the renderer can't take compressed).
    private var decodeAudioIndices: Set<Int32> = []
    @Atomic private var desiredAudioIndex: Int32 = -1

    // ---- FFmpeg audio decoder (worker thread only) ----
    private var audioDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var audioDecoderIndex: Int32 = -1
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    /// LPCM format cache, rebuilt when rate/channel layout changes.
    private var pcmFormat: CMFormatDescription?
    private var pcmRate: Int32 = 0
    private var pcmChannels: Int32 = 0
    private var loggedAudioDecodeFailure = false
    private var loggedFirstPCM = false

    // ---- PCM batching (worker thread) ----
    // TrueHD decodes in ~40-sample crumbs: unbatched, that is 1,200 sample
    // buffers PER SECOND at the renderer — it chokes, and the 96-deep queue
    // holds 80ms. Accumulate into ~quarter-second chunks instead.
    private var pcmBatch: [Float] = []
    private var pcmBatchStartPTS: Double = -1
    private var pcmBatchFrames = 0

    private func flushPCMBatch(into out: inout [CMSampleBuffer]) {
        guard pcmBatchFrames > 0, let format = pcmFormat, pcmChannels > 0 else {
            pcmBatch.removeAll(keepingCapacity: true); pcmBatchFrames = 0; pcmBatchStartPTS = -1
            return
        }
        if let sample = Self.makePCMSample(
            pcm: pcmBatch, format: format, frames: pcmBatchFrames,
            bytesPerFrame: Int(pcmChannels) * 4, ptsSeconds: pcmBatchStartPTS,
            rate: pcmRate
        ) { out.append(sample) }
        pcmBatch.removeAll(keepingCapacity: true)
        pcmBatchFrames = 0
        pcmBatchStartPTS = -1
    }

    /// Bounded sample queues — the "buffer that clears used stuff". The
    /// demux thread blocks when they're full; the renderers drain them.
    /// ~48 video AUs ≈ 2s at 24fps ≈ ≤40 MB at heavy-remux bitrates.
    private let queueLock = NSCondition()
    private var videoQueue: [CMSampleBuffer] = []
    private var audioQueue: [CMSampleBuffer] = []
    /// Compressed access units are cheap (~bitrate-sized, no decoded frames):
    /// 240 AUs ≈ 10s of 24fps video ≈ 40-100MB at 4K DV bitrates — the
    /// cushion that rides out debrid/HTTP throughput oscillation. The old cap
    /// of 48 (two seconds!) made every multi-second network dip an underrun,
    /// and the live probe showed exactly that: vq sawtoothing 48→0 with the
    /// clock flapping 0.22↔1.00 (the reported stop-go).
    private let videoQueueCap = 240
    private let audioQueueCap = 96

    /// MKV timestamps are in MILLISECONDS; a 23.976fps frame lasts 41.708ms.
    /// Stamped raw, every frame's PTS lands up to 0.5ms off the panel's frame
    /// grid, so the display periodically repeats one frame and skips the next
    /// — visible cadence judder with a perfectly healthy clock and full
    /// queues (the live probe proved the rest of the pipeline clean). Snap
    /// each video PTS to the exact NTSC grid, anchored at the first frame:
    /// only sub-2ms corrections are applied (rounding noise), so true-24.000
    /// or PAL material never gets re-timed, and the result is clamped to DTS
    /// so sample creation can never fail (the old jitter-chase regression).
    private var ptsGridAnchor: Double = -1   // demux-thread only

    private var gridFrameDuration: Double {
        let fps = Double(videoFPS)
        guard fps > 10 else { return 0 }
        switch fps {
        case 23.5...24.2: return 1001.0 / 24000.0
        case 29.5...30.2: return 1001.0 / 30000.0
        case 59.5...60.2: return 1001.0 / 60000.0
        default: return 1.0 / fps
        }
    }

    // PTS regularity census (demux thread): how many frames land off the
    // grid — the snap declines them silently, and irregular timestamps
    // display raggedly. The census makes a dirty-muxed file visible.
    private var ptsSeen = 0
    private var ptsIrregular = 0
    private var ptsWorstOff: Double = 0
    // Decode-cost profile per census window: AU sizes reveal complexity
    // spikes (a frame that busts the 41.7ms decode budget repeats on
    // screen with every other metric clean).
    private var auBytesWindow = 0
    private var auMaxWindow = 0

    private func snapVideoPTS(_ pts: Double, dts: Double) -> Double {
        let frameDur = gridFrameDuration
        guard frameDur > 0 else { return pts }
        if ptsGridAnchor < 0 { ptsGridAnchor = pts; return pts }
        let idx = ((pts - ptsGridAnchor) / frameDur).rounded()
        let snapped = ptsGridAnchor + idx * frameDur
        let off = abs(snapped - pts)
        ptsSeen += 1
        if off >= 0.002 {
            ptsIrregular += 1
            if off > ptsWorstOff { ptsWorstOff = off }
        }
        if ptsSeen % 480 == 0 {
            NSLog("[DVSample] pts census: %d frames, %d off-grid (worst %.1fms) | AU avg=%dKB max=%dKB",
                  ptsSeen, ptsIrregular, ptsWorstOff * 1000,
                  auBytesWindow / 480 / 1024, auMaxWindow / 1024)
            auBytesWindow = 0
            auMaxWindow = 0
        }
        guard off < 0.002 else { return pts }
        return max(snapped, dts)
    }

    // Vsync-level ground truth: a CADisplayLink at the panel's native rate
    // samples the synchronizer each refresh. Per ~10s window it reports how
    // many refreshes REPEATED a frame (media index unchanged) or SKIPPED
    // one (index advanced by 2+), plus the playback-vs-display clock ratio
    // in ppm and the queued A/V PTS skew. If the stutter is real, it must
    // appear here as repeats+skips.
    private var displayLink: CADisplayLink?
    private var dlLastIndex: Int64 = -1
    private var dlWindowStartMedia: Double = -1
    private var dlWindowStartWall: Double = -1
    private var dlTicks = 0
    private var dlRepeats = 0
    private var dlSkips = 0

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        guard synchronizer.rate > 0 else {
            dlLastIndex = -1
            dlWindowStartWall = -1
            return
        }
        let media = CMTimeGetSeconds(synchronizer.currentTime())
        let frameDur = gridFrameDuration
        guard frameDur > 0 else { return }
        let index = Int64((media / frameDur).rounded(.down))
        if dlLastIndex >= 0 {
            let advance = index - dlLastIndex
            dlTicks += 1
            if advance == 0 { dlRepeats += 1 }
            else if advance >= 2 { dlSkips += Int(advance - 1) }
        }
        dlLastIndex = index
        if dlWindowStartWall < 0 {
            dlWindowStartWall = link.timestamp
            dlWindowStartMedia = media
        }
        let wall = link.timestamp - dlWindowStartWall
        if wall >= 10 {
            let mediaAdv = media - dlWindowStartMedia
            let ppm = (mediaAdv / wall - 1) * 1_000_000
            NSLog("[DVSample] vsync probe: %d refreshes, %d repeats, %d skips, clock %+.0fppm, avSkew=%.2fs",
                  dlTicks, dlRepeats, dlSkips, ppm, lastQueuedVideoPTS - lastQueuedAudioPTS)
            dlTicks = 0; dlRepeats = 0; dlSkips = 0
            dlWindowStartWall = link.timestamp
            dlWindowStartMedia = media
        }
    }

    // Live jitter probe (diagnostic): clock ratio + queue depths every 2s.
    private var probeTick = 0
    private var lastProbeWall: CFAbsoluteTime = 0
    private var lastProbeMedia: Double = 0
    private var demuxEOF = false

    @Atomic private var cancelled = false
    /// Total stream bytes demuxed (packet payloads) — probe reads the delta
    /// to report live ingest throughput.
    @Atomic private var bytesDemuxed: Int64 = 0
    private var lastProbeBytes: Int64 = 0
    /// Seek generation: bumping it makes the demux thread restart its read
    /// loop at `pendingSeekTo` and the feeders drop stale samples.
    @Atomic private var seekGeneration = 0
    @Atomic private var pendingSeekTo: Double = -1
    /// Post-seek trim point (worker thread): video before this decodes
    /// without displaying; audio before it is dropped.
    private var trimBefore: Double = -1

    /// The open input, for the audio decoder's stream lookups (worker only).
    private var liveFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var demuxThread: Thread?
    private var timeTimer: Timer?
    private let feedQueue = DispatchQueue(label: "dv-sample-feed")

    /// Fold decoded multichannel down to stereo IN THE ENGINE. tvOS cannot
    /// bitstream TrueHD/DTS — they always decode to PCM — and on a route
    /// with no spatial support the renderer must live-downmix 8ch→2ch on
    /// every buffer, on an A10X. That real-time mixer load is the prime
    /// suspect for the crackly TrueHD sound AND the video judder (the
    /// synchronizer slaves video to the audio renderer's clock). On a
    /// stereo route this fold is what the listener would hear anyway.
    let downmixToStereo: Bool

    /// Play the HDR10 base layer only: strip every DV NAL (EL and RPU) and
    /// publish a plain HEVC format description. The FEL policy — a full
    /// enhancement layer can't ride the converted-8.1 path honestly, and its
    /// approximate per-frame metadata is the prime suspect for composer-level
    /// judder no pipeline probe can see.
    let forceHDR10: Bool

    /// Exact-label track memory ("English · AC3 · 6ch"): outranks language.
    let preferredAudioLabel: String?

    init(input: String, startAt: Double,
         preferredAudioLanguage: String, convertProfile7: Bool,
         requestHeaders: [String: String]? = nil,
         downmixToStereo: Bool = false,
         forceHDR10: Bool = false,
         preferredAudioLabel: String? = nil) {
        inputURLString = input
        self.startAt = max(startAt, 0)
        self.preferredAudioLanguage = preferredAudioLanguage
        self.convertProfile7 = convertProfile7
        self.requestHeaders = requestHeaders
        self.downmixToStereo = downmixToStereo
        self.forceHDR10 = forceHDR10
        self.preferredAudioLabel = preferredAudioLabel
    }

    // MARK: Lifecycle

    /// Open the source and start feeding. Returns false (with a reason via
    /// the completion) when the file can't ride this pipeline — the caller
    /// falls back to the remux path. Runs its blocking probe OFF the caller.
    func start(completion: @escaping (Bool, String) -> Void) {
        Self.elNalCount = 0
        Self.elNalBytes = 0
        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let failReason = self.run()
            if let failReason {
                DispatchQueue.main.async { completion(false, failReason) }
            }
        }
        thread.name = "DVSampleEngine"
        thread.qualityOfService = .userInitiated
        demuxThread = thread
        startCompletion = completion
        thread.start()
    }
    private var startCompletion: ((Bool, String) -> Void)?
    private var reportedLayerFailure = false
    private var reportedAudioFailure = false
    private var lastLayerRecoveryAt = Date.distantPast
    private var layerRecoveryCount = 0

    /// The rate the USER wants — underrun auto-pause must not overwrite a
    /// deliberate pause, and refill must not resume one.
    private var userRate: Float = 1
    private var autoPaused = false
    private var playbackClockStarted = false
    private let startupVideoPreroll = 18

    /// Cushion required before resuming from an underrun. The old flat 16
    /// (0.7s) meant each resume ran dry again within seconds on a feed
    /// that's oscillating — pause/play machine-gunning. Prefer a real
    /// runway (~5s of AUs), but TIME-BOX the hold: on a feed that refills
    /// slowly (the heavy-file case) waiting for the full cushion reads as
    /// "frozen after rewind", so after a few seconds take a 1s cushion and
    /// go. Near EOF take whatever remains so the tail still plays.
    private var autoPausedAt = Date.distantPast
    private var recentUnderruns = 0
    private var lastUnderrunAt = Date.distantPast
    /// True between a seek and its first resume: the refill after a seek is
    /// a fresh start, not a stalled feed — take a 1s cushion and go.
    private var seekRefill = false

    private func underrunResumeDepth(eof: Bool) -> Int {
        if eof { return 1 }
        if seekRefill { return 24 }
        // A one-off hiccup resumes fast (time-boxed small cushion). REPEATED
        // underruns mean the feed is genuinely slower than the movie right
        // now (a debrid link warming up) — each one demands a deeper cushion,
        // up to the full buffer, so a cold link produces one honest buffering
        // pause instead of a minute of stop-go machine-gunning.
        if recentUnderruns <= 1 {
            return Date().timeIntervalSince(autoPausedAt) > 4 ? 24 : 120
        }
        return min(24 << min(recentUnderruns, 4), 240)   // 96, 192, 240…
    }

    func play() {
        if userRate <= 0 { userRate = 1 }
        if playbackClockStarted, !autoPaused {
            synchronizer.setRate(userRate, time: synchronizer.currentTime())
        }
    }

    func pause() {
        userRate = 0
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    var rate: Float {
        get { synchronizer.rate }
        set {
            userRate = newValue
            if playbackClockStarted, !autoPaused {
                synchronizer.setRate(newValue, time: synchronizer.currentTime())
            }
        }
    }

    /// Seek: flush the renderers, point the demuxer at the target, restart
    /// the clock there. The demux thread notices the generation bump at its
    /// next loop iteration (or wakes from a full-queue wait).
    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 1 ? duration - 2 : seconds))
        pendingSeekTo = target
        seekGeneration += 1
        // A seek's refill is a fresh start, NOT a stalled feed. Without this,
        // every scan-seek emptied the queues, registered as an "underrun",
        // and stacked the escalation cushion until landing demanded a 10s
        // refill — the "doesn't load when I get there" report. Reset the
        // escalation and resume on a 1s cushion.
        recentUnderruns = 0
        lastUnderrunAt = .distantPast
        seekRefill = true
        queueLock.lock()
        videoQueue.removeAll()
        audioQueue.removeAll()
        queueLock.signal()
        queueLock.unlock()
        displayLayer.flush()
        audioRenderer.flush()
        let targetRate = playbackClockStarted && !autoPaused && userRate > 0 ? userRate : 0
        synchronizer.setRate(targetRate,
                             time: CMTime(seconds: target, preferredTimescale: 90000))
    }

    func stop() {
        cancelled = true
        queueLock.lock(); queueLock.broadcast(); queueLock.unlock()
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        displayLayer.flushAndRemoveImage()
        audioRenderer.flush()
        synchronizer.setRate(0, time: .zero)
        // Detach the renderers: the synchronizer retains them, and a video
        // renderer holds its hardware decode session (tens of MB of
        // compressed-memory decoder state) for as long as it's attached.
        synchronizer.removeRenderer(displayLayer, at: .invalid)
        synchronizer.removeRenderer(audioRenderer, at: .invalid)
        timeTimer?.invalidate()
        timeTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        // Drop the queued samples NOW. The queues held up to 240 compressed
        // AUs (~80MB at UHD-remux bitrates) and stop() never cleared them —
        // combined with the callback retain cycle below, that WAS the
        // ~80MB-per-session creep that ended in jetsam.
        queueLock.lock()
        videoQueue.removeAll()
        audioQueue.removeAll()
        queueLock.unlock()
        // Break the self-retain cycle: the VM's callbacks capture this engine
        // strongly (for their `dvDirectEngine === engine` identity checks)
        // and the engine stores those closures — engine → closure → engine
        // kept every retired engine alive forever.
        onTime = nil
        onBuffering = nil
        onEnded = nil
        onError = nil
    }

    deinit {
        NSLog("[DVSample] engine deinit")
    }

    // MARK: Demux worker

    /// Returns a failure reason for a PRE-start failure, nil once streaming.
    private func run() -> String? {
        var ictx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let inCtx = ictx else { return "alloc failed" }
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { opaque -> Int32 in
            guard let opaque else { return 0 }
            return Unmanaged<DVSampleEngine>.fromOpaque(opaque).takeUnretainedValue().cancelled ? 1 : 0
        }
        inCtx.pointee.interrupt_callback = interruptCB
        var opts: OpaquePointer?
        av_dict_set(&opts, "rw_timeout", "20000000", 0)
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "reconnect_streamed", "1", 0)
        if let headers = requestHeaders, !headers.isEmpty {
            let blob = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&opts, "headers", blob, 0)
        }
        defer { av_dict_free(&opts) }
        guard avformat_open_input(&ictx, inputURLString, nil, &opts) == 0, ictx != nil else {
            return "couldn't open source"
        }
        defer { avformat_close_input(&ictx) }
        ictx!.pointee.probesize = 2 << 20
        ictx!.pointee.max_analyze_duration = 1_000_000
        guard avformat_find_stream_info(ictx, nil) >= 0 else { return "couldn't probe source" }
        liveFormatCtx = ictx

        // ---- Stream selection ----
        var videoIndex: Int32 = -1
        var audioIndex: Int32 = -1
        var bestAudioScore = Int.min
        var dvProfile = 0
        var dvLevel = 0
        var dvCompatibilityID = 1
        var nalLengthSize = 4
        for i in 0 ..< Int(ictx!.pointee.nb_streams) {
            guard let stream = ictx!.pointee.streams[i], let par = stream.pointee.codecpar else { continue }
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO, videoIndex < 0,
               par.pointee.codec_id == AV_CODEC_ID_HEVC,
               (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 {
                videoIndex = Int32(i)
                if par.pointee.nb_coded_side_data > 0, let sideDatas = par.pointee.coded_side_data {
                    for j in 0 ..< Int(par.pointee.nb_coded_side_data) {
                        let sd = sideDatas[j]
                        if sd.type == AV_PKT_DATA_DOVI_CONF, let data = sd.data {
                            let record = data.withMemoryRebound(
                                to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
                            ) { $0 }.pointee
                            dvProfile = Int(record.dv_profile)
                            dvLevel = Int(record.dv_level)
                            dvCompatibilityID = Int(record.dv_bl_signal_compatibility_id)
                            detectedDVProfile = dvProfile
                            NSLog("[DVSample] dovi conf: profile %d.%d level %d (bl compat %d)",
                                  dvProfile, dvCompatibilityID, dvLevel, dvCompatibilityID)
                        }
                    }
                }
                if let extra = par.pointee.extradata, par.pointee.extradata_size > 22, extra[0] == 1 {
                    nalLengthSize = Int(extra[21] & 0x03) + 1
                }
                let fr = stream.pointee.avg_frame_rate
                if fr.den > 0 { videoFPS = Float(av_q2d(fr)) }
                videoWidth = Int(par.pointee.width)
                videoHeight = Int(par.pointee.height)
                containerMbps = Double(inCtx.pointee.bit_rate) / 1_000_000
                // The A/B datum the jitter hunt needs: exact rate + bitrate.
                let rfr = stream.pointee.r_frame_rate
                NSLog("[DVSample] video: %dx%d avg_fps=%d/%d (%.5f) r_fps=%d/%d container_bitrate=%.1f Mbps",
                      par.pointee.width, par.pointee.height,
                      fr.num, fr.den, fr.den > 0 ? av_q2d(fr) : 0,
                      rfr.num, rfr.den,
                      Double(inCtx.pointee.bit_rate) / 1_000_000)
            }
            if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                let id = par.pointee.codec_id
                // Passthrough for what the renderer decodes itself; the
                // FFmpeg decode→LPCM path for EVERYTHING else (TrueHD, DTS,
                // FLAC, Opus…) — every audio track is eligible now.
                let passthrough = id == AV_CODEC_ID_EAC3 || id == AV_CODEC_ID_AC3 || id == AV_CODEC_ID_AAC
                if passthrough, let format = Self.makeAudioFormat(par: par.pointee) {
                    audioFormats[Int32(i)] = format
                } else if avcodec_find_decoder(id) != nil {
                    decodeAudioIndices.insert(Int32(i))
                } else {
                    continue   // no decoder for this codec — skip the track
                }
                var lang = ""
                if let tag = av_dict_get(stream.pointee.metadata, "language", nil, 0)?.pointee.value {
                    lang = String(cString: tag)
                }
                let codecName = avcodec_get_name(id).map { String(cString: $0).uppercased() } ?? "?"
                let channels = Int(par.pointee.ch_layout.nb_channels)
                let language = Locale.current.localizedString(forLanguageCode: lang) ?? lang
                let label = [language, codecName, channels > 0 ? "\(channels)ch" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                audioTracks.append(AudioTrack(index: Int32(i), label: label.isEmpty ? "Track \(i)" : label, lang: lang))
                // RANKED default, not first-wins: remuxes routinely put a 2ch
                // commentary first, and taking it made "native" sessions open
                // on the director track. Same policy as the FFmpeg engine:
                // language match dominates, then channel count; commentary /
                // described-video tracks sink to the bottom no matter what.
                var title = ""
                if let t = av_dict_get(stream.pointee.metadata, "title", nil, 0)?.pointee.value {
                    title = String(cString: t).lowercased()
                }
                let disposition = stream.pointee.disposition
                var score = channels * 10
                if (disposition & AV_DISPOSITION_DEFAULT) != 0 { score += 5 }
                if !preferredAudioLanguage.isEmpty, lang.hasPrefix(preferredAudioLanguage) { score += 200 }
                // The user's remembered pick for THIS title wins outright.
                if let want = preferredAudioLabel, !want.isEmpty,
                   audioTracks.last?.label == want { score += 100_000 }
                if (disposition & (AV_DISPOSITION_COMMENT | AV_DISPOSITION_VISUAL_IMPAIRED
                                   | AV_DISPOSITION_HEARING_IMPAIRED)) != 0
                    || title.contains("commentary") || title.contains("description") {
                    score -= 10_000
                }
                if score > bestAudioScore {
                    bestAudioScore = score
                    audioIndex = Int32(i)
                }
            }
        }
        guard videoIndex >= 0 else { return "no HEVC video track" }
        guard audioIndex >= 0 else { return "no playable audio track" }
        // DV files must be a profile this pipeline can tag; a file with NO
        // DV config plays as plain HEVC (HDR10/HDR10+/SDR — the static and
        // dynamic metadata ride the bitstream untouched, which IS HDR10+
        // passthrough on capable boxes).
        if dvProfile > 0 {
            guard dvProfile == 5 || dvProfile == 8 || (dvProfile == 7 && convertProfile7) else {
                return "Dolby Vision profile \(dvProfile) not supported here"
            }
        }
        let needsP7 = dvProfile == 7
        if ictx!.pointee.duration > 0 {
            duration = Double(ictx!.pointee.duration) / Double(AV_TIME_BASE)
        }
        if ictx!.pointee.nb_chapters > 0, let list = ictx!.pointee.chapters {
            var found: [Chapter] = []
            for c in 0 ..< Int(ictx!.pointee.nb_chapters) {
                guard let chapter = list[c] else { continue }
                let tb = chapter.pointee.time_base
                let start = Double(chapter.pointee.start) * av_q2d(tb)
                let end = Double(chapter.pointee.end) * av_q2d(tb)
                var title = ""
                if let tag = av_dict_get(chapter.pointee.metadata, "title", nil, 0)?.pointee.value {
                    title = String(cString: tag)
                }
                found.append(Chapter(start: start, end: end, title: title))
            }
            chapters = found
        }

        // ---- Embedded subtitle tracks (second pass; text + PGS bitmap) ----
        for i in 0 ..< Int(inCtx.pointee.nb_streams) {
            guard let stream = inCtx.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let id = par.pointee.codec_id
            let textCodec = id == AV_CODEC_ID_SUBRIP || id == AV_CODEC_ID_ASS
                || id == AV_CODEC_ID_SSA || id == AV_CODEC_ID_MOV_TEXT || id == AV_CODEC_ID_TEXT
            let bitmapCodec = id == AV_CODEC_ID_HDMV_PGS_SUBTITLE || id == AV_CODEC_ID_DVD_SUBTITLE
            guard textCodec || bitmapCodec, avcodec_find_decoder(id) != nil else { continue }
            var lang = ""
            if let tag = av_dict_get(stream.pointee.metadata, "language", nil, 0)?.pointee.value {
                lang = String(cString: tag)
            }
            var title = ""
            if let tag = av_dict_get(stream.pointee.metadata, "title", nil, 0)?.pointee.value {
                title = String(cString: tag)
            }
            let language = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            let kind = bitmapCodec ? "PGS" : (avcodec_get_name(id).map { String(cString: $0).uppercased() } ?? "SUB")
            var label = [language, title, kind].filter { !$0.isEmpty }.joined(separator: " · ")
            if label.isEmpty { label = "Track \(i)" }
            if (stream.pointee.disposition & AV_DISPOSITION_FORCED) != 0 { label += " · Forced" }
            subtitleTracks.append(SubtitleTrack(index: Int32(i), label: label, isBitmap: bitmapCodec))
            subStreamSet.insert(Int32(i))
        }
        if !subtitleTracks.isEmpty {
            NSLog("[DVSample] embedded subtitles: %@",
                  subtitleTracks.map { "\($0.index):\($0.label)" }.joined(separator: ", "))
        }

        // ---- Format descriptions ----
        guard let vStream = ictx!.pointee.streams[Int(videoIndex)],
              let vPar = vStream.pointee.codecpar,
              let extra = vPar.pointee.extradata, vPar.pointee.extradata_size > 0 else {
            return "video track carries no hvcC"
        }
        let hvcC = Data(bytes: extra, count: Int(vPar.pointee.extradata_size))
        let vFormat: CMFormatDescription?
        if dvProfile > 0, !forceHDR10 {
            // The dvvC the display pipeline sees: a converted P7 declares
            // itself 8.1 single-layer (the remux path's exact contract).
            let outProfile = needsP7 ? 8 : dvProfile
            // The base-layer compatibility id comes from the FILE's own dovi
            // config, not an assumption: Profile 8 exists as 8.1 (HDR10 base)
            // AND 8.4 (HLG base) — hardcoding 1 told the display to decode
            // PQ math against HLG pixels on 8.4 files: washed, wrong colors.
            // P5 is its own IPT-PQ world (compat 0); a converted P7 emits an
            // HDR10-base 8.1 by construction.
            let compatID = outProfile == 5 ? 0 : (needsP7 ? 1 : dvCompatibilityID)
            let dvvC = Self.doviConfigurationBox(
                profile: outProfile, level: max(dvLevel, 1), compatibilityID: compatID
            )
            vFormat = Self.makeDVVideoFormat(
                width: Int32(vPar.pointee.width), height: Int32(vPar.pointee.height),
                hvcC: hvcC, dvvC: dvvC
            )
        } else {
            vFormat = Self.makeHEVCVideoFormat(
                width: Int32(vPar.pointee.width), height: Int32(vPar.pointee.height),
                hvcC: hvcC
            )
        }
        guard let vFormat else { return "couldn't build the video format description" }
        videoFormat = vFormat

        guard audioFormats[audioIndex] != nil || decodeAudioIndices.contains(audioIndex) else {
            return "no playable audio track"
        }
        desiredAudioIndex = audioIndex
        NSLog("[DVSample] audio: picked stream %d (%@ path); tracks=%@",
              audioIndex,
              decodeAudioIndices.contains(audioIndex) ? "decode" : "passthrough",
              audioTracks.map { "\($0.index):\($0.label)" }.joined(separator: ", "))

        // ---- Start position + clock ----
        if startAt > 1 {
            let ts = Int64(startAt * Double(AV_TIME_BASE))
            av_seek_frame(ictx, -1, ts, 1 /* BACKWARD */)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startCompletion?(true, "")
            self.startCompletion = nil
            self.synchronizer.setRate(0, time: CMTime(seconds: self.startAt, preferredTimescale: 90000))
            self.installFeeders()
            self.onBuffering?(true)
            let link = CADisplayLink(target: self, selector: #selector(self.displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
            self.timeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.onTime?(self.position)
                // Jitter probe: if the synchronizer's clock ratio wanders off
                // 1.000 the whole presentation timeline is breathing (both
                // renderers follow this clock); if the ratio is clean but the
                // picture stutters, the fault is per-frame (decode/enqueue).
                self.probeTick += 1
                if self.probeTick % 4 == 0 {
                    let wall = CFAbsoluteTimeGetCurrent()
                    let media = CMTimeGetSeconds(self.synchronizer.currentTime())
                    if self.lastProbeWall > 0, self.synchronizer.rate > 0 {
                        let ratio = (media - self.lastProbeMedia) / max(wall - self.lastProbeWall, 0.001)
                        self.queueLock.lock()
                        let vq = self.videoQueue.count
                        let aq = self.audioQueue.count
                        self.queueLock.unlock()
                        let nowBytes = self.bytesDemuxed
                        let feedMbps = Double(nowBytes - self.lastProbeBytes) * 8
                            / max(wall - self.lastProbeWall, 0.001) / 1_000_000
                        self.lastProbeBytes = nowBytes
                        NSLog("[DVSample] probe clock=%.4f vq=%d aq=%d vReady=%d aReady=%d rate=%.2f panel=%ldHz feed=%.1fMbps",
                              ratio, vq, aq,
                              self.displayLayer.isReadyForMoreMediaData ? 1 : 0,
                              self.audioRenderer.isReadyForMoreMediaData ? 1 : 0,
                              self.synchronizer.rate,
                              UIScreen.main.maximumFramesPerSecond,
                              feedMbps)
                    }
                    self.lastProbeWall = wall
                    self.lastProbeMedia = media
                }
                // The layer fails SILENTLY — the clock keeps running while
                // nothing renders. Ask it, and report the real reason out.
                if self.displayLayer.status == .failed {
                    // -11847 "Operation Interrupted" and friends are decode-
                    // session interruptions, not verdicts — the documented
                    // recovery is flush + re-prime from a keyframe, which is
                    // exactly what a seek to the current position does. Only
                    // repeated failures in quick succession fall back.
                    let now = Date()
                    if now.timeIntervalSince(self.lastLayerRecoveryAt) > 8,
                       self.layerRecoveryCount < 3 {
                        self.lastLayerRecoveryAt = now
                        self.layerRecoveryCount += 1
                        NSLog("[DVSample] display layer interrupted — recovering in place (attempt %d)",
                              self.layerRecoveryCount)
                        let resumeAt = self.position
                        self.displayLayer.flush()
                        self.seek(to: resumeAt)
                        self.installFeeders()
                    } else if !self.reportedLayerFailure {
                        self.reportedLayerFailure = true
                        let detail = self.displayLayer.error.map(String.init(describing:)) ?? "unknown"
                        self.onError?("display layer failed: \(detail)")
                    }
                }
                // Underrun watch: an empty video queue mid-stream means the
                // network fell behind — HOLD the clock (or audio keeps going
                // and A/V drifts across the gap) and show buffering; resume
                // when a real cushion is back. Hysteresis (enter at empty,
                // exit at 16 AUs ≈ two-thirds of a second) prevents flapping.
                self.queueLock.lock()
                let depth = self.videoQueue.count
                let aqDepth = self.audioQueue.count
                let eof = self.demuxEOF
                self.queueLock.unlock()
                if !self.playbackClockStarted {
                    if depth >= self.startupVideoPreroll || eof {
                        self.playbackClockStarted = true
                        self.autoPaused = false
                        if self.userRate > 0 {
                            self.synchronizer.setRate(self.userRate, time: self.synchronizer.currentTime())
                        }
                        self.onBuffering?(false)
                    }
                    return
                }
                if !eof {
                    // EITHER queue running dry means a hold: the vsync probe
                    // caught the audio renderer starving (aq=0 while vq>0)
                    // during feed micro-dips — its clock lurched ±1800ppm and
                    // dragged video into visible repeats/skips, because the
                    // synchronizer slaves everything to the audio clock. The
                    // old check watched only video.
                    if (depth == 0 || aqDepth == 0), !self.autoPaused, self.userRate > 0, self.synchronizer.rate > 0 {
                        self.autoPaused = true
                        self.autoPausedAt = Date()
                        if Date().timeIntervalSince(self.lastUnderrunAt) > 90 { self.recentUnderruns = 0 }
                        self.recentUnderruns += 1
                        self.lastUnderrunAt = Date()
                        NSLog("[DVSample] underrun #%d — holding clock (vq=%d aq=%d)",
                              self.recentUnderruns, depth, aqDepth)
                        self.synchronizer.setRate(0, time: self.synchronizer.currentTime())
                        self.onBuffering?(true)
                    } else if self.autoPaused, depth >= self.underrunResumeDepth(eof: eof), aqDepth >= 4 {
                        self.autoPaused = false
                        self.seekRefill = false
                        NSLog("[DVSample] underrun over — resuming with vq=%d", depth)
                        if self.userRate > 0 {
                            self.synchronizer.setRate(self.userRate, time: self.synchronizer.currentTime())
                        }
                        self.onBuffering?(false)
                    }
                }
                if self.audioRenderer.status == .failed, !self.reportedAudioFailure {
                    self.reportedAudioFailure = true
                    let detail = self.audioRenderer.error.map(String.init(describing:)) ?? "unknown"
                    NSLog("[DVSample] audio renderer failed: %@", detail)
                }
            }
        }

        // ---- Read loop ----
        let vTB = vStream.pointee.time_base
        // Audio timebase resolved per-packet (the active track can change).
        let aTB = AVRational(num: 1, den: 1000)
        guard let packet = av_packet_alloc() else { return "packet alloc failed" }
        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&pkt) }
        var myGeneration = seekGeneration

        while !cancelled {
            // A seek moved the goalposts: reposition and keep reading.
            if seekGeneration != myGeneration {
                myGeneration = seekGeneration
                let target = pendingSeekTo
                if target >= 0 {
                    let ts = Int64(target * Double(AV_TIME_BASE))
                    av_seek_frame(ictx, -1, ts, 1)
                    // Seeks land on the KEYFRAME BEFORE the target, so left
                    // alone every skip jumped back a few seconds. Trim: the
                    // lead-in video is decoded but flagged do-not-display,
                    // and lead-in audio is dropped outright, so playback
                    // resumes exactly where the viewer aimed.
                    trimBefore = target - 0.05
                    ptsGridAnchor = -1   // re-anchor the PTS grid at the seek target
                }
                if let decoder = audioDecoder { avcodec_flush_buffers(decoder) }
                if let sdec = subDecoder { avcodec_flush_buffers(sdec) }
                subPacketBuffer.removeAll(keepingCapacity: true)
                lastAudioEndPTS = -1
                pcmBatch.removeAll(keepingCapacity: true)
                pcmBatchFrames = 0
                pcmBatchStartPTS = -1
            }
            let readResult = av_read_frame(ictx, packet)
            if readResult < 0 {
                queueLock.lock(); demuxEOF = true; queueLock.broadcast(); queueLock.unlock()
                break
            }
            defer { av_packet_unref(packet) }
            let index = packet.pointee.stream_index
            let activeAudio = desiredAudioIndex
            let activeSub = activeSubtitleIndex
            // Selection changed since the last loop: serve the buffered
            // backlog so the track starts NOW, not when the read head (which
            // runs a full buffer ahead) reaches its next cue.
            if activeSub != lastServedSubIndex {
                lastServedSubIndex = activeSub
                if activeSub >= 0, let ictxL = liveFormatCtx,
                   let stream = ictxL.pointee.streams[Int(activeSub)] {
                    let stb = stream.pointee.time_base
                    for stored in subPacketBuffer where stored.stream == activeSub {
                        replayStoredSubPacket(stored, tb: stb)
                    }
                }
            }
            guard index == videoIndex || index == activeAudio || subStreamSet.contains(index) else { continue }
            guard packet.pointee.pts != Int64.min, let data = packet.pointee.data,
                  packet.pointee.size > 0 else { continue }

            let isVideo = index == videoIndex
            let tb = isVideo ? vTB
                : (ictx!.pointee.streams[Int(index)]?.pointee.time_base ?? aTB)
            let pts = Double(packet.pointee.pts) * av_q2d(tb)
            let dts = packet.pointee.dts != Int64.min
                ? Double(packet.pointee.dts) * av_q2d(tb) : pts
            let dur = packet.pointee.duration > 0
                ? Double(packet.pointee.duration) * av_q2d(tb) : 0

            bytesDemuxed += Int64(packet.pointee.size)
            if isVideo {
                auBytesWindow += Int(packet.pointee.size)
                auMaxWindow = max(auMaxWindow, Int(packet.pointee.size))
            }
            var bytes = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            if isVideo, forceHDR10, dvProfile > 0 {
                if let stripped = Self.stripDVAccessUnit(bytes, nalLengthSize: nalLengthSize) {
                    if stripped.isEmpty { continue }   // pure-DV packet: drop
                    bytes = stripped
                }
            } else if isVideo, needsP7 {
                if let converted = Self.convertP7AccessUnit(bytes, nalLengthSize: nalLengthSize) {
                    if converted.isEmpty { continue }   // pure-EL packet: drop
                    bytes = converted
                }
            }
            // Post-seek trim (see the seek branch above).
            if trimBefore > 0 {
                if !isVideo, pts < trimBefore { continue }
                if isVideo, pts >= trimBefore { trimBefore = -1 }
            }
            let displaySuppressed = isVideo && trimBefore > 0 && pts < trimBefore

            if !isVideo, subStreamSet.contains(index) {
                subPacketBuffer.append(StoredSubPacket(
                    stream: index,
                    pts: packet.pointee.pts,
                    duration: packet.pointee.duration,
                    ptsSeconds: pts,
                    bytes: [UInt8](UnsafeBufferPointer(start: packet.pointee.data,
                                                       count: Int(packet.pointee.size)))
                ))
                // Bound the backlog: keep ~90s of events (subtitle packets are
                // tiny; even 20 PGS tracks stay a few MB).
                if subPacketBuffer.count > 800 {
                    subPacketBuffer.removeFirst(subPacketBuffer.count - 800)
                }
                let cutoff = pts - 90
                if let first = subPacketBuffer.first, first.ptsSeconds < cutoff - 30 {
                    subPacketBuffer.removeAll { $0.ptsSeconds < cutoff }
                }
                if index == activeSub {
                    decodeSubtitlePacket(packet, streamIndex: index, tb: tb, ptsSeconds: pts)
                }
                continue
            }
            // Non-passthrough audio: FFmpeg-decode to interleaved Float32 PCM
            // and enqueue the LPCM samples — this is what makes TrueHD, DTS,
            // FLAC and friends playable on this engine.
            if !isVideo, decodeAudioIndices.contains(index) {
                for pcm in decodeAudioPacket(packet, streamIndex: index, tb: tb) {
                    enqueueBounded(pcm, isVideo: false, generation: myGeneration)
                }
                continue
            }
            // Duration rides the same grid as the PTS: the container's
            // ms-rounded 41/42ms durations feed straight into the display
            // layer's scheduling; hand it the exact cadence instead.
            var sampleDur = dur
            if isVideo {
                let frameDur = gridFrameDuration
                if frameDur > 0, abs(dur - frameDur) < 0.002 { sampleDur = frameDur }
            }
            guard let sample = Self.makeSample(
                bytes: bytes,
                format: isVideo ? vFormat : audioFormats[index],
                ptsSeconds: isVideo ? snapVideoPTS(pts, dts: dts) : pts,
                dtsSeconds: dts, durationSeconds: sampleDur,
                keyframe: (packet.pointee.flags & 0x0001) != 0
            ) else { continue }
            if displaySuppressed { Self.markDoNotDisplay(sample) }

            enqueueBounded(sample, isVideo: isVideo, generation: myGeneration)
        }
        closeAudioDecoder()
        if subDecoder != nil { avcodec_free_context(&subDecoder) }
        subDecoderIndex = -1
        return nil
    }

    /// Bounded enqueue — blocks (self-clearing buffer) until the renderers
    /// have consumed room, a seek clears the queues, or stop.
    // Audio PTS continuity census: the synchronizer slaves VIDEO to the
    // AUDIO renderer's clock, so a gap or overlap in audio timestamps makes
    // the whole presentation lurch — visible stutter with every other probe
    // clean. Expected next PTS = last PTS + last duration; any mismatch
    // beyond 2ms is counted and the worst offender kept.
    private var lastAudioEndPTS: Double = -1
    private var audioPTSSeen = 0
    private var audioPTSGaps = 0
    private var audioPTSWorstGap: Double = 0
    private var lastQueuedVideoPTS: Double = 0
    private var lastQueuedAudioPTS: Double = 0

    private func censusAudioPTS(_ sample: CMSampleBuffer) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let dur = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        lastQueuedAudioPTS = pts
        if lastAudioEndPTS >= 0 {
            let gap = pts - lastAudioEndPTS
            audioPTSSeen += 1
            if abs(gap) > 0.002 {
                audioPTSGaps += 1
                if abs(gap) > abs(audioPTSWorstGap) { audioPTSWorstGap = gap }
            }
            if audioPTSSeen % 120 == 0 {   // ~30s of quarter-second batches
                NSLog("[DVSample] audio pts census: %d buffers, %d discontinuities (worst %+.1fms)",
                      audioPTSSeen, audioPTSGaps, audioPTSWorstGap * 1000)
            }
        }
        lastAudioEndPTS = dur.isFinite && dur > 0 ? pts + dur : pts
    }

    private func enqueueBounded(_ sample: CMSampleBuffer, isVideo: Bool, generation: Int) {
        if isVideo {
            lastQueuedVideoPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        } else {
            censusAudioPTS(sample)
        }
        queueLock.lock()
        while !cancelled, seekGeneration == generation,
              (isVideo ? videoQueue.count >= videoQueueCap
                       : audioQueue.count >= audioQueueCap) {
            queueLock.wait(until: Date().addingTimeInterval(0.25))
        }
        if !cancelled, seekGeneration == generation {
            if isVideo { videoQueue.append(sample) } else { audioQueue.append(sample) }
            queueLock.broadcast()
        }
        queueLock.unlock()
    }

    // MARK: FFmpeg subtitle decode (text + PGS bitmap)

    /// Worker thread only. Lazily (re)opens the decoder when the active
    /// stream changes, decodes one packet, and posts the resulting cue (or
    /// clear marker) to main via onSubtitleEvent.
    private func decodeSubtitlePacket(
        _ packet: UnsafeMutablePointer<AVPacket>, streamIndex: Int32, tb: AVRational,
        ptsSeconds: Double
    ) {
        if subDecoderIndex != streamIndex {
            if subDecoder != nil { avcodec_free_context(&subDecoder) }
            subDecoderIndex = -1
            guard let ictxLocal = liveFormatCtx,
                  let stream = ictxLocal.pointee.streams[Int(streamIndex)],
                  let par = stream.pointee.codecpar,
                  let codec = avcodec_find_decoder(par.pointee.codec_id),
                  let ctx = avcodec_alloc_context3(codec) else { return }
            avcodec_parameters_to_context(ctx, par)
            guard avcodec_open2(ctx, codec, nil) >= 0 else {
                var dead: UnsafeMutablePointer<AVCodecContext>? = ctx
                avcodec_free_context(&dead)
                return
            }
            subDecoder = ctx
            subDecoderIndex = streamIndex
            NSLog("[DVSample] subtitle decoder opened for stream %d (%@)",
                  streamIndex,
                  avcodec_get_name(ctx.pointee.codec_id).map { String(cString: $0) } ?? "?")
        }
        guard let decoder = subDecoder else { return }
        var sub = AVSubtitle()
        var got: Int32 = 0
        let rc = avcodec_decode_subtitle2(decoder, &sub, &got, packet)
        guard rc >= 0, got != 0 else { return }
        defer { avsubtitle_free(&sub) }
        var start = ptsSeconds + Double(sub.start_display_time) / 1000
        // PGS timestamps ride the AVSubtitle itself in AV_TIME_BASE.
        if sub.pts != Int64.min {
            start = Double(sub.pts) / Double(AV_TIME_BASE) + Double(sub.start_display_time) / 1000
        }
        var end = start + 6   // open-ended default; a later cue/clear truncates
        if sub.end_display_time > sub.start_display_time, sub.end_display_time != UInt32.max {
            end = start + Double(sub.end_display_time - sub.start_display_time) / 1000
        } else if packet.pointee.duration > 0 {
            end = start + Double(packet.pointee.duration) * av_q2d(tb)
        }
        guard start >= 0 else { return }
        if sub.num_rects == 0 {   // explicit clear (PGS)
            DispatchQueue.main.async { [weak self] in self?.onSubtitleEvent?(start, start, nil, nil) }
            return
        }
        var texts: [String] = []
        var image: UIImage?
        for i in 0 ..< Int(sub.num_rects) {
            guard let rect = sub.rects[i]?.pointee else { continue }
            switch rect.type {
            case SUBTITLE_ASS:
                if let ass = rect.ass {
                    let line = Self.assEventText(String(cString: ass))
                    if !line.isEmpty { texts.append(line) }
                }
            case SUBTITLE_TEXT:
                if let t = rect.text {
                    let line = String(cString: t).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { texts.append(line) }
                }
            case SUBTITLE_BITMAP:
                if image == nil { image = Self.imageFromSubtitleRect(rect) }
            default:
                break
            }
        }
        let text = texts.isEmpty ? nil : texts.joined(separator: "\n")
        guard text != nil || image != nil else { return }
        let img = image
        DispatchQueue.main.async { [weak self] in self?.onSubtitleEvent?(start, end, text, img) }
    }

    /// FFmpeg's decoded ASS event: "ReadOrder,Layer,Style,Name,MarginL,
    /// MarginR,MarginV,Effect,Text" — the dialogue text is everything after
    /// the 8th comma, with override tags stripped and \N line breaks kept.
    private static func assEventText(_ event: String) -> String {
        var text = event
        var commas = 0
        if let idx = text.indices.first(where: { i in
            if text[i] == "," { commas += 1 }
            return commas == 8
        }) {
            text = String(text[text.index(after: idx)...])
        }
        // Strip {\...} override blocks.
        while let open = text.firstIndex(of: "{"), let close = text[open...].firstIndex(of: "}") {
            text.removeSubrange(open ... close)
        }
        return text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PAL8 bitmap rect (PGS/DVD) → RGBA UIImage.
    private static func imageFromSubtitleRect(_ rect: AVSubtitleRect) -> UIImage? {
        let w = Int(rect.w), h = Int(rect.h)
        guard w > 0, h > 0,
              let indices = rect.data.0,
              let paletteBytes = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        let palette = paletteBytes.withMemoryRebound(to: UInt32.self, capacity: 256) { pal in
            (0 ..< 256).map { pal[$0] }
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                // FFmpeg subtitle palettes are 0xAARRGGBB.
                let entry = palette[Int(indices[y * stride + x])]
                let o = (y * w + x) * 4
                rgba[o] = UInt8((entry >> 16) & 0xFF)
                rgba[o + 1] = UInt8((entry >> 8) & 0xFF)
                rgba[o + 2] = UInt8(entry & 0xFF)
                rgba[o + 3] = UInt8((entry >> 24) & 0xFF)
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: FFmpeg audio decode → LPCM

    private func closeAudioDecoder() {
        pcmBatch.removeAll(keepingCapacity: true)
        pcmBatchFrames = 0
        pcmBatchStartPTS = -1
        if audioDecoder != nil { avcodec_free_context(&audioDecoder) }
        if decodedFrame != nil { av_frame_free(&decodedFrame) }
        audioDecoderIndex = -1
    }

    /// Decode one compressed packet into zero or more LPCM sample buffers.
    /// Worker thread only. The decoder is (re)built when the active stream
    /// changes; a seek flushes it via `flushAudioDecoderOnSeek`.
    private func decodeAudioPacket(
        _ packet: UnsafeMutablePointer<AVPacket>, streamIndex: Int32, tb: AVRational
    ) -> [CMSampleBuffer] {
        if audioDecoderIndex != streamIndex {
            closeAudioDecoder()
            guard let ictxLocal = liveFormatCtx,
                  let stream = ictxLocal.pointee.streams[Int(streamIndex)],
                  let par = stream.pointee.codecpar,
                  let codec = avcodec_find_decoder(par.pointee.codec_id),
                  let ctx = avcodec_alloc_context3(codec) else { return [] }
            avcodec_parameters_to_context(ctx, par)
            guard avcodec_open2(ctx, codec, nil) >= 0 else {
                var dead: UnsafeMutablePointer<AVCodecContext>? = ctx
                avcodec_free_context(&dead)
                return []
            }
            audioDecoder = ctx
            audioDecoderIndex = streamIndex
            decodedFrame = av_frame_alloc()
            NSLog("[DVSample] audio decoder opened for stream %d (%@)",
                  streamIndex,
                  avcodec_get_name(ctx.pointee.codec_id).map { String(cString: $0) } ?? "?")
        }
        guard let decoder = audioDecoder, let frame = decodedFrame else { return [] }
        let sendResult = avcodec_send_packet(decoder, packet)
        guard sendResult >= 0 else {
            if !loggedAudioDecodeFailure {
                loggedAudioDecodeFailure = true
                NSLog("[DVSample] audio decode send failed (%d) for stream %d", sendResult, streamIndex)
            }
            return []
        }

        var out: [CMSampleBuffer] = []
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            let channels = Int(frame.pointee.ch_layout.nb_channels)
            let samples = Int(frame.pointee.nb_samples)
            let rate = frame.pointee.sample_rate
            guard channels > 0, samples > 0, rate > 0 else { continue }
            guard var pcm = Self.interleaveToFloat32(frame: frame.pointee,
                                                    channels: channels, samples: samples)
            else {
                if !loggedAudioDecodeFailure {
                    loggedAudioDecodeFailure = true
                    NSLog("[DVSample] PCM interleave failed: fmt=%d ch=%d", frame.pointee.format, channels)
                }
                continue
            }
            if !loggedFirstPCM {
                loggedFirstPCM = true
                NSLog("[DVSample] first PCM out: %dch %dHz %d samples fmt=%d",
                      channels, rate, samples, frame.pointee.format)
            }
            var outChannels = channels
            if downmixToStereo, channels > 2 {
                pcm = Self.downmix(pcm, channels: channels, samples: samples)
                outChannels = 2
            }
            if pcmFormat == nil || pcmRate != rate || pcmChannels != Int32(outChannels) {
                pcmFormat = Self.makeLPCMFormat(rate: rate, channels: Int32(outChannels))
                pcmRate = rate
                pcmChannels = Int32(outChannels)
            }
            guard pcmFormat != nil else { continue }
            let pts = frame.pointee.pts != Int64.min
                ? Double(frame.pointee.pts) * av_q2d(tb)
                : Double(packet.pointee.pts) * av_q2d(tb)
            if pcmBatchStartPTS < 0 { pcmBatchStartPTS = pts }
            pcmBatch.append(contentsOf: pcm)
            pcmBatchFrames += samples
            // ~a quarter second per buffer: 4 buffers/s instead of 1,200.
            if pcmBatchFrames >= Int(rate) / 4 {
                flushPCMBatch(into: &out)
            }
        }
        return out
    }

    /// ITU-style stereo fold for FFmpeg's native channel order
    /// (FL FR FC LFE BL BR [SL SR]): center/surrounds at -3 dB, LFE -6 dB,
    /// the sum scaled to keep peaks out of clipping.
    private static func downmix(_ pcm: [Float], channels: Int, samples: Int) -> [Float] {
        var out = [Float](repeating: 0, count: samples * 2)
        let c: Float = 0.7071
        for i in 0 ..< samples {
            let base = i * channels
            var left = pcm[base]
            var right = pcm[base + 1]
            if channels > 2 { left += c * pcm[base + 2]; right += c * pcm[base + 2] }        // FC
            if channels > 3 { left += 0.5 * pcm[base + 3]; right += 0.5 * pcm[base + 3] }    // LFE
            if channels > 5 { left += c * pcm[base + 4]; right += c * pcm[base + 5] }        // BL/BR
            if channels > 7 { left += c * pcm[base + 6]; right += c * pcm[base + 7] }        // SL/SR
            out[i * 2] = left * 0.5
            out[i * 2 + 1] = right * 0.5
        }
        return out
    }

    /// Any planar/packed float or integer layout → packed interleaved Float32.
    private static func interleaveToFloat32(
        frame: AVFrame, channels: Int, samples: Int
    ) -> [Float]? {
        var out = [Float](repeating: 0, count: channels * samples)
        let fmt = AVSampleFormat(rawValue: frame.format)
        func planar<T>(_: T.Type, _ convert: (T) -> Float) -> Bool {
            var data = frame.data
            return withUnsafeBytes(of: &data) { raw -> Bool in
                let planes = raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)
                for ch in 0 ..< channels {
                    guard ch < 8, let plane = planes[ch] else { return false }
                    let typed = UnsafeRawPointer(plane).bindMemory(to: T.self, capacity: samples)
                    for i in 0 ..< samples { out[i * channels + ch] = convert(typed[i]) }
                }
                return true
            }
        }
        func packed<T>(_: T.Type, _ convert: (T) -> Float) -> Bool {
            guard let base = frame.data.0 else { return false }
            let typed = UnsafeRawPointer(base).bindMemory(to: T.self, capacity: channels * samples)
            for i in 0 ..< channels * samples { out[i] = convert(typed[i]) }
            return true
        }
        let ok: Bool
        switch fmt {
        case AV_SAMPLE_FMT_FLTP: ok = planar(Float.self) { $0 }
        case AV_SAMPLE_FMT_FLT: ok = packed(Float.self) { $0 }
        case AV_SAMPLE_FMT_S16P: ok = planar(Int16.self) { Float($0) / 32768 }
        case AV_SAMPLE_FMT_S16: ok = packed(Int16.self) { Float($0) / 32768 }
        case AV_SAMPLE_FMT_S32P: ok = planar(Int32.self) { Float($0) / 2147483648 }
        case AV_SAMPLE_FMT_S32: ok = packed(Int32.self) { Float($0) / 2147483648 }
        case AV_SAMPLE_FMT_DBLP: ok = planar(Double.self) { Float($0) }
        case AV_SAMPLE_FMT_DBL: ok = packed(Double.self) { Float($0) }
        default: ok = false
        }
        return ok ? out : nil
    }

    private static func makeLPCMFormat(rate: Int32, channels: Int32) -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Multichannel LPCM is SILENT without a channel layout — the ASBD
        // alone doesn't tell the renderer what the channels mean. This was
        // "TrueHD doesn't work": stereo decode paths played (2ch needs no
        // layout in practice) while every 5.1/7.1 lossless track sat mute.
        // Tags follow FFmpeg's native channel order closely enough; exotic
        // counts fall back to discrete-in-order, which always plays.
        var layout = AudioChannelLayout()
        switch channels {
        case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        case 3: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_3_0_A
        case 4: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Quadraphonic
        case 5: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_0_A
        case 6: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        case 7: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_6_1_A
        case 8: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_C
        default:
            layout.mChannelLayoutTag =
                kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
        var format: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private static func makePCMSample(
        pcm: [Float], format: CMFormatDescription, frames: Int,
        bytesPerFrame: Int, ptsSeconds: Double, rate: Int32
    ) -> CMSampleBuffer? {
        let byteCount = pcm.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        guard pcm.withUnsafeBytes({ raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    // MARK: Feeders

    private func installFeeders() {
        displayLayer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            self?.feed(video: true)
        }
        audioRenderer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            self?.feed(video: false)
        }
    }

    private func feed(video: Bool) {
        while !cancelled,
              video ? displayLayer.isReadyForMoreMediaData
                    : audioRenderer.isReadyForMoreMediaData {
            queueLock.lock()
            let sample: CMSampleBuffer?
            if video {
                sample = videoQueue.isEmpty ? nil : videoQueue.removeFirst()
            } else {
                sample = audioQueue.isEmpty ? nil : audioQueue.removeFirst()
            }
            let ended = demuxEOF && videoQueue.isEmpty && audioQueue.isEmpty
            queueLock.broadcast()
            queueLock.unlock()
            guard let sample else {
                if ended { DispatchQueue.main.async { [weak self] in self?.onEnded?() } }
                return
            }
            if video { displayLayer.enqueue(sample) } else { audioRenderer.enqueue(sample) }
        }
    }

    // MARK: Sample construction

    private static func makeSample(
        bytes: [UInt8], format: CMFormatDescription?,
        ptsSeconds: Double, dtsSeconds: Double, durationSeconds: Double, keyframe: Bool
    ) -> CMSampleBuffer? {
        guard let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        guard bytes.withUnsafeBytes({ raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count
            )
        }) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: durationSeconds > 0
                ? CMTime(seconds: durationSeconds, preferredTimescale: 90000) : .invalid,
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 90000),
            decodeTimeStamp: CMTime(seconds: dtsSeconds, preferredTimescale: 90000)
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if !keyframe, CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    /// DV format description: HEVC dimensions + hvcC, tagged 'dvh1' with the
    /// dvvC atom so VideoToolbox and the display pipeline treat the stream as
    /// Dolby Vision rather than plain HEVC.
    private static func makeDVVideoFormat(
        width: Int32, height: Int32, hvcC: Data, dvvC: Data
    ) -> CMFormatDescription? {
        let atoms: [String: Any] = ["hvcC": hvcC, "dvvC": dvvC]
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms
        ]
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_DolbyVisionHEVC,
            width: width, height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    /// Decode-but-don't-display, for post-seek lead-in frames.
    private static func markDoNotDisplay(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [CFMutableDictionary], let first = attachments.first else { return }
        CFDictionarySetValue(
            first,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// Plain HEVC (HDR10/HDR10+/SDR): hvc1 + hvcC, nothing else — every SEI
    /// in the bitstream (static mastering metadata, HDR10+ dynamic metadata)
    /// reaches the display pipeline untouched.
    private static func makeHEVCVideoFormat(
        width: Int32, height: Int32, hvcC: Data
    ) -> CMFormatDescription? {
        let atoms: [String: Any] = ["hvcC": hvcC]
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms
        ]
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: width, height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    /// The 24-byte dv decoder configuration record (ISO/IEC layout) —
    /// version 1.0, single layer, RPU+BL present.
    private static func doviConfigurationBox(
        profile: Int, level: Int, compatibilityID: Int
    ) -> Data {
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 1   // version major
        b[1] = 0   // version minor
        b[2] = UInt8((profile << 1) | ((level >> 5) & 0x01))
        b[3] = UInt8(((level & 0x1F) << 3) | (1 << 2) /* rpu */ | (0 << 1) /* el */ | 1 /* bl */)
        b[4] = UInt8((compatibilityID & 0x0F) << 4)
        return Data(b)
    }

    private static func makeAudioFormat(par: AVCodecParameters) -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription()
        switch par.codec_id {
        case AV_CODEC_ID_EAC3: asbd.mFormatID = kAudioFormatEnhancedAC3
        case AV_CODEC_ID_AC3: asbd.mFormatID = kAudioFormatAC3
        case AV_CODEC_ID_AAC: asbd.mFormatID = kAudioFormatMPEG4AAC
        default: return nil
        }
        asbd.mSampleRate = Float64(par.sample_rate)
        asbd.mChannelsPerFrame = UInt32(max(par.ch_layout.nb_channels, 2))
        asbd.mFramesPerPacket = par.codec_id == AV_CODEC_ID_AAC ? 1024 : 1536
        var format: CMFormatDescription?
        // AAC cannot decode without its AudioSpecificConfig — the codec
        // extradata IS that cookie. AC3/E-AC3 are self-describing.
        var cookie: UnsafeRawPointer?
        var cookieSize = 0
        if par.codec_id == AV_CODEC_ID_AAC, let extra = par.extradata, par.extradata_size > 0 {
            cookie = UnsafeRawPointer(extra)
            cookieSize = Int(par.extradata_size)
        }
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: cookieSize, magicCookie: cookie,
            extensions: nil, formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    // MARK: P7 → 8.1 access-unit conversion

    /// Walk length-prefixed NALs: drop EL carriage (type 63), convert RPUs
    /// (type 62) via libdovi. Returns nil to keep the original packet, an
    /// empty array when the whole AU was enhancement layer.
    nonisolated(unsafe) private static var rpuConversionFailures = 0
    nonisolated(unsafe) private static var elNalCount = 0
    nonisolated(unsafe) private static var elNalBytes = 0
    /// Fired once (on main) when the P7 layer type is measured — surfaces
    /// FEL/MEL in the player's decision panel. Single active DV engine at a
    /// time, so static state is safe; counters reset per engine start.
    nonisolated(unsafe) static var onELVerdict: ((String) -> Void)?

    /// forceHDR10: drop every DV NAL (EL type 63 and RPU type 62), keep the
    /// plain HEVC base layer untouched.
    private static func stripDVAccessUnit(_ au: [UInt8], nalLengthSize: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(au.count)
        var i = 0
        var changed = false
        var kept = 0
        while i + nalLengthSize <= au.count {
            var len = 0
            for k in 0 ..< nalLengthSize { len = (len << 8) | Int(au[i + k]) }
            let start = i + nalLengthSize
            guard len > 0, start + len <= au.count else { return nil }
            let nalType = (au[start] >> 1) & 0x3F
            if nalType == 63 || nalType == 62 {
                changed = true
            } else {
                appendPrefixed(&out, Array(au[start ..< start + len]), nalLengthSize)
                kept += 1
            }
            i = start + len
        }
        if kept == 0 { return [] }
        return changed ? out : nil
    }

    private static func convertP7AccessUnit(_ au: [UInt8], nalLengthSize: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(au.count)
        var i = 0
        var changed = false
        var kept = 0
        while i + nalLengthSize <= au.count {
            var len = 0
            for k in 0 ..< nalLengthSize { len = (len << 8) | Int(au[i + k]) }
            let start = i + nalLengthSize
            guard len > 0, start + len <= au.count else { return nil }
            let nalType = (au[start] >> 1) & 0x3F
            let nal = Array(au[start ..< start + len])
            if nalType == 63 {
                changed = true   // EL: drop
                // FEL-vs-MEL diagnosis: MEL enhancement layers are ~100-byte
                // shells (lossless to drop); FEL ELs are a real 12-bit
                // residual stream, and converted-8.1 metadata over a dropped
                // FEL is an approximation the composer may stumble on.
                elNalCount += 1
                elNalBytes += len
                if elNalCount == 240 {
                    let avg = elNalBytes / elNalCount
                    let fel = avg > 1000
                    NSLog("[DVSample] P7 enhancement layer: avg %d bytes/NAL over %d NALs — %@",
                          avg, elNalCount, fel ? "FEL (full residual layer)" : "MEL (empty shell)")
                    let verdict = fel
                        ? "FEL — full enhancement layer (dropped; converted 8.1 metadata is approximate)"
                        : "MEL — minimal enhancement layer (lossless 8.1 conversion)"
                    DispatchQueue.main.async { onELVerdict?(verdict) }
                }
            } else if nalType == 62 {
                if let converted = DoviConverter.convertRPU7to81(Data(nal)) {
                    appendPrefixed(&out, [UInt8](converted), nalLengthSize)
                    kept += 1
                } else {
                    // NEVER let a raw P7 RPU into the 8.1-tagged stream: it
                    // references the enhancement layer we just deleted, and
                    // the DV composer glitching on it per affected frame is
                    // visible stutter no pipeline probe can see. A frame
                    // with no DV metadata is benign; corrupt metadata isn't.
                    rpuConversionFailures += 1
                    if rpuConversionFailures == 1 || rpuConversionFailures % 100 == 0 {
                        NSLog("[DVSample] P7 RPU conversion failed (%d so far) — dropping the frame's RPU",
                              rpuConversionFailures)
                    }
                }
                changed = true
            } else {
                appendPrefixed(&out, nal, nalLengthSize)
                kept += 1
            }
            i = start + len
        }
        if kept == 0 { return [] }
        return changed ? out : nil
    }

    private static func appendPrefixed(_ out: inout [UInt8], _ nal: [UInt8], _ lengthSize: Int) {
        let len = nal.count
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((len >> shift) & 0xFF))
        }
        out.append(contentsOf: nal)
    }
}

/// UIView whose backing layer IS the sample display layer, so the video
/// scales with the view like every other engine's output.
final class DVSampleLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("unavailable") }
}
