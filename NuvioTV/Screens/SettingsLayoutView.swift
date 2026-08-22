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
                HStack(spacing: NuvioSpacing.md) {
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
            }

            SettingsGroupCard(title: "Posters", subtitle: "Card size and labels across the app") {
                HStack(spacing: NuvioSpacing.md) {
                    ForEach(PosterSize.allCases) { size in
                        Button { settings.posterSize = size } label: {
                            PosterSizeChip(title: size.displayName, selected: settings.posterSize == size)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }

                SettingsToggleCard(
                    title: "Poster labels",
                    subtitle: "Show the title beneath poster cards",
                    isOn: $settings.showPosterLabels
                )

                NuvioDropdown(
                    title: "Corner radius",
                    subtitle: "Roundness of poster card corners",
                    icon: "square.on.square.dashed",
                    selection: String(settings.posterCornerRadius),
                    options: HomeCatalogSettingsStore.posterCornerRadiusValues.map {
                        NuvioDropdownOption(String($0), $0 == 0 ? "Square" : "\($0) pt")
                    }
                ) { settings.posterCornerRadius = Int($0) ?? 12 }

                SettingsToggleCard(
                    title: "Fullscreen hero backdrop",
                    subtitle: "Let the home hero image fill the screen behind the rows",
                    isOn: $settings.fullscreenHero
                )

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
                NuvioDropdown(
                    title: "Sort order",
                    subtitle: settings.continueWatchingSortMode.summary,
                    icon: "arrow.up.arrow.down",
                    selection: settings.continueWatchingSortMode.rawValue,
                    options: ContinueWatchingSortMode.allCases.map {
                        NuvioDropdownOption($0.rawValue, $0.displayName)
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
            .padding(.vertical, NuvioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous).fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : (selected ? theme.palette.secondary : .clear),
                                  lineWidth: isFocused ? 4 : 2)
            )
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isFocused)
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

/// The reorder / rename / show-hide list of home catalog rows. Shared by the
/// Layout pane and the Addons → Catalog Order entry (the APK files catalog
/// order under Add-ons).
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
        let namespaces = addonManager.catalogKeyNamespaces
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addon: addon, catalog: catalog, namespaces: namespaces)
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
        let namespaces = addonManager.catalogKeyNamespaces
        for addon in addonManager.catalogAddons {
            for catalog in (addon.manifest.catalogs ?? []) where !catalog.requiresExtra {
                let key = HomeCatalogSettingsStore.catalogKey(
                    addon: addon, catalog: catalog, namespaces: namespaces)
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

/// Full-screen "Catalog Order" cover opened from the Addons screen. Menu/Back
/// returns to the Addons list.
struct CatalogOrderCoverView: View {
    @EnvironmentObject private var theme: ThemeManager
    let onDone: () -> Void

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            DetailScaffold(title: "Catalog Order", subtitle: "Reorder, rename and hide your home catalog rows") {
                CatalogOrderSection()
            }
        }
        .onExitCommand { onDone() }
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
        VStack(spacing: NuvioSpacing.sm) {
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
        .padding(NuvioSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.background.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
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
        HStack(spacing: NuvioSpacing.lg) {
            Image(systemName: row.isCollection ? "rectangle.stack.fill" : "square.grid.2x2.fill")
                .font(.system(size: 22))
                .foregroundStyle(enabled ? theme.palette.secondary : theme.palette.textTertiary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: NuvioSpacing.sm) {
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
        .padding(.horizontal, NuvioSpacing.lg)
        .frame(minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(focused ? theme.palette.focusBackground
                      : theme.palette.backgroundCard.opacity(enabled ? 0.5 : 0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .strokeBorder(focused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .animation(.easeInOut(duration: 0.15), value: focused)
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
            .scaleEffect(isFocused ? 1.08 : 1)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
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
            theme.palette.background.ignoresSafeArea()
            VStack(spacing: NuvioSpacing.xl) {
                Text("Rename \"\(title)\"")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)

                TextField("Custom title", text: $text)
                    .font(.system(size: 26))
                    .frame(maxWidth: 700)

                HStack(spacing: NuvioSpacing.lg) {
                    Button("Save", action: onSave)
                    Button("Use Default", action: onClear)
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                .font(.system(size: 24, weight: .semibold))
            }
            .padding(NuvioSpacing.huge)
        }
        .onExitCommand { onCancel() }
    }
}

// MARK: - Collections pane

/// Settings → Collections: create and edit collections (custom home rows of
/// folders, each backed by addon catalog sources). Synced whole as a JSON
/// blob via `sync_push_collections`.
struct CollectionsSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @ObservedObject private var perf = PerformanceSettingsStore.shared

    @State private var editing: NuvioCollection?
    @State private var creating = false

    var body: some View {
        DetailScaffold(title: "Collections", subtitle: "Group catalogs into custom home rows") {
            // Focus artwork sits ABOVE the collection list — it applies to all
            // of them, and it's the first thing to reach for when a collection
            // pack feels heavy. (Also mirrored in Settings → Performance.)
            NuvioDropdown(
                title: "Focus artwork",
                subtitle: perf.settings.collectionGifQuality.summary,
                icon: "sparkles.tv",
                selection: perf.settings.collectionGifQuality.rawValue,
                options: CollectionGifQuality.allCases.map {
                    NuvioDropdownOption($0.rawValue, $0.displayName)
                }
            ) { raw in
                perf.settings.collectionGifQuality =
                    CollectionGifQuality(rawValue: raw) ?? .deviceDefault
            }

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
                HStack(spacing: NuvioSpacing.md) {
                    Button {
                        collections.setGloballyVisible(!on, id: collection.id)
                    } label: {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 30))
                            .foregroundStyle(on ? theme.palette.focusRing : theme.palette.textTertiary)
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

// MARK: - Collection editor

/// Create/edit one collection: title, folders, and each folder's addon
/// catalog sources (TMDB/Trakt sources need the #4 integrations; existing
/// ones from other devices are preserved untouched).
struct CollectionEditorView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var addonManager: AddonManager

    let collection: NuvioCollection?
    let onDone: () -> Void

    @State private var title = ""
    @State private var folders: [NuvioCollectionFolder] = []
    @State private var editingFolder: NuvioCollectionFolder?
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
            theme.palette.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
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
                    CollectionLayoutPicker(viewMode: $viewMode)

                    Text("Folders")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    Button { addingFolder = true } label: {
                        SettingsActionRow(
                            title: "Add Folder",
                            subtitle: "Pick catalogs to fill it",
                            leadingIcon: "folder.badge.plus"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    ForEach(folders) { folder in
                        HStack(spacing: NuvioSpacing.md) {
                            // Account-wide on/off for this folder. Every profile
                            // inherits it; a profile can hide MORE in Profile
                            // Manager but can't re-enable what's off here — so
                            // this is the shared baseline everyone starts from.
                            Button {
                                collections.setFolderGloballyVisible(
                                    !collections.isFolderGloballyVisible(folder.id), id: folder.id)
                            } label: {
                                Image(systemName: collections.isFolderGloballyVisible(folder.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 30))
                                    .foregroundStyle(collections.isFolderGloballyVisible(folder.id)
                                                     ? theme.palette.focusRing : theme.palette.textTertiary)
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
                                Image(systemName: "trash").font(.system(size: 22))
                            }
                        }
                    }

                    // Changes autosave — no Save button. "Done" flushes any
                    // debounced title edit, then dismisses.
                    HStack(spacing: NuvioSpacing.lg) {
                        Button("Done") {
                            titlePersistTask?.cancel()
                            persist()
                            onDone()
                        }
                        if collections.collections.contains(where: { $0.id == collectionID }) {
                            Button("Delete Collection", role: .destructive) {
                                collections.remove(id: collectionID)
                                onDone()
                            }
                        }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, NuvioSpacing.lg)
                }
                .padding(NuvioSpacing.huge)
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
            persist()
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
    private func persist() {
        guard didLoad else { return }
        // Never autosave an empty name — mid-retype the field passes through
        // "" and the old Save button refused it too. The last good title holds
        // until a non-empty one is typed.
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let existing = collections.collections.first(where: { $0.id == collectionID })
        var c = existing ?? NuvioCollection(id: collectionID, title: trimmed)
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

    private func folderSubtitle(_ folder: NuvioCollectionFolder) -> String {
        let addonCount = folder.addonSources.count
        let otherCount = folder.effectiveSources.count - addonCount
        var parts: [String] = ["\(addonCount) catalog\(addonCount == 1 ? "" : "s")"]
        if otherCount > 0 { parts.append("\(otherCount) TMDB/Trakt") }
        return parts.joined(separator: " · ")
    }

}

// MARK: - Folder editor

/// Edit one folder: name and which installed addon catalogs feed it.
private struct FolderEditorView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager

    let folder: NuvioCollectionFolder?
    let onDone: (NuvioCollectionFolder?) -> Void

    @State private var title = ""
    @State private var selectedSources: Set<String> = []
    /// Non-addon sources carried through untouched (TMDB/Trakt from Android).
    @State private var passthroughSources: [CollectionSourceDTO] = []
    @State private var tileShape = "SQUARE"
    @State private var coverURL = ""
    @State private var showSourcePicker = false

    private static let shapes: [(id: String, label: String)] =
        [("SQUARE", "Square"), ("POSTER", "Poster"), ("LANDSCAPE", "Landscape")]

    private struct CatalogChoice: Identifiable {
        let source: CollectionSourceDTO
        let label: String
        let addonName: String
        var id: String { "\(source.addonId ?? "")|\(source.type ?? "")|\(source.catalogId ?? "")" }
    }

    private var choices: [CatalogChoice] {
        let all = addonManager.catalogAddons.flatMap { addon in
            (addon.manifest.catalogs ?? [])
                .filter { !$0.requiresExtra }
                .map { catalog in
                    CatalogChoice(
                        source: CollectionSourceDTO(
                            addonId: addon.manifest.id,
                            type: catalog.type,
                            catalogId: catalog.id
                        ),
                        label: catalog.displayName,
                        addonName: addon.manifest.name
                    )
                }
        }
        // A source is identified by manifest id + type + catalog id (the shared
        // wire format), so two installs of the same addon yield the SAME id
        // twice. Rendered as-is that's duplicate ids in a ForEach — the tvOS
        // focus-engine crash — and one row's selection would toggle both.
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                    Text(folder == nil ? "New Folder" : "Edit Folder")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    TextField("Folder name", text: $title)
                        .font(.system(size: 26))
                        .frame(maxWidth: 700)

                    Text("Catalog Sources")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)

                    ForEach(choices) { choice in
                        Button {
                            if selectedSources.contains(choice.id) {
                                selectedSources.remove(choice.id)
                            } else {
                                selectedSources.insert(choice.id)
                            }
                        } label: {
                            HStack(spacing: NuvioSpacing.lg) {
                                Image(systemName: selectedSources.contains(choice.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 26))
                                    .foregroundStyle(selectedSources.contains(choice.id)
                                                     ? theme.palette.secondary : theme.palette.textTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.label)
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(theme.palette.textPrimary)
                                    Text(choice.addonName)
                                        .font(.system(size: 18))
                                        .foregroundStyle(theme.palette.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, NuvioSpacing.lg)
                            .frame(minHeight: 70)
                            .frame(maxWidth: 900)
                            .background(
                                RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                                    .fill(theme.palette.backgroundCard.opacity(0.5))
                            )
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }

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

                    ForEach(Array(passthroughSources.enumerated()), id: \.offset) { index, source in
                        HStack(spacing: NuvioSpacing.md) {
                            SettingsActionRow(
                                title: source.title?.isEmpty == false ? source.title! : (source.tmdbSourceType ?? "Trakt List"),
                                subtitle: source.isTraktSource ? "Trakt list" : "TMDB \((source.tmdbSourceType ?? "").capitalized)",
                                leadingIcon: source.isTraktSource ? "checkmark.seal.fill" : "film.fill"
                            )
                            Button(role: .destructive) {
                                passthroughSources.remove(at: index)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 22))
                            }
                        }
                    }

                    // Tile shape — Square / Poster / Landscape.
                    Text("Tile Shape")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    HStack(spacing: NuvioSpacing.md) {
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
                        .padding(.horizontal, NuvioSpacing.lg)
                        .padding(.vertical, NuvioSpacing.md)
                        .background(theme.palette.field, in: RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
                        .frame(maxWidth: 900)

                    HStack(spacing: NuvioSpacing.lg) {
                        Button("Save", action: save)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel", role: .cancel) { onDone(nil) }
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, NuvioSpacing.lg)
                }
                .padding(NuvioSpacing.huge)
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
            selectedSources = Set(folder.addonSources.map {
                "\($0.addonId ?? "")|\($0.type ?? "")|\($0.catalogId ?? "")"
            })
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
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let picked = choices.filter { selectedSources.contains($0.id) }.map(\.source)
        var result = folder ?? NuvioCollectionFolder(id: UUID().uuidString, title: trimmed, sources: [])
        result.title = trimmed
        result.sources = picked + passthroughSources
        result.catalogSources = picked
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
            .padding(.horizontal, NuvioSpacing.lg)
            .padding(.vertical, NuvioSpacing.md)
            .background(Capsule().fill(selected ? theme.palette.secondary
                                      : (isFocused ? theme.palette.focusBackground : Color.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3))
    }
}
