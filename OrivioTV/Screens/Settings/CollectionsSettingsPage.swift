import SwiftUI

// §6.8 Collections editor (Settings → Home & Layout → Collections): New
// Collection, rename, Pin to top, Focus glow, "All" tab, folders with add-on /
// TMDB / Trakt sources, reorder and remove. Pages read the store by id, so a
// pushed page always shows the current state.

struct CollectionsSettingsPage: View {
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsGroup(footer: "Collections group titles into folders. Rows-style collections get their own Home row; the others share one \u{201C}Collections\u{201D} row.") {
            SettingsRow(label: "New Collection", icon: "plus") {
                let c = collections.create(title: "New Collection")
                nav.push(c.title) { CollectionEditPage(collectionID: c.id) }
            }
        }
        if !collections.library.isEmpty {
            SettingsGroup(header: "Your Collections") {
                ForEach(collections.library) { c in
                    SettingsRow(label: c.title, detail: summary(c), value: c.pinToTop ? "Pinned" : nil, chevron: true) {
                        nav.push(c.title) { CollectionEditPage(collectionID: c.id) }
                    }
                }
            }
        }
    }

    private func summary(_ c: OrivioCollection) -> String {
        let n = c.folders.count
        return "\(n) folder\(n == 1 ? "" : "s") · \(CollectionViewMode(rawValue: c.viewMode.uppercased())?.label ?? "Rows")"
    }
}

enum CollectionViewMode: String, CaseIterable {
    case ROWS, TABBED_GRID, COMBINED
    var label: String {
        switch self {
        case .ROWS: return "Own Home Row"
        case .TABBED_GRID: return "Collections Row · Tabs"
        case .COMBINED: return "Collections Row · Combined"
        }
    }
}

enum FolderTileShape: String, CaseIterable {
    case SQUARE, POSTER, LANDSCAPE
    var label: String { rawValue.capitalized }
}

struct CollectionEditPage: View {
    let collectionID: String
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var confirm: ConfirmAction?

    private var collection: OrivioCollection? { collections.collection(collectionID) }

    private func edit(_ f: (inout OrivioCollection) -> Void) {
        guard var c = collection else { return }
        f(&c)
        collections.update(c)
    }

    var body: some View {
        if let c = collection {
            SettingsGroup {
                TextEntryRow(label: "Name", text: Binding(get: { c.title }, set: { v in if !v.isEmpty { edit { $0.title = v } } }))
                PickerRow(label: "Show on Home as", options: CollectionViewMode.allCases,
                          selection: Binding(get: { CollectionViewMode(rawValue: c.viewMode.uppercased()) ?? .ROWS }, set: { v in edit { $0.viewMode = v.rawValue } }),
                          title: \.label)
                ToggleRow(label: "Pin to top", isOn: Binding(get: { c.pinToTop }, set: { v in edit { $0.pinToTop = v } }))
                ToggleRow(label: "Focus glow", isOn: Binding(get: { c.focusGlowEnabled ?? true }, set: { v in edit { $0.focusGlowEnabled = v } }))
                ToggleRow(label: "\u{201C}All\u{201D} tab", detail: "Every folder's titles together, first on the collection page",
                          isOn: Binding(get: { c.showAllTab }, set: { v in edit { $0.showAllTab = v } }))
                TextEntryRow(label: "Backdrop image", text: Binding(get: { c.backdropImageUrl ?? "" }, set: { v in edit { $0.backdropImageUrl = v.isEmpty ? nil : v } }),
                             placeholder: "https://…", footer: "Shown behind the collection page and its Home tile.", keyboard: .URL)
            }
            SettingsGroup(header: "Folders") {
                ForEach(c.folders) { f in
                    SettingsRow(label: f.title, detail: sourceSummary(f), chevron: true) {
                        nav.push(f.title) { FolderEditPage(collectionID: collectionID, folderID: f.id) }
                    }
                }
                SettingsRow(label: "Add Folder", icon: "folder.badge.plus") {
                    let f = CollectionFolder(title: "Folder \(c.folders.count + 1)")
                    edit { $0.folders.append(f) }
                    nav.push(f.title) { FolderEditPage(collectionID: collectionID, folderID: f.id) }
                }
            }
            SettingsGroup(header: "Position") {
                SettingsRow(label: "Move Up", icon: "arrow.up") { collections.move(collectionID, by: -1) }
                SettingsRow(label: "Move Down", icon: "arrow.down") { collections.move(collectionID, by: 1) }
            }
            SettingsGroup {
                SettingsRow(label: "Delete Collection", destructive: true) {
                    confirm = ConfirmAction(title: "Delete \u{201C}\(c.title)\u{201D}?", message: "Its folders are removed from every profile and synced device.",
                                            button: "Delete") {
                        nav.pop()
                        collections.delete(collectionID)
                    }
                }
            }
            Color.clear.frame(height: 1).confirmation($confirm)
        }
    }

