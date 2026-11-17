import Foundation
import Testing
@testable import RTBKit

@Suite("VAST validation")
struct VASTValidationTests {
    private func issues(_ xml: String, requireSecure: Bool = false) -> [ValidationIssue] {
        VASTParser.parse(xml, requireSecure: requireSecure).issues
    }

    // MARK: Version

    @Test func versionChecks() {
        #expect(issues("<VAST><Error>https://tracker.example/e</Error></VAST>").issue("vast.version.missing")?.severity == .warning)
        #expect(issues(#"<VAST version="banana"/>"#).issue("vast.version.invalid")?.path == "VAST@version")
        #expect(issues(#"<VAST version="5.0"/>"#).issue("vast.version.unsupported")?.message.contains("102") == true)
        #expect(!issues(#"<VAST version="4.1.0"/>"#).codes().contains { $0.hasPrefix("vast.version") })
    }

    @Test(arguments: VASTSpecVersion.allCases)
    func everyVersionIsInterpreted(_ version: VASTSpecVersion) {
        #expect(VASTSpecVersion.interpret(version.rawValue) == .supported(version))
    }

    @Test func versionInterpretation() {
        #expect(VASTSpecVersion.interpret("3") == .supported(.v3_0))
        #expect(VASTSpecVersion.interpret("1.0") == .unsupported(closest: .v2_0))
        #expect(VASTSpecVersion.interpret("4.3") == .unsupported(closest: .v4_2))
        #expect(VASTSpecVersion.interpret("4.x") == .invalid)
        #expect(VASTSpecVersion.interpret("") == .invalid)
        #expect(VASTSpecVersion.v2_0 < .v4_2)
    }

    // MARK: Required elements

    /// Spec scenario "Missing VAST Impression": the inspector names `InLine/Impression`.
    @Test func missingImpressionNamesTheElement() throws {
        let xml = """
        <VAST version="3.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle>
        <Creatives><Creative><Linear><Duration>00:00:10</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let issue = try #require(issues(xml).issue("vast.inline.impression.missing"))
        #expect(issue.severity == .error)
        #expect(issue.path == "VAST/Ad[1]/InLine/Impression")
    }

    @Test func inlineRequiredElements() {
        let found = issues(#"<VAST version="3.0"><Ad><InLine></InLine></Ad></VAST>"#)
        for code in ["vast.inline.adSystem.missing", "vast.inline.adTitle.missing", "vast.inline.impression.missing", "vast.inline.creatives.missing"] {
            #expect(found.issue(code)?.severity == .error, "\(code)")
        }
        #expect(issues(#"<VAST version="3.0"><Ad/></VAST>"#).issue("vast.ad.body.missing")?.severity == .error)
    }

    @Test func linearRequiresDurationAndMediaFiles() {
        let xml = """
        <VAST version="3.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
        <Creatives><Creative><Linear></Linear></Creative><Creative><Linear><Duration>15 seconds</Duration><MediaFiles/></Linear></Creative></Creatives>
        </InLine></Ad></VAST>
        """
        let found = issues(xml)
        #expect(found.issue("vast.linear.duration.missing")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/Duration")
        #expect(found.issue("vast.linear.duration.invalid")?.severity == .error)
        #expect(found.filter { $0.code == "vast.linear.mediaFiles.missing" }.count == 2)
    }

    @Test func mediaFileRequiredAttributesAreErrorsFrom30AndWarningsIn20() {
        func mediaFileIssues(_ version: String) -> [ValidationIssue] {
            issues("""
            <VAST version="\(version)"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
            <Creatives><Creative><Linear><Duration>00:00:10</Duration>
            <MediaFiles><MediaFile>https://cdn.example/a.mp4</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
            """).filter { $0.code.hasPrefix("vast.mediaFile.") }
        }
        let modern = mediaFileIssues("3.0")
        #expect(Set(modern.map(\.code)) == ["vast.mediaFile.delivery.missing", "vast.mediaFile.type.missing", "vast.mediaFile.width.missing",
                                            "vast.mediaFile.height.missing"])
        #expect(modern.allSatisfy { $0.severity == .error })
        let legacy = mediaFileIssues("2.0")
        #expect(legacy.count == 4)
        #expect(legacy.allSatisfy { $0.severity == .warning })
        #expect(modern.issue("vast.mediaFile.type.missing")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/MediaFiles/MediaFile[1]@type")
    }

    @Test func audioMediaFileWithoutSizeIsOnlyANote() {
        let xml = """
        <VAST version="4.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
        <Creatives><Creative><UniversalAdId idRegistry="unknown" idValue="unknown">unknown</UniversalAdId><Linear><Duration>00:00:10</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="audio/mpeg">https://cdn.example/a.mp3</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let found = issues(xml)
        #expect(found.issue("vast.mediaFile.width.missing")?.severity == .info)
        #expect(found.codes(.error).isEmpty && found.codes(.warning).isEmpty)
    }

