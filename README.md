<img src="Resources/AppIcon.png" width="128" alt="pgdata Packer app icon">

# pgdata Packer

*for the Groove Synthesis 3rd Wave*

A macOS app that packs Groove Synthesis 3rd Wave programs (`.pro`) together with the wavetables
(`.wt`) and multisamples (`.bin`) they use into unified program files (`.pgdata`), unpacks
`.pgdata` files back into those parts, and converts wavetables between the 3rd Wave's formats and
those of other synths.

Not affiliated with or endorsed by Groove Synthesis. Everything here was worked out from files and
checked on an 8M and a 24M, both running OS 2.0d. The Formats and Tests sections say what was
confirmed on the 3rd Wave and what is inferred.

**Building something for the 3rd Wave?** The file formats are (unofficially) documented as far as
they're understood, and the libraries behind this app, test files, and a developer tool are free to
use under the MIT licence: see [For developers](#for-developers).

![The Pack page: the programs added on the left; for the selected program, what each oscillator source will play and whether it is embedded; below, the wavetables and multisamples added and the slots they go to](docs/pack-window.png)

## Download

Download `pgdata-Packer-<version>.zip` from the
[latest release](https://github.com/adambier/3rd-wave-tools/releases/latest), unzip it, and move
the app wherever you like, for example to your Applications folder. The app is signed with a
Developer ID and notarized by Apple, so it opens like any other app, on Apple Silicon and Intel
Macs. Requires macOS 13 or later.

The app updates itself, using [Sparkle](https://sparkle-project.org): on its second
launch it asks whether to check automatically, and **Check for Updates…** in the app menu checks
at any time. In the Help menu, **pgdata Packer Help** opens this page and **File Format Reference**
the format reference; **Release Notes** opens the notes for the version you have.

## Build

Or build it yourself; it takes a minute. Requires macOS 13 or later and the Xcode command-line
tools (`xcode-select --install`; Xcode 14.1 or later, for the macOS 13 SDK). There is no Xcode
project.

```
git clone https://github.com/adambier/3rd-wave-tools.git
cd 3rd-wave-tools
./make-app.sh          # builds "pgdata Packer.app" in this folder
open "pgdata Packer.app"
```

The first build downloads Sparkle from GitHub (checked against its SHA-256 and kept in `build/`),
so it needs a network connection; later builds work offline. An app built on your own Mac is
signed only for that Mac (an "ad-hoc" signature); it opens normally there, and macOS warns about
it elsewhere.

The tests (`./run-tests.sh`) need a full Xcode installation (15 or later) on a Mac; on Linux and
Windows, `swift test` runs them directly. (On a Mac, `Package.swift` includes the test targets only
when `PGDATA_TESTS=1` is set, which the script does, so that a plain `swift build` works with the
command-line tools alone. Such a build has no Sparkle, so no **Check for Updates…**.)

## Using it

The window has two pages, **Pack** and **Unpack**, chosen in the toolbar or from the View menu
(⌘1, ⌘2), and a third, **Wavetables** (⌘3), that is still being tested: View › **Show
Under-Development Features** adds it, with the audio output control that goes with it. There is
nothing else to set up.

Files and folders can be dropped onto a page, chosen with **Add Files or Folders…** (⌘O) in the
File menu or on the page, or dropped onto the app's icon in the Dock, which sends each file to the
page that reads it (the app does not claim any of these file types as its own). Selected rows go
with **Remove Selected** or Edit › **Delete** (the Delete key); **Remove All…** clears a page; both
can be undone with Edit › **Undo**. Files on disk are never touched by either. The status bar
shows the last thing the app did, and **Show Log** (⌥⌘L) everything it has done this session.
Every report or list of problems the app shows has a copy icon beside its title that puts the text
on the clipboard.

### Factory wavetables

The app never embeds factory wavetables. A program that uses a factory slot (P00–P35, U00–U55)
lists the slot without data, and the 3rd Wave that loads the file plays its own factory table, unless
you add a different table for that slot (see Pack).

The app knows each factory table by name and by a fingerprint of its content (built in from Groove
Synthesis's factory `.wt` files; only names and fingerprints are stored). It uses them to:

- show factory slot names (e.g., "U00 Additive_Bell_17");
- treat an added file that is identical to the factory table of its slot as that table (listed,
  not embedded), for example a table unpacked from the 3rd Wave's own export, which carries every
  table a program uses;
- leave factory tables out of the free-slot estimate, since the 3rd Wave reuses them when it has them;
- skip, when unpacking, tables identical to the factory table in their slot, and never offer
  factory tables for renaming.

#### U48–U55

These joined the factory set in 2025, alongside OS 1.9 (which also brought `.pgdata`); the 8M's
factory programs use them, so every 8M has them. 24K and 24M owners download them from Groove
Synthesis's support site (after logging in) and load them with Global → **Bulk wavetable
import**. The app assumes the 3rd Wave that loads a `.pgdata` has them.

Before 2025 those were user slots, and some older program sets used them for their own tables,
shipped as `.wt` files named with the slot (e.g., `U48 Warm Pad.wt`). So in a program saved before
OS 1.9, U48–U55 are treated like user slots: missing until you add the table, which is then
embedded and goes into a free slot on import. A note with the program explains this and the three
ways to fix it: add the author's table, point the oscillators elsewhere, or choose the factory
table anyway from the Plays menu.

A program counts as saved before OS 1.9 when its format is older than `W3_PROG_5` or its float
block has fewer than 544 values. Every program saved since OS 1.9 that has been seen has 544 or
more (544 from OS 1.9, as in Groove Synthesis's factory banks from August 2025; 548 from OS 2.0);
every older set has fewer. The file carries no date, so this is an inference from the layout.

A table from a user slot (P36–P47, U56–U63) or a multisample that a program uses is always
embedded from a file you add, because whoever loads the file will not have the same user slots or
sample memory.

### Pack

Drop `.pro` files, plus the `.wt` and `.bin` files they use (folders work too). For each program
the app lists its oscillator sources and what each will be:

- **a file you added and assigned to that slot,** since it is what the program's author supplied.
  A file named with its slot (e.g., `U48 Warm Pad.wt`, `S010_Strings.bin`) is assigned to it
  automatically; assign others in the Slot column. One assignment serves every loaded program that
  uses the slot, with two safeguards for factory slots: a file in U48–U55 is used only by programs
  saved before OS 1.9 (later programs keep the factory table, and can still choose the file in the
  Plays menu), and a file in any other factory slot is used but flagged, in the program's status and
  in the report after packing, as replacing the factory table;
- **for a factory slot: the factory table,** listed but not embedded. An added file identical to it
  is listed the same way;
- **for a user slot or a multisample with no file added: missing.** The program is not written
  until you add the file or, for a wavetable, point the oscillators elsewhere.

You can change any choice from the Plays menu.

A line under the program name sums it up: what will be embedded, the size of the `.pgdata`, and
how many free slots the 3rd Wave will need; or what the program still needs before it can be packed.
The list on the left can be filtered by name or location, or limited to programs needing
attention.

#### Checks

- A program in a layout not seen before (a format other than `W3_PROG_3` to `_5`, or an unusual
  number of values per part) gets a warning: the app finds the oscillator sources from the layout,
  so check them, and check the program on the 3rd Wave after importing.
- A source number outside every known range shows as an unknown source, and the program is not
  written until those oscillators are pointed elsewhere.
- Content that does not look like the 3rd Wave's own is flagged: a wavetable whose samples go
  beyond ±1, or a multisample whose samples are out of key order or carry values outside the ranges
  Groove Synthesis specifies.
- A file that cannot be read at all (empty, cut short, or not the kind its extension says) is
  reported once, with the reason, and left out.

#### Older programs

**Programs in an older format are converted as they are packed.** A program saved by older
firmware (`W3_PROG_3`, `W3_PROG_4`, or a `W3_PROG_5` from before OS 2.0) is brought up to the
current format in the same way the 3rd Wave's **Import program** function converts it, and a line
under the program name says so. This matters because **Import unified program data file** does
only part of that conversion, and a 2022 factory program packed unconverted plays silently. The
converter was checked against 599 conversions made by an 8M and a 24M and matches the 3rd Wave's
own result value for value, except for eight 2022 factory programs that the 3rd Wave corrects
individually on import, by name (see [`docs/FORMATS.md`](docs/FORMATS.md#6-converting-older-programs)).
The packed program keeps all four parts, so one file works on every model: an 8M fits it to its
two parts when it imports it.

#### Changing what oscillators play

**Play Something Else…** in the Plays menu (or **Choose What to Play…**, the first choice when a
wavetable is missing) opens a sheet. Check the oscillators to change, then pick what they should
play:

- a file you added (listed first). When the program needs a slot that has nothing yet (e.g., U57),
  the sheet preselects an added file that has no slot yet and assigns it to that slot, so the
  oscillators stay as they are;
- any factory P or U slot (searchable by slot or name);
- an analog wave (A00–A06).

The Source column then shows, for example, **U01 → U56**, with a button to point it back. Only the
`.pgdata` changes; the `.pro` is not modified. Multisample oscillators are not repointed.

![The sheet for changing what oscillators play: oscillators to change on the left, and on the right the files added, the factory slots, and the analog waves](docs/change-what-plays.png)

Parts 3 and 4 play only on the 4-part models (24K, 24M). In every program saved on an 8M seen so
far, they hold filler (P02, U01, and an analog wave).

Added files that no program uses are flagged in the files table ("Not used"; the tooltip says
why), and listed again after packing. **Point a Program Here…** opens the same sheet for the file.

#### Names

The program name at the top of the detail area can be edited. **Clean Up Names…** proposes tidier
names for the programs and for the wavetables and multisamples you added (never factory
wavetables):

- slot numbers removed from the start or end (e.g., "U48 Warm Pad" → "Warm Pad", "S010_Strings_"
  → "Strings", "B5-P003 Name" → "Name");
- underscores to spaces;
- title case for names written entirely in capitals or entirely in lower case (e.g., "GLASS
  BELLS" → "Glass Bells"). Names that already mix cases keep their capitals.

Within title case:

- words with digits stay as they are (e.g., JP8, TB303);
- words with no vowels count as acronyms (e.g., PWM, PPG, FM); Y counts as a vowel, so "SYNTH"
  becomes "Synth";
- words on an editable list keep a fixed spelling (e.g., LFO, MIDI, LoFi);
- short joining words are lower case except at the start (e.g., "DRUMS AND AMPS" → "Drums and
  Amps"), and the parts of a hyphenated word are cased separately (e.g., "LO-FI PAD" → "Lo-Fi
  Pad").

Every proposal is shown, can be edited, and can be unchecked. New names go into the `.pgdata` and
its file name. Source files are not changed, and unpacking keeps names as they are.

![Clean Up Names: options at the top, and each current name with its proposed new name](docs/clean-up-names.png)

#### Name limits

Name fields hold 31 characters, and the 3rd Wave displays all 31 for programs, wavetables, and
multisamples. The fields hold single-byte (Latin-1) characters only. A name they cannot hold is
changed the same way wherever the app writes one, here and in the 3rd Wave tables the Wavetables
page writes: a line break becomes a space; a letter outside Latin-1 keeps its base letter and
loses its accents (e.g., "Ő" becomes "O"); any other character outside Latin-1 (an en dash, curly
quotes, an emoji) becomes "?"; and the name is then shortened to 31 characters. Every change is
flagged next to the name, in the program's notes, and in the report after packing, with the name as
it will be written.

#### Writing

Every program gets a `.pgdata`, even one that uses only factory tables and analog waves. A
`.pgdata` that embeds nothing is usually smaller than its `.pro` (about 10–30% for the factory
programs, since six-decimal floats become 4-byte words), though a program with a long sequencer
section can come out a little larger. Each embedded U table adds about 0.5 MB, each P table about
65 KB, and a multisample its audio.

**Pack Selected…** and **Pack All…** (⇧⌘E) ask for a folder. If some programs can't be packed yet,
the app asks first whether to pack the others. Existing files are never replaced without asking,
and the report at the end can open the folder in the Finder.

![The report after packing: every program was converted from an older format, and seven added files were left out because no packed program uses them](docs/pack-report.png)

Files are named in Groove Synthesis's own pattern, with the program location first:
`B05P87_Glass_Bells.pgdata`, as in Groove Synthesis's `B05P06_Glass_Cow_Bell_Transients.pgdata`.

- The location comes from the `.pro` file name (e.g., `B05P100.pro`), since a `.pro` does not
  record it. Groove Synthesis's older layout of a `Bank 1` folder holding `001.PRO` to `100.PRO`
  is read too.
- The prefix keeps the 3rd Wave's alphabetical bulk import in program order.
- As in the 3rd Wave's own exports, spaces become underscores and everything other than ASCII letters,
  digits, hyphens, and underscores is dropped (e.g., "Big Bass (MW)" → `Big_Bass_MW`). This affects
  the file name only, not the program name inside it.
- A batch that includes a program 100 uses three digits throughout (e.g., `B05P087_…`,
  `B05P100_…`). The 3rd Wave itself writes `B05P09_…` and `B05P100_…`, but its bulk import takes
  files in plain character order, where `B05P100` sorts between `B05P10` and `B05P11` (checked on a
  24M), which would put it out of order.
- If any program being written has no location in its file name (for example, a renamed file, or a
  `.pro` written by Unpack), all of them are numbered by their place in the batch instead (e.g.,
  `001_…`, `002_…`).

### Unpack

Drop `.pgdata` files. Each becomes a `.pro` named after the program, a `.wt` per embedded
wavetable named with its slot (e.g., `U57_Warm Pad.wt`), and a `.bin` per multisample named as
Groove Synthesis's sample library names them (e.g., `S010_Strings.bin`).

When a batch writes any wavetables or multisamples, the files go into the folders your 3rd Wave's
USB drive uses: `PROGRAMS` for `.pro`, `WAVES` for `.wt`, and `AUDIO` for `.bin`, so you can copy
them onto the drive as they are. A batch of programs alone is written straight into the folder
you choose.

A box above the file list says what the program needs on your 3rd Wave: which multisamples go
into which S slots before you import the `.pro`, and which slots the program plays from your 3rd
Wave rather than from the file. It appears only when there is something to say. Select several
files to see everything they will produce in one list, with the program each file comes from.

![The Unpack page with five .pgdata files selected: the multisamples to import first, the factory slots their programs play from your 3rd Wave, and each file they will produce with its program, file name, and contents](docs/unpack-window.png)

Uncheck anything you don't want, or rename it (double-click the file name), before **Unpack
Selected…** or **Unpack All…**.
Wavetables identical to the factory table in their slot are skipped by default (**Skip factory
wavetables**): the 3rd Wave's own
export embeds factory tables too, and a repack lists them anyway. Unpacked names are kept as they
are.

A `.pgdata` does not record the program's format. One that holds a program in an older layout
(built by another tool; the 3rd Wave's own exports are always current) is converted as it is
unpacked, in the same way as in Pack, and the box says so. The app works out the old format from
the layout, so the unpacked `.pro` is always in the current format, `W3_PROG_5`.

### Wavetables

Drop wavetable files or folders: WAV and FLAC wavetables (the kinds Serum, Vital, Phase Plant,
and many other synths use), the 3rd Wave's `.wt` and `.pgdata` files, and Surge `.wt` files.
Folders are searched, and files without wavetables are passed over. Each table is listed once,
with any identical copies noted beside it, its frames and frame size, and what converting it
changes. Groove Synthesis's factory tables are marked, and for a 3rd Wave destination they start
unchecked, since the app assumes your 3rd Wave already has them (see
[Factory wavetables](#factory-wavetables)). Names are edited in the table (double-click a row);
**Clean Up Names…** works as on the Pack page.

The page converts existing wavetables; it does not make wavetables from other audio, which is
what the 3rd Wave's **Wave Maker** does. Wave Maker also imports a Serum wavetable directly; this
page adds other formats and frame sizes, many tables at once, and Send to Pack.

#### Frame sizes

The Input column says where each table's frame size comes from. A size the file's contents state
(a chunk, a header, or a format that fixes it) is taken as it is. One the page estimated, from a
`_wt<N>` tag in the file name, a Serum `.txt` beside the file, or markers, is the default of a
choice: click it to see every size the length allows, each drawn so the one that cuts the frames
in the right place is visible. When the file states nothing, the page assumes 2,048 samples per
frame, the Serum-style size, and says so. Two lengths are left open, since they are also well-known
tables at other sizes: 8,192 samples (64 × 128, a PPG-style table, or 4 × 2,048) and 16,384 (64 ×
256, a WaveEdit bank, or 8 × 2,048); for those the page assumes the size whose frames are most
alike from one to the next, marked "likely" in the chooser, or waits for a choice when no size
stands out. With several tables selected, the preview offers one frame size for those whose size
is assumed or estimated, from the sizes all of them allow (⌘A selects every table). For the rare
WAV or FLAC whose chunk states the wrong size, **Override Frame Size…** in the preview opens the
same chooser. The counts above the table jump to the first table that still needs a size or cannot
be split into frames; **Show only tables that can't be converted yet** filters to them.

#### Destinations

| Destination | What the Wavetables page writes |
|---|---|
| 3rd Wave P table | a `.wt` of 64 frames of 128 samples, optionally with the PPG's four standard waveforms at 60–63 |
| 3rd Wave U table | a `.wt` of 64 frames of 1,024 samples, with its mipmap chain |
| Serum, Vital, Pigments | a 32-bit float WAV of up to 256 frames of 2,048, recording the interpolation |
| MiniFreak V | the same, with at most 64 frames, for MiniFreak V to send to a MiniFreak |
| Elektron Tonverk | a 32-bit float WAV of up to 64 frames, its frame size and interpolation in its name |
| Phase Plant | a 32-bit float WAV of exactly 256 frames of 2,048 |
| Surge XT | a Surge `.wt` |
| WaveEdit, E370 | a 16-bit WAV of 64 frames of 256 |

The destination applies to every table marked to convert. The chosen row says why its format is
separate and, in orange, what is open about it: that converting to it has not yet been tested
(none has), and anything its sources leave open that the tables to convert bring about. The book
icon beside each row (under **Sources**) opens the documents the format rests on; a green seal in
its place marks a destination that has been tested. While any destination is untested, the page
carries a notice that wavetable conversion is under development.
[`docs/WAVETABLES.md`](docs/WAVETABLES.md) describes what each destination expects, with sources.

#### Options

Shown when a choice applies to the destination and the tables to convert:

- When the destination needs a different number of frames, **Original Frames Only** keeps evenly
  spaced originals (the first and last among them) for fewer frames and repeats each original in
  order for more, making no new waveforms; **Crossfade New Frames** makes each new frame by
  crossfading its neighbours.
- **Interpolation**, for formats whose file records it: an interpolation method, crossfade or
  spectral, or none (no interpolation: the destination steps from frame to frame). The Interpolation
  column shows what each table's own file specifies; by default each table keeps that, and a
  table whose file says nothing gets crossfade.
- Tonverk's frame size, and the PPG's four standard waveforms for P tables.

#### Preview

The pane below the table shows the selected table: the input and the result stacked frame by
frame, with the interpolation drawn between frames where a file records one; its file, its frame
size and what that rests on, its interpolation, and what converting changes. The **Frame** slider
sweeps through the table and draws the cycle there large, input and result together. **Listen** plays that cycle, following the slider, at the pitch chosen
beside it (a piano key with its number; A3, 220 Hz, to start) through the device chosen under
**Audio Output**, the speaker icon at the right of the toolbar.

#### Converting

**Convert…** writes the files into a folder you choose (3rd Wave tables into a `WAVES` folder
inside it) and reports everything it changed; it never replaces an existing file. For a 3rd Wave
destination, **Send to Pack…** does the same and then adds the `.wt` files to the Pack page, to
embed in programs. The page warns when more tables are to be converted than the 3rd Wave's user
slots hold (P36–P47 and U56–U63; the factory tables fill the rest), since the 3rd Wave then offers
to overwrite its last slots.

To load the `.wt` files on the 3rd Wave, copy the `WAVES` folder onto its USB drive and use
Global → **Bulk wavetable import**, or add them to the 3rd Wave Terminal app's library and sync.

## On the 3rd Wave

Checked on an 8M (OS 2.0d), and most points on a 24M as well
([`docs/FORMATS.md`](docs/FORMATS.md#7-what-the-3rd-wave-does-on-import) says which). What the
3rd Wave does when it imports a file:

- **A table or multisample the 3rd Wave already has** (same content, in any slot, whatever its
  name) is reused. No slot is used, and the 3rd Wave keeps its own name for it.
- **A new table or multisample** goes into a free slot, and the program is pointed there. The slot
  number in the file is only a label. With no free slot, the 3rd Wave offers to overwrite its last
  ones; blank placeholder tables count as used. The Pack page shows how many free wavetable slots a
  program may need; each embedded multisample the 3rd Wave does not already have also takes a free
  S slot. (For multisamples, the 3rd Wave's message says it erases the most recently loaded
  samples; not tried here.)
- **A table or multisample listed without its data** plays whatever is in that slot on the 3rd Wave,
  with no warning; an empty sample slot plays silence. That is why multisamples are always
  embedded.
- **Programs in an older format** are converted on import: fully by **Import program** and **Bulk
  program import**, only in part by **Import unified program data file**. That is why this app converts them before
  packing (see Pack). Details are in
  [`docs/FORMATS.md`](docs/FORMATS.md#6-converting-older-programs).

> [!WARNING]
> **Unplug the USB cable from your computer while the 3rd Wave exports.** With the drive mounted on
> a computer at the same time, exports have been observed to write empty files. Plug it back in when the export has
> finished.
>
> **Empty the `PROGRAMS` folder before exporting.** An export onto an existing file of the same name
> has been observed not to shorten it (once, on a 24M), so a longer old file leaves its tail behind
> the new program. (The app
> recognises such a file by its header, drops the leftover values when packing or unpacking it,
> and says so.)
>
> **Leave only one `.pgdata` in `PROGRAMS` when using Import unified program data file.** It takes
> the first file in alphabetical order without asking.

## For developers

pgdata Packer is one tool; a major aim of this project is to help make it easier to build others,
in any language. Everything here is open source under the MIT licence.

- **The format reference.** [`docs/FORMATS.md`](docs/FORMATS.md) describes the structure of the
  3rd Wave's four file formats, for someone implementing them for the first time, and how the 3rd
  Wave behaves when it imports them. It is enough to read, write, pack, unpack, convert, and rename
  programs, wavetables, and multisamples. **What most of a program's values mean is not yet
  known:** fewer than 60 of a program's roughly 1,450 values have an identified meaning, so it does
  not yet support tools that create sounds or edit a program's settings. Footnotes give the evidence for each statement (a test on the 3rd Wave, or
  Groove Synthesis's own documents), and what is still unknown is listed at the end.
- **Test files.** [`fixtures/`](fixtures/) holds a small file of each kind, each with a JSON file
  of what it should parse to, so a new reader or writer can be checked without the 3rd Wave at hand.
  They are synthetic, so they can be used freely.
- **A Swift library.** `PgdataFormats` reads and writes every format byte for byte, packs and
  unpacks `.pgdata` files, converts older programs as the 3rd Wave does, and recognises Groove
  Synthesis's factory wavetables. It depends only on Foundation, and its tests run on macOS, Linux,
  and Windows. Add it to a Swift package with
  `.package(url: "https://github.com/adambier/3rd-wave-tools", from: "1.0.5")` and the product
  `PgdataFormats`. Its documentation, with a getting-started guide, is at
  [adambier.github.io/3rd-wave-tools](https://adambier.github.io/3rd-wave-tools/documentation/pgdataformats/).
  The library is versioned with the app (tags `v1.0.5` and on).
- **Other synths' wavetable formats.** `WavetableFormats`, the package's second library, finds
  wavetables in files (WAV and FLAC with their metadata, Surge `.wt`, and the 3rd Wave's `.wt` and
  `.pgdata`), resizes them, and writes them for the destinations the Wavetables page offers. Like
  `PgdataFormats`, on which it builds, it depends only on Foundation and is tested on macOS, Linux,
  and Windows.
  [`docs/WAVETABLES.md`](docs/WAVETABLES.md) describes the formats, with sources, and the
  library's documentation is at
  [adambier.github.io/3rd-wave-tools](https://adambier.github.io/3rd-wave-tools/documentation/wavetableformats/).
  It is new in 1.1 and provisional: its API may change until a 1.1.x release, once its
  destinations have been tested in their synths.
- **The app's logic, for other platforms.** `PgdataPackerCore`, the package's third library,
  holds pgdata Packer's own decisions without its user interface: pack, unpack, and convert plans,
  factory table handling, file names, and Clean Up Names. A command-line tool, or an app for Windows or
  Linux, can use it to behave exactly like pgdata Packer. Its API may change between versions more
  than `PgdataFormats`'s.
- **A command-line tool.** `tw3pg` (in `Sources/tw3pg`) inspects files, checks that they round
  trip, unpacks and repacks `.pgdata` files, converts older programs, and lists what the
  Wavetables page would find in a folder of wavetable files: `swift run tw3pg inspect <file>`.
- **Using an AI coding tool?** Give it [`AGENTS.md`](AGENTS.md): a terse map of the code, the
  rules it must keep (byte-exact round trips, Foundation-only libraries, the single-module app
  build), where each kind of change goes, and how to verify it. Claude Code reads it through
  `CLAUDE.md`; other tools read `AGENTS.md` directly or can be pointed at it.
- **Contributions.** Corrections to the format reference are the most valuable contribution,
  whether from tests on the 3rd Wave or from knowing better; so are bug reports with the files that
  show them, and word of tools built on this. [`CONTRIBUTING.md`](CONTRIBUTING.md) explains how.

## Formats

[`docs/FORMATS.md`](docs/FORMATS.md) is the full reference (see For developers above). In brief:

- **.pro**: text, one value per line: the format tag (`W3_PROG_3` to `_5`), the name, four sizes
  (integers and floats per part, global values, sequence events), then four integer part blocks
  (each starting with its three oscillator source ids), four float part blocks, the globals, and the
  sequence events.
- **.pgdata**: `W3_UNIPROG_1`, a table of the sources the program uses (each with its embedded `.wt`
  values or multisample, or listed without data), then the program name and the `.pro` values as
  32-bit words. It has no format tag. The container is fully known; the program values inside it
  are the `.pro`'s, and most of their meanings are not.
- **.wt**: text: `PNAME` or `UNAME`, the name, then one float per line.
- **.bin**: `W3_MSAMPLE_<v>`, a slot name and up to eight samples with their settings and 16-bit
  audio.
- **Source ids**: each oscillator stores what it plays as one number. The ranges are irregular, and
  the seven analog waves are not numbered in the order the 3rd Wave lists them.

## Verification

Run against about 2,700 real files: Groove Synthesis's factory banks (8M, and 24-voice versions 1
and 2b), sample library, and OS 1.8 example files, plus nine third-party program sets. These checks
use the `tw3pg` developer tool, which keeps each table as it was; the app's own repack lists
factory tables instead of embedding them, so its output differs there by design.

- Every `.pro`, `.wt`, `.pgdata`, and v5 `.bin` reads and rewrites byte for byte (v1 and v4 `.bin`
  files are upgraded to v5).
- All 221 `.pgdata` files unpack and repack identically, up to the `.pro` format's six-decimal
  float precision (the 3rd Wave's own `.pro` export has the same limit).
- All 325 embedded wavetables compared are bit-identical to the `.wt` files they came from.
- Packing Groove Synthesis's factory `.pro` files reproduces the structure of their `.pgdata` (19
  for the 8M, 19 for the 24-voice models): the same sources, in the same order, with the same
  samples. What differs: Groove Synthesis's files embed the factory tables and this app lists them
  without data; a few values that appear to be state captured at export time (one per part); and
  the leftover source references from unused parts, which this app lists and Groove Synthesis's 8M
  exporter does not (their 24-voice files do). One 24-voice program's `.pro` and `.pgdata` differ
  in real settings; they appear to be different editions.

## Tests on the 3rd Wave

Besides the import behaviour above, name lengths and the 3rd Wave's own export file names were
checked on the 3rd Wave. The conversion of older programs was worked out from 599 programs
bulk-imported and exported again on an 8M and a 24M, and programs converted and packed by this
app were imported on both. The 3rd Wave's exports were also
unpacked and repacked byte for byte with `tw3pg`. The test `.pgdata` files are built with `tw3pg`
from files that are not included here (a Groove Synthesis factory program and one of its `.wt`
files, two third-party programs, and a small `.bin`).

Still unknown: how the 3rd Wave writes non-ASCII letters in file names; whether a 24K converts
older programs exactly as the 24M does; and the meaning of most program values.

## Layout

```
Sources/PgdataFormats/      the library (the package's PgdataFormats product): formats, packing,
                            conversion; no UI; Foundation only (tested on Linux, macOS, and Windows)
  SourceRef.swift             source-id mapping
  ProgramFile.swift           .pro
  WavetableFile.swift         .wt
  Multisample.swift           .bin and the shared sample record
  UnifiedProgram.swift        .pgdata
  PackUnpack.swift            Packer / Unpacker
  ProgramConverter.swift      older programs to the current layout, as Import program converts them
  FactoryLibrary.swift        factory wavetables by slot, name, and fingerprint
  FactoryCatalog.swift        factory table names and fingerprints (generated)
  ByteIO.swift                byte reading and writing, 32-byte name fields
  SafeFileName.swift          file names safe on macOS, Windows, and FAT/exFAT drives
  PgdataFormats.docc/         the library's documentation pages
Sources/WavetableFormats/   other synths' wavetable formats (the package's WavetableFormats
                            product): finding tables in files, resizing, writing; Foundation only
  Wavetable.swift             the shared types: tables, presets, options
  Read*.swift, Reading.swift  detection and readers (WAV, FLAC, Surge .wt, 3rd Wave .wt and .pgdata)
  Write*.swift, Writing.swift writers for each destination
  Resampling.swift, FFT.swift frame size and frame count changes, the 3rd Wave's mipmap chain
  WavetableFormats.docc/      the library's documentation pages
Sources/PgdataPackerCore/   the app's own decision logic, no UI (the package's PgdataPackerCore
                            product): pack, unpack, and convert plans, output file names,
                            Clean Up Names, the Wavetables page's report
Sources/PgdataPacker/       the app (SwiftUI)
Sources/tw3pg/              developer tool: inspect, roundtrip, unpack, repack, compare, wtcheck,
                            wtscan, wtdump, factory-catalog, pack, convert, convertcheck, and the
                            3rd Wave-test builders
Tests/                      unit tests, one target per library (./run-tests.sh)
fixtures/                   test files with what each parses to, for other implementers
Resources/                  app icon, drawn by tools/make-icon.py (needs cairosvg and Pillow)
docs/                       FORMATS.md (format reference), WAVETABLES.md (other synths' wavetable
                            formats), and the screenshots used in this README
make-app.sh                 builds, signs, and notarizes the app; embeds Sparkle; writes the appcast
.github/workflows/          tests on Linux, macOS, and Windows; publishes the libraries' documentation
```

## License

MIT; see `LICENSE`. "3rd Wave" and "Groove Synthesis", and the names of other synths and their
makers, are used only to say what this works with; this project is not affiliated with or
endorsed by Groove Synthesis or any of them.
