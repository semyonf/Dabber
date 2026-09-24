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
        let movie = AVMovie(url: url)
        guard let track = movie.tracks.first(where: { $0.mediaType == .audio }) else { throw ChapterError.noAudio(name) }
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading(), let first = output.copyNextSampleBuffer(), let audioFormat = first.formatDescription else {
            throw ChapterError.noAudio(name)
        }
        let temp = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: out, fileType: .m4a)
        if let title {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            writer.metadata = [item]
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        writer.add(audio)
        let end = CMTime(value: frames, timescale: CMTimeScale(Timeline.rate))
        var text: AVAssetWriterInput?
        var samples: [CMSampleBuffer] = []
        if !chapters.isEmpty {
            let textFormat = try Self.textFormat()
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
            input.marksOutputTrackAsEnabled = false
            writer.add(input)
            audio.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            samples = try chapters.indices.map { i in
                let start = CMTime(value: CMTimeValue(chapters[i].startMillis), timescale: 1000)
                let next = i + 1 < chapters.count ? CMTime(value: CMTimeValue(chapters[i + 1].startMillis), timescale: 1000) : end
                return try Self.sample(chapters[i].title, start: start, duration: next - start, format: textFormat)
            }
            text = input
        }
        guard writer.startWriting() else { throw ChapterError.write(name, "\(writer.error.map { "\($0)" } ?? "start")") }
        writer.startSession(atSourceTime: .zero)
        let feed = Feed(audio: audio, text: text, output: output, first: first, samples: samples)
        guard feed.run() else {
            writer.cancelWriting()
            throw ChapterError.write(name, "timed out")
        }
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, reader.status == .completed else {
            throw ChapterError.write(name, "\(writer.error ?? reader.error.map { $0 as any Error } ?? ChapterError.noAudio(name))")
        }
        let written = try AVAudioFile(forReading: out).length
        guard written == frames else {
            throw FinalizeError.lengthMismatch(file: name, expected: Int(frames), actual: Int(written))
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
    }

    private final class Feed: @unchecked Sendable {
        let audio: AVAssetWriterInput
        let text: AVAssetWriterInput?
        let output: AVAssetReaderTrackOutput
        var first: CMSampleBuffer?
        var samples: [CMSampleBuffer]
        let group = DispatchGroup()

        init(audio: AVAssetWriterInput, text: AVAssetWriterInput?, output: AVAssetReaderTrackOutput,
             first: CMSampleBuffer, samples: [CMSampleBuffer]) {
            self.audio = audio
            self.text = text
            self.output = output
            self.first = first
            self.samples = samples
        }

        func run() -> Bool {
            if let text {
                group.enter()
                text.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.text")) { self.feedText() }
            }
            group.enter()
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dabber.chapters.audio")) { self.feedAudio() }
            return group.wait(timeout: .now() + 600) == .success
        }

        private func feedText() {
            guard let text else { return }
            while text.isReadyForMoreMediaData {
                guard !samples.isEmpty, text.append(samples.removeFirst()) else { return finish(text) }
            }
        }

        private func feedAudio() {
            while audio.isReadyForMoreMediaData {
                let next = first ?? output.copyNextSampleBuffer()
                first = nil
                guard let next, audio.append(next) else { return finish(audio) }
            }
        }

        private func finish(_ input: AVAssetWriterInput) {
            input.markAsFinished()
            group.leave()
        }
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
