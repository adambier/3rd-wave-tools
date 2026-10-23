# 3rd Wave file formats: reference

This is the model of the Groove Synthesis 3rd Wave's program, wavetable, multisample and unified
program files that pgdata Packer is built on. Groove Synthesis has not published these formats; everything
here comes from reading real files and from tests on a 3rd Wave 8M (OS 2.0d). The library in
`Sources/PgdataFormats` implements it, and its tests are the executable form of much of it.

Each statement carries a tag saying how far it can be trusted:

- **[verified]**: checked on a 3rd Wave (what it displays, plays or writes) or stated by Groove Synthesis;
- **[observed]**: seen consistently in real files, but not checked on a 3rd Wave;
- **[inferred]**: our reasoning from the above, not yet checked.

Line numbers in `.pro` files count from 1. "Value *n*" inside a block counts from 0.

## Contents

- [Oscillator source ids](#oscillator-source-ids)
- [.pro: program](#pro-program)
- [Program layouts and their conversion](#program-layouts-and-their-conversion)
- [.pgdata: unified program data](#pgdata-unified-program-data)
- [.wt: wavetable](#wt-wavetable)
- [.bin: multisample](#bin-multisample)
- [Names and file names](#names-and-file-names)
- [What the 3rd Wave does on import](#what-the-3rd-wave-does-on-import)
- [Open questions](#open-questions)

## Oscillator source ids

Each oscillator stores what it plays as one integer, the same in `.pro` files and in the source table
of a `.pgdata`. The numbering is irregular; it looks as if later ranges were added without
renumbering the earlier ones. [inferred]

| id | source | evidence |
|---|---|---|
| 0–33 | P00–P33 | [observed]: embedded in `.pgdata` files as tables named "Wavetable P00" etc. |
| 34–40 | U00–U06 | [verified] for 34 = U00; the rest of the range [observed] |
| 41–47 | analog waves, **not in display order**: see below | [verified], every id |
| 1000+k | P(34+k): P34–P47 | [verified] for 1000 = P34; P36–P47 (1002–1013) [inferred] |
| 2000+k | U(7+k): U07–U63 (2056 = U63) | [verified] for 2000 = U07; the rest [observed] |
| 4000+n | S*n*, multisample slot *n* | [observed] |

Analog waves, as the 3rd Wave's OSC screen shows each id [verified, 2026-10-23]:

| id | shown as |
|---|---|
| 41 | A00 Sawtooth |
| 42 | A01 Square |
| 43 | A04 Supersaw |
| 44 | A03 Sine |
| 45 | A05 noise; the wave offset knob sweeps white → pink → red |
| 46 | A06 noise; the wave offset knob sweeps white → blue → violet |
| 47 | A02 Triangle |

An id names a **slot**, not content: what plays is whatever that 3rd Wave has loaded in the slot.
Two programs that both use U50 can expect different tables. [verified]

## .pro: program

Plain text, one value per line, LF line ends with a trailing newline. [observed]

| Lines | Content |
|---|---|
| 1 | Format tag: `W3_PROG_3`, `W3_PROG_4` or `W3_PROG_5` seen |
| 2 | Program name |
| 3 | *S*, the number of values per part: 173, 174, 179, 180 or 181 seen |
| 4–6 | Three header values (see below) |
| 7 … 6 + 4*S* | Four part blocks of *S* values each; part *k* (0–3) starts at line 7 + *S*·*k* |
| 4*S* + 7 … | The float block (504 to 548 values, by layout) |
| after the floats | The integer tail, to the end of the file |

[observed on about 2,350 programs: Groove Synthesis's factory banks and third-party sets]

Integers are written as decimal integers, floats with six decimals (`%f`, e.g. `0.385000`), so a `.pro`
keeps floats to about 1e-6. The 3rd Wave's own `.pro` export does the same. [observed]

### Header values (lines 4–6)

| Program | Line 4 | Line 5 | Line 6 |
|---|---|---|---|
| `W3_PROG_5` written by OS 2.0d (three programs) | 137 | 182 | 189, 142, 0 |
| `W3_PROG_4` (one program) | 130 | 175 | 0 |
| `W3_PROG_3`, *S* 173 | 126 | 75 | 268 |
| `W3_PROG_3`, *S* 174 | 127 | 115 | 306 |

Lines 4–5: meaning unknown. Every program the 3rd Wave wrote had 137 and 182. [observed] Line 6 is
the number of 6-value event records at the end of the tail, in every file where it was counted.
[observed]

### Part blocks

Within a part block (value 0 = the block's first line):

| Value | Meaning |
|---|---|
| 3, 4, 5 | Source ids of oscillators 1, 2, 3 [verified] |
| 34 | Amp envelope amount: 100 = +100 [observed: the only part value that differed between a program the 3rd Wave played and one it left silent; 3rd Wave Terminal labels it Amp Env Amount] |

Parts 3 and 4 play only on the 4-part models (24K, 24M). Programs saved on an 8M hold filler there:
oscillators P02, U01 and A01 Square (ids 2, 35, 42). [observed in every 8M factory program] An 8M
replaced parts 3–4 with that filler, and dropped their automation, in every program imported and
exported again. [observed, three programs]

### Float block

Its length depends on the layout. Within a layout it is fixed. [observed]

| *S* | Floats | Where seen |
|---|---|---|
| 173 | 504 | `W3_PROG_3` (Groove Synthesis's 2022 24-voice factory banks) |
| 174 | 508 | `W3_PROG_3` |
| 179 | 508 | `W3_PROG_4` |
| 180 | 520 | `W3_PROG_4` |
| 181 | 520 | `W3_PROG_4`, and `W3_PROG_5` saved before mid-2025 |
| 181 | 544 | `W3_PROG_5` saved from OS 1.9 (8M and 24-voice factory banks, 2025) |
| 181 | 548 | `W3_PROG_5` written by OS 2.0d (every export seen; the last 4 were 0 in all of them) |

A `.pgdata` stores the same values as 32-bit words without saying which are floats, so a reader has
to work out the float block's length. pgdata Packer uses the known lengths for each *S* and, for
*S* = 181, looks for small non-zero integers where the tail would start in each layout. [observed]

### Integer tail

Global settings, then a list of event records. [observed]

- Value 0: 3 in everything OS 2.0d wrote; 1 or 2 in older files. Meaning unknown. [observed]
- Value 1: a velocity setting. The 3rd Wave Terminal shows 5 as "Piano" and 2 as "Medium". [observed]
- Converting to the current layout inserts further global values. See
  [Program layouts and their conversion](#program-layouts-and-their-conversion).
- The tail ends with event records of 6 values each; their number is header line 6. Two kinds were seen:
  - `p 108 1 <float bits> <step> 0`: one per part *p* and step (steps 0, 64, 128, …), with a float
    stored as its 32-bit pattern. Probably per-step automation. [inferred]
  - `<k> <a> 2 <b> <time> 0`: probably sequencer notes. [inferred] *k* was 0 in a `W3_PROG_3` file and
    3 after the 3rd Wave converted it.

## Program layouts and their conversion

The 3rd Wave converts an older program to its current layout when importing it. **Import Program**
(`.pro`) and **Import Unified Program Data File** (`.pgdata`) do not convert in the same way.
[verified, one `W3_PROG_3` program, "House Organ 1" from Groove Synthesis's 2022 24-voice factory banks, 2026-10-23]

Both imports produced identical results in the header constants, every part value and all 548
floats. They differed only where Import Program applies fixes that depend on the format version:

| What | Original `W3_PROG_3` | After Import Program | After `.pgdata` import |
|---|---|---|---|
| Part value 34, parts 1–2 | 0 | **100** | 0: the program is silent |
| Tail value 1 (velocity) | 5 | **2** | 5 |
| Event records | 16 note + 4 × 63 automation | 16 note (*k* = 3) + automation for parts 1–2 | no notes; automation for 3 parts |

The likely reason is that a `.pgdata` does not carry the format tag, so the `.pgdata` import
cannot tell which fixes to apply. [inferred] The 3rd Wave itself never writes an older layout into a
`.pgdata`: its exports are always current. [observed]

**Consequence:** packing a `.pro` older than `W3_PROG_5` into a `.pgdata` gives a file that imports
without error but can play differently. Until pgdata Packer converts old programs itself, import
such programs on the 3rd Wave with **Import Program**, then export a `.pgdata` from there. Whether
`W3_PROG_4` programs are affected in the same way is still being checked; one did play the same.

What Import Program changes when converting, as far as seen [observed]:

- `W3_PROG_3`, *S* 173 → `W3_PROG_5`, *S* 181: each part block gains 8 values at its end (all 0 in
  the example); part value 34 becomes 100; the float block grows from 504 to 548 values, with values
  inserted and some changed; header lines 4–5 become 137, 182; tail value 0 becomes 3, tail value 1
  changes from 5 to 2; global values are inserted in the tail; the event records are rewritten: the notes
  are kept with *k* = 3, and the automation for parts 1–2 is kept, numbered 1 and 2 where the original
  numbered parts from 0 [inferred].
- `W3_PROG_4`, *S* 181 → `W3_PROG_5`: part values unchanged; the float block grows from 520 to 548;
  header lines 4–5 change from 130, 175 to 137, 182; tail value 0 changes from 1 to 3; global values are
  inserted in the tail.

These come from one program of each kind. They are not yet enough to reproduce the conversion.

## .pgdata: unified program data

Binary, little-endian. [observed: 221 files from Groove Synthesis, third parties and a 3rd Wave's own exports]

```
0    char[16]  "W3_UNIPROG_1", NUL-padded
16   u8        N, the number of sources
17   N × { u8 index (0 … N-1), u8 type, u16 source id }      type: 0 = P, 1 = U, 2 = analog, 4 = S
     N × record, in index order:
         u8 type, u8 index, u8 has_data
         if has_data, type 0 or 1:  char[32] table name, float32[16384 (P) or 131072 (U)]
         if has_data, type 4:       u8 sample count, char[32] slot name, samples (as in .bin v5)
     char[32]  program name
     one 32-bit word per .pro line from line 3 on (int32, or float32 in the float block), to the end
```

- The twelve oscillator source ids in the program words are replaced by source-table indices.
  [observed] Sources are listed in order of first use, part 1 oscillator 1 first. [observed]
- Analog waves are listed with type 2 and never carry data. [observed]
- There is **no format tag**: the words start with *S*. Unpacking writes `W3_PROG_5`. [observed]
- Embedded wavetables are the `.wt` values as float32, bit-identical to the files they came from
  (325 compared). [observed]
- The 3rd Wave's own export embeds every wavetable a program uses, factory ones included, and lists
  only the sources the program actually uses. [verified] Groove Synthesis's sample library lists factory
  tables without data instead [observed]; a file built that way imports and plays correctly. [verified]
- Multisample records are byte-identical to the body of a v5 `.bin`. [observed]

## .wt: wavetable

Plain text, LF or CRLF. [observed: 92 factory files and others]

- Line 1: `PNAME` (P table) or `UNAME` (U table). Line 2: the display name.
- Then one float per line, written as a C literal with an `f` suffix (e.g., `0.963237f`). Lines starting
  with `//` are comments.
- P tables: 16,384 values = 64 waves × 128 × (sample, delta to the next sample, wrapping within the
  wave). U tables: 131,072 values = 64 waves × 2048 samples.
- The file does not contain a slot number; the slot is chosen at import.
- Number formatting varies between files. pgdata Packer writes six decimals when that reproduces the
  float exactly, and the shortest exact form otherwise.

## .bin: multisample

Binary, little-endian. [observed: 13 files]

```
0    char[16]  "W3_MSAMPLE_<v>", NUL-padded        v = 1, 4 or 5 seen
16   u8        sample count (up to 8)
17   char[32]  slot name
49   samples, to the end of the file
```

Each sample in v5: `u32` length in frames, `f32` sample rate, `u8` bit depth, `char[32]` name, `u32`
start, end, loop start, loop end, `u8` root note, low note, high note, loop mode, `u32` crossfade
length, `u8` crossfade type, `f32` pitch, second rate, volume, then `int16` audio × length.

- v4 lacks the volume. v1 also lacks the rate and bit depth after the length, and the pitch and second
  rate. Upgrading to v5 fills in the 3rd Wave's own defaults: 48,000 Hz, 16-bit, pitch 0, second rate
  = rate, volume 1.0. [observed]
- The file does not contain a slot number; the slot is chosen at import. [verified]

## Names and file names

- Name fields in `.pgdata` and `.bin` are 32 bytes: up to 31 characters and a terminating NUL. The
  3rd Wave displays all 31 for programs, wavetables and multisamples. [verified]
- Program locations display as `B4-P003`: bank 1–5, program 001–100. [verified]
- The 3rd Wave's `.pgdata` export names files `B05P09_Name.pgdata`, `B05P100_Name.pgdata`: two-digit
  bank, program number without padding beyond two digits, spaces → underscores, punctuation other
  than hyphens dropped. [verified] Its `.pro` export uses `B05P094.pro` (three-digit program).
  [verified]
- The USB drive's folders appear as `PROGRAMS` (`.pro`, `.pgdata`), `WAVES` (`.wt`), `AUDIO`
  (`.bin`, exported `.wav`) and `FIRMWARE` when the drive is mounted on a Mac. [verified] (Groove
  Synthesis's READMEs write `program/`, `waves/` and `audio/`.)

## What the 3rd Wave does on import

[verified on an 8M, OS 2.0d]

- **Tables are matched by content.** A table the 3rd Wave already has, in any slot and under any name,
  is reused; no slot is used and it keeps its own name for it.
- **A new table or multisample goes into a free slot**, and the program is pointed there. The slot
  number in the file is only a label. With no free slot, the 3rd Wave offers to overwrite its last
  table(s); blank placeholder tables count as used.
- **A source listed without its data** plays whatever is in that slot; an empty sample slot plays
  silence, with no warning.
- **Import Program** asks for the new program's name (defaulting to the name in the file); the `.pgdata`
  import does not.
- **Older layouts** are converted, differently by the two imports: see
  [Program layouts and their conversion](#program-layouts-and-their-conversion).

## Open questions

- The full rules Import Program uses to convert `W3_PROG_3` and `W3_PROG_4` programs, and whether the
  `.pgdata` import mishandles `W3_PROG_4` programs too.
- Whether Import Program accepts an unpacked `.pro` tagged `W3_PROG_5` that has an older layout.
- Whether multisamples are reused by content, as tables are.
- Whether the bulk import sorts file names plainly or by number (`B05P100` vs `B05P10`).
- The meaning of the header constants, of most part, float and tail values, and of the few values
  that differ between a program's `.pro` and `.pgdata` exports.
