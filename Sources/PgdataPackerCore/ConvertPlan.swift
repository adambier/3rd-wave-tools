import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the app's single-module swiftc build
#endif
#if canImport(WavetableFormats)
import WavetableFormats
#endif

// The Convert tab's decisions, kept free of UI code like the rest of PgdataPackerCore: which files
// to read, how the wavetables found in them are listed (duplicates collapsed, factory tables
// flagged, frame sizes the files leave open), what each conversion is expected to produce, and how
// the converted files are named and written.
//
// Convert converts existing wavetables between formats. It does not make wavetables from other
// audio: that is the 3rd Wave's Wave Maker.

/// The wavetables added to the Convert tab, the destination chosen for them, and the conversion.
public struct ConvertPlan: Equatable {

    // MARK: Types

    /// Where a table was found: the file, and a label for display ("Pad.wav", "U56 in Set.pgdata").
    public struct Location: Equatable {
        /// The file the table was read from.
        public var url: URL
        /// The file name, or the slot and the file name for a table in a `.pgdata`.
        public var label: String
        /// Creates a location.
        public init(url: URL, label: String) { self.url = url; self.label = label }
    }

    /// A table read from a file, before duplicates are collapsed.
    public struct Found: Equatable {
        /// The file it was read from.
        public var url: URL
        /// What the reader found.
        public var table: FoundTable
        /// Creates a found table.
        public init(url: URL, table: FoundTable) { self.url = url; self.table = table }
    }

    /// What reading a set of dropped files and folders produced.
    public struct Collected: Equatable {
        /// Every table found, in file order.
        public var found: [Found]
        /// Files that could not be read, as "name: reason".
        public var problems: [String]
        /// Files read that hold no wavetable (a program, a multisample, ordinary audio).
        public var withoutTables: Int
        /// Files left out by name (not a kind of file that can hold a wavetable).
        public var ignored: Int
        /// Creates a result.
        public init(found: [Found] = [], problems: [String] = [], withoutTables: Int = 0, ignored: Int = 0) {
            self.found = found; self.problems = problems; self.withoutTables = withoutTables; self.ignored = ignored
        }
    }

    /// One wavetable in the list: a found table, with any identical copies collapsed into it.
    public struct Item: Identifiable, Equatable {
        /// Identity in the list.
        public let id: UUID
        /// The table as the reader found it (the first copy).
        public var table: FoundTable
        /// Where the first copy was found.
        public var location: Location
        /// Where identical copies were found ("also in …"), in the order they were added.
        public var alsoIn: [Location] = []
        /// What kind of source it is, for display ("Serum-style WAV", "3rd Wave U table (.wt)",
        /// "U56 in Set.pgdata", "Surge .wt").
        public var sourceDescription: String
        /// The 3rd Wave factory slot whose table this is, for a table from a 3rd Wave file.
        public var factorySlot: SourceRef?
        /// That factory table's name, when the library has one that does more than repeat the slot.
        public var factoryName: String?
        /// The frame size the user chose from the sizes the file's length allows: needed when the
        /// file leaves the size open (`table.frameSize` is nil), and possible when only its length
        /// suggested one.
        public var chosenFrameSize: Int?
        /// The user's tick; nil follows the destination's default (see `ConvertPlan.isSelected`).
        public var userSelection: Bool?
        /// A new name from Clean Up Names (nil: the name the file gives).
        public var newName: String?
        /// The largest absolute sample, computed once when the table is added (the views ask for
        /// it on every pass).
        public let peak: Float
        /// Content identity for collapsing duplicates.
        let contentKey: ContentKey

