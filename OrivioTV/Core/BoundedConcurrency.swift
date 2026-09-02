import Foundation

/// Runs `work` over `items` with at most `limit` tasks in flight, returning the
/// results in the ORIGINAL order of `items`.
///
/// Every addon sweep in the app used to be an unbounded `withTaskGroup` — one
/// task per addon (or per catalog). That is fine for the ~5 addons a default
/// install has, but an account with 40–60 installed addons turned a single Home
/// load into 300+ simultaneous URLSession requests, each holding its response
/// buffer, all landing on the main actor at once. On an Apple TV that is a
/// jetsam kill, not a slow load. Capping the window keeps peak memory flat and
/// barely costs wall-clock time: the tail is dominated by the slowest addon,
/// not by how many start at t=0.
func boundedConcurrentMap<Item: Sendable, Result: Sendable>(
    _ items: [Item],
    limit: Int,
    _ work: @escaping @Sendable (Item) async -> Result
) async -> [Result] {
    guard !items.isEmpty else { return [] }
    let window = max(1, min(limit, items.count))

    return await withTaskGroup(of: (Int, Result).self) { group in
        var results = [Result?](repeating: nil, count: items.count)
        var next = 0

        // Prime the window, then top it back up as each task finishes so there
        // are never more than `window` requests outstanding.
        while next < window {
            let index = next
            let item = items[index]
            group.addTask { (index, await work(item)) }
            next += 1
        }
        for await (index, value) in group {
            results[index] = value
            if next < items.count {
                let nextIndex = next
                let item = items[nextIndex]
                group.addTask { (nextIndex, await work(item)) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}

/// Concurrency ceilings for the addon sweeps. Sized so a big install stays
/// within a couple of hundred MB of peak transfer buffers while still
/// saturating a typical connection.
enum AddonSweepLimits {
    /// Manifest fetches (login pull, launch refresh). Small responses, but one
    /// per installed addon.
    static var manifests: Int {
        PerformanceProfile.isLowPower ? 4 : 6
    }
    /// Home catalog rows. The heaviest payloads in the app (a catalog page is
    /// easily 100s of KB) and every result is retained for the whole load.
    static var catalogs: Int {
        if PerformanceProfile.isLowPower { return 3 }
        if PerformanceProfile.isMidPower { return 4 }
        return 6
    }
    /// Per-title stream sweeps. Higher than the others because the user is
    /// actively waiting on this one and responses are small.
    static var streams: Int {
        PerformanceProfile.isLowPower ? 5 : 8
    }
    /// Plugin scrapers. Lowest of the lot: each concurrent run stands up its own
    /// JSContext, which costs orders of magnitude more than an HTTP request.
    static var plugins: Int {
        if PerformanceProfile.isLowPower { return 2 }
        if PerformanceProfile.isMidPower { return 3 }
        return 4
    }
    /// Hard ceiling on Home rows regardless of how many catalogs the installed
    /// addons declare. Row layouts build their rows EAGERLY (a non-lazy VStack,
    /// so the LazyHStacks inside keep their scroll position), so an account
    /// with 50 addons would otherwise materialize 300 rows up front and take
    /// the focus engine down with it. Rows past the cap are still reachable
    /// from Discover / See All; the user can also reorder Home in
    /// Settings → Layout to pull a specific catalog into the visible set.
    static var maxHomeRows: Int {
        PerformanceProfile.isLowPower ? 42 : 60
    }
}
