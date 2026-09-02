import SwiftUI

// Shared hold-Select (long-press) context menus for poster / continue-watching
// cards, used by every theme so hold-down behaves the same everywhere. Built as
// direct ViewModifiers that read their own stores from the environment, so they
// drop onto any card without threading dependencies.
//
// NOTE on the Apple TV ("Modern") theme: the system `CardButtonStyle` (its
// parallax platter) swallows `.contextMenu`, so cards that need a working hold
// menu there use the flat card style instead (see `mediaCardButtonStyle`). The
// parallax stays on the browse cards; only the Continue Watching row opts out.

// MARK: - Poster hold menu (Details / Library / Watched)

struct PosterHoldMenu: ViewModifier {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    let item: MetaItem
    let onDetails: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button { library.toggle(item) } label: {
                Label(library.contains(item) ? "Remove from Library" : "Add to Library",
                      systemImage: library.contains(item) ? "bookmark.slash" : "bookmark")
            }
            Button { watched.toggleMovie(item) } label: {
                Label(watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                      systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle")
            }
        }
    }
}

extension View {
    /// Standard poster hold-Select menu (Details / Library / Watched).
    func posterHoldMenu(_ item: MetaItem, onDetails: @escaping () -> Void) -> some View {
        modifier(PosterHoldMenu(item: item, onDetails: onDetails))
    }

    /// Optional-item variant — no-ops when a card has no resolved `MetaItem`
    /// (some theme cards only carry a lightweight title until selected).
    @ViewBuilder
    func posterHoldMenu(ifAvailable item: MetaItem?, onDetails: @escaping () -> Void) -> some View {
        if let item { posterHoldMenu(item, onDetails: onDetails) } else { self }
    }
}

// MARK: - Shared watched badge

/// A small "watched" tick shown on a movie poster once it's been marked watched,
/// so every theme surfaces watched state consistently. Series aren't badged at
/// the card level (their episodes carry watched state individually).
struct WatchedTickBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.green))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(10)
    }
}

private struct WatchedBadgeModifier: ViewModifier {
    @EnvironmentObject private var watched: WatchedStore
    let item: MetaItem?
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            if let item, !item.isSeries, watched.isWatched(item) { WatchedTickBadge() }
        }
    }
}

extension View {
    /// Overlays a watched tick on a movie card when it's been marked watched.
    func watchedBadge(_ item: MetaItem?, alignment: Alignment = .topTrailing) -> some View {
        modifier(WatchedBadgeModifier(item: item, alignment: alignment))
    }
}

// MARK: - Continue Watching hold menu (Details / Play Manually / Restart / Remove)

struct ContinueHoldMenu: ViewModifier {
    @EnvironmentObject private var progressStore: ProgressStore
    let progress: WatchProgress
    let onDetails: () -> Void
    let onPlayManually: () -> Void
    let onResumeFromStart: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button { onPlayManually() } label: { Label("Play Manually", systemImage: "list.and.film") }
            Button { onResumeFromStart() } label: { Label("Start from Beginning", systemImage: "gobackward") }
            Button(role: .destructive) {
                // Remove the whole show (all episodes), like Netflix/Hulu.
                progressStore.removeShow(metaID: progress.metaID, notifyTrakt: true)
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark")
            }
        }
    }
}

extension View {
    /// Continue-Watching hold-Select menu, shared across every theme.
    func continueHoldMenu(_ progress: WatchProgress,
                          onDetails: @escaping () -> Void,
                          onPlayManually: @escaping () -> Void,
                          onResumeFromStart: @escaping () -> Void) -> some View {
        modifier(ContinueHoldMenu(progress: progress, onDetails: onDetails,
                                  onPlayManually: onPlayManually,
                                  onResumeFromStart: onResumeFromStart))
    }
}
