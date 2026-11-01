import Foundation

/// The JSON snapshot the app writes into the App Group for the Top Shelf
/// extension (Continue Watching on the tvOS home screen).
struct TopShelfSnapshot: Codable {
    struct Item: Codable, Hashable {
        var id: String
        var title: String
        var subtitle: String?
        var imageURL: String?
        var progress: Double
        /// Deep link back into the app (install-unique scheme).
        var playURL: String
        var displayURL: String
    }
    var items: [Item]
    var updatedAt: Date

    static var fileURL: URL? {
        AppGroup.containerURL?
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("topshelf-\(AppGroup.owningBundleID).json")
    }

    static func load() -> TopShelfSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}
