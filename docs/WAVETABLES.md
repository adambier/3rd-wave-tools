# Wavetable formats of other synths

What pgdata Packer's Convert page and the `WavetableFormats` library rely on when they read
wavetables made for other synths and write tables for them. The 3rd Wave's own formats (`.wt` P
and U tables, and the tables a `.pgdata` embeds) are in [FORMATS.md](FORMATS.md), section 5.1.

Each statement names its source: the maker's manual or documentation, or the maker's own source
code. Where a statement is an inference, it says so. Nothing here has been tested with this
project's files unless it says so, and each destination in the app is labelled the same way:
"tested in …" once it has been, "not yet tested in its destination" until then.
Corrections and test results are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md).

This project is not affiliated with Groove Synthesis or with any maker named here; their product
names are used only to say what the files work with.

## 1. The common shape: frames in a WAV

Most synths that import wavetables take a mono WAV holding the frames (single cycles) one after
another, all the same length. The usual length is **2,048 samples** per frame, which is what Serum
uses internally and what most other synths assume when a file says nothing else.[^serum][^vital]
[^pigments] Files carry the frame size, if at all, in one of a few ways:

| Where | What it says | Written by | Read by |
|---|---|---|---|
| `clm ` chunk | ASCII `<!>2048 F0000000 …`: the frame size, then flags; the first flag digit F is the interpolation (below) | Serum, Vital, Surge, Convert | Serum (the first 10 bytes); Vital (the flag only); Surge (2,048 only)[^surge-code][^vital] |
| `srge` chunk | int32 version, int32 frame size | Surge | Surge[^surge-code] |
| `uhWT` chunk | frames of 2,048 | u-he synths | Surge[^surge-code] |
| `_wt<N>` at the end of the file name | the frame size N (64–4,096, a power of two); a trailing `r` means no interpolation | Convert (for Tonverk) | Tonverk[^tonverk] |
| a `.txt` file beside the WAV | line 1 `[N]`, the samples per frame; optional line 2 `[interp]` or `[no interp]` | people, by hand | Serum (`<name>.txt`, then `FolderInfo.txt`)[^serum] |
| nothing | the reader's own assumption, usually 2,048 | many | Pigments slices every 2,048 samples[^pigments] |

**Interpolation.** In the `clm ` chunk's first flag digit, `0` means no interpolation (the table
steps from frame to frame), `1` a crossfade, and `2`–`4` Serum's spectral morphs.[^serum-clm] Vital
reads `0` as none, `1` as crossfade, anything else as spectral, and uses spectral when there is no
chunk.[^vital] Most other synths set interpolation on the oscillator, not in the file.

## 2. Destinations Convert writes

| Destination | What Convert writes | Source |
|---|---|---|
| Serum, Vital, Pigments | Mono 32-bit float WAV, 48 kHz, 2,048 per frame, up to 256 frames, with a `clm ` chunk carrying the interpolation | [^serum] [^vital] [^pigments] |
| MiniFreak V (for the MiniFreak) | The same, with at most 64 frames | [^minifreak] |
| Elektron Tonverk | Mono 32-bit float WAV, 48 kHz, at most 64 frames, its frame size and interpolation in the file name (`Name_wt1024.wav`, `Name_wt128r.wav`) | [^tonverk] |
| Phase Plant | Exactly 256 frames of 2,048, with a `clm ` chunk | [^phaseplant] |
| Surge XT | A Surge `.wt` (binary, below) | [^surge-code] |
| WaveEdit, E370 | Mono 16-bit WAV, 44.1 kHz, 64 frames of 256, no extra chunk | [^waveedit] |
| 3rd Wave U table | A `.wt`: 64 frames of 1,024, then the mipmap chain | [FORMATS.md](FORMATS.md) 5.1 |
| 3rd Wave P table | A `.wt`: 64 frames of 128, each sample stored with the difference to the next | [FORMATS.md](FORMATS.md) 5.1 |

Notes on each:

