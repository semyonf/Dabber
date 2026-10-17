import CoreAudio
import Foundation
import Testing
@testable import DabberCore

private func pull(_ r: MicResampler, frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    out.withUnsafeMutableBufferPointer { r.add(into: $0, frames: frames, gain: 1) }
    return stride(from: 0, to: out.count, by: 2).map { out[$0] }
}

@Test func resamplerStaysSilentUntilPrimed() {
    let r = MicResampler(micRate: 24_000, outputRate: 48_000, latencySeconds: 0.01)
    for _ in 0..<100 { r.fifo.push(0.5) }
    #expect(pull(r, frames: 64).allSatisfy { $0 == 0 })
}

// Bluetooth headsets run their mic at 8 kHz (CVSD), 16 kHz (mSBC) or 24 kHz (AirPods); wired ones at 44.1/48 kHz.
@Test(arguments: [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0])
func resamplerConvertsAToneWithoutClicks(micRate: Double) {
    let outRate = 48_000.0, hz = 700.0
    let r = MicResampler(micRate: micRate, outputRate: outRate)
    var n = 0
    func feed(_ count: Int) {
        for _ in 0..<count {
            r.fifo.push(Float(0.5 * sin(2 * .pi * hz * Double(n) / micRate)))
            n += 1
        }
    }
    // The mic delivers 20 ms packets, the feed asks for 512 frames: the clocks never line up.
    let packet = Int(micRate * 0.02)
    var out: [Float] = []
    var owed = 0.0
    feed(packet * 4)
    for _ in 0..<400 {
        out += pull(r, frames: 512)
        owed += 512 * micRate / outRate
        while owed >= Double(packet) {
            feed(packet)
            owed -= Double(packet)
        }
    }
    #expect(r.underruns == 0)
    let steady = Array(out.dropFirst(4800))
    // A clean tone moves at most 2*pi*f/rate*amplitude per sample; a click jumps far more.
    let maxJump = zip(steady, steady.dropFirst()).map { abs($1 - $0) }.max() ?? 1
    #expect(maxJump < Float(2 * .pi * hz / outRate * 0.5 * 1.2))
    #expect((steady.max() ?? 0) > 0.45)
}

@Test func resamplerResyncsAfterAnUnderrun() {
    let r = MicResampler(micRate: 48_000, outputRate: 48_000, latencySeconds: 0.01)
    for _ in 0..<600 { r.fifo.push(0.25) }
    _ = pull(r, frames: 1000)
    #expect(r.underruns == 1)
    #expect(pull(r, frames: 64).allSatisfy { $0 == 0 })
    for _ in 0..<600 { r.fifo.push(0.25) }
    #expect(pull(r, frames: 400).suffix(100).allSatisfy { abs($0 - 0.25) < 1e-6 })
}

@Test func resamplerFadesInAfterPrimingSoAResumeDoesNotClick() {
    let r = MicResampler(micRate: 48_000, outputRate: 48_000, latencySeconds: 0.05)
    for _ in 0..<3000 { r.fifo.push(0.5) }
    let out = pull(r, frames: 1000)
    #expect(out[0] < 0.05)
    #expect(abs(out[999] - 0.5) < 1e-6)
}

@Test func resamplerFillsBuffersLargerThanItsScratch() {
    let r = MicResampler(micRate: 48_000, outputRate: 48_000, latencySeconds: 0.25)
    for _ in 0..<13_000 { r.fifo.push(0.5) }
    let out = pull(r, frames: 10_000)
    #expect(abs(out[9_999] - 0.5) < 1e-6)
}

private func db(_ v: Double) -> Double { pow(10, v / 10) }

private func feed(_ s: MicSwitch, chosen: Double, builtIn: Double, seconds: Double) {
    for _ in 0..<Int(seconds * 100) { s.decide(primary: db(chosen), backup: db(builtIn), seconds: 0.01) }
}

