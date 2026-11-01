import Combine
// Ported from the old app's Core/PlayerSettingsStore.swift: the settings
// model the Classic player reads. Filled from the new app's PlayerSettings
// for each playback (see ClassicPlayerSettings(_:) below).
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

/// Post-play / auto-next settings, mirroring the Android `ClassicPlayerSettings`
/// (same field names + defaults) so behavior matches the APK. Persisted
/// locally; there's no server row for these in the sync schema.
struct ClassicPlayerSettings: Codable, Equatable {
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
    /// Let subtitle-addon tracks (SubMaker, OpenSubtitles…) win over the
    /// file's own tracks in the same language. The automatic pick then waits
    /// for the addon wave instead of settling on the embedded track that lands
    /// first. Off = the file's own track wins, as before.
    var preferAddonSubtitles: Bool = false
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
    var enabledAudioLanguages: [String] = ClassicPlayerSettings.commonLanguageCodes.sorted()
    var allSubtitleLanguages: Bool = false
    var enabledSubtitleLanguages: [String] = ClassicPlayerSettings.commonLanguageCodes.sorted()
    /// Playback policy: Automatic / Maximum Fidelity / Compatibility.
    /// Governs the DV path, P7 conversion and audio route (see ClassicPlaybackMode).
    var playbackMode: ClassicPlaybackMode = .automatic
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

    static let `default` = ClassicPlayerSettings()
}

// MARK: - From the new app's settings

extension ClassicPlayerSettings {
    private static let colorHex: [String: String] = [
        "White": "FFFFFF", "Off-White": "F5F5F5", "Yellow": "FFEB3B", "Cyan": "00E5FF",
        "Green": "69F0AE", "Grey": "BDBDBD", "Black": "000000",
    ]
    private static let fontNames: [String: String] = [
        "System": "", "Typewriter": "American Typewriter",
    ]

    /// The Classic player's view of the user's Playback / Subtitles settings.
    /// Settings the new app has no control for keep the old app's defaults.
    init(_ s: PlayerSettings) {
        self.init()
        autoPlayNextEpisode = s.autoPlayNextEpisode
        upNextLeadSeconds = s.upNextSecondsBeforeEnd
        autoPlayTimeoutSeconds = s.autoPlayCountdown
        didMigrateUpNextTimeout = true
        stillWatchingEnabled = s.stillWatchingEnabled
        stillWatchingEpisodeThreshold = s.stillWatchingAfter
        preferBingeGroupForNextEpisode = s.keepSameSourceForNext
        reuseBingeGroup = s.keepSameSourceForNext
        skipSeconds = s.skipAmount
        scrubJumpSeconds = s.scrubberJump
        skipIntroEnabled = s.skipIntroButton
        autoSkipSegments = s.autoSkipIntros
        animeSkipEnabled = s.aniSkip
        scrubPreviewsEnabled = s.scrubPreviews
        sourceFiltersEnabled = s.linkFilters
        sourcesPerSizeTier = s.linksPerResolution
        sourceSearchTimeoutSeconds = s.sourceSearchPatience
        streamMinResolution = s.minimumResolution ?? ""
        streamExcludeAV1 = s.hideAV1
        streamHDROnly = s.hdrOnly
        streamDolbyVisionOnly = s.dolbyVisionOnly
        streamCachedOnly = s.cachedOnly
        autoPlaySourceEnabled = s.autoPlayBestSource
        autoPlaySourceCachedOnly = s.autoPlayCachedOnly
        autoPlaySourceRegex = s.autoPlayRegex
        reuseLastLinkEnabled = s.reuseLastLink
        reuseLastLinkCacheHours = s.reuseWindowHours
        playerEngine = PlayerEngine(rawValue: s.engine.rawValue) ?? .auto
        switch s.playbackMode {
        case .automatic: playbackMode = .automatic
        case .maximumFidelity: playbackMode = .fidelity
        case .compatibility: playbackMode = .compatibility
        }
        hybridDiskCacheEnabled = s.hybridCache
        atmosPassthrough = s.atmosPassthrough
        switch s.videoScaling {
        case .normal: aspectModeRaw = "fit"
        case .crop: aspectModeRaw = "fill"
        case .stretch: aspectModeRaw = "stretch"
        }
        externalPlayerID = s.externalPlayer.rawValue
        externalPlayerForwardSubtitles = s.externalForwardSubtitles
        externalPlayerSendPlaylist = s.externalSendSeason
        parentalGuideEnabled = s.parentalGuide
        autoPlayTrailerSeconds = max(0, s.detailTrailerDelay)
        preferredAudioLanguage = s.preferredAudioLanguage
        subtitlesOnByDefault = s.subtitlesOnByDefault
        preferredSubtitleLanguage = s.subtitleLanguage
        subtitleSecondaryLanguage = s.subtitleSecondaryLanguage ?? ""
        subtitlePreferForced = s.preferForcedSubtitles
        preferAddonSubtitles = s.preferAddonSubtitles
        fullAssSubtitles = s.fullStyledSubtitles
        subtitleSize = Int(s.subtitleSize.rounded())
        subtitleFontName = Self.fontNames[s.subtitleFont] ?? s.subtitleFont
        subtitleTextColorHex = Self.colorHex[s.subtitleColor] ?? "FFFFFF"
        subtitleBold = s.subtitleBold
        subtitleOutlineEnabled = s.subtitleOutline
        subtitleOutlineColorHex = Self.colorHex[s.subtitleOutlineColor] ?? "000000"
        subtitleOutlineWidth = Int(s.subtitleOutlineWidth.rounded())
        subtitleBackground = s.subtitleBackground
        subtitleBackgroundOpacity = Int((s.subtitleBackgroundOpacity * 100).rounded())
        subtitleVerticalOffset = Int(s.subtitleVerticalOffset.rounded())
        subtitleDelaySeconds = s.subtitleDelay
    }

