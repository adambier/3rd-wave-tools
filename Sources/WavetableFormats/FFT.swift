import Foundation

// The spectral core behind Resampling: a radix-2 FFT for power-of-two lengths and a plain DFT for
// the rest. Adapted from ThirdWaveWT's CycleResampler (MIT, © 2026 Adam Arthur Bier), whose FFT
// this is; the plain DFT and the harmonic representation are new here.

extension Resampling {
    /// One periodic cycle as harmonics: for h ≥ 1, `re[h] + i·im[h]` is the complex amplitude a_h
    /// with x(t) = a_0 + Σ 2·Re(a_h·e^{2πi·h·t}) over one period t ∈ [0, 1); `re[0]` is the mean.
    /// For an even length n the Nyquist harmonic n/2 is a cosine with no phase, stored as half its
    /// amplitude so the same formula holds (the usual split of that bin between +n/2 and −n/2).
    struct Harmonics {
        var re: [Double]
        var im: [Double]
        /// The highest harmonic present.
        var top: Int { re.count - 1 }

        /// The harmonics of a cycle of any length ≥ 1: by FFT for a power of two, otherwise by a
        /// plain DFT (O(n²), a few milliseconds at the sizes wavetables use).
        init(of cycle: [Float]) {
            let n = cycle.count
            let top = n / 2
            var re = [Double](repeating: 0, count: top + 1)
            var im = [Double](repeating: 0, count: top + 1)
            if FFT.isPowerOfTwo(n) {
                var xr = cycle.map(Double.init), xi = [Double](repeating: 0, count: n)
                FFT.transform(&xr, &xi, inverse: false)
                for h in 0...top { re[h] = xr[h]; im[h] = xi[h] }
            } else {
                let table = FFT.unitCircle(n)
                for h in 0...top {
                    var sr = 0.0, si = 0.0, k = 0
                    for i in 0..<n {
                        let v = Double(cycle[i])
                        sr += v * table.cos[k]; si -= v * table.sin[k]   // e^{−2πi·h·i/n}
                        k += h; if k >= n { k -= n }
                    }
                    re[h] = sr; im[h] = si
                }
            }
            let scale = 1 / Double(n)
            for h in 0...top { re[h] *= scale; im[h] *= scale }
            im[0] = 0
            if n % 2 == 0 && top > 0 { re[top] /= 2; im[top] = 0 }   // Nyquist: real, split in two
            self.re = re; self.im = im
        }

        /// The cycle at `size` samples, keeping harmonics 1…`maxHarmonic` that also lie strictly
        /// below the new Nyquist (size/2), plus the mean. Inverse FFT for a power-of-two size,
        /// plain synthesis otherwise.
        func synthesize(size m: Int, maxHarmonic: Int = .max) -> [Float] {
            guard m > 0 else { return [] }
            let belowNyquist = (m - 1) / 2   // the largest h with h < m/2
            let keep = Swift.max(0, Swift.min(maxHarmonic, belowNyquist, top))
            if FFT.isPowerOfTwo(m) {
                var yr = [Double](repeating: 0, count: m), yi = [Double](repeating: 0, count: m)
                let g = Double(m)
                yr[0] = re[0] * g
                if keep >= 1 {
                    for h in 1...keep {
                        yr[h] = re[h] * g; yi[h] = im[h] * g
                        yr[m - h] = re[h] * g; yi[m - h] = -im[h] * g
                    }
                }
                FFT.transform(&yr, &yi, inverse: true)
                return yr.map { Float($0) }
            }
            let table = FFT.unitCircle(m)
            var out = [Float](repeating: 0, count: m)
            for i in 0..<m {
                var v = re[0], k = 0
                if keep >= 1 {
                    for h in 1...keep {
                        k += i; if k >= m { k -= m }   // k = h·i mod m
                        v += 2 * (re[h] * table.cos[k] - im[h] * table.sin[k])
                    }
                }
                out[i] = Float(v)
            }
            return out
        }
    }

    /// An in-place iterative radix-2 FFT, from ThirdWaveWT.
    enum FFT {
        static func isPowerOfTwo(_ n: Int) -> Bool { n > 0 && (n & (n - 1)) == 0 }

        /// cos and sin of 2π·k/n for k in 0..<n.
        static func unitCircle(_ n: Int) -> (cos: [Double], sin: [Double]) {
            let step = 2 * Double.pi / Double(n)
            return ((0..<n).map { cos(step * Double($0)) }, (0..<n).map { sin(step * Double($0)) })
        }

        /// Unnormalised forward transform; the inverse divides by n. `re.count` must be a power of two.
        static func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
            let n = re.count
            guard n > 1 else { return }
            var j = 0
            for i in 1..<n {   // bit-reversal permutation
                var bit = n >> 1
                while j & bit != 0 { j ^= bit; bit >>= 1 }
                j |= bit
                if i < j { re.swapAt(i, j); im.swapAt(i, j) }
            }
            // Butterflies; twiddles evaluated directly so error does not accumulate across stages.
            var len = 2
            let sign = inverse ? 1.0 : -1.0
            while len <= n {
                let half = len / 2
                for k in 0..<half {
                    let angle = sign * 2 * Double.pi * Double(k) / Double(len)
                    let wr = cos(angle), wi = sin(angle)
                    var a = k
                    while a < n {
                        let b = a + half
                        let vr = re[b] * wr - im[b] * wi, vi = re[b] * wi + im[b] * wr
                        re[b] = re[a] - vr; im[b] = im[a] - vi
                        re[a] += vr; im[a] += vi
                        a += len
                    }
                }
                len <<= 1
            }
            if inverse {
                let inv = 1 / Double(n)
                for i in 0..<n { re[i] *= inv; im[i] *= inv }
            }
        }
    }
}
