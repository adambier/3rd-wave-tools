import Foundation

// WAV files: the RIFF chunks a wavetable can carry, and the order in which they settle the frame
// size. Sources for the conventions: the project's research notes (Serum's `clm ` chunk and `.txt`
// sidecar, Vital's and Surge's source code, Tonverk's manual, WaveEdit's source), and a scan of
// about 20,000 files from sample and wavetable libraries (docs/WAVETABLES.md, section 3).
//
// Frame size, first rule that applies wins:
//   1. `clm ` chunk number      2. `srge` chunk          3. `uhWT` chunk (its own size field, else 2,048)
//   4. Tonverk `_wt<N>` tag      5. Serum sidecar `[N]`   6. evenly spaced `cue ` points
//   7. a `smpl` loop from sample 0   8. the file's length
// Rules 1–5 are written for the purpose and are trusted as long as one whole frame fits; samples
// past the last whole frame are left out. Rules 6 and 7 are markers ordinary samples have too,
// so they count only for powers of two up to 4,096 that give at least two frames. An `srgo`
// chunk marks a one-shot sample: no wavetable.

extension WavetableReader {
    /// A size claim from one of the file's sources of metadata.
    fileprivate struct SizeClaim {
        var size: Int
        /// Which source made it.
        var source: FrameSizeSource
        /// Short phrase for `FoundTable.frameSizeBasis`.
        var basis: String
        /// The source as the subject of a sentence ("the tag inside the file (clm chunk)").
        var subject: String
        /// What kind of source it is.
        var evidence: FrameSizeEvidence
    }

    /// An interpolation claim from one of the file's sources of metadata.
    fileprivate struct InterpolationClaim {
        var value: Interpolation
        var source: FrameSizeSource
        var subject: String
    }