private func makeSwitch() -> MicSwitch {
    MicSwitch(
        primary: MicResampler(micRate: 24_000, outputRate: 48_000),
        backup: MicResampler(micRate: 48_000, outputRate: 48_000), outputRate: 48_000)
}

@Test func switchKeepsAirPodsWhileTheyHearTheUserLouder() {
    let s = makeSwitch()
    feed(s, chosen: -15, builtIn: -35, seconds: 5)
    #expect(!s.usingBackup)
}

@Test func switchFallsBackWhenAirPodsAreTakenOutAndReturnsWhenPutBack() {
    let s = makeSwitch()
    feed(s, chosen: -15, builtIn: -35, seconds: 2)
    feed(s, chosen: -30, builtIn: -30, seconds: 0.5)
    #expect(!s.usingBackup)
    feed(s, chosen: -30, builtIn: -30, seconds: 1.5)
    #expect(s.usingBackup)
    feed(s, chosen: -15, builtIn: -35, seconds: 1.5)
    #expect(!s.usingBackup)
}

@Test func switchIgnoresSilence() {
    let s = makeSwitch()
    feed(s, chosen: -70, builtIn: -60, seconds: 10)
    #expect(!s.usingBackup)
}

@Test func switchFallsBackWhenAirPodsGoSilentWhileTheUserTalks() {
    let s = makeSwitch()
    feed(s, chosen: -200, builtIn: -30, seconds: 2)
    #expect(s.usingBackup)
}

private final class Starter: @unchecked Sendable {
    var failing: Set<AudioObjectID> = []
    var started: [AudioObjectID] = []
    var stopped: [AudioObjectID] = []

    func start(_ id: AudioObjectID) throws -> (resampler: MicResampler, stop: @Sendable () -> Void) {
        if failing.contains(id) { throw SourceError.deviceMissing("\(id)") }
        started.append(id)
        return (MicResampler(micRate: 48_000, outputRate: 48_000), { [self] in stopped.append(id) })
    }
}

private func open(_ s: Starter, chosen: MicCandidate?, builtIn: AudioObjectID? = 2) throws -> OpenedMics {
    try MicInputs.open(chosen: chosen, builtIn: builtIn, outputRate: 48_000, start: s.start)
}

@Test func bluetoothMicGetsTheBuiltInBackupSwitch() throws {
    let s = Starter()
    let mics = try open(s, chosen: MicCandidate(id: 1, bluetooth: true))
    #expect(mics.input is MicSwitch)
    #expect(s.started == [1, 2])
    #expect(mics.devices == [1, 2])
    mics.stop()
    #expect(s.stopped.sorted() == [1, 2])
}

@Test func wiredMicGetsNoBackup() throws {
    let s = Starter()
    let mics = try open(s, chosen: MicCandidate(id: 1, bluetooth: false))
    #expect(mics.input is MicResampler)
    #expect(s.started == [1])
}

@Test func backupThatFailsToOpenKeepsTheChosenMic() throws {
    let s = Starter()
    s.failing = [2]
    let mics = try open(s, chosen: MicCandidate(id: 1, bluetooth: true))
    #expect(mics.input is MicResampler)
    #expect(mics.devices == [1])
    mics.stop()
    #expect(s.stopped == [1])
}

@Test func chosenMicThatFailsToOpenLeavesNothingRunning() {
    let s = Starter()
    s.failing = [1]
    #expect(throws: (any Error).self) { try open(s, chosen: MicCandidate(id: 1, bluetooth: true)) }
    #expect(Set(s.started) == Set(s.stopped))
}

@Test func missingChosenMicFallsBackToTheBuiltInOne() throws {
    let s = Starter()
    let mics = try open(s, chosen: nil)
    #expect(mics.input is MicResampler)
    #expect(s.started == [2])
}

@Test func builtInMicChosenOpensOnce() throws {
    let s = Starter()
    let mics = try open(s, chosen: MicCandidate(id: 2, bluetooth: false))
    #expect(s.started == [2])
    #expect(mics.devices == [2])
}
