import Foundation
import libdovi

/// Dolby Vision RPU conversion via libdovi (quietvoid/dovi_tool's dolby_vision
/// crate, cross-compiled to a tvOS static lib — see Vendor/libdovi.xcframework).
///
/// Used by the DV remux path to turn Profile 7 (dual-layer, MEL/FEL) Dolby
/// Vision into Profile 8.1 (single-layer): the base-layer HEVC is kept as-is,
/// the enhancement layer is discarded, and each RPU NAL is converted 7→8.1 so
/// Apple's video pipeline accepts it as native DV (the same 8.x path profile
/// 5/8 already uses). Without this, DV7 files only ever tone-map to HDR10.
enum DoviConverter {
    /// Convert one Dolby Vision RPU NAL unit (HEVC NAL type 62 / UNSPEC62)
    /// from Profile 7 to Profile 8.1.
    ///
    /// `nal` must be the NAL unit WITHOUT an Annex-B start code or length
    /// prefix — i.e. starting at the 2-byte NAL header (`0x7C 0x01 …`), the
    /// form libdovi's `dovi_parse_unspec62_nalu` accepts. Emulation-prevention
    /// bytes may be present (libdovi strips them). Returns the converted NAL,
    /// again starting at the `0x7C` NAL header (with emulation prevention
    /// re-inserted), ready to length-prefix or start-code and re-mux. Returns
    /// nil if the NAL isn't a parseable DV RPU or the conversion fails — the
    /// caller then keeps the original NAL.
    static func convertRPU7to81(_ nal: Data) -> Data? {
        nal.withUnsafeBytes { raw -> Data? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            guard let rpu = dovi_parse_unspec62_nalu(base, nal.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            // A non-null error string means the parse failed.
            if dovi_rpu_get_error(rpu) != nil { return nil }

            // mode 2 == ConversionMode::To81.
            guard dovi_convert_rpu_with_mode(rpu, 2) == 0 else { return nil }

            guard let out = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(out) }
            guard let bytes = out.pointee.data, out.pointee.len > 0 else { return nil }
            return Data(bytes: bytes, count: out.pointee.len)
        }
    }
}
