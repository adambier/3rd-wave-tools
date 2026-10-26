import Foundation

// FLAC files (RFC 9639): a decoder in plain Swift, and the wavetable rules applied to the result.
//
// The decoder reads the whole stream: STREAMINFO, every metadata block (APPLICATION and
// VORBIS_COMMENT are kept), and every frame: CONSTANT, VERBATIM, FIXED, and LPC subframes, Rice
// and Rice2 residuals with escaped partitions, wasted bits, and the left/side, right/side, and
// mid/side stereo modes; 4- to 32-bit samples (8 to 32 tested), any number of channels, fixed or
// variable block sizes. Each frame header's CRC-8 and each frame's CRC-16 are checked, and so is
// the MD5 signature of the decoded audio in STREAMINFO when the file carries one; a file that
// fails any of them is reported as damaged. Only the first channel is kept, scaled to ±1 by the
// bit depth; the others are decoded (they are needed for the checks and the stereo modes) and
// dropped.
//
// The wavetable rules are the WAV reader's (ReadWAV.swift, `tables(in:…)`): a FLAC file has no
// RIFF chunks, but a writer may store the same metadata as APPLICATION blocks, and this reader
// hands blocks whose id is one of the WAV chunk ids it knows (`clm `, `srge`, `srgo`, `uhWT`,
// `cue `, `smpl`), forwards or byte-reversed, to those rules as the chunks they are. The reversed
// form is what Phase Plant's factory library has: of its 402 files (all mono, 24-bit, 256 × 2,048),
// 29 carry a 48-byte " mlc" block holding "<!>2048 10000000 Kilohearts (www.kilohearts.com)" and
// 8 carry a 60-byte "lpms" block (a `smpl` chunk with no loops). Every one of them also carries an
// 8-byte "MsHk" block: a little-endian 32-bit 1, then a 32-bit float between 0.89 and 3.55 (1.0 in
// 272 of the files) that has no evident relation to the file's peak (all peak at exactly full
// scale) or RMS level. It states neither a frame size nor a frame count, so it is read past; what
// the float means is not documented. A Vorbis comment whose value is a Serum tag ("<!>2048 …")
// counts as a `clm ` chunk too, with a note saying where it was found (no writer is known to do
// this; it is read because the tag's form is unmistakable). Other comments that mention frames,
// cycles, or wavetables are noted but not acted on. With no block that states a size, the
// Tonverk name tag, Serum sidecar, and length rules apply as they do to a WAV.

extension WavetableReader {
    /// The wavetable in a FLAC file, or none when it holds no wavetable.
    static func readFLAC(_ b: [UInt8], fileName: String, sidecarText: String?) throws -> [FoundTable] {
        let decoded = try FLACDecoder.decode(b, fileName: fileName)
        var chunks: [String: [UInt8]] = [:]
        var notes: [ReadNote] = []
        // Chunk ids a WAV wavetable can carry, which a FLAC writer may store as application blocks,
        // forwards or (as Phase Plant's library has them) byte-reversed.
        let riffIDs: Set<String> = ["clm ", "srge", "srgo", "uhWT", "cue ", "smpl"]
        for block in decoded.applications {
            let forwards = String(decoding: block.id, as: UTF8.self)
            let backwards = String(decoding: block.id.reversed(), as: UTF8.self)
            if riffIDs.contains(forwards) {
                if chunks[forwards] == nil { chunks[forwards] = block.body }
            } else if riffIDs.contains(backwards) {
                if chunks[backwards] == nil { chunks[backwards] = block.body }
            }
        }
        for (key, value) in decoded.comments {
            if value.hasPrefix("<!>") {
                if chunks["clm "] == nil {
                    chunks["clm "] = Array(value.utf8)
                    notes.append(ReadNote(.tagInComment(key: key),
                                          "The Serum-style tag was found in the file’s comments (\(key)), not in a block of its own."))
                }
            } else if ["FRAME", "CYCLE", "WAVETABLE"].contains(where: { key.uppercased().contains($0) }) {
                notes.append(ReadNote(.commentMentionsFrames(key: key, value: value),
                                      "The file’s comments say \"\(key)=\(value)\"; a frame size is not taken from a comment."))
            }
        }
        let info = decoded.info
        let wav = DecodedWAV(samples: decoded.firstChannel, channels: info.channels,
                             bytesPerSample: (info.bitsPerSample + 7) / 8, chunks: chunks, notes: notes)
        return try tables(in: wav, fileName: fileName, sidecarText: sidecarText, source: .flac, chunkWord: "block")
    }
}

