import Foundation

/// The scripts injected into a creative's web view at document start (design D9, D10).
///
/// - `instrumentation` (page world, every frame): reports each request the creative makes or tries to make — `fetch`,
///   XHR, `sendBeacon`, WebSocket, element `src` / `href` (setters, `setAttribute`, parsed markup via MutationObserver),
///   and resource timing for loads no hook sees — plus `console.*`, uncaught errors and `window.open` (never opens).
///   The originals are captured before the creative runs.
/// - `mraid` (page world, main frame): the MRAID 3.0 container. Every call is posted for the log (getters throttled to
///   one line per second per name); state changes and commands are posted for the container to act on.
/// - `gesture` (isolated world): trusted pointer / key events, so the page cannot fake a user gesture.
enum CreativeScripts {
    static let isolatedWorldName = "ccinn-isolated"

    static let instrumentation = #"""
    (function () {
      'use strict';
      if (window.__ccinnInstrumented) { return; }
      try { Object.defineProperty(window, '__ccinnInstrumented', { value: true }); } catch (e) { return; }
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ccinn;
      if (!handler) { return; }
      var postMessage = handler.postMessage.bind(handler);
      var stringify = JSON.stringify;
      function post(message) { try { postMessage(message); } catch (e) {} }

      var MAX_REPORTS = 500;
      var MAX_CONSOLE = 200;
      var reports = 0;
      var consoleLines = 0;
      var counter = 0;
      var frame = Math.random().toString(36).slice(2, 10);
      var pendingByURL = new Map();

      function absolute(url) {
        if (url === undefined || url === null || url === '') { return null; }
        try { return new URL(String(url), document.baseURI || location.href).href; } catch (e) { return null; }
      }
      function networked(url) { return /^(https?|wss?):/i.test(url) && !/\/mraid\.js([?#]|$)/i.test(url); }
      function admit() {
        if (reports < MAX_REPORTS) { reports++; return true; }
        if (reports === MAX_REPORTS) { reports++; post({ channel: 'net', phase: 'overflow' }); }
        return false;
      }
      function start(url, kind, awaitsTiming) {
        var href = absolute(url);
        if (!href || !networked(href) || !admit()) { return null; }
        var rid = frame + ':' + (++counter);
        post({ channel: 'net', phase: 'start', rid: rid, url: href.slice(0, 8192), kind: kind });
        if (awaitsTiming) {
          var list = pendingByURL.get(href) || [];
          list.push(rid);
          pendingByURL.set(href, list);
        }
        return rid;
      }
      function end(rid, status, bytes, error) {
        if (!rid) { return; }
        post({ channel: 'net', phase: 'end', rid: rid,
               status: typeof status === 'number' && isFinite(status) ? status : null,
               bytes: typeof bytes === 'number' && isFinite(bytes) && bytes > 0 ? bytes : null,
               error: error ? String(error).slice(0, 500) : null });
      }
      function forget(rid) {
        var forgotten = null;
        pendingByURL.forEach(function (list, url) {
          var index = list.indexOf(rid);
          if (index >= 0) { list.splice(index, 1); forgotten = url; if (!list.length) { pendingByURL.delete(url); } }
        });
        return forgotten;
      }
      // Loads an element hook ended (load / error event) before resource timing reported them: that later timing entry is
      // the same request, not one the hooks missed.
      var settledByURL = new Map();
      function settle(rid) {
        var url = forget(rid);
        if (url) { settledByURL.set(url, (settledByURL.get(url) || 0) + 1); }
      }
      function consumeSettled(url) {
        var count = settledByURL.get(url);
        if (!count) { return false; }
        if (count > 1) { settledByURL.set(url, count - 1); } else { settledByURL.delete(url); }
        return true;
      }

      var nativeFetch = window.fetch;
      if (typeof nativeFetch === 'function') {
        window.fetch = function (input) {
          var url = (input && typeof input === 'object' && 'url' in input) ? input.url : input;
          var rid = start(url, 'fetch', false);
          var promise;
          try { promise = nativeFetch.apply(this, arguments); } catch (error) { end(rid, 0, null, error && error.message || 'fetch failed'); throw error; }
          promise.then(function (response) { end(rid, response.status, null, null); },
                       function (error) { end(rid, 0, null, (error && error.message) || 'fetch failed'); });
          return promise;
        };
      }

      if (window.XMLHttpRequest) {
        var xhrOpen = XMLHttpRequest.prototype.open;
        var xhrSend = XMLHttpRequest.prototype.send;
        var xhrURL = new WeakMap();
        XMLHttpRequest.prototype.open = function (method, url) { xhrURL.set(this, url); return xhrOpen.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function () {
          var xhr = this;
          var rid = start(xhrURL.get(xhr), 'xhr', false);
          if (rid) { xhr.addEventListener('loadend', function () { end(rid, xhr.status, null, xhr.status ? null : 'network error'); }); }
          return xhrSend.apply(this, arguments);
        };
      }

      if (navigator.sendBeacon) {
        var nativeBeacon = navigator.sendBeacon;
        navigator.sendBeacon = function (url) {
          var rid = start(url, 'beacon', true);
          var queued = nativeBeacon.apply(navigator, arguments);
          if (!queued && rid) { forget(rid); end(rid, 0, null, 'beacon not queued'); }
          return queued;
        };
      }

      var NativeWebSocket = window.WebSocket;
      if (typeof NativeWebSocket === 'function') {
        var WrappedWebSocket = function (url, protocols) {
          var rid = start(url, 'websocket', false);
          var socket = arguments.length > 1 ? new NativeWebSocket(url, protocols) : new NativeWebSocket(url);
          if (rid) {
            socket.addEventListener('open', function () { end(rid, 101, null, null); });
            socket.addEventListener('error', function () { end(rid, 0, null, 'websocket error'); });
          }
          return socket;
        };
        WrappedWebSocket.prototype = NativeWebSocket.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (name) {
          try { Object.defineProperty(WrappedWebSocket, name, { value: NativeWebSocket[name] }); } catch (e) {}
        });
        window.WebSocket = WrappedWebSocket;
      }

      var ATTRIBUTES = { IMG: ['src'], SCRIPT: ['src'], IFRAME: ['src'], FRAME: ['src'], LINK: ['href'], SOURCE: ['src'],
                         VIDEO: ['src', 'poster'], AUDIO: ['src'], EMBED: ['src'], OBJECT: ['data'], INPUT: ['src'], TRACK: ['src'] };
      var SELECTOR = 'img,script,iframe,frame,link,source,video,audio,embed,object,input,track';
      var noted = new WeakMap();
      var elementRequest = new WeakMap();
      function elementDone(element, ok) {
        var rid = elementRequest.get(element);
        if (!rid) { return; }
        elementRequest.delete(element);
        settle(rid);
        end(rid, ok ? 200 : 0, null, ok ? null : 'load error');
      }
      function noteElement(element, attribute) {
        if (!element || !element.tagName || !attribute) { return; }
        var tag = String(element.tagName).toUpperCase();
        var names = ATTRIBUTES[tag];
        if (!names || names.indexOf(attribute) < 0) { return; }
        if (tag === 'LINK' && !/(^|\s)(stylesheet|preload|prefetch|icon|modulepreload|manifest)(\s|$)/i.test(element.getAttribute('rel') || '')) { return; }
        var value = element.getAttribute(attribute);
        if (!value) { return; }
        var seen = noted.get(element) || {};
        if (seen[attribute] === value) { return; }
        seen[attribute] = value;
        noted.set(element, seen);
        var rid = start(value, tag.toLowerCase(), attribute !== 'poster');
        if (!rid || attribute === 'poster') { return; }
        elementRequest.set(element, rid);
        element.addEventListener('load', function () { elementDone(element, true); });
        element.addEventListener('loadedmetadata', function () { elementDone(element, true); });
        element.addEventListener('error', function () { elementDone(element, false); });
        if (tag === 'IMG' && element.complete) { elementDone(element, element.naturalWidth > 0); }
      }
      function noteAll(element) {
        var names = ATTRIBUTES[String(element.tagName || '').toUpperCase()];
        if (names) { for (var i = 0; i < names.length; i++) { noteElement(element, names[i]); } }
      }
      function scan(node) {
        if (!node || node.nodeType !== 1) { return; }
        noteAll(node);
        if (node.querySelectorAll) {
          var all = node.querySelectorAll(SELECTOR);
          for (var i = 0; i < all.length; i++) { noteAll(all[i]); }
        }
      }
      function hook(proto, property, attribute) {
        if (!proto) { return; }
        var descriptor = Object.getOwnPropertyDescriptor(proto, property);
        if (!descriptor || typeof descriptor.set !== 'function') { return; }
        Object.defineProperty(proto, property, {
          configurable: true, enumerable: descriptor.enumerable, get: descriptor.get,
          set: function (value) { descriptor.set.call(this, value); noteElement(this, attribute); }
        });
      }
      hook(window.HTMLImageElement && HTMLImageElement.prototype, 'src', 'src');
      hook(window.HTMLScriptElement && HTMLScriptElement.prototype, 'src', 'src');
      hook(window.HTMLIFrameElement && HTMLIFrameElement.prototype, 'src', 'src');
      hook(window.HTMLLinkElement && HTMLLinkElement.prototype, 'href', 'href');
      hook(window.HTMLSourceElement && HTMLSourceElement.prototype, 'src', 'src');
      hook(window.HTMLMediaElement && HTMLMediaElement.prototype, 'src', 'src');
      hook(window.HTMLVideoElement && HTMLVideoElement.prototype, 'poster', 'poster');
      hook(window.HTMLEmbedElement && HTMLEmbedElement.prototype, 'src', 'src');
      hook(window.HTMLObjectElement && HTMLObjectElement.prototype, 'data', 'data');
      hook(window.HTMLInputElement && HTMLInputElement.prototype, 'src', 'src');
      var nativeSetAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name) {
        var result = nativeSetAttribute.apply(this, arguments);
        noteElement(this, String(name).toLowerCase());
        return result;
      };
      try {
        new MutationObserver(function (mutations) {
          for (var i = 0; i < mutations.length; i++) {
            var mutation = mutations[i];
            if (mutation.type === 'attributes') { noteElement(mutation.target, mutation.attributeName); }
            else { for (var j = 0; j < mutation.addedNodes.length; j++) { scan(mutation.addedNodes[j]); } }
          }
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'href', 'data', 'poster', 'rel'] });
      } catch (e) {}

      if (window.PerformanceObserver) {
        try {
          new PerformanceObserver(function (list) {
            var entries = list.getEntries();
            for (var i = 0; i < entries.length; i++) {
              var entry = entries[i];
              var kind = entry.initiatorType || 'resource';
              if (kind === 'fetch' || kind === 'xmlhttprequest' || !networked(entry.name)) { continue; }
              var status = typeof entry.responseStatus === 'number' && entry.responseStatus > 0 ? entry.responseStatus : null;
              var bytes = entry.transferSize > 0 ? entry.transferSize : (entry.encodedBodySize > 0 ? entry.encodedBodySize : null);
              var waiting = pendingByURL.get(entry.name);
              if (waiting && waiting.length) {
                var rid = waiting.shift();
                if (!waiting.length) { pendingByURL.delete(entry.name); }
                end(rid, status || 200, bytes, null);
                continue;
              }
              if (consumeSettled(entry.name)) { continue; }
              if (!admit()) { continue; }
              post({ channel: 'net', phase: 'timing', url: entry.name.slice(0, 8192), kind: kind, status: status, bytes: bytes });
            }
          }).observe({ type: 'resource', buffered: true });
        } catch (e) {}
      }

      function describe(value) {
        if (typeof value === 'string') { return value; }
        if (value instanceof Error) { return value.name + ': ' + value.message; }
        try { var text = stringify(value); return text === undefined ? String(value) : text; } catch (e) { return String(value); }
      }
      function consoleLine(level, text) {
        if (consoleLines >= MAX_CONSOLE) { return; }
        consoleLines++;
        if (consoleLines === MAX_CONSOLE) { text = text + ' (further console output is not recorded)'; }
        post({ channel: 'console', level: level, message: String(text).slice(0, 2000) });
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        if (typeof original !== 'function') { return; }
        console[level] = function () {
          try { consoleLine(level, Array.prototype.map.call(arguments, describe).join(' ')); } catch (e) {}
          return original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (event) {
        if (event && event.message) { consoleLine('error', event.message + (event.filename ? ' (' + event.filename + ':' + event.lineno + ')' : '')); }
      });
      window.addEventListener('unhandledrejection', function (event) { consoleLine('error', 'Unhandled rejection: ' + describe(event && event.reason)); });

      var openWindow = function (url) {
        var href = absolute(url);
        post({ channel: 'open', url: href || String(url || '').slice(0, 8192) });
        return null;
      };
      try { Object.defineProperty(window, 'open', { value: openWindow, writable: true, configurable: true }); } catch (e) { window.open = openWindow; }
    })();
    """#

    static let gesture = #"""
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ccinnGesture;
      if (!handler) { return; }
      var last = 0;
      function gesture(event) {
        if (!event.isTrusted) { return; }
        var now = Date.now();
        if (now - last < 200) { return; }
        last = now;
        try { handler.postMessage({ channel: 'gesture' }); } catch (e) {}
      }
      ['pointerdown', 'mousedown', 'touchstart', 'keydown'].forEach(function (type) {
        window.addEventListener(type, gesture, { capture: true, passive: true });
      });
    })();
    """#

    /// Simulated-mode sandbox only (every frame): content rules cannot stop WebRTC (ICE / STUN is not HTTP), so the
    /// constructors throw, and the attempt is recorded as a blocked request. Best effort: a script that grabs a constructor
    /// from a frame WebKit injects no script into could still reach it.
    static let blockWebRTC = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ccinn;
      var postMessage = handler ? handler.postMessage.bind(handler) : null;
      var counter = 0;
      var frame = 'rtc' + Math.random().toString(36).slice(2, 8);
      function record(configuration) {
        if (!postMessage || counter >= 20) { return; }
        var url = 'webrtc:';
        try {
          var servers = configuration && configuration.iceServers;
          var first = servers && servers[0] && servers[0].urls;
          if (first) { url = String(Array.isArray(first) ? first[0] : first).slice(0, 2000); }
        } catch (e) {}
        try { postMessage({ channel: 'net', phase: 'start', rid: frame + ':' + (++counter), url: url, kind: 'webrtc' }); } catch (e) {}
      }
      ['RTCPeerConnection', 'webkitRTCPeerConnection'].forEach(function (name) {
        if (!(name in window)) { return; }
        var blocked = function (configuration) {
          record(configuration);
          throw new DOMException('WebRTC is disabled by the Simulated-mode sandbox', 'NotAllowedError');
        };
        try { Object.defineProperty(window, name, { value: blocked, writable: false, configurable: false }); } catch (e) {}
      });
    })();
    """#

