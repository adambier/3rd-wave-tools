import Foundation
import PgdataFormats
import PgdataPackerCore
import WavetableFormats

// Developer harness for the format library. Not the user-facing tool (that is the app).
//
//   tw3pg inspect <file>...
//   tw3pg roundtrip <dir>...            parse + rewrite every file, report any byte difference
//   tw3pg unpack <file.pgdata> <outdir>
//   tw3pg repack <dir>...               unpack every .pgdata and pack it again; must be byte-identical
//   tw3pg compare <file.pgdata> <file.pro> [wt dirs...]   pack the .pro with the .pgdata's content; diff
//   tw3pg factory-catalog <out.swift> <factory dirs...>   write FactoryCatalog.swift from the factory .wt files
//   tw3pg pack <file.pro> <out.pgdata> [.wt/.bin files...]  pack as the app would (defaults, built-in factory list)
//   tw3pg convert <in.pro> <out.pro> [8m|24]         convert an older program to the OS 2.0d layout
//   tw3pg convertcheck <in dir> <3rd Wave export dir> [8m|24]   convert each input (sorted) and compare with
//                                        what the 3rd Wave's bulk import made of it (B05P001… in order)
//   tw3pg wtcheck <wt dirs>... -- <pgdata dirs>...   match .wt files against the tables embedded in .pgdata files
//   tw3pg wtscan [--all] [--check-writers] <files or dirs>...   what the Wavetables page would list for
//                                        each file (TSV); --all also lists files without tables;
//                                        --check-writers writes every table for every preset and
//                                        reads it back
//   tw3pg wtdump <file> <out.f32>        the first table's samples as raw float32 little-endian (to compare a
//                                        decoder with ffmpeg: ffmpeg -i x.flac -f f32le -ac 1 x.raw)
//   tw3pg maketests | maketest5 | maketest6 ...   build the hardware-test files (see each command's usage line)

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
        return "\(p.version) \"\(p.name)\" \(p.values.count) values, \(p.valuesPerPart)/part, \(p.floatBlockCount) floats"
            + (PackPlan.predates2025FactoryTables(p) ? " (pre-2025)" : "") + "; sources: "
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
/// Stops with a usage line when a command has fewer arguments than it needs.
func need(_ n: Int, _ rest: [String], _ usage: String) {
    if rest.count < n { print("usage: tw3pg " + usage); exit(2) }
}
guard let cmd = args.first else {
    print("usage: tw3pg inspect|roundtrip|unpack|repack|compare|factory-catalog|pack|convert|convertcheck|wtcheck|maketests|maketest5|maketest6 ...")
    exit(2)
}
let rest = Array(args.dropFirst())
// For the commands whose arguments are all existing files or folders, a path that does not exist
// is a typo, not an empty result.
if ["inspect", "roundtrip", "repack", "compare", "wtcheck", "convertcheck", "wtscan"].contains(cmd) {
    for a in rest where a != "8m" && a != "24" && a != "--" && !a.hasPrefix("--") && !FileManager.default.fileExists(atPath: a) {
        print("error: no such file or folder: \(a)"); exit(1)
    }
}

