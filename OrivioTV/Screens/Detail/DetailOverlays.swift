import SwiftUI

/// Full-screen trailer presented from anywhere.
@MainActor
final class TrailerPresenter: ObservableObject {
    static let shared = TrailerPresenter()
    struct Request: Identifiable { let id = UUID(); let keys: [String] }
    @Published var request: Request?
    func present(keys: [String]) { request = Request(keys: keys) }
}

/// The info popover presented from anywhere (About card "MORE", hero ⓘ).
@MainActor
final class InfoPresenter: ObservableObject {
    static let shared = InfoPresenter()
    @Published var meta: MetaItem?
    func present(_ m: MetaItem) { meta = m }
}

/// ⓘ — centred glass panel 640×620, dark frosted, scrolls vertically.
struct InfoPopover: View {
    let meta: MetaItem
    var model: DetailModel? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: TMDBEnrichment?

    private var e: TMDBEnrichment? { model?.enrichment ?? loaded }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            // tvOS scrolls by moving focus: every block is focusable, so swiping on
            // the remote steps through them and the panel scrolls along.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    InfoBlock {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meta.name).font(.system(size: 28, weight: .bold))
                            Text(([meta.typeLabel] + meta.genres.prefix(3)).joined(separator: " · ")).textStyle(.meta)
                        }
                    }
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                        InfoBlock { Text(p).textStyle(.body).fixedSize(horizontal: false, vertical: true) }
                    }
                    InfoBlock {
                        MetaLine(parts: [meta.year ?? "", (meta.runtimeMinutes ?? e?.runtime).map(MetaItem.formatMinutes) ?? ""], rating: meta.imdbRating)
                    }
                    section("Information", rows: infoRows)
                    section("Languages", rows: languageRows)
                    section("Accessibility", rows: [("CC", "Subtitles are available when the source or a subtitle add-on provides them."),
                                                    ("SDH", "Subtitles for the deaf and hard of hearing, when tagged by the source.")])
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
            }
            .frame(width: 680, height: 660)
            .glassCard(radius: Metrics.popoverRadius, dark: true)
        }
        .onExitCommand { dismiss() }
        .task {
            if model == nil { loaded = await TMDBService.enrichment(for: meta) }
        }
    }

    /// The synopsis split into paragraphs (long ones into ~3-sentence chunks) so
    /// each scroll step moves a readable amount.
    private var paragraphs: [String] {
        guard let d = meta.description ?? e?.overview, !d.isEmpty else { return [] }
        var out: [String] = []
        for para in d.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !para.isEmpty {
            var chunk = ""
            para.enumerateSubstrings(in: para.startIndex..., options: .bySentences) { sub, _, _, _ in
                chunk += sub ?? ""
                if chunk.count > 260 { out.append(chunk.trimmingCharacters(in: .whitespaces)); chunk = "" }
            }
            if !chunk.trimmingCharacters(in: .whitespaces).isEmpty { out.append(chunk.trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    private var infoRows: [(String, String)] {
        var r: [(String, String)] = []
        if let s = e?.companies.first?.name ?? e?.networks.first?.name { r.append(("Studio", s)) }
        if let d = meta.released ?? e?.releaseDate { r.append(("Released", DateParsing.mediumDisplay.string(from: d))) }
        if let rt = meta.runtimeMinutes ?? e?.runtime { r.append(("Run Time", MetaItem.formatMinutes(rt))) }
        if let c = meta.certification ?? e?.certification { r.append(("Rated", c)) }
        if let adv = model?.advisories, !adv.isEmpty { r.append(("Content Advisories", adv.map { "\($0.label) (\($0.severity.label))" }.joined(separator: ", "))) }
        if let c = meta.country ?? e?.countries.first { r.append(("Region of Origin", c)) }
        if let a = meta.awards { r.append(("Awards", a)) }
        return r
    }

    private var languageRows: [(String, String)] {
        var r: [(String, String)] = []
        if let o = e?.originalLanguage { r.append(("Original Audio", Locale.current.localizedString(forLanguageCode: o) ?? o)) }
        if let langs = e?.spokenLanguages, !langs.isEmpty { r.append(("Audio", langs.joined(separator: ", "))) }
        return r
    }

    @ViewBuilder private func section(_ title: String, rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.system(size: 24, weight: .semibold)).padding(.top, 14).padding(.horizontal, 16)
            ForEach(rows, id: \.0) { k, v in
                InfoBlock {
                    HStack(alignment: .top) {
                        Text(k).font(.system(size: 19)).foregroundStyle(Palette.textTertiary).frame(width: 200, alignment: .leading)
                        Text(v).font(.system(size: 21)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A focusable, quietly highlighted block inside the info popover.
struct InfoBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: {}) {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(InfoBlockStyle())
    }
}

struct InfoBlockStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(focused ? 0.12 : 0)))
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// ••• More — a glass popover list.
struct MoreMenu: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let action: () -> Void
    }

    let items: [Item]
    let onClose: () -> Void
    @FocusState private var focused: UUID?
    /// The click that opened the menu also arrives here; ignore presses until it's settled.
    @State private var openedAt = Date()

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        guard Date().timeIntervalSince(openedAt) > 0.5 else { return }
                        onClose()
                        // After the menu has gone, so the action can present its own screen.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { item.action() }
                    } label: {
                        Label(item.title, systemImage: item.systemImage).font(.system(size: 26, weight: .semibold))
                    }
                    .buttonStyle(FocusCapsuleRowStyle(height: 66))
                    .focused($focused, equals: item.id)
                }
            }
            .padding(24)
            .frame(width: 560)
            .glassCard(radius: Metrics.popoverRadius, dark: true)
            .focusSection()
        }
        .onAppear {
            openedAt = Date()
            focused = items.first?.id
        }
        .onExitCommand(perform: onClose)
    }
}

/// Full-screen 1–10 picker with "Clear rating".
struct RatingPicker: View {
    let title: String
    let current: Int?
    let onPick: (Int?) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Int?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 44) {
                Text("Rate \(title)").font(.system(size: 44, weight: .bold))
                HStack(spacing: 16) {
                    ForEach(1...10, id: \.self) { v in
                        Button { onPick(v) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: v <= (current ?? 0) ? "star.fill" : "star").font(.system(size: 30))
                                Text("\(v)").font(.system(size: 30, weight: .bold))
                            }
                            .frame(width: 96, height: 120)
                        }
                        .buttonStyle(GlassCardStyle(radius: 22))
                        .focused($focused, equals: v)
                    }
                }
                Button("Clear rating") { onPick(nil) }.buttonStyle(GlassCapsuleStyle())
                Text("Press Menu to cancel").textStyle(.caption)
            }
        }
        .onAppear { focused = current ?? 7 }
        .onExitCommand(perform: onCancel)
    }
}
