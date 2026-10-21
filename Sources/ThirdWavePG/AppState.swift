import AppKit
import Combine
import Foundation
#if canImport(ThirdWaveFormats)
import ThirdWaveFormats   // SwiftPM build; absent in the single-module swiftc build
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
    @Published var writeWhenNotNeeded = false { didSet { saveSettings() } }
    @Published var skipFactoryDuplicates = true { didSet { saveSettings(); rebuildUnpackPlans() } }

    // Pack
    @Published var programs: [PackItem] = []
    @Published var contentFiles: [ContentFile] = []
    @Published var selectedProgram: UUID?

    // Unpack
    @Published var unpacks: [UnpackItem] = []
    @Published var selectedUnpack: UUID?

    // Messages
    @Published var log: [String] = []
    @Published var alertMessage: String?

    private let defaults = UserDefaults.standard
    private var loading = true

    init() {
        if let paths = defaults.stringArray(forKey: "factoryFolders") {
            factoryFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        embedFactory = defaults.bool(forKey: "embedFactory")
        writeWhenNotNeeded = defaults.bool(forKey: "writeWhenNotNeeded")
        if defaults.object(forKey: "skipFactoryDuplicates") != nil {
            skipFactoryDuplicates = defaults.bool(forKey: "skipFactoryDuplicates")
        }
        if let d = try? Data(contentsOf: profileURL), let p = try? SlotProfile.decoded(d) { profile = p }
        loading = false
        reloadFactory()
    }

    // MARK: Persistence

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ThirdWavePG", isDirectory: true)
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
        defaults.set(writeWhenNotNeeded, forKey: "writeWhenNotNeeded")
        defaults.set(skipFactoryDuplicates, forKey: "skipFactoryDuplicates")
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
        PackPlan.make(program: item.program, files: contentFiles, profile: profile, factory: factory,
                      embedFactory: embedFactory, overrides: item.overrides)
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
        var skippedPlain: [String] = [], blocked: [String] = [], failed: [String] = []
        for item in items {
            let plan = plan(for: item)
            switch plan.verdict {
            case .blocked(let refs):
                blocked.append("\(item.program.name) (needs \(refs.map(\.label).joined(separator: ", ")))"); continue
            case .plainProgramEnough where !writeWhenNotNeeded:
                skippedPlain.append(item.program.name); continue
            default: break
            }
            do {
                let content = try plan.content(files: contentFiles, profile: profile, factory: factory)
                let g = try Packer.pack(item.program, content: content)
                outputs.append((name: OutputNames.unified(item.program), data: g.serialized()))
            } catch { failed.append("\(item.program.name): \(error)") }
        }
        let written = Panels.write(outputs, into: folder)
        var msg = "Wrote \(written) .pgdata file\(written == 1 ? "" : "s") to \(folder.path)."
        if !skippedPlain.isEmpty { msg += "\nNo .pgdata needed (factory content only), so not written: " + skippedPlain.joined(separator: ", ") + "." }
        if !blocked.isEmpty { msg += "\nNot written, content missing: " + blocked.joined(separator: "; ") + "." }
        if !failed.isEmpty { msg += "\nFailed: " + failed.joined(separator: "; ") }
        note(msg)
        if !blocked.isEmpty || !failed.isEmpty || !skippedPlain.isEmpty { alertMessage = msg }
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
        guard let url = Panels.chooseFile(types: ref.isSample ? ["bin"] : ["wt"],
                                          message: "Choose the \(ref.isSample ? "multisample (.bin)" : "wavetable (.wt)") that is in \(ref.label) on your synth") else { return }
        do {
            let f = try ContentFile.load(url)
            guard f.fits(ref) else { alertMessage = "\(url.lastPathComponent) is a \(f.kindLabel.lowercased()); \(ref.label) needs a \(ref.isSample ? "multisample" : (ref.isP ? "P wavetable" : "U wavetable"))."; return }
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

    /// Assigns dropped files to the slots their names suggest ("U48 SM OBX8 1.WT", "S010_JP8.bin"),
    /// after the user confirms the list.
    func assignByFilename(_ urls: [URL]) {
        var pairs: [(SourceRef, ContentFile)] = []
        var unplaced: [String] = []
        for u in urls {
            guard let f = try? ContentFile.load(u) else { unplaced.append(u.lastPathComponent + " (unreadable)"); continue }
            if let s = f.slot, f.fits(s) { pairs.append((s, f)) } else { unplaced.append(u.lastPathComponent) }
        }
        guard !pairs.isEmpty else {
            alertMessage = "None of these file names say which slot they belong in. Use the Assign button on a slot instead."
            return
        }
        let list = pairs.map { "\($0.0.label)  ←  \($0.1.url.lastPathComponent)" }.joined(separator: "\n")
        let extra = unplaced.isEmpty ? "" : "\n\nNot assigned (no slot in the name): " + unplaced.joined(separator: ", ")
        if Panels.confirm(title: "Assign these files to slots?", message: list + extra, ok: "Assign") {
            for (s, f) in pairs { profile.assign(f, to: s) }
            note("Assigned \(pairs.count) file\(pairs.count == 1 ? "" : "s") to slots by name.")
        }
    }
}
