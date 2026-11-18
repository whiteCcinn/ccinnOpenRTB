import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Input summary")
struct InputSummaryTests {
    private let warning = ValidationIssue(.warning, code: "w", message: "w", path: "/a")
    private let error = ValidationIssue(.error, code: "e", message: "e", path: "/b")

    @Test func statusLineNamesTheInputBidsAndIssues() {
        let bids = [Fixtures.candidate(.html("")), Fixtures.candidate(.html(""), id: "0.1")]
        let response = ParsedInput(kind: .bidResponse(.v2("2.6")), candidates: bids)
        #expect(InputSummary.status(of: response, issues: [warning], isParsing: false) == "OpenRTB 2.6 · 2 bids · 1 issue")
        #expect(InputSummary.status(of: response, issues: [warning, error], isParsing: false) == "OpenRTB 2.6 · 2 bids · 2 issues")
        let single = ParsedInput(kind: .bidResponse(.v3("3.0")), candidates: [bids[0]])
        #expect(InputSummary.status(of: single, issues: [], isParsing: false) == "OpenRTB 3.0 · 1 bid · no issues")
        let noBid = ParsedInput(kind: .bidResponse(.v2("2.x")), noBidReason: 2)
        #expect(InputSummary.status(of: noBid, issues: [], isParsing: false) == "OpenRTB 2.x · no bid (nbr 2) · no issues")
        #expect(InputSummary.status(of: ParsedInput(kind: .vastMarkup, candidates: [bids[0]]), issues: [], isParsing: false)
            == "VAST markup · 1 bid · no issues")
        #expect(InputSummary.status(of: ParsedInput(kind: .empty), issues: [], isParsing: false) == "Paste a bid response, Native, VAST or HTML")
        #expect(InputSummary.status(of: ParsedInput(kind: .invalid("Unexpected token")), issues: [error], isParsing: false)
            == "Not recognised: Unexpected token · 1 issue")
        #expect(InputSummary.status(of: response, issues: [], isParsing: true) == "Parsing…")
    }

    @Test func worstSeverityColoursTheStatus() {
        #expect(InputSummary.worstSeverity([warning, error]) == .error)
        #expect(InputSummary.worstSeverity([warning]) == .warning)
        #expect(InputSummary.worstSeverity([]) == nil)
    }

    @Test func bidTitlesCarryWhatTellsBidsApart() {
        var bid = Fixtures.candidate(.html(""))
        bid.dealID = "deal-7"
        #expect(InputSummary.title(of: bid) == "bid-0.0 · seat-a · 2.50 USD · Banner 320×50 · deal deal-7")
        let bare = AdCandidate(id: "1.0", bidID: "", price: 0.1234, currency: "EUR", format: .video, markup: .none)
        #expect(InputSummary.title(of: bare) == "bid 1.0 · 0.1234 EUR · Video")
    }
}

@Suite("Launch options")
struct LaunchOptionsTests {
    @Test func everyFlagIsRead() {
        let options = LaunchOptions(arguments: ["CcinnOpenRTB", "--sample", "vast-pod", "--device", "iphone-duo", "--placement", "rewarded",
                                                "--mode", "simulated", "--landscape", "--folded", "--spanned", "--visibility", "0.4",
                                                "--zoom", "0.5", "--snapshot", "/tmp/a.png", "--snapshot-delay", "2.5", "--quit-after-snapshot",
                                                "--open-network", "--no-render", "--export-har", "/tmp/a.har"])
        #expect(options.sampleID == "vast-pod")
        #expect(options.deviceID == "iphone-duo")
        #expect(options.placement == .rewarded)
        #expect(options.mode == .simulated)
        #expect(options.landscape && options.folded && options.spanned)
        #expect(options.visibility == 0.4)
        #expect(options.zoom == .scale(0.5))
        #expect(options.snapshotPath == "/tmp/a.png")
        #expect(options.snapshotDelay == 2.5)
        #expect(options.quitAfterSnapshot && options.opensNetworkWindow)
        #expect(!options.renders)
        #expect(options.harPath == "/tmp/a.har")
        #expect(options.isEmpty == false)
        #expect(LaunchOptions(arguments: ["app", "--export-har", "/tmp/b.har"]).isEmpty == false)
    }

