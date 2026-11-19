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
| A bid request you send from the Client tab (the URL, headers and body you typed) | Recorded as `offline`, not sent | Sent to the URL you entered, with the simulated device's User-Agent unless you set one | Sent to the URL you entered, with the simulated device's User-Agent unless you set one |
| Update check | Once a day unless turned off | Once a day unless turned off | Once a day unless turned off |

`data:` URLs and the built-in sample media (`ccinn-sample://`) are decoded or generated on the Mac and never reach the network. Nothing else leaves the Mac.

## Scope and design notes

- **Simulated mode never sends a tracker, and Offline loads nothing.** This is enforced in the structure of the code: every request — trackers, content, and the media player's byte ranges, HLS playlists and segments — goes through one dispatch policy, the HTTP transport can only be called with a send permit, and the policy issues none for a tracker in Simulated or Offline mode, nor for remote content when Offline. Leaving Real, rendering again, Reset and Lose cancel the trackers in flight at once and stop every Real-mode web view (companions included); leaving Real also stops a render still being prepared, so no later wrapper hop carries Real-mode values; an HLS playlist line that still names an origin after rewriting is dropped; a tracker's redirect chain stops before its next hop. Any way to make a tracker leave the Mac in Simulated or Offline mode, to make Offline load anything, or to make the creative reach the network while it is blocked, is a vulnerability.
- **Real mode can inflate real campaign numbers.** A tracker sent from CcinnOpenRTB carries the simulated device's User-Agent and counts like device traffic. That is why Real mode needs an explicit confirmation in every session, lists the hosts it will contact, and is shown in the toolbar and on every Network entry. Use it with your own test endpoints, or with the agreement of whoever owns the trackers.
- **Redirects are never followed automatically.** The transport sends one request per hop. The monitor records each hop and stops after 10 hops or at a loop. A bid request follows its own **Redirects** setting. By default (**within the origin**) a redirect to another origin — another host, scheme (http↔https) or port — is not followed and is shown as the response, so neither custom credentials (`X-Api-Key` …) nor the request's personal data go anywhere the user did not point. **Follow all** (chosen per request, or as the default for new requests in Settings ▸ Network) follows every hop like `curl -L`: `Authorization`, `Proxy-Authorization` and `Cookie` are not carried to another origin, but other headers and, on 307/308, the body are — choose it only for endpoints you trust; a downgrade to http is followed and flagged on the hop. **Follow to ‹host› and Send** follows all redirects for that one send only, names the host it goes to, and is offered only while the request is unchanged since the answer, so an edited request is never sent along a chain you did not see. On every hop, 307 and 308 repeat the method and body, and 303 (and 301 or 302 after a POST) continue as a GET without the body.
- **Creatives are isolated.** HTML creatives run in a web view with a non-persistent data store, so cookies and storage they set disappear with the session. Clicks and navigations are intercepted and recorded; they never load inside the simulator. `mraid.open` and `mraid.playVideo` need a real user gesture; every message from the creative's container scripts carries a per-load secret, and a message the page forges is dropped and logged. A click-through opens only in the default web browser, never in an app that claims the link.
- **The transport is ephemeral.** It uses no cookies, no cache and no credentials, answers no authentication challenge (only server trust is evaluated), sends an explicit `Accept-Language`, and writes nothing to disk. The headers recorded for a request are the headers actually sent. Video and audio reach the network only through the monitor: progressive files through a resource loader, HLS through a loopback-only proxy (127.0.0.1, a random port and route per render) — the media player's own networking is never used. `data:` media is written to a private temporary folder and deleted when the render ends.
- **Only http(s), `data:` and `ccinn-sample:` URLs are loaded.** A VAST wrapper, image or media URL with any other scheme (`file:`, `javascript:`, `ftp:`, …) is recorded as failed and never opened, so pasted markup cannot read local files. Responses are size-capped (32 MiB for content, 1 MiB read for trackers) and every hop has a timeout.
- **The pasted request's personal data stays on the Mac until Real mode is confirmed.** In Simulated and Offline mode nothing derived from it is sent: a VAST tag or wrapper URI fetched to render the ad gets `-1` for `[IFA]`, `[IFATYPE]`, `[DEVICEIP]`, `[LATLONG]`, `[GDPRCONSENT]`, `[GPPSTRING]` and `[GPPSECTIONID]`, and the simulated device's User-Agent for `[DEVICEUA]`. Real mode fills macros with the pasted request's values, device identifiers, location and consent strings included. In Simulated mode the publisher-context macros (`[LIMITADTRACKING]`, `[DOMAIN]`, `[PAGEURL]`, `[APPBUNDLE]`, `[TRANSACTIONID]`) are still filled from the pasted request in tag URLs: they describe the placement, not the user. Any way to make a request-derived identifier leave the Mac before Real mode is confirmed is a vulnerability.
- **Generated content is bounded.** A built-in sample image is at most 1920×1920; images are generated one at a time, at most 32 new ones a minute, in a 64 MiB cache. A VAST wrapper chain's merged trackers are shared, not copied per ad, and capped at 50,000.
- **Pasted data stays on the Mac.** Bid responses, bid requests and macro values are never uploaded anywhere, except the bid request you send yourself from the Client tab, to the URL you entered. Only the requests in the table above are made.
- **A bid request is sent only when you press Send, and never when Offline.** It goes through the same dispatch policy and appears in the Network window with its body. It is not a tracker, so it is sent in Simulated mode too; a response is shown on the device at once only outside Real mode — in Real mode the device waits for an explicit Render, which is what sends the bid's trackers. Header names and values are validated before sending (no CR, LF or NUL can split a header).
- **Saved requests are files only you can read.** Each saved request is a JSON file in `~/Library/Application Support/CcinnOpenRTB/Requests/` (the folder is `0700`, the files `0600`). It holds what you typed — headers, credentials included, and the request's device identifiers, IP address, location and consent strings — and the last response. Anyone with access to your account can read them; delete what you no longer need. Damaged or foreign files in the folder are skipped, never executed.
- **Exports of saved requests are as sensitive as the folder.** **Export All…** writes every saved request, credentials and personal data included, to one file created `0600`. **Import…** treats the file as untrusted: it is size-capped before it is read, another kind of document or a newer format is refused, damaged entries are skipped, nothing in it is executed, and it only adds or replaces saved requests (merged by id, a newer copy wins). Importing never sends anything.
- **Exports contain full URLs.** HAR files and `curl` commands include tracker hosts and any tokens or encrypted prices in their query strings, and for a bid request its headers and body (`postData`, `--data-raw`; never `--data-binary` or `-d`, which would read a body starting with `@` as a local file to upload). Review them before sharing.
- Update checks contact only `api.github.com` and `github.com`, send no personal data (the User-Agent is `CcinnOpenRTB/<version>`), and run at most once a day unless you check manually. A downloaded disk image is accepted only from this repository's download URL for the same release tag, at the size the release lists, and with the SHA-256 published in that release's `SHA256SUMS.txt`. The checksum guards against corruption and truncation, not against a compromised GitHub release; authenticity relies on HTTPS to github.com. The app never replaces itself; you drag the new version into Applications.
