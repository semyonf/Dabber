import CoreAudio
import Foundation
import Synchronization

public final class FeedRenderer: @unchecked Sendable {
    public let meter = LevelMeter()
    private let cycleCount = Atomic<Int>(0)
    private let frameCount = Atomic<Int>(0)
    private let discontinuityCount = Atomic<Int>(0)
    private let unexpectedLayoutCount = Atomic<Int>(0)
    private let skippedInputCount = Atomic<Int>(0)
    private var nextSampleTime = -1.0

    public init() {}

    public var cycles: Int { cycleCount.load(ordering: .relaxed) }
    public var framesRendered: Int { frameCount.load(ordering: .relaxed) }
    public var discontinuities: Int { discontinuityCount.load(ordering: .relaxed) }
    public var unexpectedLayouts: Int { unexpectedLayoutCount.load(ordering: .relaxed) }
    public var skippedInputs: Int { skippedInputCount.load(ordering: .relaxed) }

    public func render(
        _ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
        _ time: UnsafePointer<AudioTimeStamp>
    ) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard outs.count == 1, let data = outs[0].mData, outs[0].mNumberChannels == 2 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            unexpectedLayoutCount.add(1, ordering: .relaxed)
            return
        }
        let frames = Int(outs[0].mDataByteSize) / MemoryLayout<Float>.size / 2
        let t = time.pointee
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuityCount.add(1, ordering: .relaxed) }
        nextSampleTime = t.mSampleTime + Double(frames)
        cycleCount.add(1, ordering: .relaxed)
        frameCount.add(frames, ordering: .relaxed)
        let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * 2)
        out.update(repeating: 0)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var sources = 0
        for b in inputs where Self.fits(b, frames: frames) { sources += 1 }
        for b in inputs {
            guard Self.fits(b, frames: frames), let src = b.mData else {
                skippedInputCount.add(1, ordering: .relaxed)
                continue
            }
            let channels = Int(b.mNumberChannels)
            FeedMixer.add(
                UnsafeBufferPointer(start: src.assumingMemoryBound(to: Float.self), count: frames * channels),
                channels: channels, gain: 1 / Float(sources), into: out)
        }
        FeedMixer.clamp(out)
        meter.update(UnsafePointer(data.assumingMemoryBound(to: Float.self)), count: out.count)
    }

    private static func fits(_ b: AudioBuffer, frames: Int) -> Bool {
        b.mNumberChannels > 0 && b.mData != nil
            && Int(b.mDataByteSize) == frames * Int(b.mNumberChannels) * MemoryLayout<Float>.size
    }
}
