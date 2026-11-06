import Foundation

/// Finds how much later a microphone hears Mac audio than the Mac audio track has it: output and input latency plus
/// the way through the room. Cross-correlation with phase transform (GCC-PHAT) over the whole recording, on 8 kHz
/// averages: speech of either side that is not echo averages out, and the direct sound from the speakers stands
/// out as one peak. Mic and Mac audio of the same moment are fed together, 48 kHz mono.
struct EchoDelay {
    static let decimation = 6
    /// 8192 samples at 8 kHz: about one second per block.
    static let block = 8192
    /// ±0.5 s at 8 kHz.
    static let maxLag = 4000
    /// Blocks quieter than -70 dB on either side say nothing about the delay.
    static let minPower: Float = 1e-7
    /// Peak over the RMS of the correlation. With echo it is far above 10 (about 90 in the simulations), without
    /// echo (headphones) it stays near 4.
    static let minConfidence: Float = 10

    private let fft = RealFFT(size: 2 * EchoDelay.block)
    private var accRe: [Float]
    private var accIm: [Float]
    private(set) var blocksUsed = 0
    private var mic: [Float] = []
    private var ref: [Float] = []
    private var micSum: Float = 0
    private var refSum: Float = 0
    private var phase = 0

    init() {
        accRe = [Float](repeating: 0, count: Self.block + 1)
        accIm = [Float](repeating: 0, count: Self.block + 1)
        mic.reserveCapacity(Self.block)
        ref.reserveCapacity(Self.block)
    }

    mutating func add(mic micChunk: [Float], reference: [Float]) {
        let n = min(micChunk.count, reference.count)
        let scale = 1 / Float(Self.decimation)
        for i in 0..<n {
            micSum += micChunk[i]
            refSum += reference[i]
            phase += 1
            guard phase == Self.decimation else { continue }
            mic.append(micSum * scale)
            ref.append(refSum * scale)
            micSum = 0
            refSum = 0
            phase = 0
            if mic.count == Self.block {
                accumulate()
                mic.removeAll(keepingCapacity: true)
                ref.removeAll(keepingCapacity: true)
            }
        }
    }

    private mutating func accumulate() {
        func power(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(x.count) }
        guard power(mic) >= Self.minPower, power(ref) >= Self.minPower else { return }
        let size = 2 * Self.block
        let bins = Self.block + 1
        var padded = [Float](repeating: 0, count: size)
        var ar = [Float](repeating: 0, count: bins), ai = ar, br = ar, bi = ar
        for i in 0..<Self.block { padded[i] = mic[i] }
        fft.forward(padded, re: &ar, im: &ai)
        for i in 0..<Self.block { padded[i] = ref[i] }
        fft.forward(padded, re: &br, im: &bi)
        for k in 0..<bins {
            // mic × conj(reference), whitened.
            let cr = ar[k] * br[k] + ai[k] * bi[k]
            let ci = ai[k] * br[k] - ar[k] * bi[k]
            let mag = (cr * cr + ci * ci).squareRoot()
            guard mag > 1e-20 else { continue }
            accRe[k] += cr / mag
            accIm[k] += ci / mag
        }
        blocksUsed += 1
    }

    /// The delay in 48 kHz samples (negative when the mic track is ahead), or nil when there is no clear echo.
    func lag() -> Int? {
        guard let found = peak(), found.confidence >= Self.minConfidence else { return nil }
        return found.lag
    }

    func peak() -> (lag: Int, confidence: Float)? {
        guard blocksUsed > 0 else { return nil }
        let size = 2 * Self.block
        var cc = [Float](repeating: 0, count: size)
        fft.inverse(re: accRe, im: accIm, &cc)
        var best = -Float.infinity
        var bestLag = 0
        var sum: Float = 0
        for lag in -Self.maxLag...Self.maxLag {
            let v = cc[lag >= 0 ? lag : size + lag]
            sum += v * v
            if v > best {
                best = v
                bestLag = lag
            }
        }
        let rms = (sum / Float(2 * Self.maxLag + 1)).squareRoot()
        return (bestLag * Self.decimation, best / max(rms, 1e-20))
    }
}
