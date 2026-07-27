import SwiftUI

// Stremio's Discover — reconstructed from the IPA's CatalogGridVC + FilterBox
// / DropdownCollectionView: a filter row (Type · Catalog · Genre) above a
// poster grid of the selected catalog. Browsable catalogs come from the
// installed addons.

@MainActor
final class StremioDiscoverModel: ObservableObject {
    struct Source: Identifiable, Hashable {
        let addon: InstalledAddon
        let catalog: ManifestCatalog
        var id: String { "\(addon.id)|\(catalog.type)|\(catalog.id)" }
        var typeLabel: String {
            switch catalog.type {
            case "movie": return "Movies"
            case "series": return "Series"
            case "tv", "channel": return "TV"
            default: return catalog.type.capitalized
            }
        }
    }

    @Published var sources: [Source] = []
    @Published var selected: Source?
    @Published var genre: String? = nil
    @Published var items: [MetaItem] = []
    @Published var isLoading = false

    private var loadToken = 0

    func buildSources(_ addonManager: AddonManager) {
        var out: [Source] = []
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                out.append(Source(addon: addon, catalog: catalog))
            }
        }
        sources = out
        if selected == nil { selected = out.first }
    }

    var types: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in sources where seen.insert(s.typeLabel).inserted { out.append(s.typeLabel) }
        return out
    }

    func sources(forType type: String) -> [Source] {
        sources.filter { $0.typeLabel == type }
    }

    var genreOptions: [String] { selected?.catalog.genreOptions ?? [] }

    func load() async {
        guard let selected else { items = []; return }
        loadToken += 1
        let token = loadToken
        isLoading = true
        let result = (try? await StremioAPI.catalog(addon: selected.addon, catalog: selected.catalog, genre: genre)) ?? []
        guard token == loadToken else { return }
        items = result
        isLoading = false
    }
}

struct StremioDiscoverView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @StateObject private var model = StremioDiscoverModel()
    let onSelect: (MetaItem) -> Void
    var onBackAtRoot: () -> Void = {}

    @State private var showTypeMenu = false
    @State private var showCatalogMenu = false
    @State private var showGenreMenu = false

    private let columns = Array(repeating: GridItem(.fixed(200), spacing: 24, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Discover")
                    .font(StremioFont.bold(48))
                    .foregroundStyle(StremioSurfaces.textPrimary)
                    .padding(.top, 40)

                filterRow

                if model.isLoading && model.items.isEmpty {
                    NuvioLoadingView(label: "Loading").frame(maxWidth: .infinity).frame(height: 360)
                } else if model.items.isEmpty {
                    StremioEmptyState(icon: "safari", title: "Nothing here",
                                      message: "Pick a different catalog or genre.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(model.items) { item in
                            Button { onSelect(item) } label: {
                                StremioPosterCard(item: item, width: 200, parallax: perf.cardParallaxEffective)
                            }
                            .stremioCardStyle(parallax: perf.cardParallaxEffective)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.leading, 60)
            .padding(.trailing, 70)
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .background(StremioSurfaces.background.ignoresSafeArea())
        .task {
            model.buildSources(addonManager)
            await model.load()
        }
        .onChange(of: addonManager.addons) { _, _ in model.buildSources(addonManager) }
        .onExitCommand(perform: onBackAtRoot)
    }

    private var filterRow: some View {
        HStack(spacing: 18) {
            // Type
            StremioDropdown(label: "Type", value: model.selected?.typeLabel ?? "All",
                            options: model.types) { type in
                if let first = model.sources(forType: type).first {
                    model.selected = first
                    model.genre = nil
                    Task { await model.load() }
                }
            }
            // Catalog
            StremioDropdown(label: "Catalog", value: model.selected?.catalog.displayName ?? "—",
                            options: model.sources(forType: model.selected?.typeLabel ?? "").map { $0.catalog.displayName }) { name in
                if let match = model.sources(forType: model.selected?.typeLabel ?? "").first(where: { $0.catalog.displayName == name }) {
                    model.selected = match
                    model.genre = nil
                    Task { await model.load() }
                }
            }
            // Genre
            if !model.genreOptions.isEmpty {
                StremioDropdown(label: "Genre", value: model.genre ?? "All genres",
                                options: ["All genres"] + model.genreOptions) { g in
                    model.genre = (g == "All genres") ? nil : g
                    Task { await model.load() }
                }
            }
            Spacer(minLength: 0)
        }
        .focusSection()
    }
}

/// A Stremio filter dropdown: a rounded purple-outlined pill showing the
/// current value; selecting it presents the options as a context menu.
private struct StremioDropdown: View {
    let label: String
    let value: String
    let options: [String]
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(opt) { onPick(opt) }
            }
        } label: {
            StremioDropdownLabel(label: label, value: value)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct StremioDropdownLabel: View {
    @Environment(\.isFocused) private var isFocused
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(value)
                .font(StremioFont.medium(23))
                .foregroundStyle(isFocused ? .white : StremioSurfaces.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isFocused ? .white : StremioSurfaces.textSecondary)
        }
        .padding(.horizontal, 24)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? StremioSurfaces.accent : StremioSurfaces.card)
        )
        .focusLift(1.03, isFocused, animation: StremioFocus.entry)
    }
}
