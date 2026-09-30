import Foundation
import Testing
@testable import DabberCore

@Test func singleMonoSourceGoesToBothChannelsUnscaled() {
    #expect(Mixer.mixToStereo(mono: [[0.5, -0.25]], stereo: []) == [0.5, 0.5, -0.25, -0.25])
}

@Test func singleStereoSourceIsUnscaled() {
    #expect(Mixer.mixToStereo(mono: [], stereo: [[0.5, -0.25]]) == [0.5, -0.25])
}

@Test func stereoIsSummedWithMono() {
    #expect(Mixer.mixToStereo(mono: [[0.1]], stereo: [[0.2, 0.3]]) == [0.15, 0.2].map { Float($0) })
}

@Test func backupTracksAreMixedAtTheGainOfTheOthers() {
    #expect(Mixer.mixToStereo(mono: [[0.5]], stereo: [], backup: [[0, 0.5]]) == [0.5, 0.5, 0.5, 0.5])
}

@Test func shorterInputsArePaddedWithSilence() {
    #expect(Mixer.mixToStereo(mono: [[0.5]], stereo: [[0, 0, 0.25, 0.25]]) == [0.25, 0.25, 0.125, 0.125])
}

@Test func twoFullScaleSinesDoNotClip() {
    let frames = 48_000
    let a = (0..<frames).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) }
    let b = (0..<frames).flatMap { f in
        let s = Float(sin(2 * Double.pi * 1499 * Double(f) / 48_000))
        return [s, s]
    }
    let out = Mixer.mixToStereo(mono: [a], stereo: [b])
    #expect(out.map(abs).max()! <= 1)
    #expect(!out.contains { abs($0) == 1 })
}

@Test func positiveSumIsClamped() {
    #expect(Mixer.mixToStereo(mono: [[1.5], [1.5]], stereo: []) == [1, 1])
}

@Test func negativeSumIsClamped() {
    #expect(Mixer.mixToStereo(mono: [], stereo: [[-1.5, -1.5], [-1.5, -1.5]]) == [-1, -1])
}

@Test func emptyInputGivesEmptyMix() {
    #expect(Mixer.mixToStereo(mono: [], stereo: []).isEmpty)
}

@Test func oddLengthStereoDropsTrailingSample() {
    #expect(Mixer.mixToStereo(mono: [], stereo: [[0.1, 0.2, 0.3]]) == [0.1, 0.2])
}
