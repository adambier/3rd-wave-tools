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
        /// The frame size the user chose, when the file leaves it open (`table.frameSize` is nil).
        public var chosenFrameSize: Int?
        /// The user's tick; nil follows the destination's default (see `ConvertPlan.isSelected`).
        public var userSelection: Bool?
        /// Content identity for collapsing duplicates.
        let contentKey: ContentKey

        /// The table's name.
        public var name: String { table.name }
        /// The frame size used: the file's, or the user's choice when the file leaves it open.
        public var frameSize: Int? { table.frameSize ?? chosenFrameSize }
        /// Whether the file leaves the frame size open, so the user must choose one.
        public var needsFrameSize: Bool { table.frameSize == nil }
        /// Frames at the frame size used; nil when no size is known or the samples do not divide.
        public var frameCount: Int? {
            guard let n = frameSize, n > 0, !table.samples.isEmpty, table.samples.count % n == 0 else { return nil }
            return table.samples.count / n
        }
        /// Frames × samples ("64 × 1,024"), or what is missing.
        public var sizeDescription: String {
            if let n = frameSize, let c = frameCount { return "\(c) × \(ConvertPlan.formatCount(n))" }
            if frameSize != nil { return "Samples do not divide into frames" }
            return "Frame size needed"
        }
        /// How the frame size was decided, in a short phrase.
        public var basisDescription: String {
            if !needsFrameSize { return table.frameSizeBasis }
            let open = table.candidateFrameSizes.isEmpty
                ? "not settled by the file"
                : "not settled by the file; its length allows " + ConvertPlan.candidateList(table)
            return chosenFrameSize == nil ? open : "Your choice (" + open + ")"
        }
        /// The interpolation the source asks for, or "not stated".
        public var interpolationDescription: String { table.interpolation?.rawValue ?? "not stated" }
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

    /// Content identity: frame size, sample count, and an FNV-1a hash of the samples' bits.
    struct ContentKey: Hashable {
        var frameSize: Int?
        var count: Int
        var hash: UInt64
        init(_ t: FoundTable) {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for s in t.samples {
                var b = s.bitPattern
                for _ in 0..<4 { h = (h ^ UInt64(b & 0xff)) &* 0x0000_0100_0000_01b3; b >>= 8 }
            }
            frameSize = t.frameSize; count = t.samples.count; hash = h
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

    /// What a conversion produced, before anything is written.
    public struct Conversion: Equatable {
        /// The converted files, with unique names (see `uniqueNames`).
        public var files: [OutputFile]
        /// The item each file came from, in the same order.
        public var itemIDs: [UUID]
        /// What the conversions did, as "Name: note".
        public var notes: [String]
        /// Tables that could not be converted, as "Name: reason".
        public var errors: [String]
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
                              factorySlot: slot, factoryName: factoryName, contentKey: key))
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

    /// Sets the frame size for an item whose file leaves it open; nil clears the choice. Sizes
    /// that the file's length does not allow are ignored.
    public mutating func chooseFrameSize(_ id: UUID, _ size: Int?) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].needsFrameSize else { return }
        if let size, !items[i].table.candidateFrameSizes.contains(size) { return }
        items[i].chosenFrameSize = size
    }

    /// Notes for an item: the reader's, and what the destination means for it.
    public func notes(for item: Item) -> [String] {
        var out = item.table.notes
        if let slot = item.factorySlot {
            if preset.isThirdWave {
                out.append("Identical to the 3rd Wave's \(item.factoryLabel ?? slot.label). Every 3rd Wave already has it, so it starts unticked.")
            } else {
                out.append("Identical to the 3rd Wave's \(item.factoryLabel ?? slot.label).")
            }
        }
        if item.needsFrameSize && item.chosenFrameSize == nil {
            out.append(item.table.candidateFrameSizes.isEmpty
                ? "The file does not settle the frame size, and its length allows none of the usual sizes."
                : "The file does not settle the frame size. Choose one: its length allows \(Self.candidateList(item.table)).")
        }
        return out
    }

    /// Whether an item can be converted: its frame size is known and its samples divide into frames.
    public func canConvert(_ item: Item) -> Bool { item.frameCount != nil }

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

    /// What converting an item to the destination is expected to produce, from the preset's facts
    /// (e.g., "64 × 1,024; frames resized from 2,048 samples; 256 frames reduced to 64 by picking
    /// evenly"). The writer's own notes, after converting, say what was done.
    public func expectedResult(for item: Item) -> String {
        guard let size = item.frameSize else { return "Choose a frame size first" }
        guard let count = item.frameCount else { return "Cannot be converted: the samples do not divide into frames of \(Self.formatCount(size))" }
        let outSize = destinationFrameSize(source: size)
        let outCount = destinationFrameCount(source: count)
        var parts = ["\(outCount) × \(Self.formatCount(outSize))"]
        if outSize != size { parts.append("frames resized from \(Self.formatCount(size)) samples") }
        let how = options.frameCountPolicy == .pickEvenly ? "picking evenly" : "interpolating"
        if outCount < count {
            parts.append("\(Self.formatCount(count)) frames reduced to \(outCount) by \(how)")
        } else if outCount > count {
            parts.append("\(count) frame\(count == 1 ? "" : "s") brought up to \(outCount) by \(how)")
        }
        if preset == .thirdWaveP && options.appendPPGStandardWaves {
            parts.append("the table brought to 60 frames, then the PPG's four standard waves at 60–63")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Converting

    /// Converts the ticked items with `write` (each separately; a failure is collected, not
    /// thrown), and gives the files unique names. Items without a known frame size are reported
    /// and left out.
    public func convert(write: (Wavetable, OutputPreset, OutputOptions) throws -> OutputFile = WavetableWriter.write)
        -> Conversion {
        var files: [OutputFile] = [], ids: [UUID] = [], notes: [String] = [], errors: [String] = []
        for item in selectedItems {
            guard let table = item.table.wavetable(frameSize: item.frameSize) else {
                errors.append("\(item.name): " + (item.frameSize == nil
                    ? "choose a frame size first"
                    : "the samples do not divide into frames of \(Self.formatCount(item.frameSize!))"))
                continue
            }
            do {
                let f = try write(table, preset, options)
                files.append(f); ids.append(item.id)
                notes += f.notes.map { "\(item.name): \($0)" }
            } catch {
                errors.append("\(item.name): \(Self.describe(error))")
            }
        }
        return Conversion(files: Self.uniqueNames(files), itemIDs: ids, notes: notes, errors: errors)
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

    /// The kind of source, for display.
    static func sourceDescription(_ t: FoundTable) -> String {
        switch t.source {
        case .thirdWaveWavetable(let isP): return "3rd Wave \(isP ? "P" : "U") table (.wt)"
        case .unifiedProgram(let slot, _): return "\(slot) in \(t.fileName)"
        case .wav: return t.frameSize == 2048 ? "Serum-style WAV" : "WAV"
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
