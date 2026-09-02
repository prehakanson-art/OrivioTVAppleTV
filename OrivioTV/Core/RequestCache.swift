import Foundation
import CryptoKit

/// Coalesces concurrent identical requests: if the same key is already being
/// fetched, later callers await the SAME task instead of firing their own
/// network round-trip. Ported from the Android app's `inFlight*` maps in
/// MetaRepositoryImpl — without it, a Home screen (many rows) + focus-prefetch
/// + back-nav fire piles of duplicate requests for the same meta/catalog.
actor RequestCoalescer {
    private var inFlight: [String: Task<Data, Error>] = [:]

    func data(for key: String, _ work: @Sendable @escaping () async throws -> Data) async throws -> Data {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await work() }
        inFlight[key] = task
        let result = await task.result
        inFlight[key] = nil
        return try result.get()
    }
}

/// A thread-safe, disk-backed TTL cache of `Codable` values keyed by string.
/// Entries survive app relaunches (JSON in Caches/), with a small in-memory
/// layer on top so repeat reads in a session don't touch disk. Reads check
/// freshness against a caller-supplied TTL. Ported from the Android app's
/// DataStore caches (StreamLinkCache / enrichment) so re-opening a title is
/// instant instead of another addon sweep or meta fetch.
actor DiskCache<Value: Codable & Sendable> {
    private struct Entry: Codable { let value: Value; let time: Date }
    private let directory: URL
    private var memory: [String: Entry] = [:]
    /// The in-RAM mirror exists only to skip repeat disk reads within a
    /// session — uncapped it grows for the app's lifetime (every catalog /
    /// meta / enrichment response ever touched stays decoded in memory).
    /// Eviction is invisible: entries re-read from disk on the next hit.
    private let memoryLimit = 64

    private func capMemory() {
        guard memory.count > memoryLimit else { return }
        // Drop the oldest half so eviction is amortized, not per-insert.
        let sorted = memory.sorted { $0.value.time < $1.value.time }
        for (key, _) in sorted.prefix(memory.count - memoryLimit / 2) {
            memory.removeValue(forKey: key)
        }
    }

    init(name: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("OrivioCache/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One-time cleanup of the pre-rebrand cache dir, so it doesn't sit
        // orphaned on disk forever (it would never be read or evicted again).
        // Off-thread: several DiskCaches init during launch, and deleting a
        // potentially large directory synchronously there would block startup.
        let legacy = base.appendingPathComponent("NuvioCache", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
    }

    /// Fresh value for `key`, or nil if missing/stale (`ttl <= 0` disables).
    func value(for key: String, ttl: TimeInterval) -> Value? {
        guard ttl > 0 else { return nil }
        let entry: Entry?
        if let hit = memory[key] {
            entry = hit
        } else if let data = try? Data(contentsOf: fileURL(key)),
                  let decoded = try? JSONDecoder().decode(Entry.self, from: data) {
            memory[key] = decoded
            capMemory()
            entry = decoded
        } else {
            entry = nil
        }
        guard let entry, Date().timeIntervalSince(entry.time) < ttl else { return nil }
        return entry.value
    }

    func store(_ value: Value, for key: String) {
        let entry = Entry(value: value, time: Date())
        memory[key] = entry
        capMemory()
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: fileURL(key), options: .atomic)
        }
    }

    private func fileURL(_ key: String) -> URL {
        let hashed = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hashed).appendingPathExtension("json")
    }
}

/// One addon's stream cached for a title (raw, pre-curation) so the Sources
/// list can be rebuilt instantly on re-open. Debrid resolution still happens
/// fresh on selection, and the player's failover re-fetches if a cached direct
/// link has expired — so the short TTL is safe.
struct CachedStreamSource: Codable, Sendable {
    let addonName: String
    let stream: Stream
}
