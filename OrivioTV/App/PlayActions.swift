import SwiftUI

/// Entry points shared by every screen: open Detail, go to Sources, resume.
@MainActor
struct PlayActions {
    let router: Router

    func openDetail(_ meta: MetaItem, siblings: [MetaItem] = []) {
        if openMediaServerItem(meta) { return }
        router.push(.detail(meta, siblings: siblings))
    }

    /// Plex / Jellyfin items have no add-on meta: shows open their episode list,
    /// movies play straight from the server.
    private func openMediaServerItem(_ meta: MetaItem, fromStart: Bool = false) -> Bool {
        guard let kind = MediaServerKind.kind(ofMetaID: meta.id) else { return false }
        let serverID = String(meta.id.dropFirst(kind.idPrefix.count))
        if meta.isSeries {
            router.push(.mediaServerShow(serverID: kind.rawValue, itemID: serverID, title: meta.name))
        } else {
            Task { await MediaServerPlayback.resume(meta: meta, video: nil, fromStart: fromStart) }
        }
        return true
    }

    /// Play/Pause on a card → straight to the source list ("Play Manually").
    func playManually(_ meta: MetaItem, video: MetaVideo? = nil) {
        if video == nil, openMediaServerItem(meta) { return }
        router.push(.streams(StreamsRequest(meta: meta, video: video, mode: .manual)))
    }

    func play(_ meta: MetaItem, video: MetaVideo?, mode: StreamsMode = .normal) {
        router.push(.streams(StreamsRequest(meta: meta, video: video, mode: mode)))
    }

    /// Continue Watching resume: re-scrape, auto-play the matching link.
    func resume(_ item: ContinueWatchingItem, fromStart: Bool = false) {
        if MediaServerKind.kind(ofMetaID: item.meta.id) != nil {
            Task { await MediaServerPlayback.resume(meta: item.meta, video: item.video, fromStart: fromStart) }
            return
        }
        router.push(.streams(StreamsRequest(meta: item.meta, video: item.video, mode: item.progress == nil ? .normal : .resume(fromStart: fromStart))))
    }
}

private struct PlayActionsKey: EnvironmentKey {
    static let defaultValue: PlayActions? = nil
}

extension View {
    /// Play/Pause on a focused card.
    func onPlayPause(_ action: @escaping () -> Void) -> some View {
        onPlayPauseCommand(perform: action)
    }
}
