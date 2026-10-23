import Foundation

/// Brings a program saved by older 3rd Wave firmware up to the layout OS 2.0d writes: format
/// W3_PROG_5 with 181 integers and 137 floats per part, 182 global values, then the event records.
///
/// The rules reproduce what the 3rd Wave's Import program (and Bulk program import, which converts
/// the same way) did to 299 programs on an 8M: 100 W3_PROG_3, 76 W3_PROG_4 and 123 older W3_PROG_5,
/// in ten layouts. With `.eightM`, 292 of the 299 come out identical, value for value; the other 7
/// (all W3_PROG_3) differ in one to six values that no rule found so far explains, apart from one
/// program whose part 2 the 8M replaced with a copy of part 1. See docs/FORMATS.md.
///
/// A .pgdata import converts an old layout's structure but skips several of these value changes:
/// a W3_PROG_3 program packed unconverted played silent [verified on hardware].
public enum ProgramConverter {
    /// The 3rd Wave the program is converted for. An 8M has two parts: its import replaces parts 3
    /// and 4 with fixed filler and limits everything else to parts 1 and 2. The 24-voice models
    /// keep all four parts; for them the 8M-only steps are left out [inferred: no 24K or 24M
    /// imports were available to compare].
    public enum Model: String, CaseIterable, Sendable {
        case eightM = "8M"
        case twentyFour = "24K / 24M"
    }

    public struct Layout: Equatable, CustomStringConvertible, Sendable {
        public var ints: Int, floats: Int, globals: Int
        public init(ints: Int, floats: Int, globals: Int) { self.ints = ints; self.floats = floats; self.globals = globals }
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
    public static func convert(_ p: ProgramFile, for model: Model) throws -> ProgramFile {
        guard needsConversion(p) else { return p }
        if let why = unsupportedReason(p) { throw FormatError.invalid("\(p.name): \(why)") }
        let l = layout(of: p)!
        let v = p.versionNumber
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
            // Set in every converted program [observed in 299/299].
            floats[k][85] = "0.000000"
            floats[k][102] = "1.000000"
            floats[k][116] = "0.000000"
            // 2.0 became 1.0 [observed twice, W3_PROG_3].
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
                let extra = ((1 - (Double(floats[k][113]) ?? 0)) * 100).rounded()
                ints[k][34] = min(127, ints[k][34] + Int32(extra))
            }
        }

        for (j, x) in globalsSet { g[j] = x }
        // Velocity: W3_PROG_3's 5 became 2 in 89 programs and 3 in 4 others, which no rule found
        // so far separates [observed].
        if v == 3, g[1] == 5 { g[1] = 2 }
        // Layouts with 120 globals or fewer had one value where OS 2.0 has one per part [observed in all 100].
        if l.globals <= 120 {
            for k in parts { g[120 + k] = oldG[12]; g[124 + k] = oldG[13]; g[132 + k] = oldG[15] }
        }

        // Event records: [target, a, type, b, time, 0]. Type 1 is automation, type 2 a note
        // (b = velocity · 256 + note). Formats 3 and 4 give the part as an index (0...3); format 5
        // gives a part mask (1, 2, 4, 8). Other types were dropped [observed once].
        let splits = eightM ? min(Int(oldG[18]), 1) : min(Int(oldG[18]), 3)
        let layer = oldG[24]
        var events: [[Int32]] = []
        for var e in oldEvents {
            var mask: Int32
            if v <= 4 {
                guard e[2] == 1 || e[2] == 2 else { continue }
                let index = Int(e[0])
                guard (0...3).contains(index) else { continue }
                if e[2] == 2 && splits > 0 {
                    // Keyboard split: the note goes to the part mask of the zone its key falls in,
                    // whatever part it was recorded on [observed in 10 programs].
                    let note = e[3] & 0xFF
                    let zone = (0..<splits).filter { note > oldG[21 + $0] }.count
                    mask = oldG[24 + zone]
                } else {
                    if eightM && index >= 2 { continue }
                    mask = 1 << index
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
            g[36] = 0
            if g[11] >= 2 {                              // the selected part was 3 or 4
                g[11] = split ? 1 : 0
                if g[24] != 0 || split { g[37 + Int(g[11])] = 1 }
            }
            g[39] = 0; g[40] = 0
            for j in [124, 125, 127] { g[j] = min(g[j], 8) }
        }

        var out: [ProgramFile.Value] = [.int(Int32(current.ints)), .int(Int32(current.floats)),
                                        .int(Int32(current.globals)), .int(Int32(events.count))]
        for k in parts { out += ints[k].map { .int($0) } }
        for k in parts { out += floats[k].map { .float(Float($0) ?? 0, text: $0) } }
        out += g.map { .int($0) }
        for e in events { out += e.map { .int($0) } }
        return ProgramFile(version: "W3_PROG_5", name: p.name, values: out)
    }

    private static func intOf(_ v: ProgramFile.Value) -> Int32 {
        switch v {
        case let .int(x, _): return x
        case let .float(f, _): return Int32(f)
        }
    }

    /// Globals every converted program had with these values [observed in 299/299].
    static let globalsSet: [(Int, Int32)] = [
        (0, 3), (2, 0), (75, 1), (76, 2), (77, 2), (78, 0), (79, 0), (80, 1), (81, 1), (82, 1),
        (115, 1), (140, 0), (142, 0), (152, 1), (153, 0), (173, 0), (174, 1), (175, 2), (178, 1),
    ]

    /// Values OS 2.0d gives the global positions older layouts lack (73...181), from 299 bulk imports.
    /// 120...135 are filled from the old file instead (see `convert`).
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
