import Foundation
import KSPlayer
import Libavcodec
import Libavformat
import Libavutil

/// Captures FFmpeg's own error lines so a failed remux can say WHY.
///
/// "mux header failed (-22)" is FFmpeg for "something was invalid" — the real
/// reason ("Could not find tag for codec X in stream #N", "dimensions not
/// set"…) only exists as an av_log line. KSPlayer installs a global callback
/// that swallows those into its own logger, so this replaces it with a chained
/// version: errors are kept in a small ring (and NSLog'd).
///
/// KNOWN TRADE: KSPlayer's callback also fed avfilter lines into
/// options.filter(log:) for idet deinterlace detection. That plumbing is NOT
/// replicated — the avfilter headers aren't exposed to this target — and it
/// is safe to drop here because nothing in this app enables autoDeInterlace
/// or a video filter chain. If either is ever turned on, this capture must
/// grow the avfilter branch back.
enum FFmpegLogCapture {
    nonisolated(unsafe) private static var ring: [String] = []
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        av_log_set_callback { ptr, level, format, args in
            guard let format else { return }
            var line = String(cString: format)
            if let args { line = NSString(format: line, arguments: args) as String }
            guard level <= AV_LOG_ERROR else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            FFmpegLogCapture.append(trimmed)
        }
    }

    private static func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        ring.append(line)
        if ring.count > 8 { ring.removeFirst(ring.count - 8) }
        NSLog("[FFmpegError] %@", line)
    }

    /// The most recent error lines, newest last. Cleared on read.
    static func drainRecent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = ring
        ring = []
        return out
    }
}

/// On-device Dolby Vision remux server.
///
/// tvOS only outputs true (dynamic-metadata) Dolby Vision when a DV-tagged
/// compressed stream reaches Apple's own video pipeline — anything FFmpeg
/// decodes to pixels has already lost the RPU. So for a DV file this class
/// remuxes (stream copy, no re-encode) the source's HEVC+audio into a LOCAL
/// fMP4 HLS event playlist that AVPlayer plays natively:
///
///   http(s) MKV ──libavformat──▶ mp4 muxer (fragmented, DV-tagged)
///        │                          │ custom AVIO write callback
///        ▼                          ▼
///   packets (copied)       top-level box splitter
///                          ftyp+moov → init.mp4
///                          each moof+mdat → segNNNNN.m4s
///                          hand-written dv.m3u8 (EVENT, EXT-X-MAP)
///
/// This build's FFmpeg has no `hls` muxer, hence the manual splitter — the
/// mp4 muxer in `frag_keyframe+empty_moov+default_base_moof` mode emits
/// exactly the boxes fMP4 HLS needs, and movenc writes the `dvcC`/`dvvC`
/// configuration box from the stream's DOVI side data (verified present in
/// the shipped Libavformat).
///
/// Eligibility (checked on open): HEVC video with DOVI config, profile 5 or 8
/// (Apple never accepts profile 7), and at least one AVPlayer-compatible
/// audio track (E-AC3 / AC3 / AAC — TrueHD/DTS can't ride HLS). Anything else
/// reports `onIneligible` and the caller stays on the FFmpeg engine.
///
/// All callbacks are delivered on the main queue.
final class DVRemuxer {
    // MARK: Public surface

    /// Fires once the playlist is playable (a few segments written, or the
    /// whole file finished early). `actualStart` = the absolute source time
    /// (seconds) that playlist t=0 corresponds to.
    var onReady: ((URL, Double) -> Void)?
    /// Seconds of content (relative to actualStart) written so far.
    var onProgress: ((Double) -> Void)?
    /// The whole file has been remuxed; playlist got EXT-X-ENDLIST.
    var onFinished: (() -> Void)?
    /// The source can't take this path (wrong profile / no compatible audio).
    var onIneligible: ((String) -> Void)?
    /// Hard failure mid-flight.
    var onError: ((String) -> Void)?

