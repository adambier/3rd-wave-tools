# 3rd Wave file formats

This document describes the files the Groove Synthesis 3rd Wave reads and writes:

| File | What it holds |
|---|---|
| `.pro` | one program (a patch, with its sequence) as text |
| `.pgdata` | a *unified program*: one program plus the wavetables and multisamples it uses, in one binary file |
| `.wt` | one wavetable, as text |
| `.bin` | one multisample (up to 8 samples with their key ranges and loops) |

It is written for someone implementing these formats.

**What this covers, and what it does not.** The structure of each file is known well enough to
read and write every file examined byte for byte: where each part of a program is, which values
are its oscillator sources, how a `.pgdata` carries wavetables and multisamples, and how the 3rd
Wave converts programs saved by older firmware (section [6](#6-converting-older-programs), which
anyone writing a `.pgdata` has to do as well). Wavetables and multisamples are understood almost
completely (section [5](#5-wavetable-wt-and-multisample-bin)). **What most of a program's values
mean is not known.** A current program holds about 1,450 values; fewer than 60 have an identified
meaning, most of them only probably (section [3.4](#34-what-the-values-mean)). The rest, nearly
all of a program's sound settings, can be copied through unchanged but not interpreted. So this
document supports tools that read, inspect, pack, unpack, convert, move, and rename programs,
wavetables, and multisamples, but not yet tools that create a program's sound or edit its
settings.

Groove Synthesis has not published these file formats; its MIDI and SysEx specification defines
the wavetable and multisample payloads, which the files carry in the same form (section
[5](#5-wavetable-wt-and-multisample-bin)). Everything else here comes from reading real files and
from tests on a 3rd Wave 8M and a 24M, both running OS 2.0d. The PgdataFormats library in
3rd-wave-tools (`Sources/PgdataFormats`), which the pgdata Packer app uses, implements it, and its
tests cover much of it; "the library" below means this library. The repository's
[`fixtures`](../fixtures/) folder holds a small file of each kind with what it should parse to,
for checking an implementation.

## Contents

1. [Conventions](#1-conventions)
2. [Oscillator sources](#2-oscillator-sources)
3. [Program (.pro)](#3-program-pro)
4. [Unified program (.pgdata)](#4-unified-program-pgdata)
5. [Wavetable (.wt) and multisample (.bin)](#5-wavetable-wt-and-multisample-bin)
6. [Converting older programs](#6-converting-older-programs)
7. [What the 3rd Wave does on import](#7-what-the-3rd-wave-does-on-import)
8. [Names, file names, and the USB drive](#8-names-file-names-and-the-usb-drive)
9. [How this was established](#9-how-this-was-established)
10. [Open questions](#10-open-questions)
- [Appendix: values for new positions](#appendix-values-for-new-positions)

## 1. Conventions

**How sure each statement is.** A plain statement describes what every file examined does; the
test is that every file reads and writes back byte for byte (section
[9](#9-how-this-was-established)). A statement that rests on more than the files has a footnote
saying where it comes from: a test on the 3rd Wave, or Groove Synthesis's own documents and files.
Where something is reasoning that has not been checked, the text says so in words ("probably",
"not yet checked").

[^8m]: Tested on a 3rd Wave 8M (OS 2.0d), 21–23 October 2026; section
    [9](#9-how-this-was-established) lists the tests.
[^24m]: Tested on a 3rd Wave 24M (OS 2.0d), October 2026; section
    [9](#9-how-this-was-established) lists the tests.
[^both]: Tested on a 3rd Wave 8M and a 24M (OS 2.0d), October 2026; section
    [9](#9-how-this-was-established) lists the tests.
[^bulk]: Seen in the programs bulk-imported and exported again on an 8M (299 programs) and a 24M
    (300), OS 2.0d, October 2026 (section [9](#9-how-this-was-established)).
[^manual]: Groove Synthesis's user manual (v1.9).
[^spec]: Groove Synthesis's *3rd Wave MIDI CC + SysEx Spec* (v2a).
[^bank-arranger]: Groove Synthesis's Bank Arranger script.
[^smoothing]: Checked on a 3rd Wave 8M (OS 2.0d), 26 October 2026: an oscillator set to a P
    table showed **wavetable smoothing** off, and one set to a U table showed it on, without the
    setting having been changed. Not yet checked on a 24M.

**Counting and naming.** Positions inside a block count from 0: integer 34 is the 35th value of a
part's integer block, and likewise for floats and globals. Lines of a `.pro` count from 1.

**Binary files** (`.pgdata`, `.bin`) are little-endian. `u8`, `u16`, `u32` are unsigned integers of
1, 2, and 4 bytes; `f32` is an IEEE 754 single-precision float; `char[n]` is a text field of *n*
bytes (see [Names](#8-names-file-names-and-the-usb-drive)).

**Menu items.** The 3rd Wave's functions are named in bold as its Global menu writes them:
**Import program**, **Bulk program import**, **Bulk program export**, **Import unified program data
file** (called "the `.pgdata` import" here), **Bulk wavetable import**, **Export Wavetable**, and
**Wave Maker**.

**Parts.** A program has four parts (layers), numbered 1–4 on the 3rd Wave and 0–3 in the files.
The 24K and 24M play all four; the 8M plays parts 1 and 2 only.[^parts]

[^parts]: Stated by Groove Synthesis. An 8M also fits every program it imports to two parts
    (section [6.4](#64-what-an-8m-does-on-top)).

## 2. Oscillator sources

Each part has three oscillators, and each oscillator plays one *source*: a wavetable slot, an analog
wave, or a multisample slot. A program stores each oscillator's source as one integer, its *source
id*. The same ids appear in a `.pgdata`'s source table.

| Source id | Source | Slot names on the 3rd Wave |
|---|---|---|
| 0–33 | wavetable slots P00–P33 | P00 … P33 |
| 34–40 | wavetable slots U00–U06 | U00 … U06 |
| 41–47 | analog waves (order below) | A00 … A06 |
| 1000 + *k* | wavetable slot P(34 + *k*) | P34 … P47 (ids 1000–1013) |
| 2000 + *k* | wavetable slot U(7 + *k*) | U07 … U63 (ids 2000–2056) |
| 4000 + *n* | multisample slot S*n* | S00 … (the library accepts S00–S127, ids 4000–4127; the upper limit is not yet checked) |

The ranges look as if later slots were added without renumbering the earlier ones.

The analog ids are not in the order the 3rd Wave displays them:

| Id | Shown as |
|---|---|
| 41 | A00 Sawtooth |
| 42 | A01 Square |
| 43 | A04 Supersaw |
| 44 | A03 Sine |
| 45 | A05 noise; the wave offset knob sweeps white → pink → red |
| 46 | A06 noise; the wave offset knob sweeps white → blue → violet |
| 47 | A02 Triangle |

**An id names a slot, not its content.** What plays is whatever that 3rd Wave has loaded in the
slot, so two 3rd Waves can play different tables for the same program.[^8m]

**Factory slots.** P00–P35 and U00–U55 hold Groove Synthesis's factory tables; P36–P47 and U56–U63
are free for the user's own.[^factory-slots] U48–U55 became factory slots in 2025 (the factory
files for them are dated April 2025); before that, some program sets used them for their own tables.

*How this was established:* ids 34 (U00), 1000 (P34), 2000 (U07), and all seven analog ids were read
from the 3rd Wave's OSC screen for programs that use them.[^osc-ids] The rest of each range follows
from those and from the names of tables embedded in `.pgdata` files ("Wavetable P15" under id 15,
for example). P36–P47 as ids 1002–1013 is an assumption: no file using them has been seen.

[^factory-slots]: Groove Synthesis's user manual (v1.9) gives P00–P35 as the factory P tables.
    For the U tables, Groove Synthesis's support page lists U00–U55 and offers U48–U55 as a
    separate download; the manual still gives U00–U47.
[^osc-ids]: Read on an 8M's OSC screen (OS 2.0d), 21–23 October 2026.

## 3. Program (.pro)

### 3.1 Text format

A `.pro` is plain text with one value per line, LF line ends, and a final newline. (A
reader should accept CRLF as well.) Integers are written in decimal (e.g., `-12`, `2018`). Floats
are written with exactly six decimals, as C's `%f` does (e.g., `0.385000`, `120.000000`,
`-0.002000`), so a float in a `.pro` is rounded to about 1e-6. The 3rd Wave's own export writes
them the same way.

### 3.2 Layout

The first two lines are text; every line after that is one number. Call those numbers the
*program values* v[0], v[1], …: v[0] is on line 3, v[*i*] on line 3 + *i*. A `.pgdata` stores the same
program values, one 32-bit word each (section [4](#4-unified-program-pgdata)).

| Lines | Content |
|---|---|
| 1 | format tag, e.g., `W3_PROG_5` |
| 2 | program name |
| 3 = v[0] | *S*: integers per part |
| 4 = v[1] | *F*: floats per part |
| 5 = v[2] | *G*: global values |
| 6 = v[3] | *E*: event records |
| then | four **integer part blocks** of *S* values: part 1, 2, 3, 4 |
| then | four **float part blocks** of *F* values: part 1, 2, 3, 4 |
| then | *G* **global values** (integers) |
| then | *E* **event records** of 6 integers each, to the end of the file |

So the header gives the size of every section, and the file ends exactly where it says:

> number of program values = 4 + 4·*S* + 4·*F* + *G* + 6·*E*

To find a value:

| Value | Program value index |
|---|---|
| part *k* (0–3), integer *i* | 4 + *S*·*k* + *i* |
| part *k*, float *i* | 4 + 4·*S* + *F*·*k* + *i* |
| global *i* | 4 + 4·*S* + 4·*F* + *i* |
| event record *r*, field *j* | 4 + 4·*S* + 4·*F* + *G* + 6·*r* + *j* |

For the current layout (*S* = 181, *F* = 137, *G* = 182), the float blocks start at v[728] (line
731), the globals at v[1276] (line 1279), and the event records at v[1458] (line 1461).

*How this was established:* the sizes add up exactly in every `.pro` examined: 2,348 files from
Groove Synthesis (1,505) and nine third-party sets (843), and the 3rd Wave's own exports.

### 3.3 Format tags and layouts

The format tag and the four sizes vary with the firmware that saved the program:

| Tag | *S* | *F* | *G* | Where seen |
|---|---|---|---|---|
| `W3_PROG_3` | 173 | 126 | 73 or 75 | Groove Synthesis's 2022 factory banks for the 24-voice models |
| `W3_PROG_3` | 174 | 127 | 115 | the same banks (a few programs) |
| `W3_PROG_4` | 179 | 127 | 143 | third-party sets |
| `W3_PROG_4` | 180 | 130 | 169 | third-party sets |
| `W3_PROG_4` | 181 | 130 | 174, 175, or 177 | third-party sets |
| `W3_PROG_5` | 181 | 130 | 177 | third-party programs saved before mid-2025 |
| `W3_PROG_5` | 181 | 136 | 181 | saved from OS 1.9 (Groove Synthesis's 2025 factory banks) |
| `W3_PROG_5` | 181 | 137 | 182 | **current**: written by OS 2.0d |

Each newer layout keeps the older values in place and adds new ones at the end of each
section; section [6](#6-converting-older-programs) describes what else changes. Groove Synthesis's
Bank Arranger script also accepts `W3_PROG_2`,[^bank-arranger] but no such file has been seen.

### 3.4 What the values mean

Only a few values are understood: the oscillator sources and a few dozen others, most of them only
probably. The rest, nearly all of a program's sound settings, can be copied through unchanged but
not interpreted.

**Integer part blocks**

| Value | Meaning |
|---|---|
| 0, 1, 2 | Source ids of oscillators 1, 2, and 3 (section [2](#2-oscillator-sources)).[^osc-ids] |
| 34 | Amp envelope amount, probably (3rd Wave Terminal labels it Amp Env Amount); 100 = +100, and setting the amount to 127 on an 8M wrote 127.[^edited] A `W3_PROG_3` program packed unconverted, with 0 here, plays silently (section 6.1).[^8m] Groove Synthesis's 8M "Init Program" carries 0 here (and 1.0 in float 113) and is not silent, so this is not the only route to the amplifier. |

**Float part blocks**

| Value | Meaning |
|---|---|
| 6, 7, 8 | The three oscillators' levels, probably, as level ÷ 100: setting oscillator 1 to 100 and oscillator 2 to 0 on the 3rd Wave wrote 1.0 and 0.0 (oscillator 3, already at 0, had 0.0).[^edited] |
| 53 | Tempo in BPM, probably (3rd Wave Terminal shows 102.000000 as 102.0 BPM). |
| 98 | A filter cutoff, probably: setting both filters' cutoffs to 127 changed it from 0.535 to 1.0 (float 99, already 1.0, may be the other filter's).[^edited] |
| 112 | The part's level, probably, as level ÷ 100: a part set to 170 wrote 1.7, and a part set to 0 wrote 0.0.[^edited] |
| 113 | Probably a second amp envelope amount, 0 = full, 1 = none; in a `W3_PROG_3` program OS 2.0 folds it into integer 34 when converting.[^bulk] OS 2.0d still writes both: setting the amp envelope amount to 127 wrote integer 34 = 127 and float 113 = 0.0, from 0 and 1.0.[^edited] |
| 124 | Pan, probably (3rd Wave Terminal's Pan knob): 0 = left, 0.5 = center, 1 = right. |

Values that changed together when a program was edited on the 3rd Wave so that both envelopes
had 0 attack, decay, release, and delay with sustain 127, the wave envelope was off, the mod wheel
was routed to every oscillator's wave offset at 127, and nothing else was modulated: part 1's
integers 5, 21, 25, 26, 29, and 30 (2, 34, 87, 80, 74, and 82 → 0) and globals 9, 146, 147, 179,
and 180. Which value holds which setting has not been separated.[^edited]

[^edited]: One program on an 8M (OS 2.0d), 26 October 2026: Groove Synthesis's "Init Program"
    (8M factory bank) with its sources changed, imported, edited on the 3rd Wave as described,
    and exported; every value that differs between the two files is accounted for here or in
    section 6.3 (float 102). "Probably" because the attribution of each value to a setting rests
    on that one comparison.

**Global values.** These apply to the whole program. Apart from value 0, the meanings below are
inferences: from how the values change when the 3rd Wave converts or fits a program to an 8M, from
how they line up with the event records, and, for value 1, from 3rd Wave Terminal's display.

| Value | Meaning |
|---|---|
| 0 | Set by the importing model: 3 on an 8M, 2 on a 24M (section 6.3); 1, 2, or 4 in older files.[^bulk] |
| 1 | Velocity curve: 3rd Wave Terminal shows 5 as "Piano", 2 as "Medium", and 3 as "Heavy". |
| 11 | The selected part, 0–3. |
| 18 | Number of keyboard split points, 0–3; 0 = no split. |
| 21, 22, 23 | The split points, as note numbers: notes above value 21 belong to zone 2, above 22 to zone 3, above 23 to zone 4. |
| 24, 25, 26, 27 | The parts each keyboard zone plays, as a part mask (below). Without a split, value 24 is the *layer*: the parts that sound together. |
| 37, 38, 39, 40 | One per part: 1 when that part is selected. |
| 120–123, 124–127, 132–135 | One per part, for settings that layouts with 120 globals or fewer stored once (as globals 12, 13, and 15). |

A **part mask** is a sum of 1 (part 1), 2 (part 2), 4 (part 3), and 8 (part 4): 3 means parts 1 and 2,
15 all four.

**Event records.** Each record is six integers:

> *target*, *a*, *type*, *b*, *time*, 0

| *type* | What it is | Fields |
|---|---|---|
| 2 | a sequencer note | *b* = velocity × 256 + note number; the meaning of *a* is unknown |
| 1 | automation | e.g., `1 108 1 <bits> <step> 0`: *a* is probably the parameter (108 is the most common of about 20 values seen), *b* a float stored as its 32-bit pattern; often one record per part and step (steps 0, 64, 128, …) |
| 0 | unknown | seen only in a few `W3_PROG_5` files |

*target* says which parts the record applies to. In `W3_PROG_5` it is a part mask; in `W3_PROG_3`
and `W3_PROG_4` it is a part number, 0–3. Records are kept in the order they appear; the unit of
*time* is unknown. Groove Synthesis's Bank Arranger script treats a non-zero *E* (line 6) as "this
program has a sequence".[^bank-arranger]

*How this was established:* the note encoding is an inference: the low byte of *b* decides which side
of a keyboard split the 3rd Wave sends a note to when it converts an old program, and the high byte
stays between 1 and 128. The type-1 reading is an inference from its regular pattern.

### 3.5 Reading and writing a `.pro`

To read: split into lines; line 1 is the tag, line 2 the name; take *S*, *F*, *G*, *E* from the
next four lines and check that the count adds up; then parse the lines in the float blocks (section
3.2) as floats and every other line as an integer. (Deciding by the text instead, "a line with a `.`
is a float", works for every file the 3rd Wave writes, but a float block line written `1` by some
other tool would then be read as the integer 1 and packed as the wrong 32-bit pattern.) When the
count does not add up: a file with more values than the header declares carries the tail of a
longer file it was exported over (section [7](#7-what-the-3rd-wave-does-on-import)), and the extra
values can be dropped; one with fewer is cut short and should be refused. To write: the same in
reverse, floats with `%f`. Keeping each line's original text lets an unmodified file be written
back byte for byte, which is how the library's reader is tested.

## 4. Unified program (.pgdata)

A `.pgdata` is a program together with the wavetables and multisamples it uses, so that it plays the
same on another 3rd Wave. It has no format tag: its program part is always expected to be in the
current layout (see [6](#6-converting-older-programs)).

It is a container. Its own layout is fully known; the program values inside it are a `.pro`'s
(section [3.4](#34-what-the-values-mean)).

### 4.1 Layout

```
offset  type          content
0       char[16]      "W3_UNIPROG_1", padded with NUL bytes
16      u8            N, the number of sources
17      N × 4 bytes   source table, entry k (k = 0 … N-1):
                        u8  k
                        u8  type: 0 = P table, 1 = U table, 2 = analog wave, 4 = multisample
                        u16 source id (section 2)
then    N records     one per source, in the same order:
                        u8  type (as above)
                        u8  k
                        u8  has_data: 0 = listed only, 1 = data follows
                        if has_data and type 0 or 1 (wavetable):
                          char[32]  table name
                          f32 × 16,384 (P) or 131,072 (U): the table's values
                        if has_data and type 4 (multisample):
                          the body of a v5 .bin (section 5.2, from the sample count on)
then    char[32]      program name
then    u32 × …       the program values v[0], v[1], … (section 3.2), one word each, to the
                      length the header declares: int32 for integers, f32 for floats; anything
                      after it is left over from an export onto a longer file (section 7)
```

**Oscillator sources point into the source table.** In the program words, the twelve oscillator
values (integers 0–2 of each part) hold the index *k* of a source-table entry instead of a source
id. Everything else is the `.pro`'s values unchanged. The type codes (0 P, 1 U, 2 analog, 4
multisample; 3 unused) match the slot-kind codes of the 3rd Wave's SysEx protocol.

**To unpack** a `.pgdata` into a `.pro`: read the program words; tell floats from integers using
*S*, *F*, *G*, and *E* in the first four words (section 3.2); replace each oscillator's index with the
source id from the table; write the tag `W3_PROG_5` and the name. Each embedded wavetable becomes a
`.wt` and each multisample a `.bin`.

To unpack a program in an older layout (section 3.3), convert it (section 6); the conversion needs
the format number, which a `.pgdata` does not carry, so it has to be read from the layout:
*S* = 173 or 174 means `W3_PROG_3` and 179 or 180 means `W3_PROG_4` (true of every file seen);
*S* = 181 with *F* below 136 was written by both `W3_PROG_4` and `W3_PROG_5`, which differ only in
how event records name parts (section 3.4), so look at the note and automation records (types 1
and 2): a target above 3 means `W3_PROG_5`; otherwise a target 0 means `W3_PROG_4`; with neither,
assume `W3_PROG_5`. This rule is an inference from the files, not checked on the 3rd Wave. The same rule serves a `.pro` whose tag disagrees with its layout
(a `W3_PROG_5` tag on a 173-value layout, as an unpacker that does not convert would write): go by
the layout, except that a 181-integer layout with fewer than 136 floats keeps a tag of 4 or 5.

**To pack** a `.pro`: list each source the program uses, in order of first use (part 1 oscillator 1
first), replace the oscillator values with their indices, and embed or just list each source.
Analog waves are always listed without data. A wavetable or multisample can be embedded, or listed
without data when the receiving 3rd Wave is expected to have it in that slot (for example, factory
tables).

### 4.2 What real files contain

- The 3rd Wave's own export embeds every wavetable a program uses, factory tables included, and lists
  only sources the program actually uses.[^8m]
- Groove Synthesis's sample library lists factory tables without data. Files built that way import
  and play correctly.[^8m]
- Embedded wavetables are bit-identical to the `.wt` files they came from (325 compared), and
  embedded multisamples to the body of their v5 `.bin`.
- The 3rd Wave's exports are always in the current program layout.

*How this was established:* the layout reads and rewrites byte for byte 221 files from Groove
Synthesis, third parties, and the 3rd Wave's own exports. Files that the library builds
import correctly.[^both]

## 5. Wavetable (.wt) and multisample (.bin)

### 5.1 Wavetable (.wt)

Plain text, LF or CRLF line ends.

| Line | Content |
|---|---|
| 1 | `PNAME` for a P table, `UNAME` for a U table |
| 2 | the table's display name |
| 3 … | one float per line, as a C literal with an `f` suffix (`0.963237f`, `1.38777878078e-17f`); lines starting with `//` are comments |

- A **P table** has 16,384 values and a **U table** 131,072 (below).
- The file has no slot number; the slot is chosen when it is imported.[^8m]
- Number formatting varies between files: Groove Synthesis's factory P tables use 12–14 digits and
  exponents. The library writes six decimals when that gives back the exact float, and the
  shortest exact form otherwise.

**P tables (PPG-style).** The P set is the 3rd Wave's form of the PPG Wave's wavetables. P00–P31
are derived from the PPG Wave 2.2/2.3's own tables (P30 is the PPG's *upper wavetable*), P32 and
P33 are Groove Synthesis's, P34 and P35 hold the Prophet VS waveforms; 48 slots in all, the rest for
the user's own.[^manual] The format:

- **64 frames of 128 points**, a frame being one cycle (the manual and the PPG say *wave*; this
  document says *frame*, as the rest of the project does). The file stores each point as a pair,
  the sample and then the difference to the next sample of the same frame (the last point's
  difference leads back to the first), so a frame takes 256 values and the table 16,384. The difference is
  derived data: in every factory P table examined it equals the next sample minus this one to
  float precision, and over SysEx the 3rd Wave sends a P table as 64 × 128 plain samples.[^p-diff]
  A writer should compute the differences
  from the samples; what the 3rd Wave does when a file's differences disagree with its samples has
  not been tested.
- **The samples are floats within ±1**, not quantized to the PPG's 8-bit levels, although the
  manual calls the P set "8-bit" and says the **Wave Maker** converts imported audio "to the correct
  sample rate and bit depth" for it. So any reduction the 3rd Wave applies is presumably made when
  it imports or plays a table, and is not recorded in the file.
- **Positions 60–63 hold the PPG's four standard waveforms** (60 a triangle, 61 a narrow pulse, 62 a
  square, 63 a sawtooth) in the tables that came from the PPG: every PPG wavetable had only 60
  frames of its own, and these four were always the same;[^manual] P00, P01, P23, and P27 show
  this. It is a property of the content, not of the format: P33 and the Prophet VS table P34 use
  all 64 positions for their own frames.

How a P table *plays* is set in the program, not the file, by three settings in the oscillator's
Wave Flow menu meant to reproduce the PPG:[^manual] **wavetable smoothing** (interpolation
between neighboring frames), **waveform smoothing** (interpolation within the frame and of pitch),
and **use upper wavetable**. By default, **wavetable smoothing** is off for an oscillator playing
a P table and on for one playing a U table,[^smoothing] so a P table steps from frame to frame
and a U table blends between them unless the program says otherwise. With **use upper wavetable**
on, a sweep past position 63 continues
into P30, the PPG's upper wavetable; with it off, the 3rd Wave sweeps positions 0–59 only, and
60–63 are reached by setting the wave offset there with the wave envelope off. That is why a P
table's last four frames look unrelated to the rest. The user manual's "About Wave Flow and the
Upper Wavetables", "Importing Wavetables into the P Set", and "How to Sound Like a Vintage PPG"
have more.

**U tables: the table and its mipmaps.** A U table is 64 frames of 1,024 samples: the manual's
**Wave Maker** chapter says "the period length that the 3rd Wave uses is 1024 samples" and takes a
64 × 1,024-sample `.wav` as a ready-made table, and the SysEx spec defines the U payload as
65,536 floats, "64 different waveforms ... each with a length of 1024 samples".[^manual][^spec] The
131,072 values of a U `.wt` are that table followed by progressively band-limited, smaller copies
of the same 64 frames (a mipmap chain, of the kind usually played at higher pitches):

| Values | Content |
|---|---|
| 0 – 65,535 | the table: 64 frames × 1,024 samples |
| 65,536 – 98,303 | the same 64 frames at 512 samples each |
| 98,304 – 114,687 | at 256 samples each |
| 114,688 – 122,879 | at 128 samples each, band-limited |
| 122,880 – 126,975 | at 64 samples each, band-limited further |
| 126,976 – 131,071 | at 64 samples each again, band-limited further still (only the lowest few harmonics) |

All 56 factory U tables have this layout, and the 8M's own `.pgdata` exports carry all 131,072
values; a SysEx dump of U08 from a 24M equals the file's first 65,536 values exactly.[^24m] Frame *f* of each level
corresponds to frame *f* of the table, with the harmonic amplitudes of the base frame up to each
level's cutoff and a small gain change; in tables made from recorded audio the smaller copies are
also shifted in phase by a constant, so they were probably made with a real filter, not an ideal
resample.

**The 3rd Wave does not use the chain.** A `.wt` carrying a known table with its second half zeroed
is matched to the loaded table by its first 65,536 values alone (so the content hash covers only
the table); one carrying a new table with a zeroed chain is stored, plays identically from C2 to
C7, and exports again with the zeros intact.[^24m] So the chain is kept and
passed through but neither hashed nor played; a writer should still fill it with band-limited
resamples of its frames, as the factory files do, in case a later firmware reads it. The P set has
no such chain: PPG-style playback is meant to alias.

[^p-diff]: Checked in six P tables embedded in Groove Synthesis's `.pgdata` files (five exactly,
    the Prophet VS table within 1e-6) and in SysEx dumps from an 8M.

### 5.2 Multisample (.bin)

Binary; 13 files were examined, in versions 1, 4, and 5.

```
offset  type        content
0       char[16]    "W3_MSAMPLE_5" (or _1, _4), padded with NUL bytes
16      u8          number of samples, up to 8
17      char[32]    slot name
49      samples, one after another, to the end of the file
```

Each sample (version 5):

| Field | Type | Notes |
|---|---|---|
| length | u32 | in samples (the audio is mono; one int16 value each) |
| sample rate | f32 | the recording's rate, e.g., 48000 |
| bit depth | u8 | the recording's: 0 = 8-bit, 1 = 12-bit, 2 = 16-bit |
| name | char[32] | |
| start, end, loop start, loop end | u32 × 4 | sample positions |
| root note, low note, high note | u8 × 3 | the note the recording is assigned to, and the key range it plays, as MIDI note numbers |
| loop mode | u8 | 0 off, 1 on while the note is held, 2 always on |
| crossfade length | u32 | in samples |
| crossfade type | u8 | 0 off, 1 equal volume, 2 equal power |
| pitch | f32 | −1.0 to 1.0 |
| second rate | f32 | not in the SysEx record. Equal to the sample rate in all but 40 of 1,270 samples seen; in those it is another standard rate (12,000, 22,050, 44,100, or 48,000), so it is probably the rate the sample is played back or was resampled at |
| volume | f32 | multiplier, 0.0 to 2.0 |
| audio | int16 × length | |

The field meanings and ranges come from Groove Synthesis's *3rd Wave MIDI CC + SysEx Spec* (v2a),
whose "set multisample" message carries the same fields in a different order, without the name
and the second rate.[^spec] It also requires a multisample's samples to be in increasing order
of assigned note; all 278 multisamples seen (1,270 samples, in `.bin` files and `.pgdata`
records) are. Their volumes lie within 0.6–2.0, and their pitches within ±1.

Version 4 lacks the volume. Version 1 also lacks the sample rate and bit depth (after the length),
and the pitch and second rate. To upgrade an older file, fill in what the 3rd Wave itself uses:
48,000 Hz, 16-bit, pitch 0, second rate = sample rate, volume 1.0, as Groove Synthesis's version 1
and version 5 copies of the same multisample show. The file has no slot number.[^8m]

## 6. Converting older programs

### 6.1 Why

The 3rd Wave converts a program in an older layout (section 3.3) when it imports it. But only
**Import program** (`.pro`) and **Bulk program import** do the whole conversion. The `.pgdata` import
converts the layout but skips several changes that depend on the format, and a `.pgdata` carries no
format tag that would tell it which to apply.[^both]

| What | Original `W3_PROG_3` | After **Import program** | After `.pgdata` import |
|---|---|---|---|
| Integer 34, parts 1–2 | 0 | **100** | 0: the program is silent |
| Global 1 (velocity) | 5 | **2** | 5 |
| Event records | 16 notes + 4 × 63 automation | 16 notes (mask 3) + automation for parts 1–2 | no notes; automation for 3 parts |

(Groove Synthesis's 2022 factory program "House Organ 1"; every other value comes out identical.)

So a program in an older layout must be converted before it is packed. A program already in the
current layout comes through the `.pgdata` import unchanged, apart from the few values each model
sets on every import (section 6.3).[^both]

### 6.2 The conversion

These are the steps **Import program** applies, as the library's `ProgramConverter` implements
them: steps 1–5, then the model's own values (section 6.3). They produce the **4-part result**,
what a 24M makes of the program; an 8M fits it to two parts (section 6.4), and does so by itself on
importing the `.pgdata`.[^8m] "Old global *n*" means the value before conversion. The steps
are written for the layouts in section 3.3; the library applies them to any `W3_PROG_3`, `_4`, or `_5`
program with 173–181 integers, 126–137 floats, and 73–182 globals per the header, and packs anything
else as it is, with a warning.

**Step 1. Extend each section.** Keep every old value in its position and append new ones:

- each integer part block: 0s up to 181 values;
- each float part block: up to 137 values, all 0.0 except value 127 = 4.0;
- the globals: up to 182 values, from the table in the [appendix](#appendix-values-for-new-positions).

If the old layout had 120 globals or fewer, three of the per-part groups are filled from the old
single values instead: globals 120–123 = old global 12, 124–127 = old global 13, 132–135 = old
global 15 (128–131 still come from the appendix).

**Step 2. Values set in every layout.** In each of the four parts:

- floats 85 and 116 become 0.0 (written `0.000000` even where the old value was `-0.000000`), and
  float 102 becomes 1.0 (0.446233 for a `W3_PROG_3` program on a 24M: section 6.3);
- float 115 becomes 1.0 where it was 0.0 (seen in 12 parts, all of them parts 3–4 on the 24M);
- floats 91 and 95 become 1.0 where they were above 1.0 (seen in a few `W3_PROG_3` programs, the
  only files with such values);
- integers 63, 64, and 65 become 1 where they were 0;
- if all three oscillators are A04 Supersaw (id 43), oscillator 3 becomes A00 Sawtooth (id 41)
  (probably because OS 2.0 allows two supersaws per part).

In the globals, whatever they were: 2 = 0, 36 = 0, 75 = 1, 76 = 2, 77 = 2, 78 = 0, 79 = 0, 81 = 1,
82 = 1, 115 = 1, 140 = 0, 142 = 0, 152 = 1, 153 = 0, 173 = 0, 175 = 2, 177 = 0, 178 = 1 (a
non-zero 177 was seen only on the 24M). Globals 0, 80, and 174 are set too, by model: see section 6.3.

**Step 3. `W3_PROG_3` only:**

- amp envelope: integer 34 of each part increases by 100 × (1 − float 113), computed in double
  precision and rounded to the nearest whole number (halves away from zero), with the result capped
  at 127;
- velocity: global 1 becomes 2 where it was 5.

**Step 4. Event records (`W3_PROG_3` and `W3_PROG_4`):** replace each record's *target*, a part
number *n*, with a part mask. Keep every record, in order. The mask is 2<sup>*n*</sup> (0 when *n*
is outside 0–3), with two exceptions for notes (type 2):

- **in a layered program** (old global 18 = 0), a note for a part in the layer (old global 24)
  gets the whole layer's mask; a note for a part outside the layer keeps 2<sup>*n*</sup>;
- **in a split program** (old global 18 = 1–3), a note gets the mask of the zone its key falls in:
  count the split points (old globals 21 up to 20 + global 18) the note number is above, and take
  old global 24 + that count. The part it was recorded on is ignored.

A record of another type with a target outside 0–3 gets mask 0; the 24M keeps such records and the
8M drops them (seen once: 335 records of type 255, target 255). `W3_PROG_5` records already use
masks and stay as they are.

**Step 5. Header:** tag `W3_PROG_5`, sizes 181, 137, 182, and the new number of event records.

*How this was established:* programs were bulk-imported and exported again on both models, OS 2.0d
(section 9): 299 on an 8M (100 `W3_PROG_3`, 76 `W3_PROG_4`, 123 older `W3_PROG_5`, ten layouts) and
300 on a 24M (the same 2022 factory bank and third-party programs, plus Groove Synthesis's 2025
factory bank 1, which uses parts 3–4 throughout). Every step above holds in all of them, except
where noted in 6.5; the counts of programs each step was seen in are in `ProgramConverter.swift`.
That a 24K converts as the 24M does is an assumption: no 24K was available.

### 6.3 Values each model sets

A few values come out differently on the two models, the same way on every import, including the
`.pgdata` import of a program already in the current layout. They seem to mark a program as the
importing model's own: a file carrying the 8M's values, imported into a 24M, comes out with the
24M's.[^24m]

| Value | 8M | 24M |
|---|---|---|
| Global 0 | 3 | 2 |
| Global 80 | 1 | 0 |
| Global 174 | 1 | 0 |
| A float written `-0.000000` | kept | becomes `0.000000` |
| Float 102 of a `W3_PROG_3` program, by **Import program** | 1.0 | 0.446233 |
| Float 102, by the `.pgdata` import | 1.0 | 1.0 |

Since each model overwrites them, what a file carries for these does not matter. When it converts a
program, the library writes the 24M's **Import program** values; a program already in the current
layout keeps what it carries. Float 102 is the one value a `.pgdata` cannot carry
into a 24K/24M as **Import program** would set it, since the `.pgdata` import makes it 1.0 whatever
the file says. The difference is not audible: the same `W3_PROG_3` program imported both ways on a
24M sounds the same and shows identical parameters in an editor; only the sequencer piano roll's
scroll position differs, which may be what the value stores.[^24m] On the 8M, a current-layout
program imported with **Bulk program import**, edited, and exported came back with 0.591133 in
float 102 of both parts (the file had carried 1.0), so the value is not fixed per model either;
a stored view position would fit.[^edited]

### 6.4 What an 8M does on top

On an 8M, every import (**Import program**, **Bulk program import**, and the `.pgdata` import) also fits the
program to two parts:[^8m]

- parts 3 and 4 are replaced with the 8M's filler (oscillators P02, U01, and A01 Square; full list
  in the [appendix](#appendix-values-for-new-positions)), the same filler found in every program
  saved on an 8M;
- globals 24 and 25 keep only parts 1 and 2 (mask & 3); globals 18 and 19 are limited to 1, and
  globals 124, 125, and 127 to 8 (126 is left alone);
- the selection flags for parts 3 and 4 (globals 39 and 40) are cleared; if part 3 or 4 was selected
  (global 11 = 2 or 3), part 1 is selected instead, or part 2 in a split program, and that part's
  flag (global 37 or 38) is set, except in an unsplit program whose layer (global 24) held only
  parts 3 and 4: then no flag is set (seen in 6 programs);
- every event record's mask keeps only parts 1 and 2 (mask & 3), and a record left with mask 0 is
  dropped. This applies to `W3_PROG_5` records too.

Sequence notes recorded on parts 3 and 4 of a `W3_PROG_3` or `W3_PROG_4` program are treated
differently by the two imports:

- **Import program** cuts a split to its first split point, so in step 4 a note is zoned with one
  split point and masks from old globals 24 and 25 only; without a split, a note recorded on part 3
  or 4 is dropped even when the layer includes part 1 or 2. (So notes from a split's upper zones
  move to part 2 and play with part 2's sound.)
- **`.pgdata` import** applies step 4 as written, then the mask rule above: a note whose mask names
  only parts 3–4 is dropped, and one that also names part 1 or 2 keeps those.

The library's converter can also produce **Import program**'s 8M result directly (`Model.eightM`);
that is used only to check the rules against the 8M's exports.

### 6.5 Accuracy, and the 3rd Wave's fixes to its 2022 programs

The converter matches the 3rd Wave's own export byte for byte for 292 of the 299 programs on the 8M
and 292 of the 300 on the 24M, including every `W3_PROG_4` and `W3_PROG_5` program. The rest are
eight `W3_PROG_3` factory programs from 2022 (seven of them on both models) that the firmware
**fixes individually on import, keyed by the program's name**:[^24m]

- in 3, global 1 (velocity) is 3 rather than 2;
- in 1, part 2 becomes a copy of part 1 panned the other way (float 124: 1 in part 1, 0 in part
  2), the layer becomes parts 1–2, the tempo (float 53) 102 in every part, and velocity 3;
- in 2, a few values in parts 1–2 change (integers 30 and 33, floats 17, 44, and 103);
- in 1, the tempo goes from 120 to 122 in parts 1–2 (all four on the 24M);
- in 1, on the 24M only, integer 143 goes from 8 to 0 in parts 1 and 2.

The fixes are not the 2025 factory versions of these programs (several of those differ in hundreds
of values), and nothing in the files predicts them. That they go by name was shown by importing the
second program above twice: byte for byte as distributed but with one letter of its name changed,
it received the ordinary conversion only; under its own name with one value of its unused part 3
changed, it received the whole fix. So no other program will ever trigger them, and the library
does not reproduce them: one of these eight programs packed from its 2022 file plays as that file
describes. The `.pgdata` import does not apply them at all: neither to one of these programs
already converted to the current layout nor to the unconverted 2022 file, which comes through with
its blank part 2, tempo 120, and velocity curve 5.[^both]

## 7. What the 3rd Wave does on import

Tested on an 8M (OS 2.0d) unless a footnote says otherwise; section
[9](#9-how-this-was-established) lists the tests.

- **Wavetables are matched by content.** If the 3rd Wave already has a table with the same values, in
  any slot and under any name, the program is pointed at that slot and nothing is stored; the slot
  keeps its own name. (The SysEx spec shows the mechanism: the 3rd Wave keeps a hash id for every
  wavetable and multisample "to lookup whether a wavetable or multisample is already loaded".[^spec])
  **Multisamples are reused the same way:** a second `.pgdata` carrying the same
  multisample under another slot label is pointed at the slot the first import filled, and no
  second copy is stored.[^24m]
- **A new wavetable or multisample goes into a free slot**, and the program is pointed there: the
  slot in the file is only a label. With no free slot, the 3rd Wave offers to overwrite its last
  table(s). Blank placeholder tables count as used.
- **Bulk wavetable import asks for a starting slot** and has been observed to write the files
  into consecutive slots from there, in plain character order of their names, with no overwrite
  prompt: eight `.wt` files (four P, four U) with U55 chosen as the start went into P36–P39 and
  U55–U58, U55 being the last slot of the 2025 factory set (once, on the 8M).[^wt-import]
- **A source listed without data** plays whatever is in that slot; an empty multisample slot plays
  silence, with no warning.
- **Import program** asks for a name for the new program (defaulting to the one in the file); the
  `.pgdata` import does not.
- **Older layouts** are converted fully by **Import program** and **Bulk program import**, which give
  byte-identical results, and only in part by the `.pgdata` import (section 6).
- **An 8M fits every imported program to two parts** (section 6.4), and each model sets a few
  values of its own on every import (section 6.3).[^both]
- **The `.pgdata` import takes the first `.pgdata` file in `PROGRAMS`**, in alphabetical order; it
  does not offer a choice.[^24m] **Bulk program import** takes the files in plain
  character order, so `B05P100` comes between `B05P10` and `B05P11`; a batch that includes a program
  100 therefore needs three-digit numbers throughout.[^24m]
- **An export onto an existing file has been observed not to shorten it.** A bulk export over a
  longer file of the same name left the end of the old file after the new program (once, on the
  24M). Empty `PROGRAMS` before exporting.
- **Exporting while the USB drive is mounted on a computer** has been observed to write empty
  (0-byte) files for the first programs of a bulk export; with the USB cable unplugged during the
  export, every file was complete (one session).

## 8. Names, file names, and the USB drive

- **Name fields** (`char[32]` in `.pgdata` and `.bin`) hold up to 31 single-byte characters followed by
  a NUL; the rest of the field is padding, normally NUL. The 3rd Wave displays all 31 characters
  for programs, wavetables, and multisamples.[^8m] A `.pro` stores the name as line 2.
- **Program locations** display as `B4-P003`: bank 1–5, program 001–100.[^8m]
- **The 3rd Wave's exports** are named `B05P094.pro` (three-digit program) and
  `B05P09_Name.pgdata` / `B05P100_Name.pgdata` (program number with at least two digits; spaces
  become underscores; punctuation other than hyphens is dropped).[^8m] **Export Wavetable**
  names its files `01.wt`, `02.wt`, … from a counter the 3rd Wave keeps (the counter is not reset
  by emptying the folder), not by slot.[^24m] The 3rd Wave ignores
  file names when importing.[^file-names]
- **The USB drive** (volume `THIRDWAVE`) shows the folders `PROGRAMS` (`.pro` and `.pgdata`), `WAVES`
  (`.wt`), `AUDIO` (`.bin` and exported `.wav`), and `FIRMWARE` when mounted on a Mac.[^8m]
  Groove Synthesis's READMEs write them as `program/`, `waves/`, and `audio/`.

[^wt-import]: 8M, OS 2.0d, 26 October 2026: the wavetable-conversion test of pgdata Packer 1.1
    (eight tables written by the app's Wavetables page). The P slots were free; U55 was chosen
    as the starting U slot in the import's prompt.
[^file-names]: Stated by Groove Synthesis. The hardware tests in section
    [9](#9-how-this-was-established) also imported files under names of their own.

## 9. How this was established

**Files examined.** Groove Synthesis's factory banks (the 2022 and 2025 banks for the 24-voice
models and the 2025 8M banks: 1,500 `.pro` and 38 `.pgdata`), its sample library (45 `.pgdata`) and
sampling examples, its Bank Arranger script, nine third-party program sets (843 `.pro` and
150 `.pgdata`), and programs exported by a 3rd Wave 8M and a 24M. **Documents:** the
user manual (v1.9) and the *3rd Wave MIDI CC + SysEx Spec* (v2a), whose wavetable and multisample
messages carry the same data as the files; footnotes cite them where a statement rests on them. The library's
reader is tested by reading files and writing them back: every file checked comes back byte for
byte (`.wt` files value for value), most recently 703 files in one run. The exceptions are 12 third-party `.pgdata` files that
are damaged as distributed (empty or cut short).

**Tests on a 3rd Wave 8M and 24M (OS 2.0d), October 2026** (8M unless marked):

| What was tested | Result |
|---|---|
| Source ids read on the OSC screen | ids 34, 1000, 2000, and 41–47 as in section 2 |
| `.pgdata` listing factory tables without data | imports and plays from the factory slots |
| A table identical to a factory one, labeled with another slot; the same content under a new name; a new table under a factory name | reused, reused, stored as new: matching is by content |
| A new table or multisample labeled with an occupied or blank slot | stored in a free slot (or after an overwrite prompt), program repointed |
| Multisample slot listed without data, slot occupied / empty | plays that slot / silent, no warning |
| 31-character names | displayed in full |
| Wave Flow defaults: an oscillator set to a P table, and one set to a U table | **wavetable smoothing** off for the P table, on for the U table (section 5.1) |
| The 3rd Wave's own `.pro` and `.pgdata` exports | file names and contents as in sections 4 and 8 |
| A `W3_PROG_3` program packed unconverted, against **Import program** | silent; the differences in section 6.1 |
| 299 programs (100 `W3_PROG_3`, 76 `W3_PROG_4`, 123 `W3_PROG_5`) bulk-imported and exported | the conversion rules in section 6 |
| The same program through **Import program** and **Bulk program import** | byte-identical |
| 5 programs converted by the library for the 8M, packed, imported | exported exactly as converted; 4 identical to **Import program**'s result, the fifth differing only in its velocity fix (section 6.5), which the `.pgdata` import did not apply |
| 2 programs converted with parts 3–4 kept, packed, imported into the 8M | parts, globals, and all values identical to **Import program**'s result; sequence notes for parts 3–4 as in section 6.4 |
| 24M: 300 programs (the same 100 `W3_PROG_3` and 100 third-party programs, and Groove Synthesis's 2025 factory bank 1) bulk-imported and exported | the 4-part conversion in section 6.2 |
| 24M: 3 programs converted for 24 voices, packed, imported, two of them carrying the 8M's values | the 24M's values restored on import; otherwise identical to **Import program**'s result except float 102 (section 6.3) |
| 24M: the 2022 program of section 6.5 that gains a copy of part 1, bulk-imported renamed and, separately, under its own name with one unused value changed | renamed: ordinary conversion only; own name: every fix; the fixes are keyed by name |
| 24M: three `.pro` files named `B05P10`, `B05P100`, `B05P11`, bulk-imported | landed in that order: plain character order |
| 24M: a `.pgdata` carrying factory U08 with its mipmap chain zeroed | matched to U08: the hash covers the table only |
| 24M: a `.pgdata` carrying a new U table (U08 at half level) with its chain zeroed, then **Export Wavetable** | stored in U56, played the same from C2 to C7, exported with the zeros intact: the chain is not used |
| 24M: the 2022 program of section 6.5 that gains a copy of part 1, packed unconverted (`W3_PROG_3` layout) and imported with the `.pgdata` import | part 2 still blank, tempo 120, velocity 5: the fixes are not applied; parts 1 and 2 both shown active (cause not examined) |
| 24M: two `.pgdata` files carrying the same multisample labeled S20 and S21 | the first stored it in S11 ("Updating sample voice memory"); the second pointed its program at S11 ("Updating Sample Data"): reused by content |

**Implemented from this document alone.** As a check that section 6 describes the conversion fully
enough to reproduce it, a converter was written by
someone given only this document (no access to the library or the files) and run against the 599
exports above. It matched them to exactly the extent the library does: all but the programs listed
in section 6.5, plus float 102 on the 24M (section 6.3).

## 10. Open questions

- Whether a 24K converts exactly as the 24M does.
- Whether **Import program** accepts a `.pro` tagged `W3_PROG_5` that has an older layout, as an
  unpacker that does not convert would write it (the library converts every layout it knows, and
  writes others as they are, with a warning).
- The meaning of most part, float, and global values, and of event fields *a* and *time*.

## Appendix: values for new positions

**New global positions.** When a program is converted (section 6.2, step 1), new global positions
get these values. Positions 120–127 and 132–135 are filled from the old file instead when it had 120
globals or fewer; the values set in step 2 override these; and 80 and 174 are shown as the 8M sets
them, the 24M sets 0 (section 6.3).

| Globals | Values, in order |
|---|---|
| 73–79 | 0 1 1 2 2 0 0 |
| 80–89 | 1 1 1 0 15 15 15 15 0 0 |
| 90–99 | 0 0 0 0 0 0 0 0 0 0 |
| 100–109 | 0 0 0 0 0 0 0 0 0 0 |
| 110–119 | 0 0 0 0 0 1 0 1 2 3 |
| 120–129 | 0 0 0 0 1 1 1 1 0 0 |
| 130–139 | 0 0 0 0 0 0 0 0 0 0 |
| 140–149 | 0 0 0 0 0 0 1 0 0 0 |
| 150–159 | 0 0 1 0 0 0 0 0 0 0 |
| 160–169 | 0 0 0 0 0 0 0 0 0 0 |
| 170–179 | 0 0 0 0 1 2 0 0 1 0 |
| 180–181 | 0 0 |

New float positions (126–136 of each part) are 0.0, except 127 = 4.0. New integer positions
(173–180 of each part) are 0.

**The 8M's filler for parts 3 and 4** (section 6.4), as the 8M writes it in every program it
imports or saves (the same in 299 imports and 500 factory programs). Integers:

| Integers | Values, in order |
|---|---|
| 0–19 | 2 35 42 0 0 2 0 0 0 0 0 1 0 1 0 0 0 0 0 0 |
| 20–39 | 0 34 0 0 0 87 80 0 0 74 82 0 0 0 0 0 0 0 0 0 |
| 40–59 | 0 0 52 35 35 77 95 95 93 93 93 105 61 61 127 78 78 78 88 88 |
| 60–79 | 5 5 5 1 1 1 0 0 0 120 40 40 40 7 7 7 7 0 0 0 |
| 80–99 | 0 0 0 0 0 1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 |
| 100–119 | 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 |
| 120–139 | 0 0 0 0 0 0 0 0 0 4 0 0 0 0 0 0 0 0 4 12 |
| 140–159 | 0 0 0 0 0 2 0 7 0 9 0 7 0 2 0 10 1 1 0 0 |
| 160–179 | 0 0 0 1 0 0 0 1 1 1 0 0 127 0 0 0 0 0 0 0 |
| 180–180 | 0 |

Floats (written with six decimals; shown shortened):

| Floats | Values, in order |
|---|---|
| 0–9 | 0 0 0 0 0 0 0.5 0.5 0 0 |
| 10–19 | 0.5 0.5 0.5 0 0 0 0 0.47 0 0 |
| 20–29 | 0 0 0 0 0 0 0 11 11 22 |
| 30–39 | 55 55 10 10 10 47 35 35 18 17 |
| 40–49 | 17 1 0 0 0.405 0.267121 0 1 0 0 |
| 50–59 | 0 0 0 120 0 0 0 0 0 0.166667 |
| 60–69 | 0 0 0 0 0 0 0 0 0 0 |
| 70–79 | 0 0 0 0 0 0 0 0 0 0 |
| 80–89 | 0 0 0 0 0 0 1 0 0 0 |
| 90–99 | 0.5 0.235294 0.196078 0.745098 0.094488 0.537255 0.490196 0.14902 0.535 1 |
| 100–109 | 0 0 0 0 0 0 0 0 0 0 |
| 110–119 | 0.166667 0 1 1 0 0 0 0 0 0 |
| 120–129 | 0 0 0 0 0.5 0 0 4 0 0 |
| 130–136 | 0 0 0 0 0 0 0 |
