import XCTest
@testable import PgdataFormats

/// Groove Synthesis's factory tables: read from their download folders, and the list built in.
final class FactoryLibraryTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw3fl-\(UUID().uuidString)")
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
        XCTAssertFalse(lib.isComplete)
        // One parent folder holding both downloads as subfolders is enough.
        let parent = dir.appendingPathComponent("parent"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f, to: parent.appendingPathComponent("3rdWave56UWavetables"))
        XCTAssertEqual(Set(FactoryLibrary(folders: [parent]).tables.keys), [.u(0), .u(50), .p(2), .p(34)])
    }

    func testBuiltInFactoryListIsComplete() {
        let lib = FactoryLibrary.builtIn
        XCTAssertTrue(lib.isComplete)
        XCTAssertEqual(lib.tables.count, 92)
        XCTAssertEqual(lib.name(.u(0)), "Additive_Bell_17")
        XCTAssertEqual(lib.name(.u(48)), "FM_Crush")
        XCTAssertEqual(lib.slot(withFingerprint: 0x9D778BEF7D5E8992), .u(7))   // Knob Grotto 6
        XCTAssertEqual(Set(lib.tables.values.map(\.fingerprint)).count, 92)  // no two factory tables alike
    }
}
