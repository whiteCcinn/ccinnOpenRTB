import Foundation

/// The touch screen of a touch device, for the HTML creative's web view (page world, every frame, document start).
///
/// macOS WebKit has no touch events (`TouchEvent` undefined, `maxTouchPoints` 0, pointer events say `"mouse"`), so a
/// mobile creative takes its desktop path and ignores swipes. This script gives every frame a touch environment and turns
/// the real (trusted) primary mouse button into one finger, sending what a phone sends:
///
/// - press: `pointerover`, `pointerenter`, `pointerdown` (`pointerType: "touch"`), `touchstart`;
/// - drag: `pointermove`, `touchmove` — touch events stay on the element the finger went down on;
/// - release: `pointerup`, `pointerout`, `pointerleave`, `touchend`; a tap (under 10 px of movement) whose touch events
///   were not cancelled then gets `mouseover` / `mouseenter` (on a new element), `mousemove`, `mousedown`, `mouseup` and
///   the real `click`, which stays trusted (links, `window.open`, media) and reports `pointerType: "touch"`. A swipe, or
///   a tap the creative cancelled, gets no click.
/// - The page never sees the mouse itself: no hover, no native mouse or pointer events, no drag-and-drop or text selection
///   while the finger is down. Events the page dispatches itself (untrusted) are left alone.
/// - A drag the creative does not cancel pans the nearest element that scrolls along its main axis (CSS `touch-action`
///   respected); pointer events then end with `pointercancel`, touch events go on uncancelable, as on phones. On release
///   it coasts with the finger's speed and settles where the element's own scroll snapping puts it.
/// - Each gesture is reported once, when it ends (`channel: 'touch'`, see `TouchGesture`).
///
/// `document.open()` erases a window's listeners and WebKit then runs the user scripts again (a "friendly" iframe written
/// by an ad tag): a second run only registers the same listeners again.
enum TouchEmulation {
    static let maxTouchPointsPlaceholder = "__CCINN_MAX_TOUCH_POINTS__"

    static func script(nonce: String, maxTouchPoints: Int) -> String {
        template.replacingOccurrences(of: CreativeScripts.noncePlaceholder, with: JSLiteral.string(nonce))
            .replacingOccurrences(of: maxTouchPointsPlaceholder, with: String(max(1, maxTouchPoints)))
    }

