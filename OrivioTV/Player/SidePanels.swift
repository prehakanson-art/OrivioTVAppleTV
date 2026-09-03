import SwiftUI

/// Right-anchored panel used for episodes, sources, tracks and speed,
/// mirroring Orivio's in-player side sheets.
struct SidePanel<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    /// Back/Menu handler — always just returns to the main controls, never
    /// exits the player. Passed in (rather than reaching for a shared view
    /// model) so this stays a small, reusable presentational view.
    var onExitCommand: () -> Void = {}
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: OrivioSpacing.lg) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 60)
                content
                Spacer(minLength: 40)
            }
            // `huge` (64pt), matching `FusionMetrics.sideInset` on the player's
            // own controls. At `xl` (28pt) the trailing resolution and size
            // badges and the selected checkmark sat inside the tvOS title-safe
            // inset — 60pt at the 1920x1080 reference — so any TV that
            // overscans clipped them. The background still bleeds to the edge;
            // only the content moves in.
            .padding(.horizontal, OrivioSpacing.huge)
            .frame(width: 640, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(theme.palette.panel.opacity(0.98))
        }
        .ignoresSafeArea()
        // Slide only — the dimming is a separate scrim (see PlayerScreen) so the
        // panel just moves sideways instead of sliding AND fading at once.
        .transition(.move(edge: .trailing))
        // Defensive: attached directly beside the panel's own ScrollView
        // (rather than relying only on PlayerScreen's top-level handler) so a
        // Menu press while focus is deep inside the row list is guaranteed to
        // land here and return to the controls — never fall through and
        // close the whole player.
        .onExitCommand(perform: onExitCommand)
    }
}

struct PanelRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    let title: String
    var subtitle: String?
    var selected: Bool = false
    /// Stacked trailing badges: resolution over file size (Sources rows).
    var resolution: String?
    var fileSize: String?
    /// Badger badge chips (in-player Sources rows).
    var badges: [StreamBadge] = []

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 19))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
                if !badges.isEmpty {
                    StreamBadgeChips(badges: badges)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if resolution != nil || fileSize != nil {
                VStack(alignment: .trailing, spacing: 4) {
                    if let resolution {
                        MetaBadge(
                            text: resolution,
                            tint: theme.palette.secondary.opacity(0.22),
                            textColor: theme.palette.secondary
                        )
                    }
                    if let fileSize {
                        MetaBadge(
                            text: fileSize,
                            tint: Color.white.opacity(0.12),
                            textColor: .white.opacity(0.85)
                        )
                    }
                }
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(theme.palette.secondary)
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : .white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 2.5)
        )
        .focusLift(OrivioFocus.row, isFocused)
    }
}

struct EpisodesPanelContent: View {
    @ObservedObject var viewModel: PlayerViewModel
    // Open with focus already on the episode you're watching, so the trackpad
    // navigates out from there instead of the top of the list.
    @FocusState private var focused: String?

    // displayMeta, NOT the launch meta: a Continue Watching session starts
    // with a bare record (no episode list) — the enriched Cinemeta fetch is
    // what carries the videos.
    private var episodes: [MetaVideo] {
        guard let season = viewModel.currentVideo?.season else { return [] }
        return viewModel.displayMeta.episodes(season: season)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: OrivioSpacing.sm) {
                if episodes.isEmpty {
                    // Focusable so Menu still lands in the panel.
                    Button {} label: {
                        PanelRow(
                            title: "Episodes unavailable",
                            subtitle: "The episode list hasn't loaded for this session yet."
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
                ForEach(episodes) { episode in
                    let isCurrent = episode.id == viewModel.currentVideo?.id
                    Button {
                        viewModel.play(episode: episode)
                    } label: {
                        EpisodeRow(
                            episode: episode,
                            fallbackImage: viewModel.displayMeta.background,
                            isCurrent: isCurrent
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focused, equals: episode.id)
                    // Press-and-hold on an episode → choose a specific source
                    // for it, or mark it watched.
                    .contextMenu {
                        Button {
                            viewModel.play(episode: episode, presentSources: true)
                        } label: {
                            Label("Choose Source", systemImage: "list.bullet")
                        }
                        Button {
                            viewModel.markEpisodeWatched(episode)
                        } label: {
                            Label("Mark as Watched", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .padding(.vertical, OrivioSpacing.sm)
        }
        .scrollClipDisabled()
        .defaultFocus($focused, viewModel.currentVideo?.id)
    }
}

/// One row in the in-player Episodes list: thumbnail + title/overview, with a
/// distinct highlight (accent border + "Now Playing" tag) on the episode
/// that's currently playing.
private struct EpisodeRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let episode: MetaVideo
    let fallbackImage: String?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: episode.thumbnail ?? fallbackImage)
                    .frame(width: 170, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: OrivioRadius.sm, style: .continuous))
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(theme.palette.secondary, in: Circle())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if isCurrent {
                    Text("NOW PLAYING")
                        .font(.system(size: 13, weight: .heavy))
                        .kerning(1.1)
                        .foregroundStyle(theme.palette.secondary)
                }
                Text("\(episode.episode.map { "\($0). " } ?? "")\(episode.title ?? "Episode")")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 19))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .padding(.vertical, OrivioSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground
                      : isCurrent ? theme.palette.secondary.opacity(0.14)
                      : .white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(
                    isFocused ? theme.palette.focusRing
                    : isCurrent ? theme.palette.secondary.opacity(0.7) : .clear,
                    lineWidth: isFocused ? 2.5 : 2
                )
        )
        .focusLift(OrivioFocus.row, isFocused)
    }
}

struct SourcesPanelContent: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    // Land on the source that's currently playing.
    @FocusState private var focused: UUID?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: OrivioSpacing.sm) {
                // The status rows are FOCUSABLE no-op buttons on purpose: with
                // nothing focusable inside the panel, a Menu press would fall
                // through the player entirely and close it.
                if viewModel.isLoadingSources {
                    Button {} label: {
                        HStack(spacing: OrivioSpacing.md) {
                            ProgressView()
                            PanelRow(title: "Searching sources…")
                        }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                } else if viewModel.allEntries.isEmpty {
                    Button {} label: {
                        PanelRow(title: "No sources found", subtitle: "None of your stream addons returned a link for this title.")
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
                ForEach(viewModel.allEntries) { entry in
                    Button {
                        viewModel.switchSource(entry)
                    } label: {
                        PanelRow(
                            title: entry.displayName,
                            subtitle: "\(entry.addonName)\(entry.displayDetail.isEmpty ? "" : " · \(entry.displayDetail)")",
                            selected: entry.id == viewModel.currentEntry.id,
                            resolution: entry.resolutionLabel,
                            fileSize: entry.fileSizeLabel,
                            badges: streamBadges.badges(for: entry)
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focused, equals: entry.id)
                }
            }
            .padding(.vertical, OrivioSpacing.sm)
        }
        .scrollClipDisabled()
        .defaultFocus($focused, viewModel.currentEntry.id)
    }
}

struct TrackPanelContent: View {
    let options: [TrackOption]
    let selectedID: String?
    let onSelect: (TrackOption) -> Void
    // Land on the currently-selected track/subtitle.
    @FocusState private var focused: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: OrivioSpacing.sm) {
                if options.isEmpty {
                    // Focusable so Menu still lands in the panel (see Sources).
                    Button {} label: {
                        PanelRow(title: "No tracks available in this stream")
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        PanelRow(title: option.displayName, selected: option.id == selectedID)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .focused($focused, equals: option.id)
                }
            }
            .padding(.vertical, OrivioSpacing.sm)
        }
        .scrollClipDisabled()
        .defaultFocus($focused, selectedID)
    }
}

