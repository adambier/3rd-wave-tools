import Foundation

// MARK: - Factory library

/// Groove Synthesis's factory wavetables, as names and content fingerprints by slot.
///
/// pgdata Packer uses the built-in list (``builtIn``, generated from Groove Synthesis's factory
/// `.wt` files by `tw3pg factory-catalog`); it never embeds factory tables, so it does not need
/// their data. ``init(folders:)`` reads the `.wt` files themselves, for that generator and for
/// tests.
///
/// Factory slots are P00–P35 and U00–U55 (section 2 of FORMATS.md). A program can list a factory
/// table without its data, since every 3rd Wave is expected to have it loaded.
public struct FactoryLibrary {
    /// One factory wavetable: its display name and the fingerprint of its content.
    public struct Table: Equatable {
        /// The table's display name, as its `.wt` file gives it.
        public var name: String
        /// The table's content fingerprint, as ``WavetableFile/fingerprint`` computes it.
        public var fingerprint: UInt64
        /// Creates a table entry from a name and a content fingerprint.
        public init(name: String, fingerprint: UInt64) { self.name = name; self.fingerprint = fingerprint }
    }
    /// The factory tables known to this library, by slot.
    public private(set) var tables: [SourceRef: Table] = [:]
    /// Files that ``init(folders:)`` could not use, each as a sentence; empty for other initializers.
    public private(set) var problems: [String] = []

    /// Creates an empty library.
    public init() {}

    /// Creates a library from tables keyed by slot.
    public init(_ tables: [SourceRef: Table]) { self.tables = tables }

    /// The factory set built into the library (U00–U55, P00–P35; U48–U55 added in 2025).
    public static let builtIn: FactoryLibrary = {
        var t: [SourceRef: Table] = [:]
        for e in FactoryCatalog.entries {
            if let r = SourceRef(label: e.slot), r.isFactorySlot { t[r] = Table(name: e.name, fingerprint: e.fingerprint) }
        }
        return FactoryLibrary(t)
    }()

    /// Whether all 56 factory U tables and all 36 factory P tables are present.
    public var isComplete: Bool {
        tables.keys.filter { if case .u = $0 { return true }; return false }.count >= 56 && tables.keys.filter(\.isP).count >= 36
    }

    /// Reads the .wt files in each folder and in its immediate subfolders, as Groove Synthesis
    /// distributes them ("00-Additive_Bell_17.wt", "00P.wt", "P34_VS_0-63.wt"). The slot comes from
    /// the number at the start of the file name; the kind from the file's own header.
    public init(folders: [URL]) {
        let fm = FileManager.default
        for folder in folders {
            guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
                problems.append("Could not read \(folder.path)."); continue
            }
            var items = top
            for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                items += (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
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
                tables[ref] = Table(name: w.name, fingerprint: w.fingerprint)
            }
        }
    }

    /// The display name of the factory table in `ref`, or nil when the library has none for that slot.
    public func name(_ ref: SourceRef) -> String? { tables[ref]?.name }

    /// The factory slot whose table has this content fingerprint, or nil when there is none.
    public func slot(withFingerprint f: UInt64) -> SourceRef? {
        tables.first { $0.value.fingerprint == f }?.key
    }

    /// Swift source for the library's built-in catalog, listing these tables in slot order.
    ///
    /// `note` becomes the second comment line of the generated file. This is how the catalog behind
    /// ``builtIn`` is generated.
    public func catalogSource(note: String) -> String {
        let refs = tables.keys.sorted()
        var s = """
        // Generated by `tw3pg factory-catalog`. Do not edit by hand.
        // \(note)
        //
        // Names and content fingerprints (FNV-1a 64 of the table's values) of the factory wavetables.
        // Only these are stored, not the wavetables themselves.

        enum FactoryCatalog {
            static let entries: [(slot: String, name: String, fingerprint: UInt64)] = [

        """
        for r in refs {
            let t = tables[r]!
            let name = t.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            s += "        (\"\(r.label)\", \"\(name)\", 0x" + String(format: "%016llX", t.fingerprint) + "),\n"
        }
        s += "    ]\n}\n"
        return s
    }
}
