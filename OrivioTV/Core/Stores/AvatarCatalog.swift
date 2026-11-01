import SwiftUI

/// Profile pictures. A profile stores an avatar *id* from the account's
/// catalog (`get_avatar_catalog`: id → storage path + background colour), not
/// a file name — so the catalog is loaded from the account (and cached), as
/// the old app did. Without it every profile fell back to initials.
@MainActor
final class AvatarCatalog: ObservableObject {
    static let shared = AvatarCatalog()

    struct Item: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let imageURL: String
        let category: String
        let sortOrder: Int
        let bgColor: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    private var loadedThisLaunch = false
    private let cacheURL = Persistence.fileURL("avatar-catalog.json")

    private init() {
        items = Persistence.loadFile([Item].self, url: cacheURL) ?? []
    }

    private static var base: String {
        let b = Secrets.avatarPublicBaseURL
        return b.hasSuffix("/") ? String(b.dropLast()) : b
    }

    /// The picture for an avatar id: the catalog entry, a full URL, or a
    /// storage path (older profiles stored the path itself).
    func url(for id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if id.hasPrefix("http") { return id }
        if let item = items.first(where: { $0.id == id }) { return item.imageURL }
        guard !Self.base.isEmpty, id.contains("/") || id.contains(".") else { return nil }
        return Self.base + "/" + id
    }

    func item(_ id: String?) -> Item? { id.flatMap { id in items.first { $0.id == id } } }

    /// Once per launch, when signed in (cheap; the catalog rarely changes).
    func loadIfNeeded() async {
        guard !loadedThisLaunch, !loading, OrivioAccount.shared.isSignedIn, !Self.base.isEmpty else { return }
        loading = true
        defer { loading = false }
        guard let data = try? await OrivioAccount.shared.rpc("get_avatar_catalog", [:]),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let parsed: [Item] = rows.compactMap { r in
            guard let id = r["id"].map({ "\($0)" }), let path = r["storage_path"] as? String, !path.isEmpty else { return nil }
            let full = path.hasPrefix("http") ? path : Self.base + "/" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
            return Item(id: id, name: r["display_name"] as? String ?? "", imageURL: full,
                        category: r["category"] as? String ?? "", sortOrder: (r["sort_order"] as? Int) ?? 0,
                        bgColor: r["bg_color"] as? String)
        }
        guard !parsed.isEmpty else { return }
        items = parsed.sorted { ($0.category, $0.sortOrder) < ($1.category, $1.sortOrder) }
        loadedThisLaunch = true
        Persistence.saveFile(items, url: cacheURL)
    }
}
