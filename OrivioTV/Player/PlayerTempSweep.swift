import AVFoundation
import Foundation
import KSPlayer
import Network
import SwiftUI
import UIKit

/// Reclaims the player's scratch space in `tmp/` at launch.
///
/// The DV remuxer writes its fMP4 segments to `tmp/dv-remux-<uuid>/` and
/// deletes the directory when the session ends. That deletion is best-effort
/// by construction — it runs as the player is being dismissed, and a remux
/// session is exactly the workload most likely to get the app jetsammed on a
/// 3 GB box, so the process is often gone before the delete completes. Every
/// time that happens the directory is orphaned with no owner left to remove
/// it: found on a real Apple TV 4K (1st gen) as **3.2 GB across 15 leaked
/// directories**, three of them ~1 GB each.
///
/// Nothing else ever cleaned them up. tvOS does purge `tmp/` under storage
/// pressure, but only once the box is nearly full — long after the app has
/// been swapping, stuttering and getting killed. So the sweep has to be ours,
/// and it has to run at LAUNCH: that is the one moment we know for certain
/// that no remuxer owns any of these directories.
///
/// CFNetwork's response spool files (`tmp/CFNetworkDownload_*.tmp`) leak the
/// same way and for the same reason — the app dies with requests in flight —
/// so they are swept on the same pass (179 MB / 12,231 files on that device).
///
/// The hybrid disk cache's file (`Caches/hybrid-cache/current.bin`) is the
/// third case, and the largest of them: `MediaCacheServer.endSession()` deletes
/// it on player teardown, but teardown only runs on a normal exit. A crash, a
/// jetsam kill, or the user force-quitting mid-film leaves TENS OF GIGABYTES
/// stranded, and nothing would ever remove it — the next `beginSession` only
/// clears the file if a cache session actually starts, so turning the feature
/// off (or never playing a cacheable stream again) strands it permanently.
enum PlayerTempSweep {
    private static let remuxPrefix = "dv-remux-"
    private static let spoolPrefix = "CFNetworkDownload_"

    /// Delete every orphaned player scratch directory and network spool file.
    ///
    /// Call once, at launch, BEFORE any playback can start. Runs off the main
    /// thread: this is thousands of unlinks and real filesystem work, and it
    /// must never sit in front of the first frame of UI.
    static func sweepAtLaunch() {
        Task.detached(priority: .utility) { sweep() }
    }

    /// Delete a hybrid-cache file orphaned by a kill. Launch is the one moment
    /// no session can own it: `MediaCacheServer` creates its file inside
    /// `beginSession`, which cannot have run yet.
    private static func sweepHybridCache() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("hybrid-cache", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ), !entries.isEmpty else { return }
        var reclaimed: Int64 = 0
        for entry in entries {
            reclaimed += Int64(
                (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
            try? fm.removeItem(at: entry)
        }
        if reclaimed > 0 {
            NSLog("[OrivioSweep] reclaimed %.2f GB of orphaned hybrid cache at launch",
                  Double(reclaimed) / 1e9)
        }
    }

    /// The sweep itself. Synchronous — call it directly only from a background
    /// context (or a test).
    static func sweep() {
        sweepHybridCache()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey]
        ) else { return }

        var reclaimed: Int64 = 0
        var directories = 0
        var spools = 0

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(remuxPrefix) {
                reclaimed += directorySize(of: entry, fm: fm)
                try? fm.removeItem(at: entry)
                directories += 1
            } else if name.hasPrefix(spoolPrefix) {
                reclaimed += Int64(
                    (try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0
                )
                try? fm.removeItem(at: entry)
                spools += 1
            }
        }

        guard directories > 0 || spools > 0 else { return }
        NSLog("[OrivioSweep] reclaimed %.1f MB — %d orphaned remux dirs, %d network spool files",
              Double(reclaimed) / (1024 * 1024), directories, spools)
    }

    private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        guard let walker = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
            )
        }
        return total
    }
}

/// Master switch for the whole probe suite (bus + LAN server + flight recorder).
///
/// DEBUG builds default ON. RELEASE builds — what `make-ipa.sh` produces and
/// what a sideloaded install actually runs — default OFF and are turned on from
/// Settings → Performance → "Capture diagnostics". The old `#if DEBUG` gate
/// compiled every probe away in release, so the build people really use had no
/// instrumentation at all; this makes the same suite available there without
/// paying for it unless someone asks.
enum ProbeGate {
    /// Persisted choice. Absent means "DEBUG default" (see `configureFromDefaults`).
    static let defaultsKey = "orivio.diag.capture.v1"

    private static let lock = NSLock()
    private static var enabled = false

    /// Read on every `PlayerProbe` call (including the scrub path), so it is a
    /// cheap lock, not a `UserDefaults` hit.
    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Called once from the app's `init`, before any probe is started.
    static func configureFromDefaults() {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool
        #if DEBUG
        set(stored ?? true)
        #else
        set(stored ?? false)
        #endif
    }

