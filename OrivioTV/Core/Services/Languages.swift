import Foundation

/// Language matching on real tags (with ISO 639-2/T vs /B aliases: ger/deu,
/// fre/fra…). Label fallback is whole-word only — **never `contains("es")`**
/// ("Chinese").
enum Languages {
    /// 639-1 → [639-2 codes (B and T)].
    static let threeLetter: [String: [String]] = [
        "en": ["eng"], "es": ["spa"], "fr": ["fre", "fra"], "de": ["ger", "deu"], "it": ["ita"], "pt": ["por"],
        "nl": ["dut", "nld"], "sv": ["swe"], "no": ["nor", "nob", "nno"], "da": ["dan"], "fi": ["fin"], "pl": ["pol"],
        "cs": ["cze", "ces"], "sk": ["slo", "slk"], "hu": ["hun"], "ro": ["rum", "ron"], "el": ["gre", "ell"],
        "tr": ["tur"], "ru": ["rus"], "uk": ["ukr"], "ar": ["ara"], "he": ["heb"], "fa": ["per", "fas"], "hi": ["hin"],
        "bn": ["ben"], "ta": ["tam"], "te": ["tel"], "ml": ["mal"], "th": ["tha"], "vi": ["vie"], "id": ["ind"],
        "ms": ["may", "msa"], "zh": ["chi", "zho"], "ja": ["jpn"], "ko": ["kor"], "hr": ["hrv"], "sr": ["srp"],
        "bg": ["bul"], "sl": ["slv"], "et": ["est"], "lv": ["lav"], "lt": ["lit"], "is": ["ice", "isl"], "ga": ["gle"],
        "ca": ["cat"], "eu": ["baq", "eus"], "gl": ["glg"], "tl": ["tgl", "fil"], "ur": ["urd"], "sq": ["alb", "sqi"],
        "mk": ["mac", "mkd"], "ka": ["geo", "kat"], "hy": ["arm", "hye"], "az": ["aze"], "kk": ["kaz"], "sw": ["swa"],
        "af": ["afr"], "cy": ["wel", "cym"], "bs": ["bos"], "mn": ["mon"], "ne": ["nep"], "si": ["sin"], "km": ["khm"],
        "lo": ["lao"], "my": ["bur", "mya"], "am": ["amh"], "pa": ["pan"], "gu": ["guj"], "kn": ["kan"], "mr": ["mar"],
    ]

    /// Common subset shown first in pickers.
    static let common = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "no", "da", "fi", "pl", "ru", "tr", "ar", "he", "hi", "ja", "ko", "zh"]

    static var all: [String] {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }.sorted { name($0) < name($1) }
    }

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Normalizes any tag ("eng", "en-US", "pt-BR", "English") to 639-1 when possible.
    static func normalize(_ tag: String?) -> String? {
        guard var t = tag?.lowercased().trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let dash = t.firstIndex(where: { $0 == "-" || $0 == "_" }) { t = String(t[..<dash]) }
        if t.count == 2 { return t }
        if t.count == 3 {
            if t == "pob" || t == "pb" { return "pt" }
            for (two, threes) in threeLetter where threes.contains(t) { return two }
            return nil
        }
        // A label: whole-word match against English language names.
        let words = Set(t.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for (two, _) in threeLetter where words.contains(name(two).lowercased()) { return two }
        return nil
    }

    static func matches(_ tag: String?, _ preferred: String) -> Bool {
        guard let n = normalize(tag) else { return false }
        return n == preferred.lowercased()
    }
}

/// Add-on subtitles, queried concurrently (order preserved).
@MainActor
enum SubtitleFetcher {
    static func fetchAll(meta: MetaItem, video: MetaVideo?, filename: String? = nil) async -> [AddonSubtitle] {
        let addons = AppStores.shared.addons.subtitleAddons
        let type = meta.isSeries ? "series" : "movie"
        let id = video?.id ?? meta.id
        var extras: [String: String] = [:]
        if let filename { extras["filename"] = filename }
        let lists = await boundedConcurrentMap(addons.filter { $0.manifest.handles("subtitles", type: type, id: id) }, limit: 4) { addon in
            (try? await AddonClient.subtitles(addon, type: type, id: id, extras: extras)) ?? []
        }
        return lists.flatMap { $0 }
    }

    static func preferredSubtitleURL(meta: MetaItem, video: MetaVideo?) async -> URL? {
        let s = AppStores.shared.player.value
        let subs = await fetchAll(meta: meta, video: video)
        let pick = subs.first { Languages.matches($0.lang, s.subtitleLanguage) }
            ?? s.subtitleSecondaryLanguage.flatMap { sec in subs.first { Languages.matches($0.lang, sec) } }
        return pick.flatMap { URL(string: $0.url) }
    }
}
