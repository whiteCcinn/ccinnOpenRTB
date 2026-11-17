import Foundation
import Testing
@testable import CcinnOpenRTB

@Suite("JavaScript literals")
struct JSLiteralTests {
    @Test func stringsAreSafeInsideScriptSource() throws {
        let hostile = "\"; alert(1); //\u{2028}</script>\\"
        let literal = JSLiteral.string(hostile)
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        #expect(!literal.contains("\u{2028}"), "line separators would end a JS string in old engines")
        #expect(!literal.contains("</script"), "the literal must not close an HTML script element")
        // It is still the same string once parsed as JSON.
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded == hostile)
    }

    @Test func encodablesBecomeObjectLiterals() {
        struct Payload: Encodable { var a = 1; var b = "x\u{2029}" }
        let literal = JSLiteral.json(Payload())
        #expect(literal == #"{"a":1,"b":"x\u2029"}"#)
    }
}

@Suite("Creative request ledger")
struct CreativeRequestLedgerTests {
    private final class Recorder {
        var recorded: [(url: String, kind: String, blocked: Bool)] = []
        func record(_ url: String, _ kind: String, _ blocked: Bool) -> UUID {
            recorded.append((url, kind, blocked))
            return UUID()
        }
    }

    @Test func startsAreRecordedAndEndsFinishTheMatchingEntry() {
        var ledger = CreativeRequestLedger(capacity: 10)
        let recorder = Recorder()
        let first = ledger.start(rid: "f1:1", url: "https://a.example/p.gif", kind: "img", blocked: true, record: recorder.record)
        let second = ledger.start(rid: "f1:2", url: "https://a.example/x", kind: "fetch", blocked: true, record: recorder.record)
        #expect(recorder.recorded.map(\.url) == ["https://a.example/p.gif", "https://a.example/x"])
        #expect(recorder.recorded.allSatisfy { $0.blocked })
        guard case let .recorded(firstID) = first, case let .recorded(secondID) = second else {
            Issue.record("not recorded")
            return
        }
        #expect(ledger.end(rid: "f1:2") == secondID)
        #expect(ledger.end(rid: "f1:2") == nil, "an end is used once")
        #expect(ledger.end(rid: "f1:1") == firstID)
        #expect(ledger.end(rid: "unknown") == nil)
    }

    @Test func aDuplicateRequestIDIsNotRecordedTwice() {
        var ledger = CreativeRequestLedger(capacity: 10)
        let recorder = Recorder()
        _ = ledger.start(rid: "a:1", url: "https://a.example/1", kind: "img", blocked: false, record: recorder.record)
        #expect(ledger.start(rid: "a:1", url: "https://a.example/1", kind: "img", blocked: false, record: recorder.record) == .ignored)
        #expect(recorder.recorded.count == 1)
    }

    @Test func capacityStopsRecordingAndReportsOverflowOnce() {
        var ledger = CreativeRequestLedger(capacity: 2)
        let recorder = Recorder()
        _ = ledger.start(rid: "1", url: "https://a.example/1", kind: "img", blocked: true, record: recorder.record)
        _ = ledger.timing(url: "https://a.example/font.woff2", kind: "css", blocked: false, record: recorder.record)
        #expect(ledger.start(rid: "3", url: "https://a.example/3", kind: "img", blocked: true, record: recorder.record) == .overflow)
        #expect(ledger.start(rid: "4", url: "https://a.example/4", kind: "img", blocked: true, record: recorder.record) == .ignored)
        #expect(ledger.timing(url: "https://a.example/5", kind: "css", blocked: false, record: recorder.record) == .ignored)
        #expect(recorder.recorded.count == 2)
        #expect(ledger.recordedCount == 2)
    }

    @Test func timingRecordsALoadTheHooksMissed() {
        var ledger = CreativeRequestLedger(capacity: 5)
        let recorder = Recorder()
        guard case .recorded = ledger.timing(url: "https://fonts.example/a.woff2", kind: "css", blocked: false, record: recorder.record) else {
            Issue.record("timing not recorded")
            return
        }
        #expect(recorder.recorded.first?.kind == "css")
        #expect(recorder.recorded.first?.blocked == false)
    }
}

