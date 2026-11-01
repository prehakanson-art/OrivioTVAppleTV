import SwiftUI

/// Live TV → Guide: a channel × time grid in the right pane (same two-pane
/// layout as the rest of Live TV). Day chips (catch-up days when the provider
/// keeps an archive), a two-hour window with a now line, channel logos down
/// the left. The window pages by itself: Left/Right past its edge lands on an
/// invisible step that moves the window and focuses the next programme — the
/// grid never needs a horizontal scroll view (rows can't share one).
struct LiveGuideView: View {
    /// One shared clock: made inline in `body`, every redraw (each focus move)
    /// re-created and re-subscribed it, restarting the 30 s countdown — the
    /// now-line froze while browsing.
    private static let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Plays a channel; the list is the guide's (channel up/down in the player).
    let watch: (LiveChannel, [LiveChannel]) -> Void
    @ObservedObject private var guide = EPGGuide.shared
    @ObservedObject private var model = LiveTVModel.shared
    @ObservedObject private var reminders = GuideReminders.shared
    @EnvironmentObject private var favorites: LiveChannelFavorites

    @State private var group: GuideGroup?
    @State private var windowStart = LiveGuideView.floor30(Date())
    @State private var now = Date()
    @State private var selection: GuideSelection?
    @State private var showGroups = false
    /// The programme focus was on before it reached a step (where to continue from).
    @State private var lastCell: (channel: String, programme: EPGProgramme?)?
    @FocusState private var focus: GuideFocus?

    static let span: TimeInterval = 2 * 3600
    static let rowHeight: CGFloat = 92
    static let channelColumn: CGFloat = 170
    static let gap: CGFloat = 12

    enum GuideGroup: Hashable {
        case favorites, all, group(String)
        var title: String {
            switch self {
            case .favorites: return "Favorites"
            case .all: return "All Channels"
            case .group(let g): return g
            }
        }
    }

    enum GuideFocus: Hashable {
        case channel(String), cell(String, Int), stepPrev(String), stepNext(String), day(Date), groups
    }

    struct GuideSelection: Identifiable {
        let channel: LiveChannel
        let programme: EPGProgramme?
        var id: String { "\(channel.id)|\(programme?.id ?? -1)" }
    }

    // MARK: Data

    private var currentGroup: GuideGroup {
        if let group { return group }
        if !favorites.ids.isEmpty { return .favorites }
        return model.groups.first.map(GuideGroup.group) ?? .all
    }

    private var channels: [LiveChannel] {
        switch currentGroup {
        case .favorites: return favorites.ids.compactMap { model.channel($0) }
        case .all: return model.channels
        case .group(let g): return model.channels(in: g)
        }
    }

    private var windowEnd: Date { windowStart.addingTimeInterval(Self.span) }
    private static var calendar: Calendar { .current }

