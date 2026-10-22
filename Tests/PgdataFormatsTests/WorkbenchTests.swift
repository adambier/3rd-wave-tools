import XCTest
@testable import PgdataFormats

final class WorkbenchTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw3wb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func writeWT(_ name: String, kind: WavetableFile.Kind, seed: Float, file: String) throws -> URL {
        let w = WavetableFile(kind: kind, name: name, values: (0..<kind.valueCount).map { Float($0 % 97) * seed / 97 })
        let u = dir.appendingPathComponent(file); try w.serialized().write(to: u); return u
    }

    func testFactoryLibraryReadsGrooveSynthesisNames() throws {
        let f = dir.appendingPathComponent("factory"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let save = dir; dir = f
        _ = try writeWT("Additive_Bell_17", kind: .u, seed: 0.1, file: "00-Additive_Bell_17.wt")
        _ = try writeWT("Dub Grind", kind: .u, seed: 0.2, file: "50_Dub_Grind.wt")
        _ = try writeWT("Wavetable P02", kind: .p, seed: 0.3, file: "02P.wt")
        _ = try writeWT("VS00-63", kind: .p, seed: 0.4, file: "P34_VS_0-63.wt")
        dir = save
        let lib = FactoryLibrary(folders: [f])
        XCTAssertEqual(Set(lib.tables.keys), [.u(0), .u(50), .p(2), .p(34)])
        XCTAssertEqual(lib.name(.u(50)), "Dub Grind")
        XCTAssertTrue(lib.problems.isEmpty, "\(lib.problems)")
    }

    func testFactoryOnlyProgramNeedsNoUnifiedFile() {
        let pro = makeProgram(sources: [34, 2000, 1000, 41, 42, 42, 2, 35, 42, 41, 42, 42])
        let plan = PackPlan.make(program: pro, files: [], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.verdict, .factoryOnly)
        XCTAssertTrue(plan.rows.allSatisfy { $0.choice == .reference || $0.choice == .builtIn })
    }

    func testSampleWithoutFileBlocks() {
        let pro = makeProgram(sources: [4010] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.verdict, .blocked([.s(10)]))
    }

    func testSuppliedFileWinsAndIsSuggestedFromName() throws {
        // Scott McAuley's case: his program uses U50, his file is named "U50 SM OB2.WT".
        let u = try writeWT("U50 SM OB2", kind: .u, seed: 0.7, file: "U50 SM OB2.WT")
        let cf = try ContentFile.load(u)
        XCTAssertEqual(cf.slot, .u(50))
        let pro = makeProgram(sources: [2043, 2043, 42] + Array(repeating: 42, count: 9))
        let plan = PackPlan.make(program: pro, files: [cf], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.rows.first?.choice, .file(cf.id))
        XCTAssertEqual(plan.verdict, .embedsContent)
        let g = try Packer.pack(pro, content: try plan.content(files: [cf], profile: SlotProfile(), factory: FactoryLibrary()))
        XCTAssertTrue(g.sources[0].hasData)
    }

    func testProfileFlagsFactorySlotThatWasOverwritten() throws {
        // Adam's synth: U50 holds SM OB2, not factory Dub Grind.
        let u = try writeWT("SM OB2", kind: .u, seed: 0.7, file: "SM OB2.wt")
        var profile = SlotProfile()
        profile.assign(try ContentFile.load(u), to: .u(50))
        let pro = makeProgram(sources: [2043] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], profile: profile, factory: FactoryLibrary(), embedFactory: false)
        guard case .warning? = plan.rows.first?.status else { return XCTFail("expected a warning, got \(String(describing: plan.rows.first?.status))") }
        XCTAssertTrue(plan.rows[0].options.contains(.profile))
        // Choosing the synth's table embeds it.
        let p2 = PackPlan.make(program: pro, files: [], profile: profile, factory: FactoryLibrary(), embedFactory: false, overrides: [.u(50): .profile])
        XCTAssertEqual(p2.verdict, .embedsContent)
        let c = try p2.content(files: [], profile: profile, factory: FactoryLibrary())
        guard case .wavetable(let w)? = c[.u(50)] else { return XCTFail() }
        XCTAssertEqual(w.name, "SM OB2")
    }

    func testNonFactorySlotUsesProfileFile() throws {
        let u = try writeWT("Breathy Vowels", kind: .u, seed: 0.5, file: "02.wt")
        var profile = SlotProfile(); profile.assign(try ContentFile.load(u), to: .u(57))
        let pro = makeProgram(sources: [2050] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], profile: profile, factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.rows.first?.choice, .profile)
        XCTAssertEqual(plan.verdict, .embedsContent)
    }

    func testSampleSlotsAreNotTracked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("S010_Test.bin")
        try makeMultisample().binData().write(to: u)
        var profile = SlotProfile()
        profile.assign(try ContentFile.load(u), to: .s(10))
        XCTAssertTrue(profile.entries.isEmpty)
        // An old profile that still has an S entry is ignored.
        profile.entries["S10"] = SlotEntry(state: .file, name: "Test", path: u.path)
        XCTAssertEqual(profile.entry(.s(10)).state, .unknown)
        let pro = makeProgram(sources: [4010] + Array(repeating: 42, count: 11))
        let plan = PackPlan.make(program: pro, files: [], profile: profile, factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(plan.verdict, .blocked([.s(10)]))
        XCTAssertFalse(plan.rows[0].options.contains(.profile))
    }

    func testRepointMovesOscillatorsAndEmbedsTheAssignedFile() throws {
        // Parts 3 and 4 hold U01 (as in Matt Johnson's NOSTALGIA RES); repoint part 3 osc 2 to U56.
        let pro = makeProgram(sources: [41, 42, 43, 41, 42, 43, 2, 35, 42, 2, 35, 42])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("01.wt")
        try WavetableFile(kind: .u, name: "NOSTALGIA", values: Array(repeating: 0.25, count: 131_072)).serialized().write(to: u)
        var cf = try ContentFile.load(u); cf.slot = .u(56)

        let before = PackPlan.make(program: pro, files: [cf], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        XCTAssertEqual(PackPlan.unusedFiles([cf], plans: [before])[cf.id], "Not used by any program here")

        let moved = pro.repointed([7: .u(56)])
        XCTAssertEqual(moved.sources[7], .u(56))
        XCTAssertEqual(moved.sources[10], .u(1))          // part 4 osc 2 untouched
        let plan = PackPlan.make(program: moved, files: [cf], profile: SlotProfile(), factory: FactoryLibrary(),
                                 embedFactory: false, original: pro)
        let row = plan.rows.first { $0.ref == .u(56) }!
        XCTAssertEqual(row.oscillators, [7])
        XCTAssertEqual(row.repointedFrom, [.u(1)])
        XCTAssertEqual(row.choice, .file(cf.id))
        XCTAssertEqual(plan.verdict, .embedsContent)
        XCTAssertTrue(PackPlan.unusedFiles([cf], plans: [plan]).isEmpty)
        // A table the synth isn't known to have needs a free slot on import...
        XCTAssertTrue(row.mayNeedSlot)
        XCTAssertEqual(plan.slotsNeeded.u, 1)
        // ...but not once Synth Slots records the same content (in any slot): the synth reuses it.
        var prof = SlotProfile(); prof.assign(cf, to: .u(57))
        let reused = PackPlan.make(program: moved, files: [cf], profile: prof, factory: FactoryLibrary(),
                                   embedFactory: false, original: pro)
        XCTAssertFalse(reused.rows.first { $0.ref == .u(56) }!.mayNeedSlot)
        XCTAssertEqual(reused.slotsNeeded.u, 0)

        var unassigned = cf; unassigned.slot = nil
        let p3 = PackPlan.make(program: moved, files: [unassigned], profile: SlotProfile(), factory: FactoryLibrary(),
                               embedFactory: false, original: pro)
        XCTAssertEqual(p3.verdict, .blocked([.u(56)]))
        XCTAssertEqual(PackPlan.unusedFiles([unassigned], plans: [p3])[cf.id], "Not used by any program here")
    }

    func testProfileRoundTripsAsJSON() throws {
        var p = SlotProfile()
        p.set(.u(58), SlotEntry(state: .empty, name: "blank"))
        p.set(.u(1), SlotProfile.defaultEntry(.u(1)))   // default: not stored
        let again = try SlotProfile.decoded(p.encoded())
        XCTAssertEqual(again, p)
        XCTAssertEqual(again.entries.count, 1)
        XCTAssertEqual(again.entry(.u(3)).state, .factory)
        XCTAssertEqual(again.entry(.s(3)).state, .unknown)
    }

    func testUnpackPlanNamesAndFactoryDuplicates() throws {
        let pro = makeProgram(sources: [4010, 2018, 42] + Array(repeating: 42, count: 9))
        let f = dir.appendingPathComponent("factory"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let wt = WavetableFile(kind: .u, name: "Science_Channel", values: (0..<131_072).map { Float($0 % 50) / 50 })
        try wt.serialized().write(to: f.appendingPathComponent("25-Science_Channel.wt"))
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
        try WavetableFile(kind: .u, name: "NOSTALGIA", values: Array(repeating: 0.5, count: 131_072)).serialized().write(to: u)
        var cf = try ContentFile.load(u); cf.slot = .u(56)
        var renamed = pro; renamed.name = "Nostalgia Res"
        let plan = PackPlan.make(program: renamed, files: [cf], profile: SlotProfile(), factory: FactoryLibrary(), embedFactory: false)
        let g = try Packer.pack(renamed, content: plan.content(files: [cf], profile: SlotProfile(), factory: FactoryLibrary(),
                                                               names: [cf.id: "Nostalgia"]))
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
