import UIKit
import AVFoundation
import AVKit

/// HDR / frame-rate matching (§7.6).
/// - The gate is tvOS's own **Match Content** setting; the app has no toggle.
/// - Requested **once per playback**, pinned on both rate and range (a
///   range-blind pin made DV play as HDR10 after any other title).
/// - Released only by the exit sequence, never in a retired session's teardown.
@MainActor
final class DisplayModeManager {
    static let shared = DisplayModeManager()

    enum Range: String {
        case sdr, hlg, hdr10, dolbyVision
        var label: String {
            switch self {
            case .sdr: return "SDR"
            case .hlg: return "HLG"
            case .hdr10: return "HDR10"
            case .dolbyVision: return "Dolby Vision"
            }
        }
    }

    private(set) var pinned: (rate: Double, range: Range)?
    private(set) var isSwitching = false
    var onLog: ((String) -> Void)?

    private var displayManager: AVDisplayManager? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first?.avDisplayManager
    }

    var matchingEnabled: Bool { displayManager?.isDisplayCriteriaMatchingEnabled ?? false }

    var supportsDolbyVision: Bool { AVPlayer.availableHDRModes.contains(.dolbyVision) }
    var supportsHDR10: Bool { AVPlayer.availableHDRModes.contains(.hdr10) }
    var supportsHLG: Bool { AVPlayer.availableHDRModes.contains(.hlg) }

    /// HDR10+ → gen-3 + tvOS 18.4.
    var supportsHDR10Plus: Bool {
        guard PerformanceProfile.isGen3 else { return false }
        if #available(tvOS 18.4, *) { return true }
        return false
    }

    func beginPlayback() {
        pinned = nil
    }

    /// Clamps the range to what the panel supports: DV → HDR10 → HLG → SDR.
    func clamp(_ r: Range) -> Range {
        switch r {
        case .dolbyVision: return supportsDolbyVision ? .dolbyVision : (supportsHDR10 ? .hdr10 : .sdr)
        case .hdr10: return supportsHDR10 ? .hdr10 : .sdr
        case .hlg: return supportsHLG ? .hlg : (supportsHDR10 ? .hdr10 : .sdr)
        case .sdr: return .sdr
        }
    }

    /// Snaps 23.976 vs 24 (and 29.97/30, 59.94/60) at the pair's midpoint.
    static func snap(_ fps: Double) -> Double {
        let pairs: [(Double, Double)] = [(24000.0 / 1001, 24), (25, 25), (30000.0 / 1001, 30), (50, 50), (60000.0 / 1001, 60)]
        for (ntsc, integer) in pairs where abs(fps - ntsc) < 0.6 || abs(fps - integer) < 0.6 {
            if ntsc == integer { return integer }
            return fps < (ntsc + integer) / 2 ? ntsc : integer
        }
        return fps
    }

    /// Returns true when a new request was actually made (the caller may hold
    /// video attach until the panel settles).
    @discardableResult
    func request(frameRate: Double, range: Range) -> Bool {
        guard let dm = displayManager, dm.isDisplayCriteriaMatchingEnabled else {
            onLog?("display: Match Content off — no request")
            return false
        }
        let rate = Self.snap(frameRate > 0 ? frameRate : 24)
        let clamped = clamp(range)
        if let p = pinned, abs(p.rate - rate) < 0.01, p.range == clamped { return false }
        guard pinned == nil else {
            onLog?("display: already pinned \(pinned!.rate)/\(pinned!.range.label) — ignoring \(rate)/\(clamped.label)")
            return false
        }
        guard let fd = Self.formatDescription(for: clamped) else { return false }
        pinned = (rate, clamped)
        dm.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(rate), formatDescription: fd)
        onLog?("display: requested \(String(format: "%.3f", rate)) Hz · \(clamped.label)")
        return true
    }

    /// Waits out a requested mode switch using tvOS's own signal
    /// (`isDisplayModeSwitchInProgress`), then a settling beat for HDMI link
    /// training. Guessing from the refresh rate missed range-only switches
    /// (SDR → Dolby Vision at the same rate, e.g. with Match Frame Rate off):
    /// the picture went in mid-renegotiation and the panel wedged grey.
    /// Returns whether a switch actually happened.
    @discardableResult
    func waitForSwitch(limit: Double = 12, startWithin: Double = 1.5) async -> Bool {
        guard let dm = displayManager else { return false }
        isSwitching = true
        defer { isSwitching = false }
        // tvOS starts the switch a beat after the request (or not at all when
        // nothing needs to change, or Match Content's toggles exclude it).
        var started = dm.isDisplayModeSwitchInProgress
        var waited = 0
        while !started, Double(waited) < startWithin * 10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
            waited += 1
            started = dm.isDisplayModeSwitchInProgress
        }
        guard started else {
            onLog?("display: no mode switch needed")
            return false
        }
        var elapsed = 0
        while dm.isDisplayModeSwitchInProgress, Double(elapsed) < limit * 10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return true }
            elapsed += 1
        }
        onLog?("display: switch finished after \(Double(elapsed + waited) / 10) s")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return true
    }

    /// ⏯ pressed 3× within 2 s: blind re-sync (escape hatch for an HDMI wedge).
    func blindResync() {
        guard let dm = displayManager, let p = pinned, let fd = Self.formatDescription(for: p.range) else { return }
        dm.preferredDisplayCriteria = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dm.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(p.rate), formatDescription: fd)
        }
        onLog?("display: blind re-sync")
    }

    /// The exit sequence's release (menus otherwise stay at 24 Hz). Returns
    /// whether the panel may now be switching back (the caller waits it out).
    @discardableResult
    func releaseForExit() -> Bool {
        let hadMode = pinned != nil
        pinned = nil
        guard let dm = displayManager else { return false }
        dm.preferredDisplayCriteria = nil
        return hadMode && dm.isDisplayCriteriaMatchingEnabled
    }

    static func formatDescription(for range: Range) -> CMFormatDescription? {
        var ext: [String: Any] = [:]
        let codec: CMVideoCodecType
        switch range {
        case .sdr:
            codec = kCMVideoCodecType_H264
            ext[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            ext[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case .hdr10, .hlg, .dolbyVision:
            codec = range == .dolbyVision ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC
            ext[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            ext[kCMFormatDescriptionExtension_TransferFunction as String] = range == .hlg
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            ext[kCMFormatDescriptionExtension_BitsPerComponent as String] = 10
        }
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 3840, height: 2160,
                                       extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        return fd
    }
}
