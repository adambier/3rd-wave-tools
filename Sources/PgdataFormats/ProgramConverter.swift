import Foundation

/// Brings a program saved by older 3rd Wave firmware up to the layout OS 2.0d writes: format
/// W3_PROG_5 with 181 integers and 137 floats per part, 182 global values, then the event records.
///
/// The rules reproduce what the 3rd Wave's Import program (and Bulk program import, which converts
/// the same way) did to programs on two models running OS 2.0d: 299 on an 8M (100 W3_PROG_3, 76
/// W3_PROG_4, 123 older W3_PROG_5, ten layouts) and 300 on a 24M (the same 2022 factory bank and
/// third-party programs, plus Groove Synthesis's 2025 factory bank 1). 292 of the 299 and 292 of
/// the 300 come out identical, value for value. The rest are 2022 W3_PROG_3 factory programs that
/// the firmware fixes individually on import, keyed by the program's name (shown on the 24M);
/// these fixes are not reproduced. See docs/FORMATS.md section 6.5.
///
/// A .pgdata import converts an old layout's structure but skips several of these value changes:
/// a W3_PROG_3 program packed unconverted has been observed to play silently on a 3rd Wave.
/// See section 6 of FORMATS.md for the conversion step by step.
public enum ProgramConverter {
    /// The 3rd Wave whose Import program the result reproduces. `.twentyFour` (24K or 24M) keeps
    /// all four parts and is what pgdata Packer writes: an 8M fits such a program to its two
    /// parts when it imports the .pgdata. `.eightM` adds the 8M's own two-part
    /// steps; it is used to check the rules against the 8M's exports.
    public enum Model: String, CaseIterable, Sendable {
        /// The 3rd Wave 8M, which plays parts 1 and 2 only: the result also has the 8M's two-part
        /// steps (section 6.4 of FORMATS.md).
        case eightM = "8M"
        /// The 24-voice models, 24K and 24M, which play all four parts. The rules come from a 24M;
        /// that a 24K converts the same way has not been checked.
        case twentyFour = "24K / 24M"
    }

    /// The sizes a program's header declares: integers per part, floats per part, and global values.
    ///
    /// The event record count is not part of the layout. See section 3.3 of FORMATS.md for the
    /// layouts seen.
    public struct Layout: Equatable, CustomStringConvertible, Sendable {
        /// Integers per part (*S*).
        public var ints: Int
        /// Floats per part (*F*).
        public var floats: Int
        /// Global values (*G*).
        public var globals: Int
        /// Creates a layout from its three sizes.
        public init(ints: Int, floats: Int, globals: Int) { self.ints = ints; self.floats = floats; self.globals = globals }
        /// The sizes as "S/F/G", for example "181/137/182".
        public var description: String { "\(ints)/\(floats)/\(globals)" }
    }

    /// The layout OS 2.0d writes.
    public static let current = Layout(ints: 181, floats: 137, globals: 182)

    /// The layout the program's header declares (integers and floats per part, globals), or nil
    /// when the header is missing or the file is not exactly as long as it says.
    public static func layout(of p: ProgramFile) -> Layout? {
        guard p.values.count >= 4 else { return nil }
        let h = p.values.prefix(4).map { v -> Int? in if case let .int(x, _) = v { return Int(x) }; return nil }
        guard let s = h[0], let f = h[1], let g = h[2], let e = h[3], s > 0, f > 0, g >= 0, e >= 0,
              4 + 4 * s + 4 * f + g + 6 * e == p.values.count else { return nil }
        return Layout(ints: s, floats: f, globals: g)
    }

    /// True when the program is not already in the current format and layout.
    public static func needsConversion(_ p: ProgramFile) -> Bool {
        !(p.version == "W3_PROG_5" && layout(of: p) == current)
    }

    /// Why the program cannot be converted, or nil when it can (or needs nothing).
    public static func unsupportedReason(_ p: ProgramFile) -> String? {
        guard needsConversion(p) else { return nil }
        guard let l = layout(of: p) else {
            return "The program's header does not match its length, so its layout is unknown."
        }
        guard (3...5).contains(p.versionNumber) else { return "Format \(p.version) has not been seen before." }
        guard (173...181).contains(l.ints), (126...137).contains(l.floats), (73...182).contains(l.globals) else {
            return "Layout \(l) (\(p.version)) has not been seen before."
        }
        return nil
    }

