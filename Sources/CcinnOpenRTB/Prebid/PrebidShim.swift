import Foundation

/// The script injected into the Prebid page (and its frames) at document start, before any Prebid code: the page's
/// network goes through the app.
///
/// - Script `src` (set as a property or an attribute): the app answers with the file (Prebid.js's own, or a refusal),
///   which runs from a same-origin `blob:` URL — the element keeps its `integrity`, so WebKit still checks Prebid's
///   hashes, and `src` still reads the real URL (the loader reads its `?modules=` from `document.currentScript.src`).
/// - `fetch` and `XMLHttpRequest` go to the `prebidNet` handler, which sends them with the window's network monitor and
///   answers with the response (a real `Response` for `fetch`). A `no-cors` fetch is a pixel (a tracker).
/// - `navigator.sendBeacon` goes the same way, without waiting.
/// - http(s) image and iframe `src` (user syncs, pixels) are reported to the app and not loaded; they say they loaded.
/// - `document.cookie` lives in memory: every auction is a fresh visit, and Prebid turns user syncs off when it cannot
///   set one.
///
/// A content rule list blocks every other load of the page, so anything this does not cover fails closed.
enum PrebidShim {
    static let networkHandler = "prebidNet"

    static let source = #"""
    (function () {
      if (window.__ccinnPrebidShim) { return; }
      window.__ccinnPrebidShim = true;
      var net = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prebidNet;
      var events = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.prebidEvents;
      function report(type, payload) { try { events.postMessage({ type: type, payload: JSON.stringify(payload) }); } catch (e) {} }
      function absolute(url) { try { return new URL(String(url), document.baseURI).href; } catch (e) { return String(url); } }
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
      async function bytesOf(body) {
        if (body === null || body === undefined) { return null; }
        if (typeof body === 'string') { return new TextEncoder().encode(body); }
        if (body instanceof ArrayBuffer) { return new Uint8Array(body); }
        if (ArrayBuffer.isView(body)) { return new Uint8Array(body.buffer, body.byteOffset, body.byteLength); }
        if (typeof Blob !== 'undefined' && body instanceof Blob) { return new Uint8Array(await body.arrayBuffer()); }
        return new TextEncoder().encode(String(body));
      }
      async function send(kind, url, method, headers, body) {
        if (!net) { throw new TypeError('The network is not available'); }
        var bytes = await bytesOf(body);
        return net.postMessage({ kind: kind, url: absolute(url), method: method || 'GET', headers: headers || {}, body: bytes ? toBase64(bytes) : null });
      }
      function headerObject(source) {
        var headers = {};
        try { new Headers(source || {}).forEach(function (value, name) { headers[name] = value; }); } catch (e) {}
        return headers;
      }

      window.fetch = async function (input, init) {
        init = init || {};
        var request = (typeof Request !== 'undefined' && input instanceof Request) ? input : null;
        var url = request ? request.url : String(input);
        var method = String(init.method || (request && request.method) || 'GET').toUpperCase();
        var headers = headerObject(init.headers || (request && request.headers));
        var body = init.body !== undefined ? init.body
          : (request && method !== 'GET' && method !== 'HEAD' ? await request.clone().arrayBuffer() : null);
        var signal = init.signal || (request && request.signal);
        if (signal && signal.aborted) { throw new DOMException('The operation was aborted.', 'AbortError'); }
        var mode = init.mode || (request && request.mode);
        var kind = mode === 'no-cors' ? 'pixel' : 'fetch';
        var answer = send(kind, url, method, headers, body);
        var aborted = signal ? new Promise(function (_, reject) {
          signal.addEventListener('abort', function () { reject(new DOMException('The operation was aborted.', 'AbortError')); });
        }) : null;
        var reply;
        try { reply = await (aborted ? Promise.race([answer, aborted]) : answer); }
        catch (error) { if (error && error.name === 'AbortError') { throw error; } throw new TypeError('Failed to fetch: ' + (error && error.message || error)); }
        var responseHeaders = new Headers();
        (reply.headers || []).forEach(function (pair) { try { responseHeaders.append(pair[0], pair[1]); } catch (e) {} });
        var status = reply.status >= 200 && reply.status <= 599 ? reply.status : 200;
        var empty = status === 204 || status === 205 || status === 304;
        return new Response(empty ? null : fromBase64(reply.body), { status: status, statusText: reply.statusText || '', headers: responseHeaders });
      };

      function ShimXHR() {
        this.readyState = 0; this.status = 0; this.statusText = ''; this.responseText = ''; this.response = '';
        this.responseType = ''; this.responseURL = ''; this.withCredentials = false; this.timeout = 0; this.upload = {};
        this._headers = {}; this._responseHeaders = []; this._listeners = {};
      }
      ['UNSENT', 'OPENED', 'HEADERS_RECEIVED', 'LOADING', 'DONE'].forEach(function (name, value) { ShimXHR[name] = value; ShimXHR.prototype[name] = value; });
      ShimXHR.prototype.open = function (method, url) { this._method = String(method || 'GET').toUpperCase(); this._url = url; this.readyState = 1; this._fire('readystatechange'); };
      ShimXHR.prototype.setRequestHeader = function (name, value) { this._headers[name] = String(value); };
      ShimXHR.prototype.getResponseHeader = function (name) {
        var lower = String(name).toLowerCase();
        for (var i = 0; i < this._responseHeaders.length; i++) { if (this._responseHeaders[i][0].toLowerCase() === lower) { return this._responseHeaders[i][1]; } }
        return null;
      };
      ShimXHR.prototype.getAllResponseHeaders = function () { return this._responseHeaders.map(function (pair) { return pair[0] + ': ' + pair[1]; }).join('\r\n'); };
      ShimXHR.prototype.overrideMimeType = function () {};
      ShimXHR.prototype.addEventListener = function (type, listener) { (this._listeners[type] = this._listeners[type] || []).push(listener); };
      ShimXHR.prototype.removeEventListener = function (type, listener) { this._listeners[type] = (this._listeners[type] || []).filter(function (l) { return l !== listener; }); };
      ShimXHR.prototype._fire = function (type) {
        var event = { type: type, target: this, currentTarget: this };
        var handler = this['on' + type];
        try { if (typeof handler === 'function') { handler.call(this, event); } } catch (e) { setTimeout(function () { throw e; }); }
        (this._listeners[type] || []).forEach(function (listener) { try { listener.call(this, event); } catch (e) { setTimeout(function () { throw e; }); } }, this);
      };
      ShimXHR.prototype.abort = function () { this._aborted = true; this.readyState = 4; this._fire('abort'); this._fire('loadend'); };
      ShimXHR.prototype.send = function (body) {
        var xhr = this;
        send('xhr', this._url, this._method, this._headers, body).then(function (reply) {
          if (xhr._aborted) { return; }
          var bytes = fromBase64(reply.body);
          xhr.status = reply.status; xhr.statusText = reply.statusText || ''; xhr.responseURL = reply.url || '';
          xhr._responseHeaders = reply.headers || [];
          xhr.responseText = new TextDecoder().decode(bytes);
          if (xhr.responseType === 'json') { try { xhr.response = JSON.parse(xhr.responseText); } catch (e) { xhr.response = null; } }
          else if (xhr.responseType === 'arraybuffer') { xhr.response = bytes.buffer; }
          else { xhr.response = xhr.responseText; }
          xhr.readyState = 4; xhr._fire('readystatechange'); xhr._fire('load'); xhr._fire('loadend');
        }, function () {
          if (xhr._aborted) { return; }
          xhr.readyState = 4; xhr.status = 0; xhr._fire('readystatechange'); xhr._fire('error'); xhr._fire('loadend');
        });
      };
      window.XMLHttpRequest = ShimXHR;

      if (navigator.sendBeacon) {
        navigator.sendBeacon = function (url, data) { send('beacon', url, 'POST', {}, data).catch(function () {}); return true; };
      }

      var setAttribute = Element.prototype.setAttribute;
      function isHTTP(url) { return /^https?:/i.test(url); }

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
        send('script', url, 'GET', {}, null).then(function (reply) {
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
