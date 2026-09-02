import SwiftUI

/// Metadata sheet shown while paused, modeled on Orivio's pause overlay:
/// left-heavy gradient, "You're watching" header, logo or title, episode
/// info, description, cast chips and a clock in the top-right corner.
struct PauseOverlayView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            gradients

            PauseClock()
                .padding(.top, 50)
                .padding(.trailing, OrivioSpacing.huge)

            VStack(alignment: .leading, spacing: OrivioSpacing.md) {
                Spacer()

                Text("YOU'RE WATCHING")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.textTertiary)
                    .kerning(2)

                if let logo = viewModel.meta.logo {
                    RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading)
                        .frame(width: 440, height: 120)
                } else {
                    Text(viewModel.meta.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                if let year = viewModel.meta.year {
                    let episodeSuffix = viewModel.currentVideo?.seasonEpisodeCode
                    Text([year, episodeSuffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                if let episodeTitle = viewModel.currentVideo?.title {
                    Text(episodeTitle)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                if let description = viewModel.currentVideo?.overview ?? viewModel.meta.description {
                    Text(description)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 950, alignment: .leading)
                        .padding(.top, OrivioSpacing.xs)
                }

                if let cast = viewModel.meta.cast, !cast.isEmpty {
                    Text("CAST")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.palette.textTertiary)
                        .kerning(2)
                        .padding(.top, OrivioSpacing.lg)

                    HStack(spacing: OrivioSpacing.md) {
                        ForEach(cast.prefix(6), id: \.self) { member in
                            Text(member)
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, OrivioSpacing.lg)
                                .padding(.vertical, OrivioSpacing.sm)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: OrivioRadius.md, style: .continuous))
                        }
                    }
                }
            }
            .padding(.horizontal, OrivioSpacing.huge)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private var gradients: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.88), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            Color.black.opacity(0.34)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.3),
                    .init(color: .black.opacity(0.2), location: 0.6),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct PauseClock: View {
    @State private var now = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now, style: .time)
            .font(.system(size: 40, weight: .regular))
            .foregroundStyle(.white.opacity(0.95))
            .onReceive(timer) { now = $0 }
    }
}