    static func set(_ on: Bool) {
        lock.lock(); enabled = on; lock.unlock()
    }
}

/// Live probe bus: timestamped EVENTS from anywhere, plus LEVELS pulled on
/// demand from whoever holds them.
///
/// The colour and DV trails are the wrong shape for watching an interaction.
/// They go through `UserDefaults` (a disk-backed write per line, capped at a
/// few dozen entries), which is fine for a handful of decisions per session and
/// useless for a scrub, where the interesting part is dozens of events a second
/// against levels that are moving the whole time.
///
/// So: an in-memory ring for events, a registry of sampler closures for levels,
/// and a monotonically increasing sequence number so a streaming reader can ask
/// for "everything since N" without re-reading what it already has.
///
/// Gated by `ProbeGate`. When off, the `@autoclosure` message is never built,
/// so the call sites (including the scrub path) stay cheap.
enum PlayerProbe {
    /// Ring capacity. Big enough to hold a whole scrub gesture at full rate —
    /// and, since the live tail only drains it twice a second, big enough that
    /// a burst (a source switch, a failover, a flood of engine states) can
    /// never push an event out before the reader has seen it.
    private static let capacity = 2000

    private static let lock = NSLock()
    private static var ring: [(seq: UInt64, at: Date, tag: String, line: String)] = []
    private static var nextSeq: UInt64 = 1
    static let startedAt = Date()

    /// Record one event. Safe from any thread or queue — the cache server
    /// calls it from its own serial queue, the player from the main actor.
    ///
    /// The message is an autoclosure so it is never even BUILT in release: the
    /// call sites sit on the scrub publish path and in every seek, and a
    /// `String(format:)` per call there is real work for a log nobody can read.
    nonisolated static func event(_ tag: String, _ line: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        lock.lock()
        ring.append((nextSeq, Date(), tag, line()))
        nextSeq &+= 1
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
    }

    /// Events newer than `seq`, formatted, with the sequence to ask from next.
    static func events(since seq: UInt64, limit: Int = capacity) -> (lines: [String], next: UInt64) {
        guard ProbeGate.isEnabled else { return ([], seq) }
        lock.lock()
        let fresh = ring.filter { $0.seq > seq }.suffix(limit)
        let next = ring.last?.seq ?? seq
        lock.unlock()
        return (fresh.map { entry in
            String(format: "%8.3f  %-9@ %@",
                   entry.at.timeIntervalSince(startedAt), entry.tag, entry.line)
        }, next)
    }

    // MARK: Counters and sticky notes

    /// Monotonic counters and last-value notes, surfaced as a `[health]` block.
    ///
    /// Events answer "what just happened"; these answer "what has been
    /// happening" — the questions a live session actually turns on. A stall
    /// that fires once is a blip, the same stall forty times in an hour is the
    /// bug, and there is no way to tell those apart by watching a tail scroll
    /// past. Every number here is something that should be ZERO (or one) in a
    /// healthy session, so the block reads as a defect list rather than stats.
    private static var counters: [String: Int] = [:]
    private static var notes: [(key: String, value: String, at: Date)] = []
    /// Insertion order, so the block doesn't reshuffle between reads.
    private static var counterOrder: [String] = []

    /// Bump a counter. Same threading contract as `event`.
    nonisolated static func count(_ name: String, by amount: Int = 1) {
        guard ProbeGate.isEnabled else { return }
        lock.lock()
        if counters[name] == nil { counterOrder.append(name) }
        counters[name, default: 0] += amount
        lock.unlock()
    }

    /// Record a last-known value (with the time it was set). Use for the one
    /// fact whose LATEST value matters — the last error, the URL in play, how
    /// long the open took.
    nonisolated static func note(_ key: String, _ value: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        let v = value()
        lock.lock()
        notes.removeAll { $0.key == key }
        notes.append((key, v, Date()))
        lock.unlock()
    }

    /// Drop every counter and note. Called when a new playback session starts
    /// so the numbers describe THIS title, not the afternoon.
    nonisolated static func resetHealth(keeping prefix: String? = nil) {
        guard ProbeGate.isEnabled else { return }
        lock.lock()
        if let prefix {
            counters = counters.filter { $0.key.hasPrefix(prefix) }
            counterOrder = counterOrder.filter { $0.hasPrefix(prefix) }
            notes = notes.filter { $0.key.hasPrefix(prefix) }
        } else {
            counters = [:]; counterOrder = []; notes = []
        }
        lock.unlock()
    }

