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

    /// A size the file's contents state is not offered for change; one the app estimated (a
    /// tag in the file name, markers, a .txt, the length) is the default of a choice among the
    /// sizes the length allows; a 3rd Wave table's format fixes its size.
    func testOnlyEstimatedSizesAreOfferedForChange() {
        var plan = ConvertPlan()
        let stated = FoundTable(name: "T", fileName: "t.wav", source: .wav, samples: Array(repeating: 0, count: 8192),
                                frameSize: 2048, frameSizeBasis: "clm chunk")
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/t.wav"), table: stated)])
        XCTAssertFalse(plan.items[0].sizeIsEstimate)
        XCTAssertEqual(plan.items[0].frameSizeChoices, [])
        XCTAssertEqual(plan.items[0].sizeQualifier, "in the file")
        plan.chooseFrameSize(plan.items[0].id, 1024)
        XCTAssertEqual(plan.items[0].frameSize, 2048, "not offered, so not taken")

        let tagged = FoundTable(name: "Pad_wt1024", fileName: "Pad_wt1024.wav", source: .wav, samples: Array(repeating: 0, count: 8192),
                                frameSize: 1024, frameSizeBasis: "Tonverk tag in the file name", frameSizeEvidence: .fileName)
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/Pad_wt1024.wav"), table: tagged)])
        XCTAssertTrue(plan.items[1].sizeIsEstimate)
        XCTAssertEqual(plan.items[1].frameSizeChoices, [1024, 64, 128, 256, 512, 2048, 4096])
        XCTAssertEqual(plan.items[1].frameSize, 1024, "the estimate is the default")
        XCTAssertEqual(plan.items[1].sizeQualifier, "in the name")
        plan.chooseFrameSize(plan.items[1].id, 2048)
        XCTAssertEqual(plan.items[1].frameSize, 2048)
        XCTAssertEqual(plan.items[1].sizeQualifier, "set manually")
        plan.chooseFrameSize(plan.items[1].id, 1024)   // back to the tag's
        XCTAssertNil(plan.items[1].chosenFrameSize)

        let u = FoundTable(name: "U", fileName: "u.wt", source: .thirdWaveWavetable(isP: false),
                           samples: Array(repeating: 0, count: 65_536), frameSize: 1024, frameSizeBasis: "3rd Wave U table")
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/u.wt"), table: u)])
        XCTAssertEqual(plan.items[2].frameSizeChoices, [])
    }
}
