import Foundation
import Testing
@testable import DabberCore

/// Deterministic noise in -amplitude...amplitude.
private func noise(_ count: Int, seed: UInt64, amplitude: Float) -> [Float] {
    var x = seed
    return (0..<count).map { _ in
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Double(x >> 40) / Double(1 << 24) * 2 - 1) * amplitude
    }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
}

private func delayed(_ x: [Float], by frames: Int, gain: Float) -> [Float] {
    (0..<x.count).map { $0 >= frames ? gain * x[$0 - frames] : 0 }
}

private func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

/// Feeds the cleaner the way the Finalizer does: primed with the first `latency` frames, then each chunk read
/// `latency` frames ahead, the reference `shift` frames earlier than the mic.
private func clean(_ cleaner: any MicCleaning, mic: [Float], reference: [Float], shift: Int) -> [Float] {
    func read(_ x: [Float], _ range: Range<Int>) -> [Float] {
        range.map { $0 >= 0 && $0 < x.count ? x[$0] : 0 }
    }
    let latency = cleaner.latency
    func feed(_ ahead: Range<Int>) -> [Float] {
        let ref = cleaner.echo ? read(reference, (ahead.lowerBound - shift)..<(ahead.upperBound - shift)) : []
        return cleaner.process(mic: read(mic, ahead), reference: ref)
    }
    _ = feed(0..<latency)
    var out: [Float] = []
    var start = 0
    while start < mic.count {
        let end = min(start + 48_000, mic.count)
        out += feed((start + latency)..<(end + latency))
        start = end
    }
    return out
}

