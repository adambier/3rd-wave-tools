# Wavetable formats of other synths

What pgdata Packer's Wavetables page and the `WavetableFormats` library rely on when they read
wavetables made for other synths and write tables for them. The 3rd Wave's own formats (`.wt` P
and U tables, and the tables a `.pgdata` embeds) are in [FORMATS.md](FORMATS.md), section 5.1.

Each statement names its source: the company's manual, or its own source code. Where a
statement is an inference, it says so. Nothing here has been tested with this project's files
unless it says so. The app labels each destination the same way: the book icon beside its row
opens its sources, a green seal in its place marks one that has been tested, and where the
sources leave something open (the questions at the end), the chosen row says so.
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
| `clm ` chunk | ASCII `<!>2048 F0000000 …`: the frame size, then flags; the first flag digit F is the interpolation (below) | Serum, Vital, Surge, this app | Serum (the first 10 bytes); Vital (the flag only); Surge (2,048 only)[^surge-code][^vital] |
| `srge` chunk | int32 version, int32 frame size | Surge | Surge[^surge-code] |
| `uhWT` chunk | a frame size field (2,048 throughout Hive's library; the layout is an inference from those files), which Surge reads as 2,048 | u-he synths | Surge, this app[^surge-code] |
| `_wt<N>` at the end of the file name | the frame size N (64–4,096, a power of two); a trailing `r` means no interpolation | this app (for Tonverk) | Tonverk[^tonverk] |
| a `.txt` file beside the WAV | line 1 `[N]`, the samples per frame; optional line 2 `[interp]` or `[no interp]` | people, by hand | Serum (`<name>.txt`, then `FolderInfo.txt`)[^serum] |
| nothing | the reader's own assumption, usually 2,048 | many | Pigments slices every 2,048 samples[^pigments] |

**Interpolation.** In the `clm ` chunk's first flag digit, `0` means no interpolation (the table
steps from frame to frame), `1` a crossfade, and `2`–`4` Serum's spectral morphs.[^serum-clm] Vital
reads `0` as none, `1` as crossfade, anything else as spectral, and uses spectral when there is no
chunk.[^vital] Most other synths set interpolation on the oscillator, not in the file.

## 2. Destinations the Wavetables page writes

| Destination | What is written | Source |
|---|---|---|
| Serum, Vital, Pigments | Mono 32-bit float WAV, 48 kHz, 2,048 per frame, up to 256 frames, with a `clm ` chunk carrying the interpolation | [^serum] [^vital] [^pigments] |
| MiniFreak V (for the MiniFreak) | The same, with at most 64 frames | [^minifreak] |
| Tonverk | Mono 32-bit float WAV, 48 kHz, at most 64 frames, its frame size and interpolation in the file name (`Name_wt1024.wav`, `Name_wt128r.wav`) | [^tonverk] |
| Phase Plant | Exactly 256 frames of 2,048, with a `clm ` chunk | [^phaseplant] |
| Surge XT | A Surge `.wt` (binary, below) | [^surge-code] |
| WaveEdit, E370 | Mono 16-bit WAV, 44.1 kHz, 64 frames of 256, no extra chunk | [^waveedit] |
| 3rd Wave P table | A `.wt`: 64 frames of 128, each sample stored with the difference to the next. Tested on the 3rd Wave 8M, OS 2.0d | [FORMATS.md](FORMATS.md) 5.1 and 9 |
| 3rd Wave U table | A `.wt`: 64 frames of 1,024, then the mipmap chain. Tested on the 3rd Wave 8M, OS 2.0d | [FORMATS.md](FORMATS.md) 5.1 and 9 |

Notes on each:

- **Serum** loads up to 256 frames of 2,048 samples (2 MB of 32-bit samples). Without a `clm `
  chunk it offers several ways to slice the file; a `.txt` file beside it overrides them.[^serum]
- **Vital** slices `.wav` files at 2,048 per frame and does not read the `clm ` chunk's frame size,
  only its interpolation digit. A file of exactly 16,384 samples whose spectrum looks like a
  WaveEdit table is sliced at 256 instead.[^vital]
