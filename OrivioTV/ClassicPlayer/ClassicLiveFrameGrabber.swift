import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import UIKit

/// The scrub preview's frame under the finger, fetched on demand.
///
/// `ClassicScrubThumbnailer` lays down a set of frames ahead of time, which
/// can only cover what has been decoded so far — the cached window on a big
/// remux, a frame every 30 seconds elsewhere. This answers ONE position at a
/// time instead: a single FFmpeg session, opened on the first request and kept
/// for the rest of the scrub, that seeks to the keyframe at or before the
/// target and decodes just that frame. Pointed at the origin it works the same
/// on film that is cached and film that is not, and one seek is one ranged
/// read of a few megabytes.
///
/// Requests are serial on one queue and the caller keeps at most one in
/// flight, so a moving finger costs one decode at a time, newest target first.
final class ClassicLiveFrameGrabber: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]?
    private let thumbWidth: Int32
    private let queue = DispatchQueue(label: "ClassicLiveFrameGrabber", qos: .userInitiated)

    @ClassicAtomic private var closed = false
    /// Set once an open has failed: the source refuses a second reader (a
    /// single-connection debrid or IPTV link), and retrying it on every scrub
    /// movement would only hammer it.
    @ClassicAtomic private(set) var unavailable = false

    // Owned by `queue`.
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1)
    private var startTime: Int64 = 0
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scaler: OpaquePointer?
    private var scalerKey: (format: Int32, width: Int32, height: Int32) = (-1, 0, 0)

    init(url: URL, headers: [String: String]? = nil, thumbWidth: Int32 = 480) {
        self.url = url
        self.headers = headers
        self.thumbWidth = thumbWidth
    }

    deinit { teardown() }

    /// The keyframe at or before `seconds`, stamped with its own time. Nil when
    /// the source cannot be read or the seek finds nothing.
    func frame(at seconds: Double) async -> ClassicScrubThumbnail? {
        guard !closed, !unavailable, seconds.isFinite else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: closed ? nil : grab(seconds))
            }
        }
    }

    /// Open the session ahead of the first request, off the caller's thread.
    func prewarm() {
        guard !closed, !unavailable else { return }
        queue.async { [self] in _ = closed ? false : openIfNeeded() }
    }

    /// Abort any blocked read and release the session.
    func close() {
        closed = true
        queue.async { [self] in teardown() }
    }

    // MARK: - Queue

    private func openIfNeeded() -> Bool {
        if formatCtx != nil { return true }
        guard !unavailable else { return false }
        var ctx = avformat_alloc_context()
        guard let inCtx = ctx else { unavailable = true; return false }
        var interrupt = AVIOInterruptCB()
        interrupt.opaque = Unmanaged.passUnretained(self).toOpaque()
        interrupt.callback = { opaque -> Int32 in
            guard let opaque else { return 0 }
            return Unmanaged<ClassicLiveFrameGrabber>.fromOpaque(opaque).takeUnretainedValue().closed ? 1 : 0
        }
        inCtx.pointee.interrupt_callback = interrupt
        // Same network posture as the thumbnailer: errors out on a flaky CDN
        // instead of hanging the queue.
        var options: OpaquePointer?
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_delay_max", "3", 0)
        av_dict_set(&options, "rw_timeout", "8000000", 0)
        av_dict_set(&options, "multiple_requests", "1", 0)
        av_dict_set(&options, "probesize", String(2 << 20), 0)
        av_dict_set(&options, "analyzeduration", "1000000", 0)
        if let headers, !headers.isEmpty {
            av_dict_set(&options, "headers", headers.map { "\($0.key):\($0.value)\r\n" }.joined(), 0)
        }
        let path = url.isFileURL ? url.path : url.absoluteString
        let opened = avformat_open_input(&ctx, path, nil, &options)
        av_dict_free(&options)
        guard opened == 0, let ctx, !closed, avformat_find_stream_info(ctx, nil) >= 0 else {
            avformat_close_input(&ctx)
            if !closed { unavailable = true }
            return false
        }
        formatCtx = ctx

        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) == 0 else { continue }
            videoIndex = Int32(i)
            timeBase = stream.pointee.time_base
            startTime = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
            break
        }
        guard videoIndex >= 0, let par = ctx.pointee.streams[Int(videoIndex)]?.pointee.codecpar,
              let codec = avcodec_find_decoder(par.pointee.codec_id),
              let codecCtx = avcodec_alloc_context3(codec) else {
            unavailable = true; teardown(); return false
        }
        self.codecCtx = codecCtx
        guard avcodec_parameters_to_context(codecCtx, par) >= 0 else { unavailable = true; teardown(); return false }
        // One keyframe at a time, but while the viewer is waiting on it: a
        // 4K HEVC keyframe on two threads was most of a request's half second.
        // The 3 GB box keeps its cores for playback.
        codecCtx.pointee.thread_count = PerformanceProfile.isMidPower ? 1 : 4
        codecCtx.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(codecCtx, codec, nil) >= 0 else { unavailable = true; teardown(); return false }
        packet = av_packet_alloc()
        frame = av_frame_alloc()
        guard packet != nil, frame != nil else { unavailable = true; teardown(); return false }
        return true
    }

    private func grab(_ seconds: Double) -> ClassicScrubThumbnail? {
        guard openIfNeeded(), let formatCtx, let codecCtx, let packet, let frame else { return nil }
        let target = Int64(max(seconds, 0) / av_q2d(timeBase)) + startTime
        avcodec_flush_buffers(codecCtx)
        guard av_seek_frame(formatCtx, videoIndex, target, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        var reads = 0
        while !closed, reads < 400 {
            guard av_read_frame(formatCtx, packet) >= 0 else { return nil }
            defer { av_packet_unref(packet) }
            reads += 1
            guard packet.pointee.stream_index == videoIndex else { continue }
            let sent = avcodec_send_packet(codecCtx, packet)
            guard sent >= 0 || sent == Int32(-EAGAIN) else { return nil }
            let received = avcodec_receive_frame(codecCtx, frame)
            if received == Int32(-EAGAIN) { continue }
            guard received >= 0 else { return nil }
            defer { av_frame_unref(frame) }
            return thumbnail(from: frame, fallbackStamp: target)
        }
        return nil
    }

    private func thumbnail(from frame: UnsafeMutablePointer<AVFrame>, fallbackStamp: Int64) -> ClassicScrubThumbnail? {
        let srcW = frame.pointee.width, srcH = frame.pointee.height
        guard srcW > 0, srcH > 0 else { return nil }
        let dstW = min(thumbWidth, srcW)
        let dstH = max(dstW * srcH / srcW, 1)
        // Rebuilt on any change of format or geometry (see the thumbnailer's
        // note on reading past the source planes).
        if scaler == nil || scalerKey != (frame.pointee.format, srcW, srcH) {
            if let scaler { sws_freeContext(scaler) }
            scalerKey = (frame.pointee.format, srcW, srcH)
            scaler = sws_getContext(srcW, srcH, AVPixelFormat(rawValue: frame.pointee.format),
                                    dstW, dstH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil)
        }
        guard let scaler,
              let image = ClassicScrubThumbnailer.image(from: frame, scaler: scaler, width: dstW, height: dstH)
        else { return nil }
        let stamp = frame.pointee.best_effort_timestamp == Int64.min
            ? fallbackStamp : frame.pointee.best_effort_timestamp
        return ClassicScrubThumbnail(image: image, time: max(Double(stamp - startTime) * av_q2d(timeBase), 0))
    }

    private func teardown() {
        if let scaler { sws_freeContext(scaler) }
        scaler = nil
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
        if formatCtx != nil { avformat_close_input(&formatCtx) }
    }
}
