import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case search, home, discover, movies, shows, liveTV, library, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search"
        case .home: return "Home"
        case .discover: return "Discover"
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .library: return "Library"
        case .liveTV: return "Live TV"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house.fill"
        case .discover: return "safari.fill"
        case .movies: return "film.fill"
        case .shows: return "play.tv.fill"
        case .library: return "books.vertical.fill"
        case .liveTV: return "dot.radiowaves.left.and.right"
        case .settings: return "gearshape.fill"
        }
    }

    /// Apple puts Search first, then Home.
    static func visible(liveTV: Bool) -> [AppTab] {
        [.search, .home, .discover, .movies, .shows] + (liveTV ? [.liveTV] : []) + [.library, .settings]
    }
}

/// How the Sources page behaves for a given entry point.
enum StreamsMode: Hashable {
    case normal
    /// Always show the list, even with auto-select on.
    case manual
    /// Auto-pick, then hand to Infuse.
    case infuse
    case fromStart
    /// Continue Watching resume: re-scrape and auto-play the link matching what was last watched.
    case resume(fromStart: Bool)
    case shuffle
}

struct StreamsRequest: Hashable {
    var meta: MetaItem
    var video: MetaVideo?
    var mode: StreamsMode = .normal
}

enum Route: Hashable {
    case detail(MetaItem, siblings: [MetaItem] = [])
    case streams(StreamsRequest)
    case collection(String)
    case person(Int, String)
    case tmdbCompany(Int, String, isNetwork: Bool)
    case tmdbCollection(Int, String)
    case catalogSeeAll(addonURL: String, catalog: ManifestCatalog, title: String)
    case discover(type: String?, genre: String?)
    case cloudLibrary
    case mediaServerLibrary(serverID: String, libraryID: String, title: String)
    case mediaServerShow(serverID: String, itemID: String, title: String)
}

/// Per-tab navigation stacks.
@MainActor
final class Router: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var paths: [AppTab: [Route]] = [:]

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    func push(_ route: Route) {
        paths[tab, default: []].append(route)
    }

    func pop() {
        guard !(paths[tab] ?? []).isEmpty else { return }
        paths[tab]?.removeLast()
    }

    var isAtRoot: Bool { (paths[tab] ?? []).isEmpty }

    func popToRoot(_ t: AppTab? = nil) { paths[t ?? tab] = [] }
}

/// What the player is asked to play.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    var meta: MetaItem
    var video: MetaVideo?
    var entry: StreamEntry
    var allEntries: [StreamEntry]
    var resumePosition: Double?
    var forceDemuxer = false
    var shuffle = false
    /// Resolved playable URL (after debrid / TorrServer).
    var url: URL
    var headers: [String: String] = [:]
    var isLive = false
    /// Plex / Jellyfin: each episode's own file, so Up Next skips the add-on search.
    var directEpisodes: [String: StreamEntry]? = nil
    /// Live TV: the list this channel was picked from (channel up/down, the mini guide).
    var liveChannels: [LiveChannel]? = nil
}

@MainActor
final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()
    /// Live TV plays in this app's own player (channel up/down, the Channels
    /// list, Start Over)…
    @Published var request: PlaybackRequest?
    /// …everything else in the Classic player (the old app's).
    @Published var classicRequest: ClassicPlaybackRequest?
    /// A Classic cover re-presented by Picture in Picture's restore (not a new start).
    var classicRestoredID: UUID?
    /// The view model kept alive while Picture in Picture runs.
    var parkedModel: AnyObject?

    /// Either player is on screen.
    var isPresenting: Bool { request != nil || classicRequest != nil }

    func present(_ r: PlaybackRequest) {
        // Starting another playback stops Picture in Picture first.
        if let parked = parkedModel as? PlayerViewModel {
            parked.saveProgress(transient: false)
            parked.stopPiP()
            parked.teardown()
            parkedModel = nil
        }
        if PiPHandoff.shared.isActive {
            PiPHandoff.shared.viewModel?.pictureInPicture.stop()
            PiPHandoff.shared.finish()
            ClassicScrobbler.shared.stop()
        }
        if r.isLive || r.liveChannels != nil || r.meta.type == "tv" || r.meta.type == "channel" || r.meta.type == "recording" {
            request = r
        } else {
            classicRequest = ClassicPlaybackRequest(r)
        }
    }
}

