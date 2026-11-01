import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import UIKit

// §7.19 Scrub previews. A second FFmpeg connection + software decoder next to
// playback, so every rule below is about not hurting the picture on screen:
// every packet is unref'd, a cancel flag interrupts blocked reads, threads are
// capped, and the pass breathes between frames. Rules carried over from the old
// app: never AVDISCARD_NONKEY (backward seek + LOW_DELAY instead), keep decoded
// frames on cancel, and skip a refused slot instead of abandoning the pass.

struct ScrubThumbnail {
    let image: UIImage
    let time: Double
}

final class ScrubThumbnailer: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let count: Int
    private let range: ClosedRange<Double>?
    private let budget: TimeInterval
    private let breath: TimeInterval
    private let denseSpacing: Double?
    private let denseCenter: Double?
    private let shouldProceed: (@Sendable () -> Bool)?
    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    static let thumbWidth: Int32 = 320
    /// Coarse pass: a frame every ~30 s, capped by tier (a 320-wide frame is ~230 KB).
    static func coarseCount(duration: Double) -> Int {
        let cap = PerformanceProfile.isLowPower ? 60 : (PerformanceProfile.isMidPower ? 100 : 240)
        guard duration.isFinite, duration > 0 else { return 36 }
        return max(12, min(Int(duration / 30), cap))
    }

    private static let sweepFloorFPS: Double = 60
    private static let sweepRateWindow = 48
    private static var sweepDecodeCap: Int { PerformanceProfile.isMidPower ? 600 : 1500 }

    init(url: URL, headers: [String: String], count: Int, range: ClosedRange<Double>? = nil, budget: TimeInterval = 120,
         breath: TimeInterval = 0.6, denseSpacing: Double? = nil, denseCenter: Double? = nil,
         shouldProceed: (@Sendable () -> Bool)? = nil) {
        self.url = url
        self.headers = headers
        self.count = max(1, count)
        self.range = range
        self.budget = budget
        self.breath = breath
        self.denseSpacing = denseSpacing
        self.denseCenter = denseCenter
        self.shouldProceed = shouldProceed
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    /// 0, ½, ¼, ¾, ⅛ … — whenever the budget stops the pass, what it has is spread over the whole span.
    static func scanOrder(_ count: Int) -> [Int] {
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
        for i in 0..<count where seen.insert(i).inserted { order.append(i) }
        return order
    }

    /// Runs on its own thread; `onProgress` (worker thread, ≤ 1 Hz) gets the frames so far.
    func generate(onProgress: (([ScrubThumbnail]) -> Void)? = nil) async -> [ScrubThumbnail] {
        await withCheckedContinuation { cont in
            let t = Thread { [self] in cont.resume(returning: run(onProgress: onProgress)) }
            t.name = "ScrubThumbnailer"
            t.qualityOfService = .utility
            t.start()
        }
    }

    // MARK: Worker

    private func run(onProgress: (([ScrubThumbnail]) -> Void)?) -> [ScrubThumbnail] {
        let deadline = Date().addingTimeInterval(budget)
        var thumbs: [ScrubThumbnail] = []
        var lastPublish: CFAbsoluteTime = 0

        var fmt = avformat_alloc_context()
        guard let ctx = fmt else { return [] }
        defer { avformat_close_input(&fmt) }
        var interrupt = AVIOInterruptCB()
        interrupt.opaque = Unmanaged.passUnretained(self).toOpaque()
        interrupt.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<ScrubThumbnailer>.fromOpaque(opaque).takeUnretainedValue().cancelled ? 1 : 0
        }
        ctx.pointee.interrupt_callback = interrupt

        var opts: OpaquePointer?
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "reconnect_streamed", "1", 0)
        av_dict_set(&opts, "reconnect_delay_max", "5", 0)
        av_dict_set(&opts, "rw_timeout", "15000000", 0)
        av_dict_set(&opts, "multiple_requests", "1", 0)
        av_dict_set(&opts, "probesize", String(2 << 20), 0)
        av_dict_set(&opts, "analyzeduration", "1000000", 0)
        if !headers.isEmpty {
            av_dict_set(&opts, "headers", headers.map { "\($0.key): \($0.value)\r\n" }.joined(), 0)
        }
        let path = url.isFileURL ? url.path : url.absoluteString
        let opened = avformat_open_input(&fmt, path, nil, &opts)
        av_dict_free(&opts)
        guard opened == 0, let fc = fmt, !cancelled, avformat_find_stream_info(fc, nil) >= 0, !cancelled else { return [] }

        var vi = -1
        for i in 0..<Int(fc.pointee.nb_streams) {
            guard let st = fc.pointee.streams[i], let par = st.pointee.codecpar, par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  st.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 else { continue }
            vi = i
            break
        }
        guard vi >= 0, let vs = fc.pointee.streams[vi], let par = vs.pointee.codecpar,
              let codec = avcodec_find_decoder(par.pointee.codec_id), let cc = avcodec_alloc_context3(codec) else { return [] }
        var freeCC: UnsafeMutablePointer<AVCodecContext>? = cc
        defer { avcodec_free_context(&freeCC) }
        guard avcodec_parameters_to_context(cc, par) >= 0 else { return [] }
        cc.pointee.thread_count = PerformanceProfile.isMidPower ? 1 : 2
        cc.pointee.skip_loop_filter = AVDISCARD_ALL
        cc.pointee.flags |= Int32(AV_CODEC_FLAG_LOW_DELAY)
        guard avcodec_open2(cc, codec, nil) >= 0, cc.pointee.width > 0, cc.pointee.height > 0 else { return [] }
        let dstW = min(Self.thumbWidth, cc.pointee.width)
        let dstH = max(dstW * cc.pointee.height / cc.pointee.width, 1)

        // Built from the first decoded frame's real format and geometry, rebuilt if either changes.
        var scaler: OpaquePointer?
        var sFormat: Int32 = -1, sW: Int32 = 0, sH: Int32 = 0
        defer { if let scaler { sws_freeContext(scaler) } }

        guard let pkt = av_packet_alloc() else { return [] }
        var freePkt: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&freePkt) }
        guard let frame = av_frame_alloc() else { return [] }
        var freeFrame: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&freeFrame) }

        let tb = vs.pointee.time_base
        let duration = av_rescale_q(fc.pointee.duration, AVRational(num: 1, den: AV_TIME_BASE), tb)
        guard duration > 0 else { return [] }
        let start = vs.pointee.start_time == Int64.min ? 0 : vs.pointee.start_time
        let secs = av_q2d(tb)
        let spanLo: Int64, spanLen: Int64
        if let range {
            let lo = max(Int64(range.lowerBound / secs), 0)
            let hi = min(Int64(range.upperBound / secs), duration)
            spanLo = lo
            spanLen = max(hi - lo, 1)
        } else {
            spanLo = 0
            spanLen = duration
        }

        func publish(force: Bool = false) {
            guard let onProgress, !cancelled, !thumbs.isEmpty else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard force || now - lastPublish >= 1 else { return }
            lastPublish = now
            onProgress(thumbs.sorted { $0.time < $1.time })
        }

        func keep(_ f: UnsafeMutablePointer<AVFrame>, fallback: Int64) -> Bool {
            if scaler == nil || sFormat != f.pointee.format || sW != f.pointee.width || sH != f.pointee.height {
                if let s = scaler { sws_freeContext(s) }
                sFormat = f.pointee.format
                sW = f.pointee.width
                sH = f.pointee.height
                guard sW > 0, sH > 0 else { return false }
                scaler = sws_getContext(sW, sH, AVPixelFormat(rawValue: sFormat), dstW, dstH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil)
            }
            guard let scaler, let img = Self.image(f, scaler: scaler, width: dstW, height: dstH) else { return false }
            let stamp = f.pointee.best_effort_timestamp == Int64.min ? fallback : f.pointee.best_effort_timestamp
            thumbs.append(ScrubThumbnail(image: img, time: max(Double(stamp - start) * secs, 0)))
            publish()
            return true
        }

        func waitForPlayback() {
            while let shouldProceed, !shouldProceed(), !cancelled, Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        }

        /// One seek, then read forward keeping a frame every `spacing` s — the frames between keyframes.
        /// False = stood down (too slow / decode cap): don't sweep the other half either.
        func sweep(from: Double, to: Double, spacing: Double, decoded: inout Int) -> Bool {
            guard to > from else { return true }
            let pts = Int64(from / secs) + start
            avcodec_flush_buffers(cc)
            guard av_seek_frame(fc, Int32(vi), pts, AVSEEK_FLAG_BACKWARD) >= 0 else { return true }
            var nextKeep = from
            var here = 0, sinceCheck = 0
            let began = Date()
            while !cancelled, Date() < deadline {
                if decoded >= Self.sweepDecodeCap { return false }
                guard av_read_frame(fc, pkt) >= 0 else { return true }
                defer { av_packet_unref(pkt) }
                guard pkt.pointee.stream_index == Int32(vi) else { continue }
                let sent = avcodec_send_packet(cc, pkt)
                guard sent >= 0 || sent == -EAGAIN else { return true }
                while avcodec_receive_frame(cc, frame) >= 0 {
                    defer { av_frame_unref(frame) }
                    decoded += 1
                    here += 1
                    sinceCheck += 1
                    let stamp = frame.pointee.best_effort_timestamp == Int64.min ? pts : frame.pointee.best_effort_timestamp
                    let t = max(Double(stamp - start) * secs, 0)
                    if t > to { return true }
                    if t + 0.001 >= nextKeep {
                        guard keep(frame, fallback: stamp) else { return true }
                        nextKeep = t + spacing
                    }
                }
                if sinceCheck >= 24 {
                    sinceCheck = 0
                    waitForPlayback()
                    if here >= Self.sweepRateWindow, Double(here) / max(Date().timeIntervalSince(began), 0.001) < Self.sweepFloorFPS { return false }
                }
            }
            return false
        }

        if let denseSpacing, denseSpacing > 0 {
            let lo = Double(spanLo) * secs, hi = lo + Double(spanLen) * secs
            let centre = min(max(denseCenter ?? (lo + hi) / 2, lo), hi)
            var decoded = 0
            // Forward from the viewer first: a budget that runs out costs the edges.
            if sweep(from: centre, to: hi, spacing: denseSpacing, decoded: &decoded) {
                _ = sweep(from: lo, to: centre, spacing: denseSpacing, decoded: &decoded)
            }
            publish(force: true)
        }

        let interval = max(spanLen / Int64(count), 1)
        for index in Self.scanOrder(count) {
            if cancelled || Date() >= deadline { break }
            waitForPlayback()
            if cancelled || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: breath)
            let target = spanLo + interval * Int64(index) + start
            if let denseSpacing {
                let tSec = Double(target - start) * secs
                if thumbs.contains(where: { abs($0.time - tSec) <= denseSpacing }) { continue }
            }
            avcodec_flush_buffers(cc)
            // Skip the slot, don't abandon the pass.
            guard av_seek_frame(fc, Int32(vi), target, AVSEEK_FLAG_BACKWARD) >= 0 else { continue }
            var reads = 0
            while !cancelled, Date() < deadline {
                guard av_read_frame(fc, pkt) >= 0 else { break }
                defer { av_packet_unref(pkt) }
                reads += 1
                if reads > 240 { break }
                guard pkt.pointee.stream_index == Int32(vi) else { continue }
                let sent = avcodec_send_packet(cc, pkt)
                guard sent >= 0 || sent == -EAGAIN else { break }
                let received = avcodec_receive_frame(cc, frame)
                if received == -EAGAIN { continue }
                if received < 0 { break }
                defer { av_frame_unref(frame) }
                _ = keep(frame, fallback: target)
                break
            }
        }
        publish(force: true)
        // Keep what was decoded, even on cancel.
        return thumbs
    }

    private static func image(_ f: UnsafeMutablePointer<AVFrame>, scaler: OpaquePointer, width: Int32, height: Int32) -> UIImage? {
        let bpr = Int(width) * 4
        let size = bpr * Int(height)
        guard let buffer = malloc(size) else { return nil }
        var dst: [UnsafeMutablePointer<UInt8>?] = [buffer.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        var dstStride: [Int32] = [Int32(bpr), 0, 0, 0]
        let d = f.pointee.data, l = f.pointee.linesize
        var src: [UnsafePointer<UInt8>?] = [d.0, d.1, d.2, d.3, d.4, d.5, d.6, d.7].map { $0.map { UnsafePointer($0) } }
        var srcStride: [Int32] = [l.0, l.1, l.2, l.3, l.4, l.5, l.6, l.7]
        guard sws_scale(scaler, &src, &srcStride, 0, f.pointee.height, &dst, &dstStride) > 0 else { free(buffer); return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else { free(buffer); return nil }
        guard let cg = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The player's preview set: a coarse pass over the film after the first frame,
/// and a fine pass around the target while scrubbing. Merged, sorted, cached on disk.
@MainActor
final class ScrubPreviews: ObservableObject {
    @Published private(set) var frames: [ScrubThumbnail] = []
    private var coarse: ScrubThumbnailer?
    private var fine: ScrubThumbnailer?
    private var fineCentre: Double?
    private var url: URL?
    private var headers: [String: String] = [:]
    private var duration: Double = 0
    /// Polled by the passes: false while playback is short of buffer.
    var playbackHealthy: @Sendable () -> Bool = { true }
    /// The hybrid cache's disk-only lane when the film around `t` is already on
    /// disk (§7.19: previews read the cache lane, or the origin when not cached).
    var cacheLane: ((Double) -> URL?)?

    /// Off on the A8, on HLS, live and non-http sources.
    static func eligible(url: URL, isLive: Bool) -> Bool {
        guard !isLive, !PerformanceProfile.isLowPower else { return false }
        let s = url.absoluteString.lowercased()
        if s.contains(".m3u8") || s.contains("/manifest") { return false }
        return url.isFileURL || url.scheme?.hasPrefix("http") == true
    }

    func start(url: URL, headers: [String: String], duration: Double) {
        stop()
        guard duration > 0 else { return }
        self.url = url
        self.headers = headers
        self.duration = duration
        if let cached = ScrubPreviewCache.load(url: url) {
            frames = cached
            return
        }
        let pass = ScrubThumbnailer(url: url, headers: headers, count: ScrubThumbnailer.coarseCount(duration: duration),
                                    budget: 30 * 60, breath: 0.6, shouldProceed: playbackHealthy)
        coarse = pass
        Task {
            let result = await pass.generate { [weak self] partial in
                Task { @MainActor in self?.merge(partial) }
            }
            guard coarse === pass else { return }
            merge(result)
            if result.count >= ScrubThumbnailer.coarseCount(duration: duration) / 2 { ScrubPreviewCache.save(frames, url: url) }
        }
    }

    /// Fine pass around the scrub target: one seek, a frame every second.
    func refine(around t: Double) {
        guard let url, duration > 0 else { return }
        if let c = fineCentre, abs(c - t) < 20 { return }
        fine?.cancel()
        fineCentre = t
        let range = max(0, t - 45)...min(duration, t + 45)
        let lane = cacheLane?(t)
        // Off the disk: no network, and the lane answers uncovered ranges 416 at once.
        let pass = ScrubThumbnailer(url: lane ?? url, headers: lane == nil ? headers : [:], count: 45, range: range,
                                    budget: 40, breath: 0, denseSpacing: 1, denseCenter: t)
        fine = pass
        Task {
            let result = await pass.generate { [weak self] partial in
                Task { @MainActor in self?.merge(partial) }
            }
            merge(result)
        }
    }

    func endScrub() {
        fine?.cancel()
        fine = nil
        fineCentre = nil
    }

    func stop() {
        coarse?.cancel()
        fine?.cancel()
        coarse = nil
        fine = nil
        fineCentre = nil
        frames = []
    }

    /// The frame for `t`: the latest frame at or before it within tolerance
    /// (keyframe stamps on 4K remuxes are 5–10 s apart), else the nearest.
    func frame(at t: Double) -> UIImage? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        let before = frames[lo]
        let after = lo + 1 < frames.count ? frames[lo + 1] : nil
        let best = after.map { abs($0.time - t) < abs(before.time - t) ? $0 : before } ?? before
        let tolerance = max(12, duration / Double(max(frames.count, 1)) * 1.5)
        return abs(best.time - t) <= tolerance ? best.image : nil
    }

    private func merge(_ new: [ScrubThumbnail]) {
        guard !new.isEmpty else { return }
        var all = frames
        for f in new where !all.contains(where: { abs($0.time - f.time) < 0.25 }) { all.append(f) }
        all.sort { $0.time < $1.time }
        // Bound memory: thin the oldest coarse duplicates if a long session piles up fine passes.
        let cap = PerformanceProfile.isMidPower ? 400 : 900
        if all.count > cap {
            let keepAround = fineCentre ?? 0
            all = all.sorted { abs($0.time - keepAround) < abs($1.time - keepAround) }.prefix(cap).sorted { $0.time < $1.time }
        }
        frames = all
    }
}

/// Finished coarse sets, `Library/Caches/OrivioCache/scrub/<fnv>.json` (newest 40).
enum ScrubPreviewCache {
    private struct Entry: Codable { let t: Double; let jpeg: Data }

    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("OrivioCache/scrub", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// FNV-1a of the URL without its query (signed links change per session).
    private static func key(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        var h: UInt64 = 0xcbf29ce484222325
        for b in (c?.string ?? url.absoluteString).utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    static func load(url: URL) -> [ScrubThumbnail]? {
        let f = dir.appendingPathComponent(key(url) + ".json")
        guard let data = try? Data(contentsOf: f), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return entries.compactMap { e in UIImage(data: e.jpeg).map { ScrubThumbnail(image: $0, time: e.t) } }
    }

    static func save(_ frames: [ScrubThumbnail], url: URL) {
        let entries = frames.compactMap { f in f.image.jpegData(compressionQuality: 0.6).map { Entry(t: f.time, jpeg: $0) } }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: dir.appendingPathComponent(key(url) + ".json"))
        // Newest 40.
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in files.dropFirst(40) { try? fm.removeItem(at: old) }
    }
}
