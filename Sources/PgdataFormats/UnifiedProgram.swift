import Foundation

/// A .pgdata unified program: a program plus the wavetables and multisamples it uses.
///
///     char[16]   "W3_UNIPROG_1" + NUL padding
///     u8         N, number of sources
///     N ×        u8 index (0…N-1), u8 type (0 P, 1 U, 2 analog, 4 S), u16 source id
///     N ×        u8 type, u8 index, u8 hasData, then if hasData:
///                  P/U: char[32] name, float32 × 16,384 (P) or 131,072 (U)
///                  S:   u8 count, char[32] slot name, samples (multisample v5 layout)
///     char[32]   program name
///     u32 ×      one word per .pro value from line 3 on (int32 or float32), to the declared length;
///                the 12 oscillator source ids are replaced by indices into the source table.
///
/// Read and rewritten byte for byte: Groove Synthesis's factory banks (38), its sample library
/// (45), and 138 third-party files. See section 4 of FORMATS.md.
public struct UnifiedProgram: Equatable {
    /// The data a source record carries.
    public enum Payload: Equatable {
        /// No data: the source is listed only, and the 3rd Wave plays whatever is in that slot (or,
        /// for an analog wave, the built-in wave).
        case none
        /// An embedded wavetable: its name and its values as little-endian 32-bit floats, 16,384
        /// for a P table or 131,072 for a U table (the bytes of ``WavetableFile/dataBytes``).
        case wavetable(name: NameField, data: [UInt8])
        /// An embedded multisample.
        case multisample(Multisample)
    }

    /// One entry of the source table, with its record.
    public struct Source: Equatable {
        /// The slot the entry names.
        public var ref: SourceRef
        /// The data the entry carries, if any.
        public var payload: Payload
        /// Whether the entry carries data.
        public var hasData: Bool { payload != .none }
    }

    /// The file's first 16 bytes, "W3_UNIPROG_1" padded with NUL bytes, kept as read.
    public var magic: [UInt8]
    /// The source table, in order: the oscillator values in ``words`` are indices into it.
    public var sources: [Source]
    /// The program name.
    public var programName: NameField
    /// Program words with oscillator ids already replaced by source-table indices.
    public var words: [UInt32]
    /// The number of bytes after the program's declared end when the file was read (left over
    /// when the 3rd Wave exported onto a longer file). Not written back.
    public var trailingBytes = 0

    /// The tag a `.pgdata` begins with: "W3_UNIPROG_1".
    public static let magicText = "W3_UNIPROG_1"

    /// Creates a unified program from its source table, program name, and program words.
    ///
    /// The oscillator words must already hold indices into `sources`. ``Packer/pack(_:content:)``
    /// builds one from a program.
    public init(sources: [Source], programName: NameField, words: [UInt32]) {
        magic = NameField(Self.magicText, width: 16).raw
        self.sources = sources; self.programName = programName; self.words = words
    }