    nonisolated static func healthLines() -> [String] {
        guard ProbeGate.isEnabled else { return [] }
        lock.lock()
        let c = counterOrder.compactMap { name -> String? in
            guard let value = counters[name] else { return nil }
            return "\(name)=\(value)"
        }
        let n = notes.map { note -> String in
            String(format: "%@ = %@  (%.1fs ago)", note.key, note.value,
                   Date().timeIntervalSince(note.at))
        }
        lock.unlock()
        var out: [String] = []
        // Counters wrap at ~100 columns: a terminal is the client.
        var row = ""
        for item in c {
            if row.count + item.count + 2 > 96 { out.append(row); row = "" }
            row += (row.isEmpty ? "" : "  ") + item
        }
        if !row.isEmpty { out.append(row) }
        out.append(contentsOf: n)
        return out
    }

    // MARK: Levels

    /// Named sampler closures, called on the main actor when a reader asks.
    /// The player registers itself on `init` and clears on `deinit`, so a
    /// finished session's model is never held alive by this.
    @MainActor private static var samplers: [(name: String, sample: () -> [String])] = []

    @MainActor static func register(_ name: String, _ sample: @escaping () -> [String]) {
        samplers.removeAll { $0.name == name }
        samplers.append((name, sample))
    }

    @MainActor static func unregister(_ name: String) {
        samplers.removeAll { $0.name == name }
    }

    /// One block of every registered level, newest state at the moment of the
    /// call. The cache is always included — it outlives any one player.
    /// When the running executable was built.
    ///
    /// Earned its place: four hours of device observation were spent verifying a
    /// fix against a binary that turned out to predate it, because nothing in the
    /// probe said which build was answering. `strings` on the app cannot settle
    /// it (Swift literals do not surface), and "the install said Launched" is not
    /// evidence the install replaced anything.
    static let buildStamp: String = {
        guard let exe = Bundle.main.executableURL,
              let date = try? exe.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }()

    /// Resident footprint in MB, or 0 if the kernel won't say. A 3 GB Apple TV
    /// jetsams the app somewhere north of ~650 MB, and "it just closed" is one
    /// of the most common player complaints — a number climbing across a
    /// session is the difference between guessing and knowing.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    @MainActor static func levels() -> [String] {
        var out: [String] = [
            String(format: "[build] %@   up=%.0fs   mem=%.0fMB",
                   buildStamp, Date().timeIntervalSince(startedAt), footprintMB()),
        ]
        for sampler in samplers {
            let lines = sampler.sample()
            guard !lines.isEmpty else { continue }
            out.append("[\(sampler.name)]")
            out.append(contentsOf: lines.map { "  " + $0 })
        }
        let cache = MediaCacheServer.shared.probeLines
        if !cache.isEmpty {
            out.append("[cache]")
            out.append(contentsOf: cache.map { "  " + $0 })
        }
        // Last, and deliberately so: it is the block to read when nothing in
        // the live state looks wrong but the session still feels broken.
        let health = healthLines()
        if !health.isEmpty {
            out.append("[health]")
            out.append(contentsOf: health.map { "  " + $0 })
        }
        return out
    }
}

extension Bool {
    /// Compact yes/no for probe lines — `true`/`false` doubles the width of
    /// every state line for no gain when a dozen of them share a row.
    var probe: String { self ? "Y" : "n" }
}

/// Dev-only: serves the colour trail over the LAN as plain text.
///
/// The point is to be able to WATCH a playback session live. The alternative —
/// pulling the app container with `devicectl` — briefly backgrounds the app,
/// which pops auto-PiP over whatever is playing and, worse, fires the
/// `didEnterBackground` observer that clears `SessionDisplayMode`'s pin. That
/// destroys the exact state a colour investigation is trying to observe. A
/// read-only socket costs the session nothing.
///
/// Lives here rather than in its own file purely so it needs no project-file
/// change. Debug builds only, read-only, and it parses nothing the client sends.
@MainActor
final class ColorProbeServer {
    static let shared = ColorProbeServer()

    /// High, fixed, and distinct from the add-on import server's 8099.
    private static let port: UInt16 = 8123
    private var listener: NWListener?

