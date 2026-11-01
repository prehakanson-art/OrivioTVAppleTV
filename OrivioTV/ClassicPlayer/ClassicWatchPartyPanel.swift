import SwiftUI

/// Watch Party, reached from the player's pull-down (Info → Options).
///
/// The panel is deliberately a plain sheet inside the info panel rather than a
/// `fullScreenCover`: the player's Menu handling already owns Back, and a
/// nested presentation on tvOS tends to leave the remote focused on a view
/// that is no longer on screen. Closing sets `viewModel.watchPartyPanelOpen`
/// back to false, which `handleExit()` also does, so Menu always steps out of
/// the party and only then out of the info sheet.
struct WatchPartyPanel: View {
    @ObservedObject var viewModel: ClassicPlayerViewModel
    @ObservedObject private var service = WatchPartyService.shared
    @FocusState private var focus: String?
    @State private var code = ""
    @State private var joining = false

    private static let codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header
                if let party = service.party {
                    activeParty(party)
                } else {
                    lobby
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 52)
        }
        .onAppear {
            WatchPartyService.shared.player = viewModel
            Task { await service.refreshAvailability() }
            landFocus(service.party == nil ? "start" : (service.party?.isHost == true ? "end" : "leave"))
        }
        .onChange(of: service.party?.id) { _, id in
            if id == nil {
                joining = false
                code = ""
                landFocus("start")
            } else {
                landFocus(service.party?.isHost == true ? "end" : "leave")
            }
        }
        .onChange(of: service.errorText) { _, text in
            if text != nil { landFocus(joining ? "submit" : "start") }
        }
        .onExitCommand { close() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Watch Party")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                Text(service.party == nil
                     ? "Start a party or join one with a six-character code."
                     : "Everyone follows the same playhead.")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                close()
            } label: {
                PartyButtonLabel(title: "Close", systemImage: "xmark")
            }
            .buttonStyle(PlainCardButtonStyle())
            .focused($focus, equals: "close")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = service.errorText, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(Color(hex: 0xFFB4A2))
            } else if let notice = service.notice, !notice.isEmpty {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.65))
            }
            if !service.isSignedIn {
                Text("Watch Party needs an Orivio account. Sign in from Settings → Account.")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: Lobby

    private var lobby: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    startParty()
                } label: {
                    PartyButtonLabel(title: "Start a Watch Party",
                                     subtitle: "You host. Friends join with the code.",
                                     systemImage: "person.2.badge.plus")
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focus, equals: "start")

                Button {
                    joining = true
                    landFocus("code")
                } label: {
                    PartyButtonLabel(title: "Join with a Code",
                                     subtitle: "Enter the six characters from the host.",
                                     systemImage: "number")
                }
                .buttonStyle(PlainCardButtonStyle())
                .focused($focus, equals: "join")
            }
            .frame(width: 560)

            if joining {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PARTY CODE")
                        .font(.system(size: 18, weight: .semibold))
                        .kerning(1.2)
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("ABC 123", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 420, height: 88)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(focus == "code" ? 0.22 : 0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(focus == "code" ? 0.85 : 0.18), lineWidth: 2)
                        )
                        .focused($focus, equals: "code")
                        .onChange(of: code) { _, value in
                            let cleaned = String(value.uppercased()
                                .filter { Self.codeAlphabet.contains($0) }
                                .prefix(6))
                            if cleaned != value { code = cleaned }
                        }
                        .onSubmit { joinParty() }

                    Button {
                        joinParty()
                    } label: {
                        PartyButtonLabel(title: service.busy ? "Joining…" : "Join Party",
                                         systemImage: "arrow.right.circle.fill",
                                         prominent: true)
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .disabled(service.busy || code.count != 6)
                    .opacity(service.busy || code.count != 6 ? 0.45 : 1)
                    .focused($focus, equals: "submit")
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How it works")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    bullet("The host picks the title and gets a code.")
                    bullet("Everyone joins and follows the host's pause and seek.")
                    bullet("Leave at any time; the party keeps going without you.")
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(.white.opacity(0.35)).frame(width: 6, height: 6).padding(.top, 10)
            Text(text).font(.system(size: 20)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Active party

    private func activeParty(_ party: ActiveParty) -> some View {
        HStack(alignment: .top, spacing: 44) {
            VStack(alignment: .leading, spacing: 12) {
                Text("PARTY CODE")
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.5))
                Text(WatchPartyService.format(party.code))
                    .font(.system(size: 58, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Share this code. \(party.members.count)/\(party.maxMembers) watching.")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 10) {
                    Image(systemName: service.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    Text(service.connected ? "Connected" : "Reconnecting…")
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(service.connected ? Color(hex: 0x7EE787) : .orange)
                .padding(.top, 4)

                if let pending = service.pendingMedia {
                    Text("The host is watching \(pending.title)\(pending.episodeTitle.map { " — \($0)" } ?? "").")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .frame(width: 520, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                Text("WATCHING")
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.5))
                Text(party.media.title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let episode = party.media.episodeTitle, !episode.isEmpty {
                    Text(episode)
                        .font(.system(size: 21))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Text("MEMBERS")
                    .font(.system(size: 18, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(party.members) { member in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: member.avatarColor ?? "") ?? .white.opacity(0.2))
                                .frame(width: 34, height: 34)
                                .overlay(Text(member.initials).font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                            Text(member.displayName)
                                .font(.system(size: 21, weight: member.id == party.memberId ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(member.id == party.memberId ? 0.95 : 0.72))
                            if member.id == party.hostMemberId {
                                Text("HOST")
                                    .font(.system(size: 12, weight: .bold))
                                    .kerning(0.8)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(.white.opacity(0.85)))
                            }
                            if member.id == party.memberId {
                                Text("YOU")
                                    .font(.system(size: 12, weight: .bold))
                                    .kerning(0.8)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }

                HStack(spacing: 18) {
                    if party.isHost {
                        Button {
                            service.end()
                        } label: {
                            PartyButtonLabel(title: "End Party", systemImage: "stop.circle")
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focus, equals: "end")
                    } else {
                        Button {
                            service.leave()
                        } label: {
                            PartyButtonLabel(title: "Leave Party", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focus, equals: "leave")
                    }
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private func startParty() {
        guard service.isSignedIn else {
            service.report("Sign in to Orivio to use Watch Party.")
            return
        }
        Task {
            await service.create(media: viewModel.watchPartyMedia,
                                 position: viewModel.watchPartyPosition,
                                 paused: viewModel.watchPartyPaused,
                                 rate: viewModel.watchPartyRate)
        }
    }

    private func joinParty() {
        guard code.count == 6 else { return }
        Task { await service.join(code: code) }
    }

    private func close() {
        viewModel.watchPartyPanelOpen = false
    }

    private func landFocus(_ target: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            focus = target
        }
    }
}

// MARK: - Row label

private struct PartyButtonLabel: View {
    @Environment(\.isFocused) private var isFocused
    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var prominent = false

    var body: some View {
        HStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused || prominent ? .black : .white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle((isFocused || prominent ? Color.black : Color.white).opacity(0.6))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if prominent {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: subtitle == nil ? 62 : 82)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? .white : (prominent ? .white.opacity(0.85) : .white.opacity(0.12)))
        )
        .contentShape(Rectangle())
    }
}
