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
            // Two pages, chosen with a segmented control rather than a sidebar, which would take
            // width the Pack tables need.
            HStack {
                Spacer()
                Picker("", selection: $state.section) {
                    ForEach(AppState.Section.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch state.section {
                case .pack: PackView()
                case .unpack: UnpackView()
                }
            }
            // Each page fills the area and no more (a page that asked for its full content height
            // pushed the top of the window out of view).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            LogBar(showLog: $showLog)
        }
        // Tall enough for both Pack panes at their minimum heights with the log open.
        .frame(minWidth: 900, minHeight: 700)
        // Standard alert with a scrolling text area (see AlertPresenter): system look, but wide
        // enough for one-item-per-line reports, and long lists scroll.
        .onChange(of: state.alertMessage) { msg in
            guard let msg else { return }
            let reveal = state.alertReveal
            state.alertReveal = nil
            AlertPresenter.show(msg, reveal: reveal) { state.alertMessage = nil }
        }
    }
}

/// A blue border while files are dragged over a page, so a drop target is visible.
struct DropHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(3)
                .opacity(active ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func dropHighlight(_ active: Bool) -> some View { modifier(DropHighlight(active: active)) }
}

// MARK: - Log

struct LogBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showLog: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // A labelled button rather than a bare arrow, so it is clear what it opens.
                Button { showLog.toggle() } label: {
                    Label(showLog ? "Hide Log" : "Show Log", systemImage: showLog ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(showLog ? "Hide the log" : "Show the log: everything the app has done in this session")
                Divider().frame(height: 14)
                // While files are read, their progress takes the place of the last log line, here
                // rather than in the page's toolbar, so the toolbar never changes width.
                if let p = state.reading {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        .frame(width: 120)
                    Text("Reading \(p.done) of \(p.total)…")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.log.last ?? "Nothing added yet.")
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Drop .pro, .wt, .bin or .pgdata files onto the page above to add them", systemImage: "arrow.down.doc")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                .visibleScrollers()
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

/// A short placeholder over an empty list or table.
struct ListPlaceholder: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(20)
        .allowsHitTesting(false)
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

/// A row's status in a few words, with the full sentence on hover.
struct StatusText: View {
    let brief: String
    let status: PackPlan.Status
    var body: some View {
        switch status {
        case .ok(let s): Text(brief).foregroundStyle(.secondary).lineLimit(1).help(s)
        case .warning(let s): Label(brief, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1).help(s)
        case .missing(let s): Label(brief, systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(1).help(s)
        }
    }
}

/// One line that says what packing this program produces: what is embedded, the size, and the
/// free slots it needs; or what stops it being packed.
struct PlanSummary: View {
    let plan: PackPlan

    private func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private var text: String {
        switch plan.verdict {
        case .blocked(let refs):
            let list = refs.map(\.label)
            let joined = list.count == 1 ? list[0] : list.dropLast().joined(separator: ", ") + " and " + list.last!
            return "Can't pack yet: \(joined) need\(list.count == 1 ? "s" : "") a file"
        case .factoryOnly:
            return "Factory tables only, nothing to embed: \(PackPlan.formatBytes(plan.estimatedBytes))"
        case .embedsContent:
            let c = plan.embeddedCounts
            var parts: [String] = []
            if c.wavetables > 0 { parts.append(count(c.wavetables, "wavetable")) }
            if c.multisamples > 0 { parts.append(count(c.multisamples, "multisample")) }
            var s = "Embeds " + parts.joined(separator: " and ") + ": \(PackPlan.formatBytes(plan.estimatedBytes))"
            let need = plan.slotsNeeded
            var slots: [String] = []
            if need.u > 0 { slots.append("\(need.u) U") }
            if need.p > 0 { slots.append("\(need.p) P") }
            if c.multisamples > 0 { slots.append("\(c.multisamples) S") }
            if !slots.isEmpty { s += "; needs " + slots.joined(separator: ", ") + " free slot\(need.u + need.p + c.multisamples == 1 ? "" : "s") on the 3rd Wave" }
            return s
        }
    }

    var body: some View {
        Label(text, systemImage: plan.verdict.symbol)
            .foregroundStyle(plan.verdict.tint)
            .help("The 3rd Wave reuses a table it already has (in any slot, under any name) and stores new ones in free slots. With none free, it offers to overwrite its last tables; blank placeholders count as used.")
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
    /// `reveal`: a folder to offer a "Show in Finder" button for.
    static func show(_ text: String, reveal: URL? = nil, done: @escaping () -> Void) {
        let parts = text.components(separatedBy: "\n\n")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = parts.first ?? ""
        let rest = parts.dropFirst().joined(separator: "\n\n")
        let content = rest.isEmpty ? nil : textArea(rest)
        alert.accessoryView = content
        alert.addButton(withTitle: "OK")
        if reveal != nil { alert.addButton(withTitle: "Show in Finder") }
        // A copy icon that puts the whole report on the clipboard as plain text and leaves the
        // sheet open.
        addCopyButton(to: alert, content: content, copying: ReportText.plain(text))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn, let url = reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            done()
        }
        if let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: w, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Lays out a report (see `ReportText`): paragraphs separated by blank lines, headings (lines
    /// ending in ":") in semibold with the list under them as indented bullets, and an item's
    /// explanation (after the tab) in italic grey after the name.
    private static func styled(_ text: String) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let body = NSFont.systemFont(ofSize: size)
        let heading = NSFont.systemFont(ofSize: size, weight: .semibold)
        let italic = NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? body
        let out = NSMutableAttributedString()
        for paragraph in text.components(separatedBy: "\n\n") {
            for line in paragraph.components(separatedBy: "\n") {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = out.string.isEmpty ? 0 : 14   // before a paragraph or heading
                if !out.string.isEmpty { out.append(NSAttributedString(string: "\n")) }
                if line.hasPrefix("• ") {
                    // A list item: bullet in a hanging indent, then the name and its explanation,
                    // half a line below the previous line.
                    para.paragraphSpacingBefore = 8
                    para.firstLineHeadIndent = 10
                    para.headIndent = 24
                    para.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
                    para.defaultTabInterval = 24
                    let parts = line.dropFirst(2).components(separatedBy: "\t")
                    out.append(NSAttributedString(string: "•\t" + parts[0], attributes: [
                        .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
                    if parts.count > 1 {
                        out.append(NSAttributedString(string: " — " + parts.dropFirst().joined(separator: " "), attributes: [
                            .font: italic, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
                    }
                } else {
                    out.append(NSAttributedString(string: line, attributes: [
                        .font: line.hasSuffix(":") ? heading : body,
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
                }
            }
        }
        return out
    }

    /// Puts the copy icon in the alert's lower-left corner, level with the response buttons: the
    /// spot macOS gives an alert's Help button, the one control it places beside the buttons
    /// without being an answer to the alert. Laying the alert out first is how Apple says to
    /// position things relative to its views. When the buttons leave no room there (two side by
    /// side across the whole width), the icon goes under the text instead.
    private static func addCopyButton(to alert: NSAlert, content: NSView?, copying text: String) {
        alert.layout()
        let button = CopyButton(text: text, sizedLike: alert.buttons.first)
        if let contentView = alert.window.contentView, let ok = alert.buttons.first {
            let okFrame = contentView.convert(ok.bounds, from: ok)
            let leading = content.map { contentView.convert($0.bounds, from: $0).minX } ?? leadingEdge(of: contentView)
            let buttonsLeft = alert.buttons.map { contentView.convert($0.bounds, from: $0).minX }.min() ?? okFrame.minX
            let frame = NSRect(x: leading, y: okFrame.minY, width: button.frame.width, height: button.frame.height)
            if frame.maxX + 8 <= buttonsLeft {
                button.frame = frame
                button.autoresizingMask = [.maxXMargin, .maxYMargin]   // stays in the corner
                contentView.addSubview(button)
                return
            }
        }
        alert.accessoryView = withCopyButton(content, button)
        alert.layout()
    }

    /// The left edge of the alert's text, from its text fields.
    private static func leadingEdge(of view: NSView) -> CGFloat {
        var edges: [CGFloat] = []
        func walk(_ v: NSView) {
            for s in v.subviews {
                if s is NSTextField { edges.append(view.convert(s.bounds, from: s).minX) }
                walk(s)
            }
        }
        walk(view)
        return edges.min() ?? 16
    }

    /// `content` (a text area, or nothing) above a right-aligned copy icon.
    private static func withCopyButton(_ content: NSView?, _ button: NSButton) -> NSView {
        let width = content?.frame.width ?? 520
        let rowHeight = button.frame.height + 4
        let height = (content?.frame.height ?? 0) + rowHeight
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if let content {
            content.frame = NSRect(x: 0, y: rowHeight, width: width, height: content.frame.height)
            box.addSubview(content)
        }
        button.frame.origin = NSPoint(x: width - button.frame.width, y: 0)
        box.addSubview(button)
        return box
    }

    /// A push button showing the system copy symbol that copies `text` and shows a check mark
    /// for a moment. Sized like `reference` (the alert's OK button) so the two line up.
    private final class CopyButton: NSButton {
        private let text: String
        private static let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        private static let doneIcon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        init(text: String, sizedLike reference: NSButton?) {
            self.text = text
            super.init(frame: .zero)
            title = ""
            image = Self.copyIcon
            imagePosition = .imageOnly
            bezelStyle = reference?.bezelStyle ?? .rounded
            controlSize = reference?.controlSize ?? .large
            toolTip = "Copy results to clipboard"
            setAccessibilityLabel("Copy results to clipboard")
            target = self
            action = #selector(copyText)
            sizeToFit()
            frame.size.width = max(frame.width, frame.height)   // square, not a sliver
        }
        required init?(coder: NSCoder) { nil }
        @objc private func copyText() {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            image = Self.doneIcon
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.image = Self.copyIcon }
        }
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
        // A long report scrolls: then show a classic scroll bar and a frame, so that is obvious.
        let scrolls = used > maxHeight
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = scrolls
        scroll.drawsBackground = false
        scroll.borderType = scrolls ? .bezelBorder : .noBorder
        scroll.documentView = tv
        return scroll
    }
}
