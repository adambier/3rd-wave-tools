# ``PgdataFormats``

Read and write the files of the Groove Synthesis 3rd Wave: programs, wavetables, multisamples,
and unified programs.

## Overview

PgdataFormats is the library behind pgdata Packer, offered for anyone building their own tools
for the 3rd Wave: librarians, editors, converters, or scripts. It reads and writes the 3rd Wave's
four file formats byte for byte, and implements the parts of the 3rd Wave's own behaviour that a
tool needs to reproduce:

- programs (`.pro`), in every layout seen in files saved since 2022, with ``ProgramFile``;
- wavetables (`.wt`), P and U tables, with ``WavetableFile``;
- multisamples (`.bin`), in versions 1, 4, and 5, with ``Multisample``;
- unified programs (`.pgdata`), a program together with the wavetables and multisamples it
  uses, with ``UnifiedProgram``, ``Packer``, and ``Unpacker``;
- the conversion the 3rd Wave applies to programs saved by older firmware, with
  ``ProgramConverter``;
- which slot an oscillator plays, with ``SourceRef``, and which wavetables are Groove
  Synthesis's factory tables, with ``FactoryLibrary``.

It depends only on Foundation and builds on macOS and Linux.

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

### Supporting types

- ``NameField``
- ``FormatError``
- ``fnv1a64(_:)``
