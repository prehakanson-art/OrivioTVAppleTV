import SwiftUI

/// First launch: sign in, or say you'd rather not.
///
/// Shown once, before anything else, and only when nobody is signed in. The
/// three choices are deliberately ranked — the QR is the default because it is
/// the only one where the password is never typed on the TV (see the note on
/// `OrivioAccountManager.signIn`), email/password is there for anyone who
/// wants it, and carrying on without an account is a first-class option rather
/// than a dead end: the default add-ons are guaranteed, so the app is usable
/// immediately.
struct WelcomeView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var account: OrivioAccountManager
    @ObservedObject var addonManager: AddonManager
    let onFinished: () -> Void

    /// `offerAddons` and `addAddons` are only reachable from "Use without an
    /// account". Someone who SIGNED IN has their add-ons arriving from their
    /// account moments later, so asking them to add some would be both
    /// redundant and confusing.
    private enum Step: Equatable { case choose, email, offerAddons, addAddons }
    @State private var step: Step =
        ProcessInfo.processInfo.arguments.contains("-welcomeOfferDemo") ? .offerAddons : .choose
    /// The offer's primary action holds focus, so a Select arriving as the
    /// screen appears takes the additive choice rather than dismissing it.
    @FocusState private var offerFocus: Bool
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @FocusState private var focus: Field?
    private enum Field: Hashable { case email, password }

    /// The sign-in address without scheme or query — what someone would
    /// actually type into a phone.
    private static var displayHost: String {
        let base = OrivioConfig.tvLoginWebBaseURL
        return base
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "?").first ?? base
    }

    var body: some View {
        ZStack {
            ATVBackground()
            Group {
                switch step {
                case .choose: chooser
                case .email: emailForm
                case .offerAddons: addonOffer
                case .addAddons:
                    AddonPhoneAddView(addonManager: addonManager, onDone: onFinished)
                }
            }
            .padding(OrivioSpacing.huge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Signing in by ANY route finishes onboarding — the QR poll completes
        // on its own timeline, so watching the auth state is what catches it
        // rather than a callback on the button.
        //
        // Only while still ON a sign-in step, though. A session restored in
        // the background flips this too, and without the guard it tore the
        // screen away from someone who had already chosen "Use without an
        // account" and was part-way through adding add-ons from their phone.
        .onChange(of: account.authState.isSignedIn) { _, signedIn in
            guard signedIn, step == .choose || step == .email else { return }
            onFinished()
        }
        .onAppear { if account.qrLogin == nil { account.startQRLogin() } }
        .onDisappear { account.cancelQRLogin() }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(spacing: OrivioSpacing.lg) {
            Text("Welcome to Orivio")
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)

            if let qr = account.qrLogin {
                // Same shape as the Trakt and SIMKL connect pages: the QR
                // carries the code, and the typed-in fallback is the bare
                // address plus the code shown separately. Printing the full
                // webURL was unreadable — it embeds the code, so the line then
                // said "go to …?code=e9cd… and enter e9cd…".
                Text("Scan the code with your phone, or go to \(Self.displayHost) and enter the code below.")
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .fixedSize(horizontal: false, vertical: true)
                QRCodeView(string: qr.webURL, side: 300)
                Text(qr.code)
                    .font(.system(size: 40, weight: .heavy, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(theme.palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 900)
                Text(qr.statusText)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textTertiary)
            } else if OrivioConfig.isConfigured {
                OrivioLoadingView(label: "Preparing sign-in").frame(height: 300)
            } else {
                // No backend configured in this build — say so instead of
                // showing a QR that can never complete.
                Text("Accounts aren't configured in this build. You can still use Orivio without one.")
                    .font(FusionType.bodyText(theme.font))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = account.errorMessage {
                Text(error)
                    .font(.system(size: 20))
                    .foregroundStyle(OrivioPrimitives.red300)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: OrivioSpacing.md) {
                if OrivioConfig.isConfigured {
                    Button("Sign in with email") {
                        account.errorMessage = nil
                        step = .email
                    }
                }
                Button("Use without an account") {
                    account.cancelQRLogin()
                    step = .offerAddons
                }
            }
            .padding(.top, OrivioSpacing.sm)
        }
    }

    // MARK: Add-ons offer

    private var addonOffer: some View {
        VStack(spacing: OrivioSpacing.lg) {
            Text("Add add-ons?")
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Add-ons are where Orivio gets its catalogs, artwork and streams. Cinemeta and OpenSubtitles are already installed. You can add more from your phone now — no typing on the remote — or any time from Settings → Add-ons.")
                .font(FusionType.bodyText(theme.font))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: OrivioSpacing.md) {
                Button("Add add-ons now") { step = .addAddons }
                    .focused($offerFocus)
                Button("Later, in Settings", action: onFinished)
            }
            .padding(.top, OrivioSpacing.sm)
            .onAppear { offerFocus = true }
        }
    }

    // MARK: Email + password

    private var emailForm: some View {
        VStack(spacing: OrivioSpacing.md) {
            Text("Sign in")
                .font(FusionType.pageTitle(theme.font))
                .foregroundStyle(theme.palette.textPrimary)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .focused($focus, equals: .email)
                .frame(maxWidth: 700)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .frame(maxWidth: 700)

            if let error = account.errorMessage {
                Text(error)
                    .font(.system(size: 20))
                    .foregroundStyle(OrivioPrimitives.red300)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 800)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: OrivioSpacing.md) {
                Button(signingIn ? "Signing in…" : "Sign in") {
                    guard !signingIn else { return }
                    signingIn = true
                    Task {
                        await account.signIn(email: email, password: password)
                        signingIn = false
                        // Clear the password either way; it has no reason to
                        // stay in memory after the attempt.
                        password = ""
                    }
                }
                .disabled(signingIn)
                Button("Back") {
                    account.errorMessage = nil
                    password = ""
                    step = .choose
                }
            }
            .padding(.top, OrivioSpacing.sm)
        }
        .onAppear { focus = .email }
        .onExitCommand { step = .choose }
    }
}

/// Whether the welcome screen has been shown and dismissed.
///
/// Its own flag rather than "is signed in": someone who chose to carry on
/// without an account must not be asked again on every launch.
enum OnboardingState {
    private static let key = "orivio.onboarding.completed.v1"

    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// True on a fresh install with nobody signed in. An install that is
    /// already signed in (restored session, or an upgrade from a build that
    /// predates this screen) skips it — the screen would have nothing to ask.
    static func shouldShow(signedIn: Bool) -> Bool {
        !completed && !signedIn
    }
}
