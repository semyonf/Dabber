import CoreAudio
import Foundation

public final class TonePlayer: @unchecked Sendable {
    private var tone: ToneGenerator
    private let startNanos: UInt64
    private var nextSampleTime = -1.0
    public private(set) var toneStartNanos: UInt64 = 0
    public private(set) var framesRendered = 0
    public private(set) var discontinuities = 0
    public private(set) var unexpectedLayouts = 0

    public init(tone: ToneGenerator, startNanos: UInt64) {
        self.tone = tone
        self.startNanos = startNanos
    }

    public func render(_ list: UnsafeMutablePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count == 1, let data = buffers[0].mData, buffers[0].mNumberChannels > 0 else {
            for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            unexpectedLayouts += 1
            return
        }
        let channels = Int(buffers[0].mNumberChannels)
        let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frames = count / channels
        let t = time.pointee
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuities += 1 }
        nextSampleTime = t.mSampleTime + Double(frames)
        framesRendered += frames
        let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        let nanos = HostClock.nanos(hostTime: t.mHostTime)
        if toneStartNanos == 0, nanos >= startNanos { toneStartNanos = nanos }
        if toneStartNanos == 0 {
            out.update(repeating: 0)
        } else {
            tone.fill(out, channels: channels)
        }
    }
}
