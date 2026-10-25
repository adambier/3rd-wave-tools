import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

/// The one rule for names the 3rd Wave keeps (`NameField.fitted`), and that the Pack page (through
/// `Packer.pack`) and the Wavetables page's writer give the same name for the same input.
final class NameFittingTests: XCTestCase {
    func testComposedAccentsAreKept() {
        // "Café" as macOS file names store it: "e" plus a combining accent, composed to é.
        let fit = NameField.fitted("Cafe\u{301} Pad")
        XCTAssertEqual(fit.text, "Caf\u{E9} Pad")
        XCTAssertEqual(fit.changes, [])
        XCTAssertEqual(NameField.fitted("Caf\u{E9} Pad").text, "Caf\u{E9} Pad")
    }

    func testAccentsOutsideLatin1AreRemoved() {
        let fit = NameField.fitted("\u{150}r\u{151}k")   // Őrök
        XCTAssertEqual(fit.text, "Orok")
        XCTAssertEqual(fit.changes, [.accentsRemoved(from: "\u{150}\u{151}", to: "Oo")])
        XCTAssertTrue(fit.changes[0].description.contains("outside Latin-1"), fit.changes[0].description)
        // A base letter with an accent that has no composed form: the letter stays, the mark goes.
        XCTAssertEqual(NameField.fitted("x\u{301}").text, "x")
        // The same letter twice is listed once.
        XCTAssertEqual(NameField.fitted("\u{150}\u{150}").changes, [.accentsRemoved(from: "\u{150}", to: "O")])
    }

    func testCharactersWithNoLatin1BaseBecomeQuestionMarks() {
        let fit = NameField.fitted("Keys \u{1F3B9} \u{2013} \u{3A9}")   // emoji, en dash, Omega
        XCTAssertEqual(fit.text, "Keys ? ? ?")
        XCTAssertEqual(fit.changes, [.replacedWithQuestionMark(characters: "\u{1F3B9}\u{2013}\u{3A9}")])
        // An emoji made of several scalars is one character, so one "?".
        XCTAssertEqual(NameField.fitted("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}").text, "?")
        // Both kinds at once, each once: "Łódź" keeps its ó, drops the accent of ź, and has no letter for Ł.
        let mixed = NameField.fitted("\u{141}\u{F3}d\u{17A}")
        XCTAssertEqual(mixed.text, "?\u{F3}dz")
        XCTAssertEqual(mixed.changes, [.accentsRemoved(from: "\u{17A}", to: "z"), .replacedWithQuestionMark(characters: "\u{141}")])
    }

    func testLongNamesAreShortenedToTheDisplayLimit() {
        XCTAssertEqual(NameField.displayLimit, 31)
        let thirty = String(repeating: "x", count: 30)
        let name = thirty + " " + String(repeating: "y", count: 9)   // 40 characters; the 31st is a space
        let fit = NameField.fitted(name)
        XCTAssertEqual(fit.text, thirty, "the 31st character is a space, which the cut drops")
        XCTAssertEqual(fit.changes, [.shortened(from: 40, to: thirty)])
        XCTAssertTrue(fit.changes[0].description.contains("shortened"))
        let words = String(repeating: "abcd ", count: 8)   // 40 characters; the 31st is a letter
        XCTAssertEqual(NameField.fitted(words).text, "abcd abcd abcd abcd abcd abcd a")
        let exact = String(repeating: "x", count: 31)
        XCTAssertEqual(NameField.fitted(exact).changes, [])
        XCTAssertEqual(NameField.fitted(exact + "y").changes, [.shortened(from: 32, to: exact)])
        // Replacement comes first, so the count is of what is stored: 40 letters, each one byte.
        let accented = String(repeating: "e\u{301}", count: 40)
        XCTAssertEqual(NameField.fitted(accented).changes, [.shortened(from: 40, to: String(repeating: "\u{E9}", count: 31))])
    }

