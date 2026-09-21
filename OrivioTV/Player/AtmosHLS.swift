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
/// the init segment and each `moof`+`mdat` pair.
final class AtmosAudioRemuxer {
    /// (url, requestHeaders, startSeconds)
    private let inputURL: String
    private let headers: [String: String]?
    private let startAt: Double
    /// The FFmpeg audio stream index the player selected (-1 = first E-AC-3).
    private let preferredIndex: Int32

    /// Called on the remux queue: the init segment, then each media segment.
    var onInit: ((Data) -> Void)?
    var onSegment: ((Data) -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "orivio.atmos.remux")
    /// Set from `cancel()` on the CALLER's thread (the main actor), read by the
    /// loop in `run()` on `queue`. It must NOT go through `queue`: `run()` owns
    /// that serial queue for its whole lifetime, so an enqueued cancel block
    /// could never execute — the download ran on to EOF (or the 20-minute
    /// safety stop) against the raw CDN URL after playback had already ended,
    /// saturating Wi-Fi and CPU while the viewer was back on Home. `@Atomic`
    /// makes the flag cross the threads without the deadlock.
    @Atomic private var cancelled = false

    init(inputURL: String, headers: [String: String]?, startAt: Double,
         preferredIndex: Int32 = -1) {
        self.inputURL = inputURL
        self.headers = headers
        self.startAt = max(startAt, 0)
        self.preferredIndex = preferredIndex
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
        var onSegment: ((Data) -> Void)?
        /// fMP4 segments are ~1-2s of E-AC-3 (tens of KB); cap the buffer so a
        /// malformed muxer can't grow it without bound.
        let maxBuffer = 8 * 1024 * 1024

        func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
            pending.append(bytes, count: count)
            drain()
        }

        func append(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
            append(UnsafePointer(bytes), count: count)
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
                        // The accumulated init is everything already emitted
                        // minus this box; emit once.
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
                        onSegment?(buffer)
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
        guard let input = ictx else { onError?("alloc failed"); return }
        defer {
            if ictx != nil { avformat_close_input(&ictx) }
        }

        var opts: OpaquePointer?
        if let headers, !headers.isEmpty {
            for (key, value) in headers {
                av_dict_set(&opts, key, value, 0)
            }
        }
        // BOUND THE INPUT, like every other open in the app. Without these a
        // stalled origin (or the hybrid-cache proxy in front of it) parks this
        // remux thread inside `av_read_frame` indefinitely — no error, no
        // timeout, the worker leaked for the rest of the session. The engines
        // use the same 20s read bound; the reconnect ladder is capped too, or
        // one hung read becomes minutes of 0/1/3/7/… retries.
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
        sink.onSegment = { [weak self] data in self?.onSegment?(data) }
        let opaque = Unmanaged.passRetained(sink).toOpaque()
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
        let ioBuffer = ioRaw.assumingMemoryBound(to: UInt8.self)
        let avio = avio_alloc_context(ioBuffer, 64 * 1024, 1, opaque, nil, writeCallback, nil)
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

        // Seek to the resume point if asked.
        if startAt > 1 {
            let ts = Int64(startAt * Double(AV_TIME_BASE))
            let micros = AVRational(num: 1, den: AV_TIME_BASE)
            _ = av_seek_frame(ictx, audioIndex, av_rescale_q(ts, micros, srcTB), AVSEEK_FLAG_BACKWARD)
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let maxSegmentSeconds = 20 * 60.0   // safety stop, not a normal path
        let wallStart = Date()
        while !cancelled {
            if Date().timeIntervalSince(wallStart) > maxSegmentSeconds { break }
            guard av_read_frame(ictx, packet) >= 0 else { break }
            defer { av_packet_unref(packet) }
            guard packet!.pointee.stream_index == audioIndex else { continue }
            guard packet!.pointee.pts != Int64.min else { continue }
            // Rescale into the output stream's timebase.
            let pts = av_rescale_q(packet!.pointee.pts, srcTB, stream.pointee.time_base)
            let dts = av_rescale_q(packet!.pointee.dts, srcTB, stream.pointee.time_base)
            packet!.pointee.pts = pts
            packet!.pointee.dts = dts
            packet!.pointee.duration = av_rescale_q(packet!.pointee.duration, srcTB, stream.pointee.time_base)
            packet!.pointee.stream_index = outIndex
            if av_interleaved_write_frame(out, packet) < 0 {
                onError?("write failed")
                break
            }
        }
        av_write_trailer(out)
        // The sink retains a pending tail; flush anything left as a segment.
        Unmanaged<Sink>.fromOpaque(opaque).release()
        _ = avio
        if !cancelled { onEnded?() }
    }
}

// MARK: - Loopback HLS server

/// Serves the remuxed playlist + init + segments over loopback HTTP. AVPlayer
/// only accepts HLS over a network URL, never a local file.
final class AtmosHLSServer {
    private let queue = DispatchQueue(label: "orivio.atmos.server")
    private var listener: NWListener?
    /// Written on `queue` by the listener's state handler, read on the main
    /// actor by `AtmosPassthrough.startPlayerIfNeeded` — worth the lock rather
    /// than a cross-thread `UInt16` race.
    @Atomic private(set) var port: UInt16 = 0

