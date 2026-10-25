import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

/// The report after converting: each note once with the tables it applies to, a short title,
/// what the destination list says about its sources, and the alert and log texts `ConvertReport`
/// assembles from them.
final class ConvertReportTests: XCTestCase {
    private func report(_ name: String, _ notes: String...) -> ConvertPlan.ItemReport {
        ConvertPlan.ItemReport(name: name, notes: notes)
    }

    // MARK: ConvertReport

    private let folder = URL(fileURLWithPath: "/Users/me/Desktop/output")

    /// A conversion of `names`, one file each, with `errors`; the reports carry `notes`.
    private func conversion(_ names: [String], notes: [[String]]? = nil, errors: [String] = []) -> ConvertPlan.Conversion {
        ConvertPlan.Conversion(files: names.map { OutputFile(fileName: $0 + ".wav", data: Data()) },
                               itemIDs: names.map { _ in UUID() },
                               reports: names.enumerated().map { ConvertPlan.ItemReport(name: $1, notes: notes?[$0] ?? []) },
                               errors: errors)
    }

    private func written(_ names: [String], renamed: [String] = [], failed: [String] = []) -> ConvertPlan.WriteReport {
        ConvertPlan.WriteReport(written: names.map { folder.appendingPathComponent($0) }, renamed: renamed, failed: failed)
    }

    private func make(_ plan: ConvertPlan, _ c: ConvertPlan.Conversion, _ w: ConvertPlan.WriteReport, pack: [URL] = []) -> ConvertReport {
        ConvertReport(plan: plan, conversion: c, written: w, folder: folder, packFiles: pack)
    }

    func testTitleCountsTheFilesWritten() {
        let one = make(ConvertPlan(preset: .thirdWaveU), conversion(["A"]), written(["WAVES/A.wt"]))
        XCTAssertEqual(one.title, "Converted 1 table to a 3rd Wave U table into “output”.")
        XCTAssertEqual(one.message, one.title, "nothing else to say")
        XCTAssertEqual(one.log, one.title + " (/Users/me/Desktop/output)")
        let three = make(ConvertPlan(preset: .phasePlant), conversion(["A", "B", "C"]), written(["A.wav", "B.wav", "C.wav"]))
        XCTAssertEqual(three.title, "Converted 3 tables for Phase Plant into “output”.")
        XCTAssertTrue(three.message.hasPrefix(three.title))
        // A file that could not be written is not counted as converted.
        let two = make(ConvertPlan(preset: .wav2048), conversion(["A", "B", "C"]), written(["A.wav", "B.wav"], failed: ["/Users/me/Desktop/output/C.wav: Permission denied"]))
        XCTAssertTrue(two.title.hasPrefix("Converted 2 tables for "), two.title)
    }

    func testGroupedNotesAreOneSectionAndTheLogHasEveryTable() {
        let c = conversion(["A", "B"], notes: [["same", "only A"], ["same", "only B"]])
        let r = make(ConvertPlan(preset: .wav2048), c, written(["A.wav", "B.wav"]))
        XCTAssertEqual(r.message, r.title + "\n\nWhat converting did:\n• Both tables\tsame\n• A\tonly A\n• B\tonly B")
        XCTAssertEqual(r.log, r.message + " (/Users/me/Desktop/output)\n\nBy table:\n• A\tsame\n• A\tonly A\n• B\tsame\n• B\tonly B")
        // One table: its notes under its name; the log still lists them by table.
        let single = make(ConvertPlan(preset: .wav2048), conversion(["Only"], notes: [["Resized from 1,024 to 2,048 samples per frame."]]), written(["Only.wav"]))
        XCTAssertTrue(single.message.hasSuffix("What converting did:\n• Only\tResized from 1,024 to 2,048 samples per frame."), single.message)
        XCTAssertTrue(single.log.hasSuffix("By table:\n• Only\tResized from 1,024 to 2,048 samples per frame."), single.log)
        // No notes: no section, and no "By table:" in the log.
        let plain = make(ConvertPlan(preset: .wav2048), conversion(["A", "B"]), written(["A.wav", "B.wav"]))
        XCTAssertFalse(plain.message.contains("What converting did"))
        XCTAssertFalse(plain.log.contains("By table"))
    }

