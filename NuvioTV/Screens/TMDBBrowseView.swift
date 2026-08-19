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
    @StateObject private var viewModel: TMDBBrowseViewModel

    let onSelect: (MetaItem) -> Void

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: NuvioSpacing.lg), count: 6)

    init(companyID: Int, title: String, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: TMDBBrowseViewModel(companyID: companyID, title: title))
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            if viewModel.isLoading {
                NuvioLoadingView(label: "Loading titles")
            } else if viewModel.items.isEmpty {
                NuvioEmptyState(
                    icon: "building.2.fill",
                    title: viewModel.title,
                    message: "No titles available for this studio."
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                        Text(viewModel.title)
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
                            }
                        }
                        .padding(.horizontal, NuvioSpacing.huge)
                        .padding(.bottom, NuvioSpacing.huge)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task { await viewModel.load() }
    }
}
