import Foundation

/// A .WT wavetable file: text, one value per line.
///
///     UNAME | PNAME        table kind
///     <display name>
///     0.963237f            values as C float literals; "//" lines are comments
///
/// P tables: 16,384 values = 64 waves × 128 × (sample, delta to next sample, wrapping within
/// the wave). U tables: 131,072 values = 64 waves × 1024 samples, followed by band-limited copies
/// of the same waves at 512, 256, 128, 64, and 64 samples (see docs/FORMATS.md 5.1). The same
/// values, as little-endian float32, are what a .pgdata embeds.
public struct WavetableFile: Equatable {
    public enum Kind: String { case p = "PNAME", u = "UNAME"
        public var valueCount: Int { self == .p ? 16_384 : 131_072 }
        public var letter: String { self == .p ? "P" : "U" }
    }

    public var kind: Kind
    public var name: String { didSet { originalBytes = nil } }
    public var values: [Float] { didSet { originalBytes = nil } }
    /// Original file bytes, kept so an unmodified file is written back unchanged.
    public var originalBytes: [UInt8]?

    public init(kind: Kind, name: String, values: [Float]) {
        self.kind = kind; self.name = name; self.values = values; originalBytes = nil
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        let text = bytes.latin1.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2, let k = Kind(rawValue: lines[0].trimmingCharacters(in: .whitespaces)) else {
            throw FormatError.badMagic(expected: "3rd Wave wavetable (.wt)", found: String(lines.first?.prefix(16) ?? ""))
        }
        kind = k
        name = lines[1]
        var vals: [Float] = []
        vals.reserveCapacity(k.valueCount)
        for (i, raw) in lines.dropFirst(2).enumerated() {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("//") { continue }
            let t = s.hasSuffix("f") || s.hasSuffix("F") ? String(s.dropLast()) : s
            guard let f = Float(t), f.isFinite else { throw FormatError.invalid("Line \(i + 3) of wavetable \"\(name)\" is not a number: \"\(s)\".") }
            vals.append(f)
        }
        guard vals.count == k.valueCount else {
            throw FormatError.invalid("Wavetable \"\(name)\" has \(vals.count) values; a \(k.letter) table needs \(k.valueCount).")
        }
        values = vals
        originalBytes = bytes
    }

    /// Values as the little-endian float32 bytes a .pgdata stores.
    public var dataBytes: [UInt8] {
        var w = ByteWriter(); w.bytes.reserveCapacity(values.count * 4)
        for v in values { w.f32(v) }
        return w.bytes
    }

    /// Identity of the table's content, independent of its name and text formatting.
    public var fingerprint: UInt64 { fnv1a64(dataBytes) }

    /// The largest absolute value. The 3rd Wave's own tables stay within ±1 [observed: every
    /// factory table, and SysEx dumps from an 8M], so more suggests a damaged or unnormalised file.
    public var peak: Float { values.reduce(0) { max($0, abs($1)) } }

    public func serialized() -> Data {
        if let o = originalBytes { return Data(o) }
        var s = kind.rawValue + "\n" + name + "\n"
        s.reserveCapacity(values.count * 11)
        for v in values { s += Self.literal(v) + "f\n" }
        return Data(s.latin1Bytes)
    }

    /// Six decimals (the 3rd Wave's own "%f" style) when that reproduces the float32 exactly;
    /// otherwise the shortest text that does. Groove Synthesis's factory P tables use 12–14 digits and
    /// exponent forms ("1.38777878078e-17f"), so the 3rd Wave reads both.
    static func literal(_ v: Float) -> String {
        let six = String(format: "%f", Double(v))
        if Float(six) == v { return six }
        return "\(v)"
    }
}
