import XCTest
@testable import PgdataFormats
@testable import WavetableFormats
@testable import PgdataPackerCore

// The Convert tab's decisions, with the reader and writer injected: WavetableReader and
// WavetableWriter are not called here. Every table is synthetic.
final class ConvertPlanTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tw3convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Helpers

    /// A synthetic table: `frames` frames of `size` samples, a ramp scaled by `seed`.
    func table(_ name: String, file: String, source: SourceFormat = .wav, frames: Int = 4, size: Int? = 2048,
               seed: Float = 1, samples: Int? = nil, candidates: [Int] = [], fingerprint: UInt64? = nil) -> FoundTable {
        let n = samples ?? frames * (size ?? 2048)
        return FoundTable(name: name, fileName: file, source: source,
                          samples: (0..<n).map { Float($0 % 101) / 101 * seed },
                          frameSize: size, frameSizeBasis: size == nil ? "file length" : "clm chunk",
                          candidateFrameSizes: candidates, thirdWaveFingerprint: fingerprint)
    }

    func found(_ t: FoundTable, _ path: String) -> ConvertPlan.Found {
        ConvertPlan.Found(url: dir.appendingPathComponent(path), table: t)
    }

    func touch(_ path: String) throws {
        let u = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: u)
    }

    static let byExtension: (String) -> Bool = { ["wav", "wt", "pgdata"].contains(($0 as NSString).pathExtension.lowercased()) }

    /// A writer stand-in: names every file after the table, in WAVES for the 3rd Wave presets.
    static func fakeWriter(_ t: Wavetable, _ p: OutputPreset, _ o: OutputOptions) throws -> OutputFile {
        let ext = p.isThirdWave ? "wt" : "wav"
        return OutputFile(fileName: t.name + "." + ext, folder: p.isThirdWave ? "WAVES" : nil,
                          data: Data(t.name.utf8), notes: ["\(t.frameCount) frames in"])
    }

    // MARK: Collecting

    func testFoldersAreSearchedRecursivelyAndFilteredByName() throws {
        for f in ["a.wav", "sub/b.WT", "sub/deeper/c.pgdata", "sub/deeper/d.wav", "notes.txt", "sub/prog.pro",
                  ".hidden.wav", "sub/.cache/e.wav", "bad.wav", "empty.wt"] { try touch(f) }
        let loose = dir.appendingPathComponent("a.wav")   // given directly as well: read once
        let (files, ignored) = ConvertPlan.filesToRead(in: [dir, loose], mayContain: Self.byExtension)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.wav", "bad.wav", "empty.wt", "b.WT", "c.pgdata", "d.wav"])
        XCTAssertEqual(ignored, 3)   // notes.txt, prog.pro, and the second a.wav

        var read: [String] = []
        var progress: [Int] = []
        let c = ConvertPlan.collect(urls: [dir], mayContain: Self.byExtension, reader: { u in
            read.append(u.lastPathComponent)
            switch u.lastPathComponent {
            case "bad.wav": throw WavetableError("The file is not a WAV.")
            case "empty.wt": return []
            case "c.pgdata": return [self.table("One", file: "c.pgdata", source: .unifiedProgram(slot: "U56", isP: false), seed: 0.5),
                                     self.table("Two", file: "c.pgdata", source: .unifiedProgram(slot: "U57", isP: false), seed: 0.25)]
            default: return [self.table(u.lastPathComponent, file: u.lastPathComponent, seed: Float(read.count))]
            }
        }, progress: { done, _ in progress.append(done) })
        XCTAssertEqual(read.count, 6)
        XCTAssertEqual(progress, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(c.problems, ["bad.wav: The file is not a WAV."])
        XCTAssertEqual(c.withoutTables, 1)
        XCTAssertEqual(c.ignored, 2)
        XCTAssertEqual(c.found.count, 5)

        var plan = ConvertPlan()
        XCTAssertEqual(plan.add(c.found, factory: FactoryLibrary()).added, 5)
        let pg = plan.items.first { $0.name == "One" }!
        XCTAssertEqual(pg.sourceDescription, "U56 in c.pgdata")
        XCTAssertEqual(pg.location.label, "U56 in c.pgdata")
        XCTAssertEqual(plan.items.first { $0.name == "a.wav" }?.sourceDescription, "WAV")
    }

    // MARK: Items

    func testDuplicatesCollapseByContentAndFrameSize() {
        var plan = ConvertPlan()
        let a = table("Pad", file: "Pad.wav")
        let s = plan.add([found(a, "Pad.wav"),
                          found(table("Pad copy", file: "Pad copy.wav"), "x/Pad copy.wav"),
                          found(table("Pad", file: "Set.pgdata", source: .unifiedProgram(slot: "U58", isP: false)), "Set.pgdata"),
                          found(table("Other", file: "Other.wav", seed: 0.5), "Other.wav"),
                          // Same samples, different frame size: a different table.
                          found(table("Pad", file: "Pad 1024.wav", frames: 8, size: 1024), "Pad 1024.wav")],
                         factory: FactoryLibrary())
        XCTAssertEqual(s, ConvertPlan.AddSummary(added: 3, duplicates: 2, repeated: 0))
        XCTAssertEqual(plan.items.map(\.name), ["Pad", "Other", "Pad"])
        let pad = plan.items[0]
        XCTAssertEqual(pad.location.label, "Pad.wav")
        XCTAssertEqual(pad.alsoIn.map(\.label), ["Pad copy.wav", "U58 in Set.pgdata"])
        XCTAssertEqual(pad.alsoInDescription, "also in Pad copy.wav and U58 in Set.pgdata")
        XCTAssertNil(plan.items[1].alsoInDescription)

        // The same file added again is left out, not recorded as a copy of itself.
        let again = plan.add([found(a, "Pad.wav"), found(table("Pad copy", file: "Pad copy.wav"), "x/Pad copy.wav")],
                             factory: FactoryLibrary())
        XCTAssertEqual(again, ConvertPlan.AddSummary(added: 0, duplicates: 0, repeated: 2))
        XCTAssertEqual(plan.items[0].alsoIn.count, 2)

        plan.remove([plan.items[1].id])
        XCTAssertEqual(plan.items.count, 2)
    }

    func testFactoryTablesAreFlaggedAndStartUntickedForTheThirdWave() throws {
        let lib = FactoryLibrary.builtIn
        let ref = SourceRef.u(7)
        let fp = try XCTUnwrap(lib.tables[ref]?.fingerprint)
        let name = try XCTUnwrap(lib.name(ref))
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([found(table(name, file: "U07.wt", source: .thirdWaveWavetable(isP: false), frames: 64, size: 1024, fingerprint: fp), "U07.wt"),
                  found(table("Mine", file: "Mine.wt", source: .thirdWaveWavetable(isP: false), frames: 64, size: 1024, seed: 0.3,
                              fingerprint: fp &+ 1), "Mine.wt"),
                  found(table("Pad", file: "Pad.wav", seed: 0.7), "Pad.wav")])
        let factory = plan.items[0]
        XCTAssertEqual(factory.factorySlot, ref)
        XCTAssertEqual(factory.factoryLabel, "factory table U07 \(name)")
        XCTAssertEqual(factory.sourceDescription, "3rd Wave U .wt")
        XCTAssertNil(plan.items[1].factorySlot)
        XCTAssertNil(plan.items[2].factorySlot)   // not a 3rd Wave source: no fingerprint, never flagged

        // A 3rd Wave destination: the factory table starts unchecked, with a note saying why.
        XCTAssertFalse(plan.isSelected(factory))
        XCTAssertTrue(plan.isSelected(plan.items[1]))
        XCTAssertTrue(plan.isSelected(plan.items[2]))
        XCTAssertTrue(plan.notes(for: factory).contains { $0.contains("every 3rd Wave has it") })
        XCTAssertEqual(plan.selectedItems.map(\.name), ["Mine", "Pad"])

        // Another destination: ticked, flagged without the 3rd Wave note.
        plan.preset = .wav2048
        XCTAssertTrue(plan.isSelected(plan.items[0]))
        XCTAssertFalse(plan.notes(for: plan.items[0]).contains { $0.contains("every 3rd Wave has it") })
        XCTAssertTrue(plan.notes(for: plan.items[0]).contains { $0.contains("U07") })

        // The user's tick wins over the default either way.
        plan.preset = .thirdWaveP
        plan.setSelected(factory.id, true)
        plan.setSelected(plan.items[2].id, false)
        XCTAssertEqual(plan.selectedItems.map(\.name), [name, "Mine"])
    }

    func testFactoryPTableNameThatRepeatsTheSlotIsLeftOut() throws {
        let lib = FactoryLibrary.builtIn
        let fp = try XCTUnwrap(lib.tables[.p(2)]?.fingerprint)
        var plan = ConvertPlan()
        plan.add([found(table("Wavetable P02", file: "02P.wt", source: .thirdWaveWavetable(isP: true), frames: 64, size: 128,
                              fingerprint: fp), "02P.wt")])
        XCTAssertEqual(plan.items[0].factorySlot, .p(2))
        XCTAssertEqual(lib.name(.p(2)), "Wavetable P02")
        XCTAssertEqual(plan.items[0].factoryLabel, "factory table P02")
    }

    func testFrameSizeNeededAsksAndOffersTheSizesThatFit() {
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([found(table("Edit", file: "Edit.wav", size: nil, samples: 16_384, candidates: [256, 2048]), "Edit.wav")],
                 factory: FactoryLibrary())
        var item = plan.items[0]
        XCTAssertTrue(item.needsFrameSize)
        XCTAssertNil(item.frameSize)
        XCTAssertNil(item.frameCount)
        XCTAssertEqual(item.sourceDescription, "WAV")
        XCTAssertEqual(item.sizeDescription, "Choose a frame size")
        XCTAssertEqual(item.sizeSource, .notStated)
        XCTAssertEqual(item.basisDescription, "The file doesn't say how long each wave is. Its length allows 256 (64 frames) or 2,048 (8 frames).")
        XCTAssertFalse(plan.canConvert(item))
        XCTAssertTrue(plan.isSelected(item))   // ticked, but not converted until a size is chosen
        XCTAssertEqual(plan.expectedResult(for: item), "Choose a frame size first")
        XCTAssertEqual(plan.status(item), .needsFrameSize)
        XCTAssertTrue(plan.statusDescription(item).contains("Choose a frame size"))
        XCTAssertNil(plan.expected(for: item))

        var c = plan.convert(write: Self.fakeWriter)
        XCTAssertTrue(c.files.isEmpty)
        XCTAssertEqual(c.errors, ["Edit: choose a frame size first"])

        plan.chooseFrameSize(item.id, 1000)   // not a size the length allows: ignored
        XCTAssertNil(plan.items[0].chosenFrameSize)
        plan.chooseFrameSize(item.id, 256)
        item = plan.items[0]
        XCTAssertEqual(item.frameSize, 256)
        XCTAssertEqual(item.sizeDescription, "64 × 256")
        XCTAssertTrue(item.basisDescription.hasPrefix("Set manually"))
        XCTAssertEqual(item.sizeSource, .setManually)
        XCTAssertEqual(plan.status(item), .ready)
        XCTAssertEqual(plan.expectedResult(for: item), "64 × 1,024; resized from 256 samples per frame")
        c = plan.convert(write: Self.fakeWriter)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.files.map(\.fileName), ["Edit.wt"])
        XCTAssertEqual(c.notes, ["Edit: 64 frames in"])
        XCTAssertEqual(c.itemIDs, [item.id])

        plan.chooseFrameSize(item.id, nil)
        XCTAssertNil(plan.items[0].frameSize)
    }

    // MARK: Destination

    func testExpectedResultFromThePresetFacts() {
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([found(table("Big", file: "Big.wav", frames: 256), "Big.wav"),
                  found(table("Few", file: "Few.wav", frames: 8, seed: 0.5), "Few.wav"),
                  found(table("U", file: "U.wt", source: .thirdWaveWavetable(isP: false), frames: 64, size: 1024, seed: 0.2), "U.wt")],
                 factory: FactoryLibrary())
        let (big, few, u) = (plan.items[0], plan.items[1], plan.items[2])
        XCTAssertEqual(plan.expectedResult(for: big), "64 × 1,024; resized from 2,048 samples per frame; 256 frames → 64, keeping original frames")
        XCTAssertEqual(plan.expectedResult(for: few), "64 × 1,024; resized from 2,048 samples per frame; 8 frames → 64, keeping original frames")
        XCTAssertEqual(plan.expectedResult(for: u), "64 × 1,024")
        plan.options.frameCountPolicy = .interpolate
        XCTAssertTrue(plan.expectedResult(for: big).hasSuffix("256 frames → 64, crossfading new frames"))

        plan.preset = .wav2048
        XCTAssertEqual(plan.expectedResult(for: few), "8 × 2,048")
        XCTAssertEqual(plan.expectedResult(for: big), "256 × 2,048")

        plan.preset = .tonverk
        XCTAssertEqual(plan.expectedResult(for: u), "64 × 1,024")    // Tonverk takes 1,024: kept
        XCTAssertEqual(plan.expectedResult(for: big), "64 × 2,048; 256 frames → 64, crossfading new frames")
        plan.options.tonverkFrameSize = 512
        XCTAssertEqual(plan.expectedResult(for: few), "8 × 512; resized from 2,048 samples per frame")

        plan.preset = .thirdWaveP
        plan.options.appendPPGStandardWaves = true
        XCTAssertEqual(plan.expectedResult(for: u), "64 × 128; resized from 1,024 samples per frame; 64 frames → 60, crossfading new frames; the PPG's four standard waves at 60–63")
    }

    // MARK: Converting and writing

    func testConvertCollectsErrorsAndGivesUniqueNames() {
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([found(table("Pad", file: "a.wav"), "a.wav"),
                  found(table("pad", file: "b.wav", seed: 0.5), "b.wav"),
                  found(table("Pad", file: "c.wav", seed: 0.25), "c.wav"),
                  found(table("Broken", file: "d.wav", seed: 0.125), "d.wav")],
                 factory: FactoryLibrary())
        let c = plan.convert { t, p, o in
            if t.name == "Broken" { throw WavetableError("The table is empty.") }
            return try Self.fakeWriter(t, p, o)
        }
        XCTAssertEqual(c.files.map(\.fileName), ["Pad.wt", "pad 2.wt", "Pad 3.wt"])
        XCTAssertEqual(c.errors, ["Broken: The table is empty."])
        XCTAssertEqual(c.itemIDs, Array(plan.items.prefix(3).map(\.id)))

        // Only clashes within the same folder count.
        let named = ConvertPlan.uniqueNames([OutputFile(fileName: "X.wav", data: Data()),
                                             OutputFile(fileName: "X.wav", folder: "WAVES", data: Data()),
                                             OutputFile(fileName: "x.WAV", data: Data()),
                                             OutputFile(fileName: "NoExt", data: Data()),
                                             OutputFile(fileName: "NoExt", data: Data())])
        XCTAssertEqual(named.map(\.fileName), ["X.wav", "X.wav", "x 2.WAV", "NoExt", "NoExt 2"])
    }

    func testWriteNeverReplacesAnExistingFile() throws {
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out.appendingPathComponent("WAVES"), withIntermediateDirectories: true)
        let existing = out.appendingPathComponent("WAVES/Pad.wt")
        try Data("old".utf8).write(to: existing)
        let files = [OutputFile(fileName: "Pad.wt", folder: "WAVES", data: Data("new".utf8)),
                     OutputFile(fileName: "Lead.wt", folder: "WAVES", data: Data("lead".utf8)),
                     OutputFile(fileName: "Loose.wav", data: Data("wav".utf8))]
        let r = ConvertPlan.write(files, into: out)
        XCTAssertEqual(r.failed, [])
        XCTAssertEqual(r.renamed, ["WAVES/Pad.wt → WAVES/Pad 2.wt"])
        XCTAssertEqual(r.written.map(\.lastPathComponent), ["Pad 2.wt", "Lead.wt", "Loose.wav"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("WAVES/Pad 2.wt")), Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Loose.wav").path))

        // Send to Pack: the .wt files, and only for a 3rd Wave destination.
        XCTAssertEqual(ConvertPlan.filesForPack(r.written, preset: .thirdWaveU).map(\.lastPathComponent), ["Pad 2.wt", "Lead.wt"])
        XCTAssertEqual(ConvertPlan.filesForPack(r.written, preset: .wav2048), [])
    }

    func testFormatCount() {
        XCTAssertEqual(ConvertPlan.formatCount(64), "64")
        XCTAssertEqual(ConvertPlan.formatCount(1024), "1,024")
        XCTAssertEqual(ConvertPlan.formatCount(524_288), "524,288")
        XCTAssertEqual(ConvertPlan.formatCount(1_000_000), "1,000,000")
    }
}

