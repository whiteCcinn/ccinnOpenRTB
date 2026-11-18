import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// Native 1.2 `assetsurl` (§5.1: the response mirrors the `assets` array) and `dcourl` (DCO, beta: not supported).
@MainActor
@Suite("Native assetsurl")
struct NativeAssetsURLTests {
    private static let assetsURL = "https://dsp.example/assets?id=1"

    /// Stands in for kit-openrtb's `NativeParser` (a placeholder on this branch): titles and data assets only.
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
