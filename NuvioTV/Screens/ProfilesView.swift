import SwiftUI
import UIKit

extension Color {
    /// Parses a "#RRGGBB" profile color, falling back to blue.
    init(profileHex: String) {
        var s = profileHex
        if s.hasPrefix("#") { s.removeFirst() }
        self.init(hex: UInt32(s, radix: 16) ?? 0x1E88E5)
    }
}

// MARK: - Avatar

/// A profile's avatar: catalog image if it has one, otherwise a colored circle
/// with the name's initial.
struct ProfileAvatarView: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profile: UserProfile
    var size: CGFloat = 140

    @State private var image: UIImage?

    private var avatarURLString: String? { profiles.avatarURL(for: profile) }

    var body: some View {
        ZStack {
            Circle().fill(Color(profileHex: profile.avatarColorHex))
            if let image {
                // Chosen avatar fully REPLACES the initial (drawn over the
                // colored circle, clipped to it).
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else if avatarURLString == nil {
                // No avatar chosen → colored initial. When an avatar IS chosen
                // but still loading, we deliberately show ONLY the circle (no
                // initial) so the "P" never flashes before the icon.
                initial
            }
        }
        .frame(width: size, height: size)
        .task(id: avatarURLString) { await loadAvatar() }
    }

    /// Cached avatar load (via the shared ImageCache) so a decoded avatar shows
    /// instantly on every re-appearance instead of re-downloading and flashing.
    private func loadAvatar() async {
        guard let urlString = avatarURLString, let url = URL(string: urlString) else {
            image = nil
            return
        }
        if let cached = ImageCache.shared.image(for: urlString) {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !Task.isCancelled,
              let decoded = UIImage(data: data) else { return }
        ImageCache.shared.insert(decoded, for: urlString)
        image = decoded
    }

    private var initial: some View {
        Text(profile.initial)
            .font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(.white)
    }
}

// MARK: - "Who's watching?" gate

struct ProfileGateView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    let onSelected: () -> Void

    @State private var pinProfile: UserProfile?
    // Open with focus on the profile you last used, so the trackpad starts on a
    // sensible tile rather than an arbitrary one.
    @FocusState private var focusedProfile: Int?
    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            // PIN entry is rendered INLINE (not a nested fullScreenCover) so it
            // reliably appears every time a locked profile is entered — the
            // nested cover only presented on the first launch, so later profile
            // switches skipped the PIN.
            if let locked = pinProfile {
                PinEntryView(
                    title: "Enter PIN",
                    subtitle: locked.name,
                    onSubmit: { pin in
                        let outcome = await profiles.verifyPin(id: locked.id, pin: pin)
                        if outcome.unlocked {
                            pinProfile = nil
                            profiles.setActive(locked.id)
                            onSelected()
                            return nil
                        }
                        if outcome.retryAfterSeconds > 0 {
                            return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                        }
                        return outcome.message ?? "Incorrect PIN"
                    },
                    onCancel: { pinProfile = nil }
                )
            } else {
                VStack(spacing: NuvioSpacing.huge) {
                    Text("Who's watching?")
                        .font(.system(size: 58, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)

                    HStack(alignment: .top, spacing: NuvioSpacing.xl) {
                        ForEach(profiles.profiles) { profile in
                            Button { select(profile) } label: {
                                GateTile(title: profile.name, locked: profile.pinEnabled) {
                                    ProfileAvatarView(profile: profile)
                                }
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focusedProfile, equals: profile.id)
                        }
                        if profiles.canAddProfile {
                            Button { addProfile() } label: {
                                GateTile(title: "Add") { DashedCircle(systemName: "plus") }
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                        // Manage Profiles and Nuvio Account moved to Settings → Account.
                    }
                    .defaultFocus($focusedProfile, profiles.active.id)
                }
                .padding(NuvioSpacing.huge)
            }
        }
        // This is the very first screen the app can show — there's nothing to
        // go back to, so Back is a no-op instead of falling through to the
        // system (which would otherwise exit the app).
        .onExitCommand {}
        .task { await profiles.loadAvatarCatalog() }
    }

    private func select(_ profile: UserProfile) {
        if profile.pinEnabled {
            pinProfile = profile
        } else {
            profiles.setActive(profile.id)
            onSelected()
        }
    }

    private func addProfile() {
        if let created = profiles.addProfile(name: "") {
            profiles.setActive(created.id)
            onSelected()
        }
    }
}

/// Avatar + caption tile with a focus ring, used across profile screens.
private struct GateTile<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var locked: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: NuvioSpacing.md) {
            ZStack(alignment: .bottomTrailing) {
                content
                    .overlay(
                        Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 6)
                    )
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(Circle().fill(.black.opacity(0.65)))
                }
            }
            .scaleEffect(isFocused ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)

            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 160)
        }
    }
}