    static func floor30(_ d: Date) -> Date {
        let t = d.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 1800).rounded(.down) * 1800)
    }

    /// Catch-up days (the provider's archive) through the last day with listings.
    private var days: [Date] {
        let today = Self.calendar.startOfDay(for: now)
        let archive = channels.compactMap(\.archiveDays).max() ?? 0
        let lastListing = guide.range?.upperBound ?? now
        let ahead = min(3, max(0, Self.calendar.dateComponents([.day], from: today, to: Self.calendar.startOfDay(for: lastListing)).day ?? 0))
        return (-archive...ahead).compactMap { Self.calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private var earliest: Date { days.first ?? Self.calendar.startOfDay(for: now) }
    private var latestStart: Date {
        let lastDayEnd = Self.calendar.date(byAdding: .day, value: 1, to: days.last ?? Self.calendar.startOfDay(for: now)) ?? now
        return lastDayEnd.addingTimeInterval(-Self.span)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let gridWidth = max(400, geo.size.width - Self.channelColumn - Self.gap)
            VStack(alignment: .leading, spacing: 18) {
                header
                dayChips
                ruler(gridWidth: gridWidth)
                if guide.programmes.isEmpty {
                    emptyState
                } else {
                    rows(gridWidth: gridWidth)
                }
            }
        }
        .padding(.trailing, Metrics.margin)
        .task { await model.loadGuideIfNeeded() }
        .onReceive(Self.clock) { now = $0 }
        .onChange(of: focus) { _, f in focusChanged(f) }
        .sheet(isPresented: $showGroups) {
            let options: [GuideGroup] = (favorites.ids.isEmpty ? [] : [.favorites]) + [.all] + model.groups.map(GuideGroup.group)
            OptionPickerSheet(title: "Channels", options: options.map { ($0.title, $0.title) }, selected: currentGroup.title) { v in
                group = options.first { $0.title == v }
                showGroups = false
            }
        }
        .fullScreenCover(item: $selection) { s in
            // Each action runs once the card has gone: presenting the player
            // while this cover is still dismissing left it stuck on "Loading".
            GuideProgrammeCard(selection: s, now: now,
                               watch: { let list = channels; afterClosing { watch(s.channel, list) } },
                               catchup: { p in
                                   afterClosing {
                                       Task {
                                           if let err = await LivePlayback.playCatchup(s.channel, p) {
                                               ToastCenter.shared.show(err, systemImage: "exclamationmark.triangle.fill")
                                           }
                                       }
                                   }
                               },
                               close: { selection = nil })
                .presentationBackground(.clear)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentGroup.title).font(.system(size: 34, weight: .bold)).lineLimit(1)
                Text(metaLine).textStyle(.meta)
            }
            Spacer()
            Button { showGroups = true } label: {
                Label("Channels", systemImage: "chevron.down").labelStyle(TrailingIcon())
            }
            .buttonStyle(GlassCapsuleStyle())
            .focused($focus, equals: .groups)
        }
    }

    private var metaLine: String {
        let viewing = Self.calendar.startOfDay(for: windowStart)
        // The clock only for today; another day shows which day it is.
        let when = Self.calendar.isDateInToday(viewing) ? "Today, \(PlayerTransport.wall.string(from: now))" : dayLabel(viewing)
        var parts = ["\(channels.count) channel\(channels.count == 1 ? "" : "s")", when]
        if guide.loading { parts.append("Updating guide…") }
        else if let u = guide.updated { parts.append("Guide updated \(PlayerTransport.wall.string(from: u))") }
        return parts.joined(separator: " · ")
    }

    private func dayLabel(_ d: Date) -> String {
        if Self.calendar.isDateInToday(d) { return "Today" }
        if Self.calendar.isDateInTomorrow(d) { return "Tomorrow" }
        if Self.calendar.isDateInYesterday(d) { return "Yesterday" }
        return Self.dayChipFormat.string(from: d)
    }

    private static let dayChipFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d")
        return f
    }()

    private var dayChips: some View {
        let selected = Self.calendar.startOfDay(for: windowStart)
        let today = Self.calendar.startOfDay(for: now)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if days.first.map({ $0 < today }) == true {
                    Text("CATCH-UP").textStyle(.eyebrow).padding(.trailing, 6)
                }
                ForEach(days, id: \.self) { d in
                    Button { jump(to: d) } label: { Text(dayLabel(d)) }
                        .buttonStyle(GlassCapsuleStyle(selected: d == selected))
                        .focused($focus, equals: .day(d))
                }
            }
            .padding(.vertical, 10)
        }
        // A horizontal scroll view is greedy vertically; keep it to its row.
        .fixedSize(horizontal: false, vertical: true)
        .scrollClipDisabled()
        .focusSection()
        // Up into the chips lands on the day being shown, not the leftmost chip.
        .defaultFocus($focus, .day(selected), priority: .userInitiated)
    }

    /// Time labels every half hour, with the now marker.
    private func ruler(gridWidth: CGFloat) -> some View {
        let scale = gridWidth / Self.span
        let ticks = (0...Int(Self.span / 1800)).map { windowStart.addingTimeInterval(Double($0) * 1800) }
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.channelColumn + Self.gap)
            ZStack(alignment: .topLeading) {
                ForEach(ticks.dropLast(), id: \.self) { t in
                    let x = CGFloat(t.timeIntervalSince(windowStart)) * scale
                    HStack(spacing: 8) {
                        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 18)
                        Text(PlayerTransport.wall.string(from: t)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    }
                    .offset(x: x)
                }
                if now >= windowStart, now < windowEnd {
                    Rectangle().fill(Palette.live).frame(width: 3, height: 26)
                        .offset(x: CGFloat(now.timeIntervalSince(windowStart)) * scale - 1)
                }
            }
            .frame(width: gridWidth, height: 28, alignment: .topLeading)
        }
        .frame(height: 28)
    }

    private func rows(gridWidth: CGFloat) -> some View {
        let scale = gridWidth / Self.span
        let list = channels
        let first = earliest
        let lastStart = latestStart
        let remindersByChannel = Dictionary(grouping: reminders.items, by: \.channelID)
            .mapValues { Set($0.map(\.start)) }
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(list) { c in
                    row(c, gridWidth: gridWidth, scale: scale, list: list,
                        canPrev: windowStart > first, canNext: windowStart < lastStart,
                        reminders: remindersByChannel[c.id] ?? [])
                }
            }
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// One channel's row — its own Equatable view: built inline, every focus move
    /// (the guide's @FocusState) recomputed and redrew every visible row.
    private func row(_ c: LiveChannel, gridWidth: CGFloat, scale: CGFloat, list: [LiveChannel],
                     canPrev: Bool, canNext: Bool, reminders: Set<Date>) -> some View {
        let progs = guide.programmes(for: c, from: windowStart, to: windowEnd)
        return GuideRowView(channel: c, programmes: progs, windowStart: windowStart, windowEnd: windowEnd,
                            gridWidth: gridWidth, scale: scale, now: Self.floorMinute(now),
                            stepsOn: focusedRow == c.id, canPrev: canPrev, canNext: canNext,
                            favorite: favorites.contains(c.id), hasGuide: guide.hasGuide(for: c),
                            reminders: reminders,
                            focus: $focus,
                            watch: { watch(c, list) },
                            select: { p in selection = GuideSelection(channel: c, programme: p) },
                            toggleFavorite: { favorites.toggle(c.id) })
            .equatable()
    }

    /// Rows only need the clock to the minute (progress bars, past/live/upcoming).
    static func floorMinute(_ d: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            if guide.loading {
                ProgressView().scaleEffect(1.3)
                Text("Loading the guide…").textStyle(.body, color: Palette.textSecondary)
            } else {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 50)).opacity(0.7)
                Text("No guide yet").font(.system(size: 30, weight: .bold))
                Text(guide.error ?? "Your provider or playlist doesn't offer a TV guide. Add a Guide URL (XMLTV) in Settings → Content.")
                    .textStyle(.body, color: Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 760)
                Button("Try Again") {
                    Task { await guide.refresh(channels: model.channels, sources: model.guideSources) }
                }
                .buttonStyle(PrimaryCapsuleStyle(minWidth: 220))
            }
        }
        .padding(50)
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.top, 40)
    }

    // MARK: Focus & paging

    private var focusedRow: String? {
        switch focus {
        case .cell(let c, _), .stepPrev(let c), .stepNext(let c): return c
        default: return nil
        }
    }

    private func focusChanged(_ f: GuideFocus?) {
        switch f {
        case .cell(let cid, let pid):
            let p = model.channel(cid).flatMap { c in guide.programmes(for: c, from: windowStart, to: windowEnd).first { $0.id == pid } }
            lastCell = (cid, p)
        case .stepNext(let cid):
            page(forward: true, channel: cid)
        case .stepPrev(let cid):
            page(forward: false, channel: cid)
        default:
            break
        }
    }

    /// Moves the window past its edge and focuses the next (or previous)
    /// programme in that row.
    private func page(forward: Bool, channel cid: String) {
        guard let c = model.channel(cid) else { return }
        let from = lastCell?.channel == cid ? lastCell?.programme : nil
        let all = guide.programmes(for: c, from: earliest, to: latestStart.addingTimeInterval(Self.span))
        var newStart: Date
        var target: EPGProgramme?
        if forward {
            target = all.first { $0.start >= (from?.end ?? windowEnd) }
            newStart = windowStart.addingTimeInterval(1800)
            if let t = target, t.start >= newStart.addingTimeInterval(Self.span - 1800) {
                newStart = Self.floor30(t.start).addingTimeInterval(-1800)
            }
        } else {
            target = all.last { $0.end <= (from?.start ?? windowStart) }
            newStart = windowStart.addingTimeInterval(-1800)
            if let t = target, t.start < newStart { newStart = Self.floor30(t.start) }
        }
        newStart = min(max(newStart, earliest), latestStart)
        withAnimation(.easeInOut(duration: 0.2)) { windowStart = newStart }
        let goal: GuideFocus = .cell(cid, target.flatMap { t in t.end > newStart && t.start < newStart.addingTimeInterval(Self.span) ? t.id : nil } ?? firstVisibleID(c, forward: forward))
        focusLater(goal, attempt: 0)
    }

    private func firstVisibleID(_ c: LiveChannel, forward: Bool) -> Int {
        let visible = guide.programmes(for: c, from: windowStart, to: windowEnd)
        return (forward ? visible.last : visible.first)?.id ?? -1
    }

    /// The target cell exists only after the window re-renders; keep asking briefly.
    private func focusLater(_ target: GuideFocus, attempt: Int) {
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.1)) {
            guard focus != target else { return }
            focus = target
            focusLater(target, attempt: attempt + 1)
        }
    }

    private func afterClosing(_ action: @escaping () -> Void) {
        selection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    private func jump(to day: Date) {
        let today = Self.calendar.startOfDay(for: now)
        let offset = Self.calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let start = Self.calendar.date(byAdding: .day, value: offset, to: Self.floor30(now)) ?? day
        withAnimation(.easeInOut(duration: 0.2)) { windowStart = min(max(start, earliest), latestStart) }
    }
}

