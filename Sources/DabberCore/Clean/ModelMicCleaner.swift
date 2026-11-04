import Foundation

/// What `Finalizer` needs from a microphone cleaner: mono 48 kHz in and out, the output `latency` frames late.
protocol MicCleaning: AnyObject, Sendable {
    /// Whether the reference (Mac audio) is used.
    var echo: Bool { get }
    var latency: Int { get }
    /// How much earlier than the measured delay Mac audio is fed, so that the echo never comes before it.
    var headroom: Int { get }
    /// Why the cleaning stopped part way, if it did; the rest of the track is left as recorded.
    var failure: String? { get }
    func process(mic: [Float], reference: [Float]) -> [Float]
}

extension MicCleaner: MicCleaning {
    var latency: Int { Self.latency }
    var headroom: Int { Self.headroom }
    var failure: String? { nil }
}

/// A neural model that cleans 16 kHz microphone audio with the far-end reference (LocalVQE): echo, noise, room.
/// One stream per track, used from one thread at a time.
public protocol MicModelStream: AnyObject {
    /// The most 16 kHz samples `enhance` may hold back.
    var buffering: Int { get }
    /// Takes mic and reference samples of the same moment and returns the cleaned samples that are complete, in
    /// order and aligned with the input: as many as given in the end, fewer while the model buffers.
    func enhance(mic: [Float], reference: [Float]) throws -> [Float]
}

/// Opens a stream for one track, or throws when the model is not ready (then `MicCleaner` is used).
public typealias MicModel = @Sendable () throws -> any MicModelStream

/// Runs a 16 kHz model on a 48 kHz microphone track. The model only sees what is below 8 kHz. What is above (the
/// "air" of a good microphone; an AirPods call microphone has nothing there) is taken from the original track and let
/// through only as much as the model let the sound through: where the model left your voice, the highs stay; where it
/// removed echo or noise, they go too.
///
/// The output is `latency` frames late. The filters delay the sound by `path` frames; the rest of `latency` is room
/// for what the model holds back, so the output never runs dry. Not thread-safe (hence `@unchecked Sendable`).
final class ModelMicCleaner: MicCleaning, @unchecked Sendable {
    static let factor = 3
    /// 20 ms: the model lines up the echo by itself within a few hundred ms, it only must not come before Mac audio.
    static let headroom = 960
    /// About 10 ms: how fast the gain on the highs follows the model.
    static let gainSmoothing: Float = exp(-1 / (0.01 * 16_000))

    let echo: Bool
    let latency: Int
    var headroom: Int { Self.headroom }
    private(set) var failure: String?

    private let stream: any MicModelStream
    private var down = FIRFilter.lowPass()
    private var refDown = FIRFilter.lowPass()
    private var up = FIRFilter.lowPass()
    /// The highs are the original track minus what the same two low-pass filters (down and up) leave of it, so that
    /// with the model passing everything through, lows and highs add up to the original exactly.
    private var split = FIRFilter.lowPass()
    private var split2 = FIRFilter.lowPass()
    private var late = DelayLine(ModelMicCleaner.path)
    private var phase = 0
    private var refPhase = 0
    private var highs: [Float] = []
    /// 16 kHz input the model has not answered yet, to compare the answer with.
    private var unanswered: [Float] = []
    private var energyIn: Float = 0
    private var energyOut: Float = 0
    private var ready: [Float]

    /// Frames of delay through the filters: down to 16 kHz and back up.
    static let path = 2 * FIRFilter.delay

    init(echo: Bool, stream: any MicModelStream) {
        self.echo = echo
        self.stream = stream
        let room = Self.factor * (stream.buffering + 2)
        latency = room + Self.path
        ready = [Float](repeating: 0, count: room)
    }

