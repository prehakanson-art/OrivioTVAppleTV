# Orivio TV

A native tvOS media player, rebuilt in SwiftUI with an Apple-TV-premium feel. Orivio TV
is a from-scratch Apple TV port of [Orivio](https://github.com/OrivioMedia/OrivioTV) — the
Android TV Stremio-addon player — and syncs with the same account. Licensed GPLv3,
matching the upstream project.

## ❤️ Support Orivio TV

Orivio TV is free and open-source. I'm raising funds to put it on **TestFlight** so it can
be installed without sideloading — if you'd like to help make that happen, donations are
hugely appreciated:

**→ [ko-fi.com/oriviotv](https://ko-fi.com/oriviotv)**

## Install

Grab the latest `.ipa` from [Releases](../../releases):

- **`OrivioTV-V2(Sideloady).ipa`** — for **Sideloadly** and similar sideloaders.
- **`OrivioTV-0.7.15-tvos.ipa`** — for **Xcode** (Devices & Simulators) or **Apple
  Configurator**.

Both are the same unsigned arm64 tvOS build (Apple TV HD / 4K, tvOS 17+); the sideload tool
re-signs with your Apple ID on install.

The upstream app is Kotlin + Jetpack Compose + ExoPlayer/mpv, so nothing could be reused
directly; this is a from-scratch reimplementation of the same product:

- **Stremio addon ecosystem** — Cinemeta ships installed; add any addon by pasting its
  `manifest.json` URL in Settings (`stremio://` links accepted).
- **Orivio design system** — the full color token set (all 7 accent themes: Crimson, Ocean,
  Violet, Emerald, Amber, Rose, White), near-black surfaces, accent focus rings.
- **Home** — hero backdrop that follows card focus (logo, IMDb badge, meta, description),
  addon catalog rows, Continue Watching row with resume.
- **Search** — native tvOS search across every search-capable addon catalog.
- **Detail** — full-bleed backdrop, logo, meta badges, cast, season picker + episode rows.
- **Stream selection** — parallel fan-out to all stream addons, grouped by addon with
  quality badges.

## Player

Dual-engine playback with a fully custom UI:

- **Native engine** (AVPlayer via KSPlayer's `KSAVPlayer`) — HLS, MP4, MOV, fMP4 on the
  hardware path.
- **FFmpeg engine** ([KSPlayer](https://github.com/kingslay/KSPlayer)'s `KSMEPlayer`) —
  MKV, AVI, FLV, TS and everything else, with embedded subtitle rendering (text and
  PGS/VobSub bitmap cues). If the native engine rejects a stream, playback fails over
  to FFmpeg automatically; the active engine shows in the "via" line of the controls.

- **Orivio-style controls** — title/episode/via lines, accent progress bar with buffered
  fill that thickens on focus, circular icon buttons (play, next episode, subtitles,
  audio, sources, episodes, speed, aspect), elapsed/total readout.
- **Infuse-style touchpad scrubbing** — with controls hidden, swipe the Siri remote
  touch surface to glide a preview playhead along the timeline (velocity-adaptive:
  slow drags get fine precision, flicks accelerate). A floating time bubble shows the
  target and signed delta; **click to seek**, Menu to cancel, auto-cancel after 6 s.
- Pause overlay ("You're watching" metadata sheet with cast chips and clock), d-pad
  ±10 s skips, debounced nudge-seek on the focused timeline, episode/source side
  panels, audio & subtitle track selection, playback speed, aspect fit/zoom/stretch,
  Continue Watching persistence.

### Remote guide (during playback)

| Input | Action |
|---|---|
| Swipe left/right | Infuse-style scrub preview |
| Click (while scrubbing) | Seek to preview position |
| Click left/right edge | ±10 seconds |
| Click / swipe up/down | Show controls |
| Play/Pause | Toggle; pausing reveals the info overlay |
| Menu | Cancel scrub → close panel → exit player |

## Building

Requires Xcode 16+ with the tvOS platform installed, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen).

Provider keys are kept out of source control (like the Android app's
`local.properties`). Before building, copy the template and fill in any keys you
have — all are optional; with them blank the app still browses and plays via
addons, only the Orivio account, Trakt, and TMDB enrichment need them:

```bash
cp Secrets.example.swift NuvioTV/Secrets.swift   # then edit NuvioTV/Secrets.swift
xcodegen generate
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS Simulator' build
```

`NuvioTV/Secrets.swift` is gitignored, so your keys never enter the repo.

To run on a real Apple TV, open `OrivioTV.xcodeproj` in Xcode, pick your signing team,
and run on the device. Dev flags: launch with `-playerDemo` to open the player against
Apple's public HLS test stream (`-playerDemoTour` walks the overlay states); `-detailDemo`
jumps straight to a Detail screen so cast/trailers/more-like-this enrichment is visible
without navigating there by remote.

## Known limitations

- Torrent/`infoHash`-only streams are filtered out (no torrent engine on tvOS);
  debrid-resolved HTTP links from addons work.
- External-subtitle addons (OpenSubtitles) not wired yet; embedded tracks work on
  both engines.
- First build downloads the FFmpegKit binary xcframeworks (large) and needs the
  Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