/// Where Right/Back out of the nav lands: the row the viewer was in (its first card).
@MainActor
final class ContentFocusRouter: ObservableObject {
    /// Makes the side rail/top bar unfocusable for a moment (set by the shell; a
    /// plain callback, not published). A page that swaps out its focused view —
    /// Detail paging between titles — calls it first, or the focus engine hands
    /// focus to the rail for a frame and the rail's "focus left the nav" landing
    /// re-ran the tab root's focus logic under the page on every swap.
    var holdNav: (() -> Void)?
    /// Keeps the rail unfocusable while true (Detail's card, where Left pages
    /// to the previous title: the engine moved focus into the rail first, so it
    /// flashed open on every Left).
    var blockNav: ((Bool) -> Void)?
    struct Landing: Equatable {
        /// The tab whose row should take focus (the same row can exist in several tabs).
        var tab: AppTab? = nil
        let rowID: String
        /// Land on the card closest to this screen x (nil = the first card).
        var x: CGFloat? = nil
        /// Or on this card index (restoring focus after Back).
        var index: Int? = nil
        let token = UUID()
    }

    /// Screen x of the focused card's centre (for vertical moves between rows).
    var focusedMidX: CGFloat?
    /// Screen frame of the focused card — where the Detail page zooms out of —
    /// and that card's item id (so a page opened from elsewhere never zooms
    /// out of a stale card).
    var focusedFrame: CGRect?
    var focusedItem: String?

    /// The focused card's frame, if that card is this title (`cw:<id>`-style
    /// row ids included).
    func cardFrame(for metaID: String) -> CGRect? {
        guard let f = focusedFrame, let item = focusedItem,
              item == metaID || item.hasSuffix(":" + metaID) else { return nil }
        return f
    }

    /// A Detail page shrinking back into the card it came from, drawn by the
    /// tab over its root as the page fades away.
    struct ZoomBack: Equatable {
        let id = UUID()
        let tab: AppTab
        /// The card's image and the page's backdrop.
        let start: UIImage?
        let end: UIImage?
        /// Screen frames: the card it lands on, the page card it leaves.
        let card: CGRect
        let page: CGRect
        static func == (a: ZoomBack, b: ZoomBack) -> Bool { a.id == b.id }
    }
    @Published var zoomBack: ZoomBack?

    /// The row that last held focus, per tab.
    private(set) var lastRow: [AppTab: String] = [:]
    /// The index of the focused card in that row (Back scrolls a row to its start first).
    private(set) var lastIndex: [String: Int] = [:]
    @Published var landing: Landing? {
        didSet {
            #if DEBUG
            if Self.traceLandings, let l = landing {
                let callers = Thread.callStackSymbols.dropFirst(1).filter { $0.contains("OrivioTV ") }.prefix(4)
                    .map { $0.split(separator: " ").dropFirst(3).first.map(String.init) ?? "?" }
                DebugLog.write("[landing] \(l.rowID) tab=\(l.tab.map { "\($0)" } ?? "-") from \(callers.joined(separator: " ← "))")
            }
            #endif
        }
    }
    #if DEBUG
    private static let traceLandings = CommandLine.arguments.contains("-traceFocus")
    #endif
    @Published var resetRow: Landing?

    /// When focus last moved between tracked items (to tell a failed move from a real one).
    private(set) var lastFocusAt = Date.distantPast

    func noteFocus(tab: AppTab, rowID: String, index: Int) {
        lastRow[tab] = rowID
        lastIndex[rowID] = index
        lastFocusAt = Date()
    }

    /// Lands on the remembered row of a tab, or its first row.
    func land(tab: AppTab, fallbackRow: String?) {
        if let row = lastRow[tab] { landing = Landing(tab: tab, rowID: row) } else if let r = fallbackRow { landing = Landing(tab: tab, rowID: r) }
    }

    /// The pseudo-row for the top of a page (Home's hero buttons).
    static let topRow = "__top"

    /// Lands on the remembered row of a tab — or the top of the page when
    /// nothing was focused there yet (so leaving the nav never strands focus).
    func land(tab: AppTab) {
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[router] land(tab:) \(tab) lastRow=\(lastRow[tab] ?? "-")") }
        #endif
        landing = Landing(tab: tab, rowID: lastRow[tab] ?? Self.topRow)
    }

