import SwiftUI

@MainActor
final class CastDetailViewModel: ObservableObject {
    @Published var items: [MetaItem] = []
    @Published var isLoading = true

    private var hasLoaded = false

    let personID: Int
    let personName: String

    init(personID: Int, personName: String) {
        self.personID = personID
        self.personName = personName
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        defer { isLoading = false }
        items = await TMDBService.personFilmography(personID: personID)
    }
}

/// An actor's filmography, reached by focusing a cast member on the Detail
/// screen. Mirrors the Android `CastDetailScreen`.
struct CastDetailView: View {
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var viewModel: CastDetailViewModel

    let onSelect: (MetaItem) -> Void

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: OrivioSpacing.lg), count: 6)

    init(personID: Int, personName: String, onSelect: @escaping (MetaItem) -> Void) {
        _viewModel = StateObject(wrappedValue: CastDetailViewModel(personID: personID, personName: personName))
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack {
            ATVBackground()
            if viewModel.isLoading {
                OrivioLoadingView(label: "Loading filmography")
            } else if viewModel.items.isEmpty {
                OrivioEmptyState(
                    icon: "person.fill.questionmark",
                    title: viewModel.personName,
                    message: "No filmography available for this person."
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                        Text(viewModel.personName)
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
