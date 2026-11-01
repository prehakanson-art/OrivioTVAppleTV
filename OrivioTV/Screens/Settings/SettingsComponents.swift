import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Right-pane navigation

/// The right pane's page stack (pickers, sub-pages). Back pops it.
@MainActor
final class SettingsNav: ObservableObject {
    struct Page: Identifiable {
        let id = UUID()
        let title: String
        let content: () -> AnyView
    }

    @Published private(set) var stack: [Page] = []
    let registry = PaneRowRegistry()
    /// Bumped when focus should return to the pane's first row.
    @Published var focusToken = 0

    func push<V: View>(_ title: String, @ViewBuilder _ content: @escaping () -> V) {
        registry.resetClaims()
        stack.append(Page(title: title) { AnyView(content()) })
        focusToken += 1
    }

    func pop() {
        guard !stack.isEmpty else { return }
        registry.resetClaims()
        stack.removeLast()
        focusToken += 1
    }

    func reset() {
        registry.resetClaims()
        stack = []
    }
}

// MARK: - Pane focus

/// Rows register in appearance order per page so the pane can focus its first
/// row (entering from the categories) or the row a sub-page was opened from.
@MainActor
final class PaneRowRegistry {
    private var order: [String: [String]] = [:]
    var lastFocused: [String: String] = [:]

    private var claimed: [String: Int] = [:]

    /// A unique id for a row on a page ("API key" can appear twice).
    func claim(_ id: String, page: String) -> String {
        let k = page + "\u{1}" + id
        let n = claimed[k, default: 0]
        claimed[k] = n + 1
        let r = n == 0 ? id : "\(id)#\(n + 1)"
        // Claims happen as bodies are built — top to bottom — unlike onAppear.
        register(r, page: page)
        return r
    }

    func register(_ id: String, page: String) {
        if !(order[page] ?? []).contains(id) { order[page, default: []].append(id) }
    }

    func first(page: String) -> String? { order[page]?.first }
    func target(page: String) -> String? { lastFocused[page] ?? first(page: page) }
    /// Pages are rebuilt on every push/pop; ids restart so they come out the same.
    func resetClaims() {
        claimed = [:]
        order = [:]
    }

    func forget(page: String) {
        order[page] = nil
        lastFocused[page] = nil
        claimed = claimed.filter { !$0.key.hasPrefix(page + "\u{1}") }
    }
}

private struct PaneFocusKey: EnvironmentKey { static let defaultValue: FocusState<String?>.Binding? = nil }
private struct PaneRegistryKey: EnvironmentKey { static let defaultValue: PaneRowRegistry? = nil }
private struct PaneKeyKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    var settingsPaneFocus: FocusState<String?>.Binding? {
        get { self[PaneFocusKey.self] }
        set { self[PaneFocusKey.self] = newValue }
    }
    var settingsPaneRegistry: PaneRowRegistry? {
        get { self[PaneRegistryKey.self] }
        set { self[PaneRegistryKey.self] = newValue }
    }
    var settingsPageKey: String {
        get { self[PaneKeyKey.self] }
        set { self[PaneKeyKey.self] = newValue }
    }
}

/// Makes a pane row addressable for focus (first row / return-to-row).
struct PaneRow: ViewModifier {
    let id: String
    @Environment(\.settingsPaneFocus) private var focus
    @Environment(\.settingsPaneRegistry) private var registry
    @Environment(\.settingsPageKey) private var page

    @State private var box = IDBox()

    final class IDBox { var id: String? }

    func body(content: Content) -> some View {
        if let focus, let registry {
            let resolved = box.id ?? {
                let r = registry.claim(id, page: page)
                box.id = r
                return r
            }()
            content
                .focused(focus, equals: resolved)
        } else {
            content
        }
    }
}

extension View {
    func paneRow(_ id: String) -> some View { modifier(PaneRow(id: id)) }
}

// MARK: - Grouped glass list

