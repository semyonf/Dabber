import CoreAudio
import Testing
@testable import DabberCore

private func play(_ player: TonePlayer, frames: Int, sampleTime: Double, hostNanos: UInt64) -> [Float] {
    var samples = [Float](repeating: 9, count: frames * 2)
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mHostTime = AudioConvertNanosToHostTime(hostNanos)
        ts.mFlags = [.sampleTimeValid, .hostTimeValid]
        withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in player.render(l, t) } }
    }
    return samples
}

private func makePlayer() -> TonePlayer {
    TonePlayer(tone: ToneGenerator(frequency: 440, amplitude: 0.25), startNanos: 1_000_000_000)
}

@Test func playerIsSilentBeforeStart() {
    let player = makePlayer()
    let out = play(player, frames: 512, sampleTime: 0, hostNanos: 500_000_000)
    #expect(out.allSatisfy { $0 == 0 })
    #expect(player.toneStartNanos == 0)
}

@Test func toneBeginsWithTheFirstBufferAtOrAfterStart() {
    let player = makePlayer()
    _ = play(player, frames: 512, sampleTime: 0, hostNanos: 990_000_000)
    let out = play(player, frames: 512, sampleTime: 512, hostNanos: 1_000_666_000)
    #expect(out[0] == 0 && out[1] == 0)
    #expect(out.contains { $0 != 0 })
    #expect(player.toneStartNanos > 1_000_665_000 && player.toneStartNanos < 1_000_667_000)
}

@Test func sampleTimeJumpCountsADiscontinuity() {
    let player = makePlayer()
    _ = play(player, frames: 512, sampleTime: 0, hostNanos: 0)
    _ = play(player, frames: 512, sampleTime: 512, hostNanos: 0)
    #expect(player.discontinuities == 0)
    _ = play(player, frames: 512, sampleTime: 2048, hostNanos: 0)
    #expect(player.discontinuities == 1)
    #expect(player.framesRendered == 1536)
}

@Test func unexpectedBufferLayoutIsZeroedAndCounted() {
    let player = makePlayer()
    var samples = [Float](repeating: 9, count: 8)
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in player.render(l, t) } }
    }
    #expect(samples.allSatisfy { $0 == 0 })
    #expect(player.unexpectedLayouts == 1)
}