    func start() {
        guard ProbeGate.isEnabled else { return }
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: port) else { return }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            // One read is enough to see the request line, which is all that
            // picks the route.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, _, _ in
                let head = chunk.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                Task { @MainActor in
                    switch path {
                    case let p where p.hasPrefix("/live"):
                        Self.stream(on: connection, eventsOnly: false)
                    case let p where p.hasPrefix("/events"):
                        Self.stream(on: connection, eventsOnly: true)
                    // `/mark?<anything>` drops a labelled line into the event
                    // stream. During a live session the observer and the
                    // person watching are not the same person: "it just
                    // froze" arrives seconds after the fact, over a tail that
                    // has scrolled on. A mark is an anchor in the ONE clock
                    // both sides share, so the complaint can be lined up with
                    // the events around it afterwards instead of estimated.
                    case let p where p.hasPrefix("/mark"):
                        let note = p.split(separator: "?", maxSplits: 1).dropFirst().first
                            .map { $0.replacingOccurrences(of: "+", with: " ")
                                     .removingPercentEncoding ?? String($0) } ?? "mark"
                        PlayerProbe.event("MARK", "──────── \(note) ────────")
                        Self.sendText(on: connection, "marked: \(note)\n")
                    // `/cachecheck` runs the cache listener check a new playback
                    // session would run and reports the listener's state — the
                    // way to prove, from outside, that a listener killed by a
                    // suspension is rebuilt rather than handed out dead.
                    case let p where p.hasPrefix("/cachecheck"):
                        #if DEBUG
                        MediaCacheServer.shared.debugCheckListener { line in
                            Task { @MainActor in Self.sendText(on: connection, line + "\n") }
                        }
                        #else
                        Self.sendText(on: connection, "cachecheck: debug builds only\n")
                        #endif
                    case let p where p.hasPrefix("/health"):
                        Self.sendText(on: connection,
                                      PlayerProbe.healthLines().joined(separator: "\n") + "\n")
                    case let p where p.hasPrefix("/probe"):
                        Self.sendText(on: connection, PlayerProbe.levels()
                            .joined(separator: "\n") + "\n\n"
                            + PlayerProbe.events(since: 0, limit: 120).lines.joined(separator: "\n") + "\n")
                    default:
                        Self.send(on: connection)
                    }
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Tear the listener down when the Diagnostics toggle is switched off.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Live tail: an HTTP response with NO Content-Length that simply never
    /// ends, so `curl` prints it as it arrives. Levels every half second (the
    /// rate a scrub is worth watching at), events the moment they land.
    ///
    /// Deliberately not SSE or JSON — the client for this is a terminal.
    private static func stream(on connection: NWConnection, eventsOnly: Bool) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        let banner = "=== orivio live probe — \(eventsOnly ? "events" : "levels + events") ===\n"
        connection.send(content: Data(head.utf8) + Data(banner.utf8),
                        completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            Task { @MainActor in tick(on: connection, since: 0, eventsOnly: eventsOnly, ticks: 0) }
        })
    }

    @MainActor
    private static func tick(on connection: NWConnection, since: UInt64,
                             eventsOnly: Bool, ticks: Int) {
        var body = ""
        let fresh = PlayerProbe.events(since: since)
        if !fresh.lines.isEmpty { body += fresh.lines.joined(separator: "\n") + "\n" }
        // Levels every fourth tick (~2s) rather than every one: they are two
        // dozen lines, and at 2 Hz they would bury the events, which are the
        // part that says what just happened.
        if !eventsOnly, ticks % 4 == 0 {
            let stamp = String(format: "%8.3f", Date().timeIntervalSince(PlayerProbe.startedAt))
            body += "\n\(stamp)  ---- levels ----\n"
            body += PlayerProbe.levels().joined(separator: "\n") + "\n\n"
        }
        let payload = body.isEmpty ? "" : body
        let send: (@escaping () -> Void) -> Void = { done in
            guard !payload.isEmpty else { done(); return }
            connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
                if error != nil { connection.cancel() } else { done() }
            })
        }
        send {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    tick(on: connection, since: fresh.next, eventsOnly: eventsOnly, ticks: ticks + 1)
                }
            }
        }
    }

    private static func sendText(on connection: NWConnection, _ text: String) {
        let body = Data(text.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func send(on connection: NWConnection) {
        var trail = UserDefaults.standard.stringArray(forKey: "dev.colorTrail") ?? []
        // The DV trail as well. It lives under its own key, so every line the
        // native-DV path writes — "display settled at Nfps" above all — was
        // invisible to this endpoint and readable only on a console-attached
        // device, which is exactly the situation this server exists to avoid.
        let dv = UserDefaults.standard.stringArray(forKey: "dev.dvTrail") ?? []
        if !dv.isEmpty {
            trail.append("--- dv trail ---")
            trail.append(contentsOf: dv)
        }
        // Live cache state on every read — the trail only records EVENTS, and
        // "how much has actually downloaded" is a level, not an event.
        trail.append(MediaCacheServer.shared.statusLine)
        let body = Data((trail.joined(separator: "\n") + "\n").utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// App-wide flight recorder: one compact line every few seconds, kept in
/// UserDefaults so it SURVIVES the failure.
///
/// The `:8123` live probe is the better read-out right up until the moment it
/// matters, and then it is gone — a suspended app stops answering, a wedged one
/// never accepts the connection, and a kernel panic takes the whole box with it.
/// On 2026-09-14 the app froze and the Apple TV then died of an out-of-memory
/// panic, and none of the live tooling could say a word about it. What DID
/// survive was the persisted trail in UserDefaults, readable afterwards with
/// `devicectl device copy from … Library/Preferences/<bundle>.plist`.
///
/// So this records the handful of numbers that incident needed and nobody had:
///
/// - **mainStall** — seconds since the main thread last ticked. THE datum that
///   separates "deadlocked" from "out of memory", and the one whose absence
///   sent that investigation down the wrong path for an hour. A heartbeat is
///   bumped on the main queue; this thread only ever READS how stale it is, so
///   a blocked main thread makes the number climb instead of hiding.
/// - **mem** — footprint in MB, app-wide and continuous. The existing memory
///   line only runs while the player is open, which is why the staircase that
///   ended in the panic was invisible.
/// - **vms** — live `PlayerViewModel` count. Leaked players are what fills the
///   memory; the leak probe already counts them but only shouted into NSLog.
/// - **state** — foreground / inactive / background, tracked from the lifecycle
///   notifications rather than read from `UIApplication`, because
///   `applicationState` is main-thread-only and this runs on a utility queue.
/// - **cache** — the hybrid cache's own status line (file size, window, pool).
///
/// Deliberately cheap and deliberately boring: two timers, a few lock-guarded
/// reads, a bounded ring, no retained references to anything it observes, and
/// no UIKit access off the main thread.
enum FlightRecorder {
    /// Read it back with:
    /// `plistlib.load(open(prefs))["dev.flight"]`
    private static let key = "dev.flight"
    /// ~40 minutes at the tick below. Bounded so it can never grow without
    /// limit — the same discipline `dvTrail` learned the hard way.
    private static let capacity = 240
    private static let tick: TimeInterval = 10
    /// How often the main queue stamps its heartbeat. Finer than the tick so a
    /// stall is dated to within a second rather than within ten.
    private static let beat: TimeInterval = 1

    private static let queue = DispatchQueue(label: "orivio.flight", qos: .utility)

    /// When the main queue last proved it was alive (`timeIntervalSince1970`).
    /// An `Atomic` because it is written on main and read on `queue`.
    private static let mainBeatAt = Atomic<TimeInterval>(
        wrappedValue: Date().timeIntervalSince1970
    )
    private static let appState = Atomic<String>(wrappedValue: "launching")
    /// A one-off marker the next tick will carry (see `mark`).
    private static let pendingMark = Atomic<String?>(wrappedValue: nil)

    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var beatTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var tickTimer: DispatchSourceTimer?

    /// Annotate the recording — "the freeze started here", a build stamp, a
    /// deliberate reproduction step. Carried on the next tick. Safe from any
    /// thread.
    static func mark(_ note: String) {
        pendingMark.wrappedValue = note
        NSLog("[OrivioFlight] MARK %@", note)
    }

    static func start() {
        guard ProbeGate.isEnabled else { return }
        guard !started else { return }
        started = true
        NSLog("[OrivioFlight] recorder armed — tick %.0fs, ring %d, key %@",
              tick, capacity, key)

        // A new run is a new recording. Keeping the previous launch's lines
        // would make "what happened just before it died" ambiguous, and the
        // crash/panic reports already carry the boundary.
        //
        // WRITTEN THROUGH `queue` like every other write, so the first tick
        // cannot race the reset and lose itself.
        let opening = line(mainStall: 0, note: "=== launch ===")
        queue.async { UserDefaults.standard.set([opening], forKey: key) }

        // Main-thread heartbeat. All it does is stamp the clock; if the main
        // thread is blocked this simply stops happening and the tick below sees
        // the gap grow.
        let heart = DispatchSource.makeTimerSource(queue: .main)
        heart.schedule(deadline: .now() + beat, repeating: beat, leeway: .milliseconds(200))
        heart.setEventHandler { mainBeatAt.wrappedValue = Date().timeIntervalSince1970 }
        heart.resume()
        beatTimer = heart

        let recorder = DispatchSource.makeTimerSource(queue: queue)
        recorder.schedule(deadline: .now() + tick, repeating: tick, leeway: .seconds(1))
        recorder.setEventHandler { record() }
        recorder.resume()
        tickTimer = recorder

        observeLifecycle()
    }

    // MARK: - Internals

    /// Lifecycle tracked from notifications, NOT from `UIApplication.shared
    /// .applicationState`: that is main-thread-only, and reading UIKit off the
    /// main thread is precisely the defect the Main Thread Checker caught in
    /// the sample engine the same night this file was written.
    private static func observeLifecycle() {
        let centre = NotificationCenter.default
        func watch(_ name: Notification.Name, _ label: String) {
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                appState.wrappedValue = label
                // Flush immediately: a suspension can freeze the process before
                // the next tick, and the state it went away in is exactly what
                // the next investigation wants.
                queue.async { record(note: "lifecycle \(label)") }
            }
        }
        watch(UIApplication.didBecomeActiveNotification, "active")
        watch(UIApplication.willResignActiveNotification, "inactive")
        watch(UIApplication.didEnterBackgroundNotification, "background")
        watch(UIApplication.willEnterForegroundNotification, "foreground")
        centre.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in queue.async { record(note: "MEMORY WARNING") } }
    }

    /// Build one line. Pure reads — nothing here can block on the main thread,
    /// which is the whole point: it has to keep recording while main is stuck.
    private static func line(mainStall: Double, note: String?) -> String {
        var out = String(
            format: "%@ mem=%.0fMB vms=%d state=%@ mainStall=%.0fs",
            Self.stamp(),
            PlayerProbe.footprintMB(),
            PlayerViewModel.liveInstanceCounter.wrappedValue,
            appState.wrappedValue,
            mainStall
        )
        // The cache's own snapshot is lock-guarded and built for cross-thread
        // reads (`statusLine`), so this costs a lock and a string.
        out += " | " + MediaCacheServer.shared.statusLine
        if let note { out += " | " + note }
        return out
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// Append one line. Always on `queue`.
    private static func record(note: String? = nil) {
        let stall = max(0, Date().timeIntervalSince1970 - mainBeatAt.wrappedValue)
        var text = line(mainStall: stall, note: note)
        if let mark = pendingMark.wrappedValue {
            pendingMark.wrappedValue = nil
            text += " | MARK: " + mark
        }
        // A stalled main thread is the headline, not a field to squint at.
        if stall >= 3 { text += "  <-- MAIN THREAD STALLED" }

        var trail = UserDefaults.standard.stringArray(forKey: key) ?? []
        trail.append(text)
        if trail.count > capacity { trail.removeFirst(trail.count - capacity) }
        UserDefaults.standard.set(trail, forKey: key)
    }
}

/// The electronic equivalent of toggling the TV input, used to recover a panel
/// wedged grey by a bad HDMI mode switch.
///
/// Deliberately GLOBAL (not owned by a player): the wedge is most often escaped
/// by backing out of the player, and at that point there is no view model left
/// to run a recovery — the display manager is still there, though, so this is
/// driven straight off it. `sessionTarget` lets a live player put its own mode
/// back; with no player the target is home mode (nil).
@MainActor
enum DisplayResync {
    /// Set by the active player so step 3 restores the SESSION's HDR/DV mode
    /// rather than dropping to SDR. Cleared on teardown.
    static var sessionTarget: (() -> AVDisplayCriteria?)?

    static func force(reason: String) {
        guard let manager = UIApplication.shared.ks_keyWindow?.avDisplayManager else {
            PlayerProbe.event("display", "force re-sync: no display manager")
            return
        }
        let held = manager.preferredDisplayCriteria
        let target = held ?? sessionTarget?()
        // 1/3 — drop the criteria and the app's pin, so tvOS is allowed to move
        // the panel and a later request is not deduped.
        manager.preferredDisplayCriteria = nil
        SessionDisplayMode.resetPinForResync()
        PlayerProbe.event("display", "force re-sync 1/3 — dropped criteria (held="
            + (held != nil ? "set" : "nil") + ") reason=\(reason)")
        // 2/3 — force a DEFINITE different mode (SDR) so the link re-trains even
        // if tvOS thought it was already home.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let sdr = AVDisplayCriteria(
                refreshRate: Float(UIScreen.main.maximumFramesPerSecond),
                videoDynamicRange: DynamicRange.sdr.rawValue
            )
            manager.preferredDisplayCriteria = sdr
            PlayerProbe.event("display", "force re-sync 2/3 — stepped through SDR")
            // 3/3 — restore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                manager.preferredDisplayCriteria = target
                PlayerProbe.event("display", "force re-sync 3/3 — restored "
                    + (target == nil ? "home mode" : "session mode"))
            }
        }
    }
}

