import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import DabberCore

private enum SampleKind { case int16, float32 }

private func pcmFormat(ch: Int, kind: SampleKind, interleaved: Bool) -> AudioStreamBasicDescription {
    let bytes = kind == .int16 ? 2 : 4
    var flags: AudioFormatFlags = kind == .int16
        ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        : kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
    let bpf = interleaved ? bytes * ch : bytes
    return AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: UInt32(bpf), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bpf),
        mChannelsPerFrame: UInt32(ch), mBitsPerChannel: UInt32(bytes * 8), mReserved: 0)
}

private func noiseHash(_ i: Int) -> Int {
    var x = UInt64(truncatingIfNeeded: i) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 29
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 32
    return Int(x & 0xFFFF)
}

private struct Signal {
    let kind: SampleKind
    let offset: Int

    func raw(_ frame: Int, _ ch: Int) -> Float {
        let n = noiseHash((frame + offset) * 2 + ch) - 32_768
        return kind == .int16 ? Float(n / 4) : Float(n) / 262_144
    }

    func decoded(_ frame: Int, _ ch: Int) -> Float { kind == .int16 ? raw(frame, ch) / 32_768 : raw(frame, ch) }
}

private func pushFrames(
    _ ring: RingBuffer, ch: Int, interleaved: Bool, signal: Signal, start: Int, count: Int,
    sampleTime: Int, hostNanos: UInt64
) {
    let buffers = interleaved ? 1 : ch
    let perBuffer = interleaved ? ch : 1
    let sampleBytes = signal.kind == .int16 ? 2 : 4
    let byteCount = count * perBuffer * sampleBytes
    let list = AudioBufferList.allocate(maximumBuffers: buffers)
    defer { free(list.unsafeMutablePointer) }
    var storage: [UnsafeMutableRawPointer] = []
    defer { storage.forEach { $0.deallocate() } }
    for b in 0..<buffers {
        let p = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        storage.append(p)
        for f in 0..<count {
            for k in 0..<perBuffer {
                let idx = f * perBuffer + k
                let v = signal.raw(start + f, interleaved ? k : b)
                if signal.kind == .int16 {
                    p.storeBytes(of: Int16(v), toByteOffset: idx * 2, as: Int16.self)
                } else {
                    p.storeBytes(of: v, toByteOffset: idx * 4, as: Float.self)
                }
            }
        }
        list[b] = AudioBuffer(mNumberChannels: UInt32(perBuffer), mDataByteSize: UInt32(byteCount), mData: p)
    }
    var ts = AudioTimeStamp()
    ts.mSampleTime = Double(sampleTime)
    ts.mHostTime = AudioConvertNanosToHostTime(hostNanos)
    ts.mFlags = [.sampleTimeValid, .hostTimeValid]
    withUnsafePointer(to: &ts) { ring.push(UnsafePointer(list.unsafePointer), $0) }
}

private let slotSizes = [512, 479, 1024, 7, 333, 960]

private func pushRun(
    _ ring: RingBuffer, ch: Int, interleaved: Bool, signal: Signal, frames: Int, sampleTime: Int, hostNanos: UInt64
) {
    var pos = 0
    var i = 0
    while pos < frames {
        let n = min(slotSizes[i % slotSizes.count], frames - pos)
        pushFrames(
            ring, ch: ch, interleaved: interleaved, signal: signal, start: pos, count: n,
            sampleTime: sampleTime + pos, hostNanos: hostNanos + UInt64((Double(pos) / 48_000 * 1e9).rounded()))
        pos += n
        i += 1
    }
}

private func readCAF(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    let ch = Int(f.processingFormat.channelCount)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096)!
    var out: [Float] = []
    while f.framePosition < f.length {
        try f.read(into: buf, frameCount: 4096)
        out.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength) * ch))
    }
    return out
}

