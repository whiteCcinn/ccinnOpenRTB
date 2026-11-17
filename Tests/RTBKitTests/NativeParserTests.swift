import Foundation
import Testing
@testable import RTBKit

/// Native 1.0 spec example response (§6.3, `ver` as a number) and its request (§6.2).
enum NativeFixtures {
    static let response10 = #"""
    {"native":{"ver":1,
      "link":{"url":"deeplink://deeplink/url/into/app","fallback":"http://i.am.a/URL","clicktrackers":["http://a.com/a","http://b.com/b"]},
      "imptrackers":["http://a.com/a","http://b.com/b"],
      "assets":[
        {"id":1,"title":{"text":"Watch this awesome thing"}},
        {"id":2,"img":{"url":"http://www.myads.com/thumbnail1.png"}},
        {"id":3,"img":{"url":"http://www.myads.com/largethumb1.png"}},
        {"id":4,"data":{"value":"My Brand"}},
        {"id":5,"data":{"value":"Learn all about this awesome story of someone using my product."}}
      ]}}
    """#

    static let request10 = #"""
    {"native":{"ver":"1","layout":6,"assets":[
      {"id":1,"required":1,"title":{"len":25}},
      {"id":2,"required":1,"img":{"type":1,"wmin":50,"hmin":50}},
      {"id":3,"required":1,"img":{"type":3,"wmin":200,"hmin":200}},
      {"id":4,"required":1,"data":{"type":1}},
      {"id":5,"required":0,"data":{"type":2,"len":140}}
    ]}}
    """#

    /// Native 1.2, unwrapped, `ver` as a string, types in the response, event trackers and privacy.
    static let response12 = #"""
    {"ver":"1.2",
     "assets":[
       {"id":1,"required":1,"title":{"text":"Learn about this awesome thing","len":30}},
       {"id":2,"img":{"type":1,"url":"https://cdn.example/icon.png","w":128,"h":128}},
       {"id":3,"img":{"type":3,"url":"https://cdn.example/main.png","w":1200,"h":627}},
       {"id":4,"data":{"type":1,"value":"Acme"}},
       {"id":5,"data":{"type":12,"value":"Install"}},
       {"id":6,"video":{"vasttag":"<VAST version=\"4.0\"></VAST>"}},
       {"id":7,"title":{"text":"Tap me"},"link":{"url":"https://landing.example/asset","clicktrackers":["https://t.example/asset-click"]}}
     ],
     "link":{"url":"https://landing.example/","clicktrackers":["https://t.example/click"]},
     "eventtrackers":[
       {"event":1,"method":1,"url":"https://t.example/imp"},
       {"event":2,"method":2,"url":"https://t.example/viewable.js"},
       {"event":555,"method":1,"url":"https://t.example/custom"}
     ],
     "privacy":"https://privacy.example/"}
    """#
}

@Suite("NativeParser – spec examples")
struct NativeParserSpecTests {
    @Test func native10ResponseWithoutTheRequestInfersTypes() throws {
        let (ad, issues) = NativeParser.parse(NativeFixtures.response10)
        let native = try #require(ad)
        #expect(native.version == "1")
        #expect(native.wrapped)
        #expect(native.assets.map(\.id) == [1, 2, 3, 4, 5])
        #expect(native.link == AdLink(url: "deeplink://deeplink/url/into/app", clickTrackers: ["http://a.com/a", "http://b.com/b"],
                                      fallback: "http://i.am.a/URL"))
        #expect(native.impressionTrackers == ["http://a.com/a", "http://b.com/b"])
        #expect(issues.filter { $0.severity == .error }.isEmpty)

        // Native 1.0 responses carry no types: images and data are inferred and labelled so.
        #expect(native.assets[1].typeSource == .inferred)
        #expect(native.assets[4].typeSource == .inferred)
        if case let .data(_, _, type) = native.assets[4].content { #expect(type == .description) } else { Issue.record("asset 5 is data") }
        // "My Brand" is not convincing either way: no type, and it says so.
        #expect(native.assets[3].typeSource == .unknown)
    }

    @Test func native10ResponseResolvesTypesFromTheRequest() throws {
        var log = IssueLog()
        let hints = try #require(NativeRequestReader.hints(fromRequestString: NativeFixtures.request10, at: .root, log: &log))
        #expect(hints.version == "1")
        #expect(hints.required == [1, 2, 3, 4])
        let (ad, issues) = NativeParser.parse(NativeFixtures.response10, hints: hints)
        let native = try #require(ad)
        #expect(native.assets[1].content == .image(url: "http://www.myads.com/thumbnail1.png", width: nil, height: nil, type: .icon))
        #expect(native.assets[2].content == .image(url: "http://www.myads.com/largethumb1.png", width: nil, height: nil, type: .main))
        #expect(native.assets[3].content == .data(value: "My Brand", label: nil, type: .sponsored))
        #expect(native.assets.dropFirst().allSatisfy { $0.typeSource == .request })
        #expect(native.assets[0].typeSource == .response)
        // Title "Watch this awesome thing" (24) fits len 25.
        #expect(issues.isEmpty)
    }

    @Test func native12UnwrappedWithEventTrackersAndPrivacy() throws {
        let (ad, issues) = NativeParser.parse(NativeFixtures.response12)
        let native = try #require(ad)
        #expect(native.version == "1.2")
        #expect(!native.wrapped)
        #expect(native.assets.count == 7)
        #expect(native.assets[1].content == .image(url: "https://cdn.example/icon.png", width: 128, height: 128, type: .icon))
        #expect(native.assets[1].typeSource == .response)
        #expect(native.assets[4].content == .data(value: "Install", label: nil, type: .callToAction))
        #expect(native.assets[5].vastSource == .xml(#"<VAST version="4.0"></VAST>"#))
        #expect(native.assets[6].link == AdLink(url: "https://landing.example/asset", clickTrackers: ["https://t.example/asset-click"]))
        #expect(native.eventTrackers == [NativeEventTracker(event: 1, method: 1, url: "https://t.example/imp"),
                                         NativeEventTracker(event: 2, method: 2, url: "https://t.example/viewable.js"),
                                         NativeEventTracker(event: 555, method: 1, url: "https://t.example/custom")])
        #expect(native.privacyURL == "https://privacy.example/")
        #expect(issues.isEmpty, "500+ events are exchange-specific, not invalid: \(issues)")
    }

    @Test func versionAsNumberAndOtherFields() throws {
        let json = #"{"native":{"ver":1.1,"assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l.example"},"jstracker":"<script src=\"https://t.example/j.js\"></script>","assetsurl":"https://a.example/assets","dcourl":"https://a.example/dco"}}"#
        let native = try #require(NativeParser.parse(json).ad)
        #expect(native.version == "1.1")
        #expect(native.jsTracker == #"<script src="https://t.example/j.js"></script>"#)
        #expect(native.assetsURL == "https://a.example/assets")
        #expect(native.dcoURL == "https://a.example/dco")
    }

    @Test func dataLabelsFromNative10DriveInference() throws {
        let json = #"{"native":{"link":{"url":"https://l.example"},"assets":[{"id":1,"data":{"label":"Rating","value":"4.5"}},{"id":2,"data":{"label":"Sponsored by","value":"Acme Co"}},{"id":3,"data":{"value":"$1.99"}}]}}"#
        let native = try #require(NativeParser.parse(json).ad)
        #expect(native.assets.map(\.content) == [.data(value: "4.5", label: "Rating", type: .rating),
                                                 .data(value: "Acme Co", label: "Sponsored by", type: .sponsored),
                                                 .data(value: "$1.99", label: nil, type: .price)])
        #expect(native.assets.allSatisfy { $0.typeSource == .inferred })
    }
}

@Suite("NativeParser – AdCOM native")
struct AdcomNativeTests {
    @Test func adcomNativeAliasesAreRead() throws {
        let json = #"""
        {"link":{"url":"https://l.example","urlfb":"https://fb.example","trkr":["https://t.example/c"]},
         "asset":[{"id":1,"req":1,"title":{"text":"Hello"}},
                  {"id":2,"image":{"url":"https://cdn.example/m.png","w":1200,"h":627,"type":3}},
                  {"id":3,"img":{"url":"https://cdn.example/i.png","w":100,"h":100,"type":1}},
                  {"id":4,"video":{"curl":"https://vast.example/tag"}},
                  {"id":5,"data":{"value":"Acme","type":1}}]}
        """#
        let (ad, issues) = NativeParser.parse(json)
        let native = try #require(ad)
        #expect(issues.isEmpty)
        #expect(native.link == AdLink(url: "https://l.example", clickTrackers: ["https://t.example/c"], fallback: "https://fb.example"))
        #expect(native.assets[0].required)
        #expect(native.assets[1].content == .image(url: "https://cdn.example/m.png", width: 1200, height: 627, type: .main))
        #expect(native.assets[3].vastSource == .url("https://vast.example/tag"))
        #expect(native.version == nil)
    }
}

@Suite("Native validation")
struct NativeValidationTests {
    private func codes(_ json: String, hints: NativeRequestHints? = nil) -> [String] {
        NativeParser.parse(json, hints: hints).issues.map(\.code)
    }

    private func issue(_ code: String, in json: String, hints: NativeRequestHints? = nil) -> ValidationIssue? {
        NativeParser.parse(json, hints: hints).issues.first { $0.code == code }
    }

    @Test func missingAssetsIsAnError() throws {
        let found = try #require(issue("native.assets.missing", in: #"{"native":{"link":{"url":"https://l.example"}}}"#))
        #expect(found.severity == .error)
        #expect(found.path == "/native/assets")
        // `assetsurl` / `dcourl` deliver assets by reference.
        #expect(!codes(#"{"native":{"link":{"url":"https://l.example"},"assetsurl":"https://a.example"}}"#).contains("native.assets.missing"))
    }

    @Test func missingLinkIsAnError() throws {
        let found = try #require(issue("native.link.missing", in: #"{"native":{"assets":[{"id":1,"title":{"text":"T"}}]}}"#))
        #expect(found.severity == .error)
        #expect(found.path == "/native/link")
    }

    @Test func emptyLinkURLIsAnError() throws {
        let found = try #require(issue("native.link.url.empty", in: #"{"assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"  "}}"#))
        #expect(found.severity == .error)
        #expect(found.path == "/link/url")
    }

    @Test func invalidEventTrackerEventAndMethodAreWarnings() throws {
        let json = #"{"ver":"1.2","assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l"},"eventtrackers":[{"event":7,"method":3,"url":"https://t.example"}]}"#
        let event = try #require(issue("native.eventtracker.event.invalid", in: json))
        let method = try #require(issue("native.eventtracker.method.invalid", in: json))
        #expect(event.severity == .warning)
        #expect(event.path == "/eventtrackers/0/event")
        #expect(method.path == "/eventtrackers/0/method")
    }

    @Test func requiredRequestAssetMissingIsAnError() throws {
        let hints = NativeRequestHints(assets: [1: .title(maxLength: 90), 2: .image(type: .main, width: nil, height: nil)], required: [1, 2])
        let found = try #require(issue("native.asset.required.missing", in: #"{"assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l"}}"#,
                                       hints: hints))
        #expect(found.severity == .error)
        #expect(found.message.contains("asset 2"))
    }

    @Test func titleOverRequestLengthIsAWarning() throws {
        let hints = NativeRequestHints(assets: [1: .title(maxLength: 5)])
        let found = try #require(issue("native.title.length", in: #"{"assets":[{"id":1,"title":{"text":"Too long"}}],"link":{"url":"https://l"}}"#,
                                       hints: hints))
        #expect(found.severity == .warning)
        #expect(found.path == "/assets/0/title/text")
    }

    @Test func duplicateAssetIDsAreAWarning() throws {
        let found = try #require(issue("native.asset.id.duplicate",
                                       in: #"{"assets":[{"id":1,"title":{"text":"A"}},{"id":1,"data":{"value":"B"}}],"link":{"url":"https://l"}}"#))
        #expect(found.severity == .warning)
        #expect(found.path == "/assets/1/id")
    }

    @Test func native10WithoutTheWrapperIsInfo() throws {
        let found = try #require(issue("native.wrapper.missing", in: #"{"ver":"1.0","assets":[{"id":1,"title":{"text":"A"}}],"link":{"url":"https://l"}}"#))
        #expect(found.severity == .info)
        #expect(!codes(#"{"ver":"1.2","assets":[{"id":1,"title":{"text":"A"}}],"link":{"url":"https://l"}}"#).contains("native.wrapper.missing"))
    }

    @Test func versionSpecificFields() {
        let old = codes(#"{"native":{"ver":"1.1","assets":[{"id":1,"title":{"text":"A"}}],"link":{"url":"https://l"},"eventtrackers":[{"event":1,"method":1,"url":"https://t"}],"privacy":"https://p"}}"#)
        #expect(old.contains("native.eventtrackers.version"))
        #expect(old.contains("native.privacy.version"))
        let new = codes(#"{"ver":"1.2","assets":[{"id":1,"title":{"text":"A"}}],"link":{"url":"https://l"},"imptrackers":["https://t"],"jstracker":"<script></script>"}"#)
        #expect(new.contains("native.imptrackers.deprecated"))
        #expect(new.contains("native.jstracker.deprecated"))
    }

    @Test func assetTypeMismatchAgainstTheRequest() {
        let hints = NativeRequestHints(assets: [1: .image(type: .main, width: 1200, height: 627)])
        #expect(codes(#"{"assets":[{"id":1,"title":{"text":"A"}}],"link":{"url":"https://l"}}"#, hints: hints).contains("native.asset.type.mismatch"))
    }

    @Test func malformedInputNeverCrashesAndIsReported() {
        #expect(NativeParser.parse("not json").ad == nil)
        #expect(NativeParser.parse("not json").issues.map(\.code) == ["native.json.invalid"])
        #expect(NativeParser.parse("[1,2]").ad == nil)
        #expect(NativeParser.parse(#"{"native":7}"#).ad == nil)
        // Wrong types are coerced or skipped with warnings, never fatal.
        let (ad, issues) = NativeParser.parse(#"{"native":{"ver":true,"assets":[7,{"id":"3","title":{"text":5}},{"id":4}],"link":{"url":"https://l","clicktrackers":"https://c"},"imptrackers":[1,"https://i"]}}"#)
        #expect(ad?.assets.map(\.id) == [3])
        #expect(ad?.assets.first?.content == .title(text: "5"))
        #expect(ad?.link.clickTrackers == ["https://c"])
        #expect(ad?.impressionTrackers == ["https://i"])
        #expect(issues.contains { $0.code == "native.type.mismatch" })
        #expect(issues.contains { $0.code == "native.asset.content.missing" && $0.path == "/native/assets/2" })
    }

    @Test func doubleEncodedWrapperIsAccepted() throws {
        let json = #"{"native":"{\"assets\":[{\"id\":1,\"title\":{\"text\":\"A\"}}],\"link\":{\"url\":\"https://l\"}}"}"#
        let (ad, issues) = NativeParser.parse(json)
        #expect(try #require(ad).assets.count == 1)
        #expect(issues.map(\.code) == ["native.type.mismatch"])
    }
}
