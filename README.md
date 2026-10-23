<img src="Resources/AppIcon.png" width="128" alt="pgdata Packer app icon">

# pgdata Packer

*for the Groove Synthesis 3rd Wave*

A macOS app that packs Groove Synthesis 3rd Wave programs (`.pro`) together with the wavetables
(`.wt`) and multisamples (`.bin`) they use into unified program files (`.pgdata`), and unpacks
`.pgdata` files back into those parts.

Not affiliated with or endorsed by Groove Synthesis. Everything here was worked out from files and
checked on one 8M running OS 2.0d. The Formats and Tests sections say what was confirmed on
the 3rd Wave and what is inferred.

![The Pack page: the programs added on the left; for the selected program, what each oscillator source will play and whether it is embedded; below, the wavetables and multisamples added and the slots they go to](docs/pack-window.png)

## Build

There is no download: the app is not notarised with Apple (that needs a paid developer account),
and an app that isn't makes macOS show a security warning that has to be bypassed. Building it
yourself takes a minute and avoids that; an app built on your own Mac opens normally.

Requires macOS 13 or later and the Xcode command-line tools (`xcode-select --install`). There is no
Xcode project.

```
git clone https://github.com/adambier/pgdata-packer.git
cd pgdata-packer
./make-app.sh          # builds "pgdata Packer.app" in this folder
open "pgdata Packer.app"
```

Move the app wherever you like afterwards, for example to your Applications folder.

The tests (`./run-tests.sh`) need a full Xcode installation on a Mac; on Linux, `swift test` runs
them directly.

## Using it

The window has two pages, **Pack** and **Unpack**. There is nothing to set up.

### Factory wavetables

The app never embeds factory wavetables. A program that uses a factory slot (U00–U55, P00–P35)
lists the slot without data, and the 3rd Wave that loads the file plays its own factory table, unless
you add a different table for that slot (see Pack).

