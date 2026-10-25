import Foundation

// Surge's binary `.wt` (see the Surge project's `WT fileformat.txt`): after the ASCII magic
// "vawt", little-endian u32 frame size, u16 frame count, u16 flags, then the data, float32 or
// int16. Flags: 0x01 a sample, not a wavetable; 0x02 looped; 0x04 int16 data; 0x08 int16 uses the
// full 16-bit range (otherwise its peak is 2^14); 0x10 a NUL-terminated XML metadata block
// follows the data (ignored here).

extension WavetableReader {
    /// The table in a Surge `.wt`, or none when its header marks it as a sample.
    static func readSurge(_ b: [UInt8], fileName: String) throws -> [FoundTable] {
        let what = "\"\(fileName)\" begins like a Surge wavetable (vawt), but"
        guard b.count >= 12 else {
            throw WavetableError("\(what) it ends after \(b.count) bytes, inside its 12-byte header; it is damaged or cut short.")
        }
        let size = Int(le32(b, 4)), count = Int(le16(b, 8)), flags = le16(b, 10)
        if flags & 0x01 != 0 { return [] }   // a sample, not a wavetable
        guard (2...65_536).contains(size) else {
            throw WavetableError("\(what) its header says \(grouped(size)) samples per frame, which is not a usable size; it is damaged.")
        }
        guard count >= 1 else { throw WavetableError("\(what) its header says it has no frames; it is damaged.") }
        let isInt16 = flags & 0x04 != 0
        let need = size * count * (isInt16 ? 2 : 4)
        guard b.count - 12 >= need else {
            throw WavetableError("\(what) its header promises \(grouped(count)) frames of \(grouped(size)) samples "
                                 + "(\(grouped(need)) bytes), and the file holds only \(grouped(b.count - 12)) bytes "
                                 + "after the header; it has been cut short.")
        }
        var samples = [Float](repeating: 0, count: size * count)
        if isInt16 {
            let scale: Float = flags & 0x08 != 0 ? 32_768 : 16_384
            for i in samples.indices { samples[i] = Float(Int16(bitPattern: le16(b, 12 + 2 * i))) / scale }
        } else {
            for i in samples.indices {
                let v = Float(bitPattern: le32(b, 12 + 4 * i))
                guard v.isFinite else {
                    throw WavetableError("\(what) sample \(grouped(i)) is not a number; it is damaged.")
                }
                samples[i] = v
            }
        }
        var notes: [String] = []
        if size > 4096 || size & (size - 1) != 0 {
            notes.append("\(grouped(size)) samples per frame: Surge itself takes only powers of two from 2 to 4,096, so this file may not have come from Surge.")
        }
        if count > 512 { notes.append("\(grouped(count)) frames: Surge takes at most 512, and Serum, Vital, and Pigments 256, so converting for them drops frames (you choose how).") }
        else if let n = frameCountNote(count) { notes.append(n) }
        if let n = peakNote(samples.reduce(0) { max($0, abs($1)) }) { notes.append(n) }
        return [FoundTable(name: fileStem(fileName), fileName: fileName, source: .surgeWavetable, samples: samples,
                           frameSize: size, frameSizeBasis: "Surge .wt header", notes: notes)]
    }
}
