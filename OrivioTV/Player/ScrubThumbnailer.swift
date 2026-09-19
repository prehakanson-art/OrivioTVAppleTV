import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import UIKit

/// One scrub-preview frame.
struct ScrubThumbnail {
    let image: UIImage
    let time: Double
}

extension ScrubThumbnailer {
    /// Dev-only harness: `-thumbnailSelfTest <path-or-URL>` runs the grabber
    /// against one file and logs what came back, so the frame grabber can be
    /// verified on its own (the sim can't reach a real debrid stream). Also
    /// exercises the cancel path. Logs under "OrivioThumbTest".
    static func runSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-thumbnailSelfTest"),
              args.index(after: flag) < args.endIndex else { return }
        let target = args[args.index(after: flag)]
        let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(string: target)
        guard let url else {
            NSLog("[OrivioThumbTest] bad target %@", target)
            return
        }
        Task.detached(priority: .utility) {
            let started = Date()
            let thumbs = await ScrubThumbnailer(url: url, count: 12).generate()
            NSLog("[OrivioThumbTest] %d frames in %.2fs from %@",
                  thumbs.count, Date().timeIntervalSince(started), url.lastPathComponent)
            for thumb in thumbs {
                // Also sample a pixel: a channel-order mistake (BGRA vs RGBA)
                // compiles and produces plausible-looking frames while tinting
                // every preview, so the test asserts colour, not just size.
                let rgb = Self.samplePixel(thumb.image)
                NSLog("[OrivioThumbTest]   t=%.3fs size=%.0fx%.0f rgb=(%d,%d,%d)",
                      thumb.time, thumb.image.size.width, thumb.image.size.height,
                      rgb.0, rgb.1, rgb.2)
            }
            // Cancel path: aborting must return nothing and not hang.
            let cancelStart = Date()
            let cancellable = ScrubThumbnailer(url: url, count: 12)
            Task.detached { cancellable.cancel() }
            let cancelled = await cancellable.generate()
            NSLog("[OrivioThumbTest] cancel → %d frames in %.2fs (expect 0, fast)",
                  cancelled.count, Date().timeIntervalSince(cancelStart))

            // Fine-tune window: the slot pass against the sweep, over the same
            // seconds of film. `-thumbnailWindow <centre> <half> <spacing>`.
            guard let windowFlag = args.firstIndex(of: "-thumbnailWindow"),
                  args.index(windowFlag, offsetBy: 3, limitedBy: args.endIndex - 1) != nil,
                  let centre = Double(args[windowFlag + 1]),
                  let half = Double(args[windowFlag + 2]),
                  let spacing = Double(args[windowFlag + 3])
            else { return }
            let range = max(centre - half, 0)...(centre + half)
            let slots = max(4, Int((range.upperBound - range.lowerBound) / spacing))
            for dense in [false, true] {
                let started = Date()
                let pass = ScrubThumbnailer(
                    url: url, count: slots, budgetSeconds: 120, range: range,
                    denseSpacing: dense ? spacing : nil, denseCenter: centre
                )
                let frames = await pass.generate().sorted { $0.time < $1.time }
                let gaps = zip(frames, frames.dropFirst()).map { $1.time - $0.time }
                let worst = gaps.max() ?? 0
                let mean = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
                NSLog("[OrivioThumbTest] %@ window %.0f±%.0fs @%.1fs: %d frames in %.2fs, mean gap %.2fs, worst %.2fs",
                      dense ? "SWEEP" : "slots ", centre, half, spacing,
                      frames.count, Date().timeIntervalSince(started), mean, worst)
            }
        }
    }

    /// Top-left pixel of a preview as (r, g, b), for the self-test only.
    private static func samplePixel(_ image: UIImage) -> (Int, Int, Int) {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= 4
        else { return (-1, -1, -1) }
        // Buffer is BGRA in memory (byteOrder32Little + noneSkipFirst).
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }
}

