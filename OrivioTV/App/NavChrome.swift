import SwiftUI

/// A round avatar: image if set, else initials on the profile colour.
struct AvatarView: View {
    let profile: Profile
    var size: CGFloat = 44
    @Environment(\.avatarRing) private var ring
    @ObservedObject private var catalog = AvatarCatalog.shared

    private var imageURL: String? {
        if let u = profile.avatarURL, !u.isEmpty { return u }
        return catalog.url(for: profile.avatarID)
    }

    var body: some View {
        ZStack {
            // The catalog's own backdrop colour behind a picture; the profile colour otherwise.
            if imageURL != nil, let bg = catalog.item(profile.avatarID)?.bgColor.flatMap({ Color(hex: $0) }) {
                Circle().fill(bg)
            } else {
                Circle().fill(profile.color.gradient)
            }
            if let url = imageURL {
                RemoteImage(url: url, maxPixel: ImageSize.avatar, contentMode: .fill, placeholder: false).clipShape(Circle())
            } else {
                Text(profile.initials)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay { if ring > 0 { Circle().strokeBorder(Color.white, lineWidth: ring).padding(-ring - 3) } }
        .allowsHitTesting(false)
        .task(id: profile.avatarID) { if profile.avatarID != nil { await catalog.loadIfNeeded() } }
    }
}

/// The current time, updated each minute.
struct ClockText: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(DateParsing.shortTime.string(from: ctx.date))
                .font(.system(size: 22))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

/// A row in the sidebar/rail panel: 36 pt icon well + 26 pt semibold label.
struct NavItemLabel: View {
    let tab: AppTab
    var showsLabel = true
    @Environment(\.rowFocused) private var focused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(focused ? Color.black.opacity(0.08) : Color.white.opacity(0.12)))
            if showsLabel {
                Text(tab.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
            }
        }
    }
}

/// Mounts the profile card when it opens, and unmounts it a beat after it
/// closes (it fades out in place first so focus can fall back onto the panel).
struct StripMount: ViewModifier {
    let open: Bool
    @Binding var mounted: Bool
    /// Bumped on every change, so a reopen cancels a pending unmount.
    @State private var generation = 0
    func body(content: Content) -> some View {
        content.onChange(of: open) { _, now in
            generation += 1
            if now { mounted = true } else {
                let g = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if generation == g { mounted = false } }
            }
        }
    }
}

/// A nav focus request made while the target is still re-enabling (the panel
/// coming back from behind the profile card) is dropped; keep asking briefly.
enum NavFocusRetry {
    @MainActor
    /// `after`: wait for the target to be visible first — a view still fading
    /// in from opacity 0 can't take focus, and the FocusState keeps the refused
    /// value, so a retry can't tell it failed.
    static func request(_ target: NavFocus, on binding: FocusState<NavFocus?>.Binding,
                        after delay: TimeInterval = 0.05, attempt: Int = 0) {
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? delay : 0.1)) {
            guard binding.wrappedValue != target else { return }
            binding.wrappedValue = target
            request(target, on: binding, attempt: attempt + 1)
        }
    }
}

// MARK: - Profile switcher (the raised card; same component in all three styles)

/// "Switch Profile": a glass pill label over a raised glass card of large
/// avatars (a green check on the active one) and a black "+ Add Profile".
struct ProfileStrip: View {
    @EnvironmentObject private var profiles: ProfileStore
    var navFocus: FocusState<NavFocus?>.Binding
    var onChosen: () -> Void
    @State private var pinFor: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                Text("Switch Profile").font(.system(size: 22, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 6)
            .padding(.trailing, 20)
            .frame(height: 50)
            .glassCapsule()
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 26) {
                ForEach(profiles.profiles) { p in
                    Button { choose(p) } label: {
                        VStack(spacing: 10) {
                            FocusedAvatar(profile: p, size: 128)
                                .overlay(alignment: .topTrailing) {
                                    if p.id == profiles.activeID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 34))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Palette.positive)
                                            .offset(x: 4, y: -4)
                                    } else if p.pinEnabled {
                                        Image(systemName: "lock.circle.fill")
                                            .font(.system(size: 30))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                }
                            Text(p.name).font(.system(size: 21, weight: .semibold)).lineLimit(1).frame(maxWidth: 140)
                        }
                    }
                    .buttonStyle(ProfileAvatarStyle())
                    .focused(navFocus, equals: .profile(p.id))
                }
                Button {
                    let p = profiles.add(name: "")
                    choose(p)
                } label: {
                    VStack(spacing: 10) {
                        FocusLift {
                            Image(systemName: "plus")
                                .font(.system(size: 46, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 128, height: 128)
                                .background(Circle().fill(Color.black.opacity(0.88)))
                        }
                        Text("Add Profile").font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                    }
                }
                .buttonStyle(ProfileAvatarStyle())
                .focused(navFocus, equals: .addProfile)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .background {
                // Raised glass: lighter than the panel, with a hairline edge.
                let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
                NavGlass(shape: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: PerformanceProfile.isConstrained ? 8 : 30,
                            y: PerformanceProfile.isConstrained ? 4 : 16)
            }
            .focusSection()
        }
        .onAppear { navFocus.wrappedValue = .profile(profiles.activeID) }
        .fullScreenCover(item: $pinFor) { p in
            PinPadView(title: "Enter PIN for \(p.name)") { pin in
                if profiles.verifyPIN(pin, for: p.id) {
                    pinFor = nil
                    profiles.switchTo(p.id)
                    onChosen()
                    return true
                }
                return false
            } onCancel: { pinFor = nil }
        }
    }

    private func choose(_ p: Profile) {
        if p.pinEnabled, p.id != profiles.activeID { pinFor = p; return }
        profiles.switchTo(p.id)
        onChosen()
    }
}