/// A color choice with a clear focus ring (the swatches had none, so you
/// couldn't tell which was selected while moving). White inner ring = current
/// color; accent outer ring + scale = focused.
private struct ColorSwatchLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let hex: String
    let selected: Bool

    var body: some View {
        Circle().fill(Color(profileHex: hex)).frame(width: 52, height: 52)
            .overlay(Circle().strokeBorder(selected ? .white : .clear, lineWidth: 3))
            .overlay(
                Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
                    .padding(-6)
            )
            .scaleEffect(isFocused ? 1.18 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }
}

/// An avatar choice with a focus ring (same problem as the color swatches).
private struct AvatarPickLabel<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .overlay(Circle().strokeBorder(selected ? theme.palette.secondary : .clear, lineWidth: 4))
            .overlay(
                Circle().strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 5)
                    .padding(-6)
            )
            .scaleEffect(isFocused ? 1.1 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
    }
}

private struct DashedCircle: View {
    @EnvironmentObject private var theme: ThemeManager
    let systemName: String
    var body: some View {
        Circle()
            .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [10]))
            .background(Circle().fill(.white.opacity(0.06)))
            .frame(width: 140, height: 140)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            )
    }
}

// MARK: - PIN entry

/// Reusable 4-digit PIN pad. `onSubmit` returns an error string to display, or
/// nil on success.
struct PinEntryView: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    var subtitle: String?
    let onSubmit: (String) async -> String?
    let onCancel: () -> Void

    @State private var digits = ""
    @State private var error: String?
    @State private var busy = false

    private let pinLength = 4

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(spacing: NuvioSpacing.xl) {
                Text(title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                }

                HStack(spacing: NuvioSpacing.lg) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < digits.count ? theme.palette.secondary : .white.opacity(0.2))
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.vertical, NuvioSpacing.md)

                if let error {
                    Text(error)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(NuvioPrimitives.error)
                }

                VStack(spacing: NuvioSpacing.md) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: NuvioSpacing.md) {
                            ForEach(1...3, id: \.self) { col in
                                digitButton("\(row * 3 + col)")
                            }
                        }
                    }
                    HStack(spacing: NuvioSpacing.md) {
                        actionButton(systemName: "delete.left") { if !digits.isEmpty { digits.removeLast() } }
                        digitButton("0")
                        actionButton(systemName: "xmark") { onCancel() }
                    }
                }
                .disabled(busy)
            }
            .padding(NuvioSpacing.huge)
        }
        // Back cancels (same as the on-screen xmark) instead of falling
        // through to the system, which would otherwise exit the app.
        .onExitCommand { onCancel() }
    }

    private func digitButton(_ digit: String) -> some View {
        Button { append(digit) } label: {
            Text(digit)
                .font(.system(size: 40, weight: .semibold))
        }
        .buttonStyle(PinKeyStyle())
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 34, weight: .semibold))
        }
        .buttonStyle(PinKeyStyle())
    }

    private func append(_ digit: String) {
        guard digits.count < pinLength, !busy else { return }
        error = nil
        digits += digit
        if digits.count == pinLength { submit() }
    }

    private func submit() {
        busy = true
        let entered = digits
        Task {
            let result = await onSubmit(entered)
            if let result {
                error = result
                digits = ""
            }
            busy = false
        }
    }
}

private struct PinKeyStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 90, height: 90)
            .background(Circle().fill(isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.12)))
            .foregroundStyle(isFocused ? .black : .white)
            .scaleEffect(isFocused ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }
}

