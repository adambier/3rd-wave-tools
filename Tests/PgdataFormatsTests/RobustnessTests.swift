import XCTest
@testable import PgdataFormats

/// How the readers behave on damaged, truncated, empty, mistyped and hand-edited files: every
/// such file must produce a FormatError with a plain reason, never a crash or silently wrong output.
final class RobustnessTests: XCTestCase {
    private func error(_ body: () throws -> Any) -> String {
        do { _ = try body(); return "" } catch { return (error as? FormatError)?.description ?? "\(error)" }
    }

    // MARK: Empty, truncated and mistyped files

    func testEmptyAndTinyFiles() {
        XCTAssertEqual(error { try ProgramFile(data: Data()) }, "Not a 3rd Wave program (.pro) file: it is empty.")
        XCTAssertEqual(error { try WavetableFile(data: Data()) }, "Not a 3rd Wave wavetable (.wt) file: it is empty.")
        XCTAssertEqual(error { try UnifiedProgram(data: Data()) }, "The file is empty.")
        XCTAssertEqual(error { try Multisample(binData: Data()) }, "The file is empty.")
        XCTAssertTrue(error { try ProgramFile(data: Data("W3_PROG_5\nName\n".utf8)) }.contains("only 2 lines"))
        XCTAssertTrue(error { try UnifiedProgram(data: Data([UInt8](repeating: 0x41, count: 20))) }.hasPrefix("Not a 3rd Wave unified program (.pgdata) file: it begins with"))
    }

    func testCutShortFilesSayWhereTheyEnd() throws {
        let g = try Packer.pack(makeCurrentProgram(sources: [2049] + Array(repeating: 42, count: 11)),
                                content: [.u(56): .wavetable(WavetableFile(kind: .u, name: "T", values: Array(repeating: 0.5, count: 131_072)))])
        let whole = [UInt8](g.serialized())
        let cut = Data(whole.prefix(whole.count / 2))
        let msg = error { try UnifiedProgram(data: cut) }
        XCTAssertTrue(msg.hasPrefix("The file ends early: it is \(cut.count) bytes, but at least"), msg)
        XCTAssertTrue(msg.contains("cut short"), msg)
        // A .bin cut inside its audio.
        let bin = [UInt8](makeMultisample().binData())
        XCTAssertTrue(error { try Multisample(binData: Data(bin.dropLast(50))) }.hasPrefix("The file ends early"))
        // A .pgdata cut inside the program words (not a whole number of words, no plausible header).
        var short = whole
        short.removeLast(whole.count - (whole.count - g.words.count * 4 + 6))
        XCTAssertTrue(error { try UnifiedProgram(data: Data(short)) }.contains("not a whole number of values"))
    }

