import Foundation

// WAV files: the RIFF chunks a wavetable can carry, and the order in which they settle the frame
// size. Sources for the conventions: the project's research notes (Serum's `clm ` chunk and `.txt`
// sidecar, Vital's and Surge's source code, Tonverk's manual, WaveEdit's source).
//
// Frame size, first rule that applies wins (each needs a size of at least 2 that divides the
// sample count; one that does not divide is noted and skipped):
//   1. `clm ` chunk number      2. `srge` chunk          3. `uhWT` chunk → 2,048
//   4. Tonverk `_wt<N>` tag      5. Serum sidecar `[N]`   6. evenly spaced `cue ` points
//   7. a single `smpl` loop      8. the file's length
// An `srgo` chunk marks a one-shot sample: no wavetable.

extension WavetableReader {
    /// A size claim from one of the file's sources of metadata.
    fileprivate struct SizeClaim {
        var size: Int
        /// Short phrase for `FoundTable.frameSizeBasis`.
        var basis: String
        /// The source as the subject of a sentence ("the clm chunk").
        var subject: String
    }

    /// An interpolation claim from one of the file's sources of metadata.
    fileprivate struct InterpolationClaim {
        var value: Interpolation
        var subject: String
    }

    /// The audio and chunks of a WAV, decoded.
    fileprivate struct DecodedWAV {
        /// The first (left) channel's samples.
        var samples: [Float]
        var channels: Int
        var bytesPerSample: Int
        /// The body of the first chunk of each id, except `data`.
        var chunks: [String: [UInt8]]
        var notes: [String]
    }

    /// The parse result: audio, or a well-formed WAV in a sample format this reader does not decode.
    fileprivate enum ParsedWAV {
        case audio(DecodedWAV)
        case unsupported(reason: String, chunks: [String: [UInt8]])
    }

