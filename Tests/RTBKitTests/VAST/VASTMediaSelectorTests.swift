import Foundation
import Testing
@testable import RTBKit

@Suite("VAST media selector")
struct VASTMediaSelectorTests {
    private func mp4(_ width: Int, _ height: Int, bitrate: Int? = nil, codec: String? = nil, name: String? = nil) -> VASTMediaFile {
        VASTMediaFile(url: "https://cdn.example/\(name ?? "\(width)x\(height)").mp4", delivery: "progressive", type: "video/mp4", width: width,
                      height: height, bitrate: bitrate, codec: codec)
    }

    private func chosenURL(_ files: [VASTMediaFile], _ width: Int = 1280, _ height: Int = 720, audioOnly: Bool = false) -> String? {
        if case let .play(file) = VASTMediaSelector.choose(files, playerWidth: width, playerHeight: height, audioOnly: audioOnly) {
            return file.url
        }
        return nil
    }

    private let hls = VASTMediaFile(url: "https://cdn.example/master.m3u8", delivery: "streaming", type: "application/x-mpegURL", width: 1920,
                                    height: 1080)
    private let webm = VASTMediaFile(url: "https://cdn.example/a.webm", delivery: "progressive", type: "video/webm", width: 1280, height: 720)
    private let vpaid = VASTMediaFile(url: "https://cdn.example/vpaid.js", delivery: "progressive", type: "application/javascript", width: 1280,
                                      height: 720, apiFramework: "VPAID")

    @Test func progressiveH264BeatsHLSWhichBeatsHEVC() {
        let hevc = mp4(1920, 1080, codec: "hvc1.1.6.L93.B0", name: "hevc")
        #expect(chosenURL([webm, hls, hevc, mp4(640, 360)]) == "https://cdn.example/640x360.mp4")
        #expect(chosenURL([webm, hevc, hls]) == "https://cdn.example/master.m3u8")
        #expect(chosenURL([webm, hevc]) == "https://cdn.example/hevc.mp4")
    }

    @Test func smallestFileCoveringThePlayerElseTheLargest() {
        let files = [mp4(1920, 1080), mp4(640, 360), mp4(1280, 720), mp4(320, 180)]
        #expect(chosenURL(files, 640, 360) == "https://cdn.example/640x360.mp4")
        #expect(chosenURL(files, 641, 360) == "https://cdn.example/1280x720.mp4")
        #expect(chosenURL(files, 1280, 720) == "https://cdn.example/1280x720.mp4")
        #expect(chosenURL(files, 3840, 2160) == "https://cdn.example/1920x1080.mp4")
        #expect(chosenURL(files, 0, 0) == "https://cdn.example/1920x1080.mp4")
        // Portrait player: 360×640 is covered by neither landscape dimension pair except 1280×720 and up.
        #expect(chosenURL(files, 360, 640) == "https://cdn.example/1280x720.mp4")
    }

    @Test func equalSizesPreferTheHigherBitrateThenDocumentOrder() {
        let low = mp4(1280, 720, bitrate: 800, name: "low")
        let high = mp4(1280, 720, bitrate: 2500, name: "high")
        let alsoHigh = mp4(1280, 720, bitrate: 2500, name: "also-high")
        #expect(chosenURL([low, high, alsoHigh]) == "https://cdn.example/high.mp4")
        #expect(chosenURL([low, high, alsoHigh], 3840, 2160) == "https://cdn.example/high.mp4")
        var ranged = mp4(1280, 720, name: "ranged")
        ranged.maxBitrate = 3000
        #expect(chosenURL([low, high, ranged]) == "https://cdn.example/ranged.mp4")
    }

    @Test func vpaidOnlyIs901AndNothingPlayableIs403() {
        #expect(VASTMediaSelector.choose([vpaid], playerWidth: 1280, playerHeight: 720) == .unsupported(.vpaidError))
        var flashVPAID = vpaid
        flashVPAID.type = "application/x-shockwave-flash"
        #expect(VASTMediaSelector.choose([vpaid, flashVPAID], playerWidth: 1280, playerHeight: 720) == .unsupported(.vpaidError))
        #expect(VASTMediaSelector.choose([webm], playerWidth: 1280, playerHeight: 720) == .unsupported(.noSupportedMedia))
        #expect(VASTMediaSelector.choose([vpaid, webm], playerWidth: 1280, playerHeight: 720) == .unsupported(.noSupportedMedia))
        #expect(VASTMediaSelector.choose([], playerWidth: 1280, playerHeight: 720) == .unsupported(.noSupportedMedia))
        #expect(chosenURL([vpaid, mp4(1280, 720)]) == "https://cdn.example/1280x720.mp4")
    }

