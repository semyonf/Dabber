public struct Segment: Equatable, Sendable, Codable {
    public let startNanos: UInt64
    public var frames: Int
    public var endNanos: UInt64?

    public init(startNanos: UInt64, frames: Int, endNanos: UInt64? = nil) {
        self.startNanos = startNanos
        self.frames = frames
        self.endNanos = endNanos
    }
}

public struct Placement: Equatable, Sendable {
    public let segmentIndex: Int
    public let destFrame: Int
    public let skipFrames: Int
    public let frames: Int
}

public struct Gap: Equatable, Sendable {
    public let atFrame: Int
    public let frames: Int

    public init(atFrame: Int, frames: Int) {
        self.atFrame = atFrame
        self.frames = frames
    }
}

public enum Timeline {
    public static let rate = 48_000

    public static func frames(nanos: Int64) -> Int {
        Int((Double(nanos) * Double(rate) / 1e9).rounded())
    }

    public static func place(_ segments: [Segment], sessionStartNanos: UInt64) -> [Placement] {
        var result: [Placement] = []
        var cursor = 0
        for (i, s) in segments.enumerated() {
            let offset = frames(nanos: Int64(s.startNanos) - Int64(sessionStartNanos))
            let dest = max(offset, cursor)
            let skip = dest - offset
            let count = s.frames - skip
            guard count > 0 else { continue }
            result.append(Placement(segmentIndex: i, destFrame: dest, skipFrames: skip, frames: count))
            cursor = dest + count
        }
        return result
    }

    public static func driftMillis(_ s: Segment) -> Double {
        guard let end = s.endNanos, end > s.startNanos else { return 0 }
        let expected = Double(end - s.startNanos) * Double(rate) / 1e9
        return (Double(s.frames) - expected) / Double(rate) * 1000
    }

    public static func gaps(_ placements: [Placement]) -> [Gap] {
        var result: [Gap] = []
        var cursor = 0
        for p in placements {
            if p.destFrame > cursor { result.append(Gap(atFrame: cursor, frames: p.destFrame - cursor)) }
            cursor = p.destFrame + p.frames
        }
        return result
    }
}
