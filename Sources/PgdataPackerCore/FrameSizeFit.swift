import Foundation

/// An aid for choosing a frame size the file leaves open: how well each candidate size fits the
/// samples, judged by how alike neighbouring frames are at that size. The frames of a wavetable
/// change little from one to the next, so at the right size frame k + 1 is close to frame k,
/// and much closer than the two halves of a frame are to each other. At a size that is too
/// small a "frame" is a fragment of the cycle, and a smooth cycle is about as like itself a
/// fragment later as half a fragment later; at a multiple of the right size the frames are
/// alike, but no more alike than at the right size. This is a heuristic: it is shown as
/// "likely", and assumed only when nothing states a size (`ConvertPlan.Item.frameSize`); a
/// table whose frames differ sharply (a bank of unrelated frames) fits no size well.
public enum FrameSizeFit {
    /// How a candidate size fits.
    public struct Rating: Equatable {
        /// Samples per frame.
        public var size: Int
        /// The mean difference between each sample and the one a frame later, as a fraction of
        /// the signal's mean level: 0 when every frame repeats the one before it; about 1 or
        /// more when neighbouring frames are unrelated.
        public var difference: Float
        /// The same difference half a frame later, for comparison: large at the right size
        /// (the two halves of a cycle differ), close to `difference` at a size that is too
        /// small or too large.
        public var halfDifference: Float
        /// Whether this size reads as a cycle length: the frames are alike (`difference` at most
        /// 0.5) and much more alike than half-frames (at most half of `halfDifference`).
        public var isPlausible: Bool {
            difference <= FrameSizeFit.plausibleBelow && difference <= halfDifference * FrameSizeFit.halfRatio
        }
        /// Creates a rating.
        public init(size: Int, difference: Float, halfDifference: Float) {
            self.size = size; self.difference = difference; self.halfDifference = halfDifference
        }
    }

    /// What the ratings say, in one word for the user.
    public enum Verdict: Equatable {
        /// One size stands out: the smallest plausible one.
        case likely(Int)
        /// The sizes fit about equally (none well, or all alike): nothing to prefer.
        case tie
        /// Nothing to say: no candidates, or too few samples to compare frames.
        case unclear
    }

    /// Differences at or below this count as plausible.
    static let plausibleBelow: Float = 0.5
    /// A plausible size's frames must be at most this fraction as different as its half-frames.
    static let halfRatio: Float = 0.5
    /// Differences within this fraction of each other count as equal.
    static let tieWithin: Float = 0.2

    /// Rates each size: see ``Rating/difference``. A size that does not divide the samples
    /// into at least two frames is left out.
    public static func rate(_ samples: [Float], sizes: [Int]) -> [Rating] {
        let count = samples.count
        var level: Float = 0
        for s in samples { level += abs(s) }
        level /= Float(max(count, 1))
        guard level > 0 else { return [] }
        func meanDifference(lag: Int) -> Float {
            let compared = count - lag
            guard compared > 0 else { return 0 }
            var sum: Float = 0
            for i in 0..<compared { sum += abs(samples[i + lag] - samples[i]) }
            return sum / Float(compared) / level
        }
        return sizes.compactMap { (n: Int) -> Rating? in
            guard n > 1, count >= 2 * n else { return nil }
            return Rating(size: n, difference: meanDifference(lag: n), halfDifference: meanDifference(lag: n / 2))
        }
    }

    /// The verdict for a set of candidate sizes (see ``Verdict``).
    public static func verdict(_ samples: [Float], sizes: [Int]) -> Verdict {
        let ratings = rate(samples, sizes: sizes)
        guard ratings.count > 1 else { return ratings.count == 1 && ratings[0].isPlausible ? .likely(ratings[0].size) : .unclear }
        let plausible = ratings.filter(\.isPlausible)
        if let best = plausible.min(by: { $0.size < $1.size }) { return .likely(best.size) }
        let lo = ratings.map(\.difference).min() ?? 0, hi = ratings.map(\.difference).max() ?? 0
        return hi <= lo * (1 + tieWithin) ? .tie : .unclear
    }

    /// The size the verdict prefers, if any.
    public static func likelySize(_ verdict: Verdict) -> Int? {
        if case .likely(let n) = verdict { return n }
        return nil
    }
}
