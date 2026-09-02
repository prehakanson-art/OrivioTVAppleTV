import Foundation

struct OrivioSyncLogEntry: Codable, Identifiable, Hashable {
    enum Level: String, Codable {
        case info
        case success
        case warning
        case failure
    }

    let id: String
    let date: Date
    let level: Level
    let area: String
    let message: String

    init(date: Date = Date(), level: Level, area: String, message: String) {
        self.id = UUID().uuidString
        self.date = date
        self.level = level
        self.area = area
        self.message = message
    }

    var timeLabel: String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

enum OrivioSyncDiagnostics {
    private static let logKey = "orivio.sync.log.v1"
    private static let maxEntries = 80

    static func record(_ level: OrivioSyncLogEntry.Level, area: String, _ message: String) {
        var current = entries()
        current.insert(OrivioSyncLogEntry(level: level, area: area, message: message), at: 0)
        if current.count > maxEntries { current.removeLast(current.count - maxEntries) }
        save(current)
    }

    static func entries() -> [OrivioSyncLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: logKey),
              let decoded = try? JSONDecoder().decode([OrivioSyncLogEntry].self, from: data) else { return [] }
        return decoded
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: logKey)
    }

    private static func save(_ entries: [OrivioSyncLogEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: logKey)
    }
}
