import CoreAudio
import Testing
@testable import DabberCore

private func withList(
    _ buffers: [(channels: Int, samples: [Float])], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void
) {
    let list = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))
    defer { free(list.unsafeMutablePointer) }
    list.count = buffers.count
    var storage: [UnsafeMutablePointer<Float>] = []
    for (i, b) in buffers.enumerated() {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, b.samples.count))
        p.initialize(from: b.samples, count: b.samples.count)
        storage.append(p)
        list[i] = AudioBuffer(
            mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(b.samples.count * 4), mData: p)
    }
    body(list.unsafeMutablePointer)
    for p in storage { p.deallocate() }
}

private func render(
    _ renderer: FeedRenderer, inputs: [(channels: Int, samples: [Float])], frames: Int, sampleTime: Double = 0
) -> [Float] {
    var out = [Float](repeating: 9, count: frames * 2)
    withList(inputs) { input in
        out.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in renderer.render(input, l, t) } }
        }
    }
    return out
}

@Test func rendererMixesMicAndTapIntoTheFeed() {
    let r = FeedRenderer()
    let out = render(r, inputs: [(1, [0.5, 0.25]), (2, [0.1, 0.2, 0.3, 0.4])], frames: 2)
    #expect(out == Mixer.mixToStereo(mono: [[0.5, 0.25]], stereo: [[0.1, 0.2, 0.3, 0.4]]))
    #expect(r.meter.decibels > -20)
    #expect(r.cycles == 1)
}

@Test func rendererWithNoInputsWritesSilence() {
    let r = FeedRenderer()
    #expect(render(r, inputs: [], frames: 4).allSatisfy { $0 == 0 })
    #expect(r.meter.decibels == -160)
}

@Test func inputOfTheWrongSizeIsSkippedAndCounted() {
    let r = FeedRenderer()
    let out = render(r, inputs: [(1, [0.5]), (2, [0.1, 0.2, 0.3, 0.4])], frames: 2)
    #expect(out == [0.1, 0.2, 0.3, 0.4])
    #expect(r.skippedInputs == 1)
}

@Test func outputSampleTimeJumpIsCounted() {
    let r = FeedRenderer()
    _ = render(r, inputs: [], frames: 4, sampleTime: 0)
    _ = render(r, inputs: [], frames: 4, sampleTime: 4)
    _ = render(r, inputs: [], frames: 4, sampleTime: 100)
    #expect(r.discontinuities == 1)
    #expect(r.framesRendered == 12)
}

@Test func levelMeterRoundTripsTheLevel() {
    let meter = LevelMeter()
    #expect(meter.decibels == -160)
    let half = [Float](repeating: 0.5, count: 64)
    half.withUnsafeBufferPointer { meter.update($0.baseAddress!, count: $0.count) }
    #expect(abs(meter.decibels - 20 * log10(0.5)) < 0.001)
    let zero = [Float](repeating: 0, count: 64)
    zero.withUnsafeBufferPointer { meter.update($0.baseAddress!, count: $0.count) }
    #expect(meter.decibels == -160)
}

@Test func rendererCountersAndMeterSurviveConcurrentReads() async {
    let r = FeedRenderer()
    let writer = Task.detached {
        for i in 0..<20_000 { _ = render(r, inputs: [(1, [0.5, 0.5])], frames: 2, sampleTime: Double(i * 2)) }
    }
    var seen: [Double] = []
    while seen.count < 20_000 {
        seen.append(r.meter.decibels)
        #expect(r.cycles >= 0 && r.framesRendered >= 0 && r.discontinuities >= 0 && r.skippedInputs >= 0)
    }
    await writer.value
    #expect(seen.allSatisfy { $0 == -160 || abs($0 - 20 * log10(0.5)) < 0.01 })
    #expect(r.cycles == 20_000)
    #expect(r.framesRendered == 40_000)
    #expect(r.discontinuities == 0)
}