    @Test func javaScriptMediaWithoutAPIFrameworkCountsAsVPAID() {
        var script = vpaid
        script.apiFramework = nil
        #expect(VASTMediaSelector.choose([script], playerWidth: 1, playerHeight: 1) == .unsupported(.vpaidError))
    }

    @Test func audio() {
        let aac = VASTMediaFile(url: "https://cdn.example/a.m4a", delivery: "progressive", type: "audio/mp4", bitrate: 128)
        let mp3 = VASTMediaFile(url: "https://cdn.example/a.mp3", delivery: "progressive", type: "audio/mpeg", bitrate: 192)
        #expect(chosenURL([mp4(1280, 720), aac, mp3], audioOnly: true) == "https://cdn.example/a.mp3")
        #expect(VASTMediaSelector.choose([mp4(1280, 720)], playerWidth: 0, playerHeight: 0, audioOnly: true) == .unsupported(.noSupportedMedia))
        // A video player plays an audio-only ad rather than failing.
        #expect(chosenURL([webm, aac]) == "https://cdn.example/a.m4a")
        #expect(chosenURL([aac, mp4(1280, 720)]) == "https://cdn.example/1280x720.mp4")
    }

    @Test func typesAreNormalisedAndInferred() {
        let withParameters = VASTMediaFile(url: "https://cdn.example/p.mp4", type: " Video/MP4; codecs=\"avc1.42E01E, mp4a.40.2\" ", width: 640,
                                           height: 360)
        #expect(chosenURL([webm, withParameters]) == "https://cdn.example/p.mp4")
        let untyped = VASTMediaFile(url: "https://cdn.example/untyped.MP4?token=1", width: 640, height: 360)
        #expect(chosenURL([webm, untyped]) == "https://cdn.example/untyped.MP4?token=1")
        let unknown = VASTMediaFile(url: "https://cdn.example/stream", width: 640, height: 360)
        #expect(VASTMediaSelector.choose([unknown], playerWidth: 1, playerHeight: 1) == .unsupported(.noSupportedMedia))
    }

    @Test func unplayableCodecsAndSchemesAreSkipped() {
        let vp9 = mp4(1280, 720, codec: "vp09.00.10.08", name: "vp9")
        let rtmp = VASTMediaFile(url: "rtmp://cdn.example/live", delivery: "streaming", type: "video/mp4", width: 1280, height: 720)
        let dash = VASTMediaFile(url: "https://cdn.example/a.mpd", delivery: "streaming", type: "application/dash+xml", width: 1280, height: 720)
        #expect(VASTMediaSelector.choose([vp9, rtmp, dash], playerWidth: 1280, playerHeight: 720) == .unsupported(.noSupportedMedia))
        let sample = VASTMediaFile(url: VASTSamples.videoURL, delivery: "progressive", type: "video/mp4", width: 1280, height: 720)
        #expect(chosenURL([sample]) == VASTSamples.videoURL)
    }

    @Test func hugeDimensionsDoNotOverflow() {
        let huge = mp4(Int.max, Int.max, name: "huge")
        #expect(chosenURL([huge, mp4(1280, 720)], 1280, 720) == "https://cdn.example/1280x720.mp4")
        #expect(chosenURL([huge, mp4(-5, -5, name: "negative")], 3840, 2160) == "https://cdn.example/huge.mp4")
    }

    @Test func samplesSelectTheirMedia() throws {
        for (xml, audioOnly, expected) in [(VASTSamples.inline42Verification, false, VASTSamples.videoURL), (VASTSamples.audio40, true, VASTSamples.audioURL)] {
            let (document, _) = VASTParser.parse(xml)
            guard case let .inline(inline) = document?.ads.first?.body else {
                Issue.record("expected an inline ad")
                continue
            }
            #expect(chosenURL(inline.playedLinear?.mediaFiles ?? [], 393, 852, audioOnly: audioOnly) == expected)
        }
        let (vpaidDocument, _) = VASTParser.parse(VASTSamples.vpaidOnly)
        guard case let .inline(vpaidInline) = vpaidDocument?.ads.first?.body else {
            Issue.record("expected an inline ad")
            return
        }
        #expect(VASTMediaSelector.choose(vpaidInline.playedLinear?.mediaFiles ?? [], playerWidth: 1280, playerHeight: 720)
            == .unsupported(.vpaidError))
    }
}
