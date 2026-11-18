import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import UniformTypeIdentifiers

/// A tiny fMP4 HLS stream (4 s of 160×90 H.264 in 1 s segments), written with AVAssetWriter's HLS profile.
struct HLSFixture: Sendable {
    var initSection: Data
    var segments: [(data: Data, duration: Double)]

    /// The media playlist, with relative URIs (`init.mp4`, `seg<N>.m4s`).
    var mediaPlaylist: String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (index, segment) in segments.enumerated() { text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\nseg\(index).m4s\n" }
        return text + "#EXT-X-ENDLIST\n"
    }

    static func masterPlaylist(variant: String) -> String {
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=160x90,CODECS=\"avc1.42c00c\"\n\(variant)\n"
    }

    private final class Collector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var initSection = Data()
        private var segments: [(Data, Double)] = []

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            lock.lock()
            defer { lock.unlock() }
            switch segmentType {
            case .initialization: initSection = segmentData
            case .separable: segments.append((segmentData, segmentReport?.trackReports.first?.duration.seconds ?? 1))
            @unknown default: break
            }
        }

        var fixture: HLSFixture {
            lock.lock()
            defer { lock.unlock() }
            return HLSFixture(initSection: initSection, segments: segments.map { (data: $0.0, duration: $0.1) })
        }
    }

    enum Failure: Error { case writer(String) }

    static func make() throws -> HLSFixture {
        let collector = Collector()
        guard let type = UTType(AVFileType.mp4.rawValue) else { throw Failure.writer("no MP4 type") }
        let writer = AVAssetWriter(contentType: type)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
                if waited > 2_000 { throw Failure.writer("the writer stalled") }
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(frame * 2 % 255), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "finishWriting")
        }
        return collector.fixture
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
