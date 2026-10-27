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

    /// Section 5.1 of FORMATS.md: the 3rd Wave has been observed to read a value line longer than
    /// 31 characters as two values. The reader reports such lines; the writer never makes one.
    func testLongValueLinesAreReportedAndNeverWritten() throws {
        let huge = "-261953457593075210649600.0000000000000f"   // 40 characters, as a tool wrote it
        var lines = ["PNAME", "Long Lines", "// comment lines do not count, however long they are: " + huge]
        lines += (0..<16_384).map { $0 == 10 || $0 == 4_000 ? huge : "0.25f" }
        let w = try WavetableFile(data: Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(w.longLines, [14, 4_004])                 // file line numbers, counting from 1
        XCTAssertEqual(w.values[10], -2.6195346e+23)             // read correctly here all the same
        XCTAssertEqual(w.serialized(), Data((lines.joined(separator: "\n") + "\n").utf8))   // unmodified
        // A line of exactly 31 characters is within the limit; CRLF endings do not count.
        let edge = "-26195345759307521064960.00000f"
        XCTAssertEqual(edge.count, 31)
        let crlf = (["PNAME", "Edge"] + (0..<16_384).map { $0 == 0 ? edge : "0.25f" }).joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(try WavetableFile(data: Data(crlf.utf8)).longLines, [])
        // Rewritten, the out-of-range value takes its short exponent form, and renaming clears the list.
        var again = w; again.name = "Renamed"
        XCTAssertEqual(again.longLines, [])
        let text = String(decoding: again.serialized(), as: UTF8.self)
        XCTAssertTrue(text.split(separator: "\n").allSatisfy { $0.count <= WavetableFile.lineLimit }, "a written line exceeds 31 characters")
        XCTAssertEqual(try WavetableFile(data: again.serialized()).values, w.values)
        XCTAssertEqual(WavetableFile.literal(-2.6195346e+23), "-2.6195346e+23")
        XCTAssertEqual(WavetableFile.literal(0.963237), "0.963237")
        XCTAssertEqual(WavetableFile(kind: .p, name: "Made", values: [1]).longLines, [])
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
        XCTAssertTrue(error { try Multisample(binData: Data(v7)) }.contains("version 7 is not supported"))
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

    func testCorruptUnifiedProgramIsRejectedNotCrashed() throws {
        let pro = makeProgram(sources: [34] + Array(repeating: 42, count: 11))
        var g = try Packer.pack(pro, content: [.u(0): .reference])
        var d = g.serialized()
        // Patch the first program word (values per part) to -200.
        let start = d.count - 4 * g.words.count
        d.replaceSubrange(start..<start + 4, with: [0x38, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try UnifiedProgram(data: d))
        // An oscillator index the file does not list: unpacks with a note, no crash.
        g = try Packer.pack(pro, content: [.u(0): .reference])
        let osc = g.oscillatorWordIndices[0]
        var words = g.words; words[osc] = 7
        d = g.serialized()
        let s2 = d.count - 4 * g.words.count + 4 * osc
        d.replaceSubrange(s2..<s2 + 4, with: [7, 0, 0, 0])
        let u = try UnifiedProgram(data: d)
        XCTAssertNil(u.oscillatorSources[0])
        let up = Unpacker.unpack(u)
        XCTAssertEqual(up.program.sources[0], .p(7))
        XCTAssertTrue(up.notes.contains { $0.contains("reads as P07") })
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
        XCTAssertTrue(up.notes.contains { $0.contains("layout (177/128/100) not seen before") }, "\(up.notes)")
        XCTAssertEqual(up.program.values.count, odd.values.count)
        // A known old layout with a global count the converter refuses.
        let refused = prog(173, 126, 40)
        let g2 = UnifiedProgram(sources: [.init(ref: .analog(1), payload: .none)], programName: NameField("x"),
                                words: refused.words.enumerated().map { i, w in refused.oscillatorIndices.contains(i) ? 0 : w })
        XCTAssertTrue(Unpacker.unpack(g2).notes.contains { $0.contains("could not be converted") })
    }
}
