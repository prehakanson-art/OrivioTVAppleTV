import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// What a header probe learned about a source.
struct StreamProbeResult {
    /// At least one ASS/SSA subtitle track (→ route to VLC for libass).
    var hasStyledASS = false
    /// HDR10+ dynamic metadata present in the video bitstream.
    var hasHDR10Plus = false
    /// Dolby Vision profile from the container's dvcC/dvvC record (nil when
    /// the stream carries none). Read from the header — no packet scan.
    var dvProfile: Int?
    /// Profile 7 only: true when the enhancement layer is a real residual
    /// stream (FEL) rather than a minimal shell (MEL). Measured by a short
    /// packet scan; FEL conversion to 8.1 is approximate, MEL is lossless.
    var isFEL = false
    /// An HEVC video track exists (the direct engine's requirement).
    var hasHEVC = false
    /// The video is PQ-transfer HDR (HDR10 family) — drives the display-mode
    /// request when there's no DV.
    var isPQ = false
    /// Container duration in seconds (0 when unknown). Free with the header,
    /// and the DV-first path needs it — a session that never opens the FFmpeg
    /// engine has no other duration source until AVPlayer reports one.
    var durationSeconds: Double = 0
    /// The file carries at least one audio track. (Formerly restricted to
    /// E-AC3/AC3/AAC for the remux path; the direct sample engine decodes
    /// everything else to LPCM, so ANY audio is now eligible.)
    var hasEligibleAudio = false
}

