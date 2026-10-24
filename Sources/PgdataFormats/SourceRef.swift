import Foundation

/// What an oscillator plays: a wavetable slot, an analog shape, or a multisample slot.
///
/// Programs store each oscillator's source as one integer ("source id"). The id space is
/// irregular, probably because it grew in stages without renumbering; ids 34, 1000, 2000, and
/// 41–47 were read on an 8M (OS 2.0d), the rest follow from those and from real files:
///
///     0–33      P00–P33          (PPG tables)
///     34–40     U00–U06
///     41–47     analog waves A00–A06, not in display order (see `analogIDs`)
///     1000+k    P(34+k)          P34–P47
///     2000+k    U(7+k)           U07–U63
///     4000+n    Sn               multisample slots
///
/// An id names a *slot*, not content: what plays depends on what is loaded in that slot.
/// See section 2 of FORMATS.md.
public enum SourceRef: Hashable, Comparable, CustomStringConvertible {
    /// P wavetable slot P*n*, *n* = 0–47.
    case p(Int)        // 0...47
    /// U wavetable slot U*n*, *n* = 0–63.
    case u(Int)        // 0...63
    /// Analog wave A*n*, *n* = 0–6, numbered as the 3rd Wave shows them (see ``analogIDs``).
    case analog(Int)   // 0...6 = A00...A06 as the 3rd Wave shows them (ids 41...47, reordered)
    /// Multisample slot S*n*, *n* = 0–127; the 3rd Wave's upper limit has not been checked.
    case s(Int)        // 0...127
    /// A source id that names no known slot, kept as it is.
    case unknown(Int32)

    /// The number of P slots (48), the number of U slots (64), and the highest S slot number this
    /// library accepts (127).
    public static let pCount = 48, uCount = 64, sMax = 127
    /// The number of factory P tables, in P00–P35: 36.
    public static let factoryPCount = 36   // P00–P35
    /// The number of factory U tables, in U00–U55: 56.
    public static let factoryUCount = 56   // U00–U55

    /// The source for a source id, as a program or a `.pgdata` source table stores it; ``unknown(_:)``
    /// for an id outside the known ranges.
    public init(id: Int32) {
        let v = Int(id)
        switch v {
        case 0...33: self = .p(v)
        case 34...40: self = .u(v - 34)
        case 41...47: self = .analog(Self.analogIDs.firstIndex(of: Int32(v))!)
        case 1000...1013: self = .p(v - 1000 + 34)
        case 2000...2056: self = .u(v - 2000 + 7)
        case 4000...4127: self = .s(v - 4000)
        default: self = .unknown(id)
        }
    }

    /// The source id, as a program stores it.
    public var id: Int32 {
        switch self {
        case let .p(n): return Int32(n <= 33 ? n : 1000 + n - 34)
        case let .u(n): return Int32(n <= 6 ? 34 + n : 2000 + n - 7)
        case let .analog(n): return Self.analogIDs.indices.contains(n) ? Self.analogIDs[n] : Int32(41 + n)
        case let .s(n): return Int32(4000 + n)
        case let .unknown(v): return v
        }
    }

    /// Type code used in the .pgdata source table: 0 = P, 1 = U, 2 = analog, 4 = multisample, and
    /// 255 for ``unknown(_:)``.
    public var typeCode: UInt8 {
        switch self {
        case .p: return 0
        case .u: return 1
        case .analog: return 2
        case .s: return 4
        case .unknown: return 0xff
        }
    }

    /// The seven analog-modelled waves, as the 3rd Wave labels and names them (read on an 8M,
    /// 2026-10-22). The wave offset knob sweeps A05 from white through pink to red noise and A06
    /// from white through blue to violet.
    public static let analogNames = ["Sawtooth", "Square", "Triangle", "Sine", "Supersaw", "Pink noise", "Blue noise"]

    /// The source id of each analog wave A00–A06. The ids are not in display order: 43 is A04
    /// Supersaw and 47 is A02 Triangle (each id 41–47 was read from the OSC screen of an 8M,
    /// OS 2.0d, 2026-10-23; the earlier assumption 41 + n was wrong for A02–A04).
    public static let analogIDs: [Int32] = [41, 42, 47, 44, 43, 45, 46]
    /// The number of analog waves: 7.
    public static var analogCount: Int { analogNames.count }

    /// Slot label as the 3rd Wave shows it: P07, U50, S10.
    public var label: String {
        switch self {
        case let .p(n): return String(format: "P%02d", n)
        case let .u(n): return String(format: "U%02d", n)
        case let .s(n): return String(format: "S%02d", n)
        case let .analog(n): return String(format: "A%02d", n)
        case let .unknown(v): return "?\(v)"
        }
    }

    /// The slot label, followed by the wave's name for an analog wave: "P07", "A04 Supersaw".
    public var description: String {
        if case let .analog(n) = self { return n < Self.analogNames.count ? "\(label) \(Self.analogNames[n])" : "Analog \(label)" }
        return label
    }

    /// Whether the source is a wavetable slot, P or U.
    public var isWavetable: Bool { if case .p = self { return true }; if case .u = self { return true }; return false }
    /// Whether the source is a multisample slot.
    public var isSample: Bool { if case .s = self { return true }; return false }
    /// Sources that never carry data (analog shapes are built in).
    public var isBuiltIn: Bool { if case .analog = self { return true }; return false }

    /// Whether the slot lies in the factory-filled range (P00–P35, U00–U55). Says nothing about
    /// what a particular 3rd Wave actually has loaded there. Analog waves count as factory slots.
    public var isFactorySlot: Bool {
        switch self {
        case let .p(n): return n < Self.factoryPCount
        case let .u(n): return n < Self.factoryUCount
        case .analog: return true
        default: return false
        }
    }

    /// Parse "P07", "U50", "S10", "S010", case-insensitive.
    ///
    /// Accepts P, U, and S labels within the slot ranges; nil for anything else, analog labels
    /// included.
    public init?(label: String) {
        let t = label.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = t.dropFirst()
        guard let k = t.first, !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits) else { return nil }
        switch k {
        case "P" where (0..<Self.pCount).contains(n): self = .p(n)
        case "U" where (0..<Self.uCount).contains(n): self = .u(n)
        case "S" where (0...Self.sMax).contains(n): self = .s(n)
        default: return nil
        }
    }

    /// Slot suggested by a filename such as "S000_Drums.bin", "U48 Strings 1.WT", or
    /// "U50_Bells.wt". Only ever a suggestion for the UI to confirm.
    ///
    /// The name must start with P, U, or S and two or three digits, not followed by a letter;
    /// otherwise the result is nil.
    public static func suggested(byFilename name: String) -> SourceRef? {
        let base = (name as NSString).lastPathComponent
        let scalars = Array(base.uppercased())
        guard let k = scalars.first, "PUS".contains(k) else { return nil }
        var digits = ""
        for c in scalars.dropFirst() { if c.isNumber { digits.append(c) } else { break } }
        guard (2...3).contains(digits.count) else { return nil }
        let rest = scalars.dropFirst(1 + digits.count)
        if let c = rest.first, c.isLetter { return nil }   // e.g. "Piano..." is not a slot
        return SourceRef(label: String(k) + digits)
    }

    public static func < (a: SourceRef, b: SourceRef) -> Bool {
        (a.typeCode, a.id) < (b.typeCode, b.id)
    }
}