// MARK: - Pieces

private struct GuideChannelCell: View {
    let channel: LiveChannel
    let favorite: Bool

    var body: some View {
        ZStack {
            if let logo = channel.logo {
                RemoteImage(url: logo, maxPixel: 300, contentMode: .fit, placeholder: false)
                    .frame(maxWidth: 120, maxHeight: 56)
            } else {
                Text(channel.name).font(.system(size: 19, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
        .frame(width: LiveGuideView.channelColumn, height: LiveGuideView.rowHeight)
        .overlay(alignment: .topTrailing) {
            if favorite { Image(systemName: "star.fill").font(.system(size: 14)).foregroundStyle(.yellow).padding(8) }
        }
    }
}

/// Guide cells: near-white when focused (dark ink); live ones carry a progress
/// line; past ones are dimmed.
struct GuideCellStyle: ButtonStyle {
    enum Kind: Equatable { case channel, live(Double), past, upcoming, none }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, kind: kind) }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let kind: Kind

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white.opacity(kind == .past || kind == .none ? 0.55 : 0.92))
                .background {
                    ZStack(alignment: .bottomLeading) {
                        shape.fill(focused ? Color.white.opacity(0.92) : Color.white.opacity(fill))
                        if case .live(let p) = kind {
                            GeometryReader { g in
                                Capsule().fill(Palette.positive).frame(width: max(6, g.size.width * p), height: 4)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                            .padding(.horizontal, 6).padding(.bottom, 4)
                        }
                    }
                }
                .scaleEffect(focused ? (configuration.isPressed ? 0.98 : 1.03) : 1)
                .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.35 : 0),
                        radius: PerformanceProfile.isConstrained ? 0 : 12,
                        y: PerformanceProfile.isConstrained ? 0 : 6)
                .zIndex(focused ? 1 : 0)
                .animation(Motion.focus, value: focused)
        }

        private var fill: Double {
            switch kind {
            case .channel: return 0.08
            case .live: return 0.16
            case .upcoming: return 0.10
            case .past, .none: return 0.05
            }
        }
    }
}

