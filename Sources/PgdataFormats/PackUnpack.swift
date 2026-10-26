import Foundation

// MARK: - Packing

/// What to put in the .pgdata for one source.
public enum SourceContent: Equatable, Sendable {
    /// List the source but carry no data: the 3rd Wave uses whatever is in that slot.
    case reference
    /// Embed this wavetable. It must be of the slot's kind: a P table for a P slot, a U table for a
    /// U slot.
    case wavetable(WavetableFile)
    /// Embed this multisample. Only a multisample (S) slot can take one.
    case multisample(Multisample)
}

/// An error building a `.pgdata` with ``Packer/pack(_:content:)``.
public enum PackError: Error, CustomStringConvertible, Sendable {
    /// No content was given for these sources, which the program uses.
    case unresolved([SourceRef])
    /// The content given for this source does not suit its slot; the string says why.
    case wrongKind(SourceRef, String)
    /// The program uses this source id, which names no known slot.
    case unknownSource(Int32)

    /// A sentence describing the error, for display.
    public var description: String {
        switch self {
        case let .unresolved(r):
            return "No content chosen for " + r.map(\.label).joined(separator: ", ") + "."
        case let .wrongKind(r, why): return "\(r.label): \(why)"
        case let .unknownSource(id): return "The program uses source id \(id), which is not a known slot."
        }
    }
}

/// Builds unified programs (`.pgdata`) from programs and the content of the sources they use.
///
/// See section 4 of FORMATS.md for the format, and ``Unpacker`` for the reverse.
public enum Packer {
    /// Builds a .pgdata from a program and the content chosen for each of its sources.
    ///
    /// Sources are listed in order of first use (part 1 osc 1 … part 4 osc 3), every referenced
    /// source included, as Groove Synthesis's sample library does. Analog shapes never carry data.
    /// Multisamples are normally carried. Listing an S slot without its samples is allowed only when
    /// asked for explicitly: no such file from Groove Synthesis has been seen, and the 3rd Wave plays
    /// whatever is in that slot, or silence if it is empty (FORMATS.md section 7).
    ///
    /// Values beyond the program's declared length (left over when the 3rd Wave exported onto a
    /// longer file) are dropped. A program saved in an older layout is converted to the current one
    /// (see ``ProgramConverter``), because the 3rd Wave's .pgdata import does not convert it fully.
    /// One in a layout the converter does not know is packed as it is.
    ///
    /// - Parameters:
    ///   - program: The program to pack.
    ///   - content: The content for each source the program uses, by slot. Analog waves need no
    ///     entry; every other source does.
    /// - Returns: The unified program, ready for ``UnifiedProgram/serialized()``.
    /// - Throws: ``PackError`` when a source has no content or content of the wrong kind, or the
    ///   program uses an unknown source id.
    public static func pack(_ program: ProgramFile, content: [SourceRef: SourceContent]) throws -> UnifiedProgram {
        var program = program.trimmedToHeader()
        if ProgramConverter.needsConversion(program), ProgramConverter.unsupportedReason(program) == nil {
            program = try ProgramConverter.convert(program)
        }
        let refs = program.distinctSources
        if let bad = refs.first(where: { if case .unknown = $0 { return true }; return false }) {
            throw PackError.unknownSource(bad.id)
        }
        var missing: [SourceRef] = []
        var sources: [UnifiedProgram.Source] = []
        for ref in refs {
            if ref.isBuiltIn { sources.append(.init(ref: ref, payload: .none)); continue }
            guard let c = content[ref] else { missing.append(ref); continue }
            switch (ref, c) {
            case (.s, .multisample(let m)):
                sources.append(.init(ref: ref, payload: .multisample(m)))
            case (.s, .reference):
                // Listed without its samples. Never seen in Groove Synthesis's files; the 3rd Wave plays the slot as loaded, or silence.
                sources.append(.init(ref: ref, payload: .none))
            case (.s, _):
                throw PackError.wrongKind(ref, "a sample slot needs a multisample (.bin), not a wavetable.")
            case (_, .reference):
                sources.append(.init(ref: ref, payload: .none))
            case (_, .wavetable(let wt)):
                let want: WavetableFile.Kind = ref.isP ? .p : .u
                guard wt.kind == want else {
                    throw PackError.wrongKind(ref, "\"\(wt.name)\" is a \(wt.kind.letter) table, but this slot needs a \(want.letter) table.")
                }
                sources.append(.init(ref: ref, payload: .wavetable(name: NameField(wt.name), data: wt.dataBytes)))
            case (_, .multisample):
                throw PackError.wrongKind(ref, "a wavetable slot cannot take a multisample.")
            }
        }
        if !missing.isEmpty { throw PackError.unresolved(missing) }

        var words = program.words
        for (slot, i) in program.oscillatorIndices.enumerated() {
            let ref = program.sources[slot]
            words[i] = UInt32(refs.firstIndex(of: ref)!)
        }
        return UnifiedProgram(sources: sources, programName: NameField(program.name), words: words)
    }