/// Cheap "what is actually in this stream?" check, run once per title.
///
/// Only reads the container header (plus, for HDR10+, a short run of video
/// packets) — a few MB over the network, once — so it's safe for remote
/// debrid / torrent streams. Both questions share ONE open: they used to be
/// separate probes, and a second connection to the same remote file competes
/// for bandwidth at the exact moment startup is most sensitive.
enum StreamProbe {
    /// Probe `url`, answering only the questions asked for. Any failure
    /// returns all-false — a probe must never be the reason playback changes
    /// behaviour on bad information.
    static func inspect(
        url: String,
        needsStyledASS: Bool,
        needsHDR10Plus: Bool,
        needsDolbyVision: Bool = false,
        timeoutSeconds: Double = 8
    ) async -> StreamProbeResult {
        guard needsStyledASS || needsHDR10Plus || needsDolbyVision else { return StreamProbeResult() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe(
                    url: url,
                    needsStyledASS: needsStyledASS,
                    needsHDR10Plus: needsHDR10Plus,
                    timeoutSeconds: timeoutSeconds
                ))
            }
        }
    }

    private static func probe(
        url: String, needsStyledASS: Bool, needsHDR10Plus: Bool, timeoutSeconds: Double
    ) -> StreamProbeResult {
        var result = StreamProbeResult()
        var ctx: UnsafeMutablePointer<AVFormatContext>?

        // Bound the network open so a slow host can't stall playback start.
        var opts: OpaquePointer?
        av_dict_set(&opts, "rw_timeout", String(Int(timeoutSeconds * 1_000_000)), 0)
        av_dict_set(&opts, "timeout", String(Int(timeoutSeconds * 1_000_000)), 0)
        av_dict_set(&opts, "reconnect", "1", 0)

        defer { av_dict_free(&opts) }
        guard avformat_open_input(&ctx, url, nil, &opts) == 0, let ctx else { return result }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }

        // Bound the probe the same way the playback path does (PlayerViewModel
        // sets probesize/maxAnalyzeDuration). This runs on a SECOND connection
        // to the same remote file while the player is still filling its initial
        // buffer, and FFmpeg's defaults here are 5 MB and up to 5 SECONDS of
        // content — a meaningful bandwidth competitor on a debrid link right at
        // the moment startup is most sensitive. The stream list comes from the
        // container header, so a small probe is entirely sufficient.
        ctx.pointee.probesize = 2 << 20              // 2 MB
        ctx.pointee.max_analyze_duration = 1_000_000 // 1s (microseconds)
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return result }

        var videoIndex: Int32 = -1
        var isPQ = false
        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i], let par = stream.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_SUBTITLE:
                if par.pointee.codec_id == AV_CODEC_ID_ASS || par.pointee.codec_id == AV_CODEC_ID_SSA {
                    result.hasStyledASS = true
                }
            case AVMEDIA_TYPE_VIDEO:
                let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
                if !isAttachedPic, videoIndex < 0, par.pointee.codec_id == AV_CODEC_ID_HEVC {
                    videoIndex = Int32(i)
                    isPQ = par.pointee.color_trc == AVCOL_TRC_SMPTE2084
                    result.hasHEVC = true
                    result.isPQ = isPQ
                    // Dolby Vision configuration rides the header as coded
                    // side data — same source KSPlayer's track parser uses.
                    if par.pointee.nb_coded_side_data > 0, let sideDatas = par.pointee.coded_side_data {
                        for j in 0 ..< Int(par.pointee.nb_coded_side_data) {
                            let sideData = sideDatas[j]
                            if sideData.type == AV_PKT_DATA_DOVI_CONF, let data = sideData.data {
                                let record = data.withMemoryRebound(
                                    to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
                                ) { $0 }.pointee
                                result.dvProfile = Int(record.dv_profile)
                            }
                        }
                    }
                }
            case AVMEDIA_TYPE_AUDIO:
                result.hasEligibleAudio = true
            default: break
            }
        }
        if ctx.pointee.duration > 0 {
            result.durationSeconds = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        }

        // HDR10+ rides in the HEVC bitstream as a per-frame SEI, so it can't be
        // read from the header — a short packet scan is required. Skip it
        // unless the base layer is actually PQ HDR10: HDR10+ is defined as
        // HDR10 plus dynamic metadata, so a non-PQ stream cannot carry it and
        // the scan would be pure startup latency.
        if needsHDR10Plus, videoIndex >= 0, isPQ {
            result.hasHDR10Plus = scanForHDR10Plus(ctx: ctx, videoIndex: videoIndex)
        }
        // FEL/MEL is decided the same way: a bounded packet scan measuring
        // the enhancement-layer (type-63) NAL sizes. MEL shells are ~100
        // bytes; FEL residual frames are kilobytes.
        if result.dvProfile == 7, videoIndex >= 0 {
            result.isFEL = scanForFEL(ctx: ctx, videoIndex: videoIndex)
        }
        return result
    }

    /// Average type-63 NAL payload over a short packet run; >1000 bytes = FEL.
    private static func scanForFEL(
        ctx: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int32
    ) -> Bool {
        guard let packet = av_packet_alloc() else { return false }
        defer { var pp: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&pp) }
        var nalLengthSize = 4
        if let stream = ctx.pointee.streams[Int(videoIndex)],
           let extra = stream.pointee.codecpar.pointee.extradata,
           stream.pointee.codecpar.pointee.extradata_size > 22,
           extra[0] == 1 {
            nalLengthSize = Int(extra[21] & 0x03) + 1
        }
        var scanned = 0, elCount = 0, elBytes = 0
        let deadline = Date().addingTimeInterval(4)
        while scanned < 48, Date() < deadline {
            guard av_read_frame(ctx, packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == videoIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            scanned += 1
            let au = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            var i = 0
            while i + nalLengthSize <= au.count {
                var len = 0
                for k in 0 ..< nalLengthSize { len = (len << 8) | Int(au[i + k]) }
                let start = i + nalLengthSize
                guard len > 0, start + len <= au.count else { break }
                if (au[start] >> 1) & 0x3F == 63 { elCount += 1; elBytes += len }
                i = start + len
            }
        }
        guard elCount > 0 else { return false }
        return elBytes / elCount > 1000
    }

    /// Read a bounded run of video packets looking for the HDR10+ SEI.
    ///
    /// HDR10+ metadata is emitted on essentially every frame, so a short scan
    /// is conclusive in practice; the cap keeps a false negative cheap rather
    /// than reading the file looking for something that isn't there.
    private static func scanForHDR10Plus(
        ctx: UnsafeMutablePointer<AVFormatContext>, videoIndex: Int32
    ) -> Bool {
        guard let packet = av_packet_alloc() else { return false }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }

        // Length-prefix size from hvcC extradata; Annex-B sources are detected
        // per-packet by their start codes instead.
        var nalLengthSize = 4
        if let stream = ctx.pointee.streams[Int(videoIndex)],
           let extra = stream.pointee.codecpar.pointee.extradata,
           stream.pointee.codecpar.pointee.extradata_size > 22,
           extra[0] == 1 {   // hvcC configurationVersion
            nalLengthSize = Int(extra[21] & 0x03) + 1
        }

        var scanned = 0
        let deadline = Date().addingTimeInterval(4)
        while scanned < 48, Date() < deadline {
            guard av_read_frame(ctx, packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == videoIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            scanned += 1
            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            if packetCarriesHDR10Plus(bytes, nalLengthSize: nalLengthSize) { return true }
        }
        return false
    }

    /// True if any prefix-SEI NAL in this access unit carries the HDR10+
    /// `user_data_registered_itu_t_t35` payload.
    private static func packetCarriesHDR10Plus(
        _ buf: UnsafeBufferPointer<UInt8>, nalLengthSize: Int
    ) -> Bool {
        // Annex-B (start codes) vs length-prefixed (MP4/MKV) — TS sources use
        // the former, and guessing wrong means scanning garbage.
        let isAnnexB = buf.count > 4 && buf[0] == 0 && buf[1] == 0
            && (buf[2] == 1 || (buf[2] == 0 && buf[3] == 1))
        var ranges: [Range<Int>] = []
        if isAnnexB {
            var starts: [Int] = []
            var i = 0
            while i + 3 <= buf.count {
                if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                    starts.append(i + 3); i += 3
                } else { i += 1 }
            }
            for (n, start) in starts.enumerated() {
                ranges.append(start ..< (n + 1 < starts.count ? starts[n + 1] - 3 : buf.count))
            }
        } else {
            var i = 0
            while i + nalLengthSize <= buf.count {
                var len = 0
                for k in 0 ..< nalLengthSize { len = (len << 8) | Int(buf[i + k]) }
                i += nalLengthSize
                guard len > 0, i + len <= buf.count else { break }
                ranges.append(i ..< i + len)
                i += len
            }
        }

        for range in ranges {
            guard range.count > 7 else { continue }
            // HEVC NAL type = bits 1..6 of the first header byte. 39 = prefix
            // SEI (where HDR10+ lives); 40 = suffix SEI, checked too since
            // some muxers place it there.
            let nalType = (buf[range.lowerBound] >> 1) & 0x3F
            guard nalType == 39 || nalType == 40 else { continue }
            // Signature: ITU-T T.35 country code 0xB5 (USA), terminal provider
            // code 0x003C (Samsung), oriented code 0x0001 — the registered
            // HDR10+ identifier. Searched as raw bytes rather than parsed:
            // emulation-prevention bytes can only be inserted after two
            // consecutive zeros, and this sequence never has a pair, so it
            // survives escaping intact. Confined to SEI NALs, so slice data
            // can't produce a false positive.
            var i = range.lowerBound
            while i + 5 <= range.upperBound {
                if buf[i] == 0xB5, buf[i + 1] == 0x00, buf[i + 2] == 0x3C,
                   buf[i + 3] == 0x00, buf[i + 4] == 0x01 {
                    return true
                }
                i += 1
            }
        }
        return false
    }
}