    let directory: URL
    private let inputURLString: String
    private let startAtSeconds: Double
    private let preferredAudioLanguage: String
    /// Convert Profile 7 (dual-layer) → 8.1 via libdovi so DV7 also gets
    /// native output. Off = P7 is ineligible and falls back to HDR10.
    private let convertProfile7: Bool
    /// Worker-thread QoS (set before start()). A lower QoS lets tvOS shed the
    /// conversion under UI pressure instead of starving the main thread.
    var qos: QualityOfService = .userInitiated
    /// Cap processing at this multiple of realtime once past `paceLeadSeconds`
    /// (0 = unbounded). Bounds the download/decode burst on constrained boxes.
    var paceSpeedFactor: Double = 0
    /// Seconds of content the worker may get ahead before pacing engages.
    var paceLeadSeconds: Double = 0
    /// Wall-clock anchor, captured when the first content packet is seen.
    private var paceStartWall: Date?

    init(input: String, startAt: Double, preferredAudioLanguage: String = "",
         convertProfile7: Bool = false) {
        inputURLString = input
        startAtSeconds = max(startAt, 0)
        self.preferredAudioLanguage = preferredAudioLanguage
        self.convertProfile7 = convertProfile7
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-remux-\(UUID().uuidString)", isDirectory: true)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "DVRemuxer"
        thread.qualityOfService = qos
        thread.start()
    }

    /// Thread-safe: flips the flag the AVIO interrupt callback polls, so even
    /// a blocked network read bails out promptly.
    func cancel() {
        cancelled = true
    }

    /// Remove the segment directory (call after the player has moved off it).
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: State (remux thread unless noted)

    @Atomic private var cancelled = false
    private var readySignalled = false
    private var finished = false

    // Timeline bookkeeping (seconds, source timeline)
    private var firstWrittenPTS: Double = .nan
    private var lastVideoPTS: Double = 0
    /// Video keyframe times relative to firstWrittenPTS — fragment boundaries
    /// (frag_keyframe = one fragment per GOP), used for exact EXTINF values.
    private var keyframes: [Double] = []

    // Playlist bookkeeping
    private var segmentDurations: [Double] = []
    private var playlistURL: URL { directory.appendingPathComponent("dv.m3u8") }

    // Box splitter state
    private var pendingBytes = Data()
    private var initPhase = true
    private var initData = Data()
    private var segmentData = Data()
    private var segmentOpen = false
    private var segmentIndex = 0

    // MARK: - Remux thread

    private func run() {
        FFmpegLogCapture.install()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            report { self.onError?("Couldn't create segment directory") }
            return
        }

        var ictx: UnsafeMutablePointer<AVFormatContext>?
        var octx: UnsafeMutablePointer<AVFormatContext>?
        var avioCtx: UnsafeMutablePointer<AVIOContext>?
        defer {
            if octx != nil {
                if let pb = octx?.pointee.pb { av_free(pb.pointee.buffer) }
                avformat_free_context(octx)
            }
            if avioCtx != nil { avio_context_free(&avioCtx) }
            avformat_close_input(&ictx)
        }

        // ---- Open input (same network posture as the player) ----
        ictx = avformat_alloc_context()
        guard let inCtx = ictx else { report { self.onError?("alloc failed") }; return }
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { opaque -> Int32 in
            guard let opaque else { return 0 }
            return Unmanaged<DVRemuxer>.fromOpaque(opaque).takeUnretainedValue().cancelled ? 1 : 0
        }
        inCtx.pointee.interrupt_callback = interruptCB

        var openOpts: OpaquePointer?
        av_dict_set(&openOpts, "reconnect", "1", 0)
        av_dict_set(&openOpts, "reconnect_streamed", "1", 0)
        av_dict_set(&openOpts, "reconnect_delay_max", "5", 0)
        av_dict_set(&openOpts, "reconnect_on_network_error", "1", 0)
        av_dict_set(&openOpts, "rw_timeout", "20000000", 0)
        av_dict_set(&openOpts, "buffer_size", String(4 << 20), 0)
        var openResult = avformat_open_input(&ictx, inputURLString, nil, &openOpts)
        av_dict_free(&openOpts)
        guard openResult == 0, ictx != nil else {
            report { self.onError?("Couldn't open source (\(openResult))") }
            return
        }
        openResult = avformat_find_stream_info(ictx, nil)
        guard openResult >= 0 else {
            report { self.onError?("Couldn't probe source (\(openResult))") }
            return
        }