    /// Writes back what the player's own panels can change (caption style,
    /// delay, engine, aspect) so the app's Settings pages stay in step.
    func apply(to s: inout PlayerSettings) {
        s.subtitleSize = Double(subtitleSize)
        if let font = Self.fontNames.first(where: { $0.value == subtitleFontName })?.key { s.subtitleFont = font }
        else if !subtitleFontName.isEmpty { s.subtitleFont = subtitleFontName }
        if let c = Self.colorHex.first(where: { $0.value == subtitleTextColorHex.uppercased() })?.key { s.subtitleColor = c }
        if let c = Self.colorHex.first(where: { $0.value == subtitleOutlineColorHex.uppercased() })?.key { s.subtitleOutlineColor = c }
        s.subtitleBold = subtitleBold
        s.subtitleOutline = subtitleOutlineEnabled
        s.subtitleOutlineWidth = Double(subtitleOutlineWidth)
        s.subtitleBackground = subtitleBackground
        s.subtitleBackgroundOpacity = Double(subtitleBackgroundOpacity) / 100
        s.subtitleVerticalOffset = Double(subtitleVerticalOffset)
        s.subtitleDelay = subtitleDelaySeconds
        s.subtitlesOnByDefault = subtitlesOnByDefault
        s.subtitleLanguage = preferredSubtitleLanguage
        s.preferredAudioLanguage = preferredAudioLanguage
        if let e = EnginePreference(rawValue: playerEngine.rawValue) { s.engine = e }
        switch aspectModeRaw {
        case "fill": s.videoScaling = .crop
        case "stretch": s.videoScaling = .stretch
        default: s.videoScaling = .normal
        }
    }
}

/// The old player's settings store, backed by the new app's `PlayerSettingsStore`.
@MainActor
final class ClassicPlayerSettingsStore: ObservableObject {
    static let shared = ClassicPlayerSettingsStore()

    @Published var settings: ClassicPlayerSettings {
        didSet {
            guard settings != oldValue, !syncing else { return }
            var s = AppStores.shared.player.value
            settings.apply(to: &s)
            if s != AppStores.shared.player.value { AppStores.shared.player.value = s }
        }
    }
    private var syncing = false
    private var observer: AnyCancellable?

    private init() {
        settings = ClassicPlayerSettings(AppStores.shared.player.value)
        observer = AppStores.shared.player.$value.dropFirst().sink { [weak self] new in
            guard let self else { return }
            let mapped = ClassicPlayerSettings(new)
            guard mapped != self.settings else { return }
            self.syncing = true
            self.settings = mapped
            self.syncing = false
        }
    }
}
