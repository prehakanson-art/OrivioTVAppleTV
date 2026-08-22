import SwiftUI

// Max theme — the browse screens, ported from MaxTV (Home / Hub / Categories /
// Category list / Search / My Stuff). Layout, sizes, fonts and insets are
// MaxTV's 1:1; the content is Orivio's (passed in as `MaxTitle` pools by
// `MaxRootView`), so there is NO second backend. Genres are matched by name.

private let side: CGFloat = MaxStyle.side   // 130 — the shared "stopping point"

// MARK: - Home

struct MaxHomeView: View {
    let featured: [MaxTitle]
    let continueItems: [MaxTitle]
    let rows: [MaxRow]
    var onSelect: (MaxTitle) -> Void
    var defaultFocusNS: Namespace.ID? = nil
    var playFocus: FocusState<Bool>.Binding? = nil
    /// Back at the start of a row (or on the hero) opens the side menu.
    var onBackAtRoot: () -> Void = {}

    /// Focus target for the first row, so Down off the hero drops into content.
    @FocusState private var firstRow: Bool

    private var firstRowTitle: String? {
        if !continueItems.isEmpty { return "Continue Watching" }
        return rows.first?.title
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // LAZY: these rows are built per collection/catalog and each
            // instantiates its own horizontal strip of cards. Eager, the whole
            // screen's artwork was constructed before the first frame — the
            // cost that made these themes crawl on the older boxes.
            LazyVStack(alignment: .leading, spacing: 30) {
                MaxFeaturedHero(items: featured.isEmpty ? [.placeholder] : featured,
                                onPlay: onSelect,
                                defaultFocusNS: defaultFocusNS, playFocus: playFocus,
                                onDown: { firstRow = true })
                    .padding(.bottom, 6)

                if !continueItems.isEmpty {
                    MaxPosterRail(title: "Continue Watching", items: continueItems,
                                  onSelect: onSelect, firstCardFocus: $firstRow,
                                  onBackAtStart: onBackAtRoot)
                }
                ForEach(rows) { row in
                    MaxPosterRail(title: row.title, items: row.items, onSelect: onSelect,
                                  firstCardFocus: row.title == firstRowTitle && continueItems.isEmpty ? $firstRow : nil,
                                  onBackAtStart: onBackAtRoot)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        // Dev-only: focus the first row card so the reflow can be screenshotted.
        .onAppear {
            if ProcessInfo.processInfo.environment["MAX_FOCUS_CARD"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { firstRow = true }
            }
        }
    }
}

/// A titled group of titles (Orivio catalog row / genre rail). `id` is STABLE
/// (derived from the source row) — NOT a fresh UUID — so that recomputing the
/// rows on a parent re-render (e.g. opening/closing the sidebar) keeps the same
/// ForEach identities and doesn't tear down + rebuild every rail (which reset
/// scroll positions and reloaded artwork — the "page reloaded" bug).
struct MaxRow: Identifiable { let id: String; let title: String; let items: [MaxTitle] }

// MARK: - Hub (Series / Movies / HBO / Sports / Channels)

struct MaxHubView: View {
    let featured: [MaxTitle]
    let pool: [MaxTitle]
    let top10Kind: String
    /// true = a TV hub, false = a movies hub (drives the genre fetch media type).
    let series: Bool
    var onSelect: (MaxTitle) -> Void
    var playFocus: FocusState<Bool>.Binding? = nil
    var onBackAtRoot: () -> Void = {}

    @State private var genre: String = "Featured"
    @FocusState private var firstChip: Bool

    private var genres: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in pool { for g in t.genres where seen.insert(g).inserted { out.append(g) } }
        return out.sorted()
    }
    private var top10: [MaxTitle] { Array(pool.prefix(10)) }

    /// Genre rails: pool grouped by genre name, ≥4 items each (MaxTV's rule).
    private var genreRails: [MaxRow] {
        genres.prefix(8).compactMap { g in
            let items = pool.filter { $0.genres.contains(g) }
            guard items.count >= 4 else { return nil }
            return MaxRow(id: g, title: g, items: items)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                MaxFeaturedHero(items: featured.isEmpty ? [.placeholder] : featured,
                                onPlay: onSelect, playFocus: playFocus,
                                onDown: { firstChip = true })

                MaxGenreChips(genres: genres, selected: $genre, firstChipFocus: $firstChip)

                if genre == "Featured" {
                    if !top10.isEmpty { MaxTop10Row(kind: top10Kind, items: top10, onSelect: onSelect, onBackAtStart: onBackAtRoot) }
                    ForEach(genreRails) {
                        MaxPosterRail(title: $0.title, items: $0.items, onSelect: onSelect,
                                      onBackAtStart: onBackAtRoot)
                    }
                } else {
                    // Full, paginated genre catalog (keeps loading as you scroll).
                    MaxGenreGrid(genre: genre, series: series, onSelect: onSelect)
                        .padding(.horizontal, side)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        .onAppear {
            // Dev-only: preselect a genre chip for sim verification.
            if let g = ProcessInfo.processInfo.environment["MAX_GENRE"] { genre = g }
        }
    }
}

/// Horizontal genre filter chips — "Featured" plus the pool's genres.
struct MaxGenreChips: View {
    let genres: [String]
    @Binding var selected: String
    var firstChipFocus: FocusState<Bool>.Binding? = nil
    private var chips: [String] { ["Featured"] + genres }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 20) {
                ForEach(Array(chips.enumerated()), id: \.element) { idx, chip in
                    MaxChip(text: chip, selected: selected == chip,
                            focus: idx == 0 ? firstChipFocus : nil) { selected = chip }
                }
            }
            .padding(.horizontal, side)
            .padding(.vertical, 8)
        }
        // Treat the chip strip as one focus section so pressing Up from ANY chip
        // (not just the first) escapes upward to the hero, and Down enters the
        // rows below — instead of a geometric search that only the leftmost chip
        // could satisfy.
        .focusSection()
    }
}