        // ---- Eligibility: DV P5/P8 video + AVPlayer-compatible audio ----
        var videoIndex: Int32 = -1
        var dvProfile: UInt8 = 0
        var audioIndex: Int32 = -1
        var audioScore = -1

        let streamCount = Int(ictx!.pointee.nb_streams)
        for i in 0 ..< streamCount {
            guard let stream = ictx!.pointee.streams[i], let par = stream.pointee.codecpar else { continue }
            let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO, !isAttachedPic, videoIndex < 0 {
                guard par.pointee.codec_id == AV_CODEC_ID_HEVC else { continue }
                var sideSize = 0
                if let side = av_stream_get_side_data(stream, AV_PKT_DATA_DOVI_CONF, &sideSize), sideSize > 0 {
                    let record = side.withMemoryRebound(to: DOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
                    dvProfile = record.dv_profile
                    videoIndex = Int32(i)
                }
            } else if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                // Priority: E-AC3 (Atmos-capable) > AC3 > AAC.
                let score: Int
                switch par.pointee.codec_id {
                case AV_CODEC_ID_EAC3: score = 3
                case AV_CODEC_ID_AC3: score = 2
                case AV_CODEC_ID_AAC: score = 1
                default: score = -1
                }
                guard score > 0 else { continue }
                // Preferred language wins ties (worth +½ tier).
                var langBonus = 0
                if !preferredAudioLanguage.isEmpty,
                   let langEntry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
                   let value = langEntry.pointee.value,
                   String(cString: value).hasPrefix(preferredAudioLanguage) {
                    langBonus = 10
                }
                if score + langBonus > audioScore {
                    audioScore = score + langBonus
                    audioIndex = Int32(i)
                }
            }
        }

        guard videoIndex >= 0 else {
            report { self.onIneligible?("no Dolby Vision video stream") }
            return
        }
        // Profile 7 (dual-layer) is convertible to 8.1 via libdovi when the
        // experimental toggle is on; otherwise it's ineligible → HDR10 path.
        let needsProfile7Conversion = (dvProfile == 7) && convertProfile7
        guard dvProfile == 5 || dvProfile == 8 || needsProfile7Conversion else {
            report { self.onIneligible?("Dolby Vision profile \(dvProfile) (only 5/8 supported)") }
            return
        }
        guard audioIndex >= 0 else {
            report { self.onIneligible?("no E-AC3/AC3/AAC audio track (TrueHD/DTS can't ride the native pipeline)") }
            return
        }

        // ---- Input seek (resume mid-movie without remuxing from zero) ----
        if startAtSeconds > 1 {
            let ts = Int64(startAtSeconds * 1_000_000)   // AV_TIME_BASE units
            av_seek_frame(ictx, -1, ts, 1 /* AVSEEK_FLAG_BACKWARD */)
        }

        // ---- Output: fragmented MP4 through the box splitter ----
        avformat_alloc_output_context2(&octx, nil, "mp4", nil)
        guard let outCtx = octx else { report { self.onError?("mp4 muxer unavailable") }; return }
        outCtx.pointee.strict_std_compliance = -2   // experimental: DV tags
        outCtx.pointee.avoid_negative_ts = 2        // MAKE_ZERO: playlist t=0

        let ioBufSize: Int32 = 1 << 16
        guard let ioBuf = av_malloc(Int(ioBufSize))?.assumingMemoryBound(to: UInt8.self) else {
            report { self.onError?("io alloc failed") }; return
        }
        avioCtx = avio_alloc_context(
            ioBuf, ioBufSize, 1,
            Unmanaged.passUnretained(self).toOpaque(), nil,
            { opaque, data, size -> Int32 in
                guard let opaque, let data, size > 0 else { return size }
                let remuxer = Unmanaged<DVRemuxer>.fromOpaque(opaque).takeUnretainedValue()
                remuxer.consume(Data(bytes: data, count: Int(size)))
                return size
            }, nil
        )
        guard avioCtx != nil else { report { self.onError?("avio alloc failed") }; return }
        avioCtx!.pointee.seekable = 0
        outCtx.pointee.pb = avioCtx

