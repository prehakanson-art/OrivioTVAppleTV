import SwiftUI

// §16.10 secondary browse screens: See All, Company, TMDB collection, Person.
// Page title top-left under the nav capsule, filter capsules on the right,
// then a 6-column poster grid.

// MARK: - Shared pieces

/// The 6-column poster grid every browse page uses. Cards open Detail;
/// Play/Pause plays manually; nearing the end asks for the next page.
struct PosterGrid: View {
    let items: [MetaItem]
    var onNearEnd: (() -> Void)? = nil
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var watched: WatchedStore

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 240), spacing: 40, alignment: .top)], alignment: .leading, spacing: 60) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let actions = PlayActions(router: router)
                Button { actions.openDetail(item, siblings: items) } label: {
                    PosterCard(meta: item, watched: item.isMovie && watched.isWatched(item.id))
                }
                .buttonStyle(FlatCardStyle())
                .onPlayPauseCommand { actions.playManually(item) }
                .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
                .onAppear { if i >= items.count - 12 { onNearEnd?() } }
            }
        }
        .padding(.horizontal, Metrics.margin)
    }
}

/// Title (and an optional subtitle) on the left, filter capsules on the right.
struct BrowseHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).textStyle(.pageTitle).lineLimit(1)
                if let subtitle { Text(subtitle).textStyle(.meta) }
            }
            Spacer(minLength: 40)
            HStack(spacing: 14) { trailing() }
                .buttonStyle(GlassCapsuleStyle())
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 120)
    }
}

extension BrowseHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A filter capsule: "Movies ⌄".
struct FilterCapsule: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(label, systemImage: "chevron.down").labelStyle(TrailingIcon()) }
    }
}

/// Grid filters shared by the browse pages.
enum BrowseTypeFilter: String, CaseIterable {
    case all, movies, shows
    var label: String { self == .all ? "All Types" : (self == .movies ? "Movies" : "Shows") }
    func keep(_ m: MetaItem) -> Bool {
        switch self {
        case .all: return true
        case .movies: return !m.isSeries
        case .shows: return m.isSeries
        }
    }
}

enum BrowseSort: String, CaseIterable {
    case standard, name, newest, oldest, rating
    var label: String {
        switch self {
        case .standard: return "Default Order"
        case .name: return "Name"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .rating: return "Rating"
        }
    }

    func apply(_ items: [MetaItem]) -> [MetaItem] {
        let year: (MetaItem) -> String = { $0.releaseInfo.map { String($0.prefix(4)) } ?? "" }
        switch self {
        case .standard: return items
        case .name: return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest: return items.sorted { year($0) > year($1) }
        case .oldest: return items.sorted { (year($0).isEmpty ? "9999" : year($0)) < (year($1).isEmpty ? "9999" : year($1)) }
        case .rating: return items.sorted { (Double($0.imdbRating ?? "") ?? 0) > (Double($1.imdbRating ?? "") ?? 0) }
        }
    }
}

/// The empty / loading footer under a grid.
struct GridFooter: View {
    let loading: Bool
    let isEmpty: Bool
    var emptyIcon = "square.grid.3x3"
    var emptyTitle = "Nothing here"
    var emptyMessage = "There are no titles to show."

    var body: some View {
        if loading {
            OrivioLoadingView(label: "Loading…", holdsFocus: isEmpty).frame(height: 200)
        } else if isEmpty {
            OrivioEmptyState(icon: emptyIcon, title: emptyTitle, message: emptyMessage).frame(height: 400)
        }
    }
}

// MARK: - See All (one add-on catalog, paginated with skip=)

struct CatalogSeeAllView: View {
    let addonURL: String
    let catalog: ManifestCatalog
    let title: String

    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var home: HomeSettingsStore
    @State private var genre: String?
    @State private var items: [MetaItem] = []
    @State private var loading = false
    @State private var exhausted = false
    @State private var pickingGenre = false
    @State private var didInit = false

