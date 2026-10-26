# Getting started

Add the library to a project, then read, pack, unpack, and convert files.

## Add the package

In your `Package.swift`, depend on the repository and the `PgdataFormats` product:

```swift
dependencies: [
    .package(url: "https://github.com/adambier/3rd-wave-tools", from: "1.0.5"),
],
targets: [
    .target(name: "MyTool", dependencies: [
        .product(name: "PgdataFormats", package: "3rd-wave-tools"),
    ]),
]
```

The package also contains the pgdata Packer app and a developer command-line tool, `tw3pg`;
depending on it builds neither.

## Read a program

A ``ProgramFile`` holds a `.pro`'s format tag, name, and values. Each oscillator's source is a
``SourceRef``: a wavetable slot, an analog wave, or a multisample slot.

```swift
import Foundation
import PgdataFormats

let program = try ProgramFile(data: Data(contentsOf: programURL))
for (oscillator, source) in program.sources.enumerated() {
    print("Part \(oscillator / 3 + 1) oscillator \(oscillator % 3 + 1): \(source.label)")
}
```

## Pack a unified program

``Packer`` builds a `.pgdata` from a program and, for each source it uses, the content to carry:
an embedded wavetable or multisample, or ``SourceContent/reference`` to list the slot without
data, for content the receiving 3rd Wave already has (for example, a factory table).

```swift
let table = try WavetableFile(data: Data(contentsOf: wavetableURL))

var content: [SourceRef: SourceContent] = [:]
for source in program.distinctSources where !source.isBuiltIn {
    content[source] = .reference
}
content[.u(56)] = .wavetable(table)

let unified = try Packer.pack(program, content: content)
try unified.serialized().write(to: pgdataURL)
```

A program saved by older firmware is converted to the current layout as it is packed, because
the 3rd Wave's `.pgdata` import does not convert it fully. To recognize Groove Synthesis's
factory tables by their content, use ``FactoryLibrary/builtIn``.

## Unpack a unified program

``Unpacker`` turns a `.pgdata` back into a program and the wavetables and multisamples it
embeds, with the slots they were stored under:

```swift
let unpacked = Unpacker.unpack(try UnifiedProgram(data: Data(contentsOf: pgdataURL)))
try unpacked.program.serialized().write(to: programURL)
for (slot, table) in unpacked.wavetables {
    try table.serialized().write(to: folder.appendingPathComponent("\(slot.label).wt"))
}
for (slot, multisample) in unpacked.multisamples {
    try multisample.binData().write(to: folder.appendingPathComponent("\(slot.label).bin"))
}
```

## Convert an older program

``ProgramConverter`` applies the changes the 3rd Wave's **Import program** makes to a program
saved by older firmware, for a 4-part model by default:

```swift
if ProgramConverter.needsConversion(program) {
    let current = try ProgramConverter.convert(program)
    try current.serialized().write(to: convertedURL)
}
```

Every reader and writer in the library writes an unmodified file back byte for byte, which is
how it is tested against real files.
