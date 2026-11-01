import Foundation

/// Resolves the App Group container shared between the app and the Top Shelf
/// extension. The group is read from the *live* signing (the embedded
/// provisioning profile), so a re-signing tool that swaps in its own group still
/// works. If a signer strips the entitlement, `containerURL` is nil and the
/// shelf simply stays empty.
enum AppGroup {
    static let fallbackIdentifier = "group.com.innerapns.pubtest.CYCSPZ5MTR"

    static let identifier: String? = {
        if let fromProfile = groupsFromEmbeddedProfile().first { return fromProfile }
        return fallbackIdentifier
    }()

    static var containerURL: URL? {
        guard let id = identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// The bundle id of the *app* that owns this install (the extension strips
    /// its `.topshelf` suffix). Files in the group are namespaced by it so two
    /// sideloads sharing a group never read each other's snapshot.
    static var owningBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? "orivio"
        if id.hasSuffix(".topshelf") { return String(id.dropLast(".topshelf".count)) }
        return id
    }

    /// Reads `com.apple.security.application-groups` from the embedded
    /// provisioning profile. The profile is a CMS envelope around a plain XML
    /// plist, so the plist can be cut out by its markers.
    private static func groupsFromEmbeddedProfile() -> [String] {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            candidates.append(url)
        }
        // From inside an appex, the app's profile is two levels up.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(appURL.appendingPathComponent("embedded.mobileprovision"))
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
            else { continue }
            let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
            guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let ents = plist["Entitlements"] as? [String: Any],
                  let groups = ents["com.apple.security.application-groups"] as? [String]
            else { continue }
            return groups.filter { !$0.contains("*") }
        }
        return []
    }
}