    /// The converted program. A program already in the current layout comes back unchanged.
    /// `format` overrides the format number in the tag (3, 4, or 5), for a program unpacked from a
    /// .pgdata, which has no tag (see ``inferredFormat(_:)``).
    ///
    /// - Throws: ``FormatError/invalid(_:)`` when the program cannot be converted (see
    ///   ``unsupportedReason(_:)``).
    public static func convert(_ p: ProgramFile, for model: Model = .twentyFour, format: Int? = nil) throws -> ProgramFile {
        guard needsConversion(p) else { return p }
        if let why = unsupportedReason(p) { throw FormatError.invalid("\(p.name): \(why)") }
        let l = layout(of: p)!
        let v = format ?? resolvedFormat(p)
        let eightM = model == .eightM
        let parts = 0..<ProgramFile.partCount

        var o = 4
        func take(_ n: Int) -> [ProgramFile.Value] { defer { o += n }; return Array(p.values[o..<o + n]) }
        var ints = parts.map { _ in take(l.ints).map(intOf) }
        var floats = parts.map { _ in take(l.floats).map(\.text) }
        let oldG = take(l.globals).map(intOf)
        let eventCount = (p.values.count - o) / 6
        let oldEvents = (0..<eventCount).map { _ in take(6).map(intOf) }

        // New values go at the end of each section [observed: every old value keeps its position].
        for k in parts {
            ints[k] += Array(repeating: 0, count: current.ints - l.ints)
            floats[k] += floatDefaults[(l.floats - 126)...]
        }
        var g = oldG + globalDefaults[(l.globals - 73)...]

        for k in parts {
            // Set in every converted program [observed in all 599 conversions, both models].
            floats[k][85] = "0.000000"
            floats[k][116] = "0.000000"
            // Float 102 is 1.0 after every conversion, except that a 24M gives W3_PROG_3 programs
            // 0.446233 [observed: 100 on each model].
            floats[k][102] = (v == 3 && !eightM) ? "0.446233" : "1.000000"
            // 0 became 1.0 [observed in 12 parts 3–4 on the 24M; 1.0 in every other part seen].
            if Double(floats[k][115]) == 0 { floats[k][115] = "1.000000" }
            // 2.0 became 1.0 [observed in a few W3_PROG_3 programs, the only files seen with values above 1 here].
            for j in [91, 95] where (Double(floats[k][j]) ?? 0) > 1 { floats[k][j] = "1.000000" }
            // 0 became 1 [observed in all 53 parts that had 0].
            for j in 63...65 where ints[k][j] == 0 { ints[k][j] = 1 }
            // Three supersaws (A04) in one part: oscillator 3 became sawtooth (A00) [observed in both
            // parts that had three; inferred: OS 2.0 allows two per part].
            if ints[k][0] == 43, ints[k][1] == 43, ints[k][2] == 43 { ints[k][2] = 41 }
            if v == 3 {
                // W3_PROG_3 kept part of the amp envelope amount in float 113 (0 = full, 1 = none);
                // OS 2.0 adds it to integer 34 [observed in all 100 W3_PROG_3 programs]. This is what made an
                // unconverted W3_PROG_3 program silent.
                let f113 = Double(floats[k][113]) ?? 0
                let extra = f113.isFinite ? Int64(max(-1e9, min(1e9, ((1 - f113) * 100).rounded()))) : 0
                ints[k][34] = Int32(clamping: min(127, Int64(ints[k][34]) + extra))
            }
        }

        for (j, x) in globalsSet { g[j] = x }
        // Values each model sets its own way on every import [observed: 299 on the 8M, 300 on the 24M].
        let stamp: [(Int, Int32)] = eightM ? [(0, 3), (80, 1), (174, 1)] : [(0, 2), (80, 0), (174, 0)]
        for (j, x) in stamp { g[j] = x }
        // Velocity: W3_PROG_3's 5 became 2 [observed in 89 programs]. The 4 others that got 3 are
        // among the 2022 factory programs the firmware fixes by name (FORMATS.md section 6.5).
        if v == 3, g[1] == 5 { g[1] = 2 }
        // Layouts with 120 globals or fewer had one value where OS 2.0 has one per part [observed in all 100].
        if l.globals <= 120 {
            for k in parts { g[120 + k] = oldG[12]; g[124 + k] = oldG[13]; g[132 + k] = oldG[15] }
        }

        // Event records: [target, a, type, b, time, 0]. Type 1 is automation, type 2 a note
        // (b = velocity · 256 + note). Formats 3 and 4 give the part as an index (0...3); format 5
        // gives a part mask (1, 2, 4, 8). A target outside 0...3 becomes mask 0, which an 8M drops
        // [observed once: 335 records of type 255 with target 255, kept by the 24M].
        let splits = eightM ? min(Int(oldG[18]), 1) : min(Int(oldG[18]), 3)
        let layer = oldG[24]
        var events: [[Int32]] = []
        for var e in oldEvents {
            var mask: Int32
            if v <= 4 {
                let index = Int(e[0])
                if e[2] == 2 && splits > 0 {
                    // Keyboard split: the note goes to the part mask of the zone its key falls in,
                    // whatever part it was recorded on [observed in 10 programs].
                    let note = e[3] & 0xFF
                    let zone = (0..<splits).filter { note > oldG[21 + $0] }.count
                    mask = oldG[24 + zone]
                } else {
                    if eightM && index >= 2 { continue }
                    mask = (0...3).contains(index) ? 1 << index : 0
                    // A note for a part in the layer (global 24) plays the whole layer [observed in 60 programs].
                    if e[2] == 2 && mask & layer != 0 { mask = layer }
                }
            } else {
                mask = e[0]
            }
            if eightM { mask &= 3; if mask == 0 { continue } }
            e[0] = mask
            events.append(e)
        }

        if eightM {
            for k in 2...3 { ints[k] = eightMFillerInts; floats[k] = eightMFillerFloats }
            let split = splits > 0
            g[24] &= 3; g[25] &= 3                       // part masks
            g[18] = min(g[18], 1); g[19] = min(g[19], 1)
            if g[11] >= 2 {                              // the selected part was 3 or 4
                g[11] = split ? 1 : 0
                if g[24] != 0 || split { g[37 + Int(g[11])] = 1 }
            }
            g[39] = 0; g[40] = 0
            for j in [124, 125, 127] { g[j] = min(g[j], 8) }
        }

        // A 24M writes negative zero as 0.000000; an 8M keeps -0.000000 [observed in 11 parts].
        if !eightM { for k in parts { for j in floats[k].indices where floats[k][j] == "-0.000000" { floats[k][j] = "0.000000" } } }

        var out: [ProgramFile.Value] = [.int(Int32(current.ints)), .int(Int32(current.floats)),
                                        .int(Int32(current.globals)), .int(Int32(events.count))]
        for k in parts { out += ints[k].map { .int($0) } }
        for k in parts { out += floats[k].map { .float(Float($0) ?? 0, text: $0) } }
        out += g.map { .int($0) }
        for e in events { out += e.map { .int($0) } }
        return ProgramFile(version: "W3_PROG_5", name: p.name, values: out)
    }

