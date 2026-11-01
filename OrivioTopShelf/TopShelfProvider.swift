import TVServices

/// Continue Watching on the tvOS home screen, read from the snapshot the app
/// writes into the App Group. PIN-locked profiles are excluded by the app
/// before it writes.
final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let snapshot = TopShelfSnapshot.load(), !snapshot.items.isEmpty else { return nil }
        let items: [TVTopShelfSectionedItem] = snapshot.items.prefix(20).map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title
            item.imageShape = .hdtv
            if let s = entry.imageURL, let url = URL(string: s) {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }
            item.playbackProgress = max(0, min(1, entry.progress))
            if let play = URL(string: entry.playURL) { item.playAction = TVTopShelfAction(url: play) }
            if let display = URL(string: entry.displayURL) { item.displayAction = TVTopShelfAction(url: display) }
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
