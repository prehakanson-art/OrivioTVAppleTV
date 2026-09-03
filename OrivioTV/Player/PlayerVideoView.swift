import KSPlayer
import SwiftUI
import UIKit

/// Hosts the current engine's video view. KSPlayerLayer swaps the underlying
/// player (native ↔ FFmpeg) during failover and re-parents the new view into
/// the old one's superview itself, so this container just has to attach the
/// current view and clean up strays whenever `videoRefreshID` changes.
///
/// Deliberately NOT `@ObservedObject`: observing the view model made every
/// published change re-run `updateUIView`. The parent passes `refreshID`
/// (bumped only when the engine/player instance may have changed) so SwiftUI
/// re-invokes us exactly when re-attachment could be needed.
struct PlayerVideoView: UIViewRepresentable {
    let viewModel: PlayerViewModel
    let refreshID: UUID

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: UIView) {
        // Point PiP at whatever the engine ended up rendering into. Done here
        // rather than at load time because the render view only exists once
        // the engine has actually started, and it CHANGES on an engine swap.
        viewModel.pictureInPicture.attach(viewModel.pictureInPictureSource)
        // The active engine's render view (KSPlayer's player view or VLC's
        // drawable) — bumped via videoRefreshID when the engine changes.
        guard let videoView = viewModel.activeVideoView else {
            for subview in container.subviews {
                subview.removeFromSuperview()
            }
            return
        }
        for subview in container.subviews where subview !== videoView {
            subview.removeFromSuperview()
        }
        guard videoView.superview !== container else { return }
        videoView.removeFromSuperview()
        container.addSubview(videoView)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// Renders the active subtitle cues from KSPlayer's SubtitleModel: text cues
/// bottom-centered in Orivio's caption style, bitmap cues (PGS/VobSub) fitted
/// over the video.
struct SubtitleOverlayView: View {
    @ObservedObject var model: SubtitleModel
    var settings: PlayerSettings = .default

    var body: some View {
        ZStack {
            ForEach(model.parts) { part in
                if let image = part.image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: geo.size.width * 0.9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 60)
                    }
                } else if let text = part.text {
                    // Broadcast-caption look, styled from Playback settings:
                    // text color, optional true outline, background plate with
                    // adjustable opacity, and a vertical offset.
                    VStack {
                        Spacer()
                        styledCaption(text)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                            .background(
                                Color.black.opacity(settings.subtitleBackground
                                    ? Double(settings.subtitleBackgroundOpacity) / 100 : 0),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .padding(.bottom, CGFloat(84 + settings.subtitleVerticalOffset))
                            .frame(maxWidth: 1200)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var textColor: Color { Color(badgeHex: settings.subtitleTextColorHex) ?? .white }
    private var outlineColor: Color { Color(badgeHex: settings.subtitleOutlineColorHex) ?? .black }

    /// One caption line with the configured color and (optionally) a real
    /// outline — SwiftUI has no text stroke, so the outline is the same text
    /// rendered in 8 directions behind the fill. Falls back to a soft double
    /// shadow when the outline is off.
    @ViewBuilder
    private func styledCaption(_ text: NSAttributedString) -> some View {
        let base = Text(AttributedString(text))
            .font(.system(size: CGFloat(settings.subtitleSize), weight: settings.subtitleBold ? .bold : .medium))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
        if settings.subtitleOutlineEnabled {
            ZStack {
                let w = CGFloat(max(1, settings.subtitleOutlineWidth))
                ForEach(0 ..< 8, id: \.self) { i in
                    let a = Double(i) / 8 * 2 * .pi
                    base.foregroundStyle(outlineColor)
                        .offset(x: cos(a) * w, y: sin(a) * w)
                }
                base.foregroundStyle(textColor)
            }
        } else {
            base.foregroundStyle(textColor)
                .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                // The soft radius-8 glow is a second offscreen blur composited
                // over the moving video on every displayed frame — enough to
                // cost playback frames on the A8 whenever captions are up. The
                // crisp radius-2 shadow alone keeps them readable there.
                .shadow(color: .black.opacity(PerformanceProfile.isLowPower ? 0 : 0.6),
                        radius: PerformanceProfile.isLowPower ? 0 : 8)
        }
    }
}
