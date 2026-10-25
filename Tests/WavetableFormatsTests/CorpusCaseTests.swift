import XCTest
import Foundation
@testable import WavetableFormats

// Each test rebuilds, synthetically, the shape of a file met in a scan of about 20,000 files from
// wavetable and sample libraries (Hive, Surge XT, Serum packs, Tonverk's factory library and
// third-party Tonverk packs, Phase Plant, DUNE 3, a MiniFreak V bank, and the 3rd Wave's factory
// files), and checks what the reader makes of it. No file from any library is copied here: the
// samples are ramps, and only the layout, chunks, and names are reproduced.

final class CorpusCaseTests: XCTestCase {

    // MARK: - u-he Hive

    /// Hive's library: mono WAV, a `uhWT` chunk of 272 bytes (u32 0, u32 frames, u32 frame size,
    /// u32 0, then a description), no `clm ` chunk.
    func testHiveTable() throws {
        let uh = ("uhWT", u32(0) + u32(24) + u32(2048) + u32(0) + padded("Filter sweep", to: 256))
        let t = try one(corpusWAV([saw(24 * 2048)], format: .pcm16, rate: 44_100, chunks: [uh]), "Overblow.wav")
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.frameSizeBasis, "u-he tag inside the file (uhWT chunk)")
        XCTAssertEqual(t.frameSizeEvidence, .statedInFile)
        XCTAssertNil(t.interpolation)
        XCTAssertEqual(t.notes, [])
        // Some of Hive's float files peak well over full scale (one at 8.0): noted, not an error.
        let loud = try one(corpusWAV([saw(6 * 2048).map { $0 * 8 }], format: .float32, rate: 44_100, chunks: [uh]), "Glass to Brass.wav")
        XCTAssertEqual(loud.notes, ["Peak 8.00: over full scale (±1). Converting to a 3rd Wave table or a 16-bit file scales it down to fit."])
    }

    // MARK: - Serum-style packs (Starsky's Analog Collection, Oxenholme's JunVerk, the RMR packs)

    func testSerumPackTables() throws {
        // A clm chunk of 48 bytes: "<!>2048 00000000 wavetable (…)", NUL-padded.
        let stepped = try one(corpusWAV([saw(128 * 2048)], format: .float32, rate: 44_100,
                                        chunks: [clmChunk("<!>2048 00000000 wavetable (starsky)")]), "100pc reso filter.wav")
        XCTAssertEqual(stepped.frameSize, 2048)
        XCTAssertEqual(stepped.interpolation, Interpolation.none)
        XCTAssertEqual(stepped.frameSizeBasis, "Serum-style tag inside the file (clm chunk)")
        let faded = try one(corpusWAV([saw(64 * 2048)], format: .float32, rate: 44_100,
                                      chunks: [clmChunk("<!>2048 10000000 wavetable (www.carvetoy.com)")]), "CarveToy_JunoPWM.wav")
        XCTAssertEqual(faded.interpolation, .crossfade)
        let spectral = try one(corpusWAV([saw(33 * 2048)], format: .float32, rate: 44_100,
                                         chunks: [clmChunk("<!>2048 20000000 wavetable (vital.audio)")]), "KOMPLEXER_WT2.WAV")
        XCTAssertEqual(spectral.interpolation, .spectral)
        XCTAssertEqual(spectral.name, "KOMPLEXER_WT2")   // "_WT2" numbers the table; it is not a Tonverk tag
        XCTAssertEqual(spectral.notes, [])
    }

    /// Two folders of a Serum pack held samples, not tables: a Korg MS-2000's single cycles
    /// (stereo, one loop over the whole file, named by note) and a Virus's sustained notes (16-bit,
    /// a sustain loop that does not start at 0, an `inst` chunk). Neither is listed.
    func testSamplesInsideAWavetablePackAreNotListed() throws {
        let cycle = corpusWAV([saw(674), saw(674)], format: .float32, rate: 44_100, chunks: [smplChunk(loops: [(0, 673)])])
        XCTAssertEqual(try WavetableReader.read(cycle, fileName: "SAW-C1.wav"), [])
        let inst = ("inst", [UInt8](repeating: 0, count: 8))
        let virus = corpusWAV([saw(6968)], format: .pcm16, rate: 48_000, chunks: [smplChunk(loops: [(1098, 6967)]), inst])
        XCTAssertEqual(try WavetableReader.read(virus, fileName: "Virus_WT_001.wav"), [])
    }

    // MARK: - Elektron Tonverk

    /// Tonverk's own wavetables: 32-bit float, 48 kHz, no chunk of any kind; the frame size is
    /// the length's doing, and 8,192 and 16,384 samples are left for the user to settle.
    func testTonverkFactoryWavetables() throws {
        let t = try one(corpusWAV([saw(64 * 2048)], format: .float32, rate: 48_000), "Bass Bridge.wav")
        XCTAssertEqual(t.frameSize, 2048)
        XCTAssertEqual(t.frameSizeEvidence, .length)
        XCTAssertEqual(t.candidateFrameSizes, [512, 1024, 4096])
        XCTAssertEqual(try one(corpusWAV([saw(15 * 2048)], format: .float32, rate: 48_000), "Bowed Lowed.wav").candidateFrameSizes,
                       [128, 256, 512, 1024])
        let all = try one(corpusWAV([saw(8192)], format: .float32, rate: 48_000), "All Waves.wav")
        XCTAssertNil(all.frameSize)
        XCTAssertEqual(all.candidateFrameSizes, [128, 2048])
        XCTAssertEqual(all.frameSizeEvidence, .none)
        let pinanino = try one(corpusWAV([saw(16_384)], format: .float32, rate: 48_000), "Pinanino.wav")
        XCTAssertNil(pinanino.frameSize)
        XCTAssertEqual(pinanino.candidateFrameSizes, [2048, 256])   // float: a WaveEdit bank is less likely than 8 × 2,048
        // A name like "Bwt1" is not a note name.
        XCTAssertEqual(try one(corpusWAV([saw(32 * 2048)], format: .float32, rate: 44_100), "Bwt1.wav").name, "Bwt1")
    }

    /// Tonverk's multisampled instruments: each note is its own WAV, named "<Name>-000-<midi>-<note>",
    /// 64-bit float, 65,536 samples (which happens to be 32 × 2,048), mono or stereo. Its "Pure"
    /// waves are 16-bit single cycles whose sample rate carries the pitch. None is a wavetable.
    func testTonverkMultisampledInstrumentsAreNotWavetables() throws {
        for name in ["Spectral Undertones-000-012-c1.wav", "Spectral Pad-000-025-c#2.wav", "Spectral Synced Noise-000-023-b1.wav"] {
            XCTAssertEqual(try WavetableReader.read(corpusWAV([saw(65_536)], format: .float64, rate: 48_000), fileName: name), [], name)
            XCTAssertEqual(try WavetableReader.read(corpusWAV([saw(65_536), saw(65_536)], format: .float64, rate: 48_000), fileName: name), [], name)
        }
        XCTAssertEqual(try WavetableReader.read(corpusWAV([saw(2936)], format: .pcm16, rate: 96_017), fileName: "Pure Saw-000-036-c1.wav"), [])
    }

    /// Third-party Tonverk packs (Metropolis Border): tables in a "Wavetables" folder with no
    /// chunks, plus a stereo single cycle with a loop among the samples.
    func testTonverkThirdPartyPack() throws {
        XCTAssertEqual(try one(corpusWAV([saw(64 * 2048)], format: .float32, rate: 48_000), "Afterglow.wav").frameSize, 2048)
        let single = corpusWAV([saw(5400), saw(5400)], format: .float32, rate: 44_100, chunks: [smplChunk(loops: [(0, 674)])])
        XCTAssertEqual(try WavetableReader.read(single, fileName: "10singlecycle.wav"), [])
    }

    // MARK: - Surge XT

    func testSurgeLibrary() throws {
        // Surge's own "HQ" basic tables: 16-bit, a loop over the first frame, and a SAUR chunk.
        let saur = ("SAUR", [UInt8](repeating: 0, count: 32))
        let tri = try one(corpusWAV([saw(2 * 2048)], format: .pcm16, rate: 44_100, chunks: [smplChunk(loops: [(0, 2047)]), saur]), "Triangle HQ.wav")
        XCTAssertEqual(tri.frameSize, 2048)
        XCTAssertEqual(tri.frameSizeEvidence, .markers)
        XCTAssertEqual(tri.frameSizeBasis, "loop markers over the first frame (which ordinary samples can have too)")
        // Its "Generated" tables: 512-sample frames marked the same way.
        XCTAssertEqual(try one(corpusWAV([saw(6 * 512)], format: .pcm16, rate: 44_100, chunks: [smplChunk(loops: [(0, 511)])]), "Saw ATC.wav").frameSize, 512)
        // Third-party tables whose length falls one sample short of a whole frame (A.Liv's).
        let short = try one(corpusWAV([saw(89 * 2048 - 1)], format: .float32, rate: 44_100, chunks: [clmChunk("<!>2048 00000000")]), "Droplet 5.wav")
        XCTAssertEqual(short.wavetable()?.frameCount, 88)
        XCTAssertEqual(short.notes, ["2,047 samples after the last whole frame are left out (1 sample short of another frame)."])
        // A one-shot sample marked with srgo, and a Surge .wt flagged as a sample: not listed.
        XCTAssertEqual(try WavetableReader.read(corpusWAV([saw(5000)], format: .pcm16, rate: 44_100, chunks: [("srgo", u32(1) + u32(5000))]), fileName: "Flute 1.wav"), [])
        let sample = Data(Array("vawt".utf8) + u32(2048) + u16(1) + u16(0x01) + saw(2048).flatMap { u32(Int($0.bitPattern)) })
        XCTAssertEqual(try WavetableReader.read(sample, fileName: "Blip 1.wt"), [])
        // A plain 16-bit sample of 33 × 2,048 samples in the same library (Emu's "EP.wav") is listed
        // by its length: the reader cannot tell, and says so with .length.
        XCTAssertEqual(try one(corpusWAV([saw(33 * 2048)], format: .pcm16, rate: 44_100), "EP.wav").frameSizeEvidence, .length)
    }

    // MARK: - Formats the reader does not read

    /// DUNE 3's `.wt` is its own binary format; a MiniFreak V bank (`.mnfx`) is a zip of presets
    /// that name their wavetables without holding them. Neither is a WAV, a FLAC file, a Surge
    /// file, or a 3rd Wave file, so each is passed over without an error. (Phase Plant's factory
    /// tables are FLAC, which the reader does read: FLACTests.)
    func testUnreadFormatsArePassedOverQuietly() throws {
        XCTAssertTrue(WavetableReader.mayContainWavetables(fileName: "Brass.flac"))
        XCTAssertFalse(WavetableReader.mayContainWavetables(fileName: "Bank.mnfx"))
        XCTAssertTrue(WavetableReader.mayContainWavetables(fileName: "Vintage Saw.wt"))
        let dune = Data(u32(2) + u32(0) + u32(0) + u32(0x0015_0800) + u32(24) + u32(3) + u32(0) + u32(0x3F80_0000)) + Data(repeating: 0, count: 320 + 4096)
        XCTAssertEqual(try WavetableReader.read(dune, fileName: "Vintage Saw.wt"), [])
        XCTAssertEqual(try WavetableReader.read(Data("PK\u{3}\u{4}".utf8) + Data(repeating: 0, count: 64), fileName: "Bank.mnfx"), [])
    }

    // MARK: - Helpers

    private func one(_ d: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> FoundTable {
        let all = try WavetableReader.read(d, fileName: name)
        XCTAssertEqual(all.count, 1, name, file: file, line: line)
        return try XCTUnwrap(all.first, file: file, line: line)
    }
}

