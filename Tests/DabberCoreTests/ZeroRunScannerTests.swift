import Testing
@testable import DabberCore

private func scan(_ chunks: [[Float]], channels: Int = 1, minFrames: Int = 3) -> ZeroRunScanner {
    var s = ZeroRunScanner(minFrames: minFrames)
    for chunk in chunks { chunk.withUnsafeBufferPointer { s.scan($0, channels: channels) } }
    s.finish()
    return s
}

@Test func leadingSilenceIsNotARun() {
    let s = scan([[0, 0, 0, 0, 0.5, 0.5]])
    #expect(s.firstSignalFrame == 4)
    #expect(s.runCount == 0)
}

@Test func zeroRunAfterSignalIsCountedAcrossChunks() {
    let s = scan([[0.5, 0, 0], [0, 0, 0.5]])
    #expect(s.runs == [ZeroRunScanner.Run(startFrame: 1, frames: 4)])
    #expect(s.longest == 4)
}

@Test func shortZeroRunsAreIgnored() {
    #expect(scan([[0.5, 0, 0, 0.5]]).runCount == 0)
}

@Test func trailingRunIsClosedByFinish() {
    let s = scan([[0.5, 0, 0, 0]])
    #expect(s.runs == [ZeroRunScanner.Run(startFrame: 1, frames: 3)])
}

@Test func aFrameIsZeroOnlyWhenEveryChannelIsZero() {
    let s = scan([[0.5, 0.5, 0, 0.1, 0, 0.1, 0, 0.1]], channels: 2)
    #expect(s.runCount == 0)
    #expect(s.framesScanned == 4)
}

@Test func onlyTheFirstRunsAreKeptButAllAreCounted() {
    var chunk: [Float] = []
    for _ in 0..<40 { chunk += [0.5, 0, 0, 0] }
    let s = scan([chunk])
    #expect(s.runCount == 40)
    #expect(s.runs.count == ZeroRunScanner.keptRuns)
}
