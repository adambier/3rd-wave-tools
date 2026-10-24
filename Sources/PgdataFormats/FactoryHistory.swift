import Foundation

// Facts about the 3rd Wave that tools need besides the file layouts: which slots became factory
// slots in 2025, how to tell a program saved before then, and how the 3rd Wave names the files
// it exports. See sections 2 and 8 of FORMATS.md.

public extension SourceRef {
    /// Whether this is one of U48–U55, the wavetable slots that became factory slots in 2025
    /// (with OS 1.9). Before then they were user slots, and some program sets stored their own
    /// tables there.
    var is2025FactorySlot: Bool {
        if case let .u(n) = self { return (48...55).contains(n) }
        return false
    }
}

public extension ProgramFile {
    /// The number of values in the float block of a program saved by OS 1.9 or later: 544 (OS 2.0d
    /// writes 548). Programs saved earlier have fewer.
    static let floatBlockCountSince2025 = 544

    /// Whether the program was saved before OS 1.9, and so before U48–U55 held factory tables: an
    /// older format (`W3_PROG_1` to `_4`) or fewer than 544 values in its float block. A file
    /// carries no date, so this is an inference from the layout: every set seen with 544 or more
    /// float values dates from 2025 on, and every set with fewer from before.
    var predates2025FactoryTables: Bool {
        (1...4).contains(versionNumber) || floatBlockCount < Self.floatBlockCountSince2025
    }
}

/// How the 3rd Wave names the files it exports, and how to read a program location from a file
/// name. See section 8 of FORMATS.md.
public enum ExportNames {
    /// The name part of a `.pgdata` file name as the 3rd Wave writes it in an export: spaces become
    /// underscores, ASCII letters, digits, hyphens, and underscores are kept, and anything else is
    /// dropped ("Big Bass (MW)" → "Big_Bass_MW"). Non-ASCII letters are dropped too: how the 3rd Wave
    /// writes them is not known. Returns "Untitled" when nothing is left.
    public static func unifiedProgramName(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: true).map { w in
            String(w.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        }.filter { !$0.isEmpty }
        return words.isEmpty ? "Untitled" : words.joined(separator: "_")
    }

    private static let locationPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[Bb]0?([1-5])-?[Pp](\d{1,3})(?!\d)"#)

    /// The program location (bank 1–5, program 1–100) named in a file name, in the forms the 3rd Wave
    /// and Groove Synthesis use: "B05P003.pro", "B05P18_Name.pgdata", or "B5-P003 Name.pro".
    public static func programLocation(inFileName name: String) -> (bank: Int, program: Int)? {
        guard let m = locationPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let b = Range(m.range(at: 1), in: name), let p = Range(m.range(at: 2), in: name),
              let bank = Int(name[b]), let prog = Int(name[p]), (1...100).contains(prog) else { return nil }
        return (bank, prog)
    }

    private static let bankFolderPattern = try! NSRegularExpression(pattern: #"^[Bb]ank\s*0?([1-5])$"#)

    /// The program location of a file: from its name, or from Groove Synthesis's older layout of a
    /// "Bank 1" folder holding "001.PRO" to "100.PRO" (its 2022 factory banks for the 24-voice models).
    public static func programLocation(of url: URL) -> (bank: Int, program: Int)? {
        if let l = programLocation(inFileName: url.lastPathComponent) { return l }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard base.count <= 3, base.allSatisfy(\.isNumber), let prog = Int(base), (1...100).contains(prog),
              let m = bankFolderPattern.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)),
              let b = Range(m.range(at: 1), in: folder), let bank = Int(folder[b]) else { return nil }
        return (bank, prog)
    }
}
