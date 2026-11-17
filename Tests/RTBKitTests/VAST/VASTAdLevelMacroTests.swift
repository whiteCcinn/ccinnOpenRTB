import Foundation
import Testing
@testable import RTBKit

/// VAST 4.x ad-level identifiers (`AdServingId`, `UniversalAdId`, `Ad@adType`, `Category`) and the macros they fill
/// (VAST 4.1 / 4.2 §6.3 Ad Break Info and §6.7 Player State Info).
@Suite("VAST ad-level identifiers and macros")
struct VASTAdLevelMacroTests {
    private typealias F = VASTFixture
    private static let context = MacroContext(timestamp: Date(timeIntervalSince1970: 1_700_000_000), cacheBuster: "12345678")
    private static let macroKeys = ["[ADSERVINGID]", "[UNIVERSALADID]", "[ADTYPE]", "[ADCATEGORIES]"]

    /// The macro values the plan sets for an ad (or one of its companions).
    private func values(_ vast: ResolvedVAST, adIndex: Int = 0, companionIndex: Int? = nil) throws -> [String: String] {
        let planner = VASTPlanner(vast: vast, context: Self.context, source: "bid 0.0")
        let context = try #require(planner.macroContext(adIndex: adIndex, companionIndex: companionIndex))
        return context.custom.filter { Self.macroKeys.contains($0.key) }
    }