    /// The audio and chunks of a WAV, decoded. (The FLAC reader builds one too, with its
    /// application blocks as the chunks, and hands it to the same rules.)
    struct DecodedWAV {
        /// The first (left) channel's samples.
        var samples: [Float]
        var channels: Int
        var bytesPerSample: Int
        /// The body of the first chunk of each id, except `data`.
        var chunks: [String: [UInt8]]
        var notes: [ReadNote]
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
                throw WavetableError(.unsupported, "\"\(fileName)\" is marked as a wavetable, but \(reason)")
            }
            return []
        case let .audio(w): wav = w
        }
        return try tables(in: wav, fileName: fileName, sidecarText: sidecarText, source: .wav, chunkWord: "chunk")
    }

    /// The frame-size rules, applied to decoded audio and its metadata chunks: the wavetable in
    /// it, or none. `chunkWord` names the kind of container the chunks came from in the text
    /// shown to the user ("chunk" in a WAV, "block" in a FLAC file).
    static func tables(in wav: DecodedWAV, fileName: String, sidecarText: String?, source sourceFormat: SourceFormat,
                       chunkWord: String) throws -> [FoundTable] {
        let stem = fileStem(fileName)
        let tag = tonverkTag(in: stem)
        if wav.chunks["srgo"] != nil { return [] }   // Surge's one-shot sample marker
        let count = wav.samples.count
        guard count > 0 else { return [] }

        var notes = wav.notes
        if wav.channels == 2 {
            notes.append(ReadNote(.channelsDropped(used: 1, of: 2), "Stereo file: only the left channel is used."))
        } else if wav.channels > 2 {
            notes.append(ReadNote(.channelsDropped(used: 1, of: wav.channels),
                                  "The file has \(wav.channels) channels: only the first is used."))
        }
        var sizes: [SizeClaim] = []
        var interps: [InterpolationClaim] = []
        /// Size claims that cannot be used, each with the reason as a clause.
        var rejected: [(kind: ReadNote.Kind, reason: String)] = []
        // Metadata written for the purpose (clm, srge, uhWT, a Tonverk tag, a Serum sidecar) is
        // trusted when at least one whole frame fits, even when the samples run past the last
        // whole frame, as in files from some editors and in Surge's own library; the extra samples
        // are then left out.
        func offer(_ size: Int, source: FrameSizeSource, basis: String, subject: String,
                   evidence: FrameSizeEvidence = .statedInFile) {
            if size >= 2, count >= size {
                sizes.append(SizeClaim(size: size, source: source, basis: basis, subject: subject, evidence: evidence))
            } else if size < 2 {
                rejected.append((.sizeTagRejected(source: source, size: size, reason: .unusableSize),
                                 "\(subject) says \(grouped(size)) \(size == 1 ? "sample" : "samples") per frame, which is not a usable size"))
            } else {
                rejected.append((.sizeTagRejected(source: source, size: size, reason: .fileShorterThanFrame(samples: count)),
                                 "\(subject) says \(grouped(size)) samples per frame, and the file holds only "
                                 + "\(grouped(count)) \(count == 1 ? "sample" : "samples"), less than one frame"))
            }
        }

        // 1. clm (Serum): "<!>2048 10000000 wavetable ...": any frame size, and the interpolation digit.
        if let clm = wav.chunks["clm "] {
            let parsed = parseCLM(clm)
            let subject = "the Serum-style tag inside the file (clm \(chunkWord))"
            if let n = parsed.size {
                offer(n, source: .clmChunk, basis: "Serum-style tag inside the file (clm \(chunkWord))", subject: subject)
            } else {
                notes.append(ReadNote(.sizeTagUnreadable(source: .clmChunk),
                                      "The file's wavetable tag (clm \(chunkWord)) does not give a readable frame size; it is ignored."))
            }
            if let i = parsed.interpolation { interps.append(InterpolationClaim(value: i, source: .clmChunk, subject: subject)) }
        }
        // 2. srge (Surge): int32 version, int32 frame size.
        if let srge = wav.chunks["srge"] {
            if srge.count >= 8 {
                offer(Int(Int32(bitPattern: le32(srge, 4))), source: .srgeChunk,
                      basis: "Surge tag inside the file (srge \(chunkWord))",
                      subject: "the Surge tag inside the file (srge \(chunkWord))")
            } else {
                notes.append(ReadNote(.sizeTagUnreadable(source: .srgeChunk),
                                      "The file's Surge tag (srge \(chunkWord)) is too short to give a frame size; it is ignored."))
            }
        }
        // 3. uhWT (u-he). Surge reads it as 2,048 only. In the 76 files of Hive's library the chunk
        // is 272 bytes: u32 0, u32 frame count, u32 frame size (2,048 in all of them), u32 0, then a
        // description; that size field is used when it is plausible, else 2,048 (an inference from
        // those files, not documented by u-he).
        if let uh = wav.chunks["uhWT"] {
            var n = 2048
            if uh.count >= 12 {
                let stated = Int(le32(uh, 8))
                if (2...65_536).contains(stated), stated & (stated - 1) == 0 { n = stated }
            }
            offer(n, source: .uhWTChunk, basis: "u-he tag inside the file (uhWT \(chunkWord))",
                  subject: "the u-he tag inside the file (uhWT \(chunkWord))")
        }
        // 4. Tonverk file-name tag.
        if let t = tag {
            let subject = "the file name (\(t.text))"
            let source = FrameSizeSource.tonverkFileName(tag: t.text)
            offer(t.size, source: source, basis: "Tonverk tag in the file name (\(t.text))", subject: subject, evidence: .fileName)
            if t.stepped { interps.append(InterpolationClaim(value: .none, source: source, subject: subject)) }
        }
        // 5. Serum sidecar text.
        if let text = sidecarText {
            let s = parseSidecar(text)
            if let n = s.size {
                if (32...9999).contains(n) {
                    offer(n, source: .serumSidecar, basis: "Serum .txt file beside it ([\(n)])",
                          subject: "the .txt file beside it ([\(n)])", evidence: .sidecar)
                } else {
                    notes.append(ReadNote(.sidecarOutOfRange(n),
                                          "The .txt file beside it says [\(n)] samples per frame, outside the 32–9,999 Serum accepts; it is ignored."))
                }
            }
            if let i = s.interpolation {
                interps.append(InterpolationClaim(value: i, source: .serumSidecar, subject: "the .txt file beside it"))
            }
        }
        // 6. cue points, evenly spaced from sample 0. Cue points and loops also mark ordinary
        // samples, so these two count only for powers of two up to 4,096 (Surge's limit) that give
        // at least two frames; a single looped cycle is a sample, not a wavetable.
        if let cue = wav.chunks["cue "], let d = cueSpacing(cue), isMarkerFrameSize(d, count: count) {
            offer(d, source: .cueMarkers, basis: "cue markers, evenly spaced (which ordinary samples can have too)",
                  subject: "the cue markers", evidence: .markers)
        }
        // 7. A single smpl loop from sample 0 (the loop over the first frame).
        if let smpl = wav.chunks["smpl"], let loop = singleLoop(smpl), loop.start == 0 {
            // The loop end is inclusive, but some writers store it exclusively.
            if let n = [loop.end - loop.start + 1, loop.end - loop.start].first(where: { isMarkerFrameSize($0, count: count) }) {
                offer(n, source: .loopMarkers, basis: "loop markers over the first frame (which ordinary samples can have too)",
                      subject: "the loop markers", evidence: .markers)
            }
        }

        var frameSize: Int?
        var basis: String
        var source: FrameSizeSource?
        var candidates: [Int] = []
        var evidence = FrameSizeEvidence.none
        notes += rejected.map { ReadNote($0.kind, capitalized($0.reason) + "; it is ignored.") }
        /// No wavetable: silently, unless the file is marked as one whose stated size does not fit.
        func none() throws -> [FoundTable] {
            if let reason = rejected.first?.reason {
                throw WavetableError(.notAWavetable, "\"\(fileName)\" is marked as a wavetable, but \(reason), so nothing can be read from it.")
            }
            return []
        }
        if let chosen = sizes.first {
            frameSize = chosen.size
            basis = chosen.basis
            source = chosen.source
            evidence = chosen.evidence
            for other in sizes.dropFirst() where other.size != chosen.size {
                notes.append(ReadNote(.sizeClaimsDisagree(chosen: chosen.source, chosenSize: chosen.size,
                                                          other: other.source, otherSize: other.size),
                                      "\(capitalized(other.subject)) says \(grouped(other.size)) samples per frame, but "
                                      + "\(chosen.subject) says \(grouped(chosen.size)); \(chosen.subject) is used."))
            }
        } else if wav.channels > 1 || count % 2048 != 0 && count != 8192 || endsWithNoteName(stem) {
            // No metadata, and stereo, a length that is not a multiple of 2,048, or a name that
            // ends in a note name ("Bass-000-036-c2", "Saw C3"), as the notes of a multisampled
            // instrument are named: with nothing to say it is a wavetable, it is taken to be
            // ordinary audio. (Wavetable files without metadata are mono; in the libraries scanned,
            // stereo samples, a few one-shots, and whole multisampled instruments had lengths that
            // happened to divide into frames.)
            return try none()
        } else if count == 8192 {
            // The 3rd Wave's Wave Maker reads this length as a 64 × 128 PPG table, while Serum,
            // Pigments, and Tonverk read 4 × 2,048 (Tonverk's own factory library has one), so ask.
            basis = "not stated: 8,192 samples is 64 frames of 128 (a PPG-style table, as the 3rd Wave's Wave Maker reads it) or 4 frames of 2,048"
            candidates = [128, 2048]
        } else if count == 16_384 {
            basis = "not stated: 16,384 samples is 64 frames of 256 (a WaveEdit bank) or 8 frames of 2,048"
            candidates = wav.bytesPerSample == 2 ? [256, 2048] : [2048, 256]
        } else if count % 2048 == 0 {
            // Length alone: more than the 256 frames Serum, Vital, and Pigments take is taken to be
            // ordinary audio (a 16-second sample at 48 kHz is 375 × 2,048).
            // A single frame is a single cycle, not a wavetable (WAVETABLES.md §3).
            guard count / 2048 <= 256, count >= 2 * 2048 else { return try none() }
            frameSize = 2048
            source = .fileLength
            evidence = .length
            basis = "file length only (2,048 per frame, the usual size; the file does not say)"
            candidates = fittingFrameSizes(count).filter { $0 != 2048 }
        } else {
            return try none()   // unreachable: the first branch takes every other length
        }

        var interpolation: Interpolation?
        if let chosen = interps.first {
            interpolation = chosen.value
            for other in interps.dropFirst() where other.value != chosen.value {
                notes.append(ReadNote(.interpolationClaimsDisagree(chosen: chosen.source, chosenValue: chosen.value,
                                                                   other: other.source, otherValue: other.value),
                                      "\(capitalized(other.subject)) asks for \(describe(other.value)), but \(chosen.subject) "
                                      + "asks for \(describe(chosen.value)); \(chosen.subject) is used."))
            }
        }

        var samples = wav.samples
        if let n = frameSize, count % n != 0 {
            let extra = count % n
            samples.removeLast(extra)
            var note = "\(grouped(extra)) sample\(extra == 1 ? "" : "s") after the last whole frame \(extra == 1 ? "is" : "are") left out"
            var short: Int?
            if extra * 2 >= n {
                let s = n - extra
                short = s
                note += " (\(grouped(s)) sample\(s == 1 ? "" : "s") short of another frame)"
            }
            notes.append(ReadNote(.samplesLeftOut(extra, shortOfAnotherFrame: short), note + "."))
        }
        if let n = frameSize, let note = frameCountNote(count / n) { notes.append(note) }
        if let note = peakNote(wav.samples.reduce(0) { max($0, abs($1)) }) { notes.append(note) }
        var name = stem
        if let t = tag, !t.nameBeforeTag.isEmpty { name = t.nameBeforeTag }
        return [FoundTable(name: name, fileName: fileName, source: sourceFormat, samples: samples, frameSize: frameSize,
                           frameSizeBasis: basis, candidateFrameSizes: candidates, interpolation: interpolation,
                           readNotes: notes, frameSizeEvidence: evidence, frameSizeSource: source)]
    }

    // MARK: Parsing the RIFF structure

    /// Walks the chunks and decodes the first channel. Tolerates a wrong RIFF size, unknown chunks,
    /// odd-sized chunks with or without their pad byte, and a data chunk that runs past the end.
    fileprivate static func parseWAV(_ b: [UInt8], fileName: String) throws -> ParsedWAV {
        let damaged = "\"\(fileName)\" is a WAV file, but"
        var chunks: [String: [UInt8]] = [:]
        var dataRange: Range<Int>?
        var notes: [ReadNote] = []
        var off = 12
        let n = b.count
        while off + 8 <= n {
            let id = String(decoding: b[off..<off + 4], as: UTF8.self)
            let body = off + 8
            var len = Int(le32(b, off + 4))
            if len > n - body {
                if id == "data", len != 0xFFFF_FFFF {
                    notes.append(ReadNote(.cutShort, "The file ends before its audio should (it may have been cut short); what is there is read."))
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
            throw WavetableError(.damaged, "\(damaged) it has no readable format description (fmt chunk), which every WAV needs; it is damaged.")
        }
        guard let data = dataRange else { throw WavetableError(.damaged, "\(damaged) it has no audio data (data chunk); it is damaged.") }
        var tag = Int(le16(fmt, 0))
        let channels = Int(le16(fmt, 2)), blockAlign = Int(le16(fmt, 12)), bits = Int(le16(fmt, 14))
        if tag == 0xFFFE {   // WAVE_FORMAT_EXTENSIBLE: the real format is the subformat GUID's first two bytes
            guard fmt.count >= 26 else {
                throw WavetableError(.damaged, "\(damaged) its format description (an extensible fmt chunk) is cut short; it is damaged.")
            }
            tag = Int(le16(fmt, 24))
        }
        guard channels > 0 else { throw WavetableError(.damaged, "\(damaged) its format description says it has no channels; it is damaged.") }
        var bytesPerSample = (bits + 7) / 8
        if blockAlign >= channels, blockAlign % channels == 0 { bytesPerSample = blockAlign / channels }
        guard bytesPerSample > 0 else {
            throw WavetableError(.damaged, "\(damaged) its format description gives no sample size; it is damaged.")
        }
        let isInt = tag == 1 && (1...4).contains(bytesPerSample)
        let isFloat = tag == 3 && (bytesPerSample == 4 || bytesPerSample == 8)
        guard isInt || isFloat else {
            let what: String
            switch tag {
            case 1, 3: what = "\(bits)-bit \(tag == 3 ? "floating-point" : "integer") samples"
            case 2: what = "ADPCM compression"
            case 6, 7: what = "telephone (A-law or µ-law) compression"
            case 0x50, 0x55: what = "MPEG compression"
            default: what = "an audio format this reader does not handle (format code \(tag))"
            }
            return .unsupported(reason: "its audio uses \(what). Save it as a 16-bit, 24-bit, or 32-bit float WAV and try again.",
                                chunks: chunks)
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
                    throw WavetableError(.damaged, "\(damaged) sample \(grouped(i)) is not a number; it is damaged.")
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
    /// trailing `r` for no interpolation. N must be one of the sizes Tonverk's manual lists (the
    /// powers of two from 64 to 4,096): "KOMPLEXER_WT1" and "Pad_wt2" are names numbering their
    /// tables, not tags (found in Serum libraries), and are left alone.
    fileprivate static func tonverkTag(in stem: String) -> (size: Int, stepped: Bool, text: String, nameBeforeTag: String)? {
        guard let r = stem.range(of: "_wt", options: [.backwards, .caseInsensitive]) else { return nil }
        let rest = stem[r.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let tail = rest.dropFirst(digits.count)
        guard !digits.isEmpty, tail.isEmpty || tail == "r" || tail == "R", let n = Int(digits),
              (64...4096).contains(n), n & (n - 1) == 0 else { return nil }
        let stepped = !tail.isEmpty
        return (n, stepped, "_wt\(digits)\(stepped ? "r" : "")", String(stem[..<r.lowerBound]))
    }

    /// Whether a file stem ends in a note name, as the notes of a multisampled instrument are
    /// named: a letter A–G, an optional sharp, and an octave digit, at the start of the name or
    /// after a space, hyphen, or underscore ("Saw C3", "SAW-C1", "Pad-000-036-c2", "Bass_F#-1").
    /// "Bwt1" or "voc2" do not count: the letter must stand on its own.
    static func endsWithNoteName(_ stem: String) -> Bool {
        var s = Substring(stem)
        guard let octave = s.last, octave.isASCII, octave.isNumber else { return false }
        s = s.dropLast()
        if s.last == "-" { s = s.dropLast() }
        if s.last == "#" { s = s.dropLast() }
        guard let letter = s.last, letter.isASCII, "abcdefg".contains(letter.lowercased()) else { return false }
        s = s.dropLast()
        guard let before = s.last else { return true }
        return before == " " || before == "-" || before == "_"
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

    /// Whether a size from cue points or a loop can be a frame size: a power of two from 2 to
    /// 4,096 (Surge's range) with at least two whole frames in the file.
    fileprivate static func isMarkerFrameSize(_ n: Int, count: Int) -> Bool {
        (2...4096).contains(n) && n & (n - 1) == 0 && count / n >= 2
    }

    /// Powers of two from 64 to 4,096 that divide `count` into 2 to 256 frames.
    fileprivate static func fittingFrameSizes(_ count: Int) -> [Int] {
        (6...12).map { 1 << $0 }.filter { count % $0 == 0 && (2...256).contains(count / $0) }
    }

    fileprivate static func describe(_ i: Interpolation) -> String {
        switch i {
        case .none: return "no interpolation (stepped frames)"
        case .crossfade: return "a crossfade between frames"
        case .spectral: return "a spectral morph between frames"
        }
    }

    fileprivate static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
