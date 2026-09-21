# Orivio TV (Apple TV / tvOS) — Complete Engineering Handoff

> **Purpose of this file.** This is the full working context for the Orivio TV tvOS app,
> written so a new assistant (or a new engineer) can pick the project up cold and be
> productive without re-deriving anything. It covers the repository and GitHub setup, the
> two shipped IPAs and exactly why there are two, the build system, every subsystem
> (especially the player), the sync/account model, the debugging harnesses, and a long
> list of hard-won rules and traps that cost real debugging time to learn.
>
> **Generated:** 2026-09-18 · **Tree:** `~/Downloads/NuvioTV-AppleTV` · **HEAD:** `057809e` ("Land the v8 batch and stamp the version") · **Version:** MARKETING_VERSION `8`, build `1`
>
> **Authority note:** where this document says *verified*, it was observed on a real
> device or simulator. Where it says *reasoned* or *unverified*, it was derived by
> reading code and has never been proven at runtime. That distinction matters — the
> project owner makes decisions from it. Preserve it in future work.

---

## 0. The one-paragraph summary

Orivio TV is a native tvOS 17+ media player written in SwiftUI (127 Swift files, ~83,000
lines). It is a from-scratch Apple TV port of **Orivio** (the Android TV Stremio-add-on
player) and syncs with the same account backend. It browses content through the **Stremio
add-on protocol**, resolves playable links through add-ons / debrid providers / JS
scraper plugins / Plex / Jellyfin / IPTV, and plays them through a **four-engine player**
(AVPlayer, FFmpeg/KSPlayer, VLCKit, and a bespoke Dolby-Vision/Dolby-Atmos direct sample
feed). There is no CI; IPAs are built locally by a shell script and published as GitHub
Releases for sideloading. It is GPLv3.

---

## 1. Repository, GitHub, and release process

### 1.1 Git

| Item | Value |
|---|---|
| Remote `origin` | `https://github.com/prehakanson-art/OrivioTVAppleTV.git` |
| Default branch | `main` |
| Commits | 367 |
| Other live branch | `fix/audit-sessions-1-3` — **currently identical to `main`** (0 ahead, 0 behind). Historically this was the long-lived work branch where almost all 2026-09 work landed before being merged. |
| Backup branches | `backup-pre-vt-renderer`, `backup/pre-hero-redesign`, `backup/pre-home-refactor`, `backup/pre-perf-motion-20260902-204927`, `backup/pre-phase2`, `backup/pre-revert-20260904-143605`, `backup/pre-scrub-cache-20260904-131258` |
| Release tags | `v0.7.15`, `v2`, `v3`, `v4`, `v5`, `v6`, `v7`, `v8` |
| Backup tags | `backup/pre-sync-fix-20260910`, `orivio-rename-and-redesign`, `pre-home-refactor-backup`, `pre-orivio-rename`, `pre-phase2-backup`, `pre-player-upgrade` |
| Git author | Preston Hakanson |

**There is no `.github/` directory. There are no GitHub Actions, no CI, no automated
tests on push.** Everything — build, test, package, release — is run by hand on the
owner's Mac. Do not assume a pipeline exists.

### 1.2 Working-tree state at handoff

```
M .gitignore
?? Untitled.canvas
?? ORIVIO_TV_HANDOFF.md   (this file)
```

`Untitled.canvas` is an Obsidian artifact (the repo has a `.obsidian/` folder, gitignored).

### 1.3 Release history (GitHub Releases)

| Tag | Date | Title | Assets |
|---|---|---|---|
| `v8` | 2026-09-19 | Dolby Atmos, A/V sync, audio read-out | `OrivioTV-V8.Sideload.ipa` (54.4 MB), `OrivioTV-V8.Sideloadly.ipa` (54.4 MB) |
| `v7` | 2026-09-13 | rebuilt player, disk cache, HDR fix | `OrivioTV-V7.Sideload.ipa`, `OrivioTV-V7.Sideloadly.ipa` (54.2 MB each) |
| `v6` | 2026-09-05 | redesign, SIMKL, Picture in Picture | `OrivioTV-V6.Sideload.ipa`, `OrivioTV-V6.Sideloadly.ipa` (52.2 MB each) |
| `v5` | 2026-08-27 | new native player | — |
| `v4` | 2026-08-19 | — | — |
| `v3` | 2026-07-23 | — | — |
| `v2` | 2026-07-17 | Orivio TV (rename from NuvioTV) | `OrivioTV-V2.Sideloady.ipa`, `OrivioTV-0.7.15-tvos.ipa` (50.8 MB each) |
| `v0.7.15` | 2026-07-13 | NuvioTV for Apple TV | — |

Release notes are written by hand, long-form, user-facing, with emoji section headers
(see the v6/v7/v8 bodies for the house style).

### 1.4 Licensing and lineage — **read before copying any code**

* Orivio TV (this repo) is **GPLv3**, matching upstream.
* **Upstream Android app:** `OrivioMedia/OrivioTV` — Kotlin + Jetpack Compose +
  ExoPlayer/mpv. Nothing was reusable; this tvOS app is a clean reimplementation of the
  same product, and it syncs with the same account backend.
* **Sibling tvOS project:** `github.com/bobsupra/NuvioTVOS` — a GPL-3 KMP project with its
  own tvOS client (AetherEngine / MPVKit). It has been read for *comparison and fact
  finding* (it is why `api.nuvio.tv` is understood). **Never copy its source into this
  repo — GPL-3 would infect the tree. Clean-room only: read it, learn the fact, write
  your own code.**
* Funding: <https://ko-fi.com/oriviotv> (raising for TestFlight so users don't have to
  sideload).

### 1.5 Files at the repo root

| File | Tracked? | What it is |
|---|---|---|
| `README.md` | yes | Public-facing README. **Partly stale** — its Install section still describes the v2 asset names (`OrivioTV-V2(Sideloady).ipa`, `OrivioTV-0.7.15-tvos.ipa`) and its build command still says `cp Secrets.example.swift NuvioTV/Secrets.swift` (the folder is `OrivioTV/` now). Worth fixing. |
| `SETTINGS_REFERENCE.md` | yes | **30 KB, authoritative.** Every Settings pane, row, switch and dropdown, with a "Works?" column tracing each stored property to its consumer, plus a summary table of settings that are genuinely dead. Generated 2026-09-14 at commit `85deb0e`. Read this before touching Settings. |
| `Secrets.example.swift` | yes | Template for `OrivioTV/Secrets.swift`. |
| `LICENSE` | yes | GPLv3. |
| `project.yml` | yes | XcodeGen spec — the real project definition. |
| `Config/` | yes | `Info.plist`, `OrivioTV.entitlements`, `OrivioTV-Debug.entitlements`. |
| `scripts/` | yes | `make-ipa.sh`, `probe.sh`, `record.sh`, `build-nodejs-mobile-tvos.sh`. |
| `nodeserver/` | yes | **Dead code / future plan.** An in-process Node.js P2P streaming server (nodejs-mobile). Its own README says "NOT WIRED UP" — nothing in the app references it, `Vendor/NodeMobile.xcframework` has never been built. The live P2P path is **TorrServer** (Settings → Integrations → P2P). |
| `holddiag-instrumentation.patch` | yes | A saved diagnostic patch from the hold-menu investigation. |
| `APK_LIVE_SWEEP.md`, `APK_SETTINGS_SPEC.md`, `PARITY_ROADMAP.md`, `NETFLIX_DETAILS_SPEC.md`, `NETFLIX_THEME_SPEC.md`, `THEME_SYSTEM.md` | **gitignored** | Internal design/parity notes kept locally, deliberately not published. Several describe systems that no longer exist (the whole theme system was deleted 2026-08-31). |
| `graphify-out/` | **gitignored** | A local knowledge graph / Obsidian vault. Deliberately untracked because staged notes carry the test device's UDID and LAN address. |

### 1.6 `.gitignore` highlights (and why)

* `OrivioTV/Secrets.swift` **and** `NuvioTV/Secrets.swift` are both ignored. Both paths
  are listed on purpose: during the Nuvio→Orivio rename the file moved out from under a
  single-path rule, stopped being ignored, and **got committed with real keys in it.**
* `ipa_out/`, `*.ipa`, `*.dSYM*`, `DerivedData/`, `build*/`, `_player_backup_*/`.
* `graphify-out/` and the internal spec docs, per above.

---

## 2. THE TWO IPAs — the complete story

This is the part that confuses everyone. Read all of it.

### 2.1 Why there are two

There is **one Release build**. `scripts/make-ipa.sh` packages that single `.app` twice,
and the two artifacts differ in **exactly two files** (the app's `Info.plist` and the Top
Shelf extension's `Info.plist`) and in **exactly one string in each** — the bundle
identifier. This was verified byte-for-byte against the shipped V7 pair.

| Artifact | App bundle id | Extension bundle id | Effect on install |
|---|---|---|---|
| `OrivioTV-V<ver>.Sideload.ipa` | `com.orivio.tv.appletv.dev` (left exactly as built) | `com.orivio.tv.appletv.dev.topshelf` | Installs **alongside** any previously sideloaded Orivio. Two icons on the home screen, **separate local data** (library, progress, add-ons, profiles). |
| `OrivioTV-V<ver>.Sideloadly.ipa` | `com.orivio.tv.appletv` (rewritten by the script) | `com.orivio.tv.appletv.topshelf` | **Updates an existing sideloaded Orivio in place**, keeping its library, progress and add-ons. This is the historical/distribution identity. |

Both are **unsigned for distribution**. Sideloadly / AltStore re-sign the whole bundle
with the end user's own Apple ID at install time (and uniquify the id when Apple's
registry demands it). Both are the same unsigned arm64 tvOS build (Apple TV HD and 4K,
tvOS 17+).

### 2.2 Why the project builds under `.dev` in the first place

`com.orivio.tv.appletv` is registered to a **different Apple developer team**. This
machine signs with the free Personal Team `CYCSPZ5MTR`, which cannot register that id —
every archive died on it. So:

* `PRODUCT_BUNDLE_IDENTIFIER` = `com.orivio.tv.appletv.dev` for **both** Debug and
  Release (they used to differ; see below).
* The Top Shelf extension is `com.orivio.tv.appletv.dev.topshelf`. **An app extension's
  identifier must be prefixed by its host app's** or the bundle is malformed and
  installation fails outright.
* A free Personal Team's App IDs are provisional and can become unregisterable at any
  time; `com.orivio.tv.appletv.dev` itself once did, which is why a `.devbuild` variant
  exists in some historical notes. **The current tree signs Debug and Release with the
  same `.dev` id**, because an app *extension* cannot be signed with a wildcard profile
  and the `.dev` pair (app **and** topshelf) is the one that is already registered and
  provisioned. A free team may only create ten App IDs per seven days, so burning the
  quota on a new id can block device builds for a week.
* Consequence: a local Debug run installs **alongside** a sideloaded Orivio, not over it.

### 2.3 `scripts/make-ipa.sh` mechanics (and the traps it defends against)

```bash
scripts/make-ipa.sh      # builds Release, writes both IPAs into ipa_out/
```

What it does, in order:

1. `xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS' -configuration Release -allowProvisioningUpdates build`
2. Asks `xcodebuild -showBuildSettings` for `BUILT_PRODUCTS_DIR`.
   **Trap it fixes:** an earlier version did `ls DerivedData/OrivioTV-* | head -1`, which
   picked an arbitrary, often months-stale derived-data directory — so a failed build
   still packaged an old `.app`.
3. **Refuses any `.app` older than 10 minutes.** A failed build leaves the previous `.app`
   in place, so freshness is the only thing separating a real artifact from a stale one.
   An earlier version also swallowed build failures with `|| true`.
4. Packages `Payload/OrivioTV.app` into a zip, twice. For the `Sideloadly` variant it
   rewrites the app's `CFBundleIdentifier` and then rewrites **every** `PlugIns/*.appex`
   id by taking the plugin's **last path component** and re-prefixing it — so adding a
   second extension later stays correct automatically.
5. **Reads the ids back out of the finished zip** and prints them. A silent PlistBuddy
   no-op would otherwise produce two identical IPAs that look right.
6. Version comes from `grep MARKETING_VERSION project.yml`, **not** from
   `Config/Info.plist` (which holds the literal `$(MARKETING_VERSION)`).

Output filenames: `ipa_out/OrivioTV-V<VERSION>.Sideload.ipa` and
`ipa_out/OrivioTV-V<VERSION>.Sideloadly.ipa`.

### 2.4 `LSRequiresIPhoneOS`

`Config/Info.plist` sets `LSRequiresIPhoneOS = true`, which tvOS apps normally omit.
It is there because **Sideloadly's iOS-derived IPA validator (Cydia Impactor lineage)
rejects a bundle without it** as "not a valid iOS app". It is ignored on tvOS; the binary
stays a real AppleTVOS/arm64 app and installs to the Apple TV normally. Do not remove it.

### 2.5 The Top Shelf extension and App Groups

