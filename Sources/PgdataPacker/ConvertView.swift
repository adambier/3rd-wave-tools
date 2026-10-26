import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(PgdataFormats)
import PgdataFormats
#endif
#if canImport(WavetableFormats)
import WavetableFormats
#endif
#if canImport(PgdataPackerCore)
import PgdataPackerCore
#endif

/// The Wavetables page: the wavetables found in the files added (top left), a read-only preview of
/// the selected one (bottom left), and the destination with its options, which apply to every
/// table to convert (right). The decisions are in `ConvertPlan`; the preview is in
/// ConvertDetail.swift and the destination pane in ConvertDestination.swift.
struct ConvertView: View {
    @EnvironmentObject var state: AppState
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false
    @State private var showNameCleanup = false

    var body: some View {
        VStack(spacing: 0) {
            if ConvertPlan.conversionUnderDevelopment { ConvertDevelopmentNotice() }
            controls
            Divider()
            if state.convertPlan.items.isEmpty {
                EmptyHint(title: "Drop wavetables here",
                          detail: "Add WAV and FLAC wavetables (Serum, Vital, and others), 3rd Wave .wt and .pgdata files, and Surge .wt files; folders work too, and files without wavetables are passed over. Each table is then listed with its size (frames × samples per frame) and what converting changes, and previewed below. This page converts existing wavetables between formats; it does not make wavetables from other audio.")
            } else {
                HSplitView {
                    // The preview's height is the page's own (dragged at the divider, kept
                    // between sessions): a VSplitView gave the preview back its smallest height
                    // whenever the selection changed its content.
                    GeometryReader { (geo: GeometryProxy) in
                        let tallest = max(ConvertPaneDivider.minimumHeight, geo.size.height - ConvertPaneDivider.tableMinimumHeight)
                        let height = min(max(state.convertPreviewHeight, ConvertPaneDivider.minimumHeight), tallest)
                        VStack(spacing: 0) {
                            ConvertTablesPane(selection: $selection)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            ConvertPaneDivider(height: $state.convertPreviewHeight, tallest: tallest)
                            ConvertDetailPane(selection: selection)
                                .frame(maxWidth: .infinity)
                                .frame(height: height)
                        }
                    }
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                    ConvertDestinationPane()
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
        .dropHighlight(dropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            DropSupport.load(providers) { state.addToConvert(urls: $0) }
            return true
        }
        // A row that goes (removed here, or by Remove All) leaves the selection, whichever way
        // it went.
        .onChange(of: state.convertPlan.items.map(\.id)) { (ids: [UUID]) in
            selection = selection.filter { (id: UUID) -> Bool in ids.contains(id) }
        }
    }

    // The keyboard shortcuts (Open, Convert) are the File menu's; see main.swift.
    private var controls: some View {
        let plan = state.convertPlan
        let marked = plan.selectedItems.count
        return HStack(spacing: 14) {
            Button("Add Files or Folders…") {
                state.addToConvert(urls: Panels.chooseFiles(message: "Choose wavetable files (.wav, .flac, .wt, .pgdata) or folders to search",
                                                            allowedExtensions: ["wav", "flac", "wt", "pgdata"]))
            }
            Button("Clean Up Names…") { showNameCleanup = true }
                .disabled(plan.items.allSatisfy { $0.factorySlot != nil })
                .help("Propose tidier names for the tables listed (e.g., slot numbers removed, title case), used for the converted files. Factory wavetables keep their names.")
                .sheet(isPresented: $showNameCleanup) { NameCleanupSheet(state: state, page: .convert) }
            Spacer()
            Button("Remove Selected") { state.removeConvertItems(selection); selection = [] }
                .disabled(selection.isEmpty || state.isWorking)
                .help("Remove the selected tables from this list (the files are not touched)")
            Button("Remove All…") { state.removeAllConvert() }
                .disabled(plan.items.isEmpty || state.isWorking)
                .help("Remove every table from this page (the files are not touched)")
            // Always shown, so the toolbar keeps its width; available for the 3rd Wave presets.
            Button("Send to Pack…") { state.convertTables(sendToPack: true) }
                .disabled(marked == 0 || !plan.preset.isThirdWave || state.isWorking)
                .help(plan.preset.isThirdWave
                      ? "Convert the tables marked to convert into .wt files in a folder you choose, then add them to the Pack page"
                      : "Available when converting to a 3rd Wave table")
            Button("Convert…") { state.convertTables() }
                .disabled(marked == 0 || state.isWorking)
                .buttonStyle(.borderedProminent)
                .help("Convert the tables marked to convert into a folder you choose")
        }
        .padding(10)
    }
}

/// The notice under the toolbar while `ConvertPlan.conversionUnderDevelopment` is true: in
/// orange, centred, with the reason as its tip. It goes by itself once every destination has
/// been tested in its synth (`OutputPreset.testedIn`).
struct ConvertDevelopmentNotice: View {
    var body: some View {
        Label("Wavetable conversion under development.", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .help("Converting has not yet been tested in every destination’s synth; the Sources beside each destination say whether it has been there. The notice goes when all have.")
    }
}

/// The divider between the table and the preview: dragging it changes the preview's height
/// (`AppState.convertPreviewHeight`), between `minimumHeight` and `tallest`, as a split view's
/// divider would, with the up-down cursor. A thin line in a strip wide enough to grab.
struct ConvertPaneDivider: View {
    @Binding var height: CGFloat
    /// The most the preview may take: the pane's height less what the table keeps.
    let tallest: CGFloat
    @State private var heightAtStart: CGFloat?

    /// The least the preview is given.
    static let minimumHeight: CGFloat = 170
    /// What the table above keeps when the preview is dragged up (its header, a few rows, and
    /// the divider).
    static let tableMinimumHeight: CGFloat = 220
    /// The strip the pointer grabs.
    private static let grabHeight: CGFloat = 9

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: Self.grabHeight)
        .contentShape(Rectangle())
        .onHover { (inside: Bool) in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { (drag: DragGesture.Value) in
                    let start = heightAtStart ?? height
                    heightAtStart = start
                    NSCursor.resizeUpDown.set()   // kept while the pointer runs ahead of the strip
                    // Dragging down makes the preview shorter.
                    height = min(max(start - drag.translation.height, Self.minimumHeight), tallest)
                }
                .onEnded { _ in heightAtStart = nil }
        )
        .accessibilityLabel("Preview height")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            let step: CGFloat = 20
            height = min(max(height + (direction == .increment ? step : -step), Self.minimumHeight), tallest)
        }
    }
}

// MARK: - The tables found

struct ConvertTablesPane: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: Set<UUID>