/// PIN prompt shown when selecting a locked profile.
struct PinUnlockView: View {
    @EnvironmentObject private var profiles: ProfileStore
    let profile: UserProfile
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    var body: some View {
        PinEntryView(
            title: "Enter PIN",
            subtitle: profile.name,
            onSubmit: { pin in
                let outcome = await profiles.verifyPin(id: profile.id, pin: pin)
                if outcome.unlocked {
                    onUnlocked()
                    return nil
                }
                if outcome.retryAfterSeconds > 0 {
                    return "Too many attempts. Try again in \(outcome.retryAfterSeconds)s."
                }
                return outcome.message ?? "Incorrect PIN"
            },
            onCancel: onCancel
        )
    }
}

// MARK: - Management

struct ProfileManageView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var addonManager: AddonManager
    let onDone: () -> Void

    @State private var editing: UserProfile?
    // Without an explicit focus binding the tiles' `@Environment(\.isFocused)`
    // ring didn't light up inside this fullScreenCover — the "nothing is
    // highlighted" bug. Driving focus explicitly (like the Who's-watching gate)
    // makes the highlight reliable and lands focus on a tile, not "Done".
    @FocusState private var focusedTile: Int?

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                HStack {
                    Text("Manage Profiles")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Spacer()
                    Button("Done") { onDone() }
                }

                HStack(alignment: .top, spacing: NuvioSpacing.xl) {
                    ForEach(profiles.profiles) { profile in
                        Button { editing = profile } label: {
                            GateTile(title: profile.name, locked: profile.pinEnabled) {
                                ProfileAvatarView(profile: profile, size: 120)
                            }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focusedTile, equals: profile.id)
                    }
                    if profiles.canAddProfile {
                        Button { profiles.addProfile(name: "") } label: {
                            GateTile(title: "Add") { DashedCircle(systemName: "plus") }
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .focused($focusedTile, equals: -1)
                    }
                }
                .focusSection()
                .defaultFocus($focusedTile, profiles.active.id)
                Spacer()
            }
            .padding(NuvioSpacing.huge)
        }
        .onExitCommand { onDone() }
        .task { await profiles.loadAvatarCatalog() }
        .fullScreenCover(item: $editing) { profile in
            ProfileEditView(profile: profile) { editing = nil }
                .environmentObject(theme)
                .environmentObject(profiles)
                .environmentObject(addonManager)
        }
    }
}