/// A FLAC decoder in plain Swift (Foundation only). It decodes a whole stream at once and checks
/// every frame's CRCs and the stream's MD5 signature; see the comment at the top of this file.
enum FLACDecoder {
    /// The STREAMINFO block.
    struct StreamInfo: Equatable {
        var minBlockSize: Int
        var maxBlockSize: Int
        var minFrameSize: Int
        var maxFrameSize: Int
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        /// 0 when the stream does not say.
        var totalSamples: Int
        /// 16 bytes; all zero when the stream carries none.
        var md5: [UInt8]
    }

    /// A decoded stream.
    struct Decoded {
        var info: StreamInfo
        /// The first channel's samples, scaled to ±1 by the bit depth.
        var firstChannel: [Float]
        /// Every APPLICATION block, in order: its 4-byte id and the data after it.
        var applications: [(id: [UInt8], body: [UInt8])]
        /// Every VORBIS_COMMENT field, in order, split at its first "=".
        var comments: [(key: String, value: String)]
        /// The number of frames decoded.
        var frames: Int
        /// What the stream used, for tests.
        var stats: Stats
    }

    /// Counts of what a stream's frames used.
    struct Stats: Equatable {
        var constant = 0, verbatim = 0, fixed = 0, lpc = 0
        /// Residuals coded with the 5-bit (Rice2) partition parameter.
        var rice2 = 0
        /// Escaped (uncoded) partitions.
        var escaped = 0
        /// Subframes with wasted bits.
        var wasted = 0
        /// Frames in each stereo mode: independent, left/side, right/side, mid/side.
        var independent = 0, leftSide = 0, rightSide = 0, midSide = 0
        /// Frames with the variable-block-size strategy.
        var variable = 0
    }

    /// Decodes a whole FLAC stream.
    ///
    /// - Throws: ``WavetableError`` when the stream is not FLAC, is cut short, uses a reserved or
    ///   invalid code, or fails a CRC or the MD5 signature.
    static func decode(_ bytes: [UInt8], fileName: String) throws -> Decoded {
        let what = "\"\(fileName)\" is a FLAC file, but"
        guard bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            throw WavetableError(.damaged, "\"\(fileName)\" is not a FLAC file.")
        }
        // Metadata blocks.
        var off = 4
        var info: StreamInfo?
        var applications: [(id: [UInt8], body: [UInt8])] = []
        var comments: [(key: String, value: String)] = []
        var last = false
        while !last {
            guard off + 4 <= bytes.count else { throw WavetableError(.damaged, "\(what) it ends inside its header; it is cut short.") }
            let header = bytes[off]
            last = header & 0x80 != 0
            let type = Int(header & 0x7F)
            let length = Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            let body = off + 4
            guard body + length <= bytes.count else {
                throw WavetableError(.damaged, "\(what) a header block (type \(type)) runs past the end of the file; it is cut short.")
            }
            if type == 127 { throw WavetableError(.damaged, "\(what) a header block has the invalid type 127; it is damaged.") }
            if info == nil, type != 0 {
                throw WavetableError(.damaged, "\(what) it does not begin with its stream description (STREAMINFO); it is damaged.")
            }
            switch type {
            case 0:
                guard length >= 34 else { throw WavetableError(.damaged, "\(what) its stream description (STREAMINFO) is too short; it is damaged.") }
                let s = Array(bytes[body..<(body + 34)])
                var x: UInt64 = 0
                for k in 10..<18 { x = x << 8 | UInt64(s[k]) }
                let i = StreamInfo(minBlockSize: Int(s[0]) << 8 | Int(s[1]), maxBlockSize: Int(s[2]) << 8 | Int(s[3]),
                                   minFrameSize: Int(s[4]) << 16 | Int(s[5]) << 8 | Int(s[6]),
                                   maxFrameSize: Int(s[7]) << 16 | Int(s[8]) << 8 | Int(s[9]),
                                   sampleRate: Int(x >> 44), channels: Int((x >> 41) & 7) + 1,
                                   bitsPerSample: Int((x >> 36) & 31) + 1, totalSamples: Int(x & ((1 << 36) - 1)),
                                   md5: Array(s[18..<34]))
                guard (4...32).contains(i.bitsPerSample) else {
                    throw WavetableError(.damaged, "\(what) its stream description says \(i.bitsPerSample)-bit samples, outside FLAC’s 4 to 32; it is damaged.")
                }
                guard i.maxBlockSize >= 1 else { throw WavetableError(.damaged, "\(what) its stream description gives no block size; it is damaged.") }
                info = i
            case 2:
                guard length >= 4 else { throw WavetableError(.damaged, "\(what) an application block is shorter than its 4-byte id; it is damaged.") }
                applications.append((Array(bytes[body..<(body + 4)]), Array(bytes[(body + 4)..<(body + length)])))
            case 4:
                comments += vorbisComments(bytes, body..<(body + length))
            default: break   // PADDING, SEEKTABLE, CUESHEET, PICTURE, and reserved types
            }
            off = body + length
        }
        guard let streamInfo = info else { throw WavetableError(.damaged, "\(what) it has no stream description (STREAMINFO); it is damaged.") }

