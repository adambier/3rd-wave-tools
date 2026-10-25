import Foundation

/// One multisample slot (S): up to 8 samples, each with key range, loop, and level settings.
///
/// Stored in a .bin file ("W3_MSAMPLE_<v>", v = 1, 4, or 5 seen) and, in the v5 layout, inside
/// a .pgdata. Older versions lack some fields; on upgrade they get the values the 3rd Wave itself
/// assigns, as Groove Synthesis's version 1 and version 5 copies of the same multisample show:
/// 48 kHz, 16-bit, pitch 0, second rate = rate, volume 1.0. See section 5.2 of FORMATS.md.
public struct Multisample: Equatable, Sendable {
    /// One sample of a multisample: its audio, the key range it plays, and its loop and level
    /// settings.
    ///
    /// The field meanings and ranges are those of Groove Synthesis's *3rd Wave MIDI CC + SysEx
    /// Spec* (v2a), whose "set multisample" message carries the same fields, apart from the name
    /// and ``secondRate``.
    public struct Sample: Equatable, Sendable {
        /// The sample's name.
        public var name: NameField
        /// The length of the audio, in frames.
        public var length: UInt32              // frames
        /// The recording's sample rate in Hz, for example 48,000. Version 1 files lack it, and it
        /// is then 48,000.
        public var sampleRate: Float = 48_000
        /// The recording's bit depth, as a code: 0 = 8-bit, 1 = 12-bit, 2 = 16-bit. Version 1 files
        /// lack it, and it is then 2.
        public var bitDepth: UInt8 = 2         // 0 = 8-bit, 1 = 12-bit, 2 = 16-bit
        /// The start point, as a frame position.
        public var start: UInt32
        /// The end point, as a frame position.
        public var end: UInt32
        /// The loop start point, as a frame position.
        public var loopStart: UInt32
        /// The loop end point, as a frame position.
        public var loopEnd: UInt32
        /// The MIDI note number the recording is assigned to.
        ///
        /// The samples of a multisample must be in increasing order of this note (see ``Multisample/problems``).
        public var rootNote: UInt8
        /// The lowest MIDI note number of the key range the sample plays.
        public var lowNote: UInt8
        /// The highest MIDI note number of the key range the sample plays.
        public var highNote: UInt8
        /// The loop mode: 0 = off, 1 = on while the note is held, 2 = always on.
        public var loopMode: UInt8             // 0 off, 1 while key held, 2 always
        /// The loop crossfade length, in frames.
        public var crossfade: UInt32           // samples
        /// The loop crossfade type: 0 = off, 1 = equal volume, 2 = equal power.
        public var crossfadeType: UInt8        // 0 off, 1 equal volume, 2 equal power
        /// The sample's pitch setting, from −1.0 to 1.0. Version 1 files lack it, and it is then 0.
        public var pitch: Float = 0
        /// A second sample rate in Hz, which the SysEx message does not carry.
        ///
        /// It equals ``sampleRate`` in all but 40 of the 1,270 samples examined; in those it is
        /// another standard rate (12,000, 22,050, 44,100, or 48,000 Hz), so it is probably the rate
        /// the sample is played back or was resampled at. Version 1 files lack it, and it is then
        /// equal to ``sampleRate``.
        public var secondRate: Float = 48_000  // meaning inferred: playback / reduced rate
        /// The sample's volume, as a multiplier from 0.0 to 2.0. Version 1 and 4 files lack it, and
        /// it is then 1.0.
        public var volume: Float = 1
        /// The audio: signed 16-bit little-endian values, one per frame, so `length` × 2 bytes.
        public var audio: [UInt8]
    }

    /// The multisample's name, which the file calls the slot name.
    public var slotName: NameField
    /// The samples. The 3rd Wave allows at most 8, in increasing order of ``Sample/rootNote``
    /// (see ``problems``).
    public var samples: [Sample]
    /// Version of the .bin this was read from (5 when built or read from a .pgdata).
    public var sourceVersion: Int = 5

