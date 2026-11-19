import Foundation
import Testing
@testable import RTBKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func url(_ text: String) -> URL { URL(string: text)! }
private func context(_ publisher: String, _ policy: CookiePolicy) -> CookieContext {
    CookieContext(topLevelSite: CookieSite(url: url(publisher))!, policy: policy)
}

/// A page on news.example.
private func context(_ policy: CookiePolicy) -> CookieContext { context("https://news.example", policy) }

@Suite("Cookies: dates (RFC 6265 §5.1.1)")
struct CookieDateTests {
    @Test(arguments: ["Wed, 21 Oct 2026 07:28:00 GMT", "Wednesday, 21-Oct-26 07:28:00 GMT", "Wed Oct 21 07:28:00 2026", "21 Oct 2026 07:28:00",
                      "Wed, 21-Oct-2026 07:28:00 GMT"])
    func everyFormatBrowsersAcceptParses(text: String) throws {
        let date = try #require(CookieDate.parse(text))
        #expect(date == Date(timeIntervalSince1970: 1_792_567_680))
    }

    @Test(arguments: ["", "tomorrow", "Wed, 32 Oct 2026 07:28:00 GMT", "Wed, 21 Foo 2026 07:28:00 GMT", "Wed, 21 Oct 1500 07:28:00 GMT",
                      "Wed, 21 Oct 2026 25:00:00 GMT"])
    func invalidDatesAreIgnored(text: String) {
        #expect(CookieDate.parse(text) == nil)
    }

    /// Two-digit years: 70–99 are 19xx, 00–69 are 20xx.
    @Test func twoDigitYears() throws {
        #expect(try #require(CookieDate.parse("01-Jan-99 00:00:00 GMT")) == Date(timeIntervalSince1970: 915_148_800))
        #expect(try #require(CookieDate.parse("01-Jan-30 00:00:00 GMT")) == Date(timeIntervalSince1970: 1_893_456_000))
    }
}

@Suite("Cookies: sites")
struct CookieSiteTests {
    @Test func registrableDomains() {
        #expect(CookieSite.registrableDomain(of: "a.b.dsp.example") == "dsp.example")
        #expect(CookieSite.registrableDomain(of: "WWW.News.Co.UK") == "news.co.uk")
        #expect(CookieSite.registrableDomain(of: "dsp.example") == "dsp.example")
        #expect(CookieSite.registrableDomain(of: "localhost") == "localhost")
        #expect(CookieSite.registrableDomain(of: "127.0.0.1") == "127.0.0.1")
        #expect(CookieSite.isPublicSuffix("co.uk"))
        #expect(CookieSite.isPublicSuffix("com"))
        #expect(!CookieSite.isPublicSuffix("dsp.example"))
    }

    /// Schemeful same-site: http and https of one domain are different sites.
    @Test func sitesCompareSchemeAndRegistrableDomain() {
        #expect(CookieSite(url: url("https://a.news.example/x")) == CookieSite(url: url("https://b.news.example/y")))
        #expect(CookieSite(url: url("http://news.example")) != CookieSite(url: url("https://news.example")))
        #expect(CookieSite(url: url("data:,x")) == nil)
    }
}

@Suite("Cookies: Set-Cookie")
struct SetCookieTests {
    private func receive(_ line: String, from origin: String = "https://sync.dsp.example/pixel", _ policy: CookiePolicy = .allowThirdParty,
                         publisher: String = "https://news.example") -> (CookieJar, CookieDecision) {
        var jar = CookieJar()
        let decisions = jar.receive([line], from: url(origin), context: context(publisher, policy), now: now)
        return (jar, decisions[0])
    }

    @Test func aThirdPartyCookieWithSameSiteNoneAndSecureIsStored() throws {
        let (jar, decision) = receive("uid=abc123; Domain=.dsp.example; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=None")
        guard case let .stored(cookie) = decision else { Issue.record("\(decision)"); return }
        #expect(cookie.name == "uid")
        #expect(cookie.value == "abc123")
        #expect(cookie.domain == "dsp.example")
        #expect(!cookie.hostOnly)
        #expect(cookie.path == "/")
        #expect(cookie.expires == now.addingTimeInterval(3600))
        #expect(cookie.secure && cookie.httpOnly)
        #expect(cookie.sameSite == .none)
        #expect(cookie.partitionSite == nil)
        #expect(jar.cookies.count == 1)
    }

    @Test func withoutDomainTheCookieIsHostOnlyAndThePathIsTheRequestDirectory() throws {
        let (_, decision) = receive("uid=1; Secure; SameSite=None", from: "https://sync.dsp.example/a/b/pixel?x=1")
        guard case let .stored(cookie) = decision else { Issue.record("\(decision)"); return }
        #expect(cookie.hostOnly)
        #expect(cookie.domain == "sync.dsp.example")
        #expect(cookie.path == "/a/b")
        #expect(cookie.expires == nil, "a session cookie")
    }

