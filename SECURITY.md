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

| Traffic | Simulated (default) | Real |
|---|---|---|
| Trackers: win, billing, loss, impression, viewability, VAST events, clicks, errors | Recorded, never sent | Sent after a per-session confirmation that lists the tracker hosts, with the simulated device's User-Agent |
| Script trackers: Native `jstracker`, `eventtrackers` with method 2 | Recorded, not injected | Injected into the creative |
| The HTML creative's own network | Blocked, with no way to lift the block in Simulated mode. Loads through elements, `fetch`, XHR, `sendBeacon`, WebSocket and WebRTC are recorded as `blocked`; loads from CSS, `EventSource`, `<a ping>` and workers are blocked without a record | Not blocked |
| Content needed to render: VAST wrapper and tag fetches, images, media, `dcourl` | Fetched | Fetched |
| Click-through navigation | Recorded, never opened | Recorded; opened in the default browser only when **Open click-throughs in browser in Real mode** is on (off by default). Never on CTV |
| Update check | Once a day unless turned off | Once a day unless turned off |

`data:` URLs and the built-in sample media (`ccinn-sample://`) are decoded or generated on the Mac and never reach the network. Nothing else leaves the Mac.

## Scope and design notes

- **Simulated mode never sends a tracker.** This is enforced in the structure of the code: the HTTP transport can only be called with a send permit, and the dispatch policy issues none for a tracker in Simulated mode. Switching back to Simulated stops a tracker's redirect chain before its next hop. Any way to make a tracker leave the Mac in Simulated mode, or to make the creative reach the network while it is blocked, is a vulnerability.
- **Real mode can inflate real campaign numbers.** A tracker sent from CcinnOpenRTB carries the simulated device's User-Agent and counts like device traffic. That is why Real mode needs an explicit confirmation in every session, lists the hosts it will contact, and is shown in the toolbar and on every Network entry. Use it with your own test endpoints, or with the agreement of whoever owns the trackers.
- **Redirects are never followed automatically.** The transport sends one request per hop. The monitor records each hop and stops after 10 hops or at a loop.
- **Creatives are isolated.** HTML creatives run in a web view with a non-persistent data store, so cookies and storage they set disappear with the session. Clicks and navigations are intercepted and recorded; they never load inside the simulator.
- **The transport is ephemeral.** It uses no cookies and no cache, and writes nothing to disk.
- **Only http(s), `data:` and `ccinn-sample:` URLs are loaded.** A VAST wrapper, image or media URL with any other scheme (`file:`, `javascript:`, `ftp:`, …) is recorded as failed and never opened, so pasted markup cannot read local files. Responses are size-capped (32 MiB for content, 1 MiB read for trackers) and every hop has a timeout.
- **Pasted data stays on the Mac.** Bid responses, bid requests and macro values are never uploaded anywhere. Only the requests in the table above are made.
- **Exports contain full URLs.** HAR files and `curl` commands include tracker hosts and any tokens or encrypted prices in their query strings. Review them before sharing.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnOpenRTB/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
