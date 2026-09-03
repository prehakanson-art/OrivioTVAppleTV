import SwiftUI

/// A hand-picked "Recommended" add-on shown at the top of Discover, above the
/// full live community catalog.
struct AddonCatalogEntry: Identifiable {
    let name: String
    let tagline: String
    let category: AddonCategory
    let manifestURL: String
    /// Needs configuration on the add-on's own site (e.g. a debrid key) for
    /// full function; installing the base URL still adds it.
    var needsSetup: Bool = false
    var id: String { manifestURL }
}

enum AddonCategory: String, CaseIterable, Identifiable {
    case streams = "Streams"
    case metadata = "Catalogs & Metadata"
    case anime = "Anime"
    case liveTV = "Live TV"
    case subtitles = "Subtitles"
    case other = "More Add-ons"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .streams: return "play.rectangle.on.rectangle.fill"
        case .metadata: return "square.stack.3d.up.fill"
        case .anime: return "sparkles.tv.fill"
        case .liveTV: return "tv.fill"
        case .subtitles: return "captions.bubble.fill"
        case .other: return "puzzlepiece.extension.fill"
        }
    }
}

enum AddonDirectory {
    /// Recommended quick-picks — the most-wanted add-ons across categories,
    /// including a ready-to-go IPTV add-on that feeds the Live TV tab.
    ///
    /// These free/community-hosted manifest URLs occasionally go dark (the
    /// previous Live TV pick, "USA TV", died between sessions — its host
    /// stopped resolving entirely). If Install silently does nothing here
    /// again, it's very likely another dead host, not an app bug — the row
    /// now surfaces the actual fetch error instead of failing silently.
    static let featured: [AddonCatalogEntry] = [
        .init(name: "Cinemeta", tagline: "Official movie & series catalogs and metadata",
              category: .metadata, manifestURL: "https://v3-cinemeta.strem.io/manifest.json"),
        .init(name: "Torrentio", tagline: "Torrent streams from many trackers. Add a debrid key for cached, instant links.",
              category: .streams, manifestURL: "https://torrentio.strem.fun/manifest.json", needsSetup: true),
        .init(name: "Comet", tagline: "Debrid-focused stream scraper with strong caching",
              category: .streams, manifestURL: "https://comet.elfhosted.com/manifest.json", needsSetup: true),
        .init(name: "Watchio.live TV", tagline: "Free live TV channels from around the world, including US. Appears in the Live TV tab.",
              category: .liveTV, manifestURL: "https://watchio-addon.pages.dev/manifest.json"),
        .init(name: "Anime Kitsu", tagline: "Anime catalogs & metadata via Kitsu",
              category: .anime, manifestURL: "https://anime-kitsu.strem.fun/manifest.json"),
        .init(name: "OpenSubtitles v3", tagline: "Community subtitles in most languages",
              category: .subtitles, manifestURL: "https://opensubtitles-v3.strem.io/manifest.json"),
    ]
}

/// A single row's data, unified across the curated "Recommended" picks and the
/// live community catalog so one row view renders both.
private struct DiscoverItem: Identifiable {
    let url: String
    let name: String
    let subtitle: String
    let category: AddonCategory
    let needsSetup: Bool
    var id: String { url }
}

