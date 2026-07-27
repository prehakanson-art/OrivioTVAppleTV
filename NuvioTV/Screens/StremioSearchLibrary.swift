import SwiftUI

// Stremio's Search and Library — custom screens (not the shared SearchView /
// LibraryView). Both are the navy stage with a Stremio search bar / heading
// and a grid of Stremio poster cards.

// MARK: - Search

struct StremioSearchView: View {
    @EnvironmentObject private var addonManager: AddonManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @ObservedObject var viewModel: SearchViewModel
    let onSelect: (MetaItem) -> Void
    var onBackAtRoot: () -> Void = {}

    @FocusState private var fieldFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(210), spacing: 26, alignment: .top), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                // Search bar (SearchBarTextField style).
                HStack(spacing: 18) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(StremioSurfaces.textSecondary)
                    TextField("Search movies, series, channels…", text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .font(StremioFont.medium(28))
                        .foregroundStyle(.white)
                        .focused($fieldFocused)
                }
                .padding(.horizontal, 30)
                .frame(height: 78)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(StremioSurfaces.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(fieldFocused ? StremioSurfaces.accent : .clear, lineWidth: 3)
                        )
                )
                .padding(.top, 40)

                if viewModel.isSearching && viewModel.results.isEmpty {
                    NuvioLoadingView(label: "Searching").frame(maxWidth: .infinity).frame(height: 360)
                } else if viewModel.results.isEmpty {
                    StremioEmptyState(
                        icon: "magnifyingglass",
                        title: viewModel.query.count >= 2 ? "No results" : "Search Orivio",
                        message: viewModel.query.count >= 2 ? "Nothing matched “\(viewModel.query)”." : "Find movies, series and more."
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(viewModel.results) { item in
                            Button { onSelect(item) } label: {
                                StremioPosterCard(item: item, parallax: perf.cardParallaxEffective)
                            }
                            .stremioCardStyle(parallax: perf.cardParallaxEffective)
                            .posterHoldMenu(item) { onSelect(item) }
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
        .onChange(of: viewModel.query) { _, _ in viewModel.search(addonManager: addonManager) }
        .onExitCommand(perform: onBackAtRoot)
    }
}

// MARK: - Library

struct StremioLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    let onSelect: (MetaItem) -> Void
    let onResume: (WatchProgress) -> Void
    var onBackAtRoot: () -> Void = {}

    /// Stremio's library sort options.
    enum Sort: String, CaseIterable, Identifiable {
        case lastWatched = "By Last Watched"
        case name = "By Name"
        case nameDesc = "By Name Descending"
        var id: String { rawValue }
    }
    @State private var sort: Sort = .lastWatched

    private let columns = Array(repeating: GridItem(.fixed(210), spacing: 26, alignment: .top), count: 6)

    private var saved: [SavedLibraryItem] {
        let base = library.sorted
        switch sort {
        case .lastWatched: return base   // library.sorted is already recency-ordered
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text("Library")
                        .font(StremioFont.bold(48))
                        .foregroundStyle(StremioSurfaces.textPrimary)
                    Spacer()
                    if !library.sorted.isEmpty {
                        Menu {
                            ForEach(Sort.allCases) { s in Button(s.rawValue) { sort = s } }
                        } label: {
                            StremioLibrarySortLabel(value: sort.rawValue)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
                .padding(.top, 40)
                .focusSection()

                if saved.isEmpty {
                    StremioEmptyState(icon: "bookmark", title: "Your Library is empty",
                                      message: "Add movies and series to find them here.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(saved) { item in
                            Button { onSelect(metaFor(item)) } label: {
                                StremioPosterCard(item: metaFor(item), parallax: perf.cardParallaxEffective)
                            }
                            .stremioCardStyle(parallax: perf.cardParallaxEffective)
                            .contextMenu {
                                Button("Details") { onSelect(metaFor(item)) }
                                Button("Remove from Library", role: .destructive) {
                                    library.remove(id: item.id, type: item.type)
                                }
                            }
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
        .onExitCommand(perform: onBackAtRoot)
    }

    private func metaFor(_ i: SavedLibraryItem) -> MetaItem {
        MetaItem(id: i.id, type: i.type, name: i.name, poster: i.poster,
                 background: i.background, description: i.description,
                 releaseInfo: i.releaseInfo, genres: i.genres)
    }
}

private struct StremioLibrarySortLabel: View {
    @Environment(\.isFocused) private var isFocused
    let value: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 18, weight: .bold))
            Text(value).font(StremioFont.medium(22))
        }
        .foregroundStyle(isFocused ? .white : StremioSurfaces.textPrimary)
        .padding(.horizontal, 22)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(isFocused ? StremioSurfaces.accent : StremioSurfaces.card))
        .focusLift(1.03, isFocused, animation: StremioFocus.entry)
    }
}

// MARK: - Empty state

struct StremioEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(StremioSurfaces.accentBright)
            Text(title)
                .font(StremioFont.bold(32))
                .foregroundStyle(StremioSurfaces.textPrimary)
            Text(message)
                .font(StremioFont.regular(23))
                .foregroundStyle(StremioSurfaces.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
    }
}
