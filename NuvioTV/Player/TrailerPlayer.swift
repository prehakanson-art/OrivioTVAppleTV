import SwiftUI
import AVKit
import YouTubeKit

/// Resolves a YouTube video key to something AVPlayer can play. tvOS has no
/// WebKit, so the iframe embed is out — YouTubeKit extracts native streams.
///
/// YouTube only *muxes* audio+video up to ~720p; 1080p and up exist solely as
/// separate adaptive tracks (DASH). A merged 1080p composition looks sharper,
/// but AVPlayer then has to buffer and mux TWO separate remote streams before
/// it can start — which is what made trailers slow to open. For a short
/// trailer, a fast start matters more than the extra sharpness, so we play the
/// single muxed (≤720p) progressive URL — one stream AVPlayer can begin almost
/// immediately — and only fall back to the merge when no muxed stream exists.
enum TrailerResolver {
    /// Fastest-starting natively-playable item: the best muxed (≤720p) stream,
    /// falling back to a merged 1080p video + audio composition only when the
    /// video offers no muxed stream at all.
    static func playerItem(youtubeKey: String) async -> AVPlayerItem? {
        guard let streams = try? await YouTube(videoID: youtubeKey).streams else { return nil }
        // isNativelyPlayable keeps only codecs AVPlayer decodes (H.264/AAC),
        // dropping VP9/AV1 webm — so the "highest" video-only is 1080p H.264.
        let playable = streams.filter { $0.isNativelyPlayable }

        // Single progressive URL → near-instant start.
        if let muxed = playable.filterVideoAndAudio().highestResolutionStream() {
            return AVPlayerItem(url: muxed.url)
        }
        // No muxed stream: fall back to merging the adaptive tracks for 1080p.
        if let video = playable.filterVideoOnly().highestResolutionStream(),
           let audio = playable.filterAudioOnly().highestAudioBitrateStream(),
           let merged = await mergedItem(video: video.url, audio: audio.url) {
            return merged
        }
        return nil
    }

    /// Merge a remote video-only and audio-only track into one playable asset.
    private static func mergedItem(video: URL, audio: URL) async -> AVPlayerItem? {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        do {
            guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { return nil }
            let duration = try await videoAsset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let vComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try vComp?.insertTimeRange(range, of: vTrack, at: .zero)
            if let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
                let aComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try aComp?.insertTimeRange(range, of: aTrack, at: .zero)
            }
            return AVPlayerItem(asset: composition)
        } catch {
            return nil
        }
    }

    /// Silent backdrop trailer: no audio needed, so use the sharpest
    /// natively-playable video-only stream (falls back to a muxed stream).
    static func streamURL(youtubeKey: String) async -> URL? {
        guard let streams = try? await YouTube(videoID: youtubeKey).streams else { return nil }
        let playable = streams.filter { $0.isNativelyPlayable }
        if let video = playable.filterVideoOnly().highestResolutionStream() { return video.url }
        return playable.filterVideoAndAudio().highestResolutionStream()?.url
    }
}

/// A bare `AVPlayerLayer` with no transport chrome — used to play a trailer
/// silently behind the Detail hero. `.resizeAspectFill` so it fills the header
/// like the still backdrop it replaces.
struct BackdropVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen trailer playback. Resolves the YouTube key, then plays through
/// the native tvOS `VideoPlayer` transport. Menu (back) dismisses.
struct TrailerPlayerView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let trailer: TMDBService.Trailer

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    // Fully release on dismiss: pausing alone leaves the player
                    // registered as the system "Now Playing" item, so pressing
                    // Play/Pause later summons the tvOS transport overlay over
                    // whatever screen you're on. Clearing the item drops it.
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                    }
            } else if failed {
                NuvioEmptyState(
                    icon: "play.slash.fill",
                    title: "Trailer unavailable",
                    message: "This trailer couldn't be loaded. Press Menu to go back."
                )
            } else {
                NuvioLoadingView(label: "Loading trailer")
            }
        }
        .onExitCommand { dismiss() }
        .task {
            guard let item = await TrailerResolver.playerItem(youtubeKey: trailer.youtubeKey) else {
                failed = true
                return
            }
            let player = AVPlayer(playerItem: item)
            // Start on the first available buffer instead of waiting to build a
            // stall-proof one — a trailer should pop up, not spin.
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            player.play()
        }
    }
}
