import Foundation
#if canImport(PgdataFormats)
import PgdataFormats   // SwiftPM build; absent in the app’s single-module swiftc build
#endif
#if canImport(WavetableFormats)
import WavetableFormats
#endif

// The Wavetables page's decisions, kept free of UI code like the rest of PgdataPackerCore: which files
// to read, how the wavetables found in them are listed (duplicates collapsed, factory tables
// flagged, frame sizes the files leave open), what each conversion is expected to produce, and how
// the converted files are named and written.
//
// The page converts existing wavetables between formats. It does not make wavetables from other
// audio: that is the 3rd Wave's Wave Maker.

/// The wavetables added to the Wavetables page, the destination chosen for them, and the conversion.
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
        /// The table as the reader found it (the first copy). Read-only: `peak`, the frame-size
        /// hint, and the content key are computed from it when the item is added.
        public let table: FoundTable
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
        /// A new name from Clean Up Names (nil: the name the file gives).
        public var newName: String?
        /// The largest absolute sample, computed once when the table is added (the views ask for
        /// it on every pass).
        public let peak: Float
        /// How the sizes in `frameSizeChoices` fit the samples (see `FrameSizeFit`), computed once
        /// when the table is added; `.unclear` when the file settles the size.
        public let frameSizeFit: FrameSizeFit.Verdict
        /// Content identity for collapsing duplicates.
        let contentKey: ContentKey

        /// The name it is converted under: the new name from Clean Up Names, or the file's.
        public var name: String { newName ?? table.name }
        /// The frame size used: the user's choice, else the page's estimate. Nil when nothing
        /// settles it.
        public var frameSize: Int? { chosenFrameSize ?? estimatedFrameSize }
        /// The size the page settles on when the user has chosen none: the file's own, except
        /// that a size taken from the file's length alone (the Serum-style 2,048) gives way to
        /// the size the samples make likely (`FrameSizeFit`), since the samples are better
        /// evidence than a convention; with no size from the file, the likely one; nil when
        /// nothing settles it. The Input column says "estimated" wherever this decided.
        public var estimatedFrameSize: Int? {
            if case .length = table.frameSizeEvidence, let n = FrameSizeFit.likelySize(frameSizeFit) { return n }
            return table.frameSize ?? FrameSizeFit.likelySize(frameSizeFit)
        }
        /// The sizes the Input column offers, when the size is open, an estimate
        /// (`sizeIsEstimate`), or overridden (`chosenFrameSize`): the file's own first, then the
        /// other sizes its length allows (`WavetableReader.fittingFrameSizes`). Empty when the
        /// file's contents state the size (a chunk or header, or a format that fixes it) and
        /// nothing has been chosen over it: the column then has nothing to choose, and the
        /// preview's Override Frame Size… offers `frameSizeAlternatives` instead.
        public var frameSizeChoices: [Int] {
            let own = table.frameSize.map { [$0] } ?? []
            var others = table.candidateFrameSizes
            if others.isEmpty, table.frameSize != nil, sizeIsEstimate || chosenFrameSize != nil {
                others = WavetableReader.fittingFrameSizes(table.samples.count)
            }
            let choices = own + others.filter { $0 != table.frameSize }
            return choices.count > 1 || table.frameSize == nil ? choices : []
        }
        /// Every size the file could be cut at: its own first (when it has one), then the other
        /// sizes its length allows. For overriding a size a WAV or FLAC states in a chunk, which
        /// is rarely right but sometimes needed (a chunk saying 2,048 over frames of 1,024
        /// divides fine and shows two cycles in every frame). Empty for the formats whose layout
        /// fixes the size (3rd Wave and Surge tables), and when there is nothing to choose
        /// between.
        public var frameSizeAlternatives: [Int] {
            guard table.source == .wav || table.source == .flac else { return [] }
            let own = table.frameSize.map { [$0] } ?? []
            var others = table.candidateFrameSizes
            if others.isEmpty { others = WavetableReader.fittingFrameSizes(table.samples.count) }
            let all = own + others.filter { $0 != table.frameSize }
            return all.count > 1 ? all : []
        }
        /// Whether the size is one the file's contents state, so that choosing another is an
        /// override (offered from the preview, not the Input column).
        public var sizeIsStated: Bool {
            if case .statedInFile = table.frameSizeEvidence { return table.frameSize != nil }
            return false
        }
        /// Whether the size is the app's estimate rather than something the file's contents
        /// state: from a tag in the file name (files get renamed), a .txt beside the file,
        /// markers, or the length alone. An estimate is offered as the default of a choice.
        public var sizeIsEstimate: Bool {
            switch table.frameSizeEvidence {
            case .fileName, .sidecar, .markers, .length: return true
            case .statedInFile, .none: return false
            }
        }
        /// Whether the frame size is still open, so the user must choose one: the file leaves it
        /// open, the samples make none of the sizes likely, and nothing has been chosen.
        public var needsFrameSize: Bool { frameSize == nil }
        /// Frames at the frame size used; nil when no size is known or the samples do not divide.
        public var frameCount: Int? {
            guard let n = frameSize, n > 0, !table.samples.isEmpty, table.samples.count % n == 0 else { return nil }
            return table.samples.count / n
        }
        /// Frames × samples ("64 × 1,024"), or what is missing ("Choose a frame size", "Can't
        /// split into frames").
        public var sizeDescription: String {
            if let n = frameSize, let c = frameCount { return "\(c) × \(ConvertPlan.formatCount(n))" }
            if frameSize != nil { return "Can’t split into frames" }
            return "Choose a frame size"
        }
        /// Whether the frame size is the page's estimate (from the samples' fit, or from the
        /// file's length alone), with no choice made.
        public var isGuessed: Bool { chosenFrameSize == nil && (sizeSource == .guessed || sizeSource == .likely) }
        /// A word or two after the size in the Input column, saying where the size comes from,
        /// so every row shows how much to trust it: "in the file" (a chunk or header states
        /// it, or the format fixes it), "in the name" (a Tonverk tag), "in the .txt" (a Serum
        /// sidecar), "from markers" (cue or loop markers), "estimated" (from the samples, or
        /// from the length alone), or "set manually" (the user chose it); nil when there is no
        /// size yet. The full reason is `basisDescription`.
        public var sizeQualifier: String? {
            switch sizeSource {
            case .inFile: return "in the file"
            case .fileName: return "in the name"
            case .sidecar: return "in the .txt"
            case .markers: return "from markers"
            case .guessed, .likely: return "estimated"
            case .setManually: return "set manually"
            case .notStated: return nil
            }
        }
        /// A short badge for where the table came from, when that matters: the slot and file for
        /// a table inside a `.pgdata`, "3rd Wave U" or "3rd Wave P", "Surge .wt", or "FLAC"; nil
        /// for a WAV, the usual case.
        public var originBadge: String? {
            switch table.source {
            case .wav: return nil
            case .flac: return "FLAC"
            case .surgeWavetable: return "Surge .wt"
            case .thirdWaveWavetable(let isP): return isP ? "3rd Wave P" : "3rd Wave U"
            case .unifiedProgram(let slot, _): return "\(slot) in \(table.fileName)"
            }
        }
        /// What the frame size used rests on.
        public var sizeSource: SizeSource {
            if chosenFrameSize != nil { return .setManually }
            if needsFrameSize { return .notStated }
            if table.frameSize == nil { return .likely }   // the samples' fit settled it
            switch table.frameSizeEvidence {
            case .statedInFile: return .inFile
            case .fileName: return .fileName
            case .sidecar: return .sidecar
            case .markers: return .markers
            case .length: return FrameSizeFit.likelySize(frameSizeFit) != nil ? .likely : .guessed
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
                // 2,048 samples per frame is the size of Serum-style wavetables (WAVETABLES.md
                // section 2); taken when the samples themselves point to no size.
                return "The file doesn’t specify a frame size, and nothing in the samples points to one. The estimate is \(ConvertPlan.formatCount(table.frameSize ?? 2048)) samples per frame, the size of Serum-style wavetables."
            case .likely:
                // The other sizes the chooser offers: the file's own (when the length alone
                // suggested one) and the rest its length allows.
                // Each sentence finishes what it states ("frames of 128 samples", not "128") and
                // names the noun rather than saying "it" (Adam, 2026-10-26).
                let others = frameSizeChoices.filter { $0 != frameSize }.map(ConvertPlan.formatCount)
                return "The file doesn’t specify a frame size. The estimate is \(ConvertPlan.formatCount(frameSize ?? 0)) samples per frame, because frames of that size are alike from one to the next, as the frames of a wavetable are."
                    + (others.isEmpty ? "" : " The file’s length also allows frames of \(ConvertPlan.listPhrase(others, "or")) samples.")
            case .notStated:
                // Unlike `.guessed` and `.likely`, nothing could be estimated: the file states no
                // size, its length is not a Serum-style one, and no size makes its frames alike.
                return "Unable to estimate a frame size from this file."
                    + (table.candidateFrameSizes.isEmpty ? " The file’s length allows none of the frame sizes offered here (powers of two from 64 to 4,096 samples)."
                                                          : " The file’s length allows frames of " + ConvertPlan.candidateList(table) + ".")
            case .setManually:
                if let own = table.frameSize {
                    return sizeIsStated ? "Set manually; the file specifies \(ConvertPlan.formatCount(own)) samples per frame."
                                        : "Set manually; the file’s length suggested \(ConvertPlan.formatCount(own)) samples per frame."
                }
                return "Set manually; the file doesn’t specify a frame size."
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

    /// What an item's frame size rests on, as the Input column's qualifier and tooltip show it.
    public enum SizeSource: String, Equatable, CaseIterable {
        /// Stated in the file's contents (a `clm ` chunk, a Surge header, a 3rd Wave layout).
        case inFile
        /// A Tonverk `_wt<N>` tag in the file name.
        case fileName
        /// A Serum `.txt` file beside the WAV.
        case sidecar
        /// Loop or cue markers, which ordinary samples carry too.
        case markers
        /// The file's length alone, with the samples pointing to no size: 2,048 estimated.
        case guessed
        /// The samples make one size likely (`FrameSizeFit`): that one estimated, whether the
        /// file's length alone suggested another or left the size open.
        case likely
        /// Nothing says: the user must choose.
        case notStated
        /// The user chose a size.
        case setManually

        /// A word or two for the tooltips ("In file", "Estimated", "Set manually").
        public var label: String {
            switch self {
            case .inFile: return "In file"
            case .fileName: return "File name"
            case .sidecar: return "Serum .txt"
            case .markers: return "Markers"
            case .guessed, .likely: return "Estimated"
            case .notStated: return "Not stated"
            case .setManually: return "Set manually"
            }
        }
    }

    /// Whether an item will convert, and if not, why. The page acts on the rows the user selects
    /// (Convert Selected…) or on every table (Convert All…); `isIncluded(_:)` says which tables
    /// Convert All takes, and the statuses speak of those.
    public enum Status: Equatable {
        /// Ready: a frame size that divides the samples into frames.
        case ready
        /// The file leaves the frame size open and none has been chosen.
        case needsFrameSize
        /// The samples do not divide into frames of the size given.
        case cannotSplit
        /// Left out by Convert All: a factory table for a 3rd Wave destination, which the 3rd Wave
        /// already has (Convert Selected… still takes it).
        case excluded

        /// Whether Convert All takes the item but it cannot convert yet.
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

    /// What converting an item is expected to produce: the writer's own plan
    /// (`WavetableWriter.plan`), which the writer then follows, so the page and the conversion
    /// cannot disagree. The writer's notes, after converting, say what was done.
    public typealias ExpectedResult = WritePlan

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
        /// "All 74 tables" ("Both tables" for two), "12 tables", or the one table's name.
        public var label: String {
            if names.count == 1 { return names[0] }
            if isUniversal { return CountWords.all(total, "tables") }
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
    /// The destination. An interpolation chosen for another destination is dropped on the way
    /// to one that cannot take it: a destination whose files record no interpolation (the
    /// Options box shows no Interpolation pop-up there, so the choice would act unseen), or
    /// Tonverk for a spectral choice, which a Tonverk file name cannot mark (the pop-up showed
    /// Crossfade while the writer noted a spectral morph: Adam, 2026-10-26). The pop-up then
    /// shows each table's own interpolation, or the default.
    public var preset: OutputPreset {
        didSet {
            if !preset.recordsInterpolation || (preset == .tonverk && options.interpolation == .spectral) {
                options.interpolation = nil
            }
        }
    }
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
                // enumerator does not honor .skipsHiddenFiles.
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

    /// Adds found tables to the list: prepares each (`Prepared`) and adds them (`add(_:)`). A
    /// table whose content (samples and frame size) matches one already listed is recorded under
    /// it ("also in …") rather than listed again; a table from a file and slot already listed is
    /// left out. Tables from 3rd Wave files are checked against the factory library.
    @discardableResult
    public mutating func add(_ found: [Found], factory: FactoryLibrary = .builtIn) -> AddSummary {
        add(found.map { Prepared($0, factory: factory) })
    }

    /// A found table with the work of adding it done ahead, on any thread: its content key (a
    /// hash of every sample), its peak, the factory table it matches, and the frame-size verdict
    /// over its samples. The app prepares tables on the queue that read them, so that
    /// `add(_:)`, on the main thread, has only the list to check them against.
    public struct Prepared {
        /// The table and where it was found.
        public let found: Found
        let key: ContentKey
        let peak: Float
        let factorySlot: SourceRef?
        let factoryName: String?
        let fit: FrameSizeFit.Verdict

        /// Does the work for one found table.
        public init(_ found: Found, factory: FactoryLibrary = .builtIn) {
            let t = found.table
            self.found = found
            key = ContentKey(t)
            peak = t.peak
            if let fp = t.thirdWaveFingerprint, let ref = factory.slot(withFingerprint: fp) {
                factorySlot = ref
                // The factory P00–P33 tables are named "Wavetable P00" …: a name that only repeats the slot is left out.
                factoryName = factory.name(ref).flatMap { $0 == "Wavetable \(ref.label)" ? nil : $0 }
            } else {
                factorySlot = nil
                factoryName = nil
            }
            // Rated unless the file's contents state the size; even when the length allows one
            // size only, so a length-only file whose frames are alike at the Serum-style size is
            // "likely" rather than a bare convention.
            let choices = (t.frameSize.map { [$0] } ?? []) + t.candidateFrameSizes.filter { $0 != t.frameSize }
            let stated: Bool = { if case .statedInFile = t.frameSizeEvidence { return true }; return false }()
            fit = stated || choices.isEmpty ? .unclear : FrameSizeFit.verdict(t.samples, sizes: choices)
        }
    }

    /// Adds prepared tables (see `Prepared`): a table identical to one listed is recorded under
    /// it ("also in …"), the same file and slot again is left out, and the rest become items.
    @discardableResult
    public mutating func add(_ prepared: [Prepared]) -> AddSummary {
        var s = AddSummary(added: 0, duplicates: 0, repeated: 0)
        for p in prepared {
            let t = p.found.table
            let location = Location(url: p.found.url, label: Self.locationLabel(t, url: p.found.url))
            if let i = items.firstIndex(where: { $0.contentKey == p.key && $0.table.samples == t.samples }) {
                if items[i].location == location || items[i].alsoIn.contains(location) { s.repeated += 1; continue }
                items[i].alsoIn.append(location); s.duplicates += 1
                continue
            }
            items.append(Item(id: UUID(), table: t, location: location, sourceDescription: Self.sourceDescription(t),
                              factorySlot: p.factorySlot, factoryName: p.factoryName, peak: p.peak, frameSizeFit: p.fit, contentKey: p.key))
            s.added += 1
        }
        return s
    }

    /// Removes items from the list.
    public mutating func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    /// Whether Convert All takes an item for the current destination: everything except the 3rd
    /// Wave's factory tables when the destination is the 3rd Wave, which already has them (Convert
    /// Selected… takes whatever is selected, those included). The Options captions and the
    /// destination's cautions describe these items.
    public func isIncluded(_ item: Item) -> Bool { !(preset.isThirdWave && item.factorySlot != nil) }

    /// The items Convert All takes, in list order.
    public var includedItems: [Item] { items.filter(isIncluded) }

    /// Sets the frame size for an item, from its `frameSizeChoices`; nil, or the file's own size,
    /// clears the choice. Other sizes are ignored.
    public mutating func chooseFrameSize(_ id: UUID, _ size: Int?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let size, !items[i].frameSizeAlternatives.contains(size), !items[i].frameSizeChoices.contains(size) { return }
        // The page's own estimate is no choice at all.
        items[i].chosenFrameSize = size == items[i].estimatedFrameSize ? nil : size
    }

    // MARK: One frame size for several tables

    /// Among `ids`, the items whose frame size the file does not state (estimated or
    /// still open), in the page's order: the ones a frame size chosen for several tables
    /// applies to. A table whose file states its size keeps it (the preview's override is for
    /// one table at a time).
    public func adjustableItems(in ids: Set<UUID>) -> [Item] {
        items.filter { ids.contains($0.id) && !$0.sizeIsStated && !$0.frameSizeChoices.isEmpty }
    }

    /// The frame sizes every one of `items` allows (`frameSizeChoices`), smallest first; empty
    /// when no size fits them all.
    public static func commonFrameSizes(of items: [Item]) -> [Int] {
        guard let first = items.first else { return [] }
        var common = Set(first.frameSizeChoices)
        for item in items.dropFirst() { common.formIntersection(item.frameSizeChoices) }
        return common.sorted()
    }

    /// The frame size `items` share, when they all have the same one; nil when they differ.
    public static func sharedFrameSize(of items: [Item]) -> Int? {
        let sizes = Set(items.map { $0.frameSize ?? 0 })
        return sizes.count == 1 ? sizes.first.flatMap { $0 == 0 ? nil : $0 } : nil
    }

    /// Chooses `size` for every item in `ids` that `adjustableItems(in:)` returns and whose
    /// length allows it (see `chooseFrameSize(_:_:)`); the others are left as they are.
    public mutating func chooseFrameSize(_ size: Int, forAll ids: Set<UUID>) {
        for item in adjustableItems(in: ids) where item.frameSizeChoices.contains(size) {
            chooseFrameSize(item.id, size)
        }
    }

    /// Notes for an item, warnings first: the reader's, and what the destination means for it.
    public func notes(for item: Item) -> [String] { itemNotes(for: item).all }

    /// Notes for an item by severity. The reader's note about samples over full scale is replaced
    /// by one built from the item's peak (so the wording is the same whichever reader found it),
    /// and the reader's notes about disagreeing metadata or samples left out count as warnings.
    public func itemNotes(for item: Item) -> ItemNotes {
        var warnings: [String] = [], information: [String] = []
        for note in item.table.readNotes {
            if case .peak = note.kind { continue }
            if Self.isWarning(note.kind) { warnings.append(note.text) } else { information.append(note.text) }
        }
        if item.peak > 1 {
            warnings.insert("Peak \(Wavetable.peakText(item.peak)) is over full scale (±1); "
                + (destinationScalesToFit ? "the table is attenuated to fit, so the table plays a little quieter."
                                          : "the table is kept as it is, so unless the synth attenuates the table, the loudest parts may clip, which adds a hard, buzzy edge."), at: 0)
        }
        if let slot = item.factorySlot {
            let label = "factory " + slot.label + (item.factoryName.map { " " + $0 } ?? "")
            information.append(preset.isThirdWave
                ? "Same as \(label), which your 3rd Wave is expected to have, so Convert All leaves it out (Convert Selected… takes it)."
                : "Same as \(label).")
        }
        return ItemNotes(warnings: warnings, information: information)
    }

    /// Whether a reader's note is a warning: metadata that disagrees or is ignored, samples left
    /// out, channels dropped, or a file cut short. Everything else (a high frame count, an
    /// unusual Surge size, where a FLAC tag was found) is information; the peak has its own note.
    static func isWarning(_ kind: ReadNote.Kind) -> Bool {
        switch kind {
        case .channelsDropped, .sizeClaimsDisagree, .interpolationClaimsDisagree, .samplesLeftOut, .cutShort,
             .sizeTagRejected, .sizeTagUnreadable, .sidecarOutOfRange:
            return true
        case .peak, .highFrameCount, .unusualSurgeFrameSize, .tagInComment, .commentMentionsFrames:
            return false
        }
    }

    /// Whether an item can be converted: its frame size is known and its samples divide into frames.
    public func canConvert(_ item: Item) -> Bool { item.frameCount != nil }

    /// Whether an item converts, and if not, why.
    public func status(_ item: Item) -> Status {
        guard isIncluded(item) else { return .excluded }
        if item.frameSize == nil { return .needsFrameSize }
        return item.frameCount == nil ? .cannotSplit : .ready
    }

    /// The item's status as a sentence or two: what blocks it and what to do, or that it is
    /// ready, or that Convert All leaves it out.
    public func statusDescription(_ item: Item) -> String {
        switch status(item) {
        case .ready: return "Ready to convert."
        case .excluded: return "Left out by Convert All: a factory table your 3rd Wave already has. Convert Selected… takes it."
        case .needsFrameSize:
            return "Choose a frame size: none could be estimated from the file."
                + (item.table.candidateFrameSizes.isEmpty ? " The file’s length allows none of the frame sizes offered here (powers of two from 64 to 4,096 samples)."
                                                           : " The file’s length allows frames of \(Self.candidateList(item.table)).")
        case .cannotSplit:
            return "Can’t split into frames: \(Self.formatCount(item.table.samples.count)) samples don’t divide into frames of \(Self.formatCount(item.frameSize ?? 0))."
        }
    }

    /// Whether an item Convert All takes can't be converted yet (the filter above the table).
    /// Estimated frame sizes and warnings do not count: those items are converted.
    public func needsAttention(_ item: Item) -> Bool { status(item).isBlocked }

    /// The items Convert All takes that cannot convert yet (see `needsAttention`).
    public var attentionCount: Int { items.filter(needsAttention).count }

    /// The items Convert All takes that still need a frame size.
    public var needsFrameSizeCount: Int { items.filter { status($0) == .needsFrameSize }.count }

    /// The items Convert All takes whose samples do not divide into frames.
    public var cannotSplitCount: Int { items.filter { status($0) == .cannotSplit }.count }

    /// The items Convert All takes that cannot convert yet, for either reason.
    public var blockedCount: Int { items.filter { status($0).isBlocked }.count }

    /// What converting does to a table whose destination changes none of its frames, size, or
    /// level: for a 3rd Wave `.wt` or `.pgdata` table going back to a 3rd Wave table, the table
    /// itself is unchanged and only its wrapping differs; for any other source, the file format
    /// changes. (A U table's mipmap chain is recomputed on the way, from the frames; the 3rd Wave
    /// identifies a table by its frames alone. See section 5.1 of FORMATS.md.)
    public func unchangedWords(for item: Item) -> String {
        switch item.table.source {
        case .thirdWaveWavetable(let isP):
            return preset.isThirdWave && isP == (preset == .thirdWaveP) && !isP
                ? "The table is unchanged; the mipmap chain is recomputed."
                : (preset.isThirdWave ? "The table is unchanged." : "Only the file format changes.")
        case .unifiedProgram:
            return preset.isThirdWave ? "The table is unchanged, written out as a .wt file." : "Only the file format changes."
        case .wav, .flac, .surgeWavetable:
            return "Only the file format changes."
        }
    }

    /// The first item, in the page's order, with the given status; nil when none has it. The
    /// page's counts of blocked tables jump to this item when clicked.
    public func firstItem(with status: Status) -> Item? { items.first { self.status($0) == status } }

    /// The items Convert All takes whose frame count the destination changes.
    public var frameCountChangeCount: Int {
        includedItems.filter { expected(for: $0)?.changesCount == true }.count
    }

    /// Whether converting to a destination has been tested (`OutputPreset.testedIn`): the
    /// chosen row says so in orange when it has not, and the sources popover either way.
    /// "Converting to this destination has not yet been tested in its synth." or "Tested in
    /// Pigments and Serum."
    public static func testingStatus(_ preset: OutputPreset) -> String {
        preset.testedIn.isEmpty ? "Converting to this destination has not yet been tested in its synth."
                                : "Tested in " + listPhrase(preset.testedIn) + "."
    }

    /// The destinations whose testing decides whether wavetable conversion is still under
    /// development: the 3rd Wave's P and U tables, the page's purpose, and Tonverk (Adam,
    /// 2026-10-26). The other destinations carry their own caution until they are tested.
    public static let gatingPresets: [OutputPreset] = [.thirdWaveP, .thirdWaveU, .tonverk]

    /// Whether converting to any of the `gatingPresets` has yet to be tested in its synth
    /// (`OutputPreset.testedIn` empty). While true, the Wavetables page is shown only with View ›
    /// Show Under-Development Features and carries a notice that wavetable conversion is under
    /// development; both go when the last of those destinations is tested, and the rows of
    /// destinations still untested say so themselves.
    public static var conversionUnderDevelopment: Bool {
        gatingPresets.contains { $0.testedIn.isEmpty }
    }

    /// The orange note under the chosen destination, or nil: one of the things its sources leave
    /// open (`OutputPreset.caveat` has the general statement, shown with the sources), said
    /// only when the tables to convert, or a choice made, bring it about:
    /// - Serum, Vital, Pigments: an interpolation other than crossfade is saved for some table,
    ///   which Pigments does not read.
    /// - MiniFreak V: some table has fewer than 64 frames, which it is not documented to handle.
    /// - Phase Plant: some table has fewer than the 256 frames its documentation asks for, so
    ///   frames are added.
    /// The 3rd Wave destinations have none: how many tables fit is a matter for the 3rd Wave
    /// (section 7 of FORMATS.md), not a caution the page raises.
    public func caveat(for preset: OutputPreset) -> String? {
        let tables = includedItems.filter(canConvert)
        switch preset {
        case .wav2048:
            let notCrossfade = tables.contains { (item: Item) -> Bool in
                let saved = WavetableWriter.interpolationRecorded(for: preset, source: item.table.interpolation, options: options)
                return saved != nil && saved != .crossfade
            }
            return notCrossfade ? "Pigments does not read the interpolation saved in the file (Serum and Vital do)." : nil
        case .miniFreak:
            let short = tables.filter { ($0.frameCount ?? 64) < 64 }.count
            guard short > 0 else { return nil }
            return "\(Self.tablesHave(short, of: tables.count)) fewer than 64 frames; what MiniFreak V does with fewer frames is not documented."
        case .phasePlant:
            let short = tables.filter { ($0.frameCount ?? 256) < 256 }.count
            guard short > 0 else { return nil }
            return "\(Self.tablesHave(short, of: tables.count)) fewer than 256 frames; whether Phase Plant loads shorter tables is untested, so frames are added to reach 256."
        case .thirdWaveU, .thirdWaveP, .tonverk, .surge, .waveEdit:
            return nil
        }
    }

    /// "1 table has", "12 tables have"; "Both tables have" or "All 12 tables have" when every
    /// table to convert is meant (`CountWords.all`).
    static func tablesHave(_ n: Int, of total: Int) -> String {
        if n == 1 { return "1 table has" }
        return (n == total ? CountWords.all(n, "tables") : "\(n) tables") + " have"
    }

    /// The report's first line: "Converted 74 tables for Phase Plant into “output”." (the
    /// destination's own notes say the sizes, so the title does not).
    public func reportTitle(converted n: Int, folderName: String) -> String {
        let to = preset.isThirdWave ? (n == 1 ? "to a \(preset.title)" : "to \(preset.title)s") : "for \(preset.title)"
        return "Converted \(n) table\(n == 1 ? "" : "s") \(to) into \u{201C}\(folderName)\u{201D}."
    }

    // MARK: Destination

    /// The frame size the destination writes for a source frame size (the writer's own rule).
    public func destinationFrameSize(source: Int) -> Int {
        WavetableWriter.frameSize(for: preset, source: source, options: options)
    }

    /// The frame count the destination writes for a source frame count (the writer's own rule;
    /// with the PPG waveforms the table itself goes into 60, which `expected(for:)` accounts for).
    public func destinationFrameCount(source: Int) -> Int {
        WavetableWriter.frameCount(for: preset, source: source)
    }

    /// Whether the destination turns a table over full scale down to fit (the 3rd Wave's tables
    /// stay within ±1; 16-bit samples cannot go beyond it).
    public var destinationScalesToFit: Bool { preset.scalesToFit }

    /// The interpolation as the destination's file will record it: the option, else
    /// the source's, else crossfade; nil when the format cannot record it. A Tonverk name
    /// can say only stepped or smooth, so spectral is recorded as crossfade there.
    public func interpolationRecorded(for item: Item) -> Interpolation? {
        WavetableWriter.interpolationRecorded(for: preset, source: item.table.interpolation, options: options)
    }

    /// The interpolation the destination's synth plays the result with, for the preview's
    /// pictures and Listen: what the file records when the format records it; for the 3rd Wave,
    /// whose files record none, what its Wave Flow does by default (checked on an 8M; FORMATS.md
    /// section 5.1): a U table plays with wavetable smoothing on, taken here to be a crossfade
    /// between frames (the manual says "interpolation between neighbouring frames"; the method
    /// is an inference), and a P table with it off, stepping from frame to frame. Nil for a
    /// format that records nothing when the synth's default is not known.
    public func interpolationPlayed(for item: Item) -> Interpolation? {
        if let recorded = interpolationRecorded(for: item) { return recorded }
        switch preset {
        case .thirdWaveU: return .crossfade
        case .thirdWaveP: return Interpolation.none
        default: return nil
        }
    }

    // MARK: Existing choices (the Options pickers)

    // The Interpolation and Tonverk frame size pickers list every value the destination can take
    // and mark the one the tables to convert already have: "Crossfade — existing" when every
    // table states that value (that item stands for no override, `options.interpolation == nil`),
    // or a first item "Each table’s own — existing: 3 stepped, 2 crossfade; 4 not stated" when
    // they differ or some files say nothing. A file that says nothing has no existing value: it
    // is saved with the writer's default (crossfade; Tonverk's smooth), and when no file says
    // anything the default item simply stands for no override, unmarked. Tables that cannot
    // convert yet are left out of the counts.

    /// A picker item's words in three parts: the value ("Crossfade", "Each table’s own"); set
    /// apart after a dash and in a second style, the mark that the tables already have it
    /// ("existing"); and, for "Each table’s own", the breakdown of what they have ("3 stepped,
    /// 2 crossfade"), which the menu item leaves out (it made the item long and wide: Adam,
    /// 2026-10-26) and the caption under the menu carries.
    public struct ChoiceLabel: Equatable {
        /// The value the item chooses.
        public var value: String
        /// What the tables to convert already have, or nil when the item is not marked.
        public var existing: String?
        /// The breakdown behind "existing", for the caption, or nil.
        public var detail: String?

        /// Creates a label from its parts.
        public init(value: String, existing: String? = nil, detail: String? = nil) {
            self.value = value; self.existing = existing; self.detail = detail
        }

        /// The parts as one string, for a tooltip: "Crossfade — existing", "Each table’s own —
        /// existing: 3 stepped, 2 crossfade".
        public var text: String { (existing.map { value + " — " + $0 } ?? value) + (detail.map { ": " + $0 } ?? "") }
    }

    /// The interpolation the writer records when a file says nothing and nothing is chosen
    /// (`WavetableWriter`'s default; Tonverk's manual calls a crossfade "smooth").
    public static let defaultInterpolation: Interpolation = .crossfade

    /// The interpolations the tables to convert state in their files, as the destination would
    /// record them (for Tonverk, whose name can say only stepped or smooth, spectral counts as
    /// crossfade), keyed by interpolation with the number of tables. Files that say nothing are
    /// not counted (see `unstatedInterpolationCount`). Empty when the destination's files record
    /// no interpolation, or no table to convert can convert yet.
    public func existingInterpolations() -> [Interpolation: Int] {
        guard preset.recordsInterpolation else { return [:] }
        var unchosen = options
        unchosen.interpolation = nil
        var counts: [Interpolation: Int] = [:]
        for item in includedItems where canConvert(item) && item.table.interpolation != nil {
            if let i = WavetableWriter.interpolationRecorded(for: preset, source: item.table.interpolation, options: unchosen) {
                counts[i, default: 0] += 1
            }
        }
        return counts
    }

    /// The tables to convert whose files say nothing about interpolation (saved with
    /// `defaultInterpolation` unless one is chosen); 0 when the destination records none.
    public var unstatedInterpolationCount: Int {
        guard preset.recordsInterpolation else { return 0 }
        return includedItems.filter { canConvert($0) && $0.table.interpolation == nil }.count
    }

    /// The one interpolation every table to convert states (see `existingInterpolations`); nil
    /// when they differ, when any file says nothing, or when there is none.
    public var sharedExistingInterpolation: Interpolation? {
        unstatedInterpolationCount == 0 ? Self.shared(existingInterpolations()) : nil
    }

    /// The value the picker's unmarked default item stands for when no file states an
    /// interpolation: `defaultInterpolation`. Nil when some file does (the existing value, or
    /// the "Each table’s own" item, then stands for no override).
    public var defaultInterpolationItem: Interpolation? {
        existingInterpolations().isEmpty ? Self.defaultInterpolation : nil
    }

    /// The Interpolation picker's first item when the tables to convert state different
    /// interpolations, or some state one and others say nothing: "Each table’s own — existing:
    /// 3 stepped, 2 crossfade; 4 not stated". Nil when
    /// they all state one value (that value's item is then marked existing) and when no file
    /// states any (the default's item then stands for no override).
    public var eachTablesOwnInterpolationLabel: ChoiceLabel? {
        let counts = existingInterpolations()
        if counts.isEmpty || sharedExistingInterpolation != nil { return nil }
        var parts = [Interpolation.none, .crossfade, .spectral].compactMap { (i: Interpolation) -> String? in
            counts[i].map { "\($0) \(existingWord(i))" }
        }.joined(separator: ", ")
        let unstated = unstatedInterpolationCount
        if unstated > 0 { parts += "; \(unstated) not stated" }
        return ChoiceLabel(value: "Each table’s own", existing: "existing", detail: parts)
    }

    /// The word for an interpolation in the existing counts: "stepped", "crossfade", or
    /// "spectral" (Tonverk's manual says "smooth" for a crossfade; the page keeps one word).
    func existingWord(_ i: Interpolation) -> String {
        switch i {
        case Interpolation.none: return "stepped"
        case .crossfade: return "crossfade"
        case .spectral: return "spectral"
        }
    }

    /// The frame sizes of the tables to convert, with the number of tables of each (for the
    /// Tonverk frame size picker). Tables that cannot convert yet are left out.
    public func existingFrameSizes() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for item in includedItems where canConvert(item) {
            if let n = item.frameSize { counts[n, default: 0] += 1 }
        }
        return counts
    }

    /// The one frame size every table to convert has, when Tonverk takes it (powers of two from
    /// 64 to 4,096, `WavetableWriter.tonverkFrameSizes`); nil otherwise.
    public var sharedTonverkFrameSize: Int? {
        guard let n = Self.shared(existingFrameSizes()), WavetableWriter.tonverkFrameSizes.contains(n) else { return nil }
        return n
    }

    /// The Tonverk frame size picker's first item when the tables to convert differ in frame
    /// size, have one Tonverk doesn't take, or there are none: "Each table's own — existing:
    /// 1,024 and 2,048", and for sizes Tonverk doesn't take, what the writer does with them
    /// ("2,048 for 3 tables of 600, which Tonverk doesn't take"). Nil when every table has one
    /// size Tonverk takes: that size's own item is then marked existing.
    public var eachTablesOwnFrameSizeLabel: ChoiceLabel? {
        let counts = existingFrameSizes()
        if sharedTonverkFrameSize != nil { return nil }
        if counts.isEmpty { return ChoiceLabel(value: "Each table’s own") }
        let sizes = counts.keys.sorted()
        let taken = sizes.filter { WavetableWriter.tonverkFrameSizes.contains($0) }
        let notTaken = sizes.filter { !WavetableWriter.tonverkFrameSizes.contains($0) }
        var parts: [String] = []
        if !taken.isEmpty { parts.append(Self.listPhrase(taken.map(Self.formatCount))) }
        if !notTaken.isEmpty {
            let n = notTaken.reduce(0) { $0 + (counts[$1] ?? 0) }
            parts.append("2,048 for \(n) table\(n == 1 ? "" : "s") of \(Self.listPhrase(notTaken.map(Self.formatCount))), which Tonverk doesn’t take")
        }
        return ChoiceLabel(value: "Each table’s own", existing: "existing", detail: parts.joined(separator: "; "))
    }

    /// The one key of a count, when there is exactly one.
    static func shared<Value>(_ counts: [Value: Int]) -> Value? {
        counts.count == 1 ? counts.keys.first : nil
    }

    /// What converting an item is expected to produce (the writer's plan for it); nil when the
    /// item cannot convert (no frame size, or samples that do not divide).
    public func expected(for item: Item) -> ExpectedResult? { expected(for: item, frameSize: item.frameSize) }

    /// `expected(for:)` as if the item had the frame size `frameSize` (one of the sizes the file
    /// allows), for the size chooser; nil when that size does not divide the samples.
    public func expected(for item: Item, frameSize: Int?) -> ExpectedResult? {
        guard let size = frameSize, size > 0, !item.table.samples.isEmpty, item.table.samples.count % size == 0 else { return nil }
        return WavetableWriter.plan(frameSize: size, frameCount: item.table.samples.count / size, peak: item.peak,
                                    interpolation: item.table.interpolation, preset: preset, options: options)
    }

    /// `expected(for:)` as one line (e.g., "64 × 1,024; resized from 2,048 samples per frame;
    /// 256 frames → 64, keeping original frames"), or why the item cannot convert.
    public func expectedResult(for item: Item) -> String {
        guard let size = item.frameSize else { return "Choose a frame size first" }
        guard let e = expected(for: item) else {
            return "Can’t split into frames: the samples don’t divide into frames of \(Self.formatCount(size))"
        }
        var parts = ["\(e.frameCountOut) × \(Self.formatCount(e.frameSizeOut))"]
        if e.resizes { parts.append("resized from \(Self.formatCount(e.frameSizeIn)) samples per frame") }
        if e.changesCount {
            parts.append("\(Self.formatCount(e.frameCountIn)) frame\(e.frameCountIn == 1 ? "" : "s") → \(e.tableFrameCount), " + Self.methodWord(e.countPolicy, grows: e.frameCountGrows == true))
        }
        if e.scaledToFit { parts.append("attenuated to fit (peak \(Wavetable.peakText(e.peak)))") }
        else if e.mayScaleToFit { parts.append("may be attenuated a little to fit after resizing") }
        if e.addsPPGWaves { parts.append("the PPG’s four standard waveforms at 60–63") }
        return parts.joined(separator: "; ")
    }

    /// How a frame count is changed, in a word: "repeated" (more frames, originals repeated),
    /// "picked evenly" (fewer frames, originals kept), or "crossfaded" (new frames made by
    /// crossfading neighbors, either way).
    public static func methodWord(_ policy: FrameCountPolicy, grows: Bool) -> String {
        switch policy {
        case .pickEvenly: return grows ? "repeated" : "picked evenly"
        case .interpolate: return "crossfaded"
        }
    }

    /// How many tables to convert gain frames and how many lose them for the destination.
    public var frameCountChanges: (gain: Int, lose: Int) {
        var gain = 0, lose = 0
        for item in includedItems {
            guard let grows = expected(for: item)?.frameCountGrows else { continue }
            if grows { gain += 1 } else { lose += 1 }
        }
        return (gain, lose)
    }

    /// The Options caption for the frame-count choice: "148 tables lose frames (picked
    /// evenly)." or, when some gain and some lose, "Affects 12 tables: 9 gain frames (repeated),
    /// 3 lose frames (picked evenly)."; "Every table already fits." when none changes.
    public var frameCountCaption: String {
        let c = frameCountChanges
        let total = c.gain + c.lose
        guard total > 0 else { return "Every table already fits." }
        func part(_ n: Int, _ verb: String, grows: Bool, noun: Bool) -> String {
            let subject = noun ? (n == 1 ? "1 table " : "\(n) tables ") : "\(n) "
            let method = Self.methodWord(options.frameCountPolicy, grows: grows)
            return subject + verb + (n == 1 ? "s" : "") + " frames (" + method + ")"
        }
        if c.lose == 0 { return part(c.gain, "gain", grows: true, noun: true) + "." }
        if c.gain == 0 { return part(c.lose, "lose", grows: false, noun: true) + "." }
        return "Affects \(total) tables: " + part(c.gain, "gain", grows: true, noun: false) + ", " + part(c.lose, "lose", grows: false, noun: false) + "."
    }

    /// What the Changes column says for an item: short words for each change the destination
    /// makes ("2,048 → 1,024 samples", "64 → 256 frames", "attenuated", "+ PPG waveforms", "name changed"), and
    /// short orange words for the warnings ("peak 1.14", "extra samples dropped"). Both empty
    /// when nothing changes but the format; nil when the item cannot convert.
    public func changeWords(for item: Item) -> (changes: [String], warnings: [String])? {
        changeWords(for: item, frameSize: item.frameSize)
    }

    /// `changeWords(for:)` as if the item had the frame size `frameSize` (for the size chooser).
    public func changeWords(for item: Item, frameSize: Int?) -> (changes: [String], warnings: [String])? {
        guard let e = expected(for: item, frameSize: frameSize) else { return nil }
        var changes: [String] = []
        // Parallel to the frame-count change, so a reader sees which number changes.
        if e.resizes { changes.append("\(Self.formatCount(e.frameSizeIn)) → \(Self.formatCount(e.frameSizeOut)) samples") }
        if e.changesCount {
            changes.append("\(Self.formatCount(e.frameCountIn)) → \(e.tableFrameCount) frames, " + Self.methodWord(e.countPolicy, grows: e.frameCountGrows == true))
        }
        // "Attenuated": resizing a frame can raise its peak above ±1 (a square to 128 samples
        // reaches 1.18), and the writer then scales the table to fit (WritePlan.Scaling).
        if e.scaledToFit { changes.append("attenuated") }
        else if e.mayScaleToFit { changes.append("may be attenuated") }
        if e.addsPPGWaves { changes.append("+ PPG waveforms") }
        if preset.isThirdWave, WavetableWriter.thirdWaveName(item.name).name != item.name.trimmingCharacters(in: .whitespaces) {
            changes.append("name changed")
        }
        var warnings: [String] = []
        if e.peakKept { warnings.append("peak \(Wavetable.peakText(e.peak)), may clip") }
        for note in item.table.readNotes where Self.isWarning(note.kind) {
            if let word = Self.shortWarning(note.kind), !warnings.contains(word) { warnings.append(word) }
        }
        return (changes, warnings)
    }

    /// A reader's warning in a few words that stand on their own, for the Changes column; the
    /// note itself is the tooltip. Nil for a kind that is not a warning (see `isWarning`).
    static func shortWarning(_ kind: ReadNote.Kind) -> String? {
        switch kind {
        case let .samplesLeftOut(n, _): return "\(formatCount(n)) extra sample\(n == 1 ? "" : "s") dropped"
        case let .channelsDropped(_, of): return of == 2 ? "left channel only" : "first channel only"
        case .sizeClaimsDisagree: return "size tags disagree"
        case .interpolationClaimsDisagree: return "interpolation tags disagree"
        case .cutShort: return "file cut short"
        case .sidecarOutOfRange: return ".txt size out of range, ignored"
        case .sizeTagUnreadable: return "unreadable size tag ignored"
        case let .sizeTagRejected(source, _, reason):
            switch reason {
            case .unusableSize: return "unusable size tag ignored"
            case .fileShorterThanFrame: return source == .serumSidecar ? ".txt size larger than the file, ignored" : "size tag larger than the file, ignored"
            }
        case .peak, .highFrameCount, .unusualSurgeFrameSize, .tagInComment, .commentMentionsFrames: return nil
        }
    }

    // MARK: Sweep notes

    /// A note on what a sweep through the result sounds like, when it is not what the
    /// interpolation choice suggests: shown set apart in the Output block (with an icon) and,
    /// for a repeated-frames note, in the report after converting. The confusion these head
    /// off: a listener switches between none and crossfade and hears no difference, because the
    /// output's frames are repeated or because the table's frames differ little (Adam,
    /// 2026-10-26).
    public struct SweepNote: Equatable {
        public enum Kind: Equatable {
            /// The destination needs more frames than the source has and Original Frames Only
            /// repeats them, so a synth that blends between frames blends only where the frame
            /// changes: a caution, with the setting that changes it.
            case repeatedFrames
            /// Neighboring frames differ little, so stepping and blending between them sound
            /// nearly the same: information, nothing to change.
            case alikeFrames
        }
        public var kind: Kind
        public var text: String
    }

    /// The repeated-frames note for an item, or nil when the output's frames are not repeated
    /// (`WritePlan.repeatsFrames`).
    public func repeatedFramesNote(for item: Item) -> SweepNote? {
        guard let e = expected(for: item), e.repeatsFrames else { return nil }
        let blender = preset.isThirdWave ? "the 3rd Wave’s wavetable smoothing" : "a synth that blends between frames"
        return SweepNote(kind: .repeatedFrames, text:
            "The \(Self.formatCount(e.frameCountIn)) frames are repeated to make \(Self.formatCount(e.tableFrameCount)), so \(blender) can blend only where the frame changes; "
            + "the sweep is stepped whatever the interpolation. Crossfade New Frames, under Options, makes the sweep continuous.")
    }

    /// The alike-frames note for a table's frames (the result's, as the destination gets them),
    /// or nil when neighboring frames differ enough to hear the steps. Repeated frames are left
    /// out of the measure (`neighborDifference(_:)`), so a repeated table is judged by its
    /// original frames and gets the repeated-frames note instead when it is alike as well.
    public static func alikeFramesNote(for frames: [[Float]]) -> SweepNote? {
        guard let d = neighborDifference(frames), d < alikeThreshold else { return nil }
        return SweepNote(kind: .alikeFrames, text:
            "Neighboring frames are much alike, so stepping and blending between frames can be hard to tell apart.")
    }

    /// Below this, neighboring frames are "much alike". A heuristic, set by Adam's ear on
    /// 2026-10-26: factory P03 measures 0.01 and FM Crush (U48) 0.025, and he hears no
    /// difference between stepping and blending on either; Bowed Lowed measures 0.03, Metal
    /// Bubbles (U26) 0.04, P00 0.06, Additive Bell (U00) 0.09 (a slight but real difference),
    /// All Waves 0.41. First set at 0.02, raised when FM Crush got no note.
    public static let alikeThreshold: Float = 0.05

    /// How much neighboring frames differ, as the median over the pairs that differ at all of
    /// the RMS difference between a frame and the next, relative to the table's peak (0 for
    /// identical, about 0.4 for a sine next to a saw). Nil for a table without two differing
    /// frames of the same length, or a silent one.
    public static func neighborDifference(_ frames: [[Float]]) -> Float? {
        guard frames.count > 1, let n = frames.first?.count, n > 0, frames.allSatisfy({ $0.count == n }) else { return nil }
        let peak = frames.reduce(Float(0)) { m, f in f.reduce(m) { max($0, abs($1)) } }
        guard peak > 0 else { return nil }
        var differences: [Float] = []
        for (a, b) in zip(frames, frames.dropFirst()) {
            var sum: Float = 0, same = true
            for (x, y) in zip(a, b) {
                let d = x - y
                if same, abs(d) > 1e-6 { same = false }
                sum += d * d
            }
            if !same { differences.append((sum / Float(n)).squareRoot() / peak) }
        }
        guard !differences.isEmpty else { return nil }
        let sorted = differences.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: Preview

    /// Runs the writer for one item (whether Convert All takes it does not matter), so the preview can
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

    /// Converts items with `write` (each separately; a failure is collected, not thrown), and
    /// gives the files unique names: the items with the given ids, in list order (Convert
    /// Selected…), or, with nil, the items Convert All takes (`includedItems`). Items without a
    /// known frame size are reported and left out.
    public func convert(_ ids: Set<UUID>? = nil, write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write)
        -> Conversion {
        var files: [OutputFile] = [], converted: [UUID] = [], reports: [ItemReport] = [], errors: [String] = []
        let chosen = ids.map { (wanted: Set<UUID>) in items.filter { wanted.contains($0.id) } } ?? includedItems
        for item in chosen {
            guard var table = item.table.wavetable(frameSize: item.frameSize) else {
                errors.append("\(item.name): " + (item.frameSize == nil
                    ? "choose a frame size first"
                    : "can’t split into frames of \(Self.formatCount(item.frameSize ?? 0))"))
                continue
            }
            table.name = item.name
            do {
                let f = try write(table, preset, options)
                files.append(f); converted.append(item.id)
                // The repeated-frames caution goes with the writer's notes: it is about the file.
                reports.append(ItemReport(name: item.name, notes: f.notes + (repeatedFramesNote(for: item).map { [$0.text] } ?? [])))
            } catch {
                errors.append("\(item.name): \(Self.describe(error))")
            }
        }
        return Conversion(files: Self.uniqueNames(files), itemIDs: converted, reports: reports, errors: errors)
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

    /// The files to hand to the Pack page after writing: the 3rd Wave `.wt` files, for a 3rd Wave
    /// destination; none otherwise.
    public static func filesForPack(_ written: [URL], preset: OutputPreset) -> [URL] {
        preset.isThirdWave ? written.filter { $0.pathExtension.lowercased() == "wt" } : []
    }

    // MARK: Wording

    /// `name`, or "name 2", "name 3", … (before the extension) until `taken` is false.
    static func numbered(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // A Tonverk tag must stay at the very end of the name, where Tonverk reads it:
        // "Pad_wt128r.wav" becomes "Pad 2_wt128r.wav", not "Pad_wt128r 2.wav".
        var tag = ""
        if let r = WavetableWriter.trailingTonverkTag(in: base) {
            tag = String(base[r]); base = String(base[..<r.lowerBound])
        }
        var n = 2
        while true {
            let candidate = "\(base) \(n)" + tag + (ext.isEmpty ? "" : "." + ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// A count with thousands separators, independent of the locale ("1,024"); the same formatting
    /// as the library's notes (`WavetableReader.grouped`).
    public static func formatCount(_ n: Int) -> String { WavetableReader.grouped(n) }

    /// The phrase with its first letter in capitals, when it starts with an ordinary word ("cue
    /// markers" to "Cue markers"); a name such as "u-he" or "clm" alone is left as it is.
    static func capitalized(_ s: String) -> String {
        guard let first = s.first, first.isLowercase, s.dropFirst().first?.isLetter == true else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// A list in words, with the serial comma: "A", "A and B", "A, B, and C".
    public static func listPhrase(_ xs: [String], _ conjunction: String = "and") -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        case 2: return xs[0] + " \(conjunction) " + xs[1]
        default: return xs.dropLast().joined(separator: ", ") + ", \(conjunction) " + xs.last!
        }
    }

    /// The frame sizes a table's length allows, with the frame count each gives, to follow
    /// "frames of": "256 samples (64 frames) or 2,048 samples (8 frames)".
    static func candidateList(_ t: FoundTable) -> String {
        let parts = t.candidateFrameSizes.map { n -> String in
            let frames = n > 0 ? t.samples.count / n : 0
            return "\(formatCount(n)) samples (\(frames) frame\(frames == 1 ? "" : "s"))"
        }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " or " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + ", or " + parts.last!
        }
    }

    /// The kind of source, in a few words ("WAV", "U56 in Set.pgdata", "3rd Wave U .wt").
    static func sourceDescription(_ t: FoundTable) -> String {
        switch t.source {
        case .thirdWaveWavetable(let isP): return "3rd Wave \(isP ? "P" : "U") .wt"
        case .unifiedProgram(let slot, _): return "\(slot) in \(t.fileName)"
        case .wav: return "WAV"   // one label: how the frame size was decided is shown with the Input column
        case .flac: return "FLAC"
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
///
/// The app asks with `result(_:in:ready:)`, which answers at once from the cache or starts the
/// conversion on a background queue and calls back on the main thread when it is done: writing a
/// U table and reading its text back takes a noticeable moment, and the window must not wait for
/// it. `preview(_:in:)` and `resultFrames(_:in:)` do the same work at once, on the caller's
/// thread (tests, and anything that needs the answer now). All of it is for one thread at a
/// time, the main thread in the app; only the conversion itself runs elsewhere.
public final class ConvertPreviewCache {
    /// What the preview of one item comes to: the file the page would write and that file read
    /// back and cut into frames (what the destination gets), each nil when there is none.
    public struct Result {
        /// The file the page would write; nil when the item cannot convert or the writer fails.
        public var file: OutputFile?
        /// The file's table read back with `WavetableReader` and cut into frames of the size the
        /// destination writes; nil when there is no file or the reader finds no table in it.
        public var frames: [[Float]]?
    }

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
        /// The result; nil while it is being computed on the background queue.
        var result: Result?
    }
    private var entries: [UUID: Entry] = [:]
    private let write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile
    private let queue = DispatchQueue(label: "pgdata Packer preview", qos: .userInitiated)
    /// How many times the writer has run (for tests).
    public private(set) var writerRuns = 0

    /// An empty cache that converts with `write` (the real writer by default).
    public init(write: @escaping (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write) {
        self.write = write
    }

    private static func key(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> Key {
        Key(itemID: item.id, name: item.name, frameSize: item.frameSize, sampleCount: item.table.samples.count,
            preset: plan.preset, options: plan.options)
    }

    /// The conversion itself: the writer, then the file read back. Pure, so it can run anywhere.
    private static func compute(_ item: ConvertPlan.Item, in plan: ConvertPlan,
                                write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile) -> Result {
        let file = plan.preview(item, write: write)
        var frames: [[Float]]?
        if let file, let found = try? WavetableReader.read(file.data, fileName: file.fileName).first {
            let size = found.frameSize ?? plan.expected(for: item)?.frameSizeOut
            frames = found.wavetable(frameSize: size)?.frames
        }
        return Result(file: file, frames: frames)
    }

    /// The result, computed now if the cache does not hold it.
    private func resultNow(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> Result {
        let key = Self.key(item, in: plan)
        if let hit = entries[item.id], hit.key == key, let result = hit.result { return result }
        writerRuns += 1
        let result = Self.compute(item, in: plan, write: write)
        entries[item.id] = Entry(key: key, result: result)
        return result
    }

    /// `plan.preview(item)`, from the cache when nothing that affects it has changed; computed
    /// now otherwise.
    public func preview(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> OutputFile? {
        resultNow(item, in: plan).file
    }

    /// The converted table as the destination gets it (`Result.frames`), from the cache when
    /// nothing that affects it has changed; computed now otherwise.
    public func resultFrames(_ item: ConvertPlan.Item, in plan: ConvertPlan) -> [[Float]]? {
        resultNow(item, in: plan).frames
    }

    /// The result from the cache, or nil while it is being computed: the first call for an item
    /// (or for a change to it) starts the conversion on a background queue and returns nil, and
    /// `ready` is called on the main thread once the result is in the cache, so the caller can
    /// ask again. Further calls while it is computed return nil without starting it again.
    public func result(_ item: ConvertPlan.Item, in plan: ConvertPlan, ready: @escaping () -> Void) -> Result? {
        let key = Self.key(item, in: plan)
        if let hit = entries[item.id], hit.key == key { return hit.result }   // nil while in progress
        entries[item.id] = Entry(key: key, result: nil)
        writerRuns += 1
        let write = self.write
        queue.async { [weak self] in
            let result = Self.compute(item, in: plan, write: write)
            DispatchQueue.main.async { [weak self] in
                guard let self, let entry = self.entries[item.id], entry.key == key else { return }   // superseded
                self.entries[item.id] = Entry(key: key, result: result)
                ready()
            }
        }
        return nil
    }

    /// Forgets everything (e.g., when items are removed).
    public func removeAll() { entries = [:] }

    /// Forgets the previews of the given items only (e.g., when those rows are removed); the
    /// others keep theirs, so removing one row does not cost the selected table its preview.
    public func remove(_ ids: Set<UUID>) { for id in ids { entries[id] = nil } }
}
