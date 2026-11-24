import AppKit
@testable import CcinnOpenRTB
import Foundation
import RTBKit
import SwiftUI
import Testing

/// The VAST wrapper from the issue, escaped the way an `adm` holds it (shortened tokens).
private let escapedWrapper = #"<VAST version=\"3.0\"><Ad><Wrapper><AdSystem><![CDATA[RTB House]]></AdSystem><VASTAdTagURI><![CDATA[https://ams.creativecdn.example/ad/imp-delivery?curl=https%3A%2F%2Fams.creativecdn.example%2Fad%2Fclicks&tk=DH7lXmn8_F6nMU7FX1WzTwyHemlR0]]></VASTAdTagURI><Impression><![CDATA[https://ams.creativecdn.example/ssp-notification/billing?wp=0.3757666&tk=DH7lXmn8]]></Impression><Impression><![CDATA[https://tk.adx.example/adx/tracking?d=eyJkYXRlX3RpbWUiOiIyMDI2&auction_price=${AUCTION_PRICE}]]></Impression><Error><![CDATA[https://ams.creativecdn.example/ad/imp-tags?tk=SFmlFMXQ&ed_errorCode=[ERRORCODE]]]></Error><Error><![CDATA[https://adx-tk.example/adx/tk_ssp_postback?d=eyJkYXRl]]></Error><Creatives></Creatives></Wrapper></Ad></VAST>"#

/// The Inspector's Markup and the Response editor drawn in a window: they render (smoke), and with
/// `CCINN_MARKUP_SNAPSHOTS=<dir>` they are written as PNGs, for looking at them.
@MainActor
@Suite("Markup views", .serialized)
struct MarkupViewsTests {
    private func candidate(_ markup: AdMarkup, format: AdFormat = .video) -> AdCandidate {
        AdCandidate(id: "1.1", bidID: "b", impID: "1", price: 2.7, currency: "USD", format: format, markup: markup)
    }

    @Test func theMarkupViewRendersEveryKindOfMarkup() async throws {
        let unescaped = try #require(JSONEscapedText.unescaped(escapedWrapper)).text
        let candidates = [
            candidate(.vast(.xml(unescaped))),
            candidate(.html("<div><img src=\"a.png\"></div>"), format: .banner),
            candidate(.native(#"{"native":{"assets":[]}}"#), format: .native),
            candidate(.vast(.url("https://ads.example/vast"))),
            AdCandidate(id: "1.1", bidID: "b", price: 1, format: .banner, markup: .none, winURL: "https://x.example/win"),
        ]
        for candidate in candidates {
            let harness = WindowHarness(InspectorMarkupView(candidate: candidate, deviceMarkup: nil), size: CGSize(width: 520, height: 400))
            harness.hosting.layoutSubtreeIfNeeded()
            #expect(harness.hosting.fittingSize.width > 0)
            harness.close()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CCINN_MARKUP_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_MARKUP_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A bid response whose adm is the wrapper: Inspector ▸ Markup, in the bid and on the device.
        let response = #"{"id":"r","seatbid":[{"seat":"g24","bid":[{"id":"b1","impid":"1","price":2.7,"mtype":2,"adm":""# + escapedWrapper + #""}]}]}"#
        let parsed = InputParser.parse(response)
        let bid = try #require(parsed.candidates.first)
        let device = AdMarkup.vast(.xml(try #require(JSONEscapedText.unescaped(escapedWrapper)).text.replacingOccurrences(of: "${AUCTION_PRICE}", with: "2.70")))
        try await snapshot(InspectorMarkupView(candidate: bid, deviceMarkup: device), size: CGSize(width: 760, height: 420),
                           to: directory.appendingPathComponent("inspector-markup.png"))

        // The Response editor after Format on the pasted, escaped wrapper.
        let formatted = try MarkupFormatter.format(escapedWrapper).get()
        let note = FormatNote(text: formatted.text, message: formatted.summary, isProblem: false)
        try await snapshot(VStack(spacing: 0) {
            HStack {
                Label("Format", systemImage: "text.alignleft")
                Spacer()
                FormatNoteLabel(note: note, text: formatted.text)
            }
            .padding(8)
            Divider()
            CodeEditor(text: .constant(formatted.text), accessibilityLabel: "Bid response")
        }, size: CGSize(width: 760, height: 360), to: directory.appendingPathComponent("response-formatted.png"))
    }

    private func snapshot(_ view: some View, size: CGSize, to url: URL) async throws {
        let harness = WindowHarness(view.background(Color(nsColor: .windowBackgroundColor)), size: size)
        harness.window.appearance = NSAppearance(named: .aqua)
        defer { harness.close() }
        try await Task.sleep(for: .seconds(1.5))
        let hosting = harness.hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
