# Orivio TV — Settings Reference

Every pane, card, switch, dropdown and button in Settings, what it does, and
whether it is actually wired to anything.

- **Commit:** `85deb0e` (branch `fix/audit-sessions-1-3`, identical to `main`)
- **Generated:** 2026-09-14

## What "Works?" means here

This column is **static analysis, not device testing**. For every setting I
traced the stored property to the code that reads it:

- **Wired** — the value is read by code that acts on it. Traced to a specific
  consumer file. It is *connected*; I have not clicked each one on an Apple TV.
- **DEAD** — the control writes a value that **nothing ever reads**. Toggling it
  changes nothing at all.
- **Partial** — works, with a caveat spelled out in the notes.

A first pass flagged more settings as dead than really are. Several are consumed
through *computed aggregates* rather than by name — `streamMinResolution` and its
four siblings feed `PlayerSettings.streamFilterOptions`, and the five
Performance motion switches are read as `focusZoomEffective`,
`cardParallaxEffective` and so on. Those all work. Every "DEAD" below was
re-checked by hand for that pattern.

---

## Summary of what is broken

| Item | Where | Status |
| --- | --- | --- |
| **Hide torrent stats** | Integrations → P2P | **DEAD** — persisted, never read by anything |
| `pauseOverlayEnabled` | *(no UI)* | Dead model field — declared and decoded, never read |
| `osdClockEnabled` | *(no UI)* | Dead model field — declared and decoded, never read |
| `fullscreenHero` | *(no UI)* | Persisted **and synced to the account**, but no view reads it |
| `audioRendererEnabled` | *(no UI)* | Legacy — survives only as a migration fallback for **Surround & Dolby Atmos**. Correct as-is. |

Everything else in Settings is wired to a consumer.

Three settings are directly implicated in bugs currently under investigation —
see [Known interactions](#known-interactions-with-open-bugs) at the end.

---

## Settings rail

Ten categories, in rail order. **Plugins** is hidden unless
Appearance → Experience Mode is **Advanced**.

| Category | Subtitle |
| --- | --- |
| Account | Orivio account and profiles |
| Appearance | Theme, accent color, and font |
| Layout | Home structure and poster styles |
| Content & Discovery | Add-ons, catalogs, and collections |
| Integrations | Manage available integrations |
| Plugins | Scraper repositories and plugins *(Advanced only)* |
| Playback | Auto-play and next-episode behavior |
| Performance | Turn effects off for a faster UI on older Apple TVs |
| Trakt & SIMKL | Scrobble and sync your watch history, or connect SIMKL |
| About | App information, updates, and legal links |

---

## Account

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Accounts | Value card | Opens sign-in / account status for the Orivio account | Wired |
| Manage Profiles | Action | Add, rename, recolor, PIN-lock and remove profiles | Wired |

### Separate per profile

Seven switches. **On:** each profile keeps its own copy. **Off:** one shared copy
for the whole device. Turning one off falls back to the shared copy; turning it
back on finds each profile's own state where it was.

| Control | What it splits per profile | Works? |
| --- | --- | --- |
| Add-ons | Installed add-ons and their order | Wired |
| Plugins | Plugin repositories and scrapers | Wired |
| Debrid logins | Real-Debrid / Premiumize / TorBox and the preferred service | Wired |
| Player & subtitles | Playback and caption settings | Wired |
| TMDB | TMDB key, language and enrichment choices | Wired |
| Theme & appearance | Accent, font and settings style | Wired |
| Stream badges | Badge pack and size | Wired |

---

## Appearance

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Accent Color | Swatch row | Highlight color across the app. One swatch per palette in `OrivioThemes.all` | Wired |
| Black Background | Switch | Flat black stage (AMOLED) — drops both the grey depth wash and the accent bloom, and the Detail hero scrim fades to the same black | Wired |
| Font | Chips | Typeface across the app (`AppFont.allCases`) | Wired |
| Experience Mode | Chips | **Essential** / **Advanced**. Essential hides the Plugins section and the advanced Playback cards (auto-play source, player engine, on-screen display, audio) | Wired |
| Settings Style | Chips | **Classic** rounded / **Zen** pill / **Horizon** squared — reshapes settings cards and rows | Wired |

---

## Layout

### Home Layout

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| *(layout picker)* | Cards | Chooses the Home layout | Wired |
| Landscape Posters | Switch | Portrait vs landscape cards for Modern view | Wired |
| Featured section | Switch | The rotating Featured banner between Continue Watching and the catalog rows | Wired |
| Hero layout | Dropdown | How the Home hero behaves. **Rolling Hero** — a banner that cycles the top ten on a timer; browsing never changes it. **Pinned Focus** — a fixed header above the rows showing whichever card holds focus; never cycles. **Hybrid** — cycles at the top of the page; move down into the rows and it becomes a Pinned Focus hero fixed to the top of the *screen*, following whichever card you're on. Press UP out of the first row to hand it back to the roll. **Hybrid is the default.** Replaces the old "Pin hero to the top" switch: on → Pinned Focus (an explicit choice, kept), off → Hybrid (never a choice, takes the default) | Wired |
| Hero source | Dropdown | Which catalog feeds the hero. **Automatic (first row)** is the default and the long-standing behaviour — whichever catalog sits first in your Home order. Pick any catalog an add-on declares to pin the hero to it instead. A chosen catalog that isn't on screen (switched off in the row list below, ranked past Home's row cap, or from an add-on since removed) falls back to the first row. The Featured bar always takes the first catalog that *isn't* the hero's, so the two never show the same row | Wired |
| Navigation Position | Dropdown | Where the primary navigation sits. **Left / Vertical** is the default and the shipped layout — a glass rail hugging the left edge that expands to labels on focus. **Top / Horizontal** turns the same component on its side: one bar across the top, always showing every tab's label and the profile chip. Same items, icons, focus bindings and glass either way. The bar floats OVER Home (the hero is never pushed down, exactly as the left pill floats beside it); the other tabs reserve clearance for it. Reach the navigation with Left (vertical) or Up (horizontal); step along it with Up/Down or Left/Right; leave it with Right or Down. Back behaves identically in both | Wired |
| Hide the sidebar | Switch | Gives rows the full screen width. LEFT from the page edge (or Menu) brings the sidebar back | Wired |
| Hero trailers | Switch | With the hero pinned, plays the highlighted title's trailer behind the name and details. **Pinned Focus only** — the rolling banner (Rolling / Hybrid) has never played trailers | Wired |
| Hero trailer sound | Switch | Plays the hero trailer with sound instead of muted | Wired |
| Full stream names | Switch | Source list shows each link's complete release name, wrapped rather than truncated | Wired |