final class ConvertPlanRenameTests: XCTestCase {
    func testRenamedItemIsConvertedUnderItsNewName() throws {
        var plan = ConvertPlan()
        let t = FoundTable(name: "SAW_STACK_01", fileName: "SAW_STACK_01.wav", source: .wav,
                           samples: (0..<8 * 2048).map { Float(sin(Double($0) * 2 * .pi / 2048)) * 0.5 },
                           frameSize: 2048, frameSizeBasis: "test")
        _ = plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/SAW_STACK_01.wav"), table: t)])
        let id = try XCTUnwrap(plan.items.first?.id)
        plan.preset = .wav2048
        plan.rename(id, to: NameCleaner().clean("SAW_STACK_01"))
        XCTAssertTrue(plan.anyRenamed)
        var seen: [String] = []
        _ = plan.convert { table, _, _ in seen.append(table.name); return OutputFile(fileName: table.name + ".wav", data: Data()) }
        XCTAssertEqual(seen, [NameCleaner().clean("SAW_STACK_01")])
        XCTAssertNotEqual(seen.first, "SAW_STACK_01")
        plan.rename(id, to: "SAW_STACK_01")   // back to the file's own name
        XCTAssertFalse(plan.anyRenamed)
        plan.rename(id, to: "X"); plan.undoRenames()
        XCTAssertEqual(plan.items.first?.name, "SAW_STACK_01")
    }
}