    private var addon: InstalledAddon? {
        addons.enabled.first { $0.manifestURL == addonURL } ?? addons.addons.first { $0.manifestURL == addonURL }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                BrowseHeader(title: title, subtitle: addon?.displayName) {
                    if !catalog.genreOptions.isEmpty {
                        FilterCapsule(label: genre ?? "All Genres") { pickingGenre = true }
                    }
                }
                PosterGrid(items: items) { Task { await loadMore() } }
                GridFooter(loading: loading, isEmpty: items.isEmpty && didInit, emptyMessage: "This catalog returned no titles.")
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: items.first?.background).railBleed().ignoresSafeArea())
        .task {
            guard !didInit else { return }
            if catalog.genreRequired { genre = catalog.genreOptions.first }
            await loadMore()
            didInit = true
        }
        .sheet(isPresented: $pickingGenre) {
            let all: [(String, String)] = catalog.genreRequired ? [] : [("", "All Genres")]
            OptionPickerSheet(title: "Genre", options: all + catalog.genreOptions.map { ($0, $0) }, selected: genre ?? "") { v in
                pickingGenre = false
                genre = v.isEmpty ? nil : v
                items = []
                exhausted = false
                Task { await loadMore() }
            }
        }
    }

    private func loadMore() async {
        guard !loading, !exhausted, let addon else { return }
        loading = true
        defer { loading = false }
        var extras: [String: String] = [:]
        if let genre { extras["genre"] = genre }
        if !items.isEmpty {
            guard catalog.supportsSkip else { exhausted = true; return }
            extras["skip"] = String(items.count)
        }
        let requested = genre
        let more = (try? await AddonClient.catalog(addon, type: catalog.type, id: catalog.id, extras: extras)) ?? []
        guard requested == genre else { return }
        let seen = Set(items.map(\.id))
        let fresh = more.filter { !seen.contains($0.id) }.map { $0.withPoster(banners: home.value.posterBanners) }
        if fresh.isEmpty { exhausted = true }
        items += fresh
    }
}

// MARK: - Company / Network (TMDB)

struct CompanyView: View {
    let companyID: Int
    let name: String
    let isNetwork: Bool

    @State private var items: [MetaItem] = []
    @State private var page = 1
    @State private var loading = false
    @State private var exhausted = false
    @State private var type: BrowseTypeFilter = .all
    @State private var sort: BrowseSort = .standard
    @State private var picker: Picker?
    @State private var didInit = false

    enum Picker: Identifiable { case type, sort; var id: Self { self } }

    private var shown: [MetaItem] { sort.apply(items.filter(type.keep)) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                BrowseHeader(title: name, subtitle: isNetwork ? "Network" : "Studio") {
                    if !isNetwork { FilterCapsule(label: type.label) { picker = .type } }
                    FilterCapsule(label: sort == .standard ? "Popular" : sort.label) { picker = .sort }
                }
                PosterGrid(items: shown) { Task { await loadMore() } }
                GridFooter(loading: loading, isEmpty: shown.isEmpty && didInit,
                           emptyIcon: "building.2", emptyMessage: tmdbReady ? "TMDB has no titles for \(name)." : "Add your TMDB key in Settings → Integrations to browse studios and networks.")
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: shown.first?.background).railBleed().ignoresSafeArea())
        .task {
            guard !didInit else { return }
            await loadMore()
            didInit = true
        }
        .sheet(item: $picker) { p in
            switch p {
            case .type:
                OptionPickerSheet(title: "Type", options: BrowseTypeFilter.allCases.map { ($0.rawValue, $0.label) }, selected: type.rawValue) { v in
                    picker = nil
                    type = BrowseTypeFilter(rawValue: v) ?? .all
                }
            case .sort:
                OptionPickerSheet(title: "Sort", options: BrowseSort.allCases.map { ($0.rawValue, $0 == .standard ? "Popular" : $0.label) }, selected: sort.rawValue) { v in
                    picker = nil
                    sort = BrowseSort(rawValue: v) ?? .standard
                }
            }
        }
    }

    private var tmdbReady: Bool { AppStores.shared.tmdb.value.isUsable }

    private func loadMore() async {
        guard !loading, !exhausted, tmdbReady, page <= 25 else { return }
        loading = true
        defer { loading = false }
        let more = await TMDBService.company(companyID, isNetwork: isNetwork, page: page)
        let seen = Set(items.map(\.id))
        let fresh = more.filter { !seen.contains($0.id) }
        if fresh.isEmpty { exhausted = true }
        items += fresh
        page += 1
    }
}

// MARK: - TMDB collection (a film franchise)

struct TMDBCollectionView: View {
    let collectionID: Int
    let name: String

