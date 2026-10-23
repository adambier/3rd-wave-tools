import AppKit
import UniformTypeIdentifiers

/// Open/save panels and confirmations (AppKit, modal, main thread).
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

    static func chooseFile(types: [String], message: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        p.message = message
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFiles(message: String) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = message
        return p.runModal() == .OK ? p.urls : []
    }

    /// `details`, when given, goes in a scrolling text area below the message (one item per line).
    /// An alert with several buttons (first one is the default). Returns the index of the button
    /// pressed. `details`, when given, goes in a scrolling text area.
    static func choose(title: String, message: String, details: String? = nil, buttons: [String]) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        if let d = details, !d.isEmpty { a.accessoryView = AlertPresenter.textArea(d) }
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func confirm(title: String, message: String, details: String? = nil, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        if let d = details, !d.isEmpty { a.accessoryView = AlertPresenter.textArea(d) }
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// What `write` did: how many files it wrote and what went wrong, or nil when cancelled.
    struct WriteResult {
        var written: Int
        var failed: [String]
    }

    /// Writes files into a folder. A name may start with a subfolder ("PROGRAM/Pad.pro"); missing
    /// subfolders are created. Within one batch, two outputs with the same path (ignoring case, as
    /// the file system does) get " 2", " 3"… If any of the final paths is already taken, asks once
    /// whether to replace those files, keep both (the new copies get " 2", " 3"…), or cancel.
    /// Write failures are collected and reported once, not one alert per file.
    static func write(_ files: [(name: String, data: Data)], into folder: URL) -> WriteResult? {
        let fm = FileManager.default
        // Path below `folder`, for messages ("WAVES/U57_Warm Pad.wt").
        func shown(_ url: URL) -> String {
            let base = folder.standardizedFileURL.path + "/"
            let p = url.standardizedFileURL.path
            return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : url.lastPathComponent
        }
        // Final paths, with batch duplicates numbered first, so the clash prompt lists the files
        // that would really be replaced.
        var used = Set<String>()
        func numbered(_ name: String, taken: (URL) -> Bool) -> URL {
            var url = folder.appendingPathComponent(name)
            if taken(url) {
                let dir = url.deletingLastPathComponent()
                let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                var n = 2
                repeat { url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1 } while taken(url)
            }
            return url
        }
        var planned: [(url: URL, data: Data)] = files.map { f in
            let u = numbered(f.name) { used.contains(shown($0).lowercased()) }
            used.insert(shown(u).lowercased()); return (u, f.data)
        }
        let clashes = planned.filter { fm.fileExists(atPath: $0.url.path) }
        if !clashes.isEmpty {
            let a = NSAlert()
            a.messageText = clashes.count == 1 ? "\"\(shown(clashes[0].url))\" already exists." : "\(clashes.count) of these files already exist."
            a.informativeText = clashes.prefix(10).map { shown($0.url) }.joined(separator: "\n") + (clashes.count > 10 ? "\n…" : "")
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Keep Both")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn:
                // Keep both: number the new copies past every existing file and every name in the batch.
                used = []
                planned = files.map { f in
                    let u = numbered(f.name) { used.contains(shown($0).lowercased()) || fm.fileExists(atPath: $0.path) }
                    used.insert(shown(u).lowercased()); return (u, f.data)
                }
            default: return nil
            }
        }
        var result = WriteResult(written: 0, failed: [])
        for p in planned {
            do {
                try fm.createDirectory(at: p.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try p.data.write(to: p.url, options: .atomic); result.written += 1
            } catch {
                result.failed.append("\(shown(p.url)): \(error.localizedDescription)")
                if result.failed.count >= 3 && result.written == 0 {
                    result.failed.append("Stopped: nothing could be written to this folder.")
                    break
                }
            }
        }
        return result
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
