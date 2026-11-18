import Foundation
import Testing
@testable import CcinnOpenRTBKit

@Suite("HLS playlist rewriting")
struct HLSPlaylistTests {
    private let base = URL(string: "https://cdn.example/hls/master.m3u8?token=1")!

    private func rewrite(_ text: String) -> (text: String, references: [HLSPlaylist.Reference]) {
        var references: [HLSPlaylist.Reference] = []
        let output = HLSPlaylist.rewrite(text, base: base, unresolved: "http://127.0.0.1/dead") { reference in
            references.append(reference)
            return "http://127.0.0.1:9/r/\(references.count)"
        }
        return (output, references)
    }

    @Test func masterPlaylistVariantsAndRenditionsArePlaylists() {
        let master = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/session.key"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="en",URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aac"
        low/index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="low/iframe.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000
        https://other.example/high/index.m3u8
        """
        let (output, references) = rewrite(master)
        #expect(references.map(\.url.absoluteString) == ["https://cdn.example/hls/keys/session.key", "https://cdn.example/hls/audio/en.m3u8",
                                                         "https://cdn.example/hls/low/index.m3u8", "https://cdn.example/hls/low/iframe.m3u8",
                                                         "https://other.example/high/index.m3u8"])
        #expect(references.map(\.kind) == [.key, .playlist, .playlist, .playlist, .playlist])
        #expect(output == """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="http://127.0.0.1:9/r/1"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="en",URI="http://127.0.0.1:9/r/2"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aac"
        http://127.0.0.1:9/r/3
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="http://127.0.0.1:9/r/4"
        #EXT-X-STREAM-INF:BANDWIDTH=2400000
        http://127.0.0.1:9/r/5
        """)
    }

    @Test func mediaPlaylistSegmentsKeysAndMapsAreRewritten() {
        let media = "#EXTM3U\r\n#EXT-X-TARGETDURATION:4\r\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example/k1\",IV=0x1\r\n"
            + "#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"720@0\"\r\n#EXTINF:4.0,\r\nseg0.m4s\r\n#EXTINF:4.0,\r\n/abs/seg1.m4s\r\n"
            + "#EXT-X-KEY:METHOD=NONE\r\n#EXTINF:4.0,\r\n//edge.example/seg2.m4s\r\n#EXT-X-ENDLIST\r\n"
        let (output, references) = rewrite(media)
        #expect(references.map(\.url.absoluteString) == ["https://keys.example/k1", "https://cdn.example/hls/init.mp4",
                                                         "https://cdn.example/hls/seg0.m4s", "https://cdn.example/abs/seg1.m4s",
                                                         "https://edge.example/seg2.m4s"])
        #expect(references.map(\.kind) == [.key, .map, .segment, .segment, .segment])
        // CRLF in, LF out.
        #expect(output.contains("#EXT-X-MAP:URI=\"http://127.0.0.1:9/r/2\",BYTERANGE=\"720@0\"\n"))
        #expect(output.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:9/r/1\",IV=0x1\n"))
        #expect(output.contains("#EXT-X-KEY:METHOD=NONE\n"))
        #expect(!output.contains("\r"))
        #expect(!output.contains("example"), "no origin URL survives: \(output)")
    }

    /// Nothing that could reach the network is left for the player: every http(s) or relative URI comes out routed (or,
    /// when it cannot be resolved at all, as a dead route); data: and FairPlay skd: URIs never reach the network through
    /// the player and stay.
    @Test func noURIIsLeftForThePlayerToFetch() {
        let media = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key-id\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n"
            + "#EXTINF:4,\nhttp://[bad\n#EXTINF:4,\nHTTPS://Upper.example/a.ts\n#EXTINF:4,\nseg 3.ts\n#EXTINF:4,\ndata:video/mp2t;base64,AAAA\n"
        let (output, _) = rewrite(media)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines[1] == "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key-id\",KEYFORMAT=\"com.apple.streamingkeydelivery\"")
        for uri in [lines[3], lines[5], lines[7]] { #expect(uri.hasPrefix("http://127.0.0.1"), "\(uri)") }
        #expect(lines[9] == "data:video/mp2t;base64,AAAA")
    }

    @Test func playlistsAreRecognisedByTypeOrSignature() {
        #expect(HLSPlaylist.isPlaylist(Data(), mimeType: "application/vnd.apple.mpegurl"))
        #expect(HLSPlaylist.isPlaylist(Data(), mimeType: "Application/X-MpegURL"))
        #expect(HLSPlaylist.isPlaylist(Data("\u{FEFF}\n #EXTM3U\n".utf8), mimeType: "text/plain"))
        #expect(!HLSPlaylist.isPlaylist(Data("<VAST/>".utf8), mimeType: "video/mp4"))
    }
}

@Suite("Byte ranges")
struct ByteRangeTests {
    @Test func rangeHeadersRoundTrip() {
        #expect(ByteRange.from(0, through: 1).header == "bytes=0-1")
        #expect(ByteRange.from(100).header == "bytes=100-")
        #expect(ByteRange(header: "bytes=5-9")?.header == "bytes=5-9")
        #expect(ByteRange(header: " bytes=7- ")?.header == "bytes=7-")
        #expect(ByteRange(header: "bytes=-500")?.header == "bytes=-500")
    }

    @Test(arguments: ["bytes=9-5", "bytes=0-1,5-6", "items=0-1", "bytes=a-b", "bytes=-", "bytes=0-1\r\nX-Evil: 1", "bytes=-0",
                      "bytes=１-２", "bytes=99999999999999999999-"])
    func onlyASingleWellFormedRangeIsAccepted(_ header: String) {
        #expect(ByteRange(header: header) == nil)
    }

    @Test func contentRangesParse() {
        #expect(ContentRange(header: "bytes 0-1/1000") == ContentRange(start: 0, end: 1, total: 1000))
        #expect(ContentRange(header: "bytes 10-19/*") == ContentRange(start: 10, end: 19, total: nil))
        #expect(ContentRange(header: "bytes 0-1/1") == nil, "the end must be inside the total")
        #expect(ContentRange(header: "bytes */1000") == nil)
        #expect(ContentRange(header: nil) == nil)
        #expect(ContentRange(start: 0, end: 9, total: 10).length == 10)
    }
}

@Suite("Media resource loader")
struct MediaResourceLoaderTests {
    private let url = URL(string: "https://cdn.example/ads/clip.mp4")!

    private func part(_ status: Int, body: Data = Data(count: 2), mimeType: String? = "video/mp4", range: ContentRange? = nil,
                      playlist: Bool = false, truncated: Bool = false) -> MediaPart {
        MediaPart(status: status, mimeType: mimeType, body: body, contentRange: range, isPlaylist: playlist, truncated: truncated)
    }

    @Test func aRangedAnswerGivesTheLength() throws {
        let resource = try MediaResourceLoader.resource(from: part(206, range: ContentRange(start: 0, end: 1, total: 5_000)), offset: 0, url: url)
        guard case let .ranged(type, length) = resource else { Issue.record("\(resource)"); return }
        #expect(type == "public.mpeg-4")
        #expect(length == 5_000)
        #expect(resource.isKept)
    }

    /// A server that ignores `Range` is read whole once; a playlist is never kept, because a live one changes.
    @Test func wholeBodiesAreKeptPlaylistsAreNot() throws {
        let whole = try MediaResourceLoader.resource(from: part(200, body: Data(count: 10)), offset: 0, url: url)
        #expect(whole.isKept)
        let playlist = try MediaResourceLoader.resource(from: part(200, mimeType: "application/vnd.apple.mpegurl", playlist: true), offset: 0, url: url)
        #expect(!playlist.isKept)
    }

    @Test func inconsistentAnswersFail() {
        #expect(throws: NetworkMonitorError.self) {
            _ = try MediaResourceLoader.resource(from: part(206, range: ContentRange(start: 10, end: 11, total: 100)), offset: 0, url: url)
        }
        #expect(throws: NetworkMonitorError.self) {
            _ = try MediaResourceLoader.resource(from: part(206, range: ContentRange(start: 0, end: 1, total: nil)), offset: 0, url: url)
        }
        #expect(throws: NetworkMonitorError.tooLarge(limit: NetworkMonitor.maxContentBytes)) {
            _ = try MediaResourceLoader.resource(from: part(200, truncated: true), offset: 0, url: url)
        }
        #expect(throws: NetworkMonitorError.self) { _ = try MediaResourceLoader.resource(from: part(404), offset: 0, url: url) }
    }

    @Test func theTypeComesFromTheMIMETypeThenTheExtension() {
        #expect(MediaResourceLoader.uniformType(mimeType: "audio/mp4", url: url) == "public.mpeg-4-audio")
        #expect(MediaResourceLoader.uniformType(mimeType: "application/octet-stream", url: url) == "public.mpeg-4")
        #expect(MediaResourceLoader.uniformType(mimeType: nil, url: URL(string: "https://x/a.mov")!) == "com.apple.quicktime-movie")
        #expect(MediaResourceLoader.uniformType(mimeType: "binary/x-unknown", url: URL(string: "https://x/a")!) == "public.mpeg-4")
    }

    /// The private scheme is unique per loader and names nothing of the origin but the file name.
    @Test func everyLoaderHasItsOwnPrivateURL() {
        let fetch: @Sendable (ByteRange?, Int) async -> Result<MediaPart, NetworkMonitorError> = { _, _ in .failure(.cleared) }
        let first = MediaResourceLoader(remoteURL: url, chunkBytes: 1, fetch: fetch)
        let second = MediaResourceLoader(remoteURL: url, chunkBytes: 1, fetch: fetch)
        #expect(first.url != second.url)
        #expect(first.url.scheme?.hasPrefix(MediaResourceLoader.schemePrefix) == true)
        #expect(first.url.lastPathComponent == "clip.mp4")
        #expect(!first.url.absoluteString.contains("cdn.example"))
    }
}

@Suite("Media loopback proxy")
struct MediaLoopbackProxyTests {
    @Test func requestsAreParsedStrictly() {
        let request = MediaLoopbackProxy.parse(Data("GET /t/1/seg.ts HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\nCookie: a=b".utf8))
        #expect(request?.method == "GET")
        #expect(request?.path == "/t/1/seg.ts")
        #expect(request?.range?.header == "bytes=0-99")
        #expect(MediaLoopbackProxy.parse(Data("GET /t/1 HTTP/1.1\r\nRange: bytes=0-1,4-5".utf8))?.range == nil)
        #expect(MediaLoopbackProxy.parse(Data("garbage".utf8)) == nil)
        #expect(MediaLoopbackProxy.parse(Data("GET /x SPDY/3".utf8)) == nil)
    }

    /// Only the router's current routes exist: anything else is 404, and nothing but the route and a range reaches it.
    @Test func unknownRoutesAreNotFound() async throws {
        let proxy = try MediaLoopbackProxy { request in
            request.path == "/known" ? MediaLoopbackProxy.Response(status: 200, headers: ["Content-Type": "text/plain"], body: Data("ok".utf8))
                : .status(404)
        }
        let port = try await proxy.start()
        defer { proxy.stop() }
        let session = URLSession(configuration: .ephemeral)
        let (body, known) = try await session.data(from: try #require(URL(string: "http://127.0.0.1:\(port)/known")))
        #expect((known as? HTTPURLResponse)?.statusCode == 200)
        #expect(body == Data("ok".utf8))
        let (_, unknown) = try await session.data(from: try #require(URL(string: "http://127.0.0.1:\(port)/other")))
        #expect((unknown as? HTTPURLResponse)?.statusCode == 404)
    }
}
