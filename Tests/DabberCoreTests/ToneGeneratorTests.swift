import Testing
@testable import DabberCore

private func render(_ tone: inout ToneGenerator, frames: Int, channels: Int) -> [Float] {
    var out = [Float](repeating: 9, count: frames * channels)
    out.withUnsafeMutableBufferPointer { tone.fill($0, channels: channels) }
    return out
}

@Test func toneStartsAtZero() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    #expect(render(&tone, frames: 1, channels: 1) == [0])
}

@Test func toneIsContinuousAcrossCalls() {
    var whole = ToneGenerator(frequency: 440, amplitude: 0.25)
    var split = ToneGenerator(frequency: 440, amplitude: 0.25)
    let a = render(&whole, frames: 480, channels: 1)
    let b = render(&split, frames: 100, channels: 1) + render(&split, frames: 380, channels: 1)
    #expect(a == b)
}

@Test func everyChannelGetsTheSameSample() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    let out = render(&tone, frames: 64, channels: 2)
    #expect(stride(from: 0, to: out.count, by: 2).allSatisfy { out[$0] == out[$0 + 1] })
}

@Test func tonePeakIsTheAmplitude() {
    var tone = ToneGenerator(frequency: 1000, amplitude: 0.25)
    let peak = render(&tone, frames: 48_000, channels: 1).map(abs).max() ?? 0
    #expect(abs(peak - 0.25) < 0.001)
}

@Test func toneHasTheRequestedFrequency() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    let out = render(&tone, frames: 48_000, channels: 1)
    let rising = (1..<out.count).filter { out[$0 - 1] < 0 && out[$0] >= 0 }.count
    #expect(abs(rising - 440) <= 1)
}
