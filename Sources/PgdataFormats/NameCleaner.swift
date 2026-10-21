import Foundation

/// Proposes tidier names for programs, wavetables and multisamples. Only a proposal: the app
/// shows every change for approval. Factory wavetables are never offered for renaming.
///
/// Rules, each optional:
///  - strip a slot number at the start or end ("U48 SM OBX8 1" → "SM OBX8 1", "S010_JP8_" → "JP8",
///    "B05P003 Name" → "Name"); never one in the middle, and never if nothing would be left
///  - underscores to spaces, runs of spaces collapsed, ends trimmed
///  - title case, but only for names that are entirely upper case or entirely lower case; a name
///    that already mixes cases is left as its author wrote it. Words containing digits (JP8, OBX8)
///    and words on the keep-uppercase list (SM, FM, PWM…) stay upper case; short joining words
///    (and, of, the…) are lower case except at the start.
public struct NameCleaner: Equatable {
    public var stripSlots = true
    public var underscoresToSpaces = true
    public var titleCase = true
    public var keepUppercase: [String] = NameCleaner.defaultKeepUppercase

    public static let defaultKeepUppercase = ["SM", "FM", "AM", "PWM", "LFO", "VCO", "VCF", "VCA", "DX", "PPG",
                                              "MIDI", "EQ", "BPM", "OB", "JP", "CS", "CZ", "TB", "TR", "SH",
                                              "EP", "FX", "DJ", "UK", "USA"]
    static let minorWords: Set<String> = ["a", "an", "and", "the", "of", "in", "on", "to", "for", "with", "or", "at", "by"]

    /// Longest program name in Groove's 8M factory banks: names up to this length are known to fit.
    public static let longestFactoryName = 26
    /// Name fields in .pgdata and .bin files hold 31 characters (32 bytes with the terminator).
    public static let fieldLimit = 31

    public init() {}

    private static let slot = #"(?:[PUSpus]\d{2,3}|[Bb]\d{1,2}-?[Pp]\d{2,3})"#
    private static let prefix = try! NSRegularExpression(pattern: "^" + slot + #"(?:[ _\-:.]+)"#)
    private static let suffix = try! NSRegularExpression(pattern: #"[ _\-]+"# + slot + "$")

    public func clean(_ name: String) -> String {
        var s = name
        if stripSlots {
            var t = s
            for re in [Self.prefix, Self.suffix] {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
            if t.contains(where: { $0.isLetter || $0.isNumber }) { s = t }
        }
        if underscoresToSpaces { s = s.replacingOccurrences(of: "_", with: " ") }
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if titleCase { s = applyTitleCase(s) }
        return s
    }

    private func applyTitleCase(_ s: String) -> String {
        let hasLower = s.contains { $0.isLowercase }, hasUpper = s.contains { $0.isUppercase }
        guard hasLower != hasUpper else { return s }        // mixed case (or no letters): leave it
        let keep = Set(keepUppercase.map { $0.uppercased() })
        let words = s.split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in titleWord(w, first: i == 0, keep: keep) }.joined(separator: " ")
    }

    private func titleWord(_ w: String, first: Bool, keep: Set<String>) -> String {
        if w.contains(where: { $0.isNumber }) { return w }
        let letters = w.filter { $0.isLetter }
        if keep.contains(letters.uppercased()) { return w.uppercased() }
        if !first, Self.minorWords.contains(letters.lowercased()), letters.count == w.count { return w.lowercased() }
        // Hyphenated or slashed parts are cased separately: "DX-PPG" → "DX-PPG", "LO-FI" → "Lo-Fi".
        var out = "", part = ""
        func flush() {
            let l = part.filter { $0.isLetter }
            if keep.contains(l.uppercased()) { out += part.uppercased() }
            else {
                var done = false
                for ch in part.lowercased() {
                    if !done && ch.isLetter { out += String(ch).uppercased(); done = true } else { out.append(ch) }
                }
            }
            part = ""
        }
        for ch in w { if ch == "-" || ch == "/" { flush(); out.append(ch) } else { part.append(ch) } }
        flush()
        return out
    }
}

public extension SourceContent {
    /// The same content under another name (references have none).
    func renamed(_ name: String) -> SourceContent {
        switch self {
        case .reference: return self
        case .wavetable(var w): w.name = name; return .wavetable(w)
        case .multisample(var m): m.slotName = NameField(name); return .multisample(m)
        }
    }
}