    /// One line saying what converting this program means, for the app; nil when it needs nothing.
    public static func summary(_ p: ProgramFile) -> String? {
        guard needsConversion(p), unsupportedReason(p) == nil, let l = layout(of: p) else { return nil }
        let f = resolvedFormat(p)
        let saved = f == p.versionNumber ? "(\(p.version), layout \(l))"
                                         : "(layout \(l), that of W3_PROG_\(f), though tagged \(p.version))"
        return "Originally saved in an older format \(saved). The program will be converted to the "
            + "current format (W3_PROG_5, \(current)) as part of packing, in the same way the 3rd Wave's \u{201C}Import program\u{201D} "
            + "function handles older programs."
    }

    /// The format a program unpacked from a .pgdata was probably saved in. A .pgdata has no format
    /// tag, so it is read from the layout: 173 or 174 integers per part = W3_PROG_3, 179 or 180 =
    /// W3_PROG_4 (true of every file seen). 181 with fewer than 136 floats was written as both
    /// W3_PROG_4 and W3_PROG_5; the two differ only in how event records name parts, so (looking at
    /// note and automation records only) a part mask above 3 means W3_PROG_5, else a part index 0
    /// means W3_PROG_4 (an inference from the files, not checked on a 3rd Wave). Without either,
    /// W3_PROG_5 is assumed. Nil when the layout is current or unknown.
    public static func inferredFormat(_ p: ProgramFile) -> Int? {
        guard let l = layout(of: p), l != current else { return nil }
        switch l.ints {
        case 173, 174: return 3
        case 179, 180: return 4
        case 181 where l.floats >= 136: return 5
        case 181:
            let start = 4 + 4 * l.ints + 4 * l.floats + l.globals
            var sawZero = false, sawMask = false
            for r in stride(from: start, to: p.values.count - 5, by: 6) {
                guard case let .int(target, _) = p.values[r], case let .int(type, _) = p.values[r + 2],
                      type == 1 || type == 2 else { continue }
                if target == 0 { sawZero = true } else if target > 3 { sawMask = true }
            }
            return sawZero && !sawMask ? 4 : 5
        default: return nil
        }
    }

