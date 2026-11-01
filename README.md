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

Both are the same unsigned arm64 tvOS build (Apple TV HD / 4K, tvOS 18+); the sideload tool
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

Requires Xcode 16.3+ (Swift 6.1, for SwiftPM package traits) with the tvOS platform
installed. The deployment target is tvOS 18. `OrivioTV.xcodeproj` is checked in;
[XcodeGen](https://github.com/yonaskolb/XcodeGen) is optional (`project.yml` excludes the
pre-v0.13 files the committed project does not compile, so both build the same file set).

### Playback engines

Movies and episodes play in the Classic player. Auto (the default in Settings → Playback →
Playback engine) opens every stream there with
[AetherEngine](https://github.com/superuser404notfound/AetherEngine): MKV, MP4, HLS and the
rest, hardware decode through AVPlayer where tvOS can and its own Metal route where it
cannot (AV1, VC-1, MPEG-2, Hi10P…), the panel's native Dolby Vision (Profile 5 / 7 / 8),
HDR10+ and HLG modes, E-AC-3 Atmos passthrough, a lossless LPCM bridge for TrueHD / DTS-HD MA
on a 7.1 route, and TrueHD Atmos / DTS:X objects rendered into a 7.1.4 bed on tvOS 26+. A link
it cannot play is reloaded once through the previous engines (AVPlayer for MP4/HLS, FFmpeg via
KSPlayer for the rest), then normal source failover applies. The player UI is the same for
every engine. Live TV keeps its own player (Native / FFmpeg / VLC); there AetherEngine
counts as Auto.

AetherEngine is linked through the local package `Vendor/OrivioAether`, a dynamic framework, so
its FFmpeg stays separate from the FFmpeg KSPlayer links statically (see the comment in
`Vendor/OrivioAether/Package.swift`). That manifest turns on the engine's optional components
(`TrueHDObjectAudio`, `DTSXObjectAudio`, `DualLayerDolbyVision`, `DolbyVisionStillReshaping`).
They may be subject to third-party patent licensing; whoever distributes a build is
responsible for that licensing. AetherEngine is LGPL-3.0 with an App Store exception, its
FFmpeg frameworks are LGPL-2.1-or-later, libdovi (quietvoid) is MIT, and the TrueHD decoder
(LibTrueHD / truehdd) is MIT + Apache-2.0: ship their license texts and notices with any
distributed build (details in the AetherEngine README, "License").

Xcode resolves the package on the first build (`Package.resolved` is not committed for it).

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

On the box itself, **Settings → Playback → Developer → Test streams** plays public
sample files through the selected engine: Dolby Vision 5 / 8.1 / 8.4, HDR10, HLG, AV1,
TrueHD Atmos, DTS-HD MA, E-AC-3, PGS and ASS subtitles (Apple HLS examples, Jellyfin test
videos, samples.ffmpeg.org), plus a field for any URL of your own — DV Profile 7 FEL,
HDR10+ and DTS:X have no reliable public direct link. Test sessions never reach Continue
Watching, Trakt or the add-on failover sweep.

## Known limitations

- Torrent/`infoHash`-only streams are filtered out (no torrent engine on tvOS);
  debrid-resolved HTTP links from addons work.
- External-subtitle addons (OpenSubtitles) not wired yet; embedded tracks work on
  both engines.
- First build downloads the FFmpegKit binary xcframeworks (large) and needs the
  Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
