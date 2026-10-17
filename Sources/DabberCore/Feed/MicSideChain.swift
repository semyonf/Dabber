import CoreAudio
import Synchronization

/// Single-producer single-consumer FIFO of mono samples; the mic IOProc writes, the feed IOProc reads.
public final class SampleFIFO: @unchecked Sendable {
    public let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }

    deinit { data.deallocate() }

    public var count: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

    /// Drops what does not fit: the reader resyncs on its own.
    public func push(_ sample: Float) {
        let h = head.load(ordering: .relaxed)
        guard h - tail.load(ordering: .acquiring) < capacity else { return }
        data[h % capacity] = sample
        head.store(h + 1, ordering: .releasing)
    }

    public func pop() -> Float? {
        let t = tail.load(ordering: .relaxed)
        guard t < head.load(ordering: .acquiring) else { return nil }
        let v = data[t % capacity]
        tail.store(t + 1, ordering: .releasing)
        return v
    }

    public func skip(_ n: Int) {
        let t = tail.load(ordering: .relaxed)
        tail.store(t + min(n, head.load(ordering: .acquiring) - t), ordering: .releasing)
    }
}

/// Mic audio the feed renderer mixes in.
public protocol FeedMicInput: AnyObject, Sendable {
    /// Adds `frames` mono samples at the output rate to interleaved stereo `out`.
    func add(into out: UnsafeMutableBufferPointer<Float>, frames: Int, gain: Float)
}

/// Converts mic samples at the mic's own rate and clock to the feed's rate. The ratio is nudged by how full the
/// FIFO is, so the two clocks never slip against each other. Used only from the feed IOProc.
public final class MicResampler: FeedMicInput, @unchecked Sendable {
    static let maxFrames = 8192
    public let fifo: SampleFIFO
    private let baseStep: Double
    private let target: Int
    private var primed = false
    private var frac = 0.0
    private var h: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private let scratch: UnsafeMutablePointer<Float>
    private let fadeStep: Float
    private var fade: Float = 0
    public private(set) var underruns = 0

    public init(micRate: Double, outputRate: Double, latencySeconds: Double = 0.06) {
        baseStep = micRate / outputRate
        fadeStep = Float(1 / (0.005 * outputRate))
        target = max(64, Int(micRate * latencySeconds))
        fifo = SampleFIFO(capacity: target * 8)
        scratch = .allocate(capacity: Self.maxFrames)
    }

    deinit { scratch.deallocate() }

    public func add(into out: UnsafeMutableBufferPointer<Float>, frames: Int, gain: Float) {
        var done = 0
        while done < frames {
            let n = min(frames - done, Self.maxFrames)
            render(into: scratch, frames: n)
            for f in 0..<n {
                out[2 * (done + f)] += gain * scratch[f]
                out[2 * (done + f) + 1] += gain * scratch[f]
            }
            done += n
        }
    }

    /// Writes `frames` mono samples at the output rate; silence while not primed or after an underrun.
    public func render(into mono: UnsafeMutablePointer<Float>, frames: Int) {
        mono.update(repeating: 0, count: frames)
        let fill = fifo.count
        if !primed {
            guard fill >= target else { return }
            fifo.skip(fill - target)
            primed = true
            frac = 0
            fade = 0
            for _ in 0..<4 { advance() }
        } else if fill > target * 4 {
            fifo.skip(fill - target)
        }
        let error = max(-1, min(1, Double(fifo.count - target) / Double(target)))
        let step = baseStep * (1 + 0.002 * error)
        for f in 0..<frames {
            while frac >= 1 {
                guard advance() else {
                    primed = false
                    underruns += 1
                    return
                }
                frac -= 1
            }
            // Fades in after priming, so resuming after a dropout does not click.
            mono[f] = fade * Self.catmullRom(h, Float(frac))
            fade = min(1, fade + fadeStep)
            frac += step
        }
    }

    @discardableResult
    private func advance() -> Bool {
        guard let s = fifo.pop() else { return false }
        h = (h.1, h.2, h.3, s.isFinite ? s : 0)
        return true
    }

    /// Interpolates between h.1 and h.2.
    static func catmullRom(_ h: (Float, Float, Float, Float), _ t: Float) -> Float {
        let (p0, p1, p2, p3) = h
        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        return ((a * t + b) * t + c) * t + p1
    }
}

/// Reads the mic on its own clock instead of putting it in the feed aggregate. A Bluetooth mic (AirPods in call
/// mode) inside an aggregate either drops packets for every app that reads it or makes the feed click.
public final class MicSideChain: Sendable {
    public let resampler: MicResampler
    private let runner: IOProcRunner

