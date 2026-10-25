import AppKit
import Combine
import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the single-module swiftc build
#endif
#if canImport(WavetableFormats)
import WavetableFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// All app state. Plain ObservableObject, used only from the main thread (as in ThirdWaveWT).
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case pack = "Pack", unpack = "Unpack", convert = "Wavetables"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .pack: return "shippingbox"
            case .unpack: return "tray.and.arrow.up"
            case .convert: return "waveform"
            }
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

    // Convert
    /// The wavetables added to the Wavetables page, the destination, and its options. The
    /// destination and the frame-count choice are remembered between sessions.
    @Published var convertPlan = ConvertPlan() { didSet { saveSettings() } }
    /// Show only the Wavetables page's tables that need a look (blocked, guessed frame size, or a warning).
    @Published var convertOnlyAttention = false
    /// The writer's results for the tables the Convert detail pane shows, kept between passes.
    let convertPreviews = ConvertPreviewCache()

    // Messages
    @Published var log: [String] = []
    @Published var alertMessage: String?

    private let defaults = UserDefaults.standard
    private var loading = true
    /// Plans by program id, built on demand and dropped whenever anything they depend on changes.
    /// The views ask for plans many times per render (rows, filter, usage counts), so this keeps a
    /// window with a hundred programs responsive.
    private var planCache: [UUID: PackPlan] = [:]
    private var cancellables = Set<AnyCancellable>()

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
        if let raw = defaults.string(forKey: "convertPreset"), let p = OutputPreset(rawValue: raw) {
            convertPlan.preset = p
        }
        if let raw = defaults.string(forKey: "convertFrameCountPolicy"), let p = FrameCountPolicy(rawValue: raw) {
            convertPlan.options.frameCountPolicy = p
        }
        // Settings from versions that asked for the factory .wt files and tracked the 3rd Wave's slots.
        for key in ["factoryFolders", "embedFactory", "synthHasAllFactory"] { defaults.removeObject(forKey: key) }
        loading = false
        Publishers.Merge3($programs.map { _ in () }, $contentFiles.map { _ in () }, $contentNames.map { _ in () })
            .sink { [weak self] in self?.planCache = [:] }
            .store(in: &cancellables)
    }

    // MARK: Persistence

    private func saveSettings() {
        guard !loading else { return }
        defaults.set(skipFactoryDuplicates, forKey: "skipFactoryDuplicates")
        defaults.set(nameCleaner.stripSlots, forKey: "cleanStripSlots")
        defaults.set(nameCleaner.underscoresToSpaces, forKey: "cleanUnderscores")
        defaults.set(nameCleaner.titleCase, forKey: "cleanTitleCase")
        defaults.set(nameCleaner.fixedSpellings, forKey: "cleanFixedSpellings")
        defaults.set(convertPlan.preset.rawValue, forKey: "convertPreset")
        defaults.set(convertPlan.options.frameCountPolicy.rawValue, forKey: "convertFrameCountPolicy")
    }

    // MARK: Messages

    func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(ReportText.plain(s))")
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
        guard !urls.isEmpty else { return }
        let known = Set(programs.map(\.url) + contentFiles.map(\.url) + unpacks.map(\.url))
        let factory = self.factory, skip = self.skipFactoryDuplicates
        batchesReading += 1
        reading = reading ?? LoadProgress(done: 0, total: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Folders are walked here too: a dropped volume or home folder would otherwise freeze the window.
            var all: [URL] = []
            let fm = FileManager.default
            for u in urls {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
                   let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e { all.append(f) }
                } else { all.append(u) }
            }
            let wanted = all.filter { ["pro", "wt", "bin", "pgdata"].contains($0.pathExtension.lowercased()) }
            let todo = wanted.sorted { $0.path < $1.path }.filter { !known.contains($0) }
            DispatchQueue.main.async { self?.reading = LoadProgress(done: 0, total: todo.count) }
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
                } catch { results.append(.problem("\(u.lastPathComponent): \(Self.describe(error))")) }
                if i % 5 == 4 || i == todo.count - 1 {
                    let done = i + 1
                    DispatchQueue.main.async { self?.reading = LoadProgress(done: done, total: todo.count) }
                }
            }
            let wav = all.filter { ["wav", "wave"].contains($0.pathExtension.lowercased()) }.count
            let skipped = (dropped: all.count - wanted.count, known: wanted.count - todo.count, wav: wav)
            DispatchQueue.main.async { self?.finishAdding(results, skipped: skipped) }
        }
    }

    /// Batches of files still being read; the progress indicator stays until the last one finishes.
    private var batchesReading = 0

    /// The reason a file could not be read, in plain words: the library's own messages as they
    /// are, Foundation's as macOS phrases them (not the raw NSError dump).
    static func describe(_ error: Error) -> String {
        if let e = error as? FormatError { return e.description }
        if let e = error as? PackError { return e.description }
        return error.localizedDescription
    }

    private func finishAdding(_ results: [Loaded], skipped: (dropped: Int, known: Int, wav: Int)) {
        batchesReading -= 1
        if batchesReading <= 0 { batchesReading = 0; reading = nil }
        var problems: [String] = []
        var addedPrograms = 0, addedContent = 0, addedUnified = 0
        // A file added by another batch in the meantime (the same folder dropped twice) is not added again.
        var known = Set(programs.map(\.url) + contentFiles.map(\.url) + unpacks.map(\.url))
        var repeated = skipped.known
        for r in results {
            switch r {
            case let .program(u, p):
                guard known.insert(u).inserted else { repeated += 1; continue }
                programs.append(PackItem(url: u, program: p)); addedPrograms += 1
            case let .content(c):
                guard known.insert(c.url).inserted else { repeated += 1; continue }
                contentFiles.append(c); addedContent += 1
            case let .unified(u, g, plan):
                guard known.insert(u).inserted else { repeated += 1; continue }
                unpacks.append(UnpackItem(url: u, unified: g, plan: plan)); addedUnified += 1
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
        if addedContent > 0 { parts.append("\(addedContent) wavetable or sample file\(addedContent == 1 ? "" : "s")") }
        if addedUnified > 0 { parts.append("\(addedUnified) .pgdata file\(addedUnified == 1 ? "" : "s")") }
        if !parts.isEmpty { note("Added " + parts.joined(separator: ", ") + ".") }
        else if problems.isEmpty {
            // Nothing happened; say why, so a drop that does nothing is not a mystery.
            var why: [String] = []
            if repeated > 0 { why.append("\(repeated) already in the lists") }
            if skipped.dropped > 0 { why.append("\(skipped.dropped) not .pro, .wt, .bin, or .pgdata files") }
            note("Nothing added" + (why.isEmpty ? "." : ": " + why.joined(separator: "; ") + "."))
        }
        if skipped.wav > 0 {
            note(skipped.wav == 1
                 ? "1 WAV file was left out: Pack takes 3rd Wave files. If it is a wavetable, the Wavetables page can convert it to a 3rd Wave table."
                 : "\(skipped.wav) WAV files were left out: Pack takes 3rd Wave files. Wavetables among them can be converted to 3rd Wave tables on the Wavetables page.")
        }
        // Show the page the dropped files belong to.
        if addedUnified > 0 && addedPrograms == 0 && addedContent == 0 { section = .unpack }
        else if addedUnified == 0 && addedPrograms + addedContent > 0 { section = .pack }
        if !problems.isEmpty {
            problems.forEach { note("Could not read \($0)") }
            alertMessage = "Some files could not be read.\n\n" + problems.prefix(8).map { ReportText.item(splitting: $0) }.joined(separator: "\n")
                + (problems.count > 8 ? "\n\n…and \(problems.count - 8) more (see the log)." : "")
        }
    }

    // MARK: Pack

    func plan(for item: PackItem) -> PackPlan {
        if let p = planCache[item.id] { return p }
        // The caller's copy may be stale; plan the program as it is now.
        let cur = programs.first { $0.id == item.id } ?? item
        let p = PackPlan.make(program: cur.effectiveProgram, files: contentFiles, factory: factory,
                              overrides: cur.overrides, original: cur.program, names: contentNames)
        planCache[item.id] = p
        return p
    }

    /// The name an added file will be packed under.
    func displayName(_ f: ContentFile) -> String { contentNames[f.id] ?? f.name }

    /// Added files that are copies of a factory wavetable: never offered for renaming.
    func isFactoryCopy(_ f: ContentFile) -> Bool {
        !f.isSample && factory.slot(withFingerprint: f.fingerprint) != nil
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
        let candidates: [SourceRef] = file.isPTable ? (SourceRef.factoryPCount..<SourceRef.pCount).map { .p($0) }
                                                    : (SourceRef.factoryUCount..<SourceRef.uCount).map { .u($0) }
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

    /// Slot label and what it holds ("U07  Knob Grotto 6"), or the label alone when the name only
    /// repeats it: the factory P00–P33 tables are named "Wavetable P00" … "Wavetable P33".
    func labelledSlot(_ ref: SourceRef, separator: String = "  ") -> String {
        let name = slotName(ref)
        return name == "Wavetable \(ref.label)" ? ref.label : ref.label + separator + name
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
    func removeContent(_ id: UUID) { contentFiles.removeAll { $0.id == id }; contentNames[id] = nil }

    /// Empties the Pack page, programs and added files alike, after asking. Files are not touched.
    func removeAllPack() {
        let n = programs.count, f = contentFiles.count
        guard n + f > 0 else { return }
        var parts: [String] = []
        if n > 0 { parts.append("\(n) program\(n == 1 ? "" : "s")") }
        if f > 0 { parts.append("\(f) added file\(f == 1 ? "" : "s")") }
        let what = parts.joined(separator: " and ")
        guard Panels.confirm(title: "Remove everything from the Pack page?",
                             message: "This removes \(what) from the lists, with any slots, choices, and names you set for them. The files themselves are not touched.",
                             ok: "Remove All") else { return }
        programs = []; contentFiles = []; contentNames = [:]; selectedProgram = nil
        note("Removed \(what) from the Pack page.")
    }

    func describe(_ choice: PackPlan.Choice, for ref: SourceRef) -> String {
        switch choice {
        case .builtIn: return ref.description
        case .reference:
            // "Factory table — Human Vowel Sweep", matching "Name — from file.wt" for added files.
            // The Source column already shows the slot, so a name that only repeats it
            // ("Wavetable P02") is left out; the Result column says the 3rd Wave's own copy is used.
            if let name = factory.name(ref), name != "Wavetable \(ref.label)" {
                return "Factory table \u{2014} \(name)"
            }
            return "Factory table"
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
            return ReportText.item(item.name, needs)
        }
        let oldTables = items.contains { plan(for: $0).userSlotNote != nil }
        if !missing.isEmpty {
            let ok = items.count - missing.count
            if ok == 0 {
                alertMessage = (items.count == 1 ? "This program can't be packed yet: it needs files that aren't here."
                                                 : "None of these programs can be packed yet: they need files that aren't here.")
                    + "\n\n" + missing.joined(separator: "\n")
                    + (items.count == 1 ? "\n\nAdd the .wt or .bin files it needs." : "\n\nAdd the .wt or .bin files they need.")
                    + (oldTables ? " For wavetables from before 2025, the note with each program explains the choices." : "")
                return
            }
            let n = missing.count
            guard Panels.confirm(
                title: "\(n) of \(items.count) programs can't be packed yet",
                message: "\(n == 1 ? "It needs files that aren't here and" : "They need files that aren't here and") will be left out. Pack the other \(ok == 1 ? "one" : String(ok))?",
                details: missing.joined(separator: "\n"),
                ok: "Pack \(ok)") else { return }
        }
        guard let folder = Panels.chooseFolder(prompt: "Pack Here", message: "Choose where to put the .pgdata files") else { return }
        var outputs: [(name: String, data: Data)] = []
        var planned: [(item: PackItem, plan: PackPlan)] = []     // one per output, in order
        var blocked: [String] = [], failed: [String] = []
        // Prefix each file with its program location (or its position among the files written) so
        // the 3rd Wave's alphabetical bulk import keeps the programs in order.
        let prefixes = OutputNames.orderPrefixes(urls: items.map(\.url))
        let prefixByID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), prefixes))
        for item in items {
            let plan = plan(for: item)
            switch plan.verdict {
            case .blocked:
                blocked.append(ReportText.item(item.name, plan.missingSummary ?? "content missing")); continue
            default: break
            }
            do {
                let content = plan.content(files: contentFiles, names: contentNames)
                let g = try Packer.pack(item.effectiveProgram, content: content)
                outputs.append((name: OutputNames.unified(item.effectiveProgram, prefix: prefixByID[item.id]), data: g.serialized()))
                planned.append((item, plan))
            } catch { failed.append(ReportText.item(item.name, Self.describe(error))) }
        }
        guard let result = Panels.write(outputs, into: folder) else { note("Packing cancelled; nothing written."); return }
        failed += result.failed.map { ReportText.item(splitting: $0) }
        // The report's sections cover the files that were really written.
        var packedPlans: [PackPlan] = []
        var unfamiliar: [String] = [], replaced: [String] = [], converted: [String] = []
        for (i, (item, plan)) in planned.enumerated() where result.writtenIndices.contains(i) {
            packedPlans.append(plan)
            if !plan.warnings.isEmpty { unfamiliar.append(ReportText.item(item.name)) }
            if plan.conversion != nil { converted.append(ReportText.item(item.name)) }
            for r in plan.rows where r.replacesFactory {
                if case .file(let id)? = r.choice, let f = contentFiles.first(where: { $0.id == id }) {
                    replaced.append(ReportText.item(item.name, "\(r.ref.label) uses \(f.url.lastPathComponent) instead of factory \(factory.name(r.ref).map { "\"\($0)\"" } ?? "table")"))
                }
            }
        }
        let written = result.written
        var msg = "Packed \(written) program\(written == 1 ? "" : "s") into \"\(folder.lastPathComponent)\"."
        // Each section: a heading line ending in ":" and one item per line (see ReportText).
        if !blocked.isEmpty { msg += "\n\nNot packed (files missing):\n" + blocked.joined(separator: "\n") }
        if !failed.isEmpty { msg += "\n\nNot packed:\n" + failed.joined(separator: "\n") }
        // When every packed program was converted (a whole older bank), one line says so instead
        // of a list as long as the bank.
        let howConverted = "in the same way the 3rd Wave's \u{201C}Import program\u{201D} function handles older programs"
        if !converted.isEmpty && converted.count == written {
            msg += "\n\n" + (written == 1 ? "The program was" : CountWords.all(written, "programs") + " were") + " converted from an older format, \(howConverted)."
        } else if !converted.isEmpty {
            msg += "\n\nConverted from an older format, \(howConverted):\n" + converted.joined(separator: "\n")
        }
        if !replaced.isEmpty { msg += "\n\nFactory tables replaced by added files (check these are meant):\n" + replaced.joined(separator: "\n") }
        if !unfamiliar.isEmpty { msg += "\n\nPacked, but check these on the 3rd Wave (see each program's notes):\n" + unfamiliar.joined(separator: "\n") }
        // Files none of the packed programs use (other added programs may use them).
        let unused = PackPlan.unusedFiles(contentFiles, plans: packedPlans, factory: factory, programs: "packed")
        if !unused.isEmpty {
            // The reason is given only when it adds to the heading: an assigned file that is still
            // not used, or one identical to the factory table of its slot.
            msg += "\n\nAdded files that no packed program uses (left out):\n" + contentFiles.filter { unused[$0.id] != nil }
                .map { f -> String in
                    let why = unused[f.id]!
                    return why.hasPrefix("Not used by any") ? ReportText.item(f.url.lastPathComponent)
                                                           : ReportText.item(f.url.lastPathComponent, ReportText.lowerFirst(why))
                }.joined(separator: "\n")
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
            unpacks[i].plan = unpacks[i].plan.refreshed(factory: factory, skipFactoryDuplicates: skipFactoryDuplicates)
        }
    }

    func setUnpackItem(_ unpackID: UUID, _ itemID: UUID, write: Bool) {
        guard let i = unpacks.firstIndex(where: { $0.id == unpackID }),
              let j = unpacks[i].plan.items.firstIndex(where: { $0.id == itemID }) else { return }
        unpacks[i].plan.items[j].write = write
    }

    /// Takes an edited file name when the user finishes editing it. The name is cleaned the way
    /// generated ones are ("/" and the like become "_"); an empty one falls back to the generated
    /// name. Returns the name as stored, for the field to show.
    @discardableResult
    func commitUnpackFileName(_ unpackID: UUID, _ itemID: UUID, _ text: String) -> String {
        guard let i = unpacks.firstIndex(where: { $0.id == unpackID }),
              let j = unpacks[i].plan.items.firstIndex(where: { $0.id == itemID }) else { return text }
        let name = text.trimmingCharacters(in: .whitespaces).isEmpty
            ? unpacks[i].plan.items[j].defaultFileName : OutputNames.sanitize(text)
        if unpacks[i].plan.items[j].fileName != name { unpacks[i].plan.items[j].fileName = name }
        return name
    }

    func removeUnpacks(_ ids: Set<UUID>) { unpacks.removeAll { ids.contains($0.id) }; if let s = selectedUnpack, ids.contains(s) { selectedUnpack = unpacks.first?.id } }

    /// Empties the Unpack page after asking. Files are not touched.
    func removeAllUnpacks() {
        let n = unpacks.count
        guard n > 0 else { return }
        let what = "\(n) .pgdata file\(n == 1 ? "" : "s")"
        guard Panels.confirm(title: "Remove everything from the Unpack page?",
                             message: "This removes \(what) from the list, with the files you unchecked and the names you changed. The files themselves are not touched.",
                             ok: "Remove All") else { return }
        unpacks = []; selectedUnpack = nil
        note("Removed \(what) from the Unpack page.")
    }

    func unpack(_ ids: [UUID]) {
        let items = unpacks.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        guard items.contains(where: { $0.plan.items.contains(where: \.write) }) else {
            alertMessage = "No files are checked to write. Check the files to unpack in the Write column."
            return
        }
        guard let folder = Panels.chooseFolder(prompt: "Unpack Here", message: "Choose where to put the unpacked files") else { return }
        // Identical files (same name and content) shared by several programs are written once.
        var files: [(file: UnpackPlan.Item, name: String)] = []
        for item in items {
            for f in item.plan.items where f.write {
                if files.contains(where: { $0.file.fileName == f.fileName && $0.file.data == f.data }) { continue }
                files.append((f, f.fileName))
            }
        }
        // With any wavetables or multisamples, each kind goes in the folder the 3rd Wave's USB drive
        // uses for it, named as the drive shows them when mounted (PROGRAMS, WAVES, AUDIO; checked
        // on Adam's 8M), so the output can be copied onto the drive as it is. Programs alone stay
        // at the top level.
        let foldered = files.contains { $0.file.ref != nil }
        let outputs: [(name: String, data: Data)] = files.map { f in
            guard foldered else { return (f.name, f.file.data) }
            let sub = f.file.ref == nil ? "PROGRAMS" : (f.file.ref!.isSample ? "AUDIO" : "WAVES")
            return (sub + "/" + f.name, f.file.data)
        }
        guard let result = Panels.write(outputs, into: folder) else { note("Unpacking cancelled; nothing written."); return }
        var msg = "Unpacked \(items.count) file\(items.count == 1 ? "" : "s") into \"\(folder.lastPathComponent)\": \(result.written) file\(result.written == 1 ? "" : "s") written."
        if !result.failed.isEmpty { msg += "\n\nNot written:\n" + result.failed.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        note(msg + " (\(folder.path))")
        alertReveal = folder
        alertMessage = msg
    }

    // MARK: Convert

    /// Adds the wavetables in files and folders to the Wavetables page. Folders are searched; files
    /// that cannot hold a wavetable, or hold none, are passed over. Read on a background queue
    /// with progress shown, like `add(urls:)`; the tables are listed on the main thread in one go,
    /// identical ones collapsed into one entry.
    func addToConvert(urls: [URL]) {
        guard !urls.isEmpty else { return }
        batchesReading += 1
        reading = reading ?? LoadProgress(done: 0, total: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (files, ignored) = ConvertPlan.filesToRead(in: urls)
            DispatchQueue.main.async { self?.reading = LoadProgress(done: 0, total: files.count) }
            var collected = ConvertPlan.read(files, progress: { done, total in
                if done % 5 == 0 || done == total {
                    DispatchQueue.main.async { self?.reading = LoadProgress(done: done, total: total) }
                }
            })
            collected.ignored = ignored
            DispatchQueue.main.async { self?.finishAddingToConvert(collected) }
        }
    }

    private func finishAddingToConvert(_ c: ConvertPlan.Collected) {
        batchesReading -= 1
        if batchesReading <= 0 { batchesReading = 0; reading = nil }
        let s = convertPlan.add(c.found, factory: factory)
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if s.added > 0 {
            var msg = "Added \(count(s.added, "wavetable")) to Convert"
            if s.duplicates > 0 { msg += " (and \(s.duplicates) identical cop\(s.duplicates == 1 ? "y" : "ies"), shown with the table they match)" }
            note(msg + ".")
        } else if c.problems.isEmpty {
            // Nothing happened; say why, so a drop that does nothing is not a mystery.
            var why: [String] = []
            if s.duplicates > 0 { why.append("\(s.duplicates) identical to tables already listed") }
            if s.repeated > 0 { why.append("\(s.repeated) already in the list") }
            if c.withoutTables > 0 { why.append("\(count(c.withoutTables, "file")) without a wavetable") }
            if c.ignored > 0 { why.append("\(count(c.ignored, "file")) of other kinds") }
            note("No wavetables added" + (why.isEmpty ? "." : ": " + why.joined(separator: "; ") + "."))
        }
        if !c.problems.isEmpty {
            c.problems.forEach { note("Could not read \($0)") }
            alertMessage = "Some files could not be read.\n\n" + c.problems.prefix(8).map { ReportText.item(splitting: $0) }.joined(separator: "\n")
                + (c.problems.count > 8 ? "\n\n…and \(c.problems.count - 8) more (see the log)." : "")
        }
    }

    func removeConvertItems(_ ids: Set<UUID>) { convertPlan.remove(ids); convertPreviews.removeAll() }

    /// Empties the Wavetables page after asking. Files are not touched.
    func removeAllConvert() {
        let n = convertPlan.items.count
        guard n > 0 else { return }
        let what = "\(n) wavetable\(n == 1 ? "" : "s")"
        guard Panels.confirm(title: "Remove everything from the Wavetables page?",
                             message: "This removes \(what) from the list, with the tables you marked to convert and the frame sizes you chose. The files themselves are not touched.",
                             ok: "Remove All") else { return }
        convertPlan.items = []
        convertPreviews.removeAll()
        note("Removed \(what) from the Wavetables page.")
    }

    /// Converts the tables marked to convert for the chosen destination into a folder the user chooses. With
    /// `sendToPack` (3rd Wave destinations), the .wt files written are then added to the Pack page.
    func convertTables(sendToPack: Bool = false) {
        let plan = convertPlan
        let marked = plan.selectedItems
        guard !marked.isEmpty else {
            alertMessage = "No tables are marked to convert. Check the tables to convert in the Convert column."
            return
        }
        guard marked.contains(where: plan.canConvert) else {
            alertMessage = (marked.count == 1 ? "The table marked to convert can't convert yet: its file doesn't say how long each wave is."
                                              : "None of the tables marked to convert can convert yet: their files don't say how long each wave is.")
                + "\n\nChoose a frame size in the Size column first."
            return
        }
        let toPack = sendToPack && plan.preset.isThirdWave
        guard let folder = Panels.chooseFolder(
            prompt: toPack ? "Convert and Send" : "Convert Here",
            message: toPack ? "Choose where to put the .wt files; they are then added to the Pack page"
                            : "Choose where to put the converted files") else { return }
        let conversion = plan.convert()
        let report = ConvertPlan.write(conversion.files, into: folder)
        let n = report.written.count
        var msg = plan.reportTitle(converted: n, folderName: folder.lastPathComponent)
        // Each section: a heading line ending in ":" and one item per line (see ReportText).
        if !conversion.errors.isEmpty { msg += "\n\nNot converted:\n" + conversion.errors.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !report.failed.isEmpty { msg += "\n\nNot written:\n" + report.failed.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !report.renamed.isEmpty {
            msg += "\n\nAlready in the folder, so written under a new name (nothing was replaced):\n"
                + report.renamed.map { ReportText.item($0) }.joined(separator: "\n")
        }
        // Each distinct note once: "All 74 tables", "12 tables", or the one table it applies to.
        // The log, below, has every table's own lines.
        let grouped = ConvertPlan.groupedNotes(conversion.reports)
        if !grouped.isEmpty {
            msg += "\n\nWhat converting did:\n" + grouped.map { ReportText.item($0.label, $0.text) }.joined(separator: "\n")
        }
        let packFiles = toPack ? ConvertPlan.filesForPack(report.written, preset: plan.preset) : []
        if !packFiles.isEmpty {
            msg += "\n\n" + (packFiles.count == 1 ? "The .wt file is" : "The \(packFiles.count) .wt files are") + " added to the Pack page."
        }
        var logged = msg + " (\(folder.path))"
        let shared = grouped.filter { $0.names.count > 1 }
        if !shared.isEmpty || !conversion.notes.isEmpty {
            logged += "\n\nBy table:\n" + conversion.notes.map { ReportText.item(splitting: $0) }.joined(separator: "\n")
        }
        note(logged)
        alertReveal = folder
        alertMessage = msg
        if !packFiles.isEmpty {
            add(urls: packFiles)
            section = .pack
        }
    }
}

/// The report texts shown in alerts and written to the log: paragraphs separated by a blank line;
/// a paragraph whose first line ends in ":" is a heading for the item lines under it. An item line
/// starts with "• " and may carry an explanation after a tab, which the alert shows in a lighter
/// style and the log joins with a dash.
enum ReportText {
    static func item(_ name: String, _ detail: String? = nil) -> String {
        "• " + name + (detail.map { "\t" + $0 } ?? "")
    }
    /// An item from a "name: explanation" line (a file name or table name, then what happened),
    /// so the name is set apart in the alert. A line without ": " is the whole item.
    static func item(splitting line: String) -> String {
        guard let r = line.range(of: ": ") else { return item(line) }
        return item(String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " — ") }
    /// "Not used: …" → "not used: …" for an explanation that follows a dash; a label such as "U50 …"
    /// is left alone.
    static func lowerFirst(_ s: String) -> String {
        guard let a = s.first, a.isUppercase, s.dropFirst().first?.isLowercase == true else { return s }
        return a.lowercased() + s.dropFirst()
    }
}
