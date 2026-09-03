import Foundation

/// Kicks a FULL sync of every destination whenever something sync-relevant
/// happens locally — a title finished, a rating changed, a profile deleted —
/// instead of leaving it for the next periodic tick.
///
/// The individual managers already push the single item that changed. That
/// covers the common case, but it is not the same thing: a per-item push sends
/// one row to one service, whereas the events here (a profile switch, a
/// deletion, a title finishing) usually mean several stores moved at once and
/// the whole picture needs reconciling everywhere. This is the "and now make
/// everything agree" pass.
///
/// Two pieces of pacing, because "immediately" and "on every single event" are
/// not the same requirement:
///
/// * A short **trailing debounce**. "Mark Season Watched" fires one event per
///   episode — twenty-odd in the same runloop turn. Without collapsing them
///   that single button press would start twenty full syncs.
/// * A **minimum interval** between runs, with the last request kept and run
///   when the floor lifts. Nothing is dropped; it is deferred, so a burst of
///   activity can't turn into a full sync every second or two.
@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private init() {}

    /// Keyed by name so re-registering (a second `configure`, a rebuilt view)
    /// replaces a destination instead of doubling it.
    private var destinations: [String: () -> Void] = [:]
    private var order: [String] = []

    private var pendingReasons: [String] = []
    private var scheduled: Task<Void, Never>?
    private var lastRun = Date.distantPast

    /// Long enough to swallow a "mark the whole season" burst, short enough to
    /// still read as immediate.
    private static let debounce: TimeInterval = 1.5
    /// Floor between two full syncs. A request inside the floor is not dropped
    /// — it waits for the remainder and then runs.
    private static let minimumInterval: TimeInterval = 8

    // MARK: - Destinations

    func addDestination(_ name: String, _ run: @escaping () -> Void) {
        if destinations[name] == nil { order.append(name) }
        destinations[name] = run
    }

    // MARK: - Requesting

    /// Something changed that every destination should hear about.
    /// `reason` is for the log only.
    func requestFullSync(_ reason: String) {
        pendingReasons.append(reason)
        scheduled?.cancel()
        let sinceLast = Date().timeIntervalSince(lastRun)
        let wait = max(Self.debounce, Self.minimumInterval - sinceLast)
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    private func run() {
        scheduled = nil
        lastRun = Date()
        // Collapse the reasons for the log — twenty "watched" events in one
        // burst should read as one line, not twenty.
        var seen = Set<String>()
        let reasons = pendingReasons.filter { seen.insert($0).inserted }
        pendingReasons.removeAll()
        guard !destinations.isEmpty else { return }
        NSLog("[OrivioSync] full sync — %@", reasons.joined(separator: ", "))
        for name in order {
            destinations[name]?()
        }
    }

    // MARK: - Observing the stores

    /// Subscribe to every local change that should force a full sync.
    ///
    /// These are the same hook lists the Trakt and SIMKL managers use, which is
    /// why they are lists: this adds one more observer rather than displacing
    /// either of them. Remote merges set `suppressChange` in the stores, so a
    /// PULL cannot fire these and spin the coordinator in a loop.
    func observe(watched: WatchedStore, library: LibraryStore,
                 ratings: RatingsStore, progress: ProgressStore) {
        watched.onTrackerMark.append { [weak self] _ in
            self?.requestFullSync("watched")
        }
        watched.onTrackerRemove.append { [weak self] _ in
            self?.requestFullSync("un-watched")
        }
        library.onTrackerAdd.append { [weak self] _ in
            self?.requestFullSync("library add")
        }
        library.onTrackerRemove.append { [weak self] _ in
            self?.requestFullSync("library remove")
        }
        ratings.onTrackerRate.append { [weak self] _, _, _ in
            self?.requestFullSync("rating")
        }
        ratings.onTrackerUnrate.append { [weak self] _, _ in
            self?.requestFullSync("rating cleared")
        }
        progress.onTrackerProgressRemove.append { [weak self] _ in
            self?.requestFullSync("continue watching removed")
        }
    }
}
