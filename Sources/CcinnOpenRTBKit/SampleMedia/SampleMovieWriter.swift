import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Writes the sample video (H.264 + AAC MP4 with a running timecode and the VAST quartile the playhead is in) and the
/// sample audio (AAC M4A tone) with AVAssetWriter. Synchronous: call it off the Swift concurrency pool
/// (`SampleMedia` runs it on a dispatch queue).
enum SampleMovieWriter {
    static let duration = 15
    static let width = 1280
    static let height = 720
    static let framesPerSecond: Int32 = 30
    static let sampleRate = 44_100
    /// Audio is appended in chunks of this many samples (0.1 s).
    static let audioChunk = 4_410
    /// Generation never hangs: a writer that stops accepting data for this long fails.
    static let stallTimeout: TimeInterval = 30

    static func writeVideo(to url: URL) throws {
        try write(to: url, fileType: .mp4, includeVideo: true)
    }

    static func writeAudio(to url: URL) throws {
        try write(to: url, fileType: .m4a, includeVideo: false)
    }

    private static func write(to url: URL, fileType: AVFileType, includeVideo: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if includeVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000,
                    AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond),
                ] as [String: Any],
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw SampleMediaError.generationFailed("the writer refused the video track") }
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
            videoInput = input
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { throw SampleMediaError.generationFailed("the writer refused the audio track") }
        writer.add(audioInput)

        guard let audioFormat = makeAudioFormat() else { throw SampleMediaError.generationFailed("no audio format") }
        guard writer.startWriting() else {
            throw SampleMediaError.generationFailed(writer.error?.localizedDescription ?? "the writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let background = includeVideo ? FrameRenderer.background() : nil
        let totalFrames = includeVideo ? duration * Int(framesPerSecond) : 0
        let totalSamples = duration * sampleRate
        var frame = 0
        var sample = 0
        var lastProgress = Date()

        while frame < totalFrames || sample < totalSamples {
            if writer.status == .failed {
                throw SampleMediaError.generationFailed(writer.error?.localizedDescription ?? "the writer failed")
            }
            let videoTime = Double(frame) / Double(framesPerSecond)
            let audioTime = Double(sample) / Double(sampleRate)
            let videoWanted = frame < totalFrames && (videoTime <= audioTime || sample >= totalSamples)
            var progressed = false

            if videoWanted, let videoInput, let adaptor, videoInput.isReadyForMoreMediaData {
                try appendFrame(frame, adaptor: adaptor, background: background)
                frame += 1
                progressed = true
            } else if sample < totalSamples, audioInput.isReadyForMoreMediaData {
                let count = min(audioChunk, totalSamples - sample)
                guard let buffer = makeAudioBuffer(start: sample, count: count, format: audioFormat), audioInput.append(buffer) else {
                    throw SampleMediaError.generationFailed(writer.error?.localizedDescription ?? "could not append audio")
                }
                sample += count
                progressed = true
            } else if frame < totalFrames, let videoInput, let adaptor, videoInput.isReadyForMoreMediaData {
                try appendFrame(frame, adaptor: adaptor, background: background)
                frame += 1
                progressed = true
            }

            if progressed {
                lastProgress = Date()
            } else {
                if Date().timeIntervalSince(lastProgress) > stallTimeout {
                    writer.cancelWriting()
                    throw SampleMediaError.generationFailed("the writer stalled")
                }
                usleep(1_000)
            }
        }
        videoInput?.markAsFinished()
        audioInput.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + stallTimeout) == .success, writer.status == .completed else {
            writer.cancelWriting()
            throw SampleMediaError.generationFailed(writer.error?.localizedDescription ?? "the writer did not finish")
        }
    }

    private static func appendFrame(_ frame: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor, background: CGImage?) throws {
        guard let pool = adaptor.pixelBufferPool else { throw SampleMediaError.generationFailed("no pixel buffer pool") }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            throw SampleMediaError.generationFailed("no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw SampleMediaError.generationFailed("no drawing context")
        }
        FrameRenderer.draw(frame: frame, in: context, background: background)
        let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw SampleMediaError.generationFailed("could not append frame \(frame)")
        }
    }

    // MARK: Audio

    private static func makeAudioFormat() -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                      mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    /// A soft 440 Hz tone with an 880 Hz pip at every second and a 1320 Hz pip at each quartile.
    static func toneSample(_ index: Int) -> Int16 {
        let time = Double(index) / Double(sampleRate)
        let base = 0.10 * sin(2 * .pi * 440 * time)
        let intoSecond = time - time.rounded(.down)
        var pip = 0.0
        if intoSecond < 0.08 {
            let envelope = sin(.pi * intoSecond / 0.08)
            pip = 0.22 * envelope * sin(2 * .pi * 880 * time)
        }
        let quarter = Double(duration) / 4
        let intoQuarter = time.truncatingRemainder(dividingBy: quarter)
        if time >= quarter * 0.99, intoQuarter < 0.15 {
            let envelope = sin(.pi * intoQuarter / 0.15)
            pip += 0.25 * envelope * sin(2 * .pi * 1320 * time)
        }
        let value = max(-1, min(1, base + pip))
        return Int16(value * Double(Int16.max - 1))
    }

    private static func makeAudioBuffer(start: Int, count: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let samples = (start..<(start + count)).map(toneSample)
        let byteCount = count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)), packetDescriptions: nil,
            sampleBufferOut: &buffer)
        return status == noErr ? buffer : nil
    }
}