private func newDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func renderTimeline(_ dir: URL, _ records: [SegmentRecord], channels: Int, sessionStart: UInt64) throws -> [Float] {
    let files = try records.map { try CAFSegment(url: dir.appendingPathComponent($0.file)) }
    let plans = FinalizePlan.make(records, fileFrames: files.map(\.frames))
    let planned = Set(plans.map(\.file))
    let sources: [any SegmentSource] = zip(records, files).filter { planned.contains($0.0.file) }.map(\.1)
    let reader = TimelineReader(
        placements: Timeline.place(plans.map(\.segment), sessionStartNanos: sessionStart), sources: sources,
        channels: channels)
    var out: [Float] = []
    var start = 0
    while start < reader.totalFrames {
        let range = start..<min(start + Finalizer.chunkFrames, reader.totalFrames)
        out += try reader.read(range)
        start = range.upperBound
    }
    return out
}

private func destFrame(_ nanos: UInt64) -> Int { Int((Double(nanos) * 48_000 / 1e9).rounded()) }

@Test func crashMidSegmentIsRecoveredFromTheManifestOnDisk() throws {
    let dir = try newDir("crash")
    let s: UInt64 = 10_000_000_000
    let ring = RingBuffer(slotCount: 512, slotBytes: 32_768)
    let w = TrackWriter(dir: dir, baseName: "mic - A", channels: 1, ring: ring)
    let saved = Mutex<[SegmentRecord]>([])
    w.onSegmentsChanged = { records in saved.withLock { $0 = records } }
    try w.openSegment(format: pcmFormat(ch: 1, kind: .int16, interleaved: true), reason: "start")
    let signal = Signal(kind: .int16, offset: 0)
    let frames = 102_400
    pushRun(ring, ch: 1, interleaved: true, signal: signal, frames: frames, sampleTime: 0, hostNanos: s + 1_000_000)
    let caf = dir.appendingPathComponent(SessionNaming.segmentFile(base: "mic - A", index: 0))
    #expect(waitUntil {
        saved.withLock { $0.first?.startNanos ?? 0 } > 0 && (try? AVAudioFile(forReading: caf).length) == Int64(frames)
    })

    let crash = try newDir("crash-copy")
    let onDisk = saved.withLock { $0 }
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
        try FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: crash.appendingPathComponent(name))
    }
    w.stop()
    var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
    m.sources = [SourceManifest(
        kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: onDisk,
        restarts: [], overruns: 0)]
    try m.save(to: crash)
    #expect(Finalizer.needsRecovery(crash))

    let offset = destFrame(1_000_000)
    let pcm = try renderTimeline(crash, m.sources[0].segments, channels: 1, sessionStart: s)
    #expect(pcm.count == offset + frames)
    if pcm.count == offset + frames {
        #expect(pcm[0..<offset].allSatisfy { $0 == 0 })
        #expect(Array(pcm[offset...]) == (0..<frames).map { signal.decoded($0, 0) })
    }

    let report = try Finalizer.run(crash)
    #expect(report.totalFrames == offset + frames)
    #expect(try AVAudioFile(forReading: crash.appendingPathComponent("mic - A.m4a")).length == Int64(offset + frames))
}

@Test func cafsTheFinalizerDidNotRenderAreKept() throws {
    let dir = try newDir("keep")
    let s: UInt64 = 10_000_000_000
    let ring = RingBuffer(slotCount: 512, slotBytes: 32_768)
    let w = TrackWriter(dir: dir, baseName: "mic - A", channels: 1, ring: ring)
    try w.openSegment(format: pcmFormat(ch: 1, kind: .int16, interleaved: true), reason: "start")
    pushRun(
        ring, ch: 1, interleaved: true, signal: Signal(kind: .int16, offset: 0), frames: 48_000, sampleTime: 0,
        hostNanos: s)
    w.stop()
    let rendered = w.segments[0]
    let unstarted = SegmentRecord(
        file: "mic - A.seg002.caf", startNanos: 0, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1,
        reason: "restart")
    try FileManager.default.copyItem(
        at: dir.appendingPathComponent(rendered.file), to: dir.appendingPathComponent(unstarted.file))
    try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("stray.caf"))
    var m = SessionManifest(appVersion: "t", startedAt: Date(), sessionStartNanos: s)
    m.sources = [SourceManifest(
        kind: .mic, uid: "u", name: "A", file: "mic - A.m4a", channels: 1, segments: [rendered, unstarted],
        restarts: [], overruns: 0)]
    try m.save(to: dir)

    try Finalizer.run(dir)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["mic - A.m4a", "mic - A.seg002.caf", "mix.m4a", "session.json", "stray.caf"])
}

