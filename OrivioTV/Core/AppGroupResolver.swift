import Foundation

/// The application-group id this binary is ACTUALLY entitled to, read from the
/// live code-signing entitlements at runtime.
///
/// Why not a constant: sideload / re-signing tools (and the user's own Xcode
/// signing) rewrite the app group to one registered under THEIR team — the
/// `.entitlements` template value is replaced at sign time. A hardcoded id
/// then never resolves a container and the Top Shelf silently gets no data.
/// Reading the entitlement means the app and the extension both use whatever
/// group the signer assigned, as long as it assigned them the SAME one (which
/// it must for the shared container to work at all).
///
/// The `SecTask` entitlement APIs aren't in tvOS's public Security module, so
/// both functions are resolved via dlsym and `SecTask` is treated as an
/// opaque pointer. If either symbol is missing the resolver falls back to the
/// template id rather than failing.
enum AppGroupResolver {
    /// Matches the `.entitlements` templates; only used if the runtime read
    /// fails (it shouldn't).
    static let fallback = "group.com.innerapns.pubtest.CYCSPZ5MTR"

    static let identifier: String = {
        if let live = liveEntitlementGroup() { return live }
        // The private-API read can fail (a future tvOS, or a re-signer whose
        // signature the dlsym path can't see). The sideloader's assigned group
        // is ALSO baked into the embedded provisioning profile, which needs no
        // private API to read — so use that before giving up on the template.
        if let fromProfile = provisioningProfileGroup() { return fromProfile }
        return fallback
    }()

    /// The group from the LIVE code signature (private `SecTask` API, via
    /// dlsym because it isn't in tvOS's public Security module).
    private static func liveEntitlementGroup() -> String? {
        typealias CreateSelf = @convention(c) (CFAllocator?) -> AnyObject?
        typealias CopyValue = @convention(c)
            (AnyObject?, CFString, UnsafeMutableRawPointer?) -> AnyObject?

        guard let handle = dlopen(nil, RTLD_NOW),
              let createSym = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement")
        else { return nil }

        let create = unsafeBitCast(createSym, to: CreateSelf.self)
        let copyValue = unsafeBitCast(copySym, to: CopyValue.self)

        guard let task = create(nil),
              let value = copyValue(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String],
              let first = groups.first
        else { return nil }
        return first
    }

    /// The group from the embedded provisioning profile.
    ///
    /// A sideloader (Sideloadly/AltStore) re-signs with the viewer's own Apple
    /// ID and writes its assigned group into `embedded.mobileprovision`; this
    /// reads that directly, so a re-signed install resolves the SAME group on
    /// both sides even when the live-entitlement read fails. The profile is a
    /// CMS blob wrapping an XML plist, so the plist is sliced out and parsed.
    ///
    /// The profile lives at the APP bundle root; inside the extension
    /// (`…/App.app/PlugIns/X.appex`) that is two levels up — the same host
    /// lookup `ownerBundleID` uses.
    private static func provisioningProfileGroup() -> String? {
        let main = Bundle.main
        let appBundle: URL
        if main.bundleURL.pathExtension == "appex" {
            appBundle = main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            appBundle = main.bundleURL
        }
        let profileURL = appBundle.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL),
              let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8),
                                     in: xmlStart.lowerBound ..< data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: xmlStart.lowerBound ..< xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization
                .propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              let first = groups.first, !first.isEmpty
        else { return nil }
        return first
    }

    /// The shared container for the resolved group, or nil when app groups
    /// aren't available (a signer that stripped the entitlement) — every Top
    /// Shelf path treats nil as "no shelf", never a failure.
    ///
    /// Memoized (`static let`, resolved once) because this was a computed
    /// property: with the app-group entitlement deliberately off (Top Shelf
    /// disabled in project.yml) EVERY progress persist paid an XPC round trip
    /// to containerURL(forSecurityApplicationGroupIdentifier:) and logged an
    /// error, for a result that can never change during the process's life.
    static let containerURL: URL? =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)

    /// A file BOTH sides can actually write inside the shared container.
    ///
    /// On tvOS the group container's ROOT is not writable — the system creates
    /// `Library/Caches` and `Library/Preferences` inside it and nothing else
    /// may be created alongside them. The Top Shelf snapshot used to be
    /// written straight to the root, where the write failed every time (it was
    /// a `try?`, so silently) and the shelf could never have any content, no
    /// matter how the entitlements were signed. Caches is the documented place
    /// for this on tvOS: the system may purge it, and the app rewrites the
    /// snapshot on every launch and every progress save.
    ///
    /// Namespaced by the OWNING app's bundle id: the release group is a TEAM
    /// group that every sideload signed by that team shares, so with fixed
    /// file names install B's shelf rendered install A's Continue Watching
    /// (and deep-linked into A, under A's PIN gate rather than B's).
    static func sharedFile(_ name: String) -> URL? {
        guard let container = containerURL else { return nil }
        let dir = container
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(ownerBundleID, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(name)
    }

    /// The app that owns this process's slice of the group: the app itself,
    /// or — inside the Top Shelf extension (`…/App.app/PlugIns/X.appex`) —
    /// the host app two levels up, whose id the extension cannot otherwise
    /// know (its own id is not what the app registered).
    static let ownerBundleID: String = {
        let main = Bundle.main
        if main.bundleURL.pathExtension == "appex" {
            let host = main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let id = Bundle(url: host)?.bundleIdentifier, !id.isEmpty { return id }
        }
        return main.bundleIdentifier ?? "orivio"
    }()
}