    /// `--export-har <file>` writes the window's network log (HAR 1.2 with the `_ccinn` relationships) after the
    /// snapshot, for checks of the real app.
    @MainActor
    @Test func theNetworkLogIsExportedAsHAR() async throws {
        let monitor = NetworkMonitor(transport: CountingTransport(), publishInterval: .zero)
        let parent = monitor.dispatch(TrackerRequest(category: .win, trigger: "win", source: "bid 0.0", template: "https://w.example/",
                                                     url: "https://w.example/"), userAgent: "UA")
        monitor.recordNavigation(url: "https://l.example/", trigger: "click", source: "bid 0.0", parentID: parent)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-har-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: file) }
        await LaunchCoordinator.exportNetwork(of: monitor, to: file)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entries = try #require((document["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        let custom = entries.compactMap { $0["_ccinn"] as? [String: Any] }
        #expect(custom.count == 2 && custom[1]["parent"] as? String == custom[0]["id"] as? String)
    }

    @Test func placementsAreMatchedLooselyAndNonsenseIsIgnored() {
        #expect(LaunchOptions(arguments: ["app", "--placement", "in-feed"]).placement == .inFeed)
        #expect(LaunchOptions(arguments: ["app", "--placement", "CTV instream"]).placement == .ctvInstream)
        #expect(LaunchOptions(arguments: ["app", "--placement", "inlineBanner"]).placement == .inlineBanner)
        #expect(LaunchOptions(arguments: ["app", "--placement", "billboard"]).placement == nil)
        #expect(LaunchOptions(arguments: ["app", "--visibility", "nan"]).visibility == nil)
        #expect(LaunchOptions(arguments: ["app", "--visibility", "7"]).visibility == 1)
        #expect(LaunchOptions(arguments: ["app", "--zoom", "fit"]).zoom == .fit)
        #expect(LaunchOptions(arguments: ["app", "--zoom", "-1"]).zoom == nil)
        #expect(LaunchOptions(arguments: ["app", "--snapshot-delay", "-3"]).snapshotDelay == LaunchOptions.defaultSnapshotDelay)
        // A flag at the end without its value.
        #expect(LaunchOptions(arguments: ["app", "--device"]).deviceID == nil)
        #expect(LaunchOptions(arguments: ["app"]).isEmpty)
        #expect(LaunchOptions(arguments: ["app"]).renders)
    }

    /// `--mode real` may ask, but never switches by itself: the confirmation is the only way into Real mode.
    @MainActor
    @Test func realModeFromTheCommandLineOnlyAsks() async {
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.html("<p>"))]))
        let options = LaunchOptions(arguments: ["app", "--mode", "real", "--no-render"])
        #expect(options.mode == .real)
        await options.apply(to: harness.session, samples: [])
        #expect(harness.session.mode == .simulated)
        #expect(harness.session.realModeConfirmation != nil)
    }

    @MainActor
    @Test func applyingSetsUpTheSessionAndRendersTheSample() async throws {
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.html("<p>"))]))
        let sample = Sample(id: "banner", title: "Banner", group: "OpenRTB 2.x", response: "{\"id\":\"a\"}")
        let options = LaunchOptions(arguments: ["app", "--sample", "banner", "--device", "surface-duo", "--spanned", "--placement", "interstitial",
                                                "--visibility", "0.25"])
        await options.apply(to: harness.session, samples: [sample])
        await harness.waitUntilSettled()
        #expect(harness.session.device.id == "surface-duo")
        #expect(harness.session.spanned)
        #expect(harness.session.placement == .interstitial)
        #expect(harness.session.visibility == 0.25)
        #expect(harness.session.responseText == sample.response)
        #expect(harness.session.phase == .ready)
    }
}

