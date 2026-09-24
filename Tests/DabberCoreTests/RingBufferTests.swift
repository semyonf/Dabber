import Testing
@testable import DabberCore

@Test func pushedBytesComeBackInOrder() {
    let ring = RingBuffer(slotCount: 4, slotBytes: 16)
    pushSlot(ring, bytes: [1, 2, 3], sampleTime: 0, hostNanos: 10)
    pushSlot(ring, bytes: [4, 5], sampleTime: 3, hostNanos: 20)
    var seen: [(SlotHeader, [UInt8])] = []
    while ring.pop({ h, p in seen.append((h, Array(UnsafeRawBufferPointer(start: p, count: h.bytesPerBuffer)))) }) {}
    #expect(seen.map(\.1) == [[1, 2, 3], [4, 5]])
    #expect(seen.map(\.0.sampleTime) == [0, 3])
    #expect(seen[0].0.bufferCount == 1)
    #expect(ring.overruns == 0)
}

@Test func fullRingDropsAndCountsOverrun() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 16)
    for i in 0..<3 { pushSlot(ring, bytes: [UInt8(i)], sampleTime: Double(i), hostNanos: 0) }
    #expect(ring.overruns == 1)
    var count = 0
    while ring.pop({ _, _ in count += 1 }) {}
    #expect(count == 2)
}

@Test func oversizedBufferIsDropped() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 4)
    pushSlot(ring, bytes: [1, 2, 3, 4, 5], sampleTime: 0, hostNanos: 0)
    #expect(ring.overruns == 1)
    #expect(ring.pop({ _, _ in }) == false)
}

@Test func popOnEmptyRingReturnsFalse() {
    #expect(RingBuffer(slotCount: 1, slotBytes: 1).pop({ _, _ in }) == false)
}

@Test func slotsAreReusedAfterPop() {
    let ring = RingBuffer(slotCount: 2, slotBytes: 8)
    for i in 0..<10 {
        pushSlot(ring, bytes: [UInt8(i)], sampleTime: Double(i), hostNanos: 0)
        var got: UInt8 = 255
        #expect(ring.pop({ _, p in got = p.load(as: UInt8.self) }))
        #expect(got == UInt8(i))
    }
    #expect(ring.overruns == 0)
}
