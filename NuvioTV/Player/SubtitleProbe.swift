import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Cheap "does this stream carry a styled ASS/SSA subtitle track?" check.
///
/// Only reads the container header (avformat_find_stream_info), NOT the whole
/// file — a few MB over the network, once — so it's safe for remote debrid /
/// torrent streams. Used to decide whether to route a title to the VLC engine
/// (which renders full ASS with libass + embedded MKV fonts) instead of the
/// KSPlayer engine (whose built-in ASS parser drops fonts / complex styling).
enum SubtitleProbe {
    /// True if the source has at least one ASS or SSA subtitle stream. Any
    /// probe failure returns false (leave the engine choice untouched).
    static func hasStyledASS(url: String, timeoutSeconds: Double = 8) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probe(url: url, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    private static func probe(url: String, timeoutSeconds: Double) -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>?

        // Bound the network open so a slow host can't stall playback start.
        var opts: OpaquePointer?
        av_dict_set(&opts, "rw_timeout", String(Int(timeoutSeconds * 1_000_000)), 0)
        av_dict_set(&opts, "timeout", String(Int(timeoutSeconds * 1_000_000)), 0)
        av_dict_set(&opts, "reconnect", "1", 0)

        defer { av_dict_free(&opts) }
        guard avformat_open_input(&ctx, url, nil, &opts) == 0, let ctx else { return false }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }

        // Bound the probe the same way the playback path does (PlayerViewModel
        // sets probesize/maxAnalyzeDuration). This runs on a SECOND connection
        // to the same remote file while the player is still filling its initial
        // buffer, and FFmpeg's defaults here are 5 MB and up to 5 SECONDS of
        // content — a meaningful bandwidth competitor on a debrid link right at
        // the moment startup is most sensitive. The subtitle stream list comes
        // from the container header, so a small probe is entirely sufficient.
        ctx.pointee.probesize = 2 << 20              // 2 MB
        ctx.pointee.max_analyze_duration = 1_000_000 // 1s (microseconds)
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return false }

        for i in 0 ..< Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i], let par = stream.pointee.codecpar else { continue }
            guard par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            if par.pointee.codec_id == AV_CODEC_ID_ASS || par.pointee.codec_id == AV_CODEC_ID_SSA {
                return true
            }
        }
        return false
    }
}
