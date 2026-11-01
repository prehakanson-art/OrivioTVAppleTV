import SwiftUI

/// Settings → Playback → Test streams: public sample files that exercise each
/// playback path (HDR10, HLG, Dolby Vision 5 / 8.1 / 8.4, TrueHD Atmos,
/// DTS-HD MA, E-AC-3 JOC, AV1, PGS and ASS subtitles) without a stream add-on,
/// plus a field for any URL of your own (DV Profile 7 FEL, HDR10+ and DTS:X
/// have no reliable public direct link — bring your own file for those).
///
/// Every link was checked when it was added (ffprobe: codec, transfer, DV
/// profile, audio). Sources: Apple's HLS examples
/// (developer.apple.com/streaming/examples), Jellyfin's test videos
/// (repo.jellyfin.org/test-videos, CC BY-SA 4.0) and the FFmpeg sample archive
/// (samples.ffmpeg.org).
///
/// A test plays through `PlayerPresenter.present`, i.e. the Classic player,
/// so the engine picked in Playback (Auto / AetherEngine / Native / FFmpeg /
/// VLC) decides how it opens, exactly as for a real add-on link. It never
/// touches Continue Watching, Trakt or the add-on failover sweep (see
/// `isTestMeta`).
enum TestStreamCatalog {
    /// The add-on name every test entry carries.
    static let addonName = "Orivio Test Streams"
    static let addonID = "orivio.test-streams"
    /// Test sessions use ids no add-on, tracker or progress row can know.
    static let metaIDPrefix = "orivio-test:"

    static func isTestMeta(_ id: String) -> Bool { id.hasPrefix(metaIDPrefix) }

    struct Item: Identifiable {
        let id: String
        let title: String
        /// What the sample carries: video, audio, subtitles, container.
        let detail: String
        /// Short badge (resolution · range). It is also the stream name's
        /// second line, so the player's name-based routing hints (DV, Atmos,
        /// TrueHD…) see it exactly as they would on an add-on link.
        let tag: String
        let size: String
        let url: String
    }