/// The state the Convert page shows per item (status, attention, notes by severity, the expected
/// result), the preview and its cache, and what each destination says about itself.
final class ConvertPlanStateTests: XCTestCase {
    private func table(_ name: String, frames: Int = 4, size: Int? = 2048, samples: Int? = nil, peak: Float = 0.5,
                       candidates: [Int] = [], evidence: FrameSizeEvidence? = nil, notes: [String] = [],
                       interpolation: Interpolation? = nil) -> FoundTable {
        let n = samples ?? frames * (size ?? 2048)
        return FoundTable(name: name, fileName: name + ".wav", source: .wav,
                          samples: (0..<n).map { Float(sin(Double($0) * 2 * .pi / 2048)) * peak },
                          frameSize: size, frameSizeBasis: "clm chunk", candidateFrameSizes: candidates,
                          interpolation: interpolation, notes: notes, frameSizeEvidence: evidence)
    }

    private func plan(_ tables: [FoundTable], preset: OutputPreset = .thirdWaveU) -> ConvertPlan {
        var p = ConvertPlan(preset: preset)
        p.add(tables.map { ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/" + $0.fileName), table: $0) },
              factory: FactoryLibrary())
        return p
    }

    func testStatusAndAttention() {
        var p = plan([table("Ready"),
                      table("Open", size: nil, samples: 16_384, candidates: [256, 2048]),
                      table("Odd", size: 1000, samples: 2500),
                      table("Guess", frames: 8, candidates: [1024], evidence: .length),
                      table("Loud", peak: 1.3)])
        let (ready, open, odd, guess, loud) = (p.items[0], p.items[1], p.items[2], p.items[3], p.items[4])
        XCTAssertEqual(p.status(ready), .ready)
        XCTAssertEqual(p.status(open), .needsFrameSize)
        XCTAssertEqual(p.status(odd), .cannotSplit)
        XCTAssertEqual(odd.sizeDescription, "Can't split into frames")
        XCTAssertTrue(p.statusDescription(odd).hasPrefix("Can't split into frames: 2,500 samples"))
        XCTAssertEqual(p.status(guess), .ready)
        XCTAssertTrue(guess.isGuessed)
        XCTAssertEqual(guess.sizeSource, .guessed)
        XCTAssertEqual(guess.sizeSource.label, "Guessed")
        XCTAssertTrue(guess.basisDescription.contains("the usual 2,048 is assumed"))
        XCTAssertEqual(ready.sizeSource, .inFile)
        XCTAssertEqual(ready.basisDescription, "Clm chunk.")   // the reader's own phrase, capitalised

        // Only blockers count: a guessed size and a warning convert, so they need no attention.
        XCTAssertFalse(p.needsAttention(ready))
        XCTAssertTrue(p.needsAttention(open))
        XCTAssertTrue(p.needsAttention(odd))
        XCTAssertFalse(p.needsAttention(guess))
        XCTAssertFalse(p.needsAttention(loud))
        XCTAssertEqual(p.attentionCount, 2)
        XCTAssertEqual(guess.sizeQualifier, "guessed")
        XCTAssertNil(ready.sizeQualifier)
        XCTAssertNil(open.sizeQualifier)
        XCTAssertNil(ready.originBadge)
        XCTAssertEqual(p.needsFrameSizeCount, 1)
        XCTAssertEqual(p.cannotSplitCount, 1)
        XCTAssertEqual(p.blockedCount, 2)

        // Unticked tables need no attention and are not blocked.
        p.setSelected(open.id, false)
        XCTAssertEqual(p.status(p.items[1]), .excluded)
        XCTAssertFalse(p.needsAttention(p.items[1]))
        XCTAssertEqual(p.blockedCount, 1)
        XCTAssertEqual(p.attentionCount, 1)
        XCTAssertEqual(p.statusDescription(p.items[1]), "Not marked to convert; left out.")

        // Choosing a size for a guessed table makes it the user's choice.
        p.chooseFrameSize(guess.id, 1024)
        XCTAssertEqual(p.items[3].sizeSource, .setManually)
        XCTAssertFalse(p.items[3].isGuessed)
        XCTAssertEqual(p.items[3].basisDescription, "Set manually; the file's length suggested 2,048.")
        XCTAssertEqual(p.items[3].sizeQualifier, "set manually")
        XCTAssertFalse(p.needsAttention(p.items[3]))
    }

    func testNotesBySeverity() {
        let p = plan([table("Loud", peak: 1.234, notes: ["Its samples reach 1.23, beyond ±1.", "The file has 2 channels; only the left (first) channel is read."]),
                      table("Quiet", notes: ["The clm chunk gives 2,048 samples per frame, but the Serum .txt sidecar gives 1,024; the clm chunk is used."])])
        let loud = p.itemNotes(for: p.items[0])
        XCTAssertEqual(loud.warnings, ["Peak 1.23 is over full scale (±1); the table is turned down to fit.", "The file has 2 channels; only the left (first) channel is read."])
        XCTAssertEqual(loud.information, [])
        XCTAssertEqual(p.notes(for: p.items[0]), loud.all)
        XCTAssertEqual(p.items[0].peak, 1.234, accuracy: 1e-5)
        let quiet = p.itemNotes(for: p.items[1])
        XCTAssertEqual(quiet.warnings.count, 1)
        XCTAssertTrue(quiet.warnings[0].hasSuffix("is used."))
        XCTAssertTrue(quiet.information.isEmpty)
        XCTAssertFalse(quiet.isEmpty)
    }

    func testExpectedResultStruct() throws {
        var p = plan([table("Big", frames: 256, peak: 1.5), table("Small", frames: 8, size: 1024, interpolation: .spectral)])
        let big = try XCTUnwrap(p.expected(for: p.items[0]))
        XCTAssertEqual(big.frameSizeIn, 2048)
        XCTAssertEqual(big.frameSizeOut, 1024)
        XCTAssertEqual(big.frameSizeGrows, false)
        XCTAssertEqual(big.frameCountIn, 256)
        XCTAssertEqual(big.frameCountOut, 64)
        XCTAssertEqual(big.frameCountGrows, false)
        XCTAssertTrue(big.scaledToFit)
        XCTAssertFalse(big.peakKept)
        XCTAssertNil(big.interpolationRecorded)   // a 3rd Wave .wt cannot record it
        XCTAssertTrue(p.expectedResult(for: p.items[0]).contains("turned down to fit (peak 1.50)"))
        let small = try XCTUnwrap(p.expected(for: p.items[1]))
        XCTAssertFalse(small.resizes)
        XCTAssertNil(small.frameSizeGrows)
        XCTAssertEqual(small.frameCountGrows, true)
        XCTAssertFalse(small.scaledToFit)
        XCTAssertEqual(p.frameCountChangeCount, 2)

        p.preset = .wav2048
        let kept = try XCTUnwrap(p.expected(for: p.items[0]))
        XCTAssertFalse(kept.scaledToFit)
        XCTAssertTrue(kept.peakKept)
        XCTAssertEqual(kept.interpolationRecorded, .crossfade)   // the source does not say
        XCTAssertEqual(p.expected(for: p.items[1])?.interpolationRecorded, .spectral)
        p.options.interpolation = Interpolation.none
        XCTAssertEqual(p.expected(for: p.items[1])?.interpolationRecorded, Interpolation.none)
        XCTAssertEqual(p.frameCountChangeCount, 0)

        p.preset = .thirdWaveP
        p.options.appendPPGStandardWaves = true
        let ppg = try XCTUnwrap(p.expected(for: p.items[1]))
        XCTAssertTrue(ppg.addsPPGWaves)
        XCTAssertEqual(ppg.frameCountOut, 64)
        XCTAssertEqual(ppg.tableFrameCount, 60)
        XCTAssertTrue(ppg.changesCount)
    }

    func testPreviewRunsTheWriterForOneItemAndTheCacheKeepsIt() throws {
        var p = plan([table("One"), table("Open", size: nil, samples: 16_384, candidates: [256, 2048])], preset: .wav2048)
        var runs = 0
        let write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = { t, preset, _ in
            runs += 1
            return OutputFile(fileName: t.name + "." + preset.fileExtension, data: Data(), notes: ["\(t.frameCount) frames"])
        }
        XCTAssertEqual(p.preview(p.items[0], write: write)?.notes, ["4 frames"])
        XCTAssertNil(p.preview(p.items[1], write: write))   // no frame size yet
        XCTAssertEqual(runs, 1)

        let cache = ConvertPreviewCache(write: write)
        XCTAssertEqual(cache.preview(p.items[0], in: p)?.fileName, "One.wav")
        XCTAssertEqual(cache.preview(p.items[0], in: p)?.fileName, "One.wav")
        XCTAssertEqual(cache.writerRuns, 1)
        p.preset = .thirdWaveU
        XCTAssertEqual(cache.preview(p.items[0], in: p)?.fileName, "One.wt")
        XCTAssertEqual(cache.writerRuns, 2)
        p.rename(p.items[0].id, to: "Two")
        XCTAssertEqual(cache.preview(p.items[0], in: p)?.fileName, "Two.wt")
        XCTAssertEqual(cache.writerRuns, 3)
        XCTAssertEqual(cache.preview(p.items[0], in: p)?.fileName, "Two.wt")
        XCTAssertEqual(cache.writerRuns, 3)
        cache.removeAll()
        _ = cache.preview(p.items[0], in: p)
        XCTAssertEqual(cache.writerRuns, 4)

        // The real writer, through the plan.
        let real = try XCTUnwrap(p.preview(p.items[0]))
        XCTAssertEqual(real.folder, "WAVES")
        XCTAssertTrue(real.notes.contains { $0.hasPrefix("Resized from 2,048 to 1,024") })
    }

    func testPresetInfo() {
        let titles = OutputPreset.allCases.map(\.shortTitle)
        XCTAssertEqual(Set(titles).count, titles.count)
        for p in OutputPreset.allCases {
            XCTAssertFalse(p.specLine.isEmpty, "\(p)")
            XCTAssertFalse(p.distinction.isEmpty, "\(p)")
            XCTAssertEqual(p.group == .thirdWave, p.isThirdWave, "\(p)")
        }
        XCTAssertEqual(OutputPreset.Group.thirdWave.presets, [.thirdWaveU, .thirdWaveP])
        XCTAssertEqual(OutputPreset.Group.otherSynths.presets.count, 6)
        XCTAssertEqual(OutputPreset.Group.thirdWave.title, "3rd Wave")
        XCTAssertEqual(OutputPreset.thirdWaveU.specLine, "64 × 1,024 · .wt")
        XCTAssertEqual(OutputPreset.allCases.filter(\.recordsInterpolation), [.wav2048, .miniFreak, .tonverk, .phasePlant])
        XCTAssertEqual(Interpolation.none.displayName, "None (stepped)")
        XCTAssertEqual(Interpolation.displayName(nil), "Not stated")
        XCTAssertEqual(Interpolation.displayName(.spectral), "Spectral")
        XCTAssertTrue(ConvertPlan.testingFootnote.hasPrefix("Not yet tested"))
        XCTAssertEqual(ConvertPlan.policyPhrase(.pickEvenly), "keeping original frames")
    }

    func testInterpolationWordsNeverShowTheRawName() {
        let p = plan([table("Stepped", interpolation: Interpolation.none), table("Silent", peak: 0.25)])
        XCTAssertEqual(p.items[0].interpolationDescription, "None (stepped)")
        XCTAssertEqual(p.items[1].interpolationDescription, "Not stated")
    }
}

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
        XCTAssertEqual(plan.reportTitle(converted: 1, folderName: "out"), "Converted 1 table to 3rd Wave U tables into “out”.")
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

/// The small pictures of a table: frames picked evenly and each reduced to a few values.
final class WavetableSketchTests: XCTestCase {
    func testPickKeepsFirstAndLastEvenly() {
        XCTAssertEqual(WavetableSketch.pick(5, upTo: 64), [0, 1, 2, 3, 4])
        XCTAssertEqual(WavetableSketch.pick(256, upTo: 4), [0, 85, 170, 255])
        XCTAssertEqual(WavetableSketch.pick(256, upTo: 1), [0])
        XCTAssertEqual(WavetableSketch.pick(0, upTo: 4), [])
        XCTAssertEqual(WavetableSketch.pick(256, upTo: 64).count, 64)
        XCTAssertEqual(WavetableSketch.pick(256, upTo: 64).last, 255)
    }