    private func sourceSummary(_ f: CollectionFolder) -> String {
        let s = f.effectiveSources
        if s.isEmpty { return "No sources yet" }
        return s.prefix(2).map(\.label).joined(separator: ", ") + (s.count > 2 ? " +\(s.count - 2)" : "")
    }
}

struct FolderEditPage: View {
    let collectionID: String
    let folderID: String
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var nav: SettingsNav
    @State private var confirm: ConfirmAction?

    private var folder: CollectionFolder? { collections.collection(collectionID)?.folders.first { $0.id == folderID } }

    private func edit(_ f: (inout CollectionFolder) -> Void) {
        guard var c = collections.collection(collectionID), let i = c.folders.firstIndex(where: { $0.id == folderID }) else { return }
        f(&c.folders[i])
        collections.update(c)
    }

    private func moveFolder(by delta: Int) {
        guard var c = collections.collection(collectionID), let i = c.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let j = max(0, min(c.folders.count - 1, i + delta))
        guard i != j else { return }
        c.folders.insert(c.folders.remove(at: i), at: j)
        collections.update(c)
    }

    var body: some View {
        if let f = folder {
            SettingsGroup {
                TextEntryRow(label: "Name", text: Binding(get: { f.title }, set: { v in if !v.isEmpty { edit { $0.title = v } } }))
                PickerRow(label: "Tile shape", options: FolderTileShape.allCases,
                          selection: Binding(get: { FolderTileShape(rawValue: f.tileShape.uppercased()) ?? .SQUARE }, set: { v in edit { $0.tileShape = v.rawValue } }),
                          title: \.label)
                ToggleRow(label: "Hide title on tile", isOn: Binding(get: { f.hideTitle }, set: { v in edit { $0.hideTitle = v } }))
                TextEntryRow(label: "Cover image", text: Binding(get: { f.coverImageUrl ?? "" }, set: { v in edit { $0.coverImageUrl = v.isEmpty ? nil : v } }),
                             placeholder: "https://…", keyboard: .URL)
                TextEntryRow(label: "Focus GIF", text: Binding(get: { f.focusGifUrl ?? "" }, set: { v in edit { $0.focusGifUrl = v.isEmpty ? nil : v; $0.focusGifEnabled = v.isEmpty ? nil : true } }),
                             placeholder: "https://….gif",
                             footer: "Plays over the cover while the tile is focused. GIF, animated WebP or a still image.", keyboard: .URL)
                TextEntryRow(label: "Cover emoji", text: Binding(get: { f.coverEmoji ?? "" }, set: { v in edit { $0.coverEmoji = v.isEmpty ? nil : String(v.prefix(2)) } }),
                             footer: "Shown on the gradient tile when there's no cover image.")
                TextEntryRow(label: "Hero backdrop", text: Binding(get: { f.heroBackdropUrl ?? "" }, set: { v in edit { $0.heroBackdropUrl = v.isEmpty ? nil : v } }),
                             placeholder: "https://…", keyboard: .URL)
                TextEntryRow(label: "Title logo", text: Binding(get: { f.titleLogoUrl ?? "" }, set: { v in edit { $0.titleLogoUrl = v.isEmpty ? nil : v } }),
                             placeholder: "https://…", keyboard: .URL)
            }
            SettingsGroup(header: "Sources", footer: "Titles from every source are interleaved. TMDB sources need your TMDB key; Trakt sources need Trakt.") {
                ForEach(Array(f.effectiveSources.enumerated()), id: \.offset) { i, s in
                    SettingsRow(label: s.label, detail: describe(s), icon: icon(s)) {
                        confirm = ConfirmAction(title: "Remove \u{201C}\(s.label)\u{201D}?", message: "The folder stops pulling titles from it.", button: "Remove") {
                            edit { folder in
                                var list = folder.effectiveSources
                                if list.indices.contains(i) { list.remove(at: i) }
                                folder.sources = list
                                folder.catalogSources = nil
                            }
                        }
                    }
                }
                SettingsRow(label: "Add Add-on Catalog", chevron: true, icon: "puzzlepiece.extension") {
                    nav.push("Add-on Catalog") { AddonCatalogSourcePage { add($0) } }
                }
                SettingsRow(label: "Add TMDB Source", chevron: true, icon: "film.stack") {
                    nav.push("TMDB Source") { TMDBSourcePage { add($0) } }
                }
                SettingsRow(label: "Add Trakt Source", chevron: true, icon: "list.star") {
                    nav.push("Trakt Source") { TraktSourcePage { add($0) } }
                }
            }
            SettingsGroup(header: "Position") {
                SettingsRow(label: "Move Up", icon: "arrow.up") { moveFolder(by: -1) }
                SettingsRow(label: "Move Down", icon: "arrow.down") { moveFolder(by: 1) }
            }
            SettingsGroup {
                SettingsRow(label: "Delete Folder", destructive: true) {
                    confirm = ConfirmAction(title: "Delete \u{201C}\(f.title)\u{201D}?", message: "Its sources are removed with it.", button: "Delete") {
                        nav.pop()
                        guard var c = collections.collection(collectionID) else { return }
                        c.folders.removeAll { $0.id == folderID }
                        collections.update(c)
                    }
                }
            }
            Color.clear.frame(height: 1).confirmation($confirm)
        }
    }

