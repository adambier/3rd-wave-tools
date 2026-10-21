import AppKit
import Combine
import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the single-module swiftc build
#endif

/// All app state. Plain ObservableObject, used only from the main thread (as in ThirdWaveWT).
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case pack = "Pack", unpack = "Unpack", slots = "Synth Slots"
        var id: String { rawValue }
        var icon: String {
            switch self { case .pack: return "shippingbox"; case .unpack: return "tray.and.arrow.up"; case .slots: return "square.grid.3x3" }
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
    @Published var profile = SlotProfile() { didSet { saveProfile() } }
    @Published var factoryFolders: [URL] = [] { didSet { saveSettings(); reloadFactory() } }
    @Published private(set) var factory = FactoryLibrary()
    @Published var embedFactory = false { didSet { saveSettings() } }
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
        Self.migrateFromOldName(defaults)
        if let paths = defaults.stringArray(forKey: "factoryFolders") {
            factoryFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        embedFactory = defaults.bool(forKey: "embedFactory")
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
        if let d = try? Data(contentsOf: profileURL), let p = try? SlotProfile.decoded(d) { profile = p }
        loading = false
        reloadFactory()
    }

    // MARK: Persistence

    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var supportDir: URL { Self.supportBase.appendingPathComponent("pgdata Packer", isDirectory: true) }

    /// The app was first built as "ThirdWavePG" (bundle id org.biers.thirdwavepg). Carry its
    /// settings and slot list over once, leaving the old copies in place.
    private static func migrateFromOldName(_ defaults: UserDefaults) {
        if defaults.object(forKey: "factoryFolders") == nil, let old = UserDefaults(suiteName: "org.biers.thirdwavepg") {
            for key in ["factoryFolders", "embedFactory", "skipFactoryDuplicates"] {
                if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
            }
        }
        let fm = FileManager.default
        let oldFile = supportBase.appendingPathComponent("ThirdWavePG/synth-slots.json")
        let newDir = supportBase.appendingPathComponent("pgdata Packer", isDirectory: true)
        let newFile = newDir.appendingPathComponent("synth-slots.json")
        if !fm.fileExists(atPath: newFile.path), fm.fileExists(atPath: oldFile.path) {
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? fm.copyItem(at: oldFile, to: newFile)
        }
    }
    private var profileURL: URL { supportDir.appendingPathComponent("synth-slots.json") }

    private func saveProfile() {
        guard !loading else { return }
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try profile.encoded().write(to: profileURL, options: .atomic)
        } catch { note("Could not save the slot list: \(error.localizedDescription)") }
    }

    private func saveSettings() {
        guard !loading else { return }
        defaults.set(factoryFolders.map(\.path), forKey: "factoryFolders")
        defaults.set(embedFactory, forKey: "embedFactory")
        defaults.set(skipFactoryDuplicates, forKey: "skipFactoryDuplicates")
        defaults.set(nameCleaner.stripSlots, forKey: "cleanStripSlots")
        defaults.set(nameCleaner.underscoresToSpaces, forKey: "cleanUnderscores")
        defaults.set(nameCleaner.titleCase, forKey: "cleanTitleCase")
        defaults.set(nameCleaner.fixedSpellings, forKey: "cleanFixedSpellings")
    }

    /// Reading the factory .wt files takes a moment (about 92 text files), so it runs off the main thread.
    @Published private(set) var loadingFactory = false
    private var factoryGeneration = 0

    func reloadFactory() {
        let folders = factoryFolders
        factoryGeneration += 1
        let generation = factoryGeneration
        loadingFactory = true
        DispatchQueue.global(qos: .userInitiated).async {
            let lib = FactoryLibrary(folders: folders)
            DispatchQueue.main.async {
                guard generation == self.factoryGeneration else { return }
                self.factory = lib
                self.loadingFactory = false
                self.rebuildUnpackPlans()
            }
        }
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
        PackPlan.make(program: item.effectiveProgram, files: contentFiles, profile: profile, factory: factory,
                      embedFactory: embedFactory, overrides: item.overrides, original: item.program)
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
    /// (U56–U63, P36–P47) that no other added file is assigned to and that Synth Slots does not
    /// record as holding another file. The user can change it.
    func suggestedSlot(for file: ContentFile, alsoTaken: Set<SourceRef> = []) -> SourceRef? {
        guard !file.isSample else { return nil }
        let taken = Set(contentFiles.compactMap { $0.id == file.id ? nil : $0.slot }).union(alsoTaken)
        let candidates: [SourceRef] = file.isPTable ? (36..<SourceRef.pCount).map { .p($0) } : (56..<SourceRef.uCount).map { .u($0) }
        return candidates.first { !taken.contains($0) && profile.entry($0).state != .file }
            ?? candidates.first { !taken.contains($0) } ?? candidates.first
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
        let e = profile.entry(ref)
        switch e.state {
        case .file: return e.name
        case .factory: return factory.name(ref) ?? "Factory table"
        case .empty: return "Blank"
        case .unknown: return ref.isFactorySlot ? (factory.name(ref) ?? "Factory table") : "Unknown"
        }
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
            return ref.isFactorySlot ? "Factory " + (factory.name(ref).map { "\"\($0)\"" } ?? "table") + " — not embedded"
                                     : "Leave to the synth — not embedded"
        case .factory: return "Factory " + (factory.name(ref).map { "\"\($0)\"" } ?? "table") + " — embedded"
        case .file(let id):
            let f = contentFiles.first { $0.id == id }
            return "\"\(f?.name ?? "?")\" (\(f?.url.lastPathComponent ?? "?"))"
        case .profile: return "As on my synth: \"\(profile.entry(ref).name)\""
        }
    }

    /// Writes .pgdata files for the given programs into a folder chosen by the user.
    func writeUnified(_ ids: [UUID]) {
        let items = programs.filter { ids.contains($0.id) }
        guard !items.isEmpty, let folder = Panels.chooseFolder(prompt: "Write Here", message: "Choose where to write the .pgdata files") else { return }
        var outputs: [(name: String, data: Data)] = []
        var blocked: [String] = [], failed: [String] = []
        // Prefix each file with its program location (or list position) so the synth's alphabetical
        // bulk import keeps the programs in order. Positions count over the whole list.
        let prefixes = OutputNames.orderPrefixes(fileNames: programs.map { $0.url.lastPathComponent })
        let prefixByID = Dictionary(uniqueKeysWithValues: zip(programs.map(\.id), prefixes))
        for item in items {
            let plan = plan(for: item)
            switch plan.verdict {
            case .blocked(let refs):
                blocked.append("\(item.name) (needs \(refs.map(\.label).joined(separator: ", ")))"); continue
            default: break
            }
            do {
                let content = try plan.content(files: contentFiles, profile: profile, factory: factory, names: contentNames)
                let g = try Packer.pack(item.effectiveProgram, content: content)
                outputs.append((name: OutputNames.unified(item.effectiveProgram, prefix: prefixByID[item.id]), data: g.serialized()))
            } catch { failed.append("\(item.name): \(error)") }
        }
        let written = Panels.write(outputs, into: folder)
        var msg = "Wrote \(written) .pgdata file\(written == 1 ? "" : "s") to \(folder.path)."
        // One item per line, a blank line between sections.
        if !blocked.isEmpty { msg += "\n\nNot written, content missing:\n" + blocked.joined(separator: "\n") }
        if !failed.isEmpty { msg += "\n\nFailed:\n" + failed.joined(separator: "\n") }
        let unused = unusedContent
        if !unused.isEmpty {
            msg += "\n\nAdded files not used by any program:\n" + contentFiles.filter { unused[$0.id] != nil }
                .map { "\($0.url.lastPathComponent) (\(unused[$0.id]!.lowercased()))" }.joined(separator: "\n")
        }
        note(msg)
        if !blocked.isEmpty || !failed.isEmpty || !unused.isEmpty { alertMessage = msg }
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

    // MARK: Synth slots

    func assignFile(to ref: SourceRef) {
        guard ref.isWavetable else { return }   // sample slots are not tracked
        guard let url = Panels.chooseFile(types: ["wt"],
                                          message: "Choose the wavetable (.wt) that is in \(ref.label) on your synth") else { return }
        do {
            let f = try ContentFile.load(url)
            guard f.fits(ref) else { alertMessage = "\(url.lastPathComponent) is a \(f.kindLabel.lowercased()); \(ref.label) needs a \(ref.isP ? "P wavetable" : "U wavetable")."; return }
            profile.assign(f, to: ref)
            note("\(ref.label) set to \"\(f.name)\" (\(url.lastPathComponent)).")
        } catch { alertMessage = "\(url.lastPathComponent): \(error)" }
    }

    func setSlotState(_ ref: SourceRef, _ state: SlotEntry.State) {
        var e = profile.entry(ref)
        e.state = state
        if state != .file { e.path = nil; e.fingerprint = nil }
        if state == .factory || state == .unknown { e.name = "" }
        profile.set(ref, e)
    }

    func renameSlot(_ ref: SourceRef, _ name: String) {
        var e = profile.entry(ref); e.name = name; profile.set(ref, e)
    }

    /// Assigns dropped wavetable files to the slots their names suggest ("U48 SM OBX8 1.WT"),
    /// after the user confirms the list. Multisamples are not tracked here; they go on the Pack screen.
    func assignByFilename(_ urls: [URL]) {
        var pairs: [(SourceRef, ContentFile)] = []
        var unplaced: [String] = []
        for u in urls {
            guard let f = try? ContentFile.load(u) else { unplaced.append(u.lastPathComponent + " (unreadable)"); continue }
            if f.isSample { unplaced.append(u.lastPathComponent + " (multisamples are added on the Pack screen)"); continue }
            if let s = f.slot, f.fits(s) { pairs.append((s, f)) } else { unplaced.append(u.lastPathComponent) }
        }
        guard !pairs.isEmpty else {
            alertMessage = "Nothing to assign" + (unplaced.isEmpty ? ": no files." : ":\n" + unplaced.joined(separator: "\n")) + "\n\nWavetable file names must start with a slot (\"U48 …\"); otherwise use Set… → Assign File… on a slot. Multisamples are added on the Pack screen."
            return
        }
        let list = pairs.map { "\($0.0.label)  ←  \($0.1.url.lastPathComponent)" }.joined(separator: "\n")
        let extra = unplaced.isEmpty ? "" : "\n\nNot assigned:\n" + unplaced.joined(separator: "\n")
        if Panels.confirm(title: "Assign these files to slots?", message: list + extra, ok: "Assign") {
            for (s, f) in pairs { profile.assign(f, to: s) }
            note("Assigned \(pairs.count) file\(pairs.count == 1 ? "" : "s") to slots by name.")
        }
    }
}
