import Foundation

/// `orivio://`, `stremio://` and `<bundle-id>://`.
@MainActor
enum DeepLinks {
    static func handle(_ url: URL, router: Router) {
        let scheme = url.scheme?.lowercased() ?? ""
        let bundleScheme = (Bundle.main.bundleIdentifier ?? "").lowercased()
        guard ["orivio", "stremio", bundleScheme].contains(scheme) else { return }
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).map { $0.removingPercentEncoding ?? $0 }

        // stremio://…/manifest.json → install add-on
        if url.absoluteString.contains("manifest.json") {
            Task {
                let result = await AppStores.shared.addons.install(url.absoluteString)
                switch result {
                case .success(let a): ToastCenter.shared.show("Installed \(a.displayName)", systemImage: "puzzlepiece.extension.fill")
                case .failure(let e): ToastCenter.shared.show("Couldn't install: \(e.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
                }
            }
            return
        }

        switch parts.first {
        case "meta", "detail":
            guard parts.count >= 3 else { return }
            router.tab = .home
            router.popToRoot(.home)
            router.push(.detail(MetaItem(id: parts[2], type: parts[1], name: "")))
        case "resume", "play":
            guard parts.count >= 3 else { return }
            let id = parts[2]
            router.tab = .home
            router.popToRoot(.home)
            let progress = AppStores.shared.progress
            if let p = progress.inProgress.first(where: { $0.metaID == id }) {
                let video = p.season.map { MetaVideo(id: p.videoID ?? p.id, title: p.episodeTitle ?? "", season: $0, episode: p.episode) }
                router.push(.streams(StreamsRequest(meta: p.meta, video: video, mode: .resume(fromStart: false))))
            } else {
                router.push(.detail(MetaItem(id: id, type: parts[1], name: "")))
            }
        case "x-callback-url", "callback", "external":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let action = parts.dropFirst().first ?? q.first(where: { $0.name == "action" })?.value ?? ""
            if action.contains("fail") || action.contains("error") {
                let msg = q.first(where: { $0.name == "errorMessage" || $0.name == "message" })?.value ?? "The external player couldn't play this link."
                ExternalPlayback.finishedWithError(msg)
            } else {
                let pos = q.first(where: { ["position", "time", "progress"].contains($0.name) })?.value.flatMap(Double.init)
                ExternalPlayback.finished(position: pos)
            }
        default:
            break
        }
    }
}
