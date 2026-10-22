import Foundation

// Decision logic behind the app, kept free of UI code so it can be unit-tested.
//
//   FactoryLibrary  names and fingerprints of the factory wavetables, indexed by slot (built in)
//   ContentFile     a .wt or .bin the user added, with the slot it is assigned to
//   PackPlan        for one program: what each source will be, and whether a .pgdata is needed

// MARK: - Content files

public struct ContentFile: Identifiable, Equatable {
    public enum Body: Equatable { case wavetable(WavetableFile), multisample(Multisample) }

    public let id: UUID
    public var url: URL
    public var body: Body
    /// Slot the user assigned it to (pre-filled from the filename when it names one).
    public var slot: SourceRef?

    public init(url: URL, body: Body, slot: SourceRef?) {
        id = UUID(); self.url = url; self.body = body; self.slot = slot
    }

    public static func load(_ url: URL) throws -> ContentFile {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "wt":
            let w = try WavetableFile(data: data)
            var slot = SourceRef.suggested(byFilename: url.lastPathComponent)
            if let s = slot, s.isP != (w.kind == .p) || !s.isWavetable { slot = nil }
            return ContentFile(url: url, body: .wavetable(w), slot: slot)
        case "bin":
            let m = try Multisample(binData: data)
            var slot = SourceRef.suggested(byFilename: url.lastPathComponent)
            if let s = slot, !s.isSample { slot = nil }
            return ContentFile(url: url, body: .multisample(m), slot: slot)
        default:
            throw FormatError.invalid("\(url.lastPathComponent) is not a wavetable (.wt) or multisample (.bin).")
        }
    }

    public var name: String {
        switch body { case let .wavetable(w): return w.name; case let .multisample(m): return m.name }
    }
    public var isSample: Bool { if case .multisample = body { return true }; return false }
    public var isPTable: Bool { if case let .wavetable(w) = body { return w.kind == .p }; return false }
    public var kindLabel: String {
        switch body {
        case let .wavetable(w): return "\(w.kind.letter) wavetable"
        case let .multisample(m): return "Multisample, \(m.samples.count) sample\(m.samples.count == 1 ? "" : "s")"
        }
    }
    public var fingerprint: UInt64 {
        switch body { case let .wavetable(w): return w.fingerprint; case let .multisample(m): return m.fingerprint }
    }
    public func fits(_ ref: SourceRef) -> Bool {
        switch (ref, body) {
        case (.s, .multisample): return true
        case (.p, .wavetable(let w)): return w.kind == .p
        case (.u, .wavetable(let w)): return w.kind == .u
        default: return false
        }
    }
    public var content: SourceContent {
        switch body { case let .wavetable(w): return .wavetable(w); case let .multisample(m): return .multisample(m) }
    }
}

// MARK: - Factory library

/// The factory wavetables, as names and content fingerprints by slot. The app uses the built-in
/// list (`FactoryLibrary.builtIn`, generated from Groove Synthesis's factory .wt files by
/// `tw3pg factory-catalog`); it never embeds factory tables, so it does not need their data.
/// `init(folders:)` reads the .wt files themselves, for that generator and for tests.
public struct FactoryLibrary {
    public struct Table: Equatable {
        public var name: String
        public var fingerprint: UInt64
        public init(name: String, fingerprint: UInt64) { self.name = name; self.fingerprint = fingerprint }
    }
    public private(set) var tables: [SourceRef: Table] = [:]
    public private(set) var problems: [String] = []

    public init() {}

    public init(_ tables: [SourceRef: Table]) { self.tables = tables }

    /// The factory set built into the app (U00–U55, P00–P35; U48–U55 added in 2025).
    public static let builtIn: FactoryLibrary = {
        var t: [SourceRef: Table] = [:]
        for e in FactoryCatalog.entries {
            if let r = SourceRef(label: e.slot), r.isFactorySlot { t[r] = Table(name: e.name, fingerprint: e.fingerprint) }
        }
        return FactoryLibrary(t)
    }()

