import SwiftUI

// Hulu theme — browse screens ported from HuluTV, driven by Orivio data. Cards
// select into Orivio's DetailView; the hero PLAY routes to the stream picker and
// DETAILS to the detail page (wired in HuluRootView). Genres/hub rows/collections
// are all real Orivio data.

private let side: CGFloat = HuluStyle.side

// MARK: - Home

struct HuluHomeView: View {
    let featured: [HuluTitle]
    let continueItems: [HuluTitle]
    let rows: [HuluRail]
    var onSelect: (HuluTitle) -> Void
    var onPlay: (HuluTitle) -> Void
    var onResume: (HuluTitle) -> Void
    var playFocus: FocusState<Bool>.Binding? = nil
    var onBackAtRoot: () -> Void = {}

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // LAZY: these rows are built per collection/catalog and each
            // instantiates its own horizontal strip of cards. Eager, the whole
            // screen's artwork was constructed before the first frame — the
            // cost that made these themes crawl on the older boxes.
            LazyVStack(alignment: .leading, spacing: 34) {
                HuluFeaturedHero(items: featured.isEmpty ? [.placeholder] : featured,
                                 onPlay: onPlay, onDetails: onSelect, playFocus: playFocus)
                    .padding(.bottom, 6)

                if !continueItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CONTINUE WATCHING").font(HuluStyle.title(26)).foregroundStyle(.white)
                            .padding(.leading, side)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 26) {
                                ForEach(continueItems) { cw in
                                    HuluProgressCard(title: cw, label: "Continue Watching",
                                                     subtitle: [cw.episodeLine.isEmpty ? cw.name : cw.episodeLine, cw.remainingText]
                                                        .compactMap { $0 }
                                                        .joined(separator: " · "),
                                                     progress: cw.progress ?? 0.35) { onResume(cw) }
                                }
                            }
                            .padding(.horizontal, side)
                        }
                        .scrollClipDisabled()
                    }
                }

                ForEach(rows) { rail in
                    HuluContentRail(rail: rail, onSelect: onSelect, onBackAtStart: onBackAtRoot)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
    }
}

// MARK: - Hub (TV / Movies)

struct HuluHubView: View {
    let featured: [HuluTitle]
    let genres: [String]
    let rows: [HuluRail]
    let series: Bool
    var onSelect: (HuluTitle) -> Void
    var onPlay: (HuluTitle) -> Void
    var onCategory: (String) -> Void
    var playFocus: FocusState<Bool>.Binding? = nil
    var onBackAtRoot: () -> Void = {}

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 34) {
                HuluFeaturedHero(items: featured.isEmpty ? [.placeholder] : featured,
                                 onPlay: onPlay, onDetails: onSelect, playFocus: playFocus)

                if !genres.isEmpty {
                    HuluGenreButtons(genres: genres, onSelect: onCategory)
                }

                ForEach(rows) { rail in
                    HuluContentRail(rail: rail, onSelect: onSelect, onBackAtStart: onBackAtRoot)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
    }
}

// MARK: - Hubs (the user's collections, as rows)

struct HuluHubsView: View {
    let collections: [NuvioCollection]
    var onOpenCollection: (NuvioCollection) -> Void
    var onOpenFolder: (NuvioCollectionFolder, NuvioCollection) -> Void
    @FocusState private var first: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // LAZY: these rows are built per collection/catalog and each
            // instantiates its own horizontal strip of cards. Eager, the whole
            // screen's artwork was constructed before the first frame — the
            // cost that made these themes crawl on the older boxes.
            LazyVStack(alignment: .leading, spacing: 40) {
                Text("HUBS").font(HuluStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 40)

                if collections.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 64)).foregroundStyle(HuluStyle.textTertiary)
                        Text("Your categories will show up here").font(HuluStyle.regular(28)).foregroundStyle(HuluStyle.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 140)
                } else {
                    ForEach(collections) { c in
                        CollectionRowSection(
                            collection: c, title: c.title,
                            onOpenFolder: { onOpenFolder($0, c) },
                            onOpenCollection: { onOpenCollection(c) }
                        )
                        .padding(.leading, side - NuvioSpacing.huge)
                    }
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        .huluPullFocusOnAppear($first)
    }
}

// MARK: - My Stuff (Orivio library)