* `OrivioTopShelf` renders Continue Watching on the tvOS home screen (Android's "Watch
  Next" equivalent). It reads a JSON snapshot from a shared App Group written by
  `TopShelfExporter`.
* The App Group is `group.com.innerapns.pubtest.CYCSPZ5MTR` — the id ends in the team id,
  so it was issued to this team, which is why the target is switched on.
* `AppGroupResolver` reads the group **from the live entitlement at runtime**, so a
  re-signing tool that swaps in its own group still works; if a signer strips the
  entitlement entirely, the container is nil and the shelf stays empty **without
  affecting the app**.
* Top Shelf files are namespaced by owning bundle id inside the team group
  (`AppGroupResolver.ownerBundleID`; the extension walks two levels up from its `.appex`)
  so the `.dev` and distribution installs don't collide.
* A PIN-locked profile is deliberately kept off the Top Shelf.
* There are **three** places in `project.yml` marked `TOP SHELF` — they move together.

### 2.6 Historical naming (v2 era)

The v2 release shipped `OrivioTV-V2.Sideloady.ipa` (for Sideloadly) and
`OrivioTV-0.7.15-tvos.ipa` (for Xcode → Devices & Simulators, or Apple Configurator).
The README still describes that pair. From v6 onward the pair is `.Sideload` /
`.Sideloadly` as described above.

### 2.7 Install rules learned the hard way

* **NEVER install onto the Apple TV while it is playing.** (2026-09-08) `devicectl
  install` during 4K DV playback plus the hybrid cache's parallel downloads ground for
  >300 s, failed with `IXRemoteErrorDomain error 6`, left the installed app record
  **broken** ("app won't open"), and then wedged the Apple TV off the network entirely
  until a power cycle. Install only between playback sessions; abort an install that
  exceeds ~60 s while the app is busy.
* **NEVER build with `CODE_SIGNING_ALLOWED=NO` for a device install.** It succeeds and
  writes a real, current binary, but `devicectl device install` then fails with
  `IXUserPresentableErrorDomain error 14` / `0xe800801c (No code signature found.)` — and
  `devicectl process launch --terminate-existing` afterwards happily relaunches the
  **previously installed** app and prints "Launched application", which reads exactly like
  success. This cost four hours and made six fixes look broken when they simply weren't in
  the binary. Use `CODE_SIGNING_ALLOWED=NO` for compile-checking **only**.
* **A `devicectl install` can finalize minutes after it reports success.** tvOS may
  migrate/re-sign the bundle after the fact, killing the launched process; the app comes
  back on its own from a different container. A probe that goes quiet a few minutes after
  an install is most likely this, not a crash.

---

## 3. Build system and toolchain

### 3.1 Requirements

* Xcode 16+ with the tvOS platform installed.
* [XcodeGen](https://github.com/yonaskolb/XcodeGen).
* `xcodebuild -downloadComponent MetalToolchain` (the Metal toolchain is required).
* First build downloads the FFmpegKit binary xcframeworks (large), pulled in transitively
  by KSPlayer.

### 3.2 Bootstrap

```bash
cp Secrets.example.swift OrivioTV/Secrets.swift   # then fill in keys (all optional)
xcodegen generate
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS Simulator' build
```

### 3.3 `project.yml` — the source of truth

`OrivioTV.xcodeproj` is **generated**. Edit `project.yml`, then run `xcodegen generate`.

Key settings:

| Setting | Value |
|---|---|
| `deploymentTarget.tvOS` | `17.0` |
| `SWIFT_VERSION` | `5.9` |
| `TARGETED_DEVICE_FAMILY` | `3` (tvOS) |
| `MARKETING_VERSION` | `8` |
| `CURRENT_PROJECT_VERSION` | `1` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.orivio.tv.appletv.dev` |
| `DEVELOPMENT_TEAM` | `CYCSPZ5MTR` (set **here**, not only in the pbxproj — Xcode's GUI writes it into `project.pbxproj`, where any xcodegen regeneration silently drops it and device builds die with "Signing for 'OrivioTV' requires a development team") |
| `CODE_SIGN_STYLE` | `Automatic` |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `false` (required by the build phases below) |

Targets: **`OrivioTV`** (app), **`OrivioTopShelf`** (app extension), **`OrivioTVUITests`**
(XCUITest bundle, simulator only).

Info.plist properties set from `project.yml`:
`CFBundleDisplayName = "Orivio TV"`, `LSRequiresIPhoneOS = true`,
`CFBundleShortVersionString = $(MARKETING_VERSION)`,
`CFBundleVersion = $(CURRENT_PROJECT_VERSION)` (literals once landed in the plist and
About reported "Version 1.0 (1)" on every build), `UIUserInterfaceStyle = Dark`,
`UIBackgroundModes = [audio]` (PiP keeps rendering when not frontmost, and **AVKit refuses
to start PiP at all without it**), `UIAppFonts` = Plus Jakarta Sans (Regular/Medium/Bold),
`NSAppTransportSecurity.NSAllowsArbitraryLoads = true`.

`LSApplicationQueriesSchemes` (so `canOpenURL` can detect external players for handoff):
`infuse`, `infuse-x-callback`, `vlc-x-callback`, `nplayer-http`, `open-vidhub`,
`senplayer`.

URL schemes registered: `orivio`, `stremio`, **and `$(PRODUCT_BUNDLE_IDENTIFIER)`**. The
third one exists because `orivio` is claimed by *every* sideload of this app on the box,
so Infuse's `x-success` callbacks and Top Shelf deep links used to land in whichever
install tvOS preferred. `AppCallbackScheme` reads the install-unique scheme back at
runtime; `DeepLinkService` accepts it alongside `orivio` (and legacy `nuvio`).

### 3.4 Build phases you must not delete

* **Pre-build — "Fix vendor framework bundle IDs at the source".** FFmpegKit ships
  `libshaderc_combined.framework` with an **underscore** in its `CFBundleIdentifier`,
  which is illegal and which Xcode's embed validation rejects. The fix rewrites the id in
  the **SPM checkout** before anything is compiled, and runs every build so it self-heals
  after a package re-resolve.
* **Post-build — "Sanitize embedded framework bundle IDs".** Belt to the above: rewrites
  and re-signs any embedded framework that still has an underscore id.
* **Build gotcha:** a stale `build/Build` fails with an invalid CFBundleIdentifier for
  `libshaderc_combined`. `rm -rf build/Build` (keep `build/SourcePackages`) fixes it.

### 3.5 Scheme environment (simulator only, but critical)

```
MTL_DEBUG_LAYER = 0
MTL_SHADER_VALIDATION = 0
```

KSPlayer's Metal renderer calls `makeTexture` and tolerates a nil result via `compactMap`
— fine on device. The **simulator** Debug run enables Metal API Validation, which
**asserts (SIGABRT)** on the same texture instead of returning nil, crashing the app
whenever video plays in the sim. These variables make the sim behave like the device.

### 3.6 Adding a new `.swift` file

`project.yml` globs `sources: - OrivioTV`, and the checked-in `.xcodeproj` has no
`PBXFileSystemSynchronizedRootGroup`. **A new file is not picked up** and fails with
"cannot find X in scope". Either run `xcodegen generate` (rewrites the whole project) or
put the code in a file already in the project. For dev-probe machinery the established
home is **`OrivioTV/Player/PlayerTempSweep.swift`** — that is *why* `PlayerProbe`,
`ColorProbeServer` and `FlightRecorder` live there.

### 3.7 Secrets

`OrivioTV/Secrets.swift` (gitignored) supplies:

| Key | Unlocks |
|---|---|
| `supabaseURL`, `supabaseFallbackURL`, `supabaseAnonKey` | The Orivio account: QR login + cross-device sync |
| `tvLoginWebBaseURL` | The web page the TV's QR points at (default `https://nuvio.tv/tv-login`) |
| `avatarPublicBaseURL` | Profile avatar images |
| `traktClientID`, `traktClientSecret` | Trakt OAuth |
| `simklClientID` | SIMKL PIN login (no secret needed) |

**Every value is optional.** With them blank the app still browses and plays through
add-ons. TMDB is deliberately *not* here — each viewer enters their own key in
Settings → Integrations → TMDB.

The Supabase `anon` key is a public client value (role=anon, RLS-enforced server side),
not a `service_role` key. Account security comes from the user logging in on the official
web page during the QR flow — **the app never sees a password** (there is also an
email/password sign-in path added in `626db82`).

### 3.8 Compile-check commands

```bash
# Simulator build
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' build

# Device compile-check ONLY (never install a binary built this way)
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -sdk appletvos CODE_SIGNING_ALLOWED=NO build

# Real device build (note -allowProvisioningUpdates; look for "Signing Identity:")
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -configuration Debug \
  -destination "id=<APPLE_TV_UDID>" -allowProvisioningUpdates build
```

**Incremental builds silently no-op in this DerivedData.** (2026-09-09) `xcodebuild`
printed `** BUILD SUCCEEDED **`, re-signed the app and updated the binary's mtime while
compiling *nothing* — so install+launch ran a stale binary and a just-written feature
"didn't work". `touch`ing the source did not help; only

```bash
rm -rf DerivedData/<proj>/Build/Intermediates.noindex/OrivioTV.build/<Config>-<platform>
```

(plus the stale `.app`) forced a real rebuild.

> **RULE: never pipe an `xcodebuild` through `grep` and then judge whether it compiled.**
> Write the full log to a file and confirm `grep -cE 'SwiftCompile|SwiftDriver' <log>` is
> non-zero before trusting any device/sim observation.

**Release configuration:** it compiles today, but it is only ever exercised when cutting an
IPA, so it drifts. It has broken twice — once because a `#if DEBUG` definition had
unconditional call sites (`FocusTrace`), once because a DEBUG-only helper was referenced
from a ternary that the type checker evaluated before the `#if` (`debugColourTags`).
**Rule: guard a DEBUG-only symbol at the call site with `#if DEBUG`, never with a runtime
condition.** Build Release before believing an IPA.

---

## 4. Dependencies

Declared in `project.yml` under `packages:`.

### 4.1 KSPlayer — **vendored** at `Vendor/KSPlayer`

Base revision `10a40a1c0001d75307ad5922d1d1bc0cb01c89b4`. Provides both the native
(`KSAVPlayer`, AVPlayer-backed) and FFmpeg (`KSMEPlayer`) engines, plus the Metal render
path, the subtitle model and FFmpegKit.

**14 local patches, all marked `// ORIVIO PATCH`.** Grep for that string before touching
anything in the vendor tree; every one of them is a fix for a reproduced bug:

| File | Patch |
|---|---|
| `MEPlayer/MEPlayerItem.swift` (×5) | *Lost-wakeup*: the check-then-wait in the reader teardown was not atomic against `shutdown()`'s single `condition.signal()`, parking the read thread forever with `state == .closed` and wedging the entire teardown (leaking ~400–500 MB per engine swap — a jetsam killer on 3 GB boxes). *Wedged seek*: an `inAVRead` flag lets the interrupt callback abort a **blocked read** when a seek is pending, without ever aborting the seek's own I/O; `reading()` swallows the aborted-read error while `state == .seeking`. |
| `AVPlayer/KSPlayerLayer.swift` (×3) | Display-link retain chain broken on engine swap (the CADisplayLink retained the view retained the `MEPlayerItem` with every cache). `MPNowPlayingInfoCenter` elapsed-time write throttled from 10 Hz to 1 Hz (it was a read-modify-write of the whole dict, with artwork and language-option groups, over XPC, on main, beside a 4K decode). Call-stack symbolication only when a trail sink is installed. Also: `audioInterrupted` `.began` now only acts **when playback is actually running** (stock called `play()` unconditionally on `.ended + .shouldResume`, overriding the app's deliberate no-auto-resume policy — this was the "random unpause"). |
| `MEPlayer/KSMEPlayer.swift` (×2) | *Side-button desync*: the route-change guard was commented out, so **every** route notification (including the `.categoryChange` a volume press or system HUD produces) re-derived every track's audio format and called `audioOutput.flush()`, dropping queued audio while the master clock ran on. Filter restored. Plus the symbolication guard. |
| `Subtitle/KSSubtitle.swift` (×2) | Parse off-thread but **publish cues on main** (`search(for:)` reads `parts` on every clock tick — swapping the array under it was a data race). `removeSubtitles(where:)` so a reload can replace a track whose download/parse failed (`addSubtitle` de-duplicates by id). |
| `MEPlayer/AudioRendererPlayer.swift` | `play()` removes a prior periodic observer before installing one — a double-play stacked a second observer and `pause()` removes only the last, so a stale observer re-stamped the clock forever. |
| `AVPlayer/MediaPlayerProtocol.swift` | Public `Chapter` memberwise init, so the app's own demux paths (DV remux, direct sample engine) can feed the same chapter machinery every other engine uses. |

Additional vendor behaviour the app relies on: `FFmpegAssetTrack` recovers colour
primaries/transfer/matrix/range from the **SPS VUI in the bitstream** when `codecpar` is
UNSPECIFIED (see §7.7). Keep `thread_count = 1` on that `avcodec_open2`.

### 4.2 YouTubeKit — **vendored** at `Vendor/YouTubeKit`

Base `e5b7d0396ce12bf3444f0d209e8436c83373b7af` (tag 0.4.9). Pure-Swift YouTube stream
extractor — the only way to play trailer YouTube keys on tvOS (no WebKit/WKWebView, so no
iframe embed).

**1 `ORIVIO PATCH`:** `YouTube.streams` called `checkAvailability()` — which parses the
watch page — *before* walking the `methods` list, so an unreadable page (consent wall /
bot check, i.e. what YouTube serves any shared VPN exit) threw `regexMatchError` out of the
entire call, taking the `.remote` extractor down with it even though `.remote` never
touches that page. **This is why trailers died the moment a VPN was switched on.** Now only
`regexMatchError` is non-fatal; a genuinely unavailable video still throws
`videoUnavailable`.

### 4.3 VLCKit

`https://github.com/tylerjonesio/vlckit-spm` from `3.6.0`, product `VLCKitSPM`. The tvOS
slice vends module `TVVLCKit`. Third playback engine.

### 4.4 libdovi — `Vendor/libdovi.xcframework`

quietvoid/dovi_tool's `dolby_vision` crate (C API), cross-compiled Rust static lib for
tvOS. Powers **Dolby Vision Profile 7 (dual-layer) → 8.1 RPU conversion**, so DV7 remuxes
get native DV output instead of the HDR10 base-layer tone-map. `embed: false`.

---

## 5. Application architecture

### 5.1 Entry point — `OrivioTV/OrivioTVApp.swift` (2,456 lines)

`@main struct OrivioTVApp: App`. Its `init()` runs, in order:

1. `OrivioRenameMigration.runIfNeeded()` — carries `nuvio.*` prefs and caches forward to
   `orivio.*` **before any store reads them**, or an existing install boots as a factory
   reset.
2. `PlayerTempSweep.sweepAtLaunch()` — reclaims orphaned player scratch space (a remux
   session that got jetsammed leaves its segment directory behind with no owner).
3. `ColorProbeServer.shared.start()` — the LAN dev probe (see §9).
4. `FlightRecorder.start()` — a recording that survives a suspend/wedge/panic.
5. `AppProbe.installLevels()` — the browse half of the probe, armed here so the tail
   covers launch itself.

### 5.2 The 21 observable stores

All created as `@StateObject` in `OrivioTVApp` and injected as `environmentObject`s:

`ThemeManager`, `AddonManager`, `ProgressStore`, `OrivioAccountManager`, `LibraryStore`,
`WatchedStore`, `ProfileStore`, `CollectionsStore`, `HomeCatalogSettingsStore`,
`TMDBSettingsStore`, `MDBListSettingsStore`, `DebridStore`, `TraktStore`, `SimklStore`,
`StremioAccountStore`, `PlayerSettingsStore`, `StreamBadgeStore`, `PluginStore`,
`TorrentSettingsStore`, `RatingsStore`, `MediaServerStore` (+ the sync managers).

> Known structural cost: `RootView` observes ~24 stores, so any store publishing
> re-renders the root. Deliberately not refactored.

### 5.3 Navigation

* **Tabs** — `AppTab` (in `Screens/GlassSidebar.swift`): `home, search, library, settings,
  liveTV`. Rail render order is `[home, search, library, liveTV, settings]`.
* **`GlassSidebar`** — always-visible left rail. Collapsed it is a floating Liquid Glass
  pill (84 pt wide, 36 pt icons) vertically centred, hugging the screen edge at absolute
  x≈28 via `.ignoresSafeArea(edges: .horizontal)`. Focus entering it expands a full-height
  300 pt glass panel (profile chip, labelled rows) over a 0.55 dim. Uses
  `glassEffect(.regular, in:)` on tvOS 26 with an `.ultraThinMaterial` fallback
  (deployment target is tvOS 17).
* **`Route`** (in `OrivioTVApp.swift`) — per-tab `NavigationStack` destinations:
  `detail`, `streams`, `streamsManual` (hold-Play: always show the list even with Auto
  Link on), `streamsInfuse` (resolve then hand off to Infuse), `streamsFromStart`,
  `streamsResume(fromStart:)`, `collection`, `person`, `tmdbCompany`, `catalogSeeAll`,
  `discover`, `cloudLibrary`, `mediaServerShow`. Each `Route` also exposes `probeName` /
  `probeDetail` so navigation is visible in the live probe.
* The player is presented as a `fullScreenCover` over the root.

### 5.4 Design system (post-2026-08-31)

On 2026-08-31 **all themes were deleted** (32 files: Hulu/, Max/, Stremio*, CinemaHome,
OnyxHome, NetflixNav, SidebarNav, ThemedDetailView, ThemedProfileGates, theme token files,
PlayerControlsOverlay) and replaced with one Apple-TV-native look:

* **Home** = the former Fusion "modern" layout, promoted to the only layout. Hero scrolls
  with content, rotating TOP-10 spotlight, `FusionHeroBar` "Featured" strip,
  `ATVCardCaption` under every card, native `CardButtonStyle` platter + accent glow.
* **Player** = the Fusion overlay only (later rebuilt again to the Infuse spec, §7.10).
* **`ThemeManager`** now carries only: accent palette, AMOLED, font, `experienceMode`,
  `settingsUiStyle`. `ThemeSnapshot` keeps the retired fields (`appThemeID`,
  `detailStyle`/`profileStyle`/`playerStyle`, `atvAppearance`) **so synced blobs still
  decode**; `applyRemote` ignores them. `isXTheme` flags remain as hardcoded-false stubs.
* **Accent palettes** (`Theme/OrivioTheme.swift`, `enum OrivioThemes`): crimson, ocean,
  violet, emerald, amber, rose, white, lavender, mint. **White, Lavender and Mint are the
  light fills** and are where accent bugs hide — an accent-filled control's label must use
  `palette.onSecondary`, never a literal `.white`.
* **`ExperienceMode`**: `essential` | `advanced` (Advanced reveals engine/OSD/tuning
  controls and the Plugins pane). **`SettingsUiStyle`**: `classic` | `zen` | `horizon`
  (row/card corner radius only).

#### Liquid Glass — the rule that cost a debugging round

`glassEffect` **wrapping focusable content makes it invisible to the tvOS focus engine**.
The detail page's action row became a total focus trap (every direction dead). **Glass must
always be a BACKGROUND view**: `.background(Color.clear.liquidGlass(in: shape))`. The
shared `liquidGlassIf` helper in `Components` enforces this; plain `liquidGlass(in:)` is
safe only on non-focusable content.

### 5.5 Screens (`OrivioTV/Screens/`, 34 files)

| File | Lines | What it is |
|---|---:|---|
| `HomeView.swift` | 3,558 | Hero billboard (rotating spotlight, trailers), catalog rows, Continue Watching, Next Up, Live Channels row, collections rows, pinned/hybrid hero layouts |
| `DetailView.swift` | 2,077 | Full-bleed backdrop, logo, meta badges, cast, season picker, episode rows, backdrop trailer, hold menus |
| `StreamsView.swift` | 2,001 | The source list: parallel fan-out to every stream add-on + plugins + debrid resolution + the four auto-select paths |
| `SettingsView.swift` | 1,952 | Settings root/body |
| `AccountView.swift` | 1,387 | Orivio account, QR login, profiles entry |
| `SettingsLayoutView.swift` | 1,307 | Layout pane + the collection editor |
| `CollectionView.swift` | 1,259 | A collection: Categories (row-per-folder) or Grid mode |
| `ProfilesView.swift` | 966 | Profiles, PIN, Auto Link Selector preferences |
| `SettingsIntegrationsView.swift` | 989 | TMDB, MDBList, debrid, P2P, Plex/Jellyfin |
| `CommunityCollectionsView.swift` | 809 | Community collection presets |
| `SettingsTraktView.swift` | 633 | Trakt + SIMKL |
| `SettingsPlaybackView.swift` | 589 | Playback pane |
| `LiveTVView.swift` | 524 | IPTV channels + favourites |
| `CollectionSourcePickerView.swift` | 435 | Add sources to a collection folder |
| `SearchView.swift` | 326 | Native tvOS search across search-capable catalogs + Trending idle grid |
| `AddonDiscoverView.swift` | 323 | Community add-on catalog browser |
| `MediaServerLibraryView.swift` / `MediaServerConnectViews.swift` | 322 / 319 | Plex & Jellyfin |
| `SettingsPerformanceView.swift` | 296 | Performance pane + dev probes |
| `GlassSidebar.swift` | 273 | The rail |
| `LibraryView.swift`, `DiscoverView.swift`, `WelcomeView.swift`, `AddonPhoneAddView.swift`, `CloudLibraryView.swift`, `PosterHoldMenu.swift`, `FusionHeroBar.swift`, `ATVSettingsView.swift`, `CatalogSeeAllView.swift`, `CastDetailView.swift`, `TMDBBrowseView.swift`, `EmailSignInView.swift`, `SettingsPluginsView.swift`, `SettingsStremioView.swift` | — | as named |

### 5.6 Core services (`OrivioTV/Core/`, 54 files)

Grouped by job:

* **Add-on protocol / content** — `Models.swift` (1,305: `AddonManifest`, `ManifestCatalog`,
  `InstalledAddon`, `MetaItem`, `MetaVideo`, `Stream`, `StreamEntry`, `ReleaseDateParser`,
  `SeasonEpisode`), `StremioAPI.swift`, `AddonManager.swift`, `AddonCatalogService.swift`,
  `AddonImportServer.swift`, `StreamBadges.swift`, `StreamTitleMatcher.swift`,
  `SourceSelection.swift`.
* **Metadata / enrichment** — `TMDBService.swift` (1,628), `MDBListService.swift`,
  `RatingsStore.swift`, `ParentalGuideService.swift`, `AnimeSkipService.swift` (+ IntroDB
  merged in).
* **Playback sources** — `DebridService.swift` (Real-Debrid, Premiumize, TorBox,
  AllDebrid), `TorrServerService.swift`, `MediaServerService.swift` (Plex PIN flow via
  `plex.tv/link` + resources + `/identity` probe; Jellyfin `AuthenticateByName`),
  `M3UService.swift`, `LiveStreamResolver.swift`, `LiveStreamOptions.swift`,
  `LiveChannelFavorites.swift`, `CloudLibraryService.swift`, `ExternalPlayers.swift`.
* **Plugins** — `Plugins/PluginRuntime.swift` (JavaScriptCore host for Orivio JS scrapers:
  `getStreams(tmdbId, mediaType, season, episode)`, with `console.*`, an async `fetch`
  bridged to URLSession, `atob`/`btoa`, `setTimeout`, optional crypto-js/cheerio),
  `PluginStore.swift`, `PluginModels.swift`.
* **User data stores** — `ProgressStore.swift` (1,611), `LibraryStore.swift`,
  `WatchedStore.swift`, `CollectionsStore.swift` (1,132), `CollectionResolver.swift`,
  `ProfileStore.swift` (+ `ProfileScopedDefaults`), `HomeCatalogSettingsStore.swift`,
  `PlayerSettingsStore.swift`, `PerformanceSettingsStore.swift`,
  `TorrentSettingsStore.swift`, `LiveTVSettingsStore.swift`.
* **Accounts & sync** — `OrivioAccount/` (`OrivioAccountManager`, `OrivioSyncManager` at
  3,965 lines, `OrivioSyncModels`, `OrivioAuthModels`, `OrivioConfig`,
  `OrivioLocalBackupService`, `OrivioSyncDiagnostics`, `QRCode`), `TraktService`,
  `TraktSyncManager`, `SimklService`, `SimklSyncManager`, `StremioAccount`,
  `StremioSyncManager`, `StremioAPI`, `SyncCoordinator`.
* **Infrastructure** — `MediaCacheServer.swift` (3,245 — the hybrid disk cache),
  `PerformanceProfile.swift`, `RequestCache.swift`, `BoundedConcurrency.swift`,
  `ContentFocusRouter.swift`, `DeepLinkService.swift`, `AppGroupResolver.swift`,
  `TopShelfExporter.swift`, `KeyHandoffServer.swift`, `DiagnosticsService.swift`,
  `HoldProbe.swift`, `AudioLanguageMatch.swift`, `OrivioRenameMigration.swift`.

---

## 6. Content model — the Stremio add-on protocol

### 6.1 Add-ons

An add-on is a `manifest.json` URL. `AddonManager` keeps the installed list; **Cinemeta
ships installed by default**, and any add-on can be added by pasting its manifest URL in
Settings (or a `stremio://` link, or via the QR "Add from Phone" flow —
`AddonImportServer` + `AddonPhoneAddView`).

`StremioAPI` exposes exactly five calls:

| Call | Endpoint shape | Cache TTL |
|---|---|---|
| `manifest(url:)` | the manifest itself | app cache |
| `catalog(...)` | `/catalog/<type>/<id>[/<extras>].json` | app cache |
| `meta(addon:type:id:)` | `/meta/<type>/<id>.json` | app cache |
| `streams(addon:type:id:)` | `/stream/<type>/<id>.json` | `ttl: 0` — links are short-lived |
| `subtitles(addon:type:id:)` | `/subtitles/<type>/<id>.json` | `ttl: 600` |

**Two caching traps, both fixed, both worth knowing:**

1. `ttl: 0` did **not** mean "don't cache". The request inherited
   `.useProtocolCachePolicy` from a shared `URLSession` with a **256 MB disk `URLCache`**,
   so stream responses were stored and replayed **across launches**, serving dead debrid
   links without a request ever reaching the server. This was the "AIOStreams source
   failed while the server is demonstrably up, across relaunches, clears on its own later"
   report. Fix: `if ttl == 0 { request.cachePolicy = .reloadIgnoringLocalCacheData }`, plus
   the same on the `bypassCache` health-check path.
   > **RULE: in this app, "we chose not to cache it" means the APP cache only. Anything
   > that must be fresh has to say so on the `URLRequest`.**
2. A subtitle add-on that is rate-limited answers **200 with `{"subtitles":[]}`**, which
   looks like a good response and got cached for ten minutes in memory. Now an empty list
   is evicted (`StremioResponseCache.remove(_:)`).
   > **PATTERN: "works again after a restart" = in-memory state. "Survives a restart but
   > clears later" = the disk `URLCache` or a TTL.** That single distinction has named the
   > root cause of three separate reports.

Other add-on facts:

* `AddonCatalogService` pulls the live community catalog from
  `v3-cinemeta.strem.io/addon_catalog/all/{official,community}.json` (verified alive;
  7 + 95 entries).
* Catalog `extras` must be encoded **unreserved-only** or `Law & Order` /
  `Action & Adventure` get truncated.
* `normalizeManifestURL` splits the query off (three copies of this exist, plus
  `Models.baseURL`).
* Manifest decoding is deliberately **lenient**, which created a real bug: a 200 that
  isn't a manifest (captive portal, CDN error, WAF body) decodes into a manifest with no
  catalogs and no resources (`isPlaceholder`), and `refreshManifests` used to write it over
  the good entry and `save()` it — silently emptying an installed add-on until relaunch.
  Now: keep what we have unless the answer is better; stamp `lastRefreshKey` only when at
  least one fetch succeeded; the same guard in `resolvePlaceholders`, which now also runs
  on `scenePhase == .active`.
* Add-on manifests are stored **in full** in `orivio.addons.v1[.pN]`. One real Xperience
  profile is 746 catalogs ≈ **270 KB of JSON per profile**. Since 2026-09-17 the blob is
  stored **zlib-compressed** behind a 4-byte `OAZ1` magic (260 KB → 14.4 KB, 18×). See §8.6.

### 6.2 `MetaItem` / `MetaVideo`

`MetaItem` is the title (id, type, name, poster, `posterFallback`, background, logo,
description, cast, genres, `videos`, release info, …). `MetaVideo` is an episode
(`<id>:<season>:<episode>` in Stremio form). `ReleaseDateParser` handles aired/unreleased
logic with **static cached formatters** (per-call formatter allocation in per-episode hot
paths was a measured cost).

`posterFallback` exists because Xperience's poster provider prints "In Cinemas"-style
banners *into* the poster; every meta also carries a clean TMDB poster, and
Settings → Layout → Posters → "Poster banners" (default ON) swaps them.

### 6.3 `Stream` → `StreamEntry`

`Stream` is the raw add-on stream object (url / `infoHash` + `fileIdx` / `externalUrl`,
`name`, `title`, `description`, `behaviorHints` incl. `filename` and proxy headers).

`StreamEntry` wraps it with **precomputed** display strings (`displayName`,
`displayDetail`, `resolutionLabel`, `fileSizeLabel`, `sizeBytes`, `isInstant`,
`sourceScore`) — computing them in row bodies (regex + string builds × visible rows ×
focus moves) was the main Sources-page scroll cost.

Two identity properties that matter enormously:

* **`sourceAddonName`** — the add-on name with any resolver prefix stripped (text after
  the last `" · "`). A debrid/P2P resolve relabels the entry it hands the player
  (`"RD · Torrentio"`, `"P2P · Torrentio"`) while every other copy keeps the plain name,
  so comparing labels with `==` **never matched for any debrid user** — which sent
  same-add-on failover to a *different* add-on instead of the next link from the one the
  viewer was on.
* **`rejectionKey`** — identity that survives between sessions: `hash:<infoHash>#<fileIdx>`
  → `file:<addon>|<filename>` → `name:<addon>|<display>|<detail>`. **Not the URL**: a
  debrid link is freshly signed on every resolve.

`fileIdx` is honoured **only for Real-Debrid and TorrServer**, where the provider's file
list is the torrent's own in original order. Premiumize, TorBox and AllDebrid filter or
renumber, so a naive mapping plays the wrong file; those fall back to an
SxxExx-then-largest heuristic.

`Stream.RangeRefusingAddons` (persisted, key bumped to `.v2`) records an add-on whose links
answer an HTTP **status** to a range GET after all recovery attempts — never on **416**
(Range Not Satisfiable means *our* range was wrong) and never on a dropped connection. A
server that genuinely can't do ranges answers **200 with the whole body**. Both auto-pick
filters exclude a listed add-on; manual taps still play it.

### 6.4 Torrents

`infoHash`-only streams are filtered out of direct playback (there is no in-app torrent
engine on tvOS). The live P2P path is **TorrServer** (Settings → Integrations → P2P).
Debrid-resolved HTTP links work normally. `nodeserver/` is an unfinished alternative
(see §1.5).

---

## 7. THE PLAYER

This is the heart of the app and where nearly all of the hard-won knowledge lives.
`Player/PlayerViewModel.swift` alone is **11,383 lines**.

### 7.1 Four engines

| Engine | Class | Used for | Can bitstream Dolby? | Can PiP natively? |
|---|---|---|---|---|
| **Native** | `KSAVPlayer` (AVPlayer) | HLS, MP4, M4V, MOV, fMP4 | **Yes** (AC-3 / E-AC-3) | Yes (`AVPlayerLayer`) |
| **FFmpeg** | `KSMEPlayer` | MKV, AVI, FLV, TS, everything else; embedded text + PGS/VobSub subtitles | **No — always decodes to LPCM** | No (sample-buffer layer) |
| **VLC** | `VLCEngine` (TVVLCKit) | Manual fallback for files choppy on the others; renders its own subtitles; buffers internally (no cache bar) | No | No (no CALayer at all) |
| **DV direct sample feed** | `DVSampleEngine` (3,611 lines) | Dolby Vision **and** Dolby-audio MKVs: FFmpeg demux → CMSampleBuffers → `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` | **Yes** (AC-3 / E-AC-3 / AAC; decodes everything else) | No (sample-buffer layer) |

`PlayerEngine` (in `PlayerSettingsStore.swift`): `auto | native | ffmpeg | vlc | external`.
`auto` picks AVPlayer for MP4/HLS and FFmpeg for MKV & friends, with the other as
automatic fallback. `external` hands every stream to another installed app (Infuse, VLC,
nPlayer, VidHub, SenPlayer) via its public URL scheme.

`PlaybackMode` (Settings → Playback): `automatic` (default) · `fidelity` (never downgrade;
forces P7 conversion even where the tier default says no) · `compatibility` (skip the DV
path entirely, HDR10-mapped decode, standard audio engine).

Every meaningful branch records a line in `PlaybackDecisionLog` (`stage`, `choice`,
`reason`) which is shown verbatim in the info panel, mirrored to `NSLog`, to the colour
trail and to the live probe. **A player that can explain itself is debuggable from the
couch.**

### 7.2 Engine selection and the DV/Atmos preflight

`shouldTryDVFirst(url:)` gates the direct sample engine. It requires:

* engine preference is `auto` or `ffmpeg`, the URL is remote, memory footprint < 850 MB,
  and this URL has not already failed or been tried for DV;
* the container is **not** mp4/m4v/mov/m3u8 (those play DV *and* Dolby audio through
  AVPlayer as-is);
* **and** one of two hints from the add-on's stream name/title/description:
  * **video hint** — `\b(dv|dovi|dolby)\b` **and** the display advertises a DV mode;
  * **audio hint** — `\b(atmos(?!phere)|joc|ddp|dd\+|e-?ac-?3|ec-?3|ac-?3|true-?hd)`.
    Note: **no trailing `\b`** (release names glue codec to layout: `DDP5.1`, `DD+`,
    `E-AC3`), the `(?!phere)` lookahead keeps a film called *Atmosphere* from buying a
    probe, and `ac-?3` is safe because `\b` will not start inside a word (checked against
    AAC, AAC5.1, FLAC, DTS-HD, x264, "MAC3S").
* **`DolbyMemory`** (in `PlaybackMemory.swift`) supplements the name: a play that *saw*
  multichannel E-AC-3/AC-3 with HEVC remembers the title, so the **next** play takes the
  passthrough engine even when the release name says nothing about audio. It also records
  the **negative** ("a probe looked and found nothing usable") so a wider hint costs one
  probe per title **ever**, not per play. An audio negative clears the **audio** reason
  only — never the Dolby *Vision* path, which is judged separately.
* Audio-only entries get a **3 s** preflight budget; a DV title keeps **5 s**.

`StreamProbe` reads the container header (DV config record `AV_PKT_DATA_DOVI_CONF` →
`AVDOVIDecoderConfigurationRecord`, duration, audio eligibility, `hasAVC`, `isPQ`,
`isFEL`). Its reconnect ladder is **bounded** (commit `88e6a85`) — an unbounded FFmpeg
reconnect on an unreachable tail read once contributed to an out-of-memory **kernel
panic** on the 3 GB box.

Tier order with automatic fallback: **DVSampleEngine → FFmpeg (`KSMEPlayer`) → VLC**, with
Native used directly for native-friendly containers. `fallBackFromDirect(reason:)` is the
single funnel out of the direct engine, and its reason string is surfaced.

### 7.3 `DVSampleEngine` — the bespoke engine

**Why it exists.** The original DV path was: remux with FFmpeg → serve over a loopback
HTTP HLS playlist → AVPlayer. It produced true DV output but **CoreMedia retains every
byte it fetches over that path, process-scoped and unreleasable**, measured live at the
fetch rate until jetsam (proven: an `AVPlayerItem` recycle returned *zero* memory). That
tier is **retired** (commit `019f7b5`); do not rebuild it.

**What the direct engine does instead** — the Infuse/SenPlayer architecture:

FFmpeg demux → (libdovi P7→8.1 RPU conversion inline when needed) → wrap each compressed
HEVC access unit in a `CMSampleBuffer` tagged with a Dolby Vision format description
(`dvh1` + a 24-byte `dvvC` config record; compatibility id 1 for 8.x, 0 for 5, 4 for HLG) →
enqueue into `AVSampleBufferDisplayLayer`, with `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`. Memory is the app's own bounded queue: **~155 MB flat**
versus 900–1450 MB on the remux path.

Key mechanics and every trap found in it:

* **VT decode-ahead (`vtDecodeAhead`).** Obsession-class encodes use 7-consecutive-B
  groups (83 % B, reorder depth ~8). `AVSampleBufferDisplayLayer`'s just-in-time decoder on
  A10X emits those in bursts (~3 boundaries/s at 24 fps) — measured with 240 fps slo-mo of
  the panel as ~3 true repeat+catch-up pairs per second, while every clock/queue/vsync/PTS
  probe read perfect. Fix: a `VTDecompressionSession` decoding synchronously on the feed
  path, a display-order heap with an 8-frame reorder holdback, and the layer receiving
  finished pixel buffers. Compressed cap 120 in VT mode. **User-confirmed smooth.**
* **H.264 must NOT use decode-ahead.** With `decodeAheadActive` on, H.264 decoded 120
  frames cleanly (0 VT errors) and rendered **black** while audio played. `decodeAheadActive
  = … && !videoIsAVC` routes H.264 to the compressed feed where the display layer decodes
  it natively. Decode-ahead exists only for HEVC burst-B smoothing and DV NAL work.
* **H.264 shape gate** (all must hold, else return a reason → fall back to FFmpeg): `avcC`
  extradata (`extra[0] == 1`, not Annex-B); progressive (`field_order`); square pixels
  (SAR); **no DOVI config** on the track (DV Profile 9 is AVC-based — a `dvh1` description
  around `avcC` succeeds and then plays black); and the **selected** audio track is
  E-AC-3/AC-3 (not merely "the file has one" — language/label bonuses can pick TrueHD/DTS).
* **PTS grid.** `gridFrameDuration` used to fold everything in 23.5…24.2 onto 1001/24000,
  so a **true 24.000** film was snapped against a frame duration 0.042 ms too long;
  `snapVideoPTS` passes >2 ms deviations through raw, so the engine alternated between
  re-timing and not, handing the synchronizer a step change at every crossing. Proven by
  the engine's own census (`480 frames, 432 off-grid, worst 20.3 ms` = exactly half a frame
  at 24 fps; 2/20.83 ms = 10 % in-window, measured 48/480). Fixed in `894edce` by splitting
  each NTSC/integer pair at its midpoint; `videoFPS` is `av_q2d` of the stream's rational so
  24.0 and 23.976025 are distinguishable. Same shape for 30 vs 29.97 and 60 vs 59.94.
* **Preroll gate** counts decoded frames when decode-ahead is active
  (`depth = max(videoQueue.count, heap + framesToLayerSinceFlush)`) — counting the
  *compressed* queue meant VT drained it instantly for light content and the clock never
  started (25 s watchdog failover). Also requires `audioResumeCushion`, not just video.
* **Cold-start resume**: `startAt > 1` sets `pendingSeekTo` + `seekRefill` at open, or a
  resume could start the clock on all lead-in and freeze (invisible on 1–2 s HEVC-remux
  GOPs, guaranteed on x264 `keyint=250`). Device-verified at 120 s on both codecs.
* **Audio**: decode-to-LPCM for anything not bitstreamable. TrueHD emits ~40-sample frames
  = 1200 buffers/s which silently choke `AVSampleBufferAudioRenderer` — **quarter-second
  batching** fixed it. Multichannel LPCM **requires an `AudioChannelLayout`** or it is
  silent. AAC needs `codecpar` extradata as the `CMAudioFormatDescription` magic cookie.
* **Underrun hold**: audio only counts as starving when
  `lastAudioHandedEnd − clock < audioHoldLead (1.0 s)`. Before that, a hold fired on
  `aqDepth == 0` while the renderer still held ~3.9 s, because the single demux thread
  parks on the full video queue — 4 half-second freezes in 8 minutes.
* **Seek**: packets read across a seek generation are discarded (this was the "jumps back
  then fast-forwards" scrub bug). `seekRefill` no longer requires `rate > 0` to clear.
* **EOF**: the demux thread **parks** at EOF instead of exiting, so a seek in the last ten
  seconds is serviceable; `seek()` clears `demuxEOF` inside the same lock hold that empties
  the queues.
* **Leak class**: the engine once self-retained through the VM's `onTime`/`onBuffering`/
  `onEnded`/`onError` closures (VM captured `engine` strongly for identity checks while the
  engine stored the closures), and `stop()` never emptied the 240-AU queues — ~80 MB per
  retired engine, forever. Now `stop()` clears queues and nils callbacks; the VM captures
  weakly.
* **Known off-main access:** `installFeeders` touches `UIView.layer` (`videoView.displayLayer`)
  inside `feedQueue.async` — Main Thread Checker has caught it twice. Still open.

### 7.4 Audio: Dolby / Atmos passthrough

**tvOS rule to keep:** tvOS bitstreams **AC-3 and E-AC-3 (Atmos/JOC included) and nothing
lossless** — TrueHD and DTS-HD always decode to PCM. **Never label a TrueHD session Atmos.**

Atmos was playing as PCM because of three independent defects, all now fixed:

1. **Both passthrough renderers excluded multichannel.**
   `allowedAudioSpatializationFormats` defaults to `.monoAndStereo`; `AVPlayerItem`
   (KSAVPlayer) and `DVSampleEngine`'s `AVSampleBufferAudioRenderer` both left it there.
   Nothing ever called `setSupportsMultichannelContent(true)`, and
   `KSOptions.isSpatialAudioEnabled` actively called it with `false` on any route reporting
   no spatial audio — which is exactly what an HDMI receiver that decodes Dolby itself
   reports.
2. **The bitstreaming engine was reachable only for Dolby *Vision* reasons** (see §7.2 —
   the audio hint now qualifies on its own).
3. **TrueHD beat DD+ in the engine's ranking** (score was `channels * 10` with no codec
   awareness), so a UHD remux's TrueHD 8ch won over the E-AC-3 JOC 6ch compatibility track
   — and TrueHD goes down the decode branch. Now E-AC-3 gets **+60** and AC-3 **+5**,
   multichannel-only so stereo never jumps the queue.

Also: `downmixToStereo` is driven by `maximumOutputNumberOfChannels` (the capability), not
`isSpatialAudioEnabled` (a spatialization question), and is **re-checked once at the first
decoded frame, one-way** (it can relax a fold, never introduce one) because the route
renegotiates on asset load. `setPreferredOutputNumberOfChannels` is set on the **decode
path only** — asking the session for an N-channel PCM output while bitstreaming is an
invitation to decode the stream you are passing through.

**Atmos tunnels through a 2-channel MAT carrier**, so `maximumOutputNumberOfChannels` can
legitimately be 2 on a *working* Atmos chain. The `[atmos]` verdict no longer consults the
route's channel count. A soundbar stuck at stereo PCM after a reboot is an HDMI handshake
problem — power-cycle the sink or flip the Apple TV's audio format once (the diagnostics
say this when multichannel PCM meets a 2ch route).

**Known gap:** an H.264 + DD+ title whose add-on stream name carries **no** audio hint
never bitstreams, on any play (`noteDolbyCapability` is HEVC-only by design, and only the
engine's own success writes `DolbyMemory.remember`, which needs the hint to get there).
Real release names almost always carry the token.

**MKV E-AC-3 JOC: the `dec3` box is the gate (2026-09-20).** The sample-feed path hands
compressed E-AC-3 to `AVSampleBufferAudioRenderer`, which DECODES it — the receiver sees
PCM and the objects are gone. The AVPlayer route (`Player/AtmosHLS.swift`, Settings →
Playback → "Dolby Atmos passthrough") re-muxes the E-AC-3 into fMP4/HLS so AVPlayer emits
Dolby MAT. Two defects kept it from working:

1. `DVSampleEngine.streamSaysAtmos` read only the track's text tags, and Matroska
   remuxes tag the track "English · EAC3 · 5.1" — never "atmos". FFmpeg 6.1 sets
   `AVCodecParameters.profile == 30` (`FF_PROFILE_EAC3_DDP_ATMOS` /
   `FF_PROFILE_TRUEHD_ATMOS`) from the JOC extension; that is now the primary signal.
2. FFmpeg 6.1's `mov` muxer writes `dec3` without the JOC complexity index (upstream
   added it in master; jellyfin-ffmpeg backported it; FFmpeg trac #9996). Without it
   tvOS plays the remux as plain DD+ and never lights "Dolby Atmos". `AtmosDec3`
   rewrites the box in the JOC layout before the init segment is served.

The remuxer also carries the track the PLAYER selected (not merely the first E-AC-3), so a
5.1 Atmos + 2.0 commentary file cannot remux the wrong one.

**Audio language policy (settled 2026-09-15):** the **Settings language always wins**; the
per-title memory survives as a *fallback* for files carrying nothing in the chosen
language. Implemented in all four places: `loadTracks` (KSPlayer),
`applyPreferredVLCAudioIfNeeded`, DV engine construction, and
`applyPreferredDVAudioSecondTurn` (which now rescues with the **remembered** language when
the Settings language is absent). Previously the per-title memory (keyed by **show**, no
TTL, no way to clear) outranked Settings forever, so one hand-pick on one episode pinned
that language for the whole series.

`AudioLanguageMatch` is the shared matcher (real language tag is definitive, label fallback
is whole-word only, alias table covers 639-2/T vs /B: ger/deu, fre/fra). **Never use
`name.contains(code)`** — "es" matches "Chinese" and "Japanese".

**Audio Sync** (per title, Audio tab): `PlayerViewModel.audioSyncOffset`, ±50 ms…±2 s,
persisted in `TitleMemory.audioSyncOffset`. Wired as `currentOptions.videoDelay = -offset`
on KSPlayer (desire = master − videoDelay, so positive videoDelay = video later ≡ voices
earlier — hence the negation), `vlcEngine.player.currentAudioPlaybackDelay = offset µs` on
VLC, and `DVSampleEngine.setAudioDelay` (re-stamps audio PTS then re-anchors with
`seek(to: position)`) on the direct engine. Proven applied on both engines by measurement;
small steps are genuinely hard to see (ITU BT.1359 lag detectability ≈125 ms).

### 7.5 A/V sync and frame pacing (FFmpeg engine only)

Audio ran ~250 ms ahead of video on **every** title. Three causes:

1. **There is no frame scheduler, and the pump ran at the wrong rate.** `MetalPlayView`
   enqueues every picture with `presentationTimeStamp: .zero` +
   `kCMSampleAttachmentKey_DisplayImmediately`, so **the display-link callback cadence *is*
   the on-screen cadence**. `KSOptions.preferredFrame` (default true) then asked the link
   for a preferred **24 Hz**; a 60 Hz panel only delivers 60/N so it landed on 30 Hz, and
   23.976 content was presented on a 30 Hz grid (33/67 ms holds instead of an even 2:3).
   A gate presenting ≤30 fps also cannot outrun a 24 fps decoder, which is why the offset
   never converged. **Fix: `KSOptions.preferredFrame = false`** (one line, in the statics
   block of `configureOptions`).
2. **The sync gate's dead zone is asymmetric.** `KSOptions.videoClockSync` holds video
   *early* until within half a frame (~20 ms) but shows video *late* with no correction
   until `4/fps` = **167 ms** at 24 fps; the app's `pulldown60Hz` softening suppresses 2 of
   every 3 catch-up drops while `diff > -0.5`, widening the uncorrected band to 500 ms. Fix:
   a converging servo in the app's override returns `.dropNextFrame` once when `diff` has
   been worse than 1.5 frame durations for a sustained window. Gated on `frameCount >= 2`
   because `frameCount` is the **decoded queue depth** and `.dropNextFrame` shows the head
   then discards the one behind it.
3. **Side buttons flushed the audio** — the vendored `KSMEPlayer.audioRouteChange` patch
   (§4.1).

Diagnostic: `/probe` `[engine]` prints `ks: fps=<displayFPS> dropped=… avSync=…`. **A
pinned, never-correcting negative `avSync` IS the "audio early" report** (negative = the
picture is late).

**`decodeStalls=0` is the answer to "is it the cache?"** — `[DVSample] vsync probe: …
decodeStalls=N` means the renderer was never starved. repeats+skips with `decodeStalls=0`
is **pacing**, not supply. Read that field before blaming buffering or the disk cache on
any stutter report.

**Also settled:** the "Obsession stutter" saga ended in vsync-level probes proving
bit-perfect presentation (240 refreshes per 10 s window, 0 repeats, 0 skips, ±21 ppm) — the
judder was baked into that encode. Don't re-open it without a different **file size**.

### 7.6 Display mode / HDR — the Match-Content model (as of 2026-09-14)

This is the streaming-app standard and should not be "improved" again without cause:

1. **The gate is tvOS's own switch**: `displayManager.isDisplayCriteriaMatchingEnabled` ==
   Settings → Video and Audio → Match Content. **The app's own toggle was removed.**
2. On playback the app hands tvOS `AVDisplayCriteria(refreshRate:videoDynamicRange:)` with
   the content's rate (snapped by `snapToBroadcastRate`, which distinguishes 23.976 from 24)
   and the content's range **clamped to what the panel advertises** (DV → HDR10 → HLG →
   SDR). Asking for **both halves is correct**: tvOS applies whichever of Match Dynamic
   Range / Match Frame Rate the viewer enabled.
3. **One switch per playback**, via `SessionDisplayMode.applyOnce(rate:range:)`. Its job is
   to stop the DV-first → FFmpeg-fallback sequence switching twice in seconds, and to stop
   consecutive episodes re-switching to the same format. The pin records **both**
   `pinnedRate` **and `pinnedRange`** — it used to be range-blind, so only the **first
   title of each foreground stint could set the dynamic range**, and a DV title opened after
   any HDR10/SDR title played out as plain HDR (and a DV-only Profile 5 file, whose IPT
   colour is meaningless outside DV mode, came out broken).
4. **On exit** `releaseDisplayForExit()` → `SessionDisplayMode.releaseForExit()` clears the
   criteria and the pin, over a **black cover**, **after** the video surface is detached
   (opaque cover → 250 ms → `prepareForExit` detaches → release → 0.8 s settle → dismiss).
   Without this the whole UI stayed at the film's refresh rate (menus and scrolling
   quantised to 41 ms).
