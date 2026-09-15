import SwiftUI

// MARK: - Layout pane (home row customization)

/// One customizable home row as shown in the Layout pane.
private struct LayoutRowInfo: Identifiable {
    let key: String
    let defaultTitle: String
    let subtitle: String
    let isCollection: Bool
    var id: String { key }
}

/// Settings → Layout: reorder, rename, and show/hide the home screen rows
/// (addon catalogs and collections), mirroring the Android Layout settings.
/// All changes sync via `sync_push_home_catalog_settings`.
struct LayoutSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var settings: HomeCatalogSettingsStore

    var body: some View {
        DetailScaffold(title: SettingsCategory.layout.title, subtitle: SettingsCategory.layout.subtitle) {
            SettingsGroupCard(title: "Home Layout", subtitle: "Choose your home screen layout") {
                HStack(spacing: OrivioSpacing.md) {
                    ForEach(HomeLayout.allCases) { option in
                        Button { settings.homeLayout = option } label: {
                            LayoutPreviewCard(option: option, selected: settings.homeLayout == option)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }

                if settings.homeLayout == .modern {
                    SettingsToggleCard(
                        title: "Landscape Posters",
                        subtitle: "Switch between portrait and landscape cards for Modern view",
                        isOn: $settings.landscapePosters
                    )
                }

                SettingsToggleCard(
                    title: "Featured section",
                    subtitle: "The rotating Featured banner between Continue Watching and your catalog rows. Off removes it from the home screen.",
                    isOn: $settings.showFeaturedBar
                )

                SettingsToggleCard(
                    title: "Pin hero to the top",
                    subtitle: "Keep the hero fixed above the rows and show whatever title is highlighted, instead of a banner that scrolls away and cycles the top ten on its own.",
                    isOn: $settings.pinnedHero
                )

                SettingsToggleCard(
                    title: "Hide the sidebar",
                    subtitle: "Give the rows the full width of the screen. Press LEFT from the edge of the page (or Menu) to bring the sidebar back; picking a tab hides it again. Settings always keeps its sidebar.",
                    isOn: $settings.autoHideSidebar
                )

                SettingsToggleCard(
                    title: "Hero trailers",
                    subtitle: "With the hero pinned, play the highlighted title's trailer in the hero behind the name and details. Sitting on the hero itself cycles through the Top 10, trailer and all.",
                    isOn: $settings.heroTrailersEnabled
                )

                SettingsToggleCard(
                    title: "Hero trailer sound",
                    subtitle: "Play the hero trailer with sound instead of muted.",
                    isOn: $settings.heroTrailerSound
                )

                SettingsToggleCard(
                    title: "Full stream names",
                    subtitle: "On the source list, show every link's complete release name — wrapped across lines instead of cut off.",
                    isOn: $settings.fullStreamTitles
                )
            }

            SettingsGroupCard(title: "Posters", subtitle: "Card size and labels across the app") {
                HStack(spacing: OrivioSpacing.md) {
                    ForEach(PosterSize.allCases) { size in
                        Button { settings.posterSize = size } label: {
                            PosterSizeChip(title: size.displayName, selected: settings.posterSize == size)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }

                SettingsToggleCard(
                    title: "Poster labels",
                    subtitle: "Show the title and release year beneath poster cards, everywhere they appear — Home rows, Discover, Search, Library and your Plex/Jellyfin shelves. Off leaves just the artwork. Continue Watching keeps its labels either way: those name the episode and how much is left, which is information rather than decoration.",
                    isOn: $settings.showPosterLabels
                )

                OrivioDropdown(
                    title: "Corner radius",
                    subtitle: "Roundness of poster card corners",
                    icon: "square.on.square.dashed",
                    selection: String(settings.posterCornerRadius),
                    options: HomeCatalogSettingsStore.posterCornerRadiusValues.map {
                        OrivioDropdownOption(String($0), $0 == 0 ? "Square" : "\($0) pt")
                    }
                ) { settings.posterCornerRadius = Int($0) ?? 12 }

                SettingsToggleCard(
                    title: "Hide unreleased content",
                    subtitle: "Keep titles that haven't aired yet out of catalog rows",
                    isOn: $settings.hideUnreleasedContent
                )
            }

            SettingsGroupCard(title: "Rows & Details", subtitle: "Row titles and detail-page fields") {
                SettingsToggleCard(
                    title: "Addon name in row titles",
                    subtitle: "Append the source addon's name to each catalog row header",
                    isOn: $settings.catalogAddonNameEnabled
                )
                SettingsToggleCard(
                    title: "Type suffix in row titles",
                    subtitle: "Append “- Movie” / “- Series” to catalog row headers",
                    isOn: $settings.catalogTypeSuffixEnabled
                )
                SettingsToggleCard(
                    title: "Full release date",
                    subtitle: "Show the full date on the details page instead of just the year",
                    isOn: $settings.showFullReleaseDate
                )
                SettingsToggleCard(
                    title: "Trailer button",
                    subtitle: "Show the Trailer button on the details page",
                    isOn: $settings.detailPageTrailerButtonEnabled
                )
            }

            SettingsGroupCard(title: "Continue Watching", subtitle: "How the resume row behaves") {
                OrivioDropdown(
                    title: "Sort order",
                    subtitle: settings.continueWatchingSortMode.summary,
                    icon: "arrow.up.arrow.down",
                    selection: settings.continueWatchingSortMode.rawValue,
                    options: ContinueWatchingSortMode.allCases.map {
                        OrivioDropdownOption($0.rawValue, $0.displayName)
                    }
                ) { settings.continueWatchingSortMode = ContinueWatchingSortMode(rawValue: $0) ?? .recentlyWatched }

                SettingsToggleCard(
                    title: "Episode thumbnails",
                    subtitle: "Show the episode still on Continue Watching cards instead of the show poster",
                    isOn: $settings.useEpisodeThumbnailsInCw
                )

                SettingsToggleCard(
                    title: "Next up from furthest episode",
                    subtitle: "Resume a series after the furthest episode you've watched, not the most recently played one",
                    isOn: $settings.nextUpFromFurthestEpisode
                )

                SettingsToggleCard(
                    title: "Show unaired next up",
                    subtitle: "Allow an episode that hasn't aired yet to be the next-up target",
                    isOn: $settings.showUnairedNextUp
                )

                SettingsToggleCard(
                    title: "Blur unwatched episodes",
                    subtitle: "Spoiler-blur episode thumbnails you haven't watched (focus a card to reveal it)",
                    isOn: $settings.blurUnwatchedEpisodes
                )

                SettingsToggleCard(
                    title: "Blur Continue Watching next up",
                    subtitle: "Spoiler-blur art for barely-started next-up episodes on the home row",
                    isOn: $settings.blurContinueWatchingNextUp
                )
            }

            CatalogOrderSection()
        }
    }
}

/// Poster-size selector chip. Reads `\.isFocused` (only resolves inside the
/// focusable Button's subtree) so it lights up on focus, and keeps readable
/// contrast in every state: focused = filled accent + onSecondary text,
/// selected = accent-tinted + white text, idle = card + secondary text.
private struct PosterSizeChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, OrivioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous).fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : (selected ? theme.palette.secondary : .clear),
                                  lineWidth: isFocused ? 4 : 2)
            )
            .focusLift(OrivioFocus.card, isFocused)
    }

    private var foreground: Color {
        if isFocused { return theme.palette.onSecondary }
        if selected { return .white }
        return theme.palette.textSecondary
    }
    private var background: Color {
        if isFocused { return theme.palette.secondary }
        if selected { return theme.palette.secondary.opacity(0.28) }
        return theme.palette.backgroundCard.opacity(0.85)
    }
}

