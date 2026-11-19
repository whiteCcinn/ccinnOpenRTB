import Foundation

/// The script injected into the Prebid page (and its frames) at document start, before any Prebid code: the page's
/// network goes through the app.
///
/// - `fetch`, `XMLHttpRequest` and `navigator.sendBeacon` build WebKit's own `Request` first — so the method, the headers
///   (forbidden ones dropped), the body and its `Content-Type`, the mode and the credentials are exactly what Safari would
///   send — and hand it to the `prebidNet` handler, which applies CORS and sends it with the window's network monitor.
/// - Script `src` (set as a property or an attribute): the app answers with the file (Prebid.js's own, or a refusal),
///   which runs from a same-origin `blob:` URL — the element keeps its `integrity`, so WebKit still checks Prebid's
///   hashes, and `src` still reads the real URL (the loader reads its `?modules=` from `document.currentScript.src`).
/// - http(s) image and iframe `src` (user syncs, pixels) are reported to the app and not loaded; they say they loaded.
/// - WebRTC and WebTransport (their own sockets) are gone, and workers (where this script cannot run) throw — in every
///   frame, and in a same-origin frame reached before its own copy of this script ran.
/// - Following a link does nothing (the page stays): WebKit would preconnect to the target before the navigation guard
///   cancels it.
/// - `document.cookie` lives in memory: every auction is a fresh visit, and Prebid turns user syncs off when it cannot
///   set one.
/// - Everything it reports or asks carries the page's run, so the app drops a page being replaced.
///
/// The page's Content-Security-Policy and a content rule list block every other load, so anything this does not cover
/// fails closed.
enum PrebidShim {
    static let networkHandler = "prebidNet"

