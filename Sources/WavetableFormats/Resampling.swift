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
    /// used. Tests on a 3rd Wave synth (FORMATS.md section 5.1) found that it
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
