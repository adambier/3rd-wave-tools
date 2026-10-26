import Foundation

/// Changes a wavetable's frame size and frame count.
///
/// Frame sizes change spectrally: each cycle is taken apart into its harmonics and put back
/// together at the new size, which is exact for a periodic cycle (adapted from ThirdWaveWT's
/// `CycleResampler`, MIT, © 2026 Adam Arthur Bier). Power-of-two sizes use an FFT; other sizes
/// (a Serum sidecar allows any size from 32 to 9,999, e.g. 600) are analysed with Bluestein's
/// algorithm, which is as fast.
public enum Resampling {
    /// Resizes one periodic cycle to `size` samples, band-limited (exact for a periodic cycle).
    ///
    /// Growing a cycle keeps every harmonic, so the original samples are reproduced exactly at
    /// their positions and the new ones are the values of the band-limited waveform in between;
    /// the old Nyquist component (a cosine) is split evenly between its two bins, the standard
    /// resolution. Shrinking a cycle drops the harmonics above the new Nyquist (`size`/2) and keeps
    /// the cosine part of the one at it, which is what the samples at the new positions hold; so
    /// growing a cycle and shrinking it again returns the original samples exactly, and shrinking
    /// a cycle gives the samples of its band-limited waveform at the new positions.
    /// Returns the cycle unchanged when it already has `size` samples, an empty array when `size`
    /// is 0 or less, and silence when the cycle is empty.
    public static func resizeCycle(_ cycle: [Float], to size: Int) -> [Float] {
        guard size > 0 else { return [] }
        guard cycle.count != size else { return cycle }
        guard !cycle.isEmpty else { return [Float](repeating: 0, count: size) }
        return Harmonics(of: cycle).synthesize(size: size)
    }

    /// Resizes one periodic cycle to `size` samples keeping only its mean and harmonics
    /// 1…`maxHarmonic` (and, as ``resizeCycle(_:to:)`` does, the cosine part of a harmonic
    /// exactly at the new Nyquist when `size` is even and `maxHarmonic` allows it).
    ///
    /// This is a cycle as a band-limited oscillator would play it: at a pitch of f Hz and a
    /// sample rate of r Hz, every harmonic above r / (2f) would alias, so a player keeps
    /// `maxHarmonic` = ⌊r / (2f)⌋ − 1 or so. A `maxHarmonic` of 0 leaves the mean alone, and a
    /// negative one is treated as 0. Returns an empty array when `size` is 0 or less, and silence
    /// when the cycle is empty.
    public static func bandLimitedCycle(_ cycle: [Float], to size: Int, maxHarmonic: Int) -> [Float] {
        guard size > 0 else { return [] }
        guard !cycle.isEmpty else { return [Float](repeating: 0, count: size) }
        return Harmonics(of: cycle).synthesize(size: size, maxHarmonic: Swift.max(0, maxHarmonic))
    }

    /// A blend of two cycles by spectrum: each harmonic's amplitude moves linearly from `a`'s
    /// to `b`'s (`t` = 0 gives `a`, 1 gives `b`) and its phase along the shorter arc between
    /// them; a harmonic one cycle lacks keeps the other's phase. This stands in for the spectral
    /// morphs of Serum and Vital, whose exact methods are not published, so it is an
    /// approximation; two identical cycles give that cycle back (to rounding). The cycles should
    /// be the same length; the result has the shorter one's. Empty when either is empty.
    public static func spectralBlend(_ a: [Float], _ b: [Float], t: Float) -> [Float] {
        let n = Swift.min(a.count, b.count)
        guard n > 0 else { return [] }
        return CycleSpectrum.blend(CycleSpectrum(Array(a.prefix(n))), CycleSpectrum(Array(b.prefix(n))), t: t).cycle(size: n)
    }

    /// One cycle as its harmonics, for blending cycles by spectrum (``spectralBlend(_:_:t:)``
    /// does one blend; taking each frame's spectrum once, then blending pairs, is quicker when
    /// several blends are wanted between the same frames) and for synthesising it again at any
    /// size, band-limited.
    public struct CycleSpectrum {
        var harmonics: Harmonics

        /// The spectrum of a cycle of at least one sample.
        public init(_ cycle: [Float]) {
            harmonics = Harmonics(of: cycle.isEmpty ? [0] : cycle)
        }

        /// The blend described under ``Resampling/spectralBlend(_:_:t:)``, over the harmonics
        /// both have.
        public static func blend(_ a: CycleSpectrum, _ b: CycleSpectrum, t: Float) -> CycleSpectrum {
            let bins = Swift.min(a.harmonics.re.count, b.harmonics.re.count)
            var re = [Double](repeating: 0, count: bins), im = re
            let tt = Double(t)
            // Below this an amplitude counts as absent (amplitudes here are normalised; a cycle
            // with values within ±1 has harmonics within ±1).
            let silent = 1e-7
            for k in 0..<bins {
                let ar = a.harmonics.re[k], ai = a.harmonics.im[k], br = b.harmonics.re[k], bi = b.harmonics.im[k]
                let am = (ar * ar + ai * ai).squareRoot(), bm = (br * br + bi * bi).squareRoot()
                let magnitude = am + (bm - am) * tt
                let phase: Double
                if am < silent { phase = atan2(bi, br) }
                else if bm < silent { phase = atan2(ai, ar) }
                else {
                    let pa = atan2(ai, ar), pb = atan2(bi, br)
                    phase = pa + atan2(sin(pb - pa), cos(pb - pa)) * tt
                }
                re[k] = magnitude * cos(phase); im[k] = magnitude * sin(phase)
            }
            im[0] = 0
            var out = a
            out.harmonics = Harmonics(re: re, im: im)
            return out
        }