5. Next playback negotiates fresh.

> **⚠️ THE GREY-WEDGE HISTORY.** The exit revert was previously **disabled** because a
> revert landing while the video surface was torn down **wedged the owner's own TV panel
> grey until power-cycled**. It was re-enabled deliberately, sequenced over a static black
> screen, with the safety argument that `releaseForExit()` is byte-for-byte what the
> background observer already does on every Home press. **If the grey wedge returns, the
> escape is one line:** return `0` from `exitDisplaySettleDelay` and drop the
> `SessionDisplayMode.releaseForExit()` call. Both are commented in place.
>
> **Do NOT add a display release to `teardown()`** — it runs for retired sessions while
> another plays, with no black cover.

**`OrivioPlayerOptions.matchFrameRate` is dead code** — declared, assigned from settings,
read nowhere. The rate request is unconditional. Left in place deliberately.

**Capability rule:** `p7ok = activeMode == .fidelity || PerformanceProfile.recommendsDolbyVisionProfile7`;
`wantHDR10Plus = PerformanceProfile.supportsHDR10Plus && activeMode != .compatibility`;
native DV is gated by `DynamicRange.availableHDRModes.contains(.dolbyVision)`.
> **RULE FOR THIS APP: a capability feature is gated by hardware, never by a toggle and
> never unconditionally.**