    struct Category: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let items: [Item]
    }

    private static let apple = "https://devstreaming-cdn.apple.com/videos/streaming/examples"
    private static let jellyfin = "https://repo.jellyfin.org/test-videos"
    private static let ffmpeg = "https://samples.ffmpeg.org"

    static let categories: [Category] = [
        Category(
            id: "dv", title: "Dolby Vision",
            subtitle: "Profile 5 (IPT, no fallback), 8.1 (HDR10 base) and 8.4 (HLG base)",
            icon: "sparkles.tv.fill",
            items: [
                Item(id: "apple-dv-atmos", title: "Apple TV trailer — DV + Atmos (HLS)",
                     detail: "DV P5 + HDR10 + SDR ladder up to 2160p, E-AC-3 JOC Atmos / AC-3 / AAC, WebVTT subtitles (FR, ES, IT, ZH, forced, SDH) + CEA-608",
                     tag: "2160p DV Atmos", size: "Streaming",
                     url: "\(apple)/adv_dv_atmos/main.m3u8"),
                Item(id: "jf-dv5-4k", title: "Jellyfin — DV Profile 5",
                     detail: "HEVC Main10, DV P5 (BL compatibility 0), MP4, no audio",
                     tag: "2160p DV P5", size: "157 MB",
                     url: "\(jellyfin)/HDR/Dolby%20Vision/Test%20Jellyfin%204K%20DV%20P5.mp4"),
                Item(id: "jf-dv81-4k", title: "Jellyfin — DV Profile 8.1",
                     detail: "HEVC Main10, DV P8.1 on an HDR10 (PQ) base layer, MP4, no audio",
                     tag: "2160p DV P8.1", size: "119 MB",
                     url: "\(jellyfin)/HDR/Dolby%20Vision/Test%20Jellyfin%204K%20DV%20P8.1.mp4"),
                Item(id: "jf-dv84-4k", title: "Jellyfin — DV Profile 8.4",
                     detail: "HEVC Main10, DV P8.4 on an HLG base layer, MP4, no audio",
                     tag: "2160p DV P8.4 HLG", size: "183 MB",
                     url: "\(jellyfin)/HDR/Dolby%20Vision/Test%20Jellyfin%204K%20DV%20P8.4.mp4"),
                Item(id: "jf-dv5-1080", title: "Jellyfin — DV Profile 5 (1080p)",
                     detail: "HEVC Main10, DV P5, MP4, no audio — the light variant for older boxes",
                     tag: "1080p DV P5", size: "47 MB",
                     url: "\(jellyfin)/HDR/Dolby%20Vision/Test%20Jellyfin%201080p%20DV%20P5.mp4"),
            ]
        ),
        Category(
            id: "hdr", title: "HDR10 / HLG",
            subtitle: "PQ and HLG transfer, HEVC and AV1, up to 150 Mb/s",
            icon: "sun.max.fill",
            items: [
                Item(id: "jf-hevc-hdr10-40", title: "Jellyfin — HEVC HDR10 40 Mb/s",
                     detail: "HEVC Main10, BT.2020 PQ, MP4, no audio",
                     tag: "2160p HDR10", size: "140 MB",
                     url: "\(jellyfin)/HDR/HDR10/HEVC/Test%20Jellyfin%204K%20HEVC%20HDR10%2040M.mp4"),
                Item(id: "jf-hevc-hdr10-150", title: "Jellyfin — HEVC HDR10 150 Mb/s (stress)",
                     detail: "HEVC Main10, BT.2020 PQ, MP4 — network and buffer stress test",
                     tag: "2160p HDR10", size: "527 MB",
                     url: "\(jellyfin)/HDR/HDR10/HEVC/Test%20Jellyfin%204K%20HEVC%20HDR10%20150M.mp4"),
                Item(id: "jf-av1-hdr10-40", title: "Jellyfin — AV1 HDR10 40 Mb/s",
                     detail: "AV1 Main 10-bit, BT.2020 PQ, MP4 — hardware AV1 only on the newest Apple TV, software decode elsewhere",
                     tag: "2160p AV1 HDR10", size: "142 MB",
                     url: "\(jellyfin)/HDR/HDR10/AV1/Test%20Jellyfin%204K%20AV1%20HDR10%2040M.mp4"),
                Item(id: "ff-leopard", title: "Planet Earth II — Leopard (MKV)",
                     detail: "HEVC Main10 HDR10, DTS-HD MA 5.1, PGS subtitles (English SDH)",
                     tag: "2160p HDR10 DTS-HD MA", size: "24 MB",
                     url: "\(ffmpeg)/4khdr/PE2_Leopard_4K.mkv"),
            ]
        ),
        Category(
            id: "audio", title: "Lossless & object audio",
            subtitle: "TrueHD Atmos, DTS-HD MA, E-AC-3 — the AetherEngine object-audio and bitstream paths",
            icon: "hifispeaker.2.fill",
            items: [
                Item(id: "ff-lalaland", title: "La La Land — café (MKV)",
                     detail: "HEVC Main10 HDR10, Dolby TrueHD + Atmos 7.1, 4 PGS tracks (EN, ES, FR)",
                     tag: "2160p HDR10 TrueHD Atmos", size: "425 MB",
                     url: "\(ffmpeg)/4khdr/LaLaLand_cafe_4K.mkv"),
                Item(id: "ff-passengers", title: "Passengers — breakfast (MKV)",
                     detail: "HEVC Main10 HDR10, Dolby TrueHD + Atmos 7.1, 4 PGS tracks",
                     tag: "2160p HDR10 TrueHD Atmos", size: "151 MB",
                     url: "\(ffmpeg)/4khdr/Passengers_Breakfast_4K.mkv"),
                Item(id: "ff-atmos-m2ts", title: "TrueHD Atmos Blu-ray clip (M2TS)",
                     detail: "H.264 1080p, TrueHD + Atmos 7.1 and 7 AC-3 tracks, 3 PGS tracks — MPEG-TS demux and track switching",
                     tag: "1080p TrueHD Atmos", size: "48 MB",
                     url: "\(ffmpeg)/ffmpeg-bugs/trac/ticket3960/dolby_atmos_truehd_sample.m2ts"),
                Item(id: "ff-dtshdma", title: "DTS-HD MA Blu-ray clip (M2TS)",
                     detail: "H.264 1080p, DTS-HD MA 5.1 + 6 AC-3 tracks, 4 PGS tracks",
                     tag: "1080p DTS-HD MA", size: "10 MB",
                     url: "\(ffmpeg)/A-codecs/DTS/bond_sample_dtshdma.m2ts"),
                Item(id: "ff-eac3", title: "E-AC-3 5.1 (MKV)",
                     detail: "H.264 720p, Dolby Digital Plus 5.1",
                     tag: "720p DDP5.1", size: "6 MB",
                     url: "\(ffmpeg)/A-codecs/AC3/eac3/sample-eac3.mkv"),
            ]
        ),
        Category(
            id: "subs", title: "Subtitles",
            subtitle: "Bitmap (PGS) and styled (ASS/SSA) tracks embedded in MKV",
            icon: "captions.bubble.fill",
            items: [
                Item(id: "ff-pgs", title: "PGS sample (MKV)",
                     detail: "H.264 480p, one Blu-ray PGS track (1280×720 canvas)",
                     tag: "480p PGS", size: "24 KB",
                     url: "\(ffmpeg)/sub/PGS/supsample.mkv"),
                Item(id: "ff-ass", title: "ASS/SSA, 15 tracks (MKV)",
                     detail: "MPEG-4 Part 2 video, Vorbis audio, 15 styled ASS tracks (EN, NL, FI, FR, DE…) — software video decode",
                     tag: "480p ASS", size: "8 MB",
                     url: "\(ffmpeg)/Matroska/subtitles/SSA_15subtitles.mkv"),
            ]
        ),
        Category(
            id: "sdr", title: "SDR codecs & containers",
            subtitle: "Baselines: HLS, AV1, HEVC 10-bit, MKV",
            icon: "film.stack.fill",
            items: [
                Item(id: "apple-bipbop-hevc", title: "Apple Bip Bop — AVC/HEVC (HLS)",
                     detail: "AVC and HEVC ladders, AAC / AC-3 / E-AC-3 renditions, WebVTT subtitles",
                     tag: "1080p HEVC", size: "Streaming",
                     url: "\(apple)/bipbop_adv_example_hevc/master.m3u8"),
                Item(id: "apple-av1", title: "Apple TV trailer — AV1 (HLS)",
                     detail: "AV1 10-bit SDR ladder, E-AC-3 JOC Atmos / AC-3 / AAC, WebVTT subtitles",
                     tag: "2160p AV1 Atmos", size: "Streaming",
                     url: "\(apple)/av1-sample/av1-sample.m3u8"),
                Item(id: "jf-hevc10-sdr", title: "Jellyfish — HEVC 10-bit 120 Mb/s (MKV)",
                     detail: "HEVC Main10 SDR 3840×2160, MKV, no audio — high-bitrate MKV read-ahead",
                     tag: "2160p HEVC 10-bit", size: "429 MB",
                     url: "https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-120-mbps-4k-uhd-hevc-10bit.mkv"),
                Item(id: "jf-avc-1080", title: "Jellyfin — H.264 1080p",
                     detail: "AVC High, SDR, MP4, no audio",
                     tag: "1080p H.264", size: "35 MB",
                     url: "\(jellyfin)/SDR/AVC/Test%20Jellyfin%201080p%20AVC%2010M.mp4"),
            ]
        ),
    ]

    static func request(for item: Item) -> PlaybackRequest? {
        request(id: item.id, title: item.title, tag: item.tag, detail: item.detail, url: item.url)
    }

    /// A pasted link. Nil when it isn't an http(s) URL.
    static func request(customURL raw: String) -> PlaybackRequest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return request(id: "custom", title: name.isEmpty ? "Custom URL" : name,
                       tag: "Custom", detail: trimmed, url: trimmed)
    }

    private static func request(id: String, title: String, tag: String,
                                detail: String, url raw: String) -> PlaybackRequest? {
        guard let url = URL(string: raw) else { return nil }
        let meta = MetaItem(id: metaIDPrefix + id, type: "movie", name: title)
        let stream = Stream(name: "Test\n\(tag)", title: title, description: detail, url: raw)
        let entry = StreamEntry(stream: stream, addonName: addonName, addonID: addonID, index: 0)
        return PlaybackRequest(meta: meta, video: nil, entry: entry, allEntries: [entry],
                               resumePosition: nil, url: url)
    }

    /// Opens a test the way any VOD link opens (stops Picture in Picture first,
    /// then the Classic player cover).
    @MainActor
    static func play(_ request: PlaybackRequest?) {
        guard let request else {
            ToastCenter.shared.show("Not a playable http(s) URL.", systemImage: "exclamationmark.triangle.fill")
            return
        }
        PlayerPresenter.shared.present(request)
    }
}