    /// All 56 factory U tables and 36 factory P tables present.
    public var isComplete: Bool {
        tables.keys.filter { if case .u = $0 { return true }; return false }.count >= 56 && tables.keys.filter(\.isP).count >= 36
    }

    /// Reads the .wt files in each folder and in its immediate subfolders, as Groove Synthesis
    /// distributes them ("00-Additive_Bell_17.wt", "00P.wt", "P34_VS_0-63.wt"). The slot comes from
    /// the number at the start of the file name; the kind from the file's own header.
    public init(folders: [URL]) {
        let fm = FileManager.default
        for folder in folders {
            guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
                problems.append("Could not read \(folder.path)."); continue
            }
            var items = top
            for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                items += (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            }
            for url in items where url.pathExtension.lowercased() == "wt" {
                guard let w = try? WavetableFile(data: Data(contentsOf: url)) else {
                    problems.append("\(url.lastPathComponent) is not a readable wavetable."); continue
                }
                let base = url.deletingPathExtension().lastPathComponent
                var digits = Substring(base.drop { !$0.isNumber })
                if base.first?.isNumber == true { digits = Substring(base) }
                let n = Int(String(digits.prefix { $0.isNumber }))
                guard let n else { problems.append("\(url.lastPathComponent): no slot number in the name."); continue }
                let ref: SourceRef = w.kind == .p ? .p(n) : .u(n)
                guard ref.isFactorySlot else { problems.append("\(url.lastPathComponent): \(ref.label) is not a factory slot."); continue }
                tables[ref] = Table(name: w.name, fingerprint: w.fingerprint)
            }
        }
    }

    public func name(_ ref: SourceRef) -> String? { tables[ref]?.name }

    /// Factory slot whose table has this content, if any.
    public func slot(withFingerprint f: UInt64) -> SourceRef? {
        tables.first { $0.value.fingerprint == f }?.key
    }

    /// Swift source for `FactoryCatalog`, listing these tables in slot order.
    public func catalogSource(note: String) -> String {
        let refs = tables.keys.sorted()
        var s = """
        // Generated by `tw3pg factory-catalog`. Do not edit by hand.
        // \(note)
        //
        // Names and content fingerprints (FNV-1a 64 of the table's values) of the factory wavetables.
        // Only these are stored, not the wavetables themselves.

        enum FactoryCatalog {
            static let entries: [(slot: String, name: String, fingerprint: UInt64)] = [

        """
        for r in refs {
            let t = tables[r]!
            let name = t.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            s += "        (\"\(r.label)\", \"\(name)\", 0x" + String(format: "%016llX", t.fingerprint) + "),\n"
        }
        s += "    ]\n}\n"
        return s
    }
}

// MARK: - Pack plan

public struct PackPlan {
    /// What the user (or the defaults) chose for one source.
    public enum Choice: Hashable {
        case builtIn                 // analog shape
        case reference               // list the slot only; the synth supplies its factory table
        case file(UUID)              // embed a content file from this session
    }

    public enum Status: Equatable {
        case ok(String)
        case warning(String)
        case missing(String)
    }

    public struct Row: Identifiable {
        public var id: SourceRef { ref }
        public var ref: SourceRef
        /// Oscillators using it, e.g. ["Part 1 Osc 1", "Part 2 Osc 1"].
        public var usedBy: [String]
        /// The same oscillators as positions 0...11 (part = pos / 3, osc = pos % 3).
        public var oscillators: [Int] = []
        /// Where those oscillators pointed in the original program, when the user repointed them.
        public var repointedFrom: [SourceRef] = []
        public var choice: Choice?
        public var options: [Choice]
        public var status: Status
        public var embeds: Bool
        /// Approximate bytes this source adds to the .pgdata.
        public var bytes: Int = 3
        /// An embedded wavetable the synth is not known to have. On import the synth reuses a table
        /// whose content it already has (in any slot, whatever its name); anything else goes into a
        /// free slot, and if there is none it offers to overwrite the last ones. [verified, T2/T6]
        public var mayNeedSlot = false
        /// U48–U55 in a program saved before they became factory slots, with no table added: most
        /// likely the author's own wavetable (see `PackPlan.userSlotNote`).
        public var wasUserSlot = false
    }

