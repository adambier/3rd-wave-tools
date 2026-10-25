import XCTest
@testable import PgdataFormats
@testable import WavetableFormats

/// Cases found in review: ordinary looped samples, the evidence behind a frame size, and the
/// 3rd Wave name of an accented file name as macOS stores it. (The plan's part of these cases is
/// `ReviewFixPlanTests` in PgdataPackerCoreTests.)
final class ReviewFixTests: XCTestCase {
    /// A mono 16-bit WAV with an optional smpl loop over [loopStart, loopEnd].
    private func wav16(_ samples: Int, loop: (Int, Int)? = nil) -> Data {
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func u16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var fmt: [UInt8] = u16(1) + u16(1) + u32(48_000)
        fmt += u32(96_000) + u16(2) + u16(16)
        fmt = Array("fmt ".utf8) + u32(fmt.count) + fmt
        var body = fmt
        if let (s, e) = loop {
            var smpl = [UInt8](repeating: 0, count: 28) + u32(1) + u32(0)
            smpl += u32(0) + u32(0) + u32(s)
            smpl += u32(e) + u32(0) + u32(0)
            body += Array("smpl".utf8) + u32(smpl.count) + smpl
        }
        let audio = (0..<samples).flatMap { i in u16(Int(sin(Double(i) * 0.05) * 12_000)) }
        body += Array("data".utf8) + u32(audio.count) + audio
        return Data(Array("RIFF".utf8) + u32(4 + body.count) + Array("WAVE".utf8) + body)
    }

    func testOrdinaryLoopedSampleIsNotAWavetable() throws {
        XCTAssertEqual(try WavetableReader.read(wav16(48_000, loop: (0, 47_999)), fileName: "Pad.wav").count, 0)
    }

    func testFrameSizeEvidence() throws {
        XCTAssertEqual(try WavetableReader.read(wav16(65_536), fileName: "a.wav").first?.frameSizeEvidence, .length)
        XCTAssertEqual(try WavetableReader.read(wav16(16_384), fileName: "b.wav").first?.frameSizeEvidence, FrameSizeEvidence.none)
        XCTAssertEqual(try WavetableReader.read(wav16(65_536), fileName: "c_wt1024.wav").first?.frameSizeEvidence, .fileName)
        XCTAssertEqual(try WavetableReader.read(wav16(8192, loop: (0, 2047)), fileName: "d.wav").first?.frameSizeEvidence, .markers)
        let p = try XCTUnwrap(WavetableReader.read(Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/wavetable-p.wt")), fileName: "p.wt").first)
        XCTAssertEqual(p.frameSizeEvidence, .statedInFile)
    }

    func testEightThousandSamplesOfferOtherSizes() throws {
        let found = try XCTUnwrap(WavetableReader.read(wav16(8192), fileName: "Four.wav").first)
        XCTAssertNil(found.frameSize)
        XCTAssertEqual(found.candidateFrameSizes, [128, 2048])
    }

    func testDecomposedAccentsKeepTheirLetters() throws {
        let nfd = "Cafe\u{301} Pad"   // "Café Pad" as macOS file names store it
        let wave = (0..<1024).map { Float(sin(2 * Double.pi * Double($0) / 1024)) * 0.5 }
        let out = try WavetableWriter.write(Wavetable(name: nfd, frames: Array(repeating: wave, count: 64)), preset: .thirdWaveU)
        // The .wt's name line (its second line, Latin-1), read without parsing the values below it.
        let nameLine = out.data.split(separator: UInt8(ascii: "\n"), maxSplits: 2, omittingEmptySubsequences: false)[1]
        XCTAssertEqual(String(nameLine.map { Character(Unicode.Scalar($0)) }), "Café Pad")
        XCTAssertFalse(out.notes.contains { $0.contains("Latin-1") }, "\(out.notes)")
        XCTAssertEqual(NameField(nfd).text, "Café Pad")
    }
}
