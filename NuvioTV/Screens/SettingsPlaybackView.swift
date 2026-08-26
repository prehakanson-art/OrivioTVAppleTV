import SwiftUI

/// Settings → Playback: post-play / auto-next controls, mirroring the Android
/// autoplay settings section (next episode, still-watching gate, threshold
/// mode/value, countdown timeout, binge-group preference). Every row here is
/// wired to `PlayerSettingsStore` and actually changes player behavior.
struct PlaybackSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var store: PlayerSettingsStore

    private var s: Binding<PlayerSettings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        DetailScaffold(title: SettingsCategory.playback.title, subtitle: SettingsCategory.playback.subtitle) {
            SettingsGroupCard(title: "Auto-play", subtitle: "What happens when an episode finishes") {
                autoPlayControls
            }
            SettingsGroupCard(title: "Seeking", subtitle: "How far a single skip jumps") {
                NuvioDropdown(
                    title: "Skip amount",
                    subtitle: "Each left/right press; rapid presses add up, holding accelerates",
                    icon: "goforward",
                    selection: String(store.settings.skipSeconds),
                    options: PlayerSettings.skipValues.map { NuvioDropdownOption(String($0), "\($0) seconds") }
                ) { store.settings.skipSeconds = Int($0) ?? 10 }

                NuvioDropdown(
                    title: "Scrubber jump",
                    subtitle: "Left/right press while scrubbing with the trackpad",
                    icon: "forward.frame.fill",
                    selection: String(store.settings.scrubJumpSeconds),
                    options: PlayerSettings.scrubJumpValues.map {
                        NuvioDropdownOption(String($0), $0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 >= 120 ? "s" : "")")
                    }
                ) { store.settings.scrubJumpSeconds = Int($0) ?? 60 }

                PlaybackToggleRow(
                    icon: "forward.frame.fill",
                    title: "Skip Intro button",
                    subtitle: "Show a Skip Intro pill while inside an intro/recap chapter (⏯ skips it)",
                    isOn: s.skipIntroEnabled
                )

                PlaybackToggleRow(
                    icon: "forward.fill",
                    title: "Auto-skip intros",
                    subtitle: "Jump past intro and recap chapters automatically, no button press. Needs chapter markers in the file.",
                    isOn: s.autoSkipSegments
                )

                PlaybackToggleRow(
                    icon: "sparkles.tv",
                    title: "AniSkip for anime",
                    subtitle: "Fetch anime intro/outro skip times (AniSkip) for episodes that carry no chapter markers, so Skip Intro and Up Next work on anime web releases.",
                    isOn: s.animeSkipEnabled
                )

                PlaybackToggleRow(
                    icon: "ladybug.fill",
                    title: "Show input debug",
                    subtitle: "Overlay the last trackpad/remote event in the player (for tuning gestures on a real Apple TV)",
                    isOn: s.showInputDebug
                )
            }

            SettingsGroupCard(title: "Sources", subtitle: "Which links the source lists show") {
                PlaybackToggleRow(
                    icon: "line.3.horizontal.decrease.circle.fill",
                    title: "Link filters",
                    subtitle: "Smart-rank links: each addon grouped by resolution — scored by cached status, release quality (REMUX > Blu-ray > WEB-DL), codec, HDR/DV, audio, seeders and bitrate. Off = show links exactly as each addon returns them (cached still first), up to \(PlayerSettings.unfilteredPerAddonCap) per addon",
                    isOn: s.sourceFiltersEnabled
                )

                if store.settings.sourceFiltersEnabled {
                    NuvioDropdown(
                        title: "Links per resolution",
                        subtitle: "Best-scored links kept in each of 2160p / 1080p / 720p / 480p per addon",
                        icon: "square.stack.3d.up.fill",
                        selection: String(store.settings.sourcesPerSizeTier),
                        options: PlayerSettings.sourcesPerTierValues.filter { $0 > 0 }.map {
                            NuvioDropdownOption(String($0), "\($0) links")
                        }
                    ) { store.settings.sourcesPerSizeTier = Int($0) ?? 6 }
                }

                NuvioDropdown(
                    title: "Minimum resolution",
                    subtitle: "Hide links below this quality (links with no resolution tag are kept)",
                    icon: "arrow.up.right.video.fill",
                    selection: store.settings.streamMinResolution,
                    options: [NuvioDropdownOption("", "No minimum")]
                        + ["2160p", "1080p", "720p", "480p"].map { NuvioDropdownOption($0, $0) }
                ) { store.settings.streamMinResolution = $0 }

                PlaybackToggleRow(
                    icon: "cpu.fill",
                    title: "Hide AV1 links",
                    subtitle: "AV1 has no hardware decode on the Apple TV — those links stutter",
                    isOn: s.streamExcludeAV1
                )

                PlaybackToggleRow(
                    icon: "sparkles",
                    title: "HDR only",
                    subtitle: "Only show HDR10 / HLG / Dolby Vision links",
                    isOn: s.streamHDROnly
                )

                PlaybackToggleRow(
                    icon: "sparkles.tv.fill",
                    title: "Dolby Vision only",
                    subtitle: "Only show Dolby Vision links",
                    isOn: s.streamDolbyVisionOnly
                )

                PlaybackToggleRow(
                    icon: "bolt.fill",
                    title: "Cached only",
                    subtitle: "Only show debrid-cached links (instant play, no download wait)",
                    isOn: s.streamCachedOnly
                )
            }

            SettingsGroupCard(title: "Content", subtitle: "Advisories shown on the details page") {
                PlaybackToggleRow(
                    icon: "exclamationmark.shield.fill",
                    title: "Parental guide",
                    subtitle: "Show IMDb content advisories (sex, violence, profanity, drugs, frightening) on the details page",
                    isOn: s.parentalGuideEnabled
                )
            }

            // Advanced-only cards (hidden in Essential experience mode).
            if theme.experienceMode.isAdvanced {
            SettingsGroupCard(title: "Auto-play source", subtitle: "Skip the Sources page and start playing on its own") {
                PlaybackToggleRow(
                    icon: "play.circle.fill",
                    title: "Auto-play best source",
                    subtitle: "When you open a title, start the top-ranked link automatically instead of showing the source list",
                    isOn: s.autoPlaySourceEnabled
                )

                if store.settings.autoPlaySourceEnabled {
                    PlaybackToggleRow(
                        icon: "bolt.fill",
                        title: "Cached sources only",
                        subtitle: "Only auto-play a debrid-cached / instant link — never wait on a torrent that has to resolve first",
                        isOn: s.autoPlaySourceCachedOnly
                    )

                    HStack(spacing: NuvioSpacing.md) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 26))
                            .foregroundStyle(theme.palette.textSecondary)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Match (optional)")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(theme.palette.textPrimary)
                            TextField("e.g. 2160p|remux", text: s.autoPlaySourceRegex)
                                .font(.system(size: 22))
                            Text("Case-insensitive; the auto-played link's name must match. Blank = first in the list.")
                                .font(.system(size: 18))
                                .foregroundStyle(theme.palette.textTertiary)
                        }
                    }
                }

                PlaybackToggleRow(
                    icon: "arrow.clockwise.circle.fill",
                    title: "Reuse last link",
                    subtitle: "Replay the last source you played for a title without searching addons again, within the window below",
                    isOn: s.reuseLastLinkEnabled
                )

                if store.settings.reuseLastLinkEnabled {
                    NuvioDropdown(
                        title: "Reuse window",
                        subtitle: "How long a remembered link stays valid before Orivio searches again",
                        icon: "clock.fill",
                        selection: String(store.settings.reuseLastLinkCacheHours),
                        options: PlayerSettings.reuseLastLinkHoursValues.map {
                            NuvioDropdownOption(String($0), $0 < 24 ? "\($0) hours" : "\($0 / 24) day\($0 >= 48 ? "s" : "")")
                        }
                    ) { store.settings.reuseLastLinkCacheHours = Int($0) ?? 24 }
                }
            }

            SettingsGroupCard(title: "Player", subtitle: "Which engine opens streams") {
                NuvioDropdown(
                    title: "Playback engine",
                    subtitle: store.settings.playerEngine.footnote,
                    icon: "play.rectangle.on.rectangle.fill",
                    selection: store.settings.playerEngine.rawValue,
                    options: PlayerEngine.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                ) { store.settings.playerEngine = PlayerEngine(rawValue: $0) ?? .auto }

                NuvioDropdown(
                    title: "Playback mode",
                    subtitle: "Automatic picks the best supported path. Maximum Fidelity never downgrades (native Dolby Vision, Profile 7 conversion always on, Atmos renderer when the route supports it) — heaviest on older boxes. Compatibility takes the most forgiving path for streams that misbehave.",
                    icon: "dial.high.fill",
                    selection: store.settings.playbackMode.rawValue,
                    options: PlaybackMode.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                ) { store.settings.playbackMode = PlaybackMode(rawValue: $0) ?? .automatic }

                NuvioDropdown(
                    title: "Buffer ahead",
                    subtitle: "How much of the video to download ahead so a slow/bursty connection doesn't rebuffer. Auto sizes to the file. The MB/GB options pre-load roughly that much of the movie before it's needed. Capped to what your Apple TV's memory can hold (no disk cache on tvOS), so on a 3 GB model the big options top out ~600 MB.",
                    icon: "gauge.with.dots.needle.50percent",
                    selection: store.settings.bufferProfile.rawValue,
                    options: BufferProfile.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                ) { store.settings.bufferProfile = BufferProfile(rawValue: $0) ?? .auto }

                // External engine: pick WHICH installed app receives streams.
                // canOpenURL only sees apps actually on this Apple TV, so the
                // list is exactly what's installed — and when nothing is, the
                // section stays blank.
                if store.settings.playerEngine == .external {
                    let installed = ExternalPlayers.installed
                    if !installed.isEmpty {
                        NuvioDropdown(
                            title: "External player",
                            subtitle: "Streams open in this app; playback, resume and history then live there",
                            icon: "arrow.up.forward.app.fill",
                            selection: store.settings.externalPlayerID,
                            options: installed.map { NuvioDropdownOption($0.id, $0.name) }
                        ) { store.settings.externalPlayerID = $0 }

                        PlaybackToggleRow(
                            icon: "captions.bubble.fill",
                            title: "Forward subtitles",
                            subtitle: "Fetch a subtitle in your preferred language from your subtitle addons and pass it to the external player (Infuse / VLC / VidHub)",
                            isOn: s.externalPlayerForwardSubtitles
                        )

                        // Only Infuse takes a playlist; the row would be a lie
                        // for the players whose scheme carries one url.
                        if (ExternalPlayers.player(id: store.settings.externalPlayerID)
                            ?? installed.first)?.supportsPlaylist == true {
                            PlaybackToggleRow(
                                icon: "list.and.film",
                                title: "Send the rest of the season",
                                subtitle: "Hand the next few episodes over as a playlist so next-episode keeps working in the other app. Their links are resolved before the handoff, which adds a moment to starting a show; the episode you pressed play on always goes first.",
                                isOn: s.externalPlayerSendPlaylist
                            )
                        }
                    }
                }

                PlaybackToggleRow(
                    icon: "rectangle.on.rectangle.badge.gearshape",
                    title: "HDR10+ passthrough",
                    subtitle: "Send HDR10+ dynamic metadata to the TV instead of the plain HDR10 base layer, so brightness is mapped scene by scene. The metadata lives inside the video, and only Apple's own pipeline carries it through — so a matching file is remuxed on-device the same way Dolby Vision is, and falls back to HDR10 if anything fails. Needs an Apple TV 4K (3rd gen) or newer on tvOS 18.4+, an HDR10+ TV, and an HDR10+ file; Dolby Vision always wins when a file has both.",
                    isOn: s.hdr10PlusPassthrough,
                    unavailable: PerformanceProfile.hdr10PlusUnavailableReason
                )

                PlaybackToggleRow(
                    icon: "sparkles.tv.fill",
                    title: "Native Dolby Vision",
                    subtitle: "Play Dolby Vision files (profile 5/8) through Apple's video pipeline for true dynamic DV on DV-capable TVs. Remuxes on-device; falls back to the standard HDR10 engine automatically if anything fails. Off = always use the standard engine.",
                    isOn: s.nativeDolbyVision
                )

                if s.nativeDolbyVision.wrappedValue {
                    PlaybackToggleRow(
                        icon: "square.stack.3d.up.fill",
                        title: "Dolby Vision Profile 7",
                        subtitle: "Also handle dual-layer Profile 7 files (UHD Blu-ray remuxes) by converting them to Profile 8.1 on the fly, for native DV instead of the HDR10 tone-map. \(PerformanceProfile.recommendsDolbyVisionProfile7 ? "On by default on \(PerformanceProfile.tierLabel)." : "Off by default on \(PerformanceProfile.tierLabel): the on-the-fly conversion re-processes the whole file and can freeze playback on this box — turn on only if you accept that.") If a P7 title looks wrong, turn this off and it reverts to HDR10. Needs Native Dolby Vision on.\(ExternalPlayers.player(id: "senplayer")?.isInstalled == true ? " SenPlayer is installed on this Apple TV and does the same P7 → 8.1 conversion in its own app — set Playback engine to External and pick it there to hand P7 titles off instead of converting them here." : "")",
                        isOn: s.dolbyVisionProfile7
                    )

                    if s.dolbyVisionProfile7.wrappedValue {
                        NuvioDropdown(
                            title: "DV7 conversion speed",
                            subtitle: "How hard the Profile 7 → 8.1 conversion is allowed to work. \"Smooth\" runs it at low priority and paces it to just above realtime after a short head start, so it won't starve a RAM-limited Apple TV (the 3 GB gen-1) into a freeze; \"Fast\" runs it flat out (best on 4 GB+ boxes). If DV7 hangs this box, choose Smooth.",
                            icon: "speedometer",
                            selection: store.settings.dolbyVisionProfile7Pace.rawValue,
                            options: DolbyVisionRemuxPace.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                        ) { store.settings.dolbyVisionProfile7Pace = DolbyVisionRemuxPace(rawValue: $0) ?? .deviceDefault }
                    }
                }

                PlaybackToggleRow(
                    icon: "tv.fill",
                    title: "Match content display mode",
                    subtitle: "Also switch the TV into the matching HDR mode and refresh rate for non-Dolby-Vision videos (HDR10/SDR). Dolby Vision always switches — that's the point of DV — and the mode is held until you leave the app, so the TV only ever sees one switch per session. Off = non-DV videos tone-map into the home screen's format.",
                    isOn: s.matchContentDisplayMode
                )

                

                NuvioDropdown(
                    title: "Video scaling",
                    subtitle: "Default zoom for the video. Cycle it live in the player with the aspect button.",
                    icon: "aspectratio.fill",
                    selection: store.settings.aspectModeRaw,
                    options: AspectMode.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                ) { store.settings.aspectModeRaw = $0 }
            }

            SettingsGroupCard(title: "On-screen display", subtitle: "Player overlays and status") {
                PlaybackToggleRow(
                    icon: "pause.rectangle.fill",
                    title: "Pause overlay",
                    subtitle: "Show the info overlay (title, artwork, progress) when playback is paused",
                    isOn: s.pauseOverlayEnabled
                )
                PlaybackToggleRow(
                    icon: "clock.fill",
                    title: "Clock",
                    subtitle: "Show a wall clock on the player controls",
                    isOn: s.osdClockEnabled
                )
                PlaybackToggleRow(
                    icon: "photo.fill",
                    title: "Loading backdrop",
                    subtitle: "Show the full-screen loading screen (artwork + spinner) while a stream opens",
                    isOn: s.loadingOverlayEnabled
                )
                if store.settings.loadingOverlayEnabled {
                    PlaybackToggleRow(
                        icon: "text.append",
                        title: "Loading status",
                        subtitle: "Show the “Loading / Caching %” text and cache bar on the loading screen",
                        isOn: s.showPlayerLoadingStatus
                    )
                }
            }

            SettingsGroupCard(title: "Audio", subtitle: "Track selection and output") {
                NuvioDropdown(
                    title: "Preferred language",
                    subtitle: "Automatically pick a matching audio track when the stream has one",
                    icon: "waveform",
                    selection: store.settings.preferredAudioLanguage,
                    options: PlayerSettings.audioLanguageOptions.map { NuvioDropdownOption($0.0, $0.1) }
                ) { store.settings.preferredAudioLanguage = $0 }

                NuvioDropdown(
                    title: "Surround & Dolby Atmos",
                    subtitle: "Auto uses the enhanced renderer (Atmos/spatial + lighter TrueHD/DTS-HD decode) only when your TV or receiver reports spatial-audio support. Takes effect on next playback.",
                    icon: "hifispeaker.2.fill",
                    selection: store.settings.audioOutputMode.rawValue,
                    options: AudioOutputMode.allCases.map { NuvioDropdownOption($0.rawValue, $0.label) }
                ) { store.settings.audioOutputMode = AudioOutputMode(rawValue: $0) ?? .auto }
            }
            } // end advanced-only cards

            SettingsGroupCard(title: "Subtitles", subtitle: "How captions look and when they turn on") {
                PlaybackToggleRow(
                    icon: "captions.bubble.fill",
                    title: "Subtitles on by default",
                    subtitle: "Automatically enable subtitles when a stream loads, picking your preferred language when it's available",
                    isOn: s.subtitlesOnByDefault
                )

                PlaybackToggleRow(
                    icon: "textformat.alt",
                    title: "Full styled subtitles (ASS/SSA)",
                    subtitle: "Render fancy anime/fansub subtitles — custom fonts, positioning, karaoke — properly. Titles that carry ASS/SSA subtitles play in the VLC engine (which includes libass and reads embedded fonts). You lose that title's scrub-thumbnail preview while it plays. Off = the built-in renderer (readable text, but drops fonts/effects).",
                    isOn: s.fullAssSubtitles
                )

                if store.settings.subtitlesOnByDefault {
                    NuvioDropdown(
                        title: "Preferred language",
                        subtitle: "Chosen automatically when the stream has a matching subtitle; otherwise the first available is used",
                        icon: "globe",
                        selection: store.settings.preferredSubtitleLanguage,
                        options: PlayerSettings.subtitleLanguageOptions.map { NuvioDropdownOption($0.0, $0.1) }
                    ) { store.settings.preferredSubtitleLanguage = $0 }

                    NuvioDropdown(
                        title: "Secondary language",
                        subtitle: "Used when the preferred language isn't available",
                        icon: "globe.badge.chevron.backward",
                        selection: store.settings.subtitleSecondaryLanguage,
                        options: PlayerSettings.subtitleLanguageOptions.map { NuvioDropdownOption($0.0, $0.1) }
                    ) { store.settings.subtitleSecondaryLanguage = $0 }

                    PlaybackToggleRow(
                        icon: "exclamationmark.bubble.fill",
                        title: "Prefer forced subtitles",
                        subtitle: "When a forced track (foreign dialogue only) exists in your language, choose it",
                        isOn: s.subtitlePreferForced
                    )
                }

                NuvioDropdown(
                    title: "Text size",
                    icon: "textformat.size",
                    selection: String(store.settings.subtitleSize),
                    options: PlayerSettings.subtitleSizeValues.map {
                        NuvioDropdownOption(String($0), sizeLabel($0))
                    }
                ) { store.settings.subtitleSize = Int($0) ?? 36 }

                NuvioDropdown(
                    title: "Timing offset",
                    subtitle: "Shift captions earlier (−) or later (+). Adjustable live from the Subtitles panel during playback.",
                    icon: "timer",
                    selection: String(store.settings.subtitleDelaySeconds),
                    options: PlayerSettings.subtitleDelayValues.map {
                        NuvioDropdownOption(String($0), PlayerViewModel.formatDelay($0))
                    }
                ) { store.settings.subtitleDelaySeconds = Double($0) ?? 0 }

                NuvioDropdown(
                    title: "Text color",
                    icon: "paintpalette.fill",
                    selection: store.settings.subtitleTextColorHex,
                    options: PlayerSettings.subtitleColorOptions.map { NuvioDropdownOption($0.0, $0.1) }
                ) { store.settings.subtitleTextColorHex = $0 }

                PlaybackToggleRow(
                    icon: "bold",
                    title: "Bold text",
                    subtitle: "Heavier caption weight",
                    isOn: s.subtitleBold
                )

                PlaybackToggleRow(
                    icon: "a.square.fill",
                    title: "Outline",
                    subtitle: "Draw an outline around the text so it's readable on any background",
                    isOn: s.subtitleOutlineEnabled
                )

                if store.settings.subtitleOutlineEnabled {
                    NuvioDropdown(
                        title: "Outline color",
                        icon: "scribble",
                        selection: store.settings.subtitleOutlineColorHex,
                        options: PlayerSettings.subtitleColorOptions.map { NuvioDropdownOption($0.0, $0.1) }
                    ) { store.settings.subtitleOutlineColorHex = $0 }

                    NuvioDropdown(
                        title: "Outline thickness",
                        icon: "lineweight",
                        selection: String(store.settings.subtitleOutlineWidth),
                        options: PlayerSettings.subtitleOutlineWidthValues.map {
                            NuvioDropdownOption(String($0), $0 == 1 ? "Thin (1 pt)" : "\($0) pt")
                        }
                    ) { store.settings.subtitleOutlineWidth = Int($0) ?? 2 }
                }

                PlaybackToggleRow(
                    icon: "rectangle.fill.on.rectangle.fill",
                    title: "Background plate",
                    subtitle: "Panel behind captions for readability on bright scenes",
                    isOn: s.subtitleBackground
                )

                if store.settings.subtitleBackground {
                    NuvioDropdown(
                        title: "Background opacity",
                        icon: "circle.lefthalf.filled",
                        selection: String(store.settings.subtitleBackgroundOpacity),
                        options: PlayerSettings.subtitleBackgroundOpacityValues.map {
                            NuvioDropdownOption(String($0), "\($0)%")
                        }
                    ) { store.settings.subtitleBackgroundOpacity = Int($0) ?? 45 }
                }

                NuvioDropdown(
                    title: "Vertical position",
                    subtitle: "Raise or lower the captions",
                    icon: "arrow.up.and.down.text.horizontal",
                    selection: String(store.settings.subtitleVerticalOffset),
                    options: PlayerSettings.subtitleOffsetValues.map {
                        NuvioDropdownOption(String($0), $0 == 0 ? "Default" : ($0 > 0 ? "Higher +\($0)" : "Lower \($0)"))
                    }
                ) { store.settings.subtitleVerticalOffset = Int($0) ?? 0 }
            }

            SettingsGroupCard(title: "Trailers", subtitle: "Preview a title's trailer while browsing") {
                NuvioDropdown(
                    title: "Auto-play trailer",
                    subtitle: "Play the trailer in the backdrop after sitting on a title",
                    icon: "play.tv.fill",
                    selection: String(store.settings.autoPlayTrailerSeconds),
                    options: PlayerSettings.trailerDelayValues.map {
                        NuvioDropdownOption(String($0), $0 == 0 ? "Off" : "After \($0)s")
                    }
                ) { store.settings.autoPlayTrailerSeconds = Int($0) ?? 0 }
            }
        }
    }

    @ViewBuilder
    private var autoPlayControls: some View {
        PlaybackToggleRow(
            icon: "forward.end.fill",
            title: "Auto-play next episode",
            subtitle: "Run a countdown on the Up Next card and start the next episode automatically. Off = the card still appears, but waits for you to press Play",
            isOn: s.autoPlayNextEpisode
        )

        // Shown regardless of auto-play — the Up Next card always appears.
        NuvioDropdown(
            title: "Show Up Next",
            subtitle: "When credits chapters exist the card appears as they start; otherwise this many seconds before the end",
            icon: "clock.fill",
            selection: String(store.settings.upNextLeadSeconds),
            options: PlayerSettings.upNextLeadValues.map {
                NuvioDropdownOption(String($0), $0 < 60 ? "\($0) seconds before end" : "\($0 / 60) min before end")
            }
        ) { store.settings.upNextLeadSeconds = Int($0) ?? 30 }

        if store.settings.autoPlayNextEpisode {
            PlaybackToggleRow(
                icon: "eye.fill",
                title: "Still watching?",
                subtitle: "Pause auto-play after several episodes to check you're still there",
                isOn: s.stillWatchingEnabled
            )

            if store.settings.stillWatchingEnabled {
                NuvioDropdown(
                    title: "Ask after",
                    icon: "repeat",
                    selection: String(store.settings.stillWatchingEpisodeThreshold),
                    options: (2...6).map { NuvioDropdownOption(String($0), "\($0) episodes") }
                ) { store.settings.stillWatchingEpisodeThreshold = Int($0) ?? 3 }
            }

            NuvioDropdown(
                title: "Auto-play countdown",
                icon: "timer",
                selection: String(store.settings.autoPlayTimeoutSeconds),
                options: PlayerSettings.timeoutValues.map { NuvioDropdownOption(String($0), timeoutLabel($0)) }
            ) { store.settings.autoPlayTimeoutSeconds = Int($0) ?? 3 }

            PlaybackToggleRow(
                icon: "square.stack.3d.up.fill",
                title: "Prefer same source group",
                subtitle: "Pick the next episode from the same release group when possible",
                isOn: s.preferBingeGroupForNextEpisode
            )

            if store.settings.preferBingeGroupForNextEpisode {
                PlaybackToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Reuse the same source",
                    subtitle: "Keep the next episode on the same addon as well as the same group, so it's as close to the current source as possible",
                    isOn: s.reuseBingeGroup
                )
            }
        }
    }

    private func sizeLabel(_ size: Int) -> String {
        switch size {
        case ..<32: return "Small (\(size)pt)"
        case ..<40: return "Standard (\(size)pt)"
        case ..<50: return "Large (\(size)pt)"
        default: return "Huge (\(size)pt)"
        }
    }

    private func timeoutLabel(_ seconds: Int) -> String {
        if seconds == 0 { return "Instant" }
        if seconds == PlayerSettings.timeoutUnlimited { return "Wait for me" }
        return "\(seconds)s"
    }

}

// MARK: - Rows

/// A toggle row with a leading icon and Nuvio pill switch (focus = fill + ring,
/// same treatment as every other settings row).
private struct PlaybackToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    /// Non-nil = this Apple TV can't do it. The row still shows (so the
    /// feature is discoverable and the limit is explained rather than
    /// mysterious) but reads as off and refuses to toggle.
    var unavailable: String?

    var body: some View {
        Button { if unavailable == nil { isOn.toggle() } } label: {
            PlaybackToggleLabel(
                icon: icon, title: title,
                subtitle: unavailable.map { "\(subtitle)\n\nUnavailable: \($0)." } ?? subtitle,
                isOn: isOn && unavailable == nil,
                dimmed: unavailable != nil
            )
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct PlaybackToggleLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    var dimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: NuvioSpacing.md) {
            SettingsIconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)   // full text, wraps
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            Spacer(minLength: NuvioSpacing.lg)
            NuvioSwitch(isOn: isOn)
                .padding(.top, 4)
        }
        .padding(.horizontal, NuvioSpacing.md)
        .padding(.vertical, NuvioSpacing.md)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        .opacity(dimmed ? 0.5 : 1)
    }
}

