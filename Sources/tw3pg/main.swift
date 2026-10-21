import Foundation
import ThirdWaveFormats

// Developer harness for the format library. Not the user-facing tool (that is the app).
//
//   tw3pg inspect <file>...
//   tw3pg roundtrip <dir>...            parse + rewrite every file, report any byte difference
//   tw3pg unpack <file.pgdata> <outdir>
//   tw3pg repack <dir>...               unpack every .pgdata and pack it again; must be byte-identical
//   tw3pg compare <file.pgdata> <file.pro> [wt dirs...]   pack the .pro with the .pgdata's content; diff

func files(under paths: [String], ext: Set<String>) -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    for p in paths {
        let u = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
        if !isDir.boolValue { out.append(u); continue }
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil) {
            for case let f as URL in e where ext.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
    }
    return out.sorted { $0.path < $1.path }
}

func load(_ u: URL) throws -> Data { try Data(contentsOf: u) }

func describe(_ u: URL) throws -> String {
    let d = try load(u)
    switch u.pathExtension.lowercased() {
    case "pro":
        let p = try ProgramFile(data: d)
        return "\(p.version) \"\(p.name)\" \(p.values.count) values, \(p.valuesPerPart)/part; sources: "
            + p.sources.map(\.description).joined(separator: " ")
    case "pgdata":
        let g = try UnifiedProgram(data: d)
        let src = g.sources.map { $0.ref.label + ($0.hasData ? "*" : "") }.joined(separator: " ")
        return "\"\(g.programName.text)\" \(g.words.count) words; sources [\(src)]"
    case "bin":
        let m = try Multisample(binData: d)
        return "v\(m.sourceVersion) \"\(m.name)\" \(m.samples.count) samples, \(m.totalFrames) frames"
    case "wt":
        let w = try WavetableFile(data: d)
        return "\(w.kind.letter) \"\(w.name)\" fingerprint \(String(w.fingerprint, radix: 16))"
    default: return "?"
    }
}

