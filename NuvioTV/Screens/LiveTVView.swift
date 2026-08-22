import SwiftUI

/// A channel in the Live TV grid. Either a direct M3U stream (plays straight
/// away) or an add-on catalog entry (resolved through the source picker).
struct LiveChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let group: String
    /// Direct stream URL (from the embedded M3U). nil → resolve via `meta`.
    let directURL: String?
    let meta: MetaItem?
}

/// Live TV / IPTV tab. Merges two sources: `tv`-type catalogs from installed
/// add-ons AND an embedded iptv-org playlist, so there are channels out of the
/// box. Direct (M3U) channels play immediately; add-on channels go through the
/// normal source picker.
@MainActor
final class LiveTVViewModel: ObservableObject {
    struct Section: Identifiable {
        let id: String
        let title: String
        let channels: [LiveChannel]
    }

    @Published var sections: [Section] = []
    @Published var isLoading = false
    @Published var loadingIPTV = false
    private var loaded = false

    func loadIfNeeded(addonManager: AddonManager) async {
        guard !loaded else { return }
        loaded = true
        await load(addonManager: addonManager)
    }

    func load(addonManager: AddonManager) async {
        isLoading = sections.isEmpty

        // 1) Add-on tv catalogs (fast) — show these first.
        let addonSections = await addonSections(addonManager)
        sections = addonSections
        if !addonSections.isEmpty { isLoading = false }

        // 2) Embedded IPTV list — from the language/country playlist chosen in
        // Settings → Live TV, so channels that don't apply are simply absent.
        loadingIPTV = true
        let settings = LiveTVSettingsStore.shared
        var m3u = await M3UService.channels(from: settings.primaryPlaylistURL)

        // Safety net: if a language is chosen but its iptv-org playlist came
        // back empty (unsupported/unavailable), pull the global list and keep
        // only channels whose country is one where that language is spoken, so
        // non-matching-language channels are still hidden.
        if !settings.languageCode.isEmpty && m3u.isEmpty {
            let allowed = settings.countriesForLanguage(settings.languageCode)
            if !allowed.isEmpty {
                let global = await M3UService.channels(from: M3UService.iptvOrgURL)
                m3u = global.filter { ch in ch.country.map { allowed.contains($0) } ?? false }
            }
        }

        sections = addonSections + m3uSections(m3u)
        loadingIPTV = false
        isLoading = false
    }

    private func addonSections(_ addonManager: AddonManager) async -> [Section] {
        var requests: [(addon: InstalledAddon, catalog: ManifestCatalog)] = []
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? [])
            where catalog.type == "tv" && !catalog.requiresExtra {
                requests.append((addon, catalog))
            }
        }
        guard !requests.isEmpty else { return [] }

        var built: [(Int, Section)] = []
        await withTaskGroup(of: (Int, Section?).self) { group in
            for (i, req) in requests.enumerated() {
                group.addTask {
                    let metas = (try? await StremioAPI.catalog(addon: req.addon, catalog: req.catalog)) ?? []
                    guard !metas.isEmpty else { return (i, nil) }
                    let title = req.catalog.name ?? req.catalog.id.capitalized
                    let channels = metas.map {
                        LiveChannel(id: $0.id, name: $0.name,
                                    logo: $0.logo ?? $0.poster ?? $0.background,
                                    group: title, directURL: nil, meta: $0)
                    }
                    return (i, Section(id: "addon|\(req.addon.id)|\(req.catalog.id)", title: title, channels: channels))
                }
            }
            for await (i, section) in group { if let section { built.append((i, section)) } }
        }
        return built.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func m3uSections(_ channels: [M3UChannel]) -> [Section] {
        guard !channels.isEmpty else { return [] }
        // Preserve first-seen group order.
        var order: [String] = []
        var byGroup: [String: [LiveChannel]] = [:]
        for c in channels {
            if byGroup[c.group] == nil { order.append(c.group) }
            byGroup[c.group, default: []].append(
                LiveChannel(id: c.id, name: c.name, logo: c.logo, group: c.group, directURL: c.url, meta: nil)
            )
        }
        return order.map { g in Section(id: "iptv|\(g)", title: g, channels: byGroup[g] ?? []) }
    }
}

enum ChannelSort: String, CaseIterable, Identifiable {
    case defaultOrder = "Default"
    case nameAsc = "A → Z"
    case nameDesc = "Z → A"
    var id: String { rawValue }
}