    /// The rows shown: every table, or only those that can't be converted yet.
    private var shown: [ConvertPlan.Item] {
        let plan = state.convertPlan
        guard state.convertOnlyAttention, plan.blockedCount > 0 else { return plan.items }
        return plan.items.filter(plan.needsAttention)
    }

    var body: some View {
        let st = state
        let rows = shown
        VStack(alignment: .leading, spacing: 0) {
            ConvertSummaryStrip(state: st) { (status: ConvertPlan.Status) in
                // Jump to the first table with that status: select it (the preview follows)
                // and scroll it into view.
                guard let item = st.convertPlan.firstItem(with: status) else { return }
                selection = [item.id]
                if let row = rows.firstIndex(where: { $0.id == item.id }) {
                    DispatchQueue.main.async { TableReveal.scroll(toRow: row, rowCount: rows.count) }
                }
            }
            ConvertTable(state: st, items: rows, selection: $selection)
        }
    }
}

/// Scrolls the page's table to a row. SwiftUI's `Table` gives no way to scroll to a row on
/// macOS 13 (`ScrollViewReader` does not reach its rows), so the `NSTableView` behind it is
/// looked up in the window, told apart from any other by its row count, and asked directly.
/// When none is found, nothing happens (the row is still selected).
enum TableReveal {
    static func scroll(toRow row: Int, rowCount: Int) {
        guard row >= 0, let root = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView,
              let table = tableView(in: root, rows: rowCount) else { return }
        table.scrollRowToVisible(row)
    }

    private static func tableView(in view: NSView, rows: Int) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfRows == rows { return table }
        for sub in view.subviews {
            if let table = tableView(in: sub, rows: rows) { return table }
        }
        return nil
    }
}

/// One line above the table: how many tables there are and how many are marked to convert,
/// what blocks any of them (each count a button that jumps to the first such table), and the
/// filter for the blocked ones.
struct ConvertSummaryStrip: View {
    @ObservedObject var state: AppState
    /// Called with a blocking status when its count is clicked.
    let jump: (ConvertPlan.Status) -> Void

