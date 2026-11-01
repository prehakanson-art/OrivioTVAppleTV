import SwiftUI

/// Discover grid: pick Type / Catalog / Genre across installed add-ons; a
/// paginated 6-column grid of results.
struct DiscoverView: View {
    let initialType: String?
    let initialGenre: String?

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var home: HomeSettingsStore
    @State private var type = "movie"
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var items: [MetaItem] = []
    @State private var page = 0
    @State private var loading = false
    @State private var exhausted = false
    @State private var picker: Picker?
    @State private var didInit = false

    enum Picker: Identifiable { case type, catalog, genre; var id: Self { self } }

    private var catalogs: [(InstalledAddon, ManifestCatalog)] {
        addons.enabled.flatMap { a in
            a.manifest.catalogs.filter { $0.type == type && !$0.isSearchOnly && !$0.extra.contains { $0.isRequired && $0.name != "genre" } }.map { (a, $0) }
        }
    }

    private var current: (InstalledAddon, ManifestCatalog)? {
        catalogs.first { "\($0.0.manifestURL)|\($0.1.id)" == catalogKey } ?? catalogs.first
    }

    private var types: [String] {
        var seen = Set<String>()
        return addons.enabled.flatMap { $0.manifest.catalogs.map(\.type) }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text(genre ?? "Discover").textStyle(.pageTitle)
                    Spacer()
                    HStack(spacing: 14) {
                        Button { picker = .type } label: { Label(typeLabel(type), systemImage: "chevron.down").labelStyle(TrailingIcon()) }
                        if catalogs.count > 1 {
                            Button { picker = .catalog } label: { Label(current?.1.name ?? "Catalog", systemImage: "chevron.down").labelStyle(TrailingIcon()) }
                        }
                        if !(current?.1.genreOptions.isEmpty ?? true) {
                            Button { picker = .genre } label: { Label(genre ?? "All Genres", systemImage: "chevron.down").labelStyle(TrailingIcon()) }
                        }
                    }
                    .buttonStyle(GlassCapsuleStyle())
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 120)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 240), spacing: 40, alignment: .top)], alignment: .leading, spacing: 60) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        let actions = PlayActions(router: router)
                        Button { actions.openDetail(item, siblings: items) } label: { PosterCard(meta: item) }
                            .buttonStyle(FlatCardStyle())
                            .onPlayPauseCommand { actions.playManually(item) }
                            .posterHoldMenu(item) { actions.openDetail(item, siblings: items) }
                            .onAppear { if i >= items.count - 12 { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal, Metrics.margin)
                if loading { OrivioLoadingView(label: "Loading…").frame(height: 200) }
                if !loading && items.isEmpty && didInit {
                    OrivioEmptyState(icon: "square.grid.3x3", title: "Nothing here", message: "This catalog returned no titles.")
                        .frame(height: 400)
                }
                Spacer().frame(height: 100)
            }
        }
        .scrollClipDisabled()
        .background(ArtField(imageURL: items.first?.background).railBleed().ignoresSafeArea())
        .task {
            guard !didInit else { return }
            type = initialType ?? "movie"
            // Prefer a catalog that offers the requested genre.
            if let g = initialGenre, let c = catalogs.first(where: { $0.1.genreOptions.contains(g) }) {
                catalogKey = "\(c.0.manifestURL)|\(c.1.id)"
                genre = g
            }
            didInit = true
            await reload()
        }
        .sheet(item: $picker) { p in pickerSheet(p) }
    }

    private func typeLabel(_ t: String) -> String {
        switch t {
        case "movie": return "Movies"
        case "series": return "Shows"
        case "tv", "channel": return "Live"
        default: return t.capitalized
        }
    }

    @ViewBuilder private func pickerSheet(_ p: Picker) -> some View {
        let options: [(String, String)] = {
            switch p {
            case .type: return types.map { ($0, typeLabel($0)) }
            case .catalog: return catalogs.map { ("\($0.0.manifestURL)|\($0.1.id)", "\($0.1.name) · \($0.0.displayName)") }
            case .genre: return [("", "All Genres")] + (current?.1.genreOptions ?? []).map { ($0, $0) }
            }
        }()
        OptionPickerSheet(title: p == .type ? "Type" : (p == .catalog ? "Catalog" : "Genre"), options: options,
                          selected: p == .type ? type : (p == .catalog ? (catalogKey ?? "") : (genre ?? ""))) { v in
            picker = nil
            switch p {
            case .type: type = v; catalogKey = nil; genre = nil
            case .catalog: catalogKey = v; genre = nil
            case .genre: genre = v.isEmpty ? nil : v
            }
            Task { await reload() }
        }
    }

    private func reload() async {
        items = []
        page = 0
        exhausted = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !exhausted, let (addon, cat) = current else { return }
        loading = true
        defer { loading = false }
        var extras: [String: String] = [:]
        if let genre { extras["genre"] = genre }
        if page > 0 {
            guard cat.supportsSkip else { exhausted = true; return }
            extras["skip"] = String(items.count)
        }
        let more = (try? await AddonClient.catalog(addon, type: cat.type, id: cat.id, extras: extras)) ?? []
        let seen = Set(items.map(\.id))
        let fresh = more.filter { !seen.contains($0.id) }.map { $0.withPoster(banners: home.value.posterBanners) }
        if fresh.isEmpty { exhausted = true }
        items += fresh
        page += 1
        ImagePipeline.shared.prefetch(fresh.prefix(6).compactMap { $0.poster.flatMap(URL.init(string:)) },
                                      maxPixel: ImageSize.poster)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.title; configuration.icon.font(.system(size: 16, weight: .bold)) }
    }
}

/// A full-screen list of options (Settings-style picker page).
struct OptionPickerSheet: View {
    let title: String
    let options: [(String, String)]
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.system(size: 40, weight: .bold)).padding(.leading, 20)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(options, id: \.0) { value, label in
                            Button { onPick(value) } label: {
                                HStack {
                                    Text(label).font(.system(size: 26, weight: .semibold))
                                    Spacer()
                                    if value == selected { Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)) }
                                }
                            }
                            .buttonStyle(FocusCapsuleRowStyle(cornerRadius: 16, height: 66))
                            .focused($focused, equals: value)
                        }
                    }
                    .padding(20)
                }
            }
            .padding(30)
            .frame(width: 760, height: 860)
            .glassCard(radius: Metrics.popoverRadius, dark: true)
        }
        .onAppear { focused = selected }
        .onExitCommand { dismiss() }
    }
}
