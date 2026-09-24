import Testing
@testable import DabberCore

@Test func readerZeroFillsGapsAndHonoursSkip() throws {
    let a = MemorySegment(samples: [1, 2, 3, 4], channels: 1)
    let b = MemorySegment(samples: [5, 6, 7], channels: 1)
    let placements = [
        Placement(segmentIndex: 0, destFrame: 1, skipFrames: 0, frames: 4),
        Placement(segmentIndex: 1, destFrame: 7, skipFrames: 1, frames: 2),
    ]
    let r = TimelineReader(placements: placements, sources: [a, b], channels: 1)
    #expect(r.totalFrames == 9)
    #expect(try r.read(0..<9) == [0, 1, 2, 3, 4, 0, 0, 6, 7])
    #expect(try r.read(3..<8) == [3, 4, 0, 0, 6])
    #expect(try r.read(9..<12) == [0, 0, 0])
}

@Test func readerHandlesInterleavedStereo() throws {
    let a = MemorySegment(samples: [1, -1, 2, -2], channels: 2)
    let r = TimelineReader(placements: [Placement(segmentIndex: 0, destFrame: 1, skipFrames: 1, frames: 1)], sources: [a], channels: 2)
    #expect(try r.read(0..<3) == [0, 0, 2, -2, 0, 0])
}

@Test func resamplerKeepsConstantsAndInterpolatesRamps() throws {
    let constant = DriftResampler(MemorySegment(samples: [Float](repeating: 0.5, count: 100), channels: 1), targetFrames: 90)
    #expect(constant.frames == 90)
    #expect(try constant.read(0..<90).allSatisfy { abs($0 - 0.5) < 1e-6 })
    let ramp = DriftResampler(MemorySegment(samples: (0..<10).map(Float.init), channels: 1), targetFrames: 20)
    let out = try ramp.read(0..<20)
    #expect(abs(out[2] - 1.0) < 1e-6)
    #expect(abs(out[3] - 1.5) < 1e-6)
    #expect(out.count == 20)
    #expect(try ramp.read(18..<20).count == 2)
}

@Test func gapsAreListedFromZero() {
    let p = [
        Placement(segmentIndex: 0, destFrame: 10, skipFrames: 0, frames: 5),
        Placement(segmentIndex: 1, destFrame: 15, skipFrames: 0, frames: 5),
        Placement(segmentIndex: 2, destFrame: 30, skipFrames: 0, frames: 1),
    ]
    #expect(Timeline.gaps(p) == [Gap(atFrame: 0, frames: 10), Gap(atFrame: 20, frames: 10)])
    #expect(Timeline.gaps([]).isEmpty)
}

@Test func planResamplesOnlyAboveFiftyMilliseconds() {
    let hour: UInt64 = 3_600_000_000_000
    let records = [
        SegmentRecord(file: "a", startNanos: 1, frames: 0, endNanos: 1 + hour, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "b", startNanos: 1, frames: 0, endNanos: 1 + hour, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "c", startNanos: 1, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
        SegmentRecord(file: "d", startNanos: 0, frames: 0, endNanos: nil, sourceRate: 48_000, sourceChannels: 1, reason: "start"),
    ]
    let plans = FinalizePlan.make(records, fileFrames: [48_000 * 3600 + 4_800, 48_000 * 3600 + 2_000, 100, 100])
    #expect(plans.map(\.file) == ["a", "b", "c"])
    #expect(plans[0].resample && plans[0].segment.frames == 48_000 * 3600)
    #expect(!plans[1].resample && plans[1].segment.frames == 48_000 * 3600 + 2_000)
    #expect(!plans[2].resample && plans[2].segment.frames == 100)
    #expect(abs(plans[0].driftMillis - 100) < 0.01)
}
