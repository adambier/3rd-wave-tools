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
        guard lines.count >= 3, lines[0].hasPrefix("W3_PROG_") else {
            throw FormatError.badMagic(expected: "3rd Wave program (.pro)", found: String(lines.first?.prefix(16) ?? ""))
        }
        version = lines[0]
        name = lines[1]
        values = try lines.dropFirst(2).enumerated().map { i, s in
            if s.contains(".") || s.contains("e") || s.contains("n") {
                guard let f = Float(s) else { throw FormatError.invalid("Line \(i + 3) of the program is not a number: \"\(s)\".") }
                return .float(f, text: s)
            }
            guard let v = Int32(s) else { throw FormatError.invalid("Line \(i + 3) of the program is not a number: \"\(s)\".") }
            return .int(v, text: s)
        }
        guard valuesPerPart > 0, oscillatorIndices.allSatisfy({ $0 < values.count }) else {
            throw FormatError.invalid("Program \"\(name)\" is too short for its declared layout (\(valuesPerPart) values per part).")
        }
    }

    public func serialized() -> Data {
        var lines = [version, name] + values.map(\.text)
        if trailingNewline { lines.append("") }
        return Data(lines.joined(separator: lineEnding).latin1Bytes)
    }

    /// Format generation number from the tag (5 for "W3_PROG_5").
    public var versionNumber: Int { Int(version.dropFirst("W3_PROG_".count)) ?? 0 }

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
