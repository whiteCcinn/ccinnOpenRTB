# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Generating the sample video (`ccinn-sample://media/sample-15s.mp4`) could fail with "the writer stalled", mostly on a busy Mac. The audio track was finished before the video track, but its input was left open, and AVAssetWriter then waited for more audio forever and stopped taking video frames. Now AVAssetWriter pulls each track, and each track is marked finished as soon as its last sample is in. A writer that makes no progress is still cancelled after 30 s.
- Sample media generation no longer leaves AVAssetWriter's temporary side file (`*.sb-*`) next to the generated file. The file stayed there until the writer was released, and for good when a generation failed. Now the writer is released before generation returns, and each generation writes into its own temporary directory, which is removed afterwards.

## [1.0.0] - Unreleased

First public release.

### Added

- **Input.** Paste an OpenRTB 2.x (2.0–2.6) or 3.0 + AdCOM bid response, a bare `adm` (HTML, Native JSON or VAST XML) or a VAST tag URL; the type and version are detected automatically. Parsing is lenient: wrong types become validation issues and unknown fields are kept. Every bid across all seats can be picked. An optional bid request resolves Native asset types, impression sizes and placement, and request-side macros. A no-bid response shows its `nbr` reason.
- **Rendering** in a device frame:
  - HTML and rich media in a sandboxed web view with an MRAID 3.0 shim whose calls are logged;
  - OpenRTB 3.0 image banners;
  - Native 1.0–1.2 in in-feed, content-stream and app-install layouts;
  - VAST 2.0–4.2 video and audio with skip, mute, pause, countdown, click-through, progress, companions, ad pods and wrapper chains up to 5 levels; VPAID is reported as error 901, SIMID/OMID scripts are listed but not executed;
  - placements: inline banner, in-feed, interstitial, rewarded and CTV instream, with full-screen pods and remote-style focus on CTV.
- **Devices:** iPhone SE (3rd gen) to 16 Pro Max, Pixel 8, Galaxy S24, Fold-class foldables (folded or unfolded), a Surface Duo-class dual-screen device (single or spanned), iPad (10th gen), iPad Pro 11, and Apple TV 4K, Google TV / Android TV, Fire TV and Roku in 1080p and 4K. Each device carries its OpenRTB `devicetype`, OS, User-Agent and screen geometry.
- **Tracking:** win `nurl`, billing `burl`, loss `lurl`, impressions, viewability, VAST events, clicks and errors fire when an SDK or player would fire them. OpenRTB `${AUCTION_*}` macros (with `:B64`), AdCOM `bid.macro` custom macros and VAST 4.x `[MACROS]` are expanded; unknown macros are reported. The clearing price, encrypted price, auction id and loss reason are editable. A viewability slider drives the MRC rules (50% for 1 s for display, 50% for 2 s for video), and Fire buttons trigger events by hand.
- **Simulated mode** (the default for every session) records every tracker and never sends it, enforced in the structure of the code. The HTML creative's own network is blocked and attempted loads are shown as `blocked`; **Allow creative network** lifts the block for the session.
- **Real mode** after a per-session confirmation that lists the tracker hosts of the selected bid. Trackers are sent with the simulated device's User-Agent; redirects are not followed automatically, and each hop (at most 10, loops detected) is recorded as a child entry with status, timing, headers and size. Click-throughs open in the default browser only when **Settings ▸ Network ▸ Open click-throughs in browser in Real mode** is on (off by default); CTV never navigates.
- **Content** needed to render (VAST wrapper and tag fetches, images, media, `dcourl`) is fetched in both modes. `data:` URLs are decoded locally.
- **Network window** (Window ▸ Network, ⌥⌘N): a real-time table with category, trigger, mode, status and duration; a relationship tree (wrapper chains, redirects, win-notice markup → creative loads, click → navigation); a waterfall timeline; details with the URL template, the expanded URL and its macros, query parameters, headers, redirect chain and response preview; filters by category, mode and text; follow tail; clear; **Export HAR 1.2** with custom `_ccinn` fields; **Copy URL**; **Copy as curl** (shell-quoted, with `--globoff`). At most 10,000 entries per session.
- **Validation** against the detected OpenRTB, Native and VAST versions, with severity, code, message and location for every issue.
- **Built-in samples** for every supported format and version, working offline. Sample media (a 15 s 1280×720 H.264 MP4 with a timecode, a 15 s AAC tone and PNG images) is generated locally on first use and cached under `~/Library/Caches`.
- **Settings:** General (appearance, automatic update check, **Check Now**, version and project links) and Network (request timeout of 5, 10, 15, 30 or 60 s, default 15 s; opening click-throughs in Real mode, default off).
- **Check for Updates…** in the app menu, a quiet daily check that can be turned off, **Skip This Version**, and **Download & Open**, which verifies the disk image against the release's `SHA256SUMS.txt`. Project links in the Help menu and the About window.
- Launch arguments for checks: `--demo-network`, `--snapshot-network <file.png>` (with `--network-layout`, `--network-select`, `--snapshot-delay`, `--quit-after-snapshot`) and `--no-update-check`.

[Unreleased]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/whiteCcinn/ccinnopenrtb/releases/tag/v1.0.0
