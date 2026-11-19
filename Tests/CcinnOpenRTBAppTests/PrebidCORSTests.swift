import Foundation
import Testing
@testable import CcinnOpenRTB

/// The browser's CORS checks, as the Fetch standard words them: what a bidder must answer for its bid to reach Prebid.
@Suite("Prebid: CORS as the browser applies it")
struct PrebidCORSTests {
    private let origin = "https://news.example"

    /// Prebid's usual bid request (POST text/plain) is a simple request: no preflight. JSON, PUT or a custom header is not.
    @Test func whatNeedsAPreflight() {
        #expect(!PrebidCORS.needsPreflight(method: "POST", headers: ["content-type": "text/plain"]))
        #expect(!PrebidCORS.needsPreflight(method: "GET", headers: [:]))
        #expect(!PrebidCORS.needsPreflight(method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded;charset=UTF-8", "Accept": "*/*"]))
        #expect(PrebidCORS.needsPreflight(method: "POST", headers: ["Content-Type": "application/json"]))
        #expect(PrebidCORS.needsPreflight(method: "PUT", headers: [:]))
        #expect(PrebidCORS.needsPreflight(method: "GET", headers: ["X-Openrtb-Version": "2.6"]))
        #expect(PrebidCORS.needsPreflight(method: "GET", headers: ["Accept": String(repeating: "a", count: 129)]), "a safelisted value is short")
        #expect(PrebidCORS.unsafeHeaderNames(["Content-Type": "application/json", "X-B": "1", "x-a": "2", "Accept": "*/*"]) == ["content-type", "x-a", "x-b"])
    }

    @Test func thePreflightRequest() {
        let headers = PrebidCORS.preflightHeaders(method: "POST", unsafeNames: ["content-type", "x-a"])
        #expect(headers == ["Accept": "*/*", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type,x-a"])
        #expect(PrebidCORS.preflightHeaders(method: "PUT", unsafeNames: [])["Access-Control-Request-Headers"] == nil)
    }

