import Foundation

/// File names that are safe on macOS, Windows, and the FAT/exFAT file systems of USB drives and
/// SD cards (the 3rd Wave's drive among them), for any tool that writes files named after
/// programs, wavetables, or multisamples.
public enum SafeFileName {
    /// The most UTF-8 bytes a name keeps: below the 255-byte limit of common file systems, with
    /// room for a slot prefix and an extension.
    public static let byteLimit = 200

    /// `name` made safe as a file name (or a file-name stem):
    ///
    /// - `/ \ : * ? " < > |` and control characters are replaced. With `replacement`, each becomes
    ///   that character. Without it, separators (`/ \ : |`) become hyphens, quotes an apostrophe,
    ///   angle brackets parentheses, `*` and `?` are dropped, and control characters become spaces,
    ///   so the name stays readable.
    /// - Leading and trailing whitespace and dots are removed (a leading dot hides a file on macOS;
    ///   Windows drops trailing dots and spaces).
    /// - The name is cut to ``byteLimit`` UTF-8 bytes.
    /// - A reserved Windows device name (CON, PRN, AUX, NUL, COM1–9, LPT1–9, with any extension)
    ///   gets an underscore before its first dot.
    /// - An empty result becomes "Untitled".
    public static func make(_ name: String, replacement: Character? = nil) -> String {
        var s = ""
        for ch in name {
            let control = ch.isNewline || ch.unicodeScalars.contains { $0.properties.generalCategory == .control }
            if let r = replacement {
                s.append(control || "/\\:*?\"<>|".contains(ch) ? r : ch)
                continue
            }
            switch ch {
            case "/", "\\", "|", ":": s += "-"
            case "*", "?": continue
            case "\"": s += "'"
            case "<": s += "("
            case ">": s += ")"
            default: s.append(control ? " " : ch)
            }
        }
        s = trimEnds(s)
        while s.utf8.count > byteLimit { s.removeLast() }
        s = trimEnds(s)
        if s.isEmpty { return "Untitled" }
        // Windows reserves these device names with any extension ("NUL.txt" is NUL).
        let device = String(s.prefix { $0 != "." })
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(device.trimmingCharacters(in: .whitespaces).uppercased()) {
            s = device + "_" + s.dropFirst(device.count)
        }
        return s
    }

    /// Without leading or trailing whitespace and dots.
    private static func trimEnds(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }
}
