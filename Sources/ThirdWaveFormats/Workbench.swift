import Foundation

// Decision logic behind the app, kept free of UI code so it can be unit-tested.
//
//   SlotProfile     what the user's synth holds in each slot (default: factory where factory)
//   FactoryLibrary  the factory .wt files, indexed by slot
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

// MARK: - Synth profile

/// What one slot on the user's synth holds.
public struct SlotEntry: Codable, Equatable {
    public enum State: String, Codable { case factory, file, empty, unknown }
    public var state: State
    /// Display name as the synth shows it (may differ from the file's own name).
    public var name: String
    /// File holding the content, when state == .file.
    public var path: String?
    public var fingerprint: UInt64?

    public init(state: State, name: String = "", path: String? = nil, fingerprint: UInt64? = nil) {
        self.state = state; self.name = name; self.path = path; self.fingerprint = fingerprint
    }
}

public struct SlotProfile: Codable, Equatable {
    /// Keyed by slot label ("U50", "S10"). Missing entries take the default.
    public var entries: [String: SlotEntry] = [:]

    public init() {}

    public static func defaultEntry(_ ref: SourceRef) -> SlotEntry {
        ref.isFactorySlot ? SlotEntry(state: .factory) : SlotEntry(state: .unknown)
    }

    public func entry(_ ref: SourceRef) -> SlotEntry { entries[ref.label] ?? Self.defaultEntry(ref) }

    public mutating func set(_ ref: SourceRef, _ e: SlotEntry?) {
        if let e, e != Self.defaultEntry(ref) { entries[ref.label] = e } else { entries[ref.label] = nil }
    }

    public mutating func assign(_ file: ContentFile, to ref: SourceRef, displayName: String? = nil) {
        set(ref, SlotEntry(state: .file, name: displayName ?? file.name, path: file.url.path, fingerprint: file.fingerprint))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    public static func decoded(_ d: Data) throws -> SlotProfile { try JSONDecoder().decode(SlotProfile.self, from: d) }
}

// MARK: - Factory library

/// The factory wavetables, read from the folders Groove distributes ("00-Additive_Bell_17.wt",
/// "00P.wt", "P34_VS_0-63.wt"). The slot comes from the number at the start of the file name;
/// the kind from the file's own header.
public struct FactoryLibrary {
    public private(set) var tables: [SourceRef: (url: URL, name: String, fingerprint: UInt64)] = [:]
    public private(set) var problems: [String] = []

    public init() {}

    public init(folders: [URL]) {
        let fm = FileManager.default
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                problems.append("Could not read \(folder.path)."); continue
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
                tables[ref] = (url, w.name, w.fingerprint)
            }
        }
    }

    public func wavetable(_ ref: SourceRef) -> WavetableFile? {
        guard let t = tables[ref] else { return nil }
        return try? WavetableFile(data: Data(contentsOf: t.url))
    }

    public func name(_ ref: SourceRef) -> String? { tables[ref]?.name }

    /// Factory slot whose table has this content, if any.
    public func slot(withFingerprint f: UInt64) -> SourceRef? {
        tables.first { $0.value.fingerprint == f }?.key
    }
}

// MARK: - Pack plan

public struct PackPlan {
    /// What the user (or the defaults) chose for one source.
    public enum Choice: Hashable {
        case builtIn                 // analog shape
        case reference               // list the slot only; the synth supplies the content
        case factory                 // embed the factory table
        case file(UUID)              // embed a content file from this session
        case profile                 // embed the file the synth profile says is in that slot
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
        public var choice: Choice?
        public var options: [Choice]
        public var status: Status
        public var embeds: Bool
        /// Approximate bytes this source adds to the .pgdata.
        public var bytes: Int = 3
    }

    public enum Verdict: Equatable {
        case plainProgramEnough      // only factory/built-in content; no .pgdata needed
        case needsUnifiedFile
        case blocked([SourceRef])
    }

    public var rows: [Row]
    public var verdict: Verdict
    /// Approximate size of the .pgdata this plan would produce.
    public var estimatedBytes: Int
    /// Part of that size taken by embedded factory wavetables.
    public var factoryBytes: Int

    static let uTableBytes = 3 + 32 + 131_072 * 4
    static let pTableBytes = 3 + 32 + 16_384 * 4
    static func multisampleBytes(_ m: Multisample) -> Int { 3 + 33 + m.samples.reduce(0) { $0 + 78 + 2 * Int($1.length) } }
    public static func formatBytes(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f MB", Double(n) / 1_000_000) : String(format: "%.0f KB", Double(n) / 1_000)
    }