/// The reorder / rename / show-hide list of home catalog rows, shown at the
/// bottom of the Layout pane. (There used to be a second, identical drill-in
/// under Add-ons → Catalog Order; this is now the only one.)
struct CatalogOrderSection: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var settings: HomeCatalogSettingsStore

    @State private var renamingRow: LayoutRowInfo?
    @State private var renameText = ""

    /// Keep a just-moved row in view (runs after the reorder re-lays-out).
    private func follow(_ proxy: ScrollViewProxy, _ key: String) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .center) }
        }
    }

    /// Real catalog keys, in nothing-special order (used for the block reorder).
    private var catalogKeys: [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
        return keys
    }

    private var collectionKeys: [String] {
        collections.collections.map { HomeCatalogSettingsStore.collectionKey($0.id) }
    }

    /// Display rows: catalog rows plus ONE "Collections" row (all collections
    /// fold into it), positioned where the collections block sits.
    private var rows: [LayoutRowInfo] {
        var byKey: [String: LayoutRowInfo] = [:]
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addonID: addon.manifest.id, type: catalog.type, catalogID: catalog.id)
                if byKey[key] == nil {
                    byKey[key] = LayoutRowInfo(key: key, defaultTitle: catalog.displayName,
                                               subtitle: addon.manifest.name, isCollection: false)
                }
            }
        }
        let cKeys = collectionKeys
        let collectionsRow = LayoutRowInfo(
            key: HomeCatalogSettingsStore.collectionsUnit,
            defaultTitle: "Collections",
            subtitle: "\(collections.collections.count) collection\(collections.collections.count == 1 ? "" : "s") · one Home row",
            isCollection: true
        )
        var result: [LayoutRowInfo] = []
        var insertedCollections = false
        for key in settings.mergedOrder(catalogKeys: catalogKeys, collectionKeys: cKeys) {
            if cKeys.contains(key) {
                if !insertedCollections && !collections.collections.isEmpty {
                    result.append(collectionsRow); insertedCollections = true
                }
            } else if let r = byKey[key] {
                result.append(r)
            }
        }
        return result
    }

    private var collectionsEnabled: Bool {
        collectionKeys.contains { settings.isEnabled(key: $0) }
    }

    var body: some View {
        let rows = self.rows
        let catalogKeys = self.catalogKeys
        let collectionKeys = self.collectionKeys
        // The proxy drives the enclosing DetailScaffold scroll, so after a
        // move we scroll the row back into view — otherwise moving up pushed
        // the row off the top of the screen.
        ScrollViewReader { proxy in
            SettingsGroupCard(title: "Home Rows", subtitle: "Reorder, rename and hide your catalog rows") {
                ForEach(rows) { row in
                    let isCollectionsUnit = row.key == HomeCatalogSettingsStore.collectionsUnit
                    LayoutRowView(
                        row: row,
                        title: isCollectionsUnit ? row.defaultTitle : (settings.customTitle(for: row.key) ?? row.defaultTitle),
                        isRenamed: !isCollectionsUnit && settings.customTitle(for: row.key) != nil,
                        enabled: isCollectionsUnit ? collectionsEnabled : settings.isEnabled(key: row.key),
                        onMoveUp: {
                            settings.moveHomeUnit(up: true, unitKey: row.key, catalogKeys: catalogKeys, collectionKeys: collectionKeys)
                            follow(proxy, row.key)
                        },
                        onMoveDown: {
                            settings.moveHomeUnit(up: false, unitKey: row.key, catalogKeys: catalogKeys, collectionKeys: collectionKeys)
                            follow(proxy, row.key)
                        },
                        onToggle: {
                            if isCollectionsUnit {
                                settings.setCollectionsEnabled(!collectionsEnabled, collectionKeys: collectionKeys)
                            } else {
                                settings.setEnabled(!settings.isEnabled(key: row.key), key: row.key)
                            }
                        },
                        onRename: {
                            guard !isCollectionsUnit else { return }   // the Collections row keeps its name
                            renameText = settings.customTitle(for: row.key) ?? ""
                            renamingRow = row
                        }
                    )
                    .id(row.key)
                }

                if rows.isEmpty {
                    Text("No home rows yet — install a catalog add-on first.")
                        .font(.system(size: 21))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .fullScreenCover(item: $renamingRow) { row in
            RenameRowView(
                title: row.defaultTitle,
                text: $renameText,
                onSave: {
                    settings.setCustomTitle(renameText, key: row.key)
                    renamingRow = nil
                },
                onClear: {
                    settings.setCustomTitle(nil, key: row.key)
                    renamingRow = nil
                },
                onCancel: { renamingRow = nil }
            )
            .environmentObject(theme)
        }
    }
}

/// Selectable card for a home layout option (Classic / Modern / Grid).
/// A visual wireframe preview card for a home layout (Modern / Grid / Classic),
/// matching the APK's Home Layout picker.
private struct LayoutPreviewCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let option: HomeLayout
    let selected: Bool

    var body: some View {
        VStack(spacing: OrivioSpacing.sm) {
            preview
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.palette.secondary)
                }
                Text(option.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        }
        .padding(OrivioSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.background.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing
                              : (selected ? theme.palette.secondary : .clear), lineWidth: isFocused ? 4 : 2)
        )
    }

    private var bar: Color { theme.palette.textTertiary.opacity(0.5) }

    @ViewBuilder
    private var preview: some View {
        switch option {
        case .modern:
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(bar).frame(height: 70)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(bar).frame(height: 34) }
                }
            }
            .padding(10)
        case .grid:
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(bar) }
                    }
                }
            }
            .padding(10)
        case .classic:
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(bar).frame(height: 28) }
                    }
                }
            }
            .padding(10)
        }
    }
}

