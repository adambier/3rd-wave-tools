import Foundation
#if canImport(PgdataFormats)
import PgdataFormats
#endif

// Names for WavetableWriter: the 3rd Wave's display name and file names that are safe on macOS,
// Windows, and exFAT.

extension WavetableWriter {
    /// The name a 3rd Wave `.wt` gets for `name`, and notes on what changed. Spaces and line
    /// breaks at the ends go silently; the rest is `NameField.fitted`, the one rule for names the
    /// 3rd Wave keeps (control characters become spaces, a character outside Latin-1 loses its
    /// accents when that leaves a Latin-1 letter, "Ő" to "O", and becomes "?" otherwise, and the
    /// name is cut to `NameField.displayLimit` characters), with a note for each change. An empty
    /// name becomes "Untitled".
    public static func thirdWaveName(_ name: String) -> (name: String, notes: [String]) {
        Names.thirdWave(name)
    }

    /// The range of a Tonverk tag (`_wt<N>` or `_wt<N>r`, N one of Tonverk's frame sizes) at the
    /// end of a file-name stem, or nil. For tools that must keep the tag where Tonverk reads it.
    public static func trailingTonverkTag(in stem: String) -> Range<String.Index>? {
        guard let r = stem.range(of: "_wt", options: [.backwards, .caseInsensitive]) else { return nil }
        var digits = stem[r.upperBound...]
        if digits.last == "r" || digits.last == "R" { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), tonverkFrameSizes.contains(n) else { return nil }
        return r.lowerBound..<stem.endIndex
    }

    /// Makes names fit their destination, saying what changed.
    enum Names {
        /// A name for a 3rd Wave `.wt` (its line 2), as `NameField.fitted` makes it: Latin-1 only,
        /// at most `NameField.displayLimit` characters, one line. Spaces and line breaks at the
        /// ends (common in names taken from file names) are dropped without a note; the fitting
        /// itself gets one note per change.
        static func thirdWave(_ name: String) -> (name: String, notes: [String]) {
            let fit = NameField.fitted(name.trimmingCharacters(in: .whitespacesAndNewlines))
            var out = fit.text.trimmingCharacters(in: .whitespaces)
            var notes = fit.changes.map(\.description)
            if out.isEmpty {
                out = "Untitled"
                notes.append("The table has no name, so it is called “Untitled”.")
            }
            return (out, notes)
        }

        /// A file-name stem safe on macOS, Windows, and exFAT, kept readable (see
        /// `SafeFileName.make`), with a note when the name had to change.
        static func fileStem(_ name: String) -> (stem: String, notes: [String]) {
            let s = SafeFileName.make(name)
            var notes: [String] = []
            if s != name.trimmingCharacters(in: .whitespaces) {
                notes.append("File name adjusted to be safe on macOS, Windows, and exFAT: “\(s)”.")
            }
            return (s, notes)
        }

        /// Removes a trailing Tonverk tag (`_wt<N>`, optionally followed by `r`) from a stem, so the
        /// writer's own tag is the only one. Returns the tag removed, if any.
        static func removeTonverkTag(_ stem: String) -> (stem: String, removed: String?) {
            guard let r = stem.range(of: "_wt", options: [.backwards, .caseInsensitive]) else { return (stem, nil) }
            var digits = stem[r.upperBound...]
            if digits.last == "r" || digits.last == "R" { digits = digits.dropLast() }
            // Only Tonverk's sizes count, as when reading: "KOMPLEXER_WT1" keeps its name.
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(digits), WavetableWriter.tonverkFrameSizes.contains(n) else { return (stem, nil) }
            let rest = trimEnds(String(stem[..<r.lowerBound]))
            return (rest.isEmpty ? "Untitled" : rest, String(stem[r.lowerBound...]))
        }

        /// Without leading spaces and dots (a leading dot hides a file on macOS) or trailing spaces
        /// and dots (Windows drops them).
        private static func trimEnds(_ s: String) -> String {
            var t = Substring(s)
            while let c = t.first, c == " " || c == "." { t = t.dropFirst() }
            while let c = t.last, c == " " || c == "." { t = t.dropLast() }
            return String(t)
        }
    }
}
