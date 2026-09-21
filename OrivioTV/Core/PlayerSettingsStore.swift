import Foundation

/// How much of the stream to buffer AHEAD (read-ahead cache), so a slow or
/// bursty connection doesn't cause mid-playback rebuffering.
///
/// `auto` keeps the size-adaptive default (a modest seconds-based cache scaled
/// to the file's bitrate). `conservative` shrinks it (smaller, gentler network
/// refill bursts — for boxes/networks that hitch on the periodic refill). The
/// SIZE options (500 MB … 2 GB) pre-buffer roughly that many bytes ahead — the
/// player converts the target to seconds from the stream's real bitrate — so a
/// whole scene downloads before it's needed. `max` uses as much as the device
/// can spare. All sizes are CAPPED to a per-device RAM budget
/// (PerformanceProfile.maxBufferBytes): the buffer lives in memory (tvOS has no
/// working disk cache), so an oversized one would jetsam the app. On a 3 GB
/// Apple TV, "2 GB" therefore effectively caps around 600 MB.
enum BufferProfile: String, Codable, CaseIterable {
    case auto, conservative, mb500, gb1, gb2, max

    var label: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .conservative: return "Conservative (smaller)"
        case .mb500: return "500 MB ahead"
        case .gb1: return "1 GB ahead"
        case .gb2: return "2 GB ahead"
        case .max: return "Maximum (fills available memory)"
        }
    }

    /// Target read-ahead bytes for the size options; nil for auto/conservative
    /// (which stay seconds-based). The player clamps this to the device budget.
    var targetBytes: Int? {
        switch self {
        case .auto, .conservative: return nil
        case .mb500: return 500 << 20
        case .gb1: return 1000 << 20
        case .gb2: return 2000 << 20
        case .max: return .max
        }
    }
}

/// Which playback engine opens a stream first.
/// - auto: route by container — Apple's hardware AVPlayer for native formats
///   (MP4/HLS), FFmpeg (VideoToolbox-accelerated) for MKV & friends. The
///   other engine remains the automatic fallback either way.
/// - native / ffmpeg: force that engine first for every stream.
enum PlayerEngine: String, Codable, CaseIterable {
    case auto, native, ffmpeg, vlc, external

    var label: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .native: return "Native (AVPlayer)"
        case .ffmpeg: return "FFmpeg (KSPlayer)"
        case .vlc: return "VLC"
        case .external: return "External app"
        }
    }

    var footnote: String {
        switch self {
        case .vlc:
            return "VLC buffers internally (no cache bar) and renders its own subtitles. Try it when a file is choppy on the other engines."
        case .external:
            return "Send every stream to another player app installed on this Apple TV (Infuse, VLC, …) instead of playing in Orivio. Pick the app below."
        default:
            return "Auto picks the hardware AVPlayer for MP4/HLS and FFmpeg for MKV & friends; the other engine stays as automatic fallback."
        }
    }
}

/// How the FFmpeg engine outputs audio.
/// - auto: use the enhanced renderer (AVSampleBufferAudioRenderer — Dolby
///   Atmos/spatial rendering and cheaper lossless TrueHD/DTS-HD decode) when
///   the connected TV/receiver route reports spatial-audio support, classic
///   AVAudioEngine otherwise. Capability-gated: Atmos-capable setups get it,
///   plain stereo TVs keep the battle-tested path.
/// - renderer / engine: force one side regardless of the route.
enum AudioOutputMode: String, Codable, CaseIterable {
    case auto, renderer, engine

    var label: String {
        switch self {
        case .auto: return "Auto (Atmos when supported)"
        case .renderer: return "Enhanced renderer (always)"
        case .engine: return "Standard (AVAudioEngine)"
        }
    }
}

/// Post-play / auto-next settings, mirroring the Android `PlayerSettings`
/// (same field names + defaults) so behavior matches the APK. Persisted
/// locally; there's no server row for these in the sync schema.
struct PlayerSettings: Codable, Equatable {
    /// The Up Next card always appears near an episode's end; this only
    /// controls whether its countdown runs and auto-starts the next episode.
    var autoPlayNextEpisode: Bool = true
    var preferBingeGroupForNextEpisode: Bool = true
    var reuseBingeGroup: Bool = true
    /// Countdown before auto-advancing. 0 = instant; `timeoutUnlimited` = wait
    /// for the user (no auto-advance, Up Next stays until dismissed/confirmed).
    ///
    /// Ten, not three. Three is long enough to notice the card and nowhere near
    /// long enough to act on it — by the time you have read which episode is
    /// next and reached for the remote, the advance has already happened.
    var autoPlayTimeoutSeconds: Int = 10
    /// Set once the 3 → 10 migration below has run for this profile, so a
    /// viewer who deliberately goes back to 3 keeps it.
    var didMigrateUpNextTimeout = false

    /// Raise a stored 3 to 10, exactly once per profile.
    ///
    /// Changing the default alone reaches nobody who has ever launched the app:
    /// the whole settings struct is persisted, so every existing install
    /// carries the old default as a stored value and goes on counting down from
    /// three. A blanket overwrite would be wrong too — it would stamp on a
    /// deliberate choice — so this only moves the value that IS the old
    /// default, and only the first time.
    mutating func migrateUpNextTimeout() {
        guard !didMigrateUpNextTimeout else { return }
        didMigrateUpNextTimeout = true
        if autoPlayTimeoutSeconds == 3 { autoPlayTimeoutSeconds = 10 }
    }

