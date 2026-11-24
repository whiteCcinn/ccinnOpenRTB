@testable import CcinnOpenRTB
import Foundation
import RTBKit
import Testing

@Suite("Markup formatter")
struct MarkupFormatterTests {
    @Test func theVASTFromALog() throws {
        let pasted = #"<VAST version=\"3.0\"><Ad><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><Impression><![CDATA[https://t.example/i?d=eyJ&auction_price=${AUCTION_PRICE}]]></Impression><Creatives></Creatives></Wrapper></Ad></VAST>"#
        let formatted = try MarkupFormatter.format(pasted).get()
        #expect(formatted.text == """
        <VAST version="3.0">
          <Ad>
            <Wrapper>
              <AdSystem><![CDATA[RTB House]]></AdSystem>
              <Impression><![CDATA[https://t.example/i?d=eyJ&auction_price=${AUCTION_PRICE}]]></Impression>
              <Creatives></Creatives>
            </Wrapper>
          </Ad>
        </VAST>
        """)
        #expect(formatted.language == .vast)
        #expect(formatted.unescapedLevels == 1)
        #expect(formatted.summary == "Unescaped a JSON string · VAST XML")
    }

    @Test func eachLanguage() throws {
        let native = try MarkupFormatter.format(#"{"native":{"ver":"1.2","assets":[]}}"#).get()
        #expect(native.language == .json)
        #expect(native.text.hasPrefix("{\n  \"native\": {"))
        #expect(native.summary == "JSON")
        let xml = try MarkupFormatter.format(#"<?xml version="1.0"?><VMAP><AdBreak/></VMAP>"#).get()
        #expect(xml.language == .xml)
        #expect(xml.text == "<?xml version=\"1.0\"?>\n<VMAP>\n  <AdBreak/>\n</VMAP>")
        #expect(try MarkupFormatter.format("<vmap:VMAP xmlns:vmap=\"x\"><vmap:AdBreak/></vmap:VMAP>").get().language == .xml)
        let html = try MarkupFormatter.format(#"<div><img src="a.png"></div>"#).get()
        #expect(html.language == .html)
        #expect(html.text == "<div>\n  <img src=\"a.png\">\n</div>")
        #expect(html.summary == "HTML")
        // A lower-case vast root is VAST too; an HTML document that mentions VAST is not.
        #expect(try MarkupFormatter.format("<vast version=\"4.0\"><Ad/></vast>").get().language == .vast)
        #expect(try MarkupFormatter.format("<div><script>var v='<VAST>'</script></div>").get().language == .html)
    }

    @Test func escapedNativeAndTwice() throws {
        let once = try MarkupFormatter.format(#"{\"native\":{\"assets\":[]}}"#).get()
        #expect(once.text == "{\n  \"native\": {\n    \"assets\": []\n  }\n}")
        let twice = try MarkupFormatter.format(#"<div class=\\\"a\\\">x</div>"#).get()
        #expect(twice.unescapedLevels == 2)
        #expect(twice.summary == "Unescaped twice · HTML")
    }

    @Test func unescapedEvenWhenItDoesNotPrettyPrint() throws {
        let result = try MarkupFormatter.format(#"<VAST version=\"3.0\"><Ad></VAST>"#).get()
        #expect(result.text == #"<VAST version="3.0"><Ad></VAST>"#)
        #expect(result.language == nil)
        #expect(result.summary == "Unescaped a JSON string · Not well-formed XML: </VAST> closes <Ad> (line 1)")
    }

    @Test func failuresSayWhy() {
        #expect(MarkupFormatter.format("  ") == .failure(.empty))
        #expect(MarkupFormatter.format("https://ads.example/vast") == .failure(.notMarkup))
        #expect(MarkupFormatter.format("{\"a\": [1, 2}") == .failure(.json))
        #expect(MarkupFormatter.format("<VAST><Ad>\n</VAST>") == .failure(.xml(.mismatched(open: "Ad", close: "VAST", line: 2))))
        #expect(MarkupFormatter.Failure.json.message == "Not well-formed JSON: unbalanced brackets or an open string")
        #expect(MarkupFormatter.Failure.notMarkup.message == "Nothing to format: not JSON, XML or HTML")
        #expect(MarkupFormatter.Failure.xml(.unclosed("Ad", line: 3)).message == "Not well-formed XML: <Ad> is not closed (line 3)")
        #expect(MarkupFormatter.Failure.xml(.unexpectedClose("Ad", line: 3)).message == "Not well-formed XML: </Ad> closes nothing (line 3)")
        #expect(MarkupFormatter.Failure.html(.unterminated(line: 4)).message
            == "Not well-formed HTML: a tag, comment or script is not closed (line 4)")
    }

    @Test func whetherFormatApplies() {
        for text in ["{}", " [1]", "\n<VAST/>", #""<p>""#, #"<div>"#] {
            #expect(MarkupFormatter.mightFormat(text), "\(text)")
        }
        for text in ["", "  ", "https://ads.example/vast", "hello"] {
            #expect(!MarkupFormatter.mightFormat(text), "\(text)")
        }
    }

    @Test func viewersShowTheFormattedTextOrTheTextItself() {
        #expect(MarkupFormatter.displayText("<a><b/></a>", as: .xml) == "<a>\n  <b/>\n</a>")
        #expect(MarkupFormatter.displayText("plain text") == "plain text")
        #expect(MarkupFormatter.displayText("{\"a\":") == "{\"a\":")
    }
}

@Suite("Markup formatter – viewers")
struct MarkupViewerTests {
    @Test func languageFromAMIMEType() {
        #expect(MarkupFormatter.Language(mimeType: "application/json") == .json)
        #expect(MarkupFormatter.Language(mimeType: "application/x-openrtb+json") == .json)
        #expect(MarkupFormatter.Language(mimeType: "application/xml") == .xml)
        #expect(MarkupFormatter.Language(mimeType: "TEXT/XML") == .xml)
        #expect(MarkupFormatter.Language(mimeType: "text/html") == .html)
        #expect(MarkupFormatter.Language(mimeType: "image/png") == nil)
        #expect(MarkupFormatter.Language(mimeType: nil) == nil)
    }

    @Test func aViewerCanKeepEscapesAsReceived() {
        let escaped = #"<VAST version=\"3.0\"/>"#
        #expect(MarkupFormatter.displayText(escaped, unescape: false) == escaped)
        #expect(MarkupFormatter.displayText(escaped) == #"<VAST version="3.0"/>"#)
        // An XML hint formats markup that does not say what it is as XML.
        #expect(MarkupFormatter.displayText("<r><a>1</a></r>", as: .xml) == "<r>\n  <a>1</a>\n</r>")
    }

    @Test func aBidsMarkupInTheBidAndOnTheDevice() {
        let vast = "<VAST version=\"4.0\"><Ad/></VAST>"
        let candidate = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .video, markup: .vast(.xml(vast)))
        let bid = InspectorMarkup.sources(candidate: candidate, deviceMarkup: nil)
        #expect(bid == [InspectorMarkup.Source(title: "In the bid", text: vast, language: .vast)])
        let device = InspectorMarkup.sources(candidate: candidate, deviceMarkup: .vast(.xml("<VAST version=\"4.0\"><Ad id=\"2\"/></VAST>")))
        #expect(device.map(\.title) == ["In the bid", "On the device"])

        let html = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .banner, markup: .html("<div/>"))
        #expect(InspectorMarkup.sources(candidate: html, deviceMarkup: nil).first?.language == .html)
        let native = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .native, markup: .native("{}"))
        #expect(InspectorMarkup.sources(candidate: native, deviceMarkup: nil).first?.language == .json)
        // Same markup on the device: one source.
        #expect(InspectorMarkup.sources(candidate: html, deviceMarkup: .html("<div/>")).count == 1)
    }

    @Test func markupThatIsNotText() {
        let url = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .video,
                              markup: .vast(.url("https://ads.example/vast")))
        #expect(InspectorMarkup.sources(candidate: url, deviceMarkup: nil) == [InspectorMarkup.Source(title: "VAST tag URL", text: "https://ads.example/vast", language: nil)])
        let image = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .banner,
                                markup: .image(ImageBanner(imageURL: "https://x.example/a.png", link: nil)))
        #expect(InspectorMarkup.sources(candidate: image, deviceMarkup: nil).first?.text == "https://x.example/a.png")
        let none = AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 1, currency: "USD", format: .banner, markup: .none,
                               winURL: "https://x.example/win")
        #expect(InspectorMarkup.sources(candidate: none, deviceMarkup: nil).isEmpty)
        #expect(InspectorMarkup.unavailableReason(none) == "Delivered by the win notice (nurl): Real mode fetches it.")
    }
}
