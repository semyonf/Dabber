import Testing
@testable import DabberCore

private func header(_ sampleTime: Double, bytes: Int, buffers: Int = 1) -> SlotHeader {
    SlotHeader(hostTime: 0, sampleTime: sampleTime, bufferCount: buffers, bytesPerBuffer: bytes)
}

@Test func contiguousSlotsContinue() {
    var t = SegmentTracker(bytesPerFrame: 2, bufferCount: 1)
    #expect(t.classify(header(0, bytes: 960)) == .continues)
    #expect(t.classify(header(480, bytes: 960)) == .continues)
    #expect(t.classify(header(960.5, bytes: 960)) == .continues)
}

@Test func sampleTimeJumpIsAGap() {
    var t = SegmentTracker(bytesPerFrame: 2, bufferCount: 1)
    _ = t.classify(header(0, bytes: 960))
    #expect(t.classify(header(1000, bytes: 960)) == .gap(frames: 520))
    #expect(t.classify(header(1480, bytes: 960)) == .continues)
}

@Test func byteSizeNotDivisibleByFrameIsAMismatch() {
    var t = SegmentTracker(bytesPerFrame: 4, bufferCount: 1)
    #expect(t.classify(header(0, bytes: 6)) == .formatMismatch)
}

@Test func bufferCountChangeIsAMismatch() {
    var t = SegmentTracker(bytesPerFrame: 4, bufferCount: 2)
    #expect(t.classify(header(0, bytes: 8, buffers: 1)) == .formatMismatch)
}

@Test func framesAreDerivedFromBytes() {
    let t = SegmentTracker(bytesPerFrame: 8, bufferCount: 1)
    #expect(t.frames(in: header(0, bytes: 4096)) == 512)
}
