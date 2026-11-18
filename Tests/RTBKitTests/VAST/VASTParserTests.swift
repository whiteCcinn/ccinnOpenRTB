import Foundation
import Testing
@testable import RTBKit

/// Fixtures modelled on the IAB Tech Lab VAST sample tags (github.com/InteractiveAdvertisingBureau/VAST_Samples).
@Suite("VAST parser")
struct VASTParserTests {
    /// Shape of IAB "VAST 4.1 Samples/Inline_Linear_Tag-test.xml".
    static let iabInline41 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.1" xmlns="http://www.iab.com/VAST">
      <Ad id="20001" sequence="1" conditionalAd="false">
        <InLine>
          <AdSystem version="4.0">iabtechlab</AdSystem>
          <Error>https://example.com/error</Error>
          <Extensions>
            <Extension type="iab-Count">
              <total_available>
                <![CDATA[ 2 ]]>
              </total_available>
            </Extension>
          </Extensions>
          <Impression id="Impression-ID">https://example.com/track/impression</Impression>
          <Pricing model="cpm" currency="USD">
            <![CDATA[ 25.00 ]]>
          </Pricing>
          <AdServingId>a532d16d-4d7f-4440-bd29-2ec05553fc80</AdServingId>
          <AdTitle>iabtechlab video ad</AdTitle>
          <Category authority="https://www.iabtechlab.com/categoryauthority">AD CONTENT description category</Category>
          <Creatives>
            <Creative id="5480" sequence="1" adId="2447226">
              <CompanionAds>
                <Companion id="1232" width="100" height="150" assetWidth="250" assetHeight="200" expandedWidth="350" expandedHeight="250" apiFramework="VPAID" adSlotID="3214" pxratio="1400">
                  <StaticResource creativeType="image/png">
                    <![CDATA[https://www.iab.com/wp-content/uploads/2014/09/iab-tech-lab-6-644x290.png]]>
                  </StaticResource>
                  <CompanionClickThrough>
                    <![CDATA[https://iabtechlab.com]]>
                  </CompanionClickThrough>
                </Companion>
              </CompanionAds>
            </Creative>
            <Creative id="5481" sequence="1" adId="2447226">
              <UniversalAdId idRegistry="Ad-ID">8465</UniversalAdId>
              <Linear>
                <TrackingEvents>
                  <Tracking event="start">https://example.com/tracking/start</Tracking>
                  <Tracking event="firstQuartile">https://example.com/tracking/firstQuartile</Tracking>
                  <Tracking event="midpoint">https://example.com/tracking/midpoint</Tracking>
                  <Tracking event="thirdQuartile">https://example.com/tracking/thirdQuartile</Tracking>
                  <Tracking event="complete">https://example.com/tracking/complete</Tracking>
                  <Tracking event="progress" offset="00:00:10">https://example.com/tracking/progress-10</Tracking>
                </TrackingEvents>
                <Duration>00:00:16</Duration>
                <MediaFiles>
                  <MediaFile id="5241" delivery="progressive" type="video/mp4" bitrate="2000" width="1280" height="720" minBitrate="1500" maxBitrate="2500" scalable="1" maintainAspectRatio="1" codec="H.264">
                    <![CDATA[https://iab-publicfiles.s3.amazonaws.com/vast/VAST-4.0-Short-Intro.mp4]]>
                  </MediaFile>
                  <MediaFile id="5244" delivery="progressive" type="video/mp4" bitrate="1000" width="854" height="480" minBitrate="700" maxBitrate="1500" scalable="1" maintainAspectRatio="1" codec="H.264">
                    <![CDATA[https://iab-publicfiles.s3.amazonaws.com/vast/VAST-4.0-Short-Intro-mid-resolution.mp4]]>
                  </MediaFile>
                </MediaFiles>
                <VideoClicks>
                  <ClickThrough id="blog">
                    <![CDATA[https://iabtechlab.com]]>
                  </ClickThrough>
                </VideoClicks>
              </Linear>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    @Test func iabInlineLinear41() throws {
        let (document, issues) = try parsedDocument(Self.iabInline41)
        #expect(document.version == "4.1")
        #expect(issues.codes(.error).isEmpty)
        #expect(document.errors.isEmpty)
        let ad = try #require(document.ads.first)
        #expect(ad.id == "20001")
        #expect(ad.sequence == 1)
        guard case let .inline(inline) = ad.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.adSystem == "iabtechlab")
        #expect(inline.adTitle == "iabtechlab video ad")
        #expect(inline.impressions == ["https://example.com/track/impression"])
        #expect(inline.errors == ["https://example.com/error"])
        #expect(inline.creatives.map(\.id) == ["5480", "5481"])
        #expect(inline.creatives.map(\.adID) == ["2447226", "2447226"])
        #expect(inline.creatives[0].companions.first?.resources == [
            .staticResource(url: "https://www.iab.com/wp-content/uploads/2014/09/iab-tech-lab-6-644x290.png", creativeType: "image/png"),
        ])
        #expect(inline.creatives[0].companions.first?.clickThrough == "https://iabtechlab.com")

        let linear = try #require(inline.playedLinear)
        #expect(linear.duration == 16)
        #expect(linear.clickThrough == "https://iabtechlab.com")
        #expect(linear.trackingEvents.map(\.event) == [.start, .firstQuartile, .midpoint, .thirdQuartile, .complete, .progress(.seconds(10))])
        #expect(linear.mediaFiles.count == 2)
        #expect(linear.mediaFiles[0] == VASTMediaFile(url: "https://iab-publicfiles.s3.amazonaws.com/vast/VAST-4.0-Short-Intro.mp4",
                                                      delivery: "progressive", type: "video/mp4", width: 1280, height: 720, bitrate: 2000,
                                                      minBitrate: 1500, maxBitrate: 2500, codec: "H.264", scalable: true,
                                                      maintainAspectRatio: true))
        // Companion-only creative without UniversalAdId: VAST 4.1 requires one in every creative.
        #expect(issues.issue("vast.creative.universalAdId.missing")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/UniversalAdId")
    }

    /// Shape of IAB "VAST 4.1 Samples/Wrapper_Tag-test.xml".
    @Test func iabWrapper41() throws {
        let xml = """
        <VAST version="4.1" xmlns="http://www.iab.com/VAST">
          <Ad id="20011" sequence="1" conditionalAd="false">
            <Wrapper followAdditionalWrappers="0" allowMultipleAds="1" fallbackOnNoAd="0">
              <AdSystem version="4.0">iabtechlab</AdSystem>
              <Error>http://example.com/error</Error>
              <Impression id="Impression-ID">http://example.com/track/impression</Impression>
              <Creatives>
                <Creative id="5480" sequence="1" adId="2447226">
                  <CompanionAds>
                    <Companion id="1232" width="100" height="150">
                      <StaticResource creativeType="image/png"><![CDATA[https://www.iab.com/wp-content/uploads/2014/09/iab-tech-lab-6-644x290.png]]></StaticResource>
                      <CompanionClickThrough><![CDATA[https://iabtechlab.com]]></CompanionClickThrough>
                    </Companion>
                  </CompanionAds>
                </Creative>
              </Creatives>
              <VASTAdTagURI>
                <![CDATA[https://raw.githubusercontent.com/InteractiveAdvertisingBureau/VAST_Samples/master/VAST%204.0%20Samples/Inline_Companion_Tag-test.xml]]>
              </VASTAdTagURI>
            </Wrapper>
          </Ad>
        </VAST>
        """
        let (document, issues) = try parsedDocument(xml)
        guard case let .wrapper(wrapper) = document.ads.first?.body else {
            Issue.record("expected a wrapper")
            return
        }
        #expect(wrapper.adTagURI.hasPrefix("https://raw.githubusercontent.com/"))
        #expect(!wrapper.followAdditionalWrappers)
        #expect(wrapper.allowMultipleAds)
        #expect(!wrapper.fallbackOnNoAd)
        #expect(wrapper.impressions == ["http://example.com/track/impression"])
        #expect(wrapper.creatives.first?.companions.count == 1)
        #expect(issues.codes(.error).isEmpty)
        #expect(issues.codes(.info).contains("vast.url.insecure"))
    }

    @Test func wrapperDefaultsAndTrackingOnlyCreatives() throws {
        let (document, _) = try parsedDocument(VASTFixture.wrapper(name: "w", adTagURI: "https://ads.example/vast"))
        guard case let .wrapper(wrapper) = document.ads.first?.body else {
            Issue.record("expected a wrapper")
            return
        }
        #expect(wrapper.followAdditionalWrappers)
        #expect(!wrapper.allowMultipleAds)
        #expect(!wrapper.fallbackOnNoAd)
        #expect(wrapper.creatives.first?.linear?.trackingEvents == [VASTTracking(event: .start, url: VASTFixture.url("w", "start"))])
        #expect(wrapper.creatives.first?.linear?.clickTrackings == [VASTFixture.url("w", "click")])
        #expect(wrapper.creatives.first?.linear?.mediaFiles == [])
    }

    @Test func vast20Sample() throws {
        let (document, issues) = try parsedDocument(VASTSamples.inline20)
        #expect(document.version == "2.0")
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.impressions == ["https://tracker.example/vast20/impression", "https://tracker.example/vast20/impression-3p"])
        #expect(inline.creatives.first?.adID == "ccinn-20")
        let events = inline.playedLinear?.trackingEvents.map(\.event) ?? []
        #expect(events.contains(.fullscreen))
        #expect(events.contains(.close))
        #expect(issues.codes(.error).isEmpty)
        #expect(issues.codes(.warning).isEmpty)
    }

    @Test func skippableProgressAndCompanion30() throws {
        let (document, issues) = try parsedDocument(VASTSamples.inline30Skippable)
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        let linear = try #require(inline.playedLinear)
        #expect(linear.skipOffset == .seconds(5))
        let progress = linear.trackingEvents.compactMap { tracking -> VASTOffset? in
            if case let .progress(offset) = tracking.event { return offset }
            return nil
        }
        #expect(progress == [.seconds(10), .percent(25)])
        let companion = try #require(inline.creatives.flatMap(\.companions).first)
        #expect(companion.width == 300 && companion.height == 250)
        #expect(companion.resources == [.staticResource(url: VASTSamples.companionImageURL, creativeType: "image/png")])
        #expect(companion.trackingEvents == [VASTTracking(event: .creativeView, url: "https://tracker.example/vast30/companion/creativeView")])
        #expect(companion.clickTrackings == ["https://tracker.example/vast30/companion/click"])
    }

    @Test func mezzanineAndUniversalAdId40() throws {
        let (document, issues) = try parsedDocument(VASTSamples.inline40)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.playedLinear?.mediaFiles.count == 1)
        #expect(inline.viewableImpression?.viewable == ["https://tracker.example/vast40/viewable"])
        #expect(issues.codes(.info).contains("vast.mezzanine.notPlayed"))
        #expect(!issues.codes().contains("vast.creative.universalAdId.missing"))
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty)
    }

    @Test func verificationsViewabilityAndCompanions42() throws {
        let (document, issues) = try parsedDocument(VASTSamples.inline42Verification)
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        let verification = try #require(inline.verifications.first)
        #expect(verification.vendor == "tracker.example-omid")
        #expect(verification.javaScriptResource == "https://tracker.example/omid/verification-client.js")
        #expect(verification.parameters == #"{"partner":"ccinn","campaign":"sample-42"}"#)
        #expect(verification.trackingEvents == [
            VASTTracking(event: .other("verificationNotExecuted"), url: "https://tracker.example/vast42/verification/not-executed?reason=[REASON]"),
        ])
        #expect(inline.viewableImpression?.notViewable == ["https://tracker.example/vast42/not-viewable"])
        let companions = inline.creatives.flatMap(\.companions)
        #expect(companions.map(\.id) == ["ccinn-companion-static", "ccinn-companion-html"])
        guard case let .html(html) = companions[1].resources.first else {
            Issue.record("expected an HTML resource")
            return
        }
        #expect(html.hasPrefix("<!DOCTYPE html>"))
    }