struct LiveTVView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @ObservedObject private var liveSettings = LiveTVSettingsStore.shared
    @StateObject private var viewModel = LiveTVViewModel()

    /// Add-on channel → source picker.
    let onSelectChannel: (MetaItem) -> Void
    /// Direct (M3U) channel → play its URL immediately.
    let onPlayDirect: (LiveChannel) -> Void

    @State private var searchText = ""
    @State private var sortMode: ChannelSort = .defaultOrder
    /// A group opened via "Show All". "" = the grouped rows view.
    @State private var selectedGroup = ""

    private var settingsKey: String { "\(liveSettings.countryCode)|\(liveSettings.languageCode)" }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            content
        }
        .task { await viewModel.loadIfNeeded(addonManager: addonManager) }
        // Reload the IPTV list when the location/language changes in Settings.
        .onChange(of: settingsKey) { _, _ in
            selectedGroup = ""
            Task { await viewModel.load(addonManager: addonManager) }
        }
    }

    private func play(_ channel: LiveChannel) {
        if channel.directURL != nil { onPlayDirect(channel) }
        else if let meta = channel.meta { onSelectChannel(meta) }
    }

    private var filtering: Bool {
        !searchText.isEmpty || sortMode != .defaultOrder || !selectedGroup.isEmpty
    }

    private var displayChannels: [LiveChannel] {
        var pool = selectedGroup.isEmpty
            ? viewModel.sections.flatMap(\.channels)
            : (viewModel.sections.first { $0.title == selectedGroup }?.channels ?? [])
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.id).inserted }
        if !searchText.isEmpty {
            pool = pool.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortMode {
        case .nameAsc:  pool.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: pool.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .defaultOrder: break
        }
        return pool
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.sections.isEmpty {
            NuvioLoadingView(label: "Loading channels…")
        } else if viewModel.sections.isEmpty {
            NuvioEmptyState(
                icon: "tv",
                title: "No channels",
                message: "Couldn't load channels. Check your connection, or install a Live TV / IPTV add-on from Add-ons → Discover."
            )
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                    header
                    controls
                    if filtering {
                        gridContext
                        filteredGrid
                    } else {
                        ForEach(viewModel.sections) { section in
                            channelRow(section)
                        }
                    }
                }
                .padding(.top, NuvioSpacing.xl)
                .padding(.bottom, NuvioSpacing.huge)
            }
        }
    }

    /// Above the grid: when viewing a single group ("Show All"), a back button
    /// and the group name so you can return to the grouped rows.
    @ViewBuilder
    private var gridContext: some View {
        if !selectedGroup.isEmpty {
            HStack(spacing: NuvioSpacing.md) {
                Button { selectedGroup = "" } label: { SeeAllLabel(text: "‹ All Channels") }
                    .buttonStyle(PlainCardButtonStyle())
                Text(selectedGroup)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NuvioSpacing.huge)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live TV")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
            Text(viewModel.loadingIPTV
                 ? "Loading the IPTV channel list…"
                 : "Channels from your add-ons and the built-in IPTV list")
                .font(.system(size: 21))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.leading, NuvioSpacing.huge)
    }

    private var controls: some View {
        HStack(spacing: NuvioSpacing.lg) {
            HStack(spacing: NuvioSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                TextField("Search channels", text: $searchText)
                    .font(.system(size: 23))
            }
            .padding(.horizontal, NuvioSpacing.lg)
            .padding(.vertical, NuvioSpacing.md)
            .background(theme.palette.field, in: RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
            .frame(maxWidth: 560)

            NuvioDropdown(
                title: "Sort",
                selection: sortMode.rawValue,
                options: ChannelSort.allCases.map { NuvioDropdownOption($0.rawValue) },
                triggerWidth: 240
            ) { sortMode = ChannelSort(rawValue: $0) ?? .defaultOrder }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, NuvioSpacing.huge)
    }

    private var filteredGrid: some View {
        Group {
            if displayChannels.isEmpty {
                Text(searchText.isEmpty ? "No channels in this group." : "No channels match “\(searchText)”.")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, NuvioSpacing.huge)
                    .padding(.top, NuvioSpacing.xl)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 300), spacing: NuvioSpacing.lg, alignment: .top)],
                    alignment: .leading,
                    spacing: NuvioSpacing.xl
                ) {
                    ForEach(displayChannels) { channel in
                        Button { play(channel) } label: {
                            ChannelCard(channel: channel)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .onPlayPauseCommand { play(channel) }
                    }
                }
                .padding(.horizontal, NuvioSpacing.huge)
            }
        }
    }

    private func channelRow(_ section: LiveTVViewModel.Section) -> some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                RowHeader(title: section.title)
                Spacer()
                // Every row can open its full channel list.
                Button { selectedGroup = section.title } label: {
                    SeeAllLabel(text: "Show All")
                }
                .buttonStyle(PlainCardButtonStyle())
                .padding(.trailing, NuvioSpacing.huge)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: NuvioSpacing.lg) {
                    ForEach(section.channels.prefix(40)) { channel in
                        Button { play(channel) } label: {
                            ChannelCard(channel: channel)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .onPlayPauseCommand { play(channel) }
                    }
                }
                .padding(.horizontal, NuvioSpacing.huge)
                .padding(.vertical, NuvioSpacing.lg)
            }
            .scrollClipDisabled()
        }
    }
}

/// A landscape channel tile — logo on a dark plate with the name underneath.
/// Equatable so a focus step — which writes the row's @FocusState and re-runs
/// the row body — skips the bodies of unchanged tiles instead of rebuilding
/// every one in the row. Focus visuals come through \.isFocused, which
/// bypasses the == gate.
private struct ChannelCard: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.channel == rhs.channel }

    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @Environment(\.isFocused) private var isFocused
    let channel: LiveChannel

    private let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.sm) {
            ZStack {
                theme.palette.backgroundCard
                if let logo = channel.logo {
                    RemoteImage(url: logo, contentMode: .fit, maxDimension: width)
                        .padding(NuvioSpacing.md)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 46))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
            .shadow(color: .black.opacity(perf.settings.cardShadows && isFocused ? 0.65 : 0),
                    radius: perf.settings.cardShadows && isFocused ? 22 : 0, y: 10)
            // Fusion accent focus glow.
            .shadow(color: isFocused ? theme.effectiveFocusGlow : .clear,
                    radius: theme.isAppleTVTheme && isFocused ? 26 : 0)

            MarqueeText(
                text: channel.name,
                font: .system(size: 22, weight: .medium),
                color: isFocused ? theme.palette.textPrimary : theme.palette.textSecondary,
                active: isFocused
            )
            .frame(width: width, alignment: .leading)
        }
        .scaleEffect(perf.focusZoomEffective && isFocused ? 1.06 : 1.0)
        .animation(theme.isAppleTVTheme ? FusionMotion.focusMove : .spring(response: 0.32, dampingFraction: 0.82), value: isFocused)
    }
}
