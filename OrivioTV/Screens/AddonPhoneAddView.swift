import SwiftUI

/// Settings → Add-ons → Add Add-ons: a QR pointing at a small page this Apple
/// TV serves on the local network, so manifest URLs can be pasted from a phone
/// instead of typed on the remote.
///
/// The server runs ONLY while this screen is up (see `onAppear`/`onDisappear`)
/// — it is a tool the viewer opened, not a service left listening.
struct AddonPhoneAddView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var addonManager: AddonManager
    @StateObject private var server = AddonImportServer()
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            VStack(spacing: OrivioSpacing.lg) {
                Text("Add Add-ons")
                    .font(FusionType.pageTitle(theme.font))
                    .foregroundStyle(theme.palette.textPrimary)

                if let address = server.address {
                    Text("Scan with your phone, or open \(address) in its browser. Both devices have to be on the same network.")
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(string: address, side: 360)
                    Text(address)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.secondary)
                } else if let error = server.lastError {
                    Text(error)
                        .font(FusionType.bodyText(theme.font))
                        .foregroundStyle(OrivioPrimitives.red300)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    OrivioLoadingView(label: "Starting")
                        .frame(height: 360)
                }

                if !server.accepted.isEmpty {
                    // Echo what the phone sent so it is obvious it worked
                    // without walking back to the TV to check the list.
                    VStack(spacing: 4) {
                        ForEach(server.accepted.prefix(4), id: \.self) { name in
                            Text("Added \(name)")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(OrivioPrimitives.success)
                        }
                    }
                }

                Button("Done", action: onDone)
                    .padding(.top, OrivioSpacing.sm)
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            server.onInstall = { url in
                do {
                    try await addonManager.install(manifestURL: url)
                    // Name it from what actually installed, so the phone
                    // confirms the real add-on rather than echoing the URL.
                    let name = addonManager.addons.first { $0.manifestURL == url }?.manifest.name
                    return .success(name ?? url)
                } catch {
                    return .failure(error)
                }
            }
            server.start()
        }
        .onDisappear { server.stop() }
        .onExitCommand(perform: onDone)
    }
}