    /// Why some U48–U55 sources are missing, and what to do about it: title and body.
    public struct Note: Equatable {
        public var title: String
        public var body: String
    }

    public enum Verdict: Equatable {
        case factoryOnly             // only factory/built-in content: the .pgdata embeds nothing
        case embedsContent           // the .pgdata carries at least one wavetable or multisample
        case blocked([SourceRef])
    }

    public var rows: [Row]
    public var verdict: Verdict
    /// Things to check that do not stop the program being written (an unfamiliar layout).
    public var warnings: [String] = []
    /// Set when U48–U55 are missing because the program predates them as factory slots.
    public var userSlotNote: Note? = nil
    /// Approximate size of the .pgdata this plan would produce.
    public var estimatedBytes: Int
    /// What a blocked program needs, for reports: "needs U57" or
    /// "needs U48, U50: probably the author's own wavetables from before 2025".
    public var missingSummary: String? {
        guard case .blocked(let refs) = verdict else { return nil }
        let old = rows.filter(\.wasUserSlot).map(\.ref).sorted()
        let other = refs.filter { !old.contains($0) }
        var parts: [String] = []
        if !other.isEmpty { parts.append(other.map(\.label).joined(separator: ", ")) }
        if !old.isEmpty {
            parts.append(old.map(\.label).joined(separator: ", ")
                         + ": probably the author's own wavetable\(old.count == 1 ? "" : "s") from before 2025")
        }
        return "needs " + parts.joined(separator: "; ")
    }

    /// Embedded wavetables that may need a free U / P slot on import (see Row.mayNeedSlot).
    public var slotsNeeded: (u: Int, p: Int) {
        let r = rows.filter(\.mayNeedSlot)
        return (r.filter { if case .u = $0.ref { return true }; return false }.count, r.filter(\.ref.isP).count)
    }

    static let uTableBytes = 3 + 32 + 131_072 * 4
    static let pTableBytes = 3 + 32 + 16_384 * 4
    static func multisampleBytes(_ m: Multisample) -> Int { 3 + 33 + m.samples.reduce(0) { $0 + 78 + 2 * Int($1.length) } }
    public static func formatBytes(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f MB", Double(n) / 1_000_000) : String(format: "%.0f KB", Double(n) / 1_000)
    }