    /// The root's focused card when the first page was pushed over it. Rows on
    /// pushed pages (Detail's sections) report to the same tab, so without this
    /// Back would try to land on a row that only existed on the page.
    private var rootFocus: [AppTab: (row: String, index: Int?)] = [:]
    /// …and that card's frame and item id (what a Detail page shrinks back into,
    /// even after pages pushed over it rebuilt it).
    private var rootCard: [AppTab: (frame: CGRect, item: String)] = [:]

    func noteLeftRoot(tab: AppTab) {
        rootFocus[tab] = lastRow[tab].map { ($0, lastIndex[$0]) }
        if let f = focusedFrame, let item = focusedItem { rootCard[tab] = (f, item) } else { rootCard[tab] = nil }
    }

    /// The root card a page for `metaID` opened from, if that's where it came from.
    func rootCardFrame(tab: AppTab, metaID: String) -> CGRect? {
        guard let c = rootCard[tab], c.item == metaID || c.item.hasSuffix(":" + metaID) else { return nil }
        return c.frame
    }

    /// Back from a pushed page: focus the exact card that was focused.
    func restore(tab: AppTab) {
        rootCard[tab] = nil
        if let r = rootFocus.removeValue(forKey: tab) {
            lastRow[tab] = r.row
            if let i = r.index { lastIndex[r.row] = i }
        }
        guard let row = lastRow[tab] else { return }
        landing = Landing(tab: tab, rowID: row, index: lastIndex[row])
    }

    func land(row: String, x: CGFloat?, tab: AppTab) {
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[router] land(row:) \(row) x=\(x.map { "\(Int($0))" } ?? "-") tab=\(tab)") }
        #endif
        landing = Landing(tab: tab, rowID: row, x: x)
    }

    /// Back from Sources/the player: land on the exact card the viewer
    /// entered (an episode), not just the row's first card. `landing`'s index
    /// is what `FocusRow` uses to pick the card.
    func land(row: String, index: Int, tab: AppTab) {
        #if DEBUG
        if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[router] land(row:) \(row) index=\(index) tab=\(tab)") }
        #endif
        landing = Landing(tab: tab, rowID: row, index: index)
    }

    /// Back at a tab root: first scroll the current row back to its start.
    /// Returns true if that happened (so the nav should not open yet).
    func resetCurrentRowIfNeeded(tab: AppTab) -> Bool {
        guard let row = lastRow[tab], (lastIndex[row] ?? 0) > 0 else { return false }
        lastIndex[row] = 0
        resetRow = Landing(tab: tab, rowID: row)
        return true
    }
}

/// Brief rail holds (a page swapping out its focused view) and blocks (a
/// focused view whose Left is its own). Observed by the rail alone.
@MainActor
final class NavGate: ObservableObject {
    @Published private(set) var held = false
    @Published private(set) var blocked = false
    private var generation = 0

    func hold(for seconds: Double = 0.6) {
        generation += 1
        let g = generation
        if !held { held = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.generation == g { self?.held = false }
        }
    }

    func setBlocked(_ b: Bool) { if blocked != b { blocked = b } }
}

extension Notification.Name {
    /// Left/Back inside a page's content: return focus to that page's own menu
    /// instead of opening the app sidebar.
    static let orivioReturnToTabMenu = Notification.Name("orivio.returnToTabMenu")
}

/// Pages with a second, in-page column on their left (Library's sections,
/// Settings' categories, Live TV's list). A failed Left inside the right-hand
/// content must land on that column first; only a Left *from* the column may
/// open the app's sidebar/rail. Without this, the focus engine's failed move
/// went straight to the shell and the sidebar opened from the first poster.
@MainActor
final class PageMenuRouter {
    static let shared = PageMenuRouter()

    struct Entry {
        /// Whether the page's own menu currently holds focus.
        var isMenuFocused: () -> Bool
        /// Move focus onto the page's menu.
        var focusMenu: () -> Void
    }

    private var entries: [AppTab: Entry] = [:]

    func register(_ tab: AppTab,
                  isMenuFocused: @escaping () -> Bool,
                  focusMenu: @escaping () -> Void) {
        entries[tab] = Entry(isMenuFocused: isMenuFocused, focusMenu: focusMenu)
    }

    func unregister(_ tab: AppTab) {
        entries.removeValue(forKey: tab)
    }