    public init(device: AudioObjectID, outputRate: Double) throws {
        let micRate = try getValue(device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
        guard micRate > 0, outputRate > 0 else { throw CAError(status: kAudioHardwareBadDeviceError, op: "mic rate") }
        let resampler = MicResampler(micRate: micRate, outputRate: outputRate)
        self.resampler = resampler
        let fifo = resampler.fifo
        runner = try IOProcRunner(device: device) { input, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            // Interleaved: average the channels. Non-interleaved: the first buffer is the first channel.
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let src = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += src[f * channels + c] }
                fifo.push(sum / Float(channels))
            }
        }
    }

    public func stop() { runner.stop() }
}

/// Plays the chosen mic and falls back to the built-in one while the chosen mic does not hear the user.
/// macOS does not tell apps whether AirPods are in the ears: taken out, they stay the input and keep sending,
/// only about as loud as the built-in mic instead of 10-25 dB louder. Compared only while the built-in mic hears
/// something, so silence never flips the choice.
public final class MicSwitch: FeedMicInput, @unchecked Sendable {
    public static let voiceDb = -45.0
    public static let outBelowDb = 5.0
    public static let inAboveDb = 10.0
    public static let outAfter = 1.0
    public static let inAfter = 0.5

    private let primary: MicResampler
    private let backup: MicResampler
    private let rate: Double
    private let p: UnsafeMutablePointer<Float>
    private let b: UnsafeMutablePointer<Float>
    private var envP = 0.0
    private var envB = 0.0
    private var pending = 0.0
    private var weight: Float = 1
    public private(set) var usingBackup = false

    public init(primary: MicResampler, backup: MicResampler, outputRate: Double) {
        self.primary = primary
        self.backup = backup
        rate = outputRate
        p = .allocate(capacity: MicResampler.maxFrames)
        b = .allocate(capacity: MicResampler.maxFrames)
    }

    deinit {
        p.deallocate()
        b.deallocate()
    }

    public func add(into out: UnsafeMutableBufferPointer<Float>, frames: Int, gain: Float) {
        var done = 0
        while done < frames {
            let n = min(frames - done, MicResampler.maxFrames)
            primary.render(into: p, frames: n)
            backup.render(into: b, frames: n)
            decide(primary: Self.meanSquare(p, n), backup: Self.meanSquare(b, n), seconds: Double(n) / rate)
            let target: Float = usingBackup ? 0 : 1
            let step = Float(1 / (0.05 * rate))
            for f in 0..<n {
                if weight < target { weight = min(target, weight + step) }
                if weight > target { weight = max(target, weight - step) }
                let v = gain * (weight * p[f] + (1 - weight) * b[f])
                out[2 * (done + f)] += v
                out[2 * (done + f) + 1] += v
            }
            done += n
        }
    }

    func decide(primary ms: Double, backup msB: Double, seconds: Double) {
        let a = 1 - exp(-seconds / 0.3)
        envP += (ms - envP) * a
        envB += (msB - envB) * a
        let dbP = 10 * log10(envP + 1e-12), dbB = 10 * log10(envB + 1e-12)
        let voice = max(dbP, dbB) > Self.voiceDb
        let flip = usingBackup ? dbP - dbB > Self.inAboveDb : dbP - dbB < Self.outBelowDb
        pending = voice && flip ? pending + seconds : 0
        if pending >= (usingBackup ? Self.inAfter : Self.outAfter) {
            usingBackup.toggle()
            pending = 0
        }
    }

    private static func meanSquare(_ x: UnsafeMutablePointer<Float>, _ n: Int) -> Double {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += x[i] * x[i] }
        return Double(sum) / Double(n)
    }
}

public struct MicCandidate: Sendable {
    public let id: AudioObjectID
    public let bluetooth: Bool
}

public struct OpenedMics {
    public let input: FeedMicInput?
    public let devices: [AudioObjectID]
    public let stop: @Sendable () -> Void
}

public enum MicInputs {
    public typealias Start = (AudioObjectID) throws -> (resampler: MicResampler, stop: @Sendable () -> Void)

    /// Opens the chosen mic. A Bluetooth one gets the built-in mic as a backup behind a MicSwitch; a missing one is
    /// replaced by the built-in mic. The backup is optional: if it fails to open, the chosen mic plays alone.
    public static func open(
        chosen: MicCandidate?, builtIn: AudioObjectID?, outputRate: Double, start: Start
    ) throws -> OpenedMics {
        let backupID = builtIn == chosen?.id ? nil : builtIn
        guard let chosen else {
            guard let backupID, let b = try? start(backupID) else { return OpenedMics(input: nil, devices: [], stop: {}) }
            return OpenedMics(input: b.resampler, devices: [backupID], stop: b.stop)
        }
        let c = try start(chosen.id)
        guard chosen.bluetooth, let backupID, let b = try? start(backupID) else {
            return OpenedMics(input: c.resampler, devices: [chosen.id], stop: c.stop)
        }
        return OpenedMics(
            input: MicSwitch(primary: c.resampler, backup: b.resampler, outputRate: outputRate),
            devices: [chosen.id, backupID],
            stop: {
                c.stop()
                b.stop()
            })
    }
}
