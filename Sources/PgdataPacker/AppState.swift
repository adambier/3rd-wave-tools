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
        /// Whether the page is still under development, so it is shown only when View › Show
        /// Under-Development Features is on (`AppState.showsUnderDevelopmentFeatures`).
        var isUnderDevelopment: Bool { self == .convert }
    }

    private static let underDevelopmentKey = "ShowUnderDevelopmentFeatures"

    /// Whether the pages still under development (the Wavetables page, with Listen and the audio
    /// output in the toolbar) are shown: View › Show Under-Development Features. Off by default;
    /// kept between sessions. Turning it off while such a page is current goes back to Pack.
    @Published var showsUnderDevelopmentFeatures: Bool = UserDefaults.standard.bool(forKey: AppState.underDevelopmentKey) {
        didSet {
            UserDefaults.standard.set(showsUnderDevelopmentFeatures, forKey: Self.underDevelopmentKey)
            if !showsUnderDevelopmentFeatures, section.isUnderDevelopment { section = .pack }
        }
    }

    /// The pages shown, in the toolbar's and the View menu's order.
    var availableSections: [Section] {
        Section.allCases.filter { showsUnderDevelopmentFeatures || !$0.isUnderDevelopment }
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

    /// Opens the "Change what oscillators play" sheet: from a source row (itemID + from), or from a
    /// content file ("Point a program here…", fileID; the program is then chosen in the sheet).
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

    /// Undo for the pages' lists (Edit › Undo and Redo): removing rows, or everything, only takes
    /// them off a page, and undoing puts them back where they were with everything set for them
    /// (names, slots, choices, frame sizes). The window hands this manager out
    /// (`AppDelegate.windowWillReturnUndoManager`), so the standard menu items reach it. The
    /// files themselves are never touched either way.
    let undoManager: UndoManager = {
        let manager = UndoManager()
        // Each removal keeps its rows (a removed wavetable keeps its samples) until undone or
        // dropped; a bound keeps that memory within reason.
        manager.levelsOfUndo = 20
        return manager
    }()

    @Published var section: Section = .pack
    /// Whether the log is open under the status bar (the View menu and the status bar's button
    /// both toggle it).
    @Published var showLog = false
    /// Text typed into the filter field above the program list.
    @Published var programFilter = ""
    /// Show only programs that cannot be packed yet or carry a warning.
    @Published var onlyAttention = false
    /// Files being read in the background: how many of how many so far.
    struct LoadProgress { var done: Int; var total: Int }
    @Published var reading: LoadProgress?
    /// Packing, unpacking, or converting in the background: the verb for the status bar
    /// ("Packing", "Writing", "Converting") and the item being worked on of how many; `total` 0
    /// when the count is not known (the bar then shows no value).
    struct WorkProgress { var verb: String; var done: Int; var total: Int }
    @Published var working: WorkProgress?
    /// Whether a pack, unpack, or conversion is running: the pages' action buttons and the File
    /// menu's commands are disabled meanwhile.
    var isWorking: Bool { working != nil }
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

    // Wavetables
    /// The wavetables added to the Wavetables page, the destination, and its options. The
    /// destination and the frame-count choice are remembered between sessions.
    @Published var convertPlan = ConvertPlan() { didSet { saveSettings() } }
    /// Show only the Wavetables page's tables that can't be converted yet (`ConvertPlan.needsAttention`).
    @Published var convertOnlyAttention = false
    /// The Wavetables page's filter by name (as `programFilter` is the Pack page's).
    @Published var convertFilter = ""
    /// Whether converting to a 3rd Wave destination then adds the .wt files to the Pack page (the
    /// 3rd Wave options' checkbox); kept between sessions.
    @Published var convertAddsToPack: Bool = UserDefaults.standard.bool(forKey: "ConvertAddsToPack") {
        didSet { UserDefaults.standard.set(convertAddsToPack, forKey: "ConvertAddsToPack") }
    }

    /// The Wavetables page's rows as shown: every table, those matching `convertFilter` (by name
    /// or file name), and, with `convertOnlyAttention`, only those that can't be converted yet.
    var convertShownItems: [ConvertPlan.Item] {
        let plan = convertPlan
        let needle = convertFilter.trimmingCharacters(in: .whitespaces)
        let blocked = convertOnlyAttention && plan.blockedCount > 0
        return plan.items.filter { (item: ConvertPlan.Item) -> Bool in
            (!blocked || plan.needsAttention(item))
                && (needle.isEmpty || item.name.localizedCaseInsensitiveContains(needle)
                    || item.location.url.lastPathComponent.localizedCaseInsensitiveContains(needle))
        }
    }
    /// Counts the requests to put the cursor in the Pack page's program name field (Return in
    /// the program list); `ProgramDetail` watches it.
    @Published private(set) var programNameFocusRequest = 0
    func focusProgramName() { programNameFocusRequest += 1 }

    /// The table the Wavetables page should select and scroll to: the first table of each drop
    /// (`finishAddingToConvert`); `ConvertView` watches it.
    @Published private(set) var convertSelectionRequest: UUID?

    /// Whether a drag of files is over the current page; the status bar then says what the page
    /// takes (the pages set it from their drop targets).
    @Published var dragIsOverPage = false

    /// The writer's results for the tables the Wavetables page previews, kept between passes;
    /// computed on a background queue (see `convertPreview(_:)`).
    let convertPreviews = ConvertPreviewCache()
    /// Bumped when a preview asked for has been computed, so the views asking show it.
    @Published private(set) var convertPreviewVersion = 0

    /// The preview of a table for the current destination and options: from the cache, or nil
    /// while it is being computed, in which case the view is updated once it is ready.
    func convertPreview(_ item: ConvertPlan.Item) -> ConvertPreviewCache.Result? {
        _ = convertPreviewVersion   // read, so a view calling this follows the version
        return convertPreviews.result(item, in: convertPlan) { [weak self] in self?.convertPreviewVersion += 1 }
    }

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
        // Settings from versions that asked for the factory .wt files and tracked the 3rd Wave's
        // slots, and from 1.1 builds whose preview pane was dragged to a height.
        for key in ["factoryFolders", "embedFactory", "synthHasAllFactory", "convertPreviewHeight"] { defaults.removeObject(forKey: key) }
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
    /// (P36–P47, U56–U63) that no other added file is assigned to. The user can change it.
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

    func removePrograms(_ ids: Set<UUID>) {
        let removed = programs.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        programs.removeAll { ids.contains($0.id) }
        if let s = selectedProgram, ids.contains(s) { selectedProgram = programs.first?.id }
        let name = "Remove \(removed.count == 1 ? "Program" : "Programs")"
        registerUndo(name) { [weak self] in
            guard let self else { return }
            self.programs = Self.putBack(removed, into: self.programs)
            self.registerUndo(name) { [weak self] in self?.removePrograms(ids) }
        }
    }

    func removeContent(_ id: UUID) { removeContent([id]) }

    /// Removes added wavetable and multisample files from the Pack page (undoable; the files
    /// themselves are not touched).
    func removeContent(_ ids: Set<UUID>) {
        let removed = contentFiles.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        let names = contentNames.filter { ids.contains($0.key) }
        contentFiles.removeAll { ids.contains($0.id) }
        for id in ids { contentNames[id] = nil }
        let name = "Remove \(removed.count == 1 ? "File" : "Files")"
        registerUndo(name) { [weak self] in
            guard let self else { return }
            self.contentFiles = Self.putBack(removed, into: self.contentFiles)
            for (id, newName) in names { self.contentNames[id] = newName }
            self.registerUndo(name) { [weak self] in self?.removeContent(ids) }
        }
    }

    // MARK: Undo

    /// Registers `inverse` under `name` ("Remove Program": the Edit menu reads "Undo Remove
    /// Program"). Called from the action and from its undo alike: the manager files the
    /// registration on the redo stack while it is undoing, and back on the undo stack while it
    /// is redoing, so one call in each direction keeps both stacks right.
    private func registerUndo(_ name: String, _ inverse: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { _ in inverse() }
        undoManager.setActionName(name)
    }

    /// `rows` back into `list` at the indices they had, in order (an index past the end goes at
    /// the end).
    private static func putBack<T>(_ rows: [(offset: Int, element: T)], into list: [T]) -> [T] {
        var out = list
        for row in rows.sorted(by: { $0.offset < $1.offset }) {
            out.insert(row.element, at: min(row.offset, out.count))
        }
        return out
    }

    /// Empties the Pack page, programs and added files alike, after asking. Files are not touched.
    func removeAllPack() {
        let n = programs.count, f = contentFiles.count
        guard n + f > 0 else { return }
        var parts: [String] = []
        if n > 0 { parts.append("\(n) program\(n == 1 ? "" : "s")") }
        if f > 0 { parts.append("\(f) added file\(f == 1 ? "" : "s")") }
        let what = parts.joined(separator: " and ")
        Panels.confirm(title: "Remove everything from the Pack page?",
                       message: "This removes \(what) from the lists, with any slots, choices, and names you set for them. The files themselves are not touched.",
                       ok: "Remove All") { [weak self] (confirmed: Bool) in
            guard confirmed, let self else { return }
            // Rows are put back by index, so rows added after a Remove All survive its undo.
            let programs = Array(self.programs.enumerated()), files = Array(self.contentFiles.enumerated())
            let names = self.contentNames, selected = self.selectedProgram
            self.programs = []; self.contentFiles = []; self.contentNames = [:]; self.selectedProgram = nil
            self.note("Removed \(what) from the Pack page.")
            self.registerUndo("Remove All") { [weak self] in
                guard let self else { return }
                self.programs = Self.putBack(programs, into: self.programs)
                self.contentFiles = Self.putBack(files, into: self.contentFiles)
                self.contentNames.merge(names) { current, _ in current }
                if self.selectedProgram == nil { self.selectedProgram = selected }
                let programIDs = Set(programs.map(\.element.id)), fileIDs = files.map(\.element.id)
                self.registerUndo("Remove All") { [weak self] in
                    guard let self else { return }
                    self.removePrograms(programIDs)
                    for id in fileIDs { self.removeContent(id) }
                }
            }
        }
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

    /// Writes .pgdata files for the given programs into a folder chosen by the user. Asks first
    /// when some of them cannot be packed yet; the packing and writing then run in the background
    /// (see `pack(_:)`).
    func writeUnified(_ ids: [UUID]) {
        guard !isWorking else { return }
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
                alertMessage = (items.count == 1 ? "This program can’t be packed yet: it needs files that aren’t here."
                                                 : "None of these programs can be packed yet: they need files that aren’t here.")
                    + "\n\n" + missing.joined(separator: "\n")
                    + (items.count == 1 ? "\n\nAdd the .wt or .bin files it needs." : "\n\nAdd the .wt or .bin files they need.")
                    + (oldTables ? " For wavetables from before 2025, the note with each program explains the choices." : "")
                return
            }
            let n = missing.count
            Panels.confirm(
                title: "\(n) of \(items.count) programs can’t be packed yet",
                message: "\(n == 1 ? "It needs files that aren’t here and" : "They need files that aren’t here and") will be left out. Pack the other \(ok == 1 ? "one" : String(ok))?",
                details: missing.joined(separator: "\n"),
                ok: "Pack \(ok)") { [weak self] (confirmed: Bool) in
                guard confirmed else { return }
                self?.pack(items)
            }
            return
        }
        pack(items)
    }

    /// Asks for the folder, then packs the programs (those that can be) on a background queue and
    /// writes the files, with progress in the status bar; the report is shown on the main thread.
    /// Everything the packing reads is taken from the page before it starts, so changes made on
    /// the page meanwhile do not reach it.
    private func pack(_ items: [PackItem]) {
        guard !isWorking else { return }
        guard let folder = Panels.chooseFolder(prompt: "Pack Here", message: "Choose where to put the .pgdata files") else { return }
        let plans: [UUID: PackPlan] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, plan(for: $0)) })
        let files = contentFiles, names = contentNames
        // Prefix each file with its program location (or its position among the files written) so
        // the 3rd Wave's alphabetical bulk import keeps the programs in order.
        let prefixes = OutputNames.orderPrefixes(urls: items.map(\.url))
        let prefixByID = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), prefixes))
        working = WorkProgress(verb: "Packing", done: 0, total: items.count)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outputs: [(name: String, data: Data)] = []
            var planned: [(item: PackItem, plan: PackPlan)] = []     // one per output, in order
            var blocked: [String] = [], failed: [String] = []
            for (i, item) in items.enumerated() {
                let current = i + 1
                DispatchQueue.main.async { self?.working = WorkProgress(verb: "Packing", done: current, total: items.count) }
                guard let plan = plans[item.id] else { continue }
                switch plan.verdict {
                case .blocked:
                    blocked.append(ReportText.item(item.name, plan.missingSummary ?? "content missing")); continue
                default: break
                }
                do {
                    let content = plan.content(files: files, names: names)
                    let g = try Packer.pack(item.effectiveProgram, content: content)
                    outputs.append((name: OutputNames.unified(item.effectiveProgram, prefix: prefixByID[item.id]), data: g.serialized()))
                    planned.append((item, plan))
                } catch { failed.append(ReportText.item(item.name, Self.describe(error))) }
            }
            DispatchQueue.main.async {
                self?.writePacked(outputs, planned: planned, blocked: blocked, failed: failed, into: folder, files: files)
            }
        }
    }

    /// Writes the packed programs (asking about files already in the folder) and reports.
    /// `files` are the added files as they were when the programs were packed.
    private func writePacked(_ outputs: [(name: String, data: Data)], planned: [(item: PackItem, plan: PackPlan)],
                             blocked: [String], failed: [String], into folder: URL, files: [ContentFile]) {
        Panels.write(outputs, into: folder, progress: { [weak self] (done: Int, total: Int) in
            self?.working = WorkProgress(verb: "Writing", done: done, total: total)
        }, completion: { [weak self] (result: Panels.WriteResult?) in
            guard let self else { return }
            self.working = nil
            guard let result else { self.note("Packing canceled; nothing written."); return }
            let failed = failed + result.failed.map { ReportText.item(splitting: $0) }
            // The report's sections cover the files that were really written.
            var packedPlans: [PackPlan] = []
            var unfamiliar: [String] = [], replaced: [String] = [], converted: [String] = []
            for (i, (item, plan)) in planned.enumerated() where result.writtenIndices.contains(i) {
                packedPlans.append(plan)
                if !plan.warnings.isEmpty { unfamiliar.append(ReportText.item(item.name)) }
                if plan.conversion != nil { converted.append(ReportText.item(item.name)) }
                for r in plan.rows where r.replacesFactory {
                    if case .file(let id)? = r.choice, let f = files.first(where: { $0.id == id }) {
                        replaced.append(ReportText.item(item.name, "\(r.ref.label) uses \(f.url.lastPathComponent) instead of factory \(self.factory.name(r.ref).map { "\u{201C}\($0)\u{201D}" } ?? "table")"))
                    }
                }
            }
            let written = result.written
            var msg = "Packed \(written) program\(written == 1 ? "" : "s") into \u{201C}\(folder.lastPathComponent)\u{201D}."
            // Each section: a heading line ending in ":" and one item per line (see ReportText).
            if !blocked.isEmpty { msg += "\n\nNot packed (files missing):\n" + blocked.joined(separator: "\n") }
            if !failed.isEmpty { msg += "\n\nNot packed:\n" + failed.joined(separator: "\n") }
            // When every packed program was converted (a whole older bank), one line says so instead
            // of a list as long as the bank.
            let howConverted = "in the same way the 3rd Wave’s \u{201C}Import program\u{201D} function handles older programs"
            if !converted.isEmpty && converted.count == written {
                msg += "\n\n" + (written == 1 ? "The program was" : CountWords.all(written, "programs") + " were") + " converted from an older format, \(howConverted)."
            } else if !converted.isEmpty {
                msg += "\n\nConverted from an older format, \(howConverted):\n" + converted.joined(separator: "\n")
            }
            if !replaced.isEmpty { msg += "\n\nFactory tables replaced by added files (check these are meant):\n" + replaced.joined(separator: "\n") }
            if !unfamiliar.isEmpty { msg += "\n\nPacked, but check these on the 3rd Wave (see each program’s notes):\n" + unfamiliar.joined(separator: "\n") }
            // Files none of the packed programs use (other added programs may use them).
            let unused = PackPlan.unusedFiles(files, plans: packedPlans, factory: self.factory, programs: "packed")
            if !unused.isEmpty {
                // The reason is given only when it adds to the heading: an assigned file that is still
                // not used, or one identical to the factory table of its slot.
                msg += "\n\nAdded files that no packed program uses (left out):\n" + files.filter { unused[$0.id] != nil }
                    .map { (f: ContentFile) -> String in
                        let why = unused[f.id]!
                        return why.hasPrefix("Not used by any") ? ReportText.item(f.url.lastPathComponent)
                                                               : ReportText.item(f.url.lastPathComponent, ReportText.lowerFirst(why))
                    }.joined(separator: "\n")
            }
            self.note(msg + " (\(folder.path))")
            self.alertReveal = folder
            self.alertMessage = msg
        })
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

    /// Keeps an edited file name on the Unpack page: `stem` is the part before the suffix, which
    /// stays the file's own (a `.pro` is written as a `.pro`); it is cleaned the way generated
    /// names are ("/" and the like become "_"), and an empty stem brings the generated name
    /// back. Undoable ("Undo Rename"). Returns the name kept.
    @discardableResult
    func commitUnpackFileName(_ unpackID: UUID, _ itemID: UUID, stem: String) -> String {
        guard let i = unpacks.firstIndex(where: { $0.id == unpackID }),
              let j = unpacks[i].plan.items.firstIndex(where: { $0.id == itemID }) else { return stem }
        let item = unpacks[i].plan.items[j]
        let suffix = Self.suffix(of: item.defaultFileName)
        var trimmed = stem.trimmingCharacters(in: .whitespaces)
        if !suffix.isEmpty, trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)   // typed again: once is enough
        }
        let name = trimmed.isEmpty ? item.defaultFileName : OutputNames.sanitize(trimmed) + suffix
        setUnpackFileName(unpackID, itemID, name)
        return name
    }

    /// ".pro", ".wt", ".bin": the suffix of a generated file name, with its dot; empty without one.
    static func suffix(of fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext
    }

    /// Sets a file name on the Unpack page, undoable.
    private func setUnpackFileName(_ unpackID: UUID, _ itemID: UUID, _ name: String) {
        guard let i = unpacks.firstIndex(where: { $0.id == unpackID }),
              let j = unpacks[i].plan.items.firstIndex(where: { $0.id == itemID }),
              unpacks[i].plan.items[j].fileName != name else { return }
        let before = unpacks[i].plan.items[j].fileName
        unpacks[i].plan.items[j].fileName = name
        registerUndo("Rename") { [weak self] in self?.setUnpackFileName(unpackID, itemID, before) }
    }

    func removeUnpacks(_ ids: Set<UUID>) {
        let removed = unpacks.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        unpacks.removeAll { ids.contains($0.id) }
        if let s = selectedUnpack, ids.contains(s) { selectedUnpack = unpacks.first?.id }
        let name = "Remove \(removed.count == 1 ? "File" : "Files")"
        registerUndo(name) { [weak self] in
            guard let self else { return }
            self.unpacks = Self.putBack(removed, into: self.unpacks)
            self.registerUndo(name) { [weak self] in self?.removeUnpacks(ids) }
        }
    }

    /// Empties the Unpack page after asking. Files are not touched.
    func removeAllUnpacks() {
        let n = unpacks.count
        guard n > 0 else { return }
        let what = "\(n) .pgdata file\(n == 1 ? "" : "s")"
        Panels.confirm(title: "Remove everything from the Unpack page?",
                       message: "This removes \(what) from the list, with the files you unchecked and the names you changed. The files themselves are not touched.",
                       ok: "Remove All") { [weak self] (confirmed: Bool) in
            guard confirmed, let self else { return }
            let unpacks = Array(self.unpacks.enumerated()), selected = self.selectedUnpack
            self.unpacks = []; self.selectedUnpack = nil
            self.note("Removed \(what) from the Unpack page.")
            self.registerUndo("Remove All") { [weak self] in
                guard let self else { return }
                self.unpacks = Self.putBack(unpacks, into: self.unpacks)
                if self.selectedUnpack == nil { self.selectedUnpack = selected }
                self.registerUndo("Remove All") { [weak self] in self?.removeUnpacks(Set(unpacks.map(\.element.id))) }
            }
        }
    }

    /// Writes the checked files of the given .pgdata files into a folder chosen by the user, on a
    /// background queue with progress in the status bar; the report is shown on the main thread.
    func unpack(_ ids: [UUID]) {
        guard !isWorking else { return }
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
        let count = items.count
        working = WorkProgress(verb: "Writing", done: 0, total: outputs.count)
        Panels.write(outputs, into: folder, progress: { [weak self] (done: Int, total: Int) in
            self?.working = WorkProgress(verb: "Writing", done: done, total: total)
        }, completion: { [weak self] (result: Panels.WriteResult?) in
            guard let self else { return }
            self.working = nil
            guard let result else { self.note("Unpacking canceled; nothing written."); return }
            var msg = "Unpacked \(count) file\(count == 1 ? "" : "s") into \u{201C}\(folder.lastPathComponent)\u{201D}: \(result.written) file\(result.written == 1 ? "" : "s") written."
            if !result.failed.isEmpty { msg += "\n\nNot written:\n" + result.failed.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
            self.note(msg + " (\(folder.path))")
            self.alertReveal = folder
            self.alertMessage = msg
        })
    }

    // MARK: Wavetables

    /// Adds the wavetables in files and folders to the Wavetables page. Folders are searched; files
    /// that cannot hold a wavetable, or hold none, are passed over. Read on a background queue
    /// with progress shown, like `add(urls:)`; the tables are listed on the main thread in one go,
    /// identical ones collapsed into one entry.
    func addToConvert(urls: [URL]) {
        guard !urls.isEmpty else { return }
        batchesReading += 1
        reading = reading ?? LoadProgress(done: 0, total: 0)
        let factory = self.factory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (files, ignored) = ConvertPlan.filesToRead(in: urls)
            DispatchQueue.main.async { self?.reading = LoadProgress(done: 0, total: files.count) }
            var collected = ConvertPlan.read(files, progress: { done, total in
                if done % 5 == 0 || done == total {
                    DispatchQueue.main.async { self?.reading = LoadProgress(done: done, total: total) }
                }
            })
            collected.ignored = ignored
            // The hashing, peak, factory match, and frame-size verdict of each table are done
            // here, off the main thread; the list only checks them in.
            let prepared = collected.found.map { ConvertPlan.Prepared($0, factory: factory) }
            DispatchQueue.main.async { self?.finishAddingToConvert(collected, prepared) }
        }
    }

    private func finishAddingToConvert(_ c: ConvertPlan.Collected, _ prepared: [ConvertPlan.Prepared]) {
        batchesReading -= 1
        if batchesReading <= 0 { batchesReading = 0; reading = nil }
        let before = Set(convertPlan.items.map(\.id))
        let s = convertPlan.add(prepared)
        // The first table added is selected, so the preview shows what the drop brought.
        if let first = convertPlan.items.first(where: { !before.contains($0.id) }) { convertSelectionRequest = first.id }
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if s.added > 0 {
            var msg = "Added \(count(s.added, "wavetable"))"
            if s.duplicates > 0 {
                msg += s.duplicates == 1 ? " (and 1 identical copy, shown with the table it matches)"
                                         : " (and \(s.duplicates) identical copies, shown with the tables they match)"
            }
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

    /// Gives a table on the Wavetables page a new name, which goes on the converted file (the
    /// source file is not changed); the file's own name clears it. Undoable ("Undo Rename").
    func renameConvertItem(_ id: UUID, to name: String) {
        guard let i = convertPlan.items.firstIndex(where: { $0.id == id }) else { return }
        let before = convertPlan.items[i].newName
        convertPlan.rename(id, to: name)
        guard convertPlan.items[i].newName != before else { return }
        registerUndo("Rename") { [weak self] in
            guard let self, let j = self.convertPlan.items.firstIndex(where: { $0.id == id }) else { return }
            let undone = self.convertPlan.items[j].newName
            self.convertPlan.items[j].newName = before
            self.registerUndo("Rename") { [weak self] in
                guard let self, let k = self.convertPlan.items.firstIndex(where: { $0.id == id }) else { return }
                self.renameConvertItem(id, to: undone ?? self.convertPlan.items[k].table.name)
            }
        }
    }

    func removeConvertItems(_ ids: Set<UUID>) {
        let removed = convertPlan.items.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        convertPlan.remove(ids)
        convertPreviews.remove(ids)
        let name = "Remove \(removed.count == 1 ? "Table" : "Tables")"
        registerUndo(name) { [weak self] in
            guard let self else { return }
            self.convertPlan.items = Self.putBack(removed, into: self.convertPlan.items)
            self.registerUndo(name) { [weak self] in self?.removeConvertItems(ids) }
        }
    }

    /// Empties the Wavetables page after asking. Files are not touched.
    func removeAllConvert() {
        let n = convertPlan.items.count
        guard n > 0 else { return }
        let what = "\(n) table\(n == 1 ? "" : "s")"
        Panels.confirm(title: "Remove everything from the Wavetables page?",
                       message: "This removes \(what) from the list, with the names and frame sizes you chose. The files themselves are not touched.",
                       ok: "Remove All") { [weak self] (confirmed: Bool) in
            guard confirmed, let self else { return }
            let items = Array(self.convertPlan.items.enumerated())
            self.convertPlan.items = []
            self.convertPreviews.removeAll()
            self.registerUndo("Remove All") { [weak self] in
                guard let self else { return }
                self.convertPlan.items = Self.putBack(items, into: self.convertPlan.items)
                self.registerUndo("Remove All") { [weak self] in self?.removeConvertItems(Set(items.map(\.element.id))) }
            }
            self.note("Removed \(what) from the Wavetables page.")
        }
    }

    /// Converts tables for the chosen destination into a folder the user chooses: the tables
    /// with the given ids (Convert Selected…), or, with nil, every table Convert All takes
    /// (`ConvertPlan.includedItems`). For a 3rd Wave destination with `convertAddsToPack` on,
    /// the .wt files written are then added to the Pack page. The converting and writing run on
    /// a background queue, with progress in the status bar; the report comes up at the end.
    func convertTables(_ ids: Set<UUID>? = nil) {
        guard !isWorking else { return }
        let plan = convertPlan
        let chosen = ids.map { (wanted: Set<UUID>) in plan.items.filter { wanted.contains($0.id) } } ?? plan.includedItems
        let what = ids == nil ? "to convert" : "selected"
        guard !chosen.isEmpty else {
            alertMessage = ids == nil ? "No tables to convert." : "No tables are selected."
            return
        }
        guard chosen.contains(where: plan.canConvert) else {
            alertMessage = (chosen.count == 1 ? "The table \(what) can’t be converted yet: a frame size could not be estimated from its file."
                                              : "None of the tables \(what) can be converted yet: frame sizes could not be estimated from their files.")
                + "\n\nChoose a frame size in the Input column first."
            return
        }
        let toPack = convertAddsToPack && plan.preset.isThirdWave
        guard let folder = Panels.chooseFolder(
            prompt: "Convert Here",
            message: toPack ? "Choose where to put the .wt files; they are then added to the Pack page"
                            : "Choose where to put the converted files") else { return }
        let total = chosen.filter(plan.canConvert).count
        working = WorkProgress(verb: "Converting", done: 0, total: total)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The plan converts each table through this writer; it counts them for the status bar.
            var current = 0
            let conversion = plan.convert(ids) { (table: Wavetable, preset: OutputPreset, options: OutputOptions) throws -> OutputFile in
                current += 1
                let n = current
                DispatchQueue.main.async { self?.working = WorkProgress(verb: "Converting", done: n, total: total) }
                return try WavetableWriter.write(table, preset: preset, options: options)
            }
            // The files are written without a count (ConvertPlan.write reports at the end).
            DispatchQueue.main.async { self?.working = WorkProgress(verb: "Writing", done: 0, total: 0) }
            let written = ConvertPlan.write(conversion.files, into: folder)
            let packFiles = toPack ? ConvertPlan.filesForPack(written.written, preset: plan.preset) : []
            // The texts are assembled in PgdataPackerCore (ConvertReport); ReportText, which they and
            // the Pack and Unpack reports use, lives there too.
            let report = ConvertReport(plan: plan, conversion: conversion, written: written, folder: folder, packFiles: packFiles)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = nil
                self.note(report.log)
                self.alertReveal = folder
                self.alertMessage = report.message
                if !packFiles.isEmpty {
                    self.add(urls: packFiles)
                    self.section = .pack
                }
            }
        }
    }
}
