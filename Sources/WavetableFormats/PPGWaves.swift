import Foundation

/// The PPG's four standard waveforms, which positions 60–63 of the 3rd Wave's PPG-derived P tables
/// hold: a triangle, a narrow pulse, a square, and a sawtooth (FORMATS.md section 5.1).
///
/// The shapes here are idealised, 128 samples each, the same as the fixture generator in the
/// tests: they have not been compared sample by sample with the factory tables' waves 60–63, whose
/// exact shapes and phases may differ.
public enum PPGStandardWaves {
    /// The positions the four waves occupy in a 64-wave P table.
    public static let positions = 60...63
    /// Samples per wave.
    public static let frameSize = 128

    /// The triangle (position 60): 0 at the start, +1 a quarter of the way in, −1 at three quarters.
    public static let triangle: [Float] = wave { x in x < 0.25 ? 4 * x : (x < 0.75 ? 2 - 4 * x : 4 * x - 4) }
    /// The narrow pulse (position 61): +1 for the first eighth of the cycle, −1 for the rest.
    public static let narrowPulse: [Float] = wave { x in x < 0.125 ? 1 : -1 }
    /// The square (position 62): +1 for the first half, −1 for the second.
    public static let square: [Float] = wave { x in x < 0.5 ? 1 : -1 }
    /// The sawtooth (position 63): a ramp from −1 rising towards +1.
    public static let sawtooth: [Float] = wave { x in 2 * x - 1 }

    /// The four waves in position order (60, 61, 62, 63).
    public static var frames: [[Float]] { [triangle, narrowPulse, square, sawtooth] }

    private static func wave(_ f: (Double) -> Double) -> [Float] {
        (0..<frameSize).map { Float(f(Double($0) / Double(frameSize))) }
    }
}
