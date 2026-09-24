public struct ZeroRunScanner: Sendable {
    public struct Run: Sendable, Equatable {
        public let startFrame: Int
        public let frames: Int
    }

    public static let keptRuns = 32
    public let minFrames: Int
    public private(set) var framesScanned = 0
    public private(set) var firstSignalFrame: Int?
    public private(set) var runCount = 0
    public private(set) var longest = 0
    public private(set) var runs: [Run] = []
    private var runStart: Int?

    public init(minFrames: Int) {
        self.minFrames = minFrames
        runs.reserveCapacity(Self.keptRuns)
    }

    public mutating func scan(_ samples: UnsafeBufferPointer<Float>, channels: Int) {
        let frames = samples.count / channels
        for f in 0..<frames {
            var zero = true
            for c in 0..<channels where samples[f * channels + c] != 0 {
                zero = false
                break
            }
            let index = framesScanned + f
            if !zero {
                if firstSignalFrame == nil { firstSignalFrame = index }
                close(at: index)
            } else if firstSignalFrame != nil, runStart == nil {
                runStart = index
            }
        }
        framesScanned += frames
    }

    public mutating func finish() { close(at: framesScanned) }

    private mutating func close(at index: Int) {
        guard let start = runStart else { return }
        runStart = nil
        let frames = index - start
        guard frames >= minFrames else { return }
        runCount += 1
        longest = max(longest, frames)
        if runs.count < Self.keptRuns { runs.append(Run(startFrame: start, frames: frames)) }
    }
}
