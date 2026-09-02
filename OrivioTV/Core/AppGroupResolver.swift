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
        typealias CreateSelf = @convention(c) (CFAllocator?) -> AnyObject?
        typealias CopyValue = @convention(c)
            (AnyObject?, CFString, UnsafeMutableRawPointer?) -> AnyObject?

        guard let handle = dlopen(nil, RTLD_NOW),
              let createSym = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(handle, "SecTaskCopyValueForEntitlement")
        else { return fallback }

        let create = unsafeBitCast(createSym, to: CreateSelf.self)
        let copyValue = unsafeBitCast(copySym, to: CopyValue.self)

        guard let task = create(nil),
              let value = copyValue(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String],
              let first = groups.first
        else { return fallback }
        return first
    }()

    /// The shared container for the resolved group, or nil when app groups
    /// aren't available (a signer that stripped the entitlement) — every Top
    /// Shelf path treats nil as "no shelf", never a failure.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
