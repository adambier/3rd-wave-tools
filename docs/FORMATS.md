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
| 3 | *S*, the number of integer values per part: 173, 174, 179, 180 or 181 seen |
| 4 | *F*, the number of float values per part: 126, 127, 130, 136 or 137 seen |
| 5 | *G*, the number of global values: 73 to 182 seen (see below) |
| 6 | *E*, the number of event records |
| 7 … | Four integer part blocks of *S* values; part *k* (0–3) starts at line 7 + *S*·*k* |
| 4*S* + 7 … | Four float part blocks of *F* values |
| then | *G* global integer values |
| then | *E* event records of 6 values each, to the end of the file |

So a `.pro` describes its own layout: lines 3–6 give the size of every section, and the file ends
exactly where they say. [observed: every file checked (over 500 programs: Groove Synthesis's
factory banks, third-party sets and 3rd Wave exports), with no exceptions]

Integers are written as decimal integers, floats with six decimals (`%f`, e.g. `0.385000`), so a `.pro`
keeps floats to about 1e-6. The 3rd Wave's own `.pro` export does the same. [observed]

### Layouts seen

| Format | *S* | *F* | *G* | Where seen |
|---|---|---|---|---|
| `W3_PROG_3` | 173 | 126 | 73 or 75 | Groove Synthesis's 2022 24-voice factory banks |
| `W3_PROG_3` | 174 | 127 | 115 | the same banks (a few programs) |
| `W3_PROG_4` | 179 | 127 | 143 | third-party sets |
| `W3_PROG_4` | 180 | 130 | 169 | third-party sets |
| `W3_PROG_4` | 181 | 130 | 174, 175 or 177 | third-party sets |
| `W3_PROG_5` | 181 | 130 | 177 | programs saved before mid-2025 |
| `W3_PROG_5` | 181 | 136 | 181 | saved from OS 1.9 (8M and 24-voice factory banks, 2025) |
| `W3_PROG_5` | 181 | 137 | 182 | written by OS 2.0d (every export seen) |

[observed] Earlier versions of pgdata Packer did not use lines 4–6 and inferred the float block's
length from *S*; it still falls back on that for a `.pgdata` whose header does not add up.

### Integer part blocks

