import SwiftUI

/// App-wide short confirmations with an SF Symbol (~2.6 s).
@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    static let shared = ToastCenter()
    @Published private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "checkmark.circle.fill") {
        hideTask?.cancel()
        withAnimation(Motion.popover) { current = Toast(message: message, systemImage: systemImage) }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.current = nil }
        }
    }
}

/// Glass capsule, top-right.
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            if let t = center.current {
                HStack(spacing: 14) {
                    Image(systemName: t.systemImage).font(.system(size: 26, weight: .semibold))
                    Text(t.message).font(.system(size: 24, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 64)
                .glassBackground(Capsule(), dark: true)
                .padding(.top, 48)
                .padding(.trailing, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(t.id)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
