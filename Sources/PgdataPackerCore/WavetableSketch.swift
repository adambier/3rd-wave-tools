import Foundation
#if canImport(WavetableFormats)
import WavetableFormats   // SwiftPM build; absent in the app’s single-module swiftc build
#endif

/// Reduces a wavetable to what a small picture of it needs: a few dozen frames, each a few
/// dozen values. The Wavetables page draws the result as frames stacked front to back.
public enum WavetableSketch {
    /// Up to `maxFrames` frames chosen evenly (always the first and last), each reduced to
    /// `columns` values: the sample of largest magnitude in each column's span, so a peak is
    /// never skipped, scaled to the table's own peak (1 when the table is silent). Values are
    /// within −1…1. Empty for an empty table, or when `maxFrames` or `columns` is below 1.
    public static func reduce(_ frames: [[Float]], maxFrames: Int, columns: Int) -> [[Float]] {
        guard !frames.isEmpty, maxFrames > 0, columns > 0 else { return [] }
        let chosen = pick(frames.count, upTo: maxFrames).map { frames[$0] }
        let peak = chosen.reduce(Float(0)) { m, f in f.reduce(m) { max($0, abs($1)) } }
        let scale: Float = peak > 0 ? 1 / peak : 1
        return chosen.map { reduceCycle($0, to: columns).map { $0 * scale } }
    }

    /// The indices of up to `limit` frames out of `count`, evenly spaced, the first and last
    /// among them (all of them when `count` is within `limit`).
    static func pick(_ count: Int, upTo limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        guard limit > 1 else { return [0] }
        return (0..<limit).map { i in
            Int((Double(i) * Double(count - 1) / Double(limit - 1)).rounded())
        }
    }

    /// One cycle as `columns` values: the sample of largest magnitude in each column's span
    /// (the cycle itself when it has no more samples than columns).
    static func reduceCycle(_ cycle: [Float], to columns: Int) -> [Float] {
        guard cycle.count > columns else { return cycle }
        return (0..<columns).map { c in
            let lo = cycle.count * c / columns
            let hi = max(lo + 1, cycle.count * (c + 1) / columns)
            var v: Float = 0
            for s in cycle[lo..<min(hi, cycle.count)] where abs(s) > abs(v) { v = s }
            return v
        }
    }
}

// MARK: - The cycle at one position (the preview's sweep)

public extension WavetableSketch {
    /// The cycle a table gives at one position of a sweep through it, and which stored frames
    /// it comes from. From ``cycle(at:in:interpolation:columns:)``.
    struct SweepPoint: Equatable {
        /// The cycle's values (`columns` of them at most), within the table's own range.
        public var values: [Float]
        /// The stored frame at or before the position, counted from 0.
        public var lower: Int
        /// The stored frame after it (`lower` again at a whole position, or when the table
        /// steps).
        public var upper: Int
        /// How far from `lower` towards `upper` the position lies, 0…1 (0 when `upper == lower`).
        public var fraction: Float

        /// Whether the cycle is an in-between of two stored frames.
        public var isBetween: Bool { upper != lower }
    }

    /// The cycle at `position`, 0 for the first frame to 1 for the last, through `frames`: the
    /// stored frame at a whole position; between two, a linear crossfade for `.crossfade`, a
    /// spectral blend (``spectralBlend(_:_:t:)``) for `.spectral`, and the stored frame before
    /// the position for `.none` or nil (the table steps from frame to frame, or nothing says,
    /// and a stored frame is the only certain thing to show). Each frame is first reduced to
    /// `columns` values (``reduceCycle(_:to:)``), enough for a picture, so a spectral blend of
    /// long frames stays quick. Nil for an empty table.
    static func cycle(at position: Double, in frames: [[Float]], interpolation: Interpolation?, columns: Int = 256) -> SweepPoint? {
        guard !frames.isEmpty else { return nil }
        let last = frames.count - 1
        let p = min(max(position, 0), 1) * Double(last)
        let lower = min(Int(p.rounded(.down)), last)
        let fraction = Float(p - Double(lower))
        let a = reduceCycle(frames[lower], to: columns)
        let between = interpolation == .crossfade || interpolation == .spectral
        guard between, lower < last, fraction > 0.001 else {
            return SweepPoint(values: a, lower: lower, upper: lower, fraction: 0)
        }
        let b = reduceCycle(frames[lower + 1], to: columns)
        let values = interpolation == .crossfade ? blend(a, b, t: fraction) : spectralBlend(a, b, t: fraction)
        return SweepPoint(values: values, lower: lower, upper: lower + 1, fraction: fraction)
    }

    /// The words for a sweep point, to follow a label: "frame 12 of 64", or "between frames 12
    /// and 13 (crossfade)" or "… (spectral blend)". Frames are counted from 1 for the reader.
    static func sweepWords(_ point: SweepPoint, of count: Int, interpolation: Interpolation?) -> String {
        guard point.isBetween else { return "frame \(point.lower + 1) of \(count)" }
        let how = interpolation == .spectral ? "spectral blend" : "crossfade"
        return "between frames \(point.lower + 1) and \(point.upper + 1) (\(how))"
    }
}

// MARK: - Interpolation between frames

public extension WavetableSketch {
    /// How many stored frames to draw, and how many in-between frames to put in each gap
    /// between them, within a budget of lines: with in-betweens the stored frames are capped at
    /// `storedWithBetweens` so the gaps have room, and each gap gets up to five.
    static func lineBudget(storedFrames count: Int, showsBetweens: Bool, cap: Int = 150,
                           storedAlone: Int = 64, storedWithBetweens: Int = 24) -> (stored: Int, perGap: Int) {
        let stored = max(1, min(count, showsBetweens ? storedWithBetweens : storedAlone))
        guard showsBetweens, stored > 1 else { return (stored, 0) }
        return (stored, max(0, min(5, (cap - stored) / (stored - 1))))
    }

