@testable import CcinnOpenRTB
import Foundation
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
