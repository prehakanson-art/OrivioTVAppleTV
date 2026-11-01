import Foundation

/// Decides whether an audio track is in the language the viewer asked for.
///
/// The three playback engines describe a track completely differently — the
/// FFmpeg paths expose the container's language tag ("eng", "spa"), VLC exposes
/// only a display name ("English 5.1"), and plenty of re-encodes tag nothing at
/// all and put the language in the track title. Each engine used to do its own
/// comparison, so "Preferred audio language" worked on some streams and was
/// silently ignored on others:
///
/// * a bare `hasPrefix(code)` misses "English" when the setting is "en" (the
///   capital E alone defeats it) and misses "eng" when a file tags 639-2/B
///   forms like "ger" against a "de" setting,
/// * a substring search the other way matched "en" inside "French",
/// * and a track with a nil language code fell through every check even when
///   its label said the language in plain words.
///
/// This is the one comparison all three now use: match on the language CODE
/// when there is one, fall back to the track's LABEL when there isn't, and know
/// the handful of aliases each language actually appears under.
enum ClassicAudioLanguageMatch {

    /// ISO 639-1 code → every spelling that means the same language: the
    /// 639-2/T and 639-2/B three-letter forms (which disagree for exactly the
    /// languages people configure most — ger/deu, fre/fra), the English name,
    /// and the endonym releases label tracks with.
    private static let aliases: [String: Set<String>] = [
        "en": ["en", "eng", "english"],
        "es": ["es", "spa", "esl", "spanish", "espanol", "castellano", "latino"],
        "fr": ["fr", "fra", "fre", "french", "francais"],
        "de": ["de", "deu", "ger", "german", "deutsch"],
        "it": ["it", "ita", "italian", "italiano"],
        "pt": ["pt", "por", "portuguese", "portugues", "brazilian"],
        "ja": ["ja", "jpn", "jap", "japanese"],
        "ko": ["ko", "kor", "korean"],
        "zh": ["zh", "zho", "chi", "chinese", "mandarin", "cantonese"],
        "hi": ["hi", "hin", "hindi"],
        "ru": ["ru", "rus", "russian"],
        "ar": ["ar", "ara", "arabic"],
        // Not an allow-list: any language NOT named here still matches through
        // `normalizedCode` + the localized-name fallback below. This (and the
        // table above) only add the endonyms / 639-2 forms Foundation does not
        // know for a few languages people configure most.
        "vi": ["vi", "vie", "vietnamese", "tieng viet"],
        "th": ["th", "tha", "thai"],
        "tr": ["tr", "tur", "turkish", "turkce"],
        "nl": ["nl", "nld", "dut", "dutch", "nederlands"],
        "pl": ["pl", "pol", "polish", "polski"],
        "id": ["id", "ind", "indonesian", "bahasa"],
        "uk": ["uk", "ukr", "ukrainian"],
        "el": ["el", "ell", "gre", "greek"],
        "he": ["he", "iw", "heb", "hebrew"],
        "sv": ["sv", "swe", "swedish", "svenska"],
        "no": ["no", "nor", "norwegian", "norsk"],
        "da": ["da", "dan", "danish", "dansk"],
        "fi": ["fi", "fin", "finnish", "suomi"],
        "cs": ["cs", "ces", "cze", "czech"],
        "hu": ["hu", "hun", "hungarian", "magyar"],
        "ro": ["ro", "ron", "rum", "romanian"],
        "fa": ["fa", "fas", "per", "persian", "farsi"],
        "ms": ["ms", "msa", "may", "malay"],
        "ta": ["ta", "tam", "tamil"],
        "te": ["te", "tel", "telugu"],
        "bn": ["bn", "ben", "bengali"],
        "ur": ["ur", "urd", "urdu"],
        "tl": ["tl", "fil", "tagalog", "filipino"],
    ]

