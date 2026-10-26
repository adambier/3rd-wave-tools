# AGENTS.md: 3rd-wave-tools for AI coding tools

Machine-first orientation for Claude Code, Cursor, Copilot, and similar tools working in this
repository. Human developers: paste this file into your tool, or point it here, before asking for
changes. Facts below are checked against the code at the commit that introduced or last updated
this file; `docs/FORMATS.md` and `docs/WAVETABLES.md` remain the authorities on the file formats.

## 1. Project at a glance

| Item | Value |
|---|---|
| Repository | `adambier/3rd-wave-tools` (GitHub), Swift package `3rd-wave-tools` |
| What it is | pgdata Packer, a macOS app for the Groove Synthesis 3rd Wave, plus the three libraries and the developer tool behind it |
| License | MIT (`LICENSE`); not affiliated with or endorsed by Groove Synthesis |
| Formats handled | `.pro` (program), `.wt` (wavetable), `.bin` (multisample), `.pgdata` (unified program); other synths' wavetable files (WAV, FLAC, Surge `.wt`) |
| Language, tooling | Swift, `swift-tools-version:5.9`; Swift 5.9 or later (CI: the `swift:6.0-noble` image on Linux, Swift 6.2 on Windows, the runner's Xcode on macOS); XCTest |
| App platform | macOS 13 or later (`platforms: [.macOS(.v13)]`); SwiftUI plus AppKit; no Xcode project |
| Library platforms | macOS, Linux, Windows (CI tests all three on every push and pull request) |
| Hardware checked | 3rd Wave 8M and 24M, OS 2.0d (see README and FORMATS.md for what was checked where) |

## 2. Building your own tool for the 3rd Wave

This repository exists as much to help other tools get built as to ship pgdata Packer. Two ways in:

**A. In Swift, on the libraries.** Add the package and take the product for the job:

```swift
dependencies: [
    // Use the latest tag; `PgdataFormats` is stable from v1.0.5 on, `WavetableFormats` arrives with 1.1.
    .package(url: "https://github.com/adambier/3rd-wave-tools", from: "1.0.5"),
],
targets: [
    .target(name: "MyTool", dependencies: [
        .product(name: "PgdataFormats", package: "3rd-wave-tools"),      // the 3rd Wave's files
        .product(name: "WavetableFormats", package: "3rd-wave-tools"),   // other synths' wavetables
        .product(name: "PgdataPackerCore", package: "3rd-wave-tools"),   // only to behave exactly like pgdata Packer
    ]),
]
```

| Product | Take it for | Stability |
|---|---|---|
| `PgdataFormats` | Reading, writing, packing, unpacking, and converting the 3rd Wave's files; recognizing factory tables | Versioned with the app; kept stable from `v1.0.5` on |
| `WavetableFormats` | Finding wavetables in WAV, FLAC, Surge `.wt`, and 3rd Wave files; resizing; writing for other synths | Provisional in 1.1 (new; may change until a 1.1.x release after more testing) |
| `PgdataPackerCore` | Pack, unpack, and convert plans, output names, Clean Up Names, report text | May change between versions |

Three common jobs, in full (the DocC pages have more: `Sources/*/*.docc/`):

```swift
import Foundation
import PgdataFormats
import WavetableFormats

// 1. Read a program and list what each oscillator plays.
let program = try ProgramFile(data: Data(contentsOf: proURL))
for (k, source) in program.sources.enumerated() { print("part \(k / 3 + 1) osc \(k % 3 + 1): \(source.label)") }

// 2. Pack it with one embedded table; everything else listed by slot, for the receiving 3rd Wave to supply.
var content: [SourceRef: SourceContent] = [:]
for source in program.distinctSources where !source.isBuiltIn { content[source] = .reference }
content[.u(56)] = .wavetable(try WavetableFile(data: Data(contentsOf: wtURL)))
try Packer.pack(program, content: content).serialized().write(to: pgdataURL)

// 3. Convert a Serum-style WAV to a 3rd Wave U table.
for found in try WavetableReader.read(url: wavURL) {
    guard let table = found.wavetable() else { continue }   // nil: the frame size is open; ask the user (found.candidateFrameSizes)
    let out = try WavetableWriter.write(table, preset: .thirdWaveU)
    try out.data.write(to: wavesFolder.appendingPathComponent(out.fileName))
    out.notes.forEach { print($0) }   // every change made: resized, frames reduced, turned down
}
```

**B. In any other language, from the reference.** `docs/FORMATS.md` is written for implementers;
`fixtures/` is the conformance test. The facts a reader or writer cannot get wrong, each with its
section:

| Fact | Where |
|---|---|
| `.pro`: text, one value per line; tag `W3_PROG_3`…`_5`; name; four sizes; the layout of parts, floats, globals, event records | FORMATS.md §3.1–3.3 |
| Oscillator source ids and their slot ranges (P, U, analog, S) | FORMATS.md §2 |
| `.pgdata`: `W3_UNIPROG_1`, the source table (type codes 0 P, 1 U, 2 analog, 4 multisample), embedded data as 32-byte NUL-padded name + float32 LE values, then the program as 32-bit words; no format tag | FORMATS.md §4 |
| `.wt`: `PNAME`/`UNAME`, name line, one float per line; P = 64 × 128 stored as (sample, difference-to-next) pairs = 16,384 values; U = 64 × 1,024 then the mipmap chain = 131,072 values | FORMATS.md §5.1 |
| `.bin`: `W3_MSAMPLE_<v>`, versions 1, 4, 5; up to eight int16 samples with key ranges and loops | FORMATS.md §5.2 |
| Older program layouts and how the 3rd Wave converts them on import | FORMATS.md §6 and appendix |
| Name fields: 31 single-byte characters plus NUL; what the app does with names that do not fit | FORMATS.md §8; README "Names" |

Conformance: your reader must produce, from each file in `fixtures/`, the values in its `<file>.json`
(`fixtures/README.md` says what each covers); your writer should reproduce the fixtures byte for
byte from those values. Then run `swift run tw3pg roundtrip <your files>` (or your own equivalent)
over real exports: every unmodified file must come back identical.

**C. What the 3rd Wave does with your files** (FORMATS.md §7–8; read these before shipping anything the
3rd Wave will import):

- It matches wavetables and multisamples **by content**, not name: an identical table already loaded
  is reused and the file's name ignored; the slot in a file is only a label, and new content goes
  into a free slot (P36–P47, U56–U63 for tables), with an offer to overwrite the last ones when none
  is free.
- Imports come from the USB drive (volume `THIRDWAVE`): `PROGRAMS` for `.pro` and `.pgdata`, `WAVES`
  for `.wt`, `AUDIO` for `.bin` and `.wav`. **Import unified program data file** takes the first
  `.pgdata` in `PROGRAMS` (plain character order) without offering a choice; **Bulk program
  import** and **Bulk wavetable import** process files in plain character order
  (`B05P100` sorts between `B05P10` and `B05P11`: number with three digits).
- A `.pgdata` carries no format tag, and the 3rd Wave's `.pgdata` import does not fully convert
  older programs; convert them first (`ProgramConverter`, FORMATS.md §6).
- Export quirks observed on the 3rd Wave (FORMATS.md §7, §9): exporting while the drive is mounted
  on a computer has written empty files; **Export Wavetable** names files by a counter, not by slot.
- This project is file-based. For live communication with the 3rd Wave (dumps, hash lookups), see
  Groove Synthesis's *3rd Wave MIDI CC + SysEx Spec*; nothing here implements it.

**Tools wanted** (open an issue to say what you are building): a cross-platform command-line tool
for pack, unpack, and convert (the libraries are ready; `tw3pg` is a developer harness, not it); a
Windows or Linux front end on `PgdataPackerCore`; a librarian; tests of the wavetable destinations
in their synths (`OutputPreset.testedIn`).

## 3. Repository map

| Path | Contents |
|---|---|
| `Package.swift` | Targets and products (section 4); test targets opt-in on macOS |
| `Sources/PgdataFormats/` | Library: the 3rd Wave's four formats, pack/unpack, program conversion, factory table catalog; Foundation only |
| `Sources/WavetableFormats/` | Library: other synths' wavetable formats; reading, resizing, writing; Foundation and PgdataFormats only |
| `Sources/PgdataPackerCore/` | Library: the app's decisions without UI (pack, unpack, and convert plans, file names, Clean Up Names) |
| `Sources/PgdataPacker/` | The macOS app (SwiftUI, AppKit); declared in `Package.swift` only on macOS |
| `Sources/tw3pg/main.swift` | Developer command-line tool: inspect, round-trip, pack, unpack, repack, compare, convert, checks, test-file builders |
| `Tests/PgdataFormatsTests/` | Tests for PgdataFormats (`FormatTests`, `RobustnessTests`, `ConverterTests`, `FactoryLibraryTests`, `FixtureTests`, …) |
| `Tests/WavetableFormatsTests/` | Tests for WavetableFormats; `Resources/FLAC/` holds synthetic FLAC files read by path |
| `Tests/PgdataPackerCoreTests/` | Tests for PgdataPackerCore: `WorkbenchTests`, `PlanRobustnessTests`, `ConvertPlanTests.swift` (several classes: `ConvertPlanTests`, `ConvertPlanStateTests`, `ConvertChangeWordsTests`, `ConvertExistingChoicesTests`, `ConvertOptionsTextTests`, `WavetableSketchTests`, `FrameSizeFitTests`, …), `ConvertReportTests`, `ReviewFixPlanTests`, `PianoKeyTests`, and `NameFittingTests` (the Pack page and the Wavetables page's writer give the same 3rd Wave name); `TestPrograms.swift` repeats the program builders of `FormatTests.swift` |
| `fixtures/` | Seven synthetic files, one per format and layout, each with a `<file>.json` of what it parses to; `fixtures/README.md` |
| `docs/FORMATS.md` | The 3rd Wave format reference (sections 1–10 and an appendix); every claim about the 3rd Wave lives here with its evidence in footnotes |
| `docs/WAVETABLES.md` | Other synths' wavetable formats, with sources; the destinations the Wavetables page writes |
| `docs/*.png` | README screenshots |
| `Sources/*/*.docc/` | DocC catalogs for PgdataFormats (overview, `GettingStarted.md`) and WavetableFormats |
| `make-app.sh` | Builds, bundles, signs, and (for the owner) notarizes the app and updates the appcast |
| `run-tests.sh` | `PGDATA_TESTS=1 swift test` with a check that full Xcode is present |
| `.github/workflows/tests.yml` | Tests on Linux, macOS, and Windows |
| `.github/workflows/docs.yml` | Publishes the two libraries' DocC sites to GitHub Pages on pushes to `main` |
| `appcast.xml` | Sparkle update feed; maintained by the owner's release flow |
| `Resources/` | App icon (`AppIcon.icns`, `AppIcon.png`), drawn by `tools/make-icon.py` |
| `README.md`, `CONTRIBUTING.md` | User documentation and contribution rules; house style in CONTRIBUTING "Writing" |

Ignored (never commit): `.build/`, `build/`, `*.app`, `*.zip`, `site/`, `Package.resolved`, and
`hw-tests/` (the owner's private hardware-test files and release notes; only `make-app.sh --appcast`
reads it, and only when present).

## 4. Targets and dependencies

```
PgdataFormats        (library)     depends on: Foundation
WavetableFormats     (library)     depends on: PgdataFormats
PgdataPackerCore     (library)     depends on: PgdataFormats, WavetableFormats
tw3pg                (executable)  depends on: all three libraries
PgdataPacker         (executable)  depends on: all three libraries; macOS only (#if os(macOS) in Package.swift)
PgdataFormatsTests   (test target) depends on: all three libraries (a few PackPlan checks sit in its program tests)
WavetableFormatsTests (test target) depends on: PgdataFormats, WavetableFormats
PgdataPackerCoreTests (test target) depends on: all three libraries
```

Environment switches read by `Package.swift` and the tests:

| Variable | Effect |
|---|---|
| `PGDATA_TESTS=1` | On macOS, include the three test targets (needed because the Command Line Tools alone lack XCTest). Always included on Linux and Windows |
| `PGDATA_DOCS=1` | Add the `swift-docc-plugin` dependency, for building documentation |
| `PGDATA_REGENERATE_FIXTURES=1` | With `swift test --filter FixtureTests`: rewrite `fixtures/` from the libraries |

## 5. Two ways the code is compiled (both must keep working)

1. **SwiftPM** (`swift build`, `swift test`, `swift run tw3pg`): each folder is its own module.
2. **`make-app.sh`** (the shipped app): `swiftc` compiles `Sources/PgdataFormats/*.swift`,
   `Sources/WavetableFormats/*.swift`, `Sources/PgdataPackerCore/*.swift`, and
   `Sources/PgdataPacker/*.swift` together as **one module** named `PgdataPacker`, linking Sparkle
   from `build/Sparkle-<version>/`. SwiftPM is not involved (`--spm` is an alternative path).

Consequences:

- Cross-library imports inside those four folders are written as
  `#if canImport(PgdataFormats)` / `import PgdataFormats` / `#endif` (same for `WavetableFormats`
  and `PgdataPackerCore`), so they compile out in the single-module build. `tw3pg` imports plainly.
- No two top-level declarations in the four folders may share a name, and `internal` symbols are
  visible across the folders in the app build but not in SwiftPM: write code that compiles both ways
  (use `public` for anything another library target uses).
- `Package.swift` does not declare Sparkle; `Sources/PgdataPacker/main.swift` guards it with
  `#if canImport(Sparkle)`. A plain `swift build` or an Xcode build of the app compiles without
  Sparkle and has no "Check for Updates…" (`make-app.sh --spm` passes the framework flags itself).

## 6. Rules (do / don't)

Do:

- Keep `PgdataFormats`, `WavetableFormats`, and `PgdataPackerCore` Foundation-only, UI-free, and
  building on Linux, macOS, and Windows.
- Keep every reader in `PgdataFormats` round-trip exact: an unmodified file read and written back is
  byte for byte identical (`ProgramFile` keeps each line's text, `WavetableFile` keeps
  `originalBytes`, `UnifiedProgram` and `Multisample` v5 re-serialize exactly; `.bin` v1 and v4 are
  upgraded to v5 by design). Add a test for anything new.
- Give every `public` declaration in `PgdataFormats` and `WavetableFormats` a `///` doc comment
  (currently complete in both); document new public API in `PgdataPackerCore` too (coverage there
  is partial today).
- Put any new or changed claim about what the 3rd Wave does in `docs/FORMATS.md` with its evidence
  (a test on the 3rd Wave with model and OS version, a Groove Synthesis document, or a count of files),
  and mark inferences as inferences, in the code comment as well as the document.
- For a new wavetable destination, set `OutputPreset.basis` to its sources and leave `testedIn`
  empty until someone has tested it in that synth (`docs/WAVETABLES.md` carries the sources).
- Keep `fixtures/` synthetic (made by the libraries, no one else's sounds) and regenerate them with
  the command in section 9 after a deliberate change to what the libraries write.
- Follow the house style (section 10) in README, docs, DocC pages, and app text.
- Run the tests (section 9) before proposing a change; keep the three CI jobs green.

Don't:

- Don't add dependencies to the libraries, or UI frameworks (AppKit, SwiftUI, Combine) outside
  `Sources/PgdataPacker/`.
- Don't edit `Sources/PgdataFormats/FactoryCatalog.swift` by hand; it is generated by
  `tw3pg factory-catalog` from Groove Synthesis's factory `.wt` files (names and fingerprints only).
- Don't change `fixtures/*` by hand, and don't let line endings convert (`.gitattributes` marks them
  `-text`).
- Don't embed factory wavetables in a `.pgdata` in the app's plans (`PackPlan` lists a factory slot
  as `.reference`), and don't repoint multisample oscillators (`Oscillator.repointTargets` offers
  wavetable slots and analog waves only).
- Don't guess a frame size silently: a `FoundTable` with `frameSize == nil` is settled by the
  user from `candidateFrameSizes`, or by `FrameSizeFit`'s likely size only where the Input column
  says "estimated" (`ConvertPlan.Item.estimatedFrameSize`, `sizeQualifier`); 2,048, the Serum-style
  convention, is the estimate only when the samples point to no size.
- Don't commit files from other people's sound sets, factory banks, or synth exports; tests build
  their inputs synthetically (see the headers of `CorpusCaseTests.swift` and `ReadingTests.swift`).
- Don't import a module a test target does not depend on in `Package.swift` (section 4): a
  local build that has built every target has the module on hand, CI building the targets in
  parallel does not. A test that needs `PgdataPackerCore` goes in `PgdataPackerCoreTests`.
- Don't move a published git tag; a fix after a release goes into the next version.
- Don't touch `appcast.xml`, signing, or notarization: the release flow is the owner's
  (`make-app.sh --sign/--notarize/--appcast`), and its identities and keys are not in this document.
- Don't write "Third Wave", "the synth", or claims the evidence does not support.

## 7. Key types

PgdataFormats (`Sources/PgdataFormats/`):

| Type | File | Role |
|---|---|---|
| `SourceRef` | `SourceRef.swift` | What an oscillator plays: `.p(n)`, `.u(n)`, `.analog(n)`, `.s(n)`, `.unknown(id)`; id mapping, labels, `isFactorySlot` |
| `ProgramFile` | `ProgramFile.swift` | `.pro` text: `version`, `name`, `values` (`Value.int`/`.float` with original text), `sources`, `serialized()` |
| `WavetableFile` | `WavetableFile.swift` | `.wt` text: `Kind` (`.p`/`.u`), `frames`, `mipmapChain`, `dataBytes`, `fingerprint`, `peak` |
| `Multisample` | `Multisample.swift` | `.bin` v1/v4/v5: `slotName`, `samples: [Sample]`, `binData()`, `problems` |
| `UnifiedProgram` | `UnifiedProgram.swift` | `.pgdata`: `sources: [Source]` (`ref`, `payload`), `programName`, `words`, `serialized()` |
| `Packer`, `Unpacker`, `SourceContent`, `UnpackedProgram`, `PackError` | `PackUnpack.swift` | `Packer.pack(_:content:)` and `Unpacker.unpack(_:)` |
| `ProgramConverter` | `ProgramConverter.swift` | Older layouts to `ProgramConverter.current` (181/137/182): `needsConversion`, `convert(_:for:format:)`, `Model` (`.eightM`, `.twentyFour`) |
| `FactoryLibrary` | `FactoryLibrary.swift` | Factory tables by slot, name, and fingerprint; `.builtIn` from generated `FactoryCatalog` |
| `ExportNames` | `FactoryHistory.swift` | The 3rd Wave's own export file names and `B05P06`-style locations; also `SourceRef.is2025FactorySlot`, `ProgramFile.predates2025FactoryTables` |
| `NameField`, `FormatError`, `fnv1a64(_:)` | `ByteIO.swift` | 32-byte name fields and `NameField.fitted` (the one rule for a name the 3rd Wave keeps: `displayLimit` = 31, `Change`), the library's error type, the fingerprint hash |
| `SafeFileName` | `SafeFileName.swift` | File names safe on macOS, Windows, and FAT/exFAT |

WavetableFormats (`Sources/WavetableFormats/`):

| Type | File | Role |
|---|---|---|
| `Wavetable`, `Interpolation`, `SourceFormat`, `FrameSizeEvidence`, `FrameSizeSource`, `FoundTable`, `ReadNote`, `OutputPreset`, `FrameCountPolicy`, `OutputOptions`, `OutputFile`, `WavetableError` (with `Kind`) | `Wavetable.swift` | Shared value types; `ReadNote.kind` is the structured form of a reader's note, `notes` its text |
| `WavetableReader` | `Reading.swift` + `ReadWAV.swift`, `ReadFLAC.swift`, `ReadSurge.swift`, `ReadThirdWave.swift` | `read(url:)`, `read(_:fileName:sidecarText:)`: detection by content, not extension |
| `WavetableWriter`, `WritePlan` | `Writing.swift` + `WriteWAV.swift`, `WriteNames.swift` | `write(_:preset:options:) -> OutputFile`; `plan(...) -> WritePlan`, the one statement of what a conversion will do (the writer and the app's preview both derive from it); per-preset facts (`frameSize`, `maxFrameCount`, `basis`, `caveat`, `testedIn`) as `OutputPreset` extensions |
| `OutputPreset.recordsInterpolation`, `Interpolation.displayName` | `PresetInfo.swift` | Whether a format records the interpolation; the words for an interpolation (used in the writer's notes) |
| `Resampling` | `Resampling.swift`, `FFT.swift` | `resizeCycle`, `changeFrameCount`, `thirdWaveMipmapChain`; `bandLimitedCycle` (a cycle as a band-limited oscillator plays it, for Listen); `spectralBlend` and `CycleSpectrum` (a blend of two cycles by spectrum, an approximation of Serum's and Vital's morphs) |
| `PPGStandardWaves` | `PPGWaves.swift` | The PPG's four standard waveforms, which P tables from the PPG carry as frames 60–63 |

PgdataPackerCore (`Sources/PgdataPackerCore/`):

| Type | File | Role |
|---|---|---|
| `ContentFile`, `PackPlan`, `UnpackPlan`, `OutputNames`, `Oscillator`, `ProgramFile.repointed` | `Workbench.swift` | Pack and Unpack page decisions and output file names |
| `ConvertPlan`, `ConvertPreviewCache` | `ConvertPlan.swift` | Wavetables page decisions: collecting files (`Prepared` does each table's hashing, factory match, and frame-size verdict on the reading queue; `add(_:)` checks them into the list), collapsing duplicates, frame-size choice (`Item.frameSize`, `frameSizeChoices`, `sizeQualifier`, `SizeSource`), the preview's override (`Item.frameSizeAlternatives`, `sizeIsStated`), one frame size for several tables (`adjustableItems(in:)`, `commonFrameSizes(of:)`, `sharedFrameSize(of:)`, `chooseFrameSize(_:forAll:)`), blocked-table jumps (`firstItem(with:)`), which tables Convert All takes (`isIncluded(_:)`, `includedItems`: every table but factory tables for a 3rd Wave destination) and converting them or a selection (`convert(_:write:)`), expected results, the under-development notice (`conversionUnderDevelopment`, `testingStatus(_:)`), reports |
| `NameCleaner` | `NameCleaner.swift` | Clean Up Names proposals |
| `OutputPreset` display extensions | `DestinationInfo.swift` | What the Wavetables page says about each destination: `Group` (with `title`, `presets`), `group`, `shortTitle`, `specLine`, `distinction` |
| `ConvertReport`, `ReportText` | `ConvertReport.swift` | The Wavetables page's report after converting (alert title and text, log text); the item-line form every report uses |
| `FrameSizeFit`, `WavetableSketch`, `CountWords`, `PianoKey` | own files | Frame-size heuristic (the estimate when the file states no size; 2,048 is the fallback), preview pictures and the cycle at a sweep position, report phrasing, the Listen control's piano keys |

App (`Sources/PgdataPacker/`): `main.swift` (AppDelegate, menus, window, Sparkle, Help links),
`AppState.swift` (all state, `ObservableObject`, main thread; `Section` = Pack, Unpack, Wavetables),
`ContentView.swift`, `PackView.swift`, `UnpackView.swift`, `ConvertView.swift`,
`ConvertDestination.swift`, `ConvertDetail.swift`, `RepointSheet.swift`, `NameCleanupSheet.swift`,
`Panels.swift` (AppKit open/save panels, confirmations and the overwrite choice as sheets, background
writing with progress), `SearchField.swift` (an `NSSearchField` for SwiftUI), `AudioPreview.swift`
(the Listen control's engine: `AVAudioEngine` with a source node whose `Voice` owns three fixed
buffers, band-limiting through `Resampling.bandLimitedCycle`, and the CoreAudio output-device list).
The Wavetables page is laid out as the other two: the table on the left (status, Name, Input,
Output, Changes; what a file states about interpolation is in the preview and the Options box's
"existing" marks), and on the right the selected table's preview (`ConvertDetailPane`, as tall as
its content up to what leaves the destination `ConvertDestinationPane.minimumHeight`, with a fade
when it must scroll) over the destination pane; its buttons are Pack's (Remove Selected, Remove
All…, **Convert Selected…**, **Convert All…**, the last two through `AppState.convertTables(_:)`),
and the 3rd Wave options' checkbox "Also add the .wt files to the Pack page"
(`AppState.convertAddsToPack`) is honored by both. The pages are laid out to give their best at
the default window size, which fits a 13-inch display (1,440 × 860; `main.swift`), the table
giving way to the right pane. `ConvertView.swift` also holds `TableReveal` (scrolls the Wavetables
table to a row through the `NSTableView` behind SwiftUI's `Table`; the summary strip's blocked
counts jump to `ConvertPlan.firstItem(with:)`); `ConvertDetail.swift` holds the preview:
`ConvertSweepControls`
(Frame slider, Listen/Stop, pitch pop-up over `AudioPreview.pitches`, C2–C6), `ConvertSweepView`,
`ConvertSizeOverrideLink` (Override Frame Size…, over `Item.frameSizeAlternatives`), and
`ConvertSeveralFrameSize` (one frame size for several selected tables). `main.swift` also holds
`MenuActions` (the File, Edit, and View menus' targets and validation; Edit › Delete, on the Delete
key, is disabled while text is edited and otherwise removes the focused list's selected rows; a
plain Return while a list has the focus edits the selected row's name, Pack's list putting the
cursor in the program's name field, through an `NSEvent` local monitor) and `ToolbarController`
(the unified toolbar whose segmented control
switches pages, with the audio output menu at its trailing end on every page). The Wavetables page
is shown only while View › Show Under-Development Features is on (`AppState.showsUnderDevelopmentFeatures`,
`Section.isUnderDevelopment`, `availableSections`), and carries an orange under-development notice
while `ConvertPlan.conversionUnderDevelopment` is true (any `OutputPreset.testedIn` empty). Scroll bars follow the system setting; menus carry
the shortcuts (⌘O, ⇧⌘E, ⌘1–⌘3, ⌥⌘L, ⌫, ⌘A, ⌘Z); the Info.plist declares the file types with
`LSHandlerRank` None, so files open by Dock-icon drop without the app claiming any type.
`ListCommands.swift` is how Delete and Return reach a list: each `List` or `Table` registers its
closures with `.listCommands(delete:rename:)`, whose bridge view finds the `NSTableView` behind the
list and keys them by it, and `MenuActions` looks up the window's first responder (SwiftUI's
`.onCommand` on a `List` or `Table` did not answer `NSApp.target(forAction:)` on macOS 13). Every
list that holds added items (Pack's programs and its added files, Unpack's `.pgdata` files, the
Wavetables table) removes by selection, with no per-row button; Unpack's file table lists outputs
and removes nothing (Write unchecks one). Removals and committed renames are undoable through
`AppState.undoManager`, which the window returns; while a text field is edited the window returns
a separate manager for the typing (`AppDelegate.windowWillReturnUndoManager`).

## 8. Where to look (task to files)

| Task | Start here | Then |
|---|---|---|
| Change how a `.pro` is parsed or written | `ProgramFile.swift`; FORMATS.md section 3 | `FixtureTests`, `RobustnessTests`, `fixtures/program-*.pro*` |
| Source ids, slot ranges, analog order | `SourceRef.swift`; FORMATS.md section 2 | `FormatTests.swift` (`SourceRefTests`) |
| `.pgdata` layout, packing, unpacking | `UnifiedProgram.swift`, `PackUnpack.swift`; FORMATS.md section 4 | `fixtures/unified.pgdata*`, `tw3pg repack`, `tw3pg compare` |
| `.wt` values, mipmap chain, P-table differences | `WavetableFile.swift`; FORMATS.md section 5.1 | `WavetableFramesTests`, `Resampling.thirdWaveMipmapChain` |
| `.bin` fields and versions | `Multisample.swift`; FORMATS.md section 5.2 | `fixtures/multisample.bin*` |
| Older-program conversion | `ProgramConverter.swift`; FORMATS.md section 6 and appendix | `ConverterTests`, `fixtures/program-2022-layout*`, `tw3pg convert`, `tw3pg convertcheck` |
| Factory tables, U48–U55 history | `FactoryLibrary.swift`, `FactoryHistory.swift`, `FactoryCatalog.swift` (generated) | `FactoryLibraryTests`; README "Factory wavetables" |
| Names, 31-character limit, file names | `ByteIO.swift` (`NameField.fitted`, which `NameField.init`, `WriteNames.swift`, `PackPlan.nameWarnings`, and the app's `NameLengthNote` all apply), `SafeFileName.swift`, `ExportNames`, `OutputNames` | `NameFittingTests`, `SafeFileNameTests`, `WorkbenchTests` |
| Read another wavetable format | `Reading.swift` dispatch, a new `Read<Format>.swift`, `SourceFormat` | `ReadingTests`, `CorpusCaseTests`, `RoundTripTests`; WAVETABLES.md |
| Write for another synth | `OutputPreset` in `Wavetable.swift`, `Writing.swift`, `PresetInfo.swift`; `DestinationInfo.swift` in PgdataPackerCore | `WritingTests`, `RoundTripTests`; WAVETABLES.md section 2; README destination table |
| Frame size decisions | `ReadWAV.swift`, `FrameSizeEvidence`, `FrameSizeFit.swift`, `ConvertPlan.Item.frameSize`/`frameSizeChoices`/`frameSizeAlternatives`; WAVETABLES.md section 3 | `ReadingTests`, `ReviewFixTests`, `FrameSizeFitTests`, `ReviewFixPlanTests`, `ConvertPlanStateTests` |
| Listen, pitch, audio output | `AudioPreview.swift`, `PianoKey.swift`, `ToolbarController` in `main.swift` (`NSMenuToolbarItem`) | `PianoKeyTests`, `ResamplingTests` (`bandLimitedCycle`); the engine itself only by running the app |
| Preview pictures, Frame slider, sweep | `ConvertDetail.swift`, `WavetableSketch.swift` | `WavetableSketchTests`, `WavetableSketchInterpolationTests`, `ResamplingTests` (`spectralBlend`) |
| Remove, Edit › Delete, Undo | `ListCommands.swift` (`.listCommands(delete:rename:)` on each list), `MenuActions.deleteSelection` in `main.swift`; `AppState.undoManager`, `removePrograms`/`removeContent`/`removeUnpacks`/`removeConvertItems`, `removeAll*`, `renameConvertItem`, `commitUnpackFileName` | no tests; build and use the app |
| Return to rename, drop hint, first table selected after a drop | `MenuActions.installReturnKey` in `main.swift` and the lists' `rename` handlers, `AppState.focusProgramName`; `AppState.dragIsOverPage` and `LogBar`; `AppState.convertSelectionRequest` | no tests; build and use the app |
| Showing or hiding the Wavetables page | `AppState.showsUnderDevelopmentFeatures`, `MenuActions.toggleUnderDevelopmentFeatures`, `ToolbarController.fillSegments`/`showOutputItem` | no tests; build and use the app |
| Pack page behavior (what each source will be, status lines, slot estimate) | `PackPlan` in `Workbench.swift` | `WorkbenchTests`; then `PackView.swift`, `AppState.swift` |
| Unpack page behavior | `UnpackPlan` in `Workbench.swift` | `WorkbenchTests`; then `UnpackView.swift` |
| Wavetables page behavior | `ConvertPlan.swift`, `ConvertReport.swift` | `ConvertPlanTests`, `ConvertReportTests`; then `ConvertView.swift`, `ConvertDetail.swift`, `ConvertDestination.swift` |
| Clean Up Names | `NameCleaner.swift` | `WorkbenchTests`; `NameCleanupSheet.swift` |
| Menus, About, Help links, updater | `main.swift` | `make-app.sh` (Info.plist keys) |
| Developer checks against real files | `Sources/tw3pg/main.swift` | README "Verification" |
| Format documentation | `docs/FORMATS.md`, `docs/WAVETABLES.md`, `Sources/*/*.docc/` | `fixtures/README.md` |

## 9. How to verify

Library tests (XCTest, one test target per library; tests use `@testable import`):

| Platform | Command |
|---|---|
| Linux, Windows | `swift test` |
| macOS (full Xcode 15 or later) | `./run-tests.sh` or `PGDATA_TESTS=1 swift test` |
| One test class | add `--filter <ClassName>` (e.g., `--filter FixtureTests`) |
| One library's tests | add `--filter <TargetName>` (e.g., `--filter PgdataPackerCoreTests`) |

Other checks:

- **Three libraries as one module** (catches duplicate top-level names and symbols hidden by the
  `#if canImport` pattern; works on any platform):
  `swiftc -typecheck -module-name Check Sources/PgdataFormats/*.swift Sources/WavetableFormats/*.swift Sources/PgdataPackerCore/*.swift`
- **All four folders as one module and the app itself** (macOS only): `./make-app.sh debug`, then
  `open "pgdata Packer.app"`. The first run downloads Sparkle into `build/`.
- **Developer tool**: `swift run tw3pg inspect <file>`; `tw3pg roundtrip <dir>` re-serializes every
  file and reports byte differences; `tw3pg repack <dir>` unpacks and repacks `.pgdata` files;
  `tw3pg wtscan [--check-writers] <files or dirs>` lists what the Wavetables page would find and
  round-trips every preset.
- **Fixtures**: `FixtureTests` runs with the suite; regenerate after a deliberate change with
  `PGDATA_TESTS=1 PGDATA_REGENERATE_FIXTURES=1 swift test --filter FixtureTests` and commit the files.
- **Documentation**: `PGDATA_DOCS=1 swift package --disable-sandbox preview-documentation --target PgdataFormats`
  (or `--target WavetableFormats`).
- **CI** (`.github/workflows/tests.yml`, every push and pull request): `swift test` in
  `swift:6.0-noble` on `ubuntu-24.04`; `PGDATA_TESTS=1 swift test` on `macos-15`; Swift 6.2 on
  `windows-2022`. `swift test` builds every target, so the macOS job also compiles the
  `PgdataPacker` target through SwiftPM (without Sparkle), and it then type-checks all four
  Sources folders as one module with `swiftc -typecheck`, as `make-app.sh` compiles them; CI never
  runs `make-app.sh` or produces the app bundle. `docs.yml` publishes DocC on pushes to `main` that touch the libraries, only in
  the upstream repository.

No tests cover the SwiftUI views; a UI change is verified by building and using the app on a Mac.

## 10. House style for text (README, docs, DocC, app strings)

- "3rd Wave", never "Third Wave"; "Groove Synthesis" in full; "the 3rd Wave" or "your 3rd Wave",
  not "the synth" and never "a 3rd Wave" standing alone ("tests on the 3rd Wave", not "on a 3rd
  Wave"; as an adjective, "a 3rd Wave program" is fine).
- Standing behavior in the present tense; single observations as "has been observed to …";
  inferences said to be inferences; never claim more than the evidence supports.
- The serial (Oxford) comma. "e.g.," or "for example" before parenthetical examples.
- American spelling throughout ("color", "behavior", "recognize", "gray", "license"), in code
  comments and identifiers too.
- No third-party sound-set, program, or author names in README, docs, or app text (code comments,
  tests, and screenshots may carry them).
- App vocabulary: add (files), pack, embed, unpack, convert; 3rd Wave functions in bold in
  README and FORMATS.md (e.g., **Import program**), in curly quotes in the app.
- Code comments that state a fact about the 3rd Wave cite the FORMATS.md section
  (e.g., "See section 2 of FORMATS.md").
- Plain, short words; one term for one thing (table, frame, frame size, interpolation, destination,
  "to convert", input and output for the page's columns); nothing said twice in one view, report,
  or paragraph; counts that read naturally ("Both tables", "1 change"; see `CountWords`); labels
  that say exactly what they mean (name the company or document, not "the maker"); every distinct
  label actually different.
- "Frame" for a cycle in a table, never "wave" (which is kept for the analog oscillator's waves,
  the PPG's four standard waveforms, and names: Wave Maker, the `WAVES` folder). Crossfade and
  spectral are interpolation methods; "none" is the absence of interpolation, not a method.
- P tables before U tables wherever both are listed (P00–P35, U00–U55; P36–P47, U56–U63).
- Quotation marks around words taken from synth documentation (Tonverk's manual says "smooth"),
  and an inference marked when such a word is read as one of ours ("taken here to mean a
  crossfade").
- **Language review before a build is handed over, docs are merged, or a release is made:** read
  every user-facing string and document that changed for accuracy against the evidence, currency
  after renames (page, column, and feature names), agreement of tense, number, case, and mood, and
  the rules above; fix, and report any change of meaning. Tests assert some strings
  (`ConvertPlanTests`, `ConvertReportTests`, `WorkbenchTests`, `ReadingTests`): keep them in step.

## 11. Recipes

**Add a reader for another wavetable file format** (`WavetableFormats`): add a `SourceFormat` case
in `Wavetable.swift`; add a `Read<Format>.swift` file with a `static func` on `WavetableReader` that
returns `[FoundTable]` (as `readSurge(_:fileName:)` does), detecting by content and setting
`frameSizeBasis`, `frameSizeEvidence`, and `candidateFrameSizes`; dispatch from
`WavetableReader.read(_:fileName:sidecarText:)` in `Reading.swift`
and add the extension to `wavetableExtensions`; cover it in `ReadingTests` (synthetic bytes) and,
if the writer also targets it, `RoundTripTests`; document it with sources in `docs/WAVETABLES.md`
and the DocC overview; update the README "Wavetables" paragraph.

**Add a destination (writer preset)**: add an `OutputPreset` case; handle it in `Job.run()` and a
new `mutating func` in `Writing.swift`; fill every `switch` in the `OutputPreset` extensions
(`Writing.swift`: `title`, `basis`, `caveat`, `frameSize`, `maxFrameCount`, `requiredFrameCount`,
`fileExtension`, and `scalesToFit`/`isThirdWave` where they apply; `PresetInfo.swift`:
`recordsInterpolation`; PgdataPackerCore's `DestinationInfo.swift`: `shortTitle`, `specLine`,
`distinction`, the page's wording; `ConvertPlan.caveat(for:)`, an exhaustive switch);
the app lists presets through `OutputPreset.Group.presets`, so no UI list needs editing; add
`WritingTests` and `RoundTripTests` cases; add a row to `docs/WAVETABLES.md` section 2 with a
footnoted source and to the README destination table; leave `testedIn` empty.

**Add a plan feature** (Pack, Unpack, or Wavetables page): put the decision in
`PgdataPackerCore` (`PackPlan`, `UnpackPlan`, or `ConvertPlan`), test it in `WorkbenchTests` or
`ConvertPlanTests` (reader and writer are injectable in `ConvertPlan`), then show it from the view
in `Sources/PgdataPacker/`. State lives in `AppState`; the plan is recomputed from it.

**Change the UI**: edit `Sources/PgdataPacker/*.swift` only; keep imports behind `#if canImport`;
no new top-level names that collide with the libraries; build with `./make-app.sh debug` on a Mac.
Wording follows section 10. Reports go through `AlertPresenter.show` in `ContentView.swift`, which
adds the copy icon beside the title; use it rather than a new alert.

**Record a format finding**: change the code and `docs/FORMATS.md` together; add a footnote giving
the evidence (model, OS version, steps, files, or the Groove Synthesis document and section); if a
reader or writer changed, regenerate `fixtures/`; if it is only an inference, say so in both places.

**Releases** (owner only): `VERSION` in `make-app.sh` is the app and library version; tags are
`v<VERSION>`, and `PgdataFormats` is versioned with the app (tags `v1.0.5` and on). The Help menu
opens the README at the running version's tag. The build number is the commit count. A published
tag is never moved. Signing, notarization, and the Sparkle appcast are the owner's steps and need
credentials that are not in the repository.

## 12. Known limits and open questions

- Most of a program's roughly 1,450 values have no identified meaning (fewer than 60 do); the
  libraries copy them through. Editing a program's sound settings is not supported (FORMATS.md
  section 3.4 lists what is known).
- FORMATS.md section 10 (open): whether a 24K converts exactly as the 24M does; whether
  **Import program** accepts a `W3_PROG_5`-tagged file with an older layout; the meaning of most
  part, float, and global values and of event fields *a* and *time*.
- README "Tests on the 3rd Wave": how the 3rd Wave writes non-ASCII letters in file names is unknown.
- P36–P47 as ids 1002–1013 is an assumption (no file using them has been seen); the upper S-slot
  limit has not been checked (`SourceRef.sMax = 127` is the library's limit, not the 3rd Wave's).
- `OutputPreset.testedIn` is empty for every destination: no converted file has yet been loaded in
  its synth through this project. WAVETABLES.md "Open questions" lists what each test would settle.
- The mipmap chain written for U tables uses ideal spectral cut-offs; the factory filter is unknown
  (the 3rd Wave identifies a table by its first 65,536 values, so the chain need not match).
- `fixtures/` exercise structure, not sound, and have not been loaded on the 3rd Wave.
- The app is macOS-only; CI compiles it but has no tests for it. A Linux or Windows front end would
  build on `PgdataPackerCore`, whose API may change between versions more than `PgdataFormats`'s.
- `WavetableFormats` is provisional in 1.1: its API may change until a 1.1.x release, once its
  destinations have been tested in their synths.
- Listen and the preview's spectral lines use `Resampling.spectralBlend`, an approximation: Serum's
  and Vital's morph methods are not published. `FrameSizeFit` is a heuristic (frames alike at lag
  n, unlike at n/2); the Input column says "estimated" wherever it decided, and the samples
  outrank the Serum-style convention (Adam, 2026-10-26).
- The preview writes the converted bytes and reads them back (`ConvertPreviewCache`), on a
  background queue since 1.1 (`result(_:in:ready:)`; the result's picture shows a spinner until it
  is in). The read-back is kept because it is what the picture claims to show (the file the page
  would write, as a reader sees it); taking the frames from the writer instead would be quicker
  but would show the writer's intent, not the file.

## 13. Glossary

| Term | Meaning here |
|---|---|
| `.pro` | A program (patch plus sequence) as text, one value per line; tag `W3_PROG_3` to `_5` |
| `.pgdata` | A unified program: `W3_UNIPROG_1`, a source table, embedded tables and multisamples, then the program's values as 32-bit words; no format tag |
| `.wt` | One wavetable as text: `PNAME` or `UNAME`, a name, one float per line |
| `.bin` | One multisample (`W3_MSAMPLE_<v>`, versions 1, 4, and 5): up to eight samples with key ranges, loops, and audio stored as int16 |
| Part | One of a program's four layers, three oscillators each; the 8M plays parts 1 and 2 |
| Source, source id | What an oscillator plays, stored as one integer; names a slot, not content |
| `SourceRef` | The library's enum for a source: `.p`, `.u`, `.analog`, `.s`, `.unknown` |
| Slot | A position on the 3rd Wave a source id names: P00–P47, U00–U63, S*n*; what plays is whatever that 3rd Wave holds there |
| Factory slot, factory table | P00–P35 and U00–U55, holding Groove Synthesis's tables; known here by name and fingerprint, never embedded by the app |
| User slot | P36–P47 and U56–U63 (12 P and 8 U slots for the user's own tables) |
| P table | PPG-style wavetable: 64 frames of 128 samples, each point stored with its difference to the next (16,384 values) |
| U table | Wavetable of 64 frames of 1,024 samples followed by its mipmap chain (131,072 values) |
| Frame | One cycle of a waveform; a wavetable is a sequence of frames of equal length. The 3rd Wave's own terms (its wave offset and wave envelope, the manual's counts of waves) and WaveEdit's say "wave" for the same thing; this project says frame throughout, and keeps "wave" for the analog oscillator's waves, for the PPG's four standard waveforms, and in names (Wave Maker, the `WAVES` folder) |
| Frame size | Samples per frame (128, 1,024, 2,048, …); for WAV and FLAC sources it is settled by metadata, file name, sidecar, markers, or length (`FrameSizeEvidence`), or by the samples' fit (`FrameSizeFit`, said to be estimated; 2,048 when they point to no size), or left to the user |
| Mipmap chain | The band-limited copies of a U table's 64 frames at 512, 256, 128, 64, and 64 samples (65,536 values) that follow the frames in a `.wt` |
| Fingerprint | 64-bit FNV-1a of a table's values as little-endian float32 (`fnv1a64`); how factory tables and duplicates are recognized |
| Preset (`OutputPreset`) | A conversion destination (3rd Wave P or U table, Serum-style WAV, MiniFreak V, Tonverk, Phase Plant, Surge XT, WaveEdit) |
| Plan | A `PgdataPackerCore` value describing what a page will do (`PackPlan`, `UnpackPlan`, `ConvertPlan`) |
| Layout | A program's values per part, floats per part, and globals (current: 181/137/182); older layouts are converted |