### Posters

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Poster labels | Switch | Title beneath poster cards | Wired |
| Poster banners | Switch | Shows the tags some add-ons print into their poster artwork ("In Cinema", "#2 Today", "New Movie"). Off uses the plain poster the add-on sends alongside (`posterFallback`) wherever it sends one, swapped in as catalogs and details are fetched: Home reloads on the switch, other screens pick it up the next time they load. Continue Watching and Library keep the artwork each title was saved with | Wired |
| Corner radius | Dropdown | Roundness of poster card corners | Wired |
| Hide unreleased content | Switch | Keeps unaired titles out of catalog rows | Wired |

### Rows & Details

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Addon name in row titles | Switch | Appends the source addon's name to each catalog row header | Wired |
| Type suffix in row titles | Switch | Appends "- Movie" / "- Series" to row headers | Wired |
| Full release date | Switch | Full date on the details page instead of just the year | Wired |
| Trailer button | Switch | Shows the Trailer button on the details page | Wired |

### Layout → Details Page

Which optional sections appear below a title's artwork. All default ON, so a viewer who never opens these sees the page exactly as it always was. These are DISPLAY switches and are independent of the per-section TMDB enrichment switches under Integrations → TMDB, which decide whether the data is fetched at all — a section with no data stays hidden either way.

| Setting | Type | What it does | Status |
| --- | --- | --- | --- |
| Creator and Cast | Switch | The row of directors, writers and cast members | Wired |
| Collection | Switch | The "part of…" row for a title in a series of films, listing the others | Wired |
| More Like This | Switch | Recommended titles based on the one being viewed | Wired |
| Production | Switch | The studios and production companies behind the title | Wired |
| Comments | Switch | Viewer comments from Trakt | Wired |

The episode browser on a series is deliberately NOT toggleable — it is how an episode is chosen, so hiding it would leave a series unplayable.