        guard let inVideo = ictx!.pointee.streams[Int(videoIndex)],
              let inAudio = ictx!.pointee.streams[Int(audioIndex)],
              let outVideo = avformat_new_stream(outCtx, nil),
              let outAudio = avformat_new_stream(outCtx, nil)
        else { report { self.onError?("stream setup failed") }; return }

        avcodec_parameters_copy(outVideo.pointee.codecpar, inVideo.pointee.codecpar)
        avcodec_parameters_copy(outAudio.pointee.codecpar, inAudio.pointee.codecpar)
        outAudio.pointee.codecpar.pointee.codec_tag = 0
        // Sample entry: P5 has no cross-compatible base layer → dvh1 (DV-only
        // brand). P8 (and converted-from-P7 8.1) is HDR10-backward-compatible
        // → hvc1, movenc adds dvvC.
        outVideo.pointee.codecpar.pointee.codec_tag = dvProfile == 5
            ? fourCC("d", "v", "h", "1")
            : fourCC("h", "v", "c", "1")

        // movenc reads DV config (and HDR mastering metadata for the fallback
        // path) from STREAM side data, which parameters_copy doesn't carry.
        copyStreamSideData(from: inVideo, to: outVideo, type: AV_PKT_DATA_DOVI_CONF)
        copyStreamSideData(from: inVideo, to: outVideo, type: AV_PKT_DATA_MASTERING_DISPLAY_METADATA)
        copyStreamSideData(from: inVideo, to: outVideo, type: AV_PKT_DATA_CONTENT_LIGHT_LEVEL)

        // Rewrite the copied DV config to single-layer 8.1: profile 8, no
        // enhancement layer, HDR10-compatible base (bl_signal_compatibility 1)
        // — matching the RPUs we convert per-packet below. movenc emits the
        // corresponding dvvC box from this.
        if needsProfile7Conversion {
            var outSize = 0
            // AV_PKT_DATA_DOVI_CONF side data is the raw
            // AVDOVIDecoderConfigurationRecord: 8 contiguous uint8_t fields
            // (version_major, version_minor, dv_profile, dv_level,
            // rpu_present, el_present, bl_present, bl_signal_compat_id).
            // Write the bytes directly — the struct view is const-imported.
            if let outSide = av_stream_get_side_data(outVideo, AV_PKT_DATA_DOVI_CONF, &outSize),
               outSize >= 8 {
                outSide[2] = 8   // dv_profile → 8
                outSide[4] = 1   // rpu_present_flag
                outSide[5] = 0   // el_present_flag → single-layer
                outSide[6] = 1   // bl_present_flag
                outSide[7] = 1   // dv_bl_signal_compatibility_id → HDR10-compatible (8.1)
            }
        }

        var muxOpts: OpaquePointer?
        // delay_moov: movenc builds some audio sample entries (AC3's dac3 box
        // among them) from the FIRST PACKETS, so writing moov at header time
        // fails with "Cannot write moov atom before AC3 packets" — the exact
        // error a P7 remux carrying a plain AC3 core hits (E-AC3 sources never
        // did, which is why this path used to look fine). Deferring moov to
        // the first fragment flush is safe for our splitter: it defines the
        // init segment as everything before the first moof, wherever the moov
        // bytes arrive in that stretch.
        av_dict_set(&muxOpts, "movflags", "+frag_keyframe+empty_moov+default_base_moof+delay_moov", 0)
        _ = FFmpegLogCapture.drainRecent()   // only THIS call's errors
        var writeResult = avformat_write_header(octx, &muxOpts)
        av_dict_free(&muxOpts)
        guard writeResult >= 0 else {
            let detail = FFmpegLogCapture.drainRecent().joined(separator: " | ")
            report { self.onError?("mux header failed (\(writeResult))"
                + (detail.isEmpty ? "" : " — \(detail)")) }
            return
        }