    /// Builds the plan for a program.
    ///
    /// Default choice per source:
    ///  1. a content file assigned to that slot in this session (the program's author supplied it),
    ///     unless it is identical to the factory table of that slot: then the slot is listed only
    ///  2. for a factory slot: listed without data; the receiving synth plays its own factory table.
    ///     Factory tables are never embedded. Exception: in a program saved before the 2025 factory
    ///     tables (see `predates2025FactoryTables`), U48–U55 were user slots, so they are treated
    ///     like user slots; the factory table stays available as a choice, not as the default.
    ///  3. otherwise (a user slot or a multisample with no file added) nothing: the source is
    ///     reported missing and packing is blocked
    public static func make(program: ProgramFile, files: [ContentFile], factory: FactoryLibrary,
                            overrides: [SourceRef: Choice] = [:], original: ProgramFile? = nil) -> PackPlan {
        let srcs = program.sources
        let originalSrcs = original?.sources ?? srcs
        let predates = predates2025FactoryTables(program)
        // Content a synth is expected to have: the factory tables.
        let onSynth = Set(factory.tables.values.map(\.fingerprint))
        var rows: [Row] = []
        for ref in program.distinctSources {
            let positions = srcs.indices.filter { srcs[$0] == ref }
            let users = positions.map(Oscillator.label)
            var from: [SourceRef] = []
            for p in positions where p < originalSrcs.count && originalSrcs[p] != ref && !from.contains(originalSrcs[p]) { from.append(originalSrcs[p]) }
            if ref.isBuiltIn {
                rows.append(Row(ref: ref, usedBy: users, oscillators: positions, repointedFrom: from,
                                choice: .builtIn, options: [.builtIn], status: .ok("Built in"), embeds: false))
                continue
            }
            if case let .unknown(id) = ref {
                rows.append(Row(ref: ref, usedBy: users, oscillators: positions, repointedFrom: from,
                                choice: nil, options: [],
                                status: .missing("Unknown source number \(id): not a wavetable, analog shape or sample slot. Point these oscillators to another slot."),
                                embeds: false))
                continue
            }
            let factoryTable = factory.tables[ref]
            let assigned = files.filter { $0.slot == ref && $0.fits(ref) }
            // A file identical to this slot's factory table is the factory table: listed, not embedded.
            let distinct = assigned.filter { $0.fingerprint != factoryTable?.fingerprint }
            var options: [Choice] = distinct.map { .file($0.id) }
            let isFactory = ref.isWavetable && ref.isFactorySlot
            // A slot that was a user slot when this program was saved (U48–U55 before 2025): the
            // program meant the author's own table there, unless the added file is the factory table.
            let wasUserSlot = isFactory && predates && is2025FactorySlot(ref) && assigned.count == distinct.count
            if isFactory { options.append(.reference) }
            // Tables in user slots and multisamples are always embedded from an added file: a program
            // is never packed without them.

            var choice: Choice? = overrides[ref].flatMap { options.contains($0) ? $0 : nil }
            if choice == nil {
                if let f = distinct.first { choice = .file(f.id) }
                else if isFactory && !wasUserSlot { choice = .reference }
            }

            let factoryName = factory.name(ref).map { "\"\($0)\"" } ?? "table"
            var status: Status
            var embeds = false
            var mayNeedSlot = false
            let tableBytes = ref.isP ? pTableBytes : uTableBytes
            var bytes = 3
            switch choice {
            case .file(let id)?:
                let f = files.first { $0.id == id }!
                embeds = true
                if case let .multisample(m) = f.body {
                    bytes = multisampleBytes(m)
                    status = .ok("Embeds \"\(f.name)\" from \(f.url.lastPathComponent); goes into a free S slot on import")
                } else {
                    bytes = tableBytes
                    if let same = factory.slot(withFingerprint: f.fingerprint) {
                        status = .ok("Embeds \"\(f.name)\", identical to factory \(same.label); a synth that has it reuses it")
                    } else {
                        mayNeedSlot = !onSynth.contains(f.fingerprint)
                        status = .ok("Embeds \"\(f.name)\" from \(f.url.lastPathComponent); goes into a free \(ref.isP ? "P" : "U") slot on import")
                    }
                }
            case .reference?:
                // Offered only for factory slots: listed without data, the synth plays its own table.
                status = .ok("Factory \(factoryName); not embedded"
                             + (assigned.count > distinct.count ? " (the added file is identical to it)" : ""))
            case .builtIn?: status = .ok("Built in")
            case nil where wasUserSlot:
                status = .missing("Probably the author's own wavetable: \(ref.label) was a user slot when this program was made. See the note above.")
            case nil:
                status = .missing(ref.isSample
                    ? "Needs the multisample for \(ref.label): add its .bin file and assign it to \(ref.label)"
                    : "Needs the wavetable for \(ref.label) (a user slot): add its .wt file, or point these oscillators to another slot")
            }
            rows.append(Row(ref: ref, usedBy: users, oscillators: positions, repointedFrom: from,
                            choice: choice, options: options, status: status, embeds: embeds, bytes: bytes,
                            mayNeedSlot: mayNeedSlot, wasUserSlot: wasUserSlot && choice == nil))
        }
        let missing = rows.filter { $0.choice == nil }.map(\.ref)
        let verdict: Verdict
        if !missing.isEmpty { verdict = .blocked(missing) }
        else if rows.contains(where: \.embeds) { verdict = .embedsContent }
        else { verdict = .factoryOnly }
        let total = 17 + 4 * rows.count + rows.reduce(0) { $0 + $1.bytes } + 32 + 4 * program.values.count
        let userSlots = rows.filter(\.wasUserSlot).map(\.ref)
        return PackPlan(rows: rows, verdict: verdict, warnings: [program.layoutWarning].compactMap { $0 },
                        userSlotNote: userSlots.isEmpty ? nil : userSlotNote(program: program, slots: userSlots, factory: factory),
                        estimatedBytes: total)
    }

