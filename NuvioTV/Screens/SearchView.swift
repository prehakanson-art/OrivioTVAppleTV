import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [MetaItem] = []
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?

    func search(addonManager: AddonManager) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let targets: [(InstalledAddon, ManifestCatalog)] = addonManager.catalogAddons
            .flatMap { addon in
                (addon.manifest.catalogs ?? [])
                    .filter { $0.supportsSearch }
                    .map { (addon, $0) }
            }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            var merged: [MetaItem] = []
            var seen = Set<String>()
            await withTaskGroup(of: [MetaItem].self) { group in
                for (addon, catalog) in targets {
                    group.addTask {
                        (try? await StremioAPI.catalog(addon: addon, catalog: catalog, search: trimmed)) ?? []
                    }
                }
                for await items in group {
                    for item in items where !seen.contains(item.id + item.type) {
                        seen.insert(item.id + item.type)
                        merged.append(item)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            results = merged
            isSearching = false
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @EnvironmentObject private var addonManager: AddonManager
    // Owned by RootView so the query + results PERSIST across tab switches.
    // A local @StateObject would be rebuilt (and cleared) every time the Search
    // tab is re-entered.
    @ObservedObject var viewModel: SearchViewModel

    let onSelect: (MetaItem) -> Void
    var onOpenDiscover: () -> Void = {}

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth, maximum: posterLayout.posterSize.posterWidth), spacing: NuvioSpacing.lg, alignment: .top)] }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                searchBar
                ScrollView(.vertical) {
                    if viewModel.isSearching && viewModel.results.isEmpty {
                        NuvioLoadingView(label: "Searching").frame(height: 480)
                    } else if viewModel.results.isEmpty {
                        NuvioEmptyState(
                            icon: "magnifyingglass",
                            title: viewModel.query.count >= 2 ? "No results" : "Start Searching",
                            message: viewModel.query.count >= 2
                                ? "Nothing matched “\(viewModel.query)”."
                                : "Enter at least 2 characters"
                        )
                        .frame(height: 480)
                    } else {
                        // Results split by type: Movies on top, Shows below.
                        VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                            if !movieResults.isEmpty {
                                resultSection(title: "Movies", items: movieResults)
                            }
                            if !showResults.isEmpty {
                                resultSection(title: "Shows", items: showResults)
                            }
                        }
                        .padding(.bottom, NuvioSpacing.huge)
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.top, NuvioSpacing.xl)
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.search(addonManager: addonManager)
        }
    }

    private var searchBar: some View {
        HStack(spacing: NuvioSpacing.md) {
            Button(action: onOpenDiscover) { SearchBarIcon(systemName: "safari") }
                .buttonStyle(PlainCardButtonStyle())
            SearchField(text: $viewModel.query)
        }
        .padding(.horizontal, NuvioSpacing.huge)
    }

    private var movieResults: [MetaItem] {
        viewModel.results.filter { !$0.isSeries }
    }

    private var showResults: [MetaItem] {
        viewModel.results.filter(\.isSeries)
    }

    /// One titled grid section ("Movies" / "Shows"), its own focus section so
    /// up/down moves cleanly between the two groups.
    private func resultSection(title: String, items: [MetaItem]) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            RowHeader(title: title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioSpacing.xl) {
                ForEach(items) { item in
                    Button { onSelect(item) } label: { PosterCard(item: item) }
                        .mediaCardButtonStyle()
                        .posterHoldMenu(item) { onSelect(item) }
                }
            }
        }
        .padding(.horizontal, NuvioSpacing.huge)
        .focusSection()
    }
}


/// Round icon button in the Search top bar (Discover).
private struct SearchBarIcon: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(theme.palette.textPrimary)
            .frame(width: 74, height: 74)
            .background(Circle().fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.7)))
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(NuvioFocus.card, isFocused)
            .animation(PerformanceSettingsStore.shared.buttonAnimationsEffective
                       ? .easeInOut(duration: 0.15) : nil, value: isFocused)
    }
}

/// The APK-style pill search field. A plain `TextField` in a dark resting
/// capsule; on focus tvOS draws its own light editing surface, and we DON'T add
/// a competing ring — otherwise the system fill sits inset inside our ring with
/// a dark gap between them (the "weird bar" the user saw). Letting the system
/// focus be the sole highlight means the highlight and the field are one shape.
/// Auto-focuses on open so the keyboard is ready.
private struct SearchField: View {
    @EnvironmentObject private var theme: ThemeManager
    @FocusState private var focused: Bool
    @Binding var text: String

    var body: some View {
        TextField("Search movies & series", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 26))
            .foregroundStyle(theme.palette.textPrimary)
            .tint(theme.palette.secondary)
            .padding(.horizontal, NuvioSpacing.xl)
            .frame(height: 74)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(theme.palette.backgroundCard.opacity(0.7)))
            // No auto-focus: on the top-bar layout, merely moving focus over the
            // Search tab would otherwise pop the keyboard. Focus the field only
            // when the user actually selects it.
    }
}