/// The Test streams page, pushed from Settings → Playback → Developer.
struct TestStreamsPage: View {
    @EnvironmentObject private var player: PlayerSettingsStore
    @AppStorage("orivio.dev.testStreamCustomURL") private var customURL = ""

    var body: some View {
        SettingsGroup(header: "Engine",
                      footer: "The same switch as Playback → Playback engine. In the player, the engine menu still switches per session. Nothing here reaches Continue Watching or Trakt.") {
            PickerRow(label: "Playback engine", options: EnginePreference.allCases.filter { $0 != .external },
                      selection: $player.value.engine, title: \.label)
        }
        SettingsGroup(header: "Custom URL",
                      footer: "Any direct http(s) link: your own DV Profile 7 FEL, HDR10+ or DTS:X file, a NAS share over HTTP, an HLS/DASH manifest.") {
            TextEntryRow(label: "Stream URL", text: $customURL, placeholder: "https://…/sample.mkv", keyboard: .URL)
            if !customURL.isEmpty {
                SettingsRow(label: "Play custom URL", icon: "play.fill") {
                    TestStreamCatalog.play(TestStreamCatalog.request(customURL: customURL))
                }
            }
        }
        ForEach(TestStreamCatalog.categories) { category in
            SettingsGroup(header: category.title, footer: category.subtitle) {
                ForEach(category.items) { item in
                    SettingsRow(label: item.title, detail: "\(item.tag) · \(item.detail)", value: item.size, icon: category.icon) {
                        TestStreamCatalog.play(TestStreamCatalog.request(for: item))
                    }
                }
            }
        }
        Text("Sources: Apple HLS examples, Jellyfin test videos (CC BY-SA 4.0), samples.ffmpeg.org. Large files stream progressively — a 4K sample needs a fast connection.")
            .textStyle(.caption, color: Palette.textSecondary)
    }
}
