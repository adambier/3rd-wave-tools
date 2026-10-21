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

Tests (`./run-tests.sh`) need a full Xcode installation, as in ThirdWaveWT.

## Using it

The window has three sections.

**Synth Slots** — tell the app what your synth's wavetable slots hold. Every factory slot (P00–P35,
U00–U55) is assumed to hold its factory table unless you say otherwise. Other slots are "unknown"
until you assign the `.wt` file that is in them. Drop files named with a slot (`U48 SM OBX8 1.WT`)
onto this view to assign several at once, or use **Set… → Assign File…** on a row. Sample (S)
slots are not tracked, because sample memory changes too often for a record of it to stay right:
add the `.bin` a program needs on the Pack screen. Also add the folders of Groove's factory `.wt` files here. The app uses
them to embed factory tables when asked, and to recognise factory tables when unpacking. The slot
list is saved in `~/Library/Application Support/pgdata Packer/synth-slots.json`.

**Pack** — drop `.pro` files, plus any `.wt` / `.bin` files they need. For each program the app
lists its oscillator sources and what each will be:

- a file you added and assigned to that slot (this wins, since it is what the program's author
  supplied),
- for a factory slot: the factory table, not embedded by default ("Embed factory wavetables"
  embeds them),
- for any other wavetable slot: the file the Synth Slots list says is there,
- otherwise **missing**, and that program will not be written.

**Point to another slot…** (bottom of the Content menu) repoints oscillators: tick the oscillators
to change and pick the target, which can be a file you added (listed first, under the slot it is
assigned to), any U or P slot on your synth (searchable by slot or name), or an analog shape. The
Source column then shows e.g. **U01 → U56**, with a button to undo it. Only the `.pgdata` changes;
the `.pro` file is not modified. Multisample oscillators are not repointed. Parts 3 and 4 play only
on 4-part models (24K, 24M); on an 8M they hold filler (P02, U01 and an analog shape).

**Clean Up Names…** proposes tidier names for the programs and the wavetables and multisamples
you added (never factory wavetables): slot numbers removed from the start or end ("U48 SM OBX8 1" →
"SM OBX8 1", "S010_JP8_" → "JP8"), underscores to spaces, and title case for names written entirely
in capitals or entirely in lower case ("NOSTALGIA RES" → "Nostalgia Res"). Names that already mix
cases keep their capitals; words with digits (JP8, OBX8) words with no vowels are taken to be acronyms (SM, PWM, PPG; Y counts as a vowel, so
"SYNTH" becomes "Synth"); and words on an editable list keep a fixed spelling (LFO, MIDI, LoFi…). Every proposal is shown, editable and can be unticked. New names go into
the `.pgdata` (and its file name); source files are not changed, and unpacking keeps names as they
are. Names longer than 26 characters (the longest factory program name) are flagged, since the
synth's display limit is unknown; name fields hold 31 characters. A table embedded "as on my synth"
carries the name recorded in Synth Slots.

Added files that no program uses are flagged in the files table ("Not assigned to a slot", "Not
used by any program here"), with **Use in a program…** to repoint a program to them, and are listed
again after **Write**.

You can change any choice from the Content menu. A warning appears where your synth differs
from what the program expects (for example a factory slot you have overwritten).

Every program gets a `.pgdata`, even one that uses only factory tables and analog shapes: the
`.pgdata` is no bigger than the `.pro` (about 13% smaller, since values are stored as 4-byte words
rather than text). A multisample a program uses is always embedded; there is no option to leave it
out. Each program shows **factory content only** (nothing embedded), **embeds wavetables or
samples**, or **missing content** (not written until you add the file). **Write Selected…** /
**Write All…** ask for a folder.

**Unpack** — drop `.pgdata` files. Each becomes a `.pro`, plus a `.wt` per embedded wavetable and
a `.bin` per multisample, named the way Groove names its own files (`U50_SM OB2.wt`,
`S010_JP8.bin`). Untick anything you don't want, or rename it, before **Unpack…**. Wavetables
identical to the factory table in their slot are skipped by default.

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

Run against 2,000-odd real files: Groove's 8M factory banks and sample library, Groove's
1.8 examples and the Bank Arranger banks, plus nine third-party sound sets.

- Every `.pro`, `.bin`, `.wt` and `.pgdata` reads and rewrites byte for byte.
- All 202 intact `.pgdata` unpack and repack identically, up to the `.pro` format's six-decimal
  float precision (the synth's own `.pro` export has the same limit).
- All 280 embedded wavetables are bit-identical to Groove's `.wt` files.
- Packing Groove's 19 factory `.pro` files reproduces Groove's `.pgdata`. The differences are
  three values that appear to be state captured at export time, and the leftover source
  references from unused parts, which this app lists and Groove's 8M exporter does not (Groove's
  sample library does).

## Not yet known (needs a test on the synth)

- Whether importing a `.pgdata` puts its wavetables back in their original slots or moves them
  to free ones. Groove's own instructions imply that samples are moved to free S slots.
- Whether a `.pgdata` containing an older `W3_PROG_4` program imports correctly.
- Whether the synth accepts our `.pgdata` files with factory tables left out. Groove's own sample
  library does this, so it is expected to work.

## Synth tests

`hw-tests/` holds four small `.pgdata` files and step-by-step instructions (`hw-tests/TESTS.md`)
for the open questions above. `tw3pg maketests` regenerates them.

## Layout

```
Sources/PgdataFormats/   formats and packing logic, no UI (tested on Linux and macOS)
  SourceRef.swift           source-id mapping
  ProgramFile.swift         .pro
  WavetableFile.swift       .wt
  Multisample.swift         .bin and the shared sample record
  UnifiedProgram.swift      .pgdata
  PackUnpack.swift          Packer / Unpacker
  Workbench.swift           slot profile, factory library, pack and unpack plans
Sources/PgdataPacker/       the app (SwiftUI)
Sources/tw3pg/              developer harness: inspect, roundtrip, repack, compare, wtcheck
Tests/PgdataFormatsTests/
```
