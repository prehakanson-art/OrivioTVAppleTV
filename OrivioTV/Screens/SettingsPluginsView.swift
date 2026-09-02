import SwiftUI

/// Settings → Plugins: install scraper repositories (manifest URL), then toggle
/// individual scrapers. Runs the Orivio JS scrapers alongside Stremio addons on
/// the source page.
struct PluginsSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var plugins: PluginStore
    @State private var repoInput = ""

    var body: some View {
        DetailScaffold(title: SettingsCategory.plugins.title, subtitle: SettingsCategory.plugins.subtitle) {
            SettingsGroupCard(title: "Add repository", subtitle: "Paste a scraper repository manifest URL") {
                HStack(spacing: OrivioSpacing.md) {
                    TextField("https://…/manifest.json", text: $repoInput)
                        .font(.system(size: 22))
                    Button {
                        let url = repoInput.trimmingCharacters(in: .whitespaces)
                        guard !url.isEmpty, !plugins.isBusy else { return }
                        // Guard re-entry here rather than with `.disabled`:
                        // disabling the button the user just pressed removes it
                        // from the tvOS focus tree mid-action and drops focus to
                        // an arbitrary row.
                        guard !plugins.isBusy else { return }
                        Task {
                            await plugins.addRepository(url)
                            if plugins.lastError == nil { repoInput = "" }
                        }
                    } label: {
                        if plugins.isBusy { ProgressView() } else { SeeAllLabel(text: "Add") }
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .disabled(repoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = plugins.lastError {
                    Text(error)
                        .font(.system(size: 18))
                        .foregroundStyle(OrivioPrimitives.error)
                }
                Text("Scrapers run in a sandboxed JS engine. Ones that only call JSON APIs work today; scrapers that parse HTML (cheerio) need that bundled and aren't supported yet. CloudStream (.cs3) extensions are Android-only and can't run on tvOS.")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            if plugins.repositories.isEmpty {
                OrivioEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No plugin repositories",
                    message: "Add a scraper repository above to pull in extra sources."
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ForEach(plugins.repositories) { repo in
                    SettingsGroupCard(title: repo.name, subtitle: repo.url) {
                        SettingsToggleCard(
                            title: "Enable repository",
                            subtitle: "\(repo.scraperCount) scraper\(repo.scraperCount == 1 ? "" : "s")",
                            isOn: Binding(
                                get: { repo.enabled },
                                set: { plugins.setRepositoryEnabled($0, id: repo.id) }
                            )
                        )
                        ForEach(plugins.scrapers.filter { $0.repoID == repo.id }) { scraper in
                            SettingsToggleCard(
                                title: scraper.name,
                                subtitle: "v\(scraper.version) · \(scraper.supportedTypes.joined(separator: ", "))",
                                isOn: Binding(
                                    get: { scraper.enabled },
                                    set: { plugins.setScraperEnabled($0, id: scraper.id) }
                                )
                            )
                        }
                        Button { plugins.removeRepository(repo.id) } label: {
                            SettingsValueCard(title: "Remove repository", subtitle: "Delete this repo and its scrapers", value: "", icon: "trash.fill")
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
            }
        }
    }
}