Diagnostic: the colour trail's `display gate` line prints `pin=…` and `panelSupports=[…]`
together. `panelSupports` without `dolbyVision` means the **system** doesn't report DV for
that TV/ATV combination — a different problem from the pin.

### 7.7 Colour accuracy

**Root cause of "FFmpeg isn't colour accurate" (device-verified):** untagged HEVC remuxes
(2160p/1080p 10-bit, `spc`/`pri`/`trc` all UNSPECIFIED in `codecpar` — *not* a probesize
artefact, tested and exonerated) made KSPlayer build the `CMFormatDescription` with no
colour extensions, so VideoToolbox defaulted output to **BT.709 SDR** and HDR played washed
out.

**Fix:** `FFmpegAssetTrack` recovers colour **from the bitstream** when `codecpar` is
unspecified — a single-threaded `avcodec_open2` (no frames decoded) parses the SPS VUI out
of extradata, and the recovered primaries/trc/matrix/range go into the format description.
**Keep `thread_count = 1`.**

Known KSPlayer colour defects still open: Metal-path untagged fallback is BT.601+sRGB;
software decode drops full-range; DV P5 via FFmpeg parses and discards the RPU (the
`displayYCCTexture` IPT shader exists but is never selected); `dynamicRange` calls anything
10-bit "HDR10"; `StreamProbe.isPQ` still reads bare `codecpar` so untagged HDR probes as
"SDR" (could reuse the same SPS sniff).