        /// The name it is converted under: the new name from Clean Up Names, or the file's.
        public var name: String { newName ?? table.name }
        /// The frame size used: the user's choice, or else the file's.
        public var frameSize: Int? { chosenFrameSize ?? table.frameSize }
        /// The sizes the user can choose from: the file's own (when it gives one) and the other
        /// sizes its length allows. Empty when the file settles the size by metadata or name.
        public var frameSizeChoices: [Int] {
            guard !table.candidateFrameSizes.isEmpty else { return [] }
            return (table.frameSize.map { [$0] } ?? []) + table.candidateFrameSizes.filter { $0 != table.frameSize }
        }
        /// Whether the file leaves the frame size open, so the user must choose one.
        public var needsFrameSize: Bool { table.frameSize == nil }
        /// Frames at the frame size used; nil when no size is known or the samples do not divide.
        public var frameCount: Int? {
            guard let n = frameSize, n > 0, !table.samples.isEmpty, table.samples.count % n == 0 else { return nil }
            return table.samples.count / n
        }
        /// Frames × samples ("64 × 1,024"), or what is missing ("Choose a frame size", "Can't
        /// split into frames").
        public var sizeDescription: String {
            if let n = frameSize, let c = frameCount { return "\(c) × \(ConvertPlan.formatCount(n))" }
            if frameSize != nil { return "Can't split into frames" }
            return "Choose a frame size"
        }
        /// Whether the frame size rests on the file's length alone (an assumption the user may
        /// want to change), with no choice made.
        public var isGuessed: Bool { chosenFrameSize == nil && !needsFrameSize && table.frameSizeEvidence == .length }
        /// What the frame size used rests on.
        public var sizeSource: SizeSource {
            if chosenFrameSize != nil { return .yourChoice }
            if needsFrameSize { return .notStated }
            switch table.frameSizeEvidence {
            case .statedInFile: return .inFile
            case .fileName: return .fileName
            case .sidecar: return .sidecar
            case .markers: return .markers
            case .length: return .guessed
            case .none: return .notStated
            }
        }
        /// How the frame size was decided, as a sentence or two for the user. The reader's own
        /// phrase (`FoundTable.frameSizeBasis`, a noun phrase such as "Serum-style tag inside the
        /// file (clm chunk)") is used where it says what settled the size.
        public var basisDescription: String {
            let file = ConvertPlan.capitalized(table.frameSizeBasis)
            switch sizeSource {
            case .inFile, .fileName, .sidecar: return file + "."
            case .markers: return file + "; less certain than a frame size the file states."
            case .guessed:
                return "Nothing in the file says, so the usual \(ConvertPlan.formatCount(table.frameSize ?? 2048)) is assumed. If it sounds wrong, pick another size."
            case .notStated:
                return "The file doesn't say how long each wave is."
                    + (table.candidateFrameSizes.isEmpty ? " Its length allows none of the usual sizes."
                                                          : " Its length allows " + ConvertPlan.candidateList(table) + ".")
            case .yourChoice:
                if let suggested = table.frameSize {
                    return "Your choice; the file's length suggested \(ConvertPlan.formatCount(suggested))."
                }
                return "Your choice; the file doesn't say."
            }
        }
        /// The interpolation the source asks for: None (stepped), Crossfade, Spectral, or Not stated.
        public var interpolationDescription: String { Interpolation.displayName(table.interpolation) }
        /// "factory table U07 Knob Grotto 6" for a 3rd Wave factory table; nil otherwise.
        public var factoryLabel: String? {
            guard let slot = factorySlot else { return nil }
            return "factory table " + slot.label + (factoryName.map { " " + $0 } ?? "")
        }
        /// "also in A.wav and U56 in Set.pgdata"; nil without duplicates.
        public var alsoInDescription: String? {
            alsoIn.isEmpty ? nil : "also in " + ConvertPlan.listPhrase(alsoIn.map(\.label))
        }
    }

    /// What an item's frame size rests on, as the Size from column shows it.
    public enum SizeSource: String, Equatable, CaseIterable {
        /// Stated in the file's contents (a `clm ` chunk, a Surge header, a 3rd Wave layout).
        case inFile
        /// A Tonverk `_wt<N>` tag in the file name.
        case fileName
        /// A Serum `.txt` file beside the WAV.
        case sidecar
        /// Loop or cue markers, which ordinary samples carry too.
        case markers
        /// The file's length alone: 2,048 assumed.
        case guessed
        /// Nothing says: the user must choose.
        case notStated
        /// The user chose a size.
        case yourChoice

        /// A word or two for the column ("In file", "Guessed", "Your choice").
        public var label: String {
            switch self {
            case .inFile: return "In file"
            case .fileName: return "File name"
            case .sidecar: return "Serum .txt"
            case .markers: return "Markers"
            case .guessed: return "Guessed"
            case .notStated: return "Not stated"
            case .yourChoice: return "Your choice"
            }
        }
    }

    /// Whether an item will convert, and if not, why.
    public enum Status: Equatable {
        /// Ticked, with a frame size that divides the samples into frames.
        case ready
        /// Ticked, but the file leaves the frame size open and none has been chosen.
        case needsFrameSize
        /// Ticked, but the samples do not divide into frames of the size given.
        case cannotSplit
        /// Not ticked: left out of the conversion.
        case unticked

        /// Whether the item is ticked but cannot convert.
        public var isBlocked: Bool { self == .needsFrameSize || self == .cannotSplit }
    }

    /// Notes for an item, by severity.
    public struct ItemNotes: Equatable {
        /// Things that may change the sound or that the user should check (over full scale,
        /// metadata that disagrees, samples left out, a frame size still to choose).
        public var warnings: [String]
        /// Everything else worth knowing.
        public var information: [String]
        /// Whether there is anything to show.
        public var isEmpty: Bool { warnings.isEmpty && information.isEmpty }
        /// Warnings first, then information.
        public var all: [String] { warnings + information }
    }