    /// Reads a `.pgdata` file.
    ///
    /// Bytes after the program's declared length are dropped and counted in ``trailingBytes``.
    ///
    /// - Throws: ``FormatError`` when the data is not a unified program, ends early, or does not
    ///   agree with itself (for example, a source record that does not match the source table).
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 17 else {
            throw FormatError.truncated(at: 0, need: 17, have: bytes.count)
        }
        magic = Array(bytes[0..<16])
        guard NameField(raw: magic).text == Self.magicText else {
            throw FormatError.badMagic(expected: "3rd Wave unified program (.pgdata)", found: String(magic.latin1.prefix(12)))
        }
        var r = ByteReader(bytes, offset: 16)
        let n = Int(try r.u8())
        var refs: [SourceRef] = []
        for k in 0..<n {
            let idx = try r.u8(), type = try r.u8(), id = try r.u16()
            guard idx == k else { throw FormatError.invalid("Source table entry \(k) is numbered \(idx).") }
            let ref = SourceRef(id: Int32(id))
            guard ref.typeCode == type else {
                throw FormatError.invalid("Source \(k) has type \(type) but id \(id) (\(ref.label)) belongs to type \(ref.typeCode).")
            }
            refs.append(ref)
        }
        var out: [Source] = []
        for k in 0..<n {
            let type = try r.u8(), idx = try r.u8(), has = try r.u8()
            guard idx == k, type == refs[k].typeCode else {
                throw FormatError.invalid("Source record \(k) does not match the source table (type \(type), index \(idx)).")
            }
            var payload = Payload.none
            if has != 0 {
                switch refs[k] {
                case .p, .u:
                    let name = NameField(raw: try r.take(32))
                    let count = refs[k].isP ? 16_384 : 131_072
                    payload = .wavetable(name: name, data: try r.take(count * 4))
                case .s:
                    payload = .multisample(try Multisample.readBody(&r))
                default:
                    throw FormatError.invalid("Source \(refs[k].label) claims to carry data, which this app does not understand.")
                }
            }
            out.append(Source(ref: refs[k], payload: payload))
        }
        sources = out
        programName = NameField(raw: try r.take(32))
        // The first four words (S, F, G, E) say how long the program is. When they are plausible and
        // the file runs on past that, the rest is left over from a longer file it was exported onto
        // (FORMATS.md section 7) and is not part of the program.
        var count = r.remaining / 4
        if r.remaining >= 16 {
            var peek = r
            let h = try (0..<4).map { _ in Int(Int32(bitPattern: try peek.u32())) }
            if let h = ProgramFile.header(h) {
                let declared = 4 + 4 * h.s + 4 * h.f + h.g + 6 * h.e
                if declared < count { count = declared; trailingBytes = r.remaining - 4 * declared }
            }
        }
        guard trailingBytes > 0 || r.remaining % 4 == 0 else {
            throw FormatError.invalid("Program data is \(r.remaining) bytes, not a whole number of values; the file may be truncated.")
        }
        var ws: [UInt32] = []
        ws.reserveCapacity(count)
        for _ in 0..<count { ws.append(try r.u32()) }
        words = ws
        // The program block must at least hold the 12 oscillator words its first word implies.
        guard valuesPerPart > 0, oscillatorWordIndices.allSatisfy({ $0 < words.count }) else {
            throw FormatError.invalid("Program \"\(programName.text)\" is too short for its declared layout (\(valuesPerPart) values per part).")
        }
    }

    /// The unified program as `.pgdata` file data.
    public func serialized() -> Data {
        var w = ByteWriter()
        w.put(magic)
        w.u8(UInt8(sources.count))
        for (k, s) in sources.enumerated() { w.u8(UInt8(k)); w.u8(s.ref.typeCode); w.u16(UInt16(truncatingIfNeeded: s.ref.id)) }
        for (k, s) in sources.enumerated() {
            w.u8(s.ref.typeCode); w.u8(UInt8(k)); w.u8(s.hasData ? 1 : 0)
            switch s.payload {
            case .none: break
            case let .wavetable(name, data): w.put(name.raw); w.put(data)
            case let .multisample(m): m.writeBody(&w)
            }
        }
        w.put(programName.raw)
        for x in words { w.u32(x) }
        return Data(w.bytes)
    }

    /// Values per part, from the program's first word.
    public var valuesPerPart: Int { words.isEmpty ? 0 : Int(Int32(bitPattern: words[0])) }

    /// Word indices of the 12 oscillator sources (same positions as in the .pro).
    public var oscillatorWordIndices: [Int] {
        let s = valuesPerPart
        return (0..<ProgramFile.partCount).flatMap { k in (3...5).map { 1 + s * k + $0 } }
    }

    /// The source each oscillator points at (nil if the stored index is out of range).
    public var oscillatorSources: [SourceRef?] {
        oscillatorWordIndices.map { i in
            guard words.indices.contains(i) else { return nil }
            let k = Int(words[i]); return k < sources.count ? sources[k].ref : nil
        }
    }
}

extension SourceRef {
    /// Whether the source is a P wavetable slot.
    public var isP: Bool { if case .p = self { return true }; return false }
}
