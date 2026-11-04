import Foundation

/// Cleans one microphone track after the recording. Without headphones the mic also hears the call from the Mac's
/// speakers, so the other side is recorded twice, the second time late and with the room in it. This removes that
/// echo, using Mac audio as the reference, and steady background noise (fans, hum, traffic rumble).
///
/// Everything happens in 1024-sample frames (21 ms) with a 512-sample hop:
/// 1. Echo: per frequency bin an adaptive filter over the last 24 reference frames (256 ms) learns the way from the
///    speakers to the mic, and its estimate of the echo is subtracted. Two copies of the filter, as in Speex and
///    WebRTC: a background one adapts all the time, the foreground one makes the output and takes the background
///    weights only while they cancel better. Talking over the other side therefore cannot spoil the filter in use.
/// 2. What the filter leaves (speaker distortion, the room's tail) and noise are taken down per bin by a Wiener
///    gain. The noise level is the minimum of the smoothed power over the last second; the leftover echo is the
///    filter's echo estimate scaled by how much of it still reaches the output. The gain never goes below -20 dB,
///    so speech is not chopped into "musical" noise, and the lowest bins (below about 70 Hz) go 30 dB down.
///
/// The output is `latency` samples later than the input: feed the input that far ahead to keep the timeline.
/// Not thread-safe: one cleaner per track, used by one thread at a time (hence `@unchecked Sendable`).
final class MicCleaner: @unchecked Sendable {
    static let frame = 1024
    static let hop = 512
    static let partitions = 24
    /// Room in the filter before the measured delay, so a delay measured a little late still fits.
    static let headroom = 2 * hop
    static let latency = frame
    static let stepSize: Float = 0.2
    static let floorGain: Float = 0.1
    static let lowCutGain: Float = 0.03
    static let lowCutBins = 2
    static let residualOverestimate: Float = 1.5
    static let residualDecay: Float = 0.5
    static let minWindowFrames = 12
    static let minWindows = 8
    static let noiseBias: Float = 1.5

    let echo: Bool
    private let bins = MicCleaner.frame / 2 + 1
    private let fft = RealFFT(size: MicCleaner.frame)

    private let window: UnsafeMutablePointer<Float>
    private let micFrame: UnsafeMutablePointer<Float>
    private let refFrame: UnsafeMutablePointer<Float>
    private let outFrame: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let yr: UnsafeMutablePointer<Float>
    private let yi: UnsafeMutablePointer<Float>
    private let er: UnsafeMutablePointer<Float>
    private let ei: UnsafeMutablePointer<Float>
    private let br: UnsafeMutablePointer<Float>
    private let bi: UnsafeMutablePointer<Float>
    private let px: UnsafeMutablePointer<Float>
    /// Reference spectra of the last `partitions` frames; frame `l` back is in slot `(head + l) % partitions`.
    private let xr: UnsafeMutablePointer<Float>
    private let xi: UnsafeMutablePointer<Float>
    private var head = 0
    private var slots = [Int](repeating: 0, count: MicCleaner.partitions)
    /// Filter weights; lag `l` is at `l * bins`.
    private let wbr: UnsafeMutablePointer<Float>
    private let wbi: UnsafeMutablePointer<Float>
    private let wfr: UnsafeMutablePointer<Float>
    private let wfi: UnsafeMutablePointer<Float>
    private var backgroundError: Double = 0
    private var foregroundError: Double = 0
    private var pey: Double = 0
    private var pyy: Double = 1e-12
    private var leak: Float = 0.1
    private let residual: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    private let minNow: UnsafeMutablePointer<Float>
    private let mins: UnsafeMutablePointer<Float>
    private var minsCount = 0
    private var minsNext = 0
    private let noise: UnsafeMutablePointer<Float>
    private let prevClean: UnsafeMutablePointer<Float>
    private var frames = 0

    private var pendingMic: [Float] = []
    private var pendingRef: [Float] = []
    private var ready: [Float]

