import XCTest
@testable import PgdataFormats

/// `WavetableFile`'s wave-level view: building a table from its waves, and reading them back.
final class WavetableFramesTests: XCTestCase {
    private func waves(_ size: Int) -> [[Float]] {
        (0..<64).map { f in (0..<size).map { i in Float(sin(2 * Double.pi * Double(i) / Double(size))) * Float(f + 1) / 64 } }
    }

    /// What the 3rd Wave gives back from Export Wavetable: every value rounded to six decimals.
    private func sixDecimalCopy(_ file: WavetableFile) throws -> WavetableFile {
        var text = file.kind.rawValue + "\n" + file.name + "\n"
        for v in file.values { text += String(format: "%.6ff\n", v) }
        return try WavetableFile(data: Data(text.utf8))
    }

    func testCompareWithinTheExportTolerance() throws {
        let chain = (0..<65_536).map { Float($0 % 97) / 97 - 0.5 }
        let u = try WavetableFile(kind: .u, name: "U", frames: waves(1024), mipmapChain: chain)
        let back = try sixDecimalCopy(u)
        let frames = WavetableFile.compare(u.frames.flatMap { $0 }, back.frames.flatMap { $0 })
        XCTAssertEqual(frames.differing, 0)
        XCTAssertFalse(frames.exact)
        XCTAssertLessThanOrEqual(frames.largest, WavetableFile.exportTolerance)
        let chainBack = WavetableFile.compare(u.mipmapChain ?? [], back.mipmapChain ?? [])
        XCTAssertEqual(chainBack.differing, 0)
        // A P table's values are the samples and the differences; both come back within tolerance.
        let p = try WavetableFile(kind: .p, name: "P", frames: waves(128))
        XCTAssertEqual(WavetableFile.compare(p.values, try sixDecimalCopy(p).values).differing, 0)
        // Exact equality is reported, and a real change is counted.
        XCTAssertTrue(WavetableFile.compare(u.values, u.values).exact)
        let half = try WavetableFile(kind: .u, name: "U", frames: waves(1024).map { $0.map { $0 / 2 } }, mipmapChain: chain)
        let d = WavetableFile.compare(u.frames.flatMap { $0 }, half.frames.flatMap { $0 })
        XCTAssertGreaterThan(d.differing, 60_000)
        XCTAssertGreaterThan(d.largest, 0.4)
        // A length difference counts as that many positions.
        XCTAssertEqual(WavetableFile.compare([1, 2, 3], [1, 2]).differing, 1)
    }

    func testPTableStoresDifferencesAndGivesItsWavesBack() throws {
        let w = waves(128)
        let p = try WavetableFile(kind: .p, name: "P", frames: w)
        XCTAssertEqual(p.values.count, 16_384)
        XCTAssertEqual(p.values[0], w[0][0])
        XCTAssertEqual(p.values[1], w[0][1] - w[0][0])
        XCTAssertEqual(p.values[255], w[0][0] - w[0][127])   // the last difference wraps to the wave's start
        XCTAssertEqual(p.frames, w)
        XCTAssertNil(p.mipmapChain)
        // Round trip through the text form.
        XCTAssertEqual(try WavetableFile(data: p.serialized()).frames, w)
    }

    func testUTableCarriesItsChain() throws {
        let w = waves(1024)
        let chain = [Float](repeating: 0.25, count: 65_536)
        let u = try WavetableFile(kind: .u, name: "U", frames: w, mipmapChain: chain)
        XCTAssertEqual(u.values.count, 131_072)
        XCTAssertEqual(u.frames, w)
        XCTAssertEqual(u.mipmapChain, chain)
    }

    func testWrongShapesAreRefused() {
        XCTAssertThrowsError(try WavetableFile(kind: .p, name: "", frames: waves(1024)))
        XCTAssertThrowsError(try WavetableFile(kind: .p, name: "", frames: Array(waves(128).prefix(60))))
        XCTAssertThrowsError(try WavetableFile(kind: .u, name: "", frames: waves(1024)))                       // no chain
        XCTAssertThrowsError(try WavetableFile(kind: .u, name: "", frames: waves(1024), mipmapChain: [0]))
        XCTAssertThrowsError(try WavetableFile(kind: .p, name: "", frames: waves(128), mipmapChain: []))       // P has none
        var bad = waves(128); bad[3][7] = .nan
        XCTAssertThrowsError(try WavetableFile(kind: .p, name: "", frames: bad))
    }

    func testEmbeddedBytesMatchDataBytes() throws {
        let p = try WavetableFile(kind: .p, name: "P", frames: waves(128))
        let again = WavetableFile(kind: .p, name: "P", dataBytes: p.dataBytes)
        XCTAssertEqual(again.values, p.values)
        XCTAssertEqual(again.fingerprint, p.fingerprint)
    }
}
