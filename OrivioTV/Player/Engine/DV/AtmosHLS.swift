import AVFoundation
import Foundation
import KSPlayer
import Libavcodec
import Libavformat
import Libavutil
import Network

/// EXPERIMENTAL: true Dolby Atmos (E-AC-3 + JOC) passthrough for MKV sources.
///
/// The normal sample-feed engine hands compressed E-AC-3 to
/// `AVSampleBufferAudioRenderer`, which DECODES it — the receiver sees PCM and
/// the Atmos objects are gone. Only `AVPlayer` emits Dolby MAT 2.0 (real
/// Atmos), and AVPlayer cannot open MKV.
///
/// So this module demuxes the source's E-AC-3 track, re-muxes it into
/// fragmented MP4 (init + media segments) with libavformat's `mov` muxer
/// (`frag_duration` + `empty_moov`), serves the result over loopback HTTP as an
/// HLS media playlist, and plays THAT with an `AVPlayer`. The video stays on the
/// existing `AVSampleBufferDisplayLayer` pipeline; the AVPlayer is the audio
/// clock and the display synchronizer follows it.
///
/// Everything here is behind a default-off setting and is never started unless
/// the source is E-AC-3 and the route is HDMI. If anything fails, the caller
/// falls back to the normal engine untouched.
enum AtmosHLS {
    /// Log prefix, so the probe tail can follow one session.
    static let tag = "atmos-hls"
}

// MARK: - JOC signalling

/// Rebuilds the `dec3` (EAC3SpecificBox) so it carries the JOC complexity
/// index — the one thing that makes tvOS treat an E-AC-3 track as Dolby Atmos.
///
/// FFmpeg 6.1's `mov` muxer writes `dec3` WITHOUT the extension (upstream added
/// it in master and jellyfin-ffmpeg backported it; FFmpeg trac #9996). The
/// bitstream keeps its JOC objects, but without the box flag tvOS/AVFoundation
/// sees an ordinary DD+ track — the remuxed audio plays as PCM or plain DD+
/// and the receiver never lights "Dolby Atmos". This walks the init segment to
/// the box and rewrites it in the JOC layout.
///
/// Best effort by construction: anything that does not match the exact shape
/// this understands returns nil, and the original init segment is served
/// untouched.
enum AtmosDec3 {
    private struct Substream {
        var fscod = 0, bsid = 0, bsmod = 0, acmod = 0, lfeon = 0
        var numDepSub = 0, chanLoc = 0
    }

    /// Complexity index written for a source that is Atmos but whose exact
    /// index we do not parse. 16 is the documented upper bound (the
    /// jellyfin-ffmpeg patch clamps to it), and the receiver decodes the real
    /// object scene from the bitstream regardless.
    static let defaultComplexity = 16

    /// `initSegment` with its `dec3` carrying JOC, or nil to leave it alone.
    static func patchingJOC(_ initSegment: Data,
                            complexityIndex: Int = defaultComplexity) -> Data? {
        let bytes = [UInt8](initSegment)
        guard let (path, dec3) = findDec3(bytes),
              let legacy = parseLegacyDec3(bytes, dec3) else { return nil }
        let newPayload = emitJOCDec3(legacy.dataRate, legacy.substreams,
                                     complexityIndex: complexityIndex)
        let newSize = 8 + newPayload.count
        let delta = newSize - dec3.size
        var out = Array(bytes[0..<dec3.start])
        out.append(contentsOf: be32(UInt32(newSize)))
        out.append(contentsOf: Array("dec3".utf8))
        out.append(contentsOf: newPayload)
        out.append(contentsOf: bytes[dec3.end...])
        // Every ancestor box now holds `delta` more bytes.
        for box in path.dropLast() {
            let size = Int(be32(out, box.start)) + delta
            guard size >= 8 else { return nil }
            writeBE32(&out, at: box.start, UInt32(size))
        }
        guard validates(out) else { return nil }
        return Data(out)
    }

    // MARK: ISO BMFF walking

    private struct Box {
        let type: String
        let start: Int
        let size: Int
        var end: Int { start + size }
    }