/// Profile buttons draw their own focus on the picture only (`FocusLift`).
struct ProfileAvatarStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
    }
}

/// A plain button style: the label draws any focus effect itself.
struct PlainLabelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Lifts its content when the enclosing button is focused (scale, white ring, glow).
struct FocusLift<Content: View>: View {
    var ring = true
    @ViewBuilder let content: () -> Content
    @Environment(\.isFocused) private var focused

    var body: some View {
        content()
            .overlay { if ring && focused { Circle().strokeBorder(Color.white, lineWidth: 3).padding(-5) } }
            .scaleEffect(focused ? 1.12 : 1)
            .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.45 : 0),
                    radius: PerformanceProfile.isConstrained ? 0 : 18,
                    y: PerformanceProfile.isConstrained ? 0 : 10)
            .shadow(color: .white.opacity(focused && !PerformanceProfile.isConstrained ? 0.25 : 0),
                    radius: PerformanceProfile.isConstrained ? 0 : 14)
            .animation(Motion.focus, value: focused)
    }
}

/// An avatar that lifts when its button is focused.
struct FocusedAvatar: View {
    let profile: Profile
    var size: CGFloat = 44
    var body: some View {
        FocusLift { AvatarView(profile: profile, size: size) }
    }
}

/// Avatar focus: scale + white ring.
struct AvatarButtonStyle: ButtonStyle {
    var selected: Bool
    var ring: CGFloat = 4
    var scale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, ring: ring, scale: scale)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let ring: CGFloat
        let scale: CGFloat

        var body: some View {
            configuration.label
                .environment(\.avatarRing, focused ? ring : (selected ? 2 : 0))
                .scaleEffect(focused ? scale : 1)
                .shadow(color: .white.opacity(focused && !PerformanceProfile.isConstrained ? 0.25 : 0),
                        radius: PerformanceProfile.isConstrained ? 0 : 18)
                .foregroundStyle(.white)
                .animation(Motion.focus, value: focused)
        }
    }
}

private struct AvatarRingKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// Ring width drawn around an `AvatarView` (set by `AvatarButtonStyle`).
    var avatarRing: CGFloat {
        get { self[AvatarRingKey.self] }
        set { self[AvatarRingKey.self] = newValue }
    }
}

// MARK: - A. Apple TV sidebar panel

/// The floating glass panel: x 40 / y 40, 340 wide, radius 40. Focused rows
/// are a near-white rounded rectangle; the current tab a light glass one.
/// Selecting the header morphs the panel into the raised profile card.
struct SidebarPanel: View {
    let tabs: [AppTab]
    let current: AppTab
    var navFocus: FocusState<NavFocus?>.Binding
    @Binding var profileStripOpen: Bool
    let select: (AppTab) -> Void
    let close: () -> Void
    @EnvironmentObject private var profiles: ProfileStore
    @State private var stripMounted = false

