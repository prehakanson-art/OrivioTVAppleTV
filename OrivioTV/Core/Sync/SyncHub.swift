import Foundation

/// Coordinates every sync destination (Orivio account, Trakt, SIMKL).
/// - `syncOnAppOpen`: 1.5 s after launch/foreground (3 s on A8/A10X), 15 s floor.
/// - Auto-sync every 30 s (90 s on A8/A10X); light during playback.
/// - Trakt/SIMKL every 5 min while signed in, skipped during playback.
@MainActor
final class SyncHub: ObservableObject {
    static let shared = SyncHub()

    @Published private(set) var isSyncing = false
    @Published var lastError: String?
    @Published var lastSync: Date?
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?

    private let account = OrivioAccount.shared
    private var timer: Timer?
    private var lastAppOpenSync = Date.distantPast
    private var lastTrackerSync = Date.distantPast
    private var started = false

    private var isPlaying: Bool { PlayerPresenter.shared.isPresenting || PlayerPresenter.shared.parkedModel != nil || PiPHandoff.shared.isActive }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        isSignedIn = account.isSignedIn
        accountEmail = account.email
        OrivioSync.shared.onError = { [weak self] e in self?.lastError = e }
        account.onSignedIn = { [weak self] uid, interactive in
            guard let self else { return }
            self.isSignedIn = true
            self.accountEmail = self.account.email
            if interactive {
                OrivioSync.shared.accountChanged(to: uid)
                Task { await self.syncNow() }
            }
        }
        account.onSignedOut = { [weak self] in
            self?.isSignedIn = false
            self?.accountEmail = nil
            OrivioSync.shared.signedOut()
        }
        if let uid = account.userID { OrivioSync.shared.accountChanged(to: uid) }
        let interval: TimeInterval = PerformanceProfile.isConstrained ? 90 : 30
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoSync() }
        }
        RunLoop.main.add(t, forMode: .default)
        timer = t
        appBecameActive()
    }

    func appBecameActive() {
        guard Date().timeIntervalSince(lastAppOpenSync) > 15 else { return }
        lastAppOpenSync = Date()
        let delay: UInt64 = PerformanceProfile.isConstrained ? 3_000_000_000 : 1_500_000_000
        Task {
            try? await Task.sleep(nanoseconds: delay)
            await syncNow(trackers: true)
        }
    }

    private func autoSync() async {
        if account.isSignedIn { await runAccount(light: isPlaying) }
        if !isPlaying, Date().timeIntervalSince(lastTrackerSync) > 300 { await syncTrackers() }
    }

    /// "Sync now" — everything.
    func syncNow(trackers: Bool = true) async {
        if account.isSignedIn { await runAccount(light: false) }
        if trackers, !isPlaying { await syncTrackers() }
    }

    private func runAccount(light: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await OrivioSync.shared.syncNow(light: light)
        if lastError == nil { lastSync = Date() }
    }

    func syncTrackers() async {
        lastTrackerSync = Date()
        await TraktSync.sync()
        await SimklService.sync()
    }

    func signOut() { account.signOut() }
}
