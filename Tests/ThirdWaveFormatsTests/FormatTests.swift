import XCTest
@testable import ThirdWaveFormats

final class SourceRefTests: XCTestCase {
    // Each of these was checked on an 8M (OS 2.0d) by reading the slot the synth displays.
    func testIdsVerifiedOnHardware() {
        XCTAssertEqual(SourceRef(id: 34), .u(0))      // B1-P049 SparkleSauce, osc 3 → U00
        XCTAssertEqual(SourceRef(id: 2000), .u(7))    // B1-P059 KnobGrotto1, osc 1 → U07
        XCTAssertEqual(SourceRef(id: 1000), .p(34))   // B4-P003 FilString VS, osc 1 → P34
    }

    func testIdRoundTripCoversEverySlot() {
        for n in 0..<48 { XCTAssertEqual(SourceRef(id: SourceRef.p(n).id), .p(n)) }
        for n in 0..<64 { XCTAssertEqual(SourceRef(id: SourceRef.u(n).id), .u(n)) }
        for n in 0..<7 { XCTAssertEqual(SourceRef(id: SourceRef.analog(n).id), .analog(n)) }
        for n in 0...127 { XCTAssertEqual(SourceRef(id: SourceRef.s(n).id), .s(n)) }
        XCTAssertEqual(SourceRef.u(63).id, 2056)
        XCTAssertEqual(SourceRef.p(47).id, 1013)
    }

    func testFactoryRanges() {
        XCTAssertTrue(SourceRef.p(35).isFactorySlot)
        XCTAssertFalse(SourceRef.p(36).isFactorySlot)
        XCTAssertTrue(SourceRef.u(55).isFactorySlot)
        XCTAssertFalse(SourceRef.u(56).isFactorySlot)
        XCTAssertFalse(SourceRef.s(0).isFactorySlot)
    }

    func testFilenameSuggestions() {
        XCTAssertEqual(SourceRef.suggested(byFilename: "S000_Amen Cuts.bin"), .s(0))
        XCTAssertEqual(SourceRef.suggested(byFilename: "S010_JP8_.bin"), .s(10))
        XCTAssertEqual(SourceRef.suggested(byFilename: "U48 SM OBX8 1.WT"), .u(48))
        XCTAssertEqual(SourceRef.suggested(byFilename: "U50_SM OB2.wt"), .u(50))
        XCTAssertNil(SourceRef.suggested(byFilename: "01.wt"))
        XCTAssertNil(SourceRef.suggested(byFilename: "Prophet 5 VCO Saw.bin"))
    }
}

/// Builds a small but structurally faithful program: S = 181, 4 parts, 520 floats, int tail.
func makeProgram(sources: [Int32], version: String = "W3_PROG_5", floats: Int = 544) -> ProgramFile {
    let s = 181
    var v: [ProgramFile.Value] = [.int(Int32(s))]
    for _ in 0..<(4 * s + 3) { v.append(.int(0)) }
    for i in 0..<floats { v.append(.float(Float(i % 7) * 0.125)) }
    for i in 0..<40 { v.append(.int(Int32(i % 3))) }
    var p = ProgramFile(version: version, name: "Test Prog", values: v)
    for (k, id) in sources.enumerated() { p.setSourceID(id, at: k) }
    return p
}

func makeMultisample() -> Multisample {
    let audio: [UInt8] = (0..<200).map { UInt8($0 & 0xff) }
    let s = Multisample.Sample(name: NameField("Test C2"), length: 100, start: 0, end: 99, loopStart: 10, loopEnd: 90,
                               rootNote: 48, lowNote: 24, highNote: 60, loopMode: 1, crossfade: 5, crossfadeType: 2,
                               audio: audio)
    return Multisample(slotName: NameField("Test"), samples: [s])
}

final class ProgramTests: XCTestCase {
    func testTextRoundTrip() throws {
        let p = makeProgram(sources: [4000, 2043, 42, 41, 42, 42, 2, 35, 42, 41, 42, 42])
        let again = try ProgramFile(data: p.serialized())
        XCTAssertEqual(again.serialized(), p.serialized())
        XCTAssertEqual(again.sources.first, .s(0))
        XCTAssertEqual(again.distinctSources, [.s(0), .u(50), .analog(1), .analog(0), .p(2), .u(1)])
    }