    static let source = #"""
    (function () {
      if (window.__ccinnPrebidShim) { return; }
      Object.defineProperty(window, '__ccinnPrebidShim', { value: true });
      var handlers = window.webkit && window.webkit.messageHandlers;
      var net = handlers && handlers.prebidNet;
      var events = handlers && handlers.prebidEvents;
      var NativeRequest = window.Request, NativeResponse = window.Response, NativeHeaders = window.Headers;
      var setAttribute = Element.prototype.setAttribute, removeAttribute = Element.prototype.removeAttribute;

      function run() { try { return window.top.__ccinnRun || window.__ccinnRun || null; } catch (e) { return window.__ccinnRun || null; } }
      function report(type, payload) { try { events.postMessage({ type: type, run: run(), payload: JSON.stringify(payload) }); } catch (e) {} }
      function absolute(url) { try { return new URL(String(url), document.baseURI).href; } catch (e) { return String(url); } }
      function isHTTP(url) { return /^https?:/i.test(String(url)); }
      function toBase64(bytes) {
        var text = '';
        for (var i = 0; i < bytes.length; i += 0x8000) { text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); }
        return btoa(text);
      }
      function fromBase64(base64) {
        var text = atob(base64 || '');
        var bytes = new Uint8Array(text.length);
        for (var i = 0; i < text.length; i++) { bytes[i] = text.charCodeAt(i); }
        return bytes;
      }
      function define(target, name, value) { try { Object.defineProperty(target, name, { configurable: true, value: value }); } catch (e) {} }

      // No network the app does not see.
      function seal(win) {
        try {
          if (!win || Object.prototype.hasOwnProperty.call(win, '__ccinnSealed')) { return; }
          Object.defineProperty(win, '__ccinnSealed', { value: true });
          ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCIceTransport', 'RTCSctpTransport', 'RTCDtlsTransport', 'WebTransport']
            .forEach(function (name) { try { delete win[name]; } catch (e) {} });
          ['Worker', 'SharedWorker'].forEach(function (name) {
            define(win, name, function () { throw new win.DOMException(name + ' is not available on this page', 'SecurityError'); });
          });
          try { Object.defineProperty(win.Navigator.prototype, 'serviceWorker', { configurable: true, get: function () { return undefined; } }); } catch (e) {}
        } catch (e) {}
      }
      seal(window);
      [window.HTMLIFrameElement, window.HTMLFrameElement].forEach(function (type) {
        if (!type) { return; }
        var windowOf = Object.getOwnPropertyDescriptor(type.prototype, 'contentWindow');
        var documentOf = Object.getOwnPropertyDescriptor(type.prototype, 'contentDocument');
        if (windowOf) {
          Object.defineProperty(type.prototype, 'contentWindow', { configurable: true, get: function () {
            var win = windowOf.get.call(this); seal(win); return win;
          } });
        }
        if (documentOf) {
          Object.defineProperty(type.prototype, 'contentDocument', { configurable: true, get: function () {
            var doc = documentOf.get.call(this); if (doc) { seal(doc.defaultView); } return doc;
          } });
        }
      });

      function headersOf(headers) { var result = {}; headers.forEach(function (value, name) { result[name] = value; }); return result; }
      function bodyOf(request) {
        if (request.method === 'GET' || request.method === 'HEAD' || !request.body) { return Promise.resolve(null); }
        return request.arrayBuffer().then(function (buffer) { return new Uint8Array(buffer); });
      }
      function post(kind, request, mode) {
        if (!net) { return Promise.reject(new TypeError('Load failed')); }
        return bodyOf(request).then(function (bytes) {
          return net.postMessage({ kind: kind, run: run(), url: request.url, method: request.method, headers: headersOf(request.headers),
                                   body: bytes && bytes.length ? toBase64(bytes) : null, mode: mode || request.mode, credentials: request.credentials });
        });
      }
      function abortError(signal) { return (signal && signal.reason) || new DOMException('Fetch is aborted', 'AbortError'); }

      window.fetch = function (input, init) {
        var request;
        try { request = new NativeRequest(input, init); } catch (error) { return Promise.reject(error); }
        var signal = request.signal;
        if (signal && signal.aborted) { return Promise.reject(abortError(signal)); }
        var answer = post('fetch', request);
        var aborted = signal ? new Promise(function (_, reject) {
          signal.addEventListener('abort', function () { reject(abortError(signal)); });
        }) : null;
        return (aborted ? Promise.race([answer, aborted]) : answer).then(function (reply) {
          var opaque = reply.type === 'opaque';
          var headers = new NativeHeaders();
          if (!opaque) { (reply.headers || []).forEach(function (pair) { try { headers.append(pair[0], pair[1]); } catch (e) {} }); }
          var status = reply.status >= 200 && reply.status <= 599 ? reply.status : 200;
          var empty = opaque || status === 204 || status === 205 || status === 304 || request.method === 'HEAD';
          var response = new NativeResponse(empty ? null : fromBase64(reply.body), { status: status, statusText: opaque ? '' : (reply.statusText || ''), headers: headers });
          define(response, 'url', opaque ? '' : (reply.url || request.url));
          define(response, 'redirected', !!reply.redirected);
          define(response, 'type', reply.type || 'basic');
          if (opaque) { define(response, 'status', 0); define(response, 'ok', false); }
          return response;
        }, function (error) {
          if (error && error.name === 'AbortError') { throw error; }
          throw new TypeError('Load failed');
        });
      };

      var tokenPattern = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
      var normalized = ['DELETE', 'GET', 'HEAD', 'OPTIONS', 'POST', 'PUT'];
      class ShimXHR extends EventTarget {
        constructor() {
          super();
          this.readyState = 0; this.timeout = 0; this.withCredentials = false; this.responseType = '';
          this.upload = new EventTarget(); this._generation = 0; this._clear();
        }
        _clear() {
          this.status = 0; this.statusText = ''; this.response = ''; this.responseText = ''; this.responseURL = '';
          this._responseHeaders = []; this._headers = new NativeHeaders(); this._sent = false; this._done = false;
          if (this._timer) { clearTimeout(this._timer); this._timer = null; }
        }
        open(method, url) {
          var verb = String(method);
          if (!tokenPattern.test(verb)) { throw new DOMException('Invalid method ' + verb, 'SyntaxError'); }
          var upper = verb.toUpperCase();
          if (upper === 'CONNECT' || upper === 'TRACE' || upper === 'TRACK') { throw new DOMException(upper + ' is forbidden', 'SecurityError'); }
          if (normalized.indexOf(upper) >= 0) { verb = upper; }
          this._generation += 1; this._clear();
          this._method = verb; this._url = absolute(url); this.readyState = 1; this._fire('readystatechange');
        }
        setRequestHeader(name, value) {
          if (this.readyState !== 1 || this._sent) { throw new DOMException('The object is in an invalid state.', 'InvalidStateError'); }
          try { this._headers.append(name, value); } catch (e) { throw new DOMException('Invalid header ' + name, 'SyntaxError'); }
        }
        getResponseHeader(name) {
          var lower = String(name).toLowerCase(), values = [];
          this._responseHeaders.forEach(function (pair) { if (pair[0].toLowerCase() === lower) { values.push(pair[1]); } });
          return values.length ? values.join(', ') : null;
        }
        getAllResponseHeaders() {
          return this._responseHeaders.map(function (pair) { return pair[0].toLowerCase() + ': ' + pair[1] + '\r\n'; }).join('');
        }
        overrideMimeType() {}
        _fire(type, target) {
          var on = target || this;
          var event = type === 'readystatechange' ? new Event(type) : new ProgressEvent(type);
          on.dispatchEvent(event);
          var handler = on['on' + type];
          if (typeof handler === 'function') { try { handler.call(on, event); } catch (e) { setTimeout(function () { throw e; }); } }
        }
        _fail(type) {
          this._done = true;
          if (this._timer) { clearTimeout(this._timer); this._timer = null; }
          this.status = 0; this.statusText = ''; this.response = this.responseType === '' || this.responseType === 'text' ? '' : null; this.responseText = '';
          this.readyState = 4; this._fire('readystatechange'); this._fire(type); this._fire('loadend');
        }
        abort() {
          var active = this._sent && !this._done && this.readyState > 0 && this.readyState < 4;
          this._generation += 1;
          if (active) { this._fail('abort'); }
          this.readyState = 0;
        }
        send(body) {
          if (this.readyState !== 1 || this._sent) { throw new DOMException('The object is in an invalid state.', 'InvalidStateError'); }
          this._sent = true;
          var xhr = this, generation = this._generation, request;
          var bodyless = this._method === 'GET' || this._method === 'HEAD';
          try {
            request = new NativeRequest(this._url, { method: this._method, headers: this._headers, body: bodyless ? null : (body === undefined ? null : body),
                                                     credentials: this.withCredentials ? 'include' : 'same-origin', mode: 'cors' });
          } catch (error) {
            setTimeout(function () { if (generation === xhr._generation) { xhr._fail('error'); } }, 0);
            return;
          }
          if (this.timeout > 0) {
            this._timer = setTimeout(function () { if (generation === xhr._generation && !xhr._done) { xhr._fail('timeout'); } }, this.timeout);
          }
          this._fire('loadstart');
          if (!bodyless && body !== undefined && body !== null) { this._fire('loadstart', this.upload); }
          post('xhr', request).then(function (reply) {
            if (generation !== xhr._generation || xhr._done) { return; }
            var bytes = fromBase64(reply.body);
            xhr.status = reply.status; xhr.statusText = reply.statusText || ''; xhr.responseURL = reply.url || '';
            xhr._responseHeaders = reply.headers || [];
            xhr.readyState = 2; xhr._fire('readystatechange');
            var text = new TextDecoder().decode(bytes);
            if (xhr.responseType === 'json') { try { xhr.response = JSON.parse(text); } catch (e) { xhr.response = null; } }
            else if (xhr.responseType === 'arraybuffer') { xhr.response = bytes.buffer; }
            else if (xhr.responseType === 'blob') { xhr.response = new Blob([bytes], { type: xhr.getResponseHeader('content-type') || '' }); }
            else if (xhr.responseType === 'document') { xhr.response = null; }
            else { xhr.response = text; }
            xhr.responseText = xhr.responseType === '' || xhr.responseType === 'text' ? text : '';
            xhr.readyState = 3; xhr._fire('readystatechange'); xhr._fire('progress');
            xhr._done = true;
            if (xhr._timer) { clearTimeout(xhr._timer); xhr._timer = null; }
            xhr.readyState = 4; xhr._fire('readystatechange'); xhr._fire('load'); xhr._fire('loadend');
          }, function () {
            if (generation !== xhr._generation || xhr._done) { return; }
            xhr._fail('error');
          });
        }
      }
      ['UNSENT', 'OPENED', 'HEADERS_RECEIVED', 'LOADING', 'DONE'].forEach(function (name, value) {
        Object.defineProperty(ShimXHR, name, { value: value }); Object.defineProperty(ShimXHR.prototype, name, { value: value });
      });
      window.XMLHttpRequest = ShimXHR;

      if (navigator.sendBeacon) {
        var safelistedBody = /^(application\/x-www-form-urlencoded|multipart\/form-data|text\/plain)\s*(;|$)/i;
        navigator.sendBeacon = function (url, data) {
          var request;
          try { request = new NativeRequest(absolute(url), { method: 'POST', body: data === undefined ? null : data, credentials: 'include' }); }
          catch (error) { throw new TypeError('sendBeacon: ' + (error && error.message || error)); }
          var type = request.headers.get('content-type');
          // A CORS-safelisted body goes no-cors; any other content type is a CORS request (with its preflight).
          post('beacon', request, !type || safelistedBody.test(type.trim()) ? 'no-cors' : 'cors').catch(function () {});
          return true;
        };
      }

      function interceptSource(prototype, kind) {
        var native = Object.getOwnPropertyDescriptor(prototype, 'src');
        Object.defineProperty(prototype, 'src', {
          configurable: true,
          get: function () { return this.__ccinnSource !== undefined ? this.__ccinnSource : native.get.call(this); },
          set: function (value) {
            var element = this, url = absolute(value);
            if (!isHTTP(url)) { element.__ccinnSource = undefined; native.set.call(element, value); return; }
            element.__ccinnSource = url;
            report('sync', { kind: kind, url: url });
            setTimeout(function () { element.dispatchEvent(new Event('load')); }, 0);
          }
        });
      }
      interceptSource(HTMLImageElement.prototype, 'image');
      interceptSource(HTMLIFrameElement.prototype, 'iframe');

      var nativeScriptSource = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
      function loadScript(element, value) {
        var url = absolute(value);
        element.__ccinnSource = url;
        if (!isHTTP(url)) { nativeScriptSource.set.call(element, value); return; }
        var asked = net ? net.postMessage({ kind: 'script', run: run(), url: url, method: 'GET', headers: {}, body: null })
                        : Promise.reject(new Error('the network is not available'));
        asked.then(function (reply) {
          if (reply.blocked) {
            report('log', { level: 'warn', message: 'Script blocked (only Prebid.js runs on this page): ' + url });
            element.dispatchEvent(new Event('error'));
            return;
          }
          var blob = URL.createObjectURL(new Blob([fromBase64(reply.body)], { type: 'text/javascript' }));
          var done = function () { URL.revokeObjectURL(blob); };
          element.addEventListener('load', done, { once: true });
          element.addEventListener('error', function () {
            done();
            report('scriptError', { url: url, reason: element.hasAttribute('integrity') ? 'its integrity check failed' : 'it did not run' });
          }, { once: true });
          setAttribute.call(element, 'src', blob);
        }, function (error) {
          report('scriptError', { url: url, reason: String(error && error.message || error) });
          element.dispatchEvent(new Event('error'));
        });
      }
      Object.defineProperty(HTMLScriptElement.prototype, 'src', {
        configurable: true,
        get: function () { return this.__ccinnSource !== undefined ? this.__ccinnSource : nativeScriptSource.get.call(this); },
        set: function (value) { loadScript(this, value); }
      });

      Element.prototype.setAttribute = function (name, value) {
        if (String(name).toLowerCase() === 'src' && (this instanceof HTMLImageElement || this instanceof HTMLIFrameElement || this instanceof HTMLScriptElement)) {
          this.src = value;
          return;
        }
        return setAttribute.call(this, name, value);
      };

      // Following a link does nothing: the page stays, and WebKit gets no target to preconnect to. A click's default
      // action runs while the link has no href (its listeners still run); a click in the page is cancelled.
      function linkOf(node) {
        var link = node && node.closest ? node.closest('a[href], area[href]') : null;
        return link && isHTTP(link.href) ? link : null;
      }
      function stayOnPage(link, action) {
        report('log', { level: 'warn', message: 'Navigation not followed (the page stays): ' + link.href });
        var href = link.getAttribute('href');
        removeAttribute.call(link, 'href');
        try { return action(); } finally { setAttribute.call(link, 'href', href); }
      }
      var click = HTMLElement.prototype.click;
      HTMLElement.prototype.click = function () {
        var link = linkOf(this), element = this;
        return link ? stayOnPage(link, function () { return click.call(element); }) : click.call(this);
      };
      var dispatch = EventTarget.prototype.dispatchEvent;
      EventTarget.prototype.dispatchEvent = function (event) {
        var link = event && event.type === 'click' ? linkOf(this) : null, target = this;
        return link ? stayOnPage(link, function () { return dispatch.call(target, event); }) : dispatch.call(this, event);
      };
      document.addEventListener('click', function (event) {
        var link = linkOf(event.target);
        if (link) { event.preventDefault(); report('log', { level: 'warn', message: 'Navigation not followed (the page stays): ' + link.href }); }
      }, true);
      document.addEventListener('submit', function (event) { event.preventDefault(); }, true);
      HTMLFormElement.prototype.submit = function () { report('log', { level: 'warn', message: 'Form submission not followed (the page stays)' }); };

      var jar = {};
      Object.defineProperty(Document.prototype, 'cookie', {
        configurable: true,
        get: function () { return Object.keys(jar).map(function (name) { return name + '=' + jar[name]; }).join('; '); },
        set: function (value) {
          var parts = String(value).split(';');
          var pair = parts[0];
          var equals = pair.indexOf('=');
          if (equals < 0) { return; }
          var name = pair.slice(0, equals).trim();
          var expired = parts.slice(1).some(function (attribute) {
            var match = /^\s*(max-age|expires)\s*=\s*(.*)$/i.exec(attribute);
            if (!match) { return false; }
            return match[1].toLowerCase() === 'max-age' ? Number(match[2]) <= 0 : Date.parse(match[2]) < Date.now();
          });
          if (expired) { delete jar[name]; } else { jar[name] = pair.slice(equals + 1).trim(); }
        }
      });
    })();
    """#
}