    /// The wavetable in a RIFF/WAVE file, or none when it holds no wavetable.
    static func readWAV(_ b: [UInt8], fileName: String, sidecarText: String?) throws -> [FoundTable] {
        let stem = fileStem(fileName)
        let tag = tonverkTag(in: stem)
        let wav: DecodedWAV
        switch try parseWAV(b, fileName: fileName) {
        case let .unsupported(reason, chunks):
            // Marked as a wavetable: say why it cannot be read. Otherwise it is just audio.
            if ["clm ", "srge", "uhWT"].contains(where: { chunks[$0] != nil }) || tag != nil {
                throw WavetableError("\"\(fileName)\" is marked as a wavetable, but \(reason)")
            }
            return []
        case let .audio(w): wav = w
        }
        if wav.chunks["srgo"] != nil { return [] }   // Surge's one-shot sample marker
        let count = wav.samples.count
        guard count > 0 else { return [] }

        var notes = wav.notes
        if wav.channels > 1 {
            notes.append("The file has \(wav.channels) channels; only the left (first) channel is read.")
        }
        var sizes: [SizeClaim] = []
        var interps: [InterpolationClaim] = []
        // Metadata written for the purpose (clm, srge, uhWT, a Tonverk tag, a Serum sidecar) is
        // trusted even when the samples run a little past the last whole frame, as in files from
        // some editors; the extra samples are then left out. Cue points and loops must divide
        // the file exactly, since ordinary samples have them too.
        func offer(_ size: Int, basis: String, subject: String, explicit: Bool = true) {
            if size >= 2, count % size == 0 || (explicit && count >= size) {
                sizes.append(SizeClaim(size: size, basis: basis, subject: subject))
            } else {
                notes.append("\(capitalized(subject)) gives \(grouped(size)) samples per frame, which does not divide "
                             + "the file's \(grouped(count)) samples, so it is not used.")
            }
        }

        // 1. clm (Serum): "<!>2048 10000000 wavetable ...": any frame size, and the interpolation digit.
        if let clm = wav.chunks["clm "] {
            let parsed = parseCLM(clm)
            if let n = parsed.size { offer(n, basis: "clm chunk", subject: "the clm chunk") }
            else { notes.append("The file's clm chunk does not give a frame size Convert can read.") }
            if let i = parsed.interpolation { interps.append(InterpolationClaim(value: i, subject: "the clm chunk")) }
        }
        // 2. srge (Surge): int32 version, int32 frame size.
        if let srge = wav.chunks["srge"] {
            if srge.count >= 8 {
                offer(Int(Int32(bitPattern: le32(srge, 4))), basis: "Surge srge chunk", subject: "the Surge srge chunk")
            } else {
                notes.append("The file's Surge srge chunk is too short to give a frame size.")
            }
        }
        // 3. uhWT (u-he): 2,048.
        if wav.chunks["uhWT"] != nil { offer(2048, basis: "u-he uhWT chunk", subject: "the u-he uhWT chunk") }
        // 4. Tonverk file-name tag.
        if let t = tag {
            let subject = "the Tonverk tag in the file name (\(t.text))"
            offer(t.size, basis: "Tonverk file name (\(t.text))", subject: subject)
            if t.stepped { interps.append(InterpolationClaim(value: .none, subject: subject)) }
        }
        // 5. Serum sidecar text.
        if let text = sidecarText {
            let s = parseSidecar(text)
            if let n = s.size {
                if (32...9999).contains(n) {
                    offer(n, basis: "Serum .txt sidecar ([\(n)])", subject: "the Serum .txt sidecar ([\(n)])")
                } else {
                    notes.append("The Serum .txt sidecar gives [\(n)], outside the 32–9,999 Serum accepts, so it is not used.")
                }
            }
            if let i = s.interpolation { interps.append(InterpolationClaim(value: i, subject: "the Serum .txt sidecar")) }
        }
        // 6. cue points, evenly spaced. Cue points and loops also mark ordinary samples, so these
        // two count only for frame sizes a wavetable can have (at most 4,096, Surge's limit).
        if let cue = wav.chunks["cue "], let d = cueSpacing(cue), d <= 4096 {
            offer(d, basis: "cue points", subject: "the cue points", explicit: false)
        }
        // 7. A single smpl loop.
        if let smpl = wav.chunks["smpl"], let loop = singleLoop(smpl) {
            let inclusive = loop.end - loop.start + 1, exclusive = loop.end - loop.start
            let n = count % inclusive != 0 && exclusive >= 2 && count % exclusive == 0 ? exclusive : inclusive
            if n <= 4096 { offer(n, basis: "smpl loop", subject: "the smpl loop", explicit: false) }
        }

        var frameSize: Int?
        var basis: String
        var candidates: [Int] = []
        if let chosen = sizes.first {
            frameSize = chosen.size
            basis = chosen.basis
            for other in sizes.dropFirst() where other.size != chosen.size {
                notes.append("\(capitalized(other.subject)) gives \(grouped(other.size)) samples per frame, but "
                             + "\(chosen.subject) gives \(grouped(chosen.size)); \(chosen.subject) is used.")
            }
        } else if count == 8192 {
            frameSize = 128
            basis = "length 8,192: the 64 × 128 layout the 3rd Wave's Wave Maker reads as a PPG table"
            candidates = fittingFrameSizes(count).filter { $0 != 128 }
        } else if count == 16_384 {
            basis = "length 16,384: WaveEdit's 64 × 256 or 8 × 2,048; the file does not say which"
            candidates = wav.bytesPerSample == 2 ? [256, 2048] : [2048, 256]
        } else if count % 2048 == 0 {
            // Length alone: longer than Surge's 512 frames is taken to be ordinary audio.
            guard count / 2048 <= 512 else { return [] }
            frameSize = 2048
            basis = "file length (multiples of 2,048, the Serum convention)"
            candidates = fittingFrameSizes(count).filter { $0 != 2048 }
        } else {
            // No metadata and a length that is not a multiple of 2,048: with nothing to say it is
            // a wavetable, it is taken to be ordinary audio. (Among one collection's 700 or so
            // percussion samples, a few had lengths that happened to divide into frames.)
            return []
        }

        var interpolation: Interpolation?
        if let chosen = interps.first {
            interpolation = chosen.value
            for other in interps.dropFirst() where other.value != chosen.value {
                notes.append("\(capitalized(other.subject)) asks for \(describe(other.value)), but \(chosen.subject) "
                             + "asks for \(describe(chosen.value)); \(chosen.subject) is used.")
            }
        }

        var samples = wav.samples
        if let n = frameSize, count % n != 0 {
            let extra = count % n
            samples.removeLast(extra)
            notes.append("The file has \(grouped(extra)) sample\(extra == 1 ? "" : "s") after its last whole frame of \(grouped(n)); they are left out.")
        }
        if let n = frameSize, let note = frameCountNote(count / n) { notes.append(note) }
        if let note = peakNote(wav.samples.reduce(0) { max($0, abs($1)) }) { notes.append(note) }
        var name = stem
        if let t = tag, !t.nameBeforeTag.isEmpty { name = t.nameBeforeTag }
        return [FoundTable(name: name, fileName: fileName, source: .wav, samples: samples, frameSize: frameSize,
                           frameSizeBasis: basis, candidateFrameSizes: candidates, interpolation: interpolation,
                           notes: notes)]
    }