    @State private var backdrop: String?
    @State private var title = ""
    @State private var parts: [MetaItem] = []
    @State private var loading = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                BrowseHeader(title: title.isEmpty ? name : title,
                             subtitle: parts.isEmpty ? nil : "\(parts.count) film\(parts.count == 1 ? "" : "s")")
                PosterGrid(items: parts)
                GridFooter(loading: loading, isEmpty: parts.isEmpty && !loading, emptyIcon: "film.stack",
                           emptyMessage: "TMDB didn't return this collection.")
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background {
            ZStack {
                ArtField(imageURL: backdrop)
                if let backdrop {
                    RemoteImage(url: backdrop, maxPixel: ImageSize.backdrop, placeholder: false)
                        .frame(width: 1920, height: 1080)
                        .overlay(LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                }
            }
            .railBleed()
            .ignoresSafeArea()
        }
        .task {
            guard parts.isEmpty else { return }
            if let c = await TMDBService.collection(collectionID) {
                withAnimation(Motion.pageOpen) {
                    title = c.name
                    backdrop = c.backdrop
                    parts = c.parts
                }
            }
            loading = false
        }
    }
}

// MARK: - Person

/// 260 pt circle photo + name (48 bold) + known-for line, then Movies and Shows rows.
struct PersonView: View {
    let personID: Int
    let name: String

    @EnvironmentObject private var router: Router
    @State private var person: TMDBService.PersonDetails?
    @State private var loading = true
    @State private var focusedItem: MetaItem?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                header
                if let person {
                    if !person.movies.isEmpty { row("Movies", person.movies) }
                    if !person.shows.isEmpty { row("Shows", person.shows) }
                    if person.movies.isEmpty && person.shows.isEmpty {
                        OrivioEmptyState(icon: "person.crop.circle", title: "No titles", message: "TMDB has no credits for \(person.name).")
                            .frame(height: 300)
                    }
                } else if loading {
                    OrivioLoadingView(label: "Loading…", holdsFocus: true).frame(height: 300)
                } else {
                    OrivioEmptyState(icon: "person.crop.circle.badge.exclamationmark", title: "Couldn't load \(name)",
                                     message: AppStores.shared.tmdb.value.isUsable ? "TMDB didn't respond. Try again later." : "Add your TMDB key in Settings → Integrations.")
                        .frame(height: 300)
                }
                Spacer().frame(height: 60)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: focusedItem?.background ?? person?.movies.first?.background).railBleed().ignoresSafeArea())
        .task {
            guard person == nil else { return }
            person = await TMDBService.person(personID)
            loading = false
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 50) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12))
                if let photo = person?.photo {
                    RemoteImage(url: photo, maxPixel: 520, placeholder: false).clipShape(Circle())
                } else {
                    Text(initials).font(.system(size: 84, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 260, height: 260)
            .shadow(color: .black.opacity(0.35), radius: PerformanceProfile.isConstrained ? 6 : 24,
                    y: PerformanceProfile.isConstrained ? 3 : 12)
            VStack(alignment: .leading, spacing: 14) {
                Text(person?.name ?? name).font(.system(size: 48, weight: .bold)).lineLimit(1)
                if let line = knownForLine { Text(line).textStyle(.meta) }
                if let bio = person?.biography, !bio.isEmpty {
                    Text(bio).textStyle(.body, color: Palette.textSecondary).lineLimit(4).frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, 110)
    }

    private var knownForLine: String? {
        guard let p = person else { return nil }
        var parts: [String] = []
        if let k = p.knownFor, !k.isEmpty { parts.append(k == "Acting" ? "Actor" : k) }
        let top = (p.movies + p.shows).prefix(3).map(\.name)
        if !top.isEmpty { parts.append("Known for " + top.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private func row(_ title: String, _ items: [MetaItem]) -> some View {
        FocusRow(rowKey: "person-\(personID)-\(title)", title: title, items: items,
                 onFocus: { item, _ in focusedItem = item }) { item, _ in
            let actions = PlayActions(router: router)
            Button { actions.openDetail(item, siblings: items) } label: { PosterCard(meta: item) }
                .buttonStyle(FlatCardStyle())
                .onPlayPauseCommand { actions.playManually(item) }
                .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
        }
    }
}
