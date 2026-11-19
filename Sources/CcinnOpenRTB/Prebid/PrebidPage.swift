import Foundation
import RTBKit

/// The publisher page that runs Prebid.js, loaded as the response to the page's own URL (`https://news.example/article`)
/// so Prebid sees the page bidders should see — `location`, referrer detection, a secure context. It loads the official
/// per-version loader (`dist/bundle.js?modules=…`) from where it lives (jsDelivr), the shim handing every Prebid script
/// to the page from the app's library with its `integrity` intact. It emulates the device's screen, sets the config
/// (production: no debug), adds the ad units, reports Prebid's events and runs the auction. Everything typed reaches the
/// page as JSON, never as script. Pure.
enum PrebidPage {
    /// The message handler the page reports to.
    static let eventsHandler = "prebidEvents"

    /// The page's URL: the setup's https page.
    static func pageURL(of setup: PrebidSetup) -> URL? {
        guard let url = URL(string: setup.pageURL), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The official loader of the version at `distBase` (`…/prebid.js@11.51.0/dist/`), with the modules and its chunks'
    /// base.
    static func loaderURL(distBase: String, modules: [String]) -> String {
        "\(distBase)bundle.js?modules=\(modules.joined(separator: ","))&distUrlBase=\(distBase)chunks/"
    }

    static func html(for setup: PrebidSetup, catalog: [String: PrebidBidder], distBase: String,
                     device: PrebidDevice) throws(PrebidSetup.Invalid) -> String {
        let modules = try setup.modules(catalog: catalog)
        let loader = json(.string(loaderURL(distBase: distBase, modules: modules)))
        let config = json(.object(configObject(setup, catalog: catalog)))
        let units = json(.array(setup.adUnits.map(adUnitObject)))
        let divs = setup.adUnits.map { "<div id=\"\(attribute($0.code))\" class=\"slot\"></div>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Prebid.js \(attribute(setup.version))</title>
        <style>body{font:12px -apple-system,sans-serif;margin:8px}.slot{border:1px dashed #999;min-height:20px;margin:4px 0}</style>
        <script>
        (function () {
          \(emulation(device))
          function safe() {
            var seen = new WeakSet();
            return function (key, value) {
              if (typeof value === 'function') return undefined;
              if (value instanceof Error) return String(value);
              if (value && typeof value === 'object') { if (seen.has(value)) return undefined; seen.add(value); }
              return value;
            };
          }
          function post(type, payload) {
            try { window.webkit.messageHandlers.\(eventsHandler).postMessage({ type: type, payload: JSON.stringify(payload, safe()) }); } catch (e) {}
          }
          // console.warn('%cPrebid', 'css…', 'WARNING: …') reads "Prebid WARNING: …".
          function text(args) {
            args = Array.prototype.slice.call(args || []);
            if (typeof args[0] === 'string' && args[0].indexOf('%c') >= 0) {
              var styles = args[0].split('%c').length - 1;
              args = [args[0].split('%c').join(' ')].concat(args.slice(1 + styles));
            }
            return args.map(function (value) {
              if (typeof value === 'string') return value;
              if (value instanceof Error) return String(value);
              try { return JSON.stringify(value, safe()); } catch (e) { return String(value); }
            }).join(' ').replace(/\\s+/g, ' ').trim().slice(0, 2000);
          }
          ['warn', 'error'].forEach(function (level) {
            var original = console[level];
            console[level] = function () {
              post('log', { level: level, message: text(arguments) });
              return original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (event) { if (event.message) post('log', { level: 'error', message: String(event.message) }); });
          window.addEventListener('unhandledrejection', function (event) { post('log', { level: 'error', message: 'Unhandled rejection: ' + text([event.reason]) }); });
          window.pbjs = window.pbjs || {};
          pbjs.que = pbjs.que || [];
          pbjs.que.push(function () {
            // Prebid emits its warnings and errors as auctionDebug whether or not debug is on.
            pbjs.onEvent('auctionDebug', function (data) {
              var level = String(data && data.type || 'WARNING').toLowerCase();
              post('log', { level: level, message: (data && data.bidder ? data.bidder + ': ' : '') + text(data && data.arguments) });
            });
            ['auctionInit', 'bidRequested', 'bidResponse', 'noBid', 'bidTimeout', 'bidderDone', 'bidderError', 'auctionEnd', 'adRenderFailed']
              .forEach(function (name) { pbjs.onEvent(name, function (data) { post(name, data); }); });
            pbjs.setConfig(\(config));
            pbjs.addAdUnits(\(units));
            post('ready', { version: pbjs.version });
            pbjs.requestBids({
              timeout: \(setup.timeoutMilliseconds),
              bidsBackHandler: function (responses) {
                var bids = [];
                Object.keys(responses || {}).forEach(function (code) { (responses[code].bids || []).forEach(function (bid) { bids.push(bid); }); });
                post('bidsBack', bids);
              }
            });
          });
          var loader = document.createElement('script');
          loader.src = \(loader);
          document.head.appendChild(loader);
        })();
        </script>
        </head><body>
        \(divs)
        </body></html>
        """
    }

    /// The device as the page's scripts read it: the screen, the viewport, the pixel ratio, the platform, touch and the
    /// languages (the monitor's `Accept-Language`).
    private static func emulation(_ device: PrebidDevice) -> String {
        let values = json(.object([
            "screenWidth": .int(Int64(device.screenWidth)), "screenHeight": .int(Int64(device.screenHeight)),
            "viewportWidth": .int(Int64(device.viewportWidth)), "viewportHeight": .int(Int64(device.viewportHeight)),
            "pixelRatio": .double(device.pixelRatio), "platform": .string(device.platform),
            "maxTouchPoints": .int(Int64(device.maxTouchPoints)), "languages": .array(device.languages.map { .string($0) }),
        ]))
        return """
        (function (d) {
            function define(target, name, value) { try { Object.defineProperty(target, name, { configurable: true, get: function () { return value; } }); } catch (e) {} }
            var screenType = Object.getPrototypeOf(screen), navigatorType = Object.getPrototypeOf(navigator);
            define(screenType, 'width', d.screenWidth); define(screenType, 'height', d.screenHeight);
            define(screenType, 'availWidth', d.screenWidth); define(screenType, 'availHeight', d.screenHeight);
            define(window, 'devicePixelRatio', d.pixelRatio);
            define(window, 'innerWidth', d.viewportWidth); define(window, 'innerHeight', d.viewportHeight);
            define(window, 'outerWidth', d.screenWidth); define(window, 'outerHeight', d.screenHeight);
            define(navigatorType, 'platform', d.platform); define(navigatorType, 'maxTouchPoints', d.maxTouchPoints);
            define(navigatorType, 'language', d.languages[0]); define(navigatorType, 'languages', Object.freeze(d.languages.slice()));
          })(\(values));
        """
    }

    private static func configObject(_ setup: PrebidSetup, catalog: [String: PrebidBidder]) -> [String: JSONValue] {
        var config: [String: JSONValue] = [
            "pageUrl": .string(setup.pageURL),
            "bidderTimeout": .int(Int64(setup.timeoutMilliseconds)),
            "enableSendAllBids": .bool(true),
            "userSync": .object([
                "syncEnabled": .bool(true),
                "syncDelay": .int(0),
                "filterSettings": .object([
                    "image": .object(["bidders": .string("*"), "filter": .string("include")]),
                    "iframe": .object(["bidders": .string("*"), "filter": .string("include")]),
                ]),
            ]),
        ]
        var consent: [String: JSONValue] = [:]
        if let applies = setup.consent.gdprApplies {
            let purposes = JSONValue.object(Dictionary(uniqueKeysWithValues: (1...11).map { ("\($0)", JSONValue.bool(true)) }))
            let vendors = JSONValue.object(Dictionary(uniqueKeysWithValues: setup.vendorIDs(catalog: catalog).map { ("\($0)", JSONValue.bool(true)) }))
            consent["gdpr"] = .object([
                "cmpApi": .string("static"),
                "timeout": .int(0),
                "consentData": .object([
                    "tcString": .string(setup.consent.tcString),
                    "gdprApplies": .bool(applies),
                    "purpose": .object(["consents": purposes, "legitimateInterests": purposes]),
                    "vendor": .object(["consents": vendors, "legitimateInterests": vendors]),
                ]),
            ])
        }
        if setup.consent.configuresUSP {
            consent["usp"] = .object(["cmpApi": .string("static"), "timeout": .int(0),
                                      "consentData": .object(["getUSPData": .object(["uspString": .string(setup.consent.usPrivacy)])])])
        }
        if setup.consent.configuresGPP {
            consent["gpp"] = .object(["cmpApi": .string("static"), "timeout": .int(0),
                                      "consentData": .object(["gppString": .string(setup.consent.gppString),
                                                              "applicableSections": .array(setup.consent.gppSectionIDs.map { .int(Int64($0)) })])])
        }
        if !consent.isEmpty { config["consentManagement"] = .object(consent) }
        return config
    }

    private static func adUnitObject(_ unit: PrebidAdUnit) -> JSONValue {
        let sizes = JSONValue.array(unit.sizes.map { .array([.int(Int64($0.width)), .int(Int64($0.height))]) })
        let mediaTypes: JSONValue = switch unit.mediaType {
        case .banner: .object(["banner": .object(["sizes": sizes])])
        case .video: .object(["video": .object(["context": .string("outstream"), "playerSize": unit.sizes.first.map {
            .array([.array([.int(Int64($0.width)), .int(Int64($0.height))])]) } ?? .array([]),
            "mimes": .array([.string("video/mp4")]), "protocols": .array([2, 3, 5, 6, 7, 8].map { .int($0) })])])
        case .native: .object(["native": .object(["ortb": .object(["ver": .string("1.2"), "assets": .array([
            .object(["id": .int(1), "required": .int(1), "title": .object(["len": .int(80)])]),
            .object(["id": .int(2), "required": .int(1), "img": .object(["type": .int(3), "w": .int(1200), "h": .int(627)])]),
            .object(["id": .int(3), "data": .object(["type": .int(1)])]),
        ])])])])
        }
        let bids = JSONValue.array(unit.bids.map { bid in
            let params = (try? JSONValue.parse(bid.params)) ?? .object([:])
            return .object(["bidder": .string(bid.bidder), "params": params])
        })
        return .object(["code": .string(unit.code.trimmingCharacters(in: .whitespaces)), "mediaTypes": mediaTypes, "bids": bids])
    }

    /// JSON that is safe inside a `<script>`: `</` can never close it, and U+2028/2029 cannot end a line.
    static func json(_ value: JSONValue) -> String {
        value.serialized()
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
