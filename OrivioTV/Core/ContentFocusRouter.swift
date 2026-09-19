import Foundation

/// Hands focus from the rail into a specific spot in the content — the FIRST
/// tile of the row the viewer was last in — instead of letting the focus
/// engine pick "the nearest candidate" when the rail's focus is dropped.
///
/// Dropping focus with no destination is how the engine ended up on the
/// fourth card of a row: the expanded panel overlaps the first two, so the
/// nearest candidate to the rail's centre was a card three along. Rows
/// register a "take focus at your start" handler while they are mounted and
/// note when they hold focus; the rail asks the last such row to take it back.
@MainActor
final class ContentFocusRouter {
    static let shared = ContentFocusRouter()

    /// Each mounted row's hand-off, keyed by row id. Returns true when the row
    /// took focus.
    private var handlers: [String: () -> Bool] = [:]
    /// The row that last held focus in the content.
    private(set) var lastRowID: String?

    func register(_ rowID: String, handler: @escaping () -> Bool) {
        handlers[rowID] = handler
        AppProbe.focus("row registered: \(rowID)  (\(handlers.count) mounted)")
    }

    func unregister(_ rowID: String) {
        handlers.removeValue(forKey: rowID)
        AppProbe.focus("row gone: \(rowID)  (\(handlers.count) mounted)"
                       + (lastRowID == rowID ? "  — and it was the last focused one" : ""))
    }

    /// A tile in `rowID` just took focus. Rows that carry no hand-off handler
    /// still call this (the Live Channels strip, the poster grids): it makes
    /// the record honest, so leaving the rail falls back to the engine's own
    /// pick instead of teleporting to the last ROUTED row the viewer was in —
    /// possibly several rows away.
    func noteFocused(row rowID: String) {
        // Only the CHANGES: a row notes itself on every tile the viewer moves
        // to, and a tail of "still in row 3" forty times over is noise that
        // pushes the useful lines out of the ring.
        if lastRowID != rowID {
            AppProbe.focus("content focus: \(lastRowID ?? "—") → \(rowID)"
                           + (handlers[rowID] == nil ? "  (no hand-off handler)" : ""))
        }
        lastRowID = rowID
    }

    /// Ask the last-focused row to focus its first tile. False when no such
    /// row is mounted (another tab, a pushed screen, an unrouted row) — the
    /// caller then falls back to letting the engine choose.
    func focusLastRowStart() -> Bool {
        guard let id = lastRowID, let handler = handlers[id] else {
            // The fallback that historically dropped focus on the wrong card:
            // worth seeing every time it happens, with the reason.
            AppProbe.focus("hand-off DECLINED — "
                           + (lastRowID == nil ? "no row has held focus"
                                               : "row \(lastRowID!) is not mounted")
                           + "; the engine will pick")
            return false
        }
        let took = handler()
        AppProbe.focus("hand-off to \(id) — \(took ? "taken" : "REFUSED by the row")")
        return took
    }

    /// Keep assigning `assign()` until `landed()` reads true — the first
    /// card of a lazily-stacked row may take several ticks to exist after
    /// `scrollTo`, and a single deferred retry lost the race on the slower
    /// boxes (focus then fell to whatever the engine picked mid-scroll).
    ///
    /// `focusToken` (the row's current focused id) lets the loop tell a
    /// mid-scroll ENGINE pick — which it exists to correct — from the VIEWER
    /// having moved on: focus resting on the same non-target tile two ticks
    /// running means someone chose it, and re-assigning would yank them back
    /// to card 1 and snap the platter raise mid-move (up to six times over
    /// 360ms — one face of the "frozen poster" fight).
    static func land(assign: @escaping () -> Void,
                     landed: @escaping () -> Bool,
                     focusToken: (() -> String?)? = nil) {
        assign()
        Task { @MainActor in
            var previous: String?
            for attempt in 1...6 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if landed() {
                    if attempt > 1 { AppProbe.focus("land: took \(attempt) tries") }
                    return
                }
                if let token = focusToken?(), token == previous {
                    AppProbe.focus("land: gave up after \(attempt) — focus is resting on"
                                   + " \(token), which reads as the viewer's own choice")
                    return
                }
                previous = focusToken?()
                assign()
            }
            // Six tries is 360ms. Reaching the end means the target never took
            // focus and nothing else claimed it either — the shape of a row
            // that scrolled but never built its first card.
            AppProbe.focus("land: NEVER LANDED after 6 tries")
        }
    }
}