    var stillWatchingEnabled: Bool = false
    var stillWatchingEpisodeThreshold: Int = 3
    /// Fallback for files WITHOUT an end-credits chapter: how many seconds
    /// before the end the Up Next card appears. Default 30.
    var upNextLeadSeconds: Int = 30
    /// Seconds a Detail screen must sit idle before its trailer auto-plays
    /// (muted) in the backdrop. 0 = off. On by default so hero previews work
    /// out of the box.
    var autoPlayTrailerSeconds: Int = 3
    /// Show the "Skip Intro" pill when playback sits inside an intro/recap
    /// chapter (⏯ then skips it).
    var skipIntroEnabled: Bool = true
    /// Automatically jump past intro/recap chapters without a button press.
    var autoSkipSegments: Bool = false
    /// Use AniSkip (arm.haglund.dev + api.aniskip.com) to get anime intro/outro
    /// skip times for files that carry no chapters. Off by default (adds a
    /// lookup per anime episode; only useful for anime).
    var animeSkipEnabled: Bool = false
    /// Seconds a single left/right press seeks in the player. Rapid presses
    /// accumulate (2 presses = 2×), holding accelerates.
    var skipSeconds: Int = 10
    /// Seconds a left/right press jumps while in SCRUB mode (the trackpad
    /// zoom-through-the-movie state) — coarser hops than normal skips.
    var scrubJumpSeconds: Int = 60
    /// Diagnostics: show the last trackpad/remote event on-screen in the player
    /// (helps tune gestures on a real Apple TV — the Simulator has no remote).
    var showInputDebug: Bool = false
    /// Generate scrub preview frames (the scene window on the progress bar).
    /// The pass is a SECOND connection and a second FFmpeg decoder running
    /// against live playback, so on a marginal source or a busy box it is a
    /// real cost — this is the switch for trading the previews away.
    var scrubPreviewsEnabled: Bool = true
    /// Subtitle presentation: point size (KSPlayer stamps it onto every cue),
    /// optional dark plate behind lines, bold text.
    var subtitleSize: Int = 36
    var subtitleBackground: Bool = true
    var subtitleBold: Bool = false
    /// Caption typeface family; "" = the system font. Only families tvOS
    /// ships are offered (see `subtitleFontOptions`) — a name that fails to
    /// resolve at render time falls back to the system font rather than
    /// blanking the caption.
    var subtitleFontName: String = ""
    /// Turn subtitles on automatically when a stream loads. When a track in
    /// `preferredSubtitleLanguage` exists it's chosen; otherwise the first
    /// available subtitle.
    var subtitlesOnByDefault: Bool = false
    /// Preferred subtitle language (ISO 639-1 code); "" = first available.
    var preferredSubtitleLanguage: String = "en"
    /// Fallback subtitle language when the preferred one isn't present.
    var subtitleSecondaryLanguage: String = ""
    /// Prefer a "forced" subtitle track (foreign-dialogue only) when one exists.
    var subtitlePreferForced: Bool = false
    // --- Styling ---
    /// Caption text color (hex, no #).
    var subtitleTextColorHex: String = "FFFFFF"
    /// Draw an outline around the text for readability on any background.
    var subtitleOutlineEnabled: Bool = true
    var subtitleOutlineColorHex: String = "000000"
    /// Outline stroke thickness in points (the 8-direction offset radius).
    var subtitleOutlineWidth: Int = 2
    /// Background plate opacity 0–100 (used when subtitleBackground is on).
    var subtitleBackgroundOpacity: Int = 45
    /// Raise (+) or lower (−) the caption from its default bottom margin, points.
    var subtitleVerticalOffset: Int = 0