    /// Every alias of the preferred language. Unknown languages still get the
    /// code itself plus its localized name, so nothing is excluded by omission.
    static func aliases(for preferred: String) -> Set<String> {
        let base = normalizedCode(preferred)
        if let known = aliases[base] {
            var out = known
            // Include the current locale's name for the language too: a track
            // labelled "Vietnamese" must satisfy a preference stored as "vi".
            if let full = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
                out.insert(full)
            }
            return out
        }
        // Not a language we have a table for: match its own spellings only.
        var out: Set<String> = [base]
        if let full = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
            out.insert(full)
        }
        if let full = Locale.current.localizedString(forLanguageCode: preferred)?.lowercased() {
            out.insert(full)
        }
        return out
    }

    /// Reduce any language tag to its canonical two-letter ISO 639-1 base:
    /// "en-US" → "en", "eng" → "en", "vie" → "vi", "ger" → "de".
    ///
    /// Foundation's own identifier parser does the 639-2/B and 639-2/T mapping,
    /// so this works for EVERY language rather than only the alias table above.
    /// Unrecognized tags are returned lowercased and otherwise untouched.
    /// The code for a language NAME ("Français", "English"), for engines that
    /// report a display name and no tag (VLC). Nil when it isn't one.
    static func code(forName name: String) -> String? {
        let key = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .trimmingCharacters(in: .whitespaces)
        for (short, forms) in aliases where forms.contains(key) { return short }
        return nil
    }

    static func normalizedCode(_ code: String) -> String {
        let bare = code.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? code.lowercased()
        guard !bare.isEmpty, bare != "und" else { return bare }
        if bare.count == 2 { return bare }
        for (short, forms) in aliases where forms.contains(bare) { return short }
        if let canonical = Locale(identifier: bare).language.languageCode?.identifier,
           canonical.count == 2, canonical != bare {
            return canonical
        }
        return bare
    }

    /// A human-readable name for a language tag, preserving the raw tag as the
    /// fallback when Foundation doesn't recognize it. Returns nil only for an
    /// empty tag, so callers can still choose their own "Unknown" wording.
    static func displayName(for code: String?) -> String? {
        guard let code, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: normalizedCode(code)),
           !name.isEmpty {
            return name
        }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        return code
    }

    /// Does this track carry the preferred language?
    ///
    /// - Parameters:
    ///   - code: the container's language tag, if the engine exposes one.
    ///   - label: the track's display name — the only signal VLC gives, and the
    ///     fallback whenever a file tags no language.
    ///   - preferred: the configured (or remembered) language.
    static func matches(code: String?, label: String?, preferred: String) -> Bool {
        let preferred = preferred.trimmingCharacters(in: .whitespaces)
        guard !preferred.isEmpty else { return false }
        let wanted = aliases(for: preferred)

        // A real language tag is definitive — believe it, either way. Without
        // this, an "eng"-tagged track sitting in a file whose title says
        // "Latino" could match a Spanish preference off the label.
        if let code, !code.isEmpty, code.lowercased() != "und" {
            return wanted.contains(normalizedCode(code))
        }

        guard let label, !label.isEmpty else { return false }
        // Whole words only: "en" is inside "French" and a contains-check on the
        // bare code is how the French track once won an English preference.
        let words = Set(
            label.folding(options: [.diacriticInsensitive, .caseInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        return !words.isDisjoint(with: wanted)
    }

    /// A commentary, described-video or otherwise secondary track, spotted from
    /// its label. The FFmpeg paths also have disposition flags, which are more
    /// reliable; this catches the files that set no flags and say it in words.
    static func isSecondary(label: String?) -> Bool {
        guard let label = label?.lowercased() else { return false }
        for marker in ["commentary", "description", "descriptive", "narration",
                       "sdh", "visual impaired", "audio description"]
        where label.contains(marker) {
            return true
        }
        return false
    }
}

/// The audio picker's row text, the same on every engine.
///
/// Each engine used to build its own (VLC still can't do much better: it
/// reports a display name only, so its rows get the language and dub, not
/// the codec): KSPlayer put the language in brackets
/// after the title ("Surround 7.1 (French)", which the picker's width cut
/// off), the DV engine joined tag, codec and channel count ("French · AC3 ·
/// 6ch"), AetherEngine showed the bare title. The row is now always the
/// language (with the French dub, VFQ / VFF / VFI) first, then the track's
/// own title, or, when the title only restates what the row already says,
/// codec and layout: "French (VFQ) – DD+ 5.1".
enum ClassicAudioTrackLabel {

    /// - Parameters:
    ///   - title: the container's track title, as the engine reports it.
    ///   - languageTag: the container's language tag ("fre", "fr-CA").
    ///   - codec: FFmpeg's codec name ("truehd", "eac3") or an engine's own
    ///     display name ("Dolby Digital+"); both are shortened alike.
    ///   - profile: the codec profile ("Dolby TrueHD + Dolby Atmos",
    ///     "DTS-HD MA"), which names Atmos and DTS-HD before decode does.
    ///   - note: an engine fact appended last ("→ PCM").
    static func make(title rawTitle: String?, languageTag: String?, codec rawCodec: String?,
                     profile: String? = nil, channels: Int, atmos: Bool = false, dtsx: Bool = false,
                     commentary: Bool = false, note: String? = nil, fallbackID: Int) -> String {
        var title = rawTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        // An untitled track comes back as "ENG (eac3)" from AetherEngine and
        // as the bare tag ("eng") from KSPlayer: the row already says both.
        if title.caseInsensitiveCompare(languageTag ?? "") == .orderedSame
            || title.range(of: #"^[a-z]{2,3} \([a-z0-9_]+\)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            title = ""
        }
        let profileLower = profile?.lowercased() ?? ""
        let codec = shortCodec(rawCodec, profile: profile)
        let object: String? = atmos || profileLower.contains("atmos") ? "Atmos"
            : (dtsx || profileLower.contains("dts:x") ? "DTS:X" : nil)

        var language = ClassicAudioLanguageMatch.displayName(for: languageTag)
        let dub = frenchDub(languageTag: languageTag, title: title)
        if dub == nil, let tag = languageTag, tag.contains("-") || tag.contains("_"),
           let regional = Locale.current.localizedString(forIdentifier: tag.replacingOccurrences(of: "_", with: "-")) {
            language = regional   // "Portuguese (Brazil)"
        }
        if let dub, let name = language { language = "\(name) (\(dub))" }

        // Words a title can hold that the row already shows: the layout, the
        // language, and the French dub markers.
        let generic = title.range(
            of: #"^(surround|stereo|mono|\d\.\d|\d+ ?ch(annels)?|english|anglais|french|fran[cç]ais|vf[fqi2]?|ca|fr|qc|canada|canadien|france|qu[ée]bec|[\s.,·()\[\]_-])*$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        var detail: String
        if generic {
            let layout: String? = switch channels {
            case 1: "Mono"
            case 2: "2.0"
            case 3...: "\(channels - 1).1"
            default: nil
            }
            // KSPlayer's codec already reads "TrueHD Atmos".
            let objectWord = object.flatMap { codec?.localizedCaseInsensitiveContains($0) == true ? nil : $0 }
            detail = [codec, objectWord, layout].compactMap { $0 }.joined(separator: " ")
        } else {
            detail = title
            if let codec, !detail.localizedCaseInsensitiveContains(codec) { detail += " · \(codec)" }
            if let object, !detail.localizedCaseInsensitiveContains(object) { detail += " \(object)" }
        }
        if commentary, !detail.lowercased().contains("comment") { detail += " (Commentary)" }
        if let note { detail += " \(note)" }

        var label: String
        if let language, !detail.localizedCaseInsensitiveContains(language) {
            label = detail.isEmpty ? language : "\(language) – \(detail)"
        } else {
            label = detail
        }
        if label.isEmpty { label = "Track \(fallbackID)" }
        return label
    }

    /// The codec as the picker spells it: short enough that a row with a
    /// language and a dub still fits ("DD+", not "Dolby Digital+").
    static func shortCodec(_ raw: String?, profile: String? = nil) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let codec = raw.lowercased()
        let profile = profile ?? ""
        switch codec {
        case "truehd", "mlp": return "TrueHD"
        case "eac3", "e-ac-3", "dolby digital+": return "DD+"
        case "ac3", "ac-3", "dolby digital": return "DD"
        case "dts", "dts-hd":
            return profile.uppercased().contains("HD") ? profile : (codec == "dts-hd" ? "DTS-HD" : "DTS")
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        default:
            if codec.hasPrefix("dolby digital+") { return "DD+" + raw.dropFirst("dolby digital+".count) }
            if codec.hasPrefix("dolby digital") { return "DD" + raw.dropFirst("dolby digital".count) }
            return codec.hasPrefix("pcm") ? "PCM" : (raw == codec ? raw.uppercased() : raw)
        }
    }

    /// Which French dub a track is, from its tag's region or its title: VFQ
    /// (Quebec), VFF (France) or VFI (international). Nil for any other
    /// language, and for a French track that says neither.
    static func frenchDub(languageTag: String?, title: String) -> String? {
        let tag = languageTag ?? ""
        let titleSaysFrench = title.range(of: #"\b(fr(ench|an[cç]ais)?|vf[fqi2]?)\b"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
        guard ClassicAudioLanguageMatch.normalizedCode(tag) == "fr" || (tag.isEmpty && titleSaysFrench)
        else { return nil }
        let region = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst().first
        func says(_ pattern: String) -> Bool {
            title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if region == "ca" || says(#"\b(vfq|ca|qc|canad\w*|qu[ée]bec\w*)\b"#) { return "VFQ" }
        if says(#"\bvfi\b"#) { return "VFI" }
        if region == "fr" || says(#"\b(vff|vf2|france)\b"#) { return "VFF" }
        return nil
    }
}