    func testReduceKeepsPeaksAndScalesToTheTable() {
        var cycle = [Float](repeating: 0, count: 2048)
        cycle[100] = 0.5; cycle[1500] = -2
        let frames = [cycle, cycle.map { $0 * 0.5 }]
        let r = WavetableSketch.reduce(frames, maxFrames: 64, columns: 64)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].count, 64)
        XCTAssertEqual(r[0][3], 0.25)                 // 100 / 32 = column 3; scaled by 1/2
        XCTAssertEqual(r[0][46], -1)                  // 1500 / 32 = column 46: the peak, scaled to 1
        XCTAssertEqual(r[1][46], -0.5)                // the second frame keeps its level relative to the first
        XCTAssertEqual(WavetableSketch.reduce([[Float](repeating: 0, count: 8)], maxFrames: 1, columns: 4), [[0, 0, 0, 0]])
        XCTAssertEqual(WavetableSketch.reduce([[0.5, -0.25]], maxFrames: 1, columns: 8), [[1, -0.5]], "a short cycle is kept as it is")
        XCTAssertEqual(WavetableSketch.reduce([], maxFrames: 4, columns: 4), [])
        XCTAssertEqual(WavetableSketch.reduce(frames, maxFrames: 0, columns: 4), [])
        XCTAssertEqual(WavetableSketch.reduce(Array(repeating: cycle, count: 300), maxFrames: 64, columns: 10).count, 64)
    }

    func testResultFramesComeFromTheWrittenFile() throws {
        let wave = (0..<2048).map { Float(sin(Double($0) * 2 * .pi / 2048)) * 0.5 }
        let t = FoundTable(name: "T", fileName: "T.wav", source: .wav, samples: Array((0..<8).map { _ in wave }.joined()),
                           frameSize: 2048, frameSizeBasis: "clm chunk")
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/T.wav"), table: t)], factory: FactoryLibrary())
        let cache = ConvertPreviewCache()
        let u = try XCTUnwrap(cache.resultFrames(plan.items[0], in: plan))
        XCTAssertEqual(u.count, 64)
        XCTAssertEqual(u[0].count, 1024)
        XCTAssertEqual(cache.writerRuns, 1)
        _ = cache.resultFrames(plan.items[0], in: plan)
        XCTAssertEqual(cache.writerRuns, 1)
        plan.preset = .waveEdit   // 16,384 samples read back with no metadata: cut at the size written
        let w = try XCTUnwrap(cache.resultFrames(plan.items[0], in: plan))
        XCTAssertEqual(w.count, 64)
        XCTAssertEqual(w[0].count, 256)
        plan.preset = .phasePlant
        XCTAssertEqual(cache.resultFrames(plan.items[0], in: plan)?.count, 256)
    }
}