@Suite("Navigation classifier")
struct NavigationClassifierTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)
    private let base = CreativeWebController.baseURL.absoluteString

    private func facts(_ url: String, mainFrame: Bool = true, newWindow: Bool = false, initial: Bool = false, current: String? = nil)
        -> NavigationFacts {
        NavigationFacts(url: url, isMainFrame: mainFrame, targetsNewWindow: newWindow, isAwaitingInitialLoad: initial,
                        currentURL: current ?? base)
    }

    @Test func fragmentNavigationsStayInTheDocument() {
        #expect(NavigationClassifier.decide(facts(base + "#", current: base), lastGesture: nil, now: now) == .allow)
        #expect(NavigationClassifier.decide(facts(base + "#section-2", current: base + "#"), lastGesture: now, now: now) == .allow)
        // Not the same document: another path, or a fragment opened in a new window.
        #expect(NavigationClassifier.decide(facts(base + "other#x", current: base), lastGesture: nil, now: now) == .autoRedirect(url: base + "other#x"))
        #expect(NavigationClassifier.decide(facts(base + "#x", newWindow: true, current: base), lastGesture: nil, now: now)
            == .autoRedirect(url: base + "#x"))
        #expect(NavigationClassifier.decide(facts("https://adv.example/#x", current: nil), lastGesture: nil, now: now)
            == .autoRedirect(url: "https://adv.example/#x"))
    }

    @Test func theInitialDocumentLoads() {
        #expect(NavigationClassifier.decide(facts(base, initial: true), lastGesture: nil, now: now) == .allow)
    }

    @Test func subframesLoadAndAreLeftToTheContentRules() {
        #expect(NavigationClassifier.decide(facts("https://cdn.example/frame.html", mainFrame: false), lastGesture: nil, now: now) == .allow)
        #expect(NavigationClassifier.decide(facts("about:blank", mainFrame: false), lastGesture: nil, now: now) == .allow)
    }

    @Test func aMainFrameNavigationAfterAGestureIsAClick() {
        let gesture = now.addingTimeInterval(-0.4)
        #expect(NavigationClassifier.decide(facts("https://adv.example/landing"), lastGesture: gesture, now: now)
            == .click(url: "https://adv.example/landing"))
        #expect(NavigationClassifier.decide(facts("https://adv.example/popup", newWindow: true), lastGesture: gesture, now: now)
            == .click(url: "https://adv.example/popup"))
    }

    @Test func withoutARecentGestureItIsAnAutoRedirect() {
        #expect(NavigationClassifier.decide(facts("https://evil.example/"), lastGesture: nil, now: now) == .autoRedirect(url: "https://evil.example/"))
        let stale = now.addingTimeInterval(-NavigationClassifier.gestureWindow - 0.1)
        #expect(NavigationClassifier.decide(facts("https://evil.example/"), lastGesture: stale, now: now) == .autoRedirect(url: "https://evil.example/"))
        #expect(NavigationClassifier.decide(facts(base, initial: false), lastGesture: nil, now: now) == .autoRedirect(url: base),
                "a reload of the document is not the initial load")
    }

    @Test func nonNavigableURLsAreDropped() {
        #expect(NavigationClassifier.decide(facts("about:blank"), lastGesture: now, now: now) == .ignore)
        #expect(NavigationClassifier.decide(facts(""), lastGesture: now, now: now) == .ignore)
        #expect(NavigationClassifier.decide(facts("javascript:void(0)", newWindow: true), lastGesture: now, now: now) == .ignore)
    }

    @Test func gesturesFromTheFutureDoNotCount() {
        #expect(NavigationClassifier.decide(facts("https://a.example"), lastGesture: now.addingTimeInterval(5), now: now) == .autoRedirect(url: "https://a.example"))
    }
}

@Suite("Bridge channels")
struct BridgeChannelTests {
    @Test func networkPhases() {
        #expect(BridgeMessage.decode(["channel": "net", "phase": "start", "rid": "f:1", "url": "https://t.example/p", "kind": "fetch"])
            == .network(.start(rid: "f:1", url: "https://t.example/p", kind: "fetch")))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "end", "rid": "f:1", "status": 204, "bytes": 12])
            == .network(.end(rid: "f:1", status: 204, bytes: 12, error: nil)))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "end", "rid": "f:1", "status": 0, "error": "TypeError"])
            == .network(.end(rid: "f:1", status: 0, bytes: nil, error: "TypeError")))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "timing", "url": "https://f.example/a.woff2", "kind": "css", "bytes": 9000])
            == .network(.timing(url: "https://f.example/a.woff2", kind: "css", status: nil, bytes: 9000)))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "overflow"]) == .network(.overflow))
    }

    @Test func numbersAreBoundedAndTyped() {
        #expect(BridgeMessage.decode(["channel": "net", "phase": "end", "rid": "x", "status": -5, "bytes": Double.infinity])
            == .network(.end(rid: "x", status: nil, bytes: nil, error: nil)))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "end", "rid": "x", "status": "200"])
            == .network(.end(rid: "x", status: nil, bytes: nil, error: nil)))
        #expect(BridgeMessage.decode(["channel": "net", "phase": "start", "rid": "x", "url": ""]) == nil)
        #expect(BridgeMessage.decode(["channel": "net", "phase": "teleport"]) == nil)
    }

    @Test func windowOpenAndMRAIDErrors() {
        #expect(BridgeMessage.decode(["channel": "open", "url": "https://adv.example/"]) == .windowOpen(url: "https://adv.example/"))
        #expect(BridgeMessage.decode(["channel": "open"]) == nil)
        #expect(BridgeMessage.decode(["channel": "mraidError", "message": "resize properties not set", "action": "resize"])
            == .mraidError(message: "resize properties not set", action: "resize"))
    }
}