    init(echo: Bool) {
        self.echo = echo
        ready = [Float](repeating: 0, count: Self.hop)
        let n = Self.frame
        let k = Self.frame / 2 + 1
        let p = Self.partitions
        window = Self.allocate(n)
        micFrame = Self.allocate(n)
        refFrame = Self.allocate(n)
        outFrame = Self.allocate(n)
        scratch = Self.allocate(n)
        yr = Self.allocate(k)
        yi = Self.allocate(k)
        er = Self.allocate(k)
        ei = Self.allocate(k)
        br = Self.allocate(k)
        bi = Self.allocate(k)
        px = Self.allocate(k)
        xr = Self.allocate(p * k)
        xi = Self.allocate(p * k)
        wbr = Self.allocate(p * k)
        wbi = Self.allocate(p * k)
        wfr = Self.allocate(p * k)
        wfi = Self.allocate(p * k)
        residual = Self.allocate(k)
        smoothed = Self.allocate(k)
        minNow = Self.allocate(k, value: .infinity)
        mins = Self.allocate(Self.minWindows * k)
        noise = Self.allocate(k)
        prevClean = Self.allocate(k)
        for i in 0..<n { window[i] = Float((0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))).squareRoot()) }
    }

    deinit {
        for buffer in [
            window, micFrame, refFrame, outFrame, scratch, yr, yi, er, ei, br, bi, px, xr, xi, wbr, wbi, wfr, wfi,
            residual, smoothed, minNow, mins, noise, prevClean,
        ] { buffer.deallocate() }
    }

    private static func allocate(_ count: Int, value: Float = 0) -> UnsafeMutablePointer<Float> {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: value, count: count)
        return buffer
    }

    /// Takes mic samples and the Mac audio (mono, already shifted by the measured delay) of the same moment and
    /// returns as many cleaned samples, `latency` samples late. The reference is ignored when `echo` is off.
    func process(mic: [Float], reference: [Float]) -> [Float] {
        pendingMic += mic
        if echo { pendingRef += reference.count == mic.count ? reference : [Float](repeating: 0, count: mic.count) }
        let hops = pendingMic.count / Self.hop
        pendingMic.withUnsafeBufferPointer { m in
            pendingRef.withUnsafeBufferPointer { r in
                for h in 0..<hops {
                    step(mic: m.baseAddress! + h * Self.hop, reference: echo ? r.baseAddress! + h * Self.hop : nil)
                }
            }
        }
        pendingMic.removeFirst(hops * Self.hop)
        if echo { pendingRef.removeFirst(hops * Self.hop) }
        var out = Array(ready.prefix(mic.count))
        ready.removeFirst(out.count)
        if out.count < mic.count { out += [Float](repeating: 0, count: mic.count - out.count) }
        return out
    }

    private func step(mic: UnsafePointer<Float>, reference: UnsafePointer<Float>?) {
        let n = Self.frame
        let hop = Self.hop
        slide(micFrame, mic)
        for i in 0..<n { scratch[i] = micFrame[i] * window[i] }
        fft.forward(scratch, re: yr, im: yi)
        if let reference {
            slide(refFrame, reference)
            head = (head + Self.partitions - 1) % Self.partitions
            for i in 0..<n { scratch[i] = refFrame[i] * window[i] }
            fft.forward(scratch, re: xr + head * bins, im: xi + head * bins)
            cancelEcho()
        } else {
            er.update(from: yr, count: bins)
            ei.update(from: yi, count: bins)
        }
        suppress()
        fft.inverse(re: er, im: ei, scratch)
        for i in 0..<n { outFrame[i] += scratch[i] * window[i] }
        ready.append(contentsOf: UnsafeBufferPointer(start: outFrame, count: hop))
        outFrame.update(from: outFrame + hop, count: n - hop)
        (outFrame + n - hop).update(repeating: 0, count: hop)
    }

    private func slide(_ buffer: UnsafeMutablePointer<Float>, _ next: UnsafePointer<Float>) {
        let n = Self.frame
        let hop = Self.hop
        buffer.update(from: buffer + hop, count: n - hop)
        (buffer + n - hop).update(from: next, count: hop)
    }

    /// Leaves the foreground filter's error in `er`/`ei` and updates the leftover echo estimate. The loops run
    /// over bins inside partitions, so that memory is read in order and the compiler can vectorize them.
    private func cancelEcho() {
        let k = bins
        let p = Self.partitions
        for l in 0..<p { slots[l] = ((head + l) % p) * k }
        br.update(from: yr, count: k)
        bi.update(from: yi, count: k)
        er.update(from: yr, count: k)
        ei.update(from: yi, count: k)
        px.update(repeating: 0, count: k)
        for l in 0..<p {
            let ar = xr + slots[l], ai = xi + slots[l]
            let bwr = wbr + l * k, bwi = wbi + l * k, fwr = wfr + l * k, fwi = wfi + l * k
            for j in 0..<k {
                let a = ar[j], b = ai[j]
                px[j] += a * a + b * b
                br[j] -= bwr[j] * a - bwi[j] * b
                bi[j] -= bwr[j] * b + bwi[j] * a
                er[j] -= fwr[j] * a - fwi[j] * b
                ei[j] -= fwr[j] * b + fwi[j] * a
            }
        }
        var eb: Double = 0
        var ef: Double = 0
        var x0: Double = 0
        let newest = slots[0]
        for j in 0..<k {
            eb += Double(br[j] * br[j] + bi[j] * bi[j])
            ef += Double(er[j] * er[j] + ei[j] * ei[j])
            x0 += Double(xr[newest + j] * xr[newest + j] + xi[newest + j] * xi[newest + j])
        }
        let active = x0 > Double(Self.frame) * 1e-7 * Double(k)
        if active {
            // Clipping large errors keeps double talk from throwing the background filter far off. The step per
            // bin is normalized by the reference power in it (NLMS).
            let limit = Float(3 * max(eb / Double(k), 1e-20).squareRoot())
            let regularization = Float(Self.frame) * 1e-6
            for j in 0..<k {
                let mag = (br[j] * br[j] + bi[j] * bi[j]).squareRoot()
                let clip: Float = mag > limit ? limit / (mag + 1e-20) : 1
                let g = Self.stepSize * clip / (px[j] + regularization)
                br[j] *= g
                bi[j] *= g
            }
            for l in 0..<p {
                let ar = xr + slots[l], ai = xi + slots[l]
                let bwr = wbr + l * k, bwi = wbi + l * k
                for j in 0..<k {
                    // conj(X) × step × error
                    let a = ar[j], b = ai[j]
                    bwr[j] += a * br[j] + b * bi[j]
                    bwi[j] += a * bi[j] - b * br[j]
                }
            }
            backgroundError = 0.9 * backgroundError + 0.1 * eb
            foregroundError = 0.9 * foregroundError + 0.1 * ef
            if backgroundError < 0.75 * foregroundError {
                wfr.update(from: wbr, count: p * k)
                wfi.update(from: wbi, count: p * k)
                foregroundError = backgroundError
                er.update(from: yr, count: k)
                ei.update(from: yi, count: k)
                for l in 0..<p {
                    let ar = xr + slots[l], ai = xi + slots[l]
                    let fwr = wfr + l * k, fwi = wfi + l * k
                    for j in 0..<k {
                        let a = ar[j], b = ai[j]
                        er[j] -= fwr[j] * a - fwi[j] * b
                        ei[j] -= fwr[j] * b + fwi[j] * a
                    }
                }
            } else if backgroundError > 8 * foregroundError + 1e-9 {
                wbr.update(from: wfr, count: p * k)
                wbi.update(from: wfi, count: p * k)
                backgroundError = foregroundError
            }
        }
        // `px` now holds the power of the echo estimate, Y - E.
        for j in 0..<k {
            let dr = yr[j] - er[j], di = yi[j] - ei[j]
            px[j] = dr * dr + di * di
        }
        // How much of the echo estimate is still in the output: Speex's leak estimate, the covariance of the
        // output power with the echo estimate power over the variance of the latter.
        if active {
            var meanE: Double = 0
            var meanY: Double = 0
            for j in 0..<k {
                meanE += Double(er[j] * er[j] + ei[j] * ei[j])
                meanY += Double(px[j])
            }
            meanE /= Double(k)
            meanY /= Double(k)
            var cov: Double = 0
            var varY: Double = 0
            for j in 0..<k {
                let a = Double(er[j] * er[j] + ei[j] * ei[j]) - meanE
                let b = Double(px[j]) - meanY
                cov += a * b
                varY += b * b
            }
            pey = 0.95 * pey + 0.05 * cov
            pyy = 0.95 * pyy + 0.05 * varY
            leak = Float(min(0.5, max(0.01, pey / (pyy + 1e-20))))
        }
        for j in 0..<k { residual[j] = max(leak * px[j], Self.residualDecay * residual[j]) }
    }

    /// Wiener gain against noise and leftover echo, applied to `er`/`ei`.
    private func suppress() {
        let k = bins
        for j in 0..<k {
            let power = er[j] * er[j] + ei[j] * ei[j]
            smoothed[j] = frames == 0 ? power : 0.8 * smoothed[j] + 0.2 * power
            minNow[j] = min(minNow[j], smoothed[j])
        }
        if frames % Self.minWindowFrames == 0 {
            (mins + minsNext * k).update(from: minNow, count: k)
            minsNext = (minsNext + 1) % Self.minWindows
            minsCount = min(minsCount + 1, Self.minWindows)
            minNow.update(from: smoothed, count: k)
        }
        frames += 1
        for j in 0..<k {
            var m = minNow[j]
            for w in 0..<minsCount { m = min(m, mins[w * k + j]) }
            noise[j] = Self.noiseBias * m
        }
        for j in 0..<k {
            let power = er[j] * er[j] + ei[j] * ei[j]
            let interference = noise[j] + Self.residualOverestimate * residual[j] + 1e-20
            let snr = power / interference
            let prior = 0.98 * prevClean[j] / interference + 0.02 * max(snr - 1, 0)
            var gain = max(prior / (1 + prior), Self.floorGain)
            if j < Self.lowCutBins { gain = Self.lowCutGain }
            prevClean[j] = gain * gain * power
            er[j] *= gain
            ei[j] *= gain
        }
    }
}
