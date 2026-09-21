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
            // tvOS only evaluates this closure when it is about to PRESENT the
            // menu, so reaching this line proves the hold was accepted.
            let _ = HoldProbe.log("MENU BUILT — poster \(item.name)")
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            Button { library.toggle(item) } label: {
                Label(library.contains(item) ? "Remove from Library" : "Add to Library",
                      systemImage: library.contains(item) ? "bookmark.slash" : "bookmark")
            }
            // Movies only. `WatchedStore.isWatched(_ meta:)` is hard-false for a
            // series, so on a show poster this read "Mark as Watched" forever,
            // never showed the tick, and wrote a show-level record nothing
            // reads — a dead toggle. Series watched state lives per episode.
            if !item.isSeries {
                Button { watched.toggleMovie(item) } label: {
                    Label(watched.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                          systemImage: watched.isWatched(item) ? "eye.slash" : "checkmark.circle")
                }
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

// MARK: - Live TV channel hold menu (Favourite / Add to Home)

/// Hold-Select on a Live TV channel: favourite it, and once it IS a favourite,
/// pin it to the home screen as well. Two steps on purpose — "Add to Home"
/// only appears on a channel you have already said you care about, which is
/// what keeps the home row short.
struct ChannelHoldMenu: ViewModifier {
    @ObservedObject private var favorites = LiveChannelFavorites.shared
    let channel: FavoriteChannel

    func body(content: Content) -> some View {
        content.contextMenu {
            let _ = HoldProbe.log("MENU BUILT — channel \(channel.name)")
            let isFavorite = favorites.isFavorite(channel.id)
            Button { favorites.toggleFavorite(channel) } label: {
                Label(isFavorite ? "Remove from Favorites" : "Favorite",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            // NO `role: .destructive` anywhere in here — tvOS refuses to
            // present a context menu that contains one (see ContinueHoldMenu).
            if isFavorite {
                Button { favorites.toggleOnHome(channel) } label: {
                    Label(favorites.isOnHome(channel.id) ? "Remove from Home Page" : "Add to Home Page",
                          systemImage: favorites.isOnHome(channel.id) ? "house.slash" : "house")
                }
            }
        }
    }
}

extension View {
    /// Live TV channel hold-Select menu (Favorite / Add to Home Page).
    func channelHoldMenu(_ channel: FavoriteChannel) -> some View {
        modifier(ChannelHoldMenu(channel: channel))
    }
}

// MARK: - Continue Watching hold menu (Details / Play Manually / Restart / Remove)

struct ContinueHoldMenu: ViewModifier {
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var watched: WatchedStore
    let progress: WatchProgress
    let onDetails: () -> Void
    let onPlayManually: () -> Void
    let onResumeFromStart: () -> Void

    /// True for a series row, whatever type spelling a sync source used.
    private var isSeriesType: Bool {
        ["series", "tv", "show", "tvshow", "anime"].contains(progress.type.lowercased())
    }

    /// The (season, episode) this row is for, from the stored columns or — when
    /// a sync source dropped them — from a row key shaped "…:<season>:<episode>"
    /// (e.g. "tt0903747:5:6"). Only the two trailing components AFTER the show
    /// id are trusted, so an exotic "kitsu:1234:5" show id is not mistaken for
    /// season 1234.
    private var episodeCoordinates: (season: Int, episode: Int)? {
        if let season = progress.season, let episode = progress.episode {
            return (season, episode)
        }
        let prefix = progress.metaID + ":"
        guard progress.id.hasPrefix(prefix) else { return nil }
        let tail = progress.id.dropFirst(prefix.count).split(separator: ":")
        guard tail.count == 2, let season = Int(tail[0]), let episode = Int(tail[1]) else {
            return nil
        }
        return (season, episode)
    }

    /// A Continue Watching card for one specific episode (as opposed to a
    /// movie). Only episodes get the manual "Mark Episode Watched" action.
    private var isEpisode: Bool { isSeriesType && episodeCoordinates != nil }

    func body(content: Content) -> some View {
        content.contextMenu {
            let _ = HoldProbe.log("MENU BUILT — CW \(progress.name)")
            Button { onPlayManually() } label: { Label("Play Manually", systemImage: "list.and.film") }
            Button { onDetails() } label: { Label("Go to Details", systemImage: "info.circle") }
            if isEpisode {
                Button { markEpisodeWatched() } label: {
                    Label("Mark Episode Watched", systemImage: "checkmark.circle")
                }
            }
            Button { onResumeFromStart() } label: { Label("Start Over", systemImage: "gobackward") }
            // NO `role: .destructive` — tvOS will not present a context menu
            // that contains one, so this single item silently killed the whole
            // Continue Watching menu while the role-free poster menu worked.
            // The wording and the ✗ glyph carry the meaning instead.
            Button {
                // Remove the whole show (all episodes), like Netflix/Hulu.
                progressStore.removeShow(metaID: progress.metaID, notifyTrakt: true)
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark")
            }
        }
    }

    /// Mark ONLY this episode watched through the same progress/watch-history
    /// path the player uses when an episode finishes: the progress row is
    /// retired (so Continue Watching stops offering it) and the episode is
    /// recorded in watch history, which lets Home's existing Next Up logic
    /// advance the card to the following episode. Every other episode's resume
    /// position is untouched, and no season/series mark is written.
    private func markEpisodeWatched() {
        guard let (season, episode) = episodeCoordinates else { return }
        let meta = MetaItem(
            id: progress.metaID,
            type: "series",
            name: progress.name,
            poster: progress.poster,
            background: progress.background,
            logo: progress.logo
        )
        let video = MetaVideo(
            id: progress.id,
            title: progress.episodeTitle ?? progress.name,
            season: season,
            episode: episode,
            thumbnail: progress.episodeThumbnail
        )
        // Record the watch FIRST, as a user action (not `fromPlayback`). The
        // player's `onFinished` marks the same key with `fromPlayback: true`,
        // which flags it as "already reported by the stop scrobble" and makes
        // the Trakt push SKIP the history add — correct for a finished
        // playback, wrong for a manual mark that has no scrobble behind it.
        // Doing it here, before `markFinished` can set that flag, sends the
        // watched state to Trakt/SIMKL immediately. `mark` is idempotent.
        if !watched.isWatched(contentID: progress.metaID, season: season, episode: episode) {
            watched.mark(meta: meta, video: video)
        }
        // `markFinished` then retires the progress row and clears the account /
        // Stremio resume point, through the same path in-app playback uses.
        progressStore.markFinished(meta: meta, video: video)
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
