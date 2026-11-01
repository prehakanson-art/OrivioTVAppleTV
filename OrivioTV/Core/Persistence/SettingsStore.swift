import Foundation
import Combine

/// A settings struct with defaults. Stored JSON is merged over the encoded
/// defaults, so adding/removing fields never loses the rest of a user's
/// settings (lenient forward/backward decoding without hand-written inits).
protocol SettingsModel: Codable, Equatable {
    init()
}

enum LenientSettings {
    static func decode<T: SettingsModel>(_ type: T.Type, from data: Data) -> T {
        guard let baseData = try? JSONEncoder.orivio.encode(T()),
              var base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any]
        else { return T() }
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return T() }
        for (k, v) in stored {
            if let existing = base[k], !sameKind(existing, v) { continue }
            base[k] = v
        }
        if let merged = try? JSONSerialization.data(withJSONObject: base),
           let value = try? JSONDecoder.orivio.decode(T.self, from: merged) {
            return value
        }
        // A nested value failed to decode — fall back key by key.
        var result = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] ?? [:]
        for (k, v) in stored {
            var trial = result
            trial[k] = v
            if let d = try? JSONSerialization.data(withJSONObject: trial),
               (try? JSONDecoder.orivio.decode(T.self, from: d)) != nil {
                result = trial
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: result),
           let value = try? JSONDecoder.orivio.decode(T.self, from: d) {
            return value
        }
        return T()
    }

    private static func sameKind(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNumber, is NSNumber), (is String, is String), (is [Any], is [Any]),
             (is [String: Any], is [String: Any]), (is NSNull, _), (_, is NSNull): return true
        default: return false
        }
    }
}

/// The profile currently driving every per-profile store.
enum ProfileScope {
    static var current: Int = {
        let v = Persistence.integer(forKey: Persistence.key("profiles.active"))
        return v == 0 ? 1 : v
    }()
}

/// Every per-profile store reloads itself when the active profile changes.
@MainActor
protocol ProfileScoped: AnyObject {
    func reloadForActiveProfile()
}

enum SettingsScope {
    case device
    case profile
}

/// A persisted settings value. Writes are debounced; `onUserChange` lets the
/// sync engine mark the matching store dirty.
@MainActor
class SettingsStore<T: SettingsModel>: ObservableObject, ProfileScoped {
    @Published var value: T {
        didSet {
            guard value != oldValue, !isLoading else { return }
            scheduleSave()
            onUserChange?()
        }
    }

    let baseKey: String
    let scope: SettingsScope
    var onUserChange: (() -> Void)?
    private var isLoading = false
    private var saveWork: DispatchWorkItem?

    init(baseKey: String, scope: SettingsScope) {
        self.baseKey = baseKey
        self.scope = scope
        self.value = T()
        self.value = Self.read(baseKey: baseKey, scope: scope)
    }

    private static func read(baseKey: String, scope: SettingsScope) -> T {
        let key: String
        switch scope {
        case .device: key = Persistence.key(baseKey)
        case .profile:
            let scoped = Persistence.key(baseKey, profile: ProfileScope.current)
            key = (Persistence.hasValue(key: scoped) || ProfileScope.current != 1) ? scoped : Persistence.key(baseKey)
        }
        guard let raw = Persistence.rawData(forKey: key) else { return T() }
        return LenientSettings.decode(T.self, from: raw)
    }

    var storageKey: String {
        switch scope {
        case .device: return Persistence.key(baseKey)
        case .profile: return Persistence.key(baseKey, profile: ProfileScope.current)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        // Capture the key and value: a profile switch in the 0.4 s window must
        // still write the old value to the old profile, not the new one.
        let key = storageKey
        let snapshot = value
        let work = DispatchWorkItem { Persistence.saveInBackground(snapshot, key: key) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        Persistence.save(value, key: storageKey)
    }

    /// Replace the value without firing `onUserChange` (used by sync pulls).
    func applyRemote(_ newValue: T) {
        isLoading = true
        value = newValue
        isLoading = false
        saveNow()
    }

    func reloadForActiveProfile() {
        guard scope == .profile else { return }
        isLoading = true
        value = Self.read(baseKey: baseKey, scope: scope)
        isLoading = false
    }

    func update(_ mutate: (inout T) -> Void) {
        var copy = value
        mutate(&copy)
        value = copy
    }
}