    /// Preferred audio language (ISO 639-1 code); "" = stream default. When a
    /// stream carries a matching track it's selected automatically.
    var preferredAudioLanguage: String = ""
    /// Picker language lists. Each picker shows the short common set by
    /// default; the "… languages" drill-ins under Audio / Subtitles turn on
    /// either EVERY language or a hand-picked subset, so a viewer who needs an
    /// uncommon language can still find it without scrolling ~180 entries on
    /// every pick.
    var allAudioLanguages: Bool = false
    var enabledAudioLanguages: [String] = PlayerSettings.commonLanguageCodes.sorted()
    var allSubtitleLanguages: Bool = false
    var enabledSubtitleLanguages: [String] = PlayerSettings.commonLanguageCodes.sorted()
    /// Playback policy: Automatic / Maximum Fidelity / Compatibility.
    /// Governs the DV path, P7 conversion and audio route (see PlaybackMode).
    var playbackMode: PlaybackMode = .automatic
    /// Convert Dolby Vision Profile 7 → 8.1 so the enhancement layer's
    /// brightness survives, instead of playing the dark HDR10 base layer.
    /// Costs CPU on older boxes (the A10X/3 GB 4K); ON by default, and the
    /// escape hatch when a Profile 7 title stutters. See `p7ok` in
    /// PlayerViewModel.
    var convertProfile7ForBrightness: Bool = true
    /// Playback engine selection (see PlayerEngine).
    var playerEngine: PlayerEngine = .auto
    /// Playback buffer sizing (see BufferProfile).
    var bufferProfile: BufferProfile = .auto
    /// Which external player app receives streams when playerEngine is
    /// .external (id from ExternalPlayers.catalog).
    var externalPlayerID: String = "infuse"
    /// Fetch a preferred-language subtitle from your subtitle addons and hand
    /// it to the external player (Infuse/VLC/VidHub `sub=` parameter).
    var externalPlayerForwardSubtitles: Bool = false
    /// Hand the REST of the season over too, as a playlist, when the external
    /// player supports one (Infuse takes repeated url/filename/position
    /// groups). Lets next-episode work over there instead of stopping dead
    /// after one episode.
    var externalPlayerSendPlaylist: Bool = true
    /// LEGACY (pre-audioOutputMode): the old force-renderer toggle. Kept only
    /// so existing saves migrate — read once in the decoder, never in the UI.
    var audioRendererEnabled: Bool = false
    /// FFmpeg-engine audio output (see AudioOutputMode). Auto = the enhanced
    /// renderer only when the route is spatial/Atmos-capable.
    var audioOutputMode: AudioOutputMode = .auto
    /// Default video scaling (Fit / Zoom / Stretch). The in-player button
    /// cycles it live for the session; this is the saved + synced default.
    var aspectModeRaw: String = "fit"
    /// Default subtitle timing offset in seconds (+ = later, − = earlier).
    /// Applied when a stream loads; the in-player nudge adjusts it live.
    var subtitleDelaySeconds: Double = 0
    // --- Player OSD / overlays (cosmetic) ---
    /// Show the Infuse-style info overlay when playback is paused.
    var pauseOverlayEnabled: Bool = true
    /// Show a wall clock on the player controls overlay.
    var osdClockEnabled: Bool = true
    /// Show the full-screen loading backdrop while a stream opens.
    var loadingOverlayEnabled: Bool = true
    /// Show the "Loading / Caching %" status text on the loading backdrop.
    var showPlayerLoadingStatus: Bool = true
    /// Show IMDb parental-guide content advisories on the details page.
    var parentalGuideEnabled: Bool = true

    /// Master switch for the curated link filters. On = each addon's links
    /// are grouped into size tiers (250 MB–4 GB … 30 GB+), debrid-cached
    /// links first, capped per tier. Off = links exactly as each addon
    /// returned them (cached still first), capped per addon so a Torrentio
    /// flood can't drown the UI.
    var sourceFiltersEnabled: Bool = true
    /// Per-addon stream-request deadline (seconds). 45 covers most live
    /// scrapers, but aggregators that fan out to Usenet indexers (AIOStreams
    /// with NZBgeek behind it) legitimately need longer — under a too-short
    /// deadline the whole aggregator response is dropped and only its fast
    /// upstreams ever "work". The sweep reveals per-addon results as they
    /// land, so extra patience costs nothing when addons are fast.
    var sourceSearchTimeoutSeconds: Int = 45
    /// Hybrid disk cache (Infuse-style): download the whole file to the Apple
    /// TV's storage at full line speed while playing, and serve seeks from
    /// disk — the RAM read-ahead tops out at a few hundred MB, so deep seeks
    /// otherwise always stall on the network. Direct-file streams only (HLS
    /// bypasses); anything unexpected falls back to direct playback.
    /// ON by default. It was shipped off behind a "beta" label while the
    /// sliding window, the eviction policy and the download pool were being
    /// settled; it is the difference between instant seeking and re-fetching
    /// the film every time, and leaving it off by default meant almost nobody
    /// got that. A stream the cache cannot handle (HLS, an origin that refuses
    /// byte ranges) still plays — the proxy fails open to the origin.
    var hybridDiskCacheEnabled: Bool = true
    /// Links shown per size tier (250 MB–4 GB / 4–10 / 10–20 / 20–30 / 30+).
    var sourcesPerSizeTier: Int = 6
    // --- Stream filters (applied before curation) ---
    /// Drop links below this resolution. "" = no minimum. (2160p/1080p/720p/480p)
    var streamMinResolution: String = ""
    /// Hide AV1 links (no hardware decode on the Apple TV A10X → slideshow).
    var streamExcludeAV1: Bool = false
    /// Only show HDR (HDR10/HLG/DV) links.
    var streamHDROnly: Bool = false
    /// Only show Dolby Vision links.
    var streamDolbyVisionOnly: Bool = false
    /// Only show links the debrid service already has cached (instant play).
    var streamCachedOnly: Bool = false
    // --- Auto-play source (skip the picker) ---
    /// Skip the Sources page and start the best matching link automatically.
    var autoPlaySourceEnabled: Bool = false
    /// Only auto-play a debrid-cached / instant source (never wait on a
    /// torrent that has to be resolved first).
    var autoPlaySourceCachedOnly: Bool = false
    /// Optional case-insensitive regex the auto-played source's name/detail
    /// must match (e.g. "2160p|remux"). "" = first source in the sorted list.
    var autoPlaySourceRegex: String = ""
    // --- Reuse last link ---
    /// Replay the last successfully-played source for a title without
    /// re-scraping, as long as it's within the cache window.
    var reuseLastLinkEnabled: Bool = false
    /// How long a remembered last link stays valid (hours).
    var reuseLastLinkCacheHours: Int = 24
    /// OPT-IN HDR/frame-rate display-mode switching. Off (default) = the
    /// Apple TV stays in its home-screen format and tone-maps content into it
    /// (like the Android APK/Stremio). On = ask the TV to switch into the
    /// content's native mode — some TVs mis-handshake the switch back and
    /// wedge on a grey screen until power-cycled, hence the default.
    var matchContentDisplayMode: Bool = false
    /// Also switch the panel's REFRESH RATE to the content's (e.g. 60→23.976
    /// for film) when matching display mode / playing native DV. OFF by
    /// default: it removes 3:2 pulldown (24p film at its true cadence), but the
    /// rate change is a much heavier HDMI renegotiation than a range-only
    /// switch, and the target panel mis-handshakes it into a grey screen —
    /// recovering from that then flashes through several more mode changes.
    /// Turn ON only on a TV that handles 24p switches cleanly.
    var matchFrameRate: Bool = false
    /// True Dolby Atmos passthrough from MKV sources. The sample engine hands
    /// compressed E-AC-3 to a renderer that DECODES it (PCM, no Atmos), so this
    /// re-muxes the E-AC-3 into a loopback HLS playlist and plays it with
    /// AVPlayer — the only path that emits Dolby MAT 2.0. ON by default, but it
    /// only engages when the container actually declares Atmos AND the route is
    /// HDMI, so non-Atmos titles pay nothing; it falls back untouched otherwise.
    var atmosPassthrough: Bool = true
    /// Native Dolby Vision output. When a Dolby Vision file
    /// (profile 5/8) plays on a DV-capable TV, the stream is remuxed on-device
    /// into a DV-tagged fMP4 playlist and handed to Apple's video pipeline —
    /// true dynamic DV instead of the HDR10 tone-map. Any failure falls back
    /// to the standard engine automatically. Off = always use the standard
    /// HDR10 path.
    var nativeDolbyVision: Bool = true