private struct MaxChip: View {
    let text: String
    let selected: Bool
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(MaxStyle.semibold(26))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 30).padding(.vertical, 14)
                .background(Capsule().fill(selected ? Color.white : (focused ? Color.white.opacity(0.18) : .clear)))
                .overlay(Capsule().stroke(.white.opacity(focused && !selected ? 0.9 : 0), lineWidth: 2))
        }
        .buttonStyle(.maxFlat)
        .focused($focused)
        .maxExternalFocus(focus)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

// MARK: - Categories

struct MaxCategoriesView: View {
    /// (genre name, representative artwork url)
    let genres: [(name: String, image: String?)]
    /// The categories the user set up in their account (collections), each shown
    /// as its OWN ROW of that collection's folders/items.
    let collections: [NuvioCollection]
    var onOpenCategory: (String) -> Void
    var onOpenCollection: (NuvioCollection) -> Void
    var onOpenFolder: (NuvioCollectionFolder, NuvioCollection) -> Void
    @FocusState private var firstTile: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // LAZY: these rows are built per collection/catalog and each
            // instantiates its own horizontal strip of cards. Eager, the whole
            // screen's artwork was constructed before the first frame — the
            // cost that made these themes crawl on the older boxes.
            LazyVStack(alignment: .leading, spacing: 40) {
                Text("Categories")
                    .font(MaxStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 40)

                sectionTitle("Browse by Genre")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(Array(genres.enumerated()), id: \.element.name) { idx, g in
                            MaxGenreTile(name: g.name, image: g.image,
                                         focus: idx == 0 ? $firstTile : nil) { onOpenCategory(g.name) }
                        }
                    }
                    .padding(.horizontal, side).padding(.vertical, 8)
                }

                // Each saved collection (e.g. "Streaming Services", "Major
                // Studios") is its OWN row — the Orivio collection row, which
                // resolves and lays out its folders/items.
                ForEach(collections) { c in
                    CollectionRowSection(
                        collection: c, title: c.title,
                        onOpenFolder: { onOpenFolder($0, c) },
                        onOpenCollection: { onOpenCollection(c) }
                    )
                    .padding(.leading, side - NuvioSpacing.huge)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
        .maxPullFocusOnAppear($firstTile)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(MaxStyle.title(28)).foregroundStyle(.white).padding(.leading, side)
    }
}

private struct MaxGenreTile: View {
    let name: String
    let image: String?
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                RemoteImage(url: image, maxDimension: 300)
                    .frame(width: 300, height: 300)
                    .overlay(Color.black.opacity(0.35))
                Text(name.uppercased())
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 6)
                    .padding(12)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: focused ? 4 : 0))
        }
        .buttonStyle(.maxFlat)
        .focused($focused)
        .maxExternalFocus(focus)
        .focusLift(1.06, focused)
        .padding(.vertical, 14)
    }
}

