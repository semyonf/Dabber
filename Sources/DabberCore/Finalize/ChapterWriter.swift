import AVFoundation
import CoreMedia

public enum ChapterError: Error, CustomStringConvertible {
    case noAudio(String)
    case format(OSStatus)
    case write(String, String)

    public var description: String {
        switch self {
        case .noAudio(let file): return "\(file): no audio to add chapters to"
        case .format(let status): return "chapter format: \(status)"
        case .write(let file, let why): return "\(file): writing chapters failed: \(why)"
        }
    }
}

public enum ChapterWriter {
    public static func write(_ chapters: [Chapter], title: String? = nil, into url: URL) throws {
        let name = url.lastPathComponent
        let frames = try AVAudioFile(forReading: url).length
        let source = try AudioPassthrough(url)
        let temp = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        writer.metadata = titleMetadata(title)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.format)
        writer.add(audio)
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        let text = try chapterLane(chapters, end: end, writer: writer, linkedFrom: [audio])
        guard writer.startWriting() else { throw ChapterError.write(name, "\(writer.error.map { "\($0)" } ?? "start")") }
        writer.startSession(atSourceTime: .zero)
        guard try WriterFeed([source.lane(audio)] + (text.map { [$0] } ?? [])).run() else {
            writer.cancelWriting()
            throw ChapterError.write(name, "timed out")
        }
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, source.reader.status == .completed else {
            throw ChapterError.write(name, "\(writer.error ?? source.reader.error.map { $0 as any Error } ?? ChapterError.noAudio(name))")
        }
        let written = try AVAudioFile(forReading: out).length
        guard written == frames else {
            throw FinalizeError.lengthMismatch(file: name, expected: Int(frames), actual: Int(written))
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
    }

    static func titleMetadata(_ title: String?) -> [AVMetadataItem] {
        guard let title else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        return [item]
    }

    static func chapterLane(
        _ chapters: [Chapter], end: CMTime, writer: AVAssetWriter, linkedFrom tracks: [AVAssetWriterInput]
    ) throws -> WriterFeed.Lane? {
        guard !chapters.isEmpty else { return nil }
        let format = try textFormat()
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
        input.marksOutputTrackAsEnabled = false
        writer.add(input)
        for track in tracks {
            track.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        }
        var samples = try chapters.indices.map { i in
            let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
            let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
            return try sample(chapters[i].title, start: start, duration: next - start, format: format)
        }
        return (input, { samples.isEmpty ? nil : samples.removeFirst() })
    }

    private static func sample(_ title: String, start: CMTime, duration: CMTime, format: CMFormatDescription) throws -> CMSampleBuffer {
        let bytes = Array(title.utf8)
        let data = [UInt8(bytes.count >> 8 & 0xff), UInt8(bytes.count & 0xff)] + bytes
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw ChapterError.format(status) }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw ChapterError.format(status) }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ChapterError.format(status) }
        return sample
    }

    private static func textFormat() throws -> CMFormatDescription {
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
            kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let clear: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
            kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor: clear,
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 18, kCMTextFormatDescriptionStyle_ForegroundColor: white,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw ChapterError.format(status) }
        return format
    }
}