/// Scrub-preview frame grabber.
///
/// Replaces KSPlayer's `ThumbnailController`, which could not be used safely
/// against a high-bitrate remote file for three reasons:
///
/// 1. **It leaked every packet it read.** Its inner loop calls
///    `av_read_frame(ctx, &packet)` repeatedly and only `av_packet_unref`s ONCE,
///    after all the seeks are done. `av_read_frame` doesn't free what the packet
///    already holds, so each read past the first leaked its buffer. The leak
///    scales with PACKET SIZE, i.e. with bitrate — a 4K (or high-bitrate 1080p)
///    stream leaks megabytes per read, tens of reads per seek, 36 seeks: enough
///    to get the app jetsam-killed mid-playback regardless of how small the file
///    is. Here every read is unref'd in a `defer`.
/// 2. **It could not be cancelled or timed out.** It opened the input with no
///    options and no interrupt callback, so `Task.isCancelled` couldn't stop a
///    blocked network read: the pass kept a second connection and a full decoder
///    alive after the player closed. Here an AVIO interrupt callback polls a
///    cancel flag, the same mechanism DVRemuxer uses, plus `rw_timeout`.
/// 3. **It used every core.** Default `thread_count` on a software decode of 4K
///    keyframes competes directly with the playback decode. Capped at 2 here.
///
/// Decoding is software (these are keyframes, and spinning up a second
/// VideoToolbox session next to playback is worse), on its own thread, at a
/// bounded frame count with an overall wall-clock budget.
/// Unchecked: `cancelled` is the only cross-thread state and it goes through
/// `@Atomic`; everything else is touched solely on the worker thread below.
final class ScrubThumbnailer: @unchecked Sendable {
    private let url: URL
    private let count: Int
    private let thumbWidth: Int32
    /// Overall budget. A slow remote source must not hold a second connection
    /// and decoder open for the whole movie.
    private let budgetSeconds: TimeInterval
    /// Addon-declared request headers (behaviorHints.proxyHeaders). Same
    /// requirement as playback: the sources that need a Referer answer this
    /// second connection with a 403 without one.
    private let headers: [String: String]?

    @Atomic private var cancelled = false

    /// One frame per this many seconds of runtime, which is what the scrub
    /// preview is specified in. `frameCount(forDuration:)` turns it into a
    /// count, clamped so a long film can't blow the memory budget.
    static let secondsPerFrame: Double = 30
    /// Ceiling on frames held in memory. At 256x144 RGBA a frame is ~147 KB, so
    /// 240 is ~35 MB — the most this is worth spending next to a live decode.
    /// A film longer than 2 hours simply gets a coarser spacing than 30s.
    /// Tiered: these are held for the whole scrub on a 3 GB box.
    static var maxFrames: Int {
        PerformanceProfile.isLowPower ? 60 : (PerformanceProfile.isMidPower ? 100 : 240)
    }