/// The pushed "category" page: a big title and the FULL, paginated genre grid
/// (movies + TV), which keeps loading as you scroll.
struct MaxCategoryListView: View {
    let name: String
    var onSelect: (MaxTitle) -> Void
    @FocusState private var firstCard: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                Text(name)
                    .font(MaxStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 60)
                MaxGenreGrid(genre: name, series: nil, onSelect: onSelect, firstCard: $firstCard)
                    .padding(.horizontal, side)
                Color.clear.frame(height: 40)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: [.top, .trailing])
        .maxPullFocusOnAppear($firstCard)
    }
}

/// A 6-column poster grid, shared by hubs / categories.
struct MaxGrid: View {
    let items: [MaxTitle]
    var firstCard: FocusState<Bool>.Binding? = nil
    var onSelect: (MaxTitle) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 6)

    var body: some View {
        if items.isEmpty {
            Text("Nothing here yet.")
                .font(MaxStyle.regular(26)).foregroundStyle(MaxStyle.textTertiary)
                .padding(.top, 80)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                    MaxGridCard(title: t, focus: idx == 0 ? firstCard : nil) { onSelect(t) }
                }
            }
        }
    }
}

/// A genre grid that fetches the FULL genre catalog from Orivio's TMDB service
/// and keeps appending pages as you scroll — so a genre "keeps giving results
/// until you've gone through them all" instead of the ~one page the home pool
/// holds. `series`: true = TV only, false = movies only, nil = both.
struct MaxGenreGrid: View {
    let genre: String
    let series: Bool?
    var onSelect: (MaxTitle) -> Void
    var firstCard: FocusState<Bool>.Binding? = nil

    @State private var items: [MaxTitle] = []
    @State private var page = 0
    @State private var loading = false
    @State private var done = false
    @State private var seen = Set<String>()
    /// Bumped on every genre (re)load; an in-flight fetch whose token is stale
    /// (the genre changed mid-request) discards its results instead of mixing
    /// them into the new genre's grid.
    @State private var loadToken = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 6)

    var body: some View {
        Group {
            if items.isEmpty && loading {
                HStack { Spacer(); ProgressView().tint(.white).scaleEffect(1.4); Spacer() }
                    .padding(.top, 100)
            } else if items.isEmpty {
                Text("Nothing here yet.")
                    .font(MaxStyle.regular(26)).foregroundStyle(MaxStyle.textTertiary)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                        MaxGridCard(title: t, focus: idx == 0 ? firstCard : nil) { onSelect(t) }
                            // Prefetch the next page as the grid nears its end.
                            .onAppear { if idx >= items.count - 12 { Task { await loadMore() } } }
                    }
                }
                if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
        }
        .task(id: genre) {
            loadToken += 1
            items = []; page = 0; done = false; seen = []; loading = false
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
        // The genre changed while this page was in flight — drop these results.
        guard token == loadToken else { return }
        page = next
        let fresh = batch.filter { seen.insert($0.id).inserted }
        // Stop when a page returns nothing new, or after a generous page cap.
        if fresh.isEmpty || next >= 20 { done = true }
        items += fresh.map(MaxTitle.init)
        loading = false
    }
}

// MARK: - Search (ported keyboard, Orivio results)

struct MaxSearchView: View {
    let suggestions: [MaxTitle]
    @ObservedObject var searchViewModel: SearchViewModel
    let addonManager: AddonManager
    var onSelect: (MaxTitle) -> Void
    @FocusState private var firstKey: Bool

    // 4 columns: the results area (right of the 520pt keyboard) is too narrow for
    // 5 fixed-width posters, which made them overlap. 4 fits with breathing room.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 4)

    private var results: [MaxTitle] { searchViewModel.results.map(MaxTitle.init) }
    private var query: String { searchViewModel.query }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                HStack(spacing: 18) {
                    Image(systemName: "magnifyingglass").font(.system(size: 36))
                    Text(query.isEmpty ? "Find movies, shows, and more" : query)
                        .font(MaxStyle.hero(40))
                        .foregroundStyle(query.isEmpty ? MaxStyle.textTertiary : .white)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.top, 40).padding(.trailing, 60)