### 7.8 The hybrid disk cache — `Core/MediaCacheServer.swift`

A **localhost HTTP proxy on port 8097** between the engines and a direct-file stream,
Infuse-style. The in-memory read-ahead tops out at a few hundred MB on tvOS, so a deep seek
always lands beyond it; this downloads the file to `Library/Caches/hybrid-cache/current.bin`
at line speed and serves range requests from disk.

Design constraints:

* **One session at a time**, replaced on the next `beginSession`. `teardown()` →
  `endSession()` **deletes** the file — nothing survives player exit. (A persistent
  per-title resume cache is a known possible upgrade, not built.)
* **Direct http(s) files only.** HLS playlists never qualify.
* **Fail open:** anything unexpected flips the session to redirect mode and every later
  request gets a **307 to the origin**. Worst case is exactly today's direct playback.
* Everything runs on one serial queue (`orivio.hybridcache`) — listener, connections and
  the URLSession delegate all target it.

**Three download priorities in `pickChunk`, strictly ordered:**

1. **DEMAND** — the reader with the least road ahead. Never subject to any ceiling.
2. **FORWARD FILL** — from the live reader's contiguous edge to `fillCeiling`
   (`liveReadAnchor() + leadAllowance` = **600 s of film**, floor 512 MB, cap `budget/2`).
   Time-based is the whole point: a flat `budget/2` let the pool race **10.6 GB / 27 minutes**
   ahead of the playhead and spend the entire window doing it, which jammed eviction and
   froze the bar for the rest of the film.
3. **ARCHIVE** — the first uncached gap **from byte zero**, whole-file, gated on
   `usedBytes() < archiveCeiling` (`budget − leadAllowance − resumeHeadroom`). Last, so it
   can never take a connection from the viewer; capped at `archiveWorkerCap = 2` workers and
   stood down entirely below `archiveMinLeadBytes = 384 MB` (after a seek the lead is zero,
   so the jump gets the whole pool). Archiving stops well before eviction starts
   (~3.5 GB of hysteresis on the measured session) so the two cannot oscillate.

**Sliding window & eviction.** A file bigger than free disk caches a window (free − 4 GB
storage floor, min 2 GB). The budget is fixed at session start, so a write-path sampler
re-reads REAL free space every 5 s and enforces the same floor for the whole session:
windowed sessions evict behind the reader and, if that cannot recover the floor, park;
full-file sessions hand the whole cache file back and fail open (tvOS thrashes and can
reboot when internal storage fills, and an unbounded write when the free-space query
failed was how the cache filled the box). At budget the downloader pauses; blocks behind the slowest reader are
hole-punched out of the sparse file with APFS **`F_PUNCHHOLE`** (8 MB header + 256 MB rewind
margin protected, 64 MB minimum evict, 32/256 MB hysteresis). `evictBehind(target:)` walks
ranges in **ascending** offset order and stops once the target is met — oldest film first,
only as much as needed. `evictAhead` exists because backward seeks strand earlier regions
*ahead* of the reader; it must protect a span around **every** live reader.

**Connection pool.** Ramps 2→5 (worker count 4/6/8 by hardware tier). On a 429/503 the
refusing level is **remembered** (`throttleCeiling`), the pool steps down by **one** (it
used to halve, producing a sawtooth that spent most of its life at 1 connection,
re-discovering a ceiling it had found seconds earlier: 12.9 MB/s on a link that had done
35 MB/s), the ramp climbs to one below the known ceiling, and a deliberate re-test is
allowed every 5 minutes. Probe prints `pool=3/4 (origin caps at 5)`.

