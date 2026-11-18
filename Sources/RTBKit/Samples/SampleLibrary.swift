import Foundation

/// Built-in samples (design D11). Owner: kit-openrtb (OpenRTB / Native); VAST XML constants live in VASTSamples.swift (kit-vast).
public struct Sample: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var group: String
    public var response: String
    public var request: String?

    public init(id: String, title: String, group: String, response: String, request: String? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.response = response
        self.request = request
    }
}

/// Every sample works offline: trackers live on `https://tracker.example/…`, landing pages on
/// `https://advertiser.example/…` (RFC 2606 reserved names), images and media are `ccinn-sample://` URLs the app serves
/// locally, and markup by reference (nurl, `display.curl`) is a `data:` URL. Each sample parses without errors or
/// warnings; requests match their responses (ids, impressions, Native assets).
public enum SampleLibrary {
    public static let all: [Sample] = [
        // Display
        Sample(id: "ortb25-banner-html", title: "OpenRTB 2.5 · HTML banner 320×50", group: Group.display,
               response: DisplaySamples.banner25, request: DisplaySamples.banner25Request),
        Sample(id: "ortb26-mraid-interstitial", title: "OpenRTB 2.6 · MRAID interstitial 320×480", group: Group.display,
               response: DisplaySamples.interstitial26, request: DisplaySamples.interstitial26Request),
        Sample(id: "ortb25-nurl-markup", title: "OpenRTB 2.5 · Markup from the win notice (nurl)", group: Group.display,
               response: DisplaySamples.nurlMarkup25, request: DisplaySamples.nurlMarkup25Request),
        // Native
        Sample(id: "ortb25-native10-wrapped", title: "OpenRTB 2.5 · Native 1.0 (wrapped) with its request", group: Group.native,
               response: NativeSamples.native10, request: NativeSamples.native10Request),
        Sample(id: "ortb26-native12-eventtrackers", title: "OpenRTB 2.6 · Native 1.2 eventtrackers and privacy", group: Group.native,
               response: NativeSamples.native12, request: NativeSamples.native12Request),
        // Video and audio
        video("ortb26-vast20-inline", "OpenRTB 2.6 · VAST 2.0 inline", vast: VASTSamples.inline20, protocol: 2),
        video("ortb26-vast30-skippable", "OpenRTB 2.6 · VAST 3.0 skippable with progress", vast: VASTSamples.inline30Skippable, protocol: 3),
        video("ortb26-vast40-inline", "OpenRTB 2.6 · VAST 4.0 inline", vast: VASTSamples.inline40, protocol: 7),
        video("ortb26-vast42-verification", "OpenRTB 2.6 · VAST 4.2 AdVerifications and companions", vast: VASTSamples.inline42Verification,
              protocol: 13),
        video("ortb26-vast30-wrapper-chain", "OpenRTB 2.6 · VAST 3.0 wrapper chain (data: URLs)", vast: VASTSamples.wrapperChain30,
              protocol: 6),
        video("ortb26-vast41-ctv-pod", "OpenRTB 2.6 · CTV pod, VAST 4.1 (2 ads)", vast: VASTSamples.pod41, protocol: 11, ctv: true),
        video("ortb26-vast30-vpaid-only", "OpenRTB 2.6 · VAST 3.0 VPAID only (error 403)", vast: VASTSamples.vpaidOnly, protocol: 3),
        Sample(id: "ortb26-audio-vast40", title: "OpenRTB 2.6 · Audio, VAST 4.0", group: Group.video,
               response: VideoSamples.response(id: "ortb26-audio-vast40", markupType: 3, vast: VASTSamples.audio40, protocol: 7, size: nil),
               request: VideoSamples.audioRequest(id: "ortb26-audio-vast40")),
        // OpenRTB 3.0 / AdCOM
        Sample(id: "ortb30-display-banner", title: "OpenRTB 3.0 · AdCOM display banner (image) with events", group: Group.openRTB3,
               response: OpenRTB3Samples.banner),
        Sample(id: "ortb30-display-native", title: "OpenRTB 3.0 · AdCOM display native", group: Group.openRTB3,
               response: OpenRTB3Samples.native),
        Sample(id: "ortb30-display-curl", title: "OpenRTB 3.0 · AdCOM display markup by reference (curl)", group: Group.openRTB3,
               response: OpenRTB3Samples.curl),
        Sample(id: "ortb30-video", title: "OpenRTB 3.0 · AdCOM video, VAST 4.0", group: Group.openRTB3, response: OpenRTB3Samples.video),
        // No bid
        Sample(id: "ortb26-no-bid", title: "No bid · nbr 2 (Invalid Request)", group: Group.noBid,
               response: #"{"id": "ccinn-req-no-bid", "nbr": 2}"#),
    ]

    /// The sample with `id`, if any.
    public static func sample(id: String) -> Sample? {
        all.first { $0.id == id }
    }

    enum Group {
        static let display = "Display"
        static let native = "Native"
        static let video = "Video and audio"
        static let openRTB3 = "OpenRTB 3.0"
        static let noBid = "No bid"
    }

    private static func video(_ id: String, _ title: String, vast: String, protocol vastProtocol: Int, ctv: Bool = false) -> Sample {
        let size = ctv ? AdSize(width: 1920, height: 1080) : AdSize(width: 640, height: 360)
        return Sample(id: id, title: title, group: Group.video,
                      response: VideoSamples.response(id: id, markupType: 2, vast: vast, protocol: vastProtocol, size: size),
                      request: VideoSamples.videoRequest(id: id, size: size, ctv: ctv))
    }
}

// MARK: - Shared pieces

/// JSON text helpers for the hand-laid-out samples.
enum SampleJSON {
    /// `value` as a JSON string literal (quoted and escaped), for markup carried in a string field.
    static func string(_ value: String) -> String {
        JSONValue.string(value).serialized()
    }

