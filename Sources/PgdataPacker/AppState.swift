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
        /// Bank and program from the file name or its "Bank n" folder, as the 3rd Wave shows it ("B4-P029").
        var location: (bank: Int, program: Int)? { OutputNames.programLocation(of: url) }
        var locationLabel: String? { location.map { String(format: "B%d-P%03d", $0.bank, $0.program) } }
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

    @Published var section: Section = .pack
    /// Text typed into the filter field above the program list.
    @Published var programFilter = ""
    /// Show only programs that cannot be packed yet or carry a warning.
    @Published var onlyAttention = false
    /// Files being read in the background: how many of how many so far.
    struct LoadProgress { var done: Int; var total: Int }
    @Published var reading: LoadProgress?
    /// A folder the current alert can open in the Finder.
    @Published var alertReveal: URL?

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
        // Settings from versions that asked for the factory .wt files and tracked the 3rd Wave's slots.
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

    /// What reading one file produced, on the background queue.
    private enum Loaded {
        case program(URL, ProgramFile)
        case content(ContentFile)
        case unified(URL, UnifiedProgram, UnpackPlan)
        case problem(String)
    }

    /// Accepts any mix of .pro, .wt, .bin and .pgdata files (folders are searched). Files are read
    /// on a background queue, with progress shown, since a folder of wavetables is many megabytes
    /// of text; the results are added on the main thread in one go.
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
        let known = Set(programs.map(\.url) + contentFiles.map(\.url) + unpacks.map(\.url))
        let todo = all.sorted { $0.path < $1.path }
            .filter { ["pro", "wt", "bin", "pgdata"].contains($0.pathExtension.lowercased()) && !known.contains($0) }
        guard !todo.isEmpty else { return }
        reading = LoadProgress(done: 0, total: todo.count)
        let factory = self.factory, skip = self.skipFactoryDuplicates
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [Loaded] = []
            for (i, u) in todo.enumerated() {
                do {
                    switch u.pathExtension.lowercased() {
                    case "pro": results.append(.program(u, try ProgramFile(data: Data(contentsOf: u))))
                    case "wt", "bin": results.append(.content(try ContentFile.load(u)))
                    case "pgdata":
                        let g = try UnifiedProgram(data: Data(contentsOf: u))
                        results.append(.unified(u, g, UnpackPlan.make(g, factory: factory, skipFactoryDuplicates: skip)))
                    default: break
                    }
                } catch { results.append(.problem("\(u.lastPathComponent): \(error)")) }
                if i % 5 == 4 || i == todo.count - 1 {
                    let done = i + 1
                    DispatchQueue.main.async { self?.reading = LoadProgress(done: done, total: todo.count) }
                }
            }
            DispatchQueue.main.async { self?.finishAdding(results) }
        }
    }

    private func finishAdding(_ results: [Loaded]) {
        reading = nil
        var problems: [String] = []
        var addedPrograms = 0, addedContent = 0, addedUnified = 0
        for r in results {
            switch r {
            case let .program(u, p): programs.append(PackItem(url: u, program: p)); addedPrograms += 1
            case let .content(c): contentFiles.append(c); addedContent += 1
            case let .unified(u, g, plan): unpacks.append(UnpackItem(url: u, unified: g, plan: plan)); addedUnified += 1
            case let .problem(s): problems.append(s)
            }
        }
        // Programs in bank and program order, as on the 3rd Wave; files without a location after them.
        programs.sort { a, b in
            switch (a.location, b.location) {
            case let (x?, y?): return (x.bank, x.program) < (y.bank, y.program)
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.url.path < b.url.path
            }
        }
        if selectedProgram == nil { selectedProgram = programs.first?.id }
        if selectedUnpack == nil { selectedUnpack = unpacks.first?.id }
        var parts: [String] = []
        if addedPrograms > 0 { parts.append("\(addedPrograms) program\(addedPrograms == 1 ? "" : "s")") }
        if addedContent > 0 { parts.append("\(addedContent) wavetable/sample file\(addedContent == 1 ? "" : "s")") }
        if addedUnified > 0 { parts.append("\(addedUnified) .pgdata file\(addedUnified == 1 ? "" : "s")") }
        if !parts.isEmpty { note("Added " + parts.joined(separator: ", ") + ".") }
        // Show the page the dropped files belong to.
        if addedUnified > 0 && addedPrograms == 0 && addedContent == 0 { section = .unpack }
        else if addedUnified == 0 && addedPrograms + addedContent > 0 { section = .pack }
        if !problems.isEmpty {
            problems.forEach { note("Could not read \($0)") }
            alertMessage = "Some files could not be read:\n\n" + problems.prefix(8).joined(separator: "\n")
                + (problems.count > 8 ? "\n…and \(problems.count - 8) more (see the log)." : "")
        }
    }

    // MARK: Pack

    func plan(for item: PackItem) -> PackPlan {
        PackPlan.make(program: item.effectiveProgram, files: contentFiles, factory: factory,
                      overrides: item.overrides, original: item.program, names: contentNames)
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
        PackPlan.unusedFiles(contentFiles, plans: programs.map { plan(for: $0) }, factory: factory)
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

    /// Suggestions for every unassigned wavetable file, each one different: the files in file-name
    /// order (numerically, so 2.wt comes before 10.wt) take the free user slots in order
    /// (01.wt → U56, 02.wt → U57), which is how sets that ship numbered files mean them to be loaded.
    func suggestedSlots() -> [UUID: SourceRef] {
        var out: [UUID: SourceRef] = [:]
        var used = Set<SourceRef>()
        let unassigned = contentFiles.filter { !$0.isSample && $0.slot == nil }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        for f in unassigned {
            if let s = suggestedSlot(for: f, alsoTaken: used) { out[f.id] = s; used.insert(s) }
        }
        return out
    }

    /// What a wavetable slot holds on the user's 3rd Wave, for display.
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
            return "Factory \(factory.name(ref) ?? ref.label) (the 3rd Wave's own copy)"
        case .file(let id):
            let f = contentFiles.first { $0.id == id }
            return "\(f.map(displayName) ?? "?") — from \(f?.url.lastPathComponent ?? "?")"
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
                alertMessage = (items.count == 1 ? "This program can't be packed yet: it needs files that aren't here."
                                                 : "None of these programs can be packed yet: they need files that aren't here.")
                    + "\n\n" + missing.joined(separator: "\n")
                    + "\n\nAdd the .wt or .bin files they need."
                    + (oldTables ? " For wavetables from before 2025, the note with each program explains the choices." : "")
                return
            }
            let n = missing.count
            guard Panels.confirm(
                title: "\(n) of \(items.count) programs can't be packed yet",
                message: "\(n == 1 ? "It needs files that aren't here and" : "They need files that aren't here and") will be left out. Pack the other \(ok)?",
                details: missing.joined(separator: "\n"),
                ok: "Pack \(ok)") else { return }
        }
        guard let folder = Panels.chooseFolder(prompt: "Pack Here", message: "Choose where to put the .pgdata files") else { return }
        var outputs: [(name: String, data: Data)] = []
        var blocked: [String] = [], failed: [String] = [], unfamiliar: [String] = [], replaced: [String] = []
        // Prefix each file with its program location (or its position among the files written) so
        // the 3rd Wave's alphabetical bulk import keeps the programs in order.
        let prefixes = OutputNames.orderPrefixes(urls: items.map(\.url))
        let prefixByID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), prefixes))
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
                if !plan.warnings.isEmpty { unfamiliar.append(item.name) }
                for r in plan.rows where r.replacesFactory {
                    if case .file(let id)? = r.choice, let f = contentFiles.first(where: { $0.id == id }) {
                        replaced.append("\(item.name): \(r.ref.label) uses \(f.url.lastPathComponent) instead of factory \(factory.name(r.ref).map { "\"\($0)\"" } ?? "table")")
                    }
                }
            } catch { failed.append("\(item.name): \(error)") }
        }
        guard let result = Panels.write(outputs, into: folder) else { note("Packing cancelled; nothing written."); return }
        failed += result.failed
        let written = result.written
        var msg = "Packed \(written) program\(written == 1 ? "" : "s") into \"\(folder.lastPathComponent)\"."
        // One item per line, a blank line between sections.
        if !blocked.isEmpty { msg += "\n\nNot packed (files missing):\n" + blocked.joined(separator: "\n") }
        if !failed.isEmpty { msg += "\n\nNot packed:\n" + failed.joined(separator: "\n") }
        if !replaced.isEmpty { msg += "\n\nFactory tables replaced by added files (check these are meant):\n" + replaced.joined(separator: "\n") }
        if !unfamiliar.isEmpty { msg += "\n\nPacked, but check these on the 3rd Wave (unfamiliar layout or a cut name; see each program's notes):\n" + unfamiliar.joined(separator: "\n") }
        let unused = unusedContent
        if !unused.isEmpty {
            msg += "\n\nAdded files that no program uses (left out):\n" + contentFiles.filter { unused[$0.id] != nil }
                .map { "\($0.url.lastPathComponent) (\(unused[$0.id]!.lowercased()))" }.joined(separator: "\n")
        }
        note(msg + " (\(folder.path))")
        alertReveal = folder
        alertMessage = msg
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
        // An edited name is cleaned the way generated ones are ("/" and the like become "_");
        // an empty one falls back to the generated name.
        if let n = fileName {
            let cleaned = OutputNames.sanitize(n)
            unpacks[i].plan.items[j].fileName = cleaned == "Untitled" && n.trimmingCharacters(in: .whitespaces).isEmpty
                ? UnpackPlan.make(unpacks[i].unified, factory: factory, skipFactoryDuplicates: skipFactoryDuplicates).items[j].fileName
                : cleaned
        }
    }

    func removeUnpacks(_ ids: Set<UUID>) { unpacks.removeAll { ids.contains($0.id) }; if let s = selectedUnpack, ids.contains(s) { selectedUnpack = unpacks.first?.id } }

    func unpack(_ ids: [UUID]) {
        let items = unpacks.filter { ids.contains($0.id) }
        guard !items.isEmpty, let folder = Panels.chooseFolder(prompt: "Unpack Here", message: "Choose where to put the unpacked files") else { return }
        // Identical files (same name and content) shared by several programs are written once.
        var outputs: [(name: String, data: Data)] = []
        for item in items {
            for f in item.plan.items where f.write {
                if outputs.contains(where: { $0.name == f.fileName && $0.data == f.data }) { continue }
                outputs.append((name: f.fileName, data: f.data))
            }
        }
        guard let result = Panels.write(outputs, into: folder) else { note("Unpacking cancelled; nothing written."); return }
        var msg = "Unpacked \(items.count) file\(items.count == 1 ? "" : "s") into \"\(folder.lastPathComponent)\": \(result.written) file\(result.written == 1 ? "" : "s") written."
        if !result.failed.isEmpty { msg += "\n\nNot written:\n" + result.failed.joined(separator: "\n") }
        note(msg + " (\(folder.path))")
        alertReveal = folder
        alertMessage = msg
    }
}
