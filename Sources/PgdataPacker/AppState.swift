import AppKit
import Combine
import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the single-module swiftc build
#endif

/// All app state. Plain ObservableObject, used only from the main thread (as in ThirdWaveWT).
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case pack = "Pack", unpack = "Unpack"
        var id: String { rawValue }
        var icon: String {
            switch self { case .pack: return "shippingbox"; case .unpack: return "tray.and.arrow.up" }
        }
    }

    struct PackItem: Identifiable {
        let id = UUID()
        var url: URL
        var program: ProgramFile
        var overrides: [SourceRef: PackPlan.Choice] = [:]
        /// Oscillators the user pointed at another slot: position 0...11 → new source.
        var repoints: [Int: SourceRef] = [:]
        /// New program name from Clean Up Names (nil: the .pro's own name).
        var newName: String?
        /// The program as it will be packed (the original .pro is never changed).
        var effectiveProgram: ProgramFile {
            var p = repoints.isEmpty ? program : program.repointed(repoints)
            p.name = name
            return p
        }
        /// Name used for packing; an empty edit falls back to the .pro's own name.
        var name: String {
            if let n = newName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
            return program.name
        }
    }

    /// Opens the "Point to another slot" sheet: from a source row (itemID + from), or from a
    /// content file ("Use in a program…", fileID; the program is then chosen in the sheet).
    struct RepointRequest: Identifiable {
        let id = UUID()
        var itemID: UUID?
        var from: SourceRef?
        var fileID: UUID?
    }

    struct UnpackItem: Identifiable {
        let id = UUID()
        var url: URL
        var unified: UnifiedProgram
        var plan: UnpackPlan
    }

    @Published var section: Section? = .pack

    // Shared settings
    /// Names and fingerprints of the factory wavetables, built into the app.
    let factory = FactoryLibrary.builtIn
    @Published var skipFactoryDuplicates = true { didSet { saveSettings(); rebuildUnpackPlans() } }

    // Pack
    @Published var programs: [PackItem] = []
    @Published var contentFiles: [ContentFile] = []
    @Published var selectedProgram: UUID?
    @Published var repointRequest: RepointRequest?
    /// New names for added wavetables and multisamples (by file id), from Clean Up Names.
    @Published var contentNames: [UUID: String] = [:]
    @Published var showNameCleanup = false
    @Published var nameCleaner = NameCleaner() { didSet { saveSettings() } }

    // Unpack
    @Published var unpacks: [UnpackItem] = []
    @Published var selectedUnpack: UUID?

    // Messages
    @Published var log: [String] = []
    @Published var alertMessage: String?

    private let defaults = UserDefaults.standard
    private var loading = true

    init() {
        if defaults.object(forKey: "cleanStripSlots") != nil {
            var c = NameCleaner()
            c.stripSlots = defaults.bool(forKey: "cleanStripSlots")
            c.underscoresToSpaces = defaults.bool(forKey: "cleanUnderscores")
            c.titleCase = defaults.bool(forKey: "cleanTitleCase")
            if let k = defaults.stringArray(forKey: "cleanFixedSpellings") { c.fixedSpellings = k }
            nameCleaner = c
        }
        if defaults.object(forKey: "skipFactoryDuplicates") != nil {
            skipFactoryDuplicates = defaults.bool(forKey: "skipFactoryDuplicates")
        }
        // Settings from versions that asked for the factory .wt files and tracked the synth's slots.
        for key in ["factoryFolders", "embedFactory", "synthHasAllFactory"] { defaults.removeObject(forKey: key) }
        loading = false
    }

    // MARK: Persistence

    private func saveSettings() {
        guard !loading else { return }
        defaults.set(skipFactoryDuplicates, forKey: "skipFactoryDuplicates")
        defaults.set(nameCleaner.stripSlots, forKey: "cleanStripSlots")
        defaults.set(nameCleaner.underscoresToSpaces, forKey: "cleanUnderscores")
        defaults.set(nameCleaner.titleCase, forKey: "cleanTitleCase")
        defaults.set(nameCleaner.fixedSpellings, forKey: "cleanFixedSpellings")
    }

    // MARK: Messages

    func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
    }

    // MARK: Adding files

    /// Accepts any mix of .pro, .wt, .bin and .pgdata files (folders are searched).
    func add(urls: [URL]) {
        var all: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
               let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let f as URL in e { all.append(f) }
            } else { all.append(u) }
        }
        var problems: [String] = []
        var addedPrograms = 0, addedContent = 0, addedUnified = 0
        for u in all.sorted(by: { $0.path < $1.path }) {
            let ext = u.pathExtension.lowercased()
            do {
                switch ext {
                case "pro":
                    if programs.contains(where: { $0.url == u }) { continue }
                    let p = try ProgramFile(data: Data(contentsOf: u))
                    programs.append(PackItem(url: u, program: p)); addedPrograms += 1
                case "wt", "bin":
                    if contentFiles.contains(where: { $0.url == u }) { continue }
                    contentFiles.append(try ContentFile.load(u)); addedContent += 1
                case "pgdata":
                    if unpacks.contains(where: { $0.url == u }) { continue }
                    let g = try UnifiedProgram(data: Data(contentsOf: u))
                    unpacks.append(UnpackItem(url: u, unified: g,
                                              plan: UnpackPlan.make(g, factory: factory, skipFactoryDuplicates: skipFactoryDuplicates)))
                    addedUnified += 1
                default: continue
                }
            } catch {
                problems.append("\(u.lastPathComponent): \(error)")
            }
        }
        if selectedProgram == nil { selectedProgram = programs.first?.id }
        if selectedUnpack == nil { selectedUnpack = unpacks.first?.id }
        var parts: [String] = []
        if addedPrograms > 0 { parts.append("\(addedPrograms) program\(addedPrograms == 1 ? "" : "s")") }
        if addedContent > 0 { parts.append("\(addedContent) wavetable/sample file\(addedContent == 1 ? "" : "s")") }
        if addedUnified > 0 { parts.append("\(addedUnified) .pgdata file\(addedUnified == 1 ? "" : "s")") }
        if !parts.isEmpty { note("Added " + parts.joined(separator: ", ") + ".") }
        if addedUnified > 0 && addedPrograms == 0 && addedContent == 0 { section = .unpack }
        if !problems.isEmpty {
            problems.forEach { note("Could not read \($0)") }
            alertMessage = "Some files could not be read:\n\n" + problems.prefix(8).joined(separator: "\n")
                + (problems.count > 8 ? "\n…and \(problems.count - 8) more (see the log)." : "")
        }
    }

    // MARK: Pack

    func plan(for item: PackItem) -> PackPlan {
        PackPlan.make(program: item.effectiveProgram, files: contentFiles, factory: factory,
                      overrides: item.overrides, original: item.program)
    }

    /// The name an added file will be packed under.
    func displayName(_ f: ContentFile) -> String { contentNames[f.id] ?? f.name }

    /// Added files that are copies of a factory wavetable: never offered for renaming.
    func isFactoryCopy(_ f: ContentFile) -> Bool {
        guard case let .wavetable(w) = f.body else { return false }
        return factory.slot(withFingerprint: w.fingerprint) != nil
    }

    func setProgramName(_ itemID: UUID, _ name: String?) {
        guard let i = programs.firstIndex(where: { $0.id == itemID }) else { return }
        programs[i].newName = (name == programs[i].program.name) ? nil : name
    }

    /// Why each added file is not used by any loaded program (absent when it is used).
    var unusedContent: [UUID: String] {
        PackPlan.unusedFiles(contentFiles, plans: programs.map { plan(for: $0) })
    }

    /// Points the given oscillators of a program at `ref`. Pointing one back at its original source
    /// removes the change.
    func repoint(_ itemID: UUID, positions: [Int], to ref: SourceRef) {
        guard let i = programs.firstIndex(where: { $0.id == itemID }) else { return }
        let original = programs[i].program.sources
        for p in positions where p < original.count {
            programs[i].repoints[p] = original[p] == ref ? nil : ref
        }
        let labels = positions.sorted().map(Oscillator.label).joined(separator: ", ")
        note("\(programs[i].name): \(labels) now use \(ref.description).")
    }

    /// Undoes every repoint that leads to `ref` in a program.
    func undoRepoints(_ itemID: UUID, to ref: SourceRef) {
        guard let i = programs.firstIndex(where: { $0.id == itemID }) else { return }
        programs[i].repoints = programs[i].repoints.filter { $0.value != ref }
    }

    /// A slot to offer for an unassigned wavetable file: the first user slot of the right kind
    /// (U56–U63, P36–P47) that no other added file is assigned to. The user can change it.
    func suggestedSlot(for file: ContentFile, alsoTaken: Set<SourceRef> = []) -> SourceRef? {
        guard !file.isSample else { return nil }
        let taken = Set(contentFiles.compactMap { $0.id == file.id ? nil : $0.slot }).union(alsoTaken)
        let candidates: [SourceRef] = file.isPTable ? (36..<SourceRef.pCount).map { .p($0) } : (56..<SourceRef.uCount).map { .u($0) }
        return candidates.first { !taken.contains($0) } ?? candidates.first
    }

    /// Suggestions for every unassigned wavetable file, in list order, each one different
    /// (01.wt → U56, 02.wt → U57).
    func suggestedSlots() -> [UUID: SourceRef] {
        var out: [UUID: SourceRef] = [:]
        var used = Set<SourceRef>()
        for f in contentFiles where !f.isSample && f.slot == nil {
            if let s = suggestedSlot(for: f, alsoTaken: used) { out[f.id] = s; used.insert(s) }
        }
        return out
    }

    /// What a wavetable slot holds on the user's synth, for display.
    func slotName(_ ref: SourceRef) -> String {
        if ref.isBuiltIn { return ref.description }
        if ref.isSample { return "Multisample" }
        if case .unknown = ref { return "unknown source" }
        if !ref.isFactorySlot {
            // User slots are not tracked: name the added file assigned to it, if any.
            return contentFiles.first { $0.slot == ref }.map { displayName($0) } ?? "no file added"
        }
        return factory.name(ref) ?? "Factory table"
    }

    func setOverride(_ itemID: UUID, _ ref: SourceRef, _ choice: PackPlan.Choice?) {
        guard let i = programs.firstIndex(where: { $0.id == itemID }) else { return }
        programs[i].overrides[ref] = choice
    }

    func setSlot(_ fileID: UUID, _ slot: SourceRef?) {
        guard let i = contentFiles.firstIndex(where: { $0.id == fileID }) else { return }
        contentFiles[i].slot = slot
    }

    func removePrograms(_ ids: Set<UUID>) { programs.removeAll { ids.contains($0.id) }; if let s = selectedProgram, ids.contains(s) { selectedProgram = programs.first?.id } }
    func removeContent(_ id: UUID) { contentFiles.removeAll { $0.id == id } }

    func describe(_ choice: PackPlan.Choice, for ref: SourceRef) -> String {
        switch choice {
        case .builtIn: return ref.description
        case .reference:
            return "Factory " + (factory.name(ref).map { "\"\($0)\"" } ?? "table") + " — not embedded"
        case .file(let id):
            let f = contentFiles.first { $0.id == id }
            return "\"\(f?.name ?? "?")\" (\(f?.url.lastPathComponent ?? "?"))"
        }
    }

    /// Writes .pgdata files for the given programs into a folder chosen by the user.
    func writeUnified(_ ids: [UUID]) {
        let items = programs.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        // Programs missing content cannot be packed: ask before writing the rest.
        let missing: [String] = items.compactMap { item in
            guard let needs = plan(for: item).missingSummary else { return nil }
            return "\(item.name) (\(needs))"
        }
        let oldTables = items.contains { plan(for: $0).userSlotNote != nil }
        if !missing.isEmpty {
            let ok = items.count - missing.count
            if ok == 0 {
                alertMessage = (items.count == 1 ? "This program is missing content, so it can't be written."
                                                 : "None of these programs can be written: all are missing content.")
                    + "\n\n" + missing.joined(separator: "\n")
                    + "\n\nAdd the .wt or .bin files they need and assign them to the slots shown."
                    + (oldTables ? " For the author's own wavetables from before 2025, the note shown with each program explains the choices." : "")
                return
            }
            let n = missing.count
            guard Panels.confirm(
                title: "\(n) of \(items.count) programs \(n == 1 ? "is" : "are") missing content",
                message: "\(n == 1 ? "It" : "They") will not be written. Write the other \(ok)?",
                details: missing.joined(separator: "\n"),
                ok: "Write \(ok)") else { return }
        }
        guard let folder = Panels.chooseFolder(prompt: "Write Here", message: "Choose where to write the .pgdata files") else { return }
        var outputs: [(name: String, data: Data)] = []
        var blocked: [String] = [], failed: [String] = [], unfamiliar: [String] = []
        // Prefix each file with its program location (or list position) so the synth's alphabetical
        // bulk import keeps the programs in order. Positions count over the whole list.
        let prefixes = OutputNames.orderPrefixes(fileNames: programs.map { $0.url.lastPathComponent })
        let prefixByID = Dictionary(uniqueKeysWithValues: zip(programs.map(\.id), prefixes))
        for item in items {
            let plan = plan(for: item)
            switch plan.verdict {
            case .blocked:
                blocked.append("\(item.name) (\(plan.missingSummary ?? "content missing"))"); continue
            default: break
            }
            do {
                let content = plan.content(files: contentFiles, names: contentNames)
                let g = try Packer.pack(item.effectiveProgram, content: content)
                outputs.append((name: OutputNames.unified(item.effectiveProgram, prefix: prefixByID[item.id]), data: g.serialized()))
                if !plan.warnings.isEmpty { unfamiliar.append("\(item.name) (\(item.program.version), \(item.program.valuesPerPart) values per part)") }
            } catch { failed.append("\(item.name): \(error)") }
        }
        let written = Panels.write(outputs, into: folder)
        var msg = "Wrote \(written) .pgdata file\(written == 1 ? "" : "s") to \(folder.path)."
        // One item per line, a blank line between sections.
        if !blocked.isEmpty { msg += "\n\nNot written, content missing:\n" + blocked.joined(separator: "\n") }
        if !failed.isEmpty { msg += "\n\nFailed:\n" + failed.joined(separator: "\n") }
        if !unfamiliar.isEmpty { msg += "\n\nWritten from an unfamiliar program layout (check them on the synth):\n" + unfamiliar.joined(separator: "\n") }
        let unused = unusedContent
        if !unused.isEmpty {
            msg += "\n\nAdded files not used by any program (and not added to any .pgdata file):\n" + contentFiles.filter { unused[$0.id] != nil }
                .map { "\($0.url.lastPathComponent) (\(unused[$0.id]!.lowercased()))" }.joined(separator: "\n")
        }
        note(msg)
        if !blocked.isEmpty || !failed.isEmpty || !unfamiliar.isEmpty || !unused.isEmpty { alertMessage = msg }
    }

    // MARK: Unpack

    /// Recomputes descriptions and factory-duplicate flags, keeping the user's file names and
    /// Write choices (only the default for factory duplicates follows the "skip" setting).
    func rebuildUnpackPlans() {
        for i in unpacks.indices {
            let old = unpacks[i].plan.items
            var plan = UnpackPlan.make(unpacks[i].unified, factory: factory, skipFactoryDuplicates: skipFactoryDuplicates)
            for j in plan.items.indices {
                guard let prev = old.first(where: { $0.ref == plan.items[j].ref }) else { continue }
                plan.items[j].fileName = prev.fileName
                if !plan.items[j].isFactoryDuplicate { plan.items[j].write = prev.write }
            }
            unpacks[i].plan = plan
        }
    }

    func setUnpackItem(_ unpackID: UUID, _ itemID: UUID, write: Bool? = nil, fileName: String? = nil) {
        guard let i = unpacks.firstIndex(where: { $0.id == unpackID }),
              let j = unpacks[i].plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        if let w = write { unpacks[i].plan.items[j].write = w }
        if let n = fileName { unpacks[i].plan.items[j].fileName = n }
    }

    func removeUnpacks(_ ids: Set<UUID>) { unpacks.removeAll { ids.contains($0.id) }; if let s = selectedUnpack, ids.contains(s) { selectedUnpack = unpacks.first?.id } }

    func unpack(_ ids: [UUID]) {
        let items = unpacks.filter { ids.contains($0.id) }
        guard !items.isEmpty, let folder = Panels.chooseFolder(prompt: "Unpack Here", message: "Choose where to write the unpacked files") else { return }
        // Identical files (same name and content) shared by several programs are written once.
        var outputs: [(name: String, data: Data)] = []
        for item in items {
            for f in item.plan.items where f.write {
                if outputs.contains(where: { $0.name == f.fileName && $0.data == f.data }) { continue }
                outputs.append((name: f.fileName, data: f.data))
            }
        }
        let written = Panels.write(outputs, into: folder)
        note("Unpacked \(items.count) file\(items.count == 1 ? "" : "s"): wrote \(written) file\(written == 1 ? "" : "s") to \(folder.path).")
    }
}
