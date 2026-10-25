import XCTest
import Foundation
@testable import PgdataFormats
@testable import WavetableFormats

// Tests for WavetableReader. Every WAV and Surge file here is built synthetically by the small
// private builders at the end of this file (not by WavetableWriter), and the 3rd Wave files are the
// repository's own synthetic fixtures.

final class ReadingTests: XCTestCase {

    // MARK: - File names

    func testMayContainWavetables() {
        for name in ["a.wt", "b.WT", "c.pgdata", "d.wav", "e.WAV", "f.wave", "g.Wave"] {
            XCTAssertTrue(WavetableReader.mayContainWavetables(fileName: name), name)
        }
        for name in ["a.pro", "b.bin", "c.txt", "wav", ".hidden.wav", "._d.wav", "e.aiff", "f.wt.json"] {
            XCTAssertFalse(WavetableReader.mayContainWavetables(fileName: name), name)
        }
    }

    // MARK: - Sniffing

    func testUnrelatedContentHoldsNoWavetable() throws {
        XCTAssertEqual(try WavetableReader.read(Data(), fileName: "empty.wt"), [])
        XCTAssertEqual(try WavetableReader.read(Data("hello\n".utf8), fileName: "x.wt"), [])
        XCTAssertEqual(try WavetableReader.read(try fixture("program-current.pro"), fileName: "p.wt"), [])
        XCTAssertEqual(try WavetableReader.read(try fixture("multisample.bin"), fileName: "m.wav"), [])
    }

    func testContentNotExtensionDecides() throws {
        // A Surge file named .wav and a WAV named .wt are still read as what they are.
        let surge = try WavetableReader.read(surgeFile(size: 64, frames: [[Float]](repeating: ramp(64), count: 2)),
                                             fileName: "s.wav")
        XCTAssertEqual(surge.first?.source, .surgeWavetable)
        let w = try WavetableReader.read(wavFile([ramp(8192)]), fileName: "w.wt")
        XCTAssertEqual(w.first?.source, .wav)
    }

    // MARK: - Surge .wt

    func testSurgeFloat() throws {
        let frames = (0..<3).map { k in ramp(256).map { $0 * Float(k + 1) / 4 } }
        let t = try XCTUnwrap(WavetableReader.read(surgeFile(size: 256, frames: frames), fileName: "Pad.wt").first)
        XCTAssertEqual(t.source, .surgeWavetable)
        XCTAssertEqual(t.name, "Pad")
        XCTAssertEqual(t.frameSize, 256)
        XCTAssertEqual(t.frameSizeBasis, "Surge .wt header")
        XCTAssertEqual(t.samples, frames.flatMap { $0 })
        XCTAssertNil(t.thirdWaveFingerprint)
        XCTAssertEqual(t.notes, [])
    }

    func testSurgeInt16Scaling() throws {
        let frames = [[Float](repeating: 0.5, count: 64), [Float](repeating: -0.25, count: 64)]
        let full = try XCTUnwrap(WavetableReader.read(surgeFile(size: 64, frames: frames, int16: .fullScale),
                                                      fileName: "a.wt").first)
        XCTAssertEqual(full.samples.first, 0.5)
        XCTAssertEqual(full.samples.last, -0.25)
        // Without flag 0x08 the int16 data peaks at 2^14, so the same integers read twice as loud.
        let half = try XCTUnwrap(WavetableReader.read(surgeFile(size: 64, frames: frames, int16: .halfScaleData),
                                                      fileName: "b.wt").first)
        XCTAssertEqual(half.samples.first, 0.5)
        XCTAssertEqual(half.samples.last, -0.25)
    }

    func testSurgeSampleFlagIsNotAWavetable() throws {
        XCTAssertEqual(try WavetableReader.read(surgeFile(size: 64, frames: [ramp(64)], extraFlags: 0x01),
                                                fileName: "s.wt"), [])
    }

    func testSurgeMetadataBlockIgnored() throws {
        var d = surgeFile(size: 64, frames: [ramp(64), ramp(64)], extraFlags: 0x10)
        d.append(contentsOf: Array("<wtmeta/>".utf8) + [0])
        XCTAssertEqual(try WavetableReader.read(d, fileName: "m.wt").first?.samples.count, 128)
    }

    func testDamagedSurgeThrows() {
        XCTAssertThrowsError(try WavetableReader.read(Data("vawt".utf8), fileName: "a.wt"))
        var short = surgeFile(size: 64, frames: [ramp(64), ramp(64)])
        short.removeLast(10)
        XCTAssertThrowsError(try WavetableReader.read(short, fileName: "b.wt")) { e in
            XCTAssertTrue("\(e)".contains("cut short"), "\(e)")
        }
        var zero = surgeFile(size: 64, frames: [ramp(64)])
        zero[4] = 0; zero[5] = 0
        XCTAssertThrowsError(try WavetableReader.read(zero, fileName: "c.wt"))
    }

