import TVServices

/// Top Shelf: shows the app's Continue Watching row on the tvOS home screen
/// when OrivioTV sits in the dock's top row — the tvOS equivalent of Android
/// TV's "Watch Next" channel.
///
/// Data flows one way: the app exports a small JSON snapshot of the Continue
/// Watching list into the shared app-group container every time progress
/// changes (see TopShelfExporter); this extension just reads and renders it.
/// Selecting an item deep-links into the app via orivio://meta?type=…&id=…
/// (handled by DeepLinkService), which opens the title's detail page.
///
/// If the app group isn't available (e.g. a sideload signer that strips the
/// entitlement), the container URL is nil and the shelf simply stays empty —
/// the app itself is unaffected.
final class TopShelfProvider: TVTopShelfContentProvider {

    /// Mirror of TopShelfExporter.Entry — kept as its own tiny struct so the
    /// extension target doesn't need to compile any app sources.
    private struct Entry: Codable {
        let id: String
        let type: String
        let title: String
        let subtitle: String?
        let imageURL: String?
    }

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        completionHandler(Self.content())
    }

    private static func content() -> TVTopShelfContent? {
        // AppGroupResolver is shared with the app target (see project.yml) so
        // both sides resolve the SAME signer-assigned group at runtime.
        guard let dir = AppGroupResolver.containerURL else { return nil }
        let file = dir.appendingPathComponent("topshelf.json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              !entries.isEmpty
        else { return nil }

        let items = entries.map { entry -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.subtitle.map { "\(entry.title) — \($0)" } ?? entry.title
            item.imageShape = .hdtv   // 16:9, matching the in-app CW cards
            if let urlString = entry.imageURL, let url = URL(string: urlString) {
                item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
            }
            var comps = URLComponents()
            comps.scheme = "orivio"
            comps.host = "meta"
            comps.queryItems = [
                URLQueryItem(name: "type", value: entry.type),
                URLQueryItem(name: "id", value: entry.id)
            ]
            if let url = comps.url {
                item.displayAction = TVTopShelfAction(url: url)
                item.playAction = TVTopShelfAction(url: url)
            }
            return item
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