    /// The in-between frames between each pair of neighbouring frames, `perGap` per gap, in
    /// order (gap 0's first, then gap 1's, …): linear crossfades for `.crossfade`, spectral
    /// blends (``spectralBlend(_:_:t:)``) for `.spectral`, and none for `.none` or nil (the
    /// table steps from frame to frame, or nothing says). Each in-between is paired with its
    /// position, counted in frames from the first (1.5 is halfway between frames 1 and 2). The
    /// frames must be the same length.
    static func inBetweens(_ frames: [[Float]], interpolation: Interpolation?, perGap: Int) -> [(position: Double, values: [Float])] {
        guard let mode = interpolation, mode != .none, perGap > 0, frames.count > 1 else { return [] }
        var out: [(position: Double, values: [Float])] = []
        out.reserveCapacity((frames.count - 1) * perGap)
        // For spectral blends, each frame's spectrum is taken once, not once per in-between.
        let spectra: [(magnitude: [Double], phase: [Double])] = mode == .spectral ? frames.map(spectrum) : []
        for g in 0..<(frames.count - 1) {
            for j in 1...perGap {
                let t = Float(j) / Float(perGap + 1)
                let values: [Float]
                if mode == .crossfade {
                    values = blend(frames[g], frames[g + 1], t: t)
                } else {
                    values = synthesize(blendSpectra(spectra[g], spectra[g + 1], t: t), count: frames[g].count)
                }
                out.append((Double(g) + Double(t), values))
            }
        }
        return out
    }

    /// A linear crossfade: `a` at t = 0, `b` at t = 1 (the shorter of the two sets the length).
    static func blend(_ a: [Float], _ b: [Float], t: Float) -> [Float] {
        (0..<min(a.count, b.count)).map { a[$0] + (b[$0] - a[$0]) * t }
    }

    /// A spectral blend: each harmonic's magnitude moves linearly from `a`'s to `b`'s, and its
    /// phase along the shorter arc between them. This stands in for the spectral morphs of
    /// Serum and Vital, whose exact methods are not published, so it is an approximation. Two
    /// identical cycles give that cycle back (to rounding). The cycles must be the same length.
    static func spectralBlend(_ a: [Float], _ b: [Float], t: Float) -> [Float] {
        let n = min(a.count, b.count)
        guard n > 1 else { return blend(a, b, t: t) }
        let blended = blendSpectra(spectrum(Array(a.prefix(n))), spectrum(Array(b.prefix(n))), t: t)
        return synthesize(blended, count: n)
    }

    /// The harmonics of a blend between two spectra (see ``spectralBlend(_:_:t:)``).
    static func blendSpectra(_ sa: (magnitude: [Double], phase: [Double]), _ sb: (magnitude: [Double], phase: [Double]), t: Float)
        -> (magnitude: [Double], phase: [Double]) {
        let bins = min(sa.magnitude.count, sb.magnitude.count)
        var magnitude = [Double](repeating: 0, count: bins), phase = magnitude
        let tt = Double(t)
        let silent = 1e-6
        for k in 0..<bins {
            magnitude[k] = sa.magnitude[k] + (sb.magnitude[k] - sa.magnitude[k]) * tt
            // A harmonic one frame lacks has no phase there: keep the other frame's.
            if sa.magnitude[k] < silent { phase[k] = sb.phase[k]; continue }
            if sb.magnitude[k] < silent { phase[k] = sa.phase[k]; continue }
            let d = atan2(sin(sb.phase[k] - sa.phase[k]), cos(sb.phase[k] - sa.phase[k]))
            phase[k] = sa.phase[k] + d * tt
        }
        return (magnitude, phase)
    }

    /// The real cycle of `count` samples with the given harmonics (the inverse of `spectrum`).
    static func synthesize(_ spectrum: (magnitude: [Double], phase: [Double]), count n: Int) -> [Float] {
        synthesize(magnitude: spectrum.magnitude, phase: spectrum.phase, count: n)
    }

    /// The magnitudes and phases of harmonics 0 … n/2 of a real cycle (a plain DFT: the cycles
    /// here are a few dozen values, so no FFT is needed).
    static func spectrum(_ x: [Float]) -> (magnitude: [Double], phase: [Double]) {
        let n = x.count
        let bins = n / 2 + 1
        var magnitude = [Double](repeating: 0, count: bins), phase = magnitude
        for k in 0..<bins {
            var re = 0.0, im = 0.0
            for j in 0..<n {
                let angle = 2 * Double.pi * Double(j * k) / Double(n)
                re += Double(x[j]) * cos(angle)
                im -= Double(x[j]) * sin(angle)
            }
            magnitude[k] = (re * re + im * im).squareRoot()
            phase[k] = atan2(im, re)
        }
        return (magnitude, phase)
    }

    /// The real cycle of `count` samples with the given harmonics (the inverse of `spectrum`).
    static func synthesize(magnitude: [Double], phase: [Double], count n: Int) -> [Float] {
        let bins = min(magnitude.count, phase.count)
        return (0..<n).map { j in
            var v = 0.0
            for k in 0..<bins {
                // Bins 0 and n/2 (for even n) occur once; every other harmonic has a mirror.
                let weight: Double = (k == 0 || (n % 2 == 0 && k == n / 2)) ? 1 : 2
                v += weight * magnitude[k] * cos(2 * Double.pi * Double(j * k) / Double(n) + phase[k])
            }
            return Float(v / Double(n))
        }
    }
}
