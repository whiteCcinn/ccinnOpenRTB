<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="CcinnOpenRTB icon">
</p>

<h1 align="center">CcinnOpenRTB</h1>

<p align="center">
  <b>A native OpenRTB ad rendering and tracking simulator for macOS.</b><br>
  Paste a bid response, see the ad on a simulated phone, foldable, tablet or TV, and watch every tracker in a real-time network view. No tracker is sent unless you ask for it.
</p>

<p align="center">
  <a href="https://github.com/whiteCcinn/ccinnopenrtb/actions/workflows/ci.yml"><img src="https://github.com/whiteCcinn/ccinnopenrtb/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whiteCcinn/ccinnopenrtb/releases/latest"><img src="https://img.shields.io/github/v/release/whiteCcinn/ccinnopenrtb?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/OpenRTB-2.x%20%C2%B7%203.0-5b5bd6" alt="OpenRTB 2.x and 3.0">
  <img src="https://img.shields.io/badge/VAST-2.0%E2%80%934.2-d9480f" alt="VAST 2.0 to 4.2">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT license"></a>
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="docs/images/simulator-vast.png" width="900" alt="A skippable VAST 3.0 ad with its companion on a simulated iPhone 17 Pro, next to the bid response">
</p>
<p align="center">
  <img src="docs/images/simulator-ctv.png" width="445" alt="A two-ad VAST 4.1 pod on a simulated Apple TV 4K">
  <img src="docs/images/network-window.png" width="445" alt="The Network window: a VAST wrapper chain, every tracker recorded in Simulated mode">
</p>

## Why CcinnOpenRTB?

Exchange, SSP, DSP and SDK engineers keep asking the same question: *what does this bid response actually render on a device, and which trackers fire, in what order?* Answering it usually means one of these:

- reading `adm` blobs by hand,
- pasting VAST into a web validator that knows nothing about OpenRTB,
- building a real SDK and pointing it at a test exchange.

CcinnOpenRTB answers it on your Mac. Paste an OpenRTB bid response, a bare `adm` or a VAST tag URL. The ad renders in a device frame the way an SDK or player would show it. Every win notice, impression, viewability event, VAST event, click and error appears in the Network window, with expanded macros, timing and the event that caused it.

