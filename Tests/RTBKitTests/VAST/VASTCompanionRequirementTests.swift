import Foundation
import Testing
@testable import RTBKit

/// VAST 3.0+ `CompanionAds@required` (VAST 4.1 §3.13.1): "all" — the player must display every companion, or not
/// display the ad; "any" — at least one, or not display the ad; "none" (the default when absent) — companions are
/// optional. An unmet requirement is VAST error 602 "Unable to display Required Companion" (VAST 4.1 §2.3.6.3).
@Suite("VAST CompanionAds@required")
struct VASTCompanionRequirementTests {
    static func document(version: String = "4.1", required: String?) -> String {
        let attribute = required.map { " required=\"\($0)\"" } ?? ""
        return """
        <VAST version="\(version)"><Ad id="a"><InLine><AdSystem>S</AdSystem><AdTitle>T</AdTitle><AdServingId>x</AdServingId>
        <Impression><![CDATA[https://t.example/imp]]></Impression>
        <Creatives>
        <Creative id="lin"><UniversalAdId idRegistry="unknown">unknown</UniversalAdId><Linear><Duration>00:00:15</Duration><MediaFiles>
        <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[https://cdn.example/a.mp4]]></MediaFile>
        </MediaFiles></Linear></Creative>
        <Creative id="comp"><UniversalAdId idRegistry="unknown">unknown</UniversalAdId><CompanionAds\(attribute)>
        <Companion id="big" width="300" height="250"><StaticResource creativeType="image/png"><![CDATA[https://cdn.example/300x250.png]]></StaticResource></Companion>
        <Companion id="small" width="320" height="50"><StaticResource creativeType="image/png"><![CDATA[https://cdn.example/320x50.png]]></StaticResource></Companion>
        </CompanionAds></Creative>
        </Creatives></InLine></Ad></VAST>
        """
    }

    static func inline(_ xml: String) throws -> VASTInline {
        guard case let .inline(inline) = try #require(VASTParser.parse(xml).document?.ads.first).body else {
            throw Missing()
        }
        return inline
    }

    struct Missing: Error {}

    @Test func requiredIsParsedPerCreativeWithNoneAsTheDefault() throws {
        for (raw, expected) in [("all", VASTCompanionRequirement.all), ("any", .any), ("none", .none), (nil, .none)] as [(String?, VASTCompanionRequirement)] {
            let inline = try Self.inline(Self.document(required: raw))
            #expect(inline.creatives.map(\.companionsRequired) == [.none, expected], "\(raw ?? "absent")")
        }
    }

    @Test func invalidOrPreVAST3RequiredIsReported() {
        let invalid = VASTParser.parse(Self.document(required: "some")).issues
        #expect(invalid.contains { $0.code == "vast.companionAds.required.invalid" && $0.severity == .warning
                && $0.path == "VAST/Ad[1]/InLine/Creatives/Creative[2]/CompanionAds@required" })
        let old = VASTParser.parse(Self.document(version: "2.0", required: "all")).issues
        #expect(old.contains { $0.code == "vast.element.newerVersion" && $0.path.hasSuffix("CompanionAds@required") })
    }

    /// The player says which companions it can show (none on CTV, which has no companion slots); the predicate says
    /// whether the ad may play.
    @Test func satisfiabilityFollowsTheRequirement() throws {
        let everything: (VASTCompanion) -> Bool = { _ in true }
        let nothing: (VASTCompanion) -> Bool = { _ in false }
        let onlyBig: (VASTCompanion) -> Bool = { $0.id == "big" }

        let all = try Self.inline(Self.document(required: "all"))
        #expect(all.companionRequirementError(canShow: everything) == nil)
        #expect(all.companionRequirementError(canShow: onlyBig) == .requiredCompanionUnavailable)
        #expect(all.companionRequirementError(canShow: nothing) == .requiredCompanionUnavailable)

        let any = try Self.inline(Self.document(required: "any"))
        #expect(any.companionRequirementError(canShow: onlyBig) == nil)
        #expect(any.companionRequirementError(canShow: nothing) == .requiredCompanionUnavailable)

        for raw in ["none", nil] as [String?] {
            let optional = try Self.inline(Self.document(required: raw))
            #expect(optional.companionRequirementError(canShow: nothing) == nil, "\(raw ?? "absent")")
        }
        #expect(all.creatives.map { $0.isCompanionRequirementSatisfiable(canShow: onlyBig) } == [true, false])
    }

    /// A requirement over no companions requires nothing (and is reported as a trafficking mistake).
    @Test func aRequirementWithoutCompanionsIsVacuous() {
        let creative = VASTCreative(companions: [], companionsRequired: .all)
        #expect(creative.isCompanionRequirementSatisfiable { _ in false })
        #expect(VASTCreative(companionsRequired: .any).isCompanionRequirementSatisfiable { _ in false })
    }

    /// VAST 4.1 §2.3.6.3 / 4.2 error table: the codes the simulator had no case for.
    @Test func theRemainingErrorCodesExist() {
        let expected: [(VASTErrorCode, Int)] = [
            (.adCategoryRequired, 204), (.blockedAdCategory, 205), (.adBreakShortened, 206),
            (.nonLinearDimensions, 501), (.nonLinearResourceUnavailable, 502), (.nonLinearResourceUnsupported, 503),
            (.companionDimensions, 601), (.requiredCompanionUnavailable, 602), (.companionResourceUnavailable, 603),
            (.companionResourceUnsupported, 604),
        ]
        for (code, raw) in expected {
            #expect(code.rawValue == raw)
            #expect(VASTErrorCode(rawValue: raw) == code)
        }
    }
}
