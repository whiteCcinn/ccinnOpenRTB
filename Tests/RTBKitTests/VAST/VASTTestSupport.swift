import Foundation
import Testing
@testable import RTBKit

/// A `VASTFetcher` serving canned responses and `data:` URLs, recording every call.
actor FakeVASTFetcher: VASTFetcher {
    enum Response: Sendable {
        case body(String)
        case failure
    }

    struct Call: Sendable, Equatable {
        var url: String
        var parentRequestID: UUID?
        var requestID: UUID
    }

    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "The request timed out." }
    }

    private let responses: [String: Response]
    private(set) var calls: [Call] = []

    init(_ responses: [String: Response] = [:]) {
        self.responses = responses
    }

    func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
        let requestID = UUID()
        calls.append(Call(url: url, parentRequestID: parentRequestID, requestID: requestID))
        if let body = Self.decodeDataURL(url) { return (body, requestID) }
        switch responses[url] {
        case let .body(body): return (body, requestID)
        case .failure, nil: throw Unavailable()
        }
    }

    /// `data:[type][;base64],payload`; `nil` for any other URL.
    static func decodeDataURL(_ url: String) -> String? {
        guard url.lowercased().hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let payload = String(url[url.index(after: comma)...])
        if header.lowercased().hasSuffix(";base64") {
            return Data(base64Encoded: payload).map { String(decoding: $0, as: UTF8.self) }
        }
        return payload.removingPercentEncoding
    }
}

enum VASTFixture {
    static func dataURL(_ xml: String) -> String {
        "data:application/xml;base64," + Data(xml.utf8).base64EncodedString()
    }

    /// A minimal valid inline ad document (one Linear, one MP4). VAST 4.x documents get the `UniversalAdId` they require.
    static func inline(version: String = "3.0", id: String = "inline", sequence: Int? = nil, name: String = "inline",
                       extraInline: String = "", duration: String = "00:00:15") -> String {
        document(version: version, ads: [inlineAd(id: id, sequence: sequence, name: name, extraInline: extraInline, duration: duration,
                                                  universalAdId: version.hasPrefix("4"))])
    }

    /// `universalAdId`: VAST 4.x requires `<UniversalAdId>` in every InLine creative; earlier versions do not know it.
    static func inlineAd(id: String = "inline", sequence: Int? = nil, name: String = "inline", extraInline: String = "",
                         duration: String = "00:00:15", universalAdId: Bool = false) -> String {
        """
        <Ad id="\(id)"\(sequence.map { " sequence=\"\($0)\"" } ?? "")>
          <InLine>
            <AdSystem>Fixture</AdSystem>
            <AdTitle>\(name)</AdTitle>
            <Impression><![CDATA[https://tracker.example/\(name)/impression]]></Impression>
            <Error><![CDATA[https://tracker.example/\(name)/error?code=[ERRORCODE]]]></Error>
            \(extraInline)
            <Creatives>
              <Creative id="\(name)-creative">
                \(universalAdId ? #"<UniversalAdId idRegistry="unknown">unknown</UniversalAdId>"# : "")
                <Linear>
                  <Duration>\(duration)</Duration>
                  <TrackingEvents>
                    <Tracking event="start"><![CDATA[https://tracker.example/\(name)/start]]></Tracking>
                  </TrackingEvents>
                  <VideoClicks>
                    <ClickThrough><![CDATA[https://advertiser.example/\(name)]]></ClickThrough>
                    <ClickTracking><![CDATA[https://tracker.example/\(name)/click]]></ClickTracking>
                  </VideoClicks>
                  <MediaFiles>
                    <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[https://cdn.example/\(name).mp4]]></MediaFile>
                  </MediaFiles>
                </Linear>
              </Creative>
            </Creatives>
          </InLine>
        </Ad>
        """
    }

    /// A wrapper ad pointing at `adTagURI`, with an Impression, Error, start tracker and ClickTracking named `name`.
    static func wrapperAd(id: String = "wrapper", sequence: Int? = nil, name: String, adTagURI: String?, attributes: String = "") -> String {
        """
        <Ad id="\(id)"\(sequence.map { " sequence=\"\($0)\"" } ?? "")>
          <Wrapper\(attributes.isEmpty ? "" : " " + attributes)>
            <AdSystem>Fixture</AdSystem>
            \(adTagURI.map { "<VASTAdTagURI><![CDATA[\($0)]]></VASTAdTagURI>" } ?? "")
            <Impression><![CDATA[https://tracker.example/\(name)/impression]]></Impression>
            <Error><![CDATA[https://tracker.example/\(name)/error?code=[ERRORCODE]]]></Error>
            <Creatives>
              <Creative>
                <Linear>
                  <TrackingEvents>
                    <Tracking event="start"><![CDATA[https://tracker.example/\(name)/start]]></Tracking>
                  </TrackingEvents>
                  <VideoClicks>
                    <ClickTracking><![CDATA[https://tracker.example/\(name)/click]]></ClickTracking>
                  </VideoClicks>
                </Linear>
              </Creative>
            </Creatives>
          </Wrapper>
        </Ad>
        """
    }

    static func wrapper(version: String = "3.0", name: String, adTagURI: String?, attributes: String = "") -> String {
        document(version: version, ads: [wrapperAd(name: name, adTagURI: adTagURI, attributes: attributes)])
    }

    static func document(version: String = "3.0", ads: [String], rootErrors: [String] = []) -> String {
        let errors = rootErrors.map { "<Error><![CDATA[\($0)]]></Error>" }.joined()
        return "<VAST version=\"\(version)\">\(errors)\(ads.joined(separator: "\n"))</VAST>"
    }

    /// A chain of `depth` wrappers (named `w1` … `wN`, outermost first) ending in an inline ad, all as `data:` URLs.
    static func chain(depth: Int) -> String {
        var xml = inline(name: "inline")
        for level in stride(from: depth, through: 1, by: -1) {
            xml = wrapper(name: "w\(level)", adTagURI: dataURL(xml))
        }
        return xml
    }

    static func url(_ name: String, _ kind: String) -> String {
        "https://tracker.example/\(name)/\(kind)"
    }
}

/// Whether kit-openrtb's `MacroExpander` is merged (the placeholder returns templates unchanged). Expansion assertions are
/// enabled automatically once it is.
enum MacroSupport {
    static let isImplemented: Bool = {
        MacroExpander.expand("[ERRORCODE]", context: MacroContext(errorCode: 405)).url != "[ERRORCODE]"
    }()
}

extension [ValidationIssue] {
    func codes(_ severity: ValidationIssue.Severity? = nil) -> [String] {
        filter { severity == nil || $0.severity == severity }.map(\.code)
    }

    func issue(_ code: String) -> ValidationIssue? {
        first { $0.code == code }
    }
}

func parsedDocument(_ xml: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> (VASTDocument, [ValidationIssue]) {
    let (document, issues) = VASTParser.parse(xml)
    let unwrapped = try #require(document, sourceLocation: sourceLocation)
    return (unwrapped, issues)
}

func resolved(_ xml: String, fetcher: FakeVASTFetcher = FakeVASTFetcher(), maxDepth: Int = 5,
              parentRequestID: UUID? = nil) async -> ResolvedVAST {
    await VASTResolver(fetcher: fetcher, maxDepth: maxDepth).resolve(.xml(xml), parentRequestID: parentRequestID)
}