    /// path → body. Replaced per session.
    private var files: [String: Data] = [:]
    private var playlist = ""
    private var segments: [(name: String, seconds: Double)] = []

    var isRunning: Bool { listener != nil }

    func start() -> Bool {
        guard listener == nil else { return true }
        guard let nwPort = NWEndpoint.Port(rawValue: 0) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
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
        queue.sync {
            files.removeAll()
            segments.removeAll()
            playlist = ""
        }
    }

    func reset(playlist: String) {
        queue.sync {
            files.removeAll()
            segments.removeAll()
            self.playlist = playlist
        }
    }

    func addSegment(name: String, data: Data, seconds: Double) {
        queue.sync {
            files[name] = data
            segments.append((name, seconds))
        }
    }

    func updatePlaylist() {
        queue.sync {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7",
                         "#EXT-X-TARGETDURATION:\(Int(ceil(segments.map(\.seconds).max() ?? 2)))",
                         "#EXT-X-MEDIA-SEQUENCE:0",
                         "#EXT-X-MAP:URI=\"init.mp4\""]
            for s in segments {
                lines.append(String(format: "#EXTINF:%.3f,", s.seconds))
                lines.append(s.name)
            }
            // The playlist is rewritten as segments arrive; without ENDLIST
            // AVPlayer treats it as live and keeps polling (which is what we
            // want until the remux finishes).
            playlist = lines.joined(separator: "\n") + "\n"
        }
    }

    /// Replace the whole file set (used when a session restarts).
    func replaceAll(playlist: String, files: [String: Data], order: [(String, Double)]) {
        queue.sync {
            self.files = files
            self.segments = order
            self.playlist = playlist
        }
    }

    private func respond(to path: String, on connection: NWConnection) {
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        queue.async { [weak self] in
            guard let self else { return }
            let body: Data
            let type: String
            if name == "playlist.m3u8" || name.isEmpty {
                body = Data(self.playlist.utf8)
                type = "application/vnd.apple.mpegurl"
            } else if name == "init.mp4" {
                body = self.files["init.mp4"] ?? Data()
                type = "video/mp4"
            } else if let data = self.files[name] {
                body = data
                type = "video/iso.segment"
            } else {
                body = Data()
                type = "application/octet-stream"
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: - Orchestrator

/// Ties the three pieces together for one playback: remux the source's E-AC-3
/// into the loopback HLS server and play it with an `AVPlayer`.
///
/// `currentTime` is in SOURCE seconds (the AVPlayer's 0-based timeline plus the
/// remux start offset), which is the same axis the video engine's clock runs
/// on — so the caller can align the two.
@MainActor
final class AtmosPassthrough {
    private let server = AtmosHLSServer()
    private var remuxer: AtmosAudioRemuxer?
    private var player: AVPlayer?
    private(set) var startAt: Double = 0
    /// Fired once the AVPlayer exists and the playlist has its first segment.
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    var isActive: Bool { player != nil }
    var playerForSync: AVPlayer? { player }

    func start(inputURL: String, headers: [String: String]?, startAt: Double,
               trackIndex: Int32 = -1) {
        self.startAt = max(startAt, 0)
        guard server.start() else { onError?("hls server failed"); return }
        server.replaceAll(
            playlist: "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MAP:URI=\"init.mp4\"\n",
            files: [:], order: []
        )
        let remuxer = AtmosAudioRemuxer(inputURL: inputURL, headers: headers,
                                        startAt: self.startAt, preferredIndex: trackIndex)
        self.remuxer = remuxer
        var segmentIndex = 0
        remuxer.onInit = { [weak self] data in
            Task { @MainActor in self?.server.addSegment(name: "init.mp4", data: data, seconds: 0) }
        }
        remuxer.onSegment = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                let name = "seg\(segmentIndex).m4s"
                segmentIndex += 1
                self.server.addSegment(name: name, data: data, seconds: 2.0)
                self.server.updatePlaylist()
                self.startPlayerIfNeeded()
            }
        }
        remuxer.onError = { [weak self] message in
            Task { @MainActor in self?.onError?(message) }
        }
        remuxer.start()
    }

    private func startPlayerIfNeeded() {
        guard player == nil, server.port != 0 else { return }
        guard let url = URL(string: "http://127.0.0.1:\(server.port)/playlist.m3u8") else { return }
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        onReady?()
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    /// Seek on the SOURCE axis; the AVPlayer is 0-based from `startAt`.
    func seek(to sourceSeconds: Double) {
        let relative = max(sourceSeconds - startAt, 0)
        player?.seek(to: CMTime(seconds: relative, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Source-seconds position, aligned with the video clock's axis.
    var currentTime: Double {
        guard let player else { return startAt }
        return startAt + CMTimeGetSeconds(player.currentTime())
    }

    var rate: Float {
        get { player?.rate ?? 0 }
        set { player?.rate = newValue }
    }

    func stop() {
        remuxer?.cancel()
        remuxer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        server.stop()
    }
}