    /// True when the page took the Left move by landing on its own menu.
    /// False when the page has no menu, or the menu already holds focus (the
    /// shell may then open the sidebar/rail).
    func landOnMenu(tab: AppTab) -> Bool {
        guard let entry = entries[tab], !entry.isMenuFocused() else { return false }
        entry.focusMenu()
        return true
    }
}

/// Bridges `UIFocusSystem.movementDidFailNotification` (the only reliable
/// way to detect a real edge — `.onMoveCommand` fires on every press).
@MainActor
final class FocusEdgeObserver: ObservableObject {
    /// A direct callback, deliberately not @Published: the root view owns this
    /// object, so publishing made every press that went nowhere rebuild the
    /// whole app.
    var onFailedMove: ((UIFocusHeading) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main) { [weak self] note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            let heading = ctx.focusHeading
            MainActor.assumeIsolated { self?.onFailedMove?(heading) }
        }
    }
}

/// Up/Down that the focus engine couldn't carry out, from a click *or* a
/// trackpad swipe. Pages that move between rows by hand (Home, Detail) used
/// only `.onMoveCommand`, which sees clicks alone — a swipe sends no press,
/// so swiping up and down did nothing there. A failed swipe still posts
/// `movementDidFailNotification`; a failed click posts it *and* reaches
/// `.onMoveCommand` a few ms later, so clicks are noted here and the failure
/// path skips them (each move runs once).
@MainActor
final class VerticalMoveRelay {
    static let shared = VerticalMoveRelay()
    private var lastPress: (dir: MoveCommandDirection, at: Date)?
    private var lastSwipe = Date.distantPast

    /// Called from the `.onMoveCommand` handlers that move rows.
    func notePress(_ dir: MoveCommandDirection) {
        guard dir == .up || dir == .down else { return }
        lastPress = (dir, Date())
    }

    fileprivate func wasPressed(_ dir: MoveCommandDirection, near t: Date) -> Bool {
        guard let p = lastPress, p.dir == dir else { return false }
        return abs(p.at.timeIntervalSince(t)) < 0.3
    }

    /// One move per swipe: a long swipe can fail several times in a row.
    fileprivate func claimSwipe(at t: Date) -> Bool {
        guard t.timeIntervalSince(lastSwipe) > 0.28 else { return false }
        lastSwipe = t
        return true
    }

    /// Nothing is presented over the main window (the player, a sheet, a
    /// menu): their failed moves are theirs, not the page's underneath.
    fileprivate static var mainContentIsFront: Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return true }
        return root.presentedViewController == nil
    }
}

private struct VerticalSwipeMoves: ViewModifier {
    let enabled: Bool
    let perform: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { note in
            guard enabled, let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            let heading = ctx.focusHeading
            let dir: MoveCommandDirection
            if heading.contains(.down) { dir = .down } else if heading.contains(.up) { dir = .up } else { return }
            guard VerticalMoveRelay.mainContentIsFront else { return }
            let at = Date()
            // Give a click's `.onMoveCommand` time to arrive (it follows the failure).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let relay = VerticalMoveRelay.shared
                guard !relay.wasPressed(dir, near: at), relay.claimSwipe(at: at) else { return }
                #if DEBUG
                if CommandLine.arguments.contains("-traceNav") { DebugLog.write("[swipe] failed \(dir) → page move") }
                #endif
                perform(dir)
            }
        }
    }
}

extension View {
    /// Runs `perform` for an Up/Down swipe the focus engine couldn't carry out
    /// while `enabled` (clicks keep going through `.onMoveCommand`, which must
    /// call `VerticalMoveRelay.shared.notePress`).
    func onVerticalSwipeMove(enabled: Bool, perform: @escaping (MoveCommandDirection) -> Void) -> some View {
        modifier(VerticalSwipeMoves(enabled: enabled, perform: perform))
    }
}

/// Where UIKit's focus really is (screen frame). A refused @FocusState request
/// keeps its value, so the binding can't say whether focus actually moved;
/// this can.
@MainActor
enum FocusProbe {
    private(set) static var focusedFrame: CGRect?
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            // SwiftUI's focus items report their frame in screen points already
            // (verified against the -traceFocus log); views are converted.
            let frame = ctx?.nextFocusedItem.map { item -> CGRect in
                if let v = item as? UIView { return v.convert(v.bounds, to: nil) }
                return item.frame
            }
            MainActor.assumeIsolated { focusedFrame = frame }
        }
    }
}