/// Remote probe commands, fired from the Mac with:
///
///   xcrun devicectl device notification post --device <id> \
///     --name com.orivio.tv.probe.resyncDisplay
///
/// The grey-screen wedge leaves the WHOLE TV grey, so recovery must not depend
/// on the viewer finding the remote gesture. This lets the person reading the
/// probe trigger the SAME display re-sync from outside, and lets a support
/// session recover the panel without touching the Apple TV.
enum ProbeRemote {
    static let resyncDarwinName = "com.orivio.tv.probe.resyncDisplay"
    static let resyncNotification = Notification.Name("orivio.probe.resyncDisplay")

    private static let callback: CFNotificationCallback = { _, _, _, _, _ in
        // Darwin callbacks are not on a known queue; hop to main and run the
        // GLOBAL display re-sync (works even with no player open, which is the
        // case the moment the viewer backs out of a wedged grey player).
        DispatchQueue.main.async {
            PlayerProbe.event("display", "remote re-sync command received")
            MainActor.assumeIsolated { DisplayResync.force(reason: "remote") }
            NotificationCenter.default.post(name: resyncNotification, object: nil)
        }
    }

    nonisolated(unsafe) private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil, callback,
            resyncDarwinName as CFString, nil, .deliverImmediately
        )
        PlayerProbe.event("life", "remote probe commands armed — \(resyncDarwinName)")
    }
}

