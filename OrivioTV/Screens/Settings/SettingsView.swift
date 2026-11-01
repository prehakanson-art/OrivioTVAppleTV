import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, appearance, home, content, integrations, playback, subtitles, trackers, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .appearance: return "Appearance"
        case .home: return "Home & Layout"
        case .content: return "Content"
        case .integrations: return "Integrations"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles & Audio"
        case .trackers: return "Trakt & SIMKL"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "circle.lefthalf.filled"
        case .home: return "square.grid.2x2"
        case .content: return "square.on.square"
        case .integrations: return "arrow.left.arrow.right"
        case .playback: return "play.fill"
        case .subtitles: return "captions.bubble"
        case .trackers: return "checkmark.circle"
        case .about: return "info.circle"
        }
    }
}

/// §16.12: Library's two-pane grammar — categories left (account card on
/// top), inset-grouped glass lists right, pickers pushed in the right pane.
struct SettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @ObservedObject private var hub = SyncHub.shared
    @StateObject private var nav = SettingsNav()
    @State private var category: SettingsCategory = .appearance
    /// The page on screen trails `category` by a beat: building a page is ~100–180 ms
    /// on an A10X, and doing it in the same frame as the focus move made every Down
    /// in the list stutter (and scrolling through built every page on the way).
    @State private var shownCategory: SettingsCategory = .appearance
    @State private var paneSwap: Task<Void, Never>?
    @FocusState private var focus: Focus?
    @FocusState private var paneFocus: String?
    private var registry: PaneRowRegistry { nav.registry }
    @State private var navChangedAt = Date.distantPast
    @EnvironmentObject private var router: Router
    @Environment(\.currentTab) private var tab

    enum Focus: Hashable { case category(SettingsCategory) }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            categories
                .frame(width: 400)
            pane
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.leading, Metrics.margin)
        .padding(.trailing, Metrics.margin)
        .padding(.top, 120)
        .pageFrame()
        .environmentObject(nav)
        .onChange(of: nav.focusToken) { _, _ in
            navChangedAt = Date()
            // After a push or pop: the new page's first row, or the row the sub-page was opened from.
            // Read the target now: the engine's own landing would overwrite it.
            let key = pageKey
            let remembered = registry.lastFocused[key]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if let t = remembered ?? registry.first(page: key) { paneFocus = t }
            }
        }
        .onChange(of: paneFocus) { old, f in
            // Arriving from the categories lands on the page's first row (the engine
            // would pick whichever row is level with the category).
            if old == nil, f != nil, shownCategory != category {
                // Came across before the delayed swap: the page under focus is stale.
                enterPane()
                return
            }
            if old == nil, f != nil, Date().timeIntervalSince(navChangedAt) > 0.4,
               let first = registry.first(page: pageKey), f != first {
                DispatchQueue.main.async { paneFocus = first }
                return
            }
            if let f, Date().timeIntervalSince(navChangedAt) > 0.3 { registry.lastFocused[pageKey] = f }
        }
        .onAppear {
            #if DEBUG
            // `-settings integrations` opens a category at launch (simulator checks).
            if let i = CommandLine.arguments.firstIndex(of: "-settings"), i + 1 < CommandLine.arguments.count,
               let c = SettingsCategory(rawValue: CommandLine.arguments[i + 1]) { category = c; shownCategory = c }
            #endif
            if router.tab == .settings { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .category(category) } }
        }
        .onChange(of: router.tab) { _, t in
            if t == .settings { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .category(category) } }
        }
        .onChange(of: focus) { old, f in
            if case .category(let c)? = f, c != category {
                category = c
                paneSwap?.cancel()
                paneSwap = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled else { return }
                    showCategory(c)
                }
            }
        }
        .onChange(of: category) { _, _ in registerMenu() }
        .onAppear { registerMenu() }
        .onDisappear { PageMenuRouter.shared.unregister(tab) }
    }

    /// Left out of the settings pane lands on the categories column rather than
    /// opening the app sidebar (Apple TV sidebar style) or the rail.
    private func registerMenu() {
        let target = category
        PageMenuRouter.shared.register(tab,
                                       isMenuFocused: { focus != nil },
                                       focusMenu: {
            focus = .category(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if focus == nil { focus = .category(target) }
            }
        })
    }

    private var pageKey: String { nav.stack.last?.id.uuidString ?? shownCategory.rawValue }

    private func showCategory(_ c: SettingsCategory) {
        guard c != shownCategory else { return }
        registry.forget(page: shownCategory.rawValue)
        shownCategory = c
        nav.reset()
        registry.lastFocused[c.rawValue] = nil
    }

    /// Into the pane on its first row (the engine would pick the row level with the category).
    private func enterPane() {
        // Select before the delayed swap: show the page now.
        paneSwap?.cancel()
        showCategory(category)
        landFirst(pageKey, tries: 4)
    }

    /// A freshly swapped page registers its rows as they appear, a frame or two later.
    private func landFirst(_ key: String, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 4 ? 0 : 0.05)) {
            if let first = registry.first(page: key) { paneFocus = first }
            else if tries > 0 { landFirst(key, tries: tries - 1) }
        }
    }

    // MARK: Left column

    private var categories: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Button { enterPane() } label: { accountCard }
                    .buttonStyle(FocusCapsuleRowStyle(selected: category == .account, cornerRadius: 28, horizontalPadding: 16, height: 100))
                    .focused($focus, equals: .category(.account))
                    .padding(.bottom, 14)
                ForEach(SettingsCategory.allCases.filter { $0 != .account }) { c in
                    Button { enterPane() } label: {
                        HStack(spacing: 18) {
                            Image(systemName: c.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.white.opacity(0.14)))
                            Text(c.title).font(.system(size: 26, weight: .semibold))
                        }
                    }
                    .buttonStyle(FocusCapsuleRowStyle(selected: category == c, height: 66))
                    .focused($focus, equals: .category(c))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .focusSection()
        .defaultFocus($focus, .category(category))
    }

    private var accountCard: some View {
        let p = profiles.active
        return HStack(spacing: 18) {
            // The profile's picture (it showed only initials here).
            AvatarView(profile: p, size: 64)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.system(size: 28, weight: .bold)).lineLimit(1)
                Text(hub.isSignedIn ? "Orivio account · Signed in" : "Orivio account · Not signed in")
                    .font(.system(size: 19, weight: .medium)).opacity(0.65)
            }
        }
    }

    // MARK: Right pane

    private var pane: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 16) {
                if !nav.stack.isEmpty {
                    Image(systemName: "chevron.left").font(.system(size: 30, weight: .semibold)).opacity(0.6)
                }
                Text(nav.stack.last?.title ?? shownCategory.title).textStyle(.pageTitle)
            }
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if let page = nav.stack.last {
                        page.content().id(page.id)
                    } else {
                        SettingsCategoryPage(category: shownCategory).id(shownCategory)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 80)
            }
            .focusSection()
            .environment(\.settingsPaneFocus, $paneFocus)
            .environment(\.settingsPaneRegistry, registry)
            .environment(\.settingsPageKey, pageKey)
            .onExitCommand {
                if !nav.stack.isEmpty { nav.pop() } else { focus = .category(category) }
            }
        }
    }
}
