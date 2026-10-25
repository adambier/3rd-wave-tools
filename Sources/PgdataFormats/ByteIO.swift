import Foundation

/// An error reading a 3rd Wave file: the data is not the expected kind of file, ends early, or
/// is malformed.
///
/// Each case's ``description`` is a complete sentence suitable for showing to a user.
public enum FormatError: Error, CustomStringConvertible, Equatable {
    /// The data does not begin with the tag of the expected file type.
    ///
    /// `expected` names the file type (for example, "3rd Wave program (.pro)"), and `found` is the
    /// text the data begins with, empty when the data is empty.
    case badMagic(expected: String, found: String)
    /// The data ends before a field it should contain.
    ///
    /// `at` is the byte offset of the field, `need` the number of bytes the field takes, and `have`
    /// the total length of the data in bytes.
    case truncated(at: Int, need: Int, have: Int)
    /// The data is malformed in some other way; the string says how.
    case invalid(String)

    /// A sentence describing the error, for display.
    public var description: String {
        switch self {
        case let .badMagic(e, f):
            return f.isEmpty ? "Not a \(e) file: it is empty." : "Not a \(e) file: it begins with \"\(f)\"."
        case let .truncated(at, need, have):
            if have == 0 { return "The file is empty." }
            return "The file ends early: it is \(have) bytes, but at least \(at + need) were expected. It was probably cut short when it was copied or exported."
        case let .invalid(s): return s
        }
    }
}

/// Little-endian reader over a byte array.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }

    var remaining: Int { bytes.count - offset }

    func check(_ n: Int) throws {
        if n < 0 || offset + n > bytes.count {
            throw FormatError.truncated(at: offset, need: n, have: bytes.count)
        }
    }

    mutating func u8() throws -> UInt8 { try check(1); defer { offset += 1 }; return bytes[offset] }

    mutating func u16() throws -> UInt16 {
        try check(2); defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        try check(4); defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        try check(n); defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
}

