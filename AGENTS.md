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
| Licence | MIT (`LICENSE`); not affiliated with or endorsed by Groove Synthesis |
| Formats handled | `.pro` (program), `.wt` (wavetable), `.bin` (multisample), `.pgdata` (unified program); other synths' wavetable files (WAV, FLAC, Surge `.wt`) |
| Language, tooling | Swift, `swift-tools-version:5.9`; Swift 5.9 or later (CI: the `swift:6.0-noble` image on Linux, Swift 6.2 on Windows, the runner's Xcode on macOS); XCTest |
| App platform | macOS 13 or later (`platforms: [.macOS(.v13)]`); SwiftUI plus AppKit; no Xcode project |
| Library platforms | macOS, Linux, Windows (CI tests all three on every push and pull request) |
| Hardware checked | 3rd Wave 8M and 24M, OS 2.0d (see README and FORMATS.md for what was checked where) |

## 2. Repository map

| Path | Contents |
|---|---|
| `Package.swift` | Targets and products (section 3); test targets opt-in on macOS |
| `Sources/PgdataFormats/` | Library: the 3rd Wave's four formats, pack/unpack, program conversion, factory table catalog; Foundation only |
| `Sources/WavetableFormats/` | Library: other synths' wavetable formats; reading, resizing, writing; Foundation and PgdataFormats only |
| `Sources/PgdataPackerCore/` | Library: the app's decisions without UI (pack, unpack, and convert plans, file names, Clean Up Names) |
| `Sources/PgdataPacker/` | The macOS app (SwiftUI, AppKit); declared in `Package.swift` only on macOS |
| `Sources/tw3pg/main.swift` | Developer command-line tool: inspect, round-trip, pack, unpack, repack, compare, convert, checks, test-file builders |
| `Tests/PgdataFormatsTests/` | Tests for PgdataFormats (`FormatTests`, `RobustnessTests`, `ConverterTests`, `FactoryLibraryTests`, `FixtureTests`, …) |
| `Tests/WavetableFormatsTests/` | Tests for WavetableFormats; `Resources/FLAC/` holds synthetic FLAC files read by path |
| `Tests/PgdataPackerCoreTests/` | Tests for PgdataPackerCore: `WorkbenchTests`, `PlanRobustnessTests`, `ConvertPlanTests`, `ConvertReportTests`, `ReviewFixPlanTests`; `TestPrograms.swift` repeats the program builders of `FormatTests.swift` |
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

## 3. Targets and dependencies

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

## 4. Two ways the code is compiled (both must keep working)

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

## 5. Rules (do / don't)

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
  (a test on a 3rd Wave with model and OS version, a Groove Synthesis document, or a count of files),
  and mark inferences as inferences, in the code comment as well as the document.
- For a new wavetable destination, set `OutputPreset.basis` to its sources and leave `testedIn`
  empty until someone has tested it in that synth (`docs/WAVETABLES.md` carries the sources).
- Keep `fixtures/` synthetic (made by the libraries, no one else's sounds) and regenerate them with
  the command in section 8 after a deliberate change to what the libraries write.
- Follow the house style (section 9) in README, docs, DocC pages, and app text.
- Run the tests (section 8) before proposing a change; keep the three CI jobs green.

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
- Don't guess a frame size silently: a `FoundTable` with `frameSize == nil` must be settled by the
  user from `candidateFrameSizes`.
- Don't commit files from other people's sound sets, factory banks, or synth exports; tests build
  their inputs synthetically (see the headers of `CorpusCaseTests.swift` and `ReadingTests.swift`).
- Don't move a published git tag; a fix after a release goes into the next version.
- Don't touch `appcast.xml`, signing, or notarization: the release flow is the owner's
  (`make-app.sh --sign/--notarize/--appcast`), and its identities and keys are not in this document.
- Don't write "Third Wave", "the synth", or claims the evidence does not support.

## 6. Key types

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
| `NameField`, `FormatError`, `fnv1a64(_:)` | `ByteIO.swift` | 32-byte name fields, the library's error type, the fingerprint hash |
| `SafeFileName` | `SafeFileName.swift` | File names safe on macOS, Windows, and FAT/exFAT |

WavetableFormats (`Sources/WavetableFormats/`):

| Type | File | Role |
|---|---|---|
| `Wavetable`, `Interpolation`, `SourceFormat`, `FrameSizeEvidence`, `FoundTable`, `OutputPreset`, `FrameCountPolicy`, `OutputOptions`, `OutputFile`, `WavetableError` | `Wavetable.swift` | Shared value types |
| `WavetableReader` | `Reading.swift` + `ReadWAV.swift`, `ReadFLAC.swift`, `ReadSurge.swift`, `ReadThirdWave.swift` | `read(url:)`, `read(_:fileName:sidecarText:)`: detection by content, not extension |
| `WavetableWriter` | `Writing.swift` + `WriteWAV.swift`, `WriteNames.swift` | `write(_:preset:options:) -> OutputFile`; per-preset facts (`frameSize`, `maxFrameCount`, `basis`, `caveat`, `testedIn`) as `OutputPreset` extensions |
| `OutputPreset` display extensions | `PresetInfo.swift` | `Group`, `shortTitle`, `specLine`, `distinction`, `recordsInterpolation` |
| `Resampling` | `Resampling.swift`, `FFT.swift` | `resizeCycle`, `changeFrameCount`, `thirdWaveMipmapChain` |
| `PPGStandardWaves` | `PPGWaves.swift` | The four waves P tables carry at positions 60–63 |

PgdataPackerCore (`Sources/PgdataPackerCore/`):

| Type | File | Role |
|---|---|---|
| `ContentFile`, `PackPlan`, `UnpackPlan`, `OutputNames`, `Oscillator`, `ProgramFile.repointed` | `Workbench.swift` | Pack and Unpack page decisions and output file names |
| `ConvertPlan`, `ConvertPreviewCache` | `ConvertPlan.swift` | Wavetables page decisions: collecting files, collapsing duplicates, frame-size choice, expected results, reports |
| `NameCleaner` | `NameCleaner.swift` | Clean Up Names proposals |
| `ConvertReport`, `ReportText` | `ConvertReport.swift` | The Wavetables page's report after converting (alert title and text, log text); the item-line form every report uses |
| `FrameSizeFit`, `WavetableSketch`, `CountWords` | own files | Frame-size heuristic ("likely", never applied alone), preview thumbnails, report phrasing |

App (`Sources/PgdataPacker/`): `main.swift` (AppDelegate, menus, window, Sparkle, Help links),
`AppState.swift` (all state, `ObservableObject`, main thread; `Section` = Pack, Unpack, Wavetables),
`ContentView.swift`, `PackView.swift`, `UnpackView.swift`, `ConvertView.swift`,
`ConvertDestination.swift`, `ConvertDetail.swift`, `RepointSheet.swift`, `NameCleanupSheet.swift`,
`Panels.swift` (AppKit open/save panels), `VisibleScrollers.swift`.

## 7. Where to look (task to files)

| Task | Start here | Then |
|---|---|---|
| Change how a `.pro` is parsed or written | `ProgramFile.swift`; FORMATS.md section 3 | `FixtureTests`, `RobustnessTests`, `fixtures/program-*.pro*` |
| Source ids, slot ranges, analog order | `SourceRef.swift`; FORMATS.md section 2 | `FormatTests.swift` (`SourceRefTests`) |
| `.pgdata` layout, packing, unpacking | `UnifiedProgram.swift`, `PackUnpack.swift`; FORMATS.md section 4 | `fixtures/unified.pgdata*`, `tw3pg repack`, `tw3pg compare` |
| `.wt` values, mipmap chain, P-table differences | `WavetableFile.swift`; FORMATS.md section 5.1 | `WavetableFramesTests`, `Resampling.thirdWaveMipmapChain` |
| `.bin` fields and versions | `Multisample.swift`; FORMATS.md section 5.2 | `fixtures/multisample.bin*` |
| Older-program conversion | `ProgramConverter.swift`; FORMATS.md section 6 and appendix | `ConverterTests`, `fixtures/program-2022-layout*`, `tw3pg convert`, `tw3pg convertcheck` |
| Factory tables, U48–U55 history | `FactoryLibrary.swift`, `FactoryHistory.swift`, `FactoryCatalog.swift` (generated) | `FactoryLibraryTests`; README "Factory wavetables" |
| Names, 31-character limit, file names | `ByteIO.swift` (`NameField`), `SafeFileName.swift`, `ExportNames`, `OutputNames`, `WriteNames.swift` | `SafeFileNameTests`, `WorkbenchTests` |
| Read another wavetable format | `Reading.swift` dispatch, a new `Read<Format>.swift`, `SourceFormat` | `ReadingTests`, `CorpusCaseTests`, `RoundTripTests`; WAVETABLES.md |
| Write for another synth | `OutputPreset` in `Wavetable.swift`, `Writing.swift`, `PresetInfo.swift` | `WritingTests`, `RoundTripTests`; WAVETABLES.md section 2; README destination table |
| Frame size decisions | `ReadWAV.swift`, `FrameSizeEvidence`, `FrameSizeFit.swift`; WAVETABLES.md section 3 | `ReadingTests`, `ReviewFixTests`, `FrameSizeFitTests`, `ReviewFixPlanTests` |
| Pack page behaviour (what each source will be, status lines, slot estimate) | `PackPlan` in `Workbench.swift` | `WorkbenchTests`; then `PackView.swift`, `AppState.swift` |
| Unpack page behaviour | `UnpackPlan` in `Workbench.swift` | `WorkbenchTests`; then `UnpackView.swift` |
| Wavetables page behaviour | `ConvertPlan.swift`, `ConvertReport.swift` | `ConvertPlanTests`, `ConvertReportTests`; then `ConvertView.swift`, `ConvertDetail.swift`, `ConvertDestination.swift` |
| Clean Up Names | `NameCleaner.swift` | `WorkbenchTests`; `NameCleanupSheet.swift` |
| Menus, About, Help links, updater | `main.swift` | `make-app.sh` (Info.plist keys) |
| Developer checks against real files | `Sources/tw3pg/main.swift` | README "Verification" |
| Format documentation | `docs/FORMATS.md`, `docs/WAVETABLES.md`, `Sources/*/*.docc/` | `fixtures/README.md` |

## 8. How to verify

Library tests (XCTest, one test target per library; tests use `@testable import`):

| Platform | Command |
|---|---|
| Linux, Windows | `swift test` |
| macOS (full Xcode 15 or later) | `./run-tests.sh` or `PGDATA_TESTS=1 swift test` |
| One test class | add `--filter <ClassName>` (e.g. `--filter FixtureTests`) |
| One library's tests | add `--filter <TargetName>` (e.g. `--filter PgdataPackerCoreTests`) |

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

## 9. House style for text (README, docs, DocC, app strings)

- "3rd Wave", never "Third Wave"; "Groove Synthesis" in full; "the 3rd Wave" or "your 3rd Wave",
  not "the synth".
- Standing behaviour in the present tense; single observations as "has been observed to …";
  inferences said to be inferences; never claim more than the evidence supports.
- The serial (Oxford) comma. "e.g.," or "for example" before parenthetical examples.
- No third-party sound-set, program, or author names in README, docs, or app text (code comments,
  tests, and screenshots may carry them).
- App vocabulary: add (files), pack, embed, unpack, convert; 3rd Wave functions in bold in
  README and FORMATS.md (e.g. **Import program**), in curly quotes in the app.
- Code comments that state a fact about the 3rd Wave cite the FORMATS.md section
  (e.g. "See section 2 of FORMATS.md").
- Plain, short words; one term for one thing (table, frame, frame size, interpolation, destination,
  "to convert"); nothing said twice in one view, report, or paragraph; counts that read naturally
  ("Both tables", "1 change"; see `CountWords`); labels that say exactly what they mean (name the
  company or document, not "the maker"); every distinct label actually different.
- **Language review before a build is handed over, docs are merged, or a release is made:** read
  every user-facing string and document that changed for accuracy against the evidence, currency
  after renames (page, column, and feature names), agreement of tense, number, case, and mood, and
  the rules above; fix, and report any change of meaning. Tests assert some strings
  (`ConvertPlanTests`, `ConvertReportTests`, `WorkbenchTests`, `ReadingTests`): keep them in step.

## 10. Recipes

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
`fileExtension`; `PresetInfo.swift`: `shortTitle`, `specLine`, `distinction`, `recordsInterpolation`);
the app lists presets through `OutputPreset.Group.presets`, so no UI list needs editing; add
`WritingTests` and `RoundTripTests` cases; add a row to `docs/WAVETABLES.md` section 2 with a
footnoted source and to the README destination table; leave `testedIn` empty.

**Add a plan feature** (Pack, Unpack, or Wavetables page): put the decision in
`PgdataPackerCore` (`PackPlan`, `UnpackPlan`, or `ConvertPlan`), test it in `WorkbenchTests` or
`ConvertPlanTests` (reader and writer are injectable in `ConvertPlan`), then show it from the view
in `Sources/PgdataPacker/`. State lives in `AppState`; the plan is recomputed from it.

**Change the UI**: edit `Sources/PgdataPacker/*.swift` only; keep imports behind `#if canImport`;
no new top-level names that collide with the libraries; build with `./make-app.sh debug` on a Mac.
Wording follows section 9. Reports go through `AlertPresenter.show` in `ContentView.swift`, which
adds the copy icon beside the title; use it rather than a new alert.

**Record a format finding**: change the code and `docs/FORMATS.md` together; add a footnote giving
the evidence (model, OS version, steps, files, or the Groove Synthesis document and section); if a
reader or writer changed, regenerate `fixtures/`; if it is only an inference, say so in both places.

**Releases** (owner only): `VERSION` in `make-app.sh` is the app and library version; tags are
`v<VERSION>`, and `PgdataFormats` is versioned with the app (tags `v1.0.5` and on). The Help menu
opens the README at the running version's tag. The build number is the commit count. A published
tag is never moved. Signing, notarization, and the Sparkle appcast are the owner's steps and need
credentials that are not in the repository.

## 11. Known limits and open questions

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
- `fixtures/` exercise structure, not sound, and have not been loaded on a 3rd Wave.
- The app is macOS-only; CI compiles it but has no tests for it. A Linux or Windows front end would
  build on `PgdataPackerCore`, whose API may change between versions more than `PgdataFormats`'s.

## 12. Glossary

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
| User slot | P36–P47 and U56–U63 (8 U and 12 P slots for the user's own tables) |
| P table | PPG-style wavetable: 64 waves of 128 samples, each point stored with its difference to the next (16,384 values) |
| U table | Wavetable of 64 waves of 1,024 samples followed by its mipmap chain (131,072 values) |
| Frame | One cycle of a waveform; a wavetable is a sequence of frames of equal length |
| Frame size | Samples per frame (128, 1,024, 2,048, …); for WAV and FLAC sources it is settled by metadata, file name, sidecar, markers, or length (`FrameSizeEvidence`), or left to the user |
| Mipmap chain | The band-limited copies of a U table's 64 waves at 512, 256, 128, 64, and 64 samples (65,536 values) that follow the waves in a `.wt` |
| Fingerprint | 64-bit FNV-1a of a table's values as little-endian float32 (`fnv1a64`); how factory tables and duplicates are recognised |
| Preset (`OutputPreset`) | A conversion destination (3rd Wave U or P table, Serum-style WAV, MiniFreak V, Tonverk, Phase Plant, Surge XT, WaveEdit) |
| Plan | A `PgdataPackerCore` value describing what a page will do (`PackPlan`, `UnpackPlan`, `ConvertPlan`) |
| Layout | A program's values per part, floats per part, and globals (current: 181/137/182); older layouts are converted |
