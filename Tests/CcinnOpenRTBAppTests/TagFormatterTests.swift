@testable import CcinnOpenRTB
import Foundation
import RTBKit
import Testing

@Suite("Tag formatter – XML")
struct XMLTagFormatterTests {
    private func format(_ text: String) -> String? {
        try? TagFormatter.prettyPrinted(text, dialect: .xml).get()
    }

    @Test func vastWrapperOneElementPerLine() {
        let input = #"<?xml version="1.0" encoding="UTF-8"?><VAST version="3.0"><Ad><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><VASTAdTagURI><![CDATA[https://ams.example/ad?a=1&b=2]]></VASTAdTagURI><Impression><![CDATA[https://t.example/i?p=${AUCTION_PRICE}]]></Impression><Error><![CDATA[https://t.example/e?c=[ERRORCODE]]]></Error><Creatives></Creatives></Wrapper></Ad></VAST>"#
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="3.0">
          <Ad>
            <Wrapper>
              <AdSystem><![CDATA[RTB House]]></AdSystem>
              <VASTAdTagURI><![CDATA[https://ams.example/ad?a=1&b=2]]></VASTAdTagURI>
              <Impression><![CDATA[https://t.example/i?p=${AUCTION_PRICE}]]></Impression>
              <Error><![CDATA[https://t.example/e?c=[ERRORCODE]]]></Error>
              <Creatives></Creatives>
            </Wrapper>
          </Ad>
        </VAST>
        """
        #expect(format(input) == expected)
        // Idempotent, and an already indented document is re-indented the same way.
        #expect(format(expected) == expected)
        #expect(format(expected.replacingOccurrences(of: "\n  ", with: "\n\t\t")) == expected)
    }

    @Test func textAndMixedContentAreKeptAsTyped() {
        let mediaFile = #"<MediaFile type="video/mp4" width="640"  height="360">"# + "\n    https://cdn.example/a.mp4\n    </MediaFile>"
        let input = #"<Linear skipoffset="00:00:05"><Duration> 00:00:15 </Duration><MediaFiles>"# + mediaFile
            + #"</MediaFiles><AdParameters>a <b>bold</b> c</AdParameters><Tracking event="start"/><!-- note --></Linear>"#
        let expected = #"<Linear skipoffset="00:00:05">"# + "\n  " + "<Duration> 00:00:15 </Duration>\n  <MediaFiles>\n    " + mediaFile
            + "\n  </MediaFiles>\n  <AdParameters>a <b>bold</b> c</AdParameters>\n  " + #"<Tracking event="start"/>"# + "\n  <!-- note -->\n</Linear>"
        #expect(format(input) == expected)
    }

    @Test func aVASTDocumentParsesTheSameFormatted() throws {
        for sample in VASTSamples.all {
            // Minified first, as a DSP sends it.
            let minified = sample.xml.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
            let formatted = try #require(format(minified), "\(sample.title)")
            let original = try #require(VASTParser.parse(minified).document, "\(sample.title)")
            #expect(VASTParser.parse(formatted).document == original, "\(sample.title)")
            #expect(formatted != minified, "\(sample.title)")
        }
    }

    @Test func malformedXMLSaysWhereAndWhy() {
        #expect(TagFormatter.prettyPrinted("<VAST><Ad>\n</VAST>", dialect: .xml) == .failure(.mismatched(open: "Ad", close: "VAST", line: 2)))
        #expect(TagFormatter.prettyPrinted("<VAST><Ad>", dialect: .xml) == .failure(.unclosed("Ad", line: 1)))
        #expect(TagFormatter.prettyPrinted("<VAST>\n</Ad></VAST>", dialect: .xml) == .failure(.mismatched(open: "VAST", close: "Ad", line: 2)))
        #expect(TagFormatter.prettyPrinted("<VAST>\n<Ad id=\"1\"", dialect: .xml) == .failure(.unterminated(line: 2)))
        #expect(TagFormatter.prettyPrinted("<VAST><![CDATA[x</VAST>", dialect: .xml) == .failure(.unterminated(line: 1)))
        #expect(TagFormatter.prettyPrinted("   ", dialect: .xml) == .failure(.empty))
    }

    @Test func attributesMayHoldAngleBrackets() {
        #expect(format(#"<a x="1>2" y='<'><b/></a>"#) == "<a x=\"1>2\" y='<'>\n  <b/>\n</a>")
    }
}

@Suite("Tag formatter – HTML")
struct HTMLTagFormatterTests {
    private func format(_ text: String) -> String? {
        try? TagFormatter.prettyPrinted(text, dialect: .html).get()
    }

    @Test func blocksGetLinesAndInlineRunsStayTogether() {
        let input = #"<div class="ad"><a href="https://x.example"><img src="a.png"><img src="b.png"></a><p>Hello <b>world</b></p></div>"#
        let expected = """
        <div class="ad">
          <a href="https://x.example"><img src="a.png"><img src="b.png"></a>
          <p>
            Hello <b>world</b>
          </p>
        </div>
        """
        #expect(format(input) == expected)
        #expect(format(expected) == expected)
    }

    @Test func aDocumentWithHeadScriptsAndStyles() {
        let input = #"<!DOCTYPE html><html><head><meta charset="utf-8"><title>A  b</title><style>.a{color:red}</style><script src="mraid.js"></script></head><body><div id="ad"><script>if (a < b && c > d) { document.write("<p>x</p>"); }</script></div></body></html>"#
        let expected = """
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>A  b</title>
            <style>.a{color:red}</style>
            <script src="mraid.js"></script>
          </head>
          <body>
            <div id="ad">
              <script>if (a < b && c > d) { document.write("<p>x</p>"); }</script>
            </div>
          </body>
        </html>
        """
        #expect(format(input) == expected)
    }

    @Test func aFragmentOfScriptsThenContent() {
        // Before the first content of a line, whitespace is not rendered.
        let input = #"<script src="mraid.js"></script><script>var x=1;</script><a href="c"><img src="i.png"></a><span>t</span>"#
        let expected = """
        <script src="mraid.js"></script>
        <script>var x=1;</script>
        <a href="c"><img src="i.png"></a><span>t</span>
        """
        #expect(format(input) == expected)
    }

    @Test func scriptsBetweenInlineContentStayInline() {
        // A line break here would put a space between "a" and "b".
        #expect(format("<span>a</span><script>t()</script><span>b</span>") == "<span>a</span><script>t()</script><span>b</span>")
        #expect(format("<span>a</span><!-- c --><span>b</span>") == "<span>a</span><!-- c --><span>b</span>")
    }

    @Test func preformattedTextIsKept() {
        let input = "<div><pre>  a\n    <b>b</b>  </pre><textarea>\n x </textarea></div>"
        let expected = "<div>\n  <pre>  a\n    <b>b</b>  </pre>\n  <textarea>\n x </textarea>\n</div>"
        #expect(format(input) == expected)
    }

    @Test func anInlineBlockStyledDivIsInline() {
        let input = #"<div><div style="display: inline-block">A</div><div style="DISPLAY:inline-flex">B</div></div>"#
        #expect(format(input) == """
        <div>
          <div style="display: inline-block">A</div><div style="DISPLAY:inline-flex">B</div>
        </div>
        """)
    }

    @Test func voidAndUnclosedElementsAreLenient() {
        let input = "<ul><li>a<li>b</ul><br><hr/><p>x"
        // Implied end tags (`li`, `p`, cells) are known, so the indentation follows the document.
        let expected = """
        <ul>
          <li>
            a
          <li>
            b
        </ul>
        <br>
        <hr/>
        <p>
          x
        """
        #expect(format(input) == expected)
        // A stray end tag is kept where it was.
        #expect(format("<div>a</span></div>") == "<div>\n  a</span>\n</div>")
        #expect(format("<table><tr><td>1<td>2<tr><td>3</table><p>a<div>b</div>") == """
        <table>
          <tr>
            <td>
              1
            <td>
              2
          <tr>
            <td>
              3
        </table>
        <p>
          a
        <div>
          b
        </div>
        """)
    }

    @Test func textWhitespaceBetweenInlineElementsIsKept() {
        #expect(format("<div><b>a</b>   <i>b</i>\n<u>c</u></div>") == "<div>\n  <b>a</b>   <i>b</i>\n<u>c</u>\n</div>")
    }

    @Test func breaksOnlyWhereWhitespaceIsNotRendered() throws {
        // Every inserted break is next to a block boundary or at the start of a line: compare the token streams with
        // whitespace removed, and the text content with whitespace collapsed.
        let input = #"<div><h1>T</h1><span>a</span><span>b</span><br><img src="x"><table><tr><td>1</td><td>2</td></tr></table></div>"#
        let formatted = try #require(format(input))
        #expect(formatted.filter { !$0.isWhitespace } == input.filter { !$0.isWhitespace })
        #expect(formatted.contains("<span>a</span><span>b</span>"))
        #expect(formatted.contains("<td>\n"))
    }

    @Test func unterminatedTagsFail() {
        #expect(TagFormatter.prettyPrinted("<div class=\"a", dialect: .html) == .failure(.unterminated(line: 1)))
        #expect(TagFormatter.prettyPrinted("<div><!-- x", dialect: .html) == .failure(.unterminated(line: 1)))
        // A lone "<" is text.
        #expect(format("<p>a < b</p>") == "<p>\n  a < b\n</p>")
    }

    @Test func aMegabyteIsQuick() throws {
        let unit = #"<div class="row"><a href="https://x.example/c?id=1"><img src="https://x.example/i.png" width="300"></a><p>Text <b>bold</b></p></div>"#
        let text = "<div>" + String(repeating: unit, count: 8_000) + "</div>"
        #expect(text.utf8.count > 1_000_000)
        let start = Date()
        let html = try #require(format(text))
        let xml = try #require(try? TagFormatter.prettyPrinted(text.replacingOccurrences(of: "width=\"300\">", with: "width=\"300\"/>"), dialect: .xml).get())
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(html.count > text.count && xml.count > text.count)
    }
}

@Suite("Tag formatter – pathological input")
struct TagFormatterStressTests {
    @Test func deepNestingStaysLinear() throws {
        // 200,000 open elements, then stray and implied end tags: must not scan the stack per tag.
        let deep = String(repeating: "<div>", count: 100_000) + String(repeating: "<span>", count: 100_000)
            + String(repeating: "<li>x</em>", count: 20_000) + "<pre> a </pre>"
        let start = Date()
        let html = try #require(try? TagFormatter.prettyPrinted(deep, dialect: .html, indentWidth: 0).get())
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(html.filter { !$0.isWhitespace } == deep.filter { !$0.isWhitespace })
        let xml = String(repeating: "<a>", count: 100_000) + String(repeating: "</a>", count: 100_000)
        #expect((try? TagFormatter.prettyPrinted(xml, dialect: .xml, indentWidth: 0).get()) != nil)
    }

    @Test func randomBytesNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("<>/!?-[]=\"' abcdivscriptprestyleCDATA\\nu003c{}:,\n\t&;".utf8)
        for _ in 0..<3_000 {
            let length = Int.random(in: 0..<120, using: &generator)
            let bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator) ?? 0x20 }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = TagFormatter.prettyPrinted(text, dialect: .html)
            _ = TagFormatter.prettyPrinted(text, dialect: .xml)
            _ = MarkupFormatter.format(text)
            _ = JSONEscapedText.unescaped(text)
        }
    }
}
