import Foundation
@testable import RTBKit
import Testing

@Suite("JSON-escaped text")
struct JSONEscapedTextTests {
    private func unescaped(_ text: String) -> String? {
        JSONEscapedText.unescaped(text)?.text
    }

    @Test func vastCopiedOutOfAJSONString() {
        let escaped = #"<VAST version=\"3.0\"><Ad><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><Impression><![CDATA[https://t.example/i?a=1&p=${AUCTION_PRICE}]]></Impression></Wrapper></Ad></VAST>"#
        let result = JSONEscapedText.unescaped(escaped)
        #expect(result?.levels == 1)
        #expect(result?.text == #"<VAST version="3.0"><Ad><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><Impression><![CDATA[https://t.example/i?a=1&p=${AUCTION_PRICE}]]></Impression></Wrapper></Ad></VAST>"#)
    }

    @Test func goEscapesAngleBracketsAndAmpersands() {
        #expect(unescaped(#"\u003cVAST version=\"4.0\"\u003e\u003cAd id=\"a\u0026b\"/\u003e\u003c/VAST\u003e"#)
            == #"<VAST version="4.0"><Ad id="a&b"/></VAST>"#)
        #expect(unescaped(#"\u003Cdiv\u003Ex\u003C/div\u003E"#) == "<div>x</div>")
    }

    @Test func aQuotedStringLiteral() {
        #expect(unescaped(#"  "<div class=\"x\">a\/b<\/div>"  "#) == #"<div class="x">a/b</div>"#)
        #expect(unescaped(#""https:\/\/ads.example\/vast?id=1""#) == "https://ads.example/vast?id=1")
    }

    @Test func escapedTwiceIsUnescapedTwice() {
        let result = JSONEscapedText.unescaped(#"<VAST version=\\\"3.0\\\"><Ad id=\\\"1\\\"/></VAST>"#)
        #expect(result?.levels == 2)
        #expect(result?.text == #"<VAST version="3.0"><Ad id="1"/></VAST>"#)
        #expect(JSONEscapedText.unescaped(#"<VAST version=\\\"3.0\\\"/>"#, maxLevels: 1)?.text == #"<VAST version=\"3.0\"/>"#)
    }

    @Test func escapedJSON() {
        #expect(unescaped(#"{\"native\":{\"ver\":\"1.2\",\"assets\":[]}}"#) == #"{"native":{"ver":"1.2","assets":[]}}"#)
        #expect(unescaped(#"[ {\"id\":1} ]"#) == #"[ {"id":1} ]"#)
    }

    @Test func everyJSONEscapeAndUnicode() {
        #expect(unescaped(#"<p title=\"t\">\b\f\n\r\t\\\/ \u00e9 \ud83d\ude00</p>"#)
            == "<p title=\"t\">\u{08}\u{0C}\n\r\t\\/ é 😀</p>")
        // A lone surrogate cannot be in a Swift string: it becomes U+FFFD.
        #expect(unescaped(#"<p title=\"t\">\ud83d.</p>"#) == "<p title=\"t\">\u{FFFD}.</p>")
    }

    @Test func leadingEscapedWhitespace() {
        #expect(unescaped(#"\n\t<VAST version=\"3.0\"/>\n"#) == "\n\t<VAST version=\"3.0\"/>\n")
    }

    @Test func markupThatIsNotEscaped() {
        // Raw quotes: real markup.
        #expect(JSONEscapedText.unescaped(#"<VAST version="3.0"></VAST>"#) == nil)
        #expect(JSONEscapedText.unescaped(#"{"adm":"<VAST version=\"3.0\">"}"#) == nil)
        // `\"` only inside a script's JavaScript string: real HTML (document.write is common in banners).
        #expect(JSONEscapedText.unescaped(#"<script>document.write('<img src=\"x.png\">')</script>"#) == nil)
        #expect(JSONEscapedText.unescaped(#"<!-- a=\"b\" --><div>x</div>"#) == nil)
        // No escaped quote anywhere: nothing says it was a JSON string.
        #expect(JSONEscapedText.unescaped(#"<div>a\nb</div>"#) == nil)
        #expect(JSONEscapedText.unescaped(#"https://a.example/?q=\"x\""#) == nil)
        // Not valid JSON string content.
        #expect(JSONEscapedText.unescaped(#"<div class=\"x\">\q</div>"#) == nil)
        #expect(JSONEscapedText.unescaped(#"<div class=\"x\">\u12</div>"#) == nil)
        #expect(JSONEscapedText.unescaped(#"<div class=\"x\">\"#) == nil)
        #expect(JSONEscapedText.unescaped("<div class=\\\"x\\\">\u{01}</div>") == nil)
        #expect(JSONEscapedText.unescaped("") == nil)
        #expect(JSONEscapedText.unescaped("   ") == nil)
        #expect(JSONEscapedText.unescaped(#"""#) == nil)
        #expect(JSONEscapedText.unescaped(#""a"b""#) == nil)
    }

    @Test func rawLineBreaksAreKept() {
        // A log line wrapped by the terminal or an editor.
        #expect(unescaped("<VAST version=\\\"3.0\\\">\n  <Ad/>\n</VAST>") == "<VAST version=\"3.0\">\n  <Ad/>\n</VAST>")
    }

    @Test func aMegabyteIsQuick() {
        let ad = #"<Ad id=\"1\"><InLine><Impression><![CDATA[https://t.example/i?x=1]]></Impression></InLine></Ad>"#
        let text = #"<VAST version=\"4.0\">"# + String(repeating: ad, count: 12_000) + "</VAST>"
        #expect(text.utf8.count > 1_000_000)
        let start = Date()
        #expect(JSONEscapedText.unescaped(text)?.levels == 1)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

@Suite("JSON-escaped text – review cases")
struct JSONEscapedTextReviewTests {
    @Test func legacyScriptCommentsAndSingleQuotedValuesAreReal() {
        // A legacy `<!--` script writing another script: its `</script>` does not end the outer one.
        let legacy = "<script type='text/javascript'><!--\ndocument.write('<script src=https://a.example/x.js></script>');\n"
            + #"document.write('<img src=\"https://t.example/p.gif\">\n');"# + "\n//--></script>"
        #expect(JSONEscapedText.unescaped(legacy) == nil)
        // `\"` inside a single-quoted attribute value is JavaScript.
        let handler = #"<a href='#' onclick='this.innerHTML=`<img src=\"x.png\">`'>Click</a><script>var s='a\nb';</script>"#
        #expect(JSONEscapedText.unescaped(handler) == nil)
    }

    @Test func prettyPrintedJSONFromALog() {
        #expect(JSONEscapedText.unescaped(#"{\n  \"id\": \"req-1\",\n  \"imp\": []\n}"#)?.text == "{\n  \"id\": \"req-1\",\n  \"imp\": []\n}")
        #expect(JSONEscapedText.unescaped(#"{\r\n\t\"id\": 1}"#)?.text == "{\r\n\t\"id\": 1}")
    }

    @Test func phpEscapesSlashes() {
        #expect(JSONEscapedText.unescaped(#"<style>.a{color:red}<\/style><a href=\"https:\/\/x.example\/c\">x<\/a>"#)?.text
            == #"<style>.a{color:red}</style><a href="https://x.example/c">x</a>"#)
    }

    @Test func escapedTwiceAfterAnEscapedLineBreak() {
        let result = JSONEscapedText.unescaped(#"\\n<VAST version=\\\"3.0\\\"/>"#)
        #expect(result?.levels == 2)
        #expect(result?.text == "\n<VAST version=\"3.0\"/>")
    }
}