        // Frames.
        var out: [Float] = []
        // The header's sample count guides the reservation but cannot be trusted with memory: a
        // damaged or hostile header could claim 2³⁶ samples. The file itself bounds it (a FLAC
        // frame never shrinks below about a quarter of a byte per sample at these bit depths).
        out.reserveCapacity(min(streamInfo.totalSamples > 0 ? streamInfo.totalSamples : 65_536, bytes.count * 4))
        var frames = 0
        let wantMD5 = streamInfo.md5.contains { $0 != 0 }
        var md5 = MD5()
        var decoded = 0
        var stats = Stats()
        try bytes.withUnsafeBufferPointer { buffer in
            var reader = Bits(buffer, position: off)
            var frame = FrameDecoder(info: streamInfo, what: what)
            while reader.position < buffer.count {
                if streamInfo.totalSamples > 0, decoded >= streamInfo.totalSamples { break }   // trailing bytes (a tag, say)
                let n: Int
                do { n = try frame.decodeFrame(&reader) } catch is Bits.CutShort {
                    throw WavetableError(.damaged, "\(what) it ends in the middle of frame \(frames); it is cut short or damaged.")
                }
                frames += 1
                decoded += n
                if streamInfo.totalSamples > 0, decoded > streamInfo.totalSamples {
                    throw WavetableError(.damaged, "\(what) it holds more samples than its stream description promises (\(WavetableReader.grouped(streamInfo.totalSamples))); it is damaged.")
                }
                let scale = Float(1) / Float(1 << (streamInfo.bitsPerSample - 1))
                let ch = frame.buffers.channels[0]
                for i in 0..<n { out.append(Float(ch[i]) * scale) }
                if wantMD5 { frame.feed(&md5, count: n) }
            }
            stats = frame.stats
        }
        guard frames > 0 else { throw WavetableError(.damaged, "\(what) it holds no audio frames; it is damaged or cut short.") }
        if streamInfo.totalSamples > 0, decoded < streamInfo.totalSamples {
            throw WavetableError(.damaged, "\(what) it ends after \(WavetableReader.grouped(decoded)) of the \(WavetableReader.grouped(streamInfo.totalSamples)) samples its stream description promises; it is cut short.")
        }
        if wantMD5, md5.finish() != streamInfo.md5 {
            throw WavetableError(.damaged, "\(what) its audio does not match the MD5 signature in its stream description; it is damaged.")
        }
        return Decoded(info: streamInfo, firstChannel: out, applications: applications, comments: comments, frames: frames,
                       stats: stats)
    }

    /// The fields of a VORBIS_COMMENT block, split at the first "=". A malformed block gives what
    /// could be read of it.
    private static func vorbisComments(_ b: [UInt8], _ range: Range<Int>) -> [(key: String, value: String)] {
        var o = range.lowerBound
        func u32() -> Int? {
            guard o + 4 <= range.upperBound else { return nil }
            defer { o += 4 }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard let vendorLength = u32(), o + vendorLength <= range.upperBound else { return [] }
        o += vendorLength
        guard let count = u32() else { return [] }
        var fields: [(key: String, value: String)] = []
        for _ in 0..<count {
            guard let length = u32(), o + length <= range.upperBound else { break }
            let text = String(decoding: b[o..<(o + length)], as: UTF8.self)
            o += length
            if let eq = text.firstIndex(of: "=") {
                fields.append((String(text[..<eq]), String(text[text.index(after: eq)...])))
            } else {
                fields.append((text, ""))
            }
        }
        return fields
    }

    // MARK: - Bit reading

    /// A big-endian bit reader over the file's bytes. The bits not yet consumed sit at the top of
    /// `buffer`, `count` of them; the bits below them are zero.
    struct Bits {
        let bytes: UnsafeBufferPointer<UInt8>
        /// The next byte to load into the buffer.
        var position: Int
        var buffer: UInt64 = 0
        var count: Int = 0

        init(_ bytes: UnsafeBufferPointer<UInt8>, position: Int) {
            self.bytes = bytes; self.position = position
        }

        /// The byte position of the next unread bit (only meaningful when byte-aligned).
        var bytePosition: Int { position - count / 8 }

        @inline(__always)
        mutating func refill() {
            while count <= 56, position < bytes.count {
                buffer |= UInt64(bytes[position]) << UInt64(56 - count)
                count += 8
                position += 1
            }
        }

        /// The next `n` bits (0–56) as an unsigned value.
        @inline(__always)
        mutating func read(_ n: Int) throws -> UInt64 {
            if n == 0 { return 0 }
            if count < n {
                refill()
                guard count >= n else { throw cutShort }
            }
            let v = buffer >> UInt64(64 - n)
            buffer <<= UInt64(n)
            count -= n
            return v
        }

        /// The next `n` bits (1–56) as a two's-complement signed value.
        @inline(__always)
        mutating func readSigned(_ n: Int) throws -> Int {
            let v = try read(n)
            return Int(Int64(bitPattern: v << UInt64(64 - n)) >> Int64(64 - n))
        }

        /// The number of zero bits before the next one bit, consuming the one too.
        @inline(__always)
        mutating func readUnary() throws -> Int {
            var zeros = 0
            while true {
                if buffer == 0 {
                    zeros += count
                    count = 0
                    refill()
                    guard count > 0 else { throw cutShort }
                    continue
                }
                let lz = buffer.leadingZeroBitCount
                zeros += lz
                buffer <<= UInt64(lz + 1)
                count -= lz + 1
                return zeros
            }
        }

        /// Drops the bits up to the next byte boundary.
        @inline(__always)
        mutating func alignToByte() {
            let drop = count % 8
            buffer <<= UInt64(drop)
            count -= drop
        }

        /// Thrown when the bytes run out; `decode` turns it into a sentence naming the file.
        struct CutShort: Error {}
        var cutShort: CutShort { CutShort() }
    }

    // MARK: - Frames

    /// One frame's samples, a buffer per channel, each of FLAC's largest block size.
    final class SampleBuffers {
        let channels: [UnsafeMutablePointer<Int>]
        static let capacity = 65_536
        init(channels n: Int) {
            channels = (0..<n).map { _ in
                let p = UnsafeMutablePointer<Int>.allocate(capacity: SampleBuffers.capacity)
                p.initialize(repeating: 0, count: SampleBuffers.capacity)
                return p
            }
        }
        deinit { for p in channels { p.deallocate() } }
    }

    /// Decodes frames one after another, keeping the per-frame buffers between them.
    struct FrameDecoder {
        let info: StreamInfo
        let what: String
        /// Each channel's samples of the last frame (`blockSize` of them are valid).
        let buffers: SampleBuffers
        var blockSize = 0
        var frameNumber = 0
        var stats = Stats()
        private var md5Bytes: [UInt8] = []

        init(info: StreamInfo, what: String) {
            self.info = info
            self.what = what
            buffers = SampleBuffers(channels: info.channels)
        }

        private func damaged(_ reason: String) -> WavetableError {
            WavetableError(.damaged, "\(what) frame \(frameNumber) \(reason); it is damaged.")
        }

        /// Decodes the next frame into `channels` and returns its block size.
        mutating func decodeFrame(_ r: inout Bits) throws -> Int {
            r.alignToByte()
            let start = r.bytePosition
            // Header.
            guard try r.read(15) == 0x7FFC else { throw damaged("does not begin with a frame sync code") }
            let variableBlocking = try r.read(1) == 1
            let blockCode = Int(try r.read(4)), rateCode = Int(try r.read(4))
            let channelCode = Int(try r.read(4)), sizeCode = Int(try r.read(3))
            guard try r.read(1) == 0 else { throw damaged("sets a reserved bit in its header") }
            // The frame or sample number, UTF-8 coded: up to 7 bytes.
            let first = Int(try r.read(8))
            var extra = 0
            if first & 0x80 != 0 {
                var m = 0x40
                while first & m != 0, extra < 7 { extra += 1; m >>= 1 }
                guard extra <= (variableBlocking ? 6 : 5), extra >= 1 else { throw damaged("has an unreadable frame number") }
                for _ in 0..<extra { guard try r.read(8) & 0xC0 == 0x80 else { throw damaged("has an unreadable frame number") } }
            }
            var n: Int
            switch blockCode {
            case 0: throw damaged("uses the reserved block size code 0")
            case 1: n = 192
            case 2...5: n = 576 << (blockCode - 2)
            case 6: n = Int(try r.read(8)) + 1
            case 7: n = Int(try r.read(16)) + 1
            default: n = 256 << (blockCode - 8)
            }
            switch rateCode {
            case 12: _ = try r.read(8)
            case 13, 14: _ = try r.read(16)
            case 15: throw damaged("uses the invalid sample rate code 15")
            default: break
            }
            var bits: Int
            switch sizeCode {
            case 0: bits = info.bitsPerSample
            case 1: bits = 8
            case 2: bits = 12
            case 3: throw damaged("uses the reserved sample size code 3")
            case 4: bits = 16
            case 5: bits = 20
            case 6: bits = 24
            default: bits = 32
            }
            guard bits == info.bitsPerSample else {
                throw damaged("says \(bits)-bit samples, but the stream description says \(info.bitsPerSample)-bit")
            }
            let channelCount: Int, mode: Int   // mode: 0 independent, 8 left/side, 9 right/side, 10 mid/side
            switch channelCode {
            case 0...7: channelCount = channelCode + 1; mode = 0
            case 8, 9, 10: channelCount = 2; mode = channelCode
            default: throw damaged("uses a reserved channel layout (\(channelCode))")
            }
            guard channelCount == info.channels else {
                throw damaged("has \(channelCount) channels, but the stream description says \(info.channels)")
            }
            r.alignToByte()
            let crc8 = Int(try r.read(8))
            guard CRC.crc8(r.bytes, start..<(r.bytePosition - 1)) == crc8 else { throw damaged("fails its header checksum (CRC-8)") }
            blockSize = n
            if variableBlocking { stats.variable += 1 }
            switch mode {
            case 8: stats.leftSide += 1
            case 9: stats.rightSide += 1
            case 10: stats.midSide += 1
            default: if channelCount == 2 { stats.independent += 1 }
            }

            // Subframes.
            for c in 0..<channelCount {
                let sideBit = (mode == 8 && c == 1) || (mode == 9 && c == 0) || (mode == 10 && c == 1)
                try decodeSubframe(&r, channel: c, bits: bits + (sideBit ? 1 : 0), count: n)
            }
            r.alignToByte()
            let end = r.bytePosition
            let crc16 = Int(try r.read(16))
            guard CRC.crc16(r.bytes, start..<end) == crc16 else { throw damaged("fails its checksum (CRC-16)") }

            // Stereo decorrelation.
            if mode != 0 {
                let a = buffers.channels[0], b = buffers.channels[1]
                switch mode {
                case 8: for i in 0..<n { b[i] = a[i] &- b[i] }                  // left, side → right = left − side
                case 9: for i in 0..<n { a[i] = b[i] &+ a[i] }                  // side, right → left = right + side
                default:                                                         // mid, side
                    for i in 0..<n {
                        let side = b[i]
                        let mid = a[i] << 1 | (side & 1)
                        a[i] = (mid &+ side) >> 1
                        b[i] = (mid &- side) >> 1
                    }
                }
            }
            frameNumber += 1
            return n
        }

        private mutating func decodeSubframe(_ r: inout Bits, channel: Int, bits: Int, count n: Int) throws {
            guard try r.read(1) == 0 else { throw damaged("sets a reserved bit in a subframe header") }
            let type = Int(try r.read(6))
            var wasted = 0
            if try r.read(1) == 1 { wasted = try r.readUnary() + 1 }
            let depth = bits - wasted
            guard depth >= 1, depth <= 33 else { throw damaged("has a subframe with no bits per sample left after its wasted bits") }
            var order = 0
            enum Kind { case constant, verbatim, fixed, lpc }
            let kind: Kind
            switch type {
            case 0: kind = .constant; stats.constant += 1
            case 1: kind = .verbatim; stats.verbatim += 1
            case 8...12: kind = .fixed; order = type - 8; stats.fixed += 1
            case 32...63: kind = .lpc; order = type - 31; stats.lpc += 1
            default: throw damaged("uses a reserved subframe type (\(type))")
            }
            if wasted > 0 { stats.wasted += 1 }
            let s = buffers.channels[channel]
            do {
                switch kind {
                case .constant:
                    let v = try r.readSigned(depth)
                    for i in 0..<n { s[i] = v }
                case .verbatim:
                    for i in 0..<n { s[i] = try r.readSigned(depth) }
                case .fixed:
                    guard order <= n else { throw damaged("has a predictor of higher order than its block has samples") }
                    for i in 0..<order { s[i] = try r.readSigned(depth) }
                    try decodeResidual(&r, into: s, count: n, order: order)
                    switch order {
                    case 1: for i in 1..<n { s[i] &+= s[i - 1] }
                    case 2: for i in 2..<n { s[i] &+= 2 &* s[i - 1] &- s[i - 2] }
                    case 3: for i in 3..<n { s[i] &+= 3 &* s[i - 1] &- 3 &* s[i - 2] &+ s[i - 3] }
                    case 4: for i in 4..<n { s[i] &+= 4 &* s[i - 1] &- 6 &* s[i - 2] &+ 4 &* s[i - 3] &- s[i - 4] }
                    default: break
                    }
                case .lpc:
                    guard order <= n else { throw damaged("has a predictor of higher order than its block has samples") }
                    for i in 0..<order { s[i] = try r.readSigned(depth) }
                    let precision = Int(try r.read(4)) + 1
                    guard precision <= 15 else { throw damaged("uses the invalid predictor precision code 15") }
                    let shift = try r.readSigned(5)
                    guard shift >= 0 else { throw damaged("has a negative predictor shift") }
                    var coefficients = [Int](repeating: 0, count: order)
                    for j in 0..<order { coefficients[j] = try r.readSigned(precision) }
                    try decodeResidual(&r, into: s, count: n, order: order)
                    coefficients.withUnsafeBufferPointer { q in
                        for i in order..<n {
                            var sum = 0
                            for j in 0..<order { sum &+= q[j] &* s[i - 1 - j] }
                            s[i] &+= sum >> shift
                        }
                    }
                }
                if wasted > 0 { for i in 0..<n { s[i] <<= wasted } }
            }
        }

        /// The residual of a FIXED or LPC subframe, into `s[order..<n]`.
        private mutating func decodeResidual(_ r: inout Bits, into s: UnsafeMutablePointer<Int>, count n: Int, order: Int) throws {
            let method = Int(try r.read(2))
            guard method <= 1 else { throw damaged("uses a reserved residual coding method (\(method))") }
            if method == 1 { stats.rice2 += 1 }
            let parameterBits = method == 0 ? 4 : 5
            let escape = (1 << parameterBits) - 1
            let partitionOrder = Int(try r.read(4))
            let partitions = 1 << partitionOrder
            guard n % partitions == 0 else { throw damaged("splits a block of \(WavetableReader.grouped(n)) samples into \(partitions) partitions, which does not divide") }
            let perPartition = n >> partitionOrder
            guard perPartition >= order else { throw damaged("has a residual partition smaller than its predictor order") }
            var i = order
            for p in 0..<partitions {
                let end = (p + 1) * perPartition
                let parameter = Int(try r.read(parameterBits))
                if parameter == escape {
                    stats.escaped += 1
                    let raw = Int(try r.read(5))
                    if raw == 0 { while i < end { s[i] = 0; i += 1 } }
                    else { while i < end { s[i] = try r.readSigned(raw); i += 1 } }
                } else {
                    while i < end {
                        let q = try r.readUnary()
                        let remainder = try r.read(parameter)
                        let v = (UInt64(q) << UInt64(parameter)) | remainder
                        s[i] = Int(bitPattern: UInt(v >> 1)) ^ -Int(v & 1)
                        i += 1
                    }
                }
            }
        }

        /// Feeds the last frame's samples (interleaved, little-endian, at the stream's byte size)
        /// to the MD5 signature.
        mutating func feed(_ md5: inout MD5, count n: Int) {
            let bytesPerSample = (info.bitsPerSample + 7) / 8
            let channels = buffers.channels
            let total = n * channels.count * bytesPerSample
            if md5Bytes.count < total { md5Bytes = [UInt8](repeating: 0, count: total) }
            md5Bytes.withUnsafeMutableBufferPointer { out in
                var o = 0
                for i in 0..<n {
                    for c in channels {
                        let v = c[i]
                        for k in 0..<bytesPerSample { out[o] = UInt8(truncatingIfNeeded: v >> (8 * k)); o += 1 }
                    }
                }
            }
            md5Bytes.withUnsafeBufferPointer { md5.update(UnsafeBufferPointer(rebasing: $0[0..<total])) }
        }
    }

    // MARK: - Checksums

    enum CRC {
        /// CRC-8, polynomial 0x07, of the bytes in `range`.
        static func crc8(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
            var crc: UInt8 = 0
            for i in range { crc = table8[Int(crc ^ b[i])] }
            return Int(crc)
        }

        /// CRC-16, polynomial 0x8005, of the bytes in `range`.
        static func crc16(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
            var crc: UInt16 = 0
            for i in range { crc = (crc << 8) ^ table16[Int((crc >> 8) ^ UInt16(b[i]))] }
            return Int(crc)
        }

        static let table8: [UInt8] = (0..<256).map { i in
            var c = UInt8(i)
            for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
            return c
        }

        static let table16: [UInt16] = (0..<256).map { i in
            var c = UInt16(i) << 8
            for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
            return c
        }
    }

    /// MD5 (RFC 1321), for the signature in STREAMINFO.
    struct MD5 {
        private var a: UInt32 = 0x6745_2301, b: UInt32 = 0xEFCD_AB89, c: UInt32 = 0x98BA_DCFE, d: UInt32 = 0x1032_5476
        private var pending: [UInt8] = []
        private var length: UInt64 = 0

        private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                               5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                               4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                               6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        private static let constants: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296.0)) }

        init() {}

        /// Adds bytes to the message.
        mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
            length &+= UInt64(bytes.count)
            var i = 0
            if !pending.isEmpty {
                let take = min(64 - pending.count, bytes.count)
                pending.append(contentsOf: bytes[0..<take])
                i = take
                if pending.count == 64 {
                    pending.withUnsafeBufferPointer { block($0, 0) }
                    pending.removeAll(keepingCapacity: true)
                } else { return }
            }
            while i + 64 <= bytes.count { block(bytes, i); i += 64 }
            if i < bytes.count { pending.append(contentsOf: bytes[i...]) }
        }

        /// The 16-byte digest.
        mutating func finish() -> [UInt8] {
            var tail = pending + [0x80]
            while tail.count % 64 != 56 { tail.append(0) }
            let bits = length &* 8
            for k in 0..<8 { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(k)))) }
            tail.withUnsafeBufferPointer { p in
                var o = 0
                while o < p.count { block(p, o); o += 64 }
            }
            var digest: [UInt8] = []
            for v in [a, b, c, d] { for k in 0..<4 { digest.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(k)))) } }
            return digest
        }

        private mutating func block(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) {
            var m = [UInt32](repeating: 0, count: 16)
            for k in 0..<16 {
                let j = o + 4 * k
                m[k] = UInt32(p[j]) | UInt32(p[j + 1]) << 8 | UInt32(p[j + 2]) << 16 | UInt32(p[j + 3]) << 24
            }
            var aa = a, bb = b, cc = c, dd = d
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (bb & cc) | (~bb & dd); g = i
                case 16..<32: f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16
                case 32..<48: f = bb ^ cc ^ dd; g = (3 * i + 5) % 16
                default: f = cc ^ (bb | ~dd); g = (7 * i) % 16
                }
                f = f &+ aa &+ MD5.constants[i] &+ m[g]
                aa = dd; dd = cc; cc = bb
                bb = bb &+ (f << MD5.shifts[i] | f >> (32 - MD5.shifts[i]))
            }
            a &+= aa; b &+= bb; c &+= cc; d &+= dd
        }
    }
}
