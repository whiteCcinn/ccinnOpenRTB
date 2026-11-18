import CcinnOpenRTBKit
import Foundation
import os
import RTBKit
import Testing
@testable import CcinnOpenRTB

@MainActor
@Suite("Ad session lifecycle")
struct AdSessionTests {
    private let display = Fixtures.candidate(.html("<div>ad</div>"))
    private let video = Fixtures.candidate(.vast(.xml("<VAST version=\"4.2\"/>")), format: .video)

    // MARK: Parsing and selection

    @Test func everySessionStartsSimulatedEvenWithARealMonitor() {
        let monitor = NetworkMonitor(transport: CountingTransport(), publishInterval: .zero)
        monitor.mode = .real
        let session = AdSession(services: Fixtures.services(Fixtures.input([]), recorder: KitRecorder()), monitor: monitor)
        #expect(session.mode == .simulated)
    }

    @Test func parsingSelectsTheFirstBidAndSuggestsAPlacement() async {
        let harness = SessionHarness(Fixtures.input([video, display]))
        await harness.paste()
        #expect(harness.session.selectedCandidateID == "0.0")
        #expect(harness.session.placement == .interstitial)
        harness.session.selectedCandidateID = video.id
        #expect(harness.session.isParsing == false)
    }

    @Test func typingIsDebouncedAndOnlyTheLatestTextIsApplied() async throws {
        let recorder = KitRecorder()
        let session = AdSession(services: Fixtures.services(Fixtures.input([display]), recorder: recorder),
                                monitor: NetworkMonitor(transport: CountingTransport(), publishInterval: .zero), parseDebounce: .milliseconds(30))
        for character in "typing" { session.responseText.append(character) }
        #expect(session.isParsing)
        for _ in 0..<500 where session.isParsing { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!session.isParsing)
        #expect(recorder.parses == 1)
        #expect(session.selectedCandidateID == "0.0")
    }

    /// The editor (or anything else) touching the text while a sample parses must not leave the sample unparsed: `load`
    /// renders what it loaded.
    @Test func loadingASampleSurvivesAnEditDuringItsParse() async {
        let recorder = KitRecorder()
        var services = Fixtures.services(Fixtures.input([display]), recorder: recorder)
        let parse = services.parseInput
        services.parseInput = { text, request in
            Thread.sleep(forTimeInterval: 0.03)
            return parse(text, request)
        }
        let session = AdSession(services: services, monitor: NetworkMonitor(transport: CountingTransport(), publishInterval: .zero),
                                clock: ManualSessionClock(), browser: RecordingBrowser(), opensClickThroughs: { false }, parseDebounce: .zero)
        let sample = Sample(id: "s", title: "S", group: "G", response: "{\"id\":\"a\"}")
        let echo = Task { @MainActor in
            await Task.yield()
            session.responseText = session.responseText
        }
        await session.load(sample)
        await echo.value
        for _ in 0..<500 where session.phase != .ready { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(session.selectedCandidateID == display.id)
        #expect(session.phase == .ready)
    }

    @Test func noBidResponseRendersTheReason() async {
        let harness = SessionHarness(ParsedInput(kind: .bidResponse(.v2("2.x")), responseID: "a", noBidReason: 2))
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .noBid(reason: 2))
        #expect(harness.recorder.events.isEmpty)
    }

    // MARK: Lifecycle