// MARK: - App-wide probe

/// Everything the player probe never reached: browsing, focus, data loads,
/// sync and app lifecycle.
///
/// The player has been watchable over `:8123` since 2026-09-08; the rest of
/// the app had no instrumentation at all, so "it got stuck while I was moving
/// around" had nothing behind it but a guess. This is the SAME bus — one ring,
/// one clock, one `/live` tail — with app-shaped verbs, so a browse and the
/// playback it leads into read as one story instead of two.
///
/// Gated by `ProbeGate`, not by the compiler: with capture off the message is
/// never built (it is an `@autoclosure` behind a cheap flag check), so the call
/// sites are still free to sit anywhere, including in a `body`. With capture on
/// — the Settings toggle in a Release/sideloaded build — they all record.
///
/// Lives in this file for the same reason `PlayerProbe` does — `project.yml`
/// globs sources but the checked-in `.xcodeproj` does not, so a NEW file needs
/// an xcodegen run. See [[nuviotv-device-debugging]].
enum AppProbe {

    // MARK: Verbs
    //
    // One tag per concern rather than a single "app" tag: the live tail is
    // read by eye, and `grep -w focus` on a recording is the difference
    // between finding a focus bug and scrolling past it.

    /// Screens appearing and leaving, tab switches, pushes and pops.
    nonisolated static func nav(_ line: @autoclosure () -> String) {
        PlayerProbe.event("nav", line())
    }

