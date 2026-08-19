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

    @Atomic private var cancelled = false

    init(url: URL, count: Int = 36, thumbWidth: Int32 = 256, budgetSeconds: TimeInterval = 60) {
        self.url = url
        self.count = count
        self.thumbWidth = thumbWidth
        self.budgetSeconds = budgetSeconds
    }

    /// Aborts promptly even from a blocked network read (the interrupt callback
    /// below polls this).
    func cancel() { cancelled = true }

    /// Generate the frames off the caller's thread. Returns whatever was
    /// produced before the budget, the end of the file, or a cancel.
    func generate() async -> [ScrubThumbnail] {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(returning: run())
            }
            thread.name = "ScrubThumbnailer"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    // MARK: - Worker thread

    private func run() -> [ScrubThumbnail] {
        let deadline = Date().addingTimeInterval(budgetSeconds)
        var thumbnails: [ScrubThumbnail] = []

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
        let interval = duration / Int64(count)
        let startTime = videoStream.pointee.start_time == Int64.min ? 0 : videoStream.pointee.start_time

        for index in 0 ..< count {
            if cancelled || Date() >= deadline { break }
            let target = interval * Int64(index) + startTime
            avcodec_flush_buffers(codecCtx)
            guard av_seek_frame(formatCtx, Int32(videoIndex), target, AVSEEK_FLAG_BACKWARD) >= 0
            else { break }

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
                guard avcodec_send_packet(codecCtx, packet) >= 0 else { break }
                let received = avcodec_receive_frame(codecCtx, frame)
                if received < 0 {
                    // EAGAIN just means "feed me more packets".
                    if received == -35 || received == Int32(-EAGAIN) { continue }
                    break
                }
                defer { av_frame_unref(frame) }
                // (Re)build the scaler when the decoded format first appears or
                // changes mid-file.
                if scaler == nil || scalerFormat != frame.pointee.format {
                    if let existing = scaler { sws_freeContext(existing) }
                    scalerFormat = frame.pointee.format
                    scaler = sws_getContext(
                        srcW, srcH, AVPixelFormat(rawValue: scalerFormat),
                        dstW, dstH, AV_PIX_FMT_BGRA,
                        SWS_BILINEAR, nil, nil, nil
                    )
                }
                guard let scaler else { break }
                if let image = Self.image(
                    from: frame, scaler: scaler, width: dstW, height: dstH
                ) {
                    let stamp = frame.pointee.best_effort_timestamp == Int64.min
                        ? target : frame.pointee.best_effort_timestamp
                    let seconds = Double(stamp - startTime) * av_q2d(timeBase)
                    thumbnails.append(ScrubThumbnail(image: image, time: max(seconds, 0)))
                }
                break
            }
        }
        return cancelled ? [] : thumbnails
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
