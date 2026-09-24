public struct TimelineReader {
    public let placements: [Placement]
    public let sources: [any SegmentSource]
    public let channels: Int

    public init(placements: [Placement], sources: [any SegmentSource], channels: Int) {
        self.placements = placements
        self.sources = sources
        self.channels = channels
    }

    public var totalFrames: Int { placements.map { $0.destFrame + $0.frames }.max() ?? 0 }

    public func read(_ range: Range<Int>) throws -> [Float] {
        var out = [Float](repeating: 0, count: range.count * channels)
        for p in placements {
            let lo = max(range.lowerBound, p.destFrame)
            let hi = min(range.upperBound, p.destFrame + p.frames)
            guard lo < hi else { continue }
            let start = p.skipFrames + (lo - p.destFrame)
            let data = try sources[p.segmentIndex].read(start..<(start + hi - lo))
            let offset = (lo - range.lowerBound) * channels
            for i in 0..<data.count { out[offset + i] = data[i] }
            if hi == p.destFrame + p.frames { sources[p.segmentIndex].close() }
        }
        return out
    }
}