By default no tracker is sent: see [Simulated and Real mode](#simulated-and-real-mode). The app is native SwiftUI/AppKit, with no third-party dependencies, no bundled runtime and no telemetry.

## Simulated and Real mode

Every session starts in **Simulated** mode. Trackers are recorded with their fully expanded URLs and are **never sent**. This is enforced in the structure of the code, not only by tests: the HTTP transport can only be called with a send permit, and no permit exists for a tracker in Simulated mode. Switch to **Real** only when you want trackers to reach their servers.

| | Simulated (default) | Real |
|---|---|---|
| **Trackers**: win `nurl`, billing `burl`, loss `lurl`, impressions, viewability, VAST events, clicks, errors | Recorded, **never sent** | Sent with the simulated device's User-Agent. Status, timing, headers and size are recorded. |
| **Tracker redirects** | Nothing is sent, so there are none | Not followed automatically. The app follows each hop itself and records it as a child entry (at most 10 hops; loops are detected). |
| **Script trackers**: Native `jstracker`, `eventtrackers` and AdCOM events with method 2 | Recorded, not run | Recorded, then each run once in its own hidden web view; the loads it makes are its child entries |
| **The HTML creative's own network**: scripts, pixels, `fetch`, XHR, beacons | Blocked by a WebKit content rule list; nothing lifts the block in Simulated mode. Loads through elements (`img`, `script`, `iframe`, `link`, media, `object`, `embed`), `fetch`, XHR, `sendBeacon`, WebSocket and WebRTC appear as `blocked`. Loads from CSS (`url()`, fonts, `@import`), `EventSource`, `<a ping>` and workers are blocked without an entry. | Not blocked |
| **Content needed to render**: VAST wrapper and tag fetches, images, media, Native `assetsurl`, markup by reference (AdCOM `display.curl`) | Fetched | Fetched |
| **Markup delivered by the win notice** (a bid with `nurl` and no `adm`) | Not fetched: the win notice is a tracker. The ad slot says so; switching to Real fetches it | The `nurl` response body is the markup, and the URLs inside it hang under that request |
| **`data:` URLs and built-in sample media** (`ccinn-sample://`) | Decoded or generated on the Mac | Decoded or generated on the Mac |
| **Click-throughs** | Recorded as navigation, never opened | Recorded. Opened in the default browser only when **Settings ▸ Network ▸ Open click-throughs in browser in Real mode** is on (off by default). |

- Switching to Real asks for confirmation and lists the tracker hosts of the selected bid. Cancelling keeps Simulated mode.
- The confirmation lasts for the current session only. The next session starts in Simulated mode again.
- The mode is shown in the toolbar and on every entry in the Network window.
- CTV devices never navigate, in either mode.
- Native 1.2 `dcourl` (dynamic creative, beta in the spec) is logged as unsupported and never fetched.
- Apart from the requests above, the only thing that leaves your Mac is the once-a-day update check against GitHub, which you can turn off.

> [!WARNING]
> Real mode sends real trackers. To the receiving server they look like traffic from the simulated device, so they can inflate the numbers of a live campaign. Use Real mode with your own test endpoints, or with the agreement of whoever owns the trackers.

## Features

- **Paste what an exchange returns.** An OpenRTB 2.x or 3.0 bid response, a bare `adm` (HTML, Native JSON or VAST XML) or a VAST tag URL. The input type and version are detected automatically. Parsing is lenient: wrong types become validation issues and unknown fields are kept. A no-bid response shows "No bid" with the `nbr` reason named.
- **The exchange's part, too.** Like an exchange (OpenRTB 2.6 §4.4), the simulator substitutes its `${AUCTION_*}` / `${OPENRTB_*}` macros in the bid's inline `adm` — HTML, Native JSON or VAST XML — before the device sees it; VAST `[MACROS]` stay for the player and are filled when each tracker fires. Markup the DSP returns after the win (`nurl` response, `display.curl`) is used as delivered.
- **Pick the bid.** Every bid across all seats is listed with its format. Optionally paste the bid request too: it resolves Native asset types, the impression size and placement, and request-side macros.
- **Render it as a device would**
  - HTML and rich media in a sandboxed web view with an MRAID 3.0 bridge. Bridge calls are logged. Clicks and navigations are recorded instead of leaving the simulator.
  - Image banners (OpenRTB 3.0 `display.banner`).
  - Native 1.0, 1.1 and 1.2 in in-feed, content-stream and app-install layouts, with the privacy link and per-asset clicks.
  - VAST video and audio: skip (from `skipoffset`), mute, pause, countdown, click-through, progress bar, companions (shown from the ad's first frame) or an end card, ad pods in `sequence` order, and wrapper chains up to 5 levels.
  - Placements: inline banner, in-feed, interstitial, rewarded and CTV instream. The bid picks a sensible one (a 320×480 bid is an interstitial, a CTV device plays instream); you can change it. Full-screen ads have a close control with a 44 pt (Apple) or 50 pt (Android) hit area; a non-skippable video offers it when it ends.
  - CTV: full-screen pod playback ("Ad 1 of 2"), remote-style focus with the arrow keys, Return, Escape and Space, and no click-through.
- **Devices.** 28 devices: iPhones from SE to 18 Pro Max, Android phones, foldables including the iPhone Duo (folded or unfolded), the Surface Duo (one screen or spanned across the hinge), iPads and four CTV platforms, in portrait or landscape, each with its own system chrome and mock app. See [Devices](#devices).
- **Tracking at the right moment.** Trackers fire when a real SDK or player would fire them, with OpenRTB, AdCOM and VAST macros expanded and unknown macros reported. A **Viewability** slider scrolls the ad in and out of view and drives the MRC rules: 50% for 1 s for display, 50% for 2 s for video. **Fire** buttons trigger events by hand. See [Tracking and macros](#tracking-and-macros).
- **Network window.** Every request in real time as a table, a relationship tree and a waterfall, with details, filters, HAR export and copy as curl. See [The Network window](#the-network-window).
- **Validation.** The inspector checks the response against the detected OpenRTB, Native and VAST versions: required fields, wrong types, invalid URLs, non-HTTPS trackers when the request requires secure creatives, missing playable media, wrapper depth, and fields that belong to another version. Each issue has a severity, a code, a message and a location (a JSON pointer or a VAST element path).
- **Samples that work offline.** Built-in samples cover every supported format and version: HTML and MRAID, Native 1.0–1.2, VAST 2.0–4.2 (a wrapper chain, a CTV pod and an audio ad included), OpenRTB 3.0 and a no-bid. Sample media is generated on the Mac on first use and cached under `~/Library/Caches`: a 15 s 1280×720 H.264 MP4 with a timecode, a 15 s AAC tone, and PNG images.

## The Network window

Open it with **Window ▸ Network** (**⌥⌘N**). There is one Network window; it shows the session of the focused main window.

- **List**, updated in real time: sequence, relative time (+ms), category, trigger, host and path, mode, status and duration.
- **Tree** of relationships. A request's parent is the request that delivered the document its URL is in: each VAST tracker, media file and companion (its image, an HTML or iframe companion's own loads and navigation) hangs under the wrapper or inline hop that delivered it; the trackers, clicks, navigations and creative loads of markup delivered by `nurl` or `display.curl` hang under that request; URLs written in the bid response itself (`nurl`, `burl`, `lurl`, AdCOM events, the AdCOM banner link) are roots. Redirect hops hang under their tracker. A tracker never parents a navigation: the requests of one click share its trigger.
- **Waterfall** timeline.
- **Details**: the URL template next to the expanded URL with macros highlighted, replaced and unknown macros, query parameters, request and response headers, the redirect chain, and a response preview for content.
- **Filters** by category, mode and text. **Follow tail** keeps the newest entry in view. **Clear** empties the session's list.
- **Export HAR 1.2.** Entries carry custom `_ccinn` fields: `sequence`, `category`, `trigger`, `source`, `mode`, `delivery`, `parent`, `template` and `macros`.
- **Copy URL** and **Copy as curl**. The curl command is shell-quoted and uses `--globoff`, so VAST `[MACROS]` are not read as curl globs.
- A session keeps at most 10,000 entries. The oldest are dropped first.

| Category | What it is |
|---|---|
| `win` | Win notice: `nurl` (2.x) or `purl` (3.0) |
| `billing` | Billing notice: `burl` |
| `loss` | Loss notice: `lurl` |
| `impression` | VAST `Impression`, Native `imptrackers` and impression event trackers, AdCOM impression events |
| `viewability` | Native `eventtrackers` 2–4, AdCOM events 3–5, VAST `ViewableImpression` |
| `event` | VAST tracking events: `creativeView`, `start`, quartiles, `complete`, `progress`, `mute`, `pause`, `skip`, … |
| `click` | Native `clicktrackers`, VAST `ClickTracking` and `CompanionClickTracking` |
| `navigation` | A click-through target: Native `link.url`, VAST `ClickThrough`, `mraid.open`, `window.open`, links |
| `error` | VAST `Error` URLs with `[ERRORCODE]` |
| `verification` | VAST `AdVerifications` tracking, such as `verificationNotExecuted` |
| `content` | What the app fetches to render the ad: VAST wrappers and tags, images, media, Native `assetsurl`, `display.curl` markup |
| `creative` | Whatever the HTML creative loads, or tries to load |

In HAR exports the mode is `_ccinn.delivery`: `simulated`, `network` (Sent), `blocked`, `local`, `renderer` or `browser`; `_ccinn.mode` is the session's tracking mode.

| Mode | Meaning |
|---|---|
| Simulated | Recorded, not sent |
| Sent | Sent by the app: a tracker in Real mode, or a content fetch |
| Blocked | The creative tried to load it, and the Simulated-mode sandbox blocked it |
| Local | Served on the Mac: a `data:` URL or built-in sample media |
| Renderer | Loaded by the web view or the media player itself: video media, allowed creative loads, injected script trackers |
| Browser | A click-through opened in the default browser |

## Tracking and macros

| When | What fires |
|---|---|
| Win | `nurl` (2.x) or `purl` (3.0) |
| Render | `burl`, AdCOM event types 1 (loaded) and 2 (impression), Native `imptrackers` and `eventtrackers` event 1. For VAST, the first frame of the first ad that actually plays |
| First frame of each VAST ad | That ad's `Impression` URLs from every document in its wrapper chain, its `creativeView` tracking, and `verificationNotExecuted` for its verification resources |
| Viewable | Native `eventtrackers` 2–4, AdCOM events 3–5 and VAST `ViewableImpression`, once the MRC rule is met (display: 50% in view for 1 s; video: 50% for 2 s) |
| Playback | `start`, `firstQuartile`, `midpoint`, `thirdQuartile`, `complete`, `mute`, `unmute`, `pause`, `resume`, `skip`, `fullscreen`, `close`, … once per ad; `progress` once per offset |
| Companion shown | The companion's `creativeView` (after its ad's impression), with the matching wrapper companions' tracking first |
| Click | Native `clicktrackers` (asset link first), VAST `ClickTracking` or `CompanionClickTracking`; then the click-through is recorded as navigation |
| Loss | `lurl` with `${AUCTION_LOSS}` |
| Error | VAST `Error` URLs with `[ERRORCODE]`, for example 303 when a wrapper chain ends without an ad, 403 when no media file is playable, 901 for VPAID |

| Family | Macros |
|---|---|
| OpenRTB | `${AUCTION_ID}`, `${AUCTION_BID_ID}`, `${AUCTION_IMP_ID}`, `${AUCTION_SEAT_ID}`, `${AUCTION_AD_ID}`, `${AUCTION_PRICE}`, `${AUCTION_CURRENCY}`, `${AUCTION_MBR}`, `${AUCTION_LOSS}`, `${AUCTION_MIN_TO_WIN}`, and their `:B64` variants (base64url) |
| OpenRTB 3.0 | `${OPENRTB_ID}`, `${OPENRTB_BID_ID}`, `${OPENRTB_ITEM_ID}`, `${OPENRTB_SEAT_ID}`, `${OPENRTB_MEDIA_ID}`, `${OPENRTB_PRICE}`, `${OPENRTB_CURRENCY}`, `${OPENRTB_LOSS}`, `${OPENRTB_MIN_TO_WIN}`, …; the bid's `bid.macro` keys as `${CUSTOM_KEY}` |
| Exchange | A bare `${KEY}` is a macro you define in the Macros panel |
| VAST 4.x | `[ERRORCODE]`, `[TIMESTAMP]`, `[CACHEBUSTING]`, `[ADPLAYHEAD]`, `[CONTENTPLAYHEAD]`, `[ASSETURI]`, `[PLAYERSIZE]`, `[PODSEQUENCE]`, `[ADSERVINGID]`, `[UNIVERSALADID]`, `[DEVICEUA]`, `[IFA]`, `[REASON]`, … (values are URL-encoded; list macros encode each item and keep literal commas; a known macro without a value is `-1`) |

- Unknown macros are left in place and reported, in the inspector and in the entry's details.
- You can edit the macro values: the clearing price (defaults to the bid price), an encrypted price (an opaque string substituted verbatim for `${AUCTION_PRICE}`), the auction id, the loss reason and custom macros.

## Compatibility

| Specification | Versions | Notes |
|---|---|---|
| OpenRTB | 2.0 – 2.6 | The version is inferred: 2.6 when `mtype` or other 2.6 fields are present, 2.5 when `burl` or `lurl` are, otherwise 2.x. |
| OpenRTB + AdCOM | 3.0 + AdCOM 1.0 | `display` (`adm`, `banner`, `native`, `event`), `video` and `audio` (`adm`, `curl`), `bid.macro`. |
| OpenRTB Native | 1.0, 1.1, 1.2 | Wrapped (`{"native": …}`) and unwrapped. Without the bid request, 1.0/1.1 data asset types are inferred and labelled "inferred". |
| VAST | 2.0, 3.0, 4.0, 4.1, 4.2 | Wrappers up to 5 levels, ad pods, companions. VPAID is reported as error 901. SIMID and OMID verification scripts are listed, not executed. |
| MRAID | 3.0 | A shim injected into HTML creatives. Every bridge call is logged. |

CcinnOpenRTB runs on **macOS 14 Sonoma or later** (Apple silicon and Intel).

### Devices

| Family | Devices |
|---|---|
| iPhone | iPhone SE (3rd gen), 13 mini, 15, 15 Plus, 15 Pro, 15 Pro Max, 16 Pro, 16 Pro Max, 16e, 17, Air, 17 Pro, 17 Pro Max, 18 Pro, 18 Pro Max (notch, Dynamic Island or home button, each with its own safe area) |
| Android phone | Pixel 8, Galaxy S24 |
| Foldable | iPhone Duo (951×669 pt open, an iPhone-style cover screen when folded), Galaxy Z Fold5, Pixel Fold — folded or unfolded |
| Dual-screen | Surface Duo: one screen, or spanned across its 34 pt hinge |
| Tablet | iPad (10th gen), iPad Pro 11" (4th gen), iPad Pro 11" (M5) |
| CTV | Apple TV 4K, Google TV (4K TV), Fire TV Stick 4K Max (2nd gen), Roku Express (1080p): 1920×1080 pt, a remote, no click-through |

Each device carries its OpenRTB `devicetype`, OS and version (iOS / iPadOS / tvOS 27.2, Android 17 — the Surface Duo stays on 12 — Android TV 14, Fire OS 8.1.8.5, Roku OS 15.3), the User-Agent of its in-app web view and screen geometry (size, scale, corner radius, safe area, cutout, hinge or folded screen). These are used for rendering, for choosing a VAST media file, for macros such as `[DEVICEUA]`, and as the User-Agent of trackers sent in Real mode. CTV is landscape only.

## Installation

1. Download `CcinnOpenRTB-<version>.dmg` (or the `.zip`) from the [latest release](https://github.com/whiteCcinn/ccinnopenrtb/releases/latest).
2. Open the disk image and drag **CcinnOpenRTB** into **Applications**.
3. The app is ad-hoc signed but not notarized. The first time, right-click the app and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/CcinnOpenRTB.app
   ```

Each release lists SHA-256 checksums in `SHA256SUMS.txt`.

### Updating

Choose **CcinnOpenRTB ▸ Check for Updates…**. If a newer release exists, CcinnOpenRTB shows what's new. **Download & Open** saves the disk image to your Downloads folder, checks it against the release's `SHA256SUMS.txt`, and opens it. Quit CcinnOpenRTB, then drag the new version onto **Applications**.

CcinnOpenRTB also checks quietly once a day; turn this off in **Settings ▸ General**. The check contacts only GitHub's public releases API, and you can **Skip This Version**.

The project page, release notes and issue tracker are also in the **Help** menu, the About window and **Settings ▸ General**.

## Quick start

1. Pick a built-in sample, or paste an OpenRTB bid response, a bare `adm` or a VAST tag URL into the **Response** editor on the right.
2. Choose a device, an orientation and a placement. The simulator on the left renders the selected bid.
3. Press **⌥⌘N** to open the Network window and watch the trackers fire. Move the **Viewability** slider, or use the **Fire** buttons, to trigger more events.
4. Optionally paste the bid request into **Request**, pick another seat or bid, and set the clearing price or other macro values.

| Shortcut | Action |
|---|---|
| **⌥⌘N** | Network window |
| **⌘K** | Clear the Network window's list |
| **⌘,** | Settings |

More shortcuts are listed in the menus.

## Settings

- **General**
  - Appearance.
  - Automatic update check, and **Check Now**.
  - Version and project links.
- **Network**
  - Every session starts in Simulated mode. This is deliberately not a setting: Real mode is switched on per session, with a confirmation.
  - **Request timeout**: 5, 10, 15, 30 or 60 s. The default is 15 s.
  - **Open click-throughs in browser in Real mode**: off by default. While it is off, click-throughs are only recorded.

## Building from source

Requirements: macOS 14+, Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/whiteCcinn/ccinnopenrtb.git && cd ccinnopenrtb
swift build                          # debug build
swift test                           # unit, renderer and end-to-end acceptance tests
scripts/build-app.sh --open          # build dist/CcinnOpenRTB.app and launch it
scripts/package-release.sh 1.0.0     # universal .app, .zip, .dmg and checksums in dist/
```

### Launch arguments for checks

```bash
dist/CcinnOpenRTB.app/Contents/MacOS/CcinnOpenRTB --sample ortb26-vast42-verification --device iphone-17-pro \
  --snapshot /tmp/vast.png --export-har /tmp/vast.har --quit-after-snapshot
```

| Argument | Effect |
|---|---|
| `--sample <id>` | Loads a built-in sample (its id, as in `SampleLibrary`) and renders it. `--no-render` only loads it. |
| `--device <id>`, `--landscape`, `--folded`, `--spanned` | The device and its posture. |
| `--placement <name>`, `--visibility <0…1>`, `--zoom fit\|<scale>` | Placement (`in-feed`, `interstitial`, …), the ad's visible fraction, the canvas zoom. |
| `--mode simulated\|real` | `real` only shows the confirmation: the command line never switches Real mode on by itself. |
| `--snapshot <file.png>` | Renders the main window to a PNG after `--snapshot-delay <s>` (default 4), once it has finished drawing, with the current video frame and any sheet (such as the Real-mode confirmation) drawn in. `--quit-after-snapshot` quits afterwards, cancelling a pending confirmation. |
| `--export-har <file.har>` | Writes the window's network log (HAR 1.2 with the `_ccinn` relationships) after the snapshot. |
| `--open-network` | Opens the Network window. |
| `--demo-network` | Fills the Network window with synthetic entries, so it can be checked without rendering an ad. |
| `--snapshot-network <file.png>` | Renders the Network window to a PNG (with `--snapshot-delay <s>`, `--quit-after-snapshot`), without screen-recording permission. |
| `--network-layout list\|tree\|waterfall`, `--network-select <sequence>` | The layout and the selected request for that snapshot. |
| `--no-update-check` | Skips the automatic update check. |

## Architecture

```
CcinnOpenRTB (SwiftUI app: shell, simulator, renderers, Network window)
 └─ CcinnOpenRTBKit   network monitor: Simulated/Real dispatch, URLSession transport without auto-redirects, HAR, curl; sample media; updates
     └─ RTBKit        Foundation only: OpenRTB 2.x/3.0, Native, VAST parsing and wrapper resolution, macros, tracking plan, devices, validation, samples
```

- **A deterministic core.** RTBKit uses only Foundation and does no I/O. Parsing, wrapper merging, macro expansion and the tracking plan are pure functions of their input, so the order of trackers is covered by unit tests. VAST wrapper fetches go through a `VASTFetcher` protocol that the app implements on top of the network monitor.
- **One gate to the network.** Every request goes through one dispatch policy. The transport can only be called with a send permit, and the policy issues none for a tracker in Simulated mode. Switching back to Simulated stops a tracker's redirect chain before its next hop.
- **Every hop is visible.** The transport sends exactly one request and never follows redirects. The monitor records each 3xx and follows it itself.
- **Never crash on input.** Wrong types and missing fields become validation issues with a location; unknown fields are kept.
- **Concurrency safety.** The project builds in Swift 6 strict-concurrency mode. Network updates are batched before they reach the UI, so a burst of trackers does not stall the window.

## The ccinn series

Native macOS tools that share the same design, speed and care:

| App | What it is |
|---|---|
| [**CcinnMongo**](https://github.com/whiteCcinn/ccinnmongo) | Native MongoDB client for every server from 2.6 to 8.x, with the legacy `OP_QUERY` and the modern `OP_MSG` protocols. |
| [**CcinnStarRocks**](https://github.com/whiteCcinn/ccinnstarrocks) | Native StarRocks client: partitions, tablets and skew, materialized views, running tasks, SQL with completion and charts. |
| [**CcinnRedis**](https://github.com/whiteCcinn/ccinnredis) | Native Redis client for Redis 2.8 → 8.x and Valkey, in standalone, Sentinel, Cluster and proxy deployments. |
| [**CcinnBucket**](https://github.com/whiteCcinn/ccinnbucket) | Object storage browser for Amazon S3, S3-compatible services and Alibaba Cloud OSS. |
| [**CcinnMysql**](https://github.com/whiteCcinn/ccinnmysql) | Native MySQL, MariaDB and Percona client for 5.5 → 9.x: TLS and every auth plugin, InnoDB locks, top statements, replication, visual EXPLAIN and safe inline editing. |
| [**CcinnPsql**](https://github.com/whiteCcinn/ccinnpsql) | Native PostgreSQL client for 9.6 → 18: blocking trees, index and bloat insights, replication and slots, visual EXPLAIN ANALYZE, PgBouncer and Pgpool awareness. |
| [**CcinnClickHouse**](https://github.com/whiteCcinn/ccinnclickhouse) | Native ClickHouse client for 22.8 → 26.x: engine families, parts and compression, merges, mutations, replication, query-log analysis and cluster topology. |
| **CcinnOpenRTB** *(this project)* | Native OpenRTB ad rendering and tracking simulator: OpenRTB 2.x/3.0, Native 1.0–1.2 and VAST 2.0–4.2 on simulated phones, foldables, tablets and TVs, with a real-time view of every tracker. |

## Contributors

- [whiteCcinn](https://github.com/whiteCcinn)

<a href="https://github.com/whiteCcinn/ccinnopenrtb/graphs/contributors"><img src="https://contrib.rocks/image?repo=whiteCcinn/ccinnopenrtb" alt="Contributors"></a>

## Star history

[![Star History Chart](https://api.star-history.com/svg?repos=whiteCcinn/ccinnopenrtb&type=Date)](https://star-history.com/#whiteCcinn/ccinnopenrtb&Date)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md), and report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 whiteCcinn. OpenRTB, AdCOM, Native and VAST are specifications of IAB Tech Lab; this project is not affiliated with or endorsed by IAB Tech Lab.
