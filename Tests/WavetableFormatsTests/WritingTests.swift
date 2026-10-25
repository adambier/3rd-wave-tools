import XCTest
import PgdataFormats
@testable import WavetableFormats

/// Every preset's bytes, parsed back with small parsers of the tests' own (independent of
/// WavetableReader), plus names, notes, and validation.
final class WritingTests: XCTestCase {

    // MARK: Test parsers

    private struct ParsedWAV {
        var formatTag = 0, channels = 0, sampleRate = 0, blockAlign = 0, bits = 0
        var chunks: [String: [UInt8]] = [:]
        var chunkOrder: [String] = []
        var riffSizeMatches = false
        var samples: [Float] {
            let d = chunks["data"] ?? []
            if formatTag == 3 {
                return stride(from: 0, to: d.count, by: 4).map { Float(bitPattern: le32(d, $0)) }
            }
            return stride(from: 0, to: d.count, by: 2).map { Float(Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8)) }
        }
        var clmText: String? { chunks["clm "].map { String(decoding: $0.filter { $0 != 0 }, as: UTF8.self) } }
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }

    private func parseWAV(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> ParsedWAV {
        let b = [UInt8](data)
        var w = ParsedWAV()
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { XCTFail("not a WAV", file: file, line: line); return w }
        w.riffSizeMatches = Int(Self.le32(b, 4)) == b.count - 8
        var o = 12
        while o + 8 <= b.count {
            let id = String(decoding: b[o..<(o + 4)], as: UTF8.self)
            let size = Int(Self.le32(b, o + 4))
            w.chunks[id] = Array(b[(o + 8)..<(o + 8 + size)])
            w.chunkOrder.append(id)
            o += 8 + size + (size % 2)
        }
        if let f = w.chunks["fmt "] {
            w.formatTag = Self.le16(f, 0); w.channels = Self.le16(f, 2); w.sampleRate = Int(Self.le32(f, 4))
            w.blockAlign = Self.le16(f, 12); w.bits = Self.le16(f, 14)
        }
        return w
    }

    // MARK: Test tables

    /// `count` frames of `size` samples; frame f is a few harmonics scaled to `peak`.
    private func table(_ name: String = "Test Table", frames count: Int, size: Int, peak: Float = 0.8,
                       interpolation: Interpolation? = nil) -> Wavetable {
        Self.table(name, frames: count, size: size, peak: peak, interpolation: interpolation)
    }

    private static func table(_ name: String = "Test Table", frames count: Int, size: Int, peak: Float = 0.8,
                              interpolation: Interpolation? = nil) -> Wavetable {
        let frames: [[Float]] = (0..<count).map { f in
            let raw = (0..<size).map { i -> Float in
                let x = 2 * Double.pi * Double(i) / Double(size)
                return Float(sin(x) + 0.3 * sin(2 * x + Double(f) * 0.1) + 0.2 * sin(3 * x))
            }
            let p = raw.map(abs).max() ?? 1
            return raw.map { $0 / p * peak }
        }
        return Wavetable(name: name, frames: frames, interpolation: interpolation)
    }

    /// A 3rd Wave-sized table (64 frames of 1,024), and what each preset writes for it, made once:
    /// writing a U table serializes 131,072 values, the slow part of these tests.
    private static let standardTable = table(frames: 64, size: 1024)
    private static var standardOutputs: [OutputPreset: OutputFile] = [:]
    private func standardOutput(_ p: OutputPreset) throws -> OutputFile {
        if let out = Self.standardOutputs[p] { return out }
        let out = try WavetableWriter.write(Self.standardTable, preset: p)
        Self.standardOutputs[p] = out
        return out
    }

    private func write(_ t: Wavetable, _ p: OutputPreset, _ o: OutputOptions = OutputOptions()) throws -> OutputFile {
        try WavetableWriter.write(t, preset: p, options: o)
    }

    private func notes(_ out: OutputFile, contain text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(out.notes.contains { $0.contains(text) }, "no note containing “\(text)” in \(out.notes)", file: file, line: line)
    }

    // MARK: 3rd Wave U

    func testThirdWaveUNative() throws {
        let t = Self.standardTable
        let out = try standardOutput(.thirdWaveU)
        XCTAssertEqual(out.fileName, "Test Table.wt")
        XCTAssertEqual(out.folder, "WAVES")
        XCTAssertEqual(out.notes, [])
        let wt = try WavetableFile(data: out.data)
        XCTAssertEqual(wt.kind, .u)
        XCTAssertEqual(wt.name, "Test Table")
        XCTAssertEqual(Array(wt.values[0..<65_536]), t.frames.flatMap { $0 })
        XCTAssertEqual(Array(wt.values[65_536...]), Resampling.thirdWaveMipmapChain(t.frames))
        XCTAssertTrue(wt.values[65_536...].contains { $0 != 0 }, "chain present")
    }

    func testThirdWaveUResizesExpandsAndScales() throws {
        let out = try write(table(frames: 3, size: 2048, peak: 1.5), .thirdWaveU)
        let wt = try WavetableFile(data: out.data)
        XCTAssertEqual(wt.values.count, 131_072)
        XCTAssertLessThanOrEqual(wt.peak, 1.00001)
        XCTAssertEqual(wt.values[0..<65_536].map(abs).max()!, 1, accuracy: 1e-6)
        notes(out, contain: "Resized from 2,048 to 1,024")
        notes(out, contain: "Frame count changed from 3 to 64")
        notes(out, contain: "repeating frames")
        notes(out, contain: "Turned down to fit (peak was 1.50")
    }

    func testThirdWaveNameSanitised() throws {
        let t = table("Łódź Ω strings that go on and on for ever", frames: 64, size: 1024)
        let out = try write(t, .thirdWaveU)
        let name = wtName(out.data)
        XCTAssertEqual(name, "?ódz ? strings that go on and o")
        XCTAssertEqual(name.count, 31)
        notes(out, contain: "outside Latin-1")
        notes(out, contain: "shortened")
        XCTAssertEqual(out.fileName, "Łódź Ω strings that go on and on for ever.wt", "the file name keeps the full name")
    }

    func testThirdWaveNameOnOneLine() throws {
        let out = try write(table("Two\nLines", frames: 64, size: 1024), .thirdWaveU)
        XCTAssertEqual(wtName(out.data), "Two Lines")
    }

    /// The name line of a .wt (its second line, Latin-1), read without parsing the 131,072 values
    /// below it; `testThirdWaveUNative` parses a whole file.
    private func wtName(_ data: Data) -> String {
        let lines = data.split(separator: UInt8(ascii: "\n"), maxSplits: 2, omittingEmptySubsequences: false)
        return lines.count > 1 ? String(lines[1].map { Character(Unicode.Scalar($0)) }) : ""
    }

    // MARK: 3rd Wave P

    func testThirdWavePDeltas() throws {
        let t = table(frames: 64, size: 128)
        let out = try write(t, .thirdWaveP)
        XCTAssertEqual(out.folder, "WAVES")
        let wt = try WavetableFile(data: out.data)
        XCTAssertEqual(wt.kind, .p)
        XCTAssertEqual(wt.values.count, 16_384)
        for w in [0, 31, 63] {
            for i in 0..<128 {
                let at = w * 256 + i * 2
                XCTAssertEqual(wt.values[at], t.frames[w][i])
                XCTAssertEqual(wt.values[at + 1], t.frames[w][(i + 1) % 128] - t.frames[w][i])
            }
        }
        XCTAssertEqual(out.notes, [])
    }

    func testThirdWavePWithPPGWaves() throws {
        let out = try write(table(frames: 64, size: 2048), .thirdWaveP, OutputOptions(appendPPGStandardWaves: true))
        let wt = try WavetableFile(data: out.data)
        for (k, wave) in PPGStandardWaves.frames.enumerated() {
            let samples = stride(from: (60 + k) * 256, to: (61 + k) * 256, by: 2).map { wt.values[$0] }
            XCTAssertEqual(samples, wave, "position \(60 + k)")
        }
        notes(out, contain: "Frame count changed from 64 to 60")
        notes(out, contain: "standard waves")
        notes(out, contain: "harmonic and above are dropped")
    }

    // MARK: Serum-style WAVs

    func testWAV2048() throws {
        let t = table(frames: 8, size: 2048)
        let out = try write(t, .wav2048)
        XCTAssertEqual(out.fileName, "Test Table.wav")
        XCTAssertNil(out.folder)
        let w = parseWAV(out.data)
        XCTAssertTrue(w.riffSizeMatches)
        XCTAssertEqual(w.chunkOrder, ["fmt ", "clm ", "data"])
        XCTAssertEqual([w.formatTag, w.channels, w.sampleRate, w.blockAlign, w.bits], [3, 1, 48_000, 4, 32])
        XCTAssertEqual(w.clmText, "<!>2048 10000000 wavetable (pgdata Packer)")
        XCTAssertEqual(w.samples, t.frames.flatMap { $0 })
        notes(out, contain: "crossfade")
    }

    func testCLMInterpolationFlag() throws {
        let t = table(frames: 2, size: 2048)
        let cases: [(Interpolation?, Interpolation?, String)] = [
            (nil, Interpolation.none, "0"), (nil, .spectral, "2"), (Interpolation.none, nil, "0"), (.spectral, Interpolation.none, "0"),
            (.crossfade, .spectral, "2"),
        ]
        for (source, asked, digit) in cases {
            var s = t; s.interpolation = source
            let w = parseWAV(try write(s, .wav2048, OutputOptions(interpolation: asked)).data)
            XCTAssertEqual(w.clmText, "<!>2048 \(digit)0000000 wavetable (pgdata Packer)")
        }
    }

    func testWAV2048ReducesTo256AndKeepsPeak() throws {
        let out = try write(table(frames: 300, size: 4, peak: 1.25), .wav2048, OutputOptions(frameCountPolicy: .interpolate))
        let w = parseWAV(out.data)
        XCTAssertEqual(w.samples.count, 256 * 2048)
        XCTAssertGreaterThan(w.samples.map(abs).max()!, 1.2)
        notes(out, contain: "Frame count changed from 300 to 256")
        notes(out, contain: "crossfading")
        notes(out, contain: "Peak 1.25 kept, over full scale")
    }

    /// One rule for the peak in every note: two decimals, or enough of them that a peak just
    /// over full scale never reads "1.00".
    func testPeakText() throws {
        XCTAssertEqual(Wavetable.peakText(1.25), "1.25")
        XCTAssertEqual(Wavetable.peakText(0.5), "0.50")
        XCTAssertEqual(Wavetable.peakText(1), "1.00")
        XCTAssertEqual(Wavetable.peakText(1.0003), "1.0003")
        XCTAssertEqual(Wavetable.peakText(1.00001), "just over 1")
        XCTAssertEqual(Wavetable.peakText(8), "8.00")
        let barely = try write(table(frames: 4, size: 2048, peak: 1.0003), .wav2048)
        notes(barely, contain: "Peak 1.0003 kept, over full scale")
        let turned = try write(table(frames: 4, size: 1024, peak: 1.0003), .thirdWaveU)
        notes(turned, contain: "peak was 1.0003")
    }

    func testMiniFreak() throws {
        let big = try write(table(frames: 100, size: 2048), .miniFreak)
        XCTAssertEqual(parseWAV(big.data).samples.count, 64 * 2048)
        XCTAssertNotNil(parseWAV(big.data).clmText)
        notes(big, contain: "Frame count changed from 100 to 64")
        let small = try write(table(frames: 10, size: 2048), .miniFreak)
        XCTAssertEqual(parseWAV(small.data).samples.count, 10 * 2048)
        notes(small, contain: "not documented")
    }

    func testPhasePlantExpandsTo256() throws {
        let out = try write(table(frames: 64, size: 2048), .phasePlant)
        let w = parseWAV(out.data)
        XCTAssertEqual(w.samples.count, 524_288)
        XCTAssertEqual(w.clmText?.hasPrefix("<!>2048 1"), true)
        notes(out, contain: "Frame count changed from 64 to 256")
    }

    // MARK: Tonverk

    func testTonverkNames() throws {
        let t = table(frames: 8, size: 1024)
        let smooth = try write(t, .tonverk)
        XCTAssertEqual(smooth.fileName, "Test Table_wt1024.wav")
        let w = parseWAV(smooth.data)
        XCTAssertNil(w.chunks["clm "])
        XCTAssertEqual([w.formatTag, w.sampleRate, w.bits], [3, 48_000, 32])
        XCTAssertEqual(w.samples, t.frames.flatMap { $0 })

        XCTAssertEqual(try write(t, .tonverk, OutputOptions(interpolation: Interpolation.none)).fileName, "Test Table_wt1024r.wav")
        var stepped = t; stepped.interpolation = Interpolation.none
        XCTAssertEqual(try write(stepped, .tonverk).fileName, "Test Table_wt1024r.wav")

        var guitar = t; guitar.name = "Guitar"
        XCTAssertEqual(try write(guitar, .tonverk).fileName, "Guitar_wt1024.wav", "a name ending in r stays smooth")

        let spectral = try write(t, .tonverk, OutputOptions(interpolation: .spectral))
        XCTAssertEqual(spectral.fileName, "Test Table_wt1024.wav")
        notes(spectral, contain: "spectral morph asked for is marked smooth")
    }

    func testTonverkReplacesExistingTag() throws {
        var t = table(frames: 8, size: 128); t.name = "strings_wt128r"
        let out = try write(t, .tonverk)
        XCTAssertEqual(out.fileName, "strings_wt128.wav")
        notes(out, contain: "“_wt128r” was replaced by “_wt128”")
    }

    func testTonverkFrameSizes() throws {
        let odd = try write(table(frames: 4, size: 600), .tonverk)
        XCTAssertEqual(odd.fileName, "Test Table_wt2048.wav")
        XCTAssertEqual(parseWAV(odd.data).samples.count, 4 * 2048)
        let asked = try write(table(frames: 4, size: 2048), .tonverk, OutputOptions(tonverkFrameSize: 128))
        XCTAssertEqual(asked.fileName, "Test Table_wt128.wav")
        XCTAssertEqual(parseWAV(asked.data).samples.count, 4 * 128)
        XCTAssertThrowsError(try write(table(frames: 4, size: 2048), .tonverk, OutputOptions(tonverkFrameSize: 100)))
        let many = try write(table(frames: 80, size: 64), .tonverk)
        XCTAssertEqual(parseWAV(many.data).samples.count, 64 * 64)
        notes(many, contain: "from 80 to 64")
    }

    // MARK: Surge

    func testSurgeHeader() throws {
        let t = table(frames: 5, size: 1024)
        let out = try write(t, .surge)
        XCTAssertEqual(out.fileName, "Test Table.wt")
        let b = [UInt8](out.data)
        XCTAssertEqual(String(decoding: b[0..<4], as: UTF8.self), "vawt")
        XCTAssertEqual(Self.le32(b, 4), 1024)
        XCTAssertEqual(Self.le16(b, 8), 5)
        XCTAssertEqual(Self.le16(b, 10), 0)
        XCTAssertEqual(b.count, 12 + 5 * 1024 * 4)
        XCTAssertEqual(Float(bitPattern: Self.le32(b, 12 + 4 * 1025)), t.frames[1][1])
    }

    func testSurgeResizesOddSizesAndLimitsCount() throws {
        let odd = try write(table(frames: 2, size: 600), .surge)
        XCTAssertEqual(Self.le32([UInt8](odd.data), 4), 2048)
        notes(odd, contain: "from 600 to 2,048")
        let many = try write(table(frames: 600, size: 4), .surge)
        XCTAssertEqual(Self.le32([UInt8](many.data), 4), 4)
        XCTAssertEqual(Self.le16([UInt8](many.data), 8), 512)
    }

    // MARK: WaveEdit

    func testWaveEdit16Bit() throws {
        var t = table(frames: 64, size: 256)
        t.frames[0][0] = 0.5; t.frames[0][1] = -0.5
        let out = try write(t, .waveEdit)
        let w = parseWAV(out.data)
        XCTAssertEqual(w.chunkOrder, ["fmt ", "data"])
        XCTAssertEqual([w.formatTag, w.channels, w.sampleRate, w.blockAlign, w.bits], [1, 1, 44_100, 2, 16])
        XCTAssertEqual(w.chunks["data"]?.count, 32_768)
        XCTAssertEqual(Array(w.samples.prefix(2)), [16_384, -16_384], "rounded to nearest")
        XCTAssertEqual(out.notes, [])
    }

    func testWaveEditScalesToFit() throws {
        let out = try write(table(frames: 64, size: 256, peak: 2), .waveEdit)
        XCTAssertEqual(parseWAV(out.data).samples.map(abs).max(), 32_767)
        notes(out, contain: "Turned down to fit (peak was 2.00")
    }

    // MARK: Names, validation, presets

    func testFileNamesAreSafe() throws {
        let cases = [
            ("A/B: C*? \"x\" <y>|z. ", "A-B- C 'x' (y)-z"),
            (".hidden", "hidden"),
            ("CON", "CON_"),
            ("lpt1.backup", "lpt1_.backup"),
            ("   ", "Untitled"),
            ("Tab\there", "Tab here"),
        ]
        for (name, stem) in cases {
            XCTAssertEqual(try write(table(name, frames: 2, size: 2048), .wav2048).fileName, stem + ".wav", name)
        }
        let long = String(repeating: "é", count: 300)
        XCTAssertLessThanOrEqual(try write(table(long, frames: 2, size: 2048), .wav2048).fileName.utf8.count, 255)
        notes(try write(table("a/b", frames: 2, size: 2048), .wav2048), contain: "File name adjusted")
    }

    func testValidation() {
        func kind(_ error: Error) -> WavetableError.Kind? { (error as? WavetableError)?.kind }
        XCTAssertThrowsError(try write(Wavetable(name: "Empty", frames: []), .wav2048)) { XCTAssertEqual(kind($0), .cannotConvert) }
        XCTAssertThrowsError(try write(Wavetable(name: "Empty frame", frames: [[]]), .wav2048)) { XCTAssertEqual(kind($0), .cannotConvert) }
        XCTAssertThrowsError(try write(Wavetable(name: "Ragged", frames: [[0, 0], [0]]), .wav2048)) { XCTAssertEqual(kind($0), .cannotConvert) }
        XCTAssertThrowsError(try write(Wavetable(name: "NaN", frames: [[0, .nan]]), .wav2048)) { error in
            XCTAssertTrue((error as? WavetableError)?.description.contains("not numbers") == true)
            XCTAssertEqual(kind(error), .cannotConvert)
        }
        XCTAssertThrowsError(try write(table(frames: 4, size: 2048), .tonverk, OutputOptions(tonverkFrameSize: 100))) {
            XCTAssertEqual(kind($0), .cannotConvert)
        }
    }

    func testPresetFacts() {
        let titles = OutputPreset.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for p in OutputPreset.allCases {
            XCTAssertFalse(p.title.isEmpty)
            XCTAssertEqual(p.testedIn, [])
            XCTAssertFalse(p.basis.isEmpty)
            XCTAssertLessThanOrEqual(p.requiredFrameCount ?? 0, p.maxFrameCount)
        }
        XCTAssertEqual(OutputPreset.allCases.filter(\.isThirdWave), [.thirdWaveU, .thirdWaveP])
        XCTAssertEqual(OutputPreset.thirdWaveU.frameSize, 1024)
        XCTAssertEqual(OutputPreset.phasePlant.requiredFrameCount, 256)
        XCTAssertNil(OutputPreset.tonverk.frameSize)
    }

    /// Every preset's output size follows from its facts.
    func testEveryPresetWrites() throws {
        for p in OutputPreset.allCases {
            let out = try standardOutput(p)
            XCTAssertTrue(out.fileName.hasSuffix("." + p.fileExtension), "\(p)")
            XCTAssertFalse(out.data.isEmpty)
        }
    }

    // MARK: The plan

    func testPlanFields() {
        let big = WavetableWriter.plan(frameSize: 2048, frameCount: 256, peak: 1.5, interpolation: nil, preset: .thirdWaveU)
        XCTAssertEqual(big.frameSizeOut, 1024)
        XCTAssertEqual(big.frameSizeGrows, false)
        XCTAssertEqual(big.frameCountOut, 64)
        XCTAssertEqual(big.tableFrameCount, 64)
        XCTAssertEqual(big.frameCountGrows, false)
        XCTAssertEqual(big.countPolicy, .pickEvenly)
        XCTAssertTrue(big.scalesToFit)
        XCTAssertEqual(big.scaling, .certain)
        XCTAssertTrue(big.scaledToFit)
        XCTAssertFalse(big.mayScaleToFit)
        XCTAssertFalse(big.peakKept)
        XCTAssertNil(big.interpolationRecorded)
        XCTAssertEqual(big.fileExtension, "wt")

        let grows = WavetableWriter.plan(frameSize: 128, frameCount: 64, peak: 0.9, interpolation: .spectral, preset: .thirdWaveU)
        XCTAssertEqual(grows.scaling, .possible)
        XCTAssertEqual(grows.frameSizeGrows, true)
        XCTAssertNil(grows.frameCountGrows)
        XCTAssertFalse(grows.changesCount)

        let kept = WavetableWriter.plan(frameSize: 2048, frameCount: 8, peak: 1.2, interpolation: nil, preset: .wav2048)
        XCTAssertEqual(kept.scaling, .none)
        XCTAssertFalse(kept.scalesToFit)
        XCTAssertTrue(kept.peakKept)
        XCTAssertEqual(kept.interpolationRecorded, .crossfade)
        XCTAssertFalse(kept.resizes)
        XCTAssertNil(kept.frameSizeGrows)

        let tonverk = WavetableWriter.plan(frameSize: 600, frameCount: 100, peak: 0.5, interpolation: .spectral, preset: .tonverk,
                                           options: OutputOptions(frameCountPolicy: .interpolate))
        XCTAssertEqual(tonverk.frameSizeOut, 2048)
        XCTAssertEqual(tonverk.frameCountOut, 64)
        XCTAssertEqual(tonverk.interpolationRecorded, .crossfade, "a Tonverk name can say only stepped or smooth")
        XCTAssertEqual(tonverk.countPolicy, .interpolate)
        XCTAssertEqual(tonverk.fileExtension, "wav")

        let ppg = WavetableWriter.plan(frameSize: 1024, frameCount: 64, peak: 0.5, interpolation: nil, preset: .thirdWaveP,
                                       options: OutputOptions(appendPPGStandardWaves: true))
        XCTAssertTrue(ppg.addsPPGWaves)
        XCTAssertEqual(ppg.frameCountOut, 64)
        XCTAssertEqual(ppg.tableFrameCount, 60)
        XCTAssertTrue(ppg.changesCount)
        XCTAssertEqual(ppg.frameCountGrows, false)
        XCTAssertFalse(WavetableWriter.plan(frameSize: 1024, frameCount: 64, peak: 0.5, interpolation: nil, preset: .thirdWaveU,
                                            options: OutputOptions(appendPPGStandardWaves: true)).addsPPGWaves, "P tables only")

        XCTAssertEqual(WavetableWriter.frameCount(for: .surge, source: 600), 512)
        XCTAssertEqual(WavetableWriter.frameCount(for: .phasePlant, source: 8), 256)
        XCTAssertEqual(WavetableWriter.frameCount(for: .miniFreak, source: 8), 8)
        XCTAssertEqual(WavetableWriter.interpolationRecorded(for: .surge, source: .spectral), nil)
        XCTAssertEqual(WavetableWriter.interpolationRecorded(for: .wav2048, source: .spectral), .spectral)
        XCTAssertEqual(WavetableWriter.interpolationRecorded(for: .wav2048, source: .spectral, options: OutputOptions(interpolation: Interpolation.none)),
                       Interpolation.none)
        XCTAssertEqual(OutputPreset.allCases.filter(\.scalesToFit), [.thirdWaveU, .thirdWaveP, .waveEdit])
    }

    /// The writer does what its plan says, for every preset and several shapes of table, with
    /// the default options and with every option changed; the plan's "may be turned down" is
    /// the one thing left open.
    func testWriterFollowsItsPlan() throws {
        let shapes: [(frames: Int, size: Int, peak: Float, interpolation: Interpolation?)] = [
            (64, 1024, 0.8, nil), (3, 2048, 1.5, .spectral), (300, 4, 0.5, Interpolation.none), (8, 600, 0.9, .crossfade), (64, 128, 1, nil),
        ]
        let changed = OutputOptions(frameCountPolicy: .interpolate, interpolation: .spectral, appendPPGStandardWaves: true)
        for p in OutputPreset.allCases {
            for (i, s) in shapes.enumerated() {
                for options in [i % 2 == 0 ? OutputOptions() : changed, p == .thirdWaveP && i % 2 == 0 ? changed : nil].compactMap({ $0 }) {
                    let t = table(frames: s.frames, size: s.size, peak: s.peak, interpolation: s.interpolation)
                    let plan = WavetableWriter.plan(for: t, preset: p, options: options)
                    let out = try write(t, p, options)
                    let label = "\(p) \(s) \(options.frameCountPolicy)"
                    XCTAssertEqual(plan.preset, p)
                    XCTAssertEqual(plan.frameSizeIn, s.size); XCTAssertEqual(plan.frameCountIn, s.frames)
                    XCTAssertEqual(plan.peak, s.peak, accuracy: 1e-6)
                    XCTAssertTrue(out.fileName.hasSuffix("." + plan.fileExtension), label)

                    // The written size and the metadata.
                    var count: Int, size: Int
                    switch p {
                    case .thirdWaveU, .thirdWaveP:
                        let wt = try WavetableFile(data: out.data)
                        count = wt.frames.count; size = wt.frames.first?.count ?? 0
                    case .surge:
                        let b = [UInt8](out.data)
                        size = Int(Self.le32(b, 4)); count = Self.le16(b, 8)
                    case .wav2048, .miniFreak, .phasePlant, .tonverk, .waveEdit:
                        let w = parseWAV(out.data)
                        size = plan.frameSizeOut; count = w.samples.count / size
                        XCTAssertEqual(w.samples.count % size, 0, label)
                        if let recorded = plan.interpolationRecorded, p != .tonverk {
                            let digit: Character = recorded == Interpolation.none ? "0" : recorded == .crossfade ? "1" : "2"
                            XCTAssertEqual(w.clmText?.dropFirst(8).first, digit, label)
                        } else {
                            XCTAssertNil(w.clmText, label)
                        }
                        if p == .tonverk {
                            let tag = "_wt\(plan.frameSizeOut)" + (plan.interpolationRecorded == Interpolation.none ? "r" : "")
                            XCTAssertTrue(out.fileName.hasSuffix(tag + ".wav"), label)
                        }
                    }
                    XCTAssertEqual(count, plan.frameCountOut, label)
                    XCTAssertEqual(size, plan.frameSizeOut, label)

                    // The notes say what the plan said. The level after resizing is the writer's
                    // to judge: growing the frame size can lift a peak of 1 a little above it,
                    // so a destination that keeps the peak may then note it, and one that turns
                    // the table down may do so (`Scaling.possible`).
                    func said(_ text: String) -> Bool { out.notes.contains { $0.contains(text) } }
                    XCTAssertEqual(said("Resized from"), plan.resizes, label)
                    XCTAssertEqual(said("Frame count changed from"), plan.changesCount, label)
                    XCTAssertEqual(said("standard waves"), plan.addsPPGWaves, label)
                    if plan.peakKept {
                        XCTAssertTrue(said("kept, over full scale"), label)
                    } else if plan.scalesToFit || plan.frameSizeGrows != true {
                        XCTAssertFalse(said("kept, over full scale"), label)
                    }
                    switch plan.scaling {
                    case .certain: XCTAssertTrue(said("Turned down to fit"), label)
                    case .none: XCTAssertFalse(said("Turned down to fit"), label)
                    case .possible: break   // settled by the resized peak
                    }
                    if plan.changesCount {
                        let how = plan.countPolicy == .interpolate ? "crossfading" : (plan.frameCountGrows == true ? "repeating" : "keeping evenly spaced")
                        XCTAssertTrue(said(how), label)
                    }
                }
            }
        }
    }
}

final class TonverkNameTagTests: XCTestCase {
    func testOnlyTonverkSizesCountAsTags() {
        XCTAssertNil(WavetableWriter.Names.removeTonverkTag("KOMPLEXER_WT1").removed)
        XCTAssertNil(WavetableWriter.Names.removeTonverkTag("Pad_wt100").removed)
        XCTAssertEqual(WavetableWriter.Names.removeTonverkTag("Pad_wt1024r").stem, "Pad")
    }
}
