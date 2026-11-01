import Foundation

/// Per-title memory: audio sync, playback speed, the audio/subtitle language picked.
struct TitleMemory: Codable {
    var audioSync: Double = 0
    var speed: Float = 1
    var audioLanguage: String?
    var subtitleLanguage: String?
    var updatedAt = Date()
}

@MainActor
enum PlaybackMemory {
    private static let key = Persistence.key("player.titleMemory.v1")
    private static var store: [String: TitleMemory] = Persistence.load([String: TitleMemory].self, key: key) ?? [:]

    static func get(_ titleID: String) -> TitleMemory { store[titleID] ?? TitleMemory() }

    static func update(_ titleID: String, _ mutate: (inout TitleMemory) -> Void) {
        var m = get(titleID)
        mutate(&m)
        m.updatedAt = Date()
        store[titleID] = m
        if store.count > 400 {
            let keep = store.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(300)
            store = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        Persistence.save(store, key: key)
    }
}

/// Remembers per title that a play *saw* HEVC + multichannel Dolby (so the next
/// play takes the passthrough engine with no hint), and remembers negatives
/// (one probe per title, ever).
@MainActor
enum DolbyMemory {
    private static let yesKey = Persistence.key("player.dolbyCapableTitles.v1")
    private static let noKey = Persistence.key("player.dolbyDeclinedTitles.v2")
    private static var yes = Set(Persistence.load([String].self, key: yesKey) ?? [])
    private static var no = Set(Persistence.load([String].self, key: noKey) ?? [])

    static func isCapable(_ id: String) -> Bool { yes.contains(id) }
    static func isDeclined(_ id: String) -> Bool { no.contains(id) }

    static func markCapable(_ id: String) {
        guard yes.insert(id).inserted else { return }
        no.remove(id)
        Persistence.save(Array(yes.suffix(2000)), key: yesKey)
        Persistence.save(Array(no), key: noKey)
    }

    static func markDeclined(_ id: String) {
        guard !yes.contains(id), no.insert(id).inserted else { return }
        Persistence.save(Array(no.suffix(2000)), key: noKey)
    }
}

/// Audio Sync steps: −2 s … +2 s.
enum AudioSync {
    static let steps: [Double] = [-2, -1, -0.5, -0.25, -0.1, -0.05, 0, 0.05, 0.1, 0.25, 0.5, 1, 2]

    static func label(_ v: Double) -> String {
        if v == 0 { return "Off" }
        let ms = Int(abs(v) * 1000)
        return v > 0 ? "Voices +\(ms) ms later" : "Voices \(ms) ms earlier"
    }
}

enum PlaybackSpeed {
    static let steps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func label(_ v: Float) -> String { v == 1 ? "Normal" : String(format: "%g×", v) }
}

enum AspectChoice: String, CaseIterable, Identifiable {
    case auto, sdtv, hdtv1610, hdtv169, wideA, wideB, anaA, anaB, anaC, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .sdtv: return "SDTV 4:3"
        case .hdtv1610: return "HDTV 16:10"
        case .hdtv169: return "HDTV 16:9"
        case .wideA: return "Widescreen A 1.85"
        case .wideB: return "Widescreen B 2.00"
        case .anaA: return "Anamorphic A 2.35"
        case .anaB: return "Anamorphic B 2.39"
        case .anaC: return "Anamorphic C 2.40"
        case .ultra: return "Ultra-Widescreen 36:10"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .sdtv: return 4.0 / 3
        case .hdtv1610: return 16.0 / 10
        case .hdtv169: return 16.0 / 9
        case .wideA: return 1.85
        case .wideB: return 2.0
        case .anaA: return 2.35
        case .anaB: return 2.39
        case .anaC: return 2.40
        case .ultra: return 3.6
        }
    }
}

enum VerticalShift: String, CaseIterable, Identifiable {
    case none, up, down
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