    private static func inline(version: String, adAttributes: String = "", inlineExtra: String = "", universalAdIds: String) -> String {
        """
        <VAST version="\(version)"><Ad id="a"\(adAttributes)><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle>
        <Impression>https://tracker.example/i?sid=[ADSERVINGID]&amp;uid=[UNIVERSALADID]&amp;type=[ADTYPE]&amp;cat=[ADCATEGORIES]</Impression>
        \(inlineExtra)
        <Creatives><Creative>\(universalAdIds)<Linear><Duration>00:00:10</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1280" height="720">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
    }

    // MARK: Parsing

    @Test func vast42SampleCarriesItsIdentifiers() throws {
        let (document, issues) = try parsedDocument(VASTSamples.inline42Verification)
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty)
        let ad = try #require(document.ads.first)
        #expect(ad.adType == "video")
        guard case let .inline(inline) = ad.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.adServingID == "ccinn-42-serving-0001")
        #expect(inline.creatives.map(\.universalAdIDs) == [[VASTUniversalAdID(registry: "Ad-ID", value: "CCIN0042000H")],
                                                          [VASTUniversalAdID(registry: "unknown", value: "unknown")]])
    }

    /// VAST 4.1 §3.7.1: "always use the Content as the source of truth"; the 4.0 `idValue` attribute is the fallback.
    @Test func universalAdIdContentWinsOverIdValue() throws {
        func ids(_ element: String) throws -> ([VASTUniversalAdID], [ValidationIssue]) {
            let (document, issues) = try parsedDocument(Self.inline(version: "4.0", universalAdIds: element))
            guard case let .inline(inline) = document.ads.first?.body else { return ([], issues) }
            return (inline.creatives.first?.universalAdIDs ?? [], issues)
        }
        #expect(try ids(#"<UniversalAdId idRegistry="ad-id.org" idValue="OLD">  CNPA0484000H </UniversalAdId>"#).0
            == [VASTUniversalAdID(registry: "ad-id.org", value: "CNPA0484000H")])
        #expect(try ids(#"<UniversalAdId idRegistry="ad-id.org" idValue="CNPA0484000H"></UniversalAdId>"#).0
            == [VASTUniversalAdID(registry: "ad-id.org", value: "CNPA0484000H")])
        let (defaulted, issues) = try ids("<UniversalAdId/>")
        #expect(defaulted == [VASTUniversalAdID(registry: "unknown", value: "unknown")])
        #expect(issues.issue("vast.universalAdId.idRegistry.missing")?.severity == .warning)
    }

    @Test func severalUniversalAdIdsAreAVAST42Feature() throws {
        let two = #"<UniversalAdId idRegistry="ad-id.org">CNPA0484000H</UniversalAdId><UniversalAdId idRegistry="clearcast.co.uk">AAA/BBBB123/030</UniversalAdId>"#
        let (document42, issues42) = try parsedDocument(Self.inline(version: "4.2", inlineExtra: "<AdServingId>s</AdServingId>", universalAdIds: two))
        guard case let .inline(inline) = document42.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.creatives.first?.universalAdIDs.map(\.value) == ["CNPA0484000H", "AAA/BBBB123/030"])
        #expect(!issues42.codes().contains("vast.element.newerVersion"))
        let (_, issues41) = try parsedDocument(Self.inline(version: "4.1", inlineExtra: "<AdServingId>s</AdServingId>", universalAdIds: two))
        #expect(issues41.issue("vast.element.newerVersion")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/UniversalAdId[2]")
    }

    @Test func categoriesNeedAnAuthority() throws {
        let categories = #"<Category authority="https://www.iabtechlab.com/categoryauthority">232</Category><Category>IAB1-6</Category><Category authority="x"> </Category>"#
        let xml = Self.inline(version: "4.1", inlineExtra: "<AdServingId>s</AdServingId>" + categories,
                              universalAdIds: #"<UniversalAdId idRegistry="unknown">unknown</UniversalAdId>"#)
        let (document, issues) = try parsedDocument(xml)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.categories == [VASTCategory(code: "232", authority: "https://www.iabtechlab.com/categoryauthority"),
                                      VASTCategory(code: "IAB1-6")])
        #expect(issues.issue("vast.inline.category.authority.missing")?.path == "VAST/Ad[1]/InLine/Category[2]@authority")
        #expect(issues.issue("vast.inline.category.empty")?.path == "VAST/Ad[1]/InLine/Category[3]")
    }

    @Test func adTypeValues() throws {
        func parsed(_ attributes: String, version: String = "4.1") throws -> (String?, [ValidationIssue]) {
            let xml = Self.inline(version: version, adAttributes: attributes, inlineExtra: "<AdServingId>s</AdServingId>",
                                  universalAdIds: #"<UniversalAdId idRegistry="unknown">unknown</UniversalAdId>"#)
            let (document, issues) = try parsedDocument(xml)
            return (document.ads.first?.adType, issues)
        }
        #expect(try parsed(#" adType="audio""#).0 == "audio")
        #expect(try parsed(#" adType=" hybrid ""#).0 == "hybrid")
        #expect(try parsed("").0 == nil)
        let (invalid, issues) = try parsed(#" adType="banner""#)
        #expect(invalid == "banner")
        #expect(issues.issue("vast.ad.adType.invalid")?.severity == .warning)
        #expect(try parsed(#" adType="audio""#, version: "4.0").1.issue("vast.element.newerVersion")?.path == "VAST/Ad[1]@adType")
    }

    // MARK: Macro values per ad

    @Test func vast42ValuesForTheAdAndItsCompanions() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        #expect(try values(vast) == ["[ADSERVINGID]": "ccinn-42-serving-0001", "[UNIVERSALADID]": "Ad-ID CCIN0042000H", "[ADTYPE]": "video"])
        // A companion's requests name its own creative.
        #expect(try values(vast, companionIndex: 0)["[UNIVERSALADID]"] == "unknown unknown")
    }

    @Test func vast41PodValuesArePerAd() async throws {
        let vast = await resolved(VASTSamples.pod41)
        for index in 0..<2 {
            #expect(try values(vast, adIndex: index) == ["[ADSERVINGID]": "ccinn-pod-41-serving-\(index + 1)",
                                                         "[UNIVERSALADID]": "Ad-ID CCIN004100\(index + 1)H", "[ADTYPE]": "video"])
        }
    }

    /// VAST 4.1 §3.3.2: `adType` is "assumed to be video if attribute is not present"; the attribute exists from VAST 4.1.
    @Test func adTypeDefaultsToVideoFromVAST41() async throws {
        let ids = #"<UniversalAdId idRegistry="unknown">unknown</UniversalAdId>"#
        let absent = await resolved(Self.inline(version: "4.1", inlineExtra: "<AdServingId>s</AdServingId>", universalAdIds: ids))
        #expect(try values(absent)["[ADTYPE]"] == "video")
        let audio = await resolved(Self.inline(version: "4.2", adAttributes: #" adType="audio""#, inlineExtra: "<AdServingId>s</AdServingId>",
                                               universalAdIds: ids))
        #expect(try values(audio)["[ADTYPE]"] == "audio")
    }

    @Test func vast40HasOnlyTheUniversalAdId() async throws {
        let vast = await resolved(VASTSamples.inline40)
        #expect(try values(vast) == ["[UNIVERSALADID]": "Ad-ID CCIN0040000H"])
    }

    @Test func vast30LeavesThemUnknown() async throws {
        for xml in [VASTSamples.inline30Skippable, VASTSamples.inline20] {
            #expect(try values(await resolved(xml)).isEmpty)
        }
    }

    /// `[ADCATEGORIES]` is a VAST request macro ("List of desired ad categories", VAST 4.1 / 4.2 §6.3): the ad's own
    /// `Category` never fills it on tracking pixels.
    @Test func adCategoriesIsNotFilledFromTheAdsCategory() async throws {
        let xml = Self.inline(version: "4.2", inlineExtra: #"<AdServingId>s</AdServingId><Category authority="iabtechlab.com">232</Category>"#,
                              universalAdIds: #"<UniversalAdId idRegistry="unknown">unknown</UniversalAdId>"#)
        #expect(try values(await resolved(xml))["[ADCATEGORIES]"] == nil)
    }

    @Test func severalUniversalAdIdsAreCommaSeparated() async throws {
        let two = #"<UniversalAdId idRegistry="ad-id.org">CNPA0484000H</UniversalAdId><UniversalAdId idRegistry="clearcast.co.uk">AAA/BBBB123/030</UniversalAdId>"#
        let vast = await resolved(Self.inline(version: "4.2", inlineExtra: "<AdServingId>s</AdServingId>", universalAdIds: two))
        #expect(try values(vast)["[UNIVERSALADID]"] == "ad-id.org CNPA0484000H,clearcast.co.uk AAA/BBBB123/030")
    }

    @Test func outOfRangeIndicesHaveNoContext() async {
        let vast = await resolved(VASTSamples.inline42Verification)
        let planner = VASTPlanner(vast: vast, context: Self.context, source: "s")
        for (adIndex, companionIndex) in [(-1, nil), (1, nil), (Int.max, nil), (0, -1), (0, 2), (0, Int.max)] as [(Int, Int?)] {
            #expect(planner.macroContext(adIndex: adIndex, companionIndex: companionIndex) == nil)
        }
    }

    // MARK: Expansion (enabled once kit-openrtb's MacroExpander is merged)

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func expandedOnTrackingPixelsPerVersion() async throws {
        func impression(_ xml: String) async throws -> String {
            let vast = await resolved(xml)
            let request = try #require(VASTTrackingPlan.requests(for: .video(.creativeView, adIndex: 0), vast: vast, candidate: nil,
                                                                 context: Self.context, source: "s").first)
            return request.url
        }
        let ids = #"<UniversalAdId idRegistry="ad-id.org">CNPA0484000H</UniversalAdId>"#
        #expect(try await impression(Self.inline(version: "4.2", adAttributes: #" adType="hybrid""#,
                                                 inlineExtra: #"<AdServingId>ServerName-47ed3bac</AdServingId><Category authority="x">232</Category>"#,
                                                 universalAdIds: ids))
            == "https://tracker.example/i?sid=ServerName-47ed3bac&uid=ad-id.org%20CNPA0484000H&type=hybrid&cat=-1")
        #expect(try await impression(Self.inline(version: "4.1", inlineExtra: "<AdServingId>s-1</AdServingId>", universalAdIds: ids))
            == "https://tracker.example/i?sid=s-1&uid=ad-id.org%20CNPA0484000H&type=video&cat=-1")
        #expect(try await impression(Self.inline(version: "4.0", universalAdIds: #"<UniversalAdId idRegistry="ad-id.org" idValue="CNPA0484000H"/>"#))
            == "https://tracker.example/i?sid=-1&uid=ad-id.org%20CNPA0484000H&type=-1&cat=-1")
        #expect(try await impression(Self.inline(version: "3.0", universalAdIds: ""))
            == "https://tracker.example/i?sid=-1&uid=-1&type=-1&cat=-1")
    }
}
