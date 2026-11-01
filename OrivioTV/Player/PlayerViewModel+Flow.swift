import SwiftUI

// MARK: - Next episode, Up Next, Still watching, Post-play

extension PlayerViewModel {
    static func makeShuffle(meta: MetaItem, current: MetaVideo?) -> [String] {
        let watched = AppStores.shared.watched
        let pool = meta.orderedEpisodes.filter { $0.hasAired && $0.id != current?.id }
        let unplayed = pool.filter { !watched.isWatched($0.id) }
        return (unplayed.isEmpty ? pool : unplayed).map(\.id).shuffled()
    }

    func computeNextEpisode() {
        guard meta.isSeries, let v = video else { nextVideo = nil; return }
        if request.shuffle {
            nextVideo = shuffleOrder.first.flatMap { meta.video(id: $0) }
        } else {
            nextVideo = meta.episode(after: v, allowUnaired: false)
        }
        upNextCancelled = false
    }

    func loadEpisodeList() {
        guard meta.isSeries else { episodeList = []; return }
        if let s = video?.season { episodeList = meta.episodes(season: s) } else { episodeList = meta.orderedEpisodes }
        if meta.videos.isEmpty {
            Task {
                let full = await MetaService.fetch(meta)
                if !full.videos.isEmpty {
                    meta = full
                    computeNextEpisode()
                    if let s = video?.season { episodeList = full.episodes(season: s) }
                }
            }
        }
    }

    /// Appears at the credits chapter or **Show Up Next** seconds before the end.
    func checkUpNextTrigger(_ t: Double) {
        guard firstFrameShown, duration > 60, nextVideo != nil, !upNextCancelled, !advancing, !isSwitchingSource,
              !pickingNextSource, overlay == .none || overlay.transportVisible, scrub == nil else { return }
        let lead = Double(settings.value.upNextSecondsBeforeEnd)
        let trigger = creditsStart ?? (duration - lead)
        guard t >= trigger, t < duration - 0.5 else { return }
        presentUpNext()
    }

    func presentUpNext() {
        let auto = settings.value.autoPlayNextEpisode || request.shuffle
        let countdown = settings.value.autoPlayCountdown
        if !request.shuffle, settings.value.stillWatchingEnabled, autoAdvanceCount >= settings.value.stillWatchingAfter {
            overlay = .stillWatching
            return
        }
        overlay = .upNext
        if auto, countdown >= 0 || request.shuffle {
            let total = Double(max(countdown, 0) == 0 && request.shuffle ? 10 : max(countdown, 0))
            upNextTotal = max(total, 0.1)
            upNextRemaining = total
            runUpNextCountdown()
        } else {
            upNextRemaining = nil
        }
    }