    /// U48–U55: user slots until Groove Synthesis added them to the factory set in 2025 (files dated
    /// April 2025, shipped with OS 1.9).
    public static func is2025FactorySlot(_ ref: SourceRef) -> Bool {
        if case let .u(n) = ref { return (48...55).contains(n) }
        return false
    }

    /// Float-block length of programs saved since OS 1.9 (2025).
    public static let currentFloatBlockCount = 544

    /// A program saved before OS 1.9, and so before U48–U55 held factory tables: an older format
    /// (W3_PROG_1 to _4) or fewer than 544 values in its float block.
    /// [inferred from the sets seen: every 544-float set dates from 2025 on (8M factory, Matt Johnson,
    /// Miles Away Vol. 3) and every set with fewer predates it (Dynamica, Frank Pels, Euphonic Wave,
    /// Analog Core, Miles Away Vol. 2, Sam Gutman's v5). The 2025 tables shipped with OS 1.9.]
    public static func predates2025FactoryTables(_ p: ProgramFile) -> Bool {
        (1...4).contains(p.versionNumber) || p.floatBlockCount < currentFloatBlockCount
    }

    /// The explanation shown with a program whose U48–U55 sources are missing because it predates them.
    static func userSlotNote(program: ProgramFile, slots: [SourceRef], factory: FactoryLibrary) -> Note {
        let slots = slots.sorted()
        let one = slots.count == 1
        func and(_ xs: [String]) -> String { xs.count == 1 ? xs[0] : xs.dropLast().joined(separator: ", ") + " and " + xs.last! }
        func fname(_ r: SourceRef) -> String { "\"\(factory.name(r) ?? "factory table")\"" }
        let list = and(slots.map(\.label))
        let first = slots[0]
        let title = one
            ? "\(list) probably held the author's own wavetable, which is not included"
            : "\(list) probably held the author's own wavetables, which are not included"
        let factoryList = and(slots.map { "\($0.label) \(fname($0))" })
        let body = """
        This program was most likely made before 2025. Its layout is older than what the synth has saved since OS 1.9 (\(program.version), with \(program.floatBlockCount) values in its float block rather than \(currentFloatBlockCount)). The file itself carries no date, so this is an inference.

        Until 2025, U48–U55 were user slots, where people loaded their own wavetables. Groove Synthesis then made them factory slots. Loaded as it is, this program would play the factory \(one ? "table" : "tables") \(factoryList) instead of the \(one ? "one" : "ones") the author used.

        To fix it, do one of these:
        • Add the author's wavetable \(one ? "file" : "files") for \(list). Program sets that use these slots usually include them, often named with the slot (for example "\(first.label) Name.wt"). A file whose name starts with the slot is assigned to it automatically; otherwise, choose Point to another slot… in the slot's Content menu and pick the file. \(one ? "The table is" : "The tables are") then included in the .pgdata, and the synth stores \(one ? "it in a free slot" : "them in free slots") when it imports the file.
        • Point the oscillators to a different wavetable you have: Point to another slot… in the slot's Content menu.
        • Use the factory \(one ? "table" : "tables") anyway: \(one ? "in the slot's Content menu, choose Factory \(fname(first))" : "in each slot's Content menu, choose its factory table (Factory \(fname(first)) for \(first.label), and so on)"). Choose this if you know the program was made for \(one ? "it" : "them"), or you accept a different sound.
        """
        return Note(title: title, body: body)
    }