/// Select on a programme: what it is and how to watch it.
struct GuideProgrammeCard: View {
    let selection: LiveGuideView.GuideSelection
    let now: Date
    let watch: () -> Void
    /// Plays a programme from the archive (catch-up, or Start Over on one that's on now).
    let catchup: (EPGProgramme) -> Void
    let close: () -> Void
    @EnvironmentObject private var favorites: LiveChannelFavorites
    @ObservedObject private var reminders = GuideReminders.shared
    @FocusState private var primaryFocused: Bool
    /// The click that opened the card also arrives here; ignore presses until it's settled.
    @State private var openedAt = Date()

    private var c: LiveChannel { selection.channel }
    private var p: EPGProgramme? { selection.programme }
    /// Finished and still in the archive.
    private var canCatchUp: Bool { p.map { $0.end <= now && LivePlayback.canPlayFromArchive(c, $0, now: now) } ?? false }
    /// On now, and the archive can play it from its start.
    private var canStartOver: Bool { p.map { $0.isLive(at: now) && LivePlayback.canPlayFromArchive(c, $0, now: now) } ?? false }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 36) {
                    ChannelTile(name: c.name, logo: c.logo, width: 340, height: 192, showsName: false)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(c.group) · \(c.name)".uppercased()).textStyle(.eyebrow).lineLimit(1)
                        Text(p?.title ?? c.name).font(.system(size: 38, weight: .bold)).lineLimit(2)
                        if let p {
                            Text(timeLine(p)).textStyle(.meta)
                            if p.isLive(at: now) {
                                ProgressView(value: p.progress(at: now)).tint(Palette.positive).frame(width: 360)
                            }
                            Text(Self.duration(p.duration)).textStyle(.cardBody, color: Palette.textTertiary)
                        }
                    }
                }
                if let d = p?.desc {
                    Text(d).textStyle(.body, color: Palette.textSecondary).lineLimit(4).frame(maxWidth: 1100, alignment: .leading)
                }
                HStack(spacing: 18) {
                    if canCatchUp, let p {
                        Button { guarded { catchup(p) } } label: { Label("Watch", systemImage: "play.fill") }
                            .buttonStyle(PrimaryCapsuleStyle(minWidth: 220))
                            .focused($primaryFocused)
                        Button { guarded(watch) } label: { Label("Watch Live", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                    } else if canStartOver, let p {
                        Button { guarded(watch) } label: { Label("Watch Live", systemImage: "play.fill") }
                            .buttonStyle(PrimaryCapsuleStyle(minWidth: 240))
                            .focused($primaryFocused)
                        Button { guarded { catchup(p) } } label: { Label("Start Over", systemImage: "backward.end.fill") }
                            .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                    } else if let p, p.start > now {
                        let set = reminders.has(c.id, p)
                        Button { guarded { reminders.toggle(c, p) } } label: {
                            Label(set ? "Reminder Set" : "Remind Me", systemImage: set ? "bell.fill" : "bell")
                        }
                        .buttonStyle(PrimaryCapsuleStyle(minWidth: 240))
                        .focused($primaryFocused)
                        Button { guarded(watch) } label: { Label("Watch Live", systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                    } else {
                        Button { guarded(watch) } label: { Label("Watch Live", systemImage: "play.fill") }
                            .buttonStyle(PrimaryCapsuleStyle(minWidth: 240))
                            .focused($primaryFocused)
                    }
                    Button { guarded { favorites.toggle(c.id) } } label: {
                        Label(favorites.contains(c.id) ? "Favorited" : "Favorite", systemImage: favorites.contains(c.id) ? "star.fill" : "star")
                    }
                    .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                }
                if let p, p.end <= now, !canCatchUp {
                    Text("Catch-up isn't available for this channel.").textStyle(.cardBody, color: Palette.textTertiary)
                }
            }
            .padding(44)
            .frame(width: 1300, alignment: .leading)
            // A solid base under the glass: on a real TV the guide read through it.
            .background(RoundedRectangle(cornerRadius: Metrics.popoverRadius, style: .continuous).fill(Palette.navBase.opacity(0.88)))
            .glassCard(radius: Metrics.popoverRadius, dark: true)
            .focusSection()
        }
        .onAppear {
            openedAt = Date()
            primaryFocused = true
        }
        .onExitCommand(perform: close)
    }

    private func guarded(_ action: @escaping () -> Void) {
        guard Date().timeIntervalSince(openedAt) > 0.5 else { return }
        action()
    }

    private func timeLine(_ p: EPGProgramme) -> String {
        let range = "\(PlayerTransport.wall.string(from: p.start)) – \(PlayerTransport.wall.string(from: p.end))"
        if p.isLive(at: now) { return "\(range) · \(Self.duration(p.end.timeIntervalSince(now))) left" }
        if p.start > now { return "\(range) · starts in \(Self.duration(p.start.timeIntervalSince(now)))" }
        return "\(range) · ended"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = max(1, Int((t / 60).rounded()))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// Settings → Content → TV Guide.
struct GuideSettingsGroup: View {
    @EnvironmentObject private var liveTV: LiveTVSettingsStore
    @ObservedObject private var guide = EPGGuide.shared

    var body: some View {
        SettingsGroup(header: "TV guide",
                      footer: "XMLTV (.xml or .xml.gz). Leave empty to use the guide your IPTV provider or playlist offers.") {
            TextEntryRow(label: "Guide URL", text: $liveTV.value.epgURL, placeholder: "https://…/guide.xml.gz", keyboard: .URL)
            SettingsRow(label: "Refresh guide", value: status, icon: "arrow.clockwise") {
                Task {
                    let model = LiveTVModel.shared
                    await model.loadIfNeeded()
                    await guide.refresh(channels: model.channels, sources: model.guideSources)
                }
            }
        }
    }

    private var status: String {
        if guide.loading { return "Updating…" }
        if let u = guide.updated { return "Updated \(PlayerTransport.wall.string(from: u))" }
        return guide.error == nil ? "" : "Not available"
    }
}

/// A guide reminder firing: the programme is starting.
struct ReminderPrompt: View {
    let reminder: GuideReminder
    let close: () -> Void
    @FocusState private var watchFocused: Bool
    @State private var openedAt = Date()

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 18) {
                Label("Starting now", systemImage: "bell.fill").textStyle(.eyebrow)
                Text(reminder.title).font(.system(size: 40, weight: .bold)).lineLimit(2)
                Text("\(reminder.channelName) · \(PlayerTransport.wall.string(from: reminder.start)) – \(PlayerTransport.wall.string(from: reminder.end))")
                    .textStyle(.meta)
                HStack(spacing: 18) {
                    Button {
                        guard Date().timeIntervalSince(openedAt) > 0.5 else { return }
                        let id = reminder.channelID
                        close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            Task {
                                guard let c = LiveTVModel.shared.channel(id) else { return }
                                if let err = await LivePlayback.play(c) { ToastCenter.shared.show(err, systemImage: "exclamationmark.triangle.fill") }
                            }
                        }
                    } label: { Label("Watch Now", systemImage: "play.fill") }
                        .buttonStyle(PrimaryCapsuleStyle(minWidth: 240))
                        .focused($watchFocused)
                    Button { guard Date().timeIntervalSince(openedAt) > 0.5 else { return }; close() } label: { Text("Dismiss") }
                        .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 28, height: 64))
                }
                .padding(.top, 10)
            }
            .padding(44)
            .frame(width: 1000, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.popoverRadius, style: .continuous).fill(Palette.navBase.opacity(0.88)))
            .glassCard(radius: Metrics.popoverRadius, dark: true)
            .focusSection()
        }
        .onAppear { openedAt = Date(); watchFocused = true }
        .onExitCommand(perform: close)
    }
}