### Continue Watching

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Sort order | Dropdown | How the resume row is ordered | Wired |
| Episode thumbnails | Switch | Episode still on CW cards instead of the show poster | Wired |
| Next up from furthest episode | Switch | Resume after the furthest episode watched, not the most recently played | Wired |
| Show unaired next up | Switch | Allows an unaired episode to be the next-up target | Wired |
| Blur unwatched episodes | Switch | Spoiler-blurs unwatched episode thumbnails (focus reveals) | Wired |
| Blur Continue Watching next up | Switch | Spoiler-blurs art for barely-started next-up episodes on the home row | Wired |

### Home Rows

Reorder, rename and hide catalog rows. Per-collection editor.

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| New Collection | Action | Creates a custom home row of catalog folders | Wired |
| Pin to top of Home | Switch | Shows this collection's row before the catalogs | Wired |
| Focus glow | Switch | Soft glow on focused tiles | Wired |
| "All" tab | Switch | Combined tab alongside each folder's tab in the browser | Wired |
| Add Folder | Action | Pick TMDB or Trakt sources to fill it | Wired |
| Add TMDB / Trakt Source | Action | Studios, networks, people, discover feeds, or a Trakt list | Wired |

---

## Content & Discovery

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Addons | Value card | Manage add-ons, catalog order and collections | Wired |
| Auto-refresh | Dropdown | Re-fetches Home catalogs on a timer while the app is open | Wired |

### Live TV

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Live TV tab | Switch | Shows the Live TV tab in the sidebar | Wired |
| Location | Dropdown | Loads channels for this country. All countries = the full global list | Wired |
| Preferred language | Dropdown | Only shows channels in this language, wherever they're from. Location is used only when no language is set | Wired |

### Badges

Badge packs from Badger (`nintle.github.io/Badger`) shown on source rows.

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Add from Phone | Action | QR code to paste a playlist URL from a phone browser | Wired |
| Badge size | Dropdown | Size of badges on source rows | Wired |
| Badge profile | Dropdown | Which remote badge pack to use | Wired |

### Install Add-on

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Discover Add-ons | Action | Browse and install popular add-ons | Wired |
| Collections | Action | Group catalogs into custom home rows | Wired |
| Community Collections | Action | One-tap streaming-service and studio collections | Wired |
| Sync Add-ons | Action | Re-pulls add-ons from the account | Wired |
| Add-on Health | Action | Measures manifest response time, finds slow/dead providers | Wired |
| Add Add-ons | Action | QR code opening a phone page to paste manifest URLs | Wired |
| Export Add-on Setup | Action | QR code containing every installed manifest URL | Wired |
| Import Add-on Setup | Action | Paste exported manifest URLs to restore a setup | Wired |
| Installed Add-ons | List | Per-addon enable/disable and removal | Wired |

---

## Integrations

### MDBList

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Enable MDBList ratings | Switch | Aggregate scores across rating sources | Wired |
| API key | Key row | MDBList API key entry | Wired |
| Provider toggles | Switches | Which rating providers to show | Wired |

### Debrid

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Provider rows | Rows | Connect Real-Debrid / Premiumize / TorBox | Wired |
| Preferred provider | Dropdown | Used first when a stream is cached on more than one | Wired |

### TMDB

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Enable TMDB | Switch | Master switch for TMDB enrichment | Wired |
| API key | Key row | TMDB API key entry | Wired |
| Enrich Continue Watching | Switch | Fetches missing titles/artwork for CW rows synced from other devices | Wired |
| Language | Dropdown | TMDB metadata language | Wired |
| Cast & Crew | Switch | TMDB cast, crew and director on the details page | Wired |
| Trailers | Switch | TMDB trailers **and the auto-playing hero trailer** on details | Wired |
| More Like This | Switch | TMDB recommendations row on the details page | Wired |
| Details | Switch | TMDB country and spoken-language details | Wired |
| Release dates | Switch | TMDB release date on the details page | Wired |
| Production companies | Switch | TMDB production-companies row | Wired |
| Collections | Switch | "Part of a collection" row and its other entries | Wired |
| Episodes | Switch | Per-episode TMDB ratings and air dates for series | Wired |

### P2P (TorrServer)

tvOS cannot run a torrent engine on-device, so P2P routes through a TorrServer
instance on the network.

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Enable P2P | Switch | Plays torrent sources through TorrServer when no debrid provider is set | Wired — gates `TorrentSettings.isConfigured`, which `TorrServerService.resolve` requires |
| Server URL | Text | TorrServer base URL, e.g. `http://192.168.1.10:8090` | Wired |
| Test connection | Action | Pings the server | Wired |
| **Hide torrent stats** | Switch | *Claims to* hide peer/seed counts while streaming | **DEAD** — the value is persisted and decoded, but **no code reads it**. The switch does nothing. |

