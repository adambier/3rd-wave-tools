import XCTest
@testable import PgdataFormats
@testable import PgdataPackerCore

final class WorkbenchTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw3wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a .wt whose values are a ramp scaled by `seed` (so tables with different seeds have
    /// different content and fingerprints), and returns its URL.
    func writeWT(_ name: String, kind: WavetableFile.Kind, seed: Float, file: String) throws -> URL {
        let u = dir.appendingPathComponent(file); try Self.wtData(name: name, kind: kind, seed: seed).write(to: u); return u
    }

    /// The bytes `WavetableFile(kind:name:values:).serialized()` gives for a `writeWT` table: the
    /// header, then the value lines, which are kept per kind and seed because serializing a
    /// U table's 131,072 values is the slow part of these tests and the same tables recur.
    private static var valueLines: [String: Data] = [:]
    static func wtData(name: String, kind: WavetableFile.Kind, seed: Float) -> Data {
        let key = "\(kind.rawValue) \(seed)"
        let lines: Data
        if let cached = valueLines[key] {
            lines = cached
        } else {
            let header = Data((kind.rawValue + "\n\n").utf8)
            lines = WavetableFile(kind: kind, name: "", values: rampValues(kind: kind, seed: seed)).serialized().dropFirst(header.count)
            valueLines[key] = lines
        }
        return Data((kind.rawValue + "\n" + name + "\n").utf8) + lines
    }

    /// The values of a `writeWT` table.
    static func rampValues(kind: WavetableFile.Kind, seed: Float) -> [Float] {
        (0..<kind.valueCount).map { Float($0 % 97) * seed / 97 }
    }

    /// A U table named "NOSTALGIA" whose content does not matter, serialized once.
    static let nostalgia: Data = WavetableFile(kind: .u, name: "NOSTALGIA", values: Array(repeating: 0.25, count: 131_072)).serialized()

    func testFactoryOnlyProgramNeedsNoUnifiedFile() {
        let pro = makeProgram(sources: [34, 2000, 1000, 41, 42, 42, 2, 35, 42, 41, 42, 42])
        let plan = PackPlan.make(program: pro, files: [], factory: FactoryLibrary())
        XCTAssertEqual(plan.verdict, .factoryOnly)
        XCTAssertTrue(plan.rows.allSatisfy { $0.choice == .reference || $0.choice == .builtIn })
    }

    func testSampleWithoutFileBlocks() {
        let pro = makeProgram(sources: [4010] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], factory: FactoryLibrary())
        XCTAssertEqual(plan.verdict, .blocked([.s(10)]))
    }

    func testSurgeWavetableIsSentToConvert() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("surge-\(UUID().uuidString).wt")
        try Data("vawt".utf8 + [0, 8, 0, 0, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 2048 * 4)).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertThrowsError(try ContentFile.load(u)) { e in
            XCTAssertTrue("\(e)".contains("Surge wavetable"), "\(e)")
            XCTAssertTrue("\(e)".contains("Wavetables page"), "\(e)")
        }
    }

    func testSuppliedFileWinsAndIsSuggestedFromName() throws {
        // Scott McAuley's case: his program uses U50, his file is named "U50 SM OB2.WT".
        let u = try writeWT("U50 SM OB2", kind: .u, seed: 0.7, file: "U50 SM OB2.WT")
        let cf = try ContentFile.load(u)
        XCTAssertEqual(cf.slot, .u(50))
        let pro = makeProgram(sources: [2043, 2043, 42] + Array(repeating: 42, count: 9), version: "W3_PROG_4", floats: 520)
        let plan = PackPlan.make(program: pro, files: [cf], factory: FactoryLibrary())
        XCTAssertEqual(plan.rows.first?.choice, .file(cf.id))
        XCTAssertEqual(plan.verdict, .embedsContent)
        let g = try Packer.pack(pro, content: plan.content(files: [cf]))
        XCTAssertTrue(g.sources[0].hasData)
    }

    func testFactoryTablesAreListedNeverEmbedded() throws {
        // Factory U50 "Dub Grind".
        let f = dir.appendingPathComponent("factory"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let save = dir; dir = f
        let dub = try ContentFile.load(try writeWT("Dub Grind", kind: .u, seed: 0.2, file: "50_Dub_Grind.wt"))
        dir = save
        let lib = FactoryLibrary(folders: [f])
        let pro = makeProgram(sources: [2043] + Array(repeating: 42, count: 11))
        let oldPro = makeProgram(sources: [2043] + Array(repeating: 42, count: 11), version: "W3_PROG_4", floats: 520)

        let plain = PackPlan.make(program: pro, files: [], factory: lib)
        XCTAssertEqual(plain.rows[0].choice, .reference)
        XCTAssertEqual(plain.rows[0].options, [.reference])
        XCTAssertEqual(plain.verdict, .factoryOnly)
        XCTAssertEqual(plain.rows[0].status, .ok("Factory \u{201C}Dub Grind\u{201D}; not embedded"))

        // The factory table itself, added (e.g. unpacked from the synth's own export): still listed only.
        var same = dub; same.slot = .u(50)
        let copy = PackPlan.make(program: pro, files: [same], factory: lib)
        XCTAssertEqual(copy.rows[0].choice, .reference)
        XCTAssertEqual(copy.rows[0].options, [.reference])
        XCTAssertEqual(copy.verdict, .factoryOnly)

        // A different table for U50 in an older program (Dynamica's SM OB2): embedded, as its author meant.
        var ob2 = try ContentFile.load(try writeWT("SM OB2", kind: .u, seed: 0.7, file: "SM OB2.wt")); ob2.slot = .u(50)
        let p2 = PackPlan.make(program: oldPro, files: [ob2], factory: lib)
        XCTAssertEqual(p2.rows[0].choice, .file(ob2.id))
        XCTAssertEqual(p2.rows[0].options, [.file(ob2.id), .reference])
        XCTAssertTrue(p2.rows[0].mayNeedSlot)
        guard case .wavetable(let w)? = p2.content(files: [ob2])[.u(50)] else { return XCTFail() }
        XCTAssertEqual(w.name, "SM OB2")
    }

    func testOldProgramTreatsU48ToU55AsUserSlots() throws {
        // Dynamica Vol. 2: W3_PROG_4, U48 meant Scott McAuley's SM OBX8 1, not factory FM_Crush.
        let lib = FactoryLibrary([.u(48): .init(name: "FM_Crush", fingerprint: 1), .u(7): .init(name: "Knob Grotto 6", fingerprint: 2)])
        let old = makeProgram(sources: [2041, 2000, 42] + Array(repeating: 42, count: 9), version: "W3_PROG_4", floats: 520)
        let plan = PackPlan.make(program: old, files: [], factory: lib)
        let u48 = plan.rows.first { $0.ref == .u(48) }!
        XCTAssertNil(u48.choice)
        XCTAssertEqual(u48.options, [.reference])          // the factory table, only if chosen
        guard case .missing(let why) = u48.status else { return XCTFail() }
        XCTAssertTrue(why.hasPrefix("Probably the author’s own wavetable"))
        XCTAssertTrue(u48.wasUserSlot)
        let note = try XCTUnwrap(plan.userSlotNote)
        XCTAssertEqual(note.title, "U48 probably held the author’s own wavetable, which is not included")
        XCTAssertTrue(note.body.contains("it is in the W3_PROG_4 format, older than the W3_PROG_5"))
        XCTAssertTrue(note.body.contains("U48 \u{201C}FM_Crush\u{201D}"))
        XCTAssertEqual(plan.missingSummary, "needs U48: probably the author’s own wavetable from before 2025")
        XCTAssertEqual(plan.rows.first { $0.ref == .u(7) }!.choice, .reference)   // older factory slots unaffected
        XCTAssertEqual(plan.verdict, .blocked([.u(48)]))

        // Scott's file added: embedded.
        var obx = try ContentFile.load(try writeWT("SM OBX8 1", kind: .u, seed: 0.3, file: "U48 SM OBX8 1.WT"))
        XCTAssertEqual(obx.slot, .u(48))
        let withFile = PackPlan.make(program: old, files: [obx], factory: lib)
        XCTAssertEqual(withFile.rows.first { $0.ref == .u(48) }!.choice, .file(obx.id))
        XCTAssertEqual(withFile.verdict, .embedsContent)

        // Choosing the factory table anyway is allowed.
        let forced = PackPlan.make(program: old, files: [], factory: lib, overrides: [.u(48): .reference])
        XCTAssertEqual(forced.verdict, .factoryOnly)

        XCTAssertNil(withFile.userSlotNote)
        XCTAssertNil(forced.userSlotNote)

        // An older v5 (520 floats, like Sam Gutman's) predates 2025 too; a 544-float v5 means the factory table.
        var oldV5 = old; oldV5.version = "W3_PROG_5"
        XCTAssertEqual(PackPlan.make(program: oldV5, files: [], factory: lib).verdict, .blocked([.u(48)]))
        let v5 = makeProgram(sources: [2041, 2000, 42] + Array(repeating: 42, count: 9), version: "W3_PROG_5", floats: 544)
        XCTAssertEqual(v5.floatBlockCount, 544)
        XCTAssertEqual(PackPlan.make(program: v5, files: [], factory: lib).verdict, .factoryOnly)

        // Two slots: one note naming both.
        let two = makeProgram(sources: [2041, 2043, 42] + Array(repeating: 42, count: 9), version: "W3_PROG_4", floats: 520)
        let lib3 = FactoryLibrary([.u(48): .init(name: "FM_Crush", fingerprint: 1), .u(50): .init(name: "Dub Grind", fingerprint: 3)])
        let p2 = PackPlan.make(program: two, files: [], factory: lib3)
        XCTAssertEqual(p2.userSlotNote?.title, "U48 and U50 probably held the author’s own wavetables, which are not included")
        XCTAssertEqual(p2.missingSummary, "needs U48, U50: probably the author’s own wavetables from before 2025")

        // An added file identical to the factory table: listed, not embedded.
        obx.slot = .u(48)
        let lib2 = FactoryLibrary([.u(48): .init(name: "FM_Crush", fingerprint: obx.fingerprint)])
        XCTAssertEqual(PackPlan.make(program: old, files: [obx], factory: lib2).rows[0].choice, .reference)
    }

    func testLongNamesAreWarnedAboutAndFactoryIdenticalFilesExplained() throws {
        let long = String(repeating: "x", count: 40)
        var pro = makeProgram(sources: [2050] + Array(repeating: 42, count: 11))
        pro.name = long
        var cf = try ContentFile.load(try writeWT("Breathy Vowels", kind: .u, seed: 0.5, file: "02.wt")); cf.slot = .u(57)
        let plan = PackPlan.make(program: pro, files: [cf], factory: FactoryLibrary(), names: [cf.id: long])
        XCTAssertEqual(plan.warnings.count, 2)
        XCTAssertTrue(plan.warnings[0].contains("program name is 40 characters"))
        XCTAssertTrue(plan.warnings[1].contains("02.wt"))
        guard case .ok(let st) = plan.rows[0].status else { return XCTFail() }
        XCTAssertTrue(st.contains(long))                        // status shows the packed name
        // Two user slots fed the same content need one free slot, not two.
        let two = makeProgram(sources: [2049, 2050] + Array(repeating: 42, count: 10))
        var cf2 = cf; cf2.slot = .u(56)
        let p2 = PackPlan.make(program: two, files: [cf, cf2], factory: FactoryLibrary())
        XCTAssertEqual(p2.slotsNeeded.u, 1)
        // A file that is its slot's factory table: explained, not "another choice".
        let lib = FactoryLibrary([.u(7): .init(name: "Knob Grotto 6", fingerprint: cf.fingerprint)])
        var fac = cf; fac.slot = .u(7)
        let p3 = PackPlan.make(program: makeProgram(sources: [2000] + Array(repeating: 42, count: 11)), files: [fac], factory: lib)
        XCTAssertEqual(PackPlan.unusedFiles([fac], plans: [p3], factory: lib)[fac.id], "Identical to factory U07; the 3rd Wave’s own copy is used, so it is not embedded")
        XCTAssertTrue(p3.content(files: []).isEmpty || p3.content(files: [])[.u(7)] == .reference)   // no crash without the file
    }

    func testOlderSetsTableIsNotAppliedToCurrentPrograms() throws {
        // An older set's U48 table loaded beside a current (544-float) program that uses factory U48.
        let lib = FactoryLibrary([.u(48): .init(name: "FM_Crush", fingerprint: 1), .u(10): .init(name: "MultiWave96k", fingerprint: 2)])
        let obx = try ContentFile.load(try writeWT("SM OBX8 1", kind: .u, seed: 0.3, file: "U48 SM OBX8 1.WT"))
        let current = makeProgram(sources: [2041] + Array(repeating: 42, count: 11), version: "W3_PROG_5", floats: 544)
        let plan = PackPlan.make(program: current, files: [obx], factory: lib)
        XCTAssertEqual(plan.rows[0].choice, .reference)                 // keeps factory FM_Crush
        XCTAssertEqual(plan.rows[0].options, [.file(obx.id), .reference]) // the file can still be chosen
        XCTAssertEqual(plan.rows[0].heldBack, [obx.id])
        XCTAssertTrue(PackPlan.unusedFiles([obx], plans: [plan], factory: lib)[obx.id]!.contains("from after it became a factory slot"))
        // The older program in the same session uses the file.
        let old = makeProgram(sources: [2041] + Array(repeating: 42, count: 11), version: "W3_PROG_4", floats: 520)
        let p2 = PackPlan.make(program: old, files: [obx], factory: lib)
        XCTAssertEqual(p2.rows[0].choice, .file(obx.id))
        XCTAssertFalse(p2.rows[0].replacesFactory)                      // expected here: no warning
        XCTAssertNil(PackPlan.unusedFiles([obx], plans: [plan, p2], factory: lib)[obx.id])
        // Another factory slot: the added file is used, with a warning that it replaces the factory table.
        var other = try ContentFile.load(try writeWT("My Table", kind: .u, seed: 0.9, file: "mine.wt")); other.slot = .u(10)
        let p3 = PackPlan.make(program: makeProgram(sources: [2003] + Array(repeating: 42, count: 11)), files: [other], factory: lib)
        XCTAssertEqual(p3.rows[0].choice, .file(other.id))
        guard case .warning(let w) = p3.rows[0].status else { return XCTFail() }
        XCTAssertTrue(w.contains("in place of factory \u{201C}MultiWave96k\u{201D}"))
        XCTAssertTrue(p3.rows[0].replacesFactory)
    }

    func testUnfamiliarLayoutAndUnknownSourcesAreFlagged() {
        let ok = makeProgram(sources: Array(repeating: 42, count: 12))
        XCTAssertNil(ok.layoutWarning)
        XCTAssertTrue(PackPlan.make(program: ok, files: [], factory: FactoryLibrary()).warnings.isEmpty)

        // W3_PROG_2: written (a warning, not a block), and treated as pre-2025 like v3/v4.
        let v2 = makeProgram(sources: [2041] + Array(repeating: 42, count: 11), version: "W3_PROG_2")
        XCTAssertNotNil(v2.layoutWarning)
        XCTAssertTrue(PackPlan.predates2025FactoryTables(v2))
        let plan = PackPlan.make(program: v2, files: [], factory: FactoryLibrary.builtIn)
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("W3_PROG_2"))
        XCTAssertEqual(plan.verdict, .blocked([.u(48)]))

        // A source number outside every known range: missing, with its own message.
        let odd = makeProgram(sources: [123] + Array(repeating: 42, count: 11))
        let p2 = PackPlan.make(program: odd, files: [], factory: FactoryLibrary())
        XCTAssertEqual(p2.verdict, .blocked([.unknown(123)]))
        guard case .missing(let why) = p2.rows[0].status else { return XCTFail() }
        XCTAssertTrue(why.hasPrefix("Unknown source number 123"))
    }

    func testUserSlotTableMustBeAddedAndIsAlwaysEmbedded() throws {
        let u = try writeWT("Breathy Vowels", kind: .u, seed: 0.5, file: "02.wt")
        let pro = makeProgram(sources: [2050] + Array(repeating: 42, count: 11))
        let missing = PackPlan.make(program: pro, files: [], factory: FactoryLibrary())
        XCTAssertEqual(missing.verdict, .blocked([.u(57)]))
        XCTAssertTrue(missing.rows[0].options.isEmpty)          // no "leave it to the synth"
        var cf = try ContentFile.load(u); cf.slot = .u(57)
        let plan = PackPlan.make(program: pro, files: [cf], factory: FactoryLibrary())
        XCTAssertEqual(plan.rows.first?.choice, .file(cf.id))
        XCTAssertEqual(plan.rows.first?.options, [.file(cf.id)])
        XCTAssertEqual(plan.verdict, .embedsContent)
    }

    func testSampleWithoutAssignedFileBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("S010_Test.bin")
        try makeMultisample().binData().write(to: u)
        XCTAssertEqual(try ContentFile.load(u).slot, .s(10))
        let pro = makeProgram(sources: [4010] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], factory: FactoryLibrary())
        XCTAssertEqual(plan.verdict, .blocked([.s(10)]))
        XCTAssertFalse(plan.rows[0].options.contains(.reference))
    }

    func testRepointMovesOscillatorsAndEmbedsTheAssignedFile() throws {
        // Parts 3 and 4 hold U01 (as in Matt Johnson's NOSTALGIA RES); repoint part 3 osc 2 to U56.
        let pro = makeProgram(sources: [41, 42, 43, 41, 42, 43, 2, 35, 42, 2, 35, 42])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("01.wt")
        try Self.nostalgia.write(to: u)
        var cf = try ContentFile.load(u); cf.slot = .u(56)

        let before = PackPlan.make(program: pro, files: [cf], factory: FactoryLibrary())
        XCTAssertEqual(PackPlan.unusedFiles([cf], plans: [before])[cf.id], "Not used by any added program")
        XCTAssertEqual(PackPlan.unusedFiles([cf], plans: [before], programs: "packed")[cf.id], "Not used by any packed program")

        let moved = pro.repointed([7: .u(56)])
        XCTAssertEqual(moved.sources[7], .u(56))
        XCTAssertEqual(moved.sources[10], .u(1))          // part 4 osc 2 untouched
        let plan = PackPlan.make(program: moved, files: [cf], factory: FactoryLibrary(), original: pro)
        let row = plan.rows.first { $0.ref == .u(56) }!
        XCTAssertEqual(row.oscillators, [7])
        XCTAssertEqual(row.repointedFrom, [.u(1)])
        XCTAssertEqual(row.choice, .file(cf.id))
        XCTAssertEqual(plan.verdict, .embedsContent)
        XCTAssertTrue(PackPlan.unusedFiles([cf], plans: [plan]).isEmpty)
        // A table the synth isn't known to have needs a free slot on import...
        XCTAssertTrue(row.mayNeedSlot)
        XCTAssertEqual(plan.slotsNeeded.u, 1)
        // ...but not when it is a factory table (in any slot): the synth reuses it.
        let lib = FactoryLibrary([.u(50): .init(name: "NOSTALGIA", fingerprint: cf.fingerprint)])
        let reused = PackPlan.make(program: moved, files: [cf], factory: lib, original: pro)
        XCTAssertFalse(reused.rows.first { $0.ref == .u(56) }!.mayNeedSlot)
        XCTAssertEqual(reused.slotsNeeded.u, 0)

        var unassigned = cf; unassigned.slot = nil
        let p3 = PackPlan.make(program: moved, files: [unassigned], factory: FactoryLibrary(), original: pro)
        XCTAssertEqual(p3.verdict, .blocked([.u(56)]))
        XCTAssertEqual(PackPlan.unusedFiles([unassigned], plans: [p3])[cf.id], "Not used by any added program")
    }

    func testUnpackPlanNamesAndFactoryDuplicates() throws {
        let pro = makeProgram(sources: [4010, 2018, 42] + Array(repeating: 42, count: 9))
        let f = dir.appendingPathComponent("factory"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let wt = WavetableFile(kind: .u, name: "Science_Channel", values: Self.rampValues(kind: .u, seed: 0.5))
        try Self.wtData(name: "Science_Channel", kind: .u, seed: 0.5).write(to: f.appendingPathComponent("25-Science_Channel.wt"))
        let g = try Packer.pack(pro, content: [.s(10): .multisample(makeMultisample()), .u(25): .wavetable(wt)])
        let plan = UnpackPlan.make(g, factory: FactoryLibrary(folders: [f]), skipFactoryDuplicates: true)
        XCTAssertEqual(plan.items.map(\.fileName), ["Test Prog.pro", "U25_Science_Channel.wt", "S010_Test.bin"])
        XCTAssertEqual(plan.items.map(\.write), [true, false, true])
    }

    func testSanitize() {
        XCTAssertEqual(OutputNames.sanitize("A/B:C"), "A_B_C")
        XCTAssertEqual(OutputNames.sanitize("   "), "Untitled")
    }
}

