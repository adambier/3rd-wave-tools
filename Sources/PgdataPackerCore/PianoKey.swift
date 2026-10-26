import Foundation

/// A key of the 88-key piano, numbered 1 (A0) to 88 (C8), with its pitch in equal temperament
/// at A4 = 440 Hz (key 49). The Wavetables page's Listen control plays a cycle at one of these;
/// the pitch pop-up lists them by note name and key number.
public struct PianoKey: Hashable, Comparable, Identifiable, Sendable {
    /// The key's number, 1 (A0) to 88 (C8).
    public let number: Int

    public var id: Int { number }

    /// Creates the key with the given number; numbers outside 1…88 are clamped to it.
    public init(_ number: Int) {
        self.number = min(max(number, 1), 88)
    }

    /// A4 = 440 Hz, key 49.
    public static let a440 = PianoKey(49)
    /// Middle C, C4, key 40 (261.6 Hz).
    public static let middleC = PianoKey(40)
    /// A3, key 37 (220 Hz): the Listen control's default pitch. See `AudioPreview` in the app for
    /// why.
    public static let defaultPitch = PianoKey(37)

    /// The pitch in hertz: 440 × 2^((number − 49) / 12).
    public var frequency: Double { 440 * pow(2, Double(number - 49) / 12) }

    /// The note's name with its octave in scientific pitch notation: "A4", "C♯3", "B♭" is written
    /// as "A♯".
    public var name: String {
        let names = ["A", "A♯", "B", "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯"]
        let index = number - 1   // 0 = A0
        return names[index % 12] + String((index + 9) / 12)
    }

    /// The frequency for reading: "440 Hz", "261.6 Hz", "27.5 Hz" (one decimal unless the value
    /// is whole).
    public var frequencyText: String {
        let f = frequency
        let rounded = (f * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) Hz" }
        return String(format: "%.1f Hz", rounded)
    }

    /// The pop-up's line for the key: "A4 · 440 Hz" (the key number is not shown; the note and
    /// its pitch are enough, Adam, 2026-10-26).
    public var label: String { "\(name) · \(frequencyText)" }

    /// The keys in `range` that exist (1…88), in order.
    public static func keys(_ range: ClosedRange<Int>) -> [PianoKey] {
        let lo = max(range.lowerBound, 1), hi = min(range.upperBound, 88)
        guard lo <= hi else { return [] }
        return (lo...hi).map(PianoKey.init)
    }

    public static func < (lhs: PianoKey, rhs: PianoKey) -> Bool { lhs.number < rhs.number }
}