do {
switch cmd {
case "convert":
    need(2, rest, "convert <in.pro> <out.pro> [8m|24]")
    let model: ProgramConverter.Model = rest.count > 2 && rest[2] == "24" ? .twentyFour : .eightM
    let p = try ProgramFile(data: load(URL(fileURLWithPath: rest[0])))
    let c = try ProgramConverter.convert(p, for: model)
    try c.serialized().write(to: URL(fileURLWithPath: rest[1]))
    print("\(p.version) \(ProgramConverter.layout(of: p).map(\.description) ?? "?") -> \(c.version) \(ProgramConverter.layout(of: c)!)")

case "convertcheck":
    need(2, rest, "convertcheck <in dir> <export dir> [8m|24]")
    let checkModel: ProgramConverter.Model = rest.count > 2 && rest[2] == "24" ? .twentyFour : .eightM
    let ins = files(under: [rest[0]], ext: ["pro"]), outs = files(under: [rest[1]], ext: ["pro"])
    var same = 0
    for (a, b) in zip(ins, outs) {
        let p = try ProgramFile(data: load(a)), want = try ProgramFile(data: load(b))
        guard p.name.trimmingCharacters(in: .whitespaces) == want.name.trimmingCharacters(in: .whitespaces) else {
            print("\(b.lastPathComponent): name \"\(want.name)\", expected \"\(p.name)\" (skipped)"); continue
        }
        let got = try ProgramConverter.convert(p, for: checkModel)
        if got.serialized() == want.serialized() { same += 1; continue }
        let diffs = zip(got.values, want.values).enumerated().filter { $0.element.0.text != $0.element.1.text }
        print("\(b.lastPathComponent) \"\(p.name)\" \(p.version) \(ProgramConverter.layout(of: p)!): \(diffs.count) values differ"
              + (got.values.count != want.values.count ? ", length \(got.values.count) vs \(want.values.count)" : "")
              + ": " + diffs.prefix(6).map { "line \($0.offset + 3): \($0.element.0.text) vs \($0.element.1.text)" }.joined(separator: ", "))
    }
    print("\(same) of \(min(ins.count, outs.count)) identical")

case "factory-catalog":
    guard rest.count >= 2 else { print("usage: tw3pg factory-catalog <out.swift> <factory dirs...>"); exit(2) }
    let lib = FactoryLibrary(folders: rest.dropFirst().map { URL(fileURLWithPath: $0) })
    lib.problems.forEach { print("warning: \($0)") }
    let u = lib.tables.keys.filter { !$0.isP }.count, p = lib.tables.keys.filter(\.isP).count
    print("\(u) U and \(p) P factory tables")
    guard lib.isComplete else { print("error: expected 56 U and 36 P"); exit(1) }
    let dupes = Dictionary(grouping: lib.tables, by: { $0.value.fingerprint }).filter { $0.value.count > 1 }
    for (_, d) in dupes { print("note: identical content in " + d.map(\.key.label).sorted().joined(separator: ", ")) }
    try lib.catalogSource(note: "56 U (U00–U55) and 36 P (P00–P35) tables.").write(toFile: rest[0], atomically: true, encoding: .utf8)
    print("wrote \(rest[0])")

case "pack":
    guard rest.count >= 2 else { print("usage: tw3pg pack <file.pro> <out.pgdata> [.wt/.bin files...]"); exit(2) }
    let pro = try ProgramFile(data: load(URL(fileURLWithPath: rest[0])))
    let files = try rest.dropFirst(2).map { try ContentFile.load(URL(fileURLWithPath: $0)) }
    let plan = PackPlan.make(program: pro, files: files, factory: .builtIn)
    plan.warnings.forEach { print("warning: \($0)") }
    for (id, why) in PackPlan.unusedFiles(files, plans: [plan], factory: .builtIn) {
        if let f = files.first(where: { $0.id == id }) { print("not used: \(f.url.lastPathComponent) (\(why))") }
    }
    for r in plan.rows { print("  \(r.ref.label): \(r.status)") }
    if let n = plan.userSlotNote { print("\n" + n.title + "\n\n" + n.body + "\n") }
    if let m = plan.missingSummary { print("report line: \(pro.name) (\(m))") }
    if case .blocked(let refs) = plan.verdict { print("error: missing " + refs.map(\.label).joined(separator: ", ")); exit(1) }
    let g = try Packer.pack(pro, content: plan.content(files: files))
    try g.serialized().write(to: URL(fileURLWithPath: rest[1]))
    print("wrote \(rest[1]) (\(pro.version), \(pro.valuesPerPart) values per part)")

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
    need(2, rest, "unpack <file.pgdata> <outdir>")
    let u = URL(fileURLWithPath: rest[0]), out = URL(fileURLWithPath: rest[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let up = Unpacker.unpack(try UnifiedProgram(data: try load(u)))
    try up.program.serialized().write(to: out.appendingPathComponent(OutputNames.program(up.program)))
    for (r, w) in up.wavetables { try w.serialized().write(to: out.appendingPathComponent(OutputNames.wavetable(r, w))) }
    for (r, m) in up.multisamples { try m.binData().write(to: out.appendingPathComponent(OutputNames.multisample(r, m))) }
    print("wrote \(1 + up.wavetables.count + up.multisamples.count) files; referenced only: \(up.referenced.map(\.label))")
    up.notes.forEach { print("note: \($0)") }

case "repack":
    var same = 0, diff = 0, failed = 0, converted = 0
    for u in files(under: rest, ext: ["pgdata"]) {
        do {
            let d = try load(u)
            let g = try UnifiedProgram(data: d)
            let up = Unpacker.unpack(g)
            // An older layout is converted on unpack, so it cannot come back byte for byte.
            if up.notes.contains(where: { $0.contains("older format") }) { converted += 1; continue }
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
                // A .pro keeps floats to six decimals (as the 3rd Wave's own export does), so words in
                // the float section may differ below that precision; anything else is a real difference.
                func sixDecimals(_ w: UInt32) -> String { String(format: "%f", Double(Float(bitPattern: w))) }
                let wd = zip(a.words, b.words).enumerated().filter { $0.element.0 != $0.element.1 }
                    .filter { sixDecimals($0.element.0) != sixDecimals($0.element.1) }.map(\.offset)
                if !wd.isEmpty || a.words.count != b.words.count { why.append("words at \(Array(wd.prefix(12))) (\(a.words.count) vs \(b.words.count))") }
                if why.isEmpty { same += 1; diff -= 1 } else { print("DIFFERS \(u.lastPathComponent): " + why.joined(separator: "; ")) }
            }
        } catch { failed += 1; print("FAILED \(u.lastPathComponent): \(error)") }
    }
    print("repack: \(same) identical, \(diff) different, \(failed) unreadable, \(converted) in an older layout (converted, not compared)")

case "compare":
    need(2, rest, "compare <file.pgdata> <file.pro> [wt dirs...]")
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
    need(4, rest, "maketests <factory .pro using U07> <a .wt already on the 3rd Wave> <a W3_PROG_4 .pro> <outdir>")
    // Builds the hardware-test .pgdata files for tests T1–T4 and T6 (hw-tests/TESTS.md, not in the repository).
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
    // T2: part 1 osc 1 -> U58, carrying a table the 3rd Wave already has in another slot.
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

case "maketest6":
    need(3, rest, "maketest6 <factory .pro> <a small .bin> <outdir>")
    // tw3pg maketest6 <factory .pro using U07> <a small .bin> <outdir>
    // Name-length test: every name is 31 characters (the most a name field holds), in a pattern
    // that shows where a display cuts it off: digits 1–10, lower case 11–20, capitals 21–31.
    let pattern = "1234567890abcdefghijKLMNOPQRSTU"
    var base = try ProgramFile(data: try load(URL(fileURLWithPath: rest[0])))
    let ms = try Multisample(binData: try load(URL(fileURLWithPath: rest[1])))
    let out = URL(fileURLWithPath: rest[2])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    base.name = pattern
    var refs: [SourceRef: SourceContent] = [:]
    for r in base.distinctSources where !r.isBuiltIn { refs[r] = .reference }
    // T6a: program name + a new wavetable in U60 (a blank placeholder on Adam's synth).
    var vals: [Float] = []; vals.reserveCapacity(131_072)
    for wave in 0..<64 {
        let k = Float(1 + wave / 8)            // brighter every 8 waves: easy to hear it is ours
        for i in 0..<2048 { vals.append(0.8 * sin(Float(i % 1024) / 1024 * 2 * .pi * k)) }
    }
    var a = base; a.setSourceID(SourceRef.u(60).id, at: 0)
    var ca = refs; ca.removeValue(forKey: .u(7)); ca[.u(60)] = .wavetable(WavetableFile(kind: .u, name: pattern, values: vals))
    if a.sources.contains(.u(7)) { ca[.u(7)] = .reference }
    let ga = try Packer.pack(a, content: ca)
    try ga.serialized().write(to: out.appendingPathComponent("TW3_T6a_Names31.pgdata"))
    print("T6a: \"\(a.name)\" sources \(ga.sources.map { $0.ref.label + ($0.hasData ? "*" : "") })")
    // T6b: same, plus a small multisample (0.5 s sine) on part 1 osc 2, listed as S20.
    var b = a; b.setSourceID(SourceRef.s(20).id, at: 1)
    var cb = ca; cb[.s(20)] = .multisample(ms)
    if !b.sources.contains(.p(2)) { cb.removeValue(forKey: .p(2)) }
    let gb = try Packer.pack(b, content: cb)
    try gb.serialized().write(to: out.appendingPathComponent("TW3_T6b_Names31_Sample.pgdata"))
    print("T6b: \"\(b.name)\" sources \(gb.sources.map { $0.ref.label + ($0.hasData ? "*" : "") })")

case "maketest5":
    need(2, rest, "maketest5 <.pro using a sample slot> <outdir>")
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

case "wtscan":
    let all = rest.contains("--all"), check = rest.contains("--check-writers")
    let paths = rest.filter { !$0.hasPrefix("--") }
    need(1, paths, "wtscan [--all] [--check-writers] <files or dirs>...")
    let (todo, ignored) = ConvertPlan.filesToRead(in: paths.map { URL(fileURLWithPath: $0) })
    var tables = 0, open = 0, without = 0, failed = 0, writerFailures = 0
    var bases: [String: Int] = [:]
    print(["file", "source", "name", "frames x size", "frame size from", "other sizes", "interpolation", "factory", "notes"].joined(separator: "\t"))
    for u in todo {
        let found: [FoundTable]
        do { found = try WavetableReader.read(url: u) } catch {
            failed += 1; print("\(u.path)\tERROR\t\t\t\t\t\t\t\(error)"); continue
        }
        if found.isEmpty { without += 1; if all { print("\(u.path)\t-") }; continue }
        for t in found {
            tables += 1
            let size = t.frameSize.map { "\(t.samples.count / $0) x \($0)" } ?? "? (\(t.samples.count) samples)"
            if t.frameSize == nil { open += 1 }
            let key = t.frameSize == nil ? "(open)" : t.frameSizeBasis.components(separatedBy: " (").first ?? t.frameSizeBasis
            bases[key, default: 0] += 1
            let factory = t.thirdWaveFingerprint.flatMap { FactoryLibrary.builtIn.slot(withFingerprint: $0)?.label } ?? ""
            let source: String
            switch t.source {
            case .wav: source = "wav"
            case .flac: source = "flac"
            case .surgeWavetable: source = "surge"
            case let .thirdWaveWavetable(isP): source = isP ? "3w-P" : "3w-U"
            case let .unifiedProgram(slot, _): source = "pgdata:" + slot
            }
            print([u.path, source, t.name, size, t.frameSizeBasis, t.candidateFrameSizes.map(String.init).joined(separator: ","),
                   t.interpolation?.rawValue ?? "", factory, t.notes.joined(separator: " | ")].joined(separator: "\t"))
            guard check, let w = t.wavetable() else { continue }
            // Round trip: each preset's file, read back, must show the frame size and frame count
            // the preset promises, and when neither changed, the same samples (within what a
            // 16-bit file or six-decimal text can hold).
            for preset in OutputPreset.allCases {
                func fail(_ why: String) { writerFailures += 1; print("  WRITER \(preset.rawValue): \(why) for \(u.lastPathComponent)") }
                do {
                    let out = try WavetableWriter.write(w, preset: preset)
                    let back = try WavetableReader.read(out.data, fileName: out.fileName)
                    let isPow2 = w.frameSize & (w.frameSize - 1) == 0
                    let wantSize: Int
                    switch preset {
                    case .tonverk: wantSize = (64...4096).contains(w.frameSize) && isPow2 ? w.frameSize : 2048
                    case .surge: wantSize = (2...4096).contains(w.frameSize) && isPow2 ? w.frameSize : 2048
                    default: wantSize = preset.frameSize ?? 2048
                    }
                    let wantCount = preset.requiredFrameCount ?? min(preset.maxFrameCount, w.frameCount)
                    guard back.count == 1 else { fail("read back \(back.count) tables"); continue }
                    let gotSize = back[0].frameSize ?? (preset == .waveEdit ? back[0].candidateFrameSizes.first : nil)
                    guard gotSize == wantSize, let r = back[0].wavetable(frameSize: gotSize) else {
                        fail("read back frame size \(back[0].frameSize.map(String.init) ?? "open (\(back[0].candidateFrameSizes))"), wanted \(wantSize)"); continue
                    }
                    guard r.frameCount == wantCount else { fail("read back \(r.frameCount) frames, wanted \(wantCount)"); continue }
                    if wantSize == w.frameSize, wantCount == w.frameCount, w.peak <= 1 {
                        let tolerance: Float = preset == .waveEdit ? 1.0 / 32_768 : 1e-5
                        var worst: Float = 0
                        for (a, b) in zip(w.frames, r.frames) { for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) } }
                        if worst > tolerance { fail("samples differ by up to \(worst)") }
                    }
                } catch { fail("\(error)") }
            }
        }
    }
    FileHandle.standardError.write(Data(("\(todo.count) files read, \(ignored) other files skipped: \(tables) tables (\(open) with the frame size open), "
        + "\(without) files without tables, \(failed) errors" + (check ? ", \(writerFailures) writer failures" : "") + "\n"
        + bases.sorted { $0.value > $1.value }.map { "  \($0.value)\t\($0.key)" }.joined(separator: "\n") + "\n").utf8))

case "wtdump":
    need(2, rest, "wtdump <file> <out.f32>")
    let found = try WavetableReader.read(url: URL(fileURLWithPath: rest[0]))
    guard let t = found.first else { print("no table in \(rest[0])"); exit(1) }
    var out = Data(capacity: t.samples.count * 4)
    for s in t.samples { withUnsafeBytes(of: s.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
    try out.write(to: URL(fileURLWithPath: rest[1]))
    print("\(t.samples.count) samples")

default:
    print("unknown command \(cmd)"); exit(2)
}
} catch {
    print("error: \((error as? FormatError)?.description ?? (error as? PackError)?.description ?? error.localizedDescription)"); exit(1)
}
