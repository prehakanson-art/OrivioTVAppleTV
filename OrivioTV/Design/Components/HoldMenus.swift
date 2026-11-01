import SwiftUI

/// A `.contextMenu` that rebuilds only when `key` changes. If the view
/// carrying it re-renders while the menu is open, tvOS reloads its rows under
/// the viewer and the focus highlight flickers. `key` must cover everything the
/// menu shows and every value its actions capture.
struct StableContextMenu<Content: View, MenuItems: View>: View, Equatable {
    let content: Content
    let key: String
    @ViewBuilder let menuItems: () -> MenuItems

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        content.contextMenu(menuItems: menuItems)
    }
}

/// Poster card: Go to Details · Add to / Remove from Library · Mark as Watched / Unwatched (movies).
struct PosterHoldMenu: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var toasts: ToastCenter
    let meta: MetaItem
    let onDetails: () -> Void

    func body(content: Content) -> some View {
        let inLibrary = library.contains(meta.id)
        let isWatched = !meta.isSeries && watched.isWatched(meta.id)
        StableContextMenu(content: content, key: "\(meta.id)|\(inLibrary)|\(isWatched)") {
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button {
                let added = library.toggle(meta)
                toasts.show(added ? "Added to Library" : "Removed from Library", systemImage: added ? "plus.circle.fill" : "minus.circle.fill")
            } label: {
                Label(inLibrary ? "Remove from Library" : "Add to Library", systemImage: inLibrary ? "minus" : "plus")
            }
            if !meta.isSeries {
                Button {
                    if isWatched { watched.markUnwatched(meta: meta) } else { watched.markWatched(meta: meta) }
                    toasts.show(isWatched ? "Marked as Unwatched" : "Marked as Watched", systemImage: "eye")
                } label: {
                    Label(isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: isWatched ? "eye.slash" : "eye")
                }
            }
        }
    }
}

/// Continue Watching card: Play Manually · Go to Details · Mark Episode Watched · Start Over · Remove.
struct ContinueWatchingHoldMenu: ViewModifier {
    @EnvironmentObject private var progress: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var toasts: ToastCenter
    let item: ContinueWatchingItem
    let onPlayManually: () -> Void
    let onDetails: () -> Void
    let onStartOver: () -> Void

    func body(content: Content) -> some View {
        StableContextMenu(content: content, key: "\(item.id)|\(item.video?.id ?? "")") {
            Button { onPlayManually() } label: { Label("Play Manually", systemImage: "list.bullet") }
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            if let v = item.video {
                Button {
                    watched.markWatched(meta: item.meta, video: v)
                    if let p = item.progress { progress.clear(p.id) }
                    toasts.show("Marked \(v.seasonEpisodeCode) as Watched", systemImage: "eye")
                } label: { Label("Mark Episode Watched", systemImage: "eye") }
            }
            if item.progress != nil {
                Button { onStartOver() } label: { Label("Start Over", systemImage: "gobackward") }
            }
            Button(role: .destructive) {
                progress.removeFromContinueWatching(metaID: item.meta.id)
                toasts.show("Removed from Continue Watching", systemImage: "xmark.circle.fill")
            } label: { Label("Remove from Continue Watching", systemImage: "xmark") }
        }
    }
}

extension View {
    func posterHoldMenu(_ meta: MetaItem, onDetails: @escaping () -> Void) -> some View {
        modifier(PosterHoldMenu(meta: meta, onDetails: onDetails))
    }
}
