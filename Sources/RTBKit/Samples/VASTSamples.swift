import Foundation

/// Built-in VAST documents (design D11), shaped after the IAB Tech Lab sample tags. Owner: kit-vast.
///
/// Everything works offline: media and images are `ccinn-sample://` URLs the app generates locally, wrapper chains use
/// `data:` URLs, and every tracker points at `https://tracker.example/…` (landing pages at `https://advertiser.example/…`).
/// Each sample uses only elements, attributes and macros of its declared version.
public enum VASTSamples {
    /// The sample video: 15 s, 1280×720, H.264 + AAC.
    public static let videoURL = "ccinn-sample://media/sample-15s.mp4"
    /// The sample audio: 15 s AAC.
    public static let audioURL = "ccinn-sample://media/sample-15s.m4a"
    /// The 300×250 companion image.
    public static let companionImageURL = "ccinn-sample://image/companion.png"

    // MARK: - VAST 2.0

    /// VAST 2.0 inline linear ad: two Impressions, the 2.0 tracking events, a click-through and one MP4. VAST 2.0 has no
    /// error codes and no standard macros, so its URLs carry none.
    public static let inline20 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="2.0">
      <Ad id="ccinn-inline-20">
        <InLine>
          <AdSystem version="2.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 2.0 Inline Linear</AdTitle>
          <Description>A 15-second linear video ad.</Description>
          <Error><![CDATA[https://tracker.example/vast20/error]]></Error>
          <Impression id="primary"><![CDATA[https://tracker.example/vast20/impression]]></Impression>
          <Impression id="third-party"><![CDATA[https://tracker.example/vast20/impression-3p]]></Impression>
          <Creatives>
            <Creative id="ccinn-creative-20" sequence="1" AdID="ccinn-20">
              <Linear>
                <Duration>00:00:15</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/vast20/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/vast20/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/vast20/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/vast20/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/vast20/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/vast20/complete]]></Tracking>
                  <Tracking event="mute"><![CDATA[https://tracker.example/vast20/mute]]></Tracking>
                  <Tracking event="unmute"><![CDATA[https://tracker.example/vast20/unmute]]></Tracking>
                  <Tracking event="pause"><![CDATA[https://tracker.example/vast20/pause]]></Tracking>
                  <Tracking event="resume"><![CDATA[https://tracker.example/vast20/resume]]></Tracking>
                  <Tracking event="rewind"><![CDATA[https://tracker.example/vast20/rewind]]></Tracking>
                  <Tracking event="fullscreen"><![CDATA[https://tracker.example/vast20/fullscreen]]></Tracking>
                  <Tracking event="close"><![CDATA[https://tracker.example/vast20/close]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough><![CDATA[https://advertiser.example/landing?src=vast20]]></ClickThrough>
                  <ClickTracking><![CDATA[https://tracker.example/vast20/click]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000" scalable="true" maintainAspectRatio="true"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    // MARK: - VAST 3.0

    /// VAST 3.0 skippable linear ad (`skipoffset` 00:00:05) with `progress` at 00:00:10 and 25%, and a 300×250 static
    /// companion.
    public static let inline30Skippable = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="3.0">
      <Ad id="ccinn-inline-30">
        <InLine>
          <AdSystem version="3.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 3.0 Skippable Linear</AdTitle>
          <Description>A 15-second linear video ad, skippable after 5 seconds, with a companion banner.</Description>
          <Advertiser>Ccinn Sample Advertiser</Advertiser>
          <Error><![CDATA[https://tracker.example/vast30/error?code=[ERRORCODE]&cb=[CACHEBUSTING]]]></Error>
          <Impression id="primary"><![CDATA[https://tracker.example/vast30/impression?cb=[CACHEBUSTING]]]></Impression>
          <Creatives>
            <Creative id="ccinn-creative-30" sequence="1" AdID="ccinn-30">
              <Linear skipoffset="00:00:05">
                <Duration>00:00:15</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/vast30/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/vast30/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/vast30/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/vast30/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/vast30/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/vast30/complete]]></Tracking>
                  <Tracking event="progress" offset="00:00:10"><![CDATA[https://tracker.example/vast30/progress-10s]]></Tracking>
                  <Tracking event="progress" offset="25%"><![CDATA[https://tracker.example/vast30/progress-25pct]]></Tracking>
                  <Tracking event="skip"><![CDATA[https://tracker.example/vast30/skip]]></Tracking>
                  <Tracking event="mute"><![CDATA[https://tracker.example/vast30/mute]]></Tracking>
                  <Tracking event="unmute"><![CDATA[https://tracker.example/vast30/unmute]]></Tracking>
                  <Tracking event="pause"><![CDATA[https://tracker.example/vast30/pause]]></Tracking>
                  <Tracking event="resume"><![CDATA[https://tracker.example/vast30/resume]]></Tracking>
                  <Tracking event="fullscreen"><![CDATA[https://tracker.example/vast30/fullscreen]]></Tracking>
                  <Tracking event="exitFullscreen"><![CDATA[https://tracker.example/vast30/exitFullscreen]]></Tracking>
                  <Tracking event="closeLinear"><![CDATA[https://tracker.example/vast30/closeLinear]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough id="landing"><![CDATA[https://advertiser.example/landing?src=vast30]]></ClickThrough>
                  <ClickTracking id="click"><![CDATA[https://tracker.example/vast30/click?cb=[CACHEBUSTING]]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile id="mp4-720p" delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000" minBitrate="1500" maxBitrate="2500" codec="avc1.4D401F" scalable="true" maintainAspectRatio="true"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
            <Creative id="ccinn-companion-30" sequence="1">
              <CompanionAds>
                <Companion id="ccinn-companion-300x250" width="300" height="250">
                  <StaticResource creativeType="image/png"><![CDATA[ccinn-sample://image/companion.png]]></StaticResource>
                  <TrackingEvents>
                    <Tracking event="creativeView"><![CDATA[https://tracker.example/vast30/companion/creativeView]]></Tracking>
                  </TrackingEvents>
                  <CompanionClickThrough><![CDATA[https://advertiser.example/landing?src=vast30-companion]]></CompanionClickThrough>
                  <CompanionClickTracking><![CDATA[https://tracker.example/vast30/companion/click]]></CompanionClickTracking>
                </Companion>
              </CompanionAds>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    // MARK: - VAST 4.0

    /// VAST 4.0 inline linear ad with a `Mezzanine` file, `UniversalAdId` and `ViewableImpression`.
    public static let inline40 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.0" xmlns="http://www.iab.com/VAST">
      <Ad id="ccinn-inline-40">
        <InLine>
          <AdSystem version="4.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 4.0 Inline Linear with Mezzanine</AdTitle>
          <Description>A 15-second linear video ad with a mezzanine file for server-side transcoding.</Description>
          <Advertiser>Ccinn Sample Advertiser</Advertiser>
          <Error><![CDATA[https://tracker.example/vast40/error?code=[ERRORCODE]&cb=[CACHEBUSTING]]]></Error>
          <Impression id="primary"><![CDATA[https://tracker.example/vast40/impression?cb=[CACHEBUSTING]&ts=[TIMESTAMP]]]></Impression>
          <ViewableImpression id="ccinn-viewable-40">
            <Viewable><![CDATA[https://tracker.example/vast40/viewable]]></Viewable>
            <NotViewable><![CDATA[https://tracker.example/vast40/not-viewable]]></NotViewable>
            <ViewUndetermined><![CDATA[https://tracker.example/vast40/view-undetermined]]></ViewUndetermined>
          </ViewableImpression>
          <Creatives>
            <Creative id="ccinn-creative-40" sequence="1" adId="ccinn-40">
              <UniversalAdId idRegistry="Ad-ID" idValue="CCIN0040000H">CCIN0040000H</UniversalAdId>
              <Linear>
                <Duration>00:00:15.000</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/vast40/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/vast40/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/vast40/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/vast40/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/vast40/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/vast40/complete]]></Tracking>
                  <Tracking event="mute"><![CDATA[https://tracker.example/vast40/mute]]></Tracking>
                  <Tracking event="unmute"><![CDATA[https://tracker.example/vast40/unmute]]></Tracking>
                  <Tracking event="pause"><![CDATA[https://tracker.example/vast40/pause]]></Tracking>
                  <Tracking event="resume"><![CDATA[https://tracker.example/vast40/resume]]></Tracking>
                  <Tracking event="rewind"><![CDATA[https://tracker.example/vast40/rewind]]></Tracking>
                  <Tracking event="playerExpand"><![CDATA[https://tracker.example/vast40/playerExpand]]></Tracking>
                  <Tracking event="playerCollapse"><![CDATA[https://tracker.example/vast40/playerCollapse]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough id="landing"><![CDATA[https://advertiser.example/landing?src=vast40]]></ClickThrough>
                  <ClickTracking id="click"><![CDATA[https://tracker.example/vast40/click]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile id="mp4-720p" delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000" minBitrate="1500" maxBitrate="2500" codec="H.264" scalable="true" maintainAspectRatio="true"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                  <Mezzanine delivery="progressive" type="video/mp4" width="1280" height="720" codec="H.264"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></Mezzanine>
                </MediaFiles>
              </Linear>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    /// VAST 4.0 audio ad: an AAC file (`width`/`height` 0, as for audio) and a 300×250 artwork companion.
    public static let audio40 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.0" xmlns="http://www.iab.com/VAST">
      <Ad id="ccinn-audio-40">
        <InLine>
          <AdSystem version="4.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 4.0 Audio Ad</AdTitle>
          <Description>A 15-second audio ad with companion artwork.</Description>
          <Error><![CDATA[https://tracker.example/audio40/error?code=[ERRORCODE]]]></Error>
          <Impression id="primary"><![CDATA[https://tracker.example/audio40/impression?cb=[CACHEBUSTING]]]></Impression>
          <Creatives>
            <Creative id="ccinn-audio-creative-40" sequence="1" adId="ccinn-audio-40">
              <UniversalAdId idRegistry="Ad-ID" idValue="CCIN0040A01H">CCIN0040A01H</UniversalAdId>
              <Linear>
                <Duration>00:00:15</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/audio40/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/audio40/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/audio40/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/audio40/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/audio40/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/audio40/complete]]></Tracking>
                  <Tracking event="mute"><![CDATA[https://tracker.example/audio40/mute]]></Tracking>
                  <Tracking event="unmute"><![CDATA[https://tracker.example/audio40/unmute]]></Tracking>
                  <Tracking event="pause"><![CDATA[https://tracker.example/audio40/pause]]></Tracking>
                  <Tracking event="resume"><![CDATA[https://tracker.example/audio40/resume]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough id="landing"><![CDATA[https://advertiser.example/landing?src=audio40]]></ClickThrough>
                  <ClickTracking id="click"><![CDATA[https://tracker.example/audio40/click]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile id="aac-128k" delivery="progressive" type="audio/mp4" width="0" height="0" bitrate="128" codec="mp4a.40.2"><![CDATA[ccinn-sample://media/sample-15s.m4a]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
            <Creative id="ccinn-audio-artwork-40" sequence="1">
              <UniversalAdId idRegistry="unknown" idValue="unknown">unknown</UniversalAdId>
              <CompanionAds>
                <Companion id="ccinn-audio-artwork" width="300" height="250">
                  <StaticResource creativeType="image/png"><![CDATA[ccinn-sample://image/companion.png]]></StaticResource>
                  <TrackingEvents>
                    <Tracking event="creativeView"><![CDATA[https://tracker.example/audio40/artwork/creativeView]]></Tracking>
                  </TrackingEvents>
                  <CompanionClickThrough><![CDATA[https://advertiser.example/landing?src=audio40-artwork]]></CompanionClickThrough>
                  <CompanionClickTracking><![CDATA[https://tracker.example/audio40/artwork/click]]></CompanionClickTracking>
                </Companion>
              </CompanionAds>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    // MARK: - VAST 4.1

    /// VAST 4.1 ad pod for CTV: two 15-second ads, `sequence` 1 and 2.
    public static let pod41 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.1" xmlns="http://www.iab.com/VAST">
    \(podAd41(position: 1))
    \(podAd41(position: 2))
    </VAST>
    """

    // MARK: - VAST 4.2

    /// VAST 4.2 inline linear ad with `AdVerifications` (OMID JavaScript resource and a `verificationNotExecuted` tracker),
    /// `ViewableImpression`, and two companions: a static image and an HTML resource.
    public static let inline42Verification = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.2" xmlns="http://www.iab.com/VAST">
      <Ad id="ccinn-inline-42" adType="video">
        <InLine>
          <AdSystem version="4.2">CcinnOpenRTB Sample Ad Server</AdSystem>
          <Error><![CDATA[https://tracker.example/vast42/error?code=[ERRORCODE]&cb=[CACHEBUSTING]]]></Error>
          <Impression id="primary"><![CDATA[https://tracker.example/vast42/impression?cb=[CACHEBUSTING]&ts=[TIMESTAMP]]]></Impression>
          <AdServingId>ccinn-42-serving-0001</AdServingId>
          <AdTitle>VAST 4.2 Inline with AdVerifications and Companions</AdTitle>
          <Advertiser>Ccinn Sample Advertiser</Advertiser>
          <AdVerifications>
            <Verification vendor="tracker.example-omid">
              <JavaScriptResource apiFramework="omid" browserOptional="true"><![CDATA[https://tracker.example/omid/verification-client.js]]></JavaScriptResource>
              <TrackingEvents>
                <Tracking event="verificationNotExecuted"><![CDATA[https://tracker.example/vast42/verification/not-executed?reason=[REASON]]]></Tracking>
              </TrackingEvents>
              <VerificationParameters><![CDATA[{"partner":"ccinn","campaign":"sample-42"}]]></VerificationParameters>
            </Verification>
          </AdVerifications>
          <ViewableImpression id="ccinn-viewable-42">
            <Viewable><![CDATA[https://tracker.example/vast42/viewable]]></Viewable>
            <NotViewable><![CDATA[https://tracker.example/vast42/not-viewable]]></NotViewable>
            <ViewUndetermined><![CDATA[https://tracker.example/vast42/view-undetermined]]></ViewUndetermined>
          </ViewableImpression>
          <Creatives>
            <Creative id="ccinn-creative-42" sequence="1" adId="ccinn-42">
              <UniversalAdId idRegistry="Ad-ID">CCIN0042000H</UniversalAdId>
              <Linear>
                <Duration>00:00:15</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/vast42/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/vast42/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/vast42/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/vast42/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/vast42/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/vast42/complete]]></Tracking>
                  <Tracking event="progress" offset="50%"><![CDATA[https://tracker.example/vast42/progress-50pct?playhead=[ADPLAYHEAD]]]></Tracking>
                  <Tracking event="mute"><![CDATA[https://tracker.example/vast42/mute]]></Tracking>
                  <Tracking event="unmute"><![CDATA[https://tracker.example/vast42/unmute]]></Tracking>
                  <Tracking event="pause"><![CDATA[https://tracker.example/vast42/pause]]></Tracking>
                  <Tracking event="resume"><![CDATA[https://tracker.example/vast42/resume]]></Tracking>
                  <Tracking event="playerExpand"><![CDATA[https://tracker.example/vast42/playerExpand]]></Tracking>
                  <Tracking event="playerCollapse"><![CDATA[https://tracker.example/vast42/playerCollapse]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough id="landing"><![CDATA[https://advertiser.example/landing?src=vast42]]></ClickThrough>
                  <ClickTracking id="click"><![CDATA[https://tracker.example/vast42/click]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile id="mp4-720p" delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000" minBitrate="1500" maxBitrate="2500" codec="avc1.4D401F" scalable="true" maintainAspectRatio="true"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
            <Creative id="ccinn-companions-42" sequence="1">
              <UniversalAdId idRegistry="unknown">unknown</UniversalAdId>
              <CompanionAds>
                <Companion id="ccinn-companion-static" width="300" height="250">
                  <StaticResource creativeType="image/png"><![CDATA[ccinn-sample://image/companion.png]]></StaticResource>
                  <AltText>Ccinn sample companion</AltText>
                  <TrackingEvents>
                    <Tracking event="creativeView"><![CDATA[https://tracker.example/vast42/companion/static/creativeView]]></Tracking>
                  </TrackingEvents>
                  <CompanionClickThrough><![CDATA[https://advertiser.example/landing?src=vast42-companion-static]]></CompanionClickThrough>
                  <CompanionClickTracking id="static-click"><![CDATA[https://tracker.example/vast42/companion/static/click]]></CompanionClickTracking>
                </Companion>
                <Companion id="ccinn-companion-html" width="320" height="50">
                  <HTMLResource><![CDATA[<!DOCTYPE html><html><head><meta name="viewport" content="width=320"><style>html,body{margin:0;height:100%}body{display:flex;align-items:center;justify-content:center;background:#1f6feb;color:#fff;font:600 14px -apple-system,sans-serif}</style></head><body>Ccinn sample HTML companion</body></html>]]></HTMLResource>
                  <TrackingEvents>
                    <Tracking event="creativeView"><![CDATA[https://tracker.example/vast42/companion/html/creativeView]]></Tracking>
                  </TrackingEvents>
                  <CompanionClickThrough><![CDATA[https://advertiser.example/landing?src=vast42-companion-html]]></CompanionClickThrough>
                  <CompanionClickTracking id="html-click"><![CDATA[https://tracker.example/vast42/companion/html/click]]></CompanionClickTracking>
                </Companion>
              </CompanionAds>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    // MARK: - Wrapper chain (VAST 3.0)

    /// VAST 3.0 wrapper → wrapper → inline ad. Each `VASTAdTagURI` is a `data:application/xml;base64,…` URL, so the chain
    /// resolves offline. Both wrappers add an Impression, an Error URL, linear tracking and a ClickTracking.
    public static let wrapperChain30 = wrapper30(level: 1, adTagURI: dataURL(wrapper30(level: 2, adTagURI: dataURL(wrapperChainInline30))))

    /// The inline ad at the end of `wrapperChain30`.
    public static let wrapperChainInline30 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="3.0">
      <Ad id="ccinn-chain-inline">
        <InLine>
          <AdSystem version="3.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 3.0 Inline (end of the wrapper chain)</AdTitle>
          <Error><![CDATA[https://tracker.example/chain/inline/error?code=[ERRORCODE]]]></Error>
          <Impression id="inline"><![CDATA[https://tracker.example/chain/inline/impression?cb=[CACHEBUSTING]]]></Impression>
          <Creatives>
            <Creative id="ccinn-chain-creative" sequence="1" AdID="ccinn-chain">
              <Linear>
                <Duration>00:00:15</Duration>
                <TrackingEvents>
                  <Tracking event="creativeView"><![CDATA[https://tracker.example/chain/inline/creativeView]]></Tracking>
                  <Tracking event="start"><![CDATA[https://tracker.example/chain/inline/start]]></Tracking>
                  <Tracking event="firstQuartile"><![CDATA[https://tracker.example/chain/inline/firstQuartile]]></Tracking>
                  <Tracking event="midpoint"><![CDATA[https://tracker.example/chain/inline/midpoint]]></Tracking>
                  <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/chain/inline/thirdQuartile]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/chain/inline/complete]]></Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough><![CDATA[https://advertiser.example/landing?src=chain]]></ClickThrough>
                  <ClickTracking><![CDATA[https://tracker.example/chain/inline/click]]></ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    // MARK: - Failures

    /// VAST 3.0 inline ad whose only media file is VPAID JavaScript: the simulator does not run VPAID, so no media file is
    /// supported (error 403; 901 is a VPAID runtime error).
    public static let vpaidOnly = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="3.0">
      <Ad id="ccinn-vpaid-only">
        <InLine>
          <AdSystem version="3.0">CcinnOpenRTB Sample Ad Server</AdSystem>
          <AdTitle>VAST 3.0 VPAID-only (unsupported)</AdTitle>
          <Error><![CDATA[https://tracker.example/vpaid/error?code=[ERRORCODE]&cb=[CACHEBUSTING]]]></Error>
          <Impression><![CDATA[https://tracker.example/vpaid/impression]]></Impression>
          <Creatives>
            <Creative id="ccinn-vpaid-creative" sequence="1" AdID="ccinn-vpaid">
              <Linear>
                <Duration>00:00:15</Duration>
                <AdParameters><![CDATA[{"clickThrough":"https://advertiser.example/landing?src=vpaid"}]]></AdParameters>
                <TrackingEvents>
                  <Tracking event="start"><![CDATA[https://tracker.example/vpaid/start]]></Tracking>
                  <Tracking event="complete"><![CDATA[https://tracker.example/vpaid/complete]]></Tracking>
                </TrackingEvents>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="application/javascript" width="1280" height="720" apiFramework="VPAID"><![CDATA[https://tracker.example/vpaid/vpaid-unit.js]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    /// A no-ad response: only a root `<Error>` (VAST 3.0+), fired with error 303.
    public static let noAd = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.2" xmlns="http://www.iab.com/VAST">
      <Error><![CDATA[https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]]]></Error>
    </VAST>
    """

    /// Every sample with a short title, for menus and tests.
    public static let all: [(id: String, title: String, xml: String)] = [
        ("vast-2.0-inline", "VAST 2.0 inline", inline20),
        ("vast-3.0-skippable", "VAST 3.0 skippable, progress, companion", inline30Skippable),
        ("vast-4.0-mezzanine", "VAST 4.0 inline, Mezzanine", inline40),
        ("vast-4.1-pod", "VAST 4.1 pod (2 ads)", pod41),
        ("vast-4.2-verification", "VAST 4.2 verification, companions", inline42Verification),
        ("vast-3.0-wrapper-chain", "VAST 3.0 wrapper chain (data: URLs)", wrapperChain30),
        ("vast-3.0-vpaid", "VAST 3.0 VPAID only", vpaidOnly),
        ("vast-4.0-audio", "VAST 4.0 audio", audio40),
        ("vast-no-ad", "VAST no-ad response", noAd),
    ]

    // MARK: - Builders

    private static func podAd41(position: Int) -> String {
        """
          <Ad id="ccinn-pod-41-\(position)" sequence="\(position)" adType="video">
            <InLine>
              <AdSystem version="4.1">CcinnOpenRTB Sample Ad Server</AdSystem>
              <Error><![CDATA[https://tracker.example/vast41/pod/\(position)/error?code=[ERRORCODE]]]></Error>
              <Impression id="pod-\(position)"><![CDATA[https://tracker.example/vast41/pod/\(position)/impression?cb=[CACHEBUSTING]&pod=[PODSEQUENCE]]]></Impression>
              <AdServingId>ccinn-pod-41-serving-\(position)</AdServingId>
              <AdTitle>VAST 4.1 Pod Ad \(position) of 2</AdTitle>
              <Creatives>
                <Creative id="ccinn-pod-41-creative-\(position)" sequence="1" adId="ccinn-pod-\(position)">
                  <UniversalAdId idRegistry="Ad-ID">CCIN004100\(position)H</UniversalAdId>
                  <Linear>
                    <Duration>00:00:15</Duration>
                    <TrackingEvents>
                      <Tracking event="creativeView"><![CDATA[https://tracker.example/vast41/pod/\(position)/creativeView]]></Tracking>
                      <Tracking event="start"><![CDATA[https://tracker.example/vast41/pod/\(position)/start]]></Tracking>
                      <Tracking event="firstQuartile"><![CDATA[https://tracker.example/vast41/pod/\(position)/firstQuartile]]></Tracking>
                      <Tracking event="midpoint"><![CDATA[https://tracker.example/vast41/pod/\(position)/midpoint]]></Tracking>
                      <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/vast41/pod/\(position)/thirdQuartile]]></Tracking>
                      <Tracking event="complete"><![CDATA[https://tracker.example/vast41/pod/\(position)/complete]]></Tracking>
                      <Tracking event="progress" offset="00:00:05"><![CDATA[https://tracker.example/vast41/pod/\(position)/progress-5s?playhead=[ADPLAYHEAD]]]></Tracking>
                      <Tracking event="mute"><![CDATA[https://tracker.example/vast41/pod/\(position)/mute]]></Tracking>
                      <Tracking event="unmute"><![CDATA[https://tracker.example/vast41/pod/\(position)/unmute]]></Tracking>
                      <Tracking event="pause"><![CDATA[https://tracker.example/vast41/pod/\(position)/pause]]></Tracking>
                      <Tracking event="resume"><![CDATA[https://tracker.example/vast41/pod/\(position)/resume]]></Tracking>
                    </TrackingEvents>
                    <VideoClicks>
                      <ClickThrough id="landing"><![CDATA[https://advertiser.example/landing?src=pod41-\(position)]]></ClickThrough>
                      <ClickTracking id="click"><![CDATA[https://tracker.example/vast41/pod/\(position)/click]]></ClickTracking>
                    </VideoClicks>
                    <MediaFiles>
                      <MediaFile id="mp4-720p" delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000" codec="avc1.4D401F" scalable="true" maintainAspectRatio="true"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
                    </MediaFiles>
                  </Linear>
                </Creative>
              </Creatives>
            </InLine>
          </Ad>
        """
    }

    private static func wrapper30(level: Int, adTagURI: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VAST version="3.0">
          <Ad id="ccinn-chain-wrapper-\(level)">
            <Wrapper followAdditionalWrappers="true" allowMultipleAds="false" fallbackOnNoAd="false">
              <AdSystem version="3.0">CcinnOpenRTB Sample Wrapper \(level)</AdSystem>
              <VASTAdTagURI><![CDATA[\(adTagURI)]]></VASTAdTagURI>
              <Error><![CDATA[https://tracker.example/chain/wrapper\(level)/error?code=[ERRORCODE]]]></Error>
              <Impression id="wrapper-\(level)"><![CDATA[https://tracker.example/chain/wrapper\(level)/impression?cb=[CACHEBUSTING]]]></Impression>
              <Creatives>
                <Creative id="ccinn-chain-wrapper-\(level)-tracking">
                  <Linear>
                    <TrackingEvents>
                      <Tracking event="creativeView"><![CDATA[https://tracker.example/chain/wrapper\(level)/creativeView]]></Tracking>
                      <Tracking event="start"><![CDATA[https://tracker.example/chain/wrapper\(level)/start]]></Tracking>
                      <Tracking event="firstQuartile"><![CDATA[https://tracker.example/chain/wrapper\(level)/firstQuartile]]></Tracking>
                      <Tracking event="midpoint"><![CDATA[https://tracker.example/chain/wrapper\(level)/midpoint]]></Tracking>
                      <Tracking event="thirdQuartile"><![CDATA[https://tracker.example/chain/wrapper\(level)/thirdQuartile]]></Tracking>
                      <Tracking event="complete"><![CDATA[https://tracker.example/chain/wrapper\(level)/complete]]></Tracking>
                    </TrackingEvents>
                    <VideoClicks>
                      <ClickTracking><![CDATA[https://tracker.example/chain/wrapper\(level)/click]]></ClickTracking>
                    </VideoClicks>
                  </Linear>
                </Creative>
              </Creatives>
            </Wrapper>
          </Ad>
        </VAST>
        """
    }

    private static func dataURL(_ xml: String) -> String {
        "data:application/xml;base64," + Data(xml.utf8).base64EncodedString()
    }
}