    /// Anything that moves focus or refuses to: the rail, the focus router,
    /// the enable/disable windows. The app's most-repaired area by far.
    nonisolated static func focus(_ line: @autoclosure () -> String) {
        PlayerProbe.event("focus", line())
    }

    /// Catalogs, collections, add-on manifests, metadata, artwork — what was
    /// asked for, how long it took, and what came back.
    nonisolated static func data(_ line: @autoclosure () -> String) {
        PlayerProbe.event("data", line())
    }

    /// The account sync and everything it writes.
    nonisolated static func sync(_ line: @autoclosure () -> String) {
        PlayerProbe.event("sync", line())
    }

    /// Launch, foreground, background, memory pressure.
    nonisolated static func life(_ line: @autoclosure () -> String) {
        PlayerProbe.event("life", line())
    }

    /// Something went wrong, whether or not the viewer noticed.
    ///
    /// Logged AND counted AND kept as the latest note, because the three
    /// answer different questions: the event says when, the counter says how
    /// often (a failure that fires once is a blip; the same one forty times is
    /// the bug), and the note survives past the end of the ring so a long
    /// session still reports its last failure.
    nonisolated static func warn(_ area: String, _ line: @autoclosure () -> String) {
        guard ProbeGate.isEnabled else { return }
        let text = line()
        PlayerProbe.event("WARN", "\(area): \(text)")
        PlayerProbe.count("warn.\(area)")
        PlayerProbe.note("lastWarn", "\(area): \(text)")
    }

    /// Stopwatch for anything that takes time. Returns the closure that ends
    /// it; call it with a one-word outcome.
    ///
    ///     let done = AppProbe.begin("data", "catalog \(name)")
    ///     …
    ///     done("\(items.count) items")
    ///
    /// Anything past two seconds also bumps a counter, so "it felt slow" has a
    /// number behind it without anyone having to have been watching the tail
    /// at the time.
    nonisolated static func begin(_ tag: String, _ what: String) -> (String) -> Void {
        guard ProbeGate.isEnabled else { return { _ in } }
        let started = CACurrentMediaTime()
        PlayerProbe.event(tag, what + " …")
        return { outcome in
            let ms = (CACurrentMediaTime() - started) * 1000
            PlayerProbe.event(tag, String(format: "%@ — %.0fms · %@", what, ms, outcome))
            if ms > 2000 { PlayerProbe.count("slow.\(tag)") }
        }
    }

    /// A URL boiled down to what identifies it in a log: host plus the part of
    /// the path that says what was asked for, with the token query an add-on
    /// carries dropped. Full URLs are 200 characters of noise, and several of
    /// them contain credentials.
    nonisolated static func requestName(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host ?? "?"
        var path = url.path
        if path.hasSuffix(".json") { path.removeLast(5) }
        // Add-on paths are `/…config…/resource/type/id`; the resource is what
        // matters and the config in front of it can be enormous.
        for resource in ["/catalog/", "/meta/", "/stream/", "/subtitles/"] where path.contains(resource) {
            if let r = path.range(of: resource) { path = String(path[r.lowerBound...]) }
            break
        }
        if path.count > 80 { path = String(path.prefix(80)) + "…" }
        return host + path
    }

    // MARK: The [app] block

    /// What is on screen right now. Fed by `RootView` and `probeScreen`, read
    /// by the sampler below.
    ///
    /// Held here rather than sampled out of `RootView` because a sampler that
    /// captures a SwiftUI `View` reads whatever that struct's snapshot held,
    /// and a stale tab number in the one block meant to orient the reader is
    /// worse than no block.
    @MainActor static var tab = "—"
    @MainActor static var screen = "—"
    @MainActor static var rail = "—"
    @MainActor static var scene = "active"

