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
        XCTAssertEqual(plan.items.first { $0.name == "a.wav" }?.sourceDescription, "Serum WAV")
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

        // A 3rd Wave destination: the factory table starts unticked, with a note saying why.
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
        XCTAssertTrue(item.basisDescription.hasPrefix("Your choice"))
        XCTAssertEqual(item.sizeSource, .yourChoice)
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
        XCTAssertTrue(plan.expectedResult(for: big).hasSuffix("256 frames → 64, blending new frames"))

        plan.preset = .wav2048
        XCTAssertEqual(plan.expectedResult(for: few), "8 × 2,048")
        XCTAssertEqual(plan.expectedResult(for: big), "256 × 2,048")

        plan.preset = .tonverk
        XCTAssertEqual(plan.expectedResult(for: u), "64 × 1,024")    // Tonverk takes 1,024: kept
        XCTAssertEqual(plan.expectedResult(for: big), "64 × 2,048; 256 frames → 64, blending new frames")
        plan.options.tonverkFrameSize = 512
        XCTAssertEqual(plan.expectedResult(for: few), "8 × 512; resized from 2,048 samples per frame")

        plan.preset = .thirdWaveP
        plan.options.appendPPGStandardWaves = true
        XCTAssertEqual(plan.expectedResult(for: u), "64 × 128; resized from 1,024 samples per frame; 64 frames → 60, blending new frames; the PPG's four standard waves at 60–63")
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
        XCTAssertEqual(ready.basisDescription, "Stated in the file: clm chunk.")

        XCTAssertFalse(p.needsAttention(ready))
        XCTAssertTrue(p.needsAttention(open))
        XCTAssertTrue(p.needsAttention(odd))
        XCTAssertTrue(p.needsAttention(guess))
        XCTAssertTrue(p.needsAttention(loud))
        XCTAssertEqual(p.attentionCount, 4)
        XCTAssertEqual(p.needsFrameSizeCount, 1)
        XCTAssertEqual(p.cannotSplitCount, 1)
        XCTAssertEqual(p.blockedCount, 2)

        // Unticked tables need no attention and are not blocked.
        p.setSelected(open.id, false)
        XCTAssertEqual(p.status(p.items[1]), .unticked)
        XCTAssertFalse(p.needsAttention(p.items[1]))
        XCTAssertEqual(p.blockedCount, 1)
        XCTAssertEqual(p.attentionCount, 3)

        // Choosing a size for a guessed table makes it the user's choice.
        p.chooseFrameSize(guess.id, 1024)
        XCTAssertEqual(p.items[3].sizeSource, .yourChoice)
        XCTAssertFalse(p.items[3].isGuessed)
        XCTAssertEqual(p.items[3].basisDescription, "Your choice; the file's length suggested 2,048.")
        XCTAssertFalse(p.needsAttention(p.items[3]))
    }

    func testNotesBySeverity() {
        let p = plan([table("Loud", peak: 1.234, notes: ["Its samples reach 1.23, beyond ±1.", "The file has 2 channels; only the left (first) channel is read."]),
                      table("Quiet", notes: ["The clm chunk gives 2,048 samples per frame, but the Serum .txt sidecar gives 1,024; the clm chunk is used."])])
        let loud = p.itemNotes(for: p.items[0])
        XCTAssertEqual(loud.warnings, ["Peak 1.23: over full scale (±1).", "The file has 2 channels; only the left (first) channel is read."])
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
        XCTAssertEqual(Interpolation.none.displayName, "Steps")
        XCTAssertEqual(Interpolation.displayName(nil), "Not stated")
        XCTAssertEqual(Interpolation.displayName(.spectral), "Spectral")
        XCTAssertTrue(ConvertPlan.testingFootnote.hasPrefix("Not yet tested"))
        XCTAssertEqual(ConvertPlan.policyPhrase(.pickEvenly), "keeping original frames")
    }

    func testInterpolationWordsNeverShowTheRawName() {
        let p = plan([table("Stepped", interpolation: Interpolation.none), table("Silent", peak: 0.25)])
        XCTAssertEqual(p.items[0].interpolationDescription, "Steps")
        XCTAssertEqual(p.items[1].interpolationDescription, "Not stated")
    }
}
