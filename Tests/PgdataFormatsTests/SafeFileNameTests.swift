import XCTest
@testable import PgdataFormats

final class SafeFileNameTests: XCTestCase {
    func testReadableReplacements() {
        XCTAssertEqual(SafeFileName.make("Pad A/B: \"Warm\" <dark>?*"), "Pad A-B- 'Warm' (dark)")
        XCTAssertEqual(SafeFileName.make("line\nbreak"), "line break")
    }

    func testUnderscoreReplacementAsPackUsesIt() {
        XCTAssertEqual(SafeFileName.make("A/B:C", replacement: "_"), "A_B_C")
        XCTAssertEqual(SafeFileName.make("tab\there", replacement: "_"), "tab_here")
    }

    func testEndsLengthAndReservedNames() {
        XCTAssertEqual(SafeFileName.make("  .hidden.  "), "hidden")
        XCTAssertEqual(SafeFileName.make(" .. "), "Untitled")
        XCTAssertEqual(SafeFileName.make("nul"), "nul_")
        XCTAssertEqual(SafeFileName.make("LPT1.backup"), "LPT1_.backup")
        XCTAssertEqual(SafeFileName.make("CONSOLE"), "CONSOLE")
        XCTAssertLessThanOrEqual(SafeFileName.make(String(repeating: "é", count: 300)).utf8.count, SafeFileName.byteLimit)
    }
}