    private static func isContainer(_ type: String) -> Bool {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "stsd", "ec-3", "ac-3":
            return true
        default:
            return false
        }
    }

    /// First child byte of a box: 8 for ordinary containers, 16 for `stsd`
    /// (version/flags + entry_count), 36 for an AudioSampleEntry (`ec-3`).
    private static func bodyStart(_ type: String, _ box: Box) -> Int {
        switch type {
        case "stsd": return box.start + 16
        case "ec-3", "ac-3": return box.start + 36
        default: return box.start + 8
        }
    }

    private static func children(_ data: [UInt8], from: Int, to: Int) -> [Box] {
        var out: [Box] = []
        var i = from
        while i + 8 <= to {
            let size = Int(be32(data, i))
            guard size >= 8, i + size <= to else { break }
            out.append(Box(type: str4(data, i + 4), start: i, size: size))
            i += size
        }
        return out
    }

    /// The box plus the chain of boxes containing it.
    private static func findDec3(_ data: [UInt8]) -> (path: [Box], dec3: Box)? {
        func walk(from: Int, to: Int, path: [Box]) -> (path: [Box], dec3: Box)? {
            for box in children(data, from: from, to: to) {
                if box.type == "dec3" { return (path + [box], box) }
                guard isContainer(box.type) else { continue }
                let start = bodyStart(box.type, box)
                guard start < box.end else { continue }
                if let found = walk(from: start, to: box.end, path: path + [box]) {
                    return found
                }
            }
            return nil
        }
        return walk(from: 0, to: data.count, path: [])
    }

    // MARK: dec3 payload

    /// Parse the box FFmpeg 6.1 writes: 13-bit rate, 3-bit substream count,
    /// then 25 bits per substream (5 reserved) with no JOC extension.
    private static func parseLegacyDec3(
        _ data: [UInt8], _ box: Box
    ) -> (dataRate: Int, substreams: [Substream])? {
        var reader = BitReader(data, from: box.start + 8, to: box.end)
        guard let dataRate = reader.read(13), let numIndSub = reader.read(3),
              numIndSub <= 7 else { return nil }
        var subs: [Substream] = []
        for _ in 0...numIndSub {
            guard let fscod = reader.read(2), let bsid = reader.read(5),
                  reader.read(1) != nil, reader.read(1) != nil,
                  let bsmod = reader.read(3), let acmod = reader.read(3),
                  let lfeon = reader.read(1), reader.read(5) != nil,
                  let numDepSub = reader.read(4)
            else { return nil }
            var s = Substream(fscod: fscod, bsid: bsid, bsmod: bsmod,
                              acmod: acmod, lfeon: lfeon)
            s.numDepSub = numDepSub
            if numDepSub == 0 {
                guard reader.read(1) != nil else { return nil }
            } else {
                guard let chanLoc = reader.read(9) else { return nil }
                s.chanLoc = chanLoc
            }
            subs.append(s)
        }
        // Byte padding only. A whole byte or more left over means this is not
        // the layout assumed here (e.g. a newer muxer already wrote JOC) —
        // leave the box alone rather than double-adding the extension.
        guard reader.bitsRemaining < 8 else { return nil }
        return (dataRate, subs)
    }

    /// Emit the JOC layout: 3 reserved bits per substream, then the
    /// `flag_ec3_extension_type_a` byte and the complexity index.
    private static func emitJOCDec3(_ dataRate: Int, _ subs: [Substream],
                                    complexityIndex: Int) -> [UInt8] {
        var writer = BitWriter()
        writer.write(dataRate, 13)
        writer.write(max(subs.count - 1, 0), 3)
        for s in subs {
            writer.write(s.fscod, 2)
            writer.write(s.bsid, 5)
            writer.write(0, 1)   // reserved
            writer.write(0, 1)   // asvc
            writer.write(s.bsmod, 3)
            writer.write(s.acmod, 3)
            writer.write(s.lfeon, 1)
            writer.write(0, 3)   // reserved
            writer.write(s.numDepSub, 4)
            if s.numDepSub == 0 {
                writer.write(0, 1)   // reserved
            } else {
                writer.write(s.chanLoc, 9)
            }
        }
        let complexity = max(1, min(complexityIndex, 16))
        writer.write(0, 7)       // reserved
        writer.write(1, 1)       // flag_ec3_extension_type_a
        writer.write(complexity, 8)
        return writer.bytes
    }

    // MARK: Byte helpers

    private struct BitReader {
        let data: [UInt8]
        let endBit: Int
        var bit: Int
        init(_ data: [UInt8], from byte: Int, to end: Int) {
            self.data = data
            self.bit = byte * 8
            self.endBit = end * 8
        }
        var bitsRemaining: Int { endBit - bit }
        mutating func read(_ n: Int) -> Int? {
            guard bit + n <= endBit else { return nil }
            var value = 0
            for _ in 0..<n {
                let byte = bit >> 3
                let b = (data[byte] >> (7 - (bit & 7))) & 1
                value = (value << 1) | Int(b)
                bit += 1
            }
            return value
        }
    }

    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bit = 0
        mutating func write(_ value: Int, _ n: Int) {
            var i = n - 1
            while i >= 0 {
                if bit & 7 == 0 { bytes.append(0) }
                bytes[bytes.count - 1] |= UInt8((value >> i) & 1) << (7 - (bit & 7))
                bit += 1
                i -= 1
            }
        }
    }

    private static func be32(_ data: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16)
            | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func writeBE32(_ data: inout [UInt8], at: Int, _ value: UInt32) {
        data[at] = UInt8(value >> 24 & 0xFF)
        data[at + 1] = UInt8(value >> 16 & 0xFF)
        data[at + 2] = UInt8(value >> 8 & 0xFF)
        data[at + 3] = UInt8(value & 0xFF)
    }

    private static func str4(_ data: [UInt8], _ at: Int) -> String {
        String(bytes: data[at..<at + 4], encoding: .utf8) ?? "????"
    }

    /// Every top-level box must tile the segment exactly.
    private static func validates(_ data: [UInt8]) -> Bool {
        var i = 0
        while i + 8 <= data.count {
            let size = Int(be32(data, i))
            guard size >= 8, i + size <= data.count else { return false }
            i += size
        }
        return i == data.count
    }
}

