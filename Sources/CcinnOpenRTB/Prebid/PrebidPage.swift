import Foundation
import RTBKit

/// The publisher page that runs Prebid.js: served by the `ccinn-prebid` scheme under the page's own host, it loads the
/// official per-version loader (`dist/bundle.js?modules=…`) with every chunk from the same scheme (so Prebid's own SRI
/// checks hold), sets the config (`pageUrl` is the real https page), adds the ad units, reports Prebid's events to the
/// app and runs the auction. Everything typed reaches the page as JSON, never as script. Pure.
enum PrebidPage {
    static let scheme = "ccinn-prebid"
    /// The message handler the page reports to.
    static let eventsHandler = "prebidEvents"

    /// The page's host: the publisher's (`news.example`).
    static func host(of setup: PrebidSetup) -> String {
        URL(string: setup.pageURL)?.host ?? "publisher.example"
    }

    /// `ccinn-prebid://news.example/prebid/11.51.0/dist/`.
    static func distBase(of setup: PrebidSetup) -> String {
        "\(scheme)://\(host(of: setup))/prebid/\(setup.version)/dist/"
    }

    static func pageURL(of setup: PrebidSetup) -> URL? {
        URL(string: "\(scheme)://\(host(of: setup))/index.html")
    }

    static func html(for setup: PrebidSetup, catalog: [String: PrebidBidder]) throws(PrebidSetup.Invalid) -> String {
        let modules = try setup.modules(catalog: catalog)
        let base = distBase(of: setup)
        let loader = "\(base)bundle.js?modules=\(modules.joined(separator: ","))&distUrlBase=\(base)chunks/"
        let config = json(.object(configObject(setup, catalog: catalog)))
        let units = json(.array(setup.adUnits.map(adUnitObject)))
        let divs = setup.adUnits.map { "<div id=\"\(attribute($0.code))\" class=\"slot\"></div>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Prebid.js \(attribute(setup.version))</title>
        <style>body{font:12px -apple-system,sans-serif;margin:8px}.slot{border:1px dashed #999;min-height:20px;margin:4px 0}</style>
        <script>window.pbjs = window.pbjs || {}; window.pbjs.que = window.pbjs.que || [];</script>
        <script src="\(attribute(loader))"></script>
        </head><body>
        \(divs)
        <script>
        (function () {
          var post = function (type, payload) {
            try { window.webkit.messageHandlers.\(eventsHandler).postMessage({ type: type, payload: JSON.stringify(payload, safe()) }); } catch (e) {}
          };
          function safe() {
            var seen = new WeakSet();
            return function (key, value) {
              if (typeof value === 'function') return undefined;
              if (value && typeof value === 'object') { if (seen.has(value)) return undefined; seen.add(value); }
              return value;
            };
          }
          ['warn', 'error'].forEach(function (level) {
            var original = console[level];
            console[level] = function () {
              try { post('log', { level: level, message: Array.prototype.map.call(arguments, String).join(' ').slice(0, 2000) }); } catch (e) {}
              return original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (event) { post('log', { level: 'error', message: String(event.message) }); });
          pbjs.que.push(function () {
            pbjs.setConfig(\(config));
            pbjs.addAdUnits(\(units));
            ['auctionInit', 'bidRequested', 'bidResponse', 'noBid', 'bidTimeout', 'bidderDone', 'bidderError', 'auctionEnd', 'adRenderFailed']
              .forEach(function (name) { pbjs.onEvent(name, function (data) { post(name, data); }); });
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
        })();
        </script>
        </body></html>
        """
    }

    private static func configObject(_ setup: PrebidSetup, catalog: [String: PrebidBidder]) -> [String: JSONValue] {
        var config: [String: JSONValue] = [
            "debug": .bool(true),
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