    private func runUpNextCountdown() {
        Task { [weak self] in
            while let self, let r = self.upNextRemaining, self.overlay == .upNext {
                if r <= 0 {
                    self.upNextRemaining = nil
                    self.playNext(auto: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                if self.overlay == .upNext, !self.isPaused { self.upNextRemaining = max(0, r - 0.25) }
            }
        }
    }

    func cancelUpNext() {
        upNextRemaining = nil
        upNextCancelled = true
        overlay = .none
    }

    func handleEnded() {
        saveProgress(transient: false)
        if nextVideo != nil, settings.value.autoPlayNextEpisode || request.shuffle {
            if overlay == .upNext, upNextRemaining == nil { return } // waiting for Play
            if overlay != .stillWatching { playNext(auto: true) }
            return
        }
        isFinished = true
        scrobbleStop()
        overlay = .postPlay
    }

    func replay() {
        isFinished = false
        overlay = .none
        seek(to: 0, keepPaused: false)
        engine?.play()
    }

    func continueAfterStillWatching() {
        autoAdvanceCount = 0
        overlay = .none
        if engineState == .ended || duration - currentTime < 2 { playNext(auto: false) } else { presentUpNext() }
    }

    /// Advances inside the same full-screen cover; reports the now-playing change.
    func playNext(auto: Bool, chosen: StreamEntry? = nil) {
        guard let next = nextVideo, !advancing else { return }
        advancing = true
        overlay = .none
        saveProgress(transient: false)
        if duration > 0, currentTime / duration >= 0.9 { AppStores.shared.watched.markWatched(meta: meta, video: video) }
        applyVerdict()
        scrobbleStop()
        loadingStatus = "Loading \(next.seasonEpisodeCode)…"
        isSwitchingSource = true
        if auto { autoAdvanceCount += 1 } else { autoAdvanceCount = 0 }
        Task {
            defer { advancing = false; isSwitchingSource = false }
            let candidates: [StreamEntry]
            var all: [StreamEntry] = []
            if let chosen {
                candidates = [chosen]
            } else if let direct = request.directEpisodes?[next.id] {
                candidates = [direct]
            } else {
                let search = StreamSearch(meta: meta, video: next)
                search.start()
                // Wait for results (bounded by patience), picking as soon as a same-source link arrives.
                let deadline = Date().addingTimeInterval(TimeInterval(settings.value.sourceSearchPatience))
                var picked: [StreamEntry] = []
                while Date() < deadline {
                    picked = rankNextCandidates(search.entries)
                    if let first = picked.first, first.stream.behaviorHints?.bingeGroup == entry.stream.behaviorHints?.bingeGroup,
                       entry.stream.behaviorHints?.bingeGroup != nil { break }
                    if search.isComplete { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                search.cancel()
                all = search.entries
                candidates = rankNextCandidates(search.entries)
            }
            // Retry ladder.
            for (i, c) in candidates.prefix(4).enumerated() {
                if i > 0 { try? await Task.sleep(nanoseconds: UInt64(i) * 500_000_000) }
                guard let resolved = try? await StreamResolver.resolve(c, video: next, timeout: 25, onStatus: { [weak self] s in self?.loadingStatus = s }) else { continue }
                advance(to: next, entry: c, entries: all.isEmpty ? allEntries : all, resolved: resolved)
                return
            }
            retryAdvance = true
            overlay = .error("Couldn't find a source for \(next.seasonEpisodeCode).")
        }
    }

    /// Same binge group → same add-on (Keep next episode on the same source),
    /// bounded by the profile's Auto Link add-ons. Deliberately ignores the auto-select switches.
    func rankNextCandidates(_ entries: [StreamEntry]) -> [StreamEntry] {
        let titleKey = nextVideo?.id ?? ""
        var pool = entries.filter { !$0.stream.isExternal && !RejectedLinks.isRejected($0.rejectionKey, title: titleKey) }
        let auto = AppStores.shared.profiles.active.autoLink
        if auto.enabled, let pref = auto.preferredAddon {
            let allowed = Set([pref, auto.secondaryAddon].compactMap { $0 })
            let bounded = pool.filter { allowed.contains($0.sourceAddonName) }
            if !bounded.isEmpty { pool = bounded }
        }
        let byScore = pool.sorted { $0.sourceScore > $1.sourceScore }
        guard settings.value.keepSameSourceForNext else { return byScore }
        let group = entry.stream.behaviorHints?.bingeGroup
        let sameGroup = group.map { g in byScore.filter { $0.stream.behaviorHints?.bingeGroup == g } } ?? []
        let sameAddon = byScore.filter { $0.sourceAddonName == entry.sourceAddonName && !sameGroup.contains($0) }
        let rest = byScore.filter { !sameGroup.contains($0) && !sameAddon.contains($0) }
        return sameGroup + sameAddon + rest
    }

    private func advance(to next: MetaVideo, entry e: StreamEntry, entries: [StreamEntry], resolved: ResolvedStream) {
        if request.shuffle { shuffleOrder.removeAll { $0 == next.id } }
        setNowPlaying(video: next, entry: e, entries: entries, url: resolved.url, headers: resolved.headers)
        let resume = AppStores.shared.progress.progress(for: next.id).flatMap { $0.isResumable ? $0.position : nil }
        reopen(startAt: resume ?? 0)
        computeNextEpisode()
        onNowPlayingChanged?(meta, next)
        AppStores.shared.progress.rememberLink(LastLink(stream: e.stream, addonName: e.addonName, rejectionKey: e.rejectionKey, savedAt: Date()),
                                               signature: e.signature, for: next.id)
    }

    func markNextWatched() {
        guard let n = nextVideo else { return }
        AppStores.shared.watched.markWatched(meta: meta, video: n)
        computeNextEpisode()
        showToast("Marked \(n.seasonEpisodeCode) as watched")
    }

    func playEpisode(_ v: MetaVideo) {
        nextVideo = v
        playNext(auto: false)
    }

    func scrobbleStop() {
        guard AppStores.shared.trakt.isSignedIn, AppStores.shared.traktFlags.value.scrobble, duration > 0, !isLive, !isRecording else { return }
        let m = meta, v = video, f = currentTime / duration
        Task { await TraktService.scrobble("stop", meta: m, video: v, progress: f) }
    }
}

// MARK: - Remote grammar (§7.11)

enum RemotePress {
    case select
    case edge(Edge)
    case playPause(source: String)
    case menu
}

extension PlayerViewModel {
    var capturesSelect: Bool {
        if scrub != nil { return true }
        switch focusArea {
        case .video, .bar: return overlay == .none || overlay.transportVisible
        default: return false
        }
    }

    var capturesArrows: Bool { scrub != nil || ((focusArea == .video || focusArea == .bar) && (overlay == .none || overlay.transportVisible)) }

    func handle(_ press: RemotePress) {
        noteInteraction()
        switch press {
        case .playPause(let source):
            // ⏯ 3× within 2 s = blind display re-sync (checked before every other guard).
            let now = Date()
            playPauseStamps = playPauseStamps.filter { now.timeIntervalSince($0) < 2 } + [now]
            if let (at, src) = lastPlayPause, src != source, now.timeIntervalSince(at) < 0.1 { return }
            lastPlayPause = (now, source)
            if playPauseStamps.count >= 3 {
                playPauseStamps = []
                DisplayModeManager.shared.blindResync()
                showToast("Re-syncing display")
                return
            }
            guard transportInputAllowed() else { return }
            if scrub != nil { commitScrub(); return }
            if overlay == .upNext { playNext(auto: false); return }
            if overlay == .postPlay { replay(); return }
            togglePlayPause()
        case .menu:
            let now = Date()
            guard now.timeIntervalSince(lastMenuAt) > 0.3 else { return }
            lastMenuAt = now
            menuLadder()
        case .select:
            guard transportInputAllowed() else { return }
            if scrub != nil { commitScrub(); return }
            switch focusArea {
            case .bar:
                if overlay.transportVisible { beginScrub() }
            default:
                if overlay == .none {
                    togglePlayPause()
                    raiseTransport()
                }
            }
        case .edge(let edge):
            guard transportInputAllowed() else { return }
            if scrub != nil {
                if edge == .leading { scrubJump(-1) } else if edge == .trailing { scrubJump(1) }
                return
            }
            // Live TV with a channel list: Up/Down change channel, Left/Right
            // open the channel list (nothing to seek on a live stream).
            if isLive, overlay == .none, !liveChannels.isEmpty {
                switch edge {
                case .top: zap(-1); return
                case .bottom: zap(1); return
                case .leading, .trailing: openPicker(.channels, from: .none); return
                }
            }
            switch edge {
            case .leading, .trailing:
                guard !isLive else { raiseTransport(); return }
                let amount = Double(settings.value.skipAmount) * (edge == .leading ? -1 : 1)
                nudge(amount, debounce: 0.65, hud: overlay == .none)
            case .top:
                if overlay == .none {
                    if showsSkipIntro { requestedFocus = .skipIntro } else { raiseTransport() }
                } else if focusArea == .bar {
                    requestedFocus = .glyphs
                }
            case .bottom:
                if overlay == .none {
                    if showsSkipIntro { requestedFocus = .skipIntro } else { raiseTransport() }
                } else if focusArea == .bar {
                    openInfo()
                }
            }
        }
    }

    /// A clearly horizontal swipe > 160 pt skips; vertical swipes open info / raise the transport.
    func handleSwipe(dx: CGFloat, dy: CGFloat) {
        guard transportInputAllowed() else { return }
        if scrub != nil { return }
        noteInteraction()
        if overlay == .none {
            if abs(dx) > 160, abs(dx) > abs(dy) * 2, !isLive {
                let amount = Double(settings.value.skipAmount) * (dx < 0 ? -1 : 1)
                let continuing = swipeRun.map { Date().timeIntervalSince($0.last) < 1.2 } ?? false
                swipeRun = (continuing ? (swipeRun?.count ?? 0) + 1 : 1, Date())
                nudge(amount, debounce: 0.45, immediate: !continuing, hud: true)
            } else if dy > 45, abs(dy) > abs(dx) {
                openInfo()
            } else if dy < -45, abs(dy) > abs(dx) {
                raiseTransport()
            }
        } else if focusArea == .bar, dy > 110, abs(dy) > abs(dx) {
            openInfo()
        } else if overlay == .info, focusArea == .sheet, dy < -160 {
            closeInfo()
        }
    }

    func handleLightTap() {
        guard transportInputAllowed() else { return }
        if overlay == .none { raiseTransport() } else if focusArea == .bar { showWallClock.toggle(); noteInteraction() }
    }

    /// Before the first frame and during a display handshake, transport input is refused (logged).
    func transportInputAllowed() -> Bool {
        if !firstFrameShown, case .error = overlay {} else if !firstFrameShown {
            decisions.log("input", "refused", "before first frame")
            return false
        }
        return true
    }

    /// cancel scrub → close a picker → close a sub-menu → paused info → controls → close the info sheet → hide controls → exit.
    func menuLadder() {
        if scrub != nil { cancelScrub(); return }
        switch overlay {
        case .episodes, .sources, .speed, .engine, .channels:
            if pickingNextSource { cancelNextSourcePicker(); return }
            overlay = returnOverlay ?? .none
            returnOverlay = nil
        case .audio, .subtitles:
            overlay = isPaused ? .pauseInfo : .controls
            requestedFocus = .bar
        case .info:
            if infoPickerOpen { infoPickerOpen = false } else { closeInfo() }
        case .pauseInfo, .controls:
            hideTransport()
        case .upNext:
            cancelUpNext()
        case .error, .stillWatching, .postPlay, .none:
            exit()
        }
    }

    func openInfo() {
        hideTask?.cancel()
        refreshInfo()
        infoTab = .info
        overlay = .info
    }

    func closeInfo() {
        overlay = isPaused ? .pauseInfo : .none
        if isPaused { requestedFocus = .bar }
    }

    func openPicker(_ o: PlayerOverlay, from: PlayerOverlay) {
        returnOverlay = from
        if o == .sources, allEntries.isEmpty { fetchAlternatives() }
        overlay = o
    }

    /// Up Next hold → Select Source: a picker of the next episode's links.
    func openNextSourcePicker() {
        guard let next = nextVideo else { return }
        upNextRemaining = nil
        nextEntries = []
        pickingNextSource = true
        if let direct = request.directEpisodes?[next.id] {
            nextEntries = [direct]
            returnOverlay = .upNext
            overlay = .sources
            return
        }
        let search = StreamSearch(meta: meta, video: next)
        search.onEntries = { [weak self, weak search] _ in
            guard let self, let search else { return }
            self.nextEntries = search.entries
        }
        search.start()
        nextSourceSearch = search
        returnOverlay = .upNext
        overlay = .sources
    }

    func cancelNextSourcePicker() {
        nextSourceSearch?.cancel()
        nextSourceSearch = nil
        pickingNextSource = false
        overlay = .upNext
        returnOverlay = nil
    }

    func chooseNextSource(_ e: StreamEntry) {
        nextSourceSearch?.cancel()
        nextSourceSearch = nil
        pickingNextSource = false
        returnOverlay = nil
        playNext(auto: false, chosen: e)
    }

    /// Opened from a CW session with no alternatives: fetch them.
    func fetchAlternatives() {
        let search = StreamSearch(meta: meta, video: video)
        search.onEntries = { [weak self, weak search] _ in
            guard let self, let search else { return }
            self.allEntries = search.entries
        }
        search.start()
        alternativesSearch = search
    }
}

// MARK: - Live TV: channel up/down, the channel list, Start Over

/// The banner shown on a channel change.
struct LiveBanner: Equatable {
    let channel: LiveChannel
    let now: EPGProgramme?
    let next: EPGProgramme?
}

extension PlayerViewModel {
    var liveChannels: [LiveChannel] { request.liveChannels ?? [] }
    var currentChannel: LiveChannel? { liveChannels.first { $0.id == meta.id } }

    /// Up/Down: step through the list. The banner follows at once; the switch
    /// waits for the presses to settle so flicking past channels is cheap.
    func zap(_ delta: Int) {
        let list = liveChannels
        guard !list.isEmpty else { return }
        let from = zapTargetIndex ?? list.firstIndex { $0.id == meta.id } ?? 0
        let to = (from + delta + list.count) % list.count
        zapTargetIndex = to
        showBanner(for: list[to])
        zapTask?.cancel()
        zapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.zapTargetIndex = nil
            if list[to].id != self.meta.id { self.switchChannel(to: list[to]) }
        }
    }

    func showBanner(for c: LiveChannel) {
        let nn = EPGGuide.shared.nowNext(for: c)
        liveBanner = LiveBanner(channel: c, now: nn.now, next: nn.next)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.liveBanner = nil
        }
    }

    /// Changes channel inside this player (no cover dismiss/present).
    func switchChannel(to c: LiveChannel) {
        overlay = .none
        loadingStatus = "Tuning \(c.name)…"
        isSwitchingSource = true
        Task {
            defer { isSwitchingSource = false }
            switch await LivePlayback.resolve(c) {
            case .failure(let e):
                showToast(e.message)
            case .success(let src):
                AppStores.shared.liveTV.noteRecent(c.id)
                meta = LivePlayback.meta(for: c)
                setStreamKind(isLive: true, forceDemuxer: src.demuxer)
                let e = LivePlayback.entry(for: c, source: src)
                setNowPlaying(video: nil, entry: e, entries: [e], url: src.url, headers: src.headers)
                reopen(startAt: 0)
                onNowPlayingChanged?(meta, nil)
                showBanner(for: c)
            }
        }
    }

    /// The programme on now, when the archive can play it from its start.
    var startOverProgramme: EPGProgramme? {
        guard isLive, let c = currentChannel, let p = EPGGuide.shared.nowNext(for: c).now,
              LivePlayback.canPlayFromArchive(c, p) else { return nil }
        return p
    }

    /// Start Over: the current programme from its start, from the archive.
    func startOver() {
        guard let c = currentChannel, let p = startOverProgramme else { return }
        overlay = .none
        Task {
            guard let url = await LivePlayback.catchupURL(c, p) else { showToast("Couldn't build the catch-up address."); return }
            meta = MetaItem(id: "\(c.id)@\(p.id)", type: "recording", name: p.title, poster: c.logo, logo: c.logo, description: p.desc, genres: [c.name])
            setStreamKind(isLive: false, forceDemuxer: false)
            let e = StreamEntry(stream: Stream(name: c.name, title: p.title, url: url.absoluteString), addonName: c.name, addonID: "livetv", index: 0)
            setNowPlaying(video: nil, entry: e, entries: [e], url: url, headers: c.headers)
            reopen(startAt: 0)
            onNowPlayingChanged?(meta, nil)
        }
    }
}