    /// The `.bin` version this library writes: 5.
    public static let currentVersion = 5

    /// Creates a multisample from a name and its samples.
    public init(slotName: NameField, samples: [Sample]) {
        self.slotName = slotName; self.samples = samples
    }

    /// The multisample's name as text.
    public var name: String { slotName.text }
    /// The total length of all the samples, in frames.
    public var totalFrames: Int { samples.reduce(0) { $0 + Int($1.length) } }

    /// Departures from what the 3rd Wave's SysEx specification allows for a multisample, each as
    /// a phrase for a warning: samples out of key order (the specification requires increasing
    /// assigned notes), more than 8 samples, codes outside their ranges, offsets past the audio.
    public var problems: [String] {
        var out: [String] = []
        if samples.count > 8 { out.append("it holds \(samples.count) samples; the 3rd Wave allows 8") }
        let roots = samples.map(\.rootNote)
        if roots != roots.sorted() { out.append("its samples are not in increasing order of their assigned notes, which the 3rd Wave requires") }
        for (i, s) in samples.enumerated() {
            let n = "sample \(i + 1)"
            if s.bitDepth > 2 { out.append("\(n) has bit depth code \(s.bitDepth); the 3rd Wave uses 0 (8-bit), 1 (12-bit), or 2 (16-bit)") }
            if s.loopMode > 2 { out.append("\(n) has loop mode \(s.loopMode); the 3rd Wave uses 0, 1, or 2") }
            if s.crossfadeType > 2 { out.append("\(n) has crossfade type \(s.crossfadeType); the 3rd Wave uses 0, 1, or 2") }
            if s.lowNote > s.highNote || s.rootNote > 127 || s.lowNote > 127 || s.highNote > 127 { out.append("\(n) has a key range of \(s.lowNote)–\(s.highNote) with root \(s.rootNote), which is not a valid range of MIDI notes") }
            if max(s.start, s.end, s.loopStart, s.loopEnd) > s.length { out.append("\(n) has start, end, or loop points past its \(s.length) frames") }
            if !(s.volume >= 0 && s.volume <= 2) || !(s.pitch >= -1 && s.pitch <= 1) { out.append("\(n) has a volume of \(s.volume) or a pitch of \(s.pitch) outside the 3rd Wave's ranges (0–2 and ±1)") }
        }
        return out
    }

    // MARK: .bin

    /// Reads a `.bin` file of version 1, 4, or 5.
    ///
    /// Fields an older version lacks get the values described under ``Multisample``.
    ///
    /// - Throws: ``FormatError`` when the data is not a multisample file, is of another version,
    ///   ends early, or has bytes after the last sample.
    public init(binData data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 49 else { throw FormatError.truncated(at: 0, need: 49, have: bytes.count) }
        let magic = NameField(raw: Array(bytes[0..<16])).text        // up to the first NUL
        guard magic.hasPrefix("W3_MSAMPLE_"), let v = Int(magic.dropFirst(11)) else {
            throw FormatError.badMagic(expected: "3rd Wave multisample (.bin)", found: magic)
        }
        guard [1, 4, 5].contains(v) else {
            throw FormatError.invalid("Multisample file version \(v) is not supported (versions 1, 4, and 5 are).")
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

    /// The multisample as a version 5 `.bin` file, whatever version it was read from.
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
    ///
    /// A 64-bit FNV-1a hash of every sample's fields (its name included) and audio, as stored in a
    /// version 5 file.
    public var fingerprint: UInt64 {
        var w = ByteWriter()
        for s in samples { Self.writeSample(s, &w) }
        return fnv1a64(w.bytes)
    }

    /// The name of MIDI note `n`, with middle C (note 60) as "C3" and note 69 as "A3".
    public static func noteName(_ n: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[Int(n) % 12] + String(Int(n) / 12 - 2)
    }
}