    var body: some View {
        let plan = state.convertPlan
        let total = plan.items.count
        let marked = plan.selectedItems.count
        HStack(spacing: 12) {
            Text("\(total) table\(total == 1 ? "" : "s") · \(marked) to convert")
                .monospacedDigit()
            ConvertBlockedCount(count: plan.needsFrameSizeCount, one: "needs a frame size", many: "need frame sizes",
                                help: "Tables marked to convert whose file doesn’t specify a frame size: choose one in the Input column. Click to go to the first.") {
                jump(.needsFrameSize)
            }
            ConvertBlockedCount(count: plan.cannotSplitCount, one: "can’t be split", many: "can’t be split",
                                help: "Tables marked to convert whose samples don’t divide into frames of the size given. Click to go to the first.") {
                jump(.cannotSplit)
            }
            Spacer()
            Toggle("Show only tables that can’t be converted yet", isOn: $state.convertOnlyAttention)
                .toggleStyle(.checkbox).font(.caption)
                .disabled(plan.blockedCount == 0)
                .help(plan.blockedCount == 0
                      ? "Every table marked to convert can be converted"
                      : "Show only the tables marked to convert that still need a frame size, or whose samples don’t divide into frames")
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
    }
}

/// "1 needs a frame size" or "3 can't be split" in red, or nothing when the count is 0. `one` and
/// `many` complete the count for one table and for several. A borderless button, as Xcode's
/// issue counts are: clicking it goes to the first such table, and the pointer says so.
struct ConvertBlockedCount: View {
    let count: Int
    let one: String
    let many: String
    let help: String
    let action: () -> Void