final class NameCleanerTests: XCTestCase {
    func testProposals() {
        let c = NameCleaner()
        let cases: [(String, String)] = [
            ("U48 SM OBX8 1", "SM OBX8 1"),            // slot prefix; SM kept; digits kept
            ("S010_JP8_", "JP8"),
            ("BREATHY_VOWELS", "Breathy Vowels"),
            ("NOSTALGIA RES", "Nostalgia Res"),         // all caps: short words change too
            ("STREET DREAMS (PEDAL)", "Street Dreams (Pedal)"),
            ("DRUMS AND AMPS", "Drums and Amps"),
            ("DX-PPG KEYS", "DX-PPG Keys"),
            ("LO-FI PAD", "Lo-Fi Pad"),
            ("LOFI KEYS", "LoFi Keys"),                  // fixed spelling
            ("DUSTY (LOFI)", "Dusty (LoFi)"),
            ("PWM STRINGS", "PWM Strings"),              // no vowels: acronym
            ("ppg wave pad", "PPG Wave Pad"),
            ("SYNTH RHYTHM", "Synth Rhythm"),             // Y counts as a vowel
            ("SM PAD", "SM Pad"),
            ("Additive_Bell_17", "Additive Bell 17"),    // mixed case: only underscores change
            ("FIIx_Arr_Vocal", "FIIx Arr Vocal"),
            ("Tube Bell SM PAD", "Tube Bell SM PAD"),    // mixed case: all-caps words left alone
            ("ghibli bell", "Ghibli Bell"),
            ("B05P003 GHIBLI BELL", "Ghibli Bell"),
            ("B5-P003 GHIBLI BELL", "Ghibli Bell"),
            ("ARP SEQ LEAD", "Arp Seq Lead"),
            ("GHIBLI BELL U57", "Ghibli Bell"),
            ("U56", "U56"),                               // nothing left: keep
            ("U2 TRIBUTE", "U2 Tribute"),                 // one digit is not a slot
            ("  SPACED   OUT  ", "Spaced Out"),
        ]
        for (a, b) in cases { XCTAssertEqual(c.clean(a), b, a) }
    }