---

## Plugins *(Advanced experience mode only)*

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Add repository | Text + action | Paste a scraper repository manifest URL | Wired |
| Enable repository | Switch | Turns a whole repo's scrapers on/off | Wired |
| *(per-scraper toggle)* | Switch | Enables an individual scraper | Wired |
| Remove repository | Action | Deletes the repo and its scrapers | Wired |

---

## Playback

### Auto-play

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Auto-play next episode | Switch | Runs a countdown on the Up Next card and starts the next episode. Off = the card still appears but waits for Play | Wired |
| Show Up Next | Dropdown | With credits chapters the card appears as they start; otherwise this many seconds before the end | Wired |
| Auto-play countdown | Dropdown | How long the countdown runs | Wired |
| Still watching? | Switch | Pauses auto-play after several episodes to check you're still there | Wired |
| Ask after | Dropdown | How many consecutive auto-advances before the gate | Wired |
| Prefer same source group | Switch | Picks the next episode from the same release group when possible | Wired — **see note in Known interactions** |
| Reuse the same source | Switch | Keeps the next episode on the same addon as well as the same group | Wired |

### Seeking

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Skip amount | Dropdown | Each left/right press; rapid presses add up, holding accelerates | Wired |
| Scrubber jump | Dropdown | Left/right press while scrubbing with the trackpad | Wired |
| Skip Intro button | Switch | Shows a Skip Intro pill inside an intro/recap chapter (⏯ skips it) | Wired |
| Auto-skip intros | Switch | Jumps past intro/recap chapters automatically. Needs chapter markers | Wired |
| AniSkip for anime | Switch | Fetches intro/outro times from the public AniSkip database for anime with no chapter markers | Wired |

### Sources

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Link filters | Switch | Smart-ranks links: grouped by resolution per addon, scored by cached status, release quality (REMUX > Blu-ray > WEB-DL), codec, HDR/DV, audio, seeders, bitrate | Wired |
| Links per resolution | Dropdown | Best-scored links kept per tier (2160p/1080p/720p/480p) per addon | Wired |
| Source search patience | Dropdown | How long each addon gets to answer. Raise for aggregators querying Usenet indexers | Wired |
| Minimum resolution | Dropdown | Hides links below this quality (untagged links are kept) | Wired *(via `streamFilterOptions`)* |
| Hide AV1 links | Switch | AV1 has no hardware decode on Apple TV — those links stutter | Wired *(via `streamFilterOptions`)* |
| HDR only | Switch | Only HDR10 / HLG / Dolby Vision links | Wired *(via `streamFilterOptions`)* |
| Dolby Vision only | Switch | Only Dolby Vision links | Wired *(via `streamFilterOptions`)* |
| Cached only | Switch | Only debrid-cached links (instant play) | Wired *(via `streamFilterOptions`)* |

### Content

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Parental guide | Switch | IMDb content advisories (sex, violence, profanity, drugs, frightening) on the details page | Wired |

### Auto-play source

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Auto-play best source | Switch | Starts the top-ranked link automatically instead of showing the source list | Wired |
| Cached sources only | Switch | Only auto-plays a debrid-cached link, never one that must resolve first | Wired |
| Reuse last link | Switch | Replays the last source played for a title without re-searching addons | Wired |
| Reuse window | Dropdown | How long a remembered link stays valid | Wired |

### Player

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Playback engine | Dropdown | Which engine opens streams | Wired |
| Playback mode | Dropdown | Automatic picks the best supported path; Maximum Fidelity never downgrades (native DV, Profile 7 conversion always on, Atmos renderer); Compatibility pins the safe paths | Wired |
| Buffer ahead | Dropdown | How much video to download ahead. Auto sizes to the file | Wired |
| Hybrid disk cache | Switch | Downloads the film to storage at full speed while playing so seeking into downloaded parts is instant. Direct-file streams only; the cache is deleted when playback ends | Wired — **see Known interactions** |
| External player | Dropdown | Streams open in another app; playback, resume and history live there | Wired |
| Forward subtitles | Switch | Fetches a subtitle in the preferred language and passes it to the external player | Wired |
| Send the rest of the season | Switch | Hands the next few episodes over as a playlist so next-episode keeps working in the other app | Wired |
| HDR10+ passthrough | Switch | Sends HDR10+ dynamic metadata instead of the plain HDR10 base layer | Wired |
| Native Dolby Vision | Switch | Plays DV profile 5/8 through Apple's video pipeline for true dynamic DV. Remuxes on-device; falls back to HDR10 | Wired |
| Dolby Vision Profile 7 | Switch | Converts dual-layer Profile 7 (UHD Blu-ray remuxes) to Profile 8.1 on the fly | Wired |
| Match content display mode | Switch | Also switches the TV's HDR mode and refresh rate for **non-DV** video. DV always switches regardless | Wired — **see Known interactions** |
| Video scaling | Dropdown | Default zoom. Cycle live in the player with the aspect button | Wired |