/// Live subtitle-timing offset control at the top of the Subtitles panel:
/// −0.5 s / value / +0.5 s, plus a Reset when non-zero. Positive = subtitles
/// appear later (drag them right on the timeline).
struct SubtitleDelayControl: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.xs) {
            Text("SUBTITLE DELAY")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(theme.palette.textTertiary)
                .padding(.leading, 4)
            HStack(spacing: OrivioSpacing.sm) {
                delayButton("−0.5 s", systemImage: "minus") {
                    viewModel.nudgeSubtitleDelay(by: -0.5)
                }
                Text(PlayerViewModel.formatDelay(viewModel.subtitleDelay))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(minWidth: 96)
                delayButton("+0.5 s", systemImage: "plus") {
                    viewModel.nudgeSubtitleDelay(by: 0.5)
                }
                if viewModel.subtitleDelay != 0 {
                    delayButton("Reset", systemImage: "arrow.counterclockwise") {
                        viewModel.resetSubtitleDelay()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, OrivioSpacing.xs)
    }

    private func delayButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, OrivioSpacing.md)
                .padding(.vertical, OrivioSpacing.sm)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

/// In-player engine picker — reload the current stream through a different
/// playback engine (the "this file is choppy, try VLC" escape hatch), keeping
/// the playback position.
struct EnginePanelContent: View {
    @ObservedObject var viewModel: PlayerViewModel
    @FocusState private var focused: PlayerEngine?

    var body: some View {
        VStack(spacing: OrivioSpacing.sm) {
            // .external is a pre-playback handoff, not an in-player engine —
            // it can't take over a session that's already playing here.
            ForEach(PlayerEngine.allCases.filter { $0 != .external }, id: \.self) { engine in
                Button {
                    viewModel.switchEngine(engine)
                } label: {
                    PanelRow(
                        title: engine.label,
                        subtitle: engine == .vlc
                            ? "VLC renders its own subtitles; no cache bar"
                            : nil,
                        selected: viewModel.effectiveEngine == engine
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focused, equals: engine)
            }
            // A diagnostic, so it rides with the diagnostics HUD (Settings →
            // Performance) rather than sitting in the Engine panel for everyone.
            // The triple-press Play/Pause shortcut still works with the row
            // hidden — that is the escape hatch for a grey screen you can't
            // navigate a menu on.
            if PerformanceSettingsStore.shared.settings.showPlayerDiagnostics
                || ProcessInfo.processInfo.arguments.contains("-playerHUD") {
                Button {
                    viewModel.resyncDisplay()
                } label: {
                    PanelRow(
                        title: "Re-sync display",
                        subtitle: "If the TV shows grey or wrong colors, renegotiate the connection (also: triple-press Play/Pause)",
                        selected: false
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
            }
        }
        .defaultFocus($focused, viewModel.effectiveEngine)
    }
}

struct SpeedPanelContent: View {
    @ObservedObject var viewModel: PlayerViewModel
    // Land on the current speed.
    @FocusState private var focused: Float?

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: OrivioSpacing.sm) {
            ForEach(speeds, id: \.self) { speed in
                Button {
                    viewModel.setSpeed(speed)
                    viewModel.overlay = .controls
                } label: {
                    PanelRow(
                        title: speed == 1.0 ? "Normal" : String(format: "%gx", speed),
                        selected: viewModel.playbackSpeed == speed
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focused, equals: speed)
            }
        }
        .defaultFocus($focused, viewModel.playbackSpeed)
    }
}