    var body: some View {
        // Both stay mounted and swap by opacity: removing the card while it held
        // focus threw focus out onto the page.
        ZStack(alignment: .topLeading) {
            panel
                .opacity(profileStripOpen ? 0.011 : 1)
                .scaleEffect(profileStripOpen ? 0.96 : 1, anchor: .topLeading)
                .disabled(profileStripOpen)
            if stripMounted {
                ProfileStrip(navFocus: navFocus) {
                    withAnimation(Motion.popover) { profileStripOpen = false }
                    NavFocusRetry.request(.tab(current), on: navFocus, after: 0.15)
                }
                .opacity(profileStripOpen ? 1 : 0)
                .disabled(!profileStripOpen)
                .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .modifier(StripMount(open: profileStripOpen, mounted: $stripMounted))
        .animation(Motion.popover, value: profileStripOpen)
        .onExitCommand {
            if profileStripOpen {
                withAnimation(Motion.popover) { profileStripOpen = false }
                NavFocusRetry.request(.profileHeader, on: navFocus, after: 0.15)
            } else {
                close()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.popover) { profileStripOpen = true }
            } label: { SidebarHeaderLabel(profile: profiles.active) }
                .buttonStyle(PlainLabelStyle())
                .focused(navFocus, equals: .profileHeader)
                .padding(.bottom, 22)
            ForEach(tabs) { tab in
                Button { select(tab) } label: { SidebarItemLabel(tab: tab) }
                    .buttonStyle(SidebarRowStyle(selected: tab == current))
                    .focused(navFocus, equals: .tab(tab))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { SidebarGlass() }
    }
}

/// The nav chrome's glass. Plain Liquid Glass reads almost clear on a real TV
/// over bright art, so a dark base sits over the blur (and stands in for it
/// on boxes without live blur), with the TV app's soft multi-colour tint.
struct NavGlass<S: InsettableShape>: View {
    let shape: S
    var tinted = true

    var body: some View {
        ZStack {
            if PerformanceProfile.allowsLiveBlur {
                if #available(tvOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.regularMaterial)
                }
                shape.fill(Palette.navBase.opacity(0.62))
            } else {
                shape.fill(Palette.navBase.opacity(0.94))
            }
            if tinted {
                shape.fill(LinearGradient(
                    stops: [.init(color: Color.hex("#7A86B8").opacity(0.22), location: 0),
                            .init(color: Color.hex("#6FA7B5").opacity(0.16), location: 0.45),
                            .init(color: Color.hex("#C9B98A").opacity(0.10), location: 0.62),
                            .init(color: Color.hex("#4F8FD6").opacity(0.24), location: 1)],
                    startPoint: .top, endPoint: .bottom))
            }
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: PerformanceProfile.isConstrained ? 10 : 30, x: 8, y: 0)
        .allowsHitTesting(false)
    }
}

/// The side panel's (sidebar and rail) glass: a dark base (over the system blur
/// where the box can afford it) with the TV app's soft multi-colour tint. Mostly
/// opaque, open or closed, so the tabs read over bright art.
struct SidebarGlass<S: InsettableShape>: View {
    var shape: S

    var body: some View {
        ZStack {
            if PerformanceProfile.allowsLiveBlur {
                GlassSurface(shape: shape)
                shape.fill(Palette.navBase.opacity(0.9))
            } else {
                shape.fill(Palette.navBase.opacity(0.97))
            }
            shape.fill(LinearGradient(
                stops: [.init(color: Color.hex("#7A86B8").opacity(0.20), location: 0),
                        .init(color: Color.hex("#6FA7B5").opacity(0.14), location: 0.45),
                        .init(color: Color.hex("#C9B98A").opacity(0.08), location: 0.62),
                        .init(color: Color.hex("#4F8FD6").opacity(0.20), location: 1)],
                startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: PerformanceProfile.isConstrained ? 10 : 30, x: 8, y: 0)
        .allowsHitTesting(false)
    }
}

extension SidebarGlass where S == RoundedRectangle {
    init() { self.init(shape: RoundedRectangle(cornerRadius: 40, style: .continuous)) }
}

/// Avatar · name · clock. Focused: the clock gives way to "Switch Profile" under the name.
struct SidebarHeaderLabel: View {
    let profile: Profile
    @Environment(\.isFocused) private var focused

    var body: some View {
        // Focus lifts only the picture (as in the TV app); the row gets no fill.
        HStack(spacing: 14) {
            FocusedAvatar(profile: profile, size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                if focused {
                    Text("Switch Profile").font(.system(size: 18, weight: .medium)).opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 6)
            if !focused { ClockText() }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
        .animation(Motion.focus, value: focused)
    }
}

/// 34 pt icon circle + 23 pt semibold label.
struct SidebarItemLabel: View {
    let tab: AppTab
    @Environment(\.rowFocused) private var focused

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(focused ? 0.78 : 0.42)))
            Text(tab.title).font(.system(size: 23, weight: .semibold)).lineLimit(1)
        }
    }
}

/// Sidebar rows: rounded rectangle (radius 16). Focused = near-white fill,
/// dark ink, a slight lift; current tab = light glass.
struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    var height: CGFloat = 58

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, height: height)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let height: CGFloat

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white.opacity(0.92))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                    if focused {
                        shape.fill(Color.white.opacity(0.9))
                            .shadow(color: .black.opacity(PerformanceProfile.isConstrained ? 0 : 0.25),
                                    radius: PerformanceProfile.isConstrained ? 0 : 14, y: 6)
                    } else if selected {
                        shape.fill(Color.white.opacity(0.22))
                    }
                }
                .scaleEffect(focused ? (configuration.isPressed ? 1.0 : 1.04) : 1)
                .animation(Motion.focus, value: focused)
                .environment(\.rowFocused, focused)
        }
    }
}