    /// Frames for a runtime, at one every `secondsPerFrame`.
    static func frameCount(forDuration duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 36 }
        return max(12, min(Int(duration / secondsPerFrame), maxFrames))
    }

    /// Density while SCRUBBING across cached film: one frame every 15 seconds
    /// of runtime. Used by the cache-driven coarse pass (its target spacing,
    /// memory permitting) and by the wide dense pass that fills in around the
    /// finger during a drag.
    static let scrubSecondsPerFrame: Double = 15
    /// Density for the wide pass that follows a DRAG across the bar, when the
    /// film is coming off the local cache: a seek plus one keyframe decode per
    /// slot is cheap there, and 15 seconds a frame meant a fast drag across a
    /// minute of film showed four pictures. Still keyframe-per-slot — a drag
    /// covers far too much ground to decode through.
    static let dragSecondsPerFrame: Double = 8
    /// Density while FINE-TUNING (the wheel is engaged): one frame every two
    /// seconds, over a narrow window either side of the playhead — a distinct
    /// picture under every couple of steps of the wheel.
    ///
    /// This is what the SLOT pass aims for, and a slot can only land on a
    /// keyframe, so on a file whose keyframes are five or ten seconds apart it
    /// is an aim rather than a result. `fineSweepSeconds` is the density the
    /// sweep reaches between them.
    static let fineSecondsPerFrame: Double = 2
    /// Density the fine-tune SWEEP keeps, off the local cache: one frame per
    /// second of runtime. The wheel turns 24 seconds per revolution, so a
    /// second is about fifteen degrees — a distinct picture under every small
    /// movement, which is the point of fine-tuning.
    static let fineSweepSeconds: Double = 1
    static let fineWindowSeconds: Double = 90

    /// The order to visit frame slots in: progressive refinement, not front to
    /// back. Yields 0, ½, ¼, ¾, ⅛, ⅜ … so the film is covered COARSELY FIRST
    /// and then filled in.
    ///
    /// This matters because the pass is bounded by a wall-clock budget and each
    /// frame costs a network seek. Walking 0…N sequentially meant that when the
    /// budget ran out — which on a remote source it reliably did — every frame
    /// collected was from the front of the film and everything after the
    /// cut-off had none at all. Scrub into the back half and the nearest frame
    /// was half an hour away: present, but showing the wrong scene. Visiting
    /// slots in this order means whenever the pass stops, what it has is spread
    /// evenly over the whole runtime.
    static func scanOrder(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var order: [Int] = []
        var seen = Set<Int>()
        var step = count
        while step > 1 {
            var i = 0
            while i < count {
                if seen.insert(i).inserted { order.append(i) }
                i += step
            }
            step /= 2
        }
        for i in 0 ..< count where seen.insert(i).inserted { order.append(i) }
        return order
    }

    /// Seconds of runtime to cover, or nil for the whole file. A bounded range
    /// is what the fine-tune pass uses: a frame every two seconds over a window
    /// around the playhead, which is far too dense to run across a whole film.
    private let range: ClosedRange<Double>?

    /// Polled between frames: false means "playback needs the bandwidth and the
    /// CPU right now", and the pass waits rather than competing.
    ///
    /// This exists because the pass is a SECOND connection and a SECOND FFmpeg
    /// decoder running against live playback. It used to be held behind a gate
    /// that waited for the playback cache to fill, which made previews arrive
    /// minutes late (or never); removing that gate got the previews but handed
    /// the stutter back. Yielding per frame keeps both: previews start
    /// immediately and step aside whenever the buffer dips.
    private let shouldProceed: (@Sendable () -> Bool)?

    /// Pause between frames — the pass's DUTY CYCLE against live playback.
    ///
    /// `shouldProceed` stands the pass down when the engine's buffer dips, but
    /// a healthy buffer is not the same as a spare CPU: on the 3 GB Apple TV 4K
    /// a background pass software-decoding 4K keyframes visibly juddered the
    /// picture while every buffer reading looked fine. Standing the pass down
    /// entirely while playing fixed the judder and cost the previews — the
    /// probe then read `coarse=0` for whole sessions with nothing to fall back
    /// on. A longer breath is the setting between those two: coverage still
    /// builds, just slowly, at a fraction of the contention.
    private let breathSeconds: TimeInterval

    /// SUB-KEYFRAME DENSITY: decode CONTINUOUSLY through the range and keep a
    /// frame every this many seconds, instead of one keyframe per slot. nil
    /// (the default) is the keyframe-per-slot pass every other caller wants.
    ///
    /// A seek can only land on a keyframe, so the slot pass can never show a
    /// picture between two of them — and a keyframe every 5-10 seconds is
    /// ordinary for a remux. The fine-tune wheel turns 24 seconds per
    /// revolution, so a small nudge asks for a second or two: the viewer moves
    /// the wheel and the same still sits there, which is the whole complaint.
    /// The only way to a picture BETWEEN keyframes is to decode the frames
    /// between them, so that is what this does — one seek, then a straight
    /// read forward, keeping one frame per `denseSpacing`.
    ///
    /// It is priced accordingly, and it is opt-in for that reason: every frame
    /// in the swept span is decoded (measured: skipping B-frames saves under a
    /// third, so there is no cheap version of this), and every byte of it is
    /// read. Only the fine-tune pass asks for it, only off the local cache,
    /// and `sweepFloorFPS` below stands it down on hardware that cannot hold
    /// the pace — on a 4K remux the software decode is far too slow, so the
    /// sweep gives up early and the keyframe pass that follows still fills the
    /// window at the old density.
    private let denseSpacing: Double?
    /// Where the sweep starts from, so the frames nearest the viewer's
    /// position are decoded first and a budget that runs out costs the EDGES
    /// of the window rather than its middle. Defaults to the range's midpoint.
    private let denseCenter: Double?

    init(
        url: URL, count: Int = 36, thumbWidth: Int32 = 256,
        budgetSeconds: TimeInterval = 60, headers: [String: String]? = nil,
        range: ClosedRange<Double>? = nil,
        breathSeconds: TimeInterval = 0.08,
        denseSpacing: Double? = nil,
        denseCenter: Double? = nil,
        shouldProceed: (@Sendable () -> Bool)? = nil
    ) {
        self.url = url
        self.count = count
        self.thumbWidth = thumbWidth
        self.budgetSeconds = budgetSeconds
        self.headers = headers
        self.range = range
        self.breathSeconds = breathSeconds
        self.denseSpacing = denseSpacing
        self.denseCenter = denseCenter
        self.shouldProceed = shouldProceed
    }

    /// Decoded frames per second of wall clock below which a sweep is not
    /// worth its contention: it would take longer than the scrub itself and it
    /// is competing with the picture on screen for the same cores. Measured
    /// after the first `sweepRateWindow` frames and then continuously.
    ///
    /// 60 is about two and a half times playback speed at 24fps: a 1080p
    /// stream clears it comfortably on every box this runs on, a 4K remux's
    /// software decode does not come close, and that is exactly the split the
    /// sweep should make on its own rather than by guessing at the hardware.
    private static let sweepFloorFPS: Double = 60
    private static let sweepRateWindow = 48
    /// Hard ceiling on frames decoded in one sweeping pass, whatever the rate
    /// or the budget says — the backstop that makes the worst case finite.
    ///
    /// Tiered, because the ceiling is really a time budget: the 3 GB A10X
    /// decodes 1080p in software at something like a hundred frames a second
    /// with the single thread this pass is allowed, so 600 frames is about six
    /// seconds of work for ~25 seconds of swept film — most of the window,
    /// and the forward half (where the wheel is heading) is swept first. A
    /// current box clears the whole window inside the same wall clock.
    private static var sweepDecodeCap: Int {
        PerformanceProfile.isMidPower ? 600 : 1500
    }

    /// Aborts promptly even from a blocked network read (the interrupt callback
    /// below polls this).
    func cancel() { cancelled = true }

    /// Generate the frames off the caller's thread. Returns whatever was
    /// produced before the budget, the end of the file, or a cancel.
    ///
    /// `onProgress` is called from the worker thread with the frames so far,
    /// sorted, every time a new one lands — the pass can run for minutes on a
    /// long film, and the preview is far more useful filling in as it goes than
    /// arriving all at once at the end.
    func generate(onProgress: (([ScrubThumbnail]) -> Void)? = nil) async -> [ScrubThumbnail] {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(returning: run(onProgress: onProgress))
            }
            thread.name = "ScrubThumbnailer"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    // MARK: - Worker thread

    private func run(onProgress: (([ScrubThumbnail]) -> Void)? = nil) -> [ScrubThumbnail] {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        var thumbnails: [ScrubThumbnail] = []
        // Progress publishes are throttled to ~1 Hz: each one sorts the whole
        // set and hands a fresh array cross-actor, and per-frame that was
        // O(n² log n) over a long pass — with a main-actor hop and a bar
        // re-render per decoded frame on the other side. The completed set is
        // returned (and published) regardless, so nothing is lost.
        var lastProgressAt: CFAbsoluteTime = 0

        var formatCtx = avformat_alloc_context()
        guard let inCtx = formatCtx else { return [] }
        defer { avformat_close_input(&formatCtx) }

        // Cancellable: FFmpeg polls this from inside blocking reads.
        var interrupt = AVIOInterruptCB()
        interrupt.opaque = Unmanaged.passUnretained(self).toOpaque()
        interrupt.callback = { opaque -> Int32 in
            guard let opaque else { return 0 }
            return Unmanaged<ScrubThumbnailer>.fromOpaque(opaque)
                .takeUnretainedValue().cancelled ? 1 : 0
        }
        inCtx.pointee.interrupt_callback = interrupt

        // Same network posture as playback, so a flaky CDN errors out instead of
        // hanging this thread forever.
        var openOpts: OpaquePointer?
        av_dict_set(&openOpts, "reconnect", "1", 0)
        av_dict_set(&openOpts, "reconnect_streamed", "1", 0)
        av_dict_set(&openOpts, "reconnect_delay_max", "5", 0)
        av_dict_set(&openOpts, "rw_timeout", "15000000", 0)
        av_dict_set(&openOpts, "multiple_requests", "1", 0)
        // Keep the probe cheap — we only need the video stream's parameters.
        av_dict_set(&openOpts, "probesize", String(2 << 20), 0)
        av_dict_set(&openOpts, "analyzeduration", "1000000", 0)
        if let headers, !headers.isEmpty {
            let joined = headers.map { "\($0.key):\($0.value)\r\n" }.joined()
            av_dict_set(&openOpts, "headers", joined, 0)
        }
        let path = url.isFileURL ? url.path : url.absoluteString
        let opened = avformat_open_input(&formatCtx, path, nil, &openOpts)
        av_dict_free(&openOpts)
        guard opened == 0, formatCtx != nil, !cancelled else { return [] }
        guard avformat_find_stream_info(formatCtx, nil) >= 0, !cancelled else { return [] }

        // First real (non-cover-art) video stream.
        var videoIndex = -1
        for i in 0 ..< Int(formatCtx!.pointee.nb_streams) {
            guard let stream = formatCtx!.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0
            else { continue }
            videoIndex = i
            break
        }
        guard videoIndex >= 0, let videoStream = formatCtx!.pointee.streams[videoIndex],
              let par = videoStream.pointee.codecpar
        else { return [] }

        guard let codec = avcodec_find_decoder(par.pointee.codec_id),
              let codecCtx = avcodec_alloc_context3(codec)
        else { return [] }
        var freeCtx: UnsafeMutablePointer<AVCodecContext>? = codecCtx
        defer { avcodec_free_context(&freeCtx) }
        guard avcodec_parameters_to_context(codecCtx, par) >= 0 else { return [] }
        // Leave cores for the playback decode; previews are never urgent. The
        // 3 GB / A10X box gets a single thread — this is a SOFTWARE decode of
        // 4K keyframes running next to a live 4K decode there.
        codecCtx.pointee.thread_count = PerformanceProfile.isMidPower ? 1 : 2
        // Keyframes only: skip non-reference frames and in-loop deblocking.
        codecCtx.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(codecCtx, codec, nil) >= 0 else { return [] }

        let srcW = codecCtx.pointee.width
        let srcH = codecCtx.pointee.height
        guard srcW > 0, srcH > 0 else { return [] }
        let dstW = min(thumbWidth, srcW)
        let dstH = max(dstW * srcH / srcW, 1)

        // Built from the FIRST DECODED FRAME's real pixel format, not from
        // `codecCtx.pix_fmt`: that field can still be AV_PIX_FMT_NONE before any
        // frame is decoded (and a decoder may hand back a different format than
        // the container declared), which would have silently disabled previews.
        var scaler: OpaquePointer?
        var scalerFormat: Int32 = -1   // AV_PIX_FMT_NONE
        // The scaler's SOURCE geometry is tracked alongside its format. It used
        // to be built once from `codecCtx.width/height` and then fed
        // `frame.pointee.height` as the slice height — so a decoder that handed
        // back a frame of a different size than the container declared (a
        // resolution change mid-file, or a container that simply lies) had
        // sws_scale reading past the end of the source planes. Rebuilding on a
        // geometry change as well as a format change makes that impossible.
        var scalerWidth: Int32 = 0
        var scalerHeight: Int32 = 0
        defer { if let scaler { sws_freeContext(scaler) } }

        guard let packet = av_packet_alloc() else { return [] }
        var freePacket: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&freePacket) }
        guard let frame = av_frame_alloc() else { return [] }
        var freeFrame: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&freeFrame) }

        // Seek targets spread across the file, in the video stream's time base.
        let timeBase = videoStream.pointee.time_base
        let duration = av_rescale_q(
            formatCtx!.pointee.duration,
            AVRational(num: 1, den: AV_TIME_BASE),
            timeBase
        )
        guard duration > 0 else { return [] }
        let startTime = videoStream.pointee.start_time == Int64.min ? 0 : videoStream.pointee.start_time

        // Whole file, or the window the caller asked for — converted from
        // seconds into the stream's own time base.
        let perSecond = Int64((1.0 / av_q2d(timeBase)).rounded())
        let spanStart: Int64
        let spanLength: Int64
        if let range {
            let lo = max(Int64(range.lowerBound) * perSecond, 0)
            let hi = min(Int64(range.upperBound) * perSecond, duration)
            spanStart = lo
            spanLength = max(hi - lo, 1)
        } else {
            spanStart = 0
            spanLength = duration
        }
        let interval = max(spanLength / Int64(count), 1)

        /// Publish what has been decoded so far, at most once a second —
        /// `force` for the end of a phase, where the next publish may be a
        /// whole slot pass away.
        func publishProgress(force: Bool = false) {
            guard !cancelled, onProgress != nil, !thumbnails.isEmpty else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard force || now - lastProgressAt >= 1 else { return }
            lastProgressAt = now
            onProgress?(thumbnails.sorted { $0.time < $1.time })
        }

        /// Scale the frame the decoder just handed back, stamp it with its own
        /// time and keep it. Shared by the sweep and the slot pass so there is
        /// ONE scaler lifecycle: it is rebuilt here whenever the decoded format
        /// or geometry changes, exactly as it was when only the slot pass
        /// existed. Returns the frame's time, or nil when it could not be
        /// scaled (the callers stop that slot/sweep, as before).
        func keep(_ frame: UnsafeMutablePointer<AVFrame>, fallbackStamp: Int64) -> Double? {
            if scaler == nil || scalerFormat != frame.pointee.format
                || scalerWidth != frame.pointee.width
                || scalerHeight != frame.pointee.height {
                if let existing = scaler { sws_freeContext(existing) }
                scalerFormat = frame.pointee.format
                scalerWidth = frame.pointee.width
                scalerHeight = frame.pointee.height
                guard scalerWidth > 0, scalerHeight > 0 else { return nil }
                scaler = sws_getContext(
                    scalerWidth, scalerHeight, AVPixelFormat(rawValue: scalerFormat),
                    dstW, dstH, AV_PIX_FMT_BGRA,
                    SWS_BILINEAR, nil, nil, nil
                )
            }
            guard let scaler else { return nil }
            guard let image = Self.image(
                from: frame, scaler: scaler, width: dstW, height: dstH
            ) else { return nil }
            let stamp = frame.pointee.best_effort_timestamp == Int64.min
                ? fallbackStamp : frame.pointee.best_effort_timestamp
            let seconds = max(Double(stamp - startTime) * av_q2d(timeBase), 0)
            thumbnails.append(ScrubThumbnail(image: image, time: seconds))
            publishProgress()
            return seconds
        }

        /// ONE seek, then a straight read forward through `from`…`to`, keeping
        /// a frame every `spacing` seconds — the frames BETWEEN keyframes that
        /// a per-slot seek can never reach (see `denseSpacing`).
        ///
        /// Returns false when the sweep stood itself down — too slow for the
        /// box, or at the decode cap — which tells the caller not to sweep the
        /// rest either. A normal finish (window covered, end of file, a byte
        /// range the cache does not hold) returns true.
        func sweep(from: Double, to: Double, spacing: Double,
                   decoded: inout Int) -> Bool {
            guard to > from, spacing > 0 else { return true }
            // Straight through the time base rather than the rounded
            // ticks-per-second above: 1001/24000 rounds to 24 and puts a
            // 23.976fps file a tenth of a second out by the end of a window.
            let startPTS = Int64(from / av_q2d(timeBase)) + startTime
            avcodec_flush_buffers(codecCtx)
            guard av_seek_frame(formatCtx, Int32(videoIndex), startPTS, AVSEEK_FLAG_BACKWARD) >= 0
            else { return true }
            var nextKeep = from
            var sweptHere = 0
            var sinceCheck = 0
            let sweepStarted = Date()
            while !cancelled, Date() < deadline {
                if decoded >= Self.sweepDecodeCap { return false }
                // EVERY packet is unref'd, sweeping or not — the rule this
                // whole file exists to keep.
                guard av_read_frame(formatCtx, packet) >= 0 else { return true }
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == Int32(videoIndex) else { continue }
                let sent = avcodec_send_packet(codecCtx, packet)
                guard sent >= 0 || sent == -35 || sent == Int32(-EAGAIN) else { return true }
                // Drain everything this packet produced before reading the
                // next one: a sweep wants every frame, not the first.
                while true {
                    let received = avcodec_receive_frame(codecCtx, frame)
                    if received < 0 { break }   // EAGAIN — feed it more packets
                    defer { av_frame_unref(frame) }
                    decoded += 1
                    sweptHere += 1
                    sinceCheck += 1
                    let stamp = frame.pointee.best_effort_timestamp == Int64.min
                        ? startPTS : frame.pointee.best_effort_timestamp
                    let seconds = max(Double(stamp - startTime) * av_q2d(timeBase), 0)
                    // Past the window: the seek landed on the keyframe BEFORE
                    // `from`, so the first frames are behind it and kept only
                    // if they fall on the cadence; the far end stops here.
                    if seconds > to { return true }
                    if seconds + 0.001 >= nextKeep {
                        guard keep(frame, fallbackStamp: stamp) != nil else { return true }
                        nextKeep = seconds + spacing
                    }
                }
                // Roughly once per second of video: let playback have the
                // cores back if it needs them, and re-judge the pace.
                if sinceCheck >= 24 {
                    sinceCheck = 0
                    while let shouldProceed, !shouldProceed(), !cancelled, Date() < deadline {
                        Thread.sleep(forTimeInterval: 1)
                    }
                    if sweptHere >= Self.sweepRateWindow {
                        let rate = Double(sweptHere) / max(Date().timeIntervalSince(sweepStarted), 0.001)
                        if rate < Self.sweepFloorFPS { return false }
                    }
                }
            }
            return false
        }

        // The dense phase, when the caller asked for one. Whatever it covers,
        // the slot pass below still runs and fills in the rest at keyframe
        // density, so a sweep that stands down early costs detail, never the
        // window itself.
        if let denseSpacing, denseSpacing > 0 {
            let spanSeconds = Double(spanLength) * av_q2d(timeBase)
            let lowerSec = Double(spanStart) * av_q2d(timeBase)
            let upperSec = lowerSec + spanSeconds
            let centre = min(max(denseCenter ?? (lowerSec + spanSeconds / 2), lowerSec), upperSec)
            var decoded = 0
            // Forward from where the viewer is standing, then back over what
            // is behind them: a budget that runs out costs the EDGES of the
            // window rather than the part under the wheel.
            let sweepStarted = Date()
            if sweep(from: centre, to: upperSec, spacing: denseSpacing, decoded: &decoded) {
                _ = sweep(from: lowerSec, to: centre, spacing: denseSpacing, decoded: &decoded)
            }
            publishProgress(force: true)
            // What the sweep actually managed, so "fine-tuning still steps a
            // keyframe at a time" is answerable from the live probe instead of
            // by guessing at the hardware.
            let elapsed = max(Date().timeIntervalSince(sweepStarted), 0.001)
            PlayerProbe.event("preview", String(
                format: "sweep %.0f-%.0fs @%.1fs: kept %d, decoded %d in %.1fs (%.0f fps, floor %.0f)",
                lowerSec, upperSec, denseSpacing, thumbnails.count, decoded,
                elapsed, Double(decoded) / elapsed, Self.sweepFloorFPS))
        }

        for index in Self.scanOrder(count) {
            if cancelled || Date() >= deadline { break }
            // Stand aside while playback is struggling. Checked BEFORE the seek,
            // because a seek is the expensive part: a fresh range request on the
            // second connection, competing with the one feeding the screen.
            while let shouldProceed, !shouldProceed(), !cancelled, Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
            }
            if cancelled || Date() >= deadline { break }
            // A short breath between frames regardless, so a healthy buffer
            // isn't hammered flat by a back-to-back run of seeks either.
            Thread.sleep(forTimeInterval: breathSeconds)
            let target = spanStart + interval * Int64(index) + startTime
            // Already swept: decoding this slot would only produce a second
            // ago of the same scene the dense phase has covered.
            if let denseSpacing {
                let targetSeconds = Double(target - startTime) * av_q2d(timeBase)
                if thumbnails.contains(where: { abs($0.time - targetSeconds) <= denseSpacing }) {
                    continue
                }
            }
            avcodec_flush_buffers(codecCtx)
            // SKIP THE SLOT, DON'T ABANDON THE PASS. `break` here left one
            // refused seek deciding the whole set: the cache-only lane answers
            // 416/503 for any byte range it does not already hold, so a single
            // slot over an evicted or not-yet-fetched stretch returned ZERO
            // frames for the entire window — and `scanOrder` deliberately puts
            // the middle slot first, which on a fresh scrub is the one least
            // likely to be cached. Every other slot was perfectly fetchable.
            guard av_seek_frame(formatCtx, Int32(videoIndex), target, AVSEEK_FLAG_BACKWARD) >= 0
            else { continue }

            // Read until this stream yields a decodable frame. EVERY packet is
            // unref'd — the whole point of this file.
            var reads = 0
            while !cancelled, Date() < deadline {
                let readResult = av_read_frame(formatCtx, packet)
                if readResult < 0 { break }
                defer { av_packet_unref(packet) }
                reads += 1
                // Don't chase a frame forever inside one seek window.
                if reads > 240 { break }
                guard packet.pointee.stream_index == Int32(videoIndex) else { continue }
                // EAGAIN from send means "drain output first", not a broken
                // stream — fall through to receive instead of abandoning the
                // whole seek slot (B-frame HEVC does this on the 2nd packet).
                let sent = avcodec_send_packet(codecCtx, packet)
                guard sent >= 0 || sent == -35 || sent == Int32(-EAGAIN) else { break }
                let received = avcodec_receive_frame(codecCtx, frame)
                if received < 0 {
                    // EAGAIN just means "feed me more packets".
                    if received == -35 || received == Int32(-EAGAIN) { continue }
                    break
                }
                defer { av_frame_unref(frame) }
                // Scaler rebuild, stamp and publish all live in `keep` now, so
                // the sweep above and this pass cannot drift apart.
                _ = keep(frame, fallbackStamp: target)
                break
            }
        }
        // KEEP WHAT WAS DECODED. Discarding the lot on cancel threw away real
        // work at exactly the moment it was most wanted: the fine pass is
        // cancelled and re-centred as the finger moves, so a scrub that travels
        // at all cancelled every pass mid-flight and published nothing, however
        // many frames had already been decoded. A frame from a window the
        // viewer has just left is still a better preview than no frame.
        return thumbnails
    }

    /// Scale one decoded frame into a BGRA CGImage-backed UIImage.
    private static func image(
        from frame: UnsafeMutablePointer<AVFrame>,
        scaler: OpaquePointer,
        width: Int32,
        height: Int32
    ) -> UIImage? {
        let bytesPerRow = Int(width) * 4
        let byteCount = bytesPerRow * Int(height)
        guard let buffer = malloc(byteCount) else { return nil }
        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            buffer.assumingMemoryBound(to: UInt8.self), nil, nil, nil
        ]
        var dstStride: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
        let planes = frame.pointee.data
        let strides = frame.pointee.linesize
        var srcData: [UnsafePointer<UInt8>?] = [
            planes.0.map { UnsafePointer($0) }, planes.1.map { UnsafePointer($0) },
            planes.2.map { UnsafePointer($0) }, planes.3.map { UnsafePointer($0) },
            planes.4.map { UnsafePointer($0) }, planes.5.map { UnsafePointer($0) },
            planes.6.map { UnsafePointer($0) }, planes.7.map { UnsafePointer($0) }
        ]
        var srcStride: [Int32] = [
            strides.0, strides.1, strides.2, strides.3,
            strides.4, strides.5, strides.6, strides.7
        ]
        let scaled = sws_scale(
            scaler, &srcData, &srcStride, 0, frame.pointee.height,
            &dstData, &dstStride
        )
        guard scaled > 0 else { free(buffer); return nil }

        guard let provider = CGDataProvider(
            dataInfo: nil, data: buffer, size: byteCount,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        ) else { free(buffer); return nil }
        guard let cgImage = CGImage(
            width: Int(width), height: Int(height),
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