/// A guide row: channel cell, programme cells in the window, and the invisible
/// paging steps. Compared by its data (not the focus binding or callbacks).
struct GuideRowView: View, Equatable {
    let channel: LiveChannel
    let programmes: [EPGProgramme]
    let windowStart: Date
    let windowEnd: Date
    let gridWidth: CGFloat
    let scale: CGFloat
    let now: Date
    let stepsOn: Bool
    let canPrev: Bool
    let canNext: Bool
    let favorite: Bool
    let hasGuide: Bool
    let reminders: Set<Date>
    var focus: FocusState<LiveGuideView.GuideFocus?>.Binding
    let watch: () -> Void
    let select: (EPGProgramme?) -> Void
    let toggleFavorite: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.channel == b.channel && a.programmes == b.programmes && a.windowStart == b.windowStart && a.windowEnd == b.windowEnd
            && a.gridWidth == b.gridWidth && a.now == b.now && a.stepsOn == b.stepsOn && a.canPrev == b.canPrev
            && a.canNext == b.canNext && a.favorite == b.favorite && a.hasGuide == b.hasGuide && a.reminders == b.reminders
    }

    var body: some View {
        HStack(spacing: LiveGuideView.gap) {
            Button(action: watch) { GuideChannelCell(channel: channel, favorite: favorite) }
                .buttonStyle(GuideCellStyle(kind: .channel))
                .focused(focus, equals: .channel(channel.id))
                .contextMenu {
                    Button(action: toggleFavorite) {
                        Label(favorite ? "Remove from Favorites" : "Favorite", systemImage: favorite ? "star.slash" : "star")
                    }
                }
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: gridWidth, height: LiveGuideView.rowHeight)
                // Invisible steps just outside the window (only on the focused
                // row, so Right from a logo never pages back by accident).
                if canPrev {
                    step(.stepPrev(channel.id)).offset(x: -6).disabled(!stepsOn)
                }
                if programmes.isEmpty {
                    cell(nil, x: 0, width: gridWidth - 4)
                } else {
                    ForEach(programmes) { p in
                        let s = max(p.start, windowStart), e = min(p.end, windowEnd)
                        let x = CGFloat(s.timeIntervalSince(windowStart)) * scale
                        let w = max(24, CGFloat(e.timeIntervalSince(s)) * scale - 4)
                        cell(p, x: x, width: w)
                    }
                }
                if canNext {
                    step(.stepNext(channel.id)).offset(x: gridWidth + 4).disabled(!stepsOn)
                }
            }
            .frame(width: gridWidth, height: LiveGuideView.rowHeight, alignment: .topLeading)
        }
    }

    private func cell(_ p: EPGProgramme?, x: CGFloat, width: CGFloat) -> some View {
        let kind: GuideCellStyle.Kind = p.map { $0.isLive(at: now) ? .live($0.progress(at: now)) : ($0.end <= now ? .past : .upcoming) } ?? .none
        return Button { select(p) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let p, reminders.contains(p.start) {
                        Image(systemName: "bell.fill").font(.system(size: 16))
                    }
                    Text(p?.title ?? (hasGuide ? "No listings" : "No programme information"))
                        .font(.system(size: 22, weight: .semibold)).lineLimit(1)
                }
                if let p {
                    Text("\(PlayerTransport.wall.string(from: p.start)) – \(PlayerTransport.wall.string(from: p.end))")
                        .font(.system(size: 18)).opacity(0.6).lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: LiveGuideView.rowHeight, alignment: .leading)
        }
        .buttonStyle(GuideCellStyle(kind: kind))
        .focused(focus, equals: .cell(channel.id, p?.id ?? -1))
        .offset(x: x)
    }

    private func step(_ f: LiveGuideView.GuideFocus) -> some View {
        Button {} label: { Color.clear.frame(width: 1, height: LiveGuideView.rowHeight) }
            .buttonStyle(BareFocusStyle())
            .focused(focus, equals: f)
    }
}