    // MARK: - 3rd Wave .wt and .pgdata

    func testThirdWavePTable() throws {
        let data = try fixture("wavetable-p.wt")
        let wt = try WavetableFile(data: data)
        let t = try XCTUnwrap(WavetableReader.read(data, fileName: "wavetable-p.wt").first)
        XCTAssertEqual(t.source, .thirdWaveWavetable(isP: true))
        XCTAssertEqual(t.name, "Fixture P Sine to Saw")
        XCTAssertEqual(t.frameSize, 128)
        XCTAssertEqual(t.frameSizeBasis, "3rd Wave P table (always 64 frames of 128)")
        XCTAssertEqual(t.samples.count, 8192)
        XCTAssertEqual(t.samples, stride(from: 0, to: 16_384, by: 2).map { wt.values[$0] })
        XCTAssertEqual(t.thirdWaveFingerprint, wt.fingerprint)
        XCTAssertEqual(t.wavetable()?.frameCount, 64)
    }

    func testThirdWaveUTableAndByteOrderMark() throws {
        let data = try fixture("wavetable-u.wt")
        let wt = try WavetableFile(data: data)
        let t = try XCTUnwrap(WavetableReader.read(data, fileName: "wavetable-u.wt").first)
        XCTAssertEqual(t.source, .thirdWaveWavetable(isP: false))
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeBasis, "3rd Wave U table (always 64 frames of 1,024)")
        XCTAssertEqual(t.samples, Array(wt.values.prefix(65_536)))
        XCTAssertEqual(t.thirdWaveFingerprint, wt.fingerprint)
        // A UTF-8 byte-order mark in front changes nothing.
        let bom = try XCTUnwrap(WavetableReader.read(Data([0xEF, 0xBB, 0xBF]) + data, fileName: "bom.wt").first)
        XCTAssertEqual(bom.samples, t.samples)
        XCTAssertEqual(bom.thirdWaveFingerprint, t.thirdWaveFingerprint)
    }

    func testFingerprintMatchesFactoryLibrary() throws {
        // FactoryLibrary computes its fingerprints from .wt files with WavetableFile.fingerprint;
        // a library built from the fixture, filed as slot P05, must recognise the reader's fingerprint.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixture("wavetable-p.wt").write(to: dir.appendingPathComponent("05-Fixture.wt"))
        let library = FactoryLibrary(folders: [dir])
        let t = try XCTUnwrap(WavetableReader.read(try fixture("wavetable-p.wt"), fileName: "x.wt").first)
        XCTAssertEqual(library.slot(withFingerprint: try XCTUnwrap(t.thirdWaveFingerprint)), .p(5))
    }

    func testUnifiedProgram() throws {
        let tables = try WavetableReader.read(try fixture("unified.pgdata"), fileName: "unified.pgdata")
        // The fixture embeds U56 (wavetable-u.wt) and S00 (a multisample); the rest are listed only.
        XCTAssertEqual(tables.count, 1)
        let t = try XCTUnwrap(tables.first)
        XCTAssertEqual(t.source, .unifiedProgram(slot: "U56", isP: false))
        XCTAssertEqual(t.name, "Fixture U Saw Harmonics")
        XCTAssertEqual(t.frameSize, 1024)
        let u = try XCTUnwrap(WavetableReader.read(try fixture("wavetable-u.wt"), fileName: "u.wt").first)
        XCTAssertEqual(t.samples, u.samples)
        XCTAssertEqual(t.thirdWaveFingerprint, u.thirdWaveFingerprint)
    }

    func testDamagedThirdWaveFilesThrow() throws {
        XCTAssertThrowsError(try WavetableReader.read(Data("PNAME\nShort\n0.5f\n".utf8), fileName: "p.wt"))
        XCTAssertThrowsError(try WavetableReader.read(Data("UNAME\nBad\nnot a number\n".utf8), fileName: "u.wt"))
        let pg = try fixture("unified.pgdata")
        XCTAssertThrowsError(try WavetableReader.read(pg.prefix(5000), fileName: "cut.pgdata")) { e in
            XCTAssertTrue(e is WavetableError)
        }
    }

    // MARK: - WAV sample formats

    func testSampleFormats() throws {
        let v: [Float] = [0, 0.5, -0.5, 0.25, -1, 0.75, -0.75, 0.125]
        let input = Array((0..<4096).map { v[$0 % v.count] })   // two frames of 2,048, by length
        for f in [WAVSampleFormat.pcm16, .pcm24, .pcm32, .float32, .float64] {
            for ext in [false, true] {
                let t = try XCTUnwrap(WavetableReader.read(wavFile([input], format: f, extensible: ext),
                                                           fileName: "f.wav").first, "\(f) \(ext)")
                XCTAssertEqual(t.samples, input, "\(f) extensible \(ext)")
            }
        }
        let eight = try XCTUnwrap(WavetableReader.read(wavFile([input], format: .pcm8), fileName: "8.wav").first)
        XCTAssertEqual(eight.samples, input)
    }

    func testStereoUsesLeftChannel() throws {
        let left = ramp(8192), right = [Float](repeating: 0.25, count: 8192)
        // Stereo files are read when they carry metadata (here a clm chunk); without it, ordinary audio.
        let t = try XCTUnwrap(WavetableReader.read(wavFile([left, right], format: .pcm24, chunks: [clm("<!>2048 10000000")]),
                                                   fileName: "st.wav").first)
        XCTAssertEqual(try WavetableReader.read(wavFile([left, right], format: .pcm24), fileName: "plain.wav"), [])
        XCTAssertEqual(t.samples.count, 8192)
        XCTAssertEqual(t.samples[100], left[100], accuracy: 1e-6)
        XCTAssertTrue(t.notes.contains { $0.contains("Stereo file") }, "\(t.notes)")
    }

    func testOddChunksWithAndWithoutPadding() throws {
        for pad in [true, false] {
            let d = wavFile([ramp(4096)], chunks: [("junk", [1, 2, 3]), clm("<!>1024 10000000 x")], padOddChunks: pad)
            let t = try XCTUnwrap(WavetableReader.read(d, fileName: "odd.wav").first, "pad \(pad)")
            XCTAssertEqual(t.frameSize, 1024, "pad \(pad)")
            XCTAssertEqual(t.samples, ramp(4096))
        }
    }

    func testDamagedWAVThrows() {
        // RIFF/WAVE with no data chunk, and with a format chunk that gives no channels.
        var noData = Data("RIFF".utf8) + le32(4 + 24) + Data("WAVE".utf8)
        noData += Data("fmt ".utf8) + le32(16)
        noData += le16(3) + le16(1) + le32(48_000)
        noData += le32(192_000) + le16(4) + le16(32)
        XCTAssertThrowsError(try WavetableReader.read(noData, fileName: "a.wav"))
        var noChannels = wavFile([ramp(2048)])
        noChannels[22] = 0; noChannels[23] = 0
        XCTAssertThrowsError(try WavetableReader.read(noChannels, fileName: "b.wav"))
        XCTAssertThrowsError(try WavetableReader.read(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8), fileName: "c.wav"))
    }

    func testUnsupportedEncoding() throws {
        // An encoding the reader does not decode (format tag 6, A-law) is ignored as plain audio,
        // but a file marked as a wavetable says why it cannot be read.
        var d = wavFile([ramp(2048)], format: .pcm16)
        d[20] = 6; d[21] = 0
        XCTAssertEqual(try WavetableReader.read(d, fileName: "a.wav"), [])
        var marked = wavFile([ramp(2048)], format: .pcm16, chunks: [clm("<!>2048 00000000")])
        marked[20] = 6; marked[21] = 0
        XCTAssertThrowsError(try WavetableReader.read(marked, fileName: "b.wav"))
    }

    // MARK: - WAV frame size, rule by rule

    func testCLM() throws {
        let t = try readOne(wavFile([ramp(4096)], chunks: [clm("<!>1024 00000000 wavetable (test)")]), "a.wav")
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeBasis, "Serum-style tag inside the file (clm chunk)")
        XCTAssertEqual(t.interpolation, Interpolation.none)
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [clm("<!>2048 10000000")]), "b.wav").interpolation, .crossfade)
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [clm("<!>2048 40000000")]), "c.wav").interpolation, .spectral)
        // Any size that divides the length, not only powers of two.
        XCTAssertEqual(try readOne(wavFile([ramp(3000)], chunks: [clm("<!>600 10000000")]), "d.wav").frameSize, 600)
    }

    func testCLMThatDoesNotDivideKeepsWholeFrames() throws {
        // As in Serum tables from some editors: 24 frames of 2,048 and 32 samples more.
        let t = try readOne(wavFile([ramp(24 * 2048 + 32)], chunks: [clm("<!>2048 20000000")]), "a.wav")
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.samples.count, 24 * 2048)
        XCTAssertEqual(t.wavetable()?.frameCount, 24)
        XCTAssertEqual(t.interpolation, .spectral)
        XCTAssertTrue(t.notes.contains { $0 == "32 samples after the last whole frame are left out." }, "\(t.notes)")
        // A clm size larger than the file is not used.
        let u = try readOne(wavFile([ramp(4096)], chunks: [clm("<!>9000 20000000")]), "b.wav")
        XCTAssertEqual(u.frameSize, 2048)                      // the length rule
        XCTAssertTrue(u.notes.contains { $0.contains("9,000") && $0.contains("ignored") }, "\(u.notes)")
        // Nearly a whole extra frame: the note says how short it falls.
        let v = try readOne(wavFile([ramp(3 * 2048 + 2047)], chunks: [clm("<!>2048 00000000")]), "c.wav")
        XCTAssertEqual(v.samples.count, 3 * 2048)
        XCTAssertTrue(v.notes.contains { $0 == "2,047 samples after the last whole frame are left out (1 sample short of another frame)." }, "\(v.notes)")
        // Marked with a size the file cannot hold, and nothing else to go on: an error that says so.
        XCTAssertThrowsError(try WavetableReader.read(wavFile([ramp(1000)], chunks: [clm("<!>2048 00000000")]), fileName: "d.wav")) { e in
            XCTAssertEqual("\(e)", "\"d.wav\" is marked as a wavetable, but the Serum-style tag inside the file (clm chunk) says 2,048 samples per frame, and the file holds only 1,000 samples, less than one frame, so nothing can be read from it.")
        }
    }

    func testSurgeChunks() throws {
        let t = try readOne(wavFile([ramp(4096)], chunks: [srge(512)]), "a.wav")
        XCTAssertEqual(t.frameSize, 512)
        XCTAssertEqual(t.frameSizeBasis, "Surge tag inside the file (srge chunk)")
        XCTAssertEqual(try WavetableReader.read(wavFile([ramp(4096)], chunks: [("srgo", le32b(1) + le32b(256))]),
                                                fileName: "one.wav"), [])
        let u = try readOne(wavFile([ramp(8192)], chunks: [("uhWT", [0, 0, 0, 0])]), "u.wav")
        XCTAssertEqual(u.frameSize, 2048)
        XCTAssertEqual(u.frameSizeBasis, "u-he tag inside the file (uhWT chunk)")
        // Hive's chunks carry the frame count and size (u32 0, u32 frames, u32 size, u32 0, text).
        let hive = ("uhWT", le32b(0) + le32b(8) + le32b(1024) + le32b(0) + Array("Eight waves".utf8))
        XCTAssertEqual(try readOne(wavFile([ramp(8192)], chunks: [hive]), "h.wav").frameSize, 1024)
        // An implausible size field falls back to 2,048.
        let odd = ("uhWT", le32b(0) + le32b(8) + le32b(1000) + le32b(0))
        XCTAssertEqual(try readOne(wavFile([ramp(8192)], chunks: [odd]), "o.wav").frameSize, 2048)
    }

    func testTonverkFileName() throws {
        let t = try readOne(wavFile([ramp(4096)]), "Strings_WT512r.wav")
        XCTAssertEqual(t.frameSize, 512)
        XCTAssertEqual(t.frameSizeBasis, "Tonverk tag in the file name (_wt512r)")
        XCTAssertEqual(t.interpolation, Interpolation.none)
        XCTAssertEqual(t.name, "Strings")
        let plain = try readOne(wavFile([ramp(4096)]), "pad_wt256.wav")
        XCTAssertEqual(plain.frameSize, 256)
        XCTAssertNil(plain.interpolation)
        // A name that merely ends in "r" sets nothing.
        let monster = try readOne(wavFile([ramp(8192)]), "Monster.wav")
        XCTAssertNil(monster.interpolation)
        XCTAssertEqual(monster.name, "Monster")
        // Only Tonverk's sizes (powers of two from 64 to 4,096) make a tag: "KOMPLEXER_WT1" and
        // "KOMPLEXER_WT2" (a Serum library's numbered tables) are names, read whole, with no note.
        for name in ["KOMPLEXER_WT1", "KOMPLEXER_WT2", "Pad_wt32", "Pad_wt1000", "Pad_wt8192", "Pad_wt0"] {
            let t = try readOne(wavFile([ramp(65_536)], chunks: [clm("<!>2048 00000000")]), name + ".WAV")
            XCTAssertEqual(t.frameSize, 2048, name)
            XCTAssertEqual(t.name, name, name)
            XCTAssertEqual(t.notes, [], name)
            XCTAssertEqual(try readOne(wavFile([ramp(65_536)]), name + ".wav").frameSizeEvidence, .length, name)
        }
        for n in [64, 128, 256, 512, 1024, 2048, 4096] {
            XCTAssertEqual(try readOne(wavFile([ramp(8192)]), "a_wt\(n).wav").frameSize, n)
        }
    }

    func testMetadataBeatsFileName() throws {
        let t = try readOne(wavFile([ramp(8192)], chunks: [clm("<!>2048 10000000")]), "keys_wt1024r.wav")
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.frameSizeBasis, "Serum-style tag inside the file (clm chunk)")
        XCTAssertEqual(t.interpolation, .crossfade)
        XCTAssertTrue(t.notes.contains { $0.contains("_wt1024r") && $0.contains("1,024") && $0.contains("(clm chunk) is used") },
                      "\(t.notes)")
        XCTAssertTrue(t.notes.contains { $0.contains("no interpolation") }, "\(t.notes)")
        XCTAssertEqual(t.name, "keys")
    }

    func testSerumSidecar() throws {
        let t = try readOne(wavFile([ramp(4096)]), "a.wav", sidecar: "[256]\r\n[no interp]\r\n")
        XCTAssertEqual(t.frameSize, 256)
        XCTAssertEqual(t.frameSizeBasis, "Serum .txt file beside it ([256])")
        XCTAssertEqual(t.interpolation, Interpolation.none)
        XCTAssertNil(try readOne(wavFile([ramp(4096)]), "b.wav", sidecar: "[512]\n[interp]").interpolation)
        // Outside Serum's 32–9,999: noted and not used.
        let bad = try readOne(wavFile([ramp(4096)]), "c.wav", sidecar: "[16]")
        XCTAssertEqual(bad.frameSize, 2048)
        XCTAssertTrue(bad.notes.contains { $0.contains("[16]") }, "\(bad.notes)")
    }

    func testCuePoints() throws {
        let t = try readOne(wavFile([ramp(4096)], chunks: [cue([0, 1024, 2048, 3072])]), "a.wav")
        XCTAssertEqual(t.frameSize, 1024)
        XCTAssertEqual(t.frameSizeBasis, "cue markers, evenly spaced (which ordinary samples can have too)")
        XCTAssertEqual(t.frameSizeEvidence, .markers)
        // Unevenly spaced points say nothing.
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [cue([0, 1000, 3072])]), "b.wav").frameSize, 2048)
        // A spacing that is not a power of two is a sample's markers, not a frame size.
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [cue([0, 1024, 2048])]), "c.wav").frameSize, 1024)
        XCTAssertEqual(try WavetableReader.read(wavFile([ramp(3000)], chunks: [cue([0, 1000, 2000])]), fileName: "d.wav"), [])
        // Points that leave a partial last frame: the whole frames are kept.
        let e = try readOne(wavFile([ramp(4096 + 100)], chunks: [cue([0, 1024, 2048, 3072])]), "e.wav")
        XCTAssertEqual(e.frameSize, 1024)
        XCTAssertEqual(e.samples.count, 4096)
        XCTAssertTrue(e.notes.contains { $0.hasPrefix("100 samples after the last whole frame") }, "\(e.notes)")
    }

    func testSmplLoop() throws {
        let t = try readOne(wavFile([ramp(4096)], chunks: [smpl(loops: [(0, 511)])]), "a.wav")
        XCTAssertEqual(t.frameSize, 512)
        XCTAssertEqual(t.frameSizeBasis, "loop markers over the first frame (which ordinary samples can have too)")
        // An exclusive end is accepted too.
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [smpl(loops: [(0, 256)])]), "b.wav").frameSize, 256)
        // Two loops: not used.
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [smpl(loops: [(0, 511), (0, 255)])]), "c.wav").frameSize, 2048)
        // A loop that does not start at sample 0 is a sample's sustain loop, not a frame size.
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], chunks: [smpl(loops: [(1024, 1535)])]), "d.wav").frameSize, 2048)
        // A loop that is not a power of two says nothing either (ordinary looped samples).
        XCTAssertEqual(try WavetableReader.read(wavFile([ramp(2022)], chunks: [smpl(loops: [(0, 673)])]), fileName: "e.wav"), [])
    }

    func testSingleLoopedCycleIsNotAWavetable() throws {
        // A single-cycle sample with a loop over its whole length (one frame): a sample, not a table.
        // The name must not end in a note name here, or that rule would decide instead.
        for n in [674, 2048] {
            XCTAssertEqual(try WavetableReader.read(wavFile([ramp(n)], chunks: [smpl(loops: [(0, n - 1)])]), fileName: "Saw.wav"), [], "\(n)")
            XCTAssertEqual(try WavetableReader.read(wavFile([ramp(n)]), fileName: "Saw.wav"), [], "no loop \(n)")
            let stereo = wavFile([ramp(n), ramp(n)], format: .pcm24, chunks: [smpl(loops: [(0, n - 1)])])
            XCTAssertEqual(try WavetableReader.read(stereo, fileName: "Saw.wav"), [], "stereo \(n)")
        }
        // Two frames are enough (as in Surge's "Triangle HQ.wav").
        XCTAssertEqual(try readOne(wavFile([ramp(4096)], format: .pcm16, chunks: [smpl(loops: [(0, 2047)])]), "Triangle HQ.wav").frameSize, 2048)
    }

    func testLoopThatDoesNotDivideKeepsWholeFrames() throws {
        // As Surge's own library has them: a loop over the first 4,096 samples of a file whose
        // length is not a multiple of it. Surge loads the whole frames and ignores the rest.
        let t = try readOne(wavFile([ramp(142 * 4096 + 3795)], format: .float32, chunks: [smpl(loops: [(0, 4095)])]), "No Coast 1.wav")
        XCTAssertEqual(t.frameSize, 4096)
        XCTAssertEqual(t.frameSizeBasis, "loop markers over the first frame (which ordinary samples can have too)")
        XCTAssertEqual(t.samples.count, 142 * 4096)
        XCTAssertTrue(t.notes.contains { $0 == "3,795 samples after the last whole frame are left out (301 samples short of another frame)." }, "\(t.notes)")
    }

    func testPrecedenceOrder() throws {
        let n = 8192
        // Each step adds a higher-precedence source; each wins over everything below it.
        var chunks: [(String, [UInt8])] = [smpl(loops: [(0, 63)])]
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a.wav").frameSizeBasis, "loop markers over the first frame (which ordinary samples can have too)")
        chunks.append(cue([0, 128, 256, 384]))
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a.wav").frameSize, 128)
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a.wav", sidecar: "[256]").frameSize, 256)
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a_wt512.wav", sidecar: "[256]").frameSize, 512)
        chunks.append(("uhWT", []))
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a_wt512.wav", sidecar: "[256]").frameSize, 2048)
        chunks.append(srge(1024))
        XCTAssertEqual(try readOne(wavFile([ramp(n)], chunks: chunks), "a_wt512.wav", sidecar: "[256]").frameSize, 1024)
        chunks.append(clm("<!>4096 00000000"))
        let t = try readOne(wavFile([ramp(n)], chunks: chunks), "a_wt512.wav", sidecar: "[256]")
        XCTAssertEqual(t.frameSize, 4096)
        XCTAssertEqual(t.frameSizeBasis, "Serum-style tag inside the file (clm chunk)")
        XCTAssertEqual(t.notes.filter { $0.contains("(clm chunk) is used") }.count, 6, "\(t.notes)")
    }

    // MARK: - WAV frame size from the length alone

    func testLengthHeuristics() throws {
        let p = try readOne(wavFile([ramp(8192)]), "p.wav")
        XCTAssertNil(p.frameSize)                               // PPG 64 × 128, or 4 × 2,048: asked
        XCTAssertEqual(p.candidateFrameSizes, [128, 2048])
        XCTAssertTrue(p.frameSizeBasis.hasPrefix("not stated: 8,192 samples"))

        let we16 = try readOne(wavFile([ramp(16_384)], format: .pcm16), "we.wav")
        XCTAssertNil(we16.frameSize)
        XCTAssertEqual(we16.candidateFrameSizes, [256, 2048])
        XCTAssertNil(we16.wavetable())
        XCTAssertEqual(try readOne(wavFile([ramp(16_384)]), "we.wav").candidateFrameSizes, [2048, 256])

        let s = try readOne(wavFile([ramp(3 * 2048)]), "s.wav")
        XCTAssertEqual(s.frameSize, 2048)
        XCTAssertEqual(s.frameSizeBasis, "file length only (2,048 per frame, the usual size; the file does not say)")
        XCTAssertEqual(s.frameSizeEvidence, .length)
        XCTAssertEqual(s.candidateFrameSizes, [64, 128, 256, 512, 1024])

        // No metadata and not a multiple of 2,048 (nor 8,192 or 16,384): ordinary audio.
        XCTAssertEqual(try WavetableReader.read(wavFile([ramp(5 * 1024)]), fileName: "o.wav"), [])

        XCTAssertEqual(try WavetableReader.read(wavFile([ramp(1000)]), fileName: "x.wav"), [])
        XCTAssertEqual(try WavetableReader.read(wavFile([[]]), fileName: "empty.wav"), [])
        // Longer than Surge's 512 frames with nothing but its length to go on: ordinary audio.
        XCTAssertEqual(try WavetableReader.read(wavFile([[Float](repeating: 0, count: 513 * 2048)], format: .pcm16),
                                                fileName: "song.wav"), [])
    }

    func testNotesOfAMultisampledInstrumentAreNotWavetables() throws {
        // With nothing but its length to go on, a file named like the note of a multisampled
        // instrument (Elektron's "Name-000-036-c2", "Saw C3", "SAW-C1") is a sample.
        for name in ["Spectral Undertones-000-012-c1.wav", "Saw C3.wav", "SAW-C1.wav", "Bass_F#-1.wav", "c3.wav", "Pad A#4.WAV"] {
            XCTAssertEqual(try WavetableReader.read(wavFile([ramp(65_536)]), fileName: name), [], name)
            XCTAssertEqual(try WavetableReader.read(wavFile([ramp(8192)]), fileName: name), [], name)
        }
        // The letter must stand on its own, and metadata still wins.
        for name in ["Bwt1.wav", "voc2.wav", "moog2.wav", "Loaf I.wav", "RD-BBD1.wav", "FM 2.wav"] {
            XCTAssertEqual(try WavetableReader.read(wavFile([ramp(65_536)]), fileName: name).count, 1, name)
        }
        XCTAssertEqual(try readOne(wavFile([ramp(65_536)], chunks: [clm("<!>2048 00000000")]), "Saw C3.wav").frameSize, 2048)
        XCTAssertEqual(try readOne(wavFile([ramp(65_536)]), "Saw C3.wav", sidecar: "[1024]").frameSize, 1024)
        XCTAssertEqual(try readOne(wavFile([ramp(65_536)]), "Saw C3_wt512.wav").frameSize, 512)
    }

    // MARK: - Notes

    func testNotes() throws {
        let many = try readOne(wavFile([ramp(300 * 64)], chunks: [clm("<!>64 00000000")]), "many.wav")
        XCTAssertTrue(many.notes.contains { $0.hasPrefix("300 frames: Serum, Vital, and Pigments take at most 256") }, "\(many.notes)")
        let loud = try readOne(wavFile([ramp(8192).map { $0 * 1.5 }]), "loud.wav")
        XCTAssertTrue(loud.notes.contains { $0.hasPrefix("Peak 1.50: over full scale (±1).") }, "\(loud.notes)")
        // A peak that would print as 1.00 is shown with more digits, never as "1.00, over ±1".
        let barely = try readOne(wavFile([ramp(8192).map { $0 * 1.0003 }]), "barely.wav")
        XCTAssertTrue(barely.notes.contains { $0.hasPrefix("Peak 1.0003:") }, "\(barely.notes)")
        XCTAssertTrue(WavetableReader.peakNote(1.00001)!.hasPrefix("Peak just over 1:"))
        XCTAssertNil(WavetableReader.peakNote(1))
        let quiet = try readOne(wavFile([ramp(8192)]), "quiet.wav")
        XCTAssertEqual(quiet.notes, [])
    }

    // MARK: - Reading from a URL

    func testReadURLFindsSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try wavFile([ramp(4096)]).write(to: dir.appendingPathComponent("a.wav"))
        try wavFile([ramp(4096)]).write(to: dir.appendingPathComponent("b.wav"))
        try Data("[1024]\n".utf8).write(to: dir.appendingPathComponent("FolderInfo.txt"))
        try Data("[512]\n[no interp]\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let a = try XCTUnwrap(WavetableReader.read(url: dir.appendingPathComponent("a.wav")).first)
        XCTAssertEqual(a.frameSize, 512)
        XCTAssertEqual(a.interpolation, Interpolation.none)
        XCTAssertEqual(a.fileName, "a.wav")
        XCTAssertEqual(try WavetableReader.read(url: dir.appendingPathComponent("b.wav")).first?.frameSize, 1024)
        XCTAssertThrowsError(try WavetableReader.read(url: dir.appendingPathComponent("missing.wav")))
    }

    // MARK: - Helpers

    private func readOne(_ d: Data, _ name: String, sidecar: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) throws -> FoundTable {
        let all = try WavetableReader.read(d, fileName: name, sidecarText: sidecar)
        XCTAssertEqual(all.count, 1, file: file, line: line)
        return try XCTUnwrap(all.first, file: file, line: line)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures").appendingPathComponent(name))
    }
}

