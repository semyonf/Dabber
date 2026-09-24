import AVFoundation

public final class CAFSegment: SegmentSource {
    public let url: URL
    public let frames: Int
    public let channels: Int
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?

    public init(url: URL) throws {
        self.url = url
        let file = try Self.open(url)
        frames = Int(file.length)
        channels = Int(file.processingFormat.channelCount)
        file.close()
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    public func read(_ range: Range<Int>) throws -> [Float] {
        let file = try self.file ?? Self.open(url)
        self.file = file
        let buffer = self.buffer ?? AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        self.buffer = buffer
        var out: [Float] = []
        out.reserveCapacity(range.count * channels)
        var pos = range.lowerBound
        let end = min(range.upperBound, frames)
        while pos < end {
            let n = min(48_000, end - pos)
            file.framePosition = AVAudioFramePosition(pos)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: got * channels))
            pos += got
        }
        out.append(contentsOf: repeatElement(0, count: range.count * channels - out.count))
        return out
    }

    public func close() {
        file?.close()
        file = nil
    }
}
