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
    /// The text as the log and the clipboard carry it: the tab before an explanation as a dash.
    public static func plain(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " — ") }
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
    /// a new name, what converting did (each note once, with the tables it applies to), the
    /// 3rd Wave capacity note, and the sentence about the .wt files added to the Pack page.
    public var message: String
    /// The log's text: the message with the folder's path, then every table's own notes under
    /// "By table:" when there are any.
    public var log: String

    /// Assembles the report.
    /// - Parameters:
    ///   - plan: The plan converted (its destination names the title; its capacity note is shown).
    ///   - conversion: What converting produced.
    ///   - written: What writing the converted files into `folder` did.
    ///   - folder: The folder the files were written into.
    ///   - packFiles: The .wt files then added to the Pack page (empty when none are).
    public init(plan: ConvertPlan, conversion: ConvertPlan.Conversion, written: ConvertPlan.WriteReport,
                folder: URL, packFiles: [URL]) {
        title = plan.reportTitle(converted: written.written.count, folderName: folder.lastPathComponent)
        var msg = title
        // Each section: a heading line ending in ":" and one item per line (see ReportText).
        if !conversion.errors.isEmpty { msg += "\n\nNot converted:\n" + conversion.errors.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !written.failed.isEmpty { msg += "\n\nNot written:\n" + written.failed.map { ReportText.item(splitting: $0) }.joined(separator: "\n") }
        if !written.renamed.isEmpty {
            msg += "\n\nAlready in the folder, so written under a new name (nothing was replaced):\n"
                + written.renamed.map { ReportText.item($0) }.joined(separator: "\n")
        }
        // Each distinct note once: "All 74 tables", "12 tables", or the one table it applies to.
        // The log, below, has every table's own lines.
        let grouped = ConvertPlan.groupedNotes(conversion.reports)
        if !grouped.isEmpty {
            msg += "\n\nWhat converting did:\n" + grouped.map { ReportText.item($0.label, $0.text) }.joined(separator: "\n")
        }
        if let capacity = plan.thirdWaveCapacityNote {
            msg += "\n\n" + capacity
        }
        if !packFiles.isEmpty {
            msg += "\n\n" + (packFiles.count == 1 ? "The .wt file is" : "The \(packFiles.count) .wt files are") + " added to the Pack page."
        }
        message = msg
        var logged = msg + " (\(folder.path))"
        if !conversion.notes.isEmpty {
            logged += "\n\nBy table:\n" + conversion.notes.map { ReportText.item(splitting: $0) }.joined(separator: "\n")
        }
        log = logged
    }
}
