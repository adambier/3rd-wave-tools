import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

/// Cases found in review: ordinary looped samples, frame sizes suggested by length only, and the
/// 3rd Wave name of an accented file name as macOS stores it.
final class ReviewFixTests: XCTestCase {
    /// A mono 16-bit WAV with an optional smpl loop over [loopStart, loopEnd].
    private func wav16(_ samples: Int, loop: (Int, Int)? = nil) -> Data {
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func u16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var fmt = u16(1) + u16(1) + u32(48_000) + u32(96_000) + u16(2) + u16(16)
        fmt = Array("fmt ".utf8) + u32(fmt.count) + fmt
        var body = fmt
        if let (s, e) = loop {
            var smpl = [UInt8](repeating: 0, count: 28) + u32(1) + u32(0)
            smpl += u32(0) + u32(0) + u32(s) + u32(e) + u32(0) + u32(0)
            body += Array("smpl".utf8) + u32(smpl.count) + smpl
        }
        let audio = (0..<samples).flatMap { i in u16(Int(sin(Double(i) * 0.05) * 12_000)) }
        body += Array("data".utf8) + u32(audio.count) + audio
        return Data(Array("RIFF".utf8) + u32(4 + body.count) + Array("WAVE".utf8) + body)
    }

    func testOrdinaryLoopedSampleIsNotAWavetable() throws {
        XCTAssertEqual(try WavetableReader.read(wav16(48_000, loop: (0, 47_999)), fileName: "Pad.wav").count, 0)
    }

    func testLengthOnlyFrameSizeCanBeChanged() throws {
        let found = try XCTUnwrap(WavetableReader.read(wav16(65_536), fileName: "Table.wav").first)
        XCTAssertEqual(found.frameSize, 2048)
        XCTAssertTrue(found.candidateFrameSizes.contains(1024))
        var plan = ConvertPlan()
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/Table.wav"), table: found)])
        let id = try XCTUnwrap(plan.items.first?.id)
        XCTAssertEqual(plan.items[0].frameSizeChoices.first, 2048)
        plan.chooseFrameSize(id, 1024)
        XCTAssertEqual(plan.items[0].frameSize, 1024)
        XCTAssertEqual(plan.items[0].frameCount, 64)
        XCTAssertTrue(plan.items[0].basisDescription.hasPrefix("Your choice"))
        plan.chooseFrameSize(id, 2048)   // back to the file's own
        XCTAssertNil(plan.items[0].chosenFrameSize)
    }

    func testEightThousandSamplesOfferOtherSizes() throws {
        let found = try XCTUnwrap(WavetableReader.read(wav16(8192), fileName: "Four.wav").first)
        XCTAssertEqual(found.frameSize, 128)
        XCTAssertTrue(found.candidateFrameSizes.contains(2048))
    }

    func testMetadataSizeIsNotOfferedForChange() {
        let t = FoundTable(name: "T", fileName: "t.wav", source: .wav, samples: Array(repeating: 0, count: 4096),
                           frameSize: 2048, frameSizeBasis: "clm chunk")
        var plan = ConvertPlan()
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/t.wav"), table: t)])
        XCTAssertEqual(plan.items[0].frameSizeChoices, [])
        plan.chooseFrameSize(plan.items[0].id, 1024)
        XCTAssertEqual(plan.items[0].frameSize, 2048)
    }

    func testDecomposedAccentsKeepTheirLetters() throws {
        let nfd = "Cafe\u{301} Pad"   // "Café Pad" as macOS file names store it
        let wave = (0..<1024).map { Float(sin(2 * Double.pi * Double($0) / 1024)) * 0.5 }
        let out = try WavetableWriter.write(Wavetable(name: nfd, frames: Array(repeating: wave, count: 64)), preset: .thirdWaveU)
        let wt = try WavetableFile(data: out.data)
        XCTAssertEqual(wt.name, "Café Pad")
        XCTAssertFalse(out.notes.contains { $0.contains("Latin-1") }, "\(out.notes)")
        XCTAssertEqual(NameField(nfd).text, "Café Pad")
    }
}