/// `--snapshot` writes the window once it has finished drawing (first launch under load can leave text undrawn for a
/// moment): two identical consecutive frames, or the latest frame at the attempt limit (a playing video never settles).
@Suite("Snapshot settling")
struct SnapshotSettlerTests {
    /// Feeds `frames` and returns the verdict after each one.
    private static func verdicts(_ frames: [UInt8], maxAttempts: Int) -> [Bool] {
        var settler = SnapshotSettler(maxAttempts: maxAttempts)
        return frames.map { settler.isSettled(after: Data([$0])) }
    }

    @Test func twoIdenticalConsecutiveFramesSettle() {
        #expect(Self.verdicts([1, 2, 2], maxAttempts: 10) == [false, false, true])
        #expect(Self.verdicts([1, 2, 1, 1], maxAttempts: 10) == [false, false, false, true])
    }

    @Test func aFrameThatKeepsChangingIsTakenAtTheLimit() {
        #expect(Self.verdicts([1, 2, 3], maxAttempts: 3) == [false, false, true])
    }

    @Test func aLimitBelowOneStillTakesTheFirstFrame() {
        #expect(Self.verdicts([1], maxAttempts: 0) == [true])
    }
}

@Suite("JSON formatter")
struct JSONFormatterTests {
    @Test func reindentsWithoutTouchingTokens() {
        let input = #"{"id":"a","seatbid":[{"bid":[{"price":1.50,"adm":"<div class=\"x\">{[,]}</div>","ext":{}}]}],"e":[]}"#
        let expected = """
        {
          "id": "a",
          "seatbid": [
            {
              "bid": [
                {
                  "price": 1.50,
                  "adm": "<div class=\\"x\\">{[,]}</div>",
                  "ext": {}
                }
              ]
            }
          ],
          "e": []
        }
        """
        #expect(JSONFormatter.prettyPrinted(input) == expected)
        // Idempotent.
        #expect(JSONFormatter.prettyPrinted(expected) == expected)
    }

    @Test func refusesWhatIsNotJSON() {
        #expect(JSONFormatter.prettyPrinted("<VAST/>") == nil)
        #expect(JSONFormatter.prettyPrinted("{\"a\": [1, 2}") == nil)
        #expect(JSONFormatter.prettyPrinted("{\"a\": \"open") == nil)
        #expect(JSONFormatter.prettyPrinted("   ") == nil)
    }

    @Test func handlesAMegabyteQuickly() {
        let bid = #"{"id":"b","impid":"1","price":1.2,"adm":"\#(String(repeating: "x", count: 900))"}"#
        let text = #"{"id":"big","seatbid":[{"bid":["# + Array(repeating: bid, count: 1_100).joined(separator: ",") + "]}]}"
        #expect(text.utf8.count > 1_000_000)
        let start = Date()
        let formatted = JSONFormatter.prettyPrinted(text)
        #expect(formatted != nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    private func tokens(_ text: String, _ language: SyntaxHighlighter.Language) -> [String] {
        let ns = text as NSString
        return SyntaxHighlighter.spans(in: text, language: language).map { "\($0.kind):\(ns.substring(with: $0.range))" }
    }

