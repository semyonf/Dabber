import AVFoundation

public enum FinalizeError: Error, CustomStringConvertible {
    case buffer
    case lengthMismatch(file: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .buffer: return "could not allocate pcm buffer"
        case .lengthMismatch(let file, let expected, let actual):
            return "\(file): wrote \(expected) frames, file reports \(actual)"
        }
    }
}

public final class AACWriter: @unchecked Sendable {
    public let url: URL
    public let channels: Int
    public private(set) var framesWritten = 0
    private let file: AVAudioFile
    private let format: AVAudioFormat

    public init(url: URL, channels: Int) throws {
        self.url = url
        self.channels = channels
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: Self.bitRate(channels: channels),
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true)!
    }

    public static func bitRate(channels: Int) -> Int { channels == 1 ? 96_000 : 256_000 }

    public func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw FinalizeError.buffer
        }
        buf.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: frames * channels) }
        try file.write(from: buf)
        framesWritten += frames
    }

    public func closeAndVerify() throws {
        file.close()
        let actual = Int(try AVAudioFile(forReading: url).length)
        guard actual == framesWritten else {
            throw FinalizeError.lengthMismatch(file: url.lastPathComponent, expected: framesWritten, actual: actual)
        }
    }
}