// MARK: - Synthetic file builders (test-only; independent of WavetableWriter)

private enum WAVSampleFormat { case pcm8, pcm16, pcm24, pcm32, float32, float64 }

/// A sawtooth-like ramp from −1 up to just below 1; values exactly representable in every format tested.
private func ramp(_ n: Int) -> [Float] {
    (0..<n).map { i in Float((i % 256) - 128) / 128 }
}

private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
private func le32(_ v: Int) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xff) }) }
private func le32b(_ v: Int) -> [UInt8] { [UInt8](le32(v)) }

private func clm(_ text: String) -> (String, [UInt8]) { ("clm ", Array(text.utf8)) }
private func srge(_ size: Int) -> (String, [UInt8]) { ("srge", le32b(1) + le32b(size)) }
private func cue(_ offsets: [Int]) -> (String, [UInt8]) {
    var b = le32b(offsets.count)
    for (i, o) in offsets.enumerated() {
        b += le32b(i + 1) + le32b(o) + Array("data".utf8) + le32b(0) + le32b(0) + le32b(o)
    }
    return ("cue ", b)
}
private func smpl(loops: [(Int, Int)]) -> (String, [UInt8]) {
    var b = [UInt8](repeating: 0, count: 28) + le32b(loops.count) + le32b(0)
    for (i, l) in loops.enumerated() { b += le32b(i) + le32b(0) + le32b(l.0) + le32b(l.1) + le32b(0) + le32b(0) }
    return ("smpl", b)
}