// MARK: - Remuxer

/// Demuxes one E-AC-3 audio stream and muxes it to fMP4 segments.
///
/// The output muxer writes through a custom `AVIOContext`, so every byte it
/// produces lands in `sink` instead of a file. `sink` splits the stream into
/// the init segment and each `moof`+`mdat` pair, and stamps each pair with the
/// SOURCE time span it covers.
///
/// Paced by the playhead: the read loop stays at most `maxLead` seconds ahead
/// of `playheadSeconds`. There used to be no pacing at all — the loop read the
/// whole file as fast as the network allowed, holding every segment in memory,
/// behind a 20-minute WALL-CLOCK stop. On a large 4K remux that could not be
/// read through in 20 minutes the Atmos audio simply ended mid-film, and on a
/// fast link the retained segments ran to hundreds of MB.
final class AtmosAudioRemuxer {
    private let inputURL: String
    private let headers: [String: String]?
    private let startAt: Double
    /// The FFmpeg audio stream index the player selected (-1 = first E-AC-3).
    private let preferredIndex: Int32

    /// Called on the remux queue: the init segment, then each media segment
    /// with its SOURCE start time and duration in seconds.
    var onInit: ((Data) -> Void)?
    var onSegment: ((Data, Double, Double) -> Void)?
    /// A clean end of file. Not called after `cancel()` or an error.
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "orivio.atmos.remux")
    /// Set from `cancel()` on the CALLER's thread (the main actor), read by the
    /// loop in `run()` on `queue`. It must NOT go through `queue`: `run()` owns
    /// that serial queue for its whole lifetime, so an enqueued cancel block
    /// could never execute. `@Atomic` makes the flag cross the threads without
    /// the deadlock.
    @Atomic private var cancelled = false

    /// Where playback is, in SOURCE seconds. Written by the orchestrator on the
    /// main actor, read by the read loop.
    @Atomic var playheadSeconds: Double = 0

    /// How far past the playhead the remux may read. Covers a forward skip of
    /// this size without a restart, and bounds both memory and the second
    /// download of the source this path costs.
    static let maxLead: Double = 90

    /// FFmpeg's `AVERROR_EOF` (a macro, so not imported): -MKTAG('E','O','F',' ').
    /// Same value `DVSampleEngine` uses.
    private static let averrorEOF: Int32 = -541_478_725

    init(inputURL: String, headers: [String: String]?, startAt: Double,
         preferredIndex: Int32 = -1) {
        self.inputURL = inputURL
        self.headers = headers
        self.startAt = max(startAt, 0)
        self.preferredIndex = preferredIndex
        playheadSeconds = self.startAt
    }

    func cancel() { cancelled = true }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    // MARK: FFmpeg

    /// Custom AVIO state. Held by the `AVIOContext`'s opaque pointer.
    private final class Sink {
        var buffer = Data()
        var initWritten = false
        /// A top-level box that spans writes (rare) is carried here.
        var pending = Data()
        var onInit: ((Data) -> Void)?
        var onSegment: ((Data, Double, Double) -> Void)?
        /// fMP4 segments are ~1-2s of E-AC-3 (tens of KB); cap the buffer so a
        /// malformed muxer can't grow it without bound.
        let maxBuffer = 8 * 1024 * 1024

        /// Source-seconds start of the packet being handed to the muxer now.
        /// The mov muxer cuts a fragment BEFORE adding the packet that crosses
        /// `frag_duration`, so a segment emitted during that write ends
        /// exactly where this packet starts.
        private var packetSeconds: Double = 0
        /// End of the last packet handed in: the close of the final fragment,
        /// which only the trailer flushes.
        private var lastPacketEnd: Double = 0
        private var segmentStart: Double?
        /// Set just before `av_write_trailer`.
        var atTrailer = false

        func notePacket(start: Double, end: Double) {
            if segmentStart == nil { segmentStart = start }
            packetSeconds = start
            lastPacketEnd = max(lastPacketEnd, end)
        }

        func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
            pending.append(bytes, count: count)
            drain()
        }

        func append(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
            append(UnsafePointer(bytes), count: count)
        }

        private func emitSegment() {
            let end = atTrailer ? lastPacketEnd : packetSeconds
            let start = segmentStart ?? end
            onSegment?(buffer, start, max(end - start, 0.001))
            segmentStart = end
        }

        /// Pull whole top-level boxes out of `pending`. `ftyp`+`moov` (the
        /// boxes before the first `moof`) are the init segment; each
        /// `moof`+`mdat` pair is one media segment.
        private func drain() {
            while pending.count >= 8 {
                let size = pending.withUnsafeBytes { raw -> UInt32 in
                    let b = raw.bindMemory(to: UInt8.self)
                    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                        | (UInt32(b[2]) << 8) | UInt32(b[3])
                }
                // A 64-bit `largesize` (size == 1) is not produced for these
                // small boxes; refuse rather than mis-split.
                guard size >= 8, size != 1 else {
                    // Can't trust the stream — drop the head to resync.
                    pending.removeFirst(min(pending.count, 4))
                    continue
                }
                guard pending.count >= Int(size) else { return }   // wait for more
                let box = pending.prefix(Int(size))
                let type = box.dropFirst(4).prefix(4)
                if !initWritten {
                    // Everything up to the first `moof` is the init segment.
                    if type == Data("moof".utf8) {
                        initWritten = true
                        onInit?(buffer)
                        buffer.removeAll(keepingCapacity: true)
                        buffer.append(box)
                    } else {
                        buffer.append(box)
                    }
                } else {
                    buffer.append(box)
                    if type == Data("mdat".utf8) {
                        emitSegment()
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                pending.removeFirst(Int(size))
                if buffer.count > maxBuffer {
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private func run() {
        var ictx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard ictx != nil else { onError?("alloc failed"); return }
        defer {
            if ictx != nil { avformat_close_input(&ictx) }
        }

        var opts: OpaquePointer?
        // ONE `headers` option, CRLF-joined — FFmpeg's http protocol has no option
        // named after each header, so setting "Referer"/"User-Agent" as option
        // keys (as this used to) was silently ignored and every source that needs
        // them refused the remux.
        if let headers, !headers.isEmpty {
            av_dict_set(&opts, "headers", headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n", 0)
        }
        // BOUND THE INPUT, like every other open in the app. Without these a
        // stalled origin (or the hybrid-cache proxy in front of it) parks this
        // remux thread inside `av_read_frame` indefinitely — no error, no
        // timeout, the worker leaked for the rest of the session. The engines
        // use the same 20s read bound; the reconnect ladder is capped too, or
        // one hung read becomes minutes of 0/1/3/7/… retries. `reconnect` also
        // covers the origin dropping the idle connection while the read loop
        // waits on the playhead (a long pause).
        av_dict_set(&opts, "rw_timeout", "20000000", 0)
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "reconnect_delay_max", "5", 0)
        guard avformat_open_input(&ictx, inputURL, nil, &opts) == 0, ictx != nil else {
            av_dict_free(&opts)
            onError?("couldn't open source")
            return
        }
        av_dict_free(&opts)
        guard avformat_find_stream_info(ictx, nil) >= 0 else {
            onError?("couldn't probe source")
            return
        }

        // Carry the track the PLAYER selected, not merely the first E-AC-3 in
        // the file. A remux often holds a 5.1 Atmos track plus a 2.0 commentary;
        // remuxing the wrong one would play the wrong audio entirely — and its
        // JOC patch would be judged against the wrong track's profile. The
        // indices are FFmpeg stream indices on both sides (same file), so the
        // engine's selection is directly usable here.
        var audioIndex: Int32 = -1
        var audioPar: UnsafeMutablePointer<AVCodecParameters>?
        func cacheableAudio(_ index: Int32) -> UnsafeMutablePointer<AVCodecParameters>? {
            guard index >= 0, index < Int32(ictx!.pointee.nb_streams),
                  let stream = ictx!.pointee.streams[Int(index)],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                  par.pointee.codec_id == AV_CODEC_ID_EAC3 || par.pointee.codec_id == AV_CODEC_ID_AC3
            else { return nil }
            return par
        }
        if let par = cacheableAudio(preferredIndex) {
            audioIndex = preferredIndex
            audioPar = par
        }
        // Fall back to the first E-AC-3/AC-3 track.
        if audioIndex < 0 {
            for i in 0 ..< Int(ictx!.pointee.nb_streams) where cacheableAudio(Int32(i)) != nil {
                audioIndex = Int32(i)
                audioPar = cacheableAudio(Int32(i))
                break
            }
        }
        guard audioIndex >= 0, let srcPar = audioPar else {
            onError?("no E-AC-3/AC-3 track")
            return
        }
        let srcTB = ictx!.pointee.streams[Int(audioIndex)]!.pointee.time_base

        // Output context: fragmented MP4 through the custom sink.
        var octx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&octx, nil, "mp4", nil) == 0, let out = octx else {
            onError?("couldn't create muxer")
            return
        }
        defer { avformat_free_context(octx) }

        let sink = Sink()
        // FFmpeg 6.1's mov muxer drops the JOC complexity index from `dec3`,
        // and without it tvOS never treats the remux as Atmos. Patch it in when
        // the source actually carries E-AC-3 JOC (FFmpeg's parsed profile).
        let wantsJOC = srcPar.pointee.codec_id == AV_CODEC_ID_EAC3
            && srcPar.pointee.profile == 30
        sink.onInit = { [weak self] data in
            #if DEBUG
            // What this FFmpeg build's mov muxer writes for dec3, and whether the
            // JOC rewrite recognises it (`-atmosAnyRoute` sessions only).
            if ProcessInfo.processInfo.arguments.contains("-atmosAnyRoute"), let r = data.range(of: Data("dec3".utf8)) {
                let start = r.lowerBound - 4
                let size = Int(data[start]) << 24 | Int(data[start + 1]) << 16 | Int(data[start + 2]) << 8 | Int(data[start + 3])
                let box = data[start ..< min(data.count, start + size)]
                PlayerProbe.event(AtmosHLS.tag, "dec3 as muxed: size=\(size) bytes=\(box.map { String(format: "%02x", $0) }.joined())"
                    + " patchable=\(AtmosDec3.patchingJOC(data) != nil)")
            }
            #endif
            guard wantsJOC else { self?.onInit?(data); return }
            if let patched = AtmosDec3.patchingJOC(data) {
                PlayerProbe.event(AtmosHLS.tag, "dec3 JOC extension written"
                    + " (\(data.count) → \(patched.count) bytes)")
                self?.onInit?(patched)
            } else {
                PlayerProbe.event(AtmosHLS.tag, "dec3 not patched — box shape not recognised")
                self?.onInit?(data)
            }
        }
        sink.onSegment = { [weak self] data, start, duration in
            self?.onSegment?(data, start, duration)
        }
        let opaque = Unmanaged.passRetained(sink).toOpaque()
        // Balanced on EVERY exit, the early returns below included (each of
        // them used to leak the sink). Runs after the I/O context is freed.
        defer { Unmanaged<Sink>.fromOpaque(opaque).release() }
        let writeCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf, size > 0 else { return 0 }
            let sink = Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue()
            sink.append(buf, count: Int(size))
            return size
        }
        guard let ioRaw = av_malloc(64 * 1024) else {
            onError?("couldn't allocate IO buffer")
            return
        }
        var avio = avio_alloc_context(ioRaw.assumingMemoryBound(to: UInt8.self), 64 * 1024, 1,
                                      opaque, nil, writeCallback, nil)
        guard avio != nil else {
            av_free(ioRaw)
            onError?("couldn't allocate IO context")
            return
        }
        // With AVFMT_FLAG_CUSTOM_IO the context and its buffer are OURS —
        // `avformat_free_context` never frees `pb`, so both leaked on every
        // session. The buffer is read back off the context because avio may
        // have replaced the one allocated above.
        defer {
            out.pointee.pb = nil
            if let ctx = avio { av_free(ctx.pointee.buffer) }
            avio_context_free(&avio)
        }
        out.pointee.pb = avio
        out.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        // Fragment on a duration so audio (every packet a "keyframe") yields
        // ~2s segments rather than one per packet.
        // `+delay_moov` is load-bearing: Matroska's E-AC-3 CodecPrivate usually
        // has no pre-parsed `dec3` box, so writing the moov up front fails the
        // header. Delaying it until the first fragment cut lets libavformat's
        // E-AC-3 handler populate the sample entry from the real bitstream.
        av_opt_set(out.pointee.priv_data, "movflags",
                   "+delay_moov+empty_moov+default_base_moof", 0)
        av_opt_set_int(out.pointee.priv_data, "frag_duration", 2_000_000, 0)

        guard let stream = avformat_new_stream(out, nil) else {
            onError?("couldn't add stream")
            return
        }
        guard avcodec_parameters_copy(stream.pointee.codecpar, srcPar) >= 0 else {
            onError?("couldn't copy codec params")
            return
        }
        // Let the muxer pick its own tag; Matroska's would be rejected.
        stream.pointee.codecpar.pointee.codec_tag = 0
        stream.pointee.time_base = srcTB
        let outIndex = stream.pointee.index

        guard avformat_write_header(out, nil) >= 0 else {
            onError?("couldn't write header")
            return
        }

        // Seek to the start point if asked. By the DEFAULT stream (-1, in
        // AV_TIME_BASE units), exactly as the sample engine seeks: Matroska's
        // cues index the video track, and a seek keyed on an audio stream has
        // no index of its own to use.
        if startAt > 1 {
            let ts = Int64(startAt * Double(AV_TIME_BASE))
            _ = av_seek_frame(ictx, -1, ts, AVSEEK_FLAG_BACKWARD)
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let pkt = packet else {
            onError?("couldn't allocate packet")
            return
        }
        let secondsPerTick = av_q2d(srcTB)
        var lastPacketSeconds = -Double.infinity
        var failure: String?
        while !cancelled {
            // Stay a bounded lead ahead of playback. Checked BEFORE the read so
            // a long pause parks here, not inside a network read.
            while !cancelled, lastPacketSeconds > playheadSeconds + Self.maxLead {
                usleep(100_000)
            }
            if cancelled { break }
            let status = av_read_frame(ictx, pkt)
            if status < 0 {
                // Only a real end of file is an end. Anything else (the
                // reconnect ladder gave up, a timeout) is a failure: reported
                // as an end, the audio would just stop with nothing to say why
                // and nothing to hand the sound back to the engine.
                if status != Self.averrorEOF { failure = "source read failed (\(status))" }
                break
            }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == audioIndex else { continue }
            guard pkt.pointee.pts != Int64.min else { continue }
            if pkt.pointee.dts == Int64.min { pkt.pointee.dts = pkt.pointee.pts }
            let start = Double(pkt.pointee.pts) * secondsPerTick
            let end = start + Double(max(pkt.pointee.duration, 0)) * secondsPerTick
            sink.notePacket(start: start, end: end)
            lastPacketSeconds = start
            // Rescale into the output stream's timebase.
            pkt.pointee.pts = av_rescale_q(pkt.pointee.pts, srcTB, stream.pointee.time_base)
            pkt.pointee.dts = av_rescale_q(pkt.pointee.dts, srcTB, stream.pointee.time_base)
            pkt.pointee.duration = av_rescale_q(pkt.pointee.duration, srcTB, stream.pointee.time_base)
            pkt.pointee.stream_index = outIndex
            if av_interleaved_write_frame(out, pkt) < 0 {
                failure = "write failed"
                break
            }
        }
        if cancelled { return }
        if let failure {
            onError?(failure)
            return
        }
        // Flushes the final fragment through the sink.
        sink.atTrailer = true
        av_write_trailer(out)
        onEnded?()
    }
}

// MARK: - Loopback HLS server

/// Serves the remuxed playlist + init + segments over loopback HTTP. AVPlayer
/// only accepts HLS over a network URL, never a local file.
///
/// The playlist is an EVENT playlist (append-only, the whole of it seekable)
/// built on each request from the segment list, and closed with ENDLIST once
/// the remux reaches the end of the file. Segment BODIES behind the playhead
/// are dropped (`prune`), so memory stays bounded; the orchestrator never
/// seeks the AVPlayer into a dropped range (it restarts the remux instead), and
/// a request for one gets a 404 rather than an empty 200.
final class AtmosHLSServer {
    private let queue = DispatchQueue(label: "orivio.atmos.server")
    private var listener: NWListener?
    /// Written on `queue` by the listener's state handler, read on the main
    /// actor by `AtmosPassthrough` — worth the lock rather than a cross-thread
    /// `UInt16` race.
    @Atomic private(set) var port: UInt16 = 0

    private struct Segment {
        let name: String
        let start: Double
        let duration: Double
    }

    // All below: `queue` only.
    private var initSegment: Data?
    private var files: [String: Data] = [:]
    private var segments: [Segment] = []
    /// Index of the oldest segment whose body is still held.
    private var firstRetained = 0
    private var longestSegment: Double = 0
    private var ended = false

    /// What is on offer, in SOURCE seconds.
    struct Window {
        /// Source time of the first segment — the AVPlayer timeline's zero.
        let origin: Double
        /// Start of the oldest segment still held.
        let retainedStart: Double
        /// End of the newest segment.
        let end: Double
        /// The remux reached the end of the file.
        let ended: Bool
    }

    func start() -> Bool {
        guard listener == nil else { return true }
        guard let nwPort = NWEndpoint.Port(rawValue: 0) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only, like the cache server: AVPlayer reaches it at
        // 127.0.0.1, and nothing else on the network has any business pulling
        // the viewer's audio stream off this box.
        params.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: params, on: nwPort) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self?.respond(to: path, on: connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = self.listener?.port?.rawValue {
                self.port = p
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        queue.sync {
            initSegment = nil
            files.removeAll()
            segments.removeAll()
            firstRetained = 0
            longestSegment = 0
            ended = false
        }
    }

    func setInit(_ data: Data) {
        queue.sync { initSegment = data }
    }

    func addSegment(_ data: Data, start: Double, duration: Double) {
        queue.sync {
            let name = "seg\(segments.count).m4s"
            segments.append(Segment(name: name, start: start, duration: duration))
            files[name] = data
            longestSegment = max(longestSegment, duration)
        }
    }

    func markEnded() {
        queue.sync { ended = true }
    }

    /// Drop the bodies of segments that end before `seconds`. The newest
    /// segment is always kept.
    func prune(before seconds: Double) {
        queue.sync {
            while firstRetained < segments.count - 1 {
                let s = segments[firstRetained]
                guard s.start + s.duration < seconds else { break }
                files[s.name] = nil
                firstRetained += 1
            }
        }
    }

    /// nil until the init segment and at least one media segment exist.
    func window() -> Window? {
        queue.sync {
            guard initSegment != nil, let first = segments.first, let last = segments.last
            else { return nil }
            return Window(origin: first.start, retainedStart: segments[firstRetained].start,
                          end: last.start + last.duration, ended: ended)
        }
    }

    /// `queue` only.
    private func playlistText() -> String {
        // Every EXTINF, rounded, must be ≤ the target duration. Fragments are
        // cut at 2 s, so 3 covers them with room; a longer one (a gap in the
        // source's audio) raises it rather than break the rule.
        let target = max(3, Int(longestSegment.rounded(.up)))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7",
                     "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-PLAYLIST-TYPE:EVENT",
                     "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-MAP:URI=\"init.mp4\""]
        lines.reserveCapacity(lines.count + segments.count * 2 + 1)
        for s in segments {
            lines.append(String(format: "#EXTINF:%.6f,", s.duration))
            lines.append(s.name)
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func respond(to path: String, on connection: NWConnection) {
        var name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let query = name.firstIndex(of: "?") { name = String(name[..<query]) }
        queue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            let body: Data?
            let type: String
            if name == "playlist.m3u8" || name.isEmpty {
                body = Data(self.playlistText().utf8)
                type = "application/vnd.apple.mpegurl"
            } else if name == "init.mp4" {
                body = self.initSegment
                type = "video/mp4"
            } else {
                body = self.files[name]
                type = "video/iso.segment"
            }
            let status = body == nil ? "404 Not Found" : "200 OK"
            let payload = body ?? Data()
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: - Orchestrator

/// Ties the pieces together for one remux: the source's E-AC-3 remuxed into
/// the loopback HLS server and played by an `AVPlayer`.
///
/// This type does not decide WHEN to play. The caller drives it from the video
/// clock (`PlayerViewModel.atmosTick`): `resume(at:)` whenever the picture is
/// running and the audio is not, `pause()` whenever the picture stops. So pause,
/// buffering, seeks and play all converge on one rule — audio follows the
/// picture — instead of each needing its own forwarding.
///
/// All times are SOURCE seconds, the axis the video engine's clock runs on.
@MainActor
final class AtmosPassthrough {
    enum ResumeResult {
        /// Working on it: waiting for audio, for the player, or for a seek.
        case pending
        /// The target is outside what this remux holds or can reach soon —
        /// start a fresh one there.
        case outOfRange
        /// The target is past the end of the file's audio.
        case finished
    }

    private let server = AtmosHLSServer()
    private var remuxer: AtmosAudioRemuxer?
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var seeking = false
    private var wantsPlay = false
    private var stopped = false

    /// The FFmpeg stream index this remux was asked for.
    private(set) var trackIndex: Int32 = -1
    /// The AVPlayer has produced sound at least once.
    private(set) var hasPlayed = false
    /// When the AVPlayer last started producing sound; nil while it isn't.
    private(set) var audibleSince: Date?

    /// A failure this session cannot recover from. Main actor.
    var onError: ((String) -> Void)?
    /// The AVPlayer started or stopped producing sound. Main actor.
    var onAudibleChange: ((Bool) -> Void)?

    /// Remuxed audio needed past the target before the AVPlayer is built, so
    /// it does not open against a playlist it immediately plays off the end of.
    private static let playerLead: Double = 6
    /// How far past the remuxed end a target may be and still be waited for.
    /// Further than this (a forward seek) the remux would have to read its way
    /// there, so a fresh one is cheaper.
    private static let waitAheadLimit: Double = 10
    /// Segment bodies kept behind the playhead, for short backward seeks.
    private static let keepBehind: Double = 30

    func start(inputURL: String, headers: [String: String]?, startAt: Double,
               trackIndex: Int32 = -1) {
        self.trackIndex = trackIndex
        guard server.start() else { fail("hls server failed"); return }
        // The remux queue writes straight into the server (which is locked by
        // its own queue), so segments land in the order they are cut.
        let server = self.server
        let remuxer = AtmosAudioRemuxer(inputURL: inputURL, headers: headers,
                                        startAt: startAt, preferredIndex: trackIndex)
        remuxer.onInit = { data in server.setInit(data) }
        remuxer.onSegment = { data, start, duration in
            server.addSegment(data, start: start, duration: duration)
        }
        remuxer.onEnded = { server.markEnded() }
        remuxer.onError = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fail(message) }
            }
        }
        self.remuxer = remuxer
        remuxer.start()
    }

    var isAudible: Bool { player?.timeControlStatus == .playing }

    /// Where the AVPlayer is, in source seconds; nil before it exists.
    var currentTime: Double? {
        guard let player, let w = server.window() else { return nil }
        let t = CMTimeGetSeconds(player.currentTime())
        guard t.isFinite else { return nil }
        return w.origin + t
    }

    /// Feed the picture's position: paces the remux and drops old segments.
    func noteVideoPlayhead(_ source: Double) {
        guard !stopped, source.isFinite else { return }
        remuxer?.playheadSeconds = source
        let audio = currentTime ?? source
        server.prune(before: min(source, audio) - Self.keepBehind)
    }

    /// Get the audio playing at `source`. Idempotent: call it every tick the
    /// picture is running and the audio is not.
    func resume(at source: Double) -> ResumeResult {
        guard !stopped, source.isFinite, let w = server.window() else { return .pending }
        if source < w.retainedStart - 0.5 { return .outOfRange }
        if w.ended, source >= w.end - 0.25 { return .finished }
        if !w.ended, source > w.end + Self.waitAheadLimit { return .outOfRange }
        wantsPlay = true
        if player == nil {
            guard server.port != 0, w.ended || w.end >= source + Self.playerLead else { return .pending }
            makePlayer()
        }
        guard let player, player.currentItem?.status == .readyToPlay else { return .pending }
        // Already asked to play and getting there, or mid-seek: leave it. A
        // stall is the caller's watchdog's to judge.
        guard player.rate == 0, !seeking else { return .pending }
        // A little audio past the target, or the AVPlayer plays off the end.
        if !w.ended, source > w.end - 2 { return .pending }
        seeking = true
        let relative = max(source - w.origin, 0)
        player.seek(to: CMTime(seconds: relative, preferredTimescale: 90_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.seeking = false
                    guard finished, self.wantsPlay, !self.stopped else { return }
                    self.player?.playImmediately(atRate: 1)
                }
            }
        }
        return .pending
    }

    func pause() {
        wantsPlay = false
        player?.pause()
    }

    /// The viewer's mute (PiP window) while this player owns the sound.
    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    func stop() {
        stopped = true
        statusObservation?.invalidate()
        statusObservation = nil
        controlObservation?.invalidate()
        controlObservation = nil
        remuxer?.cancel()
        remuxer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        server.stop()
        // The callbacks close over the player model; drop them with the session.
        onError = nil
        onAudibleChange = nil
    }

    private func makePlayer() {
        guard let url = URL(string: "http://127.0.0.1:\(server.port)/playlist.m3u8") else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // A failed item used to go unnoticed: the engine was already muted, so
        // the film played on in silence while the sync pinned the picture to a
        // clock that never moved.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "the audio stream failed to load"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fail(message) }
            }
        }
        controlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.controlStatusChanged() }
            }
        }
        self.player = player
    }

    private func controlStatusChanged() {
        guard !stopped else { return }
        let audible = isAudible
        if audible {
            hasPlayed = true
            if audibleSince == nil { audibleSince = Date() }
        } else {
            audibleSince = nil
        }
        onAudibleChange?(audible)
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        onError?(message)
    }
}
