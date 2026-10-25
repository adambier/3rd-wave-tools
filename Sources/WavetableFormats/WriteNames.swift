import Foundation
#if canImport(PgdataFormats)
import PgdataFormats
#endif

// Names for WavetableWriter: the 3rd Wave's display name and file names that are safe on macOS,
// Windows, and exFAT.

extension WavetableWriter {
    /// Makes names fit their destination, saying what changed.
    enum Names {
        /// The most characters the 3rd Wave shows of a table's name.
        static let thirdWaveNameLimit = 31
        /// The longest file-name stem written, in UTF-8 bytes (file systems allow 255, and a suffix
        /// such as `_wt4096r.wav` follows).

        /// A name for a 3rd Wave `.wt` (its line 2): Latin-1 only, at most 31 characters, one line.
        /// A character outside Latin-1 loses its accents when that leaves a Latin-1 letter ("Ő" to
        /// "O"), and becomes "?" otherwise, as the 3rd Wave would show it.
        static func thirdWave(_ name: String) -> (name: String, notes: [String]) {
            var notes: [String] = []
            let oneLine = String(name.map { isControl($0) ? " " : $0 }).trimmingCharacters(in: .whitespaces)
            var replaced = false
            var out = ""
            for ch in oneLine {
                if ch.unicodeScalars.allSatisfy({ $0.value < 256 }) { out.append(ch); continue }
                replaced = true
                let base = String(ch).decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.value < 256 }
                out += base.isEmpty ? "?" : String(String.UnicodeScalarView(base))
            }
            if replaced {
                notes.append("Characters the 3rd Wave cannot show (outside Latin-1) were replaced: “\(oneLine)” became “\(out)”.")
            }
            if out.count > thirdWaveNameLimit {
                out = String(out.prefix(thirdWaveNameLimit)).trimmingCharacters(in: .whitespaces)
                notes.append("Name shortened to “\(out)”: the 3rd Wave shows at most \(thirdWaveNameLimit) characters.")
            }
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
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return (stem, nil) }
            let rest = trimEnds(String(stem[..<r.lowerBound]))
            return (rest.isEmpty ? "Untitled" : rest, String(stem[r.lowerBound...]))
        }

        private static func isControl(_ ch: Character) -> Bool {
            ch.isNewline || ch.unicodeScalars.contains { $0.properties.generalCategory == .control }
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
