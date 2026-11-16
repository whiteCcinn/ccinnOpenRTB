# Contributing to CcinnOpenRTB

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- No third-party dependencies and no services to start: the unit tests never touch the network.

```bash
git clone https://github.com/whiteCcinn/ccinnopenrtb.git && cd ccinnopenrtb
swift build
swift test
scripts/build-app.sh --open
```

### Launch arguments

```bash
dist/CcinnOpenRTB.app/Contents/MacOS/CcinnOpenRTB --demo-network --no-update-check
```

- `--demo-network` fills the Network window with synthetic entries, so the window can be checked without rendering an ad.
- `--no-update-check` skips the automatic update check.

### Testing Real mode locally

Point the trackers at a server on your Mac, never at a live ad server. Python's built-in server is enough; it logs every request it receives:

```bash
python3 -m http.server 8080
```

Paste a response whose trackers use that server, for example:

```json
{"id": "local-1", "cur": "USD", "seatbid": [{"seat": "local", "bid": [{
  "id": "b1", "impid": "1", "price": 1.5, "w": 320, "h": 50,
  "nurl": "http://127.0.0.1:8080/win?price=${AUCTION_PRICE}",
  "burl": "http://127.0.0.1:8080/bill?price=${AUCTION_PRICE}",
  "adm": "<div style=\"width:320px;height:50px;background:#eee\">Local test</div>"
}]}]}
```

1. Render it in Simulated mode. The Network window shows `win` and `billing` as `simulated`, and the server log stays empty. That empty log is the check: **nothing is sent in Simulated mode**.
2. Switch to Real mode. The confirmation lists `127.0.0.1`. Confirm and render again.
3. The server logs a `GET /win?price=…` and a `GET /bill?price=…` line, with the bid price filled in. It answers 404 for these paths, which is fine: the Network window records the request, the status, the timing and the headers.

To test redirects, use a server that answers with a 3xx and a `Location` header; each hop appears as a child entry.

## Project layout

| Module | Responsibility |
|---|---|
| `RTBKit` | Foundation only, no I/O: OpenRTB 2.x/3.0 and AdCOM parsing, Native 1.0–1.2, VAST 2.0–4.2 parsing and wrapper resolution (fetches go through the `VASTFetcher` protocol), macros, the tracking plan, the device catalog, validation and samples |
| `CcinnOpenRTBKit` | Network monitor: the Simulated/Real dispatch policy, the `HTTPTransport` protocol and its URLSession implementation without automatic redirects, the recorder, HAR and curl export. Sample media generation and the update check. No UI |
| `CcinnOpenRTB` | SwiftUI/AppKit application: shell, simulator and device frames, renderers (HTML/MRAID, image, Native, VAST player), Network window, settings |

Tests live in `RTBKitTests`, `CcinnOpenRTBKitTests` and `CcinnOpenRTBAppTests` (WebKit and AVFoundation behaviour of the renderers).

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Write the failing test, then the code. Network code is tested with a fake `HTTPTransport` and a deterministic clock; macro expansion with a fixed `[TIMESTAMP]` and `[CACHEBUSTING]`. No test may reach the internet (the transport tests use a loopback server on 127.0.0.1).
- **Simulated mode must never send a tracker.** The transport can only be called with a send permit, and only the dispatch policy issues one. Keep it that way. Any change to dispatch, redirects or mode switching needs a test that uses a transport which fails when it is called.
- **Never crash on input.** Bid responses, VAST, Native JSON and HTML come from outside. No force unwraps or casts, unchecked indexing or trapping integer conversions on parsed data. Report a validation issue with a location instead of failing, and keep unknown fields.
- **Keep RTBKit pure.** Foundation only, no I/O, no global state. The tracking plan must stay deterministic: the same event and inputs give the same requests in the same order.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O, parsing large documents or media generation.
- **Cite the spec.** When code encodes a fact from a specification or a device data sheet (an error code, a macro, a screen size), name the source in a comment.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test` pass.
3. Describe what changed and how you tested it: the OpenRTB, Native or VAST versions, the samples or responses, the devices and the tracking mode.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
