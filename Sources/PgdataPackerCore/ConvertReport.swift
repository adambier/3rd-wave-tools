import Foundation

/// The report texts shown in alerts and written to the log: paragraphs separated by a blank line;
/// a paragraph whose first line ends in ":" is a heading for the item lines under it. An item line
/// starts with "• " and may carry an explanation after a tab, which the alert shows in a lighter
/// style and the log joins with a dash.
public enum ReportText {
    /// An item line: the name, and the explanation after a tab when there is one.
    public static func item(_ name: String, _ detail: String? = nil) -> String {
        "• " + name + (detail.map { "\t" + $0 } ?? "")
    }
    /// An item from a "name: explanation" line (a file name or table name, then what happened),
    /// so the name is set apart in the alert. A line without ": " is the whole item.
    public static func item(splitting line: String) -> String {
        guard let r = line.range(of: ": ") else { return item(line) }
        return item(String(line[..<r.lowerBound]), String(line[r.upperBound...]))
    }
    /// The text as the log and the clipboard carry it: the tab before an explanation as a dash,
    /// and a heading's single item without its bullet (a list of one is not a list).
    public static func plain(_ s: String) -> String {
        let paragraphs = s.components(separatedBy: "\n\n").map { (paragraph: String) -> String in
            let lines = paragraph.components(separatedBy: "\n")
            guard isSingleItem(lines) else { return paragraph }
            return lines[0] + "\n" + String(lines[1].dropFirst(2))
        }
        return paragraphs.joined(separator: "\n\n").replacingOccurrences(of: "\t", with: " — ")
    }
    /// Whether a paragraph's lines are a heading and one item under it, which is shown without
    /// a bullet.
    public static func isSingleItem(_ lines: [String]) -> Bool {
        lines.count == 2 && lines[0].hasSuffix(":") && lines[1].hasPrefix("• ")
    }
    /// "Not used: …" → "not used: …" for an explanation that follows a dash; a label such as "U50 …"
    /// is left alone.
    public static func lowerFirst(_ s: String) -> String {
        guard let a = s.first, a.isUppercase, s.dropFirst().first?.isLowercase == true else { return s }
        return a.lowercased() + s.dropFirst()
    }
}

/// The Wavetables page's report after converting: the alert's title and text, and the log's text,
/// assembled from the plan, what converting produced, and what writing into the folder did.
public struct ConvertReport: Equatable {
    /// The first line, which the alert shows as its title: "Converted 74 tables for Phase Plant
    /// into “output”." (see `ConvertPlan.reportTitle`).
    public var title: String
    /// The alert's text (see `ReportText` for its form): the title, then, each only when it has
    /// something to say, the tables not converted, the files not written, the files written under
    /// a new name, the files written (the first `namesShown`, with the subfolder once in the
    /// heading: "Written to the WAVES folder:"), what converting did (each note once, with the tables it
    /// applies to), and the sentence about the .wt files added to the
    /// Pack page.
    public var message: String
    /// The log's text: the message with the folder's path after the title and every file written
    /// listed, then every table's own notes under "By table:" when there are any.
    public var log: String

    /// How many written files the alert lists by name; the rest are counted ("…and 62 more") and
    /// listed in the log.
    public static let namesShown = 12

    /// Assembles the report.
    /// - Parameters:
    ///   - plan: The plan converted (its destination names the title).
    ///   - conversion: What converting produced.
    ///   - written: What writing the converted files into `folder` did.
    ///   - folder: The folder the files were written into.
    ///   - packFiles: The .wt files then added to the Pack page (empty when none are).
    public init(plan: ConvertPlan, conversion: ConvertPlan.Conversion, written: ConvertPlan.WriteReport,
                folder: URL, packFiles: [URL]) {
        title = plan.reportTitle(converted: written.written.count, folderName: folder.lastPathComponent)
        var before = title
        // Each section: a heading line ending in ":" and one item per line (see ReportText).
        if !conversion.errors.isEmpty { before += "\n\nNot converted:\n" + conversion.errors.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !written.failed.isEmpty { before += "\n\nNot written:\n" + written.failed.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !written.renamed.isEmpty {
            before += "\n\nAlready in the folder, so written under a new name (nothing was replaced):\n"
                + written.renamed.map { ReportText.item($0) }.joined(separator: "\n")
        }
        // The files written, by name, so the names can be checked against the tables; the
        // subfolder every file went into (WAVES, for the 3rd Wave) is said once, in the heading.
        let names = written.written.map { ReportText.item($0.lastPathComponent) }
        var writtenShort = "", writtenFull = ""
        if !names.isEmpty {
            let heading = "\n\n" + Self.writtenHeading(written.written, folder: folder) + "\n"
            writtenFull = heading + names.joined(separator: "\n")
            writtenShort = names.count <= Self.namesShown ? writtenFull
                : heading + names.prefix(Self.namesShown).joined(separator: "\n") + "\n…and \(names.count - Self.namesShown) more (see the log)."
        }
        var after = ""
        // Each distinct note once: "All 74 tables", "12 tables", or the one table it applies to.
        // The log, below, has every table's own lines.
        let grouped = ConvertPlan.groupedNotes(conversion.reports)
        if !grouped.isEmpty {
            after += "\n\nWhat converting did:\n" + grouped.map { ReportText.item($0.label, $0.text) }.joined(separator: "\n")
        }
        if !packFiles.isEmpty {
            after += "\n\n" + (packFiles.count == 1 ? "The .wt file is" : "The \(packFiles.count) .wt files are") + " added to the Pack page."
        }
        // The report is where the files are in hand, so it says how they get onto the 3rd Wave.
        if plan.preset.isThirdWave, !written.written.isEmpty {
            after += "\n\n" + Self.loadingLine
        }
        message = before + writtenShort + after
        // The log names the folder in full, on the title's line, and lists every file written.
        var logged = title + " (\(folder.path))" + String(before.dropFirst(title.count)) + writtenFull + after
        if !conversion.notes.isEmpty {
            logged += "\n\nBy table:\n" + conversion.notes.map { ReportText.item(splitting: $0) }.joined(separator: "\n")
        }
        log = logged
    }

    /// How the .wt files get onto the 3rd Wave; the destination pane's footer says the same.
    public static let loadingLine = "To load them: copy the WAVES folder onto the 3rd Wave’s USB drive and use Global → “Bulk wavetable import”, or add them to the 3rd Wave Terminal app’s library and sync."

    /// "Written to the WAVES folder:" when every file went into the same subfolder of `folder`; "Written:"
    /// when they went into `folder` itself (or into different subfolders).
    static func writtenHeading(_ written: [URL], folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let subfolders = Set(written.map { (url: URL) -> String in
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            return parent == base ? "" : url.deletingLastPathComponent().lastPathComponent
        })
        guard subfolders.count == 1, let sub = subfolders.first, !sub.isEmpty else { return "Written:" }
        return "Written to the \(sub) folder:"
    }
}
