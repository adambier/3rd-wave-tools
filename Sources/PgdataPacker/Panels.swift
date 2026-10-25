import AppKit
import UniformTypeIdentifiers

/// Open panels, confirmations, and the writing of output files (AppKit, main thread). A question
/// about the window's content is a sheet on the main window (a dialog only when the app has no
/// window), so the answer comes back through a completion handler; the open panels are modal.
enum Panels {
    static func chooseFolder(prompt: String, message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = prompt
        p.message = message
        return p.runModal() == .OK ? p.url : nil
    }

    /// Files of any kind, or folders (the page reads what it can and passes over the rest).
    static func chooseFiles(message: String) -> [URL] {
        chooseFiles(message: message, allowedExtensions: [])
    }

    /// Files with one of the given extensions, or folders; other files are dimmed in the panel.
    /// With no extensions, every file can be chosen.
    static func chooseFiles(message: String, allowedExtensions: [String]) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = message
        let types: [UTType] = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { p.allowedContentTypes = types }
        return p.runModal() == .OK ? p.urls : []
    }

    /// The window a sheet goes on: the main window, or else the key window; nil when there is none.
    static var sheetWindow: NSWindow? {
        NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow
    }

    /// Shows an alert as a sheet on the main window, or as a dialog when the app has no window,
    /// and hands the button chosen to `completion` on the main thread.
    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = sheetWindow {
            alert.beginSheetModal(for: w, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// A confirmation with one action button and Cancel. `details`, when given, goes in a scrolling
    /// text area below the message (one item per line). `completion` gets true when the action
    /// button was chosen.
    static func confirm(title: String, message: String, details: String? = nil, ok: String,
                        completion: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        if let d = details, !d.isEmpty { a.accessoryView = AlertPresenter.textArea(d) }
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        present(a) { (response: NSApplication.ModalResponse) in completion(response == .alertFirstButtonReturn) }
    }

    /// What `write` did: how many files it wrote (and which, as indices into the list given), and
    /// what went wrong; nil when cancelled.
    struct WriteResult {
        var written: Int
        var writtenIndices: Set<Int> = []
        var failed: [String]
    }

    /// Writes files into a folder. A name may start with a subfolder ("PROGRAMS/Pad.pro"); missing
    /// subfolders are created. Within one batch, two outputs with the same path (ignoring case, as
    /// the file system does) get " 2", " 3"… If any of the final paths is already taken, asks once
    /// whether to keep both (the new copies get " 2", " 3"…; the default, since nothing is lost
    /// by it), replace those files, or cancel. The files are then written on a background queue:
    /// `progress` gets (the file being written, how many) on the main thread before each one, and
    /// `completion` the result on the main thread, or nil when cancelled. Write failures are
    /// collected and reported once, not one alert per file.
    static func write(_ files: [(name: String, data: Data)], into folder: URL,
                      progress: @escaping (Int, Int) -> Void = { _, _ in },
                      completion: @escaping (WriteResult?) -> Void) {
        let fm = FileManager.default
        // Path below `folder`, for messages ("WAVES/U57_Warm Pad.wt").
        func shown(_ url: URL) -> String {
            let base = folder.standardizedFileURL.path + "/"
            let p = url.standardizedFileURL.path
            return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : url.lastPathComponent
        }
        // The final path of every file, numbering a name `taken` says is in use (`used` holds the
        // lower-cased paths given out so far in this batch).
        func planned(taken: (URL, Set<String>) -> Bool) -> [(url: URL, data: Data)] {
            var used = Set<String>()
            return files.map { (f: (name: String, data: Data)) -> (url: URL, data: Data) in
                var url = folder.appendingPathComponent(f.name)
                if taken(url, used) {
                    let dir = url.deletingLastPathComponent()
                    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                    var n = 2
                    repeat { url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1 } while taken(url, used)
                }
                used.insert(shown(url).lowercased())
                return (url, f.data)
            }
        }
        // Writes the files off the main thread, reporting each one and then the result on it.
        func start(_ plan: [(url: URL, data: Data)]) {
            DispatchQueue.global(qos: .userInitiated).async {
                var result = WriteResult(written: 0, failed: [])
                for (i, p) in plan.enumerated() {
                    let current = i + 1
                    DispatchQueue.main.async { progress(current, plan.count) }
                    do {
                        try fm.createDirectory(at: p.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try p.data.write(to: p.url, options: .atomic); result.written += 1; result.writtenIndices.insert(i)
                    } catch {
                        result.failed.append("\(shown(p.url)): \(error.localizedDescription)")
                        if result.failed.count >= 3 && result.written == 0 {
                            result.failed.append("Stopped: nothing could be written to this folder.")
                            break
                        }
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
        // Batch duplicates are numbered first, so the clash prompt lists the files that would
        // really be replaced.
        let plan = planned { (url: URL, used: Set<String>) -> Bool in used.contains(shown(url).lowercased()) }
        let clashes = plan.filter { fm.fileExists(atPath: $0.url.path) }
        guard !clashes.isEmpty else { start(plan); return }
        let a = NSAlert()
        a.messageText = clashes.count == 1 ? "\u{201C}\(shown(clashes[0].url))\u{201D} already exists." : "\(clashes.count) of these files already exist."
        a.informativeText = clashes.prefix(10).map { shown($0.url) }.joined(separator: "\n") + (clashes.count > 10 ? "\n…" : "")
        // Keep Both first, so it is the default; Replace is the destructive choice; Cancel gets
        // Escape, as AppKit gives a button of that title.
        a.addButton(withTitle: "Keep Both")
        let replace = a.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        present(a) { (response: NSApplication.ModalResponse) in
            switch response {
            case .alertFirstButtonReturn:
                // Keep both: number the new copies past every existing file and every name in the batch.
                start(planned { (url: URL, used: Set<String>) -> Bool in
                    used.contains(shown(url).lowercased()) || fm.fileExists(atPath: url.path)
                })
            case .alertSecondButtonReturn:
                start(plan)
            default:
                completion(nil)
            }
        }
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
