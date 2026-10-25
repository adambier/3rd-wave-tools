import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

/// The plan's part of the cases found in review (the reader's part is `ReviewFixTests` in
/// WavetableFormatsTests): a frame size suggested by the file's length alone can be changed; one
/// stated in the file cannot.
final class ReviewFixPlanTests: XCTestCase {
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
        XCTAssertTrue(plan.items[0].basisDescription.hasPrefix("Set manually"))
        plan.chooseFrameSize(id, 2048)   // back to the file's own
        XCTAssertNil(plan.items[0].chosenFrameSize)
    }

    /// A stated size can be overridden with another the length allows (a wrong tag happens);
    /// the file's own size comes first and stays "in the file" until another is chosen.
    func testMetadataSizeCanBeOverriddenWithinWhatFits() {
        let t = FoundTable(name: "T", fileName: "t.wav", source: .wav, samples: Array(repeating: 0, count: 8192),
                           frameSize: 2048, frameSizeBasis: "clm chunk")
        var plan = ConvertPlan()
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/t.wav"), table: t)])
        XCTAssertEqual(plan.items[0].frameSizeChoices, [2048, 64, 128, 256, 512, 1024, 4096])
        XCTAssertEqual(plan.items[0].sizeQualifier, "in the file")
        plan.chooseFrameSize(plan.items[0].id, 1000)   // not offered
        XCTAssertEqual(plan.items[0].frameSize, 2048)
        plan.chooseFrameSize(plan.items[0].id, 1024)
        XCTAssertEqual(plan.items[0].frameSize, 1024)
        XCTAssertEqual(plan.items[0].sizeQualifier, "set manually")
        // A 3rd Wave table's format fixes its size: no choice to make, so the cell is plain text.
        let u = FoundTable(name: "U", fileName: "u.wt", source: .thirdWaveWavetable(isP: false),
                           samples: Array(repeating: 0, count: 65_536), frameSize: 1024, frameSizeBasis: "3rd Wave U table")
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/u.wt"), table: u)])
        XCTAssertEqual(plan.items[1].frameSizeChoices, [])
    }
}
