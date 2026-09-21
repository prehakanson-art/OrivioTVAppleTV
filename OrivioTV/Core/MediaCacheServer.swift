import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// The hybrid disk cache: a localhost HTTP proxy between the player engines
/// and a direct-file stream, Infuse-style.
///
/// The in-memory read-ahead buffer tops out at a few hundred MB on tvOS (see
/// `BufferProfile` — RAM is the ceiling, and jetsam is the penalty), so a deep
/// seek always lands beyond the buffer and stalls on the network. This server
/// downloads the WHOLE file to the app's caches directory at full line speed
/// while playback runs, and serves the engines' range requests from disk — so
/// once a region has downloaded, seeking into it is instant, and a fully
/// downloaded film seeks like a local file.
///
/// Design constraints that shaped it:
/// * One session at a time (one film), replaced on the next `beginSession`.
///   The cache file lives in Caches (purgeable by the OS, cleared eagerly on
///   session end) — nothing survives that shouldn't.
/// * Direct http(s) files only. HLS playlists never qualify (their URLs are
///   many small files, useless to cache this way) and are screened out by
///   extension before a session starts.
/// * Fail OPEN: anything unexpected — origin refuses ranges mid-flight, disk
///   fills, downloader dies — flips the session to redirect mode, and every
///   subsequent request is answered with a 307 to the origin. The engines
///   follow redirects, so the worst case is exactly today's direct playback.
/// * A deep forward seek REPOSITIONS the downloader to the seek point (the
///   viewer's position wins over sequential completeness); the gap left
///   behind is filled after the tail finishes.
/// * SLIDING WINDOW: a film bigger than the free disk still caches — the
///   download fills up to a budget (free space minus slack), then pauses;
///   as playback advances, blocks well behind the playhead are hole-punched
///   out of the sparse file (APFS `F_PUNCHHOLE`) and the download resumes.
///   The window keeps a rewind margin behind the viewer; a request for bytes
///   the window has already passed is answered with a redirect to the origin
///   (fail open, per request). Needs a range-capable origin.
///
/// Everything runs on one serial queue — listener, connections, and the
/// URLSession delegate all target it, so there is no shared-state locking to
/// get wrong.
final class MediaCacheServer {
    static let shared = MediaCacheServer()

    private let q = DispatchQueue(label: "orivio.hybridcache")
    /// A `beginSession` swap is waiting on `q.sync` FROM THE MAIN THREAD.
    /// The queue can hold seconds of multi-megabyte write callbacks and
    /// `F_PUNCHHOLE` evictions ahead of it — all for the session about to be
    /// torn down — and the main thread ate that whole backlog at every source
    /// switch, failover and episode advance. While this is set, the heavy
    /// jobs for the OUTGOING session early-out.
    @Atomic private var sessionSwapPending = false
    private static let port: UInt16 = 8097
    /// Serving chunk: big enough to saturate a LAN hop, small enough to keep
    /// per-connection memory trivial.
    private static let chunk = 1 << 20

    // MARK: Session state (queue-confined)

    private var origin: URL?
    /// Addon-declared request headers (Referer/User-Agent/Cookie/…) for the
    /// origin fetches, from `behaviorHints.proxyHeaders`. Without them the
    /// download workers send a bare request and a header-gated CDN answers 403
    /// — the engine's own headers only ever reach localhost, so the proxy must
    /// carry them on to the origin. Queue-confined, like `origin`.
    private var sessionHeaders: [String: String]?
    private var token = ""
    private var fileURL: URL?
    private var writeHandle: FileHandle?
    private var totalLength: Int64 = -1          // -1 until the first response
    /// Sorted, merged, non-overlapping half-open byte ranges present on disk.
    private var ranges: [CachedRange] = []
    /// Monotonic stamp handed to each newly cached run, so eviction can order
    /// by WHEN a stretch of film was cached rather than where it sits in the
    /// file.
    private var cacheClock = 0
    /// Origin answered 200 to a ranged request → it can't seek; the download
    /// still caches sequentially but jumps are impossible.
    private var rangeCapable = true
    /// Terminal failure → answer everything with a redirect to the origin.
    private var redirectAll = false
    private var listener: NWListener?
    /// Listeners retired or failed since one last reached `.ready`. See
    /// `startListenerLocked` — two in a row means rebuilding is not working,
    /// and the session declines for `listenerRetryDelay` so playback goes
    /// straight to the origin instead of looping on a port nobody answers.
    private var listenerFailures = 0
    private var listenerRetryAfter = Date.distantPast
    private static let listenerRetryDelay: TimeInterval = 30
    /// When the app last came back from the background, and when the current
    /// listener was built. A listener older than the last suspension is never
    /// trusted, whatever state it reports — see `startListenerLocked`.
    private var lastResumeAt = Date.distantPast
    private var listenerBuiltAt = Date.distantPast
    private var lifecycleObserved = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The download POOL. One connection is throttled by the provider, not by
    /// the link — several pulling different chunks is how a 22 GB remux keeps
    /// ahead of playback instead of losing to it by half.
    private var workers: [SegmentDownloader] = []
    /// How many workers may hold a live request right now. Starts gentle,
    /// grows by one per completed chunk, and HALVES when the origin answers
    /// 429/503 — the provider's ceiling is discovered, not assumed.
    private var parallelLimit = initialParallel
    /// Where a session starts. The old 2 took nearly a minute of ramping to
    /// reach a provider's real ceiling — a minute spent at a fraction of the
    /// available speed, right when the cache most needs to get ahead. Opening
    /// at 4 costs nothing when the provider is fine with it and costs one 429
    /// (which halves it straight back) when it isn't.
    private static let initialParallel = 4
    /// How long the ramp waits before probing upward again. DOUBLES on every
    /// 429 and eases back down when a probe survives.
    ///
    /// A fixed interval turns a provider that allows exactly one connection
    /// into a permanent 429 storm — probe, refused, halve, wait, probe again,
    /// forever. That is not just noise a provider may eventually ban for: the
    /// refused request frequently lands on the worker that was actually
    /// WORKING, which then sits out its retry delay doing nothing. The storm
    /// was costing a large slice of the very throughput it was looking for.
    private var rampInterval: TimeInterval = rampIntervalMin
    private static let rampIntervalMin: TimeInterval = 5
    /// Longest the ramp will wait before probing for another connection.
    ///
    /// Was 240s. Four minutes at one connection is a very long time to accept a
    /// third of the achievable speed on the word of a single 429 — measured on
    /// the device, `pool=1/1` sustained 10.2 MB/s where 8/8 had been doing 35.
    /// A 429 is cheap and handled (the segment is kept and retried); an
    /// unnecessary four-minute crawl is not.
    private static let rampIntervalMax: TimeInterval = 60
    /// Below this much ROAD AHEAD — in seconds of film, not bytes — the ramp
    /// stops being patient and probes at the minimum interval.
    ///
    /// This was 64 MB, which sounds generous and is not: on the remux measured
    /// here it is TEN SECONDS of playback, so the cache had to be within ten
    /// seconds of running dry before it would try for a second connection. Two
    /// minutes is the point at which a single connection is visibly losing.
    private static let rampUrgentLeadSeconds: Double = 120
    /// No ramp-up (and retries wait) until this passes.
    private var throttledUntil = Date.distantPast
    /// Last time the ramp probed upward, so growth is paced by TIME, not by
    /// chunk completions — a single-connection session runs one long segment
    /// that may not complete for minutes, and completion-driven ramping left
    /// it stuck at one connection forever.
    private var lastRampAt = Date.distantPast

    /// The lowest connection count this origin has refused. The ramp stops one
    /// below it rather than rediscovering it every minute.
    private var throttleCeiling: Int?
    /// Every so often, allow one probe back INTO the ceiling — a provider's
    /// limit is per-account and per-moment, not a law.
    private var lastCeilingProbeAt = Date.distantPast
    private static let ceilingRetestInterval: TimeInterval = 300
    /// Next byte to hand out. Chunks are assigned in order from here, so the
    /// contiguous coverage the reader needs grows from the front even though
    /// the fetches complete out of order.
    private var fetchCursor: Int64 = 0

    // MARK: Sliding window (queue-confined)

    /// The most bytes this session may hold on disk at once. Equal to the
    /// file size in full-file mode; smaller when `windowed`.
    private var budget: Int64 = 0
    /// The file doesn't fit whole — cache a sliding window of it instead.
    private var windowed = false
    /// The download hit the budget and is waiting for playback to advance.
    private var pausedForSpace = false
    /// `F_PUNCHHOLE` failed once — stop evicting (the window can't slide;
    /// what's cached stays useful, the download just ends at the budget).
    private var evictionBroken = false
    /// Total bytes hole-punched this session, for diagnostics.
    private var evictedTotal: Int64 = 0
    /// Where each live reader currently is, so eviction never pulls bytes out
    /// from under the slowest one.
    private var readOffsets: [ObjectIdentifier: Int64] = [:]
    /// When each reader last MOVED. A reader's offset alone can't tell a
    /// player parked on a pause from one the engine walked away from, and that
    /// difference is the whole story behind a window that won't slide — so the
    /// probe reports the age alongside the position.
    private var readTouchedAt: [ObjectIdentifier: Date] = [:]

    /// Register (or advance) a playback reader's position.
    private func noteRead(_ connection: NWConnection, _ offset: Int64) {
        if !archiveOriginSet {
            archiveOriginSet = true
            archiveOrigin = offset
        }

        readOffsets[ObjectIdentifier(connection)] = offset
        readTouchedAt[ObjectIdentifier(connection)] = Date()
    }
    /// Where this session's first real read landed — the resume point on a
    /// Continue Watching start, or zero on a fresh one.
    ///
    /// The from-the-start archive fill begins HERE rather than at byte zero.
    /// Resuming an hour into a film and then caching the opening credits first
    /// is the wrong hour of the film to have on disk: what the viewer is near,
    /// and what they are likely to jump back to, is all after the point they
    /// came in at. The fill still wraps round to the beginning once everything
    /// from here on is covered, so the earlier part is not abandoned — just
    /// last in line.
    private var archiveOrigin: Int64 = 0
    private var archiveOriginSet = false

    /// Everywhere the viewer has actually been this session, oldest first.
    ///
    /// A seek destination gets demand-fetched and then built forward by the
    /// normal window — and the moment the viewer moves on, that region stops
    /// growing and is never returned to. These are the places worth having on
    /// disk: somebody who jumps around a title jumps around the SAME title, and
    /// the second visit to a scene should come off the disk.
    private var visitedAnchors: [Int64] = []
    /// Two reads closer than this are the same place.
    private static let visitedSpacingBytes: Int64 = 256 * 1_048_576
    /// Keep the list bounded; the oldest place is the first to be forgotten.
    private static let visitedAnchorLimit = 16
    /// How much film to build around each visited place before moving on.
    private static let visitedSpanBytes: Int64 = 512 * 1_048_576

    /// Most connections the archive may hold at once.
    ///
    /// "Strictly last" was only ever true of ASSIGNMENT. A worker that has been
    /// handed a 16 MB archive chunk keeps it until it finishes, and nothing
    /// stopped all eight being handed one — so the moment the viewer seeked,
    /// `repositionForSeek` could take exactly ONE worker back and the other
    /// seven carried on fetching film from elsewhere in the title. That is the
    /// whole of "caching is very slow" and "scrubbing takes a bit to load when
    /// I jump somewhere else": the playhead was down to a single connection
    /// while the pool looked busy.
    private static let archiveWorkerCap = 2

    /// The cap ACTUALLY in force, scaled to the pool the origin is allowing.
    ///
    /// `archiveWorkerCap` is an absolute 2, written against a pool of six to
    /// eight — where two really does leave "most of the pool free". It says
    /// nothing about the case the throttle creates: a provider that answers
    /// 429 drops `parallelLimit` to ONE, and `workersOnArchive < 2` then still
    /// admits an archive worker, which is 100% of the connections. The comment
    /// above `nextArchiveGap` promises the archive "can never take a connection
    /// from the viewer"; on a throttled origin it took the only one there was.
    ///
    /// Caught on device: both buffering holds of one session had `pool=1/1`,
    /// `archiveWorkers=1/2`, archive `filling`, BOTH demux queues empty — and
    /// 614 seconds of film already on disk. The bytes were there; the one
    /// connection that could have fetched the next ones was archiving a part of
    /// the film nobody was watching.
    ///
    /// One below the pool, so the playhead always keeps a connection: at a
    /// limit of 1 the archive stands down entirely, at 2 it may take one, and
    /// from 3 up the original cap of 2 governs as before.
    private var archiveWorkerLimit: Int {
        min(Self.archiveWorkerCap, max(0, parallelLimit - 1))
    }

    /// Road the viewer must have in front of them before any of the pool is
    /// spent on film they are not watching. After a seek this is zero, so the
    /// archive stands down completely until the new position is fed.
    private static let archiveMinLeadBytes: Int64 = 384 * 1_048_576

    /// Connections currently fetching for the archive rather than the playhead.
    ///
    /// Judged by position rather than bookkeeping: a segment outside the band
    /// the playhead cares about — behind its rewind margin, or past the lead
    /// ceiling — is archive work by definition.
    private var workersOnArchive: Int {
        let low = liveReadAnchor() - keepBehindBytes
        let high = fillCeiling
        return workers.count { worker in
            guard let segment = worker.pendingSegment else { return false }
            return segment.start < low || segment.start >= high
        }
    }

    /// Note a place the viewer has been, if it is somewhere new.
    private func noteVisited(_ offset: Int64) {
        guard !visitedAnchors.contains(where: { abs($0 - offset) < Self.visitedSpacingBytes })
        else { return }
        visitedAnchors.append(offset)
        if visitedAnchors.count > Self.visitedAnchorLimit { visitedAnchors.removeFirst() }
    }

    /// The most recent MINIMUM of the active media readers — the playhead
    /// estimate that survives the moments between range requests when no
    /// reader happens to be connected. (A high-water mark was wrong twice
    /// over: an engine's open probes the file at far offsets, and one such
    /// read dragged the "playhead" deep into the film, mispointing both the
    /// request routing and the sliding window's eviction.)
    private var lastReadOffset: Int64 = 0

    /// Free space the volume must ALWAYS retain, at session start and for as
    /// long as the download runs.
    ///
    /// tvOS is not a general-purpose OS with a user-managed disk. When internal
    /// storage runs out the app's own writes begin failing mid-playback, the
    /// whole UI thrashes on I/O, and the system itself can stutter or reboot.
    /// The old 1.5 GB slack left the box sitting exactly on that cliff — which
    /// is why the cache "worked" while taking the Apple TV down with it. 4 GB is
    /// the floor tvOS needs for its own caches, logs, swap and updates.
    private static let slackBytes: Int64 = 4096 * 1_048_576
    /// How often the write path re-samples REAL free space.
    ///
    /// The budget is decided once, when the file's length is learned. A session
    /// can then run for hours while the rest of the box consumes storage (the
    /// DV remuxer, CFNetwork spools, scrub previews, the system itself), so a
    /// budget that was safe at second one is not a promise about minute ninety.
    /// Sampling is a cheap stat, but not free enough to sit on every 4 MB flush.
    private static let freeSpaceCheckInterval: TimeInterval = 5
    /// A window smaller than this isn't worth running.
    private static let minWindowBytes: Int64 = 2048 * 1_048_576
    /// Never evict the container header (MKV SeekHead/Tracks, MP4 moov-at-
    /// front): an engine reopen re-reads it.
    private static let headerProtectBytes: Int64 = 8 * 1_048_576
    /// Floor for the rewind margin kept behind the slowest reader.
    private static let keepBehindFloorBytes: Int64 = 256 * 1_048_576
    /// How much watched film to keep, in seconds of it.
    private static let keepBehindSeconds: Double = 240
    /// Bytes ahead of a reader that eviction will not touch — what it could
    /// plausibly stream into next.
    private static let keepAheadBytes: Int64 = 256 * 1_048_576

    /// Rewind margin: film just watched that eviction will not reclaim, so
    /// backing up lands on disk instead of on the network.
    ///
    /// In SECONDS of film, not bytes. A flat 256 MB is a rewind window whose
    /// length depends entirely on the bitrate of what you happen to be
    /// watching: on a 55 GB remux it is thirty-seven seconds, so "back up forty
    /// seconds" re-fetched every time. Capped at a quarter of the budget so it
    /// can never crowd out the lead.
    private var keepBehindBytes: Int64 {
        guard totalLength > 0, durationSeconds > 0 else { return Self.keepBehindFloorBytes }
        let byTime = Int64(Double(totalLength) / durationSeconds * Self.keepBehindSeconds)
        return min(max(byTime, Self.keepBehindFloorBytes),
                   max(budget / 4, Self.keepBehindFloorBytes))
    }
    /// Don't hole-punch dribbles; wait until at least this much is evictable.
    private static let minEvictBytes: Int64 = 64 * 1_048_576
    /// Pause the download when within this margin of the budget…
    private static let writeHeadroomBytes: Int64 = 32 * 1_048_576
    /// …and resume only once at least this much has been freed (hysteresis).
    private static let resumeHeadroomBytes: Int64 = 256 * 1_048_576
    /// An uncovered request this far past the frontier is a deep seek (jump);
    /// anything nearer is about to arrive sequentially anyway.
    private static let jumpAheadSlopBytes: Int64 = 4 * 1_048_576

    /// A target already inside a worker's segment counts as covered, however
    /// far back that worker currently is, once the pool is down to a single
    /// connection.
    ///
    /// With one worker you cannot serve two points at once, and trying serves
    /// NEITHER. Caught on the device: a DV session whose engine kept two
    /// readers about ten megabytes apart, and `jumpAheadSlopBytes` is four — so
    /// the worker feeding the lower reader never counted as covering the upper
    /// one. Every range request from the upper reader took the worker away
    /// (`SEEK-JUMP 11703MB -> 11713MB`), which starved the lower one, which
    /// took it straight back (`PREEMPT 11728MB -> starved reader at 11703MB`),
    /// about ten times a second. The frontier gained ONE megabyte while the
    /// pool wrote thirty-two, the reader's road ahead sat at zero, and the
    /// cache crawled at 2 MB/s on a link doing far better — "the cache isn't
    /// growing much outside of a little bit in front".
    ///
    /// Ten megabytes at the observed rate is a few seconds' wait. Ping-ponging
    /// the only connection is an unbounded one.
    private var effectiveJumpSlop: Int64 {
        parallelLimit <= 1 ? .max / 4 : Self.jumpAheadSlopBytes
    }