    /// HDR10+ passthrough. Apple added HDR10+ output in tvOS 18.4 and ONLY on
    /// the Apple TV 4K 3rd gen (A15) — `PerformanceProfile.supportsHDR10Plus`
    /// is the real gate, and this switch does nothing on older boxes (its row
    /// is disabled there and says why). On by default so capable hardware just
    /// works; off falls back to the HDR10 base layer every HDR10+ stream
    /// already carries, so turning it off never costs the picture.
    var hdr10PlusPassthrough: Bool = true

    /// Convert Dolby Vision Profile 7 (dual-layer) → 8.1 via
    /// libdovi so DV7 files also get native DV output (the base layer is kept,
    /// the enhancement layer dropped, each RPU rewritten 7→8.1). The DEFAULT is
    /// device-aware: ON on 4 GB+ Apple TVs (gen-3), OFF on the 3 GB gen-1/2 and
    /// the 2 GB HD, where the whole-file remux can hang the box mid-play — but
    /// the user can flip it either way and the choice persists. Off = DV7
    /// tone-maps to HDR10 (the standard engine), exactly as before. Requires
    /// Native Dolby Vision on.
    var dolbyVisionProfile7: Bool = PerformanceProfile.recommendsDolbyVisionProfile7
    /// Render styled ASS/SSA subtitles fully (custom fonts, positioning,
    /// karaoke) by playing titles that carry them in the VLC engine, which
    /// includes libass. KSPlayer's built-in ASS parser drops embedded fonts
    /// and complex styling. Off = keep KSPlayer's rendering. When it routes to
    /// VLC you lose that title's scrub-thumbnail preview for the session.
    var fullAssSubtitles: Bool = false

    /// Selectable subtitle sizes. The two smallest were added after reports of
    /// captions "filling the entire screen": the real cause was an embedded ASS
    /// style overriding this setting (see `SubtitleOverlayView.restyled`), but
    /// once the setting actually applies, 28pt is still bigger than some people
    /// want on a 1080p canvas.
    static let subtitleSizeValues: [Int] = [20, 24, 28, 32, 36, 42, 48, 56]

