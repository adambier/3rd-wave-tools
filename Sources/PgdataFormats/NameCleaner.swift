import Foundation

/// Proposes tidier names for programs, wavetables, and multisamples. Only a proposal: the app
/// shows every change for approval. Factory wavetables are never offered for renaming.
///
/// Rules, each optional:
///  - strip a slot number at the start or end ("U48 SM OBX8 1" → "SM OBX8 1", "S010_JP8_" → "JP8",
///    "B5-P003 Name" → "Name"; the file-name form B05P003 too); never one in the middle, and never if nothing would be left
///  - underscores to spaces, runs of spaces collapsed, ends trimmed
///  - title case, but only for names that are entirely upper case or entirely lower case; a name
///    that already mixes cases is left as its author wrote it. Words containing digits (JP8, OBX8)
///    are kept as they are; words with no vowels (A E I O U Y) are taken to be acronyms and written
///    in capitals (SM, PWM, DX, PPG); words on the fixed-spellings list are written exactly as listed
///    (LFO, MIDI, LoFi…); short joining words (and, of, the…) are lower case except at the start.
public struct NameCleaner: Equatable {
    public var stripSlots = true
    public var underscoresToSpaces = true
    public var titleCase = true
    /// Words written exactly as listed, whatever case they arrive in ("LOFI" → "LoFi").
    public var fixedSpellings: [String] = NameCleaner.defaultFixedSpellings

    /// Words without vowels are already treated as acronyms, so this lists only the ones with vowels.
    public static let defaultFixedSpellings = ["AM", "LFO", "VCO", "VCA", "MIDI", "EQ", "OB", "EP", "UK", "USA",
                                               "LoFi", "HiFi"]
    static let minorWords: Set<String> = ["a", "an", "and", "the", "of", "in", "on", "to", "for", "with", "or", "at", "by"]

    /// Name fields in .pgdata and .bin files hold 31 characters (32 bytes with the terminator). The
    /// 3rd Wave displays all 31 for programs, wavetables, and multisamples [verified on an 8M, T6].
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
        var keep: [String: String] = [:]
        for w in fixedSpellings where !w.isEmpty { keep[w.lowercased()] = w }
        let words = s.split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in titleWord(w, first: i == 0, keep: keep) }.joined(separator: " ")
    }

    /// Rewrites the letters of `w` with those of `spelling`, keeping any punctuation around them.
    private func respell(_ w: String, _ spelling: String) -> String {
        var it = spelling.makeIterator()
        return String(w.map { $0.isLetter ? (it.next() ?? $0) : $0 })
    }

    /// No vowels (Y counts as one, so SYNTH, RHYTHM, and FLY are words): an acronym such as PWM or PPG.
    static func isAcronym(_ letters: String) -> Bool {
        !letters.isEmpty && !letters.lowercased().contains { "aeiouy".contains($0) }
    }

    private func titleWord(_ w: String, first: Bool, keep: [String: String]) -> String {
        if w.contains(where: { $0.isNumber }) { return w }
        let letters = w.filter { $0.isLetter }
        if let s = keep[letters.lowercased()] { return respell(w, s) }
        if Self.isAcronym(letters) { return w.uppercased() }
        if !first, Self.minorWords.contains(letters.lowercased()), letters.count == w.count { return w.lowercased() }
        // Hyphenated or slashed parts are cased separately: "DX-PPG" → "DX-PPG", "LO-FI" → "Lo-Fi".
        var out = "", part = ""
        func flush() {
            let l = part.filter { $0.isLetter }
            if let sp = keep[l.lowercased()] { out += respell(part, sp) }
            else if Self.isAcronym(l) { out += part.uppercased() }
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
