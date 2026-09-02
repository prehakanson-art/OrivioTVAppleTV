import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Generates a crisp QR code image for a string via CoreImage.
enum QRCode {
    static func image(from string: String, scale: CGFloat = 12) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// SwiftUI wrapper that renders a QR code for the given string.
struct QRCodeView: View {
    let string: String
    var side: CGFloat = 320

    var body: some View {
        Group {
            if let image = QRCode.image(from: string) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: OrivioRadius.md)
                    .fill(.white.opacity(0.1))
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.4))
                    )
            }
        }
        .frame(width: side, height: side)
        .padding(OrivioSpacing.md)
        .background(.white, in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
    }
}