    /// A `data:` URL holding `html`, for markup delivered by reference.
    static func htmlDataURL(_ html: String) -> String {
        "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    }

    /// OpenRTB 2.x win, billing and loss notices (one field per line, trailing commas included).
    static let auctionNotices = #"""
              "nurl": "https://tracker.example/rtb/win?auction=${AUCTION_ID}&bid=${AUCTION_BID_ID}&imp=${AUCTION_IMP_ID}&seat=${AUCTION_SEAT_ID}&price=${AUCTION_PRICE}&cur=${AUCTION_CURRENCY}",
              "burl": "https://tracker.example/rtb/bill?auction=${AUCTION_ID}&bid=${AUCTION_BID_ID}&price=${AUCTION_PRICE}",
              "lurl": "https://tracker.example/rtb/loss?auction=${AUCTION_ID}&reason=${AUCTION_LOSS}&min=${AUCTION_MIN_TO_WIN}",
    """#

    /// The app, device and source members of an OpenRTB 2.x sample request (no trailing comma).
    static func requestContext(deviceType: Int, ctv: Bool = false) -> String {
        let app = ctv
            ? #""app": {"id": "ccinn-tv-app", "name": "Ccinn TV", "bundle": "com.example.ccinn.tv", "storeurl": "https://apps.example/ccinn-tv", "publisher": {"id": "pub-1"}}"#
            : #""app": {"id": "ccinn-app", "name": "Ccinn News", "bundle": "com.example.ccinn.news", "domain": "news.example", "storeurl": "https://apps.example/ccinn-news", "publisher": {"id": "pub-1"}}"#
        let device = ctv
            ? #""device": {"devicetype": \#(deviceType), "make": "Apple", "model": "AppleTV", "os": "tvOS", "ifa": "6D92078A-8246-4BA4-AE5B-76104861E7DC", "lmt": 0, "ip": "192.0.2.10"}"#
            : #""device": {"devicetype": \#(deviceType), "make": "Apple", "model": "iPhone", "os": "iOS", "ifa": "6D92078A-8246-4BA4-AE5B-76104861E7DC", "lmt": 0, "ip": "192.0.2.10", "geo": {"lat": 3.139, "lon": 101.6869, "type": 2}}"#
        return """
          \(app),
          \(device),
          "source": {"tid": "ccinn-transaction-1"},
          "cur": ["USD"],
          "tmax": 300
        """
    }
}

// MARK: - Display

enum DisplaySamples {
    static let bannerHTML = #"""
    <a href="https://advertiser.example/landing?src=banner-320x50" target="_blank"><img src="ccinn-sample://image/banner.png" width="320" height="50" alt="Advertisement" style="display:block;border:0"></a><img src="https://tracker.example/creative/pixel?cr=cr-banner-320x50&price=${AUCTION_PRICE}" width="1" height="1" alt="" style="position:absolute;left:-10000px">
    """#

    static let banner25 = #"""
    {
      "id": "ccinn-req-banner-25",
      "bidid": "ccinn-resp-banner-25",
      "cur": "USD",
      "seatbid": [
        {
          "seat": "ccinn-dsp",
          "bid": [
            {
              "id": "bid-banner-1",
              "impid": "1",
              "price": 1.25,
              "adid": "ad-banner-320x50",
    \#(SampleJSON.auctionNotices)
              "adm": \#(SampleJSON.string(bannerHTML)),
              "adomain": ["advertiser.example"],
              "cid": "cmp-1",
              "crid": "cr-banner-320x50",
              "cat": ["IAB3"],
              "w": 320,
              "h": 50
            }
          ]
        }
      ]
    }
    """#

    static let banner25Request = #"""
    {
      "id": "ccinn-req-banner-25",
      "imp": [{"id": "1", "banner": {"w": 320, "h": 50, "format": [{"w": 320, "h": 50}], "api": [3, 5, 6]}, "secure": 1, "bidfloor": 0.5, "bidfloorcur": "USD"}],
    \#(SampleJSON.requestContext(deviceType: 4))
    }
    """#

    static let interstitialHTML = #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="mraid.js"></script>
    <style>
      html, body { margin: 0; height: 100%; background: #101820; }
      #ad { display: flex; height: 100%; align-items: center; justify-content: center; cursor: pointer; }
      #ad img { width: 100%; height: auto; }
    </style>
    </head>
    <body>
    <div id="ad"><img src="ccinn-sample://image/interstitial.png" alt="Advertisement"></div>
    <script>
      var landing = "https://advertiser.example/landing?src=mraid-interstitial";
      function start() {
        console.log("MRAID " + mraid.getVersion() + ", placement " + mraid.getPlacementType() + ", state " + mraid.getState());
        mraid.addEventListener("viewableChange", function (viewable) { console.log("viewable: " + viewable); });
        document.getElementById("ad").addEventListener("click", function () { mraid.open(landing); });
      }
      if (window.mraid) {
        if (mraid.getState() === "loading") { mraid.addEventListener("ready", start); } else { start(); }
      } else {
        document.getElementById("ad").addEventListener("click", function () { window.open(landing); });
      }
    </script>
    </body>
    </html>
    """#

    static let interstitial26 = #"""
    {
      "id": "ccinn-req-interstitial-26",
      "bidid": "ccinn-resp-interstitial-26",
      "cur": "USD",
      "seatbid": [
        {
          "seat": "ccinn-dsp",
          "bid": [
            {
              "id": "bid-interstitial-1",
              "impid": "1",
              "price": 6.4,
              "mtype": 1,
              "adid": "ad-interstitial",
    \#(SampleJSON.auctionNotices)
              "adm": \#(SampleJSON.string(interstitialHTML)),
              "adomain": ["advertiser.example"],
              "cid": "cmp-2",
              "crid": "cr-interstitial-320x480",
              "w": 320,
              "h": 480
            }
          ]
        }
      ]
    }
    """#

    static let interstitial26Request = #"""
    {
      "id": "ccinn-req-interstitial-26",
      "imp": [{"id": "1", "instl": 1, "banner": {"w": 320, "h": 480, "api": [5, 6]}, "secure": 1, "bidfloor": 3, "bidfloorcur": "USD"}],
    \#(SampleJSON.requestContext(deviceType: 4))
    }
    """#

    static let nurlHTML = #"""
    <a href="https://advertiser.example/landing?src=nurl-markup" target="_blank"><img src="ccinn-sample://image/300x250.png" width="300" height="250" alt="Advertisement" style="display:block;border:0"></a>
    """#

    /// OpenRTB 2.5 §6.2-style bid without `adm`: the win notice's response body is the markup.
    static let nurlMarkup25 = #"""
    {
      "id": "ccinn-req-nurl-25",
      "bidid": "ccinn-resp-nurl-25",
      "cur": "USD",
      "seatbid": [
        {
          "seat": "ccinn-dsp",
          "bid": [
            {
              "id": "bid-nurl-1",
              "impid": "1",
              "price": 2.1,
              "nurl": "\#(SampleJSON.htmlDataURL(nurlHTML))",
              "burl": "https://tracker.example/rtb/bill?auction=${AUCTION_ID}&price=${AUCTION_PRICE}",
              "lurl": "https://tracker.example/rtb/loss?auction=${AUCTION_ID}&reason=${AUCTION_LOSS}",
              "adomain": ["advertiser.example"],
              "cid": "cmp-3",
              "crid": "cr-nurl-300x250",
              "w": 300,
              "h": 250
            }
          ]
        }
      ]
    }
    """#

    static let nurlMarkup25Request = #"""
    {
      "id": "ccinn-req-nurl-25",
      "imp": [{"id": "1", "banner": {"w": 300, "h": 250}, "secure": 1}],
    \#(SampleJSON.requestContext(deviceType: 4))
    }
    """#
}

// MARK: - Native

enum NativeSamples {
    /// Native 1.0 response (wrapped, `ver` "1"): no asset types; the request resolves them.
    static let native10Markup = #"""
    {"native":{"ver":"1","assets":[{"id":1,"required":1,"title":{"text":"Explore the night sky tonight"}},{"id":2,"required":1,"img":{"url":"ccinn-sample://image/icon.png","w":80,"h":80}},{"id":3,"required":1,"img":{"url":"ccinn-sample://image/main.png","w":1200,"h":627}},{"id":4,"required":1,"data":{"label":"Sponsored by","value":"Acme Optics"}},{"id":5,"data":{"value":"Telescopes and binoculars for every budget, shipped free."}}],"link":{"url":"https://advertiser.example/landing?src=native-10","clicktrackers":["https://tracker.example/native10/click?price=${AUCTION_PRICE}"]},"imptrackers":["https://tracker.example/native10/impression?price=${AUCTION_PRICE}"],"jstracker":"<script src=\"https://tracker.example/native10/tracker.js\"></script>"}}
    """#

    static let native10RequestMarkup = #"""
    {"native":{"ver":"1","layout":3,"plcmtcnt":1,"assets":[{"id":1,"required":1,"title":{"len":40}},{"id":2,"required":1,"img":{"type":1,"wmin":50,"hmin":50}},{"id":3,"required":1,"img":{"type":3,"wmin":600,"hmin":314}},{"id":4,"required":1,"data":{"type":1,"len":25}},{"id":5,"required":0,"data":{"type":2,"len":140}}]}}
    """#

    static let native10 = #"""
    {
      "id": "ccinn-req-native-10",
      "bidid": "ccinn-resp-native-10",
      "cur": "USD",
      "seatbid": [
        {
          "seat": "ccinn-dsp",
          "bid": [
            {
              "id": "bid-native-10",
              "impid": "1",
              "price": 1.8,
              "adid": "ad-native-10",
    \#(SampleJSON.auctionNotices)
              "adm": \#(SampleJSON.string(native10Markup)),
              "adomain": ["advertiser.example"],
              "cid": "cmp-4",
              "crid": "cr-native-10"
            }
          ]
        }
      ]
    }
    """#

    static let native10Request = #"""
    {
      "id": "ccinn-req-native-10",
      "imp": [{"id": "1", "native": {"request": \#(SampleJSON.string(native10RequestMarkup)), "ver": "1.0"}, "secure": 1}],
    \#(SampleJSON.requestContext(deviceType: 4))
    }
    """#

    /// Native 1.2 response (unwrapped): typed assets, an image-pixel impression (event 1, method 1), a JavaScript MRC 50%
    /// viewability tracker (event 2, method 2) and the privacy (AdChoices) link.
    static let native12Markup = #"""
    {"ver":"1.2","assets":[{"id":1,"required":1,"title":{"text":"Plan your next trip in minutes"}},{"id":2,"img":{"type":1,"url":"ccinn-sample://image/icon.png","w":80,"h":80}},{"id":3,"required":1,"img":{"type":3,"url":"ccinn-sample://image/main.png","w":1200,"h":627}},{"id":4,"data":{"type":1,"value":"Wanderly"}},{"id":5,"data":{"type":2,"value":"Flights, hotels and day trips in one itinerary. Free to try."}},{"id":6,"data":{"type":3,"value":"4.7"}},{"id":7,"data":{"type":12,"value":"Install"}}],"link":{"url":"https://advertiser.example/landing?src=native-12","clicktrackers":["https://tracker.example/native12/click?price=${AUCTION_PRICE}"]},"eventtrackers":[{"event":1,"method":1,"url":"https://tracker.example/native12/impression?price=${AUCTION_PRICE}"},{"event":2,"method":2,"url":"https://tracker.example/native12/viewability.js"}],"privacy":"https://advertiser.example/privacy"}
    """#

    static let native12RequestMarkup = #"""
    {"ver":"1.2","context":2,"contextsubtype":20,"plcmttype":1,"plcmtcnt":1,"assets":[{"id":1,"required":1,"title":{"len":90}},{"id":2,"img":{"type":1,"wmin":50,"hmin":50}},{"id":3,"required":1,"img":{"type":3,"wmin":600,"hmin":314}},{"id":4,"data":{"type":1,"len":25}},{"id":5,"data":{"type":2,"len":140}},{"id":6,"data":{"type":3}},{"id":7,"data":{"type":12,"len":15}}],"eventtrackers":[{"event":1,"methods":[1,2]},{"event":2,"methods":[1,2]}],"privacy":1}
    """#

    static let native12 = #"""
    {
      "id": "ccinn-req-native-12",
      "bidid": "ccinn-resp-native-12",
      "cur": "USD",
      "seatbid": [
        {
          "seat": "ccinn-dsp",
          "bid": [
            {
              "id": "bid-native-12",
              "impid": "1",
              "price": 2.35,
              "mtype": 4,
              "adid": "ad-native-12",
    \#(SampleJSON.auctionNotices)
              "adm": \#(SampleJSON.string(native12Markup)),
              "adomain": ["advertiser.example"],
              "bundle": "com.example.wanderly",
              "cid": "cmp-5",
              "crid": "cr-native-12"
            }
          ]
        }
      ]
    }
    """#

    static let native12Request = #"""
    {
      "id": "ccinn-req-native-12",
      "imp": [{"id": "1", "native": {"request": \#(SampleJSON.string(native12RequestMarkup)), "ver": "1.2"}, "secure": 1}],
    \#(SampleJSON.requestContext(deviceType: 4))
    }
    """#
}

// MARK: - Video and audio (OpenRTB 2.6)

enum VideoSamples {
    /// A 2.6 bid carrying `vast` in `adm`. `protocol` is the OpenRTB "Protocols" value (AdCOM "Creative Subtypes") of the
    /// VAST document: 2 VAST 2.0, 3 VAST 3.0, 6 VAST 3.0 wrapper, 7 VAST 4.0, 11 VAST 4.1, 13 VAST 4.2.
    static func response(id: String, markupType: Int, vast: String, protocol vastProtocol: Int, size: AdSize?) -> String {
        let sizeFields = size.map { #""w": \#($0.width), "h": \#($0.height),"# } ?? ""
        return #"""
        {
          "id": "ccinn-req-\#(id)",
          "bidid": "ccinn-resp-\#(id)",
          "cur": "USD",
          "seatbid": [
            {
              "seat": "ccinn-dsp",
              "bid": [
                {
                  "id": "bid-\#(id)",
                  "impid": "1",
                  "price": 8.5,
                  "mtype": \#(markupType),
                  "adid": "ad-\#(id)",
        \#(SampleJSON.auctionNotices)
                  "adm": \#(SampleJSON.string(vast)),
                  "adomain": ["advertiser.example"],
                  "cid": "cmp-video",
                  "crid": "cr-\#(id)",
                  "protocol": \#(vastProtocol),
                  \#(sizeFields)
                  "cat": ["IAB19"]
                }
              ]
            }
          ]
        }
        """#
    }

    static func videoRequest(id: String, size: AdSize, ctv: Bool) -> String {
        let pod = ctv ? #", "podid": "pod-1", "maxseq": 2, "poddur": 30"# : ""
        return #"""
        {
          "id": "ccinn-req-\#(id)",
          "imp": [{"id": "1", "video": {"mimes": ["video/mp4", "application/x-mpegURL"], "protocols": [2, 3, 5, 6, 7, 8, 11, 12, 13, 14], "w": \#(size.width), "h": \#(size.height), "minduration": 5, "maxduration": 30, "plcmt": 1, "skip": 1, "api": [7]\#(pod)}, "secure": 1, "bidfloor": 4, "bidfloorcur": "USD"}],
        \#(SampleJSON.requestContext(deviceType: ctv ? 3 : 4, ctv: ctv))
        }
        """#
    }

    static func audioRequest(id: String) -> String {
        #"""
        {
          "id": "ccinn-req-\#(id)",
          "imp": [{"id": "1", "audio": {"mimes": ["audio/mp4", "audio/mpeg"], "protocols": [2, 3, 7, 11, 13], "minduration": 5, "maxduration": 30, "feed": 1}, "secure": 1}],
        \#(SampleJSON.requestContext(deviceType: 4))
        }
        """#
    }
}

// MARK: - OpenRTB 3.0 / AdCOM 1.0

enum OpenRTB3Samples {
    static func envelope(id: String, bid: String) -> String {
        #"""
        {
          "openrtb": {
            "ver": "3.0",
            "domainspec": "adcom",
            "domainver": "1.0",
            "response": {
              "id": "ccinn-req-\#(id)",
              "bidid": "ccinn-resp-\#(id)",
              "cur": "USD",
              "seatbid": [
                {
                  "seat": "ccinn-dsp",
                  "bid": [
        \#(bid)
                  ]
                }
              ]
            }
          }
        }
        """#
    }

    /// OpenRTB 3.0 pending (win), billing and loss notices with the 3.0 macro names.
    static let notices = #"""
                  "purl": "https://tracker.example/ortb30/win?auction=${OPENRTB_ID}&bid=${OPENRTB_BID_ID}&item=${OPENRTB_ITEM_ID}&price=${OPENRTB_PRICE}&cur=${OPENRTB_CURRENCY}",
                  "burl": "https://tracker.example/ortb30/bill?auction=${OPENRTB_ID}&price=${OPENRTB_PRICE}",
                  "lurl": "https://tracker.example/ortb30/loss?auction=${OPENRTB_ID}&reason=${OPENRTB_LOSS}&min=${OPENRTB_MIN_TO_WIN}",
    """#

    /// AdCOM display banner (structured image + link) with events 1 (loaded), 2 (impression) and 3 (MRC 50%, JavaScript),
    /// and a buyer macro (`bid.macro` CLICKTOKEN, referenced as `${CUSTOM_CLICKTOKEN}`).
    static let banner = envelope(id: "ortb30-display-banner", bid: #"""
                    {
                      "id": "bid-ortb30-banner",
                      "item": "1",
                      "price": 1.1,
                      "cid": "cmp-30",
                      "mid": "media-ortb30-banner",
    \#(notices)
                      "macro": [{"key": "CLICKTOKEN", "value": "A7D800F2716DB"}],
                      "media": {
                        "ad": {
                          "id": "ad-ortb30-banner",
                          "adomain": ["advertiser.example"],
                          "secure": 1,
                          "display": {
                            "mime": "image/png",
                            "w": 320,
                            "h": 50,
                            "banner": {
                              "img": "ccinn-sample://image/banner.png",
                              "link": {
                                "url": "https://advertiser.example/landing?src=ortb30-banner&tok=${CUSTOM_CLICKTOKEN}",
                                "trkr": ["https://tracker.example/ortb30/click?tok=${CUSTOM_CLICKTOKEN}&price=${OPENRTB_PRICE}"]
                              }
                            },
                            "event": [
                              {"type": 1, "method": 1, "url": "https://tracker.example/ortb30/loaded?media=${OPENRTB_MEDIA_ID}"},
                              {"type": 2, "method": 1, "url": "https://tracker.example/ortb30/impression?price=${OPENRTB_PRICE}"},
                              {"type": 3, "method": 2, "url": "https://tracker.example/ortb30/viewability.js"}
                            ]
                          }
                        }
                      }
                    }
    """#)

    /// AdCOM display native: `asset[]` with title, images, data; a link with trackers; impression and viewability events.
    static let native = envelope(id: "ortb30-display-native", bid: #"""
                    {
                      "id": "bid-ortb30-native",
                      "item": "1",
                      "price": 2.2,
                      "cid": "cmp-31",
    \#(notices)
                      "media": {
                        "ad": {
                          "id": "ad-ortb30-native",
                          "adomain": ["advertiser.example"],
                          "display": {
                            "native": {
                              "link": {"url": "https://advertiser.example/landing?src=ortb30-native", "trkr": ["https://tracker.example/ortb30/native-click"]},
                              "asset": [
                                {"id": 1, "req": 1, "title": {"text": "Cook dinner in 20 minutes"}},
                                {"id": 2, "image": {"url": "ccinn-sample://image/icon.png", "w": 80, "h": 80, "type": 1}},
                                {"id": 3, "req": 1, "image": {"url": "ccinn-sample://image/main.png", "w": 1200, "h": 627, "type": 3}},
                                {"id": 4, "data": {"value": "Fresh Plate", "type": 1}},
                                {"id": 5, "data": {"value": "Recipes and groceries delivered together. First box half price.", "type": 2}},
                                {"id": 6, "data": {"value": "Order now", "type": 12}}
                              ]
                            },
                            "event": [
                              {"type": 2, "method": 1, "url": "https://tracker.example/ortb30/native-impression?price=${OPENRTB_PRICE}"},
                              {"type": 3, "method": 1, "url": "https://tracker.example/ortb30/native-viewable"}
                            ]
                          }
                        }
                      }
                    }
    """#)

    static let curlHTML = #"""
    <a href="https://advertiser.example/landing?src=ortb30-curl" target="_blank"><img src="ccinn-sample://image/300x250.png" width="300" height="250" alt="Advertisement" style="display:block;border:0"></a>
    """#

    /// AdCOM display markup by reference: the app fetches `curl` as a content request in both modes.
    static let curl = envelope(id: "ortb30-display-curl", bid: #"""
                    {
                      "id": "bid-ortb30-curl",
                      "item": "1",
                      "price": 1.4,
                      "cid": "cmp-32",
    \#(notices)
                      "media": {
                        "ad": {
                          "id": "ad-ortb30-curl",
                          "adomain": ["advertiser.example"],
                          "display": {
                            "mime": "text/html",
                            "w": 300,
                            "h": 250,
                            "curl": "\#(SampleJSON.htmlDataURL(curlHTML))",
                            "event": [{"type": 2, "method": 1, "url": "https://tracker.example/ortb30/curl-impression?price=${OPENRTB_PRICE}"}]
                          }
                        }
                      }
                    }
    """#)

    /// AdCOM video carrying VAST 4.0 in `adm` (`ctype` 7 = VAST 4.0).
    static let video = envelope(id: "ortb30-video", bid: #"""
                    {
                      "id": "bid-ortb30-video",
                      "item": "1",
                      "price": 9.75,
                      "cid": "cmp-33",
    \#(notices)
                      "media": {
                        "ad": {
                          "id": "ad-ortb30-video",
                          "adomain": ["advertiser.example"],
                          "video": {
                            "mime": ["video/mp4"],
                            "ctype": 7,
                            "dur": 15,
                            "adm": \#(SampleJSON.string(VASTSamples.inline40))
                          }
                        }
                      }
                    }
    """#)
}
