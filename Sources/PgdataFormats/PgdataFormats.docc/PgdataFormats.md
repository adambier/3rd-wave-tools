# ``PgdataFormats``

Read and write the files of the Groove Synthesis 3rd Wave: programs, wavetables, multisamples,
and unified programs.

## Overview

PgdataFormats is the library behind pgdata Packer, offered for anyone building their own tools
for the 3rd Wave, such as librarians, converters, or scripts. It reads and writes the 3rd Wave's
four file formats byte for byte, and implements the parts of the 3rd Wave's own behaviour that
such a tool needs to reproduce:

- programs (`.pro`), in every layout seen in files saved since 2022, with ``ProgramFile``;
- wavetables (`.wt`), P and U tables, with ``WavetableFile``;
- multisamples (`.bin`), in versions 1, 4, and 5, with ``Multisample``;
- unified programs (`.pgdata`), a program together with the wavetables and multisamples it
  uses, with ``UnifiedProgram``, ``Packer``, and ``Unpacker``;
- the conversion the 3rd Wave applies to programs saved by older firmware, with
  ``ProgramConverter``;
- which slot an oscillator plays, with ``SourceRef``, and which wavetables are Groove
  Synthesis's factory tables, with ``FactoryLibrary``;
- how the 3rd Wave names the files it exports, with ``ExportNames``, and file names that are safe
  on its USB drive and elsewhere, with ``SafeFileName``.

It depends only on Foundation, and its tests run on macOS, Linux, and Windows.

What it does not do is interpret a program's sound settings: what most of a program's roughly
1,450 values mean is not yet known (fewer than 60 have an identified meaning), so it copies them
through unchanged. It supports tools that move, pack, unpack, convert, and rename programs, not
yet ones that create sounds or edit a program's settings.

The package also offers two more libraries. `WavetableFormats` reads and writes other synths'
wavetable formats and converts tables to and from the 3rd Wave's. `PgdataPackerCore` holds
pgdata Packer's own decisions without its user interface (pack, unpack, and convert plans, file
names, Clean Up Names), for a command-line tool or an app on another platform that should behave
like pgdata Packer; its API may change between versions more than this library's.

The formats themselves, and how each fact about them was established, are described in
[FORMATS.md](https://github.com/adambier/3rd-wave-tools/blob/main/docs/FORMATS.md), which is
written for implementers in any language. The repository's `fixtures` folder holds small test
files of each kind, with what each should parse to.

This project is not affiliated with or endorsed by Groove Synthesis.

## Topics

### Essentials

- <doc:GettingStarted>

### Programs

- ``ProgramFile``
- ``ProgramConverter``
- ``SourceRef``

### Unified programs

- ``UnifiedProgram``
- ``Packer``
- ``Unpacker``
- ``SourceContent``
- ``UnpackedProgram``
- ``PackError``

### Wavetables

- ``WavetableFile``
- ``FactoryLibrary``

### Multisamples

- ``Multisample``

### The 3rd Wave's conventions

- ``ExportNames``
- ``SafeFileName``

### Supporting types

- ``NameField``
- ``FormatError``
- ``fnv1a64(_:)``
