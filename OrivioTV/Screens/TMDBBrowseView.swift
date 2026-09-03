import SwiftUI

@MainActor
final class TMDBBrowseViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = true

    private var hasLoaded = false

    let companyID: Int
    let title: String

    init(companyID: Int, title: String) {
        self.companyID = companyID
        self.title = title
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        defer { isLoading = false }
        items = await TMDBService.browseCompany(id: companyID)
    }
}

/// Browses a TMDB entity's catalog (currently production companies, reached by
/// focusing a company logo on the Detail screen). Mirrors Android's
/// `TmdbEntityBrowseScreen`.
struct TMDBBrowseView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var posterLayout: HomeCatalogSettingsStore
    @StateObject private var viewModel: TMDBBrowseViewModel

    let onSelect: (MetaItem) -> Void

    /// Bound to the poster-size setting, like Home, Search, Library and
    /// Discover. A hardcoded 220pt column clipped: `PosterCard` draws at the
    /// user's chosen 180/220/264, so at Large the card was 44pt wider than its
    /// column and neighbouring cards overlapped, while at Small it left 40pt of
    /// dead gutter.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterLayout.posterSize.posterWidth,
                            maximum: posterLayout.posterSize.posterWidth),
                  spacing: OrivioSpacing.lg, alignment: .top)]
    }

    init(companyID: Int, title: String, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel(companyID: companyID, title: title))
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if viewModel.isLoading {
                OrivioLoadingView(label: "Loading titles")
            } else if viewModel.items.isEmpty {
                OrivioEmptyState(
                    icon: "building.2.fill",
                    title: viewModel.title,
                    message: "No titles available for this studio."
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                        Text(viewModel.title)
                            .font(.system(size: 52, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.leading, OrivioSpacing.huge)
                            .padding(.top, OrivioSpacing.xxl)

                        LazyVGrid(columns: columns, alignment: .leading, spacing: OrivioSpacing.xl) {
                            ForEach(viewModel.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    PosterCard(item: item)
                                }
                                .mediaCardButtonStyle()
                            }
                        }
                        .padding(.horizontal, OrivioSpacing.huge)
                        .padding(.bottom, OrivioSpacing.huge)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task { await viewModel.load() }
    }
}
