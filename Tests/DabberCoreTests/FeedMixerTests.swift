import Foundation
import Testing
@testable import DabberCore

private func mix(_ inputs: [([Float], Int)], frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames * 2)
    out.withUnsafeMutableBufferPointer { o in
        for (samples, channels) in inputs {
            samples.withUnsafeBufferPointer {
                FeedMixer.add($0, channels: channels, gain: 1 / Float(inputs.count), into: o)
            }
        }
        FeedMixer.clamp(o)
    }
    return out
}

@Test func singleFeedMonoSourceGoesToBothChannelsUnscaled() {
    #expect(mix([([0.1, 0.2], 1)], frames: 2) == [0.1, 0.1, 0.2, 0.2])
}

@Test func feedStereoKeepsItsChannels() {
    #expect(mix([([0.1, 0.2, 0.3, 0.4], 2)], frames: 2) == [0.1, 0.2, 0.3, 0.4])
}

@Test func moreThanTwoChannelsUseTheFirstAsMono() {
    #expect(mix([([0.1, 0.9, 0.9, 0.2, 0.9, 0.9], 3)], frames: 2) == [0.1, 0.1, 0.2, 0.2])
}

@Test func feedMixMatchesTheRecordingMixer() {
    let mono: [Float] = [0.5, -0.25, 0.75]
    let stereo: [Float] = [0.25, 0.5, -1, 0.5, 0.5, -0.5]
    #expect(mix([(mono, 1), (stereo, 2)], frames: 3) == Mixer.mixToStereo(mono: [mono], stereo: [stereo]))
}

@Test func shortInputLeavesTheRestUntouched() {
    #expect(mix([([0.5], 1)], frames: 2) == [0.5, 0.5, 0, 0])
}

@Test func twoFullScaleFeedSourcesDoNotClip() {
    let frames = 48_000
    let a = (0..<frames).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) }
    let b = (0..<frames).flatMap { f in
        let s = Float(sin(2 * Double.pi * 1499 * Double(f) / 48_000))
        return [s, s]
    }
    let out = mix([(a, 1), (b, 2)], frames: frames)
    #expect(out.map(abs).max()! <= 1)
    #expect(!out.contains { abs($0) == 1 })
}

@Test func nonFiniteFeedInputBecomesSilence() {
    let out = mix([([0.2, .nan, .infinity, -.infinity], 1), ([.nan, 0.4, 0.2, .nan, 0.2, 0.2, 0.2, 0.2], 2)], frames: 4)
    #expect(out == [0.1, 0.3, 0.1, 0, 0.1, 0.1, 0.1, 0.1])
}
