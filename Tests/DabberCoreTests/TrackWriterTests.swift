import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func cafLength(_ url: URL) throws -> (frames: Int64, rate: Double, channels: Int) {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    return (f.length, f.processingFormat.sampleRate, Int(f.processingFormat.channelCount))
}

@Test func slotsBecomeOne48kMonoSegment() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    let t = tone(frames: 480, rate: 24_000)
    for i in 0..<10 {
        pushSlot(ring, samples: t, sampleTime: Double(i * 480), hostNanos: 1_000_000_000 + UInt64(i) * 20_000_000)
    }
    w.stop()
    let s = w.segments
    #expect(s.count == 1)
    #expect(s[0].frames == 9600)
    #expect(s[0].reason == "start")
    #expect(s[0].startNanos == 1_000_000_000)
    #expect(s[0].endNanos == 1_000_000_000 + 200_000_000)
    let info = try cafLength(dir.appendingPathComponent("mic - T.seg000.caf"))
    #expect(info.frames == 9600 && info.rate == 48_000 && info.channels == 1)
    #expect(w.meter.decibels > -20 && w.meter.decibels < 0)
}

@Test func sampleTimeJumpSplitsTheSegment() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    let t = tone(frames: 480, rate: 24_000)
    pushSlot(ring, samples: t, sampleTime: 0, hostNanos: 1_000_000_000)
    pushSlot(ring, samples: t, sampleTime: 480, hostNanos: 1_020_000_000)
    pushSlot(ring, samples: t, sampleTime: 100_000, hostNanos: 5_000_000_000)
    w.stop()
    let s = w.segments
    #expect(s.map(\.frames) == [1920, 960])
    #expect(s.map(\.reason) == ["start", "sample time jump"])
    #expect(s[1].startNanos == 5_000_000_000)
    #expect(s.map(\.file) == ["mic - T.seg000.caf", "mic - T.seg001.caf"])
}

@Test func formatMismatchClosesSegmentAndReports() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - T", channels: 1, ring: ring)
    let reported = Atomic<Int>(0)
    w.onFormatMismatch = { reported.wrappingAdd(1, ordering: .relaxed) }
    try w.openSegment(format: int16Mono(rate: 24_000), reason: "start")
    pushSlot(ring, samples: tone(frames: 480, rate: 24_000), sampleTime: 0, hostNanos: 1_000_000_000)
    pushSlot(ring, bytes: [1, 2, 3], sampleTime: 480, hostNanos: 1_020_000_000)
    pushSlot(ring, samples: tone(frames: 480, rate: 24_000), sampleTime: 483, hostNanos: 1_040_000_000)
    w.closeSegment()
    #expect(waitUntil { reported.load(ordering: .relaxed) == 1 })
    #expect(w.segments.map(\.frames) == [960])
    try w.openSegment(format: int16Mono(rate: 48_000), reason: "restart: test")
    pushSlot(ring, samples: tone(frames: 480, rate: 48_000), sampleTime: 0, hostNanos: 2_000_000_000)
    w.stop()
    #expect(w.segments.map(\.frames) == [960, 480])
    #expect(w.segments[1].sourceRate == 48_000)
}

@Test func stereoSourceIsAveragedIntoMonoTrack() throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 8, slotBytes: 4096)
    let w = TrackWriter(dir: dir, baseName: "mic - S", channels: 1, ring: ring)
    let f = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
        mReserved: 0)
    try w.openSegment(format: f, reason: "start")
    var bytes = [UInt8](repeating: 0, count: 8 * 100)
    let samples = [Float](repeating: 0, count: 200).enumerated().map { $0.offset % 2 == 0 ? Float(0.5) : Float(-0.25) }
    bytes.withUnsafeMutableBytes { raw in samples.withUnsafeBytes { raw.copyMemory(from: $0) } }
    pushSlot(ring, bytes: bytes, sampleTime: 0, hostNanos: 1_000_000_000)
    w.stop()
    let file = try AVAudioFile(forReading: dir.appendingPathComponent("mic - S.seg000.caf"), commonFormat: .pcmFormatFloat32, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
    try file.read(into: buf)
    #expect(buf.frameLength == 100)
    #expect(abs(buf.floatChannelData![0][50] - 0.125) < 0.001)
}

@Test(arguments: [(24_000.0, 1), (44_100.0, 2)])
func nonFiniteSamplesBecomeSilenceInsteadOfClicks(rate: Double, sourceChannels: Int) throws {
    let dir = try tempDir()
    let ring = RingBuffer(slotCount: 64, slotBytes: 8192)
    let w = TrackWriter(dir: dir, baseName: "mic - N", channels: 1, ring: ring)
    let bytesPerFrame = UInt32(4 * sourceChannels)
    try w.openSegment(
        format: AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(sourceChannels),
            mBitsPerChannel: 32, mReserved: 0),
        reason: "start")
    let frames = 480
    for slot in 0..<10 {
        var samples = (0..<(frames * sourceChannels)).map { i in
            Float(0.3 * sin(Double(slot * frames + i / sourceChannels) / rate * 2 * .pi * 440))
        }
        if slot == 5 {
            samples[100] = .nan
            samples[200] = .infinity
            samples[300] = -.infinity
        }
        let bytes = samples.withUnsafeBytes { [UInt8]($0) }
        pushSlot(
            ring, bytes: bytes, sampleTime: Double(slot * frames), hostNanos: 1_000_000_000 + UInt64(slot) * 10_000_000)
    }
    w.stop()
    let file = try AVAudioFile(
        forReading: dir.appendingPathComponent("mic - N.seg000.caf"), commonFormat: .pcmFormatFloat32, interleaved: true)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let out = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    let finite = out.allSatisfy(\.isFinite)
    let peak = out.map(abs).max() ?? 0
    #expect(out.count > 0)
    #expect(finite)
    #expect(peak <= 0.35)
}
