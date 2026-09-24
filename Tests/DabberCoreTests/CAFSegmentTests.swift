import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import DabberCore

private func writeMonoCAF(_ url: URL, samples: [Float]) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
    var asbd = format.streamDescription.pointee
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create")
    var client = asbd
    try check(ExtAudioFileSetProperty(ref!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "client")
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try check(ExtAudioFileWrite(ref!, buf.frameLength, buf.audioBufferList), "write")
    ExtAudioFileDispose(ref!)
}

@Test func readsUnalignedRangeWithoutZeroFill() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("caf-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = (0..<(48_000 * 3)).map { i in Float(0.25 * sin(Double(i) / 48_000 * 2 * .pi * 440)) }
    try writeMonoCAF(url, samples: source)
    let range = 47_584..<95_584
    let data = try CAFSegment(url: url).read(range)
    #expect(data.count == range.count)
    let expected = Array(source[range])
    let zeroed = zip(data, expected).filter { $0 == 0 && abs($1) > 1e-3 }.count
    #expect(zeroed == 0)
    let maxError = zip(data, expected).map { abs($0 - $1) }.max() ?? 0
    #expect(maxError <= 1e-6)
}

@Test func padsRangePastEndWithZeros() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("caf-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = [Float](repeating: 0.5, count: 48_000)
    try writeMonoCAF(url, samples: source)
    let data = try CAFSegment(url: url).read(47_000..<49_000)
    #expect(data == [Float](repeating: 0.5, count: 1_000) + [Float](repeating: 0, count: 1_000))
}