/// An inset-grouped glass list: eyebrow header, 72 pt rows with hairline
/// separators inset 24 pt, optional footer text.
struct SettingsGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header {
                Text(header).eyebrow().padding(.leading, 24)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(SeparatedLayout()) { content() }
            }
            .padding(8)
            .background { GlassSurface(shape: RoundedRectangle(cornerRadius: Metrics.glassCardRadius, style: .continuous)) }
            if let footer {
                Text(footer).textStyle(.cardBody, color: Palette.textTertiary)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Puts a hairline between children.
private struct SeparatedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 24)
            }
        }
    }
}

/// Settings row chrome: white rounded fill when focused, label left, value right.
struct SettingsRowStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, destructive: destructive) }
    private struct Chrome: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let destructive: Bool
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Palette.focusInk : (destructive ? Palette.destructive : .white))
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(focused ? Palette.focusFill : .clear)
                }
                .scaleEffect(focused ? 1.015 : 1)
                .shadow(color: .black.opacity(focused && !PerformanceProfile.isConstrained ? 0.25 : 0),
                        radius: PerformanceProfile.isConstrained ? 0 : 12,
                        y: PerformanceProfile.isConstrained ? 0 : 6)
                .animation(Motion.focus, value: focused)
                .environment(\.rowFocused, focused)
        }
    }
}

/// A row: label, optional detail line, value, chevron when it opens something.
struct SettingsRow: View {
    let label: String
    var detail: String? = nil
    var value: String? = nil
    var valueColor: Color? = nil
    var chevron = false
    var icon: String? = nil
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowLabel(label: label, detail: detail, value: value, valueColor: valueColor, chevron: chevron, icon: icon)
        }
        .buttonStyle(SettingsRowStyle(destructive: destructive))
        .paneRow(label + (detail ?? ""))
    }
}

private struct RowLabel: View {
    let label: String
    let detail: String?
    let value: String?
    let valueColor: Color?
    let chevron: Bool
    let icon: String?
    @Environment(\.rowFocused) private var focused

    var body: some View {
        HStack(spacing: 18) {
            if let icon {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 20)).opacity(0.6).lineLimit(2)
                }
            }
            Spacer(minLength: 20)
            if let value {
                Text(value)
                    .font(.system(size: 26))
                    .foregroundStyle(focused ? Palette.focusInk.opacity(0.7) : (valueColor ?? Palette.textSecondary))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: value)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).opacity(0.5)
            }
        }
        .padding(.vertical, detail == nil ? 0 : 10)
    }
}

/// tvOS-style toggle: the value reads On / Off (On in the accent); Select flips it.
struct ToggleRow: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsRow(label: label, detail: detail, value: isOn ? "On" : "Off",
                    valueColor: isOn ? (theme.isSystemWhite ? .white : theme.accent) : nil) {
            isOn.toggle()
        }
    }
}

/// A value row that pushes a picker page (checkmark on the current option).
struct PickerRow<T: Hashable>: View {
    let label: String
    var detail: String? = nil
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    var swatch: ((T) -> Color?)? = nil
    var onPreview: ((T?) -> Void)? = nil
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsRow(label: label, detail: detail, value: title(selection), chevron: true) {
            let binding = $selection
            nav.push(label) {
                PickerPage(options: options, selected: binding.wrappedValue, title: title, swatch: swatch, onPreview: onPreview) { v in
                    binding.wrappedValue = v
                    nav.pop()
                }
            }
        }
    }
}

struct PickerPage<T: Hashable>: View {
    let options: [T]
    let selected: T
    let title: (T) -> String
    var swatch: ((T) -> Color?)? = nil
    var onPreview: ((T?) -> Void)? = nil
    let onPick: (T) -> Void
    @FocusState private var focused: T?

    var body: some View {
        SettingsGroup {
            ForEach(options, id: \.self) { o in
                Button { onPick(o) } label: {
                    HStack(spacing: 18) {
                        if let c = swatch?(o) {
                            Circle().fill(c).frame(width: 36, height: 36)
                                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                        }
                        Text(title(o)).font(.system(size: 26, weight: .semibold))
                        Spacer()
                        if o == selected { Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)) }
                    }
                }
                .buttonStyle(SettingsRowStyle())
                .focused($focused, equals: o)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = selected } }
        .onChange(of: focused) { _, f in onPreview?(f) }
        .onDisappear { onPreview?(nil) }
    }
}