    /// Whether the program needs a `.pgdata`, rather than a plain `.pro`, to play as intended.
    ///
    /// True when it uses a multisample slot, or a wavetable slot for which `isFactoryContent`
    /// returns false: content the 3rd Wave does not have while its slots hold only factory
    /// content.
    public static func needsUnifiedFile(_ program: ProgramFile, isFactoryContent: (SourceRef) -> Bool) -> Bool {
        program.distinctSources.contains { ref in
            ref.isSample || (ref.isWavetable && !isFactoryContent(ref))
        }
    }
}

// MARK: - Unpacking

/// The contents of a unified program, as ``Unpacker/unpack(_:)`` returns them: the program and
/// the wavetables and multisamples it embeds.
public struct UnpackedProgram: Sendable {
    /// The program, with source ids in place of source-table indices, tagged `W3_PROG_5`.
    ///
    /// A program in an older layout is converted to the current one when the converter knows its
    /// layout, as the 3rd Wave's **Import program** would convert it; ``notes`` says so.
    public var program: ProgramFile
    /// Embedded content, keyed by the slot the program refers to.
    public var wavetables: [(ref: SourceRef, file: WavetableFile)]
    /// The embedded multisamples, each with the slot the program refers to.
    public var multisamples: [(ref: SourceRef, sample: Multisample)]
    /// Sources listed without data (expected to be present on the 3rd Wave already).
    ///
    /// Analog waves, which never carry data, are not included.
    public var referenced: [SourceRef]
    /// Sentences describing anything unusual found while unpacking, for display: for example, a
    /// conversion, an unfamiliar layout, an oscillator pointing past the source table, or bytes
    /// left over at the end of the file. Empty for an ordinary file.
    public var notes: [String]
}

/// Takes a unified program (`.pgdata`) apart into a program, wavetables, and multisamples.
///
/// See section 4.1 of FORMATS.md, and ``Packer`` for the reverse.
public enum Unpacker {
    /// Float-block length by values-per-part, from 1,800+ program files.
    /// 181 has three layouts that share the "W3_PROG_5" tag: 520 (older third-party programs, Feb 2025),
    /// 544 (from OS 1.9; Groove Synthesis's 8M factory banks, Aug 2025), and 548 (written by OS 2.0d,
    /// whose exports all have 548; the last 4 were 0 in every file seen).
    static let floatCounts: [Int: [Int]] = [173: [504], 174: [508], 179: [508], 180: [520], 181: [548, 544, 520]]

