import Foundation

public enum FormatError: Error, CustomStringConvertible, Equatable {
    case badMagic(expected: String, found: String)
    case truncated(at: Int, need: Int, have: Int)
    case invalid(String)

    public var description: String {
        switch self {
        case let .badMagic(e, f): return "Not a \(e) file (header reads \"\(f)\")."
        case let .truncated(at, need, have):
            return "File is truncated: needed \(need) bytes at offset \(at), but it is only \(have) bytes long."
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
public struct NameField: Equatable, Hashable {
    public private(set) var raw: [UInt8]

    public init(raw: [UInt8]) { self.raw = raw }

    public init(_ text: String, width: Int = 32) {
        var b = Array(text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(width - 1))
        b += [UInt8](repeating: 0, count: width - b.count)
        raw = b
    }

    public var text: String {
        let end = raw.firstIndex(of: 0) ?? raw.count
        return Array(raw[..<end]).latin1
    }
}

extension Array where Element == UInt8 {
    /// Latin-1 decode (the 3rd Wave's files are single-byte text).
    var latin1: String { String(self.map { Character(Unicode.Scalar($0)) }) }
}

extension String {
    var latin1Bytes: [UInt8] { unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") } }
}

/// 64-bit FNV-1a, used to fingerprint wavetable and sample content.
public func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
    return h
}