    @Test func json() {
        #expect(tokens(#"{"price": 1.5e2, "ok": true, "adm": "<b>\"x\"</b>", "n": null}"#, .json) == [
            "key:\"price\"", "number:1.5e2", "key:\"ok\"", "keyword:true", "key:\"adm\"", "string:\"<b>\\\"x\\\"</b>\"", "key:\"n\"",
            "keyword:null",
        ])
    }

    @Test func xml() {
        #expect(tokens(#"<VAST version="4.2"><!-- c --><Ad><![CDATA[https://x]]></Ad></VAST>"#, .xml) == [
            "tag:<VAST", "attribute:version", "string:\"4.2\"", "tag:>", "comment:<!-- c -->", "tag:<Ad", "tag:>",
            "cdata:<![CDATA[https://x]]>", "tag:</Ad", "tag:>", "tag:</VAST", "tag:>",
        ])
    }

    @Test func languageIsDetectedFromTheText() {
        #expect(SyntaxHighlighter.Language.detect("  {\"a\":1}") == .json)
        #expect(SyntaxHighlighter.Language.detect("\n<?xml version=\"1.0\"?><VAST/>") == .xml)
        #expect(SyntaxHighlighter.Language.detect("<div>html</div>") == .xml)
        #expect(SyntaxHighlighter.Language.detect("https://ads.example/vast") == .plain)
        #expect(SyntaxHighlighter.spans(in: "anything", language: .plain).isEmpty)
    }

    @Test func unterminatedInputNeverTraps() {
        for text in ["\"open", "{\"a\": \"\\", "<a href=\"x", "<!-- open", "<![CDATA[ open", "<", "\\", "\u{1F600}\"é\""] {
            _ = SyntaxHighlighter.spans(in: text, language: .json)
            _ = SyntaxHighlighter.spans(in: text, language: .xml)
        }
    }
}

@Suite("Inspector tree")
struct InspectorTreeTests {
    private func allIDs(_ nodes: [InspectorNode]) -> [String] {
        nodes.flatMap { [$0.id] + allIDs($0.children ?? []) }
    }

    @Test func bidNativeAndResolvedVASTWithUniqueIDs() throws {
        var candidate = Fixtures.candidate(.native("{}"), format: .native)
        candidate.adcomEvents = [AdcomEvent(type: 1, method: 1, url: "https://a/1"), AdcomEvent(type: 3, method: 1, url: "https://a/3")]
        let native = NativeAd(version: "1.2", assets: [NativeAsset(id: 1, content: .title(text: "Hi")),
                                                       NativeAsset(id: 2, content: .image(url: "https://img/m.png", width: 1200, height: 627, type: .main))],
                              link: AdLink(url: "https://landing", clickTrackers: ["https://c/1"]),
                              impressionTrackers: ["https://i/1", "https://i/2"],
                              eventTrackers: [NativeEventTracker(event: 2, method: 1, url: "https://v/2")])
        var pod = Fixtures.vast(ads: 2)
        pod.chain = [VASTHop(url: nil), VASTHop(url: "https://wrapper.example/vast", error: .wrapperTimeout)]
        let nodes = InspectorTree.build(candidate: candidate, native: native, vastDocument: nil, resolved: pod)
        #expect(nodes.map(\.title) == ["Bid 0.0", "Auction notices and events", "Native 1.2", "VAST (resolved)"])
        let ids = allIDs(nodes)
        #expect(Set(ids).count == ids.count)
        let auction = try #require(nodes[1].children)
        #expect(auction.map(\.title).contains("AdCOM event 1 · loaded"))
        #expect(auction.map(\.title).contains("AdCOM event 3 · viewable MRC 50"))
        let nativeRows = try #require(nodes[2].children).map(\.title)
        #expect(nativeRows.contains("asset 2 · image (main)"))
        #expect(nativeRows.contains("eventtracker 2 · viewable MRC 50"))
        let vastRows = try #require(nodes[3].children)
        #expect(vastRows.map(\.title) == ["Wrapper chain", "Ad 1", "Ad 2"])
        #expect(vastRows[0].children?.last?.detail?.contains("error 301") == true)
    }

    @Test func markupSummaries() {
        #expect(InspectorTree.markupSummary(Fixtures.candidate(.vast(.url("https://t/v")))) == "VAST tag · https://t/v")
        #expect(InspectorTree.markupSummary(Fixtures.candidate(.none)) == "Delivered by the win notice (nurl)")
        #expect(InspectorTree.markupSummary(Fixtures.candidate(.none, markupURL: "https://c/m")) == "By reference (display.curl)")
    }
}