    /// What converting an item is expected to produce, from the preset's facts and the options;
    /// the writer's own notes, after converting, say what was done.
    public struct ExpectedResult: Equatable {
        /// Samples per frame in the source.
        public var frameSizeIn: Int
        /// Samples per frame written.
        public var frameSizeOut: Int
        /// Frames in the source.
        public var frameCountIn: Int
        /// Frames written (with the PPG waves, the 60 the table goes into plus the 4 waves).
        public var frameCountOut: Int
        /// How the frame count is changed, when it is.
        public var countPolicy: FrameCountPolicy
        /// Whether the PPG's four standard waves are added at 60–63.
        public var addsPPGWaves: Bool
        /// The source's peak; above 1, the writer turns the table down for destinations that
        /// cannot hold it (`scaledToFit`).
        public var peak: Float
        /// Whether the table is turned down to fit (3rd Wave and 16-bit destinations).
        public var scaledToFit: Bool
        /// The interpolation as the file will record it; nil when the format cannot
        /// record it.
        public var interpolationRecorded: Interpolation?

        /// Whether the frame size changes.
        public var resizes: Bool { frameSizeIn != frameSizeOut }
        /// Whether the frame size grows (nil when it does not change).
        public var frameSizeGrows: Bool? { resizes ? frameSizeOut > frameSizeIn : nil }
        /// The frames the table itself goes into (60 with the PPG waves, else `frameCountOut`).
        public var tableFrameCount: Int { addsPPGWaves ? frameCountOut - 4 : frameCountOut }
        /// Whether the table's frame count changes.
        public var changesCount: Bool { tableFrameCount != frameCountIn }
        /// Whether the table gets more frames (nil when the count does not change).
        public var frameCountGrows: Bool? { changesCount ? tableFrameCount > frameCountIn : nil }
        /// Whether the source's peak is above 1 but kept (32-bit destinations).
        public var peakKept: Bool { peak > 1 && !scaledToFit }
    }