    /// Caption typeface choices (family name, label). "" = system font. All
    /// families tvOS actually ships, so `Font.custom` always resolves.
    static let subtitleFontOptions: [(String, String)] = [
        ("", "System"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Avenir Next", "Avenir Next"),
        ("Gill Sans", "Gill Sans"),
        ("Georgia", "Georgia"),
        ("Times New Roman", "Times New Roman"),
        ("American Typewriter", "Typewriter"),
        ("Menlo", "Menlo (mono)"),
        ("Verdana", "Verdana"),
    ]
    /// Language choices for the audio/subtitle preference pickers.
    ///
    /// Built from the platform's own ISO 639-1 list rather than a fixed dozen:
    /// a hardcoded list silently made every language it omitted unselectable
    /// (Vietnamese, Thai, Turkish, …), so an addon could supply a Vietnamese
    /// track that no user preference could ever target. `first` is the "no
    /// preference" entry; the rest are sorted by localized name.
    ///
    /// The full list is ~180 entries, which is a punishing dropdown on a TV, so
    /// a picker shows `commonLanguageCodes` (or the viewer's chosen subset)
    /// unless they opted into all of them in Settings → Playback → "Subtitle
    /// languages" / "Audio languages". Dutch is in the common set — it was
    /// missing from the old hardcoded twelve.
    private static func languageOptions(
        first: (String, String), showAll: Bool,
        enabled: Set<String> = commonLanguageCodes, include: String = ""
    ) -> [(String, String)] {
        var seen = Set<String>()
        var rest: [(String, String)] = []
        for code in Locale.LanguageCode.isoLanguageCodes {
            let id = code.identifier
            guard id.count == 2,
                  let name = Locale.current.localizedString(forLanguageCode: id),
                  !name.isEmpty,
                  seen.insert(name.lowercased()).inserted
            else { continue }
            if !showAll, !enabled.contains(id), id != include { continue }
            rest.append((id, name))
        }
        rest.sort { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return [first] + rest
    }

    /// Languages almost every library actually carries, so a picker starts
    /// short. Deliberately includes Dutch (and the other big European / Asian
    /// ones) that the old fixed twelve left out.
    static let commonLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl",
        "sv", "da", "no", "fi", "tr", "cs", "el", "hu", "ro",
        "ar", "he", "hi", "bn", "ta", "te", "ur", "fa",
        "ja", "ko", "zh", "th", "vi", "id", "ms", "tl",
    ]

    /// EVERY language, for matching a track label back to a code (a picker
    /// filter must never make a real track unmatchable) and for the language
    /// selection screens.
    static let allAudioLanguageOptions: [(String, String)] =
        languageOptions(first: ("", "Stream default"), showAll: true)
    static let allSubtitleLanguageOptions: [(String, String)] =
        languageOptions(first: ("", "First available"), showAll: true)

    /// Picker lists: everything when `showAll`, otherwise the chosen subset.
    /// `current` is always kept so a previously chosen language never
    /// disappears from its own dropdown.
    static func audioLanguageOptions(showAll: Bool, enabled: Set<String>,
                                     current: String = "") -> [(String, String)] {
        languageOptions(first: ("", "Stream default"), showAll: showAll,
                        enabled: enabled, include: current)
    }
    static func subtitleLanguageOptions(showAll: Bool, enabled: Set<String>,
                                        current: String = "") -> [(String, String)] {
        languageOptions(first: ("", "First available"), showAll: showAll,
                        enabled: enabled, include: current)
    }

    static let timeoutUnlimited = Int.max
    /// Selectable countdown values, matching STREAM_AUTOPLAY_TIMEOUT_VALUES.
    static let timeoutValues: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30, timeoutUnlimited]
    /// Selectable auto-play-trailer delays (seconds).
    static let trailerDelayValues: [Int] = [0, 1, 2, 3, 5]
    /// Selectable Up Next lead times (seconds before end) for chapter-less files.
    static let upNextLeadValues: [Int] = [10, 15, 20, 30, 45, 60, 90, 120, 180]
    /// Subtitle color presets (hex, display name) — no color picker on tvOS.
    static let subtitleColorOptions: [(String, String)] = [
        ("FFFFFF", "White"), ("F5F5F5", "Off-White"), ("FFEB3B", "Yellow"),
        ("00E5FF", "Cyan"), ("69F0AE", "Green"), ("BDBDBD", "Grey"), ("000000", "Black"),
    ]
    /// Selectable subtitle vertical offsets (points; + raises).
    static let subtitleOffsetValues: [Int] = [-40, -20, 0, 20, 40, 80, 120, 160]
    static let subtitleBackgroundOpacityValues: [Int] = [0, 15, 30, 45, 60, 80, 100]
    /// Selectable subtitle outline thicknesses (points).
    static let subtitleOutlineWidthValues: [Int] = [1, 2, 3, 4, 6]
    /// Selectable reuse-last-link cache windows (hours).
    static let reuseLastLinkHoursValues: [Int] = [1, 3, 6, 12, 24, 48, 72]
    /// Selectable default subtitle timing offsets (seconds).
    static let subtitleDelayValues: [Double] = [-5, -3, -2, -1, -0.5, 0, 0.5, 1, 2, 3, 5]
    /// Selectable per-press skip amounts (seconds).
    static let skipValues: [Int] = [5, 10, 15, 30]
    /// Selectable scrub-mode jump amounts (seconds).
    static let scrubJumpValues: [Int] = [30, 60, 120, 300]
    /// Selectable per-tier link counts (for both the high-GB and low-GB halves).
    static let sourcesPerTierValues: [Int] = [0, 1, 2, 3, 4, 5, 6, 8, 10, 15]
    /// Max links shown per addon when the curated filters are OFF — enough to
    /// dig through, small enough that the tvOS list stays scrollable.
    static let unfilteredPerAddonCap = 40

    /// The user's stream filters as a value for SourceSelection.filter.
    var streamFilterOptions: StreamFilterOptions {
        StreamFilterOptions(
            minResolution: streamMinResolution,
            excludeAV1: streamExcludeAV1,
            hdrOnly: streamHDROnly,
            dolbyVisionOnly: streamDolbyVisionOnly,
            cachedOnly: streamCachedOnly
        )
    }

    static let `default` = PlayerSettings()