    /// Splits a unified program into its program and the content it embeds.
    ///
    /// Each oscillator's source-table index is replaced with the source id from the table. An
    /// index past the end of the table is kept as it is, and noted. Values after the program's
    /// declared end are ignored. A program in an older layout is converted when its format can be
    /// inferred (see ``ProgramConverter/inferredFormat(_:)``), and written as it is otherwise.
    /// Every such case is described in ``UnpackedProgram/notes``. Unpacking does not fail.
    public static func unpack(_ u: UnifiedProgram) -> UnpackedProgram {
        var notes: [String] = []
        let s = u.valuesPerPart
        let floatStart = 4 * s + 4                    // values index of .pro line 4S+6
        let floatCount = detectFloatCount(u.words, perPart: s, start: floatStart, notes: &notes)

        var values: [ProgramFile.Value] = u.words.enumerated().map { i, w in
            (i >= floatStart && i < floatStart + floatCount) ? .float(Float(bitPattern: w)) : .int(Int32(bitPattern: w))
        }
        for (slot, i) in u.oscillatorWordIndices.enumerated() where values.indices.contains(i) {
            let k = Int(u.words[i])
            if k < u.sources.count {
                values[i] = .int(u.sources[k].ref.id)
            } else {
                // Kept as it is, so nothing is invented; the 3rd Wave will read it as source id k.
                let asID = Int32(bitPattern: u.words[i])
                notes.append("Oscillator \(slot % 3 + 1) of part \(slot / 3 + 1) points at source \(k), which the file does not list. "
                             + "The .pro keeps the value \(asID), which the 3rd Wave reads as \(SourceRef(id: asID).description).")
            }
        }
        if u.trailingBytes > 0 {
            notes.append("The file has \(u.trailingBytes) bytes after the end of the program, probably left over from a longer "
                         + "file it was exported onto; they are ignored.")
        }
        var program = ProgramFile(version: "W3_PROG_5", name: u.programName.text, values: values)
        // A .pgdata built from an older program by another tool: write the .pro in the current layout,
        // as Import program would have made it.
        let olderFormat = "in the same way the 3rd Wave's \u{201C}Import program\u{201D} function handles older programs"
        if let l = ProgramConverter.layout(of: program), l != ProgramConverter.current {
            if let format = ProgramConverter.inferredFormat(program) {
                do {
                    program = try ProgramConverter.convert(program, format: format)
                    notes.append("This file holds a program originally saved in an older format (probably W3_PROG_\(format), layout \(l)). "
                                 + "The .pro will be written in the current format, converted \(olderFormat)"
                                 + (format == 3 ? "; the 3rd Wave's \u{201C}Import unified program data file\u{201D} function leaves such a program silent." : "."))
                } catch {
                    notes.append("This file holds a program in an older layout (\(l)) that could not be converted: \(error) "
                                 + "The .pro is written as it is, so the 3rd Wave may not play it \(olderFormat).")
                }
            } else {
                notes.append("This file holds a program in a layout (\(l)) not seen before. The .pro is written as it is, "
                             + "tagged W3_PROG_5, so the 3rd Wave may not play it \(olderFormat).")
            }
        } else if ProgramConverter.layout(of: program) == nil {
            notes.append("The program's header (\(s) integers and \(floatCount / 4) floats per part) does not match its length "
                         + "(\(u.words.count) values). The .pro is written as it is; the 3rd Wave may not read it.")
        }

        var wts: [(SourceRef, WavetableFile)] = []
        var mss: [(SourceRef, Multisample)] = []
        var refs: [SourceRef] = []
        for src in u.sources {
            switch src.payload {
            case let .wavetable(name, data):
                wts.append((src.ref, WavetableFile(kind: src.ref.isP ? .p : .u, name: name.text, dataBytes: [UInt8](data))))
            case let .multisample(m): mss.append((src.ref, m))
            case .none: if !src.ref.isBuiltIn { refs.append(src.ref) }
            }
        }
        return UnpackedProgram(program: program, wavetables: wts, multisamples: mss, referenced: refs, notes: notes)
    }

    static func detectFloatCount(_ words: [UInt32], perPart s: Int, start: Int, notes: inout [String]) -> Int {
        func looksLikeSmallInt(_ w: UInt32) -> Bool {
            let i = Int32(bitPattern: w); return i != 0 && abs(Int(i)) < (1 << 20)
        }
        // The words start with S, F (floats per part), G (global values), and E (6-value event
        // records), and the program ends exactly where they say [observed on every file checked].
        // When they add up, F gives the float block directly.
        if words.count >= 4 {
            let f = Int(Int32(bitPattern: words[1])), g = Int(Int32(bitPattern: words[2])), e = Int(Int32(bitPattern: words[3]))
            if f > 0, f < 1000, g >= 0, g < 10_000, e >= 0, e < 1_000_000,
               4 + 4 * s + 4 * f + g + 6 * e == words.count {
                return 4 * f
            }
        }
        if let options = floatCounts[s] {
            if options.count == 1 { return options[0] }
            // 181: the 24 words after the first 520 floats are floats in the 544 layout, and the 4
            // after those are floats in the 548 layout; the integer tail starts with small integers.
            func hasInt(_ from: Int, _ to: Int) -> Bool {
                words[min(start + from, words.count)..<min(start + to, words.count)].contains(where: looksLikeSmallInt)
            }
            if hasInt(520, 544) { return 520 }
            return hasInt(544, 548) ? 544 : 548
        }
        // Unknown layout: floats run until the first small non-zero integer, in whole parts.
        var n = 0
        while start + n < words.count, !looksLikeSmallInt(words[start + n]) { n += 1 }
        n -= n % 4
        notes.append("Unfamiliar program layout (\(s) values per part); float section inferred as \(n) values.")
        return n
    }
}
