import Foundation

/// One multisample slot (S): up to 8 samples, each with key range, loop and level settings.
///
/// Stored in a .bin file ("W3_MSAMPLE_<v>", v = 1, 4 or 5 seen) and, in the v5 layout, inside
/// a .pgdata. Older versions lack some fields; on upgrade they get the values the synth itself
/// assigns (verified against Groove's v1 and v5 copies of "Hanger Drums"): 48 kHz, 16-bit,
/// pitch 0, second rate = rate, volume 1.0.
public struct Multisample: Equatable {
    public struct Sample: Equatable {
        public var name: NameField
        public var length: UInt32              // frames
        public var sampleRate: Float = 48_000
        public var bitDepth: UInt8 = 2         // 0 = 8-bit, 1 = 12-bit, 2 = 16-bit
        public var start: UInt32
        public var end: UInt32
        public var loopStart: UInt32
        public var loopEnd: UInt32
        public var rootNote: UInt8
        public var lowNote: UInt8
        public var highNote: UInt8
        public var loopMode: UInt8             // 0 off, 1 while key held, 2 always
        public var crossfade: UInt32           // samples
        public var crossfadeType: UInt8        // 0 off, 1 equal volume, 2 equal power
        public var pitch: Float = 0
        public var secondRate: Float = 48_000  // meaning inferred: playback / reduced rate
        public var volume: Float = 1
        /// int16 little-endian audio, `length` frames.
        public var audio: [UInt8]
    }

    public var slotName: NameField
    public var samples: [Sample]
    /// Version of the .bin this was read from (5 when built or read from a .pgdata).
    public var sourceVersion: Int = 5

    public static let currentVersion = 5

    public init(slotName: NameField, samples: [Sample]) {
        self.slotName = slotName; self.samples = samples
    }

    public var name: String { slotName.text }
    public var totalFrames: Int { samples.reduce(0) { $0 + Int($1.length) } }

    // MARK: .bin

    public init(binData data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 49 else { throw FormatError.truncated(at: 0, need: 49, have: bytes.count) }
        let magic = Array(bytes[0..<12]).latin1
        guard magic.hasPrefix("W3_MSAMPLE_"), let v = Int(magic.dropFirst(11)) else {
            throw FormatError.badMagic(expected: "3rd Wave multisample (.bin)", found: magic)
        }
        guard [1, 4, 5].contains(v) else {
            throw FormatError.invalid("Multisample file version \(v) is not one this app knows (1, 4 and 5 are supported).")
        }
        var r = ByteReader(bytes, offset: 16)
        let n = Int(try r.u8())
        slotName = NameField(raw: try r.take(32))
        samples = try (0..<n).map { _ in try Self.readSample(&r, version: v) }
        sourceVersion = v
        if r.offset != bytes.count {
            throw FormatError.invalid("Multisample \"\(slotName.text)\" has \(bytes.count - r.offset) unexpected bytes at the end.")
        }
    }

    /// Writes a v5 .bin.
    public func binData() -> Data {
        var w = ByteWriter()
        w.put(NameField("W3_MSAMPLE_\(Self.currentVersion)", width: 16).raw)
        writeBody(&w)
        return Data(w.bytes)
    }

    // MARK: shared body (count, slot name, samples) — identical in .bin v5 and .pgdata

    func writeBody(_ w: inout ByteWriter) {
        w.u8(UInt8(samples.count))
        w.put(slotName.raw)
        for s in samples { Self.writeSample(s, &w) }
    }

    static func readBody(_ r: inout ByteReader) throws -> Multisample {
        let n = Int(try r.u8())
        let name = NameField(raw: try r.take(32))
        let s = try (0..<n).map { _ in try readSample(&r, version: 5) }
        return Multisample(slotName: name, samples: s)
    }

    static func readSample(_ r: inout ByteReader, version v: Int) throws -> Sample {
        let length = try r.u32()
        var rate: Float = 48_000, depth: UInt8 = 2
        if v >= 4 { rate = try r.f32(); depth = try r.u8() }
        let name = NameField(raw: try r.take(32))
        let start = try r.u32(), end = try r.u32(), ls = try r.u32(), le = try r.u32()
        let root = try r.u8(), lo = try r.u8(), hi = try r.u8(), loop = try r.u8()
        let xf = try r.u32()
        let xft = try r.u8()
        var pitch: Float = 0, rate2 = rate, vol: Float = 1
        if v >= 4 { pitch = try r.f32(); rate2 = try r.f32() }
        if v >= 5 { vol = try r.f32() }
        let audio = try r.take(Int(length) * 2)
        return Sample(name: name, length: length, sampleRate: rate, bitDepth: depth, start: start, end: end,
                      loopStart: ls, loopEnd: le, rootNote: root, lowNote: lo, highNote: hi, loopMode: loop,
                      crossfade: xf, crossfadeType: xft, pitch: pitch, secondRate: rate2, volume: vol, audio: audio)
    }

    static func writeSample(_ s: Sample, _ w: inout ByteWriter) {
        w.u32(s.length); w.f32(s.sampleRate); w.u8(s.bitDepth)
        w.put(s.name.raw)
        w.u32(s.start); w.u32(s.end); w.u32(s.loopStart); w.u32(s.loopEnd)
        w.u8(s.rootNote); w.u8(s.lowNote); w.u8(s.highNote); w.u8(s.loopMode)
        w.u32(s.crossfade); w.u8(s.crossfadeType)
        w.f32(s.pitch); w.f32(s.secondRate); w.f32(s.volume)
        w.put(s.audio)
    }

    /// Identity of the audio and settings, independent of the slot name.
    public var fingerprint: UInt64 {
        var w = ByteWriter()
        for s in samples { Self.writeSample(s, &w) }
        return fnv1a64(w.bytes)
    }

    public static func noteName(_ n: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[Int(n) % 12] + String(Int(n) / 12 - 2)
    }
}