    // MARK: Offsets

    @Test func offsetsAreChecked() {
        let tracking = """
        <TrackingEvents>
          <Tracking event="progress" offset="soon"><![CDATA[https://tracker.example/p1]]></Tracking>
          <Tracking event="progress"><![CDATA[https://tracker.example/p2]]></Tracking>
          <Tracking event="progress" offset="00:00:20"><![CDATA[https://tracker.example/p3]]></Tracking>
          <Tracking event="progress" offset="150%"><![CDATA[https://tracker.example/p4]]></Tracking>
        </TrackingEvents>
        """
        let xml = """
        <VAST version="3.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
        <Creatives><Creative><Linear skipoffset="later"><Duration>00:00:15</Duration>\(tracking)
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative><Creative><Linear skipoffset="00:00:30"><Duration>00:00:15</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let found = issues(xml)
        #expect(found.issue("vast.linear.skipoffset.invalid")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear@skipoffset")
        #expect(found.filter { $0.code == "vast.tracking.offset.invalid" }.count == 3)
        #expect(found.issue("vast.tracking.offset.beyondDuration")?.path
            == "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/TrackingEvents/Tracking[3]@offset")
        #expect(found.issue("vast.linear.skipoffset.beyondDuration")?.path == "VAST/Ad[1]/InLine/Creatives/Creative[2]/Linear@skipoffset")
    }

    // MARK: URLs

    @Test func nonHTTPSIsANoteUnlessSecureIsRequired() {
        let xml = VASTFixture.inline(extraInline: "<Impression>http://tracker.example/plain</Impression>")
        #expect(issues(xml).issue("vast.url.insecure")?.severity == .info)
        let secure = issues(xml, requireSecure: true).issue("vast.url.insecure")
        #expect(secure?.severity == .warning)
        #expect(secure?.path == "VAST/Ad[1]/InLine/Impression[2]")
    }

    @Test func invalidURLs() {
        let xml = VASTFixture.inline(extraInline: """
        <Impression>/relative/path</Impression><Impression>data:image/gif;base64,R0lGOD</Impression><Impression>ftp://x.example/a</Impression>
        """)
        #expect(issues(xml).filter { $0.code == "vast.url.invalid" }.count == 3)
    }

    @Test func wrapperWithoutAdTagURIIsAnError() {
        let issue = issues(VASTFixture.wrapper(name: "w", adTagURI: nil)).issue("vast.wrapper.adTagURI.missing")
        #expect(issue?.severity == .error)
        #expect(issue?.path == "VAST/Ad[1]/Wrapper/VASTAdTagURI")
    }

    // MARK: Media

    @Test func vpaidOnlyAndUnplayableMediaAreReported() throws {
        #expect(issues(VASTSamples.vpaidOnly).issue("vast.mediaFiles.vpaidOnly")?.severity == .warning)
        let webm = VASTFixture.inline().replacingOccurrences(of: "video/mp4", with: "video/webm")
            .replacingOccurrences(of: ".mp4", with: ".webm")
        #expect(issues(webm).issue("vast.mediaFiles.unplayable")?.severity == .warning)
    }

    // MARK: Version history

    @Test func elementsNewerThanTheDeclaredVersionAreNotes() {
        let xml = """
        <VAST version="2.0"><Ad id="a" sequence="1"><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
        <ViewableImpression><Viewable>https://tracker.example/v</Viewable></ViewableImpression>
        <Creatives><Creative><Linear skipoffset="00:00:05"><Duration>00:00:10</Duration>
        <TrackingEvents><Tracking event="progress" offset="00:00:02">https://tracker.example/p</Tracking><Tracking event="skip">https://tracker.example/s</Tracking></TrackingEvents>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1" codec="avc1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let notes = issues(xml).filter { $0.code == "vast.element.newerVersion" }
        #expect(notes.allSatisfy { $0.severity == .info })
        #expect(Set(notes.map(\.path)) == [
            "VAST/Ad[1]@sequence",
            "VAST/Ad[1]/InLine/ViewableImpression",
            "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear@skipoffset",
            "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/TrackingEvents/Tracking[1]@event",
            "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/TrackingEvents/Tracking[2]@event",
            "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/MediaFiles/MediaFile[1]@codec",
        ])
    }

    @Test func rootErrorIsNewerThan20() {
        #expect(issues(#"<VAST version="2.0"><Error>https://tracker.example/e</Error></VAST>"#).issue("vast.element.newerVersion")?.path
            == "VAST/Error")
    }

    @Test func vast4RequirementsAndRenamedEvents() {
        let xml = """
        <VAST version="4.1"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression>
        <Creatives><Creative><Linear><Duration>00:00:10</Duration>
        <TrackingEvents><Tracking event="fullscreen">https://tracker.example/f</Tracking><Tracking event="FirstQuartile">https://tracker.example/q</Tracking></TrackingEvents>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let found = issues(xml)
        #expect(found.issue("vast.inline.adServingId.missing")?.severity == .warning)
        #expect(found.issue("vast.creative.universalAdId.missing")?.severity == .warning)
        #expect(found.issue("vast.tracking.event.deprecated")?.message.contains("playerExpand") == true)
        #expect(found.issue("vast.tracking.event.case")?.severity == .warning)
        let (document, _) = VASTParser.parse(xml)
        guard case let .inline(inline) = document?.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(inline.playedLinear?.trackingEvents.map(\.event) == [.fullscreen, .firstQuartile])
    }

    @Test func unknownAndMiscasedElements() {
        let found = issues(VASTFixture.inline(extraInline: "<impression>https://tracker.example/x</impression><Custom/>"))
        let unknown = found.filter { $0.code == "vast.element.unknown" }
        #expect(unknown.first { $0.path.hasSuffix("/impression") }?.severity == .warning)
        #expect(unknown.first { $0.path.hasSuffix("/Custom") }?.severity == .info)
    }

    // MARK: Pods

    @Test func podStructure() {
        let duplicate = VASTFixture.document(ads: [VASTFixture.inlineAd(id: "a", sequence: 1), VASTFixture.inlineAd(id: "b", sequence: 1)])
        #expect(issues(duplicate).issue("vast.pod.sequence.duplicate")?.severity == .warning)
        let buffet = VASTFixture.document(ads: [VASTFixture.inlineAd(id: "a", sequence: 1), VASTFixture.inlineAd(id: "b")])
        #expect(issues(buffet).issue("vast.pod.buffet")?.severity == .info)
        let standAlone = VASTFixture.document(ads: [VASTFixture.inlineAd(id: "a"), VASTFixture.inlineAd(id: "b")])
        #expect(issues(standAlone).issue("vast.ads.standAlone.multiple")?.severity == .info)
    }

    // MARK: Samples

    @Test(arguments: VASTSamples.all.map(\.id))
    func samplesAreClean(_ id: String) throws {
        let sample = try #require(VASTSamples.all.first { $0.id == id })
        let found = issues(sample.xml)
        #expect(found.codes(.error).isEmpty, "\(found)")
        let expectedWarnings: [String] = id == "vast-3.0-vpaid" ? ["vast.mediaFiles.vpaidOnly"] : []
        #expect(found.codes(.warning) == expectedWarnings, "\(found)")
        #expect(!found.codes().contains("vast.element.newerVersion"), "\(found)")
        #expect(!found.codes().contains("vast.element.unknown"), "\(found)")
        #expect(!found.codes().contains("vast.url.insecure"), "\(found)")
    }

    @Test(arguments: VASTSamples.all.map(\.id))
    func samplesUseOnlyOfflineMediaAndExampleTrackers(_ id: String) throws {
        let sample = try #require(VASTSamples.all.first { $0.id == id })
        var documents = [sample.xml]
        if id == "vast-3.0-wrapper-chain" {
            documents = [VASTSamples.wrapperChain30, VASTSamples.wrapperChainInline30]
        }
        for xml in documents {
            let (document, _) = VASTParser.parse(xml)
            for ad in document?.ads ?? [] {
                for url in ad.body.impressions + ad.body.errors + ad.body.linearTrackings.map(\.url) + ad.body.linearClickTrackings {
                    #expect(url.hasPrefix("https://tracker.example/"), "\(url)")
                }
                if case let .inline(inline) = ad.body {
                    for file in inline.playedLinear?.mediaFiles ?? [] where file.apiFramework == nil {
                        #expect(file.url == VASTSamples.videoURL || file.url == VASTSamples.audioURL)
                    }
                }
            }
        }
    }
}
