import Foundation

// MARK: - Appearance (per profile)

enum NavigationStyle: String, Codable, CaseIterable, Identifiable {
    case sidebar, rail, topBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sidebar: return "Apple TV sidebar"
        case .rail: return "Side rail"
        case .topBar: return "Top bar"
        }
    }
}

enum Ambience: String, Codable, CaseIterable, Identifiable {
    case slate, midnight, ocean, violet, crimson, emerald, amber, rose, graphite
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var hexes: (String, String) {
        switch self {
        case .slate: return ("#3F4B66", "#262E40")
        case .midnight: return ("#1A1D26", "#0B0C10")
        case .ocean: return ("#2D5C9E", "#17305A")
        case .violet: return ("#4B3A78", "#24193F")
        case .crimson: return ("#6A2D3A", "#2E1218")
        case .emerald: return ("#2C5B4E", "#132A24")
        case .amber: return ("#6B4A2A", "#2E1F10")
        case .rose: return ("#6A2E55", "#2D1226")
        case .graphite: return ("#3A3A3E", "#1C1C1F")
        }
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case systemWhite, crimson, ocean, violet, orivioPurple, lavender, emerald, mint, amber, rose
    var id: String { rawValue }
    var label: String {
        switch self {
        case .systemWhite: return "System White"
        case .orivioPurple: return "Orivio Purple"
        default: return rawValue.capitalized
        }
    }
    var hex: String {
        switch self {
        case .systemWhite: return "#FFFFFF"
        case .crimson: return "#E5484D"
        case .ocean: return "#0A84FF"
        case .violet: return "#8E4EC6"
        case .orivioPurple: return "#7B5CFF"
        case .lavender: return "#C4B5FD"
        case .emerald: return "#30A46C"
        case .mint: return "#7EE0C3"
        case .amber: return "#FFB224"
        case .rose: return "#F2557A"
        }
    }
    /// Light accents need dark ink on accent fills.
    var needsDarkInk: Bool { [.systemWhite, .lavender, .mint, .amber].contains(self) }
}

struct AppearanceSettings: SettingsModel {
    var navigationStyle: NavigationStyle = .sidebar
    /// Side rail only: hide the collapsed rail (pages take the full width); Left
    /// at the screen edge or Back opens it.
    var railAutoHide = false
    var ambience: Ambience = .slate
    var accent: AccentChoice = .systemWhite
    var artworkTint = true
}

// MARK: - Home & Layout (per profile)

enum HeroLayout: String, Codable, CaseIterable, Identifiable {
    case rolling, pinnedFocus, hybrid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rolling: return "Rolling"
        case .pinnedFocus: return "Pinned Focus"
        case .hybrid: return "Hybrid"
        }
    }
}

enum ContinueWatchingSort: String, Codable, CaseIterable, Identifiable {
    case recent, streaming
    var id: String { rawValue }
    var label: String { self == .recent ? "Recently watched" : "Streaming style" }
}

/// Collection folder focus artwork (GIFs).
enum FocusArtMode: String, Codable, CaseIterable, Identifiable {
    case animated, still, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .animated: return "Animated"
        case .still: return "Still image"
        case .off: return "Off"
        }
    }
}

struct HomeRowConfig: Codable, Equatable, Hashable {
    /// `<addonID>|<type>|<catalogID>` or `collection:<id>`.
    var key: String
    var hidden = false
    var customTitle: String?
    var numbered: Bool?
}

struct HomeSettings: SettingsModel {
    var heroLayout: HeroLayout = .hybrid
    /// nil = Automatic (first row), else a row key.
    var heroSource: String?
    var heroVideo = true
    /// Background trailers (Home and Detail) play with sound. A new key, so
    /// the old muted default doesn't carry over.
    var trailerSound = true
    var featuredSection = true
    /// "Comedies to Watch After …" rows built from the last titles finished.
    /// On by default: they already exist on Home, so an update must not drop them.
    var afterWatchingRows = true
    var landscapePosters = false
    var posterLabels = true
    var posterBanners = true
    var hideUnreleased = false
    var cwSort: ContinueWatchingSort = .recent
    var episodeThumbnails = true
    var nextUpFromFurthest = false
    var showUnairedNextUp = true
    var hideSpoilers = false
    var upcomingCountdown = false
    var fullStreamNames = false
    /// Minutes; 0 = off.
    var autoRefreshMinutes = 0
    var maxHomeRows = 30
    var rows: [HomeRowConfig] = []
    /// Collection folders' focus GIFs. Reduce Motion turns Animated into Still.
    var focusArt: FocusArtMode = .animated
}

// MARK: - Player (per profile)

/// `aether` only drives the classic (VOD) player, which hosts AetherEngine;
/// the live-TV player treats it like `auto`.
enum EnginePreference: String, Codable, CaseIterable, Identifiable {
    case auto, aether, native, ffmpeg, vlc, external
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .aether: return "AetherEngine"
        case .native: return "Native"
        case .ffmpeg: return "FFmpeg"
        case .vlc: return "VLC"
        case .external: return "External app"
        }
    }
}