    private static let template = #"""
    (function () {
      'use strict';
      var defineProperty = Object.defineProperty;
      var installed = window.__ccinnTouch;
      if (typeof installed === 'function') { installed(); return; }
      if (installed !== undefined) { return; }

      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ccinn;
      var postMessage = handler ? handler.postMessage.bind(handler) : null;
      var NONCE = __CCINN_NONCE__;
      var MAX_TOUCH_POINTS = __CCINN_MAX_TOUCH_POINTS__;
      function post(message) {
        if (!postMessage) { return; }
        try { defineProperty(message, 'n', { value: NONCE, enumerable: true }); postMessage(message); } catch (e) {}
      }

      // What the page's globals are before it runs: the creative may replace any of them.
      var addListener = EventTarget.prototype.addEventListener;
      var removeListener = EventTarget.prototype.removeEventListener;
      var dispatch = EventTarget.prototype.dispatchEvent;
      var stopImmediate = Event.prototype.stopImmediatePropagation;
      var cancel = Event.prototype.preventDefault;
      var elementAt = Document.prototype.elementFromPoint;
      var nativeCreateEvent = Document.prototype.createEvent;
      var scrollElementTo = Element.prototype.scrollTo;
      var contains = Node.prototype.contains;
      var setProperty = CSSStyleDeclaration.prototype.setProperty;
      var getPropertyValue = CSSStyleDeclaration.prototype.getPropertyValue;
      var getPropertyPriority = CSSStyleDeclaration.prototype.getPropertyPriority;
      var removeProperty = CSSStyleDeclaration.prototype.removeProperty;
      var computed = window.getComputedStyle.bind(window);
      var nativeMatchMedia = window.matchMedia;
      var PointerEventType = window.PointerEvent;
      var MouseEventType = window.MouseEvent;
      var UIEventType = window.UIEvent;
      var WeakMapType = WeakMap;
      var later = window.setTimeout.bind(window);
      var clearLater = window.clearTimeout.bind(window);
      var nextFrame = window.requestAnimationFrame.bind(window);
      var cancelFrame = window.cancelAnimationFrame.bind(window);
      var performanceClock = window.performance;
      var clockNow = performanceClock.now.bind(performanceClock);
      var abs = Math.abs, max = Math.max, min = Math.min, hypot = Math.hypot, power = Math.pow;

      // MARK: The touch environment

      var internals = new WeakMapType();
      var TOUCH_FIELDS = ['identifier', 'clientX', 'clientY', 'pageX', 'pageY', 'screenX', 'screenY', 'radiusX', 'radiusY',
                          'rotationAngle', 'force'];

      class Touch {
        constructor(init) {
          if (!init || typeof init !== 'object' || init.identifier === undefined || !init.target) {
            throw new TypeError("Failed to construct 'Touch': the identifier and target members are required.");
          }
          for (var i = 0; i < TOUCH_FIELDS.length; i++) {
            var name = TOUCH_FIELDS[i];
            defineProperty(this, name, { value: init[name] === undefined ? 0 : Number(init[name]), enumerable: true });
          }
          defineProperty(this, 'target', { value: init.target, enumerable: true });
        }
      }

      var LIST_KEY = {};
      class TouchList {
        constructor(key, touches) {
          if (key !== LIST_KEY) { throw new TypeError('Illegal constructor'); }
          internals.set(this, touches);
          for (var i = 0; i < touches.length; i++) { defineProperty(this, i, { value: touches[i], enumerable: true }); }
        }
        get length() { var touches = internals.get(this); return touches ? touches.length : 0; }
        item(index) {
          var touches = internals.get(this) || [];
          var position = Number(index) >>> 0;
          return position < touches.length ? touches[position] : null;
        }
      }
      defineProperty(TouchList.prototype, Symbol.iterator, {
        value: function () { return (internals.get(this) || []).slice()[Symbol.iterator](); }, configurable: true, writable: true
      });
      function touchList(items) {
        var touches = [];
        if (items) {
          for (var i = 0; i < items.length; i++) { if (items[i] instanceof Touch) { touches.push(items[i]); } }
        }
        return new TouchList(LIST_KEY, touches);
      }

      function touchState(init) {
        init = init || {};
        return { touches: touchList(init.touches), targetTouches: touchList(init.targetTouches), changedTouches: touchList(init.changedTouches),
                 altKey: !!init.altKey, metaKey: !!init.metaKey, ctrlKey: !!init.ctrlKey, shiftKey: !!init.shiftKey };
      }
      class TouchEvent extends UIEventType {
        constructor(type, init) {
          if (arguments.length < 1) { throw new TypeError("Failed to construct 'TouchEvent': 1 argument required, but only 0 present."); }
          super(type, init);
          internals.set(this, touchState(init));
        }
        initTouchEvent(type, bubbles, cancelable, view, detail, screenX, screenY, clientX, clientY, ctrlKey, altKey, shiftKey, metaKey,
                       touches, targetTouches, changedTouches) {
          this.initUIEvent(type, bubbles, cancelable, view, detail);
          internals.set(this, touchState({ touches: touches, targetTouches: targetTouches, changedTouches: changedTouches,
                                           ctrlKey: ctrlKey, altKey: altKey, shiftKey: shiftKey, metaKey: metaKey }));
        }
      }
      ['touches', 'targetTouches', 'changedTouches', 'altKey', 'metaKey', 'ctrlKey', 'shiftKey'].forEach(function (name) {
        defineProperty(TouchEvent.prototype, name, {
          configurable: true, enumerable: true,
          get: function () {
            var state = internals.get(this);
            if (state) { return state[name]; }
            return name.slice(-3) === 'Key' ? false : touchList(null);
          }
        });
      });

      [['Touch', Touch], ['TouchList', TouchList], ['TouchEvent', TouchEvent]].forEach(function (entry) {
        try { defineProperty(window, entry[0], { value: entry[1], writable: true, configurable: true }); } catch (e) {}
      });
      try {
        defineProperty(Document.prototype, 'createEvent', {
          configurable: true, writable: true,
          value: function createEvent(kind) {
            if (/^touchevents?$/i.test(String(kind))) { return new TouchEvent(''); }
            return nativeCreateEvent.apply(this, arguments);
          }
        });
        defineProperty(Document.prototype, 'createTouch', {
          configurable: true, writable: true,
          value: function createTouch(view, target, identifier, pageX, pageY, screenX, screenY) {
            return new Touch({ identifier: identifier, target: target, pageX: pageX, pageY: pageY, screenX: screenX, screenY: screenY,
                               clientX: pageX - window.scrollX, clientY: pageY - window.scrollY });
          }
        });
        defineProperty(Document.prototype, 'createTouchList', {
          configurable: true, writable: true, value: function createTouchList() { return touchList(arguments); }
        });
      } catch (e) {}

      // `ontouchstart` & co.: handler properties on window, documents and elements. Inline `ontouch…` attributes need
      // nothing: WebKit compiles them on the Mac too, it only lacks the properties.
      var TOUCH_TYPES = ['touchstart', 'touchmove', 'touchend', 'touchcancel'];
      var handlers = new WeakMapType();
      function setHandler(target, type, value) {
        var slots = handlers.get(target);
        if (!slots) { slots = {}; handlers.set(target, slots); }
        if (slots[type]) { removeListener.call(target, type, slots[type].listener); slots[type] = null; }
        if (typeof value !== 'function') { return; }
        var listener = function (event) {
          var result = value.call(this, event);
          if (result === false) { cancel.call(event); }
          return result;
        };
        slots[type] = { handler: value, listener: listener };
        addListener.call(target, type, listener);
      }
      function defineHandler(owner, type) {
        try {
          defineProperty(owner, 'on' + type, {
            configurable: true, enumerable: true,
            get: function () { var slots = handlers.get(this); return slots && slots[type] ? slots[type].handler : null; },
            set: function (value) { setHandler(this, type, value); }
          });
        } catch (e) {}
      }
      [window, Document.prototype, HTMLElement.prototype, SVGElement.prototype].forEach(function (owner) {
        TOUCH_TYPES.forEach(function (type) { defineHandler(owner, type); });
      });

      try {
        defineProperty(Navigator.prototype, 'maxTouchPoints', {
          configurable: true, enumerable: true, get: function () { return MAX_TOUCH_POINTS; }
        });
      } catch (e) {}

      // Pointer and hover media features as a phone answers them, by swapping each for its opposite on this Mac (fine
      // pointer, hover): a phone's `(pointer: coarse)` is true where the Mac's `(pointer: fine)` is.
      var PHONE = { 'pointer': 'coarse', 'any-pointer': 'coarse', 'hover': 'none', 'any-hover': 'none' };
      var MAC = { 'pointer': 'fine', 'any-pointer': 'fine', 'hover': 'hover', 'any-hover': 'hover' };
      function asOnThisMac(query) {
        return query.replace(/\(\s*((?:any-)?(?:pointer|hover))\s*(?::\s*([a-z-]+)\s*)?\)/gi, function (all, feature, value) {
          feature = feature.toLowerCase();
          if (value === undefined) { return PHONE[feature] === 'none' ? '(' + feature + ': none)' : all; }
          value = value.toLowerCase();
          if (value === PHONE[feature]) { return '(' + feature + ': ' + MAC[feature] + ')'; }
          if (value === MAC[feature]) { return '(' + feature + ': ' + PHONE[feature] + ')'; }
          return all;
        });
      }
      if (typeof nativeMatchMedia === 'function') {
        try {
          defineProperty(window, 'matchMedia', {
            configurable: true, writable: true,
            value: function matchMedia(query) {
              if (arguments.length < 1) { return nativeMatchMedia.apply(window, arguments); }
              var text = String(query);
              var rewritten = asOnThisMac(text);
              var list = nativeMatchMedia.call(window, rewritten);
              if (rewritten !== text) {
                var shown = nativeMatchMedia.call(window, text).media;
                try { defineProperty(list, 'media', { value: shown, enumerable: true, configurable: true }); } catch (e) {}
              }
              return list;
            }
          });
        } catch (e) {}
      }

      // MARK: The finger

      var SLOP = 10;
      var MOMENTUM_MS = 300;
      var VELOCITY_WINDOW_MS = 100;
      var nextIdentifier = 0;
      var finger = null;
      /// A tap just ended and was not cancelled: WebKit's click for it, sent in the same task, may pass.
      var tapClickPending = false;
      var lastTapTarget = null;
      var settling = null;

      function parentOf(node) {
        var parent = node.parentNode;
        if (parent && parent.nodeType === 11) { return parent.host || null; }
        return parent && parent.nodeType === 1 ? parent : null;
      }
      /// The element and its ancestors, innermost first.
      function chain(target) {
        var nodes = [];
        for (var node = target; node && node.nodeType === 1; node = parentOf(node)) { nodes.push(node); }
        return nodes;
      }
      function modifiers(init, native) {
        init.ctrlKey = !!(native && native.ctrlKey);
        init.shiftKey = !!(native && native.shiftKey);
        init.altKey = !!(native && native.altKey);
        init.metaKey = !!(native && native.metaKey);
        return init;
      }

      var POINTER_BUBBLES = { pointerover: true, pointerdown: true, pointermove: true, pointerup: true, pointercancel: true, pointerout: true };
      function firePointer(type, f, native, target, button, buttons) {
        var bubbles = !!POINTER_BUBBLES[type];
        var init = modifiers({ bubbles: bubbles, cancelable: bubbles && type !== 'pointercancel', composed: true, view: window,
                               clientX: f.x, clientY: f.y, screenX: f.screenX, screenY: f.screenY, button: button, buttons: buttons,
                               pointerId: f.pointerId, pointerType: 'touch', isPrimary: true, width: 1, height: 1,
                               pressure: buttons ? 0.5 : 0 }, native);
        return dispatch.call(target, new PointerEventType(type, init));
      }
      function firePointerEnter(f, native) {
        firePointer('pointerover', f, native, f.target, -1, 0);
        chain(f.target).reverse().forEach(function (node) { firePointer('pointerenter', f, native, node, -1, 0); });
      }
      function firePointerExit(f, native, target) {
        firePointer('pointerout', f, native, target, -1, 0);
        chain(target).forEach(function (node) { firePointer('pointerleave', f, native, node, -1, 0); });
      }

      function fireTouch(type, f, native, cancelable) {
        var touch = new Touch({ identifier: f.id, target: f.target, clientX: f.x, clientY: f.y, pageX: f.x + window.scrollX,
                                pageY: f.y + window.scrollY, screenX: f.screenX, screenY: f.screenY, radiusX: 1, radiusY: 1, force: 1 });
        var active = type === 'touchend' || type === 'touchcancel' ? [] : [touch];
        var init = modifiers({ bubbles: true, cancelable: cancelable, composed: true, view: window, touches: active, targetTouches: active,
                               changedTouches: [touch] }, native);
        return dispatch.call(f.target, new TouchEvent(type, init));
      }

      function fireMouse(type, target, f, native, button, buttons, detail, related) {
        var bubbles = type !== 'mouseenter' && type !== 'mouseleave';
        var init = modifiers({ bubbles: bubbles, cancelable: bubbles, composed: true, view: window, clientX: f.x, clientY: f.y,
                               screenX: f.screenX, screenY: f.screenY, button: button, buttons: buttons, detail: detail,
                               relatedTarget: related || null }, native);
        dispatch.call(target, new MouseEventType(type, init));
      }
      /// A phone's mouse events after a tap, at the element under the finger.
      function compatibilityMouseEvents(f, native) {
        var target = elementAt.call(document, f.x, f.y) || f.target;
        if (target !== lastTapTarget) {
          var previous = lastTapTarget && lastTapTarget.isConnected ? lastTapTarget : null;
          if (previous) {
            fireMouse('mouseout', previous, f, native, 0, 0, 0, target);
            chain(previous).forEach(function (node) {
              if (!contains.call(node, target)) { fireMouse('mouseleave', node, f, native, 0, 0, 0, target); }
            });
          }
          fireMouse('mouseover', target, f, native, 0, 0, 0, previous);
          chain(target).reverse().forEach(function (node) {
            if (!previous || !contains.call(node, previous)) { fireMouse('mouseenter', node, f, native, 0, 0, 0, previous); }
          });
          lastTapTarget = target;
        }
        fireMouse('mousemove', target, f, native, 0, 0, 0, null);
        fireMouse('mousedown', target, f, native, 0, 1, 1, null);
        fireMouse('mouseup', target, f, native, 0, 0, 1, null);
      }

      // MARK: Panning

      function allows(touchAction, axis) {
        if (typeof touchAction !== 'string' || touchAction === '' || touchAction === 'auto' || touchAction === 'manipulation') { return true; }
        var parts = touchAction.split(/\s+/);
        var wanted = axis === 'x' ? ['pan-x', 'pan-left', 'pan-right'] : ['pan-y', 'pan-up', 'pan-down'];
        return parts.some(function (part) { return wanted.indexOf(part) >= 0; });
      }
      function extent(element, axis) {
        return axis === 'x' ? element.scrollWidth - element.clientWidth : element.scrollHeight - element.clientHeight;
      }
      function viewportScrolls(axis) {
        var key = axis === 'x' ? 'overflowX' : 'overflowY';
        var value = computed(document.documentElement)[key];
        if (value === 'visible' && document.body) { value = computed(document.body)[key]; }
        return value !== 'hidden' && value !== 'clip';
      }
      function panOf(element, axis) {
        var rtl = axis === 'x' && computed(element).direction === 'rtl';
        return { element: element, axis: axis, rtl: rtl, origin: axis === 'x' ? element.scrollLeft : element.scrollTop, snap: null };
      }
      /// The nearest element the finger scrolls along `axis`, or null (touch-action forbids it, nothing scrolls).
      function scrollerFor(target, axis) {
        var root = document.scrollingElement || document.documentElement;
        for (var node = target; node; node = parentOf(node)) {
          var style = computed(node);
          if (!allows(style.touchAction, axis)) { return null; }
          if (node === root || node === document.body || node === document.documentElement) { continue; }
          var overflow = axis === 'x' ? style.overflowX : style.overflowY;
          if ((overflow === 'auto' || overflow === 'scroll') && extent(node, axis) > 1) { return panOf(node, axis); }
        }
        return root && viewportScrolls(axis) && extent(root, axis) > 1 ? panOf(root, axis) : null;
      }
      function position(pan) { return pan.axis === 'x' ? pan.element.scrollLeft : pan.element.scrollTop; }
      function place(pan, value) {
        var limit = max(0, extent(pan.element, pan.axis));
        value = pan.rtl ? min(0, max(-limit, value)) : min(limit, max(0, value));
        scrollElementTo.call(pan.element, pan.axis === 'x' ? { left: value, behavior: 'instant' } : { top: value, behavior: 'instant' });
      }
      /// Scroll snapping would pull the content back at every move: it is off while the finger pans, as a phone does it.
      function suspendSnap(pan) {
        var style = pan.element.style;
        if (!style || pan.snap) { return; }
        pan.snap = [getPropertyValue.call(style, 'scroll-snap-type'), getPropertyPriority.call(style, 'scroll-snap-type')];
        setProperty.call(style, 'scroll-snap-type', 'none', 'important');
      }
      function restoreSnap(pan) {
        if (!pan.snap) { return; }
        var style = pan.element.style;
        if (pan.snap[0]) { setProperty.call(style, 'scroll-snap-type', pan.snap[0], pan.snap[1]); } else { removeProperty.call(style, 'scroll-snap-type'); }
        pan.snap = null;
      }
      function startPan(f, native) {
        var axis = abs(f.x - f.startX) >= abs(f.y - f.startY) ? 'x' : 'y';
        f.pan = scrollerFor(f.target, axis) || false;
        if (!f.pan) { return; }
        suspendSnap(f.pan);
        // The browser takes the gesture over: pointer events end; touch events go on, no longer cancelable.
        var target = f.capture || f.target;
        firePointer('pointercancel', f, native, target, -1, 0);
        firePointerExit(f, native, target);
        f.pointerGone = true;
      }
      function followFinger(f) {
        var pan = f.pan;
        var before = position(pan);
        place(pan, pan.origin - (pan.axis === 'x' ? f.x - f.startX : f.y - f.startY));
        if (position(pan) !== before) { f.scrolled = true; }
      }
      /// The finger's speed along `axis` over its last moves (px/ms); 0 when it had stopped before lifting.
      function velocity(f, axis) {
        var samples = f.samples;
        var last = samples[samples.length - 1];
        if (!last || clockNow() - last[0] > VELOCITY_WINDOW_MS) { return 0; }
        var first = last;
        for (var i = 0; i < samples.length; i++) {
          if (last[0] - samples[i][0] <= VELOCITY_WINDOW_MS) { first = samples[i]; break; }
        }
        var elapsed = last[0] - first[0];
        if (elapsed <= 0) { return 0; }
        return (axis === 'x' ? last[1] - first[1] : last[2] - first[2]) / elapsed;
      }
      /// After the finger lifts: coast with its speed (at most a page) and settle where the element's snapping puts it.
      function settle(pan, speed) {
        var from = position(pan);
        var page = pan.axis === 'x' ? pan.element.clientWidth : pan.element.clientHeight;
        var thrown = max(-page, min(page, speed * MOMENTUM_MS));
        // Ask WebKit where its snapping lands, then put the content back: no frame is drawn in between.
        restoreSnap(pan);
        place(pan, from - thrown);
        var to = position(pan);
        suspendSnap(pan);
        place(pan, from);
        if (abs(to - from) < 1) {
          restoreSnap(pan);
          return;
        }
        var started = clockNow();
        var duration = min(500, max(200, abs(to - from) * 1.5));
        var step = function () {
          var t = min(1, (clockNow() - started) / duration);
          place(pan, from + (to - from) * (1 - power(1 - t, 3)));
          if (t < 1) {
            settling.stop = soon(step);
          } else {
            settling = null;
            restoreSnap(pan);
          }
        };
        settling = { pan: pan, stop: soon(step) };
      }
      function stopSettling() {
        if (!settling) { return; }
        settling.stop();
        restoreSnap(settling.pan);
        settling = null;
      }
      /// Runs `step` at the next frame, or after 34 ms when the page is hidden and WebKit holds frames back (a minimized
      /// window): the content never stays with its snapping suspended. Returns a function that cancels it.
      function soon(step) {
        var done = false, frame = 0, timer = 0;
        var stop = function () { done = true; cancelFrame(frame); clearLater(timer); };
        var run = function () { if (done) { return; } stop(); step(); };
        frame = nextFrame(run);
        timer = later(run, 34);
        return stop;
      }

      // MARK: Gestures

      /// The element under the finger, inside open shadow roots too (at the window the event's target is their host).
      function innermostTarget(native) {
        var path = typeof native.composedPath === 'function' ? native.composedPath() : null;
        var first = path && path[0];
        return first && first.nodeType === 1 ? first : native.target;
      }

      function begin(native) {
        if (finger) { end(native, 'cancel'); }
        stopSettling();
        var now = clockNow();
        var f = finger = {
          id: ++nextIdentifier, pointerId: native.pointerId, target: innermostTarget(native), startX: native.clientX, startY: native.clientY,
          x: native.clientX, y: native.clientY, screenX: native.screenX, screenY: native.screenY, startTime: now,
          samples: [[now, native.clientX, native.clientY]], moved: false, cancelled: false, quiet: false, pan: null, scrolled: false,
          pointerGone: false, capture: null
        };
        firePointerEnter(f, native);
        if (!firePointer('pointerdown', f, native, f.target, 0, 1)) { f.quiet = true; }
        if (!fireTouch('touchstart', f, native, true)) { f.cancelled = true; }
      }

      function move(native) {
        var f = finger;
        if (native.clientX === f.x && native.clientY === f.y) { return; }
        var now = clockNow();
        f.x = native.clientX;
        f.y = native.clientY;
        f.screenX = native.screenX;
        f.screenY = native.screenY;
        f.samples.push([now, f.x, f.y]);
        while (f.samples.length > 2 && now - f.samples[0][0] > VELOCITY_WINDOW_MS) { f.samples.shift(); }
        if (!f.moved && hypot(f.x - f.startX, f.y - f.startY) >= SLOP) { f.moved = true; }
        if (!f.pointerGone) { firePointer('pointermove', f, native, f.capture || f.target, -1, 1); }
        var cancelable = !f.pan;
        if (!fireTouch('touchmove', f, native, cancelable) && cancelable) { f.cancelled = true; }
        if (!f.moved || f.cancelled) { return; }
        if (f.pan === null) { startPan(f, native); }
        if (f.pan) { followFinger(f); }
      }

      function end(native, how) {
        var f = finger;
        finger = null;
        if (!f) { return; }
        var released = how === 'release';
        var target = f.capture || f.target;
        if (!f.pointerGone) {
          firePointer(released ? 'pointerup' : 'pointercancel', f, native, target, released ? 0 : -1, 0);
          firePointerExit(f, native, target);
        }
        var tap = released && !f.moved;
        var allowed = fireTouch(released ? 'touchend' : 'touchcancel', f, native, released && !f.pan);
        if (tap && !allowed) { f.cancelled = true; }
        if (f.pan) { settle(f.pan, released ? velocity(f, f.pan.axis) : 0); }
        if (tap && !f.cancelled) {
          if (!f.quiet) { compatibilityMouseEvents(f, native); }
          // WebKit sends the click (and a dblclick) in the same task as the release.
          tapClickPending = true;
          later(function () { tapClickPending = false; }, 0);
        }
        post({ channel: 'touch', kind: tap ? 'tap' : (released ? 'swipe' : 'cancel'), x: f.startX, y: f.startY, dx: f.x - f.startX,
               dy: f.y - f.startY, duration: max(0, clockNow() - f.startTime), cancelled: f.cancelled, scrolled: f.scrolled });
      }

      function editable(target) {
        return !!target && (target.isContentEditable || /^(input|textarea|select)$/i.test(target.nodeName || ''));
      }
      function patchPointerType(event) {
        if (event.pointerType !== 'mouse') { return; }
        try { defineProperty(event, 'pointerType', { value: 'touch', configurable: true }); } catch (e) {}
      }

      var HIDDEN = { pointerover: true, pointerenter: true, pointerout: true, pointerleave: true, mouseover: true, mouseenter: true,
                     mouseout: true, mouseleave: true, mousemove: true, mousedown: true, mouseup: true, auxclick: true };
      function onNativeEvent(event) {
        if (!event.isTrusted) { return; }
        var type = event.type;
        if (type === 'pointerdown' || type === 'pointermove' || type === 'pointerup' || type === 'pointercancel') {
          stopImmediate.call(event);
          if (event.pointerType !== 'mouse') { return; }
          if (type === 'pointerdown') {
            if (event.button === 0) { begin(event); }
            return;
          }
          if (!finger || event.pointerId !== finger.pointerId) { return; }
          if (type === 'pointercancel') { return end(event, 'cancel'); }
          if (type === 'pointerup') {
            if (event.button !== 0) { return; }
            move(event);
            return end(event, 'release');
          }
          // Not `buttons`: WebKit reads it from the Mac's mouse state, not from the event. The release always comes (AppKit
          // sends it to the view that got the press); a new press or the window losing focus ends a finger too.
          return move(event);
        }
        if (HIDDEN[type]) { return stopImmediate.call(event); }
        if (type === 'click' || type === 'dblclick') {
          // A mouse click only follows a tap that was not cancelled; a keyboard's (Return on a focused link) passes.
          var fromMouse = event.pointerType === 'mouse' || event.detail > 0;
          if (fromMouse && !tapClickPending) {
            stopImmediate.call(event);
            cancel.call(event);
            return;
          }
          return patchPointerType(event);
        }
        if (type === 'gotpointercapture' || type === 'lostpointercapture') {
          if (finger && event.pointerId === finger.pointerId) { finger.capture = type === 'gotpointercapture' ? event.target : null; }
          return patchPointerType(event);
        }
        if (type === 'dragstart' || (type === 'selectstart' && finger && !editable(event.target))) {
          stopImmediate.call(event);
          cancel.call(event);
        }
      }
      function onBlur(event) {
        if (event.isTrusted && event.target === window && finger) { end(null, 'cancel'); }
      }

      var NATIVE_TYPES = ['pointerover', 'pointerenter', 'pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'pointerout',
                          'pointerleave', 'gotpointercapture', 'lostpointercapture', 'mouseover', 'mouseenter', 'mousemove', 'mousedown',
                          'mouseup', 'mouseout', 'mouseleave', 'click', 'dblclick', 'auxclick', 'dragstart', 'selectstart'];
      /// Registers the listeners (again after `document.open()` erased them; the same functions are never added twice).
      function listen() {
        for (var i = 0; i < NATIVE_TYPES.length; i++) { addListener.call(window, NATIVE_TYPES[i], onNativeEvent, true); }
        addListener.call(window, 'blur', onBlur, true);
      }
      try { defineProperty(window, '__ccinnTouch', { value: listen }); } catch (e) { return; }
      listen();
    })();
    """#
}
