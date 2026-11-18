import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// Native 1.2 `assetsurl` (§5.1: the response mirrors the `assets` array) and `dcourl` (DCO, beta: not supported).
@MainActor
@Suite("Native assetsurl")
struct NativeAssetsURLTests {
    private static let assetsURL = "https://dsp.example/assets?id=1"

    /// A minimal parser (titles and data assets only) for the model's own behaviour: what it does with the parser's
    /// assets and issues. The production parser is covered by `theDefaultParserIsTheKitsNativeParser`.
    private static let fakeParser: NativeAssetsParser = { json in
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]] else {
            return (nil, [ValidationIssue(.error, code: "fake.invalid", message: "not a Native object", path: "")])
        }
        let parsed = assets.compactMap { asset -> NativeAsset? in
            guard let id = asset["id"] as? Int else { return nil }
            if let title = asset["title"] as? [String: Any], let text = title["text"] as? String {
                return NativeAsset(id: id, content: .title(text: text))
            }
            if let data = asset["data"] as? [String: Any], let value = data["value"] as? String {
                return NativeAsset(id: id, content: .data(value: value, label: nil, type: (data["type"] as? Int).flatMap(NativeDataType.init)))
            }
            return nil
        }
        return (parsed, [ValidationIssue(.warning, code: "fake.note", message: "a parser note", path: "/assets"),
                         ValidationIssue(.error, code: "fake.link", message: "link is missing", path: "/link")])
    }

    private func model(_ ad: NativeAd, host: RecordingHost) -> NativeAdModel {
        NativeAdModel(ad: ad, request: RendererFixtures.request(.native("{}"), format: .native, native: ad, placement: .inFeed), host: host,
                      parseAssets: Self.fakeParser)
    }

    private static let byURL = NativeAd(version: "1.2", assets: [], link: AdLink(url: "https://adv.example/"), assetsURL: assetsURL)

    @Test func assetsAreFetchedAsContentParsedAndThenRendered() async {
        let host = RecordingHost()
        host.contents[Self.assetsURL] = Data(#"{"assets":[{"id":1,"title":{"text":"Fetched title"}},{"id":2,"data":{"type":12,"value":"Install"}}]}"#.utf8)
        let model = model(Self.byURL, host: host)
        #expect(model.assets == .loading)
        model.appeared()
        #expect(host.events.isEmpty, "nothing to show yet: no impression before the assets arrive")
        await model.loadAssets()
        #expect(model.assets == .ready)
        #expect(host.fetches == [.init(url: Self.assetsURL, trigger: "Native assetsurl", source: "bid 0.0 › native › assetsurl")])
        #expect(model.content.title?.text == "Fetched title")
        #expect(model.content.callToAction?.text == "Install")
        #expect(host.events == [.rendered], "rendered once the fetched assets are shown")
        model.appeared()
        await model.loadAssets()
        #expect(host.events == [.rendered])
        #expect(host.fetches.count == 1)
        #expect(host.logs.contains { $0.origin == "Native" && $0.level == .warning && $0.message.contains("a parser note") })
        #expect(!host.logs.contains { $0.message.contains("link is missing") }, "issues of the synthetic wrapper are not the DSP's")
    }

    @Test func theResponseMayBeWrappedOrABareArray() throws {
        let inner = #"[{"id":1,"title":{"text":"x"}}]"#
        for body in [#"{"assets":\#(inner)}"#, #"{"native":{"assets":\#(inner)}}"#, inner] {
            let document = try NativeAssetsDocument.nativeJSON(from: Data(body.utf8), version: "1.2").get()
            let object = try #require(try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any])
            #expect((object["assets"] as? [Any])?.count == 1, "\(body)")
            #expect(object["ver"] as? String == "1.2")
        }
        for body in [#"{"title":"no assets"}"#, "not json", #"{"assets":"x"}"#, "", #"{"assets":[]}"#] {
            #expect(throws: NativeAssetsDocument.Failure.self, "\(body)") { try NativeAssetsDocument.nativeJSON(from: Data(body.utf8), version: nil).get() }
        }
    }

    @Test func aFailedFetchShowsTheErrorAndIsNotRendered() async {
        let host = RecordingHost()
        let model = model(Self.byURL, host: host)
        model.appeared()
        await model.loadAssets()
        guard case let .failed(message) = model.assets else {
            Issue.record("expected a failure, got \(model.assets)")
            return
        }
        #expect(!message.isEmpty)
        #expect(host.events.isEmpty)
        #expect(host.logs.contains { $0.origin == "Native" && $0.level == .error && $0.message.contains("assetsurl") })
    }

    @Test func anUnparsableResponseShowsTheError() async {
        let host = RecordingHost()
        host.contents[Self.assetsURL] = Data(#"{"assets":[{"id":"one"}]}"#.utf8)
        let model = model(Self.byURL, host: host)
        model.appeared()
        await model.loadAssets()
        if case .failed = model.assets {} else { Issue.record("no renderable asset is a failure: \(model.assets)") }
        #expect(host.events.isEmpty)
        #expect(host.logs.contains { $0.level == .error })
    }

    @Test func inlineAssetsWin() async {
        let host = RecordingHost()
        var ad = Self.byURL
        ad.assets = [NativeAsset(id: 1, content: .title(text: "Inline"))]
        let model = model(ad, host: host)
        #expect(model.assets == .ready)
        model.appeared()
        await model.loadAssets()
        #expect(host.fetches.isEmpty)
        #expect(model.content.title?.text == "Inline")
        #expect(host.events == [.rendered])
        #expect(host.logs.contains { $0.level == .info && $0.message.contains("assetsurl") && $0.message.contains("inline") })
    }

    /// The default seam is kit-openrtb's `NativeParser`: a spec-shaped `assetsurl` response (1.2 §5.1, where `img.type`
    /// and `data.type` are required) renders its title, images and data with no slot inferred, and the synthetic
    /// wrapper's own gaps (no `link`, no trackers) are not reported as the DSP's.
    @Test func theDefaultParserIsTheKitsNativeParser() async throws {
        let body = #"""
        {"assets":[{"id":1,"title":{"text":"Real title"}},
                   {"id":2,"img":{"type":3,"url":"https://cdn.example/main.png","w":1200,"h":627}},
                   {"id":3,"img":{"type":1,"url":"https://cdn.example/icon.png","w":80,"h":80}},
                   {"id":4,"data":{"type":2,"value":"Body text"}},
                   {"id":5,"data":{"type":12,"value":"Install"}}]}
        """#
        let json = try NativeAssetsDocument.nativeJSON(from: Data(body.utf8), version: "1.2").get()
        let kit = NativeParser.parse(json)
        let seam = NativeAssetsDocument.defaultParser(json)
        #expect(seam.assets == kit.ad?.assets)
        #expect(seam.issues == kit.issues)

        let host = RecordingHost()
        host.contents[Self.assetsURL] = Data(body.utf8)
        let model = NativeAdModel(ad: Self.byURL, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.byURL,
                                                                                    placement: .inFeed), host: host)
        model.appeared()
        await model.loadAssets()
        await model.loadImages()
        #expect(model.assets == .ready)
        #expect(model.content.title?.text == "Real title")
        #expect(model.content.mainImage?.url == "https://cdn.example/main.png")
        #expect(model.content.icon?.url == "https://cdn.example/icon.png")
        #expect(model.content.body?.text == "Body text")
        #expect(model.content.callToAction?.text == "Install")
        #expect(model.content.inferredAssetIDs.isEmpty)
        #expect(host.events == [.rendered])
        #expect(!host.logs.contains { $0.level == .error }, "\(host.logs.map(\.message))")
        #expect(!host.logs.contains { $0.message.contains("/link") })
    }

    /// The kit's parser is lenient (design D3): an asset whose `id` is the wrong type still renders, and the type mismatch
    /// is logged at the asset's pointer; a response whose assets carry no content has nothing to render and fails.
    @Test func theKitsParserIsLenientButNeedsContent() async {
        func load(_ body: String) async -> (NativeAdModel, RecordingHost) {
            let host = RecordingHost()
            host.contents[Self.assetsURL] = Data(body.utf8)
            let model = NativeAdModel(ad: Self.byURL, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.byURL,
                                                                                        placement: .inFeed), host: host)
            model.appeared()
            await model.loadAssets()
            return (model, host)
        }
        let (lenient, lenientHost) = await load(#"{"assets":[{"id":"one","title":{"text":"Still shown"}}]}"#)
        #expect(lenient.assets == .ready)
        #expect(lenient.content.title?.text == "Still shown")
        #expect(lenientHost.events == [.rendered])
        #expect(lenientHost.logs.contains { $0.level != .info && $0.message.contains("/assets/0/id") }, "\(lenientHost.logs.map(\.message))")

        let (empty, emptyHost) = await load(#"{"assets":[{"id":1}]}"#)
        if case .failed = empty.assets {} else { Issue.record("expected a failure, got \(empty.assets)") }
        #expect(emptyHost.events.isEmpty)
    }

    @Test func dcoURLIsNotFetched() async {
        let host = RecordingHost()
        let ad = NativeAd(version: "1.2", assets: [NativeAsset(id: 1, content: .title(text: "Inline"))], link: AdLink(url: "https://adv.example/"),
                          dcoURL: "https://dco.example/x")
        let model = model(ad, host: host)
        model.appeared()
        await model.loadAssets()
        #expect(host.fetches.isEmpty)
        #expect(host.logs.contains { $0.level == .info && $0.message.contains("dcourl") && $0.message.contains("not supported") })
    }
}
