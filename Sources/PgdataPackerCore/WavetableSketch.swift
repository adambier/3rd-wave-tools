import Foundation

/// Reduces a wavetable to what a small picture of it needs: a few dozen frames, each a few
/// dozen values. The Convert page draws the result as frames stacked front to back.
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
