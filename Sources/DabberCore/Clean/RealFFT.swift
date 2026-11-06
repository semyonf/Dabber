import Foundation

/// FFT of a real signal of a power-of-two size, through a complex FFT of half the size. Plain Swift, so the
/// cleaner computes the same numbers everywhere. Not thread-safe: it keeps scratch buffers.
///
/// Forward gives the bins 0...size/2 without scaling (like numpy's `rfft`); `inverse` undoes it exactly.
final class RealFFT {
    let size: Int
    let bins: Int
    private let half: Int
    private let bitReverse: [Int]
    /// e^(-2πik/half), k < half/2: the twiddles of the complex FFT.
    private let twiddleRe: [Float]
    private let twiddleIm: [Float]
    /// e^(-2πik/size), k <= half: the twiddles that split the half-size result into the real spectrum.
    private let splitRe: [Float]
    private let splitIm: [Float]
    private var zr: [Float]
    private var zi: [Float]

    init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "size must be a power of two")
        let h = size / 2
        self.size = size
        half = h
        bins = h + 1
        var levels = 0
        while 1 << levels < h { levels += 1 }
        bitReverse = (0..<h).map { i in
            var r = 0
            var v = i
            for _ in 0..<levels {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            return r
        }
        twiddleRe = (0..<max(1, h / 2)).map { Float(cos(-2 * Double.pi * Double($0) / Double(h))) }
        twiddleIm = (0..<max(1, h / 2)).map { Float(sin(-2 * Double.pi * Double($0) / Double(h))) }
        splitRe = (0...h).map { Float(cos(-2 * Double.pi * Double($0) / Double(size))) }
        splitIm = (0...h).map { Float(sin(-2 * Double.pi * Double($0) / Double(size))) }
        zr = [Float](repeating: 0, count: h)
        zi = [Float](repeating: 0, count: h)
    }

    /// `input` holds `size` samples; `re` and `im` receive `bins` values.
    func forward(_ input: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let h = half
        zr.withUnsafeMutableBufferPointer { zr in
            zi.withUnsafeMutableBufferPointer { zi in
                for k in 0..<h {
                    zr[k] = input[2 * k]
                    zi[k] = input[2 * k + 1]
                }
                transform(zr.baseAddress!, zi.baseAddress!)
                for k in 0...h {
                    let a = k == h ? 0 : k
                    let b = k == 0 ? 0 : h - k
                    // Z[k] and conj(Z[h-k]); Z[h] is Z[0].
                    let zkr = zr[a], zki = zi[a]
                    let zcr = zr[b], zci = -zi[b]
                    // The spectra of the even and of the odd samples.
                    let er = 0.5 * (zkr + zcr), ei = 0.5 * (zki + zci)
                    let or = 0.5 * (zki - zci), oi = -0.5 * (zkr - zcr)
                    let c = splitRe[k], s = splitIm[k]
                    re[k] = er + c * or - s * oi
                    im[k] = ei + c * oi + s * or
                }
            }
        }
    }

    /// `re` and `im` hold `bins` values; `output` receives `size` samples.
    func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        let h = half
        zr.withUnsafeMutableBufferPointer { zr in
            zi.withUnsafeMutableBufferPointer { zi in
                for k in 0..<h {
                    let xkr = re[k], xki = im[k]
                    let xcr = re[h - k], xci = -im[h - k]
                    let fer = 0.5 * (xkr + xcr), fei = 0.5 * (xki + xci)
                    let dr = 0.5 * (xkr - xcr), di = 0.5 * (xki - xci)
                    // e^(+2πik/size) is (c, -s).
                    let c = splitRe[k], s = splitIm[k]
                    let fr = dr * c + di * s, fi = di * c - dr * s
                    zr[k] = fer - fi
                    zi[k] = -(fei + fr)
                }
                transform(zr.baseAddress!, zi.baseAddress!)
                let scale = 1 / Float(h)
                for k in 0..<h {
                    output[2 * k] = zr[k] * scale
                    output[2 * k + 1] = -zi[k] * scale
                }
            }
        }
    }

    /// In-place radix-2 complex FFT of `half` points.
    private func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        let n = half
        for i in 0..<n {
            let j = bitReverse[i]
            if j > i {
                (re[i], re[j]) = (re[j], re[i])
                (im[i], im[j]) = (im[j], im[i])
            }
        }
        twiddleRe.withUnsafeBufferPointer { wr in
            twiddleIm.withUnsafeBufferPointer { wi in
                var len = 2
                while len <= n {
                    let step = n / len
                    let h = len / 2
                    var start = 0
                    while start < n {
                        for k in 0..<h {
                            let cr = wr[k * step], ci = wi[k * step]
                            let a = start + k, b = a + h
                            let tr = re[b] * cr - im[b] * ci
                            let ti = re[b] * ci + im[b] * cr
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                        }
                        start += len
                    }
                    len <<= 1
                }
            }
        }
    }
}
