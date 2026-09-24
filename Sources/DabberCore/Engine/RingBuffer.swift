import CoreAudio
import Synchronization

public struct SlotHeader: Sendable, Equatable {
    public var hostTime: UInt64
    public var sampleTime: Double
    public var bufferCount: Int
    public var bytesPerBuffer: Int

    public init(hostTime: UInt64, sampleTime: Double, bufferCount: Int, bytesPerBuffer: Int) {
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.bufferCount = bufferCount
        self.bytesPerBuffer = bytesPerBuffer
    }
}

public final class RingBuffer: @unchecked Sendable {
    public let slotCount: Int
    public let slotBytes: Int
    private let data: UnsafeMutableRawPointer
    private let headers: UnsafeMutablePointer<SlotHeader>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    public init(slotCount: Int, slotBytes: Int) {
        self.slotCount = slotCount
        self.slotBytes = slotBytes
        data = .allocate(byteCount: slotCount * slotBytes, alignment: 16)
        headers = .allocate(capacity: slotCount)
        headers.initialize(
            repeating: SlotHeader(hostTime: 0, sampleTime: 0, bufferCount: 0, bytesPerBuffer: 0), count: slotCount)
    }

    deinit {
        data.deallocate()
        headers.deallocate()
    }

    public var overruns: Int { dropped.load(ordering: .relaxed) }

    public func push(_ list: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = buffers.count
        let bytes = count > 0 ? Int(buffers[0].mDataByteSize) : 0
        guard h - t < slotCount, bytes > 0, count * bytes <= slotBytes else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let slot = data + (h % slotCount) * slotBytes
        for i in 0..<count {
            guard let src = buffers[i].mData, Int(buffers[i].mDataByteSize) == bytes else {
                dropped.wrappingAdd(1, ordering: .relaxed)
                return
            }
            (slot + i * bytes).copyMemory(from: src, byteCount: bytes)
        }
        headers[h % slotCount] = SlotHeader(
            hostTime: time.pointee.mHostTime, sampleTime: time.pointee.mSampleTime,
            bufferCount: count, bytesPerBuffer: bytes)
        head.store(h + 1, ordering: .releasing)
    }

    public func pop(_ body: (SlotHeader, UnsafeRawPointer) -> Void) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t < h else { return false }
        body(headers[t % slotCount], UnsafeRawPointer(data + (t % slotCount) * slotBytes))
        tail.store(t + 1, ordering: .releasing)
        return true
    }
}
