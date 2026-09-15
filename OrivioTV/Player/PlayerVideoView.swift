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
    /// Zoom / aspect-ratio scale and vertical shift, applied as a UIKit
    /// transform on the CONTAINER. At the identity this is exactly no
    /// transform — the Metal video layer keeps its direct scan-out path and
    /// its colour handling — unlike a SwiftUI `scaleEffect`, which wraps the
    /// layer in a compositing transform even at 1.0 (washed-out HDR on the
    /// FFmpeg engine). And because the engine's view is never re-parented,
    /// returning to Normal never leaves a black picture.
    var scale: CGSize = CGSize(width: 1, height: 1)
    var shiftY: CGFloat = 0

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attach(to: container)
        applyTransform(to: container)
        reportBounds(of: container)
    }

    /// Probe the container's SIZE, on change only.
    ///
    /// This view fills the player's ZStack, which also hosts every overlay —
    /// so any sibling that overflows the screen silently drags the video's
    /// container with it, and a `.resizeAspect` layer in an oversized frame
    /// scales the picture up. That is a zoom with no zoom in it: `aspectMode`
    /// reads `fit`, the container transform stays the identity, and nothing in
    /// the player's own state is wrong — which is exactly why the Video tab
    /// overflowing by 78pt took a full investigation to find. Anything other
    /// than the screen size here is that bug, whatever caused it.
    private func reportBounds(of container: UIView) {
        let size = container.bounds.size
        guard size != Self.lastReportedSize.value, size != .zero else { return }
        Self.lastReportedSize.value = size
        let screen = UIScreen.main.bounds.size
        let fits = abs(size.width - screen.width) < 1 && abs(size.height - screen.height) < 1
        PlayerProbe.event("aspect", String(
            format: "video container %.0fx%.0f (screen %.0fx%.0f)%@",
            size.width, size.height, screen.width, screen.height,
            fits ? "" : "  <-- OVERSIZED, the picture is being scaled up"))
        if !fits { PlayerProbe.count("layout.container-oversized") }
    }

    /// Last size reported, so an `updateUIView` on every body pass doesn't
    /// flood the probe. A plain box: this is only ever touched on the main
    /// actor, from `updateUIView`.
    private final class SizeBox: @unchecked Sendable { var value: CGSize = .zero }
    private static let lastReportedSize = SizeBox()

    private func applyTransform(to container: UIView) {
        let wanted = scale.width == 1 && scale.height == 1 && shiftY == 0
            ? CGAffineTransform.identity
            : CGAffineTransform(translationX: 0, y: shiftY).scaledBy(x: scale.width, y: scale.height)
        guard container.transform != wanted else { return }
        // The picture is being rescaled — say so, with the numbers behind it.
        // This is the ONE place a zoom can actually be applied, so a report of
        // the picture zooming is either visible here or is not this transform
        // at all, and knowing which of those it is settles the question in one
        // reproduction instead of a hunt through the layout.
        PlayerProbe.event("aspect", String(
            format: "transform %.3fx%.3f shiftY=%.0f (was %.3fx%.3f)",
            scale.width, scale.height, shiftY,
            container.transform.a, container.transform.d))
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            container.transform = wanted
        }
    }

    private func attach(to container: UIView) {
        // Point PiP at whatever the engine ended up rendering into. Done here
        // rather than at load time because the render view only exists once
        // the engine has actually started, and it CHANGES on an engine swap.
        viewModel.refreshPictureInPictureSource()
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
            // Bitmap cues (PGS/VobSub) are pre-rendered images that carry their
            // own layout; left exactly as they were.
            ForEach(model.parts.filter { $0.image != nil }) { part in
                if let image = part.image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: geo.size.width * 0.9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 60)
                    }
                }
            }

            // TEXT CUES, GROUPED BY WHERE THE TRACK SAYS THEY BELONG.
            //
            // `SubtitleModel.subtitle(currentTime:)` publishes EVERY cue
            // overlapping the playhead, so a dialogue line and a sign/song
            // translation arrive together — routinely, in anime fansubs. Every
            // one of them used to be laid out identically (a full-screen VStack
            // with a Spacer and the same bottom padding) inside a ZStack, so
            // simultaneous cues were drawn on top of each other.
            //
            // Two things fix that. Cues are placed by their own
            // `textPosition` — ASS carries an alignment per style and per `\an`
            // override, which is exactly how a sign says "I belong at the top"
            // — and cues that land in the SAME place are stacked in one VStack
            // instead of overlaid.
            //
            // Nothing moves for ordinary subtitles: SRT has no position and
            // gets `TextPosition()`'s default, and standard ASS dialogue is
            // Alignment 2. Both are bottom-centre, where they already were.
            ForEach(textGroups, id: \.slot) { group in
                VStack(spacing: 6) {
                    ForEach(group.parts) { part in
                        if let text = part.text { caption(text) }
                    }
                }
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Self.alignment(for: group.slot))
                .padding(Self.padEdge(for: group.slot),
                         Self.padInset(for: group.slot, offset: settings.subtitleVerticalOffset))
            }
        }
        .allowsHitTesting(false)
    }

    /// One caption: the broadcast look, styled from Playback settings — text
    /// colour, optional true outline, background plate with adjustable opacity.
    private func caption(_ text: NSAttributedString) -> some View {
        styledCaption(text)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Color.black.opacity(settings.subtitleBackground
                    ? Double(settings.subtitleBackgroundOpacity) / 100 : 0),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    /// Text cues bucketed into the nine ASS screen positions, in a stable
    /// order. `slot` is `vertical * 3 + horizontal` (0 = top/leading).
    private var textGroups: [(slot: Int, parts: [SubtitlePart])] {
        let texts = model.parts.filter { $0.image == nil && $0.text != nil }
        return Dictionary(grouping: texts, by: Self.slot(of:))
            .sorted { $0.key < $1.key }
            .map { (slot: $0.key, parts: $0.value) }
    }

    /// No `textPosition` means SRT (or an addon's plain text) — bottom centre,
    /// which is where every caption in this app has always gone.
    private static func slot(of part: SubtitlePart) -> Int {
        guard let position = part.textPosition else { return 2 * 3 + 1 }
        let vertical: Int
        if position.verticalAlign == .top { vertical = 0 }
        else if position.verticalAlign == .center { vertical = 1 }
        else { vertical = 2 }
        let horizontal: Int
        if position.horizontalAlign == .leading { horizontal = 0 }
        else if position.horizontalAlign == .trailing { horizontal = 2 }
        else { horizontal = 1 }
        return vertical * 3 + horizontal
    }

    private static func alignment(for slot: Int) -> Alignment {
        switch (slot / 3, slot % 3) {
        case (0, 0): return .topLeading
        case (0, 1): return .top
        case (0, 2): return .topTrailing
        case (1, 0): return .leading
        case (1, 1): return .center
        case (1, 2): return .trailing
        case (2, 0): return .bottomLeading
        case (2, 2): return .bottomTrailing
        default:     return .bottom
        }
    }

    /// The ASS margins are deliberately NOT applied — the app's own inset is
    /// what "Vertical position" in Settings adjusts, and honouring a track's
    /// margins as well would move every caption for everyone.
    private static func padEdge(for slot: Int) -> Edge.Set {
        switch slot / 3 {
        case 0:  return .top
        case 1:  return []
        default: return .bottom
        }
    }

    private static func padInset(for slot: Int, offset: Int) -> CGFloat {
        switch slot / 3 {
        // Only the bottom row follows the viewer's offset: that setting means
        // "raise or lower the captions", and the captions are down there.
        case 2:  return CGFloat(84 + offset)
        case 0:  return 84
        default: return 0
        }
    }

    private var textColor: Color { Color(badgeHex: settings.subtitleTextColorHex) ?? .white }
    private var outlineColor: Color { Color(badgeHex: settings.subtitleOutlineColorHex) ?? .black }

    /// The configured caption face at the configured size. A family name that
    /// doesn't resolve on this box falls back to the system font (UIFont is
    /// the check — `Font.custom` itself falls back silently, but through a
    /// body-text metric rather than the caption size).
    private var captionFont: Font {
        let size = CGFloat(settings.subtitleSize)
        let name = settings.subtitleFontName
        if !name.isEmpty, UIFont(name: name, size: size) != nil {
            let custom = Font.custom(name, fixedSize: size)
            return settings.subtitleBold ? custom.bold() : custom
        }
        return .system(size: size, weight: settings.subtitleBold ? .bold : .medium)
    }

    /// Strip the cue's OWN presentation attributes so the Playback settings
    /// are the only thing deciding how a caption looks.
    ///
    /// Every embedded ASS/SSA track (most anime, most MKV remuxes) carries a
    /// full style in the subtitle header — `Fontname`, `Fontsize`, primary
    /// colour, outline colour — and KSPlayer's parser copies all of it onto
    /// the attributed string as `.font` / `.foregroundColor` / `.strokeColor`
    /// runs. A SwiftUI `.font()` or `.foregroundStyle()` modifier CANNOT
    /// override an attribute the string already carries, so those scripts
    /// rendered at their own point size — an 80pt ASS style is text across the
    /// whole screen — and the Size control did nothing at all. The outline had
    /// the same problem from the other side: the 8-way stroke below is the
    /// same `Text` re-tinted, and a cue carrying its own white
    /// `.foregroundColor` ignored the tint, so the "black" outline drew white.
    ///
    /// Only the presentation attributes go. Emphasis the script author meant
    /// (italics, underline, strikethrough) is left alone.
    private func restyled(_ text: NSAttributedString) -> AttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: mutable.length)
        for key: NSAttributedString.Key in [
            .font, .foregroundColor, .backgroundColor,
            .strokeColor, .strokeWidth, .shadow, .expansion
        ] {
            mutable.removeAttribute(key, range: whole)
        }
        return AttributedString(mutable)
    }

    /// One caption line with the configured color and (optionally) a real
    /// outline — SwiftUI has no text stroke, so the outline is the same text
    /// rendered in 8 directions behind the fill. Falls back to a soft double
    /// shadow when the outline is off.
    @ViewBuilder
    private func styledCaption(_ text: NSAttributedString) -> some View {
        let base = Text(restyled(text))
            .font(captionFont)
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
