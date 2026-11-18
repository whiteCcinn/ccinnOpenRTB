# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnOpenRTB.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnopenrtb/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (CcinnOpenRTB version, a minimal bid response or markup with real tracker hosts redacted, the device and the tracking mode),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## What goes on the network in each mode

Simulated mode never sends trackers or notices; it does load the ad's content (VAST, images, video) from the URLs in the markup, which the ad server can see. Choose Offline to load nothing.

| Traffic | Offline | Simulated (default) | Real |
|---|---|---|---|
| Trackers and notices: win, billing, loss, impression, viewability, VAST events, clicks, errors | Recorded, never sent | Recorded, never sent | Sent after a per-session confirmation that lists the tracker hosts, with the simulated device's User-Agent |
| Script trackers: Native `jstracker`, `eventtrackers` with method 2 | Recorded, not run | Recorded, not run | Each run once in its own hidden web view |
| The HTML creative's own network | Blocked | Blocked, with no way to lift the block. Loads through elements, `fetch`, XHR, `sendBeacon`, WebSocket and WebRTC are recorded as `blocked`; loads from CSS, `EventSource`, `<a ping>` and workers are blocked without a record | Not blocked |
| The ad's content: VAST tag and wrapper fetches, images, media, Native `assetsurl`, `display.curl` markup | Not loaded; recorded as `offline` | Fetched from the URLs in the markup | Fetched from the URLs in the markup |
| Click-through navigation | Recorded, never opened | Recorded, never opened | Recorded; opened only when **Open click-throughs in browser in Real mode** is on (off by default), and only in the default web browser. Never on CTV |
| Update check | Once a day unless turned off | Once a day unless turned off | Once a day unless turned off |

`data:` URLs and the built-in sample media (`ccinn-sample://`) are decoded or generated on the Mac and never reach the network. Nothing else leaves the Mac.

## Scope and design notes

- **Simulated mode never sends a tracker, and Offline loads nothing.** This is enforced in the structure of the code: every request — trackers, content, and the media player's byte ranges, HLS playlists and segments — goes through one dispatch policy, the HTTP transport can only be called with a send permit, and the policy issues none for a tracker in Simulated or Offline mode, nor for remote content when Offline. Leaving Real, rendering again, Reset and Lose cancel the trackers in flight at once and stop every Real-mode web view; a tracker's redirect chain stops before its next hop. Any way to make a tracker leave the Mac in Simulated or Offline mode, to make Offline load anything, or to make the creative reach the network while it is blocked, is a vulnerability.
- **Real mode can inflate real campaign numbers.** A tracker sent from CcinnOpenRTB carries the simulated device's User-Agent and counts like device traffic. That is why Real mode needs an explicit confirmation in every session, lists the hosts it will contact, and is shown in the toolbar and on every Network entry. Use it with your own test endpoints, or with the agreement of whoever owns the trackers.
- **Redirects are never followed automatically.** The transport sends one request per hop. The monitor records each hop and stops after 10 hops or at a loop.
- **Creatives are isolated.** HTML creatives run in a web view with a non-persistent data store, so cookies and storage they set disappear with the session. Clicks and navigations are intercepted and recorded; they never load inside the simulator. `mraid.open` and `mraid.playVideo` need a real user gesture; every message from the creative's container scripts carries a per-load secret, and a message the page forges is dropped and logged. A click-through opens only in the default web browser, never in an app that claims the link.
- **The transport is ephemeral.** It uses no cookies, no cache and no credentials, answers no authentication challenge (only server trust is evaluated), sends an explicit `Accept-Language`, and writes nothing to disk. The headers recorded for a request are the headers actually sent. Video and audio reach the network only through the monitor: progressive files through a resource loader, HLS through a loopback-only proxy (127.0.0.1, a random port and route per render) — the media player's own networking is never used. `data:` media is written to a private temporary folder and deleted when the render ends.
- **Only http(s), `data:` and `ccinn-sample:` URLs are loaded.** A VAST wrapper, image or media URL with any other scheme (`file:`, `javascript:`, `ftp:`, …) is recorded as failed and never opened, so pasted markup cannot read local files. Responses are size-capped (32 MiB for content, 1 MiB read for trackers) and every hop has a timeout.
- **Generated content is bounded.** A built-in sample image is at most 1920×1920; images are generated one at a time, at most 32 new ones a minute, in a 64 MiB cache. A VAST wrapper chain's merged trackers are shared, not copied per ad, and capped at 50,000.
- **Pasted data stays on the Mac.** Bid responses, bid requests and macro values are never uploaded anywhere. Only the requests in the table above are made.
- **Exports contain full URLs.** HAR files and `curl` commands include tracker hosts and any tokens or encrypted prices in their query strings. Review them before sharing.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnOpenRTB/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