        // ---- Copy loop ----
        guard let packet = av_packet_alloc() else { report { self.onError?("packet alloc failed") }; return }
        var freePacket: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&freePacket) }

        let inVideoTB = inVideo.pointee.time_base
        let inAudioTB = inAudio.pointee.time_base
        var packetsSinceProgress = 0

        // NAL length-prefix size for RPU conversion (hvcC byte 21, low 2 bits).
        // MP4/MKV HEVC is always length-prefixed; default 4 if unreadable.
        var nalLengthSize = 4
        if needsProfile7Conversion,
           let extra = inVideo.pointee.codecpar.pointee.extradata,
           inVideo.pointee.codecpar.pointee.extradata_size > 22 {
            nalLengthSize = Int(extra[21] & 0x03) + 1
        }

        while !cancelled {
            let readResult = av_read_frame(ictx, packet)
            if readResult < 0 { break }   // EOF or error → finalize what we have
            defer { av_packet_unref(packet) }

            let streamIndex = packet.pointee.stream_index
            let isVideo = streamIndex == videoIndex
            let isAudio = streamIndex == audioIndex
            guard isVideo || isAudio else { continue }

            // P7 conversion FIRST — before any timing bookkeeping. A pure-EL
            // packet is dropped entirely here; letting it reach the keyframe
            // tracker first would append phantom cut points that no muxed
            // fragment ever matches, skewing every later segment duration.
            // On malformed/failed conversion `convertedAccessUnit` returns nil
            // and the untouched packet is muxed — a bad frame degrades to the
            // original rather than corrupting the stream.
            var converted: [UInt8]?
            if needsProfile7Conversion, isVideo {
                converted = convertedAccessUnit(packet, nalLengthSize: nalLengthSize)
                if let converted, converted.isEmpty {
                    // Whole packet was enhancement layer (key-flagged, one per
                    // frame in this mux — the same packets that shredded the
                    // playlist into single-frame fragments). Skip it.
                    continue
                }
            }

            let inTB = isVideo ? inVideoTB : inAudioTB
            if packet.pointee.pts != Int64.min {   // AV_NOPTS_VALUE
                let ptsSec = Double(packet.pointee.pts) * av_q2d(inTB)
                if firstWrittenPTS.isNaN { firstWrittenPTS = ptsSec; paceStartWall = Date() }
                if isVideo {
                    lastVideoPTS = ptsSec
                    if (packet.pointee.flags & 0x0001) != 0 {   // AV_PKT_FLAG_KEY
                        keyframes.append(ptsSec - firstWrittenPTS)
                    }
                }
            }

            let outStream = isVideo ? outVideo : outAudio

            // Profile 7 → 8.1: if this video access unit's RPU NAL(s) convert,
            if let converted {
                let outPkt = av_packet_alloc()
                defer { var p = outPkt; av_packet_free(&p) }
                if let outPkt, av_new_packet(outPkt, Int32(converted.count)) >= 0 {
                    converted.withUnsafeBufferPointer { memcpy(outPkt.pointee.data, $0.baseAddress, converted.count) }
                    av_packet_copy_props(outPkt, packet)
                    outPkt.pointee.stream_index = outStream.pointee.index
                    av_packet_rescale_ts(outPkt, inTB, outStream.pointee.time_base)
                    outPkt.pointee.pos = -1
                    writeResult = av_interleaved_write_frame(octx, outPkt)
                } else {
                    writeResult = -1
                }
            } else {
                packet.pointee.stream_index = outStream.pointee.index
                av_packet_rescale_ts(packet, inTB, outStream.pointee.time_base)
                packet.pointee.pos = -1
                writeResult = av_interleaved_write_frame(octx, packet)
            }
            if writeResult < 0 {
                report { self.onError?("mux write failed (\(writeResult))") }
                return
            }

            packetsSinceProgress += 1
            if packetsSinceProgress >= 100 {
                packetsSinceProgress = 0
                let written = max(lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS), 0)
                report { self.onProgress?(written) }
            }

            // Read-ahead pacing. Once the worker is more than `paceLeadSeconds`
            // of content ahead of a `paceSpeedFactor`× realtime budget, pause
            // until wall-clock catches up — so the whole file isn't pulled,
            // decoded and RPU-rewritten in one burst that floods the box. Uses
            // wall clock only, so it can never deadlock waiting on the playhead.
            if paceSpeedFactor > 0, let startWall = paceStartWall, !firstWrittenPTS.isNaN {
                let contentAhead = lastVideoPTS - firstWrittenPTS
                while !cancelled,
                      contentAhead > Date().timeIntervalSince(startWall) * paceSpeedFactor + paceLeadSeconds {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }

        if cancelled { return }

        // Flush the final fragment + finalize the playlist.
        av_write_trailer(octx)
        finished = true
        finalizeOpenSegment()
        writePlaylist(ended: true)
        let written = max(lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS), 0)
        signalReadyIfNeeded()
        report {
            self.onProgress?(written)
            self.onFinished?()
        }
    }

    // MARK: - Box splitter (called from the AVIO write callback, remux thread)

    /// mp4 muxer output arrives as an arbitrary byte stream; carve it into
    /// top-level ISO-BMFF boxes. ftyp+moov (everything before the first moof)
    /// is the HLS init segment; each moof…mdat run is one media segment.
    private func consume(_ bytes: Data) {
        pendingBytes.append(bytes)
        while pendingBytes.count >= 8 {
            let declared = pendingBytes.withUnsafeBytes { raw -> UInt64 in
                let size32 = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                if size32 == 1, raw.count >= 16 {
                    return UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
                }
                return UInt64(size32)
            }
            guard declared >= 8, declared < 1 << 32 else { return }   // malformed: bail
            let boxSize = Int(declared)
            guard pendingBytes.count >= boxSize else { return }       // wait for more
            let box = pendingBytes.prefix(boxSize)
            let type = String(decoding: box.dropFirst(4).prefix(4), as: UTF8.self)
            pendingBytes.removeFirst(boxSize)
            dispatch(box: Data(box), type: type)
        }
    }

    private func dispatch(box: Data, type: String) {
        if initPhase {
            if type == "moof" {
                // Init segment complete — write it, open the first segment.
                try? initData.write(to: directory.appendingPathComponent("init.mp4"))
                initPhase = false
                segmentData = box
                segmentOpen = true
            } else {
                initData.append(box)
            }
            return
        }
        if !segmentOpen {
            guard type == "moof" else { return }   // mfra / trailer noise
            segmentData = box
            segmentOpen = true
            return
        }
        segmentData.append(box)
        if type == "mdat" { closeSegment() }
    }

    private func closeSegment() {
        let name = String(format: "seg%05d.m4s", segmentIndex)
        try? segmentData.write(to: directory.appendingPathComponent(name))
        segmentData = Data()
        segmentOpen = false

        // Fragment i spans keyframe i → i+1 (frag_keyframe = one per GOP); the
        // next keyframe is always recorded before movenc flushes fragment i.
        let duration: Double
        if segmentIndex + 1 < keyframes.count {
            duration = max(keyframes[segmentIndex + 1] - keyframes[segmentIndex], 0.04)
        } else {
            let base = keyframes.indices.contains(segmentIndex) ? keyframes[segmentIndex] : 0
            duration = max(lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS) - base + 0.04, 0.04)
        }
        segmentDurations.append(duration)
        segmentIndex += 1

        writePlaylist(ended: false)
        if segmentIndex >= 3 { signalReadyIfNeeded() }
        let available = keyframes.indices.contains(segmentIndex) ? keyframes[segmentIndex]
            : max(lastVideoPTS - (firstWrittenPTS.isNaN ? 0 : firstWrittenPTS), 0)
        report { self.onProgress?(available) }
    }

    /// Trailer can flush a final moof+mdat through the normal path; anything
    /// left half-open (shouldn't happen) is dropped.
    private func finalizeOpenSegment() {
        segmentData = Data()
        segmentOpen = false
    }

    // MARK: - Playlist

    private func writePlaylist(ended: Bool) {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int((segmentDurations.max() ?? 6).rounded(.up)) + 1)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (i, duration) in segmentDurations.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", duration))
            lines.append(String(format: "seg%05d.m4s", i))
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        let content = lines.joined(separator: "\n") + "\n"
        // Atomic: AVPlayer polls the EVENT playlist — it must never read half.
        try? content.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
    }

    private func signalReadyIfNeeded() {
        guard !readySignalled, segmentIndex > 0 else { return }
        readySignalled = true
        let start = firstWrittenPTS.isNaN ? startAtSeconds : firstWrittenPTS
        let url = playlistURL
        report { self.onReady?(url, start) }
    }

    // MARK: - Dolby Vision Profile 7 → 8.1

    /// Walk the packet's length-prefixed HEVC NAL units: convert any Dolby
    /// Vision RPU NAL (type 62) from Profile 7 to 8.1 via libdovi, and DISCARD
    /// enhancement-layer NALs (type 63 — the Dolby single-stream EL carriage).
    ///
    /// Dropping the EL is not an optimisation, it is the conversion. The dvvC
    /// we write declares "profile 8.1, single layer, el_present = 0"; leaving
    /// unspec63 EL data in the bitstream contradicts that declaration, and
    /// VideoToolbox answers the contradiction by silently never producing a
    /// frame — the "switched to native DV, then the watchdog fired with no
    /// error" failure, reproduced on a real P7 disc remux. dovi_tool's own
    /// P7→8.1 is exactly: convert RPU, keep BL, discard EL.
    ///
    /// Returns the rewritten bytes; an EMPTY array when the whole packet was
    /// enhancement layer (caller must drop the packet, not mux a 0-byte one);
    /// nil when nothing needed changing or the AU looked malformed (caller
    /// muxes the original).
    private func convertedAccessUnit(
        _ packet: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int
    ) -> [UInt8]? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let size = Int(packet.pointee.size)
        let buf = UnsafeBufferPointer(start: data, count: size)
        var out = [UInt8]()
        out.reserveCapacity(size + 16)
        var i = 0
        var converted = false
        while i + nalLengthSize <= size {
            var nalLen = 0
            for k in 0 ..< nalLengthSize { nalLen = (nalLen << 8) | Int(buf[i + k]) }
            i += nalLengthSize
            guard nalLen > 0, i + nalLen <= size else {
                // Malformed length → don't risk a corrupt AU; keep original.
                return converted ? out : nil
            }
            let nal = Array(buf[i ..< i + nalLen])
            i += nalLen
            // HEVC NAL type = bits 1..6 of the first header byte.
            let nalType = (nal[0] >> 1) & 0x3F
            if nalType == 63 {
                // Enhancement layer — discarded (see doc comment).
                converted = true
            } else if nalType == 62, let newNal = DoviConverter.convertRPU7to81(Data(nal)) {
                appendLengthPrefixed(&out, [UInt8](newNal), nalLengthSize)
                converted = true
            } else {
                appendLengthPrefixed(&out, nal, nalLengthSize)
            }
        }
        return converted ? out : nil
    }

    private func appendLengthPrefixed(_ out: inout [UInt8], _ nal: [UInt8], _ lengthSize: Int) {
        let len = nal.count
        for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((len >> shift) & 0xFF))
        }
        out.append(contentsOf: nal)
    }

    // MARK: - Helpers

    private func report(_ block: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            guard !cancelled else { return }
            _ = self   // keep alive through delivery
            block()
        }
    }

    private func fourCC(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
        UInt32(a.asciiValue!) | UInt32(b.asciiValue!) << 8 | UInt32(c.asciiValue!) << 16 | UInt32(d.asciiValue!) << 24
    }

    private func copyStreamSideData(
        from inStream: UnsafeMutablePointer<AVStream>,
        to outStream: UnsafeMutablePointer<AVStream>,
        type: AVPacketSideDataType
    ) {
        var size = 0
        guard let src = av_stream_get_side_data(inStream, type, &size), size > 0,
              let dst = av_stream_new_side_data(outStream, type, size)
        else { return }
        memcpy(dst, src, size)
    }
}

/// Minimal atomic bool (the remux thread + main thread both touch `cancelled`).
@propertyWrapper
final class Atomic<Value> {
    private let lock = NSLock()
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
