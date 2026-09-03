import Combine
import Foundation

@MainActor
final class StremioSyncManager: ObservableObject {
    static weak var shared: StremioSyncManager?

    var onMergedFromStremio: (() async -> Void)?

    private static let autoSyncInterval: TimeInterval = 30

    private let stremio: StremioAccountStore
    private let addonManager: AddonManager
    private let library: LibraryStore
    private let progress: ProgressStore
    private let watched: WatchedStore
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    init(
        stremio: StremioAccountStore,
        addonManager: AddonManager,
        library: LibraryStore,
        progress: ProgressStore,
        watched: WatchedStore
    ) {
        self.stremio = stremio
        self.addonManager = addonManager
        self.library = library
        self.progress = progress
        self.watched = watched
        Self.shared = self

        stremio.$authKey
            .removeDuplicates()
            .sink { [weak self] key in
                self?.handleAuthKey(key)
            }
            .store(in: &cancellables)

        // Removals here must reach Stremio too — the hub fans OUT, not just in.
        progress.onStremioClearProgress = { [weak self] metaID in
            self?.queueProgressClear(metaID)
        }

        handleAuthKey(stremio.authKey)
    }

    deinit {
        syncTask?.cancel()
        autoSyncTask?.cancel()
    }

    /// Titles removed from Continue Watching that Stremio hasn't been told
    /// about yet. Persisted, so a removal survives a failed push or a relaunch
    /// instead of silently coming back on the next pull.
    private static let pendingClearKey = "orivio.stremio.pendingProgressClears.v1"

    private var pendingProgressClears: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.pendingClearKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.pendingClearKey) }
    }

    private func queueProgressClear(_ metaID: String) {
        guard !metaID.isEmpty else { return }
        pendingProgressClears.insert(metaID)
    }

    func syncNow(reason: String = "Manual Stremio sync") {
        runSync(reason: reason, logSkippedBusy: true)
    }

    /// False until the auth-key publisher has delivered its first value, which
    /// at launch is whatever was restored from disk.
    private var sawInitialAuthKey = false

    private func handleAuthKey(_ key: String?) {
        guard let key, !key.isEmpty else {
            stopAutoSync()
            stremio.setSyncing(false)
            return
        }
        startAutoSync()
        // A key that ARRIVES while the app is running is someone signing in —
        // the publisher's initial value at launch is the restored one, and that
        // stays deferred so a heavyweight sync does not land in app
        // construction. Signing in should show the account's library at once,
        // not up to thirty seconds later.
        if sawInitialAuthKey {
            runSync(reason: "Stremio sign-in", logSkippedBusy: false)
        } else {
            sawInitialAuthKey = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.runSync(reason: "Stremio launch", logSkippedBusy: false)
            }
        }
    }

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoSyncInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard stremio.isSignedIn else { continue }
                guard syncTask == nil else { continue }
                if OrivioSyncManager.playbackActive {
                    NSLog("[OrivioStremio] auto-sync tick skipped — playback active")
                    continue
                }
                runSync(reason: "Auto Stremio sync", logSkippedBusy: false)
            }
        }
    }

    private func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        syncTask?.cancel()
        syncTask = nil
    }

    private func runSync(reason: String, logSkippedBusy: Bool) {
        guard let key = stremio.authKey, !key.isEmpty else {
            stremio.setStatus("Connect Stremio first")
            OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Sync skipped because Stremio is not connected.")
            return
        }
        guard syncTask == nil else {
            if logSkippedBusy {
                OrivioSyncDiagnostics.record(.warning, area: "Stremio", "Sync skipped because another Stremio sync is already running.")
            }
            return
        }

        stremio.setSyncing(true)
        stremio.setStatus("Syncing...")
        OrivioSyncDiagnostics.record(.info, area: "Stremio", "\(reason) started.")

        syncTask = Task { [weak self] in
            guard let self else { return }
            let pullResult = await StremioSync.pull(
                authKey: key,
                addonManager: addonManager,
                library: library,
                progress: progress,
                watched: watched
            )
            let succeeded = !pullResult.hasPrefix("Couldn't")
            var finalResult = pullResult
            if succeeded {
                progress.removeLocalOnlyProgress()
                await onMergedFromStremio?()
                progress.removeLocalOnlyProgress()
                let clears = pendingProgressClears
                let push = await StremioSync.pushCombined(
                    authKey: key,
                    addonManager: addonManager,
                    library: library,
                    progress: progress,
                    watched: watched,
                    clearedProgressIDs: clears
                )
                // Only drop the queue once the LIBRARY push actually landed —
                // the cleared ids ride in that payload. This used to test the
                // summary string for a "Couldn't" prefix that `pushCombined`
                // never produces, so a failed push still emptied the queue and
                // the title the user removed came back on the next pull.
                if !clears.isEmpty, push.libraryPushed {
                    pendingProgressClears.subtract(clears)
                }
                finalResult = "\(pullResult) · \(push.summary)"
            }
            stremio.setStatus(finalResult)
            stremio.setSyncing(false)
            OrivioSyncDiagnostics.record(
                succeeded ? .success : .failure,
                area: "Stremio",
                finalResult
            )
            syncTask = nil
        }
    }
}