/// The faint frames the overview draws between stored frames.
final class WavetableSketchInterpolationTests: XCTestCase {
    private func cycle(_ n: Int, harmonic h: Int, amplitude: Float, phase: Double = 0) -> [Float] {
        (0..<n).map { Float(sin(2 * Double.pi * Double($0 * h) / Double(n) + phase)) * amplitude }
    }

    func testLineBudget() {
        XCTAssertEqual(WavetableSketch.lineBudget(storedFrames: 256, showsBetweens: false).stored, 64)
        XCTAssertEqual(WavetableSketch.lineBudget(storedFrames: 256, showsBetweens: false).perGap, 0)
        let b = WavetableSketch.lineBudget(storedFrames: 256, showsBetweens: true)
        XCTAssertEqual(b.stored, 24)
        XCTAssertEqual(b.perGap, 5)
        XCTAssertLessThanOrEqual(b.stored + (b.stored - 1) * b.perGap, 150)
        XCTAssertEqual(WavetableSketch.lineBudget(storedFrames: 8, showsBetweens: true).perGap, 5)
        XCTAssertEqual(WavetableSketch.lineBudget(storedFrames: 1, showsBetweens: true).perGap, 0)
    }

    func testSteppedAndUnstatedAddNothing() {
        let frames = [cycle(16, harmonic: 1, amplitude: 1), cycle(16, harmonic: 2, amplitude: 1)]
        XCTAssertTrue(WavetableSketch.inBetweens(frames, interpolation: Interpolation.none, perGap: 2).isEmpty)
        XCTAssertTrue(WavetableSketch.inBetweens(frames, interpolation: nil, perGap: 2).isEmpty)
        XCTAssertTrue(WavetableSketch.inBetweens(frames, interpolation: .crossfade, perGap: 0).isEmpty)
        XCTAssertTrue(WavetableSketch.inBetweens([frames[0]], interpolation: .crossfade, perGap: 2).isEmpty)
    }