- **Pigments** places each 2,048 samples in a position, up to 256 positions, and reads no
  metadata; interpolation is the engine's Morph setting.[^pigments]
- **MiniFreak V** imports tables (including Pigments') and sends them to a MiniFreak over USB; on
  import it truncates them to 24-bit, 512 samples per frame, and 64 frames. How it reduces a
  2,048-sample frame to 512, or more than 64 frames to 64, is not documented, so larger tables
  are cut down to 64 frames here, by the method you choose, before MiniFreak V sees the file.[^minifreak]
- **Tonverk** reads the frame size from a `_wt<N>` tag at the end of the file name (2,048 when
  there is none) and plays without interpolation when the name ends in `r`. It takes up to 64
  frames and picks evenly spaced ones from a larger table.[^tonverk] The manual's only example of
  the `r` has a size tag (`strings_wt128r.wav`); read literally, any name ending in "r" could load
  stepped, so an explicit tag is always written and any tag the name already has is removed.
  (An inference from the manual's wording; untested.)
- **Phase Plant** documents its wavetables as exactly 256 frames of 2,048 samples (524,288 in
  all).[^phaseplant] Whether it accepts shorter files is not documented; 256 frames are always
  written, the table expanded or reduced by the method you choose.
- **Surge XT** reads its own `.wt` and WAV files with the chunks above, with frame sizes from 2 to
  4,096 (powers of two) and up to 512 frames.[^surge-code]
- **WaveEdit** (Synthesis Technology's editor for the E370 and E352) saves a bank of 64 tables of
  256 samples as a 16-bit, 44.1 kHz WAV of 16,384 samples with no extra chunk.[^waveedit]
- **The 3rd Wave** imports `.wt` files with **Bulk wavetable import** and tables embedded in a
  `.pgdata` with **Import unified program data file**. Its **Wave Maker** also imports a Serum
  wavetable WAV into the U set, and takes a WAV of exactly 8,192 samples (64 × 128) as a P
  table.[^3w-manual] The page's 3rd Wave destinations add formats and frame sizes Wave Maker does not
  read, many tables at once, and a step straight to the Pack page. The page does not make
  wavetables from other audio: that is what Wave Maker is for.

### The Surge `.wt` file

Not to be confused with the 3rd Wave's `.wt`, which is text: a Surge `.wt` begins with the bytes
`vawt`, and a 3rd Wave `.wt` with the text `PNAME` or `UNAME`. They are told apart by content,
not by name.[^surge-code]

| Bytes | Field |
|---|---|
| 0–3 | `vawt` |
| 4–7 | samples per frame, uint32 little-endian (a power of two, 2–4,096) |
| 8–9 | frames, uint16 (1–512) |
| 10–11 | flags, uint16: `0x01` a sample, not a wavetable; `0x02` looped; `0x04` 16-bit data; `0x08` 16-bit data at full scale (otherwise peaking at 2¹⁴); `0x10` an XML metadata block follows the data |
| 12 … | the samples, float32 or int16, little-endian |

## 3. How a frame size is decided

When a WAV is read, the first of these that applies decides the frame size, and the page shows
which one it was:

1. a `clm ` chunk;
2. an `srge` chunk;
3. a `uhWT` chunk: the frame size in its third 32-bit field when that is a power of two, as
   Hive's library has it (u-he does not document the chunk; an inference from 76 files), else
   2,048, which is all Surge reads from it;
4. a `_wt<N>` tag at the end of the file name, for the sizes Tonverk lists (the powers of two
   from 64 to 4,096; "KOMPLEXER_WT2" numbers a table and is left alone);
5. a Serum `.txt` file beside it;
6. evenly spaced `cue ` points;
7. a single `smpl` loop starting at sample 0 (the loop over the first frame);
8. the length, for a mono file: multiples of 2,048, up to 256 frames; the size is then the one
   the samples make likely (below), 2,048 per frame when none stands out, and a choice for
   8,192 and 16,384 samples.

Rules 1–5 are written for the purpose and are trusted as long as one whole frame fits; when the
samples run past the last whole frame (as in some editors' files, and in Surge's own library),
the extra samples are left out, with a note.

Cue points and loops (rules 6 and 7) mark ordinary samples too, so they count only for powers
of two up to 4,096 that give at least two frames: a single looped cycle is a sample. When two of
these disagree, both are noted.

When only the length suggests a size, the other sizes the length allows can be chosen instead.
When nothing settles the size, the page estimates the likely size from the samples (below), and
the Input column says "estimated"; when no size stands out, the estimate is 2,048, the
Serum-style size. Two lengths wait for a choice instead when the samples point to no size,
because each is a well-known table at two sizes: a file of 8,192 samples is 64 × 128 for the 3rd
Wave's Wave Maker (a PPG table) but 4 × 2,048 for Serum, Pigments, or Tonverk (whose factory
library has one), and a file of 16,384 is 64 × 256 for WaveEdit but 8 × 2,048 for Serum.

A WAV with none of the metadata above is listed only when it is mono, its length is a multiple
of 2,048 (up to 256 frames), and its name does not end in a note name ("Pad-000-036-c2",
"Saw C3"), which is how the notes of a multisampled instrument are named; anything else is
taken to be ordinary audio. Some audio still fits that rule by chance (a sample library's mono
loops, say), and is listed with "file length only" as the reason.

These rules were checked against about 20,000 files from the libraries of Hive, Surge XT,
Tonverk, and several Serum packs: every table those libraries hold was listed with the size its
maker gives it (or, for two Tonverk files of 8,192 and 16,384 samples, with the choice left
open), and the samples beside them (multisampled notes, single cycles, looped notes, drums) were
not. DUNE 3's `.wt` files, and Harmor's and Komplexer's, are in formats of their own; the app
does not read them.

**Estimating from the samples.** When nothing but the file's length points to a size (rule 8,
or a length rule 8 leaves open), the page rates every size the length allows by how alike
neighboring frames are at that size, takes the best as its estimate (the Input column says
"estimated"), and falls back to 2,048, the Serum-style size, only when no size stands out. The
chooser draws the first frame at each size and marks the rated size "likely" whenever another
is in use.

The rating: at each candidate size n, the page takes the mean difference between every sample
and the one n samples later (frame k against frame k + 1), as a fraction of the file's mean
level, and the same at a lag of n/2. The frames of a wavetable change little from one to the
next, so at the right size the first difference is small (at most 0.5) and much smaller than
the second (at most half of it: the two halves of a cycle differ).

Why the two lags: a size that is too small fails the second test, since a smooth cycle is about
as like itself a fragment later as half a fragment later; a multiple of the right size passes
neither test better than the right size does, and when several sizes pass, the smallest is
taken. The pictures themselves are not decisive: a size twice too large shows the cycle
repeated, and one too small shows part of it, both of them smooth.

A bank of unrelated frames (a WaveEdit bank, say) fits no size; when the sizes fit equally badly
the chooser says so. For the two lengths never settled by convention (8,192 and 16,384
samples), a file whose samples point to no size waits for a choice.

**Single-cycle files are not listed.** A WAV holding one cycle (for example, a single-cycle
library's 600-sample cycles, each looped over the whole file) is a building block for a wavetable
rather than a wavetable, and making tables from such cycles is what the 3rd Wave's Wave Maker
and other synths' editors do. A short file is listed when its metadata says it holds several
frames.

### FLAC files

FLAC files are read with the app's own decoder (RFC 9639 [^flac]: CONSTANT, VERBATIM, FIXED, and
LPC subframes, Rice and Rice2 residuals, wasted bits, the three stereo modes, 4- to 32-bit
samples, fixed or variable block sizes). It checks each frame's checksums and, when the file
carries one, the MD5 signature of its audio, and reports a file that fails any of them as
damaged. Only the first channel is kept, as for a WAV.

A FLAC file has no RIFF chunks, so rules 1–3, 6, and 7 look at its APPLICATION blocks instead:
a block whose id is one of those chunk ids, forwards or byte-reversed, is read as that chunk.
Rules 4, 5, and 8 apply as for a WAV.

The reversed form is what Phase Plant's factory library has. Of its 402 files (all mono, 24-bit,
and 256 × 2,048 samples):

