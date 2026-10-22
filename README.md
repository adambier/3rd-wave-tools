# pgdata Packer

*for the Groove Synthesis 3rd Wave*

A macOS app that packs Groove Synthesis 3rd Wave programs together with the wavetables and
multisamples they use into unified program files (`.pgdata`), and unpacks `.pgdata` files back
into a program (`.pro`), wavetables (`.wt`) and multisamples (`.bin`).

Not affiliated with or endorsed by Groove Synthesis. Everything here was worked out from files
and confirmed on one 8M (OS 2.0d); the format notes below say which parts are verified and which
are inferred.

## Build

Requires macOS 13+ and the Xcode command-line tools (`xcode-select --install`). No Xcode project.

```
./make-app.sh          # builds "pgdata Packer.app" in this folder
open "pgdata Packer.app"
```

Tests (`./run-tests.sh`) need a full Xcode installation.

## Using it

The window has two sections, **Pack** and **Unpack**. There is nothing to set up.

### Factory wavetables

The app never embeds factory wavetables. A program that uses a factory slot (U00–U55, P00–P35)
lists that slot without data, and the synth that loads the file plays its own factory table.

The app knows the factory tables by name and by a fingerprint of their content, built in from
Groove Synthesis's factory `.wt` files (`tw3pg factory-catalog`; only names and fingerprints are
stored, not the tables). It uses them to:

- show factory slot names ("U00 Additive_Bell_17");
- recognise a factory table among the files you add (for example one unpacked from the synth's own
  export, which carries every table it uses), so it is listed rather than embedded;
- leave factory tables out of the free-slot estimate, since a synth that has them reuses them;
- skip factory tables when unpacking, and never offer them for renaming.

U48–U55 joined the factory set in 2025 (with OS 1.9, which also brought `.pgdata`). Before that
they were user slots, and some older program sets used them for their own tables, shipped as `.wt`
files named with the slot (`U48 Warm Pad.wt`). So in a program saved before OS 1.9, U48–U55
are treated like user slots: missing until you add the table, which is then embedded and goes into
a free slot on import. A note with the program explains this and the three ways to fix it: add the
author's tables, point the oscillators elsewhere, or choose the factory table anyway from the
Content menu.

A program counts as saved before OS 1.9 when its format is older than `W3_PROG_5`, or its float
block has fewer than 544 values. Programs saved since OS 1.9 have 544 (Groove Synthesis's 8M factory
banks, August 2025, onwards); every older set seen has fewer, including `W3_PROG_5` programs from
February 2025. The file has no date, so this is an inference from the layout.

A table from a user slot (U56–U63, P36–P47) or a multisample that a program uses is always
included in the `.pgdata`, from the file you add on the Pack screen: whoever loads the file will
almost certainly not have the same user slots or sample memory.

### Pack

Drop `.pro` files, plus the `.wt` / `.bin` files they need. For each program the app lists its
oscillator sources and what each will be:

- a file you added and assigned to that slot (this wins, since it is what the program's author
  supplied). A file named with a slot (`U48 Warm Pad.wt`, `S010_Strings.bin`) is assigned to it
  automatically;
- for a factory slot: the factory table, listed but not embedded. An added file identical to it is
  listed the same way;
- for a user slot or a multisample with no file added: **missing**, and that program is not
  written until you add the file or point the oscillators elsewhere.

You can change any choice from the Content menu.

Programs in a layout not seen before (a format other than `W3_PROG_3` to `_5`, or an unusual
number of values per part) get a warning: the app finds the oscillator sources from the layout, so
check them, and check the program on the synth after importing. The warning is repeated when you
write. A source number outside every known range shows as an unknown source, and the program is
not written until those oscillators are pointed elsewhere.

Each program shows one of:

- **factory content only**;
- **embeds wavetables or samples**;
- **missing content**: not written until you add the file.

#### Pointing oscillators to another slot

**Point to another slot…** (in the Content menu; the first choice when a wavetable is missing)
repoints oscillators. Tick the oscillators to change, then pick the target:

- a file you added (listed first). A file without a slot is given one automatically: when the
  program needs a slot that has nothing yet (say U57), the sheet preselects your
  unused file and simply assigns it to that slot, so the oscillators stay as they are;
