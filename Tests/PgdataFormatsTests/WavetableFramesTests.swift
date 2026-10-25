import XCTest
@testable import PgdataFormats

/// `WavetableFile`'s wave-level view: building a table from its waves, and reading them back.
final class WavetableFramesTests: XCTestCase {
    private func waves(_ size: Int) -> [[Float]] {
        (0..<64).map { f in (0..<size).map { i in Float(sin(2 * Double.pi * Double(i) / Double(size))) * Float(f + 1) / 64 } }
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