    func testControlCharactersBecomeSpaces() {
        let fit = NameField.fitted("Two\nLines\tand\r\na tab")
        XCTAssertEqual(fit.text, "Two Lines and a tab")
        XCTAssertEqual(fit.changes, [.controlCharactersReplaced])
        // Spaces at the ends are the caller's business: the field can hold them.
        XCTAssertEqual(NameField.fitted(" Pad ").text, " Pad ")
        XCTAssertEqual(NameField.fitted("").text, "")
    }

    func testTheFieldStoresTheFittedText() {
        for name in ["Caf\u{E9}", "\u{150}r\u{151}k", "Keys \u{1F3B9}", String(repeating: "abcd ", count: 8), "Two\nLines"] {
            let field = NameField(name)
            XCTAssertEqual(field.raw.count, 32)
            XCTAssertEqual(field.text, NameField.fitted(name).text, name)
            XCTAssertLessThanOrEqual(field.text.count, NameField.displayLimit)
        }
        // A narrower field cuts further, so that a NUL always follows the text.
        XCTAssertEqual(NameField(String(repeating: "x", count: 31), width: 16).text, String(repeating: "x", count: 15))
    }

    func testPackAndTheWriterGiveTheSameName() throws {
        let names = ["Caf\u{E9} Pad", "Cafe\u{301} Pad", "\u{150}r\u{151}k", "Keys \u{1F3B9} \u{2013} \u{3A9}",
                     "\u{141}\u{F3}d\u{17A} \u{3A9} strings that go on and on for ever", "Two\nLines", "Plain Name"]
        let wave = (0..<1024).map { Float(sin(2 * Double.pi * Double($0) / 1024)) * 0.5 }
        let frames = Array(repeating: wave, count: 64)
        for name in names {
            // The Wavetables page: the name line of the .wt the writer makes.
            let out = try WavetableWriter.write(Wavetable(name: name, frames: frames), preset: .thirdWaveU)
            let written = try WavetableFile(data: out.data).name
            XCTAssertEqual(written, WavetableWriter.thirdWaveName(name).name, name)
            // The Pack page: the name field Packer.pack writes for a program and for an embedded table.
            var program = ProgramFile(version: "W3_PROG_5", name: name, values: currentLayoutValues())
            program.setSourceID(SourceRef.u(56).id, at: 0)
            let table = WavetableFile(kind: .u, name: name, values: Array(repeating: 0.25, count: 131_072))
            let packed = try Packer.pack(program, content: [.u(56): .wavetable(table)])
            XCTAssertEqual(packed.programName.text, written, name)
            guard case let .wavetable(fieldName, _)? = packed.sources.first(where: { $0.ref == .u(56) })?.payload else {
                return XCTFail("U56 not embedded")
            }
            XCTAssertEqual(fieldName.text, written, name)
            // Both describe the same changes.
            XCTAssertEqual(PackPlan.nameWarnings(name, what: "The name").count, out.notes.filter { !$0.contains("File name") }.count, name)
        }
        // The writer alone drops spaces at the ends (they usually come from a file name) and names
        // an empty table; the field keeps the spaces, as the 3rd Wave can.
        XCTAssertEqual(WavetableWriter.thirdWaveName(" Pad ").name, "Pad")
        XCTAssertEqual(NameField(" Pad ").text, " Pad ")
        XCTAssertEqual(WavetableWriter.thirdWaveName("  ").name, "Untitled")
    }

    /// A program in the current layout (181/137/182) with analog waves at every oscillator.
    private func currentLayoutValues() -> [ProgramFile.Value] {
        var v: [ProgramFile.Value] = [.int(181), .int(137), .int(182), .int(0)]
        v += Array(repeating: .int(0), count: 4 * 181)
        v += (0..<(4 * 137)).map { .float(Float($0 % 7) * 0.125) }
        v += Array(repeating: .int(0), count: 182)
        var p = ProgramFile(version: "W3_PROG_5", name: "x", values: v)
        for k in 0..<12 { p.setSourceID(42, at: k) }
        return p.values
    }
}