- any factory U or P slot (searchable by slot or name);
- an analog shape.

The Source column then shows, for example, **U01 → U56**, with a button to undo it. Only the
`.pgdata` changes; the `.pro` file is not modified. Multisample oscillators are not repointed.

Parts 3 and 4 play only on 4-part models (24K, 24M). On an 8M they hold filler (P02, U01 and an
analog shape).

Added files that no program uses are flagged in the files table ("Not used by any program here",
or "another choice is made for U57" when a different file fills its slot). **Use in a program…**
repoints a program to them, and they are listed again after writing.

#### Names

The program name at the top of the detail area can be edited. **Clean Up Names…** proposes tidier
names for the programs and for the wavetables and multisamples you added (never factory
wavetables):

- slot numbers removed from the start or end: "U48 Warm Pad" → "Warm Pad", "S010_Strings_" → "Strings",
  "B5-P003 Name" → "Name";
- underscores to spaces;
- title case for names written entirely in capitals or entirely in lower case:
  "GLASS BELLS" → "Glass Bells". Names that already mix cases keep their capitals.

Within title case:

- words with digits stay as they are (JP8, TB303);
- words with no vowels are taken to be acronyms (PWM, PPG, FM). Y counts as a vowel, so "SYNTH"
  becomes "Synth";
- words on an editable list keep a fixed spelling (LFO, MIDI, LoFi…).

Every proposal is shown, can be edited, and can be unticked. New names go into the `.pgdata` and
its file name. Source files are not changed, and unpacking keeps names as they are.

Name fields hold 31 characters, and the synth displays all 31 for programs, wavetables and
multisamples. Longer names are flagged and cut to 31.

#### Writing

Every program gets a `.pgdata`, even one that uses only factory tables and analog shapes. The
`.pgdata` is no bigger than the `.pro`: about 13% smaller, since values are stored as 4-byte words
rather than text.

**Write Selected…** and **Write All…** ask for a folder. If some programs are missing content,
the app asks first whether to write the others.

Files are named in Groove Synthesis's own pattern, with the program location first:
`B05P87_Glass_Bells.pgdata`, as in Groove Synthesis's `B05P06_Glass_Cow_Bell_Transients.pgdata`.

- The location comes from the `.pro` file name, since a `.pro` does not record it. Every set seen
  names its files that way (`B05P100.pro`).
- The prefix keeps the synth's alphabetical bulk import in program order.
- As in the synth's own exports, spaces become underscores and punctuation other than hyphens is
  dropped ("Big Bass (MW)" → `Big_Bass_MW`). This affects the file name only, not the
  program name inside it.
- A batch that includes a program 100 uses three digits throughout (`B05P087_…`, `B05P100_…`).
  The synth itself writes `B05P09_…` and `B05P100_…`, but in plain alphabetical order `B05P100`
  sorts before `B05P95`, which could put it first in a bulk import.
- If any program's file name has no location (a renamed file), all are numbered by their place
  in the list instead (`001_…`, `002_…`).

#### What the synth does on import

Checked on an 8M (OS 2.0d):

- **A table the synth already has** (same content, in any slot, whatever its name) is reused. No
  slot is used and the synth keeps its own name for it.
- **A new table or multisample** goes into a free slot, and the program is pointed there. The slot
  number in the file is only a label. With no free slot, the synth offers to overwrite its last
  ones; blank placeholder tables count as used. The Pack screen shows how many free slots a program
  may need.
- **A table or multisample listed without its data** plays whatever is in that slot on the synth,
  or silence if the slot is empty, with no warning. That is why multisamples are always embedded.
- Older-format programs (`W3_PROG_4`) import from a `.pgdata` exactly as from their `.pro`.

### Unpack

Drop `.pgdata` files. Each becomes a `.pro`, plus a `.wt` per embedded wavetable and a `.bin` per
multisample, named the way Groove Synthesis names its own files (`U57_Warm Pad.wt`, `S010_Strings.bin`).

Untick anything you don't want, or rename it, before **Unpack…**. Wavetables identical to the
factory table in their slot are skipped by default: the synth's own export embeds factory tables
too, and a repack lists them anyway.

## Formats

