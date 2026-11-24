import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
import WebKit
@testable import CcinnOpenRTB

@Suite("Touch gestures (bridge)")
struct TouchGestureTests {
    private func message(_ fields: [String: Any]) -> [String: Any] {
        ["channel": "touch", "kind": "tap", "x": 120.4, "y": 339.6, "dx": 0, "dy": 0, "duration": 80, "cancelled": false, "scrolled": false]
            .merging(fields) { $1 }
    }

    @Test func decodesTapsSwipesAndCancellations() {
        #expect(BridgeMessage.decode(message([:])) == .touch(TouchGesture(kind: .tap, x: 120.4, y: 339.6, dx: 0, dy: 0, duration: 80)))
        let swipe = BridgeMessage.decode(message(["kind": "swipe", "dx": -180, "dy": 12, "duration": 220, "scrolled": true]))
        #expect(swipe == .touch(TouchGesture(kind: .swipe, x: 120.4, y: 339.6, dx: -180, dy: 12, duration: 220, scrolled: true)))
        #expect(BridgeMessage.decode(message(["kind": "cancel"])) == .touch(TouchGesture(kind: .cancel, x: 120.4, y: 339.6, dx: 0, dy: 0,
                                                                                          duration: 80)))
    }

    @Test func malformedGesturesAreDropped() {
        #expect(BridgeMessage.decode(message(["kind": "pinch"])) == nil)
        #expect(BridgeMessage.decode(message(["x": "120"])) == nil)
        #expect(BridgeMessage.decode(message(["dx": Double.nan])) == nil)
        #expect(BridgeMessage.decode(message(["dy": 1e9])) == nil)
        #expect(BridgeMessage.decode(message(["duration": -1])) == nil)
        #expect(BridgeMessage.decode(message(["x": true])) == nil, "a boolean is not a coordinate")
        // A flag that is not a boolean counts as not set.
        guard case let .touch(gesture)? = BridgeMessage.decode(message(["cancelled": 1, "scrolled": "yes"])) else {
            Issue.record("the gesture was dropped")
            return
        }
        #expect(!gesture.cancelledByCreative && !gesture.scrolled)
    }

    @Test func aSwipeIsNamedByItsMainAxis() {
        #expect(TouchGesture(kind: .swipe, x: 0, y: 0, dx: -180, dy: 30, duration: 1).direction == .left)
        #expect(TouchGesture(kind: .swipe, x: 0, y: 0, dx: 180, dy: -30, duration: 1).direction == .right)
        #expect(TouchGesture(kind: .swipe, x: 0, y: 0, dx: 20, dy: -300, duration: 1).direction == .up)
        #expect(TouchGesture(kind: .swipe, x: 0, y: 0, dx: -20, dy: 40, duration: 1).direction == .down)
        #expect(TouchGesture(kind: .tap, x: 0, y: 0, dx: 3, dy: 2, duration: 1).direction == nil)
    }

    @Test func logLinesSayWhatHappened() {
        #expect(TouchGesture(kind: .tap, x: 120.4, y: 339.6, dx: 0, dy: 0, duration: 80).logLine == "Tap at 120, 340")
        #expect(TouchGesture(kind: .tap, x: 120, y: 340, dx: 0, dy: 0, duration: 80, cancelledByCreative: true).logLine
            == "Tap at 120, 340: the creative cancelled it (preventDefault), so no click followed")
        #expect(TouchGesture(kind: .swipe, x: 250, y: 100, dx: -180.4, dy: 6, duration: 220).logLine == "Swipe left 180 pt in 220 ms")
        #expect(TouchGesture(kind: .swipe, x: 250, y: 100, dx: 0, dy: -400, duration: 1_540, scrolled: true).logLine
            == "Swipe up 400 pt in 1.5 s, scrolling the creative")
        #expect(TouchGesture(kind: .swipe, x: 250, y: 100, dx: 90, dy: 0, duration: 120, cancelledByCreative: true).logLine
            == "Swipe right 90 pt in 120 ms, handled by the creative (it called preventDefault)")
        #expect(TouchGesture(kind: .cancel, x: 10, y: 20, dx: 0, dy: 0, duration: 5).logLine == "Touch at 10, 20 cancelled")
    }
}

@Suite("Gesture press tracker")
struct GesturePressTrackerTests {
    @Test func theReleaseOfAPressOnTheCreativeIsAGesture() {
        var tracker = GesturePressTracker()
        let press = tracker.press(inside: true)
        let release = tracker.release()
        let again = tracker.release()
        #expect(press)
        #expect(release, "a finger lifted after a swipe, wherever the pointer is")
        #expect(!again, "one release per press")
    }