    func testCrossfadeMidpointIsExact() {
        let a = cycle(16, harmonic: 1, amplitude: 1), b = cycle(16, harmonic: 1, amplitude: 0.5)
        let between = WavetableSketch.inBetweens([a, b, a], interpolation: .crossfade, perGap: 1)
        XCTAssertEqual(between.count, 2)
        XCTAssertEqual(between[0].position, 0.5)
        XCTAssertEqual(between[1].position, 1.5)
        for (x, y) in zip(between[0].values, cycle(16, harmonic: 1, amplitude: 0.75)) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        let thirds = WavetableSketch.inBetweens([a, b], interpolation: .crossfade, perGap: 3)
        XCTAssertEqual(thirds.map(\.position), [0.25, 0.5, 0.75])
        XCTAssertEqual(WavetableSketch.blend([0, 1], [1, 1, 1], t: 0.25), [0.25, 1])
    }

    func testSpectralBlendOfIdenticalFramesIsTheFrame() {
        let a = cycle(40, harmonic: 1, amplitude: 0.6, phase: 0.3)
        let same = WavetableSketch.spectralBlend(a, a, t: 0.4)
        XCTAssertEqual(same.count, 40)
        for (x, y) in zip(same, a) { XCTAssertEqual(x, y, accuracy: 1e-5) }
        // An odd length too (bin n/2 is then an ordinary mirrored harmonic).
        let odd = cycle(33, harmonic: 2, amplitude: 0.8, phase: 1.1)
        for (x, y) in zip(WavetableSketch.spectralBlend(odd, odd, t: 0.5), odd) { XCTAssertEqual(x, y, accuracy: 1e-5) }
        // Halfway between harmonic 1 and harmonic 2 has half of each.
        let b = cycle(40, harmonic: 2, amplitude: 0.6, phase: 0.3)
        let mid = WavetableSketch.spectralBlend(a, b, t: 0.5)
        let expected = zip(cycle(40, harmonic: 1, amplitude: 0.3, phase: 0.3), cycle(40, harmonic: 2, amplitude: 0.3, phase: 0.3)).map { $0 + $1 }
        for (x, y) in zip(mid, expected) { XCTAssertEqual(x, y, accuracy: 1e-5) }
        let between = WavetableSketch.inBetweens([a, b], interpolation: .spectral, perGap: 1)
        XCTAssertEqual(between.first?.position, 0.5)
        for (x, y) in zip(between[0].values, mid) { XCTAssertEqual(x, y, accuracy: 1e-6) }
    }