    var body: some View {
        if count > 0 {
            Button(action: action) {
                Label("\(count) \(count == 1 ? one : many)", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { (inside: Bool) in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

/// The table itself: whether it is converted, its state, its name (edited after a double-click
/// on the row) and origin, its size and where that came from, what the destination writes, and
/// what changes on the way.
struct ConvertTable: View {
    @ObservedObject var state: AppState
    let items: [ConvertPlan.Item]
    @Binding var selection: Set<UUID>
    /// The row whose name is being edited, if any (see `ConvertNameField`).
    @State private var renaming: UUID?

    var body: some View {
        let st = state
        let plan = st.convertPlan
        Table(items, selection: $selection) {
            // Wide enough for its header: at 44 points "Convert" was cut to "Conv…".
            TableColumn("Convert") { (item: ConvertPlan.Item) in ConvertCheckCell(state: st, item: item) }
                .width(min: 66, ideal: 66, max: 66)
            TableColumn("") { (item: ConvertPlan.Item) in ConvertStatusCell(status: plan.status(item), tip: plan.statusDescription(item)) }
                .width(22)
            TableColumn("Name") { (item: ConvertPlan.Item) in ConvertNameCell(state: st, item: item, renaming: $renaming) }
                .width(min: 140, ideal: 210)
            // Input and Output are both frames × samples per frame: the headers say the unit (a
            // Table header takes no tooltip on macOS 13), the cells spell it out on hover. The
            // widths fit the headers and the longest cells ("256 × 2,048  from markers" with its
            // chevron; "256 → 64 frames, picked evenly, turned down" on two lines).
            TableColumn("Input (frames × samples)") { (item: ConvertPlan.Item) in ConvertFrameSizeCell(state: st, item: item, selection: $selection) }
                .width(min: 230, ideal: 260)
            // The interpolation the table came with ("Not stated" for most WAVs); what the
            // destination's file records is the Options box's affair.
            TableColumn("Interpolation") { (item: ConvertPlan.Item) in
                ConvertInterpolationCell(interpolation: item.table.interpolation, included: plan.isSelected(item))
            }
                .width(min: 100, ideal: 120)
            TableColumn("Output (frames × samples)") { (item: ConvertPlan.Item) in
                ConvertOutputCell(expected: plan.expected(for: item), summary: plan.expectedResult(for: item), included: plan.isSelected(item))
            }
                .width(min: 170, ideal: 190)
            TableColumn("Changes") { (item: ConvertPlan.Item) in
                ConvertChangesCell(words: plan.changeWords(for: item), summary: plan.expectedResult(for: item),
                                   notes: plan.itemNotes(for: item), included: plan.isSelected(item))
            }
                .width(min: 200, ideal: 330)
        }
        // A double-click on a row edits its name: the Table's own double-click, so a single
        // click selects the row as it does anywhere else in the table. (A double-tap gesture on
        // the name would most likely claim the first click, as the Input column's button and the
        // old name field do, which is why both had to select their row by hand.) The rows'
        // contextual menu offers the same, and removing, for the rows clicked.
        .contextMenu(forSelectionType: UUID.self) { (ids: Set<UUID>) in
            if ids.count == 1, let id = ids.first {
                Button("Rename") { rename(id) }
                    .disabled(st.isWorking)
            }
            if !ids.isEmpty {
                Button("Remove") { st.removeConvertItems(ids) }
                    .disabled(st.isWorking)
            }
        } primaryAction: { (ids: Set<UUID>) in
            if ids.count == 1, let id = ids.first { rename(id) }
        }
        .onDeleteCommand { state.removeConvertItems(selection); selection = [] }
    }

    /// Starts editing the row's name, with the row selected so the preview below shows the table.
    private func rename(_ id: UUID) {
        selection = [id]
        renaming = id
    }
}

struct ConvertCheckCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    var body: some View {
        // The title is the checkbox's name for VoiceOver; the column header shows the word.
        Toggle("Convert \(item.name)", isOn: Binding(get: { state.convertPlan.isSelected(item) },
                                                      set: { state.convertPlan.setSelected(item.id, $0) }))
            .labelsHidden()
            .help(item.factorySlot != nil && state.convertPlan.preset.isThirdWave
                  ? "Your 3rd Wave is expected to have this factory table (U48–U55 since the 2025 update, which Groove Synthesis offers as a download), so it starts unchecked" : "")
    }
}

/// The interpolation the table's file states: "None (stepped)", "Crossfade", "Spectral", or, in
/// secondary type, "Not stated".
struct ConvertInterpolationCell: View {
    let interpolation: Interpolation?
    let included: Bool
    var body: some View {
        Text(Interpolation.displayName(interpolation))
            .lineLimit(1)
            .foregroundStyle(interpolation == nil || !included ? Color.secondary : Color.primary)
            .help(interpolation == nil
                  ? "The file does not say how to move between frames; most synths set this on the oscillator, and a destination whose file records it saves crossfade unless the Options say otherwise."
                  : "How the file asks a synth to move between frames: none (it steps from frame to frame), crossfade (it blends neighbours), or spectral (it blends their harmonics).")
    }
}

/// Red when the table can't be converted yet, a grey check when it is ready, nothing when it is
/// not marked to convert.
struct ConvertStatusCell: View {
    let status: ConvertPlan.Status
    let tip: String
    var body: some View {
        switch status {
        case .needsFrameSize:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).help(tip)
                .accessibilityLabel("Needs a frame size")
        case .cannotSplit:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(tip)
                .accessibilityLabel("Can’t be split into frames")
        case .ready:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help(tip)
                .accessibilityLabel("Ready to convert")
        case .excluded:
            Text("").help(tip)
        }
    }
}

/// The table's name, edited in place after a double-click on the row, with its badges: where it
/// came from when that matters (a slot in a .pgdata, a 3rd Wave or Surge .wt, a FLAC), a factory
/// table, and identical copies found elsewhere.
struct ConvertNameCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    @Binding var renaming: UUID?
    var body: some View {
        let plan = state.convertPlan
        let included = plan.isSelected(item)
        HStack(spacing: 5) {
            ConvertNameField(state: state, item: item, included: included, renaming: $renaming)
            if let origin = item.originBadge {
                ConvertBadge(text: origin, tip: item.location.url.path)
            }
            if let slot = item.factorySlot {
                // The slot in the badge, so the row says which factory table this is.
                ConvertBadge(text: "Factory \(slot.label)",
                             tip: "Same as factory \(slot.label)\(item.factoryName.map { " " + $0 } ?? ""): your 3rd Wave is expected to have it")
            }
            if !item.alsoIn.isEmpty {
                Label("×\(item.alsoIn.count + 1)", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("\(item.alsoIn.count + 1) identical copies, listed and converted once. Also in: "
                          + item.alsoIn.map(\.label).joined(separator: ", "))
            }
        }
    }
}

/// The name as plain text, which becomes a field while the row is being renamed (a double-click
/// on the row, or Rename in its contextual menu; see `ConvertTable`), as a file's name does in
/// the Finder; a single click only selects the row, as anywhere else in the table. Return or
/// leaving the field commits, Escape restores the name, and the text comes back either way; an
/// empty name is not taken.
struct ConvertNameField: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let included: Bool
    /// The row being renamed, shared by the table's rows; this one edits while it is `item.id`.
    @Binding var renaming: UUID?
    @State private var text = ""
    @FocusState private var focused: Bool

    private var editing: Bool { renaming == item.id }

    var body: some View {
        if editing {
            TextField("Name", text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .lineLimit(1)
                .foregroundStyle(included ? Color.primary : Color.secondary)
                .focused($focused)
                .onAppear {
                    text = item.name
                    // Focus asked for once the field is in the window, not while it is being put there.
                    DispatchQueue.main.async { focused = true }
                }
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .onChange(of: focused) { (now: Bool) in if !now { commit() } }
        } else {
            // Fills the cell up to the badges, as the field does, so the badges keep their place
            // at the cell's end whether the name is being edited or not.
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(included ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.newName == nil ? "The table’s name; double-click the row to edit it. The name goes on the converted file (and inside a 3rd Wave table); the source file is not changed."
                                          : "Was \u{201C}\(item.table.name)\u{201D}; double-click the row to edit")
        }
    }

    // `renaming` goes first in both: the field's loss of focus commits, and a second pass must
    // find nothing to do. `focused` is set back by hand so that the next edit's `true` is a change.
    private func commit() {
        guard editing else { return }
        renaming = nil
        focused = false
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != item.name { state.convertPlan.rename(item.id, to: trimmed) }
    }

    private func cancel() {
        renaming = nil
        focused = false
    }
}

/// A small rounded label in a table cell.
struct ConvertBadge: View {
    let text: String
    let tip: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .help(tip)
    }
}

/// The input as frames × samples per frame, with a word or two after it on where the size
/// comes from ("in the file", "assumed", "set manually"; `Item.sizeQualifier`). When the file
/// allows other sizes, the cell is a button that opens the size chooser and selects the row,
/// so the preview below shows the table; when the size is still open, it is red.
struct ConvertFrameSizeCell: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    @Binding var selection: Set<UUID>
    @State private var choosing = false

    var body: some View {
        let included = state.convertPlan.isSelected(item)
        let choices = item.frameSizeChoices
        if choices.isEmpty && !item.needsFrameSize {
            ConvertSizeText(item: item, included: included, plain: true)
                .help("Input: " + item.sizeDescription + " (frames × samples per frame). " + item.basisDescription)
        } else if choices.isEmpty {
            Label("Can’t split", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1)
                .help(state.convertPlan.statusDescription(item))
        } else {
            Button { selection = [item.id]; choosing.toggle() } label: {
                HStack(spacing: 4) {
                    if item.frameSize == nil {
                        Text("Choose Size…").foregroundStyle(.red)
                    } else {
                        ConvertSizeText(item: item, included: included)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .help(item.needsFrameSize
                  ? "The file doesn’t specify a frame size. Click to choose one of the sizes its length allows (frames × samples per frame)."
                  : "Input: " + item.sizeDescription + " (frames × samples per frame). " + item.basisDescription + " Click to choose another size.")
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
                ConvertSizePopover(state: state, item: item)
            }
        }
    }
}

/// "64 × 2,048" and, in secondary type, the qualifier when there is one. The count sits in a
/// column of its own (see `ConvertFramesBySize`), so the × signs line up down the table.
struct ConvertSizeText: View {
    let item: ConvertPlan.Item
    let included: Bool
    /// Whether the text stands on its own rather than in a bordered button, which insets its
    /// label; the plain text is inset the same, so the two line up in one column.
    var plain: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if let count = item.frameCount, let size = item.frameSize {
                ConvertFramesBySize(count: count, size: size)
                    .foregroundStyle(included ? Color.primary : Color.secondary)
            } else {
                Text(item.sizeDescription).lineLimit(1)
                    .foregroundStyle(included ? Color.primary : Color.secondary)
            }
            if let word = item.sizeQualifier {
                Text(word).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, plain ? ConvertFramesBySize.buttonInset : 0)
    }
}

/// "64 × 2,048" in three parts: the count right-aligned in a column wide enough for three
/// digits, the × sign, and the size; the parts can be styled apart (the Output column puts
/// a changed number in semibold).
struct ConvertFramesBySize: View {
    let count: Int
    let size: Int
    var countWeight: Font.Weight = .regular
    var sizeWeight: Font.Weight = .regular

    /// The width of the count's column: room for three digits.
    static let countWidth: CGFloat = 26
    /// What a bordered button insets its label by, applied to plain text in the same column.
    static let buttonInset: CGFloat = 7

    var body: some View {
        // Never shortened to "2…": the numbers take the width they need, and when a cell is too
        // narrow it is the word after them that gives way.
        HStack(spacing: 4) {
            Text("\(count)").fontWeight(countWeight)
                .frame(minWidth: Self.countWidth, alignment: .trailing)
            Text("×").foregroundStyle(.secondary)
            Text(ConvertPlan.formatCount(size)).fontWeight(sizeWeight)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }
}

/// The size chooser: where the size comes from, a button per size the file's length allows with
/// the first frame drawn at that size, and what the "likely" mark means (see `FrameSizeFit`; a
/// suggestion, never applied by itself).
struct ConvertSizePopover: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item

    /// Three buttons to a row, with the popover's padding.
    private static let width: CGFloat = 3 * ConvertSizeButton.width + 2 * 8 + 24
    /// The width the sentences wrap at (the popover's, less its padding).
    private static let textWidth: CGFloat = width - 24

    /// What the “likely” mark on a button means, or that nothing stands out; nothing when the
    /// likely size is the one assumed (the sentence above the buttons says so then).
    private var fitLine: String? {
        switch item.frameSizeFit {
        case .likely(let n):
            if item.sizeSource == .likely { return nil }
            return "The likely size, \(ConvertPlan.formatCount(n)), is the one whose frames are alike from one to the next, as a wavetable’s are."
        case .tie:
            return "The sizes fit the samples equally well; nothing here settles it."
        case .unclear:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frame size").font(.headline)
            // Where the size comes from; the pictures below show each size the length allows.
            Text(item.basisDescription)
                .font(.caption)
                .frame(width: Self.textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // Three buttons to a row, each wide enough for its result on two lines; a length
            // that allows more sizes gets more rows rather than narrower buttons. Plain stacks,
            // not a LazyVGrid: in a popover's VStack the lazy grid took all the height and left
            // every sentence around it one truncated line.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(stride(from: 0, to: item.frameSizeChoices.count, by: 3)), id: \.self) { (start: Int) in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(item.frameSizeChoices[start..<min(start + 3, item.frameSizeChoices.count)], id: \.self) { (size: Int) in
                            ConvertSizeButton(state: state, item: item, size: size,
                                              likely: FrameSizeFit.likelySize(item.frameSizeFit) == size)
                                .frame(width: ConvertSizeButton.width)
                        }
                    }
                }
            }
            if let fitLine {
                Text(fitLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: Self.textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        // The popover inherits its anchor's environment, and the table's cells hold their text
        // to one line; without this every sentence and result here was cut to one line with an
        // ellipsis, whatever its frame.
        .lineLimit(nil)
    }
}

/// One size: the first frame cut at that size, "64 × 128" under it, what the destination makes
/// of it ("→ 64 × 1,024, 4 → 64 frames, repeated"), and "likely" when the samples suggest it.
struct ConvertSizeButton: View {
    @ObservedObject var state: AppState
    let item: ConvertPlan.Item
    let size: Int
    var likely: Bool = false

    /// The button's width: three to a row in the chooser (see `ConvertSizePopover`), each wide
    /// enough for its result in caption type on two lines.
    static let width: CGFloat = 160

    /// "→ 64 × 1,024, 4 → 64 frames, repeated": what the destination writes for this size.
    private var becomes: String {
        let plan = state.convertPlan
        guard let e = plan.expected(for: item, frameSize: size) else { return "" }
        var line = "→ \(e.frameCountOut) × \(ConvertPlan.formatCount(e.frameSizeOut))"
        if let words = plan.changeWords(for: item, frameSize: size), !words.changes.isEmpty {
            line += ", " + words.changes.joined(separator: ", ")
        }
        return line
    }

    var body: some View {
        let chosen = item.frameSize == size
        let frames = item.table.samples.count / max(size, 1)
        Button { state.convertPlan.chooseFrameSize(item.id, size) } label: {
            VStack(spacing: 3) {
                // The first frame cut at this size, as wide as the button: the right size shows one
                // complete cycle; too large repeats it, too small cuts it off.
                WaveThumbnail(samples: Array(item.table.samples.prefix(size)), tint: chosen ? Color.accentColor : Color.primary,
                              width: Self.width - 16, height: 36)
                Text("\(frames) × \(ConvertPlan.formatCount(size))")
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
                // The result wraps under the size rather than being cut off: "→ 64 × 1,024,"
                // then "4 → 64 frames, repeated".
                Text(becomes)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if likely {
                    Text("likely").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)   // the width the chooser gives the button
            .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(chosen ? "The frame size used: \(frames) frames of \(ConvertPlan.formatCount(size)) samples"
                     : "Use \(ConvertPlan.formatCount(size)) samples per frame (\(frames) frames)")
    }
}

/// What the destination writes: "64 × 1,024", the numbers that change in semibold; "—" when
/// the table can't be converted.
struct ConvertOutputCell: View {
    let expected: ConvertPlan.ExpectedResult?
    let summary: String
    let included: Bool

    var body: some View {
        if let e = expected {
            ConvertFramesBySize(count: e.frameCountOut, size: e.frameSizeOut,
                                countWeight: e.frameCountOut != e.frameCountIn ? .semibold : .regular,
                                sizeWeight: e.resizes ? .semibold : .regular)
                .foregroundStyle(included ? Color.primary : Color.secondary)
                .help("Output (frames × samples per frame): " + (included ? summary : "not marked to convert. If it were: " + summary))
        } else {
            Text("—").foregroundStyle(.secondary).help(summary)
        }
    }
}

/// What converting changes, in a few words each ("resized, 64 → 256 frames"), then the
/// warnings in orange ("peak 1.14"), on up to two lines; "—" when only the format changes. The
/// whole story on hover.
struct ConvertChangesCell: View {
    let words: (changes: [String], warnings: [String])?
    let summary: String
    let notes: ConvertPlan.ItemNotes
    let included: Bool

    /// Plain sentences: the output and what changes, then each warning and note as the reader
    /// or the plan wrote it.
    private var tip: String {
        (["Output " + summary + "."] + notes.all).joined(separator: "\n")
    }

    var body: some View {
        if let words {
            if words.changes.isEmpty && words.warnings.isEmpty {
                Text("—").foregroundStyle(.secondary).help("Nothing changes but the format.\n" + tip)
            } else {
                line(words).lineLimit(2).help(tip)
            }
        } else {
            Text("—").foregroundStyle(.secondary).help(tip)
        }
    }

    private func line(_ words: (changes: [String], warnings: [String])) -> Text {
        let changes = Text(words.changes.joined(separator: ", "))
            .foregroundColor(included ? Color.primary : Color.secondary)
        guard !words.warnings.isEmpty else { return changes }
        let warnings = Text(words.warnings.joined(separator: ", ")).foregroundColor(.orange)
        guard !words.changes.isEmpty else { return warnings }
        let comma = Text(", ").foregroundColor(.secondary)
        return changes + comma + warnings
    }
}

/// For a 3rd Wave destination: a scissors icon when the `.wt` will carry a different name, the
/// name and the writer's notes on hover; with `compact` off (the Clean Up Names sheet), the name
/// itself. The name is what the writer will write: `NameField.fitted` (the rule the Pack page's
/// `NameLengthNote` describes too), after the writer trims spaces at the ends.
struct ThirdWaveNameNote: View {
    let name: String
    var compact: Bool = true
    var body: some View {
        let written = WavetableWriter.thirdWaveName(name)
        if written.name != name.trimmingCharacters(in: .whitespaces) {
            let tip = "Written as \u{201C}\(written.name)\u{201D}\n" + written.notes.joined(separator: "\n")
            if compact {
                Image(systemName: "scissors").foregroundStyle(.orange).help(tip)
            } else {
                Label("Written as \u{201C}\(written.name)\u{201D}", systemImage: "scissors")
                    .foregroundStyle(.orange).lineLimit(1).help(tip)
            }
        }
    }
}