@Test func realFFTMatchesTheDirectTransformAndInvertsIt() {
    let size = 16
    let x = noise(size, seed: 7, amplitude: 1)
    let fft = RealFFT(size: size)
    var re = [Float](repeating: 0, count: fft.bins)
    var im = re
    fft.forward(x, re: &re, im: &im)
    for k in 0..<fft.bins {
        var sr = 0.0
        var si = 0.0
        for n in 0..<size {
            let angle = -2 * Double.pi * Double(k * n) / Double(size)
            sr += Double(x[n]) * cos(angle)
            si += Double(x[n]) * sin(angle)
        }
        #expect(abs(Double(re[k]) - sr) < 1e-4, "re \(k)")
        #expect(abs(Double(im[k]) - si) < 1e-4, "im \(k)")
    }
    var back = [Float](repeating: 0, count: size)
    fft.inverse(re: re, im: im, &back)
    for n in 0..<size { #expect(abs(back[n] - x[n]) < 1e-5, "sample \(n)") }
}

@Test func echoDelayFindsHowLateTheMicHearsTheReference() {
    let frames = 4 * 48_000
    let reference = noise(frames, seed: 1, amplitude: 0.3)
    let mic = add(delayed(reference, by: 1_680, gain: 0.5), noise(frames, seed: 2, amplitude: 0.05))
    var estimator = EchoDelay()
    for start in stride(from: 0, to: frames, by: 48_000) {
        estimator.add(mic: Array(mic[start..<(start + 48_000)]), reference: Array(reference[start..<(start + 48_000)]))
    }
    #expect(estimator.lag() == 1_680)
}

@Test func echoDelayIsNilWhenTheMicDoesNotHearTheReference() {
    let frames = 4 * 48_000
    var estimator = EchoDelay()
    estimator.add(mic: noise(frames, seed: 3, amplitude: 0.3), reference: noise(frames, seed: 1, amplitude: 0.3))
    #expect(estimator.blocksUsed == 3)
    #expect(estimator.lag() == nil)
}

@Test func echoDelayIgnoresSilence() {
    var estimator = EchoDelay()
    estimator.add(mic: [Float](repeating: 0, count: 4 * 48_000), reference: noise(4 * 48_000, seed: 1, amplitude: 0.3))
    #expect(estimator.blocksUsed == 0)
    #expect(estimator.lag() == nil)
}

@Test func cleanerRemovesTheEchoOfTheReference() {
    let frames = 6 * 48_000
    let reference = noise(frames, seed: 4, amplitude: 0.3)
    // Direct sound 10 ms late, a reflection, and a weak late one 41 ms late.
    var mic = delayed(reference, by: 480, gain: 0.6)
    mic = add(mic, delayed(reference, by: 580, gain: -0.3))
    mic = add(mic, delayed(reference, by: 1_980, gain: 0.1))
    let out = clean(MicCleaner(echo: true), mic: mic, reference: reference, shift: 480 - MicCleaner.headroom)
    #expect(out.count == frames)
    let tail = (4 * 48_000)..<frames
    // About -44 dB in the simulation of this code.
    #expect(rms(out[tail]) < rms(mic[tail]) * 0.03)
}

@Test func cleanerKeepsSpeechTimingAndLevelAndLowersNoiseBetween() {
    let frames = 4 * 48_000
    // A 1 kHz tone in 0.25 s bursts stands in for speech, with steady noise 40 dB lower.
    let tone = (0..<frames).map { i -> Float in
        let t = Double(i) / 48_000
        return Int(t * 2) % 2 == 0 ? Float(0.3 * sin(2 * Double.pi * 1_000 * t)) : 0
    }
    let mic = add(tone, noise(frames, seed: 5, amplitude: 0.003))
    let out = clean(MicCleaner(echo: false), mic: mic, reference: [], shift: 0)
    #expect(out.count == frames)
    let burst = 146_400..<165_600
    #expect(abs(rms(out[burst]) / rms(mic[burst]) - 1) < 0.05)
    // Output on the same timeline: the best match with the input is at no shift.
    func match(_ shift: Int) -> Float { burst.reduce(0) { $0 + out[$1] * mic[$1 + shift] } }
    #expect((-5...5).max { match($0) < match($1) } == 0)
    let gap = 124_800..<139_200
    // About -19 dB in the simulation of this code.
    #expect(rms(out[gap]) < rms(mic[gap]) * 0.25)
}

/// Stands in for LocalVQE: answers whole blocks of 4096 samples, aligned with the input, like the real stream.
private final class FakeModel: MicModelStream {
    enum Mode { case passThrough, silence, failAfter(Int) }
    let mode: Mode
    let buffering = 4096 + 256
    private var pending: [Float] = []
    private var answered = 0
    var references: [Float] = []

    init(_ mode: Mode) { self.mode = mode }

    struct Broken: Error {}

    func enhance(mic: [Float], reference: [Float]) throws -> [Float] {
        if case .failAfter(let n) = mode, answered >= n { throw Broken() }
        pending += mic
        references += reference
        let n = pending.count / 4096 * 4096
        let out = Array(pending.prefix(n))
        pending.removeFirst(n)
        answered += n
        if case .silence = mode { return [Float](repeating: 0, count: n) }
        return out
    }
}

/// Wide-band noise: below and above 8 kHz.
private func wideNoise(_ count: Int) -> [Float] { noise(count, seed: 11, amplitude: 0.3) }

@Test func modelCleanerPassingEverythingGivesBackTheTrackExactlyOnTime() {
    let mic = wideNoise(3 * 48_000)
    let cleaner = ModelMicCleaner(echo: false, stream: FakeModel(.passThrough))
    let out = clean(cleaner, mic: mic, reference: [], shift: 0)
    #expect(out.count == mic.count)
    // Lows from the model and highs from the track add up to the track (filter edges aside).
    let error = zip(out, mic).dropFirst(1_000).dropLast(1_000).map { abs($0 - $1) }.max() ?? 1
    #expect(error < 1e-3)
}

@Test func modelCleanerSilencesTheHighsWhereTheModelRemovedEverything() {
    let mic = wideNoise(3 * 48_000)
    let cleaner = ModelMicCleaner(echo: true, stream: FakeModel(.silence))
    let out = clean(cleaner, mic: mic, reference: mic, shift: 0)
    #expect(rms(out[48_000...]) < 0.001)
}

@Test func modelCleanerFeedsTheModelMacAudioAt16kHz() {
    let mic = wideNoise(48_000)
    let model = FakeModel(.passThrough)
    let cleaner = ModelMicCleaner(echo: true, stream: model)
    _ = clean(cleaner, mic: mic, reference: mic, shift: 0)
    #expect(model.references.count > 15_000)
    #expect(rms(model.references[4_000...]) > 0.05)
}

@Test func modelCleanerLeavesTheRestAsRecordedWhenTheModelFails() {
    let mic = wideNoise(4 * 48_000)
    let cleaner = ModelMicCleaner(echo: false, stream: FakeModel(.failAfter(16_000)))
    let out = clean(cleaner, mic: mic, reference: [], shift: 0)
    #expect(cleaner.failure != nil)
    #expect(out.count == mic.count)
    // Long after the failure the track goes through unchanged and on time.
    let error = zip(out, mic).dropFirst(3 * 48_000).dropLast(1_000).map { abs($0 - $1) }.max() ?? 1
    #expect(error < 1e-3)
}