private struct LayoutRowView: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager

    let row: LayoutRowInfo
    let title: String
    let isRenamed: Bool
    let enabled: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggle: () -> Void
    let onRename: () -> Void

    // Highlight the WHOLE catalog row while any of its controls is focused —
    // the row is a group of small buttons, so without this only the tiny
    // circular control lit up and the catalog itself never highlighted.
    @State private var focusCount = 0
    private var focused: Bool { focusCount > 0 }

    var body: some View {
        HStack(spacing: OrivioSpacing.lg) {
            Image(systemName: row.isCollection ? "rectangle.stack.fill" : "square.grid.2x2.fill")
                .font(.system(size: 22))
                .foregroundStyle(enabled ? theme.palette.secondary : theme.palette.textTertiary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: OrivioSpacing.sm) {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(enabled ? theme.palette.textPrimary : theme.palette.textTertiary)
                        .lineLimit(1)
                    if isRenamed {
                        Image(systemName: "pencil")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                }
                Text(row.subtitle)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            controlButton(icon: "chevron.up", action: onMoveUp)
            controlButton(icon: "chevron.down", action: onMoveDown)
            controlButton(icon: "pencil", action: onRename)
            controlButton(icon: enabled ? "eye.fill" : "eye.slash.fill", action: onToggle)
        }
        .padding(.horizontal, OrivioSpacing.lg)
        .frame(minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .fill(focused ? theme.palette.focusBackground
                      : theme.palette.backgroundCard.opacity(enabled ? 0.5 : 0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                .strokeBorder(focused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .animation(perf.motion(FusionMotion.focusEntry), value: focused)
    }

    private func controlButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RowControlIcon(icon: icon)
        }
        .buttonStyle(PlainCardButtonStyle())
        // Count focus across the row's controls so the row stays highlighted
        // as focus moves between them (no flicker on the hand-off).
        .onFocusChange { f in focusCount = max(0, focusCount + (f ? 1 : -1)) }
    }
}

/// On/off checkmark beside a collection or folder row.
///
/// `PlainCardButtonStyle` supplies only a press dip — the focus VISUAL is the
/// label's own job, which is why `RowControlIcon` below draws one. These
/// checkmarks were a bare `Image`, so moving focus left off the row and onto
/// the checkmark made the highlight vanish: the row un-highlighted and nothing
/// took its place, so there was no way to tell what was selected.
private struct CheckToggleIcon: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let isOn: Bool

    var body: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary
                             : (isOn ? theme.palette.focusRing : theme.palette.textTertiary))
            .frame(width: 56, height: 56)
            .background(Circle().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.1)))
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.control, isFocused)
    }
}