/// Draws the video frames: a static background rendered once, then the timecode, progress and quartile per frame.
enum FrameRenderer {
    static let width = SampleMovieWriter.width
    static let height = SampleMovieWriter.height

    static func background() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = [CGColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1), CGColor(srgbRed: 0.19, green: 0.18, blue: 0.51, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: 0), options: [])
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.05))
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 80) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: 80) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
        SampleImageRenderer.drawText(context, "CcinnOpenRTB sample", in: bounds, size: 54, weight: .bold, centerY: bounds.maxY - 90)
        SampleImageRenderer.drawText(context, "1280×720 · H.264 + AAC · 30 fps · 15 s", in: bounds, size: 24, weight: .regular,
                                     centerY: bounds.maxY - 145, alpha: 0.7)
        return context.makeImage()
    }

    static func draw(frame: Int, in context: CGContext, background: CGImage?) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.draw(background, in: bounds)
        } else {
            context.setFillColor(CGColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1))
            context.fill(bounds)
        }
        let fps = Int(SampleMovieWriter.framesPerSecond)
        let total = Double(SampleMovieWriter.duration)
        let seconds = Double(frame) / Double(fps)
        let timecode = String(format: "%02d:%02d.%02d", frame / fps / 60, frame / fps % 60, frame % fps)
        SampleImageRenderer.drawText(context, timecode, in: bounds, size: 170, weight: .bold, centerY: bounds.midY + 20)
        SampleImageRenderer.drawText(context, "frame \(frame + 1) / \(SampleMovieWriter.duration * fps)  ·  \(quartileLabel(seconds / total))",
                                     in: bounds, size: 28, weight: .semibold, centerY: bounds.midY - 110, alpha: 0.8)

        // Progress bar with the VAST quartile marks.
        let bar = CGRect(x: 120, y: 90, width: CGFloat(width - 240), height: 14)
        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 7, cornerHeight: 7, transform: nil))
        context.fillPath()
        let filled = CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(1, seconds / total)), height: bar.height)
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1))
        context.addPath(CGPath(roundedRect: filled, cornerWidth: 7, cornerHeight: 7, transform: nil))
        context.fillPath()
        for (fraction, label) in [(0.25, "Q1"), (0.5, "Mid"), (0.75, "Q3")] {
            let x = bar.minX + bar.width * CGFloat(fraction)
            context.setFillColor(CGColor(gray: 1, alpha: 0.9))
            context.fill(CGRect(x: x - 1.5, y: bar.minY - 8, width: 3, height: bar.height + 16))
            SampleImageRenderer.drawText(context, label, in: CGRect(x: x - 60, y: 0, width: 120, height: 40), size: 20, weight: .semibold,
                                         centerY: bar.minY - 30, alpha: 0.75)
        }
    }

    /// The last VAST progress event a player has fired at this point.
    static func quartileLabel(_ progress: Double) -> String {
        switch progress {
        case ..<0.25: "start"
        case ..<0.5: "firstQuartile"
        case ..<0.75: "midpoint"
        case ..<0.999: "thirdQuartile"
        default: "complete"
        }
    }
}