    /// For each content file that no plan uses, why: not used by any program (whether or not it has a
    /// slot), or another file or choice is used for its slot.
    public static func unusedFiles(_ files: [ContentFile], plans: [PackPlan]) -> [UUID: String] {
        var used = Set<UUID>()
        for p in plans { for r in p.rows { if case .file(let id)? = r.choice { used.insert(id) } } }
        var out: [UUID: String] = [:]
        for f in files where !used.contains(f.id) {
            guard let slot = f.slot else { out[f.id] = "Not used by any program here"; continue }
            let slotUsed = plans.contains { $0.rows.contains { $0.ref == slot } }
            out[f.id] = slotUsed ? "Not used: another choice is made for \(slot.label)"
                                 : "Not used by any program here"
        }
        return out
    }

    /// Content for the packer. `names` renames added files (by file id).
    public func content(files: [ContentFile], names: [UUID: String] = [:]) -> [SourceRef: SourceContent] {
        var out: [SourceRef: SourceContent] = [:]
        for r in rows {
            switch r.choice {
            case .file(let id)?:
                let c = files.first { $0.id == id }!.content
                out[r.ref] = names[id].map { c.renamed($0) } ?? c
            case .reference?: out[r.ref] = .reference
            case .builtIn?, nil: break
            }
        }
        return out
    }
}

// MARK: - File names

public enum OutputNames {
    /// Removes characters that are awkward in file names on macOS and on the synth's drive.
    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let t = s.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Groove Synthesis's convention: "S000_Amen Cuts.bin"; wavetables "U50_SM OB2.wt".
    public static func multisample(_ ref: SourceRef, _ m: Multisample) -> String {
        if case let .s(n) = ref { return String(format: "S%03d_", n) + sanitize(m.name) + ".bin" }
        return sanitize(m.name) + ".bin"
    }
    public static func wavetable(_ ref: SourceRef, _ w: WavetableFile) -> String { ref.label + "_" + sanitize(w.name) + ".wt" }
    public static func program(_ p: ProgramFile) -> String { sanitize(p.name) + ".pro" }
    /// "B05P87_Ghibli_Bell.pgdata", as the synth names its own exports: spaces become underscores,
    /// letters, digits, hyphens and underscores are kept, anything else is dropped
    /// ("SM Ripper Bass (MW)" → "SM_Ripper_Bass_MW", "SM Cutting Bs&Ld" → "SM_Cutting_BsLd").
    /// Only the file name changes; the name inside the file keeps its spaces and punctuation.
    /// The synth's bulk import takes files in alphabetical order, so the prefix keeps program order.
    public static func unified(_ p: ProgramFile, prefix: String? = nil) -> String {
        (prefix.map { $0 + "_" } ?? "") + exportName(p.name) + ".pgdata"
    }

    /// The name part of an exported .pgdata file name (see `unified`). Non-ASCII letters are dropped
    /// too: how the synth writes them is not known.
    public static func exportName(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: true).map { w in
            String(w.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        }.filter { !$0.isEmpty }
        return words.isEmpty ? "Untitled" : words.joined(separator: "_")
    }

    private static let locationPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[Bb]0?([1-5])-?[Pp](\d{1,3})(?!\d)"#)

    /// Program location named in a file name ("B05P003.pro", "B5-P003 Name.pro", "B05P18_Name.pgdata").
    public static func programLocation(inFileName name: String) -> (bank: Int, program: Int)? {
        guard let m = locationPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let b = Range(m.range(at: 1), in: name), let p = Range(m.range(at: 2), in: name),
              let bank = Int(name[b]), let prog = Int(name[p]), (1...100).contains(prog) else { return nil }
        return (bank, prog)
    }