struct AddonDiscoverView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    let onDone: () -> Void
    @State private var installingID: String?
    /// Last install failure per row, shown inline so a dead add-on's host
    /// (the manifest fetch throwing) is visible instead of Install just
    /// silently reverting with no explanation.
    @State private var errorsByURL: [String: String] = [:]
    @State private var remote: [RemoteAddon] = []
    @State private var loading = true
    // A freshly-presented cover doesn't self-focus a bare list on tvOS; drive
    // initial focus onto the first row.
    @FocusState private var focusedID: String?

    private static let displayOrder: [AddonCategory] =
        [.streams, .liveTV, .metadata, .anime, .subtitles, .other]

    var body: some View {
        ZStack {
            ATVBackground()
            DetailScaffold(
                title: "Discover Add-ons",
                subtitle: "Recommended picks and the full community catalog"
            ) {
                LazyVStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                    section("Recommended", items: featuredItems)

                    if loading {
                        loadingRow
                    } else if remote.isEmpty {
                        Text("Couldn't reach the community catalog right now. The Recommended add-ons above still install, and you can paste any manifest URL in the Install Add-on box.")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(Self.displayOrder) { category in
                            let items = liveItems(for: category)
                            if !items.isEmpty {
                                section(category.rawValue, items: items)
                            }
                        }
                    }
                }
            }
        }
        .onExitCommand { onDone() }
        .task { await loadCatalog() }
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if focusedID == nil { focusedID = AddonDirectory.featured.first?.manifestURL }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, items: [DiscoverItem]) -> some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 18, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.palette.secondary)
                .padding(.horizontal, 8)
            ForEach(items) { item in
                let installed = isInstalled(item.url)
                Button {
                    if !installed { install(item.url) }
                } label: {
                    AddonDiscoverRowLabel(
                        item: item,
                        installed: installed,
                        installing: installingID == item.url,
                        errorMessage: errorsByURL[item.url]
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focusedID, equals: item.url)
                // Hold Select on an installed add-on to remove it right here.
                .contextMenu {
                    if installed {
                        // No destructive role — see PosterHoldMenu: tvOS
                        // won't present a menu containing one.
                        Button { uninstall(item.url) } label: {
                            Label("Remove Add-on", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: OrivioSpacing.md) {
            ProgressView().tint(theme.palette.secondary)
            Text("Loading community add-ons…")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, OrivioSpacing.md)
    }

    // MARK: Data

    private var featuredItems: [DiscoverItem] {
        AddonDirectory.featured
            .map {
                DiscoverItem(url: $0.manifestURL, name: $0.name, subtitle: $0.tagline,
                             category: $0.category, needsSetup: $0.needsSetup)
            }
    }

    /// Live add-ons in a category, minus any already shown under Recommended.
    private func liveItems(for category: AddonCategory) -> [DiscoverItem] {
        let featuredBases = Set(AddonDirectory.featured.map { Self.base($0.manifestURL) })
        return remote
            .filter { $0.category == category
                && !featuredBases.contains(Self.base($0.transportUrl)) }
            .map {
                DiscoverItem(url: $0.transportUrl, name: $0.name,
                             subtitle: $0.description ?? "", category: category, needsSetup: false)
            }
    }

    private func loadCatalog() async {
        loading = true
        remote = await AddonCatalogService.fetchAll()
        loading = false
    }

    /// The third copy of this derivation — and the one that kept the query, so
    /// for a configured addon (`…/manifest.json?token=…`) it disagreed with
    /// `InstalledAddon.baseURL` and both "Installed" and Uninstall silently
    /// failed to match. There is now one source of truth.
    private static func base(_ url: String) -> String {
        InstalledAddon.baseURL(forManifestURL: AddonManager.normalizeManifestURL(url))
    }

    private func isInstalled(_ url: String) -> Bool {
        let base = Self.base(url)
        return addonManager.addons.contains { $0.baseURL == base }
    }

    private func install(_ url: String) {
        guard installingID == nil else { return }
        installingID = url
        errorsByURL[url] = nil
        Task {
            do {
                try await addonManager.install(manifestURL: url)
            } catch {
                // Almost always a dead/unreachable manifest host (the add-on's
                // free hosting went down) rather than anything wrong on our
                // end — say so plainly instead of leaving Install as the only
                // visible state, which reads as "nothing happened."
                errorsByURL[url] = "Couldn't install: \(error.localizedDescription). This add-on's server may be down."
            }
            installingID = nil
        }
    }

    private func uninstall(_ url: String) {
        let base = Self.base(url)
        if let addon = addonManager.addons.first(where: { $0.baseURL == base }) {
            addonManager.remove(addon)
        }
    }
}

/// The row VISUAL only — used as a Button's `label`, so `@Environment(\.isFocused)`
/// here reflects that button's own focus and the ring/highlight actually shows.
/// (The Button and `.focused` live in the parent; a Button is never disabled —
/// installed rows just no-op — so every row stays focusable.)
private struct AddonDiscoverRowLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let item: DiscoverItem
    let installed: Bool
    let installing: Bool
    var errorMessage: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: OrivioSpacing.md) {
            SettingsIconTile(symbol: item.category.icon)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: OrivioSpacing.sm) {
                    Text(item.name)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    if item.needsSetup {
                        Text("Needs setup")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.palette.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(theme.palette.secondary.opacity(0.18)))
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OrivioPrimitives.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: OrivioSpacing.lg)
            accessory
                .padding(.top, 2)
        }
        .padding(.horizontal, OrivioSpacing.md)
        .padding(.vertical, OrivioSpacing.md)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
    }

    @ViewBuilder
    private var accessory: some View {
        if installing {
            ProgressView().tint(theme.palette.secondary)
        } else if installed {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Installed")
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(OrivioPrimitives.success)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("Install")
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(isFocused ? theme.palette.secondary : theme.palette.secondary.opacity(0.16)))
        }
    }
}