    func testTonverkRecordsSpectralAsCrossfade() {
        let wave = (0..<2048).map { Float(sin(Double($0) * 2 * .pi / 2048)) * 0.5 }
        let t = FoundTable(name: "T", fileName: "T.wav", source: .wav, samples: wave + wave, frameSize: 2048,
                           frameSizeBasis: "clm chunk", interpolation: .spectral)
        var plan = ConvertPlan(preset: .tonverk)
        plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/T.wav"), table: t)], factory: FactoryLibrary())
        XCTAssertEqual(plan.interpolationRecorded(for: plan.items[0]), .crossfade)
        plan.preset = .wav2048
        XCTAssertEqual(plan.interpolationRecorded(for: plan.items[0]), .spectral)
        plan.preset = .surge
        XCTAssertNil(plan.interpolationRecorded(for: plan.items[0]))
    }
}


/// The words the Changes column and the Name badges use.
final class ConvertChangeWordsTests: XCTestCase {
    private func found(_ t: FoundTable) -> ConvertPlan.Found {
        ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/" + t.fileName), table: t)
    }

    func testChangeWords() {
        let wave = (0..<2048).map { Float(sin(Double($0) * 2 * .pi / 2048)) }
        let big = FoundTable(name: "Big", fileName: "Big.wav", source: .wav, samples: Array((0..<256).map { _ in wave }.joined()).map { $0 * 1.3 },
                             frameSize: 2048, frameSizeBasis: "clm chunk",
                             notes: ["12 samples after the last whole frame are left out.", "Stereo file: only the left channel is used."])
        let fits = FoundTable(name: "Fits", fileName: "Fits.wt", source: .thirdWaveWavetable(isP: false),
                              samples: Array((0..<64).map { _ in Array(wave.prefix(1024)) }.joined()).map { $0 * 0.5 },
                              frameSize: 1024, frameSizeBasis: "3rd Wave U table")
        var plan = ConvertPlan(preset: .thirdWaveU)
        plan.add([found(big), found(fits)], factory: FactoryLibrary())
        let b = plan.changeWords(for: plan.items[0])
        XCTAssertEqual(b?.changes, ["resized", "256 → 64 frames", "turned down"])
        XCTAssertEqual(b?.warnings, ["12 extra samples dropped", "left channel only"])
        let f = plan.changeWords(for: plan.items[1])
        XCTAssertEqual(f?.changes, [])
        XCTAssertEqual(f?.warnings, [])
        XCTAssertEqual(plan.items[1].originBadge, "3rd Wave U")

        plan.preset = .wav2048   // the peak is kept, so it is a warning rather than a change
        let kept = plan.changeWords(for: plan.items[0])
        XCTAssertEqual(kept?.changes, [])
        XCTAssertEqual(kept?.warnings, ["peak 1.30, over full scale", "12 extra samples dropped", "left channel only"])

        plan.preset = .thirdWaveP
        plan.options.appendPPGStandardWaves = true
        plan.rename(plan.items[1].id, to: String(repeating: "x", count: 40))
        XCTAssertEqual(plan.changeWords(for: plan.items[1])?.changes, ["resized", "64 → 60 frames", "+ PPG waves", "name changed"])

        let open = FoundTable(name: "Open", fileName: "Open.wav", source: .wav, samples: Array(wave.prefix(16_384 / 2)) + Array(wave.prefix(16_384 / 2)),
                              frameSize: nil, frameSizeBasis: "not stated", candidateFrameSizes: [256, 2048])
        plan.add([found(open)], factory: FactoryLibrary())
        XCTAssertNil(plan.changeWords(for: plan.items[2]))
        XCTAssertEqual(ConvertPlan.shortWarning("The clm says 2,048 samples per frame, but the .txt says 1,024; the clm is used."), "size tags disagree")
        XCTAssertEqual(ConvertPlan.shortWarning("The clm asks for a crossfade, but the .txt asks for none; the clm is used."), "interpolation tags disagree")
        XCTAssertEqual(ConvertPlan.shortWarning("1 sample after the last whole frame is left out."), "1 extra sample dropped")
        XCTAssertEqual(ConvertPlan.shortWarning("1,500 samples after the last whole frame are left out."), "1,500 extra samples dropped")
        XCTAssertEqual(ConvertPlan.firstNumber(in: "no digits here"), nil)
        XCTAssertEqual(ConvertPlan.shortWarning("Something else entirely."), "see note")
    }