    /// Resilient decoding: every missing key falls back to its default, so
    /// adding a setting in an update never wipes the user's saved settings
    /// (synthesized Codable throws on the first missing key).
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayerSettings.default
        autoPlayNextEpisode = (try? c.decode(Bool.self, forKey: .autoPlayNextEpisode)) ?? d.autoPlayNextEpisode
        preferBingeGroupForNextEpisode = (try? c.decode(Bool.self, forKey: .preferBingeGroupForNextEpisode)) ?? d.preferBingeGroupForNextEpisode
        reuseBingeGroup = (try? c.decode(Bool.self, forKey: .reuseBingeGroup)) ?? d.reuseBingeGroup
        autoPlayTimeoutSeconds = (try? c.decode(Int.self, forKey: .autoPlayTimeoutSeconds)) ?? d.autoPlayTimeoutSeconds
        // MUST be decoded, or the 3 → 10 migration re-runs on every launch and
        // overwrites a viewer who deliberately set it back to 3.
        didMigrateUpNextTimeout = (try? c.decode(Bool.self, forKey: .didMigrateUpNextTimeout)) ?? false

        stillWatchingEnabled = (try? c.decode(Bool.self, forKey: .stillWatchingEnabled)) ?? d.stillWatchingEnabled
        stillWatchingEpisodeThreshold = (try? c.decode(Int.self, forKey: .stillWatchingEpisodeThreshold)) ?? d.stillWatchingEpisodeThreshold
        upNextLeadSeconds = (try? c.decode(Int.self, forKey: .upNextLeadSeconds)) ?? d.upNextLeadSeconds
        autoPlayTrailerSeconds = (try? c.decode(Int.self, forKey: .autoPlayTrailerSeconds)) ?? d.autoPlayTrailerSeconds
        skipIntroEnabled = (try? c.decode(Bool.self, forKey: .skipIntroEnabled)) ?? d.skipIntroEnabled
        autoSkipSegments = (try? c.decode(Bool.self, forKey: .autoSkipSegments)) ?? d.autoSkipSegments
        animeSkipEnabled = (try? c.decode(Bool.self, forKey: .animeSkipEnabled)) ?? d.animeSkipEnabled
        skipSeconds = (try? c.decode(Int.self, forKey: .skipSeconds)) ?? d.skipSeconds
        scrubJumpSeconds = (try? c.decode(Int.self, forKey: .scrubJumpSeconds)) ?? d.scrubJumpSeconds
        showInputDebug = (try? c.decode(Bool.self, forKey: .showInputDebug)) ?? d.showInputDebug
        scrubPreviewsEnabled = (try? c.decode(Bool.self, forKey: .scrubPreviewsEnabled)) ?? d.scrubPreviewsEnabled
        subtitleSize = (try? c.decode(Int.self, forKey: .subtitleSize)) ?? d.subtitleSize
        subtitleBackground = (try? c.decode(Bool.self, forKey: .subtitleBackground)) ?? d.subtitleBackground
        subtitleBold = (try? c.decode(Bool.self, forKey: .subtitleBold)) ?? d.subtitleBold
        subtitleFontName = (try? c.decode(String.self, forKey: .subtitleFontName)) ?? d.subtitleFontName
        subtitlesOnByDefault = (try? c.decode(Bool.self, forKey: .subtitlesOnByDefault)) ?? d.subtitlesOnByDefault
        preferredSubtitleLanguage = (try? c.decode(String.self, forKey: .preferredSubtitleLanguage)) ?? d.preferredSubtitleLanguage
        subtitleSecondaryLanguage = (try? c.decode(String.self, forKey: .subtitleSecondaryLanguage)) ?? d.subtitleSecondaryLanguage
        subtitlePreferForced = (try? c.decode(Bool.self, forKey: .subtitlePreferForced)) ?? d.subtitlePreferForced
        subtitleTextColorHex = (try? c.decode(String.self, forKey: .subtitleTextColorHex)) ?? d.subtitleTextColorHex
        subtitleOutlineEnabled = (try? c.decode(Bool.self, forKey: .subtitleOutlineEnabled)) ?? d.subtitleOutlineEnabled
        subtitleOutlineColorHex = (try? c.decode(String.self, forKey: .subtitleOutlineColorHex)) ?? d.subtitleOutlineColorHex
        subtitleOutlineWidth = (try? c.decode(Int.self, forKey: .subtitleOutlineWidth)) ?? d.subtitleOutlineWidth
        subtitleBackgroundOpacity = (try? c.decode(Int.self, forKey: .subtitleBackgroundOpacity)) ?? d.subtitleBackgroundOpacity
        subtitleVerticalOffset = (try? c.decode(Int.self, forKey: .subtitleVerticalOffset)) ?? d.subtitleVerticalOffset
        preferredAudioLanguage = (try? c.decode(String.self, forKey: .preferredAudioLanguage)) ?? d.preferredAudioLanguage
        allAudioLanguages = (try? c.decode(Bool.self, forKey: .allAudioLanguages)) ?? d.allAudioLanguages
        enabledAudioLanguages = (try? c.decode([String].self, forKey: .enabledAudioLanguages)) ?? d.enabledAudioLanguages
        allSubtitleLanguages = (try? c.decode(Bool.self, forKey: .allSubtitleLanguages)) ?? d.allSubtitleLanguages
        enabledSubtitleLanguages = (try? c.decode([String].self, forKey: .enabledSubtitleLanguages)) ?? d.enabledSubtitleLanguages
        playbackMode = (try? c.decode(PlaybackMode.self, forKey: .playbackMode)) ?? d.playbackMode
        convertProfile7ForBrightness = (try? c.decode(Bool.self, forKey: .convertProfile7ForBrightness)) ?? d.convertProfile7ForBrightness
        playerEngine = (try? c.decode(PlayerEngine.self, forKey: .playerEngine)) ?? d.playerEngine
        bufferProfile = (try? c.decode(BufferProfile.self, forKey: .bufferProfile)) ?? d.bufferProfile
        externalPlayerID = (try? c.decode(String.self, forKey: .externalPlayerID)) ?? d.externalPlayerID
        externalPlayerForwardSubtitles = (try? c.decode(Bool.self, forKey: .externalPlayerForwardSubtitles)) ?? d.externalPlayerForwardSubtitles
        externalPlayerSendPlaylist = (try? c.decode(Bool.self, forKey: .externalPlayerSendPlaylist)) ?? d.externalPlayerSendPlaylist
        audioRendererEnabled = (try? c.decode(Bool.self, forKey: .audioRendererEnabled)) ?? d.audioRendererEnabled
        // Migration: saves from before audioOutputMode existed carry only the
        // old force-renderer bool — honor it as an explicit "renderer".
        audioOutputMode = (try? c.decode(AudioOutputMode.self, forKey: .audioOutputMode))
            ?? (audioRendererEnabled ? .renderer : d.audioOutputMode)
        aspectModeRaw = (try? c.decode(String.self, forKey: .aspectModeRaw)) ?? d.aspectModeRaw
        subtitleDelaySeconds = (try? c.decode(Double.self, forKey: .subtitleDelaySeconds)) ?? d.subtitleDelaySeconds
        pauseOverlayEnabled = (try? c.decode(Bool.self, forKey: .pauseOverlayEnabled)) ?? d.pauseOverlayEnabled
        osdClockEnabled = (try? c.decode(Bool.self, forKey: .osdClockEnabled)) ?? d.osdClockEnabled
        loadingOverlayEnabled = (try? c.decode(Bool.self, forKey: .loadingOverlayEnabled)) ?? d.loadingOverlayEnabled
        showPlayerLoadingStatus = (try? c.decode(Bool.self, forKey: .showPlayerLoadingStatus)) ?? d.showPlayerLoadingStatus
        parentalGuideEnabled = (try? c.decode(Bool.self, forKey: .parentalGuideEnabled)) ?? d.parentalGuideEnabled
        sourceFiltersEnabled = (try? c.decode(Bool.self, forKey: .sourceFiltersEnabled)) ?? d.sourceFiltersEnabled
        sourceSearchTimeoutSeconds = (try? c.decode(Int.self, forKey: .sourceSearchTimeoutSeconds)) ?? d.sourceSearchTimeoutSeconds
        hybridDiskCacheEnabled = (try? c.decode(Bool.self, forKey: .hybridDiskCacheEnabled)) ?? d.hybridDiskCacheEnabled
        sourcesPerSizeTier = (try? c.decode(Int.self, forKey: .sourcesPerSizeTier)) ?? d.sourcesPerSizeTier
        streamMinResolution = (try? c.decode(String.self, forKey: .streamMinResolution)) ?? d.streamMinResolution
        streamExcludeAV1 = (try? c.decode(Bool.self, forKey: .streamExcludeAV1)) ?? d.streamExcludeAV1
        streamHDROnly = (try? c.decode(Bool.self, forKey: .streamHDROnly)) ?? d.streamHDROnly
        streamDolbyVisionOnly = (try? c.decode(Bool.self, forKey: .streamDolbyVisionOnly)) ?? d.streamDolbyVisionOnly
        streamCachedOnly = (try? c.decode(Bool.self, forKey: .streamCachedOnly)) ?? d.streamCachedOnly
        autoPlaySourceEnabled = (try? c.decode(Bool.self, forKey: .autoPlaySourceEnabled)) ?? d.autoPlaySourceEnabled
        autoPlaySourceCachedOnly = (try? c.decode(Bool.self, forKey: .autoPlaySourceCachedOnly)) ?? d.autoPlaySourceCachedOnly
        autoPlaySourceRegex = (try? c.decode(String.self, forKey: .autoPlaySourceRegex)) ?? d.autoPlaySourceRegex
        reuseLastLinkEnabled = (try? c.decode(Bool.self, forKey: .reuseLastLinkEnabled)) ?? d.reuseLastLinkEnabled
        reuseLastLinkCacheHours = (try? c.decode(Int.self, forKey: .reuseLastLinkCacheHours)) ?? d.reuseLastLinkCacheHours
        matchContentDisplayMode = (try? c.decode(Bool.self, forKey: .matchContentDisplayMode)) ?? d.matchContentDisplayMode
        matchFrameRate = (try? c.decode(Bool.self, forKey: .matchFrameRate)) ?? d.matchFrameRate
        atmosPassthrough = (try? c.decode(Bool.self, forKey: .atmosPassthrough)) ?? d.atmosPassthrough
        nativeDolbyVision = (try? c.decode(Bool.self, forKey: .nativeDolbyVision)) ?? d.nativeDolbyVision
        hdr10PlusPassthrough = (try? c.decode(Bool.self, forKey: .hdr10PlusPassthrough)) ?? d.hdr10PlusPassthrough
        dolbyVisionProfile7 = (try? c.decode(Bool.self, forKey: .dolbyVisionProfile7)) ?? d.dolbyVisionProfile7
        fullAssSubtitles = (try? c.decode(Bool.self, forKey: .fullAssSubtitles)) ?? d.fullAssSubtitles
    }
}