@Test(arguments: [
    (1, true, true), (1, false, true), (2, false, true), (2, false, false), (2, true, true),
])
func trackWriterStoresEvery48kFrameExactly(channels: Int, int16: Bool, interleaved: Bool) throws {
    let dir = try newDir("exact")
    let ring = RingBuffer(slotCount: 512, slotBytes: 32_768)
    let w = TrackWriter(dir: dir, baseName: "t", channels: channels, ring: ring)
    let kind: SampleKind = int16 ? .int16 : .float32
    try w.openSegment(format: pcmFormat(ch: channels, kind: kind, interleaved: interleaved), reason: "start")
    let signal = Signal(kind: kind, offset: 3)
    let frames = 30_011
    pushRun(
        ring, ch: channels, interleaved: interleaved, signal: signal, frames: frames, sampleTime: 0,
        hostNanos: 5_000_000_000)
    w.stop()
    #expect(ring.overruns == 0)
    let got = try readCAF(dir.appendingPathComponent(w.segments[0].file))
    #expect(got == (0..<frames).flatMap { f in (0..<channels).map { signal.decoded(f, $0) } })
}

@Test func timelineOfTwoTracksWithGapAndOddOffsetsIsSampleExact() throws {
    let dir = try newDir("e2e")
    let s: UInt64 = 10_000_123_457
    let micOffsets: [UInt64] = [12_345_678, 2_500_007_777]
    let micFrames = [70_001, 50_011]
    let micSignals = [Signal(kind: .int16, offset: 0), Signal(kind: .int16, offset: 500_000)]
    let micRing = RingBuffer(slotCount: 1024, slotBytes: 32_768)
    let mic = TrackWriter(dir: dir, baseName: "mic - A", channels: 1, ring: micRing)
    try mic.openSegment(format: pcmFormat(ch: 1, kind: .int16, interleaved: true), reason: "start")
    for i in 0..<2 {
        pushRun(
            micRing, ch: 1, interleaved: true, signal: micSignals[i], frames: micFrames[i],
            sampleTime: micSignals[i].offset, hostNanos: s + micOffsets[i])
    }
    mic.stop()
    let compOffset: UInt64 = 3_210_987
    let compFrames = 150_017
    let compSignal = Signal(kind: .float32, offset: 7)
    let compRing = RingBuffer(slotCount: 1024, slotBytes: 32_768)
    let comp = TrackWriter(dir: dir, baseName: "computer audio", channels: 2, ring: compRing)
    try comp.openSegment(format: pcmFormat(ch: 2, kind: .float32, interleaved: false), reason: "start")
    pushRun(
        compRing, ch: 2, interleaved: false, signal: compSignal, frames: compFrames, sampleTime: 0,
        hostNanos: s + compOffset)
    comp.stop()
    #expect(micRing.overruns == 0 && compRing.overruns == 0)
    #expect(mic.segments.map(\.frames) == micFrames)

    let total = destFrame(micOffsets[1]) + micFrames[1]
    var micWant = [Float](repeating: 0, count: total)
    for i in 0..<2 {
        for f in 0..<micFrames[i] { micWant[destFrame(micOffsets[i]) + f] = micSignals[i].decoded(f, 0) }
    }
    var compWant = [Float](repeating: 0, count: total * 2)
    for f in 0..<compFrames {
        for c in 0..<2 { compWant[(destFrame(compOffset) + f) * 2 + c] = compSignal.decoded(f, c) }
    }
    let micGot = try renderTimeline(dir, mic.segments, channels: 1, sessionStart: s)
    var compGot = try renderTimeline(dir, comp.segments, channels: 2, sessionStart: s)
    compGot += [Float](repeating: 0, count: max(0, total * 2 - compGot.count))
    #expect(micGot == micWant)
    #expect(compGot == compWant)
    let mixWant = (0..<(total * 2)).map { min(1, max(-1, 0.5 * micWant[$0 / 2] + 0.5 * compWant[$0])) }
    #expect(Mixer.mixToStereo(mono: [micGot], stereo: [compGot]) == mixWant)
}
