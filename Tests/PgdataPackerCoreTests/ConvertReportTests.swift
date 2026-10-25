import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

/// The report after converting: each note once with the tables it applies to, a short title,
/// and what the destination list says about its sources.
final class ConvertReportTests: XCTestCase {
    private func report(_ name: String, _ notes: String...) -> ConvertPlan.ItemReport {
        ConvertPlan.ItemReport(name: name, notes: notes)
    }

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