    func testWrongKindOfFile() throws {
        let pro = makeCurrentProgram().serialized()
        let wt = WavetableFile(kind: .p, name: "x", values: Array(repeating: 0, count: 16_384)).serialized()
        let bin = makeMultisample().binData()
        XCTAssertTrue(error { try WavetableFile(data: pro) }.hasPrefix("Not a 3rd Wave wavetable (.wt) file: it begins with \"W3_PROG_5\""))
        XCTAssertTrue(error { try ProgramFile(data: wt) }.hasPrefix("Not a 3rd Wave program (.pro) file: it begins with \"PNAME\""))
        XCTAssertTrue(error { try Multisample(binData: pro) }.hasPrefix("Not a 3rd Wave multisample (.bin) file"))
        XCTAssertTrue(error { try UnifiedProgram(data: bin) }.hasPrefix("Not a 3rd Wave unified program (.pgdata) file"))
        // A .wt named as a .bin (or the reverse) is refused when added as content.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgdata-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mislabelled = dir.appendingPathComponent("U50_x.bin")
        try wt.write(to: mislabelled)
        XCTAssertThrowsError(try ContentFile.load(mislabelled))
        let other = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: other)
        XCTAssertTrue(error { try ContentFile.load(other) }.contains("not a wavetable (.wt) or multisample (.bin)"))
    }

    // MARK: .wt

    func testWavetableTextForms() throws {
        // Comments, blank lines, the f suffix, CRLF, exponents: all as Groove Synthesis's factory files use them.
        var lines = ["PNAME", "Test Table", "// a comment", ""]
        lines += (0..<16_384).map { i -> String in
            switch i % 4 {
            case 0: return "0.963237f"
            case 1: return "1.38777878078e-17f"
            case 2: return "-0.5F"
            default: return "  0.25f  "
            }
        }
        let crlf = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        let w = try WavetableFile(data: crlf)
        XCTAssertEqual(w.kind, .p)
        XCTAssertEqual(w.name, "Test Table")
        XCTAssertEqual(w.values.count, 16_384)
        XCTAssertEqual(w.values[1], 1.38777878078e-17)
        XCTAssertEqual(w.values[2], -0.5)
        XCTAssertEqual(w.serialized(), crlf)              // unmodified: byte for byte
        // Rewritten from values, exact floats come back exactly, in six decimals where that suffices.
        var again = w; again.name = "Renamed"
        let text = String(decoding: again.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("PNAME\nRenamed\n0.963237f\n"))
        XCTAssertEqual(try WavetableFile(data: again.serialized()).values, w.values)
        // Wrong count and a non-number are refused with the line.
        XCTAssertTrue(error { try WavetableFile(data: Data("UNAME\nShort\n0.5f\n".utf8)) }.contains("has 1 values; a U table needs 131072"))
        XCTAssertTrue(error { try WavetableFile(data: Data("PNAME\nBad\n0.5f\nabc\n".utf8)) }.contains("Line 4 of wavetable \"Bad\" is not a number"))
    }

    // MARK: .bin

    func testOlderMultisampleVersionsAndErrors() throws {
        // A version 4 file: as v5 without the volume. Built by hand from the v5 body.
        let m = makeMultisample()
        var w = ByteWriter()
        w.put(NameField("W3_MSAMPLE_4", width: 16).raw)
        w.u8(1); w.put(m.slotName.raw)
        let s = m.samples[0]
        w.u32(s.length); w.f32(s.sampleRate); w.u8(s.bitDepth); w.put(s.name.raw)
        w.u32(s.start); w.u32(s.end); w.u32(s.loopStart); w.u32(s.loopEnd)
        w.u8(s.rootNote); w.u8(s.lowNote); w.u8(s.highNote); w.u8(s.loopMode)
        w.u32(s.crossfade); w.u8(s.crossfadeType); w.f32(s.pitch); w.f32(s.secondRate)
        w.put(s.audio)
        let v4 = try Multisample(binData: Data(w.bytes))
        XCTAssertEqual(v4.sourceVersion, 4)
        XCTAssertEqual(v4.samples[0].volume, 1)
        XCTAssertEqual(v4.samples[0].audio, s.audio)
        XCTAssertEqual(try Multisample(binData: v4.binData()).sourceVersion, 5)   // upgraded on write
        // Unknown version, trailing bytes.
        var v7 = [UInt8](m.binData()); v7[11] = UInt8(ascii: "7")
        XCTAssertTrue(error { try Multisample(binData: Data(v7)) }.contains("version 7 is not one this app knows"))
        XCTAssertTrue(error { try Multisample(binData: m.binData() + Data([1, 2, 3])) }.contains("3 unexpected bytes at the end"))
    }

    // MARK: .pgdata structure

    func testUnifiedProgramStructureErrors() throws {
        let g = try Packer.pack(makeCurrentProgram(sources: [2049, 41, 42] + Array(repeating: 42, count: 9)),
                                content: [.u(56): .wavetable(WavetableFile(kind: .u, name: "T", values: Array(repeating: 0.5, count: 131_072)))])
        let bytes = [UInt8](g.serialized())
        // Source table entry numbered wrongly.
        var b = bytes; b[17] = 9
        XCTAssertTrue(error { try UnifiedProgram(data: Data(b)) }.contains("Source table entry 0 is numbered 9"))
        // Type that does not match the id.
        b = bytes; b[18] = 2
        XCTAssertTrue(error { try UnifiedProgram(data: Data(b)) }.contains("has type 2 but id"))
        // An analog wave claiming to carry data: the record for source 1 (A00) follows the first
        // source's record (3 + 32 + 131,072 × 4 bytes).
        b = bytes
        let rec1 = 17 + 3 * 4 + 3 + 32 + 131_072 * 4
        XCTAssertEqual(b[rec1], 2)              // type analog
        b[rec1 + 2] = 1                          // has_data
        XCTAssertTrue(error { try UnifiedProgram(data: Data(b)) }.contains("claims to carry data"))
    }

    func testUnpackNotesForLayoutsItCannotConvert() throws {
        // 181 integers with 128 floats: a layout never seen, so no format can be inferred.
        func prog(_ s: Int, _ f: Int, _ g: Int) -> ProgramFile {
            var v: [ProgramFile.Value] = [.int(Int32(s)), .int(Int32(f)), .int(Int32(g)), .int(0)]
            v += Array(repeating: .int(42), count: 4 * s)
            v += Array(repeating: .float(0, text: "0.000000"), count: 4 * f)
            v += Array(repeating: .int(0), count: g)
            return ProgramFile(version: "W3_PROG_5", name: "x", values: v)
        }
        let odd = prog(177, 128, 100)
        let g = UnifiedProgram(sources: [.init(ref: .analog(1), payload: .none)], programName: NameField("x"),
                               words: odd.words.enumerated().map { i, w in odd.oscillatorIndices.contains(i) ? 0 : w })
        let up = Unpacker.unpack(g)
        XCTAssertTrue(up.notes.contains { $0.contains("layout (177/128/100) this app has not seen before") }, "\(up.notes)")
        XCTAssertEqual(up.program.values.count, odd.values.count)
        // A known old layout with a global count the converter refuses.
        let refused = prog(173, 126, 40)
        let g2 = UnifiedProgram(sources: [.init(ref: .analog(1), payload: .none)], programName: NameField("x"),
                                words: refused.words.enumerated().map { i, w in refused.oscillatorIndices.contains(i) ? 0 : w })
        XCTAssertTrue(Unpacker.unpack(g2).notes.contains { $0.contains("could not be converted") })
    }

    // MARK: Names and file names

    func testNamesOutsideLatin1AreFlagged() {
        XCTAssertEqual(NameField.unstorable(in: "Pad \u{2013} Wide \u{2018}A\u{2019}"), "\u{2013}\u{2018}\u{2019}")
        XCTAssertEqual(NameField.unstorable(in: "Plain-Name"), "")
        XCTAssertEqual(NameField.storedLength("e\u{301}"), 2)          // e + combining accent: two bytes
        XCTAssertEqual(NameField.storedLength("\u{E9}"), 1)            // é precomposed: one byte
        XCTAssertEqual(NameField("Pad \u{2013} Wide").text, "Pad ? Wide")
        var p = makeCurrentProgram(); p.name = "Pad \u{2013} Wide"
        let plan = PackPlan.make(program: p, files: [], factory: FactoryLibrary())
        XCTAssertTrue(plan.warnings.contains { $0.contains("cannot hold (\u{201C}\u{2013}\u{201D})") }, "\(plan.warnings)")
        p.name = String(repeating: "e\u{301}", count: 20)             // 20 characters, 40 bytes
        XCTAssertTrue(PackPlan.make(program: p, files: [], factory: FactoryLibrary()).warnings.contains { $0.contains("is 40 characters") })
    }

    func testImplausibleContentIsFlagged() throws {
        // A wavetable whose values exceed ±1: the 3rd Wave's own never do.
        var vals = Array(repeating: Float(0.25), count: 131_072); vals[100] = 3.5
        let loud = WavetableFile(kind: .u, name: "Loud", values: vals)
        XCTAssertEqual(loud.peak, 3.5)
        let f = ContentFile(url: URL(fileURLWithPath: "/x/U56_Loud.wt"), body: .wavetable(loud), slot: .u(56))
        XCTAssertEqual(f.problems.count, 1)
        let plan = PackPlan.make(program: makeCurrentProgram(sources: [2049] + Array(repeating: 42, count: 11)), files: [f], factory: FactoryLibrary())
        XCTAssertTrue(plan.warnings.contains { $0.contains("U56_Loud.wt: its samples reach ±3.50") }, "\(plan.warnings)")
        // A P table's differences may reach ±2 (a square wave's edges): only its samples count.
        var pv = [Float](repeating: 0, count: 16_384)
        for i in stride(from: 0, to: 256, by: 2) { pv[i] = i < 128 ? 1 : -1; pv[i + 1] = i == 126 ? -2 : (i == 254 ? 2 : 0) }
        let square = WavetableFile(kind: .p, name: "Square", values: pv)
        XCTAssertEqual(square.peak, 1)
        XCTAssertTrue(ContentFile(url: URL(fileURLWithPath: "/x/P40_Square.wt"), body: .wavetable(square), slot: .p(40)).problems.isEmpty)
        // Not-a-number lines are refused outright.
        XCTAssertThrowsError(try WavetableFile(data: Data(("UNAME\nBad\n" + String(repeating: "0.5f\n", count: 131_071) + "inf\n").utf8)))
        // A multisample out of key order, with codes outside the specification's ranges.
        var m = makeMultisample()
        var second = m.samples[0]; second.rootNote = 36; second.lowNote = 24; second.highNote = 47; second.loopMode = 7; second.bitDepth = 3
        m.samples.append(second)
        let problems = m.problems
        XCTAssertTrue(problems.contains { $0.contains("not in increasing order") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("sample 2 has bit depth code 3") })
        XCTAssertTrue(problems.contains { $0.contains("sample 2 has loop mode 7") })
        XCTAssertTrue(makeMultisample().problems.isEmpty)
        // The unpack plan carries the same notes in its descriptions.
        let g = try Packer.pack(makeCurrentProgram(sources: [2049, 4000, 42] + Array(repeating: 42, count: 9)),
                                content: [.u(56): .wavetable(loud), .s(0): .multisample(m)])
        let up = UnpackPlan.make(g, factory: FactoryLibrary(), skipFactoryDuplicates: true)
        XCTAssertTrue(up.items[1].description.contains("samples reach ±3.50"), up.items[1].description)
        XCTAssertTrue(up.items[2].description.contains("not in increasing order"), up.items[2].description)
    }

    func testFileNamesSafeForTheDrive() {
        XCTAssertEqual(OutputNames.sanitize("What? * \"Quoted\" <a|b>: c/d\\e."), "What_ _ _Quoted_ _a_b__ c_d_e")
        XCTAssertEqual(OutputNames.sanitize("  ..  "), "Untitled")
        XCTAssertEqual(OutputNames.sanitize("Warm Pad"), "Warm Pad")
        XCTAssertEqual(OutputNames.sanitize("tab\there"), "tab_here")
    }

    func testUnpackPlanRefreshKeepsEdits() throws {
        let factoryTable = WavetableFile(kind: .u, name: "F", values: (0..<131_072).map { Float($0 % 97) / 97 })
        let factory = FactoryLibrary([.u(7): .init(name: "Factory Seven", fingerprint: factoryTable.fingerprint)])
        let own = WavetableFile(kind: .u, name: "Own", values: Array(repeating: 0.25, count: 131_072))
        let g = try Packer.pack(makeCurrentProgram(sources: [2000, 2049, 42] + Array(repeating: 42, count: 9)),
                                content: [.u(7): .wavetable(factoryTable), .u(56): .wavetable(own)])
        var plan = UnpackPlan.make(g, factory: factory, skipFactoryDuplicates: true)
        XCTAssertEqual(plan.items.map(\.write), [true, false, true])
        XCTAssertTrue(plan.items[1].description.contains("identical to the factory table"))
        plan.items[2].fileName = "My Own.wt"; plan.items[2].write = false
        let refreshed = plan.refreshed(factory: factory, skipFactoryDuplicates: false)
        XCTAssertEqual(refreshed.items.map(\.write), [true, true, false])      // the duplicate follows the setting; edits stay
        XCTAssertEqual(refreshed.items[2].fileName, "My Own.wt")
        XCTAssertEqual(refreshed.items[2].defaultFileName, "U56_Own.wt")
        XCTAssertEqual(refreshed.items[0].defaultFileName, "Current.pro")
    }
}