**The cache-only lane `/t/<token>/`** — a disk-or-nothing twin URL (416 on uncovered, closes
at the coverage edge, its readers don't count for eviction or resume). Scrub previews ride
it, so preview frames outlive eviction and cost no network.

**Lifecycle awareness** was entirely missing (`grep -c UIApplication` == 0) and every stall
clock is wall-clock, so `downloadDead = !pausedForSpace && now − lastWriteAt > 25s` was
trivially true on the first read after a TV sleep → `failSession` → `redirectAll` → 307 to
a dead debrid link. `noteAppResumed()` (called only from `handleEnterForeground`) reaps
stalled workers **first** and then restamps the clocks.

**The `NWListener` must be checked by state, not existence.** `startListenerLocked` returned
early on `listener != nil`, so a loopback socket tvOS reclaimed during suspension was never
rebuilt and every later playback got a proxy URL with nothing behind it — "Comet/every
add-on not working", 46 failovers, until relaunch. Now: trust `listener.state`
(`.ready`/`.setup`), cancel dead listeners, identity-guarded state handler, and after two
failed rebuilds **decline the cache for 30 s** (play direct) instead of looping.
`/cachecheck` runs the check on demand.

**Other cache facts worth keeping:**
* **The cache must fail open BEFORE the engine gives up.** Both engines bound a stalled
  read at `rw_timeout` = 20 s (`PlayerViewModel.formatContextOptions` and `DVSampleEngine`'s
  open options), so `stallTimeout`/`wedgeTimeout` are **12 s**, not 25/20. At the old
  values the engine declared the source dead five seconds before the cache could 307 it to
  the origin: the app failed over, the next source was served through the same proxy, and
  it could stall identically — "playback fails to start, and most other sources fail too".
  A seek or an audio/subtitle switch is a fresh `serve` reader on undelivered bytes, so it
  hit the same race. Any future change to these timers must keep them **below** the engine's
  read bound.
* **The origin fetches carry the addon's request headers.** `beginSession(origin:headers:)`
  threads `behaviorHints.proxyHeaders` into every `SegmentDownloader` and `SideFetcher`
  request. They were dropped before, so a header-gated CDN (Referer/User-Agent) answered
  403 to the proxy while the same link played in any client that sends them — the engine's
  own headers only ever reach `127.0.0.1`.
* A reader parked in `serve`'s 80 ms availability poll is invisible when the engine seeks
  away — an always-armed receive is the only way to learn the peer went away.
* The `serve` stall timer is **per connection** and the engine closes/reopens readers as it
  retries, so it never matures. The **download's write heartbeat** is the signal that can't
  be reset by a reconnect.
* `kickPoolIfIdle()` on the serve send-completion path is the wake — once `pickChunk`
  returns nil every worker goes idle and both re-entry signals (segment finished, reader
  starved) stop.
* The wedge timeout only fires while a reader is **actually waiting**. "Window full with
  nothing evictable" is a fine steady state when the reader has 27 minutes buffered.
* **A "no limit" sentinel may only ever be COMPARED, never added.** Returning `Int64.max`
  as an unbounded *distance* and adding it to a byte offset is a Swift overflow **trap**.
* `beginSession` raising `sessionSwapPending` for a **same-origin** early return dropped
  queued worker flushes after `writeOffset` had advanced — silent, never-retried holes
  right in front of the playhead. Fixed with a `snapshotOrigin` mirror.
* Hostile sources exist: `DMM Cast for TorBox` answers **HTTP 500 to every range request**,
  so the film plays (fail-open) while caching, seeking and previews are silently impossible.
* A relative-throughput heuristic needs its threshold set near the **fault**, not near the
  norm — a 4:1 "frontier lag" guard fired 37 s into a healthy session because eight workers
  tiling forward are always several times ahead of the contiguous edge. The real fault was
  54:1 sustained over 16 s; the guard is now 16:1.

**Perspective:** on a 55 GB file with a ~10.5 GB window the cache band can only ever cover
about a fifth of the track. "The bar isn't filling" is the sliding window working; the
archive tier is what makes a jump land in cache.

### 7.9 Scrub previews — `Player/ScrubThumbnailer.swift`

"The preview window doesn't show up" was **six defects in series**, any one of which kept
it empty. Worth reading as a cautionary tale:

1. `buffered` was never written on the DV engine (only assigned from KSPlayer's
   `playableTime`), so every buffer-health gate was shut on `dv-direct`.
2. The first fix measured the wrong thing — `lastRendererEnd` is the *renderer* queue
   (~2 s max, because the display layer stops asking once satisfied). It must be
   `max(lastQueuedVideoPTS, lastRenderedEnd)`: the **demuxer's** read-ahead.
3. The gates (12/8/8/6 s) were KSPlayer numbers and unreachable by construction on a DV
   queue capped at 120 AUs ≈ 5 s. Now `previewBufferGate { usingDVDirect ? 3.5 : 8 }`.
4. The dense pass never ran: its only unconditional start was on wheel-engage; every other
   route went through a 300 ms debounce that each pan sample cancelled, and which then
   checked `isScrubbing` when it fired. Now started from `beginScrub`.
5. The thumbnailer threw away its own work — `break` on one uncovered slot aborted the
   whole pass (now `continue`), and `return cancelled ? [] : thumbnails` discarded every
   decoded frame on cancel (the fine pass is cancelled on every re-centre).
6. The lookup rejected frames for being what they had to be: `generate()` seeks with
   `AVSEEK_FLAG_BACKWARD` and stamps the **keyframe's** PTS, while the fine lookup demanded
   ±2.0 s — and on a 4K remux keyframes are 5–10 s apart.

Then two more: every pass **assigned** `fineThumbnails` instead of merging (destroying the
overlap it had just decoded), and the coarse fallback was suspended for the whole film by a
"not while the picture is moving" stand-down (now it runs and *breathes* 0.6 s between
frames).

**The 2026-09-17 sweep** (for "show a lot more frames, especially in fine tuning"): the
remaining limit was the seek itself. `denseSpacing`/`denseCenter` do **one** seek then a
straight read forward, keeping a frame every 1 s. Measured on generated files: worst gap
went from **5.00 s / 10.01 s** to **1.00 s**, and on the HEVC file the sweep was *faster*
end-to-end than the 40 random seeks it replaces. Self-limiting (`sweepFloorFPS` 60,
`sweepRateWindow` 48 frames, `sweepDecodeCap` 600 mid-power / 1500), sweeps forward from the
centre first so a budget that runs out costs the **edges**, and only runs off the local
cache lane.

**Never set `skip_frame = AVDISCARD_NONKEY`** — it makes the decoder swallow every packet of
an MKV whose packets carry no key flag. Rely on the backward seek +
`AV_CODEC_FLAG_LOW_DELAY (1<<19)`.

**Still open:** the covered-span clamp maps cache **byte** fractions to **time** linearly,
which drifts on VBR, so the fine pass can still decide there is nothing cached under the
finger. (The *bar* has been calibrated — `displaySpans(…, calibration:)` maps bytes→time
piecewise-linearly through (0,0), (live reader byte ↔ `buffered`), (1,1) — but the preview
clamp has not.)

### 7.10 Player UI — the Infuse specification

On 2026-09-05 the player was rebuilt to match Infuse tvOS **exactly**, measured off 11
screenshots and a phone video (`IMG_6051.mov`), not from memory.

* `Player/FusionPlayerControlsOverlay.swift` — transport, scrub view, track popovers.
  **Geometry measured off 1920×1080 captures:** bar centre **95 pt** from the bottom,
  **86 pt** side insets, times **28 pt** under the bar ends, title **44 pt bold, 60 pt**
  above the bar, glyphs **62 pt** discs at the right of the title line, "Swipe down for
  Info" at y≈74. Everything `.ignoresSafeArea()` — Infuse ignores the tvOS safe area and it
  looked wrong until this did too. Keep `FusionMetrics` unless a new capture says otherwise.
* `Player/InfuseInfoPanel.swift` — the swipe-down sheet: **Info / Video / Audio /
  Subtitles** tabs plus `InfusePickerScreen` (full-screen option list, also used for
  sources/episodes/speed/engine). Sources, episodes, engine and PiP live under **OPTIONS**
  on the Info tab (Infuse has none of these).
* **Column geometry is one number:** `InfuseRowMetrics.columnWidth = 520`. 520×3 + 40×2
  spacing + 40×2 padding = 1720, leaving the documented 28 pt of slack under the 1748 pt
  card (overrun makes the film behind the sheet visibly zoom). `InfuseOptionRow` is
  `lineLimit(1)`, so a narrower column silently truncates — **measure, don't guess**
  (a 10-line script with `NSFont.systemFont(ofSize: 29)` and
  `(s as NSString).size(withAttributes:)` matches tvOS rendering to within a point).
* Deleted in the rewrite: `PauseOverlayView.swift`, `SidePanels.swift`, `OSDClock`, the
  pause-overlay and clock settings toggles, and later the "peek bar".

**Remote grammar** (from the video, not guesses):

| Input | Action |
|---|---|
| Click | Play/pause (and raises the transport — Infuse grammar) |
| Swipe left/right | Scrub directly (bare video **or** controls up); click seeks; Menu cancels |
| Click left/right edge | ±10 s skip (one press = one configured skip; the old 4-press fast-forward sweep and per-press ramp are gone — `scanTap/scanHold/scanCommit` and `.scanning` are now unreachable dead code, left in place) |
| Hold an edge | Scan |
| Light tap with controls up | Cross-fades the times to start/end **wall-clock** (`showsClockTimes`, reset in `showControls`) |
| Swipe down | Info sheet |
| Menu | Cancel scrub → close panel → exit player |

While scrubbing the title line is hidden, the played bar fills to the target, the target
time sits under the playhead, and the end labels hide when it overlaps them.

**Cache bar** = `MediaCacheServer.coverageFraction` whenever `hasLiveSession`, else the
engine read-ahead. Spans are keyed by `lowerBound` with `.transition(.identity)`
(offset-keyed transitions slid bands sideways). Gaps are merged by **~5 seconds of film**,
not by a percentage — merging <1 % of a 2 h title bridged 72 s and made the bar lie.

**Gesture thresholds.** A tap on this remote is a pad *press* with a finger on the surface,
and it rolls sideways as it presses, so the ±10 skip now demands `adx > 160` (the info
sheet demands 110 to open, 160 to close). An ambiguous diagonal stays `.undecided`, not
consumed.

**Focus on raise.** The overlay used to reset focus to `.bar` only in `onAppear`, and
raising it *inside its own dismiss transition* leaves the outgoing copy on screen holding
glyph focus. Now `PlayerOverlay.showsTransport` + `PlayerViewModel.controlsSession` (bumped
in `overlay.didSet` only on a non-transport → transport move) drives the reset from state
rather than view lifetime. Measured 199/317 ms → **7–8 ms**. Deliberately **not** bumped for
controls ↔ pauseInfo or opening/closing a popover — those must leave focus where the viewer
put it.

**Transport never auto-hides while paused** (`restartHideTimer` guards on `isPlaying`), so
focus can sit on a glyph indefinitely. That is correct.

### 7.11 Subtitles

**FFmpeg path.** `SubtitleOverlayView` renders `part.text` as
`Text(AttributedString(nsAttributedString))`. Every embedded ASS/SSA track carries its own
style in `subtitle_header`, and KSPlayer's `String.parseStyle` copies Fontname/Fontsize/
primary colour/outline colour onto the string as `.font` / `.foregroundColor` /
`.strokeColor` runs. **A SwiftUI `.font()` or `.foregroundStyle()` modifier cannot override
an attribute the AttributedString already carries** — so the ASS point size won and the Size
setting was inert, and the 8-way stroke drew in the cue's own white. Fix:
`SubtitleOverlayView.restyled` strips font/foreground/background/stroke/shadow/expansion
before rendering.

**Native AVPlayer path.** `KSAVPlayer.subtitleDataSouce` is nil — AVPlayer draws captions
itself using the **tvOS system caption appearance**, which no app setting touched. Fixed
with `AVTextStyleRule` / `kCMTextMarkupAttribute_*` in
`PlayerViewModel.applyNativeCaptionStyle()`. Note CMTextMarkup has **no edge-colour
attribute**, so outline is on/off only on that engine.

**Overlapping cues.** `SubtitleModel.subtitle(currentTime:)` publishes *every* cue
overlapping the playhead, so a dialogue line and a sign/song translation arrive together and
were drawn on top of each other in identical full-screen VStacks. `SubtitlePart.textPosition`
existed the whole time and was referenced nowhere — KSPlayer's ASS parser fills it from the
style `Alignment` and inline `\an` overrides. Cues are now bucketed into the **nine ASS
screen positions** (`slot = vertical * 3 + horizontal`), one VStack per bucket. SRT and
standard ASS dialogue (Alignment 2) land on the bottom slot exactly where they were.
Track Margin L/R/V is deliberately **not** honoured (the app's own 84 pt inset is what
Settings' "Vertical position" adjusts).

**Subtitle "None" left the last cue frozen** because the clock tick only calls
`subtitleModel.subtitle(currentTime:)` while a track is selected, and that call is the only
thing that empties `parts`. Fixed with `dropDisplayedSubtitleCue()`.

External subtitle add-ons (OpenSubtitles) are queried concurrently with order preserved.

### 7.12 Picture in Picture

**tvOS AVKit refuses sample-buffer PiP sources.** Proven by disassembling the device's
AVKit: `-[AVPictureInPicturePlatformAdapter isContentSourceSupported]` returns
`type < 4 && (0b1101 >> type) & 1`. Content source types are 0 PlayerLayer, **1
SampleBufferDisplayLayer**, 2 VideoCall, 3 GenericView — **type 1 is masked out**, so such a
source never leaves status "prohibited" and `isPictureInPicturePossible` stays false
forever. FFmpeg (MetalPlayView) and DVSampleEngine both render into sample-buffer layers;
VLC has no CALayer at all. Only `KSAVPlayer`'s `AVPlayerLayer` works natively.

Because PiP was wanted on every engine, the **private generic-view route** was built and
works (`Player/PictureInPictureBridge.swift`): an `AVPictureInPictureContentViewController`
hosts the real render view (MetalPlayView / VLC drawable / DV layer view) in the Pegasus PiP
window, with `PiPPlaybackBridge` standing in for `AVPlayerController`.

> **NEVER add methods to the bridge class in `resolveInstanceMethod`.** KVO probes
> `getX` / `insertObject:inXAtIndex:` via `respondsToSelector`, and a yes-to-everything
> class crashed AVKit's KVO (`-[NSValue getValue:size:]`).
>
> **NEVER "balance" an `OBJC_RETURNS_RETAINED` return manually.** An added `autorelease()`
> to balance `class_createInstance`'s +1 over-released every ContentSource and crashed the
> app (SIGSEGV in `_swift_release_dealloc`) on player exit.

tvOS AVKit also auto-starts PiP for a native session when the app enters background. While
PiP is active the VM ignores resignActive/background, `KSPlayerLayer.enterBackground` is
bypassed via `KSOptions.hostPictureInPictureActive`, and DetailView will not start a
backdrop trailer. The **simulator reports `isPictureInPictureSupported == false`**, so PiP
can only be exercised on hardware.

### 7.13 Player watchdogs and failover

| Watchdog | Arms | Fires |
|---|---|---|
| Load watchdog | `load()` | 30 s with no `readyToPlay` |
| **First-frame watchdog** | `markLoadStarted()` (i.e. the container OPENED) | 25 s with no first frame → `attemptFailover(code: -4)`. Without it a source that opened and never presented a frame sat on the loading screen **forever**. |
| Stall watchdog | playback running | 20 s stall. It is a one-shot, so `pauseIntent` and `isFailingOver` `didSet` hooks call `updateStallWatchdog()` when they **clear**, and it re-arms when position advanced since arming. |
| Seek-play watchdog | after a seek | polls for settled-and-stopped, then one last `enginePlay()` behind every other guard |

`KSPlayerLayer.seek` plays only `if finished`; a refused demuxer seek loses autoplay, and a
seek superseded in flight never calls its completion at all because `MEPlayerItem.seek`
overwrites `seekingCompletionHandler`. **Never call `play()` inside a seek** — that is the
audio-over-frozen-picture trap.

`recordLinkVerdict` blacklists any link watched <5 minutes for 8 hours. `rankedCandidates`
ranks failover candidates: same link → **same add-on** (compared by `sourceAddonName`) →
same resolution any add-on. Resolve chains are bounded by `withDeadline` (20 s per candidate
when auto-select drives, 60 s manual) — the chain was unbounded by construction (up to ~9
sequential requests × 30 s timeout × every provider, serially).

### 7.14 Auto-selection — **two independent features, easy to confuse**

* **Auto Link Selector** — **per profile**, `ProfileStore.AutoLinkPreferences`
  (`profiles.activeAutoLink`), toggled in ProfilesView. **Device-local, never synced** (the
  shared profile backend has no columns for it, same as `pinHash`).
* **Auto-play best source** — **global**, `PlayerSettings.autoPlaySourceEnabled`,
  Settings → Playback.

The four auto-select paths in `StreamsView.task`, in order: early Auto Link callback →
reuse-last-link (`reuseLastLinkEnabled`, default 24 h) → resume format match
(`bestResumeMatch`) → global auto-play (`autoPlayPick`). All of them exclude **external**
entries (a "cast to DMM" link the Apple TV cannot open). Auto-failover advances to the next
candidate on any resolve failure during an auto flow (capped at 4 attempts per visit)
instead of alerting; manual taps keep their alerts.

**Next-episode auto-advance** (`OrivioTVApp.nextEpisodeEntry`) deliberately picks by binge
group / same add-on with **no reference to either switch** — it belongs to "Auto-play next
episode", whose whole purpose is to continue without interaction. Raise it with the owner
before touching it.

Note: `playManuallyMenu(enabled: autoLinkOn)` returns `self` when off, so **with auto-select
off there is no hold menu attached at all**. `autoLinkOn` in DetailView is
`profiles.activeAutoLink.enabled || playerSettings.settings.autoPlaySourceEnabled`.

---

## 8. Accounts, sync and persistence

### 8.1 The Orivio account (self-hosted Supabase)

`OrivioConfig` reads everything from `Secrets`. Sign-in is a **QR flow** (the TV shows a
code, the user logs in on the web page) or email/password. The app never sees a password in
the QR flow.

**RPCs used** (`/rest/v1/rpc/…`), all verified against the live backend:

```
sync_push_profiles            sync_pull_profiles           sync_pull_profile_locks
sync_push_addons              sync_push_plugins
sync_push_library             sync_pull_library            sync_delete_library_items
sync_push_watch_progress      sync_pull_watch_progress     sync_delete_watch_progress
sync_push_watched_items       sync_pull_watched_items      sync_delete_watched_items
sync_push_collections         sync_pull_collections
sync_push_home_catalog_settings   sync_pull_home_catalog_settings
sync_push_profile_settings_blob   sync_pull_profile_settings_blob
sync_push_provider_credentials    sync_pull_provider_credentials
sync_delete_profile_data
```

Plus direct table reads at `/rest/v1/addons`, `/rest/v1/plugins`, `/rest/v1/collections`.

**Backend facts proven by an anon-key curl probe** (403 = exists but needs a session,
404 PGRST202 = missing):

* `sync_delete_profile_data(p_profile_id)` **exists** and is how Android deletes a profile.
  `sync_push_profiles` only upserts — sending `p_deleted_profile_ids` on it is a PGRST202,
  so the old delete path **never reached the server**.
* `sync_pull_watch_progress_delta` / `_cursor` / `sync_pull_watched_items_delta` exist
  (Android uses them). **Not adopted here yet — a future speed win.**
* **Android keys progress rows `<content_id>_s<S>e<E>`**; tvOS historically keyed by the
  add-on video id (`tt…:1:2`). This mismatch was the root of the "Continue Watching reverts
  to S2E1 / keeps the previous show" bug: pulls dropped the player's row as absent, deletes
  deleted nothing, and a CW-resume recanonicalize deleted the account's only S2E2 row.
  Fixed: `ProgressStore.accountProgressKey` is used for **push and every delete**, and
  `OrivioSyncManager.progressRows/localProgressKey` maps tt episodes to `tt:s:e` on pull.
  `collapseDuplicateEpisodes` reconciles the pair.

### 8.2 The pull-clobber bug class — read this before touching sync

> **Every store pushes on a 1.2–1.5 s debounce, and every pull is a full-snapshot
> replace.** Any sync that lands inside that debounce window reads the server's stale copy
> over the edit the user just made, then pushes the reverted state up as the new truth.
> That is the shape of "I delete a profile and it comes straight back".

The guard is a **dirty flag flushed before the matching pull**. As of 2026-09-09 all of
`profiles`, `addons`, `progress`, `library`, `watched`, `plugins`, `appPreferences`,
`collections`, `homeCatalog`, `badgeSettings` and `providerCredentials` have one. Dirty
flags are **persisted per profile** (`orivio.sync.dirty.<kind>.v1`).

Two extra traps, both hit by profile delete:
* Order matters — `notifyChange()` must arm the push **before** anything that starts a sync.
* A dirty flag alone is not enough for a **deletion**, because the pull has nothing local to
  compare against. `ProfileStore.deletedProfileIDs` is a **persisted tombstone set**
  (`orivio.profiles.deleted.v1`, no `.pN` suffix so the profile purge can't sweep it) that
  `replaceRemote` filters by, retired only when a **pull** comes back without the id.

The same shape applies everywhere: `ProgressStore.removedShows`, `LibraryStore` and
`WatchedStore` removal records, `CollectionsStore.removedIDs`, live-channel favourite
tombstones. **Any new tracker merge into a store MUST call `requestSyncPush()`** or it will
never reach the account. `LibraryStore.mergeRemote` has a `trusted:` flag so only the
account (whose `addedAt` round-trips) may lift a removal record.

Also: a pull in flight when the user removes an **add-on** or plugin repo used to apply its
stale snapshot additively and re-install the removed row — `pullAddons`/`pullPlugins` now
skip applying entirely while a local edit is dirty.

**`syncNow`** runs five per-store chains concurrently, gates tail pushes on dirty flags
after the first full cycle per profile per session, and sets `rerunRequested` rather than
dropping a concurrent request. Steady-state full sync went **8–9 s → 2 s**.
**`syncLight`** runs mid-playback (dirty flushes + progress/library/watched pulls, no
enrichment, no profile/add-on/pref/plugin RPCs).

**`syncOnAppOpen(reason:)`** (added 2026-09-18) arms a sync at launch and on
`scenePhase == .active`, after a settle delay of **1.5 s** (3.0 s on low/mid power) — a full
cycle during app construction made launch unresponsive on a large library. Self-coalescing,
15 s floor, stands down if the profile changed, uses `syncLight` when `playbackActive`.
> **The trap it exposed:** the four content stores decode their persisted blobs **off the
> main actor** at init and publish when the decode lands. `ProgressStore`/`WatchedStore`/
> `LibraryStore` handle a write that beats the decode by **merging**; `CollectionsStore.load()`
> did not (`guard library.isEmpty else { return }`), and `mergeIntoLibrary`'s own `save()`
> had already written the smaller account-only copy over the ~700 KB file. Moving the sync
> from +30 s to +1.5 s made that race routine. **Any future work that starts network merges
> earlier in launch must check this same class of race in every store that decodes
> off-main.**

Auto-sync interval: **30 s**, stretched to **90 s** on low/mid power hardware.

### 8.3 Profiles and per-profile scoping

`ProfileScopedDefaults` (in `ProfileStore.swift`) is the mechanism. Upstream's rule is
"every personal container gets a per-profile suffix; the bare name is the legacy seed".

Per-profile stores: **AddonManager, PluginStore, DebridStore, PlayerSettingsStore,
TMDBSettingsStore, ThemeManager, StreamBadgeStore** (+ progress/library/watched/collections/
ratings/live-favourites).

Deliberately **device-wide**: performance (hardware), torrent, Live TV including the custom
playlist, the Stremio account, and per-box player capability flags.

Rules:

* **Reads fall back to the legacy key only when the scoped key is ABSENT**, so removal paths
  must **write empty markers** (`""` / `Data()` / empty dict), never delete the scoped key.
* The legacy fallback applies to **profile 1 only** (Trakt-switch semantics: splitting hands
  device-wide state, logins included, to the primary profile; every other profile starts
  fresh). Plus a one-shot de-pollution in `data()` that drops a non-primary scoped blob
  byte-identical to the legacy blob (an echo-write of the seed).
* Each split category has a **"Separate per profile"** toggle in Settings → Account (shown
  with 2+ profiles), key `orivio.perProfile.<feature>.v1`, **default true**. In shared mode
  the store reads/writes the bare legacy keys, and `addonPID`/`pluginPID` return 1 on the
  wire (shared ≡ "everyone uses primary").
* `OrivioSyncManager` used to hardcode `p_profile_id: 1` on push and `profile_id=eq.1` on
  pull while Android has always written per-profile rows — so tvOS was blind to them. That
  is fixed; this is what made one user's profile show her husband's add-ons.
* Known cold-launch gap: `AddonManager`/`PluginStore` init reads the raw active id, so a
  `usesPrimary` profile is mapped to p1 only once wiring/sync runs.
* A **different account** signing in **wipes** resident per-profile content plus add-ons and
  plugin repos, guarded on `orivio.account.lastUser.v1` (deliberately not under the
  `orivio.sync.` prefix that `resetSyncBookkeeping` sweeps).

### 8.4 Other sync destinations

* **Trakt** — OAuth (client id/secret in Secrets), scrobbling, watch history, watchlist,
  ratings, playback progress. Auto-sync every 5 minutes when signed in, skipped during
  playback, plus a throttled `syncNow` on `didBecomeActive`. Token refresh is serialized
  with a 10-minute verified-token cache. A 401 from `get()` marks reconnect-needed
  (`SessionHealth`), toasts once per launch, and the settings row reads "Reconnect Needed".
  `pushMark` skips a title the player just finished when scrobbling is on (the stop scrobble
  already logged the play).
* **SIMKL** — PIN login (client id only). History, watchlist, ratings, and
  `syncContinueWatching(remote:)` which seeds next episodes (position 0) from the "watching"
  bucket, capped at 25, merged via `progress.mergeExternal`.
  > `ProgressStore.serviceSyncSources` was missing `"simkl"` — every SIMKL Continue Watching
  > card was deleted by the next Stremio tick and never uploaded. One-word fix, big effect.
* **Stremio account** — `datastoreMeta` for a signature so an unchanged library skips the
  whole `datastoreGet`; `pushCombined` sends only rows whose sorted-JSON FNV hash changed.
  `removed: true` rows are honoured on pull and pushed for local removals. Account change is
  detected by `orivio.stremio.lastSyncedUser.v1`.
* **`SyncCoordinator`** fans a local change out to every destination. It calls Trakt/SIMKL
  `syncNow(force: false)` — `force: true` made one "mark watched" pull the full Trakt history
  on main.

### 8.5 tvOS sandbox facts (learned the hard way)

* **tvOS apps can write ONLY to `Library/Caches` and `tmp`.** No `Documents`, no
  `Application Support` — writes there fail **silently** under `try?`. (`UnreadableBlobGuard`
  wrote to Application Support and therefore preserved nothing for any store.)
* tvOS **purges an app's `tmp` on reinstall**.
* Files the app keeps: `Library/Caches/OrivioCache/collections-library.json` (the collections
  library, ~700 KB), `Library/Caches/OrivioCache/scrub/<fnv>.json` (finished thumbnail sets,
  newest 40), `Library/Caches/hybrid-cache/current.bin` (the media cache, deleted on player
  exit), plugin JS, and the image `DiskCache`.
  `DiagnosticsService.clearCaches` **must** exclude `collections-library.json` and the
  scrapers directory (it once deleted both).

### 8.6 The ~1 MB NSUserDefaults ceiling

`__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__` is a **SIGABRT**,
and it was hit on the real device at ~984 KB. **Treat ~1 MB as the ceiling** (Apple publishes
no tvOS number).

Measured domain on the owner's Apple TV: **~455 KB across 78 keys.** Biggest occupants:
`dev.pipTrail` 97 KB (now DEBUG-only, and the release branch deletes a trail an older build
left behind), `orivio.addons.v1.p1` 46 KB, `orivio.addons.v1` legacy seed 45.6 KB,
`orivio.player.containerCache.v1` 44.8 KB, `orivio.library.v1{,.p2}` 44+43 KB,
`orivio.watched.v1{,.p2}` 15+15 KB, `orivio.badges.payload.v1{,.p1}` 13+13 KB,
`orivio.sync.log.v1` 12 KB.

The scaling risk was add-ons: one Xperience profile = 270 KB **per profile that installs
it** (same box +3 such profiles ≈ 1220 KB = past the abort on add-ons alone). Fixed by
zlib-compressing the blob behind an `OAZ1` magic. **To read the key in Python the algorithm
is RAW DEFLATE: `zlib.decompress(bytes(v[4:]), -15)`** — Apple's `.zlib` has no zlib header.
Anything without the magic is returned untouched, so older plain blobs still load.

The original crash was the same mechanism: a 902 KB collections blob plus an unbounded
`dev.dvTrail` whose one entry held a whole `dv.m3u8`, firing from inside `switchToNativeDV`
— a crash on **every** DV play. The trail is now capped (400 chars/entry, 16 KB total) and
collections moved to a file.

### 8.7 UserDefaults key inventory (all `orivio.*`)

```
account.lastUser.v1                 addons.forgottenDefaults.v1        addons.lastRefresh.v1
addons.v1                           badges.payload.v1                  badges.platform.v1
badges.size.v1                      badges.url.v1
collections.hidden.global.v1        collections.hiddenFolders.global.v1
collections.layoutMode.v1           collections.legacyProfilesMigrated.v1
collections.library.v1              collections.removed.v2             collections.v1
collections.viewMode.v1             community.logoMigration.v2         communitycoverstyle.v1
debrid.keys.v1                      debrid.preferred.v1                debrid.rdrefresh.v1
externalPlayback.pending.v1         home.autorefresh.v1                homecatalog.v1
jellyfin.deviceId                   library.removed.v1                 library.v1
livetv.country.v1                   livetv.customurl.v1                livetv.enabled.v1
livetv.favorites.removed.v1         livetv.favorites.v1                livetv.language.v1
mdblist.settings.v1                 mediaservers.v1                    migration.renameFromNuvio.v1
nextUp.dismissed.v1                 onboarding.completed.v1
performance.clearStickyDiagnostics.v1  performance.gifDefaultOn.v1     performance.v1
player.containerCache.v1            player.dolbyCapableTitles.v1       player.dolbyDeclinedTitles.v2
player.rejectedLinks.v1             player.settings.v1                 player.titleMemory.v1
plex.clientIdentifier               plugins.repos.v1                   plugins.scrapers.v1
profiles.active                     profiles.deleted.v1                profiles.depolluted.<key>
profiles.v1                         progress.removedShows.v1           progress.v1
ratings.v1                          session.v1
simkl.{token,user,synccontinue,synchistory,syncratings,syncwatchlist}.v1
stremio.{authKey,avatar,email,lastSyncedUser,pendingLibraryRemovals,pendingProgressClears}.v1
sync.adoptedAllProfileCollections.v1  sync.appPrefsDirty.v1            sync.client.v1
sync.dirty.<kind>.v1                sync.log.v1                        sync.seeded.<…>
sync.pendingLibraryDeletes.<…>      sync.pendingWatchProgressDeletes.<…>
sync.pendingWatchProgressDeleteAttempts.<…>   sync.pendingWatchedDeletes.<…>
sync.repairedWatchHistoryClear.<…>
theme  theme.amoled  theme.experience  theme.font  theme.settingsstyle
tmdb.settings.v1                    torrent.settings.v1                trailer.path
trakt.{perProfileAccounts,rejectedScrobbles,rejectedScrobbles.stamp,scrobble,secret,
       signedInHere,synchistory,syncplayback,syncratings,syncwatchlist,tokens,user}.v1
watchHistoryClearedAt.v1            watchHistoryClearedAt.reset.v1
watched.removed.v1                  watched.v1
```

Dev-only keys (DEBUG): `dev.dvTrail`, `dev.pipTrail`, `dev.colorTrail`, `dev.flight`.

Per-profile keys carry a `.pN` suffix (e.g. `orivio.addons.v1.p2`).

---

## 9. Testing, debugging and harnesses

### 9.1 The live probe — `http://<apple-tv>:8123`

`ColorProbeServer` + `PlayerProbe` live in `OrivioTV/Player/PlayerTempSweep.swift`
(**DEBUG only**; they live there so no pbxproj entry is needed). An in-memory ring (2000
events, `NSLock`, callable from any queue) plus a `@MainActor` registry of sampler closures.

| Route | What it gives |
|---|---|
| `/live` | Never-closing plain-text stream: events as they land, a LEVELS block every ~2 s |
| `/events` | Events only |
| `/probe` | One-shot snapshot (levels + last 120 events) |
| `/health` | Counters only |
| `/mark?note` | Injects an anchor line into the event stream |
| `/cachecheck` | Runs the cache listener health check on demand |
| `/` | The colour/DV trail + `MediaCacheServer.statusLine` |

Level blocks: `[build]` (executable mtime + `up=` + `mem=` phys_footprint), `[player]`,
`[scrub]`, `[previews]`, `[tracks]`, `[cache]`, `[dv]`, `[engine]`, `[input]`, `[health]`,
`[atmos]`.

Use the helpers:

```bash
export ORIVIO_TV=<apple-tv-lan-ip>
scripts/probe.sh $ORIVIO_TV                 # live tail
scripts/probe.sh $ORIVIO_TV once            # snapshot
scripts/probe.sh $ORIVIO_TV health
scripts/probe.sh $ORIVIO_TV mark "froze here"
scripts/record.sh $ORIVIO_TV session.log    # reconnecting recorder — survives suspends
```

**Always use `record.sh`, never a bare `curl > file`:** a suspended tvOS app stops answering
:8123 (backgrounding kills the `NWListener`'s replies) and a plain curl dies with it.
`/live` replays the ring on connect and the probe clock restarts per launch — split
recordings on `#### reconnect`.

**Read these first, in this order, for the classic reports:**

* `[build]` timestamp — **check it before trusting any device observation.** `strings` on
  the app cannot settle which build is running (Swift string literals do not surface); the
  Debug app is a 58 KB stub with all the code in `OrivioTV.debug.dylib`. NSLog **format**
  strings do survive, so adding one temporarily is a reliable "is my code in here" test.
* `[cache]` reader table — a row whose `idle` climbs while its offset doesn't move is a
  reader the engine abandoned; while one exists the window can't slide and the download
  stops. Rows past 5 s idle are marked `<-- STALE`.
* `[engine] ks: … avSync=` — a pinned negative value is "audio early".
* `[dv] … decodeStalls=` — zero means the renderer was never starved.
* `[tracks] wantAudio: remembered=X setting=Y` — says immediately which audio rule is winning.

> **Diagnostic lesson:** anything worth watching live has to be a `PlayerProbe.event`, not
> just a trail line. A throttle event that went only to `requestTrail` made a recorder read
> `throttleEvents=0` while throttling was happening continuously.

`PlayerProbe.event` takes an `@autoclosure` message so release builds never build the
strings.

### 9.2 Persistent trails (survive a freeze, a force-quit and a panic)

`dev.dvTrail`, `dev.pipTrail`, `dev.colorTrail`, `dev.flight` in UserDefaults. Pull them
with:

```bash
xcrun devicectl device copy from --device <UDID> --user mobile \
  --domain-type appDataContainer --domain-identifier com.orivio.tv.appletv.dev \
  --source Library/Preferences/com.orivio.tv.appletv.dev.plist --destination .
```

Read with **plistlib** (keys contain dots, so `plutil` key paths fail). Note the pulled
plist **lags recent writes**.

> `devicectl device copy from` **briefly backgrounds the app** (tvOS auto-PiP has fired
> during a pull, and it clears the display pin). Pull *after* the observation window — this
> is precisely why the :8123 probe exists.

### 9.3 Device workflow (`devicectl`)

```bash
xcrun devicectl device install app --device <UDID> <path>/OrivioTV.app
xcrun devicectl device process launch --terminate-existing <bundle-id> -- -playerDemo -pipProbe
xcrun devicectl device info files --domain-type systemCrashLogs
xcrun devicectl device info processes
```

* The `--` before launch arguments is **required** or devicectl eats the flags.
* `devicectl process launch --console` **ties the app lifetime to the terminal session** —
  killing the command SIGTERMs the app. Signal 15 is your own kill, not a crash.
* `.ips` crash files are a header JSON line + a body JSON. Jetsam events are
  `JetsamEvent-*.ips` (`rpages × 16384` = RSS).
* The developer disk image sometimes fails to mount ("error 12040"); an Apple TV restart
  fixes it.
* `log stream --device-udid` **no longer exists** on macOS Darwin 25.x.
* Device tvOS framework binaries live in
  `~/Library/Developer/Xcode/tvOS DeviceSupport/<model> <ver>/Symbols/System/Library/Frameworks/`
  — `llvm-objdump --disassemble-symbols='-[Class sel]'` on them is how the PiP limit was
  proven.

### 9.4 Simulator harnesses

**The critical trap:** the simulator may have **several stale Orivio/Nuvio apps installed**
(`com.orivio.tv.appletv` with CFBundleName **NuvioTV** — a pre-rename build —
`com.nuvio.tv.appletv`, `com.orivio.tv.appletv.dev`). Launching the wrong one cost most of a
session. **Always confirm the process name in the log is `OrivioTV[...]`, not `NuvioTV[...]`.**
Sim bundle id depends on the build configuration/DerivedData — confirm it from the build log.

```bash
xcrun simctl launch <udid> <bundle> -focusLog -detailDemo
xcrun simctl io <udid> screenshot out.png          # works for tvOS
xcrun simctl io <udid> recordVideo --codec h264 out.mp4
xcrun simctl spawn <udid> log stream --style compact \
  --predicate 'process == "OrivioTV" AND eventMessage CONTAINS "FocusTrace"'
```

* **Driving the remote from the shell:** `osascript -e 'tell application "Simulator" to
  activate' -e 'tell application "System Events" to key code N'` with
  **123/124/125/126 = left/right/down/up, 36 (or 76 keypad-enter) = Select**.
  **NEVER use key code 53 (Escape)** — it arrives as a hardware-keyboard Escape, skips
  `RemoteMenuCatcher`/`onExitCommand` and tears the `fullScreenCover` down. **Menu behaviour
  can only be tested on a device.**
* The sim drops roughly **1 in 10** presses; verify each press produced a focus-log line and
  retry. But **never use a retry loop on a Select over a toggle** — a toggle flip produces no
  focus-log line, so the verifier retries and flips it up to four times.
* Keyboard input **silently stops reaching the app** after a few `simctl terminate`/`launch`
  cycles. Only **quitting and reopening Simulator** fixes it. Symptom: probe marks appear in
  `/events` but no `remote`/`focus` lines between them.
* `simctl install` **changes the app's data-container UUID** — re-fetch `get_app_container`
  after every install or `file://` demo URLs break.
* To background a tvOS sim app, launch another (`xcrun simctl launch <udid>
  com.apple.TVSettings`) — Cmd+Shift+H reaches the app as Menu, not the system.
* **One-launch argument-domain overrides** (never written to prefs; the argument domain beats
  `@AppStorage`), placed **first** in argv:
  `-orivio.theme.p1 white`, `-orivio.addons.v1.p1 <5b5d>` (empty array),
  `-orivio.collections.viewMode.v1 grid|categories`, `-orivio.homecatalog.v1 <hex JSON>`,
  `-orivio.home.autorefresh.v1 1`. Note `-orivio.addons.lastRefresh.v1 9999999999` is needed
  alongside an empty add-on list or the launch refresh **saves** the empty list.

### 9.5 UI tests — `OrivioTVUITests/FocusTour.swift` (38 tests)

Simulator only, drives `XCUIRemote`. Covers rail exit landing, detail hold menus, the scrub
press flow, the player bar snapshot, Search left-to-rail (12 tours), Home auto-hide rail
insets, and low-power layout.

* **`XCUIRemote.shared.press(.select, forDuration: 2.0)` delivers a real held press** — an
  older note saying the simulator cannot test hold menus was **wrong** and cost several
  sessions.
* Read per-press focus with
  `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>` plus
  `manifest.json`.
* **Fixture trap:** `simctl uninstall` wipes the profile, and a **default profile has Auto
  Link Selector OFF — which gates the Play hold menu entirely.** A run reporting
  `views with contextMenuInteraction: 0` means the fixture, not the code.
* Compare per-press focus over **several runs per build**; single runs flake at launch.
* `xcodebuild build-for-testing` once, then `test-without-building`, to A/B two builds.

### 9.6 Launch arguments (complete list)

**Demos / screens:**
`-homeDemo`, `-searchDemo`, `-libraryDemo`, `-discoverDemo`, `-liveTVDemo`, `-detailDemo`,
`-detailDemoSeries`, `-detailSeries`, `-settingsDemo`, `-settingsTabDemo`, `-accountDemo`,
`-profileGateDemo`, `-railDemo`, `-welcomeDemo`, `-welcomeOfferDemo`, `-traktQRDemo`,
`-simklQRDemo`

**Settings panes:** `-paneAbout`, `-paneAccount`, `-paneContent`, `-paneIntegration`,
`-paneLayout`, `-panePerformance`, `-panePlayback`, `-paneTrakt`

**Player:** `-playerDemo` (Apple's public HLS, native engine), `-playerDemoMKV` (10 s MKV,
FFmpeg), `-playerDemoTour` (walks the overlay states), `-playerControlsDemo` (pins
controls), `-playerInfoDemo` (opens the info sheet), `-playerHUD`, `-forceFFmpeg`,
`-hybridCache` (forces the disk cache on), `-dvCompressedFeed`, `-dvDisplayHDR10`,
`-dvTagColor`

**PiP:** `-pipProbe` (also clears `dev.pipTrail` at launch and copies AVKit's own os_log
lines into it via OSLogStore), `-pipForce`, `-pipViaNative`, `-pipNoGeneric`

**Diagnostics:** `-focusLog` (FocusTrace: every `UIFocusSystem.didUpdateNotification` /
`movementDidFailNotification` with window frames), `-lowPower` (forces the A8 tier — the
**only** way to exercise it, since the sim reports the host Mac), `-hdr10Plus`,
`-thumbnailSelfTest <url>`, `-thumbnailWindow <centre> <half> <spacing>`, `-searchProbe`,
`-addonServerProbe`, `-traktReport`, `-simklEnvelopeReport`, `-traktShared`,
`-traktPerProfile`, `-clearTraktPlayback`, `-clearWatchHistory`, `-restoreProgress`

**Layout:** `-layoutClassic`, `-layoutModern`, `-layoutGrid`

### 9.7 Building media fixtures with ffmpeg

```bash
# 10-minute legible test pattern
ffmpeg -f lavfi -i "testsrc=size=1280x720:rate=24:duration=600" \
       -f lavfi -i "sine=frequency=440:duration=600" \
       -vf "hue=H=2*PI*t/60" -c:v libx264 -preset ultrafast -g 48 \
       -pix_fmt yuv420p -c:a aac -shortest -movflags +faststart out.mp4

# Exact 5-second GOP, for thumbnailer tests
ffmpeg ... -g 120 -keyint_min 120 -sc_threshold 0 ...

# Dolby fixture: HEVC + E-AC-3 5.1
ffmpeg ... -c:v libx265 -tag:v hvc1 -c:a eac3 -ac 6 ...
```

* **Fixtures must be over 180 seconds** — `isNoticeClip` calls anything shorter a notice
  clip and the preflight declines. This cost a full test cycle.
* Serve them with a **range-capable** server. `python3 -m http.server` **ignores `Range`**
  and hands back the whole file, which silently breaks every seek.
* Homebrew ffmpeg's TrueHD encoder is experimental and fails even with `-strict -2`; use
  FLAC 8ch as a stand-in (same decode branch).
* A fake Orivio session can be seeded on a **throwaway** sim (`OrivioSession` persists to
  plain UserDefaults under `orivio.session.v1`; `restoreSession()` only needs `JWT.decode`
  to yield a non-empty `sub`, so an **unsigned** token works). The window is ~2.3 s before
  the first 401 signs it out — enough for launch-time behaviour, not for anything after the
  first round trip.

> **⚠️ There is a booted simulator signed into the REAL account. Never run new sync code,
> and never test accents, on a signed-in sim** — `pullAppPreferences` reverts the theme
> mid-test, and if that pull fails the first full sync **uploads the local theme to the
> account** and thence to the Apple TV. Use `simctl create` temp devices and delete them
> afterwards (their prefs hold the user's keys).

### 9.8 Device under test

Apple TV 4K **1st gen** — `AppleTV6,2`, A10X, **3 GB RAM**, tvOS 26.x. This is the
`isMidPower` tier, and it is the *only* box the app is regularly tested on. Its UDID and LAN
address are deliberately kept out of the repo (the `.gitignore` says so explicitly); use
`export ORIVIO_TV=<ip>` and pass the UDID on the command line.

---

## 10. Performance tiers — `Core/PerformanceProfile.swift`

Optimizations here must be **visually and behaviourally identical**; older Apple TVs just do
less wasted work.

| Tier | Machines | RAM | Notes |
|---|---|---|---|
| `isLowPower` | `AppleTV5,*` (Apple TV HD, A8) or <2.5 GB | 2 GB | 1080p output, so a 3840 px decode is pure waste |
| `isMidPower` | `AppleTV6,*` (4K gen 1, A10X) or <3.5 GB | 3 GB | Full 4K render, tighter budgets |
| (high) | `AppleTV11,*` (gen 2), `AppleTV14,*` (gen 3) | 4 GB+ | Everything on |

Derived capabilities: `supportsHDR10Plus` (gen 3 + tvOS 18.4 only — Apple never shipped it
to earlier hardware), `hdr10PlusUnavailableReason`, `recommendsDolbyVisionProfile7`
(`!isLowPower && !isMidPower` — the DV7 path re-reads and RPU-rewrites the whole file with
libdovi while playback streams).

Budgets: `maxImagePixelSize` 1920/3840 · `backdropPixelCap` 2560 on mid ·
`imageCacheBytes` 96/160/256 MB · `imageCacheCount` 200/300/400 ·
`maxBufferBytes` 220/400/1000 MB (tvOS has **no working disk cache for FFmpeg** — the
`cache:` protocol can't open a temp file in the sandbox — so the read-ahead lives in RAM and
an oversized one jetsams the app).

> **⚠️ THE `isMidPower` TRAP — remember this.** Every material/animation mitigation in the
> app once checked only `isLowPower`, but the test device is `isMidPower`. Live blurs over
> video and a repeating load animation were running on the target hardware. **Gate every new
> mitigation on BOTH tiers.**

Other tiered values: MediaCacheServer `workerCount` 4/6/8 · `CollectionView`
`maxParallelFolders` 3/4/6 · scrub preview caps 120/300 with the whole feature gated on
`!isLowPower` · `StremioResponseCache.entryLimit` 32/64/96 · StremioAPI URLCache memory
8/16/32 MB · TMDB URLCache 4/8/16 MB · `DiskCache` RAM mirror 16/32/64 · hero warm 3/5/8 ·
auto-sync 30 s → 90 s on low/mid · progress save 20 s on HD · on the HD the source ranking
penalises HEVC (−120) and AV1 (−300) and section order is 1080p → 720p → 2160p.

**Recurring cost shapes this codebase produces** (look for these first in any perf pass):

1. Chained SwiftUI computed properties re-walking a big set 4–8× per body pass, on screens
   whose `@FocusState` makes every D-pad press a body pass.
2. "Decode moved off main" fixes that left the sibling half on main.
3. Per-call formatter / `JSONDecoder` allocation in per-episode / per-tile hot paths.
4. `.common`-mode timers (they fire inside the run-loop tracking mode focus/scroll
   animations use, waking SwiftUI mid-navigation). Use `.default`.
5. Fixed-size caches/pools with no tier gate and no memory-warning purge.
6. Anything on KSPlayer's **0.1 s delegate tick** — 10 Hz, whole film, main actor, beside a
   4K decode. `ProcessInfo.processInfo.arguments` rebuilds a `[String]` on **every** access;
   four of those were on the tick path (hence `PlayerDevFlags`).

---

## 11. tvOS focus engine — the rules that cost the most time

This app is a focus-heavy tvOS UI and these are all load-bearing:

1. **A directional focus move cannot be vetoed in SwiftUI.** tvOS commits the move and only
   then reports it (`@FocusState` onChange, `onMoveCommand`); there is no pre-commit hook.
   UIKit has one (`UIFocusGuide` / `preferredFocusEnvironments` / `shouldUpdateFocus`);
   SwiftUI exposes only `defaultFocus` and `focusScope`/`prefersDefaultFocus`. So any "land
   on Play" logic is a **correction after** the engine put focus elsewhere — and that
   correction is what the user sees. The fix that worked was **keeping the visit and
   stopping it painting**: `CircleIconLabel` holds off drawing its highlight until it has
   kept focus ~50 ms (3 frames); a correction takes ~1 frame so it never reaches the screen.
   The debounce **must read `\.isFocused` in the icon itself** — driving it from the row's
   `@FocusState` was built and rejected on capture, because `@FocusState` updates a beat
   after the focus system.
2. **The engine picks by horizontal CENTRE distance**, source centre → candidate centre.
   Matching heights, `.focusSection()` and `.focusScope + .prefersDefaultFocus` were all
   tried and failed to change the choice (the last one oscillated wildly).
3. **On tvOS focus is NOT hit-tested but context menus ARE.** A decorative full-bleed
   `RemoteImage` overflows the box it is visually `.clipped()` to and covers its neighbours
   for hit-test purposes — so focus, Select and Play/Pause worked perfectly on the covered
   cards and only **hold**-Select did nothing. **RULE: any decorative full-bleed
   `RemoteImage` needs `.allowsHitTesting(false)`. `.clipped()` does not help.**
4. **An interactive `UIViewRepresentable` re-resolves focus when inserted into the tree.**
   A backdrop trailer's `AVPlayerLayer` view with default `isUserInteractionEnabled` made
   focus wander by itself 1.7 s after a page opened. **Decorative representables need
   `isUserInteractionEnabled = false` + `.allowsHitTesting(false)`**, and anything that
   appears mid-browse should be **always mounted and revealed with `.opacity`**, never
   conditionally inserted — inserting one mid-browse strands the native card platter's raise
   ("the lift stays on one movie while the title moves") and cancels an in-flight long press.
   Test: open a page and idle with no input; a clean page logs **zero** focus updates.
5. **tvOS silently declines to present a `.contextMenu` on a focused view that is too
   NARROW.** A show's "Play S1:E1" pill (214 pt) opens its hold menu; a movie's "Play"
   (152 pt) does nothing — no error, no log, `UIContextMenuInteraction` never fires. Treat
   **~200 pt as the floor** for any focusable carrying a hold menu (`PlayActionButton` uses
   `.frame(minWidth: 150)` → 222 pt capsule).
6. **A `.contextMenu` needs the native platter button style** (`.mediaCardButtonStyle()`);
   `FlatCardButtonStyle` never presents one.
7. **`.onMoveCommand` on a `.focusSection()` fires on EVERY press in that direction**, not
   only when the engine finds no candidate. The correct edge detector is
   `UIFocusSystem.movementDidFailNotification` + `ctx.focusHeading.contains(.left)`.
8. **`.onMoveCommand` on a focused Button does not stop the engine's own move**, and a
   programmatic focus set inside the move handler is overridden by it. **One writer only**,
   deferred a main-actor turn (`Task { @MainActor in }`).
9. **A `.focusSection()` around a whole block makes entry pick the section's nearest item**,
   not the item below you. And a `.focusSection()` with nothing focusable inside it is an
   empty region for resolution to trip over.
10. **With NOTHING focused** (loading screens, QR pages) `.onExitCommand` never fires, and
    Menu falls through to tvOS and **suspends the app** — which looks identical to a crash in
    a screenshot. `FocusAnchor` (a 1 pt `Color.clear.focusable()`) is the fix;
    `OrivioLoadingView(holdsFocus:)` uses it.
11. **`focusSidebar()` must enable the rail before focusing it** — requests into a
    `.disabled` rail are dropped. The rail is deliberately `.disabled` for short windows
    (0.4 s after `selectTab` or a rail exit, 0.8 s after the profile gate, 0.9 s after
    popping to Home, ~1.3–1.5 s entering Home fresh) so the engine seeds focus into content —
    **and the engine can't enter a disabled rail, so a Left in that window is swallowed**
    while Back still works (Back force-enables). That is the "Left does nothing but Back
    works" report.
12. **`.onFocusChange` applied to a Button wrapper never fires**; use `onChange(of:)` on the
    focus binding, or read `\.isFocused` inside the label.
13. `ContentFocusRouter` is how the rail hands focus back to "the row you were in" — rows
    register a handler, note when they hold focus, and the rail asks the last row on
    Right/Back exit. Its retry loop takes a `focusToken` so it aborts when focus rests on the
    same non-target tile two ticks running (otherwise it yanks focus back while the viewer
    swipes on).

**Verification method that settles focus arguments:** the focus log is **not enough** — it
shows the visit either way. Record video (`simctl io recordVideo --codec h264`, 3840×2160),
then `ffmpeg fps=60,crop=…` over the control row and count accent-coloured pixels per
control per frame. *"Zero frames with a lit icon across two down-moves and an up-move"* is a
claim worth making; *"the log shows 13 ms"* is not.

---

## 12. Conventions and standing rules

### 12.1 Scope discipline (standing instruction from the owner)

> *"Be very, very careful not to create more bugs, and only fix the bugs or add the features
> I ask."*

This is a large, mature tvOS app whose player and cache paths are full of hard-won fixes,
each with a long comment explaining the bug it prevents. There is **one tester**, on **one
Apple TV he also uses**. A regression costs him a real evening. He measures a change by
whether the thing he reported stopped happening.

* Fix the reported bug. **Do not fix adjacent defects found along the way, however real.**
  Report them, offer, and wait. (A genuine DetailView sleep hole was fixed unasked and the
  whole change was reverted. The *finding* was welcome; the unrequested edit was not.)
* One file / one guard / one line beats a refactor every time. Keep the diff reviewable at a
  glance.
* Prefer applying a rule the codebase **already states somewhere else** over inventing new
  behaviour.
* Never "clean up" surrounding code, rename things, or restructure while in a file for
  another reason.
* **Say plainly what is verified vs reasoned.** He acts on that distinction.
* When a fix needs a design call he has delegated, still choose the **narrow** option and
  name the risky one you did not take, with why.

### 12.2 Code style

* Comments in this codebase explain **why**, often at length, and frequently name the bug
  the code prevents and the evidence that proved it. **Match that.** A one-line comment
  saying what the code does is worse than nothing here.
* Commit messages are **imperative, plain-English, user-outcome sentences**, not
  conventional-commits: *"Stop two caches answering addon requests the app meant to send"*,
  *"Place subtitle cues where the track says, so signs stop landing on dialogue"*,
  *"Bound the DV preflight's reconnect so a dead read can't run for minutes"*.
* Split a batch into commits that can each be reverted alone, and say which one is riskiest.

### 12.3 The recurring failure mode in this repo

> **Twice confirmed across two large audits: roughly a third of a big change set's fixes
> were INCOMPLETE rather than wrong — correct logic wired into only *some* of the paths that
> needed it.**

So: **grep for EVERY call site of the thing being fixed, and every sibling path with the
same shape, before declaring it done.** And always re-audit a large mechanical change set.
Related: for every "load once" latch, check what happens when the `.task` that set it is
cancelled (the latch was frequently set **before** the first `await`).

Two more process lessons:
* **Don't trust a skeptic panel over the code.** A five-lens audit of the scrub previews
  returned `confirmed: []` while at least three of the refuted findings were real.
* **Diff the working case against the broken one** instead of reasoning from the code. "It
  works for shows but not movies" and "it works on other movies but not Continue Watching"
  each cracked a bug that five theories had missed. The owner's own bisections are the
  reliable signal.
* A python edit script that asserts **after** a replace writes nothing when the assert
  fails — one such abort silently left an A/B diagnostic in the tree and it shipped. Write
  each edit as its own script, or verify with `git diff` before building.

---

## 13. Known open items and unverified work

Nothing below is a secret; all of it is honest state at handoff.

**Open bugs / gaps**

* `DVSampleEngine.installFeeders` reads `UIView.layer` off the main thread inside
  `feedQueue.async` (Main Thread Checker has caught it twice).
* `PlayerViewModel` never deinits (~9 MB residual per session; SwiftUI `fullScreenCover`
  retention suspected). A leak probe counts `liveVMs` climbing across play/exit cycles.
* Mid-movie engine switch can freeze ("everything weird").
* Scrub previews: the covered-span clamp still maps cache **byte** fractions to time
  linearly, so on a VBR file the fine pass can decide nothing is cached under the finger.
  Symptom: `fine=0` with the sweep line absent.
* H.264 + DD+ titles whose stream name carries no audio hint never bitstream (§7.4).
* Cross-device collection **delete** cannot propagate (the protocol has no delete record;
  tombstone + prune only).
* Add-on-only collection folders load correctly but the Settings → Collections **editor**
  used to mislabel them — fixed 09-17; the stale `!providers.any` banner ("Collections need
  one of them to load anything") is still there.
* Top Shelf and the poster bars read the raw store Continue Watching (no superseding), so a
  leftover row written after its watched mark still shows a progress bar.
* Going **up** out of the Featured bar eats one press (pre-existing; the press lands on a
  `UIKitFocusableFillerItem`).
* Rail exit from a pinned-Hybrid **row** lands on Continue Watching rather than the row you
  left.
* The idle full-screen backdrop trailer dissolves the Detail page ~9 s in (measured, real,
  left unchanged pending a product call). Workaround: Playback → auto-play trailer delay = 0.
* `RangeRefusingAddons` is permanent, global, with no TTL and no reset.
* Dead settings (from `SETTINGS_REFERENCE.md`): **Hide torrent stats** (persisted, never
  read); model fields `pauseOverlayEnabled`, `osdClockEnabled`, `fullscreenHero` (the last
  is even synced to the account but no view reads it); `OrivioPlayerOptions.matchFrameRate`.
* `Core/MediaCacheServer.swift` has **zero** `UIApplication` references beyond the new
  `noteAppResumed` hook — every other clock in it is wall-clock.
* Jellyfin libraries over ~20k items are untested/slow. **None of the Plex/Jellyfin code has
  ever been run against a real server.**
* `beginPrecache` is **dead code** — `load(entry:)` sets `cacheTargetSeconds = 0`
  unconditionally ("start on first keyframe"), so every first open takes the
  `openedUnattended` branch. The precache loop still has silent-exit hazards if re-enabled.
* The scan/fast-forward transport (`scanTap`/`scanHold`/`scanCommit`, `.scanning` bar mode)
  is unreachable dead code, left in place pending a decision.

**Built but not verified on device** (reasoned only) — treat with care:

* Several of the 2026-09-14…09-18 player fixes: the display-restore-on-exit, the range-aware
  display pin, the wake-spinner gate, the 160 pt swipe floor, the `noteAppResumed` cache
  wake, the listener state check, and the six-defect "play again fails until relaunch" chain.
* The Continue Watching account-key fixes were verified against a replay of the device's own
  blobs in a throwaway sim (41/41 logic checks), **not** against the live account.
* `syncOnAppOpen` is verified only up to the first backend round trip.

**tvOS platform facts worth re-reading before any lifecycle work**

* **Display sleep does NOT background the app promptly.** Measured on one continuous probe
  trail: `willResignActive` fires instantly, the app runs **~10 more minutes**, and only then
  does `didEnterBackground` arrive. So a short sleep wakes through `handleBecomeActive` and a
  long one through `handleEnterForeground` — **different handlers**. Any wake logic hung on
  `didEnterBackground` alone silently does not run for the first ten minutes.
* A **paused** KSPlayer engine left in `.buffering` by a flush-seek with `autoPlay: false`
  **never pumps enough to report its way back out**. That single latch is behind the
  paused-wake spinner, the dead seek-play watchdog and more. "A paused viewer is not a
  stall" is the judgement to reuse.

---

## 14. Quick reference

### Common commands

```bash
# regenerate the Xcode project after adding/removing files
xcodegen generate

# simulator build
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' build

# device build (signed)
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -configuration Debug \
  -destination "id=$UDID" -allowProvisioningUpdates build

# UI tests
xcodebuild test -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'

# both release IPAs
scripts/make-ipa.sh

# live probe
export ORIVIO_TV=<apple-tv-ip>; scripts/probe.sh $ORIVIO_TV
scripts/record.sh $ORIVIO_TV session.log
```

### Ten things that will bite a newcomer fastest

1. `project.yml` is the project; a new `.swift` file needs `xcodegen generate`.
2. Never judge whether a build compiled from a grepped log; incremental builds silently
   no-op here.
3. Check `[build]` in `/probe` before trusting any device observation.
4. Never install onto the Apple TV while it's playing.
5. Glass must be a **background**, never a wrapper around focusable content.
6. Decorative full-bleed images and representables need `.allowsHitTesting(false)` (and
   should be always-mounted, revealed by opacity).
7. `ttl: 0` does not mean uncached — the shared `URLSession` has a 256 MB disk `URLCache`.
8. A dirty flag must be flushed **before** the matching pull, or the pull clobbers the edit.
9. Gate every performance mitigation on **both** `isLowPower` and `isMidPower`.
10. Fix only what was asked. Report the rest.

---

*End of handoff. The `SETTINGS_REFERENCE.md` in this repo is the companion document for
anything Settings-related; `README.md` is the public-facing description (with the stale
Install/build paths noted in §1.5).*
