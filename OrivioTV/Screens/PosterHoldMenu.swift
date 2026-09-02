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

// The old `.contextMenu`-based modifiers lived here. They are gone: on tvOS 26
// a context menu fails to present whenever any item carries a destructive role,
// and its failures are silent, which is what made hold-Select work on some
// cards and not others for so long. Every surface now uses `HoldableCard` /
// `HoldPressDetector` (see HoldMenu.swift) with the action lists at the bottom
// of this file.

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

// MARK: - Hold-menu action lists
//
// The menu CONTENT, shared by every surface. Cards present it through
// `HoldableCard`, which detects the held Select itself; `.contextMenu` is no
// longer used for these because it fails silently on tvOS 26 (see HoldMenu).

/// Poster menu: Details / Library / Watched.
@MainActor
func posterHoldActions(item: MetaItem,
                       library: LibraryStore,
                       watched: WatchedStore,
                       onDetails: @escaping () -> Void) -> [HoldAction] {
    [
        HoldAction(title: "Go to Details", systemImage: "info.circle", action: onDetails),
        HoldAction(title: library.contains(item) ? "Remove from Library" : "Add to Library",
                   systemImage: library.contains(item) ? "bookmark.slash" : "bookmark") {
            library.toggle(item)
        },
        HoldAction(title: watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                   systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle") {
            watched.toggleMovie(item)
        }
    ]
}

/// Continue Watching menu: Details / Play Manually / Restart / Remove.
@MainActor
func continueHoldActions(progress: WatchProgress,
                         progressStore: ProgressStore,
                         onDetails: @escaping () -> Void,
                         onPlayManually: @escaping () -> Void,
                         onResumeFromStart: @escaping () -> Void) -> [HoldAction] {
    [
        HoldAction(title: "Go to Details", systemImage: "info.circle", action: onDetails),
        HoldAction(title: "Play Manually", systemImage: "list.and.film", action: onPlayManually),
        HoldAction(title: "Start from Beginning", systemImage: "gobackward", action: onResumeFromStart),
        HoldAction(title: "Remove from Continue Watching",
                   systemImage: "xmark", isDestructive: true) {
            // Removes the whole show (all episodes), like Netflix/Hulu.
            progressStore.removeShow(metaID: progress.metaID, notifyTrakt: true)
        }
    ]
}