    func testCRLFPreserved() throws {
        let p = makeProgram(sources: Array(repeating: 42, count: 12))
        let crlf = String(decoding: p.serialized(), as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = try ProgramFile(data: Data(crlf.utf8))
        XCTAssertEqual(parsed.serialized(), Data(crlf.utf8))
    }
}

final class PackTests: XCTestCase {
    func testPackUnpackRoundTrip() throws {
        let pro = makeProgram(sources: [4010, 2043, 42, 4010, 2043, 43, 2, 35, 42, 41, 42, 42])
        let wt = WavetableFile(kind: .u, name: "SM OB2", values: (0..<131_072).map { Float($0 % 2048) / 2048 })
        let content: [SourceRef: SourceContent] = [.s(10): .multisample(makeMultisample()), .u(50): .wavetable(wt),
                                                   .p(2): .reference, .u(1): .reference]
        let g = try Packer.pack(pro, content: content)
        XCTAssertEqual(g.sources.map(\.ref), [.s(10), .u(50), .analog(1), .analog(2), .p(2), .u(1), .analog(0)])
        XCTAssertEqual(g.sources.map(\.hasData), [true, true, false, false, false, false, false])

        let parsed = try UnifiedProgram(data: g.serialized())
        XCTAssertEqual(parsed.serialized(), g.serialized())
        XCTAssertEqual(parsed.oscillatorSources.first!, .s(10))

        let up = Unpacker.unpack(parsed)
        XCTAssertEqual(up.program.serialized(), pro.serialized())
        XCTAssertEqual(up.wavetables.first?.file.values, wt.values)
        XCTAssertEqual(up.multisamples.first?.sample, makeMultisample())
        XCTAssertEqual(up.referenced, [.p(2), .u(1)])
    }

    func testOlderFloatLayoutDetected() throws {
        // 520-float layout (older W3_PROG_5 and W3_PROG_4) followed by small integers.
        var pro = makeProgram(sources: Array(repeating: 42, count: 12), floats: 520)
        for i in (4 * 181 + 4 + 520)..<(4 * 181 + 4 + 544) { pro.values[i] = .int(Int32(i % 5 + 1)) }
        let g = try Packer.pack(pro, content: [:])
        XCTAssertEqual(Unpacker.unpack(g).program.serialized(), pro.serialized())
    }

    func testSampleCanBeLeftOutOnlyExplicitly() throws {
        let pro = makeProgram(sources: [4000] + Array(repeating: 42, count: 11))
        let g = try Packer.pack(pro, content: [.s(0): .reference])
        XCTAssertFalse(g.sources[0].hasData)
        // The plan never chooses that by itself.
        let plan = PackPlan.make(program: pro, files: [], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.verdict, .blocked([.s(0)]))
        XCTAssertTrue(plan.rows[0].options.contains(.reference))
        let chosen = PackPlan.make(program: pro, files: [], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false,
                                   overrides: [.s(0): .reference])
        guard case .warning? = chosen.rows.first?.status else { return XCTFail("expected a warning") }
    }

    func testMissingContentIsReported() {
        let pro = makeProgram(sources: [2049] + Array(repeating: 42, count: 11))
        XCTAssertThrowsError(try Packer.pack(pro, content: [:])) { e in
            XCTAssertTrue("\(e)".contains("U56"))
        }
    }

    func testWrongTableKindRejected() {
        let pro = makeProgram(sources: [2049] + Array(repeating: 42, count: 11))
        let p = WavetableFile(kind: .p, name: "x", values: Array(repeating: 0, count: 16_384))
        XCTAssertThrowsError(try Packer.pack(pro, content: [.u(56): .wavetable(p)]))
    }

    func testNeedsUnifiedFile() {
        let factoryOnly = makeProgram(sources: [34, 2000, 1000, 41, 42, 42, 2, 35, 42, 41, 42, 42])
        XCTAssertFalse(Packer.needsUnifiedFile(factoryOnly) { $0.isFactorySlot })
        let withSample = makeProgram(sources: [4000] + Array(repeating: 42, count: 11))
        XCTAssertTrue(Packer.needsUnifiedFile(withSample) { $0.isFactorySlot })
    }
}

final class MultisampleTests: XCTestCase {
    func testBinRoundTrip() throws {
        let m = makeMultisample()
        let d = m.binData()
        XCTAssertEqual(Array(d.prefix(12)), Array("W3_MSAMPLE_5".utf8))
        XCTAssertEqual(try Multisample(binData: d).binData(), d)
    }

    func testVersion1Upgrade() throws {
        // v1: no rate/bit depth, no pitch/second rate/volume.
        var w = ByteWriter()
        w.put(NameField("W3_MSAMPLE_1", width: 16).raw)
        w.u8(1); w.put(NameField("Old").raw)
        w.u32(2); w.put(NameField("S1").raw)
        w.u32(0); w.u32(1); w.u32(0); w.u32(1)
        w.u8(36); w.u8(24); w.u8(48); w.u8(1)
        w.u32(0); w.u8(0)
        w.put([1, 0, 2, 0])
        let m = try Multisample(binData: Data(w.bytes))
        XCTAssertEqual(m.sourceVersion, 1)
        let s = m.samples[0]
        XCTAssertEqual(s.sampleRate, 48_000); XCTAssertEqual(s.bitDepth, 2)
        XCTAssertEqual(s.secondRate, 48_000); XCTAssertEqual(s.volume, 1); XCTAssertEqual(s.pitch, 0)
        XCTAssertEqual(s.audio, [1, 0, 2, 0])
    }
}