struct HuluMyStuffView: View {
    let items: [HuluTitle]
    var onSelect: (HuluTitle) -> Void
    @State private var tab = "TV"
    private let tabs = ["TV", "MOVIES"]
    @FocusState private var firstTab: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 3)

    private var shown: [HuluTitle] {
        tab == "MOVIES" ? items.filter { !$0.isSeries } : items.filter { $0.isSeries }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { idx, t in
                        HuluTab(text: t, selected: tab == t,
                                focus: idx == 0 ? $firstTab : nil) { tab = t }
                    }
                }
                .padding(.leading, side).padding(.top, 40)

                if shown.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.square").font(.system(size: 64)).foregroundStyle(HuluStyle.textTertiary)
                        Text("Titles you add to your library show up here").font(HuluStyle.regular(28)).foregroundStyle(HuluStyle.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(shown) { t in
                            HuluProgressCard(title: t, label: t.isSeries ? "Watch Now" : "Play",
                                             subtitle: t.name, progress: t.progress ?? 0, width: 480) { onSelect(t) }
                        }
                    }
                    .padding(.horizontal, side)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        .huluPullFocusOnAppear($firstTab)
    }
}

private struct HuluTab: View {
    let text: String
    let selected: Bool
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 26, weight: .bold))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white : .clear))
                .huluFocusRing(focused && !selected, cornerRadius: 8, lineWidth: 3)
        }
        .buttonStyle(.huluFlat)
        .focused($focused)
        .huluExternalFocus(focus)
    }
}

// MARK: - Genre grid (paginated, full genre catalog from Orivio TMDB)

struct HuluGenreGrid: View {
    let genre: String
    let series: Bool?
    var onSelect: (HuluTitle) -> Void
    var firstCard: FocusState<Bool>.Binding? = nil

    @State private var items: [HuluTitle] = []
    @State private var page = 0
    @State private var loading = false
    @State private var done = false
    @State private var seen = Set<String>()
    @State private var loadToken = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 6)

    var body: some View {
        Group {
            if items.isEmpty && loading {
                HStack { Spacer(); ProgressView().tint(.white).scaleEffect(1.5); Spacer() }.padding(.top, 120)
            } else if items.isEmpty {
                Text("Nothing here yet.").font(HuluStyle.regular(26)).foregroundStyle(HuluStyle.textTertiary).padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                        HuluPosterCard(title: t, width: 210, focus: idx == 0 ? firstCard : nil) { onSelect(t) }
                            .onAppear { if idx >= items.count - 12 { Task { await loadMore() } } }
                    }
                }
                if loading { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 24) }
            }
        }
        .task(id: genre) {
            loadToken += 1; items = []; page = 0; done = false; seen = []; loading = false
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loading, !done else { return }
        loading = true
        let token = loadToken
        let next = page + 1
        var batch: [MetaItem] = []
        if series != true, TMDBService.hasMovieGenre(genre) {
            batch += await TMDBService.titlesByGenre(name: genre, isMovie: true, page: next)
        }
        if series != false, TMDBService.hasTVGenre(genre) {
            batch += await TMDBService.titlesByGenre(name: genre, isMovie: false, page: next)
        }
        guard token == loadToken else { return }
        page = next
        let fresh = batch.filter { seen.insert($0.id).inserted }
        if fresh.isEmpty || next >= 20 { done = true }
        items += fresh.map(HuluTitle.init)
        loading = false
    }
}

/// The pushed genre page (from a genre button). Big title + paginated grid.
struct HuluCategoryListView: View {
    let name: String
    var series: Bool? = nil
    var onSelect: (HuluTitle) -> Void
    @FocusState private var firstCard: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                Text(name).font(HuluStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 60)
                HuluGenreGrid(genre: name, series: series, onSelect: onSelect, firstCard: $firstCard)
                    .padding(.horizontal, side)
                Color.clear.frame(height: 40)
            }
        }
        .background(HuluStyle.background)
        .ignoresSafeArea(edges: [.top, .trailing])
        .huluPullFocusOnAppear($firstCard)
    }
}

/// News section — a titled paginated grid of a documentary/news-leaning genre
/// (Orivio has no dedicated News feed, so this is the closest real data).
struct HuluNewsView: View {
    var onSelect: (HuluTitle) -> Void
    var onBackAtRoot: () -> Void = {}
    @FocusState private var firstCard: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                Text("News & Documentaries").font(HuluStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 60)
                HuluGenreGrid(genre: "Documentary", series: nil, onSelect: onSelect, firstCard: $firstCard)
                    .padding(.horizontal, side)
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        .huluPullFocusOnAppear($firstCard)
        // Back goes to the TOP first (focus the first card, which scrolls up);
        // only Back from the top opens the side menu.
        .onExitCommand {
            if firstCard { onBackAtRoot() } else { firstCard = true }
        }
    }
}