### On-screen display

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Loading backdrop | Switch | Full-screen loading screen (artwork + spinner) while a stream opens | Wired |
| Loading status | Switch | "Loading / Caching %" text and cache bar on the loading screen | Wired |

### Audio

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Preferred language | Dropdown | Automatically picks a matching audio track | Wired |
| Surround & Dolby Atmos | Dropdown | Audio output path (Auto / enhanced renderer / standard engine) | Wired |

### Subtitles

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Subtitles on by default | Switch | Enables subtitles when a stream loads, in the preferred language | Wired |
| Full styled subtitles (ASS/SSA) | Switch | Renders fancy anime/fansub subtitles properly. Those titles play in the VLC engine | Wired |
| Preferred language | Dropdown | Chosen automatically when the stream has a match | Wired |
| Secondary language | Dropdown | Used when the preferred language isn't available | Wired |
| Prefer forced subtitles | Switch | Chooses a forced track (foreign dialogue only) when one exists in your language | Wired |
| Text size | Dropdown | Caption size | Wired |
| Font | Dropdown | Caption typeface. Also adjustable live in the player | Wired |
| Timing offset | Dropdown | Shifts captions earlier (−) or later (+). Adjustable live | Wired |
| Text color | Dropdown | Caption color | Wired |
| Bold text | Switch | Heavier caption weight | Wired |
| Outline | Switch | Outline around the text for readability on any background | Wired |
| Outline color | Dropdown | Outline color | Wired |
| Outline thickness | Dropdown | Outline width | Wired |
| Background plate | Switch | Panel behind captions | Wired |
| Background opacity | Dropdown | Plate opacity | Wired |
| Vertical position | Dropdown | Raises or lowers the captions | Wired |

> All caption styling is applied by stripping the cue's own ASS/SSA presentation
> attributes first — otherwise an embedded 80pt fansub style would override these
> controls entirely.

### Trailers

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Auto-play trailer | Dropdown | Plays the trailer in the details-page backdrop after sitting on a title. **Off** disables it entirely | Wired |

---

## Performance

Per-device; these do **not** sync to the account. When the system Accessibility
setting **Reduce Motion** is on, the motion effects are forced off regardless of
these switches, and a banner says so.

### Quick setup

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Performance mode | Switch | Turns every visual effect below OFF at once | Wired |
| Reset to recommended | Action | Restores the tuned defaults for this device tier | Wired |

### Home billboard

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Hero backdrop artwork | Switch | Full-screen art behind Home that changes with each focused card — the single heaviest effect on older boxes | Wired |
| Hero crossfade | Switch | Dissolve when hero art and info change | Wired |

### Cards & rows

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Card shadows | Switch | Soft drop shadows under posters — an offscreen blur re-rendered on every focus move | Wired |
| Focus zoom | Switch | Focused card springs slightly larger | Wired *(read as `focusZoomEffective`)* |
| Card wiggle & lift | Switch | Native Apple TV card effect — the focused poster raises and tilts with the trackpad. Heaviest per-frame focus cost | Wired *(read as `cardParallaxEffective`)* |

### Animations

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Sidebar animation | Switch | Sidebar expand/collapse spring and its dim over the content | Wired *(read as `sidebarAnimationEffective`)* |
| Button & pill effects | Switch | Small controls scale and spring on focus/click | Wired *(read as `buttonAnimationsEffective`)* |

### Artwork loading

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Preload row artwork | Switch | Downloads posters for rows below the fold in the background | Wired |
| Artwork fade-in | Switch | Posters fade in when they finish loading | Wired *(read as `artworkFadeInEffective`)* |

### Collections

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Collection focus artwork | Dropdown | GIF quality for collection folder tiles on focus | Wired |

