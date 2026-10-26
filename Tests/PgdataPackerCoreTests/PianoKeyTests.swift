import XCTest
@testable import PgdataPackerCore

/// The piano-key model behind the Listen control's pitch pop-up.
final class PianoKeyTests: XCTestCase {
    func testReferenceKeys() {
        XCTAssertEqual(PianoKey.a440.number, 49)
        XCTAssertEqual(PianoKey.a440.frequency, 440, accuracy: 1e-9)
        XCTAssertEqual(PianoKey.a440.name, "A4")
        XCTAssertEqual(PianoKey.middleC.number, 40)
        XCTAssertEqual(PianoKey.middleC.name, "C4")
        XCTAssertEqual(PianoKey.middleC.frequency, 261.6256, accuracy: 1e-4)
        XCTAssertEqual(PianoKey.defaultPitch.name, "A3")
        XCTAssertEqual(PianoKey.defaultPitch.frequency, 220, accuracy: 1e-9)
    }

    func testNamesAcrossTheKeyboard() {
        XCTAssertEqual(PianoKey(1).name, "A0")
        XCTAssertEqual(PianoKey(2).name, "A♯0")
        XCTAssertEqual(PianoKey(3).name, "B0")
        XCTAssertEqual(PianoKey(4).name, "C1")
        XCTAssertEqual(PianoKey(16).name, "C2")
        XCTAssertEqual(PianoKey(28).name, "C3")
        XCTAssertEqual(PianoKey(51).name, "B4")
        XCTAssertEqual(PianoKey(52).name, "C5")
        XCTAssertEqual(PianoKey(76).name, "C7")
        XCTAssertEqual(PianoKey(88).name, "C8")
        XCTAssertEqual(PianoKey(88).frequency, 4186.009, accuracy: 1e-3)
        XCTAssertEqual(PianoKey(1).frequency, 27.5, accuracy: 1e-9)
    }

    func testTextAndClamping() {
        XCTAssertEqual(PianoKey.a440.label, "A4 · key 49 · 440 Hz")
        XCTAssertEqual(PianoKey.middleC.frequencyText, "261.6 Hz")
        XCTAssertEqual(PianoKey(1).frequencyText, "27.5 Hz")
        XCTAssertEqual(PianoKey(0).number, 1)
        XCTAssertEqual(PianoKey(200).number, 88)
        XCTAssertEqual(PianoKey.keys(16...19).map(\.name), ["C2", "C♯2", "D2", "D♯2"])
        XCTAssertEqual(PianoKey.keys(90...95), [])
        XCTAssertTrue(PianoKey(10) < PianoKey(11))
    }
}
