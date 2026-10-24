import Foundation

/// A .PRO program file: text, one value per line.
///
///     W3_PROG_5            version tag (2, 3, 4, 5 seen)
///     <program name>
///     S                    values per part (173, 174, 179, 180, 181 seen)
///     ...                  integers, then a block of floats ("%f"), then an integer tail
///
/// Part k's block starts at line index 3 + S·k; its three oscillator source ids sit at
/// offsets 3, 4, 5 within the block. The original text of every line is kept so an
/// unmodified file is rewritten byte for byte.
public struct ProgramFile: Equatable {
    public enum Value: Equatable {
        case int(Int32, text: String)
        case float(Float, text: String)

        public var text: String {
            switch self { case let .int(_, t), let .float(_, t): return t }
        }

        public var word: UInt32 {
            switch self {
            case let .int(v, _): return UInt32(bitPattern: v)
            case let .float(f, _): return f.bitPattern
            }
        }

        public var isFloat: Bool { if case .float = self { return true }; return false }

        public static func int(_ v: Int32) -> Value { .int(v, text: String(v)) }
        public static func float(_ f: Float) -> Value { .float(f, text: String(format: "%f", Double(f))) }
    }

    public var version: String
    public var name: String
    /// Every line after the name (index 0 here = line 3 of the file).
    public var values: [Value]
    public var lineEnding: String = "\n"
    public var trailingNewline: Bool = true

    public static let partCount = 4
    public static let oscillatorsPerPart = 3

