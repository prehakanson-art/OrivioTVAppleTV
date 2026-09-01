import SwiftUI

@MainActor
final class CatalogSeeAllViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = false
    @Published var reachedEnd = false

    let addon: InstalledAddon
    let catalog: ManifestCatalog
    private var seenIDs = Set<String>()

    init(addon: InstalledAddon, catalog: ManifestCatalog) {
        self.addon = addon
        self.catalog = catalog
    }

    /// Load the next page. Stremio paginates via `skip`; we advance by however
    /// many items we already have and stop when a page adds nothing new.
    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let page = (try? await StremioAPI.catalog(addon: addon, catalog: catalog, skip: items.count)) ?? []
        let fresh = page.filter { seenIDs.insert($0.id).inserted }
        if fresh.isEmpty {
            reachedEnd = true
        } else {
            items.append(contentsOf: fresh)
        }
    }
}

/// A full, paginated grid for a single catalog — the "See All" destination from
/// a home row. Mirrors Android's `CatalogSeeAllScreen`.
struct CatalogSeeAllView: View {
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var viewModel: CatalogSeeAllViewModel

    let title: String
    let onSelect: (MetaItem) -> Void

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: NuvioSpacing.lg), count: 6)

    init(addon: InstalledAddon, catalog: ManifestCatalog, title: String, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: CatalogSeeAllViewModel(addon: addon, catalog: catalog))
        self.title = title
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if viewModel.items.isEmpty && viewModel.isLoading {
                NuvioLoadingView(label: "Loading \(title)")
            } else if viewModel.items.isEmpty {
                NuvioEmptyState(icon: "square.stack.3d.up.slash", title: title, message: "No titles in this catalog.")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                        Text(title)
                            .font(.system(size: 52, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.leading, NuvioSpacing.huge)
                            .padding(.top, NuvioSpacing.xxl)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: NuvioSpacing.xl) {
                            ForEach(viewModel.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    PosterCard(item: item)
                                }
                                .mediaCardButtonStyle()
                                .onAppear {
                                    // Prefetch the next page as the tail comes into view.
                                    if item.id == viewModel.items.last?.id {
                                        Task { await viewModel.loadMore() }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, NuvioSpacing.huge)

                        if viewModel.isLoading {
                            ProgressView().tint(theme.palette.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, NuvioSpacing.huge)
                        }
                    }
                    .padding(.bottom, NuvioSpacing.huge)
                }
                .scrollClipDisabled()
            }
        }
        .task { if viewModel.items.isEmpty { await viewModel.loadMore() } }
    }
}
