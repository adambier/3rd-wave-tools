import XCTest
@testable import PgdataFormats
@testable import PgdataPackerCore

/// How `ContentFile` and the pack and unpack plans behave on mistyped, implausible, and
/// unstorable content: a plain reason or warning, never a crash. (The readers' own behavior on
/// damaged files is `RobustnessTests` in PgdataFormatsTests.)
final class PlanRobustnessTests: XCTestCase {
    private func error(_ body: () throws -> Any) -> String {
        do { _ = try body(); return "" } catch { return (error as? FormatError)?.description ?? "\(error)" }
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
        let mislabeled = dir.appendingPathComponent("U50_x.bin")
        try wt.write(to: mislabeled)
        XCTAssertThrowsError(try ContentFile.load(mislabeled))
        let other = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: other)
        XCTAssertTrue(error { try ContentFile.load(other) }.contains("not a wavetable (.wt) or multisample (.bin)"))
    }

    // MARK: Names and file names

    func testNamesOutsideLatin1AreFlagged() {
        XCTAssertEqual(NameField.fitted("Pad \u{2013} Wide \u{2018}A\u{2019}").changes,
                       [.replacedWithQuestionMark(characters: "\u{2013}\u{2018}\u{2019}")])
        XCTAssertEqual(NameField.fitted("Plain-Name").changes, [])
        XCTAssertEqual(NameField.fitted("e\u{301}").text.count, 1)     // e + combining accent: composed to é, one byte
        XCTAssertEqual(NameField("Cafe\u{301}").text, "Caf\u{E9}")    // as macOS file names store it
        XCTAssertEqual(NameField.fitted("\u{E9}").text.count, 1)       // é precomposed: one byte
        XCTAssertEqual(NameField("Pad \u{2013} Wide").text, "Pad ? Wide")
        XCTAssertEqual(NameField("Pad \u{150}").text, "Pad O")         // Ő: the accent goes, the letter stays
        var p = makeCurrentProgram(); p.name = "Pad \u{2013} Wide"
        let plan = PackPlan.make(program: p, files: [], factory: FactoryLibrary())
        XCTAssertTrue(plan.warnings.contains { $0.contains("cannot hold (\u{201C}\u{2013}\u{201D})") }, "\(plan.warnings)")
        p.name = String(repeating: "e\u{301}", count: 40)             // 40 characters once composed
        XCTAssertTrue(PackPlan.make(program: p, files: [], factory: FactoryLibrary()).warnings.contains { $0.contains("is 40 characters") })
        p.name = "Pad \u{150}"
        XCTAssertTrue(PackPlan.make(program: p, files: [], factory: FactoryLibrary()).warnings.contains { $0.contains("written without accents: \u{201C}\u{150}\u{201D} → \u{201C}O\u{201D}") })
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