struct ProfileEditView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var collections: CollectionsStore
    let profile: UserProfile
    let onDone: () -> Void

    @State private var name = ""
    @State private var showSetPin = false
    @State private var showRemovePin = false
    @State private var pinError: String?
    @State private var confirmingDelete = false
    @State private var editingCollection: NuvioCollection?

    private var current: UserProfile {
        profiles.profiles.first { $0.id == profile.id } ?? profile
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: NuvioSpacing.md), count: 8)

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.xl) {
                    HStack {
                        Text("Edit Profile").font(.system(size: 40, weight: .bold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Spacer()
                        Button("Done") { commitName(); onDone() }
                    }

                    HStack(spacing: NuvioSpacing.lg) {
                        ProfileAvatarView(profile: current, size: 120)
                        TextField("Name", text: $name)
                            .font(.system(size: 28))
                            .padding(.horizontal, NuvioSpacing.lg)
                            .padding(.vertical, NuvioSpacing.md)
                            .background(theme.palette.field, in: RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous))
                            .frame(maxWidth: 560)
                            .onSubmit { commitName() }
                    }

                    sectionLabel("Color")
                    HStack(spacing: NuvioSpacing.md) {
                        ForEach(ProfileStore.avatarColors, id: \.self) { hex in
                            Button { profiles.setColor(id: profile.id, hex: hex) } label: {
                                ColorSwatchLabel(hex: hex, selected: current.avatarColorHex == hex)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                        }
                    }
                    .focusSection()

                    if profiles.avatarCatalog.isEmpty && !profiles.accountAvailable {
                        sectionLabel("Avatar")
                        Text("Sign in to Orivio to choose an avatar image. Colored initials are always available above.")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                    }

                    if !profiles.avatarCatalog.isEmpty {
                        sectionLabel("Avatar")
                        LazyVGrid(columns: columns, spacing: NuvioSpacing.md) {
                            Button { profiles.setAvatar(id: profile.id, avatarID: nil) } label: {
                                AvatarPickLabel(selected: current.avatarID == nil) {
                                    Circle().fill(Color(profileHex: current.avatarColorHex))
                                        .overlay(Text(current.initial).font(.system(size: 30, weight: .heavy)).foregroundStyle(.white))
                                        .frame(width: 96, height: 96)
                                }
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            ForEach(profiles.avatarCatalog) { item in
                                Button { profiles.setAvatar(id: profile.id, avatarID: item.id) } label: {
                                    AvatarPickLabel(selected: current.avatarID == item.id) {
                                        AsyncImage(url: URL(string: item.imageURL)) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: {
                                            Circle().fill(.white.opacity(0.1))
                                        }
                                        .frame(width: 96, height: 96)
                                        .clipShape(Circle())
                                    }
                                }
                                .buttonStyle(PlainCardButtonStyle())
                            }
                        }
                        .focusSection()
                    }

                    sectionLabel("PIN Lock")
                    if let pinError {
                        Text(pinError).font(.system(size: 20)).foregroundStyle(NuvioPrimitives.error)
                    }
                    if profiles.accountAvailable {
                        HStack(spacing: NuvioSpacing.lg) {
                            if current.pinEnabled {
                                // Removing a lock requires proving you know the
                                // PIN — the backend rejects a clear with no
                                // current PIN, so a nil-PIN remove silently failed.
                                Button(role: .destructive) {
                                    showRemovePin = true
                                } label: { Label("Remove PIN", systemImage: "lock.open") }
                            } else {
                                Button { showSetPin = true } label: { Label("Set PIN", systemImage: "lock") }
                            }
                        }
                    } else {
                        Text(current.pinEnabled
                             ? "This profile is PIN-locked. Sign in to Orivio to change or remove the PIN."
                             : "Sign in to Orivio to set a PIN for this profile.")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                    }

                    autoLinkSection

                    collectionsSection

                    if profile.id != 1 {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Profile", systemImage: "trash").font(.system(size: 24, weight: .semibold))
                        }
                        .padding(.top, NuvioSpacing.lg)
                    }
                }
                .padding(NuvioSpacing.huge)
            }
            .scrollClipDisabled()
        }
        .onAppear { name = current.name }
        // Same as pressing Done: commit the pending name edit, then dismiss.
        .onExitCommand { commitName(); onDone() }
        .fullScreenCover(item: $editingCollection) { collection in
            ProfileCollectionFoldersView(collection: collection) { editingCollection = nil }
                .environmentObject(theme)
                .environmentObject(collections)
        }
        .fullScreenCover(isPresented: $showSetPin) {
            PinEntryView(
                title: "Set a 4-digit PIN",
                subtitle: profile.name,
                onSubmit: { pin in
                    let outcome = await profiles.setPin(id: profile.id, pin: pin, currentPin: nil)
                    switch outcome {
                    case .success:
                        showSetPin = false
                        return nil
                    case .currentPinRequired:
                        return "This profile already has a PIN."
                    case .failure(let message):
                        return message
                    }
                },
                onCancel: { showSetPin = false }
            )
            .environmentObject(theme)
            .environmentObject(profiles)
        }
        .fullScreenCover(isPresented: $showRemovePin) {
            PinEntryView(
                title: "Enter current PIN",
                subtitle: "Remove the lock on \(profile.name)",
                onSubmit: { pin in
                    let ok = await profiles.clearPin(id: profile.id, currentPin: pin)
                    if ok { showRemovePin = false; return nil }
                    return "Incorrect PIN, or it couldn't be removed."
                },
                onCancel: { showRemovePin = false }
            )
            .environmentObject(theme)
            .environmentObject(profiles)
        }
        // Deleting also pushes to the Nuvio account (ProfileStore.delete →
        // onLocalChange → profile sync).
        .confirmationDialog(
            "Delete “\(current.name)”?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                profiles.delete(id: profile.id)
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile and its settings from this device and your Orivio account. This can't be undone.")
        }
    }

    // MARK: Auto Link Selector

    /// Write-through binding to one field of this profile's auto-link prefs.
    private func autoBind<T>(_ keyPath: WritableKeyPath<AutoLinkPreferences, T>) -> Binding<T> {
        Binding(
            get: { current.autoLinkPrefs[keyPath: keyPath] },
            set: { newValue in
                var prefs = current.autoLinkPrefs
                prefs[keyPath: keyPath] = newValue
                profiles.setAutoLink(id: profile.id, prefs)
            }
        )
    }

    /// Installed stream addons, as dropdown options (with a leading "Any"/"None").
    private func addonOptions(includeNone: Bool) -> [NuvioDropdownOption] {
        var names: [String] = []
        for addon in addonManager.streamAddons {
            let name = addon.manifest.name
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        let head = NuvioDropdownOption("", includeNone ? "None" : "Any addon")
        return [head] + names.map { NuvioDropdownOption($0) }
    }

    /// Per-profile collection visibility, as a drill-down: pick a collection,
    /// then switch its individual FOLDERS on or off (keep Streaming Services
    /// but drop HBO Max). Folders also have an account-wide default in
    /// Settings → Collections; this only trims further for THIS profile.
    ///
    /// Only meaningful for the ACTIVE profile: the hidden sets are stored per
    /// profile and the store is scoped to whoever is signed in, so editing
    /// another profile's list from here would write to the wrong one.
    @ViewBuilder
    private var collectionsSection: some View {
        if !collections.library.isEmpty {
            VStack(alignment: .leading, spacing: NuvioSpacing.md) {
                Text("Collections")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)

                if profile.id == profiles.activeProfileID {
                    Text("Choose what this profile sees. Open a collection to pick individual folders.")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)

                    ForEach(collections.library) { collection in
                        let globallyOff = !collections.isGloballyVisible(collection.id)
                        Button {
                            guard !globallyOff else { return }
                            editingCollection = collection
                        } label: {
                            ProfileCollectionRow(
                                title: collection.title,
                                detail: folderSummary(collection),
                                shown: collections.isVisible(collection.id),
                                showsChevron: !globallyOff
                            )
                        }
                        .buttonStyle(PlainCardButtonStyle())
                        .disabled(globallyOff)
                        .opacity(globallyOff ? 0.45 : 1)
                    }
                } else {
                    Text("Switch to “\(current.name)” to choose which of the \(collections.library.count) collections it shows.")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .padding(.top, NuvioSpacing.lg)
        }
    }

    /// "3 of 19 folders" — so the row says what's on without opening it.
    private func folderSummary(_ collection: NuvioCollection) -> String {
        guard collections.isGloballyVisible(collection.id) else {
            return "Off for everyone — Settings → Collections"
        }
        guard collections.isVisible(collection.id) else { return "Hidden on this profile" }
        let total = collection.folders.count
        let on = collection.folders.filter { collections.isFolderVisible($0.id) }.count
        return on == total ? "All \(total) folders" : "\(on) of \(total) folders"
    }

    private var autoLinkSection: some View {
        VStack(alignment: .leading, spacing: NuvioSpacing.md) {
            sectionLabel("Auto Link Selector")
            Text("When on, pressing Play resolves and plays the best matching source directly — no source list. Hold Play to pick a source manually.")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: 820, alignment: .leading)

            Toggle("Auto Link Selector", isOn: autoBind(\.enabled))
                .font(.system(size: 24, weight: .medium))
                .tint(theme.palette.secondary)
                .frame(maxWidth: 560)

            if current.autoLinkPrefs.enabled {
                NuvioDropdown(
                    title: "Preferred addon",
                    selection: current.autoLinkPrefs.preferredAddon,
                    options: addonOptions(includeNone: false),
                    onSelect: { autoBind(\.preferredAddon).wrappedValue = $0 }
                )
                NuvioDropdown(
                    title: "Secondary addon",
                    subtitle: "Used when the preferred addon has no match",
                    selection: current.autoLinkPrefs.secondaryAddon,
                    options: addonOptions(includeNone: true),
                    onSelect: { autoBind(\.secondaryAddon).wrappedValue = $0 }
                )
                NuvioDropdown(
                    title: "Minimum quality",
                    selection: current.autoLinkPrefs.minResolution,
                    options: [
                        .init("", "Any"),
                        .init("2160p", "4K (2160p)"),
                        .init("1080p", "1080p"),
                        .init("720p", "720p"),
                        .init("480p", "480p")
                    ],
                    onSelect: { autoBind(\.minResolution).wrappedValue = $0 }
                )
                NuvioDropdown(
                    title: "Maximum size",
                    selection: String(Int(current.autoLinkPrefs.maxSizeGB)),
                    options: [
                        .init("0", "No limit"),
                        .init("5", "5 GB"),
                        .init("10", "10 GB"),
                        .init("20", "20 GB"),
                        .init("40", "40 GB"),
                        .init("60", "60 GB")
                    ],
                    onSelect: { autoBind(\.maxSizeGB).wrappedValue = Double(Int($0) ?? 0) }
                )
                Toggle("Cached sources only", isOn: autoBind(\.cachedOnly))
                    .font(.system(size: 24, weight: .medium))
                    .tint(theme.palette.secondary)
                    .frame(maxWidth: 560)

                Toggle("Avoid Dolby Vision", isOn: autoBind(\.avoidDolbyVision))
                    .font(.system(size: 24, weight: .medium))
                    .tint(theme.palette.secondary)
                    .frame(maxWidth: 560)
                Text("Dolby Vision sources can play with green/purple colors on tvOS. Leave on unless your DV playback works.")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .padding(.top, NuvioSpacing.lg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(theme.palette.textTertiary)
            .kerning(2)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { profiles.rename(id: profile.id, to: trimmed) }
    }
}


/// A row in the profile editor's collection list. Rendered with an explicit
/// FOCUS state — the previous version used a bare checkmark and, on tvOS,
/// focus only moved a system highlight the row didn't respond to, so you
/// couldn't tell what was selected while moving over it.
private struct ProfileCollectionRow: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let detail: String
    let shown: Bool
    var showsChevron = false

    var body: some View {
        HStack(spacing: NuvioSpacing.md) {
            Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 30))
                .foregroundStyle(shown ? theme.palette.focusRing : theme.palette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(isFocused ? theme.palette.textPrimary : theme.palette.textSecondary)
                Text(detail)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .padding(.horizontal, NuvioSpacing.lg)
        .padding(.vertical, NuvioSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .fill(isFocused ? theme.palette.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NuvioRadius.md, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
    }
}

/// Folder picker for ONE collection on the active profile. Mirrors the
/// collection's own folder layout so it reads like the row it controls.
struct ProfileCollectionFoldersView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var collections: CollectionsStore
    let collection: NuvioCollection
    let onDone: () -> Void

    /// Live copy — `collection` is a snapshot taken when the cover opened.
    private var live: NuvioCollection {
        collections.library.first { $0.id == collection.id } ?? collection
    }

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NuvioSpacing.lg) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.title)
                                .font(.system(size: 40, weight: .bold))
                                .foregroundStyle(theme.palette.textPrimary)
                            Text("Choose which folders this profile sees")
                                .font(.system(size: 22))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                        Spacer()
                        Button("Done", action: onDone)
                    }

                    Button {
                        collections.setVisible(!collections.isVisible(live.id), id: live.id)
                    } label: {
                        ProfileCollectionRow(
                            title: "Show this collection",
                            detail: collections.isVisible(live.id)
                                ? "Appears on this profile" : "Hidden on this profile",
                            shown: collections.isVisible(live.id))
                    }
                    .buttonStyle(PlainCardButtonStyle())

                    if collections.isVisible(live.id) {
                        Text("Folders")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                            .padding(.top, NuvioSpacing.md)

                        ForEach(live.folders) { folder in
                            let globallyOff = !collections.isFolderGloballyVisible(folder.id)
                            Button {
                                guard !globallyOff else { return }
                                collections.setFolderVisible(
                                    !collections.isFolderVisible(folder.id), id: folder.id)
                            } label: {
                                ProfileCollectionRow(
                                    title: folder.title,
                                    detail: globallyOff
                                        ? "Off for everyone — Settings → Collections"
                                        : (collections.isFolderVisible(folder.id) ? "Shown" : "Hidden"),
                                    shown: collections.isFolderVisible(folder.id))
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .disabled(globallyOff)
                            .opacity(globallyOff ? 0.45 : 1)
                        }
                    }
                }
                .padding(NuvioSpacing.huge)
            }
            .scrollClipDisabled()
        }
        .onExitCommand(perform: onDone)
    }
}