    // MARK: Parsing the RIFF structure

    /// Walks the chunks and decodes the first channel. Tolerates a wrong RIFF size, unknown chunks,
    /// odd-sized chunks with or without their pad byte, and a data chunk that runs past the end.
    fileprivate static func parseWAV(_ b: [UInt8], fileName: String) throws -> ParsedWAV {
        let damaged = "\"\(fileName)\" is a WAV file, but"
        var chunks: [String: [UInt8]] = [:]
        var dataRange: Range<Int>?
        var notes: [String] = []
        var off = 12
        let n = b.count
        while off + 8 <= n {
            let id = String(decoding: b[off..<off + 4], as: UTF8.self)
            let body = off + 8
            var len = Int(le32(b, off + 4))
            if len > n - body {
                if id == "data", len != 0xFFFF_FFFF {
                    notes.append("The file is shorter than its data chunk says (it may have been cut short); "
                                 + "the samples that are there are read.")
                }
                len = n - body
            }
            if id == "data" { if dataRange == nil { dataRange = body..<(body + len) } }
            else if chunks[id] == nil { chunks[id] = Array(b[body..<(body + len)]) }
            var next = body + len
            if len % 2 == 1, next < n {
                // RIFF pads odd chunks to an even length; some writers leave the pad byte out.
                let unpadded = b[next] != 0 && looksLikeChunkID(b, next) && !looksLikeChunkID(b, next + 1)
                if !unpadded { next += 1 }
            }
            off = next
        }
        guard let fmt = chunks["fmt "], fmt.count >= 16 else {
            throw WavetableError("\(damaged) it has no readable format (fmt) chunk, so it is damaged.")
        }
        guard let data = dataRange else { throw WavetableError("\(damaged) it has no data chunk, so it is damaged.") }
        var tag = Int(le16(fmt, 0))
        let channels = Int(le16(fmt, 2)), blockAlign = Int(le16(fmt, 12)), bits = Int(le16(fmt, 14))
        if tag == 0xFFFE {   // WAVE_FORMAT_EXTENSIBLE: the real format is the subformat GUID's first two bytes
            guard fmt.count >= 26 else {
                throw WavetableError("\(damaged) its extensible format chunk is too short, so it is damaged.")
            }
            tag = Int(le16(fmt, 24))
        }
        guard channels > 0 else { throw WavetableError("\(damaged) its format chunk gives no channels, so it is damaged.") }
        var bytesPerSample = (bits + 7) / 8
        if blockAlign >= channels, blockAlign % channels == 0 { bytesPerSample = blockAlign / channels }
        guard bytesPerSample > 0 else {
            throw WavetableError("\(damaged) its format chunk gives no sample size, so it is damaged.")
        }
        let isInt = tag == 1 && (1...4).contains(bytesPerSample)
        let isFloat = tag == 3 && (bytesPerSample == 4 || bytesPerSample == 8)
        guard isInt || isFloat else {
            let what = tag == 1 || tag == 3 ? "\(bits)-bit \(tag == 3 ? "floating-point" : "integer") samples"
                                             : "sample format \(tag)"
            return .unsupported(reason: "it uses \(what), which Convert does not read.", chunks: chunks)
        }
        let frameBytes = bytesPerSample * channels
        let frames = data.count / frameBytes
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let o = data.lowerBound + i * frameBytes
            if isFloat {
                let v: Float = bytesPerSample == 4
                    ? Float(bitPattern: le32(b, o))
                    : Float(Double(bitPattern: UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32))
                guard v.isFinite else {
                    throw WavetableError("\(damaged) sample \(grouped(i)) is not a finite number, so it is damaged.")
                }
                samples[i] = v
            } else if bytesPerSample == 1 {
                samples[i] = (Float(b[o]) - 128) / 128   // 8-bit WAV samples are unsigned
            } else {
                var raw: UInt32 = 0
                for k in 0..<bytesPerSample { raw |= UInt32(b[o + k]) << (8 * k) }
                let shift = UInt32(32 - 8 * bytesPerSample)
                let v = Int32(bitPattern: raw << shift) >> shift
                samples[i] = Float(Double(v) / Double(1 << (8 * bytesPerSample - 1)))
            }
        }
        return .audio(DecodedWAV(samples: samples, channels: channels, bytesPerSample: bytesPerSample,
                                 chunks: chunks, notes: notes))
    }

    /// Whether four printable ASCII characters start at `o`.
    fileprivate static func looksLikeChunkID(_ b: [UInt8], _ o: Int) -> Bool {
        o + 4 <= b.count && b[o..<(o + 4)].allSatisfy { (0x20...0x7E).contains($0) }
    }

    // MARK: Metadata

    /// The frame size and interpolation digit of a `clm ` chunk ("<!>2048 10000000 …"). The digit
    /// is the first character of the second token: 0 none, 1 crossfade, 2–4 spectral.
    fileprivate static func parseCLM(_ body: [UInt8]) -> (size: Int?, interpolation: Interpolation?) {
        let end = body.firstIndex(of: 0) ?? body.count
        let text = String(decoding: body[..<end], as: UTF8.self)
        guard text.hasPrefix("<!>") else { return (nil, nil) }
        let rest = text.dropFirst(3)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let size = Int(digits)
        let after = rest.dropFirst(digits.count).drop { $0 == " " }
        let interpolation: Interpolation?
        switch after.first {
        case "0": interpolation = Interpolation.none
        case "1": interpolation = .crossfade
        case "2", "3", "4": interpolation = .spectral
        default: interpolation = nil
        }
        return (size, interpolation)
    }

    /// A Tonverk tag at the end of a file stem: `_wt<N>`, case-insensitive, with an optional
    /// trailing `r` for no interpolation.
    fileprivate static func tonverkTag(in stem: String) -> (size: Int, stepped: Bool, text: String, nameBeforeTag: String)? {
        guard let r = stem.range(of: "_wt", options: [.backwards, .caseInsensitive]) else { return nil }
        let rest = stem[r.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let tail = rest.dropFirst(digits.count)
        guard !digits.isEmpty, tail.isEmpty || tail == "r" || tail == "R", let n = Int(digits) else { return nil }
        let stepped = !tail.isEmpty
        return (n, stepped, "_wt\(digits)\(stepped ? "r" : "")", String(stem[..<r.lowerBound]))
    }

    /// Serum's sidecar: line 1 `[N]` samples per cycle, optional line 2 `[interp]` or `[no interp]`.
    fileprivate static func parseSidecar(_ text: String) -> (size: Int?, interpolation: Interpolation?) {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func bracketed(_ s: String) -> String? {
            guard s.hasPrefix("["), s.hasSuffix("]"), s.count >= 2 else { return nil }
            return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.first, let inner = bracketed(first) else { return (nil, nil) }
        let size = Int(inner)
        var interpolation: Interpolation?
        if lines.count >= 2, let second = bracketed(lines[1]),
           second.lowercased().filter({ !$0.isWhitespace }) == "nointerp" {
            interpolation = Interpolation.none
        }
        return (size, interpolation)
    }

    /// The spacing of a `cue ` chunk's points, when there are at least two, evenly spaced from a
    /// multiple of the spacing. Uses each point's sample offset, or its position when every sample
    /// offset is 0.
    fileprivate static func cueSpacing(_ body: [UInt8]) -> Int? {
        guard body.count >= 4 else { return nil }
        let count = Int(le32(body, 0))
        guard count >= 2, body.count >= 4 + 24 * count else { return nil }
        let offsets = (0..<count).map { Int(le32(body, 4 + 24 * $0 + 20)) }
        let positions = (0..<count).map { Int(le32(body, 4 + 24 * $0 + 4)) }
        let points = Array(Set(offsets.allSatisfy { $0 == 0 } ? positions : offsets)).sorted()
        guard points.count >= 2 else { return nil }
        let d = points[1] - points[0]
        guard d > 0, points[0] % d == 0, zip(points, points.dropFirst()).allSatisfy({ $1 - $0 == d }) else { return nil }
        return d
    }

    /// The start and end of an `smpl` chunk's loop, when it has exactly one.
    fileprivate static func singleLoop(_ body: [UInt8]) -> (start: Int, end: Int)? {
        guard body.count >= 36, le32(body, 28) == 1, body.count >= 60 else { return nil }
        let start = Int(le32(body, 44)), end = Int(le32(body, 48))
        return end > start ? (start, end) : nil
    }

    /// Powers of two from 64 to 4,096 that divide `count` into 2 to 256 frames.
    fileprivate static func fittingFrameSizes(_ count: Int) -> [Int] {
        (6...12).map { 1 << $0 }.filter { count % $0 == 0 && (2...256).contains(count / $0) }
    }

    fileprivate static func describe(_ i: Interpolation) -> String {
        switch i {
        case .none: return "no interpolation"
        case .crossfade: return "crossfade"
        case .spectral: return "spectral morph"
        }
    }

    fileprivate static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
