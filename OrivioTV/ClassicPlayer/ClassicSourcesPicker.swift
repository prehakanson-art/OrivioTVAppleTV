import SwiftUI

/// The in-player Sources screen, drawn like the app's own link list
/// (`StreamsView`): the title, the add-on filter chips, links grouped by add-on
/// and resolution in the same rows. It opens on the first link at the top —
/// the old picker opened on the playing link, often far down the list.
struct ClassicSourcesPicker: View {
    @ObservedObject var viewModel: ClassicPlayerViewModel
    @EnvironmentObject private var home: HomeSettingsStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var badgeStore: StreamBadgeStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    let onClose: () -> Void

    @State private var addonFilter: String?
    @FocusState private var focus: String?

    private static let placeholderID = "__placeholder"
    private static let topID = "__top"

    private var entries: [StreamEntry] { viewModel.allEntries }

    private var groups: [SourceGroup] {
        let shown = addonFilter.map { f in entries.filter { $0.addonName == f } } ?? entries
        return SourceFilters.group(shown, settings: playerSettings.value, addonOrder: addons.addons.map(\.displayName))
    }

    /// The link on screen now. The playing entry was rebuilt around its
    /// resolved URL, so ids differ; the rejection key names the same link.
    private func isPlaying(_ e: StreamEntry) -> Bool {
        e.rejectionKey == viewModel.currentEntry.rejectionKey
    }

    var body: some View {
        let groups = self.groups
        let firstID = groups.first?.tiers.first?.entries.first?.id
        ZStack {
            Group {
                if PerformanceProfile.isLowPower || PerformanceProfile.isMidPower {
                    Color.black.opacity(0.9)
                } else {
                    Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.65))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        header.id(Self.topID)
                        chips
                        if groups.isEmpty {
                            placeholder
                        } else {
                            ForEach(groups) { g in groupView(g) }
                        }
                    }
                    .frame(width: 1200, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                    .padding(.bottom, 100)
                }
                .scrollClipDisabled()
                .onAppear {
                    proxy.scrollTo(Self.topID, anchor: .top)
                    landOnTop(firstID)
                }
                // Links still arriving (a Continue Watching session fetches
                // them now): once the first lands, focus goes to the top of the
                // list rather than staying on the placeholder that just left.
                .onChange(of: firstID) { _, id in
                    guard focus == nil || focus == Self.placeholderID else { return }
                    proxy.scrollTo(Self.topID, anchor: .top)
                    landOnTop(id)
                }
                .onChange(of: addonFilter) { _, _ in
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            }
        }
    }

    /// Focus the first link (asked again briefly: a request made as the
    /// screen fades in can be refused).
    private func landOnTop(_ id: String?) {
        let target = id ?? Self.placeholderID
        for delay in [0.0, 0.12, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if focus == nil || focus == Self.placeholderID || delay == 0 { focus = target }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoOrTitle(logo: viewModel.meta.logo, title: viewModel.meta.name, maxSize: CGSize(width: 420, height: 120),
                        fallbackStyle: .pageTitle)
            if let v = viewModel.currentVideo { Text(v.episodeLine).textStyle(.meta) }
            if viewModel.isLoadingSources {
                Text("Searching add-ons…").textStyle(.caption)
            }
        }
    }

    @ViewBuilder private var chips: some View {
        let names = Array(Set(entries.map(\.addonName))).sorted()
        if names.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button("All") { addonFilter = nil }
                        .buttonStyle(GlassCapsuleStyle(selected: addonFilter == nil))
                    ForEach(names, id: \.self) { n in
                        Button(n) { addonFilter = n }
                            .buttonStyle(GlassCapsuleStyle(selected: addonFilter == n))
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }

    /// Focusable, so Back always has somewhere to start from.
    private var placeholder: some View {
        Button {} label: {
            Text(viewModel.isLoadingSources ? "Searching sources…" : "No sources found")
                .font(TypeStyle.cardTitle.font)
                .padding(.vertical, 18)
        }
        .buttonStyle(SourceRowStyle())
        .focused($focus, equals: Self.placeholderID)
    }

    private func groupView(_ g: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(g.addonName).eyebrow()
            ForEach(g.tiers) { tier in
                if !tier.label.isEmpty { Text(tier.label).textStyle(.meta).padding(.top, 4) }
                ForEach(tier.entries) { e in
                    Button {
                        if isPlaying(e) {
                            // Already on screen: just close the list.
                            if viewModel.overlay == .sources { viewModel.overlay = .none }
                        } else {
                            viewModel.switchSource(e)
                        }
                        onClose()
                    } label: {
                        SourceRow(entry: e, fullName: home.value.fullStreamNames,
                                  badges: badgeStore.badges(for: e), badgeScale: badgeStore.size.scale)
                    }
                    .buttonStyle(SourceRowStyle())
                    .overlay(alignment: .topTrailing) {
                        if isPlaying(e) { PlayingTag().offset(x: -24, y: -12) }
                    }
                    .focused($focus, equals: e.id)
                }
            }
        }
    }
}

/// "Playing" on the link that is on screen now.
private struct PlayingTag: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label("Playing", systemImage: "speaker.wave.2.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(theme.accentInk)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(theme.accent))
            .allowsHitTesting(false)
    }
}
