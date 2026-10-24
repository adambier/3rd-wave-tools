import XCTest
@testable import PgdataFormats

final class SourceRefTests: XCTestCase {
    // Each of these was checked on an 8M (OS 2.0d) by reading the slot the synth displays.
    func testIdsVerifiedOnHardware() {
        XCTAssertEqual(SourceRef(id: 34), .u(0))      // B1-P049 SparkleSauce, osc 3 → U00
        XCTAssertEqual(SourceRef(id: 2000), .u(7))    // B1-P059 KnobGrotto1, osc 1 → U07
        XCTAssertEqual(SourceRef(id: 1000), .p(34))   // B4-P003 FilString VS, osc 1 → P34
    }

    // Analog waves: each id read from the OSC screen of an 8M (OS 2.0d, 2026-10-23).
    func testAnalogIdsVerifiedOnHardware() {
        let shown: [Int32: String] = [41: "A00 Sawtooth", 42: "A01 Square", 43: "A04 Supersaw", 44: "A03 Sine",
                                      45: "A05 Pink noise", 46: "A06 Blue noise", 47: "A02 Triangle"]
        for (id, text) in shown { XCTAssertEqual(SourceRef(id: id).description, text) }
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

    func testFloatsFollowTheHeaderNotTheText() throws {
        // A float block line written "1" by another tool is the float 1.0, not the integer 1.
        var lines = String(decoding: makeCurrentProgram().serialized(), as: UTF8.self).components(separatedBy: "\n")
        let firstFloat = 2 + 4 + 4 * 181                   // line index of part 1 float 0
        lines[firstFloat] = "1"
        lines[firstFloat + 1] = "0"
        lines[2 + 4 + 7] = "3.000000"                      // a whole number written as a float, in an integer position
        let p = try ProgramFile(data: Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(p.values[4 + 4 * 181], .float(1, text: "1"))
        XCTAssertEqual(p.values[4 + 4 * 181].word, Float(1).bitPattern)
        XCTAssertEqual(p.values[4 + 4 * 181 + 1].word, Float(0).bitPattern)
        XCTAssertEqual(p.values[4 + 7], .int(3, text: "3.000000"))
        XCTAssertEqual(p.floatBlockCount, 4 * 137)
        // Trailing blank lines and trailing spaces are tolerated; non-numbers and fractions in integer positions are not.
        XCTAssertNoThrow(try ProgramFile(data: Data((lines.joined(separator: "\n") + "\n\n").utf8)))
        lines[2 + 4 + 8] = "5 "
        XCTAssertEqual(try ProgramFile(data: Data(lines.joined(separator: "\n").utf8)).values[4 + 8], .int(5, text: "5"))
        lines[2 + 4 + 8] = "5.5"
        XCTAssertThrowsError(try ProgramFile(data: Data(lines.joined(separator: "\n").utf8)))
        lines[firstFloat] = "nan"
        XCTAssertThrowsError(try ProgramFile(data: Data(lines.joined(separator: "\n").utf8)))
    }

    func testValuesBeyondTheHeaderAreDropped() throws {
        // The 3rd Wave leaves the end of an old file in place when it exports onto a longer one.
        var long = makeCurrentProgram()
        let declared = long.values.count
        long.values += (0..<50).map { .int(Int32($0)) }
        XCTAssertEqual(long.declaredCount, declared)
        XCTAssertEqual(long.excessValues, 50)
        XCTAssertNil(ProgramConverter.layout(of: long))
        let plan = PackPlan.make(program: long, files: [], factory: FactoryLibrary())
        XCTAssertTrue(plan.warnings.contains { $0.contains("50 values beyond") })
        XCTAssertNil(plan.conversion)
        let g = try Packer.pack(long, content: [:])
        XCTAssertEqual(g.words.count, declared)
        // A short file is refused when read; one built in memory gets a warning and is packed as it is.
        var short = makeCurrentProgram(); short.values.removeLast(10)
        XCTAssertTrue(PackPlan.make(program: short, files: [], factory: FactoryLibrary()).warnings.contains { $0.contains("header declares") })
        XCTAssertEqual(try Packer.pack(short, content: [:]).words.count, declared - 10)
        let cut = Data([UInt8](makeCurrentProgram().serialized()).prefix(3000))
        XCTAssertThrowsError(try ProgramFile(data: cut)) { e in
            XCTAssertTrue("\(e)".contains("ends early"), "\(e)")
        }
    }
}

/// A program in the current layout (181/137/182, no events) whose header adds up.
func makeCurrentProgram(sources: [Int32] = Array(repeating: 42, count: 12)) -> ProgramFile {
    var v: [ProgramFile.Value] = [.int(181), .int(137), .int(182), .int(0)]
    v += Array(repeating: .int(0), count: 4 * 181)
    v += (0..<(4 * 137)).map { .float(Float($0 % 7) * 0.125) }
    v += Array(repeating: .int(0), count: 182)
    var p = ProgramFile(version: "W3_PROG_5", name: "Current", values: v)
    for (k, id) in sources.enumerated() { p.setSourceID(id, at: k) }
    return p
}

final class PackTests: XCTestCase {
    func testPackUnpackRoundTrip() throws {
        let pro = makeProgram(sources: [4010, 2043, 42, 4010, 2043, 43, 2, 35, 42, 41, 42, 42])
        let wt = WavetableFile(kind: .u, name: "SM OB2", values: (0..<131_072).map { Float($0 % 2048) / 2048 })
        let content: [SourceRef: SourceContent] = [.s(10): .multisample(makeMultisample()), .u(50): .wavetable(wt),
                                                   .p(2): .reference, .u(1): .reference]
        let g = try Packer.pack(pro, content: content)
        XCTAssertEqual(g.sources.map(\.ref), [.s(10), .u(50), .analog(1), .analog(4), .p(2), .u(1), .analog(0)])
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

    func testOS20FloatLayoutDetected() throws {
        // OS 2.0d writes 548 floats; in its exports the last 4 are 0. Both forms must come back as floats.
        let pro = makeProgram(sources: Array(repeating: 42, count: 12), floats: 548)
        XCTAssertEqual(Unpacker.unpack(try Packer.pack(pro, content: [:])).program.serialized(), pro.serialized())
        var zeros = pro
        for i in (4 * 181 + 4 + 544)..<(4 * 181 + 4 + 548) { zeros.values[i] = .float(0) }
        XCTAssertEqual(Unpacker.unpack(try Packer.pack(zeros, content: [:])).program.serialized(), zeros.serialized())
        // The 544 layout is still recognised: its integer tail follows directly.
        let older = makeProgram(sources: Array(repeating: 42, count: 12), floats: 544)
        XCTAssertEqual(Unpacker.unpack(try Packer.pack(older, content: [:])).program.serialized(), older.serialized())
    }

    func testHeaderGivesFloatCount() throws {
        // Lines 4–6 give floats per part, global values and event records. A 544-float program whose
        // globals start with four zeros would look like the 548 layout; the header settles it.
        var pro = makeProgram(sources: Array(repeating: 42, count: 12), floats: 544)
        let tail = 4 * 181 + 4 + 544
        for i in tail..<(tail + 4) { pro.values[i] = .int(0) }
        pro.values[1] = .int(136); pro.values[2] = .int(40); pro.values[3] = .int(0)
        XCTAssertEqual(Unpacker.unpack(try Packer.pack(pro, content: [:])).program.serialized(), pro.serialized())
    }

    func testTrailingBytesAfterTheProgramAreIgnored() throws {
        let g = try Packer.pack(makeCurrentProgram(), content: [:])
        var bytes = [UInt8](g.serialized())
        let clean = bytes.count
        bytes += [UInt8](repeating: 0xAB, count: 1_001)           // not even a whole number of words
        let parsed = try UnifiedProgram(data: Data(bytes))
        XCTAssertEqual(parsed.words, g.words)
        XCTAssertEqual(parsed.trailingBytes, 1_001)
        XCTAssertEqual(parsed.serialized().count, clean)
        XCTAssertTrue(Unpacker.unpack(parsed).notes.contains { $0.contains("1001 bytes after the end of the program") })
        // Without a plausible header, an odd length is still an error.
        XCTAssertThrowsError(try UnifiedProgram(data: Data([UInt8](g.serialized()).dropLast(3))))
    }

    func testOscillatorWordOutOfRangeDoesNotCrash() throws {
        var g = try Packer.pack(makeCurrentProgram(), content: [:])
        g.words[g.oscillatorWordIndices[0]] = 0xFFFF_FFFF
        g.words[g.oscillatorWordIndices[1]] = 0x8000_0000
        let up = Unpacker.unpack(try UnifiedProgram(data: g.serialized()))
        XCTAssertEqual(up.notes.filter { $0.contains("does not list") }.count, 2)
        XCTAssertEqual(up.program.sourceIDs[0], -1)
    }

    func testSampleIsNeverLeftOut() throws {
        let pro = makeProgram(sources: [4000] + Array(repeating: 42, count: 11))
        // The low-level packer can still list a sample without data (used only to make synth test files).
        let g = try Packer.pack(pro, content: [.s(0): .reference])
        XCTAssertFalse(g.sources[0].hasData)
        // The app's plan offers no way to leave it out, even when asked.
        let plan = PackPlan.make(program: pro, files: [], factory: FactoryLibrary())
        XCTAssertEqual(plan.verdict, .blocked([.s(0)]))
        XCTAssertFalse(plan.rows[0].options.contains(.reference))
        let forced = PackPlan.make(program: pro, files: [], factory: FactoryLibrary(),
                                   overrides: [.s(0): .reference])
        XCTAssertEqual(forced.verdict, .blocked([.s(0)]))
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
