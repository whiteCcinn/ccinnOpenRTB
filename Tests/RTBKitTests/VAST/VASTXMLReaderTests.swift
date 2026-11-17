import Foundation
import Testing
@testable import RTBKit

@Suite("VAST XML reader")
struct VASTXMLReaderTests {
    private func root(_ xml: String, limits: VASTXMLReader.Limits = .standard) throws -> VASTXMLElement {
        try VASTXMLReader.read(xml, limits: limits).get()
    }

    @Test func stripsNamespacePrefixesAndDeclarations() throws {
        let element = try root("""
        <vast:VAST xmlns:vast="http://www.iab.com/VAST" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" vast:version="4.1">
          <vast:Ad id="1"/>
        </vast:VAST>
        """)
        #expect(element.name == "VAST")
        #expect(element.attributes == ["version": "4.1"])
        #expect(element.children.map(\.name) == ["Ad"])
    }

    @Test func defaultNamespaceIsTolerated() throws {
        let element = try root(#"<VAST xmlns="http://www.iab.com/VAST" version="4.2"><Ad/></VAST>"#)
        #expect(element.attribute("version") == "4.2")
        #expect(element.attribute("xmlns") == nil)
    }

    @Test func cdataAndWhitespaceAreKeptAndTrimmedOnRequest() throws {
        let element = try root("<Impression>\n   <![CDATA[  https://tracker.example/i?a=1&b=2  ]]>\n </Impression>")
        #expect(element.trimmedText == "https://tracker.example/i?a=1&b=2")
        #expect(element.text.hasPrefix("\n"))
    }

    @Test func predefinedEntitiesAreDecoded() throws {
        let element = try root("<Impression>https://tracker.example/i?a=1&amp;b=2&lt;</Impression>")
        #expect(element.trimmedText == "https://tracker.example/i?a=1&b=2<")
    }

    @Test func prologWithBOMDeclarationAndCommentsIsAccepted() throws {
        let element = try root("\u{FEFF}  <?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<!-- served by x -->\n<VAST version=\"3.0\"/>")
        #expect(element.name == "VAST")
    }

    @Test func doctypeInsideCDATAIsContentNotADTD() throws {
        let element = try root("<HTMLResource><![CDATA[<!DOCTYPE html><html></html>]]></HTMLResource>")
        #expect(element.trimmedText == "<!DOCTYPE html><html></html>")
    }

    @Test func attributeLookupFallsBackToCaseInsensitive() throws {
        let element = try root(#"<Creative AdID="a-1"/>"#)
        #expect(element.attribute("adId") == "a-1")
    }

    @Test func billionLaughsIsRejectedBeforeParsing() {
        let laughs = """
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
          <!ENTITY lol "lol">
          <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
          <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
          <!ENTITY lol9 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
        ]>
        <VAST version="3.0"><Error>&lol9;</Error></VAST>
        """
        let started = Date()
        #expect(VASTXMLReader.read(laughs) == .failure(.doctypeNotAllowed))
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func externalEntityDoctypeIsRejected() {
        let xxe = #"<!DOCTYPE VAST [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><VAST version="3.0"><Error>&xxe;</Error></VAST>"#
        #expect(VASTXMLReader.read(xxe) == .failure(.doctypeNotAllowed))
    }

    @Test func limitsAreEnforced() {
        let limits = VASTXMLReader.Limits(maxBytes: 200, maxDepth: 4, maxElements: 5, maxTextLength: 10)
        #expect(VASTXMLReader.read(String(repeating: " ", count: 201) + "<a/>", limits: limits) == .failure(.tooLarge(bytes: 205, limit: 200)))
        #expect(VASTXMLReader.read("<a><b><c><d><e/></d></c></b></a>", limits: limits) == .failure(.tooDeep(limit: 4)))
        #expect(VASTXMLReader.read("<a><b/><b/><b/><b/><b/></a>", limits: limits) == .failure(.tooManyElements(limit: 5)))
        #expect(VASTXMLReader.read("<a>01234567890</a>", limits: limits) == .failure(.tooMuchText(limit: 10)))
    }

    @Test func deepNestingIsCappedWithStandardLimits() {
        let depth = 10_000
        let xml = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        #expect(VASTXMLReader.read(xml) == .failure(.tooDeep(limit: VASTXMLReader.Limits.standard.maxDepth)))
    }

    @Test(arguments: ["", "   \n ", "<?xml version=\"1.0\"?>"])
    func emptyDocuments(_ xml: String) {
        #expect(VASTXMLReader.read(xml) == .failure(.empty))
    }

    @Test(arguments: ["<VAST>", "<VAST><Ad></VAST>", "not xml", "<VAST version=\"3.0\"><Error>&undefined;</Error></VAST>", "<a></a><b></b>"])
    func malformedDocumentsFail(_ xml: String) {
        guard case let .failure(failure) = VASTXMLReader.read(xml), case .malformed = failure else {
            Issue.record("expected a malformed failure for \(xml)")
            return
        }
    }
}

@Suite("VAST time format")
struct VASTTimeFormatTests {
    @Test(arguments: [
        ("00:00:15", 15.0), ("00:00:15.500", 15.5), ("01:02:03.25", 3723.25), ("  00:00:30  ", 30.0), ("100:00:00", 360_000.0),
        ("00:00:00", 0.0),
    ])
    func validTimes(_ text: String, _ seconds: Double) {
        #expect(VASTTimeFormat.seconds(from: text) == seconds)
    }

    @Test(arguments: ["15", "00:15", "00:60:00", "00:00:60", "aa:bb:cc", "-0:00:01", "00:00:15.", "00:00:+5", "", "00:00:1 5", "00:00:05.1234567890"])
    func invalidTimes(_ text: String) {
        #expect(VASTTimeFormat.seconds(from: text) == nil)
    }

    @Test func offsets() {
        #expect(VASTTimeFormat.offset(from: "25%") == .percent(25))
        #expect(VASTTimeFormat.offset(from: "12.5%") == .percent(12.5))
        #expect(VASTTimeFormat.offset(from: "100%") == .percent(100))
        #expect(VASTTimeFormat.offset(from: "0%") == .percent(0))
        #expect(VASTTimeFormat.offset(from: "00:00:10") == .seconds(10))
        #expect(VASTTimeFormat.offset(from: " 00:00:10.250 ") == .seconds(10.25))
        for invalid in ["101%", "%", "-5%", "2 5%", "1e2%", ".5%", "5.%", "25", "nan%", "10%%"] {
            #expect(VASTTimeFormat.offset(from: invalid) == nil, "\(invalid)")
        }
    }

    @Test func percentVersusSecondsResolveAgainstTheDuration() {
        #expect(VASTOffset.percent(25).seconds(inAdOf: 15) == 3.75)
        #expect(VASTOffset.seconds(10).seconds(inAdOf: 15) == 10)
    }

    @Test func formatting() {
        #expect(VASTOffset.seconds(10).vastText == "00:00:10")
        #expect(VASTOffset.seconds(3723.25).vastText == "01:02:03.250")
        #expect(VASTOffset.percent(25).vastText == "25%")
        #expect(VASTOffset.percent(12.5).vastText == "12.5%")
        #expect(VASTEvent.progress(.seconds(10)).vastLabel == "progress 00:00:10")
        #expect(VASTEvent.firstQuartile.vastLabel == "firstQuartile")
        #expect(VASTOffset(vastText: "50%") == .percent(50))
    }

    @Test func extremeOffsetsFormatWithoutTrapping() {
        // Clamped to 10^15 ms.
        #expect(VASTOffset.seconds(1e300).vastText == "277777777:46:40")
        #expect(VASTOffset.percent(1e300).vastText.hasSuffix("%"))
        #expect(VASTOffset.seconds(-1).vastText == "00:00:00")
        #expect(VASTOffset.seconds(.nan).vastText == "00:00:00")
        #expect(VASTOffset.percent(.infinity).vastText == "0%")
        #expect(VASTEvent.progress(.seconds(.infinity)).vastLabel == "progress 00:00:00")
    }
}