    func testRulesCanBeTurnedOff() {
        var c = NameCleaner(); c.titleCase = false
        XCTAssertEqual(c.clean("U48 SM OBX8 1"), "SM OBX8 1")
        XCTAssertEqual(c.clean("BREATHY_VOWELS"), "BREATHY VOWELS")
        c = NameCleaner(); c.stripSlots = false
        XCTAssertEqual(c.clean("U48 SM OBX8 1"), "U48 SM OBX8 1")
    }

    func testRenamedContentPacksUnderTheNewName() throws {
        let pro = makeProgram(sources: [2049] + Array(repeating: 42, count: 11))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("01.wt")
        try WorkbenchTests.nostalgia.write(to: u)
        var cf = try ContentFile.load(u); cf.slot = .u(56)
        var renamed = pro; renamed.name = "Nostalgia Res"
        let plan = PackPlan.make(program: renamed, files: [cf], factory: FactoryLibrary())
        let g = try Packer.pack(renamed, content: plan.content(files: [cf], names: [cf.id: "Nostalgia"]))
        let back = Unpacker.unpack(try UnifiedProgram(data: g.serialized()))
        XCTAssertEqual(back.program.name, "Nostalgia Res")
        XCTAssertEqual(back.wavetables.first?.file.name, "Nostalgia")
    }
}

