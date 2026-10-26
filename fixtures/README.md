# Test files

Small files of each kind the 3rd Wave reads and writes, for anyone writing their own reader or
writer, in any language. Each file has a JSON file next to it (`<file>.json`) saying what it
should parse to, so a new implementation can be checked against it without a 3rd Wave synth at hand.
[`docs/FORMATS.md`](../docs/FORMATS.md) describes the formats; the section numbers below refer
to it.

The files are synthetic: the PgdataFormats and WavetableFormats libraries built them, and they
contain no one else's sounds, so they can be used freely under this project's MIT licence. They
exercise the structure of each format; they are not meant as sounds, and loading them on a 3rd Wave synth
has not been tested.

| File | What it is |
|---|---|
| `program-current.pro` | A program in the current layout (`W3_PROG_5`, 181/137/182, section 3.3) whose oscillators use a source from each id range (section 2): P00, U00, A00 in part 1; P34, U56, S00 in part 2; P02, U01, A01 (the oscillators of the 8M's filler) in parts 3 and 4. Two event records: a note for parts 1 and 2, and an automation record. |
| `program-2022-layout.pro` | A program in the 2022 layout (`W3_PROG_3`, 173/126/73), whose event records name parts by number. |
| `program-2022-layout-converted.pro` | The same program converted to the current layout for a 4-part model (section 6.2): integer 34 becomes 100, global 1 becomes 2, and the note's target becomes the layer's part mask (3). |
| `wavetable-p.wt` | A P table: 60 waves morphing from a sine to a sawtooth, then the PPG's four standard waves (section 5.1). Each point is stored as the sample and the difference to the next. |
| `wavetable-u.wt` | A U table: 64 band-limited sawtooth waves of 1,024 samples, followed by a mipmap chain at 512, 256, 128, 64, and 64 samples per wave (section 5.1), made as the WavetableFormats library writes one. |
| `multisample.bin` | A version 5 multisample of two 64-frame samples with different key ranges, loop modes, and crossfades (section 5.2). |
| `unified.pgdata` | `program-current.pro` packed (section 4): U56 and S00 embedded (they are `wavetable-u.wt` and `multisample.bin`), the factory and analog sources listed without data. Unpacking it gives `program-current.pro` back, byte for byte. |

## The JSON files

They list, for each file, the values a reader most often gets wrong:

- **`.pro`**: the format tag and name, the four sizes in lines 3–6, where the float blocks,
  globals, and event records start (as program value indices, section 3.2), the twelve oscillator
  source ids and the slots they name, the first values of part 1's blocks, and every event record.
- **`.wt`**: the kind, name, and number of values, the first values of waves 0 and 1, the first
  values of the 512-sample mipmap level (U tables), and the largest sample.
- **`.bin`**: the version, the slot name, and every field of every sample, with its first four
  frames of audio.
- **`.pgdata`**: the source table (index, type code, source id, slot, whether data is embedded,
  and the embedded name), the number of program words, the twelve oscillator words (indices into
  the source table), and the source ids they unpack to.

Floats appear as JSON numbers, which convert back to the exact 32-bit values; a `.pro`'s floats
appear as the text in the file (six decimals, section 3.1).

## Keeping them current

`Tests/PgdataFormatsTests/FixtureTests.swift` checks on every test run that each file reads and
writes back byte for byte, parses to what its JSON says, that `unified.pgdata` unpacks to
`program-current.pro`, and that the converter still produces `program-2022-layout-converted.pro`.
After a deliberate change, rebuild the files and their JSON with:

```
PGDATA_TESTS=1 PGDATA_REGENERATE_FIXTURES=1 swift test --filter FixtureTests
```