    /// Builds the plan for a program.
    ///
    /// Default choice per source, in order:
    ///  1. a content file assigned to that slot in this session (the program's author supplied it)
    ///  2. for a factory slot: the factory table — embedded only if `embedFactory` — with a warning
    ///     if the synth profile says that slot now holds something else
    ///  3. for a non-factory slot: the file the synth profile has there
    ///  4. otherwise nothing: the source is reported missing and packing is blocked
    public static func make(program: ProgramFile, files: [ContentFile], profile: SlotProfile,
                            factory: FactoryLibrary, embedFactory: Bool,
                            overrides: [SourceRef: Choice] = [:]) -> PackPlan {
        let srcs = program.sources
        var rows: [Row] = []
        for ref in program.distinctSources {
            let users = srcs.enumerated().filter { $0.element == ref }.map { "Part \($0.offset / 3 + 1) Osc \($0.offset % 3 + 1)" }
            if ref.isBuiltIn {
                rows.append(Row(ref: ref, usedBy: users, choice: .builtIn, options: [.builtIn], status: .ok("Built in"), embeds: false))
                continue
            }
            let entry = profile.entry(ref)
            let assigned = files.filter { $0.slot == ref && $0.fits(ref) }
            var options: [Choice] = assigned.map { .file($0.id) }
            if ref.isWavetable, ref.isFactorySlot {
                options.append(.reference)
                if factory.tables[ref] != nil { options.append(.factory) }
            }
            if entry.state == .file, entry.path != nil { options.append(.profile) }
            if ref.isWavetable, !ref.isFactorySlot, !options.contains(.reference) { options.append(.reference) }
            // Samples can be left out only by explicit choice; it is never the default.
            if ref.isSample { options.append(.reference) }

            var choice: Choice? = overrides[ref].flatMap { options.contains($0) ? $0 : nil }
            if choice == nil {
                if let f = assigned.first { choice = .file(f.id) }
                else if ref.isWavetable && ref.isFactorySlot { choice = embedFactory && factory.tables[ref] != nil ? .factory : .reference }
                else if entry.state == .file, entry.path != nil { choice = .profile }
            }

            let factoryName = factory.name(ref).map { "\"\($0)\"" } ?? "the factory table"
            var status: Status
            var embeds = false
            let tableBytes = ref.isP ? pTableBytes : uTableBytes
            var bytes = 3
            switch choice {
            case .file(let id)?:
                let f = files.first { $0.id == id }!
                status = .ok("Embeds \"\(f.name)\" from \(f.url.lastPathComponent)")
                embeds = true
                if case let .multisample(m) = f.body { bytes = multisampleBytes(m) } else { bytes = tableBytes }
                if entry.state == .file, let fp = entry.fingerprint, fp != f.fingerprint {
                    status = .warning("Embeds \"\(f.name)\"; your synth has \"\(entry.name)\" in \(ref.label) (whether importing overwrites that slot is not yet known)")
                }
            case .factory?:
                status = .ok("Embeds factory \(factoryName) (+\(formatBytes(tableBytes)); already on a factory synth)")
                embeds = true; bytes = tableBytes
            case .profile?:
                status = .ok("Embeds \"\(entry.name)\", as on your synth"); embeds = true
                if ref.isSample {
                    let size = (try? FileManager.default.attributesOfItem(atPath: entry.path ?? "")[.size] as? Int) ?? nil
                    bytes = (size ?? 0) + 3 - 16
                } else { bytes = tableBytes }
            case .reference? where ref.isSample:
                status = .warning("Not included. The program will play whatever multisample is in \(ref.label) when it is loaded: if that slot is empty, or holds a different multisample (even one with the same name), the oscillator will be silent or wrong. How the synth handles this is not yet tested.")
            case .reference?:
                if ref.isFactorySlot {
                    status = .ok("Factory \(factoryName); not embedded")
                    if entry.state == .file {
                        status = .warning("Expects factory \(factoryName), but your synth has \"\(entry.name)\" in \(ref.label)")
                    }
                } else {
                    status = .warning("Not embedded: the synth must already have the right table in \(ref.label)")
                }
            case .builtIn?: status = .ok("Built in")
            case nil:
                status = .missing(ref.isSample
                    ? "Needs the multisample for \(ref.label): add its .bin file and assign it to \(ref.label)"
                    : "Needs a wavetable for \(ref.label) (not a factory slot): add its .wt file and assign it to \(ref.label)")
            }
            rows.append(Row(ref: ref, usedBy: users, choice: choice, options: options, status: status, embeds: embeds, bytes: bytes))
        }
        let missing = rows.filter { $0.choice == nil }.map(\.ref)
        let verdict: Verdict
        if !missing.isEmpty { verdict = .blocked(missing) }
        else if rows.contains(where: { $0.embeds && !($0.choice == .factory) }) { verdict = .needsUnifiedFile }
        else { verdict = .plainProgramEnough }
        let total = 17 + 4 * rows.count + rows.reduce(0) { $0 + $1.bytes } + 32 + 4 * program.values.count
        let factoryTotal = rows.filter { $0.choice == .factory }.reduce(0) { $0 + $1.bytes }
        return PackPlan(rows: rows, verdict: verdict, estimatedBytes: total, factoryBytes: factoryTotal)
    }

    /// Content for the packer, loading profile files from disk as needed.
    public func content(files: [ContentFile], profile: SlotProfile, factory: FactoryLibrary) throws -> [SourceRef: SourceContent] {
        var out: [SourceRef: SourceContent] = [:]
        for r in rows {
            switch r.choice {
            case .file(let id)?: out[r.ref] = files.first { $0.id == id }!.content
            case .factory?:
                guard let w = factory.wavetable(r.ref) else { throw FormatError.invalid("Factory table for \(r.ref.label) could not be read.") }
                out[r.ref] = .wavetable(w)
            case .profile?:
                let path = profile.entry(r.ref).path ?? ""
                out[r.ref] = try ContentFile.load(URL(fileURLWithPath: path)).content
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

    /// Groove's convention: "S000_Amen Cuts.bin"; wavetables "U50_SM OB2.wt".
    public static func multisample(_ ref: SourceRef, _ m: Multisample) -> String {
        if case let .s(n) = ref { return String(format: "S%03d_", n) + sanitize(m.name) + ".bin" }
        return sanitize(m.name) + ".bin"
    }
    public static func wavetable(_ ref: SourceRef, _ w: WavetableFile) -> String { ref.label + "_" + sanitize(w.name) + ".wt" }
    public static func program(_ p: ProgramFile) -> String { sanitize(p.name) + ".pro" }
    public static func unified(_ p: ProgramFile) -> String { sanitize(p.name) + ".pgdata" }
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