    /// Screens currently mounted, innermost last — a pushed Detail over Home
    /// reads as `Home › Detail`, which is the question "where am I" answered
    /// without inferring it from a stream of appear/disappear events.
    @MainActor private static var mounted: [String] = []

    @MainActor static func entered(screen name: String, _ detail: String) {
        mounted.append(name)
        screen = name
        nav("→ \(name)" + (detail.isEmpty ? "" : "  \(detail)") + "   [\(breadcrumb)]")
    }

    @MainActor static func left(screen name: String, after seconds: TimeInterval) {
        if let i = mounted.lastIndex(of: name) { mounted.remove(at: i) }
        screen = mounted.last ?? "—"
        nav(String(format: "← %@ after %.1fs   [%@]", name, seconds, breadcrumb))
    }

    @MainActor static var breadcrumb: String {
        mounted.isEmpty ? "—" : mounted.joined(separator: " › ")
    }

    /// How deep the push stack is, counted off the mounted screens rather than
    /// a `NavigationPath` — there are five independent paths, one per tab, and
    /// keeping five counters in step is a bug waiting to be written.
    @MainActor static var depth: Int { max(mounted.count - 1, 0) }

    /// Thermal pressure, the one OS signal that explains "it only stutters
    /// after twenty minutes" without anything in the app having changed.
    nonisolated static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }

    /// One-line output-route summary. Route changes are a classic source of
    /// dropouts and A/V drift ("it went out of sync when the soundbar woke"),
    /// and nothing else in the app records them.
    @MainActor static var audioRouteLabel: String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return (outputs.isEmpty ? "—" : outputs.joined(separator: ","))
            + "  cat=\(session.category.rawValue)/\(session.mode.rawValue)"
    }

    /// Register the `[app]` level block. Called once, from the app's `init`,
    /// so browsing is observable before anything has been played.
    @MainActor static func installLevels() {
        // Pin the probe clock at LAUNCH. `PlayerProbe.startedAt` is lazy, so
        // without this it was first touched when a client read the log —
        // making every event logged before that read show a NEGATIVE time.
        _ = PlayerProbe.startedAt
        ProbeRemote.install()
        PlayerProbe.register("app") {
            [
                "tab=\(tab)  screen=\(screen)  depth=\(depth)  scene=\(scene)",
                "where=\(breadcrumb)",
                "rail=\(rail)  lastFocusedRow=\(ContentFocusRouter.shared.lastRowID ?? "—")",
                "thermal=\(thermalLabel(ProcessInfo.processInfo.thermalState))"
                    + "  lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled.probe)"
                    + "  cpus=\(ProcessInfo.processInfo.activeProcessorCount)",
                // Live player-model census. More than 1 while nothing is being
                // handed to PiP is a leak, and this is the block a browse is
                // read against.
                "playerVMs=\(PlayerViewModel.liveInstanceCounter.wrappedValue)"
                    + "  mem=\(String(format: "%.0fMB", PlayerProbe.footprintMB()))",
                "audio=\(audioRouteLabel)",
            ]
        }
        // A jetsam on a 3 GB box is preceded by this, and "the app just
        // closed" is otherwise indistinguishable from a crash after the fact.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            warn("memory", String(format: "memory warning at %.0fMB", PlayerProbe.footprintMB()))
        }
        // Thermal throttling and audio-route changes both show up as "it just
        // started stuttering / drifted" with nothing in the player log.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in
            life("thermal → \(thermalLabel(ProcessInfo.processInfo.thermalState))")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            guard ProbeGate.isEnabled else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            Task { @MainActor in
                life("audio route → \(audioRouteLabel)  reason=\(reason.map(String.init(describing:)) ?? "?")")
            }
        }
        life("probe armed — app block registered")
    }
}

/// Logs a screen's appear and disappear, and keeps `[app]`'s "where" current.
///
/// A modifier rather than two hand-written `onAppear`/`onDisappear` pairs per
/// screen: the pair has to agree on the name and on the clock, and thirty
/// hand-written pairs would not. It adds no layout and no state of its own
/// beyond the entry timestamp.
private struct ProbeScreen: ViewModifier {
    let name: String
    let detail: () -> String
    @State private var shownAt = Date()

    func body(content: Content) -> some View {
        content
            .onAppear {
                shownAt = Date()
                AppProbe.entered(screen: name, detail())
            }
            .onDisappear {
                AppProbe.left(screen: name, after: Date().timeIntervalSince(shownAt))
            }
    }
}

extension View {
    /// Mark this view as a screen for the `[app]` probe block.
    ///
    /// `detail` is a closure so it is evaluated once per appearance rather
    /// than on every body pass — several of these read a title or a count off
    /// a model that is being rebuilt continuously.
    func probeScreen(_ name: String, _ detail: @escaping () -> String = { "" }) -> some View {
        modifier(ProbeScreen(name: name, detail: detail))
    }
}