// MARK: - Builders (test-only)

private enum CorpusFormat { case pcm16, float32, float64 }

/// A sawtooth cycle repeated: n samples from −1 up to just below 1 every 256 samples.
private func saw(_ n: Int) -> [Float] { (0..<n).map { Float(($0 % 256) - 128) / 128 } }

private func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
private func padded(_ s: String, to n: Int) -> [UInt8] { Array(s.utf8) + [UInt8](repeating: 0, count: max(0, n - s.utf8.count)) }
private func clmChunk(_ text: String) -> (String, [UInt8]) { ("clm ", padded(text, to: 48)) }
private func smplChunk(loops: [(Int, Int)]) -> (String, [UInt8]) {
    var b = [UInt8](repeating: 0, count: 28) + u32(loops.count) + u32(0)
    for (i, l) in loops.enumerated() { b += u32(i) + u32(0) + u32(l.0) + u32(l.1) + u32(0) + u32(0) }
    return ("smpl", b)
}

/// A RIFF/WAVE file as the libraries write them: fmt (with a fact chunk for float), the extra
/// chunks, then data.
private func corpusWAV(_ channels: [[Float]], format: CorpusFormat, rate: Int, chunks: [(String, [UInt8])] = []) -> Data {
    let (tag, bytes): (Int, Int) = { switch format { case .pcm16: return (1, 2); case .float32: return (3, 4); case .float64: return (3, 8) } }()
    let nch = channels.count, frames = channels[0].count
    var fmt = u16(tag) + u16(nch) + u32(rate) + u32(rate * nch * bytes) + u16(nch * bytes) + u16(bytes * 8)
    if tag == 3 { fmt += u16(0) }
    var audio: [UInt8] = []
    audio.reserveCapacity(frames * nch * bytes)
    for i in 0..<frames {
        for c in 0..<nch {
            let v = channels[c][i]
            switch format {
            case .pcm16: audio += u16(Int(Int16(max(-32_768, min(32_767, (v * 32_768).rounded())))) & 0xffff)
            case .float32: audio += u32(Int(v.bitPattern))
            case .float64:
                let bits = Double(v).bitPattern
                audio += (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
            }
        }
    }
    var body = Array("WAVE".utf8)
    func add(_ id: String, _ payload: [UInt8]) {
        body += Array(id.utf8) + u32(payload.count) + payload
        if payload.count % 2 == 1 { body.append(0) }
    }
    add("fmt ", fmt)
    if tag == 3 { add("fact", u32(frames)) }
    for c in chunks { add(c.0, c.1) }
    add("data", audio)
    return Data(Array("RIFF".utf8) + u32(body.count) + body)
}
