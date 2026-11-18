import Foundation
import Testing
@testable import RTBKit

/// VAST 4.1 Wrapper `<BlockedAdCategories>` (§3.19.2; `authority` attribute): ad categories the wrapper does not accept
/// from the ad servers below it. An InLine ad whose `<Category>` (§3.4.5) matches one — same code, and the same
/// authority when both name one — is not used, and its Error URLs fire with 205 "Inline Category violates Wrapper
/// BlockedAdCategories (refer 3.19.2)" (VAST 4.1 §2.3.6.3), like any other resolution failure.
@Suite("VAST BlockedAdCategories")
struct VASTBlockedCategoryTests {
    private typealias F = VASTFixture
    static let authority = "https://www.iabtechlab.com/categoryauthority"

    static func wrapper(blocking blocked: String, adTagURI: String, attributes: String = "") -> String {
        F.wrapper(version: "4.1", name: "w", adTagURI: adTagURI, attributes: attributes)
            .replacingOccurrences(of: "<AdSystem>Fixture</AdSystem>", with: "<AdSystem>Fixture</AdSystem>" + blocked)
    }

    static func inline(name: String = "in", sequence: Int? = nil, category: String?) -> String {
        F.inlineAd(id: name, sequence: sequence, name: name, extraInline: category ?? "", universalAdId: true)
    }

    static func blocking(_ codes: String, authority: String? = authority) -> String {
        "<BlockedAdCategories\(authority.map { " authority=\"\($0)\"" } ?? "")>\(codes)</BlockedAdCategories>"
    }

    static func category(_ code: String, authority: String? = authority) -> String {
        "<Category\(authority.map { " authority=\"\($0)\"" } ?? "")>\(code)</Category>"
    }

    static func resolve(wrapper blocked: String, inner: String, attributes: String = "") async -> ResolvedVAST {
        await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(wrapper(blocking: blocked, adTagURI: F.dataURL(inner), attributes: attributes)))
    }

    @Test func blockedCategoriesAreParsedOnWrappers() throws {
        let xml = Self.wrapper(blocking: Self.blocking("IAB8-5, IAB8-18") + Self.blocking("IAB7", authority: nil), adTagURI: "https://vast.example/t")
        let (document, issues) = VASTParser.parse(xml)
        guard case let .wrapper(wrapper) = try #require(document?.ads.first).body else {
            Issue.record("expected a wrapper")
            return
        }
        #expect(wrapper.blockedAdCategories == [VASTCategory(code: "IAB8-5", authority: Self.authority),
                                                VASTCategory(code: "IAB8-18", authority: Self.authority), VASTCategory(code: "IAB7")])
        #expect(!issues.contains { $0.code == "vast.element.unknown" })
        let empty = VASTParser.parse(Self.wrapper(blocking: "<BlockedAdCategories/>", adTagURI: "https://vast.example/t")).issues
        #expect(empty.contains { $0.code == "vast.wrapper.blockedAdCategories.empty" })
    }

    @Test func aBlockedInlineAdIsNotUsedAndFires205() async throws {
        let vast = await Self.resolve(wrapper: Self.blocking("IAB8-5"), inner: F.document(version: "4.1", ads: [Self.inline(category: Self.category("IAB8-5"))]))
        #expect(vast.ads.isEmpty)
        #expect(vast.failure == .blockedAdCategory)
        #expect(vast.failureErrorURLs == [F.url("w", "error?code=[ERRORCODE]"), F.url("in", "error?code=[ERRORCODE]")])
        let issue = try #require(vast.issues.first { $0.code == "vast.category.blocked" })
        #expect(issue.path == "hop 1 › VAST/Ad[1]/InLine/Category[1]")
        #expect(issue.message.contains("205"))
        let requests = VASTTrackingPlan.requests(for: .error(.blockedAdCategory, adIndex: nil), vast: vast, candidate: nil,
                                                 context: MacroContext(cacheBuster: "1"), source: "bid 0.0")
        #expect(requests.map(\.url) == [F.url("w", "error?code=205"), F.url("in", "error?code=205")])
    }

    /// Matching is by code; authorities must agree only when both are given.
    @Test func matchingRules() async {
        func plays(_ blocked: String, _ category: String) async -> Bool {
            let vast = await Self.resolve(wrapper: blocked, inner: F.document(version: "4.1", ads: [Self.inline(category: category)]))
            return vast.ads.count == 1
        }
        #expect(await plays(Self.blocking("IAB8-5"), Self.category("IAB8-6")))
        #expect(await plays(Self.blocking("IAB8-5"), Self.category("IAB8-5", authority: "https://other.example/taxonomy")))
        #expect(await !plays(Self.blocking("IAB8-5"), Self.category("IAB8-5", authority: nil)))
        #expect(await !plays(Self.blocking("IAB8-5", authority: nil), Self.category("IAB8-5")))
        #expect(await !plays(Self.blocking("iab8-5"), Self.category("IAB8-5", authority: Self.authority + "/")))
    }

    /// In a pod the blocked slot is an ad failure (its Error URLs fire after resolution); the others play.
    @Test func aBlockedPodSlotIsAnAdFailure() async throws {
        let pod = F.document(version: "4.1", ads: [Self.inline(name: "ok", sequence: 1, category: Self.category("IAB1")),
                                                   Self.inline(name: "bad", sequence: 2, category: Self.category("IAB8-5"))])
        let vast = await Self.resolve(wrapper: Self.blocking("IAB8-5"), inner: pod, attributes: #"allowMultipleAds="true""#)
        #expect(vast.ads.map(\.inline.adTitle) == ["ok"])
        #expect(vast.adFailures.map(\.code) == [.blockedAdCategory])
        #expect(vast.adFailures.first?.errorURLs == [F.url("w", "error?code=[ERRORCODE]"), F.url("bad", "error?code=[ERRORCODE]")])
    }

    /// Without a `<Category>` the ad cannot be checked: it plays, and the report names 204 "Ad category was required but
    /// not provided" for players that insist.
    @Test func anUncategorisedAdUnderABlockingWrapperPlaysWithAWarning() async throws {
        let vast = await Self.resolve(wrapper: Self.blocking("IAB8-5"), inner: F.document(version: "4.1", ads: [Self.inline(category: nil)]))
        #expect(vast.ads.count == 1)
        let issue = try #require(vast.issues.first { $0.code == "vast.category.unverifiable" })
        #expect(issue.severity == .warning)
        #expect(issue.message.contains("204"))
    }
}