    /// rfc6265bis: `SameSite=None` requires `Secure`.
    @Test func sameSiteNoneWithoutSecureIsRejected() {
        #expect(receive("uid=1; SameSite=None").1 == .rejected(name: "uid", reason: .sameSiteNoneWithoutSecure))
    }

    /// Chrome treats a cookie without SameSite as Lax, and a Lax / Strict cookie from a cross-site subresource response is
    /// not stored.
    @Test(arguments: ["uid=1; Secure", "uid=1; Secure; SameSite=Lax", "uid=1; Secure; SameSite=Strict"])
    func laxOrStrictFromACrossSiteResponseIsRejected(line: String) {
        let decision = receive(line).1
        guard case let .rejected(name, .sameSiteCrossSite(sameSite)) = decision else { Issue.record("\(decision)"); return }
        #expect(name == "uid")
        #expect(sameSite != .none)
    }

    /// WebKit (Safari, in-app web views — the iPhone default) blocks third-party cookies: nothing is stored.
    @Test func blockingThirdPartyCookiesRejectsEvenSameSiteNone() {
        #expect(receive("uid=1; Secure; SameSite=None", .blockThirdParty).1 == .rejected(name: "uid", reason: .thirdPartyBlocked))
    }

    /// The same site as the page is first party: stored whatever the policy.
    @Test func aFirstPartyCookieIsStoredUnderEveryPolicy() {
        for policy in CookiePolicy.allCases {
            guard case .stored = receive("sid=1; Secure; SameSite=Lax", from: "https://www.news.example/", policy).1 else {
                Issue.record("\(policy)")
                continue
            }
        }
    }

    /// Firefox Total Cookie Protection / CHIPS: the third-party cookie is kept for this top-level site only.
    @Test func partitionedPolicyKeysTheCookieByTheTopLevelSite() throws {
        let (_, decision) = receive("uid=1; Secure; SameSite=None", .partitioned)
        guard case let .stored(cookie) = decision else { Issue.record("\(decision)"); return }
        #expect(cookie.partitionSite == CookieSite(url: url("https://news.example")))
    }

    @Test func aPartitionedAttributeNeedsSecure() {
        #expect(receive("uid=1; SameSite=None; Partitioned").1 == .rejected(name: "uid", reason: .partitionedWithoutSecure))
        guard case let .stored(cookie) = receive("uid=1; Secure; SameSite=None; Partitioned").1 else { Issue.record("not stored"); return }
        #expect(cookie.partitionSite != nil, "CHIPS under the allow policy")
    }

    @Test func domainAttributesMustCoverTheHostAndNotBeAPublicSuffix() {
        #expect(receive("uid=1; Domain=other.example; Secure; SameSite=None").1 == .rejected(name: "uid", reason: .domainMismatch("other.example")))
        #expect(receive("uid=1; Domain=example; Secure; SameSite=None").1 == .rejected(name: "uid", reason: .publicSuffix("example")))
        #expect(receive("uid=1; Domain=co.uk; Secure; SameSite=None", from: "https://dsp.co.uk/").1 == .rejected(name: "uid", reason: .publicSuffix("co.uk")))
    }

    @Test func secureCookiesCannotComeFromHTTP() {
        #expect(receive("uid=1; Secure; SameSite=None", from: "http://sync.dsp.example/").1 == .rejected(name: "uid", reason: .secureFromInsecureOrigin))
    }