final class OutputNameTests: XCTestCase {
    func testProgramLocations() {
        func loc(_ n: String) -> String? { OutputNames.programLocation(inFileName: n).map { "\($0.bank)/\($0.program)" } }
        XCTAssertEqual(loc("B05P003.pro"), "5/3")
        XCTAssertEqual(loc("B05P18_Transymba.pgdata"), "5/18")
        XCTAssertEqual(loc("B4-P100 Name.pro"), "4/100")
        XCTAssertEqual(loc("b1p059.PRO"), "1/59")
        XCTAssertNil(loc("ARP Restooth Arp.pro"))
        XCTAssertNil(loc("B06P003.pro"))       // banks are 1–5
        XCTAssertNil(loc("AB05P003.pro"))
    }

    func testPrefixesFollowGrooveSynthesisAndKeepListOrder() {
        XCTAssertEqual(OutputNames.orderPrefixes(fileNames: ["B05P003.pro", "B05P087.pro"]), ["B05P03", "B05P87"])
        // A program 100 in the batch: three digits for all, so P100 sorts last.
        XCTAssertEqual(OutputNames.orderPrefixes(fileNames: ["B05P011.pro", "B05P100.pro"]), ["B05P011", "B05P100"])
        XCTAssertEqual(OutputNames.orderPrefixes(fileNames: ["B05P003.pro", "Lead.pro", "Bass.pro"]), ["001", "002", "003"])
        // Groove Synthesis's older layout: "Bank 1/001.PRO".
        let urls = [URL(fileURLWithPath: "/x/Bank 1/001.PRO"), URL(fileURLWithPath: "/x/Bank 5/100.PRO"), URL(fileURLWithPath: "/x/B02P007.pro")]
        XCTAssertEqual(OutputNames.orderPrefixes(urls: urls), ["B01P001", "B05P100", "B02P007"])
        XCTAssertNil(OutputNames.programLocation(of: URL(fileURLWithPath: "/x/Sounds/001.PRO")))
        XCTAssertNil(OutputNames.programLocation(of: URL(fileURLWithPath: "/x/Bank 1/1001.PRO")))
        var p = makeProgram(sources: Array(repeating: 42, count: 12)); p.name = "Ghibli Bell"
        XCTAssertEqual(OutputNames.unified(p, prefix: "B05P87"), "B05P87_Ghibli_Bell.pgdata")
        XCTAssertEqual(OutputNames.unified(p), "Ghibli_Bell.pgdata")
        XCTAssertEqual(p.name, "Ghibli Bell")      // the name inside the file keeps its spaces
        // As the synth's own exports (hardware test T7): punctuation other than - and _ is dropped.
        XCTAssertEqual(OutputNames.exportName("SM Ripper Bass (MW)"), "SM_Ripper_Bass_MW")
        XCTAssertEqual(OutputNames.exportName("SM Cutting Bs&Ld"), "SM_Cutting_BsLd")
        XCTAssertEqual(OutputNames.exportName("SM LP-Notch Pad"), "SM_LP-Notch_Pad")
        XCTAssertEqual(OutputNames.exportName("SM Got 5 On it"), "SM_Got_5_On_it")
        XCTAssertEqual(OutputNames.exportName("SM Woody Pluck Seq  "), "SM_Woody_Pluck_Seq")
        XCTAssertEqual(OutputNames.exportName("Oboe & Flute"), "Oboe_Flute")
        XCTAssertEqual(OutputNames.exportName("(((  )))"), "Untitled")
    }
}