    /// How long a reader may sit on bytes nobody is delivering before the
    /// session gives up and hands the engine the origin. Shorter than an
    /// engine's own patience on purpose: the fallback should happen while the
    /// viewer is still waiting for a first frame, not after it has given up.
    ///
    /// 25 s DID NOT HONOUR THAT. Both engines bound a stalled read at
    /// `rw_timeout` = 20 s (PlayerViewModel.formatContextOptions and
    /// DVSampleEngine's open options), so a stalled download was declared dead
    /// by the ENGINE five seconds before this could fail open — the player
    /// errored, the app failed over to the next source, and every source served
    /// through the same proxy could stall the same way ("most of them fail as
    /// well"). A seek or an audio/subtitle switch is a fresh reader on bytes
    /// the pool has not delivered, so it hit the identical race. 12 s leaves a
    /// full 8 s of margin for the engine to follow the 307 and read direct,
    /// and matches `metadataTimeout`.
    private static let stallTimeout: TimeInterval = 12
    /// How long the download may sit parked on a full window with nothing to
    /// evict before the cache gives up and plays from the origin instead. Must
    /// also beat the engines' 20 s read bound — this is the ONE failure path
    /// where `downloadDead` is suppressed (`pausedForSpace`), so it is the only
    /// clock that can hand a wedged reader back to the origin.
    private static let wedgeTimeout: TimeInterval = 12
    /// When the download parked for space, so the deadlock above is escapable.
    private var pausedForSpaceSince: Date?
    /// How long the first request may wait for the origin to reveal the file
    /// length before the session falls back to direct playback.
    private static let metadataTimeout: TimeInterval = 12

    /// Ceiling on concurrent range requests. Debrid providers rate-limit per
    /// CONNECTION, so parallelism multiplies throughput — but past the
    /// provider's per-account ceiling it answers 429 instead. `parallelLimit`
    /// ramps toward this and backs off when throttled; this is only the cap.
    /// Tiered: each worker is a live TLS/H2 stream whose delegate work lands
    /// on the same serial queue that serves the player its bytes — eight of
    /// them beside a 1080p decode saturates the A8's two cores, and the ramp
    /// happily gets there on throughput alone.
    private static let workerCount = PerformanceProfile.isLowPower ? 4
        : PerformanceProfile.isMidPower ? 6 : 8
    /// How far ahead of an active reader the pool tries to stay before doing
    /// background fill. The demand side of the demand-driven pool.
    private static let readerLookaheadBytes: Int64 = 96 * 1_048_576
    /// THE OPENING BURST. Infuse's cache visibly grabs about a minute of the
    /// film the moment playback starts and only then settles into a steady
    /// crawl, and the reason is worth stating: a cushion measured in SECONDS
    /// is the only thing that makes a stall impossible, and it is worth
    /// everything the connection has until it exists. Nothing goes anywhere
    /// else — not background fill, not the holes behind — until the viewer
    /// has this much road in front of them.
    private static let burstSeconds: Double = 60
    /// Until the player has told us the runtime, a flat stand-in.
    private static let burstFallbackBytes: Int64 = 256 * 1_048_576
    /// Runtime in seconds, from the player. Only used to turn `burstSeconds`
    /// into bytes at the file's average rate.
    private var durationSeconds: Double = 0
    /// Bytes per assignment. Large enough that a request's latency is
    /// amortised, small enough that a slow worker can't hold the contiguous
    /// edge back for long — the reader can only advance through bytes that
    /// have MERGED with the coverage in front of it.
    private static let chunkBytes: Int64 = 16 * 1_048_576

    /// A bounded range request this far from the frontier is metadata, not
    /// playback — MKV cues and MP4 moov tables sit at the END of the file and
    /// the demuxer reads them repeatedly while probing. Fetch those on the
    /// side instead of dragging the sequential download to them.
    private static let sideFetchMaxBytes: Int64 = 8 * 1_048_576
    /// Side fetches in flight, keyed by start offset (also the de-dup — the
    /// demuxer asks for the same cue block more than once).
    private var sideFetchers: [Int64: SideFetcher] = [:]
    /// Their byte spans, so chunk assignment treats them as claimed.
    private var sideFetchSpans: [Int64: Int64] = [:]
    /// The end of the CONTIGUOUS run of cached bytes in front of the reader —
    /// the only frontier that means anything to a player, since it can only
    /// advance through bytes that have merged with what it is already reading.
    ///
    /// Emphatically NOT `ranges.last?.end`: once a side fetch has pulled the
    /// container index in from the tail, the last range ENDS AT THE END OF THE
    /// FILE. Every subsequent request then looked like it was safely behind
    /// the download, so a cue read in the middle of the file neither jumped
    /// nor side-fetched — it just waited for bytes that were hundreds of
    /// megabytes away, and the engine hung there. Nor is it "the last byte
    /// written": with a parallel pool those land out of order.
    private var downloadHead: Int64 { coverageEnd(from: liveReadAnchor()) }

    /// Dev diagnostics: how many proxy requests have been narrated to the
    /// trail. Bounded — an engine makes hundreds and the trail holds 40 lines.
    private var loggedRequests = 0
    private func requestTrail(_ line: String, important: Bool = false) {
        if !important {
            guard loggedRequests < 18 else { return }
            loggedRequests += 1
        }
        PlayerViewModel.colorTrail("proxy \(line)")
    }

    // MARK: - HUD snapshot

    /// A lock-guarded copy of the session's coverage, readable from the main
    /// actor every clock tick without touching the server queue — the player's
    /// cache bar draws from this.
    private let snapshotLock = NSLock()
    private var snapshotRanges: [CachedRange] = []
    private var snapshotTotal: Int64 = -1
    /// Why the session failed, when it has — published so the UI can stop
    /// pretending a cache is live and fall back to the engine's buffer band.
    private var snapshotFailure: String?
    /// Last listener state, for the probe ("no session" included).
    private var snapshotListenerState = "none"
    /// Queue-confined master copy of the failure reason.
    private var failureReason: String?

    /// Told once, when this session's origin has proved it cannot serve a
    /// cacheable stream — an HTTP status to a plain byte-range GET, not a
    /// dropped connection. The source picker uses it to stop choosing that
    /// link again.
    ///
    /// The distinction matters: a flaky link deserves the three retries this
    /// class already makes. An origin that answers 500 to every range request
    /// is not flaky, it is the wrong KIND of link — a cast endpoint dressed as
    /// a file — and no number of retries changes that. Seen on a "DMM Cast for
    /// TorBox" entry that played (the proxy fails open to the origin) while
    /// caching, seeking and scrub previews were all quietly impossible.
    var onOriginRefusedRanges: ((String) -> Void)?
    private var snapshotWindow: String?
    // Raw ramp/throttle values. The old snapshotRamp/snapshotPool STRINGS
    // were formatted inside publishSnapshot — i.e. on every ~4 MB flush and
    // every 80 ms reader-wait poll, on the same serial queue that serves the
    // player its bytes — for lines only the dev probe ever reads. The
    // consumers (statusLine / probeLines) format them on demand instead.
    private var snapshotRampInterval: TimeInterval = 0
    private var snapshotSinceRamp: TimeInterval = 0
    private var snapshotThrottleHold: TimeInterval = 0
    private var snapshotThrottleCeiling: Int?
    /// How far the download is AHEAD of the furthest reader. Negative or tiny
    /// means the download is barely keeping up (or losing) and nothing else
    /// should be competing with it for the connection, the disk or the CPU.
    private var snapshotLead: Int64 = 0
    private var snapshotDuration: Double = 0
    private var snapshotReaders: [(offset: Int64, idle: TimeInterval)] = []
    private var snapshotHead: Int64 = 0
    /// The two numbers that decide whether the pool may fetch anything at all.
    /// Not derivable from the others, and reasoning about them from the outside
    /// cost hours — so the probe states them outright.
    private var snapshotAnchor: Int64 = 0
    private var snapshotCeiling: Int64 = 0
    private var snapshotArchiveUsed: Int64 = 0
    private var snapshotArchiveCeiling: Int64 = 0
    private var snapshotVisited: [Int64] = []
    private var snapshotArchiveWorkers = 0
    private var snapshotArchiveWorkerLimit = 0
    private var snapshotOldest: Int64?
    /// Mirror of the live session's origin, for beginSession's same-origin
    /// check (it runs on the main actor, before parking on `q`).
    private var snapshotOrigin: URL?
    private var snapshotDownloadRate: Double = 0
    private var snapshotWorkerCount = 0
    private var snapshotWindowed = false
    private var snapshotPaused = false
    private var snapshotBudget: Int64 = 0
    private var snapshotEvicted: Int64 = 0
    /// Last live free-space sample, so the probe can show the floor being
    /// approached instead of only reporting the failure once it trips.
    private var snapshotFreeBytes: Int64 = -1
    private var snapshotSideFetches = 0
    private var snapshotLastWriteAge: TimeInterval = 0
    private var snapshotBusy = 0
    private var snapshotLimit = 0
    private var snapshotSegments: [Int64] = []
    /// The cache-only preview url for the live session, or nil when there
    /// isn't one. Published into the snapshot rather than read back through
    /// `q`: the fine preview pass asks for this from the main actor in the
    /// middle of a scrub, and `q` is carrying every worker's writes and the
    /// window's hole-punching — a `sync` onto it is a stall the viewer feels
    /// in the gesture itself.
    private var snapshotThumbnailURL: URL?

    /// Recompute `snapshotThumbnailURL` from the live session. On q — it reads
    /// the queue-confined session identity.
    private func publishThumbnailURL() {
        var url: URL?
        if !token.isEmpty, listener != nil, let origin {
            let ext = origin.pathExtension.lowercased()
            let name = ext.isEmpty ? "v" : "v.\(ext)"
            url = URL(string: "http://127.0.0.1:\(Self.port)/t/\(token)/\(name)")
        }
        snapshotLock.lock()
        snapshotThumbnailURL = url
        snapshotLock.unlock()
    }

    private func publishSnapshot() {
        snapshotLock.lock()
        snapshotOrigin = origin
        snapshotRanges = ranges
        snapshotTotal = totalLength
        snapshotFailure = failureReason
        snapshotWindow = windowed
            ? "window budget=\(budget) paused=\(pausedForSpace) evicted=\(evictedTotal)\(evictionBroken ? " EVICTION BROKEN" : "")"
            : nil
        snapshotLead = downloadHead - liveReadAnchor()
        snapshotDuration = durationSeconds
        let now = Date()
        snapshotReaders = readOffsets
            .map { (offset: $0.value,
                    idle: now.timeIntervalSince(readTouchedAt[$0.key] ?? now)) }
            .sorted { $0.offset < $1.offset }
        snapshotHead = downloadHead
        snapshotAnchor = liveReadAnchor()
        snapshotCeiling = fillCeiling
        snapshotArchiveUsed = usedBytes()
        snapshotArchiveCeiling = windowed ? archiveCeiling : 0
        snapshotVisited = visitedAnchors
        snapshotArchiveWorkers = workersOnArchive
        snapshotArchiveWorkerLimit = archiveWorkerLimit
        snapshotOldest = ranges.min(by: { $0.born < $1.born })?.start
        snapshotWorkerCount = workers.count
        snapshotRampInterval = rampInterval
        snapshotSinceRamp = now.timeIntervalSince(lastRampAt)
        snapshotThrottleHold = max(throttledUntil.timeIntervalSinceNow, 0)
        snapshotThrottleCeiling = throttleCeiling
        snapshotWindowed = windowed
        snapshotPaused = pausedForSpace
        snapshotBudget = budget
        snapshotEvicted = evictedTotal
        snapshotFreeBytes = lastKnownFreeBytes
        snapshotSideFetches = sideFetchSpans.count
        snapshotLastWriteAge = now.timeIntervalSince(lastWriteAt)
        // A rate that has gone quiet is 0, not the last busy reading.
        snapshotDownloadRate = now.timeIntervalSince(lastWriteAt) > 3 ? 0 : measuredRate
        snapshotBusy = workers.count(where: { !$0.isIdle })
        snapshotLimit = parallelLimit
        snapshotSegments = workers.compactMap(\.pendingSegment).map(\.start).sorted()
        snapshotLock.unlock()
    }

    /// "pool=busy/limit (origin caps at N)" — formatted on demand from the
    /// raw snapshot values. Callers hold `snapshotLock`.
    private var snapshotPoolLine: String {
        "pool=\(snapshotBusy)/\(snapshotLimit)"
            + (snapshotThrottleCeiling.map { " (origin caps at \($0))" } ?? "")
    }

    /// One-line state for diagnostics (the dev probe endpoint): totals, how
    /// much is on disk, and the failure reason when the session has bailed.
    var statusLine: String {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal != -1 || snapshotFailure != nil || !snapshotRanges.isEmpty else {
            return "cache: no session"
        }
        let onDisk = snapshotRanges.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
        var line = "cache: total=\(snapshotTotal) onDisk=\(onDisk) ranges=\(snapshotRanges.count)"
            + " lead=\(snapshotLead / 1_048_576)MB \(snapshotPoolLine)"
        if let window = snapshotWindow { line += " " + window }
        if let failure = snapshotFailure { line += " FAILED: \(failure)" }
        return line
    }