    @Test func aPressElsewhereIsNot() {
        var tracker = GesturePressTracker()
        let press = tracker.press(inside: false)
        let release = tracker.release()
        #expect(!press && !release)
    }

    @Test func aPressElsewhereEndsTheOneOnTheCreative() {
        var tracker = GesturePressTracker()
        _ = tracker.press(inside: true)
        _ = tracker.press(inside: false)
        let release = tracker.release()
        #expect(!release)
    }
}

@Suite("Touch points")
struct TouchPointsTests {
    @Test func touchDevicesHaveFivePointsAndCTVNone() {
        #expect(RendererFixtures.phone.maxTouchPoints == 5)
        #expect(RendererFixtures.tv.maxTouchPoints == 0)
    }
}

/// The emulation driven with real mouse events: `WKWebView.mouseDown(with:)` & co. reach the page as trusted events, the
/// only kind the emulation turns into touches.
@MainActor
@Suite("Touch emulation (WebKit)", .serialized)
struct TouchEmulationWebKitTests {
    @MainActor
    private final class Harness {
        let controller: CreativeWebController
        let host: RecordingHost
        let events: ControllerEvents
        let window: NSWindow
        static let size = CGSize(width: 320, height: 480)

        init(controller: CreativeWebController, host: RecordingHost, events: ControllerEvents) {
            self.controller = controller
            self.host = host
            self.events = events
            window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller.webView.frame = NSRect(origin: .zero, size: Self.size)
            window.contentView = controller.webView
            window.orderFrontRegardless()
        }

        func close() {
            controller.teardown()
            window.orderOut(nil)
            window.contentView = nil
        }

        func evaluate(_ script: String) async throws -> Any? {
            try await controller.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }

        private var eventNumber = 0