    @Test func prefixesAreEnforced() {
        #expect(receive("__Secure-uid=1; SameSite=None").1 == .rejected(name: "__Secure-uid", reason: .sameSiteNoneWithoutSecure))
        #expect(receive("__Secure-uid=1; SameSite=Lax", from: "https://www.news.example/").1 == .rejected(name: "__Secure-uid", reason: .prefix("__Secure-")))
        #expect(receive("__Host-uid=1; Secure; Domain=news.example; Path=/", from: "https://www.news.example/").1
            == .rejected(name: "__Host-uid", reason: .prefix("__Host-")))
        guard case .stored = receive("__Host-uid=1; Secure; Path=/", from: "https://www.news.example/").1 else { Issue.record("not stored"); return }
    }

    @Test func malformedAndOversizedCookiesAreRejected() {
        #expect(receive("no-equals-sign").1 == .rejected(name: "", reason: .malformed))
        #expect(receive("=value").1 == .rejected(name: "", reason: .malformed))
        let huge = "uid=" + String(repeating: "x", count: 4_100) + "; Secure; SameSite=None"
        #expect(receive(huge).1 == .rejected(name: "uid", reason: .tooLarge))
    }

    @Test func anExpiredCookieDeletesTheStoredOne() {
        var jar = CookieJar()
        let ctx = context(.allowThirdParty)
        _ = jar.receive(["uid=1; Secure; SameSite=None"], from: url("https://sync.dsp.example/"), context: ctx, now: now)
        let decisions = jar.receive(["uid=; Max-Age=0; Secure; SameSite=None"], from: url("https://sync.dsp.example/"), context: ctx, now: now)
        #expect(decisions == [.deleted(name: "uid")])
        #expect(jar.cookies.isEmpty)
    }

    @Test func aSecondSetCookieReplacesTheFirstAndKeepsItsCreationTime() throws {
        var jar = CookieJar()
        let ctx = context(.allowThirdParty)
        _ = jar.receive(["uid=1; Secure; SameSite=None"], from: url("https://sync.dsp.example/"), context: ctx, now: now)
        let decisions = jar.receive(["uid=2; Secure; SameSite=None"], from: url("https://sync.dsp.example/"), context: ctx, now: now.addingTimeInterval(5))
        guard case let .replaced(cookie) = decisions.first else { Issue.record("\(decisions)"); return }
        #expect(cookie.value == "2")
        #expect(cookie.created == now)
        #expect(jar.cookies.count == 1)
    }

    /// URLSession joins several `Set-Cookie` lines with commas; the commas inside `Expires` are not separators.
    @Test func joinedSetCookieHeadersSplitCorrectly() {
        let joined = "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure, b=2; Path=/, c=3"
        #expect(SetCookieLines.split(joined) == ["a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure", "b=2; Path=/", "c=3"])
        #expect(SetCookieLines.split("") == [])
    }
}

@Suite("Cookies: sending")
struct CookieSendingTests {
    private func jar(_ lines: [String], from origin: String, _ ctx: CookieContext) -> CookieJar {
        var jar = CookieJar()
        _ = jar.receive(lines, from: url(origin), context: ctx, now: now)
        return jar
    }

    @Test func matchingCookiesAreSentLongestPathFirst() {
        let ctx = context(.allowThirdParty)
        let jar = jar(["a=1; Path=/; Secure; SameSite=None", "b=2; Path=/sync; Secure; SameSite=None", "c=3; Path=/other; Secure; SameSite=None"],
                      from: "https://sync.dsp.example/sync/pixel", ctx)
        let selection = jar.cookies(for: url("https://sync.dsp.example/sync/pixel"), context: ctx, now: now)
        #expect(selection.header == "b=2; a=1")
        #expect(selection.sent.map(\.name) == ["b", "a"])
    }

    @Test func expiredAndSecureOnlyCookiesAreWithheldOrDropped() {
        let ctx = context("http://news.example", .allowThirdParty)
        var stored = CookieJar()
        _ = stored.receive(["s=1; Secure; Path=/", "t=2; Max-Age=10; Path=/"], from: url("https://news.example/"), context: context(.allowThirdParty), now: now)
        let later = stored.cookies(for: url("http://news.example/"), context: ctx, now: now.addingTimeInterval(60))
        #expect(later.sent.isEmpty)
        #expect(later.withheld.map(\.reason) == [.secureOnly])
    }

    /// A cookie the DSP set while it was the top-level site (first party) is not sent to it in a third-party context
    /// under WebKit's policy, and is sent under Chrome's when it is SameSite=None.
    @Test func firstPartyCookiesInAThirdPartyContextFollowThePolicy() {
        let firstParty = context("https://dsp.example", .allowThirdParty)
        let stored = jar(["uid=1; Domain=dsp.example; Secure; SameSite=None; Path=/", "lax=1; Domain=dsp.example; Secure; SameSite=Lax; Path=/"],
                         from: "https://www.dsp.example/", firstParty)
        let pixel = url("https://sync.dsp.example/pixel")

        let chrome = stored.cookies(for: pixel, context: context(.allowThirdParty), now: now)
        #expect(chrome.sent.map(\.name) == ["uid"])
        #expect(chrome.withheld.map(\.reason) == [.sameSite(.lax)])

        let webkit = stored.cookies(for: pixel, context: context(.blockThirdParty), now: now)
        #expect(webkit.sent.isEmpty)
        #expect(Set(webkit.withheld.map(\.reason)) == [.thirdPartyBlocked])

        let firefox = stored.cookies(for: pixel, context: context(.partitioned), now: now)
        #expect(firefox.sent.isEmpty)
        #expect(Set(firefox.withheld.map(\.reason)) == [.partitionedElsewhere])
    }