The app knows each factory table by name and by a fingerprint of its content (built in from Groove
Synthesis's factory `.wt` files; only names and fingerprints are stored). It uses them to:

- show factory slot names (e.g., "U00 Additive_Bell_17");
- treat an added file that is identical to the factory table of its slot as that table (listed,
  not embedded), for example a table unpacked from the 3rd Wave's own export, which carries every
  table a program uses;
- leave factory tables out of the free-slot estimate, since a 3rd Wave that has them reuses them;
- skip, when unpacking, tables identical to the factory table in their slot, and never offer
  factory tables for renaming.

**U48–U55.** These joined the factory set in 2025, alongside OS 1.9 (which also brought `.pgdata`).
The 8M ships with them. 24K and 24M owners download them from Groove Synthesis's support site
(after logging in) and load them with Global → Bulk wavetable import. The app assumes the 3rd
Wave that loads a `.pgdata` has them.

Before 2025 those were user slots, and some older program sets used them for their own tables,
shipped as `.wt` files named with the slot (e.g., `U48 Warm Pad.wt`). So in a program saved before
OS 1.9, U48–U55 are treated like user slots: missing until you add the table, which is then
embedded and goes into a free slot on import. A note with the program explains this and the three
ways to fix it: add the author's table, point the oscillators elsewhere, or choose the factory
table anyway from the Plays menu.

A program counts as saved before OS 1.9 when its format is older than `W3_PROG_5` or its float
block has fewer than 544 values. Every program saved since OS 1.9 that has been seen has 544
(Groove Synthesis's factory banks from August 2025 onwards); every older set has fewer. The file
carries no date, so this is an inference from the layout.

A table from a user slot (U56–U63, P36–P47) or a multisample that a program uses is always
embedded from a file you add, because whoever loads the file will not have the same user slots or
sample memory.

### Pack

Drop `.pro` files, plus the `.wt` and `.bin` files they use (folders work too). For each program
the app lists its oscillator sources and what each will be:

- **a file you added and assigned to that slot,** since it is what the program's author supplied.
  A file named with its slot (e.g., `U48 Warm Pad.wt`, `S010_Strings.bin`) is assigned to it
  automatically; assign others in the Slot column. One assignment serves every loaded program that
  uses the slot, with two safeguards for factory slots: a file in U48–U55 is used only by programs
  from before 2025 (later programs keep the factory table, and can still choose the file in the
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

A program in a layout not seen before (a format other than `W3_PROG_3` to `_5`, or an unusual
number of values per part) gets a warning: the app finds the oscillator sources from the layout, so
check them, and check the program on the 3rd Wave after importing. A source number outside every
known range shows as an unknown source, and the program is not written until those oscillators are
pointed elsewhere.

#### Changing what oscillators play

**Play something else…** in the Plays menu (or **Choose what to play…**, the first choice when a
wavetable is missing) opens a sheet. Tick the oscillators to change, then pick what they should
play:

- a file you added (listed first). When the program needs a slot that has nothing yet (e.g., U57),
  the sheet preselects an unused file and assigns it to that slot, so the oscillators stay as they
  are;
- any factory U or P slot (searchable by slot or name);
- an analog wave (A00–A06).

The Source column then shows, for example, **U01 → U56**, with a button to undo. Only the
`.pgdata` changes; the `.pro` is not modified. Multisample oscillators are not repointed.

![The sheet for changing what oscillators play: oscillators to change on the left, and on the right the files added, the factory slots and the analog waves](docs/change-what-plays.png)

Parts 3 and 4 play only on the 4-part models (24K, 24M). In every program saved on an 8M seen so
far, they hold filler (P02, U01 and an analog wave).

Added files that no program uses are flagged in the files table ("Not used by any added program", or
"another choice is made for U57" when the slot is filled some other way). **Point a program
here…** opens the same sheet for the file. Unused files are listed again after packing.

#### Names

The program name at the top of the detail area can be edited. **Clean Up Names…** proposes tidier
names for the programs and for the wavetables and multisamples you added (never factory
wavetables):

- slot numbers removed from the start or end ("U48 Warm Pad" → "Warm Pad", "S010_Strings_" →
  "Strings", "B5-P003 Name" → "Name");
- underscores to spaces;
- title case for names written entirely in capitals or entirely in lower case ("GLASS BELLS" →
  "Glass Bells"). Names that already mix cases keep their capitals.

Within title case:

- words with digits stay as they are (e.g., JP8, TB303);
- words with no vowels count as acronyms (e.g., PWM, PPG, FM); Y counts as a vowel, so "SYNTH"
  becomes "Synth";
- words on an editable list keep a fixed spelling (e.g., LFO, MIDI, LoFi);
- short joining words are lower case except at the start ("DRUMS AND AMPS" → "Drums and Amps"),
  and the parts of a hyphenated word are cased separately ("LO-FI PAD" → "Lo-Fi Pad").

Every proposal is shown, can be edited, and can be unticked. New names go into the `.pgdata` and
its file name. Source files are not changed, and unpacking keeps names as they are.

![Clean Up Names: options at the top, and each current name with its proposed new name](docs/clean-up-names.png)

Name fields hold 31 characters, and the 3rd Wave displays all 31 for programs, wavetables and
multisamples. A longer name is flagged next to the name, in the program's notes and in the report
after packing, and is cut to 31.

#### Writing

Every program gets a `.pgdata`, even one that uses only factory tables and analog waves. A
`.pgdata` that embeds nothing is usually smaller than its `.pro` (about 10–30% for the factory
programs, since six-decimal floats become 4-byte words), though a program with a long sequencer
section can come out a little larger. Each embedded U table adds about 0.5 MB, each P table about
65 KB, and a multisample its audio.

**Pack Selected…** and **Pack All…** (⌘⇧S) ask for a folder. If some programs can't be packed yet,
the app asks first whether to pack the others. Existing files are never replaced without asking,
and the report at the end can open the folder in the Finder.

![The report after packing, listing the input files no packed program uses and, where it is not obvious, why](docs/pack-report.png)

Files are named in Groove Synthesis's own pattern, with the program location first:
`B05P87_Glass_Bells.pgdata`, as in Groove Synthesis's `B05P06_Glass_Cow_Bell_Transients.pgdata`.

- The location comes from the `.pro` file name (e.g., `B05P100.pro`), since a `.pro` does not
  record it. Groove Synthesis's older layout of a `Bank 1` folder holding `001.PRO` to `100.PRO`
  is read too.
- The prefix keeps the 3rd Wave's alphabetical bulk import in program order.
- As in the 3rd Wave's own exports, spaces become underscores and everything other than ASCII letters,
  digits, hyphens and underscores is dropped (e.g., "Big Bass (MW)" → `Big_Bass_MW`). This affects
  the file name only, not the program name inside it.
- A batch that includes a program 100 uses three digits throughout (e.g., `B05P087_…`,
  `B05P100_…`). The 3rd Wave itself writes `B05P09_…` and `B05P100_…`, but in plain alphabetical order
  `B05P100` sorts between `B05P10` and `B05P11`, which could put it out of order in a bulk import.
- If any program being written has no location in its file name (for example, a renamed file, or a
  `.pro` written by Unpack), all of them are numbered by their place in the batch instead (e.g.,
  `001_…`, `002_…`).

#### What the 3rd Wave does on import

Checked on an 8M (OS 2.0d):

- **A table the 3rd Wave already has** (same content, in any slot, whatever its name) is reused. No
  slot is used, and the 3rd Wave keeps its own name for it.
- **A new table or multisample** goes into a free slot, and the program is pointed there. The slot
  number in the file is only a label. With no free slot, the 3rd Wave offers to overwrite its last
  ones; blank placeholder tables count as used. The Pack page shows how many free wavetable slots a
  program may need; each embedded multisample also takes a free S slot. (For multisamples, the
  3rd Wave's message says it erases the most recently loaded samples; not tried here.)
- **A table or multisample listed without its data** plays whatever is in that slot on the 3rd Wave,
  with no warning; an empty sample slot plays silence. That is why multisamples are always
  embedded.
- A `W3_PROG_4` program imports from a `.pgdata` and plays the same as from its `.pro` (one
  program checked). `W3_PROG_3` programs have not been tried on the 3rd Wave.

### Unpack

Drop `.pgdata` files. Each becomes a `.pro` named after the program, a `.wt` per embedded
wavetable named with its slot (e.g., `U57_Warm Pad.wt`), and a `.bin` per multisample named as
Groove Synthesis's sample library names them (e.g., `S010_Strings.bin`).

When a batch writes any wavetables or multisamples, the files go into the folders your 3rd Wave's
USB drive uses: `PROGRAMS` for `.pro`, `WAVES` for `.wt` and `AUDIO` for `.bin`, so you can copy
them onto the drive as they are. A batch of programs alone is written straight into the folder
you choose.

A box above the file list says what to do on your 3rd Wave before importing the `.pro`: which
multisamples go into which S slots first, and which slots the program plays from your 3rd Wave
rather than from the file. It appears only when there is something to say.

Untick anything you don't want, or rename it, before **Unpack Selected…** or **Unpack All…**.
Wavetables identical to the factory table in their slot are skipped by default: the 3rd Wave's own
export embeds factory tables too, and a repack lists them anyway. Unpacked names are kept as they
are.

A `.pgdata` does not record the program's format, so the unpacked `.pro` is always tagged
`W3_PROG_5`, the current format, whatever its layout. Whether the 3rd Wave's **Import Program**
accepts that tag on an older layout has not been tried; the `.pgdata` itself imports either way.

## Formats

**Source ids.** A program refers to each oscillator's source by an integer. The numbering is
irregular: it looks as if later ranges were added without renumbering the earlier ones.

| id | source |
|---|---|
| 0–33 | P00–P33 |
| 34–40 | U00–U06 |
| 41–47 | analog waves A00–A06 (sawtooth, square, triangle, sine, supersaw, pink noise, blue noise) |
| 1000+k | P(34+k): P34–P47 |
| 2000+k | U(7+k): U07–U63 |
| 4000+n | S n |

Checked on the 3rd Wave for ids 34 (U00), 1000 (P34) and 2000 (U07), and for the seven analog waves;
the rest of each range follows from the ids seen in files (P36–P47 are inferred). An id names a
slot, not content: what plays is whatever is loaded in that slot.

**.pro** — text, one value per line: `W3_PROG_<n>`, the name, then values. Counting lines from 1,
line 3 is the number of values per part S (173, 174, 179, 180 or 181 seen), part *k* starts at
line 4 + S·k with its three oscillator ids at offsets 3–5, and a block of floats starts at line
4S + 7 (504, 508, 520 or 544 floats depending on the layout), followed by a variable-length
integer tail (probably sequencer data).

**.wt** — text: `PNAME` or `UNAME`, the name, then one float per line (e.g., `0.963237f`). P
tables hold 64 × 128 (sample, delta-to-next) pairs = 16,384 values; U tables 131,072 values.

**.bin** — `W3_MSAMPLE_<v>` (1, 4 and 5 seen), sample count, 32-byte slot name, then the samples:
length, rate, bit depth, name, start and end, loop start and end, root, low and high note, loop
mode, crossfade length and type, pitch, second rate, volume, int16 audio. Versions 1 and 4 lack
some fields; they are upgraded with the values the 3rd Wave itself fills in.

**.pgdata** — `W3_UNIPROG_1`, a source table (index, type, id), one record per source (with the
embedded `.wt` values as float32, or the multisample in `.bin` v5 layout, or nothing), then the
program name and the `.pro` values as 32-bit words, with oscillator ids replaced by source-table
indices.

## Verification

Run against about 2,700 real files: Groove Synthesis's factory banks (8M, and 24-voice versions 1
and 2b), sample library and OS 1.8 example files, plus ten third-party sound sets. These checks
use the `tw3pg` developer tool, which keeps each table as it was; the app's own repack lists
factory tables instead of embedding them, so its output differs there by design.

- Every `.pro`, `.wt`, `.pgdata` and v5 `.bin` reads and rewrites byte for byte (v1 and v4 `.bin`
  files are upgraded to v5).
- All 221 `.pgdata` files unpack and repack identically, up to the `.pro` format's six-decimal
  float precision (the 3rd Wave's own `.pro` export has the same limit).
- All 314 embedded wavetables are bit-identical to the `.wt` files they came from.
- Packing Groove Synthesis's factory `.pro` files reproduces the structure of their `.pgdata` (19
  for the 8M, 19 for the 24-voice models): the same sources, in the same order, with the same
  samples. What differs: Groove Synthesis's files embed the factory tables and this app lists them
  without data; a few values that appear to be state captured at export time (one per part); and
  the leftover source references from unused parts, which this app lists and Groove Synthesis's 8M
  exporter does not (their 24-voice files do). One 24-voice program's `.pro` and `.pgdata` differ
  in real settings; they appear to be different editions.

## Tests on the 3rd Wave

The behaviour under "What the 3rd Wave does on import" was checked on an 8M (OS 2.0d), along with
name lengths and the 3rd Wave's own export file names. The 3rd Wave's exports were also unpacked and
repacked byte for byte with `tw3pg`. The test `.pgdata` files are built with `tw3pg` from files that are not
included here (a Groove Synthesis factory program and one of its `.wt` files, two third-party
programs, and a small `.bin`).

Still unknown: whether the 3rd Wave reuses a multisample it already has (as it does for wavetables);
whether its bulk import sorts file names plainly or by number; how it writes non-ASCII letters in
file names; whether `W3_PROG_3` programs import from a `.pgdata`; whether **Import Program**
accepts an unpacked `.pro` tagged `W3_PROG_5` on an older layout; and the meaning of the few
program values that differ between exports.

## Layout

```
Sources/PgdataFormats/   formats and packing logic, no UI (tested on Linux and macOS)
  SourceRef.swift           source-id mapping
  ProgramFile.swift         .pro
  WavetableFile.swift       .wt
  Multisample.swift         .bin and the shared sample record
  UnifiedProgram.swift      .pgdata
  PackUnpack.swift          Packer / Unpacker
  Workbench.swift           factory library, pack and unpack plans, output file names
  NameCleaner.swift         Clean Up Names
  FactoryCatalog.swift      factory table names and fingerprints (generated)
  ByteIO.swift              byte reading and writing, 32-byte name fields
Sources/PgdataPacker/       the app (SwiftUI)
Resources/                  app icon, drawn by tools/make-icon.py (needs cairosvg and Pillow)
docs/                       screenshots used in this README
Sources/tw3pg/              developer harness: inspect, roundtrip, unpack, repack, compare, wtcheck,
                            factory-catalog, pack, and the 3rd Wave-test builders
Tests/PgdataFormatsTests/
```

## License

MIT; see `LICENSE`. "3rd Wave" and "Groove Synthesis" are used only to say what this works with;
this project is not affiliated with or endorsed by Groove Synthesis.
