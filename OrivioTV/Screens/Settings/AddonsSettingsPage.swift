import SwiftUI

/// §16.12 Add-ons page: install / health on top, installed add-ons as rows
/// (logo, name, version, On/Off); hold → Move Up / Move Down / Remove / Configure.
struct AddonsSettingsPage: View {
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    @State private var health: [String: String] = [:]
    @State private var checking = false
    @State private var installURL = ""
    @State private var confirm: ConfirmAction?
    @State private var configure: InstalledAddon?
    @State private var fromPhone = false
    @State private var exporting = false
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsGroup(footer: addons.lastError) {
            TextEntryRow(label: "Install from URL", text: Binding(get: { "" }, set: { url in
                guard !url.isEmpty else { return }
                Task {
                    switch await addons.install(url) {
                    case .success(let a): ToastCenter.shared.show("Installed \(a.displayName)")
                    case .failure(let e): ToastCenter.shared.show(e.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    }
                }
            }), placeholder: "https://…/manifest.json", footer: "Paste an add-on's manifest URL (stremio:// links work too).", keyboard: .URL)
            SettingsRow(label: "Add from Phone", detail: "Scan a code and paste manifest URLs on your phone", icon: "iphone") { fromPhone = true }
            if !addons.addons.isEmpty {
                SettingsRow(label: "Export Add-on Setup", detail: "Every manifest URL, to move to another device", icon: "square.and.arrow.up") { exporting = true }
            }
            SettingsRow(label: "Add-on Health", value: checking ? "Checking…" : (health.isEmpty ? nil : "Done"), chevron: false) { checkHealth() }
        }
        if addons.addons.isEmpty {
            Text("No add-ons yet. Install one by URL to get catalogs and sources.").textStyle(.body, color: Palette.textSecondary)
        } else {
            SettingsGroup(header: "Installed", footer: "Hold a row to move, configure or remove it.") {
                ForEach(addons.addons) { a in
                    row(a)
                }
            }
        }
        Color.clear.frame(height: 1)
            .fullScreenCover(isPresented: $fromPhone) {
                PhoneInputSheet(title: "Add Add-ons", prompt: "Paste one or more add-on manifest URLs (one per line).", multiline: true) { text in
                    Task {
                        let n = await addons.importURLs(text)
                        ToastCenter.shared.show(n == 0 ? "No new add-ons found" : "Installed \(n) add-on\(n == 1 ? "" : "s")")
                    }
                } onDone: { fromPhone = false }
            }
            .fullScreenCover(isPresented: $exporting) {
                PhoneInputSheet(title: "Export Add-on Setup", prompt: "Your add-on URLs, one per line. Paste them into Add from Phone on another Apple TV.",
                                exportFilename: "orivio-addons.txt", exportText: addons.exportText) { exporting = false }
            }
            .confirmation($confirm)
            .fullScreenCover(item: $configure) { a in
                SignInSheet(title: "Configure \(a.displayName)", url: a.baseURL + "/configure", code: nil,
                            status: "Configure on your phone, then reinstall with the new URL") { configure = nil }
            }
    }