/// Small circular icon control (move/rename/hide) with the app's focus look.
private struct RowControlIcon: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused

    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isFocused ? theme.palette.onSecondary : theme.palette.textPrimary)
            .frame(width: 56, height: 56)
            .background(Circle().fill(isFocused ? theme.palette.secondary : Color.white.opacity(0.1)))
            .overlay(Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
            .focusLift(OrivioFocus.control, isFocused)
    }
}

/// Simple rename entry cover (tvOS alerts can't host text fields).
private struct RenameRowView: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    @Binding var text: String
    let onSave: () -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.xl) {
                Text("Rename \"\(title)\"")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                TextField("Custom title", text: $text)
                    .font(.system(size: 26))
                    .frame(maxWidth: 700)

                HStack(spacing: OrivioSpacing.lg) {
                    Button("Save", action: onSave)
                    Button("Use Default", action: onClear)
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(OrivioSpacing.huge)
        }
        .onExitCommand { onCancel() }
    }
}

// MARK: - Collections pane

/// Settings → Collections: create and edit collections (custom home rows of
/// folders, each backed by TMDB / Trakt sources). Synced whole as a JSON
/// blob via `sync_push_collections`.
struct CollectionsSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var trakt: TraktStore

    private var providers: CollectionProviders {
        CollectionProviders(tmdb: tmdbSettings.isEnabled, trakt: trakt.isSignedIn)
    }

    @State private var editing: OrivioCollection?
    @State private var creating = false

    var body: some View {
        DetailScaffold(title: "Collections", subtitle: "Group TMDB and Trakt sources into custom home rows") {
            if !providers.any {
                // Collections resolve from TMDB and Trakt and nothing else.
                // They still show on Home with neither connected — every
                // folder just opens empty with this same pointer — so say it
                // here too, where the fix is one screen away. Either service
                // is enough; when both are connected TMDB is the one used.
                HStack(alignment: .top, spacing: OrivioSpacing.md) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(theme.palette.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connect TMDB or Trakt")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Collections need one of them to load anything — just one is enough. "
                             + "Add your free TMDB API key in Settings → Integrations → TMDB for the "
                             + "full range of sources, or sign in to Trakt in Settings → Trakt for your lists.")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                .padding(OrivioSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous)
                        .fill(theme.palette.backgroundCard.opacity(0.5))
                )
            }

            CollectionLayoutModePicker()

            Button { creating = true } label: {
                SettingsActionRow(
                    title: "New Collection",
                    subtitle: "A custom home row of catalog folders",
                    leadingIcon: "plus.circle.fill"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            // The LIBRARY, not the visible subset — a collection switched off
            // account-wide has to stay listed here or there'd be no way to turn
            // it back on.
            ForEach(collections.library) { collection in
                let on = collections.isGloballyVisible(collection.id)
                HStack(spacing: OrivioSpacing.md) {
                    Button {
                        collections.setGloballyVisible(!on, id: collection.id)
                    } label: {
                        CheckToggleIcon(isOn: on)
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    Button { editing = collection } label: {
                        SettingsActionRow(
                            title: collection.title,
                            subtitle: on
                                ? "\(collection.folders.count) folder\(collection.folders.count == 1 ? "" : "s")"
                                : "Off for all profiles · \(collection.folders.count) folder\(collection.folders.count == 1 ? "" : "s")",
                            leadingIcon: "rectangle.stack.fill"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .opacity(on ? 1 : 0.45)
                }
            }

            if collections.library.isEmpty {
                Text("No collections yet. A collection appears as its own home row of folder tiles — like \"Marvel\" with folders for each phase.")
                    .font(.system(size: 21))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .fullScreenCover(isPresented: $creating) {
            CollectionEditorView(collection: nil) { creating = false }
                .environmentObject(theme)
                .environmentObject(collections)
        }
        .fullScreenCover(item: $editing) { collection in
            CollectionEditorView(collection: collection) { editing = nil }
                .environmentObject(theme)
                .environmentObject(collections)
        }
    }
}

/// Settings → Collections: one account-wide layout for EVERY collection, or
/// Custom to keep each collection's own. Sits above the list because it decides
/// whether the per-collection Layout control inside each editor applies at all.
private struct CollectionLayoutModePicker: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: OrivioSpacing.md) {
            Text("Layout for all collections")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            HStack(spacing: OrivioSpacing.md) {
                ForEach(CollectionLayoutMode.allCases) { mode in
                    Button {
                        collections.globalLayoutMode = mode
                    } label: {
                        FolderTabPill(label: mode.displayName,
                                      selected: collections.globalLayoutMode == mode)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                }
            }
            Text(collections.globalLayoutMode.summary)
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

// MARK: - Collection editor

/// Create/edit one collection: title, folders, and each folder's TMDB / Trakt
/// sources (both need their integration configured — TMDB wants the viewer's
/// own API key. Add-on sources written by other devices are preserved
/// untouched, but they no longer resolve here).
struct CollectionEditorView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var addonManager: AddonManager

    let collection: OrivioCollection?
    let onDone: () -> Void

    @State private var title = ""
    @State private var folders: [OrivioCollectionFolder] = []
    @State private var editingFolder: OrivioCollectionFolder?
    @State private var addingFolder = false
    @State private var pinToTop = false
    @State private var focusGlowEnabled = true
    @State private var showAllTab = true
    @State private var viewMode = "ROWS"
    /// Stable id used for every autosave write (a new collection keeps the same
    /// id across edits instead of creating duplicates).
    @State private var collectionID = ""
    /// Gates autosave until the initial values are loaded, so seeding the
    /// fields in onAppear doesn't immediately write back.
    @State private var didLoad = false
    /// Title edits arrive per keystroke; each store write re-fingerprints Home
    /// and triggers a full catalog reload, so the title autosave is debounced.
    @State private var titlePersistTask: Task<Void, Never>?

    private var isNew: Bool { collection == nil }

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                    Text(isNew ? "New Collection" : "Edit Collection")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    TextField("Collection name", text: $title)
                        .font(.system(size: 26))
                        .frame(maxWidth: 700)

                    SettingsToggleCard(
                        title: "Pin to top of Home",
                        subtitle: "Show this collection's row before the catalogs",
                        isOn: $pinToTop
                    )
                    SettingsToggleCard(
                        title: "Focus glow",
                        subtitle: "Highlight tiles with a soft glow when focused",
                        isOn: $focusGlowEnabled
                    )
                    SettingsToggleCard(
                        title: "\"All\" tab",
                        subtitle: "Show a combined tab alongside each folder's tab in the browser",
                        isOn: $showAllTab
                    )
                    // The per-collection layout only means anything while the
                    // account-wide mode is Custom — otherwise every collection
                    // is forced to one layout and this control would lie.
                    if collections.globalLayoutMode == .custom {
                        CollectionLayoutPicker(viewMode: $viewMode)
                    } else {
                        VStack(alignment: .leading, spacing: OrivioSpacing.sm) {
                            Text("Layout")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(theme.palette.textPrimary)
                            Text("All collections are set to \(collections.globalLayoutMode.displayName) in Settings → Collections. Switch that to Custom to give this one its own layout.")
                                .font(.system(size: 20))
                                .foregroundStyle(theme.palette.textSecondary)
                                .frame(maxWidth: 900, alignment: .leading)
                        }
                    }

                    Text("Folders")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    Button { addingFolder = true } label: {
                        SettingsActionRow(
                            title: "Add Folder",
                            subtitle: "Pick TMDB or Trakt sources to fill it",
                            leadingIcon: "folder.badge.plus"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    ForEach(folders) { folder in
                        HStack(spacing: OrivioSpacing.md) {
                            // Account-wide on/off for this folder. Every profile
                            // inherits it; a profile can hide MORE in Profile
                            // Manager but can't re-enable what's off here — so
                            // this is the shared baseline everyone starts from.
                            Button {
                                collections.setFolderGloballyVisible(
                                    !collections.isFolderGloballyVisible(folder.id), id: folder.id)
                            } label: {
                                CheckToggleIcon(isOn: collections.isFolderGloballyVisible(folder.id))
                            }
                            .buttonStyle(PlainCardButtonStyle())

                            Button { editingFolder = folder } label: {
                                SettingsActionRow(
                                    title: folder.title.isEmpty ? "Untitled folder" : folder.title,
                                    subtitle: collections.isFolderGloballyVisible(folder.id)
                                        ? folderSubtitle(folder)
                                        : "Off for all profiles — " + folderSubtitle(folder),
                                    leadingIcon: "folder.fill"
                                )
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .opacity(collections.isFolderGloballyVisible(folder.id) ? 1 : 0.45)

                            Button(role: .destructive) {
                                folders.removeAll { $0.id == folder.id }
                                persist()
                            } label: {
                                RowControlIcon(icon: "trash")
                            }
                        }
                    }

                    // Changes autosave — no Save button. "Done" flushes any
                    // debounced title edit, then dismisses.
                    HStack(spacing: OrivioSpacing.lg) {
                        Button("Done") {
                            titlePersistTask?.cancel()
                            persist(finalizing: true)
                            onDone()
                        }
                        // Against the LIBRARY, not the visible subset: a
                        // collection switched off for all profiles is exactly
                        // the one with no other way to be deleted.
                        if collections.library.contains(where: { $0.id == collectionID }) {
                            Button("Delete Collection", role: .destructive) {
                                collections.remove(id: collectionID)
                                onDone()
                            }
                        }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, OrivioSpacing.lg)
                }
                .padding(OrivioSpacing.huge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear {
            if let collection {
                collectionID = collection.id
                title = collection.title
                folders = collection.folders
                pinToTop = collection.pinToTop
                focusGlowEnabled = collection.focusGlowEnabled ?? true
                showAllTab = collection.showAllTab
                viewMode = collection.viewMode
            } else if collectionID.isEmpty {
                collectionID = collections.generateID()
            }
            didLoad = true
        }
        // Every field autosaves; scalar changes persist here, folder changes
        // persist at their mutation sites. Title is debounced (see
        // titlePersistTask); Done/dismiss flushes it via the pending task.
        .onChange(of: title) { _, _ in
            titlePersistTask?.cancel()
            titlePersistTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                persist()
            }
        }
        .onChange(of: pinToTop) { _, _ in persist() }
        .onChange(of: focusGlowEnabled) { _, _ in persist() }
        .onChange(of: showAllTab) { _, _ in persist() }
        .onChange(of: viewMode) { _, _ in persist() }
        // Changes are already saved — flush any debounced title edit and dismiss.
        .onExitCommand {
            titlePersistTask?.cancel()
            persist(finalizing: true)
            onDone()
        }
        .fullScreenCover(isPresented: $addingFolder) {
            FolderEditorView(folder: nil) { newFolder in
                if let newFolder { folders.append(newFolder); persist() }
                addingFolder = false
            }
            .environmentObject(theme)
            .environmentObject(addonManager)
        }
        .fullScreenCover(item: $editingFolder) { folder in
            FolderEditorView(folder: folder) { updated in
                if let updated, let index = folders.firstIndex(where: { $0.id == updated.id }) {
                    folders[index] = updated
                    persist()
                }
                editingFolder = nil
            }
            .environmentObject(theme)
            .environmentObject(addonManager)
        }
    }

    /// Upsert the current editor state into the store. A brand-new collection
    /// isn't materialized until it has a name, so opening "New Collection" and
    /// backing straight out doesn't leave an empty row behind.
    /// `finalizing` marks the LAST write of an editing session (Done / Back).
    /// Only then may an unnamed collection take its name from its first
    /// folder: doing it on the autosave path would stamp a name onto the
    /// collection the instant a folder was added, mid-typing.
    private func persist(finalizing: Bool = false) {
        guard didLoad else { return }
        // Never autosave an empty name — mid-retype the field passes through
        // "" and the old Save button refused it too. The last good title holds
        // until a non-empty one is typed.
        var trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, finalizing {
            // Built the folders, never typed a name, pressed Done: name it
            // after what's in it rather than throwing the work away silently.
            trimmed = folders.first { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }?
                .title.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard !trimmed.isEmpty else { return }
        // The LIBRARY copy. Looking the id up in the visible list missed any
        // collection switched off in Settings, so every Back out of its editor
        // treated it as new and appended a duplicate.
        let existing = collections.library.first(where: { $0.id == collectionID })
        var c = existing ?? OrivioCollection(id: collectionID, title: trimmed)
        c.title = trimmed
        c.folders = folders
        c.pinToTop = pinToTop
        c.focusGlowEnabled = focusGlowEnabled
        c.showAllTab = showAllTab
        c.viewMode = viewMode
        // No-op writes (e.g. the onAppear seed round-trip) would still fire the
        // store's change hooks — a spurious account push + full Home reload on
        // every editor open.
        if let existing {
            guard c != existing else { return }
            collections.update(c)
        } else {
            collections.add(c)
        }
    }

    private func folderSubtitle(_ folder: OrivioCollectionFolder) -> String {
        let liveCount = folder.effectiveSources.count - folder.addonSources.count
        guard liveCount > 0 else {
            // Nothing this folder holds can resolve — say so here rather than
            // letting it read as configured and open empty.
            return folder.addonSources.isEmpty ? "No sources" : "No TMDB/Trakt sources"
        }
        return "\(liveCount) TMDB/Trakt source\(liveCount == 1 ? "" : "s")"
    }

}

// MARK: - Folder editor

/// Edit one folder: name and which TMDB / Trakt sources feed it.
///
/// Categories are a TMDB/Trakt feature — there is no add-on catalog picker here
/// any more. Add-on sources on a folder authored elsewhere are kept in storage
/// (so this editor never rewrites the phone's copy) but they no longer resolve.
private struct FolderEditorView: View {
    @EnvironmentObject private var theme: ThemeManager

    let folder: OrivioCollectionFolder?
    let onDone: (OrivioCollectionFolder?) -> Void

    @State private var title = ""
    /// Add-on sources this folder already had, preserved verbatim across a save.
    @State private var legacyAddonSources: [CollectionSourceDTO] = []
    /// The TMDB / Trakt sources this editor actually manages.
    @State private var passthroughSources: [CollectionSourceDTO] = []
    @State private var tileShape = "SQUARE"
    @State private var coverURL = ""
    @State private var showSourcePicker = false
    /// Shown next to Save when there is genuinely nothing to save.
    @State private var saveError: String?

    private static let shapes: [(id: String, label: String)] =
        [("SQUARE", "Square"), ("POSTER", "Poster"), ("LANDSCAPE", "Landscape")]

    var body: some View {
        ZStack {
            ATVBackground()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: OrivioSpacing.xl) {
                    Text(folder == nil ? "New Folder" : "Edit Folder")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    TextField("Folder name", text: $title)
                        .font(.system(size: 26))
                        .frame(maxWidth: 700)

                    Text("TMDB / Trakt Sources")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    Button { showSourcePicker = true } label: {
                        SettingsActionRow(
                            title: "Add TMDB / Trakt Source",
                            subtitle: "Studios, networks, people, discover feeds, or a Trakt list",
                            leadingIcon: "plus.circle.fill"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    // ONE focusable control per row, and the row itself is it.
                    // The label used to be a plain `SettingsActionRow` with a
                    // separate trash button beside it, so the only thing that
                    // could be selected on a source was Delete — "cannot select
                    // Netflix, only delete". Selecting the row is now what
                    // removes it, and the row says so.
                    ForEach(Array(passthroughSources.enumerated()), id: \.offset) { index, source in
                        Button {
                            guard passthroughSources.indices.contains(index) else { return }
                            passthroughSources.remove(at: index)
                        } label: {
                            HStack(spacing: OrivioSpacing.md) {
                                SettingsActionRow(
                                    title: source.title?.isEmpty == false ? source.title! : (source.tmdbSourceType ?? "Trakt List"),
                                    subtitle: (source.isTraktSource ? "Trakt list" : "TMDB \((source.tmdbSourceType ?? "").capitalized)")
                                        + " — select to remove",
                                    leadingIcon: source.isTraktSource ? "checkmark.seal.fill" : "film.fill"
                                )
                                Image(systemName: "trash")
                                    .font(.system(size: 22))
                                    .foregroundStyle(OrivioPrimitives.error)
                            }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }

                    // Tile shape — Square / Poster / Landscape.
                    Text("Tile Shape")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    HStack(spacing: OrivioSpacing.md) {
                        ForEach(Self.shapes, id: \.id) { shape in
                            Button { tileShape = shape.id } label: {
                                ShapeChip(label: shape.label, selected: tileShape == shape.id)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }

                    // Cover image — a high-quality picture used on the tile and
                    // as the collection's background.
                    Text("Cover Image URL")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    TextField("https://…/image.jpg", text: $coverURL)
                        .font(.system(size: 24))
                        .padding(.horizontal, OrivioSpacing.lg)
                        .padding(.vertical, OrivioSpacing.md)
                        .background(theme.palette.field, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
                        .frame(maxWidth: 900)

                    HStack(spacing: OrivioSpacing.lg) {
                        // NEVER `.disabled` here. A disabled tvOS button is not
                        // focusable, and a ScrollView only scrolls when focus
                        // moves — so with the name field left blank (which is
                        // the normal state right after adding a source from the
                        // picker) Save was both unreachable AND unscrollable-to,
                        // which is the "can't scroll down to save" report. The
                        // name is derived from the first source instead, and
                        // `save()` explains itself if there is nothing to name.
                        Button("Save", action: save)
                        Button("Cancel", role: .cancel) { onDone(nil) }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, OrivioSpacing.lg)

                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 20))
                            .foregroundStyle(OrivioPrimitives.error)
                    }
                }
                .padding(OrivioSpacing.huge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear {
            guard let folder else { return }
            title = folder.title
            tileShape = folder.tileShape
            coverURL = folder.coverImageUrl ?? ""
            passthroughSources = folder.effectiveSources.filter { !$0.isAddonSource }
            legacyAddonSources = folder.addonSources
        }
        // Same as Cancel — dismiss without saving.
        .onExitCommand { onDone(nil) }
        .fullScreenCover(isPresented: $showSourcePicker) {
            CollectionSourcePickerView(
                onAdd: { passthroughSources.append($0) },
                onDone: { showSourcePicker = false }
            )
            .environmentObject(theme)
        }
    }

    private func save() {
        // An unnamed folder takes the name of what's in it — "Netflix", not a
        // refusal. Typing a name is still what most people do; this just stops
        // the form from being a dead end when they don't.
        var trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            trimmed = passthroughSources.compactMap { source in
                let candidate = source.title?.trimmingCharacters(in: .whitespaces) ?? ""
                return candidate.isEmpty ? nil : candidate
            }.first ?? ""
        }
        guard !trimmed.isEmpty else {
            saveError = "Give the folder a name, or add a source to name it after."
            return
        }
        saveError = nil
        var result = folder ?? OrivioCollectionFolder(id: UUID().uuidString, title: trimmed, sources: [])
        result.title = trimmed
        // Addon rows ride along untouched: they resolve to nothing here, but
        // dropping them would sync that deletion to every other client.
        result.sources = legacyAddonSources + passthroughSources
        result.catalogSources = legacyAddonSources
        result.tileShape = tileShape
        let trimmedCover = coverURL.trimmingCharacters(in: .whitespaces)
        result.coverImageUrl = trimmedCover.isEmpty ? nil : trimmedCover
        onDone(result)
    }
}

/// Small selectable chip for the tile-shape picker.
private struct ShapeChip: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let label: String
    let selected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 23, weight: .semibold))
            .foregroundStyle(selected ? theme.palette.onSecondary : theme.palette.textSecondary)
            .padding(.horizontal, OrivioSpacing.lg)
            .padding(.vertical, OrivioSpacing.md)
            .background(Capsule().fill(selected ? theme.palette.secondary
                                      : (isFocused ? theme.palette.focusBackground : Color.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
    }
}