// MARK: - B. Side rail

/// One set of buttons that only changes shape: a capsule of icons, expanding
/// into the sidebar panel when focus enters. The buttons are never swapped
/// for others — replacing the view that holds focus left the remote stuck
/// on a rail that never expanded.
struct SideRail: View {
    let tabs: [AppTab]
    let expanded: Bool
    @Binding var profileStripOpen: Bool
    var navFocus: FocusState<NavFocus?>.Binding
    let suppressed: Bool
    @ObservedObject var gate: NavGate
    /// Auto-hide: closed and not on its way open — invisible and unfocusable.
    var hidden = false
    let select: (AppTab) -> Void
    let close: () -> Void
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var profiles: ProfileStore
    @State private var stripMounted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(expanded ? 0.3 : 0).ignoresSafeArea().allowsHitTesting(false)
            // 0.011, not 0, under the card: still a focus target the moment the
            // card closes (fully transparent views can't take focus mid-fade).
            column
                .opacity(profileStripOpen ? 0.011 : (hidden ? 0 : 1))
                .disabled(profileStripOpen || suppressed || hidden || gate.held || gate.blocked)
            // Inserted fresh on open (focus moves in on appear); on close it fades
            // out in place first, so focus falls back onto the rail, not the page.
            if stripMounted {
                ProfileStrip(navFocus: navFocus) {
                    withAnimation(Motion.popover) { profileStripOpen = false }
                    NavFocusRetry.request(.tab(router.tab), on: navFocus, after: 0.15)
                }
                .padding(40)
                .opacity(profileStripOpen ? 1 : 0)
                .disabled(!profileStripOpen)
                .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(Motion.sidebar, value: expanded)
        .animation(Motion.sidebar, value: hidden)
        .animation(Motion.popover, value: profileStripOpen)
        .modifier(StripMount(open: profileStripOpen, mounted: $stripMounted))
        .onExitCommand {
            if profileStripOpen {
                withAnimation(Motion.popover) { profileStripOpen = false }
                NavFocusRetry.request(.profileHeader, on: navFocus, after: 0.15)
            } else {
                close()
            }
        }
    }

    static let rowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 8
    private var tabsHeight: CGFloat {
        CGFloat(tabs.count) * Self.rowHeight + CGFloat(max(0, tabs.count - 1)) * Self.rowSpacing
    }
    private var width: CGFloat { expanded ? 340 : 84 }

    /// The tabs never move: they stay centred at the same spot, and the panel
    /// grows around them — wider for the labels, full height with the profile
    /// at its top.
    private var column: some View {
        ZStack(alignment: .topLeading) {
            SidebarGlass(shape: RoundedRectangle(cornerRadius: expanded ? 40 : 42, style: .continuous))
                .frame(width: width, height: expanded ? 1000 : tabsHeight + 28)
                .frame(maxHeight: .infinity)
            Button {
                withAnimation(Motion.popover) { profileStripOpen = true }
            } label: { SidebarHeaderLabel(profile: profiles.active) }
                .buttonStyle(PlainLabelStyle())
                .focused(navFocus, equals: .profileHeader)
                .frame(width: 316, alignment: .leading)
                .padding(.leading, 12)
                .padding(.top, 54)
                .opacity(expanded ? 1 : 0)
                .disabled(!expanded)
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(tabs) { tab in
                    Button { select(tab) } label: { RailRowLabel(tab: tab, expanded: expanded) }
                        .buttonStyle(RailRowStyle(selected: tab == router.tab, expanded: expanded))
                        .focused(navFocus, equals: .tab(tab))
                }
            }
            .padding(.horizontal, 12)
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, 28)
        .focusSection()
        // Entering the rail lands on the current tab, never the nearest icon.
        .defaultFocus(navFocus, .tab(router.tab), priority: .userInitiated)
    }
}