/// A RIFF/WAVE file: `channels` holds each channel's samples; `chunks` go between fmt and data.
private func wavFile(_ channels: [[Float]], format: WAVSampleFormat = .float32, extensible: Bool = false,
                     chunks: [(String, [UInt8])] = [], padOddChunks: Bool = true) -> Data {
    let (tag, bytes): (Int, Int) = {
        switch format {
        case .pcm8: return (1, 1)
        case .pcm16: return (1, 2)
        case .pcm24: return (1, 3)
        case .pcm32: return (1, 4)
        case .float32: return (3, 4)
        case .float64: return (3, 8)
        }
    }()
    let nch = channels.count, frames = channels[0].count
    var fmt = le16(extensible ? 0xFFFE : tag) + le16(nch) + le32(48_000) + le32(48_000 * nch * bytes)
        + le16(nch * bytes) + le16(bytes * 8)
    if extensible {
        fmt += le16(22) + le16(bytes * 8) + le32(0) + le16(tag)
        fmt += Data([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
    }
    var audio = Data()
    for i in 0..<frames {
        for c in 0..<nch {
            let v = Double(channels[c][i])
            switch format {
            case .pcm8: audio.append(UInt8(max(0, min(255, Int((v * 128).rounded()) + 128))))
            case .pcm16, .pcm24, .pcm32:
                let scale = Double(Int64(1) << (bytes * 8 - 1))
                let x = Int64(max(-scale, min(scale - 1, (v * scale).rounded())))
                for k in 0..<bytes { audio.append(UInt8(truncatingIfNeeded: x >> (8 * Int64(k)))) }
            case .float32: audio += le32(Int(Float(v).bitPattern))
            case .float64:
                let bits = v.bitPattern
                audio += Data((0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) })
            }
        }
    }
    var body = Data("WAVE".utf8)
    func add(_ id: String, _ payload: Data) {
        body += Data(id.utf8) + le32(payload.count) + payload
        if payload.count % 2 == 1, padOddChunks { body.append(0) }
    }
    add("fmt ", fmt)
    for c in chunks { add(c.0, Data(c.1)) }
    add("data", audio)
    return Data("RIFF".utf8) + le32(body.count) + body
}

private enum SurgeInt16 { case fullScale, halfScaleData }

/// A Surge `.wt`: float32 data, or int16 (full scale with flag 0x08, or peak 2^14 without it).
private func surgeFile(size: Int, frames: [[Float]], int16: SurgeInt16? = nil, extraFlags: Int = 0) -> Data {
    var flags = extraFlags
    if let i = int16 { flags |= 0x04; if i == .fullScale { flags |= 0x08 } }
    var d = Data("vawt".utf8) + le32(size) + le16(frames.count) + le16(flags)
    for v in frames.flatMap({ $0 }) {
        switch int16 {
        case nil: d += le32(Int(v.bitPattern))
        case .fullScale?: d += le16(Int(Int16((v * 32_768).rounded())) & 0xffff)
        case .halfScaleData?: d += le16(Int(Int16((v * 16_384).rounded())) & 0xffff)
        }
    }
    return d
}