Summarised from `claude/format-notes.md` in the project.

**Source ids.** A program refers to each oscillator's source by an integer. The numbering was
extended twice without being redone:

| id | source |
|---|---|
| 0–33 | P00–P33 |
| 34–40 | U00–U06 |
| 41–47 | analog shapes (sine, saw, triangle, supersaw, pulse, white, pink) |
| 1000+k | P(34+k) — P34–P47 |
| 2000+k | U(7+k) — U07–U63 |
| 4000+n | S n |

Checked on the synth for ids 34 (U00), 1000 (P34) and 2000 (U07). An id names a slot, not
content: what plays is whatever is loaded in that slot.

**.pro** — text, one value per line: `W3_PROG_<n>`, the name, then values. Line 3 is the number
of values per part (173, 174, 179, 180 or 181 seen), and part *k* starts at line 4 + S·k with
its three oscillator ids at offsets 3–5. A float block starts at line 4S + 6 (504, 508, 520 or
544 floats depending on version), followed by a variable-length integer tail (sequencer data).

**.wt** — text: `PNAME`/`UNAME`, the name, then one float per line (`0.963237f`). P tables hold
64 × 128 (sample, delta-to-next) pairs = 16,384 values; U tables 131,072 values.

**.bin** — `W3_MSAMPLE_<v>` (1, 4, 5 seen), sample count, 32-byte slot name, then the samples:
length, rate, bit depth, name, start/end, loop start/end, root/low/high note, loop mode,
crossfade length and type, pitch, second rate, volume, int16 audio. Versions 1 and 4 lack some
fields; they are upgraded with the values the synth itself fills in.

**.pgdata** — `W3_UNIPROG_1`, a source table (index, type, id), one record per source (with the
embedded `.wt` values as float32, or the multisample in `.bin` v5 layout, or nothing), then the
program name and the `.pro` values as 32-bit words, with oscillator ids replaced by source-table
indices.

## Verification

Run against 2,000-odd real files: Groove Synthesis's 8M factory banks and sample library, Groove Synthesis's
1.8 examples and the Bank Arranger banks, plus nine third-party sound sets.

- Every `.pro`, `.bin`, `.wt` and `.pgdata` reads and rewrites byte for byte.
- All 202 intact `.pgdata` unpack and repack identically, up to the `.pro` format's six-decimal
  float precision (the synth's own `.pro` export has the same limit).
- All 280 embedded wavetables are bit-identical to Groove Synthesis's `.wt` files.
- Packing Groove Synthesis's 19 factory `.pro` files reproduces Groove Synthesis's `.pgdata`. The differences are
  three values that appear to be state captured at export time, and the leftover source
  references from unused parts, which this app lists and Groove Synthesis's 8M exporter does not (Groove Synthesis's
  sample library does).

## Synth tests

The behaviour described under "What the synth does on import" was checked on an 8M (OS 2.0d), along
with name lengths and the synth's own export file names. The synth's exports were also unpacked and
repacked byte for byte. `tw3pg maketests`, `maketest5` and `maketest6` build the test `.pgdata` files
from your own copies of the programs they use (a Groove Synthesis factory program and two
third-party programs, which are not included here).

Still unknown: whether the synth reuses a multisample it already has (as it does for wavetables),
and the meaning of the few program values that differ between exports.

## Layout

```
Sources/PgdataFormats/   formats and packing logic, no UI (tested on Linux and macOS)
  SourceRef.swift           source-id mapping
  ProgramFile.swift         .pro
  WavetableFile.swift       .wt
  Multisample.swift         .bin and the shared sample record
  UnifiedProgram.swift      .pgdata
  PackUnpack.swift          Packer / Unpacker
  Workbench.swift           factory library, pack and unpack plans
  FactoryCatalog.swift      factory table names and fingerprints (generated)
Sources/PgdataPacker/       the app (SwiftUI)
Sources/tw3pg/              developer harness: inspect, roundtrip, repack, compare, wtcheck, factory-catalog, pack
Tests/PgdataFormatsTests/
```

## License

MIT; see `LICENSE`. "3rd Wave" and "Groove Synthesis" are used only to say what this works with; this project is not affiliated with or endorsed by Groove Synthesis.