@MainActor
final class PlayerSettingsStore: ObservableObject {
    @Published var settings: PlayerSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if !applyingRemote { onLocalChange?() }
        }
    }

    /// Fired when the user changes settings locally (not when applying a remote
    /// pull) so the sync manager can push the change up.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let key = "orivio.player.settings.v1"

    /// Player + subtitle settings are PER PROFILE (upstream scopes its whole
    /// `player_settings` store this way). The legacy device-wide blob goes to
    /// the PRIMARY profile; other profiles start at the hardware-tuned
    /// defaults (Trakt-switch semantics).
    private(set) var profileID: Int

    /// Separate-vs-shared switch (Trakt-style). Shared = one set of player +
    /// subtitle settings for the whole device, the pre-split behaviour.
    static let feature = "player"
    var perProfileEnabled: Bool { ProfileScopedDefaults.isSeparate(Self.feature) }

    func setPerProfile(_ on: Bool) {
        guard on != perProfileEnabled else { return }
        ProfileScopedDefaults.setSeparate(Self.feature, on)
        applyingRemote = true
        settings = Self.load(profile: profileID)
        applyingRemote = false
    }

    init() {
        profileID = ProfileScopedDefaults.activeProfileID
        settings = Self.load(profile: profileID)
    }

    /// Device-local (NOT synced) one-shot: a brief window of builds defaulted
    /// frame-rate matching ON, which wedges this panel grey on the 60→24
    /// switch. Force it off once. Kept out of `PlayerSettings` precisely so an
    /// account copy can't override it — the settings sync is what kept turning
    /// it back on.
    /// v2: the v1 force-off ran before the value was persisted, so it never
    /// stuck (and the v1 key then blocked a re-run). v2 forces AND saves.
    private static let forcedFrameRateOffKey = "orivio.player.matchFrameRateForcedOff.v2"

    private static func load(profile: Int) -> PlayerSettings {
        if let data = ProfileScopedDefaults.data(key, feature: feature, profile),
           var decoded = try? JSONDecoder().decode(PlayerSettings.self, from: data) {
            decoded.migrateUpNextTimeout()
            if !UserDefaults.standard.bool(forKey: forcedFrameRateOffKey) {
                UserDefaults.standard.set(true, forKey: forcedFrameRateOffKey)
                decoded.matchFrameRate = false
                // Persist IMMEDIATELY. The store's init assigns `settings`
                // without triggering its didSet save, so setting only the
                // in-memory value left the stored `true` to be read back on the
                // next launch — and the one-shot key then blocked re-forcing.
                if let encoded = try? JSONEncoder().encode(decoded) {
                    UserDefaults.standard.set(
                        encoded,
                        forKey: ProfileScopedDefaults.writeKey(key, feature: feature, profile))
                }
            }
            return decoded
        }
        return .default
    }

    /// Point the store at a profile: swap the previous profile's settings out
    /// for this one's. Suppressed as a "remote" apply so the swap can't arm a
    /// sync push of settings that didn't change.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        applyingRemote = true
        settings = Self.load(profile: id)
        applyingRemote = false
    }

    /// Forget a deleted profile's settings so a recycled id starts from the seed.
    func forgetProfile(_ id: Int) {
        ProfileScopedDefaults.forget([Self.key], profile: id)
        if id == profileID {
            applyingRemote = true
            settings = Self.load(profile: id)
            applyingRemote = false
        }
    }

    /// Settings whose value describes THIS BOX's hardware, not the user's
    /// preference — they must never ride in from another device. Their defaults
    /// come from PerformanceProfile, and the wrong value doesn't just look
    /// wrong: a 4 GB gen-3 syncing `dolbyVisionProfile7 = true` onto a 3 GB box
    /// hangs it mid-play, and `hdr10PlusPassthrough` means nothing off an A15.
    private func preservingDeviceCapabilities(_ new: PlayerSettings) -> PlayerSettings {
        var merged = new
        merged.dolbyVisionProfile7 = settings.dolbyVisionProfile7
        merged.hdr10PlusPassthrough = settings.hdr10PlusPassthrough
        // Frame-rate matching is a TV property too — whether THIS panel
        // hand-shakes a 60→24 switch cleanly. It must not ride in from another
        // device (which is how an account that had it ON kept re-greying this
        // one), and the one-time force-off flag rides with it.
        merged.matchFrameRate = settings.matchFrameRate
        return merged
    }

    /// Apply settings pulled from the account without echoing them back up.
    func applyRemote(_ new: PlayerSettings) {
        let new = preservingDeviceCapabilities(new)
        guard new != settings else { return }
        applyingRemote = true
        settings = new
        applyingRemote = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(
            data, forKey: ProfileScopedDefaults.writeKey(Self.key, feature: Self.feature, profileID))
    }
}