    func testErrorsAndFilesNotWrittenAndRenamedHaveTheirSections() {
        let c = conversion(["Pad", "Lead"], errors: ["Broken: The table is empty.", "Edit: choose a frame size first"])
        let w = written(["WAVES/Pad 2.wt", "WAVES/Lead.wt"],
                        renamed: ["WAVES/Pad.wt → WAVES/Pad 2.wt"],
                        failed: ["/Users/me/Desktop/output/WAVES/Lead.wt: You don’t have permission to save the file."])
        let r = make(ConvertPlan(preset: .thirdWaveU), c, w)
        XCTAssertEqual(r.message, r.title
            + "\n\nNot converted:\n• Broken\tThe table is empty.\n• Edit\tchoose a frame size first"
            + "\n\nNot written:\n• /Users/me/Desktop/output/WAVES/Lead.wt\tYou don’t have permission to save the file."
            + "\n\nAlready in the folder, so written under a new name (nothing was replaced):\n• WAVES/Pad.wt → WAVES/Pad 2.wt")
        XCTAssertEqual(ReportText.plain(r.message).components(separatedBy: "\n")[3], "• Broken — The table is empty.")
    }

    func testCapacityNoteFollowsTheNotes() {
        // Nine of the user's own U tables marked for a 3rd Wave U destination: more than it holds.
        let wave = (0..<128).map { Float(sin(Double($0) * 2 * .pi / 128)) }
        func table(_ i: Int) -> ConvertPlan.Found {
            let t = FoundTable(name: "T\(i)", fileName: "T\(i).wav", source: .wav, samples: (wave + wave).map { $0 * (0.1 + Float(i) * 0.05) },
                               frameSize: 128, frameSizeBasis: "clm chunk")
            return ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/T\(i).wav"), table: t)
        }
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add((0..<9).map(table), factory: FactoryLibrary())
        let names = plan.items.map(\.name)
        let c = conversion(names, notes: names.map { _ in ["Resized from 128 to 1,024 samples per frame."] })
        let note = "9 U tables to convert; a 3rd Wave holds 8 of your own at a time (with none free, it offers to overwrite its last ones)."
        let r = make(plan, c, written(names.map { "WAVES/\($0).wt" }))
        XCTAssertEqual(plan.thirdWaveCapacityNote, note)
        XCTAssertTrue(r.message.hasSuffix("What converting did:\n• All 9 tables\tResized from 128 to 1,024 samples per frame.\n\n" + note), r.message)
        XCTAssertTrue(r.log.contains(note + " (/Users/me/Desktop/output)\n\nBy table:\n"), r.log)
        // Eight fit: no note, and the pack sentence follows the notes directly.
        plan.setSelected(plan.items[0].id, false)
        XCTAssertNil(plan.thirdWaveCapacityNote)
        let fits = make(plan, c, written(names.map { "WAVES/\($0).wt" }), pack: [folder.appendingPathComponent("WAVES/T1.wt")])
        XCTAssertFalse(fits.message.contains("a 3rd Wave holds"))
        XCTAssertTrue(fits.message.hasSuffix("samples per frame.\n\nThe .wt file is added to the Pack page."), fits.message)
    }

    func testPackSentenceCountsTheFilesAdded() {
        let c = conversion(["A", "B"])
        let w = written(["WAVES/A.wt", "WAVES/B.wt"])
        let none = make(ConvertPlan(preset: .thirdWaveU), c, w)
        XCTAssertFalse(none.message.contains("Pack page"))
        let one = make(ConvertPlan(preset: .thirdWaveU), c, w, pack: [w.written[0]])
        XCTAssertEqual(one.message, one.title + "\n\nThe .wt file is added to the Pack page.")
        XCTAssertEqual(one.log, one.message + " (/Users/me/Desktop/output)")
        let two = make(ConvertPlan(preset: .thirdWaveU), c, w, pack: w.written)
        XCTAssertEqual(two.message, two.title + "\n\nThe 2 .wt files are added to the Pack page.")
    }

