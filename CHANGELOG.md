# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Format VAST, Native JSON and banner HTML.** **Format** (⇧⌘F) in the Response, Request and Client editors now pretty-prints VAST / XML and HTML as well as JSON. It used to be JSON only, and disabled for anything else. Only whitespace changes: VAST gets one element per line with text and CDATA kept as typed; HTML gets line breaks only around block elements, `<br>` and the head, never inside an inline run or next to an element that is not rendered (`hidden`, `template`, `display: none`), so the creative renders as before; `script` (as a browser reads it, legacy `<!-- … -->` scripts included), `style`, `pre` and `white-space: pre` content are kept as typed. Indentation stops deepening after 32 levels, so the output stays proportional to the input. A mismatched XML tag is named with its line.
- **Markup copied out of a JSON string.** Format unescapes text copied from a log or an `adm` value first (`<VAST version=\"3.0\">`, Go's `\u003c…`, wrapped in quotes, or escaped twice), and pasting it into the Response or Request editor reads it unescaped straight away (info `input.unescaped` / `request.unescaped`), so the ad renders without editing. Pretty-printed JSON from a log (`{\n  \"id\"…`) and PHP's escaped slashes (`<\/script>`) are recognised. Real markup is never touched: only text whose every quote is escaped, and which starts escaped or has an attribute quoted with `\"` outside scripts and single-quoted values, counts. A banner's `document.write('<img src=\"…\">')` is JavaScript, not escaping.
- **Inspector ▸ Markup.** The selected bid's markup formatted, and as the device receives it once the exchange's macros are substituted, with **Copy**. Previously a bid's `adm` could only be read as one escaped line of the response.
- **Formatted bodies.** The Network window's body previews (VAST wrapper answers, bid requests and responses) have **Formatted** and **Raw**; the Client tab formats XML and HTML response bodies too.
- **Validation: `adm` escaped twice.** A bid whose `adm` is still JSON-escaped after the response is decoded (2.x `adm`, 3.0 `display.adm`, `video.adm`, `audio.adm`) gets the warning `openrtb.bid.adm.escaped`. It is rendered as received, as a device would get it.

## [1.5.0] - 2026-11-23

### Added

- **Groups for saved requests.** Right-click a saved request (or use **Move to** in the footer for a selection) › **Move to Group** › an existing group or **New Group…**, or **Remove from Group**. Once any request has a group, **Saved** shows a section per group, by name, with "No Group" last; click a header to fold it (remembered across launches; a search shows every match), and its ⋯ menu has **Select All in Group**, **Rename Group…** and **Remove Group…** (the requests stay, ungrouped). A request is in one group at most; names are trimmed and ignore case, so "G24" and "g24" are one group. The search matches group names. Save, Save as New and Duplicate keep the group; it is an optional `group` field in the request's file, so exports carry it, files from earlier versions are ungrouped, and earlier versions ignore it. Moving a request counts as a change: the newer copy wins on import. A folded group's requests are not selected by **Select All** and so never deleted by it.
- **Select and delete several saved requests.** In **Saved**, ⌘-click adds or removes a request and ⇧-click selects a range; the footer then shows how many are selected, with **Select All** (or ⌘A), **Deselect** and **Delete…**. The Delete key, the context menu of a selected row ("Delete 4 Requests…") and the footer delete them all after one confirmation. A plain click still opens a request. Only requests the search lists can be selected: searching again drops hidden ones from the selection. A request that cannot be deleted stays listed with the reason, and the others are deleted all the same; a deleted request open in a Client tab stays there as unsaved. The folder is read once for the whole selection, removing every copy of each request's file as before.

### Fixed

- **Real-mode script trackers stop the moment Real mode ends.** Leaving Real, rendering again, Reset and Lose now tear a Native `jstracker` / `eventtrackers` script page down in that same step. It used to happen at the window's next update, so with the window hidden or the Mac busy a hidden tracker page could keep beating for a few seconds after the switch to Simulated (seen on CI). The acceptance test now checks that the teardown happens in the switch's own turn.


## [1.4.1] - 2026-11-22

### Fixed

- **Plain http works in the app.** The packaged app refused every `http://` load with "The resource could not be loaded because the App Transport Security policy requires the use of a secure connection" before it reached the network: Client bid requests to http endpoints, http trackers in Real mode, http sync hops, VAST media and creative assets. Builds run with `swift run` were not affected, so it went unnoticed. The bundle now allows cleartext, and the simulator's modes decide what is sent, as they always did. The bundle's `Info.plist` is `Resources/Info.plist`, checked by a test.

### Security

- Update checks and downloads now refuse http themselves, on the first request and on every redirect; App Transport Security used to do this for them. A redirect to http fails with its reason instead of a bare 3xx status.

## [1.4.0] - 2026-11-19

### Added

- **Prebid tab — official Prebid.js:** pick any Prebid.js release from npm (by default the newest at least two weeks old), add bidders from that release's adapter catalogue (aliases and GVL ids included) with their params as JSON, ad units (banner, outstream video, native) and static consent (TCF, US Privacy, GPP), and run the auction. The page loads the official per-version loader with exactly those adapters, from jsDelivr through the window's network gate into a cache (a release once loaded also runs Offline); every chunk keeps its `integrity`, so WebKit checks Prebid's own hashes. The page is at the publisher URL you enter — Prebid's referer detection and `location` read it — and emulates the device's screen, viewport, pixel ratio and platform; bidder requests carry the browser's `Origin`, `Referer` and `Sec-Fetch-*` and the device's User-Agent, and no cookies. Results: the bids (**Render** shows one on the device as that bidder's OpenRTB 2.6 bid), a timeline of Prebid's events, the user syncs the adapters asked for (**Use in Sync Tab**), and Prebid's warnings and errors. Every bidder request is a **Bid request** entry in the Network window; any other script is refused, and a content rule list blocks every other load.
- **The browser's rules on the Prebid page:** requests are built by WebKit's own `Request` (forbidden headers dropped, the body's `Content-Type` as Safari sets it); a cross-origin request gets its CORS preflight when one is due (recorded), and a response the bidder's CORS headers do not allow is withheld from Prebid as Safari would, with the reason in the Log; http from the https page is mixed content (loopback aside); only exposed response headers are readable. Chrome on Android sends its client hints and has `navigator.userAgentData`.

### Changed

- The window's panel tabs become a menu when the panel is too narrow for them all.

### Security

- The network gate refuses any composed request whose method or header could split on the wire — a method or header name that is not an HTTP token, a value with CR, LF or NUL — and `CONNECT`, `TRACE` and `TRACK`, whichever tab composed it (the Client tab already refused them in its own form).

## [1.3.0] - 2026-11-19

### Added

- **Sync tab — cookie mapping:** run a user-sync chain from a start URL on a publisher page as the device's browser would: the image request, every redirect followed, and the window's in-memory cookie jar read and filled on every hop. The browser follows the device or is chosen — Safari or an iOS app web view (WebKit: third-party cookies blocked), Chrome on Android (`SameSite=None; Secure`, Lax by default, CHIPS), an Android app WebView (third-party cookies off by default), Firefox (partitioned), a TV app — and sets both the cookie policy and the User-Agent. IAB consent URL macros are filled. Every hop shows the cookies sent, withheld (why), stored (attributes) and rejected (why); verdicts name the ids passed along, "no id" answers (`uid=0` …), placeholders a partner left unsubstituted (`$UID`, `{{.UID}}` …; templates passed along are not flagged), cookies the browser blocked, and what happened before a run failed. The jar follows the browsers' storage model (host-only vs Domain identity, no http overlay of Secure cookies, 400-day cap, 180 per domain). Run Again reuses the jar; the jar is never the Mac's cookies and never written to disk. Network window: a **User sync** category.

## [1.2.0] - 2026-11-19

### Added

- **Redirect following in the Client:** each request has a **Redirects** setting — **Follow all** (like `curl -L`: across origins, at most 10 hops, loops detected; `Authorization`, `Proxy-Authorization` and `Cookie` stay behind on a hop to another origin, and a downgrade to http is flagged), **Within the origin** (the default, as in 1.1.0) or **Don't follow**. Settings ▸ Network ▸ Client sets it for new requests; requests saved by 1.1.0 keep their behaviour.
- **The redirect chain:** a **Redirects** tab lists every request of the chain — method, URL, status, `Location`, time, body, what changed on the way and why the chain ended. A loop, too many hops or a target that is not http(s) is now an answer to inspect instead of an error. A redirect left unfollowed by the setting offers **Follow to ‹host› and Send**: the same request, following every redirect for that send only, opening on the chain. Copy as curl adds `--location` when the request follows all redirects.

## [1.1.0] - 2026-11-19

### Added

- **Client tab:** a Postman-like request composer in every window. Enter a method (POST or GET), an endpoint URL, headers (`Content-Type: application/json` and `x-openrtb-version: 2.6` by default) and the bid request body, and press **Send** (⌘↩). The response shows its status, time, size, headers and body (pretty-printed JSON). A 2xx response with a body goes into the Response editor and the request into the Request editor, so the simulator renders the bid with the format and placement the request and response imply; in Real mode the device waits for an explicit Render. **Copy as curl** copies exactly what Send would send.
- **Saved requests:** **Save** (⌘S) keeps a request with its last response and device; open it in any window to send it again, or render the saved response without sending anything. Duplicate, delete and search. Stored as one JSON file each in `~/Library/Application Support/CcinnOpenRTB/Requests/` (0700 folder, 0600 files); unreadable files are skipped and reported.
- **Move saved requests to another Mac:** **Export All…** writes every saved request and its last response to one JSON file (created `0600`); **Import…** on the other Mac reads it in one go, merging by id (a newer copy wins, so importing twice changes nothing). Damaged entries are skipped and counted; a file of another kind, a newer format or over 256 MiB is refused with a reason.
- **The request picks the ad unit:** `imp.rwdd` (or `imp.ext.is_rewarded_inventory`, `imp.ext.prebid.is_rewarded_inventory`; AdCOM `placement.reward`) suggests the Rewarded placement and `imp.instl` or `video.plcmt` 3 (AdCOM `display.instl`) Interstitial, before the format and size rules.
- **Network window:** a **Bid request** category with the request's method, headers and body in the details; Copy as curl repeats the body (`--data-raw`, so a body starting with `@` is never read as a file) and is disabled when the body was too large to keep; HAR exports the body as `postData`.

### Changed

- The default device is the iPhone 18 Pro.
- A bid request is redirected only within its origin: 307 and 308 repeat its method and body; 303, and 301 or 302 after a POST, continue as a GET without the body; a redirect to another host, scheme or port is shown as the response and not followed. A POST answered with 303 to its own URL is no longer taken for a redirect loop.

## [1.0.0] - 2026-11-18

First public release.

### Added

- **Input.** Paste an OpenRTB 2.x (2.0–2.6) or 3.0 + AdCOM bid response, a bare `adm` (HTML, Native JSON or VAST XML) or a VAST tag URL; the type and version are detected automatically. Parsing is lenient: wrong types become validation issues and unknown fields are kept. Every bid across all seats can be picked. An optional bid request resolves Native asset types, impression sizes and placement, and request-side macros. A no-bid response shows its `nbr` reason.
- **Rendering** in a device frame:
  - HTML and rich media in a sandboxed web view with an MRAID 3.0 shim whose calls are logged;
  - OpenRTB 3.0 image banners;
  - Native 1.0–1.2 in in-feed, content-stream and app-install layouts, with the privacy link, per-asset clicks (an asset's own link replaces the main link), a video asset played through the VAST player and Native 1.2 `assetsurl` assets; the ad is rendered once its icon and main image have loaded or failed (1 s at most);
  - VAST 2.0–4.2 video and audio with skip, mute, pause, countdown, click-through, progress, companions (shown from the ad's first frame, in the shared image → HTML → iframe → script order) or an end card, industry icons such as AdChoices, ad pods and wrapper chains up to 5 levels. `CompanionAds@required` is honoured (an ad whose required companions cannot be shown — on CTV, none can — is not played: error 602), a wrapper's `BlockedAdCategories` reject a matching ad (error 205), media is chosen by pixels and delivery, VPAID media is never chosen (an ad with only VPAID reports 403), and SIMID/OMID scripts are listed but not executed;
  - placements: inline banner, in-feed, interstitial, rewarded and CTV instream, chosen from the bid and changeable, with full-screen pods and remote-style focus on CTV. Close, skip and player controls have a 44 pt (Apple) or 50 pt (Android) hit area.
- **Who substitutes what.** Like an exchange (OpenRTB 2.6 §4.4), the simulator substitutes its `${AUCTION_*}` / `${OPENRTB_*}` macros only in the bid response: the inline `adm` (HTML, Native JSON or VAST XML, before the device sees it), `nurl`, `burl`, `lurl`, `purl`, AdCOM `display.event` and the banner link. VAST `[MACROS]` are the player's, in VAST URLs only: every tracking URL when it fires, and the VAST tag and `VASTAdTagURI` request URIs when they are fetched. Documents fetched later (the `nurl` response, `display.curl` markup, a wrapper's response, a pasted tag) keep `${…}` as written, with a warning in the inspector; Native trackers fire as written.
- **Devices:** 28 devices, each with its OpenRTB `devicetype`, OS and version, in-app web view User-Agent (the desktop-class one on iPads), screen geometry, system chrome and a mock app (news article, scrollable feed, full-screen container, TV home, second-screen list):
  - iPhone SE (3rd gen), 13 mini, 15, 15 Plus, 15 Pro, 15 Pro Max, 16 Pro, 16 Pro Max, 16e, 17, Air, 17 Pro, 17 Pro Max, 18 Pro and 18 Pro Max;
  - Pixel 8 and Galaxy S24;
  - the iPhone Duo, Galaxy Z Fold5 and Pixel Fold foldables, folded or unfolded;
  - the Surface Duo, on one screen or spanned across its hinge;
  - iPad (10th gen), iPad Pro 11" (4th gen) and iPad Pro 11" (M5);
  - Apple TV 4K, Google TV, Fire TV Stick 4K Max and Roku Express (1920×1080 pt, a remote, no click-through).

  The simulator's own text (empty-slot labels, renderer messages) never sits under a dual-screen hinge and is sized for the 10-foot UI on a TV.
- **Tracking:** win `nurl`, billing `burl`, loss `lurl`, impressions, viewability, VAST events, clicks and errors fire when an SDK or player would fire them. OpenRTB 2.x `${AUCTION_*}` and 3.0 `${OPENRTB_*}` macros (with `:B64`), AdCOM `bid.macro` keys as `${CUSTOM_KEY}` and VAST 4.x `[MACROS]` (list macros encoded item by item) are expanded; unknown macros are reported. `[ADPLAYHEAD]` is the playhead the event fired at, `[ASSETURI]` the chosen media file, `[BREAKPOSITION]` 1 in the CTV instream break and 4 elsewhere, `[ADCOUNT]` the ads that play, `[TIMESTAMP]` in the device's time zone or UTC, and `${AUCTION_LOSS}` 0 ("Bid Won") on every URL of a won bid. The clearing price, encrypted price, auction id, loss reason and request-side values are editable. A viewability slider and the in-feed scroll drive the MRC rules (50% for 1 s for display, 50% for 2 s for video), and Fire buttons trigger events by hand.
- **Network relationships.** A request's parent is the request that delivered the document its URL is in: VAST trackers, media and companions (an HTML or iframe companion's own loads and navigation included) hang under their wrapper or inline hop; the trackers, clicks, navigations and creative loads of markup delivered by `nurl` or `display.curl` hang under that request; URLs written in the bid response are roots; redirect hops hang under their tracker. A tracker never parents a navigation, and the requests of one click share one trigger.
- **Offline · Simulated · Real.** **Simulated** (the default for every session) never sends trackers or notices, enforced in the structure of the code; it does load the ad's content (VAST, images, video) from the URLs in the markup, which the ad server can see. **Offline** (opt-in, remembered per window) loads nothing from the network either: only `data:` URLs and built-in samples, the rest is recorded as `offline` and the ad says what is missing. Before Real mode is confirmed, nothing derived from the pasted request's personal data leaves the Mac: a VAST tag or wrapper URI fetched to render the ad carries `-1` for `[IFA]`, `[IFATYPE]`, `[DEVICEIP]`, `[LATLONG]`, `[GDPRCONSENT]`, `[GPPSTRING]` and `[GPPSECTIONID]`, and the simulated device's User-Agent for `[DEVICEUA]`; Real mode fills them from the request. The HTML creative's own network is blocked in both, with no way to lift the block; the loads its elements, `fetch`, XHR, `sendBeacon`, WebSocket and WebRTC attempt are shown as `blocked`.
- **Replays.** Rendering the same bid again replays its auction: every play after the first is "replay N" in the lifecycle log and in every Network source it causes.
- **Real mode** after a per-session confirmation for exactly one bid, device and placement: it lists the bid's tracker hosts, the requests that cannot be listed in advance, the content hosts the render already contacted, and warns when notices of the same auction were already sent this session (sending again may double-count at the DSP). Trackers are sent with the simulated device's User-Agent and an explicit `Accept-Language`, without cookies or credentials (authentication challenges are refused); redirects are not followed automatically, and each hop (at most 10, loops detected) is recorded as a child entry with status, timing, the headers actually sent and size. Script trackers (Native `jstracker`, method-2 event trackers) run once each in a hidden web view. Leaving Real, rendering again, Reset and Lose cancel trackers in flight and stop every Real-mode web view at once. Click-throughs open only when **Settings ▸ Network ▸ Open click-throughs in browser in Real mode** is on (off by default), and only in the default web browser; CTV never navigates.
- **The creative's container.** `mraid.open` and `mraid.playVideo` need a real user gesture; every bridge message carries a per-load secret, and messages the page forges are dropped and logged. The DNS-prefetch switch is placed by the HTML parser's own rules.
- **Content** needed to render (VAST wrapper and tag fetches, images, media, Native `assetsurl`, `display.curl` markup) is fetched in Simulated and Real mode; `data:` URLs are decoded locally, and `data:` media files are deleted when the render ends. Video and audio go through the network monitor (byte ranges; HLS through a loopback-only proxy), never through the media player's own networking. Native `dcourl` (DCO, beta) is logged as unsupported and not fetched.
- **Network window** (Window ▸ Network, ⌥⌘N): a real-time table with category, trigger, mode, status and duration, content marked with a CONTENT badge; a relationship tree; a waterfall timeline; details with the URL template (for a VAST tag or wrapper, the URI as written), the expanded URL and its macros, query parameters, the headers actually sent, redirect chain and response preview; filters by category, mode and text; follow tail; clear; **Export HAR 1.2** with custom `_ccinn` fields; **Copy URL**; **Copy as curl** (shell-quoted, with `--globoff`). At most 10,000 entries per session.
- **Validation** against the detected OpenRTB, Native and VAST versions, with severity, code, message and location for every issue.
- **Built-in samples** for every supported format and version, working offline. Sample media (a 15 s 1280×720 H.264 MP4 with a timecode, a 15 s AAC tone and PNG images) is generated locally on first use and cached under `~/Library/Caches`. Each track is pulled by AVAssetWriter and finished as soon as its last sample is in, a writer that makes no progress is cancelled after 30 s, each generation writes into its own temporary directory, and leftovers older than an hour are swept at launch. Generated sample images are at most 1920×1920, made one at a time, at most 32 a minute, in a 64 MiB cache.
- **Settings:** General (appearance, automatic update check, **Check Now**, version and project links) and Network (request timeout of 5, 10, 15, 30 or 60 s, default 15 s; opening click-throughs in Real mode, default off).
- **Check for Updates…** in the app menu, a quiet daily check that can be turned off, **Skip This Version**, and **Download & Open**, which verifies the disk image against the release's `SHA256SUMS.txt`. Project links in the Help menu and the About window.
- Launch arguments for checks: `--sample`, `--device`, `--placement`, `--mode offline|simulated|real`, `--landscape`, `--folded`, `--spanned`, `--visibility`, `--zoom`, `--no-render`, `--snapshot <file.png>` (the current video frame and any sheet drawn in; `--snapshot-delay`, `--quit-after-snapshot`), `--export-har <file.har>`, `--open-network`, `--demo-network`, `--snapshot-network <file.png>` (with `--network-layout`, `--network-select`) and `--no-update-check`.

[Unreleased]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnopenrtb/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnopenrtb/releases/tag/v1.0.0
