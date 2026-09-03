import SwiftUI

/// Email + password sign-in, shared by the Orivio and Stremio account panels as
/// the alternative to their QR flows. Both services already accept a password
/// grant; only a way to type one was missing.
///
/// Presented as a full-screen cover like the QR pages it sits beside, because a
/// tvOS keyboard needs the room and the field it is editing must not be under
/// the settings card's own scroll.
struct EmailSignInView: View {
    @EnvironmentObject private var theme: ThemeManager

    /// "Orivio" / "Stremio" — titles the page and names the account in the copy.
    let service: String
    @Binding var email: String
    @Binding var password: String
    /// Progress or failure text under the fields; failures are drawn in the
    /// error colour.
    var status: String?
    var isError: Bool = false
    var busy: Bool = false
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private enum Field: Hashable { case email, password, submit }
    @FocusState private var focused: Field?

    var body: some View {
        ZStack {
            ATVBackground()

            VStack(spacing: OrivioSpacing.xl) {
                VStack(spacing: OrivioSpacing.sm) {
                    Text("Sign in to \(service)")
                        .font(.system(size: 48, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text("Enter the email and password for your \(service) account.")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                VStack(spacing: OrivioSpacing.md) {
                    // `.username` / `.password` are what let tvOS offer the
                    // saved credential and the iPhone keyboard hand-off, which
                    // is the difference between typing an address on a remote
                    // and not having to.
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .onSubmit { focused = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .onSubmit(submit)
                }
                .font(.system(size: 26))
                .frame(maxWidth: 760)

                AccountPrimaryButton(title: busy ? "Signing In…" : "Sign In",
                                     systemImage: "arrow.right.circle.fill",
                                     action: submit)
                    .focused($focused, equals: .submit)

                if let status, !status.isEmpty {
                    Text(status)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isError ? OrivioPrimitives.error : theme.palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                }

                Text("Press Menu to go back")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: onCancel)
        .onAppear { focused = .email }
    }

    /// Nothing here is ever `.disabled`, deliberately. A disabled view is not
    /// focusable on tvOS, so disabling the button the moment a sign-in starts —
    /// or while the fields are empty — strands focus on a control that vanishes
    /// from under it. The guard lives here instead: an empty or in-flight
    /// submit is simply ignored.
    private func submit() {
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
        onSubmit()
    }
}
