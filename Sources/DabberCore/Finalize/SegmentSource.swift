public protocol SegmentSource {
    var frames: Int { get }
    var channels: Int { get }
    func read(_ range: Range<Int>) throws -> [Float]
    func close()
}

extension SegmentSource {
    public func close() {}
}

public struct MemorySegment: SegmentSource {
    public let samples: [Float]
    public let channels: Int

    public init(samples: [Float], channels: Int) {
        self.samples = samples
        self.channels = channels
    }

    public var frames: Int { samples.count / channels }

    public func read(_ range: Range<Int>) -> [Float] {
        Array(samples[(range.lowerBound * channels)..<(range.upperBound * channels)])
    }
}

public struct DriftResampler: SegmentSource {
    private let inner: any SegmentSource
    public let frames: Int

    public init(_ inner: any SegmentSource, targetFrames: Int) {
        self.inner = inner
        frames = targetFrames
    }

    public var channels: Int { inner.channels }

    public func close() { inner.close() }

    public func read(_ range: Range<Int>) throws -> [Float] {
        guard !range.isEmpty else { return [] }
        let ratio = Double(inner.frames) / Double(frames)
        let from = Int(Double(range.lowerBound) * ratio)
        let to = min(inner.frames, Int(Double(range.upperBound - 1) * ratio) + 2)
        let src = try inner.read(from..<to)
        let ch = channels
        let last = (to - from) - 1
        var out = [Float](repeating: 0, count: range.count * ch)
        for (i, frame) in range.enumerated() {
            let pos = Double(frame) * ratio
            let k = Int(pos)
            let frac = Float(pos - Double(k))
            let a = min(k - from, last)
            let b = min(a + 1, last)
            for c in 0..<ch {
                out[i * ch + c] = src[a * ch + c] * (1 - frac) + src[b * ch + c] * frac
            }
        }
        return out
    }
}
