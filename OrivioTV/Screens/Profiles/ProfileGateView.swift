import SwiftUI

/// "Who's watching?" — the full-screen picker. 220 pt avatars in a centred row,
/// a lock glyph on PIN profiles, a dashed "+ Add Profile" circle.
struct ProfileGateView: View {
    var cancellable: Bool
    var editMode = false
    let onChosen: (Int) -> Void
    var onCancel: (() -> Void)? = nil
    var onEdit: ((Profile) -> Void)? = nil

    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var progress: ProgressStore
    @State private var pinFor: Profile?
    @State private var drift = false
    @FocusState private var focused: Int?

    var body: some View {
        ZStack {
            driftingField
            VStack(spacing: 70) {
                Text(editMode ? "Manage Profiles" : "Who's watching?").textStyle(.pageTitle)
                    .padding(.top, 180)
                HStack(spacing: 64) {
                    ForEach(profiles.profiles) { p in
                        Button {
                            if editMode { onEdit?(p) } else { choose(p) }
                        } label: {
                            VStack(spacing: 22) {
                                AvatarView(profile: p, size: 220)
                                    .overlay(alignment: .bottomTrailing) {
                                        if editMode {
                                            Image(systemName: "pencil.circle.fill").font(.system(size: 54))
                                                .symbolRenderingMode(.palette).foregroundStyle(Palette.focusInk, .white)
                                        } else if p.pinEnabled {
                                            Image(systemName: "lock.circle.fill").font(.system(size: 50))
                                                .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                    }
                                Text(p.name).font(.system(size: 26, weight: .semibold))
                            }
                        }
                        .buttonStyle(AvatarButtonStyle(selected: false, ring: 5, scale: 1.12))
                        .focused($focused, equals: p.id)
                    }
                    Button {
                        let p = profiles.add(name: "")
                        if editMode { onEdit?(p) }
                    } label: {
                        VStack(spacing: 22) {
                            Image(systemName: "plus").font(.system(size: 70, weight: .light))
                                .frame(width: 220, height: 220)
                                .background(Circle().strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12, 10])).foregroundStyle(.white.opacity(0.6)))
                            Text("Add Profile").font(.system(size: 26, weight: .semibold))
                        }
                    }
                    .buttonStyle(AvatarButtonStyle(selected: false, ring: 0, scale: 1.12))
                    .focused($focused, equals: -1)
                }
                Spacer()
            }
        }
        .onAppear {
            focused = profiles.activeID
            drift = true
        }
        .onExitCommand { if cancellable { onCancel?() } }
        .fullScreenCover(item: $pinFor) { p in
            PinPadView(title: "Enter PIN for \(p.name)") { pin in
                guard profiles.verifyPIN(pin, for: p.id) else { return false }
                pinFor = nil
                onChosen(p.id)
                return true
            } onCancel: { pinFor = nil }
        }
    }

    private func choose(_ p: Profile) {
        if p.pinEnabled { pinFor = p } else { onChosen(p.id) }
    }

    /// A slow drifting art field made from recent Continue Watching art.
    private var driftingField: some View {
        let art = progress.inProgress.prefix(4).compactMap { $0.background ?? $0.poster }
        return ZStack {
            // Always oversized: at scale 1.0 the ±40 pt drift uncovered a 40 pt
            // strip at the left edge (a grey bar at launch, back every cycle).
            // 1.08 overhangs each side by ~77 pt, more than the drift.
            ArtField(imageURL: art.first)
                .scaleEffect(drift ? 1.15 : 1.08)
                .offset(x: drift ? -40 : 40)
                .animation(PerformanceProfile.reduceMotion || PerformanceProfile.isConstrained
                           ? nil : .easeInOut(duration: 24).repeatForever(autoreverses: true), value: drift)
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
    }
}

/// Glass PIN pad: 4 dots and a numeric keypad grid.
struct PinPadView: View {
    let title: String
    /// Returns true when the PIN is accepted.
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void
    @State private var digits = ""
    @State private var shake = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 40) {
                Text(title).font(.system(size: 40, weight: .bold))
                HStack(spacing: 26) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i < digits.count ? Color.white : Color.white.opacity(0.2))
                            .frame(width: 26, height: 26)
                    }
                }
                .offset(x: shake ? -16 : 0)
                .animation(shake ? .default.repeatCount(3, autoreverses: true).speed(4) : .default, value: shake)
                VStack(spacing: 18) {
                    ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                        HStack(spacing: 18) { ForEach(row, id: \.self) { key(String($0)) } }
                    }
                    HStack(spacing: 18) {
                        Color.clear.frame(width: 110, height: 90)
                        key("0")
                        Button { if !digits.isEmpty { digits.removeLast() } } label: {
                            Image(systemName: "delete.left").frame(width: 110, height: 90)
                        }
                        .buttonStyle(GlassCardStyle(radius: 24))
                    }
                }
                Text("Press Menu to cancel").textStyle(.caption)
            }
            .padding(60)
            .glassCard(radius: Metrics.popoverRadius, dark: true)
        }
        .onExitCommand(perform: onCancel)
    }

    private func key(_ d: String) -> some View {
        Button {
            guard digits.count < 4 else { return }
            digits += d
            if digits.count == 4 {
                if !onSubmit(digits) {
                    shake = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shake = false; digits = "" }
                }
            }
        } label: {
            Text(d).font(.system(size: 40, weight: .semibold)).frame(width: 110, height: 90)
        }
        .buttonStyle(GlassCardStyle(radius: 24))
    }
}