    func testOriginBadges() {
        let wave = (0..<128).map { Float(sin(Double($0) * 2 * .pi / 128)) * 0.5 }
        let tables: [FoundTable] = [
            FoundTable(name: "a", fileName: "a.wav", source: .wav, samples: wave, frameSize: 128, frameSizeBasis: "clm chunk"),
            FoundTable(name: "b", fileName: "b.flac", source: .flac, samples: wave.map { $0 * 0.9 }, frameSize: 128, frameSizeBasis: "clm chunk"),
            FoundTable(name: "c", fileName: "c.wt", source: .surgeWavetable, samples: wave.map { $0 * 0.8 }, frameSize: 128, frameSizeBasis: "Surge .wt header"),
            FoundTable(name: "d", fileName: "d.wt", source: .thirdWaveWavetable(isP: true), samples: wave.map { $0 * 0.7 }, frameSize: 128, frameSizeBasis: "3rd Wave P table"),
            FoundTable(name: "f", fileName: "Set.pgdata", source: .unifiedProgram(slot: "U56", isP: false), samples: wave.map { $0 * 0.5 }, frameSize: 128, frameSizeBasis: "3rd Wave U table"),
        ]
        var plan = ConvertPlan()
        plan.add(tables.map(found), factory: FactoryLibrary())
        XCTAssertEqual(plan.items.map(\.originBadge), [nil, "FLAC", "Surge .wt", "3rd Wave P", "U56 in Set.pgdata"])
    }
}


/// The aid for choosing a frame size: how alike neighbouring frames are at each candidate size.
final class FrameSizeFitTests: XCTestCase {
    /// `frames` cycles of `size` samples; frame k is a sine with a little of harmonic 2 + k/8,
    /// so neighbouring frames are alike but not identical.
    private func table(frames: Int, size: Int) -> [Float] {
        (0..<frames).flatMap { f -> [Float] in
            let h = Float(2 + f / 8)
            return (0..<size).map { i in
                let x = 2 * Float.pi * Float(i) / Float(size)
                return 0.7 * sin(x) + 0.2 * sin(h * x)
            }
        }
    }

    func testTheRightSizeIsLikelyAndNeitherAFragmentNorAMultipleIs() {
        let samples = table(frames: 64, size: 128)   // 8,192 samples: 64 × 128 or 4 × 2,048
        let ratings = FrameSizeFit.rate(samples, sizes: [128, 2048])
        XCTAssertEqual(ratings.map(\.size), [128, 2048])
        XCTAssertTrue(ratings[0].isPlausible, "\(ratings[0].difference)")
        XCTAssertLessThan(ratings[1].difference, 0.5, "a multiple of the right size also has alike frames")
        XCTAssertFalse(ratings[1].isPlausible, "but no more alike than its half-frames: \(ratings[1].difference) against \(ratings[1].halfDifference)")
        XCTAssertEqual(FrameSizeFit.verdict(samples, sizes: [128, 2048]), .likely(128))

        let serum = table(frames: 4, size: 2048)      // the same length, but 4 frames of 2,048
        let r = FrameSizeFit.rate(serum, sizes: [128, 2048])
        XCTAssertFalse(r[0].isPlausible, "a fragment of a cycle differs from the next fragment: \(r[0].difference)")
        XCTAssertTrue(r[1].isPlausible, "\(r[1].difference)")
        XCTAssertEqual(FrameSizeFit.verdict(serum, sizes: [128, 2048]), .likely(2048))
    }

    func testUnrelatedFramesFitNoSizeAndSilenceSaysNothing() {
        // 64 frames of noise-like, unrelated waves: neither size stands out.
        var seed: UInt32 = 7
        let bank: [Float] = (0..<16_384).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }
        let v = FrameSizeFit.verdict(bank, sizes: [256, 2048])
        XCTAssertNotEqual(v, .likely(256))
        XCTAssertNotEqual(v, .likely(2048))
        XCTAssertEqual(FrameSizeFit.rate([Float](repeating: 0, count: 4096), sizes: [2048]), [])
        XCTAssertEqual(FrameSizeFit.verdict([Float](repeating: 0, count: 4096), sizes: [2048]), .unclear)
        XCTAssertEqual(FrameSizeFit.rate(table(frames: 1, size: 2048), sizes: [2048]), [], "one frame cannot be compared with a next one")
        XCTAssertEqual(FrameSizeFit.likelySize(.likely(128)), 128)
        XCTAssertNil(FrameSizeFit.likelySize(.tie))
    }

    func testTheVerdictIsStoredWithTheItem() {
        let t = FoundTable(name: "Open", fileName: "Open.wav", source: .wav, samples: table(frames: 64, size: 128),
                           frameSize: nil, frameSizeBasis: "not stated", candidateFrameSizes: [128, 2048])
        var plan = ConvertPlan()
        plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/Open.wav"), table: t)], factory: FactoryLibrary())
        XCTAssertEqual(plan.items[0].frameSizeFit, .likely(128))
        XCTAssertNil(plan.items[0].frameSize, "never applied by itself")
        let settled = FoundTable(name: "Set", fileName: "Set.wav", source: .wav, samples: table(frames: 4, size: 2048),
                                 frameSize: 2048, frameSizeBasis: "clm chunk")
        plan.add([ConvertPlan.Found(url: URL(fileURLWithPath: "/tmp/Set.wav"), table: settled)], factory: FactoryLibrary())
        XCTAssertEqual(plan.items[1].frameSizeFit, .unclear)
    }
}
