import Testing
@testable import DabberCore

@Test func frameRateIs48k() {
    #expect(Timeline.rate == 48_000)
}

@Test func firstSegmentStartsAtItsOffset() {
    let s = [Segment(startNanos: 1_000_000_000 + 500_000_000, frames: 48_000)]
    #expect(Timeline.place(s, sessionStartNanos: 1_000_000_000) ==
            [Placement(segmentIndex: 0, destFrame: 24_000, skipFrames: 0, frames: 48_000)])
}

@Test func gapBetweenSegmentsIsKept() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 2_000_000_000, frames: 4_800),
    ]
    let p = Timeline.place(s, sessionStartNanos: 0)
    #expect(p[1] == Placement(segmentIndex: 1, destFrame: 96_000, skipFrames: 0, frames: 4_800))
}

@Test func overlappingHeadIsSkipped() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 900_000_000, frames: 9_600),
    ]
    let p = Timeline.place(s, sessionStartNanos: 0)
    #expect(p[1] == Placement(segmentIndex: 1, destFrame: 48_000, skipFrames: 4_800, frames: 4_800))
}

@Test func fullyOverlappedSegmentIsDropped() {
    let s = [
        Segment(startNanos: 0, frames: 48_000),
        Segment(startNanos: 100_000_000, frames: 480),
    ]
    #expect(Timeline.place(s, sessionStartNanos: 0).count == 1)
}

@Test func segmentBeforeSessionStartIsTrimmed() {
    let s = [Segment(startNanos: 0, frames: 48_000)]
    #expect(Timeline.place(s, sessionStartNanos: 500_000_000) ==
            [Placement(segmentIndex: 0, destFrame: 0, skipFrames: 24_000, frames: 24_000)])
}

@Test func driftIsMeasuredAgainstHostTime() {
    let s = Segment(startNanos: 0, frames: 48_000 * 3600 + 4_800, endNanos: 3_600_000_000_000)
    #expect(abs(Timeline.driftMillis(s) - 100) < 0.01)
}

@Test func driftWithoutEndIsZero() {
    #expect(Timeline.driftMillis(Segment(startNanos: 0, frames: 48_000)) == 0)
}

@Test func fewerFramesThanHostTimeIsNegativeDrift() {
    let s = Segment(startNanos: 0, frames: 48_000 * 3600 - 4_800, endNanos: 3_600_000_000_000)
    #expect(abs(Timeline.driftMillis(s) + 100) < 0.01)
}
