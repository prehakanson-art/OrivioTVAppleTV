import SwiftUI

@main
struct OrivioTVApp: App {
    private let stores: AppStores

    init() {
        #if DEBUG
        // Start the trail here rather than on first frame: the launch marks
        // below are written before RootView exists and a later reset erased them.
        DebugLog.reset()
        let t0 = DebugLog.launchMark("init")
        #endif
        // 1. Repair defaults before migrations, then one-time migrations.
        Persistence.reclaimOversizedBlobs()
        #if DEBUG
        DebugLog.launchMark("reclaim", since: t0)
        #endif
        Migrations.run()
        #if DEBUG
        DebugLog.launchMark("migrations", since: t0)
        #endif
        // 2. Sweep orphaned player scratch files.
        PlayerScratch.sweep()
        #if DEBUG
        DebugLog.launchMark("scratch", since: t0)
        #endif
        stores = AppStores.shared
        #if DEBUG
        DebugLog.launchMark("stores", since: t0)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .withAppStores(stores)
                .preferredColorScheme(.dark)
        }
    }
}

enum Migrations {
    static func run() {
        let d = Persistence.defaults
        let doneKey = Persistence.key("migration.renameFromNuvio.v1")
        guard !Persistence.bool(forKey: doneKey) else { return }
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("nuvio.") {
            let newKey = "orivio." + k.dropFirst("nuvio.".count)
            if !Persistence.hasValue(key: newKey) { Persistence.set(v, forKey: newKey) }
            Persistence.set(nil, forKey: k)
        }
        Persistence.set(true, forKey: doneKey)
    }
}

enum PlayerScratch {
    static var directory: URL {
        Persistence.cachesURL.appendingPathComponent("player-scratch", isDirectory: true)
    }

    /// Deletes every orphaned player scratch artifact, off the main thread.
    ///
    /// This used to run inline in `OrivioTVApp.init`, and it is not just a
    /// directory removal: a spent `hybrid-cache` holds a multi-gigabyte file,
    /// and a killed session leaves thousands of remux dirs and network spool
    /// files behind. Tens of thousands of unlinks on an A8 is seconds of
    /// blocked launch in front of the first frame. It is our own scratch space
    /// and a cold launch cannot own a session yet, so the work goes to a utility
    /// queue — with a timestamp cutoff, so files a session creates while the
    /// sweep is still running are left alone.
    static func sweep() {
        // Anything created after this instant belongs to a session that started
        // while the sweep was still walking the tree; the sweep must not unlink
        // it (it used to delete the whole directory, which a fast Play could
        // hit head-on).
        let launchedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.removeItem(at: directory)
            // Remux dirs, CFNetwork spools and the hybrid cache file itself.
            PlayerTempSweep.sweep(olderThan: launchedAt)
            let tmp = fm.temporaryDirectory
            if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
                for u in items where u.lastPathComponent.hasPrefix("orivio-") { try? fm.removeItem(at: u) }
            }
        }
    }
}