    static let noScroll = #"""
    (function () {
      var style = document.createElement('style');
      style.textContent = 'html,body{overflow:hidden !important;}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """#

    /// The MRAID 3.0 container for one load. `controller` is the (per-load, unguessable) global name of the object the
    /// container drives: `ready()`, `update({exposure})`, `containerClose()`.
    static func mraid(environment: MRAIDEnvironment, controller: String) -> String {
        // The controller placeholder goes first: the environment carries bid data (the bundle), which must never be
        // scanned for placeholders after it is inserted.
        mraidTemplate
            .replacingOccurrences(of: "__CCINN_CONTROLLER__", with: JSLiteral.string(controller))
            .replacingOccurrences(of: "__CCINN_ENV__", with: JSLiteral.json(environment))
    }

    private static let mraidTemplate = #"""
    (function () {
      'use strict';
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ccinn;
      if (!handler || window.mraid) { return; }
      var postMessage = handler.postMessage.bind(handler);
      var schedule = window.setTimeout.bind(window);
      var parse = JSON.parse;
      var stringify = JSON.stringify;
      function post(message) { try { postMessage(message); } catch (e) {} }

      var env = __CCINN_ENV__;
      var VERSION = '3.0';
      var EVENTS = ['ready', 'error', 'stateChange', 'viewableChange', 'exposureChange', 'sizeChange', 'audioVolumeChange'];
      var state = 'loading';
      var listeners = {};
      var customClose = false;
      var exposure = env.exposedPercentage;
      var position = copy(env.defaultPosition);
      var expandProperties = { width: env.maxSize.width, height: env.maxSize.height, useCustomClose: false, isModal: true };
      var resizeProperties = null;
      var orientationProperties = { allowOrientationChange: true, forceOrientation: 'none' };
      var throttled = {};

      function copy(value) { return value === undefined || value === null ? value : parse(stringify(value)); }
      function isNumber(value) { return typeof value === 'number' && isFinite(value); }
      function absolute(url) {
        if (url === undefined || url === null || String(url).trim() === '') { return null; }
        try { return new URL(String(url), document.baseURI || location.href).href; } catch (e) { return null; }
      }
      function describe(value) {
        if (typeof value === 'function') { return 'function'; }
        try { var text = stringify(value); if (text === undefined) { return String(value); } return text.length > 300 ? text.slice(0, 300) + '…' : text; }
        catch (e) { return String(value); }
      }
      function call(name, args, result, extra) {
        var text = 'mraid.' + name + '(' + args.map(describe).join(', ') + ')' + (result === undefined ? '' : ' → ' + describe(result));
        post({ channel: 'mraid', name: name, description: text, args: extra || {} });
      }
      function getter(name, result, key) {
        var slot = key || name;
        var entry = throttled[slot];
        if (entry) { entry.count++; return result; }
        throttled[slot] = { count: 0 };
        call(name, key && key !== name ? [key.slice(name.length + 1)] : [], result);
        schedule(function () {
          var done = throttled[slot];
          delete throttled[slot];
          if (done && done.count > 0) {
            post({ channel: 'mraid', name: name, args: {},
                   description: 'mraid.' + name + '() called ' + done.count + ' more time' + (done.count === 1 ? '' : 's') + ' within 1 s' });
          }
        }, 1000);
        return result;
      }
      function fire(event) {
        var args = Array.prototype.slice.call(arguments, 1);
        var list = (listeners[event] || []).slice();
        for (var i = 0; i < list.length; i++) {
          try { list[i].apply(window, args); }
          catch (e) { post({ channel: 'console', level: 'error', message: 'MRAID ' + event + ' listener threw: ' + (e && e.message ? e.message : String(e)) }); }
        }
      }
      function error(message, action) {
        post({ channel: 'mraidError', message: message, action: action });
        fire('error', message, action);
      }
      function announce() {
        post({ channel: 'state', state: state, customClose: customClose, width: position.width, height: position.height });
      }
      function setState(next) {
        if (state === next) { return; }
        state = next;
        announce();
        fire('stateChange', next);
      }
      function setPosition(next) {
        var resized = next.width !== position.width || next.height !== position.height;
        position = next;
        if (resized) { fire('sizeChange', next.width, next.height); }
      }
      function fireExposure() {
        var rect = exposure > 0 ? { x: 0, y: 0, width: position.width, height: Math.round(position.height * exposure) / 100 } : null;
        fire('exposureChange', exposure, rect, null);
      }
      function backToDefault() {
        setPosition(copy(env.defaultPosition));
        setState('default');
      }

      var mraid = {
        getVersion: function () { return getter('getVersion', VERSION); },
        getState: function () { return getter('getState', state); },
        getPlacementType: function () { return getter('getPlacementType', env.placementType); },
        isViewable: function () { return getter('isViewable', exposure > 0); },
        getExposure: function () { return getter('getExposure', exposure); },
        getMaxSize: function () { return getter('getMaxSize', copy(env.maxSize)); },
        getScreenSize: function () { return getter('getScreenSize', copy(env.screenSize)); },
        getCurrentPosition: function () { return getter('getCurrentPosition', copy(position)); },
        getDefaultPosition: function () { return getter('getDefaultPosition', copy(env.defaultPosition)); },
        getLocation: function () { return getter('getLocation', -1); },
        getCurrentAppOrientation: function () { return getter('getCurrentAppOrientation', { orientation: env.orientation, locked: false }); },
        supports: function (feature) { return getter('supports', env.supports[feature] === true, 'supports:' + String(feature)); },
        addEventListener: function (event, listener) {
          call('addEventListener', [event]);
          if (EVENTS.indexOf(event) < 0) { error('Unknown event: ' + event, 'addEventListener'); return; }
          if (typeof listener !== 'function') { error('The listener is not a function', 'addEventListener'); return; }
          var list = listeners[event] || (listeners[event] = []);
          if (list.indexOf(listener) < 0) { list.push(listener); }
        },
        removeEventListener: function (event, listener) {
          call('removeEventListener', [event]);
          if (!listeners[event]) { error('No listener registered for ' + event, 'removeEventListener'); return; }
          if (listener === undefined) { delete listeners[event]; return; }
          var index = listeners[event].indexOf(listener);
          if (index < 0) { error('This listener is not registered for ' + event, 'removeEventListener'); return; }
          listeners[event].splice(index, 1);
        },
        open: function (url) {
          var href = absolute(url);
          if (!href) { call('open', [url]); error('open() needs a URL', 'open'); return; }
          call('open', [href], undefined, { url: href });
        },
        close: function () {
          call('close', []);
          if (state === 'expanded' || state === 'resized') { backToDefault(); }
          else if (state === 'default') { setState('hidden'); }
          else { error('close() is not allowed in the ' + state + ' state', 'close'); }
        },
        unload: function () { call('unload', []); setState('hidden'); },
        expand: function (url) {
          var href = url === undefined ? null : absolute(url);
          call('expand', url === undefined ? [] : [href || url], undefined, { url: href || '' });
          if (env.placementType === 'interstitial') { error('expand() is not allowed for interstitials', 'expand'); return; }
          if (state !== 'default' && state !== 'resized') { error('expand() is not allowed in the ' + state + ' state', 'expand'); return; }
          setPosition({ x: 0, y: 0, width: Math.min(expandProperties.width, env.maxSize.width), height: Math.min(expandProperties.height, env.maxSize.height) });
          setState('expanded');
        },
        resize: function () {
          call('resize', []);
          if (env.placementType === 'interstitial') { error('resize() is not allowed for interstitials', 'resize'); return; }
          if (!resizeProperties) { error('setResizeProperties() must be called before resize()', 'resize'); return; }
          if (state !== 'default' && state !== 'resized') { error('resize() is not allowed in the ' + state + ' state', 'resize'); return; }
          var next = { x: env.defaultPosition.x + resizeProperties.offsetX, y: env.defaultPosition.y + resizeProperties.offsetY,
                       width: resizeProperties.width, height: resizeProperties.height };
          if (!resizeProperties.allowOffscreen) {
            if (next.width > env.maxSize.width || next.height > env.maxSize.height) { error('The resized ad does not fit the max size', 'resize'); return; }
            next.x = Math.min(Math.max(0, next.x), env.maxSize.width - next.width);
            next.y = Math.min(Math.max(0, next.y), env.maxSize.height - next.height);
          }
          setPosition(next);
          setState('resized');
        },
        getResizeProperties: function () { return getter('getResizeProperties', copy(resizeProperties)); },
        setResizeProperties: function (properties) {
          call('setResizeProperties', [properties]);
          if (!properties || !isNumber(properties.width) || !isNumber(properties.height) || !isNumber(properties.offsetX) || !isNumber(properties.offsetY)) {
            error('width, height, offsetX and offsetY must be numbers', 'setResizeProperties');
            return;
          }
          if (properties.width < 50 || properties.height < 50) { error('A resized ad must be at least 50×50', 'setResizeProperties'); return; }
          resizeProperties = { width: properties.width, height: properties.height, offsetX: properties.offsetX, offsetY: properties.offsetY,
                               customClosePosition: typeof properties.customClosePosition === 'string' ? properties.customClosePosition : 'top-right',
                               allowOffscreen: properties.allowOffscreen !== false };
        },
        getExpandProperties: function () { return getter('getExpandProperties', copy(expandProperties)); },
        setExpandProperties: function (properties) {
          call('setExpandProperties', [properties]);
          if (!properties || typeof properties !== 'object') { error('Expand properties must be an object', 'setExpandProperties'); return; }
          if (isNumber(properties.width) && properties.width > 0) { expandProperties.width = properties.width; }
          if (isNumber(properties.height) && properties.height > 0) { expandProperties.height = properties.height; }
          if (typeof properties.useCustomClose === 'boolean') {
            expandProperties.useCustomClose = properties.useCustomClose;
            customClose = properties.useCustomClose;
            announce();
          }
        },
        useCustomClose: function (value) {
          call('useCustomClose', [value], undefined, { value: value === true });
          customClose = value === true;
          expandProperties.useCustomClose = customClose;
          announce();
        },
        getOrientationProperties: function () { return getter('getOrientationProperties', copy(orientationProperties)); },
        setOrientationProperties: function (properties) {
          call('setOrientationProperties', [properties]);
          if (!properties || typeof properties !== 'object') { error('Orientation properties must be an object', 'setOrientationProperties'); return; }
          if (typeof properties.allowOrientationChange === 'boolean') { orientationProperties.allowOrientationChange = properties.allowOrientationChange; }
          if (['portrait', 'landscape', 'none'].indexOf(properties.forceOrientation) >= 0) { orientationProperties.forceOrientation = properties.forceOrientation; }
        },
        playVideo: function (url) {
          var href = absolute(url);
          call('playVideo', [href || url], undefined, { url: href || '' });
          if (!href) { error('playVideo() needs a URL', 'playVideo'); }
        },
        storePicture: function (url) { call('storePicture', [url]); error('storePicture is not supported', 'storePicture'); },
        createCalendarEvent: function (event) { call('createCalendarEvent', [event]); error('createCalendarEvent is not supported', 'createCalendarEvent'); }
      };

      var controller = {
        ready: function () {
          if (state !== 'loading') { return; }
          setState('default');
          fire('ready');
          fire('viewableChange', exposure > 0);
          fireExposure();
        },
        update: function (update) {
          if (!update || !isNumber(update.exposure)) { return; }
          var next = Math.min(100, Math.max(0, update.exposure));
          if (next === exposure) { return; }
          var wasViewable = exposure > 0;
          exposure = next;
          if (state === 'loading') { return; }
          if (wasViewable !== (exposure > 0)) { fire('viewableChange', exposure > 0); }
          fireExposure();
        },
        containerClose: function () {
          if (state === 'expanded' || state === 'resized') { backToDefault(); }
          else if (state === 'default') { setState('hidden'); }
        }
      };

      window.mraid = mraid;
      window.MRAID_ENV = { version: VERSION, sdk: env.sdk, sdkVersion: env.sdkVersion, appId: env.appID || undefined };
      Object.defineProperty(window, __CCINN_CONTROLLER__, { value: controller, writable: false, configurable: false, enumerable: false });
    })();
    """#
}
