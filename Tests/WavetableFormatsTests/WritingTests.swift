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

    private func write(_ t: Wavetable, _ p: OutputPreset, _ o: OutputOptions = OutputOptions()) throws -> OutputFile {
        try WavetableWriter.write(t, preset: p, options: o)
    }

    private func notes(_ out: OutputFile, contain text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(out.notes.contains { $0.contains(text) }, "no note containing “\(text)” in \(out.notes)", file: file, line: line)
    }

    // MARK: 3rd Wave U

    func testThirdWaveUNative() throws {
        let t = table(frames: 64, size: 1024)
        let out = try write(t, .thirdWaveU)
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
        notes(out, contain: "Frame size resampled from 2,048 to 1,024")
        notes(out, contain: "Frame count changed from 3 to 64")
        notes(out, contain: "repeating frames")
        notes(out, contain: "Scaled by 0.6")
    }

    func testThirdWaveNameSanitised() throws {
        let t = table("Łódź Ω strings that go on and on for ever", frames: 64, size: 1024)
        let out = try write(t, .thirdWaveU)
        let wt = try WavetableFile(data: out.data)
        XCTAssertEqual(wt.name, "?ódz ? strings that go on and o")
        XCTAssertEqual(wt.name.count, 31)
        notes(out, contain: "outside Latin-1")
        notes(out, contain: "shortened")
        XCTAssertEqual(out.fileName, "Łódź Ω strings that go on and on for ever.wt", "the file name keeps the full name")
    }

    func testThirdWaveNameOnOneLine() throws {
        let out = try write(table("Two\nLines", frames: 64, size: 1024), .thirdWaveU)
        XCTAssertEqual(try WavetableFile(data: out.data).name, "Two Lines")
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
        notes(out, contain: "harmonic up is dropped")
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
        notes(out, contain: "kept unscaled")
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
        notes(spectral, contain: "no spectral morph")
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
        notes(out, contain: "Scaled by 0.500")
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
        XCTAssertThrowsError(try write(Wavetable(name: "Empty", frames: []), .wav2048))
        XCTAssertThrowsError(try write(Wavetable(name: "Empty frame", frames: [[]]), .wav2048))
        XCTAssertThrowsError(try write(Wavetable(name: "Ragged", frames: [[0, 0], [0]]), .wav2048))
        XCTAssertThrowsError(try write(Wavetable(name: "NaN", frames: [[0, .nan]]), .wav2048)) { error in
            XCTAssertTrue((error as? WavetableError)?.description.contains("not numbers") == true)
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
        let t = table(frames: 64, size: 1024)
        for p in OutputPreset.allCases {
            let out = try write(t, p)
            XCTAssertTrue(out.fileName.hasSuffix("." + p.fileExtension), "\(p)")
            XCTAssertFalse(out.data.isEmpty)
        }
    }
}