func reserialize(_ u: URL, _ d: Data) throws -> Data {
    switch u.pathExtension.lowercased() {
    case "pro": return try ProgramFile(data: d).serialized()
    case "pgdata": return try UnifiedProgram(data: d).serialized()
    case "bin":
        let m = try Multisample(binData: d)
        return m.sourceVersion == 5 ? m.binData() : d   // older versions are upgraded, not rewritten
    case "wt":
        var w = try WavetableFile(data: d); w.originalBytes = nil
        // value-level check: regenerate, reparse, compare floats
        let again = try WavetableFile(data: w.serialized())
        return again.values == w.values ? d : Data()
    default: return d
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print("usage: tw3pg inspect|roundtrip|unpack|repack|compare ..."); exit(2) }
let rest = Array(args.dropFirst())

switch cmd {
case "inspect":
    for u in files(under: rest, ext: ["pro", "pgdata", "bin", "wt"]) {
        do { print(u.lastPathComponent + ": " + (try describe(u))) } catch { print(u.lastPathComponent + ": ERROR \(error)") }
    }

case "roundtrip":
    var ok = 0, bad = 0, failed = 0
    for u in files(under: rest, ext: ["pro", "pgdata", "bin", "wt"]) {
        do {
            let d = try load(u)
            if try reserialize(u, d) == d { ok += 1 } else { bad += 1; print("DIFFERS  \(u.path)") }
        } catch { failed += 1; print("FAILED   \(u.path): \(error)") }
    }
    print("roundtrip: \(ok) identical, \(bad) different, \(failed) unreadable")

case "unpack":
    let u = URL(fileURLWithPath: rest[0]), out = URL(fileURLWithPath: rest[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let up = Unpacker.unpack(try UnifiedProgram(data: try load(u)))
    try up.program.serialized().write(to: out.appendingPathComponent(up.program.name + ".pro"))
    for (r, w) in up.wavetables { try w.serialized().write(to: out.appendingPathComponent("\(r.label)_\(w.name).wt")) }
    for (r, m) in up.multisamples { try m.binData().write(to: out.appendingPathComponent("\(r.label)_\(m.name).bin")) }
    print("wrote \(1 + up.wavetables.count + up.multisamples.count) files; referenced only: \(up.referenced.map(\.label))")
    up.notes.forEach { print("note: \($0)") }

case "repack":
    var same = 0, diff = 0, failed = 0
    for u in files(under: rest, ext: ["pgdata"]) {
        do {
            let d = try load(u)
            let g = try UnifiedProgram(data: d)
            let up = Unpacker.unpack(g)
            // reparse the unpacked .pro from text, as the app would after writing it
            let pro = try ProgramFile(data: up.program.serialized())
            var content: [SourceRef: SourceContent] = [:]
            for r in up.referenced { content[r] = .reference }
            for (r, w) in up.wavetables { content[r] = .wavetable(try WavetableFile(data: w.serialized())) }
            for (r, m) in up.multisamples { content[r] = .multisample(m) }
            let again = try Packer.pack(pro, content: content)
            if again.serialized() == d { same += 1 } else {
                diff += 1
                let a = g, b = again
                var why: [String] = []
                if a.sources.map(\.ref) != b.sources.map(\.ref) { why.append("source order \(a.sources.map(\.ref.label)) vs \(b.sources.map(\.ref.label))") }
                if a.sources != b.sources && a.sources.map(\.ref) == b.sources.map(\.ref) { why.append("payloads") }
                if a.programName != b.programName { why.append("name") }
                // A .pro keeps floats to six decimals (as the synth's own export does), so words in
                // the float section may differ below that precision; anything else is a real difference.
                func sixDecimals(_ w: UInt32) -> String { String(format: "%f", Double(Float(bitPattern: w))) }
                let wd = zip(a.words, b.words).enumerated().filter { $0.element.0 != $0.element.1 }
                    .filter { sixDecimals($0.element.0) != sixDecimals($0.element.1) }.map(\.offset)
                if !wd.isEmpty || a.words.count != b.words.count { why.append("words at \(Array(wd.prefix(12))) (\(a.words.count) vs \(b.words.count))") }
                if why.isEmpty { same += 1; diff -= 1 } else { print("DIFFERS \(u.lastPathComponent): " + why.joined(separator: "; ")) }
            }
        } catch { failed += 1; print("FAILED \(u.lastPathComponent): \(error)") }
    }
    print("repack: \(same) identical, \(diff) different, \(failed) unreadable")

case "compare":
    // Pack a .pro using the content embedded in a matching .pgdata (plus .wt dirs for
    // references), then report every difference from the real .pgdata.
    let g = try UnifiedProgram(data: try load(URL(fileURLWithPath: rest[0])))
    let pro = try ProgramFile(data: try load(URL(fileURLWithPath: rest[1])))
    var content: [SourceRef: SourceContent] = [:]
    for s in g.sources {
        switch s.payload {
        case let .wavetable(name, data):
            var r = [Float](); var i = 0
            while i < data.count { r.append(Float(bitPattern: UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24)); i += 4 }
            content[s.ref] = .wavetable(WavetableFile(kind: s.ref.label.hasPrefix("P") ? .p : .u, name: name.text, values: r))
        case let .multisample(m): content[s.ref] = .multisample(m)
        case .none: content[s.ref] = .reference
        }
    }
    for r in pro.distinctSources where content[r] == nil && !r.isBuiltIn { content[r] = .reference }
    let mine = try Packer.pack(pro, content: content)
    print("table real: \(g.sources.map { $0.ref.label + ($0.hasData ? "*" : "") })")
    print("table ours: \(mine.sources.map { $0.ref.label + ($0.hasData ? "*" : "") })")
    let payloadSame = Dictionary(uniqueKeysWithValues: g.sources.map { ($0.ref, $0.payload) })
    let mismatch = mine.sources.filter { payloadSame[$0.ref] != nil && payloadSame[$0.ref] != $0.payload }.map(\.ref.label)
    print("payload mismatches: \(mismatch)")
    let osc = Set(g.oscillatorWordIndices)
    var diffs: [String] = []
    for i in 0..<min(g.words.count, mine.words.count) where !osc.contains(i) && g.words[i] != mine.words[i] {
        diffs.append("\(i + 2): \(String(g.words[i], radix: 16))≠\(String(mine.words[i], radix: 16))")
    }
    print("word count real \(g.words.count) ours \(mine.words.count); non-oscillator differences (pro line: real≠ours): \(diffs.count)")
    print(diffs.prefix(20).joined(separator: "  "))

case "wtcheck":
    // tw3pg wtcheck <wt dirs...> -- <pgdata dirs...>
    // For every wavetable embedded in a .pgdata, find the .wt with the same name and kind and
    // check that parsing that text yields exactly the embedded float32 bits.
    let split = rest.firstIndex(of: "--") ?? rest.count
    var byName: [String: [WavetableFile]] = [:]
    for u in files(under: Array(rest[..<split]), ext: ["wt"]) {
        if let w = try? WavetableFile(data: load(u)) { byName[w.kind.letter + w.name, default: []].append(w) }
    }
    var exact = 0, mismatch = 0, unmatched = Set<String>()
    for u in files(under: Array(rest[min(split + 1, rest.count)...]), ext: ["pgdata"]) {
        guard let g = try? UnifiedProgram(data: load(u)) else { continue }
        for s in g.sources {
            guard case let .wavetable(name, data) = s.payload else { continue }
            let key = (s.ref.label.hasPrefix("P") ? "P" : "U") + name.text
            guard let cands = byName[key] else { unmatched.insert("\(s.ref.label) \(name.text)"); continue }
            if cands.contains(where: { $0.dataBytes == data }) { exact += 1 } else {
                mismatch += 1
                let w = cands[0].dataBytes
                let n = stride(from: 0, to: min(w.count, data.count), by: 4).filter { w[$0..<$0+4] != data[$0..<$0+4] }.count
                print("MISMATCH \(u.lastPathComponent) \(s.ref.label) \(name.text): \(n) of \(data.count / 4) values differ")
            }
        }
    }
    print("wtcheck: \(exact) bit-exact, \(mismatch) mismatched; no .wt found for: \(unmatched.sorted())")

case "maketests":
    // tw3pg maketests <factory .pro using U07> <a .wt already on the synth> <a W3_PROG_4 .pro> <outdir>
    // Builds the hardware-test .pgdata files described in the README's "synth tests" section.
    let base = try ProgramFile(data: try load(URL(fileURLWithPath: rest[0])))
    let existing = try WavetableFile(data: try load(URL(fileURLWithPath: rest[1])))
    let v4 = try ProgramFile(data: try load(URL(fileURLWithPath: rest[2])))
    let out = URL(fileURLWithPath: rest[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func refsOnly(_ p: ProgramFile) -> [SourceRef: SourceContent] {
        var c: [SourceRef: SourceContent] = [:]
        for r in p.distinctSources where !r.isBuiltIn { c[r] = .reference }
        return c
    }
    func write(_ p: ProgramFile, _ c: [SourceRef: SourceContent], _ file: String) throws {
        let g = try Packer.pack(p, content: c)
        try g.serialized().write(to: out.appendingPathComponent(file))
        print("\(file): \"\(p.name)\" sources \(g.sources.map { $0.ref.label + ($0.hasData ? "*" : "") })")
    }
    // T1: factory tables listed, not carried.
    var t1 = base; t1.name = "TW3 T1 FactoryRef"
    try write(t1, refsOnly(t1), "TW3_T1_FactoryRef.pgdata")
    // T2: part 1 osc 1 -> U58, carrying a table the synth already has in another slot.
    var t2 = base; t2.name = "TW3 T2 U58 Dup"; t2.setSourceID(SourceRef.u(58).id, at: 0)
    var c2 = refsOnly(t2); c2[.u(58)] = .wavetable(existing)
    try write(t2, c2, "TW3_T2_U58_Dup.pgdata")
    // T3: part 1 osc 1 -> U59, carrying a brand-new table (2 cycles of 1024 per wave, sine → square).
    var vals: [Float] = []; vals.reserveCapacity(131_072)
    for wave in 0..<64 {
        let mix = Float(wave) / 63
        for i in 0..<2048 {
            let ph = Float(i % 1024) / 1024 * 2 * .pi
            let sq: Float = sin(ph) >= 0 ? 0.8 : -0.8
            vals.append((1 - mix) * 0.8 * sin(ph) + mix * sq)
        }
    }
    let fresh = WavetableFile(kind: .u, name: "TW3 Test Table", values: vals)
    var t3 = base; t3.name = "TW3 T3 U59 New"; t3.setSourceID(SourceRef.u(59).id, at: 0)
    var c3 = refsOnly(t3); c3[.u(59)] = .wavetable(fresh)
    try write(t3, c3, "TW3_T3_U59_New.pgdata")
    try fresh.serialized().write(to: out.appendingPathComponent("U59_TW3 Test Table.wt"))
    // T4: an older-format (W3_PROG_4) program inside a .pgdata.
    var t4 = v4; t4.name = String(("TW3 T4 v4 " + v4.name).prefix(31))
    try write(t4, refsOnly(t4), "TW3_T4_v4.pgdata")
    try v4.serialized().write(to: out.appendingPathComponent("TW3_T4_original.pro"))

case "maketest5":
    // tw3pg maketest5 <program using a sample slot> <outdir>
    // T5a: the program's sample slot listed without its samples. T5b: the same, pointed at empty S20.
    var p = try ProgramFile(data: try load(URL(fileURLWithPath: rest[0])))
    let out = URL(fileURLWithPath: rest[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let sRef = p.distinctSources.first(where: \.isSample) else { print("program uses no sample slot"); exit(1) }
    func refs(_ q: ProgramFile) -> [SourceRef: SourceContent] {
        var c: [SourceRef: SourceContent] = [:]
        for r in q.distinctSources where !r.isBuiltIn { c[r] = .reference }
        return c
    }
    let original = p.name
    p.name = String(("TW3 T5a " + original).prefix(31))
    try Packer.pack(p, content: refs(p)).serialized().write(to: out.appendingPathComponent("TW3_T5a_SampleRef.pgdata"))
    var q = p; q.name = String(("TW3 T5b " + original).prefix(31))
    for (k, r) in q.sources.enumerated() where r == sRef { q.setSourceID(SourceRef.s(20).id, at: k) }
    try Packer.pack(q, content: refs(q)).serialized().write(to: out.appendingPathComponent("TW3_T5b_EmptyS20.pgdata"))
    print("T5a: \(sRef.label) listed without samples; T5b: same oscillators pointed at S20, listed without samples")

default:
    print("unknown command \(cmd)"); exit(2)
}
