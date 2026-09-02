import Foundation

/// One-time carry-over for the Nuvio → Orivio rename.
///
/// Every persisted key used to be namespaced `nuvio.*` and the on-disk caches
/// were named `nuvio-*`. The rename moved all of them to `orivio.*` / `orivio-*`,
/// which on an existing install would otherwise read as a factory reset: no
/// add-ons, no library, no profiles, no watch progress, no Trakt/debrid
/// credentials, no settings.
///
/// This runs once, before any store is constructed, and COPIES the old values
/// forward. The originals are deliberately left in place so that downgrading to
/// a pre-rename build still finds its data.
///
/// NOTE FOR FUTURE SWEEPS: the `nuvio` literals below are load-bearing legacy
/// identifiers. They must never be renamed.
enum OrivioRenameMigration {
    private static let doneKey = "orivio.migration.renameFromNuvio.v1"
    private static let legacyPrefix = "nuvio."
    private static let currentPrefix = "orivio."

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        migrateDefaults(defaults)
        migrateCaches()
        defaults.set(true, forKey: doneKey)
        NSLog("[OrivioMigration] Nuvio→Orivio carry-over complete")
    }

    /// Copy every `nuvio.*` default to its `orivio.*` name. Existing values at
    /// the new name always win (a newer build may already have written there).
    private static func migrateDefaults(_ defaults: UserDefaults) {
        var moved = 0
        var reclaimed = 0
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(legacyPrefix) {
            let newKey = currentPrefix + key.dropFirst(legacyPrefix.count)
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
                moved += 1
            }
            // Small settings keys stay behind so a downgrade still finds them.
            // BIG ones cannot: this domain has already hit CFPreferences'
            // TOO_MUCH_DATA abort at around a megabyte (see CollectionsStore),
            // and keeping a second copy of the collections blob — ~900 KB on a
            // real account — parks the app permanently next to that limit for
            // the sake of a downgrade nobody performs.
            if Self.byteSize(of: value) > 65_536 {
                defaults.removeObject(forKey: key)
                reclaimed += 1
            }
        }
        NSLog("[OrivioMigration] carried over %d preference keys, reclaimed %d oversized legacy ones",
              moved, reclaimed)
    }

    /// Rough encoded size of a defaults value; only large blobs matter here.
    private static func byteSize(of value: Any) -> Int {
        if let data = value as? Data { return data.count }
        if let string = value as? String { return string.utf8.count }
        if let plist = try? PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0
        ) { return plist.count }
        return 0
    }

    /// Rename the disk caches so a warm install keeps its posters and its
    /// home-catalog snapshot instead of re-downloading everything.
    private static func migrateCaches() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let pairs = [("nuvio-images", "orivio-images"),
                     ("nuvio-home-catalogs.json", "orivio-home-catalogs.json")]
        for (old, new) in pairs {
            let from = caches.appendingPathComponent(old)
            let to = caches.appendingPathComponent(new)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
    }
}