/// A row showing a (masked) text value; Select pushes a text-entry page.
struct TextEntryRow: View {
    let label: String
    var detail: String? = nil
    @Binding var text: String
    var masked = false
    var placeholder = ""
    var footer: String? = nil
    var keyboard: UIKeyboardType = .default
    @EnvironmentObject private var nav: SettingsNav

    var body: some View {
        SettingsRow(label: label, detail: detail, value: display, chevron: true) {
            let binding = $text
            nav.push(label) {
                TextEntryPage(label: label, initial: binding.wrappedValue, placeholder: placeholder, footer: footer, keyboard: keyboard) { v in
                    binding.wrappedValue = v
                    nav.pop()
                }
            }
        }
    }

    private var display: String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Not set" }
        if masked { return t.count > 6 ? "••••••" + t.suffix(4) : "••••" }
        return t.count > 36 ? String(t.prefix(33)) + "…" : t
    }
}

struct TextEntryPage: View {
    let label: String
    let initial: String
    var placeholder = ""
    var footer: String? = nil
    var keyboard: UIKeyboardType = .default
    let onSave: (String) -> Void
    @State private var text = ""
    @State private var fromPhone = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            TextField(placeholder.isEmpty ? label : placeholder, text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 28))
                .focused($fieldFocused)
                .onSubmit { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let footer {
                Text(footer).textStyle(.cardBody, color: Palette.textTertiary).padding(.horizontal, 10)
            }
            SettingsGroup {
                SettingsRow(label: "Save", icon: "checkmark") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                SettingsRow(label: "Enter from Phone", icon: "iphone") { fromPhone = true }
                if !initial.isEmpty {
                    SettingsRow(label: "Clear", icon: "xmark", destructive: true) { onSave("") }
                }
            }
        }
        .fullScreenCover(isPresented: $fromPhone) {
            PhoneInputSheet(title: label, prompt: "Type or paste it here and send it to your Apple TV.") { value in
                fromPhone = false
                onSave(value)
            } onDone: { fromPhone = false }
        }
        .onAppear {
            text = initial
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fieldFocused = true }
        }
    }
}

// MARK: - Sign-in sheet

/// Full-screen sign-in: QR (360 pt) on a white tile, the code in 64 pt
/// monospaced, the URL and a live status. Back cancels.
struct SignInSheet: View {
    let title: String
    let url: String?
    let code: String?
    let status: String
    var qrPayload: String? = nil
    var cancelTitle = "Cancel"
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.clear.background { GlassSurface(shape: Rectangle(), dark: true) }.ignoresSafeArea()
            Color.black.opacity(0.4).ignoresSafeArea()
            HStack(spacing: 90) {
                Group {
                    if let payload = qrPayload ?? url, let img = QRCode.image(payload) {
                        Image(uiImage: img).interpolation(.none).resizable().frame(width: 360, height: 360)
                    } else {
                        ProgressView().frame(width: 360, height: 360)
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.white))
                VStack(alignment: .leading, spacing: 26) {
                    Text(title).font(.system(size: 48, weight: .bold))
                    if let url {
                        Text("Scan the code, or go to").textStyle(.body, color: Palette.textSecondary)
                        Text(url).font(.system(size: 32, weight: .semibold))
                    }
                    if let code {
                        Text("and enter").textStyle(.body, color: Palette.textSecondary)
                        Text(code).font(.system(size: 64, weight: .bold, design: .monospaced)).tracking(6)
                    }
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(status).textStyle(.meta)
                    }
                    .padding(.top, 10)
                    Button(cancelTitle, action: onCancel)
                        .buttonStyle(GlassCapsuleStyle(font: TypeStyle.button.font, horizontalPadding: 34, height: 64))
                        .padding(.top, 10)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .onExitCommand(perform: onCancel)
    }
}

enum QRCode {
    static func image(_ string: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(string.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A confirmation alert for destructive rows.
struct ConfirmAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let action: () -> Void
}

extension View {
    func confirmation(_ item: Binding<ConfirmAction?>) -> some View {
        alert(item.wrappedValue?.title ?? "", isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
              presenting: item.wrappedValue) { c in
            Button(c.button, role: .destructive) { c.action() }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }
}