    /// The format to convert a tagged .pro from: its tag, unless the layout contradicts it (a
    /// `W3_PROG_5` tag on a 173-value layout, as an unpacker that does not convert writes); then the
    /// layout decides, except that 181 integers with fewer than 136 floats fits both W3_PROG_4 and
    /// W3_PROG_5, where a tag of 4 or 5 is kept.
    static func resolvedFormat(_ p: ProgramFile) -> Int {
        guard let l = layout(of: p), let inferred = inferredFormat(p) else { return p.versionNumber }
        if l.ints == 181, l.floats < 136, (4...5).contains(p.versionNumber) { return p.versionNumber }
        return inferred
    }

    private static func intOf(_ v: ProgramFile.Value) -> Int32 {
        switch v {
        case let .int(x, _): return x
        case let .float(f, _): return f.isFinite ? Int32(clamping: Int64(max(-1e12, min(1e12, Double(f))))) : 0
        }
    }

    /// Globals every converted program had with these values (seen in all 599 conversions).
    /// (0, 80, and 174 differ by model: see `convert`.)
    static let globalsSet: [(Int, Int32)] = [
        (2, 0), (36, 0), (75, 1), (76, 2), (77, 2), (78, 0), (79, 0), (81, 1), (82, 1),
        (115, 1), (140, 0), (142, 0), (152, 1), (153, 0), (173, 0), (175, 2), (177, 0), (178, 1),
    ]

    /// Values OS 2.0d gives the global positions older layouts lack (73...181), from 299 bulk imports.
    /// 120...127 and 132...135 are filled from the old file instead when it had 120 globals or
    /// fewer (see `convert`).
    static let globalDefaults: [Int32] = [
        0, 1, 1, 2, 2, 0, 0, 1, 1, 1, 0, 15, 15, 15, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 2, 3, 0,
        0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 1, 2, 0, 0, 1, 0, 0, 0,
    ]

    /// Float positions older layouts lack (126...136).
    static let floatDefaults: [String] = [
        "0.000000", "4.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
    ]

    /// What an 8M puts in parts 3 and 4 of every program it imports (identical in all 299).
    static let eightMFillerInts: [Int32] = [
        2, 35, 42, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 34, 0, 0,
        0, 87, 80, 0, 0, 74, 82, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 52, 35, 35, 77, 95, 95,
        93, 93, 93, 105, 61, 61, 127, 78, 78, 78, 88, 88, 5, 5, 5, 1, 1, 1, 0, 0, 0, 120, 40, 40,
        40, 7, 7, 7, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 4, 12, 0, 0, 0, 0,
        0, 2, 0, 7, 0, 9, 0, 7, 0, 2, 0, 10, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1,
        1, 1, 0, 0, 127, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    static let eightMFillerFloats: [String] = [
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.500000", "0.500000",
        "0.000000", "0.000000", "0.500000", "0.500000", "0.500000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.470000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "11.000000", "11.000000", "22.000000", "55.000000", "55.000000",
        "10.000000", "10.000000", "10.000000", "47.000000", "35.000000", "35.000000", "18.000000", "17.000000",
        "17.000000", "1.000000", "0.000000", "0.000000", "0.405000", "0.267121", "0.000000", "1.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "120.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.166667", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "1.000000", "0.000000",
        "0.000000", "0.000000", "0.500000", "0.235294", "0.196078", "0.745098", "0.094488", "0.537255",
        "0.490196", "0.149020", "0.535000", "1.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.166667", "0.000000",
        "1.000000", "1.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.500000", "0.000000", "0.000000", "4.000000",
        "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000", "0.000000",
        "0.000000",
    ]
}
