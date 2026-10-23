import XCTest
@testable import PgdataFormats

/// Synthetic programs exercising each conversion rule. The rules themselves were checked against
/// 299 bulk imports on an 8M with `tw3pg convertcheck` (the files are not in the repository).
final class ConverterTests: XCTestCase {
    /// A W3_PROG_3 program in the 173/126/73 layout with neutral values.
    func makeV3(events: [[Int32]] = [], configure: (inout [[Int32]], inout [[String]], inout [Int32]) -> Void = { _, _, _ in }) -> ProgramFile {
        var ints = Array(repeating: Array(repeating: Int32(0), count: 173), count: 4)
        var floats = Array(repeating: Array(repeating: "0.000000", count: 126), count: 4)
        var g = Array(repeating: Int32(0), count: 73)
        g[0] = 2; g[1] = 5; g[13] = 1; g[21] = 60; g[22] = 60; g[23] = 60
        g[24] = 1; g[25] = 2; g[26] = 4; g[27] = 8
        for k in 0..<4 { ints[k][0] = 15; ints[k][1] = 15; ints[k][2] = 15; floats[k][113] = "1.000000" }
        configure(&ints, &floats, &g)
        var v: [ProgramFile.Value] = [.int(173), .int(126), .int(73), .int(Int32(events.count))]
        for p in ints { v += p.map { .int($0) } }
        for p in floats { v += p.map { .float(Float($0)!, text: $0) } }
        v += g.map { .int($0) }
        for e in events { v += e.map { .int($0) } }
        return ProgramFile(version: "W3_PROG_3", name: "Test", values: v)
    }

    func ints(_ p: ProgramFile, part k: Int) -> [Int32] {
        p.values[(4 + 181 * k)..<(4 + 181 * (k + 1))].map { if case let .int(x, _) = $0 { return x }; return -1 }
    }
    func floats(_ p: ProgramFile, part k: Int) -> [String] {
        let s = 4 + 4 * 181 + 137 * k
        return p.values[s..<(s + 137)].map(\.text)
    }
    func globals(_ p: ProgramFile) -> [Int32] {
        let s = 4 + 4 * 181 + 4 * 137
        return p.values[s..<(s + 182)].map { if case let .int(x, _) = $0 { return x }; return -1 }
    }
    func events(_ p: ProgramFile) -> [[Int32]] {
        let s = 4 + 4 * 181 + 4 * 137 + 182
        let flat = p.values[s...].map { v -> Int32 in if case let .int(x, _) = v { return x }; return -1 }
        return stride(from: 0, to: flat.count, by: 6).map { Array(flat[$0..<($0 + 6)]) }
    }

    func testLayoutAndHeader() throws {
        let p = makeV3()
        XCTAssertEqual(ProgramConverter.layout(of: p), .init(ints: 173, floats: 126, globals: 73))
        XCTAssertTrue(ProgramConverter.needsConversion(p))
        let c = try ProgramConverter.convert(p, for: .twentyFour)
        XCTAssertEqual(c.version, "W3_PROG_5")
        XCTAssertEqual(ProgramConverter.layout(of: c), ProgramConverter.current)
        XCTAssertFalse(ProgramConverter.needsConversion(c))
        XCTAssertEqual(try ProgramConverter.convert(c, for: .eightM), c)    // current: unchanged
        // Serialized and read back, it is the same program.
        XCTAssertEqual(try ProgramFile(data: c.serialized()).values, c.values)
    }

    func testAmpEnvelopeAmountFromFloat113() throws {
        // The silent W3_PROG_3 program: integer 34 was 0 and float 113 was 0 (full amount).
        let p = makeV3 { i, f, _ in
            f[0][113] = "0.000000"                      // 0 + 100
            f[1][113] = "0.322835"; i[1][34] = 0        // 0 + 68
            f[2][113] = "0.417323"; i[2][34] = 20       // 20 + 58
            f[3][113] = "0.393701"; i[3][34] = 85       // 85 + 61, limited to 127
        }
        let c = try ProgramConverter.convert(p, for: .twentyFour)
        XCTAssertEqual((0..<4).map { ints(c, part: $0)[34] }, [100, 68, 78, 127])
    }

