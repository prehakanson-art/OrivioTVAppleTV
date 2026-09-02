import Foundation

/// Location + language preferences for Live TV. When set, the embedded IPTV
/// list is loaded from iptv-org's per-country / per-language playlist instead
/// of the giant global one, so channels that don't apply to the viewer are
/// simply not there. Shared singleton (like PerformanceSettingsStore) so both
/// the settings pane and the Live TV tab read it without extra wiring.
@MainActor
final class LiveTVSettingsStore: ObservableObject {
    static let shared = LiveTVSettingsStore()

    /// Whether the Live TV tab is shown in the sidebar at all.
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    /// ISO-3166 alpha-2 lowercase (iptv-org country file), "" = all.
    @Published var countryCode: String { didSet { UserDefaults.standard.set(countryCode, forKey: Self.countryKey) } }
    /// ISO-639-3 lowercase (iptv-org language file), "" = all.
    @Published var languageCode: String { didSet { UserDefaults.standard.set(languageCode, forKey: Self.langKey) } }

    private static let enabledKey = "orivio.livetv.enabled.v1"
    private static let countryKey = "orivio.livetv.country.v1"
    private static let langKey = "orivio.livetv.language.v1"

    private init() {
        // Default ON (the tab ships enabled); only an explicit false hides it.
        enabled = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
        countryCode = UserDefaults.standard.string(forKey: Self.countryKey) ?? ""
        languageCode = UserDefaults.standard.string(forKey: Self.langKey) ?? ""
    }

    static let base = "https://iptv-org.github.io/iptv"

    /// Playlist to load. LANGUAGE wins over location: a preferred language means
    /// "only channels in that language, wherever they're from" — so a US viewer
    /// who prefers English still sees BBC (English/UK) but not Al Majd
    /// (Arabic/Saudi). Location matters only when no language is chosen.
    var primaryPlaylistURL: String {
        if !languageCode.isEmpty { return "\(Self.base)/languages/\(languageCode).m3u" }
        if !countryCode.isEmpty { return "\(Self.base)/countries/\(countryCode).m3u" }
        return M3UService.iptvOrgURL
    }

    /// Countries where each language is a primary/common language — the curated
    /// safety-net list. Used to filter the global playlist by a channel's
    /// country code if the per-language iptv-org playlist can't be loaded, so
    /// non-matching-language channels still get hidden.
    static let languageCountries: [String: Set<String>] = [
        "eng": ["us", "gb", "ca", "au", "ie", "nz", "za", "in", "jm", "tt", "ph", "sg", "ng", "ke", "gh", "bs", "bb", "bz", "gy"],
        "spa": ["es", "mx", "ar", "co", "cl", "pe", "ve", "ec", "gt", "cu", "bo", "do", "hn", "py", "sv", "ni", "cr", "pa", "uy", "pr"],
        "fra": ["fr", "ca", "be", "ch", "lu", "mc", "sn", "ci", "cd", "cm", "ml", "ht", "dz", "ma", "tn"],
        "deu": ["de", "at", "ch", "li", "lu"],
        "ita": ["it", "sm", "va", "ch"],
        "por": ["pt", "br", "ao", "mz", "cv"],
        "nld": ["nl", "be", "sr", "aw"],
        "rus": ["ru", "by", "kz", "kg", "md"],
        "tur": ["tr", "cy"],
        "pol": ["pl"],
        "ara": ["sa", "ae", "eg", "iq", "jo", "kw", "lb", "ly", "ma", "om", "qa", "sy", "tn", "ye", "dz", "bh", "sd", "ps"],
        "hin": ["in"],
        "jpn": ["jp"],
        "kor": ["kr", "kp"],
        "zho": ["cn", "tw", "hk", "sg", "mo"],
    ]

    func countriesForLanguage(_ code: String) -> Set<String> {
        Self.languageCountries[code] ?? []
    }

    struct Option: Identifiable { let code: String; let name: String; var id: String { code } }

    static let countries: [Option] = [
        .init(code: "", name: "All countries"),
        .init(code: "us", name: "United States"),
        .init(code: "gb", name: "United Kingdom"),
        .init(code: "ca", name: "Canada"),
        .init(code: "au", name: "Australia"),
        .init(code: "ie", name: "Ireland"),
        .init(code: "nz", name: "New Zealand"),
        .init(code: "in", name: "India"),
        .init(code: "de", name: "Germany"),
        .init(code: "fr", name: "France"),
        .init(code: "es", name: "Spain"),
        .init(code: "it", name: "Italy"),
        .init(code: "pt", name: "Portugal"),
        .init(code: "nl", name: "Netherlands"),
        .init(code: "se", name: "Sweden"),
        .init(code: "no", name: "Norway"),
        .init(code: "dk", name: "Denmark"),
        .init(code: "pl", name: "Poland"),
        .init(code: "ru", name: "Russia"),
        .init(code: "tr", name: "Turkey"),
        .init(code: "br", name: "Brazil"),
        .init(code: "mx", name: "Mexico"),
        .init(code: "ar", name: "Argentina"),
        .init(code: "jp", name: "Japan"),
        .init(code: "kr", name: "South Korea"),
    ]

    static let languages: [Option] = [
        .init(code: "", name: "All languages"),
        .init(code: "eng", name: "English"),
        .init(code: "spa", name: "Spanish"),
        .init(code: "fra", name: "French"),
        .init(code: "deu", name: "German"),
        .init(code: "ita", name: "Italian"),
        .init(code: "por", name: "Portuguese"),
        .init(code: "nld", name: "Dutch"),
        .init(code: "rus", name: "Russian"),
        .init(code: "tur", name: "Turkish"),
        .init(code: "pol", name: "Polish"),
        .init(code: "ara", name: "Arabic"),
        .init(code: "hin", name: "Hindi"),
        .init(code: "jpn", name: "Japanese"),
        .init(code: "kor", name: "Korean"),
        .init(code: "zho", name: "Chinese"),
    ]

}
