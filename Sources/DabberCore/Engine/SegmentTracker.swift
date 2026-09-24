public enum Boundary: Equatable, Sendable {
    case continues
    case gap(frames: Double)
    case formatMismatch
}

public struct SegmentTracker: Sendable {
    public let bytesPerFrame: Int
    public let bufferCount: Int
    private var nextSampleTime: Double?

    public init(bytesPerFrame: Int, bufferCount: Int) {
        self.bytesPerFrame = bytesPerFrame
        self.bufferCount = bufferCount
    }

    public func frames(in header: SlotHeader) -> Int { header.bytesPerBuffer / bytesPerFrame }

    public mutating func classify(_ header: SlotHeader) -> Boundary {
        guard header.bufferCount == bufferCount, header.bytesPerBuffer > 0,
              header.bytesPerBuffer % bytesPerFrame == 0
        else { return .formatMismatch }
        let expected = nextSampleTime
        nextSampleTime = header.sampleTime + Double(frames(in: header))
        guard let expected else { return .continues }
        let jump = header.sampleTime - expected
        return abs(jump) <= 1 ? .continues : .gap(frames: jump)
    }
}
