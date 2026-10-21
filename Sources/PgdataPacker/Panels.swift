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

    static func confirm(title: String, message: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Writes files into a folder. If any names are taken, asks once whether to replace them,
    /// keep both (new copies get " 2", " 3"… before the extension), or cancel.
    /// Returns the number of files written.
    @discardableResult
    static func write(_ files: [(name: String, data: Data)], into folder: URL) -> Int {
        let fm = FileManager.default
        let clashes = files.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
        var replace = true
        if !clashes.isEmpty {
            let a = NSAlert()
            a.messageText = clashes.count == 1 ? "\"\(clashes[0].name)\" already exists." : "\(clashes.count) of these files already exist."
            a.informativeText = clashes.prefix(10).map(\.name).joined(separator: "\n") + (clashes.count > 10 ? "\n…" : "")
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Keep Both")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: replace = true
            case .alertSecondButtonReturn: replace = false
            default: return 0
            }
        }
        var count = 0
        var used = Set<String>()   // names written in this batch: never overwrite one with another
        for f in files {
            var url = folder.appendingPathComponent(f.name)
            func taken(_ u: URL) -> Bool { used.contains(u.lastPathComponent) || (!replace && fm.fileExists(atPath: u.path)) }
            if taken(url) {
                let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                var n = 2
                repeat {
                    url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
                } while taken(url)
            }
            used.insert(url.lastPathComponent)
            do { try f.data.write(to: url, options: .atomic); count += 1 } catch {
                let a = NSAlert(); a.messageText = "Could not write \(url.lastPathComponent)"; a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
        return count
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