- 29 carry a 48-byte " mlc" block holding `<!>2048 10000000 Kilohearts (www.kilohearts.com)`.
- 8 carry a 60-byte "lpms" block (a `smpl` chunk with no loops).
- Every one carries an 8-byte "MsHk" block: a little-endian 32-bit 1, then a 32-bit float
  between 0.89 and 3.55 (1.0 in 272 files), with no evident relation to the file's peak (all
  peak at exactly full scale) or RMS level. The block states neither a frame size nor a frame
  count, so it is read past; what the float means is not documented.
- The 373 files without a " mlc" block are listed by their length (rule 8).

A Vorbis comment whose value is a Serum tag (`<!>2048 …`) is read as a `clm ` chunk, with a note
saying where it was found (no writer is known to do this; the tag's form is unmistakable).
Other comments that mention frames, cycles, or wavetables are noted, not acted on.

Checked: the 402 files of Phase Plant's library decode sample for sample as ffmpeg decodes them
(as 32-bit floats; all 402 also pass their MD5 signatures), every one is listed as 256 × 2,048,
and every one round-trips through each of the app's writers. The decoder's tests use synthetic
files from ffmpeg and from a small test-only encoder, covering 8-, 12-, 16-, 20-, 24-, and 32-bit
samples, every subframe kind and stereo mode, wasted bits, variable block sizes, escaped
partitions, and missing or wrong MD5 signatures, with ffmpeg's decoding as the reference. A
256 × 2,048 24-bit file decodes in under 20 ms in a release build.

## 4. Changing frame size and frame count

Frames are resized through their spectrum, and the report says when a frame was resized.

- Growing a frame keeps every harmonic, so the original samples are reproduced at their
  positions and the new samples between them are the band-limited waveform's values; growing a
  frame and shrinking it again returns the original samples (the tests check this to within
  0.0001).
- Shrinking a frame removes the harmonics the smaller frame cannot hold (those above its Nyquist
  frequency) and keeps the rest, so a 2,048-sample frame with content above the 512th harmonic
  loses it when it becomes a 1,024-sample frame.
- Growing can raise the peak slightly between the original samples. Such peaks are kept in
  32-bit float files; for the 3rd Wave and 16-bit files the table is attenuated to fit, which
  the report says.

When a destination needs a different number of frames, you choose how:

- **Original Frames Only** makes no new waveforms. Bringing a table down to fewer frames keeps
  evenly spaced originals, the first and last among them (256 → 64 keeps about every 4th);
  bringing it up to more repeats each original in order (16 → 64 repeats each about 4 times).
- **Crossfade New Frames** makes each new frame by crossfading its two neighbors, once, when
  converting. This is separate from the interpolation a file records, which is whether and how
  a synth interpolates between frames as it plays.

The report after converting says what was done to each table.

## Open questions

Results from any of these are welcome:

- Whether Phase Plant loads tables of fewer than 256 frames.
- Whether Tonverk treats a name ending in "r" without a `_wt<N>` tag as stepped.
- How MiniFreak V reduces 2,048-sample frames to 512, and how it treats fewer than 64 frames.
- Whether the app's 3rd Wave U table from a Serum WAV matches what Wave Maker makes from the same
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
[^flac]: RFC 9639, "Free Lossless Audio Codec" (IETF, 2024).
[^surge-code]: Surge XT's source code: `resources/data/wavetables/WT fileformat.txt`,
    `src/common/WAVFileSupport.cpp`, and `src/common/dsp/Wavetable.h`.
    <https://github.com/surge-synthesizer/surge>
[^waveedit]: WaveEdit's source code (`src/WaveEdit.hpp`, `src/bank.cpp`)
    <https://github.com/AndrewBelt/WaveEdit>, and Synthesis Technology's *E370 Quick Start* 1.4
    <https://synthtech.com/docs/E370_Quick_V14.pdf>.
[^3w-manual]: Groove Synthesis, *3rd Wave* manual, version 1.9, Wave Maker chapter.