// MARK: - Search (ported keyboard + result list, Orivio results)

struct HuluSearchView: View {
    let suggestions: [HuluTitle]
    @ObservedObject var searchViewModel: SearchViewModel
    let addonManager: AddonManager
    var onSelect: (HuluTitle) -> Void
    @FocusState private var firstKey: Bool

    private var results: [HuluTitle] { searchViewModel.results.map(HuluTitle.init) }
    private var query: String { searchViewModel.query }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass").font(.system(size: 40))
                Text(query.isEmpty ? "Search" : query)
                    .font(HuluStyle.hero(44))
                    .foregroundStyle(query.isEmpty ? HuluStyle.textTertiary : .white)
            }
            .padding(.top, 40)

            HStack(alignment: .top, spacing: 70) {
                HuluKeyboard(firstKey: $firstKey, onKey: append, onSpace: { append(" ") },
                             onDelete: deleteLast, onClear: clear)
                    .frame(width: 520)

                VStack(alignment: .leading, spacing: 0) {
                    let shown = (results.isEmpty && query.isEmpty) ? suggestions : results
                    if !query.isEmpty {
                        Text("TOP RESULTS (\(shown.count))")
                            .font(HuluStyle.semibold(22)).foregroundStyle(.white).padding(.bottom, 18)
                        Divider().overlay(HuluStyle.textFaint)
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(shown) { t in HuluSearchRow(title: t) { onSelect(t) } }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.trailing, 60)
            }
        }
        .padding(.leading, 130)
        .huluPullFocusOnAppear($firstKey)
    }

    private func append(_ s: String) { searchViewModel.query += s; run() }
    private func deleteLast() { if !searchViewModel.query.isEmpty { searchViewModel.query.removeLast(); run() } }
    private func clear() { searchViewModel.query = ""; searchViewModel.results = [] }
    private func run() { searchViewModel.search(addonManager: addonManager) }
}

private struct HuluSearchRow: View {
    let title: HuluTitle
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 28) {
                RemoteImage(url: title.cardURL, maxDimension: 300)
                    .frame(width: 300, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title.name).font(HuluStyle.title(30))
                    .foregroundStyle(focused ? .white : HuluStyle.textSecondary).lineLimit(1)
                Spacer()
            }
            .padding(12)
            .huluFocusRing(focused, cornerRadius: 12, lineWidth: 4)
        }
        .buttonStyle(.huluFlat)
        .focused($focused)
    }
}

private struct HuluKeyboard: View {
    var firstKey: FocusState<Bool>.Binding
    var onKey: (String) -> Void
    var onSpace: () -> Void
    var onDelete: () -> Void
    var onClear: () -> Void

    @State private var numeric = false
    private var letters: [String] {
        (numeric ? "1234567890" : "abcdefghijklmnopqrstuvwxyz").map { String($0) }
    }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 0) {
                HuluModeButton(text: "abc", active: !numeric) { numeric = false }
                HuluModeButton(text: "123", active: numeric) { numeric = true }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(HuluStyle.surface))

            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(Array(letters.enumerated()), id: \.element) { idx, l in
                    HuluKeyButton(label: l, focus: idx == 0 ? firstKey : nil) { onKey(l) }
                }
            }
            HStack(spacing: 20) {
                HuluActionKey(label: "SPACE") { onSpace() }
                HuluActionKey(systemImage: "delete.left") { onDelete() }
                HuluActionKey(label: "CLEAR") { onClear() }
            }
            .padding(.top, 6)
        }
    }
}

private struct HuluModeButton: View {
    let text: String; let active: Bool; let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(text).font(HuluStyle.semibold(24))
                .foregroundStyle(active ? .white : HuluStyle.textTertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 8).fill(focused ? HuluStyle.surfaceHi : .clear))
        }
        .buttonStyle(.huluFlat).focused($focused)
    }
}

private struct HuluKeyButton: View {
    let label: String
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 34, weight: .medium))
                .foregroundStyle(focused ? .black : .white)
                .frame(width: 66, height: 66)
                .background(Circle().fill(focused ? Color.white : .clear))
        }
        .buttonStyle(.huluFlat).focused($focused).huluExternalFocus(focus)
        .focusLift(1.1, focused)
    }
}

private struct HuluActionKey: View {
    var label: String? = nil
    var systemImage: String? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Group {
                if let label { Text(label).font(HuluStyle.semibold(22)) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: 26)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(focused ? HuluStyle.surfaceHi : HuluStyle.surface))
        }
        .buttonStyle(.huluFlat).focused($focused)
    }
}
