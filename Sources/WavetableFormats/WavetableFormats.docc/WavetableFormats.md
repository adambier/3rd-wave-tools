# ``WavetableFormats``

Find wavetables in the files of the 3rd Wave and other synths, resize them, and write them for
another synth.

## Overview

WavetableFormats is the library behind pgdata Packer's Wavetables page, offered for anyone
building their own wavetable tools. It converts existing wavetables between formats; it does
not make wavetables from other audio.

- ``WavetableReader`` finds the wavetables in a file by its content, not its name: WAV and FLAC
  files with their `clm `, `srge`, `uhWT`, `cue `, and `smpl` chunks (or the matching FLAC
  blocks), a Tonverk-style `_wt<N>` tag in the name, or a Serum `.txt` file beside them; Surge
  `.wt` files; and the 3rd Wave's `.wt` and `.pgdata` files (through PgdataFormats). Each ``FoundTable`` says how its frame size was
  decided, and leaves it open, with the sizes that fit, when nothing in the file settles it.
- ``Resampling`` resizes single cycles by their spectrum, changes a table's frame count by
  picking frames evenly or by crossfading, and builds the mipmap chain a 3rd Wave U table
  carries.
- ``WavetableWriter`` writes a ``Wavetable`` for an ``OutputPreset``: the 3rd Wave's U and P
  tables; Serum-style WAV files for Serum, Vital, Pigments, MiniFreak V, and Phase Plant; WAV
  files for Elektron Tonverk and WaveEdit; and Surge XT's `.wt`. Every change it makes is listed
  in the ``OutputFile/notes``.

Each preset states what its behaviour rests on (``OutputPreset/basis``) and where it has been
tested (``OutputPreset/testedIn``); a preset not yet tested in its destination says so. The
formats themselves, with sources, are described in
[WAVETABLES.md](https://github.com/adambier/3rd-wave-tools/blob/main/docs/WAVETABLES.md), and the
3rd Wave's own in
[FORMATS.md](https://github.com/adambier/3rd-wave-tools/blob/main/docs/FORMATS.md).

It depends only on Foundation and PgdataFormats, and its tests run on macOS, Linux, and Windows.

This project is not affiliated with or endorsed by Groove Synthesis or the makers of the other
synths named here.

## Converting a file

```swift
import Foundation
import WavetableFormats

for found in try WavetableReader.read(url: inputURL) {
    // nil when the file leaves the frame size open; choose from found.candidateFrameSizes.
    guard let table = found.wavetable() else { continue }
    print("\(found.name): \(table.frameCount) × \(table.frameSize), from \(found.frameSizeBasis)")
    let out = try WavetableWriter.write(table, preset: .tonverk,
                                        options: OutputOptions(frameCountPolicy: .interpolate))
    try out.data.write(to: outputFolder.appendingPathComponent(out.fileName))
    out.notes.forEach { print("  " + $0) }
}
```

Add the library to a Swift package with the product `WavetableFormats` of
`https://github.com/adambier/3rd-wave-tools`, version 1.1.0 or later.

## Topics

### Reading

- ``WavetableReader``
- ``FoundTable``
- ``SourceFormat``
- ``FrameSizeEvidence``

### Tables

- ``Wavetable``
- ``Interpolation``

### Resizing

- ``Resampling``
- ``FrameCountPolicy``
- ``PPGStandardWaves``

### Writing

- ``WavetableWriter``
- ``OutputPreset``
- ``OutputOptions``
- ``OutputFile``

### Errors

- ``WavetableError``