    /// Credentialed requests (Prebid's `withCredentials`) need the exact origin and `Access-Control-Allow-Credentials: true`.
    @Test func theResponseCheck() {
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "*"], origin: origin, credentials: .sameOrigin) == nil)
        #expect(PrebidCORS.responseProblem(headers: ["access-control-allow-origin": "https://news.example"], origin: origin, credentials: .omit) == nil)
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "https://news.example", "Access-Control-Allow-Credentials": "true"],
                                           origin: origin, credentials: .include) == nil)
        #expect(PrebidCORS.responseProblem(headers: [:], origin: origin, credentials: .sameOrigin)?.contains("no Access-Control-Allow-Origin") == true)
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "https://other.example"], origin: origin, credentials: .sameOrigin)?
            .contains("https://other.example") == true)
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "https://news.example, https://b.example"], origin: origin,
                                           credentials: .sameOrigin) != nil, "one origin only")
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "*", "Access-Control-Allow-Credentials": "true"], origin: origin,
                                           credentials: .include)?.contains("*") == true)
        #expect(PrebidCORS.responseProblem(headers: ["Access-Control-Allow-Origin": "https://news.example"], origin: origin, credentials: .include)?
            .contains("Access-Control-Allow-Credentials") == true)
    }

    @Test func thePreflightCheck() {
        let allowing = ["Access-Control-Allow-Origin": "https://news.example", "Access-Control-Allow-Methods": "POST, PUT",
                        "Access-Control-Allow-Headers": "Content-Type, X-A"]
        #expect(PrebidCORS.preflightProblem(status: 204, headers: allowing, origin: origin, method: "PUT", unsafeNames: ["content-type", "x-a"],
                                            credentials: .sameOrigin) == nil)
        #expect(PrebidCORS.preflightProblem(status: 200, headers: allowing, origin: origin, method: "POST", unsafeNames: ["x-b"], credentials: .sameOrigin)?
            .contains("x-b") == true)
        #expect(PrebidCORS.preflightProblem(status: 200, headers: allowing, origin: origin, method: "DELETE", unsafeNames: [], credentials: .sameOrigin)?
            .contains("DELETE") == true)
        #expect(PrebidCORS.preflightProblem(status: 404, headers: allowing, origin: origin, method: "PUT", unsafeNames: [], credentials: .sameOrigin)?
            .contains("404") == true)
        // A wildcard covers methods and headers, but not for a credentialed request, and never Authorization.
        let wildcard = ["Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "*", "Access-Control-Allow-Headers": "*"]
        #expect(PrebidCORS.preflightProblem(status: 200, headers: wildcard, origin: origin, method: "PUT", unsafeNames: ["x-a"], credentials: .sameOrigin) == nil)
        #expect(PrebidCORS.preflightProblem(status: 200, headers: wildcard, origin: origin, method: "PUT", unsafeNames: ["authorization"],
                                            credentials: .sameOrigin) != nil)
        // POST needs no listing: it is a CORS-safelisted method.
        #expect(PrebidCORS.preflightProblem(status: 200, headers: ["Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type"],
                                            origin: origin, method: "POST", unsafeNames: ["content-type"], credentials: .sameOrigin) == nil)
    }

    /// The page reads only safelisted response headers and the ones the server exposes; never Set-Cookie.
    @Test func exposedHeaders() {
        let headers = ["Content-Type": "application/json", "X-Bidder-Debug": "1", "X-Secret": "s", "Set-Cookie": "a=1", "Cache-Control": "no-store"]
        #expect(PrebidCORS.exposedHeaders(headers, crossOrigin: true, credentials: .sameOrigin).keys.sorted() == ["Cache-Control", "Content-Type"])
        var exposing = headers
        exposing["Access-Control-Expose-Headers"] = "x-bidder-debug"
        #expect(PrebidCORS.exposedHeaders(exposing, crossOrigin: true, credentials: .sameOrigin)["X-Bidder-Debug"] == "1")
        exposing["Access-Control-Expose-Headers"] = "*"
        #expect(PrebidCORS.exposedHeaders(exposing, crossOrigin: true, credentials: .sameOrigin)["X-Secret"] == "s")
        #expect(PrebidCORS.exposedHeaders(exposing, crossOrigin: true, credentials: .include)["X-Secret"] == nil, "* is not a wildcard with credentials")
        #expect(PrebidCORS.exposedHeaders(exposing, crossOrigin: true, credentials: .sameOrigin)["Set-Cookie"] == nil)
        #expect(PrebidCORS.exposedHeaders(headers, crossOrigin: false, credentials: .include)["X-Secret"] == "s")
        #expect(PrebidCORS.exposedHeaders(headers, crossOrigin: false, credentials: .include)["Set-Cookie"] == nil)
    }

    /// An https page cannot fetch http, except from the Mac itself (a potentially trustworthy origin: a local test bidder).
    @Test func mixedContent() {
        let page = URL(string: "https://news.example/a")!
        #expect(PrebidCORS.isMixedContent(URL(string: "http://bidder.example/b")!, page: page))
        #expect(!PrebidCORS.isMixedContent(URL(string: "https://bidder.example/b")!, page: page))
        #expect(!PrebidCORS.isMixedContent(URL(string: "http://127.0.0.1:8080/b")!, page: page))
        #expect(!PrebidCORS.isMixedContent(URL(string: "http://localhost:8080/b")!, page: page))
        #expect(!PrebidCORS.isMixedContent(URL(string: "http://bid.localhost/b")!, page: page))
        #expect(!PrebidCORS.isMixedContent(URL(string: "http://[::1]:8080/b")!, page: page))
        #expect(PrebidCORS.isMixedContent(URL(string: "http://127.0.0.1.evil.example/b")!, page: page))
    }
}
