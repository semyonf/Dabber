import CoreAudio
import Foundation
@testable import DabberCore

func pushSlot(_ ring: RingBuffer, bytes: [UInt8], sampleTime: Double, hostNanos: UInt64) {
    var b = bytes
    b.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mHostTime = AudioConvertNanosToHostTime(hostNanos)
        ts.mFlags = [.sampleTimeValid, .hostTimeValid]
        withUnsafePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in ring.push(l, t) } }
    }
}

func pushSlot(_ ring: RingBuffer, samples: [Int16], sampleTime: Double, hostNanos: UInt64) {
    var bytes = [UInt8](repeating: 0, count: samples.count * 2)
    bytes.withUnsafeMutableBytes { raw in
        samples.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    pushSlot(ring, bytes: bytes, sampleTime: sampleTime, hostNanos: hostNanos)
}

func int16Mono(rate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
        mReserved: 0)
}

func tone(frames: Int, rate: Double, hz: Double = 440, amplitude: Double = 16_000) -> [Int16] {
    (0..<frames).map { Int16(sin(Double($0) / rate * 2 * .pi * hz) * amplitude) }
}

func waitUntil(_ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(3)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
