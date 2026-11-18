import Foundation
import Testing
@testable import RTBKit

/// VAST 4.1 §6.1 / §6.2: the player expands VAST `[…]` macros in the VAST request URIs it calls — a Wrapper's
/// `VASTAdTagURI`, and a VAST tag URL pasted or delivered as AdCOM `curl` — before requesting them. OpenRTB `${…}` is the
/// exchange's (OpenRTB 2.6 §4.4) and stays literal. `data:` URIs carry a document, not a request, and are never
/// expanded. Each hop keeps the URI as written (`template`) and the URL actually requested (`url`).
@Suite("VAST request URIs")
struct VASTRequestURITests {
    static let context = MacroContext(price: 1.23, cacheBuster: "12345678")

    /// Records both forms of each request.
    actor TemplateRecordingFetcher: VASTFetcher {
        private let body: String
        private(set) var requests: [(url: String, template: String)] = []

        init(body: String) {
            self.body = body
        }

        func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
            requests.append((url, url))
            return (body, UUID())
        }

        func fetchVAST(_ url: String, template: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
            requests.append((url, template))
            return (body, UUID())
        }
    }

    @Test func wrapperTagURIExpandsVASTMacrosOnly() async {
        let template = "https://vast.example/inner?cb=[CACHEBUSTING]&p=${AUCTION_PRICE}"
        let requested = "https://vast.example/inner?cb=12345678&p=${AUCTION_PRICE}"
        let fetcher = FakeVASTFetcher([requested: .body(VASTFixture.inline())])
        let vast = await VASTResolver(fetcher: fetcher, macroContext: Self.context).resolve(.xml(VASTFixture.wrapper(name: "w", adTagURI: template)))
        #expect(vast.failure == nil)
        #expect(await fetcher.calls.map(\.url) == [requested])
        #expect(vast.chain.map(\.template) == [nil, template])
        #expect(vast.chain.map(\.url) == [nil, requested])
    }

    @Test func pastedOrCurlTagURLIsExpandedToo() async {
        let template = "https://vast.example/tag?cb=[CACHEBUSTING]&w=[PLAYERSIZE]"
        let requested = "https://vast.example/tag?cb=12345678&w=640,360"
        let fetcher = FakeVASTFetcher([requested: .body(VASTFixture.inline())])
        var context = Self.context
        context.playerWidth = 640
        context.playerHeight = 360
        let vast = await VASTResolver(fetcher: fetcher, macroContext: context).resolve(.url(template))
        #expect(vast.failure == nil)
        #expect(vast.chain.first?.template == template)
        #expect(vast.chain.first?.url == requested)
    }

    /// Without a macro context the resolver requests the URI as written (the behaviour before contexts existed).
    @Test func withoutAContextTheURIIsRequestedAsWritten() async {
        let template = "https://vast.example/tag?cb=[CACHEBUSTING]"
        let fetcher = FakeVASTFetcher([template: .body(VASTFixture.inline())])
        let vast = await VASTResolver(fetcher: fetcher).resolve(.url(template))
        #expect(vast.failure == nil)
        #expect(vast.chain.first?.template == template)
        #expect(vast.chain.first?.url == template)
    }

    @Test func dataURIsAreNeverExpanded() async {
        let inner = VASTFixture.inline().replacingOccurrences(of: "?code=[ERRORCODE]", with: "?code=[ERRORCODE]&cb=[CACHEBUSTING]")
        let dataTag = VASTFixture.dataURL(inner)
        let vast = await VASTResolver(fetcher: FakeVASTFetcher(), macroContext: Self.context).resolve(.xml(VASTFixture.wrapper(name: "w", adTagURI: dataTag)))
        #expect(vast.chain.last?.template == dataTag)
        #expect(vast.chain.last?.url == dataTag)
    }

    /// A fetcher that records requests receives both forms; one that implements only `fetchVAST(_:parentRequestID:)` keeps
    /// working (the protocol's default).
    @Test func templateAwareFetchersReceiveBothForms() async {
        let template = "https://vast.example/tag?cb=[CACHEBUSTING]"
        let fetcher = TemplateRecordingFetcher(body: VASTFixture.inline())
        let vast = await VASTResolver(fetcher: fetcher, macroContext: Self.context).resolve(.url(template))
        #expect(vast.failure == nil)
        let requests = await fetcher.requests
        #expect(requests.map(\.url) == ["https://vast.example/tag?cb=12345678"])
        #expect(requests.map(\.template) == [template])
    }
}
