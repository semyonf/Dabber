import AVFoundation
import CoreMedia
import DabberCore

/// One audio stream of the broadcast written as Dabber's segments: 48 kHz 32-bit float CAF files
/// (`<base>.seg000.caf`, …) with their start time on the host clock. ReplayKit's buffers come in whatever format the
/// stream has (app audio is often 44.1 kHz 16-bit big-endian, the microphone 48 kHz float) and stop while nothing
/// plays. A new segment starts at every gap or format change, so the timeline places each piece where it belongs.
final class AudioTrack {
    /// A buffer this much earlier or later than where the previous one ended starts a new segment.
    static let gapNanos: Int64 = 20_000_000
    static let rate = 48_000.0

    let base: String
    let channels: Int
    private let dir: URL
    private let output: AVAudioFormat
    private(set) var records: [SegmentRecord] = []
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?
    private var written = 0
    private var expected: UInt64?

    init(dir: URL, base: String, channels: Int) {
        self.dir = dir
        self.base = base
        self.channels = channels
        output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: AVAudioChannelCount(channels), interleaved: true)!
    }

    static func nanos(_ time: CMTime) -> UInt64? {
        guard time.isValid, time.seconds > 0 else { return nil }
        return UInt64(CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
    }

    func append(_ buffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0
        else { return }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, let samples = Self.decode(buffer, asbd, frames: frames, channels: channels) else { return }
        let start = Self.nanos(CMSampleBufferGetPresentationTimeStamp(buffer)) ?? expected ?? HostClock.nowNanos()
        let jumped = expected.map { abs(Int64(bitPattern: start &- $0)) > Self.gapNanos } ?? true
        if file == nil || jumped || input?.sampleRate != asbd.mSampleRate {
            let reason = file == nil && records.isEmpty ? "start" : jumped ? "gap" : "format"
            close()
            open(start: start, rate: asbd.mSampleRate, sourceChannels: Int(asbd.mChannelsPerFrame), reason: reason)
        }
        write(samples, frames: frames)
        expected = start + UInt64(Double(frames) / asbd.mSampleRate * 1e9)
    }

    /// Ends the open segment: writes out what the resampler still holds and records the length and end.
    func close() {
        if let converter, let file { drain(converter, into: file, endOfStream: true) }
        file = nil
        converter = nil
        if !records.isEmpty, records[records.count - 1].endNanos == nil {
            records[records.count - 1].frames = written
            records[records.count - 1].endNanos = expected
        }
    }

    private func open(start: UInt64, rate: Double, sourceChannels: Int, reason: String) {
        let name = "\(base).seg\(String(format: "%03d", records.count)).caf"
        let url = dir.appendingPathComponent(name)
        guard let opened = try? AVAudioFile(
            forWriting: url, settings: output.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        else { return }
        file = opened
        written = 0
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: true)!
        input = source
        converter = rate == Self.rate ? nil : AVAudioConverter(from: source, to: output)
        records.append(SegmentRecord(
            file: name, startNanos: start, frames: 0, endNanos: nil, sourceRate: rate, sourceChannels: sourceChannels,
            reason: reason))
    }

    private func write(_ samples: [Float], frames: Int) {
        guard let file, let input,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else {
            try? file.write(from: buffer)
            written += frames
            return
        }
        pending = buffer
        drain(converter, into: file, endOfStream: false)
    }

    private var pending: AVAudioPCMBuffer?

    /// Converts what is pending (and, at the end, what the converter still holds) and writes it.
    private func drain(_ converter: AVAudioConverter, into file: AVAudioFile, endOfStream: Bool) {
        let capacity = AVAudioFrameCount(Double(pending?.frameLength ?? 0) * Self.rate / converter.inputFormat.sampleRate) + 1_024
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if let next = self.pending {
                    self.pending = nil
                    state.pointee = .haveData
                    return next
                }
                state.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0 {
                try? file.write(from: out)
                written += Int(out.frameLength)
            }
            if status != .haveData || out.frameLength == 0 { return }
        }
    }

    /// The samples of a buffer as interleaved floats with `channels` channels: averaged down to mono, or the first
    /// two (a mono stream copied to both) for stereo. Handles float and 16/32-bit integers of either byte order,
    /// interleaved or not.
    static func decode(_ buffer: CMSampleBuffer, _ asbd: AudioStreamBasicDescription, frames: Int, channels: Int) -> [Float]? {
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)
        let sourceChannels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard (float && bits == 32) || (!float && (bits == 16 || bits == 32)) else { return nil }

        /// Sample `i` of channel `c`.
        func sample(_ c: Int, _ i: Int) -> Float {
            let index = interleaved ? i * sourceChannels + c : i
            let b = interleaved ? 0 : min(c, buffers.count - 1)
            guard b < buffers.count, let data = buffers[b].mData,
                  (index + 1) * bits / 8 <= Int(buffers[b].mDataByteSize)
            else { return 0 }
            if float {
                let v = data.assumingMemoryBound(to: UInt32.self)[index]
                return Float(bitPattern: bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
            }
            if bits == 16 {
                let v = data.assumingMemoryBound(to: Int16.self)[index]
                return Float(bigEndian ? Int16(bigEndian: v) : Int16(littleEndian: v)) / 32_768
            }
            let v = data.assumingMemoryBound(to: Int32.self)[index]
            return Float(bigEndian ? Int32(bigEndian: v) : Int32(littleEndian: v)) / 2_147_483_648
        }

        var out = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            if channels == 1 {
                var sum: Float = 0
                for c in 0..<sourceChannels { sum += sample(c, i) }
                out[i] = sum / Float(sourceChannels)
            } else {
                for c in 0..<channels { out[i * channels + c] = sample(min(c, sourceChannels - 1), i) }
            }
        }
        return out
    }
}
