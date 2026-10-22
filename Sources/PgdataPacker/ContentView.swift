import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $state.section) {
                    ForEach(AppState.Section.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            } detail: {
                Group {
                    switch state.section ?? .pack {
                    case .pack: PackView()
                    case .unpack: UnpackView()
                    }
                }
                // Each page fills the detail area and no more (a page that asked for its full
                // content height pushed the top of the window out of view).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            LogBar(showLog: $showLog)
        }
        .frame(minWidth: 960, minHeight: 600)
        // Standard alert with a scrolling text area (see AlertPresenter): system look, but wide
        // enough for one-item-per-line reports, and long lists scroll.
        .onChange(of: state.alertMessage) { msg in
            guard let msg else { return }
            AlertPresenter.show(msg) { state.alertMessage = nil }
        }
    }
}

// MARK: - Log

struct LogBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showLog: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showLog.toggle() } label: {
                    Image(systemName: showLog ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(state.log.last ?? "Drop .pro, .wt, .bin or .pgdata files anywhere in the window.")
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if showLog {
                ScrollView {
                    Text(state.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
            }
        }
    }
}

// MARK: - Drop support

enum DropSupport {
    static func load(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                else if let x = item as? URL { u = x }
                if let u { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

struct EmptyHint: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Shared bits

struct StatusText: View {
    let status: PackPlan.Status
    var body: some View {
        switch status {
        case .ok(let s): Text(s).foregroundStyle(.secondary)
        case .warning(let s): Label(s, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .missing(let s): Label(s, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

struct VerdictBadge: View {
    let verdict: PackPlan.Verdict
    var body: some View {
        switch verdict {
        case .factoryOnly:
            Label("Factory content only", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .embedsContent:
            Label("Embeds wavetables or samples", systemImage: "shippingbox.fill").foregroundStyle(.blue)
        case .blocked(let refs):
            Label("Missing content for " + refs.map(\.label).joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

extension PackPlan.Verdict {
    var symbol: String {
        switch self {
        case .factoryOnly: return "checkmark.circle"
        case .embedsContent: return "shippingbox.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .factoryOnly: return .secondary
        case .embedsContent: return .blue
        case .blocked: return .red
        }
    }
}

/// Shows a report as a standard alert sheet. The first paragraph is the alert's bold title; the
/// rest goes in a selectable text area 520 points wide that scrolls past about 360 points of text.
enum AlertPresenter {
    static func show(_ text: String, done: @escaping () -> Void) {
        let parts = text.components(separatedBy: "\n\n")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = parts.first ?? ""
        let rest = parts.dropFirst().joined(separator: "\n\n")
        if !rest.isEmpty { alert.accessoryView = textArea(rest) }
        alert.addButton(withTitle: "OK")
        if let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: w) { _ in done() }
        } else {
            alert.runModal(); done()
        }
    }

    /// Plain text, except that a line ending in ":" (a list heading such as "Added files not used by
    /// any program:") gets a little space below it before its list starts.
    private static func styled(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let para = NSMutableParagraphStyle()
            if line.hasSuffix(":") { para.paragraphSpacing = 6 }
            out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
            ]))
        }
        return out
    }

    static func textArea(_ text: String) -> NSView {
        let width: CGFloat = 520, maxHeight: CGFloat = 360
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(styled(text))
        var used: CGFloat = 60
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            used = lm.usedRect(for: tc).height + 8
        }
        let height = min(max(used, 20), maxHeight)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: max(used, height))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = used > maxHeight
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }
}