    /// Content identity: frame size, sample count, and an FNV-1a hash of the samples' bits.
    struct ContentKey: Hashable {
        var frameSize: Int?
        var count: Int
        var hash: UInt64
        init(_ t: FoundTable) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(t.samples.count * 4)
            for s in t.samples { let b = s.bitPattern; for k in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: b >> (8 * k))) } }
            frameSize = t.frameSize; count = t.samples.count; hash = fnv1a64(bytes)
        }
    }

    /// What adding found tables did.
    public struct AddSummary: Equatable {
        /// New items in the list.
        public var added: Int
        /// Tables identical to one already listed, recorded under it ("also in …").
        public var duplicates: Int
        /// Tables from a file and slot already listed (the same file added again), left out.
        public var repeated: Int
    }

    /// What converting one table did: its name and the writer's notes for it.
    public struct ItemReport: Equatable {
        /// The table's name (the name it was converted under).
        public var name: String
        /// The writer's notes, in order; empty when nothing but the format changed.
        public var notes: [String]
        /// Creates a report.
        public init(name: String, notes: [String]) { self.name = name; self.notes = notes }
    }

    /// A writer's note with the tables it applies to, for a report that says each thing once.
    public struct GroupedNote: Equatable {
        /// The note.
        public var text: String
        /// The tables it applies to, in list order.
        public var names: [String]
        /// How many tables were converted in all.
        public var total: Int
        /// Creates a grouped note.
        public init(text: String, names: [String], total: Int) { self.text = text; self.names = names; self.total = total }
        /// Whether every converted table has the note.
        public var isUniversal: Bool { names.count == total && total > 0 }
        /// "All 74 tables", "12 tables", or the one table's name.
        public var label: String {
            if names.count == 1 { return names[0] }
            if isUniversal { return "All \(total) tables" }
            return "\(names.count) tables"
        }
    }

    /// What a conversion produced, before anything is written.
    public struct Conversion: Equatable {
        /// The converted files, with unique names (see `uniqueNames`).
        public var files: [OutputFile]
        /// The item each file came from, in the same order.
        public var itemIDs: [UUID]
        /// What converting each table did, one report per file, in the same order.
        public var reports: [ItemReport]
        /// Tables that could not be converted, as "Name: reason".
        public var errors: [String]

        /// Every note as "Name: note", in order (for the log).
        public var notes: [String] {
            reports.flatMap { (r: ItemReport) -> [String] in r.notes.map { r.name + ": " + $0 } }
        }
    }

    /// What writing converted files into a folder did.
    public struct WriteReport: Equatable {
        /// The files written, in order.
        public var written: [URL]
        /// Files whose name was taken in the folder, written under a new name ("old → new").
        public var renamed: [String]
        /// Files that could not be written, as "path: reason".
        public var failed: [String]
    }

    // MARK: State

    /// The tables listed, in the order added.
    public var items: [Item] = []
    /// The destination.
    public var preset: OutputPreset
    /// The choices that apply to the conversion.
    public var options: OutputOptions

    /// An empty plan for a destination.
    public init(preset: OutputPreset = .thirdWaveU, options: OutputOptions = OutputOptions()) {
        self.preset = preset; self.options = options
    }

    // MARK: Collecting input

    /// The files to read among dropped files and folders: folders are searched recursively
    /// (hidden files and the insides of packages are skipped); files are kept when `mayContain`
    /// accepts their name. A file given directly is kept even if hidden. Sorted by path.
    public static func filesToRead(in urls: [URL],
                                   mayContain: (String) -> Bool = WavetableReader.mayContainWavetables(fileName:))
        -> (files: [URL], ignored: Int) {
        let fm = FileManager.default
        var all: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { all.append(u); continue }
            guard isDir.boolValue else { all.append(u); continue }
            guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in e {
                // Hidden files and folders are skipped by name too, for a Foundation whose
                // enumerator does not honour .skipsHiddenFiles.
                if f.lastPathComponent.hasPrefix(".") { e.skipDescendants(); continue }
                if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                all.append(f)
            }
        }
        var seen = Set<String>()
        let wanted = all.filter { mayContain($0.lastPathComponent) && seen.insert($0.standardizedFileURL.path).inserted }
        return (wanted.sorted { $0.path < $1.path }, all.count - wanted.count)
    }

    /// Reads files with `reader`, collecting each file's problem rather than stopping.
    /// `progress` is called after each file with (done, total).
    public static func read(_ files: [URL],
                            reader: (URL) throws -> [FoundTable] = WavetableReader.read(url:),
                            progress: (Int, Int) -> Void = { _, _ in }) -> Collected {
        var out = Collected()
        for (i, u) in files.enumerated() {
            do {
                let tables = try reader(u)
                if tables.isEmpty { out.withoutTables += 1 }
                out.found += tables.map { Found(url: u, table: $0) }
            } catch {
                out.problems.append("\(u.lastPathComponent): \(describe(error))")
            }
            progress(i + 1, files.count)
        }
        return out
    }

    /// `filesToRead` and `read` together.
    public static func collect(urls: [URL],
                               mayContain: (String) -> Bool = WavetableReader.mayContainWavetables(fileName:),
                               reader: (URL) throws -> [FoundTable] = WavetableReader.read(url:),
                               progress: (Int, Int) -> Void = { _, _ in }) -> Collected {
        let (files, ignored) = filesToRead(in: urls, mayContain: mayContain)
        var c = read(files, reader: reader, progress: progress)
        c.ignored = ignored
        return c
    }

    /// An error as a sentence for the user.
    public static func describe(_ error: Error) -> String {
        if let e = error as? WavetableError { return e.description }
        if let e = error as? FormatError { return e.description }
        return error.localizedDescription
    }

    // MARK: Items

    /// Adds found tables to the list. A table whose content (samples and frame size) matches one
    /// already listed is recorded under it ("also in …") rather than listed again; a table from a
    /// file and slot already listed is left out. Tables from 3rd Wave files are checked against
    /// the factory library.
    @discardableResult
    public mutating func add(_ found: [Found], factory: FactoryLibrary = .builtIn) -> AddSummary {
        var s = AddSummary(added: 0, duplicates: 0, repeated: 0)
        for f in found {
            let t = f.table
            let location = Location(url: f.url, label: Self.locationLabel(t, url: f.url))
            let key = ContentKey(t)
            if let i = items.firstIndex(where: { $0.contentKey == key && $0.table.samples == t.samples }) {
                if items[i].location == location || items[i].alsoIn.contains(location) { s.repeated += 1; continue }
                items[i].alsoIn.append(location); s.duplicates += 1
                continue
            }
            var slot: SourceRef?
            var factoryName: String?
            if let fp = t.thirdWaveFingerprint, let ref = factory.slot(withFingerprint: fp) {
                slot = ref
                // The factory P00–P33 tables are named "Wavetable P00" …: a name that only repeats the slot is left out.
                factoryName = factory.name(ref).flatMap { $0 == "Wavetable \(ref.label)" ? nil : $0 }
            }
            items.append(Item(id: UUID(), table: t, location: location, sourceDescription: Self.sourceDescription(t),
                              factorySlot: slot, factoryName: factoryName, peak: t.peak, contentKey: key))
            s.added += 1
        }
        return s
    }

    /// Removes items from the list.
    public mutating func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    /// Whether an item is ticked by default for the current destination: everything except the
    /// 3rd Wave's factory tables when the destination is the 3rd Wave, which already has them.
    public func defaultSelection(_ item: Item) -> Bool { !(preset.isThirdWave && item.factorySlot != nil) }

    /// Whether an item is ticked: the user's choice, or the default.
    public func isSelected(_ item: Item) -> Bool { item.userSelection ?? defaultSelection(item) }

    /// Ticks or unticks an item.
    public mutating func setSelected(_ id: UUID, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].userSelection = on
    }

    /// The ticked items, in list order.
    public var selectedItems: [Item] { items.filter(isSelected) }

    /// Sets the frame size for an item, from its `frameSizeChoices`; nil, or the file's own size,
    /// clears the choice. Other sizes are ignored.
    public mutating func chooseFrameSize(_ id: UUID, _ size: Int?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let size, !items[i].frameSizeChoices.contains(size) { return }
        items[i].chosenFrameSize = size == items[i].table.frameSize ? nil : size
    }

    /// Notes for an item, warnings first: the reader's, and what the destination means for it.
    public func notes(for item: Item) -> [String] { itemNotes(for: item).all }

    /// Notes for an item by severity. The reader's note about samples over full scale is replaced
    /// by one built from the item's peak (so the wording is the same whichever reader found it),
    /// and the reader's notes about disagreeing metadata or samples left out count as warnings.
    public func itemNotes(for item: Item) -> ItemNotes {
        var warnings: [String] = [], information: [String] = []
        for note in item.table.notes {
            if Self.isPeakNote(note) { continue }
            if Self.isWarningNote(note) { warnings.append(note) } else { information.append(note) }
        }
        if item.peak > 1 {
            warnings.insert("Peak \(Self.decimal(item.peak)): over full scale (±1).", at: 0)
        }
        if let slot = item.factorySlot {
            let label = "factory " + slot.label + (item.factoryName.map { " " + $0 } ?? "")
            information.append(preset.isThirdWave
                ? "Same as \(label); every 3rd Wave has it, so it starts unticked."
                : "Same as \(label).")
        }
        return ItemNotes(warnings: warnings, information: information)
    }

    /// Whether a reader's note is about samples over full scale (replaced by the plan's own).
    static func isPeakNote(_ note: String) -> Bool {
        note.contains("beyond ±1") || note.contains("over full scale")
    }

    /// Whether a reader's note is a warning: metadata that disagrees, samples left out, channels
    /// dropped, or a damaged file.
    static func isWarningNote(_ note: String) -> Bool {
        for mark in ["is used.", "left out", "not used", "cut short", "only the left", "does not divide", "more than the"] {
            if note.contains(mark) { return true }
        }
        return false
    }

    /// Whether an item can be converted: its frame size is known and its samples divide into frames.
    public func canConvert(_ item: Item) -> Bool { item.frameCount != nil }

    /// Whether an item converts, and if not, why.
    public func status(_ item: Item) -> Status {
        guard isSelected(item) else { return .unticked }
        if item.frameSize == nil { return .needsFrameSize }
        return item.frameCount == nil ? .cannotSplit : .ready
    }

    /// The item's status as a sentence or two: what blocks it and what to do, or that it is
    /// ready, or that it is not ticked.
    public func statusDescription(_ item: Item) -> String {
        switch status(item) {
        case .ready: return "Ready to convert."
        case .unticked: return "Not ticked: left out of the conversion."
        case .needsFrameSize:
            return "Choose a frame size: the file doesn't say how long each wave is."
                + (item.table.candidateFrameSizes.isEmpty ? " Its length allows none of the usual sizes."
                                                           : " Its length allows \(Self.candidateList(item.table)).")
        case .cannotSplit:
            return "Can't split into frames: \(Self.formatCount(item.table.samples.count)) samples don't divide into frames of \(Self.formatCount(item.frameSize ?? 0))."
        }
    }

    /// Whether a ticked item needs a look: it is blocked, its frame size is guessed from the
    /// file's length, or it carries a warning.
    public func needsAttention(_ item: Item) -> Bool {
        let s = status(item)
        guard s != .unticked else { return false }
        return s.isBlocked || item.isGuessed || !itemNotes(for: item).warnings.isEmpty
    }

    /// The ticked items that need a look (see `needsAttention`).
    public var attentionCount: Int { items.filter(needsAttention).count }

    /// The ticked items that still need a frame size.
    public var needsFrameSizeCount: Int { items.filter { status($0) == .needsFrameSize }.count }

    /// The ticked items whose samples do not divide into frames.
    public var cannotSplitCount: Int { items.filter { status($0) == .cannotSplit }.count }

    /// The ticked items that cannot convert, for either reason.
    public var blockedCount: Int { items.filter { status($0).isBlocked }.count }

    /// The ticked items whose frame count the destination changes.
    public var frameCountChangeCount: Int {
        selectedItems.filter { expected(for: $0)?.changesCount == true }.count
    }

    /// The line under the destination list: that nothing has been tested yet, or which
    /// destinations have been, from each preset's `testedIn`.
    public static var testingFootnote: String {
        let tested = OutputPreset.allCases.filter { !$0.testedIn.isEmpty }
        if tested.isEmpty {
            return "Not yet tested in these synths. Hover a row for its sources."
        }
        if tested.count == OutputPreset.allCases.count {
            return "Every destination has been tested in its synth. Hover a row for details."
        }
        return "Tested: " + listPhrase(tested.map(\.shortTitle)) + ". Hover a row for its sources."
    }

    /// The report's first line: "Converted 74 tables for Phase Plant into “output”." (the
    /// destination's own notes say the sizes, so the title does not).
    public func reportTitle(converted n: Int, folderName: String) -> String {
        let to = preset.isThirdWave ? "to \(preset.title)s" : "for \(preset.title)"
        return "Converted \(n) table\(n == 1 ? "" : "s") \(to) into \u{201C}\(folderName)\u{201D}."
    }

    // MARK: Destination

    /// The frame size the destination writes for a source frame size.
    public func destinationFrameSize(source: Int) -> Int {
        if preset == .tonverk {
            if let n = options.tonverkFrameSize { return n }
            let accepted = (6...12).map { 1 << $0 }   // 64 … 4,096
            return accepted.contains(source) ? source : 2048
        }
        if preset == .surge {   // Surge keeps a power of two from 2 to 4,096; the writer resizes others to 2,048
            return source >= 2 && source <= 4096 && source & (source - 1) == 0 ? source : 2048
        }
        return preset.frameSize ?? source
    }

    /// The frame count the destination writes for a source frame count.
    public func destinationFrameCount(source: Int) -> Int {
        preset.requiredFrameCount ?? min(source, preset.maxFrameCount)
    }

    /// Whether the destination turns a table over full scale down to fit (the 3rd Wave's tables
    /// stay within ±1; 16-bit samples cannot go beyond it).
    public var destinationScalesToFit: Bool { preset.isThirdWave || preset == .waveEdit }

    /// The interpolation as the destination's file will record it: the option, else
    /// the source's, else crossfade; nil when the format cannot record it.
    public func interpolationRecorded(for item: Item) -> Interpolation? {
        guard preset.recordsInterpolation else { return nil }
        return options.interpolation ?? item.table.interpolation ?? .crossfade
    }

    /// What converting an item is expected to produce, from the preset's facts and the options;
    /// nil when the item cannot convert (no frame size, or samples that do not divide).
    public func expected(for item: Item) -> ExpectedResult? {
        guard let size = item.frameSize, let count = item.frameCount else { return nil }
        let ppg = preset == .thirdWaveP && options.appendPPGStandardWaves
        // With the PPG waves, the table itself goes into 60 frames and the four waves follow.
        let outCount = ppg ? 64 : destinationFrameCount(source: count)
        return ExpectedResult(frameSizeIn: size, frameSizeOut: destinationFrameSize(source: size),
                              frameCountIn: count, frameCountOut: outCount,
                              countPolicy: options.frameCountPolicy, addsPPGWaves: ppg,
                              peak: item.peak, scaledToFit: item.peak > 1 && destinationScalesToFit,
                              interpolationRecorded: interpolationRecorded(for: item))
    }

    /// `expected(for:)` as one line (e.g., "64 × 1,024; resized from 2,048 samples per frame;
    /// 256 frames → 64, keeping original frames"), or why the item cannot convert.
    public func expectedResult(for item: Item) -> String {
        guard let size = item.frameSize else { return "Choose a frame size first" }
        guard let e = expected(for: item) else {
            return "Can't split into frames: the samples don't divide into frames of \(Self.formatCount(size))"
        }
        var parts = ["\(e.frameCountOut) × \(Self.formatCount(e.frameSizeOut))"]
        if e.resizes { parts.append("resized from \(Self.formatCount(e.frameSizeIn)) samples per frame") }
        if e.changesCount {
            parts.append("\(Self.formatCount(e.frameCountIn)) frame\(e.frameCountIn == 1 ? "" : "s") → \(e.tableFrameCount), " + Self.policyPhrase(e.countPolicy))
        }
        if e.scaledToFit { parts.append("turned down to fit (peak \(Self.decimal(e.peak)))") }
        if e.addsPPGWaves { parts.append("the PPG's four standard waves at 60–63") }
        return parts.joined(separator: "; ")
    }

    /// "keeping original frames" or "blending new frames".
    public static func policyPhrase(_ policy: FrameCountPolicy) -> String {
        policy == .pickEvenly ? "keeping original frames" : "blending new frames"
    }

    // MARK: Preview

    /// Runs the writer for one item (the ticked state does not matter), so the detail pane can
    /// show what converting it does; nil when the item cannot convert or the writer fails.
    public func preview(_ item: Item,
                        write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write)
        -> OutputFile? {
        guard var table = item.table.wavetable(frameSize: item.frameSize) else { return nil }
        table.name = item.name
        return try? write(table, preset, options)
    }

    // MARK: Names

    /// Gives an item a new name for converting (nil, or the file's own name, undoes it). The
    /// source files are not changed.
    public mutating func rename(_ id: UUID, to name: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].newName = name == items[i].table.name ? nil : name
    }

    /// Whether any item has a new name.
    public var anyRenamed: Bool { items.contains { $0.newName != nil } }

    /// Undoes every new name.
    public mutating func undoRenames() { for i in items.indices { items[i].newName = nil } }

    // MARK: Converting

    /// Converts the ticked items with `write` (each separately; a failure is collected, not
    /// thrown), and gives the files unique names. Items without a known frame size are reported
    /// and left out.
    public func convert(write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write)
        -> Conversion {
        var files: [OutputFile] = [], ids: [UUID] = [], reports: [ItemReport] = [], errors: [String] = []
        for item in selectedItems {
            guard var table = item.table.wavetable(frameSize: item.frameSize) else {
                errors.append("\(item.name): " + (item.frameSize == nil
                    ? "choose a frame size first"
                    : "can't split into frames of \(Self.formatCount(item.frameSize ?? 0))"))
                continue
            }
            table.name = item.name
            do {
                let f = try write(table, preset, options)
                files.append(f); ids.append(item.id)
                reports.append(ItemReport(name: item.name, notes: f.notes))
            } catch {
                errors.append("\(item.name): \(Self.describe(error))")
            }
        }
        return Conversion(files: Self.uniqueNames(files), itemIDs: ids, reports: reports, errors: errors)
    }

    /// The notes of a conversion, each distinct note once with the tables it applies to: the
    /// notes every table has first, then those several share (most tables first), then each
    /// table's own, in table order. Within a group, notes keep the order the writer gave them.
    public static func groupedNotes(_ reports: [ItemReport]) -> [GroupedNote] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        for r in reports {
            for n in r.notes {
                if names[n] == nil { order.append(n); names[n] = [] }
                names[n]?.append(r.name)
            }
        }
        let all = order.map { GroupedNote(text: $0, names: names[$0] ?? [], total: reports.count) }
        let universal = all.filter(\.isUniversal)
        let shared = all.filter { !$0.isUniversal && $0.names.count > 1 }
            .sorted { (a: GroupedNote, b: GroupedNote) -> Bool in
                a.names.count != b.names.count ? a.names.count > b.names.count : (order.firstIndex(of: a.text) ?? 0) < (order.firstIndex(of: b.text) ?? 0)
            }
        // One table's notes stay together, in table order.
        let single = reports.flatMap { (r: ItemReport) -> [GroupedNote] in
            r.notes.compactMap { (n: String) -> GroupedNote? in
                guard reports.count > 1, let who = names[n], who.count == 1 else { return nil }
                return GroupedNote(text: n, names: who, total: reports.count)
            }
        }
        return universal + shared + single
    }

    /// The files with unique names within their folders, ignoring case as macOS and FAT volumes
    /// do: a clash gets " 2", " 3", … before the extension.
    public static func uniqueNames(_ files: [OutputFile]) -> [OutputFile] {
        var used = Set<String>()
        return files.map { f in
            var f = f
            let name = numbered(f.fileName) { used.contains(((f.folder ?? "") + "/" + $0).lowercased()) }
            used.insert(((f.folder ?? "") + "/" + name).lowercased())
            f.fileName = name
            return f
        }
    }

    /// Writes files into `folder`, each into its `folder` subfolder when it has one (created as
    /// needed). An existing file is never replaced: the new one gets the next free " 2", " 3", …
    /// name, and the report lists it.
    public static func write(_ files: [OutputFile], into folder: URL) -> WriteReport {
        let fm = FileManager.default
        var report = WriteReport(written: [], renamed: [], failed: [])
        var used = Set<String>()
        for f in files {
            let dir = f.folder.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
            let prefix = f.folder.map { $0 + "/" } ?? ""
            func taken(_ name: String) -> Bool {
                used.contains((prefix + name).lowercased()) || fm.fileExists(atPath: dir.appendingPathComponent(name).path)
            }
            let name = numbered(f.fileName, taken: taken)
            used.insert((prefix + name).lowercased())
            if name != f.fileName { report.renamed.append("\(prefix + f.fileName) → \(prefix + name)") }
            let url = dir.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try f.data.write(to: url, options: .atomic)
                report.written.append(url)
            } catch {
                report.failed.append("\(prefix + name): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// The files to hand to the Pack tab after writing: the 3rd Wave `.wt` files, for a 3rd Wave
    /// destination; none otherwise.
    public static func filesForPack(_ written: [URL], preset: OutputPreset) -> [URL] {
        preset.isThirdWave ? written.filter { $0.pathExtension.lowercased() == "wt" } : []
    }

    // MARK: Wording

    /// `name`, or "name 2", "name 3", … (before the extension) until `taken` is false.
    static func numbered(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = "\(base) \(n)" + (ext.isEmpty ? "" : "." + ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// A count with thousands separators, independent of the locale ("1,024").
    public static func formatCount(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// A peak with two decimals ("1.23"), independent of the locale.
    static func decimal(_ v: Float) -> String { String(format: "%.2f", Double(v)) }

    /// The phrase with its first letter in capitals, when it starts with an ordinary word ("cue
    /// markers" to "Cue markers"); a name such as "u-he" or "clm" alone is left as it is.
    static func capitalized(_ s: String) -> String {
        guard let first = s.first, first.isLowercase, s.dropFirst().first?.isLetter == true else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// A list in words, with the serial comma: "A", "A and B", "A, B, and C".
    public static func listPhrase(_ xs: [String]) -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        case 2: return xs[0] + " and " + xs[1]
        default: return xs.dropLast().joined(separator: ", ") + ", and " + xs.last!
        }
    }

    /// The frame sizes a table's length allows, with the frame count each gives:
    /// "256 (64 frames) or 2,048 (8 frames)".
    static func candidateList(_ t: FoundTable) -> String {
        let parts = t.candidateFrameSizes.map { n -> String in
            let frames = n > 0 ? t.samples.count / n : 0
            return "\(formatCount(n)) (\(frames) frame\(frames == 1 ? "" : "s"))"
        }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " or " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + ", or " + parts.last!
        }
    }

    /// The kind of source, in a few words ("Serum WAV", "U56 in Set.pgdata", "3rd Wave U .wt").
    static func sourceDescription(_ t: FoundTable) -> String {
        switch t.source {
        case .thirdWaveWavetable(let isP): return "3rd Wave \(isP ? "P" : "U") .wt"
        case .unifiedProgram(let slot, _): return "\(slot) in \(t.fileName)"
        case .wav: return "WAV"   // one label: how the frame size was decided has its own column
        case .surgeWavetable: return "Surge .wt"
        }
    }

    /// Where a table was found, for "also in": the file name, with the slot for a `.pgdata`.
    static func locationLabel(_ t: FoundTable, url: URL) -> String {
        let file = t.fileName.isEmpty ? url.lastPathComponent : t.fileName
        if case let .unifiedProgram(slot, _) = t.source { return "\(slot) in \(file)" }
        return file
    }
}

/// Keeps the writer's result for the items the detail pane shows, so a selection that does not
/// change is not converted again on every pass. A result is reused while the item's name,
/// frame size, and samples, and the plan's destination and options, are the same.
public final class ConvertPreviewCache {
    private struct Key: Equatable {
        var itemID: UUID
        var name: String
        var frameSize: Int?
        var sampleCount: Int
        var preset: OutputPreset
        var options: OutputOptions
    }
    private struct Entry {
        var key: Key
        var file: OutputFile?
        /// The written file read back and cut into frames; nil until asked for, then kept.
        var frames: [[Float]]??
    }
    private var entries: [UUID: Entry] = [:]
    private let write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile
    /// How many times the writer has run (for tests).
    public private(set) var writerRuns = 0

    /// An empty cache that converts with `write` (the real writer by default).
    public init(write: @escaping (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write) {
        self.write = write
    }

    private func entry(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> Entry {
        let key = Key(itemID: item.id, name: item.name, frameSize: item.frameSize, sampleCount: item.table.samples.count,
                      preset: plan.preset, options: plan.options)
        if let hit = entries[item.id], hit.key == key { return hit }
        writerRuns += 1
        let e = Entry(key: key, file: plan.preview(item, write: write), frames: nil)
        entries[item.id] = e
        return e
    }

    /// `plan.preview(item)`, from the cache when nothing that affects it has changed.
    public func preview(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> OutputFile? {
        entry(item, in: plan).file
    }

    /// The converted table as the destination gets it: the preview's bytes read back with
    /// `WavetableReader` and cut into frames of the size the destination writes. Nil when there
    /// is no preview or the reader finds no table in it. Kept with the preview.
    public func resultFrames(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> [[Float]]? {
        let e = entry(item, in: plan)
        if let known = e.frames { return known }
        var frames: [[Float]]?
        if let file = e.file, let found = try? WavetableReader.read(file.data, fileName: file.fileName).first {
            let size = found.frameSize ?? plan.expected(for: item)?.frameSizeOut
            frames = found.wavetable(frameSize: size)?.frames
        }
        entries[item.id]?.frames = .some(frames)
        return frames
    }

    /// Forgets everything (e.g., when items are removed).
    public func removeAll() { entries = [:] }
}
