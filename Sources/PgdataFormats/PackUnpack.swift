import Foundation

// MARK: - Packing

/// What to put in the .pgdata for one source.
public enum SourceContent: Equatable {
    /// List the source but carry no data: the 3rd Wave uses whatever is in that slot.
    case reference
    case wavetable(WavetableFile)
    case multisample(Multisample)
}

public enum PackError: Error, CustomStringConvertible {
    case unresolved([SourceRef])
    case wrongKind(SourceRef, String)
    case unknownSource(Int32)

    public var description: String {
        switch self {
        case let .unresolved(r):
            return "No content chosen for " + r.map(\.label).joined(separator: ", ") + "."
        case let .wrongKind(r, why): return "\(r.label): \(why)"
        case let .unknownSource(id): return "The program uses source id \(id), which is not a known slot."
        }
    }
}

public enum Packer {
    /// Builds a .pgdata from a program and the content chosen for each of its sources.
    ///
    /// Sources are listed in order of first use (part 1 osc 1 … part 4 osc 3), every referenced
    /// source included, as Groove Synthesis's sample library does. Analog shapes never carry data.
    /// Multisamples are normally carried. Listing an S slot without its samples is allowed only when
    /// asked for explicitly: no such file has been seen, and the 3rd Wave's handling is untested.
    ///
    /// A program saved in an older layout is converted to the current one first (see
    /// `ProgramConverter`), because the 3rd Wave's .pgdata import does not convert it fully. One in
    /// a layout the converter does not know is packed as it is.
    public static func pack(_ program: ProgramFile, content: [SourceRef: SourceContent]) throws -> UnifiedProgram {
        var program = program
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
                // Listed without its samples. Never seen in Groove Synthesis's files; the 3rd Wave's handling is untested.
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

    /// True when the program cannot be expressed as a plain .pro for a 3rd Wave whose slots
    /// hold factory content in `factoryContent` slots: it uses a sample, or a wavetable slot
    /// for which `isFactoryContent` returns false.
    public static func needsUnifiedFile(_ program: ProgramFile, isFactoryContent: (SourceRef) -> Bool) -> Bool {
        program.distinctSources.contains { ref in
            ref.isSample || (ref.isWavetable && !isFactoryContent(ref))
        }
    }
}

// MARK: - Unpacking

public struct UnpackedProgram {
    public var program: ProgramFile
    /// Embedded content, keyed by the slot the program refers to.
    public var wavetables: [(ref: SourceRef, file: WavetableFile)]
    public var multisamples: [(ref: SourceRef, sample: Multisample)]
    /// Sources listed without data (expected to be present on the 3rd Wave already).
    public var referenced: [SourceRef]
    public var notes: [String]
}

public enum Unpacker {
    /// Float-block length by values-per-part, from 1,800+ program files.
    /// 181 has three layouts that share the "W3_PROG_5" tag: 520 (older; Sam Gutman's, Feb 2025),
    /// 544 (from OS 1.9; Groove Synthesis's 8M factory banks, Aug 2025) and 548 (written by OS 2.0d,
    /// whose exports all have 548; the last 4 were 0 in every file seen).
    static let floatCounts: [Int: [Int]] = [173: [504], 174: [508], 179: [508], 180: [520], 181: [548, 544, 520]]

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
                notes.append("Oscillator \(slot % 3 + 1) of part \(slot / 3 + 1) points at source \(k), which the file does not list. "
                             + "The .pro keeps the value \(k), which the 3rd Wave reads as \(SourceRef(id: Int32(k)).description).")
            }
        }
        var program = ProgramFile(version: "W3_PROG_5", name: u.programName.text, values: values)
        // A .pgdata built from an older program by another tool: write the .pro in the current layout,
        // as Import program would have made it.
        if let format = ProgramConverter.inferredFormat(program), let l = ProgramConverter.layout(of: program),
           let converted = try? ProgramConverter.convert(program, format: format) {
            program = converted
            notes.append("This file holds a program in an older layout (\(l), probably W3_PROG_\(format)). The .pro written here "
                         + "is converted to the current format, as the 3rd Wave's Import program would convert it"
                         + (format == 3 ? "; the 3rd Wave's own .pgdata import leaves such a program silent." : "."))
        }

        var wts: [(SourceRef, WavetableFile)] = []
        var mss: [(SourceRef, Multisample)] = []
        var refs: [SourceRef] = []
        for src in u.sources {
            switch src.payload {
            case let .wavetable(name, data):
                var r = ByteReader(data)
                var vals: [Float] = []; vals.reserveCapacity(data.count / 4)
                while r.remaining >= 4 { vals.append(try! r.f32()) }
                wts.append((src.ref, WavetableFile(kind: src.ref.isP ? .p : .u, name: name.text, values: vals)))
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
        // The words start with S, F (floats per part), G (global values) and E (6-value event
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