Within a part block (value 0 = the block's first line):

| Value | Meaning |
|---|---|
| 0, 1, 2 | Source ids of oscillators 1, 2, 3 [verified] |
| 34 | Amp envelope amount: 100 = +100 [observed: 3rd Wave Terminal labels it Amp Env Amount; a program with 0 here, and float 113 at 0, was silent] |

Parts 3 and 4 play only on the 4-part models (24K, 24M). Programs saved on an 8M hold filler there:
oscillators P02, U01 and A01 Square (ids 2, 35, 42). [observed in every 8M factory program] An 8M
puts exactly the same filler in parts 3–4 of every program it imports. [observed in 299 imports]

### Float part blocks

Four blocks of *F* floats, one per part, in part order. Newer layouts add values at the end of each
block: the first 126 values of a 137-value block line up with a 126-value one. [observed in 299
conversions by the 3rd Wave]

- Float 113 (`W3_PROG_3` only): a second amp envelope control, 0 = full, 1 = none; OS 2.0 folds it
  into part value 34 (see [conversion](#what-import-program-changes)). [inferred from 100 conversions]

### Global values

*G* integers that apply to the whole program. [observed] Newer layouts add values at the end.
[observed in 299 conversions] The meanings below are inferred from how values change in conversions
and how they line up with the event records; none has been checked on a 3rd Wave unless marked.

| Value | Meaning |
|---|---|
| 0 | 3 in everything OS 2.0d wrote; 1, 2 or 4 in older files. [observed] |
| 1 | Velocity. 3rd Wave Terminal shows 5 as "Piano" and 2 as "Medium". [observed] |
| 11 | The selected part, 0–3. [inferred] |
| 18 | Number of keyboard split points, 0–3. [inferred] |
| 21–23 | The split points: the notes above value 21 belong to zone 2, and so on. [inferred] |
| 24–27 | The parts each keyboard zone plays, as a part mask (1 = part 1, 2 = part 2, 4, 8; 3 = parts 1 and 2). Without a split, value 24 is the layer: parts that play together. [inferred] |
| 37–40 | One per part: 1 when that part is selected. [inferred] |
| 120–123, 124–127, 132–135 | One per part, where layouts with 120 globals or fewer had a single value (12, 13 and 15). [observed] |

### Event records

*E* records of 6 integers each, at the end of the file: `<target> <a> <type> <b> <time> 0`.
[observed] Groove Synthesis's own Bank Arranger script treats a non-zero line 6 as "this program has
a sequence". [official]

- *type* 2: a sequencer note. *b* = velocity × 256 + note number. [inferred: the low byte decides
  which side of a keyboard split the 3rd Wave sends the note to; the high byte stays between 1 and 128]
- *type* 1: automation, e.g., `1 108 1 <float bits> <step> 0`, one record per part and step (steps 0,
  64, 128, …), with a float stored as its 32-bit pattern. [inferred]
- *type* 0: seen only in a few `W3_PROG_5` files. [observed]
- *target*: in `W3_PROG_5` a part mask (1, 2, 4, 8, or a sum such as 3 for parts 1 and 2); in
  `W3_PROG_3` and `W3_PROG_4` a part index, 0–3. [observed]

## Program layouts and their conversion

The 3rd Wave converts a program saved in an older layout when it imports it. To find out how, 299
programs were bulk-imported into an 8M (OS 2.0d) and exported again [verified: the exports are the
3rd Wave's own output]:

- Groove Synthesis's 2022 24-voice factory bank 1: 100 `W3_PROG_3` programs, three layouts;
- Groove Synthesis's 2025 8M factory bank 1: 100 `W3_PROG_5` programs in the OS 1.9 layout;
- 99 programs from third-party sets: 76 `W3_PROG_4` and 23 `W3_PROG_5`, six layouts.

**Bulk program import** and **Import Program** convert the same way: one program imported both ways
gave byte-identical exports. [verified]

pgdata Packer's converter (`ProgramConverter` in the library) applies the rules below. Converting
for an 8M, it reproduces 292 of the 299 exports byte for byte, including every `W3_PROG_4` and
`W3_PROG_5` program; [Not explained](#not-explained) lists the 7 that differ. Every rule is
[observed] in those 299 unless marked otherwise.

### What Import Program changes

**Layout.** The result is always `W3_PROG_5` with 181 integers and 137 floats per part and 182
globals (header lines 3–5). Every old value keeps its position, and each section gains its new
values at its end, with fixed values: 0 for the integers, 4.0 for float 127 and 0 for the other
floats, and per-position values for the globals (they are in the converter's source).

Layouts with 120 globals or fewer had a single value where OS 2.0 has one per part: globals
120–123 take old global 12, 124–127 old global 13, and 132–135 old global 15.

**In every layout:**

- Floats 85 and 116 of each part become 0, and float 102 becomes 1.0.
- Globals 0 = 3, 2 = 0, 75 = 1, 76 = 2, 77 = 2, 78 = 0, 79 = 0, 80–82 = 1, 115 = 1, 140 = 0,
  142 = 0, 152 = 1, 153 = 0, 173 = 0, 174 = 1, 175 = 2 and 178 = 1, whatever they were.
- Part values 63–65 become 1 where they were 0.
- A part with all three oscillators on A04 Supersaw gets A00 Sawtooth on oscillator 3. [observed
  twice; inferred: OS 2.0 allows two supersaws per part]

**`W3_PROG_3` only:**

- Amp envelope: part value 34 gains 100 × (1 − float 113), rounded, up to 127. A program that had
  0 in both played silent until this was applied. [observed in all 100; the silence verified]
- Velocity (global 1): 5 becomes 2. (In 4 of the 93 programs that had 5, it became 3 instead.)
- Floats 91 and 95: 2.0 becomes 1.0. [observed twice]

**Event records (`W3_PROG_3` and `W3_PROG_4`):** the part index becomes a part mask. Records of other
types are dropped. [observed once]

- Automation for part index *n* gets mask 2<sup>*n*</sup>.
- Without a keyboard split, a note for part index *n* also gets mask 2<sup>*n*</sup>, unless that
  part is in the layer (global 24): then it gets the whole layer. [observed in 60 programs]
- With a split (global 18 above 0), a note goes to the zone its key falls in and gets that zone's
  part mask (globals 24–27), whatever part it was recorded on. [observed in 10 programs]
- The records stay in their original order.

`W3_PROG_5` event records are unchanged.

### What only an 8M does

On an 8M, the import also fits the program to two parts. pgdata Packer does this only when
converting for an 8M. Whether a 24K or 24M does any of it is untested. [inferred: these steps follow
from the 8M having two parts]

- Parts 3 and 4 are replaced with the 8M's filler (see [Integer part blocks](#integer-part-blocks)).
- Event records for parts 3 and 4 are dropped. Masks keep only parts 1 and 2, and a note recorded on
  part 3 or 4 of an unsplit program is dropped even when its layer includes part 1 or 2. A split
  program keeps one split point.
- Globals 24 and 25 keep only parts 1 and 2. Globals 18 and 19 are limited to 1, globals 124, 125
  and 127 to 8, and global 36 becomes 0. If part 3 or 4 was selected, part 1 is selected instead
  (part 2 in a split program), and the selection flags for parts 3 and 4 (globals 39–40) are cleared.

### Not explained

Seven `W3_PROG_3` programs come out differently from the 3rd Wave's export:

- In 3, global 1 (velocity) became 3, not 2. No rule found so far separates these from the 89
  where it became 2.
- In 1, the 3rd Wave replaced part 2 with a copy of part 1 and set the layer to parts 1–2 (it also
  changed velocity to 3).
- In 2, a few values in parts 1–2 changed (part values 30 and 33, floats 17, 44 and 103).
- In 1, float 53 went from 120 to 122 in both parts.

### The `.pgdata` import

A `.pgdata` carries no format tag, and its import does only part of the conversion. [verified on one
`W3_PROG_3` program, "House Organ 1" from Groove Synthesis's 2022 factory banks]

| What | Original `W3_PROG_3` | After Import Program | After `.pgdata` import |
|---|---|---|---|
| Part value 34, parts 1–2 | 0 | **100** | 0: the program is silent |
| Global 1 (velocity) | 5 | **2** | 5 |
| Event records | 16 notes + 4 × 63 automation | 16 notes (mask 3) + automation for parts 1–2 | no notes; automation for 3 parts |

Everything else, all 181 part values and 548 floats included, came out identical. The 3rd Wave itself
never writes an older layout into a `.pgdata`: its exports are always current. [observed] So a
program should be converted before it is packed.

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
- There is **no format tag**. The words start with *S*, *F*, *G* and *E* (`.pro` lines 3–6), so the
  layout can be read from them; pgdata Packer uses them to tell floats from integers. Unpacking
  writes the tag `W3_PROG_5`. [observed]
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
- **Older layouts** are converted, fully by Import Program and Bulk program import, only in part by
  the `.pgdata` import: see [Program layouts and their conversion](#program-layouts-and-their-conversion).
- **Exporting while the USB drive is mounted on a computer** wrote empty (0-byte) files for the first
  programs of a bulk export; with the cable unplugged during the export, every file was complete.
  [observed in one session]

## Open questions

- Whether a 24K or 24M converts exactly as an 8M does for parts 1–2, and keeps parts 3–4.
- What the `.pgdata` import does with a converted (current-layout) program: it should leave it as it
  is, so that it matches Import Program. [inferred; to be checked]
- The 7 conversions under [Not explained](#not-explained).
- Whether Import Program accepts an unpacked `.pro` tagged `W3_PROG_5` that has an older layout.
- Whether multisamples are reused by content, as tables are.
- Whether the bulk import sorts file names plainly or by number (`B05P100` vs `B05P10`).
- The meaning of most part, float and global values.