    /// File-name prefixes for programs written together, in list order. When every file name carries
    /// a location: Groove Synthesis's "B05P18" form, two-digit program, or three digits for the whole batch if
    /// it includes a program 100 ("B05P100" would sort between P10 and P11). Otherwise "001", "002"…
    /// by position in the list.
    public static func orderPrefixes(fileNames: [String]) -> [String] {
        let locs = fileNames.map { programLocation(inFileName: $0) }
        if !locs.isEmpty, locs.allSatisfy({ $0 != nil }) {
            let wide = locs.contains { $0!.program >= 100 }
            return locs.map { String(format: wide ? "B%02dP%03d" : "B%02dP%02d", $0!.bank, $0!.program) }
        }
        return fileNames.indices.map { String(format: "%03d", $0 + 1) }
    }
}

// MARK: - Unpack plan

public struct UnpackPlan {
    public struct Item: Identifiable {
        public let id = UUID()
        public var ref: SourceRef?          // nil for the program itself
        public var fileName: String
        public var data: Data
        public var description: String
        /// Content identical to the factory table in the same slot (writing it is optional).
        public var isFactoryDuplicate: Bool
        public var write: Bool
    }

    public var programName: String
    public var items: [Item]
    /// Slots the file lists without data: the synth is expected to have them already.
    public var referenced: [SourceRef]
    public var notes: [String]

    public static func make(_ u: UnifiedProgram, factory: FactoryLibrary, skipFactoryDuplicates: Bool) -> UnpackPlan {
        let up = Unpacker.unpack(u)
        var items: [Item] = [Item(ref: nil, fileName: OutputNames.program(up.program), data: up.program.serialized(),
                                  description: "Program (\(up.program.values.count + 2) lines)",
                                  isFactoryDuplicate: false, write: true)]
        for (ref, w) in up.wavetables {
            let dup = factory.tables[ref]?.fingerprint == w.fingerprint
            var desc = "\(ref.label) wavetable \"\(w.name)\""
            if dup { desc += " — identical to the factory table" }
            else if let f = factory.slot(withFingerprint: w.fingerprint) { desc += " — identical to factory \(f.label)" }
            items.append(Item(ref: ref, fileName: OutputNames.wavetable(ref, w), data: w.serialized(), description: desc,
                              isFactoryDuplicate: dup, write: !(dup && skipFactoryDuplicates)))
        }
        for (ref, m) in up.multisamples {
            let secs = m.samples.reduce(0.0) { $0 + Double($1.length) / Double(max($1.sampleRate, 1)) }
            items.append(Item(ref: ref, fileName: OutputNames.multisample(ref, m), data: m.binData(),
                              description: "\(ref.label) multisample \"\(m.name)\", \(m.samples.count) sample\(m.samples.count == 1 ? "" : "s"), "
                                + String(format: "%.1f s", secs),
                              isFactoryDuplicate: false, write: true))
        }
        return UnpackPlan(programName: up.program.name, items: items, referenced: up.referenced, notes: up.notes)
    }
}

// MARK: - Repointing oscillators

public enum Oscillator {
    /// Position 0...11 → "Part 1 Osc 1".
    public static func label(_ pos: Int) -> String { "Part \(pos / 3 + 1) Osc \(pos % 3 + 1)" }
    /// Wavetable slots and analog shapes an oscillator can be pointed at (samples are not offered).
    public static var repointTargets: [SourceRef] {
        (0..<SourceRef.uCount).map { SourceRef.u($0) } + (0..<SourceRef.pCount).map { SourceRef.p($0) }
            + (0..<SourceRef.analogNames.count).map { SourceRef.analog($0) }
    }
}

public extension ProgramFile {
    /// A copy with some oscillators pointed at other sources; keys are positions 0...11.
    func repointed(_ map: [Int: SourceRef]) -> ProgramFile {
        var p = self
        let n = sources.count
        for (pos, ref) in map where pos >= 0 && pos < n { p.setSourceID(ref.id, at: pos) }
        return p
    }
}
