import SwiftUI

/// One row of a full-screen picker.
struct InfuseRow: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var badges: [String] = []
    var checked = false
}

/// §7.13 full-screen picker: dimmed glass backdrop, title 53 pt white 45 % at
/// 100 pt from the top, rows 600 pt wide (1100 with subtitles), focused =
/// white 93 % with black text; opens on the selected row.
struct InfusePicker: View {
    let title: String
    let rows: [InfuseRow]
    var emptyText: String = "Nothing here"
    var focus: FocusState<PlayerFocus?>.Binding
    let onSelect: (String) -> Void

    private var wide: Bool { rows.contains { $0.subtitle != nil } }

    var body: some View {
        ZStack(alignment: .top) {
            GlassSurface(shape: Rectangle(), dark: true)
            Color.black.opacity(0.45)
            VStack(spacing: 40) {
                Text(title)
                    .font(.system(size: 53, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 100)
                if rows.isEmpty {
                    Spacer()
                    Text(emptyText).font(.system(size: 32, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(rows) { r in
                                    Button { onSelect(r.id) } label: { label(r) }
                                        .buttonStyle(PickerRowStyle(width: wide ? 1100 : 600))
                                        .focused(focus, equals: .picker(r.id))
                                        .id(r.id)
                                }
                            }
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                        }
                        .onAppear {
                            let target = rows.first(where: \.checked)?.id ?? rows.first?.id
                            guard let target else { return }
                            proxy.scrollTo(target, anchor: .center)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focus.wrappedValue = .picker(target) }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func label(_ r: InfuseRow) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title).font(.system(size: 29, weight: .semibold)).lineLimit(2)
                if let s = r.subtitle {
                    Text(s).font(.system(size: 22, weight: .medium)).opacity(0.65).lineLimit(2)
                }
                if !r.badges.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(r.badges, id: \.self) { b in
                            Text(b).font(.system(size: 17, weight: .bold))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5).opacity(0.6))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if r.checked { Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)) }
        }
    }
}

struct PickerRowStyle: ButtonStyle {
    let width: CGFloat
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, width: width) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let width: CGFloat
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(width: width, alignment: .leading)
                .frame(minHeight: 67)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(focused ? 0.93 : 0.12))
                }
                .scaleEffect(focused ? 1.03 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Layer 11: Sources, Episodes, Speed, Engine (reached from the info sheet, Up Next or the error card).
struct PlayerPickers: View {
    @ObservedObject var vm: PlayerViewModel
    var focus: FocusState<PlayerFocus?>.Binding

    var body: some View {
        switch vm.overlay {
        case .sources: sources
        case .episodes: episodes
        case .speed:
            InfusePicker(title: "Playback Speed",
                         rows: PlaybackSpeed.steps.map { InfuseRow(id: "\($0)", title: PlaybackSpeed.label($0), checked: $0 == vm.speed) },
                         focus: focus) { id in
                if let v = Float(id) { vm.setSpeed(v) }
                back()
            }
        case .engine:
            InfusePicker(title: "Engine", rows: engineRows, focus: focus) { id in
                if id == "auto" { vm.switchEngine(vm.chooseEngine()) } else if let k = EngineKind(rawValue: id) { vm.switchEngine(k) }
            }
        case .channels:
            InfusePicker(title: "Channels", rows: channelRows, focus: focus) { id in
                if id == Self.startOverID { vm.startOver(); return }
                guard let c = vm.liveChannels.first(where: { $0.id == id }) else { return }
                if c.id == vm.meta.id { back() } else { vm.switchChannel(to: c) }
            }
        default: EmptyView()
        }
    }

    static let startOverID = "__startover"

    /// The mini guide: each channel with what's on now (and a Start Over row
    /// when the current programme can be replayed from the archive).
    private var channelRows: [InfuseRow] {
        let now = Date()
        var rows: [InfuseRow] = []
        if let p = vm.startOverProgramme {
            rows.append(InfuseRow(id: Self.startOverID, title: "Start Over", subtitle: "\(p.title) · from \(PlayerTransport.wall.string(from: p.start))"))
        }
        rows += vm.liveChannels.map { c in
            let nn = EPGGuide.shared.nowNext(for: c, at: now)
            let sub = nn.now.map { p in
                "\(p.title) · \(PlayerTransport.wall.string(from: p.start))–\(PlayerTransport.wall.string(from: p.end))"
                    + (nn.next.map { " · Next: \($0.title)" } ?? "")
            }
            return InfuseRow(id: c.id, title: c.name, subtitle: sub, checked: c.id == vm.meta.id)
        }
        return rows
    }

    private func back() {
        vm.overlay = vm.returnOverlay ?? .none
        vm.returnOverlay = nil
    }

    private var engineRows: [InfuseRow] {
        var rows = [InfuseRow(id: "auto", title: "Auto", subtitle: "Native for MP4/HLS, FFmpeg for everything else")]
        for k in [EngineKind.native, .ffmpeg, .vlc] {
            rows.append(InfuseRow(id: k.rawValue, title: k.label, checked: vm.engineKind == k))
        }
        return rows
    }

    private var sources: some View {
        let entries = vm.pickingNextSource ? vm.nextEntries : vm.allEntries
        let searching = vm.pickingNextSource ? (vm.nextSourceSearch?.isComplete == false) : (vm.alternativesSearch?.isComplete == false)
        let title = vm.pickingNextSource ? "Sources for \(vm.nextVideo?.seasonEpisodeCode ?? "Next Episode")" : "Sources"
        return InfusePicker(title: title, rows: entries.map { e in sourceRow(e) },
                            emptyText: searching ? "Searching sources…" : "No sources found", focus: focus) { id in
            guard let e = entries.first(where: { $0.id == id }) else { return }
            if vm.pickingNextSource { vm.chooseNextSource(e); return }
            if e.id == vm.entry.id { back(); return }
            vm.returnOverlay = nil
            vm.switchSource(to: e)
        }
    }

    private func sourceRow(_ e: StreamEntry) -> InfuseRow {
        var detail = [e.sourceAddonName]
        if !e.displayDetail.isEmpty, e.displayDetail != e.displayName { detail.append(e.displayDetail) }
        if let r = e.resolutionLabel { detail.append(r) }
        if let s = e.fileSizeLabel { detail.append(s) }
        var badges = e.badges
        if e.isInstant { badges.insert("⚡ Cached", at: 0) }
        if let d = e.traits.debridShort { badges.append(d) }
        return InfuseRow(id: e.id, title: e.displayName, subtitle: detail.joined(separator: " · "), badges: badges,
                         checked: !vm.pickingNextSource && e.id == vm.entry.id)
    }

    private var episodes: some View {
        InfusePicker(title: vm.video?.season.map { "Season \($0)" } ?? "Episodes",
                     rows: vm.episodeList.map { v in
                         InfuseRow(id: v.id, title: "\(v.episode ?? 0). \(v.title.isEmpty ? "Episode \(v.episode ?? 0)" : v.title)",
                                   subtitle: v.overview.map { String($0.prefix(140)) }, checked: v.id == vm.video?.id)
                     },
                     emptyText: "The episode list hasn't loaded yet", focus: focus) { id in
            guard let v = vm.episodeList.first(where: { $0.id == id }) else { return }
            if v.id == vm.video?.id { back(); return }
            vm.returnOverlay = nil
            vm.playEpisode(v)
        }
    }
}