/// A rail row: the icon alone (collapsed) or icon + label (expanded).
struct RailRowLabel: View {
    let tab: AppTab
    let expanded: Bool
    @Environment(\.rowFocused) private var focused

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tab.systemImage)
                .font(.system(size: expanded ? 15 : 18, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(expanded ? (focused ? 0.78 : 0.42) : 0)))
            if expanded {
                Text(tab.title).font(.system(size: 23, weight: .semibold)).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
        }
    }
}

/// Collapsed: a 60 pt circle (the current tab raised). Expanded: the sidebar row.
struct RailRowStyle: ButtonStyle {
    var selected: Bool
    var expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected, expanded: expanded)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool
        let expanded: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: expanded ? 16 : 30, style: .continuous)
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white.opacity(expanded || selected ? 0.92 : 0.8))
                .padding(.horizontal, 13)
                .frame(maxWidth: expanded ? .infinity : 60, minHeight: SideRail.rowHeight, maxHeight: SideRail.rowHeight, alignment: .leading)
                .background {
                    if focused {
                        shape.fill(Color.white.opacity(0.9))
                            .shadow(color: .black.opacity(PerformanceProfile.isConstrained ? 0 : 0.25),
                                    radius: PerformanceProfile.isConstrained ? 0 : 14, y: 6)
                    } else if selected {
                        shape.fill(Color.white.opacity(0.22))
                    }
                }
                .scaleEffect(focused ? (configuration.isPressed ? 1.0 : 1.04) : 1)
                .animation(Motion.focus, value: focused)
                .environment(\.rowFocused, focused)
        }
    }
}

// MARK: - C. Top bar

struct TopBar: View {
    let tabs: [AppTab]
    var navFocus: FocusState<NavFocus?>.Binding
    @Binding var profileStripOpen: Bool
    let select: (AppTab) -> Void
    let close: () -> Void
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var topBarVisibility: TopBarVisibility

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    Button { select(tab) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.systemImage).font(.system(size: 20, weight: .semibold))
                            Text(tab.title).font(.system(size: 26, weight: .semibold))
                        }
                    }
                    .buttonStyle(GlassTabStyle(selected: tab == router.tab))
                    .focused(navFocus, equals: .tab(tab))
                }
                Spacer().frame(width: 20)
                ClockText()
                Button { withAnimation(Motion.popover) { profileStripOpen.toggle() } } label: {
                    AvatarView(profile: profiles.active, size: 48)
                }
                .buttonStyle(AvatarButtonStyle(selected: false, scale: 1.12))
                .focused(navFocus, equals: .profileHeader)
            }
            .padding(.horizontal, 12)
            .frame(height: 68)
            .background { NavGlass(shape: Capsule(), tinted: false) }
            if profileStripOpen {
                ProfileStrip(navFocus: navFocus) { closeStrip(then: .tab(router.tab)) }
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 36)
        .opacity(router.tab == .home && !topBarVisibility.visible && navFocus.wrappedValue == nil ? 0 : 1)
        .animation(Motion.popover, value: topBarVisibility.visible)
        .onExitCommand {
            if profileStripOpen { closeStrip(then: .profileHeader) } else { close() }
        }
    }

    /// Focus goes back into the bar first; the card leaves once it has (a card
    /// removed while holding focus throws focus onto the page).
    private func closeStrip(then target: NavFocus) {
        NavFocusRetry.request(target, on: navFocus)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(Motion.popover) { profileStripOpen = false }
        }
    }
}

/// Home tells the top bar to fade once focus moves below the first row.
@MainActor
final class TopBarVisibility: ObservableObject {
    /// Publishes only on a real change (Home sets it on every focus move).
    private var _visible = true
    var visible: Bool {
        get { _visible }
        set { guard newValue != _visible else { return }; objectWillChange.send(); _visible = newValue }
    }
}

struct GlassTabStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected)
    }

    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : .white)
                .padding(.horizontal, 22)
                .frame(height: 52)
                .background(Capsule().fill(focused ? Palette.focusFill : (selected ? Palette.glassRaised : .clear)))
                .scaleEffect(focused ? 1.05 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}
