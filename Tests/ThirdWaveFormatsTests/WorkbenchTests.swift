import XCTest
@testable import ThirdWaveFormats

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

    func testFactoryLibraryReadsGrooveNames() throws {
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
        XCTAssertEqual(plan.verdict, .plainProgramEnough)
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
        XCTAssertEqual(plan.verdict, .needsUnifiedFile)
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
        XCTAssertEqual(p2.verdict, .needsUnifiedFile)
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
        XCTAssertEqual(plan.verdict, .needsUnifiedFile)
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