### Developer

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Show FPS overlay | Switch | Live FPS read-out over the whole app (green/amber/red) | Wired |
| Hold menu probe | Switch | On-screen trace of hold-Select: focus, press arrival, long-press recognition, whether tvOS builds the menu | Wired |
| Playback diagnostics HUD | Switch | Live engine, fps, dropped frames, A/V drift, bitrate, buffer depth over the video | Wired |
| Scrub preview frames | Switch | Decodes a frame every 30s so the progress bar can show the scene being sought. Costs a second connection and decoder | Wired |
| Show input debug | Switch | Overlays the last trackpad/remote event in the player | Wired |

---

## Trakt & SIMKL

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Separate Trakt & SIMKL per profile | Switch | Each profile connects its own accounts | Wired |

### SIMKL

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Login | Action | Sign in with a code on `simkl.com/pin` | Wired |
| Sync watch history | Switch | Two-way sync of watched movies & episodes (the ✓ badges) | Wired |
| Sync Continue Watching | Switch | Puts the next episode of every "watching" show into Continue Watching. SIMKL stores no position, so those start at the beginning | Wired |
| Sync watchlist | Switch | Library and SIMKL's plan-to-watch fill each other in. Removals stay local | Wired |
| Sync ratings | Switch | Two-way sync of 1–10 star ratings | Wired |
| Sync now | Action | Runs a sync immediately | Wired |

### Trakt

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Login | Action | Sign in with a code on `trakt.tv/activate` | Wired |
| Scrobble playback | Switch | Automatically marks what you watch on Trakt | Wired |
| Sync watch history | Switch | Two-way sync of watched movies & episodes | Wired |
| Sync Continue Watching | Switch | Pulls in-progress movies & episodes from Trakt into the CW row | Wired |
| Sync watchlist | Switch | Two-way sync between Library and the Trakt watchlist | Wired |
| Sync ratings | Switch | Two-way sync of 1–10 star ratings | Wired |
| Sync now | Action | Runs a sync immediately | Wired |
| Clear Trakt Continue Watching | Action | Empties Trakt's in-progress list. Watched history is **not** touched | Wired |

---

## About

| Control | Type | What it does | Works? |
| --- | --- | --- | --- |
| Privacy Policy | Value card | Opens the privacy policy | Wired |
| Licenses & Attributions | Value card | Open-source components used in the app | Wired |
| System | Value card | tvOS version and device model | Wired |
| Clear cache | Action | Removes cached source lists, metadata and images | Wired |

---

## Known interactions with open bugs

Three settings are entangled with bugs currently being worked:

**Prefer same source group** (Playback → Auto-play) — when Auto Pick advances an
episode it deliberately prefers the same release group / same addon as the
episode just watched, *ahead of the top-ranked link*. If Auto Pick appears to
"choose the second source" while the first looks fine, this setting is the most
likely explanation, and it is working as designed. Turning it off makes the
advance take the best-ranked playable link instead.

**Match content display mode** (Playback → Player) — this only governs *non-DV*
content; Dolby Vision requests its mode regardless. Both paths funnel through a
session display pin that, until recently, recorded only the refresh rate and not
the dynamic range — which meant only the first title of each foreground stint
could set the TV's HDR mode, and a DV title opened after anything else played
out as plain HDR.

**Hybrid disk cache** (Playback → Player) — on by default. It opens a parallel
download pool against the stream origin and ramps up until the server pushes
back with 429s. For a self-hosted aggregator that also proxies the media, this is
worth knowing about when diagnosing "Source Failed" errors: turning it off
removes the pool entirely, at the cost of instant seeking.

---

## Method and limits

- Control inventory extracted from the Settings view sources by parsing the
  balanced argument list of every row constructor (`SettingsToggleCard`,
  `SettingsGroupCard`, `PerfToggleRow`, `PlaybackToggleRow`, `OrivioDropdown`,
  `SettingsActionRow`, `SettingsValueCard` and the bespoke key/provider rows),
  then read back against the source for the panes the parser handled poorly.
- Wiring determined by tracing each stored property to a reader outside its own
  store and outside the Settings views — then re-checking every apparent orphan
  for consumption through a computed aggregate.
- **Not verified on an Apple TV.** "Wired" means connected in code. It does not
  mean each control was exercised on device.
- Behaviour of individual add-ons, debrid providers and TorrServer instances is
  outside what static analysis can confirm.