- **Serum** loads up to 256 frames of 2,048 samples (2 MB of 32-bit samples). Without a `clm `
  chunk it offers several ways to slice the file; a `.txt` file beside it overrides them.[^serum]
- **Vital** slices `.wav` files at 2,048 per frame and does not read the `clm ` chunk's frame size,
  only its interpolation digit. A file of exactly 16,384 samples whose spectrum looks like a
  WaveEdit table is sliced at 256 instead.[^vital]
- **Pigments** places each 2,048 samples in a position, up to 256 positions, and reads no
  metadata; interpolation is the engine's Morph setting.[^pigments]
- **MiniFreak V** imports tables (including Pigments') and sends them to a MiniFreak over USB; on
  import it truncates them to 24-bit, 512 samples per cycle, and 64 cycles. How it reduces a
  2,048-sample frame to 512, or more than 64 frames to 64, is not documented, so Convert reduces
  the frame count itself, by the method you choose, before MiniFreak V sees the file.[^minifreak]
- **Tonverk** reads the frame size from a `_wt<N>` tag at the end of the file name (2,048 when
  there is none) and plays without interpolation when the name ends in `r`. It takes up to 64
  frames and picks evenly spaced ones from a larger table.[^tonverk] The manual's only example of
  the `r` has a size tag (`strings_wt128r.wav`); read literally, any name ending in "r" could load
  stepped, so Convert always writes an explicit tag and removes any tag the name already has.
  (An inference from the manual's wording; untested.)
- **Phase Plant** documents its wavetables as exactly 256 frames of 2,048 samples (524,288 in
  all).[^phaseplant] Whether it accepts shorter files is not documented; Convert writes 256 frames,
  expanding or reducing the table by the method you choose.
- **Surge XT** reads its own `.wt` and WAV files with the chunks above, with frame sizes from 2 to
  4,096 (powers of two) and up to 512 frames.[^surge-code]
- **WaveEdit** (Synthesis Technology's editor for the E370 and E352) saves a bank of 64 tables of
  256 samples as a 16-bit, 44.1 kHz WAV of 16,384 samples with no extra chunk.[^waveedit]
- **The 3rd Wave** imports `.wt` files with **Bulk wavetable import** and tables embedded in a
  `.pgdata` with **Import unified program data file**. Its **Wave Maker** also imports a Serum
  wavetable WAV into the U set, and takes a WAV of exactly 8,192 samples (64 × 128) as a P
  table.[^3w-manual] Convert's 3rd Wave output adds formats and frame sizes Wave Maker does not
  read, many tables at once, and **Send to Pack**. Convert does not make wavetables from other
  audio: that is what Wave Maker is for.

### The Surge `.wt` file

Not to be confused with the 3rd Wave's `.wt`, which is text: a Surge `.wt` begins with the bytes
`vawt`, and a 3rd Wave `.wt` with the text `PNAME` or `UNAME`. Convert tells them apart by
content, not by name.[^surge-code]

| Bytes | Field |
|---|---|
| 0–3 | `vawt` |
| 4–7 | samples per frame, uint32 little-endian (a power of two, 2–4,096) |
| 8–9 | frames, uint16 (1–512) |
| 10–11 | flags, uint16: `0x01` a sample, not a wavetable; `0x02` looped; `0x04` 16-bit data; `0x08` 16-bit data at full scale (otherwise peaking at 2¹⁴); `0x10` an XML metadata block follows the data |
| 12 … | the samples, float32 or int16, little-endian |

## 3. How Convert decides a frame size

When it reads a WAV, Convert takes the first of these that applies, and shows which one it
used:

1. a `clm ` chunk whose size divides the file;
2. an `srge` chunk;
3. a `uhWT` chunk (2,048);
4. a `_wt<N>` tag at the end of the file name;
5. a Serum `.txt` file beside it;
6. evenly spaced `cue ` points;
7. a single `smpl` loop whose length divides the file;
8. the length: 8,192 samples as 64 × 128 (the layout Wave Maker reads as a P table), and other
   multiples of 2,048 except 16,384 as 2,048 per frame, up to 512 frames.

Cue points and loops count only for frame sizes up to 4,096, since ordinary samples have them
too. When two of these disagree, Convert notes both. When only the length suggested a size, the
other sizes the length allows can be chosen instead. When nothing settles the size (for example,
a file of 16,384 samples, which is 64 × 256 for WaveEdit or 8 × 2,048 for Serum), Convert lists
the sizes the length allows and waits for you to choose. A WAV whose length fits no wavetable
layout (or that would make more than 512 frames of 2,048) is not listed.

## 4. Changing frame size and frame count

Frames are resized by zero-padding or truncating their spectrum, which is exact for a single
cycle: going from 1,024 samples to 2,048 and back returns the original samples (to within
0.0001), and shrinking a frame removes the harmonics the smaller frame cannot hold. Upsampling
can raise the peak slightly between the original samples; Convert keeps such peaks in 32-bit
float files and scales the table down for the 3rd Wave and for 16-bit files, saying so.

When a destination needs a different number of frames, you choose how:

- **Pick evenly** keeps the first and last frames and spaces the rest evenly. It adds no new
  waveforms. Bringing a table *up* to more frames this way repeats frames.
- **Interpolate** crossfades between neighbouring frames.

The report after converting says what was done to each table.

## Open questions

Results from any of these are welcome:

- Whether Phase Plant loads tables of fewer than 256 frames.
- Whether Tonverk treats a name ending in "r" without a `_wt<N>` tag as stepped.
- How MiniFreak V reduces 2,048-sample frames to 512, and how it treats fewer than 64 frames.
- Whether Convert's 3rd Wave U table from a Serum WAV matches what Wave Maker makes from the same
  file.

[^serum]: *Serum 2 User Guide*, pp. 38, 285, and 291–295. <https://xferrecords.com/manual/serum-2>
[^serum-clm]: A post by Xfer Records' developer on the `clm ` chunk, KVR forum, December 2018
    (<https://www.kvraudio.com/forum/viewtopic.php?p=7264746>). The positions of the two flag
    digits are confirmed by Vital's and Surge's source code.
[^vital]: Vital's source code: `wavetable_edit_section.cpp`, `wavetable_creator.cpp`, and
    `file_source.cpp`. <https://github.com/mtytel/vital> (the public repository; the current
    commercial build may differ).
[^pigments]: *Pigments User Manual* 7.0, section 8.12, "Wavetable Requirements".
    <https://www.arturia.com/api/download/products/pigments/manual/pigments_Manual_7_0_1_EN.pdf>
[^minifreak]: *MiniFreak V User Manual* 5.1.0, "Wavetable" section, pp. 30–31.
    <https://www.arturia.com/api/download/products/minifreak-v/manual/minifreak-v_Manual_5_1_0_EN.pdf>
[^tonverk]: *Tonverk User Manual*, OS 1.4.1, section 5.2.5, "Wavetables".
    <https://www.elektron.se/wp-content/uploads/2026/09/Tonverk-User-Manual_ENG_OS1.4.1_260923.pdf>
[^phaseplant]: Kilohearts, Phase Plant manual and "Wavetables".
    <https://kilohearts.com/docs/wavetables>
[^surge-code]: Surge XT's source code: `resources/data/wavetables/WT fileformat.txt`,
    `src/common/WAVFileSupport.cpp`, and `src/common/dsp/Wavetable.h`.
    <https://github.com/surge-synthesizer/surge>
[^waveedit]: WaveEdit's source code (`src/WaveEdit.hpp`, `src/bank.cpp`)
    <https://github.com/AndrewBelt/WaveEdit>, and Synthesis Technology's *E370 Quick Start* 1.4
    <https://synthtech.com/docs/E370_Quick_V14.pdf>.
[^3w-manual]: Groove Synthesis, *3rd Wave* manual, version 1.9, Wave Maker chapter.