        /// A mouse event at `point` in the page's CSS pixels (top-left origin). Each has its own event number, as WebKit's own
        /// test harness makes them.
        private func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: eventNumber, clickCount: 1, pressure: 0)
        }

        func press(_ point: CGPoint) {
            if let event = event(.leftMouseDown, point) { controller.webView.mouseDown(with: event) }
        }

        func drag(_ point: CGPoint) {
            if let event = event(.leftMouseDragged, point) { controller.webView.mouseDragged(with: event) }
        }

        func release(_ point: CGPoint) {
            if let event = event(.leftMouseUp, point) { controller.webView.mouseUp(with: event) }
        }

        func hover(_ point: CGPoint) {
            if let event = event(.mouseMoved, point) { controller.webView.mouseMoved(with: event) }
        }

        /// A press and a release, the press handled first (a finger is never down for no time at all).
        func tap(_ point: CGPoint) async {
            press(point)
            await nextFrame()
            release(point)
        }

        /// After a round trip to the page: the events sent before it have been handled (WebKit coalesces moves sent at
        /// once). Not an animation frame: the window is off screen, so WebKit holds `requestAnimationFrame` back.
        func nextFrame() async {
            _ = try? await evaluate("return 1")
        }

        /// A drag in `steps` moves, each handled before the next.
        func swipe(from start: CGPoint, to end: CGPoint, steps: Int = 6) async {
            press(start)
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                drag(CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
                await nextFrame()
            }
            release(end)
        }

        /// The page's event log (`window.__log`) once `done` holds for it.
        func log(until done: @escaping ([String]) -> Bool) async -> [String] {
            var last: [String] = []
            _ = await Wait.until(timeout: .seconds(10)) {
                last = (try? await self.evaluate("return window.__log || []")) as? [String] ?? []
                return done(last)
            }
            return last
        }
    }

    /// Logs every input event the page receives at the window (capture) as `type:target[:pointerType][:trusted]`.
    private static let recorder = """
    <style>html,body{margin:0}#a{position:absolute;left:0;top:0;width:320px;height:200px;background:#36c}
    #b{position:absolute;left:0;top:200px;width:320px;height:280px;background:#c63}</style>
    <div id="a"></div><div id="b"></div>
    <script>
      window.__log = [];
      ['pointerover','pointerenter','pointerdown','pointermove','pointerup','pointercancel','pointerout','pointerleave',
       'touchstart','touchmove','touchend','touchcancel','mouseover','mouseenter','mousemove','mousedown','mouseup','mouseout',
       'mouseleave','click','dragstart','selectstart'].forEach(function (type) {
        window.addEventListener(type, function (e) {
          var name = type + ':' + (e.target && e.target.id || (e.target === document ? 'document' : e.target && e.target.nodeName));
          if (e.pointerType) { name += ':' + e.pointerType; }
          if (e.isTrusted) { name += ':trusted'; }
          window.__log.push(name);
        }, true);
      });
    </script>
    """

    private func load(_ adm: String, device: DeviceProfile = RendererFixtures.phone, disableScroll: Bool = true) async -> Harness {
        let host = RecordingHost(device: device)
        let controller = CreativeWebController(host: host)
        let events = ControllerEvents()
        events.attach(controller)
        let harness = Harness(controller: controller, host: host, events: events)
        let request = RendererFixtures.request(.html(adm), placement: .interstitial, visibleFraction: 1)
        controller.load(CreativeWebController.Content(document: HTMLDocumentBuilder.document(for: adm), mraid: MRAIDEnvironment(request: request),
                                                      blocksNetwork: true, disableScroll: disableScroll, networkParentID: nil,
                                                      source: "bid 0.0 › adm"))
        let loaded = await Wait.until(timeout: .seconds(20)) { events.loaded }
        #expect(loaded, "the creative never finished loading: \(events.events)")
        return harness
    }

    private static func on(_ target: String, _ log: [String]) -> [String] {
        log.filter { $0.split(separator: ":").dropFirst().first.map(String.init) == target }
    }

    @Test func aTouchDeviceLooksLikeOne() async throws {
        let harness = await load("<div id='a'></div>")
        defer { harness.close() }
        let facts = try await harness.evaluate("""
        return [String('ontouchstart' in window), String('ontouchend' in document.documentElement), typeof TouchEvent, typeof Touch,
                String(navigator.maxTouchPoints), String(matchMedia('(pointer: coarse)').matches), String(matchMedia('(pointer:fine)').matches),
                String(matchMedia('(hover: none)').matches), String(matchMedia('(hover: hover)').matches), String(matchMedia('(hover)').matches),
                String(matchMedia('(any-pointer: coarse) and (any-hover: none)').matches), matchMedia('(pointer: coarse)').media,
                String(new Touch({ identifier: 1, target: document.body, clientX: 5 }).clientX),
                String(new TouchEvent('touchstart', { touches: [new Touch({ identifier: 2, target: document.body })] }).touches.length),
                String(document.createEvent('TouchEvent') instanceof TouchEvent), String(window.ontouchstart)]
        """) as? [String]
        #expect(facts == ["true", "true", "function", "function", "5", "true", "false", "true", "false", "false", "true",
                          "(pointer: coarse)", "5", "1", "true", "null"])
    }

    @Test func aCTVIsLeftAlone() async throws {
        let harness = await load("<div id='a'></div>", device: RendererFixtures.tv)
        defer { harness.close() }
        let facts = try await harness.evaluate("return [String('ontouchstart' in window), typeof TouchEvent, String(navigator.maxTouchPoints)]")
            as? [String]
        #expect(facts == ["false", "undefined", "0"])
    }

    @Test func aTapIsWhatAPhoneSends() async throws {
        let harness = await load(Self.recorder)
        defer { harness.close() }
        await harness.tap(CGPoint(x: 100, y: 100))
        let log = await harness.log { $0.contains { $0.hasPrefix("click:") } }
        #expect(Self.on("a", log) == ["pointerover:a:touch", "pointerenter:a:touch", "pointerdown:a:touch", "touchstart:a", "pointerup:a:touch",
                                      "pointerout:a:touch", "pointerleave:a:touch", "touchend:a", "mouseover:a", "mouseenter:a", "mousemove:a",
                                      "mousedown:a", "mouseup:a", "click:a:touch:trusted"], "\(log)")
        #expect(!log.contains { $0.hasSuffix(":mouse:trusted") || $0.hasPrefix("selectstart") }, "no mouse pointer reaches the page: \(log)")
        let logged = await Wait.until { harness.host.logs.contains { $0.origin == "Touch" && $0.message == "Tap at 100, 100" } }
        #expect(logged, "\(harness.host.logs.map(\.message))")
    }

    @Test func touchListsDescribeTheFinger() async throws {
        let harness = await load(Self.recorder)
        defer { harness.close() }
        _ = try await harness.evaluate("""
        window.__lists = [];
        var a = document.getElementById('a');
        a.addEventListener('touchstart', function (e) { __lists.push(e.touches.length, e.targetTouches.length, e.changedTouches.length, e.touches[0].clientX, e.touches.item(0).target.id, e instanceof TouchEvent, e.cancelable, e.bubbles); });
        a.addEventListener('touchend', function (e) { __lists.push(e.touches.length, e.changedTouches.length, e.changedTouches[0].clientY); });
        """)
        await harness.tap(CGPoint(x: 60, y: 120))
        _ = await harness.log { $0.contains { $0.hasPrefix("click:") } }
        let lists = try await harness.evaluate("return __lists.map(String)") as? [String]
        #expect(lists == ["1", "1", "1", "60", "a", "true", "true", "true", "0", "1", "120"])
    }

    @Test func aCancelledTapGetsNoClick() async throws {
        let harness = await load(Self.recorder + "<script>document.getElementById('a').addEventListener('touchend', function (e) { e.preventDefault(); });</script>")
        defer { harness.close() }
        await harness.tap(CGPoint(x: 100, y: 100))
        let logged = await Wait.until { harness.host.logs.contains { $0.origin == "Touch" && $0.message.contains("no click followed") } }
        #expect(logged, "\(harness.host.logs.map(\.message))")
        let log = await harness.log { $0.contains("touchend:a") }
        #expect(!log.contains { $0.hasPrefix("mouse") || $0.hasPrefix("click") }, "\(log)")
    }

    @Test func aSwipeStaysOnItsElementAndClicksNothing() async throws {
        let harness = await load(Self.recorder)
        defer { harness.close() }
        _ = try await harness.evaluate("""
        window.__moves = [];
        document.getElementById('a').addEventListener('touchmove', function (e) { __moves.push(e.target.id + '@' + Math.round(e.touches[0].clientX) + ',' + Math.round(e.touches[0].clientY)); });
        """)
        // From #a down into #b: touch events keep the element the finger went down on.
        await harness.swipe(from: CGPoint(x: 250, y: 150), to: CGPoint(x: 70, y: 260))
        let log = await harness.log { $0.contains("touchend:a") }
        #expect(log.contains("touchstart:a") && log.contains("touchmove:a") && !log.contains("touchmove:b"), "\(log)")
        #expect(!log.contains { $0.hasPrefix("click") || $0.hasPrefix("mousedown") || $0.hasPrefix("selectstart") }, "\(log)")
        let moves = try await harness.evaluate("return __moves") as? [String] ?? []
        #expect(moves.last == "a@70,260", "\(moves)")
        let logged = await Wait.until { harness.host.logs.contains { $0.origin == "Touch" && $0.message.hasPrefix("Swipe left 180 pt in ") } }
        #expect(logged, "\(harness.host.logs.map(\.message))")
    }

    @Test func handlerPropertiesAndInlineAttributesRun() async throws {
        let harness = await load(#"<div id="a" style="width:320px;height:480px" ontouchstart="window.__inline = (window.__inline || 0) + 1"></div>"#)
        defer { harness.close() }
        _ = try await harness.evaluate("""
        var a = document.getElementById('a');
        a.ontouchend = function (e) { window.__property = this.id + ':' + e.type; };
        window.__getter = a.ontouchend === a.ontouchend && typeof a.ontouchend;
        """)
        await harness.tap(CGPoint(x: 50, y: 50))
        let ran = await Wait.until { (try? await harness.evaluate("return [String(window.__inline), String(window.__property)]")) as? [String] == ["1", "a:touchend"] }
        let seen = try await harness.evaluate("return [String(window.__inline), String(window.__property), String(window.__getter)]") as? [String]
        #expect(ran, "\(seen ?? [])")
        _ = try await harness.evaluate("document.getElementById('a').ontouchend = null; window.__property = 'removed';")
        await harness.tap(CGPoint(x: 50, y: 50))
        let twice = await Wait.until { (try? await harness.evaluate("return window.__inline")) as? Int == 2 }
        #expect(twice)
        #expect(try await harness.evaluate("return window.__property") as? String == "removed")
    }

    @Test func aScrollingCarouselFollowsTheFingerAndSnaps() async throws {
        let carousel = """
        <style>html,body{margin:0}#c{width:300px;height:200px;overflow-x:auto;display:flex;scroll-snap-type:x mandatory}
        #c div{flex:0 0 300px;height:200px;scroll-snap-align:start}</style>
        <div id="c"><div id="p1" style="background:#f00"></div><div id="p2" style="background:#0f0"></div><div id="p3" style="background:#00f"></div></div>
        """
        let harness = await load(carousel)
        defer { harness.close() }
        func state() async -> [String] {
            (try? await harness.evaluate("var c = document.getElementById('c'); return [String(c.scrollLeft), c.style.scrollSnapType]")) as? [String] ?? []
        }
        harness.press(CGPoint(x: 250, y: 100))
        for x in stride(from: 230, through: 130, by: -20) {
            harness.drag(CGPoint(x: CGFloat(x), y: 100))
            await harness.nextFrame()
        }
        // While the finger is down the content follows it exactly, its snapping suspended.
        let following = await Wait.until { await state() == ["120", "none"] }
        let during = await state()
        #expect(following, "\(during)")
        harness.release(CGPoint(x: 130, y: 100))
        // Released, it settles on a snap point (which one depends on the finger's speed) with the carousel's own snapping back.
        let settled = await Wait.until { let now = await state(); return (now.first == "0" || now.first == "300") && now.last == "" }
        let after = await state()
        #expect(settled, "\(after)")
        let snap = try await harness.evaluate("return getComputedStyle(document.getElementById('c')).scrollSnapType") as? String
        #expect(snap?.hasPrefix("x mandatory") == true, "\(snap ?? "nil")")
        let logged = await Wait.until { harness.host.logs.contains { $0.origin == "Touch" && $0.message.hasSuffix(", scrolling the creative") } }
        #expect(logged, "\(harness.host.logs.map(\.message))")
    }

    @Test func touchActionNoneAndACancelledMoveDoNotScroll() async throws {
        let strip = """
        <style>html,body{margin:0}.s{width:300px;height:100px;overflow-x:auto;white-space:nowrap}.s span{display:inline-block;width:900px;height:100px}</style>
        <div class="s" id="none" style="touch-action:none"><span></span></div>
        <div class="s" id="js"><span></span></div>
        <div class="s" id="free"><span></span></div>
        <script>document.getElementById('js').addEventListener('touchmove', function (e) { e.preventDefault(); }, { passive: false });</script>
        """
        let harness = await load(strip)
        defer { harness.close() }
        await harness.swipe(from: CGPoint(x: 250, y: 50), to: CGPoint(x: 150, y: 50))
        await harness.swipe(from: CGPoint(x: 250, y: 150), to: CGPoint(x: 150, y: 150))
        await harness.swipe(from: CGPoint(x: 250, y: 250), to: CGPoint(x: 150, y: 250))
        let free = await Wait.until { ((try? await harness.evaluate("return document.getElementById('free').scrollLeft")) as? Int ?? 0) >= 100 }
        #expect(free, "the control strip scrolls")
        let others = try await harness.evaluate("return [document.getElementById('none').scrollLeft, document.getElementById('js').scrollLeft]") as? [Int]
        #expect(others == [0, 0])
        #expect(harness.host.logs.contains { $0.origin == "Touch" && $0.message.hasSuffix("handled by the creative (it called preventDefault)") }, "\(harness.host.logs.map(\.message))")
    }

    /// An ad tag's "friendly" iframe: created empty, then written with `document.open()` / `write()`, which erases the
    /// window's listeners. WebKit runs the scripts again there; the finger must still work inside it.
    @Test func aFriendlyIframeWrittenByTheTagGetsTheFingerToo() async throws {
        let tag = """
        <style>html,body{margin:0}iframe{border:0;width:320px;height:480px;display:block}</style>
        <script>
          var frame = document.createElement('iframe');
          document.body.appendChild(frame);
          var d = frame.contentWindow.document;
          d.open();
          d.write('<body style="margin:0"><div id="inner" style="width:320px;height:480px" ontouchstart="parent.__inner = typeof TouchEvent + \\':\\' + event.touches.length"></div>'
                  + '<script>document.getElementById("inner").addEventListener("click", function (e) { parent.__innerClick = e.pointerType; });<\\/script></body>');
          d.close();
        </script>
        """
        let harness = await load(tag)
        defer { harness.close() }
        await harness.tap(CGPoint(x: 100, y: 100))
        let touched = await Wait.until { (try? await harness.evaluate("return [String(window.__inner), String(window.__innerClick)]")) as? [String]
            == ["function:1", "touch"] }
        let facts = try await harness.evaluate("return [String(window.__inner), String(window.__innerClick)]") as? [String]
        #expect(touched, "\(facts ?? [])")
    }

    @Test func aTouchInsideAShadowRootReachesTheInnerElement() async throws {
        let component = """
        <style>html,body{margin:0}</style><div id="host"></div>
        <script>
          var root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<div id="inner" style="width:320px;height:480px"></div>';
          root.getElementById('inner').addEventListener('touchstart', function (e) { window.__shadow = e.target.id + ':' + e.touches[0].target.id; });
          document.addEventListener('touchstart', function (e) { window.__outside = e.target.id; });
        </script>
        """
        let harness = await load(component)
        defer { harness.close() }
        await harness.tap(CGPoint(x: 100, y: 100))
        let reached = await Wait.until { (try? await harness.evaluate("return [String(window.__shadow), String(window.__outside)]")) as? [String]
            == ["inner:inner", "host"] }
        #expect(reached, "outside the root the event is retargeted to its host, as browsers do")
    }

    @Test func thePagesOwnMouseEventsAreLeftAlone() async throws {
        let harness = await load(Self.recorder)
        defer { harness.close() }
        _ = try await harness.evaluate("document.getElementById('a').dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))")
        let log = await harness.log { $0.contains("mousedown:a") }
        #expect(log == ["mousedown:a"])
    }

    @Test func thereIsNoHover() async throws {
        let harness = await load(Self.recorder)
        defer { harness.close() }
        harness.hover(CGPoint(x: 100, y: 100))
        harness.hover(CGPoint(x: 120, y: 300))
        await harness.tap(CGPoint(x: 10, y: 10))
        let log = await harness.log { $0.contains { $0.hasPrefix("click:") } }
        #expect(!log.contains { $0.hasSuffix(":b") || $0.contains(":b:") }, "hovering #b sends nothing: \(log)")
    }

    @Test func pointerCaptureWorksWithTheTouchPointer() async throws {
        let harness = await load(Self.recorder + """
        <script>
          var a = document.getElementById('a');
          a.addEventListener('pointerdown', function (e) { try { a.setPointerCapture(e.pointerId); window.__captured = a.hasPointerCapture(e.pointerId); } catch (x) { window.__captured = String(x); } });
          a.addEventListener('pointermove', function (e) { window.__lastMove = e.pointerType + '@' + Math.round(e.clientX); });
        </script>
        """)
        defer { harness.close() }
        await harness.swipe(from: CGPoint(x: 250, y: 100), to: CGPoint(x: 150, y: 300))
        _ = await harness.log { $0.contains("touchend:a") }
        let facts = try await harness.evaluate("return [String(window.__captured), String(window.__lastMove)]") as? [String]
        #expect(facts == ["true", "touch@150"])
    }

    @Test func aTapOnALinkIsAClickThroughAndASwipeOverItIsNot() async throws {
        let link = #"<style>html,body{margin:0}</style><a id="l" href="https://landing.example/" style="display:block;width:320px;height:480px">Go</a>"#
        let harness = await load(link)
        defer { harness.close() }
        harness.controller.noteUserGesture()
        await harness.swipe(from: CGPoint(x: 250, y: 100), to: CGPoint(x: 100, y: 100))
        _ = await Wait.until { harness.host.logs.contains { $0.origin == "Touch" && $0.message.hasPrefix("Swipe left") } }
        #expect(!harness.events.events.contains { if case .click = $0 { true } else { false } }, "\(harness.events.events)")
        #expect(harness.host.monitor.liveEntries.filter { $0.category == .navigation }.isEmpty)
        harness.controller.noteUserGesture()
        await harness.tap(CGPoint(x: 100, y: 100))
        let clicked = await Wait.until { harness.events.events.contains(.click(url: "https://landing.example/", trigger: "navigation")) }
        #expect(clicked, "\(harness.events.events)")
    }

    @Test func theReleaseOfASlowSwipeCountsAsAGesture() async throws {
        let harness = await load("<div id='a' style='width:320px;height:480px'></div>")
        defer { harness.close() }
        let now = Date()
        let point = NSPoint(x: 100, y: 100)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // The press long ago, then a release now: mraid.open in touchend is a click-through.
        harness.controller.observe(try #require(event(.leftMouseDown)), at: now.addingTimeInterval(-5))
        harness.controller.observe(try #require(event(.leftMouseUp)), at: now)
        _ = try await harness.evaluate("mraid.open('https://adv.example/after-swipe')")
        let opened = await Wait.until { harness.events.events.contains(.mraidOpen(url: "https://adv.example/after-swipe")) }
        #expect(opened)
    }
}