    @Test func renderSendsTheWinNoticeAndTheRendererReportsTheImpressionOnce() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .ready)
        #expect(harness.recorder.events == [.won])
        #expect(harness.session.renderRequest?.generation == harness.session.generation)

        harness.session.report(.rendered)
        harness.session.report(.rendered)
        harness.session.fireManually(.rendered)
        #expect(harness.recorder.events == [.won, .rendered])
        #expect(harness.categories == [.win, .billing, .impression])
        #expect(harness.session.lifecycleLog.filter { $0.outcome == .alreadyFired }.count == 2)
    }

    @Test func simulatedModeRecordsTrackersAndSendsNothing() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.report(.rendered)
        harness.session.fireManually(.click(assetID: nil))
        await harness.monitor.waitUntilIdle()
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.monitor.liveEntries.allSatisfy { $0.state == .simulated })
    }

    @Test func turningTheExchangeWinNoticeOffSkipsIt() async {
        let harness = SessionHarness(Fixtures.input([display]))
        harness.session.macros.exchangeSendsWinNotice = false
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.recorder.events.isEmpty)
        #expect(harness.categories.isEmpty)
    }

    @Test func vastIsResolvedOnceAndTheShellNeverSynthesisesRendered() async {
        let harness = SessionHarness(Fixtures.input([video]))
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .ready)
        #expect(harness.recorder.resolutions == [.xml("<VAST version=\"4.2\"/>")])
        #expect(harness.recorder.resolutionRequestCalls == 1)
        #expect(harness.recorder.events == [.won])
        #expect(harness.session.renderRequest?.vast == Fixtures.vast(ads: 1))
        #expect(harness.session.issues.map(\.code) == ["vast.test"])
        #expect(harness.categories == [.win, .error])
    }

    @Test func aVASTChainFailureFiresItsErrorOnce() async {
        let harness = SessionHarness(Fixtures.input([video]), resolved: Fixtures.vast(ads: 0, failure: .noAdsAfterWrapper))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.fireManually(.error(.noAdsAfterWrapper, adIndex: nil))
        #expect(harness.recorder.events == [.won, .error(.noAdsAfterWrapper, adIndex: nil)])
    }

    @Test func aNewRenderLetsEveryEventFireAgain() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.report(.rendered)
        let first = harness.session.generation
        await harness.renderAndWait()
        #expect(harness.session.generation == first + 1)
        harness.session.report(.rendered)
        #expect(harness.recorder.events == [.won, .rendered, .won, .rendered])
    }

    @Test func resetIgnoresEventsUntilTheNextRender() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.reset()
        #expect(harness.session.phase == .idle)
        #expect(harness.session.renderRequest == nil)
        harness.session.report(.rendered)
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.recorder.events == [.won])
        #expect(harness.session.lifecycleLog.last?.outcome == .ignored("no ad on the device"))
    }

    @Test func aResolutionThatFinishesAfterResetIsDiscarded() async throws {
        let gate = ResolutionGate()
        let harness = SessionHarness(Fixtures.input([video]), gate: gate)
        await harness.paste()
        harness.session.render()
        for _ in 0..<500 where !gate.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        #expect(harness.session.phase == .preparing("Resolving VAST…"))
        harness.session.reset()
        gate.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.session.phase == .idle)
        #expect(harness.session.prepared == nil)
        #expect(harness.recorder.resolutionRequestCalls == 0)
        #expect(harness.recorder.events == [.won])
    }

    @Test func loseSendsTheLossNoticeInsteadOfRendering() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.lose(LossReason.reason(code: 100))
        #expect(harness.session.phase == .lost(LossReason.reason(code: 100)))
        #expect(harness.session.renderRequest == nil)
        harness.session.report(.rendered)
        #expect(harness.recorder.events == [.won, .loss(reason: 100)])
        #expect(harness.recorder.contexts.last?.lossReason == 100)
        #expect(harness.categories == [.win, .loss])
    }

    @Test func lifecycleGateKeepsWinAndLossApart() {
        var gate = LifecycleGate()
        #expect(gate.admit(.won) == .admitted)
        #expect(gate.admit(.loss(reason: 102)) == .contradictsOutcome)
        var lost = LifecycleGate()
        #expect(lost.admit(.loss(reason: 102)) == .admitted)
        #expect(lost.admit(.loss(reason: 102)) == .alreadyFired)
        #expect(lost.admit(.rendered) == .contradictsOutcome)
    }

    @Test func lifecycleGateRepeatsClicksAndInteractionsButNotMilestones() {
        var gate = LifecycleGate()
        #expect(gate.admit(.click(assetID: nil)) == .admitted)
        #expect(gate.admit(.click(assetID: nil)) == .admitted)
        #expect(gate.admit(.video(.mute, adIndex: 0)) == .admitted)
        #expect(gate.admit(.video(.mute, adIndex: 0)) == .admitted)
        #expect(gate.admit(.video(.firstQuartile, adIndex: 0)) == .admitted)
        #expect(gate.admit(.video(.firstQuartile, adIndex: 0)) == .alreadyFired)
        #expect(gate.admit(.video(.firstQuartile, adIndex: 1)) == .admitted)
        #expect(gate.admit(.video(.progress(.seconds(5)), adIndex: 0)) == .admitted)
        #expect(gate.admit(.video(.progress(.seconds(5)), adIndex: 0)) == .alreadyFired)
        #expect(gate.admit(.video(.progress(.seconds(10)), adIndex: 0)) == .admitted)
        #expect(gate.admit(.videoViewability(.viewable, adIndex: 0)) == .admitted)
        #expect(gate.admit(.videoViewability(.notViewable, adIndex: 0)) == .alreadyFired)
        #expect(gate.admit(.error(.vpaidError, adIndex: 0)) == .admitted)
        #expect(gate.admit(.error(.vpaidError, adIndex: 0)) == .alreadyFired)
        #expect(gate.admit(.error(.noSupportedMedia, adIndex: 0)) == .admitted)
    }

    // MARK: Markup by reference

    @Test func winNoticeMarkupIsNotFetchedInSimulatedMode() async {
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.none, format: .video)]))
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .needsRealMode("The markup is delivered by the win notice — switch to Real to fetch it."))
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.monitor.liveEntries.map(\.category) == [.win])
        #expect(harness.monitor.liveEntries.first?.state == .simulated)
        #expect(harness.monitor.liveEntries.first?.url == "https://win.dsp.example/w?p=2.5")
        #expect(harness.recorder.events.isEmpty)
    }

    @Test func winNoticeMarkupInRealModeIsTheWinNoticeAndIsNotSentTwice() async {
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.none, format: .video)]))
        harness.transport.respond("https://win.dsp.example/w?p=2.5", body: "  <VAST version=\"3.0\"><Ad/></VAST>")
        await harness.paste()
        harness.enterRealMode()
        await harness.renderAndWait()
        #expect(harness.session.phase == .ready)
        #expect(harness.transport.requests.filter { $0.url.host == "win.dsp.example" }.count == 1)
        #expect(harness.recorder.resolutions == [.xml("<VAST version=\"3.0\"><Ad/></VAST>")])
        #expect(harness.recorder.events.isEmpty)
        harness.session.report(.won)
        #expect(harness.recorder.events.isEmpty)
        #expect(harness.session.prepared?.markupFromWinNotice == true)
        let winEntry = harness.monitor.liveEntries.first { $0.category == .win }
        #expect(harness.monitor.liveEntries.first { $0.category == .content }?.parentID == nil)
        #expect(winEntry != nil)
    }

    @Test func displayCurlMarkupIsContentAndFetchedInBothModes() async {
        let candidate = Fixtures.candidate(.none, markupURL: "https://cdn.example/creative.html")
        let harness = SessionHarness(Fixtures.input([candidate]))
        harness.transport.respond("https://cdn.example/creative.html", body: "<div>curl</div>")
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .ready)
        #expect(harness.session.prepared?.candidate.markup == .html("<div>curl</div>"))
        #expect(harness.transport.requests.map(\.url.absoluteString) == ["https://cdn.example/creative.html"])
        #expect(harness.categories == [.win, .content])
        #expect(harness.recorder.events == [.won])
    }

    // MARK: Network relationships

    /// The request that delivered the markup (AdCOM `display.curl`, or the nurl win notice) is the parent of the bid's
    /// trackers and navigations: the session passes its monitor entry to the tracking plan as `markupRequestID`, nil
    /// for inline adm.
    @Test func theMarkupRequestIsPassedToTheTrackingPlan() async throws {
        let inline = SessionHarness(Fixtures.input([display]))
        await inline.paste()
        await inline.renderAndWait()
        inline.session.report(.rendered)
        #expect(inline.recorder.options.map(\.markupRequestID) == [nil, nil])

        let curl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, markupURL: "https://cdn.example/creative.html")]))
        curl.transport.respond("https://cdn.example/creative.html", body: "<div>curl</div>")
        await curl.paste()
        await curl.renderAndWait()
        curl.session.report(.rendered)
        curl.session.fireManually(.click(assetID: nil))
        let content = try #require(curl.monitor.liveEntries.first { $0.category == .content })
        #expect(curl.recorder.events == [.won, .rendered, .click(assetID: nil)])
        // `.won` fires before the markup is fetched: the nurl is in the bid, not in the markup.
        #expect(curl.recorder.options.map(\.markupRequestID) == [nil, content.id, content.id])

        let nurl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, format: .banner)]))
        nurl.transport.respond("https://win.dsp.example/w?p=2.5", body: "<div>from the win notice</div>")
        await nurl.paste()
        nurl.enterRealMode()
        await nurl.renderAndWait()
        nurl.session.report(.rendered)
        let win = try #require(nurl.monitor.liveEntries.first { $0.category == .win })
        #expect(nurl.recorder.options.last == TrackingPlanOptions(exchangeSendsWinNotice: false, markupRequestID: win.id))
    }

    /// A navigation the creative alone knows (`mraid.open`, `window.open`) belongs to the markup's document: its parent
    /// is the request that delivered the markup, never the click tracker.
    @Test func aCreativesOwnNavigationHangsUnderTheMarkupRequest() async throws {
        let curl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, markupURL: "https://cdn.example/creative.html")]))
        curl.transport.respond("https://cdn.example/creative.html", body: "<div>curl</div>")
        await curl.paste()
        await curl.renderAndWait()
        curl.session.fireManually(.click(assetID: nil))
        curl.session.rendererHost.navigate(to: "https://landing.example/mraid", trigger: "mraid.open", source: "creative")
        let content = try #require(curl.monitor.liveEntries.first { $0.category == .content })
        let navigation = try #require(curl.monitor.liveEntries.last { $0.category == .navigation })
        #expect(navigation.url == "https://landing.example/mraid")
        #expect(navigation.parentID == content.id)

        let inline = SessionHarness(Fixtures.input([display]))
        await inline.paste()
        await inline.renderAndWait()
        inline.session.fireManually(.click(assetID: nil))
        inline.session.rendererHost.navigate(to: "https://landing.example/mraid", trigger: "mraid.open", source: "creative")
        #expect(inline.monitor.liveEntries.filter { $0.category == .navigation }.allSatisfy { $0.parentID == nil })
    }

    /// The renderers learn which request delivered the markup, so the creative's own requests hang under it.
    @Test func theRenderRequestNamesTheMarkupRequest() async throws {
        let curl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, markupURL: "https://cdn.example/creative.html")]))
        curl.transport.respond("https://cdn.example/creative.html", body: "<div>curl</div>")
        await curl.paste()
        await curl.renderAndWait()
        let content = try #require(curl.monitor.liveEntries.first { $0.category == .content })
        #expect(curl.session.renderRequest?.markupRequestID == content.id)

        let inline = SessionHarness(Fixtures.input([display]))
        await inline.paste()
        await inline.renderAndWait()
        #expect(inline.session.renderRequest != nil)
        #expect(inline.session.renderRequest?.markupRequestID == nil)
    }

    /// The exchange substitutes OpenRTB macros in `adm` before the device sees it (OpenRTB 2.6 §4.4), so the HTML creative
    /// renders with them substituted; markup fetched by reference (`display.curl`) is the device's own fetch, as delivered.
    @Test func inlineHTMLAdmRendersWithTheExchangesMacrosSubstituted() async {
        let adm = "<img src='https://p.example/?price=${AUCTION_PRICE}'>"
        let inline = SessionHarness(Fixtures.input([Fixtures.candidate(.html(adm))]))
        await inline.paste()
        await inline.renderAndWait()
        #expect(inline.session.renderRequest?.candidate.markup == .html("<img src='https://p.example/?price=2.5'>"))
        #expect(!inline.session.renderIsStale, "substituting macros is not an edit of the response")

        let curl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, markupURL: "https://cdn.example/creative.html")]))
        curl.transport.respond("https://cdn.example/creative.html", body: adm)
        await curl.paste()
        await curl.renderAndWait()
        #expect(curl.session.renderRequest?.candidate.markup == .html(adm))
    }

    /// OpenRTB 2.6 §4.4: the exchange substitutes its `${…}` auction macros in the bid's inline markup, whatever its kind,
    /// before the device sees it — so the Native parser and the VAST resolver read the substituted markup. VAST `[…]`
    /// macros are the player's, filled when a tracker fires (the fake kit only knows `${AUCTION_PRICE}`).
    @Test func inlineNativeAndVASTAdmAreSubstitutedBeforeTheyAreParsed() async {
        let nativeJSON = #"{"native":{"imptrackers":["https://i.example/?p=${AUCTION_PRICE}"]}}"#
        let parsed = OSAllocatedUnfairLock<[String]>(initialState: [])
        let native = SessionHarness(Fixtures.input([Fixtures.candidate(.native(nativeJSON), format: .native)])) { services in
            services.parseNative = { json, _ in
                parsed.withLock { $0.append(json) }
                return (Fixtures.native, [])
            }
        }
        await native.paste()
        await native.renderAndWait()
        let substitutedJSON = #"{"native":{"imptrackers":["https://i.example/?p=2.5"]}}"#
        #expect(parsed.withLock { $0 }.contains(substitutedJSON), "\(parsed.withLock { $0 })")
        #expect(native.session.renderRequest?.candidate.markup == .native(substitutedJSON))
        #expect(native.session.prepared?.candidate.markup == .native(nativeJSON), "the bid keeps its own markup")
        #expect(!native.session.renderIsStale)

        let vastXML = "<VAST><Ad><InLine><Impression>https://i.example/?p=${AUCTION_PRICE}&amp;cb=[CACHEBUSTING]</Impression></InLine></Ad></VAST>"
        let substitutedXML = "<VAST><Ad><InLine><Impression>https://i.example/?p=2.5&amp;cb=[CACHEBUSTING]</Impression></InLine></Ad></VAST>"
        let vast = SessionHarness(Fixtures.input([Fixtures.candidate(.vast(.xml(vastXML)), format: .video)]))
        await vast.paste()
        await vast.renderAndWait()
        #expect(vast.recorder.resolutions == [.xml(substitutedXML)], "resolved from the substituted XML; [CACHEBUSTING] waits for the player")
        #expect(vast.session.renderRequest?.candidate.markup == .vast(.xml(substitutedXML)))
    }

    /// Markup the DSP returns after the win (the nurl response, AdCOM `display.curl`) is the device's own fetch: the
    /// exchange never sees it, so it is used as delivered, whatever its kind.
    @Test func markupFetchedAfterTheWinIsNotSubstituted() async {
        let vastXML = "<VAST><Ad><InLine><Impression>https://i.example/?p=${AUCTION_PRICE}</Impression></InLine></Ad></VAST>"
        let curl = SessionHarness(Fixtures.input([Fixtures.candidate(.none, format: .video, markupURL: "https://cdn.example/vast.xml")]))
        curl.transport.respond("https://cdn.example/vast.xml", body: vastXML)
        await curl.paste()
        await curl.renderAndWait()
        #expect(curl.recorder.resolutions == [.xml(vastXML)])
    }

    @Test func theShellsPlanOptionsBecomeTheKitsInOnePlace() {
        let markupRequestID = UUID()
        let options = TrackingPlanOptions(exchangeSendsWinNotice: false, markupRequestID: markupRequestID)
        #expect(options.kitOptions == TrackingPlan.Options(exchangeSendsWinNotice: false, markupRequestID: markupRequestID))
        #expect(TrackingPlanOptions(exchangeSendsWinNotice: true, markupRequestID: nil).kitOptions
            == TrackingPlan.Options(exchangeSendsWinNotice: true, markupRequestID: nil))
    }

    @Test func fetchedMarkupIsSniffed() {
        #expect(AdSession.markup(fromFetched: " <?xml version=\"1.0\"?><VAST/>", format: .banner) == .vast(.xml("<?xml version=\"1.0\"?><VAST/>")))
        #expect(AdSession.markup(fromFetched: "{\"native\":{}}", format: .banner) == .native("{\"native\":{}}"))
        #expect(AdSession.markup(fromFetched: "{\"ver\":\"1.2\"}", format: .native) == .native("{\"ver\":\"1.2\"}"))
        #expect(AdSession.markup(fromFetched: "https://ads.example/vast.xml\n", format: .video) == .vast(.url("https://ads.example/vast.xml")))
        #expect(AdSession.markup(fromFetched: "https://ads.example/vast.xml", format: .banner) == .html("https://ads.example/vast.xml"))
        #expect(AdSession.markup(fromFetched: "<div>x</div>", format: .banner) == .html("<div>x</div>"))
    }

    // MARK: Real mode

    @Test func realModeIsOnlyEnteredThroughTheConfirmation() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        harness.session.requestRealMode()
        #expect(harness.session.mode == .simulated)
        let first = try #require(harness.session.realModeConfirmation)
        #expect(first.summary.hosts.map(\.name) == ["bill.dsp.example", "loss.dsp.example", "win.dsp.example"])
        #expect(first.bidLabel == "bid bid-0.0 · seat seat-a")

        harness.session.cancelRealMode()
        #expect(harness.session.realModeConfirmation == nil)
        #expect(harness.session.mode == .simulated)

        // A confirmation that is no longer shown does nothing.
        harness.session.confirmRealMode(first)
        #expect(harness.session.mode == .simulated)

        harness.session.requestRealMode()
        let second = try #require(harness.session.realModeConfirmation)
        #expect(second.id != first.id)
        harness.session.confirmRealMode(second)
        #expect(harness.session.mode == .real)
        #expect(harness.session.realModeConfirmation == nil)

        // Switching back ends it: the next switch asks again.
        harness.session.useSimulatedMode()
        #expect(harness.session.mode == .simulated)
        harness.session.requestRealMode()
        #expect(harness.session.mode == .simulated)
        #expect(harness.session.realModeConfirmation != nil)
    }

    /// The confirmation must not under-report: asked for right after a paste, it completes its host list when the bid's
    /// markup has been inspected (and stays the same confirmation).
    @Test func theConfirmationCompletesItsHostListWhenTheInspectionFinishes() async throws {
        let harness = SessionHarness(Fixtures.input([video]))
        await harness.paste()
        harness.session.requestRealMode()
        let shown = try #require(harness.session.realModeConfirmation)
        for _ in 0..<500 where harness.session.inspectedVAST == nil { try await Task.sleep(for: .milliseconds(1)) }
        let completed = try #require(harness.session.realModeConfirmation)
        #expect(completed.id == shown.id)
        #expect(completed.summary.hosts.map(\.name).contains("imp.vast.example"))
        harness.session.confirmRealMode(shown)
        #expect(harness.session.mode == .real)
    }

    @Test func realModeSendsTrackersWithTheDeviceUserAgent() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        let tablet = try #require(DeviceCatalog.device(id: "ipad-10"))
        harness.session.device = tablet
        await harness.paste()
        harness.enterRealMode()
        await harness.renderAndWait()
        harness.session.report(.rendered)
        await harness.monitor.waitUntilIdle()
        #expect(harness.transport.requests.map(\.url.host) == ["win.dsp.example", "bill.dsp.example", "imp.example"])
        #expect(harness.transport.requests.allSatisfy { $0.headers["User-Agent"] == tablet.userAgent })
    }

    // MARK: Click-throughs

    @Test func clickThroughsAreRecordedAndOpenedOnlyInRealModeWithTheSetting() async throws {
        let simulated = SessionHarness(Fixtures.input([display]), opensClickThroughs: true)
        await simulated.paste()
        await simulated.renderAndWait()
        simulated.session.fireManually(.click(assetID: nil))
        let navigation = try #require(simulated.monitor.liveEntries.first { $0.category == .navigation })
        let click = try #require(simulated.monitor.liveEntries.first { $0.category == .click })
        // A tracker never parents a navigation (decisions.md, "Network relationships"): inline adm, so no parent; the
        // click and its navigation are siblings of one action.
        #expect(navigation.parentID == nil && click.parentID == nil)
        #expect(navigation.trigger == click.trigger)
        #expect(navigation.delivery == .simulated)
        #expect(simulated.browser.opened.isEmpty)

        let real = SessionHarness(Fixtures.input([display]), opensClickThroughs: true)
        await real.paste()
        real.enterRealMode()
        await real.renderAndWait()
        real.session.fireManually(.click(assetID: nil))
        #expect(real.browser.opened == [URL(string: "https://landing.example/")])
        #expect(real.monitor.liveEntries.first { $0.category == .navigation }?.delivery == .browser)

        let settingOff = SessionHarness(Fixtures.input([display]), opensClickThroughs: false)
        await settingOff.paste()
        settingOff.enterRealMode()
        await settingOff.renderAndWait()
        settingOff.session.navigate(to: "https://landing.example/mraid", trigger: "mraid.open", source: "creative")
        #expect(settingOff.browser.opened.isEmpty)
        #expect(settingOff.monitor.liveEntries.last?.category == .navigation)
    }

    @Test func connectedTVNeverOpensClickThroughs() async throws {
        let harness = SessionHarness(Fixtures.input([video]), opensClickThroughs: true)
        harness.session.device = try #require(DeviceCatalog.device(id: "apple-tv-4k"))
        #expect(harness.session.placement == .ctvInstream)
        await harness.paste()
        harness.enterRealMode()
        await harness.renderAndWait()
        harness.session.fireManually(.videoClick(adIndex: 0))
        #expect(harness.browser.opened.isEmpty)
    }

    // MARK: Viewability

    @Test func displayViewabilityFiresAfterOneSecondInView() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        harness.clock.set(10)
        harness.session.report(.rendered)
        harness.clock.set(10.5)
        harness.session.settleViewability()
        #expect(harness.recorder.events == [.won, .rendered])
        harness.clock.set(11)
        harness.session.settleViewability()
        #expect(harness.recorder.events == [.won, .rendered, .viewable(.mrc50), .viewable(.mrc100)])
        harness.clock.set(30)
        harness.session.settleViewability()
        #expect(harness.recorder.events.count == 4)
    }

    @Test func theSliderBelowHalfHoldsViewabilityBack() async {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        harness.session.setVisibleFraction(0.4)
        await harness.renderAndWait()
        harness.session.report(.rendered)
        harness.clock.set(5)
        harness.session.settleViewability()
        #expect(!harness.recorder.events.contains(.viewable(.mrc50)))
        harness.session.setVisibleFraction(0.6)
        harness.clock.set(6)
        harness.session.settleViewability()
        #expect(harness.recorder.events.suffix(1) == [.viewable(.mrc50)])
    }

    @Test func eachPodAdGetsItsOwnVideoViewabilityOutcome() async {
        let harness = SessionHarness(Fixtures.input([video]), resolved: Fixtures.vast(ads: 2))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.report(.video(.creativeView, adIndex: 0))
        harness.session.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 0, duration: 15, isPlaying: true, isMuted: true))
        harness.clock.set(1.9)
        harness.session.settleViewability()
        #expect(!harness.recorder.events.contains(.videoViewability(.viewable, adIndex: 0)))
        harness.clock.set(2)
        harness.session.settleViewability()
        #expect(harness.recorder.events.contains(.videoViewability(.viewable, adIndex: 0)))
        harness.session.report(.video(.complete, adIndex: 0))

        // Ad 2 is skipped after one second of playback: not viewable, decided at the skip.
        harness.clock.set(3)
        harness.session.report(.video(.creativeView, adIndex: 1))
        harness.session.playbackChanged(PlaybackStatus(adIndex: 1, playhead: 0, duration: 15, isPlaying: true, isMuted: true))
        harness.clock.set(4)
        harness.session.report(.video(.skip, adIndex: 1))
        harness.clock.set(10)
        harness.session.settleViewability()
        #expect(harness.recorder.events == [
            .won, .video(.creativeView, adIndex: 0), .videoViewability(.viewable, adIndex: 0), .video(.complete, adIndex: 0),
            .video(.creativeView, adIndex: 1), .video(.skip, adIndex: 1), .videoViewability(.notViewable, adIndex: 1),
        ])
        #expect(!harness.recorder.events.contains(.rendered))
    }

    @Test func pausedOrHiddenVideoIsNotViewable() async {
        let harness = SessionHarness(Fixtures.input([video]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.setVisibleFraction(0.3)
        harness.session.report(.video(.creativeView, adIndex: 0))
        harness.session.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 0, duration: 15, isPlaying: true, isMuted: false))
        harness.clock.set(5)
        harness.session.settleViewability()
        harness.session.report(.video(.complete, adIndex: 0))
        #expect(harness.recorder.events.suffix(2) == [.video(.complete, adIndex: 0), .videoViewability(.notViewable, adIndex: 0)])
    }

    @Test func nativeVideoAssetReachesVideo50() async {
        let native = Fixtures.candidate(.native("{\"native\":{}}"), format: .native)
        let harness = SessionHarness(Fixtures.input([native]))
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.placement == .inFeed)
        harness.session.setVisibleFraction(1)
        harness.session.report(.rendered)
        harness.session.report(.video(.creativeView, adIndex: 0))
        harness.session.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 0, duration: 15, isPlaying: true, isMuted: true))
        harness.clock.set(2)
        harness.session.settleViewability()
        #expect(harness.recorder.events.filter {
            if case .viewable = $0 { true } else { false }
        } == [.viewable(.mrc50), .viewable(.mrc100), .viewable(.video50)])
        #expect(!harness.recorder.events.contains { if case .videoViewability = $0 { true } else { false } })
    }

    @Test func nativeVideoVASTIsResolvedThroughTheHostOnceAndRemembered() async {
        let native = Fixtures.candidate(.native("{\"native\":{}}"), format: .native)
        let harness = SessionHarness(Fixtures.input([native]), resolved: Fixtures.vast(ads: 1))
        await harness.paste()
        await harness.renderAndWait()
        // Through the protocol, as a renderer calls it: the session's implementation must be the one dispatched.
        let host: any AdRenderingHost = harness.session.rendererHost
        let first = Task { @MainActor in await host.resolveVAST(.url("https://vast.example/tag")) }
        let second = Task { @MainActor in await host.resolveVAST(.url("https://vast.example/tag")) }
        let (resolved, again) = await (first.value, second.value)
        #expect(resolved == Fixtures.vast(ads: 1) && again == resolved)
        #expect(harness.recorder.resolutions == [.url("https://vast.example/tag")])
        #expect(harness.session.nativeVideoVAST == resolved)
        #expect(harness.recorder.resolutionRequestCalls == 1)
        #expect(harness.session.issues.map(\.code) == ["vast.test"])

        // Its `.video` events map to that VAST.
        harness.session.report(.video(.start, adIndex: 0))
        #expect(harness.recorder.events.last == .video(.start, adIndex: 0))
    }

    @Test func aFailedNativeVideoChainFiresItsErrorOnceAfterResolution() async {
        let native = Fixtures.candidate(.native("{\"native\":{}}"), format: .native)
        let harness = SessionHarness(Fixtures.input([native]), resolved: Fixtures.vast(ads: 0, failure: .wrapperLimit))
        await harness.paste()
        await harness.renderAndWait()
        _ = await harness.session.resolveVAST(.url("https://vast.example/tag"))
        _ = await harness.session.resolveVAST(.url("https://vast.example/tag"))
        #expect(harness.recorder.events == [.won, .error(.wrapperLimit, adIndex: nil)])
        #expect(harness.recorder.resolutionRequestCalls == 1)
    }

    @Test func aNativeVideoResolutionFromAnEarlierRenderIsDiscarded() async throws {
        let gate = ResolutionGate()
        let native = Fixtures.candidate(.native("{\"native\":{}}"), format: .native)
        let harness = SessionHarness(Fixtures.input([native]), gate: gate)
        await harness.paste()
        gate.open()
        await harness.renderAndWait()
        let staleHost = harness.session.rendererHost
        await harness.renderAndWait()
        let resolved = await staleHost.resolveVAST(.url("https://vast.example/tag"))
        #expect(resolved == ResolvedVAST())
        #expect(harness.session.nativeVideoVAST == nil)
        #expect(harness.recorder.resolutionRequestCalls == 0)
    }

    // MARK: Renderer host

    @Test func aRendererFromAnEarlierRenderCannotReportIntoTheNextOne() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        let staleHost = harness.session.rendererHost
        await harness.renderAndWait()
        #expect(staleHost !== harness.session.rendererHost)
        staleHost.report(.rendered)
        staleHost.navigate(to: "https://landing.example/", trigger: "click", source: "creative")
        staleHost.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 1, duration: 15, isPlaying: true, isMuted: false))
        staleHost.rendererLog(RendererLogEntry(date: Date(), origin: "HTML", level: .info, message: "stale"))
        await #expect(throws: CancellationError.self) {
            _ = try await staleHost.fetchContent("https://cdn.example/x.png", trigger: "image", source: "creative")
        }
        #expect(harness.recorder.events == [.won, .won])
        #expect(!harness.categories.contains(.navigation))
        #expect(harness.session.console.isEmpty)
        #expect(harness.session.playback.isEmpty)

        let liveHost = harness.session.rendererHost
        #expect(liveHost.device == harness.session.device)
        #expect(liveHost.monitor === harness.monitor)
        liveHost.report(.rendered)
        #expect(harness.recorder.events == [.won, .won, .rendered])
    }

    /// The proxy must forward EVERY `AdRenderingHost` requirement: a member it leaves out (or whose signature drifts)
    /// silently falls back to the protocol extension's default with no compile error, which only a call through the
    /// existential shows. Each requirement is driven through `any AdRenderingHost` as a renderer holds it, then again
    /// after a generation bump, when every callback is dropped, empty or `CancellationError`.
    @Test func theProxyForwardsEveryHostRequirementAndDropsThemAllAfterAGenerationBump() async throws {
        let scriptURL = "https://js.example/t.js"
        let native = Fixtures.candidate(.native("{\"native\":{}}"), format: .native)
        let harness = SessionHarness(Fixtures.input([native])) { services in
            let plan = services.trackingRequests
            services.trackingRequests = { event, candidate, native, vast, context, options in
                let requests = plan(event, candidate, native, vast, context, options)
                guard event == .rendered else { return requests }
                return requests + [TrackerRequest(category: .impression, trigger: "jstracker", source: "Native", template: scriptURL,
                                                  url: scriptURL, isScript: true)]
            }
        }
        harness.transport.respond("https://cdn.example/image.png", body: "png")
        await harness.paste()
        harness.enterRealMode()
        await harness.renderAndWait()
        let session = harness.session
        let host: any AdRenderingHost = session.rendererHost
        let status = PlaybackStatus(adIndex: 0, playhead: 2.5, duration: 15, isPlaying: true, isMuted: true)
        let logLine = RendererLogEntry(date: Date(), origin: "Native", level: .warning, message: "live")
        let tag = VASTSource.url("https://vast.example/tag")

        // Live: every requirement reaches the session.
        #expect(host.monitor === harness.monitor)
        #expect(host.device == session.device)
        host.report(.rendered)
        #expect(harness.recorder.events.last == .rendered)
        #expect(host.scriptTrackers.map(\.request.url) == [scriptURL])
        #expect(host.scriptTrackers == session.scriptTrackers)
        host.navigate(to: "https://landing.example/live", trigger: "mraid.open", source: "creative")
        #expect(harness.monitor.liveEntries.contains { $0.category == .navigation && $0.url == "https://landing.example/live" })
        // This render has no VAST: a companion navigation reaches the session, which refuses the index.
        let logged = session.lifecycleLog.count
        host.navigate(to: "https://landing.example/companion", trigger: "companion creative navigation", source: "VAST", vastAdIndex: 0)
        #expect(session.lifecycleLog.count == logged + 1)
        #expect(try await host.fetchContent("https://cdn.example/image.png", trigger: "image", source: "Native") == Data("png".utf8))
        host.playbackChanged(status)
        #expect(session.playback[0] == status)
        host.rendererLog(logLine)
        #expect(session.console.last?.entry == logLine)
        #expect(await host.resolveVAST(tag) == Fixtures.vast(ads: 1))
        #expect(harness.recorder.resolutions == [tag])
        #expect(session.nativeVideoVAST == Fixtures.vast(ads: 1))

        // A generation bump (Render again): the old proxy reaches nothing of the new render.
        await harness.renderAndWait()
        #expect(session.phase == .ready)
        let current: any AdRenderingHost = session.rendererHost
        current.report(.rendered)
        #expect(!session.scriptTrackers.isEmpty)
        let events = harness.recorder.events
        let entries = harness.monitor.liveEntries.count
        let consoleLines = session.console.count

        host.report(.closed)
        host.navigate(to: "https://landing.example/stale", trigger: "mraid.open", source: "creative")
        let logLines = session.lifecycleLog.count
        host.navigate(to: "https://landing.example/stale-companion", trigger: "companion creative navigation", source: "VAST", vastAdIndex: 0)
        #expect(session.lifecycleLog.count == logLines)
        await #expect(throws: CancellationError.self) {
            _ = try await host.fetchContent("https://cdn.example/image.png", trigger: "image", source: "Native")
        }
        host.playbackChanged(status)
        host.rendererLog(RendererLogEntry(date: Date(), origin: "Native", level: .error, message: "stale"))
        #expect(await host.resolveVAST(tag) == ResolvedVAST())
        // An old web view can never run the new generation's trackers.
        #expect(host.scriptTrackers.isEmpty)

        #expect(harness.recorder.events == events)
        #expect(harness.monitor.liveEntries.count == entries)
        #expect(session.console.count == consoleLines)
        #expect(session.playback.isEmpty)
        #expect(harness.recorder.resolutions == [tag])
        #expect(session.nativeVideoVAST == nil)
        // The stale proxy's own properties describe its render (same monitor, the device it rendered on): nothing to drop.
        #expect(host.monitor === harness.monitor && host.device == session.device)
    }

    /// An HTML / iframe / script companion's own navigation is a URL of its ad's inline document: it hangs under the hop
    /// that delivered that document (here the wrapper chain's second fetch), not under the bid's markup request. An index
    /// outside the resolved VAST is refused (decisions.md, "Network relationships").
    @Test func aCompanionsOwnNavigationHangsUnderItsHop() async {
        let inlineHop = UUID()
        let ad = ResolvedVASTAd(inline: VASTInline(adSystem: "Acme"), origin: [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0)])
        let resolved = ResolvedVAST(chain: [VASTHop(), VASTHop(url: "https://ads.example/inline.xml", requestID: inlineHop)], ads: [ad])
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.vast(.xml("<VAST/>")), format: .video)]), resolved: resolved)
        await harness.paste()
        await harness.renderAndWait()
        let host: any AdRenderingHost = harness.session.rendererHost
        host.navigate(to: "https://landing.example/companion", trigger: "companion creative navigation", source: "VAST › Companion 1",
                      vastAdIndex: 0)
        let navigations = harness.monitor.liveEntries.filter { $0.category == .navigation }
        #expect(navigations.map(\.url) == ["https://landing.example/companion"])
        #expect(navigations.first?.parentID == inlineHop)
        host.navigate(to: "https://landing.example/other", trigger: "companion creative navigation", source: "VAST", vastAdIndex: 1)
        host.navigate(to: "https://landing.example/negative", trigger: "companion creative navigation", source: "VAST", vastAdIndex: -1)
        #expect(harness.monitor.liveEntries.filter { $0.category == .navigation }.count == 1, "indices outside the VAST are refused")
    }

    @Test func indicesOutsideTheResolvedVASTNeverReachTheTrackingPlan() async {
        var pod = Fixtures.vast(ads: 2)
        pod.ads[0].inline.creatives = [VASTCreative(companions: [VASTCompanion(width: 300, height: 250)])]
        let harness = SessionHarness(Fixtures.input([video]), resolved: pod)
        await harness.paste()
        await harness.renderAndWait()
        let before = harness.recorder.events
        for event: AdLifecycleEvent in [.video(.start, adIndex: -1), .video(.start, adIndex: 2), .videoClick(adIndex: 7),
                                        .videoViewability(.viewable, adIndex: -3), .companionView(adIndex: 0, companionIndex: 1),
                                        .companionClick(adIndex: 1, companionIndex: 0), .error(.fileNotFound, adIndex: 2)] {
            harness.session.report(event)
        }
        #expect(harness.recorder.events == before)
        #expect(harness.session.lifecycleLog.suffix(7).allSatisfy {
            if case .ignored = $0.outcome { true } else { false }
        })
        harness.session.report(.companionView(adIndex: 0, companionIndex: 0))
        harness.session.report(.video(.start, adIndex: 1))
        #expect(harness.recorder.events.suffix(2) == [.companionView(adIndex: 0, companionIndex: 0), .video(.start, adIndex: 1)])
    }

    @Test func scriptTrackersAreListedForTheRendererOnlyInRealModeAndOnlyForTheCurrentRender() async throws {
        let recorder = KitRecorder()
        var services = Fixtures.services(Fixtures.input([display]), recorder: recorder)
        services.trackingRequests = { event, _, _, _, _, _ in
            guard event == .rendered else { return [] }
            return [TrackerRequest(category: .impression, trigger: "jstracker", source: "Native", template: "https://js.example/t.js",
                                   url: "https://js.example/t.js", isScript: true)]
        }
        let transport = CountingTransport()
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let session = AdSession(services: services, monitor: monitor, clock: ManualSessionClock(), browser: RecordingBrowser(),
                                opensClickThroughs: { false }, parseDebounce: .zero)
        session.responseText = "response"
        await session.parseNow()

        session.render()
        for _ in 0..<500 where session.phase != .ready { try await Task.sleep(for: .milliseconds(1)) }
        session.rendererHost.report(.rendered)
        #expect(session.scriptTrackers.isEmpty)
        #expect(monitor.liveEntries.contains { $0.url == "https://js.example/t.js" })

        session.requestRealMode()
        session.confirmRealMode(try #require(session.realModeConfirmation))
        session.render()
        for _ in 0..<500 where session.phase != .ready { try await Task.sleep(for: .milliseconds(1)) }
        let host: any AdRenderingHost = session.rendererHost
        host.report(.rendered)
        #expect(host.scriptTrackers.map(\.request.url) == ["https://js.example/t.js"])
        #expect(host.scriptTrackers == session.scriptTrackers)

        session.render()
        #expect(host.scriptTrackers.isEmpty)
        #expect(session.scriptTrackers.isEmpty)
    }

    @Test func rendererLogIsKeptInOrderAndCapped() async {
        let harness = SessionHarness(Fixtures.input([display]))
        for index in 0..<(AdSession.consoleCapacity + 5) {
            harness.session.rendererLog(RendererLogEntry(date: Date(), origin: "MRAID", level: .info, message: "line \(index)"))
        }
        #expect(harness.session.console.count == AdSession.consoleCapacity)
        #expect(harness.session.console.first?.entry.message == "line 5")
        #expect(Set(harness.session.console.map(\.id)).count == AdSession.consoleCapacity)
        harness.session.clearConsole()
        #expect(harness.session.console.isEmpty)
    }

    @Test func playbackStatusFeedsThePlayheadMacroAndIgnoresNonsense() async throws {
        let harness = SessionHarness(Fixtures.input([video]))
        await harness.paste()
        await harness.renderAndWait()
        harness.session.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 7.25, duration: 15, isPlaying: true, isMuted: false))
        harness.session.playbackChanged(PlaybackStatus(adIndex: 0, playhead: .nan, duration: 15, isPlaying: true, isMuted: false))
        harness.session.playbackChanged(PlaybackStatus(adIndex: -1, playhead: 1, duration: 15, isPlaying: true, isMuted: false))
        harness.session.report(.video(.midpoint, adIndex: 0))
        let context = try #require(harness.recorder.contexts.last)
        #expect(context.adPlayhead == 7.25)
        #expect(harness.session.playback.keys.sorted() == [0])
    }

    // MARK: Macros

    @Test func macroContextComesFromTheBidThePanelAndTheDevice() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        harness.session.macros.clearingPrice = "1,23"
        harness.session.macros.customMacros = [MacroEntry(key: "${CAMPAIGN}", value: "spring")]
        harness.session.macros.deterministic = true
        await harness.paste()
        await harness.renderAndWait()
        let context = try #require(harness.recorder.contexts.first)
        #expect(context.price == 1.23)
        #expect(context.auctionID == "auction-1")
        #expect(context.bidID == "bid-0.0")
        #expect(context.seatID == "seat-a")
        #expect(context.custom["CAMPAIGN"] == "spring")
        #expect(context.custom["[DOMAIN]"] == "news.example.com")
        #expect(context.custom["[TRANSACTIONID]"] == MacroSettings.deterministicTransactionID)
        #expect(context.timestamp == MacroSettings.deterministicTimestamp)
        #expect(context.cacheBuster == MacroSettings.deterministicCacheBuster)
        #expect(context.device == DeviceCatalog.defaultDevice)
        #expect(context.playerWidth == 320 && context.playerHeight == 50)
        #expect(abs((context.marketBidRatio ?? 0) - 1.23 / 2.5) < 1e-9)
    }

    @Test func theResponseLevelBidIDIsTheAuctionBidID() async throws {
        var input = Fixtures.input([display])
        input.bidResponseID = "resp-bidid"
        let harness = SessionHarness(input)
        await harness.paste()
        await harness.renderAndWait()
        #expect(try #require(harness.recorder.contexts.first).bidID == "resp-bidid")
    }

    // MARK: Context changes

    @Test func anotherDeviceOrPlacementReRendersInSimulatedMode() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        await harness.renderAndWait()
        let first = harness.session.generation
        harness.session.device = try #require(DeviceCatalog.device(id: "pixel-8"))
        await harness.waitUntilSettled()
        #expect(harness.session.generation == first + 1)
        #expect(harness.session.phase == .ready)
        #expect(harness.session.rendererHost.device.id == "pixel-8")
        harness.session.placement = .interstitial
        await harness.waitUntilSettled()
        #expect(harness.session.generation == first + 2)
        #expect(harness.recorder.events == [.won, .won, .won])
        // Orientation and posture keep the ad (the creative is told its new size).
        harness.session.landscape = true
        #expect(harness.session.generation == first + 2)
    }

    @Test func twoRendersInOneTurnOnlyRenderTheLatestBid() async throws {
        let first = Fixtures.candidate(.html("<p>1</p>"), id: "0.0")
        let second = Fixtures.candidate(.html("<p>2</p>"), id: "0.1")
        let harness = SessionHarness(Fixtures.input([first, second]))
        await harness.paste()
        harness.session.render()
        harness.session.selectedCandidateID = second.id
        harness.session.render()
        await harness.waitUntilSettled()
        #expect(harness.session.prepared?.candidate.id == second.id)
        #expect(harness.recorder.events == [.won])
        #expect(harness.recorder.contexts.map(\.bidID) == [second.bidID])
    }

    @Test func theInViewShareCarriesOverBetweenTheFeedAndTheSlider() {
        let harness = SessionHarness(Fixtures.input([display]))
        let session = harness.session
        #expect(session.visibleFraction == 1)
        session.placement = .inFeed
        // The feed opens scrolled so that the ad is as much in view as the slider said.
        #expect(session.visibleFraction > 0.99)
        session.setVisibleFraction(0.3)
        #expect(abs(session.visibleFraction - 0.3) < 0.01)
        session.placement = .interstitial
        #expect(abs(session.visibility - 0.3) < 0.01)
        #expect(abs(session.visibleFraction - 0.3) < 0.01)
    }

    @Test func anotherDeviceInRealModeRemovesTheAdWithoutSendingAnything() async throws {
        let harness = SessionHarness(Fixtures.input([display]))
        await harness.paste()
        harness.enterRealMode()
        await harness.renderAndWait()
        let sent = harness.transport.requests.count
        harness.session.device = try #require(DeviceCatalog.device(id: "pixel-8"))
        await harness.monitor.waitUntilIdle()
        #expect(harness.session.phase == .idle)
        #expect(harness.transport.requests.count == sent)
    }

    @Test func confirmingRealModeFetchesWinNoticeMarkupThatWasWaitingForIt() async throws {
        let harness = SessionHarness(Fixtures.input([Fixtures.candidate(.none, format: .video)]))
        harness.transport.respond("https://win.dsp.example/w?p=2.5", body: "<VAST version=\"3.0\"><Ad/></VAST>")
        await harness.paste()
        await harness.renderAndWait()
        #expect(harness.session.phase == .needsRealMode("The markup is delivered by the win notice — switch to Real to fetch it."))
        harness.enterRealMode()
        await harness.waitUntilSettled()
        #expect(harness.session.phase == .ready)
        #expect(harness.transport.requests.filter { $0.url.host == "win.dsp.example" }.count == 1)
    }
}