    func testReportTextLines() {
        XCTAssertEqual(ReportText.item("Pad"), "• Pad")
        XCTAssertEqual(ReportText.item("Pad", "resized"), "• Pad\tresized")
        XCTAssertEqual(ReportText.item(splitting: "Pad.wav: The file is not a WAV."), "• Pad.wav\tThe file is not a WAV.")
        XCTAssertEqual(ReportText.item(splitting: "No colon here"), "• No colon here")
        XCTAssertEqual(ReportText.item(splitting: "Set.pgdata: U56: resized"), "• Set.pgdata\tU56: resized", "split at the first \": \"")
        XCTAssertEqual(ReportText.plain("• Pad\tresized"), "• Pad — resized")
        XCTAssertEqual(ReportText.lowerFirst("Not used by any added program"), "not used by any added program")
        XCTAssertEqual(ReportText.lowerFirst("U50 is a factory slot"), "U50 is a factory slot")
        XCTAssertEqual(ReportText.lowerFirst("SM OB2"), "SM OB2")
    }

    // MARK: ConvertPlan's parts of the report

    func testGroupedNotesSayEachThingOnce() {
        let reports = [report("A", "Resized", "Count 64 → 256", "Peak 1.03 kept"),
                       report("B", "Resized", "Count 64 → 256"),
                       report("C", "Resized", "Count 8 → 256", "Name shortened"),
                       report("D", "Resized", "Count 64 → 256")]
        let g = ConvertPlan.groupedNotes(reports)
        XCTAssertEqual(g.map(\.label), ["All 4 tables", "3 tables", "A", "C", "C"])
        XCTAssertEqual(g.map(\.text), ["Resized", "Count 64 → 256", "Peak 1.03 kept", "Count 8 → 256", "Name shortened"])
        XCTAssertEqual(g[1].names, ["A", "B", "D"])
        XCTAssertTrue(g[0].isUniversal)
        XCTAssertFalse(g[1].isUniversal)

        // Shared notes come most-shared first; one table's notes keep the writer's order.
        let more = [report("A", "x", "y"), report("B", "y"), report("C", "y", "x"), report("D", "y"), report("E", "z", "w")]
        XCTAssertEqual(ConvertPlan.groupedNotes(more).map(\.label), ["4 tables", "2 tables", "E", "E"])
        XCTAssertEqual(ConvertPlan.groupedNotes(more).map(\.text), ["y", "x", "z", "w"])

        // One table: its notes under its name, never "All 1 tables".
        XCTAssertEqual(ConvertPlan.groupedNotes([report("Only", "x", "y")]).map(\.label), ["Only", "Only"])
        XCTAssertEqual(ConvertPlan.groupedNotes([]), [])
        XCTAssertEqual(ConvertPlan.groupedNotes([report("Plain")]), [])
    }

    func testConversionCarriesNotesPerItemAndTheLogLines() {
        var plan = ConvertPlan(preset: .wav2048)
        let wave = (0..<2048).map { Float(sin(Double($0) * 2 * .pi / 2048)) * 0.5 }
        let a = FoundTable(name: "A", fileName: "A.wav", source: .wav, samples: wave + wave, frameSize: 2048, frameSizeBasis: "clm chunk")
        let b = FoundTable(name: "B", fileName: "B.wav", source: .wav, samples: wave.map { $0 * 0.5 } + wave, frameSize: 2048, frameSizeBasis: "clm chunk")
        plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/A.wav"), table: a),
                  ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/B.wav"), table: b)], factory: FactoryLibrary())
        let c = plan.convert { t, _, _ in OutputFile(fileName: t.name + ".wav", data: Data(), notes: ["same", t.name == "A" ? "only A" : "only B"]) }
        XCTAssertEqual(c.reports, [ConvertPlan.ItemReport(name: "A", notes: ["same", "only A"]),
                                   ConvertPlan.ItemReport(name: "B", notes: ["same", "only B"])])
        XCTAssertEqual(c.notes, ["A: same", "A: only A", "B: same", "B: only B"])
        XCTAssertEqual(ConvertPlan.groupedNotes(c.reports).map(\.label), ["Both tables", "A", "B"])
    }