    @Test func vast30ExtensionVerificationsWithoutVersionNoise() throws {
        let extensionXML = """
        <Extensions>
          <Extension type="AdVerifications">
            <AdVerifications>
              <Verification vendor="vendor.example-omid">
                <JavaScriptResource apiFramework="omid"><![CDATA[https://tracker.example/omid.js]]></JavaScriptResource>
                <VerificationParameters><![CDATA[k=v]]></VerificationParameters>
                <TrackingEvents>
                  <Tracking event="verificationNotExecuted"><![CDATA[https://tracker.example/vne?r=[REASON]]]></Tracking>
                </TrackingEvents>
              </Verification>
            </AdVerifications>
          </Extension>
          <Extension type="other"><Anything/></Extension>
        </Extensions>
        """
        let (document, issues) = try parsedDocument(VASTFixture.inline(version: "3.0", extraInline: extensionXML))
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.verifications.map(\.vendor) == ["vendor.example-omid"])
        #expect(inline.verifications.first?.parameters == "k=v")
        #expect(inline.verifications.first?.trackingEvents.count == 1)
        #expect(!issues.codes().contains("vast.element.newerVersion"))
    }

    @Test func iconsNonLinearAndUnknownElementsDoNotBreakParsing() throws {
        let xml = """
        <VAST version="3.0"><Ad id="1"><InLine>
          <AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
          <Creatives>
            <Creative>
              <Linear>
                <Duration>00:00:10</Duration>
                <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="640" height="360">https://cdn.example/a.mp4</MediaFile></MediaFiles>
                <Icons>
                  <Icon program="AdChoices" width="20" height="20" xPosition="right" yPosition="top">
                    <StaticResource creativeType="image/png">https://cdn.example/adchoices.png</StaticResource>
                    <IconClicks><IconClickThrough>https://adchoices.example</IconClickThrough></IconClicks>
                  </Icon>
                </Icons>
                <Surprise/>
              </Linear>
            </Creative>
            <Creative>
              <NonLinearAds><NonLinear width="300" height="50"><StaticResource creativeType="image/png">https://cdn.example/o.png</StaticResource></NonLinear></NonLinearAds>
            </Creative>
          </Creatives>
        </InLine></Ad></VAST>
        """
        let (document, issues) = try parsedDocument(xml)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.creatives.count == 2)
        #expect(inline.creatives[1].hasNonLinear)
        #expect(inline.creatives[1].linear == nil)
        #expect(issues.codes(.info).contains("vast.icons.notRendered"))
        #expect(issues.codes(.info).contains("vast.nonLinear.notPlayed"))
        #expect(issues.issue("vast.element.unknown")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/Surprise")
    }

    @Test func urlsAreTrimmedAndEmptyOnesDropped() throws {
        let xml = VASTFixture.inline(extraInline: "<Impression>  </Impression><Impression>\n\t https://tracker.example/x \n</Impression>")
        let (document, issues) = try parsedDocument(xml)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.impressions == ["https://tracker.example/inline/impression", "https://tracker.example/x"])
        #expect(issues.issue("vast.url.empty")?.path == "VAST/Ad[1]/InLine/Impression[2]")
    }

    @Test func malformedXMLIsError100() {
        let (document, issues) = VASTParser.parse("<VAST version=\"3.0\"><Ad>")
        #expect(document == nil)
        #expect(issues.codes(.error) == ["vast.xml.malformed"])
        #expect(issues.first?.message.contains("100") == true)
    }

    @Test func nonVASTRootIsRejected() {
        let (document, issues) = VASTParser.parse("<html><body/></html>")
        #expect(document == nil)
        #expect(issues.codes(.error) == ["vast.root.invalid"])
    }

    @Test func noAdResponseKeepsRootErrors() throws {
        let (document, issues) = try parsedDocument(VASTSamples.noAd)
        #expect(document.ads.isEmpty)
        #expect(document.errors == ["https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]"])
        #expect(issues.codes(.info) == ["vast.noAd"])
    }

    @Test func podKeepsDocumentOrderAndSequences() throws {
        let (document, _) = try parsedDocument(VASTSamples.pod41)
        #expect(document.ads.map(\.sequence) == [1, 2])
        #expect(document.ads.map(\.id) == ["ccinn-pod-41-1", "ccinn-pod-41-2"])
    }

    @Test func eachSampleDeclaresItsVersion() throws {
        let expected = ["vast-2.0-inline": "2.0", "vast-3.0-skippable": "3.0", "vast-4.0-mezzanine": "4.0", "vast-4.1-pod": "4.1",
                        "vast-4.2-verification": "4.2", "vast-3.0-wrapper-chain": "3.0", "vast-3.0-vpaid": "3.0", "vast-4.0-audio": "4.0",
                        "vast-no-ad": "4.2"]
        #expect(Set(VASTSamples.all.map(\.id)) == Set(expected.keys))
        for sample in VASTSamples.all {
            let (document, _) = try parsedDocument(sample.xml)
            #expect(document.version == expected[sample.id], "\(sample.id)")
        }
    }

    @Test func wrapperChainSampleIsOfflineDataURLs() throws {
        let (outer, _) = try parsedDocument(VASTSamples.wrapperChain30)
        guard case let .wrapper(first) = outer.ads.first?.body else {
            Issue.record("expected a wrapper")
            return
        }
        #expect(first.adTagURI.hasPrefix("data:application/xml;base64,"))
        let middleXML = try #require(FakeVASTFetcher.decodeDataURL(first.adTagURI))
        let (middle, _) = try parsedDocument(middleXML)
        guard case let .wrapper(second) = middle.ads.first?.body else {
            Issue.record("expected a second wrapper")
            return
        }
        #expect(FakeVASTFetcher.decodeDataURL(second.adTagURI) == VASTSamples.wrapperChainInline30)
    }

    @Test func pod41AdsAreCompleteVAST41InLines() throws {
        let (document, issues) = try parsedDocument(VASTSamples.pod41)
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty, "\(issues)")
        for ad in document.ads {
            guard case let .inline(inline) = ad.body else {
                Issue.record("expected inline ads")
                continue
            }
            #expect(inline.playedLinear?.trackingEvents.contains { $0.event == .progress(.seconds(5)) } == true)
        }
    }

    @Test func audioSampleIsAudioOnly() throws {
        let (document, issues) = try parsedDocument(VASTSamples.audio40)
        #expect(issues.codes(.error).isEmpty && issues.codes(.warning).isEmpty)
        guard case let .inline(inline) = document.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.playedLinear?.mediaFiles.map(\.type) == ["audio/mp4"])
        #expect(inline.playedLinear?.mediaFiles.first?.url == VASTSamples.audioURL)
    }
}
