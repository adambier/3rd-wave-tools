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
public struct WavetableFile: Equatable, Sendable {
    /// The kind of wavetable, P or U; the raw value is the file's first line.
    public enum Kind: String, Sendable {
        /// A P table: PPG-style, 16,384 values, header line `PNAME`. See section 5.1 of FORMATS.md.
        case p = "PNAME"
        /// A U table: 131,072 values (the table and its mipmap chain), header line `UNAME`. See
        /// section 5.1 of FORMATS.md.
        case u = "UNAME"
        /// The number of values a table of this kind holds: 16,384 for P, 131,072 for U.
        public var valueCount: Int { self == .p ? 16_384 : 131_072 }
        /// The slot letter: "P" or "U".
        public var letter: String { self == .p ? "P" : "U" }
        /// Waves (frames) in a table: 64 for both kinds.
        public var frameCount: Int { 64 }
        /// Samples per wave: 128 for P, 1,024 for U.
        public var frameSize: Int { self == .p ? 128 : 1024 }
    }

    /// Whether this is a P or a U table.
    public var kind: Kind
    /// The table's display name, line 2. Changing it discards ``originalBytes``.
    public var name: String { didSet { originalBytes = nil } }
    /// The table's values, ``Kind/valueCount`` of them. Changing them discards ``originalBytes``.
    public var values: [Float] { didSet { originalBytes = nil } }
    /// Original file bytes, kept so an unmodified file is written back unchanged.
    public var originalBytes: [UInt8]?

    /// Creates a wavetable from its kind, name, and values.
    ///
    /// The values should number ``Kind/valueCount``; this initializer does not check.
    public init(kind: Kind, name: String, values: [Float]) {
        self.kind = kind; self.name = name; self.values = values; originalBytes = nil
    }

    /// Creates a wavetable from its waves, laying the values out as a `.wt` stores them.
    ///
    /// - For a P table, each of the 64 waves of 128 samples is stored point by point as the sample
    ///   and the difference to the next sample of the same wave (wrapping), so the differences are
    ///   computed here.
    /// - For a U table, the 64 waves of 1,024 samples are followed by `mipmapChain`: the same waves
    ///   at 512, 256, 128, 64, and 64 samples, 65,536 values in all (section 5.1 of FORMATS.md).
    ///   The 3rd Wave neither hashes nor plays the chain, but its own tables carry one, so a writer
    ///   should supply band-limited copies (WavetableFormats' `Resampling.thirdWaveMipmapChain`
    ///   makes them).
    ///
    /// - Throws: ``FormatError`` when there are not 64 waves of the kind's size, a value is not
    ///   finite, or a U table's chain does not hold 65,536 values (a P table takes none).
    public init(kind: Kind, name: String, frames: [[Float]], mipmapChain: [Float]? = nil) throws {
        guard frames.count == kind.frameCount, frames.allSatisfy({ $0.count == kind.frameSize }) else {
            throw FormatError.invalid("A \(kind.letter) table needs \(kind.frameCount) waves of \(kind.frameSize) samples; got \(frames.count) waves of \(frames.map(\.count).max() ?? 0).")
        }
        var vals: [Float] = []
        vals.reserveCapacity(kind.valueCount)
        switch kind {
        case .p:
            guard mipmapChain == nil else { throw FormatError.invalid("A P table has no mipmap chain.") }
            for f in frames { for i in f.indices { vals.append(f[i]); vals.append(f[(i + 1) % f.count] - f[i]) } }
        case .u:
            guard let chain = mipmapChain, chain.count == kind.valueCount - kind.frameCount * kind.frameSize else {
                throw FormatError.invalid("A U table needs a mipmap chain of 65,536 values after its waves (section 5.1 of FORMATS.md).")
            }
            for f in frames { vals += f }
            vals += chain
        }
        guard vals.allSatisfy(\.isFinite) else { throw FormatError.invalid("Wavetable \"\(name)\" has a value that is not a finite number.") }
        self.init(kind: kind, name: name, values: vals)
    }

    /// Creates a wavetable from the bytes a `.pgdata` embeds: its values as little-endian float32.
    /// Trailing bytes short of a whole value are ignored.
    public init(kind: Kind, name: String, dataBytes data: [UInt8]) {
        var r = ByteReader(data)
        var vals: [Float] = []; vals.reserveCapacity(data.count / 4)
        while r.remaining >= 4 { vals.append(try! r.f32()) }
        self.init(kind: kind, name: name, values: vals)
    }

    /// The table's 64 waves: for a P table its samples without their differences, for a U table its
    /// first 65,536 values (without the mipmap chain), which are also what the 3rd Wave identifies
    /// the table by. Empty when the table has fewer values than its kind needs.
    public var frames: [[Float]] {
        let n = kind.frameSize, count = kind.frameCount
        let step = kind == .p ? 2 : 1
        guard values.count >= n * count * step else { return [] }
        return (0..<count).map { f in (0..<n).map { values[(f * n + $0) * step] } }
    }

    /// A U table's mipmap chain: the 65,536 values after its waves. Nil for a P table.
    public var mipmapChain: [Float]? {
        guard kind == .u, values.count == kind.valueCount else { return nil }
        return Array(values[(kind.frameCount * kind.frameSize)...])
    }

    /// Reads a `.wt` file, with LF or CRLF line endings.
    ///
    /// - Throws: ``FormatError`` when the data is not a wavetable, a value is not a finite number,
    ///   or the number of values is wrong for the kind.
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
    ///
    /// A 64-bit FNV-1a hash of ``dataBytes``, covering every value. The 3rd Wave's own matching
    /// of U tables looks at the first 65,536 values only (section 5.1 of FORMATS.md), so two U
    /// tables that differ only in their mipmap chains have different fingerprints here.
    public var fingerprint: UInt64 { fnv1a64(dataBytes) }

    /// The largest absolute sample. The 3rd Wave's own tables stay within ±1 (seen in every
    /// factory table, and in SysEx dumps from an 8M), so more suggests a damaged or unnormalised file.
    /// A P table stores each point as a sample and the difference to the next (FORMATS.md 5.1),
    /// and a difference can reach ±2, so only the samples (the even positions) count.
    public var peak: Float {
        switch kind {
        case .u: return values.reduce(0) { max($0, abs($1)) }
        case .p: return stride(from: 0, to: values.count, by: 2).reduce(0) { max($0, abs(values[$1])) }
        }
    }

    /// The wavetable as `.wt` file data.
    ///
    /// An unmodified file read with ``init(data:)`` is written back unchanged. Otherwise each value
    /// is written with six decimals when that reproduces it exactly, and in the shortest exact form
    /// otherwise, with LF line endings.
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
