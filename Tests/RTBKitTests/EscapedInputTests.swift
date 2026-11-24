import Foundation
import Testing
@testable import RTBKit

/// `text` as the inside of a JSON string, the way a log or a bid response holds it.
private func jsonEscaped(_ text: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self).dropFirst(2).dropLast(2).description
}

private func issue(_ code: String, in input: ParsedInput) -> ValidationIssue? {
    input.issues.first { $0.code == code }
}

@Suite("InputParser – escaped markup")
struct EscapedInputTests {
    static let vast = #"<VAST version="3.0"><Ad id="1"><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><VASTAdTagURI><![CDATA[https://ads.example/vast?a=1&b=2]]></VASTAdTagURI></Wrapper></Ad></VAST>"#

    @Test func vastCopiedFromALogRendersAsVAST() throws {
        let escaped = jsonEscaped(Self.vast)
        #expect(escaped.hasPrefix(#"<VAST version=\"3.0\">"#))
        let input = InputParser.parse(escaped)
        #expect(input.kind == .vastMarkup)
        #expect(try #require(input.candidates.first).markup == .vast(.xml(Self.vast)))
        let note = try #require(issue("input.unescaped", in: input))
        #expect(note.severity == .info)
        #expect(note.message.contains("JSON string"))
        #expect(!note.message.contains("twice"))
    }

    @Test func escapedHTML() {
        let input = InputParser.parse(#"<div class=\"ad\"><a href=\"https://x.example/?a=1&b=2\">Go</a></div>"#)
        #expect(input.kind == .htmlMarkup)
        #expect(input.candidates.first?.markup == .html(#"<div class="ad"><a href="https://x.example/?a=1&b=2">Go</a></div>"#))
        #expect(issue("input.unescaped", in: input) != nil)
    }

    @Test func escapedNativeJSON() {
        let native = #"{"native":{"ver":"1.2","assets":[{"id":1,"title":{"text":"Hi"}}],"link":{"url":"https://x.example"}}}"#
        let input = InputParser.parse(jsonEscaped(native))
        #expect(input.kind == .nativeMarkup)
        #expect(input.candidates.first?.markup == .native(native))
    }

    @Test func aQuotedResponseAndAQuotedURL() {
        let response = OpenRTBFixtures.response26Video()
        let quoted = InputParser.parse("\"" + jsonEscaped(response) + "\"")
        #expect(quoted.kind == InputParser.parse(response).kind)
        #expect(quoted.candidates == InputParser.parse(response).candidates)
        let url = InputParser.parse(#""https:\/\/ads.example\/vast?id=1""#)
        #expect(url.kind == .vastURL)
        #expect(url.candidates.first?.markup == .vast(.url("https://ads.example/vast?id=1")))
    }

    @Test func escapedTwiceSaysSo() throws {
        let input = InputParser.parse(jsonEscaped(jsonEscaped(Self.vast)))
        #expect(input.kind == .vastMarkup)
        #expect(try #require(issue("input.unescaped", in: input)).message.contains("twice"))
    }

    @Test func realMarkupIsReadAsTyped() {
        let banner = #"<script>document.write('<img src=\"https://x.example/a.png\">');</script>"#
        let input = InputParser.parse(banner)
        #expect(input.candidates.first?.markup == .html(banner))
        #expect(issue("input.unescaped", in: input) == nil)
        // Unescaped, but still not something to render: left as it was.
        let quoted = InputParser.parse(#""hello""#)
        guard case .invalid = quoted.kind else { Issue.record("a quoted word is not an ad"); return }
        #expect(issue("input.unescaped", in: quoted) == nil)
    }

    @Test func anEscapedRequestIsReadToo() throws {
        let input = InputParser.parse(OpenRTBFixtures.response26Video(), request: jsonEscaped(OpenRTBFixtures.request26))
        let request = try #require(input.request)
        #expect(request.impressions.count == 4)
        #expect(input.issues.contains { $0.code == "request.unescaped" && $0.severity == .info })
    }
}

@Suite("InputParser – adm escaped twice by the DSP")
struct DoubleEscapedMarkupTests {
    private func escapedAdmIssue(_ input: ParsedInput) -> ValidationIssue? {
        input.issues.first { $0.code == "openrtb.bid.adm.escaped" }
    }

    @Test func openRTB2VideoBannerAndNative() throws {
        let video = InputParser.parse(OpenRTBFixtures.response26Video(adm: jsonEscaped(OpenRTBFixtures.vast)))
        let warning = try #require(escapedAdmIssue(video))
        #expect(warning.severity == .warning)
        #expect(warning.path == "/seatbid/0/bid/0/adm")
        // Used as received, as a device would get it.
        #expect(video.candidates.first?.markup == .vast(.xml(jsonEscaped(OpenRTBFixtures.vast))))

        let bannerADM = jsonEscaped(#"<div class="ad"><img src="https://x.example/a.png"></div>"#)
        let banner = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"mtype":1,"adm":""# + jsonEscaped(bannerADM) + #""}]}]}"#
        #expect(escapedAdmIssue(InputParser.parse(banner)) != nil)

        let nativeADM = jsonEscaped(#"{"native":{"assets":[],"link":{"url":"https://x.example"}}}"#)
        let native = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"mtype":4,"adm":""# + jsonEscaped(nativeADM) + #""}]}]}"#
        #expect(escapedAdmIssue(InputParser.parse(native)) != nil)
    }

    @Test func openRTB3DisplayAndVideo() {
        let display = OpenRTBFixtures.spec30(display: #"{"adm":""# + jsonEscaped(jsonEscaped(#"<div id="a">x</div>"#)) + #""}"#)
        #expect(escapedAdmIssue(InputParser.parse(display))?.path.hasSuffix("/display/adm") == true)
        let video = OpenRTBFixtures.spec30(video: #"{"adm":""# + jsonEscaped(jsonEscaped(OpenRTBFixtures.vast)) + #""}"#)
        #expect(escapedAdmIssue(InputParser.parse(video))?.path.hasSuffix("/video/adm") == true)
    }

    @Test func aBannerWritingEscapedQuotesInJavaScriptIsFine() {
        let adm = #"<script>document.write('<a href=\"https://x.example\"><img src=\"https://x.example/a.png\"></a>');</script>"#
        let response = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"mtype":1,"adm":""# + jsonEscaped(adm) + #""}]}]}"#
        let input = InputParser.parse(response)
        #expect(input.candidates.first?.markup == .html(adm))
        #expect(escapedAdmIssue(input) == nil)
        #expect(escapedAdmIssue(InputParser.parse(OpenRTBFixtures.response26Video())) == nil)
    }
}