    func process(mic: [Float], reference: [Float]) -> [Float] {
        let low = decimate(mic, filter: &down, phase: &phase)
        let ref = echo && reference.count == mic.count
            ? decimate(reference, filter: &refDown, phase: &refPhase)
            : [Float](repeating: 0, count: low.count)
        let filtered = split2.filter(split.filter(mic))
        let delayed = late.push(mic)
        highs += (0..<mic.count).map { delayed[$0] - filtered[$0] }
        unanswered += low
        var cleaned: [Float]
        if failure == nil {
            do {
                cleaned = try stream.enhance(mic: low, reference: ref)
            } catch {
                failure = "\(error)"
                cleaned = []
            }
        } else {
            cleaned = []
        }
        // After a failure the model's buffer is lost: the rest goes through as recorded, which also keeps the timing.
        if failure != nil { cleaned += unanswered.dropFirst(cleaned.count) }
        let answered = min(cleaned.count, unanswered.count)
        var gains = [Float](repeating: 1, count: answered)
        for i in 0..<answered {
            let a = unanswered[i], b = cleaned[i]
            energyIn = Self.gainSmoothing * energyIn + (1 - Self.gainSmoothing) * a * a
            energyOut = Self.gainSmoothing * energyOut + (1 - Self.gainSmoothing) * b * b
            gains[i] = failure == nil ? min(1, (energyOut / (energyIn + 1e-12)).squareRoot()) : 1
        }
        unanswered.removeFirst(answered)
        var stuffed = [Float](repeating: 0, count: answered * Self.factor)
        for i in 0..<answered { stuffed[i * Self.factor] = Float(Self.factor) * cleaned[i] }
        var out = up.filter(stuffed)
        let take = min(out.count, highs.count)
        for i in 0..<take { out[i] += gains[i / Self.factor] * highs[i] }
        highs.removeFirst(take)
        ready += out.prefix(take)
        var result = Array(ready.prefix(mic.count))
        ready.removeFirst(result.count)
        if result.count < mic.count { result += [Float](repeating: 0, count: mic.count - result.count) }
        return result
    }

    /// Low-pass filtered and every third sample kept; `phase` carries the position across calls.
    private func decimate(_ x: [Float], filter: inout FIRFilter, phase: inout Int) -> [Float] {
        let out = filter.filter(x, from: (Self.factor - phase) % Self.factor, step: Self.factor)
        phase = (phase + x.count) % Self.factor
        return out
    }
}

/// Linear-phase FIR filter with state across calls.
struct FIRFilter {
    static let taps = 145
    static let delay = (taps - 1) / 2
    let coefficients: [Float]
    private var history: [Float]

    init(_ coefficients: [Float]) {
        self.coefficients = coefficients
        history = [Float](repeating: 0, count: coefficients.count - 1)
    }

    /// Windowed sinc (Blackman) at 48 kHz, cut at 7 kHz: below the 8 kHz limit of 16 kHz audio, fully down by
    /// about 8.7 kHz.
    static func lowPass(cutoff: Double = 7_000, rate: Double = 48_000) -> FIRFilter {
        let n = taps
        let fc = cutoff / rate
        var h = (0..<n).map { i -> Double in
            let m = Double(i - delay)
            let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return FIRFilter(h.map(Float.init))
    }

    mutating func filter(_ x: [Float]) -> [Float] {
        filter(x, from: 0, step: 1)
    }

    /// Only the outputs at `from`, `from + step`, … of this call (decimation without computing the rest).
    mutating func filter(_ x: [Float], from: Int, step: Int) -> [Float] {
        let n = coefficients.count
        let buffer = history + x
        let positions = Array(stride(from: from, to: x.count, by: step))
        var out = [Float](repeating: 0, count: positions.count)
        coefficients.withUnsafeBufferPointer { h in
            buffer.withUnsafeBufferPointer { b in
                for (j, i) in positions.enumerated() {
                    var sum: Float = 0
                    for k in 0..<n { sum += h[k] * b[i + n - 1 - k] }
                    out[j] = sum
                }
            }
        }
        history = Array(buffer.suffix(n - 1))
        return out
    }
}

struct DelayLine {
    private var held: [Float]

    init(_ frames: Int) {
        held = [Float](repeating: 0, count: frames)
    }

    mutating func push(_ x: [Float]) -> [Float] {
        held += x
        let out = Array(held.prefix(x.count))
        held.removeFirst(x.count)
        return out
    }
}
