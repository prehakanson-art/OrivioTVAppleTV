import SwiftUI

/// Browse the files already in your debrid cloud (Premiumize / Real-Debrid /
/// TorBox / AllDebrid) and play them directly — the tvOS take on Android's
/// Cloud Library.
struct CloudLibraryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var debrid: DebridStore

    /// Plays a resolved cloud file (builds a throwaway MetaItem + StreamEntry).
    let onPlay: (MetaItem, StreamEntry) -> Void

    @State private var provider: DebridProvider?
    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var resolving = false
    /// Set when this page is popped. Same guard as StreamsView: presenting the
    /// player from a navigation entry that is already gone misbehaves badly,
    /// and the resolve below is an unstructured Task that outlives the view.
    @State private var isGone = false
    @FocusState private var focused: String?

    private var availableProviders: [DebridProvider] {
        CloudLibraryService.supportedProviders.filter { debrid.configuredProviders.contains($0) }
    }

    var body: some View {
        DetailScaffold(title: "Cloud Library", subtitle: "Files in your debrid cloud") {
            if availableProviders.isEmpty {
                OrivioEmptyState(
                    icon: "externaldrive.badge.xmark",
                    title: "No debrid provider configured",
                    message: "Add a Real-Debrid, Premiumize, TorBox or AllDebrid API key in Settings → Integrations to browse your cloud files."
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                if availableProviders.count > 1 { providerBar }
                content
            }
        }
        .overlay {
            if resolving {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    OrivioLoadingView(label: "Getting link")
                }
            }
        }
        .task(id: provider?.rawValue) { await load() }
        .onAppear { if provider == nil { provider = debrid.resolverProvider ?? availableProviders.first } }
        .onDisappear { isGone = true }
    }

    private var providerBar: some View {
        HStack(spacing: OrivioSpacing.sm) {
            ForEach(availableProviders) { p in
                Button { provider = p } label: {
                    SelectableChip(title: p.displayName, selected: provider == p)
                }
                .buttonStyle(PlainCardButtonStyle())
            }
        }
        .padding(.bottom, OrivioSpacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            OrivioLoadingView(label: "Loading cloud files")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if files.isEmpty {
            OrivioEmptyState(
                icon: "tray",
                title: "No video files found",
                message: "Nothing playable is in this provider's cloud yet."
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            // Movies and Shows separated into their own sections, like Search.
            VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                if !movieFiles.isEmpty {
                    LibrarySection(title: "Movies") { fileList(movieFiles) }
                }
                if !showFiles.isEmpty {
                    LibrarySection(title: "Shows") { fileList(showFiles) }
                }
            }
        }
    }

    private var movieFiles: [CloudFile] { files.filter { !$0.isSeries } }
    private var showFiles: [CloudFile] { files.filter(\.isSeries) }

    private func fileList(_ list: [CloudFile]) -> some View {
        LazyVStack(spacing: OrivioSpacing.sm) {
            ForEach(list) { file in
                Button { play(file) } label: {
                    CloudFileRow(file: file)
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focused, equals: file.id)
            }
        }
    }

    private func load() async {
        guard let provider, !debrid.key(for: provider).isEmpty else { files = []; return }
        isLoading = true
        let all = await CloudLibraryService.list(provider: provider, apiKey: debrid.key(for: provider))
        files = all.filter(\.isVideo).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    private func play(_ file: CloudFile) {
        guard let provider else { return }
        resolving = true
        Task {
            let url = await CloudLibraryService.resolveURL(file, provider: provider, apiKey: debrid.key(for: provider))
            resolving = false
            // Back was pressed while the link resolved: don't hand a player to
            // a torn-down navigation entry.
            guard !isGone, let url else { return }
            let meta = MetaItem(id: "cloud:\(file.id)", type: "movie", name: file.name)
            let stream = Stream(name: file.name, title: file.name, description: file.sizeLabel,
                                url: url, infoHash: nil, behaviorHints: nil)
            onPlay(meta, StreamEntry(addonName: "\(provider.shortName) · Cloud", stream: stream))
        }
    }
}

private struct CloudFileRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let file: CloudFile

    var body: some View {
        HStack(spacing: OrivioSpacing.md) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(isFocused ? theme.palette.secondary : theme.palette.textTertiary)
            Text(file.name)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer()
            if let size = file.sizeLabel {
                Text(size)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .frame(minHeight: 66)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
    }
}