    func testValuesSetAndAppended() throws {
        let p = makeV3 { i, f, g in
            i[0][63] = 0; i[0][64] = 2
            f[0][91] = "2.000000"; f[0][102] = "0.136000"
            i[1][0] = 43; i[1][1] = 43; i[1][2] = 43
            g[12] = 1; g[13] = 4; g[15] = 13
        }
        let c = try ProgramConverter.convert(p, for: .twentyFour)
        XCTAssertEqual(ints(c, part: 0)[63...64], [1, 2])
        XCTAssertEqual(floats(c, part: 0)[91], "1.000000")
        XCTAssertEqual(floats(c, part: 0)[102], "0.446233")   // W3_PROG_3 on a 24-voice model
        XCTAssertEqual(floats(c, part: 0)[127], "4.000000")
        XCTAssertEqual(ints(c, part: 1)[0...2], [43, 43, 41])
        let g = globals(c)
        XCTAssertEqual(g[0], 2); XCTAssertEqual(g[1], 2)
        XCTAssertEqual(Array(g[120...123]), [1, 1, 1, 1])
        XCTAssertEqual(Array(g[124...127]), [4, 4, 4, 4])
        XCTAssertEqual(Array(g[132...135]), [13, 13, 13, 13])
        XCTAssertEqual(Array(g[84...87]), [15, 15, 15, 15])
    }

    func testEventsBecomePartMasks() throws {
        // [part index, a, type, b, time, 0]; type 2 = note (b = velocity·256 + note), 1 = automation.
        let ev: [[Int32]] = [[0, 100, 2, 100 << 8 | 60, 0, 0], [1, 100, 2, 100 << 8 | 62, 10, 0],
                             [2, 108, 1, 0, 20, 0], [3, 100, 2, 100 << 8 | 64, 30, 0], [255, 255, 255, 0, 0, 0]]
        // Parts 1 and 2 layered (mask 3): their notes play both.
        let layered = makeV3(events: ev) { _, _, g in g[24] = 3 }
        XCTAssertEqual(try events(ProgramConverter.convert(layered, for: .twentyFour)).map { $0[0] }, [3, 3, 4, 8, 0])
        XCTAssertEqual(try events(ProgramConverter.convert(layered, for: .eightM)).map { $0[0] }, [3, 3])
        // Split at key 61 (one split): notes go by key, whatever part they were recorded on.
        let split = makeV3(events: ev) { _, _, g in g[18] = 1; g[21] = 61 }
        XCTAssertEqual(try events(ProgramConverter.convert(split, for: .twentyFour)).map { $0[0] }, [1, 2, 4, 2, 0])
        XCTAssertEqual(try events(ProgramConverter.convert(split, for: .eightM)).map { $0[0] }, [1, 2, 2])
    }

    func testEightMFillsParts3And4() throws {
        let p = makeV3 { _, _, g in g[24] = 7; g[11] = 2; g[39] = 1 }
        let c = try ProgramConverter.convert(p, for: .eightM)
        XCTAssertEqual(ints(c, part: 2)[0...2], [2, 35, 42])          // P02, U01, A01
        XCTAssertEqual(ints(c, part: 2), ints(c, part: 3))
        let g = globals(c)
        XCTAssertEqual(g[0], 3); XCTAssertEqual(floats(c, part: 0)[102], "1.000000")
        XCTAssertEqual(g[24], 3); XCTAssertEqual(g[11], 0); XCTAssertEqual(Array(g[37...40]), [1, 0, 0, 0])
        let full = try ProgramConverter.convert(p, for: .twentyFour)
        XCTAssertEqual(ints(full, part: 2)[0...2], [15, 15, 15])
        XCTAssertEqual(globals(full)[24], 7)
    }

    func testUnknownLayoutsRefused() {
        var p = makeV3(); p.version = "W3_PROG_2"
        XCTAssertNotNil(ProgramConverter.unsupportedReason(p))
        XCTAssertThrowsError(try ProgramConverter.convert(p, for: .eightM))
        var short = makeV3(); short.values.removeLast()
        XCTAssertNil(ProgramConverter.layout(of: short))
        XCTAssertThrowsError(try ProgramConverter.convert(short, for: .eightM))
    }
}