    private func row(_ a: InstalledAddon) -> some View {
        Button { addons.setEnabled(a, !a.enabled) } label: {
            HStack(spacing: 20) {
                RemoteImage(url: a.manifest.logo, maxPixel: 120, contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.displayName).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                    Text(health[a.id] ?? "Version \(a.manifest.version)").font(.system(size: 20)).opacity(0.6).lineLimit(1)
                }
                Spacer()
                Text(a.enabled ? "On" : "Off").font(.system(size: 26))
                    .foregroundStyle(a.enabled ? (theme.isSystemWhite ? Color.primary : theme.accent) : Palette.textSecondary)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(SettingsRowStyle())
        .contextMenu {
            Button { addons.move(a, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
            Button { addons.move(a, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            if a.manifest.behaviorHints?.configurable == true {
                Button { configure = a } label: { Label("Configure", systemImage: "slider.horizontal.3") }
            }
            Button(role: .destructive) {
                confirm = ConfirmAction(title: "Remove \(a.displayName)?", message: "Its catalogs and sources disappear from this profile.",
                                        button: "Remove") { addons.remove(a) }
            } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func checkHealth() {
        guard !checking else { return }
        checking = true
        Task {
            let results = await addons.measureHealth()
            health = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.label) })
            checking = false
        }
    }
}

// MARK: - Profiles

struct ManageProfilesPage: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsGroup {
            ForEach(profiles.profiles) { p in
                Button { nav.push(p.name) { EditProfilePage(profileID: p.id) } } label: {
                    HStack(spacing: 20) {
                        AvatarView(profile: p, size: 48).frame(width: 48, height: 48)
                        Text(p.name).font(.system(size: 26, weight: .semibold))
                        if p.pinEnabled { Image(systemName: "lock.fill").font(.system(size: 18)).opacity(0.6) }
                        Spacer()
                        if p.id == profiles.activeID { Text("Current").font(.system(size: 22)).opacity(0.6) }
                        Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.5)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(SettingsRowStyle())
            }
        }
        if profiles.profiles.count < ProfileStore.maxProfiles {
            SettingsGroup {
                SettingsRow(label: "Add Profile", icon: "plus") {
                    let used = Set(profiles.profiles.map(\.avatarColorHex))
                    let color = Profile.palette.first { !used.contains($0) } ?? Profile.palette[0]
                    let p = profiles.add(name: "Profile \(profiles.profiles.count + 1)", colorHex: color)
                    nav.push(p.name) { EditProfilePage(profileID: p.id) }
                }
            }
        }
    }
}

struct EditProfilePage: View {
    let profileID: Int
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var addons: AddonManager
    @EnvironmentObject private var nav: SettingsNav
    @State private var pinStep: PinStep?
    @State private var confirm: ConfirmAction?

    enum PinStep: Identifiable { case set, confirm(String); var id: String { if case .confirm(let p) = self { return "c\(p)" }; return "s" } }

    private var profile: Profile? { profiles.profile(profileID) }

    private func edit(_ f: (inout Profile) -> Void) {
        guard var p = profile else { return }
        f(&p)
        profiles.update(p)
    }

    var body: some View {
        if let p = profile {
            SettingsGroup {
                TextEntryRow(label: "Name", text: Binding(get: { p.name }, set: { v in if !v.isEmpty { edit { $0.name = v } } }))
                PickerRow(label: "Color", options: Profile.palette, selection: Binding(get: { p.avatarColorHex }, set: { v in edit { $0.avatarColorHex = v } }),
                          title: { Self.colorName($0) }, swatch: { Color.hex($0) })
                SettingsRow(label: "Avatar", value: AvatarCatalog.shared.item(p.avatarID)?.name.nonEmpty ?? (p.avatarID == nil ? "Initials" : "Picture"),
                            chevron: true) {
                    nav.push("Avatar") { AvatarPickerPage(profileID: p.id) }
                }
                if p.id != 1 {
                    ToggleRow(label: "Use the primary profile's add-ons", isOn: Binding(get: { p.usesPrimaryAddons }, set: { v in edit { $0.usesPrimaryAddons = v } }))
                }
            }
            SettingsGroup(header: "Lock", footer: "A 4-digit PIN is asked for when switching to this profile.") {
                if p.pinEnabled {
                    SettingsRow(label: "Change PIN") { pinStep = .set }
                    SettingsRow(label: "Remove PIN") { profiles.setPIN(nil, for: p.id) }
                } else {
                    SettingsRow(label: "Set PIN", icon: "lock") { pinStep = .set }
                }
            }
            if !collections.library.isEmpty {
                SettingsGroup {
                    let hidden = collections.library.filter { p.hiddenCollections.contains($0.id) }.count
                    SettingsRow(label: "Collections", value: hidden == 0 ? "All shown" : "\(hidden) hidden", chevron: true) {
                        nav.push("Collections") { ProfileCollectionsPage(profileID: profileID) }
                    }
                }
            }
            SettingsGroup(header: "Auto Link", footer: "Plays the best matching source automatically for this profile, bounded by these add-ons.") {
                ToggleRow(label: "Auto Link", isOn: Binding(get: { p.autoLink.enabled }, set: { v in edit { $0.autoLink.enabled = v } }))
                if p.autoLink.enabled {
                    let names: [String?] = [nil] + addons.enabled.map(\.displayName)
                    PickerRow(label: "Preferred add-on", options: names, selection: Binding(get: { p.autoLink.preferredAddon },
                              set: { v in edit { $0.autoLink.preferredAddon = v } })) { $0 ?? "Any" }
                    PickerRow(label: "Secondary add-on", options: names, selection: Binding(get: { p.autoLink.secondaryAddon },
                              set: { v in edit { $0.autoLink.secondaryAddon = v } })) { $0 ?? "None" }
                    PickerRow(label: "Minimum quality", options: [nil, "720p", "1080p", "2160p"], selection: Binding(get: { p.autoLink.minimumQuality },
                              set: { v in edit { $0.autoLink.minimumQuality = v } })) { $0 ?? "Any" }
                    PickerRow(label: "Maximum size", options: [nil, 5, 10, 20, 40, 60] as [Double?], selection: Binding(get: { p.autoLink.maximumSizeGB },
                              set: { v in edit { $0.autoLink.maximumSizeGB = v } })) { $0.map { "\(Int($0)) GB" } ?? "Any" }
                    ToggleRow(label: "Cached only", isOn: Binding(get: { p.autoLink.cachedOnly }, set: { v in edit { $0.autoLink.cachedOnly = v } }))
                    ToggleRow(label: "Avoid Dolby Vision", isOn: Binding(get: { p.autoLink.avoidDolbyVision }, set: { v in edit { $0.autoLink.avoidDolbyVision = v } }))
                }
            }
            if p.id != 1 {
                SettingsGroup {
                    SettingsRow(label: "Delete Profile", destructive: true) {
                        confirm = ConfirmAction(title: "Delete \(p.name)?", message: "Its library, progress and settings on this Apple TV are removed.",
                                                button: "Delete") {
                            profiles.delete(p.id)
                            nav.pop()
                        }
                    }
                }
            }
            Color.clear.frame(height: 1)
                .confirmation($confirm)
                .fullScreenCover(item: $pinStep) { step in
                    switch step {
                    case .set:
                        PinPadView(title: "Enter a new PIN") { pin in
                            DispatchQueue.main.async { pinStep = .confirm(pin) }
                            return true
                        } onCancel: { pinStep = nil }
                    case .confirm(let first):
                        PinPadView(title: "Enter it again") { pin in
                            guard pin == first else { return false }
                            profiles.setPIN(pin, for: profileID)
                            DispatchQueue.main.async { pinStep = nil }
                            return true
                        } onCancel: { pinStep = nil }
                    }
                }
        }
    }

    static func colorName(_ hex: String) -> String {
        let names = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Indigo", "Purple", "Pink", "Grey"]
        return Profile.palette.firstIndex(of: hex).map { names[$0] } ?? hex
    }
}

/// Which collections and folders this profile sees (Edit Profile → Collections).
struct ProfileCollectionsPage: View {
    let profileID: Int
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore

    var body: some View {
        if let p = profiles.profile(profileID) {
            ForEach(collections.library) { c in
                SettingsGroup(header: c.title) {
                    ToggleRow(label: "Show collection", isOn: Binding(get: { !p.hiddenCollections.contains(c.id) }, set: { on in
                        edit { $0.hiddenCollections = toggled($0.hiddenCollections, c.id, hide: !on) }
                    }))
                    if !p.hiddenCollections.contains(c.id) {
                        ForEach(c.folders) { f in
                            ToggleRow(label: f.title, isOn: Binding(get: { !p.hiddenFolders.contains(f.id) }, set: { on in
                                edit { $0.hiddenFolders = toggled($0.hiddenFolders, f.id, hide: !on) }
                            }))
                        }
                    }
                }
            }
        }
    }

    private func edit(_ f: (inout Profile) -> Void) {
        guard var p = profiles.profile(profileID) else { return }
        f(&p)
        profiles.update(p)
    }

    private func toggled(_ list: [String], _ id: String, hide: Bool) -> [String] {
        hide ? (list.contains(id) ? list : list + [id]) : list.filter { $0 != id }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Edit Profile → Avatar: the account's avatar catalog, by category, plus
/// "Initials" (no picture). Needs Orivio account sign-in, like the old app.
struct AvatarPickerPage: View {
    let profileID: Int
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var nav: SettingsNav
    @ObservedObject private var catalog = AvatarCatalog.shared
    @ObservedObject private var account = OrivioAccount.shared

    private var groups: [(String, [AvatarCatalog.Item])] {
        var order: [String] = []
        var by: [String: [AvatarCatalog.Item]] = [:]
        for i in catalog.items {
            if by[i.category] == nil { order.append(i.category) }
            by[i.category, default: []].append(i)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        if let p = profiles.profile(profileID) {
            VStack(alignment: .leading, spacing: 30) {
                if !account.isSignedIn {
                    Text("Sign in to your Orivio account to use avatar pictures.").textStyle(.body, color: Palette.textSecondary)
                } else if catalog.items.isEmpty {
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(catalog.loading ? "Loading avatars…" : "No avatars available.").textStyle(.body, color: Palette.textSecondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(130), spacing: 26), count: 6), alignment: .leading, spacing: 30) {
                    choice(p, id: nil, title: "Initials")
                    if !groups.isEmpty, groups.count == 1 {
                        ForEach(groups[0].1) { choice(p, id: $0.id, title: $0.name) }
                    }
                }
                if groups.count > 1 {
                    ForEach(groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(g.0.capitalized).textStyle(.eyebrow)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(130), spacing: 26), count: 6), alignment: .leading, spacing: 30) {
                                ForEach(g.1) { choice(p, id: $0.id, title: $0.name) }
                            }
                        }
                    }
                }
            }
            .task { await catalog.loadIfNeeded() }
        }
    }

    private func choice(_ p: Profile, id: String?, title: String) -> some View {
        var preview = p
        preview.avatarID = id
        preview.avatarURL = nil
        return Button {
            var updated = p
            updated.avatarID = id
            updated.avatarURL = nil
            profiles.update(updated)
            nav.pop()
        } label: {
            VStack(spacing: 10) {
                FocusLift { AvatarView(profile: preview, size: 110) }
                    .overlay(alignment: .topTrailing) {
                        if p.avatarID == id && (id != nil || p.avatarURL == nil) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.positive)
                        }
                    }
                Text(title).font(.system(size: 18, weight: .semibold)).lineLimit(1).frame(width: 130)
            }
        }
        .buttonStyle(ProfileAvatarStyle())
    }
}
