import AVFoundation
import CoreVideo

public enum SlideshowError: Error, CustomStringConvertible {
    case noFrames
    case pixelBuffer(Int32)
    case write(String)

    public var description: String {
        switch self {
        case .noFrames: return "no frames"
        case .pixelBuffer(let status): return "pixel buffer: \(status)"
        case .write(let why): return "writing video failed: \(why)"
        }
    }
}

public struct Slide: Equatable, Sendable {
    public let offsetNanos: UInt64
    public let url: URL

    public init(offsetNanos: UInt64, url: URL) {
        self.offsetNanos = offsetNanos
        self.url = url
    }
}

public enum SlideshowWriter {
    public static func write(audio: URL, slides: [Slide], chapters: [Chapter], title: String?, to out: URL) throws {
        let frames = try AVAudioFile(forReading: audio).length
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        let shown = times(slides, endNanos: UInt64(frames) * 1_000_000_000 / UInt64(Timeline.rate))
        guard let first = shown.first?.slide else { throw SlideshowError.noFrames }
        let firstImage = try Frames.decode(first.url)
        let size = Frames.fitSize(width: firstImage.width, height: firstImage.height)
        let source = try AudioPassthrough(audio)
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.metadata = ChapterWriter.titleMetadata(title)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 1,
            ],
        ])
        writer.add(video)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
        writer.add(sound)
        let text = try ChapterWriter.chapterLane(chapters, end: end, writer: writer, linkedFrom: [video, sound])
        var index = 0
        let pictures: WriterFeed.Lane = (video, {
            guard index < shown.count else { return nil }
            let item = shown[index]
            index += 1
            let next = index < shown.count ? time(shown[index].atNanos) : end
            return try sample(Frames.decode(item.slide.url), width: size.width, height: size.height, at: time(item.atNanos), until: next)
        })
        guard writer.startWriting() else { throw SlideshowError.write("\(writer.error.map { "\($0)" } ?? "start")") }
        writer.startSession(atSourceTime: .zero)
        try WriterFeed([pictures, source.lane(sound)] + (text.map { [$0] } ?? [])).run(writer)
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, source.reader.status == .completed else {
            throw SlideshowError.write("\(writer.error ?? source.reader.error.map { $0 as any Error } ?? SlideshowError.noFrames)")
        }
    }

    static func times(_ slides: [Slide], endNanos: UInt64) -> [(atNanos: UInt64, slide: Slide)] {
        var out: [(atNanos: UInt64, slide: Slide)] = []
        for slide in slides.sorted(by: { $0.offsetNanos < $1.offsetNanos }) where slide.offsetNanos < endNanos {
            if out.last?.slide.offsetNanos == slide.offsetNanos { out.removeLast() }
            out.append((out.isEmpty ? 0 : slide.offsetNanos, slide))
        }
        return out
    }

    private static func time(_ nanos: UInt64) -> CMTime { CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000) }

    private static func sample(_ image: CGImage, width: Int, height: Int, at start: CMTime, until next: CMTime) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw SlideshowError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = Frames.context(
            CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        if let ctx { Frames.render(image, in: ctx, width: width, height: height) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard ctx != nil else { throw FrameError.draw }
        var format: CMVideoFormatDescription?
        status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw SlideshowError.pixelBuffer(status) }
        var timing = CMSampleTimingInfo(duration: next - start, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SlideshowError.pixelBuffer(status) }
        return sample
    }
}