    /// Host-only cookies stay on their host: one set by www.dsp.example is not sent to sync.dsp.example.
    @Test func hostOnlyCookiesDoNotCrossSubdomains() {
        let firstParty = context("https://dsp.example", .allowThirdParty)
        let stored = jar(["uid=1; Secure; SameSite=None; Path=/"], from: "https://www.dsp.example/", firstParty)
        let selection = stored.cookies(for: url("https://sync.dsp.example/pixel"), context: context(.allowThirdParty), now: now)
        #expect(selection.sent.isEmpty)
        #expect(selection.withheld.isEmpty)
    }

    /// A partitioned cookie is sent under the top-level site it was set under, and nowhere else.
    @Test func partitionedCookiesStayWithTheirTopLevelSite() {
        let news = context("https://news.example", .partitioned)
        let stored = jar(["uid=1; Secure; SameSite=None; Path=/"], from: "https://sync.dsp.example/", news)
        #expect(stored.cookies(for: url("https://sync.dsp.example/"), context: news, now: now).sent.map(\.name) == ["uid"])
        let other = stored.cookies(for: url("https://sync.dsp.example/"), context: context("https://blog.example", .partitioned), now: now)
        #expect(other.sent.isEmpty)
        #expect(other.withheld.map(\.reason) == [.partitionedElsewhere])
    }
}

@Suite("Cookie sync URLs")
struct SyncURLTests {
    private let consent = SyncConsent(gdprApplies: true, tcString: "CPXxRfAPXxRfAAfKABENB-CgAAAAAAAAAAYgAAAAAAAA", usPrivacy: "1YNN",
                                      gppString: "DBABMA~CPX", gppSectionIDs: [2, 6])

    /// IAB "URL-based services" macros (TCF v2) and the GPP URL macros, URL-encoded.
    @Test func consentMacrosAreFilled() {
        let template = "https://ssp.example/sync?gdpr=${GDPR}&gdpr_consent=${GDPR_CONSENT_755}&pd=${GDPR_PD}&ac=${ADDTL_CONSENT}"
            + "&us_privacy=${US_PRIVACY}&gpp=${GPP_STRING_755}&gpp_sid=${GPP_SID}&x=${OTHER}"
        let expanded = SyncURL.expandConsentMacros(in: template, consent: consent)
        #expect(expanded.url == "https://ssp.example/sync?gdpr=1&gdpr_consent=CPXxRfAPXxRfAAfKABENB-CgAAAAAAAAAAYgAAAAAAAA&pd=&ac="
            + "&us_privacy=1YNN&gpp=DBABMA~CPX&gpp_sid=2%2C6&x=${OTHER}")
        #expect(Set(expanded.replaced) == ["${GDPR}", "${GDPR_CONSENT_755}", "${GDPR_PD}", "${ADDTL_CONSENT}", "${US_PRIVACY}", "${GPP_STRING_755}",
                                           "${GPP_SID}"])
        #expect(expanded.unknown == ["${OTHER}"])
    }

    @Test func gdprNotApplyingIsZeroAndUnknownIsEmpty() {
        #expect(SyncURL.expandConsentMacros(in: "g=${GDPR}", consent: SyncConsent(gdprApplies: false)).url == "g=0")
        #expect(SyncURL.expandConsentMacros(in: "g=${GDPR}", consent: SyncConsent()).url == "g=")
    }

    /// The DSP's id placeholders, left in a URL it redirected to, are what breaks a match: found in every common spelling.
    @Test func leftoverPlaceholdersAreFound() {
        #expect(SyncURL.leftoverPlaceholders(in: "https://ssp.example/setuid?bidder=dsp&uid=$UID") == ["$UID"])
        #expect(SyncURL.leftoverPlaceholders(in: "https://ssp.example/setuid?uid=${UID}&g=[GDPR]&c={consent}&d={{DSP_ID}}") == ["${UID}", "[GDPR]", "{consent}", "{{DSP_ID}}"])
        #expect(SyncURL.leftoverPlaceholders(in: "https://ssp.example/setuid?bidder=dsp&uid=abc123&cb=$") == [])
        #expect(SyncURL.leftoverPlaceholders(in: "https://ssp.example/setuid?uid=%24UID") == ["$UID"])
    }

    @Test func idsAndPartnersAreReadFromTheQuery() {
        let found = SyncURL.mappingParameters(in: "https://ssp.example/setuid?bidder=dsp&uid=abc123&gdpr=1&buyeruid=b-9&user_id=u7&cb=42")
        #expect(found.ids.map(\.name) == ["uid", "buyeruid", "user_id"])
        #expect(found.ids.map(\.value) == ["abc123", "b-9", "u7"])
        #expect(found.partners.map(\.value) == ["dsp"])
    }
}
