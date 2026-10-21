import Foundation

/// What an oscillator plays: a wavetable slot, an analog shape, or a multisample slot.
///
/// Programs store each oscillator's source as one integer ("source id"). The id space
/// grew in stages and was never renumbered, so it is irregular (verified on an 8M, OS 2.0d):
///
///     0–33      P00–P33          (PPG tables)
///     34–40     U00–U06
///     41–47     analog shapes (7)
///     1000+k    P(34+k)          P34–P47
///     2000+k    U(7+k)           U07–U63
///     4000+n    Sn               multisample slots
///
/// An id names a *slot*, not content: what plays depends on what is loaded in that slot.
public enum SourceRef: Hashable, Comparable, CustomStringConvertible {
    case p(Int)        // 0...47
    case u(Int)        // 0...63
    case analog(Int)   // 0...6  (id 41...47)
    case s(Int)        // 0...127
    case unknown(Int32)

    public static let pCount = 48, uCount = 64, sMax = 127
    public static let factoryPCount = 36   // P00–P35
    public static let factoryUCount = 56   // U00–U55

    public init(id: Int32) {
        let v = Int(id)
        switch v {
        case 0...33: self = .p(v)
        case 34...40: self = .u(v - 34)
        case 41...47: self = .analog(v - 41)
        case 1000...1013: self = .p(v - 1000 + 34)
        case 2000...2056: self = .u(v - 2000 + 7)
        case 4000...4127: self = .s(v - 4000)
        default: self = .unknown(id)
        }
    }

    public var id: Int32 {
        switch self {
        case let .p(n): return Int32(n <= 33 ? n : 1000 + n - 34)
        case let .u(n): return Int32(n <= 6 ? 34 + n : 2000 + n - 7)
        case let .analog(n): return Int32(41 + n)
        case let .s(n): return Int32(4000 + n)
        case let .unknown(v): return v
        }
    }

    /// Type code used in the .pgdata source table.
    public var typeCode: UInt8 {
        switch self {
        case .p: return 0
        case .u: return 1
        case .analog: return 2
        case .s: return 4
        case .unknown: return 0xff
        }
    }

    public static let analogNames = ["Sine", "Sawtooth", "Triangle", "Supersaw", "Pulse", "White noise", "Pink noise"]

    /// Slot label as the synth shows it: P07, U50, S10.
    public var label: String {
        switch self {
        case let .p(n): return String(format: "P%02d", n)
        case let .u(n): return String(format: "U%02d", n)
        case let .s(n): return String(format: "S%02d", n)
        case let .analog(n): return "A\(n)"
        case let .unknown(v): return "?\(v)"
        }
    }

    public var description: String {
        if case let .analog(n) = self { return n < Self.analogNames.count ? "Analog \(Self.analogNames[n])" : "Analog \(n)" }
        return label
    }

    public var isWavetable: Bool { if case .p = self { return true }; if case .u = self { return true }; return false }
    public var isSample: Bool { if case .s = self { return true }; return false }
    /// Sources that never carry data (analog shapes are built in).
    public var isBuiltIn: Bool { if case .analog = self { return true }; return false }

    /// Slot number lies in the factory-filled range (P00–P35, U00–U55). Says nothing about
    /// what a particular synth actually has loaded there.
    public var isFactorySlot: Bool {
        switch self {
        case let .p(n): return n < Self.factoryPCount
        case let .u(n): return n < Self.factoryUCount
        case .analog: return true
        default: return false
        }
    }

    /// Parse "P07", "U50", "S10", "S010", case-insensitive.
    public init?(label: String) {
        let t = label.trimmingCharacters(in: .whitespaces).uppercased()
        guard let k = t.first, let n = Int(t.dropFirst()) else { return nil }
        switch k {
        case "P" where (0..<Self.pCount).contains(n): self = .p(n)
        case "U" where (0..<Self.uCount).contains(n): self = .u(n)
        case "S" where (0...Self.sMax).contains(n): self = .s(n)
        default: return nil
        }
    }

    /// Slot suggested by a filename such as "S000_Amen Cuts.bin", "U48 SM OBX8 1.WT",
    /// "U50_SM OB2.wt". Only ever a suggestion for the UI to confirm.
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