    /// How far (as a fraction of the whole file) the on-disk cache extends
    /// CONTIGUOUSLY from the given playback fraction — what the growing cache
    /// bar shows ahead of the playhead. 0 when no session is live. Byte↔time
    /// mapping is linear, which is exactly as honest as any player's buffer
    /// bar for variable-bitrate files.
    /// A hybrid-cache session is running (a file is being written for the
    /// current stream). Read from the snapshot so it is safe on the main actor.
    var hasLiveSession: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        // A failed session is not live: leaving this true suppressed even the
        // engine-buffer fallback band, so a disk-space bail-out erased the
        // band entirely instead of degrading to the normal sliver.
        return snapshotTotal > 0 && snapshotFailure == nil
    }

    /// One coherent reading of the cache for the player's status panel —
    /// everything under a single lock hold, safe from the main actor.
    struct HealthSnapshot {
        var hasSession = false
        /// Bytes/second landing on disk over the last ~2s; 0 when quiet.
        var downloadRate: Double = 0
        /// Seconds of playback the download is ahead of the furthest reader.
        var leadSeconds: Double = 0
        var leadBytes: Int64 = 0
        var onDiskBytes: Int64 = 0
        var totalBytes: Int64 = 0
        /// Connections actually fetching / allowed / origin's known ceiling.
        var busyWorkers = 0
        var workerLimit = 0
        var originCap: Int?
        /// Sliding-window mode (file bigger than the disk budget).
        var windowed = false
        var evictedBytes: Int64 = 0
        var pausedForSpace = false
        var lastWriteAge: TimeInterval = 0
        /// Real free space on the cache volume, last sampled (-1 = unknown).
        var freeBytes: Int64 = -1
        var failure: String?
    }

    var health: HealthSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        var h = HealthSnapshot()
        h.hasSession = snapshotTotal > 0 && snapshotFailure == nil
        h.downloadRate = snapshotDownloadRate
        h.leadSeconds = readerLeadSecondsLocked
        h.leadBytes = snapshotLead
        h.onDiskBytes = snapshotRanges.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
        h.totalBytes = max(snapshotTotal, 0)
        h.busyWorkers = snapshotBusy
        h.workerLimit = snapshotLimit
        h.originCap = snapshotThrottleCeiling
        h.windowed = snapshotWindowed
        h.evictedBytes = snapshotEvicted
        h.pausedForSpace = snapshotPaused
        h.lastWriteAge = snapshotLastWriteAge
        h.freeBytes = snapshotFreeBytes
        h.failure = snapshotFailure
        return h
    }

    func coverageFraction(fromTimeFraction f: Double) -> Double {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 else { return 0 }
        let byte = Int64(min(max(f, 0), 1) * Double(snapshotTotal))
        for range in snapshotRanges where range.start <= byte && byte <= range.end {
            return Double(range.end) / Double(snapshotTotal)
        }
        // The linear time→byte estimate can land a little short of where the
        // engine is actually reading (variable bitrate, container header).
        // The segment being written just ahead of the playhead IS the cache
        // the viewer is watching grow — show it rather than nothing.
        // Bridge measured in SECONDS of film, not a flat 2% of the file:
        // total/50 on a 2-hour title bridged a ~2.4-MINUTE undownloaded hole
        // and reported the far segment's end as "cached", so the band lied
        // about exactly the stretch the engine was about to stall in. ~5s
        // covers the estimate slack the bridge exists for; when the runtime
        // is unknown yet, fall back to a small flat fraction.
        let bridge = snapshotDuration > 1
            ? Int64(Double(snapshotTotal) * 5.0 / snapshotDuration)
            : snapshotTotal / 200
        if let ahead = snapshotRanges.first(where: { $0.start > byte }),
           ahead.start - byte < bridge {
            return Double(ahead.end) / Double(snapshotTotal)
        }
        return 0
    }

    /// The live probe's view of the cache: levels, not events.
    ///
    /// The reader table is the point. Every symptom that starts with "it works
    /// for the first few seeks" comes back to a row in it — a reader whose
    /// offset stopped moving while its idle time climbs is one the engine
    /// abandoned, and while one of those is in the list `minActiveRead()` is
    /// pinned there: eviction protects the file from that point on, the window
    /// cannot slide, `paused` sticks, and the download stops. Read the table
    /// against `lead`, and it says so at a glance.
    var probeLines: [String] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 || snapshotFailure != nil else {
            return ["no session (listener \(snapshotListenerState))"]
        }
        func mb(_ bytes: Int64) -> String { String(format: "%.0fMB", Double(bytes) / 1_048_576) }
        let onDisk = snapshotRanges.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
        var lines = [
            "total=\(mb(snapshotTotal)) onDisk=\(mb(onDisk)) ranges=\(snapshotRanges.count)"
                + " head=\(mb(snapshotHead))",
            "lead=\(mb(snapshotLead)) (\(String(format: "%.0f", readerLeadSecondsLocked))s"
                + ") lastWrite=\(String(format: "%.1f", snapshotLastWriteAge))s ago",
            "pool=\(snapshotBusy)/\(snapshotLimit) segments=\(snapshotSegments.map { mb($0) }.joined(separator: ","))"
                + " sideFetch=\(snapshotSideFetches)",
            "window budget=\(mb(snapshotBudget)) paused=\(snapshotPaused) evicted=\(mb(snapshotEvicted))"
                + " free=\(snapshotFreeBytes < 0 ? "?" : mb(snapshotFreeBytes))",
            "anchor=\(mb(snapshotAnchor)) ceiling=\(mb(snapshotCeiling))"
                + " windowed=\(snapshotWindowed ? "Y" : "n")"
                + " allowed=\(mb(max(snapshotCeiling - snapshotAnchor, 0)))",
            "ramp " + String(
                format: "limit=%d workers=%d interval=%.0fs sinceProbe=%.0fs hold=%.0fs ceiling=%@",
                snapshotLimit, snapshotWorkerCount, snapshotRampInterval,
                snapshotSinceRamp, snapshotThrottleHold,
                snapshotThrottleCeiling.map(String.init) ?? "-"),
            "oldestCached=\(snapshotOldest.map { mb($0) } ?? "-")"
                + " (next to go)",
            "visited=\(snapshotVisited.map { mb($0) }.joined(separator: ","))"
                + " archiveWorkers=\(snapshotArchiveWorkers)/\(snapshotArchiveWorkerLimit)",
            snapshotWindowed
                ? "archive=\(mb(snapshotArchiveUsed))/\(mb(snapshotArchiveCeiling))"
                    + " (\(snapshotArchiveUsed < snapshotArchiveCeiling ? "filling" : "full"))"
                : "archive=n/a (whole file fits — no window, nothing to ration)",
        ]
        if snapshotReaders.isEmpty {
            lines.append("readers: none")
        } else {
            // ABANDONED, not merely idle. A paused player's reader sits still
            // too, and flagging that cried wolf on every pause — the marker has
            // to mean the thing it was added to catch: a reader left behind
            // while a NEWER one reads somewhere else.
            let furthest = snapshotReaders.map(\.offset).max() ?? 0
            for reader in snapshotReaders {
                let abandoned = reader.idle > 5 && reader.offset < furthest
                lines.append(String(format: "reader @%@ idle=%.1fs%@",
                                    mb(reader.offset), reader.idle,
                                    abandoned ? "  <-- ABANDONED" : ""))
            }
        }
        if let failure = snapshotFailure { lines.append("FAILED: \(failure)") }
        return lines
    }

    /// `readerLeadSeconds` for callers that already hold the snapshot lock.
    private var readerLeadSecondsLocked: Double {
        guard snapshotTotal > 0, snapshotDuration > 0 else { return 0 }
        let bytesPerSecond = Double(snapshotTotal) / snapshotDuration
        guard bytesPerSecond > 0 else { return 0 }
        return Double(snapshotLead) / bytesPerSecond
    }

    /// How far the download is ahead of the furthest reader, in bytes. The
    /// honest measure of whether the cache is winning: on a high-bitrate remux
    /// it can be pinned near zero, and anything else touching the file then
    /// makes playback worse rather than better.
    var readerLeadBytes: Int64 {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotLead
    }

    /// The same lead in SECONDS OF PLAYBACK, at the file's average rate.
    ///
    /// The honest unit for "is the cache winning?". A flat byte figure is not
    /// comparable across files: 128 MB is eight minutes of a 2 Mbps web-dl and
    /// twelve seconds of an 80 Mbps remux, so a byte threshold picked for the
    /// remux is one a web-dl reaches almost never — which is how the scrub
    /// preview pass, gated on exactly that, could sit out an entire film
    /// waiting for headroom it already had. 0 when the length or the runtime
    /// isn't known yet.
    var readerLeadSeconds: Double {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return readerLeadSecondsLocked
    }

    /// Covered byte ranges as 0…1 fractions of the file — what a scheduler
    /// needs to run work over ONLY the parts already on disk (the scrub
    /// preview pass). Empty until the file's length is known.
    var coveredFractions: [(start: Double, end: Double)] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 else { return [] }
        let total = Double(snapshotTotal)
        return snapshotRanges.map { (Double($0.start) / total, Double($0.end) / total) }
    }

    /// `coveredFractions` together with the live reader's position, as a 0…1
    /// fraction of the file, read under ONE lock hold so the band and the
    /// point it is calibrated against come from the same snapshot.
    ///
    /// Everything here is in BYTES. The transport bar is in TIME, and on a
    /// variable-bitrate file those disagree by minutes — a film whose opening
    /// is lighter than its average puts every later byte position well to the
    /// right of the matching timestamp. The reader's offset is the one byte
    /// position whose playback time the player actually knows (its engine's
    /// read head), which is what lets the bar convert the rest. `reader` is nil
    /// when there is no live reader or no known length.
    var coveredFractionsAndReader: (spans: [(start: Double, end: Double)], reader: Double?) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard snapshotTotal > 0 else { return ([], nil) }
        let total = Double(snapshotTotal)
        let spans = snapshotRanges.map { (Double($0.start) / total, Double($0.end) / total) }
        let reader: Double? = !snapshotReaders.isEmpty
            && snapshotAnchor > 0 && snapshotAnchor < snapshotTotal
            ? Double(snapshotAnchor) / total : nil
        return (spans, reader)
    }

    /// The cache-only twin of the playback URL for the live session. Reads on
    /// this lane are served solely from bytes already on disk: they never
    /// reposition the downloader, never wait for the network (an uncovered
    /// request is answered 416 immediately, a coverage edge closes the
    /// connection), and never count as playback for the sliding window's
    /// eviction. Built for the scrub-preview pass, whose seeks all over the
    /// file would otherwise drag the sequential download around with them.
    var thumbnailURL: URL? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotThumbnailURL
    }

    // MARK: - Public API (called from the main actor)

    /// Start caching `origin` and return the localhost URL to play instead,
    /// or nil when the stream doesn't qualify (non-http, already proxied,
    /// HLS/playlist) or the listener can't start. Ends any previous session.
    func beginSession(origin: URL, headers: [String: String]? = nil) -> URL? {
        guard let scheme = origin.scheme?.lowercased(), scheme == "http" || scheme == "https",
              origin.host != "127.0.0.1", origin.host != "localhost" else { return nil }
        let ext = origin.pathExtension.lowercased()
        guard ext != "m3u8", ext != "m3u" else { return nil }
        // Flag BEFORE parking on the queue, so already-enqueued heavy jobs
        // stand aside (see `sessionSwapPending`) — but ONLY for a genuine
        // swap. Raising it for a SAME-ORIGIN re-entry (DV-first fallback
        // reload, Try Again, failover retry of the same link — the exact
        // early-return below) made every queued worker flush ahead of the
        // sync early-out at `downloaderWrote` — after the worker had already
        // advanced its write cursor. The bytes were never written and never
        // retried: silent holes minted right in front of the playhead at
        // load time, i.e. "plays for a sec then freezes at a cached bit".
        // `snapshotOrigin` can lag the queue by one publish; the cost of a
        // stale read is only that a real swap waits behind the backlog.
        let liveOrigin: URL? = {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return snapshotOrigin
        }()
        if liveOrigin != origin { sessionSwapPending = true }
        defer { sessionSwapPending = false }
        return q.sync {
            // RE-ENTRY FOR THE SAME FILM keeps the live session and hands back
            // the SAME url. Two reasons, and the first is severe:
            //
            // 1. The token is a fresh UUID per session, so restarting here
            //    minted a NEW proxy url every time — and the player's
            //    "don't do this again" guards (`dvFirstTried`, `dvFailedURLs`,
            //    `probedURLs`) are all keyed on the url string. None of them
            //    could ever match, so a DV-first attempt retried forever. Worse,
            //    the teardown killed the connection feeding the engine that had
            //    just been started, which failed it over into another load —
            //    a self-sustaining reload loop in which nothing ever played.
            // 2. Even without that, throwing away a partly-downloaded film on
            //    an engine swap or a failover is pure waste.
            // The session is kept, but its URL is only worth handing out if
            // something is actually listening on it — rebuilt in place if not
            // (the token is session state, so the same URL keeps working).
            if self.origin == origin, !token.isEmpty,
               writeHandle != nil, failureReason == nil {
                // Same film, possibly re-entered with refreshed headers (a
                // re-signed link keeps the origin). Keep the bytes, but let the
                // pool use the current headers from here on.
                sessionHeaders = headers
                guard startListenerLocked() else { return nil }
                return proxyURL(for: origin)
            }
            teardownSessionLocked()
            guard startListenerLocked() else { return nil }
            self.origin = origin
            sessionHeaders = headers
            token = UUID().uuidString
            redirectAll = false
            rangeCapable = true
            totalLength = -1
            ranges = []
            loggedRequests = 0
            sideFetchers = [:]
            sideFetchSpans = [:]
            budget = 0
            windowed = false
            pausedForSpace = false
            pausedForSpaceSince = nil
            recoveryAttempts = 0
            evictionBroken = false
            evictedTotal = 0
            readOffsets = [:]
            readTouchedAt = [:]
            lastReadOffset = 0
            lastWriteAt = Date()   // a fresh session starts with a clean heartbeat
            freeSpaceCheckedAt = .distantPast   // and re-samples storage at once
            lastKnownFreeBytes = -1
            let dir = Self.cacheDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("current.bin")
            try? FileManager.default.removeItem(at: file)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
            fileURL = file
            writeHandle = handle
            fetchCursor = 0
            archiveOrigin = 0
            archiveOriginSet = false
            visitedAnchors = []
            parallelLimit = Self.initialParallel
            throttledUntil = .distantPast
            throttleCeiling = nil
            lastCeilingProbeAt = .distantPast
            lastRampAt = .distantPast
            lastPreemptAt = .distantPast
            rampInterval = Self.rampIntervalMin
            durationSeconds = 0
            ensurePool()
            publishThumbnailURL()
            return proxyURL(for: origin)
        }
    }

    /// The playback url for the live session. Keeps the origin's extension:
    /// the engine router picks native-vs-FFmpeg by it, and losing ".mkv" would
    /// send Matroska to AVPlayer.
    private func proxyURL(for origin: URL) -> URL? {
        let ext = origin.pathExtension.lowercased()
        let name = ext.isEmpty ? "v" : "v.\(ext)"
        return URL(string: "http://127.0.0.1:\(Self.port)/m/\(token)/\(name)")
    }

    /// Tell the cache how long the film is, so the opening burst can be
    /// sized in seconds of playback rather than a flat byte count. Cheap and
    /// idempotent — the player calls it whenever it learns a duration.
    func noteDuration(_ seconds: Double) {
        guard seconds > 0 else { return }
        q.async { [weak self] in
            guard let self, self.durationSeconds <= 0 else { return }
            self.durationSeconds = seconds
        }
    }

    /// Stop downloading, drop every connection, delete the cache file.
    ///
    /// Async on purpose. This is called from `PlayerViewModel.teardown()` on
    /// the main actor, and `q` is the queue every worker's URLSession delegate
    /// lands on — a `sync` here parks the exit behind an in-flight multi-
    /// megabyte write and whatever eviction that write triggers. Nothing reads
    /// a result, and the queue is serial, so a `beginSession` starting the next
    /// film still runs after this teardown.
    /// The app has just come back from being SUSPENDED.
    ///
    /// Every stall clock in here is wall-clock — `lastWriteAt`, the reader
    /// touch stamps — and tvOS freezes this process while the TV sleeps. So
    /// after a long sleep the first read finds "nothing written for 25s",
    /// fails the whole session and starts 307-redirecting the player at the
    /// origin (usually a debrid link, which then has to be re-resolved and
    /// surfaces as a source failure). The download really did stop, but the
    /// session is fine: reclaim the segments whose sockets the suspension
    /// killed, then restart the heartbeat the way a fresh session does.
    func noteAppResumed() {
        q.async { [weak self] in
            guard let self, self.writeHandle != nil, !self.redirectAll else { return }
            // Reaped FIRST, while the stamp is still old — that is the path
            // that cancels stuck segments and kicks the pool.
            self.reapStalledWorkers()
            self.lastWriteAt = Date()
            self.readTouchedAt = [:]
        }
    }

    func endSession() {
        q.async { [weak self] in self?.teardownSessionLocked() }
    }

    // MARK: - Session teardown (on q)

    private func teardownSessionLocked() {
        for worker in workers { worker.cancel() }
        workers = []
        fetchCursor = 0
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? writeHandle?.close()
        writeHandle = nil
        // RENAME HERE, UNLINK ELSEWHERE. Freeing a multi-gigabyte cache file is
        // real filesystem work — more of it once a windowed session has shredded
        // the file into hundreds of extents with `F_PUNCHHOLE` — and this
        // teardown runs with the main thread waiting on it: `beginSession`
        // rebuilds the session inside its own `q.sync` whenever the origin
        // changes, so every episode advance and every source switch used to pay
        // for the previous film's delete before the switching cover could move
        // again. A rename costs the same whatever the file holds; the extents
        // are released behind it. A rename the process doesn't outlive is not a
        // leak — `PlayerTempSweep` clears the whole hybrid-cache directory at
        // launch, which is the one moment no session can own anything in it.
        if let fileURL {
            let doomed = fileURL.deletingLastPathComponent()
                .appendingPathComponent("expired-\(UUID().uuidString).bin")
            do {
                try FileManager.default.moveItem(at: fileURL, to: doomed)
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.removeItem(at: doomed)
                }
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        fileURL = nil
        origin = nil
        sessionHeaders = nil
        token = ""
        ranges = []
        totalLength = -1
        failureReason = nil
        budget = 0
        windowed = false
        pausedForSpace = false
        pausedForSpaceSince = nil
        recoveryAttempts = 0
        evictionBroken = false
        evictedTotal = 0
        readOffsets = [:]
        readTouchedAt = [:]
        lastReadOffset = 0
        // Side fetches are not in `workers`, and clearing the dictionary does
        // NOT stop one — the URLSession and the fetcher own each other, so it
        // keeps running and its completion writes into whatever `writeHandle`
        // is open by the time it lands. `beginSession` tears down and re-creates
        // the cache file inside a single `q.sync`, so on a source switch that
        // handle is the NEW film's: the old link's bytes were written at the old
        // offset and `addRange` recorded the span as valid coverage, so the
        // correct bytes were never fetched again for the life of the session.
        for fetcher in sideFetchers.values { fetcher.cancel() }
        sideFetchers = [:]
        sideFetchSpans = [:]
        parallelLimit = Self.initialParallel
        throttledUntil = .distantPast
        publishThumbnailURL()   // token is cleared above: republishes as nil
        publishSnapshot()
    }

    /// Fetch a small, far-away byte range on its own connection, leaving the
    /// sequential downloader exactly where it is.
    ///
    /// Repositioning the main downloader for a container's index (what `jump`
    /// does) abandons the download that is feeding playback, and the two then
    /// pull against each other: the demuxer re-reads the cues, the downloader
    /// is yanked to the tail again, and the front creeps forward a few KB at a
    /// time. That is a startup that never finishes, not a slow one.
    private func sideFetch(start: Int64, endExclusive: Int64, attempt: Int = 0) {
        guard let origin, writeHandle != nil, !redirectAll else { return }
        guard sideFetchers[start] == nil else { return }   // already in flight
        // NEVER drop the request on the floor: the connection that triggered
        // it is sitting in `serve` waiting for those bytes, and with nobody
        // fetching them it waits out the full 60s stall timeout — the
        // intermittent "sometimes it just doesn't play". At capacity, wait a
        // beat and try again; capacity is small on purpose, because these
        // connections count against the same provider ceiling as the pool.
        guard sideFetchers.count < 3 else {
            q.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sideFetch(start: start, endExclusive: endExclusive, attempt: attempt)
            }
            return
        }
        sideFetchSpans[start] = endExclusive
        sideFetchers[start] = SideFetcher(
            origin: origin, headers: sessionHeaders,
            start: start, endExclusive: endExclusive, queue: q
        ) { [weak self] data in
            guard let self else { return }
            self.sideFetchers[start] = nil
            self.sideFetchSpans[start] = nil
            if let data, self.writeHandle != nil {
                self.downloaderWrote(data, at: start, isSideFetch: true)
            } else if attempt < 3 {
                // Backed-off retry — a 429 here clears in seconds.
                self.q.asyncAfter(deadline: .now() + Double(attempt + 1) * 2) { [weak self] in
                    self?.sideFetch(start: start, endExclusive: endExclusive, attempt: attempt + 1)
                }
            } else {
                self.requestTrail("SIDE-FETCH failed at \(start) — reader will fail over")
            }
        }
    }

    private static func cacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("hybrid-cache", isDirectory: true)
    }

    // MARK: - Listener (on q)

    /// Whether the listener is accepting (or has only just been started and is
    /// about to be). Queue-confined, like `listener`.
    private var listenerIsLive: Bool {
        guard let listener else { return false }
        switch listener.state {
        case .ready, .setup: return true
        default: return false
        }
    }

    #if DEBUG
    /// Dev probe hook (`/cachecheck` on :8123): run the SAME listener check a
    /// new session runs, then report what the listener became. Verifies the
    /// post-suspension rebuild on device without having to start a playback.
    func debugCheckListener(_ done: @escaping (String) -> Void) {
        q.async { [weak self] in
            guard let self, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let started = self.startListenerLocked()
            // State alone proved worthless after a suspension, so actually
            // connect: a refused or stalled connect is the ground truth.
            let probe = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            var reported = false
            let finish: (String) -> Void = { accepts in
                guard !reported else { return }
                reported = true
                probe.cancel()
                self.snapshotLock.lock()
                let state = self.snapshotListenerState
                self.snapshotLock.unlock()
                done("startListener=\(started) live=\(self.listenerIsLive) accepts=\(accepts)"
                     + " state=\(state) failures=\(self.listenerFailures)")
            }
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready: self.q.async { finish("yes") }
                case .failed(let error): self.q.async { finish("NO (\(error))") }
                case .waiting(let error): self.q.async { finish("NO (waiting: \(error))") }
                default: break
                }
            }
            probe.start(queue: self.q)
            self.q.asyncAfter(deadline: .now() + 2) { finish("NO (no answer in 2s)") }
        }
    }
    #endif

    /// Rebuild the listener as the app comes back from the background, BEFORE
    /// anything needs it — a resumed session reconnects within moments of the
    /// return, and a listener that lived through the suspension would refuse it
    /// (see `startListenerLocked`). Installed with the first listener.
    private func installLifecycleObserverIfNeeded() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.q.async { self?.rebuildListenerAfterSuspensionLocked() }
        }
        #endif
    }

    private func rebuildListenerAfterSuspensionLocked() {
        lastResumeAt = Date()
        // Nothing built yet: the next session builds a fresh one anyway.
        guard listener != nil else { return }
        _ = startListenerLocked()
    }

    private func noteListenerState(_ state: String) {
        snapshotLock.lock()
        snapshotListenerState = state
        snapshotLock.unlock()
        PlayerProbe.event("cache", "listener \(state)")
    }

    private func startListenerLocked() -> Bool {
        // A listener that EXISTS is not necessarily one that is LISTENING.
        //
        // This used to be `if listener != nil { return true }`, and every
        // session — plus the same-origin re-entry in `beginSession` — trusted
        // it. Backgrounding the app can leave this loopback listener `.waiting`
        // or `.failed` with the handle still set, and from then on each load
        // was handed a proxy URL with nothing behind it: "Could not connect to
        // the server" on every title, a failover onto the next link, the same
        // again, forever — "Comet isn't working in any movie" until the app
        // was relaunched. Measured on device: S2E1 played through the cache at
        // 187s, the app backgrounded at 259s, and every load after it failed
        // with no proxy request ever arriving.
        installLifecycleObserverIfNeeded()
        if let existing = listener {
            // SURVIVING A SUSPENSION IS DISQUALIFYING, WHATEVER IT REPORTS.
            // Measured on device (2026-09-16): after 75s in the background the
            // listener still read `.ready` — no state callback fired at all —
            // yet every connection to it was refused. The resumed Dolby Vision
            // session could not reconnect (black screen, 20s stall watchdog),
            // and every link the failover then tried died with "Could not
            // connect to the server", while the cache's own download workers
            // reached the origin fine. State cannot detect that, so age does.
            let predatesSuspension = listenerBuiltAt < lastResumeAt
            if listenerIsLive, !predatesSuspension { return true }
            // Retire it properly: `cancel()` releases the port so the rebuild
            // can bind it, and the handlers go first so its own `.cancelled`
            // callback can't touch the replacement. Connections it already
            // accepted are separate objects and carry on unaffected.
            existing.stateUpdateHandler = nil
            existing.newConnectionHandler = nil
            existing.cancel()
            listener = nil
            if predatesSuspension {
                // Routine, not a failure: must not push toward the back-off.
                noteListenerState("rebuilding after a suspension")
            } else {
                listenerFailures += 1
                noteListenerState("retired a dead listener (\(existing.state)) — rebuilding")
            }
        }
        // Rebuilding keeps failing: stop handing out URLs nothing will answer.
        // The caller declines the cache and the player goes straight to the
        // origin, which plays — just without the disk cache — until the delay
        // passes and a rebuild is tried again.
        if listenerFailures >= 2, Date() < listenerRetryAfter {
            noteListenerState("unavailable — playing without the cache for now")
            return false
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Localhost only — this is a private pipe to the player, not a
            // LAN service like the phone-paste server.
            params.requiredInterfaceType = .loopback
            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return false }
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.q.async { self?.accept(connection) }
            }
            // `.failed`/`.cancelled` mean the socket is gone underneath us (a
            // long suspension can do it). Guarded by IDENTITY: an unguarded
            // handler could nil the listener that REPLACED this one, when this
            // one's late callback finally arrived — dropping a healthy listener
            // for no reason. And cancelled, not just dropped, so the port is
            // released for the rebuild.
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                self?.q.async {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.listenerFailures = 0
                        self.listenerRetryAfter = .distantPast
                        self.noteListenerState("ready")
                    case .failed, .cancelled:
                        NSLog("[OrivioCache] listener %@ — will rebuild on the next session", "\(state)")
                        listener.stateUpdateHandler = nil
                        listener.newConnectionHandler = nil
                        listener.cancel()
                        self.listener = nil
                        self.listenerFailures += 1
                        if self.listenerFailures >= 2 {
                            self.listenerRetryAfter = Date().addingTimeInterval(Self.listenerRetryDelay)
                        }
                        self.noteListenerState("\(state) — will rebuild")
                    case .waiting(let error):
                        // Not acted on here: it may recover by itself. The next
                        // session finds it not live and rebuilds it.
                        self.noteListenerState("waiting (\(error))")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: q)
            self.listener = listener
            listenerBuiltAt = Date()
            if listenerFailures >= 2 {
                // A rebuild while failures stand: if this one dies too, back off.
                listenerRetryAfter = Date().addingTimeInterval(Self.listenerRetryDelay)
            }
            return true
        } catch {
            NSLog("[OrivioCache] listener failed: %@", "\(error)")
            listenerFailures += 1
            noteListenerState("could not be created (\(error))")
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let connection {
                self?.q.async { self?.drop(connection) }
            }
        }
        connection.start(queue: q)
        readRequest(connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        // A reader that is gone must stop steering the cache. Left behind, its
        // entry pins `minActiveRead()` at a position nobody is reading, which
        // is enough on its own to stop the whole download: eviction protects
        // everything from that offset forward, the window can't slide, the
        // budget fills, and `pausedForSpace` never lifts.
        readTouchedAt.removeValue(forKey: ObjectIdentifier(connection))
        if readOffsets.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            resumeIfRoom()   // the window may be free to slide the moment it goes
            kickPool()       // and the pool should re-aim at the readers that are left
        }
    }

    /// Keep one receive armed for the life of a response.
    ///
    /// Nothing more ever arrives on it — every response says `Connection:
    /// close` — so this exists purely to LEARN THAT THE PLAYER WENT AWAY.
    /// Without it, a reader parked in `serve`'s availability poll is invisible
    /// when the engine seeks and drops the socket: no send is in flight to
    /// fail, no receive is pending to complete, and NWConnection reports a
    /// peer close through neither. The connection sits `.ready` forever.
    ///
    /// That is the cache "stopping after a few jumps". Every seek leaves one
    /// more abandoned reader behind, each pinning eviction at its own dead
    /// offset and each looking permanently starved to
    /// `preemptForStarvedReader`, which then keeps hauling workers off the
    /// reader that IS playing to feed the ones that aren't.
    private func watchForPeerClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            self.q.async {
                guard self.connections[ObjectIdentifier(connection)] != nil else { return }
                if isComplete || error != nil {
                    if let at = self.readOffsets[ObjectIdentifier(connection)] {
                        PlayerProbe.event("cache", "reader CLOSED by player at \(at / 1_048_576)MB")
                    }
                    self.requestTrail("PEER CLOSED at \(self.readOffsets[ObjectIdentifier(connection)] ?? -1)")
                    self.drop(connection)
                } else {
                    // An HTTP client has nothing to say on a GET it already
                    // sent; whatever this was, keep watching for the close.
                    self.watchForPeerClose(connection)
                }
            }
        }
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil { self.drop(connection); return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 32 * 1024 { self.drop(connection) }
                else { self.readRequest(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            // From here on the only thing that can arrive on this socket is
            // the peer closing it — which is the one thing we must not miss.
            self.watchForPeerClose(connection)
            self.route(head, on: connection)
        }
    }

    // MARK: - Request handling (on q)

    private func route(_ head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2 else { drop(connection); return }
        let method = String(requestParts[0])
        let path = String(requestParts[1])
        guard method == "GET" || method == "HEAD" else {
            sendSimple(connection, "405 Method Not Allowed"); return
        }
        let cacheOnly = path.hasPrefix("/t/\(token)/")
        guard !token.isEmpty, path.hasPrefix("/m/\(token)/") || cacheOnly else {
            sendSimple(connection, "404 Not Found"); return
        }
        var requestedRange: (Int64, Int64?)?   // (start, inclusive end?)
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("range:"), let eq = line.range(of: "bytes=") else { continue }
            let spec = line[eq.upperBound...].split(separator: "-", maxSplits: 1,
                                                    omittingEmptySubsequences: false)
            guard let first = spec.first, let start = Int64(first.trimmingCharacters(in: .whitespaces))
            else { continue }
            let end = spec.count > 1 ? Int64(spec[1].trimmingCharacters(in: .whitespaces)) : nil
            requestedRange = (start, end)
        }
        // The first origin response tells us the length; wait briefly for it.
        awaitMetadata(deadline: Date().addingTimeInterval(Self.metadataTimeout)) { [weak self] ready in
            guard let self else { return }
            guard ready, !self.redirectAll, self.totalLength > 0 else {
                // An origin that hasn't answered the opening request by now is
                // not going to be a useful cache source. Bail the SESSION, not
                // just this request: redirecting one request left the session
                // alive, so every subsequent request paid the same wait again
                // and startup crawled instead of falling back.
                if !self.redirectAll, self.totalLength <= 0 {
                    self.failSession("origin sent no length within \(Int(Self.metadataTimeout))s",
                                     retryable: false)
                }
                // The cache-only lane never redirects to the origin — its whole
                // contract is "disk or nothing".
                if cacheOnly { self.sendSimple(connection, "503 Service Unavailable") }
                else { self.sendRedirect(connection) }
                return
            }
            self.beginResponse(connection, method: method, range: requestedRange, cacheOnly: cacheOnly)
        }
    }

    private func awaitMetadata(deadline: Date, _ completion: @escaping (Bool) -> Void) {
        if totalLength > 0 || redirectAll { completion(true); return }
        guard Date() < deadline else { completion(false); return }
        q.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.awaitMetadata(deadline: deadline, completion)
        }
    }

    private func beginResponse(_ connection: NWConnection, method: String, range: (Int64, Int64?)?, cacheOnly: Bool = false) {
        // `route` waits on the origin's first response before getting here, and
        // an engine that seeks again during that wait drops this socket. Coming
        // back to register a read offset for it would re-create exactly the
        // dead reader `drop` just cleaned up.
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        let total = totalLength
        let start = min(max(range?.0 ?? 0, 0), total)
        // Clamp the CLOSED end first, then add one. `(end) + 1` on a client-
        // supplied `Int64.max` end (a common "whole file" Range) overflowed
        // before `min` could clamp it and trapped the process. total >= 1 here
        // (the caller guards totalLength > 0), so total - 1 is safe.
        let endExclusive = range.map { r -> Int64 in
            min(r.1 ?? (total - 1), total - 1) + 1
        } ?? total
        guard start < endExclusive else { sendSimple(connection, "416 Range Not Satisfiable"); return }

        requestTrail("\(cacheOnly ? "/t" : "/m") \(method) start=\(start) end=\(endExclusive)"
            + " covEnd=\(coverageEnd(from: start)) head=\(downloadHead) ranges=\(ranges.count)")
        // Cache-only lane: what's on disk or a fast refusal — no jump, no
        // redirect, no waiting on the network.
        if cacheOnly {
            if coverageEnd(from: start) == start, start < total, method != "HEAD" {
                sendSimple(connection, "416 Range Not Satisfiable")
                return
            }
        }
        // Route an uncovered request. Small bounded reads are container
        // metadata (MKV cues, MP4 tables) and get their own connection; a big
        // or open-ended read is a PLAYBACK reader, which registers its
        // position below and is then fed by the demand side of the pool —
        // nothing repositions, nothing thrashes, and several concurrent probe
        // readers each just become demand.
        else if rangeCapable, coverageEnd(from: start) == start, start < total {
            if endExclusive - start <= Self.sideFetchMaxBytes {
                requestTrail("SIDE-FETCH \(start)..<\(endExclusive)")
                sideFetch(start: start, endExclusive: endExclusive)
            } else if windowed,
                      let windowStart = ranges.first(where: { $0.end > Self.headerProtectBytes })?.start,
                      start < windowStart {
                // Behind the sliding window — those bytes were EVICTED and the
                // window will not go back for them; this reader gets the
                // origin directly.
                sendRedirect(connection)
                return
            }
        }
        let mediaRead = !cacheOnly && endExclusive - start > Self.sideFetchMaxBytes

        let contentType: String
        switch origin?.pathExtension.lowercased() {
        case "mp4", "m4v": contentType = "video/mp4"
        case "mkv": contentType = "video/x-matroska"
        case "avi": contentType = "video/x-msvideo"
        case "ts": contentType = "video/mp2t"
        default: contentType = "application/octet-stream"
        }
        var head = range == nil
            ? "HTTP/1.1 200 OK\r\n"
            : "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(endExclusive - 1)/\(total)\r\n"
        head += """
        Content-Type: \(contentType)\r
        Content-Length: \(endExclusive - start)\r
        Accept-Ranges: bytes\r
        Connection: close\r
        \r

        """
        // Only PLAYBACK readers steer eviction, demand and the playhead
        // estimate. Metadata reads must not: one cue read at the tail of a
        // 22 GB file dragged the "playhead" to the end of the film, which
        // broke the request routing (mid-file reads waited on bytes nobody
        // was fetching) and pointed eviction at everything the real reader
        // still needed.
        if mediaRead {
            noteRead(connection, start)
            PlayerProbe.event("cache", "reader OPEN at \(start / 1_048_576)MB"
                + " covered=\(coverageEnd(from: start) > start) readers=\(readOffsets.count)")
            // A read that lands where the cache isn't IS the seek — move the
            // pool onto it now rather than waiting for it to starve.
            repositionForSeek(to: start)
            kickPool()   // and put any remaining idle capacity to work
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.q.async {
                if error != nil || method == "HEAD" { self.finish(connection); return }
                guard let fileURL = self.fileURL,
                      let reader = try? FileHandle(forReadingFrom: fileURL) else {
                    self.drop(connection); return
                }
                self.serve(connection, reader: reader, offset: start,
                           endExclusive: endExclusive, stalledSince: nil,
                           cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
        })
    }

    /// Pump bytes from the cache file to the player as they become available.
    /// Backpressure is the send-completion; availability gaps poll at 80ms —
    /// crude, but local, cheap, and immune to lost-wakeup bugs.
    private func serve(_ connection: NWConnection, reader: FileHandle,
                       offset: Int64, endExclusive: Int64, stalledSince: Date?,
                       cacheOnly: Bool = false, mediaRead: Bool = false) {
        guard connections[ObjectIdentifier(connection)] != nil else {
            try? reader.close(); return
        }
        if offset >= endExclusive {
            try? reader.close()
            finish(connection)
            return
        }
        let available = min(coverageEnd(from: offset), endExclusive)
        guard available > offset else {
            // Cache-only lane: the coverage edge is the end of the story —
            // close rather than wait for the network to catch up.
            if cacheOnly {
                try? reader.close()
                drop(connection)
                return
            }
            // Nothing on disk here yet. If the download has died this will
            // never change — cut the connection so the engine's own failover
            // takes over (its retry meets `redirectAll` and plays direct).
            let stalled = stalledSince.map { Date().timeIntervalSince($0) > Self.stallTimeout } ?? false
            // THE DOWNLOAD'S OWN CLOCK, not just this connection's.
            //
            // `stalledSince` is per-connection, and an engine waiting on bytes
            // does not sit still: it closes and reopens the reader as it
            // retries, and every reopen starts the timer again. So a provider
            // that simply stops sending is never caught — observed live as
            // `lastWrite=78s ago`, `pool=1/1`, a reader polling at 80ms, and a
            // picture that had been dead for over a minute with the stall
            // timeout at 25s and no failure recorded.
            //
            // Whether the DOWNLOAD has written anything cannot be reset by a
            // reconnect, which is exactly why it is the signal that has to
            // decide this.
            // Not while parked for space: that is the download deliberately
            // NOT writing, and `resumeIfRoom` below (with its own wedge
            // timeout) is what governs it. Counting that idle time here failed
            // the session the moment a reader hit an uncovered byte after 25s
            // of a full window — before eviction had a chance to make room.
            let downloadDead = !pausedForSpace
                && Date().timeIntervalSince(lastWriteAt) > Self.stallTimeout
            if redirectAll || stalled || downloadDead {
                requestTrail("STALL-DROP at \(offset) (covEnd=\(coverageEnd(from: offset)))", important: true)
                // FAIL OPEN, for real — but only when the DOWNLOAD is what
                // died. This used to only cut the connection, on a comment that
                // claimed "its retry meets `redirectAll` and plays direct" —
                // but nothing here ever SET `redirectAll`. The engine's retry
                // came straight back into a proxy that was still stalled,
                // waited the timeout again, and failed over again.
                //
                // Failing the session on ANY stalled reader was too broad the
                // other way: bytes landing steadily for the reader that is
                // playing say the cache is fine, and the one timing out is a
                // reader the engine walked away from (or one parked behind a
                // hole the pool has not reached). Killing the cache for the
                // whole title on its account threw away a working session.
                if stalled || downloadDead {
                    if downloadDead {
                        failSession("no bytes written anywhere for \(Int(Self.stallTimeout))s")
                    } else {
                        requestTrail("dropping a stalled reader at \(offset) — the download is still running",
                                     important: true)
                        PlayerProbe.event("cache", "dropped a STALLED reader at \(offset / 1_048_576)MB"
                            + " — the download is still running")
                    }
                }
                try? reader.close()
                drop(connection)
                return
            }
            if stalledSince == nil { requestTrail("waiting at \(offset) head=\(downloadHead)") }
            // A READER WAITING IS ALSO PROGRESS. `resumeIfRoom` used to be
            // called only from the send-completion path — i.e. only while
            // bytes were actually flowing — so a window that had filled to its
            // budget while a reader sat waiting for bytes just past the edge
            // could never slide: the download stayed parked waiting for
            // playback to advance, and playback waited for the download. The
            // cache stopped dead until the 60s stall timeout killed the
            // connection. Publish where this reader is and try to make room.
            if mediaRead {
                noteRead(connection, offset)
                lastReaderWaitAt = Date()
                lastReadOffset = readOffsets.values.min() ?? offset
                // Before trying to make room: a reader the engine abandoned
                // mid-seek is holding some of what there is to free.
                reapAbandonedReaders()
                publishSnapshot()
                resumeIfRoom()
            }
            // Equally: an all-idle pool leaves nobody fetching what this
            // reader is waiting for — and a fully BUSY one leaves nobody able
            // to be assigned to it, which is the worse case and the one this
            // used to skip. Kick unconditionally; the pool's own preemption
            // cooldown keeps it from thrashing at the 80ms poll rate.
            if !pausedForSpace { kickPool() }
            q.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.serve(connection, reader: reader, offset: offset,
                            endExclusive: endExclusive, stalledSince: stalledSince ?? Date(),
                            cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
            return
        }
        let count = Int(min(Int64(Self.chunk), available - offset))
        try? reader.seek(toOffset: UInt64(offset))
        guard let data = try? reader.read(upToCount: count), !data.isEmpty else {
            try? reader.close(); drop(connection); return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.q.async {
                if error != nil { try? reader.close(); self.drop(connection); return }
                let next = offset + Int64(data.count)
                if mediaRead {
                    self.reapStalledWorkers()
                    self.unblockFrontier()
                    self.reapAbandonedReaders()
                    self.noteRead(connection, next)
                    self.kickPoolIfIdle()
                    self.lastReadOffset = self.readOffsets.values.min() ?? next
                    self.resumeIfRoom()
                }
                self.serve(connection, reader: reader, offset: next,
                           endExclusive: endExclusive, stalledSince: nil,
                           cacheOnly: cacheOnly, mediaRead: mediaRead)
            }
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    private func sendSimple(_ connection: NWConnection, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    /// Fail-open path: hand the engine the origin and get out of the way.
    private func sendRedirect(_ connection: NWConnection) {
        guard let origin else { sendSimple(connection, "404 Not Found"); return }
        let head = "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(origin.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.drop(connection) }
        })
    }

    // MARK: - Range bookkeeping (on q)

    /// How far the on-disk data extends CONTIGUOUSLY from `offset`.
    private func coverageEnd(from offset: Int64) -> Int64 {
        for range in ranges where range.start <= offset && offset < range.end {
            return range.end
        }
        return offset
    }

    /// One cached run, and when it first appeared.
    ///
    /// The age is the whole point. Evicting by POSITION throws away the wrong
    /// film the moment the viewer is not watching linearly: seek forward an
    /// hour and everything behind the new playhead — including the opening the
    /// archive had just finished building — is "behind" and goes. What the
    /// viewer actually wants kept is what they have collected, and what they
    /// can most afford to lose is whatever has been sitting there longest.
    struct CachedRange {
        var start: Int64
        var end: Int64
        /// Lowest stamp of everything merged into this run: a run is as old as
        /// its oldest part, so joining a fresh chunk onto an old region does
        /// not make the region look new and win it another reprieve.
        var born: Int
    }

    private func addRange(start: Int64, end: Int64) {
        guard end > start else { return }
        cacheClock += 1
        let stamp = cacheClock
        // Fast path: a worker extending a run it already owns, which is what
        // essentially every write is. Extend in place — no sort, no rebuild,
        // no reallocation on the queue that is also feeding the player.
        if let i = ranges.firstIndex(where: { $0.start <= start && start <= $0.end }) {
            guard end > ranges[i].end else { return }
            let touchesNext = i + 1 < ranges.count && ranges[i + 1].start <= end
            if !touchesNext {
                ranges[i].end = end
                publishSnapshot()
                return
            }
        }
        ranges.append(CachedRange(start: start, end: end, born: stamp))
        ranges.sort { $0.start < $1.start }
        var merged: [CachedRange] = []
        for range in ranges {
            if var last = merged.last, range.start <= last.end {
                // TWO CACHES MEETING JOIN — they do not re-download, and the
                // joined run keeps the OLDER birthday.
                last.end = max(last.end, range.end)
                last.born = min(last.born, range.born)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        ranges = merged
        publishSnapshot()
    }


    // MARK: - Downloader callbacks (on q)

    /// What a worker should do with the response it just received.
    enum ResponseVerdict {
        case allow
        /// Throttled (429/503) or transiently broken: keep the segment, retry
        /// it after the delay. The provider's ceiling was discovered, not
        /// fatal — one 429 used to kill the entire cache session.
        case retryLater(TimeInterval)
        /// Origin ignored the Range header mid-file: restart from zero.
        case restartAtZero
        /// The session is over (failSession already ran) — stand down.
        case abandon
    }

    fileprivate func downloaderGotResponse(_ response: HTTPURLResponse, requestedOffset: Int64) -> ResponseVerdict {
        switch response.statusCode {
        case 206:
            // "bytes X-Y/TOTAL"
            if totalLength <= 0,
               let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last,
               let total = Int64(totalPart) {
                totalLength = total
                publishSnapshot()
                guard configureBudget() else { return .abandon }
                fillPool()
            }
            return .allow
        case 200:
            if requestedOffset > 0 {
                // Origin ignored the Range header — it can't seek. What's
                // cached so far still serves; jumps are off the table.
                rangeCapable = false
                return .restartAtZero
            }
            rangeCapable = false
            // Only ADOPT a length we don't have yet. The 206 branch above is
            // guarded by `totalLength <= 0`; this one was not, so a retry at
            // offset 0 that landed on a different edge — one answering 200
            // with a short error page — overwrote a known 55 GB length with
            // e.g. 512. Everything downstream then trusted it: the pool
            // re-fetched [0,512) and wrote the HTML body over the container
            // header, `beginResponse` clamped every real range to 512 and
            // answered 416, and the coverage bar went to nonsense.
            let declared = response.expectedContentLength
            if totalLength <= 0 {
                totalLength = declared
                guard totalLength > 0 else {
                    failSession("origin sent no content length")
                    return .abandon
                }
                publishSnapshot()
                guard configureBudget() else { return .abandon }
                fillPool()
                return .allow
            }
            // We already know the real length. A 200 that disagrees is not
            // this file — fail rather than reconfigure around it.
            if declared > 0, declared != totalLength {
                failSession("origin changed the content length mid-session")
                return .abandon
            }
            publishSnapshot()
            guard configureBudget() else { return .abandon }
            fillPool()
            return .allow
        case 429, 503:
            // REMEMBER THE CEILING, STEP DOWN ONE, AND STOP RE-DISCOVERING IT.
            //
            // Halving to 1 and climbing back was a sawtooth that spent most of
            // the session at the bottom of its own teeth. Measured over a
            // minute on the device: sixteen samples at `pool=1/1` against one
            // each at 3, 4, 5 and 8 — it found the provider's limit, crashed to
            // a single connection, and spent the next stretch climbing back to
            // find the same limit again. Throughput averaged 12.9 MB/s while
            // the link was plainly capable of more.
            //
            // The level that just refused IS information. Keep it, sit one
            // below it, and probe above it only rarely — which is how a
            // congestion window is supposed to behave.
            // A REFUSAL AT ONE CONNECTION IS NOT A CONCURRENCY CEILING.
            //
            // There is no level below one to fall back to, so recording it as
            // the ceiling made the ramp compute its maximum as `ceiling - 1`
            // = ZERO and `parallelLimit < 0` is never true: the pool was pinned
            // at a single connection for the rest of the session, whatever the
            // provider would actually have allowed. The probe caught it exactly
            // — `limit=1 workers=8 interval=5s ceiling=1`, eight connections
            // sitting idle while one did all the work at half the achievable
            // speed. A 429 at one connection is a RATE limit or a transient;
            // back off in time, never pin the level.
            let previousLimit = parallelLimit
            let previousCeiling = throttleCeiling
            if parallelLimit > 1 {
                throttleCeiling = min(throttleCeiling ?? Int.max, parallelLimit)
            }
            // `?? 1` here was the same mistake a second time: with no ceiling
            // recorded it read as `1 - 1 = 0` and crashed the limit to one on a
            // single 429, which is the very halving-to-the-floor this change
            // exists to stop.
            parallelLimit = max(1, min(parallelLimit - 1, (throttleCeiling ?? Int.max) - 1))
            throttledUntil = Date().addingTimeInterval(8)
            rampInterval = min(rampInterval * 2, Self.rampIntervalMax)
            lastRampAt = Date()
            // LOG THE TRANSITION, NOT EVERY 429. A provider that is simply
            // rate-limiting keeps returning 429 every retry; logging each one
            // flushed the colour trail (40 entries, shared with every
            // display-mode decision) and evicted exactly the HDR/DV lines a
            // "why is this dark" investigation needs. Only speak when the
            // ceiling or the settled level actually changes.
            if parallelLimit != previousLimit || throttleCeiling != previousCeiling {
                requestTrail("origin throttled (\(response.statusCode)) — ceiling is"
                    + " \(throttleCeiling ?? 0), settling at \(parallelLimit)", important: true)
                PlayerProbe.event("cache", "origin throttled (\(response.statusCode)) —"
                    + " ceiling \(throttleCeiling ?? 0), now \(parallelLimit) connection(s)")
            } else {
                PlayerProbe.count("cache.throttled")
            }
            publishSnapshot()
            return .retryLater(4)
        default:
            let status = response.statusCode
            // SAY WHICH RANGE. A 416 on a link that otherwise plays means the
            // range we asked for was outside the file, and without the numbers
            // there is no way to tell whose arithmetic was wrong — the pool's,
            // a side fetch's, or a `totalLength` the origin has since changed
            // its mind about.
            failSession("origin answered \(status) for a range starting at"
                + " \(requestedOffset) of \(totalLength)")
            // ONLY WHEN IT IS REALLY THE ADDON, AND ONLY AS A LAST WORD.
            //
            // Firing on any status after one failure was far too eager and
            // would have blacklisted a GOOD source: this session answered 416
            // — Range Not Satisfiable — which says the range WE asked for was
            // wrong, not that the origin refuses ranges, and a persistent
            // exclusion on the strength of it would have cost the viewer one of
            // their best addons for good. A server that genuinely cannot do
            // ranges answers 200 with the whole body; 416 and 500 are things
            // that happen to links that work.
            //
            // So: never on 416, and only once the three retries this class
            // already makes have all been spent.
            if status != 416, recoveryAttempts >= Self.maxRecoveryAttempts {
                let note = "answered \(status) to every range request, across"
                    + " \(Self.maxRecoveryAttempts) retries"
                DispatchQueue.main.async { [weak self] in self?.onOriginRefusedRanges?(note) }
            }
            return .abandon
        }
    }

    fileprivate func downloaderWrote(_ data: Data, at offset: Int64, isSideFetch: Bool = false) {
        guard let writeHandle else { return }
        // The session this chunk belongs to is about to be torn down — a
        // main-thread `beginSession` is parked behind this very queue. Drop
        // the write (the file is deleted moments from now anyway) so the swap
        // gets the queue in milliseconds instead of after the backlog.
        guard !sessionSwapPending else { return }
        do {
            try writeHandle.seek(toOffset: UInt64(offset))
            try writeHandle.write(contentsOf: data)
            lastWriteAt = Date()
            writtenTotal += Int64(data.count)
            // Sliding download-rate window (~2s) for the player's status
            // panel. On q, like every other write-path field.
            rateWindowBytes += Int64(data.count)
            let elapsed = Date().timeIntervalSince(rateWindowStart)
            if elapsed >= 2 {
                measuredRate = Double(rateWindowBytes) / elapsed
                rateWindowStart = Date()
                rateWindowBytes = 0
            }
            addRange(start: offset, end: offset + Int64(data.count))
        } catch {
            failSession("disk write failed: \(error.localizedDescription)", retryable: false)
            return
        }
        // Sliding window: approach the budget, slide or pause. The headroom
        // absorbs the chunks URLSession has already queued for delivery.
        if windowed, usedBytes() + Self.writeHeadroomBytes > budget {
            let over = usedBytes() + Self.writeHeadroomBytes - budget
            evictOldest(target: max(over + Self.resumeHeadroomBytes, Self.resumeHeadroomBytes))
            if usedBytes() + Self.writeHeadroomBytes > budget { pauseForSpaceIfNeeded() }
        }
        // STORAGE FLOOR. The budget above is what the cache MAY hold; this is
        // what the DEVICE must keep. Checked on the write path, on a slow timer,
        // because a session can run for hours while everything else on the box
        // also consumes storage. When it trips the cache is stood down (and, in
        // full-file mode, the file is handed back) rather than filling the disk.
        if !enforceStorageFloor() { return }
        // Time-paced ramp probe: while data is flowing and the throttle
        // window has passed, try one more connection every few seconds. If
        // the provider objects, the 429 halves it right back — the ceiling
        // is rediscovered continuously, not assumed from one bad moment.
        // A STARVING READER OVERRIDES THE BACK-OFF. `rampInterval` doubles to
        // four minutes after a 429, which is the right patience when the cache
        // is comfortably ahead and completely wrong when it is not: one
        // connection that cannot keep up means the film stops, and waiting four
        // minutes to try a second guarantees it. Probe at the minimum interval
        // whenever the road ahead has run out.
        let leadBytes = downloadHead - liveReadAnchor()
        let bytesPerSecond = durationSeconds > 0 && totalLength > 0
            ? Double(totalLength) / durationSeconds : 0
        let leadSeconds = bytesPerSecond > 0 ? Double(leadBytes) / bytesPerSecond : .infinity
        let starving = leadSeconds < Self.rampUrgentLeadSeconds
        let interval = starving ? Self.rampIntervalMin : rampInterval
        if !isSideFetch, Date() > throttledUntil,
           Date().timeIntervalSince(lastRampAt) > interval {
            // A probe that has survived this long was a good one — walk the
            // interval back down so a provider that frees up is found again
            // rather than being probed once every four minutes for ever.
            if rampInterval > Self.rampIntervalMin {
                rampInterval = max(Self.rampIntervalMin, rampInterval / 2)
            }
            // Never climb back into a level this origin has already refused,
            // except on the occasional deliberate re-test.
            var ceiling = Self.workerCount
            if let known = throttleCeiling {
                let retest = Date().timeIntervalSince(lastCeilingProbeAt) > Self.ceilingRetestInterval
                if retest {
                    lastCeilingProbeAt = Date()
                    throttleCeiling = nil
                } else {
                    ceiling = max(1, known - 1)
                }
            }
            if parallelLimit < ceiling {
                lastRampAt = Date()
                parallelLimit += 1
                // DEFERRED. This runs inside a worker's own write callback, and
                // `kickPool` ends in `preemptForStarvedReader`, which may cancel
                // and restart the very worker whose stack we are on. `fillPool`
                // is the hop that exists for callers in this position.
                fillPool()
            }
        }
    }

    /// A throttled worker asks to resume through the SERVER, not by itself:
    /// a self-timed restart bypassed `parallelLimit`, so five workers that
    /// were 429'd together all came back together — re-tripping the very
    /// ceiling the back-off had just discovered. The abandoned segment isn't
    /// lost either way: with no task it is unclaimed, and the next
    /// `pickChunk` hands it out again.
    fileprivate func downloaderThrottled(_ worker: SegmentDownloader,
                                         resumeAt offset: Int64, end: Int64?,
                                         after delay: TimeInterval) {
        q.asyncAfter(deadline: .now() + delay) { [weak self, weak worker] in
            guard let self, !self.redirectAll, !self.pausedForSpace else { return }
            guard let worker, worker.isIdle else { return }
            if self.workers.count(where: { !$0.isIdle }) < self.parallelLimit {
                worker.start(at: offset, endExclusive: end)
            } else {
                self.kickPool()
            }
        }
    }

    fileprivate func downloaderFinishedSegment(_ worker: SegmentDownloader) {
        // Growth is time-paced in `downloaderWrote`; here just put the freed
        // worker (and any other idle capacity) back to work.
        kickPool()
    }

    fileprivate func downloaderFailed(_ worker: SegmentDownloader) {
        // One worker dying is not the session dying — the others carry on and
        // the pool is topped back up. Only losing ALL of them is terminal.
        retire(worker)
        if workers.isEmpty { failSession("every download connection failed") }
        // TOP IT BACK UP, which the comment above always claimed happened and
        // nothing did: `workers.append` lives only in `ensurePool`, reachable
        // from `beginSession` and the recovery retry. So every worker that
        // exhausted its retries cost a connection for the rest of the film,
        // while the ramp kept raising `parallelLimit` against a pool that could
        // no longer supply it — a long session ending at one live connection.
        //
        // Replacements are RATE-LIMITED rather than unconditional: an origin
        // that kills every connection would otherwise be handed an endless
        // supply of fresh ones, `workers` would never be observed empty, and
        // the terminal failure above could never fire.
        else if Date().timeIntervalSince(lastPoolRefillAt) > 10 {
            lastPoolRefillAt = Date()
            ensurePool()
        }
    }

    /// Rate limit for replacing dead workers — see `downloaderFailed`.
    private var lastPoolRefillAt = Date.distantPast

    fileprivate func retire(_ worker: SegmentDownloader) {
        worker.cancel()
        workers.removeAll { $0 === worker }
    }

    // MARK: - Download pool (on q)

    /// Make sure the pool exists, then put idle capacity to work.
    private func ensurePool() {
        guard !redirectAll, writeHandle != nil, let origin else { return }
        let target = rangeCapable ? Self.workerCount : 1
        while workers.count < target {
            workers.append(SegmentDownloader(server: self, origin: origin,
                                              headers: sessionHeaders, queue: q))
        }
        kickPool()
    }

    /// Deferred `kickPool` — for callers running inside a worker's own
    /// delegate callback, where starting siblings would re-enter.
    private func fillPool() {
        q.async { [weak self] in self?.kickPool() }
    }

    /// Assign work to idle workers, demand first, until the adaptive
    /// parallelism limit or the work runs out.
    private func kickPool() {
        guard !redirectAll, !pausedForSpace, writeHandle != nil else { return }
        for worker in workers where worker.isIdle {
            guard workers.count(where: { !$0.isIdle }) < parallelLimit else { break }
            guard assignChunk(to: worker) else { break }
        }
        preemptForStarvedReader()
    }

    /// Cooldown so two readers can't trade the same worker back and forth.
    private var lastPreemptAt = Date.distantPast

    /// Rate limit for the playhead's own wake-up of an idle pool.
    private var lastIdleKickAt = Date.distantPast

    /// When a media reader was last WAITING on bytes the cache does not have.
    /// The difference between a cache that is merely full and one that is
    /// standing in the way of the picture.
    private var lastReaderWaitAt = Date.distantPast

    /// Wake an idle pool as the playhead advances.
    ///
    /// `kickPool` is otherwise only re-entered when a segment FINISHES or a
    /// reader STARVES. Both are fine while there is work to hand out, and
    /// neither happens once `pickChunk` has started returning nil — which is
    /// exactly what a bounded `fillCeiling` makes routine: the pool reaches the
    /// lead limit, every worker goes idle, and nothing is left to notice that
    /// the ceiling rose when the viewer watched another minute. The download
    /// would sleep through the whole buffer and then stall at the frontier.
    ///
    /// Bytes going out to the player IS the playhead advancing, so this is the
    /// right signal; it just fires ~25 times a second, hence the cooldown.
    private func kickPoolIfIdle() {
        guard !redirectAll, !pausedForSpace else { return }
        guard workers.contains(where: { $0.isIdle }) else { return }
        guard Date().timeIntervalSince(lastIdleKickAt) > 0.5 else { return }
        lastIdleKickAt = Date()
        kickPool()
    }

    /// When a worker last wrote bytes — the download's own heartbeat, which is
    /// what separates "the origin is gone" from "this one reader is waiting".
    private var lastWriteAt = Date()

    /// Last live storage sample and when it was taken (q-confined). The budget
    /// is fixed, but the free space around it is not — see `enforceStorageFloor`.
    private var freeSpaceCheckedAt = Date.distantPast
    private var lastKnownFreeBytes: Int64 = -1

    /// Every byte this session has written, for comparing the pool's aggregate
    /// throughput against the one number that matters to the player.
    private var writtenTotal: Int64 = 0
    /// Sliding-window download rate (see downloaderWrote). q-confined; the
    /// snapshot mirrors it for the status panel.
    private var rateWindowStart = Date()
    private var rateWindowBytes: Int64 = 0
    private var measuredRate: Double = 0

    // MARK: - Frontier guard

    /// The contiguous edge in front of the viewer at the last measurement, and
    /// when that measurement was taken.
    private var frontierEdgeMark: Int64 = -1
    private var frontierWrittenMark: Int64 = 0
    private var frontierMarkedAt = Date()
    /// How long to watch before judging the frontier chunk a bottleneck.
    private static let frontierWindow: TimeInterval = 6
    /// The pool may outrun the frontier by this factor before it counts as one
    /// slow chunk holding everything up rather than ordinary tiling.
    ///
    /// SIXTEEN, not four. Four is ordinary behaviour, not a fault: eight
    /// workers tiling forward are all ahead of the contiguous edge by
    /// definition, so the pool always outruns the frontier several times over
    /// while the burst is building. At four this fired THIRTY-SEVEN SECONDS
    /// into a healthy session — "frontier stuck at 16MB — it gained 15MB while
    /// the pool wrote 64MB" — and cancelled the frontier worker for doing its
    /// job, over and over. The real event it was built for was 10 MB of edge
    /// against 544 MB of pool sustained over sixteen seconds: a ratio of
    /// FIFTY-FOUR to one. There is a lot of room between the two and the
    /// threshold belongs nearer the fault than the norm.
    private static let frontierLagFactor: Int64 = 16
    /// Edge progress above this in a window is healthy whatever the pool did.
    private static let frontierHealthyGain: Int64 = 8 * 1_048_576
    /// Below this much pool throughput the sample is too small to judge.
    private static let frontierMinPoolGain: Int64 = 96 * 1_048_576

    /// Re-fetch the chunk at the contiguous edge when one slow connection is
    /// holding the whole cache back.
    ///
    /// A PLAYER CAN ONLY ADVANCE THROUGH BYTES CONTIGUOUS WITH WHAT IT IS
    /// READING. Everything the pool fetches past a hole is real, cached, and
    /// completely useless until the hole closes — so a single slow chunk at the
    /// frontier stops the usable cache dead while seven other workers keep the
    /// link saturated and `onDisk` climbing. Measured on the device: over
    /// sixteen seconds the edge moved TEN MEGABYTES while the pool wrote FIVE
    /// HUNDRED AND FORTY-FOUR, and the viewer's road ahead FELL from 178s to
    /// 164s the whole time. Then the chunk landed and the edge jumped 723 MB at
    /// once. With a full buffer that is invisible; straight after a seek, when
    /// the lead is zero, the hole is directly in the player's path — which is
    /// why "it keeps having to load" happens on a ten-second skip and a
    /// hundred-second one alike.
    ///
    /// Deliberately RELATIVE, not a stall timer. The blocker is rarely stalled
    /// — `reapStalledWorkers` already covers dead ones — it is merely slow, and
    /// slow is only a problem measured against what the rest of the pool is
    /// achieving on the same link at the same moment.
    private func unblockFrontier() {
        guard !redirectAll, !pausedForSpace, writeHandle != nil, totalLength > 0 else { return }
        let edge = coverageEnd(from: liveReadAnchor())
        guard frontierEdgeMark >= 0 else {
            frontierEdgeMark = edge
            frontierWrittenMark = writtenTotal
            frontierMarkedAt = Date()
            return
        }
        guard Date().timeIntervalSince(frontierMarkedAt) >= Self.frontierWindow else { return }
        let edgeGain = max(edge - frontierEdgeMark, 0)
        let poolGain = max(writtenTotal - frontierWrittenMark, 0)
        frontierEdgeMark = edge
        frontierWrittenMark = writtenTotal
        frontierMarkedAt = Date()
        // The pool must be working, and working much harder than the frontier.
        // Never during the opening burst: every worker is deliberately queued
        // at the frontier then, so the edge trailing the pool is the design.
        guard !bursting,
              edgeGain < Self.frontierHealthyGain,
              poolGain > Self.frontierMinPoolGain,
              edgeGain * Self.frontierLagFactor < poolGain else { return }
        guard let blocker = workers.first(where: {
            guard let segment = $0.pendingSegment else { return false }
            return segment.start <= edge && edge < segment.end
        }) else { return }
        PlayerProbe.event("cache", "frontier stuck at \(edge / 1_048_576)MB —"
            + " it gained \(edgeGain / 1_048_576)MB while the pool wrote"
            + " \(poolGain / 1_048_576)MB; re-fetching that chunk")
        requestTrail("UNBLOCK FRONTIER at \(edge) (edge +\(edgeGain), pool +\(poolGain))",
                     important: true)
        blocker.cancelSegment()
        kickPool()
    }

    /// Follow the viewer, Infuse-style: a media read that lands on bytes the
    /// cache does not have and nobody is fetching moves the pool THERE, at
    /// once, whatever it was doing.
    ///
    /// The distinction from `preemptForStarvedReader` is intent. That one is a
    /// rescue — it waits for a reader to be provably stuck, on a cooldown,
    /// because it fires off the serve loop's 80ms poll. This fires on the
    /// range request itself, which is the seek, and there is nothing to wait
    /// for: sequential completeness has already lost the argument the moment
    /// the viewer jumped. The short coalescing window is only so an engine's
    /// burst of probe reads around a seek point counts as one move.
    private func repositionForSeek(to offset: Int64) {
        guard rangeCapable, totalLength > 0, !redirectAll, !pausedForSpace else { return }
        // THIS is a place the viewer went — a jump, not the next stretch of the
        // film. Hanging this off `noteRead` instead recorded an anchor every
        // 256 MB of ordinary watching, so the list filled with the last sixteen
        // steps of continuous playback and held nothing the viewer had actually
        // jumped to: exactly the film the archive did NOT need to be told about.
        noteVisited(offset)
        guard offset < totalLength, coverageEnd(from: offset) == offset else { return }
        // Somebody is already pulling toward this point.
        let covered = workers.contains { worker in
            guard let pending = worker.pendingSegment else { return false }
            return pending.start <= offset && offset < pending.end
                && pending.start >= offset - effectiveJumpSlop
        }
        if covered { return }
        guard Date().timeIntervalSince(lastPreemptAt) > 0.25 else { return }
        let segment = min(offset + Self.chunkBytes, totalLength)
        // Spare capacity first — no reason to take work away if there is any.
        if workers.count(where: { !$0.isIdle }) < parallelLimit,
           let idle = workers.first(where: \.isIdle) {
            lastPreemptAt = Date()
            requestTrail("SEEK-JUMP -> \(offset) (spare worker)", important: true)
            PlayerProbe.event("cache", "SEEK-JUMP -> \(offset / 1_048_576)MB (spare worker)")
            idle.start(at: offset, endExclusive: segment)
            return
        }
        guard let victim = workers
            .filter({ !$0.isIdle && $0.pendingSegment != nil })
            .max(by: { abs($0.pendingSegment!.start - offset) < abs($1.pendingSegment!.start - offset) })
        else { return }
        lastPreemptAt = Date()
        requestTrail("SEEK-JUMP \(victim.pendingSegment!.start) -> \(offset)", important: true)
        PlayerProbe.event("cache", "SEEK-JUMP \(victim.pendingSegment!.start / 1_048_576)MB"
            + " -> \(offset / 1_048_576)MB (took a worker)")
        victim.cancelSegment()
        victim.start(at: offset, endExclusive: segment)
        abandonWorkFarFrom(offset)
    }

    /// After a jump, take the whole pool off film the viewer has just left.
    ///
    /// `repositionForSeek` moved exactly ONE worker to the new position and
    /// left the other seven finishing 16 MB segments around the OLD one —
    /// bytes nobody is going to read now. So the new position was fed by a
    /// single connection until those segments happened to complete, and the
    /// measured result is a jump that plays for a moment and then stalls again:
    /// 1.5s of buffering, half a second of picture, then 4.0s more, twice in
    /// the same minute. One connection cannot build a cushion faster than 4K
    /// playback drains it; eight can.
    ///
    /// Only work that is useless at the new position is dropped — anything
    /// inside the rewind margin or the lead the viewer is about to watch is
    /// left alone, so this cannot thrash a pool that is already in the right
    /// place. Buffered-but-unwritten bytes are lost with the segment, which is
    /// a few megabytes against seconds of dead picture.
    private func abandonWorkFarFrom(_ offset: Int64) {
        let low = offset - keepBehindBytes
        let high = offset + leadAllowance
        var dropped = 0
        for worker in workers {
            guard let segment = worker.pendingSegment else { continue }
            guard segment.start < low || segment.start >= high else { continue }
            worker.cancelSegment()
            dropped += 1
        }
        guard dropped > 0 else { return }
        PlayerProbe.event("cache", "re-aimed \(dropped) worker(s) from film the viewer left"
            + " to \(offset / 1_048_576)MB")
        requestTrail("re-aimed \(dropped) worker(s) to \(offset)", important: true)
        kickPool()
    }

    /// Point a busy worker at a reader that has NOTHING to read.
    ///
    /// `kickPool` only ever feeds IDLE workers, so demand-first scheduling can
    /// only answer new demand while the pool has spare capacity. It usually
    /// doesn't: `parallelLimit` starts at 2 and a single 429 from a debrid
    /// provider halves it to 1. A deep seek then lands on bytes nobody is
    /// fetching and nobody CAN be assigned to fetch — the reader waits out the
    /// stall timeout while the pool streams sequential bytes it will not reach
    /// for minutes. Nothing repositions the pool any more (the old `jump` went
    /// with the demand-driven rework), so this is the only thing that can.
    private func preemptForStarvedReader() {
        guard rangeCapable, totalLength > 0, !redirectAll, !pausedForSpace else { return }
        // Starving = not one byte on disk at this reader's own offset.
        guard let starved = readOffsets.values
            .filter({ $0 < totalLength && coverageEnd(from: $0) == $0 })
            .min() else { return }
        // The bytes may simply be sitting in a worker's write buffer. Push
        // them out now rather than making a waiting reader ride out the
        // coalescing window — batching is for throughput, not for latency in
        // front of somebody who is actually blocked.
        for worker in workers {
            guard worker.bufferedBytes > 0, let pending = worker.pendingSegment,
                  starved >= pending.start,
                  starved < pending.start + Int64(worker.bufferedBytes) else { continue }
            worker.flushNow()
            return
        }
        // Bytes already on the way — the reader is waiting, not stranded.
        let arrivingSoon = workers.contains { worker in
            guard let pending = worker.pendingSegment else { return false }
            return pending.start <= starved && starved < pending.end
                && pending.start >= starved - effectiveJumpSlop
        }
        if arrivingSoon || sideFetchSpans.contains(where: { $0.key <= starved && starved < $0.value }) {
            return
        }
        // Repositioning is the last resort, and rate-limited: two readers
        // must not be able to trade the same worker back and forth. The
        // buffer flush above is NOT gated on it — that is pure latency relief.
        guard Date().timeIntervalSince(lastPreemptAt) > 2 else { return }
        // Take the segment from whoever is working furthest from the need.
        guard let victim = workers
            .filter({ !$0.isIdle && $0.pendingSegment != nil })
            .max(by: { abs($0.pendingSegment!.start - starved) < abs($1.pendingSegment!.start - starved) })
        else { return }
        lastPreemptAt = Date()
        requestTrail("PREEMPT \(victim.pendingSegment!.start) -> starved reader at \(starved)",
                     important: true)
        PlayerProbe.event("cache", "PREEMPT \(victim.pendingSegment!.start / 1_048_576)MB"
            + " -> starved reader at \(starved / 1_048_576)MB")
        victim.cancelSegment()
        victim.start(at: starved, endExclusive: min(starved + Self.chunkBytes, totalLength))
    }

    /// Hand `worker` the most useful unclaimed chunk. False = nothing to do.
    @discardableResult
    private func assignChunk(to worker: SegmentDownloader) -> Bool {
        guard !redirectAll, !pausedForSpace, writeHandle != nil else { return false }
        // BOOTSTRAP. The file's length is only learned from the first
        // response's Content-Range, so the opening request goes out WITHOUT
        // it — requiring the length first meant every worker parked waiting
        // for a fact only a worker could learn, and nothing ever downloaded.
        guard totalLength > 0 else {
            guard workers.first === worker else { return false }
            worker.start(at: fetchCursor, endExclusive: fetchCursor + Self.chunkBytes)
            return true
        }
        guard rangeCapable else {
            // No ranges: one open-ended stream from zero is all the origin
            // allows — and only while something is actually missing, or a
            // finished stream's completion would start the whole download
            // over from the top, forever.
            // ONE STREAM, and this is the guard that holds it to one. An
            // unbounded segment can only ever claim a rolling 64 MB from its
            // write cursor, so `nextUnclaimedGap` keeps reporting the rest of
            // the file as free and every idle worker the ramp released was
            // handed this same `start(at: 0)`: two connections, then eight,
            // all pulling the whole file from the top and writing identical
            // bytes at identical offsets. The contiguous frontier the player
            // reads from then grew at a fraction of the link speed while N
            // copies of the file came down — the opening burst never got
            // ahead, readers timed out at the frontier and the engine
            // reconnected in a loop, and the origin saw a connection count it
            // is entitled to 429 or ban for.
            guard workers.allSatisfy(\.isIdle) else { return false }
            guard nextUnclaimedGap(from: 0) != nil else { return false }
            worker.start(at: 0, endExclusive: nil)
            return true
        }
        guard let gap = pickChunk() else {
            if workers.allSatisfy(\.isIdle) {
                NSLog("[OrivioCache] %@ (%lld bytes)",
                      windowed ? "window reaches the end of the file" : "file fully cached",
                      totalLength)
            }
            return false
        }
        worker.start(at: gap.start, endExclusive: gap.end)
        return true
    }

    /// How much road the opening burst is trying to build in front of the
    /// viewer, in bytes at the file's average rate.
    private var burstTargetBytes: Int64 {
        guard totalLength > 0, durationSeconds > 0 else { return Self.burstFallbackBytes }
        return Int64(Double(totalLength) / durationSeconds * Self.burstSeconds)
    }

    /// Still building the opening cushion.
    private var bursting: Bool {
        let reader = minActiveRead()
        return coverageEnd(from: reader) - reader < burstTargetBytes
    }

    /// The most useful chunk to fetch next. DEMAND FIRST: the active reader
    /// with the least contiguous road ahead of it gets fed before any
    /// background filling — that is what lets a freshly opened engine (which
    /// probes at several offsets at once) come up without anyone repositioning
    /// anything. Then the background cursor, then hole-filling.
    private func pickChunk() -> (start: Int64, end: Int64)? {
        // During the opening burst the lookahead IS the burst target, so every
        // worker queues up at the frontier instead of one feeding the reader
        // while the rest wander off to background fill.
        let lookahead = bursting
            ? max(burstTargetBytes, Self.readerLookaheadBytes)
            : Self.readerLookaheadBytes
        var best: (lead: Int64, gap: (start: Int64, end: Int64))?
        for readerOffset in readOffsets.values {
            let edge = coverageEnd(from: readerOffset)
            let lead = edge - readerOffset
            guard lead < lookahead,
                  let gap = nextUnclaimedGap(from: edge),
                  gap.start < readerOffset + lookahead
            else { continue }
            if best == nil || lead < best!.lead { best = (lead, gap) }
        }
        if let best { return bounded(best.gap) }
        // Past the lookahead ceiling the background fill stands down — the
        // demand loop above is unaffected, so a reader that seeks out there is
        // still fed at once.
        let ceiling = fillCeiling
        // Then: the first hole AT OR AFTER the slowest reader's contiguous
        // edge. Emphatically NOT a monotonic high-water cursor, which is how
        // the frontier froze: anything leaving a gap behind that cursor (a
        // preemption, an out-of-order completion, a failed side fetch) was
        // never revisited until the forward pass reached the end of the file.
        // The disk kept filling — `onDisk` climbing, `ranges` growing — while
        // `lead` sat on exactly the same number, because a player can only
        // advance through bytes that have MERGED with what it is already
        // reading. Anchoring here closes the nearest hole first, so the
        // contiguous frontier always moves.
        // FROM THE READER THAT IS PLAYING. Anchored on `minActiveRead()` this
        // aimed at the lowest reader, which after a forward seek is the
        // connection the engine has already left — so the pool spent itself
        // extending a run nobody would ever read while the viewer's own
        // frontier stood still.
        if let gap = nextUnclaimedGap(from: coverageEnd(from: liveReadAnchor())),
           gap.start < ceiling {
            return bounded(gap)
        }
        // Nothing in front — holes behind, then, but never behind the window,
        // and never while the burst is still trying to get in front.
        //
        // THE CEILING APPLIES HERE TOO. This asks from the reader's own offset,
        // so when everything in front of the reader is already contiguous the
        // "hole behind" it finds IS the frontier — the same chunk the bounded
        // step above just declined, handed back without a bound. Measured on
        // the device: budget 2388 MB, reader at 121 MB, ceiling ~1315 MB, and
        // the head had run to 2190 MB regardless. The window then fills and
        // parks exactly as it did before the ceiling existed.
        if !bursting, let gap = nextUnclaimedGap(from: windowed ? minActiveRead() : 0),
           gap.start < ceiling {
            return bounded(gap)
        }
        // LAST: build the film up from the BEGINNING with whatever budget the
        // playhead does not need.
        //
        // Everything above serves where the viewer IS. Bounding the lead left
        // most of the window unused — on the measured session, 4 GB of lead and
        // 1.6 GB of rewind margin out of a 10.6 GB budget — and film that is
        // merely somewhere else is worth more on disk than nothing is. Filling
        // forward from zero means jumping around the title lands in cache
        // instead of on the network.
        //
        // Strictly last, so it can never take a connection from the viewer, and
        // stopped well short of the budget by `archiveCeiling` so that it and
        // eviction cannot chase each other: archiving halts with a whole
        // playhead-window of headroom still free, long before the pressure that
        // makes eviction run.
        // THE VIEWER FIRST, ALWAYS. Stand down entirely until there is real
        // road ahead, and never hold more than a couple of connections even
        // then, so a seek always finds most of the pool free to follow it.
        if !bursting, windowed, usedBytes() < archiveCeiling,
           downloadHead - liveReadAnchor() > Self.archiveMinLeadBytes,
           workersOnArchive < archiveWorkerLimit {
            // FIRST, the places the viewer has actually been — a bounded
            // neighbourhood around each, oldest first, so a session that jumped
            // to four scenes ends up with all four on disk rather than one of
            // them and a very long tail.
            for anchor in visitedAnchors {
                if let gap = nextUnclaimedGap(from: anchor),
                   gap.start < min(anchor + Self.visitedSpanBytes, ceilingForArchive) {
                    return bounded(gap)
                }
            }
            // Then forward from where they came in…
            if let gap = nextUnclaimedGap(from: archiveOrigin),
               gap.start < ceilingForArchive {
                return bounded(gap)
            }
            // …and last of all, the part before it that they skipped past.
            if archiveOrigin > 0, let gap = nextUnclaimedGap(from: 0),
               gap.start < archiveOrigin {
                return bounded(gap)
            }
        }
        return nil
    }

    /// How much of the window the from-the-start fill may occupy.
    ///
    /// Whatever is left after the playhead's own needs are reserved: the lead
    /// it is allowed to build, the rewind margin behind it, and the headroom
    /// eviction wants to resume on. Reserving those is what keeps this from
    /// oscillating against eviction — archiving stops with room to spare, so
    /// the window never has to reclaim archive it is still in the middle of
    /// fetching.
    private var archiveCeiling: Int64 {
        // Reserve only what the playhead still has to GROW into — the lead it
        // is allowed to build, plus resume headroom. The rewind margin is not
        // reserved on top: it sits behind the playhead, which is the same place
        // the archive lives, so counting it twice left the archive a ceiling it
        // had already passed by the time the lead was built, and it never ran.
        max(budget - leadAllowance - Self.resumeHeadroomBytes, 0)
    }

    /// The archive fill covers the whole file; it is the BUDGET that bounds it,
    /// not a byte offset.
    private var ceilingForArchive: Int64 { totalLength > 0 ? totalLength : .max }

    /// The most road the background fill will build in front of the viewer.
    /// Ten minutes is a cushion no connection hiccup outlasts; past that the
    /// bytes are worth less than the room they occupy.
    private static let maxLeadSeconds: Double = 600
    /// Floor for the same, so a low-bitrate file still gets a real cushion in
    /// bytes (ten minutes of a 2 Mbps web-dl is 150 MB, and the pool needs more
    /// than that in hand to ride out a slow patch).
    private static let minLeadBytes: Int64 = 512 * 1_048_576

    /// The furthest byte the background fill may reach for.
    ///
    /// Unwindowed — the file fits — this is the whole file: cache all of it,
    /// there is nothing to trade off.
    ///
    /// WINDOWED, it is a bounded lead in front of the reader that is playing,
    /// and getting this wrong is what made the cache bar stop.
    ///
    /// With no cap at all the pool simply races: measured on the device, a
    /// 55.7 GB remux with an 11 GB window ran the head 10.6 GB — TWENTY-SEVEN
    /// MINUTES — in front of the playhead and spent the entire budget doing it.
    /// That lead is one contiguous run in front of the live reader, so
    /// `evictAhead` (rightly) will not touch it and `evictBehind` has nothing
    /// left behind to give; the window jams, `pausedForSpace` sticks, and the
    /// download does not move again except at playback speed. Cache bar frozen
    /// for the rest of the film, and every later seek landing in a budget with
    /// no room in it.
    ///
    /// The earlier attempt at a cap — half the window, flat — was rejected for
    /// leaving half the budget permanently unused. A TIME-based lead is the
    /// difference: it tracks the playhead, so the cached span advances
    /// continuously as the film plays instead of stopping dead, and what it
    /// leaves free is not waste but the room every seek needs to land in.
    /// `budget / 2` survives only as an upper bound on the bound.
    ///
    /// The demand loop in `pickChunk` is deliberately NOT subject to this: a
    /// reader that seeks past the ceiling is still fed at once.
    ///
    /// Returned as an ABSOLUTE ceiling rather than a distance: an earlier
    /// version handed back `Int64.max` as an unbounded distance and the caller
    /// added it to a byte offset, which in Swift is an overflow TRAP, not a
    /// saturating "no limit" — it killed the process outright on the first
    /// session small enough not to need a window. A bound that is only ever
    /// COMPARED against cannot do that.
    private var fillCeiling: Int64 {
        guard totalLength > 0 else { return .max }
        guard windowed else { return totalLength }
        return min(liveReadAnchor() + leadAllowance, totalLength)
    }

    /// The bounded lead itself, in bytes — shared by `fillCeiling` (where it
    /// bounds the download) and `archiveCeiling` (where it is reserved).
    private var leadAllowance: Int64 {
        guard totalLength > 0 else { return Self.minLeadBytes }
        let byTime = durationSeconds > 0
            ? Int64(Double(totalLength) / durationSeconds * Self.maxLeadSeconds)
            : Self.minLeadBytes
        return min(max(byTime, Self.minLeadBytes), max(budget / 2, Self.minLeadBytes))
    }

    private func bounded(_ gap: (start: Int64, end: Int64)) -> (start: Int64, end: Int64) {
        // At ONE allowed connection, chunking is pure overhead: a fresh
        // request every 8 MB means dead air on every boundary and a request
        // rate that is itself what some providers 429. A single worker gets
        // one long segment and simply streams; parallel workers get chunks so
        // the load balances and a slow one can't hold the edge back.
        // Bounded even so: a worker's UNWRITTEN span counts as claimed, so
        // the segment length is also the worst case a reader that seeks into
        // it must wait — 512 MB of that is longer than the stall timeout on
        // any ordinary link, and the wait ended in a dropped connection and a
        // failover rather than a slow start.
        let size = parallelLimit <= 1 ? Int64(64) * 1_048_576 : Self.chunkBytes
        return (gap.start, min(gap.start + size, gap.end))
    }

    /// First byte at or after `cursor` that is neither on disk NOR already
    /// being fetched. Ignoring in-flight segments here was the duplicate-
    /// download bug: two workers pulling the same bytes, halving throughput
    /// and doubling the connection count the provider sees.
    private func nextUnclaimedGap(from cursor: Int64) -> (start: Int64, end: Int64)? {
        guard totalLength > 0 else { return nil }
        var spans: [(start: Int64, end: Int64)] = ranges.map { ($0.start, $0.end) }
        for worker in workers {
            if let pending = worker.pendingSegment { spans.append(pending) }
        }
        for (start, end) in sideFetchSpans { spans.append((start, end)) }
        spans.sort { $0.start < $1.start }
        var probe = max(0, min(cursor, totalLength))
        for span in spans where span.end > probe {
            if span.start > probe { return (probe, min(span.start, totalLength)) }
            probe = max(probe, span.end)
        }
        return probe < totalLength ? (probe, totalLength) : nil
    }

    /// Recovery attempts made this session, so a origin that is simply broken
    /// can't be retried forever.
    private var recoveryAttempts = 0
    private static let maxRecoveryAttempts = 3

    /// Give up on the cache and play from the origin — but, for a failure that
    /// could be a passing thing, come back and try again.
    ///
    /// `failSession` used to be terminal for the life of the title. One HTTP
    /// 500 from a debrid host — seen on the device, three minutes into a film —
    /// and the hybrid cache was off for the whole two hours: no growing bar, no
    /// new preview frames, nothing caching to disk, and nothing anywhere that
    /// would ever try again. A transient error deserves a transient response.
    ///
    /// `retryable: false` is for the failures that are statements of fact
    /// rather than bad luck: the disk won't take writes, the origin won't say
    /// how long the file is.
    private func failSession(_ reason: String, retryable: Bool = true) {
        // Idempotent END TO END: `failSessionCore` guards itself, but the
        // retry must not be scheduled again for a session that is already
        // down, or every waiting reader on a dead session booked another one.
        guard !redirectAll else { return }
        failSessionCore(reason)
        scheduleCacheRetry(retryable: retryable)
    }

    private func scheduleCacheRetry(retryable: Bool) {
        guard retryable, recoveryAttempts < Self.maxRecoveryAttempts,
              writeHandle != nil, origin != nil else { return }
        recoveryAttempts += 1
        // Backed off, so a genuinely dead origin costs three attempts and
        // then stops rather than a request every twenty seconds.
        let delay = TimeInterval(20 << (recoveryAttempts - 1))
        let attempt = recoveryAttempts
        PlayerProbe.event("cache", "will retry the cache in \(Int(delay))s (attempt \(attempt) of \(Self.maxRecoveryAttempts))")
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.redirectAll, self.recoveryAttempts == attempt,
                  self.writeHandle != nil, self.origin != nil else { return }
            // The file and everything already on disk are still good — this
            // is only re-opening the tap. The engine keeps the proxy as its
            // base URL through a 307, so its next range request comes back
            // here and is served from the cache again.
            self.redirectAll = false
            self.failureReason = nil
            self.pausedForSpace = false
            self.pausedForSpaceSince = nil
            self.lastWriteAt = Date()
            NSLog("[OrivioCache] retrying the cache session (attempt %d)", attempt)
            PlayerProbe.event("cache", "RETRYING the cache session (attempt \(attempt))")
            self.ensurePool()
            self.publishSnapshot()
        }
    }

    private func failSessionCore(_ reason: String) {
        // ONCE. Callers include `resumeIfRoom`, which runs off the serve loop's
        // 80ms availability poll — so an unguarded re-entry re-failed the same
        // dead session twice a second for as long as it stayed dead, burying
        // the log and scheduling a retry on every pass.
        guard !redirectAll else { return }
        // The window is no longer the download's problem once we have handed
        // the stream back to the origin; leaving it parked would keep
        // `resumeIfRoom` coming back here.
        pausedForSpace = false
        pausedForSpaceSince = nil
        // Fail OPEN, but never silently: the reason reaches the colour trail
        // (readable live over the dev probe endpoint) and the snapshot, so
        // the UI knows the cache is gone and the band can fall back honestly.
        NSLog("[OrivioCache] session failed: %@ — redirecting to origin", reason)
        PlayerProbe.event("cache", "SESSION FAILED: \(reason)")
        PlayerViewModel.colorTrail("cache session failed: \(reason) — direct playback from origin")
        failureReason = reason
        redirectAll = true
        for worker in workers { worker.cancel() }
        workers = []
        publishSnapshot()
    }

    /// Decide what this session may hold on disk, now that the file's size is
    /// known. A film that fits whole gets the original full-file behaviour; a
    /// bigger one gets a sliding window when the origin can seek; only a box
    /// too full for even a useful window falls back to direct playback.
    private func configureBudget() -> Bool {
        // WHY A WRITE-BLIND FALLBACK WAS A BUG. This used to read `budget =
        // totalLength; windowed = false` when the free-space query failed — an
        // unbounded full-file download decided on a volume whose free space we
        // could not read. On a near-full Apple TV that is precisely how the
        // cache filled the disk and took the system down with it. Refusing to
        // cache is a slower film; gambling the box is not a trade.
        guard let free = volumeFreeBytes() else {
            failSession("could not read the Apple TV's free space — not caching this stream",
                        retryable: false)
            return false
        }
        lastKnownFreeBytes = free
        freeSpaceCheckedAt = Date()
        let available = max(0, free - Self.slackBytes)
        let totalGB = Double(totalLength) / 1e9
        let freeGB = Double(free) / 1e9
        if totalLength <= available {
            budget = totalLength
            windowed = false
            publishSnapshot()
            return true
        }
        guard rangeCapable else {
            failSession(String(format: "file is %.1f GB with %.1f GB free, and the origin can't seek — a sliding window needs range requests", totalGB, freeGB))
            return false
        }
        guard available >= Self.minWindowBytes else {
            failSession(String(format: "not enough space even for a sliding window (file is %.1f GB, %.1f GB free)", totalGB, freeGB))
            return false
        }
        budget = available
        windowed = true
        publishSnapshot()
        let line = String(format: "cache: sliding window — %.1f GB of the %.1f GB file, evicting behind playback", Double(budget) / 1e9, totalGB)
        NSLog("[OrivioCache] %@", line)
        PlayerViewModel.colorTrail(line)
        return true
    }

    /// Real free space on the volume the cache file lives on, or nil when the
    /// filesystem won't say.
    ///
    /// Two sources on purpose: the URL resource value is the documented one, but
    /// it can be absent for a URL (and the "important usage" variant is not
    /// available on tvOS), and `attributesOfFileSystem` is the long-standing
    /// fallback that has never been sandboxed away.
    private func volumeFreeBytes() -> Int64? {
        guard let dir = fileURL?.deletingLastPathComponent() else { return nil }
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity {
            return Int64(free)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// Keep the device's own storage floor intact, whatever the budget says.
    ///
    /// Returns false when the cache has been stood down to protect the box.
    /// Sampling is throttled because this runs on the same serial queue that
    /// feeds the player its bytes.
    @discardableResult
    private func enforceStorageFloor() -> Bool {
        guard !redirectAll, writeHandle != nil else { return true }
        let now = Date()
        guard now.timeIntervalSince(freeSpaceCheckedAt) >= Self.freeSpaceCheckInterval else {
            return true
        }
        freeSpaceCheckedAt = now
        guard let free = volumeFreeBytes() else {
            // Unknowable is not a licence to write blind. If no budget was ever
            // established, stand the cache down rather than gamble the box.
            if budget <= 0 { failStorageEmergency(free: 0); return false }
            return true
        }
        lastKnownFreeBytes = free
        guard free < Self.slackBytes else { return true }
        let shortfall = Self.slackBytes - free
        PlayerProbe.event("cache", "STORAGE FLOOR — \(free / 1_048_576)MB free,"
            + " need \(shortfall / 1_048_576)MB back")
        PlayerProbe.note("lastStorageFloor", "\(free / 1_048_576)MB free")
        // Try to hand the space back before giving anything up.
        if windowed {
            evictOldest(target: shortfall + Self.resumeHeadroomBytes)
            if let after = volumeFreeBytes(), after >= Self.slackBytes {
                publishSnapshot()
                return true
            }
            // Still short: there may be nothing evictable this instant (it is
            // all lead, or a live reader's rewind margin). Park the download
            // and let playback coast on what is on disk; the window frees
            // itself as the viewer advances.
            pauseForStorage()
            return true
        }
        // Full-file mode has nothing to evict — the whole premise was that the
        // film fit. The volume has lost space underneath us, so the only safe
        // move is to give the cache file back and let the engine play direct.
        failStorageEmergency(free: free)
        return false
    }

    /// Park the download because the VOLUME is low, not because the window is
    /// full.
    ///
    /// Separate from `pauseForSpaceIfNeeded`, which re-checks the budget and may
    /// decide nothing is wrong — and that is exactly the case the floor exists
    /// for: the window is within budget while the box around it is running out
    /// of room.
    private func pauseForStorage() {
        guard !pausedForSpace else { return }
        pausedForSpace = true
        pausedForSpaceSince = Date()
        for worker in workers { worker.cancelSegment() }
        publishSnapshot()
        NSLog("[OrivioCache] storage floor reached (%lld bytes free) — download parked",
              lastKnownFreeBytes)
        PlayerProbe.event("cache", "STORAGE FLOOR — download parked"
            + " (\(lastKnownFreeBytes / 1_048_576)MB free)")
    }

    /// The volume is critically low: stop writing and DELETE the cache file,
    /// which is the whole reason the volume got there.
    ///
    /// The session is not torn down — the token and origin have to survive so
    /// that the 307 fail-open redirects keep working — but the bytes are handed
    /// straight back.
    private func failStorageEmergency(free: Int64) {
        let reading = free > 0 ? " (\(free / 1_048_576)MB free)" : ""
        failSessionCore("device storage critically low\(reading) —"
            + " cache stopped to protect the Apple TV")
        reclaimCacheFileLocked()
    }

    /// Delete the cache file now, independently of session teardown. Open read
    /// handles keep working against the unlinked inode; new requests redirect.
    private func reclaimCacheFileLocked() {
        try? writeHandle?.close()
        writeHandle = nil
        if let fileURL {
            let doomed = fileURL.deletingLastPathComponent()
                .appendingPathComponent("expired-\(UUID().uuidString).bin")
            if (try? FileManager.default.moveItem(at: fileURL, to: doomed)) != nil {
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.removeItem(at: doomed)
                }
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        fileURL = nil
        ranges = []
        totalLength = -1
        budget = 0
        windowed = false
        pausedForSpace = false
        pausedForSpaceSince = nil
        publishSnapshot()
    }


    /// Bytes currently held on disk.
    private func usedBytes() -> Int64 {
        ranges.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// The slowest live reader's position — the point eviction must respect.
    private func minActiveRead() -> Int64 {
        readOffsets.values.min() ?? lastReadOffset
    }

    /// The reader that is actually PLAYING — the one served most recently.
    ///
    /// `minActiveRead()` answers a different question ("what must eviction not
    /// pull out from under anyone?") and is deliberately a minimum, so after a
    /// forward seek it names the connection the engine has LEFT rather than the
    /// one it is watching through. Anything that should follow the viewer — how
    /// much road is ahead of them, where the pool ought to be filling — has to
    /// ask this instead, or it aims itself at the seek before last.
    private func liveReadAnchor() -> Int64 {
        guard let newest = readTouchedAt.max(by: { $0.value < $1.value })?.key,
              let offset = readOffsets[newest] else { return lastReadOffset }
        return offset
    }

    /// How long a media reader may go unserved before it counts as abandoned.
    /// Generous: `serve` refreshes the timestamp every 80ms even while merely
    /// WAITING for bytes, so the only way to reach this is a connection whose
    /// serve loop has stopped entirely.
    private static let readerAbandonTimeout: TimeInterval = 12

    /// Close readers the engine walked away from without closing the socket.
    ///
    /// `watchForPeerClose` catches the ordinary case. It cannot catch this one:
    /// on a seek FFmpeg opens the next range request and simply stops draining
    /// the old socket, so the send in flight never completes, the serve loop
    /// for that connection never runs again, and the peer never closes. The
    /// entry sits in `readOffsets` for the rest of the session.
    ///
    /// One is survivable. Several are not, and several is what "scrub and click
    /// around a few times" produces: each pins `minActiveRead()` further back,
    /// each anchors its own protected span in `evictAhead`, and between them
    /// they hold the whole budget in film nobody is watching — the window stops
    /// sliding, the download parks, and the cache bar stops growing.
    ///
    /// ONLY WHEN ANOTHER READER IS FRESH. A player parked on a pause also stops
    /// draining its socket, and it has exactly one reader; requiring a live
    /// sibling is what tells "the engine moved on" apart from "the viewer
    /// pressed pause", without guessing at transport state from in here.
    private func reapAbandonedReaders() {
        guard readOffsets.count > 1 else { return }
        let now = Date()
        let fresh = readTouchedAt.contains {
            readOffsets[$0.key] != nil
                && now.timeIntervalSince($0.value) < Self.readerAbandonTimeout
        }
        guard fresh else { return }
        for (id, touched) in readTouchedAt
        where now.timeIntervalSince(touched) >= Self.readerAbandonTimeout {
            guard let connection = connections[id], readOffsets[id] != nil else { continue }
            PlayerProbe.event("cache", "reaping an ABANDONED reader at"
                + " \(readOffsets[id].map { $0 / 1_048_576 } ?? -1)MB —"
                + " unserved for \(Int(now.timeIntervalSince(touched)))s")
            requestTrail("reaping abandoned reader at \(readOffsets[id] ?? -1)", important: true)
            drop(connection)
        }
    }

    /// Punch the byte range out of the sparse cache file, returning the
    /// blocks to the filesystem. Bounds are block-aligned inward; the caller
    /// removes exactly the same aligned span from `ranges`.
    private func punchHole(from start: Int64, to end: Int64) -> Bool {
        guard let fd = writeHandle?.fileDescriptor else { return false }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0,
                                fp_offset: off_t(start), fp_length: off_t(end - start))
        return fcntl(fd, F_PUNCHHOLE, &hole) == 0
    }

    /// Free `target` bytes, taking the film that has been cached LONGEST first.
    ///
    /// This replaces a pair of playhead-relative passes — one that freed
    /// everything behind the reader, one that freed regions in front of it —
    /// and the reason is that both answered the wrong question. They asked
    /// "where is this film relative to the viewer?", so seeking forward an hour
    /// made every earlier region "behind" and threw it away, including an
    /// opening the archive had just finished building. Cached film does not
    /// stop being useful because the viewer moved; the only thing that makes a
    /// stretch expendable is that it has been sitting there longer than
    /// everything else.
    ///
    /// So: oldest run first, whether that run is the beginning, the middle or
    /// the end of the film. A Continue Watching session that starts at the
    /// half-way mark gives up the half-way mark first, because that is what it
    /// cached first.
    ///
    /// Never under a live reader, and never the header. Partial eviction is
    /// deliberate — a run is trimmed from its own start by exactly what is
    /// asked for, so a request for a little headroom costs a little film.
    @discardableResult
    private func evictOldest(target: Int64) -> Int64 {
        guard windowed, !evictionBroken, target > 0 else { return 0 }
        let blockSize: Int64 = 4096
        // A span around every live reader — the one that is playing keeps its
        // whole forward run, since that is where the pool is building and
        // freeing it only means fetching it again.
        let live = liveReadAnchor()
        let anchors = readOffsets.values.isEmpty ? [minActiveRead()] : Array(readOffsets.values)
        let protected: [(start: Int64, end: Int64)] = anchors.map { anchor in
            let runStart = max(anchor - keepBehindBytes, 0)
            let runEnd = anchor == live
                ? max(coverageEnd(from: anchor), anchor + Self.keepAheadBytes)
                : anchor + Self.keepAheadBytes
            return (runStart, runEnd)
        } + [(0, Self.headerProtectBytes)]

        /// The parts of `range` no reader needs, in file order.
        func evictable(_ range: CachedRange) -> [(start: Int64, end: Int64)] {
            var pieces = [(start: range.start, end: range.end)]
            for guardSpan in protected {
                var next: [(start: Int64, end: Int64)] = []
                for piece in pieces {
                    if guardSpan.end <= piece.start || guardSpan.start >= piece.end {
                        next.append(piece)
                    } else {
                        if guardSpan.start > piece.start { next.append((piece.start, guardSpan.start)) }
                        if guardSpan.end < piece.end { next.append((guardSpan.end, piece.end)) }
                    }
                }
                pieces = next
            }
            return pieces.sorted { $0.start < $1.start }
        }

        var freed: Int64 = 0
        var kept: [CachedRange] = []
        // OLDEST FIRST. This is the whole policy.
        for range in ranges.sorted(by: { $0.born < $1.born }) {
            guard freed < target, let piece = evictable(range).first else {
                kept.append(range); continue
            }
            let evictStart = (piece.start + blockSize - 1) / blockSize * blockSize
            let outstanding = max(target - freed, 0)
            let evictEnd = min(piece.end, evictStart + outstanding) / blockSize * blockSize
            guard evictEnd - evictStart >= Self.minEvictBytes else { kept.append(range); continue }
            guard punchHole(from: evictStart, to: evictEnd) else {
                evictionBroken = true
                NSLog("[OrivioCache] F_PUNCHHOLE failed — window can't slide, capping at budget")
                PlayerViewModel.colorTrail("cache: hole punch failed — window frozen at budget")
                kept.append(range)
                continue
            }
            freed += evictEnd - evictStart
            if evictStart > range.start {
                kept.append(CachedRange(start: range.start, end: evictStart, born: range.born))
            }
            if range.end > evictEnd {
                kept.append(CachedRange(start: evictEnd, end: range.end, born: range.born))
            }
        }
        if freed > 0 {
            ranges = kept.sorted { $0.start < $1.start }
            evictedTotal += freed
            PlayerProbe.event("cache", "evicted \(freed / 1_048_576)MB of the longest-held film"
                + " (readers at \(readOffsets.values.sorted().map { $0 / 1_048_576 }))")
            publishSnapshot()
        }
        return freed
    }



    /// The download reached the budget: stop the network until playback has
    /// advanced far enough to evict something.
    private func pauseForSpaceIfNeeded() {
        guard !pausedForSpace else { return }
        // Before giving up: the regions the viewer jumped away from are dead
        // weight, and on a session with any seeking in it they are most of what
        // is holding the budget.
        if evictOldest(target: Self.resumeHeadroomBytes) > 0,
           usedBytes() + Self.resumeHeadroomBytes <= budget {
            return
        }
        pausedForSpace = true
        for worker in workers { worker.cancelSegment() }
        publishSnapshot()
        NSLog("[OrivioCache] window full (%lld of %lld) — download paused until playback advances", usedBytes(), budget)
        pausedForSpaceSince = Date()
        PlayerProbe.event("cache", "WINDOW FULL — download paused"
            + " (used=\(usedBytes() / 1_048_576)MB budget=\(budget / 1_048_576)MB"
            + " slowestReader=\(minActiveRead() / 1_048_576)MB)")
    }

    /// A worker holding a segment it has stopped writing to.
    ///
    /// Observed on the device: `pool=1/1`, one pending segment, `lastWrite`
    /// nearly a minute old, `paused=false`, and the session perfectly healthy
    /// from the outside — because the reader was still being served out of a
    /// gigabyte of already-cached lead and so never entered the waiting branch
    /// where stall detection lives. Nothing was watching the DOWNLOAD itself.
    /// By the time the reader arrived at the frontier the film had a minute of
    /// dead air waiting for it.
    ///
    /// Cheap to check and cheap to act on: cancel the segment and let the pool
    /// re-assign it. A worker that is genuinely just slow loses one chunk.
    private func reapStalledWorkers() {
        guard !redirectAll, !pausedForSpace, writeHandle != nil else { return }
        guard Date().timeIntervalSince(lastWriteAt) > Self.workerStallTimeout else { return }
        let stuck = workers.filter { !$0.isIdle && $0.pendingSegment != nil }
        guard !stuck.isEmpty else { return }
        lastWriteAt = Date()   // one reap per window, not one per poll
        PlayerProbe.event("cache", "reaping \(stuck.count) stalled worker(s) — no bytes for"
            + " \(Int(Self.workerStallTimeout))s")
        for worker in stuck { worker.cancelSegment() }
        kickPool()
    }

    /// How long a worker may hold a segment without writing before the pool
    /// takes it back. Shorter than `stallTimeout`, which governs the reader.
    private static let workerStallTimeout: TimeInterval = 20

    /// Called as reads advance: if the download is parked on a full window,
    /// try to slide it and pick the download back up.
    private func resumeIfRoom() {
        guard pausedForSpace else { return }
        // A window within budget can still be parked because the VOLUME is
        // below the storage floor. Hold until there is real room — and sample
        // here, because a parked download writes nothing, so the write-path
        // sampler is not running to notice the recovery.
        if lastKnownFreeBytes >= 0, lastKnownFreeBytes < Self.slackBytes {
            let now = Date()
            if now.timeIntervalSince(freeSpaceCheckedAt) >= Self.freeSpaceCheckInterval {
                freeSpaceCheckedAt = now
                if let free = volumeFreeBytes() { lastKnownFreeBytes = free }
            }
            if lastKnownFreeBytes < Self.slackBytes { return }
        }
        let over = max(usedBytes() + Self.resumeHeadroomBytes - budget, 0)
        evictOldest(target: over + Self.resumeHeadroomBytes)
        guard usedBytes() + Self.resumeHeadroomBytes <= budget else {
            // NEVER WEDGE. A reader waiting for bytes the download is parked
            // from fetching is a deadlock with no way out of itself, and the
            // stall timeout in `serve` cannot break it: the engine closes and
            // reopens the connection as it retries, and every reopen starts a
            // fresh 25-second clock that therefore never expires. Observed as
            // a stone-dead player — `paused=true`, `pool=0/8`, no write for 70
            // seconds, a reader polling at 80ms forever.
            //
            // ONLY WHILE A READER IS ACTUALLY WAITING. Without that clause
            // this fired on a perfectly healthy session: the download had run
            // 10.5 GB — twenty-seven minutes — in front of the playhead, that
            // one contiguous run WAS the whole budget, `evictAhead` rightly
            // would not touch the film the viewer is about to watch, and so
            // "nothing evictable" was true for twenty seconds while the picture
            // was flawless and the reader had not waited for a byte. Killing
            // the cache there threw away the disk cache and the scrub previews
            // for the rest of the film to solve a deadlock that did not exist.
            // (The lead is bounded now, so the window should not fill like that
            // in the first place — but "full with a deep buffer" is a fine
            // steady state whenever it does, and must not be fatal.)
            let readerIsWaiting = Date().timeIntervalSince(lastReaderWaitAt) < 2
            if readerIsWaiting, let since = pausedForSpaceSince,
               Date().timeIntervalSince(since) > Self.wedgeTimeout {
                failSession("a reader has waited \(Int(Self.wedgeTimeout))s"
                    + " on a full window with nothing evictable")
            }
            return
        }
        pausedForSpace = false
        pausedForSpaceSince = nil
        kickPool()
        publishSnapshot()
        NSLog("[OrivioCache] window slid — download resumed")
        PlayerProbe.event("cache", "window slid — download resumed")
    }
}

// MARK: - Segment downloader

/// One bounded range fetch on its own connection, for data far from the
/// sequential frontier (a container's index).
///
/// Delegate-based rather than a completion-handler `dataTask`, for one
/// specific reason: a completion handler buffers the ENTIRE response before
/// anything can inspect it, so an origin that ignores the Range header and
/// answers 200 with the whole file would be held in memory in full — a 4 GB
/// remux is a jetsam kill on a 3 GB box, and writing it at the requested
/// offset would corrupt the cache besides. Here the response is inspected
/// first and anything but a 206 is cancelled before a byte is buffered.
private final class SideFetcher: NSObject, URLSessionDataDelegate {
    private let span: Int64
    private let completion: (Data?) -> Void
    private var session: URLSession!
    private var buffer = Data()
    private var finished = false

    init(origin: URL, headers: [String: String]? = nil,
         start: Int64, endExclusive: Int64, queue: DispatchQueue,
         completion: @escaping (Data?) -> Void) {
        span = endExclusive - start
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The bytes are already being written to our own cache file; letting
        // URLCache take a second copy is pure overhead.
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: origin)
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(start)-\(endExclusive - 1)", forHTTPHeaderField: "Range")
        session.dataTask(with: request).resume()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if Int64(buffer.count) > span {   // origin sending more than asked
            dataTask.cancel()
            finish(nil)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && !buffer.isEmpty ? buffer : nil)
    }

    /// Abandon the fetch WITHOUT calling the completion.
    ///
    /// Forgetting the fetcher is not enough to stop it: the session holds this
    /// object as its delegate and this object holds the session, so an orphan
    /// stays alive and runs to completion or its 20s timeout, and then hands
    /// back a film that is no longer playing. Only an explicit invalidate ends
    /// it, and the completion must not fire — see `teardownSessionLocked`.
    func cancel() {
        guard !finished else { return }
        finished = true
        session.invalidateAndCancel()
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        session.invalidateAndCancel()
        completion(data)
    }
}

/// One URLSession pulling the origin at full speed, one segment at a time,
/// writing straight through to the cache file. `jump(to:)` abandons the
/// current segment for the viewer's seek point; `MediaCacheServer` restarts
/// it on the gaps afterwards.
private final class SegmentDownloader: NSObject, URLSessionDataDelegate {
    private weak var server: MediaCacheServer?
    private let origin: URL
    /// Addon-declared headers for every origin request this worker makes.
    private let headers: [String: String]?
    private let q: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionDataTask?
    /// First byte of `buffer` — i.e. the next byte this worker owes the
    /// cache file. Deliberately NOT "the last byte received": buffered bytes
    /// must still read as claimed, or a sibling worker fetches them again.
    private var writeOffset: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var segmentEnd: Int64?
    private var retries = 0
    private var cancelled = false

    /// URLSession hands data over in 16-64 KB pieces, and every one of them
    /// used to become a seek, a write, a range merge and a snapshot copy on
    /// the server's single serial queue — the same queue that serves the
    /// player its bytes. At line speed that is thousands of round trips a
    /// second competing with playback. Coalesce into one write per few MB.
    private var buffer = Data()
    private var lastFlush = CFAbsoluteTimeGetCurrent()
    /// Flush at whichever comes first, so a fast link batches by size and a
    /// slow one still publishes coverage promptly for a waiting reader.
    /// Per-worker, so the pool's transient RAM is workers × this — halved on
    /// the 2 GB box (4 workers × 2 MB vs the old 8 × 4 MB = 32 MB).
    private static let flushBytes = PerformanceProfile.isLowPower
        ? 2 * 1_048_576 : 4 * 1_048_576
    private static let flushSeconds: CFAbsoluteTime = 0.12

    /// Hand the buffered run to the cache file (on q).
    private func flush() {
        guard !buffer.isEmpty, let server else { return }
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        lastFlush = CFAbsoluteTimeGetCurrent()
        // ADVANCE THE CURSOR BEFORE CALLING OUT, and write at the captured
        // offset. `downloaderWrote` re-enters this worker synchronously — its
        // ramp branch reaches `kickPool` -> `preemptForStarvedReader`, which can
        // pick THIS worker as the victim, cancel its segment and `start(at:)` it
        // somewhere else, setting `writeOffset` to the new position. Control
        // then unwound to the old `writeOffset += data.count` here and moved the
        // freshly-repositioned cursor by the length of the PREVIOUS write, so
        // the next flush wrote its bytes at the wrong file offset — silent
        // corruption of the cached file.
        let at = writeOffset
        writeOffset += Int64(data.count)
        server.downloaderWrote(data, at: at)
    }

    /// Throw away undelivered bytes — the segment they belonged to is being
    /// abandoned, and `writeOffset` still points at the last durable byte.
    private func discardBuffer() { buffer.removeAll(keepingCapacity: true) }

    /// No segment in hand — the pool may assign one.
    var isIdle: Bool { task == nil && !cancelled }

    /// The bytes this worker is still expected to deliver, so chunk
    /// assignment treats them as claimed rather than fetching them twice.
    var pendingSegment: (start: Int64, end: Int64)? {
        guard task != nil else { return nil }
        return (writeOffset, segmentEnd ?? writeOffset + 64 * 1_048_576)
    }

    /// Bytes received but not yet written — the pool asks so it can tell a
    /// waiting reader's shortfall apart from a genuinely stranded one.
    var bufferedBytes: Int { buffer.count }

    /// Push whatever is held out to disk now (on q). Called when a reader is
    /// waiting on the very bytes this worker is sitting on.
    func flushNow() { flush() }

    /// Stand down until the pool has work again.
    func park() {
        task?.cancel()
        task = nil
        discardBuffer()
    }

    /// Abandon the current segment WITHOUT retiring: a seek moved the pool, or
    /// the sliding window ran out of budget. Distinct from `cancel()`, which
    /// tears the worker down for good.
    func cancelSegment() {
        // Keep what arrived: those bytes are valid and paid for, and dropping
        // them means re-fetching them after every preemption.
        flush()
        task?.cancel()
        task = nil
    }

    init(server: MediaCacheServer, origin: URL,
         headers: [String: String]? = nil, queue: DispatchQueue) {
        self.server = server
        self.origin = origin
        self.headers = headers
        self.q = queue
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30       // idle, not total
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The bytes are already being written to our own cache file; letting
        // URLCache take a second copy is pure overhead.
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    /// Begin (or re-begin) downloading from `offset` (on q).
    func start(at offset: Int64, endExclusive: Int64? = nil) {
        task?.cancel()
        discardBuffer()
        lastFlush = CFAbsoluteTimeGetCurrent()
        segmentEnd = endExclusive
        requestedOffset = offset
        writeOffset = offset
        var request = URLRequest(url: origin)
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let endExclusive {
            request.setValue("bytes=\(offset)-\(endExclusive - 1)", forHTTPHeaderField: "Range")
        } else if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else {
            // Ranged even at zero, so the very first response reveals whether
            // the origin can seek (206) or not (200).
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled, dataTask === task, let http = response as? HTTPURLResponse,
              let server else { completionHandler(.cancel); return }
        switch server.downloaderGotResponse(http, requestedOffset: requestedOffset) {
        case .allow:
            completionHandler(.allow)
        case .retryLater(let delay):
            completionHandler(.cancel)
            flush()
            let offset = writeOffset
            let end = segmentEnd
            task = nil
            server.downloaderThrottled(self, resumeAt: offset, end: end, after: delay)
        case .restartAtZero:
            completionHandler(.cancel)
            // STAND DOWN AND LET THE POOL DECIDE, rather than reopening from
            // zero on our own. An origin that stops honouring Range hands this
            // same verdict to every worker in flight, and each one restarting
            // itself meant one full-file stream per worker — the duplication
            // the no-range branch of `assignChunk` guards against, arrived at
            // through a door that never passes through it. Going idle releases
            // this worker's claim and routes the decision through that one
            // guard, which reopens the stream on exactly one connection.
            task = nil
            server.downloaderFinishedSegment(self)
        case .abandon:
            completionHandler(.cancel)
            task = nil
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, dataTask === task, server != nil else { return }
        buffer.append(data)
        if buffer.count >= Self.flushBytes
            || CFAbsoluteTimeGetCurrent() - lastFlush >= Self.flushSeconds {
            flush()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled, task === self.task, let server else { return }
        // Whatever arrived is durable regardless of how this ended.
        flush()
        if let error {
            let code = (error as NSError).code
            // A cancel is the pool repositioning or parking us, never a
            // failure — and `task` is already nil in that case.
            if code == NSURLErrorCancelled { return }
            retries += 1
            guard retries <= 3 else {
                self.task = nil
                server.downloaderFailed(self)
                return
            }
            // KEEP THE BOUND. `start(at:endExclusive:)` defaults the end to
            // nil, so retrying without it turned a bounded 16 MB chunk into an
            // open-ended stream to EOF: `pendingSegment` then advertised only a
            // rolling window, `nextUnclaimedGap` handed everything past it to
            // other workers, and they re-downloaded bytes this one was already
            // streaming. (The deliberately unbounded case is the
            // restart-at-zero verdict, which passes nil on purpose.)
            let offset = writeOffset
            let end = segmentEnd
            self.task = nil   // not busy while it waits, so the pool can plan
            q.asyncAfter(deadline: .now() + Double(retries)) { [weak self] in
                guard let self, !self.cancelled, self.task == nil else { return }
                self.start(at: offset, endExclusive: end)
            }
            return
        }
        retries = 0
        self.task = nil
        server.downloaderFinishedSegment(self)
    }
}