    public init(version: String, name: String, values: [Value]) {
        self.version = version; self.name = name; self.values = values
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        var text = bytes.latin1
        let crlf = text.contains("\r\n")
        if crlf { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        lineEnding = crlf ? "\r\n" : "\n"
        trailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        // Stray blank lines at the end (a file ending "\n\n", or a lone "\r") are not values.
        while lines.count > 3, let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard lines.count >= 3, lines[0].hasPrefix("W3_PROG_") else {
            throw FormatError.badMagic(expected: "3rd Wave program (.pro)", found: String(lines.first?.prefix(16) ?? ""))
        }
        version = lines[0]
        name = lines[1]
        let body = Array(lines.dropFirst(2))
        // Which lines hold floats follows from the header (S, F, G, E: FORMATS.md section 3.2) when
        // it adds up. Deciding by the text ("has a '.'") is right for every file the 3rd Wave writes,
        // but a float written "1" by another tool would be packed as the integer 1's bit pattern.
        let floatRange = Self.floatRange(declaredBy: body)
        values = try body.enumerated().map { i, raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
            let isFloat = floatRange?.contains(i) ?? (s.contains(".") || s.contains("e") || s.contains("n"))
            if isFloat {
                guard let f = Float(s), f.isFinite else { throw FormatError.invalid("Line \(i + 3) of the program is not a number: \"\(s)\".") }
                return .float(f, text: s)
            }
            if let v = Int32(s) { return .int(v, text: s) }
            // A whole number written as a float ("1.000000") in an integer position.
            if let d = Double(s), d.isFinite, d == d.rounded(), abs(d) <= Double(Int32.max) { return .int(Int32(d), text: s) }
            throw FormatError.invalid("Line \(i + 3) of the program is not a whole number: \"\(s)\".")
        }
        guard valuesPerPart > 0, oscillatorIndices.allSatisfy({ $0 < values.count }) else {
            throw FormatError.invalid("Program \"\(name)\" is too short for its declared layout (\(valuesPerPart) values per part).")
        }
    }

    /// The header's S, F, G and E when they are plausible, else nil.
    static func header(_ h: [Int]) -> (s: Int, f: Int, g: Int, e: Int)? {
        guard h.count >= 4, h[0] > 0, h[0] < 1000, h[1] > 0, h[1] < 1000, h[2] >= 0, h[2] < 10_000,
              h[3] >= 0, h[3] < 1_000_000 else { return nil }
        return (h[0], h[1], h[2], h[3])
    }

    /// Indices (into the values) of the float blocks, when the header is plausible and the file is
    /// at least as long as it declares.
    private static func floatRange(declaredBy lines: [String]) -> Range<Int>? {
        guard let h = header(lines.prefix(4).map { Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 }),
              4 + 4 * h.s + 4 * h.f + h.g + 6 * h.e <= lines.count else { return nil }
        return (4 + 4 * h.s)..<(4 + 4 * h.s + 4 * h.f)
    }

    /// The number of values the header declares (4 + 4S + 4F + G + 6E), or nil when the header is
    /// implausible.
    public var declaredCount: Int? {
        guard let h = Self.header(values.prefix(4).map { if case let .int(x, _) = $0 { return Int(x) } else { return -1 } }) else { return nil }
        return 4 + 4 * h.s + 4 * h.f + h.g + 6 * h.e
    }

    /// Values beyond what the header declares. The 3rd Wave leaves the end of an old file in place
    /// when it exports onto a longer one, so such files exist; the extra values are not part of the
    /// program.
    public var excessValues: Int { max(0, values.count - (declaredCount ?? values.count)) }

    /// The program without the values beyond its declared length.
    public func trimmedToHeader() -> ProgramFile {
        var p = self
        if excessValues > 0 { p.values.removeLast(excessValues) }
        return p
    }

    public func serialized() -> Data {
        var lines = [version, name] + values.map(\.text)
        if trailingNewline { lines.append("") }
        return Data(lines.joined(separator: lineEnding).latin1Bytes)
    }

    /// Format generation number from the tag (5 for "W3_PROG_5").
    public var versionNumber: Int { Int(version.dropFirst("W3_PROG_".count)) ?? 0 }

    /// Number of float values in the float block, which starts at file line 4S + 6 (counting from 0,
    /// as `Unpacker` does): 504, 508, 520, 544 or 548 seen. Programs saved since OS 1.9 (2025) have
    /// 544, and OS 2.0d writes 548; all older ones have fewer.
    public var floatBlockCount: Int {
        let start = 4 * valuesPerPart + 4          // values index of file line 4S + 6 (0-based)
        guard valuesPerPart > 0, start < values.count else { return 0 }
        return values[start...].prefix { $0.isFloat }.count
    }

    /// Layouts seen in real files (1,843 programs: Groove Synthesis factory banks and nine
    /// third-party sets). The reader finds the oscillator sources from the values-per-part count,
    /// which is verified only for these.
    public static let knownVersions = 3...5
    public static let knownValuesPerPart: Set<Int> = [173, 174, 179, 180, 181]

    /// Why this program's layout is unfamiliar, or nil when it is one seen before.
    public var layoutWarning: String? {
        let v = Self.knownVersions.contains(versionNumber)
        let s = Self.knownValuesPerPart.contains(valuesPerPart)
        if v && s { return nil }
        var what: [String] = []
        if !v { what.append("format \(version)") }
        if !s { what.append("\(valuesPerPart) values per part") }
        return "Unfamiliar program layout (\(what.joined(separator: ", "))): the oscillator sources may be misread. Check them here and on the 3rd Wave after importing."
    }

    public var valuesPerPart: Int {
        if case let .int(v, _)? = values.first { return Int(v) }
        return 0
    }

    /// Indices into `values` of the 12 oscillator source ids, part-major.
    public var oscillatorIndices: [Int] {
        let s = valuesPerPart
        // values[0] is the file's line index 2; part k starts at line 3 + s·k → values index 1 + s·k.
        return (0..<Self.partCount).flatMap { k in (3...5).map { 1 + s * k + $0 } }
    }

    public var sourceIDs: [Int32] {
        oscillatorIndices.map { i in if case let .int(v, _) = values[i] { return v } else { return -1 } }
    }

    public var sources: [SourceRef] { sourceIDs.map(SourceRef.init(id:)) }

    /// Distinct sources in order of first appearance (part 1 osc 1 … part 4 osc 3).
    public var distinctSources: [SourceRef] {
        var seen: [SourceRef] = []
        for s in sources where !seen.contains(s) { seen.append(s) }
        return seen
    }

    public mutating func setSourceID(_ id: Int32, at slot: Int) {
        values[oscillatorIndices[slot]] = .int(id)
    }

    /// The 32-bit words the .pgdata program block stores for this program.
    public var words: [UInt32] { values.map(\.word) }
}
