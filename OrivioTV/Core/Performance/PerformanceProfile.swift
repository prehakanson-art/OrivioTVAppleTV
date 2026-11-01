import Foundation
import UIKit

/// Device tiers. Every mitigation is gated on **both** low and mid tiers —
/// they once checked only the A8 and never reached the A10X.
enum PerformanceProfile {
    enum Tier: String { case low, mid, high }

    static let modelIdentifier: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }()

    static let arguments: Set<String> = Set(ProcessInfo.processInfo.arguments)

    static let tier: Tier = {
        if arguments.contains("-lowPower") { return .low }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let model = modelIdentifier
        if model.hasPrefix("AppleTV5,") || gb < 2.5 { return .low }
        if model.hasPrefix("AppleTV6,") || gb < 3.5 { return .mid }
        return .high
    }()

    static var isLowPower: Bool { tier == .low }
    static var isMidPower: Bool { tier == .mid }
    /// A8 or A10X — snap overlays, no live blur over video, solid panels.
    static var isConstrained: Bool { tier != .high }
    static var isHighTier: Bool { tier == .high }
    /// 4 GB boxes (gen 2/3) get the decorative extras.
    static var isFourGB: Bool { tier == .high }

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    static var deviceName: String {
        switch modelIdentifier {
        case let m where m.hasPrefix("AppleTV5,"): return "Apple TV HD"
        case let m where m.hasPrefix("AppleTV6,"): return "Apple TV 4K (1st generation)"
        case let m where m.hasPrefix("AppleTV11,"): return "Apple TV 4K (2nd generation)"
        case let m where m.hasPrefix("AppleTV14,"): return "Apple TV 4K (3rd generation)"
        default: return modelIdentifier
        }
    }

    static var isGen3: Bool { modelIdentifier.hasPrefix("AppleTV14,") }

    // MARK: Budgets (low / mid / high)

    static var imageMaxPixels: CGFloat { tier == .low ? 1920 : 3840 }
    /// tvOS draws the interface at 1080p, so a mid-tier backdrop needs no more
    /// than 1920 px wide; 2560 decoded ~40% more pixels for no visible gain.
    static var backdropMaxPixels: CGFloat { tier == .high ? 3840 : 1920 }
    static var imageCacheBytes: Int { [Tier.low: 96, .mid: 160, .high: 256][tier]! << 20 }
    static var imageCacheItems: Int { [Tier.low: 200, .mid: 300, .high: 400][tier]! }
    static var engineReadAheadBytes: Int64 { Int64([Tier.low: 220, .mid: 400, .high: 1000][tier]!) << 20 }
    static var cacheWorkers: Int { [Tier.low: 4, .mid: 6, .high: 8][tier]! }
    static var responseCacheEntries: Int { [Tier.low: 32, .mid: 64, .high: 96][tier]! }
    static var collectionParallelFolders: Int { [Tier.low: 3, .mid: 4, .high: 6][tier]! }
    static var homeFetchConcurrency: Int { [Tier.low: 3, .mid: 4, .high: 6][tier]! }

    /// Whether overlays over live video may fade (else snap).
    static var animatesOverVideo: Bool { !isConstrained && !reduceMotion }
    /// Live blur allowed (else solid fills).
    static var allowsLiveBlur: Bool { !isConstrained }
}
