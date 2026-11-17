import Foundation

/// TEMPORARY stand-in for kit-vast's `VASTSamples.swift` (decisions.md, "Agreements between agents"): the same constant
/// names, each a minimal valid VAST document, so `SampleLibrary` builds before kit-vast merges. When kit-vast's file
/// lands, delete this file.
public enum VASTSamples {
    /// VAST 2.0 inline linear ad.
    public static let inline20 = inline(version: "2.0", id: "placeholder-20", title: "VAST 2.0 inline (placeholder)")
    /// VAST 3.0 inline linear ad, skippable after 5 s.
    public static let inline30Skippable = inline(version: "3.0", id: "placeholder-30", title: "VAST 3.0 skippable (placeholder)",
                                                 skipOffset: "00:00:05")
    /// VAST 4.0 inline linear ad.
    public static let inline40 = inline(version: "4.0", id: "placeholder-40", title: "VAST 4.0 inline (placeholder)")
    /// VAST 4.1 pod of two ads.
    public static let pod41 = document(version: "4.1", ads: ad(id: "placeholder-41-1", title: "Pod ad 1 (placeholder)", sequence: 1)
        + ad(id: "placeholder-41-2", title: "Pod ad 2 (placeholder)", sequence: 2))
    /// VAST 4.2 inline linear ad.
    public static let inline42Verification = inline(version: "4.2", id: "placeholder-42", title: "VAST 4.2 inline (placeholder)")
    /// VAST 3.0 wrapper whose `VASTAdTagURI` is a `data:` URL holding an inline ad.
    public static let wrapperChain30 = document(version: "3.0", ads: """
      <Ad id="placeholder-wrapper">
        <Wrapper>
          <AdSystem>CcinnOpenRTB</AdSystem>
          <VASTAdTagURI><![CDATA[data:application/xml;base64,\(Data(inline(version: "3.0", id: "placeholder-chain", title: "Chain end (placeholder)").utf8).base64EncodedString())]]></VASTAdTagURI>
          <Impression><![CDATA[https://tracker.example/placeholder/wrapper/impression]]></Impression>
        </Wrapper>
      </Ad>
    """)
    /// VAST 3.0 inline ad whose only media file is VPAID.
    public static let vpaidOnly = inline(version: "3.0", id: "placeholder-vpaid", title: "VPAID only (placeholder)",
                                         mediaFile: #"<MediaFile delivery="progressive" type="application/javascript" width="640" height="360" apiFramework="VPAID"><![CDATA[https://tracker.example/placeholder/vpaid.js]]></MediaFile>"#)
    /// VAST 4.0 audio ad.
    public static let audio40 = inline(version: "4.0", id: "placeholder-audio", title: "VAST 4.0 audio (placeholder)",
                                       mediaFile: #"<MediaFile delivery="progressive" type="audio/mp4"><![CDATA[ccinn-sample://media/sample-15s.m4a]]></MediaFile>"#)
    /// A no-ad response.
    public static let noAd = document(version: "4.2", ads: "  <Error><![CDATA[https://tracker.example/placeholder/no-ad?code=[ERRORCODE]]]></Error>")

    private static let videoFile =
        #"<MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>"#

    private static func inline(version: String, id: String, title: String, skipOffset: String? = nil, mediaFile: String = videoFile) -> String {
        document(version: version, ads: ad(id: id, title: title, skipOffset: skipOffset, mediaFile: mediaFile))
    }

    private static func document(version: String, ads: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<VAST version=\"\(version)\">\n\(ads)\n</VAST>"
    }

    private static func ad(id: String, title: String, sequence: Int? = nil, skipOffset: String? = nil, mediaFile: String = videoFile) -> String {
        let sequenceAttribute = sequence.map { " sequence=\"\($0)\"" } ?? ""
        let skipAttribute = skipOffset.map { " skipoffset=\"\($0)\"" } ?? ""
        return """
          <Ad id="\(id)"\(sequenceAttribute)>
            <InLine>
              <AdSystem>CcinnOpenRTB</AdSystem>
              <AdTitle>\(title)</AdTitle>
              <Impression><![CDATA[https://tracker.example/placeholder/\(id)/impression]]></Impression>
              <Creatives>
                <Creative>
                  <Linear\(skipAttribute)>
                    <Duration>00:00:15</Duration>
                    <TrackingEvents>
                      <Tracking event="start"><![CDATA[https://tracker.example/placeholder/\(id)/start]]></Tracking>
                      <Tracking event="complete"><![CDATA[https://tracker.example/placeholder/\(id)/complete]]></Tracking>
                    </TrackingEvents>
                    <VideoClicks>
                      <ClickThrough><![CDATA[https://advertiser.example/landing?src=\(id)]]></ClickThrough>
                    </VideoClicks>
                    <MediaFiles>
                      \(mediaFile)
                    </MediaFiles>
                  </Linear>
                </Creative>
              </Creatives>
            </InLine>
          </Ad>
        """
    }
}