    /// Adds a source and returns to this folder.
    private func add(_ s: CollectionSource) {
        edit { folder in
            var list = folder.effectiveSources
            if !list.contains(s) { list.append(s) }
            folder.sources = list
            folder.catalogSources = nil
        }
        nav.pop()
    }

    private func describe(_ s: CollectionSource) -> String {
        if s.isAddon {
            let addon = AppStores.shared.addons.addons.first { $0.manifest.id == s.addonId }?.displayName ?? s.addonId ?? "Add-on"
            return [addon, s.type == "series" ? "Shows" : (s.type == "movie" ? "Movies" : s.type?.capitalized), s.genre].compactMap { $0 }.joined(separator: " · ")
        }
        if s.isTMDB { return "TMDB · " + (s.tmdbSourceType ?? "Discover").capitalized }
        return "Trakt" + (s.mediaType.map { " · " + ($0 == "movie" ? "Movies" : "Shows") } ?? "")
    }

    private func icon(_ s: CollectionSource) -> String {
        s.isAddon ? "puzzlepiece.extension" : (s.isTMDB ? "film.stack" : "list.star")
    }
}

// MARK: - Source pickers

/// Every catalog of every enabled add-on; a catalog with genres asks for one next.
private struct AddonCatalogSourcePage: View {
    let onPick: (CollectionSource) -> Void
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        let groups = addons.enabled.filter { a in a.manifest.catalogs.contains { !$0.isSearchOnly } }
        if groups.isEmpty {
            Text("Install an add-on with catalogs first.").textStyle(.body, color: Palette.textSecondary)
        }
        ForEach(groups, id: \.manifestURL) { a in
            SettingsGroup(header: a.displayName) {
                ForEach(a.manifest.catalogs.filter { !$0.isSearchOnly }, id: \.key) { cat in
                    let typeName = cat.type == "movie" ? "Movies" : (cat.type == "series" ? "Shows" : cat.type.capitalized)
                    SettingsRow(label: cat.name.isEmpty ? cat.id : cat.name, detail: typeName, chevron: !cat.genreOptions.isEmpty) {
                        let base = CollectionSource.addon(a.manifest.id, type: cat.type, catalogId: cat.id)
                        if cat.genreOptions.isEmpty {
                            onPick(withTitle(base, cat.name))
                        } else {
                            let options: [String?] = (cat.genreRequired ? [] : [nil]) + cat.genreOptions.map { Optional($0) }
                            nav.push("Genre") {
                                PickerPage(options: options, selected: nil, title: { $0 ?? "All Genres" }) { g in
                                    var s = base
                                    s.genre = g
                                    nav.pop()
                                    onPick(withTitle(s, [cat.name, g].compactMap { $0 }.joined(separator: " · ")))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func withTitle(_ s: CollectionSource, _ title: String) -> CollectionSource {
        var s = s
        s.title = title
        return s
    }
}

/// TMDB: studios, networks, people, film collections and discover feeds.
private struct TMDBSourcePage: View {
    let onPick: (CollectionSource) -> Void
    @EnvironmentObject private var tmdb: TMDBSettingsStore
    @EnvironmentObject private var nav: SettingsNav

    static let networks: [(Int, String)] = [
        (213, "Netflix"), (2552, "Apple TV+"), (1024, "Prime Video"), (2739, "Disney+"), (3186, "HBO Max"), (49, "HBO"),
        (453, "Hulu"), (4330, "Paramount+"), (3353, "Peacock"), (88, "FX"), (174, "AMC"), (67, "Showtime"),
        (318, "Starz"), (4, "BBC One"), (6, "NBC"), (2, "ABC"), (16, "CBS"), (19, "FOX"), (71, "The CW"), (1112, "Crunchyroll"),
    ]

    var body: some View {
        if !tmdb.value.isUsable {
            SettingsGroup(footer: "Add your TMDB key in Settings → Integrations. You can still add these sources; the folder shows guidance until TMDB is connected.") {
                EmptyView()
            }
        }
        SettingsGroup(header: "Discover") {
            SettingsRow(label: "Popular Movies") { onPick(.tmdb("DISCOVER", title: "Popular Movies", id: nil, mediaType: "movie", sortBy: "popularity.desc")) }
            SettingsRow(label: "Popular Shows") { onPick(.tmdb("DISCOVER", title: "Popular Shows", id: nil, mediaType: "tv", sortBy: "popularity.desc")) }
            SettingsRow(label: "Top Rated Movies") {
                onPick(.tmdb("DISCOVER", title: "Top Rated Movies", id: nil, mediaType: "movie", sortBy: "vote_average.desc", filters: TmdbFilters(voteCountGte: 1000)))
            }
            SettingsRow(label: "Top Rated Shows") {
                onPick(.tmdb("DISCOVER", title: "Top Rated Shows", id: nil, mediaType: "tv", sortBy: "vote_average.desc", filters: TmdbFilters(voteCountGte: 500)))
            }
            SettingsRow(label: "New Movies (90 days)") {
                onPick(.tmdb("DISCOVER", title: "New Movies", id: nil, mediaType: "movie", sortBy: "popularity.desc", filters: TmdbFilters(recentDays: 90)))
            }
        }
        SettingsGroup(header: "Search") {
            SettingsRow(label: "Studio", detail: "e.g. A24, Pixar, Marvel Studios", chevron: true, icon: "building.2") {
                nav.push("Studio") {
                    TMDBSearchPage(placeholder: "Studio name") { q in
                        await TMDBService.searchCompanies(q).map { ($0.id, $0.name, nil) }
                    } onPick: { id, name in
                        nav.pop()
                        onPick(.tmdb("COMPANY", title: name, id: id, mediaType: "movie"))
                    }
                }
            }
            SettingsRow(label: "Person", detail: "Actor or director filmography", chevron: true, icon: "person.crop.circle") {
                nav.push("Person") {
                    TMDBSearchPage(placeholder: "Name") { q in
                        await TMDBService.searchPeople(q).map { ($0.id, $0.name, $0.role) }
                    } onPick: { id, name in
                        nav.pop()
                        onPick(.tmdb("PERSON", title: name, id: id, mediaType: "movie"))
                    }
                }
            }
            SettingsRow(label: "Film Collection", detail: "A franchise, e.g. The Lord of the Rings", chevron: true, icon: "film.stack") {
                nav.push("Film Collection") {
                    TMDBSearchPage(placeholder: "Collection name") { q in
                        await TMDBService.searchCollections(q).map { ($0.0, $0.1, nil) }
                    } onPick: { id, name in
                        nav.pop()
                        onPick(.tmdb("COLLECTION", title: name, id: id, mediaType: "movie"))
                    }
                }
            }
        }
        SettingsGroup(header: "Networks") {
            ForEach(Self.networks, id: \.0) { id, name in
                SettingsRow(label: name) { onPick(.tmdb("NETWORK", title: name, id: id, mediaType: "tv")) }
            }
        }
    }
}

/// A query field and its results.
private struct TMDBSearchPage: View {
    let placeholder: String
    let search: (String) async -> [(Int, String, String?)]
    let onPick: (Int, String) -> Void
    @State private var query = ""
    @State private var results: [(Int, String, String?)] = []
    @State private var searching = false
    @State private var searched = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            TextField(placeholder, text: $query)
                .autocorrectionDisabled()
                .font(.system(size: 28))
                .focused($fieldFocused)
                .onSubmit { run() }
            if searching {
                HStack(spacing: 14) { ProgressView(); Text("Searching…").textStyle(.meta) }
            } else if searched && results.isEmpty {
                Text("No matches.").textStyle(.body, color: Palette.textSecondary)
            }
            if !results.isEmpty {
                SettingsGroup {
                    ForEach(results, id: \.0) { id, name, detail in
                        SettingsRow(label: name, detail: detail) { onPick(id, name) }
                    }
                }
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fieldFocused = true } }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = await search(q)
            searching = false
            searched = true
        }
    }
}

/// Trakt: public charts, or a public list by id.
private struct TraktSourcePage: View {
    let onPick: (CollectionSource) -> Void
    @EnvironmentObject private var nav: SettingsNav

    static let charts: [(String, String, String)] = [
        ("movies/trending", "Trending Movies", "movie"), ("shows/trending", "Trending Shows", "series"),
        ("movies/popular", "Popular Movies", "movie"), ("shows/popular", "Popular Shows", "series"),
        ("movies/anticipated", "Anticipated Movies", "movie"), ("shows/anticipated", "Anticipated Shows", "series"),
        ("movies/boxoffice", "Box Office", "movie"),
    ]

    var body: some View {
        if Secrets.traktClientID.isEmpty {
            Text("Trakt isn't configured in this build.").textStyle(.body, color: Palette.textSecondary)
        } else {
            SettingsGroup(header: "Charts") {
                ForEach(Self.charts, id: \.0) { path, title, type in
                    SettingsRow(label: title) { onPick(.traktEndpoint(path, title: title, mediaType: type)) }
                }
            }
            SettingsGroup(header: "List", footer: "The number in a list's trakt.tv address, e.g. trakt.tv/lists/2142753.") {
                TextEntryRow(label: "Public list ID", text: Binding(get: { "" }, set: { v in
                    let digits = v.filter(\.isNumber)
                    if let id = Int64(digits) {
                        DispatchQueue.main.async { onPick(.traktList(id, title: "Trakt List \(id)")) }
                    }
                }), keyboard: .numberPad)
            }
        }
    }
}