            HStack(alignment: .top, spacing: 60) {
                MaxKeyboard(firstKey: $firstKey, onKey: append, onSpace: { append(" ") },
                            onDelete: deleteLast, onClear: clear)
                    .frame(width: 520)

                ScrollView(.vertical, showsIndicators: false) {
                    let shown = (results.isEmpty && query.isEmpty) ? suggestions : results
                    VStack(alignment: .leading, spacing: 24) {
                        if !shown.isEmpty {
                            Text(query.isEmpty ? "For You" : "Results")
                                .font(MaxStyle.title(28)).foregroundStyle(.white)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(shown) { t in MaxGridCard(title: t) { onSelect(t) } }
                            }
                        } else if !query.isEmpty && !searchViewModel.isSearching {
                            Text("No results for “\(query)”")
                                .font(MaxStyle.regular(28)).foregroundStyle(MaxStyle.textTertiary)
                                .padding(.top, 60)
                        }
                    }
                    // Leading room so the first column's focus scale + white
                    // border isn't clipped against the scroll edge.
                    .padding(.leading, 16).padding(.trailing, 60)
                }
                // Don't clip the focus scale/border of the edge cards.
                .scrollClipDisabled()
            }
        }
        .padding(.leading, 150)
        .maxPullFocusOnAppear($firstKey)
    }

    private func append(_ s: String) { searchViewModel.query += s; run() }
    private func deleteLast() { if !searchViewModel.query.isEmpty { searchViewModel.query.removeLast(); run() } }
    private func clear() { searchViewModel.query = ""; searchViewModel.results = [] }
    private func run() { searchViewModel.search(addonManager: addonManager) }
}

/// tvOS on-screen keyboard grid matching the Max search layout.
private struct MaxKeyboard: View {
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
                MaxModeButton(text: "abc", active: !numeric) { numeric = false }
                MaxModeButton(text: "123", active: numeric) { numeric = true }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(MaxStyle.surface))

            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(Array(letters.enumerated()), id: \.element) { idx, l in
                    MaxKeyButton(label: l, focus: idx == 0 ? firstKey : nil) { onKey(l) }
                }
            }

            HStack(spacing: 20) {
                MaxActionKey(label: "SPACE") { onSpace() }
                MaxActionKey(systemImage: "delete.left") { onDelete() }
                MaxActionKey(label: "CLEAR") { onClear() }
            }
            .padding(.top, 6)
        }
    }
}

private struct MaxModeButton: View {
    let text: String; let active: Bool; let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(text).font(MaxStyle.semibold(24))
                .foregroundStyle(active ? .white : MaxStyle.textTertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 8).fill(focused ? MaxStyle.surfaceHi : .clear))
        }
        .buttonStyle(.maxFlat).focused($focused)
    }
}

private struct MaxKeyButton: View {
    let label: String
    var focus: FocusState<Bool>.Binding? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(focused ? .black : .white)
                .frame(width: 66, height: 66)
                .background(Circle().fill(focused ? Color.white : .clear))
        }
        .buttonStyle(.maxFlat).focused($focused).maxExternalFocus(focus)
        .focusLift(1.1, focused)
    }
}

private struct MaxActionKey: View {
    var label: String? = nil
    var systemImage: String? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Group {
                if let label { Text(label).font(MaxStyle.semibold(22)) }
                else if let systemImage { Image(systemName: systemImage).font(.system(size: 26)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(focused ? MaxStyle.surfaceHi : MaxStyle.surface))
        }
        .buttonStyle(.maxFlat).focused($focused)
    }
}

// MARK: - My Stuff

struct MaxMyStuffView: View {
    let items: [MaxTitle]
    var onSelect: (MaxTitle) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 6)

    private var movies: [MaxTitle] { items.filter { !$0.isSeries } }
    private var shows: [MaxTitle] { items.filter { $0.isSeries } }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                Text("My Stuff").font(MaxStyle.hero(52)).foregroundStyle(.white)
                    .padding(.leading, side).padding(.top, 40)

                if items.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "bookmark").font(.system(size: 70)).foregroundStyle(MaxStyle.textTertiary)
                        Text("Titles you add will show up here").font(MaxStyle.regular(30)).foregroundStyle(MaxStyle.textSecondary)
                        Text("Open any title and choose “Add to Library.”").font(MaxStyle.regular(24)).foregroundStyle(MaxStyle.textTertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 160)
                } else {
                    // Movies and shows in their own labelled sections.
                    section("Movies", movies)
                    section("Shows", shows)
                }
                Color.clear.frame(height: 40)
            }
        }
        .ignoresSafeArea(edges: [.top, .trailing])
    }

    @ViewBuilder private func section(_ title: String, _ list: [MaxTitle]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(MaxStyle.title(30)).foregroundStyle(.white).padding(.leading, side)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(list) { t in MaxGridCard(title: t) { onSelect(t) } }
                }
                .padding(.horizontal, side)
            }
        }
    }
}
