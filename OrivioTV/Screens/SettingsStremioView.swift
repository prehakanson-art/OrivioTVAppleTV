import SwiftUI

/// Full-screen QR page for Stremio Link. Menu/Back cancels (handled by presenter).
struct StremioConnectPage: View {
    @EnvironmentObject private var theme: ThemeManager
    let code: StremioLinkCode
    let status: String

    var body: some View {
        VStack(spacing: OrivioSpacing.xl) {
            VStack(spacing: OrivioSpacing.sm) {
                Text("Connect Stremio")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Scan the code with your phone, or open \(code.link) and sign in to your Stremio account.")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            // The QR encodes the Stremio Link URL; opening it authorizes this code.
            QRCodeView(string: code.link, side: 360)

            Text(code.code)
                .font(.system(size: 64, weight: .heavy, design: .monospaced))
                .tracking(10)
                .foregroundStyle(theme.palette.secondary)

            HStack(spacing: OrivioSpacing.sm) {
                ProgressView().tint(theme.palette.secondary)
                Text(status)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textTertiary)
            }

            Text("Press Menu to cancel")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .padding(OrivioSpacing.huge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