/// Little-endian writer.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xff)); bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff)); bytes.append(UInt8(v >> 24))
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func put(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

/// A fixed-width, NUL-padded name field. The raw bytes are kept so a file can be rewritten
/// byte for byte even when the padding after the terminator is not all zeros.
///
/// The 3rd Wave's name fields (`char[32]` in `.pgdata` and `.bin` files) hold up to 31
/// single-byte (Latin-1) characters followed by a NUL. See section 8 of FORMATS.md.
///
/// ``fitted(_:)`` is the one rule for making any name fit such a field, and ``init(_:width:)``
/// applies it; tools that write a name for the 3rd Wave another way (the name line of a `.wt`)
/// should apply it too, so that the same name comes out the same everywhere.
public struct NameField: Equatable, Hashable {
    /// The field's bytes exactly as stored, terminator and padding included.
    public private(set) var raw: [UInt8]

    /// Creates a field from its stored bytes, kept as they are.
    public init(raw: [UInt8]) { self.raw = raw }

    /// Creates a field of `width` bytes holding `text`.
    ///
    /// The text is made to fit with ``fitted(_:)`` (composed, control characters as spaces,
    /// characters outside Latin-1 without their accents or as "?", at most ``displayLimit``
    /// characters), stored one byte per character, cut to `width` − 1 bytes so that at least one
    /// NUL follows it, and padded with NUL bytes.
    public init(_ text: String, width: Int = 32) {
        var b = Array(Self.fitted(text).text.unicodeScalars.map { UInt8($0.value) }.prefix(width - 1))
        b += [UInt8](repeating: 0, count: width - b.count)
        raw = b
    }

    /// The name: the bytes up to the first NUL, read as Latin-1.
    public var text: String {
        let end = raw.firstIndex(of: 0) ?? raw.count
        return Array(raw[..<end]).latin1
    }

    // MARK: Fitting a name

    /// The most characters a name field holds: 31, which the 3rd Wave displays in full for
    /// programs, wavetables, and multisamples. See section 8 of FORMATS.md.
    public static let displayLimit = 31

    /// One change ``fitted(_:)`` made to a name.
    ///
    /// Each case's ``description`` is a sentence about the name, for a report or a tooltip.
    public enum Change: Equatable, Hashable, Sendable, CustomStringConvertible {
        /// Line breaks, tabs, or other control characters became spaces.
        case controlCharactersReplaced
        /// Letters outside Latin-1 whose base letter is in Latin-1 lost their accents. `from`
        /// holds each such letter once, in order of first appearance, and `to` what each became,
        /// character for character ("Ő" to "O", "ź" to "z").
        case accentsRemoved(from: String, to: String)
        /// Characters outside Latin-1 with no Latin-1 base letter (an en dash, a curly quote, an
        /// emoji, a Greek letter) became "?"; `characters` holds each once, in order of first
        /// appearance.
        case replacedWithQuestionMark(characters: String)
        /// The name had `from` characters and was cut to ``displayLimit``, giving `to` (without
        /// any space the cut left at the end).
        case shortened(from: Int, to: String)

        /// The change as a sentence: "Name shortened to “…”: …".
        public var description: String {
            switch self {
            case .controlCharactersReplaced:
                return "Line breaks and other control characters in the name are written as spaces."
            case let .accentsRemoved(from, to):
                let pairs = zip(from, to).map { "\u{201C}\($0)\u{201D} → \u{201C}\($1)\u{201D}" }.joined(separator: ", ")
                return "\(from.count == 1 ? "A letter" : "Letters") the 3rd Wave's name fields cannot hold (outside Latin-1) \(from.count == 1 ? "loses its" : "lose their") accents: \(pairs)."
            case let .replacedWithQuestionMark(chars):
                let list = chars.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
                return "\(chars.count == 1 ? "A character" : "Characters") the 3rd Wave's name fields cannot hold (outside Latin-1) \(chars.count == 1 ? "is" : "are") written as \u{201C}?\u{201D}: \(list)."
            case let .shortened(from, to):
                return "Name shortened to \u{201C}\(to)\u{201D}: it has \(from) characters, and the 3rd Wave's name fields hold \(displayLimit)."
            }
        }
    }

    /// The name as the 3rd Wave's name fields can hold it, and what changed to get there.
    ///
    /// The name is composed first, so that "e" plus a combining accent (as macOS file names store
    /// "é") becomes the Latin-1 letter. Then, character by character: a line break, tab, or other
    /// control character becomes a space; a character outside Latin-1 loses its accents when a
    /// Latin-1 letter is left ("Ő" to "O", "ź" to "z") and becomes "?" otherwise (an en dash, a
    /// curly quote, an emoji); everything else is kept. Finally the name is cut to
    /// ``displayLimit`` characters, dropping any space the cut leaves at the end. Spaces at the
    /// ends are otherwise kept, and an empty name stays empty.
    ///
    /// The result holds only Latin-1 characters, so it is stored one byte each and read back
    /// unchanged. `changes` is empty when the name fits as it is.
    public static func fitted(_ name: String) -> (text: String, changes: [Change]) {
        var changes: [Change] = []
        var out = ""
        var controls = false
        var accentFrom = "", accentTo = "", questioned = ""
        for ch in name.precomposedStringWithCanonicalMapping {
            if ch.isNewline || ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                controls = true
                out.append(" ")
                continue
            }
            if ch.unicodeScalars.allSatisfy({ $0.value < 256 }) { out.append(ch); continue }
            let base = String(ch).decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.value < 256 }
            if base.isEmpty {
                out.append("?")
                if !questioned.contains(ch) { questioned.append(ch) }
            } else {
                let kept = String(String.UnicodeScalarView(base))
                out += kept
                if !accentFrom.contains(ch) { accentFrom.append(ch); accentTo += kept }
            }
        }
        if controls { changes.append(.controlCharactersReplaced) }
        if !accentFrom.isEmpty { changes.append(.accentsRemoved(from: accentFrom, to: accentTo)) }
        if !questioned.isEmpty { changes.append(.replacedWithQuestionMark(characters: questioned)) }
        let count = out.count
        if count > displayLimit {
            var cut = Substring(out.prefix(displayLimit))
            while let last = cut.last, last.isWhitespace { cut = cut.dropLast() }
            out = String(cut)
            changes.append(.shortened(from: count, to: out))
        }
        return (out, changes)
    }
}

extension Array where Element == UInt8 {
    /// Latin-1 decode (the 3rd Wave's files are single-byte text).
    var latin1: String { String(self.map { Character(Unicode.Scalar($0)) }) }
}

extension String {
    /// The bytes of a whole text file (`.pro`, `.wt`): composed first, so an accent stored as a
    /// separate combining mark (as in macOS file names) becomes the Latin-1 letter rather than
    /// "?". A name meant for the 3rd Wave is fitted with `NameField.fitted` before it gets here,
    /// so the "?" is a last resort for text that never went through it.
    var latin1Bytes: [UInt8] { precomposedStringWithCanonicalMapping.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") } }
}

/// Returns the 64-bit FNV-1a hash of `bytes`, used to fingerprint wavetable and multisample
/// content.
public func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
    return h
}