enum PlaybackMode: String, Codable, CaseIterable, Identifiable {
    case automatic, maximumFidelity, compatibility
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .maximumFidelity: return "Maximum Fidelity"
        case .compatibility: return "Compatibility"
        }
    }
}

enum VideoScaling: String, Codable, CaseIterable, Identifiable {
    case normal, crop, stretch
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ExternalPlayerApp: String, Codable, CaseIterable, Identifiable {
    case infuse, vlc, nplayer, vidhub, senplayer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        case .nplayer: return "nPlayer"
        case .vidhub: return "VidHub"
        case .senplayer: return "SenPlayer"
        }
    }
}

struct PlayerSettings: SettingsModel {
    // Auto-play
    var autoPlayNextEpisode = true
    var upNextSecondsBeforeEnd = 30
    /// -1 = Unlimited (wait for Play).
    var autoPlayCountdown = 10
    var stillWatchingEnabled = false
    var stillWatchingAfter = 3
    var keepSameSourceForNext = true
    // Seeking
    var skipAmount = 10
    var scrubberJump = 60
    var skipIntroButton = true
    var autoSkipIntros = false
    var aniSkip = false
    var scrubPreviews = true
    // Sources
    var linkFilters = true
    var linksPerResolution = 6
    var sourceSearchPatience = 45
    var minimumResolution: String?
    var hideAV1 = false
    var hdrOnly = false
    var dolbyVisionOnly = false
    var cachedOnly = false
    // Auto-play source
    var autoPlayBestSource = false
    var autoPlayCachedOnly = false
    var autoPlayRegex = ""
    var reuseLastLink = false
    var reuseWindowHours = 24
    // Player
    var engine: EnginePreference = .auto
    var playbackMode: PlaybackMode = .automatic
    var hybridCache = true
    var atmosPassthrough = true
    var videoScaling: VideoScaling = .normal
    var externalPlayer: ExternalPlayerApp = .infuse
    var externalForwardSubtitles = true
    var externalSendSeason = true
    // Content
    var parentalGuide = true
    // Trailers: -1 = off
    var detailTrailerDelay = 3
    // Audio
    var preferredAudioLanguage = "en"
    // Subtitles
    var subtitlesOnByDefault = false
    var subtitleLanguage = "en"
    var subtitleSecondaryLanguage: String?
    var preferForcedSubtitles = true
    var preferAddonSubtitles = false
    var fullStyledSubtitles = false
    var subtitleSize: Double = 36
    var subtitleFont = "System"
    var subtitleColor = "White"
    var subtitleBold = false
    var subtitleOutline = true
    var subtitleOutlineColor = "Black"
    var subtitleOutlineWidth: Double = 2
    var subtitleBackground = true
    var subtitleBackgroundOpacity: Double = 0.45
    var subtitleVerticalOffset: Double = 0
    var subtitleDelay: Double = 0
}

// MARK: - Integrations

struct TMDBSettings: SettingsModel {
    var enabled = true
    var apiKey = ""
    var language = "en-US"
    var enrichContinueWatching = true
    var isUsable: Bool { enabled && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct MDBListSettings: SettingsModel {
    var enabled = false
    var apiKey = ""
    var isUsable: Bool { enabled && !apiKey.isEmpty }
}

enum DebridProvider: String, Codable, CaseIterable, Identifiable {
    case realDebrid, premiumize, torbox, allDebrid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .premiumize: return "Premiumize"
        case .torbox: return "TorBox"
        case .allDebrid: return "AllDebrid"
        }
    }
    var short: String {
        switch self {
        case .realDebrid: return "RD"
        case .premiumize: return "PM"
        case .torbox: return "TB"
        case .allDebrid: return "AD"
        }
    }
}

struct DebridSettings: SettingsModel {
    var keys: [String: String] = [:]
    var rdRefreshToken: String?
    var rdClientID: String?
    var rdClientSecret: String?
    var preferred: DebridProvider = .realDebrid

    func key(_ p: DebridProvider) -> String? {
        let k = keys[p.rawValue]?.trimmingCharacters(in: .whitespaces)
        return (k?.isEmpty ?? true) ? nil : k
    }
    var configured: [DebridProvider] {
        let all = DebridProvider.allCases.filter { key($0) != nil }
        return all.sorted { a, _ in a == preferred }
    }
    var hasAny: Bool { !configured.isEmpty }
}

struct TorrentSettings: SettingsModel {
    var enabled = false
    var serverURL = "http://192.168.1.2:8090"
}

struct LiveTVSettings: SettingsModel {
    var enabled = true
    var country = ""
    var language = ""
    var customPlaylistURL = ""
    var xtreamServer = ""
    var xtreamUsername = ""
    var xtreamPassword = ""
    /// XMLTV guide URL; empty = the provider's / playlist's own guide.
    var epgURL = ""
    var livePreview = PerformanceProfile.isHighTier
    var useAddonChannels = true
    var homeChannelIDs: [String] = []
    var recentChannelIDs: [String] = []
}

struct TrackerFlags: SettingsModel {
    var scrobble = true
    var syncHistory = true
    var syncContinueWatching = true
    var syncWatchlist = true
    var syncRatings = true
}