    func testReportTitleIsShort() {
        var plan = ConvertPlan(preset: .phasePlant)
        XCTAssertEqual(plan.reportTitle(converted: 74, folderName: "output"), "Converted 74 tables for Phase Plant into “output”.")
        plan.preset = .thirdWaveU
        XCTAssertEqual(plan.reportTitle(converted: 1, folderName: "out"), "Converted 1 table to a 3rd Wave U table into “out”.")
        for p in OutputPreset.allCases {
            XCTAssertFalse(p.title.contains("("), "\(p): the title carries no parenthetical; the notes say the sizes")
        }
    }

    func testSourcesNameTheirPublisherAndCaveatsFollowTheOpenQuestions() {
        for p in OutputPreset.allCases {
            XCTAssertFalse(p.basis.contains("maker"), "\(p)")
        }
        XCTAssertTrue(OutputPreset.wav2048.basis.hasPrefix("Xfer Records, Serum 2 User Guide"))
        XCTAssertTrue(OutputPreset.tonverk.basis.hasPrefix("Elektron, "))
        XCTAssertEqual(OutputPreset.allCases.filter { $0.caveat != nil }, [.wav2048, .miniFreak, .phasePlant])
        XCTAssertNil(OutputPreset.tonverk.caveat, "Convert always writes a size tag, so the open question about a bare trailing r does not reach the user")
        XCTAssertFalse(ConvertPlan.testingFootnote.contains("maker"))
    }

    func testSourceLabelsAreDistinctAndWAVIsOneLabel() {
        let wave = (0..<128).map { Float(sin(Double($0) * 2 * .pi / 128)) * 0.5 }
        let tables: [FoundTable] = [
            FoundTable(name: "a", fileName: "a.wav", source: .wav, samples: wave, frameSize: 128, frameSizeBasis: "clm chunk"),
            FoundTable(name: "b", fileName: "b.wav", source: .wav, samples: wave.map { $0 * 0.9 }, frameSize: 2048, frameSizeBasis: "file length"),
            FoundTable(name: "c", fileName: "c.wt", source: .surgeWavetable, samples: wave.map { $0 * 0.8 }, frameSize: 128, frameSizeBasis: "Surge .wt header"),
            FoundTable(name: "d", fileName: "d.wt", source: .thirdWaveWavetable(isP: true), samples: wave.map { $0 * 0.7 }, frameSize: 128, frameSizeBasis: "3rd Wave P table"),
            FoundTable(name: "e", fileName: "e.wt", source: .thirdWaveWavetable(isP: false), samples: wave.map { $0 * 0.6 }, frameSize: 128, frameSizeBasis: "3rd Wave U table"),
            FoundTable(name: "f", fileName: "Set.pgdata", source: .unifiedProgram(slot: "U56", isP: false), samples: wave.map { $0 * 0.5 }, frameSize: 128, frameSizeBasis: "3rd Wave U table"),
        ]
        var plan = ConvertPlan()
        plan.add(tables.map { ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/" + $0.fileName), table: $0) }, factory: FactoryLibrary())
        let labels = plan.items.map(\.sourceDescription)
        XCTAssertEqual(labels, ["WAV", "WAV", "Surge .wt", "3rd Wave P .wt", "3rd Wave U .wt", "U56 in Set.pgdata"])
        XCTAssertEqual(Set(labels.dropFirst()).count, labels.count - 1)
    }
}
