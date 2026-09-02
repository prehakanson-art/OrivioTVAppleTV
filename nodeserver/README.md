# On-device P2P streaming (nodejs-mobile)

> **STATUS: NOT WIRED UP.** Nothing in the app references any of this. On-device
> P2P has never run: it needs `Vendor/NodeMobile.xcframework`, which has never
> been built, and `nodeserver/` is not in the app target. **TorrServer
> (Settings → Integrations → P2P) is the live P2P path** — that one works.
> Everything below is the plan for finishing this, not a description of
> shipped behaviour.

OrivioTV can stream torrents **on-device**, peer-to-peer, the same way Stremio's
tvOS app does: a Node.js runtime is linked into the app as a framework
(nodejs-mobile) and runs a small streaming server **in-process** — no
subprocess (which tvOS forbids), no external TorrServer.

- `server.js` — our own streaming server (Node + `torrent-stream`). Verified to
  boot + serve its HTTP API with desktop Node; real peering needs a network the
  build sandbox blocks, so it's tested on-device.
- `package.json` / `node_modules` — the server's deps, bundled into the app.

It exposes, on `http://127.0.0.1:11470`:

| Method | Path | Body / result |
|--------|------|---------------|
| GET  | `/health` | `ok` |
| POST | `/add` | `{magnet}` → `{infoHash, files:[{index,name,length}], defaultIndex}` |
| GET  | `/stream/:hash/:index` | the file, HTTP range-served |
| POST | `/drop` | `{hash}` → frees the swarm |

Playback: `POST /add` → pick a file → play `…/stream/<infoHash>/<index>`.

## Completing the integration

The one artifact that can't be built in a restricted sandbox is the tvOS Node
runtime (nodejs-mobile has no tvOS prebuilt). Build it on a Mac with Xcode +
GitHub access:

```sh
./scripts/build-nodejs-mobile-tvos.sh      # → Vendor/NodeMobile.xcframework
```

Then:

1. **project.yml** — link the framework and bundle the server:
   ```yaml
   targets:
     OrivioTV:
       dependencies:
         - framework: Vendor/NodeMobile.xcframework
       sources:
         - OrivioTV
         - path: nodeserver          # server.js + node_modules → app bundle
           buildPhase: resources
   ```
   `xcodegen generate` after.

2. **NodeStreamingServer.swift** (new, in `OrivioTV/Core/`) — start Node in-process:
   ```swift
   import Foundation

   // Bridged from NodeMobile: `int node_start(int argc, char** argv);`
   @_silgen_name("node_start") func node_start(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

   @MainActor final class NodeStreamingServer {
       static let shared = NodeStreamingServer()
       static let baseURL = "http://127.0.0.1:11470"
       private var started = false

       func startIfNeeded() {
           guard !started else { return }
           started = true
           guard let js = Bundle.main.path(forResource: "server", ofType: "js") else { return }
           Thread.detachNewThread {
               var args = ["node", js].map { strdup($0) }
               args.append(nil)
               _ = node_start(2, &args)
           }
       }

       /// Poll /health until the server answers (call before first torrent play).
       func waitUntilReady(timeout: TimeInterval = 8) async -> Bool {
           let deadline = Date().addingTimeInterval(timeout)
           while Date() < deadline {
               if let url = URL(string: "\(Self.baseURL)/health"),
                  let (_, r) = try? await URLSession.shared.data(from: url),
                  (r as? HTTPURLResponse)?.statusCode == 200 { return true }
               try? await Task.sleep(nanoseconds: 300_000_000)
           }
           return false
       }
   }
   ```
   Call `NodeStreamingServer.shared.startIfNeeded()` from `OrivioTVApp` on launch.

3. **Route torrent playback to it.** `TorrServerService` is already the template:
   add an `OnDeviceP2P` resolver that `POST`s the magnet to
   `NodeStreamingServer.baseURL/add`, picks the file (reuse the SxxExx/largest
   logic), and returns `…/stream/<hash>/<index>`. In `StreamsView.resolveViaP2P`,
   prefer the on-device server when `TorrentSettings.engine == .onDevice`, else
   fall back to the TorrServer client.

4. **Settings** — add an engine picker (On-device / TorrServer) to the existing
   P2P card; on-device needs no server URL.

Until the framework is dropped in, on-device P2P is inert and the TorrServer
client remains the working P2P path.