        /// The cycle at `size` samples, keeping harmonics up to `maxHarmonic` that lie below the
        /// new Nyquist (as ``Resampling/bandLimitedCycle(_:to:maxHarmonic:)`` does).
        public func cycle(size: Int, maxHarmonic: Int = .max) -> [Float] {
            guard size > 0 else { return [] }
            return harmonics.synthesize(size: size, maxHarmonic: Swift.max(0, maxHarmonic))
        }
    }

    /// Brings a table to `count` frames by the given policy; unchanged when it already has them.
    ///
    /// With `count` m and n source frames, output frame i sits at source position
    /// p = i·(n−1)/(m−1), so the first and last frames are always kept:
    /// - ``FrameCountPolicy/pickEvenly`` takes source frame round(p). With m > n this repeats
    ///   frames (no new waveforms are made).
    /// - ``FrameCountPolicy/interpolate`` crossfades linearly between frames ⌊p⌋ and ⌊p⌋+1 by the
    ///   fractional part of p.
    ///
    /// With m = 1 the result is the first frame; with n = 1 that frame is repeated m times. An
    /// empty table, or a `count` of 0 or less, gives an empty table. The frames are expected to
    /// be of equal length (crossfading pairs them sample by sample).
    public static func changeFrameCount(_ frames: [[Float]], to count: Int, policy: FrameCountPolicy) -> [[Float]] {
        let n = frames.count
        guard count != n else { return frames }
        guard count > 0, n > 0 else { return [] }
        guard count > 1 else { return [frames[0]] }
        guard n > 1 else { return [[Float]](repeating: frames[0], count: count) }
        return (0..<count).map { i in
            let p = Double(i) * Double(n - 1) / Double(count - 1)
            switch policy {
            case .pickEvenly:
                return frames[Swift.min(n - 1, Int(p.rounded()))]
            case .interpolate:
                let lo = Swift.min(n - 1, Int(p.rounded(.down)))
                let t = Float(p - Double(lo))
                guard lo < n - 1, t > 0 else { return frames[lo] }
                let a = frames[lo], b = frames[lo + 1]
                return (0..<Swift.min(a.count, b.count)).map { a[$0] + (b[$0] - a[$0]) * t }
            }
        }
    }

    /// The 3rd Wave U table mipmap chain for 64 frames of 1,024 samples: the same frames at 512,
    /// 256, 128, 64, and 64 samples, band-limited (65,536 values). See FORMATS.md section 5.1.
    ///
    /// The levels follow one after another, each holding every frame in order:
    /// - **512 and 256:** a band-limited resize (``resizeCycle(_:to:)``), keeping every harmonic
    ///   below the level's Nyquist.
    /// - **128 and 64:** low-passed at about 3/8 of the level's Nyquist, keeping harmonics 1–24 and
    ///   1–12 respectively, then resized.
    /// - **The final 64:** harmonics 1–4 only.
    ///
    /// The filters are ideal (spectral) cut-offs. The factory chains show cut-offs of about these
    /// proportions, but their exact filter is not known: they carry small gain changes and, in
    /// tables made from recorded audio, a constant phase shift, so a real filter was presumably
    /// used. Tests on the 3rd Wave (FORMATS.md section 5.1) found that it
    /// identifies a table by its first 65,536 values only and plays a table the same with its chain
    /// zeroed, so the chain does not need to match the factory's; it is written because the 3rd
    /// Wave's own tables carry one. A low-pass can raise a frame's peak (Gibbs overshoot); a level whose
    /// peak would exceed the table's own is scaled back to it, so a table within ±1 has a chain
    /// within ±1.
    ///
    /// Other frame counts and sizes are accepted (the result then holds count × 1,024 values).
    public static func thirdWaveMipmapChain(_ frames: [[Float]]) -> [Float] {
        let harmonics = frames.map { $0.isEmpty ? Harmonics(of: [0]) : Harmonics(of: $0) }
        let tablePeak = frames.reduce(Float(0)) { m, f in f.reduce(m) { Swift.max($0, abs($1)) } }
        var out: [Float] = []
        out.reserveCapacity(frames.count * mipmapLevels.reduce(0) { $0 + $1.size })
        for level in mipmapLevels {
            var values = harmonics.flatMap { $0.synthesize(size: level.size, maxHarmonic: level.maxHarmonic) }
            let peak = values.reduce(Float(0)) { Swift.max($0, abs($1)) }
            if peak > tablePeak * (1 + 1e-5), peak > 0 {   // ignore rounding-level differences
                let g = tablePeak / peak
                for i in values.indices { values[i] *= g }
            }
            out += values
        }
        return out
    }

    /// The chain's levels: samples per frame and the highest harmonic kept.
    static let mipmapLevels: [(size: Int, maxHarmonic: Int)] = [
        (512, .max), (256, .max), (128, 24), (64, 12), (64, 4),
    ]
}
